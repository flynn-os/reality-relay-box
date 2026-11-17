# reality-relay-box

**English** | [简体中文](README.zh-CN.md)

> **Dual-VPS (Rotatable Entry Relay + Fixed-Exit IP) VLESS + REALITY production hardening suite — engineered for AI coding workflows (Claude Code, OpenAI, etc.) that demand a rock-solid, static, scanner-invisible egress IP.**

## 📌 Prerequisite: Relationship with [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box)

This repository is the **production high-availability & anti-blocking hardening companion** to [**`surgeshi/reality-box`**](https://github.com/surgeshi/reality-box). We recommend following this progression:

1. **Starting from Scratch (Prerequisite Guide)**: If you are setting up a VPS proxy for the first time to use **Claude Code** (provisioning a VPS, installing `v2rayN`, and configuring proxy environment variables), **start with [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box) first**.
2. **When Your IP Gets Blocked / Protecting Your Static Egress IP (Upgrade to This Repo)**: On a single-VPS setup (`reality-box`), replacing a blocked IP changes your egress IP — frequently triggering Anthropic / OpenAI account risk controls. Upgrade to **`reality-relay-box`'s Decoupled Dual-VPS + 10-Layer Hardening Architecture** to keep your egress IP permanently static and invisible while making your entry IP disposable in seconds.

> [!IMPORTANT]
> **⚠️ Critical Rule: Bind a "Static IP" to BOTH VPS Instances!**
> After creating your instances in the cloud console (e.g., AWS Lightsail *Networking → Create static IP*), you **MUST manually create and attach a Static Public IP** (mandatory for the **Fixed-Exit VPS**, and strongly recommended for the **Entry Relay VPS**):
> - Cloud instances default to a **dynamic public IP** that **changes automatically when stopped, rebooted, or migrated** — immediately breaking your static egress IP (risking account flags) or disconnecting clients!
> - On AWS Lightsail, Static IPs are **100% free** while attached to a running instance. Binding a Static IP to your Entry Relay VPS also lets you rotate a blocked entry IP in 10 seconds right from the console (detach old Static IP → attach new Static IP) with zero server rebuilds and zero firewall/SSH changes.

---

## Why Upgrade from a Single-VPS Setup?

Running a single-VPS proxy creates a structural dilemma:
1. **Account Risk on Egress IP Changes**: AI platforms enforce strict risk controls when an account's egress IP shifts frequently.
2. **Entry IP Blocking**: When a single VPS acts as both entry and exit, any firewall block on the entry IP forces you to abandon your clean egress IP too.

**`reality-relay-box`** eliminates this trade-off via a **Decoupled Dual-VPS Architecture (Entry Relay VPS + Fixed-Exit VPS)** backed by **10 production-verified anti-blocking, leak-prevention, and small-memory stability measures**:
- **100% Static & Scanner-Invisible Egress IP**: Your Fixed-Exit VPS closes public `:443`, `:80`, and public `:22` (accepting proxy traffic exclusively over private VPC `:8443`), so internet scanners never see a REALITY listener on your egress IP.
- **Zero Public SSH Exposure & Zero Multi-Port Correlation**: All cross-border SSH and `autossh` reverse tunnels run strictly inside your local `127.0.0.1:10808` REALITY tunnel with **no automatic fallback to bare `:2222`/`:22`**.
- **10-Second Decoupled Entry IP Rotation**: Swapping your Entry Relay's Static IP leaves your Fixed-Exit VPS, credentials, cloud firewalls, and VPC SSH jump config completely untouched.

---

## Architecture Overview

```
[ Client (macOS / Linux Dev Machine) ]
   │  1) Single shared proxy 127.0.0.1:10808 (socks5h remote DNS + fail-closed System Proxy pin)
   │  2) VLESS + XHTTP + xmux + REALITY (SNI: cognito-idp.ap-northeast-1.amazonaws.com, Chrome FP, No Fragment)
   │     └─ xmux pooling (maxConcurrency 16-32, 30-50min graceful connection rotation — eliminates 200+ TCP bursts)
   │  3) Domestic background noise direct (chat/music), forced proxy for required webmail (e.g. 126/yeah)
   │  4) Cross-border SSH / autossh strictly inside 10808 (Zero public SSH, no bare fallback)
   ▼
[ Entry Relay VPS (Static Public 198.51.100.10 / Private VPC 172.26.1.10) ]
   │  Public firewall: ONLY IPv4 TCP :443 open (80 / 2222 / public 22 / public IPv6 CLOSED)
   │  BBR+FQ + bidirectional TCP MSS<=1280 + HAProxy (inspect-delay 2s) dual-stack SNI routing
   ▼  AWS Same-Region Private VPC (RTT ~0.15ms)
[ Fixed-Exit VPS (Static Public 203.0.113.20 / Private VPC 172.26.2.20) ]
   │  Public 443 / 80 / IPv6 CLOSED; TCP :22 restricted to 203.0.113.20/32 (hairpin) + 172.26.0.0/20 (VPC)
   │  xray-xhttp (:8444 XHTTP primary, GOMEMLIMIT=48MiB) + xray (:8443 Vision compat) [both OOMScoreAdjust=-900]
   ▼
[ Claude Code / ChatGPT / AI Dev Tools / Proxied Web (Static Egress 203.0.113.20) ]
```

*(Note: All IP addresses in this repository — `198.51.100.10`, `198.51.100.99`, `203.0.113.20`, `172.26.1.10`, `172.26.2.20`, `172.26.0.0/20` — are RFC 5737 / RFC 1918 documentation placeholders.)*

---

## 10 Production-Verified Hardening Measures

| # | Common Misconfiguration / Failure Mode | How `reality-relay-box` Fixes It |
| :--- | :--- | :--- |
| **1. SNI ↔ EC2 Subnet Mismatch** | Using `www.cloudflare.com` or even CloudFront-only domains (e.g. `d1.awsstatic.com`, `CLOUDFRONT` range) on an AWS `EC2`/Lightsail IP contradicts AWS `ip-ranges.json`, yields 7-byte empty-SNI rejection alerts, and makes 200+ multi-hour flows look unnatural against a 0-byte static edge. | Defaults to **`cognito-idp.ap-northeast-1.amazonaws.com`** (with `oidc.ap-northeast-1.amazonaws.com` alt): lives on AWS Tokyo **`EC2` compute IP ranges**, is directly reachable from China, supports TLS 1.3 + `h2`, and completes authentic Amazon TLS 1.3 handshakes on matching, empty, and random-SNI active probes (eliminating 7-byte alert signatures). |
| **2. Raw Cross-Border SSH & Bare Fallback Leaks** | Running 24/7 `autossh` to `:22`/`:2222` alongside `:443`, or writing `else exec nc %h %p` in `ProxyCommand` so SSH automatically falls back to bare `:2222` whenever `10808` blips — leaking `SSH-2.0-OpenSSH` banners from the same client IP. | [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example) locks SSH / `autossh` strictly inside `127.0.0.1:10808` with **no automatic bare `:2222`/`:22` fallback**; cloud SSH is closed to `0.0.0.0/0` via `<EXIT_PUBLIC_IP>/32 + 172.26.0.0/20` hairpin + private VPC jump. |
| **3. Exit Scanner Exposure & `:2222` Banner Correlation** | Leaving Exit `:443` open exposes your Fixed-Exit IP to Censys/Shodan REALITY scans; forwarding Entry `:2222 -> Exit:22` exposes mismatched OpenSSH patch banners across Entry `:22` and `:2222` (correlating both servers); forgetting cloud IPv6 firewalls leaves `[::]:22`/`:443` open. | Relays solely over **VPC `172.26.2.20:8444`/`8443`**; `setup-relay.sh` disables `:2222` relay by default (`ENABLE_SSH_RELAY=false`); cloud firewall rules close Exit `:443`/`:80`, Entry `:2222`/`:80`, and **all public IPv6 inbound rules** on both instances. |
| **4. Broken `send-proxy-v2` / `xver` & Delay Timeouts** | Setting `realitySettings.xver: 2` sends a PROXY header *outbound* to `dest`, causing TCP resets; a `5s` HAProxy `inspect-delay` exposes `5001ms` timeout clusters during packet loss. | Enforces `realitySettings.xver: 0` with HAProxy `inspect-delay 2s` routing `XHTTP` SNIs (`default_backend`) to `:8444` and legacy `Vision` SNIs to `:8443`. |
| **5. Client Beaconing & Silent Fail-Open Leaks** | Polling `gstatic.com` every 10s emits 8,640 fixed-interval TLS handshakes/day across the firewall; worse, watchdogs that only re-enable System Proxy when healthy leave System Proxy **OFF** during outages, causing browsers and desktop AI apps to leak domestic IPs! | [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh) and [`client/linux/v2rayn-keepalive.sh`](client/linux/v2rayn-keepalive.sh) combine **Zero-Beaconing** (`0` outbound probes/day) with **Fail-Closed Pinning** (keeping OS proxy locked to `127.0.0.1:10808` during outages; pause via `touch ~/.local/state/v2ray-proxy-watchdog.pause`). |
| **6. TCP Vision 200+ Concurrency Bursts & Multi-Hour Connections** | Plain `TCP + xtls-rprx-vision` opens a new TCP/TLS socket per flow with zero multiplexing — causing single client IPs running browsers + AI coding tools to hit 200+ concurrent flows, 17,000+ daily handshakes, and 17-hour stagnant sockets (prime GFW statistical blocking triggers); `finalmask` fragmentation also breaks SNI parsing. | Upgrades to **`VLESS + XHTTP (mode: auto) + xmux`**, collapsing 20+ concurrent requests into **1–2 HTTP/2 connections** (`maxConcurrency: "16-32"`), while `hMaxRequestTimes: "600-900"` / `hMaxReusableSecs: "1800-3000"` silently cycle underlying H2 connections without dropping upper-layer AI streams, plus **TCP BBR + FQ** and zero TLS fragmentation. |
| **7. Mobile Hotspot / 464XLAT MTU Blackholes (`-1ms`)** | AWS Nitro NICs default to `mtu 9001` while Chrome Post-Quantum `X25519MLKEM768` produces `~1,850B` `ClientHello`s. On 4G/5G hotspots (IPv6 + 464XLAT MTU `1280–1380` with dropped ICMP `Frag Needed`), `1500B` (`DF=1`) packets blackhole — causing `v2rayN` `-1ms` timeouts and hung SSH `KEX_ECDH_REPLY`. | Installs persistent `reality-tcp-mss.service` on both VPSs for ceiling-only bidirectional `SYN`/`SYN-ACK` MSS clamping (`<=1280` IPv4 / `<=1220` IPv6) plus `net.ipv4.tcp_mtu_probing=1` with zero stream drops. |
| **8. Single Shared Proxy, Noise Reduction & Anycast Safety** | Splitting into "Claude-only proxy" breaks other AI/dev tools; `socks5://` leaks DNS; blocking Cloudflare/Google GFE CIDRs breaks direct apps; domestic background apps (chat/music) needlessly inflate proxy concurrency unless bypassed while keeping specific proxied webmail (`126`/`yeah`) forced over `proxy`. | Keeps all proxy tools on `127.0.0.1:10808` with `ALL_PROXY=socks5h://127.0.0.1:10808` + `CLAUDE_CODE_PROXY_RESOLVES_HOSTS=1` + Fail-Closed System Proxy pinning; bypasses noisy domestic chat/music apps while explicitly placing required mail domains (`126.com`/`126.net`/`127.net`/`yeah.net`) on `proxy` **above** `geosite:cn`. |
| **9. Small-Memory (`512MB` / `416MiB`) OOM Immunity** | Entry-level `$3.5–$5` VPS instances have only `~416MiB` usable RAM. SSH login `landscape-sysinfo` spikes or `journald` growth can trigger the Linux OOM-killer to kill `xray`, severing all active proxy sessions. | `setup-exit.sh` sets `OOMScoreAdjust=-900` on `xray` & `xray-xhttp`, caps `xray-xhttp` with `GOMEMLIMIT=48MiB`, caps `journald` (`RuntimeMaxUse=16M`), and creates `.hushlogin` to eliminate MOTD login spikes. |
| **10. Decoupled Entry IP Rotation & Clean-IP Auto-Verifier** | Manual console swaps are slow and can accidentally pick a dirty/already-blocked recycled IP; hardcoding the Entry IP in SSH configs risks lockouts. | Anchors `vps-jump` on Fixed-Exit `203.0.113.20` and `vps-entry` on Relay private IP `172.26.1.10`. [`rotate-lightsail-ip.sh`](rotate-lightsail-ip.sh) calls AWS Lightsail APIs directly from China, retries up to 3x until `:443` passes direct reachability, releases old Static IPs (\$0 idle fee), and syncs clients. |

---

## 1. Provision Two Same-Region VPSs, Bind Static IPs & Harden Cloud Firewalls

1. Open the AWS Lightsail console (<https://lightsail.aws.amazon.com/>) and create two **Ubuntu 22.04 LTS** instances in the **same region** (e.g., Tokyo `ap-northeast-1`).
2. Under *Networking → Create static IP*, attach a **Static IP** to each instance:
   - **Fixed-Exit VPS**: Static Public IP `203.0.113.20`, Private VPC IP `172.26.2.20`.
   - **Entry Relay VPS**: Static Public IP `198.51.100.10`, Private VPC IP `172.26.1.10`.
   *(Ensure at least 1GB swap is configured on 512MB/416MiB instances.)*
3. **Target Cloud Firewall Matrix (*Networking → IPv4 / IPv6 Firewall*)**:
   > **Anti-Lockout Order**: Complete Steps 2–4 and verify both `127.0.0.1:10808` proxy connectivity and `vps-jump` / `vps-entry` VPC SSH **before** tightening `TCP 22`!

   | Instance Role | IPv4 Firewall Allowed Rules | Public Ports to Delete / Close | IPv6 Firewall |
   | :--- | :--- | :--- | :--- |
   | **Entry Relay VPS (`198.51.100.10`)** | `TCP 443` → `0.0.0.0/0` (sole public ingress)<br>`TCP 22` → `172.26.0.0/20` (VPC-only SSH) | Delete `80`, delete `2222`, remove `0.0.0.0/0` from `22` | **Close / Delete ALL** |
   | **Fixed-Exit VPS (`203.0.113.20`)** | `TCP 22` → `203.0.113.20/32` (`10808` hairpin) + `172.26.0.0/20` (VPC)<br>*(Same-account Lightsail VPC allows internal `:8443` automatically)* | **NEVER open public `443` or `80`**; remove `0.0.0.0/0` from `22` | **Close / Delete ALL** |

---

## 2. Step 1: Set Up the Fixed-Exit VPS

SSH into your **Fixed-Exit VPS** and run:

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo RELAY_PUBLIC_IP=198.51.100.10 bash setup-exit.sh
```

This configures `BBR + FQ`, `tcp_mtu_probing=1`, bidirectional `reality-tcp-mss` clamping (`<=1280` IPv4 / `<=1220` IPv6), `OOMScoreAdjust=-900` and `GOMEMLIMIT=48MiB` on `xray-xhttp` and `xray`, `journald` `16M` cap, `.hushlogin`, and Xray VLESS+REALITY side-by-side on private `:8444` (XHTTP + `xmux` primary) and `:8443` (TCP Vision legacy fallback), saving your `vless://` links to `/root/reality-client.txt` (`0600`).

---

## 3. Step 2: Set Up the Entry Relay VPS & VPC SSH Key Auth

1. SSH into your **Entry Relay VPS** and run `setup-relay.sh` pointing to the Exit VPS's **private VPC IP (`172.26.2.20`)**:

   ```bash
   git clone https://github.com/flynn-os/reality-relay-box.git
   cd reality-relay-box
   sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8444 LEGACY_PORT=8443 SNI=cognito-idp.ap-northeast-1.amazonaws.com bash setup-relay.sh
   ```

   *(`ENABLE_SSH_RELAY` defaults to `false` so `:2222` is not exposed.)*

2. **Authorize VPC SSH Jump (Before Closing Public `TCP 22`)**:
   - Ensure your workstation's `~/.ssh/id_ed25519.pub` is in `~ubuntu/.ssh/authorized_keys` (`0600`) on **both** Exit and Entry VPSs.
   - Optionally generate a VPC keypair on Exit (`ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519`), append Exit's `~/.ssh/id_ed25519.pub` to Entry's `~ubuntu/.ssh/authorized_keys`, and verify from Exit:
     ```bash
     # From Fixed-Exit VPS (203.0.113.20) -> Entry Relay Private VPC IP (172.26.1.10):
     ssh -o BatchMode=yes ubuntu@172.26.1.10 'hostname'
     ```

---

## 4. Step 3: Client Setup, Leak-Proof Env Vars & Neutral Health Checks

1. Import the `vless://...` link (`198.51.100.10:443`) into **v2rayN** and set it as the active server.
2. **Disable TLS Fragmentation**: In `v2rayN` (*Settings → Core Basic Settings*), ensure **`Enable Fragment` is unchecked** (if the GUI is open on Linux/macOS, uncheck it in the GUI window too so in-memory GUI flushes do not re-enable fragmentation).
3. Configure proxy environment variables using **`socks5h://`** (forces remote DNS resolution through the proxy — never use local-DNS `socks5://`):

   ```bash
   export HTTP_PROXY="http://127.0.0.1:10808"
   export HTTPS_PROXY="http://127.0.0.1:10808"
   export ALL_PROXY="socks5h://127.0.0.1:10808"
   export CLAUDE_CODE_PROXY_RESOLVES_HOSTS="1"
   ```

4. **Verify via Neutral Endpoints** (always test through `127.0.0.1:10808` using neutral URLs like `gstatic.com/generate_204` and `ip.me` — never probe AI platform domains directly):

   ```bash
   curl -sS -o /dev/null -w "HTTP=%{http_code}\n" -x http://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS -o /dev/null -w "SOCKS5H=%{http_code}\n" -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS -x socks5h://127.0.0.1:10808 https://ip.me && echo
   ```
   Both checks should return `204` and output your Fixed-Exit Static IP (`203.0.113.20`).

---

## 5. Client Daemons & Zero-Public-SSH Jump Configuration

### 5.1 macOS Zero-Beaconing + Fail-Closed Watchdogs (`client/macos/`)
- [`client/macos/v2ray-keepalive.sh`](client/macos/v2ray-keepalive.sh): Relaunches `v2rayN` if the GUI exits or `10808` stops listening.
- [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh): Checks local `networksetup` state every 10s with **zero network traffic** and **unconditionally pins System Proxy to `127.0.0.1:10808`** (fail-closed during outages so browsers and Electron/AI desktop apps never leak direct domestic connections; pause manually via `touch ~/.local/state/v2ray-proxy-watchdog.pause`).

### 5.2 Linux Session-Safe + Fail-Closed Watchdog (`client/linux/`)
- [`client/linux/v2rayn-keepalive.sh`](client/linux/v2rayn-keepalive.sh): Uses zero-traffic kernel socket checks (`ss -tlnH sport = :10808`) and defers disruptive restarts while an active Claude Code session is running; also performs zero-beaconing GNOME `gsettings` fail-closed system proxy pinning to `127.0.0.1:10808` (preserving custom `ignore-hosts`, with `~/.local/state/v2ray-proxy-watchdog.pause` pause support).

### 5.3 Zero-Public-SSH Jump & `autossh` Config (`client/ssh/ssh-config.example`)
Configure `~/.ssh/config` from [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example), verify `ssh vps-jump` and `ssh vps-entry`, and then lock down your cloud firewalls per Section 1:
- **`ssh vps-jump` / `ssh vps-exit`**: Dials `203.0.113.20:22` inside `127.0.0.1:10808`. On 1:1 NAT cloud networks (AWS Lightsail), Exit Xray hairpins via `203.0.113.20/32` into Exit `:22` — keeping `TCP 22` closed to `0.0.0.0/0` while avoiding client Xray's `geoip:private` / `geosite:private` (`domain:internal`) direct-routing rules!
- **`ssh vps-entry`**: Hops through `vps-jump` over VPC (`172.26.1.10:22`), surviving Entry Static IP rotations with zero edits.
- **Linux `autossh` (`Host tunnel-vps`)**: Never pass `-w <sec>` to Ubuntu/Debian `/bin/nc.openbsd` inside `ProxyCommand` — OpenBSD `nc` treats `-w` as an **idle data timeout** and will sever idle `autossh -N -R` tunnels!

---

## 6. Rotating the Entry Relay IP (SOP)

Whenever an Entry IP is blocked, **NEVER change your Fixed-Exit IP (`203.0.113.20`), UUID, REALITY keys, or ShortID**. Prefer **Method A**:

### Method A (Recommended): Automated Clean-IP Swap via [`rotate-lightsail-ip.sh`](rotate-lightsail-ip.sh)
When Entry `:443` is confirmed blocked, run [`rotate-lightsail-ip.sh`](rotate-lightsail-ip.sh) directly against the AWS Lightsail regional API (in-memory hidden credentials, zero disk persistence): it allocates a new Static IP, tests TCP `:443` from China (retrying up to 3x if an inherited IP is already blocked), releases the old Static IP (\$0 idle fee), and updates both local and peer client configs:
```bash
RELAY_PRIVATE_IP=172.26.1.10 bash rotate-lightsail-ip.sh
```
*(Manual alternative: swap the Static IP `198.51.100.10 -> 198.51.100.99` on the same Relay instance in the console with zero firewall/SSH changes, then run `bash switch-relay-ip.sh 198.51.100.99 cognito-idp.ap-northeast-1.amazonaws.com`.)*

### Method B: Provision a New Entry Relay Instance
1. Create a new Relay instance in the same region, bind Static IP `198.51.100.99`, and run `sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8444 LEGACY_PORT=8443 SNI=cognito-idp.ap-northeast-1.amazonaws.com bash setup-relay.sh`.
2. Add SSH public keys, apply the Entry firewall matrix from Section 1 (`TCP 443` public, `TCP 22` VPC-only), update `Host vps-entry` `HostName` if the private VPC IP changed, and run `bash switch-relay-ip.sh 198.51.100.99 cognito-idp.ap-northeast-1.amazonaws.com` on clients.

> **Active Stream Safety**: If the old Entry IP is already dead, running `switch-relay-ip.sh` restarts local `xray` immediately. For preventive rotation during live long-running tasks, wait until sessions are idle or use a dual-port hot cutover (`10808`/`10810`) — if `switch-relay-ip.sh` detects multiple `xray` PIDs or a hot-transition config, it updates configs (`0600`) without killing active `xray` cores unless `--force-restart` is passed (pass `--no-restart` to only update disk configs).

---

## 7. Troubleshooting Runbook

If you encounter `-1ms` timeouts in `v2rayN`, proxy failures, or SSH issues, follow steps **7.1 → 7.6 in strict order** (always test using `gstatic.com/generate_204` and `ip.me` via `127.0.0.1:10808` — never probe AI domains directly):

### 7.1 Local `127.0.0.1:10808` Core, Fragmentation & Hot-Redirect State
1. **Check listener & neutral proxy probes**:
   ```bash
   # macOS listener check (on Linux: ss -tlnp 'sport = :10808')
   lsof -nP -iTCP:10808 -sTCP:LISTEN
   curl -v --max-time 8 -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS --max-time 8 -x socks5h://127.0.0.1:10808 https://ip.me && echo
   ```
2. **Verify TLS fragmentation is OFF**: Ensure `"EnableFragment": false` in `guiConfigs/guiNConfig.json` and no `"finalmask"` object in `binConfigs/config.json` (uncheck `Enable Fragment` in any running `v2rayN` GUI so memory flushes do not re-enable it).
3. **Check watchdog pause file & Linux dual-core redirects**:
   - macOS: Check `ls -la ~/.local/state/v2ray-proxy-watchdog.pause` and `scutil --proxy` (`HTTP`/`HTTPS`/`SOCKS` -> `127.0.0.1:10808`).
   - Linux: If using a temporary `iptables -t nat OUTPUT` redirect (e.g. redirecting `NEW` `127.0.0.1:10808` connections to `10809`), confirm the target `10809` `xray` core and its watchdog are running.

### 7.2 Mobile Hotspot / 464XLAT `-1ms` Stalls
If Wi-Fi works but 4G/5G mobile hotspots stall or report `-1ms`, verify bidirectional MSS clamping and MTU probing on **both** Relay and Exit VPSs:
```bash
systemctl is-active reality-tcp-mss
sudo iptables -t mangle -S | grep reality-tcp-mss
sudo ip6tables -t mangle -S | grep reality-tcp-mss
sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_congestion_control
```
Confirm `TCPMSS --set-mss 1280` (IPv4) / `1220` (IPv6) and `net.ipv4.tcp_mtu_probing = 1`. Re-apply anytime with zero stream drops via `sudo systemctl restart reality-tcp-mss`.

### 7.3 Entry Relay `:443` Reachability Check
Test raw TCP handshake from your client directly to Entry `:443` (bypassing `10808`):
```bash
/usr/bin/nc -vz -G 4 198.51.100.10 443
```
- If `198.51.100.10:443` times out across networks while the Relay instance is running and `TCP 443` is open in the cloud firewall, the Entry IP is blocked → rotate **only** the Entry Static IP per **Section 6 (Method A)**.

### 7.4 Fixed-Exit VPS OOM or `xray` / `xray-xhttp` Service Check
Log into Exit via `ssh vps-jump` (or use cloud console Browser SSH if `10808` is down):
```bash
systemctl status xray xray-xhttp --no-pager
free -m
sudo dmesg -T | grep -iE 'oom|killed process' | tail -n 20
cat /proc/$(pidof xray | awk '{print $1}')/oom_score_adj
```
Confirm `xray` (`:8443`) and `xray-xhttp` (`:8444`) are `active (running)`, swap is active, and `oom_score_adj` equals **`-900`**. Note: when using `XHTTP`, client `vless` `users[].flow` **must be omitted/empty** (never leave `xtls-rprx-vision` set), otherwise connections fail with `SSL_ERROR_SYSCALL`.

### 7.5 Entry HAProxy & Private VPC `:8444` / `:8443` Path Check
From Exit, SSH over VPC to Entry (`ssh ubuntu@172.26.1.10`) and verify HAProxy and VPC connectivity to `172.26.2.20:8444` (XHTTP) and `:8443` (Vision):
```bash
systemctl status haproxy --no-pager
nc -vz -w 3 172.26.2.20 8444
nc -vz -w 3 172.26.2.20 8443
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```
- **Common Pitfall**: Verify `frontend reality_in` in `/etc/haproxy/haproxy.cfg` routes `XHTTP` SNIs (`cognito-idp.ap-northeast-1.amazonaws.com`, etc.) and `default_backend` to **`172.26.2.20:8444`**, and any legacy `Vision` SNIs (`d1.awsstatic.com`, etc.) to `172.26.2.20:8443`.

### 7.6 Cross-Border SSH (`vps-jump` / `vps-entry`) & `autossh` Pitfalls
1. **`ssh vps-jump` fails while `10808` is healthy**: Verify Exit's IPv4 firewall on `TCP 22` includes Exit's own Static Public IP **`203.0.113.20/32`** (required for 1:1 cloud NAT hairpinning) plus `172.26.0.0/20`.
2. **Do NOT replace `203.0.113.20` in `vps-jump` with `127.0.0.1`, `172.26.2.20`, or `*.compute.internal`**: Standard client `v2rayN` routing sends `geoip:private` and `geosite:private` (which includes `domain:internal`) to `direct` locally instead of through `10808`.
3. **Linux `autossh` drops periodically**: Ensure `Host tunnel-vps` on Ubuntu/Debian omits `-w` in `ProxyCommand nc -X 5 -x 127.0.0.1:10808 203.0.113.20 22` (`nc.openbsd` `-w` is an idle timeout that kills quiet `autossh -N -R` tunnels).

---

## License

[MIT](LICENSE).
