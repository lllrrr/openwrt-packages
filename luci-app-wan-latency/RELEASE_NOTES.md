# luci-app-wan-latency v1.4.1

修复浏览器黑暗模式下历史折线图仍显示白色背景的问题。

## 更新内容

- 去掉 Canvas 绘图区的固定白色填充，改为透明背景，跟随图表面板显示。
- 更新内嵌页面的缓存版本，刷新后加载新界面。
- README 新增 ImmortalWrt CPE 暗色模式实机截图。
- 保留 v1.4.0 的实时仪表盘、历史曲线、目标管理和设置功能。

## 发布文件

- `luci-app-wan-latency_1.4.1-1_all.ipk`：通用 LuCI 主包。
- `luci-app-wan-latency-1.4.1-1.run`：内含该 IPK 的自解压安装器。
- `luci-app-wan-latency-1.4.1-1-source.zip`：源代码快照。
- `SHA256SUMS`：上述三个文件的 SHA-256 校验值。

## 验证

- ImmortalWrt 24.10-SNAPSHOT / aarch64 CPE：页面文件部署、服务运行与实时采集正常；附实机暗色模式截图。
- 发布包校验与实时界面自动化检查通过。

安装前请使用 `SHA256SUMS` 校验下载文件。升级保留已有配置、目标列表和历史数据。
