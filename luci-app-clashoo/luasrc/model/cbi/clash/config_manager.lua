local NXFS = require "nixio.fs"
local SYS  = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local uci  = luci.model.uci.cursor()
local fs   = require "luci.clash"
local http = luci.http
local clash = "clash"
local LIST_FILE = "/usr/share/clashbackup/confit_list.conf"
local SUB_DIR   = "/usr/share/clash/config/sub/"

-- [[ 辅助函数 ]]
local function list_subscriptions()
	local rows = {}
	if not NXFS.access(LIST_FILE) then return rows end
	for line in io.lines(LIST_FILE) do
		local name, url, typ = line:match("^([^#]+)#([^#]+)#?(.*)$")
		if name and url then
			rows[#rows + 1] = {
				name = name,
				url  = url,
				typ  = (typ and typ ~= "") and typ or "clash"
			}
		end
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

local function shorten_url(url)
	if not url or #url <= 48 then return url or "" end
	return url:sub(1, 28) .. "..." .. url:sub(-16)
end

local function get_active_config()
	local p = luci.sys.exec("uci -q get clash.config.use_config 2>/dev/null") or ""
	return p:gsub("%s+$", "")
end

local function make_file_table(dir)
	local rows = {}
	local paths = fs.glob(dir .. "*.yaml")
	if paths then
		for _, path in ipairs(paths) do
			local st = fs.stat(path)
			if st then
				rows[#rows + 1] = {
					name  = fs.basename(path),
					mtime = os.date("%Y-%m-%d %H:%M", st.mtime),
					size  = math.ceil(st.size / 1024) .. " KB",
				}
			end
		end
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

local function download_file(dir, rows, idx)
	local row = rows[idx]
	if not row then return end
	local path = dir .. row.name
	local fd = nixio.open(path, "r")
	if not fd then return end
	HTTP.header("Content-Disposition", 'attachment; filename="' .. row.name .. '"')
	HTTP.prepare_content("application/octet-stream")
	repeat
		local blk = fd:read(nixio.const.buffersize)
		if blk and #blk > 0 then HTTP.write(blk) else break end
	until false
	fd:close()
	HTTP.close()
end

-- [[ 第一块：配置来源 ]]
kr = Map(clash)
s  = kr:section(TypedSection, "clash", "配置来源")
s.anonymous = true
kr.pageaction = false
s.description = [[填写订阅链接后点击"下载订阅"，或直接上传 YAML 文件；多来源可并存，在下方文件列表中切换]]

o = s:option(ListValue, "subcri", "订阅类型")
o.default = "clash"
o:value("clash", "Clash")
o:value("meta",  "Mihomo / Clash.Meta")

o = s:option(Value, "config_name", "配置名称")
o.description = "可选：指定基础文件名，多条链接自动追加序号后缀"
o.placeholder = "sub-config"
o.rmempty = true

o = s:option(DynamicList, "clash_url", "订阅链接")
o.description = "每条链接对应一个配置文件"
o.rmempty = false

o = s:option(Button, "update", "")
o.inputtitle = "下载订阅"
o.inputstyle = "apply"
o.write = function()
	kr.uci:commit("clash")
	SYS.call("sh /usr/share/clash/clash.sh >>/usr/share/clash/clash.txt 2>&1 &")
	SYS.call("sleep 1")
	HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
end

-- [[ 第二块：订阅管理（列表 + 配置文件合并） ]]
local active_config = get_active_config()

-- 以订阅列表为主，从磁盘补充文件信息
local sub_list = list_subscriptions()

-- 构建磁盘文件查找表：name → {mtime, size}
local file_info = {}
local file_rows_raw = make_file_table(SUB_DIR)
for _, fr in ipairs(file_rows_raw) do
	file_info[fr.name] = { mtime = fr.mtime, size = fr.size }
end

local merged_rows = {}
for _, sr in ipairs(sub_list) do
	local fi = file_info[sr.name]
	merged_rows[#merged_rows + 1] = {
		name    = sr.name,
		url     = sr.url,
		typ     = sr.typ,
		mtime   = fi and fi.mtime or "-",
		size    = fi and fi.size  or "-",
		no_file = fi == nil
	}
end

local function row_is_placeholder(row) return false end

ms = nil
if #merged_rows > 0 then
ms = Form("sub_merged")
ms.reset  = false
ms.submit = false
local mtb = ms:section(Table, merged_rows, '<div style="margin-top:1.2em">订阅管理</div>')
mtb.anonymous = true

local nm = mtb:option(DummyValue, "name", "文件名")
nm.rawhtml = true
nm.cfgvalue = function(_, section)
	local row = merged_rows[section]
	if not row then return "" end
	if SUB_DIR .. row.name == active_config then
		return '<strong style="color:#4CAF50">&#9654; ' .. UTIL.pcdata(row.name) .. '</strong>'
	end
	return UTIL.pcdata(row.name)
end

mtb:option(DummyValue, "typ", "类型")

local ul = mtb:option(DummyValue, "url", "链接")
ul.rawhtml = true
ul.cfgvalue = function(_, section)
	local row = merged_rows[section]
	if not row or row.url == "" then return "-" end
	local safe = UTIL.pcdata(row.url)
	local text = UTIL.pcdata(shorten_url(row.url))
	return string.format(
		'<span style="max-width:260px;display:inline-block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;vertical-align:middle;">'
		.. '<a href="%s" target="_blank" rel="noopener noreferrer" title="%s">%s</a></span>',
		safe, safe, text)
end

mtb:option(DummyValue, "mtime", "更新时间")
mtb:option(DummyValue, "size",  "大小")

local buse = mtb:option(Button, "_use", "使用")
buse.template = "clash/other_button"
buse.render = function(self, section, scope)
	local row = merged_rows[section]
	if not row or row.no_file or row_is_placeholder(row) then
		scope.display = "none"
	else
		self.inputstyle = "apply"
	end
	Button.render(self, section, scope)
end
buse.write = function(_, section)
	local row = merged_rows[section]
	if not row then return end
	SYS.exec(string.format('uci set clash.config.use_config="%s" && uci set clash.config.config_type="1" && uci commit clash',
		SUB_DIR .. row.name))
	if SYS.call("pidof mihomo >/dev/null || pidof clash-meta >/dev/null || pidof clash >/dev/null") == 0 then
		SYS.call("/etc/init.d/clash restart >/dev/null 2>&1 &")
		HTTP.redirect(DISP.build_url("admin", "services", "clash"))
	else
		HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
	end
end

local bdl = mtb:option(Button, "_dl", "下载")
bdl.template = "clash/other_button"
bdl.render = function(self, section, scope)
	local row = merged_rows[section]
	if not row or row.no_file or row_is_placeholder(row) then
		scope.display = "none"
	else
		self.inputstyle = "apply"
	end
	Button.render(self, section, scope)
end
bdl.write = function(_, section)
	download_file(SUB_DIR, merged_rows, section)
end

local bup = mtb:option(Button, "_update", "更新")
bup.template = "clash/other_button"
bup.render = function(self, section, scope)
	local row = merged_rows[section]
	if not row or row.url == "" or row_is_placeholder(row) then
		scope.display = "none"
	else
		self.inputstyle = "apply"
	end
	Button.render(self, section, scope)
end
bup.write = function(_, section)
	local row = merged_rows[section]
	if not row then return end
	uci:set("clash", "config", "config_update_name", row.name)
	uci:commit("clash")
	SYS.call("sh /usr/share/clash/update.sh >>/usr/share/clash/clash.txt 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
end

local brm = mtb:option(Button, "_rm", "删除")
brm.render = function(self, section, scope)
	local row = merged_rows[section]
	if not row then return end
	self.inputstyle = "remove"
	Button.render(self, section, scope)
end
brm.write = function(_, section)
	local row = merged_rows[section]
	if not row then return end
	if not row.no_file then
		fs.unlink(SUB_DIR .. row.name)
	end
	uci:set("clash", "config", "config_name_remove", row.name)
	uci:commit("clash")
	SYS.call("sh /usr/share/clash/rmlist.sh >/dev/null 2>&1 &")
	table.remove(merged_rows, section)
	HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
end
end -- if #merged_rows > 0

-- [[ 第三块：上传配置文件 ]]
local upload_dir = "/usr/share/clash/config/upload/"
ko = Map(clash)
ko.reset = false
ko.submit = false
local sul = ko:section(TypedSection, "clash", "上传配置文件")
sul.anonymous = true
sul.addremove = false
sul.description = "上传本地 .yaml / .yml 文件作为配置来源"
local uo = sul:option(FileUpload, "")
uo.title = " "
uo.template = "clash/clash_upload"
local um = sul:option(DummyValue, "", nil)
um.template = "clash/clash_dvalue"

http.setfilehandler(function(meta, chunk, eof)
	if not _upload_fd then
		if not meta then return end
		if meta and chunk then
			_upload_fd = nixio.open(upload_dir .. meta.file, "w")
		end
		if not _upload_fd then um.value = "上传失败：无法写入文件"; return end
	end
	if chunk and _upload_fd then _upload_fd:write(chunk) end
	if eof and _upload_fd then
		_upload_fd:close()
		_upload_fd = nil
		local ext = meta.file:lower():sub(-4)
		if ext == ".yml" then
			local base = meta.file:sub(1, -5)
			fs.rename(upload_dir .. meta.file, upload_dir .. base .. ".yaml")
			um.value = "已保存：" .. upload_dir .. base .. ".yaml"
		else
			um.value = "已保存：" .. upload_dir .. meta.file
		end
	end
end)

if http.formvalue("upload") then
	local f = http.formvalue("ulfile")
	if not f or #f <= 0 then um.value = "未选择文件" end
end

-- [[ 第四块：配置文件列表（上传 / 自定义） ]]
local function make_config_table(title, dir, ctype, remove_uci_key, remove_script)
	local rows = make_file_table(dir)
	if #rows == 0 then return nil end

	local ff = Form("cfg_list_" .. ctype)
	ff.reset = false
	ff.submit = false
	local ttb = ff:section(Table, rows, title)
	ttb.anonymous = true

	local nm2 = ttb:option(DummyValue, "name", "文件名")
	nm2.rawhtml = true
	nm2.cfgvalue = function(_, section)
		local row = rows[section]
		if not row then return "" end
		if dir .. row.name == active_config then
			return '<strong style="color:#4CAF50">&#9654; ' .. UTIL.pcdata(row.name) .. '</strong>'
		end
		return UTIL.pcdata(row.name)
	end

	ttb:option(DummyValue, "mtime", "更新时间")
	ttb:option(DummyValue, "size",  "大小")

	local buse2 = ttb:option(Button, "_use", "使用")
	buse2.template = "clash/other_button"
	buse2.render = function(self, section, scope)
		if not rows[section] then return end
		self.inputstyle = "apply"
		Button.render(self, section, scope)
	end
	buse2.write = function(_, section)
		local row = rows[section]
		if not row then return end
		SYS.exec(string.format('uci set clash.config.use_config="%s" && uci set clash.config.config_type="%s" && uci commit clash',
			dir .. row.name, ctype))
		if SYS.call("pidof mihomo >/dev/null || pidof clash-meta >/dev/null || pidof clash >/dev/null") == 0 then
			SYS.call("/etc/init.d/clash restart >/dev/null 2>&1 &")
			HTTP.redirect(DISP.build_url("admin", "services", "clash"))
		else
			HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
		end
	end

	local bdl2 = ttb:option(Button, "_dl", "下载")
	bdl2.template = "clash/other_button"
	bdl2.render = function(self, section, scope)
		if not rows[section] then return end
		self.inputstyle = "apply"
		Button.render(self, section, scope)
	end
	bdl2.write = function(_, section)
		download_file(dir, rows, section)
	end

	local brm2 = ttb:option(Button, "_rm", "删除")
	brm2.render = function(self, section, scope)
		if not rows[section] then return end
		self.inputstyle = "remove"
		Button.render(self, section, scope)
	end
	brm2.write = function(_, section)
		local row = rows[section]
		if not row then return end
		fs.unlink(dir .. row.name)
		SYS.exec(string.format('uci set clash.config.%s="%s" && uci commit clash', remove_uci_key, row.name))
		SYS.call(remove_script .. " >/dev/null 2>&1 &")
		table.remove(rows, section)
		HTTP.redirect(DISP.build_url("admin", "services", "clash", "config_manager"))
	end

	return ff
end

local fup = make_config_table(
	"上传配置文件",
	"/usr/share/clash/config/upload/",
	"2", "config_up_remove", "bash /usr/share/clash/uplist.sh")

local fcus = make_config_table(
	"自定义配置文件",
	"/usr/share/clash/config/custom/",
	"3", "config_cus_remove", "/usr/share/clash/cuslist.sh")

-- [[ 第五块：配置文件编辑器 ]]
local ed = nil
if active_config ~= "" and NXFS.access(active_config) then
	ed = Map(clash)
	local es = ed:section(TypedSection, "clash", "编辑当前配置：" .. fs.basename(active_config))
	es.anonymous = true
	es.addremove = false
	ed.pageaction = false
	es.description = "直接编辑当前激活的配置文件（YAML）。仅建议在订阅无法覆盖的情况下应急使用。"

	local tv = es:option(TextValue, "_yaml_editor")
	tv.rows = 25
	tv.wrap = "off"
	tv.cfgvalue = function()
		return NXFS.readfile(active_config) or ""
	end
	tv.write = function(self, section, value)
		NXFS.writefile(active_config, value:gsub("\r\n", "\n"))
	end

	local sv = es:option(Button, "_save", "")
	sv.inputtitle = "保存文件"
	sv.inputstyle = "apply"
	sv.write = function()
		ed.uci:commit("clash")
	end
end

-- 按顺序返回所有有效块
local ret = {kr}
if ms   then ret[#ret + 1] = ms   end
ret[#ret + 1] = ko
if fup  then ret[#ret + 1] = fup  end
if fcus then ret[#ret + 1] = fcus end
if ed   then ret[#ret + 1] = ed   end
return unpack(ret)
