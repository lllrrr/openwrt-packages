#!/bin/sh
# migu.uc 1.3.1 部署（修 EPG 抓取 + chFallback 计数），带回滚
SRC=/tmp/migu-131.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.3.0.bak

echo "=== 0. 语法检查 ==="
if [ ! -f "$SRC" ]; then echo "FAIL: 源文件不存在"; exit 1; fi
ucode -c -o /tmp/chk131.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "OK"

echo ""
echo "=== 1. 备份 1.3.0 ==="
cp "$DST" "$BAK"
md5sum "$BAK"; echo "行数 $(wc -l < $BAK)"

echo ""
echo "=== 2. 部署 ==="
cp "$SRC" "$DST"; chmod 755 "$DST"
md5sum "$DST"; echo "行数 $(wc -l < $DST)"

echo ""
echo "=== 3. 重启 ==="
/etc/init.d/migu restart
sleep 3
ps w | grep "[m]igu.uc" || { echo "FAIL: 进程未起，回滚"; cp "$BAK" "$DST"; /etc/init.d/migu restart; exit 1; }

echo ""
echo "=== 4. 等 EPG 首次拉取（8 秒延迟）==="
sleep 12
logread 2>/dev/null | grep -i "EPG" | tail -5

echo ""
echo "=== 5. /health EPG 字段 ==="
curl -s -m 10 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E "version|epg|chFallback"

echo ""
echo "=== 6. 决定性验证：/m3u 的 tvg-id 是否已映射成标准 id ==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m3u131.txt
echo "字节数 $(wc -c < /tmp/m3u131.txt)"
echo "--- 前 6 条 ---"
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | head -6
echo "--- 仍是中文名的条数（应远小于 174）---"
grep -c 'tvg-id="[^"]*[综合体育高清影视新闻纪录少儿]' /tmp/m3u131.txt || true
echo "--- 标准 id 命中条数 ---"
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | grep -cE 'tvg-id="(CCTV[0-9]+|CCTV5\+|CCTV4K|CGTN|东方卫视|凤凰|湖南卫视|浙江卫视|江苏卫视|北京卫视|广东卫视|深圳卫视|CHC|CETV)' || true
