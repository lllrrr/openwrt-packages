<!-- plugin-list: zh w9315273/luci-app-pulse -->
<table>
  <tr><th colspan="3">我的插件列表</th></tr>
  <tr valign="top">
    <td><a href="https://github.com/w9315273/luci-app-pulse"><img src="https://img.shields.io/github/stars/w9315273/luci-app-pulse?style=flat&amp;label=%E2%98%85&amp;color=57606a" height="16" alt="LuCI Pulse · GitHub 星数"></a></td>
    <td><strong>LuCI Pulse</strong></td>
    <td width="360"><details><summary>系统监控</summary><a href="https://raw.githubusercontent.com/w9315273/luci-app-pulse/HEAD/docs/screenshot-zh-cn.png"><img src="https://raw.githubusercontent.com/w9315273/luci-app-pulse/HEAD/docs/screenshot-zh-cn.png" width="100%" alt="LuCI Pulse · 界面截图"></a></details></td>
  </tr>
  <tr valign="top">
    <td><a href="https://github.com/w9315273/luci-app-adguardhome"><img src="https://img.shields.io/github/stars/w9315273/luci-app-adguardhome?style=flat&amp;label=%E2%98%85&amp;color=57606a" height="16" alt="AdGuard Home for LuCI · GitHub 星数"></a></td>
    <td><strong><a href="https://github.com/w9315273/luci-app-adguardhome">AdGuard Home for LuCI</a></strong></td>
    <td width="360"><details><summary>AdGuard Home 管理</summary><a href="https://raw.githubusercontent.com/w9315273/luci-app-adguardhome/HEAD/docs/screenshots/base-zh-cn.png"><img src="https://raw.githubusercontent.com/w9315273/luci-app-adguardhome/HEAD/docs/screenshots/base-zh-cn.png" width="100%" alt="AdGuard Home for LuCI · 界面截图"></a></details></td>
  </tr>
  <tr valign="top">
    <td><a href="https://github.com/w9315273/openwrt-traffic-stats"><img src="https://img.shields.io/github/stars/w9315273/openwrt-traffic-stats?style=flat&amp;label=%E2%98%85&amp;color=57606a" height="16" alt="OpenWrt Traffic Stats · GitHub 星数"></a></td>
    <td><strong><a href="https://github.com/w9315273/openwrt-traffic-stats">OpenWrt Traffic Stats</a></strong></td>
    <td width="360"><details><summary>设备流量统计</summary><a href="https://raw.githubusercontent.com/w9315273/openwrt-traffic-stats/HEAD/docs/images/overview.png"><img src="https://raw.githubusercontent.com/w9315273/openwrt-traffic-stats/HEAD/docs/images/overview.png" width="100%" alt="OpenWrt Traffic Stats · 界面截图"></a></details></td>
  </tr>
</table>
<!-- /plugin-list -->

# Pulse

### 轻量级 OpenWrt LuCI 仪表盘，集中展示系统资源、网络流量、网口与容器状态。

[English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md)

安装最新正式版：

```sh
uclient-fetch -O /tmp/install-pulse.sh https://raw.githubusercontent.com/w9315273/luci-app-pulse/main/install.sh && sh /tmp/install-pulse.sh
```

![Pulse 仪表盘](screenshot-zh-cn.png)

## 功能

- 实时网络流量与最近 1 分钟曲线
- CPU、内存、温度、连接数和磁盘用量
- 网口状态、协商速率、IP 地址与 DNS
- Docker 容器状态（可选）
- 明暗主题、移动端布局

> [!NOTE]
> - **采样**：网络每秒采样，系统指标与页面每 2 秒更新。最近 5 分钟历史保存在内存，关闭页面仍持续采集；路由器或采集服务重启后清空。
> - **接口**：自动优先选择 WAN，也可手动选择设备。物理设备统计其总流量，虚拟设备统计对应设备流量；上传为 TX，下载为 RX，选择 LAN 设备时方向可能与终端视角相反。
> - **累计流量**：来自所选设备计数器，不限于最近 5 分钟，也不是每日或每月统计；设备重建或计数器重置后重新累计。
> - **连接状态**：表示链路状态，不代表互联网连通性。
> - **按需显示**：可读取温度时显示温度卡片；磁盘默认展示根文件系统，并检测额外挂载磁盘；Docker 可用时显示容器状态，仅供查看，无需为本插件安装 Docker。
