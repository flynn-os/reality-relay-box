#!/usr/bin/env bash
#
# uninstall.sh — Cleanly remove Xray (Exit VPS) or HAProxy relay config (Relay VPS)
# Run as root: sudo bash uninstall.sh
#
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo bash $0"; exit 1; }

if command -v xray >/dev/null 2>&1; then
  echo "[*] Removing Xray-core and configuration..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -f /root/reality-client.txt
  rm -rf /usr/local/etc/xray
  echo "[+] Xray removed."
fi

if systemctl is-active --quiet haproxy 2>/dev/null; then
  echo "[*] Stopping and disabling HAProxy service..."
  systemctl stop haproxy || true
  systemctl disable haproxy || true
  echo "[+] HAProxy stopped."
fi

echo "[+] Done."
