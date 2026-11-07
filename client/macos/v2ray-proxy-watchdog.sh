#!/bin/zsh
#
# v2ray-proxy-watchdog.sh — Zero-Beaconing macOS System Proxy Watchdog
# --------------------------------------------------------------------
# Keeps macOS System Proxy pointed to v2rayN (127.0.0.1:10808) when other
# network clients overwrite system proxy settings.
#
# Anti-Blocking Design (Zero-Beaconing):
#   Instead of probing an external URL over the proxy every 10 seconds (which
#   generates 8,640 fixed-interval TLS handshakes per day across the firewall),
#   this script first performs a pure local check (`proxy_ok`) with ZERO network
#   traffic. It only performs an outbound connectivity check (`is_proxy_healthy`)
#   when the macOS system proxy has actually been turned off and needs restoration.
#

set -u

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-10808}"
SERVICE="${SERVICE:-Wi-Fi}"
BYPASS="localhost 127.0.0.1 ::1 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 *.local *.ts.net"
HEALTH_URL="https://www.gstatic.com/generate_204"
LOGFILE="$HOME/Library/Logs/v2ray-proxy-watchdog.log"

log() { echo "[watchdog $(date '+%F %T')] $1" >> "$LOGFILE"; }

is_proxy_healthy() {
  nc -z -G 1 "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1 || return 1
  curl -s -m 6 -x "http://${PROXY_HOST}:${PROXY_PORT}" -o /dev/null "$HEALTH_URL"
}

proxy_ok() {
  networksetup -getwebproxy "$SERVICE" 2>/dev/null | grep -q "Enabled: Yes" || return 1
  networksetup -getwebproxy "$SERVICE" 2>/dev/null | grep -q "Port: $PROXY_PORT" || return 1
  networksetup -getsecurewebproxy "$SERVICE" 2>/dev/null | grep -q "Enabled: Yes" || return 1
  networksetup -getsecurewebproxy "$SERVICE" 2>/dev/null | grep -q "Port: $PROXY_PORT" || return 1
  networksetup -getsocksfirewallproxy "$SERVICE" 2>/dev/null | grep -q "Enabled: Yes" || return 1
  networksetup -getsocksfirewallproxy "$SERVICE" 2>/dev/null | grep -q "Port: $PROXY_PORT" || return 1
}

restore_proxy() {
  networksetup -setwebproxy "$SERVICE" "$PROXY_HOST" "$PROXY_PORT" \
    && networksetup -setsecurewebproxy "$SERVICE" "$PROXY_HOST" "$PROXY_PORT" \
    && networksetup -setsocksfirewallproxy "$SERVICE" "$PROXY_HOST" "$PROXY_PORT" \
    && networksetup -setproxybypassdomains "$SERVICE" $BYPASS \
    && log "restored system proxy -> ${PROXY_HOST}:${PROXY_PORT}" \
    || log "restore attempt failed"
}

while true; do
  if ! proxy_ok; then
    if is_proxy_healthy; then
      restore_proxy
    fi
  fi
  sleep 10
done
