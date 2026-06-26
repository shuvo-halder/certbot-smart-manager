# 🔐 certbot-smart-manager

**Production-grade SSL certificate lifecycle management for Let's Encrypt / Certbot.**

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash)
![Platform: Linux](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux)

---

## 📋 Overview

`certbot-smart-manager` is a complete, production-grade SSL certificate management system built on top of Certbot. It automates the entire lifecycle of Let's Encrypt certificates — scanning, renewal, expiry monitoring, notifications, and backup — with a secure, modular, and extensible architecture.

### Key Features

| Feature | Description |
|---------|-------------|
| 🔁 **Automatic Renewal** | Scans all certificates, renews those near expiry (configurable threshold) |
| 🖥️ **Interactive CLI** | `ssl-manager` menu with 11 options for full certificate management |
| 🔔 **Multi-Channel Notifications** | Email (SMTP), Telegram, Slack, Console (`wall`), Log |
| 📦 **One-Click Installer** | Supports 7+ Linux distributions, idempotent, with rollback |
| ⏱️ **Systemd Timer** | Twice-daily checks at 03:00 and 15:00 with randomized delay |
| 🔒 **Security Hardened** | `set -Eeuo pipefail`, `umask 027`, lock files, no eval, SELinux-aware |
| 💾 **Automatic Backups** | Backs up `/etc/letsencrypt/` before modifications with 30-day retention |
| 🔄 **Rollback Support** | Full rollback on installation failure; restore from any backup |
| 🧪 **Dry-Run Mode** | Test renewal without modifying production certificates |
| 🌐 **Multi-OS Support** | Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora, Oracle Linux |

---

## 🚀 Quick Install

```bash
curl -sSL https://your-domain/install.sh | sudo bash
```

Or using wget:

```bash
wget -O - https://your-domain/install.sh | sudo bash
```

The installer will:
1. Detect your Linux distribution
2. Install dependencies (curl, wget, openssl, systemd)
3. Install Certbot if not present
4. Install required Certbot plugins (Nginx/Apache)
5. Create all required directories with strict permissions
6. Install the main script and modules
7. Create systemd service + timer (with cron fallback)
8. Enable and start the timer

---

## 📁 File Structure

```
/usr/local/lib/certbot-smart-manager/
├── certbot-smart-manager.sh    # Main script
└── modules/
    ├── utils.sh                 # Logging, locking, validation
    ├── server-detection.sh      # OS, web server, firewall detection
    ├── certificate-functions.sh # Scan, check, renew, install
    ├── notifications.sh         # Email, Telegram, Slack, Console
    └── backup-restore.sh        # Backup, restore, rollback

/etc/certbot-smart-manager/
└── certbot-smart.conf           # Configuration (chmod 600)

/usr/local/bin/
└── ssl-manager -> /usr/local/lib/certbot-smart-manager/certbot-smart-manager.sh

/etc/systemd/system/
├── certbot-smart.service        # Systemd service unit
└── certbot-smart.timer          # Systemd timer unit

/var/log/
└── certbot-smart-manager.log    # Log file (chmod 640)

/var/backups/certbot-smart-manager/
└── YYYYMMDD_HHMMSS/            # Timestamped backups
```

---

## 🎛️ Usage

### Interactive Menu

```bash
sudo ssl-manager
```

```
========================================
    certbot-smart-manager v1.0.0
    SSL Certificate Manager
========================================

  1) Scan existing certificates
  2) Check expiry status
  3) Renew certificates
  4) Install new SSL certificate
  5) Dry run renewal
  6) View logs
  7) Configure email notifications
  8) Create backup
  9) List backups
 10) Force renew all certificates
 11) Configure renewal threshold
  0) Exit

Enter choice [0-11]:
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `--auto` | Automatic renewal mode (for cron/systemd) |
| `--scan` | Scan and display all certificates |
| `--check` | Check and display expiry status |
| `--renew` | Renew certificates that need renewal |
| `--force-renew` | Force renewal of all certificates |
| `--dry-run` | Simulate renewal (no changes) |
| `--install` | Interactive certificate installation wizard |
| `--view-logs` | Display the log file |
| `--configure` | Configure notification settings |
| `--backup` | Create a backup of `/etc/letsencrypt/` |
| `--list-backups` | List available backups |
| `--restore BACKUP` | Restore from a backup path/timestamp |
| `--help` | Show help |
| `--version` | Show version |

### Examples

```bash
# Automatic renewal (used by systemd timer)
sudo ssl-manager --auto

# Scan and show all certificates
sudo ssl-manager --scan

# Check expiry status with color-coded output
sudo ssl-manager --check

# Test renewal without applying changes
sudo ssl-manager --dry-run

# Force renewal of all certificates
sudo ssl-manager --force-renew

# Install a new certificate interactively
sudo ssl-manager --install

# View the last 100 log entries
sudo ssl-manager --view-logs

# Configure notifications
sudo ssl-manager --configure

# Create a manual backup
sudo ssl-manager --backup

# List available backups
sudo ssl-manager --list-backups

# Restore from a specific backup
sudo ssl-manager --restore 20260627_020001
```

---

## ⏱️ Systemd Automation

The systemd timer runs automatically after installation. It checks all certificates twice daily:

```bash
# Check timer status
sudo systemctl status certbot-smart.timer

# View next scheduled runs
sudo systemctl list-timers certbot-smart.timer

# View service output
sudo journalctl -u certbot-smart.service

# Manually trigger the service
sudo systemctl start certbot-smart.service
```

**Schedule:** 03:00 and 15:00 daily with a random delay of up to 5 minutes.

---

## 🔔 Notification Configuration

Configure notifications via the interactive menu (`ssl-manager --configure`) or edit:

```bash
sudo nano /etc/certbot-smart-manager/certbot-smart.conf
```

### Methods

| Method | Configuration Required | Description |
|--------|----------------------|-------------|
| `console` | None | Sends `wall` messages to all logged-in users |
| `log` | None | Writes to log file (always active) |
| `email` | SMTP server, credentials, addresses | Sends via SMTP or system `mail`/`sendmail` |
| `telegram` | Bot Token, Chat ID | Sends via Telegram Bot API |
| `slack` | Webhook URL | Sends via Slack Incoming Webhook |
| `all` | All of the above | Sends via every configured method |

### Telegram Setup

1. Create a bot via [@BotFather](https://t.me/botfather) on Telegram
2. Get your Chat ID (message `@userinfobot` on Telegram)
3. Configure via `ssl-manager --configure` or config file

### Slack Setup

1. Create an Incoming Webhook in your Slack workspace
2. Configure via `ssl-manager --configure` or config file

### Email (SMTP)

The system tries these methods in order:
1. Direct SMTP via curl (requires SMTP server, user, password)
2. System `mail` command (if available)
3. System `sendmail` command (if available)

---

## 🔒 Security

| Requirement | Implementation |
|-------------|---------------|
| Fail-fast | `set -Eeuo pipefail` in every script |
| Strict umask | `umask 027` — new files are 640, directories 750 |
| Lock file | `flock`-based or PID-file fallback prevents duplicate execution |
| No eval | No `eval` on user input; `eval` only on predefined package manager strings |
| Input validation | Domain, email, and integer validation with regex |
| Secure config | Configuration files are `chmod 600`, owned by root |
| Shellcheck | All scripts are Shellcheck-compliant |
| Systemd hardening | `NoNewPrivileges`, `ProtectSystem`, `PrivateDevices`, etc. |
| Safe cleanup | `trap` handlers close firewall ports, release locks on exit |

---

## 📜 Logging

Log file: `/var/log/certbot-smart-manager.log`

Format:
```
[YYYY-MM-DD HH:MM:SS] LEVEL: Message
```

Levels: `INFO`, `SUCCESS`, `WARNING`, `ERROR`, `DEBUG`

Example:
```
[2026-06-27 02:00:01] INFO: Starting automatic certificate check...
[2026-06-27 02:00:03] SUCCESS: Renewed example.com
[2026-06-27 02:00:05] WARNING: example.com expires in 7 days
[2026-06-27 02:00:06] ERROR: Renewal failed for example.com
```

---

## 💾 Backup & Restore

### Automatic Backups

Backups are created automatically before any renewal operation. Retention: 30 days.

### Manual Commands

```bash
# Create a backup
sudo ssl-manager --backup

# List all backups
sudo ssl-manager --list-backups

# Restore from a backup
sudo ssl-manager --restore 20260627_020001
```

---

## 📦 Requirements

- **Linux** (Ubuntu 18.04+, Debian 10+, CentOS 7+, RHEL 7+, Rocky 8+, AlmaLinux 8+, Fedora 32+)
- **Root/sudo access**
- **Network connectivity** (for Let's Encrypt validation)
- **Ports 80 and 443** reachable from the internet (temporarily during renewal)

### Optional

- Nginx or Apache web server
- UFW or firewalld firewall
- systemd (for timer-based scheduling)
- mail/sendmail (for email notifications)

---

## 🧪 Testing

### Dry Run

Always test with `--dry-run` before relying on automatic renewal:

```bash
sudo ssl-manager --dry-run
```

### Manual Certificate Check

```bash
certbot certificates
```

### Log Monitoring

```bash
sudo tail -f /var/log/certbot-smart-manager.log
```

---

## 🆘 Troubleshooting

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed troubleshooting.

Quick fixes:

```bash
# Check systemd timer
sudo systemctl status certbot-smart.timer

# Check service logs
sudo journalctl -u certbot-smart.service -n 50 --no-pager

# Run manually
sudo ssl-manager --auto

# Verify certificate status
sudo ssl-manager --check

# Check certbot
sudo certbot certificates
```

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- All scripts must pass `shellcheck` with no warnings
- Follow the existing modular architecture
- Maintain backward compatibility
- Update documentation for any new features

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 👨‍💻 Author

**Shuvo Halder**
System Engineer

GitHub: [https://github.com/shuvo-halder](https://github.com/shuvo-halder)

---

## ⭐ Support

If you find this project useful, please give it a star on GitHub!

---

## 📊 Project Stats

- **Total code**: ~2,500+ lines of production Bash
- **Files**: 15 files across 5 directories
- **Modules**: 5 modular components
- **Shellcheck**: 100% compliant
- **Security**: Hardened with systemd sandboxing and strict Bash options