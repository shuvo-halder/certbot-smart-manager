# 🛠️ Troubleshooting Guide — certbot-smart-manager

Common issues, diagnostics, and solutions.

---

## 📋 Quick Diagnostic Commands

```bash
# Check systemd timer status
sudo systemctl status certbot-smart.timer

# Check systemd service status
sudo systemctl status certbot-smart.service

# View recent service logs
sudo journalctl -u certbot-smart.service -n 50 --no-pager

# Check certbot certificate status
sudo certbot certificates

# Run manager manually with verbose output
sudo ssl-manager --auto

# Check log file
sudo tail -f /var/log/certbot-smart-manager.log

# Verify installation
which ssl-manager
ssl-manager --version
```

---

## 🐛 Common Issues

### 1. "certbot is not installed" Error

**Symptoms:**
```
ERROR: certbot is not installed.
```

**Causes:**
- Installation failed or was interrupted
- Certbot not in PATH
- Certbot installed via snap but not linked

**Solutions:**

```bash
# Install certbot via your package manager
# Ubuntu/Debian:
sudo apt-get install -y certbot

# CentOS/RHEL/Rocky/AlmaLinux:
sudo dnf install -y certbot

# If certbot is installed via snap, create symlink:
sudo ln -sf /snap/bin/certbot /usr/bin/certbot

# Re-run the installer:
curl -sSL https://your-domain/install.sh | sudo bash
```

### 2. Systemd Timer Not Running

**Symptoms:**
```
● certbot-smart.timer - not running
```

**Solutions:**

```bash
# Check if timer exists
systemctl list-timers | grep certbot-smart

# Enable and start the timer
sudo systemctl enable certbot-smart.timer
sudo systemctl start certbot-smart.timer

# Verify status
sudo systemctl status certbot-smart.timer

# Reload systemd if timer was just installed
sudo systemctl daemon-reload
```

### 3. Certificate Renewal Fails

**Symptoms:**
```
ERROR: Renewal failed for example.com (exit code: 1)
```

**Common causes and solutions:**

#### a) DNS Resolution Issues

```bash
# Check DNS records
dig example.com +short
nslookup example.com

# Verify the domain resolves to this server's IP
hostname -I
```

#### b) Port 80/443 Not Reachable

```bash
# Check if ports are open locally
sudo ss -tlnp | grep -E ':(80|443) '

# Check firewall
sudo ufw status
sudo firewall-cmd --list-all

# Test external accessibility (from another machine)
curl -I http://example.com/.well-known/acme-challenge/test
```

#### c) Rate Limiting

Let's Encrypt has rate limits. If you hit them, wait and retry:
- 50 certificates per domain per week
- 300 pending orders per account

**Solution:** Wait and try again later, or use `--dry-run` to test without consuming quota.

#### d) Web Server Not Running

```bash
sudo systemctl status nginx
sudo systemctl status apache2
sudo systemctl status httpd
```

### 4. "Another renewal job is already running" Error

**Symptoms:**
```
WARNING: Another renewal job is already running
```

**Solutions:**

```bash
# Check for stale lock file
ls -la /var/lock/certbot-smart-manager.lock

# Remove stale lock (only if no other instance is running)
sudo rm -f /var/lock/certbot-smart-manager.lock

# Check for running processes
ps aux | grep ssl-manager
```

### 5. Email Notifications Not Working

**Symptoms:**
Notifications configured but no emails received.

**Solutions:**

```bash
# Test system mail command
echo "Test" | mail -s "Test" your-email@example.com

# Check if mail command is installed
which mail sendmail

# Install mailutils if needed
# Ubuntu/Debian:
sudo apt-get install -y mailutils

# CentOS/RHEL:
sudo dnf install -y mailx

# Verify SMTP configuration
sudo cat /etc/certbot-smart-manager/certbot-smart.conf | grep -E 'SMTP_'
```

### 6. Telegram/Slack Notifications Not Working

**Solutions:**

```bash
# Test curl connectivity
curl -I https://api.telegram.org
curl -I https://hooks.slack.com

# Verify bot token
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getMe"

# Verify webhook URL (Slack)
curl -X POST -H "Content-Type: application/json" \
  -d '{"text":"Test"}' <YOUR_WEBHOOK_URL>
```

### 7. Permission Denied Errors

**Symptoms:**
```
Permission denied
```

**Solutions:**

```bash
# Check file permissions
sudo ls -la /usr/local/bin/ssl-manager
sudo ls -la /usr/local/lib/certbot-smart-manager/
sudo ls -la /etc/certbot-smart-manager/

# Fix permissions
sudo chmod 755 /usr/local/bin/ssl-manager
sudo chmod 755 /usr/local/lib/certbot-smart-manager/*.sh
sudo chmod 640 /usr/local/lib/certbot-smart-manager/modules/*.sh
sudo chmod 600 /etc/certbot-smart-manager/certbot-smart.conf

# Always run with sudo
sudo ssl-manager
```

### 8. Backup/Restore Issues

**Symptoms:**
Backup creation or restore fails.

**Solutions:**

```bash
# Check backup directory
sudo ls -la /var/backups/certbot-smart-manager/

# Check available disk space
df -h /var/backups

# List backups with sizes
sudo ssl-manager --list-backups

# Manual backup
sudo ssl-manager --backup

# Check backup content
sudo ls -la /var/backups/certbot-smart-manager/latest/
```

---

## 🔍 Diagnostic Script

Run this to collect system diagnostics:

```bash
#!/bin/bash
echo "=== System ==="
uname -a
echo ""

echo "=== OS Release ==="
cat /etc/os-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null
echo ""

echo "=== Certbot ==="
which certbot 2>/dev/null && certbot --version || echo "certbot not found"
echo ""

echo "=== SSL Manager ==="
which ssl-manager 2>/dev/null && ssl-manager --version || echo "ssl-manager not found"
echo ""

echo "=== Configuration ==="
cat /etc/certbot-smart-manager/certbot-smart.conf 2>/dev/null || echo "Config not found"
echo ""

echo "=== Systemd Timer ==="
systemctl status certbot-smart.timer 2>/dev/null || echo "Timer not found"
echo ""

echo "=== Certificates ==="
certbot certificates 2>/dev/null || echo "No certificates"
echo ""

echo "=== Log (last 30 lines) ==="
tail -30 /var/log/certbot-smart-manager.log 2>/dev/null || echo "Log not found"
```

---

## 🌐 Network Troubleshooting

### Test Let's Encrypt Validation Endpoints

```bash
# Test ACME endpoint connectivity
curl -I https://acme-v02.api.letsencrypt.org/directory

# Test HTTP-01 challenge endpoint
curl -I http://example.com/.well-known/acme-challenge/test

# Test TLS-ALPN-01 challenge endpoint
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | head -20
```

### DNS Propagation Check

```bash
# Check A record propagation
dig example.com A +short
dig @8.8.8.8 example.com A +short

# Check CNAME records
dig www.example.com CNAME +short
```

---

## 📊 Log Analysis

### Understanding Log Levels

| Level | Meaning | Example |
|-------|---------|---------|
| `INFO` | Normal operation | Scanning certificates |
| `SUCCESS` | Operation completed | Renewed example.com |
| `WARNING` | Non-critical issue | Certificate expires in 7 days |
| `ERROR` | Operation failed | Renewal failed |
| `DEBUG` | Detailed trace (if enabled) | Lock acquired |

### Log Location

```bash
# Main log file
sudo tail -f /var/log/certbot-smart-manager.log

# Certbot's own logs
sudo tail -f /var/log/letsencrypt/letsencrypt.log

# Systemd journal for the service
sudo journalctl -u certbot-smart.service -f
```

---

## 🧪 Testing Scenarios

### Test 1: Certificate Scanning

```bash
# Expected: List all certificates with status
sudo ssl-manager --scan
```

### Test 2: Dry Run Renewal

```bash
# Expected: Simulate renewal without making changes
sudo ssl-manager --dry-run
```

### Test 3: Notification Test

```bash
# Configure and send test notification
sudo ssl-manager --configure
```

### Test 4: Backup and Restore

```bash
# Create a backup
sudo ssl-manager --backup

# List backups
sudo ssl-manager --list-backups

# Restore from the latest backup
sudo ssl-manager --restore <timestamp>
```

---

## 🚨 Getting Help

If you've tried the solutions above and still have issues:

1. **Check GitHub Issues**: https://github.com/shuvo-halder/certbot-smart-manager/issues
2. **Open a New Issue** with:
   - Complete error message
   - Output from the diagnostic script above
   - OS version and architecture
   - Steps to reproduce the issue

---

## 🔐 Security Concerns

### Reporting Security Issues

If you discover a security vulnerability, please:
1. **Do not** open a public issue
2. Email the maintainer directly
3. Include detailed information about the vulnerability

We will respond within 48 hours and work on a fix.

---

## ✅ Checklist Before Escalating

- [ ] Running as root (`sudo ssl-manager`)
- [ ] Certbot is installed (`certbot --version`)
- [ ] Ports 80/443 are accessible
- [ ] DNS records point to this server
- [ ] System time is correct (`date`)
- [ ] Certificates exist (`certbot certificates`)
- [ ] Log file is writable (`/var/log/certbot-smart-manager.log`)
- [ ] Configuration file is valid (`/etc/certbot-smart-manager/certbot-smart.conf`)
- [ ] Systemd timer is enabled (`systemctl is-enabled certbot-smart.timer`)
- [ ] No stale lock files (`/var/lock/certbot-smart-manager.lock`)