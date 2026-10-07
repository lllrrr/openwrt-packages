#!/bin/sh
# EPG id 抓取失败根因诊断
EPG="https://live.fanmingming.cn/e.xml"

echo "=== 1. 路由器能否直接访问 EPG 源 ==="
curl -s -L -m 30 -o /tmp/epg-test.xml -w "code=%{http_code} size=%{size_download} time=%{time_total}\n" "$EPG"

echo ""
echo "=== 2. 文件大小与前 5 行 ==="
ls -l /tmp/epg-test.xml
head -c 400 /tmp/epg-test.xml
echo ""

echo ""
echo "=== 3. <channel 出现的次数（确认格式）==="
grep -c '<channel' /tmp/epg-test.xml
echo "--- 含 id= 的 channel 标签抽样 ---"
grep -o '<channel[^>]*>' /tmp/epg-test.xml | head -5

echo ""
echo "=== 4. busybox grep 是否支持 -o ==="
echo "hello world hello" | grep -o "hello" > /tmp/grep-o-test.txt 2>/tmp/grep-o-err.txt
echo "exit=$?"
echo "输出行数: $(wc -l < /tmp/grep-o-test.txt)"
cat /tmp/grep-o-test.txt
echo "stderr: $(cat /tmp/grep-o-err.txt)"

echo ""
echo "=== 5. 原管道（与 epgFetchIds 完全一致）实测 ==="
curl -s -L -m 60 "$EPG" | grep -o '<channel[^>]*id="[^"]*"' | sed 's/.*id="//;s/"//' | sort -u > /tmp/epg-orig.txt
echo "退出码=$?"
echo "行数: $(wc -l < /tmp/epg-orig.txt)"
echo "--- 内容 ---"
cat /tmp/epg-orig.txt

echo ""
echo "=== 6. 备选方案 A：纯 sed ==="
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epg-test.xml | sort -u > /tmp/epg-sed.txt
echo "行数: $(wc -l < /tmp/epg-sed.txt)"
head -8 /tmp/epg-sed.txt

echo ""
echo "=== 7. 备选方案 B：awk ==="
awk 'match($0, /<channel[^>]*id="[^"]*"/) { s=substr($0, RSTART, RLENGTH); sub(/.*id="/,"",s); sub(/"$/,"",s); print s }' /tmp/epg-test.xml | sort -u > /tmp/epg-awk.txt
echo "行数: $(wc -l < /tmp/epg-awk.txt)"
head -8 /tmp/epg-awk.txt

echo ""
echo "=== 8. 备选方案 C：tr 切分 ==="
tr '<' '\n' < /tmp/epg-test.xml | grep '^channel' | sed 's/.*id="//;s/".*//' | sort -u > /tmp/epg-tr.txt
echo "行数: $(wc -l < /tmp/epg-tr.txt)"
head -8 /tmp/epg-tr.txt

echo ""
echo "=== 9. ucode split 空串行为（验证根因假设）==="
ucode -e '
let s = "";
let parts = split("\n", s);
print("split(\"\\n\", \"\") 长度 = " + length(parts) + "\n");
print("内容 = " + sprintf("%J", parts) + "\n");
let parts2 = split("\n", "\n");
print("split(\"\\n\", \"\\n\") 长度 = " + length(parts2) + "\n");
let parts3 = split("\n", "a\n\nb\n");
print("split(\"\\n\", \"a\\n\\nb\\n\") = " + sprintf("%J", parts3) + " 长度=" + length(parts3) + "\n");
' 2>&1

echo ""
echo "=== 10. 清理 ==="
rm -f /tmp/epg-test.xml
echo "done"
