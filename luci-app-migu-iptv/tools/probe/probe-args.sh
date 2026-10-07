#!/bin/sh
cp /tmp/probe-args-plugin /usr/share/rpcd/ucode/probeprobe
/etc/init.d/rpcd restart
sleep 3
echo "=== probe1 (未声明 args) 传数字 40 ==="
ubus call probeprobe probe1 '{"v":40}' 2>&1 | head -3
echo ""
echo "=== probe1 (未声明 args) 传字符串 \"40\" ==="
ubus call probeprobe probe1 '{"v":"40"}' 2>&1 | head -3
echo ""
echo "=== probe2 (声明 String) 传数字 40 ==="
ubus call probeprobe probe2 '{"v":40}' 2>&1 | head -3
echo ""
echo "=== probe3 (声明 Integer) 传数字 40 ==="
ubus call probeprobe probe3 '{"v":40}' 2>&1 | head -3
echo ""
echo "=== probe3 (声明 Integer) 传字符串 \"40\" ==="
ubus call probeprobe probe3 '{"v":"40"}' 2>&1 | head -3
echo ""
rm -f /usr/share/rpcd/ucode/probeprobe
/etc/init.d/rpcd restart
echo "（探针已清理）"
