#!/bin/sh
# etag-test2.sh — 手动验证 EPG 源支持 If-None-Match 304（带错误输出，缩短超时）
ET=$(cat /tmp/.migu-epg.lm 2>/dev/null)
echo "ETag=[$ET]"
echo "--- 无条件请求（对照）---"
curl -s -L --compressed --connect-timeout 6 -m 12 -o /dev/null -w 'plain: HTTP=%{http_code} SIZE=%{size_download}\n' 'https://live.fanmingming.cn/e.xml'
echo "curl_exit=$?"
echo "--- 带 If-None-Match ---"
curl -s -L --compressed --connect-timeout 6 -m 12 -H "If-None-Match: $ET" -o /dev/null -w 'cond: HTTP=%{http_code} SIZE=%{size_download}\n' 'https://live.fanmingming.cn/e.xml'
echo "curl_exit=$?"
echo "DONE_ETAG_TEST2"