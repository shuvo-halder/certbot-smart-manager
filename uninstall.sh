#!/bin/bash
# =============================================================================
# certbot-smart-manager — Uninstaller
# =============================================================================
# URL: https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/uninstall.sh
# =============================================================================
#
# Usage:
#   curl -sSL https://your-domain/uninstall.sh | sudo bash
#   wget -O - https://your-domain/uninstall.sh | sudo bash
#   sudo ./uninstall.sh
#
# This script:
#   - Stops and disables systemd timer + service
#   - Removes systemd unit files and reloads daemon
#   - Removes installed files: symlink, library, config, logs
#   - Cleans up cron entries (both standalone file and crontab)
#   - Optionally removes backup directory (asks user)
#   - Is fully idempotent (safe to run multiple times)
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONSTANTS
# =============================================================================
VERSION="1.0.0"
PROJECT_NAME="certbot-smart-manager"
SCRIPT_NAME="ssl-manager"

# Installation paths (must match install.sh)
LIB_DEST="/usr/local/lib/${PROJECT_NAME}"
MODULES_DEST="${LIB_DEST}/modules"
BIN_DEST="/usr/local/bin"
CONFIG_DIR="/etc/${PROJECT_NAME}"
LOG_FILE="/var/log/${PROJECT_NAME}.log"
LOCK_FILE="/var/lock/${PROJECT_NAME}.lock"
BACKUP_DIR="/var/backups/${PROJECT_NAME}"
SYSTEMD_DIR="/etc/systemd/system"
CRON_DIR="/etc/cron.d"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

echo_info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
echo_success() { printf '\033[0;32m[OK]\033[0m   %s\n' "$*"; }
echo_warning() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
echo_error()   { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; }
echo_bold()    { printf '\033[1m%s\033[0m\n' "$*"; }

# A separator line for visual clarity
separator() {
    printf '----------------------------------------\n'
}

# Utility: prompt yes/no (default: no)
# Returns 0 for yes, 1 for no
prompt_yes_no() {
    local prompt="$1"
    local response
    printf '%s [y/N]: ' "$prompt"
    read -r response
    case "$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# =============================================================================
# UNINSTALL STEPS
# =============================================================================

# Step 1: Stop and disable systemd service + timer
cleanup_systemd() {
    echo_info "Cleaning up systemd service and timer..."

    # Helper: stop and disable a systemd unit if it exists
    _stop_disable_unit() {
        local unit="$1"
        local unit_file="${SYSTEMD_DIR}/${unit}"

        # Only act if the unit file exists
        if [[ -f "$unit_file" ]]; then
            # Stop if running
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                systemctl stop "$unit" 2>/dev/null || true
                echo_info "  Stopped: ${unit}"
            fi

            # Disable if enabled
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                systemctl disable "$unit" 2>/dev/null || true
                echo_info "  Disabled: ${unit}"
            fi

            # Remove unit file
            rm -f "$unit_file"
            echo_success "  Removed: ${unit_file}"
        else
            echo_info "  Not found (already clean): ${unit}"
        fi
    }

    _stop_disable_unit "${PROJECT_NAME}.timer"
    _stop_disable_unit "${PROJECT_NAME}.service"

    # Reload systemd daemon to forget removed units
    if command_exists systemctl; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true
        echo_info "Systemd daemon reloaded and failed state reset."
    fi

    echo_success "Systemd cleanup complete."
}

# Step 2: Remove the symlink
remove_symlink() {
    echo_info "Removing symlink..."

    if [[ -L "${BIN_DEST}/${SCRIPT_NAME}" ]] || [[ -f "${BIN_DEST}/${SCRIPT_NAME}" ]]; then
        rm -f "${BIN_DEST}/${SCRIPT_NAME}"
        echo_success "Symlink removed: ${BIN_DEST}/${SCRIPT_NAME}"
    else
        echo_info "Symlink not found (already clean): ${BIN_DEST}/${SCRIPT_NAME}"
    fi
}

# Step 3: Remove the library directory (scripts + modules)
remove_library() {
    echo_info "Removing library directory..."

    if [[ -d "$LIB_DEST" ]]; then
        rm -rf "$LIB_DEST"
        echo_success "Library removed: ${LIB_DEST}/"
    else
        echo_info "Library not found (already clean): ${LIB_DEST}/"
    fi
}

# Step 4: Remove the configuration directory
remove_config() {
    echo_info "Removing configuration directory..."

    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        echo_success "Configuration removed: ${CONFIG_DIR}/"
    else
        echo_info "Configuration not found (already clean): ${CONFIG_DIR}/"
    fi
}

# Step 5: Remove the log file
remove_log() {
    echo_info "Removing log file..."

    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        echo_success "Log file removed: ${LOG_FILE}"
    else
        echo_info "Log file not found (already clean): ${LOG_FILE}"
    fi

    # Also remove rotated logs if any exist
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    if [[ -d "$log_dir" ]]; then
        local rotated_logs
        rotated_logs="$(ls -1 "${log_dir}/${PROJECT_NAME}.log"* 2>/dev/null || true)"
        if [[ -n "$rotated_logs" ]]; then
            rm -f "${log_dir}/${PROJECT_NAME}.log"*
            echo_info "  Rotated logs also cleaned from: ${log_dir}/"
        fi
        # Remove log directory if empty (never remove /var/log itself)
        if [[ "$log_dir" != "/var/log" ]]; then
            rmdir "$log_dir" 2>/dev/null || true
        fi
    fi
}

# Step 6: Remove lock file
remove_lock() {
    echo_info "Removing lock file..."

    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        echo_success "Lock file removed: ${LOCK_FILE}"
    else
        echo_info "Lock file not found (already clean): ${LOCK_FILE}"
    fi

    # Remove lock directory if empty
    local lock_dir
    lock_dir="$(dirname "$LOCK_FILE")"
    if [[ -d "$lock_dir" ]] && [[ "$lock_dir" != "/var/lock" ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
}

# Step 7: Clean up cron entries
cleanup_cron() {
    echo_info "Cleaning up cron entries..."

    local cleaned=0

    # 1) Check for a dedicated cron file
    if [[ -f "${CRON_DIR}/${PROJECT_NAME}" ]]; then
        rm -f "${CRON_DIR}/${PROJECT_NAME}"
        echo_success "  Cron file removed: ${CRON_DIR}/${PROJECT_NAME}"
        cleaned=1
    fi

    # 2) Check crontab for any certbot-smart-manager entries
    if crontab -l 2>/dev/null | grep -qF "${SCRIPT_NAME} --auto" 2>/dev/null; then
        # Remove lines matching our cron entry
        (crontab -l 2>/dev/null || true) | grep -vF "${SCRIPT_NAME} --auto" | crontab - 2>/dev/null || true
        echo_success "  Crontab entry removed (for ${SCRIPT_NAME} --auto)."
        cleaned=1
    fi

    if [[ $cleaned -eq 0 ]]; then
        echo_info "  No cron entries found (already clean)."
    fi

    echo_success "Cron cleanup complete."
}

# Step 8: Optionally remove backup directory
remove_backups() {
    echo ""
    echo_info "Backup directory found: ${BACKUP_DIR}/"

    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_size
        backup_size="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
        echo_info "  Current size: ${backup_size}"
        echo ""

        if prompt_yes_no "Do you want to DELETE the backup directory?"; then
            rm -rf "$BACKUP_DIR"
            echo_success "Backup directory removed: ${BACKUP_DIR}/"
        else
            echo_info "Backup directory preserved: ${BACKUP_DIR}/"
        fi
    else
        echo_info "Backup directory not found (already clean): ${BACKUP_DIR}/"
    fi
}

# Step 9: Final summary and verification
verify_uninstall() {
    echo_info "Verifying uninstall..."

    local errors=0

    # Check symlink gone
    if [[ -L "${BIN_DEST}/${SCRIPT_NAME}" ]] || [[ -f "${BIN_DEST}/${SCRIPT_NAME}" ]]; then
        echo_warning "  Symlink still exists: ${BIN_DEST}/${SCRIPT_NAME}"
        errors=$((errors + 1))
    fi

    # Check library directory gone
    if [[ -d "$LIB_DEST" ]]; then
        echo_warning "  Library directory still exists: ${LIB_DEST}/"
        errors=$((errors + 1))
    fi

    # Check config directory gone
    if [[ -d "$CONFIG_DIR" ]]; then
        echo_warning "  Config directory still exists: ${CONFIG_DIR}/"
        errors=$((errors + 1))
    fi

    # Check systemd units gone
    if [[ -f "${SYSTEMD_DIR}/${PROJECT_NAME}.service" ]]; then
        echo_warning "  Systemd service still exists: ${PROJECT_NAME}.service"
        errors=$((errors + 1))
    fi
    if [[ -f "${SYSTEMD_DIR}/${PROJECT_NAME}.timer" ]]; then
        echo_warning "  Systemd timer still exists: ${PROJECT_NAME}.timer"
        errors=$((errors + 1))
    fi

    if [[ $errors -eq 0 ]]; then
        echo_success "All traces removed successfully."
    else
        echo_warning "Found ${errors} leftover(s) that could not be removed."
    fi

    return $errors
}

# =============================================================================
# CHECK DEPENDENCIES
# =============================================================================

# Check if a command is available
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# MAIN UNINSTALLATION FLOW
# =============================================================================

main() {
    echo_bold ""
    echo_bold "========================================"
    echo_bold "  ${PROJECT_NAME} v${VERSION}"
    echo_bold "  Uninstaller"
    echo_bold "========================================"
    echo ""

    # -----------------------------------------------------------------------
    # 1. Root check
    # -----------------------------------------------------------------------
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo_error "This script must be run as root."
        echo_error "Usage: curl -sSL https://your-domain/uninstall.sh | sudo bash"
        exit 1
    fi
    echo_success "Running as root."

    # -----------------------------------------------------------------------
    # 2. Confirmation prompt
    # -----------------------------------------------------------------------
    echo ""
    echo_warning "This will completely remove ${PROJECT_NAME} from your system."
    echo_warning "The following will be deleted:"
    echo "  - ${BIN_DEST}/${SCRIPT_NAME}        (symlink)"
    echo "  - ${LIB_DEST}/                      (library & modules)"
    echo "  - ${CONFIG_DIR}/                    (configuration)"
    echo "  - ${LOG_FILE}                       (log file)"
    echo "  - ${LOCK_FILE}                      (lock file)"
    echo "  - systemd units: ${PROJECT_NAME}.service, .timer"
    echo "  - cron entries for ${SCRIPT_NAME}"
    echo ""
    echo_info "The backup directory (${BACKUP_DIR}/) will be handled separately."

    echo ""
    if ! prompt_yes_no "Proceed with uninstall?"; then
        echo_info "Uninstall cancelled by user. No changes were made."
        exit 0
    fi
    echo ""

    # -----------------------------------------------------------------------
    # 3. Execute uninstall steps
    # -----------------------------------------------------------------------
    echo_bold "--- Step 1/8: Systemd Cleanup ---"
    cleanup_systemd
    separator

    echo_bold "--- Step 2/8: Remove Symlink ---"
    remove_symlink
    separator

    echo_bold "--- Step 3/8: Remove Library ---"
    remove_library
    separator

    echo_bold "--- Step 4/8: Remove Configuration ---"
    remove_config
    separator

    echo_bold "--- Step 5/8: Remove Log File ---"
    remove_log
    separator

    echo_bold "--- Step 6/8: Remove Lock File ---"
    remove_lock
    separator

    echo_bold "--- Step 7/8: Cron Cleanup ---"
    cleanup_cron
    separator

    echo_bold "--- Step 8/8: Backup Directory ---"
    remove_backups
    separator

    # -----------------------------------------------------------------------
    # 4. Verification
    # -----------------------------------------------------------------------
    echo ""
    echo_bold "=== Verification ==="
    verify_uninstall

    # -----------------------------------------------------------------------
    # 5. Final message
    # -----------------------------------------------------------------------
    echo ""
    echo_bold "========================================"
    echo_bold "  ${PROJECT_NAME} v${VERSION}"
    echo_bold "  Uninstall Complete!"
    echo_bold "========================================"
    echo ""

    if [[ -d "$BACKUP_DIR" ]]; then
        echo_info "Note: Backup directory preserved at: ${BACKUP_DIR}/"
        echo_info "      Remove manually if no longer needed:"
        echo_info "      sudo rm -rf ${BACKUP_DIR}"
        echo ""
    fi

    echo_info "Thank you for using ${PROJECT_NAME}."
    echo_info "If you'd like to reinstall, run the installer again."
    echo ""
}

# =============================================================================
# RUN
# =============================================================================
main "$@"