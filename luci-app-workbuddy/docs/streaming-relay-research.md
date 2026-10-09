# SSE 流式反向代理工程实践研究 —— 对 `luci-app-workbuddy` 的差距审计

审计对象（钉死版本）：`files/usr/share/ucode/workbuddy.uc`
`sha256=249104EC287875577BFAF57C19B9C39563873DBB75247F10DC96FD7D6EC19D8B`，257270 字节，6608 行，
对应提交 `a2f30f8 v2.0.1: deep slimming - remove dead code, extract shared helpers, lightweight pass`。
**注意：本文写作期间仓库从 v1.8.4 连跳到 v2.0.1，早期行号已全部失效；下文所有行号均按上述 sha256 复核过。引用前请重新 grep。**

已排除（任务书明确要求不得作为"新发现"重复报告）：16384 字节读边界下游截断；`[DONE]` 之后不关下游连接；
阻塞式 `pclose()`/`waitpid()` 冻结单线程事件循环；阻塞 popen 管道上 EAGAIN 与 EOF 不可区分。

---

## 一、执行摘要（5 行）

1. 该中继在**协议正确性**上明显好于同类小网关：`Connection: close` 承担了真实的分帧职责（RFC 9112 §7.1）、逐字节透传不做重分帧、`conn.headersSent` 之后一律不重试（与 nginx `proxy_next_upstream` 的核心约束一致）。
2. 最大的**结构性缺口是完全没有背压**：6 处 `send()` 无一处检查返回值，`ULOOP_WRITE`/`shutdown` 出现 0 次，收发两端都是阻塞 fd，而无上限累积的 `sseBuf` 在非流式路径（`workbuddy.uc:3455`、`3466`）没有 2 MiB 上限 —— 这是 968MB 设备上唯一具备"内存炸弹"形态的地方。
3. 第二大缺口是**上游 HTTP 状态与全部限流响应头不可见**：chat 路径的 curl 既无 `-i` 也无 `-D`，失败判定靠 `isRateLimitReason`/`isAuthReason` 的**子串匹配**；而 Anthropic 的 spend-cap 429 与普通限流 429 **error type 完全相同、只差一个缺失的 `retry-after`**，子串匹配在原理上无法区分。
4. 重试策略缺少两件生产网关的标配：**时间预算**（nginx `proxy_next_upstream_timeout`、Envoy `per_try_timeout`）与**抖动**（AWS/Envoy/SRE 一致要求）；当前重试被钉在 `len(upKeys)`（实测 4 次）且零抖动，`rand()` 不可用使这项修复必须走 `readRandom()`。
5. 观测口径只有 TTFB 与 total 两个直方图（`metricsSnapshot` 内 `ttfbMs`/`totalMs`），桶界 `1500/2000/3000 ms` 使 README 自己抱怨的 ~300 ms 连接复用收益**在原理上不可测**；且 `recordConnMetrics`（`workbuddy.uc:1383-1390`）没有 abort 桶，客户端取消与流被截断在 `/metrics` 里都记成 `chatOk`。

---

## 二、优先级表

| 优先级 | 实践 | 防止的故障 | 在单线程 ucode 中怎么实现 | 跳过的风险 |
|---|---|---|---|---|
| **P0** | 给非流式与错误嗅探路径的 `sseBuf` 加上限 | 单个超大响应把 968MB 设备打爆（OOM killer 杀掉整个网关） | `workbuddy.uc:3455`/`3466` 改成与 `3479` 同款 `if (length(conn.sseBuf) < N) conn.sseBuf += chunk;`，并把 N 做成 uci 项；超限时置 `conn.sseTruncated = true` 并在收尾日志标注 | 上游返回 10MB 非流式响应即进程死亡；设备上其他服务一并遭殃 |
| **P0** | 检查 `send()` 返回值，落一条短写计数 | 客户端停止读取时中继仍以为"已送达"，静默丢数据 | `send()` 返回实际写入字节数（`lib/socket.c` `uc_socket_inst_send`），把 6 处调用改为 `let w = conn.sock.send(x); if (w < length(x)) metrics.shortWrite++;`；`< 0` 已经会 throw | 下游截断无任何痕迹；`/metrics` 显示一切正常 |
| **P0** | 修 `onData` 的 pipeline 重入 | 同一连接上第二个请求在首个 SSE 流仍在飞行时重新进入 `dispatch`，导致二次 `handleChat`、覆盖 `conn.proc`/`sseBuf`、上游连接与闸门额度双份占用 | `dispatch()` 之后立刻 `conn.headerEnd = -1; conn.bodyLen = 0; conn.buf = '';`，或在 `conn.headersSent` 时对后续请求直接 `jsonResponse(..., 409)`；`conn.handle` 不必取消（`Connection: close` 已声明） | 上游请求数凭空翻倍（与刹车注释里记录的 2.25× 放大同类）、`connections` 表出现孤儿、用量统计错乱 |
| **P1** | 让上游状态码可见：curl 加 `-D <file>` | 所有基于子串的失败判定（`isRateLimitReason`/`isAuthReason`/`upstreamLooksFailed`）的系统性误判 | `curlArgs()`（`workbuddy.uc:3385-3423`）加 `push(args, shquote('-D')); push(args, shquote(conn.hdrFile));`，收尾时读文件解析状态行与 `Retry-After`/`x-ratelimit-*`。`-D` 写文件，**不污染 stdout 的逐字节 SSE** | 429/401/5xx 全部靠猜；Anthropic spend-cap 429 被当成可重试限流，反复冷却换 Key 直到烧穿 |
| **P1** | 真正读取并翻译上游 `Retry-After` | 客户端被喂本地拍脑袋的固定值（现在恒为 5s 或本地 `upEarliestRetrySec`） | 解析两种语法（RFC 9110 §10.2.3 `HTTP-date / delay-seconds`），再解析 `x-ratelimit-reset-*` 的 `6m0s` 时长后缀格式（OpenAI）、`retry-after-ms` 毫秒格式（Azure）；回给客户端时统一成 `delay-seconds` 并保留上限 | 上游说等 56s，中继说等 5s → 客户端立刻重试 → 触发 Anthropic **加速限制**（retry 本身造成二次 429） |
| **P1** | 重试加**时间预算**（不只是次数） | 4 次重试 × 每次最长 12s/25s/900s 的链式等待，请求挂到客户端彻底超时 | 在 `conn.attemptAt` 之外加 `conn.firstAttemptAt`，`tryNextCred`/`tryNextUpKey` 里判断 `time() - conn.firstAttemptAt > budget` 则放弃换 Key 直接返回 502/429 | 客户端的 p99 被重试链拉长到分钟级（README 的 `34.03s → 5.18s` 正是在治这个症状） |
| **P1** | 重试加**抖动** | 上游限流恢复瞬间 N 个客户端同时重试，把上游再次打垮（thundering herd） | ucode 无 `rand()`（`workbuddy.uc:110` 注释明确），必须用 `readRandom()` 读 `/dev/urandom` 生成抖动；`uloop.timer(base + jitter, ...)` 改 `workbuddy.uc:3618` 的单发尾等待 | 刹车自己造成的"整齐放行"，与 AWS 博客里 no-jitter 那条"clear loser"曲线同形 |
| **P1** | 客户端取消要会计入统计（abort 桶） | 取消/截断在 `/metrics` 里被记成成功，运维看不到真实失败率 | `recordConnMetrics`（1383-1390）增加判定：`conn.headersSent` 且未见到终止标记（OpenAI 的 `[DONE]` / Anthropic 的 `message_stop`）⇒ 计入 `chatAbort` | 用 p90 调优时基线被污染；"上游静默截断"类故障永久隐形 |
| **P2** | 流式路径也检查终止标记 | 无法区分"上游正常结束"与"上游被截断" | 流式转发是逐字节透传（正确，别改），但要**旁路记账**：在已进入 `sseBuf` 的尾部（2 MiB 窗口内）搜 `[DONE]`/`message_stop`，只置标志不干预转发 | OpenAI 官方 200 响应说明明确写 "An interrupted stream may end without the marker" —— 不记账就等于放弃这条唯一的完整/截断判据 |
| **P2** | 给入站请求体加上限 | 恶意/失控客户端用巨大 `Content-Length` 让中继无限累积 `conn.buf` | `onData`（`workbuddy.uc:6411`）已有 65536 的 header 上限，给 body 也加一条 `if (conn.bodyLen > MAX_BODY) { jsonResponse(conn, 413, ...); return; }` | 968MB 设备上单连接即可吃掉可观内存（当前 0 处防护：`max_body|body_limit|413` 全部 0 命中） |
| **P2** | 发 SSE 注释行做心跳 | 中间设备（NAT/反代）静默丢弃空闲绑定，客户端干等到自己超时 | `sseHeaders()` 之后起一个 `uloop.timer`，每 N 秒写一次 `: ping\n\n`（SSE 规范把 `:` 开头的行定义为注释，客户端忽略；MDN 明确推荐此抗超时手段）。当前 0 处实现 | 长思考（WorkBuddy agent 路径 `wb_idle_sec=75`）期间链路被中间盒掐断 |
| **P2** | 采纳 OTel GenAI 的直方图桶界 | 桶界太粗导致优化无法验证（README 565-574 自述"分辨不出 300ms 差异"） | 把 `METRIC_BUCKETS`（`workbuddy.uc:1251-1254`）替换为 `[10,20,40,80,160,320,640,1280,2560,5120,10240,20480,40960,81920]`（ms） | 池化的净收益永远只能靠外挂 curl A/B 估，而 README 已记录那条路"得不出结论" |
| **P2** | prompt cache 友好：不要无谓改写前缀 | 上游 prompt cache 永远不命中，成本与 TTFB 双输 | `adaptBody`（`workbuddy.uc:2931-2938`）在 `messages[0].role !== 'system'` 时**注入**一条 `system` 消息 —— 这会改变渲染后的前缀。改为只在确有需要时注入，或至少让它在会话内保持字节一致 | OpenAI 明确 "Cache reuse requires the entire rendered prefix to match"；注入等于给每条无 system 的请求都发一张新前缀 |
| **P3** | 粘性路由键改为"会话"而非"身份" | 多设备共用一个 API Key 时，同一会话被轮询到不同 Key，落不到持有缓存的那台机器 | 现在 `conn.stickyFor = conn.apiKeyName || conn.ip`（`workbuddy.uc:4226`、`4357`）。可增加对客户端 `conversation_id`/`user` 字段或请求体首页哈希的粘性，二者择一 | 命中率下降直接体现为成本与 TTFB 上升（OpenAI 提示 15 req/min 以上会 overflow routing） |
| **P3** | 半关闭（half-close）与优雅收尾 | 无法向上游表达"我不会再发请求了"，也让中间设备无法及早回收资源 | ucode 提供 `shutdown`（当前 0 处使用）；`uloop.ULOOP_WRITE`（0 处使用）可用于可写驱动排空 | 资源回收依赖 `close()` 的粗粒度语义；RFC 9112 §9.5 要求"graceful close" |

---

## 三、分项详述

### 3.1 客户端断开 / 取消传播与槽位泄漏

**标准做法。** nginx 把这件事做成了显式开关，且**默认值就是"传播"**：`proxy_ignore_client_abort on | off; Default: proxy_ignore_client_abort off` —— "Determines whether the connection with a proxied server should be closed when a client closes the connection without waiting for a response."（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）。`off` 意味着 nginx **会**因客户端断开而关闭到上游的连接；`on` 才是"忽略"。所以"客户端走了就掐上游"不是进阶特性，而是生产默认。

**HTTP 语义上，被放弃的请求不需要响应。** RFC 9110 §9.3.3 附近明确："Clients (including intermediaries) might abandon a request if the response is not received within a reasonable period of time."（https://www.rfc-editor.org/rfc/rfc9110.txt ）。同时 RFC 9112 §9.5："A client or server that wishes to time out SHOULD issue a graceful close on the connection. Implementations SHOULD constantly monitor open connections for a received closure signal and respond to it as appropriate, since prompt closure of both sides of a connection enables allocated system resources to be reclaimed."（https://www.rfc-editor.org/rfc/rfc9112.txt ）。**"不断监视收到的关闭信号并相应响应"是 RFC 直书的义务。**

**该中继的现状（做得对的部分）。** `onData`（`workbuddy.uc:6385-6403`）把 `recv` 抛异常、返回 `null`、返回空串三种情况全部导向 `closeConn`。`closeConn`（`workbuddy.uc:2772-2820`）顺序为：幂等标志 → 取消 `conn.handle`（2776）→ 取消 `conn.procHandle`（2779）→ `conn.proc.close()`（2782）→ `bridgeRelease(conn)`（2784，内部关闭桥 socket）→ `unlink(conn.tmpFile)`（2786）→ 从 `connections` 摘除（2794-2797）→ 清 `buf`/`sseBuf`（2798-2799）→ `sock.close()`（2802）→ `recordConnMetrics` → `F.releaseGate(conn)`。桥 socket 一关，`nc` 读到 EOF 退出，curl 吃 SIGPIPE 死掉 —— 这条链路是真的把取消传到了上游（`bridgeWrap` 设计注释 `workbuddy.uc:2664-2665` 记录了该机制）。`releaseGate` 只在 `closeConn` 里被调用，且被放在最后一步（注释 2805 "必须是本函数最后一步"，因为 `pumpQueue` 会把新连接 push 进 `connections`，早放会丢连接）—— 这一处是本次审计里最扎实的地方。

**仍存在的槽位/账目问题：**

1. **`/metrics` 里没有 abort 桶。** `recordConnMetrics`（`workbuddy.uc:1383-1390`）只有 `chatOk`（2xx）/`rateLimited429`+`chatFail`/`chatClientErr`/`chatFail` 四类，而 `sseHeaders`（`workbuddy.uc:2879`）在开始推流时就把 `conn.httpStatus = 200`。于是**客户端中途取消的请求被计为成功**。对照 vLLM 的生产指标体系，abort 是一等公民：`vllm:request_success_total` 带 finish-reason 标签，样本形如 `{finished_reason="stop"} 1.0`、`{finished_reason="length"} 131.0`、`{finished_reason="abort"} 0.0`（https://docs.vllm.ai/en/latest/design/metrics.html ）。
2. **看门狗永远不会回收"从未有过上游字节"的连接。** `watchdogTick`（`workbuddy.uc:6474-6479`）：`if (c.closed || !c.proc) continue; let last = c.lastByteAt || 0; if (last === 0) continue;`。`lastByteAt` 只在收到上游字节时刷新（`workbuddy.uc:3445`、`3536`、`3721`），**从不因客户端活动刷新**。排队中的连接靠 `queueTick`（`uloop.UP_QUEUE_TICK_MS=1000`，`workbuddy.uc:4098-4124`，队列超时由 `queue_timeout` 默认 20s 兜底）覆盖，但"已 spawn 上游、curl 还没吐出任何字节、且客户端也不再读"的连接，其回收只依赖 `onData` 收到 EOF。若客户端半关闭后仍保持连接（TCP 层面只是不发数据），这一档没有独立计时器。RFC 9112 §9.5 的"持续监视关闭信号"要求正是为这类情况写的。

### 3.2 背压与无界缓冲

**这是本审计中风险最高的一类，且不是"配置问题"而是"架构缺口"。**

**标准依据。** RFC 9113 §5.2.2 直接把中继的处境写成了流控存在的理由："Flow control is defined to protect endpoints that are operating under resource constraints. For example, **a proxy needs to share memory between many connections and also might have a slow upstream connection and a fast downstream one.**"（https://www.rfc-editor.org/rfc/rfc9113.txt ）。而 RFC 9112 §9.5 给出的是**相反方向的禁令**："A server SHOULD sustain persistent connections, when possible, and allow the underlying transport's flow-control mechanisms to resolve temporary overloads rather than terminate connections with the expectation that clients will retry. The latter technique can exacerbate network congestion or server load." —— 即"别靠断连接来挡过载，让传输层流控去解决"。

Node.js 把机制说到了可实现的精度："The moment that backpressure is triggered can be narrowed exactly to the return value of a Writable's `.write()` function. … In any scenario where the data buffer has exceeded the highWaterMark or the write queue is currently busy, `.write()` will return false. When a false value is returned, the backpressure system kicks in. It will pause the incoming Readable stream from sending any data and wait until the consumer is ready again. Once the data buffer is emptied, a 'drain' event will be emitted and resume the incoming data flow." 并强调其收益是"This effectively allows a **fixed amount of memory** to be used at any given time"（https://nodejs.org/en/learn/modules/backpressuring-in-streams ）。

生产代理的落地方式有两条，都很直白：
- nginx：`proxy_buffers number size; Default: proxy_buffers 8 4k|8k` —— "Sets the number and size of the buffers used for reading a response from the proxied server, **for a single connection**."（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）即**每连接**响应内存有确定上界。
- HAProxy：`tune.buffers.limit <number>` —— "Sets a hard limit on the number of buffers which may be allocated per process. … **Forcing this value can be particularly useful to limit the amount of memory a process may take**, while retaining a sane behavior. **When this limit is reached, sessions which need a buffer wait for another one to be released by another session.**"（https://docs.haproxy.org/2.8/configuration.html ）即**超限时排队等待，而不是继续缓冲**。

**该中继的现状：**

- **6 处 `send()` 无一处检查返回值。** `workbuddy.uc:2841`、`2868`、`2890`（`jsonResponse`/`rawResponse`/`sseHeaders`）；`3472`（`makeOnChunk` 内的 `conn.sock.send(chunk)`，包在 try/catch 里，catch 后 `closeConn`）；`3840`、`3859`（`try { conn.sock.send(raw); } catch (e) { }`，**异常被完全吞掉**）。而 ucode 的 `send()` 语义是明确的：`lib/socket.c` 的 `uc_socket_inst_send` 返回**实际写入的字节数**，并且总是把 `MSG_NOSIGNAL` 或进 flags，因此**短写既不报错也不抛异常**，只有 `-1` 才是错误（源码见 https://raw.githubusercontent.com/ucode-lang/ucode/master/lib/socket.c ）。结论：**一个部分写出的 SSE 分片在该中继里是不可观测、也未处理的**。
- **没有任何"可写驱动排空"路径。** `ULOOP_WRITE` 全文 0 次，`shutdown` 0 次，`ULOOP_EDGE_TRIGGER` 0 次。套接字选项只用了 4 处：`TCP_NODELAY`（`workbuddy.uc:2746` 桥 accept、`6439` 客户端 accept）与 `SO_REUSEADDR`（`2760` 桥监听、`6542` 客户端监听）。`SO_SNDBUF`/`SO_SNDTIMEO`/`SO_SNDLOWAT`/`TCP_USER_TIMEOUT`/`SO_RCVLOWAT`/`MSG_DONTWAIT` 按 ucode socket 模块文档全部可用（https://ucode.mein.io/module-socket.html ），**一个都没用**。
- **收发两端都是阻塞 fd。** `onAccept`（`workbuddy.uc:6455`）与两条 spawn 路径（`workbuddy.uc:3539`、`3724`）都带 `uloop.ULOOP_BLOCKING`。libubox 的实现决定了这个标志的含义：`uloop_fd_add()` 里 `if (!sock->registered && !(flags & ULOOP_BLOCKING)) { fl = fcntl(sock->fd, F_GETFL, 0); if (fl >= 0) fcntl(sock->fd, F_SETFL, fl | O_NONBLOCK); }`（https://raw.githubusercontent.com/openwrt/libubox/master/uloop.c ）。**中继主动选择了阻塞 fd，而阻塞 fd 上的 `send()` 在客户端不读时会一直阻塞在单线程事件循环里。** 顺带指出一处注释漂移：`workbuddy.uc:6453` 的理由写的是"若 fd 被置为非阻塞，socket/proc 的 recv()/read() 会因 EAGAIN 返回 null 而被误判为 EOF"，但 ucode 源码里 `uc_socket_inst_recv` 在出错时走 `err_return(errno, "recv()")`（即**抛异常**），`null` 的文档含义是"发生错误"，EOF 返回的是**空字符串**。注释与实现不一致（不影响结论，但会误导后续维护者）。
- **`sseBuf` 仍有两条无上限路径。** 有上限的是流式路径：`workbuddy.uc:3479` `if (length(conn.sseBuf) < 2097152) conn.sseBuf += chunk;`（2 MiB，注释说明是为收尾提取 usage）。**无上限的是**：`workbuddy.uc:3455`（`if (conn.wantNonStream) { conn.sseBuf += chunk; return; }`）与 `workbuddy.uc:3466`（首块错误嗅探 `if ((c === '{' || c === '<') && index(chunk, 'data:') < 0) { conn.sseBuf += chunk; return; }`）。任务书点名的"968MB 设备上的内存炸弹"，形态就在这里。
- **入站请求体也没有上限。** `onData` 对 header 有 65536 的护栏（`workbuddy.uc:6411`），但 body 只按 `Content-Length` 累积（`6417-6422`）；全文对 `max_body|body_limit|413` 的匹配为 **0 命中**。
- **`conn.buf` 在请求被 dispatch 之后不清空**（只在 `closeConn` 的 2798 行清）。正常 keep-alive 语义下这本身不是泄漏（`Connection: close`），但与 3.4 的重入问题叠加时，旧字节会参与下一次 header 搜索。

**可落地的修法（不引入 select/poll，仍用 uloop）。** 短期最有效的是"把隐含的阻塞变成显式上界"：给 6 处 `send()` 记短写计数，并在 `sseBuf` 的两条无上限路径加同款上限；进一步的做法是改用 `ULOOP_WRITE` 注册可写事件，把待发数据放进一个每连接有上限的发送队列，在可写回调里排空 —— 这正是 Node 的 `.write()→false→'drain'` 与 HAProxy "超限则等待"的等价物。

### 3.3 超时：首字节 / 流中静默 / 总时长

**三档的语义在生产代理里是分开的，且"读超时"被明确定义为**流中静默**而非总时长。** nginx `proxy_read_timeout`（默认 60s）："Defines a timeout for reading a response from the proxied server. The timeout is set only **between two successive read operations, not for the transmission of the whole response**. If the proxied server does not transmit anything within this time, the connection is closed."（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）Envoy 的 `RetryPolicy` 把两者做成了两个字段：`per_try_timeout ( Duration )` "Specifies a non-zero upstream timeout per retry attempt (including the initial attempt)." 与 `per_try_idle_timeout ( Duration )` "Specifies an upstream **idle** timeout per retry attempt (including the initial attempt). This parameter is optional and if absent there is no per-try idle timeout."（https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto ）HAProxy 另有 `timeout client-fin`/`timeout server-fin` 两个**半关闭**专用超时，以及 `timeout tunnel`（"Set the maximum inactivity time on the client and server side for tunnels. … This timeout supersedes both the client and server timeouts once the connection becomes a tunnel."），并给出选值经验："It is a good practice to cover one or several TCP packet losses by specifying timeouts that are slightly above **multiples of 3 seconds (e.g. 4 or 5 seconds)**."（https://docs.haproxy.org/2.8/configuration.html ）

**该中继的三档设计方向正确。** 常量在 `workbuddy.uc:358-360`：`UP_FIRST_BYTE_SEC_DEFAULT = 12`、`UP_IDLE_SEC_DEFAULT = 25`、`WB_IDLE_SEC_DEFAULT = 75`（`UP_IDLE_TICK_MS = 5000`）；uci 项 `up_first_byte_sec`/`up_idle_sec`/`wb_idle_sec`（`workbuddy.uc:589-591`、`656-658`，范围 0..3600，0 = 关闭该档）。`watchdogTick`（`workbuddy.uc:6483-6496`）按 `!c.upstream` / `attemptBytes === 0` / 其他 三态选档，并给"首字节档"与"流中档"打了不同文案的日志（6502 / 6505），排查时能一眼分开"上游根本没受理"和"受理了但断流"——这个区分正是 nginx 把 `error` 与 `timeout` 分开的理由。

**仍缺的：总时长上限。** 全文对 `totalSec|maxTotal|deadline|reqDeadline` 匹配 0 命中；也就是说，一个不断吐字节但永远不结束的上游，会一直占着闸门额度。curl 层面有 `--max-time`（`workbuddy.uc:3401`，wb 1800s / 直连 900s）——并按 curl 文档，"Set the maximum time in seconds that you allow each transfer to take. Prevents your batch jobs from hanging for hours due to slow networks or links going down."（https://curl.se/docs/manpage.html ）——但那是**单次 attempt** 的，不构成跨重试的总预算；Envoy 明确提示"when using a 5xx based retry policy, a request that times out will not be retried as the total timeout budget would have been exhausted"，即总预算是跨重试共享的。

**"向客户端发出字节之后还能不能 failover？" —— 不能，而且该中继做对了。** 三条独立依据：
1. nginx 的核心约束："**One should bear in mind that passing a request to the next server is only possible if nothing has been sent to a client yet.**"（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）
2. RFC 9112 §9.3.2："A server MAY process a sequence of pipelined requests in parallel if they all have safe methods …, but it MUST send the corresponding responses in the same order that the requests were received." —— 已经发出的字节无法撤回，重放会破坏顺序与完整性。
3. RFC 9112 对不完整响应的定性："A client that receives an incomplete response message … MUST record the message as incomplete." 一旦把 200 头发出去了，客户端看到的"半个流"就是**不完整响应**，无论后续怎么补。

该中继的实现位于 `watchdogTick`（`workbuddy.uc:6512-6516`）：`if (c.headersSent) { closeConn(c); continue; }` 并附注释"已开始向客户端推流，无法回退重试，只能收尾"；`tryNextCred`（`workbuddy.uc:3560`）与 `tryNextUpKey`（`workbuddy.uc:3782`）同样先查 `conn.headersSent`。**这是正确行为，不要改。**

**超时后的正确响应方式。** 该中继在未推流时返回 502/429（`tryNextCred` 尾部 `type: risk ? 'account_restricted' : 'upstream_error'`）；在已推流时直接 `closeConn` —— 等价于"连接截断"，符合 RFC 9112 让客户端判为 incomplete。另一条可选路径是**在流内发一个 SSE 错误事件**（OpenAI 的说明确实允许 200 流内出现 `error` 字段的 data 帧），但那要求客户端配合解析；直接断开更保守、更符合现有客户端（openai-node 在未见到 `[DONE]` 时会把早退记为 abort 并 `controller.abort()`，见 https://raw.githubusercontent.com/openai/openai-node/master/src/core/streaming.ts ）。

**该中继完全没有入站客户端超时。** `client_timeout|recv_timeout|read_timeout|body_timeout|header_timeout` 全部 0 命中。一个连上后慢慢发 header 的客户端（slowloris 形态）不会触发任何一档看门狗，因为 `lastByteAt` 为 0 时 `watchdogTick` 直接 `continue`。设备对公网开了 18889（`workbuddy.uc:6548` 注释），这一条值得补。

### 3.4 重试预算、幂等性与放大

**幂等性是第一性的。** RFC 9110 §9.2.2："A request method is considered \"idempotent\" if the intended effect on the server of multiple identical requests with that method is the same as the effect for a single such request. Of the request methods defined by this specification, PUT, DELETE, and safe request methods are idempotent." 并给出对中继最要紧的一句："**A client SHOULD NOT automatically retry a request with a non-idempotent method unless it has some means to know that the request semantics are actually idempotent, regardless of the method, or some means to detect that the original request was never applied.**"（https://www.rfc-editor.org/rfc/rfc9110.txt ）`POST /v1/chat/completions` 按该列表**不是**幂等方法，所以"换 Key 重试"需要正当理由或"从未被应用"的证据。

**"从未被应用"的判据在 HTTP/2 里有精确形式。** RFC 9113 §8.7："HTTP/2 provides two mechanisms for providing a guarantee to a client that a request has not been processed: The GOAWAY frame indicates the highest stream number that might have been processed. Requests on streams with higher numbers are therefore guaranteed to be safe to retry. The REFUSED_STREAM error code can be included in a RST_STREAM frame to indicate that the stream is being closed prior to any processing having occurred. Any request that was sent on the reset stream can be safely retried. **Requests that have not been processed have not failed; clients MAY automatically retry them, even those with non-idempotent methods.** A server MUST NOT indicate that a stream has not been processed unless it can guarantee that fact."（https://www.rfc-editor.org/rfc/rfc9113.txt ）—— 换句话说，**"连接建立阶段失败"才是可重试的判据，而不是"收到一个错误码"**。这与该中继的实际情况形成了张力：因为没有 `-D`/`-i`，它无法区分"连接根本没建起来"（安全重试）与"上游已受理并在中途报错"（不安全重试），只能靠 body 子串猜。

nginx 的默认值把保守立场写死了：`proxy_next_upstream` 的默认是 `error timeout`，而 `non_idempotent` 项的解释是"**normally, requests with a non-idempotent method (POST, LOCK, PATCH) are not passed to the next server if a request has been sent to an upstream server** (1.9.13); enabling this option explicitly allows retrying such requests"（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）。**该中继对 POST 的做法相当于默认开启了 `non_idempotent`**（`tryNextCred`/`tryNextUpKey` 会为 POST 换 Key 重发，边界由 `conn.tryLimit = min(length(pool), MAX_TRY)` 给出，`workbuddy.uc:4257`、`4392`；注释 3797 "最多试满 Key 总数（4 次），不会无限连撞"）。这在"多 Key 轮换抗限流"的场景里有商业合理性，但应在报告中明确标注为**有意偏离 RFC 的 SHOULD NOT**，且它成立的前提是"换 Key 重发同一 prompt 不产生用户可见副作用"——对纯推理调用成立，对带工具调用/计费的调用不成立（**unverified**，取决于上游语义）。

**重试放大的三种生产级封顶方式：**

1. **每请求次数预算。** Google SRE Book："First, we implement a *per-request retry budget* of up to three attempts. If a request has already failed three times, we let the [failure surface]"（https://sre.google/sre-book/handling-overload/ ）。同页第三种做法是把尝试次数作为请求元数据传给后端："the counter starts at 0 in the first attempt and is incremented on every retry until it reaches 2, at which point the per-request budget causes it to stop being retried. Backends keep histograms of these values in received requests"。**该中继既不发尝试计数头（`X-Attempt`/`Idempotency-Key` 均 0 命中），也不接收。**
2. **并发重试占活流量的比例。** Envoy 的 `RetryBudget`：`budget_percent` —— "Specifies the limit on concurrent retries as a percentage of the sum of active requests and active pending requests. For example, if there are 100 active requests and the budget_percent is set to 25, there may be 25 active retries. This parameter is optional. **Defaults to 20%.**"；`budget_interval` —— "An optional duration in which requests will be considered when calculating the budget for retries. … By default, when budget_interval is set to 0ms, only presently active and pending requests are considered"（https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/circuit_breaker.proto ）。**这是"按比例"而非"按次数"的封顶，是中继当前完全空缺的维度。**
3. **令牌桶限速重试（且首次尝试永不受限）。** gRPC A6："For each server name, the gRPC client maintains a `token_count` variable which is initially set to `maxTokens` … Every failed RPC will decrement the `token_count` by 1. Every successful RPC will increment the `token_count` by `tokenRatio`. … If `token_count` is less than or equal to the threshold, defined to be `(maxTokens / 2)`, then RPCs will not be retried until `token_count` rises over the threshold."；"**The first outgoing RPC will always be sent**, but subsequent hedged RPCs will only be sent if `token_count` is greater than the threshold."（https://raw.githubusercontent.com/grpc/proposal/master/A6-client-retries.md ）

**值得注意的是：该中继的刹车独立收敛到了与 gRPC 相同的"首次豁免"原则。** `spawnUpstreamDirect` 中刹车只在 `if (conn.upTry > 0)` 时生效（`workbuddy.uc:3606`），代码注释（3603-3607）给出的理由正是 gRPC 那句话的经验版本：首次尝试是唯一能探知上游是否已恢复的手段。同时注释里记录了真实放大数据："96 次上游调用无一成功，占上游总流量的 70%（池统计 138 次 / 60 个客户端请求 = 2.25× 放大）"（`workbuddy.uc:440`）。**这是本审计中"中继自己走对了"的第二个证据点，且它有实测数字支撑。**

**AWS 的量化警告与抖动。** "Consider a system where the customer's call causes a five-deep stack of service calls. It ends with a query to a database, and three retries at each layer. … If each layer retries independently, the load on the database will increase 243x, making it unlikely to ever recover. This is because the retries at each layer multiply -- first three tries, then nine tries, and so on."；"In general, for low-cost control-plane and data-plane operations, our best practice is to retry at a single point in the stack."；"Setting the timeout too low has two risks: Increased traffic on the backend and increased latency because too many requests are retried."；"**Retries are 'selfish.'** In other words, when a client retries, it spends more of the server's time to get a higher chance of success."（https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/ ）同库还给出对**本地退避**的偏好理由："Circuit breakers … introduce modal behavior into systems that can be difficult to test, and can introduce significant addition time to recovery. We have found that we can mitigate this risk by limiting retries locally using a token bucket."

抖动方面，AWS 架构博客给了变体命名与实测排序（**注意：该页的公式是图片，无法文本提取，因此只引定性结论**）："The solution isn't to remove backoff. It's to add jitter."；变体 "**Full Jitter**"、"**Equal Jitter**"（"we always keep some of the backoff and jitter by a smaller amount … The intuition behind this one is that it prevents very short sleeps"）、"**Decorrelated Jitter**"；100 并发客户端下的实测："the number of calls is approximately the same for 'Full' and 'Equal' jitter, and higher for 'Decorrelated'… **The no-jitter exponential backoff approach is the clear loser. It not only takes more work, but also takes more time than the jittered approaches.**"，且抖动能"reduced our call count by more than half"（https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ ）。

**中继的抖动实现受限但可行。** `workbuddy.uc:109` 的注释明确"rand()/getpid() 在这个 ucode 构建里不可用，不要使用"；唯一的熵源是 `readRandom(n)`（`workbuddy.uc:90`，读 `/dev/urandom`；`genApiKey` 在 `workbuddy.uc:112` 展示了既有用法 `seed = '' + time() + '|' + keySeq + '|' + readRandom(32)`）。因此抖动必须写成 `base + (readRandom(2) 取模窗口)` 的形式。当前刹车放行走的是单发定时器 `uloop.timer(left * 1000, () => { F.spawnUpstreamDirect(conn); })`（`workbuddy.uc:3618`）—— **同一时刻被闭闸的多条连接会在同一毫秒整齐放行**，这正是 AWS 那句"If all the failed calls back off to the same time, they cause contention or overload again when they are retried"描述的场景。

**缺时间预算。** nginx 用两个独立指令界定 failover：`proxy_next_upstream_tries number; Default: 0`（"Limits the number of possible tries for passing a request to the next server"）与 `proxy_next_upstream_timeout time; Default: 0`（"Limits the time during which a request can be passed to the next server"）。该中继只有次数（Key 总数），没有时间。

### 3.5 上游 429 / Retry-After 与各家的限流头

**Retry-After 有两种合法语法，只解析整数是缺陷。** RFC 9110 §10.2.3：`Retry-After = HTTP-date / delay-seconds`，且 "A delay-seconds value is a non-negative decimal integer, representing time in seconds."；对 503 的含义是"how long the service is expected to be unavailable"，对 429 是"indicate that it is temporary and after what time the client MAY try again"（https://www.rfc-editor.org/rfc/rfc9110.txt ）。MDN 补充了现实约束："Support for the Retry-After header on both clients and servers is still inconsistent. … It is useful to send it along with a 503 resp[onse]"（https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After ）——即**必须准备一条"头缺失时的兜底退避"**。

**四家上游的头各不相同，且解析路径不同：**

| 供应商 | 头 | 格式 | 出处 |
|---|---|---|---|
| OpenAI | `Retry-After` | 整数秒（样例 `56`），"The minimum number of seconds to wait before retrying a temporary rate-limit error, when present." | https://platform.openai.com/docs/guides/rate-limits |
| OpenAI | `x-ratelimit-limit-requests` `60` / `x-ratelimit-limit-tokens` `150000` / `x-ratelimit-remaining-requests` `59` / `x-ratelimit-remaining-tokens` `149984` / `x-ratelimit-reset-requests` `1s` / `x-ratelimit-reset-tokens` `6m0s` | **时长后缀格式**（`1s`、`6m0s`），与 Retry-After 的整数秒是**两条不同的解析路径** | 同上 |
| Azure OpenAI | `retry-after-ms` | **毫秒**，"Included in 429 responses. The recommended wait time (in milliseconds) before retrying." | https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/quota |
| Anthropic | `retry-after` | 秒；"The number of seconds to wait until you can retry the request. Earlier retries will fail. **Not sent with the spend-cap 429**" | https://docs.claude.com/en/api/rate-limits |
| Anthropic | `anthropic-ratelimit-requests-limit` / `-requests-remaining` / `-requests-reset`，以及 `anthropic-ratelimit-tokens-*` 家族 | 后者语义会漂移："The `anthropic-ratelimit-tokens-*` headers display the values for the most restrictive limit currently in effect." | 同上 |

**最要紧的一条结构性事实（对子串匹配判定的致命打击）：** Anthropic 的 spend-cap 429 与普通限流 429 **error type 字符串完全相同**，唯一区别是**缺少 `retry-after`**："The error type is `rate_limit_error`, the same as for a rate limit, but the response has no retry-after header. **Retrying, including the SDKs' automatic retries, fails until access resumes.**"（https://docs.claude.com/en/api/rate-limits ）该中继的 `isRateLimitReason`（`workbuddy.uc:1493-1507`）是子串匹配（`tpm`/`rpm`/`rate limit`/`too many`/`429`/`限流`），**在原理上无法做出这个区分**，会把不可重试的 spend-cap 429 当成可重试限流，反复冷却换 Key，直到 4 把 Key 全部冷却并给客户端 429。

**Anthropic 还警告"重试本身会触发限流"：** "You might also encounter 429 errors because of acceleration limits on the API if your organization has a sharp increase in usage. To avoid hitting acceleration limits, ramp up your traffic gradually and maintain consistent usage patterns."（同上）这与 3.4 的抖动问题同源。

**中继从不读上游 Retry-After。** `Retry-After` 在文件中共 6 处出现，全部是**本地下发**：`workbuddy.uc:3633`（刹车尾等待后）、`3645`（冷却中的 Key）、`4030`（队列满）、`4119`（排队超时），以及注释 451/459/1634/466。常量 `RATE_BRAKE_MAX_RA_DEFAULT = 15`（466）把回给客户端的值封在 15s，注释 459 的理由是"Retry-After 有上限（默认 15s），不再是几百秒的荒谬值"。**"封顶"这个决定本身是对的（避免把上游几百秒的等待原样转嫁给客户端），但它现在是在"完全不知道上游说了什么"的前提下拍出来的。**

**官方推荐的重试节奏（可作为实现对照）**： OpenAI —— "Follow Retry-After when it's present, reduce your request rate, and then increase it gradually."；"If Retry-After is missing, increase the delay between retries and add a small random delay."（https://platform.openai.com/docs/guides/rate-limits ）Azure —— "Automatically retry requests when you receive a 429 response. Use the retry-after-ms header value if present; otherwise, use exponential backoff with random jitter"，且 SDK 默认"The default is two retries"（https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/quota ）。Azure 还给了**主动**限流的做法："Monitor `x-ratelimit-remaining-requests` and `x-ratelimit-remaining-tokens` … to detect when you're approaching limits and proactively throttle requests before receiving a 429."（同上）——中继若拿到这些头，就能把"事后刹车"升级成"事前限速"。

**该中继的下游 429 语义是合规的**：`jsonResponse(conn, 429, { error: { message: ..., type: 'rate_limit_error' } }, { 'Retry-After': '5' })`（`workbuddy.uc:4030`、`4113-4119`），带 `Retry-After` 且类型字段符合 OpenAI 错误体约定。MDN 对 429 的定义："The HTTP 429 Too Many Requests client error response status code indicates the client has sent too many requests in a given amount of time. … A Retry-After header may be included"（https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/429 ）。

### 3.6 SSE 分帧正确性

**规范要点（决定"能不能改字节流"）：**
- WHATWG："Event streams are always decoded as UTF-8. There is no way to specify another character [encoding]"；行终止符文法 `end-of-line = ( cr lf / cr / lf )`（CRLF、孤立 CR、孤立 LF **都合法**）；`comment = colon *any-char end-of-line`；解析规则"If the line starts with a U+003A COLON character (:) Ignore the line."；多行 data 拼接（`data: This is the second message, it\ndata: has two lines.`）；**关键的一条**："the middle of an event, before the final empty line, the incomplete event is not dispatched."（https://html.spec.whatwg.org/multipage/server-sent-events.html ）最后这条说明：**在事件中途切断流，那个事件会丢失且客户端不会报错** —— 这正是"截断必须被记为 incomplete"在 SSE 层的具体形态。
- MDN：推荐头集合包含 `X-Accel-Buffering: no`；"Each notification is sent as a block of text terminated by a pair of newlines."；"A colon as the first character of a line is in essence a comment, and is ignored."；"The comment line can be used to prevent connections from timing out; a server can send a comment periodically to keep the connection alive."（https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events ）
- nginx 侧确认了该头的机制地位：`proxy_buffering` 默认 `on`，且 nginx 识别 `X-Accel-Buffering` 响应头（自 1.1.6）来开关缓冲（https://nginx.org/en/docs/http/ngx_http_proxy_module.html ）。

**该中继的 `sseHeaders`（`workbuddy.uc:2877-2892`）发的是：** `HTTP/1.1 200 OK` + `Content-Type: text/event-stream` + `Cache-Control: no-cache` + `X-Accel-Buffering: no`（注释 2884-2885 明确理由：nginx 默认 `proxy_buffering on` 会把事件流攒成批）+ `Connection: close` + `Access-Control-Allow-Origin: *` + 空行。**这套头是正确的**（`X-Accel-Buffering` 这一项在 v2.0 才补上，属于正确方向）。

**`Connection: close` 在这里承担真实的分帧职责，不是装饰。** 该响应既没有 `Content-Length` 也没有 `Transfer-Encoding: chunked`（全文 `chunked|Transfer-Encoding` 0 命中），RFC 9112 §7.1："If any transfer coding other than chunked is applied to a response's content, the sender MUST either apply chunked as the final transfer coding or **terminate the message by closing the connection**."；§9.6："'close' connection option is defined as a signal that the sender will close this connection after completion of the response."（https://www.rfc-editor.org/rfc/rfc9112.txt ）**因此任何"为了 keep-alive 而删掉 `Connection: close`"的改动，都必须同时补上 chunked 或 Content-Length，否则帧边界消失。**这是给后续维护者的红线。

**字节级透传优于重分帧 —— 该中继的选择是对的。** 流式路径在 `makeOnChunk` 里直接 `conn.sock.send(chunk)`（`workbuddy.uc:3472`），不解析、不重组 SSE 帧。理由有三：SSE 允许三种行终止符（自建分帧器很容易只认 `\n\n`）；多行 data 需按规范拼接；上游可能插入注释行（Anthropic 明确"Event streams may also include any number of ping events"，https://docs.claude.com/en/api/messages-streaming ）。当前代码唯一会"看"内容的地方是首块错误嗅探（`workbuddy.uc:3465`，条件 `(c === '{' || c === '<') && index(chunk, 'data:') < 0`）与 usage 提取（`workbuddy.uc:3871`/`3961`），两者都不修改字节流。

**缺的东西：**
1. **不发注释行心跳。** 全文对 SSE 注释/心跳模式匹配 0 命中。最长静默档是 `wb_idle_sec = 75`，期间客户端与中间设备看到的是一条完全静默的连接；MDN 推荐的做法正是在这种时候周期性发 `: ping`。
2. **流式路径不识别终止标记。** OpenAI 的 200 响应说明写得很清楚："On normal completion, the final frame is: `data: [DONE]`. The final frame ends with a blank line. `[DONE]` is literal text, not a JSON chunk, and this frame has no `event: done` field. If a failure occurs after streaming has started, a data frame may contain a JSON object with an `error` field instead of a completion chunk. … **An interrupted stream may end without the marker.**"（https://raw.githubusercontent.com/openai/openai-openai/master/openapi.yaml 为同源规范文件；此处引用 https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml ）该中继对 `[DONE]` 只有 3 处引用，且都在**非流式/合并**路径：`extractUsage` 里 `if (payload === '[DONE]') continue;`、`mergeChunks` 里 `if (data === '[DONE]' || data === '') continue;`、以及一处文档注释。**正在转发的那条流从不检查它**，所以"上游正常收尾"与"上游被截断"在账本上无法区分。
3. **多供应商终止符不一致未被处理。** OpenAI 用 `[DONE]`；Anthropic 用 `message_stop`（"A final `message_stop` event."，https://docs.claude.com/en/api/messages-streaming ）。若参考客户端行为，openai-node 的判定是 `if (sse.data === '[DONE]') { receivedCompletionSentinel = true; break; }`，且其文档注释写明流"ignores events after `[DONE]`"，早退时只有在 `!receivedCompletionSentinel` 的情况下才 `controller.abort()`（https://raw.githubusercontent.com/openai/openai-node/master/src/core/streaming.ts ）。**这印证了"没看到 `[DONE]` 就当作中断"是客户端侧的标准解读，中继应当对齐。**

### 3.7 连接复用与 TTFB

**测量效应（来自该仓库自己的 README，属自测数据，非外部权威）。** README `565` 行：TTFB p50 新连接 `1603.077 ms` vs 复用 `1298.631 ms`，Δ≈`304 ms`；`566` 行拆分 `DNS + conn_wait + TLS = 1.91 + 135.3 + 84.8 ≈ 222 ms`；`568` 行第二轮 n=138：`221.444 → 112.249 ms`（省 ≈109 ms），并附注"该拆分需 n≥15 才有意义，小样本读数是噪声"。`531` 行记录 v1.8.2 后客户端 TTFB p90 从 30s+ 降到 `3.69 s`；`654` 行改造前 p50/p90/p99 = `2.25 / 31.82 / 34.03 s`，`828` 行改造后 = `1.14 / 2.57 / 5.18 s`。

**该中继的复用实现细节（`pool/main.go`）：** `ForceAttemptHTTP2: true`（注释"上游支持 h2 时多路复用，一次握手并发多请求"）、`MaxIdleConnsPerHost: idlePerHost`、`IdleConnTimeout: 90s`、`TLSHandshakeTimeout: 8s`、`ResponseHeaderTimeout: 0`（注释：WorkBuddy 是 agent 上游，可能想很久才吐第一字节）、`DisableCompression: true`（"SSE 必须逐字节原样透传"）、`KeepAlive: 30 * time.Second`；`keepaliveLoop`（`pool/main.go:532-552`）以 `tick := s.keepalive / 3` 预热心跳，且只在 `h.idleSeconds() < s.keepalive.Seconds()` 时预热；预热走 `HEAD` 且**必须把响应体读尽**（`pool/main.go:388` 注释"必须把响应体读尽：Go 的 transport 只在 body 读到 EOF 时才把连接归还"）。`keepalive` 默认 30s 的理由记在 `pool/main.go:574`："30s：多数反向代理/网关的服务端空闲回收在 60~75s（nginx keepalive_timeout…）"。

**这个 30s 的选值有直接的外部依据。** nginx 上游模块的 `keepalive_timeout timeout; Default: keepalive_timeout 60s` —— "Sets a timeout during which an idle keepalive connection to an upstream serve[r will stay open]"；`keepalive connections [local]; Default: keepalive 32 local`；`keepalive_requests number; Default: keepalive_requests 1000`（https://nginx.org/en/docs/http/ngx_http_upstream_module.html ）。**"客户端空闲回收短于服务端回收"是正确的做法**（避免使用一条已被对端单方面关闭的连接）；**若哪天上调 `keepalive` 到 ≥60s，就会开始出现"复用了一条已死连接"的失败**——这是需要写进运维文档的红线。

**预热的价值有权威支撑。** AWS Builders' Library 的连接建立案例："a ~20 ms timeout included establishing a new secure connection, which was reused on subsequent requests. Because connection establishment took longer than 20 milliseconds, we saw a small number of requests time out when a new server went into service after deployments."，解决办法就是在进程启动时预先建连（https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/ ）。该中继的预热循环属于同一思路。

**HTTP/1.1 队头阻塞与 HTTP/2 的真实边界。** RFC 9113 §1："HTTP/1.1 added request pipelining, but this only partially addressed request concurrency and still suffers from application-layer head-of-line blocking. Therefore, HTTP/1.0 and HTTP/1.1 clients use multiple connections to a server to make concurrent requests."，随后是关于 h2 的关键限定："it allows interleaving of messages on the same connection … **Note, however, that TCP head-of-line blocking is not addressed by this protocol.**"（https://www.rfc-editor.org/rfc/rfc9113.txt ）因此：**h2 消除了应用层 HOL，但没有消除 TCP 层 HOL** —— 一条丢包的 h2 连接上，所有复用其上的流一起停摆。对中继的运维含义是：`pool/main.go` 的 h2 复用提高的是握手经济性，**不构成"用一条连接跑所有并发"的理由**。另外 RFC 9113 §8.7 提示了空闲长连接的现实风险："Connections that remain idle can become broken, because some middleboxes (for instance network address translators or load balancers) silently discard connection bindings. The PING frame allows a client to safely test whether a co[ntinues to work]"—— Go 的 transport 在 `KeepAlive: 30s` 下会做 TCP keepalive 探测，但**这不是 HTTP/2 PING**，对"中间盒丢弃绑定"的检测能力不同（**unverified**：Go 是否在 h2 连接上发送 PING 需另查）。

**池的一条硬限制（对未来重试设计的约束）：** `pool/main.go:315-320` 用 `body = r.Body` 构造 `http.NewRequestWithContext(ctx, r.Method, outURL.String(), body)`。`r.Body` 是不可重放的 `io.ReadCloser`，所以**池自身在当前实现下无法重试任何请求**，它只能把 curl 的取消（`ctx := r.Context()`）传下去。若未来想让池承担重试，必须先把 body 缓冲成 `[]byte`。这同时解释了 `pool/main.go:338-340` 为什么要显式设 `req.ContentLength = r.ContentLength`（注释："NewRequest 拿到的是 io.ReadCloser，推断不出长度，会退化成 chunked；部分上游对 chunked 请求体不友好"）。

**一个现成的改进点：池已经看得到上游状态码，但没有把它交给 ucode。** `pool/main.go:444` 的日志行包含 `resp.StatusCode` 与 `reused`，`/stats` 也导出 `new_conns` 等计数。**把状态码（以及 `Retry-After` 等响应头）通过一个响应头或 `/stats` 字段回传给 ucode，就能在完全不碰 SSE 字节流的前提下解决 3.5 的核心问题。**

### 3.8 上游 prompt cache 与粘性路由

**缓存键是整个渲染后的前缀，任何前缀位置的改动都会失效。**

- OpenAI："Prompt caching preserves that state for a reusable prefix: the unchanged tokens at the beginning of a prompt. When a later request has the same prefix and finds a matching cache entry, the model can reuse the saved state instead of processing those tokens again."；"**Cache reuse requires the entire rendered prefix to match. If content or a relevant setting changes before a breakpoint, the prefix after that change cannot match the existing cache entry.**"；最小可缓存长度"A prompt prefix must meet the model's minimum cacheable token length before it can be cached. … The minimum cacheable prompt length is 1,024 tokens for GPT-5.6 and later and varies by request settings for earlier models."（https://platform.openai.com/docs/guides/prompt-caching ）
- Anthropic："Prompt caching references the entire prompt: tools, system, and messages (**in that order**), up to and including the block designated with `cache_control`." —— 顺序是 tools → system → messages，**改动越靠前，失效范围越大**。TTL："By default, automatic caching uses a 5-minute TTL. You can specify a 1-hour TTL at 2x the base input token price: `{ \"cache_control\": { \"type\": \"ephemeral\", \"ttl\": \"1h\" } }`"；断点上限："Automatic caching is compatible with explicit cache breakpoints. When used together, the automatic cache breakpoint uses one of the **4 available breakpoint slots**."（https://docs.claude.com/en/docs/build-with-claude/prompt-caching ）

**"路由到哪台机器"直接决定命中率，且跨区域不可复用。** OpenAI 说得最直白："Cached states live on individual machines, where traffic above **15 requests per minute** can lead to overflow routing. A request can reuse a cached prefix only if it reaches a machine holding a matching entry that has not expired. **Routing requests to the right machine is therefore important for cache reuse.**"；以及"**Caches are not shared across organizations and cannot be reused across regional processing boundaries.**"；还有一句对"会话粘性"的冷静提醒："Reusing context within a session can preserve a shared prompt prefix, but **maintaining a session doesn't guarantee a cache hit.**"（https://platform.openai.com/docs/guides/prompt-caching ）

**该中继的粘性路由存在，但键是"身份"不是"会话"。** `usableUpKeys(up, stickyFor)`（`workbuddy.uc:1765`）会把粘住的 Key 提到队首（条件是 `length(clean) > 1`，`workbuddy.uc:1778-1779`）；写入在 `workbuddy.uc:1911-1914`（`upSticky[conn.upstream.id + '|' + conn.stickyFor] = { key, until: time() + cfg.upStickySec }`）；键的来源是 `conn.stickyFor = (cfg.upStickySec > 0) ? conn.reqClient : ''`，而 `conn.reqClient = conn.apiKeyName || conn.ip || ''`（`workbuddy.uc:4223-4226`、`4356-4357`）。默认 `UP_STICKY_SEC_DEFAULT = 900`（15 分钟）。

**这里有两个具体风险：**

1. **同一设备上的多个会话共享一个 API Key 时，粘性把它们绑到同一个上游 Key，但无法保证"同一会话稳定落到持有缓存的那台机器"** —— 而 OpenAI 明确只有"同一组织、同一处理区域"内才可能命中。粘性键下沉到会话粒度（客户端 `user`/`conversation_id` 字段，或 system 消息+首条 user 消息的哈希）能提高命中率；但**必须承认这只能影响"我们这一跳"的 Key 选择，无法控制上游内部的路由**（出处同上："OpenAI handles routing automatically"）。
2. **`adaptBody` 会改写前缀，直接破坏缓存。** `workbuddy.uc:2931-2938`：当 `messages[0].role !== 'system'` 时，它会**注入**一条 `{ role: 'system', content: 'You are a helpful assistant.' }` 到消息数组最前面。按 Anthropic 的"tools → system → messages"顺序说明，**这是对前缀最靠前位置的一次写入**，等于让每一条原本没有 system 消息的请求都拿到一段上游从未缓存过的新前缀。这是本次审计中"中继自身行为降低了上游缓存命中率"的唯一确定证据。（`body.stream = true`（`workbuddy.uc:2928`）是否属于 OpenAI 所说的"a relevant setting"从而影响缓存键，**unverified**。）
3. 另有一条会改变缓存命名空间的路径：`onlyFree` 模型替换会改写 `body.model`（`workbuddy.uc:1244` 附近的注释与 `workbuddy.uc:2943-2945` 的排序说明）。换模型即换缓存池，这类改写应当在日志里有痕迹 —— 当前只体现在 `onlyFree` 的启动日志（`workbuddy.uc:6572`）。

### 3.9 流式观测：该测什么

**业界已经收敛出一套命名的指标体系，直接抄名字和桶界即可。**

- OpenTelemetry GenAI 语义约定（权威来源是 GitHub 上的 markdown，`opentelemetry.io` 那页已标记 "This page has moved and is no longer maintained"）：`gen_ai.client.operation.duration`；**`gen_ai.client.operation.time_to_first_chunk`** —— "Time to receive the first chunk, measured from when the client issues the generation request to when the first chunk is received in the response stream."，附注"This metrics SHOULD be reported for streaming calls and **SHOULD NOT be reported otherwise**."；**`gen_ai.client.operation.time_per_output_chunk`** —— "Time per output chunk, recorded for each chunk received after the first one, measured as the time elapsed from the end of the previous chunk to the end of the current chunk."；服务端侧对应 `gen_ai.server.time_to_first_token` / `gen_ai.server.time_per_output_token`。三个客户端直方图共用桶界 `[0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12, 10.24, 20.48, 40.96, 81.92]`（秒）——约自 10ms 起的 ×2 等比数列，顶桶 81.92s。属性包括 `gen_ai.operation.name`（含 `chat`）、`gen_ai.provider.name`（`openai`/`gcp.gen_ai`/`gcp.vertex_ai`/`aws.bedrock`）、`gen_ai.request.model`、`gen_ai.response.model`、`error.type`（如 `timeout`、`500`、`_OTHER`）；并有一条与中继直接相关的规则："`server.address`: When observed from the client side, and when communicating through an intermediary, `server.address` SHOULD represent the server address behind any intermediaries, for example proxies, if it's available."（https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-metrics.md ）
- vLLM 的生产指标集（推理服务端视角，可作为"上游健康度"的对标）：`vllm:time_to_first_token_seconds`（TTFT）、`vllm:inter_token_latency_seconds`（"Inter-token latency (time between consecutive streamed outputs)"）、`vllm:request_time_per_output_token_seconds`（TPOT）、`vllm:e2e_request_latency_seconds`，另有 `vllm:prefix_cache_queries` / `vllm:prefix_cache_hits`（**这两条正是 3.8 里"缓存命中率该不该观测"的答案：该测**）。TTFT 直方图有亚 10ms 桶（`le="0.001"`、`le="0.005"`）。归因规则："When a preemption occurs during decode … we consider the preemption as affecting the inter-token, decode, and inference intervals. When a preemption occurs during prefill … we consider the preemption as affecting the time-to-first-token and prefill intervals." —— 即**流中卡顿应计入 inter-token，而不是 TTFT**（https://docs.vllm.ai/en/latest/design/metrics.html ）。

**该中继现在的观测口径（`metricsSnapshot`，`workbuddy.uc:6046-6177`）：**
- `ttfbMs: { pool: metricStat(metrics.mode.pool.ttfb), direct: metricStat(metrics.mode.direct.ttfb) }`（6139-6142）与 `totalMs: { pool, direct }`（6143-6146）。**只有这两个直方图**，且**按池/直连分列**——这个分列设计是对的，正是 README 想验证的那件事。
- TTFB 的打点位置在 `makeOnChunk`（`workbuddy.uc:3449-3451`）：首个字节到达时 `histAdd(metricMode(conn).ttfb, conn.firstByteAt - conn.attemptAt)`，即"从发起到收到第一个字节"，包含 DNS/TCP/TLS/上游排队 —— 语义与 OTel 的 `time_to_first_chunk` 一致（虽然名字叫 ttfb）。
- 桶界 `METRIC_BUCKETS`（`workbuddy.uc:1251-1254`）= `[5, 10, 20, 30, 50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000, 30000]`（ms）。选择理由（注释 1248-1250）是 ucode 的 `sort()` 按字符串比较数字（`'1000' < '9'`）会算错分位数，而归桶能把内存钉在常数级 —— **这个工程判断是对的**，问题只在桶界：`1500 / 2000 / 3000` 这三点之间，"300ms 的连接复用收益"在原理上不可分辨。README `571-574` 行对此有自述："**用 `/metrics` 的直方图测不出来** —— 那些桶在 1–3 秒区间只有 500–1000 ms 分辨率，分辨不出 300 ms 的差异"，并记录了外挂 curl A/B（`use_pool=1` vs `0`）"**得不出结论**"（上游生成耗时本身在 1.17–3.32 s 波动）。
- **缺失的四个维度：**（a）没有 inter-token / inter-chunk 延迟；（b）`recordConnMetrics`（1383-1390）没有 abort 桶，取消与截断记为成功；（c）没有按上游 Key 的 TTFB 分解（`metrics.key[...]` 只有 ok/fail/rateLimited/authFail/lastErr，见 6053-6069）；（d）没有 prefix-cache 命中率（需先有 3.5 的头可见性）。

**落地建议（与已有结构对齐，不引入新机制）：** 把 `METRIC_BUCKETS` 换成 OTel 那套等比桶界（ms 制 `[10,20,40,80,160,320,640,1280,2560,5120,10240,20480,40960,81920]`），给 `metrics.mode.*` 增加一个 `chunk` 直方图并在 `makeOnChunk` 里按"与上一块的间隔"打点（OTel 的 `time_per_output_chunk` 就是这个定义），给 `recordConnMetrics` 增加 abort 判定，并把 `gen_ai.provider.name` / `gen_ai.request.model` 这类维度映射到现有的 `upstreams[].id` + model 字段上。

---

## 四、GAPS WE LIKELY STILL HAVE（按可能性排序的诚实猜测）

1. **无背压是真实的、可复现的架构缺口，不是理论风险。** 依据是三项可核验的事实叠加：6 处 `send()` 全部丢弃返回值、`ULOOP_WRITE`/`shutdown` 零使用、收发 fd 全部 `ULOOP_BLOCKING`。ucode 的 `send()` 明确会返回短写字节数（https://raw.githubusercontent.com/ucode-lang/ucode/master/lib/socket.c ），所以"短写不可观测"这一条是确定的；"客户端不读时 `send()` 在单线程里阻塞多久"取决于内核发送缓冲与 `SO_SNDTIMEO`（未设置，故为无限）——**推测是长时间阻塞，未实测**。
2. **`sseBuf` 的两条无上限路径是最可能被触发的内存炸弹。** 流式路径有 2 MiB 上限，非流式路径（`workbuddy.uc:3455`）与错误嗅探路径（`3466`）没有。触发条件是"客户端请求非流式 + 上游返回超大响应"，而这恰好是最容易被一个失控客户端反复触发的组合。
3. **pipeline 重入（`onData` 的 `headerEnd`/`bodyLen` 不复位）大概率会在真实客户端上出现。** HTTP/1.1 客户端复用连接（curl 默认、`requests` 的 Session、Node 的 agent）都会在同一连接上发第二个请求。第一个是 SSE 长流时，第二个请求会在 `headersSent` 已为真的连接上再次进入 `dispatch`，覆盖 `conn.proc`/`conn.sseBuf`/`conn.upKeys`，让首个上游变成孤儿。**这条与任务书排除的四个 bug 不是同一件事**（不是 16384 截断、不是 `[DONE]` 后不关连接、不是 `pclose` 阻塞、不是 EAGAIN/EOF）。建议：立刻用 `curl` 在同一连接上连发两个请求（`curl --next`）验证。
4. **Anthropic spend-cap 429 被误判为可重试限流，几乎是确定会发生的。** 依据是供应商文档明确"error type 相同、只差 `retry-after`"（https://docs.claude.com/en/api/rate-limits ）而中继用子串匹配。触发后表现为"4 把 Key 全被冷却 + 客户端连续收到 429"，且日志里看不到真实原因（状态码不可见）。
5. **重试链的时间无界，是最可能造成尾延迟事故的一项。** 4 次 Key 轮换 × 每档超时（首字节 12s / 流中 25s / wb 75s）叠加，理论上单请求可挂到分钟级；README 记录的 `p90 31.82s → 2.57s` 改进说明这条链确实曾是主因，而时间预算至今仍缺。
6. **入站无任何客户端超时 + 对公网开放（18889，`workbuddy.uc:6548`）。** slowloris 形态的连接不会被看门狗回收（`lastByteAt === 0` 直接 `continue`，`workbuddy.uc:6479`）。这是"能不能被一个廉价客户端拖垮"的问题，而不是"会不会偶发"的问题。
7. **prompt cache 命中率可能长期偏低且无人知晓。** `adaptBody` 注入 system 消息（`workbuddy.uc:2931-2938`）直接改写前缀最靠前的位置；粘性键是 `apiKeyName || ip` 而非会话；且没有任何 prefix-cache 相关指标（vLLM 有 `vllm:prefix_cache_queries`/`_hits` 可对照）。
8. **`/metrics` 的成功率读数目前偏乐观。** 取消/截断记为 `chatOk`，会让"上游静默截断"这类最难查的故障永久隐形。这一条不改代码就永远看不出来。
9. **不确定/需要实测的：** `--speed-limit 1 --speed-time 30|90` 与看门狗的叠加效果（两者都可能在长期静默时先动手，但触发后的日志文案不同，实测可区分）；桥接路径（`nc` 管道）在背压场景下的行为是否比 popen 路径更好或更差（**unverified**，`bridgeWrap` 用 `&` 把整组放后台，管道背压由 `nc` 承担，其内存行为未测）。

---

## 五、不确定性与未验证项

**未能获取的权威来源（明确记为 unverified，报告中未据其断言）：**
- `platform.openai.com/docs/api-reference/chat/create` 与 `.../chat-streaming`：直取返回 **HTTP 403**，即使带 UA。故 OpenAI 流式协议的细节全部改引其 OpenAPI 规范文件（`https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml`），二者同源但与 HTML 文档可能有措辞差异。
- `docs.claude.com/en/docs/build-with-claude/streaming` 取不到，已改用同站可用页 `https://docs.claude.com/en/api/messages-streaming`。
- curl manpage 中 `--connect-timeout` 的定义体未被成功抽取，故未引用其语义（`--max-time`、`--speed-limit`、`--speed-time`、`-D`、`-i`、`-N` 均已逐字取得）。
- HAProxy 的 `tune.bufsize` 定义体未抽取（只拿到目录项），故只引用同族的 `tune.buffers.limit`。
- AWS "Exponential Backoff And Jitter" 一文的公式以图片呈现，**Full/Equal/Decorrelated Jitter 的具体算式未取得**，报告只引用了其定性结论与实测排序。
- Node.js backpressure 文档中 `highWaterMark` 的具体默认数值未逐字取得（该页通过 `.pipe()` 叙述机制），故未给数值。
- Envoy 的 `retry_budget` 未出现在 route-level `RetryPolicy` 页，最终在 cluster 级 `circuit_breaker.proto` 页取到（`budget_percent` 默认 20%），两处均未提 `min_retry_concurrency` 的语义细节。

**事实性的不确定项：**
- `body.stream = true` 的强制改写（`workbuddy.uc:2928`）是否影响 OpenAI 的 prompt cache 键（文档只说"content or a relevant setting"）—— **unverified**。
- Go 的 `net/http` transport 在 HTTP/2 连接上是否发送 PING 帧（关系到"中间盒静默丢弃绑定"的检测能力）—— **unverified**，未查 `go/src/net/http/transport.go` 的 h2 分支。
- ucode 各版本间的 stdlib 差异：本报告引用的 `lib/socket.c`/`lib/uloop.c` 取自 master 分支，目标设备上的 ucode 构建版本未确认，**`send()` 返回短写长度这一行为建议在设备上实测一次**（`sock.send(超长串)` 看返回值）后再生效修复。
- 未实测项：`send()` 在客户端不读时阻塞多长时间；`sseBuf` 无上限路径被触发所需的响应体大小；pipeline 重入的实际触发条件与后果（可用 `curl --next` 快速验证）。
- 仓库在本次审计期间被并发修改（v1.8.4 → v2.0.1），本文所有行号对应 `sha256=249104EC287875577BFAF57C19B9C39563873DBB75247F10DC96FD7D6EC19D8B`；**引用前请重新 grep，不要直接复用行号。**
- README 中的性能数字（TTFB 对比、p50/p90/p99）是**该仓库自测数据**，非外部权威来源，本文只作为"自身基线与已知痛点"引用，不作为工程结论的证据。
