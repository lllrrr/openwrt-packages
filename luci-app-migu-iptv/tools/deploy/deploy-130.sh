#!/bin/sh
# migu.uc 1.3.0 部署脚本（带回滚）
set -e

SRC=/tmp/migu-130.uc
DST=/usr/share/ucode/migu.uc
BAK=/root/migu.uc.1.2.0.bak

echo "=== 0. 前置检查 ==="
if [ ! -f "$SRC" ]; then echo "FAIL: 源文件不存在 $SRC"; exit 1; fi
ucode -c -o /tmp/deploy-check.uc "$SRC" || { echo "FAIL: 语法检查未通过"; exit 1; }
echo "语法检查 OK"

echo ""
echo "=== 1. 备份当前版本 ==="
if [ ! -f "$BAK" ]; then
  cp "$DST" "$BAK"
  echo "已备份到 $BAK"
else
  echo "备份已存在，保留原备份"
fi
md5sum "$BAK"
echo "备份行数: $(wc -l < $BAK)"

echo ""
echo "=== 2. 部署新版本 ==="
cp "$SRC" "$DST"
chmod 755 "$DST"
md5sum "$DST"
echo "新版本行数: $(wc -l < $DST)"

echo ""
echo "=== 3. 重启服务 ==="
/etc/init.d/migu restart
sleep 3

echo ""
echo "=== 4. 进程状态 ==="
ps w | grep "[m]igu.uc" || { echo "FAIL: 进程未起来，开始回滚"; cp "$BAK" "$DST"; /etc/init.d/migu restart; exit 1; }

echo ""
echo "=== 5. 服务日志（最近 20 行）==="
logread 2>/dev/null | grep -i migu | tail -20 || echo "(无 logread)"

echo ""
echo "=== 6. /health 检查 ==="
sleep 2
curl -s -m 10 http://127.0.0.1:8788/health

echo ""
echo ""
echo "=== 7. 版本确认 ==="
curl -s -m 10 http://127.0.0.1:8788/health | grep -o '"version":"[^"]*"'
