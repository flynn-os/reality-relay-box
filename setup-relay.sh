#!/usr/bin/env bash
#
# setup-relay.sh — One-click Entry Relay VPS installer (HAProxy TCP/SNI Relay)
# ----------------------------------------------------------------------------
# Role in the Dual-VPS Architecture:
#   [ Client ] ==(VLESS+REALITY)==> [ Relay VPS (THIS SERVER) :443 ]
#                                         |
#                           (AWS VPC Private Network / TCP)
#                                         v
#                              [ Fixed-Exit VPS :8443 ] --> Internet / AI APIs
#
# What this script does:
#   1. Enables TCP BBR + FQ congestion control to minimize cross-border packet
#      loss and TCP retransmission signatures.
#   2. Installs HAProxy and verifies reachability to your Fixed-Exit VPS
#      (automatically preferring low-latency VPC private IP if reachable).
#   3. Configures SNI-aware TCP relay on port 443 (with xver=0 native passthrough
#      so REALITY handshakes never break) plus optional fallback SSH relay on
#      port 2222.
#
# Usage:
#   sudo EXIT_HOST=<exit-private-or-public-ip> bash setup-relay.sh
#
# Example (same AWS region/VPC):
#   sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh
# ----------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root: sudo EXIT_HOST=<ip> bash $0"
[ -n "${EXIT_HOST:-}" ] || die "Missing EXIT_HOST. Usage: sudo EXIT_HOST=<exit-vps-ip> [EXIT_PORT=8443] [SNI=d1.awsstatic.com] bash $0"

LISTEN_PORT="${LISTEN_PORT:-443}"
EXIT_PORT="${EXIT_PORT:-8443}"
SNI="${SNI:-d1.awsstatic.com}"
ENABLE_SSH_RELAY="${ENABLE_SSH_RELAY:-true}"
SSH_RELAY_PORT="${SSH_RELAY_PORT:-2222}"
EXIT_SSH_PORT="${EXIT_SSH_PORT:-22}"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

command -v apt >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (apt not found)."

# ----- 1. Enable TCP BBR + FQ ------------------------------------------------
info "Enabling TCP BBR + FQ congestion control..."
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  printf "\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true
ok "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

# ----- 2. Install HAProxy & netcat -------------------------------------------
info "Installing HAProxy and netcat..."
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null 2>&1 || warn "apt update reported warnings, continuing."
apt install -y haproxy netcat-openbsd curl >/dev/null 2>&1 || die "Failed to install haproxy."

# ----- 3. Verify connectivity to Exit VPS ------------------------------------
info "Testing connectivity to Exit VPS (${EXIT_HOST}:${EXIT_PORT})..."
if nc -z -w 4 "$EXIT_HOST" "$EXIT_PORT" >/dev/null 2>&1; then
  ok "Exit VPS ${EXIT_HOST}:${EXIT_PORT} is reachable!"
else
  warn "Could not reach ${EXIT_HOST}:${EXIT_PORT} right now."
  warn "Make sure setup-exit.sh is running on the Exit VPS and its firewall allows connections from this Relay VPS."
fi

# ----- 4. Write HAProxy configuration ----------------------------------------
info "Writing HAProxy configuration to $HAPROXY_CFG ..."
[ -f "$HAPROXY_CFG" ] && cp "$HAPROXY_CFG" "${HAPROXY_CFG}.bak-$(date +%Y%m%d-%H%M%S)"

cat > "$HAPROXY_CFG" <<EOF
global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend reality_in
    bind *:${LISTEN_PORT}
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend reality_aws if { req.ssl_sni -i ${SNI} }
    default_backend reality_aws

backend reality_aws
    mode tcp
    server reality_exit ${EXIT_HOST}:${EXIT_PORT}
EOF

if [ "$ENABLE_SSH_RELAY" = "true" ]; then
  cat >> "$HAPROXY_CFG" <<EOF

frontend ssh_in
    bind *:${SSH_RELAY_PORT}
    default_backend ssh_out

backend ssh_out
    server ssh_exit ${EXIT_HOST}:${EXIT_SSH_PORT}
EOF
fi

haproxy -c -f "$HAPROXY_CFG" >/dev/null || die "HAProxy config validation failed!"
systemctl enable haproxy >/dev/null 2>&1 || true
systemctl restart haproxy

sleep 1
systemctl is-active --quiet haproxy && ok "HAProxy is running and relaying :${LISTEN_PORT} -> ${EXIT_HOST}:${EXIT_PORT}." \
  || die "HAProxy failed to start. Check: journalctl -u haproxy -e"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
  [ "$ENABLE_SSH_RELAY" = "true" ] && ufw allow "${SSH_RELAY_PORT}/tcp" >/dev/null 2>&1 || true
fi

RELAY_PUBLIC_IP="$(curl -s4 --max-time 8 https://ip.me || curl -s4 --max-time 8 https://ifconfig.me || echo YOUR_RELAY_PUBLIC_IP)"

echo
echo -e "${GREEN}========================================================================${NC}"
echo -e "${GREEN} Entry Relay VPS setup complete!${NC}"
echo -e "${GREEN}========================================================================${NC}"
echo
ok "Relay Public IP : $RELAY_PUBLIC_IP"
ok "Forwarding      : *:${LISTEN_PORT} -> ${EXIT_HOST}:${EXIT_PORT} (SNI: ${SNI})"
[ "$ENABLE_SSH_RELAY" = "true" ] && ok "Emergency SSH   : *:${SSH_RELAY_PORT} -> ${EXIT_HOST}:${EXIT_SSH_PORT}"
echo
warn "Reminder: open TCP port ${LISTEN_PORT} in your cloud console firewall (e.g. AWS Lightsail Networking)."
info "In your client (v2rayN), set the server address to: ${RELAY_PUBLIC_IP}"
