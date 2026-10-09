#!/bin/sh
#
# 凭据池管理功能回归测试（36 项断言）
#
# 在路由器上运行：
#     export WB_ADMIN_PW='你的管理员密码'
#     sh /root/luci-app-workbuddy/pool-test.sh
#
# 覆盖范围：
#   判重（token 全文 / 账号 sub / 跨 pool.json 与 token.json）
#   输入校验（过短、非 JWT、已过期）
#   增删改查、启停、单条可用性测试
#   计数一致性（池条目数 / 可用凭据数）
#   default 凭据的删除与停用保护
#   页面元素与外部依赖
#
# 测试会写入并清理临时凭据；结束时池文件恢复为空数组。

B=http://127.0.0.1:8789
PW="${WB_ADMIN_PW:?请先 export WB_ADMIN_PW=你的管理员密码}"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  [PASS] $1"; PASS=$((PASS+1)); else echo "  [FAIL] $1 期望=[$2] 实际=[$3]"; FAIL=$((FAIL+1)); fi }

rm -f /tmp/pc
curl -s -o /dev/null -m 8 -c /tmp/pc -X POST -d "password=$PW" $B/admin/login
G() { curl -s -b /tmp/pc -m 20 "$@"; }
# 提取 JSON 字段（无 jq）
jf() { sed -n "s/.*\"$2\": \(.*\)/\1/p" "$1" | head -1 | sed 's/[",]//g' | tr -d ' '; }

POOLN() { G $B/admin/api/state | grep -c '"source": "pool"'; }
USABLE() { curl -s -m 8 $B/health | sed -n 's/.*"credentials": \([0-9]*\).*/\1/p'; }

echo "############ 1. 关键回归：从 token.json 复制的 token 必须判重 ############"
REAL=$(sed -n 's/.*"accessToken": "\([^"]*\)".*/\1/p' /etc/workbuddy/token.json)
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"重复测试\",\"token\":\"$REAL\"}" \
  $B/admin/api/creds/add -o /tmp/a.json -w '  HTTP %{http_code}\n'
cat /tmp/a.json | sed 's/^/    /'
chk "与网页登录凭据重复 -> 被拒" "true" "$(grep -o '"dup": *true' /tmp/a.json | head -1 | grep -o true)"
chk "池中未被写入" 0 "$(POOLN)"

echo ""
echo "############ 2. 带 Bearer 前缀 + 首尾空格 ############"
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"x\",\"token\":\"  Bearer $REAL  \"}" \
  $B/admin/api/creds/add -o /tmp/b.json -w '  HTTP %{http_code}\n'
chk "归一化后仍判重" "true" "$(grep -o '"dup": *true' /tmp/b.json | head -1 | grep -o true)"
chk "池中仍为 0" 0 "$(POOLN)"

echo ""
echo "############ 3. 非 JWT / 无点号字符串必须被拒 ############"
G -X POST -H 'Content-Type: application/json' -d '{"name":"非JWT","token":"this-is-not-a-jwt-just-plain-text-1234567890"}' $B/admin/api/creds/add -o /tmp/d.json -w '  HTTP %{http_code}\n'
cat /tmp/d.json | sed 's/^/    /'
chk "无点号字符串被拒" "false" "$(jf /tmp/d.json ok)"
G -X POST -H 'Content-Type: application/json' -d '{"name":"差点号","token":"aaa.bbb.ccc-not-base64-json-at-all"}' $B/admin/api/creds/add -o /tmp/d2.json -w '  HTTP %{http_code}\n'
chk "有点号但解不出 payload 也被拒" "false" "$(jf /tmp/d2.json ok)"
chk "池中仍为 0" 0 "$(POOLN)"

echo ""
echo "############ 4. 过期 token 在添加时就被拒 ############"
H=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
P_EXP=$(printf '{"exp":1000000000,"sub":"acc-expired","preferred_username":"过期号"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"过期\",\"token\":\"$H.$P_EXP.sig\"}" \
  $B/admin/api/creds/add -o /tmp/e.json -w '  HTTP %{http_code}\n'
cat /tmp/e.json | sed 's/^/    /'
chk "过期被拒并标记 expired" "true" "$(grep -o '"expired": *true' /tmp/e.json | head -1 | grep -o true)"
chk "池中仍为 0" 0 "$(POOLN)"

echo ""
echo "############ 5. 添加合法的新账号（另一账号）############"
P_B=$(printf '{"exp":1999999999,"iat":1789990681,"sub":"acc-bbbb-0002","preferred_username":"账号B"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"\",\"token\":\"$H.$P_B.sig\"}" \
  $B/admin/api/creds/add -o /tmp/f.json -w '  HTTP %{http_code}\n'
cat /tmp/f.json | sed 's/^/    /'
IDB=$(jf /tmp/f.json id)
chk "添加成功" "true" "$(jf /tmp/f.json ok)"
chk "名称取自账号名" "账号B" "$(jf /tmp/f.json name)"
chk "池中有 1 条" 1 "$(POOLN)"
chk "可用凭据变为 2" 2 "$(USABLE)"

echo ""
echo "############ 6. 同账号换 token 再添加 -> 按 sub 判重 ############"
P_B2=$(printf '{"exp":1999999999,"iat":1790000000,"sub":"acc-bbbb-0002","preferred_username":"账号B"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"同账号新token\",\"token\":\"$H.$P_B2.sig2\"}" \
  $B/admin/api/creds/add -o /tmp/g.json -w '  HTTP %{http_code}\n'
cat /tmp/g.json | sed 's/^/    /'
chk "同账号被判重" "true" "$(grep -o '"dup": *true' /tmp/g.json | head -1 | grep -o true)"
chk "提示指向已有条目" "账号B" "$(jf /tmp/g.json existingName)"

echo ""
echo "############ 7. 再加第三个账号 ############"
P_C=$(printf '{"exp":1999999999,"iat":1789990681,"sub":"acc-cccc-0003","preferred_username":"账号C"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
G -X POST -H 'Content-Type: application/json' -d "{\"name\":\"手动命名C\",\"token\":\"$H.$P_C.sig\"}" \
  $B/admin/api/creds/add -o /tmp/h.json -w '  HTTP %{http_code}\n'
chk "第三条添加成功" "true" "$(jf /tmp/h.json ok)"
chk "自定义名称生效" "手动命名C" "$(jf /tmp/h.json name)"
IDC=$(jf /tmp/h.json id)
chk "池中 2 条" 2 "$(POOLN)"
chk "可用 3 条" 3 "$(USABLE)"

echo ""
echo "############ 8. 停用第三条 ############"
G -X POST -H 'Content-Type: application/json' -d "{\"id\":\"$IDC\",\"enabled\":\"false\"}" \
  $B/admin/api/creds/toggle -o /tmp/i.json
chk "停用返回 ok" "true" "$(jf /tmp/i.json ok)"
chk "可用降为 2" 2 "$(USABLE)"
chk "停用项仍显示在管理页" 2 "$(POOLN)"

echo ""
echo "############ 9. 重新启用 ############"
G -X POST -H 'Content-Type: application/json' -d "{\"id\":\"$IDC\",\"enabled\":\"true\"}" \
  $B/admin/api/creds/toggle -o /dev/null
chk "可用回到 3" 3 "$(USABLE)"

echo ""
echo "############ 10. 轮询负载均衡：3 条凭据应轮流被选中 ############"
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -m 30 -X POST $B/v1/chat/completions \
    -H "Authorization: Bearer wb-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
    -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"system","content":"s"},{"role":"user","content":"hi"}],"stream":false}'
done
echo "  最近的凭据选择（应有多个不同 id）："
logread 2>/dev/null | grep -oE "try cred [a-zA-Z0-9_-]+|using cred [a-zA-Z0-9_-]+" | tail -6 | sed 's/^/    /'
logread 2>/dev/null | grep -i "cred" | tail -4 | sed 's/^/    /'

echo ""
echo "############ 11. default 受保护 ############"
G -X POST -H 'Content-Type: application/json' -d '{"id":"default"}' $B/admin/api/creds/delete -o /tmp/j.json -w '  HTTP %{http_code}\n'
chk "default 不可删除" "false" "$(jf /tmp/j.json ok)"
G -X POST -H 'Content-Type: application/json' -d '{"id":"default","enabled":"false"}' $B/admin/api/creds/toggle -o /tmp/k.json -w '  HTTP %{http_code}\n'
chk "default 不可停用" "false" "$(jf /tmp/k.json ok)"

echo ""
echo "############ 12. 删除测试凭据 ############"
for id in $IDB $IDC; do
  G -X POST -H 'Content-Type: application/json' -d "{\"id\":\"$id\"}" $B/admin/api/creds/delete -o /tmp/l.json
  chk "删除 $id" "true" "$(jf /tmp/l.json ok)"
done
chk "池中清空" 0 "$(POOLN)"
chk "可用回到 1" 1 "$(USABLE)"

echo ""
echo "############ 13. 删除不存在的 id ############"
G -X POST -H 'Content-Type: application/json' -d '{"id":"nonexistent"}' $B/admin/api/creds/delete -o /tmp/m.json -w '  HTTP %{http_code}\n'
chk "返回 ok=false" "false" "$(jf /tmp/m.json ok)"

echo ""
echo "############ 14. 凭据测试接口 ############"
G -X POST -H 'Content-Type: application/json' -d '{"id":"default"}' $B/admin/api/creds/test -o /tmp/n.json
echo "  真实凭据测试结果："
cat /tmp/n.json | sed 's/^/    /'
chk "真实凭据测试通过" "true" "$(jf /tmp/n.json ok)"

echo ""
echo "############ 15. 页面与函数 ############"
G $B/admin -o /tmp/pg.html
chk "页面含添加凭据区块" 1 "$(grep -c '<h2>添加凭据</h2>' /tmp/pg.html)"
chk "页面含两种方式" 1 "$(grep -c '方式二' /tmp/pg.html)"
chk "页面无外部依赖" 0 "$(grep -c 'src="http\|href="http' /tmp/pg.html)"
chk "含过期徽章渲染" 1 "$(grep -c 'badge err\">已过期' /tmp/pg.html)"
chk "含测试按钮" 1 "$(grep -c 'function testCred' /tmp/pg.html)"

rm -f /tmp/pc /tmp/*.json /tmp/*.html
echo ""
echo "==================================================="
echo "   通过 $PASS 项 / 失败 $FAIL 项"
echo "==================================================="
