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
node tests/test_icons.js            # 图标渲染断言（437 条）
sh tests/test_netmon_daemon.sh     # 守护进程算法断言（136 条）
node tests/test_frontend_guards.js # 前端防护 / 生命周期 / 设计系统断言（291 条）
sh tests/check_ucode_syntax.sh     # ucode 插件语法近似校验
python3 po/gen_po.py               # 翻译漂移审计
# 交互与视觉：起本地服务后打开 tests/preview/index.html（见该文件头注释）
```

### 4.1 断言数与工作区残留

`test_netmon_daemon.sh` 的工作区 `tests/.tmp` 在多次运行之间会残留
`state/<id>`。若不复位，`run_round` 的「未到下次检测时间」会让本轮直接跳过，
ping 不被调用，断言只能拿到空参数 —— 表现为「第一次跑通过、之后再跑全红」。
测试脚本已在第 2 段开头显式复位 state（用清空而不是删除：脚本把 `rm` 替换
成了 no-op，见该文件头说明）。新增测试时若引入新的目标 id，请沿用同样处理。

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
---

# 补记：前端设计体系统一（v1.6.0）

前六节记录的是 1.5.6–1.5.9 的重构。v1.6.0 是一次**纯前端**的体系性重构：
业务逻辑、UCI 字段、RPC/ubus/ACL、接口路径与数据结构一律未动，改动集中在
UI / 交互 / 样式三层。目标：建立覆盖 PC / 平板 / 移动端的完整设计系统，
消灭「同一套控件九份拷贝、弹窗四种写法、旧类名零发送方却带着一整套样式」
的现状。

## 七、统一前的问题盘点

| # | 问题 | 范围 |
|---|---|---|
| 1 | 原生 select 控件有**五份**各自带「未知当前值补兜底项」逻辑的实现 | settings / targets / realtime / history / charts / regions |
| 2 | 设置页自带四份控件工厂（switchControl / intControl / enumControl / textControl） | settings.js |
| 3 | targets 编辑器自带三份控件工厂 + 一份 field 包裹 | targets.js |
| 4 | 弹窗四种形态：`ui.dialog` / `common` 里的死实现 / 页面手拼 / 历史上的 `window.confirm` | 全库 |
| 5 | `notify` 调用未定义全局，按钮失败提示永远落 console（用户不可见） | ui.js / widgets.js |
| 6 | 删除确认的遮罩点击与普通确认无异（误点 = 误确认破坏性操作） | targets.js |
| 7 | 旧类名 `.nm-select` / `.nm-input` / `.nm-num-input` 自 v1.4.2 起零 JS 发送方，却带着基线 / 宽度 / 兼容共十余条样式规则 | style.css |
| 8 | 弹层断点各写各的（有的页面根本没有窄屏形态，直接缩小 PC 框） | 全库 |
| 9 | 编辑弹窗连点重复提交（1.5.9 的 submitting 守卫是调用方补丁，非框架能力） | targets.js |
| 10 | 概览页首屏卡片区空白，分不清「加载中」与「无数据」 | overview.js |

## 八、设计系统的构成

`ui.js`（395 → 1320 行）成为唯一的设计系统原语层：

- **表单控件九工厂**：`field` / `textInput` / `numberInput` / `textareaInput` /
  `selectInput` / `switchControl` / `checkControl` / `radioGroup` / `segmented`，
  外加 `bindLabel` 与 `setBusy`。底层仍是原生元素（受控模式下第三方组件实测
  失效，见文件头），工厂只提供一致的外观、键盘行为与无障碍语义。
- **弹窗体系**：`dialog`（重写）/ `confirm` / `panel` / `popover` / `toast` /
  `progress` 六件套，全部挂在 `overlayShell` 模态外壳上：close 幂等、
  Tab 圈养、焦点还原、滚动锁引用计数、rAF 驱动 `is-open`。
- **CSS Token**：控件高度 / 内边距 / 字号 / 圆角 / 焦点环 / 动效时长 / z-index
  层级全部变量化；弹层形态由 JS 按 `matchMedia` 加类，断点唯一 768px。

关键取舍记录：

1. **`toast` 刻意用裸 `setTimeout` 而非 `window.setTimeout`**：测试桩的
   `window.setTimeout` 会同步执行回调，那会让通知一创建就被销毁，无法断言
   结构（浏览器中两者等价）。
2. **`confirm({ danger: true })` 时 `maskClose` 默认 false**：误点遮罩等于
   误确认破坏性操作，不可接受；只保留取消 / 关闭按钮 / Esc 三条明确退出路径。
3. **禁假进度**：`indeterminate` 仅用于真不确定场景；确定进度的百分比必须
   来自真实 `setValue()` 回调，不许拿定时器演动画。
4. **`dialog` 的 `onOk` 返回 Promise 即自动 busy**：连点防护从「调用方各写
   守卫」升级为框架能力，targets 编辑器的 submitting 标志降级为防程序性
   重入的第二道防线。
5. **CSS 自定义属性挂在多个容器选择器上**（`.nm-root` / `.nm-modal` /
   `.nm-dlg-host` / `.nm-toast-host` 等）：弹窗与通知挂在 body 下、不在
   `.nm-root` 内，Token 必须跟着走，否则 body 挂载的组件全部丢变量。

## 九、变更文件清单（v1.6.0）

```
修改  htdocs/luci-static/resources/netmonitor/ui.js            设计系统原语层重建（+1016/-90）
修改  htdocs/luci-static/resources/netmonitor/style.css        Token 化 + 新组件样式 + 死 CSS 清理（+814/-143）
修改  htdocs/luci-static/resources/netmonitor/widgets.js       notify 委托 ui.toast；移除未定义全局依赖
修改  htdocs/luci-static/resources/netmonitor/common.js        注释与转发说明同步
修改  htdocs/luci-static/resources/view/netmonitor/settings.js 四份控件工厂改为委托 + bindLabel 关联 + aria-invalid
修改  htdocs/luci-static/resources/view/netmonitor/targets.js  编辑器 field/控件/提交全面改用工厂；删除确认 danger 化
修改  htdocs/luci-static/resources/view/netmonitor/{realtime,history,charts,regions}.js
                                                                makeSelect 改为转调别名；工具栏标签 bindLabel 化
修改  htdocs/luci-static/resources/view/netmonitor/overview.js 加载态：pending/lastD/刷新指示/首屏占位
修改  po/gen_po.py                                             ZH 新增 Refreshing / Loading…
修改  po/templates/luci-app-netmonitor.pot                     重新生成（186 条）
修改  po/zh_Hans/luci-app-netmonitor.po                        重新生成（untranslated 0）
修改  tests/test_frontend_guards.js                            79 → 291 断言（新增设计系统一节）
修改  tests/test_netmon_daemon.sh                               dash 下 jobs -p 不枚举时行为断言改 skip
修改  tests/test_icons.js                                      icons.js 改 require format 后更新测试桩
修改  Makefile                                                 PKG_VERSION 1.5.9 → 1.6.0
修改  CHANGELOG.md / README.md / REFACTOR.md                   文档同步
```

注意：`po/*.po` 与 `po/templates/*.pot` 是 `po/gen_po.py` 的**生成物**，
译文真源是 `gen_po.py` 里的 `ZH` 字典——手工编辑 po 文件会在下次
`--audit` 时被覆盖（本轮实际踩中过一次）。

页面级集成冒烟（targets 真实 render 全流程）暴露了两个此前静态审查没发现
的真实缺陷，均已修复：`button()` 静默丢弃 `ariaLabel`（targets 五个行内
操作按钮的可访问名称只剩箭头字符）、`test_netmon_daemon.sh` 的子进程回收
行为断言在 dash 下假失败（`jobs -p` 在命令替换里不枚举，bash / busybox ash
不受影响；改为先探测、不能枚举则 skip，支持 shell 上仍全量执行）。

行尾全部为 LF。所有 JS 文件通过 `node --check`。
