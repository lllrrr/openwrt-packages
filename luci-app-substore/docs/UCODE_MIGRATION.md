# 后端迁移评估：Lua → ucode

> **状态**：评估已修订（2026-11-28），**未执行迁移**。结论：**当前无必要迁移**。
>
> 初版评估（阶段 4）把「ucode 可以通过 `include()` 复用 Lua 核心库」当作前提，
> 并据此认为迁移成本集中在 5 个模板的胶水代码。该前提不成立：ucode 的
> `include()` / `loadfile()` / `loadstring()` 只编译 ucode 源码，不能加载 Lua。
> 本文按核实结果重写，同时修正模板清单与 25.12 兼容性判断。

## 1. 背景

本项目后端由四层组成（不含前端 `nodeform.js`）：

| 层 | 位置 | 行数 |
|----|------|------|
| 核心库 | `root/usr/share/substore/*.lua`（18 个模块） | 8,710 |
| 控制器 | `root/usr/lib/lua/luci/controller/admin/substore.lua` | 612 |
| LuCI 模板 | `root/usr/lib/lua/luci/view/substore/*.htm`（7 个） | 1,146 |
| cron | `root/usr/bin/substore-cron.sh`（内嵌 Lua 片段） | 82 |

当前 LuCI 版本面（依据 LuCI 仓库 `modules/luci-base/Makefile` 与各分支目录实查）：

| LuCI 版本 | 服务端实现 | 本项目的 `.htm` |
|-----------|-----------|------------------|
| 22.03 及更早 | Lua | ✅ 原生 |
| 23.05 | ucode dispatcher + `luci-lua-runtime` 兼容层 | ✅ 经兼容层 |
| 24.10 / 25.12 / master | 同上 | ✅ 经兼容层 |

`openwrt-23.05` 的 `luci-base` 依赖已经是 `ucode`、`ucode-mod-fs`、`ucode-mod-uci`、
`ucode-mod-ubus`、`ucode-mod-math`、`liblucihttp-ucode`，并通过 uci-defaults 把
`/cgi-bin/luci` 指向 `/usr/share/ucode/luci/uhttpd.uc`。Lua 由 `luci-lua-runtime`
兼容层提供，所以 `.htm` 与 `module()` + `entry()` 控制器在 23.05+ 仍然可用。

## 2. 已核实的事实

### 2.1 ucode 不能加载或调用 Lua 代码

ucode 官方文档（`https://ucode-lang.org/ucode/module-core.html`）明确：

- `include(path)`、`loadfile(path)`、`loadstring(code)` 都只**编译 ucode 源码**；
  它们不是通用脚本加载器，传入 `.lua` 文件只会得到语法错误。
- 官方模块清单（core / fs / io / log / math / netaddr / resolv / socket / struct /
  ubus / uci / uloop / zlib …）中没有任何专门的 Lua 互操作模块（`ffi` 只能手工
  `dlopen`，见下）。

由此可得三条硬结论：

1. **不存在「只迁模板、核心库复用」的低成本路径**——核心库 8,710 行必须重写。
2. **不存在「核心用 ucode、控制器留 Lua」的中间态**——两个运行时无法互相
   `require`；要迁就是整层一起迁。
3. 用 `ucode-mod-ffi` 调 `liblua` 理论上可行，但依赖设备上存在 `liblua` 动态库，
   胶水成本高于重写，不作为路线。

### 2.2 上游没有移除 Lua 兼容层的计划（截至 2026-11-28）

实查 LuCI 仓库：`openwrt-23.05`、`openwrt-25.12`、`master` 三个分支的 `modules/`
下都仍然包含 `luci-lua-runtime`。本项目的 CI 也已经在 24.10.8 与 25.12.5 两个 SDK
上构建出包（`.github/workflows/build.yml`）。

因此初版评估里「25.12 可能移除 Lua 运行时」**没有依据**，不构成迁移理由。
若未来上游真的移除该兼容层，`.htm` 与 Lua 控制器才会被迫迁移。

### 2.3 ucode 的能力足以承载本后端

| 需求 | 现状（Lua） | ucode 对应 |
|------|------------|-----------|
| JSON | `util.lua` 自写编解码 | 原生 `json()` + `sprintf("%J")`，且原生区分 int/double、对象/数组 |
| Base64 / hex | `util.lua` 自写 | `b64enc` / `b64dec` / `hexenc` / `hexdec` |
| 正则与捕获 | Lua patterns | `match()` 返回 `[整段, 捕获…]`，`replace()` / `split()` 接受正则 |
| 文件 | `io.open` / `os.rename` / `os.remove` | `fs` 模块（open / readfile / writefile / rename / chmod / mkdir / stat / popen） |
| 外部命令 | `io.popen` / `os.execute` | `popen()` / `system()` |
| DNS（SSRF 检查） | `nixio` / `nslookup` | `socket.addrinfo` / `resolv.query` |
| 控制器 / 模板 | `module()` + `entry()`，`.htm` | `.uc` 控制器、`.ut` 模板（23.05+ LuCI 自带） |

**「能不能迁」的答案是能**；问题在成本与回归风险，不在能力缺失。

### 2.4 模板清单（修正初版）

初版列了 5 个模板，其中 `settings.htm` **并不存在**，且漏了三个。实际为 7 个：

- `subscriptions.htm` — 订阅列表
- `form.htm` — 添加/编辑订阅
- `local_form.htm` — 本地订阅
- `nodes.htm` — 节点查看（筛选/排序/探测）
- `node_edit.htm` — 单节点编辑
- `output.htm` — 输出页
- `combo.htm` — 组合订阅

## 3. 迁移的真实成本

### 3.1 工作量

迁移不是「翻译」，而是逐模块重写，且测试要同步重写：

| 部分 | 行数 | 迁移性质 |
|------|------|---------|
| 核心库 | 8,710 | 重写（util / http / parser 及 4 个 parser_* / node / output×8 / probe / msg / core） |
| 控制器 | 612 | `.uc` 重写 |
| 模板 | 1,146 | `.ut` 重写 |
| cron | 82 | `lua -e` → `ucode -e` |
| 测试 | 12,377 | 59 个 Lua 测试 + 1 个 shell 测试全部重写或放弃 |

合计约 **2.3 万行**。粗估（核心库 + 测试的重写与回归）约 30–50 人日，
控制器/模板另加 5–8 人日，且需要真机逐页验证。

### 3.2 语义硬点（按风险排序）

1. **Lua 模式匹配**：核心库内 `match` 149 处（已扣除 `gmatch`）、`gsub` 67、
   `gmatch` 48、`find` 93；257 处 `%a/%d/%s/%w/%x` 字符（含大写否定类，其中混有
   `string.format` 的格式符，迁移时须逐处区分 pattern 与 format）；15 处非贪婪
   `.-`。ucode 使用 POSIX ERE（libc 正则），**没有非贪婪量符**，Lua 字符类要逐一
   改写，捕获结果从多返回值变成数组下标。风险最高的是 1,686 行的 `parser.lua`
   （全部协议解析）和 YAML 解析器。
2. **多返回值 + `pcall` 模型**：核心库用 `nil, err` 传错误，4 处 `pcall`（全仓库
   7 处）；ucode 是异常模型（`try/catch`），函数只有一个返回值，所有调用点都要改写。
3. **元表哨兵 3 处**：`JSON_EMPTY_OBJECT`、`JSON_NULL`、`M.CLEAR` 靠 `setmetatable`
   表达语义。ucode 原生有 `null` 以及对象/数组区分，这部分可以简化，但要重新设计
   而不是逐行直译。
4. **标准库映射**：`string.format` → `sprintf`、`os.time` → `time`、`io` → `fs`、
   `nixio` → `socket`/`resolv`、`ipairs` 114 处 / `pairs` 28 处 → `for … in` / `keys()`、
   `#` → `length()`。多数是机械改写，但 `util.lua` 的 JSON 编解码（含 inf 处理）、
   `atomic_write`、mkdir 锁、`/dev/urandom` 读 token 等有边界语义的代码要逐条对照。
5. **控制器/模板接口**：LuCI 的 ucode 控制器/模板 API 与 Lua 版不是一一对应；
   公开下载端点 `/substore/download` 在 ucode dispatcher 下的免登录/ACL 行为尤其
   需要在目标机实测。仓库目前没有这层验证。
6. **测试基建**：本机没有 ucode 运行时（`ucode` 命令不存在），CI 也没有 ucode 单测
   环节；迁 ucode 等于同时换实现和换测试语言，而现有 59 个测试正是防止回归的资产。
7. **注释即规格**：`util.lua` / `http.lua` / `core.lua` 里的大量注释记录了实测过的
   边界与故障（SSRF 写法、原子写、锁回收、JSON inf 等）。重写最容易把这些修复丢掉。

## 4. 结论：为什么当前不迁

**收益**（对用户几乎不可感知）：

- 去掉 `luci-lua-runtime` / `luci-compat` / lua5.1 依赖，安装体积与内存略降；
- 原生 JSON 可删掉 `util.lua` 一大块；
- 性能更好，与上游 LuCI 方向一致。

**成本**：

- 一次约 2.3 万行的重写 + 测试重写 + 回归风险 + 真机验证；
- 功能零提升；
- 迁移期间必须同时维护两套实现，或冻结功能开发。

**触发迁移的合理条件**（建议作为决策门槛）：

1. 上游正式移除 `luci-lua-runtime` 或 lua5.1 —— 目前 23.05 / 25.12 / master 仍都提供；
2. 需要某个只有 ucode 版才提供的新 LuCI 机制，Lua 兼容层跟不上；
3. 实测在低配设备上 Lua 方案的内存/性能不可接受。

以上三条当前均不成立，因此**保持 Lua 实现与现有依赖**。

## 5. 若将来迁移：建议路线

按「能验证再迁移」原则分步，不一次性提交：

1. **POC**：用 SDK 里的 ucode 重写 `util` + `core` + cron 的最小闭环，读写同一份
   `/etc/substore/subscriptions.json`，跑通一次 `sync`，验证 `fs` / `json` /
   `popen` / DNS 的实际行为。
2. **测试运行器**：建立 ucode 测试运行方式，把现有 59 个 Lua 测试逐条翻译——先核心
   （util / parser / node / output），这是规格来源。
3. **核心库按模块迁**：util → http → parser → node → output* → core，每步测试全绿
   再进下一步。
4. **最后迁控制器、模板、cron 与 Makefile 依赖**（新增 `ucode-mod-fs` / `socket` /
   `resolv` 等，去掉 `luci-lua-runtime` / `luci-compat`；安装路径按 ucode 版 LuCI
   规范调整）。
5. **保留 Lua 分支与已发布版本**，设备上并行验证后再切换默认实现。

## 6. `.htm` → `.ut` 语法对照（保留作参考）

> 注意：ucode **不能**加载现有 `.lua` 核心库。下表「调用核心库」一行的前提是
> 该核心模块**已经重写为 `.uc`**。`.ut` 的标签集合与 `include` 语法取自 LuCI
> `openwrt-25.12` 分支源码实查（`modules/luci-base/ucode/` 与主题模板），
> **尚未在设备上渲染验证**。

LuCI 23.05+ 的 `.ut` 模板**不再使用** `<% %>` 标签——那是旧版 Lua `.htm` 的语法。
ucode 模板沿用 ucode 自带模板引擎的标签集（标签形式对照 LuCI 25.12 源码实查，
转义语义对照 ucode 官方手册）：

- `{% ... %}`：代码块
- `{{ ... }}`：输出表达式，**原样输出、不做 HTML 转义**（ucode 手册原话：
  "Nothing is escaped for HTML"）。LuCI 已把 `entityencode()`（来自 `html` 模块）
  预绑定进模板作用域，对应 Lua 侧的 `luci.util.pcdata()`；迁移时漏掉这层会直接
  引入 XSS。
- `{# ... #}`：注释
- `{% include('header') %}`：引入其它模板（优先 `.ut`，找不到时经兼容层渲染 `.htm`）
- `{{ _('Text') }}`：翻译

| 事项 | Lua `.htm` | ucode `.ut` |
|------|-----------|-------------|
| 输出表达式 | `<%=expr%>`（`<%= expr %>`） | `{{ expr }}`——**不转义**，需自行 `entityencode()` |
| HTML 转义 | `luci.util.pcdata(v)` | `entityencode(v)`（`html` 模块） |
| 代码块 | `<% lua代码 %>` | `{% ucode代码 %}` |
| 注释 | `<%# ... %>` | `{# ... #}` |
| 翻译标签 | `<%:Text%>` | `{{ _('Text') }}` |
| 引入其它模板 | `<%+header%>` | `{% include('header') %}`（优先 `.ut`，否则回退 `.htm`） |
| 取 HTTP 参数 | `require("luci.http")` + `formvalue` | `.ut` 环境预绑定 `http`，`http.formvalue(...)` |
| 取查询参数 | `luci.dispatcher.context.query` | `http.formvalue(name, true)`（第二参数 `true` 表示从查询串取） |
| 迭代数组 | `for _, v in ipairs(t) do ... end` | `{% for (let v in t): %} … {% endfor %}` |
| 条件 | `if cond then ... end` | `{% if (cond): %} … {% endif %}`（LuCI 模板惯用冒号形式） |
| 字符串拼接 | `..` | `+` |
| 三元 | `a and b or c`（有陷阱） | `cond ? a : b` |
| 取长度 | `#t` | `length(t)` |
| 调用核心库 | `require("substore.core")` | `require("substore.core")`——**前提：已重写为 `.uc` 并安装到 ucode 模块搜索路径** |

示例（前提：`substore/core.uc` 已存在）：

```html
{% let core = require("substore.core"); %}
{% let items = core.list(); %}
{% for (let it in items): %}
  <tr><td>{{ entityencode(it.name) }}</td></tr>
{% endfor %}
```

`require()` 的模块搜索路径以目标机的 ucode 配置为准，迁移时需在设备上确认。
