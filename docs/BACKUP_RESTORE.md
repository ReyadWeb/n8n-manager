# Backups & Restore

**Run a backup now**
```bash
sudo n8n-backup.sh --run-now
```

**Configure schedule (daily at 03:17, keep 7)**
```bash
sudo n8n-backup.sh --configure 03:17 --retention 7
```

**Restore**
```bash
sudo n8n-backup.sh --restore /var/backups/n8n/n8n-YYYYmmdd_HHMMSS.tar.gz
```
Checksums (`.sha256`) are verified when present.
