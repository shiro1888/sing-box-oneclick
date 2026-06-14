#!/usr/bin/env bash
# 在本机校验 install.sh：语法 + 渲染逻辑(真实生成配置后用 JSON/YAML 解析)
# 注: 用 Windows python 验证时强制 UTF-8(PYTHONUTF8), 否则写 🚀 会触发 gbk 编码错误;
#     Linux VPS 上是 UTF-8 locale, 无此问题。
cd "$(dirname "$0")" || exit 1
# MSYS2_ENV_CONV_EXCL: 阻止 Git Bash 把 /cf-abc 这种斜杠开头的环境变量值转成 Windows 路径
# (纯 Windows 测试环境问题; Linux VPS 上不存在路径转换)
export PYTHON=python PYTHONUTF8=1 PYTHONIOENCODING=utf-8 MSYS2_ENV_CONV_EXCL='CF_WS_PATH'
fail=0
TMP="${TMPDIR:-/tmp}"

# 公共测试参数(导出, 供子shell source 后复用)
export SB_DIR="$TMP/sbtest" HY2_PORT=4433 ANYTLS_PORT=4434 VLESS_PORT=443 \
  HY2_PASSWORD=pw1 ANYTLS_PASSWORD=pw2 VLESS_UUID=11111111-1111-1111-1111-111111111111 \
  REALITY_PRIVATE_KEY=PRIVKEY REALITY_PUBLIC_KEY=PUBKEY REALITY_SHORT_ID=abcdef0123456789 \
  REALITY_SNI=www.microsoft.com TLS_SNI=www.bing.com PUBLIC_IP=1.2.3.4 LIMIT_GB=200 \
  SS_PORT=4435 SS_METHOD=2022-blake3-aes-128-gcm SS_PASSWORD=MTIzNDU2Nzg5MGFiY2RlZg==

# 在干净子shell里 source 脚本(guard 阻止 main 运行)并调用一个渲染函数
render() { PYTHON=python bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; '"$1"; }

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

if printf '%s' "$CFG3" | python -c "import json,sys;v=[i for i in json.load(sys.stdin)['inbounds'] if i['tag']=='vless-in'][0];assert v['tls']['server_name']==v['tls']['reality']['handshake']['server'];assert v['users'][0]['flow']=='xtls-rprx-vision'" 2>"$TMP/e"; then
  echo "PASS  Reality server_name==handshake.server 且 flow 正确"; else echo "FAIL  reality"; cat "$TMP/e"; fail=1; fi

echo
echo "=== 4) 渲染 Clash 订阅 ==="
ANYTLS_OK=1 DOMAIN="" render render_subscription_yaml > "$TMP/sub.yaml"
if python - "$TMP/sub.yaml" <<'PYV' 2>"$TMP/e"
import yaml,sys
d=yaml.safe_load(open(sys.argv[1],encoding='utf-8'))
names=[p['name'] for p in d['proxies']]
assert names==['Hysteria2','AnyTLS','Vless','SS2022'], names
g=d['proxy-groups'][0]
assert g['type']=='select'
assert all(x in names for x in g['proxies']), g['proxies']
assert d['rules'][-1].startswith('MATCH,'), d['rules'][-1]
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
echo "=== 5) 流量头 + 内嵌脚本 ==="
render 'render_header "2026-12-31 23:59:59 +0800"' > "$TMP/hdr.txt"
if grep -q 'add_header Subscription-Userinfo "upload=0; download=0; total=214748364800; expire=1798732799" always;' "$TMP/hdr.txt"; then
  echo "PASS  流量头格式+数值正确(200GB=214748364800, 到期戳1798732799)"; else echo "FAIL  header"; cat "$TMP/hdr.txt"; fail=1; fi

awk '/cat >"\$TRAFFIC_PY" <<.PYEOF.$/{f=1;next} /^PYEOF$/{f=0} f' install.sh > "$TMP/traffic_limit.py"
if [ -s "$TMP/traffic_limit.py" ] && python -m py_compile "$TMP/traffic_limit.py" 2>"$TMP/e"; then
  echo "PASS  内嵌 traffic_limit.py py_compile 通过"; else echo "FAIL  traffic py_compile"; cat "$TMP/e"; fail=1; fi

echo
echo "=== 6) 输入校验 validate_inputs ==="
# 在干净子shell里用 env 覆盖变量后调用 validate_inputs;die 会以非0退出
run_validate() { env "$@" PYTHON=python bash -c 'set +euo pipefail; source ./install.sh >/dev/null 2>&1; validate_inputs'; }
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
