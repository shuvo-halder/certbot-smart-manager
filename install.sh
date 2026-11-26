#!/bin/bash
# =============================================================================
# certbot-smart-manager — One-Click Installer
# =============================================================================
# URL: https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/install.sh
# =============================================================================
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/install.sh | sudo bash
#   wget -O - https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/install.sh | sudo bash
#   sudo bash install.sh            (from a cloned repository)
#
# This script:
#   - Detects Linux OS (Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux/Fedora/Oracle)
#   - Installs dependencies (curl, wget, openssl, tar, certbot, plugins)
#   - Downloads the project sources when run via a pipe (curl | bash)
#   - Creates required directories and sets permissions
#   - Installs (or upgrades) the main script and modules
#   - Creates systemd service + timer
#   - Creates cron fallback if systemd is unavailable
#   - Is fully idempotent (safe for multiple runs; re-running upgrades)
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONSTANTS
# =============================================================================
INSTALLER_VERSION="1.0.0"
PROJECT_NAME="certbot-smart-manager"
SCRIPT_NAME="ssl-manager"

# Names of the shipped files (must match the files in this repository)
CONFIG_NAME="certbot-smart.conf"
UNIT_NAME="certbot-smart"

# Names used by older installer versions — migrated/removed on upgrade
LEGACY_UNIT_NAME="certbot-smart-manager"
LEGACY_CONFIG_NAME="certbot-smart-manager.conf"

# Installation paths
LIB_DEST="/usr/local/lib/${PROJECT_NAME}"
MODULES_DEST="${LIB_DEST}/modules"
BIN_DEST="/usr/local/bin"
CONFIG_DIR="/etc/${PROJECT_NAME}"
CONFIG_DEST="${CONFIG_DIR}/${CONFIG_NAME}"
LOG_FILE="/var/log/${PROJECT_NAME}.log"
LOCK_FILE="/var/lock/${PROJECT_NAME}.lock"
BACKUP_DIR="/var/backups/${PROJECT_NAME}"
STATE_DIR="/var/lib/${PROJECT_NAME}"
SYSTEMD_DIR="/etc/systemd/system"
# certbot runs every executable here after each successful renewal
DEPLOY_HOOK_DEST="/etc/letsencrypt/renewal-hooks/deploy/${PROJECT_NAME}-reload.sh"

# Where to download the sources from when not run from a checkout
REPO_TARBALL_URL="${REPO_TARBALL_URL:-https://github.com/shuvo-halder/certbot-smart-manager/archive/refs/heads/main.tar.gz}"

# Install state markers (for idempotency of slow steps)
INSTALL_MARKER_DIR="${CONFIG_DIR}/.install-state"

# Temporary working files (created securely below)
INSTALL_LOG=""
DOWNLOAD_DIR=""

# =============================================================================
# INITIALIZATION
# =============================================================================

# Ensure we're running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf 'ERROR: This script must be run as root.\n' >&2
    printf 'Usage: curl -sSL https://raw.githubusercontent.com/shuvo-halder/certbot-smart-manager/main/install.sh | sudo bash\n' >&2
    exit 1
fi

# Operation log for rollback. mktemp — a fixed /tmp path written as root
# could be pre-created as a symlink by another user.
INSTALL_LOG="$(mktemp "/tmp/${PROJECT_NAME}-install.XXXXXX")"

# =============================================================================
# SOURCE PATHS
# =============================================================================

# When piped (curl | bash) BASH_SOURCE is empty; fall back to $0 / cwd.
set_source_paths() {
    SRC_DIR="$1"
    MAIN_SCRIPT_SRC="${SRC_DIR}/src/${PROJECT_NAME}.sh"
    MODULES_SRC="${SRC_DIR}/src/modules"
    CONFIG_SRC="${SRC_DIR}/config/${CONFIG_NAME}"
    SERVICE_SRC="${SRC_DIR}/systemd/${UNIT_NAME}.service"
    TIMER_SRC="${SRC_DIR}/systemd/${UNIT_NAME}.timer"
    HOOK_SRC="${SRC_DIR}/hooks/deploy-reload.sh"
}

_self="${BASH_SOURCE[0]:-$0}"
if [[ -f "$_self" ]]; then
    set_source_paths "$(cd "$(dirname "$_self")" && pwd)"
else
    set_source_paths "$(pwd)"
fi

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

# Install a file; record it for rollback only if it did not exist before
# (so a failed upgrade never deletes a previously working installation).
_install_file() {
    local mode="$1" src="$2" dest="$3"
    local existed=false
    [[ -e "$dest" ]] && existed=true
    install -m "$mode" "$src" "$dest"
    if [[ "$existed" == "false" ]]; then
        _log_operation "file:${dest}"
    fi
}

# Install a text file with CR characters stripped (protects against files
# checked out with Windows CRLF line endings, which break systemd / bash)
_install_text_file() {
    local mode="$1" src="$2" dest="$3" tmp
    tmp="$(mktemp)"
    tr -d '\r' < "$src" > "$tmp"
    _install_file "$mode" "$tmp" "$dest"
    rm -f "$tmp"
}

# Remove temporary files on exit
_cleanup_tmp() {
    [[ -n "$INSTALL_LOG" ]] && rm -f "$INSTALL_LOG" 2>/dev/null
    [[ -n "$DOWNLOAD_DIR" ]] && rm -rf "$DOWNLOAD_DIR" 2>/dev/null
    return 0
}
trap _cleanup_tmp EXIT

# =============================================================================
# OS DETECTION
# =============================================================================

# Read a field from /etc/os-release in a subshell. Sourcing it directly
# would overwrite variables such as VERSION and NAME in this script.
os_release_field() {
    local field="$1"
    (
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${!field:-unknown}"
    )
}

detect_os() {
    echo_info "Detecting operating system..."

    if [[ -r /etc/os-release ]]; then
        OS_ID="$(os_release_field ID)"
        OS_VERSION="$(os_release_field VERSION_ID)"
        OS_NAME="$(os_release_field NAME)"
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

_set_apt() {
    PKG_MANAGER="apt"
    PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    PKG_UPDATE="apt-get update -qq"
    NEEDS_EPEL=false
}

_set_dnf_yum() {
    if command_exists dnf; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache"
    else
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
    fi
}

get_package_manager() {
    CERTBOT_PACKAGE="certbot"
    CERTBOT_PLUGIN_NGINX="python3-certbot-nginx"
    CERTBOT_PLUGIN_APACHE="python3-certbot-apache"
    DEPS="curl wget openssl ca-certificates tar"

    case "$OS_ID" in
        ubuntu|debian)
            _set_apt
            ;;
        centos|rhel|rocky|almalinux|ol)
            _set_dnf_yum
            # EPEL is required for certbot on RHEL-family systems
            NEEDS_EPEL=true
            ;;
        fedora)
            _set_dnf_yum
            NEEDS_EPEL=false
            ;;
        *)
            if command_exists apt-get; then
                _set_apt
            elif command_exists dnf || command_exists yum; then
                _set_dnf_yum
                NEEDS_EPEL=true
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
    eval "$PKG_UPDATE" >/dev/null 2>&1 || echo_warning "Package update failed; continuing..."

    # EPEL is installed separately: if it is unavailable (e.g. on RHEL
    # without the EPEL repo configured) it must not make dnf/yum reject the
    # whole dependency list.
    if [[ "${NEEDS_EPEL:-false}" == "true" ]]; then
        echo_info "Installing EPEL repository..."
        eval "$PKG_INSTALL epel-release" >/dev/null 2>&1 \
            || echo_warning "epel-release could not be installed; certbot may be unavailable. See https://docs.fedoraproject.org/en-US/epel/"
    fi

    echo_info "Installing dependencies: ${DEPS//$'\n'/ }..."
    local pkg failed=()
    if ! eval "$PKG_INSTALL $DEPS" >/dev/null 2>&1; then
        # Retry one by one so a single missing package does not block the rest
        for pkg in curl wget openssl ca-certificates tar; do
            eval "$PKG_INSTALL $pkg" >/dev/null 2>&1 || failed+=("$pkg")
        done
    fi
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo_warning "Could not install: $(IFS=' '; printf '%s' "${failed[*]}"); continuing..."
    fi

    _mark_step_done "dependencies"
    echo_success "Dependencies installed."
}

# Step 2: Make sure the project sources are available.
# When run as `curl ... | bash` there is no checkout next to this script,
# so download the release tarball.
ensure_sources() {
    if [[ -f "$MAIN_SCRIPT_SRC" ]] && [[ -d "$MODULES_SRC" ]]; then
        echo_success "Using local sources: ${SRC_DIR}"
        return 0
    fi

    echo_info "Local sources not found; downloading ${REPO_TARBALL_URL}..."
    DOWNLOAD_DIR="$(mktemp -d "/tmp/${PROJECT_NAME}-src.XXXXXX")"

    local tarball="${DOWNLOAD_DIR}/source.tar.gz"
    if command_exists curl; then
        curl -fsSL "$REPO_TARBALL_URL" -o "$tarball"
    elif command_exists wget; then
        wget -q -O "$tarball" "$REPO_TARBALL_URL"
    else
        echo_error "Neither curl nor wget is available to download the sources."
        return 1
    fi

    tar -xzf "$tarball" -C "$DOWNLOAD_DIR"

    local extracted
    extracted="$(find "$DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -z "$extracted" ]] || [[ ! -f "${extracted}/src/${PROJECT_NAME}.sh" ]]; then
        echo_error "Downloaded archive does not contain the expected project layout."
        return 1
    fi

    set_source_paths "$extracted"
    echo_success "Sources downloaded."
}

# Step 3: Install Certbot if not present
install_certbot() {
    if command_exists certbot; then
        echo_success "Certbot is already installed."
        return 0
    fi

    echo_info "Installing Certbot..."

    if eval "$PKG_INSTALL $CERTBOT_PACKAGE" >/dev/null 2>&1 && command_exists certbot; then
        echo_success "Certbot installed."
    else
        echo_warning "Certbot package installation failed."
        echo_warning "Attempting snap installation (Ubuntu 20.04+ recommended method)..."

        if command_exists snap; then
            { snap install core && snap refresh core; } >/dev/null 2>&1 || true
            if snap install --classic certbot >/dev/null 2>&1; then
                ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
                echo_success "Certbot installed via snap."
            else
                echo_warning "Snap installation failed."
                echo_warning "Please install certbot manually: https://certbot.eff.org"
            fi
        else
            echo_warning "snap not available."
            echo_warning "Please install certbot manually: https://certbot.eff.org"
        fi
    fi
}

# Step 4: Install Certbot plugins (only for detected web servers)
install_certbot_plugins() {
    echo_info "Checking Certbot plugins..."

    if command_exists nginx || systemctl is-active --quiet nginx 2>/dev/null; then
        if eval "$PKG_INSTALL $CERTBOT_PLUGIN_NGINX" >/dev/null 2>&1; then
            echo_success "Certbot nginx plugin installed."
        else
            echo_warning "Could not install certbot nginx plugin (${CERTBOT_PLUGIN_NGINX})."
        fi
    fi

    if command_exists apache2 || command_exists httpd \
        || systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
        if eval "$PKG_INSTALL $CERTBOT_PLUGIN_APACHE" >/dev/null 2>&1; then
            echo_success "Certbot apache plugin installed."
        else
            echo_warning "Could not install certbot apache plugin (${CERTBOT_PLUGIN_APACHE})."
        fi
    fi
}

# Step 5: Create directory structure
create_directories() {
    echo_info "Creating directory structure..."

    local dirs=(
        "$LIB_DEST"
        "$MODULES_DEST"
        "$CONFIG_DIR"
        "$BACKUP_DIR"
        "$STATE_DIR"
    )

    local dir
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            _log_operation "dir:${dir}"
        fi
    done

    echo_success "Directories created."
}

# Step 6: Install (or upgrade) main script and modules.
# Always runs, so re-running the installer upgrades an existing install.
install_scripts() {
    echo_info "Installing main script and modules..."

    if [[ ! -f "$MAIN_SCRIPT_SRC" ]]; then
        echo_error "Main script not found: ${MAIN_SCRIPT_SRC}"
        rollback_install "Main script source missing."
    fi

    _install_text_file 755 "$MAIN_SCRIPT_SRC" "${LIB_DEST}/${PROJECT_NAME}.sh"
    echo_success "Main script installed."

    if [[ -d "$MODULES_SRC" ]]; then
        local module
        for module in "${MODULES_SRC}"/*.sh; do
            [[ -f "$module" ]] || continue
            _install_text_file 640 "$module" "${MODULES_DEST}/$(basename "$module")"
        done
        echo_success "Modules installed (${MODULES_DEST})."
    else
        rollback_install "Module directory not found: ${MODULES_SRC}"
    fi

    # Symlink at /usr/local/bin/ssl-manager
    local link="${BIN_DEST}/${SCRIPT_NAME}"
    local link_existed=false
    [[ -L "$link" || -e "$link" ]] && link_existed=true
    ln -sfn "${LIB_DEST}/${PROJECT_NAME}.sh" "$link"
    [[ "$link_existed" == "false" ]] && _log_operation "symlink:${link}"
    echo_success "Symlink created: ${link}"

    if [[ ":$PATH:" != *":${BIN_DEST}:"* ]]; then
        echo_warning "${BIN_DEST} is not in your PATH."
        echo_warning "Use the full path: ${BIN_DEST}/${SCRIPT_NAME}"
        echo_warning "For Bash, run: export PATH=\"\$PATH:${BIN_DEST}\""
    fi
}

# Step 7: Install configuration file (never overwrites an existing one)
install_config() {
    echo_info "Installing configuration file..."

    # Migrate a config written by older installer versions under the old name
    if [[ ! -f "$CONFIG_DEST" ]] && [[ -f "${CONFIG_DIR}/${LEGACY_CONFIG_NAME}" ]]; then
        mv "${CONFIG_DIR}/${LEGACY_CONFIG_NAME}" "$CONFIG_DEST"
        echo_warning "Migrated legacy config ${LEGACY_CONFIG_NAME} -> ${CONFIG_NAME}"
    fi

    if [[ -f "$CONFIG_DEST" ]]; then
        echo_warning "Configuration file already exists; keeping existing version."
        return 0
    fi

    if [[ -f "$CONFIG_SRC" ]]; then
        # Strip CR in case the file was checked out with Windows line endings
        _install_text_file 600 "$CONFIG_SRC" "$CONFIG_DEST"
        echo_success "Configuration file installed."
    else
        echo_warning "Config source not found: ${CONFIG_SRC}"
        ( umask 077; cat > "$CONFIG_DEST" << 'CONFEOF'
# certbot-smart-manager configuration
THRESHOLD_DAYS=30
CRITICAL_THRESHOLD_DAYS=7
LOG_FILE="/var/log/certbot-smart-manager.log"
LOG_LEVEL="INFO"
BACKUP_ENABLED=true
BACKUP_DIR="/var/backups/certbot-smart-manager"
BACKUP_RETENTION_DAYS=30
BACKUP_ARCHIVE=false
NOTIFICATION_METHOD="console"
RELOAD_WEB_SERVER=true
CONFEOF
        )
        _log_operation "file:${CONFIG_DEST}"
        echo_success "Default configuration created."
    fi
}

# Step 8: Set up permissions
setup_permissions() {
    echo_info "Setting up file permissions..."

    # Library files
    chown -R root:root "$LIB_DEST" 2>/dev/null || true
    chmod 755 "$LIB_DEST" "$MODULES_DEST" 2>/dev/null || true
    chmod 755 "${LIB_DEST}/${PROJECT_NAME}.sh" 2>/dev/null || true
    chmod 640 "$MODULES_DEST"/*.sh 2>/dev/null || true

    # Config (contains SMTP password / tokens)
    chown -R root:root "$CONFIG_DIR" 2>/dev/null || true
    chmod 750 "$CONFIG_DIR" 2>/dev/null || true
    chmod 600 "$CONFIG_DEST" 2>/dev/null || true

    # Log file
    if [[ ! -e "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        _log_operation "file:${LOG_FILE}"
    fi
    chown root:root "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true

    # Backup directory (contains private keys)
    chown root:root "$BACKUP_DIR" 2>/dev/null || true
    chmod 750 "$BACKUP_DIR" 2>/dev/null || true

    echo_success "Permissions configured."
}

# Remove units installed by older versions under the old name
migrate_legacy_units() {
    command_exists systemctl || return 0

    local unit changed=false
    for unit in "${LEGACY_UNIT_NAME}.timer" "${LEGACY_UNIT_NAME}.service"; do
        if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            rm -f "${SYSTEMD_DIR}/${unit}"
            echo_warning "Removed legacy unit: ${unit}"
            changed=true
        fi
    done

    if [[ "$changed" == "true" ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

# Step 9: Install systemd service + timer (always refreshed on upgrade)
# Install the certbot deploy hook that reloads nginx/apache after EVERY
# successful renewal — including renewals done by certbot's own timer
# (certbot.timer / snap.certbot.renew.timer), which would otherwise leave
# the web server serving the old certificate until it expires.
install_deploy_hook() {
    echo_info "Installing certbot deploy hook..."

    if [[ ! -f "$HOOK_SRC" ]]; then
        echo_warning "Deploy hook source not found: ${HOOK_SRC}; skipping."
        return 0
    fi

    mkdir -p "$(dirname "$DEPLOY_HOOK_DEST")"
    _install_text_file 755 "$HOOK_SRC" "$DEPLOY_HOOK_DEST"
    echo_success "Deploy hook installed: ${DEPLOY_HOOK_DEST}"
}

install_systemd_units() {
    if ! command_exists systemctl; then
        echo_warning "systemd not available; skipping systemd installation."
        return 0
    fi

    migrate_legacy_units

    echo_info "Installing systemd service and timer..."

    if [[ -f "$SERVICE_SRC" ]]; then
        _install_text_file 644 "$SERVICE_SRC" "${SYSTEMD_DIR}/${UNIT_NAME}.service"
        echo_success "Systemd service installed: ${UNIT_NAME}.service"
    else
        echo_warning "Service file not found: ${SERVICE_SRC}; creating a minimal one."
        [[ -e "${SYSTEMD_DIR}/${UNIT_NAME}.service" ]] || _log_operation "file:${SYSTEMD_DIR}/${UNIT_NAME}.service"
        cat > "${SYSTEMD_DIR}/${UNIT_NAME}.service" << SERVEOF
[Unit]
Description=Certbot Smart Manager - SSL Certificate Renewal Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_DEST}/${SCRIPT_NAME} --auto
User=root
UMask=027
Environment=CONFIG_FILE=${CONFIG_DEST}

[Install]
WantedBy=multi-user.target
SERVEOF
        chmod 644 "${SYSTEMD_DIR}/${UNIT_NAME}.service"
    fi

    if [[ -f "$TIMER_SRC" ]]; then
        _install_text_file 644 "$TIMER_SRC" "${SYSTEMD_DIR}/${UNIT_NAME}.timer"
        echo_success "Systemd timer installed: ${UNIT_NAME}.timer"
    else
        echo_warning "Timer file not found: ${TIMER_SRC}; creating a minimal one."
        [[ -e "${SYSTEMD_DIR}/${UNIT_NAME}.timer" ]] || _log_operation "file:${SYSTEMD_DIR}/${UNIT_NAME}.timer"
        cat > "${SYSTEMD_DIR}/${UNIT_NAME}.timer" << TIMEREOF
[Unit]
Description=Certbot Smart Manager - Twice Daily Timer

[Timer]
OnCalendar=*-*-* 03:00:00
OnCalendar=*-*-* 15:00:00
Unit=${UNIT_NAME}.service
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TIMEREOF
        chmod 644 "${SYSTEMD_DIR}/${UNIT_NAME}.timer"
    fi

    systemctl daemon-reload 2>/dev/null || true
}

# Step 10: Enable and start systemd timer (idempotent, always runs)
enable_systemd_timer() {
    command_exists systemctl || return 0

    echo_info "Enabling and starting systemd timer..."

    local was_enabled=false
    systemctl is-enabled --quiet "${UNIT_NAME}.timer" 2>/dev/null && was_enabled=true

    if systemctl enable --now "${UNIT_NAME}.timer" >/dev/null 2>&1; then
        if [[ "$was_enabled" == "false" ]]; then
            _log_operation "systemd_enable:${UNIT_NAME}.timer"
            _log_operation "systemd_start:${UNIT_NAME}.timer"
        fi
        echo_success "Timer enabled and started: ${UNIT_NAME}.timer"
    else
        echo_warning "Failed to enable/start timer ${UNIT_NAME}.timer."
    fi
}

# Step 11: Create cron fallback (only if the systemd timer is not active)
install_cron_fallback() {
    if command_exists systemctl && systemctl is-active --quiet "${UNIT_NAME}.timer" 2>/dev/null; then
        echo_success "Systemd timer active; cron fallback not needed."
        return 0
    fi

    if ! command_exists crontab; then
        echo_warning "Neither an active systemd timer nor crontab is available."
        echo_warning "Schedule '${BIN_DEST}/${SCRIPT_NAME} --auto' manually."
        return 0
    fi

    echo_info "Creating cron fallback..."

    # The script writes its own log file; discard stdout/stderr so cron
    # does not duplicate every line into the log (or mail it).
    local cron_line="0 3,15 * * * ${BIN_DEST}/${SCRIPT_NAME} --auto >/dev/null 2>&1"

    if crontab -l 2>/dev/null | grep -qF "${SCRIPT_NAME} --auto"; then
        echo_success "Cron entry already exists."
    elif { crontab -l 2>/dev/null || true; echo "$cron_line"; } | crontab - 2>/dev/null; then
        echo_success "Cron entry added."
        _log_operation "cron:added"
    else
        echo_warning "Failed to add cron entry."
    fi
}

# Step 12: Verify installation (non-fatal)
verify_installation() {
    echo_info "Verifying installation..."

    local errors=0

    if [[ -x "${LIB_DEST}/${PROJECT_NAME}.sh" ]]; then
        echo_success "Main script: ${LIB_DEST}/${PROJECT_NAME}.sh"
    else
        echo_error "Main script missing or not executable!"
        errors=$((errors + 1))
    fi

    if [[ -L "${BIN_DEST}/${SCRIPT_NAME}" ]] || [[ -f "${BIN_DEST}/${SCRIPT_NAME}" ]]; then
        echo_success "Executable: ${BIN_DEST}/${SCRIPT_NAME}"
    else
        echo_error "Executable symlink missing!"
        errors=$((errors + 1))
    fi

    if [[ -f "$CONFIG_DEST" ]]; then
        echo_success "Config: ${CONFIG_DEST}"
    else
        echo_error "Config file missing!"
        errors=$((errors + 1))
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo_success "Log: ${LOG_FILE}"
    else
        echo_warning "Log file not yet created (will be created on first run)."
    fi

    local module_count
    module_count="$(find "$MODULES_DEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l)"
    if [[ $module_count -gt 0 ]]; then
        echo_success "Modules: ${module_count} installed"
    else
        echo_error "No modules found."
        errors=$((errors + 1))
    fi

    if command_exists systemctl; then
        if [[ -f "${SYSTEMD_DIR}/${UNIT_NAME}.service" ]]; then
            echo_success "Systemd service: ${UNIT_NAME}.service"
        else
            echo_warning "Systemd service not installed."
        fi
        if [[ -f "${SYSTEMD_DIR}/${UNIT_NAME}.timer" ]]; then
            echo_success "Systemd timer: ${UNIT_NAME}.timer"
        else
            echo_warning "Systemd timer not installed."
        fi
    fi

    if ! command_exists certbot; then
        echo_warning "certbot is not installed — renewals will fail until it is."
    fi

    if "${BIN_DEST}/${SCRIPT_NAME}" --version >/dev/null 2>&1; then
        echo_success "Executable works ($("${BIN_DEST}/${SCRIPT_NAME}" --version 2>/dev/null))."
    else
        echo_warning "Executable test failed."
        errors=$((errors + 1))
    fi

    return $errors
}

# =============================================================================
# ROLLBACK
# =============================================================================

rollback_install() {
    local error_msg="${1:-Installation failed}"

    trap - ERR INT TERM

    echo_warning ""
    echo_warning "=========================================="
    echo_warning "  ROLLING BACK INSTALLATION"
    echo_warning "=========================================="
    echo_warning ""
    echo_warning "Reason: ${error_msg}"

    # Only operations that created something NEW are logged, so a failed
    # upgrade does not remove a previously working installation.
    if [[ -n "$INSTALL_LOG" ]] && [[ -f "$INSTALL_LOG" ]]; then
        local operations=()
        local line
        while IFS= read -r line; do
            operations+=("$line")
        done < "$INSTALL_LOG"

        local i op
        for (( i=${#operations[@]}-1; i>=0; i-- )); do
            op="${operations[$i]}"
            case "$op" in
                file:*)
                    rm -f "${op#file:}" 2>/dev/null || true
                    ;;
                symlink:*)
                    rm -f "${op#symlink:}" 2>/dev/null || true
                    ;;
                dir:*)
                    rm -rf "${op#dir:}/.install-state" 2>/dev/null || true
                    rmdir "${op#dir:}" 2>/dev/null || true
                    ;;
                systemd_enable:*)
                    systemctl disable "${op#systemd_enable:}" 2>/dev/null || true
                    ;;
                systemd_start:*)
                    systemctl stop "${op#systemd_start:}" 2>/dev/null || true
                    ;;
                cron:added)
                    { crontab -l 2>/dev/null || true; } | grep -vF "${SCRIPT_NAME} --auto" | crontab - 2>/dev/null || true
                    ;;
            esac
        done
        command_exists systemctl && systemctl daemon-reload 2>/dev/null || true
    fi

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
    echo_bold "  ${PROJECT_NAME} v${INSTALLER_VERSION}"
    echo_bold "  Installation Complete!"
    echo_bold "========================================"
    echo ""
    echo_info "Installation paths:"
    echo "  Executable:  ${BIN_DEST}/${SCRIPT_NAME}"
    echo "  Library:     ${LIB_DEST}/"
    echo "  Config:      ${CONFIG_DEST}"
    echo "  Log:         ${LOG_FILE}"
    echo "  Backup:      ${BACKUP_DIR}/"
    echo ""

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

    if command_exists systemctl; then
        echo_bold "Systemd:"
        echo "  sudo systemctl status ${UNIT_NAME}.timer"
        echo "  sudo systemctl status ${UNIT_NAME}.service"
        echo "  sudo journalctl -u ${UNIT_NAME}.service"
        echo ""
    fi

    echo_bold "Logs:"
    echo "  sudo tail -f ${LOG_FILE}"
    echo ""

    if command_exists systemctl; then
        if systemctl is-active --quiet "${UNIT_NAME}.timer" 2>/dev/null; then
            echo_success "Timer is running. Certificates will be checked twice daily."
            echo ""
            echo_bold "Next scheduled runs:"
            systemctl list-timers "${UNIT_NAME}.timer" --no-pager 2>/dev/null | tail -n +2 || true
        else
            echo_warning "Timer is not running. Enable with:"
            echo "  sudo systemctl enable --now ${UNIT_NAME}.timer"
        fi
    fi

    echo ""
    echo_bold "Next steps:"
    echo "  1. Request a certificate for each new domain (one time per domain):"
    echo "       sudo ssl-manager --install"
    echo "     Existing certificates in /etc/letsencrypt are picked up automatically."
    echo "  2. Set up notifications so you hear about failures / manual renewals:"
    echo "       sudo ssl-manager --configure"
    echo "  3. Verify unattended renewal works:"
    echo "       sudo ssl-manager --dry-run"
    echo ""
    echo "  After that, renewal is automatic. Only certificates issued with manual"
    echo "  DNS validation need you: you get a reminder, then run"
    echo "       sudo ssl-manager --renew-cert <name>"

    local method
    method="$(sed -n "s/^[[:space:]]*NOTIFICATION_METHOD=[\"']\{0,1\}\([a-z]*\).*/\1/p" "$CONFIG_DEST" 2>/dev/null | head -n 1)"
    if [[ -z "$method" || "$method" == "console" || "$method" == "log" ]]; then
        echo ""
        echo_warning "Notifications are '${method:-console}' only (wall/log). On a server where nobody is"
        echo_warning "logged in, a failed renewal would go unnoticed. Run: sudo ssl-manager --configure"
    fi

    echo ""
    echo_success "Installation complete!"
    echo ""

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Installation completed successfully (installer v${INSTALLER_VERSION})" >> "$LOG_FILE" 2>/dev/null || true
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

main() {
    echo_bold ""
    echo_bold "========================================"
    echo_bold "  ${PROJECT_NAME} v${INSTALLER_VERSION}"
    echo_bold "  One-Click Installer"
    echo_bold "========================================"
    echo ""

    # Trap errors for rollback
    trap 'rollback_install "Unexpected error during installation (line ${LINENO})."' ERR
    trap 'rollback_install "Installation interrupted."' INT TERM

    detect_os
    get_package_manager
    echo ""

    install_dependencies
    echo ""

    ensure_sources
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

    install_deploy_hook
    echo ""

    install_systemd_units
    echo ""

    enable_systemd_timer
    echo ""

    install_cron_fallback
    echo ""

    # Remove error trap for verification (non-fatal)
    trap - ERR INT TERM

    if ! verify_installation; then
        echo_warning "Verification reported problems — see messages above."
    fi
    echo ""

    show_summary
}

# =============================================================================
# RUN
# =============================================================================
main "$@"
