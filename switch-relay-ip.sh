#!/usr/bin/env bash
#
# switch-relay-ip.sh — Zero-downtime client helper to rotate Entry Relay IP/SNI
# -----------------------------------------------------------------------------
# When you replace an Entry Relay VPS with a new IP, you do NOT need to touch
# the Fixed-Exit VPS or regenerate keys. Run this script on your client machine
# (macOS or Linux with v2rayN) to update both v2rayN's SQLite database
# (guiNDB.db) and active Xray config.json, then hot-reload Xray in <200ms.
#
# Usage:
#   bash switch-relay-ip.sh <NEW_RELAY_IP> [NEW_SNI]
#
# Example:
#   bash switch-relay-ip.sh 198.51.100.10 d1.awsstatic.com
# -----------------------------------------------------------------------------

set -euo pipefail

NEW_IP="${1:-}"
NEW_SNI="${2:-}"

[ -n "$NEW_IP" ] || { echo "Usage: bash $0 <NEW_RELAY_IP> [NEW_SNI]"; exit 1; }

if [ "$(uname -s)" = "Darwin" ]; then
  V2RAYN_DIR="$HOME/Library/Application Support/v2rayN"
else
  V2RAYN_DIR="$HOME/.local/share/v2rayN"
fi

DB_FILE="$V2RAYN_DIR/guiConfigs/guiNDB.db"
GUI_CFG="$V2RAYN_DIR/guiConfigs/guiNConfig.json"
BIN_CFG="$V2RAYN_DIR/binConfigs/config.json"
XRAY_BIN="$V2RAYN_DIR/bin/xray/xray"
ASSET_DIR="$V2RAYN_DIR/bin"

[ -f "$DB_FILE" ] || { echo "[x] v2rayN database not found at: $DB_FILE"; exit 1; }
[ -f "$BIN_CFG" ] || { echo "[x] Active Xray config not found at: $BIN_CFG"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
cp "$DB_FILE" "${DB_FILE}.bak-${TS}"
cp "$BIN_CFG" "${BIN_CFG}.bak-${TS}"
[ -f "$GUI_CFG" ] && cp "$GUI_CFG" "${GUI_CFG}.bak-${TS}"

python3 - "$DB_FILE" "$GUI_CFG" "$BIN_CFG" "$NEW_IP" "$NEW_SNI" << 'PY'
import json, os, sqlite3, sys

db_file, gui_cfg, bin_cfg, new_ip, new_sni = sys.argv[1:6]

conn = sqlite3.connect(db_file)
if new_sni:
    conn.execute(
        "UPDATE ProfileItem SET address = ?, remarks = ?, sni = ? WHERE streamSecurity = 'reality'",
        (new_ip, f"Reality-Relay-{new_ip}", new_sni),
    )
else:
    conn.execute(
        "UPDATE ProfileItem SET address = ?, remarks = ? WHERE streamSecurity = 'reality'",
        (new_ip, f"Reality-Relay-{new_ip}"),
    )
conn.commit()
print("[+] Updated guiNDB.db:", conn.execute("SELECT remarks, address, port, sni FROM ProfileItem").fetchall())
conn.close()

if os.path.exists(gui_cfg):
    with open(gui_cfg, "r", encoding="utf-8") as f:
        g = json.load(f)
    if "CoreBasicItem" in g:
        g["CoreBasicItem"]["EnableFragment"] = False
    with open(gui_cfg, "w", encoding="utf-8") as f:
        json.dump(g, f, indent=2, ensure_ascii=False)

with open(bin_cfg, "r", encoding="utf-8") as f:
    b = json.load(f)

for ob in b.get("outbounds", []):
    if ob.get("tag") == "proxy":
        settings = ob.get("settings", {})
        if "address" in settings:
            settings["address"] = new_ip
        for vn in settings.get("vnext", []):
            vn["address"] = new_ip
        st = ob.get("streamSettings", {})
        if new_sni and "realitySettings" in st:
            st["realitySettings"]["serverName"] = new_sni
        if "finalmask" in st:
            del st["finalmask"]

with open(bin_cfg, "w", encoding="utf-8") as f:
    json.dump(b, f, indent=2, ensure_ascii=False)
print("[+] Updated binConfigs/config.json")
PY

XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$BIN_CFG" >/dev/null
OLD_PID="$(pgrep -x xray || true)"
if [ -n "$OLD_PID" ]; then
  kill -TERM $OLD_PID 2>/dev/null || true
  sleep 0.2
fi

(
  cd "$V2RAYN_DIR/binConfigs"
  XRAY_LOCATION_ASSET="$ASSET_DIR" nohup "$XRAY_BIN" run -c config.json </dev/null >/dev/null 2>&1 &
)
sleep 1
echo "[+] Verifying proxy connectivity..."
curl -s -m 6 -x http://127.0.0.1:10808 -o /dev/null -w "[+] HTTP 204 check: %{http_code}\n" https://www.gstatic.com/generate_204
echo -n "[+] Current Fixed Egress IP: "
curl -s -m 6 -x http://127.0.0.1:10808 https://ip.me
echo
