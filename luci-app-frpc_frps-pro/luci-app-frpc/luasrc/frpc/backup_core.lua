-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"
local json = require "luci.jsonc"
-- 顶层 uci cursor：后续 apply_unpacked / load_destination / list_all_destinations 会使用；
-- 沿用本项目 controller/frpc.lua 顶部已采用的同款模式，请求生命周期内复用一份 cursor。
local uci  = require "luci.model.uci".cursor()

local M = {}

-- ─────────────────────── 常量 ───────────────────────
M.PKG_NAME            = "frpc"
M.SCHEMA_VERSION      = 1
M.LOCAL_BACKUP_DIR    = "/etc/frpc-backup"
M.AUTO_SNAPSHOTS_DIR  = "/etc/frpc-backup/.auto-snapshots"
M.AUTO_SNAPSHOTS_KEEP = 10
M.MAX_UPLOAD_BYTES    = 50 * 1024 * 1024   -- 50MB
M.UCI_FILE            = "/etc/config/frpc"
M.BIN_FILE            = "/usr/bin/frpc"
M.VERSIONS_DIR        = "/usr/share/frp/versions"

M.STATUS_DIR          = "/tmp"
M.STATUS_KEEP_SEC     = 30

-- ─────────────────────── 工具函数 ───────────────────────

-- 安全 ID 校验：仅允许 [a-zA-Z0-9._-]
function M.valid_id(id)
    return type(id) == "string" and id ~= ""
        and id:match("^[a-zA-Z0-9._-]+$") ~= nil
        and not id:find("..", 1, true)   -- 拒绝包含 .. 的序列，防路径穿越（plain=true 走字面匹配，故传字面 ".."）
end

-- note → slug：仅保留 [a-zA-Z0-9_-]，其余转 _，最长 30 字符，空 → "untitled"
function M.note_to_slug(note)
    if not note or note == "" then return "untitled" end
    local s = note:gsub("[^%w_%-]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if s == "" then return "untitled" end
    return s:sub(1, 30)
end

-- 生成 UTC ISO8601 紧凑时间戳：20260522T103045Z
function M.utc_compact_timestamp()
    return os.date("!%Y%m%dT%H%M%SZ")
end

-- 生成本地 ISO 时间戳：2026-05-22 18:30:45 +0800
function M.local_iso_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S ") .. M.tz_offset()
end

-- 时区偏移：+0800
-- 实现：os.date("!*t") 返回 UTC 分解表，传给 os.time() 时会按本地时间解释，
-- 结果与 now 的差值即为本地与 UTC 的秒差（OpenWrt 默认无 DST，结果稳定）。
function M.tz_offset()
    local now = os.time()
    local diff = os.difftime(now, os.time(os.date("!*t", now)))
    local sign = diff >= 0 and "+" or "-"
    local abs = math.abs(diff)
    local hh = math.floor(abs / 3600)
    local mm = math.floor((abs % 3600) / 60)
    return string.format("%s%02d%02d", sign, hh, mm)
end

-- 计算文件 sha256（依赖 busybox sha256sum）
function M.sha256_file(path)
    if not fs.access(path) then return nil end
    local out = util.trim(sys.exec("sha256sum " .. util.shellquote(path) .. " 2>/dev/null | awk '{print $1}'"))
    if out == "" then return nil end
    return out
end

-- 文件 size，失败返回 nil
function M.file_size(path)
    local st = fs.stat(path)
    return st and st.size or nil
end

-- 安全写 JSON 文件
function M.write_json_file(path, data)
    local s = json.stringify(data, true)
    return fs.writefile(path, s) ~= nil
end

-- 安全读 JSON 文件
function M.read_json_file(path)
    local s = fs.readfile(path)
    if not s or s == "" then return nil end
    local ok, parsed = pcall(json.parse, s)
    if not ok then return nil end
    return parsed
end

-- 主机名
function M.hostname()
    return util.trim(sys.exec("uci -q get system.@system[0].hostname || cat /proc/sys/kernel/hostname"))
end

-- 读取系统架构
function M.arch_info()
    local arch_raw = util.trim(sys.exec("uname -m 2>/dev/null"))
    local map = {
        x86_64 = "linux_amd64", i386 = "linux_386", i686 = "linux_386",
        aarch64 = "linux_arm64", armv8l = "linux_arm64",
        armv7l = "linux_arm", armv6l = "linux_arm", armv5l = "linux_arm",
        mips = "linux_mips_softfloat", mipsel = "linux_mipsle_softfloat",
        mips64 = "linux_mips64", mips64el = "linux_mips64le",
        riscv64 = "linux_riscv64",
    }
    return arch_raw, map[arch_raw] or ""
end

-- 当前激活 frpc 版本（运行 `/usr/bin/frpc -v`）
function M.current_frpc_version()
    if not fs.access(M.BIN_FILE) then return "" end
    return util.trim(sys.exec(util.shellquote(M.BIN_FILE) .. " -v 2>/dev/null"))
end

-- 列出 /usr/share/frp/versions/ 下所有已下载版本号
function M.list_downloaded_versions()
    local list = {}
    if not fs.stat(M.VERSIONS_DIR) then return list end
    for entry in fs.dir(M.VERSIONS_DIR) do
        if entry:match("^[0-9]+%.[0-9]+%.[0-9]+$") then
            local bin = M.VERSIONS_DIR .. "/" .. entry .. "/frpc"
            if fs.access(bin) then
                table.insert(list, entry)
            end
        end
    end
    table.sort(list, function(a,b) return a > b end)
    return list
end

-- shell 命令包装（静默版）。调用方必须自行用 util.shellquote 处理用户输入参数，
-- 本函数不会做转义；仅追加 ">/dev/null 2>&1" 以静默标准输出与错误输出。
function M.sh_call(cmd)
    return sys.call(cmd .. " >/dev/null 2>&1")
end

-- ─────────────────────── 打包 ───────────────────────

-- opts = {
--   note            = "..."
--   includes        = { uci=bool, current_binary=bool, version_metadata=bool }
--   download_mirror = "..." (optional, from UCI)
-- }
-- 返回 ok, result | err
--   result = { backup_id, filename, tar_path (tmp), manifest, size }
function M.pack_backup(opts)
    opts = opts or {}
    opts.includes = opts.includes or { uci=true, current_binary=true, version_metadata=true }

    local backup_id = M.utc_compact_timestamp() .. "-" .. M.note_to_slug(opts.note)
    local filename  = "frpc-backup-" .. backup_id .. ".tar.gz"
    local workdir   = "/tmp/frpc_backup_build_" .. backup_id
    local pkgroot   = workdir .. "/frpc-backup"

    -- 清理可能残留的 workdir
    sys.call("rm -rf " .. util.shellquote(workdir))
    if M.sh_call("mkdir -p " .. util.shellquote(pkgroot)) ~= 0 then
        return false, "无法创建临时打包目录"
    end

    local arch_raw, frp_platform = M.arch_info()
    local manifest = {
        schema_version       = M.SCHEMA_VERSION,
        pkg                  = M.PKG_NAME,
        created_at           = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        created_at_local     = M.local_iso_timestamp(),
        note                 = opts.note or "",
        hostname             = M.hostname(),
        frpc_active_version  = M.current_frpc_version(),
        downloaded_versions  = opts.includes.version_metadata and M.list_downloaded_versions() or {},
        download_mirror      = opts.download_mirror or "",
        includes             = opts.includes,
        files                = {},
        platform = {
            arch_raw     = arch_raw,
            frp_platform = frp_platform,
        },
    }

    -- 复制 UCI 配置
    if opts.includes.uci and fs.access(M.UCI_FILE) then
        if M.sh_call("mkdir -p " .. util.shellquote(pkgroot .. "/etc/config")) ~= 0 then
            sys.call("rm -rf " .. util.shellquote(workdir))
            return false, "无法创建 etc/config 目录"
        end
        local dst = pkgroot .. "/etc/config/frpc"
        if M.sh_call("cp -f " .. util.shellquote(M.UCI_FILE) .. " " .. util.shellquote(dst)) ~= 0 then
            sys.call("rm -rf " .. util.shellquote(workdir))
            return false, "复制 UCI 配置失败"
        end
        manifest.files["etc/config/frpc"] = {
            size   = M.file_size(dst),
            sha256 = M.sha256_file(dst),
        }
    end

    -- 复制 frpc 二进制
    if opts.includes.current_binary and fs.access(M.BIN_FILE) then
        if M.sh_call("mkdir -p " .. util.shellquote(pkgroot .. "/bin")) ~= 0 then
            sys.call("rm -rf " .. util.shellquote(workdir))
            return false, "无法创建 bin 目录"
        end
        local dst = pkgroot .. "/bin/frpc"
        if M.sh_call("cp -f " .. util.shellquote(M.BIN_FILE) .. " " .. util.shellquote(dst)) ~= 0 then
            sys.call("rm -rf " .. util.shellquote(workdir))
            return false, "复制 frpc 二进制失败"
        end
        manifest.files["bin/frpc"] = {
            size   = M.file_size(dst),
            sha256 = M.sha256_file(dst),
        }
    end

    -- 写 manifest.json
    if not M.write_json_file(pkgroot .. "/manifest.json", manifest) then
        sys.call("rm -rf " .. util.shellquote(workdir))
        return false, "写 manifest.json 失败"
    end

    -- 写 README.txt
    local readme = string.format(
[[luci-app-frpc 备份包
====================
备份时间：%s
设备主机名：%s
当前 frpc 版本：%s
架构：%s

本包由 luci-app-frpc 备份/还原模块生成。
还原方法：
1) 上传本 .tar.gz 到目标设备的 luci-app-frpc「备份/还原」页面；
2) 在历史列表中点击「还原」。

如需手工还原：
  tar -xzf <本包> -C /tmp/
  /etc/init.d/frpc stop
  cp /tmp/frpc-backup/etc/config/frpc /etc/config/frpc
  cp /tmp/frpc-backup/bin/frpc /usr/bin/frpc.new && mv /usr/bin/frpc.new /usr/bin/frpc
  chmod 0755 /usr/bin/frpc
  /etc/init.d/frpc start

备注：%s
]],
        manifest.created_at_local, manifest.hostname,
        manifest.frpc_active_version, manifest.platform.arch_raw,
        manifest.note ~= "" and manifest.note or "（无）")
    fs.writefile(pkgroot .. "/README.txt", readme)

    -- 打包 tar.gz
    local tar_path = "/tmp/" .. filename
    -- -C workdir 然后只压 frpc-backup 这个顶层目录；解压时所有路径以 frpc-backup/ 开头
    local cmd = string.format(
        "tar -czf %s -C %s frpc-backup",
        util.shellquote(tar_path), util.shellquote(workdir))
    if M.sh_call(cmd) ~= 0 then
        sys.call("rm -rf " .. util.shellquote(workdir))
        sys.call("rm -f " .. util.shellquote(tar_path))
        return false, "tar 打包失败"
    end

    -- 清理工作目录
    sys.call("rm -rf " .. util.shellquote(workdir))

    return true, {
        backup_id = backup_id,
        filename  = filename,
        tar_path  = tar_path,
        manifest  = manifest,
        size      = M.file_size(tar_path) or 0,
    }
end

-- ─────────────────────── 解包与校验 ───────────────────────

-- 把 tar_path 解到临时目录，校验 manifest 和 sha256
-- 返回 ok, result | err
--   result = { unpack_dir, manifest }
function M.unpack_and_verify(tar_path)
    if not fs.access(tar_path) then
        return false, "备份文件不存在"
    end

    local stem = "frpc_restore_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999))
    local unpack_dir = "/tmp/" .. stem
    sys.call("rm -rf " .. util.shellquote(unpack_dir))
    if M.sh_call("mkdir -p " .. util.shellquote(unpack_dir)) ~= 0 then
        return false, "无法创建解压目录"
    end

    -- tar slip 防护：解压前列出条目，拒绝 .. / 绝对路径 / 非 frpc-backup/ 前缀
    local listing = sys.exec("tar -tzf " .. util.shellquote(tar_path) .. " 2>/dev/null")
    if not listing or listing == "" then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "tar 列举失败（可能不是合法 tar.gz）"
    end
    for line in listing:gmatch("[^\n]+") do
        if line ~= "" then
            if line:sub(1, 1) == "/" then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "备份包含绝对路径条目：" .. line
            end
            if line:find("..", 1, true) then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "备份包含 .. 条目（路径穿越）：" .. line
            end
            if not line:match("^frpc%-backup/?$") and not line:match("^frpc%-backup/") then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "备份条目不在 frpc-backup/ 命名空间内：" .. line
            end
        end
    end

    local cmd = string.format("tar -xzf %s -C %s",
        util.shellquote(tar_path), util.shellquote(unpack_dir))
    if M.sh_call(cmd) ~= 0 then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "tar 解压失败（可能不是 tar.gz 或损坏）"
    end

    local pkgroot = unpack_dir .. "/frpc-backup"
    if not fs.access(pkgroot .. "/manifest.json") then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "备份包结构非法：缺少 frpc-backup/manifest.json"
    end

    local manifest = M.read_json_file(pkgroot .. "/manifest.json")
    if not manifest then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "manifest.json 无法解析"
    end

    -- 校验 pkg 与 schema_version
    if manifest.pkg ~= M.PKG_NAME then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "备份包 pkg 不匹配，期望 " .. M.PKG_NAME .. "，实际 " .. tostring(manifest.pkg)
    end
    if tonumber(manifest.schema_version) ~= M.SCHEMA_VERSION then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
        return false, "备份包 schema_version 不兼容，期望 " .. M.SCHEMA_VERSION .. "，实际 " .. tostring(manifest.schema_version)
    end

    -- 校验 sha256
    if type(manifest.files) == "table" then
        for rel_path, info in pairs(manifest.files) do
            -- 主动校验 rel_path：不允许 ..、不允许绝对路径
            if type(rel_path) ~= "string" or rel_path == ""
                or rel_path:sub(1, 1) == "/"
                or rel_path:find("..", 1, true) then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "manifest.files 含非法 rel_path：" .. tostring(rel_path)
            end
            local abs = pkgroot .. "/" .. rel_path
            if not fs.access(abs) then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "备份包文件缺失：" .. rel_path
            end
            local actual = M.sha256_file(abs)
            if actual ~= info.sha256 then
                sys.call("rm -rf " .. util.shellquote(unpack_dir))
                return false, "文件校验失败：" .. rel_path .. "（manifest 与实际不一致）"
            end
        end
    end

    return true, {
        unpack_dir = unpack_dir,
        pkgroot    = pkgroot,
        manifest   = manifest,
    }
end

-- 清理临时解包目录。
-- 调用约定：unpack_dir 必须是 unpack_and_verify 返回的路径，不接受外部任意输入；
-- 白名单 ^/tmp/frpc_restore_ 仅为 defense-in-depth，遇符号链接欺骗不在此函数防护范围。
function M.cleanup_unpack(unpack_dir)
    if unpack_dir and unpack_dir:match("^/tmp/frpc_restore_") then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
    end
end


-- ─────────────────────── 还原 ───────────────────────

-- 把已解压的备份内容应用到系统
-- pkgroot: unpack 后的 frpc-backup/ 目录
-- 返回 ok, err
function M.apply_unpacked(pkgroot, manifest)
    -- 1) 停 frpc 服务
    sys.call("/etc/init.d/frpc stop >/dev/null 2>&1")

    -- 2) 还 UCI
    if manifest.includes and manifest.includes.uci then
        local src = pkgroot .. "/etc/config/frpc"
        if not fs.access(src) then
            return false, "manifest 声明含 UCI 但文件不存在"
        end
        if M.sh_call("cp -f " .. util.shellquote(src) .. " " .. util.shellquote(M.UCI_FILE)) ~= 0 then
            return false, "覆盖 UCI 配置失败"
        end
        sys.call("chmod 0644 " .. util.shellquote(M.UCI_FILE))
        sys.call("uci -q commit frpc 2>/dev/null")
    end

    -- 3) 还二进制（原子替换，避免 ETXTBSY）
    if manifest.includes and manifest.includes.current_binary then
        local src = pkgroot .. "/bin/frpc"
        if not fs.access(src) then
            return false, "manifest 声明含二进制但文件不存在"
        end
        local tmp = M.BIN_FILE .. ".new"
        local cmd = string.format(
            "cp -f %s %s && chmod 0755 %s && mv -f %s %s",
            util.shellquote(src), util.shellquote(tmp),
            util.shellquote(tmp),
            util.shellquote(tmp), util.shellquote(M.BIN_FILE))
        if M.sh_call(cmd) ~= 0 then
            sys.call("rm -f " .. util.shellquote(tmp))
            return false, "原子替换 " .. M.BIN_FILE .. " 失败"
        end
        -- 锁回 default_client_file
        -- 注意：UCI 文件在第 2 步被外部 cp 直接覆盖，模块级 cursor 缓存可能持有旧值，先 load("frpc") 强制刷新。
        uci:load("frpc")
        if uci:get("frpc", "main", "default_client_file") ~= M.BIN_FILE then
            uci:set("frpc", "main", "default_client_file", M.BIN_FILE)
            uci:commit("frpc")
        end
    end

    -- 4) 起 frpc 服务
    sys.call("/etc/init.d/frpc start >/dev/null 2>&1")

    -- 5) 等 2 秒，检测 frpc 是否真起来了
    sys.call("sleep 2")
    -- busybox pgrep 不支持 `--`，且 `pgrep -f frpc` 模式过宽（会匹配本 lua 进程命令行里的 frpc 字样）；
    -- 只用精确模式 `/usr/bin/frpc` 匹配真实 frpc 进程的 cmdline。
    local running = sys.call("pgrep -f '/usr/bin/frpc' >/dev/null 2>&1") == 0

    if not running then
        return false, "frpc 启动失败（自动回滚将启动）"
    end

    return true, nil
end

-- 滚动保留：删除 .auto-snapshots/ 下最老的，保留最近 KEEP 份
function M.prune_auto_snapshots()
    if not fs.stat(M.AUTO_SNAPSHOTS_DIR) then return end
    local list = {}
    for entry in fs.dir(M.AUTO_SNAPSHOTS_DIR) do
        if entry:match("%.tar%.gz$") then
            local p = M.AUTO_SNAPSHOTS_DIR .. "/" .. entry
            local st = fs.stat(p)
            table.insert(list, { path = p, mtime = (st and st.mtime) or 0 })
        end
    end
    table.sort(list, function(a, b) return a.mtime > b.mtime end)
    for i = M.AUTO_SNAPSHOTS_KEEP + 1, #list do
        sys.call("rm -f " .. util.shellquote(list[i].path))
    end
end

-- 创建还原前自动快照（直接调用 pack_backup，放到 .auto-snapshots/）
-- 返回 ok, snapshot_tar_path | err
function M.create_auto_snapshot()
    -- 兜底创建目录
    M.sh_call("mkdir -p " .. util.shellquote(M.AUTO_SNAPSHOTS_DIR))

    local ok, res = M.pack_backup({
        note = "auto-before-restore",
        includes = { uci = true, current_binary = true, version_metadata = true },
        download_mirror = uci:get("frpc", "main", "download_mirror") or "",
    })
    if not ok then return false, "自动快照打包失败：" .. tostring(res) end

    local dst = M.AUTO_SNAPSHOTS_DIR .. "/" .. res.filename
    if M.sh_call("mv -f " .. util.shellquote(res.tar_path) .. " " .. util.shellquote(dst)) ~= 0 then
        sys.call("rm -f " .. util.shellquote(res.tar_path))
        return false, "自动快照移入 .auto-snapshots/ 失败"
    end

    M.prune_auto_snapshots()
    return true, dst
end

-- ─────────────────────── Driver 加载 ───────────────────────

local DRIVER_MODULES = {
    ["local"] = "luci.frpc.driver_local",
    webdav    = "luci.frpc.driver_webdav",
    s3        = "luci.frpc.driver_s3",
}

function M.load_driver(cfg)
    if type(cfg) ~= "table" then return nil, "无效 destination 配置" end
    local mod_path = DRIVER_MODULES[cfg.type]
    if not mod_path then return nil, "未知 driver 类型: " .. tostring(cfg.type) end
    local ok, mod = pcall(require, mod_path)
    if not ok then return nil, "加载 driver 失败: " .. tostring(mod) end
    return mod.new(cfg)
end

-- 从 UCI 读取一个 destination
function M.load_destination(dest_id)
    if not M.valid_id(dest_id) then return nil, "无效 destination id" end
    if uci:get("frpc", dest_id) ~= "destination" then
        return nil, "destination 不存在"
    end
    local cfg = uci:get_all("frpc", dest_id) or {}
    cfg[".name"] = nil
    cfg[".type"] = nil
    cfg[".anonymous"] = nil
    cfg.id = dest_id
    return cfg, nil
end

-- 列出所有 destination（含 enabled=0 的）
function M.list_all_destinations()
    local list = {}
    uci:foreach("frpc", "destination", function(s)
        local id = s[".name"]
        local cfg = uci:get_all("frpc", id) or {}
        cfg[".name"] = nil
        cfg[".type"] = nil
        cfg[".anonymous"] = nil
        cfg.id = id
        table.insert(list, cfg)
    end)
    return list
end

return M
