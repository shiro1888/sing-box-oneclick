# sing-box 三协议一键部署（Hysteria2 / AnyTLS / Shadowsocks-2022）

一条命令在全新 VPS 上部署 **Hysteria2 + AnyTLS + Shadowsocks-2022** 三条直连自用节点，自动生成 **Clash/Mihomo 订阅 + 通用 base64 订阅**（手动 `select` 切换、国内直连国外代理、客户端显示流量、可限流）。

> **2026-10 现网口径**：直连 **VLESS/Reality** 与旧 **CF-VLESS 一键路径**均已退休（脚本仍能读取老状态并做安全清理），节点只保留 Hysteria2（**UDP 443**）/ AnyTLS（TCP 4434）/ SS2022（TCP+UDP 4435）。HY2 统一使用自动拥塞控制，不再有人工带宽与端口跳跃。
>
> 设计目标：自用、单机、直连、零交互、可迁移。脚本源于一份手写部署文档，把里面所有步骤自动化，并对**本机无法自动完成的部分给出明确说明**。
>
> 想搞懂「它到底怎么实现的、每个机制的原理」→ 看 **[原理说明.md](原理说明.md)**。

---

## 特性

- **三协议**：Hysteria2（UDP 443，快）、AnyTLS（TCP 4434，兼容好）、Shadowsocks-2022（TCP+UDP 4435，简单快，指纹不同的备选）。
- **零交互**：自动装依赖与 sing-box、自动生成全部密钥、自动探测公网 IP 和网卡。
- **多格式订阅**：Clash/Mihomo（YAML）+ 通用 base64 订阅（v2rayN / Shadowrocket / NekoBox 等）两个 URL；`install.sh links` 还能单独打印每个节点的分享链接（`hysteria2://` / `anytls://` / `ss://`）。
- **客户端分流（订阅内）**：只引用 MetaCubeX 官方 MRS（6 个 provider + 固定 7 条规则，私有→广告→Google→中国→MATCH）；`meta-google` 固定在中国规则之前，避免 Google Play 下载卡 99%。附专用 DNS：`proxy-server-nameserver` 解析节点域名，`fallback: []` 避免境外 DoH 不可达导致的 5 秒解析超时。
- **可视化看板页**：装完给一个 `http://<IP>/panel-xxxx.html`（启用订阅 HTTPS 后同页走 `https://域名/...`），浏览器打开看两种订阅 + 二维码 + 节点列表，一键复制、手机扫码导入；只读（服务器管理走 SSH）。
- **Komari 探针**：`install.sh komari` 傻瓜式装 [Komari](https://github.com/komari-monitor/komari) 监控 agent（可选，与代理无关）。
- **路由防护**：服务端默认**拦 BT/PT**（防被商家封机收滥用投诉）+ **MRS 广告规则拦截**（`ENABLE_BLOCK_BT=0` / `ENABLE_BLOCK_ADS=0` 可关）。
- **备份迁移**：`install.sh backup` 把密钥+配置+证书打成一个包，新 VPS 上 `restore <文件>` 一条命令重建——**凭证/订阅路径不变，客户端不用换密码**（换机器只需把订阅 URL 的 IP 改成新 IP，或用域名直接重指 DNS）。
- **SSH 加固**：`install.sh harden` 一键密钥登录+禁密码+fail2ban，强护栏防锁死（见下方第 3 节）。
- **WARP 解锁分流**：`install.sh warp` 把 OpenAI/Claude/Gemini/Netflix/Disney+ 走 Cloudflare WARP 出口（机房 IP 被拉黑时解锁），其余直连；走 WARP 的站点用 `WARP_SITES` 可自定义；带「校验不过自动回滚」护栏，不会弄坏现有节点。
- **订阅 443 HTTPS（可选）**：TCP 443 在 VLESS 下线后已经空出。把域名证书放到 `/etc/sing-box/sub.crt` 与 `/etc/sing-box/sub.key` 后重跑，订阅自动升级为 `https://域名/随机路径`；未知 SNI 命中 443 默认 server 后 444 关闭（黑洞）。
- **不需要域名**：默认用公网 IP 提供订阅（也支持你自带域名）。
- **自动随机化**：随机订阅路径、随机密码，旧路径与首页返回 404。
- **流量统计/限流**：vnstat + 定时任务，订阅头显示已用/额度/到期；超额自动停、月初自动恢复；**默认按出站(tx)计费**（匹配多数商家；代理 rx≈tx，rx+tx 会翻倍误算）；手动停机不会被定时任务拉起。
- **安全细节**：`server_tokens off`、密钥文件 600、流量头只挂在订阅路径（不污染首页/404）。
- **网络优化（自动）**：装前即应用 sysctl 调优——**UDP 收发缓冲 16MB**（Hysteria2/QUIC 关键，否则被限速并刷 quic-go 告警）、跨境高 BDP 链路的 TCP 缓冲、MTU 探测、空闲不重置拥塞窗口、TFO 等；内核策略固定为**发行版/云厂商官方稳定内核 + `fq + bbr`**，不安装 XanMod 或第三方 BBRv3 内核（`ENABLE_BBR=0` 可关 BBR）。
- **HY2 混淆**：salamander 混淆默认开（抗 QUIC 识别，`ENABLE_OBFS=0` 关）；不再提供端口跳跃、brutal 带宽和服务端带宽护栏，统一自动拥塞控制。
- **可选**：ufw（默认关，避免锁死 SSH）。
- **不破坏现有节点**：二次运行复用已有密钥；老 env/secrets 里的 VLESS/Reality/HY2 进阶键会被安全忽略并在重写时移除。
- **事务化维护**：安装后半段、`set`、`panel-pass` 以及订阅/看板文件组都先快照再发布；任一步失败会恢复旧配置，自动回滚不完整时保留备份路径并明确报警。
- **并发保护**：修改型命令使用维护锁，同一时间只允许一个 `install/warp/set/restore/panel-pass` 等动作，避免两个旧快照互相覆盖。

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
- **公网 IP**：IPv4 最省事。纯 IPv6 机现已支持（自动识别并开 `ipv6: true`，订阅与 DNS 段同步；私有 IPv6 由 `meta-private-ip` 覆盖；分享链接自动加方括号），但**客户端网络必须有 IPv6** 才连得上；建议配好 AAAA 后用 `NODE_ADDR=你的域名`。
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
- **KVM**：完整支持，BBR / 16MB UDP 大缓冲全部生效。
- **容器型（OpenVZ/LXC）**：核心三协议能跑，但共享宿主内核 → BBR 可能改不了、`net.core.rmem_max` 等 sysctl 可能被限制（HY2 大缓冲提速用不上）。这些都做了**非致命处理**（失败只告警、不影响装和直连），但想要满血网络优化请选 **KVM**。

---

## 按机型选协议组合

默认三协议全开，适合大多数 KVM 小鸡。但有些机器不适合跑 UDP/QUIC，按下表调整（与 `节点搭建文档.md` 的同名表一致）：

| 机型 | 推荐组合 | 装法 |
|---|---|---|
| **普通 KVM / 大多数 VPS** | 三协议全开（默认） | `bash install.sh` |
| **甲骨文 ARM / 小内存机** | AnyTLS + SS2022(TCP) | `ENABLE_HY2=0 SS_UDP=0 bash install.sh` |
| **被 DDoS 清洗过的机器** | 稳定优先去 HY2 | `ENABLE_HY2=0 bash install.sh` |
| **纯 IPv6 机** | 同上，节点地址用域名 | 配 AAAA + `NODE_ADDR=你的域名` |

> 已经装过的机器改主意也可以：重跑时带上开关即可（如 `ENABLE_HY2=0 bash install.sh`），脚本会去掉 HY2 入站、从订阅和分享链接里移除该节点，并清理旧版端口跳跃残留。密钥、订阅路径、其它协议都不受影响。

## 常用环境变量

全部可选，覆盖默认值即可。例：

```bash
LIMIT_GB=500 COUNT_MODE=tx AIRPORT_NAME=JP-01 bash install.sh
```

> 重装保参数：二次运行 `install.sh` 会沿用 `/etc/sing-box-node.env` 里已有的 `LIMIT_GB`/`EXPIRE_AT`/`COUNT_MODE` 等；本次显式传入的环境变量仍然优先。所以升级重跑不会把你 `set` 过的配置打回默认值。
>
> 状态兼容：端口、SNI、节点地址、机场名、协议开关等现已完整持久化。升级老版本时若 env 缺这些键，脚本会从已有订阅/看板回填后再重写，避免单独运行 `set`/`panel` 时用默认值覆盖真实节点参数。

| 变量 | 默认 | 说明 |
|---|---|---|
| `LIMIT_GB` | `200` | 每月显示/限流额度（GB） |
| `COUNT_MODE` | `tx` | 计费方式：`tx` 只算出站(默认,匹配多数商家) / `max` 取较大 / `rx+tx` 双向相加(仅真按进+出计费才用) |
| `EXPIRE_AT` | 空(订阅不显示到期) | 到期时间，**必须**是 `YYYY-MM-DD HH:MM:SS +0800` 格式（四位时区偏移，不能写 `+08:00` 或省略）。格式不对脚本会在开头直接报错退出，不会装到一半才崩。 |
| `DOMAIN` | 空（用 IP） | 订阅域名（仅支持单个）；填了需自己把 DNS A 记录指向本机 IP。脚本只处理一个订阅域名，需要备用域名请手动改 nginx 的 `server_name`。 |
| `AIRPORT_NAME` | `US-01` | 客户端里的订阅显示名 |
| `PUBLIC_IP` | 自动探测 | 探测失败时手动指定。探测顺序: curl v4 → ip -4 路由 → curl v6 → ip -6 路由, 纯 IPv6 机也能自动识别 |
| `NODE_ADDR` | 同 `PUBLIC_IP` | 节点 `server:` 用的连接地址。**纯 IPv6 机建议填已配 AAAA 的域名**(不少客户端对 IPv6 字面量支持不好)；填了不影响订阅 URL |
| `HY2_PORT` / `ANYTLS_PORT` / `SS_PORT` | `443` / `4434` / `4435` | 各协议端口（HY2 走 UDP，SS2022 同时用 TCP+UDP；三者必须互不相同） |
| `SS_METHOD` | `2022-blake3-aes-128-gcm` | SS2022 加密方法（可改 `2022-blake3-aes-256-gcm` / `2022-blake3-chacha20-poly1305`，密钥长度脚本自动适配） |
| `TLS_SNI` | `www.bing.com` | HY2/AnyTLS 自签证书 CN 与客户端 SNI |
| `SUB_TLS` | `auto` | 订阅传输：`auto`=有 `DOMAIN` 且证书就位就走 443 HTTPS；`1`=强制（缺证书报错）；`0`=只用 80 HTTP |
| `ENABLE_HY2` | `1` | 是否部署 **Hysteria2**。`0` = 不装：不写 hy2 入站、订阅与分享链接不含 HY2、不放行其 UDP 端口。甲骨文小机、或被 DDoS 清洗过的机器走 TCP 组合时用（见下方「按机型选协议组合」） |
| `SS_UDP` | `1` | SS2022 是否走 UDP。`0` = TCP-only 稳定版：订阅写 `udp: false`、服务端 `network: tcp`、不放行 SS 的 UDP 端口 |
| `ENABLE_BBR` | `1` | 开启 BBR（纯 sysctl，安全） |
| `ENABLE_UFW` | `0` | 自动配置并**启用** ufw（默认关，避免把自己 SSH 关在外面） |
| `ENABLE_OBFS` | `1` | HY2 **salamander 混淆**，让 Hysteria2 不像 QUIC（默认开，抗 QUIC 整体识别/限速；`0` 关） |
| `ENABLE_BLOCK_BT` | `1` | **拦截 BT/PT**（默认开）。很多商家封 BT，挂了会收滥用投诉甚至停机；`0` 关 |
| `ENABLE_BLOCK_ADS` | `1` | **广告规则拦截**（默认开，MRS `category-ads-all`）；`0` 关 |

> 已下线参数：`VLESS_PORT` / `REALITY_SNI` / `HY2_HOP_RANGE` / `HY2_UP` / `HY2_DOWN` / `HY2_UP_MBPS` / `HY2_DOWN_MBPS`。老机器的 env 里仍有这些键也能正常升级（读取后丢弃并重写移除），但**显式传入会直接报错**，避免"以为生效实际没配"。

`COUNT_MODE` 怎么选：默认 `tx`（只算出站）对绝大多数机器正确——Vultr/DigitalOcean/AWS/GCP/Hetzner 等都只按出站计费，`tx` 正好等于真实用量。代理是转发、每字节过网卡两次（rx≈tx），所以 `rx+tx`≈2×真实用量，在这些机器上会把用量翻倍、提前半量误停机；**只有商家真的按"进+出"双向计费才改 `rx+tx`**（很少见）。

> 装前会校验输入，不合法会在**开头**直接报错退出（不会装到一半才崩）：端口须为 `1–65535` 的整数且互不相同；`TLS_SNI` / `DOMAIN` 只能含字母、数字、`.`、`-`；`EXPIRE_AT` 须为 `YYYY-MM-DD HH:MM:SS ±0800` 这种**四位**时区偏移（`±0800`，不能写 `+08:00` 或省略；负偏移如 `-0500` 也可以）。

---

## 管理命令

```bash
sudo bash install.sh menu        # 交互菜单(把下面所有功能串起来, 不想记命令就用它)
sudo bash install.sh info        # 重新打印订阅 URL 和节点信息
sudo bash install.sh panel       # 打印可视化看板页地址(浏览器看订阅+扫码+复制)
sudo bash install.sh panel-pass <密码>   # 给看板页加登录(自定义登录页 + nginx 真鉴权; 关闭: panel-pass off)
sudo bash install.sh links       # 打印每个节点分享链接 + 两个订阅 URL(+ 二维码)
sudo bash install.sh status      # 状态体检: 服务/配置/端口/时间/证书/限额/订阅可达
sudo bash install.sh doctor      # 一键自检常见坑: sysctl调优/防火墙+安全组/证书到期/外部可达/内存+swap+IO压力, 带修复提示
sudo bash install.sh set LIMIT_GB=500 COUNT_MODE=tx   # 可改 LIMIT_GB/EXPIRE_AT/COUNT_MODE/INTERFACE/SUB_TLS; 其余参数带环境变量重跑 install.sh
sudo bash install.sh backup      # 打包密钥+配置 -> /root/sing-box-backup-时间.tar.gz
sudo bash install.sh restore <文件>   # 新 VPS 上恢复；直连凭证不变
sudo bash install.sh harden      # SSH 加固: 密钥登录+禁密码+fail2ban(必须先有授权公钥)
sudo bash install.sh warp        # WARP 解锁分流: OpenAI/Claude/Gemini/Netflix/Disney 走 WARP(关闭: warp off)
sudo bash install.sh admin       # 网页管理面板(仅 127.0.0.1+SSH隧道+token, 改限额/到期/重启/备份; 关闭: admin off)
sudo bash install.sh update      # 更新 sing-box 到最新版并重启
sudo bash install.sh restart     # 重启 sing-box / nginx
sudo bash install.sh cf off      # 清理旧版 CF-VLESS 留下的 cloudflared 与状态(一键安装路径已下线)
sudo KOMARI_ENDPOINT=https://面板 KOMARI_TOKEN=token bash install.sh komari   # 装 Komari 探针 agent
sudo bash install.sh uninstall   # 卸载（FORCE=1 跳过确认；删前自动备份密钥）
```

### 可视化看板页
装完会多打印一个**看板页地址** `http://<IP>/panel-xxxx.html`（启用订阅 HTTPS 后为 `https://域名/panel-xxxx.html`），浏览器打开就是一个自包含页面：
- **两种整段订阅**（Clash YAML / 通用 base64）：一键复制 + 二维码 + **一键导入按钮**（`clash://install-config` / `shadowrocket://add/sub://`，点一下直接拉进客户端）。
- **每个节点独立卡片**：单条分享链接（复制）+ 各自二维码，方便只导入某一个节点。
- **流量 / 到期**：静态显示限额+到期，并实时拉订阅响应头显示「已用」。
- **延迟自测**：测到本机的 HTTP 往返延迟（参考——浏览器测不了各协议的真实代理延迟）。
- **明暗主题**切换（记住选择）。

`install.sh links` 也会打印这些深链文本。随时 `install.sh panel` 重新拿地址。仍是**纯静态只读**页面（无后端、不开管理端口），管理一律走 SSH。
> 它是**只读**的（看/复制/扫码），**不在网页上操作服务器**——改限额/重启等用下面的「网页管理面板」或 SSH 的 `install.sh menu`。看板页**含全部节点凭证、默认走明文 HTTP**，和订阅一样：随机路径、别外传、不可信网络上 HTTPS。

**给看板页加登录**：嫌「知道链接就能直接打开」不安全，可以加一道登录——一个和看板同款的**自定义登录页**，输密码才放行：
```bash
sudo bash install.sh panel-pass 'your-strong-pass'   # 打开看板会先跳到登录页(密码限 小写字母数字 . _ ~ -, ≥6 位；不能以 ~ 开头)
sudo bash install.sh panel-pass off                  # 关闭登录
```
原理是 **nginx 服务端校验**（真鉴权，不是网页里的 JS 假门）：登录页让你输密码 → JS 把密码写进 cookie 并跳转看板 → **nginx 用 `map` 比对 cookie 是否等于密码**，不对就跳回登录页。密码**只存在 `600 root` 的 `/etc/nginx/.singbox_panel_map.conf`**（由 nginx master 加载，从不下发浏览器），所以 `查看源代码`/`curl` 都拿不到——这点和「网页里弹个 JS 密码框、凭证就在源码里」的**假安全**有本质区别。
> 边界：明文 HTTP 下 cookie 不加密（同网段可被嗅探），它挡的是「知道链接的人」，要**真加密**请启用订阅 443 HTTPS 或自行套 Tunnel；登录无限速，请用**强密码**（`openssl rand -hex 12`）。密码不能以 `~` 开头，也不能使用 nginx `map` 保留字。`map` 片段与登录页 **不随 `backup` 迁移**，换机后重设一次。

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

- `set` 可改的键：`LIMIT_GB`（每月额度 GB）、`EXPIRE_AT`（到期，四位时区如 `+0800`）、`COUNT_MODE`（`rx+tx`/`tx`/`max`）、`INTERFACE`（统计网卡）、`SUB_TLS`（`auto`/`1`/`0`）。改完即时重写流量头，客户端下次拉订阅就生效。
- `links` 若装了 `qrencode`（依赖里已含），会顺带打印通用订阅的二维码，手机扫码即导入。

### 两种订阅，按客户端选
- **Clash/Mihomo**：用 `http://<IP>/<随机.yaml>`（默认那条），支持分流规则、显示流量。
- **v2rayN / Shadowrocket / NekoBox 等**：用**通用(base64)订阅** `http://<IP>/<随机-b64.txt>`，里面是各节点的分享链接。
- 只想要单条节点：`install.sh links` 直接把 `hysteria2://`/`anytls://`/`ss://` 打印出来复制。
> 注：`anytls://` 较新，只有 mihomo / sing-box 系客户端认；v2rayN 等用 hysteria2/ss 那两条即可。两种订阅都带流量头，客户端都能显示已用/到期。

---

## 本机无法自动完成的部分（脚本会提示，这里是详解）

这些受限于平台/账号，脚本管不了，需你手动处理：

### 1. 云服务商安全组（最常见的坑）
脚本能配主机内的 ufw，但**改不了云端安全组**（阿里云/腾讯云/Oracle/AWS 等控制台里的入站规则）。云安全组默认拒绝入站、而且经常拦 UDP。请在控制台放行：

```
22/tcp  80/tcp  443/tcp  4434/tcp  4435/tcp  443/udp  4435/udp
```

- `443/udp` 是 HY2（默认端口）；`443/tcp` 只有启用订阅 HTTPS 时才需要（脚本按实际配置提示）。
- `4435/udp` 只有 SS2022 走 UDP 时需要；`SS_UDP=0` 时不用放行。

> 现象：HY2（UDP）连不上、AnyTLS（TCP 4434）却正常 = 八成是 UDP 没放行。注意本机 `ss -lntup` 只证明在监听，证明不了外部能连进来。

### 2.（可选，但在不可信网络下强烈建议）域名 + HTTPS 订阅
默认用 `http://<IP>/<随机路径>` 提供订阅。**两个订阅文件（Clash YAML 和通用 base64）都含全部节点凭证（密码等），HTTP 是明文传输**——base64 只是编码不是加密，同样能被嗅探：随机路径只能防扫描，挡不住在途嗅探——任何能抓到这次订阅请求的人（机房、运营商、出口路由）一次就拿到全套凭证、直接接管你的节点。

推荐做法（TCP 443 现在已空出，不需要 Cloudflare）：

1. 把域名 DNS A/AAAA 记录指向本机，安装时加 `DOMAIN=node.example.com`（或装完后在 env 里补上再重跑）。
2. 用你惯用的方式（acme.sh / certbot / 商家面板）签发证书，把 **fullchain** 和 **私钥** 分别放到：
   ```
   /etc/sing-box/sub.crt
   /etc/sing-box/sub.key
   ```
   也可以用 `SUB_CERT=/etc/sing-box/其它名.crt SUB_KEY=/etc/sing-box/其它名.key` 指定同目录下的其它文件名（限制在该目录内，才能随 `backup` 一起迁移）。
3. 重跑 `sudo bash install.sh`（或 `install.sh set SUB_TLS=1`）。脚本检测到 `DOMAIN` + 证书就自动给订阅 server 加 `listen 443 ssl`，订阅 URL 变成 `https://node.example.com/随机路径`；443 默认 server 对未知 SNI 直接 444 关闭，不暴露任何内容。
4. 证书续期后重跑一次 `install.sh` 让 nginx 加载新证书（`doctor` 会检查 30 天到期）。

- 临时缓解：拉完就把订阅文件删掉、只在本地保存。
- ⚠️ **换 `SUB_PATH` 不等于换凭证**：订阅一旦被截获，里面的密码就已经泄露，换个随机路径只能挡住"别人继续拉订阅"，旧凭证照样能直连你的节点。真怀疑被截获时要**重置节点凭证**——删掉 `/etc/sing-box/node-secrets.env` 里对应的密码行后重跑 `bash install.sh`（会重新生成并重写订阅），然后让所有客户端重新拉取。

### 3.（可选，强烈建议）SSH 加固
VPS 最大的风险是 22 端口被爆破——一旦失守整台机器连同密钥全没。现在有一键加固：
```bash
# 第一步(在你本地电脑)：ssh-copy-id root@<IP>，并确认能用密钥登录
sudo bash install.sh harden    # 仅密钥登录 + 禁密码 + fail2ban
```
护栏：**必须先检测到 `/root/.ssh/authorized_keys` 里有公钥才动手**（否则拒绝，防把你锁在门外）；用 `00-` 开头的 drop-in 覆盖 cloud-init 默认的 `PasswordAuthentication yes`；`sshd -t` 校验不过自动回滚。**改完务必另开一个新终端用密钥登录确认能进，再关掉旧会话。**

### 4.（可选）WARP 解锁分流（OpenAI / Claude / Gemini / Netflix / Disney+）
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

> **CF-VLESS 一键路径已下线**：2026-10 现网口径只保留经验证的自有 Cloudflare WebSocket 节点，由各自 Tunnel 与域名单独维护，不再走本脚本。老机器上由旧版 `install.sh cf` 装的 cloudflared 和 `cf.env` 可用 `install.sh cf off` 清理；`install`/`restore` 也不会再把旧 CF 节点写回订阅。

---

## 它装了哪些文件

```
/etc/sing-box/config.json          sing-box 服务端配置 (600)
/etc/sing-box/server.{crt,key}     HY2/AnyTLS 自签证书
/etc/sing-box/sub.{crt,key}        可选订阅 HTTPS 证书(你自己放, 存在即启用 443)
/etc/sing-box/node-secrets.env     密钥与随机路径 (600，复用用)
/etc/sing-box-node.env             运行参数单一来源 (600)
/var/www/html/sub-xxxx.yaml        Clash/Mihomo 订阅(644，含凭证，见安全须知)
/var/www/html/sub-b64-xxxx.txt     通用(base64)订阅(644，含凭证，供 v2rayN 等)
/var/www/html/panel-xxxx.html      可视化看板页(644，含凭证)
/etc/nginx/conf.d/00-singbox-sub.conf   订阅 server 块(仅 server 块；流量头单独在 snippets 内、只对订阅 location include，首页/404 不带头)
/etc/nginx/snippets/sub_headers.conf    流量头(只挂订阅路径)
/usr/local/bin/traffic_limit.py    流量统计/限流
/etc/cron.d/traffic_limit          每 5 分钟刷新
/etc/sysctl.d/99-singbox.conf      网络优化(UDP 16MB 大缓冲 / 跨境 TCP 调优 / fq + bbr)
```

> 旧版遗留的 `/etc/sing-box/cf.env`、`/etc/sing-box/porthop.nft`、`sing-box-porthop.service` 不再创建；重装会自动清端口跳跃，CF 状态用 `cf off` 清理。

---

## 排查

**连不上先跑 `sudo bash install.sh doctor`**——它会一次性核对服务/配置/端口/sysctl 调优/防火墙/安全组/时间/证书/订阅内外可达，并给出每一项的修复命令。下面是手动逐项排查：

```bash
systemctl is-active sing-box nginx vnstat        # 服务在跑?
sing-box check -c /etc/sing-box/config.json      # 配置合法?
nginx -t                                         # nginx 合法?
ss -lntup | grep -E ':(80|443|4434|4435)\b'      # 本地在监听?(端口为默认值; 改过端口请替换。不代表外部可达)
curl -I http://<IP或域名>/<订阅路径>             # 订阅 200 且带 Subscription-Userinfo?
journalctl -t traffic_limit -n 20 --no-pager     # 流量脚本日志
timedatectl                                      # 时间同步?(TLS 握手对时钟敏感)
```

- **订阅打不开**：先看云安全组是否放行 80/tcp（启用 443 HTTPS 时还要 443/tcp）。
- **HY2 / SS2022 连不上但 AnyTLS 正常**：云安全组没放行 UDP（HY2 的 `443/udp`、SS2022 的 `4435/udp`）。
- **SS2022 连不上**：确认云安全组放行了 `4435` 的 **TCP 和 UDP**；客户端 mihomo 需较新版本支持 `2022-blake3-*` 加密。
- **订阅不显示流量**：核对 `/etc/sing-box-node.env` 里的 `INTERFACE`（`ip -br link` 查真实网卡），看 `journalctl -t traffic_limit`。
- **HTTPS 订阅握手失败**：确认证书域名与 `DOMAIN` 一致、`sub.crt` 是 fullchain（含中间证书）、nginx 已 reload；`doctor` 会提示证书缺失/即将过期。

---

## 安全须知与取舍

一键脚本图省事，但有几个取舍你应当知情：

- **供应链信任**：本脚本以 root 运行，且内部用 `curl -fsSL https://sing-box.app/install.sh | sh` 安装 sing-box——没有固定版本、没有签名/SHA256 校验。一旦该域名/CDN 被劫持，攻击者可在你机器上以 root 执行任意代码。在意的话：先把本脚本和 sing-box 安装脚本读一遍，或改用发行版包 / 手动下载校验 release 的 SHA256 后再装。
- **订阅明文凭证**：两份订阅（Clash YAML 与通用 base64）默认走明文 HTTP、都含全部节点凭证，base64 只是编码不是加密；链路可被嗅探则节点失守。详见上方「2. 域名 + HTTPS 订阅」，不可信网络务必上 HTTPS。
- **HY2 / AnyTLS 用自签证书 + `skip-cert-verify: true`**：等于客户端不校验服务端身份，能做在途 MITM 的攻击者可冒充节点、解密/篡改流量且客户端不报警。这是自签方案的固有代价；要抗 MITM 需给节点换成真实证书并去掉 `skip-cert-verify`（本脚本默认不折腾节点证书）。
- **文件权限**：密钥、私钥、`config.json`、`*-secrets.env`、运行参数 env 均为 600，`/etc/sing-box` 目录 700，脚本运行期 `umask 077`（创建瞬间即限权）。订阅文件为 644（nginx 需要读）——同机若有不可信的本地用户，注意它可读。
- **防火墙不自动启用**：`ENABLE_UFW` 默认 0，避免把你的 SSH 关在门外；显式开启时脚本会先确认放行 22 再 enable。
- **卸载会先备份**：`uninstall` 删除前自动把密钥/参数备份到 `/root/sing-box-uninstall-backup-<时间戳>/`，避免一条命令不可逆地销毁全部凭证；它不碰你手动搭的 cloudflared。

最该补的一件事仍是 **SSH 加固**（见上方第 3 条）——host 被爆破，代理调得再好也归零。

---

## 内核政策

**只使用云厂商或发行版官方稳定内核，配合 `fq + bbr` 与 16 MiB UDP 默认/最大缓冲。**

- 脚本写入的 `/etc/sysctl.d/99-singbox.conf` 已包含 `net.core.default_qdisc=fq`、`net.ipv4.tcp_congestion_control=bbr`，以及 `rmem_max/wmem_max=16777216`（HY2/QUIC 跑满带宽的前提）。
- **不安装 XanMod、byJoey 或其它第三方内核/BBRv3 包**：换内核需要重启，起不来会失联，只能靠控制台/救援模式救回；而 BBR 只作用于 TCP（AnyTLS），HY2 走 UDP/QUIC 自带拥塞控制，v1→v3 的边际收益有限，风险与收益不匹配。
- 云厂商官方内核（如 GCP、Oracle、AWS 的 `linux-*-gcp`/`linux-oracle`）与发行版内核都会正常带上 `fq + bbr`，无需额外操作。`doctor` 会检查 `net.ipv4.tcp_congestion_control` 是否为 `bbr`。

---

## 免责声明

仅供学习与自用网络代理搭建。请遵守你所在地区与 VPS 服务商的法律法规和服务条款，自行承担使用风险。
