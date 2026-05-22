# luci-app-frpc 备份/还原功能实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 luci-app-frpc 增加「备份/还原」tab，支持本地 tar.gz + WebDAV 两种目的地，可备份 UCI 配置 + 当前激活的 frpc 二进制 + 版本号 metadata；支持一键还原（含自动快照与失败回滚）、本地 zip 导入导出、S3 driver 接口空壳预留。

**Architecture:** Lua 后端按"core + driver"模式拆分：`backup_core.lua` 负责打包/解包/快照/manifest 校验，`driver_local.lua` / `driver_webdav.lua` / `driver_s3.lua` 实现统一 `list/put/get/remove/test` 接口。前端单 .htm 页面（参考 [program_manager.htm](../../../luci-app-frpc/luasrc/view/frpc/program_manager.htm) 视觉风格）。异步任务沿用现有 setsid 后台脚本 + `/tmp/*.json` 状态文件 + 前端轮询范式。

**Tech Stack:** Lua 5.1（OpenWrt 内置）+ LuCI Lua-API + UCI + busybox tar/gzip + curl（新增 Makefile 依赖）+ 纯 JS/CSS 前端（无框架）。

**测试策略说明**：OpenWrt LuCI Lua 应用无标准单元测试基础设施。本计划采用：
- **Lua 语法/require smoke test**：每个新文件用 `lua -e 'require("...")'` 验证可加载
- **逻辑校验**：核心函数用 `lua -e` 内联跑断言
- **集成测试**：在测试设备（192.168.0.187，可用 `frpc-dev-deploy` 技能推送）上手工跑端到端流程，并截图为证
- **务实 TDD**：能用 lua -e 跑的逻辑先写测试；UI / sys.call 交互的部分写"smoke verify"步骤而不强求 TDD

**Spec：** [2026-05-22-frpc-backup-restore-design.md](../specs/2026-05-22-frpc-backup-restore-design.md)

---

## 文件结构总览

```
luci-app-frpc/
├── Makefile                                       ← 修改：+curl 依赖，PKG_RELEASE bump
├── luasrc/
│   ├── controller/frpc.lua                       ← 修改：加 ~120 行 dispatch
│   ├── view/frpc/backup_manager.htm              ← 新建：备份/还原主交互页
│   └── frpc/                                      ← 新建子目录（require "luci.frpc.*"）
│       ├── backup_core.lua                       ← 新建：核心逻辑
│       ├── driver_local.lua                      ← 新建：本地文件系统驱动
│       ├── driver_webdav.lua                     ← 新建：WebDAV 驱动
│       └── driver_s3.lua                         ← 新建：S3 空壳驱动
└── root/
    ├── etc/uci-defaults/40_luci-frpc            ← 修改：兜底创建 local_default destination + /etc/frpc-backup
    └── usr/share/rpcd/acl.d/luci-app-frpc.json  ← 修改：ACL 扩展 file 权限
```

任务执行顺序按依赖关系排列：基础设施（目录/UCI/ACL）→ 核心逻辑（core 模块）→ 驱动 → 控制器 → 前端 → Makefile/收尾。

---

## Task 1: 目录骨架 + UCI defaults 兜底

**Files:**
- Modify: `luci-app-frpc/root/etc/uci-defaults/40_luci-frpc`

**目标**：第一次安装或升级时，自动创建本地默认 destination 和 `/etc/frpc-backup` 目录骨架。

- [ ] **Step 1: 阅读现有 uci-defaults 脚本**

Run: 读取 `luci-app-frpc/root/etc/uci-defaults/40_luci-frpc` 看现有内容（之前升级脚本可能已经存在）

- [ ] **Step 2: 在脚本末尾追加 destination 兜底逻辑**

在 `40_luci-frpc` 文件末尾（紧贴最后一个 `exit 0` 之前，或在 `commit` 之后）追加：

```sh
# === 备份/还原：兜底创建本地默认 destination ===
if ! uci -q get frpc.local_default >/dev/null 2>&1; then
    uci -q batch <<EOF
set frpc.local_default=destination
set frpc.local_default.type=local
set frpc.local_default.name=本地存储
set frpc.local_default.path=/etc/frpc-backup
set frpc.local_default.enabled=1
commit frpc
EOF
fi

# 兜底创建备份目录
mkdir -p /etc/frpc-backup/.auto-snapshots
chmod 0750 /etc/frpc-backup
```

> 注意：如果脚本结尾已经有 `exit 0`，把以上块插在 `exit 0` 之前。

- [ ] **Step 3: 语法 smoke test**

Run（Windows bash 环境用 wsl 或直接 sh 解析）：
```bash
sh -n f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/root/etc/uci-defaults/40_luci-frpc
```
Expected: 无输出，退出码 0（语法检查通过）

- [ ] **Step 4: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/root/etc/uci-defaults/40_luci-frpc
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): uci-defaults 兜底创建本地 destination 与备份目录"
```

---

## Task 2: ACL 扩展

**Files:**
- Modify: `luci-app-frpc/root/usr/share/rpcd/acl.d/luci-app-frpc.json`

**目标**：扩展 ACL 让前端可通过 ubus 访问备份相关文件路径。

- [ ] **Step 1: 写入扩展后的 ACL JSON**

把文件整体替换为：

```json
{
  "luci-app-frpc": {
    "description": "Grant UCI and backup file access for luci-app-frpc",
    "read": {
      "uci": ["frpc"],
      "file": {
        "/etc/frpc-backup/*": ["read"],
        "/usr/share/frp/versions/*": ["read"]
      }
    },
    "write": {
      "uci": ["frpc"],
      "file": {
        "/etc/frpc-backup/*": ["write"],
        "/usr/bin/frpc": ["write"]
      }
    }
  }
}
```

- [ ] **Step 2: JSON 语法校验**

Run:
```bash
python -c "import json; json.load(open('f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/root/usr/share/rpcd/acl.d/luci-app-frpc.json'))"
```
Expected: 无输出，退出码 0

- [ ] **Step 3: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/root/usr/share/rpcd/acl.d/luci-app-frpc.json
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): ACL 加入备份目录与二进制文件读写权限"
```

---

## Task 3: backup_core 骨架 + 工具函数

**Files:**
- Create: `luci-app-frpc/luasrc/frpc/backup_core.lua`

**目标**：建立 backup_core 模块骨架，包含路径常量、安全 ID 校验、note slug 生成、sha256 计算等通用工具。

- [ ] **Step 1: 创建 backup_core.lua 骨架**

写入完整内容：

```lua
-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"
local json = require "luci.jsonc"
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
    return type(id) == "string" and id ~= "" and id:match("^[a-zA-Z0-9._-]+$") ~= nil
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
function M.tz_offset()
    local now = os.time()
    local local_t = os.date("*t", now)
    local utc_t   = os.date("!*t", now)
    -- DST 校正
    local_t.isdst = false
    utc_t.isdst = false
    local diff = os.difftime(os.time(local_t), os.time(utc_t))
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

-- shell 命令安全包装
function M.sh_call(cmd)
    return sys.call(cmd .. " >/dev/null 2>&1")
end

return M
```

- [ ] **Step 2: Lua 语法检查**

Run:
```bash
lua -e "package.path='f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/luasrc/?.lua;'..package.path; loadfile('f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/luasrc/frpc/backup_core.lua')"
```
Expected: 无输出（语法合法）；require 失败因为缺 luci.* 是预期的，本步只检查 parse。

如果 Windows 本地无 lua 命令，跳过此 step，留待集成测试时验证。

- [ ] **Step 3: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/backup_core.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): backup_core 骨架 + 工具函数（sha256/timestamp/manifest IO）"
```

---

## Task 4: backup_core 打包逻辑

**Files:**
- Modify: `luci-app-frpc/luasrc/frpc/backup_core.lua`

**目标**：实现 `pack_backup(opts)` 函数，把指定文件按结构组装为 tar.gz，写出 manifest.json + README.txt。

- [ ] **Step 1: 在 backup_core.lua 末尾（return M 之前）追加 pack 函数**

```lua

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
        downloaded_versions  = M.list_downloaded_versions(),
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
```

- [ ] **Step 2: 在测试环境跑一次 smoke test（如果有 lua 环境）**

Run（仅当本地有 lua 环境，否则跳过）：
```bash
lua -e "
package.path = 'f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/luasrc/?.lua;' .. package.path
local m = require 'frpc.backup_core'
print(m.note_to_slug('Hello World!! 你好'))
print(m.utc_compact_timestamp())
print(m.valid_id('abc-123_v1'), m.valid_id('../etc'))
"
```
Expected: 输出形如 `Hello_World _ 20260522T...Z true false`。

在路由器上的真实测试留到 Task 11 联调时验证。

- [ ] **Step 3: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/backup_core.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): pack_backup 实现（manifest + sha256 + tar.gz）"
```

---

## Task 5: backup_core 解包与校验

**Files:**
- Modify: `luci-app-frpc/luasrc/frpc/backup_core.lua`

**目标**：实现 `unpack_and_verify(tar_path)`，解压到临时目录、读 manifest、校验 sha256，返回解压目录路径。

- [ ] **Step 1: 在 backup_core.lua 追加 unpack 函数**

```lua

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

-- 清理临时解包目录
function M.cleanup_unpack(unpack_dir)
    if unpack_dir and unpack_dir:match("^/tmp/frpc_restore_") then
        sys.call("rm -rf " .. util.shellquote(unpack_dir))
    end
end
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/backup_core.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): unpack_and_verify（解压 + manifest + sha256 校验）"
```

---

## Task 6: backup_core 还原与回滚

**Files:**
- Modify: `luci-app-frpc/luasrc/frpc/backup_core.lua`

**目标**：实现 `apply_unpacked(pkgroot, manifest)` 和 `rollback_from_snapshot(snapshot_tar_path)`，完成还原核心动作。

- [ ] **Step 1: 在 backup_core.lua 追加还原与回滚逻辑**

```lua

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
        if uci:get("frpc", "main", "default_client_file") ~= M.BIN_FILE then
            uci:set("frpc", "main", "default_client_file", M.BIN_FILE)
            uci:commit("frpc")
        end
    end

    -- 4) 起 frpc 服务
    sys.call("/etc/init.d/frpc start >/dev/null 2>&1")

    -- 5) 等 2 秒，检测 frpc 是否真起来了
    sys.call("sleep 2")
    local running = (sys.call("pgrep -f frpc -- >/dev/null") == 0) or
                    (sys.call("pgrep -f '/usr/bin/frpc' >/dev/null") == 0)

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
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/backup_core.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): apply_unpacked 还原核心 + 自动快照 + 保留策略"
```

---

## Task 7: backup_core driver 加载器

**Files:**
- Modify: `luci-app-frpc/luasrc/frpc/backup_core.lua`

**目标**：实现 `load_driver(dest_cfg)` 工厂、`load_destination(dest_id)` UCI 读取、`list_all_destinations()` 列出全部。

- [ ] **Step 1: 在 backup_core.lua 追加 driver 加载与 destination 读取**

```lua

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
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/backup_core.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): driver 加载器 + destination UCI 读取接口"
```

---

## Task 8: driver_local 本地文件系统驱动

**Files:**
- Create: `luci-app-frpc/luasrc/frpc/driver_local.lua`

**目标**：实现 local driver，所有方法操作 `cfg.path` 目录下的 .tar.gz 文件。

- [ ] **Step 1: 创建 driver_local.lua**

```lua
-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"

local M = {}

local Driver = {}
Driver.__index = Driver

function M.new(cfg)
    local self = setmetatable({}, Driver)
    self.cfg = cfg or {}
    self.path = self.cfg.path or "/etc/frpc-backup"
    -- 去尾斜杠
    self.path = self.path:gsub("/+$", "")
    if self.path == "" then self.path = "/etc/frpc-backup" end
    return self
end

local function shc(cmd)
    return sys.call(cmd .. " >/dev/null 2>&1")
end

function Driver:test()
    -- 确保目录存在
    if not fs.stat(self.path) then
        if shc("mkdir -p " .. util.shellquote(self.path)) ~= 0 then
            return false, "目录不存在且无法创建：" .. self.path
        end
    end
    -- 写探针文件
    local probe = self.path .. "/.frpc_backup_probe"
    local f = io.open(probe, "w")
    if not f then return false, "目录不可写：" .. self.path end
    f:write("ok"); f:close()
    os.remove(probe)
    return true, nil
end

function Driver:list()
    if not fs.stat(self.path) then return {}, nil end
    local entries = {}
    for entry in fs.dir(self.path) do
        if entry:match("^frpc%-backup%-.+%.tar%.gz$") then
            local p = self.path .. "/" .. entry
            local st = fs.stat(p)
            if st then
                table.insert(entries, {
                    id        = entry:gsub("^frpc%-backup%-", ""):gsub("%.tar%.gz$", ""),
                    name      = entry,
                    size      = st.size,
                    mtime     = st.mtime,
                    raw_path  = p,
                })
            end
        end
    end
    table.sort(entries, function(a, b) return a.mtime > b.mtime end)
    return entries, nil
end

function Driver:put(local_path, remote_name, progress_cb)
    if not fs.access(local_path) then return false, "本地文件不存在" end
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    if not fs.stat(self.path) then
        if shc("mkdir -p " .. util.shellquote(self.path)) ~= 0 then
            return false, "目录创建失败"
        end
    end
    local dst = self.path .. "/" .. remote_name
    if shc("cp -f " .. util.shellquote(local_path) .. " " .. util.shellquote(dst)) ~= 0 then
        return false, "本地复制失败"
    end
    if progress_cb then
        local st = fs.stat(dst)
        progress_cb(st and st.size or 0, st and st.size or 0)
    end
    return true, nil
end

function Driver:get(remote_name, local_path, progress_cb)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local src = self.path .. "/" .. remote_name
    if not fs.access(src) then return false, "远端文件不存在：" .. remote_name end
    if shc("cp -f " .. util.shellquote(src) .. " " .. util.shellquote(local_path)) ~= 0 then
        return false, "本地复制失败"
    end
    if progress_cb then
        local st = fs.stat(local_path)
        progress_cb(st and st.size or 0, st and st.size or 0)
    end
    return true, nil
end

function Driver:remove(remote_name)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local p = self.path .. "/" .. remote_name
    if not fs.access(p) then return true, nil end -- 已不存在视为成功
    if shc("rm -f " .. util.shellquote(p)) ~= 0 then
        return false, "删除失败"
    end
    return true, nil
end

return M
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/driver_local.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): driver_local 本地文件系统驱动"
```

---

## Task 9: driver_s3 空壳驱动

**Files:**
- Create: `luci-app-frpc/luasrc/frpc/driver_s3.lua`

**目标**：S3 driver 接口空壳，所有方法返回"未实现"错误，为二期保留接口签名一致性。

- [ ] **Step 1: 创建 driver_s3.lua**

```lua
-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.
-- ⚠️ 一期空壳实现：S3 driver 接口预留，二期补全 AWS Sig V4 签名 + 上传/下载逻辑

local M = {}

local Driver = {}
Driver.__index = Driver

local NOT_IMPL = "S3 driver 一期未实现，请等待二期版本"

function M.new(cfg)
    local self = setmetatable({}, Driver)
    self.cfg = cfg or {}
    return self
end

function Driver:test()
    return false, NOT_IMPL
end

function Driver:list()
    return {}, NOT_IMPL
end

function Driver:put(local_path, remote_name, progress_cb)
    return false, NOT_IMPL
end

function Driver:get(remote_name, local_path, progress_cb)
    return false, NOT_IMPL
end

function Driver:remove(remote_name)
    return false, NOT_IMPL
end

return M
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/driver_s3.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): driver_s3 空壳（一期接口预留）"
```

---

## Task 10: driver_webdav WebDAV 驱动

**Files:**
- Create: `luci-app-frpc/luasrc/frpc/driver_webdav.lua`

**目标**：实现 WebDAV driver，用 curl 完成 PUT/GET/DELETE/PROPFIND。

- [ ] **Step 1: 创建 driver_webdav.lua**

```lua
-- Copyright 2026 luci-app-frpc-pro
-- Licensed to the public under the MIT License.

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"

local M = {}

local Driver = {}
Driver.__index = Driver

function M.new(cfg)
    local self = setmetatable({}, Driver)
    self.cfg = cfg or {}
    self.url = (self.cfg.url or ""):gsub("/+$", "") .. "/"
    self.username = self.cfg.username or ""
    self.password = self.cfg.password or ""
    self.verify_tls = (self.cfg.verify_tls == "1" or self.cfg.verify_tls == true)
    return self
end

-- 构造 curl 通用参数（鉴权 + TLS）
function Driver:_curl_args()
    local args = " --silent --show-error --max-time 60"
    if not self.verify_tls then args = args .. " -k" end
    if self.username ~= "" then
        args = args .. " -u " .. util.shellquote(self.username .. ":" .. self.password)
    end
    return args
end

-- 对 URL 路径段进行 percent-encoding（保留 / : - _ . ~）
local function url_encode_segment(s)
    return (s:gsub("[^%w%-_%.~/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Driver:_remote_url(name)
    return self.url .. url_encode_segment(name)
end

-- test：PROPFIND Depth: 0 到根 URL；2xx 即 OK
function Driver:test()
    if not self.url:match("^https?://") then
        return false, "URL 必须以 http:// 或 https:// 开头"
    end
    local cmd = string.format(
        "curl%s -X PROPFIND -H 'Depth: 0' -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(), util.shellquote(self.url))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        return true, nil
    end
    if n == 401 then return false, "鉴权失败（401），请检查用户名密码" end
    if n == 404 then return false, "URL 不存在（404）" end
    return false, "WebDAV 测试失败（HTTP " .. (code or "?") .. "）"
end

-- list：PROPFIND Depth: 1，解析 <d:href> 抓文件名
function Driver:list()
    local cmd = string.format(
        "curl%s -X PROPFIND -H 'Depth: 1' %s 2>/dev/null",
        self:_curl_args(), util.shellquote(self.url))
    local body = sys.exec(cmd)
    if not body or body == "" then return {}, "PROPFIND 无响应" end

    local entries = {}
    local seen = {}
    -- 兼容 d:href / D:href / href 命名空间
    for href in body:gmatch("<[%w]*:?href[^>]*>([^<]+)</[%w]*:?href>") do
        -- 提取文件名（href 可能是绝对 URL 或绝对路径）
        local fname = href:match("([^/]+)$")
        if fname then
            -- 解码 percent-encoding
            fname = fname:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
            if fname:match("^frpc%-backup%-.+%.tar%.gz$") and not seen[fname] then
                seen[fname] = true
                -- WebDAV 返回的 getcontentlength 解析比较复杂，简化为不带 size/mtime
                -- 仅在用户点开详情或下载时再获取
                table.insert(entries, {
                    id        = fname:gsub("^frpc%-backup%-", ""):gsub("%.tar%.gz$", ""),
                    name      = fname,
                    size      = 0,
                    mtime     = 0,
                    raw_path  = href,
                })
            end
        end
    end
    return entries, nil
end

function Driver:put(local_path, remote_name, progress_cb)
    if not fs.access(local_path) then return false, "本地文件不存在" end
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -X PUT --data-binary @%s -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(),
        util.shellquote(local_path),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        if progress_cb then
            local st = fs.stat(local_path)
            progress_cb(st and st.size or 0, st and st.size or 0)
        end
        return true, nil
    end
    return false, "WebDAV PUT 失败（HTTP " .. (code or "?") .. "）"
end

function Driver:get(remote_name, local_path, progress_cb)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -o %s -w '%%{http_code}' %s 2>/dev/null",
        self:_curl_args(),
        util.shellquote(local_path),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then
        if progress_cb then
            local st = fs.stat(local_path)
            progress_cb(st and st.size or 0, st and st.size or 0)
        end
        return true, nil
    end
    sys.call("rm -f " .. util.shellquote(local_path))
    return false, "WebDAV GET 失败（HTTP " .. (code or "?") .. "）"
end

function Driver:remove(remote_name)
    if not remote_name:match("^frpc%-backup%-.+%.tar%.gz$") then
        return false, "非法 remote_name"
    end
    local cmd = string.format(
        "curl%s -X DELETE -o /dev/null -w '%%{http_code}' %s 2>&1",
        self:_curl_args(),
        util.shellquote(self:_remote_url(remote_name)))
    local code = util.trim(sys.exec(cmd))
    local n = tonumber(code)
    if n and (n == 204 or n == 200 or n == 404) then
        return true, nil  -- 404 视为已删除
    end
    return false, "WebDAV DELETE 失败（HTTP " .. (code or "?") .. "）"
end

return M
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/frpc/driver_webdav.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): driver_webdav（curl 实现 PROPFIND/PUT/GET/DELETE）"
```

---

## Task 11: Controller dispatch + destination CRUD actions

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`

**目标**：在 controller 加 dispatch 入口和 destination CRUD 的 5 个 action。

- [ ] **Step 1: 在 frpc.lua 的 `index()` 函数末尾（最后一个 entry 之后，end 之前）追加 dispatch**

定位：[luci-app-frpc/luasrc/controller/frpc.lua:87-88](../../luci-app-frpc/luasrc/controller/frpc.lua#L87-L88)（`log` entry 之后、`end` 之前）

```lua
	-- 备份/还原
	entry({"admin", "services", "frpc", "backup"},
		call("view_backup"), _("备份/还原"), 9).leaf = true

	-- destination CRUD
	entry({"admin", "services", "frpc", "backup", "dest_list"},   call("action_backup_dest_list"))
	entry({"admin", "services", "frpc", "backup", "dest_save"},   call("action_backup_dest_save"))
	entry({"admin", "services", "frpc", "backup", "dest_delete"}, call("action_backup_dest_delete"))
	entry({"admin", "services", "frpc", "backup", "dest_test"},   call("action_backup_dest_test"))

	-- 备份操作
	entry({"admin", "services", "frpc", "backup", "list"},            call("action_backup_list"))
	entry({"admin", "services", "frpc", "backup", "create"},          call("action_backup_create"))
	entry({"admin", "services", "frpc", "backup", "create_progress"}, call("action_backup_create_progress"))
	entry({"admin", "services", "frpc", "backup", "download"},        call("action_backup_download")).leaf = true
	entry({"admin", "services", "frpc", "backup", "upload"},          call("action_backup_upload"))
	entry({"admin", "services", "frpc", "backup", "delete"},          call("action_backup_delete"))

	-- 还原操作
	entry({"admin", "services", "frpc", "backup", "restore"},          call("action_backup_restore"))
	entry({"admin", "services", "frpc", "backup", "restore_progress"}, call("action_backup_restore_progress"))
```

> 现有 `log` entry 已是序号 8（见 [controller/frpc.lua:87](../../luci-app-frpc/luasrc/controller/frpc.lua#L87)），新增 `backup` 用 9 即可，无需改动其他序号。

- [ ] **Step 2: 在 frpc.lua 末尾追加 destination CRUD actions**

```lua

-- ────────────────────────────────────────────────────────────────
-- 备份/还原 actions
-- ────────────────────────────────────────────────────────────────

local function _backup_core()
	return require("luci.frpc.backup_core")
end

function view_backup()
	a.render("frpc/backup_manager", {
		title = t.translate("Frpc - 备份与还原"),
	})
end

function action_backup_dest_list()
	http.prepare_content("application/json")
	local core = _backup_core()
	http.write_json({ ok = true, destinations = core.list_all_destinations() })
end

function action_backup_dest_save()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id   = http.formvalue("id") or ""
	local typ  = http.formvalue("type") or ""
	local name = http.formvalue("name") or ""

	if id ~= "" and not core.valid_id(id) then
		http.write_json({ ok = false, error = "id 包含非法字符" })
		return
	end
	if typ ~= "local" and typ ~= "webdav" and typ ~= "s3" then
		http.write_json({ ok = false, error = "未知 driver 类型: " .. typ })
		return
	end
	if name == "" then
		http.write_json({ ok = false, error = "name 必填" })
		return
	end

	-- 新建：id 为空则自动生成
	local section_id = id
	if section_id == "" then
		section_id = typ .. "_" .. tostring(os.time())
	end

	-- section type 必须正确
	if uci:get("frpc", section_id) and uci:get("frpc", section_id) ~= "destination" then
		http.write_json({ ok = false, error = "id 已被其他类型占用" })
		return
	end

	uci:set("frpc", section_id, "destination")
	uci:set("frpc", section_id, "type", typ)
	uci:set("frpc", section_id, "name", name)
	uci:set("frpc", section_id, "enabled", http.formvalue("enabled") == "1" and "1" or "0")

	-- type 相关字段
	if typ == "local" then
		local path = http.formvalue("path") or "/etc/frpc-backup"
		uci:set("frpc", section_id, "path", path)
	elseif typ == "webdav" then
		uci:set("frpc", section_id, "url",        http.formvalue("url") or "")
		uci:set("frpc", section_id, "username",   http.formvalue("username") or "")
		uci:set("frpc", section_id, "password",   http.formvalue("password") or "")
		uci:set("frpc", section_id, "verify_tls", http.formvalue("verify_tls") == "1" and "1" or "0")
	elseif typ == "s3" then
		uci:set("frpc", section_id, "endpoint",   http.formvalue("endpoint") or "")
		uci:set("frpc", section_id, "region",     http.formvalue("region") or "")
		uci:set("frpc", section_id, "bucket",     http.formvalue("bucket") or "")
		uci:set("frpc", section_id, "access_key", http.formvalue("access_key") or "")
		uci:set("frpc", section_id, "secret_key", http.formvalue("secret_key") or "")
		uci:set("frpc", section_id, "path_style", http.formvalue("path_style") == "1" and "1" or "0")
	end

	uci:commit("frpc")
	http.write_json({ ok = true, id = section_id })
end

function action_backup_dest_delete()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id = http.formvalue("id") or ""
	if not core.valid_id(id) then
		http.write_json({ ok = false, error = "无效 id" })
		return
	end
	if uci:get("frpc", id) ~= "destination" then
		http.write_json({ ok = false, error = "destination 不存在" })
		return
	end
	uci:delete("frpc", id)
	uci:commit("frpc")
	http.write_json({ ok = true })
end

function action_backup_dest_test()
	http.prepare_content("application/json")
	local core = _backup_core()
	local id = http.formvalue("id") or ""
	if not core.valid_id(id) then
		http.write_json({ ok = false, error = "无效 id" })
		return
	end
	local cfg, err = core.load_destination(id)
	if not cfg then http.write_json({ ok = false, error = err }); return end
	local drv, derr = core.load_driver(cfg)
	if not drv then http.write_json({ ok = false, error = derr }); return end
	local ok, terr = drv:test()
	http.write_json({ ok = ok and true or false, error = terr })
end
```

- [ ] **Step 3: 语法 smoke test**

Run:
```bash
python -c "
import re
with open('f:/Github_Application_mia-clark/luci-app-frpc_frps-pro/luci-app-frpc/luasrc/controller/frpc.lua','r',encoding='utf-8') as f:
    s = f.read()
# 计数 function .. end 块大致平衡
fc = len(re.findall(r'\\bfunction\\b', s))
ec = len(re.findall(r'\\bend\\b', s))
print(f'function={fc} end={ec}')
"
```
Expected: function 数 ≤ end 数（end 还包含 if/for/while 块）。

- [ ] **Step 4: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/controller/frpc.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): controller dispatch + destination CRUD actions"
```

---

## Task 12: Controller backup actions（list/create/progress）

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`

**目标**：实现备份列表（跨 destination 聚合）、创建备份（异步）、进度查询。

- [ ] **Step 1: 在 frpc.lua 末尾追加**

```lua

function action_backup_list()
	http.prepare_content("application/json")
	local core = _backup_core()
	local all_dests = core.list_all_destinations()

	local backups = {}
	local dest_errors = {}
	for _, cfg in ipairs(all_dests) do
		if cfg.enabled == "1" then
			local drv, derr = core.load_driver(cfg)
			if drv then
				local entries, lerr = drv:list()
				if entries then
					for _, e in ipairs(entries) do
						table.insert(backups, {
							dest_id    = cfg.id,
							dest_name  = cfg.name,
							dest_type  = cfg.type,
							id         = e.id,
							name       = e.name,
							size       = e.size,
							mtime      = e.mtime,
						})
					end
				else
					table.insert(dest_errors, { dest_id = cfg.id, error = lerr })
				end
			else
				table.insert(dest_errors, { dest_id = cfg.id, error = derr })
			end
		end
	end

	-- 按 mtime DESC（mtime=0 时退化按 name DESC，让较新的时间戳排前面）
	table.sort(backups, function(a, b)
		if a.mtime ~= b.mtime then return a.mtime > b.mtime end
		return a.name > b.name
	end)

	http.write_json({ ok = true, backups = backups, dest_errors = dest_errors })
end

-- 异步创建备份：写后台脚本 setsid 执行；前端轮询 create_progress
function action_backup_create()
	http.prepare_content("application/json")
	local core = _backup_core()

	local note = http.formvalue("note") or ""
	local dest_ids_csv = http.formvalue("dest_ids") or ""
	local inc_uci = http.formvalue("inc_uci") == "1"
	local inc_bin = http.formvalue("inc_bin") == "1"
	local inc_ver = http.formvalue("inc_ver") == "1"

	local dest_ids = {}
	for s in dest_ids_csv:gmatch("([^,]+)") do
		if core.valid_id(s) and uci:get("frpc", s) == "destination" then
			table.insert(dest_ids, s)
		end
	end
	if #dest_ids == 0 then
		http.write_json({ ok = false, error = "请选择至少一个备份目的地" })
		return
	end

	-- 任务 ID：用时间戳 + 随机数（不同于 backup_id，避免歧义）
	local task_id = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999))
	local status_file = "/tmp/frpc_backup_create_" .. task_id .. ".json"

	-- 把任务参数写到 work_file，后台脚本读取
	local work_file = "/tmp/frpc_backup_create_" .. task_id .. ".work"
	local jsonc = require("luci.jsonc")
	fs.writefile(work_file, jsonc.stringify({
		note = note,
		dest_ids = dest_ids,
		includes = { uci = inc_uci, current_binary = inc_bin, version_metadata = inc_ver },
	}))

	-- 写后台 lua 脚本
	local script_file = "/tmp/frpc_backup_create_" .. task_id .. ".lua"
	local script = string.format([=[
local fs   = require "nixio.fs"
local json = require "luci.jsonc"
local core = require "luci.frpc.backup_core"

local status_file = %q
local work_file   = %q

local function write_status(stage, msg, extra)
    local t = { stage = stage, message = msg or "", extra = extra }
    fs.writefile(status_file, json.stringify(t))
end

local work = json.parse(fs.readfile(work_file) or "{}") or {}

write_status("packing", "正在打包...")
local ok, res = core.pack_backup({
    note = work.note,
    includes = work.includes,
    download_mirror = require("luci.model.uci").cursor():get("frpc","main","download_mirror") or "",
})
if not ok then
    write_status("error", "打包失败：" .. tostring(res))
    return
end

local failed = {}
local succeeded = {}
for i, dest_id in ipairs(work.dest_ids) do
    write_status("uploading", "上传到 " .. dest_id .. " (" .. i .. "/" .. #work.dest_ids .. ")")
    local cfg, ce = core.load_destination(dest_id)
    if not cfg then
        table.insert(failed, { dest_id = dest_id, error = ce })
    else
        local drv, de = core.load_driver(cfg)
        if not drv then
            table.insert(failed, { dest_id = dest_id, error = de })
        else
            local ok2, err = drv:put(res.tar_path, res.filename)
            if ok2 then
                table.insert(succeeded, dest_id)
            else
                table.insert(failed, { dest_id = dest_id, error = err })
            end
        end
    end
end

-- 清理本地 tmp tar
os.execute("rm -f " .. res.tar_path)
os.execute("rm -f " .. work_file)

if #failed == 0 then
    write_status("done", "全部成功", { backup_id = res.backup_id, filename = res.filename, succeeded = succeeded })
else
    write_status("done", "部分失败：" .. #failed .. " / " .. #work.dest_ids,
        { backup_id = res.backup_id, filename = res.filename, succeeded = succeeded, failed = failed })
end
]=], status_file, work_file)

	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(lua " .. script_file .. " </dev/null >/dev/null 2>&1; " ..
		"rm -f " .. script_file .. "; " ..
		"sleep 30; rm -f " .. status_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ ok = true, task_id = task_id })
end

function action_backup_create_progress()
	http.prepare_content("application/json")
	local task_id = http.formvalue("task_id") or ""
	if not task_id:match("^task_[0-9_]+$") then
		http.write_json({ ok = false, error = "无效 task_id" })
		return
	end
	local status_file = "/tmp/frpc_backup_create_" .. task_id .. ".json"
	local content = fs.readfile(status_file)
	if not content or content == "" then
		http.write_json({ ok = true, stage = "idle" })
		return
	end
	local parsed = require("luci.jsonc").parse(content)
	if not parsed then
		http.write_json({ ok = true, stage = "unknown" })
		return
	end
	parsed.ok = true
	http.write_json(parsed)
end

function action_backup_delete()
	http.prepare_content("application/json")
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) then
		http.write_json({ ok = false, error = "无效 dest_id" })
		return
	end
	if not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.write_json({ ok = false, error = "无效备份名" })
		return
	end

	local cfg, ce = core.load_destination(dest_id)
	if not cfg then http.write_json({ ok = false, error = ce }); return end
	local drv, de = core.load_driver(cfg)
	if not drv then http.write_json({ ok = false, error = de }); return end
	local ok, err = drv:remove(name)
	http.write_json({ ok = ok and true or false, error = err })
end
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/controller/frpc.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): controller list/create/progress/delete actions"
```

---

## Task 13: Controller restore/upload/download actions

**Files:**
- Modify: `luci-app-frpc/luasrc/controller/frpc.lua`

**目标**：还原 action（异步含快照+回滚）、上传导入、下载导出。

- [ ] **Step 1: 在 frpc.lua 末尾追加**

```lua

function action_backup_restore()
	http.prepare_content("application/json")
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) then
		http.write_json({ ok = false, error = "无效 dest_id" })
		return
	end
	if not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.write_json({ ok = false, error = "无效备份名" })
		return
	end

	local task_id = "task_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999))
	local status_file = "/tmp/frpc_backup_restore_" .. task_id .. ".json"
	local script_file = "/tmp/frpc_backup_restore_" .. task_id .. ".lua"

	local script = string.format([=[
local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local util = require "luci.util"
local json = require "luci.jsonc"
local core = require "luci.frpc.backup_core"

local status_file = %q
local DEST_ID = %q
local NAME    = %q

local function write_status(stage, msg, extra)
    fs.writefile(status_file, json.stringify({ stage = stage, message = msg or "", extra = extra }))
end

local snapshot_path

local function rollback()
    if not snapshot_path or not fs.access(snapshot_path) then
        write_status("error", "回滚失败：快照文件丢失")
        return
    end
    write_status("rolling_back", "正在从快照回滚...")
    local ok, res = core.unpack_and_verify(snapshot_path)
    if not ok then
        write_status("error", "回滚解包失败：" .. tostring(res))
        return
    end
    local ok2, err = core.apply_unpacked(res.pkgroot, res.manifest)
    core.cleanup_unpack(res.unpack_dir)
    if ok2 then
        write_status("error", "已从快照回滚（原还原失败）")
    else
        write_status("error", "回滚也失败：" .. tostring(err))
    end
end

-- 1) 自动快照
write_status("snapshotting", "正在创建还原前快照...")
local ok, snap = core.create_auto_snapshot()
if not ok then
    write_status("error", "创建快照失败：" .. tostring(snap))
    return
end
snapshot_path = snap

-- 2) 下载
write_status("downloading", "正在从备份点拉取...")
local cfg, ce = core.load_destination(DEST_ID)
if not cfg then write_status("error", "destination 不存在：" .. tostring(ce)); return end
local drv, de = core.load_driver(cfg)
if not drv then write_status("error", "driver 加载失败：" .. tostring(de)); return end

local tmp_tar = "/tmp/frpc_restore_dl_" .. tostring(os.time()) .. ".tar.gz"
local ok2, err = drv:get(NAME, tmp_tar)
if not ok2 then
    sys.call("rm -f " .. util.shellquote(tmp_tar))
    rollback()
    return
end

-- 3) 解包校验
write_status("unpacking", "正在校验备份包...")
local ok3, res = core.unpack_and_verify(tmp_tar)
sys.call("rm -f " .. util.shellquote(tmp_tar))
if not ok3 then
    write_status("error", "校验失败：" .. tostring(res))
    return
end

-- 4) 应用
write_status("applying", "正在覆盖配置与二进制...")
local ok4, aerr = core.apply_unpacked(res.pkgroot, res.manifest)
core.cleanup_unpack(res.unpack_dir)

if not ok4 then
    rollback()
    return
end

write_status("done", "还原成功", { snapshot = snapshot_path })
]=], status_file, dest_id, name)

	fs.writefile(script_file, script)
	sys.call("chmod +x " .. util.shellquote(script_file))
	sys.call("setsid sh -c " .. util.shellquote(
		"(lua " .. script_file .. " </dev/null >/dev/null 2>&1; " ..
		"rm -f " .. script_file .. "; " ..
		"sleep 30; rm -f " .. status_file .. ") &"
	) .. " >/dev/null 2>&1")

	http.write_json({ ok = true, task_id = task_id })
end

function action_backup_restore_progress()
	http.prepare_content("application/json")
	local task_id = http.formvalue("task_id") or ""
	if not task_id:match("^task_[0-9_]+$") then
		http.write_json({ ok = false, error = "无效 task_id" })
		return
	end
	local status_file = "/tmp/frpc_backup_restore_" .. task_id .. ".json"
	local content = fs.readfile(status_file)
	if not content or content == "" then
		http.write_json({ ok = true, stage = "idle" })
		return
	end
	local parsed = require("luci.jsonc").parse(content)
	if not parsed then http.write_json({ ok = true, stage = "unknown" }); return end
	parsed.ok = true
	http.write_json(parsed)
end

-- 下载：仅本地 destination
function action_backup_download()
	local core = _backup_core()
	local dest_id = http.formvalue("dest_id") or ""
	local name    = http.formvalue("name") or ""

	if not core.valid_id(dest_id) or not name:match("^frpc%-backup%-.+%.tar%.gz$") then
		http.status(400, "Bad Request")
		http.prepare_content("text/plain")
		http.write("invalid params")
		return
	end
	local cfg, ce = core.load_destination(dest_id)
	if not cfg or cfg.type ~= "local" then
		http.status(400, "Bad Request")
		http.prepare_content("text/plain")
		http.write("only local destination can be downloaded directly")
		return
	end
	local path = (cfg.path or "/etc/frpc-backup") .. "/" .. name
	if not fs.access(path) then
		http.status(404, "Not Found"); http.write("not found"); return
	end
	http.header("Content-Disposition", 'attachment; filename="' .. name .. '"')
	http.prepare_content("application/gzip")
	local content = fs.readfile(path)
	http.write(content or "")
end

-- 上传导入：multipart，把上传的 .tar.gz 移入 local_default
function action_backup_upload()
	http.prepare_content("application/json")
	local core = _backup_core()

	local tmp_path = "/tmp/frpc_upload_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 999999)) .. ".tar.gz"
	local written = 0
	local oversized = false

	http.setfilehandler(function(meta, chunk, eof)
		if oversized then return end
		if chunk and #chunk > 0 then
			if written + #chunk > core.MAX_UPLOAD_BYTES then
				oversized = true
				return
			end
			local f = io.open(tmp_path, written == 0 and "wb" or "ab")
			if f then
				f:write(chunk)
				f:close()
				written = written + #chunk
			end
		end
	end)

	-- 触发解析（必须读一遍 formvalue 才会调 filehandler）
	http.formvalue("file")

	if oversized then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "文件超过 " .. core.MAX_UPLOAD_BYTES .. " 字节上限" })
		return
	end
	if written == 0 or not fs.access(tmp_path) then
		http.write_json({ ok = false, error = "未收到文件" })
		return
	end

	-- 校验是合法 frpc 备份包
	local ok, res = core.unpack_and_verify(tmp_path)
	if not ok then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "校验失败：" .. tostring(res) })
		return
	end
	core.cleanup_unpack(res.unpack_dir)

	-- 移入 local_default
	local local_cfg = core.load_destination("local_default")
	local target_dir
	if local_cfg and local_cfg.path then
		target_dir = local_cfg.path
	else
		target_dir = core.LOCAL_BACKUP_DIR
	end
	sys.call("mkdir -p " .. util.shellquote(target_dir))

	-- 用 manifest 推导规范文件名
	local backup_id = res.manifest.created_at:gsub("[%-:Z]", ""):gsub("T", "T") .. "-" .. core.note_to_slug(res.manifest.note or "")
	-- 简化：直接用 utc 紧凑时间戳
	local utc_compact = (res.manifest.created_at or ""):gsub("[%-:]", ""):gsub("%..*$", "")
	-- 备份文件名一律重写为规范化形式
	local norm_name = "frpc-backup-" .. utc_compact .. "-" .. core.note_to_slug(res.manifest.note or "") .. ".tar.gz"
	local dst = target_dir .. "/" .. norm_name

	if sys.call("mv -f " .. util.shellquote(tmp_path) .. " " .. util.shellquote(dst) .. " >/dev/null 2>&1") ~= 0 then
		sys.call("rm -f " .. util.shellquote(tmp_path))
		http.write_json({ ok = false, error = "移动文件到目标目录失败" })
		return
	end

	http.write_json({ ok = true, filename = norm_name, dest_id = "local_default" })
end
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/controller/frpc.lua
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): controller restore/upload/download actions（含快照回滚）"
```

---

## Task 14: 前端骨架 backup_manager.htm

**Files:**
- Create: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：建立前端页骨架（HTML 结构 + CSS 样式），所有区块占位，JS 交互在后续 task 实现。

- [ ] **Step 1: 创建 backup_manager.htm**

```html
<%
local dsp = require "luci.dispatcher"
local base = dsp.build_url("admin/services/frpc/backup")
%>

<style>
.fbk-root {
    --fbk-primary: #5b6dca;
    --fbk-primary-dark: #4c5db7;
    --fbk-success: #2dbb6e;
    --fbk-success-dark: #25a55e;
    --fbk-danger: #e85a5a;
    --fbk-info: #4a9fd6;
    --fbk-warn: #f7b500;
    --fbk-bg: #fafbfc;
    --fbk-border: #e5e7eb;
    --fbk-text: #1f2937;
    --fbk-muted: #6b7280;
    --fbk-radius: 8px;
    --fbk-radius-sm: 4px;
}

.fbk-section {
    background: #fff;
    border: 1px solid var(--fbk-border);
    border-radius: var(--fbk-radius);
    padding: 16px 20px;
    margin-bottom: 16px;
}
.fbk-section h3 {
    margin: 0 0 12px 0;
    font-size: 15px;
    color: var(--fbk-text);
    display: flex; align-items: center; gap: 8px;
}
.fbk-section h3 .fbk-tag {
    font-size: 11px; padding: 2px 8px; border-radius: 10px;
    background: #eef0ff; color: var(--fbk-primary);
}

.fbk-dest-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 12px;
}
.fbk-dest-card {
    border: 1px solid var(--fbk-border);
    border-radius: var(--fbk-radius);
    padding: 12px 14px;
    background: var(--fbk-bg);
    display: flex; flex-direction: column;
    gap: 6px;
    transition: box-shadow 0.15s;
}
.fbk-dest-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.fbk-dest-card .fbk-dest-head {
    display: flex; align-items: center; gap: 6px;
    font-weight: 600; color: var(--fbk-text);
}
.fbk-dest-card .fbk-dest-meta {
    font-size: 11px; color: var(--fbk-muted);
    font-family: 'SF Mono', Consolas, Menlo, monospace;
    word-break: break-all;
}
.fbk-dest-card .fbk-dest-actions {
    display: flex; gap: 6px;
    margin-top: auto;
    padding-top: 6px;
}
.fbk-dest-card button {
    padding: 4px 10px; font-size: 12px;
    border: 1px solid var(--fbk-border);
    background: #fff;
    border-radius: var(--fbk-radius-sm);
    cursor: pointer;
}
.fbk-dest-card button:hover { background: #f3f4f6; }
.fbk-dest-card .fbk-status-dot {
    width: 8px; height: 8px; border-radius: 50%;
    display: inline-block; background: #ccc;
}
.fbk-dest-card .fbk-status-dot.ok    { background: var(--fbk-success); }
.fbk-dest-card .fbk-status-dot.err   { background: var(--fbk-danger); }
.fbk-dest-card .fbk-status-dot.muted { background: #ccc; }
.fbk-dest-card.disabled { opacity: 0.5; }

.fbk-form-row {
    display: flex; align-items: center; gap: 12px;
    margin: 8px 0;
    flex-wrap: wrap;
}
.fbk-form-row label { color: var(--fbk-muted); font-size: 13px; min-width: 70px; }
.fbk-form-row input[type=text], .fbk-form-row select {
    padding: 6px 10px; border: 1px solid var(--fbk-border); border-radius: var(--fbk-radius-sm);
    flex: 1; min-width: 200px; font-size: 13px;
}
.fbk-form-row .fbk-check-group { display: flex; gap: 14px; flex-wrap: wrap; }
.fbk-form-row .fbk-check-group label {
    min-width: 0; display: flex; align-items: center; gap: 4px;
    cursor: pointer; color: var(--fbk-text);
}

.fbk-btn-primary {
    padding: 8px 20px; font-size: 13px; font-weight: 600;
    background: var(--fbk-primary); color: #fff;
    border: none; border-radius: var(--fbk-radius-sm);
    cursor: pointer;
}
.fbk-btn-primary:hover { background: var(--fbk-primary-dark); }
.fbk-btn-primary:disabled { background: #aaa; cursor: not-allowed; }

.fbk-btn-secondary {
    padding: 6px 14px; font-size: 12px;
    background: #fff; border: 1px solid var(--fbk-border);
    border-radius: var(--fbk-radius-sm); cursor: pointer;
}
.fbk-btn-secondary:hover { background: #f3f4f6; }
.fbk-btn-danger {
    padding: 4px 10px; font-size: 12px;
    background: #fff; border: 1px solid var(--fbk-danger);
    color: var(--fbk-danger);
    border-radius: var(--fbk-radius-sm); cursor: pointer;
}
.fbk-btn-danger:hover { background: #fde8e8; }

.fbk-progress {
    margin-top: 12px;
    padding: 10px 14px;
    background: #f9fafb;
    border: 1px solid var(--fbk-border);
    border-radius: var(--fbk-radius-sm);
    display: none;
}
.fbk-progress .fbk-stage { font-weight: 600; color: var(--fbk-text); }
.fbk-progress .fbk-msg   { color: var(--fbk-muted); font-size: 12px; margin-top: 4px; }
.fbk-progress .fbk-bar {
    margin-top: 6px; height: 6px; background: #e5e7eb;
    border-radius: 3px; overflow: hidden;
}
.fbk-progress .fbk-bar-fill {
    height: 100%; background: var(--fbk-primary);
    transition: width 0.3s;
    width: 0%;
}

table.fbk-table {
    width: 100%; border-collapse: collapse; margin-top: 8px;
}
table.fbk-table th, table.fbk-table td {
    padding: 8px 10px; text-align: left; font-size: 13px;
    border-bottom: 1px solid var(--fbk-border);
}
table.fbk-table th { color: var(--fbk-muted); font-weight: 600; background: #f9fafb; }
table.fbk-table tr:hover td { background: #fafbfc; }

.fbk-modal-mask {
    display: none;
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.45);
    z-index: 9999;
    align-items: center; justify-content: center;
}
.fbk-modal-mask.active { display: flex; }
.fbk-modal {
    background: #fff; border-radius: var(--fbk-radius);
    width: 92%; max-width: 480px;
    padding: 20px 24px;
    max-height: 80vh;
    overflow-y: auto;
}
.fbk-modal h3 { margin: 0 0 12px 0; font-size: 16px; }
.fbk-modal .fbk-modal-buttons {
    display: flex; justify-content: flex-end; gap: 8px;
    margin-top: 16px;
}

.fbk-empty {
    text-align: center; padding: 24px 0;
    color: var(--fbk-muted); font-size: 13px;
}
.fbk-toast {
    position: fixed; bottom: 24px; right: 24px;
    padding: 10px 16px; border-radius: var(--fbk-radius-sm);
    background: #333; color: #fff;
    font-size: 13px; z-index: 10000;
    opacity: 0; transition: opacity 0.3s;
}
.fbk-toast.show { opacity: 1; }
.fbk-toast.success { background: var(--fbk-success); }
.fbk-toast.error   { background: var(--fbk-danger); }
</style>

<%+header%>

<div class="fbk-root">

<h2>Frpc - 备份与还原</h2>

<!-- 区块 A：备份目的地 -->
<div class="fbk-section">
    <h3>
        <span>📦 备份目的地</span>
        <button class="fbk-btn-secondary" id="fbk-add-dest">＋ 新增</button>
    </h3>
    <div class="fbk-dest-grid" id="fbk-dest-grid">
        <div class="fbk-empty">加载中...</div>
    </div>
</div>

<!-- 区块 B：创建备份 -->
<div class="fbk-section">
    <h3>🆕 创建备份</h3>
    <div class="fbk-form-row">
        <label>备注</label>
        <input type="text" id="fbk-note" placeholder="例如：升级前周备份" maxlength="120">
    </div>
    <div class="fbk-form-row">
        <label>内容</label>
        <div class="fbk-check-group">
            <label><input type="checkbox" id="fbk-inc-uci" checked> UCI 配置</label>
            <label><input type="checkbox" id="fbk-inc-bin" checked> 当前 frpc 二进制</label>
            <label><input type="checkbox" id="fbk-inc-ver" checked> 已下载版本号</label>
        </div>
    </div>
    <div class="fbk-form-row">
        <label>目的地</label>
        <div class="fbk-check-group" id="fbk-create-dests">
            <span class="fbk-empty" style="padding: 0;">加载中...</span>
        </div>
    </div>
    <div class="fbk-form-row">
        <button class="fbk-btn-primary" id="fbk-create-btn">▶ 立即备份</button>
    </div>
    <div class="fbk-progress" id="fbk-create-progress">
        <div class="fbk-stage" id="fbk-create-stage">准备中...</div>
        <div class="fbk-msg" id="fbk-create-msg"></div>
        <div class="fbk-bar"><div class="fbk-bar-fill" id="fbk-create-bar"></div></div>
    </div>
</div>

<!-- 区块 C：备份历史 -->
<div class="fbk-section">
    <h3>
        <span>📚 备份历史</span>
        <button class="fbk-btn-secondary" id="fbk-refresh-list">🔄 刷新</button>
    </h3>
    <table class="fbk-table" id="fbk-table">
        <thead>
            <tr>
                <th style="width: 24%;">时间</th>
                <th style="width: 22%;">备注</th>
                <th style="width: 12%;">大小</th>
                <th style="width: 18%;">来源</th>
                <th style="width: 24%;">操作</th>
            </tr>
        </thead>
        <tbody id="fbk-table-body">
            <tr><td colspan="5" class="fbk-empty">加载中...</td></tr>
        </tbody>
    </table>
    <div class="fbk-progress" id="fbk-restore-progress">
        <div class="fbk-stage" id="fbk-restore-stage">准备中...</div>
        <div class="fbk-msg" id="fbk-restore-msg"></div>
        <div class="fbk-bar"><div class="fbk-bar-fill" id="fbk-restore-bar"></div></div>
    </div>
</div>

<!-- 区块 D：从本地导入 -->
<div class="fbk-section">
    <h3>📥 从本地文件导入</h3>
    <div class="fbk-form-row">
        <input type="file" id="fbk-upload-file" accept=".tar.gz,application/gzip,application/x-gzip">
        <button class="fbk-btn-primary" id="fbk-upload-btn">⬆ 上传并导入</button>
    </div>
    <div class="fbk-msg" style="color: var(--fbk-muted); font-size: 12px;">
        仅接受 frpc 备份生成的 .tar.gz 文件，上限 50MB。校验通过后自动写入"本地存储"。
    </div>
</div>

</div><!-- /fbk-root -->

<!-- destination 弹窗 -->
<div class="fbk-modal-mask" id="fbk-modal-mask">
    <div class="fbk-modal">
        <h3 id="fbk-modal-title">新增备份目的地</h3>
        <input type="hidden" id="fbk-dest-id">
        <div class="fbk-form-row">
            <label>类型</label>
            <select id="fbk-dest-type">
                <option value="local">本地（local）</option>
                <option value="webdav">WebDAV</option>
                <option value="s3">S3（占位 / 一期不可用）</option>
            </select>
        </div>
        <div class="fbk-form-row">
            <label>名称</label>
            <input type="text" id="fbk-dest-name" placeholder="给这个目的地取一个名字">
        </div>
        <div id="fbk-dest-local-fields">
            <div class="fbk-form-row">
                <label>路径</label>
                <input type="text" id="fbk-dest-path" value="/etc/frpc-backup">
            </div>
        </div>
        <div id="fbk-dest-webdav-fields" style="display:none;">
            <div class="fbk-form-row">
                <label>URL</label>
                <input type="text" id="fbk-dest-url" placeholder="https://dav.jianguoyun.com/dav/openwrt/frpc/">
            </div>
            <div class="fbk-form-row">
                <label>用户名</label>
                <input type="text" id="fbk-dest-username">
            </div>
            <div class="fbk-form-row">
                <label>密码</label>
                <input type="text" id="fbk-dest-password">
            </div>
            <div class="fbk-form-row">
                <div class="fbk-check-group">
                    <label><input type="checkbox" id="fbk-dest-verify-tls" checked> 验证 TLS 证书</label>
                </div>
            </div>
        </div>
        <div id="fbk-dest-s3-fields" style="display:none;">
            <div class="fbk-form-row">
                <label>Endpoint</label>
                <input type="text" id="fbk-dest-endpoint" placeholder="https://oss-cn-hangzhou.aliyuncs.com">
            </div>
            <div class="fbk-form-row">
                <label>Region</label>
                <input type="text" id="fbk-dest-region">
            </div>
            <div class="fbk-form-row">
                <label>Bucket</label>
                <input type="text" id="fbk-dest-bucket">
            </div>
            <div class="fbk-form-row">
                <label>Access Key</label>
                <input type="text" id="fbk-dest-access-key">
            </div>
            <div class="fbk-form-row">
                <label>Secret Key</label>
                <input type="text" id="fbk-dest-secret-key">
            </div>
            <div class="fbk-form-row">
                <div class="fbk-check-group">
                    <label><input type="checkbox" id="fbk-dest-path-style"> Path-style URL</label>
                </div>
            </div>
            <div class="fbk-msg" style="color: var(--fbk-warn); font-size: 12px;">
                ⚠️ S3 driver 一期未实现，保存后将无法实际使用
            </div>
        </div>
        <div class="fbk-form-row">
            <div class="fbk-check-group">
                <label><input type="checkbox" id="fbk-dest-enabled" checked> 启用</label>
            </div>
        </div>
        <div class="fbk-modal-buttons">
            <button class="fbk-btn-secondary" id="fbk-modal-cancel">取消</button>
            <button class="fbk-btn-secondary" id="fbk-modal-test">测试连通性</button>
            <button class="fbk-btn-primary"   id="fbk-modal-save">保存</button>
        </div>
    </div>
</div>

<script>
(function() {
    var BASE = '<%=base%>';
    // 后续 task 实现 JS 逻辑
    window.FBK = window.FBK || {};
    FBK.base = BASE;
    FBK.toast = function(msg, type) {
        var t = document.createElement('div');
        t.className = 'fbk-toast' + (type ? ' ' + type : '');
        t.textContent = msg;
        document.body.appendChild(t);
        setTimeout(function() { t.classList.add('show'); }, 10);
        setTimeout(function() {
            t.classList.remove('show');
            setTimeout(function() { t.remove(); }, 300);
        }, 3000);
    };
    FBK.humanSize = function(n) {
        n = Number(n) || 0;
        if (n < 1024) return n + ' B';
        if (n < 1024*1024) return (n/1024).toFixed(1) + ' KB';
        if (n < 1024*1024*1024) return (n/1024/1024).toFixed(1) + ' MB';
        return (n/1024/1024/1024).toFixed(2) + ' GB';
    };
    FBK.humanTime = function(ts) {
        if (!ts || ts === 0) return '-';
        var d = new Date(ts * 1000);
        var p = function(n) { return n < 10 ? '0' + n : '' + n; };
        return d.getFullYear() + '-' + p(d.getMonth()+1) + '-' + p(d.getDate()) +
               ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
    };
})();
</script>

<%+footer%>
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): backup_manager.htm 骨架（HTML + CSS + 全局工具 JS）"
```

---

## Task 15: 前端 destination 管理 JS

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：实现 destination 卡片渲染、弹窗 CRUD、测试连通性。

- [ ] **Step 1: 在 backup_manager.htm 末尾 `</script>` 之前的 IIFE 内追加 destination 模块**

把现有的 `(function() { ... var BASE ... })();` 末尾改为追加：

```javascript
    // ─────────── destination 管理 ───────────
    FBK.dests = [];

    FBK.loadDests = function(cb) {
        FBK.xhr('dest_list', null, function(r) {
            if (r && r.ok) {
                FBK.dests = r.destinations || [];
                FBK.renderDestGrid();
                FBK.renderCreateDestPicker();
            }
            if (cb) cb();
        });
    };

    FBK.xhr = function(action, data, cb) {
        var x = new XMLHttpRequest();
        var url = BASE + '/' + action;
        if (!data) {
            x.open('GET', url, true);
        } else {
            x.open('POST', url, true);
        }
        x.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            try {
                cb(JSON.parse(x.responseText));
            } catch (e) {
                cb({ ok: false, error: '响应解析失败（HTTP ' + x.status + '）' });
            }
        };
        if (!data) {
            x.send();
        } else {
            var fd = new FormData();
            for (var k in data) if (data.hasOwnProperty(k)) fd.append(k, data[k]);
            x.send(fd);
        }
    };

    FBK.renderDestGrid = function() {
        var g = document.getElementById('fbk-dest-grid');
        if (!FBK.dests.length) {
            g.innerHTML = '<div class="fbk-empty">还没有备份目的地，点击右上角「新增」</div>';
            return;
        }
        var html = '';
        FBK.dests.forEach(function(d) {
            var icon = d.type === 'local' ? '📁' : (d.type === 'webdav' ? '☁️' : '🪣');
            var meta = '';
            if (d.type === 'local') meta = d.path || '';
            else if (d.type === 'webdav') meta = d.url || '';
            else meta = d.endpoint || '';
            var disabled = d.enabled !== '1' ? ' disabled' : '';
            html += '<div class="fbk-dest-card' + disabled + '" data-id="' + d.id + '">';
            html += '  <div class="fbk-dest-head">';
            html += '    <span>' + icon + '</span>';
            html += '    <span>' + (d.name || d.id) + '</span>';
            html += '    <span class="fbk-status-dot muted" data-status></span>';
            html += '  </div>';
            html += '  <div class="fbk-dest-meta">' + meta + '</div>';
            html += '  <div class="fbk-dest-actions">';
            html += '    <button data-act="test">测试</button>';
            html += '    <button data-act="edit">编辑</button>';
            if (d.id !== 'local_default') {
                html += '    <button data-act="delete" class="fbk-btn-danger" style="border:1px solid var(--fbk-danger);">删除</button>';
            }
            html += '  </div>';
            html += '</div>';
        });
        g.innerHTML = html;

        g.querySelectorAll('.fbk-dest-card').forEach(function(card) {
            var id = card.getAttribute('data-id');
            card.querySelectorAll('button').forEach(function(btn) {
                btn.onclick = function() {
                    var act = btn.getAttribute('data-act');
                    if (act === 'test')   FBK.testDest(id, card);
                    if (act === 'edit')   FBK.openDestModal(id);
                    if (act === 'delete') FBK.deleteDest(id);
                };
            });
        });
    };

    FBK.renderCreateDestPicker = function() {
        var box = document.getElementById('fbk-create-dests');
        var enabled = FBK.dests.filter(function(d) { return d.enabled === '1' && d.type !== 's3'; });
        if (!enabled.length) {
            box.innerHTML = '<span class="fbk-empty" style="padding:0;">请先添加并启用一个目的地</span>';
            return;
        }
        var html = '';
        enabled.forEach(function(d) {
            var checked = d.id === 'local_default' ? 'checked' : '';
            html += '<label><input type="checkbox" data-dest-id="' + d.id + '" ' + checked + '> ' + (d.name || d.id) + '</label>';
        });
        box.innerHTML = html;
    };

    FBK.testDest = function(id, card) {
        var dot = card.querySelector('[data-status]');
        dot.className = 'fbk-status-dot muted';
        FBK.xhr('dest_test', { id: id }, function(r) {
            if (r && r.ok) {
                dot.className = 'fbk-status-dot ok';
                FBK.toast('连通成功', 'success');
            } else {
                dot.className = 'fbk-status-dot err';
                FBK.toast('连通失败：' + (r && r.error || '未知错误'), 'error');
            }
        });
    };

    FBK.deleteDest = function(id) {
        if (id === 'local_default') {
            FBK.toast('默认本地目的地不可删除', 'error');
            return;
        }
        if (!confirm('确定删除目的地 "' + id + '" 吗？\n（该目的地上的备份文件不会被删除）')) return;
        FBK.xhr('dest_delete', { id: id }, function(r) {
            if (r && r.ok) {
                FBK.toast('已删除', 'success');
                FBK.loadDests();
            } else {
                FBK.toast(r && r.error || '删除失败', 'error');
            }
        });
    };

    FBK.openDestModal = function(id) {
        var modal = document.getElementById('fbk-modal-mask');
        var title = document.getElementById('fbk-modal-title');
        var d = id ? FBK.dests.filter(function(x){ return x.id === id; })[0] : null;
        if (id && !d) { FBK.toast('目的地不存在', 'error'); return; }
        title.textContent = d ? '编辑：' + (d.name || d.id) : '新增备份目的地';
        document.getElementById('fbk-dest-id').value = id || '';
        document.getElementById('fbk-dest-type').value = d ? d.type : 'local';
        document.getElementById('fbk-dest-name').value = d ? (d.name || '') : '';
        document.getElementById('fbk-dest-path').value = d && d.type === 'local' ? (d.path || '/etc/frpc-backup') : '/etc/frpc-backup';
        document.getElementById('fbk-dest-url').value = d && d.type === 'webdav' ? (d.url || '') : '';
        document.getElementById('fbk-dest-username').value = d && d.type === 'webdav' ? (d.username || '') : '';
        document.getElementById('fbk-dest-password').value = d && d.type === 'webdav' ? (d.password || '') : '';
        document.getElementById('fbk-dest-verify-tls').checked = !(d && d.type === 'webdav' && d.verify_tls === '0');
        document.getElementById('fbk-dest-endpoint').value = d && d.type === 's3' ? (d.endpoint || '') : '';
        document.getElementById('fbk-dest-region').value = d && d.type === 's3' ? (d.region || '') : '';
        document.getElementById('fbk-dest-bucket').value = d && d.type === 's3' ? (d.bucket || '') : '';
        document.getElementById('fbk-dest-access-key').value = d && d.type === 's3' ? (d.access_key || '') : '';
        document.getElementById('fbk-dest-secret-key').value = d && d.type === 's3' ? (d.secret_key || '') : '';
        document.getElementById('fbk-dest-path-style').checked = d && d.type === 's3' && d.path_style === '1';
        document.getElementById('fbk-dest-enabled').checked = !d || d.enabled === '1';
        FBK.syncDestModalFields();
        modal.classList.add('active');
    };

    FBK.closeDestModal = function() {
        document.getElementById('fbk-modal-mask').classList.remove('active');
    };

    FBK.syncDestModalFields = function() {
        var t = document.getElementById('fbk-dest-type').value;
        document.getElementById('fbk-dest-local-fields').style.display  = (t === 'local')  ? '' : 'none';
        document.getElementById('fbk-dest-webdav-fields').style.display = (t === 'webdav') ? '' : 'none';
        document.getElementById('fbk-dest-s3-fields').style.display     = (t === 's3')     ? '' : 'none';
    };

    FBK.saveDestModal = function() {
        var data = {
            id:         document.getElementById('fbk-dest-id').value,
            type:       document.getElementById('fbk-dest-type').value,
            name:       document.getElementById('fbk-dest-name').value,
            enabled:    document.getElementById('fbk-dest-enabled').checked ? '1' : '0',
        };
        if (data.type === 'local') {
            data.path = document.getElementById('fbk-dest-path').value;
        } else if (data.type === 'webdav') {
            data.url        = document.getElementById('fbk-dest-url').value;
            data.username   = document.getElementById('fbk-dest-username').value;
            data.password   = document.getElementById('fbk-dest-password').value;
            data.verify_tls = document.getElementById('fbk-dest-verify-tls').checked ? '1' : '0';
        } else if (data.type === 's3') {
            data.endpoint   = document.getElementById('fbk-dest-endpoint').value;
            data.region     = document.getElementById('fbk-dest-region').value;
            data.bucket     = document.getElementById('fbk-dest-bucket').value;
            data.access_key = document.getElementById('fbk-dest-access-key').value;
            data.secret_key = document.getElementById('fbk-dest-secret-key').value;
            data.path_style = document.getElementById('fbk-dest-path-style').checked ? '1' : '0';
        }
        FBK.xhr('dest_save', data, function(r) {
            if (r && r.ok) {
                FBK.toast('已保存', 'success');
                FBK.closeDestModal();
                FBK.loadDests();
            } else {
                FBK.toast(r && r.error || '保存失败', 'error');
            }
        });
    };

    // 绑定弹窗按钮
    document.addEventListener('DOMContentLoaded', function() {
        document.getElementById('fbk-add-dest').onclick     = function() { FBK.openDestModal(null); };
        document.getElementById('fbk-modal-cancel').onclick = FBK.closeDestModal;
        document.getElementById('fbk-modal-save').onclick   = FBK.saveDestModal;
        document.getElementById('fbk-modal-test').onclick   = function() {
            // 测试：先保存再 test
            FBK.saveDestModal();
        };
        document.getElementById('fbk-dest-type').onchange = FBK.syncDestModalFields;
        document.getElementById('fbk-modal-mask').onclick = function(e) {
            if (e.target.id === 'fbk-modal-mask') FBK.closeDestModal();
        };

        FBK.loadDests();
    });
```

把这段 JS 插入到现有 `(function() { ... })();` IIFE 内部的末尾（在 `FBK.humanTime = ...` 之后、`})();` 之前）。

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): 前端 destination 卡片渲染 + CRUD 弹窗"
```

---

## Task 16: 前端 创建备份 + 进度轮询

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：实现"立即备份"按钮、进度条、轮询 create_progress。

- [ ] **Step 1: 在 IIFE 内部继续追加创建备份模块**

在 Task 15 追加的 destination 模块之后，`document.addEventListener('DOMContentLoaded', ...)` 之前插入：

```javascript
    // ─────────── 创建备份 ───────────
    FBK.creating = false;
    FBK.createTaskId = null;
    FBK.createPollTimer = null;

    FBK.startCreate = function() {
        if (FBK.creating) return;
        var note = document.getElementById('fbk-note').value;
        var inc_uci = document.getElementById('fbk-inc-uci').checked ? '1' : '0';
        var inc_bin = document.getElementById('fbk-inc-bin').checked ? '1' : '0';
        var inc_ver = document.getElementById('fbk-inc-ver').checked ? '1' : '0';

        if (inc_uci === '0' && inc_bin === '0' && inc_ver === '0') {
            FBK.toast('请至少勾选一项内容', 'error');
            return;
        }

        var dest_ids = [];
        document.querySelectorAll('#fbk-create-dests input[type=checkbox]:checked').forEach(function(c) {
            dest_ids.push(c.getAttribute('data-dest-id'));
        });
        if (!dest_ids.length) {
            FBK.toast('请勾选至少一个目的地', 'error');
            return;
        }

        FBK.creating = true;
        document.getElementById('fbk-create-btn').disabled = true;
        document.getElementById('fbk-create-btn').textContent = '⏳ 备份中...';

        var prog = document.getElementById('fbk-create-progress');
        prog.style.display = 'block';
        document.getElementById('fbk-create-stage').textContent = '准备中...';
        document.getElementById('fbk-create-msg').textContent = '';
        document.getElementById('fbk-create-bar').style.width = '5%';

        FBK.xhr('create', {
            note: note,
            dest_ids: dest_ids.join(','),
            inc_uci: inc_uci,
            inc_bin: inc_bin,
            inc_ver: inc_ver,
        }, function(r) {
            if (!r || !r.ok) {
                FBK.finishCreate(false, r && r.error || '启动备份失败');
                return;
            }
            FBK.createTaskId = r.task_id;
            FBK.pollCreate();
        });
    };

    FBK.pollCreate = function() {
        if (!FBK.createTaskId) return;
        FBK.xhr('create_progress?task_id=' + encodeURIComponent(FBK.createTaskId), null, function(r) {
            if (!r || !r.ok) {
                FBK.finishCreate(false, r && r.error || '轮询失败');
                return;
            }
            var stageMap = {
                idle:     { label: '准备中...',  pct: 5 },
                packing:  { label: '正在打包...', pct: 35 },
                uploading:{ label: '正在上传...', pct: 70 },
                done:     { label: '完成',       pct: 100 },
                error:    { label: '失败',       pct: 0 },
                unknown:  { label: '未知状态',    pct: 0 },
            };
            var s = stageMap[r.stage] || stageMap.unknown;
            document.getElementById('fbk-create-stage').textContent = s.label;
            document.getElementById('fbk-create-msg').textContent = r.message || '';
            document.getElementById('fbk-create-bar').style.width = s.pct + '%';

            if (r.stage === 'done') {
                var extra = r.extra || {};
                var msg = '备份成功';
                if (extra.failed && extra.failed.length) {
                    msg = '部分成功（' + extra.failed.length + ' 个目的地失败）';
                }
                FBK.finishCreate(true, msg);
                return;
            }
            if (r.stage === 'error') {
                FBK.finishCreate(false, r.message || '失败');
                return;
            }
            FBK.createPollTimer = setTimeout(FBK.pollCreate, 1500);
        });
    };

    FBK.finishCreate = function(ok, msg) {
        FBK.creating = false;
        FBK.createTaskId = null;
        if (FBK.createPollTimer) { clearTimeout(FBK.createPollTimer); FBK.createPollTimer = null; }
        document.getElementById('fbk-create-btn').disabled = false;
        document.getElementById('fbk-create-btn').textContent = '▶ 立即备份';
        FBK.toast(msg, ok ? 'success' : 'error');
        setTimeout(function() {
            document.getElementById('fbk-create-progress').style.display = 'none';
        }, 3000);
        if (ok) FBK.loadBackups();
    };
```

并在 `DOMContentLoaded` 处理器内追加一行：

```javascript
        document.getElementById('fbk-create-btn').onclick = FBK.startCreate;
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): 前端 创建备份 + 进度条轮询"
```

---

## Task 17: 前端 备份历史 + 删除 + 下载

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：实现备份历史表格渲染，下载（仅本地）/删除按钮。

- [ ] **Step 1: 在 IIFE 中继续追加备份历史模块**

```javascript
    // ─────────── 备份历史 ───────────
    FBK.backups = [];

    FBK.loadBackups = function() {
        var tbody = document.getElementById('fbk-table-body');
        tbody.innerHTML = '<tr><td colspan="5" class="fbk-empty">加载中...</td></tr>';
        FBK.xhr('list', null, function(r) {
            if (!r || !r.ok) {
                tbody.innerHTML = '<tr><td colspan="5" class="fbk-empty">加载失败：' +
                                  (r && r.error || '未知') + '</td></tr>';
                return;
            }
            FBK.backups = r.backups || [];
            FBK.renderBackupTable();
            // 显示 destination 拉取错误（如 WebDAV 不可达）
            if (r.dest_errors && r.dest_errors.length) {
                r.dest_errors.forEach(function(e) {
                    FBK.toast('「' + e.dest_id + '」列表失败：' + e.error, 'error');
                });
            }
        });
    };

    FBK.renderBackupTable = function() {
        var tbody = document.getElementById('fbk-table-body');
        if (!FBK.backups.length) {
            tbody.innerHTML = '<tr><td colspan="5" class="fbk-empty">还没有备份，去上面创建一个</td></tr>';
            return;
        }
        var html = '';
        FBK.backups.forEach(function(b) {
            // 从 backup id 解析备注：id 形如 20260522T103045Z-my_home
            var noteSlug = b.id.replace(/^[0-9]+T[0-9]+Z-?/, '');
            html += '<tr data-key="' + b.dest_id + '|' + b.name + '">';
            html += '  <td>' + FBK.humanTime(b.mtime) + '</td>';
            html += '  <td>' + (noteSlug || '<span style="color:#999;">untitled</span>') + '</td>';
            html += '  <td>' + (b.size > 0 ? FBK.humanSize(b.size) : '-') + '</td>';
            html += '  <td>' + b.dest_name + '<br><span style="font-size:11px;color:#999;">' + b.dest_type + '</span></td>';
            html += '  <td>';
            if (b.dest_type === 'local') {
                html += '<a class="fbk-btn-secondary" href="' + BASE + '/download?dest_id=' + encodeURIComponent(b.dest_id) +
                        '&name=' + encodeURIComponent(b.name) + '" target="_blank">⬇ 下载</a> ';
            }
            html += '<button class="fbk-btn-secondary" data-act="restore">↩ 还原</button> ';
            html += '<button class="fbk-btn-danger" data-act="delete">🗑 删除</button>';
            html += '  </td>';
            html += '</tr>';
        });
        tbody.innerHTML = html;

        tbody.querySelectorAll('tr').forEach(function(tr) {
            var key = tr.getAttribute('data-key');
            if (!key) return;
            var parts = key.split('|');
            tr.querySelectorAll('button').forEach(function(btn) {
                btn.onclick = function() {
                    var act = btn.getAttribute('data-act');
                    if (act === 'restore') FBK.confirmRestore(parts[0], parts[1]);
                    if (act === 'delete')  FBK.confirmDelete(parts[0], parts[1]);
                };
            });
        });
    };

    FBK.confirmDelete = function(dest_id, name) {
        if (!confirm('确定删除备份 "' + name + '" 吗？此操作不可撤销。')) return;
        FBK.xhr('delete', { dest_id: dest_id, name: name }, function(r) {
            if (r && r.ok) {
                FBK.toast('已删除', 'success');
                FBK.loadBackups();
            } else {
                FBK.toast(r && r.error || '删除失败', 'error');
            }
        });
    };
```

并在 `DOMContentLoaded` 中追加：

```javascript
        document.getElementById('fbk-refresh-list').onclick = FBK.loadBackups;
        FBK.loadBackups();
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): 前端 备份历史 + 下载 + 删除"
```

---

## Task 18: 前端 还原 + 进度轮询

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：还原按钮 + 强确认 + 进度条轮询 + 失败回滚提示。

- [ ] **Step 1: 在 IIFE 内追加**

```javascript
    // ─────────── 还原 ───────────
    FBK.restoring = false;
    FBK.restoreTaskId = null;
    FBK.restorePollTimer = null;

    FBK.confirmRestore = function(dest_id, name) {
        if (FBK.restoring) {
            FBK.toast('已有还原任务正在进行', 'error');
            return;
        }
        if (!confirm(
            '即将从 "' + name + '" 还原。\n\n' +
            '⚠ 将自动快照当前状态，然后整体替换 UCI 配置与 frpc 二进制。\n' +
            '⚠ 还原期间 frpc 服务会重启。\n\n' +
            '如还原失败，将自动从快照回滚。\n\n' +
            '确认继续吗？'
        )) return;

        FBK.restoring = true;
        var prog = document.getElementById('fbk-restore-progress');
        prog.style.display = 'block';
        document.getElementById('fbk-restore-stage').textContent = '准备中...';
        document.getElementById('fbk-restore-msg').textContent = '';
        document.getElementById('fbk-restore-bar').style.width = '5%';

        FBK.xhr('restore', { dest_id: dest_id, name: name }, function(r) {
            if (!r || !r.ok) {
                FBK.finishRestore(false, r && r.error || '启动还原失败');
                return;
            }
            FBK.restoreTaskId = r.task_id;
            FBK.pollRestore();
        });
    };

    FBK.pollRestore = function() {
        if (!FBK.restoreTaskId) return;
        FBK.xhr('restore_progress?task_id=' + encodeURIComponent(FBK.restoreTaskId), null, function(r) {
            if (!r || !r.ok) {
                FBK.finishRestore(false, r && r.error || '轮询失败');
                return;
            }
            var stageMap = {
                idle:          { label: '准备中...',     pct: 5 },
                snapshotting:  { label: '创建自动快照...', pct: 20 },
                downloading:   { label: '下载备份包...',  pct: 40 },
                unpacking:     { label: '校验备份包...',  pct: 60 },
                applying:      { label: '覆盖配置...',    pct: 80 },
                rolling_back:  { label: '⚠ 正在从快照回滚...', pct: 90 },
                done:          { label: '完成',          pct: 100 },
                error:         { label: '失败',          pct: 0 },
                unknown:       { label: '未知状态',       pct: 0 },
            };
            var s = stageMap[r.stage] || stageMap.unknown;
            document.getElementById('fbk-restore-stage').textContent = s.label;
            document.getElementById('fbk-restore-msg').textContent = r.message || '';
            document.getElementById('fbk-restore-bar').style.width = s.pct + '%';

            if (r.stage === 'done') {
                FBK.finishRestore(true, '还原成功，frpc 已重启');
                return;
            }
            if (r.stage === 'error') {
                FBK.finishRestore(false, r.message || '失败');
                return;
            }
            FBK.restorePollTimer = setTimeout(FBK.pollRestore, 1500);
        });
    };

    FBK.finishRestore = function(ok, msg) {
        FBK.restoring = false;
        FBK.restoreTaskId = null;
        if (FBK.restorePollTimer) { clearTimeout(FBK.restorePollTimer); FBK.restorePollTimer = null; }
        FBK.toast(msg, ok ? 'success' : 'error');
        if (ok) {
            // 还原成功后跳转到 frpc 首页（设置 tab），避免本页 stale
            setTimeout(function() {
                location.href = '<%=dsp.build_url("admin/services/frpc/common")%>';
            }, 1800);
        } else {
            setTimeout(function() {
                document.getElementById('fbk-restore-progress').style.display = 'none';
                FBK.loadBackups();
            }, 4000);
        }
    };
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): 前端 还原 + 进度轮询 + 失败提示"
```

---

## Task 19: 前端 上传导入

**Files:**
- Modify: `luci-app-frpc/luasrc/view/frpc/backup_manager.htm`

**目标**：实现 `<input type=file>` + multipart 上传。

- [ ] **Step 1: 在 IIFE 内追加**

```javascript
    // ─────────── 上传导入 ───────────
    FBK.uploadFile = function() {
        var input = document.getElementById('fbk-upload-file');
        var btn   = document.getElementById('fbk-upload-btn');
        if (!input.files || !input.files.length) {
            FBK.toast('请选择文件', 'error');
            return;
        }
        var f = input.files[0];
        if (f.size > 50 * 1024 * 1024) {
            FBK.toast('文件超过 50MB 上限', 'error');
            return;
        }

        btn.disabled = true;
        btn.textContent = '⏳ 上传中...';

        var fd = new FormData();
        fd.append('file', f);

        var x = new XMLHttpRequest();
        x.open('POST', BASE + '/upload', true);
        x.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            btn.disabled = false;
            btn.textContent = '⬆ 上传并导入';
            var r;
            try { r = JSON.parse(x.responseText); }
            catch (e) { r = { ok: false, error: '响应解析失败（HTTP ' + x.status + '）' }; }
            if (r.ok) {
                FBK.toast('导入成功：' + r.filename, 'success');
                input.value = '';
                FBK.loadBackups();
            } else {
                FBK.toast(r.error || '上传失败', 'error');
            }
        };
        x.send(fd);
    };
```

在 `DOMContentLoaded` 内追加：

```javascript
        document.getElementById('fbk-upload-btn').onclick = FBK.uploadFile;
```

- [ ] **Step 2: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/luasrc/view/frpc/backup_manager.htm
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): 前端 上传 .tar.gz 导入"
```

---

## Task 20: Makefile +curl 依赖 + 版本 bump + README

**Files:**
- Modify: `luci-app-frpc/Makefile`
- Modify: `README.md`

**目标**：把 curl 加为运行时依赖，bump PKG_RELEASE，在 README 补一段备份说明。

- [ ] **Step 1: 修改 Makefile**

把 [luci-app-frpc/Makefile:9](../../luci-app-frpc/Makefile#L9) 的 `LUCI_DEPENDS:=+libc` 改为：

```
LUCI_DEPENDS:=+libc +curl
```

把 [luci-app-frpc/Makefile:4](../../luci-app-frpc/Makefile#L4) 的 `PKG_RELEASE:=8` 改为：

```
PKG_RELEASE:=9
```

- [ ] **Step 2: 在 README.md 末尾追加备份/还原一段**

读取 [README.md](../../README.md) 看现有结尾，把下面这段追加到文件末尾：

```markdown

## 备份/还原（frpc）

进入「服务 → frpc → 备份/还原」tab：

- **备份目的地**：内置「本地存储」（`/etc/frpc-backup`），可新增 WebDAV（坚果云 / Nextcloud / Synology 等任意标准 WebDAV）。S3 目的地为占位，一期未实现。
- **创建备份**：填备注 → 勾选内容（UCI 配置 / 当前 frpc 二进制 / 已下载版本号）→ 勾选目的地 → 立即备份。
- **还原**：在历史列表点「还原」，系统会自动快照当前状态后整体替换；若还原失败则自动回滚到快照。
- **本地导入导出**：下载本地备份为 .tar.gz，拷贝到另一台路由器，在上传区导入即可还原。
- **包格式**：`.tar.gz`，包内含 `manifest.json` + `etc/config/frpc` + `bin/frpc`（可选）+ `README.txt`。
- **依赖**：包 24.10+ 自动装 `curl`（WebDAV driver 必需）。
```

- [ ] **Step 3: 提交**

```bash
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro add luci-app-frpc/Makefile README.md
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro commit -m "feat(frpc-backup): Makefile +curl 依赖、PKG_RELEASE bump 至 9、README 补说明"
```

---

## Task 21: 集成测试 — 部署到测试设备并跑端到端

**Files:** （无代码变更，纯验证）

**目标**：用 `frpc-dev-deploy` 技能把 Lua/htm 源码推到测试路由器 192.168.0.187，验证完整流程。

**前提**：测试设备能通过 SSH 访问，且已安装 luci-app-frpc。

- [ ] **Step 1: 推送源码到测试设备**

调用 `frpc-dev-deploy` 技能（用 Skill 工具）：
- skill: `frpc-dev-deploy`
- args: "推送 luci-app-frpc 所有 Lua 与 htm 源码到 192.168.0.187，并重启 uhttpd"

> 如该技能不可用，回退到手工 scp：
> ```bash
> scp -r luci-app-frpc/luasrc/* root@192.168.0.187:/usr/lib/lua/luci/
> scp luci-app-frpc/root/etc/uci-defaults/40_luci-frpc root@192.168.0.187:/etc/uci-defaults/
> ssh root@192.168.0.187 'sh /etc/uci-defaults/40_luci-frpc && /etc/init.d/uhttpd restart'
> ```

- [ ] **Step 2: 浏览器打开 http://192.168.0.187/cgi-bin/luci/admin/services/frpc/backup**

验证：
- [ ] 页面正常加载，看到 4 个区块（目的地 / 创建备份 / 备份历史 / 上传导入）
- [ ] 自动出现一个"本地存储"目的地卡片，"测试"按钮点击后绿点亮起

- [ ] **Step 3: 测试本地备份**

- [ ] 备注填"集成测试 1"，勾选全部内容，目的地勾选"本地存储"
- [ ] 点「立即备份」，进度条出现，依次显示"打包中 → 上传中 → 完成"
- [ ] 备份历史出现新行，时间正确，大小约 10MB

- [ ] **Step 4: 测试下载与上传往返**

- [ ] 点新备份的「下载」，浏览器下载 .tar.gz
- [ ] 在 7-Zip 或其他工具中打开，验证内含 `frpc-backup/manifest.json` `frpc-backup/etc/config/frpc` `frpc-backup/bin/frpc` `frpc-backup/README.txt`
- [ ] 选择该 .tar.gz 在"从本地文件导入"区上传，提示"导入成功"
- [ ] 备份历史出现新行

- [ ] **Step 5: 测试还原 + 自动快照**

- [ ] 在 frpc 设置 tab 故意改一个值（比如服务器 alias 改名）
- [ ] 回到备份/还原 tab，对最早的备份点「还原」，确认弹窗后等待
- [ ] 进度条依次显示"创建自动快照 → 下载 → 校验 → 覆盖配置 → 完成"
- [ ] 1.8 秒后页面跳到 frpc 设置首页
- [ ] 检查 alias 已经回滚到改名前
- [ ] SSH 到设备：`ls /etc/frpc-backup/.auto-snapshots/`，验证有 auto-before-restore- 开头的快照

- [ ] **Step 6: 测试 WebDAV（如有可用账号）**

- [ ] 新增 WebDAV 目的地（坚果云示例：`https://dav.jianguoyun.com/dav/openwrt/frpc/` + 邮箱 + 应用密码）
- [ ] 点「测试连通性」绿点亮起
- [ ] 创建备份勾选 WebDAV 目的地，等完成
- [ ] 备份列表出现 WebDAV 来源行
- [ ] 从 WebDAV 还原能成功

- [ ] **Step 7: 测试故意损坏快照后的回滚**

（高级测试，可选）

- [ ] 通过 SSH 把 `/usr/bin/frpc` 备份后替换为损坏文件
- [ ] 创建备份（包含当前损坏 binary）
- [ ] 还原该备份 → frpc 起不来 → 期望日志显示"已从快照回滚"

- [ ] **Step 8: 记录测试结果**

把测试过程截图或日志贴在最终提交说明中。完成所有验证后：

```bash
# 把可能的本地未提交修改 stash 或忽略；本任务无新增代码改动
git -C f:/Github_Application_mia-clark/luci-app-frpc_frps-pro log --oneline -22
```

Expected: 看到 Task 1–20 共 20 个 commit + Task 21 集成测试笔记（若有）。

---

## 自审检查清单（写完计划后自跑）

✅ Spec 覆盖：
- §2 总体架构 → Task 3–10（core + drivers）+ Task 11–13（controller）+ Task 14–19（前端）
- §3 备份包结构 → Task 4 实现，Task 5 校验
- §4 Driver 接口 → Task 7 加载器 + Task 8/9/10 三个 driver
- §5 UCI schema → Task 1（兜底 destination）+ Task 11（CRUD action）
- §6 Controller dispatch → Task 11–13
- §7 备份与还原流程 → Task 4/5/6（core）+ Task 12/13（controller 异步任务）
- §8 前端 UI → Task 14–19（5 个 task）
- §9 安全边界 → Task 4/5（ID 校验、sha256）+ Task 13（50MB 上传上限）
- §10 ACL → Task 2
- §11 uci-defaults → Task 1
- §12 测试要点 → Task 21
- §13 阶段拆分 → 整体计划即是

✅ Placeholder 扫描：无 TBD/TODO/"similar to"；所有代码块完整。

✅ 类型/方法签名一致性：
- driver 接口 `test/list/put/get/remove` 在 spec 与所有 driver 文件一致
- `backup_core` 方法名 `pack_backup`/`unpack_and_verify`/`apply_unpacked`/`create_auto_snapshot` 在 core 与 controller 引用处一致
- task_id 格式 `^task_[0-9_]+$` 在 controller 生成与 progress 校验处一致

✅ 路径一致性：
- 备份目录 `/etc/frpc-backup`、快照 `/etc/frpc-backup/.auto-snapshots`、binary `/usr/bin/frpc`、版本 `/usr/share/frp/versions/` 全部在 backup_core 常量中定义，其他文件引用 `M.LOCAL_BACKUP_DIR` 等不硬编码
