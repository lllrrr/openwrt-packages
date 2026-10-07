#!/bin/sh
echo "=== ACL 文件全文 ==="
cat /usr/share/rpcd/acl.d/luci-app-migu-iptv.json
echo ""
echo "=== 直接用 ubus 调 testchannel（root，绕过 ACL）==="
ubus call migu testchannel '{"pid":"608807420"}'
echo ""
echo "=== 对比：status 是否在 ACL 里 ==="
grep -o '"status"' /usr/share/rpcd/acl.d/luci-app-migu-iptv.json && echo "  status 已声明"
echo ""
echo "=== 列出 migu 对象所有方法 ==="
ubus -v list migu 2>/dev/null
