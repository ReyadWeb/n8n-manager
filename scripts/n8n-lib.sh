#!/usr/bin/env bash
# n8n-lib.sh — Shared helpers for n8n Manager scripts
# Safe defaults, friendly UI, idempotent operations.

set -Euo pipefail

# =============[ UI ]=============
COLOR(){ printf "\033[%sm%s\033[0m" "$1" "$2"; }
say(){ printf "%b\n" "$*"; }
h1(){ say "$(COLOR '1;36' "== $* ==")"; }
ok(){ say "$(COLOR '1;32' "✔ $*")"; }
warn(){ say "$(COLOR '1;33' "! $*")"; }
err(){ say "$(COLOR '1;31' "✖ $*")"; }
ask_yn(){ local p="$1" d="${2:-}"; while true; do read -r -p "$(COLOR '1;37' "$p") ${d:+[$d]}: " a; a="${a:-$d}"; case "$a" in [Yy]) return 0;; [Nn]) return 1;; *) say "Please answer Y or N.";; esac; done; }
prompt_def(){ local p="$1" def="$2" out; read -r -p "$(COLOR '1;37' "$p") [$def]: " out; echo "${out:-$def}"; }

SPINNER_PID=""; start_spin(){ local m="$1"; local f=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); local i=0; printf "  %s " "$(COLOR '1;34' "$m")"; ( while true; do printf "\r  %s %s" "${f[i]}" "$m"; i=$(( (i+1)%${#f[@]} )); sleep 0.1; done ) & SPINNER_PID=$!; disown "$SPINNER_PID" 2>/dev/null||true; }
stop_ok(){   [ -n "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null||true; printf "\r"; ok "$1"; SPINNER_PID=""; }
stop_warn(){ [ -n "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null||true; printf "\r"; warn "$1"; SPINNER_PID=""; }
stop_err(){  [ -n "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null||true; printf "\r"; err "$1"; SPINNER_PID=""; }

PROG_TOTAL=20 PROG_STEP=0
progress_reset(){ PROG_STEP=0; }
progress(){ PROG_STEP=$((PROG_STEP+1)); local pct=$(( PROG_STEP*100/PROG_TOTAL )); local filled=$((pct/4)); local empty=$((25-filled)); printf "\r[%s%s] %3d%%  " "$(printf '█%.0s' $(seq 1 $filled))" "$(printf ' %.0s' $(seq 1 $empty))" "$pct"; [ "$PROG_STEP" -ge "$PROG_TOTAL" ] && echo; }

# =============[ Config / State ]=============
CFG_FILE="/etc/n8n-manager.conf"
STATE_DIR="/var/lib/n8n-manager"
LOG_DIR="$STATE_DIR/logs"
LOCK_FILE="$STATE_DIR/lock"
STATE_FILE="$STATE_DIR/state"

ensure_dirs(){ mkdir -p "$STATE_DIR" "$LOG_DIR"; }

# defaults if CFG is missing or sparse (generic, no secrets)
load_cfg_defaults(){
  PUBLIC_IP="${PUBLIC_IP:-203.0.113.10}"
  N8N_HOST="${N8N_HOST:-n8n.example.com}"
  TLS_MODE="${TLS_MODE:-auto}"
  TIMEZONE="${TIMEZONE:-America/New_York}"
  APP_DIR="${APP_DIR:-/opt/n8n}"
  NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/n8n}"
  NGINX_SITE_LINK="${NGINX_SITE_LINK:-/etc/nginx/sites-enabled/n8n}"
  CLOUDFLARE_SSL_DIR="${CLOUDFLARE_SSL_DIR:-/etc/ssl/cloudflare}"
  ENABLE_SUBPATH="${ENABLE_SUBPATH:-yes}"
  SITE_TITLE="${SITE_TITLE:-Ops Console}"
  SITE_META="${SITE_META:-Automation console.}"
  SITE_STATIC_DIR="${SITE_STATIC_DIR:-/var/www/n8n.example.com}"
  BACKUP_DIR="${BACKUP_DIR:-/var/backups/n8n}"
  BACKUP_CRON_TIME="${BACKUP_CRON_TIME:-03:17}"
  BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
  ENABLE_RATE_LIMIT="${ENABLE_RATE_LIMIT:-yes}"
  ENABLE_BASIC_AUTH="${ENABLE_BASIC_AUTH:-no}"
  ENABLE_AOP="${ENABLE_AOP:-no}"
  LOCK_443_TO_CF="${LOCK_443_TO_CF:-no}"
}

# immediate safe fallbacks so strict mode doesn't break
# (these protect us even if someone forgets to call load_cfg)
: "${N8N_HOST:=n8n.example.com}"
: "${BACKUP_DIR:=/var/backups/n8n}"

load_cfg(){
  ensure_dirs
  # 1) load defaults first
  load_cfg_defaults
  # 2) then let user config override
  if [ -f "$CFG_FILE" ]; then
    # shellcheck source=/etc/n8n-manager.conf
    . "$CFG_FILE"
  fi
}

save_cfg_kv(){ # save or replace KEY=VALUE in CFG_FILE
  local k="$1" v="$2"
  touch "$CFG_FILE"
  if grep -qE "^\s*${k}=" "$CFG_FILE"; then
    sed -i "s|^\s*${k}=.*|${k}=\"${v//\//\\/}\"|g" "$CFG_FILE"
  else
    echo "${k}=\"${v}\"" >> "$CFG_FILE"
  fi
}

with_lock(){ exec 9>"$LOCK_FILE"; flock -n 9 || { err "Another run in progress (lock: $LOCK_FILE)"; exit 1; }; }
checkpoint(){ echo "$1" > "$STATE_FILE"; }
reached(){ [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE"; }
clear_state(){ rm -f "$STATE_FILE" 2>/dev/null || true; }

log_file(){
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  echo "$LOG_DIR/run_$ts.log"
}

# =============[ Validation ]=============
valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_fqdn(){ [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }

dns_detect_mode(){ # sets CF_EDGE=true|false, DIRECT_IP=true|false
  local host="$1" ip="$2"
  command -v dig >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y dnsutils >/dev/null 2>&1 || true; }
  RESOLVE_A="$(dig +short "$host" A || true)"
  RESOLVE_CNAME="$(dig +short "$host" CNAME || true)"
  CF_EDGE=false; DIRECT_IP=false
  if echo "$RESOLVE_A" | grep -Eq '(^104\.|^172\.|^188\.114\.)'; then CF_EDGE=true; fi
  if echo "$RESOLVE_A" | grep -qx "$ip"; then DIRECT_IP=true; fi
}

# =============[ Packages / Security Baseline ]=============
ensure_base_tools(){
  start_spin "Installing base tools & security"
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates gnupg lsb-release unzip jq htop ufw fail2ban unattended-upgrades >/dev/null 2>&1 || true
  dpkg-reconfigure --priority=low unattended-upgrades >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 80,443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  stop_ok "Base tools installed; firewall 80/443 open"
}

apply_os_hardening(){
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
  systemctl reload sshd || true
  cat >/etc/sysctl.d/99-hardening.conf <<'SYS'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
kernel.randomize_va_space=2
SYS
  sysctl --system >/dev/null || true
  cat >/etc/logrotate.d/docker-nginx <<'LR'
/var/lib/docker/containers/*/*.log { rotate 7 daily compress missingok copytruncate notifempty }
/var/log/nginx/*.log { rotate 14 daily compress missingok copytruncate notifempty }
LR
  ok "OS hardening applied (SSH, sysctl, logrotate)"
}

# =============[ Docker ]=============
ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    start_spin "Installing Docker Engine + Compose"
    install -m 0755 -d /etc/apt/keyrings >/dev/null 2>&1 || true
    local OS_ID; OS_ID="$(. /etc/os-release; echo "$ID")"
    local OS_CODENAME; OS_CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
    curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | tee /etc/apt/keyrings/docker.asc >/dev/null
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null
    stop_ok "Docker installed"
  else
    ok "Docker already installed"
  fi
}

compose_write_env(){
  local dir="$1" host="$2" tz="$3"
  mkdir -p "$dir"
  local ENC_KEY DB_PASS
  ENC_KEY="$(openssl rand -base64 48)"
  DB_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
  cat > "$dir/.env" <<EOF
N8N_HOST=${host}
N8N_PROTOCOL=https
WEBHOOK_URL=https://${host}/

N8N_ENCRYPTION_KEY=${ENC_KEY}
GENERIC_TIMEZONE=${tz}

DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${DB_PASS}

EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
EOF
  chmod 600 "$dir/.env"
  ok ".env created at $dir/.env"
}

compose_write_file(){
  local dir="$1"
  cat > "$dir/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: ${DB_POSTGRESDB_USER}
      POSTGRES_PASSWORD: ${DB_POSTGRESDB_PASSWORD}
      POSTGRES_DB: ${DB_POSTGRESDB_DATABASE}
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--save", "60", "1000", "--appendonly", "no"]
    restart: unless-stopped

  n8n:
    image: n8nio/n8n:latest
    env_file: .env
    depends_on: [postgres, redis]
    volumes:
      - n8n_data:/home/node/.n8n
    ports:
      - "127.0.0.1:5678:5678"
    restart: unless-stopped

  n8n-worker:
    image: n8nio/n8n:latest
    command: worker
    env_file: .env
    depends_on: [postgres, redis]
    restart: unless-stopped

volumes:
  n8n_data:
  pgdata:
YAML
  ok "docker-compose.yml written"
}

compose_up(){
  local dir="$1"
  (cd "$dir" && docker compose pull >/dev/null && docker compose up -d >/dev/null)
  ok "Docker stack up"
}

compose_down(){
  local dir="$1"
  [ -f "$dir/docker-compose.yml" ] && (cd "$dir" && docker compose down -v || true)
}

# =============[ NGINX + TLS ]=============
nginx_install(){
  apt-get install -y nginx snapd >/dev/null 2>&1 || true
  ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
  ok "NGINX installed"
}

nginx_write_cf(){
  local host="$1" site="$2" cf_dir="$3"
  mkdir -p "$(dirname "$site")" "$cf_dir"
  cat > "$site" <<NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server { listen 80; server_name ${host}; return 301 https://\$host\$request_uri; }
server {
  listen 443 ssl http2; server_name ${host};
  ssl_certificate     ${cf_dir}/${host}.origin.crt;
  ssl_certificate_key ${cf_dir}/${host}.origin.key;
  # ssl_client_certificate ${cf_dir}/cloudflare_origin_ca.pem;
  # ssl_verify_client on;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  location / {
    proxy_pass http://127.0.0.1:5678/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 20m;
  }
}
NGINX
  ln -sf "$site" /etc/nginx/sites-enabled/n8n
  nginx -t && systemctl reload nginx || true
  warn "Cloudflare mode: paste Origin cert & key into ${cf_dir}/${host}.origin.{crt,key} then reload nginx."
}

nginx_write_le(){
  local host="$1" site="$2"
  mkdir -p "$(dirname "$site")"
  cat > "$site" <<NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server { listen 80; server_name ${host}; location /.well-known/acme-challenge/ { root /var/www/html; } return 301 https://\$host\$request_uri; }
server {
  listen 443 ssl http2; server_name ${host};
  ssl_certificate     /etc/letsencrypt/live/${host}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${host}/privkey.pem;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  location / {
    proxy_pass http://127.0.0.1:5678/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 20m;
  }
}
NGINX
  ln -sf "$site" /etc/nginx/sites-enabled/n8n
  nginx -t && systemctl reload nginx
}

letsencrypt_issue(){
  local host="$1"
  if ! snap list | grep -q certbot; then snap install --classic certbot >/dev/null 2>&1 || true; fi
  ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
  certbot --nginx -d "${host}" --redirect --agree-tos -m admin@"${host#*.}" -n || return 1
}

cf_enable_aop(){
  local site="$1" cf_dir="$2"
  curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
    | tee "${cf_dir}/cloudflare_origin_ca.pem" >/dev/null
  sed -i 's|# ssl_client_certificate|ssl_client_certificate|' "$site" || true
  sed -i 's|# ssl_verify_client on;|ssl_verify_client on;|' "$site" || true
  nginx -t && systemctl reload nginx || true
}

cf_lock_443(){
  apt -y install ipset netfilter-persistent >/dev/null 2>&1 || true
  ipset create cf4 hash:net -exist; ipset create cf6 hash:net family inet6 -exist
  ipset flush cf4; ipset flush cf6
  curl -fsSL https://www.cloudflare.com/ips-v4 | while read -r n; do [ -n "$n" ] && ipset add cf4 "$n"; done
  curl -fsSL https://www.cloudflare.com/ips-v6 | while read -r n; do [ -n "$n" ] && ipset add cf6 "$n"; done
  iptables  -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables  -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables  -I INPUT -p tcp --dport 80 -j ACCEPT
  ip6tables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 22 -j ACCEPT
  ip6tables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT
  iptables  -I INPUT -p tcp --dport 443 -m set --match-set cf4 src -j ACCEPT
  ip6tables -I INPUT -p tcp --dport 443 -m set --match-set cf6 src -j ACCEPT
  iptables  -A INPUT -p tcp --dport 443 -j DROP
  ip6tables -A INPUT -p tcp --dport 443 -j DROP
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  ok "Port 443 restricted to Cloudflare IPs"
}

cf_unlock_443(){
  iptables  -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
  ip6tables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables  -S | grep -F "match-set cf4" >/dev/null 2>&1 && iptables  -D INPUT -p tcp --dport 443 -m set --match-set cf4 src -j ACCEPT || true
  ip6tables -S | grep -F "match-set cf6" >/dev/null 2>&1 && ip6tables -D INPUT -p tcp --dport 443 -m set --match-set cf6 src -j ACCEPT || true
  ipset destroy cf4 2>/dev/null || true
  ipset destroy cf6 2>/dev/null || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  ok "Cloudflare 443 lock removed"
}

# =============[ Customization ]=============
download_asset(){
  local url="$1" accept_regex="$2" dest_noext="$3" max_bytes=$((5*1024*1024))
  local tmp mime ext dest
  tmp="$(mktemp)"
  if ! curl -fsSL -o "$tmp" -L "$url"; then rm -f "$tmp"; warn "Download failed: $url"; echo ""; return 0; fi
  local size; size=$(stat -c%s "$tmp" 2>/dev/null||echo 0)
  [ "$size" -gt 0 ] && [ "$size" -le "$max_bytes" ] || { rm -f "$tmp"; warn "Invalid size for $url"; echo ""; return 0; }
  mime=$(file -b --mime-type "$tmp" 2>/dev/null||echo "")
  if ! echo "$mime" | grep -Eq "$accept_regex"; then rm -f "$tmp"; warn "Unsupported mime-type $mime"; echo ""; return 0; fi
  case "$mime" in
    image/png) ext="png" ;; image/svg+xml) ext="svg" ;; image/jpeg) ext="jpg" ;; image/webp) ext="webp" ;;
    image/x-icon|image/vnd.microsoft.icon) ext="ico" ;; *) ext="png" ;;
  esac
  dest="${dest_noext}.${ext}"
  mv -f "$tmp" "$dest"
  echo "$dest"
}

write_static_site(){
  local dir="$1" title="$2" meta="$3" logo_ext="$4" fav_ext="$5"
  mkdir -p "$dir"
  cat > "$dir/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${title}</title>
  <meta name="description" content="${meta}">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="/favicon.${fav_ext}">
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${meta}">
  <style>
    body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,'Helvetica Neue',Arial,sans-serif;margin:0;padding:40px;background:#0f172a;color:#e2e8f0}
    .card{max-width:780px;margin:auto;background:#111827;border-radius:16px;padding:28px;border:1px solid #1f2937}
    h1{margin:0 0 8px}
    p{opacity:.9}
    a.btn{display:inline-block;margin-top:16px;padding:10px 16px;border-radius:10px;background:#22c55e;color:#0b1220;text-decoration:none;font-weight:600}
    header{display:flex;align-items:center;gap:12px;margin-bottom:16px}
    img.logo{height:36px;width:auto}
  </style>
</head>
<body>
  <div class="card">
    <header>
      <img class="logo" src="/logo.${logo_ext}" alt="${title}">
      <h1>${title}</h1>
    </header>
    <p>${meta}</p>
    <a class="btn" href="/n8n/">Open Console</a>
  </div>
</body>
</html>
HTML
}

# =============[ Backups ]=============
backup_run(){
  local backup_dir="$1"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local work="/tmp/n8n-backup-$ts"
  mkdir -p "$backup_dir" "$work"
  local PG; PG=$(docker ps --format '{{.Names}}' | grep _postgres | head -n1)
  [ -n "$PG" ] || { err "Postgres container not found"; return 1; }
  docker exec -i "$PG" pg_dump -U n8n -d n8n > "$work/pg.sql"
  tar -C / -cf "$work/n8n_data.tar" home/node/.n8n
  tar -C "$work" -czf "$backup_dir/n8n-${ts}.tar.gz" pg.sql n8n_data.tar
  sha256sum "$backup_dir/n8n-${ts}.tar.gz" > "$backup_dir/n8n-${ts}.sha256"
  ok "Backup created: $backup_dir/n8n-${ts}.tar.gz"
}

backup_configure(){
  local hhmm="$1" retention="$2"
  echo "$(printf '%s %s * * * root /usr/local/sbin/backup-n8n.sh >> /var/log/backup-n8n.log 2>&1' "$(echo "$hhmm" | awk -F: '{print $2}')" "$(echo "$hhmm" | awk -F: '{print $1}')" )" > /etc/cron.d/backup-n8n
  save_cfg_kv BACKUP_CRON_TIME "$hhmm"
  save_cfg_kv BACKUP_RETENTION "$retention"
  ok "Backup schedule set to $hhmm (retention: $retention)"
}

backup_status(){
  local dir="$1"
  say "Backups in $dir:"
  ls -lh "$dir"/n8n-*.tar.gz 2>/dev/null || say " (none yet)"
  if [ -f /etc/cron.d/backup-n8n ]; then
    say "Cron: $(cat /etc/cron.d/backup-n8n)"
  else
    say "Cron: (not configured)"
  fi
}

backup_restore(){
  local archive="$1"
  [ -f "$archive" ] || { err "Archive not found: $archive"; return 1; }
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  tar -C "$tmp" -xzf "$archive"
  (cd "$APP_DIR" && docker compose down)
  tar -C / -xf "$tmp/n8n_data.tar"
  (cd "$APP_DIR" && docker compose up -d postgres)
  sleep 5
  local PG; PG=$(docker ps --format '{{.Names}}' | grep _postgres | head -n1)
  docker exec -i "$PG" psql -U n8n -d n8n < "$tmp/pg.sql"
  (cd "$APP_DIR" && docker compose up -d)
  ok "Restore complete from $archive"
}

# =============[ Health ]=============
health_check(){
  local host="$1"
  set +e
  curl -sI "http://${host}/healthz" | grep -q "200" && ok "HTTP /healthz OK" || warn "HTTP /healthz not ready"
  curl -sI "https://${host}/healthz" | grep -q "200" && ok "HTTPS /healthz OK" || warn "HTTPS /healthz pending"
  set -e
}

doctor() {
  # lightweight version (your previous one used header/section/fail/note which weren't defined)
  local host="${N8N_HOST:-}"
  h1 "n8n Manager Doctor"

  say "DNS:"
  if [[ -n "$host" ]]; then
    say "  Host: $host"
    dig +short "$host" || true
  else
    warn "  N8N_HOST not set."
  fi

  say "NGINX test:"
  if command -v nginx >/dev/null 2>&1; then
    sudo nginx -t || err "nginx config test failed"
  else
    warn "  nginx not installed"
  fi

  say "Ports (22,80,443,5678):"
  ss -ltnp | awk 'NR==1 || /:22 |:80 |:443 |:5678 /{print}'

  say "Docker containers:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

  say "Disk & Memory:"
  df -h / || true
  free -h || true

  say "Backups (latest 3):"
  ls -1 "${BACKUP_DIR:-/var/backups/n8n}"/*.tar.gz 2>/dev/null | tail -n 3 || echo "(none found)"
}

# =============[ Alerts ]=============
alert() { # alert "Subject" "Message"
  local subj="$1"; shift
  local msg="$*"
  if [[ -n "${ALERT_SLACK_WEBHOOK:-}" ]]; then
    curl -fsS -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\"*${subj}*\\n${msg}\"}" \
      "$ALERT_SLACK_WEBHOOK" >/dev/null || true
  fi
  if [[ -n "${ALERT_EMAIL_TO:-}" ]]; then
    printf "%s\n" "$msg" | mail -s "$subj" "$ALERT_EMAIL_TO" || true
  fi
}

# =============[ Image pinning ]=============
pin_image() { # pin_image service image repo tag
  local svc="$1" img="$2" repo="$3" tag="$4"
  local digest
  digest=$(docker pull "$repo:$tag" --quiet >/dev/null 2>&1; docker inspect --format='{{index .RepoDigests 0}}' "$repo:$tag")
  [[ -n "$digest" ]] || err "Could not resolve digest for $repo:$tag"
  sed -i "s#image: $img#image: $digest#g" "$APP_DIR/docker-compose.yml"
  ok "Pinned $svc to $digest"
}

# (removed the stray call):
# pin_image "n8n" "n8nio/n8n:latest" "n8nio/n8n" "latest"
