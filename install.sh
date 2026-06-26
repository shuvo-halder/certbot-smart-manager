#!/bin/bash
# =============================================================================
# certbot-smart-manager — One-Click Installer
# =============================================================================
# URL: https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/install.sh
# =============================================================================
#
# Usage:
#   curl -sSL https://your-domain/install.sh | sudo bash
#   wget -O - https://your-domain/install.sh | sudo bash
#
# This script:
#   - Detects Linux OS (Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux/Fedora)
#   - Installs dependencies (curl, wget, openssl, certbot, plugins)
#   - Creates required directories and sets permissions
#   - Installs the main script and modules
#   - Creates systemd service + timer
#   - Creates cron fallback if systemd is unavailable
#   - Is fully idempotent (safe for multiple runs)
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

# Installation paths
LIB_DEST="/usr/local/lib/${PROJECT_NAME}"
MODULES_DEST="${LIB_DEST}/modules"
BIN_DEST="/usr/local/bin"
CONFIG_DIR="/etc/${PROJECT_NAME}"
LOG_FILE="/var/log/${PROJECT_NAME}.log"
LOCK_FILE="/var/lock/${PROJECT_NAME}.lock"
BACKUP_DIR="/var/backups/${PROJECT_NAME}"
SYSTEMD_DIR="/etc/systemd/system"

# Script source paths (relative to install.sh)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT_SRC="${SRC_DIR}/src/${PROJECT_NAME}.sh"
MODULES_SRC="${SRC_DIR}/src/modules"
CONFIG_SRC="${SRC_DIR}/config/${PROJECT_NAME}.conf"
SERVICE_SRC="${SRC_DIR}/systemd/${PROJECT_NAME}.service"
TIMER_SRC="${SRC_DIR}/systemd/${PROJECT_NAME}.timer"

# Install state markers (for idempotency)
INSTALL_MARKER_DIR="${CONFIG_DIR}/.install-state"

# Operation log (for rollback)
INSTALL_LOG="/tmp/${PROJECT_NAME}-install.log"

# =============================================================================
# INITIALIZATION
# =============================================================================

# Ensure we're running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf 'ERROR: This script must be run as root.\n' >&2
    printf 'Usage: curl -sSL https://your-domain/install.sh | sudo bash\n' >&2
    exit 1
fi

# Clear previous install log
: > "$INSTALL_LOG"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

echo_info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
echo_success() { printf '\033[0;32m[OK]\033[0m   %s\n' "$*"; }
echo_warning() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
echo_error()   { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; }
echo_bold()    { printf '\033[1m%s\033[0m\n' "$*"; }

# Log an install operation for potential rollback
_log_operation() {
    printf '%s\n' "$1" >> "$INSTALL_LOG"
}

# Check if a command is available
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if an install step was already completed (idempotency)
_is_step_done() {
    local step_name="$1"
    [[ -f "${INSTALL_MARKER_DIR}/${step_name}.done" ]]
}

# Mark a step as completed
_mark_step_done() {
    local step_name="$1"
    mkdir -p "$INSTALL_MARKER_DIR" 2>/dev/null
    touch "${INSTALL_MARKER_DIR}/${step_name}.done"
    chmod 400 "${INSTALL_MARKER_DIR}/${step_name}.done"
}

# =============================================================================
# OS DETECTION
# =============================================================================

detect_os() {
    echo_info "Detecting operating system..."

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${NAME:-unknown}"
    elif [[ -r /etc/redhat-release ]]; then
        OS_NAME="$(cat /etc/redhat-release)"
        if grep -qi "centos" /etc/redhat-release 2>/dev/null; then OS_ID="centos"
        elif grep -qi "rocky" /etc/redhat-release 2>/dev/null; then OS_ID="rocky"
        elif grep -qi "almalinux" /etc/redhat-release 2>/dev/null; then OS_ID="almalinux"
        elif grep -qi "fedora" /etc/redhat-release 2>/dev/null; then OS_ID="fedora"
        else OS_ID="rhel"; fi
        OS_VERSION="$(grep -oP '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "unknown")"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_NAME="unknown"
    fi

    OS_ID="$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')"

    echo_info "Detected: ${OS_ID} ${OS_VERSION} (${OS_NAME})"

    # Supported OS check
    case "$OS_ID" in
        ubuntu|debian|centos|rhel|rocky|almalinux|fedora|ol)
            return 0
            ;;
        *)
            echo_warning "Unknown OS: ${OS_ID}. Proceeding with best-effort installation."
            return 0
            ;;
    esac
}

# =============================================================================
# PACKAGE MANAGER DETECTION
# =============================================================================

get_package_manager() {
    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
            PKG_UPDATE="apt-get update -qq"
            CERTBOT_PACKAGE="certbot"
            CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
            CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
            DEPS="curl wget openssl ca-certificates systemd"
            ;;
        centos|rhel|rocky|almalinux|ol)
            if command_exists dnf; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y"
                PKG_UPDATE="dnf makecache"
            else
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
                PKG_UPDATE="yum makecache"
            fi
            # EPEL is required for certbot on RHEL/CentOS
            CERTBOT_PACKAGE="certbot"
            CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
            CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
            DEPS="curl wget openssl ca-certificates systemd epel-release"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_INSTALL="dnf install -y"
            PKG_UPDATE="dnf makecache"
            CERTBOT_PACKAGE="certbot"
            CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
            CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
            DEPS="curl wget openssl ca-certificates systemd"
            ;;
        *)
            # Fallback: try to detect available package manager
            if command_exists apt; then
                PKG_MANAGER="apt"
                PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
                PKG_UPDATE="apt-get update -qq"
                CERTBOT_PACKAGE="certbot"
                CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
                CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
                DEPS="curl wget openssl ca-certificates systemd"
            elif command_exists dnf; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y"
                PKG_UPDATE="dnf makecache"
                CERTBOT_PACKAGE="certbot"
                CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
                CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
                DEPS="curl wget openssl ca-certificates systemd"
            elif command_exists yum; then
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
                PKG_UPDATE="yum makecache"
                CERTBOT_PACKAGE="certbot"
                CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
                CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
                DEPS="curl wget openssl ca-certificates systemd epel-release"
            else
                echo_error "No supported package manager found (apt, dnf, yum)."
                echo_error "Please install dependencies manually and re-run."
                exit 1
            fi
            ;;
    esac

    echo_info "Package manager: ${PKG_MANAGER}"
}

# =============================================================================
# INSTALLATION STEPS
# =============================================================================

# Step 1: Install system dependencies
install_dependencies() {
    if _is_step_done "dependencies"; then
        echo_success "Dependencies already installed (idempotent)."
        return 0
    fi

    echo_info "Updating package lists..."
    eval "$PKG_UPDATE" 2>/dev/null || echo_warning "Package update failed; continuing..."

    echo_info "Installing dependencies: ${DEPS}..."
    eval "$PKG_INSTALL $DEPS" 2>/dev/null || {
        echo_warning "Some dependencies could not be installed; continuing..."
    }

    _mark_step_done "dependencies"
    _log_operation "deps:installed"
    echo_success "Dependencies installed."
}

# Step 2: Install Certbot if not present
install_certbot() {
    if _is_step_done "certbot"; then
        echo_success "Certbot already installed (idempotent)."
        return 0
    fi

    if command_exists certbot; then
        echo_success "Certbot is already installed."
        _mark_step_done "certbot"
        return 0
    fi

    echo_info "Installing Certbot..."

    # Try to install certbot via package manager
    if eval "$PKG_INSTALL $CERTBOT_PACKAGE" 2>/dev/null; then
        echo_success "Certbot installed."
    else
        echo_warning "Certbot package installation failed."
        echo_warning "Attempting snap installation (Ubuntu 20.04+ recommended method)..."

        if command_exists snap; then
            snap install core && snap refresh core 2>/dev/null || true
            snap install --classic certbot 2>/dev/null && {
                ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
                echo_success "Certbot installed via snap."
            } || {
                echo_warning "Snap installation failed."
                echo_warning "Please install certbot manually: https://certbot.eff.org"
            }
        else
            echo_warning "snap not available."
            echo_warning "Please install certbot manually: https://certbot.eff.org"
        fi
    fi

    _mark_step_done "certbot"
    _log_operation "certbot:installed"
}

# Step 3: Install Certbot plugins
install_certbot_plugins() {
    if _is_step_done "certbot-plugins"; then
        echo_success "Certbot plugins already installed (idempotent)."
        return 0
    fi

    echo_info "Installing Certbot plugins..."

    # Try nginx plugin
    if command_exists nginx || systemctl is-active --quiet nginx 2>/dev/null; then
        if eval "$PKG_INSTALL $CERTBOT_PLUGIN_NGINX" 2>/dev/null; then
            echo_success "Certbot nginx plugin installed."
        else
            echo_warning "Could not install certbot nginx plugin."
        fi
    fi

    # Try apache plugin
    if systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
        if eval "$PKG_INSTALL $CERTBOT_PLUGIN_APACHE" 2>/dev/null; then
            echo_success "Certbot apache plugin installed."
        else
            echo_warning "Could not install certbot apache plugin."
        fi
    fi

    _mark_step_done "certbot-plugins"
    _log_operation "plugins:installed"
}

# Step 4: Create directory structure
create_directories() {
    if _is_step_done "directories"; then
        echo_success "Directories already exist (idempotent)."
        return 0
    fi

    echo_info "Creating directory structure..."

    local dirs=(
        "$LIB_DEST"
        "$MODULES_DEST"
        "$CONFIG_DIR"
        "$(dirname "$LOG_FILE")"
        "$(dirname "$LOCK_FILE")"
        "$BACKUP_DIR"
    )

    local dir
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null || true
        chmod 755 "$dir" 2>/dev/null || true
        _log_operation "dir:${dir}"
    done

    _mark_step_done "directories"
    echo_success "Directories created."
}

# Step 5: Install main script and modules
install_scripts() {
    if _is_step_done "scripts"; then
        echo_success "Scripts already installed (idempotent)."
        return 0
    fi

    echo_info "Installing main script and modules..."

    # Install main script
    if [[ -f "$MAIN_SCRIPT_SRC" ]]; then
        install -m 755 "$MAIN_SCRIPT_SRC" "${LIB_DEST}/${PROJECT_NAME}.sh"
        _log_operation "file:${LIB_DEST}/${PROJECT_NAME}.sh"
        echo_success "Main script installed."
    else
        echo_error "Main script not found: ${MAIN_SCRIPT_SRC}"
        echo_error "Installation aborted."
        rollback_install "Main script source missing."
        exit 1
    fi

    # Install modules
    if [[ -d "$MODULES_SRC" ]]; then
        local module
        for module in "${MODULES_SRC}"/*.sh; do
            if [[ -f "$module" ]]; then
                install -m 640 "$module" "$MODULES_DEST/"
                _log_operation "file:${MODULES_DEST}/$(basename "$module")"
            fi
        done
        echo_success "Modules installed (${MODULES_DEST})."
    else
        echo_warning "Module directory not found: ${MODULES_SRC}"
    fi

    # Create symlink at /usr/local/bin/ssl-manager
    ln -sf "${LIB_DEST}/${PROJECT_NAME}.sh" "${BIN_DEST}/${SCRIPT_NAME}"
    _log_operation "symlink:${BIN_DEST}/${SCRIPT_NAME}"
    chmod 755 "${BIN_DEST}/${SCRIPT_NAME}"
    echo_success "Symlink created: ${BIN_DEST}/${SCRIPT_NAME}"

    _mark_step_done "scripts"
}

# Step 6: Install configuration file
install_config() {
    if _is_step_done "config"; then
        echo_success "Configuration already installed (idempotent)."
        return 0
    fi

    echo_info "Installing configuration file..."

    if [[ -f "$CONFIG_SRC" ]]; then
        # Don't overwrite existing config if it exists (user may have customized it)
        if [[ ! -f "${CONFIG_DIR}/${PROJECT_NAME}.conf" ]]; then
            install -m 600 "$CONFIG_SRC" "${CONFIG_DIR}/${PROJECT_NAME}.conf"
            _log_operation "file:${CONFIG_DIR}/${PROJECT_NAME}.conf"
            echo_success "Configuration file installed."
        else
            echo_warning "Configuration file already exists; keeping existing version."
        fi
    else
        echo_warning "Config source not found: ${CONFIG_SRC}"
        # Create a default config
        cat > "${CONFIG_DIR}/${PROJECT_NAME}.conf" << 'CONFEOF'
# certbot-smart-manager configuration
THRESHOLD_DAYS=30
CRITICAL_THRESHOLD_DAYS=7
LOG_FILE="/var/log/certbot-smart-manager.log"
LOG_LEVEL="INFO"
BACKUP_ENABLED=true
BACKUP_DIR="/var/backups/certbot-smart-manager"
BACKUP_RETENTION_DAYS=30
NOTIFICATION_METHOD="console"
RELOAD_WEB_SERVER=true
CONFEOF
        chmod 600 "${CONFIG_DIR}/${PROJECT_NAME}.conf"
        _log_operation "file:${CONFIG_DIR}/${PROJECT_NAME}.conf"
        echo_success "Default configuration created."
    fi

    _mark_step_done "config"
}

# Step 7: Set up permissions
setup_permissions() {
    if _is_step_done "permissions"; then
        echo_success "Permissions already set (idempotent)."
        return 0
    fi

    echo_info "Setting up file permissions..."

    # Library files
    chown -R root:root "$LIB_DEST" 2>/dev/null || true
    chmod -R 755 "$LIB_DEST" 2>/dev/null || true
    chmod 640 "$MODULES_DEST"/*.sh 2>/dev/null || true

    # Binary symlink
    chown root:root "${BIN_DEST}/${SCRIPT_NAME}" 2>/dev/null || true
    chmod 755 "${BIN_DEST}/${SCRIPT_NAME}" 2>/dev/null || true

    # Config
    chown -R root:root "$CONFIG_DIR" 2>/dev/null || true
    chmod 755 "$CONFIG_DIR" 2>/dev/null || true
    chmod 600 "${CONFIG_DIR}/${PROJECT_NAME}.conf" 2>/dev/null || true

    # Log file
    touch "$LOG_FILE" 2>/dev/null || true
    chown root:root "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true

    # Lock directory
    chmod 755 "$(dirname "$LOCK_FILE")" 2>/dev/null || true

    # Backup directory
    chown -R root:root "$BACKUP_DIR" 2>/dev/null || true
    chmod 750 "$BACKUP_DIR" 2>/dev/null || true

    _mark_step_done "permissions"
    echo_success "Permissions configured."
}

# Step 8: Install systemd service
install_systemd_service() {
    if _is_step_done "systemd-service"; then
        echo_success "Systemd service already installed (idempotent)."
        return 0
    fi

    # Check if systemd is available
    if ! command_exists systemctl; then
        echo_warning "systemd not available; skipping systemd installation."
        return 0
    fi

    echo_info "Installing systemd service..."

    if [[ -f "$SERVICE_SRC" ]]; then
        install -m 644 "$SERVICE_SRC" "${SYSTEMD_DIR}/${PROJECT_NAME}.service"
        _log_operation "file:${SYSTEMD_DIR}/${PROJECT_NAME}.service"
        echo_success "Systemd service installed."
    else
        echo_warning "Service file not found: ${SERVICE_SRC}"
        # Create a minimal service file
        cat > "${SYSTEMD_DIR}/${PROJECT_NAME}.service" << SERVEOF
[Unit]
Description=Certbot Smart Manager - SSL Certificate Renewal Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_DEST}/${SCRIPT_NAME} --auto
User=root
UMask=027
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=CONFIG_FILE=${CONFIG_DIR}/${PROJECT_NAME}.conf

[Install]
WantedBy=multi-user.target
SERVEOF
        chmod 644 "${SYSTEMD_DIR}/${PROJECT_NAME}.service"
        _log_operation "file:${SYSTEMD_DIR}/${PROJECT_NAME}.service"
        echo_warning "Minimal service file created."
    fi

    systemctl daemon-reload 2>/dev/null || true

    _mark_step_done "systemd-service"
}

# Step 9: Install systemd timer
install_systemd_timer() {
    if _is_step_done "systemd-timer"; then
        echo_success "Systemd timer already installed (idempotent)."
        return 0
    fi

    if ! command_exists systemctl; then
        echo_warning "systemd not available; skipping timer installation."
        return 0
    fi

    echo_info "Installing systemd timer..."

    if [[ -f "$TIMER_SRC" ]]; then
        install -m 644 "$TIMER_SRC" "${SYSTEMD_DIR}/${PROJECT_NAME}.timer"
        _log_operation "file:${SYSTEMD_DIR}/${PROJECT_NAME}.timer"
        echo_success "Systemd timer installed."
    else
        echo_warning "Timer file not found: ${TIMER_SRC}"
        # Create a minimal timer file
        cat > "${SYSTEMD_DIR}/${PROJECT_NAME}.timer" << TIMEREOF
[Unit]
Description=Certbot Smart Manager - Twice Daily Timer
Requires=${PROJECT_NAME}.service

[Timer]
OnCalendar=*-*-* 03:00:00
OnCalendar=*-*-* 15:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TIMEREOF
        chmod 644 "${SYSTEMD_DIR}/${PROJECT_NAME}.timer"
        _log_operation "file:${SYSTEMD_DIR}/${PROJECT_NAME}.timer"
        echo_warning "Minimal timer file created."
    fi

    systemctl daemon-reload 2>/dev/null || true

    _mark_step_done "systemd-timer"
}

# Step 10: Enable and start systemd timer
enable_systemd_timer() {
    if _is_step_done "systemd-enabled"; then
        echo_success "Systemd timer already enabled (idempotent)."
        return 0
    fi

    if ! command_exists systemctl; then
        return 0
    fi

    echo_info "Enabling and starting systemd timer..."

    systemctl enable "${PROJECT_NAME}.timer" 2>/dev/null && {
        _log_operation "systemd_enable:${PROJECT_NAME}.timer"
        echo_success "Timer enabled: ${PROJECT_NAME}.timer"
    } || {
        echo_warning "Failed to enable timer."
    }

    systemctl start "${PROJECT_NAME}.timer" 2>/dev/null && {
        _log_operation "systemd_start:${PROJECT_NAME}.timer"
        echo_success "Timer started."
    } || {
        echo_warning "Failed to start timer."
    }

    _mark_step_done "systemd-enabled"
}

# Step 11: Create cron fallback (if systemd not available)
install_cron_fallback() {
    if _is_step_done "cron"; then
        echo_success "Cron already configured (idempotent)."
        return 0
    fi

    # Only install cron if systemd timer is not available
    if command_exists systemctl && systemctl list-units --type=timer 2>/dev/null | grep -q "${PROJECT_NAME}.timer"; then
        echo_success "Systemd timer active; cron fallback not needed."
        _mark_step_done "cron"
        return 0
    fi

    echo_info "Creating cron fallback..."

    local cron_line="0 3,15 * * * ${BIN_DEST}/${SCRIPT_NAME} --auto >> ${LOG_FILE} 2>&1"

    # Check if cron entry already exists
    if crontab -l 2>/dev/null | grep -qF "${SCRIPT_NAME} --auto"; then
        echo_success "Cron entry already exists."
    else
        (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab - 2>/dev/null && {
            echo_success "Cron entry added."
            _log_operation "cron:added"
        } || {
            echo_warning "Failed to add cron entry."
        }
    fi

    _mark_step_done "cron"
}

# Step 12: Verify installation
verify_installation() {
    echo_info "Verifying installation..."

    local errors=0

    # Check main script exists
    if [[ -f "${LIB_DEST}/${PROJECT_NAME}.sh" ]]; then
        echo_success "Main script: ${LIB_DEST}/${PROJECT_NAME}.sh"
    else
        echo_error "Main script missing!"
        errors=$((errors + 1))
    fi

    # Check symlink
    if [[ -L "${BIN_DEST}/${SCRIPT_NAME}" ]] || [[ -f "${BIN_DEST}/${SCRIPT_NAME}" ]]; then
        echo_success "Executable: ${BIN_DEST}/${SCRIPT_NAME}"
    else
        echo_error "Executable symlink missing!"
        errors=$((errors + 1))
    fi

    # Check config
    if [[ -f "${CONFIG_DIR}/${PROJECT_NAME}.conf" ]]; then
        echo_success "Config: ${CONFIG_DIR}/${PROJECT_NAME}.conf"
    else
        echo_error "Config file missing!"
        errors=$((errors + 1))
    fi

    # Check log file
    if [[ -f "$LOG_FILE" ]]; then
        echo_success "Log: ${LOG_FILE}"
    else
        echo_warning "Log file not yet created (will be created on first run)."
    fi

    # Check modules
    local module_count
    module_count="$(ls -1 "$MODULES_DEST"/*.sh 2>/dev/null | wc -l)"
    if [[ $module_count -gt 0 ]]; then
        echo_success "Modules: ${module_count} installed"
    else
        echo_warning "No modules found."
    fi

    # Check systemd
    if command_exists systemctl; then
        if [[ -f "${SYSTEMD_DIR}/${PROJECT_NAME}.service" ]]; then
            echo_success "Systemd service: ${PROJECT_NAME}.service"
        else
            echo_warning "Systemd service not installed."
        fi
        if [[ -f "${SYSTEMD_DIR}/${PROJECT_NAME}.timer" ]]; then
            echo_success "Systemd timer: ${PROJECT_NAME}.timer"
        else
            echo_warning "Systemd timer not installed."
        fi
    fi

    # Test executable
    if "${BIN_DEST}/${SCRIPT_NAME}" --version 2>/dev/null; then
        echo_success "Executable works."
    else
        echo_warning "Executable test failed (may require sudo)."
    fi

    return $errors
}

# =============================================================================
# ROLLBACK
# =============================================================================

rollback_install() {
    local error_msg="${1:-Installation failed}"

    echo_warning ""
    echo_warning "=========================================="
    echo_warning "  ROLLING BACK INSTALLATION"
    echo_warning "=========================================="
    echo_warning ""
    echo_warning "Reason: ${error_msg}"

    if [[ ! -f "$INSTALL_LOG" ]]; then
        echo_warning "No install log found; performing best-effort cleanup."
    else
        # Reverse operations
        local operations=()
        while IFS= read -r line; do
            operations+=("$line")
        done < "$INSTALL_LOG"

        local i
        for (( i=${#operations[@]}-1; i>=0; i-- )); do
            local op="${operations[$i]}"
            case "$op" in
                file:*)
                    local f="${op#file:}"
                    rm -f "$f" 2>/dev/null || true
                    ;;
                symlink:*)
                    local s="${op#symlink:}"
                    rm -f "$s" 2>/dev/null || true
                    ;;
                dir:*)
                    local d="${op#dir:}"
                    rmdir "$d" 2>/dev/null || true
                    ;;
                systemd_enable:*)
                    local u="${op#systemd_enable:}"
                    systemctl disable "$u" 2>/dev/null || true
                    ;;
                systemd_start:*)
                    local u="${op#systemd_start:}"
                    systemctl stop "$u" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    # Remove marker directory
    rm -rf "$INSTALL_MARKER_DIR" 2>/dev/null || true

    echo_error ""
    echo_error "=========================================="
    echo_error "  INSTALLATION FAILED — ROLLED BACK"
    echo_error "=========================================="
    echo_error ""
    echo_error "${error_msg}"
    echo_error ""
    echo_error "Please check the error above and try again."
    echo_error "If the issue persists, please open an issue:"
    echo_error "https://github.com/shuvo-halder/${PROJECT_NAME}/issues"
    echo_error ""

    exit 1
}

# =============================================================================
# POST-INSTALL MESSAGE
# =============================================================================

show_summary() {
    echo ""
    echo_bold "========================================"
    echo_bold "  ${PROJECT_NAME} v${VERSION}"
    echo_bold "  Installation Complete!"
    echo_bold "========================================"
    echo ""
    echo_info "Installation paths:"
    echo "  Executable:  ${BIN_DEST}/${SCRIPT_NAME}"
    echo "  Library:     ${LIB_DEST}/"
    echo "  Config:      ${CONFIG_DIR}/${PROJECT_NAME}.conf"
    echo "  Log:         ${LOG_FILE}"
    echo "  Backup:      ${BACKUP_DIR}/"
    echo ""

    if command_exists systemctl; then
        echo_info "Systemd timer status:"
        systemctl status "${PROJECT_NAME}.timer" 2>/dev/null | head -n 5 || true
        echo ""
    fi

    echo_bold "Commands:"
    echo "  ssl-manager                 Interactive menu"
    echo "  ssl-manager --auto          Automatic renewal"
    echo "  ssl-manager --scan          Scan certificates"
    echo "  ssl-manager --check         Check expiry"
    echo "  ssl-manager --renew         Renew certificates"
    echo "  ssl-manager --dry-run       Test renewal"
    echo "  ssl-manager --install       Install new certificate"
    echo "  ssl-manager --configure     Configure notifications"
    echo "  ssl-manager --backup        Backup /etc/letsencrypt/"
    echo "  ssl-manager --help          Show help"
    echo ""
    echo_bold "Systemd:"
    echo "  sudo systemctl status ${PROJECT_NAME}.timer"
    echo "  sudo systemctl status ${PROJECT_NAME}.service"
    echo "  sudo journalctl -u ${PROJECT_NAME}.service"
    echo ""
    echo_bold "Logs:"
    echo "  tail -f ${LOG_FILE}"
    echo ""

    if command_exists systemctl; then
        if systemctl is-active --quiet "${PROJECT_NAME}.timer" 2>/dev/null; then
            echo_success "Timer is running. Certificates will be checked twice daily."
        else
            echo_warning "Timer is not running. Enable with:"
            echo "  sudo systemctl enable --now ${PROJECT_NAME}.timer"
        fi
    fi

    echo ""
    echo_bold "Next scheduled runs:"
    if command_exists systemctl; then
        systemctl list-timers "${PROJECT_NAME}.timer" 2>/dev/null | tail -n +2 || echo "  (check with: systemctl list-timers)"
    fi

    echo ""
    echo_success "Installation complete!"
    echo ""

    # Log installation
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Installation completed successfully" >> "$LOG_FILE" 2>/dev/null || true
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

main() {
    echo_bold ""
    echo_bold "========================================"
    echo_bold "  ${PROJECT_NAME} v${VERSION}"
    echo_bold "  One-Click Installer"
    echo_bold "========================================"
    echo ""

    # Trap errors for rollback
    trap 'rollback_install "Unexpected error during installation."' ERR INT TERM

    # Step-by-step installation
    detect_os
    get_package_manager
    echo ""

    install_dependencies
    echo ""

    install_certbot
    echo ""

    install_certbot_plugins
    echo ""

    create_directories
    echo ""

    install_scripts
    echo ""

    install_config
    echo ""

    setup_permissions
    echo ""

    install_systemd_service
    echo ""

    install_systemd_timer
    echo ""

    enable_systemd_timer
    echo ""

    install_cron_fallback
    echo ""

    # Remove error trap for verification (non-fatal)
    trap - ERR INT TERM

    verify_installation
    echo ""

    show_summary

    # Clean up install log
    rm -f "$INSTALL_LOG" 2>/dev/null || true
}

# =============================================================================
# RUN
# =============================================================================
main