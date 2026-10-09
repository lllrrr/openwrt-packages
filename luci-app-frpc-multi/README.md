**简体中文** | [English](README.en.md)

# luci-app-frpc-multi

OpenWrt / iStoreOS 的 LuCI 多连接 frp 客户端。每个连接对应一个独立的 `frpc` 进程，可同时连接多个 frp 服务端，并在页面里统一查看状态、日志和启停。

## 安装

以 root 身份运行：

```sh
wget -O /tmp/install-frpc-multi.sh https://raw.githubusercontent.com/myc2002/luci-app-frpc-multi/main/install.sh && sh /tmp/install-frpc-multi.sh
```

支持 apk 和 opkg，架构为 ARM64 或 x86_64。安装完成后打开 **LuCI → 服务 → frp 多客户端**。

安装脚本会校验安装包，并通过系统软件源安装依赖。如果系统自带的 `frpc` 版本过旧、不支持 TOML 配置，会自动下载官方 0.66.0，放在 `/usr/lib/frpc-multi/frpc` 供本插件单独使用，不会覆盖 `/usr/bin/frpc`。

也可以到 [Releases](https://github.com/myc2002/luci-app-frpc-multi/releases) 手动下载安装包：APK 用 `noarch.apk`，opkg 用 `all.ipk`，并用 `SHA256SUMS` 校验。手动安装不会处理旧版 `frpc` 的问题。

## 功能

- 每个连接独立运行，互不影响，崩溃后自动重启，另有每分钟看门狗
- 支持 tcp、udp、http、https、tcpmux、stcp、xtcp、sudp
- 令牌、TLS、协议、多路复用、连接池、心跳、DNS、出口代理、带宽限制、加密、压缩
- HTTP 域名与认证、visitor，以及 http_proxy、socks5、static_file、unix_domain_socket 插件
- 状态卡片显示连接、代理在线情况和错误信息，可单独重启、停用、查看日志
- 保存配置后只重启有变化的连接

连接数量没有固定上限，实际取决于设备资源；状态接口使用 27400–27999 范围内的本地端口。

## 使用

1. 点击「添加连接…」，填写名称、服务端地址、端口和令牌。
2. 点击「添加代理…」，选择所属连接，填写本地地址和远程端口。
3. 保存并应用，在运行状态里确认连接和代理在线。

提示：

- TLS 默认开启，需与服务端设置一致。
- 页面里的「停用」会持久保存；用命令行 `stop` 停止的连接可能被看门狗重新拉起。
- 本插件不会改动其他 frp 插件，也不会修改防火墙，需自行放行相关端口。
- 配置文件 `/etc/config/frpc_multi` 含令牌，权限为 600；升级会保留配置，卸载不会删除。

## 常用命令

```sh
/etc/init.d/frpc-multi checkconfig [ID]   # 检查配置
/etc/init.d/frpc-multi restart [ID]       # 重启
/etc/init.d/frpc-multi reload             # 重新加载
apk del luci-app-frpc-multi               # 卸载，opkg 用 opkg remove
```

## 构建

```sh
sh build-release-matrix.sh
```

生成 `noarch` APK 和 `all` IPK 以及 `SHA256SUMS`。构建 APK 需要 Docker，或用 `APK_MKPKG` 指定本地 apk v3 工具。`tests/` 下有安装器和打包的测试脚本。

## 许可证

新增代码采用 Apache-2.0。init 脚本沿用了 OpenWrt FRPC 包的部分实现，按其 GPL-2.0 处理，详见 `NOTICE` 和 `LICENSES/`。frp 本身是独立依赖，不包含在本包中。
