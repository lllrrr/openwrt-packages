# luci-app-migu-iptv — 咪咕直播源转发（LuCI 插件）

把**咪咕视频**的直播频道转成 TV-BOX 能直接订阅的标准 **M3U 播放列表**，并在播放时按需换取咪咕流地址、302 重定向到最终 HLS 流。

- 路由器原生运行，**无需 Node.js / Docker / Python**，只用 ucode + curl。
- **纯 LuCI 应用**：全部配置在路由器「服务 → 咪咕直播」里完成，没有独立管理网页。
- 游客模式最高 540p；填咪咕账号到 720p；VIP 到蓝光 1080p / 原画 / 4K。
- **内置 EPG 映射**：自动把频道名转成播放器认识的 `tvg-id`，电视盒节目单直接可用。
- **零外部进程签名**：取流签名走 ucode 原生 MD5，不再 fork `openssl`。

> 参考实现：[akiralereal/iptv](https://github.com/akiralereal/iptv)（Node.js 版）。
> 本项目用 ucode 重写其核心算法：频道列表接口 + playurl 签名 + ddCalcu 解密 + 302 跟随。

---

## 一、LuCI 界面（配置入口）

安装后在路由器 LuCI 里出现 **服务 → 咪咕直播**，两个子页：

| 页面 | 路径 | 作用 |
| --- | --- | --- |
| **设置** | 服务 → 咪咕直播 → 设置 | 服务开关、监听端口/地址、画质档位、H.265/HDR、缓存、取流/失败缓存 TTL、并发上限、EPG 来源与刷新、调试日志、咪咕账号（userId + token，密码框输入）、外部源探测 User-Agent |
| **运行状态** | 服务 → 咪咕直播 → 运行状态 | 运行状态徽章、服务控制（启动/停止/重启）、TV-BOX 订阅地址（可点选复制）、频道测试、频道分组统计、服务日志 |

**「保存 & 应用」会写 UCI 并自动重启服务**，无需手动去「系统 → 启动项」重启。

配置改动落在 `/etc/config/migu`，同一份配置只有 LuCI 一个维护入口。

---

## 二、服务端点（流媒体后端）

| 路径 | 说明 |
| --- | --- |
| `GET /m3u` | M3U 播放列表（分组、台标、频道名、EPG `tvg-id`），TV-BOX 订阅用 |
| `GET /txt` | TXT 播放列表（`频道名,地址` 一行一条） |
| `GET /ch/<pID>` | 按需取流：换咪咕流地址 → 302 重定向到最终 HLS |
| `GET /health` | 服务状态 JSON（版本、频道数、缓存命中、解析耗时、EPG 状态、并发数） |
| `GET /` | 302 跳转到 LuCI 的咪咕直播页 |

对外提供两种订阅写法（公网访问时令牌二选一）：

- 路径前缀（推荐）：`http://地址:端口/<令牌>/m3u`
- 查询参数：`http://地址:端口/m3u?token=<令牌>`

TV-BOX 里订阅地址就是 `http://路由器IP:8788/m3u`。

> 早期版本自带的管理网页 `/admin` 已移除（`/admin` 会 302 回 LuCI）。配置管理统一在 LuCI，避免同一份配置两处维护。

---

## 三、安装

### 方式 A：OpenWrt SDK 打包（推荐）

把本目录放到 SDK 的 `package/` 下编译：

```sh
cp -r luci-app-migu-iptv package/
make package/luci-app-migu-iptv/compile V=s
# 产物：bin/packages/.../luci-app-migu-iptv_1.5.0-1_all.ipk
```

路由器上安装：

```sh
apk add --allow-untrusted luci-app-migu-iptv_1.5.0-1_all.ipk
# 老版本 OpenWrt 用：opkg install luci-app-migu-iptv_1.5.0-1_all.ipk
```

### 方式 B：手动部署

需要把 4 类文件放到位（缺一 LuCI 菜单就不出现）：

```sh
# 1) 流媒体后端 + 服务脚本 + 配置
cp files/usr/share/ucode/migu.uc      /usr/share/ucode/migu.uc
cp files/etc/init.d/migu              /etc/init.d/migu && chmod +x /etc/init.d/migu
cp files/etc/config/migu              /etc/config/migu

# 2) LuCI 菜单与权限（这两步决定菜单能否出现）
cp files/usr/share/luci/menu.d/luci-app-migu-iptv.json  /usr/share/luci/menu.d/
cp files/usr/share/rpcd/acl.d/luci-app-migu-iptv.json   /usr/share/rpcd/acl.d/

# 3) LuCI 页面
mkdir -p /www/luci-static/resources/view/migu
cp files/www/luci-static/resources/view/migu/*.js /www/luci-static/resources/view/migu/

# 4) rpcd 后端接口（LuCI 的状态/控制/测速靠它）
cp files/usr/share/rpcd/ucode/migu    /usr/share/rpcd/ucode/migu

# 5) 生效
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/migu enable
/etc/init.d/migu start
```

依赖（缺一不可）：`ucode`、`ucode-mod-fs`、`ucode-mod-uloop`、`ucode-mod-socket`、`ucode-mod-uci`、`ucode-mod-digest`、`curl`、`rpcd`、`luci-base`。

```sh
apk add ucode ucode-mod-fs ucode-mod-uloop ucode-mod-socket ucode-mod-uci ucode-mod-digest curl rpcd luci-base
```

> `ucode-mod-digest` 是 1.3.0 起新增的依赖（取流签名改用原生 MD5，不再 fork `openssl`）。
> 1.2.x 及更早版本用的是 `openssl-util`；升级后它不再是必需项，如无其它程序使用可以卸载。

---

## 四、配置（`/etc/config/migu`）

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 服务开关 |
| `port` | `8788` | 监听端口 |
| `host` | `0.0.0.0` | 监听地址（`0.0.0.0` 允许局域网访问） |
| `userId` | 空 | 咪咕账号 ID（空 = 游客，最高 540p） |
| `token` | 空 | 咪咕登录令牌（等同登录态，勿外传） |
| `rateType` | `3` | 2=标清540p / 3=高清720p / 4=蓝光1080p(VIP) / 7=原画(VIP) / 9=4K(VIP) |
| `enableH265` | `1` | H.265（部分设备只有声无画时关） |
| `enableHDR` | `1` | HDR |
| `cacheMinutes` | `360` | 频道列表缓存分钟数 |
| `externalSources` | 空 | 降级备用源，每行 `标签\|URL` |
| `publicAccess` | `0` | 允许公网访问 |
| `publicToken` | 空 | 公网访问令牌（建议生成 32 位） |
| `publicBaseUrl` | 空 | 对外访问地址（留空 = 按请求 Host 推断） |
| `debug` | `0` | 调试日志 |

### 1.4.0 新增选项

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `streamTtl` | `1800` | 取流地址缓存秒数（`0` = 不缓存，上限 10800 = 3 小时）。实测咪咕签发的地址有效期约 3 小时，缓久一点能显著减少切台耗时 |
| `failTtl` | `15` | **失败**结果的缓存秒数（`0` = 不缓存，上限 300）。版权盾时段失败是间歇性的，缓太久会把临时失败放大成一直失败；完全不缓存又会让连点重试每次都等一轮完整解析 |
| `maxConns` | `64` | 最大并发连接数（4~4096）。超出直接拒绝，防止单客户端刷请求占满单线程事件循环 |
| `epgUrl` | `https://live.fanmingming.cn/e.xml` | EPG 来源，用于把频道名映射成标准 `tvg-id`。**留空不能关闭 EPG**：UCI 存不下空字符串，清空后会回落到内置默认源 |
| `epgRefreshHours` | `12` | EPG 刷新间隔（0~168 小时）。**设为 `0` 才是关闭 EPG**（此时 `tvg-id` 退回频道名、节目单为空）。拉取失败会自动改为 5 分钟后重试 |
| `warmRecent` | `4` | 启动时预热「最近看过」的频道数（0~12）。开机后首次点开可秒开 |

### 1.5.0 新增选项

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `extUserAgent` | 空 | 外部源健康检查与分片探测时发送的 User-Agent（空 = curl 默认）。部分防盗链源只认播放器 UA（如 `VLC/3.0.18 LibVLC/3.0.18`），对 curl 默认 UA 返回 403/451 会被误判为失效 |

超出账号权益时会自动降级到咪咕愿意给的档位（例如游客要 4K 会一路降到 540p）。

---

## 四·一、性能与运行数据（实机实测）

在京东云 RE-SS-01（IPQ60xx / 4 核 / 968MB RAM，ImmortalWrt SNAPSHOT）上实测：

| 项目 | 改造前 | 1.4.0 |
| --- | --- | --- |
| 冷取流 `/ch/<pid>` | 0.48 ~ 0.78s | 0.59s |
| 热取流（缓存命中） | 0.0018s | 0.0021s |
| 失败结果重试 | 每次重解析 1.28s | 0.0021s（`failTtl` 内） |
| 取流签名开销 | 6 个进程 / 约 30~40ms | 0 进程（原生 MD5） |
| 进程常驻内存 | 2920 kB | 3016 kB |
| 频道数 / 分组 | 174 / 11 | 174 / 11 |
| EPG `tvg-id` 映射 | 无（`x-tvg-url=""` 写死为空） | 77 / 178 命中 |
| 播放中拉取 EPG 是否卡顿 | — | 不阻塞，`/m3u` 与 `/ch` 均 ~0.01s |
| 100 次请求后内存增长 | — | +80 kB（无泄漏，fd 恒为 10） |

### 端到端播放链路实测（1.4.0）

不只看「返回 302」，而是把整条链跟到底，确认真的出数据：

| 环节 | 结果 |
| --- | --- |
| `/ch/608807420` | 302 → `mgsp-hs2.live.miguvideo.com:8088/wd_r2/cctv/cctv1hd/2500/index.m3u8`，带 `client_ip=` |
| master 列表 | 200 / 702 B，指向 `01.m3u8`（码率 2084544） |
| variant 列表 | 200 / 2771 B，4 个 `#EXTINF` 分片，`TARGETDURATION:6` |
| TS 分片 | **200 / 2846132 B / 39 MB/s**，首字节 `0x47`（MPEG-TS 同步字节）✔ |
| 三个频道冷/热 | 0.002s / 0.967s / 0.549s → 热均为 ~0.002s |
| 外部备用源 pid 9002 | 302，0.09s |
| 公网侧鉴权 | WAN 无令牌 403、错令牌 403、正确令牌 200 ✔ |

> 未映射的 101 条不是缺陷：其中 4 条是外部备用源（本就无节目单），其余是 EPG 源里
> 确实没有的地方台（南京/江苏/陕西/海南各频道）、熊猫频道与咪咕自制轮播台。
> 央视全部与主流卫视均已正确映射。

`/health` 会返回完整运行指标，便于排查：

```json
{ "version": "1.5.0", "channels": 174, "chRequests": 2, "chCacheHits": 1,
  "chHitRatePct": 50, "avgResolveMs": 590, "chFallback": 1,
  "activeConns": 1, "maxConns": 64, "streamTtl": 1800, "failTtl": 15,
  "epgIds": 124, "epgOk": true, "denied": 0, "rejectedByLimit": 0 }
```

### 1.4.1 修正：并发超限时的 503 会被 RST 吃掉

`maxConns` 超限时服务端回 503 + `Retry-After: 2`。但旧写法发完 503 就**立刻**
`close()`，而服务端从头到尾没读过这个连接的请求字节 —— Linux 在 `close()` 时
若接收队列还有未读数据，会发 **RST 而不是 FIN**，RST 会让对端丢弃已到达的接收
缓冲，于是刚写出去的 503 一起没了。客户端只看到 `ECONNRESET` 和 0 字节，日志里
`rejectedByLimit` 却正常增长（服务端确实发了，只是没送达）。

判别实验（每变体 3 轮 × 20 次 = 60 次，期望 218 字节）：

| 变体 | 修复前 | 修复后 |
| --- | --- | --- |
| 连上后立即发请求（接收队列非空） | **25/60 完整，丢包 35（58.3%）** | **60/60 完整，丢包 0** |
| 连上后一个字节都不发（队列为空） | 60/60 完整，丢包 0 | 60/60 完整，丢包 0 |

两者唯一差异就是接收队列是否为空，成因由此确定。修法是三步（缺一不可）：

1. 发包前用 `recv(8192, MSG_DONTWAIT)` 把已排队的请求字节读干净（读空返回
   `null` + EAGAIN，不阻塞事件循环）；
2. 发完 503 先 `shutdown(SHUT_WR)` 再 `close()` —— shutdown 会老实发 FIN
   （实测客户端读到 `len=0` 的干净 EOF）；
3. shutdown 之后再补读一轮，覆盖「首次 recv 到 close 之间对端又补发字节」的窗口。

读循环一律限次（16 轮），避免单线程事件循环被持续灌数据卡住。修复后复测
`rejectedByLimit` 恰好等于 120（60+60 次探测全部真正走到拒绝分支），确认测的是
目标路径而非被绕过。

### 1.5.0 深度优化（参考 8 个开源 IPTV 项目后的改造）

| 改动 | 说明 | 参考项目 |
| --- | --- | --- |
| `streamTtl` 默认 300 → 1800 | 咪咕签发的流地址实测有效期约 3 小时，缓存 30 分钟显著减少切台耗时 | akiralereal/iptv |
| 外部源健康检查升级**两段式** | ① 拉 m3u8 头校验 `#EXTM3U`；② 解析首个分片，Range 请求前 32 字节校验 `0x47`（TS 同步字节）或 fMP4 box 头。只校验播放列表会把「返回 200 但分片全挂」的假阳性源判成可用 | awesome-iptv / IPTV Stream Checker |
| **慢源临时禁用** | 外部源连续失败 3 次后临时禁用 10 分钟，期满自动重新探测。避免每次降级都被同一个慢源拖累 | lizongying/my-tv |
| `extUserAgent` 可配置 | 防盗链源只认播放器 UA（如 `VLC/3.0.18 LibVLC/3.0.18`），对 curl 默认 UA 返回 403/451 会被误判失效 | awesome-iptv |
| EPG **条件更新** | 拉取带 `If-None-Match`（ETag，实测该源无 Last-Modified），源未变（304）时跳过 7.9MB 的下载与解析，沿用已有 id 表并正常续期 | awesome-iptv |

---

## 五、获取咪咕 token

`userId` + `token` 是咪咕的登录态。两种取法：

1. **浏览器**：登录咪咕后，按 F12 打开开发者工具 → Network 面板 → 找发往
   `play.miguvideo.com` 的请求 → 看请求头里的 `UserId` 和 `UserToken`。
2. **咪咕 App**：登录后用抓包工具（如 HttpCanary / Stream）抓
   `play.miguvideo.com` 请求的 `UserId` / `UserToken` 头。

把这两个值填进 LuCI「设置 → 咪咕账号」保存即可。**token 等同账号密码，只在自家路由器保存。**

> 两项要**同时填或同时留空**：只填一个会在服务端被拒（返回明确错误）。

---

## 六、TV-BOX 使用

1. 打开 IPTV 播放器（TiviMate / IPTV Pro / Kodi 等）。
2. 添加远程播放列表，地址填 `http://路由器IP:8788/m3u`（LuCI 状态页可直接点选复制）。
3. 频道按「央视 / 卫视 / 地方 / 体育 / 影视 / 综艺 / 新闻 / 纪实 / 少儿 / 教育 / 熊猫」分组显示（**央视排最前，CCTV1 开头**，符合正常电视台排序习惯），点开即播。

> 说明：频道在**播放时**才实时取流，流地址短期有效、自动续期；播放器切台 / 重连时会重新走 `/ch/<pID>` 取新地址。

---

## 七、CCTV5 与体育频道说明

咪咕对 **CCTV5（含 CCTV5+）在播出版权体育赛事时段会做版权屏蔽**（接口返回
`COPYRIGHT_SHIELD_INVALID`，提示「节目播出调整」）。这是咪咕服务端的时段性限制：

- **游客模式**：CCTV5 播版权赛事时**完全取不到流**，非赛事时段可看标清 540p；
  CCTV5+、CCTV1 等其它频道不受影响。
- **已登录账号**：实测配好账号（VIP 档位）后 CCTV5 可正常取流，返回
  `mgsp-*.live.miguvideo.com/.../cctv5hdnew/...` 的 302；后续是否需要体育会员取决于咪咕当时的版权策略。

本项目如实转发「你已有权限的流」，不绕过版权校验。取流失败时，LuCI 的
「运行状态 → 频道测试」会给出 `该频道受版权限制，需登录咪咕体育会员后观看`
的明确提示，而非含糊报错。

---

## 八、核心算法（逆向自参考项目）

1. **频道列表**：`program-sc.miguvideo.com/live/v2/tv-data/{vomsID}`，分组 → 频道（pID、台标）。
2. **取流签名**：
   - `ts = 当前毫秒时间戳`，`appVersion = "26000370"`；
   - `md5 = MD5(ts + pID + appVersion)`；
   - `sign = MD5(md5 + "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123")`，`salt = 1230024`；
   - 请求头带 `AppVersion / TerminalId:android / X-UP-CLIENT-CHANNEL-ID / appCode`，账号档位额外带 `UserId / UserToken`。
3. **ddCalcu 解密**：对返回 URL 的 `puData` 做首尾交错重排，并按位置注入
   `keys="cdabyzwxkl"` 与 `words=['v','a','0','a']` 的字符（CCTV5/5+ 走特殊分支）。
4. **302 跟随**：解密后的地址经 1~2 次 302 得到最终 HLS（`*.miguvideo.com`）。

---

## 九、文件结构

```
luci-app-migu-iptv/
├── Makefile
├── README.md
├── LICENSE
├── tools/                                     # 运维/验证/探测脚本存档（不参与安装）
│   ├── README.md
│   ├── deploy/  verify/  probe/  audit/  loadtest/
└── files/
    ├── etc/
    │   ├── config/migu                        # UCI 配置模板
    │   └── init.d/migu                        # procd 服务脚本
    ├── usr/share/
    │   ├── ucode/migu.uc                      # 流媒体后端（/m3u /txt /ch/ /health）
    │   ├── rpcd/ucode/migu                    # rpcd 插件：LuCI 的状态/控制/测试接口
    │   ├── rpcd/acl.d/luci-app-migu-iptv.json # LuCI 权限（uci + ubus migu）
    │   └── luci/menu.d/luci-app-migu-iptv.json# LuCI 菜单（服务 → 咪咕直播）
    └── www/luci-static/resources/view/migu/
        ├── config.js                          # 设置页
        └── status.js                          # 运行状态页
```

---

## 十、安全提示

- `token` 是咪咕登录态，等同账号密码，**不要**发到公网、不要提交到公开仓库。
- 服务端口（默认 8788）默认监听 `0.0.0.0`，同网段内任何人都能取流；如需限制改
  「设置 → 监听地址」或配合防火墙。
- 蓝光 / 原画 / 4K 以及体育会员频道需要**付费 VIP**，本项目只负责「转发你已有权限的流」，不绕过、不破解咪咕的会员校验。
- `tools/` 下的运维脚本已做脱敏（路由器口令、公网令牌、WAN 地址全部替换为
  `$env:ROUTER_PASS` / `${PUBLIC_TOKEN}` / `${WAN_IP}` 等占位形式，并带正向对照的残留扫描，
  详见 [tools/README.md](tools/README.md)）。使用时请通过环境变量注入自己的凭据，**不要**把真实值提交回仓库。
