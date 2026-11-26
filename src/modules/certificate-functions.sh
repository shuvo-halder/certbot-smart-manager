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

        log_debug "Certificate: ${cert_name} | Domains: ${domains} | Expires: ${expiry_date} | Remaining: ${remaining} days | Status: ${CERTIFICATE_STATUS[-1]}"
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

    local certbot_args=(renew --cert-name "$cert_name" --quiet --non-interactive)

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
        set +e
        certbot "${certbot_args[@]}"
        rc=$?
        set -e

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
        if [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
            log_info "Certificate updated for ${cert_name}; reloading web server."
            reload_web_server
        else
            log_info "Web server reload disabled by configuration."
        fi
    else
        log_info "certbot finished for ${cert_name}, but the certificate was not changed (not yet due according to certbot); reload skipped."
    fi

    return 0
}

# Renew all certificates that are within the threshold
renew_all_certificates() {
    local i cert_name remaining status
    local renewed=0
    local failed=0
    local skipped=0

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

        if [[ "$status" == "error" ]]; then
            log_warning "Skipping ${cert_name}: unable to determine status"
            send_error_notification "Unable to read certificate '${cert_name}' — please inspect /etc/letsencrypt/live/${cert_name}/"
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$remaining" -le "${THRESHOLD_DAYS:-30}" ]] || [[ "${FORCE_RENEW:-false}" == "true" ]]; then
            log_info "Certificate '${cert_name}': ${remaining} days remaining (threshold: ${THRESHOLD_DAYS:-30})"

            if renew_certificate "$cert_name" "$remaining"; then
                renewed=$((renewed + 1))
            else
                failed=$((failed + 1))
                send_renewal_failure_notification "$cert_name" "${CERTIFICATE_DOMAINS[$i]}" "${CERTIFICATE_EXPIRY_DATES[$i]}" "$remaining"
            fi
        else
            log_debug "Certificate '${cert_name}': ${remaining} days remaining (above threshold); skipping"
            skipped=$((skipped + 1))
        fi
    done

    log_info "Renewal complete: ${renewed} processed, ${failed} failed, ${skipped} skipped"

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# NEW CERTIFICATE INSTALLATION
# =============================================================================

# Interactive installation of a new SSL certificate
install_new_certificate_interactive() {
    local domain subdomain email plugin extra_domains confirm
    local domains_list=()

    echo_bold ""
    echo_bold "========================================"
    echo_bold "    Install New SSL Certificate"
    echo_bold "========================================"
    echo ""

    # Detect web server
    detect_web_server
    plugin="$(detect_certbot_plugin)"

    if [[ "$plugin" == "manual" ]]; then
        echo_warning "No supported web server detected (Nginx/Apache)."
        echo_info "Falling back to certbot's standalone mode ('certonly --standalone')."
        echo_info "Port 80 must be free during issuance; you will need to configure"
        echo_info "your server to use the certificate yourself."
    else
        echo_info "Detected web server plugin: ${plugin}"
    fi

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

    if ! validate_domain "$domain"; then
        echo_error "Invalid domain format: ${domain}"
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
            if validate_domain "$extra_domain"; then
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
    echo "  Plugin:     ${plugin}"
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
    if [[ "$plugin" == "manual" ]]; then
        certbot_args+=(certonly --standalone)
    else
        certbot_args+=("--${plugin}")
    fi
    certbot_args+=(--non-interactive --agree-tos --email "$email")

    local d
    for d in "${domains_list[@]}"; do
        certbot_args+=(-d "$d")
    done

    _load_certbot_extra_args
    certbot_args+=(${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"})

    echo ""
    echo_info "Executing: certbot $(IFS=' '; printf '%s' "${certbot_args[*]}")"
    echo ""

    open_firewall_ports

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

    # The nginx/apache installers reload the server themselves; standalone does not touch it
    if [[ "$plugin" != "manual" ]] && [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
        reload_web_server
    fi

    log_success "Installed certificate for: ${domains_str}"

    # Show certificate info (certbot names the lineage after the first -d)
    local live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${domains_list[0]}"
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

    local certbot_args=(renew --dry-run --quiet --non-interactive)
    _load_certbot_extra_args
    certbot_args+=(${CERTBOT_EXTRA[@]+"${CERTBOT_EXTRA[@]}"})

    open_firewall_ports

    local rc=0
    set +e
    certbot "${certbot_args[@]}"
    rc=$?
    set -e

    close_firewall_ports

    if [[ $rc -eq 0 ]]; then
        log_success "Dry-run completed successfully"
        echo_success ""
        echo_success "Dry-run: All renewals would succeed."
    else
        log_error "Dry-run failed (exit code: ${rc})"
        echo_error ""
        echo_error "Dry-run: Renewal simulation failed."
        echo_error "Check configuration and network connectivity."
    fi

    return $rc
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
