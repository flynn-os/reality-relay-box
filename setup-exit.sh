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
#   1. Enables TCP BBR + FQ congestion control automatically.
#   2. Defaults to an ASN-aligned camouflage target (d1.awsstatic.com for AWS
#      regions, TLS 1.3 + HTTP/2) so passive DPI sees 100% ASN consistency and
#      active empty-SNI probes never leak a mismatched CDN certificate.
#   3. Listens on both 443 and an internal relay port (8443) with xver=0 and
#      production-safe warning log level.
#   4. Generates all credentials (UUID, X25519 key pair, ShortID) locally on
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
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
CLIENT_FILE="/root/reality-client.txt"

[ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash $0"
command -v apt >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (apt not found)."

# ----- 1. Enable TCP BBR + FQ ------------------------------------------------
info "Enabling TCP BBR + FQ congestion control..."
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  printf "\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || true
ok "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

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
