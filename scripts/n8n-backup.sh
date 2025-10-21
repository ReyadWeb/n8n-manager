#!/usr/bin/env bash
set -euo pipefail

# n8n-backup.sh — Backup Manager (status / run-now / configure / restore)

LIB="/usr/local/sbin/n8n-lib.sh"
[ -f "$LIB" ] || { echo "Missing library: $LIB (make sure Step 2 is complete)"; exit 1; }
. "$LIB"

SUBCMD=""
CFG_TIME=""
CFG_RETENTION=""
RESTORE_FILE=""
NONINT="no"

usage(){
cat <<USAGE
Usage: n8n-backup.sh --status
       n8n-backup.sh --run-now
       n8n-backup.sh --configure HH:MM [--retention N]
       n8n-backup.sh --restore /path/to/n8n-YYYYmmdd_HHMMSS.tar.gz
       n8n-backup.sh                (interactive mini-menu)
USAGE
}

ensure_runner_scripts(){
  if [ ! -x /usr/local/sbin/backup-n8n.sh ]; then
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
KEEP="$(grep -E '^BACKUP_RETENTION=' /etc/n8n-manager.conf 2>/dev/null | sed -E 's/.*="?([0-9]+).*/\1/')" || KEEP=""
if [ -n "$KEEP" ]; then
  cd "$BACKUP_DIR"; (ls -1t n8n-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f) || true
fi
echo "Backup: $BACKUP_DIR/n8n-${TS}.tar.gz"
BK
    chmod +x /usr/local/sbin/backup-n8n.sh
  fi

  if [ ! -x /usr/local/sbin/restore-n8n.sh ]; then
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
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status) SUBCMD="status" ;;
    --run-now) SUBCMD="run-now" ;;
    --configure) SUBCMD="configure"; CFG_TIME="${2:-}"; shift ;;
    --retention) CFG_RETENTION="${2:-}"; shift ;;
    --restore) SUBCMD="restore"; RESTORE_FILE="${2:-}"; shift ;;
    --non-interactive) NONINT="yes" ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

load_cfg
ensure_dirs
LOG="$(log_file)"; exec > >(tee -a "$LOG") 2>&1
h1 "n8n Backup Manager"
say "Log: $LOG"
ensure_runner_scripts

interactive_menu(){
  echo
  say "What would you like to do?"
  say "  1) Status"
  say "  2) Run backup now"
  say "  3) Configure schedule/retention"
  say "  4) Restore from archive"
  say "  q) Quit"
  read -r -p "Enter choice: " ch
  case "$ch" in
    1) SUBCMD="status" ;;
    2) SUBCMD="run-now" ;;
    3) SUBCMD="configure" ;;
    4) SUBCMD="restore" ;;
    q|Q) echo "Bye!"; exit 0 ;;
    *) err "Invalid choice"; exit 1 ;;
  esac
}

validate_hhmm(){ [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

print_status(){ backup_status "$BACKUP_DIR"; }

run_now(){
  h1 "Running backup now"
  backup_run "$BACKUP_DIR"
}

configure_schedule(){
  local t="$CFG_TIME" r="$CFG_RETENTION"
  if [ -z "$t" ] && [ "$NONINT" != "yes" ]; then
    t="$(prompt_def "Daily backup time (HH:MM, 24h)" "$BACKUP_CRON_TIME")"
  fi
  if [ -z "$r" ] && [ "$NONINT" != "yes" ]; then
    r="$(prompt_def "Backups to keep (retention)" "$BACKUP_RETENTION")"
  fi
  t="${t:-$BACKUP_CRON_TIME}"
  r="${r:-$BACKUP_RETENTION}"
  validate_hhmm "$t" || { err "Invalid time: $t (use HH:MM 24h)"; exit 1; }
  [[ "$r" =~ ^[0-9]+$ ]] || { err "Invalid retention: $r"; exit 1; }
  backup_configure "$t" "$r"
}

restore_archive(){
  local file="$RESTORE_FILE"
  if [ -z "$file" ] && [ "$NONINT" != "yes" ]; then
    read -r -p "Path to archive (.tar.gz): " file
  fi
  [ -n "$file" ] || { err "No archive path provided"; exit 1; }
  [ -f "$file" ] || { err "Archive not found: $file"; exit 1; }

  local sha="${file%.tar.gz}.sha256"
  if [[ "${BACKUP_ENCRYPT:-no}" == "yes" && -n "${BACKUP_GPG_RECIPIENT:-}" ]]; then
  gpg --batch --yes -r "$BACKUP_GPG_RECIPIENT" -o "$ARCHIVE.gpg" -e "$ARCHIVE" \
    && shasum -a 256 "$ARCHIVE.gpg" > "$ARCHIVE.gpg.sha256" \
    && rm -f "$ARCHIVE"
  note "Encrypted archive: $ARCHIVE.gpg"
  fi
  need_bytes=$(tar -tzf "$ARCHIVE" | awk '{sum+=length($0)} END{print sum+104857600}') # rough +100MB
  avail_bytes=$(df -PB1 "$APP_DIR" | awk 'NR==2{print $4}')
  if (( avail_bytes < need_bytes )); then
    fail "Not enough space to restore. Need ~$(numfmt --to=iec $need_bytes), have $(numfmt --to=iec $avail_bytes)"
  fi
  if [ -f "$sha" ]; then
    say "Verifying checksum: $sha"
    if sha256sum -c "$sha"; then
      ok "Checksum OK"
    else
      warn "Checksum failed!"
      if [ "$NONINT" != "yes" ]; then
        ask_yn "Continue anyway?" "N" || { err "Aborted"; exit 1; }
      else
        err "Aborted due to checksum mismatch"; exit 1
      fi
    fi
  else
    warn "No checksum file found; proceeding without verification."
  fi

  if [ "$NONINT" != "yes" ]; then
    say "Restore will stop containers and replace database + data directory."
    ask_yn "Proceed to restore from: $file ?" "Y" || { say "Cancelled."; exit 0; }
  fi

  backup_restore "$file"
}

if [ -z "$SUBCMD" ]; then interactive_menu; fi

case "$SUBCMD" in
  status)    print_status ;;
  run-now)   run_now ;;
  configure) configure_schedule ;;
  restore)   restore_archive ;;
  *) err "Unknown subcommand: $SUBCMD"; usage; exit 1 ;;
esac

say
ok "Done."


