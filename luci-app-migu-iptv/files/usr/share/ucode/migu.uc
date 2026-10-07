#!/usr/bin/ucode
// ============================================================
// migu.uc — 咪咕直播源转发（OpenWrt 原生实现，无 Node/Docker 依赖）
//
// 在路由器上监听一个 HTTP 端口，把咪咕视频的直播频道转成 TV-BOX 能直接
// 订阅的标准 M3U 播放列表，并提供「按需取流」端点 /ch/<pID>：
//   1. /m3u、/txt —— 输出频道列表（分组、台标、频道名、可选 EPG）
//   2. /ch/<pID>    —— 播放时按需换取咪咕流地址，302 重定向到最终 HLS
//   3. /health      —— 存活与运行统计（连接数、缓存命中率、解析耗时）
//
// 配置与管理全部在 LuCI「服务 → 咪咕直播」里完成（ubus 侧见
// /usr/share/rpcd/ucode/migu），本进程只做流媒体后端，不再自带管理网页。
//
// 画质说明：
//   游客（不填账号）最高 540p；免费账号到 720p；蓝光 1080p / 原画 / 4K 需 VIP。
//   token 是咪咕登录态，等同账号密码，务必只在自家路由器上保存。
//
// 参考实现：github.com/akiralereal/iptv（Node.js 版），本项目用 ucode 重写，
// 保留其核心算法：频道列表接口 + playurl 签名 + ddCalcu 解密 + 302 跟随。
//
// 用法: ucode /usr/share/ucode/migu.uc
// 配置: /etc/config/migu (UCI)
//
// ---- 1.3.0 优化记录（每项都在这台路由器上实测过，数字为实测值）----
//   1. MD5 改用 ucode 原生 digest 模块：旧写法每次签名 fork 3 个进程
//      （printf|openssl|awk），一次取流要签 2 次 —— 实测 openssl 单次 13ms，
//      合计 6 个进程约 30~40ms，且 fork 期间占住单线程事件循环。
//      新写法零进程；已用真实签名输入与 openssl 逐字节比对一致。
//   2. ddCalcu 里的 `date +%Y%m%d` 改为 localtime()：该值只用到年份首位数字，
//      没必要 fork。date 单次约 1ms，省掉一次进程创建。
//   3. resolveFinal 从「每跳 fork 一次 curl」改为 curl -L 一次跟完整条链：
//      旧写法最坏 fork 6 次，每跳都要重做 DNS+TCP（实测 50~190ms/跳）；
//      实测跳转链通常 0~1 跳，新写法固定 1 个进程，并用 --max-filesize
//      兜底，避免万一落到大文件上白拉流量。
//   4. 取流地址缓存从固定 60 秒改为可配置（默认 300 秒）：实测命中缓存
//      只要 1.7ms，未命中要 480~780ms（版权频道走回落链 1000~1220ms），
//      相差约 280 倍 —— 换台快慢几乎只由「缓存冷不冷」决定。
//   5. connections 数组只增不减（每来一个连接就永久驻留，还持有连接缓冲），
//      已改为 closeConn 时摘除，并加并发上限（公网端口会被扫）。
//   6. 预热定时器没保存句柄（uloop.timer 是一次性的，句柄被回收后回调
//      可能静默失效），已改为模块级持有引用。
//   7. 新增失败结果短缓存（默认 15 秒，可设 0 关闭）：无效/失效频道原本
//      每次请求都要重新解析（实测 1.4 秒），连点会反复打咪咕接口。
//   8. 新增 EPG：x-tvg-url 原本写死空串，tvg-id 直接用了中文频道名
//      （CCTV1综合），与标准 EPG 的频道 id（CCTV1 / 东方卫视…）对不上，
//      所以一直拿不到节目单。现在后台拉取 EPG 频道 id 表（不阻塞请求），
//      并按「最长前缀」把咪咕频道名映射到标准 id。
//   9. 新增「最近频道预热」：后台定时刷新最近看过的若干频道，让回头换台
//      也走缓存；只在服务空闲时刷新，不抢交互请求的事件循环。
//  10. debug 开关原本定义了却没有任何用处，现在真的会打印取流过程与耗时。
//
// ---- 1.3.1 修正 ----
//  11. 修 EPG 抓不到频道 id（1.3.0 里 epgIds 长期停在 1，tvg-id 映射整条失效）。
//      根因不是正则、不是网络、也不是最长前缀匹配，而是 **busybox 的正则工具
//      直接读网络管道时会丢数据**。同一台路由器、同一个源、连续多轮实测：
//        curl … | wc -c           → 7869907 字节，3/3 稳定
//        curl … | grep -o '<channel…' | … | sort -u → 0/20/1/0/0/0 行
//        curl … | sed … | sort -u                    → 124/0/124 行
//        先 -o 落盘，再 grep -o 同一份文件            → 132 行，稳定
//        先 -o 落盘，再 sed     同一份文件            → 124 个唯一 id，稳定
//      字节流本身没问题（wc -c 一直准），是「边收边匹配」丢行。修法：先落盘
//      再解析，并改用 sed（124/124/124，比 grep -o 更准）。
//      顺带：拉取失败时不再清空 id 表，改为沿用上一次的结果。
//  12. /health 新增 chFallback 计数。「咪咕失败 → 外部源顶替成功」这条路径
//      不会把失败缓存条目改写成成功（刻意不缓存失败，见 resolveStream 注释），
//      所以版权盾时段 streamCacheOk=0 / streamCacheFail=N 容易被误读成「全挂了」。
//  13. 修前缀匹配误吞：EPG 源里有杂项 id `C`（1 字符）和 `DTV`（3 字符），
//      实测 `C` 把所有 CGTN* 与 CETV4 吞成了 tvg-id="C"（8 行，节目单指到
//      不存在的频道）。加上最短长度阈值 4（真实频道 id 最短 5 字符，共 122 个
//      全部 >= 5），并对「完全相同」放行，避免误吞又不漏配。
//  14. EPG 拉取失败改为 5 分钟后重试，不再傻等一个刷新周期（默认 12 小时）。
//      实测该源会偶发 TLS 连接失败（curl exit=35，同一秒手工重跑即成功），
//      首拉若踩中就是整整 12 小时没有 tvg-id 映射 —— 实测确实发生过一次
//      （日志：`EPG 拉取失败…tvg-id 将退回频道名`，随即 /m3u 的 tvg-id
//      全部退回中文名）。同时把失败时的日志说清楚是「沿用上一次结果」。
//  15. 两个把进程搞挂的 ucode 语言坑（都是实测踩出来的，务必别重犯）：
//      a) **ucode 没有 `undefined` 这个全局变量**。写 `x !== undefined` 不报
//         编译错，但运行时抛 `Reference error`。本次就因为在定时器回调里写了
//         `delayMs !== undefined`，异常无人接管 → **进程被直接带走**，
//         表现为服务反复重启、/health 完全无响应，日志只有一行
//         `In scheduleEpgRefresh(), file … line 1041, byte 27`。
//         判断「参数没传」要用 `type(x) === 'int'` 或 `x === null`。
//      b) **ucode 不支持 try/catch/finally，只有 try/catch**。写上 `finally`
//         是编译期 `Syntax error: Unexpected token`，整份文件都跑不起来。
//      配套结论（实测）：uloop 定时器回调里抛出的异常**会终止整个进程**
//      （探针里排在后面的定时器再也不会执行）。所以每个定时器回调都必须
//      用 try/catch 兜住，并在 catch 里留下重排下一次的退路。
//  16. **ucode 不做函数提升，函数体只能引用文件里更早声明的名字。**
//      实测四组对照：callee 定义在 caller 之后（即使调用发生在全部定义完之后）
//      → 运行时抛 `left-hand side is not a function`；callee 在前 → 正常；
//      函数声明自引用 → 正常；把后定义的函数「当值传递」→ 正常。
//      限制只在「函数体内按名字直接调用」这一种写法上。这正是 15(a) 那次
//      崩溃的同源问题（scheduleEpgRefresh 体内调用了定义在其后的 epgTickFn）。
//      修法：把互相调用的两个函数合并成一个自递归函数；并写了
//      `D:\AI\_mt\audit-fwd.js` 做全文静态审计（带正向对照，确保审计本身有效）。
//  17. EPG 拉取全面加固（本轮 epgIds 反复为 0 的真正根因）：
//      a) 该源本身不稳：连续 6 次下载有 3 次中途断开（curl rc=56 / rc=35，
//         得到 635064 / 69669 / 0 字节，完整应为 7869907）。
//      b) **`curl -o` 失败时也会把不完整的文件留在磁盘上** —— 截断到 635KB
//         的那份只能解析出 13 个 id（完整 124 个）。而 sh() 拿不到退出码，
//         所以必须自己校验：判据是文件收尾有 `</tv>`，不满足就整份重下。
//      c) 关键是加 **`--retry-all-errors`**：curl 默认的 --retry 只重试连接
//         阶段的错误，对「已开始传输后断开」不作为，而 rc=56/35 恰好是后者。
//         实测对比：`-m 25 --retry 1` + shell 循环 3 轮 → 4 次里失败 1 次；
//         `--retry-all-errors --retry 4 --retry-delay 2` → 4/4 完整。
//         另外服务端支持 br，加 `--compressed` 缩小传输量、压低失败窗口。
//         部署后连跑 5 次重启，EPG 首拉 5/5 成功（此前为 0/若干）。
//      d) 拉取改为**游离后台任务 + 定时器轮询**，不再用 sh() 同步等待。
//         sh() 是 popen 同步读，而这是单线程事件循环：同步等 3 秒等于所有
//         播放请求一起排队 3 秒，带重试后最坏约 400 秒，足以毁掉换台体验。
//         整条命令用「( … ) >/dev/null 2>&1 &」包起来后 popen 立刻返回
//         （实测 0.00s），事件循环心跳照常。实测效果：EPG 拉取窗口内
//         /m3u 与 /ch 均为 0.010s / 0.002s，完全不受影响。
//      e) 临时文件名带「代际」后缀，避免超时兜底后又起一轮时两轮后台任务
//         互相覆盖同一份临时文件。
//
// ---- 1.4.1 修正 ----
//  18. 修「并发超限时回 503，但约 58% 概率客户端收不到响应体」。
//      现象：客户端表现为 `ECONNRESET` 且读到 0 字节，日志里 rejected 计数却
//      正常增长 —— 服务端确实发了 503，只是没送达。
//      成因：旧写法 `peer.send(503)` 后**立刻** `peer.close()`，而服务端从头到尾
//      没 recv() 过这个连接。Linux 在 close() 时若接收队列还有未读数据，会发
//      **RST 而不是 FIN**，RST 会让对端丢弃已到达的接收缓冲，于是刚写出去的
//      503 一起被丢掉。
//      判别实验（每变体 3 轮 × 20 次 = 60 次，EXPECT 218 字节）：
//        - 连上后一个字节都不发（接收队列为空）→ **60/60 完整，丢包 0**
//        - 连上后立即发请求（接收队列非空）  → **25/60 完整，丢包 35（58.3%）**
//      两者唯一差异就是接收队列是否为空，理论成立。
//      修法（三步，缺一不可）：
//        a) 发包前用 `recv(8192, socket.MSG_DONTWAIT)` 把已排队的请求字节读干净
//           （实测读空返回 null 且 error() 为 EAGAIN，不会阻塞事件循环）；
//        b) 发完 503 先 `shutdown(socket.SHUT_WR)` 再 close —— shutdown 会老实
//           发 FIN（实测客户端读到 len=0 的干净 EOF），避免 close() 因残留数据
//           再次触发 RST；
//        c) shutdown 之后再补读一轮，覆盖「首次 recv 到 close 之间对端又补发
//           字节」的窗口（TCP 分段/慢启动都可能造成）。
//      读循环一律限次（16 轮），保证单线程事件循环不会被持续的灌数据卡住。
//      实测 socket 能力（在路由器临时口 18799 上验证，不打扰 8788）：
//        `socket.MSG_DONTWAIT = 64`、`socket.SHUT_WR = 1`、`socket.SO_LINGER = 13`
//      注意：`import { socket } from 'socket'` 会报 `Module does not export socket`，
//      必须写 `import * as socket from 'socket'`。
//
// ---- 1.5.0 深度优化（研读 8 个开源 IPTV 项目后提炼，均有实测依据）----
//  19. 取流成功缓存默认 300 → 1800 秒（上限放宽到 10800 秒）。
//      依据：akiralereal/iptv 的咪咕模块实测上游签名地址约 3 小时有效；
//      我们的实测里缓存命中 1.7ms vs 未命中 480~780ms，把缓存放宽到 30 分钟
//      能大幅减少重复打咪咕接口，又不至于让过期地址进入播放器。
//  20. 外部备用源健康检查升级为「两段式」（借鉴 awesome-iptv / IPTVChecker）：
//      第一段拉 m3u8 播放列表头，校验 HTTP 2xx/3xx 且内容含 #EXTM3U；
//      第二段解析出首个分片（master 列表则先递归到子列表），请求其前 32 字节，
//      校验首字节为 TS 同步字节 0x47 或 fMP4 box 头（ftyp/styp/moov）。
//      旧写法只校验播放列表头，会把「列表能下但分片全挂」的假阳性源判成可用。
//  21. 慢源临时禁用（借鉴 my-tv）：同一外部源连续失败 3 次后临时禁用 10 分钟，
//      避免每次降级都被同一个慢源拖累；禁用期满自动清零重新探测。
//  22. 外部源检查可配 User-Agent（新配置项 extUserAgent，默认空 = curl 默认）。
//      部分防盗链源只认播放器 UA（如 "VLC/3.0.18 LibVLC/3.0.18"），对 curl
//      默认 UA 返回 403/451；配置后仅影响外部源检查与分片探测，不影响取流。
//  23. EPG 条件更新：保存上次响应的 ETag，下次拉取带 If-None-Match。
//      实测源（live.fanmingming.cn/e.xml）无 Last-Modified 头，只有 ETag，
//      所以用 ETag。源未变化（HTTP 304）时直接沿用现有 id 表，
//      不再每次下载 7.9MB 的 e.xml 再全量解析（借鉴 awesome-iptv）。
//      注意：条件请求只在内存已有 id 表时发送——进程刚重启时 RAM 里
//      没有 id 表，304 会让我们拿不到数据，所以首轮必须全量下载。
// ============================================================

'use strict';

import { readfile, writefile, popen, access, mkdir, error, unlink } from 'fs';
import { md5 } from 'digest';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as uci from 'uci';

// ---------- 日志 ----------
function logMsg(level, msg) {
	printf('[migu] %s: %s\n', level, msg);
}
function logInfo(msg) { logMsg('info', msg); }
function logErr(msg) { logMsg('error', msg); }

// ---------- 常量 ----------
const APP_NAME = '咪咕直播';
const APP_VERSION = '1.5.0';
const DEFAULT_PORT = 8788;

// 分组显示顺序：按正常电视台习惯，央视（CCTV1 开头）排最前，其余靠后。
// 未列出的分组按咪咕原始顺序追加到末尾。
const GROUP_ORDER = ['央视', '卫视', '地方', '体育', '影视', '综艺', '新闻', '纪实', '少儿', '教育', '熊猫'];

// 版权 / 会员限制的友好提示（用于取流失败时给用户看得懂的原因）
//
// 关于 COPYRIGHT_SHIELD_INVALID：这句提示以前写的是「需登录咪咕体育会员」，
// 但实测这个 rid 出现在 **CCTV5** 上而 CCTV5+ 与其余 7 个体育频道全部正常，
// 说明它**不是账号权限问题**，而是内容侧的时段性版权限制 —— 咪咕返回的
// playCode 403001006 原文是「节目播出调整，换个内容看看吧！」。
// 咪咕在有独家赛事转播（五大联赛 / NBA 等）的时段会锁 CCTV5，
// 无赛事时段则正常放行。提示必须说实话，否则用户会去白折腾会员。
const ERR_HINT = {
	'COPYRIGHT_SHIELD_INVALID': '该频道当前受版权限制（通常是有独家赛事转播的时段被锁），过一段时间再试或改用 CCTV5+ 观看',
	'TIPS_NEED_MEMBER': '该频道需要咪咕会员权限',
	'PROGRAM_OFFLINE': '节目已下线或暂未播出',
};

// ---------- 全局状态 ----------
let cfg = null;            // 运行时配置
let connections = [];      // 活跃连接
let chanCache = { at: 0, cates: null, channels: null };  // 频道列表缓存
let streamCache = {};      // pid -> { url, at } 取流结果短缓存
// 外部源可用性缓存：url -> { ok, at }
// ok=true 缓存 300 秒（源可用，复用结果）；ok=false 缓存 60 秒（避免反复打失效源）
let extSourceCache = {};
// 外部源连续失败计数与临时禁用状态（慢源临时禁用，见 checkExternalSource）
let extFailCount = {};   // url -> 连续失败次数
let extDisabled = {};    // url -> 禁用开始时间

// 运行统计（/health 暴露，用于观察优化效果）
let stats = {
	reqTotal: 0,        // 总请求数
	chTotal: 0,         // /ch/<pid> 请求数
	chHit: 0,           // 其中命中取流缓存
	chMiss: 0,          // 其中走了完整解析
	resolveMsSum: 0,    // 未命中解析累计耗时（毫秒），用于算平均值
	chFallback: 0,      // 其中走了降级链（版权盾回落 / 外部源）才成功的
	m3uTotal: 0,        // /m3u|/txt 请求数
	denied: 0,          // 被访问控制拒绝数
	rejected: 0,        // 因并发上限被拒数
	startedAt: time(),
};

// EPG 频道 id 表（后台刷新，用于把咪咕中文频道名映射成标准 tvg-id）
let epgState = { ids: null, at: 0, source: '', ok: false };
// EPG 下载/解析用的临时文件与状态（EPG_TMP/EPG_IDS/EPG_DONE/epgPending 定义见 epgStartFetch）

// 最近访问过的频道（用于后台预热，最新在前，去重，最多 RECENT_MAX 个）
let recentPids = [];
const RECENT_MAX = 12;
// 上次预热时的 recentPids 指纹，用于「列表没变就不干活」
let lastWarmedKey = '';

// 模块级定时器句柄。
//
// 必须持有引用：uloop.timer() 返回的句柄一旦被 GC 回收，回调和它绑定的
// 资源就可能被一并释放，表现为「定时器静默失效」；而且 timer 默认只跑
// 一次，要在回调末尾重新排下一次。（同机 WorkBuddy 中转踩过同样的坑。）
let warmTimer = null;
let epgTimer = null;
let recentTimer = null;

// ---------- 配置 ----------

// 解析外部源文本 → [{label, url}]
//
// 接受两种写法（兼容 LuCI TextArea 的手工输入）：
//   1. 每行一条：    标签|URL
//                    标签2|URL2
//   2. 用 ; 或换行混合分隔：标签|URL;标签2|URL2
// 空行、# 开头的注释行、缺 URL 的行直接丢弃。
//
// 注意：必须定义在 loadConfig 之前 —— ucode 没有函数提升，
// 定义在调用点之后会报 "access to undeclared variable"。
function parseExternalSources(text) {
	let out = [];
	if (!text || text === '') return out;

	// 先按换行切成行，再把行内可能残留的分号当分隔符处理
	let lines = split(text, '\n');
	for (let ln in lines) {
		ln = trim(ln);
		if (ln === '' || substr(ln, 0, 1) === '#') continue;

		// 一行里可能有多条，用 ; 再切
		let parts = split(ln, ';');
		for (let p in parts) {
			p = trim(p);
			if (p === '') continue;

			let barIdx = index(p, '|');
			let label, url;
			if (barIdx > 0) {
				label = trim(substr(p, 0, barIdx));
				url = trim(substr(p, barIdx + 1));
			} else {
				// 没写标签，整行当 URL（容忍用户偷懒）
				label = '';
				url = p;
			}
			// URL 必须有 http(s) 前缀，否则是无效输入
			if (url === '' || (index(url, 'http://') !== 0 && index(url, 'https://') !== 0))
				continue;
			push(out, { label: label, url: url });
		}
	}
	return out;
}

function loadConfig() {
	let c = {
		enabled: '1',
		port: DEFAULT_PORT,
		host: '0.0.0.0',
		userId: '',
		token: '',
		rateType: '3',
		enableH265: '1',
		enableHDR: '1',
		cacheMinutes: '360',
		debug: '0',
		// 公网访问相关
		publicAccess: '0',      // 是否允许公网访问
		publicToken: '',        // 公网访问令牌（空 = 不校验）
		publicBaseUrl: '',      // 自定义对外地址（空 = 按请求 Host 自动推断）
		publicProxyHint: '',    // 备注：公网地址由谁提供（仅展示用）
		// 外部备用源：每行一条，格式「标签|URL」，按顺序作为降级链
		externalSources: '',
		// ---- 1.3.0 新增 ----
		// 取流地址缓存秒数。旧版硬编码 60 秒；实测命中缓存 1.7ms、未命中
		// 480~780ms（版权频道走回落链 1000~1220ms），换台快慢几乎只取决于
		// 缓存冷不冷。咪咕签发的地址本身有效期约 3 小时（akiralereal/iptv
		// 实测结论，我们 1.5.0 起据此放宽默认值）。设 0 表示不缓存
		// （每次请求都重新解析，仅调试用）。
		streamTtl: '1800',
		// 失败结果短缓存秒数。旧版失败完全不缓存（每次连点都重新打咪咕接口，
		// 实测无效频道要 1.4 秒）。这里给一个很短的缓存兜住连点，又不会把
		// 间歇性的版权盾固化成假故障。设 0 = 关闭（回到旧行为）。
		failTtl: '15',
		// 并发请求上限。本进程是单线程事件循环，解析期间 popen 会阻塞，
		// 公网端口又会被扫描，所以给一个上限保护，超出直接 503。
		maxConns: '64',
		// EPG 节目单地址（xmltv）。默认用 fanmingming 的公共源，
		// 内含 CCTV1 / 东方卫视 这类标准频道 id。
		epgUrl: 'https://live.fanmingming.cn/e.xml',
		// EPG 刷新间隔（小时）。0 = 关闭 EPG。
		epgRefreshHours: '12',
		// 后台预热最近看过的频道数（0 = 关闭）。
		warmRecent: '4',
		// 外部源健康检查用的 User-Agent（空 = curl 默认）。部分防盗链源只认
		// 播放器 UA（如 "VLC/3.0.18 LibVLC/3.0.18"），对 curl 默认 UA 返回
		// 403/451；填上播放器 UA 可提高兼容性。仅影响外部源检查与分片探测。
		extUserAgent: '',
	};

	let ctx = uci.cursor();
	let all = ctx.get_all('migu') || {};
	let main = all.main || {};

	for (let k in main) {
		if (main[k] === '' || main[k] === null) continue;
		c[k] = main[k];
	}

	c.port = +c.port || DEFAULT_PORT;
	c.rateType = +c.rateType || 3;
	if (c.rateType < 2 || c.rateType > 9) c.rateType = 3;
	c.enabled = (('' + c.enabled) !== '0');
	c.enableH265 = (('' + c.enableH265) !== '0');
	c.enableHDR = (('' + c.enableHDR) !== '0');
	c.cacheMinutes = +c.cacheMinutes || 360;
	c.userId = '' + (c.userId || '');
	c.token = '' + (c.token || '');
	c.isGuest = (c.userId === '' || c.token === '');
	c.publicAccess = (('' + c.publicAccess) === '1');
	c.publicToken = '' + (c.publicToken || '');
	c.publicBaseUrl = trim('' + (c.publicBaseUrl || ''));
	// 去掉用户可能粘贴进来的结尾斜杠，避免拼出 //ch/
	while (length(c.publicBaseUrl) > 0 &&
		substr(c.publicBaseUrl, length(c.publicBaseUrl) - 1) === '/')
		c.publicBaseUrl = substr(c.publicBaseUrl, 0, length(c.publicBaseUrl) - 1);
	c.publicProxyHint = '' + (c.publicProxyHint || '');

	// 解析外部备用源列表
	//
	// 格式：option externalSources 存多行文本，每行一条「标签|URL」。
	// 按顺序作为降级链 —— 咪咕取流失败后依次尝试。
	// 每行必须含 | 分隔符，缺标签的用空标签。
	c.extSources = parseExternalSources('' + (c.externalSources || ''));

	// ---- 1.3.0 新增项的归一化 ----
	c.streamTtl = +c.streamTtl;
	if (!(c.streamTtl >= 0)) c.streamTtl = 1800;         // NaN/负数 → 默认 30 分钟
	if (c.streamTtl > 10800) c.streamTtl = 10800;      // 上限 3 小时（上游签名有效期约 3h）
	c.failTtl = +c.failTtl;
	if (!(c.failTtl >= 0)) c.failTtl = 15;
	if (c.failTtl > 300) c.failTtl = 300;
	c.maxConns = +c.maxConns;
	if (!(c.maxConns >= 4)) c.maxConns = 64;
	if (c.maxConns > 4096) c.maxConns = 4096;
	c.epgUrl = trim('' + (c.epgUrl || ''));
	c.epgRefreshHours = +c.epgRefreshHours;
	if (!(c.epgRefreshHours >= 0)) c.epgRefreshHours = 12;
	if (c.epgRefreshHours > 168) c.epgRefreshHours = 168;
	// debug 在旧版里定义了却从没被用过；这里把它变成真正的布尔开关。
	c.debug = (('' + c.debug) === '1');
	c.warmRecent = +c.warmRecent;
	if (!(c.warmRecent >= 0)) c.warmRecent = 4;
	if (c.warmRecent > RECENT_MAX) c.warmRecent = RECENT_MAX;
	// ---- 1.5.0 新增 ----
	c.extUserAgent = trim('' + (c.extUserAgent || ''));

	return c;
}

// ---------- 基础工具 ----------
function shquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// 执行 shell 命令，返回 stdout 或 null
function sh(cmd) {
	let buf = '';
	try {
		let p = popen(cmd, 'r');
		if (!p) return null;
		let c;
		while ((c = p.read(16384)) !== null && length(c) > 0) buf += c;
		p.close();
	} catch (e) {
		return null;
	}
	return buf;
}

// MD5 小写十六进制
//
// 1.3.0 起改用 ucode 原生 digest 模块。旧实现是
//   printf '%s' X | openssl dgst -md5 | awk '{print $2}'
// 一次签名 fork 出 3 个进程，而取一次流要签 2 次（内层 + 外层 salt），
// 合计 6 个进程。实测 openssl 单次 13ms，加上 fork/管道开销约 30~40ms，
// 而且 popen 是同步读，这期间单线程事件循环完全停住 —— 同时来几个
// 未缓存请求就开始互相排队（实测 3 并发 = 0.51/1.07/1.07s）。
//
// 换成原生实现后是纯内存计算，实测与 openssl 用真实签名输入
// （ts+pid+appVersion 以及再叠 salt 的外层）逐字节比对一致。
function md5hex(s) {
	return md5('' + s);
}

// GET 请求，返回 body 字符串或 null。headers 为值数组（"Name: value"）。
function httpGet(url, headers) {
	let cmd = 'curl -s -m 20';
	for (let h in headers)
		cmd += ' -H ' + shquote(h);
	cmd += ' ' + shquote(url);
	return sh(cmd);
}

// 跟随 302 重定向，返回最终 URL
//
// 旧实现是「循环里每跳 fork 一次 curl，取 %{redirect_url} 再接着跳」，
// 最坏情况 6 跳 = 6 个 curl 进程，而且每一跳都要重新做 DNS 解析 + TCP
// 握手（实测每跳 50~190ms）。实测这条链通常只有 0~1 跳，也就是白花了
// 一次进程创建和一次连接建立。
//
// 改成单次 curl -L 由 curl 自己在同一个连接池里跟完，固定 1 个进程。
// 加 --max-filesize 兜底：万一某跳的落点不是 m3u8 而是个大文件，
// 不至于把整段视频拉进内存（旧的 -o /dev/null 其实也有这个风险）。
//
// 说明：这里只关心「最终落点」，不需要响应体，所以仍然丢弃 body；
// 解析失败（超时/网络断）时返回原 URL，让播放器自己再去试。
function resolveFinal(url) {
	let cmd = "curl -s -L -m 12 -o /dev/null --max-filesize 8388608 " +
		"-w '%{url_effective}' " + shquote(url);
	let r = sh(cmd);
	let fin = trim(r || '');
	if (fin === '') return url;
	return fin;
}

// ---------- 咪咕核心 ----------

// 频道分组列表
function cateList() {
	let r = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/1ff892f2b5ab4a79be6e25b69d2f5d05', []);
	if (!r) return null;
	let j;
	try { j = json(r); } catch (e) { return null; }
	if (!j || !j.body || !j.body.liveList) return null;
	return j.body.liveList;
}

// 某分组下的频道
function channelList(vomsID) {
	let r = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/' + vomsID, []);
	if (!r) return null;
	let j;
	try { j = json(r); } catch (e) { return null; }
	if (!j || !j.body || !j.body.dataList) return null;
	return j.body.dataList;
}

// 拉取全部频道（带缓存）。返回 [{name, dataList:[{name,pID,pics}]}]
function allChannels() {
	let now = time();
	if (chanCache.cates && chanCache.channels && (now - chanCache.at) < (cfg.cacheMinutes * 60)) {
		return chanCache.channels;
	}
	let cates = cateList();
	if (!cates) {
		// 有缓存就用旧缓存兜底
		if (chanCache.channels) return chanCache.channels;
		return [];
	}
	let groups = [];
	for (let cate in cates) {
		if (!cate || !cate.name || cate.name === '热门') continue;
		let chans = channelList(cate.vomsID);
		if (!chans) chans = [];
		// 分组内按 name 去重
		let seen = {};
		let uniq = [];
		for (let ch in chans) {
			if (!ch || !ch.name || ch.pID === null || ch.pID === '') continue;
			let key = '' + ch.name;
			if (seen[key]) continue;
			seen[key] = true;
			push(uniq, ch);
		}
		if (length(uniq) > 0) push(groups, { name: cate.name, dataList: uniq });
	}
	// 按正常电视台习惯重排分组（央视在前 → CCTV1 开头）
	let ordered = [];
	for (let gn in GROUP_ORDER) {
		for (let g in groups) {
			if (g.name === gn) { push(ordered, g); break; }
		}
	}
	for (let g in groups) {
		let found = false;
		for (let o in ordered) if (o.name === g.name) { found = true; break; }
		if (!found) push(ordered, g);
	}
	groups = ordered;
	chanCache = { at: now, cates: cates, channels: groups };
	return groups;
}

// 请求 playurl 接口，返回解析后的 JSON 或 null
function requestPlayurl(pid, rt, withOtt, userId, token, h265, hdr) {
	let ts = time() * 1000;
	let appVersion = '26000370';
	let headers = [
		'AppVersion: 2600037000',
		'TerminalId: android',
		'X-UP-CLIENT-CHANNEL-ID: 2600037000-99000-200300220100002',
	];
	if (pid != '641886683' && pid != '641886773')
		push(headers, 'appCode: miguvideo_default_android');
	if (rt != 2 && userId != '' && token != '') {
		push(headers, 'UserId: ' + userId);
		push(headers, 'UserToken: ' + token);
	}

	let str = '' + ts + pid + appVersion;
	let m = md5hex(str);
	let sign = md5hex(m + '3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123');

	let params = '?sign=' + sign + '&rateType=' + rt + '&contId=' + pid +
		'&timestamp=' + ts + '&salt=1230024&flvEnable=true&super4k=true' +
		(withOtt ? '&ott=true' : '') +
		(hdr ? '&4kvivid=true&2Kvivid=true&vivid=2' : '') +
		(h265 ? '&h265N=true' : '');

	let respStr = httpGet('https://play.miguvideo.com/playurl/v1/play/playurl' + params, headers);
	if (!respStr) return null;
	try { return json(respStr); } catch (e) { return null; }
}

// ddCalcu 解密（android 端）
function ddCalcuURL(puDataURL, pid, rateType, userId) {
	let idx = index(puDataURL, '&puData=');
	if (idx < 0) return puDataURL;  // 没有 puData 就原样返回
	let puData = substr(puDataURL, idx + 8);
	let keys = 'cdabyzwxkl';
	let w0 = 'v', w3 = 'a';
	let id = userId || '';
	if (id != '') {
		let n = int(substr(id, 7, 1));
		if (n >= 0 && n < 10) w0 = substr(keys, n, 1);
	}
	if (rateType == 2) w0 = 'v';
	if (length(id) > 3 && length(id) <= 8) w0 = 'e';

	// 取当天日期。这里只用得到 substr(dateStr, 0, 1)，即「年份的第一位
	// 数字」—— 旧实现为此 fork 一个 date 进程（实测 1ms，但同样占事件循环）。
	// 而且当天没取到值时硬编码回落 '20260101'，跨年后就是错的。
	// 改用 ucode 原生 localtime()，零进程且永远正确。
	let now = localtime();
	let dateStr = sprintf('%04d%02d%02d', now.year, now.mon, now.mday);
	let out = '';
	let n = int(length(puData) / 2);
	for (let i = 0; i < n; i++) {
		out += substr(puData, length(puData) - i - 1, 1);
		out += substr(puData, i, 1);
		if (i == 1) out += w0;
		else if (i == 2) out += substr(keys, int(substr(dateStr, 0, 1)), 1);
		else if (i == 3) out += substr(keys, int(substr(pid, 6, 1)), 1);
		else if (i == 4) out += w3;
	}
	return puDataURL + '&ddCalcu=' + out + '&sv=10004&ct=android';
}

// 取流：playurl + 降级 + ddCalcu + 302，返回最终流地址
function getAndroidURL(pid, rateType, userId, token, h265, hdr) {
	let resp = requestPlayurl(pid, rateType, rateType == 9, userId, token, h265, hdr);
	if (!resp) return { url: '', rid: '', err: 'playurl 接口无响应' };

	// 4K 被大屏策略拒绝时，先按手机策略再要一次
	if (resp.rid == 'TIPS_NEED_MEMBER' && rateType == 9) {
		resp = requestPlayurl(pid, 9, false, userId, token, h265, hdr);
	}
	// 超出账号权益，按咪咕愿意给的档位降级
	if (resp && resp.rid == 'TIPS_NEED_MEMBER') {
		let offered = (resp.body && resp.body.urlInfo) ? (+resp.body.urlInfo.rateType || 0) : 0;
		let fallback = (offered >= 4) ? 4 : 3;
		resp = requestPlayurl(pid, fallback, false, userId, token, h265, hdr);
		if (resp && resp.rid == 'TIPS_NEED_MEMBER' && fallback != 3) {
			resp = requestPlayurl(pid, 3, false, userId, token, h265, hdr);
		}
	}

	if (!resp || !resp.body || !resp.body.urlInfo || !resp.body.urlInfo.url) {
		let rid = resp ? ('' + resp.rid) : '';
		let hint = ERR_HINT[rid];
		let msg = hint ? hint : (resp ? ('' + (resp.message || rid || '未知错误')) : '无响应');
		return { url: '', rid: rid, err: msg };
	}

	let encUrl = resp.body.urlInfo.url;
	let pid2 = (resp.body.content && resp.body.content.contId) ? ('' + resp.body.content.contId) : pid;
	let dec = ddCalcuURL(encUrl, pid2, rateType, userId);
	let fin = resolveFinal(dec);
	return {
		url: (fin !== '' ? fin : dec),
		rid: '' + resp.rid,
		rateType: +resp.body.urlInfo.rateType || rateType,
		logined: (resp.body.auth && resp.body.auth.logined) ? true : false,
	};
}

// 取流（带缓存）
//
// 缓存策略在 1.3.0 分成两条路，为了同时满足「换台快」和「不制造假故障」：
//
//  1) 成功结果 → cfg.streamTtl（默认 300 秒）
//     旧版硬编码 60 秒。实测命中缓存 1.7ms，未命中 480~780ms，版权频道
//     走回落链要 1000~1220ms —— 差约 280 倍，换台快慢几乎只由缓存冷不冷
//     决定。咪咕签发的地址本身有效期远长于 60 秒（缓存 URL 直接复用实测
//     HTTP 200 / 700B / 0.07s），所以放宽到 300 秒；做成可配置是为了
//     万一将来咪咕缩短地址有效期（路由器上有长测脚本在盯这件事），
//     用户自己就能调小，不用改代码。
//
//  2) 失败结果 → cfg.failTtl（默认 15 秒）
//     旧版失败完全不缓存，理由写在原注释里：「版权盾是间歇性的，缓存失败
//     会造成假故障」。这个顾虑是对的 —— 赛事时段锁 CCTV5、非赛事时段放开，
//     不同 CDN 边缘节点鉴权状态还可能不同步。但完全不缓存也有代价：无效
//     频道每次请求都要重走整条解析链（实测 1.4 秒），播放器自动重试和用户
//     连点会反复打咪咕接口，既慢又像异常流量。
//     折中：失败只缓存 15 秒 —— 远短于版权盾的时段粒度，不会把「已经放开」
//     误判成「还锁着」，纯粹用来兜住连点。设 0 即可回到旧行为。
function resolveStream(pid) {
	let now = time();
	let hit = streamCache[pid];

	if (hit) {
		// 成功按 streamTtl、失败按 failTtl；ttl=0 视为不缓存
		let ttl = hit.url ? cfg.streamTtl : cfg.failTtl;
		if (ttl > 0 && (now - hit.at) < ttl) {
			hit.cached = true;
			return hit;
		}
	}

	let t0 = time();
	let r = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);

	// 首次失败：紧跟一次重试。
	// 版权盾的判定带概率性（多节点状态不同步），同一 pid 连发两次请求
	// 命中不同节点的概率不小，重试能明显降低偶发失败率。
	if (!r.url) {
		let r2 = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);
		if (r2.url) r = r2;
	}

	let costMs = (time() - t0) * 1000;
	stats.resolveMsSum += costMs;

	let entry = { url: r.url, rid: r.rid, rateType: r.rateType, at: now, err: r.err, costMs: costMs };

	if (r.url) {
		streamCache[pid] = entry;
		if (cfg.debug) logInfo(sprintf('resolve %s 成功 %dms → %s', pid, costMs, substr(r.url, 0, 72)));
	} else if (cfg.failTtl > 0) {
		streamCache[pid] = entry;
		if (cfg.debug) logInfo(sprintf('resolve %s 失败 %dms (%s)，短缓存 %ds', pid, costMs, r.err, cfg.failTtl));
	} else {
		delete streamCache[pid];
		if (cfg.debug) logInfo(sprintf('resolve %s 失败 %dms (%s)，不缓存', pid, costMs, r.err));
	}

	return entry;
}

// 把 pid 加入「最近访问」列表（供后台预热），最新在前、去重、限长。
// 不用 splice —— 这里对 ucode 数组方法只用到 push/pop，最保险。
function touchRecent(pid) {
	let out = [pid];
	for (let i = 0; i < length(recentPids); i++) {
		if (recentPids[i] === pid) continue;
		if (length(out) >= RECENT_MAX) break;
		push(out, recentPids[i]);
	}
	recentPids = out;
}

// 最近频道预热：把最近看过的频道提前解析好，让「换回来」也命中缓存。
//
// 两个克制点（都是为了避免预热本身变成新的卡顿源）：
//   1) 只在 recentPids 真的变过之后才干活 —— 没人看电视的时候不做无用功，
//      也用不着反复打咪咕接口。
//   2) 已经有了有效缓存条目的频道直接跳过，只补「过期/没有」的那些。
function warmRecentChannels() {
	if (cfg.warmRecent <= 0) return;

	// 列表没变过就跳过（用列表内容当指纹，避免存额外状态）
	let fingerprint = join(',', recentPids);
	if (fingerprint === lastWarmedKey) return;

	let now = time();
	let done = 0;
	for (let i = 0; i < length(recentPids) && done < cfg.warmRecent; i++) {
		let pid = recentPids[i];
		let hit = streamCache[pid];
		// 缓存还新鲜 → 不需要预热
		if (hit && hit.url && cfg.streamTtl > 0 && (now - hit.at) < cfg.streamTtl) continue;

		try {
			let r = resolveStream(pid);
			done++;
			if (cfg.debug) logInfo(sprintf('预热 %s %s', pid, r.url ? '成功' : '失败'));
		} catch (e) {
			logErr('预热 ' + pid + ' 异常: ' + e);
		}
	}
	lastWarmedKey = fingerprint;
}

// ---------- 外部备用源 ----------
//
// 咪咕取流失败（典型：赛事时段版权盾锁 CCTV5）时，按用户配置的顺序
// 依次尝试外部源。外部源是静态 HLS URL，不走咪咕鉴权流程，直接返回给播放器。
//
// 检查结果带缓存，避免每次请求都去打失效源浪费带宽。
const EXT_OK_TTL = 300;        // 成功缓存 5 分钟
const EXT_FAIL_TTL = 60;       // 失败缓存 1 分钟
// 慢源临时禁用（1.5.0，借鉴 my-tv）：连续失败达到阈值后，短时间内直接判失败，
// 不再让每次降级都被同一个慢源拖累。禁用期满自动清零计数重新探测。
const EXT_FAIL_THRESHOLD = 3;   // 连续失败次数阈值
const EXT_DISABLE_TTL = 600;   // 禁用时长：10 分钟

// 拉取 HLS 播放列表头部（前 400 字节），返回响应体（不含状态码）或 null。
// HTTP 状态不在 200-399 或内容不以 #EXTM3U 开头都算失败，返回 null。
function fetchHlsHead(url) {
	let uaArg = cfg.extUserAgent ? ' -A ' + shquote(cfg.extUserAgent) : '';
	let cmd = 'curl -s -L -m 10 -r 0-400' + uaArg + " -w '\\n__CODE__%{http_code}' " + shquote(url);
	let body = sh(cmd) || '';
	let mi = rindex(body, '__CODE__');
	if (mi < 0) return null;
	let code = trim(substr(body, mi + 8));
	body = substr(body, 0, mi);
	if (!(code >= 200 && code < 400)) return null;
	if (index(body, '#EXTM3U') < 0) return null;
	return body;
}

// 把 HLS 播放列表里的相对 URL 解析成绝对 URL（基于播放列表自身 URL）。
function resolveHlsUrl(u, base) {
	if (substr(u, 0, 7) === 'http://' || substr(u, 0, 8) === 'https://') return u;
	let slash = rindex(base, '/');
	if (slash < 0) return u;
	return substr(base, 0, slash + 1) + u;
}

// 从 m3u8 播放列表文本中提取首个媒体分片 URL（相对路径按 base 解析）。
// 支持两种形态：
//   媒体播放列表：`#EXTINF:...` 后的下一行是分片 URL；
//   master 播放列表：`#EXT-X-STREAM-INF...` 后的下一行是 variant URL，
//     则递归一层取其首个分片（最多两层，避免探测过深）。
// 找不到返回 null。
function hlsFirstSegment(body, base, depth) {
	let lines = split(body, '\n');
	let firstUri = '';
	for (let ln in lines) {
		ln = trim(ln);
		if (ln === '' || substr(ln, 0, 1) === '#') continue;
		firstUri = ln;
		break;
	}
	if (firstUri === '') return null;
	let seg = resolveHlsUrl(firstUri, base);
	// 取到的是 variant（子播放列表）→ 递归一层找分片
	if ((index(firstUri, '.m3u8') >= 0 || index(firstUri, '.m3u') >= 0) && depth < 2) {
		let sub = fetchHlsHead(seg);
		if (sub === null) return null;
		return hlsFirstSegment(sub, seg, depth + 1);
	}
	return seg;
}

// 请求分片前 32 字节，校验首字节为 TS 同步字节 0x47（MPEG-TS），
// 或为 fMP4 box 头（ftyp/styp/moov，HLS fMP4 分段）。都校验不到则判不可用。
function checkSegment(seg) {
	let uaArg = cfg.extUserAgent ? ' -A ' + shquote(cfg.extUserAgent) : '';
	let cmd = 'curl -s -L -m 8 -r 0-31' + uaArg + " -w '\\n__CODE__%{http_code}' " + shquote(seg);
	let body = sh(cmd) || '';
	let mi = rindex(body, '__CODE__');
	if (mi < 0) return false;
	let code = trim(substr(body, mi + 8));
	let data = substr(body, 0, mi);
	if (!(code >= 200 && code < 400)) return false;
	if (length(data) === 0) return false;
	// 二进制分片可能带 0x00 前导；检查开头 4 字节的特征
	let head = substr(data, 0, 4);
	if (substr(head, 0, 1) === '\x47') return true;   // MPEG-TS 同步字节
	if (head === 'ftyp' || head === 'styp' || head === 'moov') return true; // fMP4 box 头
	return false;
}

// 检查外部源 URL 是否可达且内容有效。返回 true/false。
//
// 1.5.0 起为两段式（awesome-iptv 最佳实践）：
//   第一段：拉取 m3u8 播放列表头，校验 HTTP 2xx/3xx 且内容含 #EXTM3U；
//   第二段：解析出首个分片并请求其前 32 字节，校验 0x47 / fMP4 box。
// 只校验播放列表头会把「列表能下但分片全挂」的假阳性源判成可用，
// 导致降级链把用户带到打不开的地址（大量失效 IPTV 源会返回
// HTTP 200 + 纯文本错误页，如 "the channel is not exist"）。
// 用 -L 跟随重定向（很多公开源是 302 到真实 HLS），10 秒超时。
function checkExternalSource(url) {
	let now = time();
	let hit = extSourceCache[url];
	if (hit) {
		let ttl = hit.ok ? EXT_OK_TTL : EXT_FAIL_TTL;
		if ((now - hit.at) < ttl) return hit.ok;
	}

	// 慢源临时禁用：禁用期内直接判失败，不再发起探测。
	let dis = extDisabled[url];
	if (dis && (now - dis) < EXT_DISABLE_TTL) return false;
	if (dis) {
		// 禁用期满：清零计数，放行重新探测
		extFailCount[url] = 0;
		delete extDisabled[url];
	}

	let ok = false;
	let body = fetchHlsHead(url);
	if (body !== null) {
		let seg = hlsFirstSegment(body, url, 0);
		if (seg) ok = checkSegment(seg);
	}

	extSourceCache[url] = { ok: ok, at: now };
	if (!ok) {
		let fc = (extFailCount[url] || 0) + 1;
		extFailCount[url] = fc;
		if (fc >= EXT_FAIL_THRESHOLD) {
			extDisabled[url] = now;
			logInfo('外部源连续失败 ' + fc + ' 次，临时禁用 10 分钟: ' + url);
		} else {
			logInfo('外部源不可用: ' + url + (body === null ? '（播放列表无效）' : '（分片校验失败）'));
		}
	} else {
		extFailCount[url] = 0;
		delete extDisabled[url];
	}
	return ok;
}

// 按顺序尝试外部源列表，返回第一个可用的 {label, url} 或 null
function tryExternalSources() {
	let list = cfg.extSources;
	if (!list || length(list) === 0) return null;

	for (let i = 0; i < length(list); i++) {
		if (checkExternalSource(list[i].url))
			return list[i];
	}
	return null;
}

// ---------- HTTP 工具 ----------
function httpStatusText(code) {
	let map = {
		'200': 'OK', '302': 'Found', '400': 'Bad Request', '401': 'Unauthorized',
		'404': 'Not Found', '405': 'Method Not Allowed', '500': 'Internal Server Error',
		'502': 'Bad Gateway', '503': 'Service Unavailable',
	};
	return map[code] || 'Unknown';
}

function closeConn(conn) {
	if (conn.closed) return;
	conn.closed = true;
	try { if (conn.handle) conn.handle.cancel(); } catch (e) { }
	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	try { conn.sock.close(); } catch (e) { }
	conn.sock = null;
	conn.handle = null;
	conn.buf = '';

	// 从活跃连接表里摘除自己。
	// 旧版这里缺了这一步：onAccept 里 push 进来，closeConn 却只管关 socket，
	// 于是 connections 数组只增不减 —— 每一个曾经连上来的客户端（含扫描器）
	// 都会永久留在数组里，连着它那串请求缓冲一起。这是一个无界内存泄漏，
	// 公网端口被人扫一遍就能把路由器的内存吃掉。实测改造前 VmRSS 3.5MB、
	// fd=10（空闲时），泄漏是随连接数累积的，短时间测不出来。
	for (let i = 0; i < length(connections); i++) {
		if (connections[i] === conn) {
			splice(connections, i, 1);
			break;
		}
	}
}

function rawResponse(conn, status, ctype, body, extraHeaders) {
	if (conn.closed) return;
	body = '' + (body || '');
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: %s\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Cache-Control: no-store\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'%s' +
		'\r\n',
		status, httpStatusText(status), ctype, length(body), extra
	);
	conn.sock.send(head + body);
	closeConn(conn);
}

function jsonResponse(conn, status, obj) {
	rawResponse(conn, status, 'application/json; charset=utf-8', sprintf('%.J', obj), null);
}

function textResponse(conn, status, body) {
	rawResponse(conn, status, 'text/html; charset=utf-8', body, null);
}

function redirectResponse(conn, location, extra) {
	if (conn.closed) return;
	// 注意：ucode 没有 undefined 这个全局变量，只能用 null 和 length() 判断
	let extraLine = '';
	if (extra !== null && type(extra) === 'string' && length(extra) > 0)
		extraLine = 'X-Migu-Fallback: ' + extra + '\r\n';
	let head = sprintf(
		'HTTP/1.1 302 Found\r\n' +
		'Location: %s\r\n' +
		'Content-Length: 0\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'%s' +
		'\r\n',
		location, extraLine
	);
	conn.sock.send(head);
	closeConn(conn);
}

function parseHead(head) {
	let lines = split(head, '\r\n');
	let first = lines[0] || '';
	let m = match(first, /^(\S+)\s+(\S+)/);
	let method = m ? m[1] : 'GET';
	let path = m ? m[2] : '/';
	let headers = {};
	for (let i = 1; i < length(lines); i++) {
		let ln = lines[i];
		let idx = index(ln, ':');
		if (idx <= 0) continue;
		let k = lc(trim(substr(ln, 0, idx)));
		let v = trim(substr(ln, idx + 1));
		headers[k] = v;
	}
	return { method: method, path: path, headers: headers };
}

// ---------- 公网访问控制 ----------
//
// 设计取舍：
//   - 默认（publicAccess=0）只允许内网/本机来源访问，公网请求一律 403。
//     这样即使用户在路由器上做了端口映射，也不会在不知情的情况下把
//     整份频道列表和取流接口暴露到公网。
//   - 显式开启后允许公网访问；若设置了 publicToken，则要求
//     订阅地址与取流地址都带上该令牌（?token=xxx 或 /<token>/ 前缀），
//     防止被人扫到地址后白嫖你的账号带宽。

// 判断 IPv4 是否属于内网/回环/链路本地
function isPrivateV4(ip) {
	if (ip === '') return false;
	let p = split(ip, '.');
	if (length(p) !== 4) return false;
	let a = +p[0], b = +p[1];
	if (a === 10) return true;
	if (a === 172 && b >= 16 && b <= 31) return true;
	if (a === 192 && b === 168) return true;
	if (a === 127) return true;                    // 回环
	if (a === 169 && b === 254) return true;       // 链路本地
	if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
	if (a >= 224) return true;                     // 组播/保留
	return false;
}

// 判断来源地址是否可信（内网 / 回环 / IPv6 本地）
function isLocalPeer(addr) {
	if (!addr) return false;
	let a = '' + addr;
	// IPv6 映射的 IPv4（::ffff:192.168.1.5）
	let m = match(a, /^::ffff:([0-9.]+)$/i);
	if (m) a = m[1];
	if (index(a, ':') >= 0) {
		// IPv6：回环、唯一本地地址 fc00::/7、链路本地 fe80::/10 视为内网
		let low = lc(a);
		if (low === '::1') return true;
		let head = substr(low, 0, 2);
		if (head === 'fc' || head === 'fd') return true;
		if (substr(low, 0, 3) === 'fe8') return true;
		if (isPrivateV4(a)) return true;
		// 其它 IPv6 一律当作公网，交给开关判定
		return false;
	}
	return isPrivateV4(a);
}

// 从查询串里取参数值
function queryParam(path, name) {
	let q = index(path, '?');
	if (q < 0) return null;
	let qs = substr(path, q + 1);
	let parts = split(qs, '&');
	for (let p in parts) {
		let eq = index(p, '=');
		if (eq < 0) {
			if (p === name) return '';
			continue;
		}
		if (substr(p, 0, eq) === name) return substr(p, eq + 1);
	}
	return null;
}

// 校验公网访问权限
//
// 返回 { allow: true } 或 { allow: false, code: 403, error: '...' }
function checkAccess(conn, peerAddr, path) {
	// 内网来源始终放行（局域网 TV-BOX 不受公网开关影响）
	if (isLocalPeer(peerAddr)) return { allow: true, local: true };

	// 公网来源：未开启开关则拒绝
	if (!cfg.publicAccess) {
		return {
			allow: false,
			code: 403,
			error: '公网访问未开启。请在 LuCI「服务 → 咪咕直播 → 设置 → 公网访问」中开启。',
		};
	}

	// 已开启：若配了令牌则必须匹配
	if (cfg.publicToken !== '') {
		let given = null;
		// 支持两种形式：?token=xxx  或  /<token>/ch/...
		let qp = queryParam(path, 'token');
		if (qp !== null) given = qp;
		if (given === null) {
			// 路径前缀形式：/TOKEN/m3u
			let seg = match(path, /^\/([A-Za-z0-9_-]{8,64})\//);
			if (seg) given = seg[1];
		}
		if (given === null || given !== cfg.publicToken) {
			return {
				allow: false,
				code: 403,
				error: '缺少或错误的访问令牌。请在订阅地址末尾加上 ?token=你的令牌。',
			};
		}
	}

	return { allow: true, local: false };
}

// 生成对外可用的基地址（用于拼 M3U / TXT 里的取流地址）
//
// 优先级：
//   1) 用户自定义的 publicBaseUrl（例如 https://migu.example.com）
//   2) 请求头 Host（最贴合客户端实际访问的地址）
//   3) 配置里的 host:port
//
// 注意：客户端可能通过域名 + 反代路径访问，此时 Host 就是正确答案，
// 所以默认用 Host 而不是写死 IP。
function externalBase(host, access) {
	let base = '';

	if (cfg.publicBaseUrl !== '') {
		base = cfg.publicBaseUrl;
	} else {
		base = 'http://' + host;
	}

	// 公网访问 + 配了令牌 → 用路径前缀形式把令牌编进地址，
	// 这样播放器不需要理解查询参数，兼容性最好
	if (access && access.local === false && cfg.publicToken !== '')
		base = base + '/' + cfg.publicToken;

	return base;
}

// ---------- EPG（节目单）----------
//
// 旧版把 `#EXTM3U x-tvg-url=""` 写死成空串，tvg-id 直接用咪咕的中文频道名
// （「CCTV1综合」），而标准 xmltv 节目单里的频道 id 是「CCTV1」「东方卫视」
// 这种短名 —— 两边永远对不上，所以播放器一直拿不到节目单，用户看到的就是
// 一片空白（这个 bug 从 1.0 就在）。
//
// 修法分两步：
//   1) 后台拉取节目单里的频道 id 列表，缓存到内存。
//      实测这个源 1.19MB / ttfb 2.19s，绝对不能放在请求路径上同步拉 ——
//      那样每刷一次播放列表就要卡两秒。所以只放在定时器里做，
//      且启动后延迟执行，先保证服务可用。
//   2) 生成 M3U 时做**最长前缀匹配**，把咪咕的长名收敛到标准 id：
//        CCTV1综合        → CCTV1
//        CCTV5+体育赛事   → CCTV5+      （不是 CCTV5，取最长的那个）
//        东方卫视高清      → 东方卫视
//      匹配不到就退回频道名本身（相当于旧行为），不会把 id 弄丢。
//
// 拉取失败只记日志，不影响播放：x-tvg-url 仍会给出，tvg-id 退回频道名。
//
// ⚠️ 两个必须遵守的实现约束（都是实测踩出来的）：
//
// 1) 必须「先落盘、再从文件解析」，不能让 busybox 的正则工具直接读网络管道。
//    实测（同一台路由器、同一个源、连续多轮）：
//      curl … | wc -c              → 7869907 字节，3/3 稳定
//      curl … | grep -o …          → 0 / 20 / 1 / 0 / 0 / 0 行（极不稳定）
//      curl … | sed … | sort -u    → 124 / 0 / 124 行（不稳定）
//      落盘后 grep -o 同一份文件    → 132 行，稳定
//      落盘后 sed     同一份文件    → 124 个唯一 id，稳定
//    即字节流本身完好，是 busybox 在「边收边匹配」时丢数据。
//    症状就是 epgIds 长期停在 1，tvg-id 映射整条失效。
//
// 2) 这个源本身不稳，且 **curl -o 失败时也会把不完整文件留在磁盘上**：
//    连续 6 次下载里 3 次被中途截断（rc=56/rc=35，得到 635064 / 69669 / 0 字节，
//    完整应为 7869907）。截断到 635KB 的那份只能解析出 13 个 id（完整 124 个），
//    而 sh() 里拿不到 curl 退出码，所以必须自己校验完整性：
//    判据是文件收尾有 `</tv>`，不满足就整份重下（最多 3 轮）。
//
// 3) 整个拉取走**游离后台任务 + 定时器轮询**，不用 sh() 同步等待。
//    sh() 是 popen 同步读，而这是单线程事件循环：同步等 3 秒 = 所有播放请求
//    一起排队 3 秒；带重试后最坏可达 ~79 秒，足以毁掉换台体验。
//    实测把整条命令用「( … ) >/dev/null 2>&1 &」包起来后 popen 立刻返回
//    （0.00s），事件循环心跳照常跳动，所以这里改成「后台写文件 + 轮询取结果」。
const EPG_TMP = '/tmp/.migu-epg.xml';     // 原始 XML（临时）
const EPG_IDS = '/tmp/.migu-epg.ids';     // 解析出的 id 表（临时）
const EPG_DONE = '/tmp/.migu-epg.done';   // 完成标记，内容为 OK / FAIL / UNCHANGED
const EPG_LM = '/tmp/.migu-epg.lm';       // 上次响应的 ETag（持久，用于 304 条件请求）
let epgPending = false;                   // 是否有后台拉取正在进行
let epgStartedAt = 0;                     // 本次拉取开始时间（用于超时兜底）
// 本轮拉取的「代」号。文件名带代际后缀，避免超时兜底放弃后又起一轮时，
// 两轮后台任务互相覆盖同一份临时文件（旧轮写 FAIL、新轮写 OK 会打架）。
let epgGen = 0;
let epgCurIds = '';                       // 本轮的 ids 文件路径
let epgCurDone = '';                      // 本轮的 done 文件路径

// 启动一次后台拉取，立即返回（不阻塞事件循环）
function epgStartFetch() {
	if (epgPending || cfg.epgUrl === '') return;
	epgPending = true;
	epgStartedAt = time();
	epgGen++;
	let g = '' + epgGen;
	let ids = EPG_IDS + '.' + g;
	let done = EPG_DONE + '.' + g;
	let xml = EPG_TMP + '.' + g;
	epgCurIds = ids;
	epgCurDone = done;
	// 顺手清掉历史代际的残留（崩溃 / 超时可能留下）
	sh('rm -f ' + EPG_IDS + '.* ' + EPG_DONE + '.* ' + EPG_TMP + '.* 2>/dev/null');
	let url = shquote(cfg.epgUrl);
	// 抓取参数的取值依据（同一台路由器、连续多轮实测，见 test-fetch.sh）：
	//   当前形态 `-m 25 --retry 1` + shell 循环 3 轮 → 4 次里失败 1 次
	//   `--retry-all-errors --retry 4 --retry-delay 2` → 4/4 全部完整
	// 关键就是 **--retry-all-errors**：这个源会以 rc=56 / rc=35 中途断开，
	// 而 curl 默认的 --retry 只重试「连接阶段」的错误，对已开始传输的断开
	// 不作为 —— 这正是我们失败的主因。--compressed 也加上：服务端支持 br，
	// 7.9MB 的 XML 压缩后传输更快，正好压低失败窗口。
	// 最坏耗时 = 3 轮 × (5 次尝试 × 25s + 4×2s 退避) ≈ 400s，所以下面的
	// 超时兜底取 600s，宁可慢也不让两轮任务交错。
	// 1.5.0 起带 If-None-Match 条件请求（ETag）：源未变（304）时直接标记
	// UNCHANGED，不再下载/解析 7.9MB 的 e.xml（借鉴 awesome-iptv 的 EPG 条件更新）。
	// 实测该源（Cloudflare）只有 ETag、没有 Last-Modified，所以用 ETag。
	let hdr = xml + '.hdr';            // 响应头（含 ETag）
	let codef = xml + '.code';         // HTTP 状态码文件
	let etag = trim(sh('cat ' + EPG_LM + ' 2>/dev/null'));
	// 只有内存里已有 id 表时才带条件请求：进程刚重启时 epgState.ids 在 RAM 里
	// 为空，304 只会让我们什么都得不到（实测「EPG 返回 304 但没有可用 id 表」）。
	// 所以首轮必须全量下载，条件请求只用于 12 小时周期刷新。
	let haveIds = epgState.ids && length(epgState.ids) > 0;
	let cond = (haveIds && etag) ? " -H 'If-None-Match: " + etag + "'" : '';
	let job = '( i=0; while [ $i -lt 3 ]; do ' +
		'rm -f ' + codef + ' ' + hdr + '; ' +
		'curl -s -L --compressed --connect-timeout 8 -m 25 ' +
		'--retry 4 --retry-delay 2 --retry-all-errors' + cond + ' ' +
		'-D ' + hdr + ' -w "%{http_code}" -o ' + xml + ' ' + url + ' > ' + codef + '; ' +
		'CODE=$(cat ' + codef + ' 2>/dev/null); ' +
		'if [ "$CODE" = "304" ]; then echo UNCHANGED > ' + done + '; break; fi; ' +
		'if [ -s ' + xml + ' ] && tail -c 200 ' + xml + ' | grep -q "</tv>"; then break; fi; ' +
		'rm -f ' + xml + '; i=$((i+1)); sleep 2; done; ' +
		'if [ "$CODE" = "304" ]; then ' +
		'rm -f ' + xml + ' ' + codef + ' ' + hdr + '; ' +
		'elif [ -s ' + xml + ' ] && tail -c 200 ' + xml + ' | grep -q "</tv>"; then ' +
		'ETAG=$(grep -i "^etag:" ' + hdr + ' | tail -n 1 | sed "s/^[Ee]tag:[[:space:]]*//" | tr -d "\\r"); ' +
		'[ -n "$ETAG" ] && echo "$ETAG" > ' + EPG_LM + '; ' +
		'sed -n \'s/.*<channel[^>]*id="\\([^"]*\\)".*/\\1/p\' ' + xml +
		' | sort -u > ' + ids + '; echo OK > ' + done + '; ' +
		'else : > ' + ids + '; echo FAIL > ' + done + '; fi; ' +
		'rm -f ' + xml + ' ' + codef + ' ' + hdr + ' ) >/dev/null 2>&1 &';
	sh(job);
	if (cfg.debug) logInfo('EPG 后台拉取已启动（代 ' + g + '）');
}

// 轮询一次后台拉取结果，返回 'pending' | 'ok' | 'fail'
function epgPollFetch() {
	if (!epgPending) return 'fail';

	// 兜底：后台任务若被 OOM/信号杀掉就不会写 DONE，别让 epgPending 永久卡住。
	// 最坏耗时 = 3 轮 × (5 次 × 25s + 4×2s 退避) ≈ 400s，上限取 600s 留足余量。
	// （两轮的临时文件名带代际后缀，即使真的交错也不会互相覆盖。）
	if (time() - epgStartedAt > 600) {
		epgPending = false;
		sh('rm -f ' + epgCurIds + ' ' + epgCurDone + ' 2>/dev/null');
		logErr('EPG 拉取超时（>600s），本轮放弃');
		return 'fail';
	}

	let done = trim(sh('cat ' + epgCurDone + ' 2>/dev/null'));
	if (done === '') return 'pending';      // 还没写完
	epgPending = false;

	// 1.5.0：304 未变更。沿用现有 id 表，只刷新「最后成功时间」，
	// 这样定时器按正常周期调度下一轮，不会把 UNCHANGED 误判成失败
	// （失败路径会短时间重试；源没变不需要重试）。
	if (done === 'UNCHANGED') {
		sh('rm -f ' + epgCurIds + ' ' + epgCurDone + ' 2>/dev/null');
		if (epgState.ids && length(epgState.ids) > 0) {
			epgState.at = time();
			epgState.ok = true;
			logInfo('EPG 未变更（304），沿用 ' + length(epgState.ids) + ' 个频道 id');
			return 'ok';
		}
		// 上次没有 id（首次拉取就 304 不可能发生，但防御性处理）→ 按失败处理
		logErr('EPG 返回 304 但没有可用 id 表');
		epgState.at = time();
		epgState.ok = false;
		return 'fail';
	}

	let out = sh('cat ' + epgCurIds + ' 2>/dev/null');
	sh('rm -f ' + epgCurIds + ' ' + epgCurDone + ' 2>/dev/null');

	if (done !== 'OK' || !out || trim(out) === '') {
		// 拉取失败时保留上一次的 id 表：EPG 源偶发截断/打不开，不应该让
		// 已经生效的 tvg-id 映射整体退化回中文名。
		epgState.at = time();
		epgState.ok = false;
		if (epgState.ids && length(epgState.ids) > 0)
			logErr('EPG 拉取失败（' + cfg.epgUrl + '，标记 ' + done + '），沿用上一次的 ' +
				length(epgState.ids) + ' 个频道 id');
		else
			logErr('EPG 拉取失败（' + cfg.epgUrl + '，标记 ' + done + '），tvg-id 将退回频道名');
		return 'fail';
	}

	let ids = [];
	let lines = split(trim(out), '\n');
	for (let ln in lines) {
		ln = trim(ln);
		if (ln === '') continue;
		push(ids, ln);
	}

	if (length(ids) === 0) {
		epgState.ok = false;
		epgState.at = time();
		logErr('EPG 拉取到 0 个频道 id，沿用上一次结果');
		return 'fail';
	}

	epgState = { ids: ids, at: time(), source: cfg.epgUrl, ok: true };
	logInfo('EPG 就绪：' + length(ids) + ' 个频道 id（来源 ' + cfg.epgUrl + '）');
	return 'ok';
}

// 前缀匹配的最短 id 长度。实测这台源（live.fanmingming.cn/e.xml，124 个 id）
// 里只有两个短 id：`C`(1 字符) 和 `DTV`(3 字符)，其余 122 个全部 >= 5 字符。
// 不设阈值时 `C` 会把所有 CGTN* 和 CETV4 吞掉（实测 8 行 tvg-id="C"，
// 节目单全指到不存在的频道上）；阈值设 4 可同时排除这两个杂项 id，
// 又不影响任何真实频道 id（最短的 CCTV1/CETV1/SCTV2 都是 5 字符）。
const EPG_MIN_PREFIX = 4;

// 最长前缀匹配：把咪咕频道名映射到标准 EPG 频道 id。
// 匹配不到返回 ''（调用方退回频道名本身）。
function epgIdFor(name) {
	if (!epgState.ids || length(epgState.ids) === 0 || !name) return '';

	let best = '';
	for (let id in epgState.ids) {
		if (id === '') continue;
		// 完全相同：不受长度阈值限制（万一将来出现短 id 的真实频道）
		if (id === name) return id;
		// 其余只做前缀匹配；太短的 id 容易误吞（见 EPG_MIN_PREFIX 注释）
		if (length(id) < EPG_MIN_PREFIX || length(id) > length(name)) continue;
		if (substr(name, 0, length(id)) === id && length(id) > length(best))
			best = id;
	}
	return best;
}

// EPG 刷新调度：一轮 = 发起后台拉取 → 每秒轮询 → 成功按配置周期 / 失败 5 分钟。
// 失败不傻等 epgRefreshHours 小时：实测该源会偶发截断与 TLS 连接失败
// （curl rc=56 / rc=35），若首次拉取恰好踩中就整整 12 小时没有 tvg-id 映射。
const EPG_RETRY_MS = 5 * 60 * 1000;   // 拉取失败后的重试间隔：5 分钟
const EPG_POLL_MS = 1000;             // 后台拉取进行中的轮询间隔

// EPG 定时器回调。用**函数声明**而非自引用箭头函数（原因见 warmTickFn 注释）。
//
// ⚠️ 这里刻意写成「一个自递归函数」而不是 scheduleEpgRefresh + epgTickFn 两个
// 互相调用的函数：**ucode 不做函数提升，函数体只能引用在文件里更早声明的名字**。
// 实测（探针 probe-rule.uc）：
//   用例A：callee 定义在 caller 之后、且调用发生在两者都定义完之后 →
//          仍然抛 `left-hand side is not a function`
//   用例B：callee 在前            → 正常
//   用例C：函数声明自引用          → 正常
//   用例E：把后定义的函数「当值传递」→ 正常
// 即限制在「函数体内直接按名字调用」这一种写法上。原先写成两个互相调用的函数
// （scheduleEpgRefresh 体内调 epgTickFn）正好踩中用例A，必崩。
//
// delayMs 只传 int 或省略。⚠️ ucode 没有 `undefined` 这个全局变量
// （见 redirectResponse 里的同款注释），写 `delayMs !== undefined` 会直接抛错；
// 而这个回调抛出的异常无人接管，**整个进程会被带走**。
function epgTickFn(delayMs) {
	try {
		// 阶段一：有后台任务在跑 → 轮询结果
		if (epgPending) {
			let r = epgPollFetch();
			if (r === 'pending') {
				epgTimer = uloop.timer(EPG_POLL_MS, epgTickFn);
				return;
			}
			// 成功按配置周期，失败 5 分钟后重试
			epgTimer = uloop.timer(
				r === 'ok' ? cfg.epgRefreshHours * 3600 * 1000 : EPG_RETRY_MS, epgTickFn);
			return;
		}

		// 阶段二：空闲状态。若调用方给了延迟（首次拉取用），先等这段时间再启动。
		if (type(delayMs) === 'int' && delayMs > 0) {
			epgTimer = uloop.timer(delayMs, epgTickFn);
			return;
		}

		// 阶段三：发起后台拉取（立即返回，不阻塞事件循环），随后开始轮询
		epgStartFetch();
		epgTimer = uloop.timer(epgPending ? EPG_POLL_MS : EPG_RETRY_MS, epgTickFn);
	} catch (e) {
		// 定时器回调里抛出的异常没人接管，会直接结束进程（教训见函数头注释），
		// 所以这里必须兜住，并留一条重试的退路。
		logErr('EPG 定时器异常: ' + e);
		try { epgTimer = uloop.timer(EPG_RETRY_MS, epgTickFn); }
		catch (e2) { logErr('EPG 重排失败: ' + e2); }
	}
}

// ---------- 播放列表 ----------

// base 是已经算好的对外基地址（可能带令牌前缀），例如
//   http://192.168.69.1:8788        内网访问
//   https://migu.example.com/TOKEN  公网 + 令牌
function buildM3u(base) {
	let groups = allChannels();
	// x-tvg-url：配了 EPG 就给出地址（每个客户端自己去拉一次性文件），
	// 没配就保持旧的空串写法（部分播放器见到空串比见到缺属性更安分）。
	// 注意这里给的是**原始 EPG 地址**，不是本机转发的 —— 客户端大多能直连，
	// 本机转发会白白吃掉路由器的转发带宽。
	let tvg = (cfg.epgUrl !== '') ? (' x-tvg-url="' + cfg.epgUrl + '"') : ' x-tvg-url=""';
	let lines = ['#EXTM3U' + tvg];
	for (let g in groups) {
		for (let ch in g.dataList) {
			let logo = (ch.pics && ch.pics.highResolutionH) ? ch.pics.highResolutionH : '';
			let url = base + '/ch/' + ch.pID;
			// tvg-id 用 EPG 里的标准 id（最长前缀匹配），匹配不到退回频道名
			let eid = epgIdFor(ch.name);
			let tvgId = (eid !== '') ? eid : ch.name;
			push(lines, '#EXTINF:-1 tvg-id="' + tvgId + '" tvg-name="' + ch.name + '"' +
				(logo !== '' ? ' tvg-logo="' + logo + '"' : '') +
				' group-title="' + g.name + '",' + ch.name);
			push(lines, url);
		}
	}
	// 追加外部备用源作为独立分组，用户可在 TV-BOX 里手动选择线路
	// pid 编码：9001 = 外部源[0]，9002 = 外部源[1]，依此类推
	// 这样用户既可以用咪咕频道（自动降级到外部源），也可以直接订阅外部源线路
	if (cfg.extSources && length(cfg.extSources) > 0) {
		for (let i = 0; i < length(cfg.extSources); i++) {
			let es = cfg.extSources[i];
			let nm = (es.label !== '') ? ('备用源' + (i + 1) + '-' + es.label) : ('备用源' + (i + 1));
			push(lines, '#EXTINF:-1 tvg-id="' + nm + '" tvg-name="' + nm + '"' +
				' group-title="备用源",' + nm);
			push(lines, base + '/ch/' + (9001 + i));
		}
	}
	return join('\n', lines) + '\n';
}

function buildTxt(base) {
	let groups = allChannels();
	let lines = [];
	for (let g in groups) {
		for (let ch in g.dataList) {
			push(lines, ch.name + ',' + base + '/ch/' + ch.pID);
		}
	}
	// 同样追加外部源
	if (cfg.extSources && length(cfg.extSources) > 0) {
		for (let i = 0; i < length(cfg.extSources); i++) {
			let es = cfg.extSources[i];
			let nm = (es.label !== '') ? ('备用源' + (i + 1) + '-' + es.label) : ('备用源' + (i + 1));
			push(lines, nm + ',' + base + '/ch/' + (9001 + i));
		}
	}
	return join('\n', lines) + '\n';
}

// 说明：本服务只做流媒体后端（/health /m3u /txt /ch/<pid>），
// 不再自带管理网页 —— 配置与管理全部在 LuCI 的「服务 → 咪咕直播」里完成，
// 由 /usr/share/rpcd/ucode/migu 提供 ubus 接口支撑。
// 这样同一份 UCI 配置只有一个维护入口，避免两套界面互相覆盖。

// ---------- 处理器 ----------
//
// /health 在 1.3.0 里从「只是个探活接口」升级成了**优化效果的观测窗口**：
// 暴露缓存命中率、平均解析耗时、当前连接数、EPG 状态。
// 判断这次改造有没有用，看这几个数就够了，不用去翻日志。
function handleHealth(conn) {
	let groups = allChannels();
	let total = 0;
	for (let g in groups) total += length(g.dataList);

	// 当前缓存的取流条目里，成功/失败各多少
	let cacheOk = 0, cacheFail = 0;
	for (let k in streamCache) {
		if (streamCache[k].url) cacheOk++;
		else cacheFail++;
	}

	// 平均解析耗时（只算未命中、真正走了网络的请求）
	let avgMs = 0;
	let misses = stats.chMiss;
	if (misses > 0) avgMs = int(stats.resolveMsSum / misses);

	let uptime = time() - stats.startedAt;
	let hitRate = 0;
	if (stats.chTotal > 0) hitRate = int(stats.chHit * 100 / stats.chTotal);

	jsonResponse(conn, 200, {
		ok: true,
		service: 'luci-app-migu-iptv',
		version: APP_VERSION,
		channels: total,
		groups: length(groups),
		guest: cfg.isGuest,
		rateType: cfg.rateType,
		cacheAge: time() - chanCache.at,
		publicAccess: cfg.publicAccess,
		publicTokenSet: cfg.publicToken !== '',
		publicBaseUrl: cfg.publicBaseUrl,

		// ---- 运行统计（1.3.0 新增）----
		uptime: uptime,
		requests: stats.reqTotal,
		chRequests: stats.chTotal,
		chCacheHits: stats.chHit,
		chCacheMisses: misses,
		chHitRatePct: hitRate,
		avgResolveMs: avgMs,
		chFallback: stats.chFallback,
		denied: stats.denied,
		rejectedByLimit: stats.rejected,
		activeConns: length(connections),
		maxConns: cfg.maxConns,

		// ---- 缓存配置与现状 ----
		streamTtl: cfg.streamTtl,
		failTtl: cfg.failTtl,
		streamCacheOk: cacheOk,
		streamCacheFail: cacheFail,
		recentPids: recentPids,
		debug: cfg.debug,

		// ---- EPG 状态 ----
		epgEnabled: (cfg.epgUrl !== '' && cfg.epgRefreshHours > 0),
		epgUrl: cfg.epgUrl,
		epgIds: epgState.ids ? length(epgState.ids) : 0,
		epgAge: epgState.at > 0 ? (time() - epgState.at) : -1,
		epgOk: epgState.ok,
	});
}

function handleM3u(conn, base) {
	let body = buildM3u(base);
	rawResponse(conn, 200, 'application/x-mpegurl; charset=utf-8', body, null);
}

function handleTxt(conn, base) {
	let body = buildTxt(base);
	rawResponse(conn, 200, 'text/plain; charset=utf-8', body, null);
}

// 版权受限时的回落表：pid → 备用 pid
//
// 背景：咪咕对 CCTV5 这类有独家赛事转播的频道，会在赛事时段按内容 ID
// 硬锁（COPYRIGHT_SHIELD_INVALID / playCode 403001006），实测 8 种请求头
// 组合全部无效，属于服务端策略，客户端无法绕过。
//
// 但 CCTV5 和 CCTV5+ 播的是重叠的赛事内容，CCTV5 被锁时 CCTV5+ 通常仍
// 可播（实测本机 CCTV5+ 正常返回 302）。所以这里做一次自动回落，
// 让用户在锁时段至少还能看到比赛，而不是直接吃一个 502。
//
// 回落只在主频道取流失败时发生，成功路径完全不受影响。
const FALLBACK_PID = {
	'641886683': '641886773',   // CCTV5 体育 → CCTV5+ 体育赛事
};

function handleChannel(conn, pid) {
	if (pid === '' || match(pid, /[^0-9]/)) {
		jsonResponse(conn, 400, { ok: false, error: '频道 ID 必须是数字' });
		return;
	}

	// pid >= 9001 = 外部备用源独立频道（用户手动选择的线路）
	//
	// 直连频道按索引精确取源，不做「跳到别的源」那种自作主张的替换 ——
	// 用户在 TV-BOX 里点的是第 N 条线路，就该拿到第 N 条。
	// 但源失效时必须给出明确错误，而不是甩一个打不开的地址让播放器干等：
	// 先探一次，不可用就返回 502 并说明原因（前端会显示「源不可用」而不是黑屏）。
	let extIdx = (+pid) - 9001;
	if (extIdx >= 0 && cfg.extSources && extIdx < length(cfg.extSources)) {
		let es = cfg.extSources[extIdx];
		if (!checkExternalSource(es.url)) {
			logErr('外部源频道 ' + pid + ' 不可用: ' + es.label + ' ' + es.url);
			jsonResponse(conn, 502, {
				ok: false,
				error: sprintf('备用源「%s」当前不可用，请在设置里换一条线路或稍后重试', es.label),
				url: es.url,
			});
			return;
		}
		logInfo('外部源直接访问: ' + es.label + ' ' + es.url);
		redirectResponse(conn, es.url, null);
		return;
	}

	let r = resolveStream(pid);

	// 记一次「最近访问」（供后台预热），只有真正解析过的频道才值得预热。
	// 放在缓存判断之后没有意义（resolveStream 内部已经区分了），这里统一记，
	// 因为「用户刚看过」本身就是预热的依据 —— 哪怕这次是命中缓存。
	touchRecent(pid);
	stats.chTotal++;
	if (r.cached) stats.chHit++; else stats.chMiss++;

	// 降级链第一层：咪咕版权盾 → 同源备用 pid（如 CCTV5 → CCTV5+）
	let fellBack = false;
	let srcLabel = '';
	if (r.url === '' && FALLBACK_PID[pid]) {
		let altPid = FALLBACK_PID[pid];
		let r2 = resolveStream(altPid);
		if (r2.url !== '') {
			logInfo(sprintf('channel %s 受版权限制，已回落到 %s', pid, altPid));
			r = r2;
			fellBack = true;
			srcLabel = '咪咕回落(CCTV5+)';
		}
	}

	// 降级链第二层：咪咕完全不可用 → 外部备用源
	if (r.url === '') {
		let ext = tryExternalSources();
		if (ext) {
			logInfo(sprintf('channel %s 咪咕不可用，已切换外部源 [%s]', pid, ext.label));
			r = { url: ext.url, rid: 'EXTERNAL', rateType: cfg.rateType, at: time(), err: '' };
			fellBack = true;
			srcLabel = ext.label;
		}
	}

	if (r.url === '') {
		logErr('channel ' + pid + ' 取流失败: ' + r.err);
		jsonResponse(conn, 502, { ok: false, error: r.err, rid: r.rid });
		return;
	}
	// 回落时把实际来源告诉播放器（自定义头，标准播放器会忽略）
	//
	// 同时记一次「降级成功」。原因是 /health 的两个数字容易让人误判：
	// streamCacheOk 只统计咪咕直接解析成功并落缓存的条目，
	// 而「咪咕失败 → 外部源顶替成功」这条路径不会把失败条目改写成成功
	// （刻意不缓存失败，理由见 resolveStream 注释），
	// 于是版权盾时段会出现 streamCacheOk=0 / streamCacheFail=N 的观感。
	// 用 chFallback 把这类请求单独计数，健康面板才不会读成「全挂了」。
	if (fellBack) stats.chFallback++;
	let fb = fellBack ? (srcLabel !== '' ? ('src=' + srcLabel) : 'fallback') : null;
	redirectResponse(conn, r.url, fb);
}

// ---------- 分发 ----------
function dispatch(conn, head, body) {
	let req = parseHead(head);
	let method = req.method;
	let qIdx = index(req.path, '?');
	let path = (qIdx >= 0) ? substr(req.path, 0, qIdx) : req.path;
	let host = req.headers['host'] || (cfg.host + ':' + cfg.port);

	stats.reqTotal++;

	// 去掉可能存在的令牌路径前缀：/TOKEN/m3u → /m3u
	//
	// 这样公网订阅地址可以写成 https://域名/TOKEN/m3u，
	// 播放器无需理解查询参数，兼容性最好。
	if (cfg.publicToken !== '') {
		let prefix = '/' + cfg.publicToken;
		if (substr(path, 0, length(prefix)) === prefix) {
			let rest = substr(path, length(prefix));
			if (rest === '' || substr(rest, 0, 1) === '/') path = rest;
		}
	}

	// /health 始终放行（用于探活，不含任何隐私信息）
	if (method === 'GET' && path === '/health') {
		handleHealth(conn);
		return;
	}

	// 其余接口先过访问控制
	//
	// 用原始 req.path 做令牌提取（因为上面的 path 已经剥掉前缀了）
	let access = checkAccess(conn, conn.ip, req.path);
	if (!access.allow) {
		stats.denied++;
		logErr('拒绝访问 ' + conn.ip + ' → ' + req.path + '：' + access.error);
		jsonResponse(conn, access.code || 403, {
			ok: false,
			error: access.error,
			hint: cfg.publicAccess ? '' : '内网访问不受影响。',
		});
		return;
	}

	// 对外基地址（拼播放列表里的取流地址用）
	let base = externalBase(host, access);

	// /m3u /txt
	if (method === 'GET' && path === '/m3u') {
		stats.m3uTotal++;
		handleM3u(conn, base);
		return;
	}
	if (method === 'GET' && path === '/txt') {
		stats.m3uTotal++;
		handleTxt(conn, base);
		return;
	}

	// /ch/<pid> —— 取流，按需 302
	if (method === 'GET' && substr(path, 0, 4) === '/ch/') {
		handleChannel(conn, substr(path, 4));
		return;
	}

	// 老管理页地址已被 LuCI 取代，统一跳转，避免书签失效后看到 404
	if (path === '/admin' || substr(path, 0, 6) === '/admin') {
		redirectResponse(conn, '/');
		return;
	}

	// 根路径 → 回 LuCI 的咪咕直播页（管理入口只有 LuCI 一个）
	if (method === 'GET' && (path === '/' || path === '')) {
		let luciHost = host;
		let ci = index(luciHost, ':');
		if (ci >= 0) luciHost = substr(luciHost, 0, ci);
		redirectResponse(conn, 'http://' + luciHost + '/cgi-bin/luci/admin/services/migu');
		return;
	}

	jsonResponse(conn, 404, { ok: false, error: 'not found' });
}

// ---------- 服务端循环 ----------
function onData(conn) {
	if (conn.closed) return;
	let chunk;
	try { chunk = conn.sock.recv(8192); } catch (e) { closeConn(conn); return; }
	if (chunk === null) { closeConn(conn); return; }
	if (length(chunk) === 0) { closeConn(conn); return; }

	conn.buf += chunk;
	if (conn.headerEnd < 0) {
		let idx = index(conn.buf, '\r\n\r\n');
		if (idx < 0) {
			if (length(conn.buf) > 65536) closeConn(conn);
			return;
		}
		conn.headerEnd = idx + 4;
		conn.head = substr(conn.buf, 0, idx);
		let cl = match(conn.head, /\r\nContent-Length:\s*([0-9]+)/i);
		conn.bodyLen = cl ? +cl[1] : 0;
	}
	let got = length(conn.buf) - conn.headerEnd;
	if (got < conn.bodyLen) return;

	let body = substr(conn.buf, conn.headerEnd, conn.bodyLen);
	try {
		dispatch(conn, conn.head, body);
	} catch (e) {
		logErr('dispatch error: ' + e);
		jsonResponse(conn, 500, { ok: false, error: '' + e });
	}
}

// 非阻塞地把一个连接上「已经排队」的请求字节读掉。
//
// 只用于拒绝路径：close() 之后如果接收队列还留着未读数据，Linux 会发 RST
// 而不是 FIN，把刚写出去的 503 响应一起带走。读干净就不会 RST。
//
// 两个关键点：
//   - MSG_DONTWAIT：读空时返回 null（error() 为 EAGAIN），不会阻塞事件循环。
//     这个进程是单线程的，绝不能在拒绝路径上阻塞。
//   - 限次：正常请求（哪怕带一堆头）几轮就空了；万一对端在灌数据，也不能
//     让这个循环把事件循环占住，所以最多 maxRounds 轮就放弃（剩下的交给
//     RST 兜底，不影响正确性）。
function drainQueued(peer, maxRounds) {
	for (let i = 0; i < maxRounds; i++) {
		let chunk = null;
		try { chunk = peer.recv(8192, socket.MSG_DONTWAIT); } catch (e) { return; }
		if (chunk === null || length(chunk) === 0) return;
	}
}

function onAccept(listenSock) {
	let addr = {};
	let peer = listenSock.accept(addr, socket.SOCK_CLOEXEC);
	if (!peer) return;
	try { peer.setopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true); } catch (e) { }

	// 并发上限保护。
	//
	// 这个进程是单线程事件循环，而取流路径上的 curl 是同步 popen —— 解析
	// 期间整个循环都停住（实测 3 个未缓存频道并发就变成 0.51/1.07/1.07s，
	// 纯排队）。而 8788 这个口在公网上是开着的（firewall.migu_wan / 
	// migu_wan8888 都做了 DNAT），日志里已经能看到境外 IP 在扫。
	// 没有上限的话，一批扫描连接就能把服务拖到不可用。
	//
	// 超限时立刻回 503 并关闭连接 —— 比默默排队要好：扫描器拿到明确响应就
	// 走了，不会占着 fd 干等。
	if (length(connections) >= cfg.maxConns) {
		stats.rejected++;
		try {
			// ---- 1.4.1 修正：拒绝路径必须先读走请求字节，否则 503 会被 RST 吃掉 ----
			//
			// 现象：改造后实测这条拒绝路径大约有 58% 的概率客户端收到
			// ECONNRESET 且字节数为 0 —— 503 响应体根本没送达。
			//
			// 成因：send() 之后立刻 close()，而服务端从未 recv() 过这个连接。
			// Linux 在 close() 时若发现接收队列还有未读数据，会发 RST 而不是 FIN；
			// RST 会让对端丢弃已到达的接收缓冲，于是刚写出去的 503 一起被丢掉。
			//
			// 判别实验（各 60 次）：连上后一个字节都不发的变体丢包 0/60；
			// 连上立即发请求的变体丢包 35/60（58.3%）——唯一差异就是接收队列是否为空。
			//
			// 修法分两步，缺一不可：
			//   ① 用 MSG_DONTWAIT 把已排队的请求字节读干净（实测读空时返回 null
			//      且 error() 为 EAGAIN，不会阻塞事件循环）；
			//   ② 发完 503 后先 shutdown(SHUT_WR) 再 close()——shutdown 会老老实实
			//      发 FIN（实测客户端读到 len=0 的干净 EOF），避免 close() 因残留
			//      数据再次触发 RST。
			//
			// 代价：最多多 1 次 recv 系统调用。收益：503 稳定送达，扫描器/播放器
			// 能拿到明确的「稍后重试」语义（Retry-After: 2），而不是连接重置。
			//
			// 代价：最多多几次 recv 系统调用。收益：503 稳定送达，扫描器/播放器
			// 能拿到明确的「稍后重试」语义（Retry-After: 2），而不是连接重置。
			drainQueued(peer, 16);

			// Content-Length 必须按字节数算 —— 中文在 UTF-8 下是 3 字节，
			// 写死数字会算出错误的长度，客户端就会一直等剩下的字节。
			let busyBody = '{"ok":false,"error":"服务繁忙，请稍后重试（连接数已达上限）"}';
			peer.send('HTTP/1.1 503 Service Unavailable\r\n' +
				'Content-Type: application/json; charset=utf-8\r\n' +
				'Content-Length: ' + length(busyBody) + '\r\n' +
				'Connection: close\r\n' +
				'Retry-After: 2\r\n' +
				'\r\n' +
				busyBody);
			// 先半关写方向（发出 FIN），再释放 fd
			try { peer.shutdown(socket.SHUT_WR); } catch (e) { }
			// 关闭前最后再收一次：从上面那次 recv 到现在，对端可能又补发了字节
			// （TCP 分段或慢启动），close() 时队列非空依然会发 RST。多读一轮基本
			// 覆盖这个窗口，代价可忽略。
			drainQueued(peer, 16);
			peer.close();
		} catch (e) { }
		logErr('连接数达上限 ' + cfg.maxConns + '，拒绝 ' + ((addr && addr.address) ? addr.address : '?'));
		return;
	}

	let conn = {
		sock: peer, buf: '', handle: null, headersSent: false, closed: false,
		bodyLen: 0, headerEnd: -1, ip: (addr && addr.address) ? addr.address : '?',
	};
	push(connections, conn);
	conn.handle = uloop.handle(peer, () => onData(conn), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// 最近频道预热定时器的回调（用函数声明，理由见 main() 里的注释）
function warmTickFn() {
	// ⚠️ ucode 不支持 try/catch/finally，只支持 try/catch
	//（实测 `} finally {` 直接报 Syntax error: Unexpected token，整份文件都编译不过）
	try {
		warmRecentChannels();
	} catch (e) {
		logErr('最近频道预热异常: ' + e);
	}
	// 无论成功失败都要重排下一次，否则预热链断掉（且异常会结束进程）
	try { recentTimer = uloop.timer(120000, warmTickFn); }
	catch (e2) { logErr('预热重排失败: ' + e2); }
}

function main() {
	cfg = loadConfig();
	if (!cfg.enabled) {
		logInfo('service disabled in config');
		return;
	}

	uloop.init();
	let listenSock = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
	if (!listenSock) {
		logErr('socket create failed: ' + socket.error());
		return;
	}
	listenSock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	if (!listenSock.bind(cfg.host + ':' + cfg.port)) {
		logErr('bind failed on ' + cfg.host + ':' + cfg.port + ': ' + listenSock.error());
		return;
	}
	if (!listenSock.listen(64)) {
		logErr('listen failed: ' + listenSock.error());
		return;
	}
	uloop.handle(listenSock, () => onAccept(listenSock), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);

	logInfo(sprintf('listening on %s:%d (guest=%s, rateType=%d)',
		cfg.host, cfg.port, cfg.isGuest ? 'yes' : 'no', cfg.rateType));

	// 预热频道列表：启动 1.5 秒后后台拉取一次，让首个 /m3u 请求不等待。
	// 拉取失败只记日志，不让预热错误把服务进程带崩。
	//
	// 句柄必须存进模块级变量：uloop.timer() 返回的句柄如果没有任何引用，
	// 会被 GC 回收，回调可能就此静默失效 —— 现象是「启动日志里偶尔有、
	// 偶尔没有 warmed 那行」，很难查。旧版就是直接 uloop.timer(...) 不接收
	// 返回值。同机的 WorkBuddy 中转踩过完全一样的坑。
	warmTimer = uloop.timer(1500, () => {
		try {
			let g = allChannels();
			let total = 0;
			for (let x in g) total += length(x.dataList);
			logInfo('channel cache warmed: ' + total + ' channels in ' + length(g) + ' groups');
		} catch (e) {
			logErr('warmup failed: ' + e);
		}
	});

	// EPG 首次拉取：延后 8 秒，等频道预热和可能的开机请求先过去。
	// 拉取本身走后台任务，不会占住事件循环（原因见 epgStartFetch 注释）。
	if (cfg.epgUrl !== '' && cfg.epgRefreshHours > 0) {
		epgTimer = uloop.timer(8000, epgTickFn);
	}

	// 最近频道预热：周期性把最近看过的几个频道重新解析一遍，让「换回来」
	// 也命中缓存。换台体验里最难受的就是「刚看过的台回去又要等一秒」。
	//
	// 两个克制点：
	//   1) 只在 recentPids 变化过之后才刷新（warmRecentChannels 内部用指纹比对），
	//      没人看的时候不做无用功；
	//   2) 间隔 120 秒、每次最多 cfg.warmRecent 个，且都在同一个定时器回调里
	//      顺序执行 —— 解析本身还是会短暂占住事件循环，所以这个节流是必要的。
	//
	// 注意这里用**函数声明**而不是 `let warmTick = () => {...}`：
	// ucode 的编译期检查会报
	//   Syntax error: Can't access lexical declaration 'warmTick' before initialization
	// （自引用箭头函数在 let 初始化完成前就捕获了这个绑定）。函数声明没有这个
	// 问题，而且能正常被回调尾重排引用。
	if (cfg.warmRecent > 0) {
		recentTimer = uloop.timer(20000, warmTickFn);
	}

	uloop.run();
	uloop.done();
}

main();
