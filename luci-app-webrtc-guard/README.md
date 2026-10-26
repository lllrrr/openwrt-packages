# luci-app-webrtc-guard

适配 OpenClash 的 WebRTC 公网 IP 防泄漏插件，使用 LuCI 原生界面。

插件检查真实 WAN 出口的 STUN 探测流量，覆盖设备直接转发和 OpenClash 的 DIRECT 出站，减少真实公网 IP 暴露的风险，不主动修改 OpenClash 分流配置。

## 功能

- 识别明文 UDP / TCP STUN，支持常见 STUN / TURN 端口辅助拦截
- 支持 IPv4 / IPv6、多 WAN 出口和设备直接转发白名单
- 自动管理流量卸载，避免加速路径绕过检查
- 查看防护状态、拦截次数和日志，可清空插件展示记录
- 规则校验通过后再加载，失败时保留原有规则并显示错误

## 环境要求

- OpenWrt / ImmortalWrt，使用 **fw4 / nftables** 和 LuCI
- 按系统包管理器选择安装包，不支持 fw3 / iptables
- 安装包均为纯脚本包，IPK 架构为 `all`，APK 架构为 `noarch`

| 系统包管理器 | 下载格式 |
| ------------ | -------- |
| `opkg`       | `.ipk`   |
| `apk`        | `.apk`   |

以固件实际使用的包管理器为准，两个格式不能互换，修改文件后缀也不能转换格式。

## 安装

从 [Releases](https://github.com/meesii/luci-app-webrtc-guard/releases/latest) 下载对应格式，上传到路由器后安装。

### IPK / opkg

```sh
opkg update
opkg install /tmp/luci-app-webrtc-guard_1.2.3-1_all.ipk
```

也可以使用 LuCI 的“系统 → 软件包 → 上传软件包”安装 IPK。

### APK / apk

依赖已安装齐全时，可离线安装，避免安装过程刷新软件源：

```sh
apk --no-network --repositories-file /dev/null add --allow-untrusted /tmp/luci-app-webrtc-guard-1.2.3-r1.apk
```

手工构建的 APK 未使用发行版私钥签名，需核对 Release 中的 SHA256 后再安装；上述签名例外仅用于本次安装，不修改全局信任设置。缺少依赖时需先补齐依赖，使用 LuCI 上传安装也需要允许未签名包。

### 开启防护

进入 **服务 → WebRTC 防泄漏**，开启防护。首次安装默认关闭，通常保留默认设置即可；升级后若仍显示旧页面，按 `Ctrl + F5` 刷新。

> 已安装旧包 `luci-app-webrtc-control` 时，请先备份 `/etc/config/webrtc-control`，停用并移除旧包，再安装新包、恢复配置并启用。新旧包不能同时安装，迁移期间防护会短暂停用。

## 使用说明

- **总览**：查看运行状态、拦截次数，开启或关闭防护
- **设置**：基本设置、高级设置和设备例外，均使用 LuCI 原生控件
- **日志**：查看最近的拦截记录；清空记录不会删除系统日志或重置拦截次数

默认仅检查真实上网出口。多 WAN 环境应补全出口区域或接口，不要将 OpenClash 隧道填写为真实出口。

设备白名单只作用于直接转发的连接；OpenClash 重新建立的出站连接仍受防护。日志目前显示 IP 和端口，不能据此准确还原发起 WebRTC 的网页域名。

## 注意事项

- 防护可能影响依赖 STUN 的语音、视频通话和部分 P2P 服务
- 默认关闭软件及硬件流量卸载，可能降低最高转发速度；停用防护时按记录恢复，检测到其他修改则不覆盖
- 不能保证识别加密 STUN / TURN、自定义隧道或跨 TCP 分段的协议头，也不控制未经过此路由器的出口
- 不能隐藏应用直接读取的局域网地址或网卡上已配置的公网 IPv6 地址

本插件用于降低泄漏风险，不承诺彻底禁用 WebRTC 或覆盖所有公网 IP 泄漏方式。

## 构建安装包

构建机器需要 Python 3.10 或更高版本，路由器不需要 Python。

```sh
python3 build.py --output dist
```

生成的 IPK 位于 `dist/luci-app-webrtc-guard_1.2.3-1_all.ipk`，构建脚本显式写入 Linux 文件权限，支持在 Windows 构建 IPK。

构建 APK 需要带有 `mkpkg` 命令的 apk-tools 3：

```sh
python3 build.py --output dist --apk-tool /path/to/apk-tools-3/apk
```

也可以将本项目加入 OpenWrt SDK / Buildroot，按标准 LuCI 包构建。

## 许可证与致谢

本项目基于 [bulb888/luci-app-webrtc-control](https://github.com/bulb888/luci-app-webrtc-control) 独立维护，采用 [GPL-3.0-or-later](LICENSE) 许可证。
