# tools/ —— 咪咕直播插件的运维、验证与探测脚本

本目录是 `luci-app-migu-iptv` 开发/运维过程中实际用过的脚本存档，对应 `ucode/migu.uc`
从 1.2.0 到 1.5.0 的每一次改造。它们不是插件运行时的一部分，**不会被安装到路由器**，
仅用于复现、回归和故障排查。

> ⚠️ **脚本里的所有真实凭据均已脱敏**，运行前需要自己注入（见下文「凭据注入」）。
> 仓库是公开的，请勿把真实口令提交回来。

## 目录结构

| 目录 | 数量 | 用途 |
|------|------|------|
| `deploy/`   | 14 | 把 `migu.uc` / LuCI 侧文件部署到路由器（带回滚与语法检查） |
| `verify/`   | 25 | 部署后的功能验收、性能复测、端到端取流、浏览器实测 |
| `probe/`    | 19 | 探测 ucode / busybox / socket 的真实语义（很多「结论」出自这里） |
| `audit/`    | 14 | 静态审计：临时文件残留、依赖、ACL、form 类名、EPG 映射率、改造前基线 |
| `loadtest/` |  6 | 并发上限（maxConns 503 分支）与拒绝路径 RST 丢包的量化实验 |

## 运行位置（很重要）

| 类型 | 运行位置 | 方式 |
|------|----------|------|
| `.sh` | **路由器**（busybox ash） | `pscp` 上传到 `/tmp` → `plink ... "tr -d '\r' < /tmp/x.sh > /tmp/x2.sh && sh /tmp/x2.sh"` |
| `.uc` | **路由器**（`ucode`） | 同上，`ucode /tmp/x.uc` |
| `.ps1` `.mjs` `.js` | **Windows** | `powershell -File` / `node` |

`.sh` 脚本大量使用 `/usr/share/ucode/migu.uc`、`/etc/config/migu`、`ubus call migu …`
等路由器上的绝对路径，直接在 Windows 上跑没有意义。

> 为什么必须 `tr -d '\r'`：Windows 侧写出的文件带 CRLF，busybox ash 会把 `\r` 当成命令的一部分。

## 凭据注入

| 脚本类型 | 占位形式 | 运行前设置 |
|----------|----------|-----------|
| `.ps1` | `'<js>'.Replace('__ROUTER_PASS__', $env:ROUTER_PASS)` | `$env:ROUTER_PASS = '<路由器口令>'` |
| `.mjs` | `(process.env.ROUTER_PASS \|\| '')` | `ROUTER_PASS=<口令> node xxx.mjs` |
| `.sh`  | `${PUBLIC_TOKEN}` / `${WAN_IP}` | `export PUBLIC_TOKEN=... WAN_IP=...` |

其它不再出现的硬编码项：路由器地址 `192.168.69.1`、SSH 主机公钥（公开信息，保留）、
migu 账号（`userId` / `token`）——后者在存档脚本里本来就没有出现。

### 脱敏是怎么做的、怎么验证的

`_mt/_collect-tools.mjs`（不在本仓库内）按显式白名单把 `D:\AI\_mt` 下的 78 个脚本
复制到本目录，并按上面的规则替换字面量。验证分两层：

1. **残留扫描带正向对照**：先往目录里植入一个含全部 5 项机密的临时文件，确认扫描器
   报出 5 条 `LEAK`，删除后再确认归零（`node _collect-tools.mjs --selftest`）。
   报 0 的检查器必须先证明它抓得到才有意义。
2. **脱敏后的语法校验**：
   - `tools/**/*.ps1` → PowerShell 官方解析器 `Parser::ParseFile`，**11/11 通过**；
   - `tools/**/*.mjs` → `node --check`，**6/6 通过**；
   - `tools/**/*.sh`  → 路由器上 `sh -n`（去 CR 后），**51/51 通过**，
     并用 4 个真语法错误样本（缺 `fi`／未闭合引号／缺 `done`／人为截断）确认检查器有效、
     1 个合法样本确认不误报。

## 各组脚本一览

### deploy/ —— 部署

| 脚本 | 说明 |
|------|------|
| `deploy-130.sh` | migu.uc 1.3.0 部署（带回滚） |
| `deploy-131.sh` / `deploy-131b.sh` / `deploy-131c.sh` | 1.3.1：修 EPG 抓取 + chFallback 计数 → `EPG_MIN_PREFIX` 修复 → 终版 |
| `deploy-140.sh` / `deploy-140f.sh` / `deploy-141.sh` | 1.4.0：EPG 改「后台任务 + 轮询」不阻塞事件循环；终版部署与长时观察 |
| `deploy-141rst.sh` | 1.4.1：拒绝路径 RST 修正 + 回归校验 |
| `deploy-150.sh` | 1.5.0 部署（外部源两段式检查、streamTtl、extUserAgent、EPG ETag） |
| `deploy-final.sh` | 1.3.1 终版部署（EPG 基准带重试，避免偶发 TLS 失败污染结论） |
| `deploy-luci.sh` / `deploy-menu.sh` | 部署 LuCI 侧（设置页/状态页/rpcd/ACL）与 `menu.d`（补 config 路由） |
| `deploy-migu.ps1` / `deploy-migu-public.ps1` | 早期 Windows 侧整体部署（走 `_upload-lib.ps1` 加固上传） |

### verify/ —— 验收

| 脚本 | 说明 |
|------|------|
| `verify-130.sh` / `verify-150.sh` | 1.3.0 前后对比基准；1.5.0 功能验收（外部源两段式、取流、统计字段） |
| `verify-304.sh` / `etag-test.sh` / `etag-test2.sh` | EPG ETag 条件更新：重启后应立即命中 If-None-Match 304 |
| `verify-epg-131.sh` / `verify-epg-c.sh` / `verify-map.sh` | EPG 修复效果、`tvg-id="C"` 误匹配、tvg-id 与标准表的交集口径 |
| `final-141.sh` / `check-141.sh` | 1.4.1 终验与上线后复检 |
| `e2e-deep.sh` / `e2e-final.sh` | 端到端：master → variant → TS 分片（校验 0x47 同步字节） |
| `test-epg-disable.sh` | 验证「把 epgUrl 设为空串」是否真能关闭 EPG（结论：不能，靠 epgRefreshHours=0） |
| `pub-test.sh` | 公网（WAN）令牌鉴权：无令牌/错令牌/对令牌 |
| `repo-compare.sh` | 汇总路由器上 migu 插件全部文件 md5，与本地仓库比对 |
| `pre-deploy-check.sh` | 部署前检查（含流地址有效期长测日志） |
| `verify-migu-*.ps1`（7 个） | 浏览器（CDP）实测设置页/状态页：点击「随机生成令牌」、通知、公网访问区块等 |
| `_upload-lib.ps1` / `_recv-lib.ps1` | 加固版上传/下载：分块 → 校验长度与 md5 → 失败重试 |

### probe/ —— 语义探测（很多「经验」的出处）

| 脚本 | 说明 |
|------|------|
| `probe-150.uc` / `probe-150b.uc` | 1.5.0 用到的 ucode 特性：`'\x47'` 转义、`delete`、空串 truthiness、数值字符串比较 |
| `probe-sock.uc` / `probe-sock2.uc` | socket 能力：`recv(MSG_DONTWAIT)` 返回语义、`shutdown(SHUT_WR)` 是否产生干净 FIN |
| `probe-timer.uc` / `probe-timercrash.uc` | `uloop.timer` 句柄方法与 `.cancel()`；回调抛异常是否会终止进程 |
| `splittest.uc` / `eagain.uc` | `split`/`trim` 参数序；`proc.read()` 遇 EAGAIN 的返回 |
| `diag-epg*.sh`（6 个） | 锁定「EPG id 只有一个」的根因：busybox 正则工具读**网络管道**会丢数据 |
| `diag-nc-eof.sh` | busybox `nc` 在 stdin EOF 时的套接字语义 |
| `diag-popen.uc` | curl 在 ucode `popen` 环境里是否行为异常 |
| `diag-shortid.sh` | 决定前缀匹配长度阈值（最终取 `EPG_MIN_PREFIX = 4`） |
| `probe-args.sh` | 用临时 rpcd 插件验证 ubus 参数类型是否严格 |
| `test-fetch.sh` | 对比几种抓取策略的可靠性（含 gzip） |

### audit/ —— 静态审计与基线

| 脚本 | 说明 |
|------|------|
| `check-luci-classes.js` | 扫 LuCI 视图里的 `form.*` 类名是否真实存在（**带正向对照**，否则等于没查） |
| `check-form.sh` / `check-password*.sh` | 路由器上导出的 `form.js` 类清单、password 处理 |
| `check-args.sh` / `check-acl.sh` / `probe/` 配合 | ubus 参数类型、`testchannel` 的 ACL 覆盖 |
| `check-deps.sh` | 临时文件/模块残留（openssl、`sh('date`）与源码一致性 |
| `check-uci-after-save.sh` | 页面保存后 uci 实际落地值核对 |
| `check-map.sh` / `analyze-m3u.sh` / `analyze-unmapped.sh` / `analyze-epg-mapping.mjs` | EPG 映射率量化（结论：77/178 直接命中，规范化后**额外命中 0**，不改算法） |
| `migu-baseline.sh` / `migu-baseline2.sh` | 改造前基线：`openssl dgst` ≈13ms/次、缓存命中比冷解析快约 280 倍、并发请求排队 |

### loadtest/ —— 并发与竞态

| 脚本 | 说明 |
|------|------|
| `test-maxconns.mjs` / `test-maxconns-curl.mjs` | 用「半开 TCP 连接」占满 `maxConns`，验证第 N+1 条请求返回 503 |
| `test-maxconns-rst.mjs` / `test-maxconns-rst2.mjs` | 判定拒绝路径上客户端读到 `ECONNRESET` 的成因，并量化丢包率（发请求变体 25/60 完整，不发字节变体 60/60 完整） |
| `test-rst-141.mjs` | 1.4.1 修复后的丢包率复测 |
| `test-maxconns.sh` | 路由器侧简化版（busybox `nc` 挂不住连接，故只用 .mjs 版结论） |

## 踩过的坑（脚本里都留了痕）

- **PowerShell 不能把多行命令内联给 `plink.exe`**：参数解析会破坏它，远端报
  `ash: line 1: syntax error: unexpected "("`。一律「本地写文件 → `pscp` 上传 → `sh`」。
- **`pscp` 不做换行转换**，上行的 CRLF 必须在路由器上 `tr -d '\r'` 掉。
- **脚本批量调用 .NET 写文件在这个环境里会静默失败**（目录建了、文件没落地、不报错），
  所以本目录的收集脚本用 node 写；单次 `[IO.File]::WriteAllLines` 和 `Set-Content` 正常。
- 路由器**没有 `od` / `comm`**：用 `hexdump -C`；`ucode` 没有 `undefined` 全局，
  **只支持 `try/catch`，没有 `finally`**（写了会整份文件编译不过）。
- ucode **不做函数提升**：被引用的函数必须定义在调用点之前。
- 报 0 的检查器必须先做正向对照（本目录的脱敏扫描与 `check-luci-classes.js` 都按这个规矩写）。

## 已知可改进项（未做）

- `deploy-141.sh` 是 1.4.0 时代的陈旧脚本，1.4.1 请用 `deploy-141rst.sh`。
- 这些脚本里的窗口等待（`sleep`）是按当时实测调的，路由器负载不同时可能需要放宽。
