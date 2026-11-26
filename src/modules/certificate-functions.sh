#!/bin/bash
# =============================================================================
# certbot-smart-manager — Certificate Functions Module
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/modules/certificate-functions.sh
# =============================================================================
#
# Handles scanning, expiry checking, renewal, and new certificate installation.
# Must be sourced after utils.sh and server-detection.sh.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# GLOBALS
# =============================================================================

# Arrays populated by scan_certificates()
CERTIFICATE_NAMES=()
CERTIFICATE_DOMAINS=()
CERTIFICATE_EXPIRY_DATES=()
CERTIFICATE_REMAINING_DAYS=()
CERTIFICATE_STATUS=()      # "valid", "expiring_soon", "critical", "expired", "error"
CERTIFICATE_RENEW_MODE=()  # "auto" or "manual" (see _cert_renew_mode)

# Last lines of certbot output from the most recent failed run (for notifications)
CERTBOT_LAST_ERROR=""

# Deploy hook installed by install.sh — certbot runs it after EVERY successful
# renewal (ours, certbot's own timer, or a manual one) and it reloads the
# web server. If present, we do not need to reload ourselves.
DEPLOY_HOOK_PATH="${DEPLOY_HOOK_PATH:-/etc/letsencrypt/renewal-hooks/deploy/certbot-smart-manager-reload.sh}"

# Certbot only renews a certificate on its own when it is within this many
# days of expiry (certbot's default `renew_before_expiry`). If our threshold
# is larger, we must pass --force-renewal or certbot silently does nothing.
CERTBOT_DEFAULT_RENEW_DAYS=30

# =============================================================================
# HELPERS
# =============================================================================

# Split CERTBOT_EXTRA_ARGS on spaces into the CERTBOT_EXTRA array.
# (The global IFS is $'\n\t', so an unquoted expansion would NOT split on
# spaces and "--a --b" would reach certbot as one single argument.)
_load_certbot_extra_args() {
    CERTBOT_EXTRA=()
    if [[ -n "${CERTBOT_EXTRA_ARGS:-}" ]]; then
        IFS=' ' read -r -a CERTBOT_EXTRA <<< "${CERTBOT_EXTRA_ARGS}"
    fi
}

# Read a value from a certbot renewal .conf ("key = value"); empty if absent
_renewal_conf_value() {
    local conf="$1" key="$2"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$conf" 2>/dev/null | head -n 1 | tr -d '\r'
}

# Decide whether a certificate can be renewed unattended.
#   manual: issued with `--manual` and no --manual-auth-hook. certbot cannot
#           renew it non-interactively (someone has to create the DNS/HTTP
#           challenge by hand), so it is NEVER auto-renewed — only logged and
#           notified. Renew it with: ssl-manager --renew-cert <name>
#   auto:   everything else (nginx, apache, webroot, standalone, DNS plugins,
#           or manual WITH an auth hook).
_cert_renew_mode() {
    local conf="$1"
    local authenticator hook
    authenticator="$(_renewal_conf_value "$conf" authenticator)"
    hook="$(_renewal_conf_value "$conf" manual_auth_hook)"
    if [[ "$authenticator" == "manual" && -z "$hook" ]]; then
        printf 'manual'
    else
        printf 'auto'
    fi
}

# Run certbot, capturing its output into our log. On failure the last lines
# are kept in CERTBOT_LAST_ERROR so the notification can say WHY it failed.
# Usage: _run_certbot_logged <args...>   (returns certbot's exit code)
_run_certbot_logged() {
    local out rc=0
    out="$(mktemp)"
    set +e
    certbot "$@" > "$out" 2>&1
    rc=$?
    set -e

    # Keep certbot's own output in our log (indented), so a failure can be
    # diagnosed without re-running certbot by hand
    if [[ -s "$out" ]]; then
        { sed 's/^/    certbot: /' "$out" >> "${LOG_FILE:-/var/log/certbot-smart-manager.log}"; } 2>/dev/null || true
    fi

    if [[ $rc -ne 0 ]]; then
        CERTBOT_LAST_ERROR="$(tail -n 15 "$out" 2>/dev/null || true)"
    else
        CERTBOT_LAST_ERROR=""
    fi
    rm -f "$out"
    return $rc
}

# Throttle repeated notifications: returns 0 if <key> was not notified in
# the last <hours> hours (and records now), 1 otherwise.
_should_notify() {
    local key="$1" hours="${2:-24}"
    local state_dir="${STATE_DIR:-/var/lib/certbot-smart-manager}"
    local stamp="${state_dir}/notified-$(sanitize_filename "$key")"
    local now last=0
    now="$(date +%s)"

    mkdir -p "$state_dir" 2>/dev/null || return 0
    [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    if (( now - last < hours * 3600 )); then
        return 1
    fi
    printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
    return 0
}

# Reload the web server after a certificate changed — unless the certbot
# deploy hook is installed, in which case certbot already did it.
_reload_after_change() {
    local cert_name="$1"
    if [[ "${RELOAD_WEB_SERVER:-true}" != "true" ]]; then
        log_info "Web server reload disabled by configuration."
    elif [[ -x "$DEPLOY_HOOK_PATH" ]]; then
        log_info "Certificate updated for ${cert_name}; web server reloaded by certbot deploy hook."
    else
        log_info "Certificate updated for ${cert_name}; reloading web server."
        reload_web_server
    fi
}

# =============================================================================
# CERTIFICATE SCANNING
# =============================================================================

# Scan /etc/letsencrypt/renewal/ and populate certificate arrays
scan_certificates() {
    local renewal_dir="${CERTBOT_RENEWAL_DIR:-/etc/letsencrypt/renewal}"
    local conf_file cert_name live_dir fullchain expiry_date expiry_epoch now_epoch remaining

    # Reset arrays
    CERTIFICATE_NAMES=()
    CERTIFICATE_DOMAINS=()
    CERTIFICATE_EXPIRY_DATES=()
    CERTIFICATE_REMAINING_DAYS=()
    CERTIFICATE_STATUS=()
    CERTIFICATE_RENEW_MODE=()

    if [[ ! -d "$renewal_dir" ]]; then
        log_warning "Let's Encrypt renewal directory not found: ${renewal_dir}"
        return 0
    fi

    log_info "Scanning certificates in ${renewal_dir}..."

    shopt -s nullglob
    local conf_files=("${renewal_dir}"/*.conf)
    shopt -u nullglob

    if [[ ${#conf_files[@]} -eq 0 ]]; then
        log_info "No certificate renewal configurations found."
        return 0
    fi

    for conf_file in "${conf_files[@]}"; do
        cert_name="$(basename "$conf_file" .conf)"
        live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${cert_name}"
        fullchain="${live_dir}/fullchain.pem"

        CERTIFICATE_NAMES+=("$cert_name")
        CERTIFICATE_RENEW_MODE+=("$(_cert_renew_mode "$conf_file")")

        if [[ ! -f "$fullchain" ]]; then
            log_warning "Certificate '${cert_name}': fullchain.pem not found at ${fullchain}"
            CERTIFICATE_DOMAINS+=("$cert_name")
            CERTIFICATE_EXPIRY_DATES+=("unknown")
            CERTIFICATE_REMAINING_DAYS+=("-1")
            CERTIFICATE_STATUS+=("error")
            continue
        fi

        # Domains: read the SANs from the certificate itself (renewal .conf
        # files do not contain a "domains =" line in modern certbot).
        local domains
        domains="$(openssl x509 -noout -text -in "$fullchain" 2>/dev/null \
            | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' | tr '\n' ' ' || true)"
        domains="$(trim "$domains")"
        [[ -z "$domains" ]] && domains="$cert_name"
        CERTIFICATE_DOMAINS+=("$domains")

        # Expiry date
        expiry_date="$(openssl x509 -enddate -noout -in "$fullchain" 2>/dev/null | cut -d= -f2 || true)"
        expiry_epoch=""
        if [[ -n "$expiry_date" ]]; then
            expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || true)"
        fi

        if [[ -z "$expiry_date" || -z "$expiry_epoch" ]]; then
            log_warning "Certificate '${cert_name}': unable to read expiry date"
            CERTIFICATE_EXPIRY_DATES+=("unknown")
            CERTIFICATE_REMAINING_DAYS+=("-1")
            CERTIFICATE_STATUS+=("error")
            continue
        fi

        CERTIFICATE_EXPIRY_DATES+=("$expiry_date")
        now_epoch="$(date +%s)"
        remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
        CERTIFICATE_REMAINING_DAYS+=("$remaining")

        if [[ $remaining -le 0 ]]; then
            CERTIFICATE_STATUS+=("expired")
        elif [[ $remaining -le "${CRITICAL_THRESHOLD_DAYS:-7}" ]]; then
            CERTIFICATE_STATUS+=("critical")
        elif [[ $remaining -le "${THRESHOLD_DAYS:-30}" ]]; then
            CERTIFICATE_STATUS+=("expiring_soon")
        else
            CERTIFICATE_STATUS+=("valid")
        fi

        log_debug "Certificate: ${cert_name} | Domains: ${domains} | Expires: ${expiry_date} | Remaining: ${remaining} days | Status: ${CERTIFICATE_STATUS[-1]} | Renewal: ${CERTIFICATE_RENEW_MODE[-1]}"
    done

    log_info "Scanned ${#CERTIFICATE_NAMES[@]} certificate(s)"
}

# =============================================================================
# EXPIRY CHECK
# =============================================================================

# Check expiry and print a formatted summary
check_expiry_status() {
    scan_certificates

    if [[ ${#CERTIFICATE_NAMES[@]} -eq 0 ]]; then
        echo_info "No certificates found."
        return 0
    fi

    echo_bold ""
    echo_bold "========================================"
    echo_bold "    SSL Certificate Expiry Summary"
    echo_bold "========================================"
    echo ""

    local i name domains expiry remaining status color
    for i in "${!CERTIFICATE_NAMES[@]}"; do
        name="${CERTIFICATE_NAMES[$i]}"
        domains="${CERTIFICATE_DOMAINS[$i]}"
        expiry="${CERTIFICATE_EXPIRY_DATES[$i]}"
        remaining="${CERTIFICATE_REMAINING_DAYS[$i]}"
        status="${CERTIFICATE_STATUS[$i]}"

        case "$status" in
            valid)            color="${COLOR_GREEN}"  ;;
            expiring_soon)    color="${COLOR_YELLOW}" ;;
            critical|expired) color="${COLOR_RED}"    ;;
            error)            color="${COLOR_RED}"    ;;
            *)                color="${COLOR_RESET}"  ;;
        esac

        printf '%b%-25s%b %s\n' "${COLOR_BOLD}" "Certificate:" "${COLOR_RESET}" "$name"
        printf '  %-23s %s\n' "Domains:" "$domains"
        printf '  %-23s %s\n' "Expires:" "$expiry"
        if [[ "${CERTIFICATE_RENEW_MODE[$i]:-auto}" == "manual" ]]; then
            printf '  %-23s %bMANUAL%b (run: ssl-manager --renew-cert %s)\n' "Renewal:" "${COLOR_YELLOW}" "${COLOR_RESET}" "$name"
        else
            printf '  %-23s %s\n' "Renewal:" "automatic"
        fi
        printf '  %-23s ' "Remaining Days:"
        case "$status" in
            valid)         printf '%b%d days%b (✓)' "$color" "$remaining" "${COLOR_RESET}" ;;
            expiring_soon) printf '%b%d days%b (⚠  will renew)' "$color" "$remaining" "${COLOR_RESET}" ;;
            critical)      printf '%b%d days%b (🔴 CRITICAL)' "$color" "$remaining" "${COLOR_RESET}" ;;
            expired)       printf '%bexpired %d day(s) ago%b (✗ EXPIRED)' "$color" "$(( -remaining ))" "${COLOR_RESET}" ;;
            *)             printf '%bunknown%b' "$color" "${COLOR_RESET}" ;;
        esac
        printf '\n\n'
    done
}

# =============================================================================
# CERTIFICATE RENEWAL
# =============================================================================

# Renew a single certificate by name
# Usage: renew_certificate <cert_name> [remaining_days]
# Returns: 0 on success, 1 on failure
renew_certificate() {
    local cert_name="$1"
    local remaining="${2:-0}"
    local live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${cert_name}"
    local fullchain="${live_dir}/fullchain.pem"
    local before_mtime=""
    local after_mtime=""
    local rc=0
    local renewal_conf="${CERTBOT_RENEWAL_DIR:-/etc/letsencrypt/renewal}/${cert_name}.conf"
    local max_retries="${MAX_RETRIES:-3}"
    local retry_delay="${RETRY_DELAY_SECONDS:-10}"
    local attempt

    validate_positive_int "$max_retries" || max_retries=1
    [[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=10

    if [[ ! -f "$renewal_conf" ]]; then
        log_error "Renewal configuration not found for: ${cert_name}"
        return 1
    fi

    # Record mtime before renewal
    if [[ -e "$fullchain" ]]; then
        before_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"
    fi

    local certbot_args=(renew --cert-name "$cert_name" --non-interactive)

    # Force renewal when requested, or when our threshold is wider than
    # certbot's own renewal window (otherwise certbot would just skip it).
    if [[ "${FORCE_RENEW:-false}" == "true" ]] || [[ "$remaining" -gt "$CERTBOT_DEFAULT_RENEW_DAYS" ]]; then
        certbot_args+=(--force-renewal)
    fi

    _load_certbot_extra_args
    certbot_args+=(${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"})

    log_info "Renewing certificate: ${cert_name}"

    # Open firewall ports if needed (closed again below, and by the EXIT trap)
    open_firewall_ports

    for (( attempt = 1; attempt <= max_retries; attempt++ )); do
        rc=0
        _run_certbot_logged "${certbot_args[@]}" || rc=$?

        [[ $rc -eq 0 ]] && break

        if [[ $attempt -lt $max_retries ]]; then
            log_warning "Renewal attempt ${attempt}/${max_retries} for ${cert_name} failed (exit code: ${rc}); retrying in ${retry_delay}s..."
            sleep "$retry_delay"
        fi
    done

    close_firewall_ports

    if [[ $rc -ne 0 ]]; then
        log_error "Renewal failed for ${cert_name} after ${max_retries} attempt(s) (exit code: ${rc})"
        return 1
    fi

    # Check if certificate was actually updated
    if [[ -e "$fullchain" ]]; then
        after_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"
    fi

    if [[ -n "$before_mtime" && -n "$after_mtime" && "$before_mtime" != "$after_mtime" ]]; then
        log_success "Renewed ${cert_name}"
        _reload_after_change "$cert_name"
    else
        log_info "certbot finished for ${cert_name}, but the certificate was not changed (not yet due according to certbot); reload skipped."
    fi

    return 0
}

# Renew all certificates that are within the threshold
renew_all_certificates() {
    local i cert_name remaining status mode
    local renewed=0
    local failed=0
    local skipped=0
    local manual_due=0

    scan_certificates

    if [[ ${#CERTIFICATE_NAMES[@]} -eq 0 ]]; then
        echo_info "No certificates to renew."
        return 0
    fi

    log_info "Starting renewal check for ${#CERTIFICATE_NAMES[@]} certificate(s)..."

    for i in "${!CERTIFICATE_NAMES[@]}"; do
        cert_name="${CERTIFICATE_NAMES[$i]}"
        remaining="${CERTIFICATE_REMAINING_DAYS[$i]}"
        status="${CERTIFICATE_STATUS[$i]}"
        mode="${CERTIFICATE_RENEW_MODE[$i]:-auto}"

        if [[ "$status" == "error" ]]; then
            log_warning "Skipping ${cert_name}: unable to determine status"
            if _should_notify "error-${cert_name}" 24; then
                send_error_notification "Unable to read certificate '${cert_name}' — please inspect /etc/letsencrypt/live/${cert_name}/"
            fi
            skipped=$((skipped + 1))
            continue
        fi

        # Certificates issued with --manual (no auth hook) cannot be renewed
        # unattended. Never try (it would only fail); log it every run and
        # notify at most once a day while it is inside the threshold.
        if [[ "$mode" == "manual" ]]; then
            if [[ "$remaining" -le "${THRESHOLD_DAYS:-30}" ]]; then
                log_warning "MANUAL RENEWAL REQUIRED: '${cert_name}' (${CERTIFICATE_DOMAINS[$i]}) expires in ${remaining} days. Run: sudo ssl-manager --renew-cert ${cert_name}"
                if _should_notify "manual-${cert_name}" 24; then
                    send_manual_renewal_notification "$cert_name" "${CERTIFICATE_DOMAINS[$i]}" "${CERTIFICATE_EXPIRY_DATES[$i]}" "$remaining"
                fi
                manual_due=$((manual_due + 1))
            else
                log_info "Certificate '${cert_name}': manual renewal mode, ${remaining} days remaining; no action needed yet"
                skipped=$((skipped + 1))
            fi
            continue
        fi

        if [[ "$remaining" -le "${THRESHOLD_DAYS:-30}" ]] || [[ "${FORCE_RENEW:-false}" == "true" ]]; then
            log_info "Certificate '${cert_name}': ${remaining} days remaining (threshold: ${THRESHOLD_DAYS:-30})"

            if renew_certificate "$cert_name" "$remaining"; then
                renewed=$((renewed + 1))
            else
                failed=$((failed + 1))
                send_renewal_failure_notification "$cert_name" "${CERTIFICATE_DOMAINS[$i]}" "${CERTIFICATE_EXPIRY_DATES[$i]}" "$remaining" "$CERTBOT_LAST_ERROR"
            fi
        else
            log_debug "Certificate '${cert_name}': ${remaining} days remaining (above threshold); skipping"
            skipped=$((skipped + 1))
        fi
    done

    log_info "Renewal complete: ${renewed} processed, ${failed} failed, ${skipped} skipped, ${manual_due} awaiting manual renewal"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Renew ONE certificate on demand, by name (ssl-manager --renew-cert <name>).
#   auto mode:   forced, non-interactive `certbot renew`.
#   manual mode: INTERACTIVE `certbot certonly --manual` with the same
#                domains — certbot shows the TXT/HTTP challenge to create.
renew_single_certificate() {
    local cert_name="$1"
    local renewal_conf="${CERTBOT_RENEWAL_DIR:-/etc/letsencrypt/renewal}/${cert_name}.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        echo_error "No certificate named '${cert_name}'. Available certificates:"
        scan_certificates >/dev/null
        local n
        for n in "${CERTIFICATE_NAMES[@]}"; do
            echo "  ${n}"
        done
        return 1
    fi

    scan_certificates >/dev/null
    local i idx=-1
    for i in "${!CERTIFICATE_NAMES[@]}"; do
        [[ "${CERTIFICATE_NAMES[$i]}" == "$cert_name" ]] && idx=$i
    done
    if [[ $idx -lt 0 ]]; then
        echo_error "Could not read certificate '${cert_name}'."
        return 1
    fi

    local mode="${CERTIFICATE_RENEW_MODE[$idx]}"
    local remaining="${CERTIFICATE_REMAINING_DAYS[$idx]}"

    if [[ "$mode" != "manual" ]]; then
        log_info "Renewing '${cert_name}' on demand (automatic mode)"
        FORCE_RENEW=true
        local rc=0
        renew_certificate "$cert_name" "$remaining" || rc=$?
        FORCE_RENEW=false
        if [[ $rc -ne 0 ]]; then
            echo_error "Renewal failed. certbot said:"
            printf '%s\n' "$CERTBOT_LAST_ERROR"
        fi
        return $rc
    fi

    # --- manual certificate ---
    local domains_arr=() d
    IFS=' ' read -r -a domains_arr <<< "${CERTIFICATE_DOMAINS[$idx]}"
    if [[ ${#domains_arr[@]} -eq 0 ]]; then
        echo_error "Could not determine the domains of '${cert_name}'."
        return 1
    fi

    local pref
    pref="$(_renewal_conf_value "$renewal_conf" pref_challs)"
    pref="${pref%%,*}"
    pref="$(trim "$pref")"
    pref="${pref%-01}"            # "dns-01" -> "dns"
    [[ -z "$pref" ]] && pref="dns"

    local certbot_args=(certonly --manual --preferred-challenges "$pref" --cert-name "$cert_name" --force-renewal)
    for d in "${domains_arr[@]}"; do
        certbot_args+=(-d "$d")
    done
    _load_certbot_extra_args
    certbot_args+=(${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"})

    echo_bold ""
    echo_bold "Manual renewal: ${cert_name}"
    echo_info "Domains:   ${CERTIFICATE_DOMAINS[$idx]}"
    echo_info "Challenge: ${pref}-01 — certbot will show you what to create (e.g. a DNS TXT record)."
    echo_info "Keep this terminal open until certbot finishes."
    echo ""

    log_info "Manual renewal started for '${cert_name}' (${CERTIFICATE_DOMAINS[$idx]})"

    local before_mtime="" after_mtime="" fullchain
    fullchain="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${cert_name}/fullchain.pem"
    [[ -e "$fullchain" ]] && before_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"

    [[ "$pref" == "http" ]] && open_firewall_ports

    # Interactive: output goes straight to the terminal, not captured
    local rc=0
    set +e
    certbot "${certbot_args[@]}"
    rc=$?
    set -e

    close_firewall_ports

    if [[ $rc -ne 0 ]]; then
        log_error "Manual renewal FAILED for '${cert_name}' (exit code: ${rc})"
        echo_error "Manual renewal failed (exit code: ${rc})."
        return 1
    fi

    [[ -e "$fullchain" ]] && after_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"
    if [[ -n "$before_mtime" && "$before_mtime" != "$after_mtime" ]]; then
        log_success "Manual renewal completed for '${cert_name}'"
        _reload_after_change "$cert_name"
        # Allow the next reminder to be sent as soon as it is due again
        rm -f "${STATE_DIR:-/var/lib/certbot-smart-manager}/notified-$(sanitize_filename "manual-${cert_name}")" 2>/dev/null || true
    else
        log_info "certbot finished for '${cert_name}' but the certificate did not change"
    fi
    return 0
}

# =============================================================================
# NEW CERTIFICATE INSTALLATION
# =============================================================================

# Validate a domain for issuance. Wildcards (*.example.com) are only
# possible with DNS validation (manual-dns).
_validate_cert_domain() {
    local d="$1" method="$2"
    if [[ "$d" == \*.* ]]; then
        [[ "$method" == "manual-dns" ]] || return 1
        d="${d#\*.}"
    fi
    validate_domain "$d"
}

# Interactive installation of a new SSL certificate
install_new_certificate_interactive() {
    local domain subdomain email plugin extra_domains confirm method method_choice
    local domains_list=()

    echo_bold ""
    echo_bold "========================================"
    echo_bold "    Install New SSL Certificate"
    echo_bold "========================================"
    echo ""

    # Detect web server
    detect_web_server
    plugin="$(detect_certbot_plugin)"

    # detect_certbot_plugin prints "manual" when no web server is found;
    # for issuing that means certbot's standalone server.
    local auto_method="$plugin"
    [[ "$plugin" == "manual" ]] && auto_method="standalone"

    if [[ "$auto_method" == "standalone" ]]; then
        echo_warning "No supported web server detected (Nginx/Apache)."
        echo_info "Automatic mode will use certbot's standalone server (port 80 must be free);"
        echo_info "you will need to configure your server to use the certificate yourself."
    else
        echo_info "Detected web server plugin: ${auto_method}"
    fi

    # Validation method
    echo ""
    echo_info "Validation method:"
    echo "  1) Automatic (${auto_method}) — renewed automatically by the timer   [default]"
    echo "  2) Manual DNS (TXT record)  — needed for wildcards (*.example.com);"
    echo "                                NOT auto-renewed: you renew it with"
    echo "                                'ssl-manager --renew-cert <name>' (you get reminders)"
    printf "> "
    read -r method_choice || method_choice=""
    case "$(trim "$method_choice")" in
        2) method="manual-dns" ;;
        ""|1) method="$auto_method" ;;
        *) echo_error "Invalid choice."; return 1 ;;
    esac

    # Primary domain
    echo ""
    echo_info "Enter the primary domain (e.g., example.com):"
    printf "> "
    read -r domain || return 1
    domain="$(to_lower "$(trim "$domain")")"

    if [[ -z "$domain" ]]; then
        echo_error "Domain cannot be empty."
        return 1
    fi

    if ! _validate_cert_domain "$domain" "$method"; then
        echo_error "Invalid domain format: ${domain}"
        [[ "$domain" == \** ]] && echo_info "Wildcard domains need the 'Manual DNS' method."
        return 1
    fi
    domains_list+=("$domain")

    # Optional subdomain (added IN ADDITION to the primary domain)
    echo ""
    echo_info "Enter subdomain (optional, e.g., www):"
    printf "> "
    read -r subdomain || subdomain=""
    subdomain="$(to_lower "$(trim "$subdomain")")"

    if [[ -n "$subdomain" ]]; then
        if validate_domain "${subdomain}.${domain}"; then
            domains_list+=("${subdomain}.${domain}")
        else
            echo_warning "Skipping invalid subdomain: ${subdomain}.${domain}"
        fi
    fi

    # Email address
    echo ""
    echo_info "Enter email address for registration/renewal notifications:"
    printf "> "
    read -r email || return 1
    email="$(trim "$email")"

    if [[ -z "$email" ]]; then
        echo_error "Email cannot be empty."
        return 1
    fi

    if ! validate_email "$email"; then
        echo_error "Invalid email format: ${email}"
        return 1
    fi

    # Additional domains
    echo ""
    echo_info "Enter additional domains (comma-separated, or leave empty):"
    echo_info "Example: api.example.com, admin.example.com"
    printf "> "
    read -r extra_domains || extra_domains=""

    if [[ -n "$(trim "$extra_domains")" ]]; then
        local extras=() extra_domain
        IFS=',' read -r -a extras <<< "$extra_domains"
        for extra_domain in "${extras[@]}"; do
            extra_domain="$(to_lower "$(trim "$extra_domain")")"
            [[ -z "$extra_domain" ]] && continue
            if _validate_cert_domain "$extra_domain" "$method"; then
                domains_list+=("$extra_domain")
            else
                echo_warning "Skipping invalid domain: ${extra_domain}"
            fi
        done
    fi

    # Space-joined copy for display (the global IFS is newline+tab, so
    # "${domains_list[*]}" would join with newlines)
    local domains_str
    domains_str="$(IFS=' '; printf '%s' "${domains_list[*]}")"

    # Confirmation
    echo ""
    echo_bold "Summary:"
    echo "  Method:     ${method}"
    echo "  Email:      ${email}"
    echo "  Domains:    ${domains_str}"
    echo ""

    echo_info "Proceed with installation? [Y/n]"
    printf "> "
    read -r confirm || confirm="n"
    confirm="$(to_lower "$(trim "$confirm")")"

    if [[ -n "$confirm" ]] && [[ "$confirm" != "y" ]] && [[ "$confirm" != "yes" ]]; then
        echo_info "Installation cancelled."
        return 0
    fi

    # Build the certbot command as an array — no eval, no word-splitting issues
    local certbot_args=()
    case "$method" in
        standalone) certbot_args+=(certonly --standalone --non-interactive) ;;
        manual-dns) certbot_args+=(certonly --manual --preferred-challenges dns) ;;  # interactive
        *)          certbot_args+=("--${method}" --non-interactive) ;;
    esac
    certbot_args+=(--agree-tos --email "$email")

    local d
    for d in "${domains_list[@]}"; do
        certbot_args+=(-d "$d")
    done

    _load_certbot_extra_args
    certbot_args+=(${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"})

    echo ""
    echo_info "Executing: certbot $(IFS=' '; printf '%s' "${certbot_args[*]}")"
    echo ""

    [[ "$method" == "manual-dns" ]] && echo_info "certbot will now show the DNS TXT record(s) to create. Keep this terminal open."
    [[ "$method" != "manual-dns" ]] && open_firewall_ports

    local rc=0
    set +e
    certbot "${certbot_args[@]}"
    rc=$?
    set -e

    close_firewall_ports

    if [[ $rc -ne 0 ]]; then
        echo_error ""
        echo_error "Certificate installation FAILED (exit code: ${rc})."
        echo_error "Check: 'certbot certificates' and /var/log/letsencrypt/letsencrypt.log"
        log_error "Certificate installation failed for: ${domains_str}"
        return 1
    fi

    echo_success ""
    echo_success "Certificate installed successfully!"
    echo_success "Domains: ${domains_str}"
    echo ""

    # nginx/apache plugins install the cert into the server config; standalone
    # and manual-dns only obtain it, so there is nothing to reload yet
    if [[ "$method" == "nginx" || "$method" == "apache" ]] && [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
        reload_web_server
    fi

    log_success "Installed certificate for: ${domains_str} (method: ${method})"

    if [[ "$method" == "manual-dns" ]]; then
        echo_warning "This certificate will NOT be renewed automatically."
        echo_warning "You will get a reminder ${THRESHOLD_DAYS:-30} days before expiry; then run:"
        echo_warning "  sudo ssl-manager --renew-cert ${domains_list[0]#\*.}"
        log_info "Certificate '${domains_list[0]}' uses manual DNS validation; renewal must be done manually"
    else
        echo_success "This certificate will be checked and renewed automatically."
    fi

    if [[ "${NOTIFICATION_METHOD:-console}" == "console" || "${NOTIFICATION_METHOD:-console}" == "log" ]]; then
        echo_warning "Notifications are set to '${NOTIFICATION_METHOD:-console}' — nobody will see a failed renewal."
        echo_warning "Configure email/Telegram/Slack with: sudo ssl-manager --configure"
    fi

    # Show certificate info (certbot names the lineage after the first -d,
    # without a leading "*." for wildcards)
    local live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${domains_list[0]#\*.}"
    if [[ -f "${live_dir}/fullchain.pem" ]]; then
        local expiry
        expiry="$(openssl x509 -enddate -noout -in "${live_dir}/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")"
        echo_info "Certificate expires: ${expiry}"
    fi
}

# =============================================================================
# DRY RUN
# =============================================================================

# Perform a dry-run renewal
dry_run_renewal() {
    log_info "Starting dry-run renewal..."

    scan_certificates >/dev/null

    if [[ ${#CERTIFICATE_NAMES[@]} -eq 0 ]]; then
        echo_info "No certificates to test."
        return 0
    fi

    _load_certbot_extra_args

    local i name ok=0 failed=0 manual=0
    open_firewall_ports

    # Test each auto-renewable certificate separately; manual ones are
    # skipped (certbot cannot renew them non-interactively by design).
    for i in "${!CERTIFICATE_NAMES[@]}"; do
        name="${CERTIFICATE_NAMES[$i]}"
        if [[ "${CERTIFICATE_RENEW_MODE[$i]:-auto}" == "manual" ]]; then
            log_info "Dry-run: skipping '${name}' (manual renewal mode)"
            echo_warning "  - ${name}: manual renewal mode (skipped)"
            manual=$((manual + 1))
            continue
        fi
        if _run_certbot_logged renew --dry-run --non-interactive --cert-name "$name" \
            ${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"}; then
            echo_success "  - ${name}: OK"
            ok=$((ok + 1))
        else
            echo_error "  - ${name}: FAILED"
            printf '%s\n' "$CERTBOT_LAST_ERROR" | sed 's/^/      /'
            failed=$((failed + 1))
        fi
    done

    close_firewall_ports

    log_info "Dry-run: ${ok} OK, ${failed} failed, ${manual} manual (skipped)"
    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "Dry-run completed successfully"
        echo_success "Dry-run: all automatic renewals would succeed."
        return 0
    fi

    log_error "Dry-run: ${failed} certificate(s) would fail to renew"
    echo_error "Dry-run: ${failed} certificate(s) would fail to renew. Full certbot output is in ${LOG_FILE}."
    return 1
}

# =============================================================================
# FORCE RENEWAL
# =============================================================================

# Force renewal of all certificates regardless of expiry
force_renew_all() {
    local rc=0

    echo_warning "Forcing renewal of all certificates..."
    log_warning "Force renewal initiated"

    # First backup
    if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
        backup_letsencrypt || log_warning "Backup failed; continuing with forced renewal"
    fi

    FORCE_RENEW=true
    renew_all_certificates || rc=$?
    FORCE_RENEW=false

    return $rc
}

# =============================================================================
# CERTIFICATE DISPLAY
# =============================================================================

# Display scanned certificates in a formatted table
display_certificates_table() {
    scan_certificates

    if [[ ${#CERTIFICATE_NAMES[@]} -eq 0 ]]; then
        echo_info "No certificates found in ${CERTBOT_RENEWAL_DIR:-/etc/letsencrypt/renewal}/"
        return 0
    fi

    echo_bold ""
    echo_bold "Found ${#CERTIFICATE_NAMES[@]} certificate(s):"
    echo ""

    local i name domains remaining status color
    for i in "${!CERTIFICATE_NAMES[@]}"; do
        name="${CERTIFICATE_NAMES[$i]}"
        domains="${CERTIFICATE_DOMAINS[$i]}"
        remaining="${CERTIFICATE_REMAINING_DAYS[$i]}"
        status="${CERTIFICATE_STATUS[$i]}"

        case "$status" in
            valid)                  color="${COLOR_GREEN}${COLOR_BOLD}"  ;;
            expiring_soon|critical) color="${COLOR_YELLOW}${COLOR_BOLD}" ;;
            *)                      color="${COLOR_RED}${COLOR_BOLD}"    ;;
        esac

        # %b so the ANSI escape sequences are interpreted, not printed literally
        printf '%b%-40s%b' "$color" "$name" "${COLOR_RESET}"
        printf '  Domains: %s\n' "$domains"
        if [[ "${CERTIFICATE_RENEW_MODE[$i]:-auto}" == "manual" ]]; then
            printf '  Renewal: MANUAL (ssl-manager --renew-cert %s)\n' "$name"
        else
            printf '  Renewal: automatic\n'
        fi

        case "$status" in
            valid)         printf '  Status: ✓ Valid (%d days remaining)\n' "$remaining" ;;
            expiring_soon) printf '  Status: ⚠ Expiring (%d days)\n' "$remaining" ;;
            critical)      printf '  Status: 🔴 Critical (%d days)\n' "$remaining" ;;
            expired)       printf '  Status: ✗ EXPIRED\n' ;;
            *)             printf '  Status: ✗ Error reading certificate\n' ;;
        esac
        echo ""
    done
}
