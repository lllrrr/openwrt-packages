# luci-app-netmonitor 重构说明

本次重构以**修复实机功能缺陷**为核心驱动，同时完成依赖瘦身与代码整理。
所有结论均在 ImmortalWrt SNAPSHOT（aarch64，192.168.10.1）实机验证。

---

## 一、关键缺陷与修复

### 1.1 编辑功能完全失效（严重，已修复）

**现象**：目标管理页点「编辑」无任何反应，弹窗不出现。

**根因**（实机抓取 DOM 证据）：

```
t-dialog 宿主元素:  getBoundingClientRect() = { x:0, y:900, w:1430, h:0 }
shadow 根容器:      display:none
容器类名:           t-dialog__mask-web-zoom-leave-active
```

组件停留在**关闭动画的离开态**，`visible=true` 根本没触发进入动画。

继续深挖发现真正原因——随包分发的 `tdesign.css` 是**残缺的组件样式表**：

| 项目 | 实测值 |
|---|---|
| CSS 变量（`--td-*`） | 578 条，完整 |
| `dialog` 相关规则 | **0 条** |
| 规则总数 | 仅 71 条 |

`tdesign.css` 实质上只是一份变量表，没有任何组件布局规则。`.t-dialog__ctx`
因此拿不到 `display` 规则，组件永久隐藏。

**修复**：整体移除 TDesign 依赖，改用自建原生组件层（见 2.1）。
修复后同一位置实测：`{ x:435, y:24, w:560, h:852 }`，`display:flex`，
`elementFromPoint` 命中链为 `div.nm-dlg-head → div.nm-dlg → div.nm-root`。

### 1.2 存储型 XSS（严重，已修复）

目标名 / 地址 / 标签 / 备注等用户可控字段直接拼接进 `innerHTML`。后端仅做
长度与字符集校验，`<img src=x onerror=alert(1)>` 可完整落进
`/etc/config/netmonitor`，在每个访问该页的管理员会话中执行——LuCI 会话等价于 root。

原代码的转义策略也不自洽：`common.targetCard` 对 `name` 做了
`.replace(/[<>&]/g,'')`（不完整、且不处理引号），同一函数里紧邻的
`host`、`label` 却完全没转义；`targets.js` 则连 `name` 都没转义。

**修复**：`common.el()` 第三个参数语义改为**纯文本**（`textContent`），
需要 HTML 时必须显式调用 `common.elHtml()`。SVG 片段走 `svgBox()`
（内容来自内置的 `icons.js`/`chart.js`，不含用户输入）。

**实机验证**：注入载荷后，页面渲染出 0 个 `img` 元素、原文以文本形式可见、
`alert` 未触发。

### 1.3 后端浮点尾数（中等问题，已修复）

```json
"latency": 26.510000000000002
"p95": 39.630000000000003
```

**根因**：这不是本代码的浮点误差，而是 **ucode/blobmsg 序列化层的固有限制**——
对 double 一律以 17 位有效数字输出。实测证据：

```
字面量 26.51                    -> 26.510000000000002
fx(26.51, 2)                    -> 26.510000000000002
sprintf("%.2f", 26.51)         -> "26.51"   （字符串则干净）
```

即字面量都会被展开，算式层面无法消除。

**修复**：`fx()` 改为返回**已格式化的字符串**，精度在服务端固化。
前端新增 `format.toNum()`（经 `common.toNum` 转发）统一转数值后再做算术与比较。
修复后：`"current": "20.27"`、`"avg": "23.74"`、`"p95": "31.55"`。

### 1.4 批量操作整批失败（中等问题，已修复）

`checked` 对象从不剪枝。删除一个已勾选的目标后，残留的「幽灵 id」导致：
`selectedIds()` 数量超出实际 → 全选框三态彻底失真 → `batch_targets`
收到不存在的 id → 后端整批报错，一条都改不了，且界面无任何提示。

**修复**：`renderList()` 按当前列表重建 `checked`。

### 1.5 负数可绕过校验写入配置（中等问题，已修复）

`<input type=number min=0>` 的 `min` 只是表单校验提示，用户键入 `-5`
不会被拦下。原代码 `parseInt(v) || 0` 对 `-5` 无效（负数是真值），
负数原样提交。`tcp_port` 做了钳位而 `interval`/`timeout` 漏了。

**修复**：新增 `intOf(input, min, max)` 统一解析并夹取范围。

### 1.6 SPA 路由切换导致弹窗与轮询泄漏（中等问题，已修复）

弹窗挂在 `document.body` 上，而 LuCI 的 SPA 路由切换**只替换 view 容器、
不碰 body**：开着弹窗点侧边栏导航，旧弹窗的遮罩与 document 级事件拦截全部留存，
新页面被完全盖住，只能刷 F5。

`settings.js` 的 `poll.add(refreshSvc, 10)` 同理——LuCI 不在路由切换时清理
poll 队列，`refreshSvc` 是 `render()` 内的闭包，切页后无人能引用它，
永远无法 `poll.remove`，访问 N 次就有 N 个 10 秒轮询并发打 rpcd。

**修复**：弹窗改为挂载到页面 `root`（随路由销毁）；轮询回调首行判断
`root.isConnected`，失联即自我注销。

### 1.7 禁用状态显示错误（中等问题，已修复）

`sw.checked = !!t.enabled`——若后端返回字符串 `'0'`，则 `!!'0' === true`，
已禁用的目标会显示为「已启用」，且表格流与卡片流同时回弹。

**修复**：新增 `boolOf(v)` 统一判定真值。

### 1.8 快速连点导致状态错乱（中等问题，已修复）

启用开关的 change 回调直接发请求，无 in-flight 标志也不禁用控件。
用户在响应返回前再次点击，会发出两个 `enabled` 相反的请求，
**响应顺序不保证与点击顺序一致**，最终状态由后到的响应决定。

**修复**：请求期间禁用自身，结束后恢复。

---

## 二、依赖瘦身：移除 TDesign

### 2.1 收益

| 项目 | 重构前 | 重构后 |
|---|---|---|
| 前端资源目录 | 7.4 MB | **159 KB** |
| 其中第三方运行时 | 7.3 MB（tdesign.min.js） | 0 |
| 运行时依赖 | TDesign Web Components | 无 |

实际只用到 `t-button` / `t-tag` / `t-dialog` / `t-alert` 四个组件，
却为此付出 7.3 MB 的 UMD bundle——每个标签页都要重新解析，
低端 CPU 上首屏明显卡顿。

### 2.2 替代方案

新增 `htdocs/luci-static/resources/netmonitor/ui.js`（原生 DOM 实现）：

| 组件 | API | 说明 |
|---|---|---|
| 按钮 | `ui.button(opts)` | 原生 `<button>`；Promise 期间自动禁用、失败自动提示并解禁 |
| 标签 | `ui.chip(opts)` | 替代 `t-tag` |
| 提示条 | `ui.alert(opts)` | 替代 `t-alert` |
| 弹窗 | `ui.dialog(opts)` | 替代 `t-dialog`，class 驱动显示状态 |
| 确认框 | `ui.confirm(opts)` | `onOk` 仅在点确认时调用 |
| 禁用开关 | `ui.setDisabled(node, on)` | 统一处理，避免各调用点各写一遍 |

**弹窗的三处关键修正**（相对原 `t-dialog`）：
1. 挂载点由 `document.body` 改为调用方传入的 `host`（消除 SPA 残留）
2. 显示状态由 class 驱动（`.is-open`），不再依赖组件内部动画状态机
3. ESC 关闭自实现，不依赖第三方组件的 uid 栈

### 2.3 Makefile

移除 TDesign 这个压缩风险源后，恢复 OpenWrt 默认的 JS/CSS 压缩：

```makefile
LUCI_MINIFY_JS:=1    # 原为 0
LUCI_MINIFY_CSS:=1   # 原为 0
```

此前必须关掉压缩，是因为 jsmin 处理 7 MB 的 UMD bundle 会从语句中间切断
（28 行压成 3 行、删掉 691636 字节），产出语法错误的文件。

---

## 三、代码整理

### 3.1 消除重复实现

| 重复项 | 原状 | 现状 |
|---|---|---|
| 按钮工厂 | 3 份（settings `svcBtn` / targets `toolBtn` / `mini`） | 统一为 `ui.button()` |
| 弹窗脚手架 | 2 份（原 `common.confirmDialog` / targets `openEditor`） | 统一为 `ui.dialog()`；`common.confirmDialog` 现仅为指向 `ui.confirm` 的兼容转发，零调用点 |
| 勾选框构造 | targets 内逐字重复 2 份 | `selectCheckbox()` |
| 启用开关 | targets 内逐字重复 2 份 | `enabledSwitch()` |
| 下拉框工厂 | settings `enumControl` / targets `tselect` | `selectInput()` |
| 焦点陷阱 | common `trapFocus` + dialog 各自实现 | 内置于 `ui.dialog()` |

`trapFocus` 原有的 40 行注释（含 uid 栈踩坑记录）随组件一并收敛。

### 3.2 风格统一

- 全部缩进统一为 tab（修正 targets/settings 中 tab+空格混排）
- i18n msgid 统一：修正 overview 页绕过 `_()` 的硬编码中文
- 文件头注释更新为实际使用的组件

---

## 四、实机验证结果

环境：ImmortalWrt SNAPSHOT r0-a385200，aarch64_cortex-a53，192.168.10.1
（先确认设备上 4 个核心文件与仓库哈希一致，排除版本陈旧干扰）

| # | 验证项 | 结果 |
|---|---|---|
| 1 | 七个页面渲染 | 全部正常，`t-*` 残留 **0**，每页 JS 错误 **0** |
| 2 | 编辑弹窗 | `visible:true`，560×852，字段正确预填，命中链正确 |
| 3 | 编辑保存 | 弹窗关闭 → 配置真实落盘 → 守护进程自动重载 |
| 4 | 新增目标弹窗 | 正常打开，字段可填 |
| 5 | 删除确认框 | 标题/正文/按钮文案正确；取消不执行删除 |
| 6 | ESC 关闭 | 弹窗数归零，无监听器残留 |
| 7 | 图表 tooltip | `23:55:28 Baidu 19 ms` |
| 8 | 后端数值 | `"avg":"23.74"` `"p95":"31.55"`（无浮点尾数） |
| 9 | 数据链路 | `running:1`，`age:3`，守护进程持续探测 |
| 10 | XSS 防护 | 注入载荷：0 个 img 元素、原文以文本显示、alert 未触发 |

复现命令：

```bash
# 注：早期的 probe/verify.js 与 probe/xss.js 已随重构删除。
# 现在由下列入口承担回归验证：
node tests/test_icons.js          # 图标渲染断言（437 条）
sh tests/test_netmon_daemon.sh   # 守护进程算法断言（101 条）
python3 po/gen_po.py             # 翻译漂移审计
# 交互与视觉：起本地服务后打开 tests/preview/index.html（见该文件头注释）
```

---

## 五、遗留问题

1. **LuCI 框架自身的 JS 报错**（非本插件）
   `TypeError: "%s/%s.js%s".format is not a function`，出自
   `luci.js` 的 `ClassConstructor.require`。在**任何** LuCI 页面
   （含原生 `/admin/status/overview`）登录后都会出现，与本插件无关，
   疑为 Aurora 主题与该 LuCI 版本的 `String.format` 兼容问题。
   已实测确认：纯 LuCI 页面同样复现，本插件七个页面均为 0 错误。

2. **TCP 探测依赖 curl**
   设备若未安装 curl 且 busybox `nc` 不支持 `-w`，TCP 目标统一报 `errno=4`。
   这是固件侧依赖，可通过安装 `curl` 解决。

3. **持久化历史默认关闭**
   `persistence=0` 时，只保留 tmpfs 环形缓冲（默认 4320 点）。
   超出缓冲区的历史区间无数据——这是保护 Flash 的有意设计，
   前端已在 history 页给出提示条。

4. **`revertConfig()` 的跨页影响**
   `uci.revert()` 回滚整个 netmonitor 会话，无法限定范围。
   设置页「放弃修改」会连带丢弃 targets 页已暂存但未应用的改动。
   本次未改动其行为（属设计取舍），仅在此记录。

---

## 六、变更文件清单

```
新增  htdocs/luci-static/resources/netmonitor/ui.js            原生组件层
删除  htdocs/luci-static/resources/netmonitor/tdesign/         -7.4 MB

修改  htdocs/luci-static/resources/netmonitor/common.js        移除 TDesign 注入；1.5.6 起收敛为
                                                               资源加载 + 兼容转发层（156 行）
新增  htdocs/luci-static/resources/netmonitor/format.js        纯函数层，自 common.js 拆出
新增  htdocs/luci-static/resources/netmonitor/api.js           数据访问层，自 common.js 拆出
新增  htdocs/luci-static/resources/netmonitor/widgets.js       业务组件层，自 common.js 拆出
修改  htdocs/luci-static/resources/netmonitor/style.css        TDesign 选择器 -> 原生类；新增组件样式
修改  htdocs/luci-static/resources/view/netmonitor/*.js         7 个页面全部改造
修改  root/usr/share/rpcd/ucode/luci.netmonitor                fx() 返回格式化字符串
修改  Makefile                                                  恢复 JS/CSS 压缩
```

行尾全部为 LF。所有 JS 文件通过 `node --check`。