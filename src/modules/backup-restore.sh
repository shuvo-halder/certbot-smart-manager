#!/bin/bash
# =============================================================================
# certbot-smart-manager — Backup and Restore Module
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/modules/backup-restore.sh
# =============================================================================
#
# Handles backup and rollback of Let's Encrypt directories.
# Must be sourced after utils.sh.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# GLOBALS
# =============================================================================

BACKUP_TIMESTAMP=""
BACKUP_PATH=""

# =============================================================================
# BACKUP LET'S ENCRYPT
# =============================================================================

# Create a timestamped backup of /etc/letsencrypt/
backup_letsencrypt() {
    local backup_dir="${BACKUP_DIR:-/var/backups/certbot-smart-manager}"
    local letsencrypt_dir="/etc/letsencrypt"
    local timestamp
    local backup_file
    local backup_path

    timestamp="$(date '+%Y%m%d_%H%M%S')"
    backup_path="${backup_dir}/${timestamp}"

    if [[ ! -d "$letsencrypt_dir" ]]; then
        log_warning "Cannot backup: ${letsencrypt_dir} does not exist"
        return 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        mkdir -p "$backup_dir" 2>/dev/null || {
            log_error "Failed to create backup directory: ${backup_dir}"
            return 1
        }
        chmod 750 "$backup_dir"
        chown root:root "$backup_dir" 2>/dev/null || true
    fi

    if [[ -e "$backup_path" ]]; then
        log_error "Backup target already exists: ${backup_path}"
        return 1
    fi

    log_info "Creating backup of ${letsencrypt_dir} to ${backup_path}..."

    # Layout: <backup_dir>/<timestamp>/letsencrypt/...  (mirrors /etc/letsencrypt)
    # Directory is 700 because it contains private keys.
    mkdir -m 700 "$backup_path" 2>/dev/null || {
        log_error "Backup failed: unable to create ${backup_path}"
        return 1
    }

    # cp -a: complete copy (preserves permissions, symlinks, timestamps)
    cp -a "$letsencrypt_dir" "${backup_path}/" 2>/dev/null || {
        log_error "Backup failed: unable to copy ${letsencrypt_dir}"
        rm -rf "$backup_path" 2>/dev/null || true
        return 1
    }

    # Optional compressed archive (off by default: the directory copy is
    # already a full backup, and twice-daily runs would double disk usage)
    if [[ "${BACKUP_ARCHIVE:-false}" == "true" ]]; then
        backup_file="${backup_dir}/letsencrypt-${timestamp}.tar.gz"
        if tar -czf "$backup_file" -C /etc letsencrypt 2>/dev/null; then
            chmod 600 "$backup_file" 2>/dev/null || true
            log_debug "Compressed archive: ${backup_file}"
        else
            rm -f "$backup_file" 2>/dev/null || true
            log_warning "Failed to create compressed backup archive"
        fi
    fi

    # Store the backup path for potential rollback
    BACKUP_TIMESTAMP="$timestamp"
    BACKUP_PATH="$backup_path"

    log_success "Backup created: ${backup_path}"

    # Cleanup old backups
    cleanup_old_backups

    return 0
}

# =============================================================================
# RESTORE / ROLLBACK
# =============================================================================

# Restore /etc/letsencrypt/ from a specific backup
# Usage: restore_letsencrypt <backup_path_or_timestamp>
restore_letsencrypt() {
    local restore_source="$1"
    local letsencrypt_dir="/etc/letsencrypt"
    local backup_dir="${BACKUP_DIR:-/var/backups/certbot-smart-manager}"
    local restore_path=""
    local source_dir=""
    local extract_dir=""

    # Resolve the argument: directory path, timestamp, or .tar.gz archive
    if [[ -d "$restore_source" ]]; then
        restore_path="$restore_source"
    elif [[ -d "${backup_dir}/${restore_source}" ]]; then
        restore_path="${backup_dir}/${restore_source}"
    elif [[ -f "$restore_source" && "$restore_source" == *.tar.gz ]] \
        || [[ -f "${backup_dir}/${restore_source}" && "$restore_source" == *.tar.gz ]]; then
        local archive="$restore_source"
        [[ -f "$archive" ]] || archive="${backup_dir}/${restore_source}"
        extract_dir="$(mktemp -d "${backup_dir}/.extract.XXXXXX")" || {
            log_error "Unable to create temporary extraction directory"
            return 1
        }
        log_info "Extracting archive: ${archive}"
        if ! tar -xzf "$archive" -C "$extract_dir" 2>/dev/null; then
            log_error "Failed to extract archive: ${archive}"
            rm -rf "$extract_dir"
            return 1
        fi
        restore_path="$extract_dir"
    else
        log_error "Backup not found: ${restore_source}"
        echo_error "Available backups:"
        list_backups
        return 1
    fi

    # Locate the directory whose contents mirror /etc/letsencrypt.
    # Supported layouts:
    #   <path>/letsencrypt/renewal       (current backups and tar archives)
    #   <path>/renewal                   (older backups: contents copied directly)
    #   <path>/etc/letsencrypt/renewal   (full-path backups)
    if [[ -d "${restore_path}/letsencrypt/renewal" ]]; then
        source_dir="${restore_path}/letsencrypt"
    elif [[ -d "${restore_path}/renewal" ]]; then
        source_dir="$restore_path"
    elif [[ -d "${restore_path}/etc/letsencrypt/renewal" ]]; then
        source_dir="${restore_path}/etc/letsencrypt"
    else
        log_error "Invalid backup structure at: ${restore_path} (no 'renewal' directory found)"
        [[ -n "$extract_dir" ]] && rm -rf "$extract_dir"
        return 1
    fi

    log_warning "Restoring ${letsencrypt_dir} from ${source_dir}..."

    # 1) Stage the restored copy next to the target first. Nothing in
    #    /etc/letsencrypt is touched until this copy has fully succeeded.
    local staging="${letsencrypt_dir}.restore.$$"
    rm -rf "$staging" 2>/dev/null || true
    if ! cp -a "$source_dir" "$staging" 2>/dev/null; then
        log_error "Restore failed: unable to copy from ${source_dir}; /etc/letsencrypt was NOT modified"
        rm -rf "$staging" 2>/dev/null || true
        [[ -n "$extract_dir" ]] && rm -rf "$extract_dir"
        return 1
    fi
    [[ -n "$extract_dir" ]] && rm -rf "$extract_dir"

    # 2) Safety net: move the current state aside into the backup directory
    local pre_restore_backup
    pre_restore_backup="${backup_dir}/pre_restore_$(date '+%Y%m%d_%H%M%S')"
    if [[ -d "$letsencrypt_dir" ]]; then
        mkdir -p -m 700 "$pre_restore_backup"
        if ! cp -a "$letsencrypt_dir" "${pre_restore_backup}/" 2>/dev/null; then
            log_error "Restore aborted: unable to save current state to ${pre_restore_backup}"
            rm -rf "$staging" "$pre_restore_backup" 2>/dev/null || true
            return 1
        fi
        log_warning "Pre-restore backup saved to: ${pre_restore_backup}"
    fi

    # 3) Swap: rename current -> .old, staging -> current (renames on the
    #    same filesystem, so the window without /etc/letsencrypt is tiny)
    local old_dir="${letsencrypt_dir}.old.$$"
    if [[ -d "$letsencrypt_dir" ]]; then
        mv "$letsencrypt_dir" "$old_dir" || {
            log_error "Restore failed: unable to move current ${letsencrypt_dir} aside"
            rm -rf "$staging" 2>/dev/null || true
            return 1
        }
    fi
    if ! mv "$staging" "$letsencrypt_dir"; then
        log_error "Restore failed: unable to put restored copy in place; reverting"
        [[ -d "$old_dir" ]] && mv "$old_dir" "$letsencrypt_dir"
        rm -rf "$staging" 2>/dev/null || true
        return 1
    fi
    rm -rf "$old_dir" 2>/dev/null || true

    # Restore SELinux context if SELinux is enabled
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$letsencrypt_dir" 2>/dev/null || true
    fi

    log_success "Restore completed from: ${restore_source}"

    # Reload web server to pick up restored certificates
    if [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
        echo_info "Reloading web server to apply restored certificates..."
        reload_web_server
    fi

    return 0
}

# =============================================================================
# LIST BACKUPS
# =============================================================================

# List all available backups
list_backups() {
    local backup_dir="${BACKUP_DIR:-/var/backups/certbot-smart-manager}"

    if [[ ! -d "$backup_dir" ]]; then
        echo_info "No backups directory found at ${backup_dir}"
        return 0
    fi

    local has_content=false

    # List directory backups
    local dirs
    dirs="$(find "$backup_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -r)"
    if [[ -n "$dirs" ]]; then
        has_content=true
        echo_bold ""
        echo_bold "Directory Backups:"
        echo_bold "------------------"
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local size
            size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
            local name
            name="$(basename "$d")"
            printf '  %s  (%s)\n' "$name" "$size"
        done <<< "$dirs"
    fi

    # List compressed archives
    local archives
    archives="$(find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort -r)"
    if [[ -n "$archives" ]]; then
        has_content=true
        echo_bold ""
        echo_bold "Compressed Archives:"
        echo_bold "--------------------"
        local a
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            local size
            size="$(du -h "$a" 2>/dev/null | awk '{print $1}')"
            local name
            name="$(basename "$a")"
            printf '  %s  (%s)\n' "$name" "$size"
        done <<< "$archives"
    fi

    if ! $has_content; then
        echo_info "No backups found at ${backup_dir}"
    fi
}

# =============================================================================
# CLEANUP OLD BACKUPS
# =============================================================================

# Remove backups older than BACKUP_RETENTION_DAYS
cleanup_old_backups() {
    local backup_dir="${BACKUP_DIR:-/var/backups/certbot-smart-manager}"
    local retention_days="${BACKUP_RETENTION_DAYS:-30}"

    if [[ ! -d "$backup_dir" ]]; then
        return 0
    fi

    log_debug "Cleaning up backups older than ${retention_days} days..."

    local cleaned=0

    # Clean directory backups
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local dir_name
        dir_name="$(basename "$d")"
        # Directory names are timestamps in format YYYYMMDD_HHMMSS
        if [[ "$dir_name" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            local dir_epoch
            dir_epoch="$(date -d "${dir_name:0:8}" +%s 2>/dev/null || echo "0")"
            local now_epoch
            now_epoch="$(date +%s)"
            local age_days=$(( (now_epoch - dir_epoch) / 86400 ))
            if [[ $age_days -gt $retention_days ]]; then
                rm -rf "$d" 2>/dev/null || true
                cleaned=$((cleaned + 1))
                log_debug "Removed old backup: ${d}"
            fi
        fi
    done < <(find "$backup_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null)

    # Clean compressed archives
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        local file_name
        file_name="$(basename "$a")"
        if [[ "$file_name" =~ ^letsencrypt-[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
            local file_epoch
            file_epoch="$(date -d "${file_name:12:8}" +%s 2>/dev/null || echo "0")"
            local now_epoch
            now_epoch="$(date +%s)"
            local age_days=$(( (now_epoch - file_epoch) / 86400 ))
            if [[ $age_days -gt $retention_days ]]; then
                rm -f "$a" 2>/dev/null || true
                cleaned=$((cleaned + 1))
                log_debug "Removed old archive: ${a}"
            fi
        fi
    done < <(find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null)

    if [[ $cleaned -gt 0 ]]; then
        log_info "Cleaned up ${cleaned} old backup(s)"
    fi
}

# =============================================================================
# ROLLBACK ON INSTALLATION FAILURE
# =============================================================================

# Rollback function for install.sh — reverts any changes made during installation
# Usage: rollback_installation <install_log_file>
rollback_installation() {
    local install_log="$1"
    local error_message="${2:-Installation failed}"

    log_error "ROLLBACK: ${error_message}"

    if [[ ! -f "$install_log" ]]; then
        log_error "No installation log found; manual cleanup required"
        echo_error ""
        echo_error "=========================================="
        echo_error "  INSTALLATION FAILED"
        echo_error "=========================================="
        echo_error ""
        echo_error "${error_message}"
        echo_error ""
        echo_error "Manual cleanup may be required."
        echo_error "Check: ${LOG_FILE}"
        return 1
    fi

    echo_warning ""
    echo_warning "Rolling back installation..."
    echo_warning ""

    # Read the install log and reverse operations (reverse order)
    local operations=()
    while IFS= read -r line; do
        operations+=("$line")
    done < "$install_log"

    # Process in reverse
    local i
    for (( i=${#operations[@]}-1; i>=0; i-- )); do
        local op="${operations[$i]}"

        case "$op" in
            file:*)
                local file_path="${op#file:}"
                if [[ -f "$file_path" ]]; then
                    rm -f "$file_path" 2>/dev/null || true
                    log_debug "Rollback: removed file ${file_path}"
                fi
                ;;
            symlink:*)
                local link_path="${op#symlink:}"
                if [[ -L "$link_path" ]]; then
                    rm -f "$link_path" 2>/dev/null || true
                    log_debug "Rollback: removed symlink ${link_path}"
                fi
                ;;
            dir:*)
                local dir_path="${op#dir:}"
                if [[ -d "$dir_path" ]]; then
                    rmdir "$dir_path" 2>/dev/null || true
                    log_debug "Rollback: removed directory ${dir_path}"
                fi
                ;;
            systemd_enable:*)
                local unit="${op#systemd_enable:}"
                systemctl disable "$unit" 2>/dev/null || true
                log_debug "Rollback: disabled systemd unit ${unit}"
                ;;
            systemd_start:*)
                local unit="${op#systemd_start:}"
                systemctl stop "$unit" 2>/dev/null || true
                log_debug "Rollback: stopped systemd unit ${unit}"
                ;;
            *)
                log_debug "Rollback: unknown operation ${op}"
                ;;
        esac
    done

    # Restore backup if one was created
    if [[ -n "${BACKUP_PATH:-}" ]] && [[ -d "$BACKUP_PATH" ]]; then
        log_info "Restoring backup from ${BACKUP_PATH}..."
        restore_letsencrypt "$BACKUP_PATH" || true
    fi

    echo_warning "Rollback completed."
    echo_error ""
    echo_error "=========================================="
    echo_error "  INSTALLATION FAILED — ROLLED BACK"
    echo_error "=========================================="
    echo_error ""
    echo_error "${error_message}"
    echo_error ""
    echo_error "Please check the logs and try again."
    echo_error "Log: ${LOG_FILE}"
    echo_error ""

    return 1
}

# =============================================================================
# BACKUP VERIFICATION
# =============================================================================

# Verify backup integrity
verify_backup() {
    local backup_path="$1"

    if [[ ! -d "$backup_path" ]]; then
        echo_error "Backup path does not exist: ${backup_path}"
        return 1
    fi

    local issues=0

    # Check required directories exist in backup
    if [[ -d "${backup_path}/letsencrypt" ]]; then
        local check_path="${backup_path}/letsencrypt"
    elif [[ -d "${backup_path}/etc/letsencrypt" ]]; then
        local check_path="${backup_path}/etc/letsencrypt"
    else
        check_path="$backup_path"
    fi

    if [[ ! -d "${check_path}/live" ]]; then
        log_warning "Backup missing 'live' directory: ${check_path}/live"
        issues=$((issues + 1))
    fi

    if [[ ! -d "${check_path}/renewal" ]]; then
        log_warning "Backup missing 'renewal' directory: ${check_path}/renewal"
        issues=$((issues + 1))
    fi

    # Check for private key (critical)
    # private keys are in archive/ or live/ symlinked
    if [[ -d "${check_path}/archive" ]]; then
        local privkey_count
        privkey_count="$(find "${check_path}/archive" -name 'privkey*.pem' 2>/dev/null | wc -l)"
        if [[ $privkey_count -eq 0 ]]; then
            log_warning "No private keys found in backup archive"
            issues=$((issues + 1))
        fi
    fi

    if [[ $issues -eq 0 ]]; then
        echo_success "Backup verification passed: integrity OK"
        return 0
    else
        log_warning "Backup verification found ${issues} issue(s)"
        return 1
    fi
}