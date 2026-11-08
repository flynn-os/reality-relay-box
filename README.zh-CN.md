# reality-relay-box

[English](README.md) | **简体中文**

> **双 VPS（动态入口中转 + 固定出口 IP）VLESS + REALITY 进阶抗封锁加固套件 —— 专为 Claude Code / OpenAI 等对出口 IP 变动高度敏感的 AI Coding 工具打造。**

## 📌 前置必读：与 [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box) 的关系

本项目是 [**`surgeshi/reality-box`**](https://github.com/surgeshi/reality-box) 的**进阶高可用与抗封锁加固版**，建议搭配阅读与使用：

1. **新手从零搭建（前置教程）**：如果你刚开始准备购买 VPS、从零配置客户端（v2rayN）以使用 **Claude Code**，请**先阅读并参照 [`surgeshi/reality-box`](https://github.com/surgeshi/reality-box)** 完成基础入门了解。
2. **遇到 IP 被墙 / 需要保住固定出口 IP（平滑升级本方案）**：单机版 `reality-box` 在高强度使用 Claude Code 或跨国 SSH 时，可能会遇到 **VPS 的 IP 被防火墙阻断（被墙）** 的情况。一旦换 IP，不仅折腾，还会因为出口 IP 频繁变动触发 Anthropic / OpenAI 的风控封号。此时即可直接切换到本项目的 **“双机解耦 + 6 大抗封锁加固方案”**。

> [!IMPORTANT]
> **⚠️ 核心铁律：VPS 必须手动绑定“静态 IP（Static IP）”！**
> 无论你使用单机还是本项目的双机方案，在云厂商控制台（如 AWS Lightsail 的 `Networking` → `Create static IP`）创建 VPS 后，**必须第一时间手动申请并绑定“静态公网 IP（Static IP）”**（尤其是**固定出口 VPS**，建议入口 VPS 也绑定）：
> - 云服务器默认分配的公网 IP 是**动态 IP**，一旦实例关机重启或宿主维护，公网 IP 就会自动改变，直接导致 Claude Code 出口 IP 突变触发封号，或者客户端连接中断！
> - 在 AWS Lightsail 中，绑定在运行中实例上的 Static IP 是**完全免费**的；且对于入口中转机而言，绑定 Static IP 后如果未来想换 IP，只需在控制台解绑旧静态 IP、重新创建一个新静态 IP 即可，无需重装机器。

---

## 为什么需要这套进阶加固方案？

在使用单台 VPS 搭建代理（如基础版 [`reality-box`](https://github.com/surgeshi/reality-box)）时，常面临一个两难困境：
1. **AI 平台风控封号**：Anthropic（Claude Code）、OpenAI 等平台对账号的出口 IP 纯净度与稳定性极为敏感，频繁更换出口 VPS 的 IP 极易触发风控封号；
2. **单机入口易被防火墙阻断**：如果只用一台 VPS，一旦该机器的 IP 因特征暴露被防火墙阻断，你就不得不更换 VPS 的 IP —— 从而破坏“固定出口 IP”的前提。

本项目通过 **“入口中转（Relay VPS）+ 固定出口（Exit VPS）”双机解耦架构** 结合 **6 项深度抗封锁加固**，彻底解决这一痛点：
- **出口 IP 永久固定**：固定出口 VPS 绑定静态 IP 且从不直接暴露给客户端，所有访问 Claude / OpenAI 的流量永远从同一个干净的静态 IP 出站；
- **入口抗封锁深度加固**：修复了常规 REALITY 部署中最常踩坑的 **伪装域名 ASN 冲突（如误用 Cloudflare 导致空 SNI 探测泄露证书）**、**跨墙明文 SSH 隧道多端口关联**、**客户端固定频率机械心跳（Beaconing）** 等致命破绽；
- **入口随时无感轮换**：万一未来入口 VPS 需要更换静态 IP，只需在入口机跑一条命令、客户端执行一行 `switch-relay-ip.sh`，**1 秒内完成热切换，出口 VPS 与所有密钥/UUID 无需任何改动**。

---

## 架构全景图

```
[ 本机 Mac / Linux 开发机 ]
   │  1) VLESS + REALITY (SNI: d1.awsstatic.com, Chrome 指纹, 零分片)
   │  2) 跨墙 SSH / autossh 自动封装进 10808 隧道内部 (公网零 SSH 暴露)
   ▼
[ 入口中转 VPS (Relay, 如 198.51.100.10) ]  <-- 仅暴露 :443, 启用 BBR+FQ
   │  HAProxy (SNI 分流 + AWS 同机房 VPC 内网直连 172.26.2.20:8443, RTT ~0.15ms)
   ▼
[ 固定出口 VPS (Exit, 如 203.0.113.20) ]    <-- 出口 IP 永久不变, 对外隐身
   │  Xray-core (REALITY 解密, dest=d1.awsstatic.com:443, xver=0)
   ▼
[ Claude Code / Anthropic / OpenAI / 互联网 ]
```

*(注：文中所涉 `198.51.100.10`、`203.0.113.20`、`172.26.x.x` 均为 RFC 5737 / RFC 1918 标准文档示例占位地址。)*

---

## 为什么传统配法会导致入口 IP 频繁被封？（6 大加固设计）

本项目针对真实生产环境中定位出的 **6 大高频被封根因** 做了默认固化：

| 根因编号 | 传统配法的致命破绽 | 本项目的内置加固方案 |
| :--- | :--- | :--- |
| **1. 伪装域名 ASN 归属冲突** | 在 AWS 机器上把 `SNI`/`dest` 设为 `www.cloudflare.com`。被动 DPI 一眼看出 AWS IP（AS16509）不可能承载 Cloudflare 官网（AS13335）；且主动无 SNI 探测会直接让 AWS IP 吐出 Cloudflare 证书，当场实锤“偷证书”。 | 默认选用与 AWS 同属 `AS16509`、支持 TLS 1.3 + H2 的官方静态节点 **`d1.awsstatic.com`**：被动审查 ASN 100% 吻合；无 SNI 空探测直接拒绝握手，带 SNI 探测返回正宗 `Amazon RSA 2048 M04` 证书。 |
| **2. 跨墙裸跑明文 SSH 隧道** | 同一台国内机器一边高并发连入口机 `:443`，一边向入口机 `:22` / `:2222` 维持 24 小时 `autossh` 反向隧道或跳板连接，暴露 `SSH-2.0-OpenSSH` 明文 Banner 与包长特征，触发多端口行为关联封禁。 | 提供 `client/ssh/ssh-config.example`：通过 `ProxyCommand` 优先将跨国 SSH / `autossh` 流量**封装进本地 `127.0.0.1:10808` REALITY 隧道内**，仅在代理挂掉时自动降级直连 `:2222`，日常跨墙明文 SSH 流量为 **0**。 |
| **3. 跨机走公网转发 & 扫描暴露** | 入口 HAProxy 通过公网 IP 转发给出口机，不仅耗双倍流量、增加握手 RTT 差值，还迫使出口机公网 `:443` 对全网敞开，全天被扫描器轰炸。 | 入口与出口部署在同区域（如 AWS 东京），HAProxy 走 **VPC 内网私有 IP（`172.26.x.x:8443`）** 转发，内网延迟仅 `0.15ms`，固定出口机对公网扫描器完全隐身。 |
| **4. 误配 `send-proxy-v2` 与 `xver`** | 在 HAProxy 加 `send-proxy-v2` 同时把 Xray `realitySettings.xver` 设为 `2`（`xver` 实为向伪装目标网站发 PROXY 头），导致目标网站直接重置连接、代理瘫痪。 | 严格保持 `realitySettings.xver: 0` 原生透传，并在 HAProxy 层启用 `req_ssl_hello_type 1` 与 SNI 识别分流，兼顾零断流切换与稳定性。 |
| **5. 客户端 10 秒机械心跳（Beaconing）** | 守护脚本每 10 秒通过代理 `curl` 一次外网（每天发出 8,640 次严格等间隔、同包长的 TLS 握手），形成明显的机器信标特征。 | `client/macos/v2ray-proxy-watchdog.sh` 采用 **Zero-Beaconing 设计**：每 10 秒仅做纯本地系统设置检查（零网络流量），仅当系统代理被篡改关闭时才做一次外网检查并恢复。 |
| **6. 首包固定分片与拥塞重传** | 对 REALITY 开启 `finalmask`（`tlshello` 50-100 字节分片），人为制造非浏览器特征；服务端默认 `cubic` 拥塞控制。 | 自动关闭客户端 `EnableFragment` / `finalmask`，服务端一键启用 **TCP BBR + FQ** 并将 Xray 日志设为 `warning`。 |

---

## 1. 准备两台同区域 VPS 并绑定静态 IP（以 AWS Lightsail 为例）

1. 登录 AWS Lightsail 控制台：<https://lightsail.aws.amazon.com/>
2. 在**同一个区域**（例如东京 `ap-northeast-1`）创建两台 **Ubuntu 22.04 LTS** 实例（$5/月套餐即可）：
   - **实例 A（固定出口机 Exit VPS）**：**必须进入 `Networking` 标签页点击 `Create static IP` 绑定一个静态公网 IP**（假设为 `203.0.113.20`，切勿使用默认的动态公网 IP，否则重启机器后出口 IP 会变！），并记下它的**私网 IP**（如 `172.26.2.20`）。
   - **实例 B（入口中转机 Relay VPS）**：同样建议绑定一个**静态公网 IP**（假设为 `198.51.100.10`，方便重启不变且日后可随时在控制台一键解绑换新 IP），并记下它的**私网 IP**（如 `172.26.1.10`）。
3. **云防火墙放行规则（Networking → IPv4 Firewall）**：
   - **入口中转机（Relay VPS）**：放行自定义 `TCP 443`（以及可选的应急 SSH 转发端口 `TCP 2222`）。
   - **固定出口机（Exit VPS）**：同账号同区域的 Lightsail 实例默认在同一个 VPC 子网（`172.26.0.0/16`）内互通，无需对公网暴露 `8443`；如需跨网段调试可放行 `TCP 443`。

---

## 2. 第一步：在【固定出口 VPS】上运行一键安装脚本

SSH 登录到**固定出口 VPS（Exit VPS）**，克隆本仓库并执行 `setup-exit.sh`（可传入入口机的公网 IP 以便直接生成最终分享链接）：

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo RELAY_PUBLIC_IP=198.51.100.10 bash setup-exit.sh
```

脚本会自动完成：
1. 开启内核 `BBR + FQ`；
2. 安装 Xray-core，生成全新的 UUID、X25519 密钥对和 ShortID；
3. 配置 `:443` 与内网 `:8443` 双入站（默认伪装目标 `d1.awsstatic.com:443`）；
4. 打印出下一步在入口机上执行的命令，以及客户端 `vless://` 导入链接（同时保存在 `/root/reality-client.txt`）。

**可选环境变量覆盖：**

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `RELAY_PUBLIC_IP` | 自动回退为本机 IP | 写入 `vless://` 分享链接中的入口机公网 IP |
| `DEST` | `d1.awsstatic.com` | REALITY 伪装目标域名（要求同 ASN、支持 TLS 1.3 与 H2） |
| `SNI` | 同 `DEST` | 客户端握手携带的 TLS SNI |
| `PORT` | `443` | 外部端口 |
| `INTERNAL_PORT` | `8443` | 供同区域入口机通过 VPC 内网连接的端口 |

---

## 3. 第二步：在【入口中转 VPS】上运行一键安装脚本

SSH 登录到**入口中转 VPS（Relay VPS）**，复制上一步 `setup-exit.sh` 打印出的提示命令直接运行（将 `EXIT_HOST` 设为固定出口机的 **VPC 内网 IP**，如 `172.26.2.20`）：

```bash
git clone https://github.com/flynn-os/reality-relay-box.git
cd reality-relay-box
sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh
```

脚本会自动完成：
1. 开启内核 `BBR + FQ`；
2. 安装 HAProxy 并验证到出口机 `172.26.2.20:8443` 的内网连通性；
3. 配置 `:443` SNI 分流转发至出口机内网 `:8443`，以及 `:2222` 应急转发至出口机 `:22`。

---

## 4. 客户端连接与 AI Coding 工具代理配置

### 4.1 导入分享链接（v2rayN）

1. 复制 `setup-exit.sh` 输出的 `vless://...` 分享链接（确认其中的地址为**入口中转机公网 IP** `198.51.100.10:443`）。
2. 打开 **v2rayN**（支持 Windows / macOS / Linux）：点击 **服务器 → 从剪贴板导入批量 URL**，右键设为**活动服务器**。
3. **关键检查**：在 v2rayN 的 *设置 → 参数设置 → Core 基础设置* 中，确保 **不要勾选** `启用分片 (Enable Fragment)`，保持原生 Chrome TLS 1.3 指纹。
4. 验证出口 IP：
   ```bash
   export HTTPS_PROXY="http://127.0.0.1:10808"
   export HTTP_PROXY="http://127.0.0.1:10808"
   export ALL_PROXY="socks5://127.0.0.1:10808"
   curl https://ip.me
   ```
   此时返回的 IP 应当是你的 **固定出口机公网 IP（`203.0.113.20`）**，而不是入口机 IP！

---

## 5. 进阶加固：客户端常驻守护、零心跳防篡改与 SSH 隧道隐身

### 5.1 macOS 零心跳系统代理守护（`client/macos/`）
如果你在 Mac 上同时安装了其他网络工具（如 Clash 等，启动时会强行关闭系统代理），可以使用 `client/macos/` 下的两个脚本配合 `LaunchAgents` 实现常驻：
- [`client/macos/v2ray-keepalive.sh`](client/macos/v2ray-keepalive.sh)：当 `v2rayN` 意外退出或 `10808` 端口未监听时自动拉起；
- [`client/macos/v2ray-proxy-watchdog.sh`](client/macos/v2ray-proxy-watchdog.sh)：采用 **零跨墙心跳（Zero-Beaconing）** 逻辑，平时只调用本地 `networksetup` 检查系统代理开关（0 流量），仅当检测到系统代理被意外关闭时才验证一次连通性并恢复系统代理。

### 5.2 Linux 开发机防断流守护（`client/linux/`）
- [`client/linux/v2rayn-keepalive.sh`](client/linux/v2rayn-keepalive.sh)：通过本地内核 `ss -tlnH sport = :10808` 检查端口状态（零网络探测包），且内置 **Claude Code 活跃会话保护**——当检测到有 Claude 会话正在运行或近 5 分钟内有交互时，绝不强杀重启进程，彻底避免长任务中途 `ECONNRESET`。

### 5.3 跨墙 SSH 跳板 / `autossh` 反向隧道隐身（`client/ssh/ssh-config.example`）
如果你需要通过 VPS 建立 `autossh` 反向隧道访问内网开发机，**切忌从国内直接裸连入口机的 `:22` 或 `:2222` 端口**。请参考 [`client/ssh/ssh-config.example`](client/ssh/ssh-config.example) 配置 `~/.ssh/config`：

```sshconfig
Host vps-jump
    HostName 198.51.100.10
    Port 2222
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    # 优先走本地 10808 REALITY 隧道直达出口机 SSH；仅当本地代理不可用时自动回退直连 2222
    ProxyCommand sh -c 'if nc -z -G 1 127.0.0.1 10808 2>/dev/null; then exec nc -X 5 -x 127.0.0.1:10808 203.0.113.20 22; else exec nc %h %p; fi'
```

这样一来，日常所有的跨国 SSH / `autossh` 流量都会被 100% 封装在 `:443` 的 REALITY TLS 1.3 数据流内，防火墙在公网上看不到任何一条 SSH 连接；而万一本地代理进程异常退出，SSH 又会自动无缝降级到 `:2222` 应急通道，兼顾隐蔽性与救火逃生能力。

---

## 6. 日常运维：如何一键无感更换入口 VPS 的 IP？

万一某天你需要更换入口中转 VPS（或者给入口机换一个新的静态 IP `198.51.100.99`）：
1. **固定出口 VPS 不用做任何改动**（UUID、密钥、出口 IP 全部保持原样）；
2. 在新的入口 VPS 上运行：
   ```bash
   sudo EXIT_HOST=172.26.2.20 EXIT_PORT=8443 SNI=d1.awsstatic.com bash setup-relay.sh
   ```
3. 在你的 Mac 或 Linux 开发机上运行本仓库自带的切换脚本：
   ```bash
   bash switch-relay-ip.sh 198.51.100.99 d1.awsstatic.com
   ```
   脚本会自动更新 `v2rayN` 的 SQLite 数据库（`guiNDB.db`）和 `binConfigs/config.json`，并在 200ms 内完成 `xray` 核心热重载与连通性校验。

---

## 许可证

[MIT](LICENSE)。请遵守所在国家/地区的法律法规与相关服务条款。
