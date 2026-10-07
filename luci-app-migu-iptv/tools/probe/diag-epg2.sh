#!/bin/sh
# EPG 管道逐段截断定位
EPG="https://live.fanmingming.cn/e.xml"
cd /tmp

echo "=== 0. 服务日志里的 EPG 记录（决定性证据）==="
logread 2>/dev/null | grep -i "EPG" | tail -20 || echo "(无)"

echo ""
echo "=== 1. 逐段计数：grep -o 单独 ==="
curl -s -L -m 60 "$EPG" | grep -o '<channel[^>]*id="[^"]*"' | wc -l

echo "=== 2. grep -o | sed ==="
curl -s -L -m 60 "$EPG" | grep -o '<channel[^>]*id="[^"]*"' | sed 's/.*id="//;s/"//' | wc -l

echo "=== 3. grep -o | sed | sort -u ==="
curl -s -L -m 60 "$EPG" | grep -o '<channel[^>]*id="[^"]*"' | sed 's/.*id="//;s/"//' | sort -u | wc -l

echo "=== 4. 换成 sed 全流程 ==="
curl -s -L -m 60 "$EPG" | sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' | sort -u | wc -l

echo "=== 5. 先落盘再 grep -o（排除流式管道因素）==="
curl -s -L -m 60 -o epg2.xml "$EPG"
ls -l epg2.xml
grep -o '<channel[^>]*id="[^"]*"' epg2.xml | wc -l
grep -o '<channel[^>]*id="[^"]*"' epg2.xml | sed 's/.*id="//;s/"//' | sort -u | wc -l
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' epg2.xml | sort -u | wc -l

echo ""
echo "=== 6. grep 版本与类型 ==="
grep --help 2>&1 | head -3
ls -l $(which grep) 2>/dev/null
busybox 2>&1 | head -2

echo ""
echo "=== 7. 关键：ucode sh() 到底拿到多少字节 ==="
cat > /tmp/shtest.uc <<'UCEOF'
let cmd = "curl -s -L -m 60 'https://live.fanmingming.cn/e.xml' | grep -o '<channel[^>]*id=\"[^\"]*\"' | sed 's/.*id=\"//;s/\"//' | sort -u";
let out = sh(cmd);
print("out 长度 = " + length(out) + "\n");
print("out 前 200 字节 = " + sprintf("%J", substr(out, 0, 200)) + "\n");
let lines = split(trim(out), '\n');
print("split 后 length = " + length(lines) + "\n");
let ids = [];
for (let ln in lines) { let s = trim(ln); if (s !== '') push(ids, s); }
print("过滤后 id 数 = " + length(ids) + "\n");
print("前 5 = " + sprintf("%J", slice(ids, 0, 5)) + "\n");
UCEOF
ucode /tmp/shtest.uc 2>&1

echo ""
echo "=== 8. ucode sh() 换成 sed 管道 ==="
cat > /tmp/shtest2.uc <<'UCEOF'
let cmd = "curl -s -L -m 60 'https://live.fanmingming.cn/e.xml' | sed -n 's/.*<channel[^>]*id=\"\\([^\"]*\\)\".*/\\1/p' | sort -u";
let out = sh(cmd);
print("out 长度 = " + length(out) + "\n");
let lines = split(trim(out), '\n');
let ids = [];
for (let ln in lines) { let s = trim(ln); if (s !== '') push(ids, s); }
print("过滤后 id 数 = " + length(ids) + "\n");
print("前 5 = " + sprintf("%J", slice(ids, 0, 5)) + "\n");
UCEOF
ucode /tmp/shtest2.uc 2>&1

echo ""
echo "=== 9. 清理 ==="
rm -f epg2.xml
echo done
