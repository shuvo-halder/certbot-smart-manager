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

# Export globally so sourced modules can rely on them
export LOG_FILE LOCK_FILE BACKUP_DIR BACKUP_ENABLED
export BACKUP_RETENTION_DAYS THRESHOLD_DAYS CRITICAL_THRESHOLD_DAYS
export LOG_LEVEL NOTIFICATION_METHOD

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
            exit 1
        fi
    fi
done

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
  --force-renew      Force renewal of all certificates
  --dry-run          Perform a dry-run renewal
  --install          Interactive certificate installation
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
  ssl-manager --configure        Configure notification settings
EOF
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Auto mode — scan + renew certificates that need it, then exit
run_auto_mode() {
    log_info "Starting automatic certificate check..."

    if ! acquire_lock; then
        log_warning "Could not acquire lock; another instance may be running."
        exit 0
    fi

    detect_os
    detect_web_server
    detect_firewall

    if ! command_exists certbot; then
        log_error "certbot is not installed. Run: ssl-manager --install-deps"
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
    fi

    release_lock
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
        echo_info "  7) Configure email notifications"
        echo_info "  8) Create backup"
        echo_info "  9) List backups"
        echo_info " 10) Force renew all certificates"
        echo_info " 11) Configure renewal threshold"
        echo_info "  0) Exit"
        echo ""
        printf "Enter choice [0-11]: "
        read -r choice

        case "${choice:-0}" in
            1)
                echo ""
                display_certificates_table
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            2)
                check_expiry_status
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            3)
                acquire_lock || {
                    printf "Press Enter to continue..."
                    read -r
                    continue
                }
                detect_os
                detect_web_server
                detect_firewall
                renew_all_certificates
                release_lock
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            4)
                acquire_lock || {
                    printf "Press Enter to continue..."
                    read -r
                    continue
                }
                install_new_certificate_interactive
                release_lock
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            5)
                dry_run_renewal
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            6)
                view_logs
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            7)
                configure_notifications_interactive
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            8)
                require_root
                acquire_lock || {
                    printf "Press Enter to continue..."
                    read -r
                    continue
                }
                backup_letsencrypt
                release_lock
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            9)
                list_backups
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            10)
                acquire_lock || {
                    printf "Press Enter to continue..."
                    read -r
                    continue
                }
                detect_os
                detect_web_server
                detect_firewall
                force_renew_all
                release_lock
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            11)
                configure_threshold_interactive
                echo ""
                printf "Press Enter to continue..."
                read -r
                ;;
            0)
                echo_info "Exiting."
                echo ""
                exit 0
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
    echo_bold ""
    echo_bold "========================================"
    echo_bold "    Configure Renewal Threshold"
    echo_bold "========================================"
    echo ""
    echo_info "Current threshold: ${THRESHOLD_DAYS:-30} days"
    echo_info "Current critical threshold: ${CRITICAL_THRESHOLD_DAYS:-7} days"
    echo ""
    echo_info "Enter new renewal threshold in days (default: 30):"
    printf "> "
    read -r new_threshold
    new_threshold="${new_threshold:-30}"

    if validate_positive_int "$new_threshold"; then
        THRESHOLD_DAYS="$new_threshold"
        _update_config_value "$CONFIG_FILE" "THRESHOLD_DAYS" "$THRESHOLD_DAYS"
        echo_success "Renewal threshold set to ${THRESHOLD_DAYS} days"
    else
        echo_error "Invalid value. Must be a positive integer."
    fi

    echo ""
    echo_info "Enter new critical threshold in days (default: 7):"
    printf "> "
    read -r new_critical
    new_critical="${new_critical:-7}"

    if validate_positive_int "$new_critical"; then
        CRITICAL_THRESHOLD_DAYS="$new_critical"
        _update_config_value "$CONFIG_FILE" "CRITICAL_THRESHOLD_DAYS" "$CRITICAL_THRESHOLD_DAYS"
        echo_success "Critical threshold set to ${CRITICAL_THRESHOLD_DAYS} days"
    else
        echo_error "Invalid value. Must be a positive integer."
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
            detect_os
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
            if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
                backup_letsencrypt || true
            fi
            renew_all_certificates
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
        dry_run)
            require_root
            detect_web_server
            detect_firewall
            dry_run_renewal
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
            view_logs
            ;;
        configure)
            require_root
            configure_notifications_interactive
            ;;
        backup)
            require_root
            backup_letsencrypt
            ;;
        list_backups)
            list_backups
            ;;
        restore)
            require_root
            if [[ -z "${RESTORE_ARG:-}" ]]; then
                echo_error "Error: --restore requires a backup path or timestamp"
                exit 1
            fi
            restore_letsencrypt "$RESTORE_ARG"
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