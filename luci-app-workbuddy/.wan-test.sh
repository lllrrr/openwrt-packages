#!/bin/sh
# 公网访问开关回归测试
# 验证：开关能真正创建/删除防火墙规则，且安全护栏有效

PW=$(uci -q get workbuddy.main.admin_password)
CJ=/tmp/ck-wan.txt; rm -f $CJ
curl -s -m 15 -c $CJ -X POST http://127.0.0.1:8789/admin/login -d "password=$PW" >/dev/null 2>&1

P=0; F=0
chk() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  [OK] $1"; else F=$((F+1)); echo "  [FAIL] $1 (expect=$3 got=$2)"; fi; }
WAN() { curl -s -m 30 -b $CJ -X POST http://127.0.0.1:8789/admin/api/config/save -H 'Content-Type: application/json' -d "$1"; }

echo "========== 公网访问开关回归 =========="
echo ""
echo "--- 0. 初始状态：应关闭且无规则 ---"
chk "UCI 无 workbuddy_wan 规则" "$(uci -q get firewall.workbuddy_wan.target 2>/dev/null || echo none)" "none"

echo ""
echo "--- 1. 查询 /admin/api/wan ---"
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/wan)
echo "$R" | grep -q '"active": false' && chk "active=false" ok ok || chk "active=false" no ok

echo ""
echo "--- 2. 打开开关 ---"
R=$(WAN '{"wan_access":"1"}')
echo "$R" | grep -q '"ok": true' && chk "接口返回 ok" ok ok || chk "接口返回 ok" "$R" ok

echo ""
echo "--- 3. 防火墙规则真的建了吗 ---"
chk "UCI 规则 target=DNAT" "$(uci -q get firewall.workbuddy_wan.target 2>/dev/null)" "DNAT"
chk "UCI 规则 src=wan"    "$(uci -q get firewall.workbuddy_wan.src 2>/dev/null)" "wan"
chk "UCI 规则 src_dport=8789" "$(uci -q get firewall.workbuddy_wan.src_dport 2>/dev/null)" "8789"
PORT=$(uci -q get workbuddy.main.port)
chk "dest_port 跟随服务端口" "$(uci -q get firewall.workbuddy_wan.dest_port 2>/dev/null)" "$PORT"

echo ""
echo "--- 4. nftables 里真的放行了吗 ---"
N=$(nft list ruleset 2>/dev/null | grep -c "dport $PORT")
if [ "$N" -gt 0 ]; then chk "nft 含 dport $PORT" ok ok; else chk "nft 含 dport $PORT" no ok; fi

echo ""
echo "--- 5. state 反映实际生效 ---"
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/state)
echo "$R" | grep -q '"active": true' && chk "state active=true" ok ok || chk "state active=true" no ok

echo ""
echo "--- 6. 服务端仍可访问（开关不影响本机）---"
chk "本机 /health 正常" "$(curl -s -m 15 http://127.0.0.1:8789/health | grep -c '"ok"')" "1"

echo ""
echo "--- 7. 关闭开关 ---"
R=$(WAN '{"wan_access":"0"}')
echo "$R" | grep -q '"ok": true' && chk "关闭返回 ok" ok ok || chk "关闭返回 ok" no ok
chk "UCI 规则已删除" "$(uci -q get firewall.workbuddy_wan.target 2>/dev/null || echo none)" "none"

echo ""
echo "--- 8. nftables 规则已回收 ---"
N=$(nft list ruleset 2>/dev/null | grep -c "dport $PORT")
chk "nft 已无 dport $PORT" "$N" "0"

echo ""
echo "--- 9. 幂等：重复关闭不报错 ---"
R=$(WAN '{"wan_access":"0"}')
echo "$R" | grep -q '"ok": true' && chk "重复关闭 ok" ok ok || chk "重复关闭 ok" no ok

echo ""
echo "--- 10. 防火墙整体完好（规则数不应崩）---"
FN=$(nft list ruleset 2>/dev/null | wc -l)
if [ "$FN" -gt 50 ]; then chk "nftables 规则集完整($FN 行)" ok ok; else chk "nftables 规则集完整" "$FN" ">50"; fi
chk "默认策略仍为 drop" "$(nft list chain inet fw4 input 2>/dev/null | grep -c 'policy drop')" "1"

echo ""
echo "--- 11. 自定义外部端口：开并设 wan_port=18789 ---"
R=$(WAN '{"wan_access":"1","wan_port":"18789"}')
echo "$R" | grep -q '"ok": true' && chk "开+设端口 ok" ok ok || chk "开+设端口 ok" "$R" ok
chk "src_dport=18789" "$(uci -q get firewall.workbuddy_wan.src_dport 2>/dev/null)" "18789"
chk "dest_port=内部端口" "$(uci -q get firewall.workbuddy_wan.dest_port 2>/dev/null)" "$PORT"
N=$(nft list ruleset 2>/dev/null | grep -cE "dport 18789([^0-9]|$)")
if [ "$N" -gt 0 ]; then chk "nft 含 dport 18789" ok ok; else chk "nft 含 dport 18789" no ok; fi
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/state)
echo "$R" | grep -q '"wanPort": *18789' && chk "state wanPort=18789" ok ok || chk "state wanPort=18789" no ok

echo ""
echo "--- 12. 非法端口应被拒 ---"
R=$(WAN '{"wan_port":"99999"}')
echo "$R" | grep -q '"ok": false' && chk "99999 被拒" ok ok || chk "99999 被拒" "$R" ok
R=$(WAN '{"wan_port":"abc"}')
echo "$R" | grep -q '"ok": false' && chk "abc 被拒" ok ok || chk "abc 被拒" no ok

echo ""
echo "--- 13. 清空端口回退内部 ---"
R=$(WAN '{"wan_access":"1","wan_port":""}')
echo "$R" | grep -q '"ok": true' && chk "清空端口 ok" ok ok || chk "清空端口 ok" "$R" ok
chk "src_dport 回退内部" "$(uci -q get firewall.workbuddy_wan.src_dport 2>/dev/null)" "$PORT"

echo ""
echo "--- 14. 保持开启时改端口立即生效 ---"
R=$(WAN '{"wan_port":"18889"}')
echo "$R" | grep -q '"ok": true' && chk "改端口 ok" ok ok || chk "改端口 ok" "$R" ok
chk "src_dport=18889" "$(uci -q get firewall.workbuddy_wan.src_dport 2>/dev/null)" "18889"

echo ""
echo "--- 15. 关闭并清理 ---"
R=$(WAN '{"wan_access":"0"}')
echo "$R" | grep -q '"ok": true' && chk "关闭 ok" ok ok || chk "关闭 ok" no ok
uci -q delete workbuddy.main.wan_port; uci commit workbuddy
chk "wan_port 已清理" "$(uci -q get workbuddy.main.wan_port 2>/dev/null || echo none)" "none"
chk "UCI 规则已删除" "$(uci -q get firewall.workbuddy_wan.target 2>/dev/null || echo none)" "none"

echo ""
echo "========== RESULT: PASS $P / FAIL $F =========="
