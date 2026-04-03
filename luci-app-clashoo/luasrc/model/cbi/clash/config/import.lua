
local NXFS = require "nixio.fs"
local SYS  = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local uci = luci.model.uci.cursor()
local fs = require "luci.clash"
local http = luci.http
local clash = "clash"
local LIST_FILE = "/usr/share/clashbackup/confit_list.conf"
local sub_rows = {}

local function list_subscriptions()
	local rows = {}
	if not NXFS.access(LIST_FILE) then
		return rows
	end

	for line in io.lines(LIST_FILE) do
		local name, url, typ = line:match("^([^#]+)#([^#]+)#?(.*)$")
		if name and url then
			rows[#rows + 1] = {
				name = name,
				url = url,
				typ = (typ and typ ~= "") and typ or "clash"
			}
		end
	end

	table.sort(rows, function(a, b)
		return a.name < b.name
	end)

	return rows
end

local function row_is_placeholder(row)
	return row and row.placeholder == true
end

local function shorten_url(url)
	if not url then
		return ""
	end
	if #url <= 88 then
		return url
	end
	return url:sub(1, 52) .. "..." .. url:sub(-24)
end

local function get_row(section)
	local idx = tonumber(section) or section
	return sub_rows and sub_rows[idx] or nil
end




kr = Map(clash)
s = kr:section(TypedSection, "clash", "订阅配置")
s.anonymous = true
kr.pageaction = false

o = s:option(ListValue, "subcri", "订阅类型")
o.default = clash
o:value("clash", translate("clash"))
o:value("meta", translate("clash meta"))
o.description = "选择订阅内核类型"

o = s:option(Value, "config_name")
o.title = "配置名称"
o.description = "可选基础配置名：一个订阅链接对应一个配置文件，多个链接会自动追加后缀"
o.placeholder = "sub-20260328120000"
o.rmempty = true

o = s:option(DynamicList, "clash_url")
o.title = "订阅链接"
o.description = "一个订阅链接对应一个配置文件"
o.rmempty = false
o:depends("subcri", 'clash')
o:depends("subcri", 'meta')


o = s:option(Button,"update")
o.title = "下载订阅"
o.inputtitle = "下载订阅"
o.inputstyle = "reload"
o.write = function()
  kr.uci:commit("clash")
  SYS.call("sh /usr/share/clash/clash.sh >>/usr/share/clash/clash.txt 2>&1 &")
  SYS.call("sleep 1")
  HTTP.redirect(DISP.build_url("admin", "services", "clash"))
end
o:depends("subcri", 'clash')
o:depends("subcri", 'meta')

sub_rows = list_subscriptions()
if #sub_rows == 0 then
	sub_rows[1] = {
		name = "暂无订阅",
		url = "请先在上方填写订阅链接并点击“下载订阅”",
		typ = "-",
		placeholder = true
	}
end

ls = Form("subscription_list")
ls.reset = false
ls.submit = false

tb = ls:section(Table, sub_rows, "订阅列表（每条可单独更新）")
tb.anonymous = true

nm = tb:option(DummyValue, "name", "名称")
tp = tb:option(DummyValue, "typ", "类型")
ul = tb:option(DummyValue, "url", "URL")
ul.rawhtml = true
ul.cfgvalue = function(_, section)
	local row = get_row(section)
	if not row or row_is_placeholder(row) then
		return row and row.url or ""
	end
	local safe = UTIL.pcdata(row.url)
	local text = UTIL.pcdata(shorten_url(row.url))
	return string.format('<div style="max-width:560px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">'
		.. '<a href="%s" target="_blank" rel="noopener noreferrer" title="%s" style="display:inline-block;max-width:100%%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;">%s</a>'
		.. '</div>', safe, safe, text)
end

btnu = tb:option(Button, "update", "更新")
btnu.template = "clash/other_button"
btnu.render = function(self, section, scope)
	if row_is_placeholder(get_row(section)) then
		scope.display = "none"
		return
	end
	self.inputstyle = "apply"
	Button.render(self, section, scope)
end
btnu.write = function(_, section)
	local row = get_row(section)
	if not row then
		return
	end
	uci:set("clash", "config", "config_update_name", row.name)
	uci:commit("clash")
	SYS.call("sh /usr/share/clash/update.sh >>/usr/share/clash/clash.txt 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "clash"))
end

btnr = tb:option(Button, "remove", "删除")
btnr.render = function(self, section, scope)
	if row_is_placeholder(get_row(section)) then
		scope.display = "none"
		return
	end
	self.inputstyle = "remove"
	Button.render(self, section, scope)
end
btnr.write = function(_, section)
	local row = get_row(section)
	if not row then
		return
	end
	uci:set("clash", "config", "config_name_remove", row.name)
	uci:commit("clash")
	SYS.call("sh /usr/share/clash/rmlist.sh >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "clash", "config", "import"))
end

function IsYamlFile(e)
   e=e or""
   local e=string.lower(string.sub(e,-5,-1))
   return e == ".yaml"
end

function IsYmlFile(e)
   e=e or""
   local e=string.lower(string.sub(e,-4,-1))
   return e == ".yml"
end


ko = Map(clash)
ko.reset = false
ko.submit = false
sul =ko:section(TypedSection, "clash", "上传配置")
sul.anonymous = true
sul.addremove=false
o = sul:option(FileUpload, "")
--o.description = translate("NB: Only upload file with name .yaml.It recommended to rename each upload file name to avoid overwrite")
o.title = translate("  ")
o.template = "clash/clash_upload"
um = sul:option(DummyValue, "", nil)
um.template = "clash/clash_dvalue"

local dir, fd
dir = "/usr/share/clash/config/upload/"
http.setfilehandler(

	function(meta, chunk, eof)
		if not fd then
			if not meta then return end

			if	meta and chunk then fd = nixio.open(dir .. meta.file, "w") end

			if not fd then
				um.value = translate("upload file error.")
				return
			end
		end
		if chunk and fd then
			fd:write(chunk)
		end
		if eof and fd then
			fd:close()
			fd = nil
			local e=string.lower(string.sub(meta.file,-4,-1))
			local yml2=string.lower(string.sub(meta.file,0,-5))
			if e == '.yml'  then
			local yml=string.lower(string.sub(meta.file,0,-5))
			local c=fs.rename(dir .. meta.file,"/usr/share/clash/config/upload/".. yml .. ".yaml")
			um.value = translate("File saved to") .. ' "/usr/share/clash/config/upload/'..yml..'.yaml"'
			else
			um.value = translate("File saved to") .. ' "/usr/share/clash/config/upload/'..yml2..'yaml"'
			end
			
		end
	end
)

if luci.http.formvalue("upload") then
	local f = luci.http.formvalue("ulfile")
	if #f <= 0 then
		um.value = translate("No specify upload file.")
	end
end


return kr,ls,ko
