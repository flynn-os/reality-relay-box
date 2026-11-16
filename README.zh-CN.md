# reality-relay-box

[English](README.md) | **简体中文**

> **双 VPS（可轮换入口中转 + 固定出口 IP）VLESS + REALITY 生产级抗封锁加固套件 —— 专为 Claude Code / OpenAI 等对出口 IP 纯净度与稳定性高度敏感的 AI 开发工作流打造。**

## 📌 前置必读：与 [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box) 的关系

本项目是 [**`surgeshi/reality-box`**](https://github.com/surgeshi/reality-box) 的**进阶高可用与生产级抗封锁加固版**，建议搭配阅读与使用：

1. **新手从零搭建（前置教程）**：如果你刚开始准备购买 VPS、从零配置客户端（`v2rayN`）以使用 **Claude Code**，请**先阅读并参照 [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box)** 完成基础入门了解。
2. **遇到 IP 被墙 / 需要死守固定出口 IP（平滑升级本方案）**：单机版 `reality-box` 在高强度使用 AI 编码工具或跨国 SSH 时，一旦 VPS 的 IP 被防火墙阻断（被墙），更换机器 IP 就会导致**出口 IP 变动**，极易触发 Anthropic / OpenAI 的账号风控。此时即可直接切换到本项目的 **“双机解耦 + 10 大生产级抗封锁与高可用加固方案”**。

> [!IMPORTANT]
> **⚠️ 核心铁律：两台 VPS 都必须手动绑定“静态公网 IP（Static IP）”！**
> 在云厂商控制台（如 AWS Lightsail 的 `Networking` → `Create static IP`）创建实例后，**必须第一时间手动申请并绑定“静态公网 IP（Static IP）”**（**固定出口 VPS** 强制必须绑定，**入口中转 VPS** 强烈建议绑定）：
> - 云服务器默认分配的公网 IP 是**动态 IP**，一旦实例关机重启或底层宿主机维护，公网 IP 就会自动改变，直接导致出口 IP 突变触发风控封号，或客户端失联！
> - 在 AWS Lightsail 中，绑定在运行中实例上的 Static IP **完全免费**；且给入口中转机绑定 Static IP 后，日后如需换入口 IP，只需在控制台**解绑旧静态 IP → 绑定新静态 IP** 即可秒级完成，无需重装机器或改云防火墙。

---

## 为什么需要这套进阶加固方案？

在使用单台 VPS 搭建代理时，常面临一个两难困境：
1. **AI 平台风控封号**：Anthropic（Claude Code）、OpenAI 等平台对出口 IP 频繁切换极为敏感；
2. **单机入口特征暴露易被封**：单机同时跑代理与 SSH 时，一旦入口 IP 被封，就不得不连同出口 IP 一起更换。

本项目通过 **“入口中转（Relay VPS）+ 固定出口（Exit VPS）”双机解耦架构** 结合 **10 项经过现网验证的深度抗封锁、防泄漏与小内存防崩加固**，彻底解决这一痛点：
- **出口 IP 永久固定且对全网隐身**：固定出口 VPS 关闭公网 `:443`/`:80` 与公网 `:22`（仅接受 VPC 内网 `:8443` 转发），全球扫描器无法识别其为代理节点，所有出站流量永远从同一个干净的静态 IP 发出；
- **零公网 SSH 暴露与多端口零关联**：跨国管理 SSH 与 `autossh` 反向隧道 100% 封装进本地 `127.0.0.1:10808` REALITY 隧道，禁用裸 `:2222`/`:22` 自动回退，彻底消除同源多端口关联与异构 SSH 横幅泄露；
- **入口随时秒级轮换**：更换入口机静态 IP 时，出口机、UUID/REALITY 密钥、云防火墙与入口 VPC 跳板配置全部无需改动，一行 `switch-relay-ip.sh` 即可切换。

---

## 架构全景图

```
[ 本机 macOS / Linux 开发机 ]
   │  1) 全工具共享单一本地代理 127.0.0.1:10808 (socks5h 远端解析 + 系统代理失败关闭锁定)
   │  2) VLESS + REALITY (SNI: d1.awsstatic.com, Chrome 指纹, 禁用 TLS 分片)
   │  3) 跨墙 SSH / autossh 严格封装进 10808 隧道内 (公网零 SSH 暴露, 无裸端口自动回退)
   ▼
[ 入口中转 VPS (Relay, 静态公网 198.51.100.10 / 私网 172.26.1.10) ]
   │  公网仅放行 IPv4 TCP :443 (关闭 80 / 2222 / 公网 22 / 公网 IPv6)
   │  BBR+FQ + 双向 TCP MSS<=1280 (热点防卡死) + HAProxy SNI 透传转发
   ▼  AWS 同区域 VPC 内网 (RTT ~0.15ms)
[ 固定出口 VPS (Exit, 静态公网 203.0.113.20 / 私网 172.26.2.20) ]
   │  公网关闭 443 / 80 / 公网 IPv6; TCP :22 仅允许 203.0.113.20/32 (10808 自回环) + 172.26.0.0/20 (VPC)
   │  Xray-core 监听内网 172.26.2.20:8443 (xver=0, OOMScoreAdjust=-900 免死保护)
   ▼
[ Claude Code / ChatGPT / AI 工具 / 需代理开发与网页流量 (固定出口 203.0.113.20) ]
```

*(注：全文所涉 `198.51.100.10`、`198.51.100.99`、`203.0.113.20`、`172.26.1.10`、`172.26.2.20`、`172.26.0.0/20` 均为 RFC 5737 / RFC 1918 标准文档示例地址。)*

---

## 10 大生产级抗封锁、防泄漏与高可用加固设计

| 编号 | 传统配法的常见破绽 / 故障根因 | 本项目的内置加固方案 |
| :--- | :--- | :--- |
| **1. 伪装域名 ASN 归属冲突** | 在 AWS 机器上把 `SNI`/`dest` 设为 `www.cloudflare.com`。被动 DPI 一眼识破 AWS IP（AS16509）承载 Cloudflare 域名（AS13335），且空 SNI 主动探测会直接吐出异网证书。 | 默认采用与 AWS 同属 `AS16509`、支持 TLS 1.3 + H2 的 **`d1.awsstatic.com`**：被动审查 ASN 100% 吻合；无 SNI 空探测拒绝握手，带 SNI 探测返回正宗 `Amazon RSA 2048 M04` 证书。 |
| **2. 跨墙裸连 SSH 与自动裸回退泄露** | 客户端一边高并发连 `:443`，一边裸连 `:22`/`:2222` 跑 `autossh`；或在 `ProxyCommand` 中写 `else exec nc %h %p`，一旦本地代理抖动就自动向公网 `:2222` 发送明文 `SSH-2.0-OpenSSH` 握手，触发多端口关联封禁。 | [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example) 将跨国 SSH / `autossh` 严格锁定在 `127.0.0.1:10808` 隧道内（无裸 `:2222`/`:22` 自动回退）；云防火墙对 `0.0.0.0/0` 彻底关闭 SSH，仅利用 `<EXIT_PUBLIC_IP>/32 + 172.26.0.0/20` 支持 `10808` 隧道自回环与 VPC 跳板登录。 |
| **3. 出口公网扫描暴露与 `:2222` 横幅关联** | 出口机公网敞开 `:443` 被全球扫描器标记为代理；入口机用 HAProxy 把公网 `:2222` 转发到出口 `:22`，导致同一入口 IP 的 `:22` 与 `:2222` 暴露不同小版本的 OpenSSH 横幅，直接暴露双机转发关系；且常遗漏云平台独立的 IPv6 防火墙。 | HAProxy 仅走 **VPC 私网 `172.26.2.20:8443`** 转发；`setup-relay.sh` 默认关闭 `:2222` 转发（`ENABLE_SSH_RELAY=false`）；云防火墙同步关闭出口 `:443`/`:80`、入口 `:2222`/`:80` 以及两台机器的全部公网 IPv6 入站规则。 |
| **4. 误配 `send-proxy-v2` 与 `xver`** | 在 HAProxy 加 `send-proxy-v2` 同时把 Xray `realitySettings.xver` 设为 `2`（`xver` 实为向伪装目标网站发送 PROXY 头），导致目标站立即 RST 重置连接。 | 严格保持 `realitySettings.xver: 0` 原生透传，配合 HAProxy `req_ssl_hello_type 1` 与 SNI 识别转发。 |
| **5. 客户端 10 秒机械心跳与断流直连泄漏** | 传统守护脚本每 10 秒跨墙 `curl` 一次（每天 8,640 次等间隔信标指纹）；且一旦代理故障就不恢复系统代理，导致浏览器与桌面 AI 客户端静默退回国内宽带直连，暴露真实国内 IP。 | [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh) 采用 **零心跳（Zero-Beaconing）+ 失败关闭锁定（Fail-Closed Pinning）**：纯本地检查 `networksetup`（0 网络流量），且即使 `10808` 故障也强制将系统代理锁定在 `127.0.0.1:10808`，使桌面应用安全报错而不直连泄漏（可通过 `touch ~/.local/state/v2ray-proxy-watchdog.pause` 手动暂停）。 |
| **6. 首包固定分片特征与拥塞重传** | 对 REALITY 开启 `finalmask`（`tlshello` 50–100B 切片），不仅制造明显非浏览器特征，还会打碎首包导致中转层 HAProxy 无法解析完整 TLS SNI！ | 自动关闭客户端 `EnableFragment` 并清除 `finalmask`；双机默认开启 **TCP BBR + FQ** 并将 Xray 日志收紧为 `warning`。 |
| **7. 手机热点 / 464XLAT 路径 MTU 黑洞（`-1ms` 卡死）** | AWS Nitro 网卡默认 `mtu 9001`，而现代 Chrome 后量子 `X25519MLKEM768` 使 `ClientHello` 达 `~1,850B`。切到 4G/5G 手机热点（IPv6 + 464XLAT 实际 MTU `1280~1380` 且丢弃 ICMP 分片差错）时，大包被静默黑洞丢弃，导致 `v2rayN` `-1ms`、SSH 卡死在 `KEX_ECDH_REPLY`。 | 双机内置持久化 `reality-tcp-mss.service`，对 `SYN`/`SYN-ACK` 做**双向只削峰不拔高**的 MSS 钳制（IPv4 `<=1280` / IPv6 `<=1220`）并开启 `net.ipv4.tcp_mtu_probing=1`，热更新零断流。 |
| **8. 单一共享链路防泄漏与 Anycast 零误伤** | 把唯一代理拆成“仅某单一域名走代理”会导致其他需代理的 AI 工具与开发网站瘫痪；而用本地 `socks5://` 会把敏感域名发给国内 DNS 抢答污染；若在本地防火墙粗暴封禁 Cloudflare / Google GFE 等共享 Anycast 网段，又会误杀直连业务软件。 | 保持单一 `127.0.0.1:10808` 承载全部需代理工具，统一使用 **`ALL_PROXY=socks5h://127.0.0.1:10808`**（远端解析 DNS）+ `CLAUDE_CODE_PROXY_RESOLVES_HOSTS=1` 配合系统代理失败关闭锁定，既杜绝 DNS/IP 直连泄漏，又对共享 Anycast CDN 零误伤。 |
| **9. 小内存实例（512MB / 416MiB）OOM 免死保护** | 入门级 `$3.5~$5` 云主机可用物理内存常仅约 `416MiB`。SSH 登录触发 Ubuntu `landscape-sysinfo` 或 `journald` 日志暴涨时，Linux OOM-killer 极易直接强杀 `xray`，造成全线断流。 | `setup-exit.sh` 自动为 `xray` 注入 `OOMScoreAdjust=-900` 免死金牌，限制 `journald` 内存占用（`RuntimeMaxUse=16M`），并创建 `.hushlogin` 消除登录内存尖峰；同时避免在 416MiB 出口机上额外部署高内存后台守护进程。 |
| **10. 入口静态 IP 解耦轮换（免改防火墙与 SSH）** | 若 SSH 配置或云防火墙硬编码了入口机公网 IP，每次换入口 IP 都容易改漏锁死自己。 | `vps-jump` 锚定固定出口 `203.0.113.20`，`vps-entry` 锚定入口机 **VPC 私网 IP `172.26.1.10`**（经出口内网跳板登录）。在控制台给入口机换绑新静态公网 IP 时，云防火墙与 SSH 配置**零改动**。 |

---

## 1. 准备两台同区域 VPS、绑定静态 IP 与配置云防火墙（以 AWS Lightsail 为例）

1. 登录 AWS Lightsail 控制台：<https://lightsail.aws.amazon.com/>
2. 在**同一个区域**（例如东京 `ap-northeast-1`）创建两台 **Ubuntu 22.04 LTS** 实例，并立即在 `Networking` 页面绑定 **Static IP**：
   - **固定出口机（Exit VPS）**：绑定静态公网 IP（示例 `203.0.113.20`），记下私网 IP（示例 `172.26.2.20`）。
   - **入口中转机（Relay VPS）**：绑定静态公网 IP（示例 `198.51.100.10`），记下私网 IP（示例 `172.26.1.10`）。
   *(建议至少为 416MiB 小内存实例配置 1GB Swap。)*
3. **最终云防火墙收口矩阵（Networking → IPv4 / IPv6 Firewall）**：
   > **防锁死顺序提醒**：首次部署执行完第 2、3、4 步并确认本地 `127.0.0.1:10808` 代理与下述 VPC 跳板 SSH 均连通后，再按此表收紧 `TCP 22`！

   | 实例角色 | IPv4 防火墙放行规则（白名单） | 必须删除 / 关闭的公网端口 | IPv6 防火墙 |
   | :--- | :--- | :--- | :--- |
   | **入口中转机（Relay `198.51.100.10`）** | `TCP 443` → `0.0.0.0/0`（唯一公网代理入口）<br>`TCP 22` → `172.26.0.0/20`（仅允许同 VPC 内网 SSH） | 删除 `80`、删除 `2222`、关闭对 `0.0.0.0/0` 的 `22` | **全部关闭 / 删除** |
   | **固定出口机（Exit `203.0.113.20`）** | `TCP 22` → `203.0.113.20/32`（`10808` 隧道自回环）+ `172.26.0.0/20`（VPC 内网）<br>*(注：同账号 Lightsail VPC 内网默认互通 `:8443`)* | **严禁对公网开放 `443` 或 `80`**；关闭对 `0.0.0.0/0` 的 `22` | **全部关闭 / 删除** |

---

## 2. 第一步：在【固定出口 VPS】上运行一键安装脚本

SSH 登录到**固定出口 VPS（Exit VPS）**，克隆本仓库并执行 `setup-exit.sh`（传入入口机静态公网 IP 以便直接生成最终客户端链接）：

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo RELAY_PUBLIC_IP=198.51.100.10 bash setup-exit.sh
```

脚本会自动完成：
1. 开启内核 `BBR + FQ`、`tcp_mtu_probing=1` 与持久化双向 TCP MSS 钳制（IPv4 `<=1280` / IPv6 `<=1220`）；
2. 为 `xray.service` 写入 `OOMScoreAdjust=-900` 免死保护、限制 `journald` 内存（`16M`）并生成 `.hushlogin`；
3. 安装 Xray-core，生成 UUID、X25519 密钥对与 ShortID，监听内网 `:8443`（及本机 `:443`，公网由云防火墙屏蔽）；
4. 输出下一步入口机安装命令与客户端 `vless://` 链接（保存在 `/root/reality-client.txt`，权限 `0600`）。

---

## 3. 第二步：在【入口中转 VPS】上运行一键安装脚本并打通 VPC 跳板

1. SSH 登录到**入口中转 VPS（Relay VPS）**，将 `EXIT_HOST` 设为出口机的 **VPC 私网 IP（`172.26.2.20`）** 执行：

   ```bash
   git clone https://github.com/flynn-os/reality-relay-box.git
   cd reality-relay-box
   sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh
   ```

   *(默认 `ENABLE_SSH_RELAY=false`，不再暴露易被关联识别的 `:2222` 端口。)*

2. **打通「出口机 → 入口机」VPC 内网 SSH 免密与本机公钥授权**（在收紧入口公网 `:22` 前完成）：
   - 确保你本机的 `~/.ssh/id_ed25519.pub` 已同时存在于出口机与入口机的 `~ubuntu/.ssh/authorized_keys`（权限 `0600`）；
   - 在**出口机**上生成一把专用于 VPC 内网运维的密钥（可选，便于从出口机直接排查入口机），将其 `.pub` 追加进**入口机** `~ubuntu/.ssh/authorized_keys`，并在出口机上测试：
     ```bash
     # 在出口机 (203.0.113.20) 上验证经 VPC 私网登录入口机 (172.26.1.10)：
     ssh -o BatchMode=yes ubuntu@172.26.1.10 'hostname'
     ```

---

## 4. 客户端连接、防泄漏环境变量与中性探针校验

1. 复制 `setup-exit.sh` 生成的 `vless://...` 链接（确认地址为入口机 `198.51.100.10:443`），导入 **v2rayN** 并设为活动服务器。
2. **关键检查**：在 `v2rayN` *设置 → 参数设置 → Core 基础设置* 中，**取消勾选 `启用分片 (Enable Fragment)`**（Linux/macOS 修改后确保图形界面保存，避免 GUI 内存状态回写重新开启分片）。
3. 在终端配置（如 `~/.zshrc` / `~/.zprofile`）及客户端环境中统一使用 **`socks5h://`**（强制由代理解析域名，严禁写成本地解析的 `socks5://`）：

   ```bash
   export HTTP_PROXY="http://127.0.0.1:10808"
   export HTTPS_PROXY="http://127.0.0.1:10808"
   export ALL_PROXY="socks5h://127.0.0.1:10808"
   export CLAUDE_CODE_PROXY_RESOLVES_HOSTS="1"
   ```

4. **中性域名健康检查**（日常连通性自检一律透过 `127.0.0.1:10808` 访问 `gstatic.com` 与 `ip.me` 等中性地址，不要直连或用 AI 平台域名当探针）：

   ```bash
   curl -sS -o /dev/null -w "HTTP=%{http_code}\n" -x http://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS -o /dev/null -w "SOCKS5H=%{http_code}\n" -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS -x socks5h://127.0.0.1:10808 https://ip.me && echo
   ```
   预期返回两次 `204`，且出口 IP 为固定出口机静态 IP **`203.0.113.20`**。

---

## 5. 进阶加固：客户端常驻守护、失败关闭锁定与零暴露 SSH 跳板

### 5.1 macOS 零心跳 + 失败关闭系统代理守护（`client/macos/`）
- [`client/macos/v2ray-keepalive.sh`](client/macos/v2ray-keepalive.sh)：当 `v2rayN` 意外退出或 `10808` 无监听时自动拉起；
- [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh)：每 10 秒做纯本地 `networksetup` 检查（0 网络流量，零跨墙心跳），一旦系统代理被其他软件清除或因进程异常关闭，**无条件将其锁定回 `127.0.0.1:10808`**（失败关闭，杜绝浏览器与桌面应用静默直连泄漏；如需临时手动切其他代理，执行 `touch ~/.local/state/v2ray-proxy-watchdog.pause` 暂停，`rm` 该文件即恢复）。

### 5.2 Linux 开发机防断流守护（`client/linux/`）
- [`client/linux/v2rayn-keepalive.sh`](client/linux/v2rayn-keepalive.sh)：基于本地内核 `ss -tlnH sport = :10808` 检测（零探测流量），内置 **活跃 AI 会话保护**——检测到活跃 Claude Code 会话时推迟破坏性重启，防止长任务中途 `ECONNRESET`。

### 5.3 零公网暴露 SSH 跳板、VPC 级联与 `autossh` 反向隧道（`client/ssh/ssh-config.example`）
按照 [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example) 配置 `~/.ssh/config` 后，即可在第 1 节云防火墙彻底关闭公网 `22`/`2222`/`443(出口)`：
- **`ssh vps-jump`（或 `ssh vps-exit`）**：经本地 `127.0.0.1:10808` 连接 `203.0.113.20:22`。在 AWS Lightsail 等 1:1 NAT 云网络中，出口机 Xray 出站拨号自身公网 IP `203.0.113.20:22` 会自回环命中云防火墙白名单 `203.0.113.20/32`，既对公网 `0.0.0.0/0` 100% 隐身，又避开了客户端 `v2rayN` 默认将 `127.0.0.1`、`172.26.x.x`（`geoip:private`）和 `*.internal`（`geosite:private`）分流为本地直连的陷阱！
- **`ssh vps-entry`**：通过 `ProxyCommand ssh -W %h:%p -o BatchMode=yes vps-jump` 从出口机走 VPC 内网直达入口机 `172.26.1.10:22`。
- **Linux `autossh` 反向隧道（`Host tunnel-vps`）**：注意在 Ubuntu/Debian 上 `/bin/nc.openbsd` 的 `-w <秒>` 参数是**空闲无数据超时（Idle Timeout）**，切勿在 `autossh -N -R` 的 `ProxyCommand` 中传 `-w`，否则空闲隧道会定时断开；应使用 SSH 自身的 `ConnectTimeout 20` 控制建连超时。

---

## 6. 日常运维：如何更换入口中转 VPS 的 IP？

无论何时更换入口 IP，**固定出口 VPS（`203.0.113.20`）、UUID、REALITY 密钥与 ShortID 一律严禁改动**。推荐优先采用 **方式 A**：

### 方式 A（强烈推荐）：在原入口实例上直接换绑静态 IP（10 秒完成，免重装）
1. 在云控制台（如 Lightsail `Networking`）将旧静态 IP `198.51.100.10` 从入口机解绑删除，立即创建一个新静态 IP（如 `198.51.100.99`）绑定到**同一台**入口机上：
   - **入口机服务无需重装**，**云防火墙规则无需修改**，**`~/.ssh/config`（`vps-jump` / `vps-entry`）也无需修改**！
2. 在你的客户端机器上执行：
   ```bash
   bash switch-relay-ip.sh 198.51.100.99 d1.awsstatic.com
   ```

### 方式 B：新建一台入口中转实例
1. 创建新同区域实例、绑定新静态 IP `198.51.100.99`，运行 `sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh`；
2. 写入 SSH 公钥并按第 1 节收紧新入口机防火墙（仅公网放行 `TCP 443`，`TCP 22` 限 `172.26.0.0/20`）；若新入口机私网 IP 变了，同步更新 `~/.ssh/config` 中 `Host vps-entry` 的 `HostName`；
3. 在客户端执行 `bash switch-relay-ip.sh 198.51.100.99 d1.awsstatic.com`。

> **无感切换说明**：若旧入口 IP 已被阻断，直接运行 `switch-relay-ip.sh` 重启本地 `xray` 即可恢复；若属于预防性换 IP 且本机正跑着不能断的长连接，可等任务空闲后执行，或采用双端口（如 `10808`/`10809`）热切换——当脚本检测到本机存在多核热过渡态时，默认只安全更新磁盘配置（`0600`）而不强杀进程（除非显式传入 `--force-restart`）。

---

## 7. 故障排查手册（Troubleshooting Runbook）

遇到 `v2rayN` 测速 `-1ms`、代理不通或跨墙 SSH 异常时，请严格**按以下 1 → 6 顺序逐层定位**（全程仅用 `gstatic.com/generate_204` 与 `ip.me` 验证，切勿拿 AI 域名直连探测）：

### 7.1 第一步：检查本机 `127.0.0.1:10808`、分片配置与过渡态规则
1. **确认本地监听与中性健康检查**：
   ```bash
   # macOS 查 10808 监听进程；Linux 可用 ss -tlnp 'sport = :10808'
   lsof -nP -iTCP:10808 -sTCP:LISTEN
   curl -v --max-time 8 -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204
   curl -sS --max-time 8 -x socks5h://127.0.0.1:10808 https://ip.me && echo
   ```
2. **确认已关闭 TLS 分片**：检查客户端 `guiConfigs/guiNConfig.json` 中 `"EnableFragment": false`，且 `binConfigs/config.json` 的 `streamSettings` 中**不含** `"finalmask"`（若 `v2rayN` 图形界面仍开着，务必在 GUI 内取消勾选分片，防止内存配置回写覆盖磁盘）。
3. **macOS 系统代理暂停标记与 Linux 热过渡态检查**：
   - macOS：确认不存在残留的手动暂停文件 `ls -la ~/.local/state/v2ray-proxy-watchdog.pause`，并用 `scutil --proxy` 核对 `HTTPEnable/HTTPSEnable/SOCKSEnable` 均为 `1`（指向 `127.0.0.1:10808`）。
   - Linux：若曾配置过无感双核热切换（如 `iptables -t nat -S OUTPUT` 中将 `127.0.0.1:10808` 的 `NEW` 连接 `REDIRECT` 到 `10809`），务必确认目标端口（如 `10809`）上的 `xray` 进程存活监听，否则新连接会被内核重定向到死端口。

### 7.2 第二步：排查手机热点 / 464XLAT 路径 MTU 黑洞（典型症状：切热点后 `-1ms`）
若 Wi-Fi 正常但切到 4G/5G 手机热点出现 TLS 握手超时或 `-1ms`，登录入口机与出口机确认双向 MSS 钳制与 PMTUD 探测仍在生效：
```bash
systemctl is-active reality-tcp-mss
sudo iptables -t mangle -S | grep reality-tcp-mss
sudo ip6tables -t mangle -S | grep reality-tcp-mss
sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_congestion_control
```
预期可见 `PORTS=22,443,...` 的 `TCPMSS --set-mss 1280`（IPv4）与 `1220`（IPv6），且 `net.ipv4.tcp_mtu_probing = 1`。若规则被其他防火墙工具冲掉，执行 `sudo systemctl restart reality-tcp-mss`（零断流即时恢复）。

### 7.3 第三步：判断入口 IP `:443` 是否被阻断
从本机直接探测入口机公网 `TCP 443` 三次握手（不经过本地代理）：
```bash
/usr/bin/nc -vz -G 4 198.51.100.10 443
```
- 若本机 Wi-Fi 与手机热点均 `Operation timed out`，而云控制台显示入口实例运行正常且防火墙放行了 `TCP 443`，说明入口静态 IP 已被阻断 → 按 **第 6 节（方式 A）** 仅更换入口静态 IP，**切勿改动固定出口机 IP 与密钥**。

### 7.4 第四步：排查固定出口 VPS 内存 OOM 或 `xray` 异常
通过 `ssh vps-jump` 登录出口机（若代理已断，可在云控制台临时开启浏览器 SSH / `lightsail-connect` 登录出口机）：
```bash
systemctl status xray --no-pager
free -m
sudo dmesg -T | grep -iE 'oom|killed process' | tail -n 20
cat /proc/$(pidof xray)/oom_score_adj
```
- 确认 `xray` 为 `active (running)`、Swap 已挂载启用，且 `oom_score_adj` 为 **`-900`**。若未生效，检查 `/etc/systemd/system/xray.service.d/oom-protect.conf`。

### 7.5 第五步：排查入口 HAProxy 与 VPC `:8443` 内网通路
从出口机经 VPC 登录入口机（`ssh ubuntu@172.26.1.10`），核对 HAProxy 状态及到出口机内网 `:8443` 的连通性：
```bash
systemctl status haproxy --no-pager
nc -vz -w 3 172.26.2.20 8443
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```
- **高频隐藏坑点**：检查 `/etc/haproxy/haproxy.cfg` 中 `frontend reality_in` 的 `use_backend` 与 `default_backend` 是否**均指向 `172.26.2.20:8443`**（若历史配置把 `default_backend` 指向了 `172.26.2.20:443`，一旦客户端误开分片导致首包 SNI 解析失败或出口 `:443` 关闭，连接就会掉进死后端）。

### 7.6 第六步：排查跨墙 SSH（`vps-jump` / `vps-entry`）与 `autossh` 断连
1. **`ssh vps-jump` 超时**：确认本地 `127.0.0.1:10808` 正常，且出口机云防火墙 IPv4 `TCP 22` 已包含出口机自身静态公网 IP **`203.0.113.20/32`**（1:1 NAT 自回环白名单）与 VPC 网段 `172.26.0.0/20`。
2. **切忌把 `vps-jump` 目标改成私网 IP 或 `.internal` 域名**：客户端 `v2rayN` 的 `geoip:private` 与 `geosite:private`（含 `domain:internal`）会把 `127.0.0.1`、`172.26.2.20` 及 `*.compute.internal` 直接交由本机直连出站，导致无法进入 `10808` 隧道。
3. **Linux `autossh` 每隔几秒自动断开重连**：检查开发机 `~/.ssh/config` 的 `Host tunnel-vps`，确保 `ProxyCommand nc -X 5 -x 127.0.0.1:10808 203.0.113.20 22` 中**没有携带 `-w` 参数**（Ubuntu `nc.openbsd` 的 `-w` 为空闲超时，会定时掐断无流量的反向隧道）。

---

## 许可证

[MIT](LICENSE)。请遵守所在国家/地区的法律法规与相关服务条款。
