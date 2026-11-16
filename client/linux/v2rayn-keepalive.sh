#!/usr/bin/env bash
#
# v2rayn-keepalive.sh — Non-disruptive v2rayN + Xray & Fail-Closed GNOME Proxy Watchdog
# -------------------------------------------------------------------------------------
# Key features:
#   1. Zero-traffic kernel socket table check (`ss -tlnH sport = :10808`) — does
#      not emit periodic heartbeat packets across the firewall.
#   2. Zero-Beaconing + Fail-Closed GNOME System Proxy Pinning (`gsettings`):
#      Unconditionally keeps `org.gnome.system.proxy` locked to `manual` ->
#      127.0.0.1:10808 (preserving any custom `ignore-hosts`) even if `xray` or
#      `v2rayN` restarts, preventing browsers and Electron/AI desktop apps from
#      silently falling back to direct domestic ISP connections.
#      - Pause enforcement : touch ~/.local/state/v2ray-proxy-watchdog.pause
#      - Resume enforcement: rm -f ~/.local/state/v2ray-proxy-watchdog.pause
#   3. Active AI coding session protection: if an active Claude Code session is
#      detected, defers disruptive GUI restarts to avoid ECONNRESET stream drops.
#

set -u

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-10808}"
PAUSE_FLAG="${PAUSE_FLAG:-$HOME/.local/state/v2ray-proxy-watchdog.pause}"
DEFAULT_IGNORE_HOSTS="['localhost', '127.0.0.1', '::1', '192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12', '100.64.0.0/10', '*.local', '*.ts.net']"
LOG="$HOME/.local/logs/v2rayn-keepalive.log"
mkdir -p "$(dirname "$LOG")"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

log() { echo "[keepalive $(date '+%F %T')] $1" >> "$LOG"; }
launch_gui() { (export DISPLAY="${DISPLAY:-:1}"; nohup /opt/v2rayN/v2rayN >/dev/null 2>&1 &); }

claude_active() {
  if pgrep -f "ccd-cli|claude" >/dev/null 2>&1; then
    if find "$HOME/.claude/projects" -name "*.jsonl" -mmin -5 2>/dev/null | grep -q .; then
      return 0
    fi
    if ss -tn 2>/dev/null | grep -q "${PROXY_HOST}:${PROXY_PORT}"; then
      return 0
    fi
  fi
  return 1
}

ensure_gnome_proxy() {
  [ ! -f "$PAUSE_FLAG" ] || return 0
  command -v gsettings >/dev/null 2>&1 || return 0
  [ -S "${XDG_RUNTIME_DIR}/bus" ] || return 0

  local mode http_host http_port https_host https_port socks_host socks_port ignore_hosts
  mode="$(gsettings get org.gnome.system.proxy mode 2>/dev/null || true)"
  [ -n "$mode" ] || return 0

  http_host="$(gsettings get org.gnome.system.proxy.http host 2>/dev/null || true)"
  http_port="$(gsettings get org.gnome.system.proxy.http port 2>/dev/null || true)"
  https_host="$(gsettings get org.gnome.system.proxy.https host 2>/dev/null || true)"
  https_port="$(gsettings get org.gnome.system.proxy.https port 2>/dev/null || true)"
  socks_host="$(gsettings get org.gnome.system.proxy.socks host 2>/dev/null || true)"
  socks_port="$(gsettings get org.gnome.system.proxy.socks port 2>/dev/null || true)"

  if [ "$mode" != "'manual'" ] \
    || [ "$http_host" != "'${PROXY_HOST}'" ] || [ "$http_port" != "$PROXY_PORT" ] \
    || [ "$https_host" != "'${PROXY_HOST}'" ] || [ "$https_port" != "$PROXY_PORT" ] \
    || [ "$socks_host" != "'${PROXY_HOST}'" ] || [ "$socks_port" != "$PROXY_PORT" ]; then
    gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null || return 0
    gsettings set org.gnome.system.proxy use-same-proxy true 2>/dev/null || true
    gsettings set org.gnome.system.proxy.http enabled true 2>/dev/null || true
    gsettings set org.gnome.system.proxy.http host "$PROXY_HOST" 2>/dev/null || true
    gsettings set org.gnome.system.proxy.http port "$PROXY_PORT" 2>/dev/null || true
    gsettings set org.gnome.system.proxy.https host "$PROXY_HOST" 2>/dev/null || true
    gsettings set org.gnome.system.proxy.https port "$PROXY_PORT" 2>/dev/null || true
    gsettings set org.gnome.system.proxy.socks host "$PROXY_HOST" 2>/dev/null || true
    gsettings set org.gnome.system.proxy.socks port "$PROXY_PORT" 2>/dev/null || true

    ignore_hosts="$(gsettings get org.gnome.system.proxy ignore-hosts 2>/dev/null || true)"
    if [ "$ignore_hosts" = "@as []" ] || [ "$ignore_hosts" = "[]" ] || [ "$ignore_hosts" = "['localhost', '127.0.0.0/8', '::1']" ]; then
      gsettings set org.gnome.system.proxy ignore-hosts "$DEFAULT_IGNORE_HOSTS" 2>/dev/null || true
    fi

    log "Restored GNOME system proxy -> ${PROXY_HOST}:${PROXY_PORT} (fail-closed)"
  fi
}

FAILED_PROBES=0

while true; do
  ensure_gnome_proxy

  PORT_UP=0
  if ss -tlnH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q "${PROXY_PORT}"; then
    PORT_UP=1
  fi

  XRAY_PID="$(pgrep -x xray 2>/dev/null | head -n 1 || true)"
  GUI_PID="$(pgrep -f '/opt/v2rayN/v2rayN' 2>/dev/null | head -n 1 || true)"

  if [ "$PORT_UP" -eq 1 ] && [ -n "$XRAY_PID" ]; then
    FAILED_PROBES=0
  else
    ((FAILED_PROBES++))
    log "Warning: proxy check failed (port_up=$PORT_UP, xray_pid=$XRAY_PID, fail_count=$FAILED_PROBES)"

    if [ "$FAILED_PROBES" -ge 3 ]; then
      if claude_active; then
        log "Deferring restart: active Claude Code session detected"
        FAILED_PROBES=2
      else
        FAILED_PROBES=0
        if [ -z "$GUI_PID" ]; then
          log "v2rayN GUI not running -> launching GUI"
          launch_gui
          sleep 15
        elif [ -z "$XRAY_PID" ] || [ "$PORT_UP" -eq 0 ]; then
          log "Xray core down while GUI present -> gracefully restarting GUI"
          kill -TERM "$GUI_PID" 2>/dev/null || true
          sleep 2
          launch_gui
          sleep 20
        fi
      fi
    fi
  fi

  if [ "$PORT_UP" -eq 1 ] && [ -n "$XRAY_PID" ] && [ -z "$GUI_PID" ]; then
    log "Xray active but GUI down -> relaunching GUI without disturbing Xray"
    launch_gui
    sleep 10
  fi

  sleep 10
done
