#!/bin/sh
F=/usr/share/ucode/migu.uc
echo "=== openssl 残留 ==="
grep -n 'openssl' $F || echo "  (无)"
echo ""
echo "=== sh('date 残留 ==="
grep -n "sh('date" $F || echo "  (无)"
echo ""
echo "=== md5hex 实现 ==="
grep -n -A3 'function md5hex' $F
echo ""
echo "=== import 行 ==="
grep -n '^import' $F
echo ""
echo "=== digest 模块文件是否存在 ==="
ls -l /usr/lib/ucode/*.so 2>/dev/null | head -20
echo ""
echo "=== 若卸载 digest 会怎样（仅探测，不真卸）==="
apk info -e ucode-mod-digest && echo "  ucode-mod-digest 已安装（migu.uc 依赖它）"
echo ""
echo "=== openssl-util 当前是否还被别的组件用 ==="
apk info -e openssl-util && echo "  openssl-util 已安装"
grep -rn 'openssl' /usr/share/ucode/*.uc 2>/dev/null | grep -v migu.uc | head -5 || echo "  其它 ucode 脚本未用 openssl"
