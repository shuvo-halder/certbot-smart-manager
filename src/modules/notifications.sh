#!/bin/bash
# =============================================================================
# certbot-smart-manager — Notifications Module
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/modules/notifications.sh
# =============================================================================
#
# Handles all notification methods: Email (SMTP), Console, Log, Telegram, Slack.
# Must be sourced after utils.sh.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NOTIFICATION FORMATTING
# =============================================================================

# Build a standardized notification message
# Usage: build_notification_message <domain> <expiry_date> <remaining_days> <reason>
build_notification_message() {
    local domain="$1"
    local expiry_date="$2"
    local remaining_days="$3"
    local reason="${4:-No specific reason provided}"

    cat <<EOF
========================================
WARNING: SSL Certificate Expiring Soon
========================================
Domain:        ${domain}
Expires:       ${expiry_date}
Remaining:     ${remaining_days} days
Status:        Automatic renewal required
Reason:        ${reason}

Action Required:
Please manually inspect DNS/web server configuration.

This notification was sent by certbot-smart-manager
========================================
EOF
}

# Build a failure notification message
# Usage: build_failure_message <domain> <expiry_date> <remaining_days>
build_failure_message() {
    local domain="$1"
    local expiry_date="$2"
    local remaining_days="$3"

    cat <<EOF
========================================
ALERT: SSL Certificate Renewal FAILED
========================================
Domain:        ${domain}
Expires:       ${expiry_date}
Remaining:     ${remaining_days} days
Status:        Automatic renewal FAILED

Action Required:
1. Check certbot logs: /var/log/letsencrypt/letsencrypt.log
2. Verify DNS records for the domain
3. Ensure ports 80 and 443 are accessible
4. Run: certbot renew --cert-name ${domain}

This notification was sent by certbot-smart-manager
========================================
EOF
}

# =============================================================================
# LOG NOTIFICATION
# =============================================================================

# Always logs a notification; this is the baseline method
notify_log() {
    local message="$1"
    local level="${2:-WARNING}"

    case "$level" in
        ERROR)   log_error   "$message" ;;
        WARNING) log_warning "$message" ;;
        SUCCESS) log_success "$message" ;;
        INFO)    log_info    "$message" ;;
        *)       log_info    "$message" ;;
    esac

    # Also append a separator line for readability
    printf -- '---\n' >> "$LOG_FILE"
}

# =============================================================================
# CONSOLE NOTIFICATION
# =============================================================================

# Send a message to all logged-in users via wall(1)
notify_console() {
    local message="$1"

    if command -v wall >/dev/null 2>&1; then
        printf '%s\n\n' "$message" | wall 2>/dev/null || true
        log_debug "Console notification sent via wall(1)"
    else
        # Fallback: write to /dev/console if available
        if [[ -w /dev/console ]]; then
            printf '%s\n' "$message" > /dev/console 2>/dev/null || true
            log_debug "Console notification sent to /dev/console"
        else
            log_warning "wall(1) not available and /dev/console not writable"
        fi
    fi
}

# =============================================================================
# EMAIL NOTIFICATION (SMTP)
# =============================================================================

# Send email notification using available tools (sendmail, mail, or curl to SMTP)
notify_email() {
    local message="$1"
    local subject="${2:-SSL Certificate Alert - certbot-smart-manager}"

    local smtp_server="${SMTP_SERVER:-}"
    local smtp_from="${SMTP_FROM:-}"
    local smtp_to="${SMTP_TO:-}"

    # If SMTP is not configured, try system mail command
    if [[ -z "$smtp_server" ]] || [[ -z "$smtp_to" ]]; then
        log_debug "SMTP not configured; trying system mail command"

        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$message" | mail -s "$subject" "$smtp_to" 2>/dev/null && {
                log_debug "Email sent via 'mail' command to ${smtp_to}"
                return 0
            } || {
                log_warning "Failed to send email via 'mail' command"
                return 1
            }
        elif command -v sendmail >/dev/null 2>&1; then
            {
                printf 'Subject: %s\n' "$subject"
                printf 'To: %s\n' "$smtp_to"
                printf 'From: %s\n' "${smtp_from:-root@$(hostname -f)}"
                printf 'Content-Type: text/plain; charset=UTF-8\n\n'
                printf '%s\n' "$message"
            } | sendmail -t 2>/dev/null && {
                log_debug "Email sent via sendmail to ${smtp_to}"
                return 0
            } || {
                log_warning "Failed to send email via sendmail"
                return 1
            }
        else
            log_warning "No email delivery method available (install 'mailutils' or 'sendmail')"
            return 1
        fi
    fi

    # SMTP via curl if configured
    if command -v curl >/dev/null 2>&1; then
        local smtp_port="${SMTP_PORT:-587}"
        local smtp_user="${SMTP_USER:-}"
        local smtp_pass="${SMTP_PASS:-}"
        local smtp_use_tls="${SMTP_USE_TLS:-true}"

        local curl_smtp_args=()
        curl_smtp_args+=("smtp://${smtp_server}:${smtp_port}")
        if [[ "$smtp_use_tls" == "true" ]]; then
            curl_smtp_args+=("--ssl-reqd")
        fi
        if [[ -n "$smtp_user" ]] && [[ -n "$smtp_pass" ]]; then
            curl_smtp_args+=("--user" "${smtp_user}:${smtp_pass}")
        fi
        curl_smtp_args+=("--mail-from" "${smtp_from:-${smtp_user}}")
        curl_smtp_args+=("--mail-rcpt" "$smtp_to")

        {
            printf 'From: %s\n' "${smtp_from:-${smtp_user}}"
            printf 'To: %s\n' "$smtp_to"
            printf 'Subject: %s\n' "$subject"
            printf 'Content-Type: text/plain; charset=UTF-8\n\n'
            printf '%s\n' "$message"
        } | curl "${curl_smtp_args[@]}" --upload-file - 2>/dev/null && {
            log_debug "Email sent via SMTP (${smtp_server}) to ${smtp_to}"
            return 0
        } || {
            log_warning "Failed to send email via SMTP (${smtp_server})"
            return 1
        }
    else
        log_warning "curl not available for SMTP delivery"
        return 1
    fi
}

# =============================================================================
# TELEGRAM NOTIFICATION
# =============================================================================

# Send notification via Telegram Bot API
notify_telegram() {
    local message="$1"

    local bot_token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$bot_token" ]] || [[ -z "$chat_id" ]]; then
        log_debug "Telegram not configured (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing)"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_warning "curl required for Telegram notifications"
        return 1
    fi

    local api_url="https://api.telegram.org/bot${bot_token}/sendMessage"
    local payload
    payload="$(printf '%s' "$message" | jq -Rs . 2>/dev/null || printf '"%s"' "$message")"

    curl -s -X POST "$api_url" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        -o /dev/null 2>/dev/null && {
        log_debug "Telegram notification sent to chat ${chat_id}"
        return 0
    } || {
        log_warning "Failed to send Telegram notification"
        return 1
    }
}

# =============================================================================
# SLACK NOTIFICATION
# =============================================================================

# Send notification via Slack Webhook
notify_slack() {
    local message="$1"

    local webhook_url="${SLACK_WEBHOOK_URL:-}"

    if [[ -z "$webhook_url" ]]; then
        log_debug "Slack not configured (SLACK_WEBHOOK_URL missing)"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_warning "curl required for Slack notifications"
        return 1
    fi

    # Escape message for JSON
    local escaped_message
    escaped_message="$(printf '%s' "$message" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"

    local payload
    payload="{\"text\":\"${escaped_message}\",\"mrkdwn\":true}"

    curl -s -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o /dev/null 2>/dev/null && {
        log_debug "Slack notification sent"
        return 0
    } || {
        log_warning "Failed to send Slack notification"
        return 1
    }
}

# =============================================================================
# DISPATCH NOTIFICATION
# =============================================================================

# Main dispatch function — routes notification to configured methods
# Usage: dispatch_notification <message> <level> [subject]
dispatch_notification() {
    local message="$1"
    local level="${2:-WARNING}"
    local subject="${3:-SSL Certificate Alert - certbot-smart-manager}"

    local method="${NOTIFICATION_METHOD:-console}"

    case "$method" in
        all)
            # Send via all available methods
            notify_log "$message" "$level"
            notify_console "$message" || true
            notify_email "$message" "$subject" || true
            notify_telegram "$message" || true
            notify_slack "$message" || true
            ;;
        email)
            notify_log "$message" "$level"
            notify_email "$message" "$subject" || {
                log_warning "Email notification failed; falling back to console"
                notify_console "$message" || true
            }
            ;;
        telegram)
            notify_log "$message" "$level"
            notify_telegram "$message" || {
                log_warning "Telegram notification failed; falling back to console"
                notify_console "$message" || true
            }
            ;;
        slack)
            notify_log "$message" "$level"
            notify_slack "$message" || {
                log_warning "Slack notification failed; falling back to console"
                notify_console "$message" || true
            }
            ;;
        console)
            notify_log "$message" "$level"
            notify_console "$message" || true
            ;;
        log|*)
            # Default: just log
            notify_log "$message" "$level"
            ;;
    esac
}

# =============================================================================
# SPECIFIC NOTIFICATION HELPERS
# =============================================================================

# Send notification about a failed renewal
send_renewal_failure_notification() {
    local cert_name="$1"
    local domains="$2"
    local expiry_date="$3"
    local remaining_days="$4"

    local message
    message="$(build_failure_message "$cert_name" "$expiry_date" "$remaining_days")"
    dispatch_notification "$message" "ERROR" "ALERT: SSL Renewal Failed - ${cert_name}"
}

# Send notification about a certificate expiring soon
send_expiry_warning_notification() {
    local cert_name="$1"
    local domains="$2"
    local expiry_date="$3"
    local remaining_days="$4"

    local message
    message="$(build_notification_message "$cert_name" "$expiry_date" "$remaining_days" "Certificate expiring in ${remaining_days} days")"
    dispatch_notification "$message" "WARNING" "WARNING: SSL Certificate Expiring - ${cert_name}"
}

# Send notification about successful renewal
send_renewal_success_notification() {
    local cert_name="$1"

    local message
    message="Certificate '${cert_name}' has been successfully renewed."
    dispatch_notification "$message" "SUCCESS" "SUCCESS: SSL Certificate Renewed - ${cert_name}"
}

# Send notification about a critical error
send_error_notification() {
    local error_message="$1"

    dispatch_notification "CRITICAL ERROR: ${error_message}" "ERROR" "CRITICAL: certbot-smart-manager Error"
}

# =============================================================================
# NOTIFICATION CONFIGURATION WIZARD
# =============================================================================

# Interactive wizard to configure email notifications
configure_notifications_interactive() {
    echo_bold ""
    echo_bold "========================================"
    echo_bold "    Configure Notifications"
    echo_bold "========================================"
    echo ""

    echo_info "Current notification method: ${NOTIFICATION_METHOD:-console}"
    echo ""

    echo_info "Select notification method:"
    echo "  1) Console (wall messages to logged-in users)"
    echo "  2) Email (SMTP)"
    echo "  3) Telegram"
    echo "  4) Slack"
    echo "  5) All methods"
    echo "  6) Log only"
    echo ""

    printf "Enter choice [1-6] (current: ${NOTIFICATION_METHOD:-console}): "
    read -r choice

    case "${choice:-0}" in
        1) NOTIFICATION_METHOD="console" ;;
        2) NOTIFICATION_METHOD="email" ;;
        3) NOTIFICATION_METHOD="telegram" ;;
        4) NOTIFICATION_METHOD="slack" ;;
        5) NOTIFICATION_METHOD="all" ;;
        6) NOTIFICATION_METHOD="log" ;;
        *)
            echo_info "Keeping current setting: ${NOTIFICATION_METHOD:-console}"
            return 0
            ;;
    esac

    echo ""

    case "$NOTIFICATION_METHOD" in
        email)
            echo_info "--- Email Configuration ---"
            printf "SMTP Server: "
            read -r SMTP_SERVER
            printf "SMTP Port [587]: "
            read -r smtp_port_input
            SMTP_PORT="${smtp_port_input:-587}"
            printf "SMTP Username: "
            read -r SMTP_USER
            printf "SMTP Password: "
            read -r -s SMTP_PASS
            echo ""
            printf "From Address: "
            read -r SMTP_FROM
            printf "To Address: "
            read -r SMTP_TO
            ;;
        telegram)
            echo_info "--- Telegram Configuration ---"
            printf "Bot Token: "
            read -r TELEGRAM_BOT_TOKEN
            printf "Chat ID: "
            read -r TELEGRAM_CHAT_ID
            ;;
        slack)
            echo_info "--- Slack Configuration ---"
            printf "Webhook URL: "
            read -r SLACK_WEBHOOK_URL
            ;;
        all)
            echo_info "--- Email Configuration ---"
            printf "SMTP Server: "
            read -r SMTP_SERVER
            printf "SMTP Port [587]: "
            read -r smtp_port_input
            SMTP_PORT="${smtp_port_input:-587}"
            printf "SMTP Username: "
            read -r SMTP_USER
            printf "SMTP Password: "
            read -r -s SMTP_PASS
            echo ""
            printf "From Address: "
            read -r SMTP_FROM
            printf "To Address: "
            read -r SMTP_TO
            echo ""
            echo_info "--- Telegram Configuration ---"
            printf "Bot Token: "
            read -r TELEGRAM_BOT_TOKEN
            printf "Chat ID: "
            read -r TELEGRAM_CHAT_ID
            echo ""
            echo_info "--- Slack Configuration ---"
            printf "Webhook URL: "
            read -r SLACK_WEBHOOK_URL
            ;;
    esac

    # Save configuration
    local config_file="${CONFIG_FILE:-/etc/certbot-smart-manager/certbot-smart.conf}"

    echo ""
    echo_info "Saving configuration to ${config_file}..."

    # Update or append configuration values
    _update_config_value "$config_file" "NOTIFICATION_METHOD" "$NOTIFICATION_METHOD"
    _update_config_value "$config_file" "SMTP_SERVER" "${SMTP_SERVER:-}"
    _update_config_value "$config_file" "SMTP_PORT" "${SMTP_PORT:-587}"
    _update_config_value "$config_file" "SMTP_USER" "${SMTP_USER:-}"
    _update_config_value "$config_file" "SMTP_FROM" "${SMTP_FROM:-}"
    _update_config_value "$config_file" "SMTP_TO" "${SMTP_TO:-}"
    _update_config_value "$config_file" "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN:-}"
    _update_config_value "$config_file" "TELEGRAM_CHAT_ID" "${TELEGRAM_CHAT_ID:-}"
    _update_config_value "$config_file" "SLACK_WEBHOOK_URL" "${SLACK_WEBHOOK_URL:-}"

    echo_success "Configuration saved!"

    # Test notification
    echo ""
    echo_info "Send a test notification? [Y/n]"
    printf "> "
    read -r test_choice
    test_choice="$(printf '%s' "$test_choice" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ "$test_choice" != "n" ]] && [[ "$test_choice" != "no" ]]; then
        echo_info "Sending test notification..."
        dispatch_notification "This is a test notification from certbot-smart-manager." "INFO" "Test Notification"
        echo_info "Test notification sent. Check your configured method."
    fi
}

# Update a single configuration value in the config file
_update_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        touch "$file"
    fi

    if grep -qE "^(# )?${key}=" "$file" 2>/dev/null; then
        # Update existing line (comment or uncommented)
        if grep -qE "^${key}=" "$file" 2>/dev/null; then
            # Line exists and is uncommented — update in place
            sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$file"
        else
            # Line is commented — uncomment and update
            sed -i "s/^# ${key}=.*/${key}=\"${value}\"/" "$file"
        fi
    else
        # Append new line
        printf '\n%s="%s"\n' "$key" "$value" >> "$file"
    fi

    # Apply secure permissions
    chmod 600 "$file" 2>/dev/null || true
    chown root:root "$file" 2>/dev/null || true
}