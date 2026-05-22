# luci-app-frpc 备份/还原功能设计

- 文档日期：2026-05-22
- 范围：仅 `luci-app-frpc`（一期）；`luci-app-frps` 二期镜像复制
- 目标包：LuCI Lua app + 前端 .htm 重交互页

---

## 1. 目标与非目标

### 1.1 目标

1. 在 frpc 顶部 tab 增加「备份/还原」入口，与现有「设置 / 代理规则 / FRPS 服务器 / 查看 TOML / 查看日志」并列。
2. 一键备份当前 frpc 完整状态（UCI 配置 + 当前激活二进制 + 已下载版本号 metadata）到三种目的地：
   - 本地 `/etc/frpc-backup/`
   - WebDAV（任意标准 WebDAV 服务器；坚果云、Nextcloud、Synology 等）
   - S3（**一期仅预留 driver 接口空壳，不实现**，二期完成）
3. 备份可填备注，可选包含内容（UCI / 当前二进制 / 版本 metadata 三项可勾选）。
4. 备份历史合并展示（不区分本地/云），按时间倒序，每条可下载（仅本地）/还原/删除。
5. 一键整体还原：还原前**自动快照当前状态**，还原失败**自动回滚**。
6. 支持下载备份为 `.tar.gz` → 拷贝到另一台路由器 → 上传导入 → 还原。

### 1.2 非目标（一期不做）

- ❌ 定时备份 / cron 调度 / 保留策略
- ❌ S3 driver 的真实实现（仅留接口空壳）
- ❌ 项粒度 diff 预览 / 部分还原
- ❌ 备份加密（路由器无可靠密钥管理；用户用 WebDAV 自己的 https/认证）
- ❌ 备份内含所有历史 frpc 二进制（每个 5–15MB，体量爆炸；改为只备份当前激活版本，其余版本号靠 metadata + 还原时重新下载）
- ❌ luci-app-frps 的备份（二期）

### 1.3 决策记录（已与用户对齐）

| 决策点 | 选择 | 理由 |
|---|---|---|
| 二进制范围 | 只含当前激活的 frpc 二进制 | 平衡包体（~10MB）与还原依赖网络的可用性 |
| 协议范围 | 本地 + WebDAV（一期），S3 留接口 | WebDAV 纯 HTTP 易实现；S3 需手写 Sig V4，工作量×2 |
| 还原冲突 | 整体替换 + 自动快照 | 语义简单可预测；失败可回滚 |
| 触发方式 | 仅手动 | 一期闭环，定时为二期特性 |
| 包格式 | tar.gz | busybox 自带 tar/gzip，零依赖 |

---

## 2. 总体架构

```
┌─────────────────────────────────────────────────────────┐
│  LuCI tab： 设置｜规则｜FRPS｜TOML｜日志｜【备份/还原】← 新增   │
└─────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────┐
│  controller/frpc.lua  ← 仅 dispatch + 薄包装             │
└─────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌────────────────┐   ┌────────────────┐   ┌────────────────┐
│ backup_core    │   │ driver_local   │   │ driver_webdav  │
│ ─────────────  │   │ ─────────────  │   │ ─────────────  │
│ pack/unpack    │   │ list/put/get/  │   │ list/put/get/  │
│ snapshot/      │   │ remove/test    │   │ remove/test    │
│ restore/manifest│   │  (fs ops)      │   │  (curl/wget)   │
└────────────────┘   └────────────────┘   └────────────────┘
                              │
                              ▼
                  ┌────────────────────┐
                  │ driver_s3.lua      │ ← 一期空壳，方法签名齐全
                  │ (stub interface)   │   返回"未实现"错误
                  └────────────────────┘
```

### 2.1 文件清单

```
luci-app-frpc/luasrc/
├── controller/
│   └── frpc.lua                       ← 现有，加约 120 行 dispatch
├── model/cbi/frpc/
│   └── (无变动；新 tab 直接用 .htm)
├── view/frpc/
│   └── backup_manager.htm              ← 新增主交互页（参考 program_manager.htm 风格）
└── frpc/                              ← 新建子目录（自动映射为 luci.frpc.*）
    ├── backup_core.lua                 ← 核心逻辑
    ├── driver_local.lua                ← 本地文件系统驱动
    ├── driver_webdav.lua               ← WebDAV 驱动
    └── driver_s3.lua                   ← S3 空壳驱动
```

> 路径映射：LuCI Makefile 默认把 `luasrc/` 整目录装到 `/usr/lib/lua/luci/`。故 `luasrc/frpc/backup_core.lua` 安装后为 `/usr/lib/lua/luci/frpc/backup_core.lua`，可用 `require "luci.frpc.backup_core"` 加载。
>
> 运行时依赖：Makefile 必须加 `+curl`（busybox wget 不支持 PUT/PROPFIND/DELETE，WebDAV driver 强依赖 curl）。本地 driver 与备份打包用 busybox tar/gzip 即可，无新依赖。

### 2.2 设计原则

- **`backup_core` 不知道数据去哪儿**：只负责打包/解包/快照/manifest 校验，返回本地 tar.gz 路径或接收本地 tar.gz 路径
- **`driver_*` 不知道包里是什么**：只实现 `list / put / get / remove / test` 五个方法，操作的是黑盒文件
- **新增协议 = 加一个 driver 文件**：core 与 controller 不动
- **单文件 ≤ 400 行**：controller 现有 ~850 行已经太厚，新逻辑必须外置

---

## 3. 备份包结构

### 3.1 文件布局

```
frpc-backup-20260522T103045Z-my_home.tar.gz
└── frpc-backup/
    ├── manifest.json                 ← 元数据 + checksums，必有
    ├── etc/
    │   └── config/
    │       └── frpc                  ← UCI 整文件原样，若 includes.uci=true
    ├── bin/
    │   └── frpc                      ← 当前激活二进制，若 includes.current_binary=true
    └── README.txt                    ← 给用户看的人类可读说明
```

### 3.2 manifest.json schema

```json
{
  "schema_version": 1,
  "pkg": "frpc",
  "created_at": "2026-05-22T10:30:45Z",
  "created_at_local": "2026-05-22 18:30:45 +0800",
  "note": "家里 OpenWrt 周期备份",
  "hostname": "openwrt-home",
  "frpc_active_version": "0.68.1",
  "downloaded_versions": ["0.68.1", "0.65.0", "0.62.1"],
  "download_mirror": "https://gh-proxy.com/",
  "includes": {
    "uci": true,
    "current_binary": true,
    "version_metadata": true
  },
  "files": {
    "etc/config/frpc": {
      "size": 2345,
      "sha256": "abc123..."
    },
    "bin/frpc": {
      "size": 11534336,
      "sha256": "def456..."
    }
  },
  "platform": {
    "arch_raw": "aarch64",
    "frp_platform": "linux_arm64"
  }
}
```

### 3.3 备份文件命名

格式：`frpc-backup-<ISO8601 紧凑 UTC>-<note slug>.tar.gz`

- 时间戳：`20260522T103045Z`
- note slug：从用户 note 提取，仅保留 `[a-zA-Z0-9_-]`，其余转 `_`，长度截到 30 字符；空 note → `untitled`
- 例：`frpc-backup-20260522T103045Z-my_home.tar.gz`

ID（用于 URL / API 引用）：去掉前缀和后缀，即 `20260522T103045Z-my_home`。ID 必须匹配 `^[a-zA-Z0-9._-]+$`，否则一律 400。

---

## 4. Driver 接口契约

每个 driver 是一个 Lua module，返回一个 factory 函数：

```lua
-- lib/luci/frpc/driver_<name>.lua
local M = {}

-- 构造：从 UCI destination section 配置创建 driver 实例
-- cfg: { type, name, ... 协议特定字段 }
function M.new(cfg)
    -- 返回 driver 实例 table
end

return M
```

driver 实例方法：

| 方法 | 入参 | 返回 |
|---|---|---|
| `:test()` | – | `ok, err` |
| `:list()` | – | `entries[], err` — entries 元素 `{ id, name, size, mtime, raw_path }` |
| `:put(local_path, remote_name, progress_cb)` | – | `ok, err` |
| `:get(remote_name, local_path, progress_cb)` | – | `ok, err` |
| `:remove(remote_name)` | – | `ok, err` |

`progress_cb(bytes_done, bytes_total)`：driver 视情况调用；不可调用也合法（进度回退为"不确定"）。

### 4.1 driver_local

- 配置：`{ path = "/etc/frpc-backup" }`
- `list`：`fs.dir(path)`，过滤前缀 `frpc-backup-`、后缀 `.tar.gz`
- `put`：`cp -f` 或直接 `fs.writefile`
- `get`：`cp -f` 反向
- `remove`：`fs.remove`
- `test`：检查目录存在且可写（`fs.access(path, "w")`）

### 4.2 driver_webdav

- 配置：`{ url, username, password, verify_tls }`（url 末尾必须 `/`）
- 实现：`curl -k -u user:pass`（busybox wget 不支持 PUT/PROPFIND/DELETE，必须用 curl；OpenWrt 标准镜像默认带 curl）
- `list`：`PROPFIND` + 解析 XML（用简单正则 `<d:href>([^<]+)</d:href>` 抓 href，过滤后缀 `.tar.gz`；不引入 XML 库）
- `put`：`PUT` 二进制
- `get`：`GET` 二进制
- `remove`：`DELETE`
- `test`：`PROPFIND Depth: 0` 到 url 根
- 进度：`curl --progress-bar 2>&1 | tee` 解析，或先用文件大小估算

### 4.3 driver_s3（一期空壳）

- 所有方法返回 `nil, "S3 driver not implemented yet (planned for v2)"`
- 配置 schema 占位：`{ endpoint, region, bucket, access_key, secret_key, path_style }`
- UCI destination 中允许创建 `type = 's3'` 的项，但保存时前端给灰色"未启用"提示

### 4.4 driver 注册

```lua
-- backup_core.lua
local DRIVERS = {
    ["local"] = "luci.frpc.driver_local",
    webdav    = "luci.frpc.driver_webdav",
    s3        = "luci.frpc.driver_s3",
}

local function load_driver(cfg)
    local mod_path = DRIVERS[cfg.type]
    if not mod_path then return nil, "unknown driver: " .. tostring(cfg.type) end
    local ok, mod = pcall(require, mod_path)
    if not ok then return nil, mod end
    return mod.new(cfg)
end
```

---

## 5. UCI schema 扩展

在 `/etc/config/frpc` 新增 `destination` section 类型：

```
config destination 'local_default'
    option type 'local'
    option name '本地存储'
    option path '/etc/frpc-backup'
    option enabled '1'

config destination 'webdav_jianguoyun'
    option type 'webdav'
    option name '坚果云'
    option url 'https://dav.jianguoyun.com/dav/openwrt/frpc/'
    option username 'me@example.com'
    option password 'app_password_here'
    option verify_tls '1'
    option enabled '1'

config destination 's3_aliyun'
    option type 's3'
    option name '阿里云 OSS（占位）'
    option endpoint 'https://oss-cn-hangzhou.aliyuncs.com'
    option region 'cn-hangzhou'
    option bucket 'my-frpc-backup'
    option access_key '...'
    option secret_key '...'
    option enabled '0'
```

- ACL 已有 `uci:frpc` 读写，无需变更
- 安装时通过 `uci-defaults/40_luci-frpc` 兜底创建 `local_default` destination

---

## 6. Controller dispatch

新增路由（在 `controller/frpc.lua` `index()` 函数中追加）：

```
entry({"admin","services","frpc","backup"}, call("view_backup"), _("备份/还原"), 6).leaf = true

-- 备份点（destination）CRUD
entry({"admin","services","frpc","backup","dest_list"},   call("backup_dest_list"))
entry({"admin","services","frpc","backup","dest_save"},   call("backup_dest_save"))
entry({"admin","services","frpc","backup","dest_delete"}, call("backup_dest_delete"))
entry({"admin","services","frpc","backup","dest_test"},   call("backup_dest_test"))

-- 备份操作
entry({"admin","services","frpc","backup","list"},        call("backup_list"))           -- 跨所有 dest 聚合
entry({"admin","services","frpc","backup","create"},      call("backup_create"))
entry({"admin","services","frpc","backup","create_progress"}, call("backup_create_progress"))
entry({"admin","services","frpc","backup","download"},    call("backup_download")).leaf = true
entry({"admin","services","frpc","backup","upload"},      call("backup_upload"))         -- 浏览器上传 tar.gz
entry({"admin","services","frpc","backup","delete"},      call("backup_delete"))

-- 还原操作
entry({"admin","services","frpc","backup","restore"},     call("backup_restore"))
entry({"admin","services","frpc","backup","restore_progress"}, call("backup_restore_progress"))
```

每个 action 函数都是薄包装，约 5–15 行：参数校验 → 调 `backup_core.*` → JSON 返回。

### 6.1 异步任务范式

沿用现有 `program_download` 的范式：

- 状态文件：`/tmp/frpc_backup_<op>_<id>.json`（op = "create" | "restore"，id = backup ID）
- 启动：`setsid sh -c '(script </dev/null >/dev/null 2>&1; rm -f script) &'`
- 阶段（写在 status.stage 字段）：
  - create: `packing → uploading → done | error`
  - restore: `snapshotting → downloading → unpacking → applying → starting | rolling_back → done | error`
- 完成后状态文件保留 30s 供前端拿最终状态，再自删

---

## 7. 备份与还原流程

### 7.1 备份流程（`backup_core.create_backup`）

```
输入：dest_ids[], note, includes = { uci, current_binary, version_metadata }

1. 校验 dest_ids 全部存在且 enabled
2. 生成 backup_id = "<UTC紧凑>-<note slug>"
3. 创建 /tmp/frpc_backup_build_<id>/  工作目录
4. 写 manifest.json 骨架
5. 若 includes.uci:
   - cp /etc/config/frpc → workdir/etc/config/frpc
   - 计算 sha256，写入 manifest.files
6. 若 includes.current_binary:
   - cp /usr/bin/frpc → workdir/bin/frpc
   - 计算 sha256 + size，写入 manifest.files
7. 若 includes.version_metadata:
   - 扫描 /usr/share/frp/versions/ 列目录
   - 写入 manifest.downloaded_versions
8. 写 README.txt（人类可读的恢复说明）
9. tar -czf /tmp/<filename>.tar.gz -C workdir .
10. 对每个 dest_id：
    - 加载 driver
    - driver:put(tar_path, filename, progress_cb)
    - 失败不中断，记录到 failed[]
11. 删除工作目录与 tmp tar
12. 写 status.stage = "done", failed = failed[]
```

### 7.2 还原流程（`backup_core.restore_backup`）

```
输入：dest_id, backup_name

1. 校验 dest 存在
2. 阶段 "snapshotting"：
   - 调用 create_backup({local_default}, note="auto-before-restore-<时间>",
                       includes={uci=true, current_binary=true, version_metadata=true})
   - 写入 /etc/frpc-backup/.auto-snapshots/
   - 滚动保留最近 10 份
3. 阶段 "downloading"：
   - driver:get(backup_name, /tmp/frpc_restore_<id>.tar.gz, progress_cb)
4. 阶段 "unpacking"：
   - mkdir /tmp/frpc_restore_<id>_unpack
   - tar -xzf /tmp/frpc_restore_<id>.tar.gz -C unpack
   - 读 manifest.json
   - 校验 sha256（任一不匹配 → 中止 + 报错）
5. 阶段 "applying"：
   - /etc/init.d/frpc stop
   - cp unpack/frpc-backup/etc/config/frpc → /etc/config/frpc  (若 includes.uci)
   - cp unpack/frpc-backup/bin/frpc → /usr/bin/frpc            (若 includes.current_binary)
     用 cp→.new + mv 原子替换（避免 ETXTBSY）
   - uci reload_config  (LuCI 进程感知配置变化)
6. 阶段 "starting"：
   - /etc/init.d/frpc start
   - 等 2 秒，pgrep -f /usr/bin/frpc 检测
   - 失败 → 阶段切 "rolling_back"，从快照重新走一遍 applying+starting
7. 清理 tmp
8. 写 status.stage = "done"
```

### 7.3 上传导入流程

- 前端 `<input type="file">` + `FormData` POST 到 `backup/upload`
- 后端接收 multipart：`luci.http.setfilehandler` 流式写入 `/tmp/frpc_upload_<rand>.tar.gz`
- 文件大小上限：50MB（避免恶意上传）
- 完成后：
  1. 解压到临时目录读 manifest.json，校验 schema_version、pkg=="frpc"
  2. 校验通过 → 移到 `/etc/frpc-backup/<原文件名>`
  3. 校验失败 → 删除 tmp 并报错

---

## 8. 前端 UI（backup_manager.htm）

参考现有 [program_manager.htm](luci-app-frpc/luasrc/view/frpc/program_manager.htm) 的视觉风格（紫色主题、卡片+表格、AJAX 轮询）。

### 8.1 页面布局

```
┌──────────────────────────────────────────────────────┐
│ Frpc - 备份与还原                                       │
├──────────────────────────────────────────────────────┤
│ 【备份目的地】                                          │
│ ┌─────────────────────┐ ┌─────────────────────┐  [+ 新增] │
│ │ 📁 本地存储          │ │ ☁️  坚果云 (WebDAV) │           │
│ │ /etc/frpc-backup    │ │ dav.jianguoyun.com  │           │
│ │ [测试] [编辑]        │ │ [测试] [编辑] [删除] │           │
│ └─────────────────────┘ └─────────────────────┘            │
├──────────────────────────────────────────────────────┤
│ 【创建备份】                                            │
│ 备注：[________________________________]              │
│ 内容：☑ UCI 配置  ☑ 当前 frpc 二进制  ☑ 已下载版本号    │
│ 目的地：☑ 本地存储  ☑ 坚果云                            │
│ [立即备份 →]                                            │
│ (进度条：打包中 32% [████░░░░])                          │
├──────────────────────────────────────────────────────┤
│ 【备份历史】                                            │
│ ┌──────────────────┬───────┬────────┬────────┬───────┐ │
│ │ 时间             │ 备注  │ 大小   │ 来源   │ 操作  │ │
│ ├──────────────────┼───────┼────────┼────────┼───────┤ │
│ │ 2026-05-22 18:30 │ 家里  │ 10.2MB │ 本地   │ ⬇️ ↩️ 🗑 │ │
│ │ 2026-05-22 18:30 │ 家里  │ 10.2MB │ 坚果云 │   ↩️ 🗑 │ │
│ │ 2026-05-21 09:00 │ 备份2 │ 10.1MB │ 本地   │ ⬇️ ↩️ 🗑 │ │
│ └──────────────────┴───────┴────────┴────────┴───────┘ │
├──────────────────────────────────────────────────────┤
│ 【从本地文件导入】                                       │
│ [选择 .tar.gz 文件] [上传并导入]                         │
└──────────────────────────────────────────────────────┘
```

### 8.2 关键交互

- **新增/编辑 destination**：弹窗，字段随 type 切换；保存前自动调一次 test
- **立即备份**：点击后按钮变 disabled，下方显示进度条，3 秒轮询一次 `create_progress`
- **还原**：点击 ↩️ 后弹强确认（"将自动快照当前状态再覆盖，确定？"），轮询 `restore_progress`，结束自动跳回 frpc 设置首页（已重启）
- **下载**：仅本地 destination 显示 ⬇️，链接到 `backup/download?id=xxx`
- **导入**：上传后入"备份历史"的"本地"行，用户再点 ↩️ 就还原

---

## 9. 安全与边界

### 9.1 输入校验

- 备份 ID / dest_id：`^[a-zA-Z0-9._-]+$`，否则 400
- 上传文件名：忽略客户端 filename，后端自己生成
- 上传大小：50MB 硬限
- WebDAV url：必须 `^https?://`
- 路径穿越：所有 `cp` 操作前 `realpath` 校验在白名单目录下

### 9.2 服务可用性

- 还原失败 → 自动从快照回滚，全过程 logger 记录到 syslog
- 还原期间显示"frpc 服务暂停中"提示，禁用其他 tab 的服务操作按钮（仅前端禁用，后端不强制）
- 自动快照空间不足 → 删最老的快照腾位置后重试

### 9.3 凭据

- WebDAV 密码：UCI 明文（行业惯例：openclash / passwall / aria2 等都如此），`/etc/config/frpc` 默认 0644 仅 root 可读
- 备份包不额外脱敏：UCI 中的 `admin_password`、`auth_token` 等会随包出去——这是用户预期（备份就是要能完整还原）

### 9.4 异常处理

- driver:test 失败 → 不阻止保存 destination（用户可能先填配置再去开通），但 UI 标红
- 备份过程任何一个 dest 失败：不中断其他 dest，最终 status 报哪个失败
- tar 解压失败 / sha256 不匹配 → 中止还原，不动 `/etc/config/frpc`

---

## 10. ACL 扩展

`root/usr/share/rpcd/acl.d/luci-app-frpc.json`：

```json
{
  "luci-app-frpc": {
    "description": "Grant UCI access for luci-app-frpc",
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

> 实际上现有 controller 也直接通过 `sys.call` 操作 `/usr/bin/frpc`（program_switch），ACL 未限制——这是 LuCI Lua-API 通病。此 ACL 改动主要为前端通过 ubus 直接访问文件预留；后端 sys.call 不受 ACL 约束。

---

## 11. uci-defaults 安装钩子

`root/etc/uci-defaults/40_luci-frpc` 追加：

```sh
# 备份/还原：兜底创建本地默认 destination
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

---

## 12. 测试要点（实施阶段需覆盖）

| 场景 | 期望 |
|---|---|
| 全勾选项备份到本地 | 10MB 级 tar.gz，manifest 完整 |
| 仅 UCI 备份 | <100KB tar.gz，无 bin/frpc 项 |
| 备份到 WebDAV（坚果云模拟） | 上传成功，列表能看到 |
| WebDAV 密码错 | test 报 401，但 destination 允许保存 |
| 还原本地备份 | frpc 服务重启后跑起来，UCI 内容一致 |
| 还原前自动快照 | `.auto-snapshots/` 目录多一个 |
| 还原过程中故意把 binary 改坏 | 自动回滚成功，frpc 继续跑 |
| 上传 .tar.gz 导入 | 出现在本地列表 |
| 上传非 frpc 备份（manifest.pkg 错） | 拒绝，报错 |
| 上传超过 50MB 文件 | 拒绝 |
| 跨架构还原（aarch64 备份还原到 x86_64） | manifest.platform 不匹配 → 警告但允许（用户可勾选不还原 binary） |

---

## 13. 阶段拆分（送入 writing-plans）

- **Phase 1**：UCI schema + ACL + uci-defaults + 目录骨架（无功能，仅占位）
- **Phase 2**：`backup_core.lua` 打包 / 解包 / manifest / sha256
- **Phase 3**：`driver_local.lua` + 本地备份/还原闭环（不含 UI）
- **Phase 4**：Controller dispatch + JSON action + 异步状态文件范式
- **Phase 5**：前端 `backup_manager.htm` UI（destination 管理 + 创建 + 历史 + 还原）
- **Phase 6**：`driver_webdav.lua` + 前端 destination 弹窗 WebDAV 字段
- **Phase 7**：本地文件 upload 导入 + download 导出
- **Phase 8**：自动快照 + 失败回滚
- **Phase 9**：`driver_s3.lua` 空壳 + 集成测试 + 文档
