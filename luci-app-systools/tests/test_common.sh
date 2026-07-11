#!/bin/bash
# systools-common.sh 公共函数单元测试
# 用法：bash tests/test_common.sh

# 加载公共库
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../root/usr/libexec/systools/systools-common.sh"

PASS=0
FAIL=0
TOTAL=0

# 测试辅助函数
assert_true() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        echo "  ✓ PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if ! "$@" >/dev/null 2>&1; then
        echo "  ✓ PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "========================================"
echo "  systools-common.sh 单元测试"
echo "========================================"

# ========== is_valid_ip 测试 ==========
echo ""
echo "--- is_valid_ip ---"

# 合法IP
assert_true "正常IP 192.168.1.1" is_valid_ip "192.168.1.1"
assert_true "全0IP 0.0.0.0" is_valid_ip "0.0.0.0"
assert_true "全255IP 255.255.255.255" is_valid_ip "255.255.255.255"
assert_true "127.0.0.1" is_valid_ip "127.0.0.1"

# 非法IP
assert_false "空字符串" is_valid_ip ""
assert_false "三段IP 192.168.1" is_valid_ip "192.168.1"
assert_false "五段IP 1.2.3.4.5" is_valid_ip "1.2.3.4.5"
assert_false "超255 256.1.1.1" is_valid_ip "256.1.1.1"
assert_false "字母 abc.def.ghi.jkl" is_valid_ip "abc.def.ghi.jkl"
assert_false "带空格 192.168.1. 1" is_valid_ip "192.168.1. 1"

# ========== is_valid_port 测试 ==========
echo ""
echo "--- is_valid_port ---"

# 合法端口
assert_true "最小端口 1" is_valid_port "1"
assert_true "常用端口 80" is_valid_port "80"
assert_true "常用端口 8123" is_valid_port "8123"
assert_true "最大端口 65535" is_valid_port "65535"

# 非法端口
assert_false "端口0" is_valid_port "0"
assert_false "端口65536" is_valid_port "65536"
assert_false "负数 -1" is_valid_port "-1"
assert_false "字母 abc" is_valid_port "abc"
assert_false "空字符串" is_valid_port ""

# ========== is_valid_mac 测试 ==========
echo ""
echo "--- is_valid_mac ---"

# 合法MAC
assert_true "小写MAC" is_valid_mac "aa:bb:cc:dd:ee:ff"
assert_true "大写MAC" is_valid_mac "AA:BB:CC:DD:EE:FF"
assert_true "混合大小写" is_valid_mac "Aa:Bb:Cc:Dd:Ee:Ff"
assert_true "全0 MAC" is_valid_mac "00:00:00:00:00:00"

# 非法MAC
assert_false "5段MAC" is_valid_mac "aa:bb:cc:dd:ee"
assert_false "7段MAC" is_valid_mac "aa:bb:cc:dd:ee:ff:00"
assert_false "短地址" is_valid_mac "a:b:c:d:e:f"
assert_false "横杠分隔" is_valid_mac "aa-bb-cc-dd-ee-ff"
assert_false "字母超范围" is_valid_mac "gg:hh:ii:jj:kk:ll"
assert_false "空字符串" is_valid_mac ""

# ========== command_exists 测试 ==========
echo ""
echo "--- command_exists ---"

assert_true "存在的命令 ls" command_exists "ls"
assert_true "存在的命令 bash" command_exists "bash"
assert_false "不存在的命令" command_exists "nonexistent_cmd_xyz"

# ========== 日志函数测试 ==========
echo ""
echo "--- log functions (仅验证不报错) ---"

# 验证日志函数能正常执行不报错
assert_true "log_info 正常执行" log_info "test info message"
assert_true "log_warn 正常执行" log_warn "test warn message"
assert_true "log_error 正常执行" log_error "test error message"

# ========== 汇总 ==========
echo ""
echo "========================================"
echo "  测试结果: $PASS/$TOTAL 通过，$FAIL 失败"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
