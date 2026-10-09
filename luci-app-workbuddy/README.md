# AI 中转服务器（luci-app-workbuddy）

在 OpenWrt / ImmortalWrt 路由器上运行 **AI 中转服务器**，把**本机 WorkBuddy 账号**
与**任意多个第三方 OpenAI 兼容服务器**聚合起来，对局域网/公网暴露**统一的
OpenAI 兼容接口**（`/v1/chat/completions`、`/v1/models`）。

每台服务器 = 一个 API 地址 + 一组 Key，组内 Key 自动轮询做负载均衡；
模型统一带 `<服务器前缀>/` 前缀，客户端据此选择走哪台服务器。

配套两块界面：

| 界面 | 位置 | 用途 |
| --- | --- | --- |
| **独立管理网页** | `http://<路由器IP>:8789/admin` | 日常管理：服务器与 Key、API 密钥、凭据池、模型策略。用管理员密码登录 |
| **LuCI 状态页** | 服务 → AI 中转服务器 | 只读查看运行状态；设置管理员密码 |

> 设计取舍：日常管理放在独立网页，是因为它需要在**公网**上也能用（LuCI 默认只在内网）。
> LuCI 页面因此精简为「状态展示 + 管理员密码设置」，避免同一份配置两处维护。

> **命名说明**：对外可见的名字是「AI 中转服务器」。内部标识符（UCI 配置节
> `workbuddy`、服务名 `/etc/init.d/workbuddy`、ucode 模块 `workbuddy.uc`、
> rpcd 对象名）**保持不变** —— WorkBuddy 上游的登录流程、凭据文件、已有配置
> 都绑定在这些路径上，改内部名需要数据迁移且会打断运行中的实例。

## 这是什么

WorkBuddy 官方客户端只在 PC / 移动端提供。本插件把它的接口协议**用纯 ucode 重新实现**，
让路由器本身成为一个常驻中转：家里任何设备（手机、平板、电视盒子、其他电脑）
只要支持自定义 OpenAI 接口，就能共享同一个 WorkBuddy 账号；
同时还能挂接第三方服务（日日新、点点等），把它们也统一到一个入口下。

路由器上没有 Node.js、没有 TLS 库，因此本实现：

| 环节 | 做法 | 原因 |
| --- | --- | --- |
| 进程与事件循环 | `ucode-mod-uloop` | 路由器原生，内存占用低 |
| HTTP 服务端 | `ucode-mod-socket` 监听 TCP，手写 HTTP 解析 | 无需引入额外 Web 服务 |
| HTTPS 上游 | 调用 `curl` 子进程 | ucode 无 TLS 能力，这是唯一可靠路径 |
| 配置存储 | `uci`（`/etc/config/workbuddy`） | 与系统一致，可被 LuCI 直接管理 |
| 凭据存储 | `/etc/workbuddy/token.json`（权限 600） | 与 UCI 分离，避免配置备份泄露凭据 |
| 服务器配置 | `/etc/workbuddy/upstreams.json`（权限 600） | 第三方地址与 Key，同样不进配置备份 |
| 管理页鉴权 | sha256 签名 Cookie（含过期戳） | 见下文「管理页安全设计」 |

## 运行时要求

- 内核：已在 **6.18.44**（ImmortalWrt SNAPSHOT, qualcommax/ipq60xx, aarch64）实测
- `ucode` 及模块：`fs`、`uloop`、`socket`、`uci`、`ubus`、`digest`
- `curl`（带 TLS）
- `luci-base`、`rpcd`（管理界面）
- 内存：实测常驻约 3–5 MB

## 核心功能

### 1. API 密钥可随时查看与复制

管理网页 → 「API 密钥」标签页会列出**全部密钥的明文值**（含已禁用的），
每条都有「复制」按钮。密钥不是"只显示一次"：

- 明文本来就存在 `/etc/workbuddy/apikeys.json`（600 权限）里才能做校验，
  "只显示一次"只是界面上的选择，不是存储限制
- 管理页登录后即可随时查看、复制、启用/停用、删除

### 2. 客户端版本自动获取

配置项 `auto_client_version` 默认开启。获取策略是**多源探测 + 自校准 + 下限兜底**：

1. 依次尝试 `VERSION_SOURCES` 里的探测地址（`/api/version`、`/version.json`）
2. **自校准**：记录上游实际接受过的最高版本号（`/etc/workbuddy/version.json`）。
   上游对版本号很宽松，因此"能成功请求的版本"比任何探测源都可靠
3. 全部失败时回退到配置里的 `client_version`（默认 `5.5.2`）

> 已核实：官方**没有**公开的客户端版本接口。`/v3/config` 只含插件市场的
> `versionUrl`；`/v3/version`、`/version.json` 等均 404；`download.codebuddy.cn/version.json`
> 是 CodeBuddy 的清单（且无 Windows 条目）。因此采用上述策略而非依赖单一接口。

关闭自动获取：LuCI 管理页或管理网页里把 `auto_client_version` 设为 `0`，
即固定使用 `client_version`。

### 3. 仅免费模型（防扣费）

`only_free_models` 默认开启：

- `/v1/models` 只返回免费额度模型（x0.00 积分）
- chat 请求若指定收费模型，**自动替换**为免费模型并记录日志

已实测确认的免费模型：`deepseek-v4.1-flash`、`hy4-preview-f`、`hy3`。

### 4. 多凭据负载均衡

多条凭据轮流使用，避免单账号被限流：

- 某条凭据失败会进入 60 秒冷却，自动切到下一条
- 冷却中的凭据会在管理页标出剩余时间
- 凭据来源：网页登录（`token.json`，作为 `default`）+ 手动添加（`pool.json`）

### 5. 服务器管理（多 API 地址 + 批量 Key 负载均衡）

这是本插件的核心能力。**每台服务器 = 一个 API 地址 + 一组 Key**，
可在管理页随时添加、修改、停用、删除。

**内置服务器（不可删除）**

| 服务器 | 地址 | Key 来源 |
|---|---|---|
| WorkBuddy | `https://www.workbuddy.ai` | 账号凭据池（见「凭据池」页，支持多账号轮询） |

内置服务器在列表里固定显示为第一张卡（左侧有蓝色标条），**没有删除按钮** ——
删掉它免费模型与凭据池就没有入口了；需要停用它请到「设置」页关闭服务。

**自定义服务器（可自由增删）**

任何 OpenAI 兼容服务都能接入。每台服务器配：

- **名称** —— 备注用，会显示在模型列表的 `name` 里（`模型名 · 名称`）
- **模型前缀** —— 路由依据，只能用小写字母、数字、`-`、`_`，长度 2–32
- **服务器 API 地址** —— 填到 `/v1` 为止，本服务自动拼接 `/chat/completions` 与 `/models`
- **API Key 密钥** —— **每行一条，支持批量粘贴**，自动去重、自动去首尾空格

**Key 负载均衡**

- 请求时从该服务器的 Key 池中**轮流取用**（round-robin）
- 某条 Key 失败（限流/鉴权失败/额度耗尽）→ 该 Key 进入冷却，自动换下一条重试
- 连续失败按指数退避，冷却上限 10 分钟；成功后立即恢复
- 冷却中的 Key 在管理页以黄色徽章标出剩余秒数，悬停可看最后一次错误
- 同一台服务器的多条 Key 互相独立，**每台服务器各自维护轮询游标**

**模型路由**

请求的模型名决定走哪台服务器，**所有**来源统一带服务器前缀：

| 模型名前缀 | 实际去向 |
|---|---|
| `workbuddy/` | 本机 WorkBuddy 凭据池（多账号轮询） |
| `<自定义前缀>/` | 对应的第三方服务器，用它自己的 Key 池 |
| 无斜杠（如 `hy3`） | 按原名直发 WorkBuddy，兼容旧客户端 |

前缀不存在时返回 400 `unknown upstream prefix: xxx`。

配置存于 `/etc/workbuddy/upstreams.json`（权限 600）。同一前缀不允许重复，
否则路由会有歧义，添加时会被拒绝。

> **免费模型防护（`onlyFree`）不作用于自定义服务器的模型** —— 它们本就不是
> WorkBuddy 的模型，用 WorkBuddy 的免费清单去校验必然"不通过"，会把请求
> 错误地改写成 WorkBuddy 的默认模型。

### 6. 公网访问开关

管理页的「设置」标签页里有一个独立开关，一键控制**管理页与 API** 是否对公网开放。
**默认关闭**，只允许局域网访问。

打开开关后，插件会**自动**在 UCI firewall 里创建端口转发规则
（`workbuddy_wan`，WAN → 本机监听端口）并 reload 防火墙；关闭时自动删除该规则。
不需要你手工去「网络 → 防火墙 → 端口转发」配置。

**自定义公网端口**：开关下方有一个「公网端口」输入框，可以把外网端口和内网端口分开：

```
外网 http://<公网IP>:18789  →  路由器 18789 端口  →  本机 8789（内部监听，不变）
```

- 留空 = 内外端口一致（都用 `port`）
- 填一个不显眼的端口（如 `18789`）能降低被扫描概率
- 端口必须是 1–65535 的整数，非法值会被拒绝；改成空串会回退到内部端口
- 开关保持开启时改端口，保存后立即重写规则生效

| 状态 | 含义 |
| --- | --- |
| 仅局域网可访问 | 默认。无防火墙规则 |
| 已生效 | 规则已建且 nftables 已放行，外网可达 |

**安全护栏**

- **未设置管理密码时拒绝开启** —— 此时开放公网等于任何人都能登录，接口会直接报错
- 开启时前端会二次确认，页面同时显示风险提示
- 关闭是幂等的，规则会被立即回收
- 即使开着，管理页仍受管理员密码保护、API 仍受 API 密钥保护

> 为什么写 UCI 而不是直接塞 nft 规则：fw4 会在 reload 时**重建整张 nftables 表**，
> 手写的 nft 规则会被冲掉；写进 UCI 才能被 fw4 持久地重新生成。
> 附带好处是规则在 LuCI 防火墙页面可见可审计，你想手动关掉也有地方关。

## 安装

### 方式一：源码编译（推荐用于正式分发）

把本目录放进 OpenWrt/ImmortalWrt 的 `package/` 或 feed 中：

```sh
# 在 SDK 或 buildroot 根目录
make package/luci-app-workbuddy/compile V=s
# 产物在 bin/packages/<arch>/base/luci-app-workbuddy_1.0.0-r1_*.apk
```

依赖 LuCI 的构建体系（`feeds/luci/luci.mk`），因此需要先执行 `./scripts/feeds install -a`。

### 方式二：设备上直接部署（无 SDK 时）

ImmortalWrt SNAPSHOT 使用 apk v3 格式，而设备端不含 `abuild` / `apk adbsign`，
无法本地打包。此时用附带的安装脚本按文件结构就地部署：

```sh
# 把整个目录上传到路由器后
cd /root/luci-app-workbuddy
sh install.sh
```

脚本会：检查并自动安装缺失依赖 → 部署文件 → 注册 procd 服务 → 重启 rpcd/uhttpd
→ 校验端口与 `/health`。

卸载：

```sh
sh install.sh remove
```

## 配置

配置文件 `/etc/config/workbuddy`。

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 是否启用服务 |
| `port` | `8789` | 监听端口 |
| `host` | `0.0.0.0` | 监听地址；`127.0.0.1` 表示仅本机 |
| `only_free_models` | `1` | 仅免费模型：过滤模型列表并在转发前替换收费模型 |
| `wan_access` | `0` | 公网访问开关：`1` 时自动创建防火墙转发规则并放行 WAN |
| `wan_port` | 空 | 公网外部端口：留空跟随 `port`；设置后外网端口与内网端口分离 |
| `auto_client_version` | `1` | 自动获取客户端版本（多源探测 + 自校准） |
| `client_version` | `5.5.2` | 客户端版本；自动获取失败时作为兜底 |
| `admin_password` | 空 | 管理网页密码；留空则管理网页停用 |
| `endpoint` | `https://www.workbuddy.ai` | 内置服务器（WorkBuddy）地址 |
| `token_file` | `/etc/workbuddy/token.json` | 凭据缓存路径 |
| `share_token` | 空 | 旧版单一令牌（兼容用）；推荐改用 API 密钥 |
| `debug` | `0` | 调试日志 |
| `up_max_inflight` | `4` | 自定义上游并发上限；`0` = 不限制 |
| `wb_max_inflight` | `6` | WorkBuddy 上游并发上限；`0` = 不限制 |
| `queue_max` | `32` | 排队上限；`0` = 不排队（超出立即 429） |
| `queue_timeout` | `20` | 排队超时秒数，等太久返回 429 + `Retry-After` |
| `use_pool` | `1` | 启用上游连接复用（常驻 `workbuddy-pool`） |
| `pool_port` | `8790` | 连接池端口（只监听 `127.0.0.1`） |
| `pool_keepalive` | `30` | 连接池保活间隔秒数，防止空闲连接被回收 |
| `rl_brake_hits` | `4` | 限流刹车：窗口内累计多少次上游限流拒绝后闭闸；`0` = 关闭刹车 |
| `rl_brake_window` | `20` | 限流刹车计数窗口（秒） |
| `rl_brake_sec` | `8` | 限流刹车闭闸时长（秒） |
| `rl_brake_max_ra` | `15` | 回给客户端的 `Retry-After` 上限（秒） |
| `up_first_byte_sec` | `12` | 静默看门狗「首字节档」：上游连上后多久还没吐出第一个字节就换 Key；`0` = 关闭该档 |
| `up_idle_sec` | `25` | 静默看门狗「流中档」：已开始返回数据后，中途静默多久判定断流；`0` = 关闭该档 |
| `wb_idle_sec` | `75` | WorkBuddy 通道静默上限（该通道首字节本来就慢，不参与首字节档）；`0` = 关闭 |
| `bridge_port` | `8791` | 上游响应回环桥端口（只监听 `127.0.0.1`）；`0` = 关闭回环桥，退回直接读 popen 管道 |

配置项大多可在**管理网页 → 服务设置**里改；改完自动生效，无需手动重启。
管理网页不可用时（例如忘了密码），直接改本文件：

```sh
uci set workbuddy.main.admin_password='新密码'
uci commit workbuddy
/etc/init.d/workbuddy restart
```

### 数据文件

| 路径 | 权限 | 内容 |
| --- | --- | --- |
| `/etc/workbuddy/token.json` | `600` | 网页登录凭据，对应池中的 `default` |
| `/etc/workbuddy/pool.json` | `600` | 多账号凭据池 |
| `/etc/workbuddy/apikeys.json` | `600` | API 密钥列表（含明文值） |
| `/etc/workbuddy/upstreams.json` | `600` | 自定义服务器配置（地址 + 多条 Key） |
| `/etc/workbuddy/version.json` | `600` | 客户端版本自校准缓存 |

## 管理网页

独立的管理面板，地址 `http://<路由器IP>:8789/admin`。

### 首次使用

1. 在 LuCI（**服务 → WorkBuddy**）的「管理员密码」栏设置密码并保存
2. 或者命令行：`uci set workbuddy.main.admin_password='你的密码'; uci commit workbuddy; /etc/init.d/workbuddy reload`
3. 浏览器打开 `http://<路由器IP>:8789/admin`，输入密码登录

未设置密码时访问 `/admin` 会提示「未设置管理员密码」，不会暴露任何信息。

### 功能

| 标签页 | 内容 |
| --- | --- |
| **概览** | 运行状态、凭据数、密钥数、客户端版本、当前模型 |
| **API 密钥** | 列出全部密钥明文，支持复制、新建、启用/停用、删除 |
| **服务器管理** | 服务器增删改查：添加/测试/改 Key/停用/删除，显示每条 Key 的冷却状态 |
| **凭据池** | 多账号轮询管理：查看/添加/测试/停用/删除，过期提示与自动判重 |
| **服务设置** | 仅免费模型、客户端版本自动获取、固定版本号、**公网访问开关** |

### 服务器管理

「服务器管理」页分两块：上面是**服务器列表**，下面是**添加服务器**表单。

**服务器列表**第一张卡固定是内置的 WorkBuddy（左侧蓝条标记为「内置」，
带「已登录/未登录」状态与账号数），它没有删除按钮。其余是自定义服务器卡片。

**添加服务器需要填**

| 字段 | 说明 |
| --- | --- |
| 服务器名称 | 备注用，会显示在模型列表的 `name` 里（`模型名 · 名称`） |
| 模型前缀 | 路由依据。客户端里模型名要写成 `前缀/模型名` |
| 服务器 API 地址 | 填到 `/v1` 为止，例如 `https://token.sensenova.cn/v1` |
| API Key 密钥 | **每行一条，支持批量粘贴**；空行与重复项会被自动去掉 |

**卡片上的状态**

| 徽章 | 含义 |
| --- | --- |
| 内置 | WorkBuddy 自身，不可删除 |
| 启用 / 已停用 | 停用后该服务器的模型从 `/v1/models` 消失，请求会被拒 |
| N/M Key 可用 | M 条 Key 中当前有 N 条不在冷却中 |
| 绿底 Key | 可用 |
| 黄底 Key | 冷却中，悬停可看最后一次错误 |

**每张卡的操作**

- **测试** —— 用该服务器的 Key 拉一次 `/models`，成功时弹出前 6 个模型名
- **改 Key** —— 打开弹层，粘贴新的一组 Key **批量覆盖**原有全部 Key
- **停用 / 启用**
- **删除** —— 二次确认后删除该服务器及其全部 Key，同时清掉内存里的冷却记录

> 注意「删除」与「停用」的区别：**停用**只是让模型从列表消失、请求被拒，
> 配置与 Key 都还在，随时可以再启用；**删除**会连同 Key 一起永久移除。

### 凭据池管理

「凭据池」页分两块：上面的表格列出池中全部凭据，下面的「添加凭据」提供两种方式。

**条目的状态徽章**

| 徽章 | 含义 |
| --- | --- |
| 正常 | token 有效且剩余有效期充足 |
| N 天后过期 | 有效，但不足 30 天到期，提前提醒 |
| N 天后过期（黄） | 不足 7 天到期，需要尽快处理 |
| 已过期 | token 已失效，**不会参与轮询**，请重新登录或更换 |
| 冷却 Ns | 该账号刚被上游限流，暂停使用 N 秒后自动恢复 |
| 已停用 | 手动停用，保留在池中但不参与轮询 |

**添加方式一 · 登录账号获取**
点「登录并添加账号」，页面会打开授权链接（同时显示可复制链接）。
在浏览器里完成 WorkBuddy 授权后，凭据自动加入池中。授权窗口 300 秒。
刷新页面不会丢失正在进行的登录流程。

> **每次登录都是「新增一个账号」，不会顶掉已有的账号（v2.2.0 起）。**
> 重复登录**同一个**账号则是「就地更新」：刷新它的 token 并保留原来的
> 名称、位置与 id —— 因为 token 过期后重新登录是正常操作，不该报错，
> 更不该在池里留下两份同一个账号。
>
> v2.2.0 之前不是这样：登录凭据只写 `token.json` 这**一个槽位**，
> 第二次登录会直接覆盖第一次的账号，池子里永远只有一个网页登录账号。

**删除由你决定，不会自动替换**
池中账号只会因为「你手动删除」「token 过期」「被上游限流而临时冷却」而
退出轮询；代码里没有任何「自动踢掉某个账号腾位置」的逻辑。

**添加方式二 · 手动添加 token**
粘贴 access token 即可，会自动去掉 `Bearer ` 前缀和首尾引号。

**自动判重（两层）**

| 情况 | 结果 |
| --- | --- |
| token 内容完全相同 | 拒绝，提示已存在并指出是哪个条目 |
| 同一账号的另一个 token（JWT `sub` 相同） | 拒绝，提示该账号已在池中 |
| 已过期的 token | 拒绝，提示重新登录 |
| 不是合法 JWT / 解析不出 payload | 拒绝，提示确认复制完整 |

> 判重同时覆盖 `pool.json` 与网页登录凭据（`token.json`）。
> 只查前者会漏掉「把自己当前登录的账号再添加一遍」这个最常见的重复场景。

**账号与有效期从哪来**
WorkBuddy 的 access token 是标准 JWT，管理页直接解析其 payload：

| 字段 | 用途 |
| --- | --- |
| `exp` | 计算剩余天数，驱动过期徽章，并在轮询时跳过已过期凭据 |
| `preferred_username` | 显示账号名；手动添加时留空名称则自动采用它 |
| `sub` | 账号唯一 ID，用于识别「同账号的不同 token」 |

解析在 ucode 内实现（`b64UrlDecode` + `parseJwt`），**不验签**——
这里只用于展示与去重，不做安全判断。

### 中转日志（v2.2.0）

「中转日志」页回答一个问题：**轮换规则到底在干什么，该往哪个方向调。**

它分两张卡片：「中转轮换分析」（每个账号/Key 的健康矩阵）与
「最近中转事件」（最近 40 条明细），右下角「重置统计」清零全部计数。

**事件类型**

| 事件 | 含义 | 计入 |
| --- | --- | --- |
| 选中 | 本次请求选中了该账号/Key | 选中数 +1 |
| 成功 | 该次选中拿到了正常响应 | 成功数 +1 |
| 限流 | 上游返回 429 / TPM / RPM 超限 | 限流数 +1，**同时计入选中数** |
| 风控 | 上游安全策略拦截（`11140` / `11-128` 等） | 风控数 +1，同时计入选中数 |
| 鉴权 | 401/403，token 或 Key 失效 | 鉴权数 +1，同时计入选中数 |
| 网络 | 连接失败、超时等 | 同上 |
| 请求错 | 上游判定为客户端错误（400/404） | 同上 |
| 冷却 | 该账号/Key 进入冷却 | 冷却次数 +1 |
| 换号 | 一个账号失败后换下一个 | 全局换号数 +1 |
| 耗尽 | 重试次数用尽，请求最终失败 | 全局失败数 +1 |
| 中断 | 客户端提前断开 | 全局中断数 +1 |
| 截断 | 流已经开始却未出现 `[DONE]` | 全局截断数 +1 |

> **「中断」与「截断」互斥**（v2.4.0 修正）：读侧 EOF / 写失败即判为
> **中断**，只进中断桶。`/metrics` 的 `chat.truncated` 原先把这类客户端取消
> 也算作截断，导致同一个事件被记两次、截断数偏高；现在两条口径一致——
> 「截断」只表示**代理或上游把流截断了**（含看门狗流中超时），是真正需要
> 告警的那一类。

> **「选中数」的分母口径**

**选中数 = 选中 + 限流 + 风控 + 鉴权 + 网络 + 请求错**，不是只数
「选中」那一条事件。一次勾选会在日志里留下多条事件（先选，再被限流），
只数前者会让分母偏小——v2.2.0 真机验收时就出现过把 11% 成功率的
Key 显示成 50% 的情况。

矩阵页顶部的全局「选中」与各账号「选中」之和**始终相等**，
可以用这一点自查统计是否被写坏。

> **「冷却占比」怎么来的**

冷却时长有两个来源：代码按失败类型给的（限流 5s / 鉴权 60s / 其他 2s，
并有指数退避上限）和从上游 `Retry-After` 采信来的——事后无法还原。
所以实现上记录的是**冷却开始时间**，等这个账号下次真正被用起来时
再结算实际时长。因此「当前冷却」一栏在账号正在冷却时才有值，
「冷却占比」= 累计冷却秒数 ÷ 进程运行秒数。

**边界与开销**

日志**只存内存，不落盘**：`/overlay` 只有约 30MB 可用，且频繁写入会
损耗闪存。明细保留最近 **200** 条（环形缓冲，可调 `RELAY_LOG_MAX`），
聚合计数随进程生命周期累积，重启即清零。
矩阵行数 = 账号数 + Key 数，规模上不构成负担。

### 成功率加权轮询（v2.3.0，权重口径见 v2.4.0）

中转日志不是只看的——它直接驱动轮换规则。v2.3.0 起，账号 / Key 的选中
不再纯轮询，而是按**历史成功率加权**（v2.4.0 在此基础上加入"近期健康度"，
见下一节）：

| 成功率 | 权重 | 效果 |
| --- | --- | --- |
| 100% | 10 | 获得 10 倍流量 |
| 50% | 5 | 获得 5 倍流量 |
| 10% | 1 | 最低流量，但仍有机会恢复 |
| 0% | 1 | 不绝杀——冷却恢复后仍给机会 |
| 样本不足（< 3 次） | 1 | 冷启动，不偏置 |

> 下表是**累计**成功率的口径，v2.4.0 的实际权重是
> `int((累计*3 + 近期*7)/10)`——同一张表仍适用于 `life` 这一项。

**两处生效**：

- **凭据池**（`usablePool`）：权重 = `relayWeight(cred.id)`，替代原来的纯轮询。
- **自定义上游 Key**（`weightedRotate`）：权重 = `max(配置权重, relay权重)`，
  即 relay 只做"加成"不做"打折"——用户配置的权重是底线。

> 为什么 0% 的账号不绝杀？
>
> relayAgg 是进程生命周期内的累计，早期的失败会一直拉低均分。给 weight=1
> 而非 0，让它在冷却结束后仍能被试到；如果它恢复了，后续成功会逐步拉高
> 均分——这正是"自我修复"的反馈环。真正的绝杀由冷却机制做（被风控 →
> 冷却 30 分钟，这期间根本不入选）。

### 智能转换：近期健康度 + 累计成功率（v2.4.0）

v2.3.0 的权重只看**累计**成功率，这有两个毛病：一是样本越多越迟钝——一个
已经恢复的账号要被过去几十次失败拖着走；二是**突发失败**反应太慢，等累计
均分掉下来，客户端已经白等了好几轮。v2.4.0 把「最近发生了什么」直接纳入
权重，这就是"智能转换"：

```
picks  = 累计 pick（含 rate/risk/auth/client/net 各类失败）
life   = int(ok * 10 / picks)          // 累计成功率 → 1..10
rec    = int(近期 ok * 10 / 近期 pick)  // 最近 3 次选中的成功率 → 0..10
weight = max(1, int((life * 3 + rec * 7) / 10))
```

| 规则 | 取值 | 理由 |
| --- | --- | --- |
| 近期窗口 | 最近 **3** 次选中（`RELAY_RECENT_MIN`） | 窗口太大等于又回到累计；3 次是全失败能被判定的最小样本 |
| 近期权重占比 | **7 成**（`life * 3 + rec * 7`） | 突发故障要能立刻反映，累计只做平滑 |
| 近期 3 次全失败 | 直接压到 **1** | 不等累计均分下滑，立刻让出流量 |
| 样本 < 3 次 | **1** | 冷启动不偏置；同时"近期无数据"不会把权重打到 0 |
| 下限 | 恒 ≥ **1** | 与 v2.3.0 一致：绝不 0 权重绝杀，冷却结束后仍有机会自我修复 |

**为什么近期单独看、而不是只缩短累计窗口**：累计窗口缩短会让"偶发一次失败"
的账号过度降权（把噪声当信号）；两者按 3:7 混合后，偶发失败只轻微降权，
而**连续**失败会迅速压到 1——正是突发限流想要的行为。

**为什么突发失败能立刻生效**：账号被上游判定限流（`rpm exhausted`）时，
`markCredFail` 会先记 `rate` 事件再进冷却；冷却期它根本不入选，冷却一结束
若近期仍是 0/3，权重仍是 1，于是它只能拿到极少的探测流量——恢复得靠这
一点探测流量，不会长期霸占主流量。

管理页「中转日志」的账号 / Key 矩阵新增**「近期」**列：`成功/选中`，全失败
标红、全成功标绿、不足 3 次显示 `—`。这一列与 `weight` 列对照着看，就能
直接判断"这个账号是不是刚被打下去"。

#### 一起修的截断计数误报

上线验收时发现汇总卡的两条口径对不上：relay 侧记 `abort`、`trunc` 正常，
而 `/metrics` 的 `chat.truncated` 偏高。原因是 `notifyTruncation()` 把
`metrics.truncated++` 写在 `if (conn.writeBroken) return` **之前**——客户端
中途取消（用户点停止、curl 超时）时读侧 EOF 已经把它标成 `aborted`，却仍然
加了一次 truncated，同一个事件同时进 `abort` 和 `truncated`。

```
修复前：curl -m 2 掐断一次 → chat.aborted 1（1 个事件）chat.truncated 2（2 个事件）
修复后：curl -m 2 掐断一次 → chat.aborted 1（1 个事件）chat.truncated 0（0 个事件）
```

判定必须放在自增**之前**，且 `aborted` 优先：客户端取消不是"被截断"，它是
客户端自己的决定，混进来会让 truncated 失去告警价值（真正要报警的是代理或
上游把流截断）。看门狗中途 abort（`watchdogTick` 走 `closeConn`，不置
`aborted`）属于真截断，仍然计数。

#### 验收记录（真机，2026-10，`v2.4.0`）

| 判据 | 结果 |
|---|---|
| 静态六项检查 | 全部 OK（顶层函数 238） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0`（含新增的 `client abort not truncated` / `writeBroken not truncated`） |
| `ucode -c` | RC=0 |
| 30 并发 soak（6 波 × 5） | `200=17 / 429=13 / 000=0`，无 `exactly_16384`，ucode 存活 |
| relay 账目自洽 | `sum(acc.pick) == totals.pick`（90 == 90，6 个账号/Key） |
| 权重随健康度变化 | `sk-3lw…TOC5` soak 前 `weight=10` → 连续失败后 `recent=0/3` → **`weight=1`**；`sk-RWe…SPf3` `life=4 / recent=2/3` → `w=5` |
| 权重公式复核 | `w1790861140` `life=9 / recent=2/3(rec=6)` → `int((9*3+6*7)/10)=6` ✓ |
| 截断口径 A/B | 客户端 `curl -m 2` 掐断：修复前 `aborted=1 / truncated=2`，修复后 `aborted=1 / truncated=0` |
| 管理页渲染 | 「近期」列与权重列正确显示，全失败标红（浏览器实测） |

> 权重不是"配"出来的而是"算"出来的：上面 `life=4 / recent=2/3 → w=5` 这类
> 数字可以手工按公式复算，任何一格对不上就说明聚合口径出了问题——这也是
> 把「近期」列放进管理页的意义。

### 上游管理增强：编辑服务器 + 单 Key 启停/权重（v2.5.0）

v2.5.0 的起点是用户报障：「上游更换不了 Key、添加不了服务器」。根因在
**前端 `api()` 调用参数错位**——`api(path, body)` 只有两个参数，但 5 处上游
相关调用写成了三个参数：

```
api('POST', '/admin/api/upstreams/test', {id})   // 错误：path='POST'，body='/admin/api/upstreams/test'
```

请求于是打到 `/admin/api/POST`，返回 `404 no such admin endpoint`。后端端点
全部正常，缺陷 100% 在前端。已把 5 处调用全部改成两参形态
（`test` / `keys` / `toggle` / `delete` / `add`）。

顺带按主流中转（one-api / new-api / gpt-load）补齐了上游管理能力：

| 能力 | 实现 | 位置 |
| --- | --- | --- |
| **编辑服务器** | 改名称 / 模型前缀 / API 地址；前缀查重（排除自身）；前缀变更时返回 `prefixChanged`，提示客户端同步改模型名 | `editUpstream()` @2864；端点 `/admin/api/upstreams/edit` |
| **单 Key 启停** | 掩码反查真实 Key（管理页只显示掩码）；停用时清该 Key 的失败计数与冷却状态 | `toggleUpstreamKey()` @2931；端点 `/admin/api/upstreams/key/toggle` |
| **单 Key 权重** | 1–1000 整数，只改单个 Key，不整批覆盖 | `setUpstreamKeyWeight()` @2969；端点 `/admin/api/upstreams/key/weight` |
| 停用 Key 不入选 | `usableUpKeys()` 跳过已停用 Key，不参与 clean 也不进 rec 恢复队列 | `usableUpKeys()` |
| Key 徽章交互 | 点击掩码徽章弹出「Key 管理」模态框（状态开关 + 权重输入 + 当前失败次数） | `editUpKey()` @6019 |
| 编辑服务器按钮 | 上游卡片操作区新增「编辑服务器」 | `editUpInfo()` @5976 |

管理 API 现在提供完整的 `upstreams` 增删改查：`add` / `delete` / `toggle` /
`edit` / `test` / `keys`，外加 `key/toggle`、`key/weight` 两个单 Key 维度端点。

#### 验收记录（真机，2026-10，`v2.5.0`）

| 判据 | 结果 |
| --- | --- |
| 静态六项检查 | 全部 OK（顶层函数 245） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0`（v2.4.0 用例全部保留） |
| `ucode -c` | RC=0（322520 字节，无 BOM） |
| 管理 API 直连 | `upstreams/add` → `edit`（返回 `prefixChanged`）→ `key/toggle`（停/启）→ `key/weight`（设 7）→ `delete` 全链路通过；错误掩码正确返回「Key 不存在」 |
| 管理页 UI | 编辑服务器模态框、Key 管理模态框、Key 池徽章交互均正常（浏览器实测） |
| 长流连通性 | 8 路并发长流式输出无队列拒绝（`up_max_inflight=8`）、4 个 Key 全部有 usage 消耗 |

### 模型可用性测试与每日刷新（v2.8.0）

用户的原始诉求是：「优化测试确保所有模型正常可用，有时候模型会变更所有每天
凌晨1点定时获取最新的模型。」

#### ① 模型可用性测试：拉列表 ≠ 能用

v2.5.0 的「测试」按钮只做了一件事——用 Key 拉一次上游 `/models`。这只证明
**鉴权过了**，不证明**模型能推理**：一个模型可以被上游下架、可以只对特定账号
开放、可以被限流到每次都超时，而 `/models` 依旧把它列出来。用户于是会遇到
"列表里有、一调用就报错"。

v2.8.0 增加真正走推理路径的测试：

| 函数 | 行为 |
| --- | --- |
| `testUpstreamModel(up, modelName)` @3431 | 直连 `POST {baseUrl}/chat/completions`，body `{model, messages:[{role:'user',content:'ping'}], max_tokens:1, stream:false}`，`curl -sS -m 20`。**能过鉴权 + 能完成一次推理**才算可用 |
| `testAllUpstreamModels()` | 遍历所有启用上游的每个模型；模型来源优先级 = 自定义清单 > 最后已知列表 > 现场拉取；去重 + 每上游上限 20 个 |

端点 `POST /admin/api/upstreams/test-all`，管理页「服务器管理」页签的「批量操作」
行新增 **「测试全部模型」** 按钮，结果以 ✅/❌ 清单弹窗展示，失败项附上游原始
错误文本。

请求体经 `mapUpstreamModel()` 翻译——**测试走的是与真实转发完全相同的映射
路径**，所以测 `gpt-4o` 实际打的是 `glm-5.2`，别名配错会在这里直接暴露。

> **为什么直连上游，而不是复用本机的 `handleChat`？**
> 走代理会占用并发闸门（`up_max_inflight`）和排队槽位。一次「测试全部」在模型
> 多的上游上可能把在途额度吃光，把真实用户请求挤进排队——**用一个诊断功能去
> 影响它本要诊断的生产链路**，是自相矛盾的。测试请求本身极小（`max_tokens:1`），
> 直连最省事也最不打扰。

#### ② 每天凌晨 1 点自动拉取最新模型

模型会变（上游上架、下架、改名），配置一次就永远正确的假设不成立。v2.8.0 增加
每日巡检定时器：

```
modelRefreshTick() @3552  ──每 60s 自重排──▶  localtime().hour === modelRefreshHour ?
                                              └─ 是且今天没跑过 ──▶ 强制刷新模型列表
                                                                   └─▶ 跑全模型连通性测试
```

关键实现细节：

| 点 | 做法 | 理由 |
| --- | --- | --- |
| 自重排位置 | **在业务逻辑之前**先 `uloop.timer(MODEL_REFRESH_CHECK_MS, ...)` | 无论本次是否到点都要排下一次；放在 `return` 之后就再也不会被调度 |
| 当日去重 | `modelRefreshLastDay === today`（`today` = `year*10000+(mon+1)*100+day`） | 定时器 60s 一跳，没有去重的话整点那一小时内会跑 60 次 |
| 时钟口径 | `localtime(time())` | 用路由器本地时间，用户说的"凌晨 1 点"就是墙上时钟的 1 点，不做时区换算 |
| 关闭时打日志 | `model refresh: off (daily 01:00, ...)` | 与刹车一致：事后翻日志要能分清"没到点"和"被关了" |

配置项（UCI `workbuddy.main`，管理页「设置」页签有「每日模型巡检」卡片）：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `model_refresh_enabled` | `1` | 总开关；关闭后仍可手动点「测试全部模型」 |
| `model_refresh_hour` | `1` | 触发小时，0–23 整数；脏值被拒绝（200 + `ok:false`），不会写进 UCI |

#### ③ 修掉一个让模型映射静默失效的 bug

这是 v2.7.0 留下的缺陷，本轮才定位到根因。

管理页配了模型清单却**不生效**——`/v1/models` 依旧返回上游的远程模型列表。
根因在 `loadUpstreams()`：它从 `upstreams.json` 读出记录后**构造了一个新的
对象**，但新对象里**没有拷贝 `modelList` / `modelMap`** 这两个字段：

```js
push(out, {
    id: id, name: ..., prefix: prefix, baseUrl: baseUrl,
    keys: keys, weights: weights, enabled: ..., createdAt: ...,
    // ← modelList / modelMap 在这里被丢掉了
});
```

于是 `/v1/models` 的「有自定义清单就直接用、不外呼上游」分支永远进不去，
`upstreamStatus()` 的 `modelCount` 也恒为 0。写入侧一直是好的
（`upstreams.json` 里字段齐全），坏的只是读取侧——所以配置看起来"存住了"
却毫无效果，正是这类 bug 最难查的地方。

修复后两个字段（含 `modelListSeen` 去重）随对象一起带出。

#### ④ 模型列表落盘兜底

`upModelCache` 原本只存在内存，服务一重启就空。上游 `/models` 恰好抖动/限流时，
`/v1/models` 就返回空列表——客户端会以为自己配错了。新增：

| 机制 | 说明 |
| --- | --- |
| `MODEL_CACHE_FILE` | `/etc/workbuddy/modelcache.json`（权限 600），存"最后已知可用"列表，键为 `prefix\|baseUrl\|keyCount` |
| `saveModelCache()` @2493 | 拉取成功时写盘 |
| `loadModelCache()` @2507 | 启动时载入 |
| `/v1/models` 兜底 | 拉取失败**且**有历史列表时用历史列表，不返回空 |
| `saveUpstreamsFile()` 联动清空 | 上游配置变更时同步清盘 —— 否则会拿"上一个上游配置"的列表兜底，**那是错的列表，比空列表更容易误导人** |

> **位置约束（踩坑记录 #12 的又一例）**：`saveModelCache` 必须定义在
> `saveUpstreamsFile` **之前**。ucode 不提升声明，函数按定义时的词法作用域解析
> 自由变量；声明在后会抛 `access to undeclared variable`，而 **`ucode -c` 与
> 单元测试都拦不住**——只有真正执行到那一行才会炸。第一版把这两个函数放在
> `fetchUpstreamModels` 之后（约 3007 行），而调用点 `saveUpstreamsFile` 在
> 2493 行，属于典型的"平时看着正常，一保存上游就死"。已移回 2493 行。

#### 验收记录（真机，2026-10，`v2.8.0`）

| 判据 | 结果 |
| --- | --- |
| 静态六项检查 | 全部 OK（顶层函数 278） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0` |
| `ucode -c` | RC=0，零输出（398511 字节，无 BOM） |
| 文件一致性 | 本地与路由器 md5 均为 `db6025984af7e8be4d646d8b527001c1` |
| `/v1/models` 修复 | 返回 `sensenova/deepseek-v4-flash` + `sensenova/gpt-4o` 两条自定义清单，不再外呼上游（修复前返回 `deepseek-v4.1-flash`/`glm-5.2`/`kimi-k3` 等远程模型） |
| `modelCount` 修复 | `/admin/api/state` 返回 `2`（修复前恒为 0） |
| `test-all` 端点 | HTTP 200 / 2.86s / `{"ok":true,"total":2,"okCount":2,"failCount":0}`；`gpt-4o` 经别名→`glm-5.2` 映射后测试通过 |
| 每日巡检链路 | 把 `model_refresh_hour` 临时设为当前小时后重启，日志依次出现 `model refresh: on (daily 19:00, ...)` → `daily 19:00 run started` → `sensenova -> 7 models` → `test-all done: 2/2 ok, 0 failed`（约 2s 完成，未打满在途额度），随后已改回 `1` |
| 落盘文件 | `/etc/workbuddy/modelcache.json`（600，428 B）写入 `{"saved":...,"cache":{"sensenova\|https://token.sensenova.cn/v1\|4":{...}}}` |
| 管理页数据层 | 浏览器实取 `/admin/api/state`：`version="2.8.0"`、`modelRefreshEnabled=true`、`modelRefreshHour=1`、`modelCount=2`、`modelsText="deepseek-v4-flash\ngpt-4o=glm-5.2"`（编辑弹窗可无损回显） |

### freeAI 集成与投毒式用量漏账修复（v2.9.0）

freeAI（`opencode.ai/zen` 免费层）是 v2.6.0 引入的内置上游，`APP_VERSION` 保持
`2.9.0` 期间修复了两个真实缺陷，其中第二个直到本轮端到端验收才暴露。

#### ① 大小写重复头导致 freeAI 聊天 100% 400

`freeaiHeaders()` 把会话包下发的头合并进请求头时**没有做大小写去重**。会话包
下发的键是**全小写**（`authorization`、`user-agent`），而我们自己拼的是首字母
大写（`Authorization`、`User-Agent`）。ucode 对象键**区分大小写**，于是合并后
同时存在两组键：

```
[Authorization] => Bearer public          [authorization] => Bearer public
[User-Agent] => opencode/1.18.31 …        [user-agent] => opencode/1.18.15 ai-sdk/…
```

`freeaiCurlArgs` 是逐键 push `-H` 的，curl 于是发出**四行互相冲突**的
Authorization / User-Agent，上游直接回 400。

隐蔽之处在于：末尾那句「重新把 UA 钉回 CLI 形态」的 `out['User-Agent'] = FRE_UA`
只覆盖**精确大小写**的那个键，对包下发的 `user-agent` 完全无效——上游实际收到
的反而是那个会触发免费层识别的 ai-sdk UA。而且 `session` / `models` 两步不经过
`freeaiHeaders`，所以探活显示全绿，看起来像"上游拒绝请求体"。

修法是合并前先建小写索引表跳过碰撞：

```js
let ours = {};
for (let k in out) ours[lc('' + k)] = true;
for (let k in pack.headers) {
    let key = '' + k;
    if (ours[lc(key)]) continue;   // 我们自己钉的键优先
    out[key] = '' + pack.headers[k];
}
```

#### ② 投毒式用量漏账：流尾的计费块盖掉了 usage

`extractUsage()` 倒序扫描 SSE 行取用量，旧实现**只要解析出一行合法 JSON 就
`break`**——于是"最后一行"决定了结果。freeAI 的流尾形态是：

```
data: {... "usage":{"prompt_tokens":8594,...}}
data: [DONE]
data: {"choices":[],"cost":"0"}      ← 最后一行，没有 usage 字段
```

旧实现在计费块上 `break`，`obj.usage` 取到 `null`，直接 `return null`。后果是
**freeAI 聊天 HTTP 200 成功、SSE 完整、`[DONE]` 齐全，但用量一笔都没记上账**：

| 观测点 | 修复前 | 修复后 |
| --- | --- | --- |
| 全局 `usage`（连打一次 freeai chat 前后） | `112453/504/112957` → **纹丝不动** | `112453/504/112957` → `121047/521/121568`（**+8594/+17/+8611**，与流内 `prompt_tokens:8594` 逐字吻合） |
| `/metrics` 的 `byUp` | 只有 `wb:*` 与 `u1790326707` | 首次出现 **`ufreeai`** 与 **`ufreeai\|***`** |
| `/admin/api/state` 的 `freeai.usage` | 恒为 `null` | `{"prompt":8594,"completion":17,"total":8611}` |

这个 bug 之所以危险，是因为它**只影响记账、不影响功能**：回答照常返回，只有
"用量面板永远显示 0"这一个症状，很容易被当成前端问题。修法是把「解析成功」与
「确实含 usage」分开判断，解析不出 usage 就继续往前找：

```js
let cand = null;
try { cand = json(payload); } catch (e) { cand = null; }
if (type(cand) !== 'object' || cand === null) continue;
let cu = cand.usage;
if (type(cu) !== 'object' || cu === null) continue;  // ← 关键：不含 usage 就继续
obj = cand;
break;
```

已补三条单元测试锁死该行为（含反向对照：只有计费块、确实没有 usage 时**必须**
仍然返回 `null`，不能瞎编数字）。

#### ③ 终态错误品牌化（配合用户 m13333 的中性化要求）

freeAI 的失败路径此前只品牌化了一半：**流式**路径由 `freeaiPurifyLine` 捕获流内
错误并走 `freeaiBrandMessage()`；**非流式 / 流前失败**不进流，落到通用兜底
`'上游 ' + up.prefix + ' 的所有 Key 均失败：' + conn.lastFailReason`。三个问题：

1. freeAI **没有 Key 池可轮换**，"所有 Key 均失败"让用户无从下手；
2. 原样泄露上游真名与内部文本（`Error from provider (Console)`、`OpenCode's free
   tier can only be used from within OpenCode`）；
3. 把**瞬时**闸门说成服务故障。

现在 `freeaiBrandMessage()` 改成「分类后只回自己的话，原文一律丢弃」，原文只进
日志；`freeaiErrText()` 负责授权服务端（`fp.php`/`activate.php`/`heartbeat.php`）
错误码的中性化翻译；全失败分支对 `up.id === FRE_UPID` 特判，瞬时闸门回
`429 + Retry-After: 5` + `'freeAI 服务繁忙，请稍后重试'`，其余回 `502` + 分类文案。

验收实测：未知模型触发终态错误后，响应体 `grep -ciE 'opencode|free tier|within
OpenCode|provider \(Console\)|zen'` = **0**。

#### 验收记录（真机，2026-10，`v2.9.0`）

| 判据 | 结果 |
| --- | --- |
| 静态六项检查 | 全部 OK（顶层函数 279） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0` |
| `ucode -c` | RC=0，零输出（406312 字节，无 BOM） |
| 文件一致性 | 本地与路由器 md5 均为 `a2615249b654e3183f1bd52c5171607a` |
| 管理页「测试」按钮（`/admin/api/freeai/test`） | HTTP 200，三步全绿：`session.ok`（ttl 300）/ `models.ok`（7 个）/ `chat.ok`（`done:true`、`text:"OK"`） |
| 管理页「重置」按钮（`/admin/api/freeai/reset`） | HTTP 200 `{"ok":true}`，state 的 `session` 回到 `null` |
| 管理页「保存」按钮（`/admin/api/freeai/save`） | HTTP 200，磁盘 `freeai.json` 的 `model`/`ver`/`injectFingerprint`/`brandNeutralize` 全部按提交值落盘 |
| 流式请求（`freeai/big-pickle`） | HTTP 200 / 2446 字节，SSE 完整、含 `reasoning_content` 增量、尾部 `usage` + `[DONE]` |
| 非流式请求 | HTTP 200 / 538 字节，标准 `chat.completion` 对象、`content:"56"`、usage 完整 |
| 品牌中性化 | 终态错误响应体零上游字样（grep 计数 0） |
| 用量记账 | 单次 chat 后全局 usage `+8594/+17/+8611`，`byUp` 首次出现 `ufreeai` |
| 心跳续签 | `tokenAge: 2`（60s 心跳 tick 生效），日志见 `chat via upstream freeai key ***` |

> **会话 id 派生（验收项③的正面证据）**：探针用同样的头集合打上游，**只有
> body 里带上会话包下发的 `fingerprint.tools`（12 个 opencode 工具，天然含
> `bash`/`read`）时才 200**；裸 119 字节 body 一律 403 `FreeTierError`。这与
> `agent2api` 的 `emulation.rs` 硬编码的三项校验互相印证：`Bearer public` 凭据、
> `ses_` 26 字符形态、**body 必须是 agent 形态（`stream:true` + 含 `bash`/`read`
> 工具桩）**。生产路径一直能通，正因为 `freeaiShape()` 无条件注入这 12 个工具。

### freeAI 网关移植审计与四项 P0 修复（v2.9.3）

对照官方 PC 端网关 `gateway.mjs`（786 行）逐项审计路由器的 ucode 移植版，
发现并修复四处**与官方语义不一致**的缺陷，另清理一处同类死代码。

#### ① 流式净化是死代码（最严重）

`freeaiPurifyChunk`/`freeaiPurifyLine` 定义了、单测也覆盖了，但**全文件零调用点** ——
真正的流式转发在 `makeOnChunk` 里直接 `safeSend(conn, chunk)` 下发原始字节。
官方 `gateway.mjs:538-551` 的 `fixChunk` 承担两件事，因此这两项保障在路由器上从未生效：

1. 丢弃"既无 `usage` 又无 `choices`"的噪声帧；
2. 给缺 `id` 的帧补 `chatcmpl-*` id（严格客户端会因缺 id 报错）。

修法：新增 `freeaiPurifyFeed(chunk)`，把任意切分的 chunk 逐字符扫 `\n`，
**只把完整行**交给 `freeaiPurifyLine`，跨 chunk 的半行攒在全局 `frePurifyTail` 里
（不补换行 —— 补了会伪造一个完整帧边界）。`makeOnChunk` 里改为：

```ucode
let sendBuf = chunk;
if (conn.freeaiPath) sendBuf = freeaiPurifyFeed(chunk);
if (length(sendBuf) > 0 && !safeSend(conn, sendBuf)) { ... }
```

注意 `conn.sseBuf` **仍攒原始字节** —— usage 提取与截断检测都依赖上游原样内容。

#### ② 收尾缺 `freeaiPurifyFlush`，最后一行会丢

修好①之后立刻暴露出**同一类**问题：净化的半行缓冲若在流结束时不清空，
最后那一行会被永久留在 `frePurifyTail` 里丢掉 —— 而丢的往往正是带 `usage`
的计费块或 `[DONE]`，客户端会一直等不到结束帧。在 `onUpstreamDirectEnd`
的收尾路径补上：

```ucode
if (conn.freeaiPath && conn.headersSent && !conn.aborted && !conn.writeBroken) {
    let tailOut = freeaiPurifyFlush();
    if (length(tailOut) > 0 && !safeSend(conn, tailOut)) conn.aborted = true;
}
```

> 教训：**"定义了函数"不等于"接上了线"**。两次都是同一形态 —— 先发现
> `freeaiPurifyChunk` 零调用点，修完又在同一条链路上发现 `freeaiPurifyFlush`
> 零调用点。查这类缺陷的有效手段是 `grep -n '函数名'` 看**调用点行号**，
> 而不是看定义是否存在；单测覆盖了函数本身，反而掩盖了它从未被调用。

#### ③ 上游 403 未做"即焚重领会话包"

官方 `gateway.mjs:523-527` 在收到 403 时 `burnSession()` 后立刻重领会话包重发一次。
我们原先只在 `args === null`（会话包**缺失**）时重领，**不覆盖"包还在但已被上游作废"**。
更糟的是 403 会被 `isClientErrorReason` 判成"客户端错误"，于是原样返回 400/404 给用户
—— 而请求本身没有任何问题。

修法：新增 `freeaiBurnSession()`，并在 `tryNextUpKey` 里**放在 `isClientErrorReason`
分支之前**拦截：

```ucode
if (reason && conn.freeaiPath && conn.upstream &&
    conn.upstream.id === FRE_UPID && !conn.freeaiBurned) {
    let lr = lc('' + reason);
    if (index(lr, 'free tier') >= 0 || index(lr, 'within opencode') >= 0 ||
        index(lr, 'freetiererror') >= 0) {
        conn.freeaiBurned = true;
        let np = freeaiBurnSession();
        if (np !== null) { conn.upTry--; F.spawnUpstreamDirect(conn); return; }
    }
}
```

`FRE_SESSION_BURN_MIN = 10` 解决并发放大：作废是**上游侧**状态，本地缓存看不出来，
若并发请求都撞上 403 而各领一次，会直接打爆授权服务端（`activate.php` 限 20 次/时/IP）。

#### ④ `freeaiHttp` 用 `-k` 跳过证书校验

授权服务端下发的是 token / `sig_block` / `fingerprint` / `upstream_url` —— **全是信任输入**。
跳过证书校验叠加"我们不做 Ed25519 验签"，等于**完全没有任何信任锚**，中间人可任意改写上游地址。
已去掉 `-k`，保留 `--resolve`：某条 IP 证书真有问题时它会回 421/TLS 重置，
而代码本来就会换下一条 IP。

#### ⑤ `routePassthrough` 漏标 freeAI 通道

`conn.freeaiPath` 原先只在 `handleChat` 的 customUp 分支设置，
`routePassthrough` 里另有一处 `conn.upstream = up`（同样可能命中 `FRE_UPID`）
未标记 ⇒ 走 `/v1/messages` 一类透传端点打 freeAI 时，净化与"即焚重领"两道保障都不生效。

#### 验收记录（真机，v2.9.3）

| 判据 | 结果 |
| --- | --- |
| 静态六项检查 | 全部 OK（顶层函数 282） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0` |
| `ucode -c` | RC=0，零输出（414164 字节，无 BOM） |
| 文件一致性 | 本地与路由器 md5 均为 `8f5ec9506ec68ec8cde16d3292d351f1` |
| 调用点接线 | `freeaiPurifyFeed` @5720、`freeaiPurifyFlush` @6237、`freeaiBurnSession` @6080、`freeaiPath` @6624/@6776 |
| 证书校验 | `grep -c 'curl -sS -k'` = **0** |
| 流式请求（`freeai/big-pickle`） | HTTP 200 / 2945 字节，`[DONE]` 计数 1 |
| **尾部帧完整性** | `tail -c 20` hexdump = `…7d 0a 64 61 74 61 3a 20 5b 44 4f 4e 45 5d 0a`，即 `data: [DONE]\n` **精确落在末尾** |
| 用量记账 | 流内 `prompt_tokens: 8590`，`/metrics` 全局 `prompt: 349177 / completion: 1012` 持续累加 |

### freeAI 深度调试与模型全量获取（v2.9.4）

v2.9.3 把 freeAI 恢复到基本可用后，这一版针对三类问题：**配额自伤**
（v2.9.3 的误诊把授权服务的 `req_hour=10` 打光）、**模型可见性**
（管理页只显示计数不显示模型名）、**与官方语义的剩余偏差**
（心跳频率、会话包过期、请求体形状、会话头派生）。

#### ① 403 即焚收窄：v2.9.3 把误诊变成配额事故

v2.9.3 收到上游 403 就即焚重领会话包重试，把 `FreeTierError`
（"free tier can only be used within OpenCode"）当成了会话包作废的证据。
实测证明**重领的包和旧包一模一样，解不了 403** —— FreeTierError 是上游对
请求形态/频次的瞬时拒绝，不是会话失效。误诊的代价是每次 403 白烧一次
`fp.php`，而授权服务端对该接口限 `req_hour=10`/`req_day=50`，
并发下十几个请求就把配额打光，之后 freeAI 全通道 `too_frequent`
不可用，直到小时窗口滚过。

修法：即焚条件收窄到**只认明确作废证据**的措辞：

```ucode
if (reason && conn.freeaiPath && conn.upstream.id === FRE_UPID && !conn.freeaiBurned) {
    let lr = lc('' + reason);
    if (index(lr, 'session_replayed') >= 0 || index(lr, 'session invalid') >= 0 ||
        index(lr, 'invalid session') >= 0 || index(lr, '会话失效') >= 0) {
        conn.freeaiBurned = true;
        freeaiBurnSession();
        conn.upTry--;
        F.spawnUpstreamDirect(conn);
        return;
    }
}
```

FreeTierError 走普通失败路径（品牌化文案 + `Retry-After`），不再烧授权配额。
`conn.freeaiBurned` 是 per-connection 预算，一次完整请求最多即焚重试一次。

> 教训：**重试机制的触发条件必须是"重试可能改变结果"**。403 后重领的包
> 和旧包完全一致（同一机器码、同一 token、同一 sig_block），结果必然不变 ——
> 这种重试就是纯烧配额。上"自动自愈"之前先回答：这个失败在服务端对应什么
> 状态，我的动作会改变那个状态吗？

#### ② 模型列表全量获取 + 管理页显示模型名

`freeaiModels()` 原先丢弃 `dead` 表中的模型，而官方 `gateway.mjs:352-358`
**不过滤**（dead 只用于挑 `DEFAULT_MODEL`，`:316`）。本版改为全量返回
`{id, name, dead}`，活模型排前。`/v1/models` 对 dead 模型在 `name` 上追加
「暂不可用」标记（id 不变 —— 客户端可能硬编码了 id）。

管理页「服务器管理」显示每个上游实际获取到的模型名列表（原先只有
`modelCount` 计数）：`upstreamStatus()` 新增 `detectedModels` 字段，
前端渲染「可用模型」徽章行，超过 24 个折叠成「…共 N 个」。数据源是模型
缓存（`/v1/models` 拉取时回写的 `modelList`），状态接口**纯本地读取** ——
`/admin/api/state` 是 5 秒轮询，在状态接口里打授权服务端或上游等于自我 DoS。

#### ③ 会话种子与净化器半行缓冲 per-connection 化

会话头种子（首条 user 消息派生）原先存在**模块级全局** `freSessionSeed` ——
uloop 单线程并发交错时 A 流的种子会覆盖 B 流的。同类问题还有 `frePurifyTail`
（SSE 半行缓冲）：多路 freeAI 流交错回调会把 A 流的残段拼到 B 流的 chunk 上。

修法：

- `freeaiSeedOf(body)` 扫 messages 取首条非空 user content；
- `freeaiSessionId(seed)`：有种子用 `sha256Hex('ses\0'+seed)` 派生
  12 hex + 14 Base62，无种子回落随机 `freeaiOid()`；
- `freeaiHeaders(pack, seed)` 的三个会话头
  （`x-opencode-session`/`x-session-affinity`/`X-Session-Id`）**只派生一次**
  同值 —— 原先三次独立调用在无种子回落分支会给出三个不同随机值（隐藏 bug）；
- `conn.freSeed` 在 `freeaiCurlArgs` 内计算一次，全程复用；
- 净化器改为 `freeaiPurifyFeed(conn, chunk)` / `freeaiPurifyFlush(conn)`，
  半行缓冲放 `conn.freTail`。`conn.sseBuf` 仍攒原始字节（usage 提取与
  截断检测依赖上游原样内容）。

> 教训：单文件 uloop 服务里，**模块级可变变量 = 所有并发连接共享的全局态**。
> 判断标准：变量的生命周期若应是"一次请求/一条连接"而非"整个进程"，
> 就不该放模块级。本版挖出两处，都是自己此前引入的。

#### ④ 心跳频率跟随服务端下发

官方 `gateway.mjs:121`：`auth.interval = (j.heartbeat_interval || 600) * 1000`；
`:136` 注释自证："token TTL 已缩至 2min(防逆向)，定时器必须跟随服务器下发的
heartbeat_interval(60s) 而非写死 10min"。我们原先写死 60 秒（值碰巧对，
但没有依据）。本版心跳成功时采纳 `j.heartbeat_interval`（夹在 10–3600 合法
区间），存入运行时变量 `freHeartbeatSec`，下一次 tick 动态生效；未下发或
非法值**保持当前值**（绝不回落官方的 600 兜底 —— token TTL 2 分钟时
600 秒心跳会掉线）。常量同步改名 `FRE_HEARTBEAT_SEC`（原名 `_MS`
但值一直是秒，名不副实）。

官方另外两条教训一并吸收：`startHeartbeat` 起新链前先 `clearTimeout`
（原实现叠加递归链导致频率翻倍打满限流，20261006-07 事故帮凶）—— 我们的
tick 是单链自重排且**先重排再执行业务**，结构上不可能叠加；心跳 429
不计入失败计数（服务端限流 ≠ 授权失败，官方原逻辑任何 `!ok` 都 fails++，
3 次误锁合法用户，同事故根因）。

#### ⑤ 会话包过期以服务端下发的 `exp` 为准

官方 `gateway.mjs:390`：`Date.now() < DIRECT.exp - 30000`（提前 30 秒刷新）。
我们原先用本地常量 `FRE_SESSION_TTL=240` 判新鲜，服务端下发的 `exp`
存了但没用。本版改为优先 `pack.exp`（毫秒）比较，缺失才回落本地 TTL。

#### ⑥ 请求体形状：`max_tokens` 与 `max_completion_tokens` 互斥

官方 `gateway.mjs:491,501` 是逐字段白名单**新建对象**，恒只写 `max_tokens`。
我们是就地 mutation 客户端对象 —— 新版客户端两个字段齐发时上游直接 400
`[invalid_request_error] max_tokens and max_completion_tokens cannot both be set`。
修法：两字段合并取一，`delete body.max_completion_tokens`，
最终只写 `max_tokens`（夹在 `FRE_MAX_TOKENS=4000`）。

#### ⑦ 其他清理

- `/admin/api/freeai/test` 的 chat 步显式挑第一个非 dead 模型
  （原先取 `ms[0]`，撞上 dead 会误报"chat 不可用"）；
- 删除死码 `freeaiPurifyChunk`（v2.9.3 用 feed/flush 取代后遗留，零调用点）；
- 纠正两处错误的语言注释（"ucode 不支持 delete" —— 路由器实测
  `delete o.b` / `delete o[k]` / 嵌套删除全部可用；真正踩过的坑是对
  **非对象**取下标 delete）。

#### 验收记录（真机，v2.9.4）

| 判据 | 结果 |
| --- | --- |
| 静态六项检查 | 全部 OK（顶层函数 283） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0` |
| `ucode -c` | RC=0 |
| 文件一致性 | 本地与路由器 md5 均为 `d279333e3f044ceb6235abd6628a9301`（425042 字节） |
| `/health` | `"version": "2.9.4"`，upstreams:1 / upstreamKeys:4 / modelRefreshEnabled:true |
| `/admin/api/freeai/test` | 三步全 ok：session（ttl:300）/ models（count:13）/ chat（done:true，text:"OK"） |
| 端到端流式（`freeai/big-pickle`） | 1470 字节，`data: [DONE]` 收尾，流内 usage `8855/3/8858` |
| 用量记账 | `/metrics` `usage.byUp.ufreeai = 8855/3/8858` 与流内**完全一致**（per-conn 净化器不影响原始字节提取） |
| `/v1/models` | 13 个 `freeai/*` 全列出，其中 6 个带「暂不可用」标记 |
| 管理页 | 内联 JS `node --check` RC=0；浏览器实测 `window.load`="function"、`window.S`="object"、版本徽章 v2.9.4；「可用模型」徽章行渲染出真实模型名列表 |

### freeAI 协议对齐二期与配置链路硬化（v2.9.5）

v2.9.4 让 freeAI 通道恢复可用并把模型全量暴露。本版落地移植审计的 P1/P2
收尾项（DNS 回落、重试降档、协议/UA 对齐、退避分档），并在真机验收中
连带修复了三处**配置持久化链路**的真实缺陷。

#### ① freeaiHttp 重写：系统 DNS 回落 + 自愈式好 IP 发现（P2-a）

`FRE_CF_IPS` 两条钉死的 Cloudflare IP 会随边缘路由翻转失效。此前全部失败
就等于 freeAI 授权服务不可达，直到手动改配置。v2.9.5 在候选列表**末位追加
`null`（不加 `--resolve`，走系统 DNS）**，并把 `-w` 扩为
`%{http_code} %{remote_ip}` —— DNS 回落连上的实际 IP 回填 `freGoodIp`，
下一个请求恢复"钉 IP"快路径。Cloudflare 轮换 A 记录后无需任何人工干预。

同批修正一个老 bug：`'000'`（连接级失败）满足旧判定
`length(out) === 3 && out !== '421'`，**曾被当作成功**——坏 IP 被缓存进
`freGoodIp` 且循环不再前移，整条授权链路跟着一个死 IP 一起坏。
任何"长度为 3 就是 http_code"的松散检查都要显式列出全部合法值。

#### ② 重试降档与协议对齐（P2-b/d/e）

- **四处 `--retry` 降为 1**（freeaiApi / freeaiActivate / freeaiCurlArgs /
  test 端点）。`--retry-all-errors` 连 429 也重发，等于把 `fp.php` 的
  `req_hour=10` 配额双倍烧掉；官方 gateway 用 undici，**零重试**——
  连接级韧性由候选 IP 轮换提供，不用 curl 重试叠配额事故。
- **freeAI 路径默认 HTTP/1.1**（与官方 undici 一致），管理页新增
  「HTTP/1.1 对齐」开关，取消勾选回退 `--http2`；通用上游的
  `curlArgs`（HTTP/2 + TCP FastOpen）不变。
- freeAI 路径移除 `--tcp-fastopen`（curl 8.6 上 FASTOPEN+HTTP2 组合有兼容问题）。
- **User-Agent 可配置**：`freeai.json` 新增 `ua` 字段（管理页留空 =
  回退内置默认 `opencode/1.18.31 …`）。上游收紧版本闸门时改一处配置即可跟上，
  不必重新刷机。

#### ③ 会话包失败退避分档（P1-g/h）

新增 `freeaiSessionBackoff(err)`：`too_frequent` / `must_upgrade` 属于
"60 秒后再试也解不了"的闸（前者是 fp.php 自身的 10 次/时配额，后者在官方
`gateway.mjs:402-424` 是客户端版本闸/服务端闸），退避改用
`FRE_ACTIVATE_BACKOFF`（900s）；其余瞬时错误保持 60s；拉取成功重置回 60。
同时把 `must_upgrade` 从 403「重领自愈」的匹配里剔除——重领解不开版本闸，
只会白烧 20 次/时的激活配额。

#### ④ 真机验收暴露的三处配置链路缺陷（热修）

- **保存端点只防 `null` 不防空串**：`/admin/api/freeai/save` 旧写法
  `(j.token === null) ? cur.token : trim('' + j.token)`，API 侧发
  `"token": ""` 会直接把 token 洗空 → freeAI 全瘫。改为走
  `unchanged()`（空串 / 含 `*` 掩码 / 与当前值相同 = 未改动，保持原值）。
  UI 表单本身不带 token 字段所以日常踩不到，但配置接口是真实攻击面。
- **`force` 语义过载封死自愈**：`freeaiRefreshPack` 原
  `if (force || freReauthing)` 直接返回错误——而 test 端点、
  burnSession、换 Key 重领**都传 force=true**，token 一旦为空这些路径全部
  失去"自动重新激活"能力。改为仅 `if (freReauthing)`（防递归本来就有
  freReauthing + 非 force 分支双保险；`freeaiActivate` 自带 900s 节流）。
  部署硬化版后跑一次 `/admin/api/freeai/test`，日志即出现
  `freeai activated, new token saved`，链路自愈成功。
- **`freeaiSaveToken` 字段清单漏 `ua`/`http11`**：它按字段清单整体重写
  `freeai.json`，新增配置字段没进清单 → 每次 token 刷新（激活/心跳轮换）
  把自定义 UA 与协议开关洗回默认。教训：**字段清单式重写配置的地方有两处
  （保存端点 + freeaiSaveToken），加字段必须 grep 全部
  `writeJsonFile(FRE_CFG_FILE)` 调用点**。
- 前端 `testAllUp()` 点击时捕获的状态节点会被 5 秒轮询重建 DOM 变成游离
  节点（结果写了看不见）→ 改为每次按 id 重查后写入。

#### 上线验收（v2.9.5）

| 判据 | 结果 |
| --- | --- |
| 静态六项 + 单测 + `ucode -c` | 全部通过（顶层函数 284） |
| 文件一致性 | 本地与路由器 md5 `86ae293ca973ffb14fe78b6228769814`（433998 字节），`/health` 2.9.5 |
| `/admin/api/freeai/test` | 三步全 ok，且缺 token 时**自动重激活自愈**（session ttl:300 / models 13 / chat done:true） |
| 端到端流式（`freeai/big-pickle`，HTTP/1.1 对齐生效） | 8377 字节 `[DONE]` 收尾，`FINAL_OK`；上游品牌字样（opencode/zen）出现 0 次 |
| 用量记账 | `/metrics` `usage.byUp.ufreeai = 8593/56/8649` 与流内 usage **完全一致** |
| 配置链路 | 保存 round-trip（真值/掩码/空串三态）不再洗掉 license/machine/token/model；disk `ua:""`（=默认生效）、`http11:true` |
| `/v1/models` | 13 个 `freeai/*`，6 个带「暂不可用」标记 |
| 管理页 | 内联 JS 52417 字节 `node --check` RC=0；「可用模型」徽章正常 |

> 验收方法论：脚本**按 UI 真实发值的形态**（含 null / 空串 / 掩码三态）发
> 保存请求，才暴露了"UI 表单不带 token 字段"掩护下的端点清空缺陷——
> 只测 UI 会永远漏掉它。

### freeAI 子系统整体移除与 sensenova 全量模型（v3.0.0）

freeAI 上游授权已停摆，用户拍板整体删除（"这个用不了，单独删除完这个项"）。
本版**净删 1711 行 / 88597 字节**（10196→8485 行，437137→348540 字节），
删除后对 `freeai|FRE_|ufreeai|t-free` 做大小写不敏感全文检索为 **0 命中**——
真删，无桩、无悬挂引用。

#### ① 删除范围（一次自底向上的带断言批删脚本）

| 层 | 删除内容 |
| --- | --- |
| 配置与常量 | `FRE_*` 全部常量、`/etc/workbuddy/freeai.json` 读写链路、品牌替换文案、`freModelCache` 等专用缓存 |
| 协议簇 | `freeaiHttp / Api / Activate / Heartbeat / RefreshPack / Headers / Shape / Purify* / ErrText / Models / SeedOf / SessionId / Status / CurlArgs / Raw / Usable / Upstream` 25 个函数（约 800 行） |
| 转发路由 | 内置上游 `ufreeai`、`usableUpKeys` / `upstreamStatus` / `extractUsage` / `findUpstreamByPrefix` / `fetchUpstreamModels` / `testAllUpstreamModels` / `modelRefreshTick` 里的 `FRE_UPID` 特判全部拆除；`makeOnChunk` 净化分支还原为直接 `safeSend`；"所有 Key 均失败"与 `args===null` 的 freeAI 专属兜底删除 |
| 管理页 | 「freeAI」页签按钮、`t-free` 卡片、`renderFree/saveFree/testFree/resetFree`、`/admin/api/freeai/{save,test,reset}` 三端点 |
| 其他 | `/v1/models` 的 freeAI 合并分支、心跳启动调用、`names` 数组中的 `'free'` 项、state 快照的 `freeai:` 字段 |

**保留未动**：`FREE_MODELS` / `freeModelIds` / `only_free_models` 配置链——
那是 WorkBuddy 凭据池的免费模型过滤（与 freeAI 无关），一字未改。
`/etc/workbuddy/freeai.json` 在路由器上一并删除，避免留孤儿配置。

> 删除方法论：40 条边界断言的自底向上批删脚本。断言当场抓出三处侦察笔记与
> 实际不符（相邻区间被大区间吸收、边界行内容差一行）——没有逐条断言，
> 这会是一次静默错删。

#### ② sensenova 全量模型暴露（"sensenova 要获取所有模型映射"）

真机验证发现网关 `/v1/models` 只列出 2 个 sensenova 模型。根因是 v2.7.0 的
短路设计：`routeModels` 一旦看到非空自定义 `modelList`，就**只暴露清单内
别名、完全不外呼**（防上游挂/限流洗空列表）。每日凌晨刷新
`modelRefreshTick` 只写模型缓存、**不回填** `modelList`，所以清单遮蔽不会
自行恢复。

修法走配置层，不改码：用管理 API 清空该上游的自定义清单
（`/admin/api/upstreams/edit` 的 `models` 传空串 → `modelList/modelMap =
null`），`/v1/models` 立刻走缓存/现场分支，暴露上游全部 **7 个模型**
（deepseek-flash / deepseek-v4-flash / deepseek-v4.1-flash / glm-5.2 /
kimi-k3 / sensenova-6.8-flash-lite / sensenova-u1.5-lite）。

- 模型映射机制完整保留：任何时候再配 `alias=real` 清单即可用别名；
- 旧的 `gpt-4o→glm-5.2` 别名随清空失效——上游真名已全量可见，建议直接用
  `sensenova/glm-5.2`；
- **设计张力（已知取舍）**：再配非空自定义清单会重新遮蔽全量列表。要"全量
  可见"就不要配自定义清单，这是刻意的防洗空设计，不是 bug；
- `/metrics` 的 `usage.byUp` 键名本就是上游 id（`u1790326707`），不受影响。

#### ③ 每日 01:00 全模型刷新（确认覆盖 sensenova）

`modelRefreshTick()`（60s tick 判时，`modelRefreshHour` 默认 1）每天对**每个
enabled 上游**强制 `fetchUpstreamModels` 全量拉取 → 写缓存 +
`saveModelCache()`（持久化 `/etc/workbuddy/modelcache.json`），随后
`testAllUpstreamModels()` 逐模型真实 min-chat 探活。删除 `FRE_UPID` 特判后
该循环覆盖所有剩余上游（含 sensenova），无需额外配置。

#### ④ 上线验收（真机 192.168.69.1，v3.0.0）

| 判据 | 结果 |
| --- | --- |
| 静态六项 + 单测 + `ucode -c` | 全部通过（顶层函数 253） |
| 残留检索 | `freeai\|FRE_\|ufreeai\|t-free` 大小写不敏感 **0 命中**（本地与路由器一致） |
| 文件一致性 | 本地与路由器 md5 `cac6693d83ae550decba9537b14ecab1`（348540 字节），`/health` `3.0.0` |
| 旧端点 | `/admin/api/freeai/{test,save}` 登录态访问返回 404 `no such admin endpoint` |
| 管理页 | `/admin` 66402 字节，内联 JS 47166 字节 `node --check` RC=0；`renderFree`/`t-free` 0 命中 |
| `/v1/models?refresh=1` | 10 个模型：7 个 sensenova 全量 + 3 个 workbuddy 免费池（`only_free_models` 生效），0 个 freeai |
| E2E 流式（`sensenova/sensenova-6.8-flash-lite`） | 1719 字节，`data: [DONE]` 收尾，流内 usage `94/16/110` |
| E2E 非流式（`workbuddy/hy3`） | 1058 字节，`reasoning_content` 正常返回 |
| 用量记账 | `/metrics` `usage.byUp.u1790326707 = 94/16/110` 与流内**完全一致**；`chat.ok=2 / truncated=0` |
| 配置清理 | `/etc/workbuddy/freeai.json` 已删除；UCI 无 freeai 残留项 |

### 管理页安全设计

| 项目 | 做法 | 理由 |
| --- | --- | --- |
| 会话凭证 | `sha256(salt+密码+过期戳)` 的前 32 位十六进制 | 不用明文/MD5；把过期时间签进去，服务端能真正拒绝过期会话 |
| Cookie 属性 | `Path=/; Max-Age=86400; HttpOnly; SameSite=Lax` | **刻意不加 `Secure`**：面板走局域网明文 HTTP，加了 `Secure` 浏览器就永不回传 Cookie，表现为"密码正确却登录不上"且无任何报错 |
| 绑定 UA | **不绑定** | UA 由客户端控制，绑定会造成无故掉线 |
| 改密码 | 立即失效所有会话 | 签名里含密码，改后旧签名自然失效 |
| 登录限速 | 同一来源 IP 连错 8 次锁定 300 秒 | 防暴力破解 |
| 页面依赖 | 全部内联 HTML/CSS/JS | 面板要在无外网的局域网可用，不能依赖 CDN |

> 锁定是内存态，重启服务即解除。忘记密码时改 `admin_password` 即可。

## 登录 WorkBuddy 账号

服务需要 WorkBuddy 的 access token。有两种方式：

### 网页授权（推荐）

浏览器访问 `http://<路由器IP>:8789/login`（需带 API 密钥）完成授权，
或在管理网页的「凭据池」页点「登录 WorkBuddy」。

返回的 `authUrl` 用浏览器打开完成授权，凭据会在约 1 秒内自动写入路由器。
授权窗口 300 秒。

### 手动导入已有凭据

如果 PC 上已经登录过 WorkBuddy，可直接复用其凭据文件：

```sh
# 在电脑上找到 token.json（DSH 插件用户通常在 ~/.dsh-workbuddy/token.json）
# 复制到路由器 /etc/workbuddy/token.json 后
chmod 600 /etc/workbuddy/token.json
/etc/init.d/workbuddy restart
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 存活、凭据数、服务器数、鉴权开关状态、公网访问状态 |
| GET | `/models`、`/v1/models` | 模型列表（OpenAI 格式；开启仅免费时只含免费模型） |
| GET | `/credentials` | 凭据池冷却/失败状态（不含 token 本身） |
| GET | `/upstreams` | 服务器状态（Key 只回掩码，不含明文） |
| GET | `/login` | 发起网页登录，返回授权链接 |
| GET | `/login/status` | 登录进度 |
| POST | `/v1/chat/completions` | 对话补全，支持流式 |

### 鉴权

只要在 LuCI 里生成过 **任意一条 API 密钥**，所有请求都必须携带密钥：

- `Authorization: Bearer <密钥>`（推荐）
- `X-API-Key: <密钥>`
- `?key=<密钥>`

`/health` 始终免鉴权，方便探活。

> **安全要点**：即使在界面上把密钥全部「禁用」，代理**依然保持强制鉴权**，
> 只是这些密钥都无法通过校验（一律 401）。这是刻意设计 —— 避免误操作
> 禁用最后一条密钥后，代理直接对公网敞开。

### 仅免费模型

`only_free_models`（默认开启）做两件事：

1. `/v1/models` 只返回倍率为 `x0.00` 的免费模型；
2. 若客户端仍请求了收费模型，转发前自动替换成免费模型，并在日志留痕：
   `only_free: model "hy4-preview" not free -> fallback "deepseek-v4.1-flash"`

这样即使客户端内置了收费模型名，也不会产生费用。

> **注意**：该项**不作用于自定义服务器的模型**。第三方服务器的模型名不在
> WorkBuddy 的免费清单里，若也走这个替换逻辑，会被错误地改写成 WorkBuddy
> 的默认模型。判据是请求是否被路由到自定义服务器。

### 模型名与路由

发往 `/v1/chat/completions` 的 `model` 字段决定实际去向：

```
workbuddy/deepseek-v4.1-flash   → 内置 WorkBuddy，它收到 "deepseek-v4.1-flash"
sensenova/deepseek-v4-flash     → 该服务器，它收到 "deepseek-v4-flash"
askdiandian/dots3-note-prev     → 该服务器，它收到 "dots3-note-prev"
hy3                             → 无斜杠，按原名直发 WorkBuddy（兼容旧客户端）
```

- 前缀不存在时返回 400：`unknown upstream prefix: xxx`
- 无斜杠的模型名不做前缀解析，直接走 WorkBuddy，老客户端无需改动
- `stream` 字段会原样透传给自定义服务器，因此非流式请求拿到的是完整 JSON；
  WorkBuddy 自身始终返回 SSE，非流式由本代理合并

### 调用示例

```sh
curl http://192.168.69.1:8789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wb-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  -d '{
    "model": "workbuddy/hy3",
    "messages": [{"role":"user","content":"你好"}],
    "stream": true
  }'
```

流式与非流式都支持：请求体 `"stream": false` 时服务会把 SSE 流合并成一个
标准 completion 对象返回。

## 多账号凭据池（负载均衡）

一个账号在 WorkBuddy 繁忙时可能被限流。**管理网页 → 凭据池** 可以把多个账号的
`accessToken` 加入池中，代理会：

- **轮询**：每次请求按游标依次选用不同凭据，均匀分摊压力；
- **失败自动切换**：某个凭据返回 401 / 429 / 空响应时，立刻换下一个重试
  （单次请求最多试 3 个凭据）；
- **自动冷却**：失败凭据进入指数退避冷却（60s 起，逐次翻倍，上限 600s），
  冷却期内不再被选中；成功后计数清零；
- **跳过过期凭据**：解析 JWT 的 `exp`，已过期的凭据不参与轮询，
  避免把请求浪费在死 token 上（但仍会显示在管理页，方便你更换）；
- **跨存储去重**：`pool.json` 与网页登录凭据（`token.json`）按 token 全文
  与账号 `sub` 双重判重，同一账号不会重复占用多个轮询位；
- **识别网关错误页**：WorkBuddy 网关失败时会返回 HTML 错误页（如
  `401 Authorization Required`）而不是 JSON，本服务能正确识别并计入冷却。

网页登录获得的凭据显示为「网页登录凭据」（id 固定为 `default`，不可删除/禁用，
需用「退出登录」清除）；手动添加的凭据可随时测试、启用、禁用、删除。

> **关于轮询的实测边界**：轮转算法本身已验证（3 个账号严格按
> `A → B → C → A` 交替）。但"多个真实账号互相接管"只有在池中确实存在
> **两个不同账号**时才会发生——同一账号的两个 token 会被判重合并为一条。

## 外网访问（公网 IP）

1. 在 **服务器管理 / API 密钥** 里先生成一条 API 密钥，并确认**管理员密码足够强**
   （两者都是公网暴露时的唯一防线）；
2. 进管理页 **设置 → 公网访问**，打开「允许公网调用管理页与 API」并保存。
   插件会自动创建并应用防火墙规则，无需手工配置。

   如需自定义外部端口，可到 **网络 → 防火墙 → 端口转发** 编辑那条
   `workbuddy_wan` 规则（例如改成 `18789` 降低被扫描概率）。

3. 路由器 WAN 若是公网 IP，即可用 `http://<公网IP>:8789/v1` 访问；
4. 若 WAN 是运营商大内网，需要另配 DDNS + 内网穿透，或让光猫做 DMZ。

> **开关默认关闭**，安装后不会自动暴露。想收回公网访问，把开关关掉即可 ——
> 规则会被立即删除并 reload 防火墙。

## 性能说明

### 转发效率优化（2026-09-27 实测，详见 lessons/workbuddy-forward-efficiency.md）

| 措施 | 实测效果 |
|---|---|
| 自定义上游模型列表缓存（TTL 300 s，`?refresh=1` 强制刷新） | `/v1/models` 1.66 s → **0.21 s**（首次）/ **0.004 s**（命中） |
| 上游失败冷却按类型区分（限流 20s→40s→80s…上限 300s；鉴权 600s；瞬时 5s） | 连续 10 次请求 1.42~3.16 s，不再出现 12 s/60 s 挂起 |
| 上游静默看门狗（**v1.8.2 起分两档**：首字节 12 s / 流中 60 s，WorkBuddy 75 s，详见「静默看门狗」节）+ curl `--speed-limit 1 --speed-time 30\|90` | 死链路 36 s 内收 502（修复前无限挂起）；v1.8.2 后客户端 TTFB p90 由 30 s+ 降到 3.69 s |
| Key **严格轮播**（游标依次轮转，冷却中的跳过） | 实测序列 `3lw→RWe→F7L→6Wg→3lw`，4 把一轮 |
| 单个 Key **被限流不换 Key**，直接返回 429 + 原因（附 Retry-After） | 实测 `attempt 2/` 出现 0 次；请求不再被拖成"连撞几把" |
| 连接表回收（`closeConn` 摘除连接并释放缓冲） | 长跑不再累积请求体 / SSE 缓冲 |
| `listen()` backlog 64 → 128 | 公网突发不再丢 SYN |
| 内核参数 `files/etc/sysctl.d/99-workbuddy-forward.conf` | slow_start_after_idle=0 / fastopen=3 / mtu_probing=1 / syn_backlog=1024 |

基础项：

- 上游 curl 关闭缓冲（`-N`），并为客户端连接设置 `TCP_NODELAY`，减少小包延迟；
- 转发缓冲 `16KB`，避免高频 `read()` 系统调用；
- 上游连接超时 5 秒，配合凭据切换做快速失败；
- 模型列表缓存 6 小时，并在服务启动 1.5 秒后预热，首个 `/v1/models` 请求不再等待。

> **当时的剩余开销（2026-09-27 基线）**：每个请求仍会重新 fork curl 并重建到上游的
> TCP+TLS 连接，实测固定开销约 130~190 ms/请求。
> **其中「重建 TCP+TLS」这一半已在 v1.8.0 由连接池解掉**（见下节）；fork curl 的开销仍在。

### 上游连接复用（v1.8.0）

上面那条「尚未实施」已于 v1.8.0 落地：新增一个常驻 Go 小程序 `workbuddy-pool`
（静态编译 aarch64，约 6.3 MB，**零外部依赖**），持有到上游的 keep-alive 连接池，
curl 改为把请求发给本机池；池不可用时自动回退直连，用户无感。

| 项 | 说明 |
|---|---|
| 协议 | 请求头 `X-WB-Target: <上游基址>`，方法/路径/查询串/头/体原样透传 |
| 本机端点 | `GET /health`、`GET /stats`（含复用率与新/旧连接 TTFB 拆分） |
| 监听 | 只监听 `127.0.0.1`，且强制 target 带 http(s) scheme —— 主服务对公网开放（`wan_access`），池绝不能成为可被外部利用的开放代理 |

实测收益（池 `/stats` 同主机拆分，n=16）：

| 指标 | 新建连接 | 复用连接 | 差额 |
|---|---|---|---|
| TTFB p50 | 1603.077 ms | 1298.631 ms | **约 304 ms** |
| DNS + conn_wait + TLS | — | — | 1.91 + 135.3 + 84.8 ≈ **222 ms** |

（另一轮 n=138 测得 221.444 → 112.249 ms，省约 109 ms。**该拆分需 n≥15 才有意义**，
小样本读数是噪声。）

> 这个收益**用 `/metrics` 的直方图测不出来** —— 那些桶在 1–3 秒区间只有
> 500–1000 ms 分辨率，分辨不出 300 ms 的差异。做这类对比必须看池自身的
> new/reused 拆分。同理，用 curl 做 `use_pool=1` vs `0` 的 A/B 也**得不出结论**：
> 上游生成耗时本身在 1.17–3.32 s 波动，远大于待测效果。

设计上刻意做对的几处：

- **`DisableCompression` + 逐块 `Write` + 立即 `Flush`**：SSE 必须逐字节原样透传。
  若用默认的 bufio（4 KB）攒够才发，整场流式对话会被成段延迟 —— 这是插入代理的头号风险。
- **预热用 `HEAD` 并读尽 body**：Go 的 transport 只在 body 读到 EOF 才把连接还给空闲池，
  读一半就关会**亲手杀掉要保的连接**，比不预热更糟。
- **`ResponseHeaderTimeout: 0`**：WorkBuddy 是 agent 上游，可能长时间思考后才吐首字节，
  超时交给 ucode 的静默看门狗与 curl 的 `--speed-time`，不重复设易误杀的阈值。

### 并发上限与 FIFO 排队（v1.8.0）

上游限的是 tpm/rpm 而非连接数，并发越高越容易整批撞 429，因此加了闸门 + 队列。
实测 8 并发（`up_max_inflight=4`）：闸门严格卡在 4，第 5~8 个进队列并按序排空，
`timeoutTotal=0`、`rejectedTotal=0`、8/8 返回 200。

> **但这并没有消除限流**。60 请求的 soak 里 `34×200 / 24×429 / 2×502`（40% 失败），
> 日志显示上游原文 `rpm exhausted`、`inference exceeds tpm/rpm limit`。
> 慢速顺序请求 3/3 全 200，说明 Key 没坏、是速率问题。详见
> `lessons/workbuddy-remaining-optimization.md` 的 v1.8.0 附录。
> 结论：**本地闸门只能削峰，不能扩容。**

### 可观测指标（v1.8.0）

`GET /metrics`（与 `/health` 一样不需要鉴权）输出：

| 分组 | 内容 |
|---|---|
| `chat` | `total` / `ok` / `fail` / `clientErr` / `rateLimited429` |
| `ttfbMs`、`totalMs` | 分 `pool` / `direct` 两条路径的 `p50` / `p90` / `p99` 与样本数 |
| `queue` | `inflight`（分 `wb`/`up`）、`waiting`、`queuedTotal`、`timeoutTotal`、`rejectedTotal`、`maxDepth` |
| `upstreams[]` | 每上游 ok/fail/rateLimited/authFail/inflight，以及**每把 Key** 的 ok/fail/rateLimited/authFail/coolingSec/lastErr（Key 一律掩码） |
| `pool` | `enabled` / `usable` / `port` / `failCooldownSec` / `requests` / `fallbacks` |

> 直方图桶在 1–3 秒区间分辨率只有 500–1000 ms，比较 ~300 ms 级别的差异时不要用它。

### 限流刹车（v1.8.1）

v1.8.0 的 soak 暴露了一个**正反馈放大**：一次请求撞上游限流后，代码会换下一把 Key 重试，
最多试满 4 把；当 4 把 Key 都已在冷却中时，这 4 次尝试**注定全部失败**，却给上游打了 4 倍流量。
实测池侧 **138 次上游请求 / 60 次客户端请求 = 2.25×**，其中 96 次（70%）就是这么烧掉的。

限流刹车（上游级熔断器）掐断这条链：

| 行为 | 说明 |
|---|---|
| 计数 | 每次上游回限流类错误时，在该上游的滑动窗口内 +1 |
| 闭闸 | 窗口内累计达到 `rl_brake_hits` → 闭闸 `rl_brake_sec` 秒 |
| 闭闸期间 | **只拦重试，不拦首次尝试** |
| 闭闸尾巴 | 剩余 ≤ 2s 时先等一次再发，把失败转成成功 |
| 客户端可见 | 被拦的请求直接回 `429` + 真实 `Retry-After`（上限 `rl_brake_max_ra`） |
| 自愈 | 任一 Key 成功即合闸 |

**为什么只拦重试**：首次尝试是唯一能探知"上游是否已恢复"的手段，拦掉它会把本可成功的
请求变成失败；而闭闸期间的重试是纯浪费。只拦重试 = 拿掉浪费 + 完整保留"不通就换下一个"。

**与 v1.7.1 被删掉的短路不同**：那个版本的判据是"我们自己的冷却模型"（4 把 Key 全在冷却就
立刻 429），`retry_after` 会算到荒谬的 577s，且违背"不通的自动换下一个"的要求。
本版判据是**观测到的上游拒绝**、要窗口内连续多次被拒才闭闸、`Retry-After` 有上限。

`/metrics` 里可观察：

| 位置 | 字段 |
|---|---|
| 顶层 `brake` | `enabled` / `hits` / `windowSec` / `brakeSec` / `maxRetryAfterSec` / `rejectedTotal` / `waitedTotal` |
| `upstreams[].brake` | `enabled` / `open` / `leftSec` / `hits` / `trips` / `waited` / `rejected` |

`rl_brake_hits=0` 可完全关闭刹车。

### 静默看门狗：两档阈值（v1.8.2）

上游连上之后一个字节都不回时，看门狗主动断开并按既有重试链换 Key，而不是让客户端干等到
自己超时。v1.8.1 及以前只有**一个**阈值（`UP_IDLE_SEC = 25`，WorkBuddy 通道 75s），
实测证明这个值是**客户端长尾的唯一来源**：

| 证据（v1.8.1，60 请求） | 数值 |
|---|---|
| 慢请求（≥5s）数量 / 其中失败数 | 13 / **0**（13 个全部 200） |
| 看门狗中止次数 | 32 次，idle 值**全部落在 25–29s** |
| 客户端 TTFB p50 / p90 / p99 | 2.25 / 31.82 / 34.03 s |

32 次中止全部卡在 25s 阈值之上（`UP_IDLE_TICK_MS = 5000` 扫描周期，故是 25+0~4s），
且慢请求**无一失败** —— 说明看门狗一直在做对的事（把"上游还没受理"的尝试掐掉换 Key，
换完几秒内就成功），只是**掐得太晚**：客户端因此白等 25~34 秒。

关键洞察：**"还没有第一个字节"和"流中途断掉"是两种完全不同的事故**，不该共用一个阈值。
没有第一个字节 = 上游根本没受理（多半是在服务端排队或撞了配额），早点换 Key 就好；
流中途断掉 = 已经出了数据又卡住，这时换 Key 会浪费已生成的内容，应该多等一会。

v1.8.2 拆成两档，用 `conn.attemptBytes` 判档 —— 它在每次尝试开始时清零
（`spawnUpstreamDirect` / `spawnUpstream`）、收到字节就累加，天然就是
"本次尝试是否已被上游受理"的标志位：

| 档位 | 判据 | 配置项 | 默认 | 命中日志 |
|---|---|---|---|---|
| 首字节 | `attemptBytes === 0` | `up_first_byte_sec` | `12` | `upstream no first byte in Ns (>=Ns, key#K, client C), failover` |
| 流中 | `attemptBytes > 0` | `up_idle_sec` | `25` | `upstream stalled Ns mid-stream (>=Ns, attempt A, client C), aborting` |
| WorkBuddy | 非自定义上游 | `wb_idle_sec` | `75` | 同「流中」 |

- `0` = 关闭该档（诊断链路时可用，生产不建议 —— 会让客户端一直干等）。
- 一致性保护：若 `up_idle_sec < up_first_byte_sec`（两者都非 0），视为配错，双双回默认值；
  否则首字节还没等到就被流中档杀掉，等于首字节档失效。
- 两条失败原因串（`上游 Ns 未返回首字节` / `上游流中静默 Ns`）都不含限流关键词，
  经 `isRateLimitReason()` 判为瞬时抖动，走 `UP_SOFT_COOL = 2` 秒冷却，**不会误计入刹车 hits**。
- 启动日志会打印当前档位：`forward tuning: idle=25s/75s first_byte=12s ...`。

**首字节档为什么取 12 s（`wb-test9.sh` 扫点，每档 60 请求，`up_idle_sec` 固定 60）**：

| `up_first_byte_sec` | 200 | 429 | 成功率 | 放大倍数 | TTFB p50 / p90 / p99 / max |
|---|---|---|---|---|---|
| 25（= v1.8.1 老阈值） | 47 | 13 | 78.3% | 0.97× | 2.16 / 7.04 / 67.71 / 67.71 s |
| **12（选定）** | 33 | 27 | 55.0% | 0.97× | **1.48 / 3.69** / 63.62 / 63.62 s |
| 6（否决） | 42 | 18 | 70.0% | **1.45×** | 2.14 / **63.92** / 68.23 / 68.23 s |

- 12 s 把中位长尾砍半（p90 7.04→3.69 s、p50 2.16→1.48 s），**放大倍数没变**（都 0.97×）
  —— 提前换 Key 没有给上游加压，代价只是更多请求被刹车快速 429（成功率数字随之下降，
  属设计内取舍：宁可早失败让客户端重试，也不要挂 30 秒）。
- **6 s 是反效果**：换 Key 太频繁，压力摊到整个 Key 池，放大倍数跳到 1.45×、p90 反而恶化到
  63.92 s。**阈值不是越低越好，存在拐点。**
- 三档的极值都在 ~63–68 s，且该值 ≈ `up_idle_sec(60) + UP_IDLE_TICK_MS(5)`，
  说明剩余长尾来自**流中档**而非首字节档。

**流中档为什么从 60 s 改成 25 s（`wb-test10.sh` / `wb-test11.sh` 扫点，每档 60 请求）**：

| `up_idle_sec` | 成功率 | 放大倍数 | TTFB p50 / p90 / p99 / max |
|---|---|---|---|
| 60（v1.8.2 默认） | 65.0% | 1.08× | 1.80 / 65.11 / 67.24 / **69.04** s |
| 30 | 55.0% | 1.50× | 1.39 / 32.93 / 35.68 / 36.35 s |
| **25（v1.8.3 默认）** | 58.3% | **1.02×** | 1.60 / **28.91** / 30.34 / 32.56 s |

- 结论很清楚：**客户端长尾几乎就等于这一档的阈值本身**（p90/max ≈ `up_idle_sec + 扫描间隔`，
  65≈60+5、33≈30+3、29≈25+4）—— 因为超时那一刻才中止并换 Key，之前全在干等。
  把 60 降到 25，最坏等待从 65 s 砍到 30 s，**放大倍数还更低了**（1.08×→1.02×）。
- 三档成功率（65.0% / 55.0% / 58.3%）在配额波动范围内**不可区分**，不构成保留 60 s 的理由。
- 为什么 25 s 不会误杀"模型在思考"：SSE 是**逐字**吐的，推理过程（reasoning）也是以增量形式
  持续下发的；流中途连续 25 s 一个字节都没有，基本等于链路已断，而不是"在想"。
  确有长静默需求的上游请单独调大 `up_idle_sec`，或配 `0` 关闭该档。
- `up_idle_sec` 是**该档决定长尾**这一点，与首字节档的取舍逻辑完全不同：首字节档越短越好
  （早换 Key 早成功），流中档则是在"误杀正常长回答"和"让客户端干等"之间取平衡，故取 25 s
  而非更短。

> v1.8.0 曾怀疑 502 是 curl `--speed-time 30` 误杀"上游思考中"。**该假设已被推翻**：
> 先到的是 25s 的看门狗，curl 的 30s 从来没机会触发。调 `--speed-time` 是修错了地方。


### 上游响应回环桥：根治并发静默截断（v1.8.3 引入，v1.8.4 修好）

v1.8.2 上线实测时发现一个**只在并发下出现**的严重正确性缺陷：客户端会收到**半截 SSE 流，
却完全看不出来**。这个缺陷比长尾严重得多，因为它静默地损坏回答内容。

**症状（`wb-test11.sh` / `wb-test13.sh` / `wb-test14.sh`）**

| 症状 | 证据 |
|---|---|
| 响应体恰好在 **16384 字节**处被切断（`proc.read(16384)` 的缓冲区大小），且切在 SSE 行**中途** | test11：5~6 个 body 恰 16384 字节、无 `[DONE]` |
| 有时是 16384 的**整数倍**（16384/32768/49152） | test13：B 相截断尺寸全是 16384 倍数 |
| 另有一类：**流已经完整转发完却不关闭连接**，curl 一直等到自己的 `-m` 上限 | test14 relay 臂：2 个 body 已含 `[DONE]` 但连接不关，40s 超时 |
| 客户端完全无感：`Connection: close` + 无 `Content-Length`、无 chunked，curl 照报 `code=200`、退出码 0 | `sseHeaders()` @2474-2486 |

**排除法（都是实测，不是推测）**

1. **不是看门狗**：把 `up_idle_sec` 配成 `600`，截断照旧发生（test13 A 相）。
2. **不是 Go 连接池**：`use_pool=0` 直接连上游，截断照旧发生（test13 B 相）。
3. **不是上游**：curl **直连**上游同一模型同一 Key，凡 HTTP 200 的流**全部完整**
   （test14 direct 臂：49245/80656/38699/49007/53149 字节，均含 `[DONE]`）。
4. **不是客户端 socket 丢块**：对截断 body 做数字连续性检测，序列 `1..12`、`1..38`、`1..17`、`1..13`
   **全部连续无跳号**，末尾停在 SSE 行中途 ⇒ 客户端没丢数据，是**读侧停止读取后连接被正常关闭**。

**根因（`probe2.uc` / `probe3.uc` / `probe6.uc` / `probe10.uc`）**

ucode 的 **`popen()` 管道 + uloop 读循环在并发下会丢可读事件**：读回调不再触发，于是
（a）在 16384 整数倍处收到伪 EOF 而提前关闭，或（b）流已完整却永不收尾。定位过程中的关键事实：

- **纯本地子进程即可复现**（probe2，无网络）：child0 在 163840 处报 EOF，child1/2/3 停在 180224
  且回调永不再触发 —— 生产两种症状都复现了。
- **`ULOOP_BLOCKING` 必须保留**：去掉它（probe3 `nonblock` 变体 5/5 失败、probe7）后
  `proc.read()` 恒返回 NULL，读取完全不可用。这也正是 `onAccept()` 注释早已写明的坑。
- 但**阻塞语义下 EAGAIN 与 EOF 无法区分**：probe5 证明阻塞读的"len=0"确实等于 EOF；
  probe6 又证明**子进程仍存活时也会出现 len=0（EMPTY）**。且 `proc.pid` / `proc.returncode`
  实测全是 `(null)`（probe4），无法另辟蹊径判存活。⇒ **在 popen 路径上无法消歧，只能换读路径。**
- **ucode 的 socket 读路径是可靠的**：probe10 用 5 个客户端各灌 200000 字节，
  **5/5 全部收满、EOF 可靠、无空读误判、无串流**。
- `uloop.process()` 回调**永不触发**（probe4），所以也没法用"等子进程退出"来消歧。

**方案：把 curl 的 stdout 经 `nc` 回环到本地 socket**

```
{ printf "<id>\n"; curl ... ; } | nc 127.0.0.1 8791 &
```

> **末尾的 ` &` 是桥的一部分，不是可选的性能优化。** v1.8.3 漏掉了它，上线即把服务打死：
> `popen()` 的直接子进程是那个 `sh`，而整条管道在**整个响应流期间**都活着，于是任何一次
> `proc.close()`（= `pclose()`/`waitpid()`）都要等管道退出才返回。ucode 是**单线程**事件循环，
> 一次 60 并发实测把它钉在 `do_wait` 上 40 s 没转过一轮 —— Recv-Q 固定堆积 87423 字节、
> `/health` 完全无响应、60 个请求里 56 个 `code=000`。这比它要修的静默截断严重得多
> （截断只损坏单个回答，死锁是**全站瘫痪**）。
>
> 加 ` &` 后 `sh` 立刻退出，`pclose()` 收的是已死子进程，实测 **2 ms** 返回；事件循环最大停顿
> 502 ms；数据仍逐字节完整送达。证据链：`probe15.uc` shape A（前台）**无限期挂住**、
> shape B（` &`）`closeMs=2 / got=200200 / FIX_OK`；`probe16.uc` 并发 A/B —— `BG=1` 三连跑
> `good=5/5`、`closeMsTotal` 6~9 ms（5 路合计）↔ `BG=0` 对照组 20 s 内直接 HUNG。

响应字节不再走 popen 管道，而是走 **socket**（probe10 已证明可靠）。请求 id 由首行握手与
`bridgePending` 映射配对，因此并发下不会串流。要点：

- **一条桥连接只注册一个 uloop 句柄**，握手与后续转发**共用**它。不要写成"握手用句柄 A，
  收到 id 后 cancel A、给同一 fd 注册句柄 B"—— 同一 fd 上取消+重新注册落在同一事件循环轮次里，
  epoll 侧会出现重复注册/陈旧句柄竞态（libubox 对同一 fd 的 `epoll_ctl(ADD)` 返回 EEXIST），
  严重时陈旧句柄会再触发一次握手，把真实数据的首行当成 id 吃掉。
- 首行 id **之后的同包残余字节**必须先塞进 `conn.bridgePrebuf` 再手动触发一次块处理，
  否则 curl 的响应头和 id 行挤在同一个报文里时会丢掉开头。
- `bridgeRegister()` 必须在 `popen()` **之前**调用，否则子进程可能在登记前就连上来。
- 每个释放路径（`closeConn` / `tryNextCred` / `tryNextUpKey` / `onUpstreamDirectEnd` /
  popen 失败）都要 `bridgeRelease(conn)`：**不释放就是连接泄漏**（探针实测会卡在 FIN_WAIT2）。
- 靠 **busybox `nc` 在 stdin EOF 时关闭 socket** 来判定响应结束（ucode 侧 `recv` 收到 len=0）；
  路由器 `nc` 是 BusyBox v1.38.0 极简版，**没有 `-l` / `-p`，只能作客户端**。
- **自动回退**：`nc` 不存在或监听失败时打日志并退回直接读 popen（`bridge_port=0` 也可显式关闭）。
  回退路径仍有截断缺陷，但至少不会因为缺少 `nc` 而完全不可用。
- 启动日志新增 `upstream bridge: on (port=8791)`。

**离线验证（`probe12.uc` + `emit9.sh`，与生产同构，5 并发，无网络）**

生产者 `emit9.sh` 用 awk 输出**恰好 200200 字节**（每 40 行 `sleep 1`，制造真实的流中停顿）。
判据：5 路各收满 200200 字节、`foreign=0`（无串流）、全部干净 EOF 收尾。

| 版本 | 结果 |
|---|---|
| 直接读 popen 管道（= 生产旧路径，`probe2.uc`） | 163840 假 EOF / 180224 停滞，**失败** |
| 回环桥，前台（`probe12.uc`，v1.8.3 形态） | 连跑 5 次全部 `good=5/5 bad=0`、每路恰好 200200 字节、`foreign=0` ⇒ `STABILITY_OK` |
| 回环桥，前台（**`probe16.uc` BG=0**，并发 A/B 对照组） | **HUNG —— 20 s 看门狗内事件循环被 `proc.close()` 钉死** |
| 回环桥 + 尾部 ` &`（**`probe16.uc` BG=1**，v1.8.4 形态） | **三连跑 `good=5/5 bad=0`、`closeMsTotal` 6~9 ms、`hung=0` ⇒ `STABILITY_OK`** |

> probe12 当初之所以通过、却在生产上炸掉，是因为它**每条请求只读满固定字节数就收尾**，
> 没有在生产那种"响应流长时间活着、期间还要走 `closeConn()`/`tryNextUpKey()`"的形态下
> 触发 `proc.close()`。probe15/probe16 把 `proc.close()` 放到**子进程必然还活着**的时刻
> 调用（`popen` 之后立刻计时），才暴露出这个真正的行为差异 —— **离线验证必须复现生产
> 的调用时序，而不只是数据量。**

> 探针本身的两个坑，也是生产代码的印证：一是 **ucode 没有全局 `error()`**，必须
> `import { ..., error } from 'fs'`（生产文件第 21 行正是这么写的）；二是**结束时必须显式
> 释放桥资源并 `exit(0)`**，否则客户端 `nc` 停在 FIN_WAIT2 死等、ucode 卡在退出阶段等子进程
> —— 探针第一版就是这样把测试 runner 整个挂住的，反过来证明了 `bridgeRelease()` 的必要性。

**上线验收（v1.8.4，12 批 × 5 = 60 并发，长输出 prompt，`curl -sS -N -m 90`）**

| 判据 | v1.8.3（桥缺 ` &`） | **v1.8.4** |
|---|---|---|
| 客户端状态码 | **56× `code=000`** / 4× `200` | **35× `200`** / 25× `429` / 0× `000` |
| 流式 body 完整（含 `[DONE]`） | 1 | **35 / 35** |
| `TRUNCATED (no [DONE])` | 3 | **0** |
| `size == 16384` 恰好 / 16384 整数倍 | 0 / 0 | **0 / 0** |
| `no finish_reason` | 3 | **0** |
| ucode 进程存活 | 事件循环钉死在 `do_wait`，`/health` 无响应 | **pid 1701 全程未变** |
| 客户端 TTFB p50 / p90 / p99 | （超时，无有效样本） | **1.14 / 2.57 / 5.18 s** |
| 流中看门狗中止次数 | — | **0** |
| 池放大倍数 / 复用率 | 0.07×（请求根本没到上游） | **1.45×** / `reuse_rate 0.93` |

- 25 个 `429` 全是 **171 字节的 JSON 错误体**（刹车拒绝，预期行为），与 25 个 `200` 一一对应；
  60 个请求里**没有一个 `code=000`**，`curl errors` 段为空。
- 流式 body 尺寸跨度 **9823 – 131280 字节**（`b.12.1` 131280 字节 / 483 chunk，
  `b.4.3` 113241 字节 / 414 chunk）⇒ 远超 16384 边界仍逐字节完整。
- 桥确实在承载流量（不是静默回退到 popen）：每批 3 s 采样的 `127.0.0.1:8791` 连接数为
  10 / 16 / 23 / 28 / 34 / 42 / 49 / 52 / 59 / 63 / 69 / 65，跟随批内并发单调变化。
- 资源无泄漏：ucode 共 **11 个 fd**（6×pipe / 2×socket / eventpoll / 脚本 / `/dev/null`）；
  空闲时 `:8791` 只剩内核侧 13 条 TIME_WAIT；孤儿 `nc`、`curl` 均为 0。
- 对比 v1.8.1 的 TTFB `2.25 / 31.82 / 34.03 s`：**每条请求都是 30 s 级的长尾被彻底消掉**。


## v2.0 重大升级（转发速度 + 转发能力）

v2.0 在 v1.8.4 的稳定性地基上做了**能力升级**，共 9 项，全部已通过
单元测试、静态检查、`ucode -c`、真机 60 并发 soak 验收：

### ① 会话粘性（session affinity）

同一客户端（按 API 密钥名；未鉴权时按来源 IP）在 **`up_sticky_sec`（默认 900s）**
窗口内始终命中同一把上游 Key，避免多轮对话在 4 把 Key 之间乱跳导致
上游的 prompt caching 完全失效 —— 同一把 Key 连续提问才能吃到缓存命中，
既省钱又省 TTFB。

- 实现：`usableUpKeys()` 把粘性 Key 提到最前；`markUpKeyOk()`/`markUpKeyFail()`
  写入 `upSticky`；窗口到期或该 Key 冷却后自然失效，重新按权重轮询。
- 关闭：`option up_sticky_sec '0'`。

### ② 每 Key 权重（weighted rotate）

管理页粘贴 Key 时支持 `key|权重` 格式（权重为 ≥1 的整数，默认 1）。
`sk-aaaa|3` 表示这把 Key 的被选中概率是普通 Key 的 3 倍（按权重取模轮询，
不是简单随机）。权重只影响**健康 Key 内部**的轮询分布；失效 Key 仍走冷却与跳过。
全部 Key 权重为 1 时退化为普通轮询，且不会把权重字段写进旧格式的
`upstreams.json`（保持旧文件兼容）。

### ③ 上游列表 TTL 缓存

`loadUpstreams()` 的结果带 **2 秒 TTL 缓存**（`UPSTREAM_CACHE_TTL=2`），
避免每个请求都重新读盘解析 `upstreams.json`。保存/编辑上游时显式失效缓存。

### ④ Token 用量统计

每次成功请求后从上游响应的 `usage` 字段提取 `prompt/completion/total`，
按 **上游 / 上游+Key / 客户端** 三个维度累计，并实时反映在：

- `/metrics` 顶层的 `usage` 段（含 `text` 缩写，如 `2.8k/4.0k/6.7k`）
- 每个 upstream / 每把 Key 的 `usage` 与 `usageText` 字段
- 管理页「服务器管理」卡片上的「用量」行，以及 Key 徽标的 tooltip

### ⑤ 通用端点透传（passthrough）

不再只支持 `/v1/chat/completions` 与 `/v1/models` —— **任意端点**
（`/v1/embeddings`、`/v1/responses`、`/v1/audio/transcriptions` 等）都会原样
透传给对应上游：`/v1/embeddings` 交给上游的 `/v1/embeddings`，
未知前缀返回 400 `unknown upstream prefix: <prefix>`。

- 自定义上游：请求路径拼在 baseUrl 之后（Go 连接池 `joinPath` 已支持任意端点）。
- WorkBuddy 内置通道：`workbuddy/` 前缀走凭据池，池空时返回 502
  `WorkBuddy credentials unavailable`。
- 鉴权、刹车、静默看门狗、回环桥等既有能力对透传请求同样生效。

### ⑥ SSRF 防护：`allow_private_upstream`

默认 **允许**自定义上游指向内网/本机地址（`allow_private_upstream '1'`）。
设为 `'0'` 后，`baseUrl` 不能是 `localhost`、`127.*`、`10.*`、`192.168.*`、
`172.16-31.*`、`::1`、`fc00::/7`、`fe80::/10`，防止把中转当跳板打内网。
本机自己的凭据池通道（`workbuddy/` 前缀）不受此限制。

### ⑦ `X-Accel-Buffering: no`

流式响应头新增 `X-Accel-Buffering: no`，避免中间层（nginx、LuCI 的
proxy 插件等）缓冲 SSE 流导致首字节延迟。

### ⑧ 管理页展示权重与用量

- 服务器卡片上，权重 >1 的 Key 显示 `×N` 徽标，tooltip 显示
  「权重 N，用量 x/y/z tokens」。
- 卡片新增「用量」行，展示该上游累计的 prompt/completion/total。
- 「改 Key」弹窗明确说明 `key|权重` 格式。

### ⑨ UCI 新增配置项

```uci
# 会话粘性时长（秒），0=关闭粘性
option up_sticky_sec '900'
# 是否允许自定义上游指向内网/本机地址（SSRF 防护）
option allow_private_upstream '1'
```

### v2.0 验收记录（真机 soak，12 批 × 5 = 60 并发，长回复流式）

| 判据 | 结果 |
|---|---|
| 客户端状态码 | **24× `200`** / 36× `429` / 0× `000` |
| 流式 body 完整（含 `[DONE]`） | **24 / 24** |
| `TRUNCATED (no [DONE])` | **0** |
| `size == 16384` 恰好 / 16384 整数倍 | **0 / 0** |
| `no finish_reason` | **0** |
| ucode 进程存活 | **pid 14774 全程未变** |
| 客户端 TTFB p50 / p90 / p99 / max | **0.23 / 1.84 / 4.07 / 4.07 s** |
| ≥20s 请求 | **0** |
| 池复用率 | **0.945** |
| 桥连接采样（每批 3s） | 9 → 86，随批内并发单调变化 |

- 36 个 `429` 全是上游限流（rpm exhausted / tpm 超限）被刹车正确拦截的
  JSON 错误体，与配额波动一致，没有 `code=000`。
- 用量统计在 soak 后准确累计：`usage {prompt:2763, completion:3969,
  total:6732}`，且按 3 把实际命中的 Key 正确拆分（`byKey`）。

## v2.0.1 轻量化精简（无用代码清理 + 公共逻辑抽取）

v2.0 上线后做了一次深度审计与精简，**只删冗余、不改行为**。审计手段：
调用图 BFS（从 `main()` 出发找不可达函数）+ 注释引用交叉核对 + 静态六项
脚本与单元测试全程护航；每批改动都复跑 `.check-forward.ps1` 与
`run-ucunit.ps1`，最后在真机重跑完整验收。

### 删除的死代码

- `b64Index()` —— 旧 base64 实现遗留。实际查表早已内联，该函数无任何调用点。
- `authorized()` —— `matchApiKey` 的薄包装，全仓库无调用点。
- `q()` 与 `shquote()` 重复定义 —— 两个函数**完全同体**
  （`"'" + replace('' + s, "'", "'\\''") + "'"`），只因 ucode 函数不提升，
  早期在调用点附近复制了一份。统一保留一份 `shquote`，并前移到所有调用点
  之前（踩坑记录 #12：ucode 函数不提升）。
- 常量 `LOG_TAG`（`logMsg` 里硬编码 `'[workbuddy]'`）与 `UP_COOL_SEC`
  （无任何引用）。

### 抽取的公共逻辑（消除重复）

- `beginAttempt(conn)` —— 每次转发尝试的复位块
  （`sseBuf`/`headersSent`/`firstByteAt`/`attemptBytes`/`attemptAt`/
  `usedPool`/模式计数），`spawnUpstream` 与 `spawnUpstreamDirect` 共用。
- `curlArgs(conn, o)` —— 两份几乎相同的 curl 参数表
  （超时档位、鉴权、Accept、UA、目标路径）收敛为一份。
- `makeOnChunk(conn, onFail, onEnd)` —— 两条转发链里完全相同的
  `onChunk` 闭包。
- `releaseAttempt(conn)` —— 三条重试/收尾路径里相同的 `proc` 清理
  （`cancel()` + `close()` + 置空 + `bridgeRelease`）。

### 结果与验收

| 指标 | 精简前（v2.0.0） | 精简后（v2.0.1） |
|---|---|---|
| 行数 | 6694 | **6608（−86）** |
| 字节 | 259707 | **257270（−2437，−0.9%）** |
| 顶层函数 | 213 | **213**（删 4 个死函数 + 1 个重复定义，加 4 个辅助函数） |
| git diff | — | **+102 / −188** |

- 静态六项检查：全部 OK。
- 单元测试：`==== ALL PASS ==== / UNIT_RC=0`（90+ 断言）。
- `ucode -c`：RC=0（语法通过）。
- 真机 soak（12 批 × 5 = 60 并发，长回复流式，`v2.0.1`）：

| 判据 | 结果 |
|---|---|
| 客户端状态码 | **19× `200`** / 41× `429` / 0× `000` |
| 流式 body 完整（含 `[DONE]`） | **19 / 19** |
| `TRUNCATED` / `size==16384` / 16384 整数倍 / `no finish_reason` | **0 / 0 / 0 / 0** |
| ucode 进程存活 | **pid 18280 全程未变** |
| 客户端 TTFB p50 / p90 / p99 / max | **0.19 / 1.99 / 2.89 / 2.89 s** |
| ≥20s 请求 | **0** |
| 池复用率 | **0.959** |
| 桥连接采样（每批 3s） | 27 → 80，随批内并发单调变化 |

- 41 个 `429` 全是上游限流（rpm exhausted / tpm 超限）被刹车正确拦截。
- `/metrics` 用量统计在 soak 后正常累计（`byKey` 按实际命中的 3 把 Key 拆分）。
- 透传链路复测：`POST /v1/embeddings` 透传到 sensenova 上游并原样返回
  上游错误（`NOT_FOUND`），转发链正常。


## v2.1.0 可观测性与健壮性补强（10 项）

v2.1.0 在 v2.0.1 精简版的基础上做了一轮可观测性与健壮性补强，
每项改动都经过静态六项 + 单元测试 + `ucode -c`，并部署到真机
完成 smoke / 并发 soak 验收。完整版本信息：

| 项目 | 值 |
|---|---|
| APP_VERSION | `2.1.0` |
| 文件 | `files/usr/share/ucode/workbuddy.uc` |
| 字节 | 268465 |
| MD5 | `5e95db867349d74e2da70b29f75537f8` |

### ① 上游状态码捕获（`curl -D`）

两条转发通道（池化 / 自定义上游）的 `curlArgs` 统一追加 `-D <每连接唯一
响应头文件>`（`conn.hdrFile`）。失败路径（`tryNextCred` /
`tryNextUpKey` / `onUpstreamEnd` / `onUpstreamDirectEnd`）通过
`readUpstreamStatus(conn)` 读取该文件，拿到**真实的上游 HTTP 状态码**与
`Retry-After` 响应头。池化路径同样生效（Go 池原样透传上游状态码与响应头）。

### ② Retry-After 解析

`readUpstreamStatus` 解析响应头文件中的 `Retry-After`（秒）。失败分类时：
限流类失败且 `Retry-After > 0` 时，冷却时长取
`max(基础冷却, min(Retry-After, MAX_RETRY_AFTER=300))`，不再盲目按固定值
冷却；`markCredFail` 同样支持（仅当 `Retry-After > 60` 才覆盖其基础冷却）。

### ③ 请求级关联 ID（`X-Request-Id`）

`handleChat` / `handlePassthrough` 为每个连接生成 `conn.reqId`
（12 位十六进制，熵源 `readRandom`）。上游请求追加 `X-Request-Id` 头，
响应头（`jsonResponse` / `rawResponse` / `sseHeaders`）回带同一个
`X-Request-Id`，客户端可用它关联日志与上游链路。

### ④ 截断检测 + 补发 `event:error`

流式累积时跟踪 `[DONE]`（`conn.sawDone`）。`notifyTruncation(conn)` 在满足
「已发响应头且未发送 `[DONE]`」时补发 `event: error` 数据帧并计入
`metrics.truncated`，然后关闭连接。触发点覆盖：`watchdogTick` 的
`headersSent` 分支、`tryNextCred` / `tryNextUpKey` 的 `headersSent` 分支、
`makeOnChunk` 的 `safeSend` 失败路径与读失败路径。正常结束不主动补发
（`[DONE]` 并非所有上游都保证返回）。

### ⑤ 退避加抖动（gRPC ±20% 口径）

`jitterFactor()` 用 `readRandom` 读 1 字节映射到 `[0.8, 1.2)`，
冷却时长 `cool = int(cool × jitter)` 且至少 1 秒。避免多把 Key 同时
冷却结束时一起重试造成"同步 thundering herd"。

### ⑥ 失败分类：429 不参与指数退避

`markUpKeyFail` / `markCredFail` 现在按失败原因分类：
限流类失败只累加 `probs`（观察用，/upstreams、/credentials、/metrics
均展示），**不累加 `fails`、不参与指数退避**，冷却固定为
`UP_RATE_COOL=5s`（或采信 `Retry-After`）；认证类失败冷却 60s 且
`fails++`；其他软失败 2s 且 `fails++` 指数退避（×2，上限 20s）。
这修复了原实现中"429 误伤最健康 Key"的问题（429 一多，健康 Key
反而被退避到最久）。

### ⑦ HTTP/1.1 连接复用 bug 修复

原 `onData` 中 `conn.handle` 从不取消，同一 HTTP/1.1 连接上的第二个请求
会在首个 SSE 流仍在飞行时**重入 `dispatch`**，覆盖 `conn.proc` /
`sseBuf` / `upKeys`，使首个上游变孤儿。现在 `dispatch` 后立即取消读句柄
并置 `null`（本服务响应一律 `Connection: close`，一条连接只服务一个请求），
`closeConn` 仍安全（再次 `cancel` 被 `if (conn.handle)` 挡住）。

### ⑧ send() 背压检查（`safeSend`）

封装 `conn.sock.send()`：返回写入字节数小于 `length(data)` 或抛异常时
计入 `metrics.sendFail` 并返回 `false`。替换全部 6 处裸 `send`（`sseHeaders`
/ `makeOnChunk` / `jsonResponse` / `rawResponse` / `onUpstreamDirectEnd`
两处）。写侧失败路径统一置 `conn.aborted = true` 并 `closeConn`，不再静默
丢数据。

### ⑨ 缓冲护栏（sseBuf / 请求体 413）

非流式累积与首块错误嗅探路径的 `conn.sseBuf += chunk` 补上
`MAX_SSE_BUF = 2MiB` 上限（此前仅流式路径有）；超限只记录不再增长。
入站请求体新增 `MAX_BODY_BYTES = 8MiB` 上限：`Content-Length` 超限直接
返回 `HTTP 413 {"error":{"message":"request body too large (>8MiB)"}}`，
不再等待读满。

### ⑩ abort 桶

`onData` 检测到客户端断开（`recv` 异常 / null / 空）时置
`conn.aborted = true`；`recordConnMetrics` 开头在
`conn.aborted && conn.headersSent` 时计入 `metrics.chatAborted++`、
`chatTotal++`、`histAdd total` 后直接返回（**不进 ok/fail**）。`/metrics`
的 `chat` 快照新增 `aborted` / `truncated` / `sendFail` 三个字段。

### 验收记录（真机，2026-10，`v2.1.0`）

| 判据 | 结果 |
|---|---|
| 静态六项检查 | 全部 OK（顶层函数 218） |
| 单元测试 | `==== ALL PASS ==== / UNIT_RC=0` |
| `ucode -c` | RC=0 |
| 非流式 smoke | `200`，正常返回 |
| 流式 smoke | 45372 字节，含 `[DONE]`，`X-Request-Id` 回带 |
| 并发 soak（10 并发 × 2 轮） | 全部 200 含 `[DONE]`，`truncated=0` |
| 上游 429 分类 | 正确识别 `rate_limit_error`，`retry_after=8` 透传 |
| `/metrics` | `aborted=0 / truncated=0 / sendFail=0`，per-key `probs` 展示 |
| 9MB 请求体 | `HTTP 413` 正确返回 |

## 接入第三方客户端

把「API 地址」填成 `http://<路由器IP或公网IP>:8789/v1`，密钥填上面生成的
**API 密钥**（若尚未生成密钥则随便填）。模型名填 `/v1/models` 返回的任一 `id`。

## 故障排查

```sh
# 服务状态
/etc/init.d/workbuddy status
netstat -ltn | grep 8789
curl -s http://127.0.0.1:8789/health

# 日志
logread | grep workbuddy
```

常见问题：

- **端口没监听**：`uci get workbuddy.main.enabled` 是否为 `1`；看 `logread` 是否有 ucode 报错。
- **`/models` 报错但 `/health` 正常**：多半是没登录，访问 `/login` 完成授权。
- **LuCI 里看不到菜单**：`/etc/init.d/rpcd restart` 并强制刷新浏览器缓存（Ctrl+F5）。
- **调用返回 502**：上游不可达，检查路由器能否解析并访问 `www.workbuddy.ai`。

## ucode 实现注意事项

本实现踩过并已规避的 ucode 与 JavaScript 的差异（改动代码时请留意）：

- **函数声明不提升**：被引用的函数必须先定义，否则运行时报
  `access to undeclared variable`。文件内函数顺序按依赖排列。
- **顶层 `let` / `const` 同样不提升**：函数编译时按**当时**的词法作用域解析标识符，
  所以被函数引用的模块级变量必须声明在该函数**之前**。本实现中
  `modelCache` 必须早于 `freeModelIds()`，`F`（前向引用表）必须早于
  `spawnUpstream()`。踩坑表现：`access to undeclared variable modelCache`。
- **没有 `String()` / `typeof` / `undefined`**：用 `'' + x` 转换、`type(x)` 判断类型、
  与 `null` 比较。**特别注意**：`obj.field !== undefined` 会直接抛
  `Reference error: access to undeclared variable undefined`，
  判断字段是否存在要用 `type(obj.field) === 'int' || type(obj.field) === 'string'`。
- **字符串函数是全局的**：`lc()`、`uc()`、`trim()`、`length()`、`substr()`、`replace()`、
  `match()`、`split()`、`join()`、`sprintf()`。
- **正则不支持 `(?:...)`**：非捕获组会报 `Repetition not preceded by valid expression`，
  改用普通捕获组。（`\s` / `\S` 可用，但 `\d` 不可用，请写 `[0-9]`。）
- **`popen()` 只接受字符串命令**：数组形式返回 `null`（"Invalid argument"）。
  因此所有外部数据必须经 `shquote()` 转义后拼入命令行。
- **`uloop.handle()` 需带 `ULOOP_BLOCKING`**：否则 fd 被置为非阻塞，
  `read()` / `recv()` 会因 EAGAIN 返回 `null`，被误判为 EOF。
- **没有 `log.info()`**：log 模块只提供 `syslog(level, fmt, ...)`，
  本实现直接输出到 stdout 交由 procd 转发。
- **没有 `getpid()`**：用 `time()` 配合 `clock()[1]` 生成唯一临时文件名。
- **没有目录遍历**：`opendir` / `readdir` / `closedir` 都不可用，
  所以多凭据池必须集中存放在单个 `pool.json` 里，而不是一个凭据一个文件。
- **没有 `decodeURIComponent`**：需自行实现百分号解码（见 `urlDecode()`）。
- **`sort()` 是原地排序**（返回原数组）。
- **对象字面量的数字键要加引号**：`{'200': 'OK'}`，否则语法错误。
- **rpcd 的 ucode 插件必须放在 `/usr/share/rpcd/ucode/`**：`/usr/libexec/rpcd/` 是
  shell 插件目录（用 `$1 = list|call` 参数约定），放错位置 rpcd 不会注册 ubus 对象。
- **rpcd 布尔参数会以字符串传入**：即使声明为 `bool`，`ubus -v list` 显示的仍是
  `String` 类型，且传 JSON 布尔值会被 ubus 以 `Invalid argument` 拒绝。
  LuCI 侧必须传 `'true'` / `'false'` 字符串，服务端用 `truthy()` 归一化。
- **不能从 rpcd 方法里调用 ubus**：rpcd 是单线程的，`ubus call ...` 会等待 rpcd
  自己处理，形成自等待死锁。调用方看到的是
  `Command failed: ubus call <obj> <method> (Unknown error)`，且没有任何日志。
  判断服务是否运行请改用 `ps` / pid 文件。
- **uci 的 `get_all()` 会带出元数据键**：`.anonymous` / `.type` / `.name` / `.index`
  都以点号开头。把它们原样放进 rpcd 的返回对象会让 ubus 序列化失败
  （同样表现为 `(Unknown error)`）。必须过滤掉点号开头的键。
- **`digest()` 不是全局函数**：必须 `require('digest')`，然后 `d.sha256(s)`；
  直接调用全局 `digest()` 会报 `left-hand side is not a function`。
- **`open()` / `writefile()` 不可靠地作为全局存在**：统一走 `require('fs')`，
  例如 `fs.open()` / `fs.writefile()` / `fs.dirname()` / `fs.rename()`。
- **字符串没有方法**：`s.replace()` / `s.match()` 会在运行时报
  `left-hand side expression is not an array or object`。
  但**全局函数** `replace(s, a, b)` 和 `match(s, re)` 是可用的。
- **没有 `undefined` 标识符**：写 `x !== undefined` 会抛
  `access to undeclared variable undefined`。判断键是否存在用 `'key' in obj`。
- **没有 `has()` 函数**：`has(obj, 'k')` 会报 `left-hand side is not a function`。
- **数组没有 `.push()` 方法**：`arr.push(x)` 会报 `left-hand side is not a function`。
  必须用全局函数 `push(arr, x)`。这个错误只在被调到的那一行才抛出，
  所以同一个文件里其它 `push()` 调用都正常时，很难注意到漏了一处。
- **`split()` 的参数顺序与 JS 相反**：ucode 是 `split(subject, separator)`，
  等价于 JS 的 `subject.split(separator)`。写成 `split('\n', text)`
  会按**字面字符 `n`** 切分并返回单元素数组（因为 text 里没有字母 n 时
  整串就是一段）。症状极具迷惑性：接口不报错，但"粘贴了一堆 Key
  却提示至少需要一条"。本实现曾因此在自定义上游的 Key 解析上栽过一次。
- **`delete obj[key]` 不可用**：会报
  `Reference error: left-hand side expression is not an object`。
  删除键要重建表（遍历时跳过目标键），数组中删元素用 `splice()`。
- **`match()` 只接受正则字面量**：`match(s, '/.../')`（字符串形式的模式）
  即使能匹配也返回 `null`。必须写成 `match(s, /.../)`。
  不做正则匹配时优先用 `index(s, sub)` + `substr()`，语义更直观。
- **`for (let x in array)` 取的是元素本身**（不是下标），
  这点与 JS 的 `for...in` 不同；对对象则遍历键。
- **函数重名会静默覆盖**：ucode 允许同名函数重复定义，只有最后一个生效，
  且不报错。管理页的 JS 函数与后端 ucode 函数同名时尤其容易踩到，
  建议 UI 侧函数统一加 `UI` 后缀（如 `addUpstreamUI`）。
- **多行输入不要用 `prompt()`**：浏览器原生 `prompt()` 是**单行**输入框，
  粘贴多行内容会被压成一行（换行丢失）。凡是"批量粘贴"场景
  （Key 列表、订阅链接等）都要用页面内 `<textarea>` 弹层。
  本实现的 `editUpKeys()` 就是为此从 `prompt()` 改成了弹层 `openModal()`。
- **产品改名时把名字提成常量**：界面上出现十几处的产品名若硬编码，
  改一次要动十几处且容易漏。本实现统一走 `const APP_NAME = 'AI 中转服务器'`，
  同时把**内部标识符**（UCI 节名、服务名、模块名、路由路径）与**显示名**
  彻底分开 —— 改显示名不影响任何已有配置与运行中的数据。
- **模板字符串里写 `onclick` 必须用 `\\'`（双反斜杠）** ← 本项目最凶险的坑。

  管理页整体是一个 ucode 反引号模板字符串，里面嵌了生成 HTML 的 JS。要在
  JS 字符串里输出 `\'`，源码必须写 **`\\'`**。实测四种写法的渲染结果：

  | 模板字符串里写的 | 实际渲染出 |
  | --- | --- |
  | `'a'` | `'a'` ✅ |
  | `\'a\'` | `'a'` ❌ 反斜杠被吃掉 |
  | `\\'a\\'` | `\'a\'` ✅ 正确 |
  | `\\\'a\\\'` | `\'a\'` ✅（多余反斜杠被合并） |

  踩坑表现：`onclick="testUp(\'' + esc(id) + '\')"` 渲染成
  `onclick="testUp('' + esc(id) + '')"` —— 引号被吃成两个连续单引号，
  浏览器解析整段 `<script>` 时抛 `SyntaxError`，**整个管理页的 JS 全部不执行**。

  症状是**页面能打开但永远停在「加载中…」**，因为 `load()` 根本没跑起来，
  而服务端一切正常（`/admin/api/state` 返回 200）。排查时容易误判成后端问题。

  验证方法：抓渲染后的 JS，`grep "('' + esc"` 应为 0 条。
  静态检查脚本 `.check-forward.ps1` 已加入该项检测（`TEMPLATE ESCAPE CHECK`）。

  > **修复记录（v1.5.1）**：这个 bug 在本项目里**一直存在**，不只是新增代码
  > 引入的 —— 密钥列表、凭据池的按钮全都中招，整段管理页 JS 因此从未真正
  > 跑起来过。表现就是页面能打开、标题正常，但所有面板永远停在「加载中…」。
  > 服务端 `/admin/api/state` 一直是好的，所以很容易误判成后端故障。
  > 本次把 13 处 `\'` 全部修正为 `\\'`，并加了静态检测防复发。

- **`.ps1` 脚本必须带 UTF-8 BOM**：不带 BOM 时 Windows PowerShell 会按本地
  代码页解析，中文字符串被误读并**污染后续代码的语法解析** —— 表现为
  脚本里明明正确的表达式抛「不能对 Null 值表达式调用方法」这类莫名错误。
  本次 `.check-forward.ps1` 加上 BOM 后才恢复正常。
- **没有 `undefined` 这个标识符**（**v1.8.0 首次部署就是被它搞挂的**）：
  ucode 里 `undefined` 既不是关键字也不是全局变量，写 `v === undefined` 会在运行期抛
  `Reference error: access to undeclared variable undefined` —— **进程直接起不来、端口完全不监听**，
  报错栈指向 `numOr()` / `loadConfig()`。判断字段是否存在要用 `type(v) === 'bool'`、`v === null`。
  最阴的地方是它**看编译单元而定**：把出问题的那段原样抠进独立小文件里跑**不报错**，
  `ucode -c` 编译期也**不报错**，**46 项单元测试全过照样抓不到**。
  所以只能靠静态扫描（`.check-forward.ps1` 的 `UNDEFINED IDENTIFIER CHECK`）+ 纪律来防。
- **字符串没有 `.indexOf()` / `.includes()`**：用全局 `match(s, /re/)`
  或 `index(s, sub)`。`.indexOf()` 与 `.push()` 报的是同一个错误信息
  （`left-hand side is not a function`），排查时要看行号而不是错误文本。
- **没有 `rand()` / `getpid()`**：生成密钥的熵来自
  `time()` + 进程内自增计数 + `/dev/urandom`，再经 sha256 混合。
- **没有 base64 模块，也没有全局 `b64dec` / `b64enc`**：
  `require('base64')` 报 `No module named 'base64' could be found`。
  本实现自带 `b64UrlDecode()`（纯 ucode 位运算，约 20 行），
  用于解析 JWT；只需解码，不需编码。
- **`popen` 不是全局函数**：`popen(...)` 报 `left-hand side is not a function`；
  要走 `require('fs').popen`。但解析 JWT 用自实现的解码器更划算，不必开子进程。

### 静态检查脚本

`.check-forward.ps1` 覆盖六类只在运行期暴露、且难靠语法检查发现的问题：

| 检查 | 拦住的错误 |
| --- | --- |
| `FORWARD REF CHECK` 前向引用 | `access to undeclared variable <name>`（ucode 不提升函数与顶层 `let`/`const`） |
| 重复定义 | 后定义的函数静默覆盖前一个 |
| `METHOD CALL CHECK` 不存在的内建方法 | `.push()` / `.replace()` / `.indexOf()` / `.has()` 等 → `left-hand side is not a function` |
| `TEMPLATE ESCAPE CHECK` 模板转义 | 模板字符串里 `onclick` 引号转义不足 → 管理页永远停在「加载中…」 |
| `UNSUPPORTED SYNTAX CHECK` 不支持的语法 | `finally`（ucode 只有 `try/catch`）→ `Syntax error: Expecting 'catch'` |
| `UNDEFINED IDENTIFIER CHECK` 裸用 `undefined` | `access to undeclared variable undefined` → **服务起不来**（v1.8.0 首次部署的崩溃根因） |
| `GLOBAL DECLARATION ORDER CHECK` 全局声明顺序 | 函数引用「比它的定义行更靠后」才声明的顶层 `let`/`const` → `Reference error: access to undeclared variable cfg`，**服务陷入崩溃-重启循环**（v1.8.1 首次部署的崩溃根因） |

```powershell
pwsh -File .check-forward.ps1
# 输出六项都 OK 才算通过
```

> `UNDEFINED IDENTIFIER CHECK` 会跳过注释与模板字符串（浏览器 JS 里 `undefined` 合法），
> 也跳过字符串字面量。加规则时务必做一次**负向测试**：故意注入一处违规，
> 确认它恰好报 1 处、且不误报字符串与注释 —— 从不报警的检查等于没有检查。

> 该脚本会跳过模板字符串区间，因为反引号里的 JS 是给浏览器执行的，
> 那里的 `.push()` / `.replace()` 都是合法的。

### 调试这类问题的有效手段

`ucode -c -o /dev/null <file>` 只做语法检查，**查不出**上述词法作用域问题。
真正的验证必须触发实际代码路径，然后看运行时错误：

```sh
logread | grep workbuddy          # 运行时报错会带文件、行号、调用栈
curl -s http://127.0.0.1:8789/health
```

本实现有两处刻意的写法：

1. **前向引用表**：`spawnUpstream → tryNextCred → onUpstreamEnd` 三者互相调用，
   无法用重排顺序解决，因此引入 `let F = {}`（声明在所有函数之前），
   彼此通过 `F.xxx()` 调用。
2. **基础工具集中在文件顶部**：ucode 对函数和顶层 `let`/`const` 都不做提升，
   `sha256Hex` / `secureEq` / `truthy` / `writeJsonFile` / `readJsonFile` /
   `genApiKey` 等被广泛复用的底层函数一律放在文件最前面的
   「基础工具函数」区，避免"定义在使用之后"。
3. **配置对象 `cfg` 与连接表 `connections` 提前声明**：函数按**定义时**的词法作用域
   解析标识符，所以一个位于文件中部、却引用 `cfg.xxx` 的函数，要求 `cfg` 在那之前
   就已声明。`let cfg = {};` 因此被提到全局声明区，读盘赋值留在启动流程里
   （`cfg = loadConfig();`，纯赋值）。v1.8.1 首次上线正是漏了这一步：
   `ucode -c` 通过、单元测试也通过，只有真机上撞到限流、走进 `brakeNoteRateLimit()`
   才抛 `Reference error: access to undeclared variable cfg`，服务被打成崩溃-重启循环。
   规则：**新增任何引用 `cfg` 的函数后，都要跑一次 `GLOBAL DECLARATION ORDER CHECK`**。

仓库里附带两个自检脚本：

```powershell
pwsh -File .check-forward.ps1        # 静态检查，输出六项 OK 才算通过
```

```sh
# 在路由器上跑凭据池功能回归测试（36 项断言）
export WB_ADMIN_PW='你的管理员密码'
sh /root/luci-app-workbuddy/pool-test.sh

# 服务器与上游功能回归测试（17 项断言，含真实上游对话与 Key 轮询）
sh /root/luci-app-workbuddy/upstream-test.sh

# 服务器增删改查回归测试（11 项断言，含批量 Key 与去重）
sh /root/luci-app-workbuddy/server-test.sh

# 公网访问开关回归测试（30 项断言，含真实防火墙规则建/删、自定义外部端口与安全护栏）
sh /root/luci-app-workbuddy/wan-test.sh
```

四套合计 **94 项断言**。当前实测结果：`36 / 17 / 11 / 30` 全部通过。

这六项**每次改动 `workbuddy.uc` 后都要跑一遍**，动过管理页 HTML 或闸门/池相关
代码之后尤其不能省。但它只扫静态模式，不能替代真机验证 —— 完整门禁是三步：

```sh
pwsh -File .check-forward.ps1              # 1. 静态检查（本地，六项 OK）
ucode -c -o /tmp/probe.bin workbuddy.uc    # 2. ucode 语法/编译检查（真机）
/etc/init.d/workbuddy restart && logread | grep workbuddy   # 3. 真机启动 + 看日志
```

> 第 2 步只能查语法，**查不出**前向引用、裸用 `undefined` 这类运行期问题；
> 而第 3 步才是唯一的最终裁判 —— v1.8.0 首次部署正是在这一步崩掉的
> （前两步都过了）。

> `upstream-test.sh` 会真的往各服务器发请求，因此可能触发对方的限流
> （日日新有 RPM 限制）。测试脚本开头有 60 秒等待，用于让上一轮冷却结束。
> `server-test.sh` 只用示例地址 `example.com`，不产生真实请求。

## 目录结构

```
luci-app-workbuddy/
├── Makefile                                  OpenWrt 包定义
├── install.sh                                设备端直接部署脚本
├── README.md
├── .check-forward.ps1                         ucode 静态检查（六项，详见上文）
├── pool-test.sh                               凭据池功能回归测试（36 项）
├── .upstream-test.sh                          服务器/上游功能回归测试（17 项）
├── .server-test.sh                            服务器增删改查回归测试（11 项）
├── .wan-test.sh                               公网访问开关回归测试（30 项）
├── pool/                                      上游连接复用代理（Go，v1.8.0）
│   ├── go.mod                                 Go 模块定义（零外部依赖）
│   ├── main.go                                连接池代理，约 500 行（中文注释）
│   └── testsse/main.go                        本地回调用最小 SSE 上游（不参与打包）
└── files/
    ├── etc/
    │   ├── config/workbuddy                   UCI 默认配置
    │   ├── init.d/workbuddy                   procd 服务（先拉池，再拉主服务）
    │   ├── sysctl.d/99-workbuddy-forward.conf 内核转发参数
    │   └── uci-defaults/50-workbuddy          首次安装初始化
    ├── usr/
    │   ├── bin/workbuddy-pool                 上游连接复用代理（aarch64 静态二进制，6.3 MB）
    │   └── share/
    │       ├── ucode/workbuddy.uc             核心中转 + 管理网页（约 210 KB）
    │       ├── rpcd/ucode/workbuddy           rpcd 后端（状态/密码/凭据/模型）
    │       ├── luci/menu.d/luci-app-workbuddy.json
    │       └── rpcd/acl.d/luci-app-workbuddy.json
    └── www/luci-static/resources/view/workbuddy/
        └── status.js                          运行状态页（只读 + 管理员密码）
```

> `files/usr/bin/workbuddy-pool` 是**预编译的 aarch64 二进制**（本机无 Go、
> 路由器也不能编译），改动 `pool/main.go` 后必须重新交叉编译再提交：

```powershell
cd D:\AI\luci-app-workbuddy\pool          # 必须在模块目录内，用 . 作包路径
$env:GOOS='linux'; $env:GOARCH='arm64'; $env:CGO_ENABLED='0'; $env:GOTOOLCHAIN='local'
& 'D:\AI\_tools\go-sdk\go\bin\go.exe' build -trimpath -ldflags '-s -w' -o ..\files\usr\bin\workbuddy-pool .
```

> 两个坑：① 在模块目录**外面**用 `go build <绝对路径>` 会报
> `cannot find main module, but found .git/config`；② 该二进制与 `Makefile` 里
> `LUCI_PKGARCH:=all` 的「架构无关」声明相矛盾 —— 打包时需按目标架构处理。

> 文件名与 rpcd 对象名均保留 `workbuddy` 前缀，理由见文首「命名说明」。

> 管理网页的 HTML/CSS/JS 全部内联在 `workbuddy.uc` 里，
> 因为面板要在无外网的局域网可用，不能依赖任何 CDN 或独立的静态资源。

## 许可

Apache-2.0
