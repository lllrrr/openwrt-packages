# luci-app-wizard

> 免责声明：本项目仅供个人学习、研究和自用备份。源码提取自个人设备运行环境，不用于商业用途。如涉及侵权或不当发布，请联系删除。

`luci-app-wizard` 是一个适用于 QWRT / OpenWrt / LEDE 系统的 LuCI 初始化设置向导插件。

这个源码是从一台正在运行的 QWRT 路由器中提取并整理成标准 OpenWrt 包结构的版本，可以放入 OpenWrt/QWRT SDK 或源码树中编译成 `.ipk` 安装包。

## 插件用途

该插件用于在路由器初次进入 LuCI 后，引导用户完成基础初始化设置，例如：

- 欢迎页
- 管理员密码设置
- 上网方式设置
- 无线网络设置
- 完成初始化

它适合用于定制固件、恢复出厂后的首次配置流程，或者作为 QWRT 固件的一键向导页面。

## 主要特性

- 提供 LuCI 初始化向导流程
- 支持多步骤向导页面
- 可以设置管理员密码
- 可以设置上网方式
- 可以设置无线网络参数
- 可以标记初始化是否完成
- 支持从系统菜单重新启动向导
- 包含 `/etc/config/wizard` 默认配置
- 包含 `/rom/etc/config/wizard` 恢复模板
- 纯 Lua + 配置文件实现，无需交叉编译 C 程序
- `.ipk` 架构无关，适合不同 CPU 架构的 OpenWrt/QWRT 设备

## LuCI 页面路径

安装后插件会注册以下 LuCI 路径：

```text
/admin/wizard/welcome
/admin/wizard/password
/admin/wizard/network
/admin/wizard/wireless
/admin/wizard/final
```

系统菜单中的重新启动向导路径：

```text
/admin/system/wizard
```

常见访问地址示例：

```text
http://192.168.1.1/cgi-bin/luci/admin/wizard/welcome
http://192.168.1.1/cgi-bin/luci/admin/system/wizard
```

如果你的路由器管理地址是 `192.168.100.1`，则访问：

```text
http://192.168.100.1/cgi-bin/luci/admin/wizard/welcome
```

## 源码结构

```text
luci-app-wizard/
├── Makefile
├── README.md
├── luasrc/
│   ├── controller/
│   │   └── wizard.lua
│   └── model/
│       └── cbi/
│           └── wizard/
│               ├── final.lua
│               ├── network.lua
│               ├── password.lua
│               ├── welcome.lua
│               └── wireless.lua
└── root/
    ├── etc/
    │   └── config/
    │       └── wizard
    └── rom/
        └── etc/
            └── config/
                └── wizard
```

## 文件说明

### `luasrc/controller/wizard.lua`

LuCI 控制器文件，负责注册向导入口和跳转逻辑。

主要功能：

- 注册 `/admin/wizard` 向导入口
- 注册欢迎页、密码页、网络页、无线页、完成页
- 判断 `/etc/config/wizard` 是否存在
- 判断向导是否已经完成
- 提供重新启动向导功能
- 将 `/admin/system/admin` 重定向到向导页面

其中重新启动向导会执行：

```sh
cp -f /rom/etc/config/wizard /etc/config/wizard
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```

也就是说，重新启动向导时会用 `/rom/etc/config/wizard` 覆盖 `/etc/config/wizard`，并清理 LuCI 缓存。

### `luasrc/model/cbi/wizard/welcome.lua`

欢迎页，通常用于展示初始化说明，并引导用户进入下一步。

### `luasrc/model/cbi/wizard/password.lua`

管理员密码设置页面。

一般用于设置 root / LuCI 管理密码，避免设备首次使用时仍处于默认密码状态。

### `luasrc/model/cbi/wizard/network.lua`

上网方式设置页面。

通常用于设置 WAN 口连接方式，例如：

- DHCP 自动获取
- PPPoE 拨号
- 静态 IP

具体支持哪些模式取决于原固件中的 CBI 脚本实现。

### `luasrc/model/cbi/wizard/wireless.lua`

无线网络设置页面。

通常用于设置无线 SSID、加密方式、密码等参数。

### `luasrc/model/cbi/wizard/final.lua`

完成页。

通常用于标记初始化流程完成，并写入：

```text
wizard.config.finished=1
```

当 `finished=1` 后，控制器中的逻辑会隐藏初始化向导入口。

### `root/etc/config/wizard`

运行时配置文件，会被安装到：

```text
/etc/config/wizard
```

用于记录当前向导状态，例如：

```text
config wizard 'config'
    option step 'final'
    option finished '1'
```

### `root/rom/etc/config/wizard`

恢复模板文件，会被安装到：

```text
/rom/etc/config/wizard
```

当用户点击重新启动向导时，系统会将该文件复制到 `/etc/config/wizard`，用于恢复向导状态。

## 编译方法

将源码目录复制到 OpenWrt/QWRT 源码树或 SDK 的 `package/` 目录：

```sh
cp -r luci-app-wizard package/
```

然后执行：

```sh
make menuconfig
```

在菜单中选择：

```text
LuCI -> Applications -> luci-app-wizard
```

编译：

```sh
make package/luci-app-wizard/compile V=s
```

编译完成后，`.ipk` 文件通常位于：

```text
bin/packages/*/base/
```

或 LuCI 相关 packages 输出目录中，具体路径取决于你的 SDK / 源码树配置。

## 安装方法

将生成的 `.ipk` 上传到路由器，然后执行：

```sh
opkg install luci-app-wizard_*.ipk
```

如果 LuCI 有缓存，可以执行：

```sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart
```

## 重新启动向导

安装后可通过 LuCI 访问：

```text
/admin/system/wizard
```

也可以手动执行等效操作：

```sh
cp -f /rom/etc/config/wizard /etc/config/wizard
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```

然后重新进入：

```text
/admin/wizard/welcome
```

## 注意事项

- 本插件源码来自正在运行的 QWRT 路由器，部分逻辑可能依赖该固件环境。
- 如果移植到标准 OpenWrt，可能需要检查 `network.lua`、`wireless.lua` 中调用的 UCI 配置是否与目标固件一致。
- 该插件只提供初始化向导页面，不负责底层驱动、无线驱动或拨号程序本身。
- 重新启动向导会覆盖 `/etc/config/wizard`，但通常不会直接重置整个网络配置。
- 如果想让向导在首次登录 LuCI 时强制弹出，需要结合固件登录流程或控制器重定向逻辑。

## 适用场景

- QWRT 固件定制
- OpenWrt/LEDE 初始化向导
- 路由器首次设置流程
- 刷机后快速配置页面
- 固件打包时集成一键设置向导

## 许可证

该源码为从设备中提取整理的 LuCI 插件源码，具体许可证请以原固件或原作者说明为准。
