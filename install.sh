#!/usr/bin/env bash
# =============================================================================
#  sing-box 三协议一键部署脚本
#  Hysteria2 + AnyTLS + Shadowsocks-2022  ->  Clash/Mihomo 订阅
#
#  2026-10 现网口径: 直连 VLESS/Reality 与旧 CF-VLESS 一键路径已退休;
#  节点只保留 Hysteria2(UDP 443) / AnyTLS(TCP 4434) / SS2022(TCP+UDP 4435)。
#
#  用法:
#    一键(在线):  bash <(curl -fsSL https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh)
#    本地:        sudo bash install.sh [install|info|panel|panel-pass <密码>|links|status|doctor|set|backup|restore <file>|harden|update|restart|cf off|warp [off]|admin [off]|komari|menu|uninstall]
#    交互菜单:    sudo bash install.sh menu
#    可视化看板:  sudo bash install.sh panel        (浏览器看订阅+扫码)
#    装探针:      KOMARI_ENDPOINT=https://面板 KOMARI_TOKEN=token sudo bash install.sh komari
#
#  常用环境变量(可选,覆盖默认):
#    LIMIT_GB=200            每月显示/限流额度
#    COUNT_MODE=tx           计费方式 tx(默认,匹配多数商家)|max|rx+tx(仅真双向计费)
#    EXPIRE_AT="..."         到期时间(默认留空, 不显示到期)
#    DOMAIN=node.example.com 订阅域名(留空=用公网IP,无需域名)
#    AIRPORT_NAME=US-01     客户端订阅显示名
#    PUBLIC_IP=1.2.3.4       手动指定公网IP(探测失败时)
#    HY2_PORT/ANYTLS_PORT/SS_PORT  端口(默认 443/4434/4435)
#    SS_METHOD=2022-blake3-aes-128-gcm  SS2022 加密方法(可改 256-gcm/chacha)
#    TLS_SNI                 HY2/AnyTLS 自签证书 CN(默认 www.bing.com)
#    SUB_TLS=auto            订阅 TLS: auto(有域名证书就开 443 HTTPS)|1|0
#    ENABLE_BBR=1            开启 BBR(默认开,纯 sysctl,安全)
#    ENABLE_UFW=0            自动配置并启用 ufw(默认关,避免锁死SSH)
#    ENABLE_OBFS=1           HY2 salamander 混淆(默认开, 抗 QUIC 识别)
#    ENABLE_BLOCK_BT=1       拦截 BT/PT(默认开, 防被商家封机收滥用投诉)
#    ENABLE_BLOCK_ADS=1      MRS 广告规则拦截(默认开)
#
#  HY2 统一使用自动拥塞控制: 不再支持 HY2_HOP_RANGE / HY2_UP / HY2_DOWN /
#  HY2_UP_MBPS / HY2_DOWN_MBPS; 老机器上的端口跳跃会在重装时自动清理。
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
# 先记录"用户本次是否显式传入"这些运行参数, 再套默认值。
# 用途: 重装(二次运行 install)时, 已存在的 $ENVFILE 里的值应作为默认被沿用,
# 但本次命令行显式传的 env 仍要赢 —— 见 do_install 里的 merge_env_defaults。
# 已下线参数的显式传入必须直接报错: 否则用户以为开了端口跳跃/暴力带宽, 实际配置里没有,
# 排查方向会被彻底带偏。老 env 文件里的同名键不走这条(load_node_env 会读入后丢弃)。
for _legacy in HY2_HOP_RANGE HY2_UP HY2_DOWN HY2_UP_MBPS HY2_DOWN_MBPS; do
  eval "_legacy_val=\${$_legacy:-}"
  [ -z "$_legacy_val" ] || die "$_legacy 已下线(2026-10 现网口径: HY2 固定 UDP 443 + 自动拥塞控制), 请去掉该参数后重跑"
done
unset _legacy _legacy_val

for _v in LIMIT_GB COUNT_MODE EXPIRE_AT INTERFACE DOMAIN AIRPORT_NAME NODE_ADDR \
          HY2_PORT ANYTLS_PORT SS_PORT SS_METHOD TLS_SNI SUB_TLS SUB_CERT SUB_KEY \
          ENABLE_BLOCK_BT ENABLE_BLOCK_ADS ENABLE_HY2 ENABLE_OBFS SS_UDP; do
  eval "_CLI_$_v=\"\${$_v:-}\""
done
unset _v

LIMIT_GB="${LIMIT_GB:-200}"
COUNT_MODE="${COUNT_MODE:-tx}"
DOMAIN="${DOMAIN:-}"
AIRPORT_NAME="${AIRPORT_NAME:-US-01}"
HY2_PORT="${HY2_PORT:-443}"
ANYTLS_PORT="${ANYTLS_PORT:-4434}"
SS_PORT="${SS_PORT:-4435}"
SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
TLS_SNI="${TLS_SNI:-www.bing.com}"
# 订阅 TLS: auto=有域名且证书就位才开 443 HTTPS; 1=强制; 0=只用 80 HTTP
SUB_TLS="${SUB_TLS:-auto}"
ENABLE_BBR="${ENABLE_BBR:-1}"
ENABLE_UFW="${ENABLE_UFW:-0}"
ENABLE_OBFS="${ENABLE_OBFS:-1}"      # HY2 salamander 混淆(默认开, 抗 QUIC 识别; 0 关)
ENABLE_HY2="${ENABLE_HY2:-1}"        # 是否部署 Hysteria2(默认开)。0=不装 HY2:
                                     #   甲骨文小机 / 已被 DDoS 清洗过的机器按文档「按机型选协议组合」走 TCP 组合时用。
                                     #   关掉后: 不写 hy2 入站、订阅与分享链接不含 HY2、不放行 UDP 端口。
SS_UDP="${SS_UDP:-1}"                # SS2022 是否走 UDP(默认开)。0=TCP-only 稳定版:
                                     #   订阅写 udp: false 且不放行 SS 的 UDP 端口(服务端仍监听, 客户端不走 UDP)。
ENABLE_BLOCK_BT="${ENABLE_BLOCK_BT:-1}"    # 拦截 BT/PT(默认开, 防被商家封机收滥用投诉; 0 关)
ENABLE_BLOCK_ADS="${ENABLE_BLOCK_ADS:-1}"  # MRS 广告规则拦截(默认开; 0 关)
KOMARI_ENDPOINT="${KOMARI_ENDPOINT:-}"  # Komari 探针面板地址(install.sh komari 用)
KOMARI_TOKEN="${KOMARI_TOKEN:-}"        # Komari 节点 token

# 路径
SB_DIR=/etc/sing-box
SECRETS="$SB_DIR/node-secrets.env"
ENVFILE=/etc/sing-box-node.env
WWW=/var/www/html
NGINX_SNIPPET=/etc/nginx/snippets/sub_headers.conf
NGINX_CONF=/etc/nginx/conf.d/00-singbox-sub.conf
NGINX_MAIN="${NGINX_MAIN:-/etc/nginx/nginx.conf}"
NGINX_DEFAULT_SITE="${NGINX_DEFAULT_SITE:-/etc/nginx/sites-enabled/default}"
NGINX_DEFAULT_CONF="${NGINX_DEFAULT_CONF:-/etc/nginx/conf.d/default.conf}"
RESTORE_ROOT="${RESTORE_ROOT:-/}"
PORTHOP_SERVICE="${PORTHOP_SERVICE:-/etc/systemd/system/sing-box-porthop.service}"
PANEL_MAP=/etc/nginx/.singbox_panel_map.conf   # 看板页登录: nginx map 片段(600 root, 校验 cookie==密码; 存在=已开登录; panel-pass 管理)
TRAFFIC_PY=/usr/local/bin/traffic_limit.py
CRON=/etc/cron.d/traffic_limit
SYSCTL_CONF=/etc/sysctl.d/99-singbox.conf
BBR_MODULE_CONF=/etc/modules-load.d/singbox-bbr.conf
# SSH 加固(harden)相关路径 —— 提成变量只为可测试(测试里指到临时目录);
# 生产默认值与原来的写死路径完全一致, 不要在真机上覆盖它们。
AKEYS="${AKEYS:-/root/.ssh/authorized_keys}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
CF_ENV="$SB_DIR/cf.env"   # 旧 CF-Vless 状态(仅用于 cf off 清理与重装提示, 不再进订阅)
CF_PENDING_ENV="$SB_DIR/cf.restore-pending.env" # 旧版恢复流程遗留的待重接 CF 参数, 仅清理
WARP_ENV="$SB_DIR/warp.env"   # WARP 解锁状态(存在=已接入; 由 warp 子命令写入)
# 管理面板(admin 子命令; 仅监听 127.0.0.1, 经 SSH 隧道访问, Token 鉴权)
ADMIN_ENV="$SB_DIR/admin.env"           # ADMIN_TOKEN / ADMIN_PORT
ADMIN_HTML="$SB_DIR/admin.html"          # 面板页(服务端注入 token 后下发)
ADMIN_PY=/usr/local/bin/singbox-admin.py # 后端(python stdlib, 无 pip)
ADMIN_INSTALL="$SB_DIR/install.sh"       # 供后端调用的 install.sh 副本
ADMIN_PORT="${ADMIN_PORT:-8088}"
ADMIN_RAW_URL="https://raw.githubusercontent.com/shiro1888/sing-box-oneclick/main/install.sh"

# 运行期填充(写成可被环境覆盖, 既不影响生产, 也便于测试渲染函数)
PKG="${PKG:-}"; OS_ID="${OS_ID:-}"; PUBLIC_IP="${PUBLIC_IP:-}"; SUB_HOST="${SUB_HOST:-}"
INTERFACE="${INTERFACE:-}"; SB_VER="${SB_VER:-}"
ANYTLS_OK="${ANYTLS_OK:-1}"; EXPIRE_VALUE="${EXPIRE_VALUE:-}"
# 密钥(gen_secrets 填充或从 SECRETS 复用)。VLESS/Reality 相关变量仅用于兼容旧状态文件,
# 新装/升级后不再生成也不会写回。
HY2_PASSWORD="${HY2_PASSWORD:-}"; ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"
SUB_PATH="${SUB_PATH:-}"; SS_PASSWORD="${SS_PASSWORD:-}"
SUB_B64_PATH="${SUB_B64_PATH:-}"   # 通用(base64)订阅路径(供 v2rayN 等; gen_secrets 生成)
OBFS_PASSWORD="${OBFS_PASSWORD:-}" # HY2 obfs 密码(非空=启用 obfs; gen_secrets 生成)
PANEL_PATH="${PANEL_PATH:-}"       # 可视化看板页路径(随机; gen_secrets 生成)
# 旧 CF-Vless 状态(只读兼容; cf off 清理)
CF_HOSTNAME="${CF_HOSTNAME:-}"; CF_VLESS_UUID="${CF_VLESS_UUID:-}"; CF_WS_PATH="${CF_WS_PATH:-}"
RESTORE_TX_TARGETS=(); RESTORE_TX_STAGE=""; RESTORE_TX_BACKUP=""; RESTORE_TX_OLD_SINGBOX_ACTIVE=0; RESTORE_TX_OLD_NGINX_ACTIVE=0; RESTORE_TX_ROLLBACK_STARTED=0
INSTALL_TX_PATHS=(); INSTALL_TX_BACKUP=""; INSTALL_TX_OLD_SUB_PATH=""; INSTALL_TX_OLD_B64_PATH=""; INSTALL_TX_OLD_PANEL_PATH=""; INSTALL_TX_OLD_SINGBOX_ACTIVE=0; INSTALL_TX_OLD_NGINX_ACTIVE=0; INSTALL_TX_OLD_PORTHOP_ACTIVE=0; INSTALL_TX_ROLLBACK_STARTED=0
IS_IPV6="${IS_IPV6:-0}"; NODE_ADDR="${NODE_ADDR:-}"   # detect_net 里按探测结果赋值
# 证书路径: server.crt/key 是 HY2/AnyTLS 自签证书; sub.crt/key 可选, 存在时订阅走 443 HTTPS。
# 订阅证书允许用 SUB_CERT/SUB_KEY 覆盖; 默认值在函数里按 SB_DIR 现算(restore/测试会改 SB_DIR)。
SUB_CERT="${SUB_CERT:-}"; SUB_KEY="${SUB_KEY:-}"
# WARP 解锁分流(warp.env 提供; WARP_PRIVATE_KEY 非空=启用)
WARP_DEFAULT_SITES="openai,anthropic,google-gemini,netflix,disney"
WARP_PRIVATE_KEY="${WARP_PRIVATE_KEY:-}"; WARP_ADDR_V4="${WARP_ADDR_V4:-}"; WARP_ADDR_V6="${WARP_ADDR_V6:-}"; WARP_RESERVED="${WARP_RESERVED:-}"
WARP_SITES="${WARP_SITES:-}"   # 走 WARP 的 geosite 列表(逗号分隔, 可自定义; 空=render 用 WARP_DEFAULT_SITES)

# ----------------------------------------------------------------- 工具
need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行(sudo bash install.sh)"; }

# 同一时刻只允许一个修改型管理动作，避免 install/cf/warp/set 并发时各自基于旧快照覆盖对方。
with_maintenance_lock() {
  if [ "${MAINT_LOCK_HELD:-0}" = 1 ] || ! command -v flock >/dev/null 2>&1; then
    "$@"
    return
  fi
  # 单独子 shell 持锁：无论动作成功、return 还是 die，进程退出都会关闭 FD 释放锁。
  # 菜单是长生命周期进程，若 FD 留在父 shell，下一次维护会被上一次自己锁住。
  (
    set -eEuo pipefail
    mkdir -p "$SB_DIR"
    local lock_fd
    exec {lock_fd}>"$SB_DIR/.maintenance.lock"
    flock -w "${MAINT_LOCK_WAIT:-30}" "$lock_fd" || die "另一项维护操作仍在运行，请稍后重试"
    MAINT_LOCK_HELD=1 "$@"
  )
}

# 菜单动作必须在真正启用 errexit 的独立子 shell 中执行；不能用 `( action ) || true`，
# 否则 Bash 会在整个 action 调用链里禁用 set -e，让失败后继续覆盖文件并误报成功。
run_menu_action() {
  local rc had_errexit=0
  case $- in *e*) had_errexit=1 ;; esac
  set +e
  ( set -eEuo pipefail; "$@" )
  rc=$?
  if [ "$had_errexit" = 1 ]; then set -e; else set +e; fi
  [ "$rc" -eq 0 ] || warn "操作失败（退出码 $rc），已返回菜单；请查看上方错误"
  return 0
}

# 从 stdin 完整写入同目录临时文件，再原子替换目标；任何写入/chmod/mv 失败都保留旧文件。
atomic_write_file() {
  local target="$1" mode="${2:-600}" dir base tmp
  dir="$(dirname "$target")"; base="$(basename "$target")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")" || return 1
  if ! cat >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

snapshot_files() {
  local dir="$1" i=0 path
  shift
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  for path in "$@"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -a "$path" "$dir/$i" || return 1
      printf '1' >"$dir/$i.exists"
    else
      printf '0' >"$dir/$i.exists"
    fi
    i=$((i+1))
  done
}

restore_files() {
  local dir="$1" i=0 path existed rc=0
  shift
  # 先完整校验快照元数据，再删除任何目标。否则备份目录已被前一次回滚删除时，
  # 缺失的 *.exists 会被误当成 0，第二次回滚反而把刚恢复的正式文件全部删掉。
  for path in "$@"; do
    [ -f "$dir/$i.exists" ] || { err "回滚快照不完整，缺少: $dir/$i.exists"; return 1; }
    existed="$(cat "$dir/$i.exists" 2>/dev/null)" || return 1
    case "$existed" in
      0) ;;
      1) [ -e "$dir/$i" ] || [ -L "$dir/$i" ] || { err "回滚快照不完整，缺少: $dir/$i"; return 1; } ;;
      *) err "回滚快照标记非法: $dir/$i.exists"; return 1 ;;
    esac
    i=$((i+1))
  done
  i=0
  for path in "$@"; do
    existed="$(cat "$dir/$i.exists")"
    rm -rf "$path" || rc=1
    if [ "$existed" = 1 ]; then
      mkdir -p "$(dirname "$path")" || rc=1
      cp -a "$dir/$i" "$path" || rc=1
    fi
    i=$((i+1))
  done
  return "$rc"
}

# 对一组已完整生成的文件做带回滚的提交。单个 rename 原子；整组若中途失败则恢复旧快照。
publish_files_transaction() {
  [ $(( $# % 2 )) -eq 0 ] || return 1
  local backup i rc=0
  local -a sources=() targets=()
  while [ "$#" -gt 0 ]; do
    sources+=("$1"); targets+=("$2"); shift 2
  done
  mkdir -p "$(dirname "${targets[0]}")" || return 1
  backup="$(mktemp -d "$(dirname "${targets[0]}")/.publish-backup.XXXXXX")" || return 1
  snapshot_files "$backup" "${targets[@]}" || { rm -rf "$backup"; return 1; }

  # 提交窗口很短；暂时屏蔽可捕获信号，避免只切换了半组文件。SIGKILL/掉电仍靠下次校验修复。
  trap '' HUP INT TERM
  for ((i=0; i<${#sources[@]}; i++)); do
    if [ "${sources[$i]}" = - ]; then
      if ! rm -f "${targets[$i]}"; then rc=1; break; fi
    elif ! mv -f "${sources[$i]}" "${targets[$i]}"; then
      rc=1; break
    fi
  done
  if [ "$rc" -ne 0 ]; then
    if ! restore_files "$backup" "${targets[@]}"; then
      err "发布失败且旧文件回滚不完整，备份保留在: $backup"
      trap - HUP INT TERM
      return 1
    fi
  fi
  trap - HUP INT TERM
  rm -rf "$backup"
  return "$rc"
}

state_has_key() {
  local key="$1" file="${2:-$ENVFILE}"
  [ -f "$file" ] && grep -qE "^${key}=" "$file"
}

# 老版本没有持久化端口/SNI/NODE_ADDR/订阅名。首次升级时从现有订阅和看板回填，
# 避免单独运行 panel/set 时拿默认值重生成出与真实服务不一致的链接。
hydrate_legacy_runtime_state() {
  [ -n "${PUBLIC_IP:-}" ] || return 0
  NODE_ADDR="${NODE_ADDR:-$PUBLIC_IP}"
  if [ -z "${DOMAIN:-}" ] && [ -n "${SUB_HOST:-}" ] && [ "$SUB_HOST" != "$PUBLIC_IP" ]; then DOMAIN="$SUB_HOST"; fi
  [ -n "${PANEL_PATH:-}" ] || return 0

  local yaml="$WWW$SUB_PATH" panel="$WWW$PANEL_PATH" key value cli
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    eval "cli=\${_CLI_$key:-}"
    state_has_key "$key" && continue
    [ -n "$cli" ] && continue
    case "$key" in
      AIRPORT_NAME|NODE_ADDR|HY2_PORT|ANYTLS_PORT|SS_PORT|SS_METHOD|TLS_SNI)
        [ -n "$value" ] && printf -v "$key" '%s' "$value"
        ;;
    esac
  done < <("$PY" - "$yaml" "$panel" <<'PY' 2>/dev/null || true
import html
import re
import sys
from pathlib import Path

yaml_path, panel_path = map(Path, sys.argv[1:])
if yaml_path.exists():
    text = yaml_path.read_text(encoding="utf-8", errors="ignore")
    blocks = {}
    for m in re.finditer(r'^  - name:\s*["\']?([^"\'\n]+)["\']?\s*\n(.*?)(?=^  - name:|^proxy-groups:)', text, re.M | re.S):
        fields = dict(re.findall(r'^\s{4}([A-Za-z0-9_-]+):\s*["\']?([^"\'\n]+)', m.group(2), re.M))
        blocks[m.group(1).strip()] = fields
    direct = next((blocks.get(n, {}).get("server", "") for n in ("Hysteria2", "AnyTLS", "SS2022") if blocks.get(n, {}).get("server")), "")
    values = {
        "NODE_ADDR": direct,
        "HY2_PORT": blocks.get("Hysteria2", {}).get("port", ""),
        "ANYTLS_PORT": blocks.get("AnyTLS", {}).get("port", ""),
        "SS_PORT": blocks.get("SS2022", {}).get("port", ""),
        "SS_METHOD": blocks.get("SS2022", {}).get("cipher", ""),
        "TLS_SNI": blocks.get("Hysteria2", {}).get("sni", "") or blocks.get("AnyTLS", {}).get("sni", ""),
    }
    for key, value in values.items():
        if value:
            print(f"{key}={value.strip()}")
if panel_path.exists():
    text = panel_path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"<title>(.*?)</title>", text, re.S)
    if m:
        title = html.unescape(m.group(1)).strip().rsplit(" ", 1)[0]
        if title:
            print(f"AIRPORT_NAME={title}")
PY
  )
  case "$PUBLIC_IP" in *:*) IS_IPV6=1 ;; *) IS_IPV6=0 ;; esac
}

ver_ge() { # ver_ge A B  -> A >= B ?
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# 装前输入校验(端口/SNI/域名/到期时间), 不合法立即报错, 避免装到一半才崩
validate_inputs() {
  local p
  for p in "$HY2_PORT" "$ANYTLS_PORT" "$SS_PORT"; do
    case "$p" in ''|*[!0-9]*) die "端口必须是数字: '$p'";; esac
    { [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || die "端口超出范围 1-65535: '$p'"
  done
  # 三个入站端口保持互不相同: HY2 虽然走 UDP, 与 TCP 端口理论可共存, 但同号会让
  # 客户端/防火墙/排障全部变得难以区分, 直接拒绝更省事。
  [ "$HY2_PORT" != "$ANYTLS_PORT" ] && [ "$HY2_PORT" != "$SS_PORT" ] && [ "$ANYTLS_PORT" != "$SS_PORT" ] \
    || die "HY2_PORT/ANYTLS_PORT/SS_PORT 必须互不相同(当前: $HY2_PORT/$ANYTLS_PORT/$SS_PORT)"
  case "$TLS_SNI" in ''|*[!A-Za-z0-9.-]*) die "TLS_SNI 含非法字符: '$TLS_SNI'";; esac
  [ -z "$DOMAIN" ] || case "$DOMAIN" in *[!A-Za-z0-9.-]*) die "DOMAIN 含非法字符: '$DOMAIN'";; esac
  case "$SUB_TLS" in auto|0|1) ;; *) die "SUB_TLS 只能是 auto / 1 / 0: '$SUB_TLS'";; esac
  # SUB_TLS=1 是"强制 HTTPS": 缺域名或证书就直接在开头报错, 不要等 nginx 配到一半才失败。
  if [ "$SUB_TLS" = 1 ]; then
    [ -n "$DOMAIN" ] || die "SUB_TLS=1 需要 DOMAIN=你的订阅域名(证书必须与域名匹配)"
    { [ -f "$(sub_cert_file)" ] && [ -f "$(sub_key_file)" ]; } \
      || die "SUB_TLS=1 但证书缺失: $(sub_cert_file) / $(sub_key_file)(先放 fullchain 与私钥)"
  fi
  # 订阅 HTTPS 会独占 443/tcp; AnyTLS/SS 也是 TCP 入站, 同端口会让 nginx -t 或 sing-box 启动失败。
  if subscription_tls_enabled || { [ "$SUB_TLS" = 1 ] && [ -n "$DOMAIN" ]; }; then
    [ "$ANYTLS_PORT" != 443 ] || die "启用订阅 HTTPS 时 443/tcp 归 nginx, ANYTLS_PORT 不能是 443"
    [ "$SS_PORT" != 443 ]    || die "启用订阅 HTTPS 时 443/tcp 归 nginx, SS_PORT 不能是 443"
  fi
  # 这些值会原样写进 /etc/sing-box-node.env; 不校验会让下一次 load_node_env 直接拒绝自己的文件,
  # 或者让 traffic_limit.py 每次 cron 都崩。
  [[ "$LIMIT_GB" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || die "LIMIT_GB 要是数字(如 200 或 0.5): '$LIMIT_GB'"
  case "$COUNT_MODE" in rx+tx|tx|max) ;; *) die "COUNT_MODE 只能 rx+tx / tx / max: '$COUNT_MODE'";; esac
  case "$AIRPORT_NAME" in
    ''|*$'\n'*|*$'\r'*|*'"'*|*"'"*|*\\*)
      die "AIRPORT_NAME 不能为空, 且不能含换行/引号/反斜杠: '$AIRPORT_NAME'" ;;
  esac
  if [ -n "${EXPIRE_AT:-}" ]; then
    [[ "$EXPIRE_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] \
      || die "EXPIRE_AT 格式必须是 'YYYY-MM-DD HH:MM:SS +0800'(含四位时区偏移, 不能是 +08:00 或省略), 当前: '$EXPIRE_AT'"
  fi
  [ -z "$OBFS_PASSWORD" ] || case "$OBFS_PASSWORD" in *[!A-Za-z0-9]*) die "OBFS_PASSWORD 只能含字母数字: '$OBFS_PASSWORD'";; esac
  # 自定义订阅证书路径: 固定在 /etc/sing-box/ 下, 保证 backup/restore 的 tar 白名单
  # 能覆盖到(否则自定义路径的证书既不会被备份, restore 时还可能误删目标文件)。
  local _cert
  for _cert in "$SUB_CERT" "$SUB_KEY"; do
    [ -z "$_cert" ] && continue
    case "$_cert" in
      /etc/sing-box/*) [[ "$_cert" != *..* && "$_cert" =~ ^/etc/sing-box/[A-Za-z0-9._/-]+$ ]] || die "证书路径非法(只允许 /etc/sing-box/ 下的常见文件名字符, 不能含 ..): '$_cert'" ;;
      *) die "证书路径必须位于 /etc/sing-box/ 下: '$_cert'" ;;
    esac
  done
  # SS_METHOD 会裸插进 Clash YAML 的 cipher: 与 ss:// 链接; 含引号或 ": " 会让整份订阅 YAML 解析失败
  # (三条节点全拉不到, 不只是 SS 那条)。用字符白名单而非枚举, 以免误杀传统 cipher。
  case "$SS_METHOD" in ''|*[!A-Za-z0-9-]*) die "SS_METHOD 只能含 字母/数字/连字符: '$SS_METHOD'";; esac
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
      local apt_packages=(curl wget tar jq nginx vnstat openssl cron python3 iproute2 ca-certificates qrencode)
      [ "$ENABLE_UFW" = 1 ] && apt_packages+=(ufw)
      apt-get install -y "${apt_packages[@]}"
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
  timedatectl set-ntp true >/dev/null 2>&1 || warn "无法自动开启 NTP, 请确认系统时间准确(TLS 握手对时钟敏感)"
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = no ]; then
    note "系统时间尚未同步(NTPSynchronized=no): TLS 握手可能失败(连得上但代理不通)。稍等几分钟或手动核对 timedatectl。"
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
    note "sing-box 版本 ${SB_VER:-未知} < 1.12.0, 不支持 AnyTLS: 已自动跳过 AnyTLS, 部署 Hysteria2 + SS2022。升级 sing-box 后重跑本脚本即可补上 AnyTLS。"
    warn "sing-box ${SB_VER:-未知} 过旧, 跳过 AnyTLS"
  fi
  ok "sing-box 版本: ${SB_VER:-unknown} (AnyTLS: $([ "$ANYTLS_OK" = 1 ] && echo 启用 || echo 跳过))"
}

detect_net() {
  PUBLIC_IP="${PUBLIC_IP:-}"
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(curl -fsSL4 --max-time 8 https://api.ipify.org   2>/dev/null || true)"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(curl -fsSL4 --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    # || true 必须留着: 纯 IPv6 机器上 ip -4 route get 会失败, pipefail 会把非零传出来,
    # set -e 就在这里静默退出, 走不到下面那句友好的 die 提示。
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    # 纯 IPv6 机器上面三步都会空手而归, 再试 IPv6; 否则脚本只能靠用户手传 PUBLIC_IP
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(curl -fsSL6 --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  if [ -z "$PUBLIC_IP" ]; then
    # SOFT_DETECT=1(info 用)时探测失败不致命, 用占位符; 安装时仍直接报错
    [ "${SOFT_DETECT:-0}" = 1 ] && PUBLIC_IP="<未探测到IP>" || die "无法探测公网 IP, 请用 PUBLIC_IP=x.x.x.x 重新运行"
  fi
  INTERFACE="${INTERFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)}"
  # 纯 IPv6 机器 IPv4 探测会失败, 再用 IPv6 兜底; 否则网卡被误写成 eth0 会让 vnstat 取不到数据、限流首次报错
  [ -z "$INTERFACE" ] && INTERFACE="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  INTERFACE="${INTERFACE:-eth0}"
  SUB_HOST="${DOMAIN:-$PUBLIC_IP}"
  # 纯 IPv6 机: 客户端要走 AAAA/IPv6, 订阅必须 ipv6: true, 分流规则要用 IP-CIDR6/128,
  # 分享链接里的地址还得加方括号。这里统一判定一次, 供各渲染函数取用。
  case "$PUBLIC_IP" in *:*) IS_IPV6=1 ;; *) IS_IPV6=0 ;; esac
  # 节点连接地址: 默认用探测到的 IP; 纯 IPv6 机建议传 NODE_ADDR=你的域名(已配 AAAA),
  # 因为不少客户端对 IPv6 字面量支持不好, 用域名更稳。
  NODE_ADDR="${NODE_ADDR:-$PUBLIC_IP}"
  if [ "$IS_IPV6" = 1 ] && [ "$NODE_ADDR" = "$PUBLIC_IP" ]; then
    note "检测到纯 IPv6 出口($PUBLIC_IP): 订阅已开 ipv6。IPv4-only 的客户端连不到本机, 建议配好 AAAA 后用 NODE_ADDR=你的域名 重跑; 需要 IPv4 入口请另建 Cloudflare WebSocket 节点(现网口径不再提供一键 CF-VLESS)。"
  fi
  ok "公网 IP: $PUBLIC_IP   网卡: $INTERFACE"
  [ -n "$DOMAIN" ] && note "订阅域名 $DOMAIN: 请确认已把它的 DNS A 记录解析到 $PUBLIC_IP(本脚本无法替你改 DNS)。"
  return 0
}

# URL authority / HTTP Host 中的 IPv6 字面量必须带方括号；SUB_HOST 本身仍保存原始 IP 或域名，
# 避免把方括号误写进 DNS/地址判断。Nginx 的 server_name 也要和标准 Host 值一致。
url_host() {
  local host="${1:-}"
  case "$host" in
    \[*\]) printf '%s' "$host" ;;
    *:*)   printf '[%s]' "$host" ;;
    *)     printf '%s' "$host" ;;
  esac
}

# 节点连接地址只能是 IPv4、IPv6 字面量或普通 DNS 名。渲染前统一校验，避免维护命令
# 误把 shell 分隔符/占位符写进全部订阅，导致服务端正常但客户端导入后三条直连节点全坏。
valid_node_address() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  "$PY" - "$value" <<'PY' >/dev/null 2>&1
import ipaddress
import re
import sys

value = sys.argv[1]
try:
    ipaddress.ip_address(value)
except ValueError:
    if (len(value) > 253 or not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", value)):
        raise SystemExit(1)
PY
}

require_node_address() {
  local value="${NODE_ADDR:-${PUBLIC_IP:-}}"
  valid_node_address "$value" || { err "节点连接地址非法，拒绝生成订阅: '${value:-空}'"; return 1; }
}

sub_cert_file() { printf '%s' "${SUB_CERT:-$SB_DIR/sub.crt}"; }
sub_key_file()  { printf '%s' "${SUB_KEY:-$SB_DIR/sub.key}"; }

# 订阅是否走 443 HTTPS: 必须有域名 + 证书。auto=两者齐备才开; 1=强制(缺证书时
# config_nginx 会直接报错, 不会留下一个打不开的 https:// 链接); 0=永远 HTTP。
subscription_tls_enabled() {
  [ "$SUB_TLS" != 0 ] || return 1
  [ -n "$DOMAIN" ] || return 1
  [ -f "$(sub_cert_file)" ] && [ -f "$(sub_key_file)" ]
}

subscription_url() {
  local path="${1:-$SUB_PATH}" scheme=http
  subscription_tls_enabled && scheme=https
  printf '%s://%s%s' "$scheme" "$(url_host "$SUB_HOST")" "$path"
}

# SS2022 密钥: base64, 长度按方法自适应(128-gcm=16字节, 256/chacha=32字节)
# 当前 SS_METHOD 要求的密钥字节数(128-gcm=16, 256-gcm/chacha20=32)
ss_need_bytes() {
  case "$SS_METHOD" in *aes-256*|*chacha*) printf 32 ;; *) printf 16 ;; esac
}

# 已有 base64 密钥解码后的实际字节数(解不出来返回 0, 触发重新生成)
# -A 不能省: 密钥是单行无换行的, 不加 -A 的 openssl base64 -d 会解出 0 字节,
# 那样每次重跑都会误判成"长度不符"并重新生成密钥, 把客户端全踢下线。
ss_key_bytes() {
  printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' \n' || printf 0
}

gen_ss_password() {
  openssl rand -base64 "$(ss_need_bytes)" | tr -d '\n'
}

# 这些文件由 root 持久化后会在后续管理命令和 restore 中重新读取。不能 source：备份或被篡改的
# KEY=VALUE 文件会变成 root shell。只接受本脚本会写出的键和值格式，并按字面量赋值。
valid_state_value() {
  local key="$1" value="$2"
  case "$key" in
    HY2_PASSWORD|ANYTLS_PASSWORD|OBFS_PASSWORD|REALITY_SHORT_ID)
      [[ -z "$value" || "$value" =~ ^[A-Za-z0-9]+$ ]]
      ;;
    VLESS_UUID|CF_VLESS_UUID)
      [[ "$value" =~ ^[0-9A-Fa-f-]{36}$ ]]
      ;;
    REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|WARP_PRIVATE_KEY)
      [[ "$value" =~ ^[A-Za-z0-9+/=_-]+$ ]]
      ;;
    SS_PASSWORD)
      [[ -z "$value" || "$value" =~ ^[A-Za-z0-9+/=_-]+$ ]]
      ;;
    SUB_PATH|SUB_B64_PATH|PANEL_PATH)
      [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ && "$value" != *..* ]]
      ;;
    LIMIT_GB)
      [[ "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
      ;;
    EXPIRE_AT)
      [[ -z "$value" || "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]]
      ;;
    INTERFACE)
      [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]
      ;;
    COUNT_MODE)
      case "$value" in rx+tx|tx|max) return 0 ;; esac; return 1
      ;;
    SUB_HOST|NODE_ADDR)
      [[ "$value" =~ ^[A-Za-z0-9:.-]+$ ]]
      ;;
    DOMAIN)
      [[ -z "$value" || "$value" =~ ^[A-Za-z0-9.-]+$ ]]
      ;;
    PUBLIC_IP)
      [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]]
      ;;
    HY2_HOP_RANGE)
      [[ -z "$value" || "$value" =~ ^[0-9]+-[0-9]+$ ]]
      ;;
    # 旧版 env 可能仍带 VLESS_PORT/HY2_HOP_RANGE/HY2_* 带宽键: 读取时接受(否则升级会
    # 直接报"未识别键"), 但 write_env 不再写回, 值也不会进入渲染 —— 等于自动迁移。
    HY2_PORT|ANYTLS_PORT|VLESS_PORT|SS_PORT|HY2_UP|HY2_DOWN|HY2_UP_MBPS|HY2_DOWN_MBPS|CF_PORT|ADMIN_PORT)
      [[ -z "$value" || "$value" =~ ^[0-9]+$ ]]
      ;;
    SUB_TLS)
      case "$value" in auto|0|1) return 0 ;; esac; return 1
      ;;
    SUB_CERT|SUB_KEY)
      case "$value" in
        '') return 0 ;;
        /etc/sing-box/*) [[ "$value" != *..* && "$value" =~ ^/etc/sing-box/[A-Za-z0-9._/-]+$ ]] && return 0; return 1 ;;
        *) return 1 ;;
      esac
      ;;
    ENABLE_BLOCK_BT|ENABLE_BLOCK_ADS|ENABLE_HY2|ENABLE_OBFS|SS_UDP|CF_VERIFIED)
      [[ "$value" = 0 || "$value" = 1 ]]
      ;;
    AIRPORT_NAME)
      [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *"\""* && "$value" != *"'"* && "$value" != *\\* ]]
      ;;
    SS_METHOD|REALITY_SNI|TLS_SNI)
      [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]
      ;;
    CF_HOSTNAME)
      [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]
      ;;
    CF_NAME)
      [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
      ;;
    CF_WS_PATH)
      [[ "$value" =~ ^/[A-Za-z0-9/_.-]*$ ]]
      ;;
    WARP_ADDR_V4)
      [[ "$value" =~ ^[0-9.]+/[0-9]+$ ]]
      ;;
    WARP_ADDR_V6)
      [[ "$value" =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]]
      ;;
    WARP_RESERVED)
      [[ -z "$value" || "$value" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]]
      ;;
    WARP_SITES)
      [[ "$value" =~ ^[a-z0-9,-]+$ ]]
      ;;
    ADMIN_TOKEN)
      [[ "$value" =~ ^[0-9A-Fa-f]+$ ]]
      ;;
    *)
      return 1
      ;;
  esac
}

load_state_file() {
  local file="$1" line key value
  shift
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || { err "状态文件格式非法: $file"; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case " $* " in *" $key "*) ;; *) err "状态文件含未识别键 $key: $file"; return 1 ;; esac
    if [[ "$value" == \"* ]]; then
      [ "${#value}" -ge 2 ] && [ "${value: -1}" = '"' ] || { err "状态文件引号不完整: $file"; return 1; }
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'* ]]; then
      [ "${#value}" -ge 2 ] && [ "${value: -1}" = "'" ] || { err "状态文件引号不完整: $file"; return 1; }
      value="${value:1:${#value}-2}"
    elif [[ "$value" == *\"* || "$value" == *\'* ]]; then
      err "状态文件含不支持的引号: $file"
      return 1
    fi
    valid_state_value "$key" "$value" || { err "状态文件中 $key 的值非法: $file"; return 1; }
    printf -v "$key" '%s' "$value"
  done <"$file"
}

load_secrets() {
  # 旧版 secrets 里的 VLESS_UUID/REALITY_* 仍接受(否则升级直接报错), 但读完即丢弃。
  load_state_file "$SECRETS" HY2_PASSWORD ANYTLS_PASSWORD VLESS_UUID REALITY_PRIVATE_KEY \
    REALITY_PUBLIC_KEY REALITY_SHORT_ID SUB_PATH SUB_B64_PATH PANEL_PATH SS_PASSWORD OBFS_PASSWORD
  VLESS_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""
}

load_node_env() {
  load_state_file "$ENVFILE" LIMIT_GB EXPIRE_AT INTERFACE COUNT_MODE SUB_HOST PUBLIC_IP DOMAIN AIRPORT_NAME NODE_ADDR \
    HY2_PORT ANYTLS_PORT VLESS_PORT SS_PORT SS_METHOD REALITY_SNI TLS_SNI SUB_TLS SUB_CERT SUB_KEY HY2_HOP_RANGE \
    HY2_UP HY2_DOWN HY2_UP_MBPS HY2_DOWN_MBPS ENABLE_BLOCK_BT ENABLE_BLOCK_ADS ENABLE_HY2 ENABLE_OBFS SS_UDP
  # 迁移: 旧值只用于兼容读取, 不参与渲染/写回。
  VLESS_PORT=""; REALITY_SNI=""; HY2_HOP_RANGE=""; HY2_UP=""; HY2_DOWN=""; HY2_UP_MBPS=""; HY2_DOWN_MBPS=""
}

load_cf_env() {
  load_state_file "$CF_ENV" CF_HOSTNAME CF_PORT CF_VLESS_UUID CF_WS_PATH CF_VERIFIED CF_NAME
}

load_warp_env() {
  load_state_file "$WARP_ENV" WARP_PRIVATE_KEY WARP_ADDR_V4 WARP_ADDR_V6 WARP_RESERVED WARP_SITES
}

load_admin_env() {
  load_state_file "$ADMIN_ENV" ADMIN_TOKEN ADMIN_PORT
}

gen_secrets() {
  mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR" 2>/dev/null || true   # 目录对非 root 封闭
  if [ -f "$SECRETS" ]; then
    log "检测到已有密钥, 复用(不破坏现有客户端)"
    load_secrets || die "密钥文件格式非法, 为保护现有节点拒绝继续: $SECRETS"
    if [ -z "${SS_PASSWORD:-}" ]; then   # 旧版安装无 SS2022 密钥, 升级时补一个(不影响其它节点)
      SS_PASSWORD="$(gen_ss_password)"
      log "已为升级补充 SS2022 密钥"
    fi
    # ENABLE_OBFS=0 要能在已装机器上真的关掉 obfs。渲染只看 OBFS_PASSWORD 是否为空,
    # 而复用分支以前从不清它, 于是"装过一次就永远关不掉"(清洗敏感机想减少 UDP 特征时会踩)。
    if [ "$ENABLE_OBFS" != 1 ] && [ -n "${OBFS_PASSWORD:-}" ]; then
      OBFS_PASSWORD=""
      warn "ENABLE_OBFS=0: 已关闭 HY2 salamander 混淆(清除 OBFS_PASSWORD)"
      note "HY2 混淆已关闭, 客户端需重新拉取订阅, 否则仍按旧的 obfs 参数连接会失败。"
    fi
    if [ -n "${SS_PASSWORD:-}" ] && [ "$(ss_key_bytes "$SS_PASSWORD")" != "$(ss_need_bytes)" ]; then
      # SS2022 的密钥长度和加密方法强绑定(128-gcm=16 字节, 256-gcm/chacha=32 字节)。
      # 用户改了 SS_METHOD 重跑时, 旧密钥长度对不上会让 sing-box check 直接失败,
      # 这里按新方法重新生成一条并覆盖写回, 只影响 SS2022 一条节点。
      SS_PASSWORD="$(gen_ss_password)"
      warn "SS_METHOD 改为 $SS_METHOD, 密钥长度需随之变化: 已重新生成 SS2022 密钥"
      note "SS2022 密钥已因加密方法变更而更新, 请重新拉取订阅(其它协议不受影响)。"
    fi
    if [ -z "${SUB_B64_PATH:-}" ]; then  # 旧版无通用订阅路径, 升级时补一个
      SUB_B64_PATH="/sub-b64-$(openssl rand -hex 8).txt"
    fi
    if [ -z "${PANEL_PATH:-}" ]; then    # 旧版无看板页, 升级时补一个
      PANEL_PATH="/panel-$(openssl rand -hex 8).html"
    fi
    if [ -z "${OBFS_PASSWORD:-}" ] && [ "$ENABLE_OBFS" = 1 ]; then  # 升级开启 HY2 obfs
      OBFS_PASSWORD="$(openssl rand -hex 12)"
      log "已为升级补充 HY2 obfs 密码"
    fi
    write_secrets || die "更新密钥文件失败，已保留旧文件: $SECRETS"
    return
  fi
  log "生成密钥与随机参数..."
  HY2_PASSWORD="$(openssl rand -hex 16)"
  ANYTLS_PASSWORD="$(openssl rand -hex 16)"
  SUB_PATH="/sub-$(openssl rand -hex 8).yaml"
  SUB_B64_PATH="/sub-b64-$(openssl rand -hex 8).txt"
  PANEL_PATH="/panel-$(openssl rand -hex 8).html"
  SS_PASSWORD="$(gen_ss_password)"
  [ "$ENABLE_OBFS" = 1 ] && OBFS_PASSWORD="$(openssl rand -hex 12)"
  write_secrets || die "写入密钥文件失败: $SECRETS"
  ok "密钥已生成并保存到 $SECRETS (600)"
}

write_secrets() {
  atomic_write_file "$SECRETS" 600 <<EOF
HY2_PASSWORD=$HY2_PASSWORD
ANYTLS_PASSWORD=$ANYTLS_PASSWORD
SUB_PATH=$SUB_PATH
SUB_B64_PATH=$SUB_B64_PATH
PANEL_PATH=$PANEL_PATH
SS_PASSWORD="$SS_PASSWORD"
OBFS_PASSWORD=$OBFS_PASSWORD
EOF
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

# 重装保参数: 已有 $ENVFILE 时, 把文件里的运行参数当默认值沿用;
# 本次显式传入的 env(_CLI_* 非空)优先级更高, 仍然覆盖文件值。
# 不这样做的话, 二次运行 install 会把 LIMIT_GB 打回 200、EXPIRE_AT 顺延成"安装日+365天"。
merge_env_defaults() {
  [ -f "$ENVFILE" ] || return 0
  local restoring="${1:-0}" v cli current_public="$PUBLIC_IP" current_host="$SUB_HOST" current_interface="$INTERFACE" current_node="$NODE_ADDR" current_domain="$DOMAIN"
  load_node_env || die "运行参数文件格式非法, 为保护现有节点拒绝继续: $ENVFILE"
  # 常规重装沿用原来的订阅 Host/IP 行为；只有跨机 restore 才必须保留新机探测结果，
  # 不能让备份机器的 IP、订阅 Host 或网卡覆盖新机。
  if [ "$restoring" = 1 ]; then
    PUBLIC_IP="$current_public"; SUB_HOST="$current_host"; INTERFACE="$current_interface"
    DOMAIN="$current_domain"; NODE_ADDR="${current_node:-$current_public}"
  fi
  # 一次性迁移: 2026-10 基线把 HY2 入口统一到 UDP 443。旧版默认 4433 的机器在重装时
  # 自动跟到 443; 显式传 HY2_PORT=4433(或其它端口) 的用户保持自己的选择。
  if [ -z "${_CLI_HY2_PORT:-}" ] && [ "${HY2_PORT:-}" = 4433 ]; then
    HY2_PORT=443
    note "HY2 端口已按 2026-10 基线从 4433 迁移到 UDP 443: 记得在云安全组放行 443/udp(旧 4433 可移除), 并让客户端重新拉订阅。"
  fi
  for v in LIMIT_GB COUNT_MODE EXPIRE_AT INTERFACE DOMAIN AIRPORT_NAME NODE_ADDR \
            HY2_PORT ANYTLS_PORT SS_PORT SS_METHOD TLS_SNI SUB_TLS SUB_CERT SUB_KEY \
            ENABLE_BLOCK_BT ENABLE_BLOCK_ADS ENABLE_HY2 ENABLE_OBFS SS_UDP; do
    eval "cli=\"\${_CLI_$v:-}\""
    [ -n "$cli" ] && printf -v "$v" '%s' "$cli"  # 本次显式传的赢回来
  done
  log "检测到已有运行参数, 沿用(LIMIT_GB=$LIMIT_GB, EXPIRE_AT=${EXPIRE_AT:-未设})"
  return 0
}

write_env() {
  # 不再捏造"安装日+365天": 那个假到期日会让客户端在一年后显示"订阅已过期"、
  # 而限流脚本到期并不停机(节点其实还在跑), 把排查方向带偏; merge_env_defaults 还会一路沿用它。
  # 留空 -> 流量头 expire=0, 客户端普遍视为"无到期", 比一个编出来的日期诚实。
  EXPIRE_VALUE="${EXPIRE_AT:-}"   # 单一来源, config_nginx 复用, 不再二次 grep
  [ -n "$EXPIRE_VALUE" ] || note "未设置 EXPIRE_AT: 订阅不显示到期(expire=0)。要显示续费日请用: bash install.sh set EXPIRE_AT='2026-12-31 23:59:59 +0800'"
  # 空网卡名会让写出的 env 反过来过不了 valid_state_value(INTERFACE 不允许空),
  # 下次 load_node_env 直接报“格式非法”。统一回退 eth0, 与 traffic_limit.py 的默认一致。
  INTERFACE="${INTERFACE:-eth0}"
  atomic_write_file "$ENVFILE" 600 <<EOF || die "写入运行参数失败，已保留旧文件: $ENVFILE"
# 由 install.sh 生成 —— 运行参数单一来源
LIMIT_GB=$LIMIT_GB
EXPIRE_AT="$EXPIRE_VALUE"
INTERFACE=$INTERFACE
COUNT_MODE=$COUNT_MODE
SUB_HOST="$SUB_HOST"
PUBLIC_IP="$PUBLIC_IP"
DOMAIN="$DOMAIN"
AIRPORT_NAME="$AIRPORT_NAME"
NODE_ADDR="$NODE_ADDR"
HY2_PORT=$HY2_PORT
ANYTLS_PORT=$ANYTLS_PORT
SS_PORT=$SS_PORT
SS_METHOD=$SS_METHOD
TLS_SNI=$TLS_SNI
SUB_TLS=$SUB_TLS
SUB_CERT=$SUB_CERT
SUB_KEY=$SUB_KEY
ENABLE_BLOCK_BT=$ENABLE_BLOCK_BT
ENABLE_BLOCK_ADS=$ENABLE_BLOCK_ADS
ENABLE_HY2=$ENABLE_HY2
ENABLE_OBFS=$ENABLE_OBFS
SS_UDP=$SS_UDP
EOF
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
  local obfs_line=""
  [ -n "$OBFS_PASSWORD" ] && obfs_line=$'\n      "obfs": { "type": "salamander", "password": "'"$OBFS_PASSWORD"'" },'
  # HY2 不再写 up_mbps/down_mbps: 统一使用自动拥塞控制(2026-10 现网口径)。
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
      # WARP_SITES 可配置(逗号分隔的 geosite 名), 默认覆盖 OpenAI/Claude/Gemini/流媒体
      local site tags=""
      for site in $(printf '%s' "${WARP_SITES:-$WARP_DEFAULT_SITES}" | tr ',' ' '); do
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
  # SS_UDP=0(TCP-only 稳定版): 服务端也要真的不收 UDP, 否则只改订阅等于"客户端不走、端口还开着"
  local ss_net_line=""
  [ "$SS_UDP" = 1 ] || ss_net_line='
      "network": "tcp",'
  local hy2_block=""
  if [ "$ENABLE_HY2" = 1 ]; then
    hy2_block="$(cat <<JSON
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASSWORD" } ],$obfs_line
      "tls": { "enabled": true, "certificate_path": "$SB_DIR/server.crt", "key_path": "$SB_DIR/server.key" }
    },
JSON
)"
  fi
  cat <<JSON
{
  "log": { "disabled": false, "level": "warn" },
  "inbounds": [
$hy2_block
$anytls_block
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $SS_PORT,$ss_net_line
      "method": "$SS_METHOD",
      "password": "$SS_PASSWORD"
    }
  ],$route_json
  "outbounds": [ { "type": "direct", "tag": "direct" } ]$warp_ep
}
JSON
}

render_subscription_yaml() {
  require_node_address || return 1
  ANYTLS_OK="$ANYTLS_OK" PUBLIC_IP="$PUBLIC_IP" DOMAIN="$DOMAIN" \
  HY2_PORT="$HY2_PORT" ANYTLS_PORT="$ANYTLS_PORT" \
  HY2_PASSWORD="$HY2_PASSWORD" ANYTLS_PASSWORD="$ANYTLS_PASSWORD" \
  TLS_SNI="$TLS_SNI" \
  SS_PORT="$SS_PORT" SS_METHOD="$SS_METHOD" SS_PASSWORD="$SS_PASSWORD" \
  OBFS_PASSWORD="$OBFS_PASSWORD" \
  ENABLE_HY2="$ENABLE_HY2" SS_UDP="$SS_UDP" \
  IS_IPV6="$IS_IPV6" NODE_ADDR="$NODE_ADDR" \
  "$PY" - <<'PY'
import os
ip  = os.environ.get("NODE_ADDR") or os.environ["PUBLIC_IP"]   # 节点连接地址(纯 IPv6 机可传域名)
v6  = os.environ.get("IS_IPV6", "0") == "1"
anytls = os.environ["ANYTLS_OK"] == "1"
hy2_on = os.environ.get("ENABLE_HY2", "1") == "1"
ss_udp = "true" if os.environ.get("SS_UDP", "1") == "1" else "false"

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
if os.environ.get("OBFS_PASSWORD", ""):
    hy2.append('    obfs: salamander')
    hy2.append(f'    obfs-password: {os.environ["OBFS_PASSWORD"]}')
hy2 += ['    alpn:', '      - h3']
if hy2_on:
    proxies.append("\n".join(hy2))
if anytls:
    proxies.append(f'''  - name: "AnyTLS"
    type: anytls
    server: {ip}
    port: {os.environ["ANYTLS_PORT"]}
    password: {os.environ["ANYTLS_PASSWORD"]}
    sni: {os.environ["TLS_SNI"]}
    skip-cert-verify: true
    udp: true
    client-fingerprint: chrome''')
proxies.append(f'''  - name: "SS2022"
    type: ss
    server: {ip}
    port: {os.environ["SS_PORT"]}
    cipher: {os.environ["SS_METHOD"]}
    password: "{os.environ["SS_PASSWORD"]}"
    udp: {ss_udp}''')

names = (["Hysteria2"] if hy2_on else []) + (["AnyTLS"] if anytls else []) + ["SS2022"]
grp = "\n".join(f'      - "{n}"' for n in names)

# 分流基线(2026-10 现网口径): 只引用 MetaCubeX/meta-rules-dat 的 meta 分支,
# 不再维护手写域名/IP 规则。6 个 provider + 固定 7 条规则:
# 私有 -> 广告 REJECT -> Google(含 Play/GMS)走代理 -> 中国直连 -> MATCH。
# meta-google 必须早于 meta-cn-domain, 否则 googleapis.cn 会先命中 cn 导致 Play 卡 99%。
providers = '''rule-providers:
  meta-private-domain:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs
    path: ./ruleset/meta-private-domain.mrs
  meta-private-ip:
    type: http
    behavior: ipcidr
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/private.mrs
    path: ./ruleset/meta-private-ip.mrs
  meta-ads:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ads-all.mrs
    path: ./ruleset/meta-ads.mrs
  meta-google:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/google.mrs
    path: ./ruleset/meta-google.mrs
  meta-cn-domain:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs
    path: ./ruleset/meta-cn-domain.mrs
  meta-cn-ip:
    type: http
    behavior: ipcidr
    format: mrs
    interval: 86400
    proxy: "🚀 节点选择"
    url: https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs
    path: ./ruleset/meta-cn-ip.mrs'''

rules = [
    "  - RULE-SET,meta-private-domain,DIRECT",
    "  - RULE-SET,meta-private-ip,DIRECT,no-resolve",
    "  - RULE-SET,meta-ads,REJECT",
    "  - RULE-SET,meta-google,🚀 节点选择",
    "  - RULE-SET,meta-cn-domain,DIRECT",
    "  - RULE-SET,meta-cn-ip,DIRECT,no-resolve",
    "  - MATCH,🚀 节点选择",
]

# 订阅 DNS: 节点域名用国内 DoH 专用解析(proxy-server-nameserver), 不依赖境外 fallback;
# fallback 必须为空数组 —— 境外 DoH 不可达时会稳定复现 5 秒解析超时(2026-10-16 实测)。
dns = f'''dns:
  enable: true
  ipv6: {"true" if v6 else "false"}
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  fallback: []
  fallback-filter:
    geoip: true
    geoip-code: CN
  nameserver-policy:
    "geosite:cn,private,apple":
      - https://doh.pub/dns-query
      - https://dns.alidns.com/dns-query
    "geosite:category-ads-all": rcode://success'''

doc = f'''mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
ipv6: {"true" if v6 else "false"}
tcp-concurrent: true

{dns}

proxies:
{chr(10).join(proxies)}

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
{grp}

{providers}

rules:
{chr(10).join(rules)}
'''
import sys
sys.stdout.write(doc)
PY
}

# 各节点的分享链接(hysteria2:// anytls:// ss://), 一行一条; 通用订阅就是它的 base64
render_share_links() {
  require_node_address || return 1
  ANYTLS_OK="$ANYTLS_OK" PUBLIC_IP="$PUBLIC_IP" \
  HY2_PORT="$HY2_PORT" ANYTLS_PORT="$ANYTLS_PORT" SS_PORT="$SS_PORT" \
  HY2_PASSWORD="$HY2_PASSWORD" ANYTLS_PASSWORD="$ANYTLS_PASSWORD" \
  SS_METHOD="$SS_METHOD" SS_PASSWORD="$SS_PASSWORD" \
  TLS_SNI="$TLS_SNI" \
  OBFS_PASSWORD="$OBFS_PASSWORD" \
  ENABLE_HY2="$ENABLE_HY2" \
  IS_IPV6="$IS_IPV6" NODE_ADDR="$NODE_ADDR" \
  "$PY" - <<'PY'
import os, urllib.parse as u
def q(s): return u.quote(str(s), safe='')
ip  = os.environ.get("NODE_ADDR") or os.environ["PUBLIC_IP"]
# URI 里的 IPv6 字面量必须加方括号(RFC 3986), 否则 host:port 会被解析错, 所有分享链接失效
if ":" in ip and not ip.startswith("["):
    ip = f"[{ip}]"
tls = os.environ["TLS_SNI"]
out = []
hy2q = f"insecure=1&sni={q(tls)}"
if os.environ.get("OBFS_PASSWORD", ""):
    hy2q += f"&obfs=salamander&obfs-password={q(os.environ['OBFS_PASSWORD'])}"
if os.environ.get("ENABLE_HY2", "1") == "1":
    out.append(f"hysteria2://{q(os.environ['HY2_PASSWORD'])}@{ip}:{os.environ['HY2_PORT']}/?{hy2q}#{q('Hysteria2')}")
if os.environ["ANYTLS_OK"] == "1":
    out.append(f"anytls://{q(os.environ['ANYTLS_PASSWORD'])}@{ip}:{os.environ['ANYTLS_PORT']}/?insecure=1&sni={q(tls)}#{q('AnyTLS')}")
# SS2022(SIP022): method:password(密码百分号编码), 不做 base64
out.append(f"ss://{os.environ['SS_METHOD']}:{q(os.environ['SS_PASSWORD'])}@{ip}:{os.environ['SS_PORT']}#{q('SS2022')}")
import sys
sys.stdout.write("\n".join(out) + "\n")
PY
}

# 自包含可视化看板页(只读: 看订阅/扫码/复制; 服务器管理仍走 SSH)
render_panel_html() {
  local clash_url b64_url
  clash_url="$(subscription_url "$SUB_PATH")"
  b64_url="$(subscription_url "$SUB_B64_PATH")"
  local qr_clash="" qr_b64=""
  if command -v qrencode >/dev/null 2>&1; then
    # || true: qrencode 运行时失败也只是没二维码, 不能因 set -e/pipefail 中断整个安装
    qr_clash="$(qrencode -t PNG -o - "$clash_url" 2>/dev/null | base64 -w0 || true)"
    qr_b64="$(qrencode -t PNG -o - "$b64_url" 2>/dev/null | base64 -w0 || true)"
  fi
  # 每节点分享链接 + 各自二维码(服务端 qrencode 生成); 用 \t 分隔 名字\t链接\t二维码base64, \n 分隔多节点
  # 进程替换 < <(...) 而非管道: 管道会开子shell 导致 node_data 丢失
  local node_data="" link nm qr1 links_output
  links_output="$(render_share_links)" || return 1
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    nm="${link##*#}"          # # 后是 URL 编码的节点名
    qr1=""
    command -v qrencode >/dev/null 2>&1 && qr1="$(printf '%s' "$link" | qrencode -t PNG -o - 2>/dev/null | base64 -w0 || true)"
    node_data="${node_data}${nm}"$'\t'"${link}"$'\t'"${qr1}"$'\n'
  done <<<"$links_output"
  local login_path=""; [ -s "$PANEL_MAP" ] && login_path="${PANEL_PATH%.html}-login.html"   # 开了登录才在看板显示"退出"
  AIRPORT_NAME="$AIRPORT_NAME" CLASH_URL="$clash_url" B64_URL="$b64_url" \
  QR_CLASH="$qr_clash" QR_B64="$qr_b64" NODE_DATA="$node_data" \
  LIMIT_GB="$LIMIT_GB" EXP="${EXPIRE_VALUE:-${EXPIRE_AT:-}}" PANEL_LOGIN="$login_path" \
  "$PY" - <<'PY'
import os, html, sys, urllib.parse, base64, json, datetime
e = html.escape
name_raw = os.environ.get("AIRPORT_NAME", "Node")
name = e(name_raw)
clash_raw = os.environ["CLASH_URL"]; b64_raw = os.environ["B64_URL"]
clash = e(clash_raw); b64 = e(b64_raw)
# 看板自身也走订阅同一个 server: 有 443 证书时同页就是 HTTPS, 提示不要写死“明文 HTTP”。
scheme_note = "已启用 HTTPS。" if clash_raw.startswith("https://") else "当前走明文 HTTP。仅自己用、别外传链接；不可信网络请启用 443 HTTPS（见 README）。"
# 一键导入深链: Clash 系吃 clash://install-config; Shadowrocket 吃 shadowrocket://add/sub://<base64(订阅URL)>
clash_deep = e("clash://install-config?url=" + urllib.parse.quote(clash_raw, safe="") + "&name=" + urllib.parse.quote(name_raw, safe=""))
sr_deep = e("shadowrocket://add/sub://" + base64.b64encode(b64_raw.encode()).decode())
clash_js = json.dumps(clash_raw)   # 安全的 JS 字符串字面量, 供 fetch 用
limit_gb = e(os.environ.get("LIMIT_GB", "") or "—")
login_path = os.environ.get("PANEL_LOGIN", "")   # 非空=已开登录, 显示"退出"按钮(清 cookie 回登录页)
logout_btn = '<button class="tg" onclick="lo()">退出</button>' if login_path else ''
logout_js = f"function lo(){{document.cookie='sbauth=; path=/; max-age=0; samesite=lax'+(location.protocol==='https:'?'; secure':'');document.body.style.opacity='0';setTimeout(function(){{location.replace({json.dumps(login_path)})}},220);}}" if login_path else ""
try:
    _exp = os.environ.get("EXP", "")
    exp_disp = e(datetime.datetime.strptime(_exp, "%Y-%m-%d %H:%M:%S %z").strftime("%Y-%m-%d")) if _exp else "—"
except Exception:
    exp_disp = "—"
def qr(data): return f'<div class="qrbox"><img class="qr" alt="QR" src="data:image/png;base64,{data}"></div>' if data else '<div class="qrbox"><span class="muted">(装 qrencode 可显示二维码)</span></div>'
I_BOLT = '<svg class="i" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 3 4 14h7l-1 7 9-11h-7z"/></svg>'
I_MOON = '<svg class="i" viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/></svg>'
I_WARN = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="flex:none;margin-top:1px"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg>'
# 每节点一张卡片: 名字 + 单条分享链接(复制) + 各自二维码
node_cards = []
for ln in os.environ.get("NODE_DATA", "").split("\n"):
    if not ln.strip():
        continue
    parts = ln.split("\t")
    if len(parts) < 2:
        continue
    nm_disp = e(urllib.parse.unquote(parts[0]))
    link_e = e(parts[1])
    qr1 = parts[2] if len(parts) > 2 else ""
    qr_html = f'<div class="qrbox"><img class="qr" alt="QR" src="data:image/png;base64,{qr1}"></div>' if qr1 else ''
    node_cards.append(
        f'<div class="ncard"><div class="nhd">{nm_disp}</div>'
        f'<div class="urlrow"><code>{link_e}</code><button class="cp" onclick="cpx(this)">复制</button></div>'
        f'{qr_html}</div>')
nodes_html = "\n".join(node_cards)
out = f'''<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name} 订阅</title><style>
:root{{--bg:#0b0e14;--card:#141925;--line:rgba(255,255,255,.07);--line2:rgba(255,255,255,.15);--fg:#eef1f6;--mut:#8b93a4;--acc:#818cf8;--accfg:#fff;--g:linear-gradient(135deg,#818cf8,#c084fc);color-scheme:dark light}}
*{{box-sizing:border-box}}
body{{margin:0;padding:0;min-height:100vh;background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;line-height:1.6;-webkit-font-smoothing:antialiased;transition:background .3s,color .3s,opacity .25s}}
body::before{{content:"";position:fixed;inset:0;pointer-events:none;background:radial-gradient(680px 360px at 50% -6%,rgba(129,140,248,.18),transparent 70%)}}
.wrap{{position:relative;max-width:560px;margin:0 auto;padding:30px 16px 48px}}
@keyframes rise{{from{{opacity:0;transform:translateY(14px)}}to{{opacity:1;transform:none}}}}
@keyframes pulse{{0%,100%{{opacity:1;transform:scale(1)}}50%{{opacity:.4;transform:scale(.7)}}}}
.wrap>*{{opacity:0;animation:rise .6s cubic-bezier(.2,.75,.2,1) forwards}}
.wrap>*:nth-child(1){{animation-delay:.03s}}.wrap>*:nth-child(2){{animation-delay:.08s}}.wrap>*:nth-child(3){{animation-delay:.13s}}.wrap>*:nth-child(4){{animation-delay:.18s}}.wrap>*:nth-child(5){{animation-delay:.23s}}.wrap>*:nth-child(6){{animation-delay:.28s}}.wrap>*:nth-child(7){{animation-delay:.33s}}.wrap>*:nth-child(8){{animation-delay:.38s}}.wrap>*:nth-child(n+9){{animation-delay:.43s}}
@media (prefers-reduced-motion:reduce){{.wrap>*{{animation:none;opacity:1}}.dot{{animation:none}}}}
.hd{{display:flex;align-items:center;justify-content:space-between;gap:12px}}
.nm{{display:flex;align-items:center;gap:10px}}
.dot{{width:9px;height:9px;border-radius:50%;background:var(--g);box-shadow:0 0 10px rgba(129,140,248,.85);animation:pulse 2.4s ease-in-out infinite}}
h1{{font-size:1.55rem;font-weight:600;margin:0;letter-spacing:-.02em;background:var(--g);-webkit-background-clip:text;background-clip:text;color:transparent}}
.sub{{color:var(--mut);font-size:.85rem;margin:9px 0 20px}}
.i{{vertical-align:-2px}}
.tg{{display:inline-flex;align-items:center;gap:6px;background:rgba(255,255,255,.04);border:1px solid var(--line);color:var(--fg);border-radius:999px;padding:8px 14px;font-size:.8rem;cursor:pointer;transition:background .2s,border-color .2s,transform .1s}}
.tg:hover{{background:rgba(255,255,255,.08);border-color:var(--line2)}}.tg:active{{transform:scale(.95)}}
.card{{position:relative;background:var(--card);border:1px solid var(--line);border-radius:18px;padding:19px;margin:13px 0;transition:transform .25s cubic-bezier(.2,.75,.2,1),border-color .25s,box-shadow .25s}}
.card:hover{{transform:translateY(-2px);border-color:var(--line2);box-shadow:0 14px 32px -14px rgba(0,0,0,.55)}}
.card.main{{border-color:rgba(129,140,248,.5);box-shadow:0 0 0 1px rgba(129,140,248,.12),0 18px 44px -20px rgba(129,140,248,.45)}}
.card.main:hover{{border-color:rgba(129,140,248,.7);box-shadow:0 0 0 1px rgba(129,140,248,.22),0 22px 50px -20px rgba(129,140,248,.6)}}
.ttl{{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:.96rem;font-weight:600;margin:0 0 14px}}
.tag{{font-size:.66rem;font-weight:600;letter-spacing:.03em;color:#fff;background:var(--g);border-radius:999px;padding:4px 11px;box-shadow:0 5px 14px -5px rgba(129,140,248,.8)}}
.urlrow{{display:flex;gap:8px;align-items:stretch}}
code{{flex:1;min-width:0;background:rgba(0,0,0,.3);border:1px solid var(--line);border-radius:11px;padding:10px 12px;font-size:.76rem;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--fg);word-break:break-all;overflow-wrap:anywhere}}
.cp{{flex:none;background:rgba(255,255,255,.05);border:1px solid var(--line);color:var(--fg);border-radius:11px;padding:0 16px;font-size:.82rem;cursor:pointer;transition:background .2s,border-color .2s,transform .1s}}
.cp:hover{{background:rgba(255,255,255,.11);border-color:var(--line2)}}.cp:active{{transform:scale(.93)}}
.imp{{display:flex;align-items:center;justify-content:center;gap:8px;background:var(--g);color:#fff;border:0;border-radius:13px;padding:13px;font-size:.92rem;font-weight:600;text-decoration:none;margin-top:13px;box-shadow:0 12px 28px -12px rgba(129,140,248,.8);transition:transform .15s,box-shadow .25s,filter .2s}}
.imp:hover{{transform:translateY(-1px);box-shadow:0 18px 38px -12px rgba(129,140,248,.95);filter:brightness(1.06)}}.imp:active{{transform:translateY(0) scale(.99)}}
.qrbox{{display:flex;justify-content:center;margin-top:16px}}
.qr{{background:#fff;padding:11px;border-radius:16px;width:152px;height:152px;box-shadow:0 10px 28px -12px rgba(0,0,0,.65)}}
.trow{{display:flex;gap:10px;flex-wrap:wrap}}
.trow>span{{flex:1;min-width:96px;background:rgba(0,0,0,.22);border:1px solid var(--line);border-radius:14px;padding:12px 13px;font-size:.76rem;color:var(--mut);transition:border-color .2s,transform .2s}}
.trow>span:hover{{border-color:var(--line2);transform:translateY(-1px)}}
.trow b{{display:block;color:var(--fg);font-size:1.12rem;font-weight:600;margin-top:4px;letter-spacing:-.01em}}
.row2{{display:flex;align-items:center;gap:10px;flex-wrap:wrap}}
.lat{{background:rgba(255,255,255,.05);border:1px solid var(--line);color:var(--fg);border-radius:11px;padding:9px 16px;font-size:.82rem;cursor:pointer;transition:background .2s,border-color .2s}}
.lat:hover{{background:rgba(255,255,255,.11);border-color:var(--line2)}}
.sec{{font-size:.72rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:26px 3px 4px}}
.ncard{{background:var(--card);border:1px solid var(--line);border-radius:15px;padding:15px;margin:11px 0;transition:transform .25s,border-color .25s}}
.ncard:hover{{transform:translateY(-2px);border-color:var(--line2)}}
.nhd{{font-weight:600;font-size:.92rem;margin-bottom:11px}}
.muted{{color:var(--mut);font-size:.84rem}}
.warn{{background:rgba(248,113,113,.09);border:1px solid rgba(248,113,113,.28);color:#fca5a5;border-radius:15px;padding:15px;font-size:.82rem;display:flex;gap:11px;align-items:flex-start;margin-top:20px}}
.foot{{color:var(--mut);font-size:.82rem;margin:16px 3px 0}}
.kbd{{font-family:ui-monospace,Menlo,monospace;background:rgba(255,255,255,.06);border:1px solid var(--line);border-radius:7px;padding:2px 8px;font-size:.78rem}}
body.light{{--bg:#f7f8fb;--card:#ffffff;--line:rgba(15,18,30,.09);--line2:rgba(15,18,30,.2);--fg:#161a22;--mut:#5f6573;--acc:#6366f1;--g:linear-gradient(135deg,#6366f1,#a855f7)}}
body.light::before{{background:radial-gradient(680px 360px at 50% -6%,rgba(99,102,241,.13),transparent 70%)}}
body.light code{{background:#f1f3f8}}
body.light .trow>span{{background:#f5f7fb}}
body.light .cp,body.light .lat,body.light .tg{{background:#f3f4f8}}
body.light .warn{{background:#fff5f5;border-color:#ffd0d0;color:#b42318}}
</style></head><body><div class="wrap">
<div class="hd"><div class="nm"><span class="dot"></span><h1>{name}</h1></div><div style="display:flex;gap:8px">{logout_btn}<button class="tg" onclick="tg()">{I_MOON} 主题</button></div></div>
<p class="sub">扫码或一键导入即可使用 · 整段订阅含全部节点,下方可逐条导入</p>
<div class="card main">
<div class="ttl"><span>Clash / Mihomo 订阅</span><span class="tag">主用</span></div>
<div class="urlrow"><code>{clash}</code><button class="cp" onclick="cpx(this)">复制</button></div>
<a class="imp" href="{clash_deep}">{I_BOLT} 一键导入 Clash / Mihomo</a>
{qr(os.environ.get("QR_CLASH",""))}</div>
<div class="card">
<div class="ttl"><span>通用订阅 · v2rayN / Shadowrocket / NekoBox</span></div>
<div class="urlrow"><code>{b64}</code><button class="cp" onclick="cpx(this)">复制</button></div>
<a class="imp" href="{sr_deep}">{I_BOLT} 一键导入 Shadowrocket</a>
{qr(os.environ.get("QR_B64",""))}</div>
<div class="card">
<div class="ttl"><span>流量 / 到期</span></div>
<div class="trow"><span>限额 <b>{limit_gb} GB</b></span><span>到期 <b>{exp_disp}</b></span><span>已用 <b id="used">查询中…</b></span></div>
<div class="row2" style="margin-top:13px"><button class="lat" onclick="lat()">延迟自测</button><span id="lat" class="muted">到本机 HTTP 往返(参考)</span></div></div>
<div class="sec">单节点（逐条导入 / 扫码）</div>
{nodes_html}
<div class="warn">{I_WARN}<span>此页含全部节点凭证。{scheme_note}</span></div>
<p class="foot">管理（改限额 / 更新 / 加节点）请用 SSH：<span class="kbd">bash install.sh menu</span></p>
</div><script>
{logout_js}
try{{sessionStorage.removeItem('sbt')}}catch(e){{}}   // 到了看板=登录成功, 清掉标记, 免得退出后回登录页误报"密码错误"
window.addEventListener('pageshow',function(e){{if(e.persisted)document.body.style.opacity=''}});  // bfcache 返回时恢复(退出时淡出过, 别卡在透明)
function cpx(b){{navigator.clipboard.writeText(b.parentElement.querySelector('code').textContent);var o=b.textContent;b.textContent='已复制';setTimeout(function(){{b.textContent=o}},1200)}}
function tg(){{document.body.classList.toggle('light');try{{localStorage.setItem('sbtheme',document.body.classList.contains('light')?'light':'dark')}}catch(e){{}}}}
try{{if(localStorage.getItem('sbtheme')==='light')document.body.classList.add('light')}}catch(e){{}}
function lat(){{var o=document.getElementById('lat');o.textContent='测试中…';var t=[],n=5,i=0;
function one(){{var s=performance.now();fetch({clash_js},{{method:'HEAD',cache:'no-store'}}).then(function(){{t.push(performance.now()-s);i++;if(i<n)one();else{{t.sort(function(a,b){{return a-b}});o.textContent=Math.round(t[Math.floor(t.length/2)])+' ms · 到本机HTTP往返(参考)';}}}}).catch(function(){{o.textContent='测不到(订阅不可达?)';}});}}
one();}}
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

# 看板页登录页(自定义好看页面, 无敏感信息): 输密码 -> JS 写 cookie sbauth -> 跳看板; nginx 校验 cookie==密码。
render_panel_login_html() {
  AIRPORT_NAME="$AIRPORT_NAME" PANEL_PATH="$PANEL_PATH" \
  PANEL_HTTPS="$(subscription_tls_enabled && printf 1 || printf 0)" \
  "$PY" - <<'PY'
import os, html, json, sys
name = html.escape(os.environ.get("AIRPORT_NAME", "订阅"))
panel = json.dumps(os.environ.get("PANEL_PATH", "/"))   # 安全的 JS 字符串字面量
tip = "HTTPS 已启用，密码与 cookie 加密传输。" if os.environ.get("PANEL_HTTPS") == "1" else "明文 HTTP 下密码不加密传输; 不可信网络请走 HTTPS。"
out = f'''<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name} · 登录</title><style>
:root{{--bg:#0b0e14;--card:#141925;--line:rgba(255,255,255,.08);--fg:#eef1f6;--mut:#8b93a4;--g:linear-gradient(135deg,#818cf8,#c084fc)}}
*{{box-sizing:border-box}}
body{{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px;background:radial-gradient(640px 340px at 50% 0%,rgba(129,140,248,.2),transparent 70%),var(--bg);color:var(--fg);font-family:system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased;animation:fadein .4s ease both}}
body.leaving{{animation:none;opacity:0;transition:opacity .22s ease}}
@keyframes fadein{{from{{opacity:0}}to{{opacity:1}}}}
@keyframes rise{{from{{opacity:0;transform:translateY(14px)}}to{{opacity:1;transform:none}}}}
@media (prefers-reduced-motion:reduce){{body,.box{{animation:none}}body.leaving{{transition:none}}}}
.box{{width:340px;max-width:100%;background:var(--card);border:1px solid var(--line);border-radius:20px;padding:28px 24px;text-align:center;box-shadow:0 24px 60px -24px rgba(0,0,0,.6),0 0 0 1px rgba(129,140,248,.08);animation:rise .55s cubic-bezier(.2,.75,.2,1) both}}
.lk{{width:54px;height:54px;margin:0 auto 14px;border-radius:16px;display:flex;align-items:center;justify-content:center;background:var(--g);color:#fff;box-shadow:0 12px 28px -10px rgba(129,140,248,.8)}}
h1{{font-size:1.25rem;font-weight:600;margin:0;letter-spacing:-.01em}}
.sub{{color:var(--mut);font-size:.86rem;margin:7px 0 20px}}
input{{width:100%;height:46px;background:rgba(0,0,0,.28);border:1px solid var(--line);border-radius:12px;color:var(--fg);font-size:.95rem;padding:0 14px;outline:none;transition:border-color .2s,box-shadow .2s}}
input:focus{{border-color:#818cf8;box-shadow:0 0 0 3px rgba(129,140,248,.22)}}
button{{width:100%;height:46px;margin-top:12px;border:0;border-radius:12px;background:var(--g);color:#fff;font-size:.95rem;font-weight:600;cursor:pointer;box-shadow:0 12px 28px -12px rgba(129,140,248,.8);transition:transform .15s,filter .2s}}
button:hover{{transform:translateY(-1px);filter:brightness(1.06)}}button:active{{transform:translateY(0) scale(.99)}}
.err{{display:none;color:#fca5a5;font-size:.82rem;margin:12px 0 0}}
.tip{{color:var(--mut);font-size:.74rem;margin:16px 0 0;line-height:1.5}}
</style></head><body>
<div class="box">
<div class="lk"><svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg></div>
<h1>{name} 看板</h1>
<p class="sub">输入密码查看你的节点订阅</p>
<input id="pw" type="password" placeholder="密码" autocomplete="current-password" autofocus>
<button id="go">登录</button>
<p class="err" id="err">密码不对,再试一次</p>
<p class="tip">{tip}</p>
</div>
<script>
var P={panel};
window.addEventListener('pageshow',function(e){{if(e.persisted)document.body.classList.remove('leaving')}});  // bfcache 返回时清除淡出态, 别卡在透明
function go(){{var v=document.getElementById('pw').value;if(!v)return;try{{sessionStorage.setItem('sbt','1')}}catch(e){{}}document.cookie='sbauth='+v+'; path=/; max-age=604800; samesite=lax'+(location.protocol==='https:'?'; secure':'');document.body.classList.add('leaving');setTimeout(function(){{location.replace(P)}},200);}}
document.getElementById('go').onclick=go;
document.getElementById('pw').addEventListener('keydown',function(e){{if(e.key==='Enter')go();}});
try{{if(sessionStorage.getItem('sbt')){{sessionStorage.removeItem('sbt');document.getElementById('err').style.display='block';document.getElementById('pw').focus();}}}}catch(e){{}}
</script></body></html>'''
sys.stdout.write(out)
PY
}

# 管理面板页(可写: 改限额/到期/计费 + 重启/备份); __TOKEN__ 由后端注入。仅经 127.0.0.1+SSH隧道访问。
render_admin_html() {
  cat <<'HTML'
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>节点管理</title><style>
:root{color-scheme:light dark}
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#0e1116;color:#e6e6e6;margin:0;padding:24px;line-height:1.6}
.wrap{max-width:720px;margin:0 auto}h1{font-size:1.4rem;margin:.2em 0}
.muted{color:#8b949e;font-size:.9rem}
.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:16px;margin:14px 0}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0}
label{min-width:70px;font-size:.9rem;color:#8b949e}
input,select{background:#0d1117;color:#e6e6e6;border:1px solid #30363d;border-radius:6px;padding:7px 10px;font-size:.9rem}
input[type=text]{min-width:260px}
button{background:#238636;color:#fff;border:0;border-radius:6px;padding:8px 14px;cursor:pointer;font-size:.9rem}
button.sec{background:#21262d;border:1px solid #30363d;color:#e6e6e6}
button:active{opacity:.7}
.k{color:#8b949e;display:inline-block;min-width:84px}
.warn{background:#3d1c1c;border-color:#5c2626;color:#ffb4b4}
#msg{white-space:pre-wrap;font-size:.82rem;font-family:ui-monospace,monospace}
.ok{color:#3fb950}.bad{color:#f85149}
</style></head><body><div class="wrap">
<h1>节点管理</h1>
<p class="muted">仅本机 127.0.0.1，经 SSH 隧道访问；所有改动复用 <code>install.sh</code>。</p>
<div class="card"><b>状态</b><div id="status" class="muted">加载中…</div></div>
<div class="card"><b>改限额 / 到期 / 计费</b>
<div class="row"><label>限额(GB)</label><input id="limit" type="number" min="0" step="0.5" placeholder="如 200"></div>
<div class="row"><label>计费</label><select id="mode"><option value="">（不改）</option><option value="rx+tx">rx+tx（双向）</option><option value="tx">tx（仅出站）</option><option value="max">max（取大）</option></select></div>
<div class="row"><label>到期</label><input id="expire" type="text" placeholder="YYYY-MM-DD HH:MM:SS +0800（留空不改）"></div>
<div class="row"><button onclick="save()">保存并刷新流量头</button></div></div>
<div class="card"><b>操作</b>
<div class="row"><button class="sec" onclick="act('restart')">重启 sing-box / nginx</button>
<button class="sec" onclick="act('backup')">立即备份（打包凭证）</button></div></div>
<div class="card"><b>输出</b><div id="msg" class="muted">—</div></div>
<div class="card warn">⚠️ 此页可改服务器配置。只应通过 SSH 隧道在你本机访问；Token 别外泄；这个端口已绑 127.0.0.1，<b>绝不要</b>暴露到公网。</div>
</div><script>
var TOKEN="__TOKEN__";
function msg(t,cls){var m=document.getElementById('msg');m.textContent=t;m.className=cls||'muted';}
function api(p,m,b){return fetch(p,{method:m||'GET',headers:{'X-Token':TOKEN,'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined}).then(function(r){return r.json();});}
function fmtGB(b){return b==null?'—':(b/1073741824).toFixed(2)+' GB';}
function loadStatus(){api('/api/status').then(function(s){
var h='';
h+='<div><span class="k">sing-box</span> '+(s.singbox?'<span class=ok>运行中</span>':'<span class=bad>已停</span>')+'</div>';
h+='<div><span class="k">nginx</span> '+(s.nginx?'<span class=ok>运行中</span>':'<span class=bad>已停</span>')+'</div>';
h+='<div><span class="k">限额</span> '+(s.limit_gb||'?')+' GB &nbsp;<span class="k">已用</span> '+fmtGB(s.used_bytes)+'</div>';
h+='<div><span class="k">计费</span> '+(s.count_mode||'?')+' &nbsp;<span class="k">到期</span> '+(s.expire||'?')+'</div>';
document.getElementById('status').innerHTML=h;
if(s.limit_gb&&!document.getElementById('limit').value)document.getElementById('limit').value=s.limit_gb;
}).catch(function(){document.getElementById('status').textContent='状态读取失败';});}
function save(){var b={limit_gb:document.getElementById('limit').value.trim(),count_mode:document.getElementById('mode').value,expire_at:document.getElementById('expire').value.trim()};
msg('保存中…');api('/api/set','POST',b).then(function(r){msg(r.msg||(r.ok?'已保存':'失败'),r.ok?'ok':'bad');if(r.ok)loadStatus();}).catch(function(){msg('请求失败','bad');});}
function act(a){if(a==='restart'&&!confirm('确定重启服务?'))return;msg(a+' 执行中…');
api('/api/action','POST',{action:a}).then(function(r){msg(r.msg||(r.ok?'完成':'失败'),r.ok?'ok':'bad');loadStatus();}).catch(function(){msg('请求失败','bad');});}
loadStatus();
</script></body></html>
HTML
}

# 写管理面板后端(python stdlib, 无 pip): 仅绑 127.0.0.1, Token 鉴权, 白名单动作, subprocess 用参数数组(无 shell 注入)
write_admin_py() {
  cat >"$ADMIN_PY" <<'PYEOF'
#!/usr/bin/env python3
import json, os, re, hmac, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOCK = threading.Lock()   # 串行化改动类动作, 防两个请求同时改 config/env

ADMIN_ENV = "/etc/sing-box/admin.env"
HTML_PATH = "/etc/sing-box/admin.html"
NODE_ENV  = "/etc/sing-box-node.env"
HDR       = "/etc/nginx/snippets/sub_headers.conf"
INSTALL   = "/etc/sing-box/install.sh"

def load_env(p):
    d = {}
    try:
        with open(p) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return d

CFG   = load_env(ADMIN_ENV)
TOKEN = CFG.get("ADMIN_TOKEN", "")
PORT  = int(CFG.get("ADMIN_PORT", "8088"))

def run(args, timeout=120):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception as e:
        return 1, str(e)

def svc(name):
    try:
        return subprocess.run(["systemctl", "is-active", "--quiet", name]).returncode == 0
    except Exception:
        return False

def status():
    env = load_env(NODE_ENV)
    used = None
    try:
        m = re.search(r"download=(\d+)", open(HDR).read())
        used = int(m.group(1)) if m else None
    except Exception:
        pass
    return {"singbox": svc("sing-box"), "nginx": svc("nginx"),
            "limit_gb": env.get("LIMIT_GB"), "expire": env.get("EXPIRE_AT"),
            "count_mode": env.get("COUNT_MODE"), "used_bytes": used}

def do_set(data):
    args = []
    lg = str(data.get("limit_gb", "")).strip()
    cm = str(data.get("count_mode", "")).strip()
    ex = str(data.get("expire_at", "")).strip()
    if lg:
        if not re.fullmatch(r"\d+(\.\d+)?", lg):
            return {"ok": False, "msg": "限额必须是数字(如 200 或 0.5)"}
        args.append("LIMIT_GB=" + lg)
    if cm:
        if cm not in ("rx+tx", "tx", "max"):
            return {"ok": False, "msg": "计费只能 rx+tx / tx / max"}
        args.append("COUNT_MODE=" + cm)
    if ex:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}", ex):
            return {"ok": False, "msg": "到期格式应为 'YYYY-MM-DD HH:MM:SS +0800'"}
        args.append("EXPIRE_AT=" + ex)
    if not args:
        return {"ok": False, "msg": "没有要改的项"}
    rc, out = run(["bash", INSTALL, "set"] + args)
    return {"ok": rc == 0, "msg": out[-1200:] or ("已保存" if rc == 0 else "失败")}

def do_action(data):
    a = data.get("action", "")
    if a in ("restart", "backup"):
        rc, out = run(["bash", INSTALL, a])
        return {"ok": rc == 0, "msg": out[-1200:] or ("完成" if rc == 0 else "失败")}
    return {"ok": False, "msg": "未知操作"}

class H(BaseHTTPRequestHandler):
    def _auth(self):
        q = parse_qs(urlparse(self.path).query)
        tok = (q.get("token", [""])[0]) or self.headers.get("X-Token", "")
        return bool(TOKEN) and hmac.compare_digest(tok, TOKEN)
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        b = body.encode("utf-8") if isinstance(body, str) else body
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        except (BrokenPipeError, ConnectionError):
            pass   # 客户端提前断开(如 curl 超时), 不是错误, 别刷栈
    def do_GET(self):
        if not self._auth():
            return self._send(401, '{"error":"unauthorized"}')
        path = urlparse(self.path).path
        if path == "/":
            try:
                page = open(HTML_PATH, encoding="utf-8").read().replace("__TOKEN__", TOKEN)
            except Exception:
                return self._send(500, '{"error":"no admin.html"}')
            return self._send(200, page, "text/html; charset=utf-8")
        if path == "/api/status":
            return self._send(200, json.dumps(status()))
        return self._send(404, '{"error":"not found"}')
    def do_POST(self):
        if not self._auth():
            return self._send(401, '{"error":"unauthorized"}')
        path = urlparse(self.path).path
        ln = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(ln) if ln else b""
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            data = {}
        if path == "/api/set":
            with LOCK:
                res = do_set(data)
            return self._send(200, json.dumps(res))
        if path == "/api/action":
            with LOCK:
                res = do_action(data)
            return self._send(200, json.dumps(res))
        return self._send(404, '{"error":"not found"}')
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF
  chmod 700 "$ADMIN_PY"
}

render_header() {
  LIMIT_GB="$LIMIT_GB" EXPIRE_AT_VAL="$1" "$PY" - <<'PY'
import os, datetime
limit = int(float(os.environ["LIMIT_GB"]) * 1024 ** 3)
# EXPIRE_AT 留空 -> expire=0(客户端普遍视为"无到期"), 与 traffic_limit.py 口径一致
_raw = os.environ["EXPIRE_AT_VAL"].strip()
exp = int(datetime.datetime.strptime(_raw, "%Y-%m-%d %H:%M:%S %z").timestamp()) if _raw else 0
print(f'add_header Subscription-Userinfo "upload=0; download=0; total={limit}; expire={exp}" always;')
PY
}

# ---- 写文件 + 副作用 -------------------------------------------------------
write_singbox_config() {
  log "写入 sing-box 配置并校验..."
  systemctl enable sing-box >/dev/null 2>&1 || true
  # 重装已有节点时也走回滚护栏: 先临时文件 sing-box check, 再经 apply_singbox_config 落地;
  # restart 失败时回滚旧配置, 不把原本可用的节点丢在新配置/停服状态(首次安装无旧配置可回滚)。
  local tmpc; tmpc="$(mktemp)" || return 1
  render_singbox_config >"$tmpc" || { rm -f "$tmpc"; return 1; }
  sing-box check -c "$tmpc" || { rm -f "$tmpc"; return 1; }
  apply_singbox_config "$tmpc" || { rm -f "$tmpc"; return 1; }
  rm -f "$tmpc"
  ok "sing-box 已启动"
}

write_subscription() {
  log "生成 Clash/Mihomo 订阅 + 通用(base64)订阅..."
  mkdir -p "$WWW"
  chmod 755 "$WWW"   # 防止 umask 077 下新建的 web 根变 700, 导致 nginx(www-data) 无法遍历→订阅 403
  require_node_address || return 1

  # 所有产物先写同目录临时文件。只有整组渲染和校验都成功才逐个原子替换；任何一步失败时，
  # 已发布订阅保持原样，不会因 shell 重定向先截断目标文件而把可用节点变成空/坏配置。
  local tmp_yaml="" tmp_b64="" tmp_panel="" tmp_login=""
  local out_yaml="$WWW$SUB_PATH" out_b64="$WWW$SUB_B64_PATH" out_panel="$WWW$PANEL_PATH"
  local out_login="$WWW${PANEL_PATH%.html}-login.html"
  local -a publish_pairs=()
  _cleanup_subscription_tmp() { rm -f "$tmp_yaml" "$tmp_b64" "$tmp_panel" "$tmp_login"; }
  tmp_yaml="$(mktemp "$WWW/.singbox-sub-yaml.XXXXXX")" || return 1
  if ! render_subscription_yaml >"$tmp_yaml"; then _cleanup_subscription_tmp; return 1; fi
  if [ -n "${SUB_B64_PATH:-}" ]; then
    tmp_b64="$(mktemp "$WWW/.singbox-sub-b64.XXXXXX")" || { _cleanup_subscription_tmp; return 1; }
    if ! render_share_links | base64 -w0 >"$tmp_b64"; then _cleanup_subscription_tmp; return 1; fi
  fi
  if [ -n "${PANEL_PATH:-}" ]; then
    tmp_panel="$(mktemp "$WWW/.singbox-panel.XXXXXX")" || { _cleanup_subscription_tmp; return 1; }
    if ! render_panel_html >"$tmp_panel"; then _cleanup_subscription_tmp; return 1; fi
    if [ -s "$PANEL_MAP" ]; then
      tmp_login="$(mktemp "$WWW/.singbox-panel-login.XXXXXX")" || { _cleanup_subscription_tmp; return 1; }
      if ! render_panel_login_html >"$tmp_login"; then _cleanup_subscription_tmp; return 1; fi
    fi
  fi

  SUB_YAML="$tmp_yaml" SUB_B64="$tmp_b64" PANEL_HTML="$tmp_panel" NODE_IP="${NODE_ADDR:-$PUBLIC_IP}" \
    EXPECTED_HY2="$ENABLE_HY2" EXPECTED_ANYTLS="$ANYTLS_OK" "$PY" - <<'PY' || { _cleanup_subscription_tmp; return 1; }
import base64
import os
import re

node_ip = os.environ["NODE_IP"]
expected_direct = 1 + (os.environ["EXPECTED_HY2"] == "1") + (os.environ["EXPECTED_ANYTLS"] == "1")
expected_total = expected_direct

yaml_text = open(os.environ["SUB_YAML"], encoding="utf-8").read()
servers = re.findall(r"^\s+server:\s*(\S+)\s*$", yaml_text, re.M)
if len(servers) != expected_total or servers[:expected_direct] != [node_ip] * expected_direct:
    raise SystemExit("invalid direct server fields in rendered subscription")

b64_path = os.environ.get("SUB_B64", "")
if b64_path:
    encoded = open(b64_path, encoding="ascii").read().strip()
    links = base64.b64decode(encoded, validate=True).decode("utf-8").splitlines()
    if len(links) != expected_total:
        raise SystemExit("unexpected share-link count")
    for link in links[:expected_direct]:
        match = re.match(r"^[a-z0-9]+://[^@]+@(?P<host>\[[^\]]+\]|[^:/?#]+)", link)
        if not match or match.group("host").strip("[]") != node_ip:
            raise SystemExit("invalid direct host in share links")
    if "@;:" in "\n".join(links):
        raise SystemExit("placeholder host in share links")

panel_path = os.environ.get("PANEL_HTML", "")
if panel_path:
    panel = open(panel_path, encoding="utf-8").read()
    if "@;:" in panel or panel.count('class="ncard"') != expected_total:
        raise SystemExit("invalid dashboard node links")
PY

  chmod 644 "$tmp_yaml" || { _cleanup_subscription_tmp; return 1; }
  publish_pairs+=("$tmp_yaml" "$out_yaml")
  if [ -n "$tmp_b64" ]; then chmod 644 "$tmp_b64" || { _cleanup_subscription_tmp; return 1; }; publish_pairs+=("$tmp_b64" "$out_b64"); fi
  if [ -n "$tmp_panel" ]; then chmod 644 "$tmp_panel" || { _cleanup_subscription_tmp; return 1; }; publish_pairs+=("$tmp_panel" "$out_panel"); fi
  if [ -n "$tmp_login" ]; then
    chmod 644 "$tmp_login" || { _cleanup_subscription_tmp; return 1; }
    publish_pairs+=("$tmp_login" "$out_login")
  elif [ -n "${PANEL_PATH:-}" ]; then
    publish_pairs+=("-" "$out_login")
  fi
  [ $(( $# % 2 )) -eq 0 ] || { _cleanup_subscription_tmp; err "write_subscription 额外发布参数必须是 source/target 对"; return 1; }
  publish_pairs+=("$@")
  if ! publish_files_transaction "${publish_pairs[@]}"; then _cleanup_subscription_tmp; return 1; fi
  tmp_yaml=""; tmp_b64=""; tmp_panel=""; tmp_login=""
}

validate_panel_file() {
  local panel="$1"
  EXPECTED_HY2="$ENABLE_HY2" EXPECTED_ANYTLS="$ANYTLS_OK" "$PY" - "$panel" <<'PY'
import os
import sys

expected = 1 + (os.environ["EXPECTED_HY2"] == "1") + (os.environ["EXPECTED_ANYTLS"] == "1")
text = open(sys.argv[1], encoding="utf-8").read()
if "@;:" in text or text.count('class="ncard"') != expected:
    raise SystemExit(1)
PY
}

write_panel_files() {
  require_node_address || return 1
  mkdir -p "$WWW" || return 1
  chmod 755 "$WWW" || return 1
  local tmp_panel="" tmp_login="" panel_file="$WWW$PANEL_PATH" login_file="$WWW${PANEL_PATH%.html}-login.html"
  local -a pairs=()
  tmp_panel="$(mktemp "$WWW/.singbox-panel.XXXXXX")" || return 1
  if ! render_panel_html >"$tmp_panel" || ! validate_panel_file "$tmp_panel" || ! chmod 644 "$tmp_panel"; then
    rm -f "$tmp_panel"; return 1
  fi
  pairs+=("$tmp_panel" "$panel_file")
  if [ -s "$PANEL_MAP" ]; then
    tmp_login="$(mktemp "$WWW/.singbox-panel-login.XXXXXX")" || { rm -f "$tmp_panel"; return 1; }
    if ! render_panel_login_html >"$tmp_login" || ! chmod 644 "$tmp_login"; then
      rm -f "$tmp_panel" "$tmp_login"; return 1
    fi
    pairs+=("$tmp_login" "$login_file")
  else
    pairs+=("-" "$login_file")
  fi
  if ! publish_files_transaction "${pairs[@]}"; then rm -f "$tmp_panel" "$tmp_login"; return 1; fi
}

config_nginx() {
  log "配置 nginx 订阅服务..."
  mkdir -p "$(dirname "$NGINX_SNIPPET")" "$(dirname "$NGINX_CONF")" "$(dirname "$NGINX_MAIN")" || return 1
  local backup tmp_header tmp_conf tmp_main terr nginx_was_active=0
  backup="$(mktemp -d "$SB_DIR/.nginx-backup.XXXXXX")" || return 1
  snapshot_files "$backup" "$NGINX_SNIPPET" "$NGINX_CONF" "$NGINX_MAIN" "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF" \
    || { rm -rf "$backup"; return 1; }
  systemctl is-active --quiet nginx 2>/dev/null && nginx_was_active=1 || true
  _rollback_nginx() {
    local rollback_rc=0
    restore_files "$backup" "$NGINX_SNIPPET" "$NGINX_CONF" "$NGINX_MAIN" "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF" || rollback_rc=1
    if nginx -t >/dev/null 2>&1 && [ "$nginx_was_active" = 1 ]; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || rollback_rc=1
    elif ! nginx -t >/dev/null 2>&1; then
      rollback_rc=1
    fi
    if [ "$rollback_rc" -eq 0 ]; then
      rm -rf "$backup"
    else
      err "Nginx 回滚不完整，备份保留在: $backup"
    fi
    return "$rollback_rc"
  }
  # 流量头单独放 snippets, 只在订阅 location 内 include(首页/404 不会带头); 数值用 env 单一来源
  tmp_header="$(mktemp "$(dirname "$NGINX_SNIPPET")/.sub-headers.XXXXXX")" || { _rollback_nginx; return 1; }
  if ! render_header "$EXPIRE_VALUE" >"$tmp_header" || ! chmod 644 "$tmp_header"; then rm -f "$tmp_header"; _rollback_nginx; return 1; fi

  # 订阅 TLS(可选): TCP 443 在 VLESS 下线后已经空出。有域名证书时让订阅 server 直接监听 443,
  # 并补一个 443 默认 server —— 未知 SNI 会命中自签证书后 444 关闭, 不暴露任何内容(黑洞)。
  local tls_listen="" tls_default=""
  if subscription_tls_enabled; then
    tls_listen=$'\n    listen 443 ssl;\n    ssl_certificate '"$(sub_cert_file)"$';\n    ssl_certificate_key '"$(sub_key_file)"$';'
    tls_default=$'server {\n    listen 443 ssl default_server;\n    ssl_certificate '"$SB_DIR/server.crt"$';\n    ssl_certificate_key '"$SB_DIR/server.key"$';\n    server_name _;\n    return 444;\n}\n\n'
  elif [ "$SUB_TLS" = 1 ]; then
    rm -f "$tmp_header"; _rollback_nginx
    err "SUB_TLS=1 需要 DOMAIN=$( [ -n "$DOMAIN" ] && printf '%s' "$DOMAIN" || printf '<域名>' ) 且证书就位: $(sub_cert_file) / $(sub_key_file)"
    return 1
  fi

  # 双 server: 默认 Host/IP 一律 404; 只有订阅域名/IP 的精确随机路径返回内容。
  local v6_default="" v6_named=""
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    v6_default=$'\n    listen [::]:80 default_server;'
    v6_named=$'\n    listen [::]:80;'
  fi
  rm -f "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF" 2>/dev/null || true
  # 看板页可选登录(nginx 真鉴权, 不是网页里的 JS 假门): 存在 map 片段时, nginx 用 \$sb_ok 校验 cookie 是否
  # 等于密码(密码只在 600 root 的 \$PANEL_MAP 里, 由 nginx master 加载, 从不下发浏览器); 不对就 302 跳登录页。
  local sub_server_name panel_login="${PANEL_PATH%.html}-login.html"
  sub_server_name="$(url_host "$SUB_HOST")"
  local panel_inc="" panel_guard="" login_loc=""
  if [ -s "$PANEL_MAP" ]; then
    panel_inc="include $PANEL_MAP;"$'\n'
    panel_guard=$'\n        if ($sb_ok = 0) { return 302 '"$panel_login"'; }'
    login_loc=$'    location = '"$panel_login"$' {\n        default_type text/html;\n        try_files $uri =404;\n    }\n'
  fi
  tmp_conf="$(mktemp "$(dirname "$NGINX_CONF")/.singbox-sub.XXXXXX")" || { rm -f "$tmp_header"; _rollback_nginx; return 1; }
  cat >"$tmp_conf" <<EOF
${panel_inc}${tls_default}server {
    listen 80 default_server;$v6_default
    server_name _;
    return 404;
}

server {
    listen 80;$v6_named$tls_listen
    root $WWW;
    server_name $sub_server_name;
    # 若该 vhost 后续放到内部 TLS 端口后面，保持相对 Location，避免把内部端口泄漏给浏览器。
    absolute_redirect off;

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

    location = $PANEL_PATH {$panel_guard
        default_type text/html;
        try_files \$uri =404;
    }
$login_loc
    location / {
        return 404;
    }
}
EOF
  chmod 644 "$tmp_conf" || { rm -f "$tmp_header" "$tmp_conf"; _rollback_nginx; return 1; }

  tmp_main="$(mktemp "$(dirname "$NGINX_MAIN")/.nginx-main.XXXXXX")" || { rm -f "$tmp_header" "$tmp_conf"; _rollback_nginx; return 1; }
  cp -a "$NGINX_MAIN" "$tmp_main" || { rm -f "$tmp_header" "$tmp_conf" "$tmp_main"; _rollback_nginx; return 1; }
  if grep -q 'server_tokens' "$tmp_main"; then
    sed -i 's/^\([[:space:]]*\)#\?[[:space:]]*server_tokens .*/\1server_tokens off;/' "$tmp_main" || { rm -f "$tmp_header" "$tmp_conf" "$tmp_main"; _rollback_nginx; return 1; }
  else
    sed -i '0,/http[[:space:]]*{/s//http {\n    server_tokens off;/' "$tmp_main" || { rm -f "$tmp_header" "$tmp_conf" "$tmp_main"; _rollback_nginx; return 1; }
  fi

  if ! mv -f "$tmp_header" "$NGINX_SNIPPET" || ! mv -f "$tmp_conf" "$NGINX_CONF" || ! mv -f "$tmp_main" "$NGINX_MAIN"; then
    rm -f "$tmp_header" "$tmp_conf" "$tmp_main"; _rollback_nginx; return 1
  fi

  # 不用 /tmp/xxx.$$: 文件名由 PID 决定可预测, root 写入会跟随他人预置的符号链接
  local terr; terr="$(mktemp)"
  if ! nginx -t 2>"$terr"; then
    err "nginx 配置校验失败:"; cat "$terr" >&2
    if grep -qi 'duplicate default server' "$terr" 2>/dev/null; then
      err "→ 机器上已有别的 default_server 站点。请在 /etc/nginx/ 下找到并移除冲突的 default_server, 然后重跑。"
    fi
    rm -f "$terr"; _rollback_nginx; return 1
  fi
  rm -f "$terr"
  if ! systemctl reload nginx && ! systemctl restart nginx; then _rollback_nginx; return 1; fi
  rm -rf "$backup"
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
STATE_DIR = "/var/lib/sing-box-node"
QUOTA_FLAG = os.path.join(STATE_DIR, "quota-stopped")


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
    months = iface.get("traffic", {}).get("month", [])
    if not months:
        return 0
    # 优先取标签等于当前自然月的桶; 匹配不到(例如配了 vnstat MonthRotate、
    # 账期跨入新自然月的前半段)就退回最后一个桶。vnstat 按时间升序输出,
    # 最后一个桶就是当前账期, 对自然月和 MonthRotate 都成立。
    cur = months[-1]
    for m in months:
        d = m.get("date", {})
        if d.get("year") == now.year and d.get("month") == now.month:
            cur = m
            break
    rx = cur.get("rx", 0)
    tx = cur.get("tx", 0)
    if mode == "rx+tx":
        return rx + tx  # 仅商家真按"进+出"计费才用; 代理 rx≈tx, 这是真实用量的约 2 倍
    if mode == "max":
        return max(rx, tx)
    return tx  # 默认 tx: 只算出站, 匹配绝大多数商家(rx+tx 会翻倍误算)


def build_header(used, total, expire):
    return (f'add_header Subscription-Userinfo '
            f'"upload=0; download={used}; total={total}; expire={expire}" always;\n')


def decide_enforcement(used, limit_bytes, active, flag_exists):
    # LIMIT_GB=0 表示不限量(只统计显示, 永不配额停机)。
    # 没有这个特判的话 used >= 0 恒真, 首个 cron 周期就会停掉 sing-box 并打标记,
    # 之后一直保持停机 —— 而用户填 0 的本意恰恰是"不要限制"。
    # 若此前被配额停过, 这里顺带把服务拉回来并清标记。
    if limit_bytes <= 0:
        return ("start" if (flag_exists and not active) else None, False)
    if used >= limit_bytes:
        if active:
            return ("stop", True)        # 超额且在跑: 停掉并打配额标记
        # 已经停了: 只有原本就是配额停(有标记)才保留标记;
        # 手动停(无标记)不抢标记, 否则下月恢复会被误当配额停机拉起。
        return (None, flag_exists)
    if flag_exists:
        return ("start" if not active else None, False)
    return (None, False)  # 无标记的手动停机: 不动


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    env = load_env()
    limit_bytes = int(float(env.get("LIMIT_GB", "200")) * 1024 ** 3)
    interface = env.get("INTERFACE", "eth0")
    mode = env.get("COUNT_MODE", "tx")
    # EXPIRE_AT 缺失/为空时不崩溃, 回退 expire=0(多数客户端视为"无到期")。
    expire_raw = env.get("EXPIRE_AT")
    expire = parse_expire(expire_raw) if expire_raw else 0

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
        # 打日志: cron 已把输出接到 logger -t traffic_limit。
        # 不打的话, 用户看到的现象是"手动 restart 后 5 分钟内又自己停",
        # 且 status/doctor 都不显示配额标记, 极易误判成 sing-box 崩溃或被墙。
        print(f"quota exceeded: used={used} >= limit={limit_bytes}, stopping sing-box",
              file=sys.stderr)
        subprocess.run(["systemctl", "stop", "sing-box"])
    elif action == "start":
        print(f"quota restored: used={used} < limit={limit_bytes}, starting sing-box",
              file=sys.stderr)
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
    mkdir -p "$(dirname "$BBR_MODULE_CONF")"
    printf 'tcp_bbr\n' >"$BBR_MODULE_CONF"
    chmod 644 "$BBR_MODULE_CONF"
    # Oracle 等内核可能把 BBR 编译成模块；先加载再应用 sysctl，否则会继续停在 cubic。
    modprobe tcp_bbr >/dev/null 2>&1 || true
    cat >>"$SYSCTL_CONF" <<'EOF'
# BBR 拥塞控制 + fq 队列(只作用于 TCP: AnyTLS; HY2 走 UDP 不受影响)
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

# HY2 端口跳跃已于 2026-10 下线(现网固定 UDP 443 + 自动拥塞控制)。
# 老机器可能仍留着 nft 表/自启服务: 重装时只清理本脚本自己建的对象, 不碰用户其它 nft 规则。
porthop_cleanup() {
  local svc="$PORTHOP_SERVICE"
  local had=0
  [ -f "$svc" ] && had=1
  if [ "$had" = 0 ] && command -v nft >/dev/null 2>&1; then
    nft list table inet sb_hophy2 >/dev/null 2>&1 && had=1
  fi
  [ "$had" = 1 ] || return 0          # 本来就没配过端口跳跃, 什么都不做
  log "清理旧版 HY2 端口跳跃配置..."
  systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
  rm -f "$svc" "$SB_DIR/porthop.nft"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v nft >/dev/null 2>&1; then nft delete table inet sb_hophy2 >/dev/null 2>&1 || true; fi
  ok "已移除旧版 HY2 端口跳跃(nft 表与自启服务)"
  note "旧版 HY2 端口跳跃已清理: 云安全组里之前为跳跃放行的 UDP 端口段可以一并删掉。"
  return 0
}

config_firewall() {
  # 提示要跟着 ENABLE_HY2 / SS_UDP / 订阅 TLS 走: 关掉的协议不该再让用户去云安全组放行对应端口
  local tcp_ports="22 80 $ANYTLS_PORT $SS_PORT" udp_ports="" udp_hint="" tcp_hint="" p
  if subscription_tls_enabled; then tcp_ports="22 80 443 $ANYTLS_PORT $SS_PORT"; fi
  for p in $tcp_ports; do tcp_hint="${tcp_hint:+$tcp_hint、}$p/tcp"; done
  subscription_tls_enabled && tcp_hint="$tcp_hint(443 为订阅 HTTPS)"
  [ "$SS_UDP" = 1 ] && udp_ports="$SS_PORT" && udp_hint="$SS_PORT"
  if [ "$ENABLE_HY2" = 1 ]; then
    udp_ports="$HY2_PORT${udp_ports:+ $udp_ports}"
    udp_hint="$HY2_PORT${udp_hint:+、$udp_hint}"
  fi
  if [ -n "$udp_hint" ]; then
    note "云安全组(服务商控制台)必须放行: $tcp_hint 与 UDP($udp_hint)—— 尤其 UDP。本脚本改不了云端安全组, 这是'HY2/SS 连不上、AnyTLS 却正常'的头号原因。"
  else
    note "云安全组(服务商控制台)必须放行: $tcp_hint(本机按 TCP-only 组合部署, 无需放行 UDP)。本脚本改不了云端安全组。"
  fi
  if ! command -v ufw >/dev/null 2>&1; then return 0; fi
  _ufw_allow_ports() {
    local p
    for p in $tcp_ports; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
    for p in $udp_ports; do ufw allow "$p"/udp >/dev/null 2>&1 || true; done
  }
  if [ "$ENABLE_UFW" = 1 ]; then
    log "配置并启用 ufw..."
    _ufw_allow_ports
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
    _ufw_allow_ports
    ok "已在现有 ufw 中放行端口"
  else
    note "主机防火墙 ufw 未启用, 本脚本未自动开启(避免锁死 SSH)。如需启用: 用 ENABLE_UFW=1 重跑, 或手动放行 TCP($tcp_ports)${udp_ports:+ 与 UDP($udp_ports)} 后 'ufw enable'。"
  fi
}

# ----------------------------------------------------------------- 输出
print_summary() {
  local sub_url
  sub_url="$(subscription_url "$SUB_PATH")"
  echo
  ok "================= 部署完成 ================="
  echo
  printf '  订阅名称:         %s\n' "$AIRPORT_NAME"
  printf '  Clash/Mihomo 订阅: %s\n' "$sub_url"
  [ -n "${SUB_B64_PATH:-}" ] && printf '  通用(base64)订阅:  %s   (v2rayN/Shadowrocket/NekoBox)\n' "$(subscription_url "$SUB_B64_PATH")"
  [ -n "${PANEL_PATH:-}" ]   && printf '  可视化看板页:      %s   (浏览器打开, 看订阅+扫码+复制)\n' "$(subscription_url "$PANEL_PATH")"
  echo
  printf '  节点(客户端里显示名):\n'
  [ "$ENABLE_HY2" = 1 ] && printf '    - Hysteria2  (UDP %s)\n' "$HY2_PORT"
  [ "$ANYTLS_OK" = 1 ] && printf '    - AnyTLS     (TCP %s)\n' "$ANYTLS_PORT"
  if [ "$SS_UDP" = 1 ]; then printf '    - SS2022     (TCP+UDP %s)\n' "$SS_PORT"
  else printf '    - SS2022     (TCP %s, TCP-only)\n' "$SS_PORT"; fi
  [ -n "$WARP_PRIVATE_KEY" ] && printf '    * WARP 解锁分流已开 (%s 走 WARP)\n' "${WARP_SITES:-$WARP_DEFAULT_SITES}"
  echo
  printf '  管理命令:\n'
  printf '    查看信息:    bash install.sh info\n'
  printf '    一键自检:    bash install.sh doctor   (排查不通先跑它)\n'
  printf '    看板页地址:  bash install.sh panel\n'
  printf '    分享链接:    bash install.sh links\n'
  printf '    备份/迁移:   bash install.sh backup   (新机: bash install.sh restore <文件>)\n'
  printf '    SSH 加固:    bash install.sh harden   (密钥登录+禁密码+fail2ban)\n'
  printf '    WARP 解锁:   bash install.sh warp      (关闭: warp off)\n'
  printf '    网页管理:    bash install.sh admin     (仅本机, SSH隧道访问)\n'
  printf '    旧CF清理:    bash install.sh cf off    (CF-VLESS 一键路径已下线)\n'
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
  warn "可选增强(默认未做): 1) SSH 改密钥登录+禁用密码(防爆破, 最值得做)  2) 订阅 443 HTTPS(把域名证书放到 $(sub_cert_file) 与 $(sub_key_file) 后重跑 install)  3) WARP 解锁分流(见 README)"
  echo
  log "自检: 把订阅 URL 导入 Clash/Mihomo, 先试 Hysteria2, 不通切 AnyTLS / SS2022。服务器端可跑: systemctl is-active sing-box nginx ; curl -I $sub_url"
}

do_info() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  # 优先用安装时存下的 SUB_HOST(纯读, 不崩); 老版本无此字段才回退探测且探测失败不致命
  [ -n "${SUB_HOST:-}" ] || SOFT_DETECT=1 detect_net
  command -v sing-box >/dev/null 2>&1 && SB_VER="$(sing-box version 2>/dev/null | awk '/version/{print $3; exit}')"
  [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json" && ANYTLS_OK=1 || ANYTLS_OK=0
  print_summary
}

do_links() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  echo "===== 各节点分享链接(单条可粘进 v2rayN / NekoBox / Shadowrocket 等) ====="
  render_share_links
  echo
  echo "===== 订阅 URL ====="
  local clash_url b64_url
  clash_url="$(subscription_url "$SUB_PATH")"
  b64_url="$(subscription_url "$SUB_B64_PATH")"
  printf 'Clash/Mihomo:  %s\n' "$clash_url"
  [ -n "${SUB_B64_PATH:-}" ] && printf '通用(base64):  %s\n' "$b64_url"
  echo
  echo "===== 一键导入深链(在装了客户端的设备上点开即可导入) ====="
  local _cu="$clash_url"
  printf 'Clash/Mihomo:  clash://install-config?url=%s&name=%s\n' \
    "$("$PY" -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$_cu")" \
    "$("$PY" -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$AIRPORT_NAME")"
  [ -n "${SUB_B64_PATH:-}" ] && printf 'Shadowrocket:  shadowrocket://add/sub://%s\n' \
    "$("$PY" -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' "$b64_url")"
  if ! command -v qrencode >/dev/null 2>&1; then
    echo "(装 qrencode 后这里会出二维码: apt install -y qrencode)"
  elif [ -n "${SUB_B64_PATH:-}" ]; then
    echo; echo "===== 通用订阅二维码(扫码导入 v2rayN/Shadowrocket) ====="
    qrencode -t ANSIUTF8 "$b64_url"
  else
    echo "(无通用订阅路径, 重跑 install 升级后即可生成二维码)"
  fi
}

do_panel() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  hydrate_legacy_runtime_state
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  [ -n "${PANEL_PATH:-}" ] || die "本安装无看板页, 重跑 install 升级后生成"
  write_panel_files || die "看板渲染/校验/发布失败，已保留旧看板"
  ok "可视化看板页: $(subscription_url "$PANEL_PATH")"
  echo "  浏览器打开即可看两种订阅 + 扫码导入 + 一键复制; 手机扫码最方便。"
  if [ -s "$PANEL_MAP" ]; then
    echo "  (已开密码登录: 打开会先到登录页。改密码/关闭: bash install.sh panel-pass <密码> | panel-pass off)"
  else
    echo "  想加密码登录(自定义登录页): bash install.sh panel-pass <密码>"
  fi
}

# 给看板页加登录: 自定义好看登录页 + nginx 用 cookie==密码 服务端校验(真鉴权, 不是网页里的 JS 假门)。off 关闭。
do_panel_pass() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  [ -n "${PANEL_PATH:-}" ] || die "本安装无看板页, 先重跑 install 升级再设密码"
  command -v nginx >/dev/null 2>&1 || die "未检测到 nginx"
  # config_nginx 需要的派生变量(单独跑该函数时补齐)
  # 同 write_env: 不捏造到期日, 留空即 expire=0("无到期"), 也避免 panel-pass 顺手把假日期写进流量头
  EXPIRE_VALUE="${EXPIRE_AT:-}"
  SUB_HOST="${SUB_HOST:-${PUBLIC_IP:-127.0.0.1}}"
  hydrate_legacy_runtime_state
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  local login_file="$WWW${PANEL_PATH%.html}-login.html"
  local panel_file="$WWW$PANEL_PATH" state_bak nginx_was_active=0
  mkdir -p "$(dirname "$PANEL_MAP")" || die "无法创建 panel-pass 状态目录"
  state_bak="$(mktemp -d "$(dirname "$PANEL_MAP")/.panel-pass-backup.XXXXXX")" || die "无法创建 panel-pass 回滚目录"
  snapshot_files "$state_bak" "$PANEL_MAP" "$login_file" "$panel_file" "$NGINX_CONF" "$NGINX_SNIPPET" "$NGINX_MAIN" "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF" \
    || { rm -rf "$state_bak"; die "无法备份现有看板/Nginx 状态"; }
  systemctl is-active --quiet nginx 2>/dev/null && nginx_was_active=1 || true
  _rollback_panel_pass() {
    local rollback_rc=0
    restore_files "$state_bak" "$PANEL_MAP" "$login_file" "$panel_file" "$NGINX_CONF" "$NGINX_SNIPPET" "$NGINX_MAIN" "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF" || rollback_rc=1
    if nginx -t >/dev/null 2>&1; then
      if [ "$nginx_was_active" = 1 ]; then systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || rollback_rc=1; fi
    else
      rollback_rc=1
    fi
    if [ "$rollback_rc" -eq 0 ]; then
      rm -rf "$state_bak"
    else
      err "看板认证回滚不完整，备份保留在: $state_bak"
    fi
    return "$rollback_rc"
  }
  if [ "${1:-}" = "off" ]; then
    rm -f "$PANEL_MAP"
    if ! write_panel_files || ! config_nginx; then _rollback_panel_pass || true; die "关闭看板登录失败，已尝试恢复旧认证状态"; fi
    rm -rf "$state_bak"
    ok "已关闭看板页登录(恢复为随机路径直达)。"
    return 0
  fi
  local pass="${1:-}"
  [ -n "$pass" ] || die "用法: bash install.sh panel-pass <密码>   (关闭: panel-pass off)"
  # 密码会进 cookie 和 nginx map, 限安全字符集(免转义/免 cookie 截断); 长度 >=6
  # nginx map 字符串匹配大小写不敏感(官方: strings are matched ignoring the case), 故限小写,
  # 免得大写密码被误以为区分大小写、实际白丢这部分熵。免转义/免 cookie 截断字符集。
  case "$pass" in '~'*|default|hostnames|volatile|include|*[!a-z0-9._~-]*) rm -rf "$state_bak"; die "密码不能以 ~ 开头或使用 nginx map 保留字，只允许小写字母/数字/. _ ~ -(例: openssl rand -hex 12)";; esac
  [ "${#pass}" -ge 6 ] || { rm -rf "$state_bak"; die "密码至少 6 位(建议 openssl rand -hex 12)"; }
  # nginx map 片段: 校验 cookie sbauth 是否等于密码。600 root —— 由 nginx master(root)加载, 密码从不下发浏览器。
  atomic_write_file "$PANEL_MAP" 600 <<EOF || { rm -rf "$state_bak"; die "写入看板密码 map 失败"; }
map \$cookie_sbauth \$sb_ok {
    default 0;
    "$pass" 1;
}
EOF
  chown root:root "$PANEL_MAP" 2>/dev/null || true; chmod 600 "$PANEL_MAP"
  if ! write_panel_files || ! config_nginx; then _rollback_panel_pass || true; die "设置看板登录失败，已尝试恢复旧认证状态"; fi
  rm -rf "$state_bak"
  ok "看板页已加密码登录(自定义登录页 + nginx 服务端校验)。"
  echo "  打开 $(subscription_url "$PANEL_PATH") 会先跳到登录页, 输入你设的密码即可。"
  note "登录是 cookie==密码、nginx 服务端校验(密码只存 600 root 的 $PANEL_MAP, 不下发浏览器)。明文 HTTP 下 cookie 不加密(同网段可嗅探), 只挡'知道链接的人'; 要真加密走 HTTPS(CF Tunnel)。"
  note "无登录限速, 请用强密码。$PANEL_MAP / 登录页不随 backup 迁移, 换机后重跑 panel-pass。"
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

do_admin() {
  [ -f "$SECRETS" ] || die "请先安装(bash install.sh)再开管理面板"
  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  command -v python3   >/dev/null 2>&1 || die "需要 python3"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi

  if [ "${1:-}" = "off" ]; then
    systemctl disable --now singbox-admin >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/singbox-admin.service "$ADMIN_PY" "$ADMIN_HTML" "$ADMIN_ENV" "$ADMIN_INSTALL" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "管理面板已停止并移除(install.sh 副本、token、服务都清掉了)"
    return 0
  fi

  [ -n "${SUB_HOST:-}" ] || { SOFT_DETECT=1 detect_net; SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"; }
  # token + 端口(复用已有 token, 避免每次换)
  if [ -f "$ADMIN_ENV" ]; then load_admin_env || die "管理面板状态文件格式非法: $ADMIN_ENV"; fi
  local token; token="${ADMIN_TOKEN:-$(openssl rand -hex 24)}"
  atomic_write_file "$ADMIN_ENV" 600 <<EOF || die "写入管理面板状态失败"
ADMIN_TOKEN=$token
ADMIN_PORT=$ADMIN_PORT
EOF

  # 后端要调用的 install.sh 副本: 优先复制自身, 管道运行(curl|bash)则从仓库下载
  local self; self="$(readlink -f "$0" 2>/dev/null || true)"
  if [ -n "$self" ] && [ -f "$self" ]; then cp -f "$self" "$ADMIN_INSTALL"
  else log "当前是管道运行, 从仓库拉一份 install.sh 给后端用..."; curl -fsSL "$ADMIN_RAW_URL" -o "$ADMIN_INSTALL" || die "无法获取 install.sh 副本"; fi
  chmod 700 "$ADMIN_INSTALL"

  render_admin_html >"$ADMIN_HTML"; chmod 600 "$ADMIN_HTML"
  write_admin_py
  "$PY" -m py_compile "$ADMIN_PY" || die "管理后端 python 语法错误(不应发生, 请反馈)"

  cat >/etc/systemd/system/singbox-admin.service <<EOF
[Unit]
Description=sing-box admin panel (localhost only, token auth)
After=network.target
[Service]
ExecStart=$(command -v python3) $ADMIN_PY
Restart=on-failure
NoNewPrivileges=no
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now singbox-admin >/dev/null 2>&1 || die "管理面板服务启动失败(看 journalctl -u singbox-admin)"
  systemctl is-active singbox-admin >/dev/null 2>&1 || die "管理面板未在运行(看 journalctl -u singbox-admin)"

  ok "管理面板已启动(仅监听 127.0.0.1:$ADMIN_PORT, 不暴露公网)"
  echo
  echo "  ① 在你【本机电脑】开 SSH 隧道:"
  echo "       ssh -L $ADMIN_PORT:127.0.0.1:$ADMIN_PORT root@${SUB_HOST:-你的服务器IP}"
  echo "  ② 浏览器打开(带 token):"
  echo "       http://127.0.0.1:$ADMIN_PORT/?token=$token"
  echo
  warn "Token 等于管理密码, 别外泄。这个端口已绑 127.0.0.1, 绝不要改成 0.0.0.0 暴露公网。关闭: bash install.sh admin off"
}

do_backup() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  # 自定义订阅证书名存在 env 里; best-effort 读出来, 否则备份会漏掉非默认名的证书。
  if [ -f "$ENVFILE" ]; then load_node_env 2>/dev/null || warn "运行参数文件无法解析, 自定义订阅证书可能未打包"; fi
  local bf="${BACKUP_DIR:-/root}/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz" f files=""
  for f in "$SECRETS" "$ENVFILE" "$WARP_ENV" "$SB_DIR/server.crt" "$SB_DIR/server.key" "$(sub_cert_file)" "$(sub_key_file)"; do
    [ -f "$f" ] && files="$files $f"
  done
  # shellcheck disable=SC2086
  ( umask 077; tar czf "$bf" $files 2>/dev/null ) || die "打包失败"
  chmod 600 "$bf"
  ok "备份已生成: $bf"
  echo "  含: 密钥 / 运行参数 / WARP状态 / 自签证书 / 可选订阅证书 —— 足以在新机重建同一套节点(凭证不变)。"
  echo "  迁移到新 VPS:  1) scp 过去   2) 新机上 bash install.sh restore $bf"
  warn "此文件含全部凭证, 妥善保管、别外传。"
}

do_restore() {
  local bf="${1:-}"
  [ -n "$bf" ] || die "用法: install.sh restore <备份文件.tar.gz>"
  [ -f "$bf" ] || die "找不到备份文件: $bf"
  command -v tar >/dev/null 2>&1 || die "缺 tar(先 apt install -y tar)"
  log "恢复备份(先校验成员, 再解包)..."
  # 安全护栏: 以 root 解任意 tar 到 / 风险高(传错文件/恶意包可覆盖系统文件)。
  # 解包前先白名单校验: 只接受普通文件/目录, 拒绝符号/硬链接、绝对路径、.. 路径, 以及预期之外的成员。
  tar tzvf "$bf" >/dev/null 2>&1 || die "无法读取备份内容(文件损坏或不是 tar.gz?): $bf"
  if tar tzvf "$bf" 2>/dev/null | awk 'NF && substr($0,1,1)!~/[-d]/{bad=1} END{exit !bad}'; then
    die "备份含非普通文件成员(符号/硬链接/设备等), 拒绝恢复(可能指向系统文件)"
  fi
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case "$m" in
      /*|*..*) die "备份含危险路径(绝对路径或 ..), 拒绝恢复: $m" ;;
      etc/sing-box/|etc/sing-box/*|etc/sing-box-node.env) ;;   # 与 do_backup 打包的成员一致
      *) die "备份含预期之外的成员, 拒绝恢复(可能不是本脚本的备份): $m" ;;
    esac
  done < <(tar tzf "$bf" 2>/dev/null)
  RESTORE_TX_STAGE="$(mktemp -d)" || die "无法创建恢复暂存目录"
  tar xzf "$bf" -C "$RESTORE_TX_STAGE" 2>/dev/null || { rm -rf "$RESTORE_TX_STAGE"; RESTORE_TX_STAGE=""; die "解包失败(文件损坏?)"; }

  local restore_root_prefix="${RESTORE_ROOT%/}" rel
  _restore_rel() {
    local path="$1"
    if [ "$RESTORE_ROOT" = / ]; then
      printf '%s' "${path#/}"
    elif [[ "$path" == "$restore_root_prefix/"* ]]; then
      printf '%s' "${path#"$restore_root_prefix/"}"
    else
      return 1
    fi
  }
  rel="$(_restore_rel "$SECRETS")" || { rm -rf "$RESTORE_TX_STAGE"; RESTORE_TX_STAGE=""; die "密钥路径不在 RESTORE_ROOT 内: $SECRETS"; }
  [ -f "$RESTORE_TX_STAGE/$rel" ] || { rm -rf "$RESTORE_TX_STAGE"; RESTORE_TX_STAGE=""; die "备份里没有密钥文件, 无法恢复"; }

  mkdir -p "$SB_DIR" || { rm -rf "$RESTORE_TX_STAGE"; RESTORE_TX_STAGE=""; die "无法创建 sing-box 状态目录"; }
  RESTORE_TX_BACKUP="$(mktemp -d "$SB_DIR/.restore-backup.XXXXXX")" || { rm -rf "$RESTORE_TX_STAGE"; RESTORE_TX_STAGE=""; die "无法创建 restore 回滚目录"; }
  # 备份里的 env 可能指向 /etc/sing-box/ 下的自定义证书名。恢复目标必须在发布前按备份内容
  # 重定向, 否则 restore 只恢复默认 sub.crt/key, 自定义证书会被漏掉(甚至被 publish "-" 删掉)。
  local staged_env="$RESTORE_TX_STAGE/etc/sing-box-node.env" _sc="" _sk=""
  if [ -f "$staged_env" ]; then
    _sc="$(sed -n 's/^SUB_CERT=//p' "$staged_env" | head -n1 | tr -d '\r')"
    _sk="$(sed -n 's/^SUB_KEY=//p'  "$staged_env" | head -n1 | tr -d '\r')"
    _sc="${_sc#\"}"; _sc="${_sc%\"}"; _sk="${_sk#\"}"; _sk="${_sk%\"}"
    if [ -n "$_sc" ] && valid_state_value SUB_CERT "$_sc"; then SUB_CERT="$SB_DIR/${_sc#/etc/sing-box/}"; fi
    if [ -n "$_sk" ] && valid_state_value SUB_KEY  "$_sk"; then SUB_KEY="$SB_DIR/${_sk#/etc/sing-box/}"; fi
  fi
  RESTORE_TX_TARGETS=("$SECRETS" "$ENVFILE" "$WARP_ENV" "$SB_DIR/server.crt" "$SB_DIR/server.key" "$(sub_cert_file)" "$(sub_key_file)")
  snapshot_files "$RESTORE_TX_BACKUP" "${RESTORE_TX_TARGETS[@]}" || { rm -rf "$RESTORE_TX_STAGE" "$RESTORE_TX_BACKUP"; RESTORE_TX_STAGE=""; RESTORE_TX_BACKUP=""; die "无法备份恢复前状态"; }
  RESTORE_TX_OLD_SINGBOX_ACTIVE=0; RESTORE_TX_OLD_NGINX_ACTIVE=0; RESTORE_TX_ROLLBACK_STARTED=0
  systemctl is-active --quiet sing-box 2>/dev/null && RESTORE_TX_OLD_SINGBOX_ACTIVE=1 || true
  systemctl is-active --quiet nginx 2>/dev/null && RESTORE_TX_OLD_NGINX_ACTIVE=1 || true
  _rollback_restore() {
    [ "$RESTORE_TX_ROLLBACK_STARTED" = 0 ] || return 1
    RESTORE_TX_ROLLBACK_STARTED=1
    local rollback_rc=0
    restore_files "$RESTORE_TX_BACKUP" "${RESTORE_TX_TARGETS[@]}" || rollback_rc=1
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$RESTORE_TX_OLD_SINGBOX_ACTIVE" = 1 ]; then
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
      systemctl restart sing-box >/dev/null 2>&1 || rollback_rc=1
      systemctl is-active --quiet sing-box >/dev/null 2>&1 || rollback_rc=1
    else
      systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    if [ "$RESTORE_TX_OLD_NGINX_ACTIVE" = 1 ]; then
      nginx -t >/dev/null 2>&1 || rollback_rc=1
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || rollback_rc=1
    else
      systemctl stop nginx >/dev/null 2>&1 || true
    fi
    if [ "$rollback_rc" -eq 0 ]; then rm -rf "$RESTORE_TX_BACKUP"; RESTORE_TX_BACKUP=""; else err "restore 回滚不完整，备份保留在: $RESTORE_TX_BACKUP"; fi
    return "$rollback_rc"
  }

  _restore_exit_trap() {
    local rc=$?
    trap - EXIT
    [ -n "$RESTORE_TX_STAGE" ] && rm -rf "$RESTORE_TX_STAGE"
    RESTORE_TX_STAGE=""
    if [ "$rc" -ne 0 ]; then _rollback_restore || true; fi
    exit "$rc"
  }
  trap '_restore_exit_trap' EXIT

  local target source tmp
  local -a restore_publish=() restore_tmps=()
  for target in "${RESTORE_TX_TARGETS[@]}"; do
    rel="$(_restore_rel "$target")" || die "恢复目标不在 RESTORE_ROOT 内: $target"
    source="$RESTORE_TX_STAGE/$rel"
    mkdir -p "$(dirname "$target")" || die "无法创建恢复目标目录"
    if [ -f "$source" ]; then
      tmp="$(mktemp "$(dirname "$target")/.restore-stage.XXXXXX")" || die "无法创建恢复临时文件"
      rm -f "$tmp"
      cp -a "$source" "$tmp" || { rm -f "$tmp"; die "暂存恢复文件失败: $target"; }
      restore_tmps+=("$tmp")
      restore_publish+=("$tmp" "$target")
    else
      restore_publish+=("-" "$target")
    fi
  done
  publish_files_transaction "${restore_publish[@]}" || { rm -f "${restore_tmps[@]}"; die "提交恢复状态文件组失败"; }
  rm -rf "$RESTORE_TX_STAGE"
  RESTORE_TX_STAGE=""

  # 载入用户偏好(限额/到期/计费); 机器相关(IP/网卡/订阅host)清空让新机重新探测。
  # 状态文件只能按字面量解析，备份内的 KEY=VALUE 绝不能作为 root shell 执行。
  if [ -f "$ENVFILE" ]; then load_node_env || die "备份中的运行参数文件格式非法: $ENVFILE"; fi
  INTERFACE=""; PUBLIC_IP=""; SUB_HOST=""
  # 旧备份里的 cf.env 不会恢复: CF-VLESS 一键路径已下线, 换机后不再重建 cloudflared。
  if [ -f "$CF_ENV" ] || [ -f "$CF_PENDING_ENV" ]; then
    note "检测到旧 CF-VLESS 状态: 该路径已下线, 不会进入订阅; 如确认不再使用可运行 'install.sh cf off' 清理。"
  fi
  ok "凭证已就位, 按新机重建(IP/网卡自动适配; 用域名的话加 DOMAIN= 重跑或重指 DNS)..."
  local install_rc had_errexit=0
  case $- in *e*) had_errexit=1 ;; esac
  set +e
  ( trap - EXIT; set -eEuo pipefail; RESTORING=1 do_install )
  install_rc=$?
  if [ "$had_errexit" = 1 ]; then set -e; else set +e; fi
  [ "$install_rc" -eq 0 ] || die "按新机重建失败，正在恢复迁移前状态"
  trap - EXIT
  rm -rf "$RESTORE_TX_BACKUP" || warn "恢复成功，但临时备份目录未能删除: $RESTORE_TX_BACKUP"
  RESTORE_TX_BACKUP=""; RESTORE_TX_TARGETS=(); RESTORE_TX_ROLLBACK_STARTED=0
}

do_harden() {
  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  detect_os   # 设 PKG, 装 fail2ban 用
  local akeys="$AKEYS"
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
  mkdir -p "$SSHD_DROPIN_DIR"
  local dropin="$SSHD_DROPIN_DIR/00-singbox-harden.conf"
  cat >"$dropin" <<'EOF'
# sing-box-oneclick SSH 加固(文件名 00- 排最前, 覆盖 50-cloud-init 的 PasswordAuthentication yes)
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  local bak=""
  if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_CONFIG"; then
    warn "sshd_config 无 Include sshd_config.d/, drop-in 可能不生效; 直接改主文件兜底..."
    local kv key; bak="$SSHD_CONFIG.singbox-bak.$(date +%s)"; cp -a "$SSHD_CONFIG" "$bak"
    for kv in "PasswordAuthentication no" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no"; do
      key="${kv%% *}"
      if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}\b" "$SSHD_CONFIG"; then
        sed -i "s|^[[:space:]]*#\?[[:space:]]*${key}\b.*|${kv}|I" "$SSHD_CONFIG"
      else
        printf '%s\n' "$kv" >> "$SSHD_CONFIG"
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
    [ -n "$bak" ] && cp -a "$bak" "$SSHD_CONFIG"   # 兜底分支改过主文件, 校验不过要一并还原
    die "sshd 配置校验(sshd -t)未过, 已回滚(drop-in + 主文件), 未改动 SSH"
  fi
}

do_status() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  if [ -f "$WARP_ENV" ]; then load_warp_env || die "WARP 状态文件格式非法: $WARP_ENV"; fi
  echo "===== 服务 ====="
  local s
  for s in sing-box nginx vnstat cron; do
    printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo inactive)"
  done
  echo "===== 配置校验 ====="
  sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1 && echo "  sing-box: OK" || echo "  sing-box: FAIL (跑 sing-box check -c $SB_DIR/config.json 看详情)"
  nginx -t >/dev/null 2>&1 && echo "  nginx:    OK" || echo "  nginx:    FAIL (跑 nginx -t 看详情)"
  echo "===== 本地端口监听(不代表外部可达, 云安全组另算) ====="
  ss -lntup 2>/dev/null | grep -E ":($HY2_PORT|$ANYTLS_PORT|$SS_PORT|80|443)\b" || echo "  (无匹配)"
  echo "===== 其它 ====="
  printf '  时间同步 NTPSynchronized = %s\n' "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  [ -f "$SB_DIR/server.crt" ] && printf '  自签证书 %s\n' "$(openssl x509 -enddate -noout -in "$SB_DIR/server.crt" 2>/dev/null)"
  printf '  订阅传输: %s\n' "$(subscription_tls_enabled && echo '443 HTTPS' || echo '80 HTTP')"
  printf '  限额 %s GB | 计费 %s | 到期 %s\n' "${LIMIT_GB:-?}" "${COUNT_MODE:-?}" "${EXPIRE_AT:-?}"
  [ -n "$WARP_PRIVATE_KEY" ] && printf '  WARP 解锁分流: 已开 (OpenAI/Netflix/Disney 走 WARP; 关闭: install.sh warp off)\n'
  if [ -f /etc/systemd/system/singbox-admin.service ]; then
    local ap=8088
    if [ -f "$ADMIN_ENV" ]; then load_admin_env || die "管理面板状态文件格式非法: $ADMIN_ENV"; ap="${ADMIN_PORT:-8088}"; fi
    printf '  网页管理面板: %s (127.0.0.1:%s; 取访问方式: install.sh admin)\n' "$(systemctl is-active singbox-admin 2>/dev/null || echo inactive)" "$ap"
  fi
  # 同 doctor: 不带 Host 会命中默认 server 得到 404, 让健康机看起来像订阅坏了
  local probe_scheme=http; local -a probe_extra=()
  if subscription_tls_enabled; then probe_scheme=https; probe_extra=(-k); fi
  curl -s -o /dev/null "${probe_extra[@]}" -H "Host: $(url_host "$SUB_HOST")" -w "  订阅本地可达: $probe_scheme %{http_code}\n" "$probe_scheme://127.0.0.1${SUB_PATH}" 2>/dev/null || echo "  订阅本地探测失败"
  echo "  本月流量明细见: install.sh info  /  journalctl -t traffic_limit -n 20"
}

do_doctor() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  if [ -f "$WARP_ENV" ]; then load_warp_env || die "WARP 状态文件格式非法: $WARP_ENV"; fi
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
  for s in vnstat cron; do   # 流量统计/限流依赖, 挂了降级为警告(部分系统服务名为 vnstatd/crond)
    [ "$(systemctl is-active "$s" 2>/dev/null)" = active ] && P "$s 运行中" || W "$s 未运行(流量统计/限流依赖它): systemctl status $s"
  done
  # 光看 vnstat/cron active 不够: 网卡改名/vnstat 库重置后, traffic_limit.py 会因取不到
  # $INTERFACE 数据而提前 exit, 流量头永远停在 download=0、配额停机静默失效, 而上面两条依然全绿。
  if command -v vnstat >/dev/null 2>&1 && [ -n "${INTERFACE:-}" ]; then
    if vnstat --json 2>/dev/null | grep -q "\"name\":\"$INTERFACE\""; then
      P "vnstat 已采集网卡 $INTERFACE"
    else
      W "vnstat 里没有网卡 $INTERFACE 的数据: 流量统计/配额停机会静默失效。核对 'ip -br link' 后用 'install.sh set INTERFACE=真实网卡' 修正"
    fi
  fi
  if [ -f "$TRAFFIC_PY" ]; then
    if "$PY" "$TRAFFIC_PY" >/dev/null 2>&1; then P "限流脚本可正常执行(流量头已刷新)"
    else W "限流脚本执行失败: 'journalctl -t traffic_limit -n 20' 看原因(多为 INTERFACE 不对或 vnstat 无数据)"; fi
  fi
  # 2) 配置校验
  sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1 && P "sing-box 配置校验通过" || F "sing-box 配置无效: sing-box check -c $SB_DIR/config.json"
  nginx -t >/dev/null 2>&1 && P "nginx 配置校验通过" || F "nginx 配置无效: nginx -t"
  # 3) 网络优化(HY2/QUIC 关键)
  local rmem cc; rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  { [ "${rmem:-0}" -ge 16777216 ] 2>/dev/null && P "UDP 缓冲 rmem_max=$rmem (≥16MB, 利于 HY2)"; } || W "UDP 缓冲 rmem_max=$rmem <16MB: HY2 吞吐受限, 重跑 install 或 sysctl --system"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo)"
  [ "$cc" = bbr ] && P "拥塞控制 = bbr" || W "拥塞控制 = ${cc:-未知}(非 bbr): 重跑 install 开 BBR"
  # 4) 端口本地监听
  # ENABLE_HY2=0 时 HY2_PORT 本就不该监听, 不能当成故障报出来
  local p miss=0 want="$SS_PORT 80"
  [ "$ENABLE_HY2" = 1 ] && want="$HY2_PORT $want"
  [ "$ANYTLS_OK" = 1 ] && want="$ANYTLS_PORT $want"
  subscription_tls_enabled && want="$want 443"
  for p in $want; do
    ss -lntuH 2>/dev/null | grep -qE "[:.]$p\b" || { W "端口 $p 本地未监听"; miss=1; }
  done
  [ "$miss" = 0 ] && P "节点端口本地监听正常 ($(printf '%s' "$want" | tr ' ' '/'))"
  # 5) 防火墙 / 安全组(头号坑)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    W "ufw 已启用: 确认放行 $ANYTLS_PORT/tcp、$SS_PORT/tcp(+udp)、80/tcp$([ "$ENABLE_HY2" = 1 ] && printf '、%s/udp' "$HY2_PORT")$(subscription_tls_enabled && printf '、443/tcp')"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    W "firewalld 已启用: 确认放行对应端口(含 UDP)"
  else
    P "未检测到本机防火墙(ufw/firewalld)启用"
  fi
  W "云厂商安全组要在控制台单独放行——HY2 是 UDP, 最容易漏放 UDP 端口!"
  # 6) 时间同步(TLS 敏感)
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && P "系统时间已同步" || W "系统时间未同步: timedatectl set-ntp true"
  # 7) 证书到期
  if [ -f "$SB_DIR/server.crt" ]; then
    openssl x509 -checkend $((30*86400)) -noout -in "$SB_DIR/server.crt" >/dev/null 2>&1 && P "自签证书 30 天内不过期" || W "自签证书 30 天内将过期: 重跑 install 重新生成"
  fi
  if [ -f "$(sub_cert_file)" ] && [ -f "$(sub_key_file)" ]; then
    openssl x509 -checkend $((30*86400)) -noout -in "$(sub_cert_file)" >/dev/null 2>&1 && P "订阅证书 30 天内不过期" || W "订阅证书 30 天内将过期: 续期后重跑 install"
    subscription_tls_enabled || W "订阅证书已就位但 DOMAIN 为空: 443 HTTPS 未启用"
  elif [ "$SUB_TLS" = 1 ]; then
    W "SUB_TLS=1 但订阅证书缺失: $(sub_cert_file) / $(sub_key_file)"
  fi
  # 8) 订阅可达
  # 必须带 Host: 订阅 server 绑的是 server_name $SUB_HOST, 不带 Host 会命中默认 server(return 404),
  # 于是每台完全正常的机器都会被报成"订阅本机不可达", 真故障反而被这条噪声淹没。
  local probe_scheme=http; local -a probe_extra=(-fsS)
  if subscription_tls_enabled; then probe_scheme=https; probe_extra+=(-k); fi
  curl "${probe_extra[@]}" -o /dev/null -m 5 -H "Host: $(url_host "$SUB_HOST")" "$probe_scheme://127.0.0.1$SUB_PATH" 2>/dev/null \
    && P "订阅本机可达($probe_scheme)" \
    || F "订阅本机不可达: 看 nginx -t / $WWW 权限(若手改过 server_name, Host 不匹配也会 404)"
  if [ -n "${PUBLIC_IP:-}" ]; then
    curl -fsS -o /dev/null -m 6 "$(subscription_url "$SUB_PATH")" 2>/dev/null && P "订阅经公网可达" \
      || W "订阅经公网不可达(可能是 hairpin 不支持, 不一定是真问题): 用手机流量/外部网络测 $(subscription_url "$SUB_PATH")"
  fi
  # 9) 可选组件
  if [ -f "$CF_ENV" ]; then W "检测到旧版 CF-VLESS 状态($CF_ENV): 该路径已下线, 可运行 'install.sh cf off' 清理"; fi
  if [ -f "$PORTHOP_SERVICE" ]; then W "检测到旧版 HY2 端口跳跃服务: 重跑 install 会自动清理"; fi
  [ -n "${WARP_PRIVATE_KEY:-}" ] && P "WARP 解锁分流已配置(站点: ${WARP_SITES:-$WARP_DEFAULT_SITES})"
  if [ -f /etc/systemd/system/singbox-admin.service ]; then
    { [ "$(systemctl is-active singbox-admin 2>/dev/null)" = active ] && P "网页管理面板运行中(仅 127.0.0.1)"; } || W "网页管理面板服务未运行: journalctl -u singbox-admin"
  fi
  # 10) 低配/负载体检("服务 active 但节点像挂了" 多半在这里)
  local mem_a mem_t sw iowait dproc
  mem_a="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  mem_t="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  [ -n "$mem_a" ] && { { [ "$mem_a" -ge 150 ] 2>/dev/null && P "可用内存 ${mem_a}MB / ${mem_t}MB"; } || W "可用内存仅 ${mem_a}MB: 低配机建议加 1G swap(日志已默认 warn)"; }
  sw="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  { [ "${sw:-0}" -gt 0 ] 2>/dev/null && P "swap ${sw}MB"; } || W "无 swap: 低内存机有 OOM 风险, 建议加 1G swap"
  if [ -r /proc/pressure/io ]; then
    iowait="$(awk -F'[=. ]' '/^some/{print $3; exit}' /proc/pressure/io 2>/dev/null)"
    { [ "${iowait:-0}" -lt 20 ] 2>/dev/null && P "I/O 压力 some avg10≈${iowait:-0}%(正常)"; } || W "I/O 压力高(some avg10≈${iowait}%): 磁盘/日志在拖系统, SSH/sing-box 会像卡死; 降日志、停非必要常驻服务"
  fi
  dproc="$(ps -eo stat= 2>/dev/null | grep -c '^D' || true)"
  { [ "${dproc:-0}" -eq 0 ] 2>/dev/null && P "无 D(不可中断 IO)状态进程"; } || W "$dproc 个进程处于 D 状态(IO 卡住): ps -eo pid,stat,wchan:20,comm | awk '\$2~/D/'"
  echo "======================================="
  { [ "$issues" = 0 ] && ok "全部检查通过 ✓"; } || warn "$issues 项需关注(见上面 ! / ✗)"
}

do_set() {
  [ -f "$ENVFILE" ] || die "未检测到安装(缺 $ENVFILE)"
  [ "$#" -ge 1 ] || die "用法: install.sh set KEY=VAL ...  (可改 LIMIT_GB / EXPIRE_AT / COUNT_MODE / INTERFACE / SUB_TLS)"
  if [ -f "$SECRETS" ]; then load_secrets || die "密钥文件格式非法: $SECRETS"; fi
  load_node_env || die "运行参数文件格式非法: $ENVFILE"
  if [ -f "$WARP_ENV" ]; then load_warp_env || die "WARP 状态文件格式非法: $WARP_ENV"; fi
  # 兼容旧 env(可能无 PUBLIC_IP/SUB_HOST): 回填后再让 write_env 重写, 否则会被清空
  [ -n "${PUBLIC_IP:-}" ] || SOFT_DETECT=1 detect_net
  SUB_HOST="${SUB_HOST:-$PUBLIC_IP}"
  hydrate_legacy_runtime_state
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  local tx_bak=""
  local a key val iface_changed=0 nginx_render=0
  for a in "$@"; do
    key="${a%%=*}"; val="${a#*=}"
    [ "$key" != "$a" ] || die "参数要写成 KEY=VAL: $a"
    case "$key" in
      LIMIT_GB)   case "$val" in ''|.|*.*.*|*[!0-9.]*) die "LIMIT_GB 要是数字(如 200 或 0.5): $val";; esac; LIMIT_GB="$val" ;;
      COUNT_MODE) case "$val" in rx+tx|tx|max) COUNT_MODE="$val" ;; *) die "COUNT_MODE 只能 rx+tx/tx/max";; esac ;;
      SUB_TLS)    case "$val" in auto|0|1) SUB_TLS="$val"; nginx_render=1 ;; *) die "SUB_TLS 只能 auto / 1 / 0";; esac ;;
      INTERFACE)  [ -n "$val" ] || die "INTERFACE 不能空"
                  # 校验网卡真实存在: 打错名字会让 vnstat 取不到数据, traffic_limit.py 提前退出,
                  # 流量头不更新且配额自动停机静默失效。有 ip 命令时落盘前就拦掉(测试机无 ip 则跳过)。
                  if command -v ip >/dev/null 2>&1; then ip -br link show "$val" >/dev/null 2>&1 || die "网卡不存在: $val(用 ip -br link 查真实名)"; fi
                  INTERFACE="$val"; iface_changed=1 ;;
      EXPIRE_AT)  [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [+-][0-9]{4}$ ]] || die "EXPIRE_AT 格式须为 'YYYY-MM-DD HH:MM:SS +0800'"; EXPIRE_AT="$val" ;;
      HY2_UP_MBPS|HY2_DOWN_MBPS|HY2_UP|HY2_DOWN|HY2_HOP_RANGE)
                  die "$key 已下线(HY2 固定 UDP 443 + 自动拥塞控制), 不能再通过 set 修改" ;;
      *) die "不支持的键: $key (可改 LIMIT_GB / EXPIRE_AT / COUNT_MODE / INTERFACE / SUB_TLS)" ;;
    esac
    ok "set $key=$val"
  done
  # set 的键虽少, 但 SUB_TLS=1 依赖 DOMAIN 与证书、还会与 TCP 443 端口互斥; 改完立即校验,
  # 不合法就别写 env/刷新 nginx(否则会留下一个下次启动才报错的状态)。
  validate_inputs
  mkdir -p "$(dirname "$ENVFILE")" || die "无法创建运行参数目录"
  tx_bak="$(mktemp -d "$(dirname "$ENVFILE")/.set-backup.XXXXXX")" || die "无法创建 set 回滚目录"
  local -a set_paths=("$ENVFILE" "$SB_DIR/config.json" "$NGINX_SNIPPET" "$NGINX_CONF" "$NGINX_MAIN")
  if [ -n "${SUB_PATH:-}" ]; then
    set_paths+=("$WWW$SUB_PATH")
    [ -n "${SUB_B64_PATH:-}" ] && set_paths+=("$WWW$SUB_B64_PATH")
    [ -n "${PANEL_PATH:-}" ] && set_paths+=("$WWW$PANEL_PATH" "$WWW${PANEL_PATH%.html}-login.html")
  fi
  snapshot_files "$tx_bak" "${set_paths[@]}" || { rm -rf "$tx_bak"; die "无法备份 set 相关状态"; }
  _rollback_set() {
    local rollback_rc=0
    restore_files "$tx_bak" "${set_paths[@]}" || rollback_rc=1
    if [ -f "$SB_DIR/config.json" ]; then
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
      systemctl restart sing-box >/dev/null 2>&1 || rollback_rc=1
      systemctl is-active --quiet sing-box >/dev/null 2>&1 || rollback_rc=1
    fi
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || rollback_rc=1
    else
      rollback_rc=1
    fi
    if [ "$rollback_rc" -eq 0 ]; then
      rm -rf "$tx_bak"
    else
      err "set 回滚不完整，备份保留在: $tx_bak"
    fi
    return "$rollback_rc"
  }
  write_env   # 用更新后的全局重写 env(SUB_HOST/PUBLIC_IP 已从 env 读到, 一并保留)
  if [ -n "${SUB_PATH:-}" ]; then
    write_subscription || { _rollback_set; die "刷新订阅/看板失败，已恢复旧状态"; }
  fi
  # SUB_TLS 会改变订阅 URL 的 scheme 与 nginx 监听, 必须重新落 nginx 配置。
  if [ "$nginx_render" = 1 ]; then
    config_nginx || { _rollback_set; die "应用订阅 TLS 配置失败，已恢复旧状态"; }
  fi
  [ -f "$TRAFFIC_PY" ] && { "$PY" "$TRAFFIC_PY" >/dev/null 2>&1 && ok "已刷新订阅流量头(限额/到期即时生效)" || warn "流量头刷新失败, 5 分钟后 cron 会自动重试"; }
  rm -rf "$tx_bak"
  [ "$iface_changed" = 1 ] && warn "网卡已改: 若还有旧版 HY2 端口跳跃残留, 重跑 'bash install.sh' 会一并清理。"
  return 0
}

do_update() {
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  log "更新 sing-box(官方脚本)..."
  curl -fsSL https://sing-box.app/install.sh | sh || die "sing-box 更新失败(网络或官方脚本异常)"
  command -v sing-box >/dev/null 2>&1 || die "sing-box 安装/更新失败"
  ok "sing-box 版本: $(sing-box version 2>/dev/null | awk '/version/{print $3; exit}')"
  if sing-box check -c "$SB_DIR/config.json" >/dev/null 2>&1; then
    systemctl restart sing-box && ok "已重启 sing-box" || die "更新后 sing-box 重启失败, 看 systemctl status sing-box"
  else
    die "更新后配置校验未过, 未重启。请跑 sing-box check -c $SB_DIR/config.json 看详情"
  fi
}

do_restart() {
  local failed=0
  if systemctl restart sing-box 2>/dev/null; then ok "sing-box 已重启"; else err "sing-box 重启失败"; failed=1; fi
  if systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null; then ok "nginx 已重载"; else err "nginx 重载失败"; failed=1; fi
  return "$failed"
}

do_menu() {
  while true; do
    echo
    echo "  ===== sing-box 节点管理 ====="
    echo "  1) 安装 / 重装           2) 查看信息(订阅 URL)"
    echo "  3) 分享链接 / 二维码     4) 状态体检"
    echo "  5) 改参数(限额/到期)     6) 更新 sing-box"
    echo "  7) 重启服务              8) 备份"
    echo "  9) 卸载                  0) 退出"
    echo "  p) 看板页地址            s) 看板加/改登录密码"
    echo "  k) 装 Komari 探针"
    echo "  b) 备份                  r) 恢复(迁移)"
    echo "  h) SSH 加固(密钥登录)    w) WARP 解锁分流"
    echo "  d) doctor 自检(常见坑)   a) 管理面板(localhost)"
    printf '  选择: '
    read -r c || break
    # 每个动作放进 ( ) 子shell 并 || true: 这样某个动作内部 die/exit 只结束该动作,
    # 不会因 set -e 把整个菜单退出。
    case "$c" in
      1) run_menu_action with_maintenance_lock do_install ;;
      2) run_menu_action do_info ;;
      3) run_menu_action do_links ;;
      4) run_menu_action do_status ;;
      5) printf '  输入 KEY=VAL(如 LIMIT_GB=500): '; read -r kv || true
         [ -n "${kv:-}" ] && run_menu_action with_maintenance_lock do_set "$kv" ;;
      6) run_menu_action with_maintenance_lock do_update ;;
      7) run_menu_action with_maintenance_lock do_restart ;;
      8) run_menu_action do_backup ;;
      9) run_menu_action with_maintenance_lock do_uninstall ;;
      p|P) run_menu_action with_maintenance_lock do_panel ;;
      # 看板页含全套节点凭证, 随机路径不是登录保护 —— 菜单里必须能直接加密码,
      # 否则只用菜单的人永远不知道有 panel-pass 这回事, 看板就一直裸着。
      s|S) printf '  设置看板登录密码(留空=随机生成, 输入 off=关闭登录): '; read -r pw || true
           if [ "$pw" = off ]; then run_menu_action with_maintenance_lock do_panel_pass off
           else run_menu_action with_maintenance_lock do_panel_pass "${pw:-$(openssl rand -hex 12)}"; fi ;;
      k|K) printf '  KOMARI_ENDPOINT: '; read -r ke || true; printf '  KOMARI_TOKEN: '; read -r kt || true
            if [ -n "${ke:-}" ] && [ -n "${kt:-}" ]; then run_menu_action env KOMARI_ENDPOINT="$ke" KOMARI_TOKEN="$kt" bash "$0" komari; else echo "  已取消"; fi ;;
      b|B) run_menu_action do_backup ;;
      r|R) printf '  备份文件路径: '; read -r rf || true; [ -n "${rf:-}" ] && run_menu_action with_maintenance_lock do_restore "$rf" ;;
      h|H) run_menu_action with_maintenance_lock do_harden ;;
      w|W) run_menu_action with_maintenance_lock do_warp ;;
      d|D) run_menu_action do_doctor ;;
      a|A) run_menu_action with_maintenance_lock do_admin ;;
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
  # 自定义订阅证书名记在 env 里; best-effort 读出来, 卸载时才能一并清掉。
  if [ -f "$ENVFILE" ]; then load_node_env 2>/dev/null || true; fi
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  if [ -f "$SECRETS" ] && ! load_secrets; then warn "密钥文件格式非法, 将按通配路径清理订阅/看板文件"; fi
  rm -f "$SB_DIR/config.json" "$SB_DIR/server.crt" "$SB_DIR/server.key" "$(sub_cert_file)" "$(sub_key_file)" "$SECRETS" 2>/dev/null || true
  rm -f "$ENVFILE" "$TRAFFIC_PY" "$CRON" "$NGINX_SNIPPET" "$NGINX_CONF" 2>/dev/null || true
  [ -n "${SUB_PATH:-}" ] && rm -f "$WWW$SUB_PATH" 2>/dev/null || true
  [ -n "${SUB_B64_PATH:-}" ] && rm -f "$WWW$SUB_B64_PATH" 2>/dev/null || true
  [ -n "${PANEL_PATH:-}" ] && rm -f "$WWW$PANEL_PATH" "$WWW${PANEL_PATH%.html}-login.html" 2>/dev/null || true
  rm -f "$PANEL_MAP" 2>/dev/null || true   # 看板页登录: nginx map 密码片段
  rm -f "$WWW"/sub-*.yaml "$WWW"/sub-b64-*.txt "$WWW"/panel-*.html 2>/dev/null || true   # 兜底: 即使 secrets 丢失也清掉含凭证的订阅/看板文件
  rm -f /var/lib/sing-box-node/quota-stopped /run/sing-box-quota-stopped 2>/dev/null || true
  rm -f "$WARP_ENV" 2>/dev/null || true   # WARP 分流状态(wgcf 二进制保留, 无害)
  if [ -f /etc/systemd/system/singbox-admin.service ]; then   # 管理面板
    systemctl disable --now singbox-admin >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/singbox-admin.service "$ADMIN_PY" "$ADMIN_HTML" "$ADMIN_ENV" "$ADMIN_INSTALL" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if [ -f "$CF_ENV" ]; then
    cloudflared service uninstall >/dev/null 2>&1 || systemctl disable --now cloudflared >/dev/null 2>&1 || true
    rm -f "$CF_ENV" "$CF_PENDING_ENV" 2>/dev/null || true
    warn "已停止旧版 cf 子命令装的 cloudflared(CF 后台那条 Tunnel 需你自行删除)"
  else
    warn "未触碰 cloudflared(若你手动搭过 CF, 请自行处理 /etc/cloudflared, 凭证别误删)"
  fi
  if [ -f "$PORTHOP_SERVICE" ]; then
    systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
    rm -f "$PORTHOP_SERVICE" "$SB_DIR/porthop.nft" 2>/dev/null || true
    command -v nft >/dev/null 2>&1 && nft delete table inet sb_hophy2 >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  ok "已卸载(保留 sing-box 程序与网络优化 sysctl; 备份见上)"
}

# 用已校验通过的临时配置替换正式 config 并重启 sing-box; 重启失败则回滚旧配置并拉回旧服务。
# 用法: apply_singbox_config <临时配置文件>  返回 0=成功切到新配置 / 1=已回滚(调用方仍需自行 rm 临时文件)。
# 仅校验通过(sing-box check)还不够: 端口被占、运行时环境或 systemd 问题都可能让 restart 失败,
# 那时不回滚就会把原本可用的节点留在新配置/停服状态。
apply_singbox_config() {
  local newc="$1" bak=""
  [ -f "$newc" ] || { err "待应用的 sing-box 配置不存在: $newc"; return 1; }
  mkdir -p "$SB_DIR" || return 1
  if [ -f "$SB_DIR/config.json" ]; then
    bak="$(mktemp "$SB_DIR/.config-backup.XXXXXX")" || return 1
    if ! cp -a "$SB_DIR/config.json" "$bak"; then rm -f "$bak"; return 1; fi
  fi
  if ! install -m600 "$newc" "$SB_DIR/config.json"; then rm -f "$bak"; return 1; fi
  if systemctl restart sing-box; then
    [ -n "$bak" ] && rm -f "$bak"
    return 0
  fi
  warn "sing-box 重启失败, 回滚到旧配置并拉回旧服务..."
  if [ -n "$bak" ]; then
    if ! install -m600 "$bak" "$SB_DIR/config.json"; then
      err "回滚旧 sing-box 配置失败，备份保留在 $bak"
      return 1
    fi
    systemctl reset-failed sing-box >/dev/null 2>&1 || true   # 清掉 failed 状态, 否则 restart 可能不动
    systemctl restart sing-box >/dev/null 2>&1 || true
    # 回滚后必须确认旧配置真的起来了; 否则别让调用方误报"节点不受影响"
    if systemctl is-active --quiet sing-box; then
      rm -f "$bak"
    else
      err "回滚后 sing-box 仍未运行! 配置备份保留在 $bak；手动查: systemctl status sing-box"
    fi
  else
    rm -f "$SB_DIR/config.json"
  fi
  return 1
}

# CF-VLESS 一键路径已于 2026-10 下线(现网只保留经验证的自有 CF WebSocket 节点, 由现网事务工具维护)。
# 这里只保留清理入口, 避免老机器留下无人管理的 cloudflared 服务与状态文件。
do_cf() {
  if [ "${1:-}" != "off" ]; then
    cat <<EOF
CF-VLESS 一键安装路径已下线(2026-10 现网口径):
  直连 VLESS/Reality 与旧 CF-VLESS 已退休; 节点只保留 Hysteria2 / AnyTLS / SS2022。
  现网如仍需 CF WebSocket 节点, 由各自 Tunnel 与自有域名单独维护, 不再走本脚本。

清理老机器上由旧版 cf 子命令安装的 cloudflared 与状态:
  bash install.sh cf off
EOF
    return 0
  fi
  [ -f "$SECRETS" ] || die "未检测到安装(缺 $SECRETS)"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  local had=0
  if [ -f "$CF_ENV" ] || [ -f "$CF_PENDING_ENV" ]; then had=1; fi
  if ! command -v cloudflared >/dev/null 2>&1 && [ "$had" = 0 ]; then ok "没有检测到旧 CF-VLESS 状态, 无需清理"; return 0; fi
  if ! load_cf_env 2>/dev/null; then CF_HOSTNAME=""; fi
  # 只卸由本脚本 cf.env 记录在案的 cloudflared; 没有 cf.env 时不碰别人的 Tunnel。
  if [ "$had" = 1 ]; then
    log "停止并移除旧版 CF-VLESS 的 cloudflared 服务..."
    cloudflared service uninstall >/dev/null 2>&1 || systemctl disable --now cloudflared >/dev/null 2>&1 || true
    rm -f "$CF_ENV" "$CF_PENDING_ENV" || die "删除旧 CF 状态失败, 请手动检查 $SB_DIR"
  else
    warn "检测到 cloudflared 二进制但没有 cf.env(可能不是本脚本安装), 未改动其服务"
  fi
  # 订阅里已不含 CF 节点; 重生成一次确保面板/订阅与 sing-box 配置一致。
  [ -n "${SUB_PATH:-}" ] && write_subscription || true
  ok "旧 CF-VLESS 状态已清理(Cloudflare 后台的 Tunnel 需你自行删除)"
  [ -n "${SUB_PATH:-}" ] && echo "  订阅已重建: $(subscription_url "$SUB_PATH")"
  return 0
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

parse_wgcf_addresses() {
  local profile="$1" addresses
  # wgcf 当前会把 IPv4 与 IPv6 写在同一个 Address 行，以逗号分隔；先拆分再分别取值，
  # 否则 sing-box 会收到一个含逗号的无效 address 字符串。
  addresses="$(sed -n 's#^Address[[:space:]]*=[[:space:]]*##p' "$profile" | tr ',' '\n' | tr -d ' \r' || true)"
  WARP_ADDR_V4="$(printf '%s\n' "$addresses" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | head -n1 || true)"
  WARP_ADDR_V6="$(printf '%s\n' "$addresses" | grep -E '^[0-9A-Fa-f:]+/[0-9]+$' | head -n1 || true)"
  [ -n "$WARP_ADDR_V4" ] && [ -n "$WARP_ADDR_V6" ]
}

do_warp() {
  [ -f "$SECRETS" ] || die "请先运行安装(bash install.sh)再开 WARP 分流"
  load_secrets || die "密钥文件格式非法: $SECRETS"
  if [ -f "$ENVFILE" ]; then load_node_env || die "运行参数文件格式非法: $ENVFILE"; fi
  { [ -e "$SB_DIR/config.json" ] && grep -q anytls-in "$SB_DIR/config.json"; } && ANYTLS_OK=1 || ANYTLS_OK=0
  detect_net

  # 关闭分流: 重渲染"无 WARP"配置(护栏校验); WARP_ENV 状态文件等无 WARP 配置成功落地后才删,
  # 失败则保留原配置与状态, 避免"配置仍带 WARP 但状态文件已丢"的不一致。
  if [ "${1:-}" = "off" ]; then
    [ -f "$WARP_ENV" ] || { ok "未启用 WARP 分流, 无需关闭"; return 0; }
    local warp_off_bak
    warp_off_bak="$(mktemp -d "$SB_DIR/.warp-off-backup.XXXXXX")" || die "无法创建 WARP 关闭回滚目录"
    snapshot_files "$warp_off_bak" "$SB_DIR/config.json" "$WARP_ENV" || { rm -rf "$warp_off_bak"; die "无法备份 WARP 关闭前状态"; }
    _rollback_warp_off() {
      local rollback_rc=0
      restore_files "$warp_off_bak" "$SB_DIR/config.json" "$WARP_ENV" || rollback_rc=1
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
      systemctl restart sing-box >/dev/null 2>&1 || rollback_rc=1
      systemctl is-active --quiet sing-box >/dev/null 2>&1 || rollback_rc=1
      if [ "$rollback_rc" -eq 0 ]; then rm -rf "$warp_off_bak"; else err "WARP 关闭回滚不完整，备份保留在: $warp_off_bak"; fi
      return "$rollback_rc"
    }
    WARP_PRIVATE_KEY=""; WARP_ADDR_V4=""; WARP_ADDR_V6=""; WARP_RESERVED=""   # 清空 shell 变量→渲染出无 WARP 配置(暂不删 WARP_ENV)
    local tmpc; tmpc="$(mktemp)" || { _rollback_warp_off || true; return 1; }
    render_singbox_config >"$tmpc" || { rm -f "$tmpc"; _rollback_warp_off || true; return 1; }
    if sing-box check -c "$tmpc" >/dev/null 2>&1 && apply_singbox_config "$tmpc"; then
      rm -f "$tmpc"
      if ! rm -f "$WARP_ENV"; then
        warn "无 WARP 配置已生效，但状态文件删除失败，正在恢复旧状态"
        _rollback_warp_off || true
        return 1
      fi
      rm -rf "$warp_off_bak"
      ok "已关闭 WARP 分流(原解锁站点恢复走 VPS 直连出口)"
    else
      rm -f "$tmpc"
      _rollback_warp_off || true
      warn "关闭 WARP 失败(校验或重启未通过), 已保留原 WARP 配置与状态不动(WARP_ENV 未删)"
      return 1
    fi
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  detect_os
  local req_sites="$WARP_SITES"   # 本次显式传入的 WARP_SITES(在 source warp.env 覆盖前先记下)

  if [ -f "$WARP_ENV" ]; then
    log "复用已注册的 WARP 账号(避免重复注册被 Cloudflare 限流)..."
    load_warp_env || die "WARP 状态文件格式非法: $WARP_ENV"
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
    parse_wgcf_addresses "$prof" || { rm -rf "$wd"; die "无法从 wgcf-profile.conf 解析 IPv4/IPv6 Address"; }
    WARP_RESERVED=""   # 单账号专用默认不带; 如解锁不生效再手动填
    rm -rf "$wd"
    ok "WARP 账号已注册"
  fi
  [ -n "$WARP_PRIVATE_KEY" ] || die "WARP 私钥为空, 删 $WARP_ENV 后重试注册"
  # 站点优先级: 本次显式传入 > warp.env 记录 > 默认; 统一在此回写 warp.env(支持改站点后重跑)
  WARP_SITES="${req_sites:-${WARP_SITES:-$WARP_DEFAULT_SITES}}"
  # 落盘前清洗成安全字符集(只留 小写字母/数字/逗号/连字符), 保持状态文件可安全按字面量读取。
  WARP_SITES="$(printf '%s' "$WARP_SITES" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9,-')"
  [ -n "$WARP_SITES" ] || WARP_SITES="$WARP_DEFAULT_SITES"

  # 安全护栏: 渲染到临时文件 -> sing-box check 通过才替换正式 config, 失败保留原配置(节点不受影响)。
  # WARP_ENV 状态也等"校验+重启都成功"后再落盘: 否则校验失败(如 sing-box<1.12 不支持 wireguard endpoint)
  # 却留下"已启用"状态文件, 会让后续 install/重启继续尝试启用 WARP 而反复失败。
  log "生成带 WARP 分流的配置并校验..."
  local tmpc warp_state_bak
  warp_state_bak="$(mktemp -d "$SB_DIR/.warp-backup.XXXXXX")" || die "无法创建 WARP 回滚目录"
  snapshot_files "$warp_state_bak" "$SB_DIR/config.json" "$WARP_ENV" || { rm -rf "$warp_state_bak"; die "无法备份 WARP 相关状态"; }
  _rollback_warp_state() {
    local rollback_rc=0
    restore_files "$warp_state_bak" "$SB_DIR/config.json" "$WARP_ENV" || rollback_rc=1
    systemctl reset-failed sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box >/dev/null 2>&1 || rollback_rc=1
    systemctl is-active --quiet sing-box >/dev/null 2>&1 || rollback_rc=1
    if [ "$rollback_rc" -eq 0 ]; then rm -rf "$warp_state_bak"; else err "WARP 回滚不完整，备份保留在: $warp_state_bak"; fi
    return "$rollback_rc"
  }
  tmpc="$(mktemp)" || { _rollback_warp_state || true; return 1; }
  render_singbox_config >"$tmpc"
  if sing-box check -c "$tmpc" >/dev/null 2>&1; then
    if apply_singbox_config "$tmpc"; then
      rm -f "$tmpc"
      atomic_write_file "$WARP_ENV" 600 <<EOF || { warn "WARP 配置已生效但状态文件写入失败，正在恢复旧状态"; _rollback_warp_state || true; return 1; }
WARP_PRIVATE_KEY='$WARP_PRIVATE_KEY'
WARP_ADDR_V4='$WARP_ADDR_V4'
WARP_ADDR_V6='$WARP_ADDR_V6'
WARP_RESERVED='$WARP_RESERVED'
WARP_SITES='$WARP_SITES'
EOF
      rm -rf "$warp_state_bak"
      ok "WARP 解锁分流已开启 —— 这些站点走 WARP 出口: $WARP_SITES"
      echo "  改站点: WARP_SITES='openai,anthropic,google-gemini,tiktok' bash install.sh warp   |  关闭: bash install.sh warp off"
      echo "  若能连但仍被拦(解锁没生效), 多半是缺 reserved: 编辑 $WARP_ENV 设 WARP_RESERVED='a,b,c' 后重跑 warp"
    else
      rm -f "$tmpc"
      _rollback_warp_state || true
      warn "带 WARP 的配置重启失败, 已回滚到旧配置(现有节点不受影响); 看 systemctl status sing-box"
      return 1
    fi
  else
    rm -f "$tmpc"
    rm -rf "$warp_state_bak"
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

  # 从这里开始会改持久状态。整个后半段作为一笔事务：任何函数 die/返回非零都会触发 EXIT trap，
  # 恢复升级前的密钥、配置、订阅、Nginx、流量脚本和端口跳跃；包安装与 ufw 放行是幂等外部副作用，
  # 不做反向卸载。这样不会出现 sing-box 已切新配置、订阅或 Nginx 却只完成一半的混合状态。
  if [ -f "$SECRETS" ]; then load_secrets || die "密钥文件格式非法, 为保护现有节点拒绝继续: $SECRETS"; fi
  INSTALL_TX_OLD_SUB_PATH="${SUB_PATH:-}"; INSTALL_TX_OLD_B64_PATH="${SUB_B64_PATH:-}"; INSTALL_TX_OLD_PANEL_PATH="${PANEL_PATH:-}"
  INSTALL_TX_OLD_SINGBOX_ACTIVE=0; INSTALL_TX_OLD_NGINX_ACTIVE=0; INSTALL_TX_OLD_PORTHOP_ACTIVE=0; INSTALL_TX_ROLLBACK_STARTED=0
  mkdir -p "$SB_DIR" || die "无法创建 sing-box 状态目录"
  INSTALL_TX_BACKUP="$(mktemp -d "$SB_DIR/.install-backup.XXXXXX")" || die "无法创建安装回滚目录"
  INSTALL_TX_PATHS=(
    "$SECRETS" "$ENVFILE" "$SB_DIR/server.crt" "$SB_DIR/server.key" "$SB_DIR/config.json"
    "$NGINX_SNIPPET" "$NGINX_CONF" "$NGINX_MAIN" "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_CONF"
    "$TRAFFIC_PY" "$CRON" "$SYSCTL_CONF" "$BBR_MODULE_CONF"
    "$PORTHOP_SERVICE" "$SB_DIR/porthop.nft"
  )
  [ -n "$INSTALL_TX_OLD_SUB_PATH" ] && INSTALL_TX_PATHS+=("$WWW$INSTALL_TX_OLD_SUB_PATH")
  [ -n "$INSTALL_TX_OLD_B64_PATH" ] && INSTALL_TX_PATHS+=("$WWW$INSTALL_TX_OLD_B64_PATH")
  [ -n "$INSTALL_TX_OLD_PANEL_PATH" ] && INSTALL_TX_PATHS+=("$WWW$INSTALL_TX_OLD_PANEL_PATH" "$WWW${INSTALL_TX_OLD_PANEL_PATH%.html}-login.html")
  snapshot_files "$INSTALL_TX_BACKUP" "${INSTALL_TX_PATHS[@]}" || { rm -rf "$INSTALL_TX_BACKUP"; INSTALL_TX_BACKUP=""; die "无法备份现有安装状态"; }
  systemctl is-active --quiet sing-box 2>/dev/null && INSTALL_TX_OLD_SINGBOX_ACTIVE=1 || true
  systemctl is-active --quiet nginx 2>/dev/null && INSTALL_TX_OLD_NGINX_ACTIVE=1 || true
  systemctl is-active --quiet sing-box-porthop 2>/dev/null && INSTALL_TX_OLD_PORTHOP_ACTIVE=1 || true

  _rollback_install() {
    [ "$INSTALL_TX_ROLLBACK_STARTED" = 0 ] || return 1
    INSTALL_TX_ROLLBACK_STARTED=1
    set +e
    local rollback_rc=0
    warn "安装后半段失败，正在恢复此前工作状态..."
    restore_files "$INSTALL_TX_BACKUP" "${INSTALL_TX_PATHS[@]}" || rollback_rc=1
    [ -n "${SUB_PATH:-}" ] && [ "$SUB_PATH" != "$INSTALL_TX_OLD_SUB_PATH" ] && rm -f "$WWW$SUB_PATH"
    [ -n "${SUB_B64_PATH:-}" ] && [ "$SUB_B64_PATH" != "$INSTALL_TX_OLD_B64_PATH" ] && rm -f "$WWW$SUB_B64_PATH"
    if [ -n "${PANEL_PATH:-}" ] && [ "$PANEL_PATH" != "$INSTALL_TX_OLD_PANEL_PATH" ]; then
      rm -f "$WWW$PANEL_PATH" "$WWW${PANEL_PATH%.html}-login.html"
    fi
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$INSTALL_TX_OLD_PORTHOP_ACTIVE" = 1 ]; then
      systemctl enable --now sing-box-porthop >/dev/null 2>&1 || rollback_rc=1
    else
      systemctl disable --now sing-box-porthop >/dev/null 2>&1 || true
      command -v nft >/dev/null 2>&1 && nft delete table inet sb_hophy2 >/dev/null 2>&1 || true
    fi
    if [ "$INSTALL_TX_OLD_SINGBOX_ACTIVE" = 1 ]; then
      systemctl reset-failed sing-box >/dev/null 2>&1 || true
      systemctl restart sing-box >/dev/null 2>&1 || rollback_rc=1
      systemctl is-active --quiet sing-box >/dev/null 2>&1 || rollback_rc=1
    else
      systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    if [ "$INSTALL_TX_OLD_NGINX_ACTIVE" = 1 ]; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || rollback_rc=1
      else
        rollback_rc=1
      fi
    else
      systemctl stop nginx >/dev/null 2>&1 || true
    fi
    [ -f "$TRAFFIC_PY" ] && "$PY" "$TRAFFIC_PY" >/dev/null 2>&1 || true
    if [ "$rollback_rc" -eq 0 ]; then
      rm -rf "$INSTALL_TX_BACKUP"
      INSTALL_TX_BACKUP=""
      warn "已恢复安装前状态"
    else
      err "自动回滚不完整，备份保留在: $INSTALL_TX_BACKUP"
    fi
    return "$rollback_rc"
  }
  _install_exit_trap() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ]; then _rollback_install || true; fi
    exit "$rc"
  }
  trap '_install_exit_trap' EXIT

  detect_net
  # 必须先合并已有 env: gen_secrets 会用 SS_METHOD/ENABLE_OBFS/TLS_SNI 决定是否补密钥、
  # 是否保留混淆、生成什么 CN 的证书。放在 gen_secrets 之后会导致重装时按默认值误判
  # (例如自定义 SS_METHOD 被按 128-gcm 重新生成密钥, 随后 sing-box check 失败)。
  merge_env_defaults "${RESTORING:-0}"   # 重装时沿用已有 LIMIT_GB/EXPIRE_AT 等, 显式传入的仍优先
  # 旧 env 里的端口/SUB_TLS/证书路径也可能不合法(例如 TLS 订阅与 AnyTLS 抢 443)。
  # 合并后再校验一次, 避免装到 nginx/sing-box 启动阶段才发现、再走整段回滚。
  validate_inputs
  gen_secrets
  if [ -f "$WARP_ENV" ]; then load_warp_env || die "WARP 状态文件格式非法: $WARP_ENV"; fi   # 已接入过 WARP 则重装/更新时保留分流
  gen_cert
  config_sysctl   # 在 sing-box 启动前应用, 这样 HY2/QUIC 一启动就拿到大 UDP 缓冲
  write_env
  write_singbox_config
  write_subscription
  config_nginx
  install_traffic
  config_firewall
  porthop_cleanup   # 只清旧版残留, 不再新建端口跳跃
  if [ -f "$CF_ENV" ] || [ -f "$CF_PENDING_ENV" ]; then
    note "检测到旧 CF-VLESS 状态: 该路径已下线, 不再进入订阅; 如确认不再使用可运行 'install.sh cf off' 清理 cloudflared。"
  fi
  print_summary
  trap - EXIT
  rm -rf "$INSTALL_TX_BACKUP"
  INSTALL_TX_BACKUP=""; INSTALL_TX_PATHS=(); INSTALL_TX_ROLLBACK_STARTED=0
}

main() {
  need_root
  case "${1:-install}" in
    install)   with_maintenance_lock do_install ;;
    info)      do_info ;;
    panel)     with_maintenance_lock do_panel ;;
    panel-pass) shift; with_maintenance_lock do_panel_pass "$@" ;;
    links)     do_links ;;
    status)    do_status ;;
    doctor)    do_doctor ;;
    set)       shift; with_maintenance_lock do_set "$@" ;;
    backup)    do_backup ;;
    restore)   shift; with_maintenance_lock do_restore "$@" ;;
    harden)    with_maintenance_lock do_harden ;;
    update)    with_maintenance_lock do_update ;;
    restart)   with_maintenance_lock do_restart ;;
    cf)        shift; with_maintenance_lock do_cf "$@" ;;
    warp)      shift; with_maintenance_lock do_warp "$@" ;;
    admin)     shift; with_maintenance_lock do_admin "$@" ;;
    komari)    with_maintenance_lock do_komari ;;
    menu)      do_menu ;;
    uninstall) with_maintenance_lock do_uninstall ;;
    *) echo "用法: $0 [install|info|panel|panel-pass <密码>|links|status|doctor|set|backup|restore <file>|harden|update|restart|cf|warp [off]|admin [off]|komari|menu|uninstall]"; exit 1 ;;
  esac
}

# 仅在直接执行时运行 main(被 source 时不运行, 便于测试渲染函数)
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main "$@"
fi
