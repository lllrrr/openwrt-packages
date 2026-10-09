# 更新日志

本文件记录 luci-app-netmonitor 的所有重要变更，是**版本变更记录的唯一归口**。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

- 使用说明与当前版本的行为描述见 [`README.md`](README.md)。
- 逐条变更背后的技术背景、根因分析与实机验证方法见 README 第十二章
  「开发约定与踩坑记录」——那一章按**技术主题**组织，记录的是至今仍生效的硬约束，
  不随版本变动，因此留在 README 而未迁入本文件。
- 版本号与 `Makefile` 的 `PKG_VERSION`、git tag `v<版本>` 三者必须一致。

条目分类：`新增` / `变更` / `修复` / `移除` / `弃用` / `安全`。


## [1.5.2] - 2026-10-10

### 修复

- **区域页「延迟对比」曲线整条不可见（图表空白）**。
  该页的分区平均曲线在聚合时对后端返回值做累加，
  而 `fx()` 自 1.5.0 起把浮点字段以**字符串**返回 —— JS 的 `+` 对字符串
  是拼接而非相加：
  ```
  sum += "18.96"   ->  0 + "18.96" = "018.96"
  sum += "25.3"    ->  "018.9625.3"
  sum / cnt        ->  "018.9625.3" / 3 = NaN
  ```
  于是所有采样点的 Y 坐标都成了 NaN，生成的 path 是
  `M42.0 NaN L61.4 NaN L80.8 NaN ...` —— 曲线元素存在、但一个点都画不出来；
  Y 轴也因取不到最大值而退化成默认的 0~10，实际延迟 20~180 ms 全部落在图外。
  同一原因还让「延迟曲线」页的「当前」摘要卡显示成「—」（NaN）。

  复现关键：`/`、`*`、`-` 的隐式类型转换是正确的，**只有累加会踩这个坑**，
  因此该问题只在少数位置暴露、不易一眼看出。

  修复：在 RPC 出口统一做数值归一化（`common.js` 新增
  `numifyHistory` / `numifyStatus` / `numifyStats`），`get_history` /
  `get_status` / `get_statistics` 的浮点字段一律转成 number，
  所有消费方都拿到数值，不必每个调用点自己记得 `parseFloat`。

  首次修复时 `FLOAT_KEYS` 漏掉了曲线点位的延迟键 `l`（与目标当前延迟
  `latency` 是两个不同的键），曲线仍为 NaN；已补上并回归验证。

### 变更

- **出厂默认启用全部四个示例目标**（此前只启用 `baidu`）。
  出厂配置只启用 1 个国内目标时，区域页的「区域延迟对比」只能画出一条曲线，
  「对比」这一功能实际上看不到效果。现在默认启用：
  | 目标 | 地址 | 区域 |
  |---|---|---|
  | Baidu | www.baidu.com | 国内 |
  | AliDNS | 223.5.5.5 | 国内 |
  | Cloudflare | 1.0.0.1 | 国外 |
  | GoogleDNS | 8.8.8.8 | 国外 |
  装完即可看到国内 / 国外两条对比曲线。不需要的目标可在目标管理页停用，
  停用后既不发包也不进入曲线。
  同步更新了 `root/etc/uci-defaults/luci-app-netmonitor`（配置缺失时的补齐路径）。

- **Cloudflare 探测地址由 `1.1.1.1` 改为 `1.0.0.1`**。
  `1.0.0.1` 是 Cloudflare 的同一组任播地址，在国内网络下 ICMP 可达性更稳定
  （实测 `1.1.1.1` 常被丢弃、`1.0.0.1` 正常回包）。

  注意：这两项只影响**新安装**的默认值。OpenWrt 的包管理器在升级时保留
  `/etc/config/netmonitor`，已有安装不会被覆盖 —— 需要生效请在目标管理页
  自行启用，或删除该配置文件后重装。

### 验证

- **曲线修复**：「延迟曲线」页的「当前」摘要卡由「— ms」恢复为实测值
  （如 74.5 ms），Y 轴由退化的 0~10 恢复为 0~250；区域页 Y 轴恢复 0~200，
  两条曲线 path 中均无 NaN，图例与曲线颜色一致。
- **默认配置**：部署后守护进程生效清单为 4 个目标（2 国内 + 2 国外），
  四个目标均有回包（实测 27.7 / 23.4 / 247.5 / 53.8 ms）；区域页在默认配置下
  即渲染两条曲线（国内 ~25 ms 平稳、国外随目标波动）。
- **整体回归**：七个页面全部无异常值（无 NaN / undefined / 「— ms」占位），
  0 JS 错误。


## [1.5.1] - 2026-10-10

承接 1.5.0 的组件层重构，修复重构后暴露的一批**视觉与交互缺陷**。
以下每条都以实机 `getComputedStyle` / `getBoundingClientRect` 实测确认，
而非目测。

### 修复

- **危险按钮与普通按钮无法区分（删除按钮显示为蓝色）**。
  `.nm-btn-danger` 与 `.nm-btn-text` 同为单类选择器（优先级 0,1,0），
  谁写在样式表后面谁生效；文本变体为去掉边框底色必须声明 color，
  于是「危险 + 文本」按钮的颜色被覆盖。实测目标管理页的「删除」渲染为
  `rgb(47,111,237)`（与「编辑 / 复制」相同的强调蓝），而不是警示红
  `rgb(207,68,55)` —— 危险操作在视觉上完全无法与普通操作区分。
  修复：新增 `.nm-btn-danger.nm-btn-text` 双类规则（优先级 0,2,0），
  与书写顺序解耦；同时删除样式表中重复定义的第二份 `.nm-btn` 规则块
  （同一类被定义两次是这类问题的温床）。

- **图表页目标胶囊四个全部长得一样，无法分辨选中状态与目标身份**。
  从 TDesign 的 `t-tag` 迁移到原生 `<button>` 时只保留了布局样式，
  漏掉了状态与圆点规则，实测：
  `· .nm-chip-dot` 无任何规则 → `getBoundingClientRect()` 为 **0×0**，
  圆点完全不可见；
  `· .is-on / .is-off` 无规则 → 选中与未选中渲染结果完全相同。
  修复：补齐 `.nm-chip-tag` 完整样式、`.nm-chip-dot` 尺寸（9×9 圆形）、
  以及 `.is-on`（目标色边框 + 同色淡底 + 同色文字）与
  `.is-off`（置灰 + 圆点去色）两个状态；目标色由 `charts.js` 通过
  `--nm-chip-color` 注入，与折线、图例同源，三处不会漂移。

- **实时页状态指示列渲染为空（四个 LED 全部不可见）**。
  `.nm-led-box` / `.nm-led-center` / `.nm-led-ping-ring` 及
  `nm-led-off|good|warn|bad` 共 7 个类**从 v1.4.2 起就没有任何样式规则**，
  实测 `.nm-led-box` 高 0、`.nm-led-center` 为 0×0 且背景透明。
  修复：补齐 LED 样式，配色沿用全局等级体系，呼吸与扩散直接复用既有的
  `@keyframes nm-pulse-soft` / `nm-ripple`，不新增动画定义；停用目标
  静止不呼吸（闪烁会让人误以为该目标仍在被探测），并遵循
  `prefers-reduced-motion`。

- **开关控件被主题样式压成 16×16 蓝点**。
  LuCI 主题（Aurora `main.css`）中的
  `input[type="radio"], input[type="checkbox"] { width: calc(var(--spacing)*4) }`
  优先级为 0,1,1，高于单类选择器 `.nm-switch` 的 0,1,0，因此主题胜出，
  把开关从 44×24 压到 16×16；而圆角与底色仍由本项目规则生效（主题未定义
  这两项），最终渲染成一个 16px 蓝色圆点，20×20 的白色滑块 `::before`
  溢出容器。修复：选择器改为 `input[type="checkbox"].nm-switch`
  （优先级 0,2,1），稳定胜出。

- **实时页与设置页首次加载拿不到数据**。
  自注销逻辑（`poll.remove`）在首次同步调用时误触发：那时 LuCI 尚未把
  `root` 挂到文档，`root.isConnected` 为 false，被当作「页面已卸载」而
  立刻短路返回，`latest` 永远为 null —— 实时页表格与卡片流整片空白
  （实测页面文本长度仅 79，修复后 419）。修复：增加 `firstRun` 标记，
  只在**轮询调用**时才据 `isConnected` 判定卸载。

- **后端聚合值恒为 0**。`fx()` 改为返回格式化字符串后，`statOf()` 的
  返回值被上层拿去做算术累加（`agg.lat_sum += st.latency`），而 ucode 的
  `string += number` 会静默得 0，导致 `overall.current` / `regions.avg`
  恒为 `"0.00"`。修复：新增 `fxNum()` 返回**数值**供内部聚合，
  `statOf()` 改用 `fxNum()`；格式化统一推迟到 JSON 输出边界
  （`get_status` 的逐目标字段、`get_history` 的 summary 与 points）。

- **补齐两处从未定义的样式类**：`.nm-txt-sub`（表格次要文本）、
  `.nm-svg-soft-pulse`（区域页图标呼吸）。
  另移除 `ui.js` 中创建后从未挂载的死代码 `nm-dlg-wrap`。

### 安全

- 无新增安全问题。1.5.0 的 XSS 修复继续有效。


## [1.5.0] - 2026-10-10

### 移除

- **移除 TDesign Web Components 依赖，前端资源从 7.4 MB 降到 152 KB**。
  本项目此前随包分发 TDesign UMD 构建（`tdesign.min.js`，7.3 MB），但实际只用到
  `t-button` / `t-tag` / `t-dialog` / `t-alert` 四个组件。改为自建的原生组件层
  `htdocs/luci-static/resources/netmonitor/ui.js`（原生 DOM 实现，无第三方依赖），
  删除整个 `htdocs/luci-static/resources/netmonitor/tdesign/` 目录。
  代价是每个标签页不再需要重新解析 7.3 MB UMD，低端 CPU 上首屏不再卡顿。
- **`tdesign/` 目录整体删除**。随包的 `tdesign.css` 是一份**残缺的组件样式表**：
  578 条 `--td-*` CSS 变量齐全，但 `dialog` 相关规则一条都没有（实测
  `grep -c dialog` = 0，规则总数仅 71），实质上只是一份变量表。

### 修复

- **目标管理页「编辑」功能完全失效（最严重）**。实机抓 DOM 证据：
  `t-dialog` 宿主元素 `getBoundingClientRect()` 为 `{x:0, y:900, w:1430, h:0}`，
  shadow 根容器 `display:none`，容器类名停在 `t-dialog__mask-web-zoom-leave-active`
  —— 组件处于关闭动画的离开态，`visible = true` 根本没触发进入动画，点击编辑后
  界面毫无反应。根因即上一条的残缺样式表：`.t-dialog__ctx` 拿不到任何 `display`
  规则，组件永久隐藏。修复：随 TDesign 一并移除，改用 `ui.dialog()`（class 驱动
  显示状态）。修复后同位置实测 `{x:435, y:24, w:560, h:852}`、`display:flex`、
  `elementFromPoint` 命中链为 `div.nm-dlg-head → div.nm-dlg → div.nm-root`。
- **存储型 XSS**。目标名 / 地址 / 标签 / 备注等用户可控字段直接拼接进 `innerHTML`，
  后端仅校验长度与字符集，`<img src=x onerror=alert(1)>` 可完整落进
  `/etc/config/netmonitor` 并在每个访问该页的管理员会话中执行（LuCI 会话等价于 root）。
  原有转义策略亦不自洽：`common.targetCard` 对 `name` 做了不完整的
  `.replace(/[<>&]/g,'')`，同一函数里紧邻的 `host`、`label` 却完全没转义。
  修复：`common.el()` 第三个参数语义改为**纯文本**（`textContent`），
  需要 HTML 时必须显式调用 `common.elHtml()`；SVG 片段走 `svgBox()`
  （内容来自内置的 `icons.js` / `chart.js`，不含用户输入）。
- **后端浮点精度尾数**。`get_status` 等接口返回 `26.510000000000002` 这类带尾数的值。
  根因不是本代码的浮点误差，而是 **ucode/blobmsg 序列化层的固有限制**——对 double
  一律以 17 位有效数字输出，实测连字面量 `26.51` 都会被展开成 `26.510000000000002`，
  算式层面无法消除。修复：`fx()` 改为返回 `sprintf()` 格式化的字符串，精度在服务端
  固化；前端新增 `common.toNum()` 统一转数值后再做算术与比较。
- **批量操作整批失败**。`checked` 对象从不剪枝，删除一个已勾选的目标后残留「幽灵 id」，
  导致 `selectedIds()` 数量超出实际、全选框三态彻底失真，且 `batch_targets` 收到
  不存在的 id 后整批报错，一条都改不了且界面无任何提示。修复：`renderList()`
  按当前列表重建 `checked`。
- **负数可绕过校验写入配置**。`<input type=number min=0>` 的 `min` 只是表单校验提示，
  用户键入 `-5` 不会被拦下；原代码 `parseInt(v) || 0` 对负数无效，负数原样提交。
  `tcp_port` 做了钳位而 `interval` / `timeout` 漏了。修复：新增
  `intOf(input, min, max)` 统一解析并夹取范围。
- **SPA 路由切换导致弹窗与轮询泄漏**。弹窗挂在 `document.body` 上，而 LuCI 的 SPA
  路由切换只替换 view 容器、不碰 body：开着弹窗点侧边栏导航，旧弹窗的遮罩与
  document 级事件拦截全部留存，新页面被完全盖住，只能刷 F5。`settings.js` 的
  `poll.add(refreshSvc, 10)` 同理——LuCI 不在路由切换时清理 poll 队列，
  `refreshSvc` 是 `render()` 内的闭包，切页后无人能引用它、永远无法 `poll.remove`，
  访问 N 次就有 N 个 10 秒轮询并发打 rpcd。修复：弹窗改为挂载到页面 `root`
  （随路由销毁）；轮询回调首行判断 `root.isConnected`，失联即自我注销。
- **禁用状态显示错误**。`sw.checked = !!t.enabled` 在后端返回字符串 `'0'` 时
  （`!!'0' === true`）会把已禁用目标显示为「已启用」，且表格流与卡片流同时回弹。
  修复：新增 `boolOf(v)` 统一判定真值。
- **快速连点导致状态错乱**。启用开关的 change 回调直接发请求，无 in-flight 标志
  也不禁用控件；用户在响应返回前再次点击会发出两个 `enabled` 相反的请求，
  响应顺序不保证与点击顺序一致，最终状态由后到的响应决定。修复：请求期间禁用自身。

### 变更

- **`common.el()` 第三个参数语义变更**：由 HTML 片段（`innerHTML`）改为纯文本
  （`textContent`）。这是修复 XSS 的根本手段，属**行为变更**：依赖它渲染标记的
  调用点已改为显式 `common.elHtml()`。
- **`common.confirmDialog()` 不再返回 Promise**。此前返回 `Promise<boolean>`，
  现改为同步调用，副作用放在 `ui.confirm({ onOk })` 回调内
  （`onOk` 仅在用户点确认时触发，取消 / ESC / 点遮罩均不触发）。
- **`common.trapFocus()` 已移除**，焦点陷阱与 ESC 处理内置于 `ui.dialog()`。
- **`common.tdesign()` 已移除**，UI 组件统一走 `common.ui.*`。
- **Makefile 恢复 JS/CSS 压缩**（`LUCI_MINIFY_JS` / `LUCI_MINIFY_CSS` 由 `0` 改为 `1`）。
  此前必须关掉，是因为 jsmin 处理 7 MB 的 TDesign UMD 会从语句中间切断
  （28 行压成 3 行、删掉 691636 字节），产出语法错误的文件。移除该依赖后前端全部是
  自有源码（约 150 KB），压缩无风险。

### 新增

- **`htdocs/luci-static/resources/netmonitor/ui.js`** —— 原生 UI 组件层：
  `button()` / `iconButton()` / `chip()` / `alert()` / `dialog()` / `confirm()` /
  `setDisabled()`。按钮工厂统一处理「请求期间禁用、失败提示、结束解禁」，
  此前这份逻辑在三个页面各写一遍。
- **`REFACTOR.md`** —— 本次重构的变更说明、根因分析与实机验证记录。

### 安全

- 修复存储型 XSS（详见「修复」一节）。实机验证：注入
  `<img src=x onerror=alert(1)>` 后，页面渲染出 0 个 `img` 元素、原文以文本形式
  可见、`alert` 未触发。


## [1.4.2] - 2026-10-02

### 修复

- **CI「产物完整性护栏」把「容器缺 node」误判成「JS 被压缩破坏」**。
  护栏步骤（`.github/workflows/build.yml` 的 *Verify payload integrity against
  source*）用 `node --check` 校验打包产物里的每个 `.js` 文件，但 `openwrt/sdk`
  容器默认不装 node，命令以 `node: not found`（exit 127）退出，护栏随即把第一个
  被检文件（`netmonitor/chart.js`）误报为 `INVALID JAVASCRIPT in payload` 并终止
  构建——实际上 chart.js 与源码逐字节一致、语法完全合法。修复：护栏开头检测
  `node` 是否存在，缺则直接从 nodejs.org 下载官方静态二进制放入
  `/usr/local/bin`（架构按 `uname -m` 映射，Alpine/musl 基座自动改用 musl 构建），
  再执行校验。不用系统包管理器补装：SDK 容器的 Debian 11 (bullseye) 基座
  2026-08 已 EOL，软件源随之 404（1.4.1 CI 实测 `apt-get install nodejs` 报
  `Unable to fetch some archives`，exit 100）；且即便源可用，装上的也是 node 12，
  太老、`node --check` 认不得本项目前端用的现代 JS 语法，仍会误报。下载方案与
  系统包源解耦后，护栏恢复对 jsmin 类破坏的真实检出能力。
- **TDesign 表单控件在受控模式下交互失效（开关 / 下拉 / 输入）**。基于 Omi 框架的
  `t-switch` / `t-select` / `t-input` / `t-input-number` 在受控模式（通过 value
  属性赋值）下实测：开关点击后状态不切换（`innerChecked` 未随 `receiveProps` 同步）、
  下拉菜单无法打开（`state.innerPopupVisible` 未正确初始化、合成事件无法穿透
  shadow DOM），七个视图页上的开关按钮与下拉菜单因此无法正常使用。修复：全部改为
  原生 HTML 控件（`checkbox` / `select` / `number` / `text`），样式保留 TDesign
  观感（`.nm-switch` 纯 CSS 滑块、`.nm-select` / `.nm-input` / `.nm-num-input`
  统一样式），交互由浏览器原生保证，兼容 LuCI 全部目标浏览器。改造范围：
  设置页（已先行）、目标管理页（表格 / 卡片启用开关、编辑弹窗表单）、实时页
  （区域 / 状态筛选、关键字搜索）、延迟曲线页（时间范围、快捷筛选）、区域页
  （时间范围）、历史页（时间范围 / 区域 / 目标筛选）。`t-dialog` / `t-button` /
  `t-tag` / `t-alert` 等展示与动作组件不受受控模式缺陷影响，保留使用。
- **配置页在取不到后端配置时静默渲染空白表单 / 整页加载失败，用户无从判断原因**。
  `get_config` 的 RPC 一旦拿不到完整配置（rpcd 缓存旧 ucode、会话 ACL 未刷新、
  浏览器缓存旧页面、ubus 对象未注册 都会造成），旧版设置页只有两种表现：返回空对象
  时渲染一张所有控件为空的表单，或调用被拒时 `Promise.all` 整体失败、LuCI 直接显示
  「加载失败」——用户既看不到值也看不到原因。修复：① `render()` 顶部加诊断判断，
  当 26 个全局配置键一个都不在时显示横幅「无法从后端读取配置（RPC 调用失败或返回
  为空），请重启 rpcd 后重新登录 LuCI，并执行 `ubus call luci.netmonitor get_config`
  检查后端」，并给出可操作的排查路径；该判断必须放在 `default_proto` /
  `default_tcp_port` 兜底赋值**之前**，否则兜底会往空对象写入键、导致 `some()` 误判
  配置非空。② `load()` 里 `getConfig().catch()` 降级为 `null`，使 RPC 拒绝时页面照常
  渲染出表单与诊断横幅，而不是整页加载失败。验证：JSDOM 模拟环境三种场景全部通过——
  RPC 返回完整配置（26 控件正确填充、无横幅）/ 返回空对象（26 控件渲染 + 横幅）/
  RPC 直接拒绝（26 控件渲染 + 横幅，load 不再 reject）。


## [1.4.1] - 2026-10-03

### 修复

- **TDesign 组件库在打包时被压坏，1.4.0 的组件体系实际不生效**。1.4.0 引入的
  `tdesign.min.js`（7 MB 第三方 UMD bundle）经 `jsmin` 压缩后被破坏：文件从
  28 行压成 3 行、删掉 691636 字节，删除点落在语句中间
  （`var fu=...self:{};` 与紧随的 `!function(e){if(!e.WeakMap){` 之间），
  产出的文件 `node --check` 直接报 `SyntaxError`，浏览器报
  `missing ) after argument list`，`window.TDesign` 未定义。
  现象极具迷惑性：页面框架、响应式布局、动态 SVG 动效全部正常，
  DOM 里 `t-button` / `t-tag` / `t-switch` 与 `.nm-tcard` 计数也都非零，
  但那只是**未升级的自定义标签**，无样式、无行为——组件体系等于没装。
  修复：`Makefile` 在 `include luci.mk` 之前显式 `LUCI_MINIFY_JS:=0` 与
  `LUCI_MINIFY_CSS:=0`。luci.mk 里是 `?=` 而非 `:=`，故可被覆盖；
  位置必须在 include 之前（`JsMin` / `CssTidy` 宏在 include 时展开）。
  验证：把仓库源文件直接放上设备后 `window.TDesign` 立即为 true，七页无 JS 错误。


## [1.4.0] - 2026-10-03

### 新增

- **TDesign Web Components 组件库本地化**。`tdesign.min.js`（UMD）与
  `tdesign.css` 随 ipk 包以静态资源分发（`htdocs/luci-static/resources/netmonitor/tdesign/`），
  由 `common.tdesign()` 动态注入，无外网 CDN 依赖，低端路由器离线可用；
  组件只注册一次，失败时可降级提示，不影响既有数据链路。

### 变更

- **全量重构 UI 为 TDesign 组件体系**。七个视图页（Overview / Realtime /
  Charts / Regions / History / Targets / Settings）的工具栏、卡片、按钮、
  标签、开关、弹窗与表单控件全面替换为 TDesign 组件
  （`t-card` / `t-button` / `t-alert` / `t-tag` / `t-switch` / `t-dialog` /
  `t-input` / `t-input-number` / `t-select` / `t-notification` 等），
  移除此前自研的毛玻璃玻璃态样式；TDesign 主题变量经
  `style.css` 映射到 LuCI 主题变量（`--nm-accent` → `--td-brand-color` 等），
  保持与既有主题及暗色模式兼容。**自研动态 SVG 动效与图表渲染逻辑全部保留**：
  状态仪表、实时采样声波、环形弧长等动效由真实测量值驱动，TDesign 图标无法
  表达此类状态化动效，因此两类视觉体系按职责分工共存。
- **UI 布局与排版适配 PC + 移动端**。全页面统一响应式断点
  （手机 ≤640px / 平板 ≤1100px / 桌面 ≥1101px）：指标类卡片栅格按断点显式
  定列数（桌面 3 列 / 平板 2 列 / 手机 2 列），手机端不再一行只放一张卡片，
  下拉距离大幅缩短；目标卡片、明细表等大卡片保持单列，避免横向溢出。
- **设置页与 OpenWrt 原生「保存并应用」对齐**。移除页面底部悬浮操作栏，
  改为页内卡片，保存逻辑统一走 UCI 会话暂存（`uci.set/unset/save`），
  由系统原生按钮 `ui.changes.apply()` 统一提交，不再重复实现落盘与
  服务重载；新增「已暂存，待应用」状态提示，并同步提供「放弃修改」
  撤回会话改动。
- **延迟曲线图清晰度优化**。去掉 `clientWidth` 的 320px 下限，viewBox 与
  容器 1:1 渲染，手机端曲线与文字不再被等比压缩；轴标签字号与透明度、
  网格线、曲线线宽（2.2px）、当前值圆点与悬停游标均做了加大 / 提亮处理。
- **regions 页面桌面端收敛**。国内 / 国外区域卡片限制最大宽度
  （340–520px）并居中，不再在宽屏上拉满全宽；hero 展台内边距、图标
  尺寸（64px）与平均延迟字号（1.55rem）相应收敛，明细指标矩阵改为
  2 列布局，窄屏下 6 项指标排 3 行更均衡。
- **卡片内排版与表单控件对齐优化**。卡片容器统一改为 `.nm-tcard`
  （普通 div 复刻 TDesign 卡片视觉，避免 t-card shadow DOM 克隆导致
  内部布局样式失效）；工具栏筛选字段（区域 / 状态 / 搜索）改为 flex
  等宽铺排，宽度不再由 label 文本长度决定；设置页右侧控件区统一为
  210px 定宽，下拉 / 文本输入占满控制区、数字输入保持 132px 紧凑
  步进宽度，所有控件右缘对齐；明细表数值列（延迟 / 丢包 / 在线率 /
  连续失败等）统一右对齐，便于同列个位对齐与快速比对。

### 修复

- **触控目标过小**。图表页 / 区域页时间范围胶囊按钮在手机端高度不足
  推荐触控尺寸，补足 `min-height: 34px` 与内边距。


## [1.3.0] - 2026-10-02

### 新增

- **七个视图页统一升级为「白色毛玻璃 + 动态 SVG 动效」视觉体系**。
  Overview / Realtime / Charts / Regions / History / Targets / Settings 全部换用
  浅色径向渐变画布与毛玻璃卡片质感，统一排版（最大宽度 1360px、间距 22px、
  悬浮高光上浮、移动端响应式），并重绘各组动态 SVG：Hero 健康展台增加径向光晕、
  核心渐变圆环与雷达脉冲；实时采样声波柱改渐变填充并保留逐柱错峰动画。
- **前端文案全面汉化**。Realtime（30 处）、Settings（108 处）及其余页面副标题等
  英文残留统一替换为中文，直接以 `_('中文')` 硬编码绕过 po 词条缺失导致的
  英文原样回显。

### 修复

- **Hero 状态图标（对勾 / 感叹号 / 叉）几何居中**。此前路径 bbox 中心与
  viewBox 中心（52,52）不重合，图标整体偏左上；现按 bbox 中心对齐重写路径，
  并减弱过强的 drop-shadow 光晕，避免边缘发虚。
- **Charts 延迟曲线页移动端滚动被强制弹回顶部**。轮询重建时先清空
  图表 / 摘要 / 图例容器，而 `chart.mount()` 内部读取 `clientWidth` 会强制
  同步布局，此刻页面高度瞬时塌缩，移动端浏览器把滚动位置钳回顶部，
  导致手机上下滑查看延迟曲线时被弹回。修复为：重建前快照并锁定容器最小高度，
  重建完成 / 提前返回 / 出错时解除锁定，并对滚动位置做兜底恢复，
  手机端可正常下滑查看完整曲线。


## [1.2.1] - 2026-09-19


### 修复

- **曲线图表悬停只能看到单条曲线**。旧实现的命中测试是「在所有曲线里找离鼠标
  最近的那一个点」，于是 tooltip 永远只报一条曲线的数值，多目标对比时其余曲线
  无从对照；坐标换算还把 `width="100%"` 当成 100 像素用，导致悬停位置与曲线
  实际位置错位。现改为：先由鼠标横坐标换算出**时间**，再取每条曲线在该时刻的
  取值，一次列出全部已选曲线（色点 + 名称 + 数值），并叠加一条竖直基准线和
  各曲线的取值圆点。命中测试与绘制共用同一套几何参数（`chart.layout`），
  坐标换算改用 SVG 的 `getScreenCTM()`，`preserveAspectRatio` 造成的缩放
  与留白也不会再让位置算错。
- **延迟出现 4159331 ms 这样的荒谬最大值**。实测 `googledns` 有一条
  `4159330.860 ms` 的采样（约 69 分钟），来源是时钟跳变或 ping 输出串味，
  并非真实延迟；它把图表 Y 轴拉到百万毫秒量级，正常曲线被压成贴底直线，
  「最大值」卡片也跟着显示 4159331 ms。现为探测延迟加上界：
  `ping -W <timeout>` 的语义是「等 timeout 秒没回应就算这次超时」，因此
  任何超过探测超时预算的 RTT 一律**按超时记账**，不再作为成功样本入库。
  ICMP 与 TCP 两条探测路径同口径，读取侧（`readRing` / `readAgg` /
  `parseStats`）也同步过滤，历史文件里早先写入的脏数据不会再进入图表与统计。

### 变更

- 守护进程新增 `lat_cap()` / `lat_over_budget()`，上界取「目标独立 timeout，
  未设置则继承全局」× 1000 ms，并夹在 [1s, 30s]；越界时写一条 info 日志，
  便于事后追查是真实超时还是解析异常。
- 单元测试新增两条回归护栏：异常 RTT（4159330.860 ms）与超预算的 TCP 握手
  都必须落为「超时」而非「很慢但成功」。


## [1.2.0] - 2026-09-15

### 新增

- **目标编辑弹窗补齐保存入口**。此前弹窗只有「取消」，改完只能靠页面底部按钮提交；
  现在弹窗内提供唯一的「保存并应用」，保存后直接进入 OpenWrt 原生提交链路。
  保存过程中「保存并应用」「取消」会同时置灰，失败时在弹窗内就地报错并恢复可点。
- **丢包率按国内 / 国外分组统计**。总览页分别给出两组的丢包率，口径为
  `Σ丢包 / Σ发包`（按包加权），并附该组实际发包样本量，不再与等权口径混用。
- **整体加权丢包率**。新增按样本量加权的整体丢包率，与「每目标等权算术平均」
  并列展示：卡片副行同时给出加权值、样本数与未加权值，两个口径都可见、不混淆。
- **后端错误文案的前端兜底翻译**。rpcd 的 ucode 插件没有 LuCI i18n 运行时，
  只能用 `err('invalid host')` 这类英文串回报；现由 `common.localizeError()`
  在 RPC 唯一出口统一查表翻译，覆盖 18 条（含 `invalid value for <键名>` 前缀式）。
- **翻译完整性的三道护栏**。`po/gen_po.py` 直接解析映射表，使「以变量形式传给
  `_()`」的后端文案也能进 po；把 ucode 后端全部 `err()` 字面量与映射表比对，
  后端新增报错却忘了登记时打印告警；再自检映射表重复键与「与核心语言包同名
  却不同译」的 msgid。三项都接进了 CI，输出告警即构建失败。
- **`po/core_msgids.txt`**：冻结「与 LuCI 核心语言包同名、且本插件也在用」的
  26 个 msgid 及其核心译文。核心语言包同名时覆盖插件译文，这份清单让
  「本插件取值必须与核心一致」成为可校验的约束，而不是口头约定。
- **CI 新增 `checks` 作业**（`build` 依赖它）：可执行位核对、翻译完整性、
  守护进程单元测试、图标与视图断言。这四项都对应过真实事故，
  且失败时产物照样能编出来、只是装上不能用。
- `CHANGELOG.md`。

### 变更

- **文档职责重新切分**：`README.md` 中的版本历史一律迁入本文件，
  README 只保留「当前版本的行为说明」；新增徽章、目录与「版本与更新日志」章节，
  明确本文件为变更记录的唯一归口。同时按实际代码校正了三处描述：
  构建产物版本号（`1.0.0-r1` → `1.2.0-r1`）、i18n 包名（`zh_Hans` → `zh-cn` 别名）、
   `address_family` 的取值（全局为 `auto/ipv4/ipv6` 三选一，`both` 仅目标级可用）。
- **保存与应用统一复用 OpenWrt 原生机制**。写入仍走 `uci.set/unset`，只推入 rpcd
  会话、不落盘；提交改由 `ui.changes.apply()`（官方「保存并应用」按钮背后的同一个
  函数）完成，于是自动获得官方的应用进度提示、连接性变更确认和 90 秒失败回滚。
  插件不再自行调用 `uci.apply()`；页面级也不再出现插件自己的「保存并应用」，
  避免与 LuCI 主题渲染的 `cbi-page-actions` 重复。
- **总览页卡片排版**。栅格由 `auto-fill` 的自动列数改为按断点显式列数
  （普通卡片宽屏 3 列 / 中屏 2 列 / 窄屏 1 列，宽卡片 4 列 / 2 列），
  消除「卡片数不被列数整除时最后一行右侧留大片空白」的问题。
- **许可证变更为 GPL-3.0-or-later**（原 GPL-2.0-or-later），
  `LICENSE` 由摘要式声明改为 GPLv3 完整官方文本。
- **脚本可执行位入库修正**。本仓库在 Windows 上开发，git 默认
  `core.filemode=false`、不追踪文件模式，6 个带 shebang 的脚本被记为 `100644`；
  而 OpenWrt 打包用 `cp -fpR` 保留源文件模式，装到设备上就是不可执行的 init 脚本、
  服务直接起不来。已用 `git update-index --chmod=+x` 修正索引模式，并在 CI 中核对。
- `README.md` 同步目录结构、许可证章节与新增排障章节。

### 修复

- **百分比与延迟小数位被整除吃掉**。ucode 有独立的 `int` 类型，且 `int / int`
  是整除：设备实测 `8/10 == 0`、`2530/100 == 25`。格式化函数里
  `((v * m + 0.5) | 0) / m` 两侧皆 int，于是 25 处调用的两位小数全被截成整数、
  丢包率恒为 0。改为把除数写成 double（`m * 1.0` / `100.0`）后，
  实测恢复为 `丢包率 0.7%`、`当前延迟 23.56 ms`、`P95 46.5 ms`。
- **页签显示「目标数」而不是「目标管理」**。中文映射表在总览段另写了一条
  `'Targets': '目标数'`，与菜单段的 `'Targets': '目标管理'` 同名；Python 字典
  字面量里后者覆盖前者且不给任何提示，被覆盖的那条翻译静默失效。
  已删除重复键，并给映射表加上重复键自检。
- **6 处中文用词与预期不符（核心语言包同名覆盖）**。LuCI 核心
  `base.zh-cn.lmo` 与插件语言包同名时会覆盖插件译文，插件写的那条被静默丢弃。
  表现：目标管理页表头显示核心的「卷标」而不是「标签」，`Uptime` 显示核心的
  「运行时间」而不是要表达「在线率」的百分比，`Never` 显示核心的「禁用」
  而不是「从未检测」。已按语境分别处置：改用语境明确的新 msgid
  （`'Label'` → `'Custom label'`、`'Uptime'` → `'Availability'`、
  `'Never'` → `'Never checked'`），或把本插件取值对齐核心
  （`Interval` / `Overview` / `Enabled`）。
- **弹窗「保存并应用」看不见**。弹窗挂在 `document.body` 上、不在 `.nm-root` 子树内，
  于是只定义在 `.nm-root` 的 `--nm-accent` 解析为空，`var(--nm-accent)` 又没有回退值，
  整条 `background` 声明失效 → 白字 + 透明底。已把主题变量作用域扩展到 `.nm-modal`，
  并为关键颜色补上字面回退值。
- **弹窗操作区被折叠到可视区之外**。弹窗内容高于视口时，保存按钮必须滚动弹窗内部
  才能看到；操作区改为 `position: sticky; bottom: 0` 常驻底部。
- **`.nm-btn:hover` 覆盖主按钮底色**。主按钮悬停时变成浅底白字，已补主按钮专用悬停样式。
- 缺失的 3 条新文案（`Weighted loss` / `Lost packets` / `Unweighted`）与
  2 个无障碍标签（`aria-label` 的 `Icon` / `Status`）已补翻译，当前
  `strings: 269, untranslated: 0`。

## [1.1.0] - 2026-09-15

### 新增

- **TCP connect 探测方式**。可全局或按目标选择 ICMP 或 TCP；TCP 测量到指定端口的
  握手耗时，在被丢弃 ICMP 的网络里依然可用。支持全局默认端口与目标级覆盖，
  未填端口且无全局默认值时给出明确提示而非静默失败。

### 变更

- 目标管理页的保存链路改走 OpenWrt 原生 uci，不再经过插件私有的 RPC 通道。

### 修复

- **守护进程 reload 读到已删除选项的旧值**。长驻进程在 reload 时会命中
  `config_load` 的变量缓存，已清掉缓存后再读取。
- **pidfile 假报错**。不再抢 procd 的 pidfile，reload 时也不再盲信 pid。

## [1.0.1] - 2026-09-15

仅构建与 CI 修复，无功能变更。

### 修复

- SDK 构建期 Kconfig 递归依赖导致 ipk / apk 产物缺失。
- 显式设置 `PKG_NAME` 污染批量元数据扫描：上百个 luci 包被钉成同一个包名，
  共用同一个 Kconfig symbol，最终 `package/<name>/compile` 目标消失。
- 缺少「构建系统签名」注释使本包被扫描阶段的文件清单排除，包彻底不进 `.packageinfo`。
- CI 的 i18n 包名手算错误，改为从 `.packageinfo` 推导。
- 删除无效的 i18n 单独编译循环，改为产物存在性校验，消除误导性 skip 警告。

## [1.0.0] - 2026-09-15

### 新增

- 首个版本。procd 托管的 ICMP 延迟 / 丢包 / 连通性监控守护进程，
  连续探测用户定义的目标并按可配置间隔采集。
- LuCI 界面七页：总览、实时监控、延迟曲线、国内 / 国外、历史数据、目标管理、设置。
- 低写入统计：tmpfs 内存环形缓存，配合可选的低频 Flash 长期聚合，兼顾统计精度与 Flash 寿命。
- 动态 SVG 图标与动画系统，环形弧长等视觉元素由真实测量值换算，非固定长度的装饰。
- 中文翻译（`po/zh_Hans`），随 `luci.mk` 打包为独立 i18n 包。

[1.4.1]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.2.1...v1.3.0
[1.2.0]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/LianXia233/luci-app-netmonitor/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/LianXia233/luci-app-netmonitor/releases/tag/v1.0.0
