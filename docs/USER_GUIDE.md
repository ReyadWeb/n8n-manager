# n8n Manager — User Guide

This guide shows how to **install, operate, back up, customize, secure, and reset** an n8n server using the n8n Manager scripts. It’s written for non‑DevOps users.

---

## 1) Installation

### Option A — One‑liner (from your GitHub repo)
> Replace `ReyadWeb/n8n-manager` with your actual path if different.

```bash
curl -fsSL https://raw.githubusercontent.com/ReyadWeb/n8n-manager/main/tools/bootstrap-install.sh | sudo bash
sudo n8n-manager.sh
```

### Option B — Manual
1. Copy the config template:
   ```bash
   sudo install -m 644 config/n8n-manager.conf.example /etc/n8n-manager.conf
   sudoedit /etc/n8n-manager.conf
   ```
2. Install scripts:
   ```bash
   sudo install -m 755 scripts/*.sh /usr/local/sbin/
   ```
3. Launch:
   ```bash
   sudo n8n-manager.sh
   ```

**Requirements**
- Ubuntu 20.04+ with root access
- DNS A record for your hostname → server IP
- Port 80/443 reachable (for Let’s Encrypt)

---

## 2) Using the Main Menu

Run:
```bash
sudo n8n-manager.sh
```

Menu options:

1. **Install** – fresh, hardened setup (resumable)
2. **Reset** – safely uninstall/clean
3. **Customization** – title/meta/logo/favicon and optional `/n8n` subpath
4. **Security** – audit and apply hardening
5. **Backup** – status/run/configure/restore

**CLI (non‑interactive) examples**
```bash
# Install
sudo n8n-manager.sh --install --ip 1.2.3.4 --host n8n.example.com --force-letsencrypt --non-interactive

# Reset
sudo n8n-manager.sh --reset --yes

# Customize
sudo n8n-manager.sh --customize --title "Ops Console" --meta "Automation console"   --logo-url https://example.com/logo.png --favicon-url https://example.com/favicon.ico --enable-subpath

# Security
sudo n8n-manager.sh --security --apply-all

# Backups
sudo n8n-manager.sh --backup --status
sudo n8n-manager.sh --backup --run-now
sudo n8n-manager.sh --backup --configure 03:17 --retention 7
sudo n8n-manager.sh --backup --restore /var/backups/n8n/n8n-YYYYmmdd_HHMMSS.tar.gz
```

---

## 3) Customization (Branding & Subpath)

- Set **Title**, **Meta**, **Logo URL**, **Favicon URL**.
- Optionally enable **Subpath** so landing page serves at `/` and n8n runs under `/n8n/`.
- Revert to defaults anytime from the same menu.

---

## 4) Backups

- **Status**: list backups, sizes, SHA256, schedule.
- **Run now**: make a backup immediately.
- **Configure**: daily time (HH:MM, 24‑hour) and retention count.
- **Restore**: confirm and restore from a selected archive.

Backups live in: `/var/backups/n8n`.

---

## 5) Security

- Firewall (UFW 22/80/443), Fail2ban, SSH hardening
- HSTS, webhook rate‑limits, optional Basic Auth
- Optional Cloudflare: Authenticated Origin Pulls (mTLS) + lock 443 to CF IPs
- Unattended security updates

Run interactive audit:
```bash
sudo n8n-security.sh
```

---

## 6) Reset / Uninstall

Safe cleanup to a fresh state:
```bash
sudo n8n-manager.sh --reset
# or:
sudo n8n-reset.sh
```

You can keep backups and remove app data, NGINX site, and Docker stack.

---

## 7) Troubleshooting

- **Line endings on Windows**: ensure repo uses LF.
  ```bash
  git config --global core.autocrlf false
  git config --global core.eol lf
  git add --renormalize . && git commit -m "Normalize to LF"
  ```
- **TLS errors**: verify DNS → server IP, port 80/443 open, Cloudflare proxy mode matches your choice.
- **Docker won’t start**: check `docker ps -a`, inspect logs with `docker logs <service>`.
- **Health check**: `curl -I https://<host>/healthz` should return `200 OK` with TLS.

---

## 8) Where things live

- Config (user‑editable): `/etc/n8n-manager.conf`
- App stack: `/opt/n8n`
- NGINX: `/etc/nginx/sites-available/n8n` (linked to `sites-enabled`)
- State/logs: `/var/lib/n8n-manager/`
- Backups: `/var/backups/n8n`

---

## 9) Getting help

- Open a GitHub Issue: describe OS version, commands run, and include sanitized logs from `/var/lib/n8n-manager/logs`.
