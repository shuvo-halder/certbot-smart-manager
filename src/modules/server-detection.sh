#!/bin/bash
# =============================================================================
# certbot-smart-manager — Server Detection Module
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/modules/server-detection.sh
# =============================================================================
#
# Detects OS, web server (Nginx/Apache), and firewall (UFW/firewalld).
# Must be sourced after utils.sh.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# GLOBALS
# =============================================================================

OS_ID=""
OS_VERSION=""
OS_NAME=""
PKG_MANAGER="unknown"

WEB_SERVICES=()       # Array of detected web services
WEB_SERVICE_TYPE=""   # "nginx", "apache", or "mixed"
FIREWALL_TYPE="none"  # "none", "ufw", "firewalld"

# =============================================================================
# OS DETECTION
# =============================================================================

detect_os() {
    log_info "Detecting operating system..."

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${NAME:-unknown}"
    elif [[ -r /etc/redhat-release ]]; then
        OS_NAME="$(cat /etc/redhat-release)"
        if grep -qi "centos" /etc/redhat-release 2>/dev/null; then
            OS_ID="centos"
        elif grep -qi "rocky" /etc/redhat-release 2>/dev/null; then
            OS_ID="rocky"
        elif grep -qi "almalinux" /etc/redhat-release 2>/dev/null; then
            OS_ID="almalinux"
        elif grep -qi "fedora" /etc/redhat-release 2>/dev/null; then
            OS_ID="fedora"
        else
            OS_ID="rhel"
        fi
        OS_VERSION="$(grep -oP '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "unknown")"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_NAME="unknown"
    fi

    # Normalize OS ID to lowercase
    OS_ID="$(printf '%s\n' "$OS_ID" | tr '[:upper:]' '[:lower:]')"

    # Determine package manager
    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux)
            if command_exists dnf; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        *)
            if command_exists apt; then
                PKG_MANAGER="apt"
            elif command_exists dnf; then
                PKG_MANAGER="dnf"
            elif command_exists yum; then
                PKG_MANAGER="yum"
            else
                PKG_MANAGER="unknown"
            fi
            ;;
    esac

    log_info "Detected OS: ${OS_ID} ${OS_VERSION} (${OS_NAME})"
    log_debug "Package manager: ${PKG_MANAGER}"
}

# =============================================================================
# WEB SERVER DETECTION
# =============================================================================

detect_web_server() {
    WEB_SERVICES=()
    WEB_SERVICE_TYPE=""
    log_info "Detecting web server..."

    # Check for Nginx
    if command_exists nginx || systemctl is-active --quiet nginx 2>/dev/null; then
        WEB_SERVICES+=("nginx")
        log_debug "Web server detected: nginx"
    fi

    # Check for Apache (apache2 on Debian/Ubuntu, httpd on RHEL/CentOS)
    if systemctl is-active --quiet apache2 2>/dev/null; then
        WEB_SERVICES+=("apache2")
        log_debug "Web server detected: apache2"
    elif systemctl is-active --quiet httpd 2>/dev/null; then
        WEB_SERVICES+=("httpd")
        log_debug "Web server detected: httpd"
    fi

    # Determine type
    if [[ ${#WEB_SERVICES[@]} -eq 0 ]]; then
        WEB_SERVICE_TYPE="none"
        log_info "No active Nginx/Apache service detected."
    elif [[ ${#WEB_SERVICES[@]} -eq 1 ]]; then
        WEB_SERVICE_TYPE="${WEB_SERVICES[0]}"
        log_info "Web server detected: ${WEB_SERVICE_TYPE}"
    else
        WEB_SERVICE_TYPE="mixed"
        log_info "Multiple web servers detected: ${WEB_SERVICES[*]}"
    fi
}

# =============================================================================
# FIREWALL DETECTION
# =============================================================================

detect_firewall() {
    FIREWALL_TYPE="none"
    log_info "Detecting firewall..."

    # Check UFW
    if command_exists ufw; then
        if ufw status 2>/dev/null | grep -qi '^Status: active'; then
            FIREWALL_TYPE="ufw"
            log_info "Firewall detected: UFW (active)"
            return
        fi
    fi

    # Check firewalld
    if command_exists firewall-cmd; then
        if systemctl is-active --quiet firewalld 2>/dev/null || firewall-cmd --state >/dev/null 2>&1; then
            FIREWALL_TYPE="firewalld"
            log_info "Firewall detected: firewalld (active)"
            return
        fi
    fi

    log_info "No active firewall detected."
}

# =============================================================================
# FIREWALL PORT MANAGEMENT
# =============================================================================

# UFW: Open a port temporarily
ufw_open_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if [[ "$FIREWALL_TYPE" != "ufw" ]]; then
        return 0
    fi

    # Check if port is already allowed
    if ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}[[:space:]]+ALLOW|${port}/.*ALLOW"; then
        log_debug "UFW: port ${port}/${proto} already allowed"
        return 0
    fi

    log_info "UFW: opening port ${port}/${proto}"
    ufw allow "${port}/${proto}" 2>/dev/null || true
}

# UFW: Close a port
ufw_close_port() {
    local port="$1"
    local proto="${2:-tcp}"

    if [[ "$FIREWALL_TYPE" != "ufw" ]]; then
        return 0
    fi

    log_info "UFW: closing port ${port}/${proto}"
    ufw delete allow "${port}/${proto}" 2>/dev/null || true
}

# firewalld: Get active zones
firewalld_get_zones() {
    firewall-cmd --get-active-zones 2>/dev/null | awk 'NF && $1 !~ /^[[:space:]]/ { print $1 }'
}

# firewalld: Open a port temporarily
firewalld_open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local zone

    if [[ "$FIREWALL_TYPE" != "firewalld" ]]; then
        return 0
    fi

    while IFS= read -r zone; do
        [[ -z "$zone" ]] && continue

        if firewall-cmd --zone="$zone" --query-port="${port}/${proto}" >/dev/null 2>&1; then
            log_debug "firewalld: port ${port}/${proto} already open in zone ${zone}"
            continue
        fi

        log_info "firewalld: opening port ${port}/${proto} in zone ${zone}"
        firewall-cmd --zone="$zone" --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    done < <(firewalld_get_zones)
}

# firewalld: Close a port
firewalld_close_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local zone

    if [[ "$FIREWALL_TYPE" != "firewalld" ]]; then
        return 0
    fi

    while IFS= read -r zone; do
        [[ -z "$zone" ]] && continue
        log_info "firewalld: closing port ${port}/${proto} in zone ${zone}"
        firewall-cmd --zone="$zone" --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
    done < <(firewalld_get_zones)
}

# =============================================================================
# FIREWALL BATCH OPERATIONS
# =============================================================================

# Open required ports (80/tcp, 443/tcp) for Let's Encrypt validation
open_firewall_ports() {
    log_info "Opening firewall ports for certificate validation..."
    case "$FIREWALL_TYPE" in
        ufw)
            ufw_open_port "80" "tcp"
            ufw_open_port "443" "tcp"
            ;;
        firewalld)
            firewalld_open_port "80" "tcp"
            firewalld_open_port "443" "tcp"
            ;;
        none)
            log_debug "No firewall to configure"
            ;;
    esac
}

# Close ports opened for validation
close_firewall_ports() {
    log_info "Closing firewall ports..."
    case "$FIREWALL_TYPE" in
        ufw)
            ufw_close_port "80" "tcp"
            ufw_close_port "443" "tcp"
            ;;
        firewalld)
            firewalld_close_port "80" "tcp"
            firewalld_close_port "443" "tcp"
            ;;
        none)
            log_debug "No firewall to configure"
            ;;
    esac
}

# =============================================================================
# WEB SERVER RELOAD
# =============================================================================

# Reload detected web servers
reload_web_server() {
    local service

    if [[ ${#WEB_SERVICES[@]} -eq 0 ]]; then
        log_warning "No web server to reload"
        return 0
    fi

    for service in "${WEB_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "Reloading ${service}..."
            systemctl reload "$service" 2>/dev/null && {
                log_success "${service} reloaded successfully"
            } || {
                log_error "Failed to reload ${service}"
            }
        else
            log_warning "${service} is not active; skipping reload"
        fi
    done
}

# =============================================================================
# WEB SERVER INSTALL DETECTION
# =============================================================================

# Detect which Certbot plugin to use based on web server
detect_certbot_plugin() {
    if [[ " ${WEB_SERVICES[*]} " =~ "nginx" ]]; then
        printf '%s\n' "nginx"
    elif [[ " ${WEB_SERVICES[*]} " =~ "apache2" ]] || [[ " ${WEB_SERVICES[*]} " =~ "httpd" ]]; then
        printf '%s\n' "apache"
    else
        printf '%s\n' "manual"
    fi
}