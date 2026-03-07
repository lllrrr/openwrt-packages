#!/bin/sh
# Easy MWAN3 Test Script
# Version: 2.1.1

. /lib/functions.sh

LOG_TAG="easy_mwan3_test"

# 测试结果
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 测试函数
test_case() {
    local description=$1
    local result=$2
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [ $result -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC} $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}[FAIL]${NC} $description"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# 测试配置文件
test_config() {
    echo "=== Testing Configuration ==="
    
    # 测试配置文件存在
    test_case "Config file exists" $([ -f /etc/config/easy_mwan3 ]; echo $?)
    
    # 测试配置文件格式
    test_case "Config file is valid UCI" $(uci -q show easy_mwan3 >/dev/null 2>&1; echo $?)
    
    # 测试必要配置节
    test_case "Global section exists" $(uci -q get easy_mwan3.global >/dev/null; echo $?)
}

# 测试依赖
test_dependencies() {
    echo ""
    echo "=== Testing Dependencies ==="
    
    # 测试 mwan3 安装
    test_case "mwan3 is installed" $([ -f /etc/init.d/mwan3 ]; echo $?)
    
    # 测试 LuCI 安装
    test_case "luci-base is installed" $(opkg list-installed | grep -q luci-base; echo $?)
    
    # 测试必要工具
    test_case "ip command exists" $(which ip >/dev/null 2>&1; echo $?)
    test_case "iptables exists" $(which iptables >/dev/null 2>&1; echo $?)
}

# 测试防火墙兼容性
test_firewall() {
    echo ""
    echo "=== Testing Firewall ==="
    
    local fw_version=$(uci get firewall.@defaults[0].name 2>/dev/null || echo "unknown")
    
    if echo "$fw_version" | grep -q "fw4"; then
        echo -e "${RED}ERROR:${NC} fw4 detected - MWAN3 is incompatible with fw4"
        test_case "Firewall compatibility (fw4)" 1
    else
        test_case "Firewall compatibility (fw3 or unknown)" 0
    fi
}

# 测试脚本
test_scripts() {
    echo ""
    echo "=== Testing Scripts ==="
    
    # 测试脚本存在
    test_case "apply script exists" $([ -f /usr/bin/easy_mwan3_apply.sh ]; echo $?)
    test_case "status script exists" $([ -f /usr/bin/easy_mwan3_status.sh ]; echo $?)
    test_case "validate script exists" $([ -f /usr/bin/easy_mwan3_validate.sh ]; echo $?)
    test_case "policy script exists" $([ -f /usr/bin/easy_mwan3_policy.sh ]; echo $?)
    
    # 测试脚本可执行
    test_case "apply script is executable" $([ -x /usr/bin/easy_mwan3_apply.sh ]; echo $?)
    test_case "status script is executable" $([ -x /usr/bin/easy_mwan3_status.sh ]; echo $?)
    test_case "validate script is executable" $([ -x /usr/bin/easy_mwan3_validate.sh ]; echo $?)
    test_case "policy script is executable" $([ -x /usr/bin/easy_mwan3_policy.sh ]; echo $?)
}

# 测试接口
test_interfaces() {
    echo ""
    echo "=== Testing Interfaces ==="
    
    local enabled=$(uci -q get easy_mwan3.global.enabled)
    if [ "$enabled" != "1" ]; then
        echo -e "${YELLOW}SKIP:${NC} Easy MWAN3 is disabled"
        return
    fi
    
    local members=$(uci -q get easy_mwan3.global.members)
    if [ -z "$members" ]; then
        test_case "Interfaces configured" 1
        return
    fi
    
    for iface in $members; do
        # 测试接口存在
        if ubus call network.interface.$iface status >/dev/null 2>&1; then
            test_case "Interface $iface exists" 0
            
            # 测试接口在线
            local status=$(ubus call network.interface.$iface status 2>/dev/null)
            if echo "$status" | grep -q '"up":true'; then
                test_case "Interface $iface is online" 0
            else
                test_case "Interface $iface is online" 1
            fi
        else
            test_case "Interface $iface exists" 1
        fi
    done
}

# 测试 MWAN3 服务
test_mwan3_service() {
    echo ""
    === Testing MWAN3 Service ==="
    
    test_case "mwan3 init script exists" $([ -f /etc/init.d/mwan3 ]; echo $?)
    test_case "mwan3 is enabled" $([ "$(uci -q get mwan3.globals.enabled)" = "1" ]; echo $?)
    test_case "mwan3 is running" $(/etc/init.d/mwan3 running >/dev/null 2>&1; echo $?)
}

# 生成报告
generate_report() {
    echo ""
    echo "==================================="
    echo "         Test Report"
    echo "==================================="
    echo "Total Tests:  $TESTS_TOTAL"
    echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"
    echo "==================================="
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed. Please check the output above.${NC}"
        return 1
    fi
}

# 主函数
main() {
    echo "Easy MWAN3 Test Suite v2.1.1"
    echo "==================================="
    echo ""
    
    test_config
    test_dependencies
    test_firewall
    test_scripts
    test_interfaces
    test_mwan3_service
    
    generate_report
}

main "$@"
