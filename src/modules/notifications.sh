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
    local log_file="${LOG_FILE:-/var/log/certbot-smart-manager.log}"
    printf -- '---\n' >> "$log_file"
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
# HELPERS
# =============================================================================

# Escape a string for use inside a double-quoted value of a curl config file
_curl_cfg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Escape a string for use inside a JSON string literal
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# =============================================================================
# EMAIL NOTIFICATION (SMTP)
# =============================================================================

# Send email notification: direct SMTP via curl if SMTP_SERVER is set,
# otherwise the system `mail` / `sendmail` commands.
notify_email() {
    local message="$1"
    local subject="${2:-SSL Certificate Alert - certbot-smart-manager}"

    local smtp_server="${SMTP_SERVER:-}"
    local smtp_from="${SMTP_FROM:-}"
    local smtp_to="${SMTP_TO:-}"

    if [[ -z "$smtp_to" ]]; then
        log_warning "Email notification skipped: SMTP_TO (recipient) is not configured"
        return 1
    fi

    # No SMTP server configured — use the local MTA
    if [[ -z "$smtp_server" ]]; then
        log_debug "SMTP_SERVER not configured; trying system mail command"

        if command -v mail >/dev/null 2>&1; then
            if printf '%s\n' "$message" | mail -s "$subject" "$smtp_to" 2>/dev/null; then
                log_debug "Email sent via 'mail' command to ${smtp_to}"
                return 0
            fi
            log_warning "Failed to send email via 'mail' command"
            return 1
        elif command -v sendmail >/dev/null 2>&1; then
            if {
                printf 'Subject: %s\n' "$subject"
                printf 'To: %s\n' "$smtp_to"
                printf 'From: %s\n' "${smtp_from:-root@$(hostname -f 2>/dev/null || hostname)}"
                printf 'Content-Type: text/plain; charset=UTF-8\n\n'
                printf '%s\n' "$message"
            } | sendmail -t 2>/dev/null; then
                log_debug "Email sent via sendmail to ${smtp_to}"
                return 0
            fi
            log_warning "Failed to send email via sendmail"
            return 1
        else
            log_warning "No email delivery method available (set SMTP_SERVER, or install 'mailutils' / 'sendmail')"
            return 1
        fi
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_warning "curl not available for SMTP delivery"
        return 1
    fi

    local smtp_port="${SMTP_PORT:-587}"
    local smtp_user="${SMTP_USER:-}"
    local smtp_pass="${SMTP_PASS:-}"
    local smtp_use_tls="${SMTP_USE_TLS:-true}"
    local mail_from="${smtp_from:-${smtp_user}}"

    # Port 465 = implicit TLS (smtps://); otherwise STARTTLS via --ssl-reqd
    local scheme="smtp"
    [[ "$smtp_port" == "465" ]] && scheme="smtps"

    local curl_args=(--silent --show-error --fail --url "${scheme}://${smtp_server}:${smtp_port}")
    if [[ "$smtp_use_tls" == "true" ]]; then
        curl_args+=(--ssl-reqd)
    fi
    curl_args+=(--mail-from "$mail_from" --mail-rcpt "$smtp_to" --upload-file -)

    # Credentials are passed through a curl config on a file descriptor, so
    # the SMTP password never appears in the process list (ps aux).
    local cred_cfg=""
    if [[ -n "$smtp_user" ]] && [[ -n "$smtp_pass" ]]; then
        cred_cfg="user = \"$(_curl_cfg_escape "${smtp_user}:${smtp_pass}")\""
    fi

    if {
        printf 'From: %s\r\n' "$mail_from"
        printf 'To: %s\r\n' "$smtp_to"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(LC_ALL=C date -R)"
        printf 'Content-Type: text/plain; charset=UTF-8\r\n\r\n'
        printf '%s\r\n' "$message"
    } | curl --config <(printf '%s\n' "$cred_cfg") "${curl_args[@]}" >/dev/null 2>&1; then
        log_debug "Email sent via SMTP (${smtp_server}) to ${smtp_to}"
        return 0
    fi

    log_warning "Failed to send email via SMTP (${smtp_server}:${smtp_port})"
    return 1
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

    # The URL contains the bot token, so pass it via a curl config (not argv).
    # --data-urlencode makes '&', '+', '=' etc. in the message safe; no
    # parse_mode, so '<' and '>' in the text cannot break the request.
    # --fail makes HTTP errors (e.g. 401 bad token) count as failures.
    local api_url="https://api.telegram.org/bot${bot_token}/sendMessage"
    if curl --config <(printf 'url = "%s"\n' "$(_curl_cfg_escape "$api_url")") \
        --silent --show-error --fail -X POST \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" \
        -o /dev/null 2>/dev/null; then
        log_debug "Telegram notification sent to chat ${chat_id}"
        return 0
    fi

    log_warning "Failed to send Telegram notification"
    return 1
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

    local payload
    payload="{\"text\":\"$(_json_escape "$message")\",\"mrkdwn\":true}"

    # The webhook URL is a secret, so pass it via a curl config (not argv)
    if curl --config <(printf 'url = "%s"\n' "$(_curl_cfg_escape "$webhook_url")") \
        --silent --show-error --fail -X POST \
        -H "Content-Type: application/json" \
        --data-binary "$payload" \
        -o /dev/null 2>/dev/null; then
        log_debug "Slack notification sent"
        return 0
    fi

    log_warning "Failed to send Slack notification"
    return 1
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

    local choice smtp_port_input test_choice
    printf 'Enter choice [1-6] (current: %s): ' "${NOTIFICATION_METHOD:-console}"
    read -r choice || choice=""

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
    _update_config_value "$config_file" "SMTP_PASS" "${SMTP_PASS:-}"
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
    read -r test_choice || test_choice="n"
    test_choice="$(to_lower "$(trim "$test_choice")")"

    if [[ "$test_choice" != "n" ]] && [[ "$test_choice" != "no" ]]; then
        echo_info "Sending test notification..."
        dispatch_notification "This is a test notification from certbot-smart-manager." "INFO" "Test Notification"
        echo_info "Test notification sent. Check your configured method."
    fi
}

# Update a single configuration value in the config file.
#
# The value is written single-quoted (KEY='value'), so it is stored
# literally when the config is sourced: '$', '`', '"', '\' and '/' are all
# safe. (The previous sed-based version broke on any value containing '/',
# e.g. every Slack webhook URL, and allowed shell injection via '$(...)'.)
_update_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
        log_error "Refusing to write invalid config key: ${key}"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        ( umask 077; : > "$file" )
    fi

    # Quote for the shell: ' -> '\''
    local quoted="'${value//\'/\'\\\'\'}'"
    local new_line="${key}=${quoted}"

    local tmp
    tmp="$(mktemp "${file}.XXXXXX")" || {
        log_error "Unable to create temporary file next to ${file}"
        return 1
    }
    chmod 600 "$tmp" 2>/dev/null || true

    # Replace the first matching line (commented "# KEY=" or active "KEY="),
    # drop any later duplicates, append if the key is not present.
    # Values are passed via the environment so awk does not interpret escapes.
    if ! CFG_KEY="$key" CFG_LINE="$new_line" awk '
        BEGIN { key = ENVIRON["CFG_KEY"]; line = ENVIRON["CFG_LINE"]; done = 0 }
        {
            probe = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", probe)
            sub(/^[[:space:]]*/, "", probe)
            if (index(probe, key "=") == 1) {
                if (!done) { print line; done = 1 }
                next
            }
            print
        }
        END { if (!done) print line }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        log_error "Failed to update ${key} in ${file}"
        return 1
    fi

    mv -f "$tmp" "$file"

    # Apply secure permissions
    chmod 600 "$file" 2>/dev/null || true
    chown root:root "$file" 2>/dev/null || true
}