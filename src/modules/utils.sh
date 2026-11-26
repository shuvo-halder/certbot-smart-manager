#!/bin/bash
# =============================================================================
# certbot-smart-manager — Utility Functions Module
# =============================================================================
# Path: /usr/local/lib/certbot-smart-manager/modules/utils.sh
# =============================================================================
#
# This module provides shared utility functions used by all other modules.
# It must be sourced after the configuration file.
#
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Ensure log directory exists
_mklogdir() {
    local log_file="${LOG_FILE:-/var/log/certbot-smart-manager.log}"
    local log_dir
    log_dir="$(dirname "$log_file")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    touch "$log_file" 2>/dev/null || true
}

_mklogdir

# Generic log function
_log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local message="$*"
    local log_file="${LOG_FILE:-/var/log/certbot-smart-manager.log}"

    # Always try to write to the log file. A non-writable log (e.g. running
    # as a normal user) must never abort the script under `set -e`.
    { printf '[%s] %s: %s\n' "$timestamp" "$level" "$message" >> "$log_file"; } 2>/dev/null || true

    # Also output to stderr for errors, stdout for others
    if [[ "$level" == "ERROR" ]]; then
        printf '[%s] %s: %s\n' "$timestamp" "$level" "$message" >&2
    else
        printf '[%s] %s: %s\n' "$timestamp" "$level" "$message"
    fi
}

log_info()    { _log "INFO"    "$@"; }
log_success() { _log "SUCCESS" "$@"; }
log_warning() { _log "WARNING" "$@"; }
log_error()   { _log "ERROR"   "$@"; }
log_debug()   {
    if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
        _log "DEBUG" "$@"
    fi
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# Fatal error — print message and exit
die() {
    log_error "$@"
    exit 1
}

# =============================================================================
# ROOT CHECK
# =============================================================================

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

# =============================================================================
# LOCK MECHANISM
# =============================================================================

# Acquire a lock file using flock to prevent duplicate execution
# Returns 0 if lock acquired, 1 if already locked.
# NOTE: cleanup on exit (lock release, firewall ports) is handled by the
# single EXIT trap installed in the main script; this function does not
# override it.
acquire_lock() {
    local lock_file="${LOCK_FILE:-/var/lock/certbot-smart-manager.lock}"
    local lock_dir

    lock_dir="$(dirname "$lock_file")"
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || true
    fi

    if ! command -v flock >/dev/null 2>&1; then
        log_warning "flock(1) not available; using PID-file locking fallback"
        if [[ -f "$lock_file" ]]; then
            local old_pid
            old_pid="$(cat "$lock_file" 2>/dev/null || echo "")"
            if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
                log_warning "Another instance is already running (PID: ${old_pid})"
                return 1
            fi
            # Stale lock file — remove it
            rm -f "$lock_file"
        fi
        echo "$$" > "$lock_file"
        LOCK_HELD=true
        return 0
    fi

    # Use flock
    exec 9>"$lock_file"
    if ! flock -n 9; then
        exec 9>&-
        log_warning "Another renewal job is already running (lock: ${lock_file})"
        return 1
    fi
    LOCK_HELD=true
    log_debug "Lock acquired: ${lock_file}"
    return 0
}

# Release the lock (safe to call multiple times, or when no lock is held)
release_lock() {
    local lock_file="${LOCK_FILE:-/var/lock/certbot-smart-manager.lock}"

    if [[ "${LOCK_HELD:-false}" != "true" ]]; then
        return 0
    fi
    LOCK_HELD=false

    # If using flock, close fd 9.
    # (Do NOT write `exec 9>&- 2>/dev/null` — with `exec` that would redirect
    # the shell's stderr to /dev/null permanently.)
    if command -v flock >/dev/null 2>&1; then
        exec 9>&-
    fi

    # Clean up PID file if it was our fallback
    if [[ -f "$lock_file" ]]; then
        local file_pid
        file_pid="$(cat "$lock_file" 2>/dev/null || echo "")"
        if [[ "$file_pid" == "$$" ]]; then
            rm -f "$lock_file" 2>/dev/null || true
            log_debug "Lock released: ${lock_file}"
        fi
    fi
}

# =============================================================================
# INPUT VALIDATION
# =============================================================================

# Validate a domain name (returns 0 if valid)
validate_domain() {
    local domain="$1"
    # RFC 952/1123 compliant hostname pattern
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Validate an email address (basic check)
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Validate a positive integer
validate_positive_int() {
    local val="$1"
    if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# Trim leading/trailing whitespace (pure bash; unlike `xargs` it does not
# choke on quotes or backslashes in user input)
trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Lowercase a string
to_lower() {
    printf '%s' "$*" | tr '[:upper:]' '[:lower:]'
}

# Sanitize a filename (remove dangerous characters)
sanitize_filename() {
    local name="$1"
    # Remove everything except alphanumerics, hyphens, underscores, dots
    printf '%s\n' "$name" | sed 's/[^a-zA-Z0-9._-]//g'
}

# =============================================================================
# SYSTEM HELPERS
# =============================================================================

# Safely check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Read a single field from /etc/os-release WITHOUT sourcing it into the
# current shell. Sourcing it directly would overwrite our own globals such
# as VERSION and NAME (os-release defines both).
# Usage: os_release_field ID
os_release_field() {
    local field="$1"
    [[ -r /etc/os-release ]] || { printf 'unknown'; return 0; }
    (
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s' "${!field:-unknown}"
    )
}

# Get OS ID (ubuntu, debian, centos, rhel, rocky, almalinux, fedora)
get_os_id() {
    if [[ -r /etc/os-release ]]; then
        os_release_field ID | tr '[:upper:]' '[:lower:]'
        printf '\n'
    elif [[ -r /etc/redhat-release ]]; then
        if grep -qi "centos" /etc/redhat-release 2>/dev/null; then
            printf 'centos\n'
        elif grep -qi "rocky" /etc/redhat-release 2>/dev/null; then
            printf 'rocky\n'
        elif grep -qi "almalinux" /etc/redhat-release 2>/dev/null; then
            printf 'almalinux\n'
        elif grep -qi "fedora" /etc/redhat-release 2>/dev/null; then
            printf 'fedora\n'
        else
            printf 'rhel\n'
        fi
    else
        printf 'unknown\n'
    fi
}

# Get package manager for the current OS
get_package_manager() {
    local os_id
    os_id="$(get_os_id)"

    case "$os_id" in
        ubuntu|debian)
            printf 'apt\n'
            ;;
        centos|rhel|rocky|almalinux|ol)
            if command_exists dnf; then
                printf 'dnf\n'
            else
                printf 'yum\n'
            fi
            ;;
        fedora)
            printf 'dnf\n'
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

# =============================================================================
# COLOR HELPERS (for terminal output)
# =============================================================================

# Only enable colors if stdout is a terminal
if [[ -t 1 ]]; then
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_CYAN='\033[0;36m'
    COLOR_BOLD='\033[1m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_CYAN=''
    COLOR_BOLD=''
    COLOR_RESET=''
fi

echo_info()    { printf '%b%s%b\n' "${COLOR_BLUE}"   "$*" "${COLOR_RESET}"; }
echo_success() { printf '%b%s%b\n' "${COLOR_GREEN}"  "$*" "${COLOR_RESET}"; }
echo_warning() { printf '%b%s%b\n' "${COLOR_YELLOW}" "$*" "${COLOR_RESET}"; }
echo_error()   { printf '%b%s%b\n' "${COLOR_RED}"    "$*" "${COLOR_RESET}"; }
echo_bold()    { printf '%b%s%b\n' "${COLOR_BOLD}"   "$*" "${COLOR_RESET}"; }
echo_cyan()    { printf '%b%s%b\n' "${COLOR_CYAN}"   "$*" "${COLOR_RESET}"; }