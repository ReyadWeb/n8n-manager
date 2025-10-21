#!/usr/bin/env bash
set -euo pipefail

# n8n-security.sh — Security audit & guided hardening

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (make sure Step 2 is complete)"; exit 1; }
. "$LIB"

APPLY_ALL="no"
REPORT_ONLY="no"
NONINT="no"

usage(){
cat <<USAGE
Usage: n8n-security.sh [--apply-all | --report-only] [--non-interactive]
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply-all) APPLY_ALL="yes" ;;
    --report-only) REPORT_ONLY="yes" ;;
    --non-interactive) NONINT="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

load_cfg
ensure_dirs
LOG="$(log_file)"; exec > >(tee -a "$LOG") 2>&1
h1 "n8n Security Audit & Hardening"
say "Log: $LOG"
echo

yn_apply(){
  local prompt="$1" default="$2"
  if [ "$REPORT_ONLY" = "yes" ]; then return 1; fi
  if [ "$APPLY_ALL" = "yes" ]; then [ "$default" = "Y" ]; return $?; fi
  if [ "$NONINT" = "yes" ]; then [ "$default" = "Y" ]; return $?; fi
  ask_yn "$prompt" "$default"
}

check_line_in_file(){
  local pattern="$1" file="$2"
  grep -Eq "$pattern" "$file" 2>/dev/null
}

enable_fail2ban_nginx_jail(){
  apt-get install -y fail2ban >/dev/null 2>&1 || true
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/nginx-n8n.local <<'JAIL'
[nginx-http-auth]
enabled = true
port    = http,https
logpath = /var/log/nginx/*access.log
maxretry = 6
findtime = 600
bantime  = 900
JAIL
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
}

ensure_hsts(){
  local site="$1"
  if ! grep -q 'Strict-Transport-Security' "$site"; then
    awk '
      /server_name/ && !x {print; print "  add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;"; x=1; next}
      {print}
    ' "$site" > "${site}.tmp" && mv "${site}.tmp" "$site"
    nginx -t && systemctl reload nginx || true
    ok "HSTS enabled on $site"
  else
    ok "HSTS already present"
  fi
}

create_swap_if_needed(){
  local rammb; rammb="$(free -m | awk "/^Mem:/{print \$2}")"
  local has_swap; has_swap="$(swapon --show | wc -l)"
  if [ "$has_swap" -eq 0 ] && [ "$rammb" -lt 4096 ]; then
    if yn_apply "Create a 2G swapfile (recommended for <4GB RAM)?" "Y"; then
      fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      if ! grep -q '^/swapfile' /etc/fstab; then echo '/swapfile swap swap defaults 0 0' >> /etc/fstab; fi
      ok "2G swapfile created and enabled"
    fi
  fi
}

h1 "Report"

SSH_ROOT=$(sshd -T 2>/dev/null | awk '/permitrootlogin/{print $2}')
SSH_PASS=$(sshd -T 2>/dev/null | awk '/passwordauthentication/{print $2}')
say "SSH:"
say "  PermitRootLogin:       ${SSH_ROOT:-unknown}"
say "  PasswordAuthentication: ${SSH_PASS:-unknown}"
[ "$SSH_ROOT" = "no" ] && [ "$SSH_PASS" = "no" ] && ok "SSH looks hardened" || warn "SSH can be hardened"

if ufw status | grep -q "Status: active"; then
  say "UFW: active"
else
  warn "UFW: not active"
fi
for p in 22 80 443; do
  ufw status | grep -qE "\\b${p}/tcp\\b" && say "  Port ${p}/tcp: allowed" || warn "  Port ${p}/tcp: NOT allowed"
done

systemctl is-active --quiet fail2ban && say "Fail2ban: active" || warn "Fail2ban: not running"

[ -f /etc/sysctl.d/99-hardening.conf ] && ok "Sysctl hardening file present" || warn "Sysctl hardening file missing"

say "NGINX/TLS:"
if [ -f "$NGINX_SITE" ]; then
  tls_mode="${TLS_MODE:-auto}"
  say "  TLS_MODE: $tls_mode"
  case "$tls_mode" in
    cloudflare)
      if [ -f "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.crt" ] && [ -f "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.key" ]; then
        ok "  CF Origin cert/key present"
      else
        warn "  CF Origin cert/key MISSING"
      fi
      grep -q 'ssl_verify_client on;' "$NGINX_SITE" && say "  AOP: enabled" || warn "  AOP: not enabled"
      ;;
    lets-encrypt|auto)
      if [ -f "/etc/letsencrypt/live/${N8N_HOST}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${N8N_HOST}/privkey.pem" ]; then
        ok "  LE cert present"
      else
        warn "  LE cert MISSING"
      fi
      ;;
    *) warn "  Unknown TLS mode in config" ;;
  esac
  grep -q 'Strict-Transport-Security' "$NGINX_SITE" && say "  HSTS: present" || warn "  HSTS: not present"
  grep -q 'limit_req_zone' /etc/nginx/nginx.conf 2>/dev/null && say "  Rate limit zone: present" || warn "  Rate limit zone: missing"
  grep -q 'location /webhook/' "$NGINX_SITE" 2>/dev/null && grep -q 'limit_req ' "$NGINX_SITE" && say "  /webhook/: limited" || warn "  /webhook/: not limited"
  grep -q 'auth_basic ' "$NGINX_SITE" 2>/dev/null && say "  Basic Auth: enabled" || say "  Basic Auth: disabled"
else
  warn "  NGINX site missing at $NGINX_SITE"
fi

if iptables -S 2>/dev/null | grep -q 'match-set cf4'; then
  say "Firewall: 443 locked to Cloudflare IPs"
else
  say "Firewall: 443 lock not enabled"
fi

dpkg -l | grep -q unattended-upgrades && ok "unattended-upgrades installed" || warn "unattended-upgrades not installed"

if grep -q 'restart: unless-stopped' "$APP_DIR/docker-compose.yml" 2>/dev/null; then
  say "Docker: restart policy OK (unless-stopped)"
else
  warn "Docker: restart policy not set to unless-stopped"
fi

FREE_GB="$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')"
say "Disk free: ${FREE_GB} GB"
[ "${FREE_GB:-0}" -lt 15 ] && warn "Low disk space (consider cleanup)"
SWAP_LINES="$(swapon --show | wc -l)"
[ "$SWAP_LINES" -eq 0 ] && warn "No swap detected" || say "Swap: present"

echo

if [ "$REPORT_ONLY" = "yes" ]; then
  ok "Report completed (no changes made)."
  exit 0
fi

h1 "Apply Recommended Hardening"

if [ "$SSH_ROOT" != "no" ] || [ "$SSH_PASS" != "no" ] || [ ! -f /etc/sysctl.d/99-hardening.conf ]; then
  if yn_apply "Apply SSH hardening + sysctl + logrotate now?" "Y"; then
    ensure_base_tools
    apply_os_hardening
  fi
fi

if ! ufw status | grep -q "Status: active"; then
  if yn_apply "Enable UFW firewall?" "Y"; then
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw allow 80,443/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ok "UFW enabled (22/80/443 allowed)"
  fi
else
  for p in 22 80 443; do
    ufw status | grep -qE "\\b${p}/tcp\\b" || ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  done
fi

if ! systemctl is-active --quiet fail2ban; then
  if yn_apply "Install & start fail2ban with basic NGINX jail?" "Y"; then
    enable_fail2ban_nginx_jail
    ok "fail2ban enabled"
  fi
fi

if [ -f "$NGINX_SITE" ] && ! grep -q 'Strict-Transport-Security' "$NGINX_SITE"; then
  if yn_apply "Enable HSTS (forces HTTPS for 1 year)?" "Y"; then
    ensure_hsts "$NGINX_SITE"
  fi
fi

if [ -f "$NGINX_SITE" ]; then
  if ! grep -q 'limit_req_zone' /etc/nginx/nginx.conf 2>/dev/null || ! (grep -q 'location /webhook/' "$NGINX_SITE" && grep -q 'limit_req ' "$NGINX_SITE"); then
    if yn_apply "Enable rate limit for /webhook/ (10 r/s, burst 40)?" "Y"; then
      nginx_enable_rate_limit "$NGINX_SITE"
    fi
  fi
fi

if [ -f "$NGINX_SITE" ] && ! grep -q 'auth_basic ' "$NGINX_SITE"; then
  if yn_apply "Enable extra Basic Auth prompt for n8n editor?" "N"; then
    read -r -p "Basic Auth username [admin]: " BA_USER; BA_USER="${BA_USER:-admin}"
    nginx_enable_basic_auth "$NGINX_SITE" "$BA_USER" "/etc/nginx/.n8n_htpasswd"
    save_cfg_kv ENABLE_BASIC_AUTH "yes"
  fi
fi

if [ "${TLS_MODE:-auto}" = "cloudflare" ]; then
  if [ ! -f "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.crt" ] || [ ! -f "${CLOUDFLARE_SSL_DIR}/${N8N_HOST}.origin.key" ]; then
    warn "Cloudflare Origin cert/key missing — generate in CF dashboard and place files, then reload NGINX."
  else
    if ! grep -q 'ssl_verify_client on;' "$NGINX_SITE"; then
      if yn_apply "Enable Cloudflare Authenticated Origin Pulls (AOP)?" "Y"; then
        cf_enable_aop "$NGINX_SITE" "$CLOUDFLARE_SSL_DIR"
        save_cfg_kv ENABLE_AOP "yes"
      fi
    fi
    if ! iptables -S 2>/dev/null | grep -q 'match-set cf4'; then
      if yn_apply "Restrict port 443 to Cloudflare IPs?" "Y"; then
        cf_lock_443
        save_cfg_kv LOCK_443_TO_CF "yes"
      fi
    fi
  fi
fi

if ! dpkg -l | grep -q unattended-upgrades; then
  if yn_apply "Install unattended-upgrades for security patches?" "Y"; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y unattended-upgrades >/dev/null 2>&1 || true
    dpkg-reconfigure --priority=low unattended-upgrades >/dev/null 2>&1 || true
    ok "unattended-upgrades installed"
  fi
fi

create_swap_if_needed

[ "${FREE_GB:-0}" -lt 15 ] && warn "Consider cleanup: docker image prune & log rotation."

say
ok "Security hardening completed."
say "You can rerun this script anytime to re-check the posture."
