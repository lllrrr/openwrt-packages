#!/bin/sh
echo "=== 1. logs 传数字 40（前端 status.js 就是这么调的：callLogs(40)）==="
ubus call migu logs '{"lines":40}' 2>&1 | head -5
echo ""
echo "=== 2. logs 传字符串 \"40\" ==="
ubus call migu logs '{"lines":"40"}' 2>&1 | head -3
echo ""
echo "=== 3. logs 不传参数 ==="
ubus call migu logs '{}' 2>&1 | head -3
echo ""
echo "=== 4. testchannel 传数字（前端不会这么传，对照用）==="
ubus call migu testchannel '{"pid":608807420}' 2>&1 | head -3
echo ""
echo "=== 5. testchannel 传字符串（前端实际用法）==="
ubus call migu testchannel '{"pid":"608807420"}' 2>&1 | head -3
echo ""
echo "=== 6. 模拟 LuCI 非 root 会话看 ACL 粒度 ==="
echo "ACL read  : $(grep -A3 '\"read\"' /usr/share/rpcd/acl.d/luci-app-migu-iptv.json | grep 'migu' )"
echo "ACL write : $(grep -A3 '\"write\"' /usr/share/rpcd/acl.d/luci-app-migu-iptv.json | grep 'migu' )"
