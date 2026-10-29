# 流量接管与配置维护

流量接管页直接保存开关与协议模式。TCP 可选自动重定向、TUN、不接管；UDP 可选 TUN、不接管。当前接管 IPv4，IPv6 尚未接管。只有实际路由到本旁路由的流量才会被处理；客户端默认网关仍在主路由时，插件无法接管绕开的连接。

下载的订阅文件保留原样，启动时使用 yq 生成独立运行配置。TUN 使用 Mihomo 自动路由与自动重定向，局域网地址绕过，并启用域名嗅探。TCP/UDP 不接管使用独立、可清理的 IPv4 协议策略路由。启动失败会撤回接管开关。手动停止或切换模式时清理 TidyNet 的协议旁路规则。

订阅管理支持上传完整 Mihomo/Clash YAML（不超过 20 MB）。后台先校验配置及控制器地址，再保存为本地配置；应用时不重新下载。本地配置可改名、删除或应用，更新文件应重新上传。

远程订阅卡片支持手动更新和单独设置自动更新周期（每 6、12、24、48 或 168 小时）；默认手动更新。定时任务复用 TidyNet 后台 RPC，下载或校验失败时保留上次有效配置。本地上传的配置没有订阅地址，不显示自动更新周期。

广告过滤卡片展示合并后的规则条数。规则源可选手动、每小时、每 6 小时、每 12 小时或每天 04:00 更新。定时任务复用后台锁，保留其他 crontab 条目。更新周期适用于现有广告/DNS 过滤规则源，不是 DNS 上游服务器地址。

GEO 更新通过 Mihomo 官方 `/configs/geo` 接口完成，使用当前配置的 GEO 下载地址，成功后记录更新时间。它与规则源更新分开管理。

## 参考方案

- [Nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)：运行配置混入、接管生命周期与依赖管理的架构参考；TidyNet 不依赖 Nikki。
- [Mihomo TUN 文档](https://wiki.metacubex.one/config/inbound/tun/)：自动路由、自动重定向与协议栈。
- [Mihomo API](https://wiki.metacubex.one/api/)：GEO 更新。
- [sing-box 上游问题 #4316](https://github.com/SagerNet/sing-box/issues/4316)：nftables 对到达地址空间末端的排除网段可能返回 EEXIST。此实现避免将 240.0.0.0/4、ff00::/8 写入自动重定向排除集合，已在当前 ImmortalWrt 内核实测。

实现代码为 TidyNet 的独立实现，采用项目的 GPL-3.0-or-later 许可。
