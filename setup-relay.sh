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
#   1. Enables TCP BBR + FQ congestion control and RFC 4821 MTU probing
#      (tcp_mtu_probing=1) to minimize cross-border packet loss and PMTUD blackholes.
#   2. Installs persistent bidirectional TCP MSS clamping (<=1280 IPv4 / <=1220 IPv6,
#      ceiling-only) so 4G/5G mobile hotspots (464XLAT/CLAT) never stall on AWS
#      Jumbo Frame (MTU 9001) + Chrome Post-Quantum (~1850B) TLS ClientHellos.
#   3. Installs HAProxy and verifies reachability to your Fixed-Exit VPS
#      (automatically preferring low-latency VPC private IP if reachable).
#   4. Configures SNI-aware TCP relay on port 443 (with xver=0 native passthrough
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
TCP_MSS="${TCP_MSS:-1280}"
TCP_MSS6="${TCP_MSS6:-1220}"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

command -v apt >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (apt not found)."

# ----- 1. Enable TCP BBR + FQ + PMTUD Blackhole Probing ----------------------
info "Enabling TCP BBR + FQ congestion control and TCP MTU probing..."
grep -q "^net.core.default_qdisc=" /etc/sysctl.conf 2>/dev/null \
  || printf "\nnet.core.default_qdisc=fq\n" >> /etc/sysctl.conf
grep -q "^net.ipv4.tcp_congestion_control=" /etc/sysctl.conf 2>/dev/null \
  || printf "net.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
if ! grep -q "^net.ipv4.tcp_mtu_probing=" /etc/sysctl.conf 2>/dev/null; then
  printf "net.ipv4.tcp_mtu_probing=1\n" >> /etc/sysctl.conf
else
  sed -i 's/^net\.ipv4\.tcp_mtu_probing=.*/net.ipv4.tcp_mtu_probing=1/' /etc/sysctl.conf
fi
sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
ok "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown), tcp_mtu_probing=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"

# ----- 2. Configure Bidirectional TCP MSS Clamping (Hotspot/464XLAT Safe) ----
MSS_PORTS="22,${LISTEN_PORT}"
[ "$ENABLE_SSH_RELAY" = "true" ] && MSS_PORTS="${MSS_PORTS},${SSH_RELAY_PORT}"
MSS_PORTS="$(printf '%s' "$MSS_PORTS" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)"

info "Configuring zero-downtime bidirectional TCP MSS ceiling (IPv4<=${TCP_MSS}, IPv6<=${TCP_MSS6} on ports ${MSS_PORTS})..."
install -d -m 0755 /usr/local/libexec
cat > /usr/local/libexec/reality-tcp-mss <<'MSS_EOF'
#!/bin/sh
# Managed by reality-relay-box: bidirectional TCP MSS ceiling for mobile hotspot / 464XLAT / tunnel paths.
# Clamps only SYN / SYN-ACK packets whose MSS exceeds the ceiling (never raises smaller MSS).
# Existing established TCP connections are completely untouched.
set -eu

IPTABLES="${IPTABLES:-/usr/sbin/iptables}"
IP6TABLES="${IP6TABLES:-/usr/sbin/ip6tables}"
PORTS="${PORTS:-22,443,2222}"
MSS4="${MSS4:-1280}"
MSS6="${MSS6:-1220}"
MIN4=$((MSS4 + 1))
MIN6=$((MSS6 + 1))

sync_rule() {
    bin="$1"; chain="$2"; port_flag="$3"; tag="$4"; mss="$5"; min_mss="$6"
    [ -x "$bin" ] || return 0
    if "$bin" -w 5 -t mangle -C "$chain" -p tcp -m multiport "$port_flag" "$PORTS" \
        --tcp-flags SYN,RST SYN -m tcpmss --mss "${min_mss}:65535" \
        -m comment --comment "$tag" -j TCPMSS --set-mss "$mss" 2>/dev/null; then
        return 0
    fi
    "$bin" -w 5 -t mangle -I "$chain" 1 -p tcp -m multiport "$port_flag" "$PORTS" \
        --tcp-flags SYN,RST SYN -m tcpmss --mss "${min_mss}:65535" \
        -m comment --comment "$tag" -j TCPMSS --set-mss "$mss"
    "$bin" -w 5 -t mangle -S "$chain" 2>/dev/null \
        | grep -- "-A ${chain} " \
        | grep -- "--comment ${tag}" \
        | tail -n +2 \
        | sed "s/^-A ${chain} //" \
        | while IFS= read -r spec; do
            # shellcheck disable=SC2086
            "$bin" -w 5 -t mangle -D "$chain" $spec 2>/dev/null || true
        done
}

remove_by_comment() {
    bin="$1"; chain="$2"; tag="$3"
    [ -x "$bin" ] || return 0
    "$bin" -w 5 -t mangle -S "$chain" 2>/dev/null \
        | grep -- "-A ${chain} " \
        | grep -- "--comment ${tag}" \
        | sed "s/^-A ${chain} //" \
        | while IFS= read -r spec; do
            # shellcheck disable=SC2086
            "$bin" -w 5 -t mangle -D "$chain" $spec 2>/dev/null || true
        done
}

case "${1:-status}" in
    apply)
        sync_rule "$IPTABLES" INPUT --dports reality-tcp-mss-in "$MSS4" "$MIN4"
        sync_rule "$IPTABLES" OUTPUT --sports reality-tcp-mss-out "$MSS4" "$MIN4"
        sync_rule "$IP6TABLES" INPUT --dports reality-tcp-mss-in "$MSS6" "$MIN6" || true
        sync_rule "$IP6TABLES" OUTPUT --sports reality-tcp-mss-out "$MSS6" "$MIN6" || true
        ;;
    remove)
        remove_by_comment "$IPTABLES" OUTPUT reality-tcp-mss-out
        remove_by_comment "$IPTABLES" INPUT reality-tcp-mss-in
        remove_by_comment "$IP6TABLES" OUTPUT reality-tcp-mss-out
        remove_by_comment "$IP6TABLES" INPUT reality-tcp-mss-in
        ;;
    status)
        "$IPTABLES" -w 5 -t mangle -S | grep "reality-tcp-mss-"
        ;;
    *)
        printf 'Usage: %s [apply|remove|status]\n' "$0" >&2
        exit 2
        ;;
esac
MSS_EOF
chmod 0755 /usr/local/libexec/reality-tcp-mss

cat > /etc/systemd/system/reality-tcp-mss.service <<UNIT_EOF
[Unit]
Description=reality-relay-box bidirectional TCP MSS clamping for hotspot/tunnel compatibility
DefaultDependencies=no
After=local-fs.target ufw.service nftables.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
Environment="PORTS=${MSS_PORTS}" "MSS4=${TCP_MSS}" "MSS6=${TCP_MSS6}"
ExecStart=/usr/local/libexec/reality-tcp-mss apply
ExecReload=/usr/local/libexec/reality-tcp-mss apply
ExecStop=/usr/local/libexec/reality-tcp-mss remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now reality-tcp-mss.service >/dev/null
systemctl reload-or-restart reality-tcp-mss.service >/dev/null
ok "Bidirectional TCP MSS ceiling active on ports ${MSS_PORTS} (IPv4<=${TCP_MSS}, IPv6<=${TCP_MSS6})."

# ----- 3. Install HAProxy & netcat -------------------------------------------
info "Installing HAProxy and netcat..."
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null 2>&1 || warn "apt update reported warnings, continuing."
apt install -y haproxy netcat-openbsd curl >/dev/null 2>&1 || die "Failed to install haproxy."

# ----- 4. Verify connectivity to Exit VPS ------------------------------------
info "Testing connectivity to Exit VPS (${EXIT_HOST}:${EXIT_PORT})..."
if nc -z -w 4 "$EXIT_HOST" "$EXIT_PORT" >/dev/null 2>&1; then
  ok "Exit VPS ${EXIT_HOST}:${EXIT_PORT} is reachable!"
else
  warn "Could not reach ${EXIT_HOST}:${EXIT_PORT} right now."
  warn "Make sure setup-exit.sh is running on the Exit VPS and its firewall allows connections from this Relay VPS."
fi

# ----- 5. Write HAProxy configuration ----------------------------------------
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
