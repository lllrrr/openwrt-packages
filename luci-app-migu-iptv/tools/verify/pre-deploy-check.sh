#!/bin/sh
echo "=== 长测日志（流地址有效期）==="
if [ -f /tmp/url-longevity.log ]; then
  wc -l /tmp/url-longevity.log
  cat /tmp/url-longevity.log
else
  echo "(日志不存在)"
fi

echo ""
echo "=== 长测进程是否还在 ==="
ps w | grep "[l]ongevity" || echo "(已结束)"

echo ""
echo "=== 当前部署版本 ==="
md5sum /usr/share/ucode/migu.uc
uci get migu.main.port

echo ""
echo "=== uci.cursor 是否支持指定目录 ==="
mkdir -p /tmp/ucitest
echo "config migu 'main'" > /tmp/ucitest/migu
echo "	option port '18788'" >> /tmp/ucitest/migu
echo "	option enabled '1'" >> /tmp/ucitest/migu
ucode -e '
let uci = require("uci");
try {
  let c = uci.cursor("/tmp/ucitest");
  let a = c.get_all("migu");
  print("cursor(dir) OK: " + sprintf("%J", a) + "\n");
} catch (e) {
  print("cursor(dir) FAILED: " + e + "\n");
}
let c2 = uci.cursor();
print("default cursor port=" + c2.get("migu","main","port") + "\n");
' 2>&1

echo ""
echo "=== 当前服务进程信息 ==="
ps w | grep "[m]igu.uc"
cat /proc/$(pgrep -f "[m]igu.uc" | head -1)/status 2>/dev/null | grep -E "VmRSS|Threads"
ls /proc/$(pgrep -f "[m]igu.uc" | head -1)/fd 2>/dev/null | wc -l
