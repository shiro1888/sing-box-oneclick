#!/usr/bin/env bash
# =============================================================================
#  sing-box 四协议一键部署脚本
#  Hysteria2 + AnyTLS + VLESS-Reality-Vision + Shadowsocks-2022  ->  Clash/Mihomo 订阅
#
#  用法:
#    一键(在线):  bash <(curl -fsSL https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh)
#    本地:        sudo bash install.sh [install|info|cf|uninstall]
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

# 路径
SB_DIR=/etc/sing-box
SECRETS="$SB_DIR/node-secrets.env"
ENVFILE=/etc/sing-box-node.env
WWW=/var/www/html
NGINX_SNIPPET=/etc/nginx/snippets/sub_headers.conf
NGINX_CONF=/etc/nginx/conf.d/00-singbox-sub.conf
TRAFFIC_PY=/usr/local/bin/traffic_limit.py
CRON=/etc/cron.d/traffic_limit
BBR_CONF=/etc/sysctl.d/99-bbr.conf
CF_ENV="$SB_DIR/cf.env"   # CF-Vless 状态(存在=已接入第5节点; 由 cf 子命令写入)

# 运行期填充(写成可被环境覆盖, 既不影响生产, 也便于测试渲染函数)
PKG="${PKG:-}"; OS_ID="${OS_ID:-}"; PUBLIC_IP="${PUBLIC_IP:-}"; SUB_HOST="${SUB_HOST:-}"
INTERFACE="${INTERFACE:-}"; SB_VER="${SB_VER:-}"
ANYTLS_OK="${ANYTLS_OK:-1}"; EXPIRE_VALUE="${EXPIRE_VALUE:-}"
# 密钥(gen_secrets 填充或从 SECRETS 复用)
HY2_PASSWORD="${HY2_PASSWORD:-}"; ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"; VLESS_UUID="${VLESS_UUID:-}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"; REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"; SUB_PATH="${SUB_PATH:-}"; SS_PASSWORD="${SS_PASSWORD:-}"
# CF-Vless(可选第5节点; cf.env 提供, 空=未接入)
CF_HOSTNAME="${CF_HOSTNAME:-}"; CF_VLESS_UUID="${CF_VLESS_UUID:-}"; CF_WS_PATH="${CF_WS_PATH:-}"

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
      apt-get install -y curl wget tar jq nginx vnstat openssl cron python3 iproute2 ca-certificates ufw
      ;;
    dnf|yum)
      # vnstat / jq 在 RHEL 系常在 EPEL(+CRB), 先尝试启用, 否则流量统计会装不上
      "$PKG" install -y epel-release >/dev/null 2>&1 || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
        dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      "$PKG" install -y curl wget tar jq nginx vnstat openssl cronie python3 iproute ca-certificates || \
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
    note "sing-box 版本 ${SB_VER:-未知} < 1.12.0, 不支持 AnyTLS: 已自动跳过 AnyTLS, 仅部署 Hysteria2 + Vless。升级 sing-box 后重跑本脚本即可补上。"
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
  SS_PASSWORD="$(gen_ss_password)"
  ( umask 077
    cat >"$SECRETS" <<EOF
HY2_PASSWORD=$HY2_PASSWORD
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
VLESS_UUID=$VLESS_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
SUB_PATH=$SUB_PATH
SS_PASSWORD="$SS_PASSWORD"
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
  cat <<JSON
{
  "log": { "disabled": false, "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASSWORD" } ],
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
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
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
  "$PY" - <<'PY'
import os
ip  = os.environ["PUBLIC_IP"]
dom = os.environ.get("DOMAIN", "")
anytls = os.environ["ANYTLS_OK"] == "1"

proxies = []
proxies.append(f'''  - name: "Hysteria2"
    type: hysteria2
    server: {ip}
    port: {os.environ["HY2_PORT"]}
    password: {os.environ["HY2_PASSWORD"]}
    sni: {os.environ["TLS_SNI"]}
    skip-cert-verify: true
    alpn:
      - h3''')
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
  log "生成 Clash/Mihomo 订阅..."
  mkdir -p "$WWW"
  chmod 755 "$WWW"   # 防止 umask 077 下新建的 web 根变 700, 导致 nginx(www-data) 无法遍历→订阅 403
  render_subscription_yaml >"$WWW$SUB_PATH"
  chmod 644 "$WWW$SUB_PATH"
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

config_bbr() {
  [ "$ENABLE_BBR" = 1 ] || return 0
  cat >"$BBR_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR 已开启"
  else
    warn "BBR 未生效(内核可能不支持), 不影响使用"
    note "BBR: 当前内核未启用 BBR, 升级内核后会自动生效(配置已写入 $BBR_CONF)。"
  fi
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
  printf '  订阅名称:  %s\n' "$AIRPORT_NAME"
  printf '  订阅 URL:  %s\n' "$sub_url"
  echo
  printf '  节点(客户端里显示名):\n'
  printf '    - Hysteria2  (UDP %s)\n' "$HY2_PORT"
  [ "$ANYTLS_OK" = 1 ] && printf '    - AnyTLS     (TCP %s)\n' "$ANYTLS_PORT"
  printf '    - Vless      (TCP %s, Reality)\n' "$VLESS_PORT"
  printf '    - SS2022     (TCP+UDP %s)\n' "$SS_PORT"
  [ -n "$CF_HOSTNAME" ] && printf '    - CF-Vless   (WS via %s, Argo 大保底)\n' "$CF_HOSTNAME"
  echo
  printf '  管理命令:\n'
  printf '    查看信息:    bash install.sh info\n'
  printf '    加CF大保底:  CF_TOKEN=.. CF_HOSTNAME=.. bash install.sh cf\n'
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
  rm -f "$WWW"/sub-*.yaml 2>/dev/null || true   # 兜底: 即使 secrets 丢失也清掉含凭证的订阅文件
  rm -f /run/sing-box-quota-stopped 2>/dev/null || true
  if [ -f "$CF_ENV" ]; then
    cloudflared service uninstall >/dev/null 2>&1 || systemctl disable --now cloudflared >/dev/null 2>&1 || true
    rm -f "$CF_ENV" 2>/dev/null || true
    warn "已停止本脚本 cf 子命令装的 cloudflared(CF 后台那条 Tunnel 需你自行删除)"
  else
    warn "未触碰 cloudflared(若你手动搭过 CF, 请自行处理 /etc/cloudflared, 凭证别误删)"
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  ok "已卸载(保留 sing-box 程序与 BBR sysctl; 备份见上)"
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
  render_subscription_yaml >"$WWW$SUB_PATH"; chmod 644 "$WWW$SUB_PATH"

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

do_install() {
  umask 077          # 所有新建文件默认 600/700, 消除"先写后 chmod"的可读时间窗
  validate_inputs    # 端口/SNI/到期时间不合法立即报错, 不装到一半才崩
  detect_os
  install_deps
  time_sync
  install_singbox
  detect_net
  gen_secrets
  # shellcheck disable=SC1090
  [ -f "$CF_ENV" ] && . "$CF_ENV" 2>/dev/null || true   # 已接入过 CF-Vless 则重装时保留
  gen_cert
  write_env
  write_singbox_config
  write_subscription
  config_nginx
  install_traffic
  config_bbr
  config_firewall
  print_summary
}

main() {
  need_root
  case "${1:-install}" in
    install)   do_install ;;
    info)      do_info ;;
    cf)        do_cf ;;
    uninstall) do_uninstall ;;
    *) echo "用法: $0 [install|info|cf|uninstall]"; exit 1 ;;
  esac
}

# 仅在直接执行时运行 main(被 source 时不运行, 便于测试渲染函数)
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
