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
        chown root:root "$backup_dir"
    fi

    log_info "Creating backup of ${letsencrypt_dir} to ${backup_path}..."

    # Use cp -a for a complete copy (preserves permissions, symlinks, timestamps)
    cp -a "$letsencrypt_dir" "$backup_path" 2>/dev/null || {
        log_error "Backup failed: unable to copy ${letsencrypt_dir}"
        return 1
    }

    # Also create a compressed archive for portability
    backup_file="${backup_dir}/letsencrypt-${timestamp}.tar.gz"
    tar -czf "$backup_file" -C /etc letsencrypt 2>/dev/null || {
        log_warning "Failed to create compressed backup archive"
        # The directory copy still exists, so it's not a fatal error
    }

    # Apply secure permissions to backup
    chmod -R 600 "$backup_file" 2>/dev/null || true

    # Store the backup path for potential rollback
    BACKUP_TIMESTAMP="$timestamp"
    BACKUP_PATH="$backup_path"

    log_success "Backup created: ${backup_path}"
    log_debug "Compressed archive: ${backup_file}"

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

    # Determine if this is a timestamp or a full path
    if [[ -d "$restore_source" ]]; then
        restore_path="$restore_source"
    elif [[ -d "${backup_dir}/${restore_source}" ]]; then
        restore_path="${backup_dir}/${restore_source}"
    elif [[ -f "$restore_source" && "$restore_source" == *.tar.gz ]]; then
        # Restore from compressed archive
        log_info "Restoring from archive: ${restore_source}"
        tar -xzf "$restore_source" -C / 2>/dev/null || {
            log_error "Failed to restore from archive: ${restore_source}"
            return 1
        }
        log_success "Restored from archive: ${restore_source}"
        return 0
    else
        log_error "Backup not found: ${restore_source}"
        echo_error "Available backups:"
        list_backups
        return 1
    fi

    if [[ ! -d "$restore_path" ]]; then
        log_error "Backup directory not found: ${restore_path}"
        return 1
    fi

    log_warning "Restoring ${letsencrypt_dir} from ${restore_path}..."

    # Verify the backup contains expected content
    if [[ ! -f "${restore_path}/letsencrypt/renewal" ]] && [[ ! -d "${restore_path}/letsencrypt/renewal" ]]; then
        # Check if the backup is structured as /etc/letsencrypt/ or just letsencrypt/
        if [[ -d "${restore_path}/renewal" ]]; then
            # Backup is structured as letsencrypt/ content directly
            log_debug "Detected backup structure: content of /etc/letsencrypt/"
        elif [[ -d "${restore_path}/etc/letsencrypt" ]]; then
            # Backup includes full path
            log_debug "Detected backup structure: full path /etc/letsencrypt/"
            restore_path="${restore_path}/etc"
        else
            log_error "Invalid backup structure at: ${restore_path}"
            return 1
        fi
    fi

    # Create a backup of current state before restore (safety net)
    local pre_restore_backup
    pre_restore_backup="${backup_dir}/pre_restore_$(date '+%Y%m%d_%H%M%S')"
    if [[ -d "$letsencrypt_dir" ]]; then
        cp -a "$letsencrypt_dir" "$pre_restore_backup" 2>/dev/null || true
        log_warning "Pre-restore backup saved to: ${pre_restore_backup}"
    fi

    # Perform the restore
    rm -rf "$letsencrypt_dir" 2>/dev/null || true
    cp -a "${restore_path}/letsencrypt" /etc/ 2>/dev/null || {
        log_error "Restore failed: unable to copy from ${restore_path}"
        return 1
    }

    # Restore SELinux context if SELinux is enabled
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$letsencrypt_dir" 2>/dev/null || true
    fi

    log_success "Restore completed from: ${restore_path}"

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