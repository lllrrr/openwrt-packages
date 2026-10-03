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
