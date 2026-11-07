#!/usr/bin/env bash
#
# v2rayn-keepalive.sh — Non-disruptive v2rayN + Xray watchdog for Linux dev machines
# ----------------------------------------------------------------------------------
# Key features:
#   1. Zero-traffic kernel socket table check (`ss -tlnH sport = :10808`) — does
#      not emit periodic heartbeat packets across the firewall.
#   2. Active AI coding session protection: if an active Claude Code session is
#      detected, defers disruptive GUI restarts to avoid ECONNRESET stream drops.
#

set -u

PROXY_PORT="${PROXY_PORT:-10808}"
LOG="$HOME/.local/logs/v2rayn-keepalive.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[keepalive $(date '+%F %T')] $1" >> "$LOG"; }
launch_gui() { (export DISPLAY="${DISPLAY:-:1}"; nohup /opt/v2rayN/v2rayN >/dev/null 2>&1 &); }

claude_active() {
  if pgrep -f "claude" >/dev/null 2>&1; then
    if find "$HOME/.claude/projects" -name "*.jsonl" -mmin -5 2>/dev/null | grep -q .; then
      return 0
    fi
    if ss -tn 2>/dev/null | grep -q "127.0.0.1:${PROXY_PORT}"; then
      return 0
    fi
  fi
  return 1
}

FAILED_PROBES=0

while true; do
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
