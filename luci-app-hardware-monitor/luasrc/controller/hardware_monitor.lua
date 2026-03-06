module("luci.controller.hardware_monitor", package.seeall)

function index()
    entry({"admin", "status", "hardware_monitor"}, firstchild(), _("Hardware Monitor"), 60).dependent = false
    entry({"admin", "status", "hardware_monitor", "overview"}, template("hardware_monitor/overview"), _("Overview"), 1)
    entry({"admin", "status", "hardware_monitor", "status_data"}, call("get_status_data")).leaf = true
    entry({"admin", "status", "hardware_monitor", "cpu_temp"}, call("get_cpu_temperature")).leaf = true
    entry({"admin", "status", "hardware_monitor", "memory_info"}, call("get_memory_info")).leaf = true
end

function get_status_data()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    lucihttp.prepare_content("application/json")
    
    -- 获取系统负载
    local load_avg = sys.exec("cat /proc/loadavg | awk '{print $1}'")
    load_avg = tonumber(load_avg) or 0
    local cpu_cores = tonumber(sys.exec("nproc 2>/dev/null")) or 1
    local load_percentage = math.floor((load_avg / cpu_cores) * 100 + 0.5)
    
    -- 获取内存使用率
    local memory_usage = sys.exec("free | grep Mem | awk '{printf \"%.0f\", $3/$2 * 100}'")
    memory_usage = tonumber(memory_usage) or 0
    
    -- 获取网络状态
    local has_network = sys.call("ping -c 1 -W 1 223.5.5.5 > /dev/null 2>&1") == 0
    
    -- 防火墙检测
    local drop_packets = sys.exec("iptables -L INPUT -nvx 2>/dev/null | grep -E 'DROP|REJECT' | awk '{sum += $1} END {print sum+0}'")
    drop_packets = tonumber(drop_packets) or 0
    
    local port_scan = sys.exec("logread | grep -i 'port.*scan\\|syn.*flood' | wc -l")
    port_scan = tonumber(port_scan) or 0
    
    local abnormal_conn = sys.exec("netstat -an 2>/dev/null | grep -E 'SYN_RECV|FIN_WAIT|TIME_WAIT' | wc -l")
    abnormal_conn = tonumber(abnormal_conn) or 0
    
    -- 构建响应
    local response = {
        load_percentage = load_percentage,
        memory_usage = memory_usage,
        has_network = has_network,
        drop_packets = drop_packets,
        port_scan = port_scan,
        abnormal_conn = abnormal_conn,
        timestamp = os.time()
    }
    
    lucihttp.write_json(response)
end

function get_cpu_temperature()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    lucihttp.prepare_content("text/plain")
    
    -- 尝试多种方式获取CPU温度
    local temp = nil
    
    -- 方法1: 检查thermal_zone
    temp = sys.exec("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null")
    if temp and temp ~= "" then
        temp = tonumber(temp)
        if temp then
            -- 如果温度值很大，可能是以毫摄氏度为单位
            if temp > 1000 then
                temp = math.floor(temp / 1000)
            end
            lucihttp.write(tostring(temp))
            return
        end
    end
    
    -- 方法2: 检查hwmon
    temp = sys.exec("cat /sys/class/hwmon/hwmon0/temp1_input 2>/dev/null")
    if temp and temp ~= "" then
        temp = tonumber(temp)
        if temp then
            if temp > 1000 then
                temp = math.floor(temp / 1000)
            end
            lucihttp.write(tostring(temp))
            return
        end
    end
    
    -- 方法3: 使用sensors命令
    temp = sys.exec("sensors 2>/dev/null | grep -E 'Core 0|Package id 0|CPU Temperature' | head -1 | sed 's/.*+//; s/°C.*//; s/\\..*//'")
    if temp and temp ~= "" then
        temp = tonumber(temp)
        if temp then
            lucihttp.write(tostring(temp))
            return
        end
    end
    
    -- 如果都无法获取，返回默认值
    lucihttp.write("N/A")
end

function get_memory_info()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    lucihttp.prepare_content("application/json")
    
    -- 获取内存详细信息
    local mem_total = sys.exec("free -m | grep Mem: | awk '{print $2}'")
    local mem_used = sys.exec("free -m | grep Mem: | awk '{print $3}'")
    local mem_free = sys.exec("free -m | grep Mem: | awk '{print $4}'")
    local mem_available = sys.exec("free -m | grep Mem: | awk '{print $7}'")
    
    mem_total = tonumber(mem_total) or 0
    mem_used = tonumber(mem_used) or 0
    mem_free = tonumber(mem_free) or 0
    mem_available = tonumber(mem_available) or mem_free
    
    local response = {
        total_mb = mem_total,
        used_mb = mem_used,
        free_mb = mem_free,
        available_mb = mem_available
    }
    
    lucihttp.write_json(response)
end
