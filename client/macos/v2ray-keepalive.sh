#!/bin/zsh
#
# v2ray-keepalive.sh — Keep v2rayN GUI + Xray core alive on macOS
# ---------------------------------------------------------------
# 1. If v2rayN GUI is not running -> clean up orphan Xray core and relaunch v2rayN.
# 2. If GUI is alive but local port 10808 is down -> gracefully restart v2rayN
#    (with a 5-minute cooldown to avoid thrashing on bad configs).
#

set -u

PROXY_PORT="${PROXY_PORT:-10808}"
LOGFILE="$HOME/Library/Logs/v2ray-keepalive.log"
log() { echo "[keepalive $(date '+%F %T')] $1" >> "$LOGFILE"; }

while true; do
  if ! pgrep -x v2rayN >/dev/null 2>&1; then
    log "v2rayN not running -> killing orphan core and relaunching GUI"
    pkill -x xray 2>/dev/null
    open -a v2rayN
    sleep 30
  elif ! nc -z -G 2 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; then
    log "GUI alive but core ($PROXY_PORT) down -> restarting v2rayN to rebuild core"
    osascript -e 'tell application "v2rayN" to quit' 2>/dev/null
    sleep 3
    pkill -x xray 2>/dev/null
    open -a v2rayN
    sleep 300
  else
    sleep 20
  fi
done
