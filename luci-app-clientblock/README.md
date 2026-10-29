# luci-app-clientblock

OpenWrt 客户端访问控制插件（LuCI）。一个页面管两件事：**拉黑设备**、**拉黑外部 IP**，外加**登录爆破的实时自动封禁**。

> 取代 `luci-app-watchdog` 的黑名单功能。原实现因 `login_ip_black_timeout=0` 且规则在 `fw4 reload` 后不会重建，实际从未生效。

---

## 功能

| 功能 | 说明 |
|---|---|
| **设备页签** | 按 MAC 拉黑 / 解禁局域网设备。被拉黑设备失去经过路由器的所有流量：上网、DNS、DHCP、网关服务，`input` + `forward` 双向丢弃 |
| **External IPs 页签** | 按 IP 或 CIDR 拉黑 / 解禁外部地址，双向丢弃，支持 IPv4 / IPv6 |
| **IP 归属** | 离线查询，读取系统已有的 `ip2region_v4.xdb`，无网络请求 |
| **自动防护** | 实时监听 syslog，登录失败达到阈值即封禁，**秒级响应** |
| **可重命名** | 设备名称持久化，解禁再拉黑不丢 |
| **登录日志** | 记录每一次 SSH / LuCI 登录（成功、失败、断开），含来源归属，保留 500 条 |
| **定时封禁** | 每设备按星期的时段封禁，支持跨午夜 |
| **临时封禁** | 1 小时 / 8 小时 / 到明早，到期自动解封 |
| **分组与宵禁** | 家人 / 孩子 / IoT 分组，一键把整组封到次日 08:00 |
| **端口限制** | 允许上网但封掉指定端口（如 IoT 不能访问 SMB/445） |
| **通知** | Telegram / Bark / Webhook，自动封禁、新设备、封禁到期 |
| **健康检查** | 八项自检 + 端到端探针，失败直接给修复命令 |
| **概览首页** | 默认落地页：在线/封禁/失败计数、24 小时失败趋势、防护状态、健康摘要、最近活动，**不含任何设备地址** |
| **默认信任模型** | 局域网设备默认全部信任；新上线设备标记「待确认」，由你决定允许或封禁 |
| **全局锁定** | 一键封禁**仅新设备**，已信任设备不受影响 |
| **黑名单订阅** | 拉取公开列表（firehol / Spamhaus 等）并按来源管理 |
| **端口预设** | IoT / SMB / 远程 三套预设，一键套用到设备 |
| **封禁溯源** | 自动封禁记录触发它的原始 syslog 行 |
| **备份恢复** | 导出/导入全部列表与规则（JSON） |
| **设备识别** | 每台设备显示首次出现时间、MAC 厂商、推测的设备类型 |
| **丢包统计** | 每条规则显示实际丢弃的包数与字节数 |
| **开机自愈** | 重启后从状态文件重建 nftables 规则 |

---

## 安装

### 方式一：Shell 安装（推荐，无需包管理器）

适用于**任何** OpenWrt 版本，包括 apk-based（24.10+ / 25.x）和 opkg-based 系统。

```sh
# 1. 下载并解压
wget https://github.com/rheatin/luci-app-clientblock/releases/latest/download/luci-app-clientblock-1.1.0.tar.gz
tar -xzf luci-app-clientblock-1.1.0.tar.gz

# 2. 安装
cd luci-app-clientblock
sh install.sh
```

安装脚本会：

1. 复制文件到 `/`
2. 修正权限
3. 创建 `/etc/clientblock/` 状态目录
4. 重启 `rpcd` 注册 ubus 插件
5. 启用并启动 `clientblock` 服务
6. 重载防火墙

可选参数：

```sh
sh install.sh --no-start    # 只装文件，不启动服务
```

### 方式二：APK 包

仅适用于 apk-based 系统（OpenWrt 24.10 及以上）。

```sh
# 下载对应架构的 .apk 后
apk add --allow-untrusted ./luci-app-clientblock-1.1.0-r1.apk
```

> 实际文件名带架构与版本后缀，例如 `luci-app-clientblock-1.1.0-r1.apk`。
> 用 `apk add --allow-untrusted ./luci-app-clientblock*.apk` 也可以。

`.apk` 由 GitHub Actions 用官方 OpenWrt SDK 构建，在 [Releases](../../releases) 页面按架构下载。

### 方式三：无人值守

```sh
wget -qO- https://github.com/rheatin/luci-app-clientblock/releases/latest/download/luci-app-clientblock-1.1.0.tar.gz \
  | tar -xz -C /tmp && sh /tmp/luci-app-clientblock/install.sh
```

安装完成后打开 LuCI → **网络 → Access Control**。

---

## 卸载

```sh
sh uninstall.sh
```

会停止服务、移除全部文件、删除 `/etc/clientblock/` 状态目录、重载防火墙。

---

## 使用

### 拉黑设备

1. 打开 **网络 → Access Control → 设备**
2. 找到目标设备（可用名称 / IP / MAC 过滤）
3. 点 **Block**

被拉黑设备的全部流量会在路由器的 `input` 和 `forward` 链上以优先级 `-1` 丢弃，早于 fw4 的默认规则。

### 拉黑外部 IP

1. 切到 **External IPs** 页签
2. 输入地址，支持三种格式：

   ```
   1.2.3.4
   1.2.3.0/24
   2001:db8::1
   ```

3. 可填备注，点 **Block IP**

列表会显示归属地（国家 · 省份 · 城市 · ISP · 国家代码）和实际丢包量。

### 自动防护

**Automatic protection** 面板：

| 项 | 默认 | 含义 |
|---|---|---|
| 主开关 | 开 | 总开关 |
| SSH password failure | 选 | `Bad password attempt` / `Max auth tries reached` |
| SSH unknown user | 选 | `Login attempt for nonexistent user` |
| LuCI login failure | 选 | `failed login` |
| Trigger after | 5 | 触发封禁的失败次数 |
| Within | 600 | 计数时间窗（秒） |
| Expire after | 86400 | 自动条目有效期（秒），`0` = 永久 |

三个触发源可以独立勾选。例如只想防 SSH 爆破、不拦截 Web 登录失败，
取消勾选 `LuCI login failure` 即可 —— 该来源的失败事件会被完全忽略。

命中后立即写入 nftables 集合，**无需等待轮询**。

**Scan now** 按钮可手动触发一次全量扫描。

> 自动封禁的条目带红色 `auto` 徽标；从 watchdog 迁移的历史条目带蓝色 `imported` 徽标。手动封禁的条目无徽标。

---

## 登录日志

`Login log` 页签记录所有经过路由器的登录活动，**倒序**显示最新在前，保留最近 500 条。

| 字段 | 说明 |
|---|---|
| Time | 事件时间 |
| Result | `success` 成功 / `failure` 失败 / `closed` 会话断开 |
| Source | `ssh`、`ssh_password`、`ssh_user`、`web`、`web_auth` |
| IP | 来源地址，已知设备会附带主机名 |
| User | 尝试的用户名，未知用户显示 `(unknown)` |
| Detail | 具体原因，公网地址附带归属地 |

可记录的事件：

| 事件 | 来源 | Detail |
|---|---|---|
| SSH 公钥登录成功 | `ssh` | `auth=pubkey` |
| SSH 密码登录成功 | `ssh` | `auth=password` |
| SSH 会话结束 | `ssh` | `session closed` |
| SSH 密码错误 | `ssh_password` | `wrong password` |
| SSH 尝试次数超限 | `ssh_password` | `too many attempts` |
| SSH 未知用户名 | `ssh_user` | `unknown user` |
| LuCI 登录成功 | `web` | `luci session` |
| LuCI 登录失败 | `web_auth` | `bad credentials` |

支持按来源和结果筛选，也可按 IP / 用户名 / 详情搜索。**Clear log** 清空。

> 日志存储在 `/etc/clientblock/login.log`，格式为 `epoch|kind|result|ip|user|detail`。
> 服务重启不会重复记录历史事件。

## 命令行

```sh
# 查询
ubus call luci.clientblock iplist
ubus call luci.clientblock list '{"probe":"1"}'
ubus call luci.clientblock geoinfo '{"ip":"8.8.8.8"}'

# 外部 IP
ubus call luci.clientblock ipadd '{"ip":"1.2.3.0/24","note":"垃圾流量"}'
ubus call luci.clientblock ipdel '{"ip":"1.2.3.0/24"}'
ubus call luci.clientblock ipflush

# 设备
ubus call luci.clientblock block   '{"mac":"aa:bb:cc:dd:ee:ff","host":"我的设备"}'
ubus call luci.clientblock unblock '{"mac":"aa:bb:cc:dd:ee:ff"}'
ubus call luci.clientblock unblock_all
ubus call luci.clientblock rename  '{"mac":"aa:bb:cc:dd:ee:ff","name":"新名字"}'

# 自动防护
ubus call luci.clientblock autoget
ubus call luci.clientblock autoset '{"enabled":"1","threshold":"5","window":"600","ttl":"86400"}'
ubus call luci.clientblock scan
ubus call luci.clientblock tick          # 每分钟由服务调用：调度 + 到期
ubus call luci.clientblock block '{"mac":"aa:bb:cc:dd:ee:ff","minutes":"60"}'
ubus call luci.clientblock curfew '{"id":"1"}'
ubus call luci.clientblock portadd '{"mac":"aa:bb:cc:dd:ee:ff","proto":"tcp","port":"445"}'
ubus call luci.clientblock grouplist
ubus call luci.clientblock notifyget
ubus call luci.clientblock selfcheck
ubus call luci.clientblock probe

# 登录日志
ubus call luci.clientblock loglist '{"limit":"100"}'
ubus call luci.clientblock logclear
```

---

## 文件结构

```
/usr/libexec/rpcd/luci.clientblock              rpcd 后端（Lua）
/usr/sbin/clientblock-watch                     登录失败实时监听
/etc/init.d/clientblock                         服务（开机自愈 + 启动监听）
/www/luci-static/resources/view/clientblock.js  LuCI 前端
/usr/share/luci/menu.d/luci-app-clientblock.json
/usr/share/rpcd/acl.d/luci-app-clientblock.json
/etc/clientblock/blocked.json                   设备黑名单
/etc/clientblock/blocked_ips.json               外部 IP 黑名单
/etc/clientblock/names.json                     设备名称
/etc/clientblock/auto.json                      自动防护参数
/etc/nftables.d/90-clientblock.nft              生成的 nftables 规则
```

---

## 依赖

**必需**：`luci-base`、`rpcd`、`nftables`、`firewall4`

**IP 归属（可选）**：按顺序查找，缺失时归属列显示 `-`，其余功能不受影响

```
/etc/config/lucky.daji/ipdb/ip2region_v4.xdb
/usr/share/ip2region/ip2region_v4.xdb
/etc/ip2region/ip2region_v4.xdb
```

该数据库随 **Lucky** 附带。若未安装 Lucky，从 [ip2region releases](https://github.com/lionsoul2014/ip2region/releases) 取 `ip2region_v4.xdb` 放到上述任一位置即可。

---

### 订阅格式

订阅不要求固定格式——解析器逐行取 token，凡是能解析成地址的就收，其余忽略：

| 格式 | 例子 | 结果 |
|---|---|---|
| 每行一个地址 | `1.1.1.1` | 收录 |
| CIDR | `203.0.113.0/24` | 收录 |
| `#` 注释 | `198.51.100.7  # 恶意` | 收录 `198.51.100.7` |
| `;` 尾注（Spamhaus） | `192.0.2.0/28 ; SBL12345` | 收录 CIDR |
| CSV | `8.8.8.8,malware,2024-01-01` | 收录 `8.8.8.8` |
| 一行多条 | `1.2.3.4 5.6.7.8` | 两条都收 |
| IPv6 | `2001:db8::1` | 收录，进 `blocked_ip6` |
| hosts 文件 | `0.0.0.0 bad.example.com` | 无有效地址，跳过 |

**安全过滤**：订阅里的私有与保留地址一律丢弃——`10/8`、`172.16/12`、`192.168/16`、
`127/8`、`169.254/16`、`100.64/10`、`224/4`、`::1`、`fe80::/10`、`fc00::/7`、`ff00::/8`。
这样即使订阅源被投毒或写错，也不可能把你自己的局域网封掉。

## 设备识别

设备列表里每台设备都有：

| 字段 | 说明 |
|---|---|
| **首次出现** | 该设备第一次被记录的时间。带 `≈` 表示是升级后才开始记录的，之前的历史无从得知 |
| **厂商** | 由 MAC 前三字节（OUI）推断。优先查询 macvendors.com（结果缓存 7 天，每分钟最多查 2 个），离线时回退到内置常见厂商表 |
| **类型** | 结合主机名与厂商推测：手机 / 平板 / 电脑 / 电视 / 摄像头 / 音箱 / 打印机 / 游戏机 / 网络设备 / 服务器 / 智能设备 |

本地管理地址（Docker `02:42:xx`、虚拟机、手机私有 Wi-Fi 地址）不参与厂商查询，因为它们在规范上就没有厂商。

## 信任代理

反向代理（lucky / nginx / HAProxy / WAF）会让后端日志里的来源地址变成代理自己，
所有请求看起来都来自同一个 IP。**设置 → 自动防护 → 信任代理** 用来解决这个问题：

- 列出的地址**永远不会被封禁**，任何路径都不会（手动、自动、订阅、定时、紧急）
- 日志里的来源若命中列表，会改从该行的 `X-Forwarded-For` / `X-Real-IP` 读取真实客户端
- 添加代理时，若该地址已在黑名单里会被自动移除

lucky 实测默认就会写这两个头，且会**覆盖**客户端自带的伪造值：

```
X-Forwarded-For: https, 203.0.113.7     ← lucky 会带协议前缀，取最后一个逗号后的部分
X-Real-IP:       203.0.113.7            ← 干净的单 IP，优先用它
```

代理地址默认填路由器自身（`192.168.1.5`），lucky 跑在路由器上时就是它。

### 让 LuCI 日志显示真实 IP

uhttpd 把 **socket 对端**当作客户端地址，而且只向处理程序导出固定的一组请求头
（`ACCEPT` / `AUTHORIZATION` / `COOKIE` / `HOST` / `REFERER` / `USER_AGENT` 等），
**没有** `X-Forwarded-For` 或 `X-Real-IP`。所以反代之后的 LuCI 只能看到代理自己。

本包安装时会执行 `clientblock-luci-realip`，只修改 `dispatcher.uc` 里**两行登录日志**，
把来源地址换成代理转发的地址；认证、路由、界面都不动。原文件备份在同目录
`dispatcher.uc.clientblock-orig`。

由于 uhttpd 拿不到转发头，代理需要把客户端地址写进它**确实会导出**的
`X-HTTP-Method-Override`（LuCI 不用这个头）：

```
lucky → Web服务 → openwrt 规则 → 高级设置
  追加客户端协议头到指定Header  = 开
  自定义Header Key             = X-HTTP-Method-Override
```

**防伪造**：lucky 只在该头不存在时写入，客户端可以自带。所以 LuCI 侧只有在
`/proc/net/nf_conntrack` 里确实存在该地址的连接时才采信，否则退回代理地址。

**LuCI 升级会覆盖 `dispatcher.uc`**。升级后「设置 → 健康检查」会显示
`luci_realip: not applied`，执行一次即可恢复：

```sh
lua /usr/libexec/clientblock-luci-realip && /etc/init.d/uhttpd restart
```

## 封禁分类

地址表上方是一排分类筛选，点一下只看该类：

| 分类 | 来源 |
|---|---|
| **订阅** | 订阅拉取的地址，行内标签直接显示订阅名 |
| **SSH 爆破** | dropbear 登录失败达阈值后自动封禁 |
| **Web 爆破** | LuCI / uhttpd 登录失败达阈值后自动封禁 |
| **自动封禁** | 自动封禁但日志来源无法归到上面两类 |
| **手动** | 界面或命令行手动添加 |
| **定时** | 定时封禁 / 宵禁触发 |
| **紧急** | 紧急封锁期间加入 |
| **历史导入** | 从 luci-app-watchdog 迁移 |

计数在分类标签上，`19 / 484` 表示当前分类 19 条、总计 484 条。分类筛选在服务端完成，
所以订阅里有几千条时也只传当前页。空分类会置灰显示，便于知道有哪些分类可用。

## 信任模型

**局域网设备默认全部信任**，不会被任何自动动作误封：

- 当前在线设备会写入「已知设备」基线（`known_devices.json`）
- 新上线设备不在基线内 → 标记 `新设备`，等待你处理：
  - **允许**：加入基线，之后不再提示
  - **封禁**：正常封禁
- 「仅封禁新设备」只影响未确认的设备，已信任设备**永远不会**被它波及
- 白名单（`whitelist.json`）仍然存在，用于保护绝不能封的设备

## 概览（默认首页）

打开插件先看到的是汇总，**不列出任何设备地址**：

- 四个指标卡：在线设备、已封禁设备、封禁 IP、今日登录失败
- 防护状态：自动防护阈值、自动封禁数量、定时规则、分组、端口限制、通知渠道
- 今日与近 24 小时登录统计
- 健康摘要（失败时列出具体项）
- 最近活动（只显示类型与结果，不含 IP）

需要看明细时再切到「设备」或「登录日志」。

## 临时封禁

设备行提供时长选择：`永久 / 1 小时 / 8 小时 / 到明早 08:00`。
临时封禁带 `expires` 字段，由常驻服务每分钟扫描，到期自动解封并可选推送通知。
永久封禁不带该字段，永远不会被自动解除。

## 分组与宵禁

在 **定时封禁 → 分组与宵禁** 里新建分组（如 `Kids`、`IoT`），用多选框勾选成员。

- **宵禁**：把整组封到次日 08:00，来源标记为 `curfew`
- 与临时封禁共用同一套到期引擎，到点自动恢复

## 端口限制

在 **设备 → 端口限制** 里添加规则：设备 + 协议 + 端口。

```
ether saddr <MAC> tcp dport 445 counter drop
```

典型用法：让 IoT 设备只能上网，不能访问 NAS 的 SMB(445)、路由器的 telnet(23)。
与整机封禁不同，端口限制只断特定服务。

## 通知

支持三种渠道，各自独立，某个渠道失败不影响动作本身：

| 渠道 | 配置 |
|---|---|
| Telegram | Bot Token + Chat ID |
| Bark | 完整推送 URL，如 `https://api.day.app/KEY` |
| Webhook | 任意 URL，POST JSON：`{event,title,body,ts}` |

可订阅的事件：**自动封禁**、**新设备上线**、**封禁到期**。每个渠道有「测试」按钮。
新设备检测首次运行时会静默建立基线，不会把已有设备全部报成新设备。

## 健康检查

八项实时检查，失败时直接给出修复命令：

服务进程 · 日志管道 · 生成的规则 · 内核 IP 集合 · 防火墙规则 ·
归属地库 · 状态存储 · 自动防护

外加 **端到端探针**：写一条伪造登录行，等 watcher 记录后再删除。
这是唯一能证明「syslog → 存储」整条链路可用的检查。

## 中文界面

界面已提供完整中文翻译（154 条），随 `luci-i18n-clientblock-zh_Hans` 包发布：

```sh
apk add --allow-untrusted ./luci-i18n-clientblock-*_zh_Hans.apk
```

未安装时界面回退到英文，不影响功能。

## 已知限制

**局域网内设备之间的二层直连流量**由交换机完成，不经过路由器的 IP 栈，因此无法拦截。

拦截对「上网 / 网关 / DNS / DHCP」四类完全有效。

> 若要完全隔离到 L2，需要在 AP 或交换机上配置端口 ACL。

---

## 构建

CI 使用官方 OpenWrt SDK，`CONFIG_USE_APK=y` 生成 `.apk`。本地构建：

```sh
# 下载对应版本的 SDK，解压后
cd sdk
mkdir -p package/clientblock
cp -r /path/to/luci-app-clientblock/{Makefile,root,htdocs,postinst,prerm,postrm} package/clientblock/
echo 'CONFIG_USE_APK=y' >> .config
make defconfig
make package/clientblock/compile V=s
```

产物位于 `sdk/bin/packages/*/base/`。

---

## 许可

[Apache-2.0](LICENSE)
