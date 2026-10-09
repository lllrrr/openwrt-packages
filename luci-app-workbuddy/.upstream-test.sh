#!/bin/sh
KEY=$(cat /etc/workbuddy/apikeys.json 2>/dev/null | grep -o '"key"[^,]*' | head -1 | cut -d'"' -f4)
PW=$(uci -q get workbuddy.main.admin_password)
CJ=/tmp/ck2.txt; rm -f $CJ
curl -s -m 15 -c $CJ -X POST http://127.0.0.1:8789/admin/login -d "password=$PW" >/dev/null 2>&1
sleep 62

P=0; F=0
chk() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  [OK] $1"; else F=$((F+1)); echo "  [FAIL] $1 (expect=$3 got=$2)"; fi; }

echo "========== upstream feature regression =========="
echo ""
echo "--- A. model aggregation ---"
M=$(curl -s -m 40 -H "Authorization: Bearer $KEY" http://127.0.0.1:8789/v1/models)
N=$(echo "$M" | grep -o '"id": "workbuddy/' | wc -l)
chk "workbuddy prefix count=3" "$N" "3"
N=$(echo "$M" | grep -o '"id": "sensenova/' | wc -l)
if [ "$N" -ge 8 ]; then D=yes; else D=no; fi
chk "sensenova prefix >=8" "$D" "yes"
N=$(echo "$M" | grep -o '"id": "askdiandian/' | wc -l)
chk "askdiandian prefix=1" "$N" "1"

echo ""
echo "--- B. health counters ---"
H=$(curl -s -m 15 http://127.0.0.1:8789/health)
echo "$H" | grep -q '"upstreams": 2' && D=ok || D=no
chk "upstreams=2" "$D" "ok"
echo "$H" | grep -q '"upstreamKeys": 6' && D=ok || D=no
chk "upstreamKeys=6" "$D" "ok"

echo ""
echo "--- C. real chat through each upstream ---"
R=$(curl -s -m 45 -X POST http://127.0.0.1:8789/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"workbuddy/hy3","messages":[{"role":"user","content":"reply OK"}],"max_tokens":20,"stream":false}')
echo "$R" | grep -q '"choices"' && D=ok || D=no
chk "workbuddy/hy3" "$D" "ok"

R=$(curl -s -m 45 -X POST http://127.0.0.1:8789/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"sensenova/deepseek-v4-flash","messages":[{"role":"user","content":"reply OK"}],"max_tokens":20,"stream":false}')
echo "$R" | grep -q '"choices"' && D=ok || D=no
chk "sensenova" "$D" "ok"

R=$(curl -s -m 45 -X POST http://127.0.0.1:8789/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"askdiandian/dots3-note-prev","messages":[{"role":"user","content":"reply OK"}],"max_tokens":20,"stream":false}')
echo "$R" | grep -q '"choices"' && D=ok || D=no
chk "askdiandian" "$D" "ok"

echo ""
echo "--- D. error handling ---"
R=$(curl -s -m 15 -X POST http://127.0.0.1:8789/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"nope/foo","messages":[{"role":"user","content":"hi"}]}')
echo "$R" | grep -q 'unknown upstream prefix' && D=ok || D=no
chk "unknown prefix rejected" "$D" "ok"

echo ""
echo "--- E. admin api ---"
R=$(curl -s -m 20 -b $CJ http://127.0.0.1:8789/admin/api/state)
# 注意：state 是 %.J 美化过的 JSON，键值之间有空格，
# 匹配时不能用 '"prefix":"x"' 这种紧凑写法（测试脚本自身的坑）。
echo "$R" | grep -q '"prefix": *"sensenova"' && D=ok || D=no
chk "state has sensenova" "$D" "ok"
echo "$R" | grep -q 'keyUsable' && D=ok || D=no
chk "state has keyUsable" "$D" "ok"

ID=$(echo "$R" | grep -o '"id": *"u[0-9-]*"' | head -1 | cut -d'"' -f4)
R=$(curl -s -m 30 -b $CJ -X POST http://127.0.0.1:8789/admin/api/upstreams/test -H 'Content-Type: application/json' -d "{\"id\":\"$ID\"}")
echo "$R" | grep -q '"ok": true' && D=ok || D=no
chk "upstreams/test ok" "$D" "ok"

echo ""
echo "--- F. input validation ---"
# 用 ok:false 判定被拒；错误文案是中文，避免依赖具体措辞
R=$(curl -s -m 15 -b $CJ -X POST http://127.0.0.1:8789/admin/api/upstreams/add -H 'Content-Type: application/json' -d '{"prefix":"AB!","baseUrl":"https://x.com/v1","keys":"k"}')
echo "$R" | grep -q '"ok": *false' && D=ok || D=no
chk "bad prefix rejected" "$D" "ok"

R=$(curl -s -m 15 -b $CJ -X POST http://127.0.0.1:8789/admin/api/upstreams/add -H 'Content-Type: application/json' -d '{"prefix":"t1","baseUrl":"ftp://x","keys":"k"}')
echo "$R" | grep -q '"ok": *false' && D=ok || D=no
chk "bad url rejected" "$D" "ok"

R=$(curl -s -m 15 -b $CJ -X POST http://127.0.0.1:8789/admin/api/upstreams/add -H 'Content-Type: application/json' -d '{"prefix":"sensenova","baseUrl":"https://x.com/v1","keys":"k"}')
echo "$R" | grep -q '"ok": *false' && D=ok || D=no
chk "dup prefix rejected" "$D" "ok"

R=$(curl -s -m 15 -b $CJ -X POST http://127.0.0.1:8789/admin/api/upstreams/add -H 'Content-Type: application/json' -d '{"prefix":"t2","baseUrl":"https://x.com/v1","keys":""}')
echo "$R" | grep -q '"ok": *false' && D=ok || D=no
chk "empty keys rejected" "$D" "ok"

echo ""
echo "--- G. multi-key round robin ---"
# 连续打 4 次，Key 应从池中轮换（日志里能看到不同掩码）
for i in 1 2 3 4; do
  curl -s -m 40 -X POST http://127.0.0.1:8789/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"model":"askdiandian/dots3-note-prev","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}' >/dev/null 2>&1
done
USED=$(logread 2>/dev/null | grep -o 'upstream askdiandian key ak_[a-z]*' | tail -8 | sort -u | wc -l)
if [ "$USED" -ge 2 ]; then D=ok; else D=no; fi
chk "askdiandian 轮询使用 >=2 条 key (实际 $USED)" "$D" "ok"

echo ""
echo "========== RESULT: PASS $P / FAIL $F =========="
