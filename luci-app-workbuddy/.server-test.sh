#!/bin/sh
# AI 中转服务器 —— 服务器与 Key 管理功能回归
# 覆盖：添加服务器 / 批量 Key / 改 Key / 停用启用 / 删除 / 前缀校验

PW=$(uci -q get workbuddy.main.admin_password)
CJ=/tmp/ck-srv.txt; rm -f $CJ
curl -s -m 15 -c $CJ -X POST http://127.0.0.1:8789/admin/login -d "password=$PW" >/dev/null 2>&1

KEY=$(cat /etc/workbuddy/apikeys.json 2>/dev/null | grep -o '"key"[^,]*' | head -1 | cut -d'"' -f4)
API() { curl -s -m 25 -b $CJ -X POST "http://127.0.0.1:8789/admin/api/upstreams/$1" -H 'Content-Type: application/json' -d "$2"; }

P=0; F=0
chk() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  [OK] $1"; else F=$((F+1)); echo "  [FAIL] $1 (expect=$3 got=$2)"; fi; }

echo "========== 服务器管理回归 =========="
echo ""
echo "--- 1. 添加服务器（批量 3 条 Key）---"
R=$(API add '{"name":"测试服务器","prefix":"tsrv","baseUrl":"https://example.com/v1","keys":"sk-aaa111\nsk-bbb222\nsk-aaa111\n\nsk-ccc333"}')
echo "$R" | grep -q '"keyCount": 3' && K=3 || K=$(echo "$R" | grep -o '"keyCount": *[0-9]*' | grep -o '[0-9]*')
chk "3 条去重后入库（输入 4 条含 1 重复 1 空行）" "$K" "3"
ID=$(echo "$R" | grep -o '"id": *"[^"]*"' | head -1 | cut -d'"' -f4)
echo "      id=$ID"

echo ""
echo "--- 2. 新服务器出现在 state 中 ---"
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/state)
echo "$R" | grep -q '"prefix": *"tsrv"' && D=ok || D=no
chk "state 含 tsrv" "$D" "ok"

echo ""
echo "--- 3. 改 Key：覆盖为 2 条 ---"
R=$(API keys "{\"id\":\"$ID\",\"keys\":\"sk-new1\nsk-new2\"}")
echo "$R" | grep -q '"count": *2' && D=ok || D=no
chk "改 Key 后为 2 条" "$D" "ok"

echo ""
echo "--- 4. 停用服务器 ---"
R=$(API toggle "{\"id\":\"$ID\",\"enabled\":false}")
echo "$R" | grep -q '"enabled": *false' && D=ok || D=no
chk "停用成功" "$D" "ok"
# 停用后模型应消失
curl -s -m 30 -H "Authorization: Bearer $KEY" http://127.0.0.1:8789/v1/models > /tmp/m.txt
grep -q '"tsrv/' /tmp/m.txt && D=no || D=ok
chk "停用后模型从 /v1/models 消失" "$D" "ok"

echo ""
echo "--- 5. 重新启用 ---"
R=$(API toggle "{\"id\":\"$ID\",\"enabled\":true}")
echo "$R" | grep -q '"enabled": *true' && D=ok || D=no
chk "启用成功" "$D" "ok"

echo ""
echo "--- 6. 删除服务器 ---"
R=$(API delete "{\"id\":\"$ID\"}")
echo "$R" | grep -q '"ok": *true' && D=ok || D=no
chk "删除成功" "$D" "ok"
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/state)
echo "$R" | grep -q '"prefix": *"tsrv"' && D=no || D=ok
chk "删除后 state 中不再出现" "$D" "ok"

echo ""
echo "--- 7. 删除不存在的 id ---"
R=$(API delete '{"id":"nonexistent-xyz"}')
echo "$R" | grep -q '"ok": *false' && D=ok || D=no
chk "返回 ok=false" "$D" "ok"

echo ""
echo "--- 8. 服务器数量回到 2（原有两台未受影响）---"
R=$(curl -s -m 15 http://127.0.0.1:8789/health)
echo "$R" | grep -q '"upstreams": *2' && D=ok || D=no
chk "upstreams=2" "$D" "ok"

echo ""
echo "--- 9. 管理页标题为产品名 ---"
curl -s -m 15 http://127.0.0.1:8789/admin | grep -q 'AI 中转服务器' && D=ok || D=no
chk "页面含「AI 中转服务器」" "$D" "ok"

echo ""
echo "========== RESULT: PASS $P / FAIL $F =========="
