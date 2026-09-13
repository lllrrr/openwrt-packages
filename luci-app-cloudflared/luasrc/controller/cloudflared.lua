module("luci.controller.cloudflared",package.seeall)

function index()
  if not nixio.fs.access("/etc/config/cloudflared")then
return
end

entry({"admin","vpn"}, firstchild(), "VPN", 49).dependent = false

entry({"admin", "vpn", "cloudflared"},firstchild(), _("Cloudflared")).dependent = false

entry({"admin", "vpn", "cloudflared", "general"},cbi("cloudflared/settings"), _("配置"), 1)
entry({"admin", "vpn", "cloudflared", "log"},form("cloudflared/info"), _("日志"), 2)

entry({"admin","vpn","cloudflared","status"},call("act_status"))

entry({"admin","vpn","cloudflared","metricsproxy"},call("act_metricsproxy"), nil).leaf = true
end

function act_status()
local e={}
  e.running=luci.sys.call("[ -s /var/run/cloudflared.pid ] && kill -0 $(cat /var/run/cloudflared.pid 2>/dev/null) 2>/dev/null")==0

local tagfile = io.open("/tmp/cloudflared_time", "r")
        if tagfile then
	local tagcontent = tagfile:read("*all")
	tagfile:close()
	if tagcontent and tagcontent ~= "" then
        os.execute("start_time=$(cat /tmp/cloudflared_time) && time=$(($(date +%s)-start_time)) && day=$((time/86400)) && [ $day -eq 0 ] && day='' || day=${day}天 && time=$(date -u -d @${time} +'%H小时%M分%S秒') && echo $day $time > /tmp/command_cloudflared 2>&1")
        local command_output_file = io.open("/tmp/command_cloudflared", "r")
        if command_output_file then
            e.cfsta = command_output_file:read("*all")
            command_output_file:close()
	          if e.cfsta == "" then
               e.cfsta = "unknown"
            end
        end
	end
	end
  
  local command2 = io.popen('CFPID=$(cat /var/run/cloudflared.pid 2>/dev/null); [ -n "$CFPID" ] && kill -0 "$CFPID" 2>/dev/null && top -b -n1 | awk -v pid="$CFPID" \'/^ *PID/{for(i=1;i<=NF;i++) if($i ~ /CPU/) col=i} col && $1==pid {print $col; exit}\'')
  e.cfcpu = command2:read("*all")
  command2:close()
  if e.cfcpu == "" then
  e.cfcpu = "Unknown"
  end
  
  local command3 = io.popen("CFPID=$(cat /var/run/cloudflared.pid 2>/dev/null); [ -n \"$CFPID\" ] && kill -0 \"$CFPID\" 2>/dev/null && awk '/VmRSS/{printf \"%.2f MB\", $2/1024}' /proc/$CFPID/status")
  e.cfram = command3:read("*all")
  command3:close()
  if e.cfram == "" then
  e.cfram = "Unknown"
  end
  
  local command4 = io.popen("([ -s /tmp/cloudflared.tag ] && cat /tmp/cloudflared.tag ) || (echo `$(uci -q get cloudflared.@cloudflared[0].cfbin) version | awk '{print $3}'` > /tmp/cloudflared.tag && cat /tmp/cloudflared.tag)")
  e.cftag = command4:read("*all")
  command4:close()
  if e.cftag == "" then
  e.cftag = "Unknown"
  end
  
  local command5 = io.popen("([ -s /tmp/cloudflarednew.tag ] && cat /tmp/cloudflarednew.tag ) || ( curl -L -k -s --connect-timeout 3 --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36' https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep tag_name | sed 's/[^0-9.]*//g' >/tmp/cloudflarednew.tag && cat /tmp/cloudflarednew.tag )")
  e.cfnewtag = command5:read("*all")
  command5:close()
  if e.cfnewtag == "" then
  e.cfnewtag = "Unknown"
  end
  
  luci.http.prepare_content("application/json")
  luci.http.write_json(e)
end

-- 后端代理:获取本机 cloudflared 监控指标端点内容,供前端弹窗展示
-- 使用 nixio 内置 TCP socket 直连 127.0.0.1,避免浏览器跨域限制,不依赖 curl 等额外工具
function act_metricsproxy()
	local http = require "luci.http"
	local nixio = require "nixio"
	local ep = http.formvalue("ep") or ""
	local allowed = { ["/metrics"] = true, ["/healthcheck"] = true, ["/ready"] = true }
	local ret = { ok = false, status = -1, body = "", err = "invalid endpoint or port" }
	-- 优先使用前端传入的端口(即时探测不依赖已保存配置),否则从 uci 读取兜底
	local pn = tonumber(http.formvalue("port") or "") or 0
	if pn < 1 or pn > 65535 then
		local uci = require "luci.model.uci"
		local addr = uci.cursor():get("cloudflared", "config", "metrics") or ""
		pn = tonumber((addr and addr:match(":(%d+)$")) or "") or 0
	end
	if not allowed[ep] then
		ret.err = "endpoint not allowed"
	elseif pn < 1 or pn > 65535 then
		ret.err = "invalid port"
	else
		local url = "http://127.0.0.1:" .. pn .. ep
		local sock
		local created, cerr = pcall(function()
			sock = nixio.socket("inet", "stream")
		end)
		if not created or not sock then
			ret.err = "socket create failed: " .. tostring(cerr)
		else
			local all = ""
			local connected, cm = pcall(function()
				sock:connect("127.0.0.1", pn)
			end)
			if not connected then
				ret.err = "connect failed: " .. tostring(cm)
			else
				local sent, sm = pcall(function()
					sock:send("GET " .. ep .. " HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
				end)
				if not sent then
					ret.err = "send failed: " .. tostring(sm)
				else
					pcall(function()
						if sock.setblocking then sock:setblocking(1) end
						if sock.settimeout then sock:settimeout(3) end
						-- 若无超时能力,靠字节上限兜底,避免阻塞卡死
						local total = 0
						while total < 262144 do
							local chunk = sock:recv(4096)
							if not chunk or chunk == "" then break end
							all = all .. chunk
							total = total + #chunk
						end
					end)
					local status_line = all:match("^HTTP/%d%.%d (%d+)")
					-- find 第二返回值为分隔符结束位置,用它截取 body(剔除响应头)
					local _, split_e = all:find("\r\n\r\n")
					local body = all
					if split_e then body = all:sub(split_e + 1) end
					ret = { ok = true, status = tonumber(status_line) or -1, url = url, body = body }
				end
			end
			pcall(function() sock:close() end)
		end
	end
	http.prepare_content("application/json; charset=utf-8")
	http.write_json(ret)
end
