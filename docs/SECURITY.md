# Security Notes

- SSH hardening (no root login, no password auth)
- UFW (22/80/443) + Fail2ban (nginx jail)
- HSTS, optional Basic Auth, webhook rate-limits
- Optional Cloudflare: Authenticated Origin Pulls + 443 lock
- Automated security updates (`unattended-upgrades`)

Re-run anytime:
```bash
sudo n8n-security.sh
```
