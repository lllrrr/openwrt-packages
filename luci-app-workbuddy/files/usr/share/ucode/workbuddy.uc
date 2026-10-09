#!/usr/bin/ucode
// ============================================================
// workbuddy.uc — WorkBuddy 免费模型 OpenAI 兼容代理（OpenWrt 原生实现）
//
// 在路由器上监听一个 HTTP 端口，把 WorkBuddy 的三条硬性要求适配成
// 标准 OpenAI 接口，供局域网设备（DSH / OpenAI 客户端）使用：
//   1. 只接受流式（非流式请求由本代理收集 SSE 后合并）
//   2. 首条消息必须是 system prompt（不是则自动插入）
//   3. 鉴权用 WorkBuddy 账号的 accessToken
//
// 架构说明：ucode 的 socket 模块没有 TLS 能力，因此上游 HTTPS 请求
// 统一交给 curl 子进程完成（fs.popen + uloop.handle 流式读取），
// 本进程只负责 HTTP 服务端与流式转发。
//
// 用法: ucode /usr/share/ucode/workbuddy.uc
// 配置: /etc/config/workbuddy (UCI)
// ============================================================

'use strict';

import { readfile, writefile, popen, access, mkdir, error, unlink } from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as uci from 'uci';

// ---------- 日志 ----------
// 本 ucode 版本的 log 模块提供 syslog(level, fmt, ...)，没有 log.info()/log.err()。
// 这里统一输出到 stdout/stderr，由 init.d 重定向到 syslog，避免依赖具体 log API。
function logMsg(level, msg) {
	printf('[workbuddy] %s: %s\n', level, msg);
}
function logInfo(msg) { logMsg('info', msg); }
function logErr(msg) { logMsg('error', msg); }

// ---------- 常量 ----------

const APP_VERSION = '3.0.0';

// 产品显示名。集中在这里，改名字只需改这一处。
//
// 注意：这只是"对外可见的名字"，与内部标识符是两回事 ——
// UCI 配置节、init.d 服务名、ucode 模块名都仍叫 workbuddy，
// 因为 WorkBuddy 上游的登录流程、凭据池、已有配置文件都绑定在这些路径上。
// 改内部名需要数据迁移，且会打断正在运行的实例。
const APP_NAME = 'AI 中转服务器';

// 前向引用表：用于绕开 ucode 的函数不提升限制。
// 凡是「定义在文件靠后、但被靠前的函数调用」的函数，都挂在这里按需取用。
// 目前包含：runCurl（clientVersion 用）、spawnUpstream/tryNextCred/onUpstreamEnd
// （三者互相递归，纯排序无法解开）。
// 必须在任何使用它的函数之前声明：ucode 的顶层 let/const 同样不提升。
let F = {};

// ---------- 基础工具函数 ----------
//
// ucode 不提升函数，且按定义时的词法作用域解析标识符：
// 一个函数若调用「在文件中出现得更晚」的函数，运行时就会抛
// "access to undeclared variable <name>"。
// 因此所有被广泛复用的底层工具必须放在文件最前面，集中在这里。

// 取 sha256 十六进制（小写）。
// 注意：sha256 不是全局函数，必须 require('digest')；
// 直接调用 digest() 会报 "left-hand side is not a function"。
function sha256Hex(s) {
	let d = require('digest');
	return '' + d.sha256('' + s);
}

// 恒定时间比较，降低时序侧信道影响
function secureEq(a, b) {
	if (type(a) !== 'string' || type(b) !== 'string') return false;
	if (length(a) !== length(b)) return false;
	let diff = 0;
	for (let i = 0; i < length(a); i++)
		diff |= (ord(substr(a, i, 1)) ^ ord(substr(b, i, 1)));
	return diff === 0;
}

// 宽松布尔判断：前端与 rpcd 传来的可能是 1/0、"true"/"false"、
// 真布尔或 "on"/"yes"，统一归一。
function truthy(v) {
	return (v === true || v === 1 || v === '1' || v === 'true' ||
		v === 'on' || v === 'yes');
}

// 读系统熵；失败时用时间戳兜底（仍可用，只是熵弱一些）。
// open()/writefile() 在某些调用上下文里不是全局函数，必须走 fs 模块。
let keySeq = 0;

function readRandom(n) {
	try {
		let fs = require('fs');
		if (fs && type(fs.open) === 'function') {
			let f = fs.open('/dev/urandom', 'r');
			if (f) {
				let b = f.read(n);
				f.close();
				if (b && length(b) > 0) return b;
			}
		}
	} catch (e) {
		// 忽略，走兜底
	}
	return '' + time() + '.' + keySeq;
}

// 生成 wb-<8>-<4>-<4>-<4>-<12> 形式的密钥。
// 熵来源：时间戳 + 进程内自增计数 + /dev/urandom，再经 sha256 混合。
// rand()/getpid() 在这个 ucode 构建里不可用，不要使用。
function genApiKey() {
	keySeq++;
	let seed = '' + time() + '|' + keySeq + '|' + readRandom(32);
	let h = sha256Hex(seed);
	return 'wb-' + substr(h, 0, 8) + '-' + substr(h, 8, 4) + '-' +
		substr(h, 12, 4) + '-' + substr(h, 16, 4) + '-' + substr(h, 20, 12);
}

// v2.1.0：生成请求级关联 ID（12 位 hex，随 X-Request-Id 透传上游并在日志/响应头出现）。
// 熵源与 genApiKey 相同（时间戳 + 自增 + /dev/urandom），碰撞概率可忽略。
function genReqId() {
	let h = sha256Hex('' + time() + '.' + keySeq + readRandom(8));
	return substr(h, 0, 12);
}

// v2.1.0：退避抖动因子，返回 [0.8, 1.2)。rand() 在本 ucode 构建不可用，
// 用 clock() 的纳秒位做廉价伪随机 —— 对退避抖动足够（目的是打破多客户端
// 同步重试，不需要密码学强度）。
function jitterFactor() {
	let ns = clock()[1];
	return 0.8 + ((ns % 1000000) / 1000000.0) * 0.4;
}

// 原子写 JSON：先写临时文件再 rename，避免掉电/中断留下半截文件。
// 权限 600，因为文件里有密钥与令牌。
// 注意：ucode 字符串没有 .replace()/.match() 方法，路径用 fs.dirname()。
function writeJsonFile(path, obj) {
	try {
		let fs = require('fs');
		let dir = fs.dirname(path);
		if (dir && dir !== '' && !fs.access(dir, 'f')) fs.mkdir(dir, 448);  // 0700

		let tmp = path + '.tmp';
		fs.writefile(tmp, sprintf('%.J\n', obj));
		fs.rename(tmp, path);
		try { fs.chmod(path, 384); } catch (e) { }  // 0600
		return true;
	} catch (e) {
		logErr('writeJsonFile failed for ' + path + ': ' + e);
		return false;
	}
}

function readJsonFile(path) {
	try {
		let fs = require('fs');
		if (!fs.access(path, 'f')) return null;
		let raw = fs.readfile(path);
		if (!raw) return null;
		return json(raw);
	} catch (e) {
		return null;
	}
}

const FREE_MODELS = ['deepseek-v4.1-flash', 'hy4-preview-f', 'hy3'];
const LOGIN_POLL_MS = 1000;
const LOGIN_TIMEOUT_MS = 300000;
const CODE_LOGIN_ING = 11217;

// ---------- JWT / 凭据检查 ----------
//
// WorkBuddy 的 accessToken 是标准 JWT（三段点分）。第二段 payload 里有：
//   exp                过期时间（Unix 秒）—— 用来做过期提示与自动跳过
//   preferred_username 账号名 —— 用来给凭据起可读名字
//   sub                账号唯一 ID —— 用来识别同一账号的重复凭据
//
// ucode 既没有 base64 模块，也没有全局 b64dec/popen，所以这里自己实现
// base64url 解码。只需要「解码」，不需要编码。

const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

// 建一个字符 -> 6bit 值的查找表（模块加载时建一次，之后只读）
let b64Table = {};
for (let i = 0; i < length(B64_CHARS); i++)
	b64Table[substr(B64_CHARS, i, 1)] = i;

// base64url 解码为字符串。忽略 padding 与非法字符。
// 只用于解析 JWT 头部与 payload（都是 UTF-8 JSON），够用即可。
//
// 性能说明：本机是 ARMv8（BogoMIPS 48）+ 解释执行的 ucode，任何"逐字符
// 调一次函数"的写法都要付真实代价 —— 最初实现（逐字符 substr + 查表函数
// 调用）解码 843 字符的 payload 要 18–21ms。改为「每 4 字符一组、组内直接
// 查表、结果累积到数组再 join」后降到 11ms。
// 真正的开销大头不在这里，而在 parseJwt 的记忆化（见下）。
function b64UrlDecode(s) {
	if (type(s) !== 'string') return '';
	let n = length(s);
	if (n === 0) return '';

	let tab = b64Table;

	// 补齐到 4 的倍数：JWT 用无 padding 的 base64url，而按 4 字符分组
	// 解码需要完整组。补 '=' 而不是 'A'，这样末尾不会多输出字节。
	let pad = (4 - (n % 4)) % 4;
	let str = (pad > 0) ? (s + substr('====', 0, pad)) : s;
	let m = length(str);
	let acc = [];

	for (let i = 0; i < m; i += 4) {
		let c0 = substr(str, i, 1), c1 = substr(str, i + 1, 1);
		let c2 = substr(str, i + 2, 1), c3 = substr(str, i + 3, 1);
		if (c0 === '-') c0 = '+'; else if (c0 === '_') c0 = '/';
		if (c1 === '-') c1 = '+'; else if (c1 === '_') c1 = '/';
		if (c2 === '-') c2 = '+'; else if (c2 === '_') c2 = '/';
		if (c3 === '-') c3 = '+'; else if (c3 === '_') c3 = '/';

		let v0 = tab[c0], v1 = tab[c1], v2 = tab[c2], v3 = tab[c3];
		if (type(v0) !== 'int') continue;        // 组首非法：整组丢弃
		v1 = (type(v1) === 'int') ? v1 : 0;
		v2 = (type(v2) === 'int') ? v2 : 0;
		v3 = (type(v3) === 'int') ? v3 : 0;

		let w = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
		push(acc, chr((w >> 16) & 0xff));
		if (c2 !== '=') push(acc, chr((w >> 8) & 0xff));
		if (c3 !== '=') push(acc, chr(w & 0xff));
	}
	return join('', acc);
}

// 解析 JWT，返回 { exp, iat, username, sub } 或 null。
// 完全不验签：这里的用途只是读过期时间与账号名，不做安全判断。
function parseJwtUncached(token) {
	if (type(token) !== 'string' || length(token) === 0) return null;

	// 按点号切三段。原先用逐字符循环拼接，1298 字符要 10ms；
	// split() 是原生实现，几乎免费。
	let parts = split(token, '.');
	if (length(parts) < 2) return null;

	let payload;
	try {
		payload = json(b64UrlDecode(parts[1]));
	} catch (e) {
		return null;
	}
	if (type(payload) !== 'object' || payload === null) return null;

	let out = {};
	out.exp = (type(payload.exp) === 'int') ? payload.exp : 0;
	out.iat = (type(payload.iat) === 'int') ? payload.iat : 0;
	out.username = '' + (payload.preferred_username || payload.email || '');
	out.sub = '' + (payload.sub || '');
	return out;
}

// ---- parseJwt 记忆化：本插件最大的一处 CPU 开销 ----
//
// 实测（本机 ARMv8 / BogoMIPS 48，ucode 解释执行）：
//   完整解析一个 1298 字符的 accessToken = 31ms
//     ├─ 逐字符切三段                      10ms
//     └─ base64url 解码 843 字符 payload    21ms
// 而 loadPool() 每处理一个凭据要调它两次（credStatus 一次、取 sub 一次），
// 于是**单次 /health 就有 95ms 纯 CPU 花在这里**；转发链路上 loadPool /
// usablePool 被多处调用，开销按调用次数翻倍 —— 这才是"转发慢"的真正原因，
// 与网络、与 curl 参数都无关。
//
// token 是不可变的：同一条 token 的 claims 永远相同，换了 token 就是另一个
// 键。所以按 token 记忆化即可 —— 首次 11ms，之后约 0.00001ms。
// 表上限 16 条，避免异常输入把内存撑大；失败结果也缓存（避免反复解析坏 token）。
let jwtCache = {};
let jwtCacheN = 0;

function parseJwt(token) {
	if (type(token) !== 'string' || length(token) === 0) return null;

	let hit = jwtCache[token];
	// 用 type() 判定而不是 `!== undefined`：ucode 里普通对象的键查询可能
	// 命中原型链上的同名属性（返回函数），那样会被误当成解析结果。
	if (type(hit) === 'object' && hit !== null) return hit;
	if (hit === false) return null;

	let r = parseJwtUncached(token);
	if (jwtCacheN < 16) {
		jwtCache[token] = r ? r : false;
		jwtCacheN++;
	}
	return r;
}

// 凭据状态：'ok' | 'expiring'（7 天内过期）| 'expired' | 'unknown'
function credStatus(token, now) {
	let j = parseJwt(token);
	if (j === null || !j.exp) return 'unknown';
	if (j.exp <= now) return 'expired';
	if (j.exp - now < 7 * 86400) return 'expiring';
	return 'ok';
}

// 凭据池文件：单个 JSON 保存多条凭据
// 注意：ucode 没有 opendir/readdir，无法遍历目录，因此池必须放在一个文件里。
const TOKEN_POOL_FILE = '/etc/workbuddy/pool.json';

// ---------- v2.2.0：中转决策日志 ----------
//
// 目的：把"每个请求走了哪个账号、为什么换、换了多久、结尾成不成"记成
// 结构化事件，供后续**用数据调轮换规则**，而不是靠猜。
//
// 为什么不用 printf 日志了事：轮换规则要优化，需要回答的是统计问题 ——
//   · 哪个账号在什么时段最容易被限流？
//   · 429 之后换号，下一个账号成功的概率是多少？
//   · 冷却 5s 够不够？有多少请求是"等冷却"等掉的？
//   · 同一账号连续失败几次才真的坏？
// 这些靠翻 syslog 全文根本算不出来，必须落成定长环缓冲 + 聚合计数器，
// 由 /admin 与 /metrics 直接读。
//
// 存储形态：内存环缓冲（重启即失），不落盘 ——
//   /overlay 只有 32MB 可用，写盘日志会拖累闪存寿命且迟早写满；
//   需要长期留存时由外部 syslog 收集，本模块只负责"最近 N 条 + 累计聚合"。
const RELAY_LOG_MAX = 200;        // 环缓冲保留的最近事件条数
const RELAY_MIN_SAMPLES = 3;     // 成功率权重的最小样本量：少于此数视为"无数据"，权重退回 1
const RELAY_RECENT_MIN = 3;      // v2.4.0：近期健康度窗口——看该账号最近几次选中（与账号矩阵的「近期」列一致）

// 中转事件类型。用短字符串而非数字：日志要给人看，也要能被 grep。
//   pick     选中某个账号开始尝试
//   ok       该账号这次成功了
//   rate     被限流（429 / tpm/rpm）
//   risk     账号被风控（11140 等）
//   auth     鉴权失败（401/403）
//   client   客户端错误（请求本身有问题，换号无意义）
//   net      网络/上游 5xx 等
//   cool     账号进入冷却
//   switch   因上一个账号失败而换到下一个
//   exhaust  所有账号试完仍未成功
//   abort    客户端中途断开
//   trunc    流式被截断（未收到 [DONE]）

// API 密钥文件：由 LuCI 通过 rpcd 维护
const APIKEY_FILE = '/etc/workbuddy/apikeys.json';
// WorkBuddy 自身上游在模型列表里的供应商前缀。
// 所有来源统一带前缀，客户端可据此选择走哪个上游。
const WB_PREFIX = 'workbuddy';
// 凭据冷却时长（秒）：被限流/拒绝后暂不使用
const COOL_MS = 60;
// 单个请求最多尝试的凭据数
const MAX_TRY = 3;

// 账号被风控时的凭据冷却时长（秒）。
//
// 上游对「内容未通过安全审核」（code 11140）这类拦截是**账号级**的：
// 实测同一账号对 "hi" / "1+1=?" / 中文闲聊一律返回 11140，
// 而 system prompt 缺失时给的是另一个码（11-128），说明请求本身没写错，
// 是账号被风控了。这种状态下对同一账号重试毫无意义，反而加重风控。
// 因此给足 30 分钟，把多凭据池的机会让给其他账号 —— 这才是"智能换 Key"
// 该有的行为：能区分"账号坏了"和"网络抖了一下"。
const COOL_RISK = 1800;

// ---------- 转发效率参数 ----------
//
// 数值全部来自 2026-09-26 在 192.168.69.1 上的实测（见 lessons/workbuddy-forward-efficiency.md）
//
// 1) 上游 Key 的冷却。
//
// **设计原则（2026-09-28 按用户要求改）：冷却只影响"尝试顺序"，不影响"能不能试"。**
// 用户明确要求「不通的自动换下一个」—— 所以每把 Key 始终保持可尝试，
// 冷却只把它排到队尾，绝不把它锁死。
// 配套地，handleChat 里"全部冷却中就直接回 429"的提前返回已删除 ——
// 那句 `429 retry_after:577` 正是"一次请求错误让整个上游停摆 10 分钟"的来源。
//
// 历史上这里给到 20s→300s 指数退避、鉴权档 600s，理由是"避免同一把 Key 被
// 立刻再次选中而连撞限流、造成 12~60s 挂起"。但那个挂起的真正原因是
// **单次请求的重试次数没有上界**；现在 tryNextUpKey / spawnUpstreamDirect
// 用 `conn.upTry < length(conn.upKeys)` 把尝试次数钉死在 Key 总数以内
// （最多 4 次），所以短冷却不再有挂起风险。
const UP_RATE_COOL = 5;         // 限流类：起始 5s，连续失败翻倍
const UP_RATE_COOL_MAX = 20;    // 限流类冷却上限 20s
const UP_AUTH_COOL = 60;        // 鉴权类：Key 疑似失效，最多避开 60s
const UP_SOFT_COOL = 2;         // 空响应/网络抖动：短暂避让
// v2.1.0：
//   - 响应体/请求体上限（防极端大响应撑爆内存，见 makeOnChunk / onData）
//   - Retry-After 解析后直接采信上游窗口时的上限（防恶意/异常大头把 Key 永久冷却）
const MAX_SSE_BUF = 2097152;         // 2 MiB：所有响应体累积路径统一上限
const MAX_BODY_BYTES = 8388608;      // 8 MiB：入站请求体 Content-Length 上限，超限回 413
const MAX_RETRY_AFTER = 300;         // 5 分钟：直接采信 Retry-After 时的冷却上限
//
// 2) 上游静默看门狗。连接建立后连续 N 秒收不到任何字节即判定链路已死，
//    主动断开并按既有逻辑换 Key —— 客户端不再干等到自己超时。
//
//    v1.8.2 起按「首字节前 / 首字节后」分两档，因为这两段的性质完全不同：
//
//    首字节前：一个字节都没回，说明请求**根本没被上游受理** —— 限流挂起、
//    服务端排队、链路黑洞都属此类。此时干等毫无收益（那条连接不会自己好起来），
//    越早换 Key 越早拿到能用的 Key。实测池化后正常 TTFB p50 0.19~0.31s、
//    p99 2.0~2.5s，给 12s 已是 5 倍余量。
//
//    首字节后：流已经建立，模型在流中途"思考"（reasoning）时确实会长时间不吐字，
//    这是正常现象，误杀会让客户端白等一场。故阈值要大于"正常的最长思考停顿"。
//
//    实测依据（v1.8.1，60 请求 × 3 档并发）：13 个慢请求（≥5s）**全部成功**，
//    而客户端 p90 高达 30s —— 32 次看门狗中止全部发生在 25~29s（即首字节档），
//    慢的根因正是首字节前干等到 25s 才换 Key。把首字节档压到 12s，
//    是把这条尾巴砍掉的关键。
//
//    流中档的取值依据（v1.8.2，up_idle_sec 扫 60/30/25，各 60 请求）：
//    客户端 p90/p99/max ≈ up_idle_sec + UP_IDLE_TICK_MS —— 也就是说，**尾延迟
//    就是这一档本身**（超时那一刻才中止）。60s 档 p90 65.1s / 放大 1.08×，
//    25s 档 p90 28.9s / 放大 1.02×，成功率 58.3% vs 65.0% 在配额波动范围内
//    不可区分。故默认值取 25s：把"上游确实死了"的最坏等待从 65s 砍到 30s，
//    而以 SSE 逐字吐字的性质，25s 内一个字节都没有基本等于链路已断。
//    （真正需要长静默的上游请单独调大 up_idle_sec，或配 0 关闭该档。）
//
//    WorkBuddy 是 agent 上游，可能在静默工作，独立保持 75s。
//    任一档配 0 表示**关闭该档看门狗**（诊断链路时用）。
const UP_FIRST_BYTE_SEC_DEFAULT = 12;  // 首字节等待上限（未受理即换 Key）
const UP_IDLE_SEC_DEFAULT = 25;        // 首字节之后的流中静默上限
const WB_IDLE_SEC_DEFAULT = 75;        // WorkBuddy agent 路径静默上限
const UP_IDLE_TICK_MS = 5000;          // 看门狗扫描间隔
//
// 3) 自定义上游模型列表缓存。/v1/models 原来每次都逐个上游外呼，实测单上游
//    一次 1.66s；缓存后除首次外全走内存。
const UP_MODEL_TTL = 300;

//
// 4) 转发并发闸门 + FIFO 排队（v1.8.0）。
//
//    背景：v1.7.x 对并发**完全不设限**。N 个客户端同时进来就是 N 个 curl 同时
//    打上游，而上游限的是 tpm/rpm 而非连接数 —— 并发越高越容易整批撞 429，
//    表现就是"人一多，所有人一起失败"。排队把突发削成上游吃得下的形状，
//    代价是队尾请求的首字节变晚。
//
//    上限按**每个上游**分别设，不设全局：不同上游是不同账号、不同额度，
//    互相排队没有意义；WorkBuddy 是 agent 上游、单请求耗时长，额度给得更大。
//    0 = 不限制（退回 v1.7.x 行为，出问题可一键回退）。
const UP_MAX_INFLIGHT_DEFAULT = 4;   // 每个自定义上游默认在途上限
const WB_MAX_INFLIGHT_DEFAULT = 6;   // WorkBuddy 通道默认在途上限
const UP_QUEUE_MAX_DEFAULT = 32;     // 队列上限，超出立即 429（不无限攒请求）
const UP_QUEUE_TIMEOUT_DEFAULT = 20; // 排队等待上限（秒）
const UP_QUEUE_TICK_MS = 1000;       // 排队超时扫描间隔

//
// 5) 上游连接复用（常驻 workbuddy-pool 进程，v1.8.0）。
//
//    实测每请求固定开销：curl fork ~20ms + DNS ~9ms + 上游 TCP 49~87ms +
//    TLS 80~100ms。curl 每次调用都是新进程，连接池在 curl 里活不过一次请求，
//    这部分开销**在 ucode+curl 内无法消除**。做法是另起一个常驻进程持有到上游
//    的 TLS 连接池，curl 只连本机回环（源码与协议见仓库 pool/ 目录）。
//
//    回退是被动的：某次池化尝试"一个字节都没收到且尚未推流"即判定池不可用，
//    置一段冷却，本条请求立刻改用直连重发（且不消耗 Key 冷却）。冷却到期后
//    下次池化尝试成功即自动恢复 —— 不引入额外定时探活，不占单线程事件循环。
const POOL_FAIL_COOLDOWN = 30;       // 判定池挂掉后强制直连的时长（秒）
const POOL_CONNECT_TIMEOUT = 3;      // 走回环时连接超时要短，才能快速暴露池挂了

// ---------- v1.8.3：上游响应回环桥 ----------
//
// 背景：本 ucode 版本的 popen() 管道 + uloop 读循环在并发流式转发时会丢数据——
// 要么在 16384 读缓冲边界提前收 EOF（静默截断），要么可读事件丢失导致流永不收尾
// （probe2/probe3/probe6/probe7 离线复现）。根治办法是不再从 popen 管道读上游响应
// 体，而是让子进程把 stdout 经 nc 回环到一个本地 TCP socket，改由 socket 读路径
// （probe10 证明并发下字节精确、EOF 可靠）转发给客户端。
//
// bridge_port=0 关闭回环桥，退回直接 popen 读取（保留 v1.8.2 行为，诊断/回退用）。
//
// 【` &` 是桥的一部分，不是性能优化】bridgeWrap() 必须在管道尾部追加 ` &`。
// v1.8.3 漏了它，上线后 60 并发直接把服务打死：popen() 的直接子进程是那个 sh，
// 整条 `{ …; } | nc …` 管道在整个响应流期间都活着，于是任何一次 proc.close()
// （= pclose()/waitpid()）都要等管道退出才返回；单线程事件循环被钉在 do_wait，
// 40s 内一轮都没转（diag183：Recv-Q 固定 87423、/health 无响应、56/60 请求
// code=000）。加 ` &` 后 sh 立刻退出，pclose() 收的是已死子进程，实测 2 ms 返回，
// 事件循环 maxGap 502ms，5 并发 × 200200 字节逐字节精确、无串流
// （probe15 shape B FIX_OK；probe16 BG=1 3/3 ALL GOOD ↔ BG=0 20s 内 HUNG）。
//
// 【提前声明，勿删】loadConfig()（约 620 行，本文件最靠前的函数之一）要读
// BRIDGE_PORT_DEFAULT，而本文件 **不提升声明**：函数按定义时的词法作用域解析
// 标识符，声明若留在后面的常量区就会抛 `access to undeclared variable`。
// v1.8.1 的 cfg 崩溃（见下方 cfg 声明处的长注释）就是这一类问题，故这里必须前置。
const BRIDGE_PORT_DEFAULT = 8791;
const NC_PATH = '/usr/bin/nc';

// ---------- v2.8.0：模型可用性测试与每日刷新 ----------
//
// 用户需求（m14804）：优化测试确保所有模型正常可用；模型可能变更，因此
// 每天凌晨 1 点定时获取最新的模型。本块实现：
//   1) testUpstreamModel / testAllUpstreamModels：对每个启用上游的模型直接发
//      一个极小的 chat 请求验证可用性（/admin/api/upstreams/test-all 触发）；
//   2) modelRefreshTick：每 60s 自重排，到「每日指定小时」（默认凌晨 1 点）
//      强制刷新所有启用上游的模型列表 + 跑全模型连通性测试并记日志；
//   3) MODEL_CACHE_FILE：模型列表落盘为「最后已知可用」，上游临时抖动时
//      /v1/models 用最后已知列表兜底，不返回空列表。
const MODEL_CACHE_FILE = '/etc/workbuddy/modelcache.json'; // 最后已知模型列表落盘文件
const MODEL_REFRESH_HOUR_DEFAULT = 1;  // 默认每天凌晨 1 点拉取最新模型
const MODEL_REFRESH_CHECK_MS = 60000;  // 巡检定时器自重排间隔（毫秒）
const MODEL_TEST_TIMEOUT = 20;         // 单模型连通性测试超时（秒）
const MODEL_TEST_MAX_PER_UP = 20;       // 每个上游最多测试的模型数（防上游模型爆炸）

// v2.0：能力扩展 ----------
//
// 1) 上游列表缓存。loadUpstreams() 现在带 TTL 缓存（外部直接编辑
//    /etc/workbuddy/upstreams.json 后最多 UPSTREAM_CACHE_TTL 秒生效；
//    管理页保存路径会主动失效缓存，不受此延迟影响）。
const UPSTREAM_CACHE_TTL = 2;

// 2) 会话粘性（session affinity）。同一客户端（API Key 名或 IP）在
//    up_sticky_sec 内优先复用同一把上游 Key，降低多 Key 轮询导致同一会话
//    上下文在多个账号间跳变、进而触发上游多账号风控的几率。
//    默认 900 秒（15 分钟）；配 0 关闭粘性，退回纯轮询。
const UP_STICKY_SEC_DEFAULT = 900;

//
// 6) 上游限流刹车（v1.8.1）。
//
//    背景（soak 实测数据，60 个客户端请求）：池统计到 **138 次上游请求 = 2.25× 放大**，
//    其中 24 个请求以 429 收场 —— 每个都试满了 4 把 Key，即 96 次上游调用
//    **注定全部失败**，占上游总流量的 70%。
//
//    成因：撞限流后 tryNextUpKey 会无条件换下一把 Key 重试（这是用户明确要求的行为，
//    不能删）。但当 4 把 Key 都已因限流进入冷却时，这 4 次尝试**没有一次可能成功**
//    —— "冷却"的定义就是"这把现在不行"—— 流量却照打。于是上游额度被自己烧得更狠、
//    Key 恢复得更慢，形成正反馈。实测在**零并发**下也能看到单请求连烧 2 把 Key：
//    `key sk-3lw…TOC5 cooling 20s (限流)` → `attempt 2/4` → 1s 后该 Key 也 cooling。
//
//    做法：上游级熔断器。在滑动窗口内累计"被上游限流拒绝"的次数，达到阈值就把这条
//    上游**短时闭闸**：闭闸期间的尝试不再打上游，直接回 429 + 真实 Retry-After。
//    任一次成功立刻合闸自愈（不引入额外探活，不占事件循环）。
//
//    与 v1.7.1 被删除的"全部 Key 冷却就立刻 429"短路的区别（删除理由见
//    markUpKeyFail 上方注释：它回的 retry_after 高达 577s，且违背"不通的自动换下一个"）：
//      1) 判据是**观测到的上游拒绝**，不是我们自己的冷却模型 —— 冷却只是估计，
//         上游是否已恢复只有上游知道；
//      2) 要在窗口内**连续多次**被拒才闭闸（默认 20s 内 4 次），偶发一次不闭；
//      3) Retry-After 有上限（默认 15s），不再是几百秒的荒谬值；
//      4) 闭闸尾巴上到达的请求会**先等一次**（剩余 ≤ RATE_BRAKE_WAIT_MS），
//         等完直接放行 —— 把本会失败的请求尽量转成成功，而不是一律拒绝。
//    rl_brake_hits = 0 关闭该功能（退回 v1.8.0 行为）。
const RATE_BRAKE_HITS_DEFAULT = 4;    // 窗口内累计多少次限流拒绝后闭闸
const RATE_BRAKE_WINDOW_DEFAULT = 20; // 计数滑动窗口（秒）
const RATE_BRAKE_SEC_DEFAULT = 8;     // 闭闸时长（秒）
const RATE_BRAKE_MAX_RA_DEFAULT = 15; // 回给客户端的 Retry-After 上限（秒）
const RATE_BRAKE_WAIT_MS = 2000;      // 闭闸剩余 ≤ 此值时先等一次再发（毫秒）

// 数值型 UCI 选项的安全解析。三个必须显式处理的坑：
//
//   1) **ucode 没有 undefined 这个标识符。** 写 `v === undefined` 不会在
//      `ucode -c` 语法检查阶段报错，只在运行时抛
//      "Reference error: access to undeclared variable undefined" ——
//      本次 v1.8.0 首次部署就因此让服务起不来（loadConfig 第一行就炸，
//      端口都没监听）。缺失值在 ucode 里就是 null，布尔与空串另外挡。
//   2) ucode 里 +'' 和 +null **都等于 0**。而这些参数中 0 是"不限制"的意思，
//      所以留空/缺失的选项会被静默当成"用户主动关掉了限制"，而不是"用默认值"。
//      在设备上实测出来的：numOr('',4,0,64) 与 numOr(null,4,0,64) 都返回 0。
//   3) 不能用 `+cfg.x || def` —— 那样合法的 '0'（本意"不限制"）会被当假值顶掉。
//
// 越界分方向处理：写小了（含负数）多半是笔误，退回默认值；写大了是"想要更多"，
// 夹到上限比直接无视更贴近意图。
function numOr(v, def, min, max) {
	if (v === null || type(v) === 'bool' || v === '') return def;
	let n = +v;
	// NaN 与任何数比较都是 false，据此识别非数字输入
	if (!(n >= min || n <= max)) return def;
	if (n < min) return def;
	if (n > max) return max;
	return n;
}

// 在途连接表。
// 必须声明在 closeConn() 之前 —— ucode 不提升声明，函数按定义时的词法作用域
// 解析标识符，声明在后会抛 "access to undeclared variable"（本文件多处已踩过）。
let connections = [];

// 看门狗定时器句柄。必须持有引用 —— ucode 的 uloop 句柄一旦失去引用就可能被
// 回收，定时器随之失效（本文件 login.timer 同样持有）。这里的自重置写法
// 依赖它每次都能再排下一轮。
let idleTimer = null;

// 自定义上游模型列表缓存：cacheKey -> { at, list }
let upModelCache = {};

// ---------- 并发闸门与排队状态（v1.8.0） ----------
//
// upInflight: 闸门键 -> 当前在途请求数。键为 'wb'（WorkBuddy 通道）
//             或 'up:<上游id>'（每个自定义上游各自计数）。
let upInflight = {};

// chatQueue: FIFO 等待队列（元素是连接对象）。全局只有一个数组，
// 但放行时按各自闸门键的容量判断 —— 某个上游满了不会连坐另一个上游。
let chatQueue = [];

// 重入保护：pumpQueue 里发起的 spawn 可能同步失败并立刻 closeConn，
// 从而再进一次 releaseGate → pumpQueue。没有这个标志会把 chatQueue 改坏。
let pumpingQueue = false;
let queuePumpAgain = false;
let queueTimer = null;

// 连接池可用性：0 表示上次观测正常；非 0 表示在此之前一律走直连。
// 由一次"零字节且未推流"的池化尝试置位（见 spawnUpstreamDirect）。
let poolFailUntil = 0;

// ---------- 管理页会话 ----------
//
// 设计取舍（对照 edgetunnel 的实现做了三处修正）：
//   1. edgetunnel 的 Cookie = MD5(UA + 秘钥 + 密码)，绑定 User-Agent。
//      UA 完全由客户端控制，安全增益约等于零，副作用却是换浏览器/UA 升级
//      就掉线。这里不参与派生。
//   2. edgetunnel 用无盐 MD5，Cookie 值恒定、不随会话或时间变化，也无法撤销。
//      这里改为 sha256 派生，且 Cookie 值内嵌过期时间戳并参与签名，
//      服务端真正校验过期，改密码即全量失效。
//   3. 这里不设 Secure 属性：管理页通过 http 访问路由器，带 Secure 的
//      Cookie 不会被浏览器回传，会导致“密码正确但一直登录不上”且毫无提示。
const ADMIN_COOKIE = 'wb_admin';
const ADMIN_TTL = 86400;        // 会话有效期（秒）
const ADMIN_MAX_FAIL = 8;       // 同一 IP 连续失败上限
const ADMIN_LOCK_SEC = 300;     // 触发上限后的锁定时长（秒）
// 管理员密码专属盐；密码本身由 LuCI 写入 UCI
const ADMIN_SALT = 'luci-app-workbuddy/admin/v1';

// 客户端版本探测源（按顺序尝试，任一成功即用）。
// 说明：WorkBuddy 官方没有公开的版本清单接口 —— /v3/config 里只有插件市场的
// versionUrl，与客户端 UA 无关；download.codebuddy.cn/version.json 是 CodeBuddy
// 的清单（4 段式版本、无 windows-x64），不能直接当 WorkBuddy 版本用。
// 因此这里采用「多源探测 + 自校准」：探测源给出候选，同时记录上游实际接受过的
// 最高版本，避免把版本号写死在某一次发布上。
const VERSION_SOURCES = [
	'https://www.workbuddy.ai/api/version',
	'https://www.workbuddy.ai/version.json',
];
const VERSION_FILE = '/etc/workbuddy/version.json';
const VERSION_TTL = 21600;      // 版本缓存 6 小时
const VERSION_FLOOR = '5.5.2';  // 已知可用下限，探测全失败时回退到这里

// ---------- 配置读取 ----------

function rtrim(s, ch) {
	while (length(s) > 0 && substr(s, length(s) - 1) === ch)
		s = substr(s, 0, length(s) - 1);
	return s;
}

function loadConfig() {
	let cfg = {
		enabled: '1',
		port: 8789,
		host: '0.0.0.0',
		endpoint: 'https://www.workbuddy.ai',
		share_token: '',
		client_version: '5.5.2',
		auto_client_version: '1',
		admin_password: '',
		token_file: '/etc/workbuddy/token.json',
		only_free_models: '1',
		wan_access: '0',
		wan_port: '',
		debug: '0',
		// ---------- v1.8.0 ----------
		up_max_inflight: '4',    // 每个自定义上游在途上限，0=不限
		wb_max_inflight: '6',    // WorkBuddy 通道在途上限，0=不限
		queue_max: '32',         // 排队上限，0=不排队（满员直接 429）
		queue_timeout: '20',     // 排队等待上限（秒）
		use_pool: '1',           // 是否走本机连接池（pool/ 目录的常驻进程）
		pool_port: '8790',       // 连接池监听端口（仅回环）
		// ---------- v1.8.2 ----------
		up_idle_sec: '25',       // 首字节之后的流中静默上限，0=关闭该档
		up_first_byte_sec: '12', // 首字节等待上限，0=关闭该档
		wb_idle_sec: '75',       // WorkBuddy 通道静默上限，0=关闭该档
		// ---------- v2.0 ----------
		up_sticky_sec: '900',        // 会话粘性时长（秒），0=关闭粘性
		allow_private_upstream: '1', // 是否允许自定义上游指向内网/本机地址
		// ---------- v2.8.0 ----------
		model_refresh_hour: '1',     // 每日拉取最新模型的小时（0-23），默认凌晨 1 点
		model_refresh_enabled: '1',  // 是否启用每日模型巡检（拉取 + 全模型连通性测试）
	};

	let ctx = uci.cursor();
	let all = ctx.get_all('workbuddy') || {};
	let main = all.main || {};

	for (let k in main) {
		if (main[k] === '' || main[k] === null) continue;
		cfg[k] = main[k];
	}

	cfg.port = +cfg.port || 8789;
	cfg.endpoint = rtrim('' + cfg.endpoint, '/');
	cfg.enabled = (('' + cfg.enabled) !== '0');
	cfg.onlyFree = (('' + cfg.only_free_models) !== '0');
	cfg.autoVersion = (('' + cfg.auto_client_version) !== '0');
	// 【v1.7.11 起 up_failover_429 已失效，配置项保留但不再读取】
	//
	// 它原本控制"限流时是否换下一把 Key"。但实测两条分支**本来都会换 Key**
	// （关闭时落到 spawnUpstreamDirect，同样推进到下一个槽位），
	// 唯一差别只是"没 Key 可换时回哪种错误" —— 属于准死配置。
	// 现在"不通就换下一个"是无条件行为，故不再需要这个开关。
	// UCI 里残留的 up_failover_429 值不会报错，只是被忽略。
	// 公网访问默认关闭。只有显式写 '1' 才算开，避免历史配置缺项被误判成开。
	cfg.wanAccess = (('' + cfg.wan_access) === '1');
	// 外部端口（公网侧监听端口）。合法 1–65535 才采用，否则回退到内部端口。
	// 这样即使 UCI 里写了个脏值也不会把防火墙规则写坏。
	{
		let wp = +cfg.wan_port;
		cfg.wanPort = (wp >= 1 && wp <= 65535) ? wp : cfg.port;
	}
	cfg.adminPass = '' + (cfg.admin_password || '');

	// ---------- v1.8.0：并发闸门 / 排队 / 连接池 ----------
	cfg.upMaxInflight = numOr(cfg.up_max_inflight, UP_MAX_INFLIGHT_DEFAULT, 0, 64);
	cfg.wbMaxInflight = numOr(cfg.wb_max_inflight, WB_MAX_INFLIGHT_DEFAULT, 0, 64);
	cfg.queueMax = numOr(cfg.queue_max, UP_QUEUE_MAX_DEFAULT, 0, 512);
	cfg.queueTimeout = numOr(cfg.queue_timeout, UP_QUEUE_TIMEOUT_DEFAULT, 1, 300);

	cfg.usePool = (('' + cfg.use_pool) === '1');
	{
		let pp = +cfg.pool_port;
		if (!(pp >= 1 && pp <= 65535)) {
			// 端口非法就直接关池：否则 curl 会去连一个不存在的端口，
			// 每个请求先白等一次连接超时再回退直连，比不开池还慢。
			cfg.usePool = false;
			pp = 8790;
		}
		cfg.poolPort = pp;
	}
	cfg.poolBase = 'http://127.0.0.1:' + cfg.poolPort;

	// ---------- v1.8.1：上游限流刹车 ----------
	// rl_brake_hits = 0 表示关闭刹车（退回 v1.8.0：撞限流就一路换 Key 试到底）。
	cfg.brakeHits = numOr(cfg.rl_brake_hits, RATE_BRAKE_HITS_DEFAULT, 0, 1000);
	cfg.brakeWindow = numOr(cfg.rl_brake_window, RATE_BRAKE_WINDOW_DEFAULT, 1, 600);
	cfg.brakeSec = numOr(cfg.rl_brake_sec, RATE_BRAKE_SEC_DEFAULT, 0, 300);
	cfg.brakeMaxRa = numOr(cfg.rl_brake_max_ra, RATE_BRAKE_MAX_RA_DEFAULT, 1, 3600);

	// ---------- v1.8.2：静默看门狗分档 ----------
	// 0 = 关闭该档（诊断链路时用；生产不建议，会让客户端干等）。
	cfg.upFirstByteSec = numOr(cfg.up_first_byte_sec, UP_FIRST_BYTE_SEC_DEFAULT, 0, 3600);
	cfg.upIdleSec = numOr(cfg.up_idle_sec, UP_IDLE_SEC_DEFAULT, 0, 3600);
	cfg.wbIdleSec = numOr(cfg.wb_idle_sec, WB_IDLE_SEC_DEFAULT, 0, 3600);
	// 上限必须大于下限，否则首字节还没等到就被流中档杀掉。配错了就回默认。
	if (cfg.upFirstByteSec > 0 && cfg.upIdleSec > 0 && cfg.upIdleSec < cfg.upFirstByteSec) {
		cfg.upFirstByteSec = UP_FIRST_BYTE_SEC_DEFAULT;
		cfg.upIdleSec = UP_IDLE_SEC_DEFAULT;
	}

	// ---------- v1.8.3：上游响应回环桥 ----------
	// 0 = 关闭回环桥，退回直接 popen 读取（保留 v1.8.2 行为）。
	cfg.bridgePort = numOr(cfg.bridge_port, BRIDGE_PORT_DEFAULT, 0, 65535);

	// ---------- v2.0：会话粘性 / 私有上游 ----------
	cfg.upStickySec = numOr(cfg.up_sticky_sec, UP_STICKY_SEC_DEFAULT, 0, 86400);
	// 公网只允许显式写 '0' 才算关闭，避免历史配置缺项被误判成禁止。
	cfg.allowPrivateUpstream = (('' + cfg.allow_private_upstream) !== '0');

	// ---------- v2.8.0：模型每日刷新 ----------
	// 小时必须是 0-23 的整数，脏值回默认 1（凌晨 1 点）。
	cfg.modelRefreshHour = numOr(cfg.model_refresh_hour, MODEL_REFRESH_HOUR_DEFAULT, 0, 23);
	// 只允许显式写 '0' 才算关闭，历史配置缺项视为开启。
	cfg.modelRefreshEnabled = (('' + cfg.model_refresh_enabled) !== '0');

	return cfg;
}

// ---------- token 管理（兼容单文件旧格式） ----------

function tokenPath(cfg) {
	return cfg.token_file || '/etc/workbuddy/token.json';
}

// readJsonFile / writeJsonFile 定义在文件顶部的「基础工具函数」区，
// 那里是唯一允许放置底层工具的位置（ucode 不提升函数）。

function getToken(cfg) {
	let j = readJsonFile(tokenPath(cfg));
	if (!j) return null;
	let t = j.accessToken;
	if (type(t) !== 'string' || length(t) === 0) return null;
	return t;
}

// v2.2.0：网页登录**追加**到凭据池，而不是覆盖单槽。
//
// 旧行为（v2.1.0 及以前）：saveToken() 直接 writeJsonFile(token.json)，
// 整个文件被新账号覆盖 —— 于是"登录并添加账号"每点一次就顶掉上一个账号，
// 用户永远只能有一个账号可轮换，与"多个账号轮流中转"的设计意图相反。
//
// 新行为：
//   1) 账号写进 pool.json（与手动添加的 token 同一个池），已有条目一律保留；
//   2) 同一账号（JWT sub 相同）再次登录视为"刷新",只就地更新 token 与时间，
//      不新增条目、也不影响其他账号；
//   3) token.json 仍然写，作为**最近一次登录**的镜像，兼容旧读取方
//      （getToken() 与老版本外部脚本），但它不再代表"唯一账号"。
//
// 返回值沿用布尔语义，另附 { added, updated, id } 供调用方写日志。
function saveToken(cfg, accessToken, refreshToken) {
	let payload = {
		accessToken: accessToken,
		syncedAt: time(),
	};
	if (refreshToken) payload.refreshToken = refreshToken;

	// 1) 追加/更新池条目 —— 这是账号真正被保存的地方。
	// 走 F 前向引用表：addWebLoginCred 定义在 readPoolRaw/savePoolRaw 之后，
	// 而 ucode 不提升函数声明，直接调用会抛 undeclared variable。
	let r = F.addWebLoginCred(cfg, accessToken);
	if (!r.ok) {
		// 池写入失败时**仍**回写 token.json：宁可退化成旧版单账号行为，
		// 也不能让用户刚完成的授权白费（否则还得重扫一次二维码）。
		logErr('weblogin pool append failed: ' + (r.error || '?') + ' -> falling back to token.json only');
	}

	// 2) token.json 作为最近一次登录的镜像
	if (!writeJsonFile(tokenPath(cfg), payload)) {
		logErr('token save failed');
		// 镜像写失败不算致命：只要池里已经存下这次登录，轮换就照常工作。
		return r.ok;
	}

	if (r.ok) {
		logInfo(sprintf('weblogin credential %s in pool: %s (%s)',
			r.updated ? 'updated' : 'added', r.id, r.name));
	} else {
		logInfo('token saved to ' + tokenPath(cfg) + ' (pool append failed)');
	}
	return true;
}

// ---------- 凭据池（多账号轮询） ----------
//
// 凭据来源有两处，合并成一个池：
//   1. TOKEN_POOL_FILE  —— { credentials: [{id,name,accessToken,syncedAt}] }
//   2. token_file       —— 旧版单凭据文件，保持兼容
//
// 池中每个条目记录冷却截止时间，被上游限流后自动跳过，
// 冷却结束自动恢复，无需人工干预。
//
// 注意：ucode 没有 opendir/readdir，所以池必须集中在单个 JSON 文件里，
// 不能像常见做法那样一条凭据一个文件。

let credState = {};   // id -> { coolUntil: <ts>, fails: <n>, lastErr: <str> }
let credCursor = 0;   // 轮询游标（v2.3.0 前用于纯轮询，现保留给 fallback）
let poolCursor = 0;   // 加权轮询游标（v2.3.0：按成功率加权）

// ---------- v2.2.0：中转决策日志（内存环缓冲 + 聚合计数） ----------
//
// 两部分缺一不可：
//   relayEvents —— 最近 RELAY_LOG_MAX 条明细，回答"刚才这个请求发生了什么"；
//   relayAgg    —— 按 账号 × 结果 聚合的累计计数，回答"这个账号到底行不行"。
//
// 只有明细没法看趋势（要人肉数 200 条），只有聚合没法定位单次故障，
// 所以两者都留。聚合计数直接供管理页出"账号健康矩阵"。
let relayEvents = [];
let relaySeq = 0;      // 事件序号，便于对齐明细与聚合

// 聚合表：id -> { pick, ok, rate, risk, auth, client, net, cool, coolSec }
// coolSec 累计"因该账号而等待的冷却秒数"，是判断"冷却时长设得合不合适"的关键指标：
// 如果 coolSec 逼近总运行时长，说明池子太小/冷却太长，请求一直在等而不是在跑。
let relayAgg = {};
// 全局聚合：换号次数、耗尽次数、平均每请求尝试数 —— 轮换规则好坏的直接读数
let relayTotals = { pick: 0, ok: 0, fail: 0, switch: 0, exhaust: 0, abort: 0, trunc: 0 };

// 记录一条中转事件。
//
// 所有字段都用短名（id/ev/sec/why）：环缓冲只有 200 条，字段名长了内存翻倍，
// 而这张表是要在 900MB 内存的路由器上长驻的。
function relayLog(id, ev, why, extra) {
	relaySeq++;
	let e = {
		n: relaySeq,          // 序号
		t: time(),            // 时间戳
		id: '' + (id || ''),  // 账号 id（'' 表示与账号无关的事件）
		ev: '' + (ev || ''),  // 事件类型
	};
	if (why) e.why = substr('' + why, 0, 180);   // 截断：上游错误可能很长
	if (extra) {
		for (let k in extra) {
			// ucode 没有全局 undefined（裸写 undefined 会被判为未定义标识符），
			// 判空一律用 `!= null` —— 它同时覆盖 null 与 undefined。
			if (extra[k] != null && extra[k] !== '')
				e[k] = extra[k];
		}
	}

	push(relayEvents, e);
	// 环缓冲：超出上限丢最旧的。
	//
	// 用「新建数组 + 拷贝尾部」而不是 shift()：ucode 的数组方法集与 JS 不同
	// （没有 slice，shift 是否可用在各版本间不一致），手写拷贝最稳。
	// 只在超限时发生一次，n=200 的代价可忽略。
	if (length(relayEvents) > RELAY_LOG_MAX) {
		let keep = [];
		let from = length(relayEvents) - RELAY_LOG_MAX;
		for (let i = from; i < length(relayEvents); i++) push(keep, relayEvents[i]);
		relayEvents = keep;
	}

	// 聚合
	if (length(e.id) > 0) {
		if (!relayAgg[e.id]) relayAgg[e.id] = {
			pick: 0, ok: 0, rate: 0, risk: 0, auth: 0,
			client: 0, net: 0, cool: 0, coolSec: 0,
		};
		let a = relayAgg[e.id];
		if (a[e.ev] != null) a[e.ev]++;
	}
	if (relayTotals[e.ev] != null) relayTotals[e.ev]++;

	return e;
}

// 记录一次冷却，附带时长（供 coolSec 累加）
function relayLogCool(id, sec, why) {
	let e = relayLog(id, 'cool', why, { sec: int(sec) });
	if (length(e.id) > 0 && relayAgg[e.id]) relayAgg[e.id].coolSec += int(sec);
	return e;
}

// 清空中转日志（管理页按钮）—— 用于"改完规则后从零观察效果"
function relayReset() {
	relayEvents = [];
	relayAgg = {};
	relaySeq = 0;
	relayTotals = { pick: 0, ok: 0, fail: 0, switch: 0, exhaust: 0, abort: 0, trunc: 0 };
}

// 账号健康矩阵：把聚合计数整理成"一眼能判断该账号行不行"的行。
//
// 关键派生指标：
//   okRate   = ok / pick      —— 选中后真正成功的比例（<50% 的账号应考虑剔除）
//   rateRate = rate / pick    —— 被限流比例（高说明该账号配额小，适合低频用）
//   coolSec  —— 累计冷却秒数（占运行时长比例过高说明池子太小）
//
// upSec 由调用方传入，不在这里读 metrics.since ——
// metrics 声明在文件靠后处（initMetrics 之后），而 ucode 不提升顶层 let，
// 在这里直接引用会抛 "access to undeclared variable metrics"。
// 中转日志里的一行，到底是凭据池账号还是自建上游 Key？
// 判据统一放在这里，避免各处 substr(key,0,3)==='up:' 写歪。
function relayIsUpKey(key) { return substr('' + key, 0, 3) === 'up:'; }

// 该账号/Key 当前还剩多少秒冷却。两张状态表形状相同但是**两张表**
// （credState 管凭据池、upState 管自建上游的 Key），改错一侧等于没改。
//
// upState 走 F 表读取而不是直接引用：它声明在文件靠后处（upState 在 1900+ 行，
// 本函数在 900 行附近）。ucode 在**函数定义时**就解析自由变量，直接写 upState
// 会让静态检查报 "reference before declaration"，运行时则是
// "access to undeclared variable"。F 表的存在就是为了绕开这个限制。
function relayCoolingSec(isUp, key) {
	if (isUp) {
		let st = F.upStateGet(key);
		if (st && st.coolUntil > time()) return st.coolUntil - time();
		return 0;
	}
	let cs = credState[key];
	if (cs && cs.coolUntil > time()) return cs.coolUntil - time();
	return 0;
}

// 该账号/Key 最近一次失败原因，同样跨两张表取。
function relayLastErr(isUp, key) {
	if (isUp) {
		let st = F.upStateGet(key);
		return (st && st.lastErr) ? st.lastErr : '';
	}
	let cs = credState[key];
	return (cs && cs.lastErr) ? cs.lastErr : '';
}

// 记录"一次账号/Key 被选中"。
//
// 口径（这是整个中转日志最容易搞错的地方）：
//   relayTotals.pick  —— 选中次数 = 所有"选中相关"事件之和
//                        （spawn 的 pick + 该次选中后的 rate/auth/net）
//   账号行的 pick     —— 同一个口径，按账号分别统计（relayAccounts 里求和）
//   成功率分母        —— 用上面这个 pick，而不是只数 'pick' 事件。
//                        只数 'pick' 会让分母偏小，把 11% 的账号显示成 50%
//                        （v2.2.0 真机验收真实出现过 totals=101 / 账号和=38）。
//
// 注意**不要**在这里再写 relayTotals.pick++：relayLog 内部的通用累加
// `if (relayTotals[e.ev] != null) relayTotals[e.ev]++` 已经给 'pick' 事件
// 计过一次了，再手动加一次会让总数直接翻倍。
function relayPick(id, mode, extra) {
	let ex = extra || {};
	ex.mode = mode;
	relayLog(id, 'pick', '', ex);
}

// 记录"一次选中以失败告终"。
//
// rate/auth/net 这些事件的 ev 不是 'pick'，所以 relayLog 的通用累加不会
// 把它们计入 totals.pick —— 但它们确实属于"这次选中"，必须补上，
// 否则全局 pick 会小于各账号 pick 之和，两处口径对不上。
function relayFail(id, ev, why, extra) {
	let ex = extra || {};
	relayLog(id, ev, why, ex);
	if (ev !== 'pick') relayTotals.pick++;
}

// v2.4.0：该账号"近期表现"的窗口统计 —— 只扫描环缓冲里的最近若干次选中。
//
// 为什么需要它：relayAgg 是进程生命周期内的累计，冷启动期的失败会永远
// 拉低成功率（v2.3.0 真机出现过"41 次选中、12% 成功率、仍大量被选"）。
// 而轮换要降错误率，靠的是"最近到底行不行"：刚恢复的账号要尽快重新多接
// 流量，正在连续失败的账号要立刻少接 —— 只有近期窗口能提供这个信号。
//
// 实现：从 relayEvents（环缓冲，最多 RELAY_LOG_MAX 条）**倒序**扫描，
// 只统计该 id 的「选中相关」事件（pick/ok/rate/risk/auth/client/net），
// 直到收集满 maxPicks 次 'pick' 为止。返回 { attempts, ok }：
//   attempts = 收集到的 pick 次数（= 近期被选中的次数）
//   ok       = 同期收集到的成功次数
// 成功率 = ok / attempts。attempts=0（缓冲里没有该 id）表示"近期无数据"。
//
// 为什么按"次数"而非"秒数"开窗：环缓冲只有 200 条，高负载下可能只覆盖
// 几分钟，低负载下覆盖数小时。按次数开窗随负载自适应 —— 高频时看最近
// 几分钟、低频时看最近几次，语义始终是"该账号最近 N 次选中的表现"。
// 轻微乐观偏差：倒序扫描到第 maxPicks 个 pick 时，可能把第 maxPicks+1
// 个 pick 的 ok 也带进来（ok 紧跟在 pick 之后）。影响很小且偏向乐观，
// 恢复中的账号因此能更快拉高权重，是可接受的。
function relayRecentStats(id, maxPicks) {
	let attempts = 0;
	let ok = 0;
	for (let i = length(relayEvents) - 1; i >= 0; i--) {
		let e = relayEvents[i];
		if (e.id !== id) continue;
		if (e.ev === 'pick') attempts++;
		else if (e.ev === 'ok') ok++;
		else if (e.ev === 'rate' || e.ev === 'risk' || e.ev === 'auth'
			|| e.ev === 'client' || e.ev === 'net') { /* 失败结果，不单独计数 */ }
		else continue;
		if (attempts >= maxPicks) break;
	}
	return { attempts: attempts, ok: ok };
}

// v2.3.0 + v2.4.0：根据中转日志计算动态权重。
//
// 返回值 ≥ 1，用于加权轮询（weightedRotate / poolWeightedRotate）：
//   · 样本不足（< RELAY_MIN_SAMPLES）→ 1（冷启动，不偏置）
//   · 成功率 100% → 10（给 10× 流量，显著倾斜）
//   · 成功率 50%  → 5
//   · 成功率 10%  → 1（几乎不倾斜，但仍给最低流量以便恢复后重新积累）
//   · 成功率  0%  → 1（不绝杀：冷却恢复后仍给机会试）
//
// v2.4.0 起，权重 =「累计成功率」与「近期成功率」的混合。
// 近期窗口固定为最近 RELAY_RECENT_MIN=3 次选中（与账号矩阵的「近期」列一致）：
//   · 近期样本不足（< RELAY_RECENT_MIN 次选中）→ 只信累计历史；
//   · 最近 3 次选中全部失败 → 权重压到 1（别让新流量撞正在连败的账号）；
//   · 否则 7 成信近期、3 成信累计 —— 刚恢复的账号几天内就能重新拿回高权重，
//     正在变差的账号几天内就会被压低（这就是"智能转换降错误率"的核心）。
//
// 为什么不绝杀 0% 的账号：relayAgg 是进程生命周期内的累计，早期的失败
// 会一直拉低均分。给 weight=1 而非 0，让它在冷却结束后仍能被试到，
// 如果它恢复了，后续 ok 会逐步拉高均分 —— 这正是"自我修复"的反馈环。
// 真正的绝杀由冷却机制做（被风控 → cool 30min，这期间根本不入选）。
function relayWeight(id) {
	let a = relayAgg[id];
	if (!a) return 1;
	let picks = (a.pick || 0) + (a.rate || 0) + (a.risk || 0)
		+ (a.auth || 0) + (a.client || 0) + (a.net || 0);
	if (picks < RELAY_MIN_SAMPLES) return 1;
	// ucode 整数除法：2/3==0，必须先乘后除（与 relayAccounts 的 okRate 同一手法）。
	let life = int((a.ok || 0) * 10 / picks);   // 累计成功率权重 0..10
	let w = life;
	let rs = relayRecentStats(id, RELAY_RECENT_MIN);
	if (rs.attempts >= RELAY_RECENT_MIN) {
		// 近期连续失败：不管累计多好，先压到最低 —— 它正在烧流量。
		if ((rs.ok || 0) === 0) {
			w = 1;
		} else {
			// 7:3 偏近期 —— 恢复快、变差也快（ucode 整数除法，先乘后除）。
			let rec = int((rs.ok || 0) * 10 / rs.attempts);
			w = int((life * 3 + rec * 7) / 10);
		}
	}
	if (w < 1) w = 1;
	return w;
}

// v2.3.0：凭据池的加权轮询。
//
// 与 weightedRotate（给自建上游 Key 用）的区别：凭据没有用户配置的静态权重，
// 唯一的权重来源就是 relayWeight（即历史成功率）。游标用 poolCursor。
function poolWeightedRotate(keys) {
	let n = length(keys);
	let w = [];
	let total = 0;
	for (let i = 0; i < n; i++) {
		let wt = relayWeight(keys[i].id);
		if (!(wt >= 1)) wt = 1;
		w[i] = wt;
		total += wt;
	}
	// 游标按权重取模定位首个；权重全为 1 时退化为普通轮询。
	let pos = poolCursor % total;
	poolCursor = poolCursor + 1;
	let first = 0;
	let acc = 0;
	for (let i = 0; i < n; i++) {
		acc += w[i];
		if (pos < acc) { first = i; break; }
	}
	let out = [];
	for (let i = 0; i < n; i++) push(out, keys[(first + i) % n]);
	return out;
}

function relayAccounts(upSec) {
	let out = [];
	let up = (upSec && upSec > 0) ? upSec : 1;
	let ids = [];
	for (let id in relayAgg) push(ids, id);
	// ucode 有 sort()，但为保证跨版本稳定这里手动插入排序（按 id 字典序）
	for (let i = 1; i < length(ids); i++) {
		let v = ids[i], j = i - 1;
		while (j >= 0 && ids[j] > v) { ids[j + 1] = ids[j]; j--; }
		ids[j + 1] = v;
	}
	// 注意：ucode 的 for..in 对数组给出的是「值」而不是「下标」
	//（for (let i in ['a']) 里 i === 'a'），所以这里必须用显式索引循环。
	for (let n = 0; n < length(ids); n++) {
		let key = ids[n];
		let a = relayAgg[key];
		if (a == null) continue;
		// 上游 Key 的 id 形如 'up:<upId>:<maskedKey>'。它们与凭据池账号是
		// 两套完全不同的东西（一个是"用哪个 WorkBuddy 账号"，一个是
		// "用哪把自定义上游 Key"），混在一张表里会让人以为某个账号叫
		// "up:u123:sk-…"。用 kind 标出来，前端分成两张表渲染。
		let isUp = relayIsUpKey(key);
		// "选中次数"必须把该账号上的**所有**中转事件都算进去，而不能只数
		// 'pick' 事件。
		//
		// 原因：选中同一个账号会留下不止一条事件 —— spawn 时记一条 'pick'，
		// 之后这个账号被限流/鉴权失败时 markUpKeyFail 又各记一条 'rate'/'auth'/
		// 'net'；这些失败事件同样发生在"它被选中"这一次里，且 relayTotals.pick
		// 也是这么累加的（见 spawnUpstreamDirect 与 markUpKeyFail）。
		//
		// 曾经这里只写 a.pick，结果真机验收出现 totals.pick=101 而
		// sum(account.pick)=38：另外 63 次全部散落在 rate/auth/net 里，
		// 健康矩阵的「成功率」分母偏小，把 11% 的账号显示成 50%。
		let picks = (a.pick || 0) + (a.rate || 0) + (a.risk || 0)
			+ (a.auth || 0) + (a.client || 0) + (a.net || 0);
		// v2.4.0：近期窗口统计（最近 RELAY_RECENT_MIN 次选中，与 relayWeight 同窗）
		let rs = relayRecentStats(key, RELAY_RECENT_MIN);
		push(out, {
			id: key,
			kind: isUp ? 'up' : 'cred',
			pick: picks,
			ok: a.ok || 0,
			rate: a.rate || 0,
			risk: a.risk || 0,
			auth: a.auth || 0,
			client: a.client || 0,
			net: a.net || 0,
			cool: a.cool || 0,
			coolSec: a.coolSec || 0,
			okRate: picks > 0 ? int((a.ok || 0) * 100 / picks) : -1,      // 百分比整数，-1 = 无数据
			rateRate: picks > 0 ? int((a.rate || 0) * 100 / picks) : -1,
			coolPct: int((a.coolSec || 0) * 100 / up),                      // 冷却时长占运行时长百分比
			// 「当前是否在冷却」要同时看两张表：凭据池账号的状态在 credState，
			// 自建上游 Key 的在 upState。只看 credState 的话，上游 Key 那两栏
			// 永远是「—」，而它们恰恰是最容易被限流的一群。
			coolingSec: relayCoolingSec(isUp, key),
			lastErr: relayLastErr(isUp, key),
			weight: relayWeight(key),     // v2.3.0：当前轮询权重（1=无数据/最低，10=100%成功率）
			// v2.4.0：近期窗口（最近 RELAY_RECENT_MIN=3 次选中）的独立读数。
			// 累计成功率会把冷启动期的失败永远带在身上，近期读数才是
			// "当前是否值得选它"的直接依据 —— 前端据此显示「近期 x/y」。
			recentPick: rs.attempts,
			recentOk: rs.ok,
			recentOkRate: rs.attempts > 0 ? int((rs.ok || 0) * 100 / rs.attempts) : -1,
		});
	}
	return out;
}

// 最近事件，倒序（最新在前），最多 n 条。
// 倒序是因为排障时关心的是"刚才那一下"，而不是"200 次之前"。
function relayRecent(n) {
	let out = [];
	let total = length(relayEvents);
	let start = total - n;
	if (start < 0) start = 0;
	for (let i = total - 1; i >= start; i--) push(out, relayEvents[i]);
	return out;
}

// 中转日志快照。抽成独立函数，是因为两处要用同一份数据：
//   GET /metrics            —— 给监控/脚本读
//   GET /admin/api/state    —— 给管理页「中转日志」页签渲染
// 两处各写一份的话，字段迟早会漂移，前端就会莫名其妙地少一列。
//
// 必须定义在这里（relayRecent 之后、handleAdmin 之前）：ucode 在函数**定义时**
// 就解析自由变量，定义在 handleAdmin 后面的话，管理页一加载就抛
// "left-hand side is not a function"。这条规则 v2.2.0 已经踩过两次。
//
// upSec 由调用方传入，而不是在这里读 metrics.since —— metrics 声明在文件
// 靠后处（initMetrics 之后），本函数在这里引用它会触发
// "access to undeclared variable metrics"（relayAccounts 出于同样理由收 upSec）。
function relaySnapshot(upSec) {
	let up = (upSec && upSec > 0) ? upSec : 0;
	return {
		totals: {
			pick: relayTotals.pick,
			ok: relayTotals.ok,
			fail: relayTotals.fail,
			switch: relayTotals.switch,
			exhaust: relayTotals.exhaust,
			abort: relayTotals.abort,
			trunc: relayTotals.trunc,
		},
		// 每个账号一行健康矩阵。按 id 排序保证输出稳定，便于前后对比。
		accounts: relayAccounts(up),
		// 最近事件（倒序，最新在前）—— 排障时看的是"刚刚发生了什么"
		recent: relayRecent(40),
		capacity: RELAY_LOG_MAX,
		totalEvents: relaySeq,
	};
}

// 读池文件的原始条目（含禁用项，不去重），供管理页展示与编辑。
function readPoolRaw() {
	let j = readJsonFile(TOKEN_POOL_FILE);
	if (!j || type(j.credentials) !== 'array') return [];
	let out = [];
	for (let c in j.credentials) {
		if (type(c) !== 'object' || c === null) continue;
		if (type(c.accessToken) !== 'string' || length(c.accessToken) === 0) continue;
		push(out, c);
	}
	return out;
}

function savePoolRaw(list) {
	return writeJsonFile(TOKEN_POOL_FILE, { credentials: list });
}

// v2.2.0：把一次「网页登录」得到的 token 追加进凭据池。
//
// 与 addPoolCred 的区别（这是本函数存在的全部理由）：
//   addPoolCred      面向**手动粘贴**，撞到重复账号时拒绝（用户主动输入，需要明确反馈）；
//   addWebLoginCred  面向**登录流程**，撞到同一账号时**就地更新**而不是拒绝 ——
//                    用户重新登录同一账号是正常操作（token 过期要续期），
//                    此时必须刷新 token，绝不能报错、更不能覆盖别的账号。
//
// 返回 { ok, added, updated, id, name } 或 { ok:false, error }。
function addWebLoginCred(cfg, token) {
	token = trim('' + (token || ''));
	if (length(token) < 20)
		return { ok: false, error: '登录返回的 token 过短' };

	let info = parseJwt(token);
	if (info === null)
		return { ok: false, error: '登录返回的不是有效 JWT' };

	let sub = (info && length(info.sub) > 0) ? info.sub : '';
	let list = readPoolRaw();

	// 1) 同一账号已存在 -> 就地更新 token（刷新），保留 id/name/位置不变。
	//    按 sub 匹配而不是按 token 全文：同一账号重新登录会拿到新 token
	//    （jti/iat 都变了），按全文匹配必然匹配不上，结果就是"同一账号存了多份"。
	if (length(sub) > 0) {
		for (let c in list) {
			let ci = parseJwt('' + (c.accessToken || ''));
			if (ci && length(ci.sub) > 0 && ci.sub === sub) {
				let oldName = '' + (c.name || '');
				c.accessToken = token;
				c.syncedAt = time();
				// 重新登录说明账号恢复可用，清掉旧的冷却/失败标记
				delete credState['' + (c.id || '')];
				if (!savePoolRaw(list))
					return { ok: false, error: '更新凭据池失败' };
				logInfo('weblogin refreshed existing credential: ' + c.id + ' (' + oldName + ')');
				return { ok: true, added: false, updated: true, id: '' + (c.id || ''), name: oldName };
			}
		}
	}

	// 2) 新账号 -> 追加，**绝不触碰**已有条目
	let base = 'w' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let c in list) taken['' + (c.id || '')] = true;
	while (taken[id]) { id = base + '-' + n; n++; }

	let nm = (info && length(info.username) > 0) ? info.username : ('网页登录 ' + (length(list) + 1));

	push(list, {
		id: id,
		name: nm,
		accessToken: token,
		enabled: true,
		source: 'weblogin',
		syncedAt: time(),
	});
	if (!savePoolRaw(list))
		return { ok: false, error: '写入凭据池失败' };

	logInfo(sprintf('weblogin credential appended: %s (%s), pool size now %d',
		id, nm, length(list)));
	return { ok: true, added: true, updated: false, id: id, name: nm };
}

// 挂到前向引用表：saveToken() 定义在文件靠前处，需要调用本函数。
F.addWebLoginCred = addWebLoginCred;

function findPoolById(id) {
	for (let c in readPoolRaw())
		if (('' + (c.id || '')) === ('' + id)) return c;
	return null;
}

// 新增一条凭据。返回 { ok, id } 或 { ok:false, error, dup }。
//
// 去重分两层：
//   1) token 完全相同 -> 重复
//   2) 同一账号（JWT 的 sub 相同）-> 也视为重复
// 第 2 条是有意的：同一账号存多份没有任何负载均衡收益，
// 反而会让人误以为"已经配了多个账号"。
//
// 注意：去重必须同时覆盖 pool.json 和 token.json 两处存储。
// 只查 pool.json 会漏掉"网页登录凭据"——而那恰恰是用户最容易
// 复制过来重复添加的一条。
function addPoolCred(name, token, cfg) {
	token = trim('' + (token || ''));
	if (length(token) < 20)
		return { ok: false, error: '凭据内容过短，请粘贴完整的 access token' };

	// 去掉可能粘进来的 "Bearer " 前缀与首尾引号
	token = replace(token, 'Bearer ', '');
	token = replace(token, 'bearer ', '');
	token = trim(token);
	if (substr(token, 0, 1) === '"' && substr(token, length(token) - 1) === '"')
		token = substr(token, 1, length(token) - 2);
	token = trim(token);

	// 候选集合：池文件条目 + 网页登录凭据
	// 注意：ucode 的数组没有 .push() 方法，必须用全局 push(a, v)
	let candidates = [];
	for (let c in readPoolRaw()) {
		push(candidates, {
			id: '' + (c.id || ''),
			name: '' + (c.name || ''),
			token: '' + (c.accessToken || ''),
		});
	}
	if (cfg) {
		let lt = getToken(cfg);
		if (lt && length(lt) > 0)
			push(candidates, { id: 'default', name: '网页登录凭据', token: lt });
	}

	let info = parseJwt(token);
	let sub = info ? info.sub : '';

	// 必须是一个能解析出 payload 的 JWT。
	//
	// 这里刻意严格：WorkBuddy 的 access token 一定是三段点分的 JWT，
	// payload 里带 exp。放行解析失败的字符串只会让用户以为加成功了，
	// 实际轮询时才失败，反而更难排查。所以解析不出来就直接拒绝。
	if (info === null) {
		return {
			ok: false,
			error: '这不是有效的 access token：应为三段点分的 JWT，且能解析出 payload',
		};
	}
	if (info.exp && info.exp <= time()) {
		return { ok: false, expired: true, error: '该凭据已过期，请重新登录获取新的 token' };
	}

	for (let c in candidates) {
		if (c.token === token) {
			return {
				ok: false, dup: true,
				error: '该凭据已存在（内容完全相同）',
				existingId: c.id, existingName: c.name,
			};
		}
		if (length(sub) > 0) {
			let ci = parseJwt(c.token);
			if (ci && length(ci.sub) > 0 && ci.sub === sub) {
				return {
					ok: false, dup: true,
					error: '该账号已在池中（同一账号无需重复添加）',
					existingId: c.id, existingName: c.name,
				};
			}
		}
	}

	let list = readPoolRaw();

	// id 用时间戳；同秒内连续添加会撞号，补 -N 保证唯一
	let base = 'c' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let c in list) taken['' + (c.id || '')] = true;
	while (taken[id]) { id = base + '-' + n; n++; }

	let nm = trim('' + (name || ''));
	if (length(nm) === 0)
		nm = (info && length(info.username) > 0) ? info.username : ('凭据 ' + (length(list) + 1));

	push(list, {
		id: id,
		name: nm,
		accessToken: token,
		enabled: true,
		syncedAt: time(),
	});
	if (!savePoolRaw(list))
		return { ok: false, error: '写入凭据池失败' };

	logInfo('pool credential added: ' + id + ' (' + nm + ')');
	return { ok: true, id: id, name: nm };
}

function deletePoolCred(id) {
	let list = readPoolRaw();
	let next = [];
	let hit = false;
	for (let c in list) {
		if (('' + (c.id || '')) === ('' + id)) { hit = true; continue; }
		push(next, c);
	}
	if (!hit) return false;
	// 一并清掉它的冷却状态
	delete credState[id];
	return savePoolRaw(next);
}

function togglePoolCred(id, enabled) {
	let list = readPoolRaw();
	let hit = false;
	for (let c in list) {
		if (('' + (c.id || '')) === ('' + id)) { c.enabled = enabled ? true : false; hit = true; }
	}
	if (!hit) return false;
	return savePoolRaw(list);
}

// 删除「网页登录凭据」—— 即 token.json 里那个账号本体。
//
// 这是**账号级**操作，与 deletePoolCred 有本质区别：
//   deletePoolCred   只是从 pool.json 摘掉一个条目，账号凭据仍在我们手里
//                    （同一个 token 随时能再粘回来）；
//   deleteLegacyCred 删掉的是本机保存的账号凭据本体（accessToken 与
//                    refreshToken），删完本机不再持有该账号。
//
// 因此这里做**真删除**（unlink 文件），而不是写空文件、也不是加个
// disabled 标记：用户点这个按钮的动机通常就是"把这个账号从本机清掉"
// （账号被上游风控、要换号、或借出设备），留任何残片都不符合预期。
// 需要恢复时用管理页的「网页登录」重新登录即可，不需要本地留副本。
//
// 顺带清掉它在内存里的冷却状态，否则管理页会显示一个已经不存在的账号
// "冷却中"，让人以为还有残留。
function deleteLegacyCred(cfg) {
	let p = tokenPath(cfg);
	if (!access(p, 'f'))
		return { ok: false, error: '没有可删除的网页登录凭据' };

	if (!unlink(p))
		return { ok: false, error: '删除失败：' + error() };

	delete credState['default'];
	return { ok: true };
}

function loadPool(cfg) {
	let pool = [];
	let seen = {};
	let seenSub = {};
	let now = time();

	// 同一个账号只保留第一条：跨 pool.json 与 token.json 去重。
	// 已有去重只按 token 全文比较，但同一账号的 token 会随刷新而变
	// （jti/iat 不同），所以还要按 JWT 的 sub 再判一次。
	function take(id, name, t, source, syncedAt) {
		if (type(t) !== 'string' || length(t) === 0) return false;
		if (seen[t]) return false;

		// 已过期的凭据直接跳过，避免轮询把请求浪费在死 token 上。
		// 状态仍会在管理页显示，用户能看到并更换。
		if (credStatus(t, now) === 'expired') return false;

		let info = parseJwt(t);
		let sub = (info && length(info.sub) > 0) ? info.sub : '';
		if (length(sub) > 0) {
			if (seenSub[sub]) return false;
			seenSub[sub] = true;
		}

		seen[t] = true;
		push(pool, { id: id, name: name, token: t, source: source, syncedAt: syncedAt || 0 });
		return true;
	}

	// 1) 主池文件
	let j = readJsonFile(TOKEN_POOL_FILE);
	let creds = (j && type(j.credentials) === 'array') ? j.credentials : [];
	for (let c in creds) {
		if (type(c) !== 'object' || c === null) continue;
		if (c.enabled === false) continue;
		take('' + (c.id || ('cred' + (length(pool) + 1))), '' + (c.name || ''),
			c.accessToken, 'pool', c.syncedAt);
	}

	// 2) 旧版单文件凭据（兼容）
	let legacy = getToken(cfg);
	if (legacy) {
		let lj = readJsonFile(tokenPath(cfg)) || {};
		take('default', '默认凭据', legacy, 'legacy', lj.syncedAt);
	}

	return pool;
}

// 判定失败原因是否属于"账号被风控"。
//
// 上游封控账号时不会说"你被封了"，而是对所有请求统一返回内容审核类错误：
//   {"code":11140,"msg":"request illegal",
//    "displayMsg":{"zh":"内容未通过安全审核，请调整后重试。"}}
// 或安全策略拦截（code 11-128）。
//
// 与"内容真的违规"的区别：真违规只针对某条内容，换个问题就能过；
// 账号级风控则**任何**内容都过不去（实测 "hi"、"1+1=?" 全被拒）。
//
// 位置说明：必须定义在 usablePool / markCredFail **之前**。
// ucode 的函数声明不像 JS 那样提升到作用域顶部，只对已解析的定义生效，
// 因此"先调用后定义"会拿到未定义值而不是函数。
//
// 匹配策略按错误文本而非 code 字段：上游 code 在不同网关上类型不一致
// （字符串/整数都出现过，11140 与 "11-128" 前者是数字后者带横杠）。
function isRiskControlReason(reason) {
	let low = lc('' + (reason || ''));
	return (index(low, '11140') >= 0) || (index(low, '11-128') >= 0) ||
		(index(low, '安全审核') >= 0) || (index(low, '安全策略') >= 0) ||
		(index(low, 'safety review') >= 0) || (index(low, 'security policy') >= 0) ||
		(index(low, 'did not pass') >= 0) || (index(low, 'request illegal') >= 0);
}

// 仅取当前可用的凭据（跳过冷却中的），按轮询顺序返回
function usablePool(cfg) {
	let pool = loadPool(cfg);
	let now = time();
	let ok = [];
	for (let c in pool) {
		let st = credState[c.id];
		if (st && st.coolUntil > now) continue;
		push(ok, c);
	}

	// 全部冷却中：退回冷却最早结束的那个，避免完全不可用。
	//
	// 但"被风控"的凭据不在此列：它冷却 30 分钟是有意义的，退回它只会
	// 让每个请求都去撞一次已封账号 —— 既拿不到结果（每次都要等上游拒绝），
	// 又拖慢客户端拿到"账号已被风控"这条可行动信息的时间。
	// 结果是 usablePool 返回空数组，由 handleChat 给出准确报错。
	if (length(ok) === 0 && length(pool) > 0) {
		let best = null;
		for (let c in pool) {
			let st = credState[c.id];
			if (st && isRiskControlReason(st.lastErr)) continue;
			if (best === null) { best = c; continue; }
			let a = credState[c.id] ? credState[c.id].coolUntil : 0;
			let b = credState[best.id] ? credState[best.id].coolUntil : 0;
			if (a < b) best = c;
		}
		if (best !== null) push(ok, best);
	}

	// v2.3.0：按 relay 成功率加权轮询，替代原来的纯轮询。
	// 成功率高的凭据获得更多流量；冷启动（无历史）退化为轮询。
	if (length(ok) > 1) ok = poolWeightedRotate(ok);

	return ok;
}

// 标记凭据异常并进入冷却。retryAfter（秒）为上游响应头里的 Retry-After 窗口，
// 仅在限流类失败时被采信（风控/鉴权类不采信 —— 那些是账号级问题，重试窗口没意义）。
// rate/auth 由调用方传入（isRateLimitReason / isAuthReason 定义在本函数之后，
// ucode 不提升，不能在此调用）。
function markCredFail(cfg, id, reason, rate, retryAfter, auth) {
	let now = time();
	let st = credState[id] || { coolUntil: 0, coolAt: 0, fails: 0, probs: 0, lastErr: '' };
	let risk = isRiskControlReason(reason);
	// v2.1.0：429/限流属于"暂时问题"（probs），不累计 fails —— fails 只反映
	// 真正变冷的失败（风控/鉴权/网络），避免最健康的凭据因被限流而越排越后。
	if (rate) st.probs = (st.probs || 0) + 1;
	else st.fails = (st.fails || 0) + 1;
	// 连续失败则指数退避，上限 10 分钟。
	// 但"账号被风控"不是网络抖动，重试无意义 —— 直接给足 COOL_RISK
	// 并跳过指数退避，让请求尽快落到池里其他账号上。
	let cool;
	if (risk) {
		cool = COOL_RISK;
	} else {
		cool = COOL_MS;
		// v2.1.0：限流不再翻倍惩罚（有 Retry-After 时采信上游真实窗口）。
		if (!rate) {
			for (let i = 1; i < st.fails && cool < 600; i++) cool *= 2;
		}
		if (rate && retryAfter > cool) {
			cool = retryAfter;
			if (cool > MAX_RETRY_AFTER) cool = MAX_RETRY_AFTER;
		}
	}
	// v2.1.0：退避加抖动，打破多客户端同步重试（gRPC 风格 ±20%）。
	cool = int(cool * jitterFactor());
	if (cool < 1) cool = 1;
	st.coolUntil = now + cool;
	st.coolAt = now;
	st.lastErr = '' + reason;
	credState[id] = st;
	logErr(sprintf('credential %s cooling down %ds: %s', id, cool, reason));

	// v2.2.0：记进中转日志。分类入账，便于统计"这个账号主要栽在哪一类"。
	// rate/risk/auth 三类分开记 —— 它们的处置方式完全不同（等一会 / 弃用 / 换 token），
	// 混在一起就失去了优化轮换规则所需的分辨率。
	let ev = rate ? 'rate' : (risk ? 'risk' : (auth ? 'auth' : 'net'));
	relayLogCool(id, cool, reason);
	relayLog(id, ev, reason);
}

function markCredOk(id) {
	if (!credState[id]) {
		// 即便没有冷却记录也要记一次成功 —— 聚合表需要"这个账号成功过几次"，
		// 全新账号第一次就成功时 credState 里还没有条目。
		relayLog(id, 'ok');
		return;
	}
	credState[id].fails = 0;
	credState[id].probs = 0;
	credState[id].lastErr = '';

	// v2.2.0：结算本次冷却的实际经历时长，与 markUpKeyOk 同理 ——
	// 冷却时长来自"按失败类型给的"或"上游 Retry-After 指定的"，
	// 事后无法还原，只有起止两个时间戳相减才得到真实值。
	let spent = 0;
	if (credState[id].coolAt && credState[id].coolUntil > credState[id].coolAt)
		spent = credState[id].coolUntil - credState[id].coolAt;
	credState[id].coolUntil = 0;
	credState[id].coolAt = 0;
	if (spent > 0) relayLogCool(id, spent, 'cooldown served');

	relayLog(id, 'ok');
}

// 凭据健康摘要（供 /health 使用）。
//
// 为什么需要它：出问题时 /health 只说 credentials=1，看不出这个凭据到底能不能用。
// 上游风控时客户端拿到的是 "所有可用凭据均失败：上游错误码：11140"，
// 而 11140 是什么只能去翻上游响应 —— 这一层把"哪个凭据、冷却多久、上次为什么失败"
// 直接透出，排障不用再猜。
//
// 只暴露 id 的末 4 位与错误文本，不含 token 本身：/health 是不鉴权的，
// 不能成为凭据泄露面。
function credSummary(pool) {
	let now = time();
	let out = [];
	for (let c in pool) {
		let st = credState[c.id];
		let id = '' + c.id;
		let e = {
			id: length(id) > 4 ? substr(id, length(id) - 4, 4) : id,
			cooling: (st && st.coolUntil > now) ? (st.coolUntil - now) : 0,
			fails: st ? (st.fails || 0) : 0,
			// v2.1.0：429/限流类失败单独累计（不进 fails），这里单独暴露
			probs: st ? (st.probs || 0) : 0,
		};
		if (st && st.lastErr) e.lastErr = st.lastErr;
		push(out, e);
	}
	return out;
}

// 取一个当前可用的凭据 token 字符串（供模型列表等非重试场景使用）
function pickToken(cfg) {
	let pool = usablePool(cfg);
	if (length(pool) === 0) return null;
	return pool[0].token;
}

// ---------- API 密钥 ----------
//
// 与上游凭据是两层不同的东西：
//   上游凭据 = WorkBuddy 账号 token（我们调用上游用）
//   API 密钥 = 我们发给客户端用（客户端调用本代理用）

function loadApiKeys() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return [];
	let out = [];
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		if (k.enabled === false) continue;
		push(out, { id: '' + (k.id || ''), name: '' + (k.name || ''), key: k.key });
	}
	return out;
}

// 只要密钥文件里定义过任何一条密钥就算“已配置鉴权”，
// 不论它当前是启用还是禁用。
// 注意：这里刻意不看 enabled —— 否则禁用掉最后一条密钥会让
// authRequired 变成 false，整个代理直接对公网敞开，这是危险的默认行为。
function apiKeysDefined() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return 0;
	let n = 0;
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		n++;
	}
	return n;
}

function hasApiKeys() {
	return apiKeysDefined() > 0;
}

// 列出全部密钥（含禁用项与明文值），供管理页随时查看/复制。
// 明文本来就必须存在 apikeys.json 里才能做校验，所以"只显示一次"只是
// 界面上的选择，不是存储限制 —— 这里把完整值提供给已登录的管理页。
function listApiKeysFull() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return [];
	let out = [];
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		push(out, {
			id: '' + (k.id || ''),
			name: '' + (k.name || ''),
			key: k.key,
			enabled: (k.enabled !== false),
			createdAt: +k.createdAt || 0,
		});
	}
	return out;
}

// 生成一条新密钥并落盘，返回该密钥对象。
// genApiKey()/readRandom() 定义在文件顶部基础工具区。

function saveApiKeysFile(j) {
	if (!writeJsonFile(APIKEY_FILE, j)) {
		logErr('apikey save failed');
		return false;
	}
	return true;
}

function addApiKey(name) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') j = { keys: [] };

	let nm = trim('' + (name || ''));
	if (length(nm) === 0) nm = '未命名';

	// id 用时间戳；同一秒内连续创建会撞号，因此补 -N 后缀保证唯一
	let base = 'k' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let k in j.keys) if (type(k) === 'object' && k !== null) taken['' + (k.id || '')] = true;
	while (taken[id]) {
		id = base + '-' + n;
		n++;
	}

	let entry = {
		id: id,
		name: nm,
		key: genApiKey(),
		enabled: true,
		createdAt: time(),
	};
	push(j.keys, entry);
	if (!saveApiKeysFile(j)) return null;
	logInfo('api key added: ' + id + ' (' + nm + ')');
	return entry;
}

function deleteApiKey(id) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return false;
	let out = [];
	let hit = false;
	for (let k in j.keys) {
		if (type(k) === 'object' && k !== null && ('' + (k.id || '')) === ('' + id)) {
			hit = true;
			continue;
		}
		push(out, k);
	}
	if (!hit) return false;
	j.keys = out;
	return saveApiKeysFile(j);
}

function toggleApiKey(id, enabled) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return false;
	let hit = false;
	for (let k in j.keys) {
		if (type(k) === 'object' && k !== null && ('' + (k.id || '')) === ('' + id)) {
			k.enabled = enabled ? true : false;
			hit = true;
		}
	}
	if (!hit) return false;
	return saveApiKeysFile(j);
}

// ---------- 自定义上游（多 API 地址 + 多 Key 轮询） ----------
//
// 背景：WorkBuddy 本身是一个上游（走登录凭据池）。本模块让用户再挂若干个
// 第三方 OpenAI 兼容上游（例如日日新 sensenova、点点 askdiandian），
// 每个上游配多条 Key，效果对齐 dsh-free-models-hub 的 keypools：
//
//   "targets": { "sensenova": "https://token.sensenova.cn/v1", ... }
//   "keyPools": { "sensenova": ["sk-a", "sk-b"], ... }
//
// 模型列表里所有来源都带供应商前缀，客户端一眼能看出模型来自哪：
//     workbuddy/deepseek-v4.1-flash      ← 本机 WorkBuddy 自身
//     sensenova/deepseek-v4-flash        ← 自定义上游
//     askdiandian/dots3-note-prev        ← 自定义上游
//
// 存储：/etc/workbuddy/upstreams.json（与 apikeys.json 并列，权限 0600）
//
// 为什么不复用凭据池：凭据池是"WorkBuddy 账号 token"，轮询的是账号；
// 上游池轮询的是不同厂商的 key，冷却与失败语义都不同，混在一起会互相污染。
const UPSTREAM_FILE = '/etc/workbuddy/upstreams.json';

// 上游池轮询游标：按上游分别记录，避免多上游互相打乱节奏
let upCursor = {};

// 日志与页面里都不应出现完整 Key，只留头尾便于辨认。
// 必须定义在所有调用点之前 —— ucode 函数不提升（踩坑记录 #12）。
function maskKey(k) {
	let s = '' + (k || '');
	if (length(s) <= 10) return '***';
	return substr(s, 0, 6) + '…' + substr(s, length(s) - 4, 4);
}

// ---------- 指标采集（v1.8.0） ----------
//
// 用直方图而不是"存样本再排序"：ucode 的 sort() 对数字按字符串比较
// （'1000' < '9'），分位数会直接算错；归到固定桶里既绕开这个坑，
// 也把内存钉在常数级 —— 长跑不涨，这是转发服务最需要的性质。
const METRIC_BUCKETS = [
	5, 10, 20, 30, 50, 75, 100, 150, 200, 300,
	500, 750, 1000, 1500, 2000, 3000, 5000, 10000, 30000,
];

function histNew() {
	let h = [];
	for (let i = 0; i <= length(METRIC_BUCKETS); i++) push(h, 0);
	return h;
}

function histAdd(h, v) {
	if (!h || !(v >= 0)) return;
	let i = 0;
	while (i < length(METRIC_BUCKETS) && v > METRIC_BUCKETS[i]) i++;
	h[i] = h[i] + 1;
}

function histCount(h) {
	if (!h) return 0;
	let t = 0;
	for (let i = 0; i < length(h); i++) t += h[i];
	return t;
}

// p 分位所在的桶上界（近似值，思路同 Prometheus histogram_quantile）。
// 返回 -1 表示落在最后一个溢出桶，即超过 30000ms。
function histPct(h, p) {
	if (!h) return 0;
	let total = 0;
	for (let i = 0; i < length(h); i++) total += h[i];
	if (total === 0) return 0;
	// 整数**上**取整。
	// ucode 的 / 是整除：直接写 (total*p)/100 会把 1.98 截成 1，
	// 小样本下 p99 于是落在"第 9 小的样本"上，把慢请求藏起来。
	// 分位数宁可高报一点，也不能低报 —— 低报会掩盖正要排查的问题。
	let want = (total * p + 99) / 100;
	let acc = 0;
	for (let i = 0; i < length(h); i++) {
		acc += h[i];
		if (acc >= want) return (i < length(METRIC_BUCKETS)) ? METRIC_BUCKETS[i] : -1;
	}
	return -1;
}

// 一次取齐 p50/p90/p99 与样本数。
// 必须定义在 histPct 之后：ucode 不提升函数，反过来写会在首次调用时抛
// "access to undeclared variable"。
function metricStat(h) {
	return {
		n: histCount(h),
		p50: histPct(h, 50),
		p90: histPct(h, 90),
		p99: histPct(h, 99),
	};
}

// 毫秒时间戳。time() 只有整秒精度，量 TTFB 必须用 clock()（返回 [秒, 纳秒]）。
// 不用 int()：ucode 里 % 的结果本就是整数，先减掉再除即为整数毫秒。
function nowMs() {
	let c = clock();
	let ns = c[1] % 1000000;
	return c[0] * 1000 + (c[1] - ns) / 1000000;
}

function initMetrics() {
	return {
		since: time(),
		chatTotal: 0,       // 进入转发链的聊天请求总数
		chatOk: 0,          // 以 2xx 收尾
		chatFail: 0,        // 以 5xx 或 429 收尾
		chatClientErr: 0,   // 以 4xx（非 429）收尾 —— 客户端问题，不算上游故障
		rateLimited429: 0,  // 以 429 收尾（上游限流 + 本机排队超时/拒绝）
		// v2.1.0：可观测性补齐 —— 客户端中途断开/写失败/截断流单独计数，
		// 不再让"sseHeaders 一发出就记 chatOk"把取消/截断误算成成功。
		chatAborted: 0,     // 客户端在响应完成前断开（写失败/读侧 EOF）
		truncated: 0,       // 流式响应以非 [DONE] 终止（异常截断）次数
		sendFail: 0,        // 向客户端写失败次数（短写/异常）
		queued: 0,          // 曾经进过排队
		queueTimeout: 0,    // 排队等到超时
		queueRejected: 0,   // 队列已满被直接拒绝
		// 直连与池化分开统计 —— 否则"池到底有没有用"永远只能靠感觉
		mode: {
			direct: { req: 0, ttfb: histNew(), total: histNew() },
			pool: { req: 0, ttfb: histNew(), total: histNew() },
		},
		up: {},             // upstreamId -> { ok, fail, rateLimited, authFail }
		key: {},            // upstreamId|maskedKey -> { ok, fail, rateLimited, authFail, lastErr }
		pool: { used: 0, fallback: 0 },
		// v1.8.1 限流刹车：被刹车拦下的重试次数 / 其中"等一次再放行"的次数。
		// 两者之比就是刹车的有效性 —— 全是 rejected 说明上游确实长时间饱和，
		// 全是 waited 说明闭闸时长设得偏长（每次都能等到）。
		brakeRejected: 0,
		brakeWaited: 0,
		// v2.0：token 用量统计。来自上游响应的 usage 字段（SSE 流取末块）。
		usage: { prompt: 0, completion: 0, total: 0 },
		usageByUp: {},      // upstreamId -> usage
		usageByKey: {},     // upstreamId|maskedKey -> usage
		usageByClient: {},  // apiKeyName|ip -> usage
	};
}

let metrics = initMetrics();

function metricUp(upId) {
	if (!metrics.up[upId])
		metrics.up[upId] = { ok: 0, fail: 0, rateLimited: 0, authFail: 0 };
	return metrics.up[upId];
}

function metricKey(upId, key) {
	let id = upId + '|' + maskKey(key);
	if (!metrics.key[id])
		metrics.key[id] = { ok: 0, fail: 0, rateLimited: 0, authFail: 0, lastErr: '' };
	return metrics.key[id];
}

// 记一次上游 Key 失败。kind 由调用方判定后传入（'' | 'rate' | 'auth'）——
// 判定函数 isRateLimitReason/isAuthReason 定义在 1075+，本函数在 1025，
// ucode 不提升且按词法解析，在这里直接调用会抛 undeclared variable。
function metricFail(upId, key, kind, reason) {
	let u = metricUp(upId);
	let k = metricKey(upId, key);
	u.fail++;
	k.fail++;
	if (kind === 'rate') { u.rateLimited++; k.rateLimited++; }
	else if (kind === 'auth') { u.authFail++; k.authFail++; }
	if (reason) k.lastErr = '' + reason;
}

function metricMode(conn) {
	return metrics.mode[conn.usedPool ? 'pool' : 'direct'];
}

// 每条完成的连接记一次总时长与结局。
// 挂在 closeConn 上，是因为它是唯一的收尾咽喉：正常结束/超时/换 Key 用尽/
// 客户端中途断开，四条分支最后都走到这里，不会漏记也不会重复记。
function recordConnMetrics(conn) {
	if (!conn.reqAt) return;   // 不是聊天请求（/health、/models、管理页等）
	metrics.chatTotal++;
	// v2.2.0：把整条请求的结局补进中转日志。
	// 上面那些 marker 事件（pick/rate/switch）只是"过程中的站点"，
	// 缺了这条收尾记录就没法算"选 A 号最终成功率是多少"。
	let durMs = nowMs() - conn.reqAt;
	// v2.1.0：客户端在响应完成前断开（读侧 EOF / 写失败）单独记 abort 桶，
	// 不再让 sseHeaders 先置的 httpStatus=200 把这类请求误算成成功。
	if (conn.aborted) {
		metrics.chatAborted++;
		histAdd(metricMode(conn).total, durMs);
		relayLog(conn.credId || '', 'abort', '', { req: conn.reqId || '', ms: durMs });
		relayTotals.abort++;
		return;
	}
	let st = conn.httpStatus || 0;
	if (st >= 200 && st < 300) metrics.chatOk++;
	else if (st === 429) { metrics.rateLimited429++; metrics.chatFail++; }
	else if (st >= 400 && st < 500) metrics.chatClientErr++;
	else metrics.chatFail++;
	histAdd(metricMode(conn).total, durMs);

	// 截断（流式没收尾）单独标记：它比"彻底失败"更危险 ——
	// 客户端可能把半截回答当成完整回答用掉，而状态码还是 200。
	if (conn.headersSent && conn.sawDone === false && conn.wantNonStream !== true) {
		relayLog(conn.credId || '', 'trunc', '', { req: conn.reqId || '', ms: durMs });
		relayTotals.trunc++;
	}
}

// 读取上游配置。返回数组，每条形如：
//   { id, name, prefix, baseUrl, keys: [...], weights: {...}, enabled, createdAt }
// v2.0：loadUpstreams 的 TTL 缓存：{ at, list }
// 必须声明在 loadUpstreams() 之前（ucode 不提升声明，见下）。
let upstreamCache = { at: 0, list: null };

function loadUpstreams() {
	// v2.0：TTL 缓存。管理页保存路径会主动失效（见 saveUpstreamsFile），
	// 外部直接编辑文件最多延迟 UPSTREAM_CACHE_TTL 秒生效。
	let now = time();
	if (upstreamCache.list !== null && (now - upstreamCache.at) < UPSTREAM_CACHE_TTL)
		return upstreamCache.list;

	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') {
		upstreamCache = { at: now, list: [] };
		return [];
	}
	let out = [];
	for (let u in j.upstreams) {
		if (type(u) !== 'object' || u === null) continue;

		let id = '' + (u.id || '');
		let prefix = '' + (u.prefix || '');
		let baseUrl = '' + (u.baseUrl || '');
		if (length(id) === 0 || length(prefix) === 0 || length(baseUrl) === 0) continue;

		// Key 统一清洗成字符串数组，过滤空值与重复
		let keys = [];
		let seen = {};
		if (type(u.keys) === 'array') {
			for (let k in u.keys) {
				if (type(k) !== 'string') continue;
				let t = trim(k);
				if (length(t) === 0) continue;
				if (seen[t]) continue;
				seen[t] = true;
				push(keys, t);
			}
		}

		// v2.0：权重表 { key: 权重 }。只保留 >=1 的数值，其余忽略。
		let weights = {};
		if (type(u.weights) === 'object' && u.weights !== null) {
			for (let wk in u.weights) {
				let wt = +u.weights[wk];
				if (!(wt >= 1)) continue;
				weights[wk] = wt;
			}
		}

		// v2.7.0：模型映射。v2.8.0 修复：loadUpstreams() 构造新对象时之前没拷贝
		// 这两个字段，导致 /v1/models 的自定义清单分支与 upstreamStatus() 的
		// modelCount/modelsText 全部失效（管理页看不到映射、列表也不生效）。
		let modelListSeen = {};
		let modelList = [];
		let modelMap = {};
		if (type(u.modelList) === 'array') {
			for (let mid in u.modelList) {
				if (type(mid) !== 'string') continue;
				let t = trim(mid);
				if (length(t) === 0) continue;
				if (modelListSeen[t]) continue;
				modelListSeen[t] = true;
				push(modelList, t);
			}
		}
		if (type(u.modelMap) === 'object' && u.modelMap !== null) {
			for (let ak in u.modelMap) {
				let av = '' + (u.modelMap[ak] || '');
				if (type(av) === 'string' && length(av) > 0) modelMap['' + ak] = av;
			}
		}

		push(out, {
			id: id,
			name: '' + (u.name || prefix),
			prefix: prefix,
			baseUrl: baseUrl,
			keys: keys,
			weights: weights,
			enabled: (u.enabled !== false),
			createdAt: +u.createdAt || 0,
			modelList: modelList,
			modelMap: modelMap,
		});
	}
	upstreamCache = { at: now, list: out };
	return out;
}

// 上游健康状态：仅存内存，重启即清（冷却本来就不该跨重启持久化）
let upState = {};
// v2.2.0：供文件前部的 relayCoolingSec / relayLastErr 读取本表。
// 那两个函数在 900 行附近，直接写 upState 会触发 ucode 的
// "reference before declaration"（定义时解析自由变量），故经 F 表绕行。
F.upStateGet = function (key) { return upState[key]; };
// v1.8.1 上游级限流刹车状态：upId -> { hits, winStart, openUntil, trip, waited, rejected }
let upBrake = {};
// v2.0：会话粘性表：upId|client -> { key, until }（client 为 API Key 名或客户端 IP）
let upSticky = {};

// 【提前声明，勿删】v1.8.1：cfg 原本只在「连接处理」区 `let cfg = loadConfig();`（约 2842 行），
// 但 brakeNoteRateLimit() / brakeLeft() 定义在 1471 / 1460 行、需要读 cfg.brakeHits 等。
// ucode **不提升声明**：函数按定义时的词法作用域解析标识符，声明在函数之后就抛
//   Reference error: access to undeclared variable cfg
// 而且只在**真正调用到那一行**时才炸 —— `ucode -c` 语法检查与单元测试都拦不住。
// v1.8.1 首次上线就是这么把服务打成崩溃-重启循环的：平时看着正常，一撞上游限流就死，
// procd 拉起来、下一个限流请求再死一次（日志里能看到 pid 连续变化）。
// 因此按本文件既有做法（connections 同样被提前到头部）把**声明**挪到这里，
// 真正的赋值仍留在 2842 行 —— 那行才是"读盘"发生的时刻，顺序不能动。
let cfg = {};

// ---------- 上游响应回环桥（v1.8.3）的状态 ----------
//
// 机制与背景见文件头部（约 396 行）的 v1.8.3 常量块：BRIDGE_PORT_DEFAULT /
// NC_PATH 已在那里提前声明（loadConfig() 要读，本文件不提升声明）。这里只放
// 桥自身的运行时状态 —— 它们被 2390 行之后的 bridge* 函数引用，声明必须靠前。
let bridgeListen = null;   // 本地回环监听 socket
let bridgePending = {};    // 请求 id -> conn
let bridgeSeq = 0;

// 判定失败原因是否属于"上游限流"（tpm/rpm 配额、429、too many requests）。
//
// 这个判定两处共用同一份逻辑，不能各写一份：
//   1) markUpKeyFail()  —— 决定冷却时长（限流走指数退避，避免 2 秒后又去撞一次）
//   2) tryNextUpKey()   —— 限流**不换 Key**，直接把结果返回客户端
//      （用户明确要求：Key 只做轮播，不自动切换到下一把）
function isRateLimitReason(reason) {
	let low = lc('' + (reason || ''));
	return (index(low, 'tpm') >= 0) || (index(low, 'rpm') >= 0) ||
		(index(low, 'rate limit') >= 0) || (index(low, 'too many') >= 0) ||
		(index(low, '429') >= 0) || (index(low, '限流') >= 0);
}

// 判定是否"这把 Key 本身不可用"（鉴权失败）—— 这类冷却时间给最长。
//
// ⚠️ 这里**绝对不能**用裸 `'invalid'` 做子串匹配。实测教训（2026-09-28）：
// 上游对**请求体**有问题时会回 `inference request is invalid`，
// 而裸 'invalid' 会把它判成鉴权失败 → 4 把 Key 各冷却 600s →
// 客户端收到 `429 retry_after:577`，一次请求错误让整个上游停摆 10 分钟。
// 判据必须绑到"鉴权"这个词本身，或明确的鉴权报文措辞。
function isAuthReason(reason) {
	let low = lc('' + (reason || ''));
	return (index(low, 'unauthorized') >= 0) ||
		(index(low, 'authentication') >= 0) ||
		(index(low, 'invalid api key') >= 0) ||
		(index(low, 'invalid apikey') >= 0) ||
		(index(low, 'invalid access token') >= 0) ||
		(index(low, 'invalid token') >= 0) ||
		(index(low, 'invalid key') >= 0) ||
		(index(low, 'invalid authorization') >= 0) ||
		(index(low, 'api key') >= 0) ||
		(index(low, '401') >= 0) || (index(low, '403') >= 0);
}

// 判定失败原因是否属于"上游不接受这个模型名"（模型不存在 / 不在套餐内）。
//
// 这类是**客户端错误**，且对同一个上游的**所有 Key 结果完全相同**，所以：
//   1) 不该给 Key 记冷却 —— Key 本身是好的，冤枉它只会让好请求也被拖住；
//   2) 不该换下一把 Key 重试 —— 必然同样失败，白白多打 3 次上游；
//   3) 不该报"所有 Key 均失败" —— 那是把"模型名写错"说成了"服务故障"。
//
// 实测依据（直连 token.sensenova.cn，2026-09-28）：
//   sensenova-u1-fast     -> 404 "model is not found"
//   sensenova-u1.5-lite   -> 404 "model is not found"
//   deepseek-v4.1-flash   -> 403 "model is not available in the current token plan"
// 注意前两个**仍出现在上游自己的 /v1/models 列表里** —— 上游的模型表并不权威。
// 所以这条路径一定会被走到：客户端照列表选模型，照样可能被上游拒绝。
function isModelRejectReason(reason) {
	let low = lc('' + (reason || ''));
	return (index(low, 'model is not found') >= 0) ||
		(index(low, 'model not found') >= 0) ||
		(index(low, 'no such model') >= 0) ||
		(index(low, 'model does not exist') >= 0) ||
		(index(low, 'unsupported model') >= 0) ||
		(index(low, 'invalid model') >= 0) ||
		(index(low, 'not available in the current token plan') >= 0);
}

// 客户端错误总判定：模型层面 + 请求体层面，两者都指向"请求本身有问题"，
// 不是 Key 的问题（所以不该冷却 Key、不该换 Key、更不该报"所有 Key 均失败"）。
// 实测依据（2026-09-28 生产日志）：`inference request is invalid` 等。
// ⚠️ 措辞要挑准，**别用 'exceeds'** —— 它会撞上 `inference exceeds tpm/rpm limit`
// （那是限流，必须走冷却+换 Key 那条路）。
function isClientErrorReason(reason) {
	let low = lc('' + (reason || ''));
	return isModelRejectReason(reason) ||
		(index(low, 'request is invalid') >= 0) ||
		(index(low, 'invalid request') >= 0) ||
		(index(low, 'bad request') >= 0) ||
		(index(low, 'malformed') >= 0) ||
		(index(low, 'request body') >= 0) ||
		(index(low, 'context length') >= 0) ||
		(index(low, 'maximum context') >= 0) ||
		(index(low, 'payload too large') >= 0) ||
		(index(low, 'request too large') >= 0);
}

// ---------- v1.8.1：上游限流刹车 ----------
//
// 状态机（每条上游一份，懒创建）：
//   hits       本窗口内观测到的"被上游限流拒绝"次数
//   winStart   本窗口起点
//   openUntil  闭闸截止时间戳（0 = 未闭闸）
//   trip/waited/rejected  诊断计数（闭闸次数 / 等待放行次数 / 直接拒绝次数）
//
// 一条铁律：**闭闸期间不产生上游流量**。计数与开闸在 brakeNoteRateLimit 里做
// （由 markUpKeyFail 在判明 rate 后调用），合闸在 brakeClear 里做（成功即自愈）。
function brakeState(upId) {
	let b = upBrake[upId];
	if (!b) {
		b = { hits: 0, winStart: 0, openUntil: 0, trip: 0, waited: 0, rejected: 0 };
		upBrake[upId] = b;
	}
	return b;
}

// 闭闸剩余秒数。0 = 未闭闸（或刹车功能被 rl_brake_hits=0 关闭）。
function brakeLeft(up) {
	if (cfg.brakeHits <= 0) return 0;
	let b = upBrake[up.id];
	if (!b || b.openUntil <= 0) return 0;
	let left = b.openUntil - time();
	return (left > 0) ? left : 0;
}

// 记一次"上游限流拒绝"，窗口内累计到阈值就闭闸。
// 注意判据是**观测到的上游拒绝**，不是我们自己的冷却模型 —— 冷却只是估计，
// 上游到底恢没恢复只有上游知道，所以不拿冷却当开闸条件。
function brakeNoteRateLimit(up) {
	if (cfg.brakeHits <= 0) return;
	let b = brakeState(up.id);
	let now = time();

	// 窗口过期就重新计数。起点是"上次重置时间"而非精确滑动 ——
	// 单线程 ucode 里做真滑窗要存时间戳数组，为这点精度不值得。
	if (b.winStart === 0 || (now - b.winStart) > cfg.brakeWindow) {
		b.winStart = now;
		b.hits = 0;
	}

	b.hits++;
	if (b.hits < cfg.brakeHits) return;

	// 达阈值：闭闸。若已处于闭闸中则取更晚的截止时间，绝不缩短已有闭闸。
	let until = now + cfg.brakeSec;
	if (until > b.openUntil) b.openUntil = until;
	b.hits = 0;
	b.winStart = now;
	b.trip++;
	logErr(sprintf('上游 %s 在 %ds 内被限流拒绝 %d 次，刹车 %ds（期间不再打上游，直接回 429）',
		up.prefix, cfg.brakeWindow, cfg.brakeHits, cfg.brakeSec));
}

// 任一上游成功即合闸。刹车是应急手段，不该比上游自己的恢复更久。
// 也正因为"成功即清零计数"，一个还在正常出结果的（只是偶尔被拒的）上游
// 永远不会被闭闸 —— 宁可少刹，不可误刹。
function brakeClear(up) {
	let b = upBrake[up.id];
	if (!b || b.openUntil === 0) return;
	if (time() < b.openUntil)
		logInfo(sprintf('上游 %s 刹车期间请求成功，提前解除刹车', up.prefix));
	b.openUntil = 0;
	b.hits = 0;
	b.winStart = 0;
}

// 该上游最早一把 Key 还有多少秒脱离冷却。
// 全部 Key 都在冷却时用它填 Retry-After —— 让客户端按正确节奏退避，
// 而不是立刻重试、再撞一次限流（这正是"越限流越慢"的来源）。
// 返回 0 表示至少有一把 Key 当前可用。
function upEarliestRetrySec(up) {
	let now = time();
	let best = -1;
	for (let k in up.keys) {
		let st = upState[up.id + '|' + k];
		let rem = (st && st.coolUntil > now) ? (st.coolUntil - now) : 0;
		if (rem <= 0) return 0;
		if (best < 0 || rem < best) best = rem;
	}
	return best < 0 ? 0 : best;
}

// ---------- v2.8.0：模型列表落盘（最后已知可用） ----------
//
// upModelCache 原本只存在内存：上游 /models 一抖，/v1/models 就跟着变空，
// 客户端拿到空列表会以为自己配错了。现在把「最后已知可用」的模型列表落盘到
// MODEL_CACHE_FILE，启动时载入、拉取成功时写入、上游配置变更时清空。
//
// 【位置约束】必须定义在 saveUpstreamsFile（紧随其后）之前 —— 那个函数会调用
// saveModelCache()，而 ucode 不提升声明，函数按定义时的词法作用域解析自由变量，
// 声明在后会抛 "access to undeclared variable"（踩坑记录 #12）。
function saveModelCache() {
	let slim = {};
	for (let ck in upModelCache) {
		let ce = upModelCache[ck];
		if (type(ce) === 'object' && ce !== null && type(ce.list) === 'array')
			slim[ck] = { at: ce.at, list: ce.list };
	}
	try {
		writeJsonFile(MODEL_CACHE_FILE, { saved: time(), cache: slim });
	} catch (e) {
		logErr('saveModelCache failed: ' + e);
	}
}

function loadModelCache() {
	let j = null;
	try { j = readJsonFile(MODEL_CACHE_FILE); } catch (e) { j = null; }
	if (!j || type(j.cache) !== 'object' || j.cache === null) return;
	for (let ck in j.cache) {
		let ce = j.cache[ck];
		if (type(ce) === 'object' && ce !== null && type(ce.list) === 'array')
			upModelCache[ck] = { at: +ce.at || 0, list: ce.list };
	}
}

function saveUpstreamsFile(j) {
	if (!writeJsonFile(UPSTREAM_FILE, j)) {
		logErr('upstream save failed');
		return false;
	}
	// 上游配置变了（增删 / 改 Key / 停用），模型列表缓存必须作废，
	// 否则管理页改完还要等 TTL 到期才看得到新模型。
	upModelCache = {};
	// v2.8.0：落盘副本同步清空。不清的话，下次上游拉取失败时会用"上一个
	// 上游配置"的最后已知列表兜底 —— 那是错的列表，比空列表更容易误导人。
	// （清空后 saveModelCache 写的是空表，loadModelCache 自然什么都不兜。）
	saveModelCache();
	// v2.0：loadUpstreams 的 TTL 缓存同样立即失效。
	upstreamCache = { at: 0, list: null };
	return true;
}

// v2.0：判断主机名/地址是否属于内网或本机。allow_private_upstream=0 时
// 不允许自定义上游指向这些地址，防止管理面被攻破后借本机做内网跳板。
function isPrivateHost(host) {
	let h = lc('' + (host || ''));
	if (h === 'localhost') return true;
	// IPv4 私网/回环段
	let m = match(h, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	if (m) {
		let a = +m[1];
		let b = +m[2];
		if (a === 10) return true;
		if (a === 127) return true;
		if (a === 192 && b === 168) return true;
		if (a === 172 && b >= 16 && b <= 31) return true;
		return false;
	}
	// IPv6 回环 / ULA / link-local（尽力匹配；路由器上上游地址几乎都是 IPv4）
	if (h === '::1') return true;
	if (substr(h, 0, 2) === 'fc' || substr(h, 0, 2) === 'fd') return true;
	if (substr(h, 0, 5) === 'fe80:') return true;
	return false;
}

// 校验上游地址：只允许 http/https，且必须以 /v1 之类路径结尾。
// 返回规范化后的地址（去掉结尾多余的 /v1/ 重复斜杠），非法返回 null。
function normalizeBaseUrl(raw) {
	let u = trim('' + (raw || ''));
	if (length(u) === 0) return null;
	if (length(u) > 512) return null;

	let low = lc(u);
	if (substr(low, 0, 7) !== 'http://' && substr(low, 0, 8) !== 'https://') return null;

	// v2.0：allow_private_upstream=0 时拒绝内网/本机地址（见 isPrivateHost）。
	if (cfg && cfg.allowPrivateUpstream === false) {
		let hm = match(low, /^https?:\/\/([^\/:]+)/);
		let host = hm ? lc('' + hm[1]) : '';
		if (length(host) > 0 && isPrivateHost(host)) return null;
	}

	// 去掉结尾斜杠，避免拼出 //v1/chat/completions
	while (length(u) > 0 && substr(u, length(u) - 1, 1) === '/')
		u = substr(u, 0, length(u) - 1);

	if (length(u) < 12) return null;
	return u;
}

// 规范化供应商前缀：小写字母数字与 - _，长度 2-32。
// 前缀会出现在模型名里，因此必须限制字符集，否则会破坏 "前缀/模型" 的切分。
function normalizePrefix(raw) {
	let p = lc(trim('' + (raw || '')));
	if (length(p) < 2 || length(p) > 32) return null;
	for (let i = 0; i < length(p); i++) {
		let ch = substr(p, i, 1);
		let ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
		if (!ok) return null;
	}
	// 不能含斜杠（切分符），上面字符集已排除
	return p;
}

// 取该上游的 Key **尝试顺序**。
//
// 不变量（v1.7.11 起，勿破坏）：
//   1) `up.keys` 非空时，返回值**必定包含每一把 Key**，且不重复；
//   2) 顺序 =「健康 Key（严格轮询）」+「有失败记录的 Key（冷却结束早的在前）」。
//
// 为什么必须返回全部 Key：上层靠 `conn.upTry < length(conn.upKeys)` 限制单次
// 请求的尝试次数，并实现「不通就换下一个」。若这里只返回一把，那个机制就退化成
// "只试一把就放弃" —— 旧实现正是如此：全部冷却时只退回一把，
// 于是"所有 Key 都在冷却"变成了客户端的死局（用户实际撞到的问题）。
//
// 为什么健康 Key 优先且轮询：正常流量在 Key 之间均摊（负载均衡），
// 刚失败的 Key 不会被新流量立刻再撞一次，但它**仍然排在队里**、随时可被尝试。
// v2.0 增强：支持 per-Key 权重（weightedRotate）与会话粘性（upSticky）。
// 权重只影响"健康 Key"内部的轮询分布；粘性只对同一客户端（apiKeyName 或 IP）
// 生效：若该客户端上次成功用的 Key 仍然健康，就把它排在最前。
function weightedRotate(up, keys) {
	let n = length(keys);
	let w = [];
	let total = 0;
	for (let i = 0; i < n; i++) {
		// v2.3.0：取"配置权重"与"relay 成功率权重"的较大值。
		// 配置权重是用户手动设的底线（"这把 Key 我要保证至少 N 倍流量"），
		// relay 权重是运行时自动加成（"这把 Key 最近表现好，多给些"）。
		// 用 max 而非乘法：乘法会把"配置=1 + relay=10"放大成 10，但也会把
		// "配置=5 + relay=1（冷启动）"缩成 5 —— 后者没问题，但前者在
		// relay 数据还不稳定时波动太大。max 更保守，relay 只做"加成"不做"打折"。
		let cfg_w = (up.weights && up.weights[keys[i]]) || 1;
		if (!(cfg_w >= 1)) cfg_w = 1;
		let relay_w = relayWeight('up:' + up.id + ':' + maskKey(keys[i]));
		let wt = (cfg_w > relay_w) ? cfg_w : relay_w;
		w[i] = wt;
		total += wt;
	}
	// 游标按权重取模定位首个键；权重全为 1 时退化为普通轮询。
	let start = upCursor[up.id] || 0;
	upCursor[up.id] = start + 1;
	let pos = start % total;
	let first = 0;
	let acc = 0;
	for (let i = 0; i < n; i++) {
		acc += w[i];
		if (pos < acc) { first = i; break; }
	}
	let out = [];
	for (let i = 0; i < n; i++) push(out, keys[(first + i) % n]);
	return out;
}

function usableUpKeys(up, stickyFor) {
	let clean = [];
	let rec = [];
	for (let k in up.keys) {
		// v2.5.0：单 Key 停用。停用的 Key 连"恢复队列"都不进 —— 用户手动
		// 停用通常是因为这把 Key 已被上游封禁/欠费，再拿它去试探只会白费
		// 一次请求并让上游多记一次失败。
		if (up.disabled && up.disabled[k]) continue;
		let st = upState[up.id + '|' + k];
		if (st && st.fails > 0) push(rec, k); else push(clean, k);
	}

	// 健康 Key 之间按权重轮播（weightedRotate），避免单把 Key 过载。
	let n = length(clean);
	if (n > 1) clean = weightedRotate(up, clean);

	// v2.0 会话粘性：同一客户端上次成功用的 Key 若仍健康，排到最前。
	if (length(stickyFor) > 0 && length(clean) > 1) {
		let s = upSticky[up.id + '|' + stickyFor];
		let stickyKey = (s && s.key && s.until > time()) ? s.key : '';
		if (length(stickyKey) > 0) {
			let si = -1;
			for (let i = 0; i < length(clean); i++)
				if (clean[i] === stickyKey) { si = i; break; }
			if (si > 0) {
				let rot = [];
				push(rot, stickyKey);
				for (let i = 0; i < length(clean); i++)
					if (i !== si) push(rot, clean[i]);
				clean = rot;
			}
		}
	}

	// 恢复中的 Key：冷却结束早的排前面（先试最可能已恢复的那把）。
	// Key 数量很小（个位数），用"反复取最小"即可，不必引排序依赖。
	let rest = [];
	let used = {};
	let m = length(rec);
	for (let i = 0; i < m; i++) {
		let best = null;
		let bestV = 0;
		for (let j = 0; j < m; j++) {
			let k = rec[j];
			if (used[k]) continue;
			let st = upState[up.id + '|' + k];
			let v = st ? st.coolUntil : 0;
			if (best === null || v < bestV) { best = k; bestV = v; }
		}
		if (best === null) break;
		used[best] = true;
		push(rest, best);
	}

	let out = [];
	for (let k in clean) push(out, k);
	for (let k in rest) push(out, k);

	// 兜底：正常走不到（loadUpstreams 已滤掉空 Key），但绝不能让上层拿到空数组 ——
	// 那会被当作"没有配置 Key"而直接 503。
	if (length(out) === 0 && length(up.keys) > 0) push(out, up.keys[0]);

	return out;
}

// 标记上游 Key 失败并进入冷却。retryAfter（秒）为上游响应头 Retry-After 窗口，
// 仅在限流类失败时被采信（鉴权/瞬时错误不采信）。
function markUpKeyFail(up, key, reason, retryAfter) {
	let now = time();
	let id = up.id + '|' + key;
	let st = upState[id] || { coolUntil: 0, coolAt: 0, fails: 0, probs: 0, lastErr: '' };

	// v2.1.0：失败分类 —— 429/限流是"暂时问题"（probs），不累计 fails。
	// 原实现把所有失败都累进 fails，限流也因此参与指数退避（5→10→20s），
	// 最健康的 Key 反而因为被限流而越排越后（436faa3c B1）。
	let rate = isRateLimitReason(reason);
	let auth = isAuthReason(reason);
	if (rate) st.probs = (st.probs || 0) + 1;
	else st.fails = (st.fails || 0) + 1;

	// 冷却时长按失败类型区分。
	//
	// 实测教训：这里曾固定冷却 2 秒。但上游限流是按 tpm/rpm 计的 —— 2 秒后该
	// Key 又被选中、立刻再撞一次限流，一次客户端请求能在 4 个 Key 之间连撞多轮，
	// 实测出现 12.45s 与 60s+ 的挂起。限流必须指数退避。
	// v2.1.0 调整：限流不再指数翻倍（probs 不参与退避），改为固定基础冷却或
	// 直接采信上游 Retry-After（更贴近真实窗口）；指数退避只保留给非限流失败。
	let cool;
	if (rate) {
		cool = UP_RATE_COOL;
		if (retryAfter > cool) {
			cool = retryAfter;
			if (cool > MAX_RETRY_AFTER) cool = MAX_RETRY_AFTER;
		}
	} else if (auth) {
		cool = UP_AUTH_COOL;
	} else {
		cool = UP_SOFT_COOL;
	}

	// v2.1.0：退避加抖动，打破多客户端同步重试（gRPC 风格 ±20%）。
	cool = int(cool * jitterFactor());
	if (cool < 1) cool = 1;

	st.coolUntil = now + cool;
	// 冷却起点。只有"起点 + 终点"两个时间戳都在，markUpKeyOk 才能算出这次
	// 冷却实际持续了多久（v2.2.0 的冷却占比指标依赖它）。
	st.coolAt = now;
	st.lastErr = '' + reason;
	upState[id] = st;
	logErr(sprintf('upstream %s key %s cooling %ds (%s): %s',
		up.prefix, maskKey(key), cool, rate ? '限流' : (auth ? '鉴权' : '瞬时'), reason));

	// v2.2.0：自建上游的 Key 也进中转日志。
	// 账号 id 用 "up:<upstreamId>:<maskedKey>" —— 与凭据池的 c<ts> 区分开，
	// 健康矩阵里一眼能看出这是自有上游的 Key 而不是 WorkBuddy 账号。
	// 用 relayFail 而不是裸 relayLog：限流/鉴权失败也属于"这次选中"，
	// 必须同时计入该 Key 的 pick 与全局 pick（口径见 relayPick 的注释）。
	relayFail('up:' + up.id + ':' + maskKey(key),
		rate ? 'rate' : (auth ? 'auth' : 'net'), reason, { sec: cool });

	// 指标埋点就放这里：本函数是"这把 Key 失败过"的唯一入口，
	// 分档判据 rate/auth 上一行已经算好，不必让指标层再判一遍。
	metricFail(up.id, key, rate ? 'rate' : (auth ? 'auth' : ''), reason);

	// v1.8.1：限流类失败同时喂给上游刹车。连续被同一上游拒到阈值就闭闸，
	// 掐断"4 把 Key 全冷却时仍打满 4 次注定失败的上游调用"这个正反馈。
	if (rate) brakeNoteRateLimit(up);
}

// 【已删除】nextUsableUpKey()：v1.7.1 用它从 up.keys 里挑一把"未冷却"的 Key，
// 全部冷却时返回 null → 上层直接回 `429 当前 Key 被限流`（还有 Key 没试过就放弃）。
// v1.7.11 删除，因为顺序现在统一由 usableUpKeys() 在请求开始时算好
// （健康 Key 轮询在前、失败过的按冷却结束时间在后），
// 换下一把只需推进 conn.upTry 槽位即可，不需要在转发中途再挑一次。

// 【已删除】allUpKeysCooling()：v1.7.1 曾用它做"全部 Key 都冷却就立刻回
// 429 + Retry-After，省掉空转"的短路。v1.7.11 移除，原因有两条：
//   1) 它的对外表现就是用户投诉的那句
//      `429 上游 sensenova 所有 Key 均在冷却中（retry_after:577）` ——
//      把一次局部失败放大成"整个上游不可用"，还让客户端退避近 10 分钟；
//   2) 用户明确要求「不通的自动换下一个」，即宁可多打几次上游，
//      也不能在还有 Key 没试过的情况下就放弃。
// 相关的不变量：usableUpKeys() 现在**永远返回全部 Key**（只调整顺序），
// 因此"空转"已被天然限制在 `conn.upKeys` 长度以内（最多 4 次）。

function markUpKeyOk(up, key) {
	// 成功计数必须放在下面的提前 return 之前：一把从未失败过的 Key 在 upState
	// 里根本没有条目，但它的成功同样要计 —— 否则"成功率"只统计到失败过的 Key。
	metricUp(up.id).ok++;
	metricKey(up.id, key).ok++;

	// v1.8.1：任一成功即合闸（含清零计数）。
	// 这一行同时保证了刹车**不会误刹**：只要这把上游还在正常出结果，
	// 它的限流计数就永远攒不到阈值。
	//
	// 位置必须在下面那个提前 return **之前**：一把从未失败过的 Key 在 upState
	// 里没有条目，若把 brakeClear 放在 return 之后，它成功时刹车就不合闸，
	// 「成功即自愈」对这把 Key 等于没接线（本函数第一版就是这么写的）。
	brakeClear(up);

	let id = up.id + '|' + key;

	// 与上面两处同理：中转日志的成功计数也必须放在提前 return **之前**。
	// 一把从未失败过的 Key 在 upState 里没有条目，若把 relayLog 放在
	// return 之后，它每次成功都不会被记录，健康矩阵里就会显示成
	// "选中 6 次、成功 0 次、成功率 0%"——看起来像这把 Key 完全不可用，
	// 而事实恰恰相反（它一次都没被限流）。v2.2.0 首次真机验收就撞上了这个坑：
	// pick=52 但 ok 只有 5。
	relayLog('up:' + up.id + ':' + maskKey(key), 'ok');

	if (!upState[id]) return;
	upState[id].fails = 0;
	upState[id].probs = 0;
	upState[id].lastErr = '';

	// v2.2.0：结算本次冷却的"实际经历时长"。
	//
	// 为什么必须在这里算：冷却时长有两个来源，事后无法还原 ——
	//   ① 我们按失败类型给的（UP_RATE_COOL / UP_AUTH_COOL / 指数退避）
	//   ② 上游 Retry-After 指定的（markUpKeyFail 采信并夹到 MAX_RETRY_AFTER）
	// 只有"开始冷却的时刻"（记在 coolAt）和"冷却真正结束的时刻"（此刻）两个
	// 时间戳相减，才是这把 Key 实际被冷藏了多久。少了这一步，健康矩阵里的
	// 「冷却占比」永远是 0 —— 真机首测就是这样：限流 29 次、冷却次数 0，
	// 评估冷却参数时看不到任何信号。
	let spent = 0;
	if (upState[id].coolAt && upState[id].coolUntil > upState[id].coolAt)
		spent = upState[id].coolUntil - upState[id].coolAt;
	upState[id].coolUntil = 0;
	upState[id].coolAt = 0;
	if (spent > 0) relayLogCool('up:' + up.id + ':' + maskKey(key), spent, 'cooldown served');
}

// ---------- v2.0：成功收尾 / token 用量统计 ----------

// 上游 Key 成功时统一记录：成功计数 + 会话粘性绑定。
// onUpstreamDirectEnd 的两个成功分支都调它，保证计数与粘性同步。
function noteUpstreamSuccess(conn) {
	if (conn.upstream && conn.upKeyInUse) {
		markUpKeyOk(conn.upstream, conn.upKeyInUse);
		if (length(conn.stickyFor) > 0 && cfg.upStickySec > 0)
			upSticky[conn.upstream.id + '|' + conn.stickyFor] = {
				key: conn.upKeyInUse,
				until: time() + cfg.upStickySec,
			};
	}
}

// 从上游响应文本提取 usage。支持两种形态：
//   1) 非流式：整个 body 就是 JSON，直接取 .usage；
//   2) 流式 SSE：最后一个非 [DONE] 的 `data:` 块通常带 usage，取该块 JSON 的 .usage。
// 解析不到返回 null（不计数 —— 不能让错误/空响应当成功用量算进去）。
function extractUsage(text) {
	if (type(text) !== 'string' || length(text) === 0) return null;
	let t = trim(text);
	let obj = null;
	if (substr(t, 0, 1) === '{') {
		try { obj = json(t); } catch (e) { obj = null; }
	} else {
		// v2.9.0 修复：倒序扫描**所有** data: 行，找到第一个真正携带 usage 的对象为止。
		//
		// 旧实现只要解析出一行合法 JSON 就 break —— 于是"最后一行"决定了结果。
		// 某些上游的流尾形态是：
		//     data: {... "usage":{...}}
		//     data: [DONE]
		//     data: {"choices":[],"cost":"0"}
		// 最后那个 cost 计费块**没有 usage 字段**，旧实现在它上面 break 后
		// `obj.usage` 取到 null，直接 return null，用量永远记不上账
		// （实测：聊天 HTTP 200 成功，全局 usage 计数纹丝不动）。
		// 现在把"解析成功"与"确实含 usage"分开判断，解析不出 usage 就继续往前找。
		let lines = split(t, '\n');
		for (let i = length(lines) - 1; i >= 0; i--) {
			let ln = trim(lines[i]);
			if (substr(ln, 0, 5) !== 'data:') continue;
			let payload = trim(substr(ln, 5));
			if (payload === '[DONE]') continue;
			let cand = null;
			try { cand = json(payload); } catch (e) { cand = null; }
			if (type(cand) !== 'object' || cand === null) continue;
			let cu = cand.usage;
			if (type(cu) !== 'object' || cu === null) continue;
			obj = cand;
			break;
		}
	}
	if (type(obj) !== 'object' || obj === null) return null;
	let u = obj.usage;
	if (type(u) !== 'object' || u === null) return null;
	let prompt = +u.prompt_tokens || 0;
	let completion = +u.completion_tokens || 0;
	let total = +u.total_tokens || (prompt + completion);
	if (total <= 0 && prompt <= 0 && completion <= 0) return null;
	return { prompt: prompt, completion: completion, total: total };
}

// 成功请求收尾时累加 token 用量到全局 / 上游 / Key / 客户端四个维度。
function recordUsage(conn, usage) {
	if (!conn || !usage) return;
	metrics.usage.prompt += usage.prompt;
	metrics.usage.completion += usage.completion;
	metrics.usage.total += usage.total;

	let upId = conn.upstream ? conn.upstream.id : (conn.credId ? 'wb:' + conn.credId : '');
	if (length(upId) > 0) {
		let uu = metrics.usageByUp[upId] || { prompt: 0, completion: 0, total: 0 };
		uu.prompt += usage.prompt;
		uu.completion += usage.completion;
		uu.total += usage.total;
		metrics.usageByUp[upId] = uu;
	}
	if (conn.upKeyInUse) {
		let kid = upId + '|' + maskKey(conn.upKeyInUse);
		let uk = metrics.usageByKey[kid] || { prompt: 0, completion: 0, total: 0 };
		uk.prompt += usage.prompt;
		uk.completion += usage.completion;
		uk.total += usage.total;
		metrics.usageByKey[kid] = uk;
	}
	if (length(conn.reqClient) > 0) {
		let uc = metrics.usageByClient[conn.reqClient] || { prompt: 0, completion: 0, total: 0 };
		uc.prompt += usage.prompt;
		uc.completion += usage.completion;
		uc.total += usage.total;
		metrics.usageByClient[conn.reqClient] = uc;
	}
}

// 把 usage 对象格式化成 "prompt/completion/total"，如 "1.2k/3.4k/4.6k"。
function fmtUsage(u) {
	if (!u) return '';
	let fmt = function(n) {
		// 注意用 /1000.0 而不是 /1000：ucode 里两个整数相除是整除（10/3=3），
		// 1.2M 会被截成 1M。除一个浮点字面量才能得到真正的浮点商。
		if (n >= 1000000) return sprintf('%.1fM', n / 1000000.0);
		if (n >= 1000) return sprintf('%.1fk', n / 1000.0);
		return sprintf('%d', n);
	};
	return fmt(u.prompt) + '/' + fmt(u.completion) + '/' + fmt(u.total);
}

// 按前缀查找已启用的自定义上游
function findUpstreamByPrefix(prefix) {
	let list = loadUpstreams();
	for (let u in list) {
		if (u.enabled && u.prefix === prefix) return u;
	}
	return null;
}

// 单引号 shell 转义：' -> '\''
// 本版本 ucode 的 popen() 不支持数组参数形式（数组会返回 null + "Invalid argument"），
// 只能传命令字符串，因此所有外部数据必须经过本函数转义后再拼入命令行。
// 必须定义在这里（任何调用点之前）：ucode 函数不提升（踩坑记录 #12）。
function shquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// 拉取某个自定义上游的模型列表。
// 返回 [{ id }]；失败返回空数组（不让一个挂掉的上游拖垮整个 /v1/models）。
function fetchUpstreamModels(up) {
	let keys = usableUpKeys(up);
	if (length(keys) === 0) return [];

	let key = keys[0];
	let cmd = join(' ', [
		'curl', '-sS', '-m', '12', '-4',
		'-H', shquote('Authorization: Bearer ' + key),
		shquote(up.baseUrl + '/models'),
	]);

	let body = '';
	try {
		let p = popen(cmd, 'r');
		if (p) body = p.read('all') || '';
	} catch (e) {
		markUpKeyFail(up, key, 'models fetch failed: ' + e);
		return [];
	}

	let j = null;
	try { j = json(body); } catch (e) { j = null; }
	if (!j || type(j.data) !== 'array') {
		// 401/403 说明 Key 有问题；其它情况（限流/网络）也给冷却
		let why = 'models returned non-list';
		if (index(body, 'Authorization') >= 0 || index(body, 'invalid') >= 0)
			why = 'models auth failed';
		markUpKeyFail(up, key, why);
		return [];
	}

	markUpKeyOk(up, key);

	let out = [];
	for (let m in j.data) {
		if (type(m) !== 'object' || m === null) continue;
		let mid = '' + (m.id || '');
		if (length(mid) === 0) continue;
		push(out, { id: mid });
	}
	return out;
}

// 把 "供应商/模型" 切分为 { prefix, model }。
// 无斜杠返回 null（表示走 WorkBuddy 自身上游）。
//
// 注意：这里刻意不用 match()。实测 ucode 的 match() 只接受正则字面量
// /.../，传字符串模式即使能匹配也返回 null（踩坑记录 #10）。
// index+substr 更直观，也没有这个陷阱。
function splitModelRef(model) {
	let m = '' + (model || '');
	let p = index(m, '/');
	if (p <= 0) return null;
	let prefix = lc(substr(m, 0, p));
	let rest = substr(m, p + 1);
	if (length(rest) === 0) return null;
	return { prefix: prefix, model: rest };
}

// v2.0：解析管理页粘贴的 Key 文本。每行一把 Key，支持可选权重：
//   sk-xxx
//   sk-yyyy|3
// 返回 { keys: [...], weights: { key: 权重 } }。权重缺省为 1；重复项去重
// （首个出现的权重优先）。全部为空返回空数组。
function parseKeysText(keysText) {
	let keys = [];
	let weights = {};
	let seen = {};
	// split(subject, separator) —— 顺序不能反，见 addUpstream 的说明
	let lines = split('' + (keysText || ''), '\n');
	for (let ln in lines) {
		let t = trim(ln);
		if (length(t) === 0) continue;
		let key = t;
		let wt = 1;
		let bar = index(t, '|');
		if (bar >= 0) {
			key = trim(substr(t, 0, bar));
			let w = +trim(substr(t, bar + 1));
			if (w >= 1) wt = w;
		}
		if (length(key) === 0) continue;
		if (seen[key]) continue;
		seen[key] = true;
		push(keys, key);
		if (wt !== 1) weights[key] = wt;
	}
	return { keys: keys, weights: weights };
}

// v2.7.0：解析管理页粘贴的「模型映射」文本，用来把上游的真实模型名
// 与对外的模型名解耦（one-api / new-api 的「模型重定向」）。
//
// 每行一条，两种写法：
//   <真实模型名>                 —— 直接暴露（别名=真名）
//   <别名>=<真实模型名>          —— 对外暴露别名，转发时替换回真名
//
// 为什么需要它：上游有时会列出它其实不提供的模型（见 @2317 的注释），
// 或者模型名很长/带不稳定的后缀。客户端只认一个稳定的名字，
// 由这里做映射，换上游/换版本时只改映射，不用改客户端配置。
//
// 返回 { map: {别名: 真名}, list: [对外的模型名...] }。
// map 只在「别名 != 真名」时登记，这样纯粹的模型清单不占额外空间。
function parseModelMap(text) {
	let map = {};
	let list = [];
	let seen = {};
	let lines = split('' + (text || ''), '\n');
	for (let ln in lines) {
		let t = trim(ln);
		if (length(t) === 0) continue;
		// 支持 `#` 开头的注释行，方便在管理页里写说明
		if (substr(t, 0, 1) === '#') continue;
		let alias = t;
		let real = t;
		let eq = index(t, '=');
		// eq === 0 表示以 `=` 开头（没有别名），是笔误，整行丢弃 ——
		// 否则会把 "=onlyreal" 当成一个叫这个名字的模型暴露出去。
		if (eq === 0) continue;
		if (eq > 0) {
			alias = trim(substr(t, 0, eq));
			real = trim(substr(t, eq + 1));
		}
		if (length(alias) === 0 || length(real) === 0) continue;
		if (seen[alias]) continue;
		seen[alias] = true;
		push(list, alias);
		if (alias !== real) map[alias] = real;
	}
	return { map: map, list: list };
}

// 把对外的模型名翻译成上游认得的真名。没有映射表或查不到时原样返回
// —— 上游直连的裸名必须继续可用（否则用户升级后旧客户端全挂）。
function mapUpstreamModel(up, model) {
	if (up === null || type(up) !== 'object') return model;
	let mm = up.modelMap;
	if (type(mm) !== 'object' || mm === null) return model;
	let hit = mm['' + model];
	if (type(hit) === 'string' && length(hit) > 0) return hit;
	return model;
}

function addUpstream(name, prefix, baseUrl, keysText, modelsText) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') j = { upstreams: [] };

	let nm = trim('' + (name || ''));
	let pf = normalizePrefix(prefix);
	let url = normalizeBaseUrl(baseUrl);

	if (pf === null) return { ok: false, error: '前缀非法：只能用小写字母/数字/-/_，长度 2-32' };
	if (url === null) return { ok: false, error: 'API 地址非法：必须是 http(s):// 开头，且不允许指向内网/本机地址（allow_private_upstream=0）' };

	// 前缀不能与已有上游重复，否则路由会有歧义
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && lc('' + (u.prefix || '')) === pf)
			return { ok: false, error: '前缀「' + pf + '」已被占用' };
	}

	// v2.0：Key 按行拆分，支持 `sk-xxx|权重` 格式（见 parseKeysText）。
	let parsed = parseKeysText(keysText);
	let keys = parsed.keys;
	if (length(keys) === 0) return { ok: false, error: '至少需要一条 Key' };

	let base = 'u' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let u in j.upstreams) if (type(u) === 'object' && u !== null) taken['' + (u.id || '')] = true;
	while (taken[id]) { id = base + '-' + n; n++; }

	let entry = {
		id: id,
		name: (length(nm) > 0 ? nm : pf),
		prefix: pf,
		baseUrl: url,
		keys: keys,
		enabled: true,
		createdAt: time(),
	};
	// 权重非默认（存在 >1 的项）时才写入文件，保持旧文件格式不变。
	if (length(parsed.weights) > 0) entry.weights = parsed.weights;
	// v2.7.0：可选的模型映射（见 parseModelMap）。全空时不写字段，
	// 这样"没配映射"和"配了空映射"在文件里是同一种形态。
	if (modelsText != null) {
		let pm = parseModelMap('' + modelsText);
		if (length(pm.list) > 0) {
			entry.modelList = pm.list;
			if (length(keys(pm.map)) > 0) entry.modelMap = pm.map;
		}
	}
	push(j.upstreams, entry);
	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	logInfo(sprintf('upstream added: %s -> %s (%d keys)', pf, url, length(keys)));
	return { ok: true, upstream: entry };
}

function deleteUpstream(id) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return false;
	let out = [];
	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			hit = true;
			continue;
		}
		push(out, u);
	}
	if (!hit) return false;
	j.upstreams = out;
	// 顺手清掉该上游的内存态，避免删除后残留冷却记录。
	// 说明：这里用"重建表"而不是逐个 delete，是风格选择不是语言限制。
	// v2.9.4 在路由器上实测（/tmp/deltest.uc、/tmp/deltest2.uc）：本版本 ucode
	// 的 `delete o.b` / `delete o[k]` / `delete nested.m.q` 全部可用，删不存在的
	// 键返回 false 且不报错。旧注释断言"ucode 不支持 delete"是错误结论，已纠正。
	// 真正踩过的坑是另一种形态：对**非对象**（数组或字符串）取下标做 delete。
	let keep = {};
	let pfx = '' + id + '|';
	for (let k in upState) {
		if (substr(k, 0, length(pfx)) !== pfx) keep[k] = upState[k];
	}
	upState = keep;
	return saveUpstreamsFile(j);
}

function toggleUpstream(id, enabled) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return false;
	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			u.enabled = enabled ? true : false;
			hit = true;
		}
	}
	if (!hit) return false;
	return saveUpstreamsFile(j);
}

// 编辑某个上游的基本信息（名称 / 前缀 / 地址 / 启停）。
//
// 为什么单独开一个接口而不是复用 add：
//   add 的语义是"新建"，Key 是必填的；而用户想改的往往只是地址写错了、
//   或者名字想换个好认的，此时逼他重新粘贴一遍全部 Key 既危险（容易粘错
//   覆盖掉正常的 Key）也没有必要。主流中转（one-api/new-api/gpt-load）
//   都允许单独编辑渠道信息，这里是补齐这个缺口。
//
// 改 prefix 的连带影响：客户端里已写好的 "旧前缀/模型" 会立刻失效
// （findUpstreamByPrefix 找不到）。所以这里在返回值里回传 oldPrefix，
// 前端据此提示用户改客户端配置。
function editUpstream(id, name, prefix, baseUrl, enabled, modelsText) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return { ok: false, error: '无上游配置' };

	let np = normalizePrefix(prefix);
	if (np === null) return { ok: false, error: '前缀无效（2-32 位小写字母、数字、- 或 _）' };

	let nu = normalizeBaseUrl(baseUrl);
	if (nu === null) return { ok: false, error: '地址无效（需 http(s):// 且不能指向内网）' };

	// 前缀不能和别的上游撞车，否则 splitModelRef 路由会二义。
	for (let u in j.upstreams) {
		if (type(u) !== 'object' || u === null) continue;
		if (('' + (u.id || '')) === ('' + id)) continue;
		if (('' + (u.prefix || '')) === np)
			return { ok: false, error: '前缀已被「' + (u.name || u.id) + '」占用' };
	}

	let hit = null;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) hit = u;
	}
	if (hit === null) return { ok: false, error: '上游不存在' };

	let oldPrefix = '' + (hit.prefix || '');
	hit.prefix = np;
	hit.baseUrl = nu;
	// 名称允许留空：留空时回落到 prefix，避免管理页出现一片空白卡片。
	hit.name = (type(name) === 'string' && length(trim(name)) > 0) ? trim(name) : np;
	// ucode 没有全局 undefined（裸写会抛 ReferenceError），判空用 != null。
	if (enabled != null) hit.enabled = enabled ? true : false;

	// v2.7.0：模型映射。modelsText 为 null 表示"本次不改"，空串表示"清空映射"。
	// 这个区分很重要：管理页的其它字段（如只改名称）不该顺手把映射抹掉。
	if (modelsText != null) {
		let pm = parseModelMap('' + modelsText);
		// 全空 ⇒ 删除字段（而不是留一个空表），保持旧文件格式干净。
		if (length(pm.list) === 0) {
			hit.modelList = null;
			hit.modelMap = null;
		} else {
			hit.modelList = pm.list;
			hit.modelMap = (length(keys(pm.map)) > 0) ? pm.map : null;
		}
	}

	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	return { ok: true, id: '' + id, prefix: np, oldPrefix: oldPrefix,
		prefixChanged: (oldPrefix !== np), name: hit.name,
		modelCount: (type(hit.modelList) === 'array') ? length(hit.modelList) : 0 };
}

// 替换某个上游的 Key 组（管理页"编辑 Key"用）
function setUpstreamKeys(id, keysText) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return { ok: false, error: '无上游配置' };

	// v2.0：支持 `sk-xxx|权重` 格式（见 parseKeysText）。
	let parsed = parseKeysText(keysText);
	let keys = parsed.keys;
	if (length(keys) === 0) return { ok: false, error: '至少需要一条 Key' };

	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			u.keys = keys;
			// 权重随新文本整体替换：没写权重的 Key 一律回到 1。
			u.weights = length(parsed.weights) > 0 ? parsed.weights : {};
			hit = true;
		}
	}
	if (!hit) return { ok: false, error: '上游不存在' };
	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	return { ok: true, count: length(keys) };
}

// v2.5.0：单 Key 启用/停用。
//
// 传进来的 keyRef 是掩码后的 Key（管理页只拿得到 maskKey(k)，拿不到明文）。
// 因此这里必须用 maskKey 反查真实 Key —— 绝不能把掩码当成真 Key 存进去。
// 主流中转（one-api/new-api/gpt-load）都有这个开关：某把 Key 欠费/被封时，
// 用户想立刻把它摘出去，而不是等它自己冷却到超时。
function toggleUpstreamKey(id, masked, on) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return { ok: false, error: '无上游配置' };

	let hit = null;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) hit = u;
	}
	if (hit === null) return { ok: false, error: '上游不存在' };

	// 掩码 -> 明文。找不到说明管理页数据过期，明确报错而不是静默写坏配置。
	let real = null;
	for (let k in hit.keys)
		if (maskKey(k) === ('' + masked)) { real = k; break; }
	if (real === null) return { ok: false, error: 'Key 不存在（页面数据可能已过期，请刷新）' };

	if (type(hit.disabled) !== 'object' || hit.disabled === null) hit.disabled = {};
	if (on) {
		// 重建表移除这一项（ucode 有 delete 运算符，但重建对本表更直白且无需判存在）。
		let nd = {};
		for (let k in hit.disabled)
			if (k !== real) nd[k] = hit.disabled[k];
		hit.disabled = nd;
	} else {
		hit.disabled[real] = true;
		// 停用即清掉它的失败状态：否则重新启用时它还带着旧的 fails/冷却，
		// 表现成"刚启用就又被跳过了"。
		let sk = hit.id + '|' + real;
		if (upState[sk]) upState[sk] = { fails: 0, coolUntil: 0, lastErr: '' };
	}

	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	return { ok: true, enabled: on ? true : false };
}

// v2.5.0：单 Key 权重编辑（权重 ≥1 的整数）。
// 与 setUpstreamKeys 的"整批覆盖"不同，这里只动一把 Key 的权重，
// 不会碰其它 Key —— 用户调参时最怕的就是手滑把别的 Key 弄丢。
function setUpstreamKeyWeight(id, masked, weight) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return { ok: false, error: '无上游配置' };

	let w = +weight;
	if (!(w >= 1) || w !== int(w) || w > 1000)
		return { ok: false, error: '权重需为 1-1000 的整数' };

	let hit = null;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) hit = u;
	}
	if (hit === null) return { ok: false, error: '上游不存在' };

	let real = null;
	for (let k in hit.keys)
		if (maskKey(k) === ('' + masked)) { real = k; break; }
	if (real === null) return { ok: false, error: 'Key 不存在（页面数据可能已过期，请刷新）' };

	if (type(hit.weights) !== 'object' || hit.weights === null) hit.weights = {};
	hit.weights[real] = w;

	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	return { ok: true, weight: w };
}

// 上游状态汇总（给管理页用，不含 Key 明文）
function upstreamStatus() {
	let list = loadUpstreams();
	let now = time();
	let out = [];
	for (let u in list) {
		let keys = [];
		let usable = 0;
		let upUsage = metrics.usageByUp[u.id] || { prompt: 0, completion: 0, total: 0 };
		for (let k in u.keys) {
			let st = upState[u.id + '|' + k];
			let cool = (st && st.coolUntil > now) ? (st.coolUntil - now) : 0;
			let off = (u.disabled && u.disabled[k]) ? true : false;
			if (cool === 0 && !off) usable++;
			let keyUsage = metrics.usageByKey[u.id + '|' + maskKey(k)] || { prompt: 0, completion: 0, total: 0 };
			push(keys, {
				masked: maskKey(k),
				weight: (u.weights && +u.weights[k] >= 1) ? +u.weights[k] : 1,
				disabled: off,
				cooling: cool,
				fails: st ? (st.fails || 0) : 0,
				lastErr: st ? (st.lastErr || '') : '',
				usage: keyUsage,
				usageText: fmtUsage(keyUsage),
			});
		}
		// v2.7.0：把模型映射回送给管理页，供「编辑服务器」弹窗回显。
		// 用 `别名=真名`（有映射）/ 裸名（无映射）两种写法的原始文本，
		// 这样"打开弹窗再原样保存"不会丢信息。
		let ml = (type(u.modelList) === 'array') ? u.modelList : [];
		let mmt = [];
		for (let mid in ml) {
			let real = null;
			if (type(u.modelMap) === 'object' && u.modelMap !== null) real = u.modelMap[mid];
			push(mmt, (real !== null && real !== mid) ? (mid + '=' + real) : ('' + mid));
		}
		// v2.9.4（用户 m17405）：把**上游真实提供的模型**也回送，管理页要显示
		// "这台服务器到底能填哪些名字"。只读内存/磁盘缓存，绝不在状态接口里
		// 外呼上游 —— 这是每 5 秒刷一次的轮询，外呼会把状态页变成 DoS 发起者。
		let detected = [];
			let ck = u.prefix + '|' + u.baseUrl + '|' + length(u.keys);
			let ce = upModelCache[ck];
			if (ce && type(ce.list) === 'array') {
				let dseen = {};
				for (let m in ce.list) {
					let mid = (type(m) === 'object' && m !== null) ? ('' + (m.id || '')) : ('' + m);
					if (length(mid) === 0 || dseen[mid]) continue;
					dseen[mid] = true;
					push(detected, mid);
				}
			}
		push(out, {
			id: u.id,
			name: u.name,
			prefix: u.prefix,
			baseUrl: u.baseUrl,
			enabled: u.enabled,
			keyCount: length(u.keys),
			keyUsable: usable,
			keys: keys,
			usage: upUsage,
			usageText: fmtUsage(upUsage),
			modelCount: length(ml),
			modelsText: join('\n', mmt),
			detectedModels: detected,
		});
	}
	return out;
}

// ---------- v2.8.0：模型可用性测试与每日刷新 ----------

// 每日巡检定时器的句柄与"上次已跑过的日期"（用 yyyymmdd 数字比较）。
// 必须声明在函数之前：ucode 不提升声明（踩坑记录 #12）。
let modelRefreshTimer = null;
let modelRefreshLastDay = -1;

// 为什么测试直连上游而不是走本机代理：走 handleChat 会占用并发闸门（up_max_inflight）
// 和排队槽位，一次「测试全部模型」可能把在途额度吃光、把真实用户请求挤进排队。
// 测试请求本身极小（max_tokens:1），直连最省事也最不打扰生产链路。

// 对某个上游的单个模型发一个极小的 chat 请求，验证它真的可用。
// 直接调上游的 /chat/completions（stream:false、max_tokens:1），比只拉 /models
// 更接近真实使用路径：能过鉴权、能完成一次推理才算"可用"。
// 返回 { model, ok, error }。
function testUpstreamModel(up, modelName) {
	let keys = usableUpKeys(up);
	if (length(keys) === 0)
		return { model: modelName, ok: false, error: '无可用 Key（全部冷却/停用）' };

	// 对外名 -> 上游真名（模型映射在真实转发里同样生效，测试要走同一路径）
	let real = mapUpstreamModel(up, modelName);
	let key = keys[0];
	let reqBody = {
		model: real,
		messages: [{ role: 'user', content: 'ping' }],
		max_tokens: 1,
		stream: false,
	};
	let bodyJson = sprintf('%.J', reqBody);
	let cmd = join(' ', [
		'curl', '-sS', '-m', '' + MODEL_TEST_TIMEOUT, '-4',
		'-X', 'POST',
		'-H', shquote('Authorization: Bearer ' + key),
		'-H', shquote('Content-Type: application/json'),
		shquote(up.baseUrl + '/chat/completions'),
		'--data-binary', shquote(bodyJson),
	]);

	let raw = '';
	try {
		let p = popen(cmd, 'r');
		if (p) raw = p.read('all') || '';
	} catch (e) {
		return { model: modelName, ok: false, error: '请求异常: ' + e };
	}

	let j = null;
	try { j = json(raw); } catch (e) { j = null; }
	if (j && type(j.choices) === 'array' && length(j.choices) > 0)
		return { model: modelName, ok: true };

	// 提取错误信息（JSON error / HTTP 状态 / 原始片段），尽量给用户可读的原因
	let err = '';
	if (j && j.error) {
		if (type(j.error) === 'object' && j.error !== null)
			err = '' + (j.error.message || j.error.code || '');
		else
			err = '' + j.error;
	}
	if (length(err) === 0) {
		let head = substr(trim(raw), 0, 160);
		err = length(head) > 0 ? head : '空响应/超时';
	}
	return { model: modelName, ok: false, error: err };
}

// 遍历所有启用上游，对每个模型发最小
// 请求验证可用性。模型来源优先级：自定义清单 > 最后已知列表 > 现场拉取。
// 每上游最多 MODEL_TEST_MAX_PER_UP 个模型，去重后测试。
// 返回 { ok, total, okCount, failCount, results:[{model,ok,error}] }。
function testAllUpstreamModels() {
	let ups = loadUpstreams();
	let results = [];
	let okCount = 0;
	let failCount = 0;
	for (let u in ups) {
		if (!u.enabled) continue;

		// 决定要测哪些模型
		let models = [];
		let seen = {};
		if (type(u.modelList) === 'array' && length(u.modelList) > 0) {
			// 有自定义清单：以清单为准（测试对外的名字，映射在函数里做）
			for (let mid in u.modelList) {
				if (seen[mid]) continue;
				seen[mid] = true;
				push(models, mid);
			}
		} else {
			let ck = u.prefix + '|' + u.baseUrl + '|' + length(u.keys);
			let ce = upModelCache[ck];
			if (ce && type(ce.list) === 'array') {
				for (let m in ce.list) {
					if (seen[m.id]) continue;
					seen[m.id] = true;
					push(models, m.id);
				}
			}
			if (length(models) === 0) {
				let remote = fetchUpstreamModels(u);
				for (let m in remote) {
					if (seen[m.id]) continue;
					seen[m.id] = true;
					push(models, m.id);
				}
			}
		}

		// 每上游上限，防止模型列表爆炸时测试请求打爆上游
		let tested = [];
		for (let m in models) {
			push(tested, m);
			if (length(tested) >= MODEL_TEST_MAX_PER_UP) break;
		}

		for (let m in tested) {
			let r = testUpstreamModel(u, m);
			if (r.ok) okCount++;
			else failCount++;
			push(results, r);
		}
	}
	return {
		ok: failCount === 0,
		total: okCount + failCount,
		okCount: okCount,
		failCount: failCount,
		results: results,
	};
}

// 每日模型巡检：每 MODEL_REFRESH_CHECK_MS 自重排，检查是否到了
// cfg.modelRefreshHour（默认凌晨 1 点）且今天还没跑过；到了就：
//   1) 强制刷新所有启用上游的模型列表（拉取成功写缓存 + 落盘）；
//   2) 跑一遍全模型连通性测试，把失败记入日志。
// 重排必须发生在业务逻辑之前（无论是否到点都先排下一次）。
function modelRefreshTick() {
	modelRefreshTimer = uloop.timer(MODEL_REFRESH_CHECK_MS, () => modelRefreshTick());
	if (!cfg.modelRefreshEnabled) return;

	let lt = localtime(time());
	let today = lt.year * 10000 + (lt.mon + 1) * 100 + lt.day;
	if (lt.hour !== cfg.modelRefreshHour || modelRefreshLastDay === today) return;
	modelRefreshLastDay = today;

	logInfo(sprintf('model refresh: daily %02d:00 run started', cfg.modelRefreshHour));

	// 1) 强制刷新模型列表
	let ups = loadUpstreams();
	for (let u in ups) {
		if (!u.enabled) continue;
		let ck = u.prefix + '|' + u.baseUrl + '|' + length(u.keys);
		let remote = fetchUpstreamModels(u);
		if (length(remote) > 0) {
			upModelCache[ck] = { at: time(), list: remote };
			saveModelCache();
			logInfo(sprintf('model refresh: %s -> %d models', u.prefix, length(remote)));
		} else {
			logErr('model refresh: ' + u.prefix + ' returned empty model list');
		}
	}

	// 2) 全模型连通性巡检
	let t = testAllUpstreamModels();
	logInfo(sprintf('model refresh: test-all done: %d/%d ok, %d failed',
		t.okCount, t.total, t.failCount));
	for (let r in t.results) {
		if (!r.ok) logErr('model refresh: ' + r.model + ' FAIL: ' + r.error);
	}
}

// ---------- 公网访问（WAN 防火墙规则） ----------
//
// 默认关闭。打开时由本模块**自动**在 UCI firewall 里建/改一条 redirect，
// 把 WAN 的端口转到本机监听的端口；关闭时把这条规则删掉。
//
// 为什么用 UCI 而不是直接写 nft：
//   1. fw4 会在 reload 时重建整张 nftables 表，手写的 nft 规则会被冲掉；
//      写进 UCI 才能被 fw4 持久地重新生成。
//   2. 规则对用户可见、可审计 —— 在「网络 → 防火墙 → 端口转发」里能看到，
//      用户想手动关掉也有地方关。
//   3. reload 由 fw4 自己保证原子性，比我们插规则安全。
//
// 安全设计：
//   - 必须已设置管理密码才允许开启。没密码就开放公网 = 任何人可登录。
//   - 规则名固定 workbuddy_wan，关闭时整节删除，不留残影。
const FW_SECTION = 'workbuddy_wan';

// 执行一条 shell 命令，返回 { code, out }。
// 注意不能用 runCurl —— 那个是 curl 专用封装（签名是 (cfg, args)）。
// 这里要的是通用 shell，所以直接用 popen，并用 `; echo RC=$?` 取回退出码，
// 因为 popen 只给 stdout，拿不到 exit status。
function shRun(cmd) {
	let buf = '';
	try {
		let proc = popen('{ ' + cmd + ' ; } 2>&1; echo "RC=$?"', 'r');
		if (!proc) return { code: -1, out: '' };
		let chunk;
		while ((chunk = proc.read(16384)) !== null && length(chunk) > 0)
			buf += chunk;
		proc.close();
	} catch (e) {
		return { code: -1, out: '' + e };
	}
	let code = -1;
	let m = match(buf, /RC=(-?[0-9]+)\s*$/);
	if (m) {
		code = +m[1];
		buf = replace(buf, /\s*RC=-?[0-9]+\s*$/, '');
	}
	return { code: code, out: trim(buf) };
}

function fwRedirectExists() {
	let r = shRun('uci -q get firewall.' + FW_SECTION + '.target');
	return (index('' + r.out, 'DNAT') >= 0);
}

// 开关的实际落地。返回 { ok, error }
//
// 外部端口（src_dport）与内部端口（dest_port）可以不同：
//   外网 -> WAN:wanPort -> 本机:port
// 这样能把外部端口换成不显眼的端口（如 18789）降低被扫描概率，
// 同时内部监听端口保持不变。
function applyWanAccess(cfg, on) {
	if (on && !cfg.adminPass) {
		return { ok: false, error: '未设置管理密码，拒绝开放公网' };
	}

	let iport = cfg.port || 8789;             // 内部监听端口
	let eport = cfg.wanPort || iport;         // 外部暴露端口

	// dest_ip 必须显式给出。fw4 只为「带 dest_ip 的 DNAT」生成 LAN 侧反射规则
	// （dstnat_lan），只写 src_dport/dest_port 的话内网设备用公网地址访问
	// 会被直接拒绝 —— 家用场景里这很常见（手机连着 WiFi 却填了公网地址）。
	// 有了它，内网和外网用同一个地址都能通，不必维护两套配置。
	//
	// 坑（实测踩过，务必保留这段说明）：uci 的 network.lan.ipaddr 常带前缀长度，
	// 返回的是 "192.168.69.1/24" 而不是 "192.168.69.1"。原样写进 dest_ip 后，
	// fw4 会把 CIDR 透给 nft，nft 取**网络地址**生成
	//   dnat ip to 192.168.69.0:8789
	// —— 192.168.69.0 是网段地址，没有任何主机响应，后果是**外网访问全部失效**
	// （实测：加 dest_ip 后 5 国外部节点从全部 HTTP 200 变成全部不通）。
	// 所以这里必须剥掉 /前缀，并校验是纯点分四段；格式不对就退回旧写法，
	// 宁可没有反射也不能把外网弄坏。
	let lanIp = trim(shRun('uci -q get network.lan.ipaddr').out);
	if (type(lanIp) !== 'string') lanIp = '';
	let slash = index(lanIp, '/');
	if (slash >= 0) lanIp = trim(substr(lanIp, 0, slash));
	if (length(lanIp) === 0 || !match(lanIp, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/)) {
		logInfo('wan: 无法解析 LAN 地址，跳过 dest_ip（仅外网可用，无 LAN 反射）');
		lanIp = '';
	}
	let destIpArg = (lanIp !== '')
		? ('uci set firewall.' + FW_SECTION + '.dest_ip=' + lanIp + ' && ')
		: '';

	let cmd;

	if (on) {
		cmd = 'uci -q delete firewall.' + FW_SECTION + ' >/dev/null 2>&1; ' +
			'uci set firewall.' + FW_SECTION + '=redirect && ' +
			'uci set firewall.' + FW_SECTION + '.name=workbuddy_wan && ' +
			'uci set firewall.' + FW_SECTION + '.target=DNAT && ' +
			'uci set firewall.' + FW_SECTION + '.src=wan && ' +
			'uci set firewall.' + FW_SECTION + '.proto=tcp && ' +
			'uci set firewall.' + FW_SECTION + '.src_dport=' + eport + ' && ' +
			destIpArg +
			'uci set firewall.' + FW_SECTION + '.dest_port=' + iport + ' && ' +
			'uci commit firewall';
	} else {
		cmd = 'uci -q delete firewall.' + FW_SECTION + ' >/dev/null 2>&1; uci commit firewall';
	}

	let rc = shRun(cmd);
	if (rc.code !== 0) {
		return { ok: false, error: '写防火墙配置失败: ' + rc.out };
	}

	let rl = shRun('/etc/init.d/firewall reload >/dev/null 2>&1');
	if (rl.code !== 0) {
		return { ok: false, error: '防火墙 reload 失败' };
	}

	return { ok: true };
}

// 读当前实际生效状态。
// 短路优化：UCI 里没有规则时直接判定未生效，省掉一次 nft 子进程。
// nft 侧按**外部端口**匹配（redirect 规则匹配的是入站 dport），
// 并加 [^0-9] 边界避免 18789 误配到 187890。
function wanAccessStatus(cfg) {
	let uciOn = fwRedirectExists();
	if (!uciOn) {
		return { config: (cfg.wanAccess === true), uci: false, active: false };
	}
	let eport = cfg.wanPort || cfg.port || 8789;
	let r = shRun('nft list ruleset 2>/dev/null | grep -cE "dport ' + eport + '([^0-9]|$)"');
	let nftOn = (r.out !== '' && +r.out > 0);
	return { config: (cfg.wanAccess === true), uci: true, active: nftOn };
}

function hexdec(h) {
	let v = 0;
	for (let i = 0; i < length(h); i++) {
		let c = lc(substr(h, i, 1));
		let d;
		if (c >= '0' && c <= '9') d = ord(c) - 48;
		else if (c >= 'a' && c <= 'f') d = ord(c) - 87;
		else return -1;
		v = v * 16 + d;
	}
	return v;
}

// ucode 没有 decodeURIComponent，这里实现最小可用的百分号解码
function urlDecode(s) {
	if (index(s, '%') < 0 && index(s, '+') < 0) return s;
	let out = '';
	let i = 0;
	let n = length(s);
	while (i < n) {
		let ch = substr(s, i, 1);
		if (ch === '+') {
			out += ' ';
			i++;
			continue;
		}
		if (ch === '%' && i + 2 < n) {
			let hex = substr(s, i + 1, 2);
			let m = match(hex, /^([0-9a-fA-F]{2})$/);
			if (m) {
				out += chr(hexdec(m[1]));
				i += 3;
				continue;
			}
		}
		out += ch;
		i++;
	}
	return out;
}

// 恒定时间比较与 sha256Hex 定义在文件顶部「基础工具函数」区。
// 那里是唯一允许放置这类底层工具的位置：ucode 不提升函数，
// 放在这里会被后面定义的同名函数覆盖，也容易漏改。

// ---------- 哈希与会话 ----------

// 管理页会话签名：把过期时间戳一起签进去，服务端能真正判断过期，
// 而不是只依赖浏览器端的 Max-Age。
function adminToken(cfg) {
	let exp = time() + ADMIN_TTL;
	let sig = substr(sha256Hex(ADMIN_SALT + '|' + cfg.adminPass + '|' + exp), 0, 32);
	return '' + exp + '.' + sig;
}

function adminTokenValid(cfg, tok) {
	if (type(tok) !== 'string' || length(tok) === 0) return false;
	let m = match(tok, /^([0-9]+)\.([0-9a-f]{32})$/);
	if (!m) return false;
	let exp = +m[1];
	if (!exp || exp < time()) return false;
	let want = substr(sha256Hex(ADMIN_SALT + '|' + cfg.adminPass + '|' + exp), 0, 32);
	return secureEq(want, m[2]);
}

function adminEnabled(cfg) {
	return length('' + (cfg.adminPass || '')) > 0;
}

// 解析 Cookie 头为对象
function parseCookies(headers) {
	let out = {};
	let raw = headers['cookie'] || '';
	if (length(raw) === 0) return out;
	for (let part in split(raw, ';')) {
		let p = trim(part);
		let eq = index(p, '=');
		if (eq <= 0) continue;
		out[trim(substr(p, 0, eq))] = trim(substr(p, eq + 1));
	}
	return out;
}

function adminAuthed(cfg, headers) {
	if (!adminEnabled(cfg)) return false;
	return adminTokenValid(cfg, parseCookies(headers)[ADMIN_COOKIE]);
}

// 登录失败限速：同一 IP 连续失败达到上限后锁定一段时间
let adminFails = {};

function adminLocked(ip) {
	let st = adminFails[ip];
	if (!st) return 0;
	if (st.until > time()) return st.until - time();
	return 0;
}

function adminNoteFail(ip) {
	let st = adminFails[ip] || { n: 0, until: 0 };
	// 距上次失败超过锁定窗口就重新计数，避免历史失败永久累积
	if (st.until && st.until < time()) st.n = 0;
	st.n++;
	if (st.n >= ADMIN_MAX_FAIL) {
		st.until = time() + ADMIN_LOCK_SEC;
		st.n = 0;
	}
	adminFails[ip] = st;
}

function adminNoteOk(ip) {
	delete adminFails[ip];
}

// ---------- 客户端版本 ----------

let versionCache = null;

function readVersionFile() {
	let j = readJsonFile(VERSION_FILE);
	if (!j || type(j) !== 'object') return null;
	if (type(j.version) !== 'string' || length(j.version) === 0) return null;
	return { version: j.version, at: +j.at || 0, source: '' + (j.source || '') };
}

function saveVersionFile(ver, source) {
	writeJsonFile(VERSION_FILE, { version: ver, at: time(), source: source });
}

// 从任意响应体里提取形如 x.y.z 的版本号
function extractVersion(raw) {
	if (type(raw) !== 'string' || length(raw) === 0) return null;
	let m = match(raw, /([0-9]+\.[0-9]+\.[0-9]+)/);
	if (!m) return null;
	return m[1];
}

// 版本号比较：a > b 返回 1，相等 0，小于 -1
function verCmp(a, b) {
	let pa = split('' + a, '.');
	let pb = split('' + b, '.');
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let x = +((pa[i] !== null && pa[i] !== '') ? pa[i] : 0) || 0;
		let y = +((pb[i] !== null && pb[i] !== '') ? pb[i] : 0) || 0;
		if (x > y) return 1;
		if (x < y) return -1;
	}
	return 0;
}

// 取得当前应使用的客户端版本。
//
// 现实约束（已实测）：WorkBuddy 没有公开的客户端版本清单接口。
//   - /v3/config 里只有插件市场的 versionUrl，与客户端 UA 无关
//   - /v3/version、/api/version 等一律 404
//   - download.codebuddy.cn/version.json 是 CodeBuddy 的清单（4 段式、无 windows-x64）
//   - 上游不校验版本：UA 从 1.0.0 到 9.9.9 都返回 200
// 因此这里做「多源探测 + 自校准」：探测源若将来可用就自动采用；探测不到时
// 沿用自校准记录（上游接受过的最高版本）、配置值，最后才回退内置下限。
function clientVersion(cfg) {
	if (!cfg.autoVersion) return '' + (cfg.client_version || VERSION_FLOOR);

	if (versionCache === null) versionCache = readVersionFile();
	let cached = versionCache;

	// 缓存仍新鲜：直接复用，避免每次请求都外呼
	if (cached && (time() - cached.at) < VERSION_TTL && length(cached.version) > 0)
		return cached.version;

	// 逐个探测源尝试。
	// 注意：runCurl() 声明在文件后面，ucode 不提升函数且按定义时的词法作用域
	// 解析标识符，这里直接调用会报 "access to undeclared variable runCurl"。
	// 因此通过前向引用表 F 调用（与 spawnUpstream 等同一套做法）。
	for (let url in VERSION_SOURCES) {
		let out = F.runCurl(cfg, ['-sS', '-m', '8', '-L', url]);
		if (out === null || length(out) === 0) continue;
		let v = extractVersion(out);
		if (v !== null) {
			versionCache = { version: v, at: time(), source: 'probe' };
			saveVersionFile(v, 'probe');
			logInfo('client version probed: ' + v + ' from ' + url);
			return v;
		}
	}

	// 探测全部失败：沿用已有记录，否则用配置值/下限，并刷新时间戳避免
	// 每个请求都重复外呼（负缓存）。
	let fallback = (cached && length(cached.version) > 0)
		? cached.version
		: ('' + (cfg.client_version || VERSION_FLOOR));
	versionCache = { version: fallback, at: time(), source: 'fallback' };
	saveVersionFile(fallback, 'fallback');
	return fallback;
}

// 记录上游实际接受过的版本，作为自校准结果。
// 只在版本号确实更高时更新，避免把版本号写退回去。
function noteAcceptedVersion(cfg, used) {
	if (!cfg.autoVersion) return;
	let v = '' + (used || cfg.client_version || VERSION_FLOOR);
	if (!versionCache) versionCache = readVersionFile();
	if (!versionCache || verCmp(v, versionCache.version || '0') > 0) {
		versionCache = { version: v, at: time(), source: 'accepted' };
		saveVersionFile(v, 'accepted');
	}
}

// 返回命中的密钥对象，未命中返回 null
function matchApiKey(cfg, headers, query) {
	let keys = loadApiKeys();

	// 提取客户端提交的密钥
	let auth = headers['authorization'] || '';
	let bearer = trim(replace(auth, /^Bearer\s+/i, ''));
	let xkey = trim(headers['x-api-key'] || '');
	let qkey = '';
	if (query) {
		let m = match(query, /(^|&)key=([^&]*)/);
		if (m) qkey = urlDecode(m[2]);
	}

	let supplied = [bearer, xkey, qkey];
	for (let s in supplied) {
		if (length(s) === 0) continue;
		for (let k in keys)
			if (secureEq(s, k.key)) return k;
		// 兼容旧版单一 share_token
		if (cfg.share_token && secureEq(s, cfg.share_token))
			return { id: 'legacy', name: 'share_token' };
	}
	return null;
}

// 是否需要鉴权：配置了任意密钥就强制校验
function authRequired(cfg) {
	return hasApiKeys() || length('' + (cfg.share_token || '')) > 0;
}

// ---------- HTTP 工具 ----------

function httpStatusText(code) {
	let map = {
		'200': 'OK', '302': 'Found', '400': 'Bad Request', '401': 'Unauthorized',
		'404': 'Not Found', '405': 'Method Not Allowed', '429': 'Too Many Requests',
		'500': 'Internal Server Error', '502': 'Bad Gateway',
	};
	return map[code] || 'Unknown';
}

// truthy() 定义在文件顶部基础工具区。

// ---------- 上游响应回环桥实现（v1.8.3） ----------

// 回环桥是否可用：配置开启、nc 存在、监听已建立。
function bridgeUse() {
	return (cfg.bridgePort > 0) && (bridgeListen !== null);
}

// 回环桥：为一次上游请求分配 id 并登记挂起映射（必须在 popen 之前调用，否则
// 子进程可能在登记前就连上并把首行 id 发到 accept，查不到 conn 就被丢弃）。
function bridgeRegister(conn) {
	if (!bridgeUse()) return null;
	bridgeSeq++;
	let id = '' + bridgeSeq;
	bridgePending[id] = conn;
	conn.bridgeId = id;
	return id;
}

// 回环桥：把 curl 命令包成「先打印请求 id 一行，再跑 curl，整段经 nc 回环到本地端口」。
//
// 末尾的 ` &` 是必需的，不是优化：popen() 的直接子进程是那个 sh，而整条
// `{ …; } | nc …` 管道在响应流期间一直活着。若前台运行，任何一次
// proc.close()（= pclose()/waitpid()）都要等整条管道退出才返回 —— 事件循环
// 是单线程的，于是被无限期钉在 do_wait 上，Recv-Q 堆积、/health 无响应、
// 全站瘫痪（v1.8.3 实测）。加了 ` &` 之后 sh 立刻退出，pclose() 收的是已死
// 子进程，实测 2 ms 返回，而数据仍逐字节完整送达（probe15 shape B / probe16）。
// 子进程被 init 收养并在 curl 结束后自然退出；我们关桥 socket 会让 nc 读到
// EOF 而退出，进而 SIGPIPE 掉 curl，不会留下残留。
function bridgeWrap(id, cmdline) {
	return '{ printf "' + id + '\\n"; ' + cmdline + '; } | nc 127.0.0.1 ' + cfg.bridgePort + ' &';
}

// 回环桥：从已接入的连接读一块数据。桥接走 socket（可靠），未桥接走 popen 管道（旧路径）。
function readChunk(conn, n) {
	if (conn.bridgeSock) {
		if (conn.bridgePrebuf && length(conn.bridgePrebuf) > 0) {
			let out = substr(conn.bridgePrebuf, 0, n);
			conn.bridgePrebuf = (length(conn.bridgePrebuf) > n) ? substr(conn.bridgePrebuf, n, length(conn.bridgePrebuf) - n) : '';
			return out;
		}
		return conn.bridgeSock.recv(n);
	}
	return conn.proc.read(n);
}

// 回环桥：释放一次请求持有的桥资源（幂等，可安全重复调用）。
function bridgeRelease(conn) {
	try { if (conn.bridgeHandle) conn.bridgeHandle.cancel(); } catch (e) { }
	conn.bridgeHandle = null;
	try { if (conn.bridgeSock) conn.bridgeSock.close(); } catch (e) { }
	conn.bridgeSock = null;
	if (conn.bridgeId) { bridgePending[conn.bridgeId] = null; conn.bridgeId = null; }
}

// 回环桥：首行握手失败或无用连接，直接丢弃。
// 【顺序】定义必须排在 bridgeReady 之前 —— 本文件不提升函数声明，
// 后向直接调用会抛未声明变量错误，这也是静态检查 FORWARD REF 拦的东西。
function bridgeDrop(b) {
	try { if (b.handle) b.handle.cancel(); } catch (e) { }
	try { b.sock.close(); } catch (e) { }
}

// 回环桥：一条桥连接的全生命周期回调。
//
// 关键设计：**每条桥连接只注册一个 uloop 句柄**，握手与后续转发共用它。
// 不要写成「握手用句柄 A，收到 id 后 cancel A、给同一个 fd 注册句柄 B」——
// 同一 fd 上取消与重新注册落在同一个事件循环轮次里，epoll 侧会出现
// 重复注册/陈旧句柄的竞态（libubox 对同一 fd 的 epoll_ctl(ADD) 会返回 EEXIST），
// 严重时陈旧句柄会再触发一次握手，把真实数据的首行当成 id 吃掉。
// 句柄只在两处消失：bridgeRelease()（请求收尾）与 bridgeDrop()（握手失败）。
function bridgeReady(b) {
	// 已完成握手：此后本连接就是该请求的响应流
	if (b.conn) { b.conn.chunkFn(b.conn); return; }

	let chunk;
	try { chunk = b.sock.recv(512); } catch (e) { chunk = null; }
	if (chunk === null || length(chunk) === 0) { bridgeDrop(b); return; }
	b.buf += chunk;
	let nl = index(b.buf, '\n');
	if (nl < 0) {
		// 首行 id 很短；超过 256 字节还没换行说明对面不是本服务的子进程
		if (length(b.buf) > 256) bridgeDrop(b);
		return;
	}
	let id = trim(substr(b.buf, 0, nl));
	let rest = substr(b.buf, nl + 1);
	let conn = bridgePending[id] || null;
	if (!conn || conn.closed || !conn.chunkFn) { bridgeDrop(b); return; }
	bridgePending[id] = null;

	// 交棒：句柄所有权由 b 转给 conn，之后不再 cancel/重注册
	b.conn = conn;
	conn.bridgeSock = b.sock;
	conn.bridgeHandle = b.handle;

	// 首行之后的同包残余字节不能丢（curl 的响应常常和 id 行挤在同一个报文里），
	// 先塞进预读缓冲，再立刻手动触发一次块处理。
	if (length(rest) > 0) {
		conn.bridgePrebuf = rest;
		conn.chunkFn(conn);
	}
}

// 回环桥：accept 循环入口。每个新连接先做「首行 id」握手（见 bridgeReady）。
function bridgeAccept() {
	let addr = {};
	let peer = bridgeListen.accept(addr, socket.SOCK_CLOEXEC);
	if (!peer) return;
	try { peer.setopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true); } catch (e) { }
	let b = { sock: peer, buf: '', conn: null, handle: null };
	b.handle = uloop.handle(peer, () => bridgeReady(b), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// 回环桥：启动本地监听。nc 缺失或监听失败时回退到直接 popen 读取。
function bridgeStart() {
	if (!(cfg.bridgePort > 0)) return;
	if (!access(NC_PATH, 'x')) {
		logErr('bridge: nc not found at ' + NC_PATH + ', falling back to direct popen reads');
		cfg.bridgePort = 0;
		return;
	}
	let s = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
	try { s.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); } catch (e) { }
	if (!s.bind('127.0.0.1:' + cfg.bridgePort) || !s.listen(64)) {
		logErr('bridge: listen failed on 127.0.0.1:' + cfg.bridgePort + ', falling back to direct popen reads');
		cfg.bridgePort = 0;
		try { s.close(); } catch (e) { }
		return;
	}
	bridgeListen = s;
	uloop.handle(s, () => bridgeAccept(), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
	logInfo('upstream bridge listening on 127.0.0.1:' + cfg.bridgePort);
}

// v2.1.0：流式截断检测。已向客户端推流但流未以 [DONE] 正常结束（看门狗 abort、
// 换 Key 中断、上游缺失终止符等）时，补发一个 event:error 帧并计数 truncated，
// 让客户端知道流不完整，而不是把半截流当成完整回答。
// 注意 [DONE] 并非所有 SSE 上游的规范保证 —— 主上游 sensenova（OpenAI 兼容）
// 会发送；若接入不发 [DONE] 的上游，此计数会偏高但仅补发 error 事件，不影响语义。
function notifyTruncation(conn) {
	if (!conn || conn.closed) return;
	if (!conn.headersSent || conn.wantNonStream) return;
	if (conn.sawDone) return;
	// v2.4.0 修正：客户端中途断开（读侧 EOF / 写失败）已由 recordConnMetrics 记入 abort 桶，
	// 这里必须直接返回，不能计入 truncated。原实现把自增放在 writeBroken 早退**之前**，
	// 于是一次"用户点停止"会同时进 abort 和 truncated（实测 A/B：客户端 curl -m 2 掐断后
	// chat.aborted 与 chat.truncated 各 +1，而 relay 侧正确记 abort、trunc=0）。
	// truncated 的含义是"代理或上游把流截断了"，被客户端取消污染后就失去告警价值。
	// 看门狗中途 abort（watchdogTick 走 closeConn，不置 aborted）属于真截断，仍会计数。
	if (conn.aborted || conn.writeBroken) return;   // 写侧已坏，补发也无意义
	metrics.truncated++;
	try {
		conn.sock.send('event: error\r\n' +
			'data: {"error":{"message":"stream ended without [DONE]","type":"stream_truncated"}}\r\n\r\n');
	} catch (e) { }
}

function closeConn(conn) {
	if (conn.closed) return;
	notifyTruncation(conn);
	conn.closed = true;
	try {
		if (conn.handle) conn.handle.cancel();
	} catch (e) { }
	try {
		if (conn.procHandle) conn.procHandle.cancel();
	} catch (e) { }
	try {
		if (conn.proc) conn.proc.close();
	} catch (e) { }
	bridgeRelease(conn);
	try {
		if (conn.tmpFile) unlink(conn.tmpFile);
	} catch (e) { }
	// v2.1.0：清理 curl -D 落盘的上游响应头文件。
	try {
		if (conn.hdrFile) unlink(conn.hdrFile);
	} catch (e) { }

	// 从在途连接表摘除并释放缓冲。
	//
	// 实测问题：connections 原来只 push 不摘除（全文仅两处引用、从不读取），
	// 每个连接持有的请求体字符串与 SSE 累积缓冲因此永久驻留 —— 转发服务长跑
	// 就是无上界的内存泄漏。看门狗也要靠这张表扫描，必须只含活动连接。
	let keep = [];
	for (let c in connections)
		if (c !== conn) push(keep, c);
	connections = keep;
	conn.buf = '';
	conn.sseBuf = '';

	try {
		conn.sock.close();
	} catch (e) { }

	// 收尾统计 + 释放并发额度。必须是本函数最后一步。
	//
	// 顺序理由：pumpQueue 会立刻发起新请求并把新连接 push 进 connections，
	// 若放在上面那段 `connections = keep` 之前，新连接会被随后重建的数组丢掉，
	// 看门狗从此扫不到它 —— 静默看门狗失效，SSE 会一直挂着。
	//
	// releaseGate 走 F 表：它定义在本函数之后，ucode 标识符按词法作用域解析，
	// 直接调用会抛 undeclared variable（踩坑记录 #12）。
	recordConnMetrics(conn);
	try {
		if (conn.gateHeld) F.releaseGate(conn);
	} catch (e) {
		logErr('releaseGate failed: ' + e);
	}
}

// v2.1.0：带写侧检查的 send。ucode 的 Socket.send() 返回实际写入的字节数且总带
// MSG_NOSIGNAL —— 客户端慢/断开会表现为短写（返回 n < length）而不是抛异常。
// 所有面向客户端的写都必须经过这里：短写/异常即判定连接已不可用，记一次
// sendFail 并返回 false（调用方负责 closeConn）。
// 必须定义在 jsonResponse/rawResponse/sseHeaders/makeOnChunk 之前（ucode 不提升）。
function safeSend(conn, data) {
	if (conn.closed) return false;
	try {
		let n = conn.sock.send(data);
		if (n === null || n !== length(data)) {
			metrics.sendFail++;
			conn.writeBroken = true;
			return false;
		}
		return true;
	} catch (e) {
		metrics.sendFail++;
		conn.writeBroken = true;
		return false;
	}
}

// v2.1.0：读取 curl -D 落盘的上游响应头文件，解析状态码与 Retry-After。
// 返回 { status, retryAfter }（retryAfter 为秒数，无则为 0），文件不存在/不可读返回 null。
// 池化路径同样有效：Go 池会原样透传上游状态码与全部非 hop 响应头（pool/main.go:405-413）。
function readUpstreamStatus(conn) {
	if (!conn || !conn.hdrFile) return null;
	let raw = '';
	try { raw = readfile(conn.hdrFile) || ''; } catch (e) { return null; }
	if (length(raw) === 0) return null;
	let status = 0;
	let retryAfter = 0;
	// 头文件第一行形如 "HTTP/1.1 429 Too Many Requests\r\n..."
	let m = match(raw, /HTTP\/1\.[01] ([0-9]{3})/);
	if (m) status = +m[1];
	let ra = match(raw, /Retry-After:\s*([0-9]+)/i);
	if (ra) retryAfter = +ra[1];
	if (status === 0) return null;
	return { status: status, retryAfter: retryAfter };
}

function jsonResponse(conn, status, obj, extraHeaders) {
	if (conn.closed) return;
	conn.httpStatus = status;   // 供 /metrics 判定结局，见 recordConnMetrics()
	let body = sprintf('%.J', obj);
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	// v2.1.0：回显请求级关联 ID，让客户端能按同一 ID 对账日志与响应。
	let rid = conn.reqId ? ('X-Request-Id: ' + conn.reqId + '\r\n') : '';
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: application/json\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'Access-Control-Allow-Headers: *\r\n' +
		'%s%s' +
		'\r\n',
		status, httpStatusText(status), length(body), rid, extra
	);
	if (!safeSend(conn, head + body)) conn.aborted = true;
	closeConn(conn);
}

// 通用响应：可自定义 content-type 与附加响应头
// 注意：必须定义在 textResponse() 之前 —— ucode 不提升函数，
// 顺序颠倒会在运行时抛 "access to undeclared variable rawResponse"。
function rawResponse(conn, status, ctype, body, extraHeaders) {
	if (conn.closed) return;
	conn.httpStatus = status;   // 供 /metrics 判定结局
	body = '' + (body || '');
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	// v2.1.0：回显请求级关联 ID。
	let rid = conn.reqId ? ('X-Request-Id: ' + conn.reqId + '\r\n') : '';
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: %s\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Cache-Control: no-store\r\n' +
		'X-Content-Type-Options: nosniff\r\n' +
		'%s%s' +
		'\r\n',
		status, httpStatusText(status), ctype, length(body), rid, extra
	);
	if (!safeSend(conn, head + body)) conn.aborted = true;
	closeConn(conn);
}

// 发送 HTML 响应（管理页用）
function textResponse(conn, status, title, body) {
	rawResponse(conn, status, 'text/html; charset=utf-8', body, null);
}

function sseHeaders(conn) {
	if (conn.closed || conn.headersSent) return;
	conn.httpStatus = 200;      // 已经开始推流即视为成功，见 recordConnMetrics()
	// v2.1.0：回显请求级关联 ID。
	let rid = conn.reqId ? ('X-Request-Id: ' + conn.reqId + '\r\n') : '';
	let head =
		'HTTP/1.1 200 OK\r\n' +
		'Content-Type: text/event-stream\r\n' +
		'Cache-Control: no-cache\r\n' +
		// v2.0：显式告知中间反代不要缓冲 SSE（nginx 默认 proxy_buffering on
		// 会把事件流攒成批再发；X-Accel-Buffering: no 是 nginx 的原生开关）。
		'X-Accel-Buffering: no\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		rid +
		'\r\n';
	if (!safeSend(conn, head)) {
		conn.aborted = true;
		closeConn(conn);
		return;
	}
	conn.headersSent = true;
}

// ---------- 请求体适配 ----------

// 模型列表缓存。必须声明在 freeModelIds() 之前：
// ucode 在编译函数时按当时的词法作用域解析标识符，声明在后面会报
// "access to undeclared variable"。
let modelCache = { at: 0, list: null };

// 返回当前已知的免费模型 ID 集合。
// 优先用已缓存的模型列表（开启 onlyFree 时缓存里只有免费模型），
// 缓存未就绪时回退到内置 FREE_MODELS 常量。
function freeModelIds() {
	if (modelCache.list && type(modelCache.list) === 'array' && length(modelCache.list) > 0) {
		let ids = [];
		for (let m in modelCache.list)
			if (type(m) === 'object' && m !== null && type(m.id) === 'string')
				push(ids, m.id);
		if (length(ids) > 0) return ids;
	}
	return FREE_MODELS;
}

function adaptBody(raw, cfg) {
	let body;
	try {
		body = json(raw);
	} catch (e) {
		return null;
	}
	if (type(body) !== 'object' || body === null) return null;

	let wantNonStream = (body.stream === false);
	// WorkBuddy 上游始终返回 SSE，客户端要非流式时由本代理合并后再回。
	// 但自定义上游（sensenova / askdiandian 等）会遵守 stream 字段，
	// 因此这里先统一置 true，等确定路由目标后再为自定义上游还原。
	body.stream = true;

	let messages = body.messages;
	if (type(messages) !== 'array' || length(messages) === 0 || messages[0].role !== 'system') {
		let sys = { role: 'system', content: 'You are a helpful assistant.' };
		let newMsgs = [sys];
		if (type(messages) === 'array') {
			for (let m in messages) push(newMsgs, m);
		}
		body.messages = newMsgs;
	}

	// 自定义上游路由：模型名形如 "sensenova/deepseek-v4-flash" 时，
	// 记下目标上游并把模型名还原成上游认得的裸名。
	//
	// 必须在下面的 onlyFree 检查之前处理：自定义上游的模型不在 WorkBuddy
	// 免费集合里，若先走 onlyFree 会被替换成 WorkBuddy 的默认模型，
	// 导致"选了日日新的模型却拿到 WorkBuddy 的回复"。
	//
	// 不能直接改 body.model：还要用它在上游请求里传裸模型名，
	// 因此把结果通过 body 的私有字段透出给 dispatch。
	body.__upstream = null;
	let upstreamId = null;
	if (type(body.model) === 'string') {
		let ref = splitModelRef(body.model);
		if (ref !== null) {
			if (ref.prefix === WB_PREFIX) {
				// workbuddy/xxx -> 走本机凭据池，去掉前缀即可
				body.model = ref.model;
			} else {
				let up = findUpstreamByPrefix(ref.prefix);
				if (up === null) {
					return { text: '', wantNonStream: wantNonStream,
						error: 'unknown upstream prefix: ' + ref.prefix };
				}
				upstreamId = up.id;
				// v2.7.0：模型映射（与 routePassthrough 同一语义，见那里的注释）
				body.model = mapUpstreamModel(up, ref.model);
			}
		}
	}

	// 免费模型保护：onlyFree 开启时，若请求的模型不在免费集合中，
	// 自动替换为默认免费模型，从源头杜绝收费。
	//
	// 注意：自定义上游的模型不受此限制 —— 它们本来就不是 WorkBuddy 的模型，
	// 用 WorkBuddy 的免费清单去校验必然"不通过"，会把请求错误地改写成
	// WorkBuddy 的默认模型，表现为"选了日日新却收到 WorkBuddy 的回复"。
	// 判据是 upstreamId（局部变量），不是 body.__upstream。
	if (cfg && cfg.onlyFree && upstreamId === null) {
		let ids = freeModelIds();
		let requested = body.model;
		let found = false;
		if (type(requested) === 'string' && length(requested) > 0) {
			for (let id in ids)
				if (id === requested) { found = true; break; }
		}
		if (!found) {
			logInfo(sprintf('only_free: model "%s" not free -> fallback "%s"', '' + (requested || '(none)'), ids[0]));
			body.model = ids[0];
		}
	}

	// 自定义上游遵守 stream 字段，非流式请求就让它直接返回完整 JSON，
	// 比"强制流式再本地合并"少一次拼接，语义也更准确。
	if (upstreamId !== null && wantNonStream) body.stream = false;

	return { text: sprintf('%.J', body), wantNonStream: wantNonStream, upstreamId: upstreamId };
}

// 把 SSE 流合并成单个 chat.completion 对象（非流式请求用）
function mergeChunks(sse) {
	let out = {
		id: '', object: 'chat.completion', created: 0, model: '',
		choices: [{ index: 0, message: { role: 'assistant', content: '' }, finish_reason: null }],
		usage: {},
	};
	for (let line in split(sse, '\n')) {
		if (substr(line, 0, 6) !== 'data: ') continue;
		let data = trim(substr(line, 6));
		if (data === '[DONE]' || data === '') continue;
		let chunk;
		try {
			chunk = json(data);
		} catch (e) {
			continue;
		}
		if (!out.id && chunk.id) out.id = chunk.id;
		if (!out.created && chunk.created) out.created = chunk.created;
		if (chunk.model) out.model = chunk.model;
		if (type(chunk.choices) === 'array' && length(chunk.choices) > 0) {
			let c = chunk.choices[0];
			if (c.delta) {
				if (c.delta.content) out.choices[0].message.content += c.delta.content;
				if (c.delta.reasoning_content)
					out.choices[0].message.reasoning_content =
						(out.choices[0].message.reasoning_content || '') + c.delta.reasoning_content;
			}
			if (c.finish_reason) out.choices[0].finish_reason = c.finish_reason;
		}
		if (chunk.usage) out.usage = chunk.usage;
	}
	return out;
}

// ---------- 模型列表 ----------

function fallbackModels() {
	let out = [];
	for (let id in FREE_MODELS)
		push(out, { id: id, name: id + ' · Free now' });
	return out;
}

function rateLabel(credits) {
	let raw = (credits === null) ? '' : ('' + credits);
	if (length(trim(raw)) === 0) return '';
	// 注意：ucode 的 PCRE 实现不支持 (?:...) 非捕获组，这里用普通捕获组。
	let m = match(raw, /x?\s*([0-9]+(\.[0-9]+)?)/);
	if (m) {
		let n = +m[1];
		if (n === 0) return 'Free now';
	}
	return trim(replace(raw, /\s*credits\s*$/i, ''));
}

// 判断 credits 是否显式为零（真正的免费模型）。
// 无 credits 字段的模型视为非免费，避免误放行收费模型。
function isFreeCredits(raw) {
	let s = (raw === null) ? '' : ('' + raw);
	if (length(trim(s)) === 0) return false;
	let m = match(s, /x?\s*([0-9]+(\.[0-9]+)?)/);
	if (m) return (+m[1] === 0);
	return false;
}

function modelsFromConfig(conf, freeOnly) {
	let out = [];
	let models = (type(conf) === 'object' && conf !== null && type(conf.models) === 'array') ? conf.models : [];
	for (let m in models) {
		if (type(m) !== 'object' || m === null) continue;
		if (type(m.id) !== 'string' || length(m.id) === 0) continue;
		// 只保留免费模型：避免出现收费
		if (freeOnly && !isFreeCredits(m.credits)) continue;
		let base = m.name || m.id;
		let label = rateLabel(m.credits);
		let entry = { id: m.id, name: (length(label) > 0) ? (base + ' · ' + label) : base };
		if (type(m.maxInputTokens) === 'int') entry.contextWindow = m.maxInputTokens;
		if (type(m.maxOutputTokens) === 'int') entry.maxTokens = m.maxOutputTokens;
		push(out, entry);
	}
	return out;
}

// ---------- curl 执行 ----------
// 注意：这些函数必须定义在 fetchModelsSync / 登录流程之前（ucode 无函数提升）。

// 执行 curl（字符串形式）并返回 stdout；失败返回 null
function runCurlStr(cmdline) {
	let buf = '';
	try {
		let proc = popen(cmdline, 'r');
		if (!proc) {
			logErr('popen failed: ' + error());
			return null;
		}
		let chunk;
		while ((chunk = proc.read(16384)) !== null && length(chunk) > 0)
			buf += chunk;
		proc.close();
	} catch (e) {
		logErr('curl failed: ' + e);
		return null;
	}
	return buf;
}

// 通用 curl 调用：args 为字符串数组（会自动转义拼接）
function runCurl(cfg, args) {
	let parts = ['curl'];
	for (let a in args) push(parts, shquote(a));
	return runCurlStr(join(' ', parts));
}

// ---------- 同步获取模型列表（用 curl，带超时；失败回退内置） ----------
function fetchModelsSync(cfg, token) {
	if (!token) return null;
	let url = cfg.endpoint + '/v3/config';
	let out = runCurl(cfg, [
		'-sS', '-m', '10',
		'-H', 'Authorization: Bearer ' + token,
		'-H', 'Content-Type: application/json',
		'-H', 'User-Agent: WorkBuddy/' + clientVersion(cfg),
		url,
	]);
	if (out === null) return null;
	let j;
	try {
		j = json(out);
	} catch (e) {
		return null;
	}
	if (type(j) !== 'object' || j === null) return null;
	let list = modelsFromConfig(j.data || j, cfg.onlyFree);
	if (length(list) === 0) return null;
	return list;
}

function availableModels(cfg) {
	let now = time();
	if (modelCache.list && (now - modelCache.at) < 21600) return modelCache.list;

	let token = pickToken(cfg);
	let list = fetchModelsSync(cfg, token);
	if (list && length(list) > 0) {
		modelCache = { at: now, list: list };
		return list;
	}
	list = fallbackModels();
	// **降级结果不进缓存**。
	//
	// 走到这里通常意味着"此刻没有可用凭据"，而这是个**会变的临时状态** ——
	// 用户一登录新账号就变了。若按 6 小时 TTL 把它缓存下来，用户登录成功后
	// 模型列表仍旧停在降级版，表现成"刚登录却不生效"，只能靠重启服务解决。
	// 降级列表本身是常数（FREE_MODELS），每次算一遍的代价可以忽略。
	return list;
}

// ---------- 登录流程 ----------

let login = { running: false, state: '', timer: null, startedAt: 0, lastError: '', ok: false, authUrl: '' };

function noAuthHeaders() {
	return [
		'-H', 'Content-Type: application/json',
		'-H', 'X-No-Authorization: true',
		'-H', 'X-No-Enterprise-Id: true',
		'-H', 'X-No-Department-Info: true',
	];
}

function pickField(obj, keys) {
	if (type(obj) !== 'object' || obj === null) return null;
	for (let k in keys) {
		let v = obj[k];
		if (type(v) === 'string' && length(v) > 0) return v;
	}
	return null;
}

function pollOnce(cfg, state) {
	let args = ['-sS', '-m', '10'];
	let nh = noAuthHeaders();
	for (let h in nh) push(args, h);
	push(args, cfg.endpoint + '/v2/plugin/auth/token?state=' + state);

	let out = runCurl(cfg, args);
	if (out === null) return 'retry';

	let j;
	try {
		j = json(out);
	} catch (e) {
		return 'retry';
	}
	if (type(j) !== 'object' || j === null) return 'retry';

	if (j.code === 0 && j.data) {
		let data = j.data.data || j.data;
		let accessToken = pickField(data, ['access_token', 'accessToken', 'token']);
		if (accessToken) {
			saveToken(cfg, accessToken, pickField(data, ['refresh_token', 'refreshToken']));
			return 'ok';
		}
		return 'retry';
	}
	return (j.code === CODE_LOGIN_ING) ? 'retry' : 'failed';
}

function schedulePoll(cfg, state) {
	login.timer = uloop.timer(LOGIN_POLL_MS, () => {
		if (!login.running) return;
		let r = pollOnce(cfg, state);
		if (r === 'ok') {
			login.running = false;
			login.ok = true;
			login.lastError = '登录成功，token 已保存';
			return;
		}
		if (r === 'failed') {
			login.running = false;
			login.lastError = '登录失败（WorkBuddy 拒绝了本次授权）';
			return;
		}
		if (time() - login.startedAt > (LOGIN_TIMEOUT_MS / 1000)) {
			login.running = false;
			login.lastError = '登录超时（300 秒内未完成）';
			return;
		}
		schedulePoll(cfg, state);
	});
}

function startWebLogin(cfg) {
	if (login.running) return { ok: true, alreadyRunning: true, authUrl: login.authUrl };

	login.running = true;
	login.lastError = '';
	login.ok = false;

	let args = ['-sS', '-m', '15', '-X', 'POST'];
	let nh = noAuthHeaders();
	for (let h in nh) push(args, h);
	push(args, '--data', '{}');
	push(args, cfg.endpoint + '/v2/plugin/auth/state?platform=CLI');

	let out = runCurl(cfg, args);
	if (out === null) {
		login.running = false;
		login.lastError = 'auth/state 请求失败（无法连接 WorkBuddy）';
		return { ok: false, error: login.lastError };
	}

	let j;
	try {
		j = json(out);
	} catch (e) {
		login.running = false;
		login.lastError = 'auth/state 返回非 JSON';
		return { ok: false, error: login.lastError };
	}

	let data = (type(j) === 'object' && j !== null) ? j.data : null;
	if (type(data) !== 'object' || data === null || !data.authUrl) {
		login.running = false;
		login.lastError = 'auth/state 未返回 authUrl';
		return { ok: false, error: login.lastError };
	}

	login.state = data.state || '';
	login.authUrl = data.authUrl;
	login.startedAt = time();
	login.lastError = '请在浏览器打开登录链接完成 WorkBuddy 授权（300 秒内）';
	logInfo('login url: ' + data.authUrl);

	schedulePoll(cfg, login.state);
	return { ok: true, alreadyRunning: false, authUrl: data.authUrl };
}

// ---------- 连接处理 ----------

// 这里是**赋值**不是声明 —— 声明已提前到文件头部（upState/upBrake 附近）的
// `let cfg = {};`，因为 brakeLeft()/brakeNoteRateLimit() 定义在本行之前却要读 cfg。
// 赋值留在此处，是为了不改变"配置在启动流程的这一刻才读盘"的既有顺序。
// 同理 connections 也已提前到文件头部 —— closeConn() 需要它，而它定义在本行之前。
cfg = loadConfig();

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

// ---------- 聊天转发（核心） ----------
// 顺序：onUpstreamEnd（被 handleChat 引用）→ handleChat → dispatch（引用 handleChat）

// ---------- 前向引用表 ----------
// ucode 的函数声明不提升，被引用的函数必须先定义。
// 但聊天转发链存在真实的循环依赖：
//     spawnUpstream → tryNextCred → spawnUpstream（换凭据重试）
//     spawnUpstream → onUpstreamEnd → tryNextCred
// 纯靠排序无法解开，因此把这三个函数挂到一个表上，
// 相互调用走属性查找（运行时解析），绕开声明顺序限制。
//
// 注意：这个表必须在文件最前面声明（见顶部 F 的定义处），不能放在这里 ——
// clientVersion() 也要通过它调用 runCurl()，而 clientVersion 在本行之前。

// 池当前是否可用：配置里开着 且 不处于"疑似挂了"的回退冷却期内。
// 定义在这里而不是文件顶部：它读 cfg，而 cfg 的声明位置更靠后，
// ucode 按词法解析标识符，放前面会抛 undeclared variable。
function poolUsable() {
	return cfg.usePool && (poolFailUntil === 0 || time() >= poolFailUntil);
}

// 池化尝试失败但一个字节都没收到 → 判定池不可用，立刻改用直连重发同一次尝试。
// 返回 true 表示"本函数已接手处理"，调用方不要再走原有的失败分支。
//
// 关键点：**不调用 markCredFail / markUpKeyFail**。池挂了跟这把 Key 毫无关系，
// 记一次失败会把一把好 Key 打进冷却 —— 池恢复后反而少一把可用 Key，
// 日志里还会多出一堆指向错误方向的"上游失败"。
function poolFallback(conn) {
	if (!conn.usedPool || conn.headersSent) return false;
	if (conn.attemptBytes > 0) return false;
	poolFailUntil = time() + POOL_FAIL_COOLDOWN;
	metrics.pool.fallback++;
	logErr(sprintf('连接池疑似不可用（尝试 %d 零字节响应），%ds 内改用直连重发 (client %s)',
		conn.tries || conn.upTry || 0, POOL_FAIL_COOLDOWN, conn.ip || '?'));
	conn.usedPool = false;
	// 回退必须用**同一把**凭据/Key 重发：spawnUpstream 取 pool[tries]、
	// spawnUpstreamDirect 取 upKeys[upTry]，两者都是"取用时自增"，
	// 所以得先把指针退回去 —— 否则池一挂就白跳一把 Key，几次下来好 Key 全被跳过。
	if (conn.upstream) {
		if (conn.upTry > 0) conn.upTry--;
		if (conn.upKeyInUse) conn.upKeyInUse = null;
	} else {
		if (conn.tries > 0) conn.tries--;
	}
	if (conn.upstream) F.spawnUpstreamDirect(conn);
	else F.spawnUpstream(conn);
	return true;
}

// 每次尝试的公共复位：清空累积状态、重置计时、并只计一次池化模式请求数。
// 必须定义在 spawnUpstream / spawnUpstreamDirect 之前（ucode 函数不提升）。
function beginAttempt(conn) {
	conn.sseBuf = '';
	conn.headersSent = false;
	conn.sawDone = false;       // v2.1.0：每次尝试独立跟踪 [DONE]（截断检测）
	// 本次尝试的计时与池化决策。这三个字段同时服务指标与回退判定，
	// 每次尝试都必须清零 —— 否则上一轮的首字节时间会被算进这一轮的 TTFB。
	conn.firstByteAt = 0;
	conn.attemptBytes = 0;
	conn.attemptAt = nowMs();
	conn.usedPool = poolUsable();
	// 一条请求只计一次 mode.req —— 池化失败回退直连时会用同一把凭据重发，
	// 若按"尝试次数"计数会把一次请求算成两次（且口径会随回退次数漂移）。
	if (!conn.modeCounted) {
		conn.modeCounted = true;
		metricMode(conn).req++;
		if (conn.usedPool) metrics.pool.used++;
	}
}

// 释放当前尝试占用的进程、uloop 句柄与桥连接。换凭据/换 Key/正常收尾共用。
// 必须定义在 tryNextCred 等调用点之前（ucode 函数不提升）。
function releaseAttempt(conn) {
	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	conn.procHandle = null;
	conn.proc = null;
	bridgeRelease(conn);
}

// 组装转发用的 curl 参数（WorkBuddy 池通道与自定义上游通道共用）。
// 差异项（超时档位/鉴权/Accept/UA/目标/默认路径）由 o 传入，避免两份几乎
// 相同的参数表在演进中悄悄分叉。回环是明文 HTTP/1.1（--http2/--tcp-fastopen
// 无意义），且连接超时要压到 POOL_CONNECT_TIMEOUT，好让池挂掉时尽快暴露并回退。
function curlArgs(conn, o) {
	let args = ['curl', '-sS', '-N', '-X', 'POST'];
	if (conn.usedPool) {
		push(args, '--connect-timeout');
		push(args, '' + POOL_CONNECT_TIMEOUT);
	} else {
		push(args, '-4');
		push(args, '--http2');
		push(args, '--tcp-fastopen');
		push(args, '--connect-timeout');
		push(args, o.connectTimeout);
	}
	push(args, '--speed-limit');
	push(args, '1');
	push(args, '--speed-time');
	push(args, o.speedTime);
	push(args, '--max-time');
	push(args, o.maxTime);
	push(args, '--keepalive-time');
	push(args, '30');
	push(args, shquote('-H'));
	push(args, shquote('Content-Type: application/json'));
	push(args, shquote('-H'));
	push(args, shquote('Authorization: Bearer ' + o.auth));
	push(args, shquote('-H'));
	push(args, shquote('Accept: ' + o.accept));
	push(args, shquote('-H'));
	push(args, shquote('User-Agent: ' + o.ua));
	if (conn.usedPool) {
		// 池的协议约定：curl 连的是 127.0.0.1，真正的上游由 X-WB-Target 指定
		push(args, shquote('-H'));
		push(args, shquote('X-WB-Target: ' + o.target));
	}
	// v2.1.0：请求级关联 ID 透传上游。池化路径由 Go 池原样转发该头。
	push(args, shquote('-H'));
	push(args, shquote('X-Request-Id: ' + (conn.reqId || '')));
	// v2.1.0：把上游响应头（状态行 + Retry-After 等）落盘到独立文件，供失败
	// 路径解析真实状态码与限流窗口（readUpstreamStatus）。-D 只写头，不影响
	// stdout 的 SSE body 逐字节透传。
	if (conn.hdrFile) {
		push(args, '-D');
		push(args, shquote(conn.hdrFile));
	}
	push(args, shquote('--data-binary'));
	push(args, shquote('@' + conn.tmpFile));
	push(args, shquote(conn.usedPool
		? (cfg.poolBase + (conn.targetPath || o.defaultPath))
		: (o.target + (conn.targetPath || o.defaultPath))));
	return args;
}

// 创建块处理回调（WorkBuddy 池通道与自定义上游通道共用）。两个通道的差异
// 只有失败/结束的收尾函数（F.tryNextCred/F.onUpstreamEnd vs
// F.tryNextUpKey/F.onUpstreamDirectEnd），其余读块、计时、TTFB、SSE 判断、
// 转发与响应体累积逻辑完全相同 —— 抽成一份，避免两处逻辑悄然分叉。
// 必须定义在 spawnUpstream 之前（ucode 函数不提升）。
function makeOnChunk(conn, onFail, onEnd) {
	return () => {
		let chunk;
		try {
			chunk = readChunk(conn, 16384);
		} catch (e) {
			onFail(conn, 'read failed: ' + e);
			return;
		}
		if (chunk === null || length(chunk) === 0) {
			onEnd(conn);
			return;
		}
		// 有字节回来即刷新静默计时
		conn.lastByteAt = time();
		conn.attemptBytes += length(chunk);
		// 首字节即 TTFB：从发起到收到第一个字节，包含 DNS/TCP/TLS/上游排队，
		// 正是"池化到底省了多少"要对比的那个量。
		if (conn.firstByteAt === 0) {
			conn.firstByteAt = nowMs();
			histAdd(metricMode(conn).ttfb, conn.firstByteAt - conn.attemptAt);
		}

		if (conn.wantNonStream) {
			// v2.1.0：非流式累积也加 MAX_SSE_BUF 上限（原无上限，极端大响应
			// 会撑爆内存）。超限后不再累积但继续转发，收尾时按已攒内容合并。
			if (length(conn.sseBuf) < MAX_SSE_BUF) conn.sseBuf += chunk;
			return;
		}

		// 流式转发；首个数据块先判断是否为错误响应
		if (!conn.headersSent) {
			let t = trim(chunk);
			let c = substr(t, 0, 1);
			// 以 { 开头且没有 SSE 帧，或以 < 开头（网关 HTML 错误页）：
			// 都可能是错误体，先攒着，等结束时判断是否要换凭据
			// v2.1.0：错误嗅探累积同样加 MAX_SSE_BUF 上限。
			if ((c === '{' || c === '<') && index(chunk, 'data:') < 0) {
				if (length(conn.sseBuf) < MAX_SSE_BUF) conn.sseBuf += chunk;
				return;
			}
			sseHeaders(conn);
		}
		// v2.1.0：写侧检查 —— 客户端慢/断开会短写，send 不再静默失败。
		if (!safeSend(conn, chunk)) {
			conn.aborted = true;
			closeConn(conn);
			return;
		}
		// v2.0：流式也累积响应体（上限 MAX_SSE_BUF，防极端大响应撑爆内存），
		// 供收尾时提取 usage 做用量统计。v2.1.0：顺带跟踪 [DONE] 用于截断检测。
		if (index(chunk, '[DONE]') >= 0) conn.sawDone = true;
		if (length(conn.sseBuf) < MAX_SSE_BUF) conn.sseBuf += chunk;
	};
}

function spawnUpstream(conn) {
	if (conn.closed) return;

	let cred = conn.pool[conn.tries];
	conn.tries++;
	conn.credId = cred.id;
	beginAttempt(conn);

	logInfo(sprintf('chat via credential %s (attempt %d/%d) req=%s',
		cred.id, conn.tries, conn.tryLimit, conn.reqId || '?'));

	// v2.2.0：记录这次选中。poolSize 一并记下 —— 排查"为什么总是同一个账号"
	// 时，第一个要看的就是当时池子到底有几个可选项（池子只有 1 个时，
	// 任何"轮换不生效"的怀疑都是误判）。
	relayPick(cred.id, 'pool', {
		try: conn.tries, poolSize: length(conn.pool),
	});

	// 带上客户端版本：上游目前不校验版本，但统一的 UA 更贴近真实客户端，
	// 也便于日后上游若启用版本门禁时不必再改代码。
	let ua = clientVersion(cfg);
	conn.usedVersion = ua;

	// 静默兜底：curl 侧 90 秒无字节即断开（75s 看门狗通常会先触发，
	// 这层是看门狗万一失效时的最后保险）；--max-time 防连接无限占用。
	let args = curlArgs(conn, {
		speedTime: '90', maxTime: '1800', connectTimeout: '5',
		accept: 'text/event-stream',
		auth: cred.token,
		ua: 'WorkBuddy/' + ua,
		target: cfg.endpoint,
		defaultPath: '/v2/chat/completions',
	});
	let cmdline = join(' ', args);

	// 块处理：从（桥接 socket 或 popen 管道）读一块并转发（v1.8.3 回环桥）
	let onChunk = makeOnChunk(conn, F.tryNextCred, F.onUpstreamEnd);
	conn.chunkFn = onChunk;

	let bridged = bridgeUse();
	let bridgedId = null;
	if (bridged) bridgedId = bridgeRegister(conn);
	if (bridged && bridgedId) cmdline = bridgeWrap(bridgedId, cmdline);

	let proc;
	try {
		proc = popen(cmdline, 'r');
	} catch (e) {
		bridgeRelease(conn);
		F.tryNextCred(conn, 'curl spawn failed: ' + e);
		return;
	}
	if (!proc) {
		bridgeRelease(conn);
		F.tryNextCred(conn, 'curl spawn failed: ' + error());
		return;
	}

	conn.proc = proc;
	// 静默看门狗计时起点（两档阈值见 cfg.upFirstByteSec / cfg.upIdleSec 与 watchdogTick）
	conn.lastByteAt = time();

	if (!bridged) {
		conn.procHandle = uloop.handle(proc, onChunk, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
	}
}

// 结束当前凭据的尝试：释放进程与句柄，决定重试还是收尾
function tryNextCred(conn, reason) {
	if (conn.closed) return;

	releaseAttempt(conn);

	// 池化尝试零字节收场：先判是不是池本身挂了。是的话就地直连重发，
	// 并且**不记这次凭据失败** —— 见 poolFallback 的说明。
	if (poolFallback(conn)) return;

	if (reason) {
		// v2.1.0：读取 curl -D 落盘的上游状态码与 Retry-After，让冷却窗口贴近
		// 上游真实限流时长，而不是全靠本地猜测。
		let hdr = readUpstreamStatus(conn);
		let rate = isRateLimitReason(reason);
		let auth = isAuthReason(reason);
		// 状态码为 429 但响应体没匹配到限流关键词时，以状态码为准（Anthropic
		// spend-cap 429 与普通限流 error type 相同，只能靠 Retry-After 区分）。
		if (hdr && hdr.status === 429 && !rate) rate = true;
		markCredFail(cfg, conn.credId, reason, rate, hdr ? hdr.retryAfter : 0, auth);
		metricFail('wb', conn.credId, rate ? 'rate' : (auth ? 'auth' : ''), reason);
	}

	if (conn.headersSent) {
		// 已经开始向客户端推流，无法回退重试
		closeConn(conn);
		return;
	}

	if (conn.tries < conn.tryLimit) {
		// v2.2.0：换号也要记一笔。"换号后成功率"是评估轮换规则的核心指标 ——
		// 如果 switch 很多但 ok 很少，说明池子里能用的账号太少，或冷却太短
		// 导致刚跳过又跳回来。
		relayLog('', 'switch', reason, { from: conn.credId, try: conn.tries });
		F.spawnUpstream(conn);
		return;
	}

	// v2.2.0：所有账号试完仍未成功 —— 这是最需要告警的结局
	relayLog('', 'exhaust', reason, { tries: conn.tries, limit: conn.tryLimit });
	relayTotals.fail++;

	// 风控类失败附一句人话解释。否则客户端只拿到 "上游错误码：11140"，
	// 无法判断是"我写的问题太敏感"还是"账号被封了"—— 后者要换账号，
	// 前者改提问即可，处理方式完全不同。
	let risk = isRiskControlReason(reason);
	let hint = risk
		? '（上游对所有内容都返回内容审核类拦截，说明该 WorkBuddy 账号已被风控，请更换账号凭据）'
		: '';

	jsonResponse(conn, 502, {
		error: {
			message: '所有可用凭据均失败：' + (reason || '上游无响应') + hint,
			type: risk ? 'account_restricted' : 'upstream_error',
			tried: conn.tries,
		},
	});
}

// ---------- 自定义上游转发 ----------
//
// 与 spawnUpstream 的区别有三处，因此单独实现而不是复用：
//   1. Key 来自上游自己的 Key 组（轮询），不是 WorkBuddy 凭据池
//   2. 目标是 {baseUrl}/chat/completions，不是 {endpoint}/v2/chat/completions
//   3. 失败时换的是同一个上游的下一条 Key，而不是换账号
function spawnUpstreamDirect(conn) {
	if (conn.closed) return;

	let up = conn.upstream;

	// v1.8.1 限流刹车：闭闸期间**不再产生重试流量**。
	//
	// 为什么只拦重试、不拦首次尝试：首次尝试是唯一能探知"上游是否已恢复"的手段，
	// 拦掉它就会把本来能成功的请求变成失败。而闭闸期间的重试是纯浪费 ——
	// soak 实测 24 个失败请求每个试满 4 把 Key，96 次上游调用无一成功，
	// 占上游总流量的 70%（池统计 138 次 / 60 个客户端请求 = 2.25× 放大）。
	// 只拦重试既拿掉这份浪费，又完整保留"不通就换下一个"（未闭闸时行为一字不变）。
	if (conn.upTry > 0) {
		let left = brakeLeft(up);
		if (left > 0) {
			let b = brakeState(up.id);
			if (left * 1000 <= RATE_BRAKE_WAIT_MS && !conn.brakeWaited) {
				// 闭闸只剩个尾巴：等它过去再发，比直接回 429 对客户端友好得多。
				// 只能等一次（conn.brakeWaited），否则会无限自旋。
				conn.brakeWaited = true;
				b.waited++;
				metrics.brakeWaited++;
				logInfo(sprintf('上游 %s 刹车剩 %ds，等 %dms 后再重试 (client %s)',
					up.prefix, left, left * 1000, conn.ip || '?'));
				uloop.timer(left * 1000, () => { F.spawnUpstreamDirect(conn); });
				return;
			}
			b.rejected++;
			metrics.brakeRejected++;
			let ra = (left > cfg.brakeMaxRa) ? cfg.brakeMaxRa : left;
			logErr(sprintf('上游 %s 刹车中（剩 %ds），停止重试并回 429 (client %s)',
				up.prefix, left, conn.ip || '?'));
			jsonResponse(conn, 429, {
				error: {
					message: '上游 ' + up.prefix + ' 正在限流（' + cfg.brakeWindow + 's 内被拒 ' +
						cfg.brakeHits + ' 次，已刹车 ' + cfg.brakeSec + 's），请稍后重试',
					type: 'rate_limit_error',
					retry_after: ra,
				},
			}, { 'Retry-After': '' + ra });
			return;
		}
	}

	if (conn.upTry >= length(conn.upKeys)) {
		// 全部 Key 都失败：把"最后一次失败原因 + 最早可恢复时间"一并返回。
		// 冷却中的 Key 一律用 429 + Retry-After（标准限流语义），客户端据此退避；
		// 非冷却类失败（Key 无效/上游 5xx）仍用 502。
		let retry = upEarliestRetrySec(up);
		let extra = null;
		if (retry > 0) {
			extra = { 'Retry-After': '' + retry };
		}
		jsonResponse(conn, retry > 0 ? 429 : 502, {
			error: {
				message: '上游 ' + up.prefix + ' 的所有 Key 均失败' +
					(conn.lastFailReason ? '：' + conn.lastFailReason : ''),
				type: retry > 0 ? 'rate_limit_error' : 'upstream_error',
				retry_after: retry,
			},
		}, extra);
		return;
	}

	let key = conn.upKeys[conn.upTry];
	conn.upTry++;
	// v2.0.1 抽取遗漏修复：与 spawnUpstream 相同的复位逻辑统一走 beginAttempt，
	// 避免这份手写副本与 beginAttempt 在演进中分叉（原 v2.0.1 曾漏改这里）。
	beginAttempt(conn);

	logInfo(sprintf('chat via upstream %s key %s (attempt %d/%d) req=%s',
		up.prefix, maskKey(key), conn.upTry, length(conn.upKeys), conn.reqId || '?'));

	// v2.2.0：自建上游的选中也记一笔，keyCount 说明当时有几把 Key 可轮。
	// 注意不在这里赋 conn.upKeyInUse —— 那由 spawn 成功后统一设置（见本函数尾部），
	// 提前赋值会让"spawn 失败但日志显示已选中"这种假象混进健康矩阵。
	relayPick('up:' + up.id + ':' + maskKey(key), 'direct', {
		try: conn.upTry, keyCount: length(conn.upKeys),
	});

	// Accept 头必须跟着 body 的 stream 字段走。
	// 自定义上游（sensenova 等）看到 Accept: text/event-stream 就会返回 SSE，
	// 即使 body 里 stream:false —— 客户端要非流式时会收到一堆 SSE 帧，
	// 表现为"请求了非流式却拿到流"。踩坑记录 #14。
	let accept = conn.wantNonStream ? 'application/json' : 'text/event-stream';

	// 自定义上游通常直接返回 JSON/SSE，静默 30 秒即可判死（25s 看门狗通常是
	// 先触发的那一道，这层是兜底）；--max-time 防无限占用。
	let args = curlArgs(conn, {
		speedTime: '30', maxTime: '900', connectTimeout: '8',
		accept: accept,
		auth: key,
		ua: 'ai-gateway/' + APP_VERSION,
		target: up.baseUrl,
		defaultPath: '/chat/completions',
	});

	let cmdline = join(' ', args);

	// 块处理：从（桥接 socket 或 popen 管道）读一块并转发（v1.8.3 回环桥）
	let onChunk = makeOnChunk(conn, F.tryNextUpKey, F.onUpstreamDirectEnd);
	conn.chunkFn = onChunk;

	let bridged = bridgeUse();
	let bridgedId = null;
	if (bridged) bridgedId = bridgeRegister(conn);
	if (bridged && bridgedId) cmdline = bridgeWrap(bridgedId, cmdline);

	let proc;
	try {
		proc = popen(cmdline, 'r');
	} catch (e) {
		bridgeRelease(conn);
		F.tryNextUpKey(conn, 'curl spawn failed: ' + e);
		return;
	}
	if (!proc) {
		bridgeRelease(conn);
		F.tryNextUpKey(conn, 'curl spawn failed: ' + error());
		return;
	}

	conn.proc = proc;
	conn.upKeyInUse = key;
	// 静默看门狗计时起点
	conn.lastByteAt = time();

	if (!bridged) {
		conn.procHandle = uloop.handle(proc, onChunk, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
	}
}

// 换下一条 Key 重试
function tryNextUpKey(conn, reason) {
	if (conn.closed) return;

	releaseAttempt(conn);

	// 池化尝试零字节收场：先判是不是池本身挂了。是的话就地直连重发同一把 Key，
	// 并且不把它算作这把 Key 的失败（否则池一挂就会连坐冷却掉一批好 Key）。
	if (poolFallback(conn)) return;

	// 客户端错误（模型名不被接受 / 请求体不被接受）：
	// 确定性失败，换 Key 结果一模一样，所以就地返回，不进换 Key 链。
	// 这一步必须放在 markUpKeyFail **之前** —— 否则一次"模型名写错"或
	// "请求参数不对"，会依次烧掉这个上游全部 Key 的冷却，把好请求也一起拖住。
	if (reason && isClientErrorReason(reason)) {
		let isModel = isModelRejectReason(reason);
		// 请求体层面的拒绝（"inference request is invalid" 一类）：把实际发出的
		// 请求体摘要记入日志。临时文件在 closeConn 时会删除，错过这一次，
		// 就再也无法定位是哪个字段触发上游拒绝（这正是 1.7.10 时代排查不透的教训）。
		if (!isModel && conn.tmpFile) {
			let peek = '';
			try {
				peek = readfile(conn.tmpFile) || '';
			} catch (e) { peek = '(read failed: ' + e + ')'; }
			if (length(peek) > 800) peek = substr(peek, 0, 800) + ' …(截断)';
			logInfo(sprintf('upstream %s 拒绝该请求，请求体摘要: %s',
				conn.upstream.prefix,
				replace(replace(peek, '\n', '\\n'), '\r', '')));
		}
		logInfo(sprintf('upstream %s 拒绝该%s（不冷却 Key，不换 Key）：%s',
			conn.upstream.prefix, isModel ? '模型' : '请求', reason));
		if (!conn.headersSent) {
			let cmsg = '上游 ' + conn.upstream.prefix + ' ' +
					(isModel ? '不接受该模型：' : '不接受该请求：') + reason +
					(isModel
						? '（模型名请照 /v1/models 里带前缀的写法填；上游自己的模型列表有时会列出它实际不提供的模型）'
						: '（这是请求参数问题，换 Key 与重试都无用，请检查请求体）');
			jsonResponse(conn, isModel ? 404 : 400, {
				error: {
					message: cmsg,
					type: isModel ? 'model_not_found' : 'invalid_request_error',
				},
			});
		} else {
			closeConn(conn);
		}
		return;
	}

	if (reason && conn.upKeyInUse) {
		// v2.1.0：读取真实状态码与 Retry-After，冷却贴近上游真实限流窗口。
		let hdr = readUpstreamStatus(conn);
		markUpKeyFail(conn.upstream, conn.upKeyInUse, reason, hdr ? hdr.retryAfter : 0);
	}

	// 记住最后一次失败原因：全部 Key 都用尽时，把它连同 Retry-After 一起返回给客户端
	if (reason) conn.lastFailReason = '' + reason;

	if (conn.headersSent) {
		closeConn(conn);
		return;
	}

	// 一律尝试下一把 Key —— 这就是用户要的「不论上游回复什么，不通的自动换下一个」。
	//
	// 这里**不再**有按失败类型分叉的"智能换 Key"特例（v1.7.1 起、v1.7.11 移除）：
	//   - 旧特例只在 `isRateLimitReason(reason)` 时挑一把"未冷却"的 Key 覆盖下一个
	//     槽位，其它失败类型虽然也会落到 spawnUpstreamDirect，但语义不统一；
	//   - 那个特例还会在"其余 Key 都在冷却"时直接返回 `429 当前 Key 被限流`，
	//     这正是用户撞到的"还有 Key 没试过就放弃"。
	//
	// 现在顺序完全由 usableUpKeys() 决定（健康 Key 轮询在前、失败过的按恢复时间在后），
	// 本函数只负责"推进到下一个槽位"。尝试次数上界由 spawnUpstreamDirect 的
	// `conn.upTry >= length(conn.upKeys)` 保证 —— 最多试满 Key 总数（4 次），不会无限连撞。
	F.spawnUpstreamDirect(conn);
}

// 自定义上游正常结束：收尾并在必要时做非流式合并
function onUpstreamDirectEnd(conn) {
	if (conn.closed) return;

	releaseAttempt(conn);

	// 未推流就结束：要么是错误体，要么是空响应
	if (!conn.headersSent) {
		let raw = conn.sseBuf;
		// 通过 F 表调用：upstreamLooksFailed 定义在本文件更靠后的位置，
		// ucode 函数不提升，直接调用会抛未声明变量错误（同 spawnUpstream 的循环依赖处理）。
		let fail = F.upstreamLooksFailed(raw);
		if (fail) {
			tryNextUpKey(conn, fail);
			return;
		}
		// 走到这里说明上游确实产出了内容 → 这把 Key 可用。
		//
		// v1.8.1 修复：这里必须真正把"成功"回报给 Key 状态，原因是
		//   (1) markUpKeyOk 是全文件唯一会调 brakeClear 的地方，而它此前
		//       只被"逐 Key 探活/拉模型"那条冷路径调用 —— 聊天成功路径从不调用，
		//       于是 /metrics 里上游 ok 恒为 0（soak 实测 ok=0/fail=53），
		//       文档宣称的「任一成功即合闸」在聊天路径上等于没接线，
		//       刹车只能靠 openUntil 到期自愈，恢复得比应有速度慢；
		//   (2) fails/coolUntil 也需要在成功时归零，否则一把偶发失败过的 Key
		//       会一直带着 fails>0，在 usableUpKeys() 的排序里永远排在健康 Key 之后。
		// 放在 fail 判定**之后**：失败路径已经在 tryNextUpKey 里记过失败了。
		// v2.0：成功回报统一走 noteUpstreamSuccess（markUpKeyOk + 会话粘性写入）。
		if (conn.upstream && conn.upKeyInUse)
			noteUpstreamSuccess(conn);
		// v2.0：用量统计：从响应体提取 usage 并累加。
		let usage = extractUsage(raw);
		if (usage) recordUsage(conn, usage);
		// v2.0：通用端点透传：不做 chat 语义重写，上游返回什么就原样回传。
		if (conn.passthrough) {
			if (conn.wantNonStream) {
				rawResponse(conn, 200, 'application/json', raw, null);
			} else {
				sseHeaders(conn);
				if (!safeSend(conn, raw)) conn.aborted = true;
				closeConn(conn);
			}
			return;
		}
		if (conn.wantNonStream) {
			// 上游遵守了 stream:false，直接回完整 JSON；
			// 若它仍然返回 SSE（少数上游无视 stream 字段），再本地合并。
			let t = trim(raw);
			if (substr(t, 0, 1) === '{' && index(t, 'data:') < 0) {
				rawResponse(conn, 200, 'application/json', raw, null);
				return;
			}
			let merged = mergeChunks(raw);
			jsonResponse(conn, 200, merged);
			return;
		}
		// 流式但上游没给 SSE：直接透传原始内容
		sseHeaders(conn);
		if (!safeSend(conn, raw)) conn.aborted = true;
		closeConn(conn);
		return;
	}

	// 走到这里说明 headersSent 已为真：这条流的开头是真内容，已经透传给客户端了，
	// 同样是一次成功的尝试 —— 与上面 !headersSent 分支保持一致的账本，
	// 否则"流式成功"这一类请求在上游 ok 指标里永远不出现、也不参与合闸。
	// v2.0：成功回报统一走 noteUpstreamSuccess（markUpKeyOk + 会话粘性写入）。
	if (conn.upstream && conn.upKeyInUse)
		noteUpstreamSuccess(conn);
	// v2.0：用量统计：流式场景从累积的 sseBuf 里提取最后一个 usage。
	let usage = extractUsage(conn.sseBuf);
	if (usage) recordUsage(conn, usage);


	if (conn.wantNonStream) {
		// v2.0：透传端点不做合并，原样回传累积内容。
		if (conn.passthrough) {
			rawResponse(conn, 200, 'application/json', conn.sseBuf, null);
			return;
		}
		let merged = mergeChunks(conn.sseBuf);
		jsonResponse(conn, 200, merged);
		return;
	}
	closeConn(conn);
}

// 判断上游返回体是否代表“这个凭据不可用”（限流/被封/额度耗尽/鉴权失败）。
// 上游失败时并不总是返回 JSON：
//   - APISIX/openresty 网关会直接吐 HTML 错误页（如 401 Authorization Required）
//   - 也可能返回 {"error":...} JSON
//   - 也可能返回 SSE 形式的错误事件
//   - 也可能成功但其实没有任何内容
// 只要在未向客户端推流前拿到的不是“能识别出内容”的响应，就视为该凭据失败。
function upstreamLooksFailed(raw) {
	let t = trim(raw || '');
	if (length(t) === 0) return '上游返回空响应';

	let c = substr(t, 0, 1);
	let head = substr(lc(t), 0, 400);

	// HTML 错误页（网关 401/403/429/502 等）
	if (c === '<') {
		let m = match(t, /([0-9]{3})[ ]*([A-Za-z][A-Za-z ]{0,30})/);
		if (m) return '上游返回 HTML 错误页：' + m[1] + ' ' + trim(m[2]);
		return '上游返回 HTML 错误页';
	}

	// JSON 错误体
	if (c === '{') {
		let j = null;
		try { j = json(t); } catch (e) { j = null; }
		if (j && type(j) === 'object') {
			// 明确的错误字段
			if (j.error) {
				let msg = j.error;
				if (type(msg) === 'object' && msg.message) msg = msg.message;
				return '上游错误：' + ('' + msg);
			}
			// 注意：ucode 没有 undefined，判断字段是否存在要用 type()
			let hasCode = (type(j.code) === 'int' || type(j.code) === 'string');
			let code = hasCode ? ('' + j.code) : '';
			if (j.message && hasCode && code !== '0' && code !== '200')
				return '上游错误：' + ('' + j.message);
			if (hasCode && code !== '0' && code !== '200')
				return '上游错误码：' + code;
			// 合法的 chat.completion
			if (j.choices || j.object === 'chat.completion' || j.id) return null;
		}
		// 解析不了或结构不认识，交给后续处理
		return null;
	}

	// SSE：只要包含 data: 就算正常流
	if (index(t, 'data:') >= 0) return null;

	// 既不是 JSON、不是 HTML、也没有 SSE 帧 —— 无法识别，视为失败
	if (index(head, 'rate limit') >= 0 || index(head, 'too many request') >= 0)
		return '上游限流：' + substr(t, 0, 120);

	return '上游返回无法识别的响应：' + substr(t, 0, 120);
}

function onUpstreamEnd(conn) {
	if (conn.closed) return;

	// 未向客户端推送任何内容时，先判断上游是否其实失败了：
	// 失败则换下一个凭据重试，并让该凭据进入冷却。
	if (!conn.headersSent) {
		let reason = upstreamLooksFailed(conn.sseBuf);
		if (reason !== null) {
			F.tryNextCred(conn, reason);
			return;
		}
	}

	// 到这里说明上游确实产出了内容，当前凭据可用
	markCredOk(conn.credId);
	// 顺带把这次实际用成功、且上游接受的版本记下来，作为自校准依据
	if (conn.usedVersion) noteAcceptedVersion(cfg, conn.usedVersion);
	// v2.0：用量统计：非流式用 sseBuf（已含完整 JSON），流式从 SSE 尾部提取。
	let usage = extractUsage(conn.sseBuf);
	if (usage) recordUsage(conn, usage);

	if (conn.wantNonStream) {
		// v2.0：透传端点不做合并，原样回传累积内容。
		if (conn.passthrough) {
			rawResponse(conn, 200, 'application/json', conn.sseBuf, null);
			return;
		}
		jsonResponse(conn, 200, mergeChunks(conn.sseBuf));
		return;
	}
	if (!conn.headersSent)
		sseHeaders(conn);
	closeConn(conn);
}

// ---------- 并发闸门 + FIFO 排队（v1.8.0） ----------
//
// 设计取舍：
//   * 闸门键按上游分。全局单闸门会让"一个慢上游"阻塞所有上游的请求，
//     而每个上游是独立账号、独立额度，跨上游排队没有意义。
//   * 队列是同一个数组，但**放行时按各自闸门键的容量**：同键严格 FIFO
//     （顺序扫描、先到先得），跨键互不阻塞。
//   * 只在**首次**尝试前过闸门。换 Key / 换凭据的重试沿用已持有的额度
//     （conn.gateHeld 一直为真），否则重试会把自己重新排到队尾。
//   * 上限为 0 表示不限流，直接放行 —— 保留 v1.7.x 行为，出问题可一键回退。

function gateKeyOf(conn, kind) {
	return (kind === 'wb') ? 'wb' : ('up:' + conn.upstream.id);
}

function gateLimitOf(kind) {
	return (kind === 'wb') ? cfg.wbMaxInflight : cfg.upMaxInflight;
}

function gateLabel(key) {
	return (key === 'wb') ? 'WorkBuddy' : substr(key, 3);
}

// 申请额度：能进就立刻发请求，满员就进 FIFO 队列等
function gateStart(conn, kind) {
	conn.gateKind = kind;
	let key = gateKeyOf(conn, kind);
	conn.gateKey = key;

	let limit = gateLimitOf(kind);
	let cur = upInflight[key] || 0;

	if (limit === 0 || cur < limit) {
		upInflight[key] = cur + 1;
		conn.gateHeld = true;
		if (kind === 'wb') F.spawnUpstream(conn);
		else F.spawnUpstreamDirect(conn);
		return;
	}

	// 队列也有上限：无限攒请求只会让每个客户端都等到自己超时，
	// 不如立刻告诉后来者"现在忙"，让它自己退避或换上游。
	if (length(chatQueue) >= cfg.queueMax) {
		metrics.queueRejected++;
		logErr(sprintf('并发 %s 已满 %d/%d 且队列已满(%d)，直接拒绝 (client %s)',
			gateLabel(key), cur, limit, cfg.queueMax, conn.ip || '?'));
		jsonResponse(conn, 429, {
			error: {
				message: '服务繁忙：' + gateLabel(key) + ' 在途请求已达上限 ' + limit +
					'，等待队列也已满（' + cfg.queueMax + '）',
				type: 'rate_limit_error',
			},
		}, { 'Retry-After': '5' });
		return;
	}

	conn.gateHeld = false;
	conn.queuedAt = time();
	push(chatQueue, conn);
	metrics.queued++;
	logInfo(sprintf('并发 %s 已满 %d/%d，请求入队（队列深度 %d，client %s）',
		gateLabel(key), cur, limit, length(chatQueue), conn.ip || '?'));
}

// 释放额度并放行队列（由 closeConn 经 F 表调用）
function releaseGate(conn) {
	if (!conn.gateHeld) return;
	conn.gateHeld = false;
	let key = conn.gateKey;
	if (key) {
		let cur = upInflight[key] || 0;
		upInflight[key] = (cur > 0) ? cur - 1 : 0;
	}
	// 走 F 表而非直接调用：pumpQueue 定义在下面，ucode 不提升函数，
	// 直接写 pumpQueue() 会抛 undeclared variable。
	F.pumpQueue();
}

function pumpQueue() {
	if (pumpingQueue) {
		// 重入：本轮 spawn 同步失败并触发了 closeConn。
		// 只置标志让外层再扫一遍 —— 内层直接改数组会把外层的结果覆盖掉。
		queuePumpAgain = true;
		return;
	}
	pumpingQueue = true;
	// 注意：ucode 只支持 try/catch，**不支持 finally**（`} finally {` 会报
	// "Expecting 'catch'"）。所以这里不能靠 finally 复位标志，只能顺序复位。
	for (;;) {
		queuePumpAgain = false;
		let keep = [];
		let served = 0;
		for (let c in chatQueue) {
			if (c.closed || c.gateHeld) continue;
			let kind = c.gateKind;
			let key = c.gateKey;
			let limit = gateLimitOf(kind);
			let cur = upInflight[key] || 0;
			if (limit !== 0 && cur >= limit) {
				push(keep, c);
				continue;
			}
			let waited = (c.queuedAt > 0) ? (time() - c.queuedAt) : 0;
			upInflight[key] = cur + 1;
			c.gateHeld = true;
			c.queuedAt = 0;
			served++;
			logInfo(sprintf('排队请求放行 %s（等待 %ds，client %s）',
				gateLabel(key), waited, c.ip || '?'));
			if (kind === 'wb') F.spawnUpstream(c);
			else F.spawnUpstreamDirect(c);
		}
		chatQueue = keep;
		if (!queuePumpAgain || served === 0) break;
	}
	pumpingQueue = false;
}

// 排队超时扫描：等太久的直接 429 + Retry-After，不让客户端无限干等。
// 与看门狗同理，uloop.timer 是一次性的，每轮结束必须自己重排。
function queueTick() {
	if (length(chatQueue) > 0) {
		let now = time();
		let keep = [];
		for (let c in chatQueue) {
			if (c.closed || c.gateHeld) continue;
			let waited = (c.queuedAt > 0) ? (now - c.queuedAt) : 0;
			if (waited < cfg.queueTimeout) {
				push(keep, c);
				continue;
			}
			metrics.queueTimeout++;
			c.queuedAt = 0;
			logErr(sprintf('排队超时 %ds（上限 %ds），返回 429 (client %s)',
				waited, cfg.queueTimeout, c.ip || '?'));
			jsonResponse(c, 429, {
				error: {
					message: '服务繁忙：排队等待 ' + waited + ' 秒仍未获得执行额度' +
						'（上限 ' + cfg.queueTimeout + 's），请稍后重试',
					type: 'rate_limit_error',
				},
			}, { 'Retry-After': '5' });
		}
		chatQueue = keep;
	}
	queueTimer = uloop.timer(UP_QUEUE_TICK_MS, () => queueTick());
}

function handleChat(conn, bodyRaw) {
	// ---- 先定路由，再要凭据 ----
	//
	// 顺序至关重要。凭据池**只服务于 WorkBuddy 自身**；自定义上游
	// （sensenova 等）用的是它自己的 Key，与 WorkBuddy 账号无关。
	//
	// 原来这里是"一上来就查凭据池、为空即 502"，于是删掉 WorkBuddy 账号后，
	// 连明确带 sensenova/ 前缀的请求也被一并打死。用户的预期是
	// "不登 WorkBuddy 只是用不了它的免费模型，其它上游照常"——
	// 所以必须先把请求解析成"走哪条上游"，再决定要不要凭据。
	let adapted = adaptBody(bodyRaw, cfg);
	if (!adapted) {
		jsonResponse(conn, 400, { error: { message: 'invalid JSON body' } });
		return;
	}
	if (adapted.error) {
		jsonResponse(conn, 400, { error: { message: adapted.error, type: 'invalid_request_error' } });
		return;
	}

	// 归一成一个判据：非空字符串才算"路由到自定义上游"。
	// id 由 addUpstream 生成为 'u' + 时间戳，不会是空串；这里统一写法是为了
	// 避免"查凭据池"与"走自定义上游"两处用了不同语义的判断而留下隐患。
	let customUp = adapted.upstreamId;
	if (type(customUp) !== 'string' || length(customUp) === 0) customUp = null;

	// 仅当目标是本机 WorkBuddy 时才需要凭据；自定义上游不查池。
	let pool = null;
	if (customUp === null) {
		pool = usablePool(cfg);
		if (length(pool) === 0) {
			// 先区分两种"没有可用凭据"：
			//   1) 池里压根没有凭据      -> 需要登录，提示登录链接
			//   2) 凭据都在冷却/被风控   -> 说成"token 缺失"会把人引向错误方向
			//      （用户会去重新登录，但重新登录也救不回一个被风控的账号）
			let total = loadPool(cfg);
			let riskN = 0;
			let riskErr = '';
			for (let c in total) {
				let st = credState[c.id];
				if (st && isRiskControlReason(st.lastErr)) {
					riskN++;
					if (riskErr === '') riskErr = '' + st.lastErr;
				}
			}

			// 说清"这不是整体故障"。看到 502 很容易以为整个中转挂了，
			// 实际上受影响的只有 WorkBuddy 自己的模型。
			let hint = '；带前缀的其它上游模型（如 sensenova/...）不受影响，可继续调用';

			if (riskN > 0) {
				jsonResponse(conn, 502, {
					error: {
						message: 'WorkBuddy 凭据不可用：' + riskN + ' 个账号被上游风控' +
							(riskErr !== '' ? '（' + riskErr + '）' : '') +
							'，请更换账号凭据' + hint,
						type: 'account_restricted',
						credState: credSummary(total),
					},
				});
				return;
			}

			let started = startWebLogin(cfg);
			jsonResponse(conn, 502, {
				error: {
					message: 'WorkBuddy access token 缺失：' +
						(started.ok ? ('已生成登录链接（' + login.lastError + '），登录后自动生效') : login.lastError) +
						hint,
					login: started,
				},
			});
			return;
		}
	}

	// body 走临时文件，避免 JSON 内容进入命令行被 shell 解释
	// （getpid() 在本 ucode 版本不可用，用时间戳+时钟纳秒生成唯一名）
	let tmp = sprintf('/tmp/wb-req-%d-%d.json', time(), clock()[1]);
	try {
		writefile(tmp, adapted.text);
	} catch (e) {
		jsonResponse(conn, 502, { error: { message: 'temp file write failed: ' + e } });
		return;
	}

	conn.tmpFile = tmp;
	// v2.1.0：curl -D 落盘的上游响应头文件 + 请求级关联 ID。
	//   - 头文件供失败路径解析真实状态码与 Retry-After（readUpstreamStatus）
	//   - reqId 随 X-Request-Id 透传上游，并在响应头回显，日志据此串起一次请求
	conn.hdrFile = sprintf('/tmp/wb-hdr-%d-%d.txt', time(), clock()[1]);
	conn.reqId = genReqId();
	conn.wantNonStream = adapted.wantNonStream;
	conn.sseBuf = '';
	conn.sawDone = false;       // v2.1.0：流式是否已见 [DONE]（截断检测）
	conn.tries = 0;
	// 指标计时起点：从"确定要转发"算起，不含解析请求体的时间。
	// 这个字段同时是"这是一条聊天请求"的标记 —— recordConnMetrics 靠它把
	// /health、/models、管理页这些也走 closeConn 的请求排除在转发指标之外。
	conn.reqAt = nowMs();

	// v2.0：用量统计与会话粘性的客户端标识。authRequired 关闭时 apiKeyName 为空，
	// 退化为客户端 IP。
	conn.reqClient = conn.apiKeyName || conn.ip || '';
	// v2.0：会话粘性（up_sticky_sec>0 时启用）：同一客户端优先复用上次成功
	// 的那把上游 Key。无鉴权时退化为按 IP 粘性。
	conn.stickyFor = (cfg.upStickySec > 0) ? conn.reqClient : '';

	// 自定义上游：不走凭据池，改用该上游自己的 Key 轮询
	if (customUp !== null) {
		let up = null;
		let all = loadUpstreams();
		for (let u in all) if (u.id === customUp) { up = u; break; }
		if (up === null) {
			jsonResponse(conn, 404, { error: { message: 'upstream not found' } });
			return;
		}
		// 这里**不再**有"全部 Key 都在冷却 → 直接回 429"的提前返回。
		//
		// 那句话（`上游 xxx 所有 Key 均在冷却中` + `retry_after:577`）是用户实际
		// 遇到的问题：它把"某把 Key 的一次失败"放大成"整个上游对我不可用"，
		// 客户端据此退避近 10 分钟。现在一律进入转发链，
		// 由 usableUpKeys 按"健康的先轮询、失败的排后面"给出顺序，
		// 不通就换下一个，全部试完才报错。
		let keys = usableUpKeys(up, conn.stickyFor);
		if (length(keys) === 0) {
			jsonResponse(conn, 503, { error: { message: 'upstream has no key configured' } });
			return;
		}
		conn.upstream = up;
		conn.upKeys = keys;
		conn.upTry = 0;
		// 首次尝试过并发闸门；换 Key 的重试沿用已持有的额度（gateHeld）
		gateStart(conn, 'direct');
		return;
	}

	conn.tryLimit = (length(pool) < MAX_TRY) ? length(pool) : MAX_TRY;
	conn.pool = pool;

	gateStart(conn, 'wb');
}

// 挂到前向引用表上：这些函数定义在管理页代码之后，
// 但从 dispatch() 的凭据管理接口里要调用它们。
// 必须在 dispatch() 之前执行，因为请求处理会用到它们。
F.spawnUpstream = spawnUpstream;
F.tryNextCred = tryNextCred;
F.onUpstreamEnd = onUpstreamEnd;
F.runCurl = runCurl;
F.startWebLogin = startWebLogin;
// 自定义上游转发链：spawnUpstreamDirect → tryNextUpKey → spawnUpstreamDirect
F.spawnUpstreamDirect = spawnUpstreamDirect;
F.tryNextUpKey = tryNextUpKey;
F.onUpstreamDirectEnd = onUpstreamDirectEnd;
F.upstreamLooksFailed = upstreamLooksFailed;
// 并发闸门/排队：releaseGate 必须能被 closeConn() 调用，而 closeConn 定义在
// 文件很靠前的位置，只能走这张前向引用表。
F.releaseGate = releaseGate;
F.pumpQueue = pumpQueue;

// ---------- v2.0：通用端点透传 ----------
//
// 在 /v1/chat/completions（及 /chat/completions）之外的 OpenAI 兼容端点启用
// 同一转发链：/v1/embeddings、/v1/responses、/v1/images/generations 等。
// 与 chat 路径的区别（routePassthrough）：
//   * 不插 system 消息、不强制 stream=true、不做 onlyFree 检查；
//   * 只做模型前缀路由（workbuddy/xxx -> 池通道裸模型名；供应商前缀 -> 自定义上游）；
//   * 响应原样透传，不做 SSE 合并（非流式且上游返回纯 JSON 时原样回传，
//     上游返回 SSE 时也原样透传，客户端自己处理）。
//
// 为什么仍复用转发链而不是直接 curl：并发闸门、上游 Key 冷却/换 Key、
// 刹车、连接池、回环桥、看门狗、指标与用量统计全部继承，行为与 chat 一致。

function routePassthrough(body, path) {
	if (type(body) !== 'object' || body === null)
		return { error: 'invalid JSON body' };
	let upstreamId = null;
	if (type(body.model) === 'string' && length(body.model) > 0) {
		let ref = splitModelRef(body.model);
		if (ref !== null) {
			if (ref.prefix === WB_PREFIX) {
				// workbuddy/xxx -> 走本机凭据池，去掉前缀即可
				body.model = ref.model;
			} else {
				let up = findUpstreamByPrefix(ref.prefix);
				if (up === null)
					return { error: 'unknown upstream prefix: ' + ref.prefix };
				upstreamId = up.id;
				// v2.7.0：模型映射。客户端写的是对外的名字（别名或真名），
				// 这里翻译成上游认得的真名再转发。没有映射时原样透传，
				// 保证"直接写上游裸模型名"的老用法继续可用。
				let mapped = mapUpstreamModel(up, ref.model);
				if (mapped !== ref.model)
					logInfo(sprintf('model map: %s/%s -> %s', up.prefix, ref.model, mapped));
				body.model = mapped;
			}
		}
	}
	// 非流式判定：显式 stream=true 才是流式；其余（含 stream:false 或缺省）
	// 一律按非流式透传（上游返回什么就回什么，不强制改造成 SSE）。
	let wantNonStream = (body.stream !== true);
	return {
		text: sprintf('%.J', body),
		wantNonStream: wantNonStream,
		upstreamId: upstreamId,
	};
}

// 透传入口：与 handleChat 相同的准备（临时文件/路由/闸门），但 body 不改造。
function handlePassthrough(conn, bodyRaw, path) {
	let body = null;
	try {
		body = json(bodyRaw);
	} catch (e) {
		body = null;
	}
	let adapted = routePassthrough(body, path);
	if (adapted === null) {
		jsonResponse(conn, 400, { error: { message: 'invalid JSON body' } });
		return;
	}
	if (adapted.error) {
		jsonResponse(conn, 400, { error: { message: adapted.error } });
		return;
	}

	let customUp = adapted.upstreamId;

	// 准备阶段与 handleChat 共用：临时文件、计时起点、粘性/用量标识。
	let tmp = sprintf('/tmp/wb-req-%d-%d.json', time(), clock()[1]);
	try {
		writefile(tmp, adapted.text);
	} catch (e) {
		jsonResponse(conn, 502, { error: { message: 'temp file write failed: ' + e } });
		return;
	}
	conn.tmpFile = tmp;
	// v2.1.0：curl -D 落盘的上游响应头文件 + 请求级关联 ID。
	//   - 头文件供失败路径解析真实状态码与 Retry-After（readUpstreamStatus）
	//   - reqId 随 X-Request-Id 透传上游，并在响应头回显，日志据此串起一次请求
	conn.hdrFile = sprintf('/tmp/wb-hdr-%d-%d.txt', time(), clock()[1]);
	conn.reqId = genReqId();
	conn.wantNonStream = adapted.wantNonStream;
	conn.sseBuf = '';
	conn.sawDone = false;       // v2.1.0：流式是否已见 [DONE]（截断检测）
	conn.tries = 0;
	conn.reqAt = nowMs();
	conn.reqClient = conn.apiKeyName || conn.ip || '';
	conn.stickyFor = (cfg.upStickySec > 0) ? conn.reqClient : '';
	// v2.0：透传标记。转发链据此：
	//   1) URL 用 conn.targetPath（默认 /chat/completions）代替写死的路径；
	//   2) 收尾时原样透传（不 mergeChunks）。
	conn.passthrough = true;
	conn.targetPath = path;

	if (customUp !== null) {
		let up = null;
		let all = loadUpstreams();
		for (let u in all) if (u.id === customUp) { up = u; break; }
		if (up === null) {
			jsonResponse(conn, 404, { error: { message: 'upstream not found' } });
			return;
		}
		let keys = usableUpKeys(up, conn.stickyFor);
		if (length(keys) === 0) {
			jsonResponse(conn, 503, { error: { message: 'upstream has no key configured' } });
			return;
		}
		conn.upstream = up;
		conn.upKeys = keys;
		conn.upTry = 0;
		gateStart(conn, 'direct');
		return;
	}

	// 池通道：与 handleChat 相同的凭据池 + 闸门。
	// 注意：usablePool 必须传 cfg（loadPool 会经 getToken 访问 cfg.token_file），
	// 漏传会在 tokenPath 里对 null 取属性，直接抛 "left-hand side expression is null"。
	let pool = usablePool(cfg);
	if (length(pool) === 0) {
		jsonResponse(conn, 502, { error: { message: 'WorkBuddy credentials unavailable' } });
		return;
	}
	conn.tryLimit = (length(pool) < MAX_TRY) ? length(pool) : MAX_TRY;
	conn.pool = pool;
	gateStart(conn, 'wb');
}

// ---------- 管理页 ----------
//
// 独立的单页管理界面，直接由本服务提供，不依赖 LuCI：
//   GET  /admin           登录页或管理页
//   POST /admin/login     校验密码，下发会话 Cookie
//   GET  /admin/logout    清除会话
//   GET  /admin/api/state 管理页所需的全部数据
//   POST /admin/api/*     管理操作
//
// 页面全部内联，不引用任何 CDN：路由器可能没有稳定外网，也没有构建步骤。

function htmlEscape(s) {
	let out = '';
	let str = '' + s;
	for (let i = 0; i < length(str); i++) {
		let c = substr(str, i, 1);
		if (c === '&') out += '&amp;';
		else if (c === '<') out += '&lt;';
		else if (c === '>') out += '&gt;';
		else if (c === '"') out += '&quot;';
		else if (c === "'") out += '&#39;';
		else out += c;
	}
	return out;
}

// 管理页的 CSS。深色主题，响应式，无外部依赖。
function adminCss() {
	return `
:root{
  --bg:#0f1115; --panel:#171a21; --panel2:#1e222b; --line:#2a2f3a;
  --fg:#e6e9ef; --dim:#9aa4b2; --accent:#4c8dff; --accent2:#3a6fd8;
  --ok:#35c26b; --warn:#e0a83a; --err:#e5544b;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans CJK SC","Microsoft YaHei",sans-serif}
a{color:var(--accent);text-decoration:none}
.wrap{max-width:1080px;margin:0 auto;padding:20px}
header{display:flex;align-items:center;gap:12px;padding:16px 20px;
  background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:17px;margin:0;font-weight:600;letter-spacing:.3px}
header .sp{flex:1}
.badge{font-size:12px;padding:2px 9px;border-radius:99px;border:1px solid var(--line);
  background:var(--panel2);color:var(--dim)}
.badge.ok{color:var(--ok);border-color:#1e4a30}
.badge.err{color:var(--err);border-color:#4a201e}
.badge.warn{color:var(--warn);border-color:#4a3d1e}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
  padding:18px;margin-bottom:16px}
.card h2{font-size:14px;margin:0 0 4px;font-weight:600}
.card .desc{color:var(--dim);font-size:12.5px;margin:0 0 14px}
label{display:block;font-size:12.5px;color:var(--dim);margin-bottom:5px}
input[type=text],input[type=password],input[type=number],select,textarea{
  width:100%;padding:9px 11px;background:var(--bg);color:var(--fg);
  border:1px solid var(--line);border-radius:7px;font-size:13.5px;font-family:inherit}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent)}
textarea{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;resize:vertical}
.row{display:flex;gap:12px;flex-wrap:wrap}
.row>div{flex:1;min-width:190px}
.field{margin-bottom:14px}
button{cursor:pointer;border:1px solid var(--line);background:var(--panel2);color:var(--fg);
  padding:8px 15px;border-radius:7px;font-size:13px;font-family:inherit;transition:.15s}
button:hover{border-color:var(--accent)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:500}
button.primary:hover{background:var(--accent2)}
button.danger{color:var(--err);border-color:#4a201e}
button.danger:hover{background:#2a1614}
button:disabled{opacity:.5;cursor:not-allowed}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line)}
th{color:var(--dim);font-weight:500;font-size:12px}
tr:last-child td{border-bottom:none}
code,.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}
.kv{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--line)}
.kv:last-child{border-bottom:none}
.kv .k{color:var(--dim)}
.toast{position:fixed;right:18px;bottom:18px;z-index:99;display:flex;flex-direction:column;gap:8px}
.toast div{padding:11px 15px;border-radius:8px;background:var(--panel2);
  border:1px solid var(--line);box-shadow:0 6px 22px rgba(0,0,0,.45);font-size:13px;
  animation:sl .2s ease}
.toast div.ok{border-color:#1e4a30;color:#9fe8bd}
.toast div.err{border-color:#4a201e;color:#ffb3ae}
@keyframes sl{from{transform:translateX(14px);opacity:0}to{transform:none;opacity:1}}
.login{max-width:370px;margin:11vh auto;padding:0 20px}
.login .card{padding:26px}
.login h1{font-size:19px;margin:0 0 6px;font-weight:600}
.login p.sub{color:var(--dim);font-size:13px;margin:0 0 20px}
.keybox{background:var(--bg);border:1px solid var(--line);border-radius:7px;
  padding:9px 11px;display:flex;align-items:center;gap:9px}
.keybox code{flex:1;overflow-x:auto;white-space:nowrap;color:#9fe8bd}
.tabs{display:flex;gap:4px;margin-bottom:16px;flex-wrap:wrap}
.tabs button{border-radius:7px}
.tabs button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.hide{display:none!important}
.hint{color:var(--dim);font-size:12px;margin-top:7px}
.sw{position:relative;display:inline-block;width:38px;height:21px;vertical-align:middle}
.sw input{opacity:0;width:0;height:0}
.sw span{position:absolute;inset:0;background:#39404d;border-radius:99px;transition:.2s}
.sw span:before{content:"";position:absolute;width:15px;height:15px;left:3px;top:3px;
  background:#fff;border-radius:50%;transition:.2s}
.sw input:checked+span{background:var(--ok)}
.sw input:checked+span:before{transform:translateX(17px)}
/* 自定义上游卡片：地址/前缀/Key 都要能一眼看清，所以用卡片式而非表格 */
.upcard{background:var(--bg);border:1px solid var(--line);border-radius:9px;
  padding:13px 15px;margin-bottom:11px}
/* 内置服务器（WorkBuddy 自身）用左侧色条区分，且不可删除 */
.upcard.builtin{border-left:3px solid var(--accent)}
/* 弹层：改 Key 时粘贴多行内容，必须给足空间 */
.modal-mask{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:99;
  display:flex;align-items:center;justify-content:center;padding:20px}
.modal-mask .modal{background:var(--card);border:1px solid var(--line);
  border-radius:11px;padding:19px 21px;width:100%;max-width:560px;
  max-height:86vh;overflow-y:auto}
.modal-mask h3{margin:0 0 12px;font-size:15px}
.modal-mask textarea{width:100%;box-sizing:border-box;font-family:ui-monospace,Menlo,monospace}
.modal-foot{display:flex;gap:9px;justify-content:flex-end;margin-top:15px}
.uphead{margin-bottom:9px;font-size:14px}
.uprow{display:flex;gap:9px;align-items:flex-start;margin:5px 0;font-size:13px}
.uprow .lbl{color:var(--dim);min-width:66px;flex:0 0 66px}
/* 公网访问的风险提示框：只在开关打开时显示，用暖色区别于普通 hint */
.warnbox{background:#2a2113;border:1px solid #5a4520;border-radius:8px;
  padding:11px 14px;margin:11px 0;font-size:13px;color:#f0d9a8}
.warnbox strong{color:#ffd479}
.warnbox ul{margin:7px 0 0;padding-left:19px}
.warnbox li{margin:3px 0}
.uprow code{background:#1b2029;border:1px solid var(--line);border-radius:5px;
  padding:2px 7px;color:#9fe8bd;word-break:break-all}
.uprow .badge{margin-right:4px}

/* 添加凭据：两种方式并排，窄屏自动堆叠 */
.addbox{display:flex;gap:18px;flex-wrap:wrap;margin-top:6px}
.addcol{flex:1 1 300px;min-width:0;background:var(--bg);border:1px solid var(--line);
  border-radius:9px;padding:14px}
.addcol h3{margin:0 0 6px;font-size:14px;font-weight:600}
.addcol .field{margin-top:10px}
.loginbox{margin-top:12px;padding-top:12px;border-top:1px dashed var(--line)}
.linkbtn{display:inline-block;color:var(--accent);text-decoration:none;font-size:13px;
  padding:6px 0;word-break:break-all}
.linkbtn:hover{text-decoration:underline}
textarea{width:100%;background:var(--bg);border:1px solid var(--line);border-radius:7px;
  color:var(--fg);padding:9px 11px;font-family:monospace;font-size:12px;resize:vertical}
textarea:focus{outline:none;border-color:var(--accent)}
button:disabled{opacity:.5;cursor:not-allowed}
.badge.err{color:var(--err)}

@media(max-width:640px){
  .wrap{padding:12px} .card{padding:14px} header{padding:12px}
  th:nth-child(3),td:nth-child(3){display:none}
  .addcol{flex:1 1 100%}
}
`;
}

// 登录页
function adminLoginPage(msg) {
	return `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${APP_NAME} · 管理登录</title>
<style>${adminCss()}</style>
</head><body>
<div class="login">
  <div class="card">
    <h1>${APP_NAME}</h1>
    <p class="sub">请输入管理员密码</p>
    ${msg ? `<div class="badge err" style="display:block;padding:8px 11px;margin-bottom:14px">${htmlEscape(msg)}</div>` : ''}
    <form method="POST" action="/admin/login" id="f">
      <div class="field">
        <label for="pw">管理员密码</label>
        <input type="password" id="pw" name="password" autocomplete="current-password" autofocus>
      </div>
      <button class="primary" style="width:100%" id="btn" type="submit">登录</button>
    </form>
    <p class="hint">密码在「LuCI → 服务 → AI 中转服务器 → 管理页密码」中设置。</p>
  </div>
</div>
<script>
document.getElementById('f').addEventListener('submit',function(){
  var b=document.getElementById('btn'); b.disabled=true; b.textContent='登录中…';
});
</script>
</body></html>`;
}

// 管理页主体
function adminAppPage() {
	return `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${APP_NAME} · 管理</title>
<style>${adminCss()}</style>
</head><body>
<header>
  <h1>${APP_NAME}</h1>
  <span class="badge" id="bVer">—</span>
  <span class="sp"></span>
  <button onclick="load()">刷新</button>
  <button class="danger" onclick="logout()">退出</button>
</header>
<div class="wrap">

  <div class="tabs">
    <button class="on" data-t="ov" onclick="tab('ov')">概览</button>
    <button data-t="keys" onclick="tab('keys')">API 密钥</button>
    <button data-t="ups" onclick="tab('ups')">服务器管理</button>
    <button data-t="creds" onclick="tab('creds')">凭据池</button>
    <button data-t="relay" onclick="tab('relay')">中转日志</button>
    <button data-t="cfg" onclick="tab('cfg')">设置</button>
  </div>

  <div id="t-ov">
    <div class="card">
      <h2>运行状态</h2>
      <p class="desc">服务当前状态与生效范围</p>
      <div id="ovBody">加载中…</div>
    </div>
    <div class="card">
      <h2>可用模型</h2>
      <p class="desc" id="mDesc"></p>
      <div id="mBody">加载中…</div>
    </div>
  </div>

  <div id="t-keys" class="hide">
    <div class="card">
      <h2>API 密钥</h2>
      <p class="desc">密钥可随时查看与复制；吊销后立即失效。请求时通过
        <code>Authorization: Bearer &lt;密钥&gt;</code> 或 <code>X-API-Key</code> 头提交。</p>
      <div class="field">
        <label for="nkName">新建密钥名称</label>
        <div class="row">
          <div><input type="text" id="nkName" placeholder="例如：家里电脑"></div>
          <div style="flex:0"><button class="primary" onclick="addKey()">生成密钥</button></div>
        </div>
      </div>
      <div id="keysBody">加载中…</div>
    </div>
  </div>

  <div id="t-ups" class="hide">
    <div class="card">
      <h2>服务器列表</h2>
      <p class="desc">每台服务器 = 一个 API 地址 + 一组 Key。组内 Key 自动轮询做负载均衡，
        失效的 Key 进入冷却并被跳过。模型以 <code>前缀/模型名</code> 形式出现在
        <code>/v1/models</code>，客户端据此选择走哪台服务器。</p>
      <div id="upBody">加载中…</div>
    </div>

    <div class="card">
      <h2>添加服务器</h2>
      <p class="desc">填一个 API 地址 + 一批 Key 即可接入。Key 每行一条，支持一次粘贴多条，
        服务端会自动去重；某条 Key 失效会被自动跳过并进入冷却。</p>

      <div class="field">
        <label for="upName">服务器名称</label>
        <input type="text" id="upName" placeholder="例如：日日新">
      </div>

      <div class="field">
        <label for="upPrefix">模型前缀</label>
        <input type="text" id="upPrefix" placeholder="例如：sensenova">
        <p class="hint">只能用小写字母、数字、<code>-</code>、<code>_</code>，长度 2–32。
          客户端里模型名会写成 <code>前缀/模型名</code>，用前缀区分不同服务器。</p>
      </div>

      <div class="field">
        <label for="upUrl">服务器 API 地址</label>
        <input type="text" id="upUrl" placeholder="https://token.sensenova.cn/v1">
        <p class="hint">填到 <code>/v1</code> 为止，本服务会自动拼接
          <code>/chat/completions</code> 与 <code>/models</code>。</p>
      </div>

      <div class="field">
        <label for="upKeys">API Key 密钥（每行一条，可批量粘贴）</label>
        <textarea id="upKeys" rows="5" placeholder="sk-xxxxxxxx&#10;sk-yyyyyyyy&#10;sk-zzzzzzzz"></textarea>
        <p class="hint">所有 Key 组成一个池子，请求时轮流使用，实现负载均衡。</p>
      </div>

      <div class="field">
        <label for="upModels">模型映射（可选）</label>
        <textarea id="upModels" rows="4" placeholder="每行一条：&#10;deepseek-v4-flash&#10;gpt-4o=glm-5.2&#10;# 井号开头是注释"></textarea>
        <p class="hint"><code>别名=真名</code> 表示对外用别名、转发时换成真名；只写
          <code>真名</code> 表示照原样暴露。<strong>留空则自动使用上游返回的模型列表。</strong>
          填了以后 <code>/v1/models</code> 以这里为准，上游临时不可用也不会让列表变空。</p>
      </div>

      <button class="primary" onclick="addUpstreamUI()">添加服务器</button>
    </div>
  </div>

  <div id="t-creds" class="hide">
    <div class="card">
      <h2>凭据池</h2>
      <p class="desc">多个账号轮询使用，某个账号被限流时自动冷却并切换到其他账号。
        同一账号只会保留一条，重复添加会被自动拦截。</p>
      <p class="hint">要清掉某个账号，用表格右侧的删除按钮：「网页登录凭据」那一行的
        <b>删除账号</b>会把本机保存的登录凭据一并删掉（不可撤销），之后可用下方
        「登录并添加账号」换一个新账号。</p>
      <div id="credsBody">加载中…</div>
    </div>

    <div class="card">
      <h2>添加凭据</h2>
      <p class="desc">两种方式：登录 WorkBuddy 账号自动获取，或手动粘贴已有 access token。</p>

      <div class="addbox">
        <div class="addcol">
          <h3>方式一 · 登录账号获取</h3>
          <p class="hint">点击后在浏览器打开授权链接，登录完成后凭据会自动加入池中。</p>
          <button class="primary" id="btnLogin" onclick="startLogin()">登录并添加账号</button>

          <div id="loginBox" class="hide loginbox">
            <div class="row" style="gap:8px;align-items:center">
              <div style="flex:1;min-width:0">
                <a id="loginLink" href="#" target="_blank" rel="noopener noreferrer"
                   class="linkbtn">打开授权链接</a>
              </div>
              <div style="flex:0"><button onclick="copyText(document.getElementById('loginUrl').value)">复制链接</button></div>
            </div>
            <input type="text" id="loginUrl" readonly style="margin-top:8px;font-size:12px">
            <p class="hint" id="loginHint">等待授权中…</p>
          </div>
        </div>

        <div class="addcol">
          <h3>方式二 · 手动添加 token</h3>
          <p class="hint">粘贴 access token（JWT 串）。可直接粘贴 <code>Bearer xxx</code>，会自动去掉前缀。</p>
          <div class="field">
            <label for="ncName">名称（留空则用账号名）</label>
            <input type="text" id="ncName" placeholder="例如：备用账号">
          </div>
          <div class="field">
            <label for="ncToken">Access Token</label>
            <textarea id="ncToken" rows="3" placeholder="eyJhbGciOiJS..."></textarea>
          </div>
          <button class="primary" onclick="addCred()">添加到凭据池</button>
        </div>
      </div>
    </div>
  </div>

  <div id="t-relay" class="hide">
    <div class="card">
      <h2>中转轮换分析</h2>
      <p class="desc">按账号统计的轮换质量：每个账号被选中多少次、成功/限流/风控/鉴权/客户端/网络各多少次，
        以及累计冷却时长占比。这些数字就是调轮换规则的依据——例如某个账号
        <b>限流率</b>长期偏高，就该把它权重调低；<b>冷却占比</b>接近 100% 说明它基本不可用。</p>
      <p class="hint">统计自进程启动（或上次重置）起累计，只存在内存里，重启即清零。</p>
      <div id="relayBody">加载中…</div>
    </div>

    <div class="card">
      <h2>最近中转事件</h2>
      <p class="desc">最新 40 条。排障时先看这里：连着几条 <code>cool</code> 说明上游在限流，
        出现 <code>switch</code> 说明已经换号，出现 <code>exhaust</code> 说明所有账号都试过了。</p>
      <div id="relayEvents">加载中…</div>
      <div class="row" style="margin-top:12px">
        <button onclick="resetRelay()">重置统计</button>
      </div>
    </div>
  </div>

  <div id="t-cfg" class="hide">
    <div class="card">
      <h2>服务设置</h2>
      <p class="desc">修改后立即生效，写入路由器配置。</p>
      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cFree"><span></span></span>
          <span>仅使用免费模型（避免产生费用）</span>
        </label>
        <p class="hint">开启后，请求收费模型会被自动替换为免费模型。</p>
      </div>
      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cAutoVer"><span></span></span>
          <span>自动获取客户端版本</span>
        </label>
        <p class="hint">关闭后可手动指定版本号。</p>
      </div>
      <div class="field" id="verWrap">
        <label for="cVer">客户端版本</label>
        <input type="text" id="cVer" placeholder="5.5.2">
      </div>
      <button class="primary" onclick="saveCfg()">保存设置</button>
    </div>

    <div class="card">
      <h2>每日模型巡检</h2>
      <p class="desc">每天定时拉取所有启用上游的最新模型列表，并逐个验证模型可用性。</p>
      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cModelRefresh"><span></span></span>
          <span>启用每日模型巡检</span>
        </label>
        <p class="hint">关闭后仍可在「自定义服务器」点「测试全部模型」手动巡检。</p>
      </div>
      <div class="field">
        <label for="cModelHour">每日刷新时间（小时）</label>
        <input type="number" id="cModelHour" min="0" max="23" placeholder="1">
        <p class="hint">到点后自动拉取最新模型并测试连通性，结果写入系统日志。默认凌晨 1 点。</p>
      </div>
      <button class="primary" onclick="saveCfg()">保存设置</button>
    </div>
      <p class="desc">默认只允许局域网访问。打开后，外网可直连本服务。</p>

      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cWan"><span></span></span>
          <span>允许公网调用管理页与 API</span>
        </label>
        <p class="hint" id="wanState">检测中…</p>
      </div>

      <div class="field">
        <label for="cWanPort">公网端口（外部访问端口）</label>
        <input type="number" id="cWanPort" min="1" max="65535" placeholder="留空跟随内部端口">
        <p class="hint">外网用这个端口访问，转发到本机内部端口
          <code id="wanInnerPort">—</code>。改个不显眼的端口（如 <code>18789</code>）
          能降低被扫描概率。留空则内外端口一致。</p>
      </div>

      <div class="warnbox" id="wanWarn">
        <strong>开放公网意味着：</strong>
        <ul>
          <li>任何人都能访问 <code>http://&lt;你的公网IP&gt;:<span id="wanWarnPort">8789</span>/admin</code> 的登录界面</li>
          <li>API 仍受 API 密钥保护，管理页仍受管理员密码保护 —— 但请确认两者都足够强</li>
          <li>建议同时确认路由器本身没有被运营商封禁该端口</li>
        </ul>
      </div>

      <p class="hint">本开关会自动在「网络 → 防火墙 → 端口转发」中创建/移除规则
        <code>workbuddy_wan</code>，无需手工配置。关闭后规则会被立即删除。</p>
      <button class="primary" onclick="saveWan()">保存公网设置</button>
    </div>
  </div>

</div>
<div class="toast" id="toast"></div>
<div class="modal-mask hide" id="modal">
  <div class="modal">
    <h3 id="modalTitle"></h3>
    <div id="modalBody"></div>
  </div>
</div>
<script>
var S = null;

function toast(msg, kind) {
  var d = document.createElement('div');
  d.className = kind || '';
  d.textContent = msg;
  document.getElementById('toast').appendChild(d);
  setTimeout(function(){ d.remove(); }, 3200);
}

function api(path, body) {
  var opt = { method: body ? 'POST' : 'GET', headers: {}, credentials: 'same-origin' };
  if (body) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  return fetch('/admin/api/' + path, opt).then(function(r) {
    if (r.status === 401) { location.href = '/admin'; throw new Error('会话已过期'); }
    return r.json();
  });
}

function tab(name) {
  var names = ['ov','keys','ups','creds','relay','cfg'];
  for (var i = 0; i < names.length; i++) {
    document.getElementById('t-' + names[i]).className = (names[i] === name) ? '' : 'hide';
  }
  var btns = document.querySelectorAll('.tabs button');
  for (var j = 0; j < btns.length; j++) {
    btns[j].className = (btns[j].getAttribute('data-t') === name) ? 'on' : '';
  }
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}

function load() {
  api('state').then(function(d) {
    S = d;
    document.getElementById('bVer').textContent = 'v' + d.version;
    renderOv(d); renderModels(d); renderKeys(d); renderCreds(d); renderUpstreams(d); renderRelay(d); renderCfg(d); renderWan(d);

    // 如果服务端还有一个登录流程在等授权（比如页面被刷新过），
    // 就恢复显示并接着轮询，不要让它变成"看不见的后台任务"。
    if (d.login && d.login.running) {
      document.getElementById('btnLogin').disabled = true;
      document.getElementById('loginBox').className = 'loginbox';
      document.getElementById('loginUrl').value = d.login.authUrl || '';
      document.getElementById('loginLink').href = d.login.authUrl || '#';
      document.getElementById('loginHint').textContent =
        '已有登录流程在进行中，等待授权… 剩余 ' + d.login.remain + ' 秒';
      if (!loginTimer) pollLogin();
    }
  }).catch(function(e) { toast('加载失败：' + e.message, 'err'); });
}

function renderOv(d) {
  var h = '';
  function kv(k, v) { h += '<div class="kv"><span class="k">' + k + '</span><span>' + v + '</span></div>'; }
  kv('服务状态', d.enabled ? '<span class="badge ok">运行中</span>' : '<span class="badge err">已停用</span>');
  kv('监听端口', '<code>' + esc(d.host) + ':' + d.port + '</code>');
  kv('上游地址', '<code>' + esc(d.endpoint) + '</code>');
  kv('凭据数量', d.credentials);
  kv('API 密钥', d.keysActive + ' 启用 / ' + d.keysTotal + ' 总数');
  kv('模型范围', d.onlyFreeModels ? '<span class="badge ok">仅免费</span>' : '<span class="badge warn">全部模型（可能收费）</span>');
  kv('客户端版本', '<code>' + esc(d.clientVersion) + '</code>' + (d.autoVersion ? ' <span class="badge">自动</span>' : ' <span class="badge">手动</span>'));
  kv('管理页', d.adminEnabled ? '<span class="badge ok">已设密码</span>' : '<span class="badge err">未设密码</span>');
  document.getElementById('ovBody').innerHTML = h;
}

// 可用模型面板。
// 说明：这个函数曾经缺失，导致 #mBody 永远停在「加载中…」——
// 服务端 state 一直在正常返回 models 数组，只是前端没人渲染它。
function renderModels(d) {
  var box = document.getElementById('mBody');
  var desc = document.getElementById('mDesc');
  var list = (d && d.models) || [];

  if (desc) {
    desc.textContent = d && d.onlyFreeModels
      ? '当前仅允许免费额度模型（x0.00 积分）。请求收费模型会被自动替换。'
      : '当前允许全部模型，包含计费模型。';
  }

  if (!list.length) {
    box.innerHTML =
      '<p class="hint">上游没有返回可用模型。可能是凭据失效或网络不通，' +
      '可到「凭据池」点「测试」确认。</p>';
    return;
  }

  // 免费模型集合：与后端 FREE_MODELS 保持一致，用于打标
  var FREE = ['deepseek-v4.1-flash', 'hy4-preview-f', 'hy3'];

  var h = '<table><thead><tr><th>模型 ID</th><th>名称</th><th>计费</th><th></th></tr></thead><tbody>';
  for (var i = 0; i < list.length; i++) {
    var m = list[i];
    var id = m && m.id ? String(m.id) : '';
    var nm = m && m.name ? String(m.name) : '';
    var isFree = FREE.indexOf(id) >= 0;
    h += '<tr><td><code>' + esc(id) + '</code></td>' +
         '<td>' + (nm ? esc(nm) : '<span style="opacity:.5">—</span>') + '</td>' +
         '<td>' + (isFree
            ? '<span class="badge ok">免费</span>'
            : '<span class="badge warn">计费</span>') + '</td>' +
         '<td style="white-space:nowrap">' +
         '<button onclick="copyText(\\'' + esc(id) + '\\')">复制 ID</button>' +
         '</td></tr>';
  }
  h += '</tbody></table>';

  if (d && d.onlyFreeModels) {
    h += '<p class="hint" style="margin-top:10px">共 ' + list.length +
         ' 个可用模型。已开启「仅免费模型」，计费模型不会出现在 ' +
         '<code>/v1/models</code> 响应中。</p>';
  } else {
    h += '<p class="hint" style="margin-top:10px">共 ' + list.length +
         ' 个模型。<span class="badge warn">注意</span> 未开启「仅免费模型」，' +
         '调用计费模型会产生费用。</p>';
  }

  box.innerHTML = h;
}

function renderKeys(d) {
  if (!d.keys || !d.keys.length) {
    document.getElementById('keysBody').innerHTML =
      '<p class="hint">还没有密钥。未设置密钥时，代理对所有请求开放鉴权检查。</p>';
    return;
  }
  var h = '<table><thead><tr><th>名称</th><th>密钥</th><th>状态</th><th></th></tr></thead><tbody>';
  for (var i = 0; i < d.keys.length; i++) {
    var k = d.keys[i];
    h += '<tr><td>' + esc(k.name) + '</td>' +
         '<td><div class="keybox"><code>' + esc(k.key) + '</code>' +
         '<button onclick="copyKey(this,\\'' + esc(k.key) + '\\')">复制</button></div></td>' +
         '<td>' + (k.enabled ? '<span class="badge ok">启用</span>' : '<span class="badge">禁用</span>') + '</td>' +
         '<td style="white-space:nowrap">' +
         '<button onclick="toggleKey(\\'' + esc(k.id) + '\\',' + (k.enabled ? 'false' : 'true') + ')">' +
         (k.enabled ? '禁用' : '启用') + '</button> ' +
         '<button class="danger" onclick="delKey(\\'' + esc(k.id) + '\\',\\'' + esc(k.name) + '\\')">吊销</button>' +
         '</td></tr>';
  }
  h += '</tbody></table>';
  document.getElementById('keysBody').innerHTML = h;
}

// 服务器列表。每台服务器一张卡：地址、前缀、Key 数、可用数。
// 模型名前缀是路由依据，所以必须显眼展示，用户才知道客户端该填什么。
//
// 第一张卡固定是内置的 WorkBuddy 服务器（走凭据池，不是 Key 池）。
// 它不能被删除，所以不渲染删除按钮 —— 删掉它免费模型与凭据池就没入口了。
function renderUpstreams(d) {
  var box = document.getElementById('upBody');
  if (!box) return;
  var list = d.upstreams || [];
  var wb = d.wbPrefix || 'workbuddy';
  var creds = (d.credentials != null ? d.credentials : 0);

  var h = '';

  // ---- 内置服务器：WorkBuddy 自身 ----
  h += '<div class="upcard builtin">';
  h += '<div class="uphead"><strong>WorkBuddy</strong> ';
  h += '<span class="badge ok">内置</span> ';
  h += (d.hasToken ? '<span class="badge ok">已登录</span>' : '<span class="badge err">未登录</span>');
  h += '<span class="badge">' + creds + ' 个账号</span>';
  h += '</div>';
  h += '<div class="uprow"><span class="lbl">模型前缀</span><code>' + esc(wb) + '/</code></div>';
  h += '<div class="uprow"><span class="lbl">服务器</span><code>' + esc(d.endpoint || '—') + '</code></div>';
  h += '<div class="uprow"><span class="lbl">Key 池</span><span class="badge">账号凭据池（见「凭据池」页）</span></div>';
  h += '<div class="uprow"><span class="lbl">操作</span><span style="white-space:nowrap">';
  h += '<button onclick="tab(\\'creds\\')">管理账号</button>';
  h += '</span></div>';
  h += '</div>';

  // ---- 自定义服务器 ----
  if (!list.length) {
    h += '<p class="hint">还没有自定义服务器。用下面的表单添加：' +
      '填一个 API 地址 + 一批 Key，即可与本机的 WorkBuddy 一起对外提供模型。</p>';
  }

  for (var i = 0; i < list.length; i++) {
    var u = list[i];

    h += '<div class="upcard">';
    h += '<div class="uphead"><strong>' + esc(u.name) + '</strong> ';
    h += u.enabled ? '<span class="badge ok">启用</span>' : '<span class="badge">已停用</span>';
    h += '<span class="badge">' + u.keyUsable + '/' + u.keyCount + ' Key 可用</span>';
    h += '</div>';

    // 前缀 + 地址：这两个是用户配置客户端时要抄的
    h += '<div class="uprow"><span class="lbl">模型前缀</span><code>' + esc(u.prefix) + '/</code></div>';
    h += '<div class="uprow"><span class="lbl">服务器</span><code>' + esc(u.baseUrl) + '</code></div>';
    // v2.9.4（用户 m17405）：显示**实际获取到的模型名**，不只是数量。
    // 只显示计数等于没显示 —— 用户要核对的是"客户端里能填哪几个名字"。
    // 优先用上游真实模型清单（detectedModels，来自上游 /v1/models 现场获取），
    // 其次是用户自定义映射；两者都带上前缀，照抄即可用。
    var ml = (u.detectedModels && u.detectedModels.length) ? u.detectedModels : null;
    if (!ml && u.modelsText) {
      ml = u.modelsText.split('\\n');
    }
    if (ml && ml.length) {
      h += '<div class="uprow"><span class="lbl">可用模型</span><span>';
      var nShow = 0;
      for (var mi = 0; mi < ml.length; mi++) {
        var m = '' + ml[mi];
        if (!m) continue;
        if (nShow >= 24) { h += '<span class="badge">…共 ' + ml.length + ' 个</span>'; break; }
        h += '<span class="badge">' + esc(u.prefix + '/' + m) + '</span>';
        nShow++;
      }
      h += '</span></div>';
    } else {
      h += '<div class="uprow"><span class="lbl">可用模型</span><span class="badge">未获取（首次请求 /v1/models 时自动拉取）</span></div>';
    }

    // Key 明细（掩码）+ v2.0 权重/用量 + v2.5.0 单 Key 管理入口
    if (u.keys && u.keys.length) {
      h += '<div class="uprow"><span class="lbl">Key 池</span><span>';
      for (var j = 0; j < u.keys.length; j++) {
        var k = u.keys[j];
        var kTip = '权重 ' + k.weight + (k.usageText ? '，用量 ' + k.usageText : '') +
                   '\\n点击可单独启停 / 改权重';
        var kCls = k.disabled ? 'badge' : (k.cooling > 0 ? 'badge warn' : 'badge ok');
        var kTxt = esc(k.masked);
        if (k.disabled) kTxt += ' 已停用';
        else if (k.cooling > 0) kTxt += ' 冷却 ' + k.cooling + 's';
        else if (k.weight > 1) kTxt += ' ×' + k.weight;
        h += '<span class="' + kCls + '" style="cursor:pointer" ' +
             'title="' + esc(kTip) + '" ' +
             'onclick="editUpKey(\\'' + esc(u.id) + '\\',\\'' + esc(k.masked) + '\\')">' +
             kTxt + '</span> ';
      }
      h += '</span></div>';
    }

    // v2.0：上游累计用量
    h += '<div class="uprow"><span class="lbl">用量</span><code>' +
         esc(u.usageText || '0/0/0') + ' tokens</code></div>';

    h += '<div class="uprow"><span class="lbl">操作</span><span style="white-space:nowrap">';
    h += '<button onclick="testUp(\\'' + esc(u.id) + '\\')">测试</button> ';
    h += '<button onclick="editUpInfo(\\'' + esc(u.id) + '\\')">编辑服务器</button> ';
    h += '<button onclick="editUpKeys(\\'' + esc(u.id) + '\\')">改 Key</button> ';
    h += '<button onclick="toggleUp(\\'' + esc(u.id) + '\\',' + (u.enabled ? 'false' : 'true') + ')">' +
         (u.enabled ? '停用' : '启用') + '</button> ';
    h += '<button class="danger" onclick="delUp(\\'' + esc(u.id) + '\\',\\'' + esc(u.name) + '\\')">删除</button>';
    h += '</span></div>';

    h += '</div>';
  }

  // v2.8.0：批量测试所有启用上游的每个模型是否真正可用
  h += '<div class="uprow"><span class="lbl">批量操作</span><span style="white-space:nowrap">';
  h += '<button onclick="testAllUp()">测试全部模型</button> ';
  h += '<span id="upTestAllStatus" class="hint">对每个启用上游的模型发最小请求验证可用性</span>';
  h += '</span></div>';

  h += '<p class="hint">客户端里模型名写成 <code>前缀/模型名</code>。' +
       '本机 WorkBuddy 的前缀固定为 <code>' + esc(wb) + '/</code>，' +
       '其余用各自服务器配置的前缀。</p>';

  box.innerHTML = h;
}

// v2.8.0：调用 /admin/api/upstreams/test-all，并把结果以提示框展示
function testAllUp() {
  // v2.9.5：状态行不再捕获引用 —— load() 每 5 秒轮询会重建 DOM，捕获的 st
  // 到回调时多半已成 detached 节点，结果写进去页面看不见。改为每次按 id 重查。
  function setSt(t) { var s = document.getElementById('upTestAllStatus'); if (s) s.textContent = t; }
  setSt('测试中，请稍候…');
  api('upstreams/test-all', {}).then(function(r) {
    if (!r) { setSt('请求失败'); return; }
    var lines = [];
    for (var i = 0; i < r.results.length && i < 30; i++) {
      var x = r.results[i];
      lines.push((x.ok ? '✅ ' : '❌ ') + x.model + (x.ok ? '' : '  ' + (x.error || '')));
    }
    if (r.results.length > 30) lines.push('… 共 ' + r.results.length + ' 个');
    var head = '共 ' + r.total + ' 个模型：' + r.okCount + ' 可用，' + r.failCount + ' 失败';
    if (lines.length) alert(head + '\\n\\n' + lines.join('\\n'));
    else alert(head);
    setSt(r.failCount === 0 ? '全部可用 ✅' : r.failCount + ' 个失败 ❌');
    load();
  }).catch(function(e) {
    setSt('请求异常');
  });
}

// v2.5.0：编辑服务器信息（名称 / 前缀 / 地址）。
// 与「改 Key」分开：改地址时不该逼用户重贴一遍 Key（容易手滑覆盖掉）。
function editUpInfo(id) {
  var list = (S && S.upstreams) || [];
  var u = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === id) u = list[i];
  if (!u) return;

  openModal('编辑服务器 · ' + u.name,
    '<p class="hint" style="margin-top:0">只改服务器信息，<strong>Key 池不受影响</strong>。</p>' +
    '<label class="fld"><span>名称</span>' +
      '<input id="mUpName" value="' + esc(u.name) + '" placeholder="显示用，可留空"></label>' +
    '<label class="fld"><span>模型前缀</span>' +
      '<input id="mUpPrefix" value="' + esc(u.prefix) + '" placeholder="如 sensenova"></label>' +
    '<label class="fld"><span>API 地址</span>' +
      '<input id="mUpUrl" value="' + esc(u.baseUrl) + '" placeholder="https://api.example.com/v1"></label>' +
    // v2.7.0：模型映射（one-api / new-api 的「模型重定向」）。
    // 留空 = 保持上游自己的模型列表；一旦填了，/v1/models 就只列这些名字。
    '<label class="fld"><span>模型映射（可选）</span>' +
      '<textarea id="mUpModels" rows="5" placeholder="每行一条：&#10;deepseek-v4-flash&#10;gpt-4o=glm-5.2&#10;# 井号开头是注释">' +
      esc(u.modelsText || '') + '</textarea></label>' +
    '<p class="hint"><code>别名=真名</code> 表示对外用别名、转发时换成真名；' +
      '只写 <code>真名</code> 表示照原样暴露。<strong>留空则不做映射</strong>，' +
      '名称直接取上游的模型列表。填了以后 <code>/v1/models</code> 以这里为准，也就不再外呼上游。</p>' +
    '<p class="hint">改前缀会让客户端里已写好的 <code>旧前缀/模型</code> 立刻失效，' +
      '记得同步改客户端配置。</p>' +
    '<div class="modal-foot">' +
      '<button onclick="closeModal()">取消</button>' +
      '<button class="primary" onclick="saveUpInfo(\\'' + esc(id) + '\\')">保存</button>' +
    '</div>');
}

function saveUpInfo(id) {
  var name = document.getElementById('mUpName').value;
  var prefix = document.getElementById('mUpPrefix').value;
  var url = document.getElementById('mUpUrl').value;
  var modelsEl = document.getElementById('mUpModels');
  var models = modelsEl ? modelsEl.value : null;
  if (!prefix || !url) { alert('前缀和 API 地址是必填的'); return; }
  var payload = { id: id, name: name, prefix: prefix, baseUrl: url };
  // 有映射框就一定带上（空串 = 清空映射），避免"清空后保存不生效"。
  if (models !== null) payload.models = models;
  api('upstreams/edit', payload).then(function (r) {
    if (r && r.ok) {
      closeModal();
      alert('已保存 ✅' + (r.prefixChanged
        ? '\\n\\n注意：前缀已从 ' + r.oldPrefix + ' 改为 ' + r.prefix +
          '，客户端里的模型名要同步改成 ' + r.prefix + '/模型名'
        : ''));
    } else {
      alert('保存失败：' + ((r && r.error) || '未知错误'));
    }
    refresh();
  });
}

// v2.5.0：单 Key 管理（启停 + 权重）。
// keyRef 是掩码后的 Key —— 后端会用 maskKey 反查真实 Key，明文从不经过浏览器。
function editUpKey(upId, keyRef) {
  var list = (S && S.upstreams) || [];
  var u = null, k = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === upId) u = list[i];
  if (!u) return;
  for (var j = 0; j < (u.keys || []).length; j++) if (u.keys[j].masked === keyRef) k = u.keys[j];
  if (!k) return;

  var on = !k.disabled;
  openModal('Key 管理 · ' + u.name,
    '<p class="hint" style="margin-top:0"><code>' + esc(k.masked) + '</code></p>' +
    '<label class="fld"><span>状态</span>' +
      '<span class="sw"><input type="checkbox" id="mKeyOn"' + (on ? ' checked' : '') + '>' +
      '<span></span></span></label>' +
    '<label class="fld"><span>权重</span>' +
      '<input id="mKeyWeight" type="number" min="1" max="1000" value="' + k.weight + '"></label>' +
    '<p class="hint">权重 ≥1，仅调整<b>被选中概率</b>，不影响其它 Key。' +
      '停用后这把 Key 不参与轮换（也不会再被试探），直到你重新启用。</p>' +
    '<p class="hint">当前失败次数：' + k.fails +
      (k.lastErr ? '<br>最近错误：' + esc(k.lastErr) : '') + '</p>' +
    '<div class="modal-foot">' +
      '<button onclick="closeModal()">取消</button>' +
      '<button class="primary" onclick="saveUpKey(\\'' + esc(upId) + '\\',\\'' + esc(keyRef) + '\\',' + (k.disabled ? 'true' : 'false') + ')">保存</button>' +
    '</div>');
}

function saveUpKey(upId, keyRef, wasDisabled) {
  var on = document.getElementById('mKeyOn').checked;
  var w = parseInt(document.getElementById('mKeyWeight').value, 10);
  if (!(w >= 1)) { alert('权重需为 ≥1 的整数'); return; }

  // 先存状态再存权重：状态变更会清掉失败计数，权重是独立字段，顺序不影响结果，
  // 但两次请求串行发出比并发更稳妥（后端每次都要读-改-写整个 upstreams.json）。
  var p = Promise.resolve();
  if (on === wasDisabled) {
    p = api('upstreams/key/toggle', { id: upId, key: keyRef, enabled: on });
  }
  p.then(function () {
    return api('upstreams/key/weight', { id: upId, key: keyRef, weight: w });
  }).then(function (r) {
    if (r && r.ok) { closeModal(); }
    else { alert('保存失败：' + ((r && r.error) || '未知错误')); }
    refresh();
  });
}

// 测试上游：拉一次 /models，把结果直接告诉用户
function testUp(id) {
  api('upstreams/test', { id: id }).then(function (r) {
    if (r && r.ok) {
      var names = [];
      for (var i = 0; i < r.models.length && i < 6; i++) names.push(r.models[i].id);
      alert('可用 ✅\\n共 ' + r.count + ' 个模型：\\n' + names.join('\\n') +
            (r.count > 6 ? '\\n…' : ''));
    } else {
      alert('测试失败 ❌\\n' + ((r && r.error) || '拿不到模型列表，检查地址与 Key'));
    }
    refresh();
  });
}

// 改 Key：用页面内的弹层而不是 prompt()。
// prompt() 是单行输入框，粘多行 Key 会被压成一行；
// 而 Key 池的核心用法就是"一次粘一批"，所以必须用 textarea。
function editUpKeys(id) {
  var list = (S && S.upstreams) || [];
  var u = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === id) u = list[i];
  if (!u) return;

  var cur = [];
  for (var j = 0; j < (u.keys || []).length; j++) cur.push(u.keys[j].masked);

  openModal('编辑 Key · ' + u.name,
    '<p class="hint" style="margin-top:0">当前 ' + cur.length + ' 条：' +
      esc(cur.join('、')) + '</p>' +
    '<p class="hint">粘贴新的 Key 列表，每行一条。<strong>会覆盖原有全部 Key。</strong>' +
      '每行的前后空格会自动去掉，重复项自动去重。' +
      'v2.0 支持权重：每行可写成 <code>key|权重</code>（权重 ≥1 的整数，默认 1），' +
      '例如 <code>sk-aaaa|3</code> 表示这把 Key 的被选中概率是普通 Key 的 3 倍。</p>' +
    '<textarea id="mKeysEdit" rows="8" placeholder="sk-xxxxxxxx&#10;sk-yyyyyyyy|3&#10;sk-zzzzzzzz"></textarea>' +
    '<div class="modal-foot">' +
      '<button onclick="closeModal()">取消</button>' +
      '<button class="primary" onclick="saveUpKeys(\\'' + esc(id) + '\\')">保存</button>' +
    '</div>');
}

function saveUpKeys(id) {
  var v = document.getElementById('mKeysEdit').value;
  if (!v || !v.replace(/\\s/g, '')) { alert('至少需要一条 Key'); return; }
  api('upstreams/keys', { id: id, keys: v }).then(function (r) {
    if (r && r.ok) { closeModal(); alert('已保存 ' + r.count + ' 条 Key ✅'); }
    else { alert('保存失败：' + ((r && r.error) || '未知错误')); }
    refresh();
  });
}

// 通用弹层：服务器 Key 编辑用
function openModal(title, innerHtml) {
  var m = document.getElementById('modal');
  document.getElementById('modalTitle').textContent = title;
  document.getElementById('modalBody').innerHTML = innerHtml;
  m.className = 'modal-mask';
}

function closeModal() {
  document.getElementById('modal').className = 'modal-mask hide';
}

function toggleUp(id, on) {
  api('upstreams/toggle', { id: id, enabled: on }).then(function () { refresh(); });
}

// 删除服务器。内置的 WorkBuddy 不走这里（它的卡片没有删除按钮）。
function delUp(id, name) {
  if (!confirm('确定删除服务器「' + name + '」？\\n\\n' +
      '删除后它的模型会从 /v1/models 消失，指向它的请求将返回 400。\\n' +
      '该服务器上配置的所有 Key 会一并删除。')) return;
  api('upstreams/delete', { id: id }).then(function (r) {
    if (r && r.ok) refresh();
    else alert('删除失败：' + ((r && r.error) || '未知错误'));
  });
}

// 注意：函数名不能叫 addUpstream —— 后端已有同名函数，重名会让其中一个
// 被静默覆盖（ucode 允许重复定义，但只有最后一个生效）。
function addUpstreamUI() {
  var name = document.getElementById('upName').value;
  var prefix = document.getElementById('upPrefix').value;
  var url = document.getElementById('upUrl').value;
  var keys = document.getElementById('upKeys').value;
  var modelsEl = document.getElementById('upModels');
  var models = modelsEl ? modelsEl.value : null;

  if (!prefix || !url || !keys) {
    alert('前缀、API 地址、Key 都是必填的');
    return;
  }

  var req = {
    name: name, prefix: prefix, baseUrl: url, keys: keys,
  };
  if (models !== null) req.models = models;
  api('upstreams/add', req).then(function (r) {
    if (r && r.ok) {
      document.getElementById('upName').value = '';
      document.getElementById('upPrefix').value = '';
      document.getElementById('upUrl').value = '';
      document.getElementById('upKeys').value = '';
      if (modelsEl) modelsEl.value = '';
      alert('已添加 ✅\\n模型名前缀：' + r.prefix + '/');
    } else {
      alert('添加失败：' + ((r && r.error) || '未知错误'));
    }
    refresh();
  });
}

// 凭据过期状态 -> 徽章。这是用户最需要一眼看到的信息。
function credBadge(c) {  if (c.status === 'expired') return '<span class="badge err">已过期</span>';
  if (c.status === 'expiring') return '<span class="badge warn">' + c.expDays + ' 天后过期</span>';
  if (c.cooling) return '<span class="badge warn">冷却 ' + c.coolRemain + 's</span>';
  if (!c.enabled) return '<span class="badge">已停用</span>';
  if (c.status === 'unknown') return '<span class="badge">有效期未知</span>';
  if (c.expDays >= 0 && c.expDays <= 30) return '<span class="badge ok">' + c.expDays + ' 天后过期</span>';
  return '<span class="badge ok">正常</span>';
}

function renderCreds(d) {
  var box = document.getElementById('credsBody');
  var list = d.creds || [];

  if (!list.length) {
    box.innerHTML = '<p class="hint">池中还没有凭据。用下面的任意一种方式添加。</p>';
    return;
  }

  var h = '<table><thead><tr><th>名称</th><th>账号</th><th>状态</th><th>来源</th><th style="white-space:nowrap">操作</th></tr></thead><tbody>';
  for (var i = 0; i < list.length; i++) {
    var c = list[i];
    var account = c.username
      ? esc(c.username)
      : '<span style="opacity:.5">—</span>';

    var actions = '';
    if (c.managed) {
      actions += '<button onclick="testCred(\\'' + esc(c.id) + '\\')">测试</button> ';
      actions += '<button onclick="toggleCred(\\'' + esc(c.id) + '\\',' + (c.enabled ? 'false' : 'true') + ')">' +
                 (c.enabled ? '停用' : '启用') + '</button> ';
      actions += '<button class="danger" onclick="delCred(\\'' + esc(c.id) + '\\',\\'' + esc(c.name) + '\\',\\'' + esc(c.username || '') + '\\')">删除</button>';
    } else {
      // 网页登录凭据：没有启停开关（它不在 pool.json 里），但**可以删除**。
      // 删除走的是另一条路径（清 token.json），按钮文案也刻意写成"删除账号"
      // 以区别于池内凭据的"删除"——两者后果不同，用户需要一眼看出差别。
      actions += '<button onclick="testCred(\\'' + esc(c.id) + '\\')">测试</button> ';
      actions += '<button class="danger" onclick="delCred(\\'' + esc(c.id) + '\\',\\'' + esc(c.name) + '\\',\\'' + esc(c.username || '') + '\\')">删除账号</button>';
    }

    h += '<tr><td>' + esc(c.name) + '</td>' +
         '<td>' + account + '</td>' +
         '<td>' + credBadge(c) + '</td>' +
         '<td><span class="badge">' + (c.source === 'legacy' ? '网页登录' : (c.weblogin ? '网页登录' : '手动添加')) + '</span></td>' +
         '<td style="white-space:nowrap">' + actions + '</td></tr>';
  }
  h += '</tbody></table>';

  // 顶部汇总：有几个可用、几个有问题
  var usable = 0, bad = 0;
  for (var j = 0; j < list.length; j++) {
    if (list[j].status === 'expired') { bad++; continue; }
    if (!list[j].enabled) continue;
    usable++;
  }
  var sum = '<p class="hint" style="margin:0 0 10px">共 ' + list.length + ' 条，可用 ' + usable + ' 条' +
            (bad ? '，<span style="color:var(--err)">' + bad + ' 条已过期需更换</span>' : '') + '。</p>';

  box.innerHTML = sum + h;
}

// ---------- 中转日志 ----------

// 事件类型 → 中文标签 + 颜色类。用查表而不是 if 链，
// 是为了新增事件类型时只改这一处，不会漏掉某个分支。
var RELAY_EV = {
  pick:    ['选中', 'ok'],
  ok:      ['成功', 'ok'],
  rate:    ['限流', 'warn'],
  risk:    ['风控', 'err'],
  auth:    ['鉴权', 'err'],
  client:  ['请求错', 'warn'],
  net:     ['网络', 'warn'],
  cool:    ['冷却', 'warn'],
  switch:  ['换号', 'dim'],
  exhaust: ['耗尽', 'err'],
  abort:   ['中断', 'dim'],
  trunc:   ['截断', 'err'],
};

function relayBadge(ev) {
  var m = RELAY_EV[ev];
  var label = m ? m[0] : ev;
  var cls = m ? m[1] : 'dim';
  // dim 不是 badge 的既有配色，退化成一个普通 badge
  if (cls === 'dim') return '<span class="badge">' + esc(label) + '</span>';
  return '<span class="badge ' + cls + '">' + esc(label) + '</span>';
}

// 比率 -> 文本 + 配色。'-1' 是无数据的哨兵（pick 为 0 时算不出比率），
// 必须显示成「—」而不是「-1%」，否则用户会以为出了负数故障。
function pctCell(v, warnAt, errAt) {
  if (v == null || v < 0) return '<span style="opacity:.4">—</span>';
  var cls = '';
  if (errAt != null && v >= errAt) cls = ' style="color:var(--err)"';
  else if (warnAt != null && v >= warnAt) cls = ' style="color:var(--warn)"';
  return '<span' + cls + '>' + v + '%</span>';
}

function relTime(t) {
  var d = Math.floor(Date.now() / 1000) - t;
  if (d < 0) d = 0;
  if (d < 60) return d + ' 秒前';
  if (d < 3600) return Math.floor(d / 60) + ' 分钟前';
  if (d < 86400) return Math.floor(d / 3600) + ' 小时前';
  return Math.floor(d / 86400) + ' 天前';
}

function renderRelay(d) {
  var box = document.getElementById('relayBody');
  var evBox = document.getElementById('relayEvents');
  var r = d.relay;
  if (!r) {
    box.innerHTML = '<p class="hint">本版本未提供中转日志。</p>';
    evBox.innerHTML = '';
    return;
  }

  // ---- 顶部总计 ----
  var t = r.totals || {};
  var h = '<p class="hint" style="margin:0 0 10px">累计 ' + (r.totalEvents || 0) + ' 条事件，' +
          '保留最近 ' + (r.capacity || 0) + ' 条明细。</p>';
  h += '<div class="kv"><span class="k">选中账号</span><span>' + (t.pick || 0) + ' 次</span></div>';
  h += '<div class="kv"><span class="k">成功</span><span>' + (t.ok || 0) + ' 次</span></div>';
  h += '<div class="kv"><span class="k">换号 / 全部耗尽</span><span>' + (t.switch || 0) + ' 次 / ' +
       (t.exhaust || 0) + ' 次</span></div>';
  h += '<div class="kv"><span class="k">响应中断 / 截断</span><span>' + (t.abort || 0) + ' 次 / ' +
       (t.trunc || 0) + ' 次</span></div>';

  // ---- 账号健康矩阵 ----
  // 凭据池账号与自定义上游 Key 是两套东西，分两张表渲染，
  // 否则用户会看到 "up:u123:sk-xxx" 这种 id 混在账号列表里。
  var accs = r.accounts || [];
  var creds = [], ups = [];
  for (var q = 0; q < accs.length; q++) {
    if (accs[q].kind === 'up') ups.push(accs[q]); else creds.push(accs[q]);
  }

  function matrix(list, title, note) {
    if (!list.length) return '';
    var t2 = '<h3 style="margin:16px 0 8px">' + title + '</h3>';
    t2 += '<table><thead><tr>' +
          '<th>账号 / Key</th><th>权重</th><th>选中</th><th>成功</th><th>成功率</th>' +
          '<th>近期</th><th>限流</th><th>限流率</th><th>风控</th><th>鉴权</th><th>网络</th>' +
          '<th>冷却次数</th><th>冷却占比</th><th>当前冷却</th><th>最近错误</th>' +
          '</tr></thead><tbody>';
    for (var i = 0; i < list.length; i++) {
      var a = list[i];
      var cooling = a.coolingSec > 0
        ? '<span style="color:var(--warn)">' + a.coolingSec + 's</span>'
        : '<span style="opacity:.4">—</span>';
      // 近期窗口：后端 relayRecentStats 统计最近 RELAY_RECENT_MIN=3 次选中。
      // 3 次全失败（recentOk=0）标红：与 relayWeight 压到 1 的条件完全一致；3 次全成标绿。
      var recentTxt = (a.recentPick > 0)
        ? (a.recentOk + '/' + a.recentPick)
        : '<span style="opacity:.4">—</span>';
      if (a.recentPick >= 3 && (a.recentOk || 0) === 0)
        recentTxt = '<span style="color:var(--err)" title="近期连续失败，权重已被压低">' + recentTxt + '</span>';
      else if (a.recentPick >= 3 && a.recentOk === a.recentPick)
        recentTxt = '<span style="color:var(--ok)" title="近期全成">' + recentTxt + '</span>';
      t2 += '<tr>' +
           '<td><code>' + esc(a.id) + '</code></td>' +
           '<td><span class="badge" style="' + (a.weight > 1 ? 'background:var(--accent2)' : '') + '">' + a.weight + '</span></td>' +
           '<td>' + a.pick + '</td>' +
           '<td>' + a.ok + '</td>' +
           '<td>' + pctCell(a.okRate, null, null) + '</td>' +
           '<td>' + recentTxt + '</td>' +
           '<td>' + a.rate + '</td>' +
           '<td>' + pctCell(a.rateRate, 30, 60) + '</td>' +
           '<td>' + (a.risk || 0) + '</td>' +
           '<td>' + (a.auth || 0) + '</td>' +
           '<td>' + (a.net || 0) + '</td>' +
           '<td>' + (a.cool || 0) + '</td>' +
           '<td>' + pctCell(a.coolPct, 50, 80) + '</td>' +
           '<td>' + cooling + '</td>' +
           '<td style="max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' +
             esc(a.lastErr) + '">' + (a.lastErr ? esc(a.lastErr) : '<span style="opacity:.4">—</span>') + '</td>' +
           '</tr>';
    }
    t2 += '</tbody></table>';
    t2 += '<p class="hint" style="margin-top:8px">' + note + '</p>';
    return t2;
  }

  h += matrix(creds, '凭据池账号',
    '成功率＝成功 / 选中。权重由「累计成功率 + 近期成功率」混合自动计算' +
    '（v2.4.0 起 7 成信近期，100%→10，50%→5，10%→1），权重≥2 标蓝。' +
    '「近期」列是最近 3 次选中的成败比，3 次全失败会标红并把权重压到 1。' +
    '限流率超过 30% 标黄、60% 标红，说明该账号额度紧张；冷却占比接近 100% 表示它基本不可用。');
  h += matrix(ups, '自定义上游 Key',
    '这些是「自定义上游」里配置的 Key，与凭据池账号无关。' +
    '权重＝max(配置权重, relay成功率权重)，同样混入近期表现。限流率高的 Key 会自动获得低权重。');

  if (!accs.length) {
    h += '<p class="hint" style="margin-top:12px">还没有中转记录。发几个请求就会出现。</p>';
  }
  box.innerHTML = h;

  // ---- 最近事件 ----
  var evs = r.recent || [];
  if (!evs.length) {
    evBox.innerHTML = '<p class="hint">暂无事件。</p>';
    return;
  }
  var e = '<table><thead><tr><th style="white-space:nowrap">时间</th><th>事件</th>' +
          '<th>账号 / Key</th><th>说明</th><th>附加</th></tr></thead><tbody>';
  for (var k = 0; k < evs.length; k++) {
    var v = evs[k];
    // 附加字段（sec/req/try 等）逐条列出，它们排障时最有用
    var extra = '';
    for (var key in v) {
      if (key === 'n' || key === 't' || key === 'id' || key === 'ev' || key === 'why') continue;
      extra += '<span class="badge">' + esc(key) + '=' + esc(v[key]) + '</span> ';
    }
    e += '<tr>' +
         '<td style="white-space:nowrap">' + relTime(v.t) + '</td>' +
         '<td>' + relayBadge(v.ev) + '</td>' +
         '<td><code>' + (v.id ? esc(v.id) : '<span style="opacity:.4">—</span>') + '</code></td>' +
         '<td style="max-width:360px">' + (v.why ? esc(v.why) : '') + '</td>' +
         '<td>' + extra + '</td>' +
         '</tr>';
  }
  e += '</tbody></table>';
  evBox.innerHTML = e;
}

function resetRelay() {
  api('relay/reset', {}).then(function(r) {
    if (r && r.ok) { toast('中转统计已重置', 'ok'); load(); }
    else { toast('重置失败：' + ((r && r.error) || '未知错误'), 'err'); }
  });
}

// ---------- 凭据池操作 ----------

var loginTimer = null;

function addCred() {
  var name = document.getElementById('ncName').value.trim();
  var tok = document.getElementById('ncToken').value.trim();

  if (!tok) { toast('请粘贴 access token', 'err'); return; }
  // 前端先做一次明显格式校验，省一次往返
  if (tok.indexOf('.') < 0) {
    toast('这不像是一个 access token（JWT 应包含点号分段）', 'err');
    return;
  }

  api('creds/add', { name: name, token: tok }).then(function(r) {
    if (r.ok) {
      toast('已添加凭据：' + (r.name || ''), 'ok');
      document.getElementById('ncName').value = '';
      document.getElementById('ncToken').value = '';
      load();
    } else if (r.dup) {
      toast('未添加：' + r.error + (r.existingName ? '（已有：' + r.existingName + '）' : ''), 'err');
    } else if (r.expired) {
      toast('未添加：该凭据已过期，请重新登录获取新的 token', 'err');
    } else {
      toast('添加失败：' + (r.error || ''), 'err');
    }
  }).catch(function(e) { toast('添加失败：' + e.message, 'err'); });
}

// 删除凭据。两条语义不同的路径共用这个入口，确认强度也不同：
//   池内凭据     —— 只从 pool.json 摘掉一个条目，token 还在用户手上，
//                  随时能再粘回来，一次确认即可
//   网页登录凭据 —— id 固定为 'default'，删的是 token.json 里的账号本体，
//                  删完本机不再持有该账号，属于账号级操作，
//                  所以做两次确认，并把后果写清楚
function delCred(id, name, account) {
  var who = account ? ('（账号 ' + account + '）') : '';

  if (id === 'default') {
    if (!confirm('确定删除账号' + who + '？\\n\\n' +
                 '这会删除本机保存的「网页登录凭据」，删除后本机不再持有该账号；' +
                 '所有走本机 WorkBuddy 上游的请求都会失败，除非池里还有其它凭据。\\n\\n' +
                 '此操作不可撤销（不会保留本地副本）。如需恢复，请用下方的「网页登录」重新登录。')) return;
    if (!confirm('再次确认：真的要删除这个账号吗？')) return;
  } else {
    if (!confirm('确定删除凭据「' + name + '」？删除后该账号将不再参与轮询。')) return;
  }

  api('creds/delete', { id: id }).then(function(r) {
    if (r.ok) { toast(id === 'default' ? '账号已删除' : '已删除', 'ok'); load(); }
    else { toast('删除失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('删除失败：' + e.message, 'err'); });
}

function toggleCred(id, on) {
  api('creds/toggle', { id: id, enabled: on }).then(function(r) {
    if (r.ok) { toast(on ? '已启用' : '已停用', 'ok'); load(); }
    else { toast('操作失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('操作失败：' + e.message, 'err'); });
}

function testCred(id) {
  toast('正在测试…');
  api('creds/test', { id: id }).then(function(r) {
    if (r.ok) toast('凭据可用（上游 HTTP ' + r.httpCode + '）', 'ok');
    else if (r.expired) toast('该凭据已过期，请重新登录或更换', 'err');
    else toast('测试未通过：' + (r.error || ''), 'err');
    load();
  }).catch(function(e) { toast('测试失败：' + e.message, 'err'); });
}

function startLogin() {
  var btn = document.getElementById('btnLogin');
  btn.disabled = true;

  api('creds/login/start', {}).then(function(r) {
    if (!r.ok) {
      btn.disabled = false;
      toast('无法发起登录：' + (r.error || ''), 'err');
      return;
    }
    document.getElementById('loginBox').className = 'loginbox';
    document.getElementById('loginUrl').value = r.authUrl || '';
    document.getElementById('loginLink').href = r.authUrl || '#';
    document.getElementById('loginHint').textContent =
      r.already ? '已有登录流程在进行中…' : '已生成授权链接，等待授权中…';

    // 自动打开授权页，省一次点击
    if (r.authUrl) window.open(r.authUrl, '_blank', 'noopener');

    pollLogin();
  }).catch(function(e) {
    btn.disabled = false;
    toast('无法发起登录：' + e.message, 'err');
  });
}

function pollLogin() {
  if (loginTimer) clearInterval(loginTimer);
  var n = 0;

  loginTimer = setInterval(function() {
    n++;
    api('creds/login/status').then(function(r) {
      if (r.done) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
        document.getElementById('loginBox').className = 'hide';
        toast('登录成功，凭据已加入池中', 'ok');
        load();
        return;
      }
      if (!r.running) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
        document.getElementById('loginHint').textContent = r.lastError || '登录流程已结束';
        return;
      }
      document.getElementById('loginHint').textContent =
        '等待授权中… 剩余 ' + r.remain + ' 秒' + (r.lastError ? '（' + r.lastError + '）' : '');
      // 最多轮询 5 分钟
      if (n > 150) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
      }
    }).catch(function() {
      clearInterval(loginTimer); loginTimer = null;
      document.getElementById('btnLogin').disabled = false;
    });
  }, 2000);
}

function copyText(val) {
  if (!val) { toast('没有可复制的内容', 'err'); return; }
  function done() { toast('链接已复制', 'ok'); }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(val).then(done, function() { fallback(null, val, done); });
  } else { fallback(null, val, done); }
}

function renderCfg(d) {
  document.getElementById('cFree').checked = !!d.onlyFreeModels;
  document.getElementById('cAutoVer').checked = !!d.autoVersion;
  document.getElementById('cVer').value = d.clientVersion || '';
  document.getElementById('verWrap').className = d.autoVersion ? 'field hide' : 'field';
  // v2.8.0：每日模型巡检
  var cr = document.getElementById('cModelRefresh');
  if (cr) cr.checked = !!d.modelRefreshEnabled;
  var ch = document.getElementById('cModelHour');
  if (ch) ch.value = (d.modelRefreshHour != null) ? d.modelRefreshHour : 1;
}

document.getElementById('cAutoVer').addEventListener('change', function() {
  document.getElementById('verWrap').className = this.checked ? 'field hide' : 'field';
});

function copyKey(btn, val) {
  function done() { toast('密钥已复制到剪贴板', 'ok'); }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(val).then(done, function() { fallback(btn, val, done); });
  } else { fallback(btn, val, done); }
}

function fallback(btn, val, done) {
  var ta = document.createElement('textarea');
  ta.value = val; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  try { document.execCommand('copy'); done(); }
  catch (e) { toast('复制失败，请手动选择文本', 'err'); }
  ta.remove();
}

function addKey() {
  var inp = document.getElementById('nkName');
  var name = inp.value.trim();
  if (!name) { toast('请填写密钥名称', 'err'); return; }
  api('keys/add', { name: name }).then(function(r) {
    if (r.ok) { toast('已生成密钥：' + r.key, 'ok'); inp.value = ''; load(); }
    else { toast('生成失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('生成失败：' + e.message, 'err'); });
}

function toggleKey(id, on) {
  api('keys/toggle', { id: id, enabled: on }).then(function(r) {
    if (r.ok) { toast(on ? '已启用' : '已禁用', 'ok'); load(); }
    else { toast('操作失败', 'err'); }
  }).catch(function(e) { toast('操作失败：' + e.message, 'err'); });
}

function delKey(id, name) {
  if (!confirm('确定吊销密钥「' + name + '」？使用该密钥的客户端将立即无法访问。')) return;
  api('keys/delete', { id: id }).then(function(r) {
    if (r.ok) { toast('已吊销', 'ok'); load(); } else { toast('吊销失败', 'err'); }
  }).catch(function(e) { toast('吊销失败：' + e.message, 'err'); });
}

function saveCfg() {
  var hourEl = document.getElementById('cModelHour');
  var hour = hourEl ? parseInt(hourEl.value, 10) : 1;
  if (isNaN(hour) || hour < 0 || hour > 23) { alert('每日刷新时间必须是 0-23 的整数'); return; }
  var body = {
    only_free_models: document.getElementById('cFree').checked ? '1' : '0',
    auto_client_version: document.getElementById('cAutoVer').checked ? '1' : '0',
    client_version: document.getElementById('cVer').value.trim(),
    // v2.8.0：每日模型巡检
    model_refresh_enabled: (document.getElementById('cModelRefresh') && document.getElementById('cModelRefresh').checked) ? '1' : '0',
    model_refresh_hour: String(hour)
  };
  api('config/save', body).then(function(r) {
    if (r.ok) { toast('设置已保存', 'ok'); load(); }
    else { toast('保存失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('保存失败：' + e.message, 'err'); });
}

// 公网访问开关 + 外部端口。
// 后端会自动写/删防火墙规则，失败时会把错误原样带回来，
// 所以这里必须把 r.ok === false 当成失败处理，不能只看 HTTP 200。
function saveWan() {
  var on = document.getElementById('cWan').checked;
  var portEl = document.getElementById('cWanPort');
  var portVal = portEl ? portEl.value.trim() : '';
  if (on) {
    if (!confirm('确定允许公网访问？\\n\\n' +
        '任何人都能打开 http://<你的公网IP>:' + (portVal || '8789') + '/admin 的登录界面。\\n' +
        '请确认管理员密码与 API 密钥都足够强。')) {
      return;
    }
  }
  api('config/save', { wan_access: on ? '1' : '0', wan_port: portVal }).then(function(r) {
    if (r.ok) {
      toast(on ? '公网访问已开启' : '公网访问已关闭', 'ok');
      load();
    } else {
      // 配置写了但规则没生效时后端回 ok:false，要把复选框还原成实际状态
      toast('未生效：' + (r.error || '未知错误'), 'err');
      load();
    }
  }).catch(function(e) { toast('保存失败：' + e.message, 'err'); });
}

function renderWan(d) {
  var cb = document.getElementById('cWan');
  var st = document.getElementById('wanState');
  var warn = document.getElementById('wanWarn');
  var portEl = document.getElementById('cWanPort');
  var innerEl = document.getElementById('wanInnerPort');
  var warnPortEl = document.getElementById('wanWarnPort');
  if (!cb) return;
  cb.checked = !!d.wanAccess;

  // 外部端口输入框：默认填当前生效的外部端口，内部端口作提示
  var wanPort = d.wanPort || d.port || 8789;
  if (portEl) portEl.value = (d.wanAccess ? wanPort : (d.wanPort || ''));
  if (innerEl) innerEl.textContent = d.port || 8789;
  if (warnPortEl) warnPortEl.textContent = wanPort;

  var w = d.wan || {};
  var txt, cls;
  if (w.active) {
    txt = '已生效：外网端口 ' + wanPort + ' → 本机 ' + (d.port || 8789) + '（规则 workbuddy_wan 已存在）';
    cls = 'ok';
  } else if (d.wanAccess && w.uci) {
    txt = '规则已写入，但尚未在防火墙中生效，正在等待 reload';
    cls = 'warn';
  } else if (d.wanAccess && !w.uci) {
    txt = '开关已开但规则缺失，请重新保存一次';
    cls = 'err';
  } else {
    txt = '仅局域网可访问（默认，安全）';
    cls = '';
  }
  st.innerHTML = '<span class="badge ' + cls + '">' + esc(txt) + '</span>';

  // 只在开着的时候显示风险提示，避免平时吓人
  if (warn) warn.className = d.wanAccess ? 'warnbox' : 'warnbox hide';
}

function logout() {
  if (!confirm('确定退出登录？')) return;
  location.href = '/admin/logout';
}

load();
</script>
</body></html>`;
}

// 解析 POST body；只接受 JSON，失败返回空对象
function parseJsonBody(body) {
	if (type(body) !== 'string' || length(body) === 0) return {};
	try {
		let j = json(body);
		if (type(j) === 'object' && j !== null) return j;
	} catch (e) {
		// 忽略
	}
	return {};
}

// 从 application/x-www-form-urlencoded 中取字段
function formField(body, field) {
	if (type(body) !== 'string') return '';
	let want = '' + field + '=';
	for (let part in split(body, '&')) {
		if (substr(part, 0, length(want)) === want)
			return urlDecode(substr(part, length(want)));
	}
	return '';
}

// 管理页总入口。所有 /admin 与 /admin/* 请求都经过这里。
function handleAdmin(conn, req, method, path, query, body) {
	// 未设置管理员密码：明确提示去 LuCI 设置，不要静默放行
	if (!adminEnabled(cfg)) {
		textResponse(conn, 200, APP_NAME + ' 管理',
			'<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
			'<meta name="viewport" content="width=device-width,initial-scale=1">' +
			'<title>未设置管理员密码</title><style>' + adminCss() + '</style></head><body>' +
			'<div class="login"><div class="card"><h1>未设置管理员密码</h1>' +
			'<p class="sub">管理页需要先设置管理员密码。</p>' +
			'<p class="hint">请进入 LuCI：服务 → AI 中转服务器 → 管理页密码，设置一个密码后回到本页。</p>' +
			'</div></div></body></html>');
		return;
	}

	// 登录提交
	if (path === '/admin/login' && method === 'POST') {
		let ip = conn.ip || '?';
		let lock = adminLocked(ip);
		if (lock > 0) {
			logErr(sprintf('admin login blocked (locked %ds) from %s', lock, ip));
			textResponse(conn, 429, '登录受限',
				adminLoginPage(sprintf('尝试次数过多，请 %d 秒后重试。', lock)));
			return;
		}
		let pw = '' + formField(body, 'password');
		if (length(pw) === 0) pw = '' + (parseJsonBody(body).password || '');

		if (length(pw) > 0 && secureEq(pw, cfg.adminPass)) {
			adminNoteOk(ip);
			let tok = adminToken(cfg);
			logInfo('admin login ok from ' + ip);
			rawResponse(conn, 302, 'text/plain; charset=utf-8', '重定向中...', {
				'Location': '/admin',
				'Set-Cookie': ADMIN_COOKIE + '=' + tok +
					'; Path=/; Max-Age=' + ADMIN_TTL + '; HttpOnly; SameSite=Lax',
			});
			return;
		}

		adminNoteFail(ip);
		logErr('admin login failed from ' + ip);
		textResponse(conn, 401, '登录失败', adminLoginPage('密码错误'));
		return;
	}

	// 退出
	if (path === '/admin/logout') {
		rawResponse(conn, 302, 'text/plain; charset=utf-8', '重定向中...', {
			'Location': '/admin',
			'Set-Cookie': ADMIN_COOKIE + '=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax',
		});
		return;
	}

	// 以下均需已登录
	let authed = adminAuthed(cfg, req.headers);

	// 审计标识：所有**会改状态**的管理操作都要在日志里带来源 IP。
	//
	// 为什么单独立个变量：以前这些日志只有动作没有来源，于是"谁把账号删了"
	// 这种问题无法归属 —— 只能靠"当时有没有新的登录记录"去反推，
	// 而管理 cookie 有效期 24 小时，完全可以不重新登录就执行删除，
	// 归属就断了。带上 IP 后，一次 logread 就能定位到具体来源。
	let who = ' [' + (conn.ip || '?') + ']';

	if (path === '/admin' || path === '/admin/') {
		if (!authed) {
			textResponse(conn, 200, '管理登录', adminLoginPage(''));
			return;
		}
		textResponse(conn, 200, APP_NAME + ' 管理', adminAppPage());
		return;
	}

	if (!authed) {
		jsonResponse(conn, 401, { error: { message: '未登录或会话已过期' } });
		return;
	}

	// ---- 已登录的 API ----

	if (path === '/admin/api/state' && method === 'GET') {
		let now = time();
		let creds = [];

		// 池文件里的条目（含禁用项与过期项，管理页要全部看到）
		let rawList = readPoolRaw();
		let seenSub = {};
		for (let c in rawList) {
			let t = '' + (c.accessToken || '');
			let info = parseJwt(t);
			let st = credStatus(t, now);
			let stt = credState['' + (c.id || '')] || {};
			let cool = (stt.coolUntil || 0) > now;

			if (info && length(info.sub) > 0) seenSub[info.sub] = true;

			push(creds, {
				id: '' + (c.id || ''),
				name: '' + (c.name || c.id || ''),
				source: 'pool',
				weblogin: (('' + (c.source || '')) === 'weblogin'),  // 网页登录来的条目，徽章显示"网页登录"
				enabled: (c.enabled !== false),
				managed: true,                       // 可在管理页删除/启停
				status: st,                          // ok | expiring | expired | unknown
				exp: info ? info.exp : 0,
				expDays: (info && info.exp) ? int((info.exp - now) / 86400) : -1,
				username: info ? info.username : '',
				accountId: info ? info.sub : '',
				tail: length(t) >= 8 ? substr(t, length(t) - 8) : '',
				tokenLength: length(t),
				syncedAt: c.syncedAt || 0,
				cooling: cool,
				coolRemain: cool ? ((stt.coolUntil || 0) - now) : 0,
			});
		}

		// 网页登录镜像（token.json）。
		//
		// v2.2.0 起，网页登录得到的账号**已经**以普通条目形式写进 pool.json
		// （见 addWebLoginCred），token.json 退化成"最近一次登录的镜像"。
		// 因此这里必须按 JWT sub 去重，否则同一个账号会在表格里出现两行 ——
		// 一行是池条目（可启停/可删除），一行是这个镜像（managed=false），
		// 用户会以为配了两个账号，还会困惑"删哪个才对"。
		//
		// 保留这块显示的意义：兼容"只升级了 ucode 但还没重新登录"的存量设备 ——
		// 那种情况下 token.json 里的账号确实不在池里，必须让用户看到并管理它。
		let legacyTok = getToken(cfg);
		if (legacyTok) {
			let info = parseJwt(legacyTok);
			let alreadyInPool = false;
			if (info && length(info.sub) > 0 && seenSub[info.sub])
				alreadyInPool = true;
			// sub 解析不出来时退回按 token 全文比对，避免重复行
			if (!alreadyInPool) {
				for (let c in rawList) {
					if (('' + (c.accessToken || '')) === legacyTok) { alreadyInPool = true; break; }
				}
			}

			if (!alreadyInPool) {
				let lj = readJsonFile(tokenPath(cfg)) || {};
				let st = credStatus(legacyTok, now);
				let stt = credState['default'] || {};
				let cool = (stt.coolUntil || 0) > now;
				push(creds, {
					id: 'default',
					name: '网页登录凭据',
					source: 'legacy',
					enabled: true,
					managed: false,
					status: st,
					exp: info ? info.exp : 0,
					expDays: (info && info.exp) ? int((info.exp - now) / 86400) : -1,
					username: info ? info.username : '',
					accountId: info ? info.sub : '',
					tail: length(legacyTok) >= 8 ? substr(legacyTok, length(legacyTok) - 8) : '',
					tokenLength: length(legacyTok),
					syncedAt: lj.syncedAt || 0,
					cooling: cool,
					coolRemain: cool ? ((stt.coolUntil || 0) - now) : 0,
				});
			}
		}

		let usable = loadPool(cfg);
		let usableActive = 0;
		for (let c in usable) {
			let st = credStatus(c.token, now);
			if (st !== 'expired') usableActive++;
		}

		let models = [];
		for (let m in availableModels(cfg))
			push(models, { id: m.id, name: m.name });

		// 是否正在等待某个登录流程完成
		let loginState = null;
		if (login.running && length(login.state) > 0) {
			let el = int(LOGIN_TIMEOUT_MS / 1000) - (time() - (login.startedAt || 0));
			loginState = {
				running: true,
				authUrl: '' + (login.authUrl || ''),
				state: '' + login.state,
				remain: el > 0 ? el : 0,
				lastError: '' + (login.lastError || ''),
			};
		}

		jsonResponse(conn, 200, {
			ok: true,
			version: APP_VERSION,
			enabled: cfg.enabled,
			port: cfg.port,
			host: cfg.host,
			endpoint: cfg.endpoint,
			credentials: length(creds),
			credentialsUsable: usableActive,
			creds: creds,
			login: loginState,
			keys: listApiKeysFull(),
			keysTotal: apiKeysDefined(),
			keysActive: length(loadApiKeys()),
			models: models,
			onlyFreeModels: cfg.onlyFree,
			autoVersion: cfg.autoVersion,
			// v2.8.0：每日模型巡检（管理页「服务设置」卡片回显）
			modelRefreshEnabled: cfg.modelRefreshEnabled,
			modelRefreshHour: cfg.modelRefreshHour,
			wanAccess: cfg.wanAccess,
			wanPort: cfg.wanPort,
			wan: wanAccessStatus(cfg),
			clientVersion: clientVersion(cfg),
			adminEnabled: adminEnabled(cfg),
			upstreams: upstreamStatus(),
			wbPrefix: WB_PREFIX,
			// 内置服务器（WorkBuddy 自身）的状态，供服务器列表首卡展示
			hasToken: (length(loadPool(cfg)) > 0),
			endpoint: cfg.endpoint,
			// 中转日志（v2.2.0）。管理页的「中转日志」页签全靠这一块，
			// 少了它前端只会显示"本版本未提供中转日志"。
			relay: relaySnapshot(time() - metrics.since),
		});
		return;
	}

	// ---- 凭据池管理 ----

	if (path === '/admin/api/creds/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addPoolCred('' + (j.name || ''), '' + (j.token || ''), cfg);
		if (r.ok) {
			logInfo('admin added pool credential ' + r.id + who);
			jsonResponse(conn, 200, { ok: true, id: r.id, name: r.name });
		} else {
			// 重复用 409，让前端给出针对性提示
			jsonResponse(conn, r.dup ? 409 : 400, {
				ok: false, dup: !!r.dup, expired: !!r.expired, error: r.error,
				existingId: r.existingId || '', existingName: r.existingName || '',
			});
		}
		return;
	}

	if (path === '/admin/api/creds/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');

		// 网页登录凭据：删除的是 token.json（账号本体），不是池条目。
		// 早先这里直接拒绝并提示"请用「退出登录」清除"—— 那句提示是错的：
		// 管理页的「退出」清的是 admin 会话 cookie，跟账号凭据毫无关系，
		// 于是用户被引到一条死路上（账号根本无法删除）。现已改为真删除。
		if (id === 'default') {
			let r = deleteLegacyCred(cfg);
			logInfo('admin deleted legacy credential -> ' + r.ok + (r.error ? (' (' + r.error + ')') : '') + who);
			jsonResponse(conn, r.ok ? 200 : 400, {
				ok: r.ok, id: 'default', legacy: true,
				error: r.error || '',
			});
			return;
		}

		let ok = deletePoolCred(id);
		logInfo('admin deleted pool credential ' + id + ' -> ' + ok + who);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, error: ok ? '' : '凭据不存在' });
		return;
	}

	if (path === '/admin/api/creds/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		if (id === 'default') {
			jsonResponse(conn, 400, { ok: false, error: '网页登录凭据不可停用' });
			return;
		}
		let en = truthy(j.enabled);
		let ok = togglePoolCred(id, en);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: en, error: ok ? '' : '凭据不存在' });
		return;
	}

	if (path === '/admin/api/creds/test' && method === 'POST') {
		// 单条凭据可用性测试：拿它去请求一次模型列表
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		let token = '';
		if (id === 'default') {
			token = getToken(cfg) || '';
		} else {
			let c = findPoolById(id);
			if (c) token = '' + (c.accessToken || '');
		}
		if (length(token) === 0) {
			jsonResponse(conn, 404, { ok: false, error: '凭据不存在' });
			return;
		}
		let st = credStatus(token, time());
		if (st === 'expired') {
			jsonResponse(conn, 200, { ok: false, expired: true, error: '该凭据已过期，请重新登录或更换' });
			return;
		}
		let out = F.runCurl(cfg, [
			'-sS', '-m', '20', '-o', '/dev/null', '-w', '%{http_code}',
			'-H', 'Authorization: Bearer ' + token,
			'-H', 'User-Agent: WorkBuddy/' + clientVersion(cfg),
			cfg.endpoint + '/v3/config',
		]);
		let code = trim('' + (out || ''));
		let good = (code === '200');
		jsonResponse(conn, 200, {
			ok: good, httpCode: code,
			error: good ? '' : ('上游返回 HTTP ' + code),
			status: st,
		});
		return;
	}

	if (path === '/admin/api/creds/login/start' && method === 'POST') {
		// 发起一次新的网页登录，用于往池里增加凭据。
		// startWebLogin 定义在文件后段，这里必须走前向引用表。
		let r = F.startWebLogin(cfg);
		if (!r || r.ok !== true) {
			jsonResponse(conn, 500, { ok: false, error: (r && r.error) || '无法发起登录' });
			return;
		}
		logInfo('admin started web login' + who);
		jsonResponse(conn, 200, { ok: true, authUrl: r.authUrl || '', already: !!r.alreadyRunning });
		return;
	}

	if (path === '/admin/api/creds/login/status' && method === 'GET') {
		// 轮询用：告诉前端登录是否还在等、是否成功、还剩多久
		if (!login.running) {
			// 已经结束：区分"刚刚成功"与"未在登录"
			jsonResponse(conn, 200, {
				ok: true, running: false,
				done: login.ok === true,
				lastError: '' + (login.lastError || ''),
			});
			// 成功一次后清掉 ok，避免重复提示
			if (login.ok === true) login.ok = false;
			return;
		}
		let el = int(LOGIN_TIMEOUT_MS / 1000) - (time() - (login.startedAt || 0));
		jsonResponse(conn, 200, {
			ok: true,
			running: true,
			done: false,
			authUrl: '' + (login.authUrl || ''),
			remain: el > 0 ? el : 0,
			lastError: '' + (login.lastError || ''),
		});
		return;
	}

	if (path === '/admin/api/relay/reset' && method === 'POST') {
		// 只清中转日志的统计，不动任何账号/密钥——用户想重新观察一段时间
		// 的轮换质量时用，不应该有任何破坏性副作用。
		relayReset();
		logInfo('admin reset relay stats' + who);
		jsonResponse(conn, 200, { ok: true });
		return;
	}

	if (path === '/admin/api/keys/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addApiKey('' + (j.name || ''));
		if (r === null) {
			jsonResponse(conn, 500, { ok: false, error: '写入密钥文件失败' });
			return;
		}
		logInfo('admin added api key ' + r.id + who);
		jsonResponse(conn, 200, { ok: true, id: r.id, key: r.key, name: r.name });
		return;
	}

	if (path === '/admin/api/keys/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let ok = deleteApiKey('' + (j.id || ''));
		logInfo('admin deleted api key ' + (j.id || '') + ' -> ' + ok + who);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok });
		return;
	}

	if (path === '/admin/api/keys/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let on = truthy(j.enabled);
		let ok = toggleApiKey('' + (j.id || ''), on);
		logInfo('admin toggled api key ' + (j.id || '') + ' -> ' + on + who);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: on });
		return;
	}

	// ---- 自定义上游管理 ----

	if (path === '/admin/api/upstreams/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addUpstream(
			'' + (j.name || ''),
			'' + (j.prefix || ''),
			'' + (j.baseUrl || ''),
			'' + (j.keys || ''),
			('models' in j) ? ('' + (j.models || '')) : null
		);
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin added upstream ' + r.upstream.prefix + who);
		jsonResponse(conn, 200, {
			ok: true,
			id: r.upstream.id,
			prefix: r.upstream.prefix,
			baseUrl: r.upstream.baseUrl,
			keyCount: length(r.upstream.keys),
		});
		return;
	}

	if (path === '/admin/api/upstreams/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let ok = deleteUpstream('' + (j.id || ''));
		logInfo('admin deleted upstream ' + (j.id || '') + ' -> ' + ok + who);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok });
		return;
	}

	if (path === '/admin/api/upstreams/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let on = truthy(j.enabled);
		let ok = toggleUpstream('' + (j.id || ''), on);
		logInfo('admin toggled upstream ' + (j.id || '') + ' -> ' + on + who);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: on });
		return;
	}

	if (path === '/admin/api/upstreams/keys' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = setUpstreamKeys('' + (j.id || ''), '' + (j.keys || ''));
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin updated upstream keys ' + (j.id || '') + ' -> ' + r.count + who);
		jsonResponse(conn, 200, { ok: true, count: r.count });
		return;
	}

	// v2.5.0：编辑服务器信息（名称/前缀/地址/启停），Key 保持不变。
	// v2.7.0：追加 models（模型映射文本；null=本次不改，''=清空）。
	if (path === '/admin/api/upstreams/edit' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = editUpstream(
			'' + (j.id || ''),
			'' + (j.name || ''),
			'' + (j.prefix || ''),
			'' + (j.baseUrl || ''),
			('enabled' in j) ? truthy(j.enabled) : null,
			('models' in j) ? ('' + (j.models || '')) : null
		);
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin edited upstream ' + r.id + ' prefix ' + r.oldPrefix + ' -> ' + r.prefix +
			' models ' + r.modelCount + who);
		jsonResponse(conn, 200, {
			ok: true, id: r.id, name: r.name,
			prefix: r.prefix, oldPrefix: r.oldPrefix,
			prefixChanged: r.prefixChanged,
			modelCount: r.modelCount,
		});
		return;
	}

	// v2.5.0：单 Key 启用/停用
	if (path === '/admin/api/upstreams/key/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let on = truthy(j.enabled);
		let r = toggleUpstreamKey('' + (j.id || ''), '' + (j.key || ''), on);
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin toggled upstream key ' + (j.id || '') + ' ' + (j.key || '') + ' -> ' + on + who);
		jsonResponse(conn, 200, { ok: true, enabled: on });
		return;
	}

	// v2.5.0：单 Key 权重编辑
	if (path === '/admin/api/upstreams/key/weight' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = setUpstreamKeyWeight('' + (j.id || ''), '' + (j.key || ''), j.weight);
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin set upstream key weight ' + (j.id || '') + ' ' + (j.key || '') + ' -> ' + r.weight + who);
		jsonResponse(conn, 200, { ok: true, weight: r.weight });
		return;
	}

	// 测试某个上游是否可用（用它的 Key 拉一次 /models）
	if (path === '/admin/api/upstreams/test' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		let up = null;
		let all = loadUpstreams();
		for (let u in all) if (u.id === id) { up = u; break; }
		if (up === null) {
			jsonResponse(conn, 404, { ok: false, error: '上游不存在' });
			return;
		}
		let models = fetchUpstreamModels(up);
		jsonResponse(conn, 200, {
			ok: length(models) > 0,
			count: length(models),
			models: models,
		});
		return;
	}

	// v2.8.0：测试全部启用上游的每个模型是否真正可用（发最小 chat 请求）
	if (path === '/admin/api/upstreams/test-all' && method === 'POST') {
		let t = testAllUpstreamModels();
		logInfo('admin ran test-all: ' + t.okCount + '/' + t.total + ' ok, ' + t.failCount + ' failed' + who);
		jsonResponse(conn, 200, {
			ok: t.ok,
			total: t.total,
			okCount: t.okCount,
			failCount: t.failCount,
			results: t.results,
		});
		return;
	}

	if (path === '/admin/api/config/save' && method === 'POST') {
		let j = parseJsonBody(body);
		let ctx = uci.cursor();
		let changed = [];

		// 注意：ucode 没有 undefined 这个标识符（写 `!== undefined` 会在运行时抛
		// "access to undeclared variable undefined"），也没有 has()。
		// 判断字段是否出现用 `'key' in obj`。
		if ('only_free_models' in j) {
			ctx.set('workbuddy', 'main', 'only_free_models',
				truthy(j.only_free_models) ? '1' : '0');
			push(changed, 'only_free_models');
		}
		if ('auto_client_version' in j) {
			ctx.set('workbuddy', 'main', 'auto_client_version',
				truthy(j.auto_client_version) ? '1' : '0');
			push(changed, 'auto_client_version');
		}
		if (type(j.client_version) === 'string' && length(trim(j.client_version)) > 0) {
			ctx.set('workbuddy', 'main', 'client_version', trim(j.client_version));
			push(changed, 'client_version');
		}

		// v2.8.0：每日模型巡检开关与小时（0-23）
		if ('model_refresh_enabled' in j) {
			ctx.set('workbuddy', 'main', 'model_refresh_enabled',
				truthy(j.model_refresh_enabled) ? '1' : '0');
			push(changed, 'model_refresh_enabled');
		}
		if ('model_refresh_hour' in j) {
			let mh = +j.model_refresh_hour;
			if (!(mh >= 0 && mh <= 23) || mh !== int(mh)) {
				jsonResponse(conn, 200, { ok: false, error: '每日刷新时间必须是 0-23 之间的整数' });
				return;
			}
			ctx.set('workbuddy', 'main', 'model_refresh_hour', '' + mh);
			push(changed, 'model_refresh_hour');
		}

		// 公网访问开关 + 外部端口。先写配置再落地防火墙规则，这样即使规则失败，
		// 配置里记录的仍是用户的意图，下次 reload 会自动补齐。
		// wantWan 记录"本次是否触及了公网相关配置"——只要触及就重写规则，
		// 这样单独改外部端口（开关保持开启）也能立刻生效。
		let wanTouched = false;
		if ('wan_access' in j) {
			ctx.set('workbuddy', 'main', 'wan_access', truthy(j.wan_access) ? '1' : '0');
			push(changed, 'wan_access');
			wanTouched = true;
		}
		if ('wan_port' in j) {
			let raw = trim('' + j.wan_port);
			// 空 = 重置为跟随内部端口。写空串即可，loadConfig 会回退到内部端口。
			if (raw === '') {
				ctx.set('workbuddy', 'main', 'wan_port', '');
				push(changed, 'wan_port');
				wanTouched = true;
			} else {
				let wp = +raw;
				// 校验：必须是 1–65535 的整数，否则拒绝保存，不写脏值进 UCI
				if (wp < 1 || wp > 65535 || wp !== int(wp)) {
					jsonResponse(conn, 200, { ok: false, error: '外部端口必须是 1–65535 之间的整数' });
					return;
				}
				ctx.set('workbuddy', 'main', 'wan_port', '' + wp);
				push(changed, 'wan_port');
				wanTouched = true;
			}
		}

		let rc = ctx.commit('workbuddy');
		if (rc !== true && rc !== 0 && rc !== null) {
			jsonResponse(conn, 500, { ok: false, error: 'uci commit 失败' });
			return;
		}

		// 重新载入配置，让本次修改立即生效
		cfg = loadConfig();

		// 防火墙规则落地。失败时明确报错，不要让用户以为已经生效。
		if (wanTouched) {
			let r = applyWanAccess(cfg, cfg.wanAccess);
			if (!r.ok) {
				jsonResponse(conn, 200, {
					ok: false,
					error: r.error,
					changed: changed,
					wan: wanAccessStatus(cfg),
				});
				return;
			}
			logInfo('wan: ' + (cfg.wanAccess ? 'on' : 'off') +
				(cfg.wanAccess ? ' (wan:' + cfg.wanPort + ' -> lan:' + cfg.port + ')' : ''));
		}

		logInfo('admin saved config: ' + join(',', changed) + who);
		jsonResponse(conn, 200, {
			ok: true,
			changed: changed,
			wan: wanAccessStatus(cfg),
		});
		return;
	}

	// 公网访问：单独查询实际生效状态
	if (path === '/admin/api/wan' && method === 'GET') {
		jsonResponse(conn, 200, { ok: true, wan: wanAccessStatus(cfg) });
		return;
	}

	jsonResponse(conn, 404, { error: { message: 'no such admin endpoint' } });
}

// 用当前池中下一个凭据发起上游请求。
// 失败（限流 / 鉴权失败 / 空响应）时自动换凭据重试，直到用完 tryLimit。
// ---------- 指标快照（GET /metrics，v1.8.0） ----------
//
// 只读，不重置任何计数器（进程重启即清零；要看趋势请由外部定期抓取留存）。
//
// 分位数来自固定桶直方图，是**桶上界**而非精确值：p99=300 应读作
// "99% 的样本 ≤300ms"，语义与 Prometheus 的 histogram_quantile 一致。
// -1 表示落在溢出桶，即 >30000ms。
function metricsSnapshot() {
	let upsOut = [];
	let all = loadUpstreams();
	for (let u in all) {
		let mu = metrics.up[u.id] || { ok: 0, fail: 0, rateLimited: 0, authFail: 0 };
		let keysOut = [];
		for (let k in u.keys) {
			let mk = metrics.key[u.id + '|' + maskKey(k)];
			let st = upState[u.id + '|' + k];
			let cool = 0;
			if (st && st.coolUntil > time()) cool = st.coolUntil - time();
			push(keysOut, {
				key: maskKey(k),
				// v2.0：per-Key 权重与用量（管理页展示用）
				weight: (u.weights && +u.weights[k] >= 1) ? +u.weights[k] : 1,
				usage: metrics.usageByKey[u.id + '|' + maskKey(k)] || { prompt: 0, completion: 0, total: 0 },
				usageText: fmtUsage(metrics.usageByKey[u.id + '|' + maskKey(k)]),
				ok: mk ? mk.ok : 0,
				fail: mk ? mk.fail : 0,
				rateLimited: mk ? mk.rateLimited : 0,
				authFail: mk ? mk.authFail : 0,
				coolingSec: cool,
				// v2.1.0：429/限流类失败次数（失败分类后与 fails 分开展示）
				probs: st ? (st.probs || 0) : 0,
				lastErr: (mk && mk.lastErr) ? mk.lastErr : ((st && st.lastErr) || ''),
			});
		}
		let bb = upBrake[u.id] || { hits: 0, winStart: 0, openUntil: 0, trip: 0, waited: 0, rejected: 0 };
		let bLeft = (bb.openUntil > time()) ? (bb.openUntil - time()) : 0;
		push(upsOut, {
			id: u.id, prefix: u.prefix, enabled: u.enabled,
			ok: mu.ok, fail: mu.fail,
			rateLimited: mu.rateLimited, authFail: mu.authFail,
			// v2.0：该上游的累计 token 用量（管理页展示用）
			usage: metrics.usageByUp[u.id] || { prompt: 0, completion: 0, total: 0 },
			usageText: fmtUsage(metrics.usageByUp[u.id]),
			inflight: upInflight['up:' + u.id] || 0,
			// v1.8.1 限流刹车状态。open=true 表示此刻正在闭闸，
			// trips 是历史闭闸次数 —— 与 rateLimited 一起看就能算出压缩比。
			brake: {
				enabled: cfg.brakeHits > 0,
				open: bLeft > 0,
				leftSec: bLeft,
				hits: bb.hits,
				trips: bb.trip,
				waited: bb.waited,
				rejected: bb.rejected,
			},
			keys: keysOut,
		});
	}

	// 闸门键 -> 在途数。只列非零项，免得快照被一堆 0 撑满读不出重点。
	let inflight = { wb: upInflight['wb'] || 0, total: 0 };
	for (let k in upInflight) {
		inflight.total += upInflight[k];
		if (substr(k, 0, 3) === 'up:' && upInflight[k] > 0) inflight[k] = upInflight[k];
	}

	// 排队中的请求按上游分组，看清是谁在等谁
	let waiting = { total: 0 };
	for (let c in chatQueue) {
		if (c.closed || c.gateHeld) continue;
		let k = c.gateKey || '?';
		waiting[k] = (waiting[k] || 0) + 1;
		waiting.total++;
	}

	return {
		ok: true,
		service: 'luci-app-workbuddy',
		version: APP_VERSION,
		since: metrics.since,
		uptimeSec: time() - metrics.since,
		chat: {
			total: metrics.chatTotal,
			ok: metrics.chatOk,
			fail: metrics.chatFail,
			clientErr: metrics.chatClientErr,
			rateLimited429: metrics.rateLimited429,
			// v2.1.0：客户端断开 / 截断流 / 写失败单独成桶，不再混在 ok 里。
			aborted: metrics.chatAborted,
			truncated: metrics.truncated,
			sendFail: metrics.sendFail,
		},
		queue: {
			inflight: inflight,
			waiting: waiting,
			queuedTotal: metrics.queued,
			timeoutTotal: metrics.queueTimeout,
			rejectedTotal: metrics.queueRejected,
			maxDepth: cfg.queueMax,
			timeoutSec: cfg.queueTimeout,
		},
		limits: {
			upMaxInflight: cfg.upMaxInflight,
			wbMaxInflight: cfg.wbMaxInflight,
		},
		// v2.2.0：中转决策日志。relay 是"轮换规则好不好"的唯一客观依据 ——
		// switch/exhaust 比、各账号 ok/rate 比、coolSec 占比，都从这里读。
		// 抽成 relaySnapshot() 是因为 /admin/api/state 也要用它，
		// 两处各写一份迟早会漂移。
		relay: relaySnapshot(time() - metrics.since),
		// 直连 vs 池化：同一批上游、同一套口径，这两个数就是池化的净收益
		ttfbMs: {
			pool: metricStat(metrics.mode.pool.ttfb),
			direct: metricStat(metrics.mode.direct.ttfb),
		},
		totalMs: {
			pool: metricStat(metrics.mode.pool.total),
			direct: metricStat(metrics.mode.direct.total),
		},
		pool: {
			enabled: cfg.usePool,
			usable: poolUsable(),
			port: cfg.poolPort,
			failCooldownSec: POOL_FAIL_COOLDOWN,
			requests: metrics.pool.used,
			fallbacks: metrics.pool.fallback,
		},
		// v1.8.1 上游限流刹车：配置 + 全局计数。每条上游的实时状态在 upstreams[].brake。
		brake: {
			enabled: cfg.brakeHits > 0,
			hits: cfg.brakeHits,
			windowSec: cfg.brakeWindow,
			brakeSec: cfg.brakeSec,
			maxRetryAfterSec: cfg.brakeMaxRa,
			rejectedTotal: metrics.brakeRejected,
			waitedTotal: metrics.brakeWaited,
		},
		// v2.0：token 用量统计（累计，进程重启即清零）
		usage: {
			prompt: metrics.usage.prompt,
			completion: metrics.usage.completion,
			total: metrics.usage.total,
			text: fmtUsage(metrics.usage),
			byUp: metrics.usageByUp,
			byKey: metrics.usageByKey,
			byClient: metrics.usageByClient,
		},
		upstreams: upsOut,
	};
}

function dispatch(conn, head, body) {
	let req = parseHead(head);
	let method = req.method;
	// 分离 path 与 query
	let qIdx = index(req.path, '?');
	let path = (qIdx >= 0) ? substr(req.path, 0, qIdx) : req.path;
	let query = (qIdx >= 0) ? substr(req.path, qIdx + 1) : '';

	// CORS 预检（v1.7.1）：外部浏览器/小程序跨域调用需要，204 直接放行。
	if (method === 'OPTIONS') {
		rawResponse(conn, 204, 'text/plain', '', {
			'Access-Control-Allow-Origin': '*',
			'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
			'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
			'Access-Control-Max-Age': '86400',
		});
		return;
	}

	// /health 始终放行，便于探活与端口映射自检
	let isHealth = (method === 'GET' && path === '/health');

	// ---------- 管理页：独立鉴权，不走 API 密钥 ----------
	if (path === '/admin' || substr(path, 0, 7) === '/admin/') {
		handleAdmin(conn, req, method, path, query, body);
		return;
	}

	if (!isHealth && authRequired(cfg)) {
		let hit = matchApiKey(cfg, req.headers, query);
		if (hit === null) {
			logErr(sprintf('unauthorized request from %s to %s', conn.ip || '?', path));
			jsonResponse(conn, 401, {
				error: {
					message: 'unauthorized: 缺少或无效的 API 密钥',
					hint: '请携带 Authorization: Bearer <密钥> 或 X-API-Key 头',
				},
			});
			return;
		}
		conn.apiKeyName = hit.name || hit.id || '';
	}

	// GET /health
	//
	// 注意：本接口会调用 loadPool()。在 v1.7.5 之前，loadPool() 每个凭据要
	// 解析 JWT 两次（credStatus 一次、取 sub 一次），在本机 ARMv8 上单次
	// 解析 31ms，于是这个"轻量探活接口"实测要 66ms，而转发链路的同类开销
	// 更高（130ms）。现已由 parseJwt 记忆化消除，本接口回到 3ms 量级。
	if (isHealth) {
		let pool = loadPool(cfg);
		let ups = loadUpstreams();
		let upEnabled = 0;
		let upKeys = 0;
		for (let u in ups) {
			if (u.enabled) upEnabled++;
			upKeys += length(u.keys);
		}
		jsonResponse(conn, 200, {
			ok: true, service: 'luci-app-workbuddy',
			hasToken: (length(pool) > 0),
			credentials: length(pool),
			credState: credSummary(pool),
			authRequired: authRequired(cfg),
			apiKeysDefined: apiKeysDefined(),
			apiKeysActive: length(loadApiKeys()),
			onlyFreeModels: cfg.onlyFree,
			clientVersion: clientVersion(cfg),
			autoClientVersion: cfg.autoVersion,
			adminEnabled: adminEnabled(cfg),
			upstreams: length(ups),
			upstreamsEnabled: upEnabled,
			upstreamKeys: upKeys,
			modelRefreshEnabled: cfg.modelRefreshEnabled,
			modelRefreshHour: cfg.modelRefreshHour,
			version: APP_VERSION,
		});
		return;
	}

	// GET /metrics —— 可观测指标（v1.8.0）
	//
	// 与 /health 不同，这里**不绕过鉴权**：快照含每把 Key 的掩码、失败原因、
	// 队列深度与流量规模，属运维信息，不该跟着 wan_access 一起暴露到公网。
	if (method === 'GET' && path === '/metrics') {
		jsonResponse(conn, 200, metricsSnapshot());
		return;
	}

	// GET /models, /v1/models
	if (method === 'GET' && (path === '/models' || path === '/v1/models')) {
		let list = availableModels(cfg);
		let data = [];

		// 全部来源统一带供应商前缀，客户端一眼看出模型来自哪：
		//   workbuddy/deepseek-v4.1-flash   ← 本机 WorkBuddy 自身
		//   sensenova/deepseek-v4-flash     ← 自定义上游
		// 设计取舍：统一加前缀虽然有悖"改动最小"，但混用（一部分带、一部分不带）
		// 会让客户端无法判断某个模型到底该走哪个上游 —— 例如名字恰好叫
		// "sensenova/xxx" 的原生模型会被误路由。统一加前缀消除这种歧义。
		for (let m in list) {
			let e = { id: WB_PREFIX + '/' + m.id, name: m.name, object: 'model' };
			if (m.contextWindow) e.context_window = m.contextWindow;
			if (m.maxTokens) e.max_tokens = m.maxTokens;
			push(data, e);
		}

		// 追加自定义上游的模型（逐个上游拉取其 /models）
		//
		// 实测：这一步原来每次都真去外呼上游，单个上游就要 1.66s —— 客户端每次
		// 列模型都得干等，而模型列表几分钟内根本不变。改为按 TTL 缓存；管理页
		// 改动上游会清缓存（见 saveUpstreamsFile），也可用 ?refresh=1 强制刷新。
		let forceRefresh = (index(query, 'refresh=1') >= 0);
		let ups = loadUpstreams();
		for (let u in ups) {
			if (!u.enabled) continue;
			// v2.7.0：管理员显式配了模型清单时，以它为准，**不外呼上游**。
			// 这样上游挂掉/限流也不会让 /v1/models 变空，也省掉一次 1.66s 的外呼；
			// 清单里出现的是对外的名字（别名），映射在 adaptBody 里做。
			if (type(u.modelList) === 'array' && length(u.modelList) > 0) {
				for (let mid in u.modelList) {
					push(data, {
						id: u.prefix + '/' + mid,
						name: mid + ' · ' + u.name,
						object: 'model',
						provider: u.prefix,
						base_url: u.baseUrl,
					});
				}
				continue;
			}
			let ck = u.prefix + '|' + u.baseUrl + '|' + length(u.keys);
			let ce = upModelCache[ck];
			let remote;
			if (!forceRefresh && ce && (time() - ce.at) < UP_MODEL_TTL) {
				remote = ce.list;
			} else {
				remote = fetchUpstreamModels(u);
				// 只在成功时写缓存：上游临时限流返回空列表时，别把它缓存 5 分钟
				if (length(remote) > 0) {
					upModelCache[ck] = { at: time(), list: remote };
					saveModelCache();
				} else if (ce && type(ce.list) === 'array' && length(ce.list) > 0) {
					// v2.8.0：上游暂时拉不到模型（限流/抖动），用最后已知列表兜底，
					// 避免上游抖动时 /v1/models 突然变空、客户端以为自己配错了。
					remote = ce.list;
				}
			}
			for (let m in remote) {
				push(data, {
					id: u.prefix + '/' + m.id,
					name: m.id + ' · ' + u.name,
					object: 'model',
					provider: u.prefix,
					base_url: u.baseUrl,
				});
			}
		}
		jsonResponse(conn, 200, { object: 'list', data: data });
		return;
	}

	// GET /upstreams —— 自定义上游状态（不含 Key 明文，仅掩码）
	if (method === 'GET' && path === '/upstreams') {
		jsonResponse(conn, 200, { ok: true, upstreams: upstreamStatus() });
		return;
	}

	// GET /credentials —— 查看凭据池状态（不含 token 本身）
	if (method === 'GET' && path === '/credentials') {
		let pool = loadPool(cfg);
		let now = time();
		let out = [];
		for (let c in pool) {
			let st = credState[c.id] || {};
			push(out, {
				id: c.id,
				source: c.source,
				cooling: (st.coolUntil || 0) > now,
				coolRemain: ((st.coolUntil || 0) > now) ? ((st.coolUntil || 0) - now) : 0,
				fails: st.fails || 0,
				lastError: st.lastErr || '',
			});
		}
		jsonResponse(conn, 200, { ok: true, count: length(out), credentials: out });
		return;
	}

	// GET /login
	if (method === 'GET' && path === '/login') {
		let r = startWebLogin(cfg);
		jsonResponse(conn, r.ok ? 200 : 502, r);
		return;
	}

	// GET /login/status
	if (method === 'GET' && path === '/login/status') {
		let pool = loadPool(cfg);
		jsonResponse(conn, 200, {
			hasToken: (length(pool) > 0),
			credentials: length(pool),
			loginRunning: login.running,
			loginOk: login.ok,
			lastError: login.lastError,
			authUrl: login.authUrl,
			cacheFile: tokenPath(cfg),
		});
		return;
	}

	if (method !== 'POST') {
		jsonResponse(conn, 405, { error: { message: 'method not allowed' } });
		return;
	}

	// v2.0：只有 chat/completions 走完整适配链（插 system/强制流式/onlyFree）。
	// 其余 OpenAI 兼容端点（/v1/embeddings、/v1/responses 等）原样透传。
	if (path !== '/v1/chat/completions' && path !== '/chat/completions') {
		handlePassthrough(conn, body, path);
		return;
	}

	handleChat(conn, body);
}

// ---------- 连接读取与接受 ----------
// 注意：ucode 的函数声明不提升（no hoisting），被引用的函数必须先定义。
// 因此这里的顺序固定为：onData（引用 dispatch）→ onAccept（引用 onData）。

function onData(conn) {
	if (conn.closed) return;

	let chunk;
	try {
		chunk = conn.sock.recv(8192);
	} catch (e) {
		// v2.1.0：客户端断开是"abort"，单独计数，不再被误记为成功。
		conn.aborted = true;
		closeConn(conn);
		return;
	}

	if (chunk === null || length(chunk) === 0) {
		// v2.1.0：同上 —— recv 返回 null/空即对端关闭或连接已断。
		conn.aborted = true;
		closeConn(conn);
		return;
	}

	conn.buf += chunk;

	// 找 header 结束
	if (conn.headerEnd < 0) {
		let idx = index(conn.buf, '\r\n\r\n');
		if (idx < 0) {
			if (length(conn.buf) > 65536) closeConn(conn);
			return;
		}
		conn.headerEnd = idx + 4;
		let head = substr(conn.buf, 0, idx);
		conn.head = head;
		let cl = match(head, /\r\nContent-Length:\s*([0-9]+)/i);
		conn.bodyLen = cl ? +cl[1] : 0;
		// v2.1.0：入站请求体上限 —— 超大 Content-Length 直接 413，不等待读满。
		if (conn.bodyLen > MAX_BODY_BYTES) {
			jsonResponse(conn, 413, { error: { message: 'request body too large (>8MiB)' } });
			return;
		}
	}

	let got = length(conn.buf) - conn.headerEnd;
	if (got < conn.bodyLen) return;

	let body = substr(conn.buf, conn.headerEnd, conn.bodyLen);
	try {
		dispatch(conn, conn.head, body);
		// v2.1.0：HTTP/1.1 连接复用 bug 修复 —— 本服务响应一律 Connection: close，
		// 一条连接只服务一个请求。若不在此取消读句柄，同一连接上的第二个请求
		// 会在首个 SSE 流仍在飞行时重入 dispatch，覆盖 conn.proc/sseBuf/upKeys，
		// 使首个上游变孤儿。取消后 closeConn 仍会安全地再次 cancel（已置 null）。
		try { if (conn.handle) conn.handle.cancel(); } catch (e) { }
		conn.handle = null;
	} catch (e) {
		logErr('dispatch error: ' + e);
		jsonResponse(conn, 500, { error: { message: '' + e } });
	}
}

function onAccept(listenSock) {
	let addr = {};
	let peer = listenSock.accept(addr, socket.SOCK_CLOEXEC);
	if (!peer) return;

	// 关闭 Nagle 算法：让 SSE 的逐字小分片立即发出，显著降低流式延迟
	try { peer.setopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true); } catch (e) { }

	let conn = {
		sock: peer,
		buf: '',
		handle: null,
		headersSent: false,
		closed: false,
		bodyLen: 0,
		headerEnd: -1,
		ip: (addr && addr.address) ? addr.address : '?',
		// v2.1.0：新连接默认字段 —— abort 标记（客户端断开/写失败）、
		// 截断检测与请求级关联 ID（由 handleChat/handlePassthrough 填充）。
		aborted: false,
		writeBroken: false,
		sawDone: false,
		reqId: '',
		hdrFile: null,
	};
	push(connections, conn);

	// ULOOP_BLOCKING：本 ucode 版本中，若 fd 被置为非阻塞，socket/proc 的
	// recv()/read() 会因 EAGAIN 返回 null 而被误判为 EOF。加此标志保证读取可靠。
	conn.handle = uloop.handle(peer, () => onData(conn), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// ---------- 上游静默看门狗 ----------
//
// 目的：上游连接建立后长时间一个字节都不回（限流挂起、链路黑洞）时，主动断开
// 并按既有重试链换 Key，而不是让客户端一直等到自己超时。
//
// 实测背景：修复前同一个聊天请求出现过 1.82s / 12.45s / 60s+（客户端 --max-time
// 到点收 0 字节）三种结果，日志里是限流错误 + 固定 2 秒冷却导致的反复重试。
//
// 注意：uloop.timer 是一次性的（本文件 schedulePoll 也是每轮自己重排），
// 所以每轮扫描结束必须再排一次。
//
// 分档逻辑（v1.8.2）：用 conn.attemptBytes 是否为空判断"还没收到过任何字节"。
// attemptBytes 在每次尝试开始时清零（spawnUpstream / spawnUpstreamDirect），
// 收到字节就累加，所以它天然就是"本次尝试是否已被上游受理"的标志位。
//   - attemptBytes === 0：请求还没被受理 → 用 up_first_byte_sec（默认 12s）
//   - attemptBytes > 0  ：流已建立、中途卡住 → 用 up_idle_sec（默认 25s）
function watchdogTick() {
	let now = time();
	for (let c in connections) {
		if (c.closed || !c.proc) continue;
		let last = c.lastByteAt || 0;
		if (last === 0) continue;
		let idle = now - last;

		// 首字节前 vs 流中，两档阈值与两套日志文案
		let waitingFirstByte = !c.upstream || (c.attemptBytes || 0) === 0;
		let limit, phase;
		if (!c.upstream) {
			limit = cfg.wbIdleSec;
			phase = 'wb';
		} else if (waitingFirstByte) {
			limit = cfg.upFirstByteSec;
			phase = '首字节';
		} else {
			limit = cfg.upIdleSec;
			phase = '流中';
		}
		// 0 = 该档关闭
		if (limit === 0 || idle < limit) continue;

		// 日志区分两档：首字节档是"上游根本没受理"，流中档是"受理了但断流"，
		// 排查时是完全不同的两个结论，不能混在一行里。
		let which = (c.upstream ? (c.upTry || 0) : (c.tries || 0));
		if (phase === '首字节') {
			logErr(sprintf('upstream no first byte in %ds (>=%ds, key#%d, client %s), failover',
				idle, limit, which, c.ip || '?'));
		} else {
			logErr(sprintf('upstream stalled %ds mid-stream (>=%ds, attempt %d, client %s), aborting',
				idle, limit, which, c.ip || '?'));
		}

		// 先刷新计时，避免下一轮又对同一条连接重复触发
		c.lastByteAt = now;

		if (c.headersSent) {
			// 已开始向客户端推流，无法回退重试，只能收尾
			closeConn(c);
			continue;
		}
		// 失败原因带上档位，冷却分档（isRateLimitReason）与事后统计都能看出来源
		let why = (phase === '首字节')
			? ('上游 ' + idle + 's 未返回首字节')
			: ('上游流中静默 ' + idle + 's');
		if (c.upstream) F.tryNextUpKey(c, why);
		else F.tryNextCred(c, why);
	}
	idleTimer = uloop.timer(UP_IDLE_TICK_MS, () => watchdogTick());
}

// ---------- 启动 ----------

function main() {
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
	// backlog 128：本服务对公网开了 18889（wan_access=1），默认 64 在突发时
	// 会丢 SYN；内核 somaxconn 已是 4096，这里跟上即可。
	if (!listenSock.listen(128)) {
		logErr('listen failed: ' + listenSock.error());
		return;
	}

	uloop.handle(listenSock, () => onAccept(listenSock), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);

	// v1.8.3 上游响应回环桥：让 curl 的 stdout 经 nc 回环到本地 socket，
	// 规避 popen 管道并发读丢数据。监听失败会自动回退并打日志。
	bridgeStart();

	let pool = loadPool(cfg);
	let keys = loadApiKeys();
	logInfo(sprintf('listening on %s:%d -> %s (credentials=%d, apikeys=%d, auth=%s)',
		cfg.host, cfg.port, cfg.endpoint, length(pool), length(keys),
		authRequired(cfg) ? 'on' : 'OFF'));

	if (length(pool) === 0)
		logInfo('no credential yet - visit /login or call any model to start login');
	if (!authRequired(cfg))
		logInfo('warning: no API key configured, service is open to anyone who can reach it');
	if (cfg.onlyFree)
		logInfo('only_free_models: on (收费模型将被过滤，chat 自动替换为免费模型)');

	// 预热模型缓存：启动 1.5 秒后后台拉取一次，避免首个 /models 请求等待。
	// 拉取是阻塞的，但只发生一次，且监听已先就绪。
	uloop.timer(1500, () => {
		if (length(loadPool(cfg)) === 0) return;
		availableModels(cfg);
		logInfo('model cache warmed');
	});

	// 启动上游静默看门狗（自身按 UP_IDLE_TICK_MS 反复重排，句柄需持有）
	idleTimer = uloop.timer(UP_IDLE_TICK_MS, () => watchdogTick());

	// 启动排队超时扫描（同样自重置，句柄必须持有，否则定时器会被回收）
	queueTimer = uloop.timer(UP_QUEUE_TICK_MS, () => queueTick());

	// v2.8.0：载入「最后已知可用」模型列表（上游抖动时 /v1/models 的兜底），
	// 并启动每日模型巡检定时器（默认凌晨 1 点拉取最新模型 + 全模型连通性测试）。
	loadModelCache();
	modelRefreshTimer = uloop.timer(MODEL_REFRESH_CHECK_MS, () => modelRefreshTick());

	logInfo(sprintf('forward tuning: idle=%ds/%ds first_byte=%ds rate_cool=%ds/%ds model_ttl=%ds backlog=128',
		cfg.upIdleSec, cfg.wbIdleSec, cfg.upFirstByteSec, UP_RATE_COOL, UP_RATE_COOL_MAX, UP_MODEL_TTL));
	// 上限为 0 是"不限流"而不是"闸门值 0"，日志里必须一眼看出这个区别
	logInfo(sprintf('concurrency: up_inflight=%s wb_inflight=%s queue_max=%d queue_timeout=%ds',
		cfg.upMaxInflight === 0 ? 'unlimited' : ('' + cfg.upMaxInflight),
		cfg.wbMaxInflight === 0 ? 'unlimited' : ('' + cfg.wbMaxInflight),
		cfg.queueMax, cfg.queueTimeout));
	logInfo(sprintf('connection pool: %s (port=%d fail_cooldown=%ds)',
		cfg.usePool ? 'on' : 'off', cfg.poolPort, POOL_FAIL_COOLDOWN));
	logInfo(sprintf('upstream bridge: %s (port=%d)',
		cfg.bridgePort > 0 ? 'on' : 'off', cfg.bridgePort));
	// 刹车关闭时也要明确打出来，否则事后翻日志分不清"没触发"和"被关了"
	logInfo(sprintf('rate-limit brake: %s (hits=%d/%ds -> brake %ds, retry_after max %ds)',
		cfg.brakeHits > 0 ? 'on' : 'off',
		cfg.brakeHits, cfg.brakeWindow, cfg.brakeSec, cfg.brakeMaxRa));

	// v2.8.0：模型巡检排期。关闭时同样要打出来，便于事后区分"没跑"与"被关了"。
	logInfo(sprintf('model refresh: %s (daily %02d:00, test timeout %ds, max %d models/upstream)',
		cfg.modelRefreshEnabled ? 'on' : 'off',
		cfg.modelRefreshHour, MODEL_TEST_TIMEOUT, MODEL_TEST_MAX_PER_UP));

	uloop.run();
	uloop.done();
}

main();
