# n8n Manager (Installer + Security + Backups + Customization)

Production-ready scripts to install, harden, customize, back up, and reset **n8n** on Ubuntu using Docker, NGINX, Postgres, and Redis.

## Features
- Fresh, hardened install (Docker, Postgres, Redis, NGINX, TLS)
- Cloudflare **or** Let’s Encrypt TLS
- One-command **Reset**
- **Customization**: title, meta, logo, favicon, subpath `/n8n` (optional landing at `/`)
- **Security**: firewall, fail2ban, HSTS, webhook rate-limits, optional Basic Auth, optional Cloudflare AOP & 443 lock
- **Backups**: nightly cron, SHA256 checks, easy restore

## Quick Start (manual)
```bash
# 1) Put config in place (edit values first)
sudo install -m 644 config/n8n-manager.conf.example /etc/n8n-manager.conf

# 2) Install scripts
sudo install -m 755 scripts/*.sh /usr/local/sbin/

# 3) Launch
sudo n8n-manager.sh
```

## Quick Start (one-liner bootstrap)
Replace `<YOUR_ORG>` and `<YOUR_REPO>` with your GitHub path.

```bash
curl -fsSL https://raw.githubusercontent.com/ReyadWeb/n8n-manager//main/tools/bootstrap-install.sh | sudo bash
```

or

```bash
wget -qO- https://raw.githubusercontent.com/ReyadWeb/n8n-manager/main/tools/bootstrap-install.sh | sudo bash
```

## Files installed
- `/usr/local/sbin/n8n-manager.sh` – main menu
- `/usr/local/sbin/n8n-install.sh` – fresh hardened install (resumable)
- `/usr/local/sbin/n8n-reset.sh` – clean uninstall/reset
- `/usr/local/sbin/n8n-customize.sh` – branding & subpath
- `/usr/local/sbin/n8n-security.sh` – security audit & hardening
- `/usr/local/sbin/n8n-backup.sh` – backup manager

## Requirements
- Ubuntu 20.04+ (root access)
- DNS A/Proxy configured for your hostname

## Docs
- [docs/QUICKSTART.md](docs/QUICKSTART.md)
- [docs/SECURITY.md](docs/SECURITY.md)
- [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md)
- [TEAM_GUIDE.md](TEAM_GUIDE.md)

## License
MIT — see [LICENSE](LICENSE).
