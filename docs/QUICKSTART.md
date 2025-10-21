# Quickstart

1. Clone or download this repo.
2. Copy config template and edit:
   ```bash
   sudo install -m 644 config/n8n-manager.conf.example /etc/n8n-manager.conf
   sudoedit /etc/n8n-manager.conf
   ```
3. Install scripts:
   ```bash
   sudo install -m 755 scripts/*.sh /usr/local/sbin/
   ```
4. Run:
   ```bash
   sudo n8n-manager.sh
   ```

**Cloudflare users**  
- Choose Cloudflare TLS mode and paste Origin cert/key into `/etc/ssl/cloudflare/<host>.origin.{crt,key}`  
- Then `sudo nginx -t && sudo systemctl reload nginx`

**Let’s Encrypt users**  
- Ensure port 80 is open and A record points to your server.
