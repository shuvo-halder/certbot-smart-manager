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
CERTIFICATE_STATUS=()      # "valid", "expiring_soon", "expired", "error"

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

        if [[ ! -f "$fullchain" ]]; then
            log_warning "Certificate '${cert_name}': fullchain.pem not found at ${fullchain}"
            CERTIFICATE_NAMES+=("$cert_name")
            CERTIFICATE_DOMAINS+=("$cert_name")
            CERTIFICATE_EXPIRY_DATES+=("unknown")
            CERTIFICATE_REMAINING_DAYS+=("-1")
            CERTIFICATE_STATUS+=("error")
            continue
        fi

        # Extract domains from renewal config
        local domains_line domains
        domains_line="$(grep -E '^\s*domains\s*=' "$conf_file" 2>/dev/null || true)"
        if [[ -n "$domains_line" ]]; then
            # Remove 'domains = ' prefix and split by commas
            domains="$(printf '%s\n' "$domains_line" | sed 's/^.*=\s*//' | sed 's/,/ /g')"
        else
            domains="$cert_name"
        fi
        CERTIFICATE_DOMAINS+=("$domains")

        # Extract expiry date from the certificate
        expiry_date="$(openssl x509 -enddate -noout -in "$fullchain" 2>/dev/null | cut -d= -f2 || echo "unknown")"
        CERTIFICATE_EXPIRY_DATES+=("$expiry_date")

        # Calculate remaining days
        if [[ "$expiry_date" != "unknown" ]]; then
            expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")"
            now_epoch="$(date +%s)"
            remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
            CERTIFICATE_REMAINING_DAYS+=("$remaining")

            # Determine status
            if [[ $remaining -le 0 ]]; then
                CERTIFICATE_STATUS+=("expired")
            elif [[ $remaining -le "${CRITICAL_THRESHOLD_DAYS:-7}" ]]; then
                CERTIFICATE_STATUS+=("critical")
            elif [[ $remaining -le "${THRESHOLD_DAYS:-30}" ]]; then
                CERTIFICATE_STATUS+=("expiring_soon")
            else
                CERTIFICATE_STATUS+=("valid")
            fi
        else
            CERTIFICATE_REMAINING_DAYS+=("-1")
            CERTIFICATE_STATUS+=("error")
        fi

        CERTIFICATE_NAMES+=("$cert_name")

        log_debug "Certificate: ${cert_name} | Domains: ${domains} | Expires: ${expiry_date} | Remaining: ${CERTIFICATE_REMAINING_DAYS[-1]} days | Status: ${CERTIFICATE_STATUS[-1]}"
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
            valid)           color="${COLOR_GREEN}"  ;;
            expiring_soon)   color="${COLOR_YELLOW}" ;;
            critical|expired) color="${COLOR_RED}"   ;;
            error)           color="${COLOR_RED}"    ;;
            *)               color="${COLOR_RESET}"  ;;
        esac

        printf '%b%-25s%b %s\n' "${COLOR_BOLD}" "Certificate:" "${COLOR_RESET}" "$name"
        printf '  %-23s %s\n' "Domains:" "$domains"
        printf '  %-23s %s\n' "Expires:" "$expiry"
        printf '  %-23s ' "Remaining Days:"
        if [[ "$remaining" -ge 0 ]]; then
            printf '%b%d days%b' "$color" "$remaining" "${COLOR_RESET}"
            case "$status" in
                valid)         printf ' (✓)' ;;
                expiring_soon) printf ' (⚠  will renew)' ;;
                critical)      printf ' (🔴 CRITICAL)' ;;
                expired)       printf ' (✗ EXPIRED)' ;;
            esac
        else
            printf 'unknown'
        fi
        printf '\n\n'
    done
}

# =============================================================================
# CERTIFICATE RENEWAL
# =============================================================================

# Renew a single certificate by name
# Usage: renew_certificate <cert_name>
# Returns: 0 on success, 1 on failure
renew_certificate() {
    local cert_name="$1"
    local live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${cert_name}"
    local fullchain="${live_dir}/fullchain.pem"
    local before_mtime=""
    local after_mtime=""
    local rc=0
    local renewal_conf="${CERTBOT_RENEWAL_DIR:-/etc/letsencrypt/renewal}/${cert_name}.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        log_error "Renewal configuration not found for: ${cert_name}"
        return 1
    fi

    # Record mtime before renewal
    if [[ -e "$fullchain" ]]; then
        before_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"
    fi

    log_info "Renewing certificate: ${cert_name}"

    # Open firewall ports if needed
    open_firewall_ports

    # Run certbot renewal
    set +e
    certbot renew --cert-name "$cert_name" --quiet --non-interactive ${CERTBOT_EXTRA_ARGS:-}
    rc=$?
    set -e

    # Close firewall ports
    close_firewall_ports

    if [[ $rc -ne 0 ]]; then
        log_error "Renewal failed for ${cert_name} (exit code: ${rc})"
        return 1
    fi

    log_success "Renewed ${cert_name}"

    # Check if certificate was actually updated
    if [[ -e "$fullchain" ]]; then
        after_mtime="$(stat -Lc '%Y' "$fullchain" 2>/dev/null || echo "")"
    fi

    if [[ -n "$before_mtime" && -n "$after_mtime" && "$before_mtime" != "$after_mtime" ]]; then
        log_info "Certificate updated for ${cert_name}; reloading web server."
        if [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
            reload_web_server
        else
            log_info "Web server reload disabled by configuration."
        fi
    else
        log_debug "No certificate change detected for ${cert_name}; reload skipped."
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
            skipped=$((skipped + 1))
            continue
        fi

        if [[ "$remaining" -le "${THRESHOLD_DAYS:-30}" ]] || [[ "${FORCE_RENEW:-false}" == "true" ]]; then
            log_info "Certificate '${cert_name}': ${remaining} days remaining (threshold: ${THRESHOLD_DAYS:-30})"

            if renew_certificate "$cert_name"; then
                renewed=$((renewed + 1))
            else
                failed=$((failed + 1))
                # Send notification for failed renewal
                send_renewal_failure_notification "$cert_name" "${CERTIFICATE_DOMAINS[$i]}" "${CERTIFICATE_EXPIRY_DATES[$i]}" "$remaining"
            fi
        else
            log_debug "Certificate '${cert_name}': ${remaining} days remaining (above threshold); skipping"
            skipped=$((skipped + 1))
        fi
    done

    log_info "Renewal complete: ${renewed} renewed, ${failed} failed, ${skipped} skipped"

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
    local domain subdomain email web_server domains
    local plugin domains_list

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
        echo_info "You will need to use the 'certbot certonly' method manually."
        echo_info "Proceeding with manual mode..."
    else
        echo_info "Detected web server plugin: ${plugin}"
    fi

    # Gather domain information
    echo ""
    echo_info "Enter the primary domain (e.g., example.com):"
    printf "> "
    read -r domain
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ -z "$domain" ]]; then
        echo_error "Domain cannot be empty."
        return 1
    fi

    if ! validate_domain "$domain"; then
        echo_error "Invalid domain format: ${domain}"
        return 1
    fi

    # Optional subdomain
    echo ""
    echo_info "Enter subdomain (optional, e.g., www):"
    printf "> "
    read -r subdomain
    subdomain="$(printf '%s' "$subdomain" | tr '[:upper:]' '[:lower:]' | xargs)"

    # Email address
    echo ""
    echo_info "Enter email address for registration/renewal notifications:"
    printf "> "
    read -r email
    email="$(printf '%s' "$email" | xargs)"

    if [[ -z "$email" ]]; then
        echo_error "Email cannot be empty."
        return 1
    fi

    if ! validate_email "$email"; then
        echo_error "Invalid email format: ${email}"
        return 1
    fi

    # Build domain list
    domains_list="$domain"
    if [[ -n "$subdomain" ]]; then
        domains_list="${subdomain}.${domain}"
    fi

    # Ask for additional domains
    echo ""
    echo_info "Enter additional domains (comma-separated, or leave empty):"
    echo_info "Example: api.example.com, admin.example.com"
    printf "> "
    read -r extra_domains
    extra_domains="$(printf '%s' "$extra_domains" | xargs)"

    if [[ -n "$extra_domains" ]]; then
        local IFS=',' extra_domain
        for extra_domain in $extra_domains; do
            extra_domain="$(printf '%s' "$extra_domain" | xargs | tr '[:upper:]' '[:lower:]')"
            if validate_domain "$extra_domain"; then
                domains_list="${domains_list} ${extra_domain}"
            else
                echo_warning "Skipping invalid domain: ${extra_domain}"
            fi
        done
    fi

    # Confirmation
    echo ""
    echo_bold "Summary:"
    echo "  Plugin:     ${plugin}"
    echo "  Email:      ${email}"
    echo "  Domains:    ${domains_list}"
    echo ""

    echo_info "Proceed with installation? [Y/n]"
    printf "> "
    read -r confirm
    confirm="$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]' | xargs)"

    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "yes" ]] && [[ -n "$confirm" ]]; then
        echo_info "Installation cancelled."
        return 0
    fi

    # Build the certbot command
    local certbot_cmd="certbot --${plugin}"
    local domain_part=""
    local d
    for d in $domains_list; do
        domain_part="${domain_part} -d ${d}"
    done

    certbot_cmd="${certbot_cmd} --non-interactive --agree-tos --email ${email} ${domain_part}"

    echo ""
    echo_info "Executing: ${certbot_cmd}"
    echo ""

    # Open firewall ports
    open_firewall_ports

    # Run certbot
    set +e
    if eval "$certbot_cmd"; then
        set -e
        close_firewall_ports
        echo_success ""
        echo_success "Certificate installed successfully!"
        echo_success "Domains: ${domains_list}"
        echo ""

        # Reload web server
        if [[ "${RELOAD_WEB_SERVER:-true}" == "true" ]]; then
            reload_web_server
        fi

        log_success "Installed certificate for: ${domains_list}"

        # Show certificate info
        local first_domain
        first_domain="$(printf '%s\n' "$domains_list" | awk '{print $1}')"
        local live_dir="${CERTBOT_LIVE_DIR:-/etc/letsencrypt/live}/${first_domain}"
        if [[ -f "${live_dir}/fullchain.pem" ]]; then
            local expiry
            expiry="$(openssl x509 -enddate -noout -in "${live_dir}/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")"
            echo_info "Certificate expires: ${expiry}"
        fi
    else
        set -e
        close_firewall_ports
        echo_error ""
        echo_error "Certificate installation FAILED."
        echo_error "Check: 'certbot certificates' for details."
        log_error "Certificate installation failed for: ${domains_list}"
        return 1
    fi
}

# =============================================================================
# DRY RUN
# =============================================================================

# Perform a dry-run renewal
dry_run_renewal() {
    log_info "Starting dry-run renewal..."

    open_firewall_ports

    set +e
    certbot renew --dry-run --quiet --non-interactive ${CERTBOT_EXTRA_ARGS:-}
    local rc=$?
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
    FORCE_RENEW=true
    echo_warning "Forcing renewal of all certificates..."
    log_warning "Force renewal initiated"

    # First backup
    if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
        backup_letsencrypt
    fi

    renew_all_certificates
    FORCE_RENEW=false
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
            valid)   color="${COLOR_GREEN}${COLOR_BOLD}"   ;;
            expiring_soon|critical) color="${COLOR_YELLOW}${COLOR_BOLD}" ;;
            expired|error) color="${COLOR_RED}${COLOR_BOLD}" ;;
        esac

        printf '%s%-40s %s' "$color" "$name" "${COLOR_RESET}"
        printf '  Domains: %s\n' "$domains"

        if [[ "$remaining" -ge 0 ]]; then
            case "$status" in
                valid)         printf '  Status: ✓ Valid (%d days remaining)\n' "$remaining" ;;
                expiring_soon) printf '  Status: ⚠ Expiring (%d days)\n' "$remaining" ;;
                critical)      printf '  Status: 🔴 Critical (%d days)\n' "$remaining" ;;
                expired)       printf '  Status: ✗ EXPIRED\n' ;;
            esac
        else
            printf '  Status: ✗ Error reading certificate\n'
        fi
        echo ""
    done
}

# =============================================================================
# EXIT TRAP CLEANUP
# =============================================================================

# Cleanup function for certificate operations
cleanup_certificate_ops() {
    # Close any open firewall ports as safety measure
    close_firewall_ports 2>/dev/null || true
}