#!/bin/sh
# =============================================================================
# certbot-smart-manager — certbot deploy hook
# =============================================================================
# Installed to: /etc/letsencrypt/renewal-hooks/deploy/certbot-smart-manager-reload.sh
#
# certbot runs every executable in renewal-hooks/deploy/ after EACH
# successful renewal — no matter who started it: certbot-smart-manager,
# certbot's own certbot.timer / snap timer, or a manual `certbot renew`.
# This guarantees the web server always picks up a renewed certificate,
# also for webroot/standalone/DNS certificates where certbot itself does
# not reload anything.
#
# certbot sets RENEWED_LINEAGE (e.g. /etc/letsencrypt/live/example.com).
# =============================================================================

CONFIG_FILE="/etc/certbot-smart-manager/certbot-smart.conf"
LOG_FILE="/var/log/certbot-smart-manager.log"

log() {
    printf '[%s] %s: deploy-hook: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}

# Respect RELOAD_WEB_SERVER=false from the config
if [ -r "$CONFIG_FILE" ] && grep -Eq "^[[:space:]]*RELOAD_WEB_SERVER=[\"']?false" "$CONFIG_FILE"; then
    log INFO "renewed ${RENEWED_LINEAGE:-?}; reload disabled by RELOAD_WEB_SERVER=false"
    exit 0
fi

command -v systemctl >/dev/null 2>&1 || exit 0

reloaded=""
for svc in nginx apache2 httpd; do
    systemctl is-active --quiet "$svc" 2>/dev/null || continue

    # Never reload into a broken config — the running server keeps working
    if [ "$svc" = "nginx" ] && command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        log ERROR "nginx config test failed; NOT reloading nginx (renewed ${RENEWED_LINEAGE:-?})"
        continue
    fi
    if [ "$svc" != "nginx" ] && command -v apachectl >/dev/null 2>&1 && ! apachectl configtest >/dev/null 2>&1; then
        log ERROR "${svc} config test failed; NOT reloading ${svc} (renewed ${RENEWED_LINEAGE:-?})"
        continue
    fi

    if systemctl reload "$svc" >/dev/null 2>&1; then
        reloaded="${reloaded} ${svc}"
    else
        log ERROR "failed to reload ${svc} after renewal of ${RENEWED_LINEAGE:-?}"
    fi
done

log INFO "renewed ${RENEWED_LINEAGE:-?}; reloaded:${reloaded:- (no active web server)}"
exit 0
