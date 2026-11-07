# reality-relay-box

**English** | [简体中文](README.zh-CN.md)

> **Dual-VPS (Rotatable Entry Relay + Fixed-Exit IP) VLESS + REALITY proxy suite — engineered for AI coding tools (Claude Code, OpenAI, etc.) that require a rock-solid, static egress IP.**

Running a single-VPS proxy (like the basic `reality-box`) for AI coding tools creates a painful dilemma:
1. **Account Ban Risk on Egress IP Changes**: Platforms like Anthropic (Claude Code) and OpenAI enforce strict risk controls when your egress IP changes frequently.
2. **Entry IP Blocking**: When a single VPS acts as both entry and exit, any firewall block on the entry IP forces you to replace the server's IP — breaking your static egress IP.

**`reality-relay-box`** solves both problems with a **Decoupled Dual-VPS Architecture (Entry Relay VPS + Fixed-Exit VPS)** combined with **6 production-proven anti-blocking hardening measures**:
- **100% Static Egress IP Forever**: Your Fixed-Exit VPS never exposes its proxy port directly to the public internet. All outbound requests to Claude / OpenAI always originate from the exact same clean IP.
- **Hardened Against Active & Passive Probing**: Fixes the most common causes of REALITY IP blocks — including **ASN-mismatched SNI targets (e.g., using `www.cloudflare.com` on an AWS IP)**, **24/7 plaintext cross-border SSH tunnels**, and **fixed-interval client health-check beaconing**.
- **1-Second Zero-Downtime Relay Rotation**: If you ever need to rotate your Entry Relay VPS IP, your Fixed-Exit VPS and client credentials remain untouched. Run `setup-relay.sh` on the new relay and `switch-relay-ip.sh <NEW_IP>` on your client.

---

## Architecture Overview

```
[ Client (macOS / Linux Dev Machine) ]
   │  1) VLESS + REALITY (SNI: d1.awsstatic.com, Chrome FP, No Fragment)
   │  2) Cross-border SSH / autossh encapsulated inside 10808 proxy (Zero raw SSH exposure)
   ▼
[ Entry Relay VPS (e.g. 198.51.100.10) ]   <-- Exposes :443, TCP BBR+FQ enabled
   │  HAProxy (SNI routing + AWS VPC private network -> 172.26.2.20:8443, RTT ~0.15ms)
   ▼
[ Fixed-Exit VPS (e.g. 203.0.113.20) ]     <-- Static Egress IP, invisible to scanners
   │  Xray-core (REALITY termination, dest=d1.awsstatic.com:443, xver=0)
   ▼
[ Claude Code / Anthropic / OpenAI / Internet ]
```

*(Note: All IP addresses in this repository — `198.51.100.10`, `203.0.113.20`, `172.26.x.x` — are RFC 5737 / RFC 1918 documentation placeholders.)*

---

## 6 Built-In Anti-Blocking Hardening Measures

| # | Common Misconfiguration (Why Entry IPs Get Blocked) | How `reality-relay-box` Fixes It |
| :--- | :--- | :--- |
| **1. SNI ↔ ASN Conflict** | Setting `SNI`/`dest` to `www.cloudflare.com` on an AWS VPS. Passive DPI immediately flags `SNI=www.cloudflare.com` (AS13335) going to an AWS IP (AS16509). Worse, an empty-SNI active probe against the AWS IP returns Cloudflare's official TLS certificate. | Defaults to **`d1.awsstatic.com`** (AWS official static CDN, AS16509, TLS 1.3 + HTTP/2). Passive DPI sees 100% ASN consistency; empty-SNI probes are rejected just like a real CloudFront edge, and SNI probes return an authentic `Amazon RSA 2048 M04` certificate. |
| **2. Raw Cross-Border SSH Tunnels** | Running 24/7 `autossh` reverse tunnels or jump hosts directly to the Entry VPS on `:22` or `:2222` alongside `:443`. Exposes `SSH-2.0-OpenSSH` banners and keepalive timing from the same client IP. | [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example) routes SSH through the local `127.0.0.1:10808` REALITY SOCKS5 proxy, with automatic fallback to `:2222` only if the local proxy is down. Result: **zero raw cross-border SSH packets** during normal operation. |
| **3. Public Relay Hop & Scanner Exposure** | Relaying from Entry VPS to Exit VPS over the public IP consumes double bandwidth, adds extra RTT jitter, and exposes the Exit VPS `:443` to global scanners (Censys/Shodan). | Relays over the **AWS VPC private subnet (`172.26.x.x:8443`)** with `~0.15ms` latency, keeping the Fixed-Exit VPS invisible to internet scanners. |
| **4. Broken `send-proxy-v2` / `xver` Pairing** | Setting `realitySettings.xver: 2` (which actually sends a PROXY header *outbound* to the camouflage site `dest`) causes immediate connection resets. | Enforces `realitySettings.xver: 0` with HAProxy SNI-based TCP passthrough (`req_ssl_hello_type 1`). |
| **5. 10-Second Client Beaconing** | Watchdog scripts polling `gstatic.com` every 10 seconds emit 8,640 fixed-interval TLS handshakes per day across the firewall. | [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh) checks local macOS `networksetup` state first (zero network traffic) and only probes outbound when the system proxy was actually turned off. |
| **6. Artificial TLS Hello Fragmentation** | Enabling `tlshello` fragmentation (`finalmask` 50–100B) on REALITY creates an obvious non-browser packet signature. | Automatically strips `finalmask` / disables `EnableFragment`, enables **TCP BBR + FQ** on both servers, and sets Xray logs to `warning`. |

---

## Quick Start

### Step 1: Provision Two VPSs in the Same Region (e.g., AWS Lightsail Tokyo)
1. Create two **Ubuntu 22.04 LTS** instances in the same region:
   - **Fixed-Exit VPS**: public IP e.g. `203.0.113.20`, private VPC IP e.g. `172.26.2.20`.
   - **Entry Relay VPS**: public IP e.g. `198.51.100.10`, private VPC IP e.g. `172.26.1.10`.
2. In the **Entry Relay VPS** cloud firewall, open **`TCP 443`** (and optionally `TCP 2222` for emergency SSH fallback).

### Step 2: Set Up the Fixed-Exit VPS
SSH into your **Fixed-Exit VPS** and run:

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo RELAY_PUBLIC_IP=198.51.100.10 bash setup-exit.sh
```

This installs Xray, generates all keys, starts the service on `:443` and private `:8443`, and outputs both the exact command for your Entry Relay VPS and the `vless://` client share link.

### Step 3: Set Up the Entry Relay VPS
SSH into your **Entry Relay VPS** and run the command printed by Step 2 (using the Exit VPS's private VPC IP):

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh
```

### Step 4: Connect Your Client (v2rayN)
1. Copy the `vless://...` share link printed by `setup-exit.sh` and import it into **v2rayN**.
2. Verify your egress IP matches your **Fixed-Exit VPS** (`203.0.113.20`):
   ```bash
   export HTTPS_PROXY="http://127.0.0.1:10808"
   export HTTP_PROXY="http://127.0.0.1:10808"
   export ALL_PROXY="socks5://127.0.0.1:10808"
   curl https://ip.me
   ```

---

## Rotating the Entry Relay IP (Zero Downtime)

If you ever replace your Entry Relay VPS with a new IP (`198.51.100.99`):
1. Run `setup-relay.sh` on the new Entry Relay VPS pointing to your existing Exit VPS (`172.26.2.20:8443`).
2. On your macOS / Linux client machine, run:
   ```bash
   bash switch-relay-ip.sh 198.51.100.99 d1.awsstatic.com
   ```
   This updates `guiNDB.db` and `config.json` and hot-reloads Xray in `<200ms` without touching your Fixed-Exit VPS.

---

## License

[MIT](LICENSE).
