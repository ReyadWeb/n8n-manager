# Team Guide: Operating n8n Manager

This doc gives non-DevOps teammates a quick overview of **how to use n8n Manager** safely.

## Daily tasks
- **Check health:** open `https://<your-host>/healthz` — `200 OK` means the gateway is up.
- **Backup status:** `sudo n8n-backup.sh --status` (lists backups and schedule)
- **Security audit:** `sudo n8n-security.sh` (prints report; choose Y/N per fix)

## Common operations
### Fresh install
```bash
sudo n8n-manager.sh   # choose: 1) Install
```
What it does: resets old installs, sets Docker + Postgres + Redis + n8n, configures NGINX + TLS, hardens the OS, offers backups.

### Reset (safe uninstall)
```bash
sudo n8n-manager.sh   # choose: 2) Reset
```

### Customize branding / subpath
```bash
sudo n8n-manager.sh   # choose: 3) Customization
```
- Title & Meta for landing page
- Logo & Favicon (optional URLs)
- Subpath `/n8n` mode (landing at `/`) or serve n8n at `/`

### Security
```bash
sudo n8n-manager.sh   # choose: 4) Security
```
- Firewall, SSH, HSTS, webhook rate-limit, optional Basic Auth
- Optional Cloudflare AOP & 443 lock

### Backups
```bash
sudo n8n-manager.sh   # choose: 5) Backup
```
- Status / Run now / Configure daily time / Restore

## When to call for help
- TLS errors (certificate paths, Let’s Encrypt rate limits)
- Docker failing to start containers repeatedly
- Low disk (< 10GB free) or OOM (memory) issues
