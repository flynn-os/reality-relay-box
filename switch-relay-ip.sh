#!/usr/bin/env bash
#
# switch-relay-ip.sh — Client helper to rotate Entry Relay IP/SNI safely
# -----------------------------------------------------------------------------
# When you replace an Entry Relay VPS IP (or swap its Static IP), you do NOT
# need to touch the Fixed-Exit VPS or regenerate any credentials. Run this
# script on your client machine (macOS or Linux with v2rayN) to update v2rayN's
# SQLite database (guiNDB.db), active Xray config.json, and any hot-transition
# config (~/.local/state/reality-relay-hot/xray-nofrag-10809.json) with strict
# 0600 secret permissions.
#
# Stream Safety Note:
#   Restarting local `xray` terminates established TCP streams on 127.0.0.1:10808.
#   - Emergency rotation (old Entry IP is already blocked): restarting is safe
#     because old streams are already dead.
#   - Preventive rotation during active long-running AI sessions: wait until
#     streams are idle, or use a dual-port hot cutover (10808 -> 10809). If a
#     dual-core hot transition (multiple `xray` PIDs or `xray-nofrag-10809.json`)
#     is detected, this script updates configs on disk and skips killing `xray`
#     unless `--force-restart` is explicitly passed.
#
# Usage:
#   bash switch-relay-ip.sh [--force-restart] <NEW_RELAY_IP> [NEW_SNI]
#
# Example:
#   bash switch-relay-ip.sh 198.51.100.99 d1.awsstatic.com
# -----------------------------------------------------------------------------

set -euo pipefail
umask 077

FORCE_RESTART=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --force-restart)
      FORCE_RESTART=1
      ;;
    -h|--help)
      echo "Usage: bash $0 [--force-restart] <NEW_RELAY_IP> [NEW_SNI]"
      exit 0
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

NEW_IP="${POSITIONAL[0]:-}"
NEW_SNI="${POSITIONAL[1]:-}"

[ -n "$NEW_IP" ] || { echo "Usage: bash $0 [--force-restart] <NEW_RELAY_IP> [NEW_SNI]"; exit 1; }

if [ "$(uname -s)" = "Darwin" ]; then
  V2RAYN_DIR="$HOME/Library/Application Support/v2rayN"
else
  V2RAYN_DIR="$HOME/.local/share/v2rayN"
fi

DB_FILE="$V2RAYN_DIR/guiConfigs/guiNDB.db"
GUI_CFG="$V2RAYN_DIR/guiConfigs/guiNConfig.json"
BIN_CFG="$V2RAYN_DIR/binConfigs/config.json"
HOT_CFG="$HOME/.local/state/reality-relay-hot/xray-nofrag-10809.json"
XRAY_BIN="$V2RAYN_DIR/bin/xray/xray"
ASSET_DIR="$V2RAYN_DIR/bin"

[ -f "$DB_FILE" ] || { echo "[x] v2rayN database not found at: $DB_FILE"; exit 1; }
[ -f "$BIN_CFG" ] || { echo "[x] Active Xray config not found at: $BIN_CFG"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
cp "$DB_FILE" "${DB_FILE}.bak-${TS}" && chmod 600 "${DB_FILE}.bak-${TS}"
cp "$BIN_CFG" "${BIN_CFG}.bak-${TS}" && chmod 600 "${BIN_CFG}.bak-${TS}"
if [ -f "$GUI_CFG" ]; then
  cp "$GUI_CFG" "${GUI_CFG}.bak-${TS}" && chmod 600 "${GUI_CFG}.bak-${TS}"
fi
if [ -f "$HOT_CFG" ]; then
  cp "$HOT_CFG" "${HOT_CFG}.bak-${TS}" && chmod 600 "${HOT_CFG}.bak-${TS}"
fi

python3 - "$DB_FILE" "$GUI_CFG" "$BIN_CFG" "$HOT_CFG" "$NEW_IP" "$NEW_SNI" << 'PY'
import json, os, sqlite3, sys

db_file, gui_cfg, bin_cfg, hot_cfg, new_ip, new_sni = sys.argv[1:7]

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
os.chmod(db_file, 0o600)

if os.path.exists(gui_cfg):
    with open(gui_cfg, "r", encoding="utf-8") as f:
        g = json.load(f)
    if "CoreBasicItem" in g:
        g["CoreBasicItem"]["EnableFragment"] = False
    with open(gui_cfg, "w", encoding="utf-8") as f:
        json.dump(g, f, indent=2, ensure_ascii=False)
    os.chmod(gui_cfg, 0o600)

def update_xray_cfg(cfg_path):
    with open(cfg_path, "r", encoding="utf-8") as f:
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
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(b, f, indent=2, ensure_ascii=False)
    os.chmod(cfg_path, 0o600)

update_xray_cfg(bin_cfg)
print("[+] Updated binConfigs/config.json (0600)")

if os.path.exists(hot_cfg):
    update_xray_cfg(hot_cfg)
    print(f"[+] Updated hot-transition config {hot_cfg} (0600)")
PY

XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$BIN_CFG" >/dev/null
if [ -f "$HOT_CFG" ]; then
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$HOT_CFG" >/dev/null
fi

PID_LIST="$(pgrep -x xray || true)"
PID_COUNT="$(printf '%s\n' "$PID_LIST" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

if { [ "$PID_COUNT" -gt 1 ] || [ -f "$HOT_CFG" ]; } && [ "$FORCE_RESTART" -ne 1 ]; then
  echo "[!] Active dual-core hot-transition detected (xray PIDs=${PID_COUNT}, hot_cfg=$([ -f "$HOT_CFG" ] && echo present || echo absent))."
  echo "[!] Updated configs on disk (0600) WITHOUT killing active xray cores to preserve established sessions."
  echo "[!] Re-run with --force-restart only if you intentionally want to terminate and restart local xray."
  exit 0
fi

if [ -n "$PID_LIST" ]; then
  # shellcheck disable=SC2086
  kill -TERM $PID_LIST 2>/dev/null || true
  sleep 0.2
fi

(
  cd "$V2RAYN_DIR/binConfigs"
  XRAY_LOCATION_ASSET="$ASSET_DIR" nohup "$XRAY_BIN" run -c config.json </dev/null >/dev/null 2>&1 &
)
sleep 1
echo "[+] Verifying proxy connectivity via 127.0.0.1:10808..."
curl -s -m 6 -x http://127.0.0.1:10808 -o /dev/null -w "[+] HTTP 204 check: %{http_code}\n" https://www.gstatic.com/generate_204
echo -n "[+] Current Fixed Egress IP: "
curl -s -m 6 -x http://127.0.0.1:10808 https://ip.me
echo
