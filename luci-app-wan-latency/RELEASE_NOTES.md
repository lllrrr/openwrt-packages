# luci-app-wan-latency v1.3.0

本版本新增可选的 HigoOS 原生界面集成，同时保持通用 OpenWrt 安装包不受影响。

## 发布文件

- `luci-app-wan-latency_1.3.0-1_all.ipk`：通用 LuCI 主包，适用于 OpenWrt、ImmortalWrt、iStoreOS 等。
- `luci-app-wan-latency-higoos_1.3.0-1_all.ipk`：可选 HigoOS 集成扩展，依赖通用主包。
- `luci-app-wan-latency-1.3.0-1.run`：自动识别 HigoOS 的一键安装器。
- `luci-app-wan-latency-1.3.0-1-source.zip`：完整源代码。

## HigoOS 集成

- 在“其他设置”中增加“公网延迟”标签。
- 原生显示当前探测接口、更新时间、目标延迟、探测方式和连续失败次数。
- 每 5 秒自动刷新，并可手动刷新。
- “打开完整图表”继续使用 LuCI 的鉴权页面，保留历史曲线、统计、目标管理和 CSV 导出功能。
- 扩展安装前严格检测 HigoOS 前端签名；非 HigoOS 系统会安全跳过。
- 扩展卸载时仅删除自身脚本标签和资源，不覆盖其他前端修改。

## 已验证环境

- Hiveton HigoOS H5000M
- ImmortalWrt 24.10-SNAPSHOT / Linux 6.6 / aarch64_cortex-a53
- 通用包升级安装、服务启动、实时探测及 LuCI 页面
- HigoOS 原生面板实时数据展示

安装前请使用 `SHA256SUMS` 校验下载文件。
