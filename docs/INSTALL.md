# 📦 Installation Guide — certbot-smart-manager

Comprehensive installation and setup instructions.

---

## 🔧 Prerequisites

### System Requirements

| Component | Requirement |
|-----------|-------------|
| **OS** | Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+, Rocky 8+, AlmaLinux 8+, Fedora 32+, Oracle Linux 8+ |
| **Architecture** | x86_64, arm64, aarch64 |
| **Memory** | 256 MB minimum (512 MB recommended) |
| **Disk** | 100 MB free for installation; additional space for certificates |
| **Network** | Outbound access to ports 80 and 443 for Let's Encrypt validation |
| **Permissions** | Root access (via sudo or directly as root) |

### Required Software (installed automatically)

| Package | Purpose |
|---------|---------|
| `curl` | HTTP requests, installer download |
| `wget` | Alternative HTTP client |
| `openssl` | Certificate parsing and inspection |
| `ca-certificates` | SSL certificate trust store |
| `systemd` | Service and timer management (optional, cron fallback available) |
| `certbot` | Let's Encrypt client |

### Optional Software

| Package | Purpose |
|---------|---------|
| `Nginx` / `Apache` | Web server for certificate installation |
| `UFW` / `firewalld` | Firewall management |
| `mailutils` / `sendmail` | Email notifications |
| `python3-certbot-nginx` | Certbot Nginx plugin |
| `python3-certbot-apache` | Certbot Apache plugin |

---

## 🚀 Quick Install (Recommended)

### Method 1: curl (One-Liner)

```bash
curl -sSL https://your-domain/install.sh | sudo bash
```

### Method 2: wget

```bash
wget -O - https://your-domain/install.sh | sudo bash
```

### Method 3: Local Install (from cloned repo)

```bash
git clone https://github.com/shuvo-halder/certbot-smart-manager.git
cd certbot-smart-manager
sudo bash install.sh
```

---

## 📋 Step-by-Step Installation Process

The installer follows this sequence. Each step is **idempotent** — safe to rerun:

### Step 1: OS Detection

The installer identifies your Linux distribution:
- Ubuntu, Debian → uses `apt`
- CentOS, RHEL, Rocky, AlmaLinux → uses `dnf` or `yum`
- Fedora → uses `dnf`

### Step 2: Dependency Installation

Installs: `curl`, `wget`, `openssl`, `ca-certificates`, and relevant system packages.

### Step 3: Certbot Installation

If Certbot is not found, the installer attempts:
1. Package manager installation (apt/dnf/yum)
2. Snap installation fallback (Ubuntu 20.04+)

### Step 4: Certbot Plugin Installation

Detects installed web servers and installs the appropriate Certbot plugin:
- Nginx → `python3-certbot-nginx`
- Apache → `python3-certbot-apache`

### Step 5: Directory Creation

Creates the following directory structure:
- `/usr/local/lib/certbot-smart-manager/`
- `/usr/local/lib/certbot-smart-manager/modules/`
- `/etc/certbot-smart-manager/`
- `/var/log/` (for log file)
- `/var/lock/` (for lock file)
- `/var/backups/certbot-smart-manager/`

### Step 6: Script Installation

Copies:
- Main script to `/usr/local/lib/certbot-smart-manager/`
- Modules to `/usr/local/lib/certbot-smart-manager/modules/`
- Creates symlink: `/usr/local/bin/ssl-manager`

### Step 7: Configuration Installation

Installs configuration file to `/etc/certbot-smart-manager/certbot-smart.conf`.
Does **not** overwrite existing configuration — preserves customizations.

### Step 8: Permission Setup

Sets strict permissions:
- Scripts: `chmod 755` (executable)
- Modules: `chmod 640`
- Config: `chmod 600` (root-only readable)
- Log: `chmod 640`
- Backup dir: `chmod 750`

### Step 9: Systemd Service Installation

Installs `certbot-smart.service` to `/etc/systemd/system/`.
Includes security hardening directives.

### Step 10: Systemd Timer Installation

Installs `certbot-smart.timer` to `/etc/systemd/system/`.
Schedule: 03:00 and 15:00 daily.

### Step 11: Timer Enablement

```bash
systemctl enable certbot-smart.timer
systemctl start certbot-smart.timer
```

### Step 12: Cron Fallback

If systemd is not available, adds a cron entry:
```
0 3,15 * * * /usr/local/bin/ssl-manager --auto >> /var/log/certbot-smart-manager.log 2>&1
```

### Step 13: Verification

Verifies all installed components and prints a summary.

---

## ⏱️ Installation Time

| Component | Time |
|-----------|------|
| Dependency installation | 10–60 seconds |
| Certbot installation | 5–30 seconds |
| Script installation | < 1 second |
| Systemd setup | < 1 second |
| **Total** | **~20–90 seconds** |

---

## 🔄 Idempotency

The installer uses marker files in `/etc/certbot-smart-manager/.install-state/` to track completed steps. This means:

- **Running the installer again** will skip already-completed steps
- **Upgrading** will update scripts and systemd files without modifying your configuration
- **Safe to rerun** at any time

To force a reinstall of a specific component, remove the corresponding marker file:

```bash
# Reinstall scripts only
sudo rm -f /etc/certbot-smart-manager/.install-state/scripts.done
sudo bash install.sh
```

---

## 🔄 Upgrade

To upgrade to the latest version:

```bash
# Re-run the installer (safe, idempotent)
curl -sSL https://your-domain/install.sh | sudo bash
```

Or from a cloned repository:

```bash
cd certbot-smart-manager
git pull
sudo bash install.sh
```

---

## ❌ Uninstallation

To completely remove certbot-smart-manager:

```bash
# Stop and disable timer
sudo systemctl stop certbot-smart.timer
sudo systemctl disable certbot-smart.timer

# Remove systemd files
sudo rm -f /etc/systemd/system/certbot-smart.service
sudo rm -f /etc/systemd/system/certbot-smart.timer
sudo systemctl daemon-reload

# Remove installed files
sudo rm -rf /usr/local/lib/certbot-smart-manager
sudo rm -f /usr/local/bin/ssl-manager
sudo rm -rf /etc/certbot-smart-manager

# Remove logs and backups (optional)
sudo rm -f /var/log/certbot-smart-manager.log
sudo rm -rf /var/backups/certbot-smart-manager
sudo rm -f /var/lock/certbot-smart-manager.lock

# Remove cron entry (if used)
sudo crontab -l | grep -v 'ssl-manager' | sudo crontab -
```

---

## 🐳 Docker Support

certbot-smart-manager can be used inside Docker containers:

```bash
docker run --rm -it \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/log/certbot-smart-manager.log:/var/log/certbot-smart-manager.log \
  --network host \
  ubuntu:22.04 bash -c "
    apt-get update && apt-get install -y curl sudo
    curl -sSL https://your-domain/install.sh | sudo bash
  "
```

---

## 🖥️ Post-Installation Configuration

### Step 1: Verify Installation

```bash
sudo ssl-manager --version
sudo ssl-manager --scan
```

### Step 2: Configure Notifications (Optional)

```bash
sudo ssl-manager --configure
```

### Step 3: Test Renewal (Dry Run)

```bash
sudo ssl-manager --dry-run
```

### Step 4: Install Your First Certificate

```bash
sudo ssl-manager --install
```

### Step 5: Check Timer Status

```bash
sudo systemctl status certbot-smart.timer
sudo systemctl list-timers certbot-smart.timer
```

---

## ⚠️ Firewall Configuration

If you use a firewall, ensure ports 80 and 443 are accessible for Let's Encrypt validation:

### UFW

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### firewalld

```bash
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload
```

**Note:** certbot-smart-manager opens these ports automatically during renewal if UFW or firewalld is detected.

---

## 📄 Configuration Reference

Full configuration file: `/etc/certbot-smart-manager/certbot-smart.conf`

| Variable | Default | Description |
|----------|---------|-------------|
| `THRESHOLD_DAYS` | `30` | Days before expiry to attempt renewal |
| `CRITICAL_THRESHOLD_DAYS` | `7` | Days before expiry to send critical warnings |
| `LOG_FILE` | `/var/log/certbot-smart-manager.log` | Log file path |
| `LOG_LEVEL` | `INFO` | Log verbosity (DEBUG, INFO, WARNING, ERROR) |
| `BACKUP_ENABLED` | `true` | Enable automatic backup before renewal |
| `BACKUP_DIR` | `/var/backups/certbot-smart-manager` | Backup storage location |
| `BACKUP_RETENTION_DAYS` | `30` | Days to keep old backups |
| `NOTIFICATION_METHOD` | `console` | Default notification method |
| `SMTP_SERVER` | — | SMTP server for email notifications |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USER` | — | SMTP username |
| `SMTP_PASS` | — | SMTP password |
| `SMTP_FROM` | — | From address for emails |
| `SMTP_TO` | — | Recipient address for emails |
| `SMTP_USE_TLS` | `true` | Use TLS for SMTP |
| `TELEGRAM_BOT_TOKEN` | — | Telegram bot token |
| `TELEGRAM_CHAT_ID` | — | Telegram chat ID |
| `SLACK_WEBHOOK_URL` | — | Slack webhook URL |
| `RELOAD_WEB_SERVER` | `true` | Reload web server after renewal |
| `MAX_RETRIES` | `3` | Maximum renewal retry attempts |
| `RETRY_DELAY_SECONDS` | `10` | Delay between retries |