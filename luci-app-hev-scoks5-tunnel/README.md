# luci-app-hev-scoks5-tunnel
hev-socks5-tunnel插件的luci界面
# [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)

## 概述

Hev Socks5 Tunnel 是一种轻量级的隧道服务，旨在通过 Socks5 代理路由流量。该项目提供了一个基于 Web 的配置界面，用于管理 `hev-socks5-tunnel` 服务，包括启用/禁用服务、配置 Socks5 服务器地址和端口，以及监控服务状态。

### 日志

不再使用sed命令。对hev-socks-tunnel的init脚本改写，让脚本根据UCI配置文件生成程序使用的yml配置文件。
界面、init脚本使用AI生成后进行了修改。

### 致谢

特别感谢 [luci-app-microsocks](https://github.com/immortalwrt/luci/tree/master/applications/luci-app-microsocks) 