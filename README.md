# sing-box 四协议一键部署（+ 可选第 5 节点 CF-Vless）

一条命令在全新 VPS 上部署 **Hysteria2 + AnyTLS + VLESS-Reality-Vision + Shadowsocks-2022** 四条直连自用节点（再加可选的第 5 条 CF-Vless 大保底），自动生成 **Clash/Mihomo 订阅 + 通用 base64 订阅**（手动 `select` 切换、国内直连国外代理、客户端显示流量、可限流）。

> 设计目标：自用、单机、直连、零交互、可迁移。脚本源于一份手写部署文档，把里面所有步骤自动化，并对**本机无法自动完成的部分给出明确说明**。
>
> 想搞懂「它到底怎么实现的、每个机制的原理」→ 看 **[原理说明.md](原理说明.md)**。

---

## 特性

- **四协议**：Hysteria2（UDP，快）、AnyTLS（TCP，兼容好）、VLESS-Reality-Vision（TCP，稳/隐蔽）、Shadowsocks-2022（TCP+UDP，简单快，指纹不同的备选）。
- **零交互**：自动装依赖与 sing-box、自动生成全部密钥、自动探测公网 IP 和网卡。
- **多格式订阅**：Clash/Mihomo（YAML）+ 通用 base64 订阅（v2rayN / Shadowrocket / NekoBox 等）两个 URL；`install.sh links` 还能单独打印每个节点的分享链接（`vless://` / `hysteria2://` / `anytls://` / `ss://`）。
- **可视化看板页**：装完给一个 `http://<IP>/panel-xxxx.html`，浏览器打开看两种订阅 + 二维码 + 节点列表，一键复制、手机扫码导入；只读（服务器管理走 SSH）。
- **Komari 探针**：`install.sh komari` 傻瓜式装 [Komari](https://github.com/komari-monitor/komari) 监控 agent（可选，与代理无关）。
- **路由防护**：服务端默认**拦 BT/PT**（防被商家封机收滥用投诉）+ **geosite 拦广告**（`ENABLE_BLOCK_BT=0` / `ENABLE_BLOCK_ADS=0` 可关）。
- **备份迁移**：`install.sh backup` 把密钥+配置+证书打成一个包，新 VPS 上 `restore <文件>` 一条命令重建——**凭证/订阅路径不变，客户端不用换密码**（换机器只需把订阅 URL 的 IP 改成新 IP，或用域名直接重指 DNS）。
- **SSH 加固**：`install.sh harden` 一键密钥登录+禁密码+fail2ban，强护栏防锁死（见下方第 4 节）。
- **WARP 解锁分流**：`install.sh warp` 把 OpenAI/Claude/Gemini/Netflix/Disney+ 走 Cloudflare WARP 出口（机房 IP 被拉黑时解锁），其余直连；走 WARP 的站点用 `WARP_SITES` 可自定义；带「校验不过自动回滚」护栏，不会弄坏现有节点。
- **Reality SNI 自检**：安装时自动探测你填的偷证书目标（`REALITY_SNI`）是否真的支持 TLS1.3+H2，填错会在结尾提示换站点（防 Reality 静默失效/易被识别）。
- **不需要域名**：默认用公网 IP 提供订阅（也支持你自带域名）。
- **自动随机化**：随机订阅路径、随机密码/UUID/short-id，旧路径与首页返回 404。
- **流量统计/限流**：vnstat + 定时任务，订阅头显示已用/额度/到期；超额自动停、月初自动恢复；**默认按出站(tx)计费**（匹配多数商家；代理 rx≈tx，rx+tx 会翻倍误算）；手动停机不会被定时任务拉起。
- **安全细节**：`server_tokens off`、密钥文件 600、流量头只挂在订阅路径（不污染首页/404）。
- **可选第 5 节点**：CF-Vless 大保底（Argo 命名隧道），`install.sh cf` 半自动接入——VPS 侧全自动，只有 CF 后台建 Tunnel 那步要你做。直连 IP 被墙时兜底。
- **网络优化（自动）**：装前即应用 sysctl 调优——**UDP 收发缓冲 16MB**（Hysteria2/QUIC 关键，否则被限速并刷 quic-go 告警）、跨境高 BDP 链路的 TCP 缓冲、MTU 探测、空闲不重置拥塞窗口、TFO 等；BBR 默认开（`ENABLE_BBR=0` 关）。
- **HY2 进阶（按需）**：salamander 混淆默认开（抗 QUIC 识别）；`HY2_HOP_RANGE` 端口跳跃抗运营商 UDP 限速；`HY2_UP/HY2_DOWN` brutal 暴力带宽烂线路提速；`HY2_UP_MBPS/HY2_DOWN_MBPS` **服务端带宽护栏**（给套餐峰值留余量，防压测/多人下载打爆 UDP 队列）。见环境变量表。
- **可选**：ufw（默认关，避免锁死 SSH）。
- **不破坏现有节点**：二次运行复用已有密钥（含升级时自动补 SS2022 / 保留 CF-Vless）。

---

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh)
```

或下载后运行：

```bash
wget https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh
sudo bash install.sh
```

装完会打印**订阅 URL**和**需要你手动完成的清单**。把订阅 URL 导入 Clash/Mihomo 即可。

> 机器/系统要求见下方「机器要求」一节（一句话：**1 核 / 512MB / KVM / Debian 12 或 Ubuntu 22** 就够用且满血）。
>
> ⚠️ 这是 `curl | bash` 跑一个会以 root 执行的脚本，且脚本内部还会再 `curl | sh` 跑 sing-box 官方安装脚本。**建议先 `wget` 下来读一遍再运行**，不要无脑信任任何一键脚本（包括本脚本）。详见下方「安全须知与取舍」。

---

## 机器要求

proxy 的瓶颈是带宽，不是 CPU/内存，所以对机器要求很低。

**硬性要求（不满足装不了/用不了）**
- **systemd**：脚本开头检查 `systemctl`，没有直接报错退出 → **Alpine/OpenRC 不支持**。
- **root** 权限。
- **架构**：`x86_64`（amd64）或 `aarch64`（arm64）。
- **公网 IPv4**（直连节点需要）；纯 IPv6 机子要手动传 `PUBLIC_IP=` 且有坑。
- 能联网（下载 sing-box、geo 数据）。

**系统**
- **最佳**：Debian 12+ / Ubuntu 22.04+（完整支持）。
- RHEL 系（CentOS/Alma/Rocky，dnf/yum）尽力支持：自动启用 EPEL 装 vnstat，nginx 若有其它站点占用可能需手动处理（脚本会提示）。

**配置**
| | 最低能跑 | 推荐 |
|---|---|---|
| CPU | 1 vCPU | 1 vCPU |
| 内存 | 256MB | 512MB+ |
| 磁盘 | ~2GB 空闲 | 5GB+ |

sing-box 本体才占 ~20–50MB 内存。一台 **1 核 / 512MB / 10GB 的最便宜小鸡绰绰有余**，256MB 也能跑。

**虚拟化（影响「网络优化」，不影响能不能用）**
- **KVM**：完整支持，BBR / 16MB UDP 大缓冲 / 端口跳跃全部生效。
- **容器型（OpenVZ/LXC）**：核心 4 协议能跑，但共享宿主内核 → BBR 可能改不了、`net.core.rmem_max` 等 sysctl 可能被限制（HY2 大缓冲提速用不上）、端口跳跃（nftables NAT）可能不被允许。这些都做了**非致命处理**（失败只告警、不影响装和直连），但想要满血网络优化请选 **KVM**。

---

## 常用环境变量

全部可选，覆盖默认值即可。例：

```bash
LIMIT_GB=500 COUNT_MODE=tx AIRPORT_NAME=JP-01 bash install.sh
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `LIMIT_GB` | `200` | 每月显示/限流额度（GB） |
| `COUNT_MODE` | `tx` | 计费方式：`tx` 只算出站(默认,匹配多数商家) / `max` 取较大 / `rx+tx` 双向相加(仅真按进+出计费才用) |
| `EXPIRE_AT` | 安装日 +365 天 | 到期时间，**必须**是 `YYYY-MM-DD HH:MM:SS +0800` 格式（四位时区偏移，不能写 `+08:00` 或省略）。格式不对脚本会在开头直接报错退出，不会装到一半才崩。 |
| `DOMAIN` | 空（用 IP） | 订阅域名（仅支持单个）；填了需自己把 DNS A 记录指向本机 IP。脚本只处理一个订阅域名，需要备用域名请手动改 nginx 的 `server_name` 与订阅 `rules`。 |
| `AIRPORT_NAME` | `MyNode` | 客户端里的订阅显示名 |
| `PUBLIC_IP` | 自动探测 | 探测失败时手动指定 |
| `HY2_PORT` / `ANYTLS_PORT` / `VLESS_PORT` / `SS_PORT` | `4433`/`4434`/`443`/`4435` | 各协议端口（SS2022 同时用 TCP+UDP） |
| `SS_METHOD` | `2022-blake3-aes-128-gcm` | SS2022 加密方法（可改 `2022-blake3-aes-256-gcm` / `2022-blake3-chacha20-poly1305`，密钥长度脚本自动适配） |
| `REALITY_SNI` | `www.bing.com` | Reality 伪装域名（服务端 handshake + 客户端 servername，必须一致） |
| `TLS_SNI` | `www.bing.com` | HY2/AnyTLS 自签证书 SNI |
| `ENABLE_BBR` | `1` | 开启 BBR（纯 sysctl，安全） |
| `ENABLE_UFW` | `0` | 自动配置并**启用** ufw（默认关，避免把自己 SSH 关在外面） |
| `ENABLE_OBFS` | `1` | HY2 **salamander 混淆**，让 Hysteria2 不像 QUIC（默认开，抗 QUIC 整体识别/限速；`0` 关） |
| `ENABLE_BLOCK_BT` | `1` | **拦截 BT/PT**（默认开）。很多商家封 BT，挂了会收滥用投诉甚至停机；`0` 关 |
| `ENABLE_BLOCK_ADS` | `1` | **拦广告**（默认开，sing-box 远程 `geosite-category-ads` rule_set）；`0` 关 |
| `HY2_HOP_RANGE` | 空 | HY2 **端口跳跃** UDP 段（如 `20000-50000`），设了即启用（nftables 把整段重定向到 HY2 端口）。**云安全组要放行整段 UDP** |
| `HY2_UP` / `HY2_DOWN` | 空 | HY2 **brutal 暴力带宽**（Mbps，如 `50`/`200`），设了即开「无视丢包」猛提速。**必须填你真实带宽**，填错反而更差、且抢带宽不公平 |
| `HY2_UP_MBPS` / `HY2_DOWN_MBPS` | 空 | HY2 **服务端带宽护栏**（Mbps，写进 `hy2-in` 入站 `up_mbps`/`down_mbps`），按套餐峰值给 HY2 留余量，防压测/多人下载把 UDP 队列和 I/O wait 打爆。200Mbps 峰值机参考 `80`/`160`。与上面客户端 brutal 是两回事 |

`COUNT_MODE` 怎么选：默认 `tx`（只算出站）对绝大多数机器正确——Vultr/DigitalOcean/AWS/GCP/Hetzner 等都只按出站计费，`tx` 正好等于真实用量。代理是转发、每字节过网卡两次（rx≈tx），所以 `rx+tx`≈2×真实用量，在这些机器上会把用量翻倍、提前半量误停机；**只有商家真的按"进+出"双向计费才改 `rx+tx`**（很少见）。

> 装前会校验输入，不合法会在**开头**直接报错退出（不会装到一半才崩）：端口须为 `1–65535` 的整数；`REALITY_SNI` / `TLS_SNI` / `DOMAIN` 只能含字母、数字、`.`、`-`；`EXPIRE_AT` 须为 `YYYY-MM-DD HH:MM:SS ±0800` 这种**四位**时区偏移（`±0800`，不能写 `+08:00` 或省略；负偏移如 `-0500` 也可以）。

> 第 5 节点 CF-Vless 的 `CF_TOKEN` / `CF_HOSTNAME` / `CF_PORT`（默认 `28080`，仅监听 `127.0.0.1`）只在 `install.sh cf` 时用，见下方第 3 节。

---

## 管理命令

```bash
sudo bash install.sh menu        # 交互菜单(把下面所有功能串起来, 不想记命令就用它)
sudo bash install.sh info        # 重新打印订阅 URL 和节点信息
sudo bash install.sh panel       # 打印可视化看板页地址(浏览器看订阅+扫码+复制)
sudo bash install.sh panel-pass <用户名> <密码>   # 给看板页加密码登录(nginx Basic Auth, 真鉴权; 关闭: panel-pass off)
sudo bash install.sh links       # 打印每个节点分享链接 + 两个订阅 URL(+ 二维码)
sudo bash install.sh status      # 状态体检: 服务/配置/端口/时间/证书/限额/订阅可达
sudo bash install.sh doctor      # 一键自检常见坑: sysctl调优/防火墙+安全组/证书到期/外部可达/端口跳跃/内存+swap+IO压力, 带修复提示
sudo bash install.sh set LIMIT_GB=500 COUNT_MODE=tx   # 改限额/到期/计费/网卡, 即时刷新流量头
sudo bash install.sh backup      # 打包密钥+配置 -> /root/sing-box-backup-时间.tar.gz
sudo bash install.sh restore <文件>   # 新 VPS 上恢复(同一套凭证, 客户端不用换密码)
sudo bash install.sh harden      # SSH 加固: 密钥登录+禁密码+fail2ban(必须先有授权公钥)
sudo bash install.sh warp        # WARP 解锁分流: OpenAI/Claude/Gemini/Netflix/Disney 走 WARP(关闭: warp off)
sudo bash install.sh admin       # 网页管理面板(仅 127.0.0.1+SSH隧道+token, 改限额/到期/重启/备份; 关闭: admin off)
sudo bash install.sh update      # 更新 sing-box 到最新版并重启
sudo bash install.sh restart     # 重启 sing-box / nginx (/ cloudflared)
sudo CF_TOKEN=.. CF_HOSTNAME=.. bash install.sh cf    # 接入可选第 5 节点 CF-Vless(见第 3 节)
sudo KOMARI_ENDPOINT=https://面板 KOMARI_TOKEN=token bash install.sh komari   # 装 Komari 探针 agent
sudo bash install.sh uninstall   # 卸载（FORCE=1 跳过确认；删前自动备份密钥）
```

### 可视化看板页
装完会多打印一个**看板页地址** `http://<IP>/panel-xxxx.html`，浏览器打开就是一个自包含页面：
- **两种整段订阅**（Clash YAML / 通用 base64）：一键复制 + 二维码 + **一键导入按钮**（`clash://install-config` / `shadowrocket://add/sub://`，点一下直接拉进客户端）。
- **每个节点独立卡片**：单条分享链接（复制）+ 各自二维码，方便只导入某一个节点。
- **流量 / 到期**：静态显示限额+到期，并实时拉订阅响应头显示「已用」。
- **延迟自测**：测到本机的 HTTP 往返延迟（参考——浏览器测不了各协议的真实代理延迟）。
- **明暗主题**切换（记住选择）。

`install.sh links` 也会打印这些深链文本。随时 `install.sh panel` 重新拿地址。仍是**纯静态只读**页面（无后端、不开管理端口），管理一律走 SSH。
> 它是**只读**的（看/复制/扫码），**不在网页上操作服务器**——改限额/重启等用下面的「网页管理面板」或 SSH 的 `install.sh menu`。看板页**含全部节点凭证、走明文 HTTP**，和订阅一样：随机路径、别外传、不可信网络上 HTTPS。

**给看板页加密码登录**：嫌「知道链接就能直接打开」不安全，可以加一道登录：
```bash
sudo bash install.sh panel-pass myname 'your-strong-pass'   # 打开看板页会先弹登录框
sudo bash install.sh panel-pass off                         # 关闭密码
```
这是 **nginx 的 HTTP Basic Auth（真鉴权）**——没密码 nginx 直接不发这个文件，所以**有效**。注意两点：① 不要指望「网页里弹个 JS 密码框」那种做法，凭证就在页面源码里、`查看源代码`/`curl` 一下全看见，是**假安全**；② Basic Auth 在**明文 HTTP** 下密码是 base64（同网段可被嗅探），它挡的是「知道链接的人」，要**真加密**仍需 HTTPS（CF Tunnel）。密码文件 `/etc/nginx/.singbox_panel.htpasswd` **不随 `backup` 迁移**，换机后重设一次。

### 网页管理面板（可写，但只在本机）
如果你想在**网页上**改限额/到期/计费、一键重启、一键备份，而不是敲命令：
```bash
sudo bash install.sh admin       # 启动管理面板（关闭并清除：admin off）
```
它会打印两步访问方式：
```bash
# ① 在你本机电脑开 SSH 隧道
ssh -L 8088:127.0.0.1:8088 root@<服务器IP>
# ② 浏览器打开（带 token）
http://127.0.0.1:8088/?token=<随机token>
```
**安全模型（重点）**：
- 后端**只监听 `127.0.0.1`**，不暴露公网——外网根本连不到这个端口，**只能**通过你自己的 SSH 隧道访问。
- 每次操作要带**随机 token**（等于管理密码，`hmac` 常数时间比对）。
- 后端只跑**白名单动作**（`set` / `restart` / `backup`），调用复用 `install.sh`，参数走 `subprocess` **数组**（无 shell 拼接，注入无效，已测试 `200; rm -rf /`、`$(id)` 等都被正则挡掉）。
- 用 python 标准库实现（无 pip 依赖），systemd 托管。
> 为什么不默认开、不绑公网：把能改 root 配置的网页挂到公网 = 给自己开后门。绑 `127.0.0.1`+SSH 隧道，既能网页管理，又**零公网攻击面**。**永远不要**把它改成 `0.0.0.0`。

### Komari 探针 agent（可选，服务器监控）
和代理无关，是给你的 [Komari](https://github.com/komari-monitor/komari) 监控面板上报本机状态的。在 Komari 面板「添加服务器」拿到**面板地址 + 节点 token** 后：
```bash
sudo KOMARI_ENDPOINT='https://你的komari面板' KOMARI_TOKEN='节点token' bash install.sh komari
```
脚本调用 Komari 官方 `install.sh`（透传 `-e` 端点 / `-t` token）装好 agent 并起 systemd 服务。卸载本脚本**不会**动 komari-agent（独立工具，用它自己的方式卸）。
> 注意：这同样是一次以 root 跑的第三方 `curl|bash`（komari 官方仓库），和装 sing-box 一样，别无脑信任——在意就先把那个 install.sh 读一遍。

- `set` 可改的键：`LIMIT_GB`（每月额度 GB）、`EXPIRE_AT`（到期，四位时区如 `+0800`）、`COUNT_MODE`（`rx+tx`/`tx`/`max`）、`INTERFACE`（统计网卡）。改完即时重写流量头，客户端下次拉订阅就生效。
- `links` 若装了 `qrencode`（依赖里已含），会顺带打印通用订阅的二维码，手机扫码即导入。

### 两种订阅，按客户端选
- **Clash/Mihomo**：用 `http://<IP>/<随机.yaml>`（默认那条），支持分流规则、显示流量。
- **v2rayN / Shadowrocket / NekoBox 等**：用**通用(base64)订阅** `http://<IP>/<随机-b64.txt>`，里面是各节点的分享链接。
- 只想要单条节点：`install.sh links` 直接把 `vless://`/`hysteria2://`/`anytls://`/`ss://` 打印出来复制。
> 注：`anytls://` 较新，只有 mihomo / sing-box 系客户端认；v2rayN 等用 vless/hysteria2/ss 那几条即可。两种订阅都带流量头，客户端都能显示已用/到期。

---

## 本机无法自动完成的部分（脚本会提示，这里是详解）

这些受限于平台/账号，脚本管不了，需你手动处理：

### 1. 云服务商安全组（最常见的坑）
脚本能配主机内的 ufw，但**改不了云端安全组**（阿里云/腾讯云/Oracle/AWS 等控制台里的入站规则）。云安全组默认拒绝入站、而且经常拦 UDP。请在控制台放行：

```
22/tcp  80/tcp  443/tcp  4434/tcp  4435/tcp  4433/udp  4435/udp     ← 尤其 UDP(4433、4435)
```

> 现象：HY2（UDP）连不上、Vless（TCP 443）却正常 = 八成是 UDP 没放行。注意本机 `ss -lntup` 只证明在监听，证明不了外部能连进来。

### 2.（可选，但在不可信网络下强烈建议）域名 + HTTPS 订阅
默认用 `http://<IP>/<随机路径>` 提供订阅。**两个订阅文件（Clash YAML 和通用 base64）都含全部节点凭证（密码、UUID、Reality 公钥），HTTP 是明文传输**——base64 只是编码不是加密，同样能被嗅探：随机路径只能防扫描，挡不住在途嗅探——任何能抓到这次订阅请求的人（机房、运营商、出口路由）一次就拿到全套凭证、直接接管你的节点。自用、低频拉取、信任链路时风险尚可，但只要走过不可信网络，就该上 HTTPS：
- 你自己把域名 DNS A 记录指向本机 IP，安装时加 `DOMAIN=node.example.com`；
- 要真正的 HTTPS（443 已被 Reality 占用），推荐把订阅路径挂到下面的 Cloudflare Tunnel 上走 HTTPS，而不是在 VPS 上另开 443。
- 临时缓解：拉取一次后可换 `SUB_PATH`（等于换凭证），或拉完就把订阅文件删掉本地保存。

### 3.（可选）CF-Vless 大保底 / 「Argo 隧道」（IP 被墙时兜底）—— 第 5 节点
网上说的 **「Argo 隧道」就是这里的 Cloudflare Tunnel**，这个**命名隧道（固定域名）就是稳定版的 Argo**。VPS 这一侧脚本能自动做，**只有 Cloudflare 后台那步需要你**（要你自己的账号 + 一个托管在 CF 的域名）。

**第一步（你手动，在 CF 后台）**：Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared
- 加一个 Public hostname：你的域名（如 `cf.example.com`），Service 填 `http://127.0.0.1:28080`
- 复制 Connector **token**

**第二步（脚本自动）**：回到 VPS 运行
```bash
sudo CF_TOKEN='粘贴你的token' CF_HOSTNAME='cf.example.com' bash install.sh cf
```
脚本会：加一个只监听 `127.0.0.1:28080` 的 VLESS-WS 入站、下载安装 cloudflared 并以 token 起服务、生成 CF 节点密钥、把 `CF-Vless` 并进订阅、再用 `101 Switching Protocols` 验证隧道是否打通。

**第三步**：看到 `101` 后，客户端**重新拉取订阅**，就多出 `CF-Vless` 节点（排在最后，平时不用，直连都挂了再切它）。没通就先别用——脚本会告诉你怎么复测。

> 注意：部分 VPS 商家对 Cloudflare/CDN 流量额外计费或不适合走 CF，这种机器就别开。`uninstall` 会一并停掉脚本装的 cloudflared，但 CF 后台那条 Tunnel 要你自己去删。

> **关于「Argo 隧道加速」**——别被「加速」二字误导：
> - 所谓加速 = 客户端连一个**优选 Cloudflare 域名/IP**（路由好的边缘），由 CF 骨干回源到你的隧道。它**只在直连路由差/被墙时**可能更快；正常情况多一跳，往往比直连**更慢**。真正的智能路由（Argo Smart Routing）是 **按量付费**的，多数教程其实只是用了免费的「优选 IP」。
> - 另一种「免域名一键 Argo」用的是**临时快速隧道**（`cloudflared tunnel --url`，给你一个 `*.trycloudflare.com`）：好处是不要账号/域名、能自动化；但**每次 cloudflared 重启都会换一个随机域名** → 订阅里的节点地址立刻失效变死节点，还会被 Cloudflare 限速、随时可能掉。**不适合当你依赖的节点**，所以本脚本**不**自动集成它。
> - 结论：要稳定就用上面的**命名隧道**（固定域名）；它定位是**保底/兜底**，不是稳定加速。直连的 Hysteria2 / Vless-Reality 仍是主力。

### 4.（可选，强烈建议）SSH 加固
VPS 最大的风险是 22 端口被爆破——一旦失守整台机器连同密钥全没。现在有一键加固：
```bash
# 第一步(在你本地电脑)：ssh-copy-id root@<IP>，并确认能用密钥登录
sudo bash install.sh harden    # 仅密钥登录 + 禁密码 + fail2ban
```
护栏：**必须先检测到 `/root/.ssh/authorized_keys` 里有公钥才动手**（否则拒绝，防把你锁在门外）；用 `00-` 开头的 drop-in 覆盖 cloud-init 默认的 `PasswordAuthentication yes`；`sshd -t` 校验不过自动回滚。**改完务必另开一个新终端用密钥登录确认能进，再关掉旧会话。**

### 5.（可选）WARP 解锁分流（OpenAI / Claude / Gemini / Netflix / Disney+）
很多机房 IP 被 OpenAI/流媒体拉黑，直连这些服务会报「不可用/地区限制」。一条命令把这些站点的流量改走 Cloudflare WARP 出口（其余流量仍走 VPS 直连，不影响速度）：
```bash
sudo bash install.sh warp        # 自动: 装 wgcf → 注册免费 WARP 账号 → 加 WireGuard 出站 + 分流规则
sudo bash install.sh warp off    # 关闭, 恢复全部直连
```
- 默认把 `geosite-openai / anthropic / google-gemini / netflix / disney` 走 WARP，其它直连。**自定义走 WARP 的站点**（逗号分隔的 geosite 名，会自动去空格/转小写/过滤非法字符）：
  ```bash
  sudo WARP_SITES='openai,anthropic,google-gemini,tiktok,spotify' bash install.sh warp   # 改完即生效, 已记进 warp.env
  ```
- WARP 账号保存在 `/etc/sing-box/warp.env`，`backup` 会一并打包，迁移到新机免重新注册。
- **安全护栏**：新配置先渲染到临时文件、`sing-box check` 通过才替换正式配置——**校验不过就回滚，绝不弄坏现有节点**。需要 sing-box ≥ 1.12（wireguard endpoint）；脚本装的是最新版，正常满足。
- 若「能连但仍被拦」（解锁没生效），多半是缺 WARP 的 `reserved`：编辑 `warp.env` 设 `WARP_RESERVED='a,b,c'`（三个数字）后重跑 `warp`。这是少数机器才需要的微调。
- 这是本仓库里唯一在 Windows 上无法离线验证运行时的功能（只校验了配置渲染合法性），真机上 `sing-box check` 与 `warp` 的回滚护栏是最终关卡。

---

## 它装了哪些文件

```
/etc/sing-box/config.json          sing-box 服务端配置 (600)
/etc/sing-box/server.{crt,key}     HY2/AnyTLS 自签证书
/etc/sing-box/node-secrets.env     密钥与随机路径 (600，复用用)
/etc/sing-box/cf.env               CF-Vless 状态 (600，仅在跑过 cf 后存在)
/etc/sing-box-node.env             运行参数单一来源 (600)
/var/www/html/sub-xxxx.yaml        Clash/Mihomo 订阅(644，含凭证，见安全须知)
/var/www/html/sub-b64-xxxx.txt     通用(base64)订阅(644，含凭证，供 v2rayN 等)
/var/www/html/panel-xxxx.html      可视化看板页(644，含凭证)
/etc/nginx/conf.d/00-singbox-sub.conf   订阅 server 块(仅 server 块；流量头单独在 snippets 内、只对订阅 location include，首页/404 不带头)
/etc/nginx/snippets/sub_headers.conf    流量头(只挂订阅路径)
/usr/local/bin/traffic_limit.py    流量统计/限流
/etc/cron.d/traffic_limit          每 5 分钟刷新
/etc/sysctl.d/99-singbox.conf      网络优化(UDP 16MB 大缓冲 / 跨境 TCP 调优 / BBR)
/usr/local/bin/cloudflared         CF 隧道客户端(仅跑过 cf 后存在; uninstall 停服务但保留二进制)
/etc/sing-box/porthop.nft + sing-box-porthop.service  HY2 端口跳跃(仅设了 HY2_HOP_RANGE 后存在)
```

---

## 排查

**连不上先跑 `sudo bash install.sh doctor`**——它会一次性核对服务/配置/端口/sysctl 调优/防火墙/安全组/时间/证书/订阅内外可达，并给出每一项的修复命令。下面是手动逐项排查：

```bash
systemctl is-active sing-box nginx vnstat        # 服务在跑?
sing-box check -c /etc/sing-box/config.json      # 配置合法?
nginx -t                                         # nginx 合法?
ss -lntup | grep -E ':(80|443|4433|4434|4435)\b'  # 本地在监听?(端口为默认值; 改过端口请替换。不代表外部可达)
curl -I http://<IP或域名>/<订阅路径>             # 订阅 200 且带 Subscription-Userinfo?
journalctl -t traffic_limit -n 20 --no-pager     # 流量脚本日志
timedatectl                                      # 时间同步?(Reality 对时钟敏感)
```

- **订阅打不开**：先看云安全组是否放行 80/tcp。
- **HY2 / SS2022 连不上但 Vless 正常**：云安全组没放行 UDP（HY2 的 `4433/udp`、SS2022 的 `4435/udp`）。
- **SS2022 连不上**：确认云安全组放行了 `4435` 的 **TCP 和 UDP**；客户端 mihomo 需较新版本支持 `2022-blake3-*` 加密。
- **订阅不显示流量**：核对 `/etc/sing-box-node.env` 里的 `INTERFACE`（`ip -br link` 查真实网卡），看 `journalctl -t traffic_limit`。
- **Vless 连得上但不通**：多半是时间不同步或 SNI 两端不一致。

---

## 安全须知与取舍

一键脚本图省事，但有几个取舍你应当知情：

- **供应链信任**：本脚本以 root 运行，且内部用 `curl -fsSL https://sing-box.app/install.sh | sh` 安装 sing-box——没有固定版本、没有签名/SHA256 校验。一旦该域名/CDN 被劫持，攻击者可在你机器上以 root 执行任意代码。在意的话：先把本脚本和 sing-box 安装脚本读一遍，或改用发行版包 / 手动下载校验 release 的 SHA256 后再装。
- **订阅明文凭证**：两份订阅（Clash YAML 与通用 base64）都走明文 HTTP、都含全部节点凭证，base64 只是编码不是加密；链路可被嗅探则节点失守。详见上方「2. 域名 + HTTPS 订阅」，不可信网络务必上 HTTPS。
- **HY2 / AnyTLS 用自签证书 + `skip-cert-verify: true`**：等于客户端不校验服务端身份，能做在途 MITM 的攻击者可冒充节点、解密/篡改流量且客户端不报警。这是自签方案的固有代价。**Reality（Vless）不受此影响**——对抗审查/在意 MITM 时优先用 Vless；想让 HY2/AnyTLS 也抗 MITM，需改用真实证书（真域名 + Let's Encrypt）并去掉 `skip-cert-verify`。
- **文件权限**：密钥、私钥、`config.json`、`*-secrets.env`、运行参数 env 均为 600，`/etc/sing-box` 目录 700，脚本运行期 `umask 077`（创建瞬间即限权）。订阅文件为 644（nginx 需要读）——同机若有不可信的本地用户，注意它可读。
- **防火墙不自动启用**：`ENABLE_UFW` 默认 0，避免把你的 SSH 关在门外；显式开启时脚本会先确认放行 22 再 enable。
- **卸载会先备份**：`uninstall` 删除前自动把密钥/参数备份到 `/root/sing-box-uninstall-backup-<时间戳>/`，避免一条命令不可逆地销毁全部凭证；它不碰你手动搭的 cloudflared。

最该补的一件事仍是 **SSH 加固**（见上方第 4 条）——host 被爆破，代理调得再好也归零。

---

## 关于 BBR v3（可选，手动，**不在一键流程里**）

脚本默认已开 **BBR v1**（`ENABLE_BBR=1`，纯 `sysctl`、免重启、零风险）。有人会想再上 **BBR v3** 提速——这需要**换内核**，所以**故意不放进一键脚本**，原因如下，建议看完再决定值不值得。

### 为什么不进一键流程

- **会换内核 + 必须重启**。新内核若起不来，VPS 会黑屏失联，得靠服务商**控制台 / 救援模式 / 重装**才能救回——装代理的脚本不该有把机器搞砖的能力。
- **只对 TCP 节点有用**。BBR 是内核 TCP 拥塞控制，帮的是 **AnyTLS / Vless**；**Hysteria2 走 UDP/QUIC、自带拥塞控制，完全不受影响**。而本套是 HY2 优先，v1→v3 的边际收益本就有限。
- **兼容面窄**。只适用 KVM + GRUB 的 Debian 12+/Ubuntu 22.04+；**容器型 VPS（OpenVZ/LXC）不能换内核**。
- **供应链更重**。装第三方编译的内核 = 把机器最底层托付给别人的构建流水线，风险远大于用户态程序。

### 如果某台机器真的想要：手动做，优先 XanMod

XanMod 内核自带 BBRv3，有官方 apt 源、有签名、用的人多，比装某个 GitHub Release 的预编译内核更可信、更好维护。**前提：先确认这台 VPS 有控制台/VNC 或救援模式，再动内核；一台一台来。**

```bash
# 0) 先查 CPU 支持到哪个等级(输出 x86-64-v2 / v3 / v4)，选不超过它的包，否则可能起不来
wget -qO - https://dl.xanmod.org/check_x86-64_psabi.sh | bash

# 1) 加 XanMod 官方源
wget -qO - https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
  | sudo tee /etc/apt/sources.list.d/xanmod-release.list

# 2) 装内核(按上面查到的等级选 x64v1/v2/v3/v4；不确定就选低一档更稳)
sudo apt update && sudo apt install -y linux-xanmod-x64v3

# 3) 重启(确认你能从控制台进救援再重启)
sudo reboot

# 4) 回来后验证：内核换了、CC 是 bbr(XanMod 里就是 BBRv3)
uname -r
sudo sysctl --system
sysctl net.ipv4.tcp_congestion_control   # 期望: net.ipv4.tcp_congestion_control = bbr
```

> 注意：包名里的 `x64v3` 是 **CPU 指令集等级**，不是 BBR 版本——XanMod 任何等级的内核都带 BBRv3。`/etc/sysctl.d/99-singbox.conf`（本脚本已写入 `fq` + `bbr`）在新内核下会自动用上 v3，无需改动。
>
> 你提到的 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 是另一条路（自编译 BBRv3 内核 .deb）。能用，但相比 XanMod 维护性和可信度更弱，自担风险。

**一句话**：v1 留着够用；v3 当作一次性的手动内核升级，自己掂量那台机器值不值，且优先 XanMod。

---

## 免责声明

仅供学习与自用网络代理搭建。请遵守你所在地区与 VPS 服务商的法律法规和服务条款，自行承担使用风险。
