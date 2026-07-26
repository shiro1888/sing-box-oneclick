#!/usr/bin/env bash
# 在本机校验 install.sh：语法 + 渲染逻辑(真实生成配置后用 JSON/YAML 解析)
# 注: 用 Windows python 验证时强制 UTF-8(PYTHONUTF8), 否则写 🚀 会触发 gbk 编码错误;
#     Linux VPS 上是 UTF-8 locale, 无此问题。
cd "$(dirname "$0")" || exit 1
# MSYS2_ENV_CONV_EXCL: 阻止 Git Bash 把 /cf-abc 这种斜杠开头的环境变量值转成 Windows 路径
# (纯 Windows 测试环境问题; Linux VPS 上不存在路径转换)
if [ -n "${PYTHON:-}" ]; then
  PYTHON_BIN="$(command -v "$PYTHON" 2>/dev/null || true)"
else
  PYTHON_BIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"
fi
[ -n "$PYTHON_BIN" ] || { echo "FAIL  未找到 python/python3"; exit 1; }
export PYTHON="$PYTHON_BIN" PYTHONUTF8=1 PYTHONIOENCODING=utf-8 MSYS2_ENV_CONV_EXCL='CF_WS_PATH;WARP_ADDR_V4;WARP_ADDR_V6;PANEL_PATH;PANEL_LOGIN'
python() { "$PYTHON_BIN" "$@"; }
fail=0
TMP="${TMPDIR:-/tmp}"

# 公共测试参数(导出, 供子shell source 后复用)
export SB_DIR="$TMP/sbtest" HY2_PORT=4433 ANYTLS_PORT=4434 VLESS_PORT=443 \
  HY2_PASSWORD=pw1 ANYTLS_PASSWORD=pw2 VLESS_UUID=11111111-1111-1111-1111-111111111111 \
  REALITY_PRIVATE_KEY=PRIVKEY REALITY_PUBLIC_KEY=PUBKEY REALITY_SHORT_ID=abcdef0123456789 \
  REALITY_SNI=www.bing.com TLS_SNI=www.bing.com PUBLIC_IP=1.2.3.4 LIMIT_GB=200 \
  SS_PORT=4435 SS_METHOD=2022-blake3-aes-128-gcm SS_PASSWORD=MTIzNDU2Nzg5MGFiY2RlZg==

# 在干净子shell里 source 脚本(guard 阻止 main 运行)并调用一个渲染函数
render() { PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; '"$1"; }

echo "=== 1) bash -n 语法检查 ==="
if bash -n install.sh; then echo "PASS  bash -n install.sh"; else echo "FAIL  bash -n"; fail=1; fi

echo
echo "=== 2) shellcheck(若安装) ==="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning install.sh; then echo "PASS  shellcheck 无 warning+"; else echo "NOTE  shellcheck 有提示(见上)"; fi
else echo "skip  (未安装 shellcheck)"; fi

echo
echo "=== 3) 渲染 sing-box config ==="
CFG3="$(ANYTLS_OK=1 render render_singbox_config)"
if printf '%s' "$CFG3" | python -c "import json,sys;d=json.load(sys.stdin);assert [i['tag'] for i in d['inbounds']]==['hy2-in','anytls-in','vless-in','ss-in']" 2>"$TMP/e"; then
  echo "PASS  4入站 JSON 合法且顺序正确(含 ss-in)"; else echo "FAIL  config4"; cat "$TMP/e"; fail=1; fi

CFG2="$(ANYTLS_OK=0 render render_singbox_config)"
if printf '%s' "$CFG2" | python -c "import json,sys;d=json.load(sys.stdin);assert [i['tag'] for i in d['inbounds']]==['hy2-in','vless-in','ss-in']" 2>"$TMP/e"; then
  echo "PASS  跳过anytls=3入站 仍是合法 JSON(含 ss-in)"; else echo "FAIL  config3"; cat "$TMP/e"; fail=1; fi

if printf '%s' "$CFG3" | python -c "import json,sys;s=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='ss-in'][0];assert s['type']=='shadowsocks';assert s['method']=='2022-blake3-aes-128-gcm';assert s['password']" 2>"$TMP/e"; then
  echo "PASS  ss-in 入站方法/密码正确"; else echo "FAIL  ss-in"; cat "$TMP/e"; fail=1; fi

if printf '%s' "$CFG3" | python -c "import json,sys;v=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='vless-in'][0];assert v['tls']['server_name']==v['tls']['reality']['handshake']['server']=='www.bing.com';assert v['users'][0]['flow']=='xtls-rprx-vision'" 2>"$TMP/e"; then
  echo "PASS  Reality server_name==handshake.server==www.bing.com 且 flow 正确"; else echo "FAIL  reality"; cat "$TMP/e"; fail=1; fi
# HY2 服务端带宽护栏(up_mbps/down_mbps): 设了即进 hy2-in 入站; 不设则不出现
CFGBW="$(ANYTLS_OK=1 HY2_UP_MBPS=80 HY2_DOWN_MBPS=160 render render_singbox_config)"
if printf '%s' "$CFGBW" | python -c "import json,sys;h=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='hy2-in'][0];assert h['up_mbps']==80 and h['down_mbps']==160" 2>"$TMP/e"; then
  echo "PASS  HY2 服务端带宽护栏 up_mbps/down_mbps 进 hy2-in"; else echo "FAIL  hy2-server-bw"; cat "$TMP/e"; fail=1; fi
if printf '%s' "$CFG3" | python -c "import json,sys;h=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='hy2-in'][0];assert 'up_mbps' not in h and 'down_mbps' not in h" 2>"$TMP/e"; then
  echo "PASS  默认不设带宽护栏时 hy2-in 无 up_mbps/down_mbps"; else echo "FAIL  hy2-bw-default"; cat "$TMP/e"; fail=1; fi
# 路由: 默认禁BT+拦广告
if printf '%s' "$CFG3" | python -c "import json,sys;r=json.load(sys.stdin)['route'];assert any(x.get('protocol')=='bittorrent' and x.get('action')=='reject' for x in r['rules']);assert any('geosite-ads' in (x.get('rule_set') or []) for x in r['rules']);assert [s['tag'] for s in r['rule_set']]==['geosite-ads'];assert r['final']=='direct'" 2>"$TMP/e"; then
  echo "PASS  路由含 禁BT + 拦广告 rule_set + final direct"; else echo "FAIL  route"; cat "$TMP/e"; fail=1; fi
CFGNR="$(ANYTLS_OK=1 ENABLE_BLOCK_BT=0 ENABLE_BLOCK_ADS=0 render render_singbox_config)"
if printf '%s' "$CFGNR" | python -c "import json,sys;assert 'route' not in json.load(sys.stdin)" 2>"$TMP/e"; then
  echo "PASS  关闭 BT/ads 后无 route 段(仍合法 JSON)"; else echo "FAIL  route off"; cat "$TMP/e"; fail=1; fi

echo
echo "=== 4) 渲染 Clash 订阅 ==="
ANYTLS_OK=1 DOMAIN="" render render_subscription_yaml > "$TMP/sub.yaml"
if python - "$TMP/sub.yaml" <<'PYV' 2>"$TMP/e"
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
assert d['allow-lan'] is False
names=[p['name'] for p in d['proxies']]
assert names==['Hysteria2','AnyTLS','Vless','SS2022'], names
g=d['proxy-groups'][0]
assert g['type']=='select'
assert all(x in names for x in g['proxies']), g['proxies']
assert d['rules'][-1].startswith('MATCH,'), d['rules'][-1]
assert d['rules'].index('GEOSITE,google,🚀 节点选择') < d['rules'].index('GEOSITE,cn,DIRECT')
assert 'DOMAIN-SUFFIX,gvt1.com,🚀 节点选择' in d['rules']
assert d['proxies'][0]['server']=='1.2.3.4'
assert any(r.startswith('IP-CIDR,1.2.3.4/32,DIRECT') for r in d['rules'])
v=[p for p in d['proxies'] if p['name']=='Vless'][0]
assert v['reality-opts']['public-key']=='PUBKEY'
ss=[p for p in d['proxies'] if p['name']=='SS2022'][0]
assert ss['type']=='ss' and ss['cipher']=='2022-blake3-aes-128-gcm' and ss['udp'] is True
PYV
then echo "PASS  订阅YAML(含anytls/IP) 合法+节点名/组/规则一致"; else echo "FAIL  subA"; cat "$TMP/e"; fail=1; fi

ANYTLS_OK=0 DOMAIN=node.example.com render render_subscription_yaml > "$TMP/sub2.yaml"
if python - "$TMP/sub2.yaml" <<'PYV' 2>"$TMP/e"
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
assert [p['name'] for p in d['proxies']]==['Hysteria2','Vless','SS2022']
assert any(r.startswith('DOMAIN,node.example.com,DIRECT') for r in d['rules'])
PYV
then echo "PASS  订阅YAML(跳anytls+域名直连规则) 合法"; else echo "FAIL  subB"; cat "$TMP/e"; fail=1; fi

echo
echo "=== 4b) CF-Vless 接入后渲染(可选第5节点) ==="
CFCFG="$(ANYTLS_OK=1 CF_HOSTNAME=cf.example.com CF_VLESS_UUID=cfuuid CF_WS_PATH=/cf-abc render render_singbox_config)"
if printf '%s' "$CFCFG" | python -c "import json,sys;d=json.load(sys.stdin);assert [i['tag'] for i in d['inbounds']]==['hy2-in','anytls-in','vless-in','ss-in','cf-vless-ws-in'];c=[i for i in d['inbounds'] if i['tag']=='cf-vless-ws-in'][0];assert c['listen']=='127.0.0.1' and c['transport']['type']=='ws'" 2>"$TMP/e"; then
  echo "PASS  含 cf 入站(127.0.0.1 ws)且为第5入站"; else echo "FAIL  cf-config"; cat "$TMP/e"; fail=1; fi

ANYTLS_OK=1 CF_HOSTNAME=cf.example.com CF_VLESS_UUID=cfuuid CF_WS_PATH=/cf-abc render render_subscription_yaml > "$TMP/subcf.yaml"
if python - "$TMP/subcf.yaml" <<'PYV' 2>"$TMP/e"
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
names=[p['name'] for p in d['proxies']]
assert names==['Hysteria2','AnyTLS','Vless','SS2022','CF-Vless'], names
cf=[p for p in d['proxies'] if p['name']=='CF-Vless'][0]
assert cf['type']=='vless' and cf['network']=='ws' and cf['server']=='cf.example.com'
assert cf['ws-opts']['path']=='/cf-abc' and cf['ws-opts']['headers']['Host']=='cf.example.com'
assert d['proxy-groups'][0]['proxies'][-1]=='CF-Vless'
PYV
then echo "PASS  订阅含 CF-Vless 节点且在代理组末位"; else echo "FAIL  cf-sub"; cat "$TMP/e"; fail=1; fi

# 确认不开 CF 时不会冒出 CF 节点
NOCF="$(ANYTLS_OK=1 render render_subscription_yaml)"
if printf '%s' "$NOCF" | grep -q 'CF-Vless'; then echo "FAIL  未开CF却出现CF-Vless"; fail=1; else echo "PASS  不开 CF 时无 CF-Vless(条件渲染正确)"; fi

echo
echo "=== 4c) 分享链接 render_share_links + 通用订阅 ==="
LINKS="$(ANYTLS_OK=1 render render_share_links)"
clink() { if printf '%s' "$LINKS" | grep -qE "$1"; then echo "PASS  含 $2"; else echo "FAIL  缺 $2"; fail=1; fi; }
clink '^hysteria2://.+@1\.2\.3\.4:4433/\?insecure=1&sni=' 'hysteria2:// 链接'
clink '^anytls://.+@1\.2\.3\.4:4434/\?insecure=1&sni=' 'anytls:// 链接'
clink '^vless://.+@1\.2\.3\.4:443\?.*flow=xtls-rprx-vision.*security=reality' 'vless reality 链接'
clink '^ss://2022-blake3-aes-128-gcm:.+@1\.2\.3\.4:4435#' 'ss SIP022 链接(method:百分号密码)'
# SS 密码里的 base64 '==' 应被百分号编码成 %3D, 不能原样出现
if printf '%s' "$LINKS" | grep -q 'ss://.*=='; then echo "FAIL  ss 密码未百分号编码"; fail=1; else echo "PASS  ss 密码已百分号编码(无裸 ==)"; fi
if printf '%s' "$LINKS" | grep -q 'CF-Vless'; then echo "FAIL  未开CF却有CF-Vless链接"; fail=1; else echo "PASS  无CF时无 CF-Vless 链接"; fi

LINKSCF="$(ANYTLS_OK=1 CF_HOSTNAME=cf.example.com CF_VLESS_UUID=cfu CF_WS_PATH=/cf-x render render_share_links)"
if printf '%s' "$LINKSCF" | grep -qE '^vless://cfu@cf\.example\.com:443\?.*type=ws'; then echo "PASS  开CF后有 CF-Vless(ws) 链接"; else echo "FAIL  CF 链接"; fail=1; fi

B64="$(ANYTLS_OK=1 render render_share_links | base64 -w0)"
if printf '%s' "$B64" | base64 -d 2>/dev/null | grep -q '^hysteria2://'; then echo "PASS  base64 通用订阅可解码且含链接"; else echo "FAIL  base64 往返"; fail=1; fi

echo
echo "=== 4d) set 改参数(env 更新 + 校验) ==="
SETD="$TMP/setd"; mkdir -p "$SETD"
cat > "$SETD/env" <<E
LIMIT_GB=200
EXPIRE_AT="2026-12-31 23:59:59 +0800"
INTERFACE=eth0
COUNT_MODE=rx+tx
SUB_HOST=1.2.3.4
PUBLIC_IP=1.2.3.4
E
: > "$SETD/secrets"
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; do_set LIMIT_GB=500 COUNT_MODE=tx' >/dev/null 2>&1
if grep -q '^LIMIT_GB=500$' "$SETD/env" && grep -q '^COUNT_MODE=tx$' "$SETD/env" && grep -q 'EXPIRE_AT=' "$SETD/env" && grep -q '^INTERFACE=eth0$' "$SETD/env"; then
  echo "PASS  set 更新 LIMIT_GB/COUNT_MODE 并保留其它键"; else echo "FAIL  set 更新"; cat "$SETD/env"; fail=1; fi
if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; do_set COUNT_MODE=bogus' >/dev/null 2>&1; then
  echo "FAIL  set 应拒绝非法 COUNT_MODE"; fail=1
else
  grep -q '^COUNT_MODE=tx$' "$SETD/env" && echo "PASS  set 拒绝非法 COUNT_MODE 且不改 env" || { echo "FAIL  set 非法值污染了 env"; fail=1; }
fi
# EXPIRE_AT 带空格作为单个参数(对应菜单 do_set "$kv")应成功
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; do_set "EXPIRE_AT=2030-01-02 03:04:05 +0800"' >/dev/null 2>&1
if grep -q 'EXPIRE_AT="2030-01-02 03:04:05 +0800"' "$SETD/env"; then echo "PASS  set EXPIRE_AT(带空格单参数)成功"; else echo "FAIL  set EXPIRE_AT 空格"; grep EXPIRE_AT "$SETD/env"; fail=1; fi
# 畸形 LIMIT_GB(多点)应被拒, 不污染 env
if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; do_set LIMIT_GB=5.5.5' >/dev/null 2>&1; then echo "FAIL  畸形 LIMIT_GB 应被拒"; fail=1; else echo "PASS  畸形 LIMIT_GB(5.5.5)被拒"; fi
# do_set 拒绝不存在的网卡(打错网卡名会让 vnstat 取不到数据、配额限流静默失效); 用 ip 桩函数模拟存在/不存在
if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; ip(){ return 1; }; do_set INTERFACE=eth9' >/dev/null 2>&1; then
  echo "FAIL  do_set 应拒绝不存在的网卡"; fail=1
else
  grep -q '^INTERFACE=eth9$' "$SETD/env" && { echo "FAIL  非法网卡污染了 env"; fail=1; } || echo "PASS  do_set 拒绝不存在的网卡(ip 校验)"
fi
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$SETD"'/env"; SECRETS="'"$SETD"'/secrets"; TRAFFIC_PY="'"$SETD"'/nope.py"; ip(){ return 0; }; do_set INTERFACE=eth1' >/dev/null 2>&1
grep -q '^INTERFACE=eth1$' "$SETD/env" && echo "PASS  do_set 接受存在的网卡并落盘" || { echo "FAIL  do_set 合法网卡未落盘"; grep INTERFACE "$SETD/env"; fail=1; }
# cf_restore_service 首次接入(空备份)应卸载刚装的新隧道, 不留孤儿服务
MK="$TMP/cf_uninstall_mk"; rm -f "$MK"
PYTHON="$PYTHON_BIN" bash -c 'source ./install.sh >/dev/null 2>&1; set +e; cloudflared(){ [ "${1:-} ${2:-}" = "service uninstall" ] && touch "'"$MK"'"; return 0; }; systemctl(){ return 0; }; cf_restore_service ""' >/dev/null 2>&1
[ -f "$MK" ] && echo "PASS  cf_restore_service 首次接入(空备份)卸载新隧道不留孤儿" || { echo "FAIL  cf_restore_service 空备份未卸载"; fail=1; }
# apply_singbox_config: 回滚后旧服务也起不来时, 必须显式报警, 不静默谎称"节点不受影响"
AP2="$TMP/ap2"; rm -rf "$AP2"; mkdir -p "$AP2"; echo '{"old":1}' > "$AP2/config.json"; echo '{"new":1}' > "$AP2/new.json"
errout="$(PYTHON="$PYTHON_BIN" bash -c 'source ./install.sh >/dev/null 2>&1; set +e; SB_DIR="'"$AP2"'"; systemctl(){ return 1; }; apply_singbox_config "'"$AP2"'/new.json"' 2>&1)"
printf '%s' "$errout" | grep -q '回滚后 sing-box 仍未运行' && echo "PASS  apply 回滚后旧服务仍挂会显式报警" || { echo "FAIL  apply 缺回滚失败报警"; fail=1; }

echo
echo "=== 4e) HY2 obfs / 端口跳跃 / brutal 渲染 ==="
CFGO="$(ANYTLS_OK=1 OBFS_PASSWORD=obfspw render render_singbox_config)"
if printf '%s' "$CFGO" | python -c "import json,sys;h=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='hy2-in'][0];assert h['obfs']['type']=='salamander' and h['obfs']['password']=='obfspw'" 2>"$TMP/e"; then echo "PASS  hy2 入站含 obfs salamander"; else echo "FAIL  hy2 obfs"; cat "$TMP/e"; fail=1; fi
SUBO="$(ANYTLS_OK=1 OBFS_PASSWORD=obfspw HY2_HOP_RANGE=20000-50000 HY2_UP=50 HY2_DOWN=200 render render_subscription_yaml)"
if printf '%s' "$SUBO" | python -c "import yaml,sys;h=[p for p in yaml.safe_load(sys.stdin)['proxies'] if p['name']=='Hysteria2'][0];assert h['obfs']=='salamander' and h['obfs-password']=='obfspw' and h['ports']=='20000-50000' and h['up']=='50 Mbps' and h['down']=='200 Mbps'" 2>"$TMP/e"; then echo "PASS  Clash HY2 节点含 obfs/ports/up/down"; else echo "FAIL  hy2 订阅选项"; cat "$TMP/e"; fail=1; fi
LNKO="$(ANYTLS_OK=1 OBFS_PASSWORD=obfspw HY2_HOP_RANGE=20000-50000 render render_share_links)"
if printf '%s' "$LNKO" | grep -qE '^hysteria2://[^@]+@1\.2\.3\.4:20000-50000/\?.*obfs=salamander.*mport=20000-50000'; then echo "PASS  HY2 链接: 端口段进 authority + obfs + mport"; else echo "FAIL  hy2 链接选项"; printf '%s\n' "$LNKO" | grep hysteria2; fail=1; fi
# 端口段覆盖正在监听的 UDP 端口(SS_PORT=4435 / HY2_PORT=4433)应被 validate 拒绝
if env HY2_HOP_RANGE=4000-5000 PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; validate_inputs' >/dev/null 2>&1; then echo "FAIL  端口段覆盖 UDP 端口应被拒"; fail=1; else echo "PASS  端口段覆盖 HY2/SS 端口被拒"; fi
NOO="$(ANYTLS_OK=1 render render_subscription_yaml)"
if printf '%s' "$NOO" | grep -qE 'obfs|ports:| up:'; then echo "FAIL  默认却出现 obfs/ports/up"; fail=1; else echo "PASS  默认无 obfs/端口跳跃/brutal(条件渲染正确)"; fi

echo
echo "=== 4f) 可视化看板页渲染 ==="
PANEL="$(SUB_HOST=1.2.3.4 SUB_PATH=/sub-x.yaml SUB_B64_PATH=/sub-b64-x.txt ANYTLS_OK=1 AIRPORT_NAME=MyNode render render_panel_html)"
chkp() { if printf '%s' "$PANEL" | grep -qF "$1"; then echo "PASS  看板含 $2"; else echo "FAIL  看板缺 $2"; fail=1; fi; }
chkp '<!doctype html>'    'HTML 结构'
chkp '1.2.3.4/sub-x.yaml' 'Clash 订阅 URL'
chkp 'sub-b64-x.txt'      '通用订阅 URL'
chkp 'SS2022'             'SS2022 节点'
chkp '含全部节点凭证'      '明文安全警告'
chkp 'navigator.clipboard' '复制 JS'
chkp 'clash://install-config?url=http%3A%2F%2F1.2.3.4%2Fsub-x.yaml&amp;name=MyNode' 'Clash 一键导入深链(URL编码+转义)'
chkp 'shadowrocket://add/sub://aHR0cDovLzEuMi4zLjQvc3ViLWI2NC14LnR4dA==' 'Shadowrocket 深链(base64订阅URL)'
chkp '流量 / 到期'         '流量/到期卡'
chkp '限额 <b>200 GB</b>'  '限额(从环境 LIMIT_GB=200)'
chkp 'download=(\d+)'      '实时已用解析JS(同源拉订阅头)'
chkp '单节点'              '单节点分区'
chkp 'hysteria2://'        '单节点分享链接(HY2 逐条导入)'
chkp 'anytls://'           '单节点分享链接(AnyTLS)'
chkp 'onclick="cpx(this)"' '复制按钮(免逐个id)'
chkp 'onclick="tg()"'      '明暗主题切换'
chkp 'body.light'          '浅色主题样式'
chkp 'onclick="lat()"'     '延迟自测按钮'
if printf '%s' "$PANEL" | grep -qF 'CF-Vless'; then echo "FAIL  未开CF看板却有CF-Vless"; fail=1; else echo "PASS  未开CF看板无CF-Vless(条件渲染)"; fi
PANELCF="$(SUB_HOST=1.2.3.4 SUB_PATH=/s.yaml SUB_B64_PATH=/b.txt ANYTLS_OK=1 CF_HOSTNAME=cf.example.com CF_VLESS_UUID=u render render_panel_html)"
if printf '%s' "$PANELCF" | grep -qF 'CF-Vless'; then echo "PASS  开CF后看板有CF-Vless"; else echo "FAIL  开CF看板缺CF-Vless"; fail=1; fi
# 安装上下文是 set -euo pipefail, 看板渲染不能中断(qrencode 失败/缺失都该优雅降级)
if PYTHON="$PYTHON_BIN" bash -c 'set -euo pipefail; source ./install.sh >/dev/null 2>&1 || true; SUB_HOST=1.2.3.4 SUB_PATH=/s.yaml SUB_B64_PATH=/b.txt ANYTLS_OK=1 AIRPORT_NAME=N; render_panel_html >/dev/null'; then echo "PASS  看板渲染在 set -euo pipefail 下不中断"; else echo "FAIL  看板渲染 set -e 中断"; fail=1; fi
# 看板页登录(panel-pass): 自定义登录页 + nginx 用 cookie==密码 服务端校验(非网页 JS 假门)
grep -qF 'if ($sb_ok = 0)' install.sh && grep -qF 'include $PANEL_MAP' install.sh \
  && echo "PASS  config_nginx 注入未登录跳登录页 + cookie 校验(看板真鉴权)" || { echo "FAIL  缺 nginx cookie 鉴权注入"; fail=1; }
# 登录页渲染: 合法 HTML, 写 cookie sbauth, 跳看板路径; 不含密码
LG="$(PANEL_PATH=/panel-x.html AIRPORT_NAME=MyNode render render_panel_login_html)"
if printf '%s' "$LG" | python -c "import sys,html.parser;html.parser.HTMLParser().feed(sys.stdin.read())" 2>/dev/null && printf '%s' "$LG" | grep -qF "sbauth=" && printf '%s' "$LG" | grep -qF '"/panel-x.html"'; then
  echo "PASS  登录页合法 HTML(写 cookie sbauth + 跳看板)"; else echo "FAIL  登录页渲染"; fail=1; fi
# panel-pass <密码>: 写 nginx map(含密码)+ 渲染登录页
PP="$TMP/pptest"; rm -rf "$PP"; mkdir -p "$PP/www"; printf 'PANEL_PATH=/panel-x.html\n' > "$PP/secrets"
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SECRETS="'"$PP"'/secrets"; ENVFILE="'"$PP"'/nope"; PANEL_MAP="'"$PP"'/map.conf"; WWW="'"$PP"'/www"
  config_nginx(){ return 0; }; nginx(){ return 0; }
  do_panel_pass abcdef123' >/dev/null 2>&1
if grep -qF 'map $cookie_sbauth $sb_ok' "$PP/map.conf" 2>/dev/null && grep -qF '"abcdef123" 1;' "$PP/map.conf" 2>/dev/null && [ -f "$PP/www/panel-x-login.html" ]; then
  echo "PASS  panel-pass 写 nginx map(cookie==密码)+ 渲染登录页"; else echo "FAIL  panel-pass 生成"; cat "$PP/map.conf" 2>/dev/null; ls "$PP/www" 2>/dev/null; fail=1; fi
# 非法字符密码应被拒
if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SECRETS="'"$PP"'/secrets"; ENVFILE="'"$PP"'/nope"; PANEL_MAP="'"$PP"'/map2.conf"; WWW="'"$PP"'/www"
  config_nginx(){ return 0; }; nginx(){ return 0; }
  do_panel_pass "bad pass!"' >/dev/null 2>&1; then echo "FAIL  panel-pass 应拒绝非法字符密码"; fail=1; else echo "PASS  panel-pass 拒绝非法字符密码"; fi
# 大写密码应被拒(nginx map 大小写不敏感, 限小写免白丢熵)
if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SECRETS="'"$PP"'/secrets"; ENVFILE="'"$PP"'/nope"; PANEL_MAP="'"$PP"'/map3.conf"; WWW="'"$PP"'/www"
  config_nginx(){ return 0; }; nginx(){ return 0; }
  do_panel_pass ABCdef123' >/dev/null 2>&1; then echo "FAIL  panel-pass 应拒绝大写密码"; fail=1; else echo "PASS  panel-pass 拒绝大写密码(nginx 大小写不敏感)"; fi
# panel-pass off: 删 map + 登录页
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SECRETS="'"$PP"'/secrets"; ENVFILE="'"$PP"'/nope"; PANEL_MAP="'"$PP"'/map.conf"; WWW="'"$PP"'/www"
  config_nginx(){ return 0; }; nginx(){ return 0; }
  do_panel_pass off' >/dev/null 2>&1
{ [ ! -f "$PP/map.conf" ] && [ ! -f "$PP/www/panel-x-login.html" ]; } && echo "PASS  panel-pass off 删除 map + 登录页" || { echo "FAIL  panel-pass off 未清理"; fail=1; }
# 看板"退出"按钮: 开登录时出现(清 cookie 回登录页), 未开时不出现
echo x > "$PP/map_on"
PL_ON="$(PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  PANEL_MAP="'"$PP"'/map_on"; PANEL_PATH=/panel-x.html; SB_DIR="'"$TMP"'/sbtest"; SUB_HOST=1.2.3.4; SUB_PATH=/s.yaml; SUB_B64_PATH=/b.txt; ANYTLS_OK=1
  render_panel_html')"
printf '%s' "$PL_ON" | grep -qF 'onclick="lo()"' && printf '%s' "$PL_ON" | grep -qF 'function lo()' \
  && echo "PASS  开登录时看板有退出按钮(清 cookie 回登录页)" || { echo "FAIL  看板缺退出按钮"; fail=1; }
printf '%s' "$PANEL" | grep -qF 'onclick="lo()"' && { echo "FAIL  未开登录却有退出按钮"; fail=1; } || echo "PASS  未开登录时看板无退出按钮"

echo
echo "=== 4g) backup 打包 ==="
BK="$TMP/bktest"; rm -rf "$BK"; mkdir -p "$BK/sb" "$BK/out"
echo 'HY2_PASSWORD=x' > "$BK/sb/secrets"; echo 'LIMIT_GB=200' > "$BK/env"; echo cert > "$BK/sb/server.crt"; echo key > "$BK/sb/server.key"
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SB_DIR="'"$BK"'/sb"; SECRETS="'"$BK"'/sb/secrets"; ENVFILE="'"$BK"'/env"; CF_ENV="'"$BK"'/sb/cf.env"; BACKUP_DIR="'"$BK"'/out"
  do_backup >/dev/null 2>&1'
bf="$(ls "$BK"/out/sing-box-backup-*.tar.gz 2>/dev/null | head -1)"
if [ -n "$bf" ] && tar tzf "$bf" 2>/dev/null | grep -q 'secrets' && tar tzf "$bf" 2>/dev/null | grep -q 'server.key'; then
  echo "PASS  backup 生成 tar.gz 且含 密钥/证书/参数"; else echo "FAIL  backup"; ls -la "$BK/out" 2>/dev/null; fail=1; fi

# restore 安全护栏: 含白名单外成员的 tar 必须在解包前被拒(防以 root 解任意 tar 覆盖系统文件)
if command -v tar >/dev/null 2>&1; then
  RST="$TMP/rsttest"; rm -rf "$RST"; mkdir -p "$RST"; echo evil > "$RST/evil.txt"
  ( cd "$RST" && tar czf bad.tar.gz evil.txt ) 2>/dev/null
  if PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; SB_DIR="'"$RST"'/sb"; do_restore "'"$RST"'/bad.tar.gz"' >/dev/null 2>&1; then
    echo "FAIL  restore 应拒绝白名单外成员(evil.txt)"; fail=1
  else
    echo "PASS  restore 拒绝白名单外成员(解包前 die)"; fi
else echo "skip  (未安装 tar, 跳过 restore 校验)"; fi

# apply_singbox_config: 重启失败必须回滚旧配置(systemctl 用桩函数模拟成功/失败)
AP="$TMP/aptest"; rm -rf "$AP"; mkdir -p "$AP"; echo '{"new":1}' > "$AP/new.json"
echo '{"old":1}' > "$AP/config.json"
if PYTHON="$PYTHON_BIN" bash -c 'source ./install.sh >/dev/null 2>&1; set +e; SB_DIR="'"$AP"'"; systemctl(){ return 1; }; apply_singbox_config "'"$AP"'/new.json"; rc=$?; [ "$rc" -ne 0 ] && grep -q old "'"$AP"'/config.json"' >/dev/null 2>&1; then
  echo "PASS  apply_singbox_config 重启失败回滚旧配置且返回非0"; else echo "FAIL  apply 回滚"; cat "$AP/config.json" 2>/dev/null; fail=1; fi
echo '{"old":1}' > "$AP/config.json"
if PYTHON="$PYTHON_BIN" bash -c 'source ./install.sh >/dev/null 2>&1; set +e; SB_DIR="'"$AP"'"; systemctl(){ return 0; }; apply_singbox_config "'"$AP"'/new.json"; rc=$?; [ "$rc" -eq 0 ] && grep -q new "'"$AP"'/config.json"' >/dev/null 2>&1; then
  echo "PASS  apply_singbox_config 重启成功切新配置且返回0"; else echo "FAIL  apply 成功路径"; cat "$AP/config.json" 2>/dev/null; fail=1; fi

# 回滚护栏接线检查(静态): 主安装路径/CF/WARP-off 都应走回滚, 不再直接覆盖/过早删状态
grep -qF 'render_singbox_config >"$SB_DIR/config.json"' install.sh && { echo "FAIL  write_singbox_config 仍直接覆盖正式 config"; fail=1; } || echo "PASS  主安装路径不再直接覆盖正式 config"
if grep -qF 'cf_restore_service "$cfbak"' install.sh && [ "$(grep -c cf_restore_service install.sh)" -ge 3 ]; then
  echo "PASS  do_cf 后续失败均回滚旧 cloudflared 隧道(cf_restore_service)"; else echo "FAIL  do_cf 缺 cloudflared 回滚"; fail=1; fi
grep -qF 'rm -f "$tmpc" "$WARP_ENV"' install.sh && echo "PASS  warp off 成功落地后才删 WARP_ENV" || { echo "FAIL  warp off WARP_ENV 删除时机"; fail=1; }
# write_singbox_config 端到端: 重启失败必须回滚旧配置(桩 sing-box/systemctl)
WT="$TMP/wsctest"; rm -rf "$WT"; mkdir -p "$WT"; echo '{"sentinel":"old"}' > "$WT/config.json"
PYTHON="$PYTHON_BIN" bash -c 'source ./install.sh >/dev/null 2>&1; set +e
  SB_DIR="'"$WT"'"; sing-box(){ return 0; }; systemctl(){ case "$1" in restart) return 1;; *) return 0;; esac; }
  write_singbox_config' >/dev/null 2>&1
if grep -q sentinel "$WT/config.json"; then echo "PASS  write_singbox_config 重启失败端到端回滚旧配置"; else echo "FAIL  write_singbox_config 回滚"; cat "$WT/config.json" 2>/dev/null; fail=1; fi

echo
echo "=== 4h) WARP 解锁分流渲染 ==="
CFGW="$(ANYTLS_OK=1 WARP_PRIVATE_KEY=cHJpdmtleTEyMw== WARP_ADDR_V4=172.16.0.2/32 WARP_ADDR_V6=2606:4700:110:8a36::2/128 render render_singbox_config)"
if printf '%s' "$CFGW" | python -c "
import json,sys
d=json.load(sys.stdin)
ep=d['endpoints'][0]
assert ep['type']=='wireguard' and ep['tag']=='warp', ep
assert ep['private_key']=='cHJpdmtleTEyMw=='
assert ep['address']==['172.16.0.2/32','2606:4700:110:8a36::2/128'], ep['address']
p=ep['peers'][0]
assert p['public_key']=='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=', p
assert p['port']==2408 and p['allowed_ips']==['0.0.0.0/0','::/0']
assert 'reserved' not in p
r=d['route']
default=set(['geosite-openai','geosite-anthropic','geosite-google-gemini','geosite-netflix','geosite-disney'])
assert any(x.get('outbound')=='warp' and default<=set(x.get('rule_set') or []) for x in r['rules']), r['rules']
tags=[s['tag'] for s in r['rule_set']]
assert all(t in tags for t in ['geosite-ads','geosite-openai','geosite-anthropic','geosite-google-gemini','geosite-netflix','geosite-disney']), tags
" 2>"$TMP/e"; then
  echo "PASS  WARP endpoint + 解锁路由 + rule_set 正确(与BT/ads共存)"; else echo "FAIL  warp"; cat "$TMP/e"; fail=1; fi

CFGWR="$(ANYTLS_OK=1 WARP_PRIVATE_KEY=k WARP_ADDR_V4=172.16.0.2/32 WARP_ADDR_V6=2606::2/128 WARP_RESERVED='1,2,3' render render_singbox_config)"
if printf '%s' "$CFGWR" | python -c "import json,sys;p=json.load(sys.stdin)['endpoints'][0]['peers'][0];assert p['reserved']==[1,2,3],p" 2>"$TMP/e"; then
  echo "PASS  WARP_RESERVED 渲染成 reserved 数组"; else echo "FAIL  warp reserved"; cat "$TMP/e"; fail=1; fi

CFGWO="$(ANYTLS_OK=1 ENABLE_BLOCK_BT=0 ENABLE_BLOCK_ADS=0 WARP_PRIVATE_KEY=k WARP_ADDR_V4=172.16.0.2/32 WARP_ADDR_V6=2606::2/128 render render_singbox_config)"
if printf '%s' "$CFGWO" | python -c "
import json,sys
d=json.load(sys.stdin)
assert d['endpoints'][0]['tag']=='warp'
r=d['route']
assert not any(x.get('protocol')=='bittorrent' for x in r['rules'])
assert [s['tag'] for s in r['rule_set']]==['geosite-openai','geosite-anthropic','geosite-google-gemini','geosite-netflix','geosite-disney'], [s['tag'] for s in r['rule_set']]
" 2>"$TMP/e"; then
  echo "PASS  WARP开+BT/ads关: 有endpoints, route仅warp规则"; else echo "FAIL  warp-only"; cat "$TMP/e"; fail=1; fi

CFGWS="$(ANYTLS_OK=1 ENABLE_BLOCK_BT=0 ENABLE_BLOCK_ADS=0 WARP_PRIVATE_KEY=k WARP_ADDR_V4=172.16.0.2/32 WARP_ADDR_V6=2606::2/128 WARP_SITES='tiktok, spotify ,Open"AI' render render_singbox_config)"
if printf '%s' "$CFGWS" | python -c "
import json,sys
d=json.load(sys.stdin)
r=d['route']
rule=[x for x in r['rules'] if x.get('outbound')=='warp'][0]
assert rule['rule_set']==['geosite-tiktok','geosite-spotify','geosite-openai'], rule['rule_set']
assert [s['tag'] for s in r['rule_set']]==['geosite-tiktok','geosite-spotify','geosite-openai'], [s['tag'] for s in r['rule_set']]
" 2>"$TMP/e"; then
  echo "PASS  WARP_SITES 自定义+清洗(去空格/大写/引号注入)"; else echo "FAIL  warp sites"; cat "$TMP/e"; fail=1; fi

echo
echo "=== 4i) 管理面板 admin(后端 + 面板页) ==="
APY="./_sbadmin_test.py"
PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ADMIN_PY="'"$APY"'" write_admin_py'
if python -m py_compile "$APY" 2>"$TMP/e"; then echo "PASS  admin 后端 py_compile"; else echo "FAIL  admin py_compile"; cat "$TMP/e"; fail=1; fi
if python - "$APY" <<'PYA' 2>"$TMP/e"
import importlib.util,sys
spec=importlib.util.spec_from_file_location("sbadmin",sys.argv[1])
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls=[]; m.run=lambda a,timeout=120:(calls.append(a) or (0,"ok"))
# 校验拦截非法输入 + 命令注入尝试
assert m.do_set({"limit_gb":"5.5.5"})["ok"] is False
assert m.do_set({"count_mode":"x"})["ok"] is False
assert m.do_set({"expire_at":"bad"})["ok"] is False
assert m.do_set({})["ok"] is False
assert m.do_set({"limit_gb":"200; rm -rf /"})["ok"] is False
assert m.do_set({"limit_gb":"$(id)"})["ok"] is False
# 合法 -> subprocess 参数数组(无 shell, 空格也是单参数)
calls.clear()
assert m.do_set({"limit_gb":"200","count_mode":"tx","expire_at":"2026-12-31 23:59:59 +0800"})["ok"] is True
assert calls[0]==["bash","/etc/sing-box/install.sh","set","LIMIT_GB=200","COUNT_MODE=tx","EXPIRE_AT=2026-12-31 23:59:59 +0800"], calls
# 动作白名单
assert m.do_action({"action":"evil; rm -rf /"})["ok"] is False
calls.clear(); assert m.do_action({"action":"restart"})["ok"] is True
assert calls[0]==["bash","/etc/sing-box/install.sh","restart"], calls
# 无 admin.env -> 空 token -> 鉴权一律拒绝
assert m.TOKEN==""
PYA
then echo "PASS  admin 后端 校验/注入拦截/参数数组/白名单/空token拒绝"; else echo "FAIL  admin backend logic"; cat "$TMP/e"; fail=1; fi
rm -f "$APY"; rm -rf ./__pycache__ 2>/dev/null
ADMINHTML="$(render render_admin_html)"
adm(){ if printf '%s' "$ADMINHTML" | grep -qF "$1"; then echo "PASS  面板含 $2"; else echo "FAIL  面板缺 $2"; fail=1; fi; }
adm '__TOKEN__'   'token 占位(后端注入)'
adm 'id="limit"'  '限额输入框'
adm 'id="expire"' '到期输入框'
adm '/api/set'    'set API 端点'
adm 'X-Token'     'token 鉴权头'
adm '127.0.0.1'   '仅本机访问说明'

echo
echo
echo "=== 4j) 重装保参数 merge_env_defaults + detect_net set -e 陷阱 ==="
# 重装(二次运行 install)必须沿用已有 ENVFILE 的运行参数, 否则会静默把 LIMIT_GB 打回 200、
# EXPIRE_AT 顺延成"安装日+365天"、HY2 带宽护栏被清空。
MENV="$TMP/mergeenv.env"
cat >"$MENV" <<'ENVEOF'
LIMIT_GB=500
EXPIRE_AT="2026-08-03 10:22:10 +0800"
COUNT_MODE=max
HY2_UP_MBPS=80
HY2_DOWN_MBPS=160
ENVEOF
# a) 无显式 env: 文件值应被完整沿用
#    注意 unset: 本测试脚本顶部 export 了 LIMIT_GB=200, 不清掉就会被正确地当成"用户显式传入"而优先
out=$(unset LIMIT_GB COUNT_MODE EXPIRE_AT HY2_UP_MBPS HY2_DOWN_MBPS; PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$MENV"'"; merge_env_defaults >/dev/null 2>&1; echo "$LIMIT_GB|$COUNT_MODE|$HY2_UP_MBPS|$HY2_DOWN_MBPS|$EXPIRE_AT"' 2>/dev/null)
if [ "$out" = '500|max|80|160|2026-08-03 10:22:10 +0800' ]; then
  echo "PASS  重装沿用已有运行参数(LIMIT_GB/COUNT_MODE/HY2护栏/EXPIRE_AT)"
else echo "FAIL  merge_env_defaults 未沿用文件值: got '$out'"; fail=1; fi
# b) 显式传入的 env 必须仍然优先于文件值
out=$(LIMIT_GB=999 PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; ENVFILE="'"$MENV"'"; merge_env_defaults >/dev/null 2>&1; echo "$LIMIT_GB|$COUNT_MODE"' 2>/dev/null)
if [ "$out" = '999|max' ]; then
  echo "PASS  显式传入 env 优先于文件值(LIMIT_GB=999 覆盖, 其余仍沿用)"
else echo "FAIL  显式 env 未优先: got '$out'"; fail=1; fi
# c) detect_net 在纯 IPv6(ip -4 route get 失败)时不能被 set -e 静默打断, 要走到 die 提示
#    unset PUBLIC_IP: 顶部 export 了 1.2.3.4, 不清掉 detect_net 会短路、测不到这条路径
out=$(unset PUBLIC_IP INTERFACE; PYTHON="$PYTHON_BIN" bash -c '
  source ./install.sh >/dev/null 2>&1
  set -euo pipefail
  curl(){ return 1; }; ip(){ return 2; }          # 模拟纯 IPv6: curl -4 与 ip -4 route 全失败
  die(){ echo "REACHED_DIE"; exit 9; }
  detect_net' 2>&1)
case "$out" in
  *REACHED_DIE*) echo "PASS  detect_net 探测失败时走到 die 提示(未被 set -e 静默退出)" ;;
  *) echo "FAIL  detect_net 疑似被 set -e 静默打断(应出现 REACHED_DIE): '$out'"; fail=1 ;;
esac

echo
echo "=== 4k) SSH 加固 do_harden(防锁死护栏 + 回滚) ==="
# do_harden 是全脚本唯一能把用户锁在 SSH 门外的函数, 这里覆盖它的 4 条安全性质。
# 路径全部指到临时目录(AKEYS/SSHD_CONFIG/SSHD_DROPIN_DIR), 不碰本机真实 SSH 配置。
HD="$TMP/harden"
# 公共 stub: 让 do_harden 在无 systemd/无 sshd 的 Windows 上也能跑到关键分支
HSTUB='detect_os(){ PKG=apt; }; systemctl(){ return 0; }; apt-get(){ return 0; }; export DEBIAN_FRONTEND=""'
# $1=场景名 $2=authorized_keys 内容 $3=sshd_config 内容 $4=sshd -t 结果(0/1)
harden_run() {
  rm -rf "$HD"; mkdir -p "$HD/dropin"
  printf '%s' "$2" > "$HD/authorized_keys"
  printf '%s' "$3" > "$HD/sshd_config"
  PYTHON="$PYTHON_BIN" bash -c '
    set +euo pipefail
    source ./install.sh >/dev/null 2>&1
    '"$HSTUB"'
    sshd(){ return '"$4"'; }
    AKEYS="'"$HD"'/authorized_keys"
    SSHD_CONFIG="'"$HD"'/sshd_config"
    SSHD_DROPIN_DIR="'"$HD"'/dropin"
    do_harden >/dev/null 2>&1
    echo "rc=$?"' 2>/dev/null
}
VALIDKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host
'
INCLUDE_CFG='Include /etc/ssh/sshd_config.d/*.conf
PasswordAuthentication yes
'
DROPIN="$HD/dropin/00-singbox-harden.conf"

# (1) 最关键: 没有有效公钥时必须拒绝, 且不能留下任何 drop-in(否则重启 sshd 就锁死)
rc=$(harden_run "nokey" "# just a comment, no key
" "$INCLUDE_CFG" 0)
if [ "$rc" != "rc=0" ] && [ ! -f "$DROPIN" ]; then
  echo "PASS  do_harden 无有效公钥时拒绝加固且不写 drop-in(防锁死)"
else echo "FAIL  do_harden 无公钥时未拒绝或已写 drop-in ($rc, dropin存在=$([ -f "$DROPIN" ] && echo yes || echo no))"; fail=1; fi

# (2) 空 authorized_keys 同样要拒绝
rc=$(harden_run "empty" "" "$INCLUDE_CFG" 0)
if [ "$rc" != "rc=0" ] && [ ! -f "$DROPIN" ]; then
  echo "PASS  do_harden 空 authorized_keys 时拒绝加固"
else echo "FAIL  do_harden 空公钥文件未拒绝 ($rc)"; fail=1; fi

# (3) 有公钥 + sshd -t 通过: 应写入 4 条关键指令
rc=$(harden_run "ok" "$VALIDKEY" "$INCLUDE_CFG" 0)
if [ -f "$DROPIN" ] \
   && grep -q '^PasswordAuthentication no' "$DROPIN" \
   && grep -q '^PubkeyAuthentication yes' "$DROPIN" \
   && grep -q '^KbdInteractiveAuthentication no' "$DROPIN" \
   && grep -q '^PermitRootLogin prohibit-password' "$DROPIN"; then
  echo "PASS  do_harden 有公钥时写入 drop-in 且四条指令齐全"
else echo "FAIL  do_harden drop-in 内容不正确 ($rc)"; [ -f "$DROPIN" ] && cat "$DROPIN"; fail=1; fi

# (4) sshd -t 校验不过: 必须回滚删掉 drop-in 并非零退出(否则 reload 后锁死)
rc=$(harden_run "badcfg" "$VALIDKEY" "$INCLUDE_CFG" 1)
if [ "$rc" != "rc=0" ] && [ ! -f "$DROPIN" ]; then
  echo "PASS  do_harden sshd -t 不过时回滚 drop-in 并报错退出"
else echo "FAIL  do_harden 校验失败未回滚 ($rc, dropin存在=$([ -f "$DROPIN" ] && echo yes || echo no))"; fail=1; fi

# (5) 主文件无 Include 时走兜底: 改主文件并留备份; 校验不过要把主文件还原回去
rc=$(harden_run "noinclude" "$VALIDKEY" "PasswordAuthentication yes
" 1)
if [ "$rc" != "rc=0" ] && ! grep -q '^PasswordAuthentication no' "$HD/sshd_config" 2>/dev/null; then
  echo "PASS  do_harden 无 Include 兜底改主文件, 校验失败后还原主文件"
else echo "FAIL  do_harden 兜底分支未还原主文件 ($rc)"; sed -n '1,5p' "$HD/sshd_config" 2>/dev/null; fail=1; fi

echo
echo "=== 4l) 机型协议组合开关 ENABLE_HY2 / SS_UDP(对齐文档「按机型选协议组合」) ==="
# 默认: 四协议齐全
render 'render_singbox_config' > "$TMP/sb_all.json"
if python -c "import json,sys; d=json.load(open(sys.argv[1])); t=[i['tag'] for i in d['inbounds']]; sys.exit(0 if 'hy2-in' in t else 1)" "$TMP/sb_all.json" 2>/dev/null; then
  echo "PASS  默认含 hy2-in 入站"; else echo "FAIL  默认应含 hy2-in"; fail=1; fi
# ENABLE_HY2=0: 服务端不应有 hy2 入站, 且 JSON 仍合法
out=$(ENABLE_HY2=0 render 'render_singbox_config')
if printf '%s' "$out" | python -c "import json,sys; d=json.load(sys.stdin); t=[i['tag'] for i in d['inbounds']]; sys.exit(0 if ('hy2-in' not in t and 'vless-in' in t and 'ss-in' in t) else 1)" 2>/dev/null; then
  echo "PASS  ENABLE_HY2=0 服务端去掉 hy2-in 且 JSON 合法(其余协议保留)"
else echo "FAIL  ENABLE_HY2=0 服务端配置不正确"; fail=1; fi
# ENABLE_HY2=0: 订阅 YAML 不应有 Hysteria2 节点, 代理组也不能引用它(否则 mihomo 报错)
out=$(ENABLE_HY2=0 render 'render_subscription_yaml')
if ! printf '%s' "$out" | grep -q 'Hysteria2'; then
  echo "PASS  ENABLE_HY2=0 订阅不含 Hysteria2(节点与代理组均已去掉)"
else echo "FAIL  ENABLE_HY2=0 订阅仍残留 Hysteria2"; fail=1; fi
if printf '%s' "$out" | grep -q '"Vless"' && printf '%s' "$out" | grep -q '"SS2022"'; then
  echo "PASS  ENABLE_HY2=0 其余节点仍在订阅内"; else echo "FAIL  ENABLE_HY2=0 误删了其它节点"; fail=1; fi
# ENABLE_HY2=0: 通用分享链接不应有 hysteria2://
out=$(ENABLE_HY2=0 render 'render_share_links')
if ! printf '%s' "$out" | grep -q 'hysteria2://'; then
  echo "PASS  ENABLE_HY2=0 分享链接不含 hysteria2://"; else echo "FAIL  分享链接仍含 hysteria2://"; fail=1; fi
# SS_UDP=0: TCP-only 稳定版, 订阅应写 udp: false
out=$(SS_UDP=0 render 'render_subscription_yaml')
if printf '%s' "$out" | grep -A6 '"SS2022"' | grep -q 'udp: false'; then
  echo "PASS  SS_UDP=0 订阅 SS2022 写成 udp: false"; else echo "FAIL  SS_UDP=0 未生效"; fail=1; fi
out=$(render 'render_subscription_yaml')
if printf '%s' "$out" | grep -A6 '"SS2022"' | grep -q 'udp: true'; then
  echo "PASS  默认 SS2022 仍是 udp: true"; else echo "FAIL  默认 SS udp 不应变"; fail=1; fi
# SS_UDP=0 服务端必须真的不收 UDP: 只改订阅等于"客户端不走、端口还开着", 清洗敏感机风险仍在
out=$(SS_UDP=0 render 'render_singbox_config')
if printf '%s' "$out" | python -c "
import sys,json; d=json.load(sys.stdin)
ss=[i for i in d['inbounds'] if i['tag']=='ss-in'][0]
sys.exit(0 if ss.get('network')=='tcp' else 1)" 2>/dev/null; then
  echo "PASS  SS_UDP=0 服务端 ss-in 加 network:tcp(真的不收 UDP)"
else echo "FAIL  SS_UDP=0 服务端仍收 UDP"; fail=1; fi
out=$(render 'render_singbox_config')
if printf '%s' "$out" | python -c "
import sys,json; d=json.load(sys.stdin)
ss=[i for i in d['inbounds'] if i['tag']=='ss-in'][0]
sys.exit(0 if 'network' not in ss else 1)" 2>/dev/null; then
  echo "PASS  默认 ss-in 不限制 network(TCP+UDP)"; else echo "FAIL  默认不该限制 SS network"; fail=1; fi
# AnyTLS 订阅节点必须有 udp: true 和 client-fingerprint(与手搓文档模板一致);
# 缺 udp 会让 mihomo 默认不走 UDP, AnyTLS 作为 HY2 替补时 UDP 流量静默失败
out=$(render 'render_subscription_yaml')
if printf '%s' "$out" | grep -A8 '"AnyTLS"' | grep -q 'udp: true' \
   && printf '%s' "$out" | grep -A8 '"AnyTLS"' | grep -q 'client-fingerprint: chrome'; then
  echo "PASS  AnyTLS 节点含 udp: true 与 client-fingerprint(对齐文档模板)"
else echo "FAIL  AnyTLS 节点缺 udp/client-fingerprint"; fail=1; fi

echo
echo "=== 4m) SS2022 密钥长度随 SS_METHOD 自适应(改方法不再让 check 失败) ==="
out=$(PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1
  r=""
  for m in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
    SS_METHOD=$m; k=$(gen_ss_password)
    [ "$(ss_key_bytes "$k")" = "$(ss_need_bytes)" ] || r="$r BAD:$m"
  done
  # 同方法重跑必须判定为一致(否则会无谓地重新生成密钥、把客户端踢下线)
  SS_METHOD=2022-blake3-aes-128-gcm; k=$(gen_ss_password)
  [ "$(ss_key_bytes "$k")" = "$(ss_need_bytes)" ] || r="$r SAME_METHOD_MISDETECT"
  # 换成 256 位方法必须判定为不一致(触发重新生成)
  SS_METHOD=2022-blake3-aes-256-gcm
  [ "$(ss_key_bytes "$k")" != "$(ss_need_bytes)" ] || r="$r CHANGE_NOT_DETECTED"
  echo "${r:-OK}"' 2>/dev/null)
if [ "$out" = "OK" ]; then
  echo "PASS  SS 密钥长度与 SS_METHOD 匹配; 同方法不误重生成, 换方法能检出"
else echo "FAIL  SS 密钥长度逻辑有问题: $out"; fail=1; fi

echo
echo "=== 4n) doctor/status 订阅探测必须带 Host 头(否则健康机误报) ==="
# nginx 是双 server 结构: 默认 server(server_name _)一律 404, 订阅 server 绑 server_name $SUB_HOST。
# 不带 Host 的 curl 会命中默认 server 拿到 404, 让每台正常机器都报"订阅本机不可达"。
if grep -q 'curl -fsS -o /dev/null -m 5 -H "Host: \$SUB_HOST" "http://127.0.0.1\$SUB_PATH"' install.sh; then
  echo "PASS  doctor 订阅探测带 Host 头"; else echo "FAIL  doctor 订阅探测缺 Host 头(健康机会误报不可达)"; fail=1; fi
if grep -q 'curl -s -o /dev/null -H "Host: \$SUB_HOST"' install.sh; then
  echo "PASS  status 订阅探测带 Host 头"; else echo "FAIL  status 订阅探测缺 Host 头"; fail=1; fi
# 确认 nginx 确实是"默认 server 404 + 订阅 server 绑 SUB_HOST"这个结构(上面结论的前提)
if grep -q 'server_name _;' install.sh && grep -q 'server_name \$SUB_HOST;' install.sh; then
  echo "PASS  nginx 双 server 结构成立(默认404 + 订阅绑 SUB_HOST)"; else echo "FAIL  nginx server 结构与预期不符"; fail=1; fi

echo
echo "=== 4o) ENABLE_OBFS=0 能在已装机器上真正关闭 HY2 混淆 ==="
OBT="$TMP/obfs"; rm -rf "$OBT"; mkdir -p "$OBT"
printf 'SS_PASSWORD="MTIzNDU2Nzg5MGFiY2RlZg=="\nOBFS_PASSWORD="oldobfs123"\nSUB_B64_PATH=/b.txt\nPANEL_PATH=/p.html\nSUB_PATH=/s.yaml\n' > "$OBT/secrets.env"
out=$(ENABLE_OBFS=0 PYTHON="$PYTHON_BIN" bash -c '
  set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SB_DIR="'"$OBT"'"; SECRETS="'"$OBT"'/secrets.env"
  gen_secrets >/dev/null 2>&1
  echo "OBFS=[$OBFS_PASSWORD]"' 2>/dev/null)
if [ "$out" = "OBFS=[]" ] && ! grep -q '^OBFS_PASSWORD=' "$OBT/secrets.env"; then
  echo "PASS  ENABLE_OBFS=0 清空 OBFS_PASSWORD 并从 secrets 删除(混淆真的关掉)"
else echo "FAIL  ENABLE_OBFS=0 未能关闭混淆: $out"; fail=1; fi
# 默认(ENABLE_OBFS=1)不能误删已有 obfs 密码
printf 'SS_PASSWORD="MTIzNDU2Nzg5MGFiY2RlZg=="\nOBFS_PASSWORD="keepme123"\nSUB_B64_PATH=/b.txt\nPANEL_PATH=/p.html\nSUB_PATH=/s.yaml\n' > "$OBT/secrets.env"
out=$(PYTHON="$PYTHON_BIN" bash -c '
  set +euo pipefail; source ./install.sh >/dev/null 2>&1
  SB_DIR="'"$OBT"'"; SECRETS="'"$OBT"'/secrets.env"
  gen_secrets >/dev/null 2>&1
  echo "OBFS=[$OBFS_PASSWORD]"' 2>/dev/null)
if [ "$out" = "OBFS=[keepme123]" ]; then
  echo "PASS  默认不误删已有 OBFS_PASSWORD"; else echo "FAIL  默认误改了 obfs 密码: $out"; fail=1; fi

echo
echo "=== 5) 流量头 + 内嵌脚本 ==="
render 'render_header "2026-12-31 23:59:59 +0800"' > "$TMP/hdr.txt"
if grep -q 'add_header Subscription-Userinfo "upload=0; download=0; total=214748364800; expire=1798732799" always;' "$TMP/hdr.txt"; then
  echo "PASS  流量头格式+数值正确(200GB=214748364800, 到期戳1798732799)"; else echo "FAIL  header"; cat "$TMP/hdr.txt"; fail=1; fi

awk '/cat >"\$TRAFFIC_PY" <<.PYEOF.$/{f=1;next} /^PYEOF$/{f=0} f' install.sh > "$TMP/traffic_limit.py"
if [ -s "$TMP/traffic_limit.py" ] && python -m py_compile "$TMP/traffic_limit.py" 2>"$TMP/e"; then
  echo "PASS  内嵌 traffic_limit.py py_compile 通过"; else echo "FAIL  traffic py_compile"; cat "$TMP/e"; fail=1; fi
if python - "$TMP/traffic_limit.py" <<'PYT' 2>"$TMP/e"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("traffic_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.STATE_DIR == "/var/lib/sing-box-node"
# os.path.join 在 Windows 开发机上会用反斜杠; 目标 Linux 上是正斜杠, 这里归一化后再比
assert m.QUOTA_FLAG.replace("\\", "/") == "/var/lib/sing-box-node/quota-stopped"
assert m.decide_enforcement(100, 100, True, False) == ("stop", True)
assert m.decide_enforcement(100, 100, False, False) == (None, False)
assert m.decide_enforcement(100, 100, False, True) == (None, True)
assert m.decide_enforcement(50, 100, False, True) == ("start", False)
assert m.decide_enforcement(50, 100, False, False) == (None, False)
# LIMIT_GB=0 => limit_bytes=0 表示"不限量", 不能被当成 0 字节配额而立刻永久停机
assert m.decide_enforcement(0, 0, True, False) == (None, False), "limit=0 在跑时不该停"
assert m.decide_enforcement(10**12, 0, True, False) == (None, False), "limit=0 无论用量多大都不该停"
assert m.decide_enforcement(0, 0, False, True) == ("start", False), "limit=0 应把此前配额停机的服务拉回来"
assert m.decide_enforcement(0, 0, False, False) == (None, False), "limit=0 不该拉起用户手动停的服务"
PYT
then echo "PASS  内嵌 traffic_limit.py 持久标记+手动停机状态机正确"; else echo "FAIL  traffic 状态机"; cat "$TMP/e"; fail=1; fi
if python - "$TMP/traffic_limit.py" <<'PYT' 2>"$TMP/e"
import importlib.util, sys, datetime
spec = importlib.util.spec_from_file_location("traffic_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
f = m.current_month_used
now = datetime.datetime(2026, 7, 27)
# 自然月: 命中当前 year/month 桶
nat = {"interfaces": [{"name": "eth0", "traffic": {"month": [
    {"date": {"year": 2026, "month": 6}, "rx": 100, "tx": 200},
    {"date": {"year": 2026, "month": 7}, "rx": 300, "tx": 400}]}}]}
assert f(nat, "eth0", "tx", now) == 400
assert f(nat, "eth0", "rx+tx", now) == 700
assert f(nat, "eth0", "max", now) == 400
# MonthRotate: 当前自然月无对应桶, 退回最后一个(当前账期)桶, 不再恒为 0
rot = {"interfaces": [{"name": "eth0", "traffic": {"month": [
    {"date": {"year": 2026, "month": 6}, "rx": 100, "tx": 200}]}}]}
assert f(rot, "eth0", "tx", now) == 200, "MonthRotate 账期桶应退回最后一个, 不是 0"
# 边界: 网卡不存在返回 None; 无月桶返回 0
assert f({"interfaces": []}, "eth0", "tx", now) is None
assert f({"interfaces": [{"name": "eth0", "traffic": {"month": []}}]}, "eth0", "tx", now) == 0
PYT
then echo "PASS  内嵌 traffic_limit.py 账期桶匹配(自然月命中/MonthRotate 退回/边界)"; else echo "FAIL  traffic 账期桶"; cat "$TMP/e"; fail=1; fi
if grep -q 'server_name _;' install.sh && grep -q 'listen 80 default_server' install.sh; then
  echo "PASS  nginx 使用默认 404 server + 订阅精确 server"; else echo "FAIL  nginx 双 server 静态检查"; fail=1; fi

echo
echo "=== 6) 输入校验 validate_inputs ==="
# 在干净子shell里用 env 覆盖变量后调用 validate_inputs;die 会以非0退出
run_validate() { env "$@" PYTHON="$PYTHON_BIN" bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; validate_inputs'; }
ok_case()   { if run_validate "$@" >/dev/null 2>&1; then echo "PASS  $D"; else echo "FAIL  $D"; fail=1; fi; }
bad_case()  { if run_validate "$@" >/dev/null 2>&1; then echo "FAIL  $D(应被拒却通过)"; fail=1; else echo "PASS  $D"; fi; }

D="默认参数通过校验";      ok_case  -u EXPIRE_AT -u DOMAIN
D="合法 EXPIRE_AT 通过";   ok_case  EXPIRE_AT="2026-12-31 23:59:59 +0800"
D="缺时区 EXPIRE_AT 被拒"; bad_case EXPIRE_AT="2026-12-31 23:59:59"
D="仅日期 EXPIRE_AT 被拒"; bad_case EXPIRE_AT="2026-12-31"
D="非数字端口被拒";        bad_case HY2_PORT="abc"
D="超范围端口被拒";        bad_case VLESS_PORT="70000"
D="非法 SNI 被拒";         bad_case REALITY_SNI="a;rm -rf"

echo
if [ "$fail" = 0 ]; then echo "==== ALL TESTS PASS ===="; else echo "==== SOME TESTS FAILED ===="; fi
exit $fail
