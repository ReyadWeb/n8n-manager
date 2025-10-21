# n8n Manager — Project / Code Guide

**Overview**  
n8n Manager is a modular set of Bash scripts that install, harden, customize, back up, and reset an n8n deployment running behind NGINX with Docker, Postgres, and Redis. A shared library (`n8n-lib.sh`) centralizes validation, UI, TLS, NGINX, Docker, hardening, and backup helpers so each script stays small and consistent.

---

## Components

### 1) Shared Library — `n8n-lib.sh`
- **UI:** colored output, spinners, progress bars, robust prompts.
- **Lock & state:** prevent concurrent runs; checkpoints for resumable installs.
- **Validation:** OS/distro, CPU/RAM/Disk, ports, DNS, Cloudflare detection.
- **TLS:** Let’s Encrypt bootstrap; Cloudflare Origin/AOP helpers.
- **NGINX:** write vhost, `nginx -t`, reload, inject HSTS/rate‑limits/Basic Auth.
- **System hardening:** UFW, fail2ban, SSH hardening, sysctl, logrotate, unattended‑upgrades.
- **Docker:** ensure Engine/Compose, bring up/down stacks safely.
- **Backups:** create/list/restore/prune.
- **Config:** reads `/etc/n8n-manager.conf`; fills sane defaults.
- **Logs:** `/var/lib/n8n-manager/logs/<timestamp>.log` with consistent exit codes.

### 2) Entrypoint — `n8n-manager.sh`
Menu + CLI router for non‑technical users.
- Menu: **Install**, **Reset**, **Customization**, **Security**, **Backup**.
- CLI flags for automation (install/reset/customize/security/backup).
- Sources `n8n-lib.sh` and `/etc/n8n-manager.conf`.

### 3) Installer — `n8n-install.sh`
Fresh, hardened install (resumable).
1. Reset old deployment.
2. System checks & confirm.
3. Inputs: `PUBLIC_IP`, `N8N_HOST`.
4. Detect DNS & choose TLS mode (CF vs Let’s Encrypt).
5. Base security (UFW/fail2ban/SSH/sysctl/logrotate/updates).
6. Docker Engine + Compose.
7. App setup: `.env` (keys/secrets) + `docker-compose.yml`.
8. Start stack: n8n (web+worker), Postgres, Redis.
9. NGINX + TLS (CF Origin/AOP or LE `certbot --nginx`).
10. Optional protections: Basic Auth; webhook rate‑limit.
11. Backups: schedule & retention.
12. Health checks & recap.

### 4) Reset — `n8n-reset.sh`
Safe clean uninstall. Stops/removes stack & volumes, removes NGINX site, clears state. Optional: remove images, TLS certs, backups.

### 5) Customization — `n8n-customize.sh`
Branding and subpath toggle.
- Prompts for Title/Meta/Logo/Favicon (or use defaults).
- Validates logo/favicon URLs; saves to static path.
- Landing page at `/` and n8n served under `/n8n/` (optional).
- Updates `.env` (`N8N_PATH`, `N8N_EDITOR_BASE_URL`, `WEBHOOK_URL`) and NGINX locations.
- Revert to defaults on demand.

### 6) Security — `n8n-security.sh`
Audit & apply hardening:
- SSH hardening; UFW; optional CF AOP & 443 lock; fail2ban; sysctl; NGINX HSTS/rate‑limits/Basic Auth; unattended‑upgrades.

### 7) Backups — `n8n-backup.sh`
Lifecycle: **status**, **run-now**, **configure HH:MM --retention N**, **restore /path/file.tar.gz**.

---

## Files & Paths

```
/usr/local/sbin/
  n8n-manager.sh
  n8n-lib.sh
  n8n-install.sh
  n8n-reset.sh
  n8n-customize.sh
  n8n-security.sh
  n8n-backup.sh

/etc/n8n-manager.conf       # Template lives in repo/config; real one edited on the host
/var/lib/n8n-manager/       # lock, state, logs/
/opt/n8n                    # docker-compose + .env + volumes
/etc/nginx/sites-available/n8n -> sites-enabled/n8n
/var/backups/n8n            # *.tar.gz + *.sha256
```

---

## Config Template (`/etc/n8n-manager.conf`)

Keep the template generic (no secrets). Example keys:
```bash
PUBLIC_IP="203.0.113.10"
N8N_HOST="n8n.example.com"
TLS_MODE="auto"                   # auto | cloudflare | lets-encrypt
TIMEZONE="America/New_York"

APP_DIR="/opt/n8n"
NGINX_SITE="/etc/nginx/sites-available/n8n"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/n8n"
CLOUDFLARE_SSL_DIR="/etc/ssl/cloudflare"

ENABLE_SUBPATH="yes"
SITE_TITLE="Ops Console"
SITE_META="Automation console."
SITE_STATIC_DIR="/var/www/n8n.example.com"

BACKUP_DIR="/var/backups/n8n"
BACKUP_CRON_TIME="03:17"
BACKUP_RETENTION="7"

ENABLE_RATE_LIMIT="yes"
ENABLE_BASIC_AUTH="no"
ENABLE_AOP="no"
LOCK_443_TO_CF="no"
```

---

## Development Tips

- Enforce **LF** line endings via `.gitattributes` and `git add --renormalize .` (Windows users).
- Run `shellcheck` locally (matches CI).
- Keep changes modular: enhance helpers in `n8n-lib.sh`, keep command scripts small.
- For releases, tag versions and pin bootstrap installs to tags for reproducibility.
