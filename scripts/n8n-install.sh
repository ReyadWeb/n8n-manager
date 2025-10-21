#!/usr/bin/env bash
set -euo pipefail

# n8n-install.sh — Fresh, hardened installer (always resets first)

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (make sure Step 2 is complete)"; exit 1; }
. "$LIB"

FORCE_CF="no"
FORCE_LE="no"
NONINT="no"
IP_ARG=""
HOST_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force-cloudflare) FORCE_CF="yes" ;;
    --force-letsencrypt) FORCE_LE="yes" ;;
    --non-interactive) NONINT="yes" ;;
    --ip) IP_ARG="${2:-}"; shift ;;
    --host) HOST_ARG="${2:-}"; shift ;;
    -h|--help)
      cat <<H
Usage: n8n-install.sh [--ip X.X.X.X] [--host n8n.example.com]
                      [--force-cloudflare|--force-letsencrypt]
                      [--non-interactive]
H
      exit 0;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

load_cfg
ensure_dirs
with_lock
progress_reset
LOG="$(log_file)"; exec > >(tee -a "$LOG") 2>&1
trap 'code=$?; if [ $code -ne 0 ]; then echo; err "Install aborted (exit $code). Resume by re-running this script."; echo "See log: $LOG"; fi' EXIT

h1 "n8n Installer (Fresh & Hardened)"
say "This will reset any old install, then set up Docker + Postgres + Redis + n8n (web+worker), NGINX + TLS, security hardening, and optional backups."
say "Logs: $LOG"

# 0) Reset
if ! reached "reset_done"; then
  if [ -x /usr/local/sbin/n8n-reset.sh ]; then
    say "Resetting via n8n-reset.sh (safe cleanup)…"
    /usr/local/sbin/n8n-reset.sh --yes || true
  else
    say "Resetting (inline fallback)…"
    compose_down "$APP_DIR"
    rm -f "$NGINX_SITE" "$NGINX_SITE_LINK" || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    clear_state
  fi
  checkpoint "reset_done"
fi
progress

# 1) System check & inputs
if ! reached "inputs_done"; then
  h1 "System check"
  OS_PRETTY="$(. /etc/os-release; echo "$PRETTY_NAME")"
  CPU_CORES="$(getconf _NPROCESSORS_ONLN)"
  RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
  DISK_GB="$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')"
  say "OS: $OS_PRETTY"
  say "CPU: ${CPU_CORES} cores  RAM: ${RAM_MB} MB  Disk free: ${DISK_GB} GB"
  [ "$CPU_CORES" -lt 2 ] && warn "CPU below recommended (2+)"
  [ "$RAM_MB" -lt 4096 ] && warn "RAM below recommended (4GB+)"
  [ "$DISK_GB" -lt 20 ] && warn "Disk below recommended (20GB+)"

  DEFAULT_IP="${IP_ARG:-$PUBLIC_IP}"
  DEFAULT_HOST="${HOST_ARG:-$N8N_HOST}"

  if [ "$NONINT" = "yes" ]; then
    NEW_IP="$DEFAULT_IP"
    NEW_HOST="$DEFAULT_HOST"
  else
    NEW_IP="$(prompt_def "Public IP of THIS server" "$DEFAULT_IP")"
    NEW_HOST="$(prompt_def "Hostname for n8n (FQDN)" "$DEFAULT_HOST")"
  fi
  valid_ip "$NEW_IP" || { err "Invalid IP: $NEW_IP"; exit 1; }
  valid_fqdn "$NEW_HOST" || { err "Invalid FQDN: $NEW_HOST"; exit 1; }

  save_cfg_kv PUBLIC_IP "$NEW_IP"
  save_cfg_kv N8N_HOST "$NEW_HOST"
  save_cfg_kv SITE_STATIC_DIR "/var/www/${NEW_HOST}"

  if [ "$NONINT" != "yes" ]; then
    ask_yn "Proceed with IP=$NEW_IP and Host=$NEW_HOST?" "Y" || { say "Cancelled."; exit 0; }
  fi

  checkpoint "inputs_done"
fi
load_cfg
progress

# 2) DNS & TLS mode
if ! reached "dns_done"; then
  h1 "DNS verification"
  dns_detect_mode "$N8N_HOST" "$PUBLIC_IP"
  say "A:     ${RESOLVE_A:-<none>}"
  say "CNAME: ${RESOLVE_CNAME:-<none>}"

  MODE="auto"
  [ "$FORCE_CF" = "yes" ] && MODE="cloudflare"
  [ "$FORCE_LE" = "yes" ] && MODE="lets-encrypt"
  if [ "$MODE" = "auto" ]; then
    if [ "${CF_EDGE:-false}" = true ]; then MODE="cloudflare";
    elif [ "${DIRECT_IP:-false}" = true ]; then MODE="lets-encrypt";
    else
      err "DNS does not point to your IP or Cloudflare. Fix DNS, then retry."
      say "  • Direct: A ${N8N_HOST} → ${PUBLIC_IP}"
      say "  • Cloudflare (orange-cloud) → resolves to 104/172/188.114.*"
      exit 1
    fi
  fi

  save_cfg_kv TLS_MODE "$MODE"
  ok "TLS mode: $MODE"
  checkpoint "dns_done"
fi
progress

is_cf_proxied() {
  curl -sI "http://$N8N_HOST" | grep -qi 'server: cloudflare'
}
if is_cf_proxied; then
  info "Cloudflare proxy detected → recommend Cloudflare TLS mode."
else
  info "Direct A record detected → recommend Let's Encrypt."
fi


# 3) Base security & harden
if ! reached "security_done"; then
  ensure_base_tools
  apply_os_hardening
  checkpoint "security_done"
fi
progress

# 4) Docker
if ! reached "docker_done"; then
  ensure_docker
  checkpoint "docker_done"
fi
progress

# 5) App files & stack up
if ! reached "compose_written"; then
  h1 "Writing env & compose"
  rm -rf "$APP_DIR" && mkdir -p "$APP_DIR"
  compose_write_env "$APP_DIR" "$N8N_HOST" "$TIMEZONE"
  compose_write_file "$APP_DIR"
  checkpoint "compose_written"
fi
progress

if ! reached "stack_up"; then
  compose_up "$APP_DIR"
  checkpoint "stack_up"
fi
progress

# 6) NGINX + TLS
if ! reached "nginx_tls"; then
  nginx_install
  case "$TLS_MODE" in
    cloudflare)
      nginx_write_cf "$N8N_HOST" "$NGINX_SITE" "$CLOUDFLARE_SSL_DIR"
      warn "Cloudflare mode: Create an Origin Certificate in Cloudflare for $N8N_HOST and paste into:"
      say "  ${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.crt"
      say "  ${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.key"
      say "Then: sudo nginx -t && sudo systemctl reload nginx"
      ;;
    lets-encrypt)
      nginx_write_le "$N8N_HOST" "$NGINX_SITE"
      if letsencrypt_issue "$N8N_HOST"; then
        ok "Let's Encrypt certificate issued"
      else
        warn "Could not issue Let's Encrypt cert now. After fixing DNS/port 80, run:"
        say "  sudo certbot --nginx -d ${N8N_HOST} --redirect --agree-tos -m admin@${N8N_HOST#*.} -n"
      fi
      ;;
    *) err "Unknown TLS_MODE: $TLS_MODE"; exit 1 ;;
  esac
  checkpoint "nginx_tls"
fi
progress

# 7) Optional protections
if ! reached "extras_done"; then
  if [ "$TLS_MODE" = "cloudflare" ]; then
    if [ "$NONINT" = "yes" ]; then WANT_AOP="$ENABLE_AOP"; else ask_yn "Enable Cloudflare Authenticated Origin Pulls (AOP)?" "Y" && WANT_AOP="yes" || WANT_AOP="no"; fi
    if [ "$WANT_AOP" = "yes" ]; then
      cf_enable_aop "$NGINX_SITE" "$CLOUDFLARE_SSL_DIR"
      save_cfg_kv ENABLE_AOP "yes"
      if [ "$NONINT" = "yes" ]; then WANT_CFLOCK="$LOCK_443_TO_CF"; else ask_yn "Restrict 443 to Cloudflare IPs now?" "Y" && WANT_CFLOCK="yes" || WANT_CFLOCK="no"; fi
      if [ "$WANT_CFLOCK" = "yes" ]; then cf_lock_443; save_cfg_kv LOCK_443_TO_CF "yes"; fi
    fi
  fi

  if [ "$NONINT" = "yes" ]; then WANT_BAUTH="$ENABLE_BASIC_AUTH"; else ask_yn "Add NGINX Basic Auth on editor (extra password)?" "N" && WANT_BAUTH="yes" || WANT_BAUTH="no"; fi
  if [ "$WANT_BAUTH" = "yes" ]; then
    read -r -p "Basic Auth username [admin]: " BA_USER; BA_USER="${BA_USER:-admin}"
    nginx_enable_basic_auth "$NGINX_SITE" "$BA_USER" "/etc/nginx/.n8n_htpasswd"
    save_cfg_kv ENABLE_BASIC_AUTH "yes"
  fi

  if [ "$NONINT" = "yes" ]; then WANT_RL="$ENABLE_RATE_LIMIT"; else ask_yn "Enable NGINX rate-limit for /webhook/ (10 r/s, burst 40)?" "Y" && WANT_RL="yes" || WANT_RL="no"; fi
  if [ "$WANT_RL" = "yes" ]; then nginx_enable_rate_limit "$NGINX_SITE"; save_cfg_kv ENABLE_RATE_LIMIT "yes"; fi

  checkpoint "extras_done"
fi
progress

# 8) Backups (optional)
if ! reached "backups"; then
  if [ "$NONINT" = "yes" ]; then WANT_BKP="yes"; else ask_yn "Install nightly backups + restore script?" "Y" && WANT_BKP="yes" || WANT_BKP="no"; fi
  if [ "$WANT_BKP" = "yes" ]; then
    cat >/usr/local/sbin/backup-n8n.sh <<'BK'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/var/backups/n8n"; TS="$(date +%Y%m%d_%H%M%S)"; WORK="/tmp/n8n-backup-$TS"
mkdir -p "$BACKUP_DIR" "$WORK"
PG=$(docker ps --format '{{.Names}}' | grep _postgres | head -n1)
[ -n "$PG" ] || { echo "Postgres container not found"; exit 1; }
docker exec -i "$PG" pg_dump -U n8n -d n8n > "$WORK/pg.sql"
tar -C / -cf "$WORK/n8n_data.tar" home/node/.n8n
tar -C "$WORK" -czf "$BACKUP_DIR/n8n-${TS}.tar.gz" pg.sql n8n_data.tar
sha256sum "$BACKUP_DIR/n8n-${TS}.tar.gz" > "$BACKUP_DIR/n8n-${TS}.sha256"
cd "$BACKUP_DIR"; (ls -1 n8n-*.tar.gz | sort | head -n -7 | xargs -r rm -f) || true
echo "Backup: $BACKUP_DIR/n8n-${TS}.tar.gz"
BK
    chmod +x /usr/local/sbin/backup-n8n.sh
    cat >/usr/local/sbin/restore-n8n.sh <<'RS'
#!/usr/bin/env bash
set -euo pipefail
ARCHIVE="${1:-}"; [ -f "$ARCHIVE" ] || { echo "Usage: restore-n8n.sh /var/backups/n8n/n8n-YYYYmmdd_HHMMSS.tar.gz"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$ARCHIVE"
cd /opt/n8n && docker compose down
tar -C / -xf "$TMP/n8n_data.tar"
cd /opt/n8n && docker compose up -d postgres
sleep 5
PG=$(docker ps --format '{{.Names}}' | grep _postgres | head -n1)
docker exec -i "$PG" psql -U n8n -d n8n < "$TMP/pg.sql"
cd /opt/n8n && docker compose up -d
echo "Restore complete."
RS
    chmod +x /usr/local/sbin/restore-n8n.sh
    backup_configure "$BACKUP_CRON_TIME" "$BACKUP_RETENTION"
  fi
  checkpoint "backups"
fi
progress

# 9) Health & Recap
health_check "$N8N_HOST"

say
ok "Install finished!"
say "URL: https://${N8N_HOST}"
say "Files:"
say "  • App dir:   $APP_DIR"
say "  • Compose:   $APP_DIR/docker-compose.yml"
say "  • Env:       $APP_DIR/.env"
say "  • NGINX:     $NGINX_SITE"
if [ "$TLS_MODE" = "cloudflare" ]; then
  say "TLS: Cloudflare Origin mode — paste your Origin cert/key and reload NGINX."
else
  say "TLS: Let's Encrypt (auto). If it failed, re-issue with certbot once DNS/80 is correct."
fi
ok "Keep your encryption key (in .env) safe. First visit will create the n8n owner account."

