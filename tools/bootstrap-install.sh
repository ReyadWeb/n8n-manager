#!/usr/bin/env bash
set -euo pipefail
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/ReyadWeb/n8n-manager/main}"

echo "[n8n-manager bootstrap] Installing config template..."
sudo mkdir -p /etc
curl -fsSL "$REPO_RAW/config/n8n-manager.conf.example" | sudo tee /etc/n8n-manager.conf >/dev/null

echo "[n8n-manager bootstrap] Installing scripts..."
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
for f in n8n-lib.sh n8n-manager.sh n8n-install.sh n8n-reset.sh n8n-customize.sh n8n-security.sh n8n-backup.sh; do
  curl -fsSL "$REPO_RAW/scripts/$f" -o "$tmpdir/$f"
  sudo install -m 755 "$tmpdir/$f" /usr/local/sbin/
done

echo "[n8n-manager bootstrap] Done. Launch with: sudo n8n-manager.sh"
