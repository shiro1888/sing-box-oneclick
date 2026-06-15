#!/usr/bin/env bash
# =============================================================================
#  sing-box 四协议一键部署脚本
#  Hysteria2 + AnyTLS + VLESS-Reality-Vision + Shadowsocks-2022  ->  Clash/Mihomo 订阅
#
#  用法:
#    一键(在线):  bash <(curl -fsSL https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh)
#    本地:        sudo bash install.sh [install|info|panel|links|status|doctor|set|backup|restore <file>|harden|update|restart|cf|warp [off]|komari|menu|uninstall]
#    交互菜单:    sudo bash install.sh menu
#    可视化看板:  sudo bash install.sh panel        (浏览器看订阅+扫码)
#    装探针:      KOMARI_ENDPOINT=https://面板 KOMARI_TOKEN=token sudo bash install.sh komari
#
#  常用环境变量(可选,覆盖默认):
#    LIMIT_GB=200            每月显示/限流额度
#    COUNT_MODE=rx+tx        计费方式 rx+tx|tx|max
#    EXPIRE_AT="..."         到期时间(默认安装日+365天)
#    DOMAIN=node.example.com 订阅域名(留空=用公网IP,无需域名)
#    AIRPORT_NAME=MyNode     客户端订阅显示名
#    PUBLIC_IP=1.2.3.4       手动指定公网IP(探测失败时)
#    HY2_PORT/ANYTLS_PORT/VLESS_PORT/SS_PORT  端口(默认 4433/4434/443/4435)
#    SS_METHOD=2022-blake3-aes-128-gcm  SS2022 加密方法(可改 256-gcm/chacha)
#    REALITY_SNI/TLS_SNI     伪装域名(默认 www.microsoft.com / www.bing.com)
#    ENABLE_BBR=1            开启 BBR(默认开,纯 sysctl,安全)
#    ENABLE_UFW=0            自动配置并启用 ufw(默认关,避免锁死SSH)
#    ENABLE_OBFS=1           HY2 salamander 混淆(默认开, 抗 QUIC 识别)
#    ENABLE_BLOCK_BT=1       拦截 BT/PT(默认开, 防被商家封机收滥用投诉)
#    ENABLE_BLOCK_ADS=1      geosite 拦广告(默认开, 远程 rule_set)
#    HY2_HOP_RANGE=20000-50000  HY2 端口跳跃 UDP 段(需 nftables + 云安全组放行整段)
#    HY2_UP=50 HY2_DOWN=200      HY2 brutal 带宽 Mbps(要填你真实带宽, 烂线路提速)
#
#  可选第5节点 CF-Vless(大保底, 需先在 CF 后台建 Tunnel 拿 token+域名):
#    CF_TOKEN=... CF_HOSTNAME=cf.example.com  bash install.sh cf
#
#  适配: Debian/Ubuntu(完整) ; RHEL系 dnf/yum(尽力,nginx 默认站点可能需手动处理)
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------- 输出
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
log()  { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 收集"需要你手动完成"的说明,结尾统一打印
NOTES=()
note() { NOTES+=("$*"); }

PY="${PYTHON:-python3}"

# ----------------------------------------------------------------- 配置(env 可覆盖)
LIMIT_GB="${LIMIT_GB:-200}"
COUNT_MODE="${COUNT_MODE:-rx+tx}"
DOMAIN="${DOMAIN:-}"
AIRPORT_NAME="${AIRPORT_NAME:-MyNode}"
HY2_PORT="${HY2_PORT:-4433}"
ANYTLS_PORT="${ANYTLS_PORT:-4434}"
VLESS_PORT="${VLESS_PORT:-443}"
SS_PORT="${SS_PORT:-4435}"
SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
CF_PORT="${CF_PORT:-28080}"   # CF-Vless 本地 WS 入站端口(只听 127.0.0.1)
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
TLS_SNI="${TLS_SNI:-www.bing.com}"
ENABLE_BBR="${ENABLE_BBR:-1}"
ENABLE_UFW="${ENABLE_UFW:-0}"
ENABLE_OBFS="${ENABLE_OBFS:-1}"      # HY2 salamander 混淆(默认开, 抗 QUIC 识别; 0 关)
ENABLE_BLOCK_BT="${ENABLE_BLOCK_BT:-1}"    # 拦截 BT/PT(默认开, 防被商家封机收滥用投诉; 0 关)
ENABLE_BLOCK_ADS="${ENABLE_BLOCK_ADS:-1}"  # geosite 拦广告(默认开; 用远程 rule_set; 0 关)
KOMARI_ENDPOINT="${KOMARI_ENDPOINT:-}"  # Komari 探针面板地址(install.sh komari 用)
KOMARI_TOKEN="${KOMARI_TOKEN:-}"        # Komari 节点 token
HY2_HOP_RANGE="${HY2_HOP_RANGE:-}"   # HY2 端口跳跃 UDP 段(如 20000-50000, 空=不启用; 需 nftables+云安全组放行整段)
HY2_UP="${HY2_UP:-}"                 # HY2 brutal 上行 Mbps(空=自适应; 设了即开暴力模式, 要填你真实带宽)
HY2_DOWN="${HY2_DOWN:-}"             # HY2 brutal 下行 Mbps(同上)

# 路径
SB_DIR=/etc/sing-box
SECRETS="$SB_DIR/node-secrets.env"
ENVFILE=/etc/sing-box-node.env
WWW=/var/www/html
NGINX_SNIPPET=/etc/nginx/snippets/sub_headers.conf
NGINX_CONF=/etc/nginx/conf.d/00-singbox-sub.conf
TRAFFIC_PY=/usr/local/bin/traffic_limit.py
CRON=/etc/cron.d/traffic_limit
SYSCTL_CONF=/etc/sysctl.d/99-singbox.conf
CF_ENV="$SB_DIR/cf.env"   # CF-Vless 状态(存在=已接入第5节点; 由 cf 子命令写入)
WARP_ENV="$SB_DIR/warp.env"   # WARP 解锁状态(存在=已接入; 由 warp 子命令写入)

# 运行期填充(写成可被环境覆盖, 既不影响生产, 也便于测试渲染函数)
PKG="${PKG:-}"; OS_ID="${OS_ID:-}"; PUBLIC_IP="${PUBLIC_IP:-}"; SUB_HOST="${SUB_HOST:-}"
INTERFACE="${INTERFACE:-}"; SB_VER="${SB_VER:-}"
ANYTLS_OK="${ANYTLS_OK:-1}"; EXPIRE_VALUE="${EXPIRE_VALUE:-}"
# 密钥(gen_secrets 填充或从 SECRETS 复用)
HY2_PASSWORD="${HY2_PASSWORD:-}"; ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"; VLESS_UUID="${VLESS_UUID:-}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"; REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"; SUB_PATH="${SUB_PATH:-}"; SS_PASSWORD="${SS_PASSWORD:-}"
SUB_B64_PATH="${SUB_B64_PATH:-}"   # 通用(base64)订阅路径(供 v2rayN 等; gen_secrets 生成)
OBFS_PASSWORD="${OBFS_PASSWORD:-}" # HY2 obfs 密码(非空=启用 obfs; gen_secrets 生成)
PANEL_PATH="${PANEL_PATH:-}"       # 可视化看板页路径(随机; gen_secrets 生成)
# CF-Vless(可选第5节点; cf.env 提供, 空=未接入)
CF_HOSTNAME="${CF_HOSTNAME:-}"; CF_VLESS_UUID="${CF_VLESS_UUID:-}"; CF_WS_PATH="${CF_WS_PATH:-}"
# WARP 解锁分流(warp.env 提供; WARP_PRIVATE_KEY 非空=启用)
WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"; WARP_ADDR_V4="${WARP_ADDR_V4:-}"; WARP_ADDR_V6="${WARP_ADDR_V6:-}"; WARP_RESERVED="${WARP_RESERVED:-}"
WARP_SITES="${WARP_SITES:-}"   # 走 WARP 的 geosite 列表(逗号分隔, 可自定义; 空=render 用默认 openai,netflix,disney)

# ----------------------------------------------------------------- 工具
need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行(sudo bash install.sh)"; }

ver_ge() { # ver_ge A B  -> A >= B ?
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# 装前输入校验(端口/SNI/域名/到期时间), 不合法立即报错, 避免装到一半才崩
validate_inputs() {
  local p
  for p in "$HY2_PORT" "$ANYTLS_PORT" "$VLESS_PORT" "$SS_PORT"; do
    case "$p" in ''|*[!0-9]*) die "端口必须是数字: '$p'";; esac
    { [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || die "端口超出范围 1-65535: '$p'"
  done
  case "$REALITY_SNI" in *[!A-Za-z0-9.-]*) die "REALITY_SNI 含非法字符: '$REALITY_SNI'";; esac
  case "$TLS_SNI"     in *[!A-Za-z0-9.-]*) die "TLS_SNI 含非法字符: '$TLS_SNI'";; esac
  [ -z "$DOMAIN" ] || case "$DOMAIN" in *[!A-Za-z0-9.-]*) die "DOMAIN 含非法字符: '$DOMAIN'";; esac
  if [ -n "${EXPIRE_AT:-}" ]; then
    [[ "$EXPIRE_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] \
      || die "EXPIRE_AT 格式必须是 'YYYY-MM-DD HH:MM:SS +0800'(含四位时区偏移, 不能是 +08:00 或省略), 当前: '$EXPIRE_AT'"
  fi
  if [ -n "$HY2_HOP_RANGE" ]; then
    [[ "$HY2_HOP_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || die "HY2_HOP_RANGE 须为 起-止(如 20000-50000): '$HY2_HOP_RANGE'"
    local hs="${HY2_HOP_RANGE%-*}" he="${HY2_HOP_RANGE#*-}"
    { [ "$hs" -ge 1 ] && [ "$he" -le 65535 ] && [ "$hs" -lt "$he" ]; } || die "HY2_HOP_RANGE 端口段非法(1-65535 且 起<止): '$HY2_HOP_RANGE'"
    local op   # 端口段不能盖住正在监听的 UDP 端口(HY2/SS), 否则会把它也重定向到 HY2
    for op in "$HY2_PORT" "$SS_PORT"; do
      { [ "$op" -ge "$hs" ] && [ "$op" -le "$he" ]; } && die "HY2_HOP_RANGE($HY2_HOP_RANGE) 覆盖了 UDP 端口 $op, 会把它也重定向到 HY2; 请让端口段避开 HY2_PORT/SS_PORT"
    done
  fi
  local v
  for v in "$HY2_UP" "$HY2_DOWN"; do
    [ -z "$v" ] || case "$v" in *[!0-9]*) die "HY2_UP/HY2_DOWN 要是数字(Mbps): '$v'";; esac
  done
  [ -z "$OBFS_PASSWORD" ] || case "$OBFS_PASSWORD" in *[!A-Za-z0-9]*) die "OBFS_PASSWORD 只能含字母数字: '$OBFS_PASSWORD'";; esac
}

detect_os() {
  [ -r /etc/os-release ] && . /etc/os-release && OS_ID="${ID:-}"
  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  else die "未找到 apt/dnf/yum,暂不支持该系统。请参考 README 手动部署。"; fi
  command -v systemctl >/dev/null 2>&1 || die "本脚本依赖 systemd(systemctl), 当前系统未检测到(如 Alpine/OpenRC 不受支持)。"
  log "系统: ${OS_ID:-unknown}  包管理器: $PKG"
  [ "$PKG" = apt ] || note "非 Debian/Ubuntu 系统: nginx 默认站点布局不同, 如订阅返回默认页, 请手动删除其它 default_server。"
}

# ----------------------------------------------------------------- 安装步骤
install_deps() {
  log "安装依赖..."
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y curl wget tar jq nginx vnstat openssl cron python3 iproute2 ca-certificates ufw qrencode
      ;;
    dnf|yum)
      # vnstat / jq 在 RHEL 系常在 EPEL(+CRB), 先尝试启用, 否则流量统计会装不上
      "$PKG" install -y epel-release >/dev/null 2>&1 || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
        dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      "$PKG" install -y curl wget tar jq nginx vnstat openssl cronie python3 iproute ca-certificates qrencode || \
        warn "部分依赖安装失败, 继续(可能需手动补 vnstat/nginx)"
      ;;
  esac
  systemctl enable --now nginx   >/dev/null 2>&1 || true
  systemctl enable --now vnstat  >/dev/null 2>&1 || systemctl enable --now vnstatd >/dev/null 2>&1 || true
  systemctl enable --now cron    >/dev/null 2>&1 || systemctl enable --now crond   >/dev/null 2>&1 || true
  if ! command -v vnstat >/dev/null 2>&1; then
    warn "vnstat 未安装成功: 流量统计/限流将不可用"
    note "vnstat 缺失 → 流量显示/限流不工作。请手动安装 vnstat(RHEL 系需先启用 EPEL)后重跑本脚本。"
  fi
  ok "依赖就绪"
}

time_sync() {
  timedatectl set-ntp true >/dev/null 2>&1 || warn "无法自动开启 NTP, 请确认系统时间准确(Reality 对时钟敏感)"
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = no ]; then
    note "系统时间尚未同步(NTPSynchronized=no): Reality 可能握手失败(连得上但代理不通)。稍等几分钟或手动核对 timedatectl。"
  fi
}

install_singbox() {
  if ! command -v sing-box >/dev/null 2>&1; then
    log "安装 sing-box(官方脚本)..."
    curl -fsSL https://sing-box.app/install.sh | sh || true
  fi
  command -v sing-box >/dev/null 2>&1 || die "sing-box 安装失败(网络或官方脚本异常, 见上方报错)"
  SB_VER="$(sing-box version 2>/dev/null | awk '/version/{print $3; exit}')"
  SB_VER="${SB_VER#v}"; SB_VER="${SB_VER%%-*}"   # 去掉 v 前缀与 -beta/-rc 预发布后缀再比较
  if [ -n "$SB_VER" ] && ver_ge "$SB_VER" 1.12.0; then
    ANYTLS_OK=1
  else
    ANYTLS_OK=0
    note "sing-box 版本 ${SB_VER:-未知} < 1.12.0, 不支持 AnyTLS: 已自动跳过 AnyTLS, 部署 Hysteria2 + Vless + SS2022。升级 sing-box 后重跑本脚本即可补上 AnyTLS。"
    warn "sing-box ${SB_VER:-未知} 过旧, 跳过 AnyTLS"
  fi
  ok "sing-box 版本: ${SB_VER:-unknown} (AnyTLS: $([ "$ANYTLS_OK" = 1 ] && echo 启用 || echo 跳过))"
}

detect_net() {
  PUBLIC_IP="${PUBLIC_IP:-}"
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(curl -fsSL4 --max-time 8 https://api.ipify.org   2>/dev/null || true)"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(curl -fsSL4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [ -z "$PUBLIC_IP" ]; then
    # SOFT_DETECT=1(info 用)时探测失败不致命, 用占位符; 安装时仍直接报错
    [ "${SOFT_DETECT:-0}" = 1 ] && PUBLIC_IP="<未探测到IP>" || die "无法探测公网 IP, 请用 PUBLIC_IP=x.x.x.x 重新运行"
  fi
  INTERFACE="${INTERFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
  INTERFACE="${INTERFACE:-eth0}"
  SUB_HOST="${DOMAIN:-$PUBLIC_IP}"
  ok "公网 IP: $PUBLIC_IP   网卡: $INTERFACE"
  [ -n "$DOMAIN" ] && note "订阅域名 $DOMAIN: 请确认已把它的 DNS A 记录解析到 $PUBLIC_IP(本脚本无法替你改 DNS)。"
}

# SS2022 密钥: base64, 长度按方法自适应(128-gcm=16字节, 256/chacha=32字节)
gen_ss_password() {
  local b=16; case "$SS_METHOD" in *aes-256*|*chacha*) b=32;; esac
  openssl rand -base64 "$b" | tr -d '\n'
}

gen_secrets() {
  mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR" 2>/dev/null || true   # 目录对非 root 封闭
  if [ -f "$SECRETS" ]; then
    log "检测到已有密钥, 复用(不破坏现有客户端)"
    # shellcheck disable=SC1090
    . "$SECRETS"
    if [ -z "${SS_PASSWORD:-}" ]; then   # 旧版安装无 SS2022 密钥, 升级时补一个(不影响其它节点)
      SS_PASSWORD="$(gen_ss_password)"
      printf 'SS_PASSWORD="%s"\n' "$SS_PASSWORD" >>"$SECRETS"
      log "已为升级补充 SS2022 密钥"
    fi
    if [ -z "${SUB_B64_PATH:-}" ]; then  # 旧版无通用订阅路径, 升级时补一个
      SUB_B64_PATH="/sub-b64-$(openssl rand -hex 8).txt"
      printf 'SUB_B64_PATH=%s\n' "$SUB_B64_PATH" >>"$SECRETS"
    fi
    if [ -z "${PANEL_PATH:-}" ]; then    # 旧版无看板页, 升级时补一个
      PANEL_PATH="/panel-$(openssl rand -hex 8).html"
      printf 'PANEL_PATH=%s\n' "$PANEL_PATH" >>"$SECRETS"
    fi
    if [ -z "${OBFS_PASSWORD:-}" ] && [ "$ENABLE_OBFS" = 1 ]; then  # 升级开启 HY2 obfs
      OBFS_PASSWORD="$(openssl rand -hex 12)"
      printf 'OBFS_PASSWORD=%s\n' "$OBFS_PASSWORD" >>"$SECRETS"
      log "已为升级补充 HY2 obfs 密码"
    fi
    return
  fi
  log "生成密钥与随机参数..."
  HY2_PASSWORD="$(openssl rand -hex 16)"
  ANYTLS_PASSWORD="$(openssl rand -hex 16)"
  VLESS_UUID="$(sing-box generate uuid)"
  local kp; kp="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $NF}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$kp" | awk '/PublicKey/{print $NF}')"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  SUB_PATH="/sub-$(openssl rand -hex 8).yaml"
  SUB_B64_PATH="/sub-b64-$(openssl rand -hex 8).txt"
  PANEL_PATH="/panel-$(openssl rand -hex 8).html"
  SS_PASSWORD="$(gen_ss_password)"
  [ "$ENABLE_OBFS" = 1 ] && OBFS_PASSWORD="$(openssl rand -hex 12)"
  ( umask 077
    cat >"$SECRETS" <<EOF
HY2_PASSWORD=$HY2_PASSWORD
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
VLESS_UUID=$VLESS_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
SUB_PATH=$SUB_PATH
SUB_B64_PATH=$SUB_B64_PATH
PANEL_PATH=$PANEL_PATH
SS_PASSWORD="$SS_PASSWORD"
OBFS_PASSWORD=$OBFS_PASSWORD
EOF
  )
  chmod 600 "$SECRETS"
  ok "密钥已生成并保存到 $SECRETS (600)"
}

gen_cert() {
  if [ -f "$SB_DIR/server.crt" ] && [ -f "$SB_DIR/server.key" ]; then return; fi
  log "生成自签证书 (CN=$TLS_SNI)..."
  mkdir -p "$SB_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$SB_DIR/server.key" -out "$SB_DIR/server.crt" \
    -days 3650 -subj "/CN=$TLS_SNI" >/dev/null 2>&1
  chmod 600 "$SB_DIR/server.key"; chmod 644 "$SB_DIR/server.crt"
}

# 校验 Reality 偷证书目标(REALITY_SNI): 需支持 TLS1.3(硬性), 建议 H2。best-effort, 失败只提示不中断。
check_reality_sni() {
  command -v openssl >/dev/null 2>&1 || return 0
  local host="$REALITY_SNI" out
  log "校验 Reality 偷证书目标 $host (需 TLS1.3, 建议 H2)..."
  out="$( { echo | timeout 8 openssl s_client -connect "$host:443" -servername "$host" -alpn h2; } 2>/dev/null )" || true
  if ! printf '%s' "$out" | grep -q 'BEGIN CERTIFICATE'; then
    note "Reality 偷证书目标 $host:443 连不上(网络/被墙?), 没能校验。确认它在 VPS 上能直连且支持 TLS1.3(默认 www.microsoft.com 一般没问题)。"
    return 0
  fi
  if printf '%s' "$out" | grep -q 'TLSv1.3'; then
    if printf '%s' "$out" | grep -qE 'ALPN protocol: *h2$'; then
      ok "Reality SNI $host: TLS1.3 + H2 ✓"
    else
      note "Reality SNI $host 支持 TLS1.3 但未协商出 H2: 能用, 但建议换个支持 HTTP/2 的目标更隐蔽(如 www.microsoft.com)。"
    fi
  else
    note "Reality SNI $host 不支持 TLS1.3 ✗(偷证书目标的硬性要求, 握手会有问题): 换成确定支持 TLS1.3 的大站, 如 www.microsoft.com / www.cloudflare.com / www.apple.com。"
  fi
}

write_env() {
  local expire_default; expire_default="$(date -d '+365 days' '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo '2099-12-31 23:59:59 +0800')"
  EXPIRE_VALUE="${EXPIRE_AT:-$expire_default}"   # 单一来源, config_nginx 复用, 不再二次 grep
  cat >"$ENVFILE" <<EOF
# 由 install.sh 生成 —— 运行参数单一来源
LIMIT_GB=$LIMIT_GB
EXPIRE_AT="$EXPIRE_VALUE"
INTERFACE=$INTERFACE
COUNT_MODE=$COUNT_MODE
SUB_HOST="$SUB_HOST"
PUBLIC_IP="$PUBLIC_IP"
HY2_HOP_RANGE=$HY2_HOP_RANGE
HY2_UP=$HY2_UP
HY2_DOWN=$HY2_DOWN
ENABLE_BLOCK_BT=$ENABLE_BLOCK_BT
ENABLE_BLOCK_ADS=$ENABLE_BLOCK_ADS
EOF
  chmod 600 "$ENVFILE"
}

# ---- 渲染函数(纯输出, 便于测试) -------------------------------------------
render_singbox_config() {
  local anytls_block=""
  if [ "$ANYTLS_OK" = 1 ]; then
    anytls_block="$(cat <<JSON
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $ANYTLS_PORT,
      "users": [ { "password": "$ANYTLS_PASSWORD" } ],
      "tls": { "enabled": true, "certificate_path": "$SB_DIR/server.crt", "key_path": "$SB_DIR/server.key" }
    },
JSON
)"
  fi
  local cf_block=""
  if [ -n "$CF_HOSTNAME" ] && [ -n "$CF_VLESS_UUID" ]; then
    cf_block="$(cat <<JSON
,
    {
      "type": "vless",
      "tag": "cf-vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": $CF_PORT,
      "users": [ { "uuid": "$CF_VLESS_UUID" } ],
      "transport": { "type": "ws", "path": "$CF_WS_PATH" }
    }
JSON
)"
  fi
  local obfs_line=""
  [ -n "$OBFS_PASSWORD" ] && obfs_line=$'\n      "obfs": { "type": "salamander", "password": "'"$OBFS_PASSWORD"'" },'
  local route_json="" warp_ep=""
  if [ "$ENABLE_BLOCK_BT" = 1 ] || [ "$ENABLE_BLOCK_ADS" = 1 ] || [ -n "$WARP_PRIVATE_KEY" ]; then
    local rules="" rsets=""
    [ "$ENABLE_BLOCK_BT" = 1 ] && rules="$rules"'
      { "protocol": "bittorrent", "action": "reject" },'
    if [ "$ENABLE_BLOCK_ADS" = 1 ]; then
      rules="$rules"'
      { "rule_set": ["geosite-ads"], "action": "reject" },'
      rsets="$rsets"'
      { "tag": "geosite-ads", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs", "download_detour": "direct" },'
    fi
    if [ -n "$WARP_PRIVATE_KEY" ]; then
      # WARP_SITES 可配置(逗号分隔的 geosite 名), 默认 openai/netflix/disney
      local site tags=""
      for site in $(printf '%s' "${WARP_SITES:-openai,netflix,disney}" | tr ',' ' '); do
        site="$(printf '%s' "$site" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"   # 清洗防注入
        [ -n "$site" ] || continue
        tags="$tags\"geosite-$site\","
        rsets="$rsets"'
      { "tag": "geosite-'"$site"'", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-'"$site"'.srs", "download_detour": "direct" },'
      done
      rules="$rules"'
      { "rule_set": ['"${tags%,}"'], "action": "route", "outbound": "warp" },'
      local reserved=""
      [ -n "$WARP_RESERVED" ] && reserved=", \"reserved\": [$WARP_RESERVED]"
      warp_ep="$(cat <<JSON
,
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "address": ["$WARP_ADDR_V4", "$WARP_ADDR_V6"],
      "private_key": "$WARP_PRIVATE_KEY",
      "peers": [ { "address": "162.159.192.1", "port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "allowed_ips": ["0.0.0.0/0", "::/0"]$reserved } ]
    }
  ]
JSON
)"
    fi
    local rsblock=""
    [ -n "$rsets" ] && rsblock="
    \"rule_set\": [${rsets%,}
    ],"
    route_json="$(cat <<JSON

  "route": {
    "rules": [
      { "action": "sniff" },$rules
      { "action": "route", "outbound": "direct" }
    ],$rsblock
    "final": "direct"
  },
JSON
)"
  fi
  cat <<JSON
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASSWORD" } ],$obfs_line
      "tls": { "enabled": true, "certificate_path": "$SB_DIR/server.crt", "key_path": "$SB_DIR/server.key" }
    },
$anytls_block
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [ { "uuid": "$VLESS_UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": ["$REALITY_SHORT_ID"]
        }
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $SS_PORT,
      "method": "$SS_METHOD",
      "password": "$SS_PASSWORD"
    }$cf_block
  ],$route_json
  "outbounds": [ { "type": "direct", "tag": "direct" } ]$warp_ep
}
JSON
}

render_subscription_yaml() {
  ANYTLS_OK="$ANYTLS_OK" PUBLIC_IP="$PUBLIC_IP" DOMAIN="$DOMAIN" \
  HY2_PORT="$HY2_PORT" ANYTLS_PORT="$ANYTLS_PORT" VLESS_PORT="$VLESS_PORT" \
  HY2_PASSWORD="$HY2_PASSWORD" ANYTLS_PASSWORD="$ANYTLS_PASSWORD" VLESS_UUID="$VLESS_UUID" \
  REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY" REALITY_SHORT_ID="$REALITY_SHORT_ID" \
  REALITY_SNI="$REALITY_SNI" TLS_SNI="$TLS_SNI" \
  SS_PORT="$SS_PORT" SS_METHOD="$SS_METHOD" SS_PASSWORD="$SS_PASSWORD" \
  CF_HOSTNAME="$CF_HOSTNAME" CF_VLESS_UUID="$CF_VLESS_UUID" CF_WS_PATH="$CF_WS_PATH" \
  OBFS_PASSWORD="$OBFS_PASSWORD" HY2_HOP_RANGE="$HY2_HOP_RANGE" HY2_UP="$HY2_UP" HY2_DOWN="$HY2_DOWN" \
  "$PY" - <<'PY'
import os
ip  = os.environ["PUBLIC_IP"]
dom = os.environ.get("DOMAIN", "")
anytls = os.environ["ANYTLS_OK"] == "1"

proxies = []
hy2 = [
    '  - name: "Hysteria2"',
    '    type: hysteria2',
    f'    server: {ip}',
    f'    port: {os.environ["HY2_PORT"]}',
    f'    password: {os.environ["HY2_PASSWORD"]}',
    f'    sni: {os.environ["TLS_SNI"]}',
    '    skip-cert-verify: true',
]
if os.environ.get("HY2_HOP_RANGE", ""):
    hy2.append(f'    ports: "{os.environ["HY2_HOP_RANGE"]}"')
if os.environ.get("OBFS_PASSWORD", ""):
    hy2.append('    obfs: salamander')
    hy2.append(f'    obfs-password: {os.environ["OBFS_PASSWORD"]}')
if os.environ.get("HY2_UP", ""):
    hy2.append(f'    up: "{os.environ["HY2_UP"]} Mbps"')
if os.environ.get("HY2_DOWN", ""):
    hy2.append(f'    down: "{os.environ["HY2_DOWN"]} Mbps"')
hy2 += ['    alpn:', '      - h3']
proxies.append("\n".join(hy2))
if anytls:
    proxies.append(f'''  - name: "AnyTLS"
    type: anytls
    server: {ip}
    port: {os.environ["ANYTLS_PORT"]}
    password: {os.environ["ANYTLS_PASSWORD"]}
    sni: {os.environ["TLS_SNI"]}
    skip-cert-verify: true''')
proxies.append(f'''  - name: "Vless"
    type: vless
    server: {ip}
    port: {os.environ["VLESS_PORT"]}
    uuid: {os.environ["VLESS_UUID"]}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: {os.environ["REALITY_SNI"]}
    client-fingerprint: chrome
    reality-opts:
      public-key: {os.environ["REALITY_PUBLIC_KEY"]}
      short-id: {os.environ["REALITY_SHORT_ID"]}''')
proxies.append(f'''  - name: "SS2022"
    type: ss
    server: {ip}
    port: {os.environ["SS_PORT"]}
    cipher: {os.environ["SS_METHOD"]}
    password: "{os.environ["SS_PASSWORD"]}"
    udp: true''')

cf_host = os.environ.get("CF_HOSTNAME", "")
cf_uuid = os.environ.get("CF_VLESS_UUID", "")
cf_on = bool(cf_host and cf_uuid)
if cf_on:
    proxies.append(f'''  - name: "CF-Vless"
    type: vless
    server: {cf_host}
    port: 443
    uuid: {cf_uuid}
    network: ws
    udp: true
    tls: true
    servername: {cf_host}
    client-fingerprint: chrome
    ws-opts:
      path: {os.environ["CF_WS_PATH"]}
      headers:
        Host: {cf_host}''')

names = ["Hysteria2"] + (["AnyTLS"] if anytls else []) + ["Vless", "SS2022"] + (["CF-Vless"] if cf_on else [])
grp = "\n".join(f'      - "{n}"' for n in names)

rules = []
if dom:
    rules.append(f"  - DOMAIN,{dom},DIRECT")
rules.append(f"  - IP-CIDR,{ip}/32,DIRECT,no-resolve")
rules += [
    "  - DOMAIN-SUFFIX,local,DIRECT",
    "  - DOMAIN-SUFFIX,localhost,DIRECT",
    "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
    "  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
    "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
    "  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
    "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
    "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
    "  - IP-CIDR,198.18.0.0/16,DIRECT,no-resolve",
    "  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
]
for d in ["qq.com","weixin.com","wechat.com","gtimg.com","qpic.cn","bilibili.com","b23.tv",
          "hdslb.com","taobao.com","tmall.com","jd.com","360buyimg.com","alicdn.com","aliyun.com",
          "alipay.com","douyin.com","iesdouyin.com","byteimg.com","bytedance.com","amap.com",
          "autonavi.com","baidu.com","bdstatic.com","163.com","126.net","127.net","mi.com",
          "xiaomi.com","miui.com","huawei.com","vmall.com"]:
    rules.append(f"  - DOMAIN-SUFFIX,{d},DIRECT")
rules += ["  - GEOSITE,cn,DIRECT", "  - GEOIP,CN,DIRECT", "  - MATCH,🚀 节点选择"]

doc = f'''mixed-port: 7897
allow-lan: true
mode: rule
log-level: info
ipv6: false
tcp-concurrent: true

proxies:
{chr(10).join(proxies)}

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
{grp}

rules:
{chr(10).join(rules)}
'''
import sys
sys.stdout.write(doc)
PY
}

# 各节点的分享链接(vless:// hysteria2:// anytls:// ss://), 一行一条; 通用订阅就是它的 base64
render_share_links() {
  ANYTLS_OK="$ANYTLS_OK" PUBLIC_IP="$PUBLIC_IP" \
  HY2_PORT="$HY2_PORT" ANYTLS_PORT="$ANYTLS_PORT" VLESS_PORT="$VLESS_PORT" SS_PORT="$SS_PORT" \
  HY2_PASSWORD="$HY2_PASSWORD" ANYTLS_PASSWORD="$ANYTLS_PASSWORD" VLESS_UUID="$VLESS_UUID" \
  SS_METHOD="$SS_METHOD" SS_PASSWORD="$SS_PASSWORD" \
  REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY" REALITY_SHORT_ID="$REALITY_SHORT_ID" \
  REALITY_SNI="$REALITY_SNI" TLS_SNI="$TLS_SNI" \
  CF_HOSTNAME="$CF_HOSTNAME" CF_VLESS_UUID="$CF_VLESS_UUID" CF_WS_PATH="$CF_WS_PATH" \
  OBFS_PASSWORD="$OBFS_PASSWORD" HY2_HOP_RANGE="$HY2_HOP_RANGE" HY2_UP="$HY2_UP" HY2_DOWN="$HY2_DOWN" \
  "$PY" - <<'PY'
import os, urllib.parse as u
def q(s): return u.quote(str(s), safe='')
ip  = os.environ["PUBLIC_IP"]
tls = os.environ["TLS_SNI"]
out = []
hy2q = f"insecure=1&sni={q(tls)}"
if os.environ.get("OBFS_PASSWORD", ""):
    hy2q += f"&obfs=salamander&obfs-password={q(os.environ['OBFS_PASSWORD'])}"
hop = os.environ.get("HY2_HOP_RANGE", "")
# 端口跳跃: 端口段写进 authority(官方 URI 规范, mihomo/标准解析认), 再附 mport 兼容 NekoBox 系
hy2_port = hop if hop else os.environ["HY2_PORT"]
if hop:
    hy2q += f"&mport={hop}"
out.append(f"hysteria2://{q(os.environ['HY2_PASSWORD'])}@{ip}:{hy2_port}/?{hy2q}#{q('Hysteria2')}")
if os.environ["ANYTLS_OK"] == "1":
    out.append(f"anytls://{q(os.environ['ANYTLS_PASSWORD'])}@{ip}:{os.environ['ANYTLS_PORT']}/?insecure=1&sni={q(tls)}#{q('AnyTLS')}")
vq = u.urlencode({'encryption':'none','flow':'xtls-rprx-vision','security':'reality',
                  'sni':os.environ['REALITY_SNI'],'fp':'chrome',
                  'pbk':os.environ['REALITY_PUBLIC_KEY'],'sid':os.environ['REALITY_SHORT_ID'],'type':'tcp'})
out.append(f"vless://{os.environ['VLESS_UUID']}@{ip}:{os.environ['VLESS_PORT']}?{vq}#{q('Vless')}")
# SS2022(SIP022): method:password(密码百分号编码), 不做 base64
out.append(f"ss://{os.environ['SS_METHOD']}:{q(os.environ['SS_PASSWORD'])}@{ip}:{os.environ['SS_PORT']}#{q('SS2022')}")
cfh = os.environ.get("CF_HOSTNAME",""); cfu = os.environ.get("CF_VLESS_UUID","")
if cfh and cfu:
    cq = u.urlencode({'encryption':'none','security':'tls','sni':cfh,'fp':'chrome',
                      'type':'ws','host':cfh,'path':os.environ['CF_WS_PATH']})
    out.append(f"vless://{cfu}@{cfh}:443?{cq}#{q('CF-Vless')}")
import sys
sys.stdout.write("\n".join(out) + "\n")
PY
}

# 自包含可视化看板页(只读: 看订阅/扫码/复制; 服务器管理仍走 SSH)
render_panel_html() {
  local clash_url="http://$SUB_HOST$SUB_PATH" b64_url="http://$SUB_HOST$SUB_B64_PATH"
  local qr_clash="" qr_b64=""
  if command -v qrencode >/dev/null 2>&1; then
    # || true: qrencode 运行时失败也只是没二维码, 不能因 set -e/pipefail 中断整个安装
    qr_clash="$(qrencode -t PNG -o - "$clash_url" 2>/dev/null | base64 -w0 || true)"
    qr_b64="$(qrencode -t PNG -o - "$b64_url" 2>/dev/null | base64 -w0 || true)"
  fi
  local nodes="Hysteria2"
  [ "$ANYTLS_OK" = 1 ] && nodes="$nodes,AnyTLS"
  nodes="$nodes,Vless,SS2022"
  [ -n "$CF_HOSTNAME" ] && nodes="$nodes,CF-Vless"
  AIRPORT_NAME="$AIRPORT_NAME" CLASH_URL="$clash_url" B64_URL="$b64_url" \
  QR_CLASH="$qr_clash" QR_B64="$qr_b64" NODES="$nodes" \
  LIMIT_GB="$LIMIT_GB" EXP="${EXPIRE_VALUE:-${EXPIRE_AT:-}}" \
  "$PY" - <<'PY'
import os, html, sys, urllib.parse, base64, json, datetime
e = html.escape
name_raw = os.environ.get("AIRPORT_NAME", "Node")
name = e(name_raw)
clash_raw = os.environ["CLASH_URL"]; b64_raw = os.environ["B64_URL"]
clash = e(clash_raw); b64 = e(b64_raw)
# 一键导入深链: Clash 系吃 clash://install-config; Shadowrocket 吃 shadowrocket://add/sub://<base64(订阅URL)>
clash_deep = e("clash://install-config?url=" + urllib.parse.quote(clash_raw, safe="") + "&name=" + urllib.parse.quote(name_raw, safe=""))
sr_deep = e("shadowrocket://add/sub://" + base64.b64encode(b64_raw.encode()).decode())
clash_js = json.dumps(clash_raw)   # 安全的 JS 字符串字面量, 供 fetch 用
limit_gb = e(os.environ.get("LIMIT_GB", "") or "—")
try:
    _exp = os.environ.get("EXP", "")
    exp_disp = e(datetime.datetime.strptime(_exp, "%Y-%m-%d %H:%M:%S %z").strftime("%Y-%m-%d")) if _exp else "—"
except Exception:
    exp_disp = "—"
def qr(data): return f'<img class="qr" alt="QR" src="data:image/png;base64,{data}">' if data else '<span class="muted">(装 qrencode 可显示二维码)</span>'
chips = "".join(f"<span>{e(n)}</span>" for n in os.environ["NODES"].split(","))
out = f'''<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name} 订阅</title><style>
:root{{color-scheme:dark}}
body{{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#0e1116;color:#e6e6e6;margin:0;padding:24px;line-height:1.6}}
.wrap{{max-width:760px;margin:0 auto}} h1{{font-size:1.4rem;margin:.2em 0}}
.muted{{color:#8b949e;font-size:.9rem}}
.card{{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:16px;margin:14px 0}}
.row{{display:flex;gap:10px;align-items:center;flex-wrap:wrap}}
code{{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:6px 10px;word-break:break-all;flex:1;min-width:200px;font-size:.82rem}}
button{{background:#238636;color:#fff;border:0;border-radius:6px;padding:8px 14px;cursor:pointer;font-size:.85rem}} button:active{{opacity:.7}}
a.btn{{display:inline-block;background:#1f6feb;color:#fff;text-decoration:none;border-radius:6px;padding:8px 14px;font-size:.85rem;margin-top:8px}} a.btn:active{{opacity:.7}}
img.qr{{background:#fff;padding:8px;border-radius:8px;width:170px;height:170px;margin-top:12px}}
.nodes span{{display:inline-block;background:#21262d;border:1px solid #30363d;border-radius:20px;padding:4px 12px;margin:3px;font-size:.85rem}}
.warn{{background:#3d1c1c;border-color:#5c2626;color:#ffb4b4}}
</style></head><body><div class="wrap">
<h1>{name} 节点订阅</h1>
<p class="muted">导入下面任一订阅；手机可直接扫码。</p>
<div class="card"><b>Clash / Mihomo 订阅</b>
<div class="row"><code id="u1">{clash}</code><button onclick="cp('u1')">复制</button></div>
<div class="row"><a class="btn" href="{clash_deep}">⚡ 一键导入 Clash / Mihomo</a></div>
{qr(os.environ.get("QR_CLASH",""))}</div>
<div class="card"><b>通用订阅（v2rayN / Shadowrocket / NekoBox）</b>
<div class="row"><code id="u2">{b64}</code><button onclick="cp('u2')">复制</button></div>
<div class="row"><a class="btn" href="{sr_deep}">⚡ 一键导入 Shadowrocket</a></div>
{qr(os.environ.get("QR_B64",""))}</div>
<div class="card"><b>节点</b><div class="nodes">{chips}</div></div>
<div class="card"><b>流量 / 到期</b>
<div class="row"><span>限额 <b>{limit_gb} GB</b></span><span class="muted">·</span><span>到期 <b>{exp_disp}</b></span><span class="muted">·</span><span>已用 <b id="used">查询中…</b></span></div>
<p class="muted">已用为实时拉取订阅响应头（每 5 分钟由服务器刷新）。</p></div>
<div class="card warn">⚠️ 此页含全部节点凭证、走明文 HTTP。仅自己用、别外传链接；不可信网络请走 HTTPS（见仓库 README）。</div>
<p class="muted">管理（改限额 / 更新 / 加节点）请用 SSH：<code>bash install.sh menu</code></p>
</div><script>
function cp(i){{navigator.clipboard.writeText(document.getElementById(i).textContent)}}
(function(){{var el=document.getElementById('used');if(!el)return;
fetch({clash_js},{{method:'HEAD'}}).then(function(r){{
var u=r.headers.get('Subscription-Userinfo')||'';
var d=/download=(\\d+)/.exec(u),t=/total=(\\d+)/.exec(u);
if(d){{var g=(+d[1]/1073741824).toFixed(2);el.textContent=g+' GB'+(t&&+t[1]>0?(' / '+(+t[1]/1073741824).toFixed(0)+' GB'):'');}}
else{{el.textContent='—';}}
}}).catch(function(){{el.textContent='—';}});}})();
</script>
</body></html>'''
sys.stdout.write(out)
PY
}

render_header() {
  LIMIT_GB="$LIMIT_GB" EXPIRE_AT_VAL="$1" "$PY" - <<'PY'
import os, datetime
limit = int(float(os.environ["LIMIT_GB"]) * 1024 ** 3)
exp = int(datetime.datetime.strptime(os.environ["EXPIRE_AT_VAL"], "%Y-%m-%d %H:%M:%S %z").timestamp())
print(f'add_header Subscription-Userinfo "upload=0; download=0; total={limit}; expire={exp}" always;')
PY
}

# ---- 写文件 + 副作用 -------------------------------------------------------
write_singbox_config() {
  log "写入 sing-box 配置并校验..."
  render_singbox_config >"$SB_DIR/config.json"
  chmod 600 "$SB_DIR/config.json"
  sing-box check -c "$SB_DIR/config.json" || die "sing-box 配置校验失败(请把上面报错贴出来)"
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
  ok "sing-box 已启动"
}

write_subscription() {
  log "生成 Clash/Mihomo 订阅 + 通用(base64)订阅..."
  mkdir -p "$WWW"
  chmod 755 "$WWW"   # 防止 umask 077 下新建的 web 根变 700, 导致 nginx(www-data) 无法遍历→订阅 403
  render_subscription_yaml >"$WWW$SUB_PATH"
  chmod 644 "$WWW$SUB_PATH"
  if [ -n "${SUB_B64_PATH:-}" ]; then   # 通用订阅: 各节点分享链接的 base64, 供 v2rayN/Shadowrocket/NekoBox 等
    render_share_links | base64 -w0 >"$WWW$SUB_B64_PATH"
    chmod 644 "$WWW$SUB_B64_PATH"
  fi
  if [ -n "${PANEL_PATH:-}" ]; then     # 可视化看板页(订阅+二维码+节点)
    render_panel_html >"$WWW$PANEL_PATH"
    chmod 644 "$WWW$PANEL_PATH"
  fi
}

config_nginx() {
  log "配置 nginx 订阅服务..."
  mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
  # 流量头单独放 snippets, 只在订阅 location 内 include(首页/404 不会带头); 数值用 env 单一来源
  render_header "$EXPIRE_VALUE" >"$NGINX_SNIPPET"
  chmod 644 "$NGINX_SNIPPET"

  # 用 server_name 精确匹配本机 IP/域名, 不抢 default_server, 避免与机器上已有站点撞 "duplicate default server"
  local v6=""
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    v6=$'\n    listen [::]:80;'
  fi
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
  cat >"$NGINX_CONF" <<EOF
server {
    listen 80;$v6
    root $WWW;
    server_name $SUB_HOST;

    location = $SUB_PATH {
        include $NGINX_SNIPPET;
        default_type application/octet-stream;
        try_files \$uri =404;
    }

    location = $SUB_B64_PATH {
        include $NGINX_SNIPPET;
        default_type text/plain;
        try_files \$uri =404;
    }

    location = $PANEL_PATH {
        default_type text/html;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

  if grep -q 'server_tokens' /etc/nginx/nginx.conf; then
    sed -i 's/^\([[:space:]]*\)#\?[[:space:]]*server_tokens .*/\1server_tokens off;/' /etc/nginx/nginx.conf
  else
    sed -i '0,/http[[:space:]]*{/s//http {\n    server_tokens off;/' /etc/nginx/nginx.conf
  fi

  local terr="/tmp/singbox-nginxt.$$"
  if ! nginx -t 2>"$terr"; then
    err "nginx 配置校验失败:"; cat "$terr" >&2
    if grep -qi 'duplicate default server' "$terr" 2>/dev/null; then
      err "→ 机器上已有别的 default_server 站点。请在 /etc/nginx/ 下找到并移除冲突的 default_server, 然后重跑。"
    fi
    rm -f "$terr"; die "nginx 未通过校验"
  fi
  rm -f "$terr"
  systemctl reload nginx || systemctl restart nginx
  ok "nginx 订阅就绪"
}

install_traffic() {
  log "安装流量统计/限流脚本..."
  cat >"$TRAFFIC_PY" <<'PYEOF'
#!/usr/bin/env python3
import json
import subprocess
import datetime
import sys
import os

ENV_PATH = "/etc/sing-box-node.env"
HEADER_PATH = "/etc/nginx/snippets/sub_headers.conf"
QUOTA_FLAG = "/run/sing-box-quota-stopped"


def load_env(path=ENV_PATH):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def parse_expire(s):
    return int(datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z").timestamp())


def current_month_used(data, interface, mode, now=None):
    now = now or datetime.datetime.now()
    iface = None
    for it in data.get("interfaces", []):
        if it.get("name") == interface:
            iface = it
            break
    if iface is None:
        return None
    rx = tx = 0
    for m in iface.get("traffic", {}).get("month", []):
        d = m.get("date", {})
        if d.get("year") == now.year and d.get("month") == now.month:
            rx = m.get("rx", 0)
            tx = m.get("tx", 0)
            break
    if mode == "tx":
        return tx
    if mode == "max":
        return max(rx, tx)
    return rx + tx


def build_header(used, total, expire):
    return (f'add_header Subscription-Userinfo '
            f'"upload=0; download={used}; total={total}; expire={expire}" always;\n')


def decide_enforcement(used, limit_bytes, active, flag_exists):
    if used >= limit_bytes:
        return ("stop" if active else None, True)
    if flag_exists:
        return ("start" if not active else None, False)
    return (None, False)


def main():
    env = load_env()
    limit_bytes = int(float(env.get("LIMIT_GB", "200")) * 1024 ** 3)
    interface = env.get("INTERFACE", "eth0")
    mode = env.get("COUNT_MODE", "rx+tx")
    expire = parse_expire(env["EXPIRE_AT"])

    try:
        result = subprocess.run(["vnstat", "--json"], capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"Error running vnstat: {e}", file=sys.stderr)
        sys.exit(1)

    used = current_month_used(data, interface, mode)
    if used is None:
        print(f"Interface {interface} not found in vnstat data", file=sys.stderr)
        sys.exit(1)

    header = build_header(used, limit_bytes, expire)
    old = ""
    if os.path.exists(HEADER_PATH):
        with open(HEADER_PATH) as f:
            old = f.read()
    if header != old:
        with open(HEADER_PATH, "w") as f:
            f.write(header)
        subprocess.run(["systemctl", "reload", "nginx"])

    active = subprocess.run(["systemctl", "is-active", "--quiet", "sing-box"]).returncode == 0
    action, keep_flag = decide_enforcement(used, limit_bytes, active, os.path.exists(QUOTA_FLAG))
    if action == "stop":
        subprocess.run(["systemctl", "stop", "sing-box"])
    elif action == "start":
        subprocess.run(["systemctl", "start", "sing-box"])
    if keep_flag:
        open(QUOTA_FLAG, "w").close()
    elif os.path.exists(QUOTA_FLAG):
        os.remove(QUOTA_FLAG)


if __name__ == "__main__":
    main()
PYEOF
  chmod 700 "$TRAFFIC_PY"
  "$PY" -m py_compile "$TRAFFIC_PY" || die "traffic_limit.py 语法错误"
  # 前台跑一次: 网卡名等问题会立刻暴露
  if ! "$PY" "$TRAFFIC_PY"; then
    warn "首次运行 traffic_limit.py 失败(多半是 vnstat 还没采集到 $INTERFACE 数据, 几分钟后 cron 会自动重试)"
    note "流量统计: 若 5-10 分钟后订阅仍不显示流量, 运行 'journalctl -t traffic_limit -n 20' 看报错, 并核对 $ENVFILE 里的 INTERFACE 是否为真实网卡(ip -br link)。"
  fi
  # 解析真实路径, 避免 python3/logger 不在 /usr/bin 时 cron 静默失败
  local py_bin logger_bin
  py_bin="$(command -v python3 || echo /usr/bin/python3)"
  logger_bin="$(command -v logger || echo /usr/bin/logger)"
  cat >"$CRON" <<EOF
*/5 * * * * root $py_bin $TRAFFIC_PY 2>&1 | $logger_bin -t traffic_limit
EOF
  ok "流量脚本 + 每5分钟定时任务就绪"
}

config_sysctl() {
  log "应用网络优化(sysctl, 即时生效免重启)..."
  cat >"$SYSCTL_CONF" <<'EOF'
# === sing-box 节点网络优化(自用代理) ===
# UDP/QUIC 大接收缓冲 —— Hysteria2 关键! 不设会被限速并刷 quic-go 缓冲告警(Hysteria 官方推荐 16MB)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
# TCP 缓冲, 适配高带宽-延迟积(跨境长距离)链路
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
# 大连接/突发队列
net.core.netdev_max_backlog=10000
net.core.somaxconn=4096
# 跨境/隧道 MTU 黑洞探测; 空闲后不重置拥塞窗口(代理常空闲后突发)
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
# TCP Fast Open + TIME_WAIT 复用(代理出站连接多; 若在 CGNAT/有状态NAT后偶发出站卡顿, 去掉 tw_reuse 这行)
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
EOF
  if [ "$ENABLE_BBR" = 1 ]; then
    cat >>"$SYSCTL_CONF" <<'EOF'
# BBR 拥塞控制 + fq 队列(只作用于 TCP: AnyTLS/Vless; HY2 走 UDP 不受影响)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  fi
  sysctl --system >/dev/null 2>&1 || true
  local rmem; rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  if [ "${rmem:-0}" -ge 16777216 ] 2>/dev/null; then ok "UDP 缓冲已调大(rmem_max=$rmem, 利于 HY2)"; else warn "UDP 缓冲未达 16MB(rmem_max=$rmem), HY2 吞吐可能受限"; fi
  if [ "$ENABLE_BBR" = 1 ]; then
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo)" = bbr ]; then ok "BBR 已开启"
    else warn "BBR 未生效(内核可能不支持), 不影响使用"; note "BBR: 内核未启用, 升级内核重启后生效(配置已写入 $SYSCTL_CONF)。"; fi
  fi
}

# HY2 端口跳跃: nftables 把一段 UDP 端口重定向到真实 HY2 端口, 抗运营商按端口对 UDP 限速
config_porthop() {
  [ -n "$HY2_HOP_RANGE" ] || return 0
  log "配置 HY2 端口跳跃(UDP $HY2_HOP_RANGE -> $HY2_PORT)..."
  if ! command -v nft >/dev/null 2>&1; then
    case "$PKG" in apt) apt-get install -y nftables >/dev/null 2>&1 || true ;; dnf|yum) "$PKG" install -y nftables >/dev/null 2>&1 || true ;; esac
  fi
  local nftbin; nftbin="$(command -v nft 2>/dev/null || true)"
  [ -n "$nftbin" ] || { warn "nftables 未装上, 跳过端口跳跃"; note "端口跳跃: 装不上 nftables, 未启用; 手动装后重跑 install。"; return 0; }
  local hs="${HY2_HOP_RANGE%-*}" he="${HY2_HOP_RANGE#*-}"
  local rules="$SB_DIR/porthop.nft"
  cat >"$rules" <<EOF
#!/usr/sbin/nft -f
table inet sb_hophy2
delete table inet sb_hophy2
table inet sb_hophy2 {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "${INTERFACE:-eth0}" udp dport ${hs}-${he} redirect to :${HY2_PORT}
  }
}
EOF
  if ! "$nftbin" -f "$rules" 2>/dev/null; then
    warn "nft 应用失败, 端口跳跃未生效"; note "端口跳跃: 'nft -f $rules' 报错, 请手动排查。"; return 0
  fi
  cat >/etc/systemd/system/sing-box-porthop.service <<EOF
[Unit]
Description=sing-box HY2 port hopping (nftables redirect)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$nftbin -f $rules
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now sing-box-porthop >/dev/null 2>&1 || true
  ok "HY2 端口跳跃已开(UDP $HY2_HOP_RANGE 重定向到 $HY2_PORT)"
  note "端口跳跃: 云安全组必须放行 UDP 整段 $HY2_HOP_RANGE(不只是 $HY2_PORT), 否则跳跃端口连不上。"
}

config_firewall() {
  note "云安全组(服务商控制台)必须放行: 22/tcp 80/tcp $VLESS_PORT/tcp $ANYTLS_PORT/tcp $SS_PORT/tcp+udp $HY2_PORT/udp —— 尤其 UDP($HY2_PORT、$SS_PORT)。本脚本改不了云端安全组, 这是'HY2/SS 连不上、Vless 却正常'的头号原因。"
  if ! command -v ufw >/dev/null 2>&1; then return 0; fi
  if [ "$ENABLE_UFW" = 1 ]; then
    log "配置并启用 ufw..."
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow "$VLESS_PORT"/tcp  >/dev/null 2>&1 || true
    ufw allow "$ANYTLS_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$HY2_PORT"/udp    >/dev/null 2>&1 || true
    ufw allow "$SS_PORT"/tcp     >/dev/null 2>&1 || true
    ufw allow "$SS_PORT"/udp     >/dev/null 2>&1 || true
    [ -n "$HY2_HOP_RANGE" ] && ufw allow "${HY2_HOP_RANGE%-*}":"${HY2_HOP_RANGE#*-}"/udp >/dev/null 2>&1 || true
    # 启用前确认 22 已放行, 否则不启用以免把自己 SSH 关在门外
    if ufw status 2>/dev/null | grep -q '22/tcp'; then
      yes | ufw enable >/dev/null 2>&1 || true
      ok "ufw 已启用并放行端口"
    else
      warn "未能放行 SSH(22/tcp), 已跳过启用 ufw 以免锁死 SSH"
      note "ufw: 自动放行 22 失败, 未启用防火墙。请手动 'ufw allow 22/tcp' 确认后再 'ufw enable'(改过 SSH 端口的同步放行那个端口)。"
    fi
  elif ufw status 2>/dev/null | grep -q "Status: active"; then
    log "ufw 已是激活状态, 补放行端口..."
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow "$VLESS_PORT"/tcp  >/dev/null 2>&1 || true
    ufw allow "$ANYTLS_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$HY2_PORT"/udp    >/dev/null 2>&1 || true
    ufw allow "$SS_PORT"/tcp     >/dev/null 2>&1 || true
    ufw allow "$SS_PORT"/udp     >/dev/null 2>&1 || true
    [ -n "$HY2_HOP_RANGE" ] && ufw allow "${HY2_HOP_RANGE%-*}":"${HY2_HOP_RANGE#*-}"/udp >/dev/null 2>&1 || true
    ok "已在现有 ufw 中放行端口"
  else
    note "主机防火墙 ufw 未启用, 本脚本未自动开启(避免锁死 SSH)。如需启用: 用 ENABLE_UFW=1 重跑, 或手动 'ufw allow 22,80,$VLESS_PORT,$ANYTLS_PORT,$SS_PORT/tcp; ufw allow $HY2_PORT/udp; ufw allow $SS_PORT/udp; ufw enable'。"
  fi
}

# ----------------------------------------------------------------- 输出
print_summary() {
  local sub_url="http://$SUB_HOST$SUB_PATH"
  echo
  ok "================= 部署完成 ================="
  echo
  printf '  订阅名称:         %s\n' "$AIRPORT_NAME"
  printf '  Clash/Mihomo 订阅: %s\n' "$sub_url"
  [ -n "${SUB_B64_PATH:-}" ] && printf '  通用(base64)订阅:  http://%s%s   (v2rayN/Shadowrocket/NekoBox)\n' "$SUB_HOST" "$SUB_B64_PATH"
  [ -n "${PANEL_PATH:-}" ]   && printf '  可视化看板页:      http://%s%s   (浏览器打开, 看订阅+扫码+复制)\n' "$SUB_HOST" "$PANEL_PATH"
  echo
  printf '  节点(客户端里显示名):\n'
  printf '    - Hysteria2  (UDP %s)\n' "$HY2_PORT"
  [ "$ANYTLS_OK" = 1 ] && printf '    - AnyTLS     (TCP %s)\n' "$ANYTLS_PORT"
  printf '    - Vless      (TCP %s, Reality)\n' "$VLESS_PORT"
  printf '    - SS2022     (TCP+UDP %s)\n' "$SS_PORT"
  [ -n "$CF_HOSTNAME" ] && printf '    - CF-Vless   (WS via %s, Argo 大保底)\n' "$CF_HOSTNAME"
  [ -n "$WARP_PRIVATE_KEY" ] && printf '    * WARP 解锁分流已开 (OpenAI/Netflix/Disney 走 WARP)\n'
  echo
  printf '  管理命令:\n'
  printf '    查看信息:    bash install.sh info\n'
  printf '    一键自检:    bash install.sh doctor   (排查不通先跑它)\n'
  printf '    看板页地址:  bash install.sh panel\n'
  printf '    分享链接:    bash install.sh links\n'
  printf '    备份/迁移:   bash install.sh backup   (新机: bash install.sh restore <文件>)\n'
  printf '    SSH 加固:    bash install.sh harden   (密钥登录+禁密码+fail2ban)\n'
  printf '    WARP 解锁:   bash install.sh warp      (关闭: warp off)\n'
  printf '    加CF大保底:  CF_TOKEN=.. CF_HOSTNAME=.. bash install.sh cf\n'
  printf '    装探针:      KOMARI_ENDPOINT=.. KOMARI_TOKEN=.. bash install.sh komari\n'
  printf '    卸载:        bash install.sh uninstall\n'

  echo
  warn "----- 需要你手动完成 / 本机无法自动完成的部分 -----"
  if [ "${#NOTES[@]}" -eq 0 ]; then
    echo "  (无)"
  else
    local i=1
    for n in "${NOTES[@]}"; do printf '  %d) %s\n' "$i" "$n"; i=$((i+1)); done
  fi
  echo
  warn "可选增强(默认未做): 1) SSH 改密钥登录+禁用密码(防爆破, 最值得做)  2) CF-Vless 大保底(需 Cloudflare 域名+Tunnel, 见 README)  3) 订阅改 HTTPS(需域名/CF, 见 README)"
  echo
  log "自检: 把订阅 URL 导入 Clash/Mihomo, 先试 Hysteria2, 不通切 Vless。服务器端可跑: systemctl is-active sing-box nginx ; curl -I $sub_url"
}

do_info() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # shellcheck disable=SC1090
  . "$SECRETS"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -f "$CF_ENV" ]  && . "$CF_ENV"  2>/dev/null || true   # 接入过 CF-Vless 则一并显示
  # 优先用安装时存下的 SUB_HOST(纯读, 不崩); 老版本无此字段才回退探测且探测失败不致命
  [ -n "${SUB_HOST:-}" ] || SOFT_DETECT=1 detect_net
  command -v sing-box >/dev/null 2>&1 && SB_VER="$(sing-box version 2>/dev/null | awk '/version/{print $3; exit}')"
  [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json" && ANYTLS_OK=1 || ANYTLS_OK=0
  print_summary
}

do_links() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # shellcheck disable=SC1090
  . "$SECRETS"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -f "$CF_ENV" ]  && . "$CF_ENV"  2>/dev/null || true
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  echo "===== 各节点分享链接(单条可粘进 v2rayN / NekoBox / Shadowrocket 等) ====="
  render_share_links
  echo
  echo "===== 订阅 URL ====="
  printf 'Clash/Mihomo:  http://%s%s\n' "$SUB_HOST" "$SUB_PATH"
  [ -n "${SUB_B64_PATH:-}" ] && printf '通用(base64):  http://%s%s\n' "$SUB_HOST" "$SUB_B64_PATH"
  echo
  echo "===== 一键导入深链(在装了客户端的设备上点开即可导入) ====="
  local _cu="http://$SUB_HOST$SUB_PATH"
  printf 'Clash/Mihomo:  clash://install-config?url=%s&name=%s\n' \
    "$("$PY" -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$_cu")" \
    "$("$PY" -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$AIRPORT_NAME")"
  [ -n "${SUB_B64_PATH:-}" ] && printf 'Shadowrocket:  shadowrocket://add/sub://%s\n' \
    "$("$PY" -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' "http://$SUB_HOST$SUB_B64_PATH")"
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "(装 qrencode 后这里会出二维码: apt install -y qrencode)"
  elif [ -n "${SUB_B64_PATH:-}" ]; then
    echo; echo "===== 通用订阅二维码(扫码导入 v2rayN/Shadowrocket) ====="
    qrencode -t ANSIUTF8 "http://$SUB_HOST$SUB_B64_PATH"
  else
    echo "(无通用订阅路径, 重跑 install 升级后即可生成二维码)"
  fi
}

do_panel() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # shellcheck disable=SC1090
  . "$SECRETS"; [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true; [ -f "$CF_ENV" ] && . "$CF_ENV" 2>/dev/null || true
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  [ -n "${PANEL_PATH:-}" ] || die "本安装无看板页, 重跑 install 升级后生成"
  mkdir -p "$WWW"; chmod 755 "$WWW"
  render_panel_html >"$WWW$PANEL_PATH"; chmod 644 "$WWW$PANEL_PATH"
  ok "可视化看板页: http://$SUB_HOST$PANEL_PATH"
  echo "  浏览器打开即可看两种订阅 + 扫码导入 + 一键复制; 手机扫码最方便。"
}

do_komari() {
  if [ -z "${KOMARI_ENDPOINT:-}" ] || [ -z "${KOMARI_TOKEN:-}" ]; then
    cat <<EOF
安装 Komari 探针 agent 需要面板地址 + 节点 token(在你的 Komari 面板「添加服务器」时给出):
  KOMARI_ENDPOINT='https://你的komari面板' KOMARI_TOKEN='节点token' bash install.sh komari
EOF
    die "缺少 KOMARI_ENDPOINT 或 KOMARI_TOKEN"
  fi
  case "$KOMARI_ENDPOINT" in http://*|https://*) ;; *) die "KOMARI_ENDPOINT 要带 http:// 或 https://: $KOMARI_ENDPOINT";; esac
  log "安装 Komari 探针 agent(官方 install.sh, 透传 -e 端点 / -t token)..."
  curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh \
    | bash -s -- -e "$KOMARI_ENDPOINT" -t "$KOMARI_TOKEN" || die "Komari agent 安装失败(检查面板地址/token/网络)"
  systemctl is-active komari-agent >/dev/null 2>&1 && ok "komari-agent 运行中, 去面板看应该上线了" || warn "komari-agent 未在运行, 看 'systemctl status komari-agent'"
}

do_backup() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  local bf="${BACKUP_DIR:-/root}/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz" f files=""
  for f in "$SECRETS" "$ENVFILE" "$CF_ENV" "$WARP_ENV" "$SB_DIR/server.crt" "$SB_DIR/server.key"; do
    [ -f "$f" ] && files="$files $f"
  done
  # shellcheck disable=SC2086
  ( umask 077; tar czf "$bf" $files 2>/dev/null ) || die "打包失败"
  chmod 600 "$bf"
  ok "备份已生成: $bf"
  echo "  含: 密钥 / 运行参数 / CF状态 / 自签证书 —— 足以在新机重建同一套节点(凭证不变)。"
  echo "  迁移到新 VPS:  1) scp 过去   2) 新机上 bash install.sh restore $bf"
  warn "此文件含全部凭证, 妥善保管、别外传。"
}

do_restore() {
  local bf="${1:-}"
  [ -n "$bf" ] || die "用法: install.sh restore <备份文件.tar.gz>"
  [ -f "$bf" ] || die "找不到备份文件: $bf"
  command -v tar >/dev/null 2>&1 || die "缺 tar(先 apt install -y tar)"
  log "恢复备份(解包到 /)..."
  mkdir -p "$SB_DIR"
  tar xzf "$bf" -C / 2>/dev/null || die "解包失败(文件损坏?)"
  [ -f "$SECRETS" ] || die "备份里没有密钥文件, 无法恢复"
  # 载入用户偏好(限额/到期/计费/HY2 进阶); 机器相关(IP/网卡/订阅host)清空让新机重新探测
  # shellcheck disable=SC1090
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  INTERFACE=""; PUBLIC_IP=""; SUB_HOST=""
  # CF-Vless 隧道是跟机器走的(cloudflared+token), 备份只带了节点参数, 新机要重接
  [ -f "$CF_ENV" ] && note "CF-Vless 第5节点: 新机需重跑 'CF_TOKEN=.. CF_HOSTNAME=.. bash install.sh cf' 重装 cloudflared 并接隧道, 否则该节点连不上。"
  ok "凭证已就位, 按新机重建(IP/网卡自动适配; 用域名的话加 DOMAIN= 重跑或重指 DNS)..."
  do_install
}

do_harden() {
  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  detect_os   # 设 PKG, 装 fail2ban 用
  local akeys=/root/.ssh/authorized_keys
  if ! { [ -s "$akeys" ] && grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-)' "$akeys"; }; then
    err "未在 $akeys 找到有效 SSH 公钥! 为防止把你锁在门外, 拒绝禁用密码登录。"
    echo "  先在你本地电脑: ssh-copy-id root@<本机IP>  (或手动把公钥粘进 $akeys),"
    echo "  用密钥登录确认能进之后, 再跑: bash install.sh harden"
    die "无授权公钥, 已中止(没动任何 SSH 配置)"
  fi
  log "安装 fail2ban + 加固 SSH(仅密钥登录、禁密码)..."
  case "$PKG" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get install -y fail2ban >/dev/null 2>&1 || warn "fail2ban 装失败, 跳过" ;;
    dnf|yum) "$PKG" install -y epel-release >/dev/null 2>&1 || true; "$PKG" install -y fail2ban >/dev/null 2>&1 || warn "fail2ban 装失败, 跳过" ;;
  esac
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  mkdir -p /etc/ssh/sshd_config.d
  local dropin=/etc/ssh/sshd_config.d/00-singbox-harden.conf
  cat >"$dropin" <<'EOF'
# sing-box-oneclick SSH 加固(文件名 00- 排最前, 覆盖 50-cloud-init 的 PasswordAuthentication yes)
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  local bak=""
  if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    warn "sshd_config 无 Include sshd_config.d/, drop-in 可能不生效; 直接改主文件兜底..."
    local kv key; bak="/etc/ssh/sshd_config.singbox-bak.$(date +%s)"; cp -a /etc/ssh/sshd_config "$bak"
    for kv in "PasswordAuthentication no" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no"; do
      key="${kv%% *}"
      if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}\b" /etc/ssh/sshd_config; then
        sed -i "s|^[[:space:]]*#\?[[:space:]]*${key}\b.*|${kv}|I" /etc/ssh/sshd_config
      else
        printf '%s\n' "$kv" >> /etc/ssh/sshd_config
      fi
    done
    ok "已备份原 sshd_config 到 $bak"
  fi
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    ok "SSH 已加固(仅密钥、禁密码) + fail2ban 已开。"
    warn "⚠️ 现在请【另开一个新终端】用密钥登录确认能进, 再关掉当前会话! 进不去就: rm $dropin && systemctl reload sshd 回滚。"
  else
    rm -f "$dropin"
    [ -n "$bak" ] && cp -a "$bak" /etc/ssh/sshd_config   # 兜底分支改过主文件, 校验不过要一并还原
    die "sshd 配置校验(sshd -t)未过, 已回滚(drop-in + 主文件), 未改动 SSH"
  fi
}

do_status() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # shellcheck disable=SC1090
  . "$SECRETS"; [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true; [ -f "$CF_ENV" ] && . "$CF_ENV" 2>/dev/null || true; [ -f "$WARP_ENV" ] && . "$WARP_ENV" 2>/dev/null || true
  local cf_svc=""; [ -f "$CF_ENV" ] && cf_svc="cloudflared"
  echo "===== 服务 ====="
  local s
  for s in sing-box nginx vnstat cron $cf_svc; do
    printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo inactive)"
  done
  echo "===== 配置校验 ====="
  sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1 && echo "  sing-box: OK" || echo "  sing-box: FAIL (跑 sing-box check -c $SB_DIR/config.json 看详情)"
  nginx -t >/dev/null 2>&1 && echo "  nginx:    OK" || echo "  nginx:    FAIL (跑 nginx -t 看详情)"
  echo "===== 本地端口监听(不代表外部可达, 云安全组另算) ====="
  ss -lntup 2>/dev/null | grep -E ":($HY2_PORT|$ANYTLS_PORT|$VLESS_PORT|$SS_PORT|80)\b" || echo "  (无匹配)"
  echo "===== 其它 ====="
  printf '  时间同步 NTPSynchronized = %s\n' "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  [ -f "$SB_DIR/server.crt" ] && printf '  自签证书 %s\n' "$(openssl x509 -enddate -noout -in "$SB_DIR/server.crt" 2>/dev/null)"
  printf '  限额 %s GB | 计费 %s | 到期 %s\n' "${LIMIT_GB:-?}" "${COUNT_MODE:-?}" "${EXPIRE_AT:-?}"
  [ -n "$WARP_PRIVATE_KEY" ] && printf '  WARP 解锁分流: 已开 (OpenAI/Netflix/Disney 走 WARP; 关闭: install.sh warp off)\n'
  curl -s -o /dev/null -w '  订阅本地可达: http %{http_code}\n' "http://127.0.0.1${SUB_PATH}" 2>/dev/null || echo "  订阅本地探测失败"
  echo "  本月流量明细见: install.sh info  /  journalctl -t traffic_limit -n 20"
}

do_doctor() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # shellcheck disable=SC1090
  . "$SECRETS"; [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -f "$CF_ENV" ] && . "$CF_ENV" 2>/dev/null || true; [ -f "$WARP_ENV" ] && . "$WARP_ENV" 2>/dev/null || true
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  local issues=0
  P(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
  W(){ printf '  \033[33m!\033[0m %s\n' "$1"; issues=$((issues+1)); }
  F(){ printf '  \033[31m✗\033[0m %s\n' "$1"; issues=$((issues+1)); }

  echo "===== sing-box doctor 自检(常见坑) ====="
  # 1) 服务
  local s
  for s in sing-box nginx; do
    [ "$(systemctl is-active "$s" 2>/dev/null)" = active ] && P "$s 运行中" || F "$s 未运行: systemctl status $s"
  done
  # 2) 配置校验
  sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1 && P "sing-box 配置校验通过" || F "sing-box 配置无效: sing-box check -c $SB_DIR/config.json"
  nginx -t >/dev/null 2>&1 && P "nginx 配置校验通过" || F "nginx 配置无效: nginx -t"
  # 3) 网络优化(HY2/QUIC 关键)
  local rmem cc; rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  { [ "${rmem:-0}" -ge 16777216 ] 2>/dev/null && P "UDP 缓冲 rmem_max=$rmem (≥16MB, 利于 HY2)"; } || W "UDP 缓冲 rmem_max=$rmem <16MB: HY2 吞吐受限, 重跑 install 或 sysctl --system"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo)"
  [ "$cc" = bbr ] && P "拥塞控制 = bbr" || W "拥塞控制 = ${cc:-未知}(非 bbr): 重跑 install 开 BBR"
  # 4) 端口本地监听
  local p miss=0
  for p in "$HY2_PORT" "$VLESS_PORT" "$SS_PORT" 80; do
    ss -lntuH 2>/dev/null | grep -qE "[:.]$p\b" || { W "端口 $p 本地未监听"; miss=1; }
  done
  [ "$miss" = 0 ] && P "节点端口本地监听正常 ($HY2_PORT/$VLESS_PORT/$SS_PORT/80)"
  # 5) 防火墙 / 安全组(头号坑)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    W "ufw 已启用: 确认放行 $HY2_PORT/udp、$VLESS_PORT/tcp、$SS_PORT、80/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    W "firewalld 已启用: 确认放行对应端口(含 UDP)"
  else
    P "未检测到本机防火墙(ufw/firewalld)启用"
  fi
  W "云厂商安全组要在控制台单独放行——HY2 是 UDP, 最容易漏放 UDP 端口!"
  # 6) 时间同步(Reality/TLS 敏感)
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && P "系统时间已同步" || W "系统时间未同步: timedatectl set-ntp true"
  # 7) 证书到期
  if [ -f "$SB_DIR/server.crt" ]; then
    openssl x509 -checkend $((30*86400)) -noout -in "$SB_DIR/server.crt" >/dev/null 2>&1 && P "自签证书 30 天内不过期" || W "自签证书 30 天内将过期: 重跑 install 重新生成"
  fi
  # 8) 订阅可达
  curl -fsS -o /dev/null -m 5 "http://127.0.0.1$SUB_PATH" 2>/dev/null && P "订阅本机可达" || F "订阅本机不可达: 看 nginx -t / $WWW 权限"
  if [ -n "${PUBLIC_IP:-}" ]; then
    curl -fsS -o /dev/null -m 6 "http://$PUBLIC_IP$SUB_PATH" 2>/dev/null && P "订阅经公网 IP 可达" \
      || W "订阅经公网 IP 不可达(可能是 hairpin 不支持, 不一定是真问题): 用手机流量/外部网络测 http://$SUB_HOST$SUB_PATH"
  fi
  # 9) 可选组件
  [ -f "$CF_ENV" ] && { [ "$(systemctl is-active cloudflared 2>/dev/null)" = active ] && P "cloudflared(CF-Vless) 运行中" || W "cloudflared 未运行: systemctl status cloudflared"; }
  if [ -f /etc/systemd/system/sing-box-porthop.service ]; then
    { command -v nft >/dev/null 2>&1 && nft list table inet sb_hophy2 >/dev/null 2>&1 && P "端口跳跃 nftables 表在位"; } || W "端口跳跃服务装了但 nft 表缺失: systemctl restart sing-box-porthop"
  fi
  [ -n "${WARP_PRIVATE_KEY:-}" ] && P "WARP 解锁分流已配置(站点: ${WARP_SITES:-openai,netflix,disney})"
  echo "======================================="
  { [ "$issues" = 0 ] && ok "全部检查通过 ✓"; } || warn "$issues 项需关注(见上面 ! / ✗)"
}

do_set() {
  [ -f "$ENVFILE" ] || die "未检测到安装(缺 $ENVFILE)"
  [ "$#" -ge 1 ] || die "用法: install.sh set KEY=VAL ...  (可改 LIMIT_GB / EXPIRE_AT / COUNT_MODE / INTERFACE)"
  # shellcheck disable=SC1090
  . "$SECRETS" 2>/dev/null || true
  . "$ENVFILE"
  # 兼容旧 env(可能无 PUBLIC_IP/SUB_HOST): 回填后再让 write_env 重写, 否则会被清空
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  local a key val
  for a in "$@"; do
    key="${a%%=*}"; val="${a#*=}"
    [ "$key" != "$a" ] || die "参数要写成 KEY=VAL: $a"
    case "$key" in
      LIMIT_GB)   case "$val" in ''|.|*.*.*|*[!0-9.]*) die "LIMIT_GB 要是数字(如 200 或 0.5): $val";; esac; LIMIT_GB="$val" ;;
      COUNT_MODE) case "$val" in rx+tx|tx|max) COUNT_MODE="$val" ;; *) die "COUNT_MODE 只能 rx+tx/tx/max";; esac ;;
      INTERFACE)  [ -n "$val" ] || die "INTERFACE 不能空"; INTERFACE="$val" ;;
      EXPIRE_AT)  [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] || die "EXPIRE_AT 格式须为 'YYYY-MM-DD HH:MM:SS +0800'"; EXPIRE_AT="$val" ;;
      *) die "不支持的键: $key (可改 LIMIT_GB / EXPIRE_AT / COUNT_MODE / INTERFACE)" ;;
    esac
    ok "set $key=$val"
  done
  write_env   # 用更新后的全局重写 env(SUB_HOST/PUBLIC_IP 已从 env 读到, 一并保留)
  [ -f "$TRAFFIC_PY" ] && { "$PY" "$TRAFFIC_PY" >/dev/null 2>&1 && ok "已刷新订阅流量头(限额/到期即时生效)" || warn "流量头刷新失败, 5 分钟后 cron 会自动重试"; }
}

do_update() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  log "更新 sing-box(官方脚本)..."
  curl -fsSL https://sing-box.app/install.sh | sh || true
  command -v sing-box >/dev/null 2>&1 || die "sing-box 安装/更新失败"
  ok "sing-box 版本: $(sing-box version 2>/dev/null | awk '/version/{print $3; exit}')"
  if sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1; then
    systemctl restart sing-box && ok "已重启 sing-box" || warn "重启失败, 看 systemctl status sing-box"
  else
    warn "更新后配置校验未过, 未重启。请跑 sing-box check -c $SB_DIR/config.json 看详情"
  fi
}

do_restart() {
  systemctl restart sing-box 2>/dev/null && ok "sing-box 已重启" || warn "sing-box 重启失败"
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  ok "nginx 已重载"
  if [ -f "$CF_ENV" ]; then systemctl restart cloudflared 2>/dev/null && ok "cloudflared 已重启" || warn "cloudflared 重启失败"; fi
}

do_menu() {
  while true; do
    echo
    echo "  ===== sing-box 节点管理 ====="
    echo "  1) 安装 / 重装           2) 查看信息(订阅 URL)"
    echo "  3) 分享链接 / 二维码     4) 状态体检"
    echo "  5) 改参数(限额/到期)     6) 更新 sing-box"
    echo "  7) 加 CF 大保底(第5节点) 8) 重启服务"
    echo "  9) 卸载                  0) 退出"
    echo "  p) 看板页地址            k) 装 Komari 探针"
    echo "  b) 备份                  r) 恢复(迁移)"
    echo "  h) SSH 加固(密钥登录)    w) WARP 解锁分流"
    echo "  d) doctor 自检(常见坑)"
    printf '  选择: '
    read -r c || break
    # 每个动作放进 ( ) 子shell 并 || true: 这样某个动作内部 die/exit 只结束该动作,
    # 不会因 set -e 把整个菜单退出。
    case "$c" in
      1) ( do_install ) || true ;;
      2) ( do_info ) || true ;;
      3) ( do_links ) || true ;;
      4) ( do_status ) || true ;;
      5) printf '  输入 KEY=VAL(如 LIMIT_GB=500): '; read -r kv || true
         [ -n "${kv:-}" ] && { ( do_set "$kv" ) || true; } ;;
      6) ( do_update ) || true ;;
      7) printf '  CF_TOKEN: '; read -r t || true; printf '  CF_HOSTNAME: '; read -r h || true
         if [ -n "${t:-}" ] && [ -n "${h:-}" ]; then ( CF_TOKEN="$t" CF_HOSTNAME="$h" do_cf ) || true; else echo "  已取消(token/域名为空)"; fi ;;
      8) ( do_restart ) || true ;;
      9) ( do_uninstall ) || true ;;
      p|P) ( do_panel ) || true ;;
      k|K) printf '  KOMARI_ENDPOINT: '; read -r ke || true; printf '  KOMARI_TOKEN: '; read -r kt || true
           if [ -n "${ke:-}" ] && [ -n "${kt:-}" ]; then ( KOMARI_ENDPOINT="$ke" KOMARI_TOKEN="$kt" do_komari ) || true; else echo "  已取消"; fi ;;
      b|B) ( do_backup ) || true ;;
      r|R) printf '  备份文件路径: '; read -r rf || true; [ -n "${rf:-}" ] && { ( do_restore "$rf" ) || true; } ;;
      h|H) ( do_harden ) || true ;;
      w|W) ( do_warp ) || true ;;
      d|D) ( do_doctor ) || true ;;
      0) break ;;
      *) echo "  无效选择" ;;
    esac
  done
}

do_uninstall() {
  warn "即将卸载 sing-box 节点及相关配置。"
  if [ "${FORCE:-0}" != 1 ]; then
    printf '确认卸载? 输入 yes 继续: '
    read -r ans || true
    [ "$ans" = yes ] || { echo "已取消"; exit 0; }
  fi
  # 删除前自动备份密钥/参数, 防止一条命令不可逆地销毁全部凭证
  if [ -f "$SECRETS" ] || [ -f "$ENVFILE" ]; then
    local bdir="/root/sing-box-uninstall-backup-$(date +%Y%m%d-%H%M%S)"
    ( umask 077; mkdir -p "$bdir"
      [ -f "$SECRETS" ] && cp -a "$SECRETS" "$bdir/" 2>/dev/null
      [ -f "$ENVFILE" ] && cp -a "$ENVFILE" "$bdir/" 2>/dev/null ) || true
    ok "已备份密钥/参数到 $bdir"
  fi
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  [ -f "$SECRETS" ] && . "$SECRETS" 2>/dev/null || true
  rm -f "$SB_DIR/config.json" "$SB_DIR/server.crt" "$SB_DIR/server.key" "$SECRETS" 2>/dev/null || true
  rm -f "$ENVFILE" "$TRAFFIC_PY" "$CRON" "$NGINX_SNIPPET" "$NGINX_CONF" 2>/dev/null || true
  [ -n "${SUB_PATH:-}" ] && rm -f "$WWW$SUB_PATH" 2>/dev/null || true
  [ -n "${SUB_B64_PATH:-}" ] && rm -f "$WWW$SUB_B64_PATH" 2>/dev/null || true
  [ -n "${PANEL_PATH:-}" ] && rm -f "$WWW$PANEL_PATH" 2>/dev/null || true
  rm -f "$WWW"/sub-*.yaml "$WWW"/sub-b64-*.txt "$WWW"/panel-*.html 2>/dev/null || true   # 兜底: 即使 secrets 丢失也清掉含凭证的订阅/看板文件
  rm -f /run/sing-box-quota-stopped 2>/dev/null || true
  rm -f "$WARP_ENV" 2>/dev/null || true   # WARP 分流状态(wgcf 二进制保留, 无害)
  if [ -f "$CF_ENV" ]; then
    cloudflared service uninstall >/dev/null 2>&1 || systemctl disable --now cloudflared >/dev/null 2>&1 || true
    rm -f "$CF_ENV" 2>/dev/null || true
    warn "已停止本脚本 cf 子命令装的 cloudflared(CF 后台那条 Tunnel 需你自行删除)"
  else
    warn "未触碰 cloudflared(若你手动搭过 CF, 请自行处理 /etc/cloudflared, 凭证别误删)"
  fi
  if [ -f /etc/systemd/system/sing-box-porthop.service ]; then
    systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box-porthop.service "$SB_DIR/porthop.nft" 2>/dev/null || true
    command -v nft >/dev/null 2>&1 && nft delete table inet sb_hophy2 >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  ok "已卸载(保留 sing-box 程序与网络优化 sysctl; 备份见上)"
}

# 可选第5节点: CF-Vless 大保底(Argo 命名隧道)。VPS 侧自动, CF 后台需你先建 Tunnel。
do_cf() {
  umask 077
  [ -f "$SECRETS" ] || die "请先运行安装(bash install.sh)再加 CF-Vless"
  # shellcheck disable=SC1090
  . "$SECRETS"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -f "$CF_ENV" ]  && . "$CF_ENV"  2>/dev/null || true
  CF_PORT="${CF_PORT:-28080}"

  if [ -z "${CF_TOKEN:-}" ] || [ -z "${CF_HOSTNAME:-}" ]; then
    cat <<EOF
CF-Vless 大保底(第5节点)需要先在 Cloudflare 后台建一条 Tunnel:
  Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared
  · Public hostname: 你的域名(如 cf.example.com)
    Service: http://127.0.0.1:${CF_PORT}
  · 复制 Connector token
然后回本机运行:
  CF_TOKEN='粘贴token' CF_HOSTNAME='cf.example.com' bash install.sh cf
EOF
    die "缺少 CF_TOKEN 或 CF_HOSTNAME"
  fi
  case "$CF_HOSTNAME" in *[!A-Za-z0-9.-]*) die "CF_HOSTNAME 含非法字符: $CF_HOSTNAME";; esac
  case "$CF_PORT" in ''|*[!0-9]*) die "CF_PORT 必须是数字: $CF_PORT";; esac

  CF_VLESS_UUID="${CF_VLESS_UUID:-$(sing-box generate uuid)}"
  CF_WS_PATH="${CF_WS_PATH:-/cf-$(openssl rand -hex 8)}"
  case "$CF_WS_PATH" in /*) ;; *) CF_WS_PATH="/$CF_WS_PATH";; esac

  cat >"$CF_ENV" <<EOF
CF_HOSTNAME=$CF_HOSTNAME
CF_PORT=$CF_PORT
CF_VLESS_UUID=$CF_VLESS_UUID
CF_WS_PATH=$CF_WS_PATH
EOF
  chmod 600 "$CF_ENV"

  # 装 cloudflared(直接下二进制, 跨发行版)
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "下载 cloudflared..."
    local cfarch
    case "$(uname -m)" in
      x86_64|amd64)  cfarch=amd64 ;;
      aarch64|arm64) cfarch=arm64 ;;
      *) die "cloudflared 不支持架构 $(uname -m)" ;;
    esac
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cfarch" \
      || die "cloudflared 下载失败"
    chmod 755 /usr/local/bin/cloudflared
  fi
  log "安装 cloudflared 服务(token)..."
  cloudflared service uninstall >/dev/null 2>&1 || true   # 幂等: 重复跑 cf(换token)时先卸旧服务
  cloudflared service install "$CF_TOKEN" || die "cloudflared service install 失败(token 是否正确?)"
  systemctl enable --now cloudflared >/dev/null 2>&1 || true

  # 重建 config(含 cf-vless-ws-in 入站)与订阅(含 CF-Vless 节点)
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  detect_net
  render_singbox_config >"$SB_DIR/config.json"; chmod 600 "$SB_DIR/config.json"
  sing-box check -c "$SB_DIR/config.json" || die "加入 CF 入站后 sing-box 配置校验失败"
  systemctl restart sing-box
  write_subscription   # 同时刷新 Clash 订阅与通用(base64)订阅, 都带上 CF-Vless

  ok "CF-Vless 已接入(本地入站 127.0.0.1:$CF_PORT, 隧道 $CF_HOSTNAME, 路径 $CF_WS_PATH)"
  log "验证隧道(看到 101 = 通; 刚装可能要等几秒 cloudflared 连上)..."
  if curl -isS -m 10 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
       -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
       "https://$CF_HOSTNAME$CF_WS_PATH" 2>/dev/null | grep -qi '101'; then
    ok "隧道连通(101 Switching Protocols)。客户端重新拉取订阅即可看到 CF-Vless。"
  else
    warn "暂未拿到 101: cloudflared 可能还在连接, 或 CF 后台 hostname→http://127.0.0.1:$CF_PORT 未配好。"
    echo "  等几秒后手动复测: systemctl is-active cloudflared sing-box"
    echo "  curl -i -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' https://$CF_HOSTNAME$CF_WS_PATH"
  fi
}

install_wgcf() {
  command -v wgcf >/dev/null 2>&1 && return
  log "下载 wgcf(WARP 注册工具)..."
  local arch ver
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=armv7 ;;
    *) die "wgcf 不支持架构 $(uname -m)" ;;
  esac
  # 跟随 releases/latest 重定向拿版本号(免 API 限流), 资产名形如 wgcf_2.2.22_linux_amd64
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/ViRb3/wgcf/releases/latest 2>/dev/null | sed -E 's#.*/tag/v?##' || true)"
  [ -n "$ver" ] || die "无法获取 wgcf 最新版本号"
  curl -fsSL -o /usr/local/bin/wgcf \
    "https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}" \
    || die "wgcf 下载失败"
  chmod 755 /usr/local/bin/wgcf
}

do_warp() {
  [ -f "$SECRETS" ] || die "请先运行安装(bash install.sh)再开 WARP 分流"
  # shellcheck disable=SC1090
  . "$SECRETS"
  [ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null || true
  [ -f "$CF_ENV" ]  && . "$CF_ENV"  2>/dev/null || true   # 保留已接入的 CF-Vless 节点
  CF_PORT="${CF_PORT:-28080}"
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  detect_net

  # 关闭分流: 删状态 + 重渲染(护栏校验)
  if [ "${1:-}" = "off" ]; then
    [ -f "$WARP_ENV" ] || { ok "未启用 WARP 分流, 无需关闭"; return 0; }
    rm -f "$WARP_ENV"
    WARP_PRIVATE_KEY=""; WARP_ADDR_V4=""; WARP_ADDR_V6=""; WARP_RESERVED=""
    local tmpc; tmpc="$(mktemp)"
    render_singbox_config >"$tmpc"
    if sing-box check -c "$tmpc" >/dev/null 2>&1; then
      install -m600 "$tmpc" "$SB_DIR/config.json"; rm -f "$tmpc"
      systemctl restart sing-box && ok "已关闭 WARP 分流(原解锁站点恢复走 VPS 直连出口)" || warn "sing-box 重启失败"
    else
      rm -f "$tmpc"; warn "关闭后配置校验异常, 已保留原配置不动"
    fi
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  detect_os
  local req_sites="$WARP_SITES"   # 本次显式传入的 WARP_SITES(在 source warp.env 覆盖前先记下)

  if [ -f "$WARP_ENV" ]; then
    log "复用已注册的 WARP 账号(避免重复注册被 Cloudflare 限流)..."
    # shellcheck disable=SC1090
    . "$WARP_ENV"
  else
    install_wgcf
    log "注册 Cloudflare WARP 账号(wgcf)..."
    local wd; wd="$(mktemp -d)"
    if ! ( cd "$wd" && wgcf register --accept-tos >/dev/null 2>&1 ); then
      rm -rf "$wd"; die "wgcf 注册失败(Cloudflare 可能对该 IP 临时限流, 稍后重试)"
    fi
    if ! ( cd "$wd" && wgcf generate >/dev/null 2>&1 ); then
      rm -rf "$wd"; die "wgcf 生成 WireGuard 配置失败"
    fi
    local prof="$wd/wgcf-profile.conf"
    [ -f "$prof" ] || { rm -rf "$wd"; die "未生成 wgcf-profile.conf"; }
    # base64 私钥可能以 '=' 结尾, 不能用 -F= 切; 用 sed 去前缀
    WARP_PRIVATE_KEY="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$prof" | tr -d ' \r' | head -n1 || true)"
    WARP_ADDR_V4="$(sed -n 's#^Address[[:space:]]*=[[:space:]]*##p' "$prof" | grep -E '^[0-9]+\.' | head -n1 | tr -d ' \r' || true)"
    WARP_ADDR_V6="$(sed -n 's#^Address[[:space:]]*=[[:space:]]*##p' "$prof" | grep ':' | head -n1 | tr -d ' \r' || true)"
    [ -n "$WARP_ADDR_V4" ] || WARP_ADDR_V4="172.16.0.2/32"
    [ -n "$WARP_ADDR_V6" ] || WARP_ADDR_V6="2606:4700:110:8a36:df92:102a:9602:fa18/128"
    WARP_RESERVED=""   # 单账号专用默认不带; 如解锁不生效再手动填
    rm -rf "$wd"
    ok "WARP 账号已注册"
  fi
  [ -n "$WARP_PRIVATE_KEY" ] || die "WARP 私钥为空, 删 $WARP_ENV 后重试注册"
  # 站点优先级: 本次显式传入 > warp.env 记录 > 默认; 统一在此回写 warp.env(支持改站点后重跑)
  WARP_SITES="${req_sites:-${WARP_SITES:-openai,netflix,disney}}"
  # 落盘前清洗成安全字符集(只留 小写字母/数字/逗号/连字符), 防引号等破坏 warp.env 的 source
  WARP_SITES="$(printf '%s' "$WARP_SITES" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9,-')"
  [ -n "$WARP_SITES" ] || WARP_SITES="openai,netflix,disney"
  ( umask 077; cat >"$WARP_ENV" <<EOF
WARP_PRIVATE_KEY='$WARP_PRIVATE_KEY'
WARP_ADDR_V4='$WARP_ADDR_V4'
WARP_ADDR_V6='$WARP_ADDR_V6'
WARP_RESERVED='$WARP_RESERVED'
WARP_SITES='$WARP_SITES'
EOF
  )

  # 安全护栏: 渲染到临时文件 -> sing-box check 通过才替换正式 config, 失败保留原配置(节点不受影响)
  log "生成带 WARP 分流的配置并校验..."
  local tmpc; tmpc="$(mktemp)"
  render_singbox_config >"$tmpc"
  if sing-box check -c "$tmpc" >/dev/null 2>&1; then
    install -m600 "$tmpc" "$SB_DIR/config.json"; rm -f "$tmpc"
    if systemctl restart sing-box; then
      ok "WARP 解锁分流已开启 —— 这些站点走 WARP 出口: $WARP_SITES"
      echo "  改站点: WARP_SITES='openai,netflix,tiktok' bash install.sh warp   |  关闭: bash install.sh warp off"
      echo "  若能连但仍被拦(解锁没生效), 多半是缺 reserved: 编辑 $WARP_ENV 设 WARP_RESERVED='a,b,c' 后重跑 warp"
    else
      warn "sing-box 重启失败, 看 systemctl status sing-box"
    fi
  else
    rm -f "$tmpc"
    warn "带 WARP 的配置 sing-box check 未通过, 已保留原配置(现有节点不受影响)。"
    echo "  最可能原因: sing-box < 1.12(wireguard endpoint 需 1.12+) —— 先升级: bash install.sh update 再重跑 warp"
    return 1
  fi
}

do_install() {
  umask 077          # 所有新建文件默认 600/700, 消除"先写后 chmod"的可读时间窗
  validate_inputs    # 端口/SNI/到期时间不合法立即报错, 不装到一半才崩
  detect_os
  install_deps
  time_sync
  install_singbox
  detect_net
  check_reality_sni   # best-effort 探测偷证书目标是否支持 TLS1.3+H2, 填错只提示
  gen_secrets
  # shellcheck disable=SC1090
  [ -f "$CF_ENV" ] && . "$CF_ENV" 2>/dev/null || true   # 已接入过 CF-Vless 则重装时保留
  [ -f "$WARP_ENV" ] && . "$WARP_ENV" 2>/dev/null || true   # 已接入过 WARP 则重装/更新时保留分流
  gen_cert
  config_sysctl   # 在 sing-box 启动前应用, 这样 HY2/QUIC 一启动就拿到大 UDP 缓冲
  write_env
  write_singbox_config
  write_subscription
  config_nginx
  install_traffic
  config_firewall
  config_porthop
  print_summary
}

main() {
  need_root
  case "${1:-install}" in
    install)   do_install ;;
    info)      do_info ;;
    panel)     do_panel ;;
    links)     do_links ;;
    status)    do_status ;;
    doctor)    do_doctor ;;
    set)       shift; do_set "$@" ;;
    backup)    do_backup ;;
    restore)   shift; do_restore "$@" ;;
    harden)    do_harden ;;
    update)    do_update ;;
    restart)   do_restart ;;
    cf)        do_cf ;;
    warp)      shift; do_warp "$@" ;;
    komari)    do_komari ;;
    menu)      do_menu ;;
    uninstall) do_uninstall ;;
    *) echo "用法: $0 [install|info|panel|links|status|doctor|set|backup|restore <file>|harden|update|restart|cf|warp [off]|komari|menu|uninstall]"; exit 1 ;;
  esac
}

# 仅在直接执行时运行 main(被 source 时不运行, 便于测试渲染函数)
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
