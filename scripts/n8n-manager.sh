#!/usr/bin/env bash
set -euo pipefail

# n8n-manager.sh — Main menu + CLI router for the n8n Manager suite

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (run Step 2 first)"; exit 1; }
. "$LIB"

load_cfg
ensure_dirs

INSTALL="/usr/local/sbin/n8n-install.sh"
RESET="/usr/local/sbin/n8n-reset.sh"
CUSTOMIZE="/usr/local/sbin/n8n-customize.sh"
SECURITY="/usr/local/sbin/n8n-security.sh"
BACKUP="/usr/local/sbin/n8n-backup.sh"

need_subscripts(){
  local missing=()
  for f in "$INSTALL" "$RESET" "$CUSTOMIZE" "$SECURITY" "$BACKUP"; do
    [ -x "$f" ] || missing+=("$f")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    err "Missing scripts:"
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo "We will create these in the next steps."
    exit 1
  fi
}

print_header(){
  clear
  h1 "n8n Manager"
  say "Config: $(COLOR '1;37' "$CFG_FILE")"
  say "Host:   $(COLOR '1;37' "$N8N_HOST")"
  say "IP:     $(COLOR '1;37' "$PUBLIC_IP")"
  say "TZ:     $(COLOR '1;37' "$TIMEZONE")"
  echo
}

usage(){
cat <<USAGE
n8n-manager — Main menu / CLI

Menu:
  Run without arguments to open the interactive menu.

CLI:
  --install [--ip IP] [--host FQDN] [--force-cloudflare|--force-letsencrypt] [--non-interactive]
  --reset [--yes] [--purge-backups]
  --customize [--title TEXT] [--meta TEXT] [--logo-url URL] [--favicon-url URL] [--enable-subpath|--disable-subpath] [--non-interactive]
  --security [--apply-all|--report-only]
  --backup --status | --run-now | --configure HH:MM [--retention N] | --restore /path/file.tar.gz
USAGE
}

run_with_log(){
  local script="$1"; shift
  local log; log="$(log_file)"
  say "Logging to: $log"
  "$script" $@ 2>&1 | tee "$log"
}

menu(){
  print_header
  say "Choose an action:"
  say "  1) Install — reset first, then fresh hardened install"
  say "  2) Reset   — clean uninstall to a fresh state"
  say "  3) Customization — title, meta, logo, favicon; optional subpath"
  say "  4) Security — audit + guided hardening"
  say "  5) Backup — status / run / configure / restore"
  echo
  read -r -p "Enter 1-5 (q to quit): " CHOICE
  case "${CHOICE:-}" in
    1) need_subscripts; run_with_log "$INSTALL" ;;
    2) need_subscripts; run_with_log "$RESET" ;;
    3) need_subscripts; run_with_log "$CUSTOMIZE" ;;
    4) need_subscripts; run_with_log "$SECURITY" ;;
    5) need_subscripts; run_with_log "$BACKUP" ;;
    q|Q) echo "Bye!"; exit 0 ;;
    *) err "Invalid choice."; exit 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  menu
  exit 0
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
  --install) shift; need_subscripts; run_with_log "$INSTALL" "$@" ;;
  --reset) shift; need_subscripts; run_with_log "$RESET" "$@" ;;
  --customize) shift; need_subscripts; run_with_log "$CUSTOMIZE" "$@" ;;
  --security) shift; need_subscripts; run_with_log "$SECURITY" "$@" ;;
  --backup) shift; need_subscripts; run_with_log "$BACKUP" "$@" ;;
  *) err "Unknown option: $1"; usage; exit 1 ;;
esac
