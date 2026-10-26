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
