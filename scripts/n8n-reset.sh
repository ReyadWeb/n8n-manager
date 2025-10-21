#!/usr/bin/env bash
set -euo pipefail

# n8n-reset.sh — Clean uninstall / fresh-state reset for n8n

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (make sure Step 2 is complete)"; exit 1; }
. "$LIB"

YES="no"
PURGE_BACKUPS="no"
REMOVE_IMAGES="no"
KEEP_APPDIR="no"
REMOVE_LE="no"
REMOVE_CF_ORIGIN="no"

usage(){
cat <<USAGE
Usage: n8n-reset.sh [options]

Options:
  --yes               Proceed without confirmations
  --purge-backups     Also delete /var/backups/n8n
  --remove-images     Also remove docker images (n8n, postgres, redis)
  --keep-appdir       Do NOT delete /opt/n8n (leave env/compose/data)
  --remove-le         Remove Let's Encrypt certs for N8N_HOST
  --remove-cf-origin  Remove Cloudflare Origin cert/key files for N8N_HOST
  -h, --help          Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES="yes" ;;
    --purge-backups) PURGE_BACKUPS="yes" ;;
    --remove-images) REMOVE_IMAGES="yes" ;;
    --keep-appdir) KEEP_APPDIR="yes" ;;
    --remove-le) REMOVE_LE="yes" ;;
    --remove-cf-origin) REMOVE_CF_ORIGIN="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

load_cfg
ensure_dirs
LOG="$(log_file)"; exec > >(tee -a "$LOG") 2>&1

h1 "n8n Reset / Clean Uninstall"
say "This will bring the system back to a fresh state for a clean install."
say "Log: $LOG"
echo

if [ "$YES" != "yes" ]; then
  ask_yn "Proceed with reset for host '$N8N_HOST' ?" "Y" || { say "Cancelled."; exit 0; }
fi

h1 "Docker stack"
if [ -f "$APP_DIR/docker-compose.yml" ]; then
  compose_down "$APP_DIR"
  ok "Stack stopped and volumes removed"
else
  warn "No docker-compose.yml found at $APP_DIR (skipping down)"
fi

if [ "$REMOVE_IMAGES" = "yes" ] || { [ "$YES" != "yes" ] && ask_yn "Remove docker images (n8n/postgres/redis)?" "N"; }; then
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | awk '/^n8nio\/n8n:|^postgres:|^redis:/ {print $2}' \
    | xargs -r docker rmi || true
  ok "Images removed (if any)"
else
  warn "Kept images"
fi

h1 "NGINX config"
if [ -f "$NGINX_SITE" ] || [ -f "$NGINX_SITE_LINK" ]; then
  rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" || true
  nginx -t && systemctl reload nginx || true
  ok "Removed NGINX site and reloaded"
else
  warn "NGINX site not found (skipping)"
fi

if [ -f /etc/nginx/.n8n_htpasswd ]; then
  if [ "$YES" = "yes" ] || ask_yn "Remove NGINX Basic Auth file (/etc/nginx/.n8n_htpasswd)?" "Y"; then
    rm -f /etc/nginx/.n8n_htpasswd
    nginx -t && systemctl reload nginx || true
    ok "Removed Basic Auth file"
  else
    warn "Kept Basic Auth file"
  fi
fi

h1 "Firewall (Cloudflare 443 lock)"
if [ "$YES" = "yes" ] || ask_yn "Undo Cloudflare 443-lock firewall rules (if present)?" "Y"; then
  cf_unlock_443
else
  warn "Left firewall rules as-is"
fi

h1 "TLS certificates"
if [ -n "${N8N_HOST:-}" ]; then
  if [ "$REMOVE_LE" = "yes" ] || { [ "$YES" != "yes" ] && ask_yn "Remove Let's Encrypt certs for $N8N_HOST (if any)?" "N"; }; then
    if command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$N8N_HOST" || true
      rm -rf "/etc/letsencrypt/live/$N8N_HOST" "/etc/letsencrypt/archive/$N8N_HOST" "/etc/letsencrypt/renewal/$N8N_HOST.conf" || true
      ok "Removed LE certs for $N8N_HOST"
    else
      warn "certbot not installed; skipping LE removal"
    fi
  fi
  if [ "$REMOVE_CF_ORIGIN" = "yes" ] || { [ "$YES" != "yes" ] && ask_yn "Remove Cloudflare Origin cert/key for $N8N_HOST (if any)?" "N"; }; then
    rm -f "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.crt" "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.key" || true
    ok "Removed CF Origin cert/key"
  fi
else
  warn "N8N_HOST not set; skipping TLS removal prompts"
fi

h1 "Backups"
if [ -f /etc/cron.d/backup-n8n ]; then
  rm -f /etc/cron.d/backup-n8n
  ok "Removed backup cron"
fi
if [ -x /usr/local/sbin/backup-n8n.sh ] || [ -x /usr/local/sbin/restore-n8n.sh ]; then
  if [ "$YES" = "yes" ] || ask_yn "Remove backup/restore scripts?" "N"; then
    rm -f /usr/local/sbin/backup-n8n.sh /usr/local/sbin/restore-n8n.sh
    ok "Removed backup/restore scripts"
  fi
fi
if [ "$PURGE_BACKUPS" = "yes" ] || { [ "$YES" != "yes" ] && ask_yn "Purge /var/backups/n8n ?" "N"; }; then
  rm -rf "$BACKUP_DIR"
  ok "Purged backups"
else
  warn "Kept backups in $BACKUP_DIR"
fi

h1 "App directory"
if [ "$KEEP_APPDIR" = "yes" ]; then
  warn "Keeping $APP_DIR"
else
  if [ "$YES" = "yes" ] || ask_yn "Delete $APP_DIR (env/compose/data)?" "Y"; then
    rm -rf "$APP_DIR"
    ok "Removed $APP_DIR"
  else
    warn "Kept $APP_DIR"
  fi
fi

h1 "Installer state"
clear_state
rm -f "$LOCK_FILE" 2>/dev/null || true
ok "Cleared state and lock"

say
ok "Reset complete. You can run a fresh install with:"
say "  sudo /usr/local/sbin/n8n-manager.sh   # choose: Install"
