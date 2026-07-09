# luci-app-usbmodem

**USB 3G/4G/5G 调制解调器管理插件** — 适用于 OpenWrt / LEDE 固件。

支持 **NCM / ECM / QMI / RNDIS** 四种上网模式，提供 Web 管理界面、AT 指令终端和短信推送功能。

---

## ✨ 功能特性

### 📶 多模式上网
- **NCM** — CDC NCM（华为、中兴等多数 4G/5G 模块默认模式）
- **ECM** — CDC Ethernet（部分老旧模块）
- **QMI** — Qualcomm MSM Interface（高通芯片模块）
- **RNDIS** — Windows 网络共享模式

### 🖥️ LuCI Web 界面
- **状态页** — 实时显示信号强度、运营商、SIM 卡状态、IP 地址、连接速率等
- **AT 命令页** — 内置常用 AT 指令一键发送，也支持自定义命令
- **设置页** — 切换上网模式、配置 Bark 短信推送

### 📱 短信推送（Bark）
- 后台自动轮询未读短信
- 通过 **Bark** 推送至 iOS 设备
- 读取后自动删除模块短信

### 🔧 后台服务
- 开机自启，自动检测 USB 网络接口
- 自动配置防火墙、WAN 口和 DHCP

---

## 📋 目录结构

```
luci-app-usbmodem/
├── Makefile                     # 编译配置文件
├── LICENSE                      # 许可证
├── README.md                    # 本文件
└── root/
    ├── etc/
    │   ├── config/
    │   │   └── usbmodem         # UCI 配置文件（默认参数）
    │   ├── init.d/
    │   │   └── usbmodem         # 开机启动脚本 (procd)
    │   └── uci-defaults/
    │       └── 99-usbmodem      # 首次安装初始化配置
    └── usr/
        ├── bin/
        │   ├── usbmodem_detect      # 自动探测 USB 接口和协议
        │   ├── usbmodem_switch      # 切换上网模式
        │   ├── usbmodem_at          # 发送 AT 指令
        │   └── usbmodem_sms_monitor # 短信监控 + Bark 推送
        └── lib/lua/luci/
            ├── controller/
            │   └── usbmodem.lua      # LuCI 控制器（路由 + API）
            ├── model/cbi/
            │   └── usbmodem.lua      # 设置页表单模型
            └── view/usbmodem/
                ├── status.htm        # 状态页模板
                └── at.htm            # AT 命令页模板
```

---

## 🚀 编译方法

### 作为 OpenWrt 源码包编译

```bash
# 1. 将插件复制到 package 目录
git clone https://github.com/1391959853/luci-app-usbmodem.git
cp -r luci-app-usbmodem <openwrt_root>/package/fcm/luci-app-usbmodem

# 2. 更新 feeds
cd <openwrt_root>
./scripts/feeds update -a
./scripts/feeds install luci-app-usbmodem

# 3. 配置
make menuconfig
# 在 LuCI → 3. Applications → luci-app-usbmodem 选中（按 M 编译为模块）

# 4. 编译
make package/fcm/luci-app-usbmodem/compile V=s
```

### 使用 OpenWrt SDK 编译

```bash
# 下载对应平台的 SDK：
# https://downloads.openwrt.org/releases/

# 将插件放入 SDK 的 package/ 目录
cp -r luci-app-usbmodem <sdk_root>/package/

# 配置并编译
cd <sdk_root>
echo "CONFIG_PACKAGE_luci-app-usbmodem=m" >> .config
make defconfig
make package/luci-app-usbmodem/compile V=s
```

> **提示：** 编译产物在 `bin/packages/<架构>/luci/` 或 `bin/packages/<架构>/base/` 下。
> OpenWrt 24.10 及之前输出 `.ipk`，25.x 开始输出 `.apk`。

---

## 📥 安装方法

### 从编译产物安装

```bash
# OpenWrt 24.10 及之前（IPK 格式）
opkg install luci-app-usbmodem_1.0.2-r1_all.ipk

# OpenWrt 25.06 及之后（APK 格式）
apk add luci-app-usbmodem-1.0.2-r1.apk
```

### 启用服务

```bash
/etc/init.d/usbmodem enable
/etc/init.d/usbmodem start
```

### 卸载

```bash
# IPK
opkg remove luci-app-usbmodem

# APK
apk del luci-app-usbmodem
```

---

## ⚙️ 配置说明

安装后在 LuCI 后台路径：
```
网络 → USB Modem
```

### 设置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 默认模式 | `ncm` | 插入 USB 模块后自动切换的网络模式 |
| Bark Token | 空 | iOS Bark App 的设备令牌 |
| Bark 服务地址 | `https://api.day.app` | Bark 推送服务器（可自建） |
| 启用 Bark | 开启 | 是否启用短信推送 |

### 手动 UCI 配置

```bash
uci set usbmodem.settings.mode='qmi'
uci set usbmodem.settings.bark_token='YOUR_BARK_TOKEN'
uci commit usbmodem
/etc/init.d/usbmodem reload
```

---

## 🛠️ 命令工具

### usbmodem_detect
自动探测 USB 网络接口和 AT 串口。

```bash
/usr/bin/usbmodem_detect
# 输出: {"iface":"wwan0","protocol":"ncm","at_port":"/dev/ttyUSB0"}
```

### usbmodem_switch
切换上网模式。

```bash
/usr/bin/usbmodem_switch ncm
/usr/bin/usbmodem_switch qmi
```

### usbmodem_at
发送 AT 指令到模块。

```bash
/usr/bin/usbmodem_at 'AT+CSQ'        # 查询信号强度
/usr/bin/usbmodem_at 'AT+CGSN'       # 查询 IMEI
/usr/bin/usbmodem_at 'AT+COPS?'      # 查询运营商
```

---

## 🔧 依赖

| 包名 | 说明 |
|------|------|
| `luci-base` | LuCI 核心 |
| `luci-compat` | LuCI 兼容层 |
| `kmod-usb-net` | USB 网络支持 |
| `kmod-usb-net-cdc-ncm` | NCM 协议驱动 |
| `kmod-usb-net-cdc-ether` | ECM 协议驱动 |
| `kmod-usb-net-qmi-wwan` | QMI 协议驱动 |
| `kmod-usb-net-rndis` | RNDIS 协议驱动 |
| `kmod-usb-serial` | USB 串口支持 |
| `kmod-usb-serial-option` | 华为/中兴等模块串口 |
| `kmod-usb-serial-wwan` | 无线广域网串口 |
| `usbutils` | lsusb 等 USB 工具 |
| `jshn` | JSON Shell 解析 |
| `jsonfilter` | JSON 过滤工具 |
| `chat` | 拨号聊天脚本 |
| `comgt` | 3G/4G 拨号工具 |
| `uqmi` | QMI 协议工具 |

---

## 📱 Bark 推送设置

1. iOS 安装 [Bark](https://apps.apple.com/app/id1403753865)
2. 复制 App 内显示的设备令牌
3. 在 LuCI 设置页填入 Token
4. 收到短信时将自动推送到 iOS

支持自建 Bark 服务器，修改 `Bark 服务地址` 配置项即可。

---

## 📄 许可证

GNU General Public License v2.0 or later

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。

原始仓库：https://github.com/1391959853/luci-app-usbmodem