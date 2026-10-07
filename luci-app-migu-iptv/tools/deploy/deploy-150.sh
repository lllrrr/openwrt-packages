#!/bin/sh
# deploy-150.sh — 部署 migu.uc 1.5.0 到路由器
set -x
NEW=/tmp/migu-150.uc
TGT=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.4.1.bak

# 1. 语法检查（\x47 / delete / 字符串比较等特性已用探针验证）
ucode -c "$NEW" || { echo "SYNTAX FAIL"; exit 1; }
echo "syntax OK"

# 2. 备份并部署
cp "$TGT" "$BAK" || { echo "BACKUP FAIL"; exit 1; }
cp "$NEW" "$TGT" || { echo "COPY FAIL"; exit 1; }
chmod +x "$TGT"
sync

# 3. 重启服务
/etc/init.d/migu enable
/etc/init.d/migu restart
sleep 20

# 4. 健康检查
echo "---- /health ----"
curl -s -m 5 http://127.0.0.1:8788/health
echo
echo "---- md5 ----"
md5sum "$TGT"
echo "---- /m3u ----"
curl -s -m 5 -o /tmp/m3u150.out -w "HTTP=%{http_code} SIZE=%{size_download}\n" http://127.0.0.1:8788/m3u
head -c 120 /tmp/m3u150.out
echo

# 5. 崩溃类日志检查
echo "---- crash scan ----"
logread | grep -iE "migu.*(Syntax error|Reference error|not a function|Type error)" | tail -n 20 || true

# 6. EPG 首次拉取结果（Last-Modified 文件应已生成）
echo "---- EPG state ----"
ls -l /tmp/.migu-epg.lm 2>/dev/null && cat /tmp/.migu-epg.lm 2>/dev/null
echo
echo "DONE_MAIN"