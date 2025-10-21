#!/usr/bin/env bash
set -euo pipefail

# n8n-customize.sh — Branding & path customization

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (make sure Step 2 is complete)"; exit 1; }
. "$LIB"

TITLE_ARG=""
META_ARG=""
LOGO_URL_ARG=""
FAV_URL_ARG=""
ENABLE_SUBPATH_ARG=""
REVERT_DEFAULTS="no"
NONINT="no"

usage(){
cat <<USAGE
Usage: n8n-customize.sh [options]

Options:
  --title "My Console"       Set site title
  --meta  "Short tagline."   Set meta description
  --logo-url URL             Logo image (png/svg/jpg/webp), <= 5MB
  --favicon-url URL          Favicon (ico/png/svg/webp), <= 5MB
  --enable-subpath           Serve static site at / and n8n at /n8n
  --disable-subpath          Serve n8n at / (no landing at /)
  --revert-defaults          Remove custom assets and revert to default behavior (n8n at /)
  --non-interactive          Do not prompt; use args/config values
  -h, --help                 Show help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE_ARG="${2:-}"; shift ;;
    --meta) META_ARG="${2:-}"; shift ;;
    --logo-url) LOGO_URL_ARG="${2:-}"; shift ;;
    --favicon-url) FAV_URL_ARG="${2:-}"; shift ;;
    --enable-subpath) ENABLE_SUBPATH_ARG="yes" ;;
    --disable-subpath) ENABLE_SUBPATH_ARG="no" ;;
    --revert-defaults) REVERT_DEFAULTS="yes" ;;
    --non-interactive) NONINT="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

load_cfg
ensure_dirs
LOG="$(log_file)"; exec > >(tee -a "$LOG") 2>&1
h1 "n8n Customization"
say "Log: $LOG"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y file >/dev/null 2>&1 || true

STATIC_DIR="$SITE_STATIC_DIR"
SITE="$NGINX_SITE"
ENV_FILE="$APP_DIR/.env"

if [ ! -f "$SITE" ]; then
  warn "NGINX site not found at $SITE — creating base config for your TLS_MODE"
  nginx_install
  case "${TLS_MODE:-auto}" in
    cloudflare) nginx_write_cf "$N8N_HOST" "$SITE" "$CLOUDFLARE_SSL_DIR" ;;
    lets-encrypt|auto) nginx_write_le "$N8N_HOST" "$SITE" ;;
    *) nginx_write_le "$N8N_HOST" "$SITE" ;;
  esac
fi

if [ "$REVERT_DEFAULTS" = "yes" ]; then
  h1 "Reverting to defaults"
  save_cfg_kv ENABLE_SUBPATH "no"
  if grep -q "location /n8n/" "$SITE"; then
    awk '
      /server_name '"$N8N_HOST"';/ {srv=1}
      srv && /location \// {next}
      srv && /location \/n8n\// {next}
      {print}
    ' "$SITE" > "${SITE}.tmp" && mv "${SITE}.tmp" "$SITE"
    cat >> "$SITE" <<'NGX'
location / {
  proxy_pass http://127.0.0.1:5678/;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 20m;
}
NGX
  fi
  nginx -t && systemctl reload nginx || true

  if [ -d "$STATIC_DIR" ] && ask_yn "Remove static landing directory ($STATIC_DIR)?" "Y"; then
    rm -rf "$STATIC_DIR"
    ok "Removed $STATIC_DIR"
  else
    warn "Kept $STATIC_DIR"
  fi

  if [ -f "$ENV_FILE" ]; then
    sed -i '/^N8N_PATH=/d' "$ENV_FILE"
    sed -i '/^N8N_EDITOR_BASE_URL=/d' "$ENV_FILE"
    sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=https://${N8N_HOST}/|g" "$ENV_FILE" || echo "WEBHOOK_URL=https://${N8N_HOST}/" >> "$ENV_FILE"
    ok "Updated env for root mode"
    (cd "$APP_DIR" && docker compose up -d >/dev/null)
  else
    warn "Missing $ENV_FILE — skipping env update"
  fi

  health_check "$N8N_HOST"
  ok "Reverted to defaults (n8n at /)."
  exit 0
fi

TITLE="${TITLE_ARG:-$SITE_TITLE}"
META="${META_ARG:-$SITE_META}"
WANT_SUBPATH="${ENABLE_SUBPATH_ARG:-$ENABLE_SUBPATH}"

if [ "$NONINT" != "yes" ]; then
  TITLE="$(prompt_def "Website Title" "$TITLE")"
  META="$(prompt_def "Meta Description" "$META")"
  if ask_yn "Use subpath mode (/n8n) with a landing page at / ?" "$( [ "$WANT_SUBPATH" = "yes" ] && echo Y || echo N )"; then
    WANT_SUBPATH="yes"
  else
    WANT_SUBPATH="no"
  fi
  say
  say "Logo & Favicon — choose to keep current or provide URLs."
  if ask_yn "Update Logo?" "N"; then
    read -r -p "Logo URL: " LOGO_URL_ARG
  fi
  if ask_yn "Update Favicon?" "N"; then
    read -r -p "Favicon URL: " FAV_URL_ARG
  fi
fi

save_cfg_kv SITE_TITLE "$TITLE"
save_cfg_kv SITE_META "$META"
save_cfg_kv ENABLE_SUBPATH "$WANT_SUBPATH"
save_cfg_kv SITE_STATIC_DIR "$STATIC_DIR"

mkdir -p "$STATIC_DIR"
LOGO_PATH=""
FAV_PATH=""

if [ -n "${LOGO_URL_ARG:-}" ]; then
  LOGO_PATH="$(download_asset "$LOGO_URL_ARG" 'image/(png|svg+xml|jpeg|webp)' "$STATIC_DIR/logo")"
  [ -n "$LOGO_PATH" ] && ok "Logo saved: $LOGO_PATH" || warn "Logo not updated (download failed)"
fi
if [ -n "${FAV_URL_ARG:-}" ]; then
  FAV_PATH="$(download_asset "$FAV_URL_ARG" 'image/(png|svg+xml|x-icon|vnd.microsoft.icon|webp)' "$STATIC_DIR/favicon")"
  [ -n "$FAV_PATH" ] && ok "Favicon saved: $FAV_PATH" || warn "Favicon not updated (download failed)"
fi

if [ -z "$FAV_PATH" ] && [ -n "$LOGO_PATH" ]; then
  cp -f "$LOGO_PATH" "$STATIC_DIR/favicon.png" || true
  FAV_PATH="$STATIC_DIR/favicon.png"
fi

logo_ext="png"; fav_ext="png"
[ -n "$LOGO_PATH" ] && logo_ext="${LOGO_PATH##*.}"
[ -n "$FAV_PATH" ] && fav_ext="${FAV_PATH##*.}"

if [ "$WANT_SUBPATH" = "yes" ]; then
  write_static_site "$STATIC_DIR" "$TITLE" "$META" "$logo_ext" "$fav_ext"
  ok "Landing page written to $STATIC_DIR/index.html"

  awk '
    /server_name '"$N8N_HOST"';/ {srv=1}
    srv && /location \// {next}
    srv && /location \/n8n\// {next}
    {print}
  ' "$SITE" > "${SITE}.tmp" && mv "${SITE}.tmp" "$SITE"

  cat >> "$SITE" <<NGX
location / {
  root ${STATIC_DIR};
  try_files \$uri /index.html;
}
location /n8n/ {
  proxy_pass http://127.0.0.1:5678/n8n/;
  proxy_http_version 1.1;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$connection_upgrade;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 20m;
}
NGX

  nginx -t && systemctl reload nginx

  if [ -f "$ENV_FILE" ]; then
    grep -q '^N8N_PATH=' "$ENV_FILE" && sed -i 's|^N8N_PATH=.*|N8N_PATH=/n8n|' "$ENV_FILE" || echo "N8N_PATH=/n8n" >> "$ENV_FILE"
    grep -q '^N8N_EDITOR_BASE_URL=' "$ENV_FILE" && sed -i "s|^N8N_EDITOR_BASE_URL=.*|N8N_EDITOR_BASE_URL=https://${N8N_HOST}/n8n/|" "$ENV_FILE" || echo "N8N_EDITOR_BASE_URL=https://${N8N_HOST}/n8n/" >> "$ENV_FILE"
    sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=https://${N8N_HOST}/n8n/|g" "$ENV_FILE" || echo "WEBHOOK_URL=https://${N8N_HOST}/n8n/" >> "$ENV_FILE"
    ok "Updated env for subpath mode"
  else
    warn "Missing $ENV_FILE — skipping env update"
  fi

else
  awk '
    /server_name '"$N8N_HOST"';/ {srv=1}
    srv && /location \// {next}
    srv && /location \/n8n\// {next}
    {print}
  ' "$SITE" > "${SITE}.tmp" && mv "${SITE}.tmp" "$SITE"

  cat >> "$SITE" <<'NGX'
location / {
  proxy_pass http://127.0.0.1:5678/;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_read_timeout 3600s; proxy_send_timeout 3600s; client_max_body_size 20m;
}
NGX

  nginx -t && systemctl reload nginx

  if [ -f "$ENV_FILE" ]; then
    sed -i '/^N8N_PATH=/d' "$ENV_FILE"
    sed -i '/^N8N_EDITOR_BASE_URL=/d' "$ENV_FILE"
    sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=https://${N8N_HOST}/|g" "$ENV_FILE" || echo "WEBHOOK_URL=https://${N8N_HOST}/" >> "$ENV_FILE"
    ok "Updated env for root mode"
  else
    warn "Missing $ENV_FILE — skipping env update"
  fi
fi

if [ -f "$APP_DIR/docker-compose.yml" ]; then
  (cd "$APP_DIR" && docker compose up -d >/dev/null)
  ok "n8n services restarted"
else
  warn "Compose file not found at $APP_DIR — you may need to install first."
fi

say
h1 "Summary"
say "Host:   $N8N_HOST"
say "Mode:   $( [ "$WANT_SUBPATH" = "yes" ] && echo 'Subpath (/n8n) with landing at /' || echo 'Root (n8n at /)' )"
say "Title:  $TITLE"
say "Meta:   $META"
[ -n "$LOGO_PATH" ] && say "Logo:   $LOGO_PATH" || say "Logo:   (unchanged)"
[ -n "$FAV_PATH" ] && say "Favicon:$FAV_PATH" || say "Favicon:(unchanged)"
ok "Customization applied."
say "Open: https://${N8N_HOST}/ $( [ "$WANT_SUBPATH" = "yes" ] && echo '(landing) → /n8n/' )"
