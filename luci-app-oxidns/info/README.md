# OxiDNS DNS 配置与 WebUI 操作指引

语言：中文 | [English](./README.en.md)

本文面向已经安装 `luci-app-oxidns` 和 OxiDNS 内核的用户，说明如何通过 LuCI 的 `DNS配置` 页面配置 DNS，如何通过 `基本信息` 页面一键启用 dnsmasq 转发，以及如何进入 OxiDNS WebUI 完成同样的工作。

文中以 OpenWrt 默认安装路径为准：

| 项目 | 默认值 |
| --- | --- |
| 配置文件 | `/etc/oxidns/config.yaml` |
| 内核二进制 | `/usr/bin/oxidns` |
| WebUI 静态目录 | `/usr/share/oxidns/webui` |
| 工作目录 | `/var/lib/oxidns` |
| 日志文件 | `/tmp/oxidns/oxidns.log` |
| DNS 监听端口 | `5335`（UDP/TCP） |
| 管理 API / WebUI 端口 | `9199` |

---

## 一、先理解 OxiDNS 的工作方式

OxiDNS 用插件组合出完整的 DNS 处理流程：

1. **Server 插件**接收 DNS 请求，例如 `udp_server`、`tcp_server`、`quic_server`、`http_server`。
2. Server 的 `entry` 指向一个 **sequence**（处理序列）。
3. Sequence 按顺序执行规则：matcher 判断条件，executor 执行动作，例如查询缓存、转发上游、返回固定地址。
4. 处理结果返回给客户端。

最小可用配置通常包含：

- 一个 `forward` 插件和至少一个上游 DNS；
- 一个 `sequence`，把请求交给 `forward`；
- 一个或多个 server 插件监听端口。

LuCI 的 `DNS配置` 页面和 OxiDNS WebUI 修改的是**同一份** `/etc/oxidns/config.yaml`，只是操作方式不同：

- `普通模式`：表单方式，适合日常修改日志、运行时、包含文件、API、监听地址、上游和常用插件参数。
- `高级模式`：完整 YAML 编辑器，适合修改任意字段、插件组合、sequence 规则和 `network` 等顶层配置。
- `OxiDNS WebUI`：图形化管理插件、sequence、查询记录、缓存等，并可以查看仪表盘和运行日志。

### 开始前的检查

1. 在 `服务 -> OxiDNS -> 基本信息` 的 `状态概览` 确认内核状态为“已安装”。
2. 确认服务状态为“运行中”；未运行时先点击 `启动`。
3. 在 `DNS配置` 页面先点击 `下载配置` 备份当前 `config.yaml`。
4. 规划好监听地址：只给本机或 dnsmasq 使用时监听 `127.0.0.1:5335`；要让局域网直接访问时监听路由器 LAN 地址或 `0.0.0.0:5335`。
5. 不要把 53、5335 或 9199 端口暴露到 WAN。

如果内核尚未安装，请先在 `安装部署 -> 内核操作` 中点击 `安装内核`，或使用 `上传内核` 离线安装。

---

## 二、DNS 配置页面基础操作

进入方式：`服务 -> OxiDNS -> DNS配置`。

页面顶部有两个模式按钮：

- `高级模式`：默认模式。完整 YAML 编辑器。
- `普通模式`：表单方式。只有 YAML 能正常解析成顶层映射（键值对象）时可用。

两个模式共用底部同一组按钮：

| 按钮 | 作用 |
| --- | --- |
| `校验` | 把当前编辑结果交给后端执行 `oxidns check` 校验，不写文件。 |
| `下载配置` | 下载当前磁盘上的 `config.yaml`，用于备份。 |
| `上传配置` | 选择本机的 `config.yaml` 覆盖当前配置。文件名必须是 `config.yaml`；上传前会校验并保存，不会自动重启。 |
| `保存并应用` | 校验通过后写入配置文件；如果内容有变化，同时重启 OxiDNS 使配置生效。 |
| `保存` | 校验通过后只写入配置文件，不重启服务。 |
| `复位` | 放弃当前页面上尚未保存的修改，恢复为磁盘上的内容。 |

### 改动预览

页面下方有 `改动预览` 区域，默认勾选 `显示改动预览`。它会比较磁盘上的原始内容与当前编辑结果：

- 绿色 `+` 行是新增内容；
- 红色 `-` 行是删除内容；
- `…` 表示省略的未改动区域。

预览只用于查看，不会写文件。关闭勾选可以隐藏预览。

### 模式切换规则

- 从 `普通模式` 切到 `高级模式` 时，当前表单内容会先合并成 YAML，再放进编辑器。
- 从 `高级模式` 切回 `普通模式` 时，编辑器内容必须能正常解析成 YAML 对象；否则会提示错误并留在高级模式。
- 如果 YAML 本身有语法错误，页面会自动进入高级模式，普通模式不可用。
- 如果配置使用了 YAML anchor、alias 或 merge key（`<<`），普通模式会显示警告并变为只读，必须在高级模式中修改。

### 校验与保存的行为

- 普通模式在提交前会按内置 schema 先做一次前端检查：数值范围、枚举取值、插件 tag 重复、sequence 步骤和 `matches`、服务端 `entry`、DoH `exec`、fallback `primary` / `secondary` 引用不存在的插件，以及管理 API 安全配置等不满足时会直接列出问题，不会发起保存。检查范围与内核 `oxidns check` 对齐：内核允许的配置（例如缺少 `listen` / `entry`、forward 未配置上游、证书与私钥未成对、插件字段留空）不会被前端拦截。配置通过 `include` 引入外部文件时，跨文件引用无法确认，引用检查会自动跳过。
- `保存` 和 `保存并应用` 都会先后端执行 `oxidns check -c <临时文件> -d <工作目录>`，校验失败不会写入。
- `保存并应用` 总会重启服务；`保存` 只写文件，不重启。因此先用 `保存` 再点 `保存并应用` 时，即使文件内容与上次保存相同，也会重启一次让新配置生效。
- 保存采用原子写入，并在写入前备份原文件。
- 保存时会检查文件 mtime。如果 LuCI 打开页面后配置文件被其他程序（例如 OxiDNS WebUI）修改过，保存会被拒绝，需要重新加载页面后再改。
- 普通模式只会写入明确改动的字段；未改动的默认值不会自动补进文件，因此改动预览不会被无关的默认值污染。
- 普通模式保存时会重新序列化 YAML，保留注释、字段顺序和表单未管理的字段，但空白格式可能有轻微变化。高级模式按编辑器中的原文保存。

---

## 三、普通模式逐项说明

普通模式由后端下发的配置 schema 和前端固定区域共同生成。**它只显示当前配置中已经存在的插件实例**，不会凭空创建插件；例外是 `广告过滤` 卡片（可以一键创建、修改或移除一组固定 tag 的 `adguard_rule` / `black_hole` 插件，并在填写订阅地址后创建对应的 `download` 插件，详见 [3.8 广告过滤](#38-广告过滤ad-filtering)），以及配置还没有可用的服务端入口时显示的 `快速开始`（`Getting Started`）卡片：它能在配置缺少插件时补全最小的 sequence + UDP/TCP 服务端配置。其他插件的新增、删除或 sequence 规则修改请使用高级模式或 WebUI。

`快速开始` 卡片只在没有任何服务端插件引用 sequence 时出现，此时配置无法应答查询。选择或新建入口 sequence、填写监听地址（默认 `:5335`），点击 `创建入口 sequence 和服务端` 即可。已有同名类型的服务端插件只会补齐空缺的 `entry` / `listen`，不会被重复创建；tag 冲突时自动使用 `main_sequence_2` 这类后缀。配置通过 `include` 引入外部插件时，卡片只显示提示，交给外部文件处理。创建完成后，`上游 DNS` 区域的 `创建 forward 插件` 按钮即可把转发接入入口 sequence。

下文表格里的字段名沿用 schema 中的英文名称；中文 LuCI 界面会显示对应的中文译文，尚未翻译的字段仍显示英文。

### 3.1 日志（Log）

对应配置路径 `log`。

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| 日志级别（`Log level`） | `log.level` | 可选 `off`、`trace`、`debug`、`info`、`warn`、`error`，默认 `info`。 |
| 日志文件（`Log file`） | `log.file` | 日志文件路径，默认 `/tmp/oxidns/oxidns.log`。留空表示不写日志文件，只输出到标准输出。 |
| 轮转（`Rotation`） | `log.rotation.type` | 轮转周期：`never`（不轮转，默认）、`minutely`、`hourly`、`daily`、`weekly`。 |
| 最大轮转文件数（`Maximum rotation files`） | `log.rotation.max_files` | 最多保留多少个历史文件。留空或填写 `0` 表示不自动删除；只有填写了值才会写入配置文件。轮转切换为 `never` 时会清除已保存的值。 |

说明：

- 日志文件是 UTF-8 纯文本，不包含终端颜色控制码。
- `/tmp` 在重启后会清空。需要长期保留日志时，把 `Log file` 改到持久化目录，例如 `/var/log/oxidns/oxidns.log`，或在 `安装部署 -> 日志路径` 修改日志目录后点击 `保存并应用`。
- 修改日志级别只影响之后的日志输出。修改日志文件或轮转设置后，建议使用 `保存并应用` 重启服务。

### 3.2 运行时（Runtime）

对应配置路径 `runtime`。

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| 工作线程数（`Worker threads`） | `runtime.worker_threads` | DNS 工作线程数量。留空表示使用系统可用并行度（OxiDNS 默认行为）；填写时必须至少为 1。 |

说明：

- 只有需要限制 CPU 占用或固定线程数时才需要填写。留空不会把 `worker_threads` 写入配置文件。
- 清空一个已经存在的值会删除该字段，恢复为默认并行度。

### 3.3 包含文件（Include）

对应顶层配置 `include`。

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| 包含的配置文件（`Included configuration files`） | `include` | 每行一个配置文件路径。 |

说明：

- 被包含文件中**只合并 `plugins`**，其中的 `log`、`runtime`、`api` 等其他配置一律忽略。
- 相对路径以声明该 `include` 的配置文件所在目录为基准。
- 最多递归 8 层。
- 多个文件中合并后的插件 `tag` 必须全局唯一。
- 被包含文件中的插件不会显示在本页面；如需修改，请到高级模式或 WebUI 编辑对应文件。
- 清空文本框会删除整个 `include` 字段。

校验规则：

- `include` 必须是字符串列表，不能写成单个字符串。
- 列表项不能为空，且不能重复。

### 3.4 出站网络（Outbound Network）

对应配置路径 `network.outbound.default`。

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| 默认出站配置（`Default outbound profile`） | `network.outbound.default` | 从当前配置中已定义的 `network.outbound.profiles` 中选择默认出站配置。选择“无”会删除该字段。 |

说明：

- 下拉框只列出 `network.outbound.profiles` 中已经存在的配置名称。没有定义任何 profile 时只能选择“无”，需要先在高级模式或 WebUI 中添加 profile。
- 该设置供未单独指定出站配置的 HTTP 客户端和上游使用；单个上游、`ip_selector`、`download` 等插件仍可用各自的 `Outbound profile` 覆盖。
- 配置文件中指向未定义 profile 的 `default` 会保留在下拉框中并标记为“未定义”，保存前会提示校验错误。请先在 `network.outbound.profiles` 中定义该 profile，或改选已定义的 profile。
- 选择“无”会删除 `network.outbound.default`，恢复核心默认行为（使用系统 DNS 和直连连接）；如果 `network.outbound` 因此变空，这个空映射也会一并移除。
- 普通模式不编辑 `network.outbound.profiles` 的具体内容。

### 3.5 API（管理接口与 WebUI）

对应配置路径 `api.http`。

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| HTTP 监听地址（`HTTP listen`） | `api.http` 或 `api.http.listen` | 管理 API 监听地址，例如 `192.168.1.1:9199`、`0.0.0.0:9199`、`:9199`、`[::]:9199`、`127.0.0.1:9199`。 |
| WebUI 根目录（`WebUI root`） | `api.http.webui.root` | WebUI 静态文件目录，默认 `/usr/share/oxidns/webui`。 |
| WebUI 首页文件（`WebUI index`） | `api.http.webui.index` | 首页文件名，默认 `index.html`。 |
| TLS 证书（`TLS certificate`） | `api.http.ssl.cert` | 启用 HTTPS 时必须与私钥同时填写。 |
| TLS 私钥（`TLS private key`） | `api.http.ssl.key` | 与证书成对配置。 |
| 客户端 CA 证书（`Client CA certificate`） | `api.http.ssl.client_ca` | 校验客户端证书时使用。 |
| 要求客户端证书（`Require a client certificate`） | `api.http.ssl.require_client_cert` | 启用时必须填写客户端 CA。 |
| Basic 认证用户名（`Basic auth username`） | `api.http.auth.username` | 与密码同时填写才启用 Basic 认证。 |
| Basic 认证密码（`Basic auth password`） | `api.http.auth.password` | 保存后不会回显；留空表示保持当前密码。 |
| 移除 Basic 认证（`Remove Basic authentication`） | `api.http.auth` | 勾选后删除整个认证配置。 |
| CORS 允许的来源（`CORS allowed origins`） | `api.http.cors.allowed_origins` | 每行一个来源。留空时根据监听地址推导；`*` 表示允许所有来源。 |

`api.http` 有两种写法：

```yaml
# 简写：只表示监听地址，不能挂载 WebUI
api:
  http: "0.0.0.0:9199"
```

```yaml
# 详写：可以配置监听、认证、TLS、CORS 和 WebUI
api:
  http:
    listen: "0.0.0.0:9199"
    ssl:
      cert: "/etc/oxidns/api.crt"
      key: "/etc/oxidns/api.key"
      client_ca: "/etc/oxidns/client-ca.crt"
      require_client_cert: false
    auth:
      type: basic
      username: "admin"
      password: "change-me"
    cors:
      allowed_origins: [ "https://example.com" ]
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

普通模式识别当前写法：

- 简写时，`普通模式` 只显示 `HTTP 监听地址`，并提示简写形式不能提供 WebUI，也不能配置 TLS、认证或 CORS。点击 `转换为详写形式` 可以就地改为详写形式：原监听地址会保留到 `listen`，原有注释和引号风格也会保留。转换只在点击按钮时发生，不会自动改写配置文件。
- 详写时，会显示监听地址、WebUI、TLS、Basic 认证和 CORS 字段。
- 认证相关字段在保存时会自动补上 `auth.type: basic`；如果只填写用户名或只填写密码，校验会提示两者必须同时填写。
- 密码只在填写时写入配置文件，页面之后只显示“已设置”，不会回显明文。需要更换密码时直接输入新密码；需要关闭认证时勾选 `移除 Basic 认证`。
- 这些字段也可以在 OxiDNS WebUI 的 `系统配置 -> 管理 API` 中设置。

校验规则：

- 详写形式的 `listen` 不能为空。
- `ssl.cert` 与 `ssl.key` 必须同时配置。
- 启用 `require_client_cert` 时必须配置 `ssl.client_ca`。
- 已有的 `auth` 配置必须同时包含用户名和密码。

监听地址写法：

- `ip:port`：监听指定 IPv4 地址。
- `[ipv6]:port`：监听指定 IPv6 地址。
- `:port`：绑定双栈 `[::]:port`。
- 只监听 IPv4 时明确写 `0.0.0.0:port`。

> `基本信息` 页面的 `打开 WebUI` 按钮根据这个监听地址生成 URL。监听 `127.0.0.1` 或 `::1` 时只能在路由器本机访问，LuCI 会显示提示；需要从局域网访问时，把监听地址改为 LAN 地址或 `0.0.0.0:9199`。

### 3.6 监听地址（Listen Addresses）

对应 `plugins` 中的 `udp_server`、`tcp_server`、`quic_server` 实例。

普通模式会为每个这类插件显示两行：

| 界面字段 | 配置字段 | 说明 |
| --- | --- | --- |
| 入口（`Entry <tag>`） | `plugins[i].args.entry` | 入口插件 tag，通常是 sequence。下拉框列出配置中已有的插件 tag：sequence 排在最前，其它插件在 `其它插件` 分组；当前值不在列表中时以 `…（未定义）` 保留，不会静默改写。 |
| 监听（`Listen <tag>`） | `plugins[i].args.listen` | 监听地址和端口，默认 `:5335`。 |

`Entry` 使用下拉框，避免手填 tag 出错。配置通过 `include` 引入外部插件时，页面无法枚举这些 tag，`Entry` 回退为文本输入，引用检查也会跳过。

示例：让 UDP 和 TCP 只监听本机，供 dnsmasq 转发：

```yaml
- tag: udp_server
  type: udp_server
  args:
    entry: main_sequence
    listen: "127.0.0.1:5335"

- tag: tcp_server
  type: tcp_server
  args:
    entry: main_sequence
    listen: "127.0.0.1:5335"
```

注意：

- `entry` 必须指向存在的 sequence，否则 `oxidns check` 会报错。
- 两个 server 可以使用同一个端口，因为协议不同（UDP/TCP）。
- 如果配置了 `quic_server`，还需要在对应插件参数区配置 TLS 证书和私钥。
- 如果页面提示“未找到 UDP、TCP 或 QUIC 服务插件”，说明当前配置没有对应插件，需要在高级模式或 WebUI 中创建。

### 3.7 上游 DNS（Upstream DNS）

对应 `forward` 插件的 `plugins[i].args.upstreams`。

配置中没有任何 `forward` 插件时，区块会显示 `创建 forward 插件`（`Create forward plugin`）按钮。点击后会创建 tag 为 `forward` 的 `forward` 插件，并把 `- exec: $forward` 加到每个入口 sequence 的末尾（末尾是 `accept` 时插在它前面），之后在下方添加上游即可。按钮需要配置中至少有一个 server 入口 sequence，没有可用入口时不可用；tag `forward` 已被其它类型插件占用时会提示先在高级模式中重命名。

每个 `forward` 插件会显示一个区块，区块标题是插件 tag。每个上游包含：

- `上游地址 N`（`Upstream address N`）：上游地址。下拉框提供常见公共 DNS 预设，也可以直接输入自定义地址。
- `选项` / `收起选项`（`Options` / `Hide options`）：展开或收起该上游的高级连接参数。
- `删除`（`Remove`）：删除这个上游。
- `添加上游DNS`（`Add upstream DNS`）：新增入口与下方的下拉框合在一起。从中选择预设或输入自定义地址后，会自动新增一个上游并保留该地址；下拉框恢复为“选择或输入上游 DNS 服务器”，等待下一次添加。仍处于“选择或输入上游 DNS 服务器”状态（未选择地址）的上游不会保存到配置文件。

常用预设包括阿里、腾讯、114、百度、Cloudflare、Google、Quad9、Cisco 的 UDP、DoT、DoH、DoQ 地址，例如：

| 地址 | 说明 |
| --- | --- |
| `223.5.5.5`、`223.6.6.6` | 阿里公共 DNS（UDP） |
| `119.29.29.29`、`119.28.28.28` | 腾讯公共 DNS（UDP） |
| `114.114.114.114` | 114 公共 DNS（UDP） |
| `180.76.76.76` | 百度公共 DNS（UDP） |
| `https://dns.alidns.com/dns-query` | 阿里 DoH |
| `quic://dns.alidns.com` | 阿里 DoQ |
| `https://doh.pub/dns-query` | 腾讯 DoH |
| `tls://1.1.1.1`、`tls://1.0.0.1` | Cloudflare DoT |
| `https://cloudflare-dns.com/dns-query` | Cloudflare DoH |
| `tls://8.8.8.8`、`tls://8.8.4.4` | Google DoT |
| `https://dns.google/dns-query` | Google DoH |
| `tls://9.9.9.9`、`tls://149.112.112.112` | Quad9 DoT |
| `https://dns.quad9.net/dns-query` | Quad9 DoH |

自定义地址支持 OxiDNS upstream 支持的协议写法，例如 `udp://`、`tcp://`、`tls://`、`https://`、`quic://`、`h3://`。未写协议时按 UDP 处理。

`选项`（`Options`）中的字段：

| 字段 | 说明 |
| --- | --- |
| `Tag` | 这个上游的 tag，便于日志和引用。 |
| `Outbound profile` | 引用 `network.outbound.profiles` 中的出站配置。留空时使用 `network.outbound.default`。 |
| `Dial address` | 实际连接的 IP，用于域名型 DoT/DoH 地址，避免解析自身。例如 `203.0.113.1`。 |
| `Port override` | 覆盖上游端口，范围 1–65535。 |
| `Bootstrap server` | 解析 DoT/DoH 域名的引导 DNS，例如 `8.8.8.8:53`。 |
| `Bootstrap IP version` | 引导查询使用 IPv4 或 IPv6。 |
| `SOCKS5 proxy` | 该上游使用的 SOCKS5 代理，例如 `127.0.0.1:1080`。 |
| `Query timeout` | 查询超时，字符串格式，例如 `5s`。 |
| `Idle timeout` | 空闲连接超时，整数，最小 0，默认值由协议决定（通常 10 秒）。 |
| `Max connections` | 最大连接数，1–4096，默认 64。 |
| `Min connections` | 最小保持连接数，0–4096，默认 0。 |
| `Skip TLS verification` | 跳过该上游的 TLS 证书校验，只应在可信环境使用。 |
| `Enable pipeline` | 启用连接流水线。 |
| `Enable HTTP/3` | 对支持的上游启用 HTTP/3。 |
| `SO_MARK` | 给连接打标记，0–4294967295，常用于策略路由。 |
| `Bind to device` | 绑定到指定网络接口，例如 `eth0`。 |

保存前前端会检查：

- 插件 tag 不能重复；重复的 tag 会被核心拒绝；
- server 插件的 `entry`、sequence 每一步的 `exec: $tag`、DoH 入口的 `exec` 必须指向已存在的插件 tag；`entry` 和 DoH `exec` 填写的是不带 `$` 的 tag；
- `forward` 插件至少有一个上游；
- 每个上游的 `addr` 不能为空；
- `min_conns` 不能大于 `max_conns`。

后端最终仍会执行 `oxidns check`，以核心的校验结果为准。

### 3.8 广告过滤（Ad Filtering）

`广告过滤` 卡片把常见的广告拦截配置组合成一个整体。卡片需要配置中至少有一个 server 入口 sequence；没有可用入口时，`添加广告过滤` 按钮不可用，并提示先在高级模式配置 server 入口。点击 `添加广告过滤` 后，普通模式会创建固定 tag 的 `oxidns_ads_rules` 和 `oxidns_ads_block` 插件，并把拦截规则插入每个 server 插件入口 sequence 的最前面；至少填写一个订阅地址后才会创建 `oxidns_ads_download` 插件：

| Tag | 类型 | 作用 |
| --- | --- | --- |
| `oxidns_ads_download` | `download` | 从订阅地址下载规则文件。 |
| `oxidns_ads_rules` | `adguard_rule` | 读取内联规则、本地规则文件和下载的订阅文件。 |
| `oxidns_ads_block` | `black_hole` | 本地应答命中规则的查询。 |

插入的 sequence 规则固定为：

```yaml
- matches: "qname $oxidns_ads_rules"
  exec: $oxidns_ads_block
```

它位于入口 sequence 的最前面，因此广告域名会在 `forward` 之前被拦截。

未配置时卡片显示 `添加广告过滤` 按钮；配置后可以编辑：

| 字段 | 说明 |
| --- | --- |
| `订阅地址`（`Subscription URLs`） | 每行一个 `http://` 或 `https://` 地址，对应 `download.downloads`。订阅文件只在 OxiDNS 启动时缺失才会下载；文件已存在时启动阶段不会自动更新，需要删除文件后重启，或通过 OxiDNS API/WebUI 手动触发下载。启动时下载失败会导致启动失败。 |
| `内联规则`（`Inline rules`） | 每行一条 AdGuard 规则，对应 `adguard_rule.rules`。 |
| `本地规则文件`（`Local rule files`） | 每行一个绝对路径，对应 `adguard_rule.files`。 |
| `拦截模式`（`Blocking mode`） | 对应 `black_hole.mode`，默认 `nxdomain`。 |
| `拦截地址`（`Blocking addresses`） | `custom` 模式返回的 IPv4 / IPv6 地址。 |
| `规则目录`（`Rules directory`） | 订阅文件的保存目录，默认 `/etc/oxidns/rules`；生成的规则文件以 `oxidns-ads-` 开头。 |

如果保留了订阅下载插件但清空全部订阅地址，校验会提示填写订阅地址，或先点击 `移除订阅下载`。

`移除订阅下载` 只删除 `download` 插件及它生成的规则文件路径，保留内联规则、本地规则文件和拦截插件；`移除广告过滤` 删除整组插件和 sequence 中的拦截规则。

这些 tag 是固定的。如果配置中已有同名 tag 但类型不同，卡片会提示冲突且不会覆盖，需要先在高级模式中重命名。普通模式的通用插件字段区域也不会再显示这三个受管理的插件。

### 3.9 本地 Hosts（Hosts）

`Hosts` 卡片管理一个固定 tag 的 `hosts` 插件，用于在本地应答指定域名：

- 未配置时显示 `启用 hosts` 按钮。按钮需要配置中至少有一个 server 入口 sequence；没有可用入口时不可用，并提示先在高级模式配置 server 入口。
- 点击 `启用 hosts` 会创建 `oxidns_hosts` 插件，并在每个入口 sequence 中插入：

```yaml
- exec: $oxidns_hosts
```

  该步骤位于广告过滤拦截步骤之后，缓存步骤和 `forward` 之前。启用时会默认写入 `short_circuit: true`，命中记录后直接结束后续步骤；未命中的查询继续执行后续步骤。
- 启用后卡片显示 schema 中的全部 hosts 字段：

| 字段 | 说明 |
| --- | --- |
| `Hosts entries`（`entries`） | 内联记录，每行一条，格式为 `域名 IP`，例如 `router.lan 192.168.10.1`。 |
| `Hosts files`（`files`） | 引用的 hosts 文件，每行一个路径，例如 `/etc/hosts`。 |
| `Short circuit`（`short_circuit`） | 命中后短路。启用卡片时已默认开启。 |

  未修改的字段不会写入配置，默认值由 OxiDNS 核心决定。
- `移除 hosts` 删除 `oxidns_hosts` 插件和所有 sequence 中的 hosts 步骤。

如果配置中已经存在其它 tag 的 `hosts` 插件，卡片只提示该插件由高级模式管理，不会重复创建。如果 `oxidns_hosts` 已被其它类型插件占用，卡片会提示冲突，需要先在高级模式中重命名。

### 3.10 缓存（Cache）

`缓存` 卡片管理一个固定 tag 的 `cache` 插件：

- 未配置时显示 `启用缓存` 按钮。按钮需要配置中至少有一个 server 入口 sequence；没有可用入口时不可用，并提示先在高级模式配置 server 入口。
- 点击 `启用缓存` 会创建 `oxidns_cache` 插件，并在每个入口 sequence 中插入：

```yaml
- exec: $oxidns_cache
```

  该步骤位于广告过滤拦截步骤和 hosts 步骤之后、`forward` 之前；这些步骤都不存在时位于 sequence 最前面。启用时会默认写入 `short_circuit: true`，缓存命中后直接结束后续步骤；未命中时继续执行后续步骤。
- 启用后卡片显示 schema 中的全部缓存字段：`size`、`lazy_cache_ttl`、`dump_file`、`dump_interval`、`short_circuit`、`cache_negative`、`max_negative_ttl`、`negative_ttl_without_soa`、`max_positive_ttl`、`min_positive_ttl` 和 `ecs_in_key`。未修改的字段不会写入配置，默认值由 OxiDNS 核心决定。
- `移除缓存` 删除 `oxidns_cache` 插件和所有 sequence 中的缓存步骤。

如果配置中已经存在其它 tag 的 `cache` 插件，卡片只提示该插件由高级模式管理，不会重复创建。如果 `oxidns_cache` 已被其它类型插件占用，卡片会提示冲突，需要先在高级模式中重命名。

### 3.11 常用插件参数

普通模式会按插件类型显示 schema 中定义的字段。下面是常见插件的字段和各字段默认值。

#### forward

| 字段 | 说明 |
| --- | --- |
| `Concurrent upstreams`（`concurrent`） | 并发查询的上游数量，1–32，默认 1。 |
| `Response selection`（`response_selection`） | 多上游时的响应选择策略：`fastest`、`balanced`（默认）、`prefer_positive`、`consensus`。 |
| `Short circuit`（`short_circuit`） | 命中结果后是否短路后续规则。 |

#### cache

| 字段 | 说明 |
| --- | --- |
| `Cache size (entries)` | 缓存条目数，最小 0，默认 1024。 |
| `Override TTL (seconds)` | 原始 TTL 过期后仍返回 stale 响应并异步刷新的时间窗口，最小 0。 |
| `Dump file` | 缓存快照文件路径。 |
| `Dump interval (seconds)` | 快照写入间隔，默认 600。 |
| `Short circuit` | 命中缓存后短路。 |
| `Cache negative responses` | 是否缓存否定响应，默认开启。 |
| `Max negative TTL (seconds)` | 否定响应最大 TTL，默认 300。 |
| `Negative TTL without SOA (seconds)` | 无 SOA 的否定响应 TTL，默认 60。 |
| `Max positive TTL (seconds)` | 正响应最大 TTL。 |
| `Min positive TTL (seconds)` | 正响应最小 TTL。 |
| `Include ECS in cache key` | 是否把 ECS 纳入缓存键。 |

#### hosts

| 字段 | 说明 |
| --- | --- |
| `Hosts entries` | 内联 hosts 记录，每行一条，例如 `example.com 192.0.2.1`。 |
| `Hosts files` | hosts 文件列表，每行一个路径，例如 `/etc/hosts`。 |
| `Short circuit` | 命中后短路。 |

#### black_hole

| 字段 | 说明 |
| --- | --- |
| `Blocking mode` | 拦截方式：`nxdomain`、`nodata`、`null`、`custom`、`refused`。 |
| `Answer addresses` | `custom` 或 `null` 模式返回的地址，每行一个，例如 `0.0.0.0`。 |
| `Short circuit` | 命中后短路。 |

#### fallback

| 字段 | 说明 |
| --- | --- |
| `Primary executor` | 主执行器 tag。 |
| `Standby executor` | 备用执行器 tag。 |
| `Slow threshold (ms)` | 判定主执行器过慢的阈值，默认 0。 |
| `Always run standby` | 是否总是并行执行备用执行器。 |
| `Short circuit` | 命中后短路。 |

#### ip_selector

| 字段 | 说明 |
| --- | --- |
| `Selection mode` | `first_success`（默认）、`best_within_budget`、`background`。 |
| `Outbound profile` / `SOCKS5 proxy` | 探测使用的出站配置或代理。 |
| `Probe methods` | 探测方法，每行一个，默认 `tcp:443`、`tcp:80`。 |
| `Probe stagger (ms)` | 探测间隔，默认 200。 |
| `Probe timeout (ms)` | 单次探测超时，默认 600。 |
| `Max wait (ms)` | 最长等待时间，默认 1000。 |
| `Top N addresses` | 保留的地址数量，默认 1。 |
| `DNSSEC policy` | `reorder_only`（默认）或 `skip`。 |
| `Max parallel probes` | 最大并行探测数，默认 256。 |
| `Enable probe cache` | 是否缓存探测结果，默认开启。 |
| `Probe cache size` | 探测缓存条目数，默认 4096。 |
| `Success TTL (seconds)` | 成功结果缓存时间，默认 3600。 |
| `Failure TTL (seconds)` | 失败结果缓存时间，默认 60。 |

#### prefer_ipv4 / prefer_ipv6

| 字段 | 说明 |
| --- | --- |
| `Probe executor` | 用于内部优选地址探测的 executor tag。 |
| `Cache preferred state` | 是否缓存优选状态，默认开启。 |
| `Preferred state TTL (seconds)` | 优选状态缓存时间，默认 3600。 |

`prefer_ipv4` 与 `prefer_ipv6` 参数相同，只是偏好方向相反。它们是带 `with_next` 的 executor，必须放在入口 sequence 中 `forward` **之前**；放置位置不对或放在 `forward` 之后不会生效。高级模式示例：

```yaml
plugins:
  - tag: prefer_ipv4_main
    type: prefer_ipv4
    args: {}

  - tag: forward_main
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"

  - tag: main_sequence
    type: sequence
    args:
      - exec: $prefer_ipv4_main
      - exec: $forward_main
```

`probe_executor` 可选。省略时，探测查询复用下游 continuation；显式填写时要指向一个能完成查询的 executor（例如另一个 `forward`）。

#### learn_domain

| 字段 | 说明 |
| --- | --- |
| `Target dynamic domain set` | 写入的动态域名集合 provider tag。 |
| `Learning phase` | `before` 或 `after`（默认）。 |
| `Questions` | `first`（默认）或 `all`。 |
| `Query types` | 学习的查询类型，默认 `A`、`AAAA`。 |
| `Require success (NOERROR)` | 仅学习 NOERROR，默认开启。 |
| `Require an answer` | 必须有应答，默认开启。 |
| `Rule kind` | `full`（默认）或 `domain`。 |
| `Asynchronous` | 异步学习，默认开启。 |
| `Error handling` | `continue`（默认）、`stop`、`fail`。 |
| `Timeout` | 超时时间，默认 `1s`。 |

#### query_recorder

| 字段 | 说明 |
| --- | --- |
| `Database path` | SQLite 数据库路径，例如 `/tmp/oxidns/query.db`。 |
| `Queue size` | 队列长度，默认 8192。 |
| `Batch size` | 批量写入条数，默认 256。 |
| `Flush interval (ms)` | 刷新间隔，默认 200。 |
| `In-memory tail size` | 内存 tail 条数，默认 1024。 |
| `Retention days` | 保留天数，默认 7。 |
| `Cleanup interval (hours)` | 清理间隔，默认 1 小时。 |
| `Reader concurrency` | 读取并发数，默认 2。 |

#### reverse_lookup

| 字段 | 说明 |
| --- | --- |
| `Cache size (entries)` | 反向映射缓存条目数，默认 65535。 |
| `Mapping TTL (seconds)` | 映射缓存时间，默认 7200。 |
| `Answer PTR from cache` | 是否直接使用缓存应答 PTR，默认关闭。 |

#### ttl

| 字段 | 说明 |
| --- | --- |
| `Fixed TTL (seconds)` | 固定 TTL；填写后忽略响应原有 TTL。 |
| `Minimum TTL (seconds)` | 最小 TTL。 |
| `Maximum TTL (seconds)` | 最大 TTL。 |

处理顺序为 `fix` → `min` → `max`；同时填写最小值和最大值时，最终 TTL 以最大值封顶。

#### download

| 字段 | 说明 |
| --- | --- |
| `Downloads` | 下载条目列表，每条包含 `URL`、`Target directory` 和 `File name`。可以逐条添加或删除。 |
| `Timeout` | 下载超时，例如 `30s`。 |
| `Skip TLS verification` | 跳过下载 TLS 校验。 |
| `Outbound profile` / `SOCKS5 proxy` | 下载使用的出站配置或代理。 |
| `Download at startup when missing` | 文件缺失时是否在启动阶段下载，默认开启。 |

#### query_summary / metrics_collector / debug_print / sleep

| 插件 | 字段 | 说明 |
| --- | --- | --- |
| `query_summary` | `Summary label`（`msg`） | 周期性查询统计的附加标签，默认 `query summary`。 |
| `metrics_collector` | `Metrics namespace`（`name`） | 指标命名空间，默认 `default`。指标通过 `GET /api/metrics` 暴露。 |
| `debug_print` | `Message`（`msg`） | 写入调试日志的附加消息，默认 `debug print`。 |
| `sleep` | `Sleep duration (ms)`（`duration`） | 休眠时长，按整数毫秒填写，默认 `0`，表示不等待。 |

这些字段都不是必填项。核心允许空参数（`args: {}`），普通模式不会因为字段留空而拒绝保存。表单会显示核心的默认值，但只有实际改动字段时才会写入配置。

#### ipset

| 字段 | 说明 |
| --- | --- |
| `IPv4 set name`（`set_name4`） | IPv4 集合名称。 |
| `IPv6 set name`（`set_name6`） | IPv6 集合名称。 |
| `IPv4 prefix length`（`mask4`） | IPv4 前缀长度，0–32，默认 24。 |
| `IPv6 prefix length`（`mask6`） | IPv6 前缀长度，0–128，默认 32。 |

集合需要事先由防火墙或 `ipset` 工具创建；字段均可留空。

#### nftset

| 字段 | 说明 |
| --- | --- |
| `IPv4 table family`（`ipv4.table_family`） | IPv4 表族，例如 `ip`。 |
| `IPv4 table name`（`ipv4.table_name`） | IPv4 表名，例如 `mangle`。 |
| `IPv4 set name`（`ipv4.set_name`） | IPv4 集合名称。 |
| `IPv4 prefix length`（`ipv4.mask`） | IPv4 前缀长度，0–32，默认 24。 |
| `IPv6 table family`（`ipv6.table_family`） | IPv6 表族，例如 `ip6`。 |
| `IPv6 table name`（`ipv6.table_name`） | IPv6 表名。 |
| `IPv6 set name`（`ipv6.set_name`） | IPv6 集合名称。 |
| `IPv6 prefix length`（`ipv6.mask`） | IPv6 前缀长度，0–128，默认 48。 |

说明：

- 普通模式编辑结构化的 `ipv4` / `ipv6` 目标对象；兼容形式的扁平字段（`table_family4`、`table_name4`、`set_name4`、`mask4` 及 IPv6 对应项）仍可在高级模式中编辑。
- `ipv4` / `ipv6` 目标可以整体不配置；一旦配置了某个目标，其 `table_family`、`table_name` 和 `set_name` 必填。集合需事先由 nftables 创建。

#### 其他插件

| 插件 | 主要字段 |
| --- | --- |
| `domain_set` | `Inline domain expressions`、`Referenced domain sets`、`Rule files`，列表类字段每行一项。 |
| `ip_set` | `Inline IP/CIDR rules`、`Referenced IP sets`、`Rule files`。 |
| `geosite` | `GeoSite data file`、`Selectors`。 |
| `geoip` | `GeoIP data file`、`Selectors`。 |
| `adguard_rule` | `AdGuard rules`、`Rule files`。 |
| `dynamic_domain_set` | `Rules file`、`Bootstrap rules`、`Queue size`（1024）、`Batch size`（256）、`Flush interval (ms)`（200）。 |
| `tcp_server` | `TLS certificate`、`TLS private key`、`Idle timeout`（默认 10）。 |
| `http_server` | `DoH entries`（每条包含 `Request path`、`Entry executor`、`Enable JSON DNS API`）、`HTTP listen`、`Client IP header`、`TLS certificate`、`TLS private key`、`Idle timeout`（默认 30）、`Enable HTTP/3`。 |
| `quic_server` | `TLS certificate`、`TLS private key`、`Idle timeout`。 |

列表类字段（例如 `entries`、`files`、`selectors`、`rules`）在文本框中**每行一项**。清空文本框会删除该配置项；恢复为默认列表时，只有实际改动才会写回文件。

对象列表字段（例如 `Downloads`、`DoH entries`）可以逐条添加和删除。每条条目的数值范围和枚举取值会参与保存前校验；条目中的字段允许留空，与核心行为一致。DoH 入口的 `Entry executor` 使用下拉框列出配置中已有的插件 tag（sequence 排在最前，其它插件在 `其它插件` 分组），避免手填引用不存在的插件；通过 `include` 引入外部插件时回退为文本输入。

### 3.12 插件概览

页面最下方的 `Plugins` 区域只读显示：

- `Tag`：插件实例 tag；
- `Type`：插件类型；
- `Arguments`：参数摘要（对象显示键名，数组显示步骤数）；
- `Status`：核心是否支持该插件类型。

`Status` 的来源：

- 已安装 OxiDNS 内核时，从内核读取插件类型列表；
- 未安装内核时使用内置目录；
- “Not supported by this core”表示当前内核没有该插件类型；“Unknown plugin type”表示内置目录也无法识别。

这个区域不会修改配置。要新增、删除或调整插件，请使用高级模式或 WebUI 插件中心。

---

## 四、常见配置任务

### 4.1 更换上游 DNS

1. 进入 `DNS配置 -> 普通模式`。
2. 如果 `Upstream DNS` 区块提示没有 forward 插件，点击 `创建 forward 插件`；页面会创建 `forward` 插件并把转发步骤接入入口 sequence。
3. 在 `Upstream DNS` 中找到目标 `forward` 插件。
4. 从下拉框选择预设，或直接输入自定义地址。
5. 需要多个上游时，在 `Add upstream DNS` 下拉框中再次选择或输入地址，每选一次会自动新增一个上游；停留在“选择或输入上游 DNS 服务器”状态的上游不会保存。
6. 点击 `校验`；通过后点击 `保存并应用`。

### 4.2 使用 DoH / DoT / DoQ 上游

1. 在 `Upstream address` 中选择或输入加密协议地址，例如 `https://dns.alidns.com/dns-query`、`tls://1.1.1.1`、`quic://dns.alidns.com`。
2. 如果地址是域名形式，展开 `Options`，填写 `Dial address` 或 `Bootstrap server`，避免 DNS 解析自身。
3. 私有证书或测试环境才考虑勾选 `Skip TLS verification`。
4. 点击 `校验`，再点击 `保存并应用`。

### 4.3 修改监听地址或端口

1. 在 `Listen Addresses` 中修改对应 server 的 `Listen`。
2. 从 `Entry` 下拉框选择入口 sequence（通常是 `main_sequence`）。
3. 点击 `保存并应用`。
4. 用 `nslookup -po=<端口> example.com 127.0.0.1`（或对应地址）验证。

如果把端口改为 53，需要先停止占用 53 的 dnsmasq DNS 功能；推荐保留 dnsmasq 并让它转发到 5335，具体见 [4.9 用 dnsmasq 转发（推荐）](#49-用-dnsmasq-转发推荐)。

### 4.4 启用缓存

1. 在普通模式的 `缓存` 卡片中点击 `启用缓存`。没有可用的 server 入口 sequence 时，需要先在高级模式中配置 server 入口。
2. 卡片会创建 `oxidns_cache` 插件，并把 `- exec: $oxidns_cache` 插入入口 sequence；有广告过滤或 hosts 步骤时位于它们之后，否则位于 sequence 最前面。
3. 按需调整缓存大小、TTL 和否定缓存等字段；没有修改的字段不会写入配置。
4. 点击 `保存并应用`。

也可以在高级模式中手动添加任意 tag 的 `cache` 插件并在 sequence 中引用；这类插件由高级模式管理，普通模式的缓存卡片不会覆盖。

### 4.5 添加本地 hosts 记录

#### 使用普通模式的 Hosts 卡片（推荐）

1. 进入 `DNS配置 -> 普通模式`，找到 `Hosts` 区域。
2. 如果还没有 hosts 插件，点击 `启用 hosts`。页面会创建 `oxidns_hosts` 插件，并在每个入口 sequence 中插入 hosts 步骤（位于广告过滤之后、缓存和转发之前）。
3. 在 `Hosts entries` 中每行填写一条记录，例如：

```text
router.lan 192.168.1.1
nas.lan 192.168.1.10
```

4. `Hosts files` 可以引用系统 hosts 文件，例如 `/etc/hosts`。
5. 点击 `校验`，通过后点击 `保存并应用`。

记录按 `域名 IP` 或 `域名 主机名` 的格式书写，一个域名可以有多条记录（例如同时给出 IPv4 和 IPv6 地址）。未命中任何记录的查询会继续走缓存和 `forward`。

如果配置中已经存在其它 tag 的 `hosts` 插件，卡片只会提示到高级模式中编辑，不会重复创建。

#### 在高级模式中手动配置

普通模式也会为已有的 `hosts` 插件显示字段，前提是插件已经存在于配置中。手动创建时注意 `short_circuit: true`，否则后续的 `forward` 会覆盖 hosts 应答：

```yaml
- tag: local_hosts
  type: hosts
  args:
    short_circuit: true
    entries:
      - "router.lan 192.168.1.1"

- tag: main_sequence
  type: sequence
  args:
    - exec: $local_hosts
    - exec: $forward
    - exec: accept
```

### 4.6 拦截广告或指定域名

#### 使用普通模式的广告过滤卡片（推荐）

1. 进入 `DNS配置 -> 普通模式`，找到 `广告过滤` 区域。
2. 点击 `添加广告过滤`。页面会创建 `oxidns_ads_download`、`oxidns_ads_rules`、`oxidns_ads_block` 三个插件，并在每个 server 入口 sequence 的最前面插入拦截规则。
3. 在 `订阅地址` 中每行填写一个广告规则订阅 URL，例如 `https://example.com/adblock.txt`；也可以直接在 `内联规则` 中填写 `||ads.example.com^`，或在 `本地规则文件` 中填写已有规则文件的绝对路径。
4. 需要时选择 `拦截模式`；`custom` 模式还要填写 `拦截地址`。
5. 点击 `校验`，通过后点击 `保存并应用`。

订阅文件只在 OxiDNS 启动时缺失才会下载，下载失败会导致启动失败。首次启用前请确认路由器可以访问订阅地址；文件已存在时不会自动更新，需要手动触发下载或重启服务。

#### 在高级模式中手动组合

常见做法是组合 `domain_set` / `geosite` / `adguard_rule` 与 `black_hole`。`black_hole` 必须设置 `short_circuit: true`，否则后续的 `forward` 会覆盖拦截结果：

```yaml
- tag: ads
  type: adguard_rule
  args:
    rules:
      - "||ads.example.com^"

- tag: block_ads
  type: black_hole
  args:
    mode: nxdomain
    short_circuit: true

- tag: main_sequence
  type: sequence
  args:
    - matches: "qname $ads"
      exec: $block_ads
    - exec: $forward
    - exec: accept
```

如果不使用广告过滤卡片，普通模式仍可以编辑已经存在的 `black_hole`、`domain_set`、`adguard_rule` 字段，但 sequence 规则需要在高级模式或 WebUI 中调整。

### 4.7 修改日志级别和日志文件

1. `Log level` 改为 `debug` 可临时排查问题；日常建议保持 `info` 或 `warn`。
2. `Log file` 改为持久化路径，避免重启后丢失。
3. 需要自动清理旧日志时设置 `Rotation` 和 `Maximum rotation files`（留空表示不自动删除）。
4. 点击 `保存并应用`。

### 4.8 备份、恢复与回滚

- 备份：`DNS配置 -> 下载配置`，保存下载到的 `config.yaml`。
- 恢复：`DNS配置 -> 上传配置`，选择名为 `config.yaml` 的文件；上传会先校验再保存，不会自动重启，随后点击 `保存并应用` 或手动重启。
- 查看改动：`改动预览` 只显示当前页面相对磁盘内容的差异。
- 后端在写入前会把旧文件备份到工作目录下的 `config-backups/`（例如 `/var/lib/oxidns/config-backups/`），需要时可以手工恢复。

### 4.9 用 dnsmasq 转发（推荐）

OxiDNS 的 `udp_server` / `tcp_server` 插件默认监听 `:5335`，而 OpenWrt 的 53 端口由 dnsmasq 占用，DHCP 也由它提供。推荐保留 dnsmasq，让它把查询转发给 OxiDNS：局域网 DHCP、`xxx.lan` 主机名和租约名解析都不受影响，客户端也无需改动。

LuCI 在 `服务 -> OxiDNS -> 基本信息` 提供了 `系统 DNS 接入` 卡片，可以在检查通过后一键完成下面「手动配置」中的 dnsmasq 改动，并支持一键停用和恢复。它只修改 `/etc/config/dhcp`（dnsmasq 的上游和 `noresolv`），**不会改动** `/etc/oxidns/config.yaml`。

#### 一键启用

启用前需要满足：

- OxiDNS 已安装并正在运行；
- OxiDNS 的 UDP 与 TCP 监听使用**同一个端口**，并共享一个可达的 IPv4 地址，例如两者都是 `127.0.0.1:5335`；
- 监听为 `:端口`、`0.0.0.0:端口` 或 `127.0.0.1:端口` 时，转发目标为 `127.0.0.1`。如果 UDP/TCP 端口不一致、没有共同可达的 IPv4 地址，或只监听 IPv6（`[::]:端口`、`[::1]:端口`），无法确定可靠的转发目标，`启用 dnsmasq 转发` 按钮不可用。
- 监听配置为 `:端口` 时，OxiDNS 在内核上可能实际绑定 IPv6 通配（`:::端口`）；只要 `bindv6only=0`（OpenWrt 默认），通过 `127.0.0.1` 访问仍然有效，LuCI 也能正确识别该监听。

操作步骤：

1. 打开 `服务 -> OxiDNS -> 基本信息`，找到 `系统 DNS 接入` 卡片。卡片会显示 dnsmasq 运行状态、接入状态、OxiDNS 监听目标、dnsmasq 的通用上游（未接入时为当前值，接入后为记录的启用前值）、特定域名上游和 `noresolv` 当前值；列表为空时显示 `无`，OxiDNS 未监听时目标后会标注 `(未监听)`。
2. 点击 `启用 dnsmasq 转发`。确认对话框会列出将要执行的改动：
   - 移除 dnsmasq 现有的通用上游，并记录其原始值；
   - 添加指向 OxiDNS 的转发条目，例如 `127.0.0.1#5335`；
   - 设置 `noresolv=1`，并记录原始值；
   - 保留 `/domain/...` 形式的特定域名上游。
   这些原始值会写入 `/etc/config/oxidns` 的 `dns_integration` 段，用于日后停用时恢复。如果之前已经手工添加过相同的转发条目，它会被当作原有通用上游记录，停用时会恢复原样。
3. 确认后后端先保存启用前的状态，再写入 `/etc/config/dhcp` 并重载 dnsmasq。卡片随后显示已启用、转发目标，以及记录的启用前上游。

验证：

```sh
nslookup -po=5335 www.baidu.com 127.0.0.1   # 直连 OxiDNS
nslookup www.baidu.com 192.168.1.1          # 经 dnsmasq，地址换成路由器 LAN 地址
```

也可以在局域网客户端上直接查询路由器地址，结果应与直连 OxiDNS 一致。

#### 状态与异常提示

卡片会持续读取实际配置并与记录比对，在以下情况给出提示：

- 转发条目被手工删除；
- OxiDNS 监听地址或端口发生变化，与记录的转发目标不再匹配；
- `noresolv` 被其他程序修改；
- dnsmasq 或 OxiDNS 已停止运行。

出现这类偏差时，按提示重新启用或直接停用即可回到已知状态。

#### 停用与恢复

点击 `停用 dnsmasq 转发` 并确认后，后端会：

1. 只删除 `dns_integration` 记录的、由本功能添加的转发条目；
2. 恢复启用前的通用上游（已存在的不重复添加）；
3. 把 `noresolv` 恢复为启用前的值；如果启用前未设置，则删除该项；
4. 提交 UCI、重载 dnsmasq，并清除 `dns_integration` 记录。

停用后 dnsmasq 回到启用前的上游配置，OxiDNS 继续按 `config.yaml` 运行，不受影响。

#### 失败行为与注意事项

- **fail-closed**：启用期间停止 OxiDNS，经 dnsmasq 的局域网查询会超时或失败，不会自动绕过 OxiDNS。需要重新启动 OxiDNS，或先停用转发。启用状态下点击 `停止` 时，LuCI 会先弹出警告确认。
- **不接管 53 端口**：dnsmasq 继续监听 53，DHCP、本地域名和租约解析保持正常。需要 OxiDNS 直接监听 53 时见本节末尾的另一种部署方式。
- 若曾手工修改 dnsmasq 的通用上游，停用后恢复的是启用那一刻的快照；之后的手工改动不会被合并。
- 不要把 dnsmasq 的 53 端口或 OxiDNS 的 5335 端口暴露到 WAN。

#### 手动配置（不使用一键功能）

1. 在 `服务 -> OxiDNS -> DNS配置` 的 `普通模式` 中，把两个 DNS 服务改为只监听本机，然后点击 `保存并应用`：

```yaml
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: "127.0.0.1:5335"
```

上游服务器在 `forward` 插件的 `upstreams` 中配置，默认是 `223.5.5.5`。

2. 让 dnsmasq 只向 OxiDNS 查询：

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

`noresolv=1` 让 dnsmasq 忽略 `/tmp/resolv.conf.d/resolv.conf.auto`，WAN 重连重写它也不会绕过 OxiDNS。

3. 验证：

```sh
nslookup -po=5335 www.baidu.com 127.0.0.1   # 直连 OxiDNS
nslookup www.baidu.com 127.0.0.1            # 经 dnsmasq
```

停掉 OxiDNS 后经 dnsmasq 的查询应当超时或失败，重新启动后恢复，这说明流量确实经过 OxiDNS。

回滚：

```sh
uci set dhcp.@dnsmasq[0].noresolv='0'
uci -q delete dhcp.@dnsmasq[0].server
uci commit dhcp
/etc/init.d/dnsmasq restart
```

注意：`delete dhcp.@dnsmasq[0].server` 会删除全部 `server` 条目，包括 `/domain/...` 形式的特定域名上游；如果存在这类上游，请先用 `uci show dhcp.@dnsmasq[0]` 记录，回滚后重新添加。`系统 DNS 接入` 的一键停用只删除它自己添加的条目，并自动恢复启用前的上游，不会影响特定域名上游。

如果 OxiDNS 需要按客户端源地址做策略，也可以让它直接监听 53 端口：先执行 `uci set dhcp.@dnsmasq[0].port='0'` 关闭 dnsmasq 的 DNS 功能（DHCP 不受影响），并确认 DHCP 仍下发本机地址作为 DNS，再把上面两个 `listen` 改为 `":53"`。代价是 `xxx.lan` 主机名、DHCP 租约名和 dnsmasq 的 rebind 保护不再生效；IPv6 客户端还需要 OxiDNS 同时监听 IPv6，例如 `"[::]:53"`。

无论哪种方式，都不要把 53 或 5335 端口暴露到 WAN，否则路由器会成为开放解析器。

---

## 五、高级模式详解

`高级模式` 是一个完整的 YAML 编辑器，编辑的是整个 `config.yaml`。适合：

- 新增或删除插件；
- 编写 sequence、matcher 规则；
- 配置 `network.outbound.profiles`、sequence/rules 等普通模式未覆盖的字段；
- 配置 API 的认证、TLS、CORS；
- 普通模式未覆盖的插件参数。

### 5.1 完整配置结构

```yaml
runtime:
  worker_threads: 4

api:
  http:
    listen: "0.0.0.0:9199"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"

log:
  level: info
  file: "/tmp/oxidns/oxidns.log"
  rotation:
    type: daily
    max_files: 7

network:
  outbound:
    default: direct
    profiles:
      direct:
        resolver: system
        proxy: none

include: []

plugins:
  - tag: cache_main
    type: cache
    args:
      size: 4096
      short_circuit: true
      cache_negative: true

  - tag: forward
    type: forward
    args:
      upstreams:
        - addr: "223.5.5.5"

  - tag: main_sequence
    type: sequence
    args:
      - exec: $cache_main
      - exec: $forward
      - exec: accept

  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: ":5335"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: ":5335"
```

### 5.2 常用高级编辑

**为 WebUI 配置认证和 TLS：**

```yaml
api:
  http:
    listen: "0.0.0.0:9199"
    auth:
      type: basic
      username: "admin"
      password: "${OXIDNS_API_PASSWORD}"
    ssl:
      cert: "/etc/oxidns/api.crt"
      key: "/etc/oxidns/api.key"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

`auth` 的 `username` 和 `password` 都不能为空；`ssl.cert` 和 `ssl.key` 必须成对出现。

**新增一个监听端口：**

```yaml
  - tag: udp_server_lan
    type: udp_server
    args:
      entry: main_sequence
      listen: "0.0.0.0:5353"
```

**添加 sequence 规则（命中域名集合时拦截）：**

```yaml
  - tag: ads
    type: domain_set
    args:
      files:
        - "/etc/oxidns/ads.txt"

  - tag: block_ads
    type: black_hole
    args:
      mode: nxdomain
      short_circuit: true

  - tag: main_sequence
    type: sequence
    args:
      - matches: "qname $ads"
        exec: $block_ads
      - exec: $forward
      - exec: accept
```

**引用外部配置文件：**

```yaml
include:
  - /etc/oxidns/plugins/common.yaml
```

`include` 只合并被包含文件中的 `plugins`；相对路径以声明该 `include` 的文件所在目录为基准，最多递归 8 层，合并后的 tag 必须全局唯一。

**配置出站网络：**

```yaml
network:
  outbound:
    default: direct
    profiles:
      direct:
        resolver: system
        proxy: none
      remote:
        resolver:
          nameservers:
            - addr: "1.1.1.1:53"
            - addr: "tls://dns.google:853"
              dial_addr: 8.8.8.8
          ip_version: 4
          timeout: 5s
          proxy: none
        proxy:
          socks5: 127.0.0.1:1080
```

### 5.3 高级模式注意事项

- 保存前务必点击 `校验`。YAML 语法正确不代表 OxiDNS 配置语义正确，后端会用 `oxidns check` 做完整校验。
- 保存会按编辑器原文写入，不会帮你整理格式或保留你删掉的注释。
- 修改 `plugins` 时，所有 `tag` 必须唯一，长度为 1–64 个 ASCII 字符，只能包含字母、数字、`_`、`-`、`.`；每个点分隔的段都必须以字母或数字开头和结尾；`qs.exec.`、`qs.match.`、`qs.cron.` 是保留前缀。
- 修改 tag 后，所有 `$tag`、`jump/goto`、依赖引用都要同步修改。
- 使用 `${VAR}` 环境变量时，未定义的变量会导致校验失败；OxiDNS 在启动和 `oxidns check` 时才展开变量，文件中的占位符本身不会被改写。
- 除 `include` 路径外，配置中的相对路径以工作目录（默认 `/var/lib/oxidns`）为基准，不是以配置文件所在目录为基准。
- 使用 YAML anchor/alias/merge key 后，普通模式会变为只读。

---

## 六、通过 WebUI 配置 DNS

OxiDNS WebUI 是内核自带的图形化管理界面。它和 LuCI `DNS配置` 页面修改同一份 `config.yaml`，适合在浏览器里管理插件、sequence、查询记录、缓存和升级。

### 6.1 从 LuCI 打开 WebUI

1. 确认 OxiDNS 服务正在运行。
2. 进入 `服务 -> OxiDNS -> 基本信息`。
3. 在 `WebUI` 一行点击 `打开 WebUI`。

按钮可用需要同时满足：

- 内核已安装；
- WebUI 文件已安装（`full` 或 `standard` bundle）；
- OxiDNS 服务正在运行；
- 配置文件中有可用的 `api.http` 监听地址。

按钮不可用时，页面会显示原因和提示：

| 提示 | 处理方法 |
| --- | --- |
| 使用 WebUI 前请先安装 OxiDNS 内核。 | 先安装内核。 |
| 已安装的 minimal 内核 bundle 不包含 WebUI 文件。请在“安装部署”页面点击“安装 WebUI”…… | 在 `安装部署` 点击 `安装 WebUI`，下载包含 WebUI 的 bundle。 |
| WebUI 文件尚未安装。请在“安装部署”页面使用“安装 WebUI”进行安装。 | 在 `安装部署` 点击 `安装 WebUI`。 |
| 请先启动 OxiDNS 服务再打开 WebUI。 | 在 `基本信息` 点击 `启动`。 |
| WebUI 仅监听 loopback。请把 HTTP 监听地址配置为局域网可访问地址…… | 把 `api.http.listen` 改为 LAN 地址或 `0.0.0.0:9199`，或使用 SSH 隧道。 |

URL 生成规则：

- 监听 `0.0.0.0` 或 `[::]` 时，用当前浏览器访问路由器的主机名/IP 替换地址。
- 监听具体 LAN 地址时直接使用该地址。
- 监听 `127.0.0.1` / `::1` 时保留链接，但只能在路由器本机访问，或通过 SSH 隧道。

### 6.2 让 WebUI 可用所需的配置

WebUI 必须使用 `api.http` 的**详写形式**：

```yaml
api:
  http:
    listen: "0.0.0.0:9199"
    webui:
      root: "/usr/share/oxidns/webui"
      index: "index.html"
```

如果当前是简写：

```yaml
api:
  http: "0.0.0.0:9199"
```

可以在 `DNS 配置 -> 普通模式` 点击 `转换为详写形式`，也可以在 `高级模式` 手动改为详写，或在 WebUI 的 `系统配置 -> 管理 API -> WebUI 静态文件` 中启用。简写形式只能提供 API，不能挂载 WebUI。

WebUI 和管理 API 同源：

- WebUI 挂在 `/`；
- 管理 API 挂在 `/api/*`；
- 前端请求 `/api/health`、`/api/config`、`/api/plugins/...`。

因此不要给 WebUI 单独配置跨域，除非你使用 nginx 等反向代理或在线 Console。

### 6.3 首次连接与登录

打开 WebUI 后：

1. 如果 OxiDNS 开启了 `api.http.auth`（Basic Auth），页面会要求输入用户名和密码。
2. 输入配置中的 `auth.username` 和 `auth.password`。
3. 可以勾选 `记住登录状态`，下次访问时自动使用保存的凭据。
4. 页面显示 `正在连接后台服务`，连接成功后进入仪表盘。

如果页面提示未连接后台服务：

1. 进入 `系统配置 -> 后台服务`。
2. `服务地址` 保持默认 `/api`（同源托管时）。
3. 点击 `保存地址` 或 `重新连接`。
4. 如果 WebUI 由 nginx 托管，确保 `/api/*` 被反向代理到 OxiDNS 的 `api.http.listen`，且没有剥离 `/api` 前缀。

### 6.4 界面结构与两种模式

登录后左侧导航包含：

- `仪表盘`
- `插件中心`
- `运行日志`
- `系统配置`

顶部/侧边栏还有：

- `配置编辑器`：切换到完整 YAML 编辑器模式；
- `文档站`：打开 OxiDNS 文档；
- `软件升级`：检查或执行内核升级（取决于内核是否编译了升级插件）；
- `主题切换`：浅色/深色；
- `退出登录`。

界面有两种模式：

- **控制台模式**：仪表盘、插件中心、日志、系统配置，图形化编辑；
- **编辑器模式**：完整 YAML 编辑器，适合批量修改或查看原文。

两种模式修改的是同一份配置，切换不会丢失当前编辑内容，但未点击保存/应用的内容仍只存在于页面中。

### 6.5 仪表盘

仪表盘显示：

- **服务健康**：运行时长、运行状态；
- **CPU 使用率**：进程 CPU；
- **DNS QPS**：最近一段时间的平均查询速率；
- **内存占用**：进程 RSS、工作集、提交量；
- **插件总数**：插件数量、server 数量；
- **配置状态**：校验通过或配置有误；
- **运行时间**：天/小时/分/秒。

下方是**固定的插件**卡片。在 `插件中心` 打开插件菜单，选择 `固定到仪表盘` 即可添加；卡片可以拖动排序，排序只保存在当前浏览器，不会写入配置文件。

### 6.6 插件中心

`插件中心` 是 WebUI 的核心页面，按 server、executor、matcher、provider 分类展示所有插件实例。

#### 查看与筛选

- 搜索框可以按插件名称、类型或配置项搜索；
- 可以按插件类型筛选；
- 卡片显示 tag、类型、运行状态和关键配置摘要；
- 点击卡片进入详情，详情有 `配置`、`统计`/`指标` 等标签。

#### 创建插件

1. 点击 `添加插件` 或 `创建插件`。
2. 选择插件类型（server、executor、matcher、provider）。
3. 输入实例名称（tag）。名称规则：1–64 个 ASCII 字符，只能包含字母、数字、`_`、`-`、`.`；`.` 不能出现在开头、结尾或连续出现，每个点分隔的段也必须以字母或数字开头和结尾；不能使用 `qs.exec.`、`qs.match.`、`qs.cron.` 前缀。
4. 在表单中填写参数；没有表单字段的插件可直接编辑高级 YAML。
5. 保存后配置只是写入草稿/磁盘，还需要点击顶部的 `应用更改` 才会生效。

#### 编辑插件

- 表单模式：按插件定义显示常用字段，支持“恢复默认值”“清除显式配置”。
- 高级设置：直接编辑该插件的 YAML，可以是任意合法参数。
- `取反匹配`：matcher 专用，表示对该 matcher 的结果取反。
- 引用字段：从下拉框选择已有插件，或使用 `快速创建插件` 新建一个并自动回填。
- 依赖关系：详情中显示初始化序号、依赖插件、被引用关系；可以查看拓扑图。

#### 删除插件

删除前 WebUI 会检查依赖：

- 插件仍被其他插件引用时，不能直接删除；
- 可以选择一个类型兼容的替换插件，或移除引用后再删除；
- 也可以进入编辑器手动修复。

删除会先保存到磁盘，但不会自动应用；确认无误后点击 `应用更改`。

#### 固定插件到仪表盘

在插件卡片的菜单中选择 `固定到仪表盘` / `取消固定`。固定的卡片会出现在仪表盘，顺序保存在浏览器本地。

#### 运行指标与运行时控制

插件详情中的 `统计` / `指标` 显示该插件的运行数据。部分插件提供运行时控制：

| 插件 | 运行时操作 |
| --- | --- |
| matcher | 把基础结果固定为 `true` 或 `false`，用于临时验证策略；reload 或重启后恢复。 |
| provider | `重新加载数据`：用当前配置重新读取 provider 数据，不重建其他插件；不会应用 YAML 或拓扑变更。 |
| cache | 查看缓存项、按 QNAME 筛选、删除单条、清空缓存、导出/导入 `.dump`。 |
| query_recorder | 查看查询记录、筛选、实时流、清空历史、查看 matcher 命中率和聚合统计。 |
| dynamic_domain_set | 查看/添加/删除/清空规则，规则支持 `full:`、`domain:`、`keyword:`、`regexp:` 和无前缀域名。 |
| download | 查看下载清单并触发下载，下载会覆盖目标文件。 |
| cron | 查看定时任务，支持 `手动运行` 单个任务。 |

这些操作只影响运行状态，不修改配置文件，除非页面明确说明会保存。

#### Sequence 编排

`sequence` 插件详情提供画布/列表编辑器：

- 查看和编辑规则顺序；
- `IF · 匹配条件` 选择 matcher，`THEN · 执行动作` 选择 executor；
- 支持取反匹配、上移/下移、删除规则；
- 支持 `jump`/`goto` 到其他 sequence，循环引用会用指向标记表示；
- 可以切换 `引用`、`快捷`、`文本`、`控制流` 等编辑方式；
- 保存后写入当前插件配置，仍需 `应用更改` 才会生效。

`拓扑` 视图显示插件之间的依赖、matcher 条件、executor 目标和 sequence 调用关系，可用于排查悬空引用和循环依赖。

### 6.7 运行日志

`运行日志` 页面实时显示 OxiDNS 输出：

- 顶部显示 `已连接` / `断开`；
- 可以按日志级别过滤（全部级别、trace、debug、info、warn、error）；
- 搜索框按消息内容或 target 过滤；
- `暂停` / `继续` 控制自动滚动，暂停期间新日志会计数；
- `自动换行` 开关；
- 可以设置时间格式（支持 `YYYY`、`MM`、`DD`、`HH`、`mm`、`ss`、`SSS`）；
- 可以显示距应用启动的运行时间。

日志文件本身由 `log.file` 配置；WebUI 日志页读取的是后端日志流，不替代 LuCI `运行日志` 页面。

### 6.8 系统配置

`系统配置` 分为多个卡片：

#### 后台服务

- `服务地址`：WebUI 连接的后端地址，同源托管时保持 `/api`；
- `保存地址`、`重新连接`；
- 显示当前连接状态。

#### 账号与安全

- 设置或修改 Basic Auth 用户名和密码；
- 修改后需要重启生效；
- 可以关闭认证，但关闭后任何能访问管理 API 的人都可以操作，页面会显示警告。

#### 运行状态 / 配置摘要

- 编译版本、平台、健康状态、重载状态；
- 配置文件路径、配置版本、插件数、初始化顺序、配置校验状态。

#### 运行时

- `Worker 线程数`：Tokio 多线程运行时 worker 数，留空使用系统默认，不能为 0。

#### 出站网络

- `默认出站配置`：对应 `network.outbound.default`；
- 每个 profile 可以配置：
  - 名称；
  - SOCKS5 代理；
  - resolver 模式（系统解析 / 自定义 nameservers）；
  - 解析 IP 版本、解析超时、nameserver 代理；
  - nameservers 列表（支持 UDP/TCP/DoT/DoH/DoH3/DoQ，域名型需要 `dial_addr`）；
- 显示每个 profile 的 resolver 缓存命中、刷新错误、地址池刷新等运行指标。

#### 管理 API

- `监听地址 (listen)`：支持 `ip:port`、`[ipv6]:port`、`:port`；
- `TLS / SSL`：证书、私钥、客户端 CA、是否要求客户端证书；
- `身份认证 (auth)`：提示到“账号与安全”设置；
- `跨域白名单 (cors.allowed_origins)`：每行一个 Origin，`*` 允许任意 Origin；
- `WebUI 静态文件 (webui)`：启用后 WebUI 挂载在 `/`，管理 API 位于 `/api/*`；配置 `root` 和 `index`。

#### 日志

- `日志级别`：`off`、`trace`、`debug`、`info`、`warn`、`error`；
- `日志文件路径`：留空只输出到标准输出；
- `日志轮转策略`：never/minutely/hourly/daily/weekly；
- `最多保留历史文件数`：0 或留空表示不限制。

#### 软件升级

- 检查更新、查看当前/最新版本和发布说明；
- `立即升级`、`强制升级`；
- 升级配置：GitHub 仓库、bundle 类型（auto/full/standard/minimal）、出站配置、SOCKS5、GitHub Token、是否允许预发布版本、升级后是否清理缓存和备份、是否自动检查更新；
- 显示等效 CLI 命令，Token 只显示占位符；
- 如果内核未编译升级插件，页面会提示在线升级不可用，此时使用 `安装部署 -> 更新内核` 或 CLI。

### 6.9 配置编辑器

切换到 `配置编辑器` 后：

- 左侧/右侧有插件索引，点击可跳转到对应定义行；
- 编辑完整 YAML，支持语法高亮、缩进、撤销/重做和快捷键；
- `保存`：写入磁盘，不自动应用；
- `重置`：恢复为当前磁盘内容；
- `下载`：下载当前 YAML；
- `复制`：复制到剪贴板；
- `差异`：对比原文件与当前编辑内容；
- `配置历史`：保存浏览器本地的配置快照，可以查看差异、回滚、删除或清空；
- `离线模式`：未连接后端时，可以粘贴或上传 `config.yaml` 在本地编辑，结果只保存在内存中，刷新即丢失，需要手动复制或下载。

配置历史只保存在当前浏览器，并按服务实例隔离。`回滚此版本` 会写入磁盘，并根据改动类型触发热重载或重启。

### 6.10 应用、重载与重启

WebUI 中保存配置后，页面顶部会显示配置同步状态：

- `配置已同步`：磁盘配置与运行配置一致；
- `有未应用的配置改动`：点击 `应用更改` 触发热重载；
- `配置有错误`：先修复校验错误，才能应用；
- `需要重启`：顶层配置（`runtime`、`api`、`log` 等）发生变化，热重载无法生效，需要重启服务。

操作说明：

| 操作 | 作用 |
| --- | --- |
| `查看差异` | 对比正在运行的版本与待应用版本。 |
| `放弃改动·恢复运行版` | 放弃未应用的改动，恢复为当前运行配置。 |
| `重载当前配置` | 重新加载磁盘上的配置。 |
| `重启服务` | 以新进程替换运行中的服务；DNS 会短暂中断，内存缓存会清空。 |

重启时页面会显示覆盖层：保存配置、发起重启、等待服务切换、等待新进程就绪、重新加载配置。完成后自动恢复，不要刷新或关闭页面。

### 6.11 软件升级

`软件升级` 页面用于内核自升级：

1. 点击 `检查更新`，查看当前版本、最新版本和发布说明。
2. 有更新时点击 `立即升级`；需要重新安装同一版本时使用 `强制升级`。
3. 升级配置可以设置 GitHub 仓库、bundle、出站配置、代理、Token、是否允许预发布版本。
4. 升级过程中页面显示阶段：发送请求、下载并应用发布包、等待后端上线、验证版本。
5. 升级完成后会自动重新连接。

Token 保存建议：

- 可以持久化：个人专用设备、可信内网、浏览器配置受系统账号保护、使用 HTTPS；
- 不建议持久化：公用电脑、共享浏览器账号、远程代管、明文 HTTP 跨网络访问；
- 无论是否保存，Token 都会随检查和升级请求发送到后端；建议使用 fine-grained token，只授予目标仓库读取权限。

如果内核未编译升级插件，使用 LuCI `安装部署 -> 更新内核`、`上传内核`，或按页面显示的 CLI 命令手动升级。

### 6.12 WebUI 与 LuCI 操作对照

| 目标 | LuCI | OxiDNS WebUI |
| --- | --- | --- |
| 修改日志级别/文件 | `DNS配置 -> 普通模式 -> 日志` | `系统配置 -> 日志` |
| 修改监听地址/端口 | `DNS配置 -> 普通模式 -> 监听地址` | `插件中心 -> udp_server/tcp_server/quic_server -> 配置` |
| 修改上游 DNS | `DNS配置 -> 普通模式 -> 上游 DNS` | `插件中心 -> forward -> 配置` |
| 添加/删除插件 | `DNS配置 -> 高级模式` | `插件中心 -> 添加插件/删除` |
| 修改 sequence | `DNS配置 -> 高级模式` | `插件中心 -> sequence -> Sequence 编排` |
| 启用 WebUI/认证/TLS | `DNS配置 -> 高级模式` | `系统配置 -> 管理 API` |
| 修改完整 YAML | `DNS配置 -> 高级模式` | `配置编辑器` |
| 查看运行日志 | `运行日志`（LuCI） | `运行日志`（WebUI） |
| 查看查询记录/缓存 | 无 | 插件中心中的对应插件详情 |
| 升级内核 | `安装部署 -> 更新内核` | `软件升级` |

---

## 七、故障排查

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 页面提示“配置有错误” | YAML 语法错误、字段类型错误、引用了不存在的 tag | 切换到高级模式查看错误，或使用 WebUI 配置编辑器修复；修复后重新校验。 |
| 保存时提示配置冲突 | 配置文件被 WebUI、脚本或其他会话修改 | 重新加载 `DNS配置` 页面，确认内容后再保存。 |
| `保存` 成功但 DNS 行为没变 | 只写入了文件，没有重启 | 点击 `保存并应用`，或在 WebUI 中点击 `应用更改` / `重启服务`。 |
| 普通模式没有某个插件 | 插件实例不存在，或该类型没有 schema 定义 | 在高级模式或 WebUI 中添加插件。 |
| 普通模式变成只读 | 配置使用了 YAML anchor/alias/merge key | 使用高级模式修改，或去掉 anchor。 |
| `打开 WebUI` 按钮不可用 | 未安装内核、缺少 WebUI 文件、服务未运行、监听地址不可达 | 按页面提示处理；`minimal` 内核需 `安装 WebUI`。 |
| 浏览器打不开 WebUI | 监听 `127.0.0.1`、防火墙拦截、端口未开放 | 改为 LAN 地址或 `0.0.0.0:9199`；检查防火墙和端口。 |
| WebUI 登录失败 | 用户名或密码错误；认证配置已修改但未重启 | 核对 `api.http.auth`，修改后重启 OxiDNS。 |
| WebUI 显示连接失败 | `服务地址` 不是 `/api`；nginx 剥离了 `/api`；后端未启动 | 恢复 `/api`；检查反向代理；确认 OxiDNS 运行。 |
| 刷新 WebUI 深链 404 | 静态服务缺少 `index.html` 回退 | 使用 OxiDNS 托管或配置 nginx `try_files $uri $uri/ /index.html;`。 |
| 运行日志页没有输出 | `log.file` 未配置、路径不可写、服务未运行 | 检查 `log.file` 和目录权限；必要时改回标准输出并查看 `logread`。 |
| DNS 查询超时 | 监听地址/端口错误、上游不可达、防火墙 | 用 `nslookup` 直连测试；检查 Listen Addresses 和 Upstream DNS。 |
| 端口被占用 | dnsmasq 或其他 DNS 服务占用 53/5335 | 改用其他端口，或关闭占用端口的服务。 |

更多后端错误可以在 `运行日志` 页面查看；LuCI 系统日志中还会记录以 `luci-app-oxidns` 为 tag 的服务操作审计记录。

---

## 八、安全建议

- 不要把 53、5335 或 9199 端口暴露到 WAN。开放解析器会被用于 DNS 放大攻击。
- 管理 API 建议只监听 LAN 地址；需要远程访问时使用 SSH 隧道或反向代理加认证。
- 从局域网访问 WebUI 时，建议在 `api.http.auth` 中启用 Basic Auth，并在反向代理层配置 HTTPS。
- `Skip TLS verification` 只用于可信的自签名环境，不要对公网上游长期开启。
- GitHub Token 使用最小权限的 fine-grained token，避免在公用浏览器中持久化。
- 修改配置前先 `下载配置` 备份；大改前保留一份可回滚的副本。

---

## 九、相关文档

- OxiDNS 官方主页：<https://oxidns.org/>
- OxiDNS 内核与 WebUI 源码：<https://github.com/svenshi/oxidns>
- OxiDNS 全局配置参考：<https://oxidns.org/configuration/global>
- OxiDNS 序列配置参考：<https://oxidns.org/configuration/sequence>
- OxiDNS 规则配置参考：<https://oxidns.org/configuration/rules>
- 插件参考：<https://oxidns.org/plugin-reference/overview>
- WebUI 部署：<https://oxidns.org/webui>
