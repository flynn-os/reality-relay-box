#!/usr/bin/env bash
#
# setup-exit.sh — One-click Fixed-Exit VPS installer (Xray VLESS + REALITY)
# -------------------------------------------------------------------------
# Role in the Dual-VPS Architecture:
#   [ Client ] ==(TLS 1.3)==> [ Relay VPS :443 ] ==(VPC / TCP)==> [ Exit VPS (THIS SERVER) ] --> AI APIs
#
# Why separate Relay and Exit?
#   - AI Coding tools (Claude Code, OpenAI, etc.) enforce strict risk controls
#     on frequently changing egress IPs.
#   - By decoupling the Entry Relay VPS from the Fixed Exit VPS, your outbound
#     IP to AI APIs remains 100% static forever, while the Entry Relay VPS can
#     be rotated anytime without touching your Exit VPS or credentials.
#
# Key Anti-Blocking Hardening Built In:
#   1. Enables TCP BBR + FQ congestion control and TCP MTU probing automatically.
#   2. Configures persistent bidirectional TCP MSS clamping (<=1280 IPv4 / <=1220
#      IPv6, ceiling-only) across SSH + REALITY ports so 4G/5G mobile hotspots
#      (464XLAT/CLAT) never stall on AWS Jumbo Frame (MTU 9001) + Chrome PQ ClientHellos.
#   3. Defaults to an ASN-aligned camouflage target (d1.awsstatic.com for AWS
#      regions, TLS 1.3 + HTTP/2) so passive DPI sees 100% ASN consistency and
#      active empty-SNI probes never leak a mismatched CDN certificate.
#   4. Listens on both 443 and an internal relay port (8443) with xver=0 and
#      production-safe warning log level.
#   5. Generates all credentials (UUID, X25519 key pair, ShortID) locally on
#      run and prints a ready-to-import vless:// share link.
#
# Usage:
#   sudo bash setup-exit.sh
#
# Optional environment variable overrides:
#   RELAY_PUBLIC_IP  Public IP of your Entry Relay VPS (embedded into share link)
#   PORT             Primary listening port             (default: 443)
#   INTERNAL_PORT    VPC internal listening port        (default: 8443)
#   DEST             REALITY camouflage target host     (default: d1.awsstatic.com)
#   SNI              TLS SNI shown to the firewall      (default: same as DEST)
#   TCP_MSS          IPv4 TCP MSS ceiling for hotspots  (default: 1280)
#   TAG              Client profile name                (default: Reality-Relay-<ip>)
# -------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

PORT="${PORT:-443}"
INTERNAL_PORT="${INTERNAL_PORT:-8443}"
DEST="${DEST:-d1.awsstatic.com}"
SNI="${SNI:-$DEST}"
TCP_MSS="${TCP_MSS:-1280}"
TCP_MSS6="${TCP_MSS6:-1220}"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
CLIENT_FILE="/root/reality-client.txt"

[ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash $0"
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

# ----- 1b. Configure Bidirectional TCP MSS Clamping (Hotspot/464XLAT Safe) ---
MSS_PORTS="$(printf '%s\n' "22" "$PORT" "$INTERNAL_PORT" | awk '!seen[$0]++' | paste -sd, -)"
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
PORTS="${PORTS:-22,443,8443}"
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
if systemctl is-enabled --quiet claudemagic-proxy-mss.service 2>/dev/null || systemctl is-active --quiet claudemagic-proxy-mss.service 2>/dev/null; then
  systemctl stop claudemagic-proxy-mss.service >/dev/null 2>&1 || true
  systemctl disable claudemagic-proxy-mss.service >/dev/null 2>&1 || true
fi
ok "Bidirectional TCP MSS ceiling active on ports ${MSS_PORTS} (IPv4<=${TCP_MSS}, IPv6<=${TCP_MSS6})."

# ----- 2. Install dependencies & Xray-core -----------------------------------
info "Installing dependencies (curl, openssl, qrencode)..."
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null 2>&1 || warn "apt update reported warnings, continuing."
apt install -y curl openssl qrencode >/dev/null 2>&1 || warn "Some packages failed to install; continuing."

if ! command -v xray >/dev/null 2>&1; then
  info "Installing Xray-core..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  ok "Xray already installed: $(xray version | head -n1)"
fi

# ----- 3. Generate credentials -----------------------------------------------
info "Generating fresh X25519 key pair, UUID, and ShortID..."
KEY_OUTPUT="$(xray x25519)"
PRIVATE_KEY="$(echo "$KEY_OUTPUT" | grep -iE 'private' | head -n1 | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')"
PUBLIC_KEY="$(echo "$KEY_OUTPUT"  | grep -iE 'public|password' | head -n1 | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "Failed to parse keys from: $KEY_OUTPUT"

UUID="$(xray uuid)"
SHORT_ID="$(openssl rand -hex 8)"

# ----- 4. Detect Exit Public IP & Private VPC IP -----------------------------
EXIT_PUBLIC_IP="$(curl -s4 --max-time 10 https://ip.me || curl -s4 --max-time 10 https://ifconfig.me || true)"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
[ -n "$PRIVATE_IP" ] || PRIVATE_IP="0.0.0.0"

LINK_IP="${RELAY_PUBLIC_IP:-${EXIT_PUBLIC_IP:-YOUR_RELAY_PUBLIC_IP}}"
TAG="${TAG:-Reality-Relay-$LINK_IP}"

ok "Exit Public IP (Fixed Egress) : ${EXIT_PUBLIC_IP:-unknown}"
ok "Exit Private VPC IP           : $PRIVATE_IP"

# ----- 5. Verify Camouflage Target (TLS 1.3) ---------------------------------
if curl -sI --tlsv1.3 --max-time 8 "https://$DEST" >/dev/null 2>&1; then
  ok "REALITY camouflage target verified over TLS 1.3: https://$DEST"
else
  warn "Could not verify TLS 1.3 handshake to https://$DEST from this server."
  warn "Consider passing DEST=<another-tls13-domain-in-same-asn>."
fi

# ----- 6. Write Xray configuration -------------------------------------------
info "Writing Xray configuration to $CONFIG_FILE ..."
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpKeepAliveInterval": 15
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    },
    {
      "listen": "$PRIVATE_IP",
      "port": $INTERNAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpKeepAliveInterval": 15
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

xray run -test -c "$CONFIG_FILE" >/dev/null
systemctl restart xray
systemctl enable xray >/dev/null 2>&1 || true

sleep 1
systemctl is-active --quiet xray && ok "Xray is active and listening on :$PORT and $PRIVATE_IP:$INTERNAL_PORT." \
  || die "Xray failed to start. Check: journalctl -u xray -e"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  ufw allow "$INTERNAL_PORT"/tcp >/dev/null 2>&1 || true
fi

SHARE_LINK="vless://${UUID}@${LINK_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}"

{
  echo "# VLESS + REALITY Fixed-Exit Server Info"
  echo "# Generated on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "Exit Public IP (Fixed) : ${EXIT_PUBLIC_IP:-unknown}"
  echo "Exit Private VPC IP    : $PRIVATE_IP"
  echo "Entry Relay IP in link : $LINK_IP"
  echo "External Port          : $PORT"
  echo "Internal VPC Port      : $INTERNAL_PORT"
  echo "UUID                   : $UUID"
  echo "Public Key (pbk)       : $PUBLIC_KEY"
  echo "Short ID (sid)         : $SHORT_ID"
  echo "SNI / DEST             : $SNI"
  echo
  echo "Next step on your Entry Relay VPS:"
  echo "  sudo EXIT_HOST=$PRIVATE_IP EXIT_PORT=$INTERNAL_PORT SNI=$SNI bash setup-relay.sh"
  echo
  echo "Client Share Link (replace $LINK_IP with your Entry Relay Public IP if not set):"
  echo "$SHARE_LINK"
} > "$CLIENT_FILE"
chmod 600 "$CLIENT_FILE"

echo
echo -e "${GREEN}========================================================================${NC}"
echo -e "${GREEN} Fixed-Exit VPS setup complete!${NC}"
echo -e "${GREEN}========================================================================${NC}"
echo
info "1) Run this on your Entry Relay VPS (prefers private VPC IP $PRIVATE_IP):"
echo -e "   ${YELLOW}sudo EXIT_HOST=${PRIVATE_IP} EXIT_PORT=${INTERNAL_PORT} SNI=${SNI} bash setup-relay.sh${NC}"
echo "   (If the two VPSs are not in the same VPC subnet, use EXIT_HOST=${EXIT_PUBLIC_IP:-YOUR_EXIT_IP} EXIT_PORT=${PORT})"
echo
info "2) Client share link (saved to $CLIENT_FILE):"
echo -e "   ${YELLOW}${SHARE_LINK}${NC}"
echo
if command -v qrencode >/dev/null 2>&1 && [ -n "${RELAY_PUBLIC_IP:-}" ]; then
  info "QR code for mobile clients:"
  qrencode -t ANSIUTF8 "$SHARE_LINK"
fi
