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
#     streams are idle, or use a dual-port hot cutover (10808 -> 10809). If an
#     active dual-core transition (multiple running `xray` PIDs) is detected,
#     this script updates configs on disk and skips killing `xray` unless
#     `--force-restart` is explicitly passed.
#
# Usage:
#   bash switch-relay-ip.sh [--force-restart | --no-restart] <NEW_RELAY_IP> [NEW_SNI]
#
# Example:
#   bash switch-relay-ip.sh 198.51.100.99 cognito-idp.ap-northeast-1.amazonaws.com
# -----------------------------------------------------------------------------

set -euo pipefail
umask 077

FORCE_RESTART=0
NO_RESTART=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --force-restart)
      FORCE_RESTART=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    -h|--help)
      echo "Usage: bash $0 [--force-restart | --no-restart] <NEW_RELAY_IP> [NEW_SNI]"
      exit 0
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

NEW_IP="${POSITIONAL[0]:-}"
NEW_SNI="${POSITIONAL[1]:-}"

[ -n "$NEW_IP" ] || { echo "Usage: bash $0 [--force-restart | --no-restart] <NEW_RELAY_IP> [NEW_SNI]"; exit 1; }

if [ "$(uname -s)" = "Darwin" ]; then
  V2RAYN_DIR="$HOME/Library/Application Support/v2rayN"
else
  V2RAYN_DIR="$HOME/.local/share/v2rayN"
fi

DB_FILE="$V2RAYN_DIR/guiConfigs/guiNDB.db"
GUI_CFG="$V2RAYN_DIR/guiConfigs/guiNConfig.json"
BIN_CFG="$V2RAYN_DIR/binConfigs/config.json"
HOT_CFG="$HOME/.local/state/reality-relay-hot/xray-nofrag-10809.json"
HOT_XHTTP_CFG="$HOME/.local/state/reality-xhttp-hot/xray-xhttp-10810.json"
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
if [ -f "$HOT_XHTTP_CFG" ]; then
  cp "$HOT_XHTTP_CFG" "${HOT_XHTTP_CFG}.bak-${TS}" && chmod 600 "${HOT_XHTTP_CFG}.bak-${TS}"
fi

python3 - "$DB_FILE" "$GUI_CFG" "$BIN_CFG" "$HOT_CFG" "$HOT_XHTTP_CFG" "$NEW_IP" "$NEW_SNI" << 'PY'
import json, os, sqlite3, sys

db_file, gui_cfg, bin_cfg, hot_cfg, hot_xhttp_cfg, new_ip, new_sni = sys.argv[1:8]

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
print("[+] Updated guiNDB.db:", conn.execute("SELECT remarks, address, port, sni, network FROM ProfileItem").fetchall())
conn.close()
os.chmod(db_file, 0o600)

if os.path.exists(gui_cfg):
    with open(gui_cfg, "r", encoding="utf-8") as f:
        g = json.load(f)
    if "CoreBasicItem" in g:
        g["CoreBasicItem"]["EnableFragment"] = False
    sp = g.get("SystemProxyItem")
    if isinstance(sp, dict) and sp.get("SystemProxyExceptions") is not None:
        cur = [x.strip() for x in str(sp.get("SystemProxyExceptions") or "").split(",") if x.strip()]
        for item in (
            "dingtalk.com",
            "*.dingtalk.com",
            "*.dingtalkapps.com",
            "*.alibabainc.com",
            "*.alicdn.com",
            "*.aliyuncs.com",
        ):
            if item not in cur:
                cur.append(item)
        sp["SystemProxyExceptions"] = ",".join(cur)
    with open(gui_cfg, "w", encoding="utf-8") as f:
        json.dump(g, f, indent=2, ensure_ascii=False)
    os.chmod(gui_cfg, 0o600)

def update_xray_cfg(cfg_path):
    with open(cfg_path, "r", encoding="utf-8") as f:
        b = json.load(f)
    for ob in b.get("outbounds", []):
        if ob.get("tag") == "proxy":
            settings = ob.get("settings", {})
            st = ob.get("streamSettings", {})
            is_xhttp = st.get("network") == "xhttp"
            if "address" in settings:
                settings["address"] = new_ip
            if is_xhttp:
                settings.pop("flow", None)
            for vn in settings.get("vnext", []):
                vn["address"] = new_ip
                if is_xhttp:
                    vn.pop("flow", None)
                    for u in vn.get("users", []):
                        u.pop("flow", None)
            if new_sni and "realitySettings" in st:
                st["realitySettings"]["serverName"] = new_sni
            if "finalmask" in st:
                del st["finalmask"]
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(b, f, indent=2, ensure_ascii=False)
    os.chmod(cfg_path, 0o600)

update_xray_cfg(bin_cfg)
print("[+] Updated binConfigs/config.json (0600)")

for extra_cfg in (hot_cfg, hot_xhttp_cfg):
    if os.path.exists(extra_cfg):
        update_xray_cfg(extra_cfg)
        print(f"[+] Updated hot-transition config {extra_cfg} (0600)")
PY

XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$BIN_CFG" >/dev/null
if [ -f "$HOT_CFG" ]; then
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$HOT_CFG" >/dev/null
fi
if [ -f "$HOT_XHTTP_CFG" ]; then
  XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$HOT_XHTTP_CFG" >/dev/null
fi

if [ "$NO_RESTART" -eq 1 ]; then
  echo "[+] Updated configs on disk (0600) without restarting xray (--no-restart)."
  exit 0
fi

PID_LIST="$(pgrep -x xray || true)"
PID_COUNT="$(printf '%s\n' "$PID_LIST" | sed '/^$/d' | wc -l | tr -d '[:space:]')"

if [ "$PID_COUNT" -gt 1 ] && [ "$FORCE_RESTART" -ne 1 ]; then
  echo "[!] Active dual-core hot-transition detected (xray PIDs=${PID_COUNT})."
  echo "[!] Updated configs on disk (0600) WITHOUT killing active xray cores to preserve established sessions."
  echo "[!] Re-run with --force-restart only if you intentionally want to terminate and restart local xray."
  exit 0
fi

spawn_detached_xray() {
  local cfg="$1"
  python3 - "$XRAY_BIN" "$ASSET_DIR" "$V2RAYN_DIR/binConfigs" "$cfg" <<'PY'
import os, subprocess, sys
xray_bin, asset_dir, work_dir, cfg_path = sys.argv[1:5]
env = os.environ.copy()
env["XRAY_LOCATION_ASSET"] = asset_dir
p = subprocess.Popen(
    [xray_bin, "run", "-c", cfg_path],
    cwd=work_dir,
    env=env,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
print(p.pid)
PY
}

OLD_PIDS_SPACE=" $(printf '%s' "$PID_LIST" | tr '\n' ' ') "

if [ "$(uname -s)" = "Darwin" ] && [ -d "/Applications/v2rayN.app" ]; then
  GUARD_CFG="$V2RAYN_DIR/binConfigs/.config.guard.json"
  cp "$BIN_CFG" "$GUARD_CFG"
  chmod 600 "$GUARD_CFG"
  GUARD_PID="$(spawn_detached_xray "$GUARD_CFG")"
  sleep 0.5

  launchctl kickstart -k "gui/$(id -u)/com.fei.v2ray-keepalive" >/dev/null 2>&1 || true
  osascript -e 'tell application "v2rayN" to quit' >/dev/null 2>&1 || pkill -x v2rayN 2>/dev/null || true
  for old_pid in $PID_LIST; do
    kill -TERM "$old_pid" 2>/dev/null || true
  done
  sleep 0.5

  open -a v2rayN
  NEW_V2RAYN_XRAY=""
  for _ in $(seq 1 20); do
    for cand in $(lsof -nP -t -iTCP:10808 -sTCP:LISTEN 2>/dev/null || true); do
      if [ "$cand" != "$GUARD_PID" ] && [ "${OLD_PIDS_SPACE#* $cand }" = "$OLD_PIDS_SPACE" ]; then
        NEW_V2RAYN_XRAY="$cand"
        break
      fi
    done
    [ -n "$NEW_V2RAYN_XRAY" ] && break
    sleep 0.5
  done

  if [ -n "$NEW_V2RAYN_XRAY" ]; then
    kill -TERM "$GUARD_PID" 2>/dev/null || true
    rm -f "$GUARD_CFG"
    chmod 600 "$BIN_CFG" 2>/dev/null || true
  else
    echo "[!] v2rayN did not spawn a new xray listener within 10s; keeping detached guard PID ${GUARD_PID} active on :10808." >&2
  fi
else
  NEW_XRAY_PID="$(spawn_detached_xray "$BIN_CFG")"
  sleep 0.4
  for old_pid in $PID_LIST; do
    if [ "$old_pid" != "$NEW_XRAY_PID" ]; then
      kill -TERM "$old_pid" 2>/dev/null || true
    fi
  done
  rm -f "$V2RAYN_DIR/binConfigs/.config.guard.json"
fi

sleep 1
echo "[+] Verifying proxy connectivity via 127.0.0.1:10808..."
curl -s -m 6 -x http://127.0.0.1:10808 -o /dev/null -w "[+] HTTP 204 check: %{http_code}\n" https://www.gstatic.com/generate_204 || echo "[!] HTTP 204 check failed"
echo -n "[+] Current Fixed Egress IP: "
curl -s -m 6 -x http://127.0.0.1:10808 https://ip.me || echo "ERR"
echo
