#!/bin/sh
# verify-304.sh — 验证 EPG 304 条件更新（ETag 版；重启服务后应立即命中 If-None-Match）
set -x
ET=$(cat /tmp/.migu-epg.lm 2>/dev/null)
echo "ETag: [$ET]"
if [ -z "$ET" ]; then
  echo "NO_ETAG_FILE — 上次拉取未保存 ETag，无法验证 304"
  exit 1
fi

# 重启服务，epgStartFetch 会带 If-None-Match 发起条件请求
/etc/init.d/migu restart
sleep 25

echo "---- /health ----"
curl -s -m 5 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E '"version"|"epgIds"|"epgOk"|"epgAge"'
echo
echo "---- logread EPG scan ----"
logread | grep -i "migu.*EPG" | tail -n 10
echo
echo "DONE_VERIFY_304"