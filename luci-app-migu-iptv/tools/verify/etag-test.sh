#!/bin/sh
# etag-test.sh — 手动验证 EPG 源支持 If-None-Match 304
ET=$(cat /tmp/.migu-epg.lm 2>/dev/null)
echo "ETag=[$ET]"
if [ -z "$ET" ]; then echo "NO_ETAG"; exit 1; fi
curl -s -L --compressed --connect-timeout 8 -m 25 \
  -H "If-None-Match: $ET" \
  -o /dev/null -w 'HTTP=%{http_code} SIZE=%{size_download}\n' \
  'https://live.fanmingming.cn/e.xml'
echo "DONE_ETAG_TEST"