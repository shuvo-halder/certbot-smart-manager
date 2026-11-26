#!/bin/bash
# =============================================================================
# certbot-smart-manager — Main Script
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/certbot-smart-manager.sh
# Symlink: /usr/local/bin/ssl-manager -> this script
# =============================================================================
#
# Smart SSL certificate management for Let's Encrypt / Certbot.
# Features: auto-renewal, expiry monitoring, notifications, interactive menu.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# VERSION
# =============================================================================
VERSION="1.0.0"
SCRIPT_NAME="certbot-smart-manager"

# =============================================================================
# DEFAULT CONFIGURATION PATHS
# =============================================================================
CONFIG_FILE="${CONFIG_FILE:-/etc/certbot-smart-manager/certbot-smart.conf}"
LIB_DIR="/usr/local/lib/certbot-smart-manager"
MODULES_DIR="${LIB_DIR}/modules"

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# =============================================================================
# GLOBAL DEFAULTS (applied after config load, before module loading)
# =============================================================================
# These defaults ensure all referenced variables are defined before modules
# are sourced, preventing "unbound variable" errors under set -u.
LOG_FILE="${LOG_FILE:-/var/log/certbot-smart-manager.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/certbot-smart-manager.lock}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/certbot-smart-manager}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
THRESHOLD_DAYS="${THRESHOLD_DAYS:-30}"
CRITICAL_THRESHOLD_DAYS="${CRITICAL_THRESHOLD_DAYS:-7}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
NOTIFICATION_METHOD="${NOTIFICATION_METHOD:-console}"
STATE_DIR="${STATE_DIR:-/var/lib/certbot-smart-manager}"

# Export globally so sourced modules can rely on them
export LOG_FILE LOCK_FILE BACKUP_DIR BACKUP_ENABLED
export BACKUP_RETENTION_DAYS THRESHOLD_DAYS CRITICAL_THRESHOLD_DAYS
export LOG_LEVEL NOTIFICATION_METHOD STATE_DIR

LOCK_HELD=false

# =============================================================================
# LOAD MODULES
# =============================================================================
# Each module sets its own set -Eeuo pipefail, so loading order is safe

# Order matters: utils first, then dependencies
_module_list=(
    "utils.sh"
    "server-detection.sh"
    "certificate-functions.sh"
    "notifications.sh"
    "backup-restore.sh"
)

for _module in "${_module_list[@]}"; do
    _module_path="${MODULES_DIR}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck disable=SC1090
        source "$_module_path"
    else
        # Fallback: check relative to script location
        _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _module_path="${_script_dir}/modules/${_module}"
        if [[ -f "$_module_path" ]]; then
            # shellcheck disable=SC1090
            source "$_module_path"
        else
            printf '[%s] ERROR: Module not found: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_module" >&2
            { printf '[%s] ERROR: Module not found: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_module" >> "$LOG_FILE"; } 2>/dev/null || true
            exit 1
        fi
    fi
done

# =============================================================================
# EXIT HANDLING
# =============================================================================
# One single trap for the whole process: on any exit (normal, error, Ctrl-C,
# SIGTERM) close firewall ports we opened and release the lock.
_cleanup_on_exit() {
    local rc=$?
    trap - EXIT
    close_firewall_ports 2>/dev/null || true
    release_lock 2>/dev/null || true
    exit "$rc"
}
trap _cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# CLI ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION}

Usage: ssl-manager [OPTIONS]

Options:
  --auto             Run in automatic mode (scan + renew, no interaction)
  --scan             Scan and display certificates
  --check            Check expiry status
  --renew            Renew certificates that need renewal
  --force-renew      Force renewal of all automatic certificates
  --renew-cert NAME  Renew one certificate now (interactive for manual/DNS certs)
  --dry-run          Perform a dry-run renewal
  --install          Request a certificate for a new domain (interactive)
  --view-logs        Display the log file
  --configure        Configure notifications
  --backup           Create a backup of /etc/letsencrypt/
  --list-backups     List available backups
  --restore BACKUP   Restore from a backup
  --help, -h         Show this help message
  --version, -V      Show version information

Examples:
  ssl-manager                    Interactive menu
  ssl-manager --auto             Automatic renewal (for cron/systemd)
  ssl-manager --scan             Scan certificates
  ssl-manager --dry-run          Test renewal
  ssl-manager --force-renew      Force renew all certificates
  ssl-manager --renew-cert example.com   Renew one certificate (e.g. a manual DNS one)
  ssl-manager --configure        Configure notification settings
EOF
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Auto mode — scan + renew certificates that need it, then exit
run_auto_mode() {
    local rc=0

    log_info "Starting automatic certificate check..."

    if ! acquire_lock; then
        log_warning "Could not acquire lock; another instance may be running."
        exit 0
    fi

    detect_os
    detect_web_server
    detect_firewall

    if ! command_exists certbot; then
        log_error "certbot is not installed. Install it (e.g. re-run install.sh) and try again."
        send_error_notification "certbot is not installed on $(hostname 2>/dev/null || echo 'this host'); automatic renewal cannot run."
        exit 1
    fi

    # Backup before making changes
    if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
        backup_letsencrypt || log_warning "Backup skipped"
    fi

    # Renew certificates
    if renew_all_certificates; then
        log_info "Auto-mode completed successfully"
    else
        log_warning "Auto-mode completed with failures (check notifications)"
        rc=1
    fi

    release_lock
    # Non-zero exit so `systemctl status` / cron show the failure
    return $rc
}

# Pause until the user presses Enter (EOF-safe)
_pause() {
    echo ""
    printf "Press Enter to continue..."
    read -r _ || true
}

# Run a menu action that needs the lock. Failures are reported but never
# terminate the interactive menu (set -e would otherwise exit the script).
_menu_locked() {
    if ! acquire_lock; then
        return 0
    fi
    "$@" || echo_error "Operation failed (see ${LOG_FILE})."
    release_lock
}

# Run a menu action without the lock; failures do not exit the menu
_menu_run() {
    "$@" || echo_error "Operation failed (see ${LOG_FILE})."
}

# Renew with a pre-renewal backup (shared by the menu and --renew)
renew_with_backup() {
    if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
        backup_letsencrypt || log_warning "Backup skipped"
    fi
    renew_all_certificates
}

# Menu helper: ask which certificate to renew
_renew_one_interactive() {
    local name
    display_certificates_table
    printf "Certificate name to renew: "
    read -r name || return 0
    name="$(trim "$name")"
    [[ -z "$name" ]] && return 0
    renew_single_certificate "$name"
}

# Interactive menu
show_menu() {
    local choice

    while true; do
        clear 2>/dev/null || true
        echo_bold ""
        echo_bold "========================================"
        echo_bold "    ${SCRIPT_NAME} v${VERSION}"
        echo_bold "    SSL Certificate Manager"
        echo_bold "========================================"
        echo ""
        echo_info "  1) Scan existing certificates"
        echo_info "  2) Check expiry status"
        echo_info "  3) Renew certificates"
        echo_info "  4) Install new SSL certificate"
        echo_info "  5) Dry run renewal"
        echo_info "  6) View logs"
        echo_info "  7) Configure notifications"
        echo_info "  8) Create backup"
        echo_info "  9) List backups"
        echo_info " 10) Force renew all certificates"
        echo_info " 11) Configure renewal threshold"
        echo_info " 12) Renew one certificate (manual/DNS certificates)"
        echo_info "  0) Exit"
        echo ""
        printf "Enter choice [0-12]: "
        if ! read -r choice; then
            # EOF (Ctrl-D)
            echo ""
            exit 0
        fi
        choice="$(trim "$choice")"

        case "$choice" in
            1)  echo ""; _menu_run display_certificates_table; _pause ;;
            2)  _menu_run check_expiry_status; _pause ;;
            3)  _menu_locked renew_with_backup; _pause ;;
            4)  _menu_locked install_new_certificate_interactive; _pause ;;
            5)  _menu_locked dry_run_renewal; _pause ;;
            6)  _menu_run view_logs; _pause ;;
            7)  _menu_run configure_notifications_interactive; _pause ;;
            8)  _menu_locked backup_letsencrypt; _pause ;;
            9)  _menu_run list_backups; _pause ;;
            10) _menu_locked force_renew_all; _pause ;;
            11) _menu_run configure_threshold_interactive; _pause ;;
            12) _menu_locked _renew_one_interactive; _pause ;;
            0)
                echo_info "Exiting."
                echo ""
                exit 0
                ;;
            "")
                ;;
            *)
                echo_error "Invalid choice: ${choice}"
                sleep 1
                ;;
        esac
    done
}

# View logs
view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo_info "Log file not found: ${LOG_FILE}"
        return 0
    fi

    local log_size
    log_size="$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")"

    echo_bold ""
    echo_bold "=== Log File: ${LOG_FILE} ==="
    echo_bold "=== Total Lines: ${log_size} ==="
    echo ""

    # Use tail or cat depending on log size
    if [[ "$log_size" -gt 100 ]]; then
        echo_info "Showing last 100 lines (use 'tail -f ${LOG_FILE}' for live view):"
        echo ""
        tail -n 100 "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi
    echo ""
}

# Interactive threshold configuration
configure_threshold_interactive() {
    local new_threshold new_critical

    echo_bold ""
    echo_bold "========================================"
    echo_bold "    Configure Renewal Threshold"
    echo_bold "========================================"
    echo ""
    echo_info "Current threshold: ${THRESHOLD_DAYS:-30} days"
    echo_info "Current critical threshold: ${CRITICAL_THRESHOLD_DAYS:-7} days"
    echo ""
    echo_info "Enter new renewal threshold in days (Enter = keep ${THRESHOLD_DAYS:-30}):"
    printf "> "
    read -r new_threshold || new_threshold=""
    new_threshold="$(trim "$new_threshold")"
    new_threshold="${new_threshold:-${THRESHOLD_DAYS:-30}}"

    # Let's Encrypt certificates are valid for 90 days
    if validate_positive_int "$new_threshold" && [[ "$new_threshold" -lt 90 ]]; then
        THRESHOLD_DAYS="$new_threshold"
        _update_config_value "$CONFIG_FILE" "THRESHOLD_DAYS" "$THRESHOLD_DAYS"
        echo_success "Renewal threshold set to ${THRESHOLD_DAYS} days"
    else
        echo_error "Invalid value. Must be an integer between 1 and 89."
    fi

    echo ""
    echo_info "Enter new critical threshold in days (Enter = keep ${CRITICAL_THRESHOLD_DAYS:-7}):"
    printf "> "
    read -r new_critical || new_critical=""
    new_critical="$(trim "$new_critical")"
    new_critical="${new_critical:-${CRITICAL_THRESHOLD_DAYS:-7}}"

    if validate_positive_int "$new_critical" && [[ "$new_critical" -lt "$THRESHOLD_DAYS" ]]; then
        CRITICAL_THRESHOLD_DAYS="$new_critical"
        _update_config_value "$CONFIG_FILE" "CRITICAL_THRESHOLD_DAYS" "$CRITICAL_THRESHOLD_DAYS"
        echo_success "Critical threshold set to ${CRITICAL_THRESHOLD_DAYS} days"
    else
        echo_error "Invalid value. Must be a positive integer smaller than the renewal threshold (${THRESHOLD_DAYS})."
    fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main() {
    local command=""

    # Parse command line arguments
    if [[ $# -gt 0 ]]; then
        case "${1:-}" in
            --auto|-a)
                command="auto"
                ;;
            --scan|-s)
                command="scan"
                ;;
            --check|-c)
                command="check"
                ;;
            --renew|-r)
                command="renew"
                ;;
            --force-renew|-f)
                command="force_renew"
                ;;
            --dry-run|-d)
                command="dry_run"
                ;;
            --install|-i)
                command="install"
                ;;
            --view-logs|-l)
                command="view_logs"
                ;;
            --configure|--config)
                command="configure"
                ;;
            --backup|-b)
                command="backup"
                ;;
            --list-backups)
                command="list_backups"
                ;;
            --renew-cert)
                if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
                    echo_error "Error: --renew-cert requires a certificate name (see: ssl-manager --scan)"
                    exit 1
                fi
                command="renew_cert"
                RENEW_CERT_ARG="$2"
                ;;
            --restore)
                if [[ $# -lt 2 ]]; then
                    echo_error "Error: --restore requires a backup path or timestamp"
                    echo ""
                    usage
                    exit 1
                fi
                command="restore"
                RESTORE_ARG="${2:-}"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-V)
                echo "${SCRIPT_NAME} v${VERSION}"
                exit 0
                ;;
            *)
                echo_error "Unknown option: ${1}"
                echo ""
                usage
                exit 1
                ;;
        esac
    else
        command="menu"
    fi

    # Execute command
    case "$command" in
        auto)
            require_root
            run_auto_mode
            ;;
        scan)
            require_root
            display_certificates_table
            ;;
        check)
            require_root
            check_expiry_status
            ;;
        renew)
            require_root
            acquire_lock || exit 1
            detect_os
            detect_web_server
            detect_firewall
            renew_with_backup
            release_lock
            ;;
        force_renew)
            require_root
            acquire_lock || exit 1
            detect_os
            detect_web_server
            detect_firewall
            force_renew_all
            release_lock
            ;;
        renew_cert)
            require_root
            acquire_lock || exit 1
            detect_os
            detect_web_server
            detect_firewall
            renew_single_certificate "$RENEW_CERT_ARG"
            release_lock
            ;;
        dry_run)
            require_root
            acquire_lock || exit 1
            detect_web_server
            detect_firewall
            dry_run_renewal
            release_lock
            ;;
        install)
            require_root
            acquire_lock || exit 1
            detect_os
            detect_web_server
            detect_firewall
            install_new_certificate_interactive
            release_lock
            ;;
        view_logs)
            # The log file is root-only (640 root:root)
            require_root
            view_logs
            ;;
        configure)
            require_root
            configure_notifications_interactive
            ;;
        backup)
            require_root
            acquire_lock || exit 1
            backup_letsencrypt
            release_lock
            ;;
        list_backups)
            # The backup directory is root-only (750)
            require_root
            list_backups
            ;;
        restore)
            require_root
            if [[ -z "${RESTORE_ARG:-}" ]]; then
                echo_error "Error: --restore requires a backup path or timestamp"
                exit 1
            fi
            acquire_lock || exit 1
            # Needed so the web server can be reloaded after the restore
            detect_web_server
            restore_letsencrypt "$RESTORE_ARG"
            release_lock
            ;;
        menu)
            require_root
            detect_os
            detect_web_server
            detect_firewall
            show_menu
            ;;
        *)
            echo_error "Internal error: unknown command '${command}'"
            exit 1
            ;;
    esac
}

# =============================================================================
# RUN
# =============================================================================
main "$@"