# 前端组件系统（UI Design System）

面向本插件 LuCI 前端的统一交互层：弹层、反馈、浮层、表单与加载态。
**目标不是「好看」，而是让七类交互在 PC / 平板 / 手机、浅色 / 深色、
鼠标 / 键盘 / 触屏下行为一致，且异常可恢复。**

* 零 Lua、零第三方依赖、零构建步骤（直接由 LuCI 加载 ES5 源码）；
* 只使用 LuCI 已有能力（`E()` / `L.Class` / `L.resource`）与浏览器原生 API；
* 全部样式限定在 `.smw-` 作用域，不覆盖 LuCI 主题；
* 视觉语言为 Material Design 3（令牌、形状、状态层），配色优先继承主题变量。

---

## 1. 文件布局

| 文件 | 职责 | 大小量级 |
|---|---|---|
| `htdocs/luci-static/resources/smwcore.js` | 地基：层级栈、滚动锁、焦点陷阱、锚定定位、SVG 图标、断点、幂等样式注入 | ~380 行 |
| `…/smwoverlay.js` | Dialog / Drawer / BottomSheet / Confirm | ~640 行 |
| `…/smwfeedback.js` | Toast / Loading / Progress / Skeleton | ~420 行 |
| `…/smwform.js` | 表单控件、字段包装、校验器 | ~700 行 |
| `…/smwpopover.js` | Popover / Tooltip | ~230 行 |
| `…/smartmwan.js` | 业务零件（四态、卡片、表格、徽标）+ 组件聚合入口 | ~450 行 |
| `…/smartmwan/smartmwan.css` | 设计令牌 + 页面级样式 | ~1100 行 |
| `…/smartmwan/overlay.css` | 弹层/反馈/浮层样式 | ~800 行 |

**为什么拆成五个模块而不是一个文件**：LuCI 的 `'require x'` 会把模块名当作
构造函数的**参数名**注入（`new Function(deps.concat(src))`），因此模块名必须是
合法标识符——带点或斜杠的名字（`smartmwan.ui.core`）会直接抛 `SyntaxError`。
所以模块一律平级放置，用短名互相引用。

---

## 2. 设计令牌

全部定义在 `body, .smw-panel, .smw-root` 上（弹层挂在 `body` 下，靠继承拿到同一套值）。
**颜色优先取 LuCI 主题变量，缺失时落 MD3 基线**，因此换主题不会失配，也不强制用户接受某个品牌色。

| 类别 | 令牌 | 取值 |
|---|---|---|
| 主色 | `--smw-primary` / `--smw-on-primary` | `var(--primary-color, #6750a4)` |
| 表面 | `--smw-surface` / `--smw-surface-container` / `--smw-surface-container-high` | 主题背景三档 |
| 文字 | `--smw-on-surface` / `--smw-on-surface-variant` | 主题文字两档 |
| 描边 | `--smw-outline` / `--smw-outline-variant` | 主题边框两档 |
| 语义 | `--smw-ok` `--smw-warn` `--smw-bad` `--smw-info`（含 `-bg`） | 自包含，不随主题漂移 |
| 间距 | `--smw-space-1…6` | 4 / 8 / 12 / 16 / 24 / 32 px |
| 圆角 | `--smw-radius-card` `-field` `-chip` `-dialog` `-sheet` | 12 / 4 / 8 / 24 / 28 px |
| 阴影 | `--smw-shadow-1..3` | 三级 |
| 控件高度 | `--smw-control-h` / `--smw-control-h-touch` | 40 / 48 px |
| 动效 | `--smw-dur-fast/-med/-slow` + `--smw-ease`/`--smw-ease-emph` | 120 / 220 / 280 ms |
| 层级 | `--smw-z-toast: 5000`、`--smw-z-tooltip: 5200` | 弹层由脚本从 2000 起分配 |
| 焦点 | `--smw-focus-ring` / `--smw-focus-offset` | `3px solid primary` / `2px` |

语义色为什么自包含：状态色必须稳定——「健康 / 故障」不能因为换了套主题就变色，
否则同一张图在不同用户屏幕上表达不同结论。

---

## 3. 组件 API

统一入口：`smartmwan.ui.<组件>`；页面上常用的兼容别名见 §8。

### 3.1 Dialog（居中模态）

```js
var ctl = smw.ui.Dialog.open({
	title: '均衡参数',
	description: '保存后仍需「应用」才会下发到内核。',
	size: 'md',                    // sm 400 / md 560 / lg 840 / xl 1080
	body: [ node, node ],          // 节点 / 字符串 / 数组（自动展平）
	actions: [
		{ label: '取消', variant: 'text', value: null },
		{ label: '保存', variant: 'filled', loadingText: '保存中…',
		  onClick: function (ctl) { return save(); } }   // 返回 Promise
	],
	dismissible: { scrim: true, esc: true, button: true },
	mobile: 'auto',                // auto(转底部面板) | dialog(保持居中) | fullscreen
	beforeClose: function (reason) {
		return dirty ? '有未保存的改动，确定放弃？' : true;   // true/false/字符串/异步
	},
	onClose: function (reason, value) { /* ... */ }
});
```

* `ctl.promise` —— 关闭时 resolve（动作按钮的 `value`，取消类为 `null`）；
* `ctl.close(value, reason)` —— 代码关闭（**绕过** `beforeClose`）；
* `ctl.requestClose(value, reason)` —— 走守卫的关闭（等价于用户点关闭）；
* `ctl.setState('idle'|'loading'|'success'|'error', { message })` —— 就地状态区；
* `ctl.setTitle(text)`、`ctl.body` / `ctl.footer`（节点引用）。

**提交语义**：`onClick` 返回 Promise 时，按钮进入加载态、全部动作按钮禁用；
resolve 后自动关闭（除非 `closeOnSuccess: false`），reject 则**不关闭**、
错误显示在状态区、按钮恢复可点（可重试）。`busy` 期间重复点击一律丢弃。

### 3.2 Drawer（右侧抽屉）

```js
smw.ui.Drawer.open({
	title: '配置编辑器',
	description: '整份配置（JSON）',
	width: 560,                    // number | '520px'
	body: [ textarea ],
	footer: node,                  // 可选：动作区上方的一行说明
	beforeClose: ..., onClose: ...,
	actions: [ ... ]
});
```

手机端（< 768px）自动转全屏面板，不机械缩小 PC 抽屉。

### 3.3 Bottom Sheet

```js
smw.ui.Sheet.open({
	title: '快速操作',
	body: node,
	actions: [
		{ label: '立即回切', variant: 'filled', value: 'failback' },   // 无 onClick = 菜单式
		{ label: '取消', variant: 'text', value: null }
	]
}).then(function (v) { /* v 为所选 value，取消为 null */ });
```

* 顶部拖动把手（`dragHandle: false` 可关），下滑 > 120px 或速度 > 0.5px/ms 关闭；
* 只从头部拖动 —— 内容区的滑动留给内部滚动，两者不冲突；
* 适配 `env(safe-area-inset-bottom)`；键盘弹出时按 `visualViewport` 收窄面板。

### 3.4 Confirm（危险确认）

```js
smw.ui.Confirm.show({
	title: '停用服务',
	message: '停用后本插件会清空自己的内核对象，流量交还系统原路由。',
	details: [ '路由表与 nft 链会被清空。', '已建立的连接按 conntrack 继续走。' ],
	severity: 'danger',            // normal | danger | critical
	disconnectRisk: true,          // 额外提示「可能中断当前管理连接」
	requireType: '恢复默认',        // critical：要求原样输入才允许确认
	confirmText: '确认停用',
	onConfirm: async function () { /* 提交；失败自动留在窗内可重试 */ }
});   // → Promise<boolean>，取消/ESC/遮罩/关闭一律 false
```

**约定（防误操作）**：

* 初始焦点落在「取消」（`trapFocus` 优先取第一个动作按钮），回车不会误确认；
* 危险等级不只靠颜色：标题前有图标、按钮文字是动词（「确认停用」而非「确定」）；
* `disconnectRisk` 用于重启/重拨/断网类操作，文案明确说明「页面失联后等 30 秒重连」；
* `critical` 要求输入指定文字，输入框内容与确认按钮的 `disabled` 联动。

### 3.5 Toast / Snackbar

```js
smw.ui.Toast.success('已写盘（3 项变更）');
smw.ui.Toast.error('应用失败：事务 txn-9 未提交');
smw.ui.Toast.warning('主线路 3 次探测失败', { duration: 8000 });
smw.ui.Toast.info(node);                                  // 也可以直接传节点
smw.ui.Toast.show({
	type: 'warning', message: '已导入配置',
	action: { label: '查看变更', onClick: fn },              // 可选操作
	key: 'import-done',                                    // 去重键（默认 type|text）
	duration: 6000, persistent: false, dismissible: true
});
var task = smw.ui.Toast.progress({ message: '正在提交事务…' });
task.done('事务 txn-1：已提交');   // 原地变成功态并按 4s 关闭
task.fail('回滚失败：…');          // 原地变错误态并常驻
```

* **去重**：同 `key` 的通知不新建，只顶到最前、重置计时并闪一下；
* **上限 4 条**，超出淘汰最旧的（进行中的任务不淘汰——删掉会让用户以为任务没了）；
* **错误默认常驻**（需手动关）：闪一下就消失的错误等于没提示；
* 悬停暂停计时；`aria-live="polite"`，错误用 `role="alert"` 立即播报。

### 3.6 Loading / Progress

```js
var reg = smw.ui.Loading.region(el, { text: '正在读取…', onRetry: reload });
reg.update('仍在读取…'); reg.done(); reg.fail('读取失败');

smw.ui.Loading.skeleton({ rows: 5 });                      // 骨架屏（装饰，对读屏隐藏）
var p = smw.ui.Loading.progress({ label: '写入内核对象' }); // 无 value = 不确定
p.set(40); p.indeterminate(); p.label('已完成');
smw.ui.Loading.busy(btn, true, '保存中…');                  // 按钮内加载
```

**不得伪造进度**：`value` 为 `null` 时走不确定动画，且不设 `aria-valuenow`。
没有真实数值的场景（等待后端回执）一律用 `Toast.progress`，不画假百分比。

### 3.7 Popover / Tooltip

```js
var pop = smw.ui.Popover.open(anchorEl, {
	content: node, placement: 'bottom-start', offset: 8,
	onClose: function (reason) { /* 'outside' | 'esc' | 'replace' | 'program' */ }
});
pop.close(); pop.reposition();

var detach = smw.ui.Tooltip.attach(el, '命中数来自内核 counter', { placement: 'top', delay: 500 });
detach();
```

* 挂 `body` + `position: fixed`：逃逸父级 `overflow: hidden`（卡片/表格常见）；
* 首选方向放不下时翻转，仍放不下则夹取到视口内（8px 留白）；
* Popover 是**非模态**：接管焦点但不锁页面；外部 `pointerdown` 与 ESC 关闭；
* Tooltip 触屏设备无 hover：改为点击切换，且阻止该次点击继续冒泡；
* 滚动时自动收起重定位（气泡是 fixed，不跟随内容）。

### 3.8 表单

```js
var f = smw.ui.Form.field({
	label: '网关地址', required: true,
	control: smw.ui.Form.ip({ value: '192.168.1.1', version: 4 }),
	help: 'IPv4 地址，四段 0–255。',
	validate: function (v) { return smw.ui.Form.validators.ipv4(v) ? null : '不是合法的 IPv4'; }
});
panel.appendChild(f.el);          // f.input 是原始控件；f.setError()/clearError()/validate()

smw.ui.Form.validate([f1, f2]);   // 表单级：返回 {ok, field}，失败自动聚焦
```

控件一览：`text` `password`（带显示切换）`number` `ip` `port`（支持区间）
`search`（带清除）`textarea` `select` `searchSelect`（可搜索下拉）
`radio` `checkbox` `switch` `group`（可折叠，收起不销毁内容）。

**返回值的坑（已加显式报错）**：`password / search / searchSelect / radio /
checkbox / switch` 返回 `{ el, input }`，放进 `field()` 时要取 `.el`；
传错会抛 `Form.field: control 必须是 DOM 节点…` 而不是在 `appendChild` 处
炸出一句看不懂的 `parameter 1 is not of type Node`。

校验器：`validators.ipv4` `ipv6`（支持 `::` 压缩与末尾内嵌 v4）`port`
`intBetween(min,max)`。**前端校验只为即时反馈，后端仍然权威**。

---

## 4. 响应式策略

移动优先，两个断点：**768px（手机）** 与 **1024px（平板）**。

| 场景 | ≥1024（PC） | 768–1023（平板） | < 768（手机） |
|---|---|---|---|
| Dialog | 居中，四档宽度 | 宽档收窄到视口内 | 默认转**底部面板**（`mobile:'dialog'` 时保持居中，宽度 `100vw-32px`） |
| Drawer | 右侧 480（可配 560） | 最宽 88vw | 全屏面板 |
| Sheet | 居中限宽 640 | 同上 | 全宽、94dvh |
| Toast | 右下 400 宽 | 右下 | 底部全宽 + 安全区 |
| 表单 | 双列（`auto-fit minmax(240px)`） | 自动降为单列 | 单列 |
| 按钮组 | 横排 | 横排 | 竖排全宽，48px 高 |

关键实现细节：

* Dialog 手机端变形只靠一条媒体查询覆盖 `inset/margin/width/border-radius/transform`，
  **DOM 与 JS 不变**——不需要为移动端另建一套组件；
* 组件内部统一 `box-sizing: border-box`（`.smw-overlay *` 等作用域内），
  否则 `width:100%` + 12px 内边距会把输入框顶出 360px 屏幕（实测过）；
* 安全区：Sheet 底部 `env(safe-area-inset-bottom)`，同时给底部操作栏留白；
* 虚拟键盘：监听 `visualViewport.resize`，视口变矮 > 80px 时按 94% 高度收窄面板。

---

## 5. 无障碍与焦点

| 要求 | 实现 |
|---|---|
| 语义 | `role="dialog"` + `aria-modal` + `aria-labelledby`/`aria-describedby` 指向真实标题与描述 |
| 初始焦点 | 指定 > 第一个输入控件 > 第一个动作按钮 > 面板；**不落关闭按钮** |
| 焦点陷阱 | Tab/Shift+Tab 在面板内循环（`smwcore.trapFocus`） |
| 焦点恢复 | 关闭后回到打开前的元素 |
| 键盘关闭 | ESC 只作用于**最上层**（嵌套弹窗不会一次全关） |
| 表单 | `label for`、`aria-describedby`（说明 + 错误行）、`aria-invalid`、`aria-required` |
| 通知 | `aria-live="polite"`；错误 `role="alert"` |
| 状态不靠颜色 | 徽标有状态点 + 文字；确认框有图标 + 动词按钮；错误行有文字 |
| 减少动效 | `prefers-reduced-motion: reduce` 关闭全部过渡与动画 |
| 可见焦点 | `:focus-visible` 统一 3px 主色环 + 2px 偏移 |

---

## 6. 生命周期与清理

每个弹层实例负责自己的四件事，关闭时全部归还：

1. **层级**：`smwcore.pushLayer/popLayer` 维护栈，关中间层会重排剩余层的 z-index，
   不留空洞；
2. **滚动锁**：引用计数（嵌套弹窗只锁一次），关闭时恢复 `body.overflow` 与
   `padding-right`（滚动条宽度补偿，防止页面横跳）；
3. **监听器**：统一登记在 `smwcore.Listeners`，`release()` 一次解绑（含 document 级
   keydown、pointer、visualViewport）；
4. **DOM**：关闭动画（220 ms）结束后摘除，并有定时器兜底——`prefers-reduced-motion`
   下 `transitionend` 不触发时不会卡住。

状态机：`open → closing → closed`，`closed` 后 `close()` 幂等；
`busy` 期间拒绝关闭（半提交状态比「点了没反应」更难排查）。

页面切走时调用 `smw.ui.Dialog.closeAll()` 兜底（当前视图未使用——它们都是单页操作，
无跨页弹层）。

---

## 7. 安全边界

* 组件代码中**没有任何 `innerHTML` 赋值**（有静态断言把关），用户输入、
  RPC 返回值、后端错误消息一律走 `textContent` / 文本节点；
* 前端显示状态不替代后端权限：ACL、RPC 方法、UCI 结构均未改动（见
  `root/usr/share/rpcd/acl.d/`）；
* 不把配置写进 URL、localStorage 或 console。

---

## 8. 从旧 API 迁移

旧调用仍然可用（内部转发到组件系统），但新代码请用 `smw.ui.*`：

| 旧 | 新 | 说明 |
|---|---|---|
| `ui.addNotification(null, node, 'info')` | `smartmwan.notify(node, 'info')` 或 `smw.ui.Toast.info(node)` | 已全量迁移到 Toast（7 个视图共 51 处） |
| `smw.confirm({...})` | `smw.ui.Confirm.show({...})` | 语义相同，新增 `severity`/`requireType`/`disconnectRisk`/`onConfirm` |
| `smw.sheet({...})` | `smw.ui.Sheet.open({...})` | 同一实现 |
| `smw.button(label, {variant, click})` | 不变 | 内部转 `smwcore.button` |
| `smw.field(label, control, help)` | `smw.ui.Form.field({label, control, help, validate})` | 新版本带 label 关联、错误行与校验 |
| `smw.number/select/checkbox` | `smw.ui.Form.number/select/switch` | `checkbox` 是方框多选，`switch` 是功能开关，语义不同不要混用 |

---

## 9. 验证方法

### 9.1 结构/交互冒烟（无需路由器）

```sh
node scripts/ui-smoke.js
```

用最小 DOM stub 执行**真实模块代码**，194 项断言覆盖：视图渲染、弹层尺寸/aria/
焦点/ESC/遮罩/守卫/重复提交/失败恢复/层级/清理、Toast 去重与上限、Popover 定位与
外部点击、IP/端口校验边界、表单 aria 关联、Loading 不伪造百分比、静态约束
（选择器作用域、`!important` 数量、`innerHTML` 零使用、Makefile 安装清单）。

### 9.2 视觉核对（真实浏览器）

```sh
python3 -m http.server 8080          # 仓库根目录
# 打开 http://localhost:8080/scripts/ui-preview.html
```

预览页加载的是同一批模块与同一份 CSS，只替换成最小 LuCI 运行时。
`?open=dialog|drawer|sheet|confirm` 自动打开对应弹层，`&debug=1` 打印布局尺寸
（用于排查溢出/裁切）。切换系统深色外观核对暗色。

本次实现已用 headless Chromium 在 1280 / 500 / 360 三种视口与深色模式下截图核对
（Dialog、Drawer、Sheet、Confirm、表单全量）。

### 9.3 真机仍需人工确认的项目

* LuCI 主题变量在本机主题下的实际取值（`--primary-color` 等是否存在）；
* 手机浏览器（iOS Safari / Android Chrome）的安全区与键盘行为；
* 触屏拖拽关闭的手感阈值（当前 120px / 0.5px·ms⁻¹）；
* 真实 `smw-` 页面里的长表单（当前最长的是「系统设置」8 个字段）。

---

## 10. 已知限制

1. **动画时长写死在 CSS**（220/280 ms），JS 侧关闭等待用 220 ms + 定时器兜底；
   若主题覆盖了 `--smw-dur-*`，关闭会等满 220 ms（视觉上无差异）。
2. **Dialog 手机端不做拖拽关闭**：只有 Sheet 有拖动把手与手势。被动变形的
   Dialog 显示把手会承诺一个不存在的交互。
3. **Popover 单例**：同时只允许一个浮层，打开第二个会关掉第一个。
4. **Toast 上限 4 条**，超出淘汰最旧的非进行中通知——极高频错误场景下早期
   错误可能被挤掉（错误本身常驻，用户仍能从页面状态看到失败）。
5. **`searchSelect` 的选项在打开时快照**：打开后外部数据变化不会实时反映。
6. **未接入的组件用法**：`Drawer` 目前只用于「配置编辑器」，`Dialog` 宽屏只用于
   「待下发变更」详情；其余页面仍是卡片内联编辑（改动风险最小化的选择）。
7. **真机未验证**：见 §9.3。
