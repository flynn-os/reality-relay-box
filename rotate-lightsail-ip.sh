#!/usr/bin/env bash
#
# rotate-lightsail-ip.sh — Automated Entry Relay Static IP Rotator & Clean-IP Verifier
# ------------------------------------------------------------------------------------
# Connects directly to the AWS Lightsail regional API (bypassing a blocked local proxy),
# allocates a fresh Static IP, attaches it to your Entry Relay instance, probes TCP :443
# directly from your client machine to ensure the allocated IP is NOT already blocked
# (retrying up to 3 times if dirty), releases the old Static IP ($0 unattached charge),
# and updates local + optional peer client configs via switch-relay-ip.sh.
#
# Configuration via environment variables or ~/.config/reality-relay-box/rotate.env:
#   RELAY_PRIVATE_IP   Entry Relay private VPC IP (e.g. 172.26.1.10) [required unless --instance]
#   RELAY_INSTANCE     Optional Lightsail instance name (overrides RELAY_PRIVATE_IP lookup)
#   AWS_REGION         Lightsail region (default: ap-northeast-1)
#   RELAY_PORT         Public REALITY port to probe (default: 443)
#   PEER_SSH_HOST      Optional SSH host alias of a second dev machine (e.g. dev-box)
#   PEER_SWITCH_SCRIPT Path to switch-relay-ip.sh on PEER_SSH_HOST
#   AWS_BIN            Path to aws CLI v2 binary (default: aws)
#
# Usage:
#   RELAY_PRIVATE_IP=172.26.1.10 bash rotate-lightsail-ip.sh [--check] [--force] [--no-restart]
# ------------------------------------------------------------------------------------

set -euo pipefail
export HISTFILE=/dev/null
set +o history 2>/dev/null || true

ENV_FILE="${ROTATE_ENV_FILE:-$HOME/.config/reality-relay-box/rotate.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

AWS_BIN="${AWS_BIN:-$(command -v aws || echo /usr/local/bin/aws)}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
RELAY_PRIVATE_IP="${RELAY_PRIVATE_IP:-}"
RELAY_INSTANCE="${RELAY_INSTANCE:-}"
RELAY_PORT="${RELAY_PORT:-443}"
PEER_SSH_HOST="${PEER_SSH_HOST:-}"
PEER_SWITCH_SCRIPT="${PEER_SWITCH_SCRIPT:-~/reality-relay-box/switch-relay-ip.sh}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH_SCRIPT="${SWITCH_SCRIPT:-${SCRIPT_DIR}/switch-relay-ip.sh}"

if [ "$(uname -s)" = "Darwin" ]; then
  CLIENT_CFG="${CLIENT_CFG:-$HOME/Library/Application Support/v2rayN/binConfigs/config.json}"
else
  CLIENT_CFG="${CLIENT_CFG:-$HOME/.local/share/v2rayN/binConfigs/config.json}"
fi

FORCE=0
CHECK_ONLY=0
NO_RESTART=0

usage() {
  cat <<'HELP'
Usage: rotate-lightsail-ip.sh [--check] [--force] [--no-restart] [--help]

Options:
  --check       Read-only check: print current Entry IP & direct TCP reachability
  --force       Rotate even if the current Entry IP is reachable
  --no-restart  Update client configs without restarting active xray processes
  --help        Show this help message
HELP
}

for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[x] Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$CLIENT_CFG" ] || { echo "[x] Client config not found: $CLIENT_CFG" >&2; exit 1; }

CURRENT_IP="$(python3 - "$CLIENT_CFG" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)
for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "proxy":
        s = ob.get("settings", {})
        if s.get("address"):
            print(s["address"]); raise SystemExit(0)
        vn = s.get("vnext", [])
        if vn and vn[0].get("address"):
            print(vn[0]["address"]); raise SystemExit(0)
raise SystemExit("No proxy address found in " + sys.argv[1])
PY
)"

echo "[*] Current Entry Relay IP: ${CURRENT_IP}:${RELAY_PORT}"

probe_tcp() {
  local host="$1" port="$2"
  if [ "$(uname -s)" = "Darwin" ]; then
    nc -z -G 4 "$host" "$port" >/dev/null 2>&1
  else
    nc -z -w 4 "$host" "$port" >/dev/null 2>&1
  fi
}

if probe_tcp "$CURRENT_IP" "$RELAY_PORT"; then
  echo "[+] Direct TCP check to ${CURRENT_IP}:${RELAY_PORT} -> REACHABLE"
  [ "$CHECK_ONLY" -eq 1 ] && exit 0
  if [ "$FORCE" -ne 1 ]; then
    echo "[!] Entry IP is reachable. Pass --force to rotate anyway."
    exit 0
  fi
else
  echo "[!] Direct TCP check to ${CURRENT_IP}:${RELAY_PORT} -> BLOCKED / TIMEOUT"
  [ "$CHECK_ONLY" -eq 1 ] && exit 1
fi

[ -x "$AWS_BIN" ] || { echo "[x] aws CLI not found/executable: $AWS_BIN" >&2; exit 1; }
[ -n "$RELAY_INSTANCE" ] || [ -n "$RELAY_PRIVATE_IP" ] || {
  echo "[x] Set RELAY_PRIVATE_IP (e.g. 172.26.1.10) or RELAY_INSTANCE." >&2
  exit 1
}

aws_direct() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    "$AWS_BIN" "$@"
}

detach_and_wait() {
  local sip="$1" reg="$2" state=""
  aws_direct lightsail detach-static-ip --region "$reg" --static-ip-name "$sip" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    state="$(aws_direct lightsail get-static-ip --region "$reg" --static-ip-name "$sip" --query 'staticIp.isAttached' --output text 2>/dev/null || echo "")"
    case "$state" in
      False|false|None) return 0 ;;
    esac
    sleep 2
  done
  return 0
}

attach_with_retry() {
  local sip="$1" inst="$2" reg="$3"
  for _ in 1 2 3 4 5 6; do
    if aws_direct lightsail attach-static-ip --region "$reg" --static-ip-name "$sip" --instance-name "$inst" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

release_with_retry() {
  local sip="$1" reg="$2"
  for _ in 1 2 3 4 5 6; do
    if aws_direct lightsail release-static-ip --region "$reg" --static-ip-name "$sip" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

OLD_DETACHED=0
PENDING_CAND=""
NEW_IP=""
OLD_STATIC_NAME=""

cleanup_on_exit() {
  if [ -n "${PENDING_CAND:-}" ]; then
    detach_and_wait "$PENDING_CAND" "$AWS_REGION" || true
    release_with_retry "$PENDING_CAND" "$AWS_REGION" || true
    PENDING_CAND=""
  fi
  if [ -z "${NEW_IP:-}" ] && [ "${OLD_DETACHED:-0}" -eq 1 ] && [ -n "${OLD_STATIC_NAME:-}" ] && [ -n "${RELAY_INSTANCE:-}" ]; then
    attach_with_retry "$OLD_STATIC_NAME" "$RELAY_INSTANCE" "$AWS_REGION" || true
  fi
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}
trap cleanup_on_exit EXIT INT TERM

if ! aws_direct sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
  [ -r /dev/tty ] || { echo "[x] No valid AWS session and no TTY available." >&2; exit 1; }
  echo "=== Temporary In-Memory AWS Credentials (${AWS_REGION}, Direct API) ===" >&2
  read -rs -p "AWS Access Key ID (hidden): " INPUT_AK </dev/tty; echo >&2
  read -rs -p "AWS Secret Access Key (hidden): " INPUT_SK </dev/tty; echo >&2
  read -rs -p "AWS Session Token (optional, Enter if none): " INPUT_ST </dev/tty; echo >&2
  AWS_ACCESS_KEY_ID="$(printf '%s' "$INPUT_AK" | tr -d '\r\n[:space:]')"
  AWS_SECRET_ACCESS_KEY="$(printf '%s' "$INPUT_SK" | tr -d '\r\n[:space:]')"
  AWS_SESSION_TOKEN="$(printf '%s' "$INPUT_ST" | tr -d '\r\n[:space:]')"
  unset INPUT_AK INPUT_SK INPUT_ST
  [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || { echo "[x] Missing AWS credentials." >&2; exit 1; }
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  if [ -n "$AWS_SESSION_TOKEN" ]; then export AWS_SESSION_TOKEN; else unset AWS_SESSION_TOKEN; fi
fi

ACCT="$(aws_direct sts get-caller-identity --region "$AWS_REGION" --query 'Account' --output text)"
echo "[+] Authenticated AWS Account: ${ACCT}"

INSTANCES_JSON="$(aws_direct lightsail get-instances --region "$AWS_REGION" --output json)"
STATICS_JSON="$(aws_direct lightsail get-static-ips --region "$AWS_REGION" --output json)"

if [ -z "$RELAY_INSTANCE" ]; then
  RELAY_INSTANCE="$(python3 - "$INSTANCES_JSON" "$RELAY_PRIVATE_IP" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
priv = sys.argv[2]
for inst in data.get("instances", []):
    if inst.get("privateIpAddress") == priv:
        print(inst["name"]); raise SystemExit(0)
raise SystemExit("Entry instance not found by private IP " + priv)
PY
)"
fi

OLD_STATIC_NAME="$(python3 - "$STATICS_JSON" "$RELAY_INSTANCE" "$CURRENT_IP" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
ename, cur_ip = sys.argv[2], sys.argv[3]
for s in data.get("staticIps", []):
    if s.get("attachedTo") == ename or s.get("ipAddress") == cur_ip:
        print(s["name"]); raise SystemExit(0)
print("")
PY
)"
echo "[*] Entry Instance: ${RELAY_INSTANCE} | Old Static IP: ${OLD_STATIC_NAME:-<none>} (${CURRENT_IP})"

NEW_IP=""
NEW_STATIC_NAME=""
for attempt in 1 2 3; do
  CAND_NAME="relay-ip-$(date +%Y%m%d-%H%M%S)-${attempt}"
  echo "[*] Attempt ${attempt}/3: Allocating ${CAND_NAME}..."
  aws_direct lightsail allocate-static-ip --region "$AWS_REGION" --static-ip-name "$CAND_NAME" >/dev/null
  PENDING_CAND="$CAND_NAME"

  if [ "$OLD_DETACHED" -eq 0 ] && [ -n "$OLD_STATIC_NAME" ]; then
    echo "[*] Detaching current Static IP '${OLD_STATIC_NAME}' from ${RELAY_INSTANCE}..."
    detach_and_wait "$OLD_STATIC_NAME" "$AWS_REGION"
    OLD_DETACHED=1
  fi

  echo "[*] Attaching ${CAND_NAME} to ${RELAY_INSTANCE}..."
  attach_with_retry "$CAND_NAME" "$RELAY_INSTANCE" "$AWS_REGION"
  CAND_IP="$(aws_direct lightsail get-static-ip --region "$AWS_REGION" --static-ip-name "$CAND_NAME" --query 'staticIp.ipAddress' --output text)"

  REACHABLE=0
  for _ in 1 2; do
    sleep 2
    if probe_tcp "$CAND_IP" "$RELAY_PORT"; then
      REACHABLE=1
      break
    fi
  done

  if [ "$REACHABLE" -eq 1 ]; then
    NEW_IP="$CAND_IP"
    NEW_STATIC_NAME="$CAND_NAME"
    PENDING_CAND=""
    echo "[+] Verified reachable Entry IP: ${NEW_IP}:${RELAY_PORT} (${NEW_STATIC_NAME})"
    break
  else
    echo "[!] Candidate ${CAND_IP} is unreachable! Detaching, releasing, and retrying..."
    detach_and_wait "$CAND_NAME" "$AWS_REGION"
    release_with_retry "$CAND_NAME" "$AWS_REGION" || echo "[!] Warning: could not release candidate '${CAND_NAME}'; check Lightsail Console." >&2
    PENDING_CAND=""
  fi
done

[ -n "$NEW_IP" ] || { echo "[x] Failed to obtain a reachable Entry IP after 3 attempts." >&2; exit 1; }

if [ -n "$OLD_STATIC_NAME" ] && [ "$OLD_STATIC_NAME" != "$NEW_STATIC_NAME" ]; then
  echo "[*] Releasing old Static IP '${OLD_STATIC_NAME}'..."
  release_with_retry "$OLD_STATIC_NAME" "$AWS_REGION" || \
    echo "[!] Warning: release '${OLD_STATIC_NAME}' manually in Lightsail Console." >&2
fi

if [ "$NO_RESTART" -eq 1 ]; then
  SW_FLAG="--no-restart"
else
  SW_FLAG="--force-restart"
fi

bash "$SWITCH_SCRIPT" "$NEW_IP" "$SW_FLAG"

if [ -n "$PEER_SSH_HOST" ]; then
  echo "[*] Syncing peer host (${PEER_SSH_HOST})..."
  ssh -o BatchMode=yes -o ConnectTimeout=6 "$PEER_SSH_HOST" "bash ${PEER_SWITCH_SCRIPT} '${NEW_IP}' '${SW_FLAG}'" || \
    echo "[!] Warning: failed to sync peer ${PEER_SSH_HOST}; update it manually." >&2
fi
