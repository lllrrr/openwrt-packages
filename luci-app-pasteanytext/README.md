# luci-app-pasteanytext

一款可以在OpenWrt/ImmortalWrt上安装使用的文本剪贴板，可以在局域网使用，也可以在公网使用（如果你将LuCI WEB暴露在公网，但建议给LuCI WEB设置强密码）

使用场景举例：

- send on device A
- reveive on device B
- search items
- view history items
- click item and copy it's content

本程序只依赖 luci-base，由于是第一次开发编译和构建 openwrt ipk 插件，构建出来的 ipk 是架构无关的，我在（ImmortalWrt 24.10.1 on x86_64）上成功安装和使用，如有问题（如无法安装）欢迎提 issue 交流。

### 下载量统计

![GitHub release downloads](https://img.shields.io/github/downloads/hellodk34/luci-app-pasteanytext/v1.1-r4/total)

## 安装使用方法

事先将 release 中的 ipk 文件拷贝到系统，在正确目录执行以下命令安装

opkg install ./luci-app-pasteanytext_1.1-r4_all.ipk

重启 rpcd 服务后登录 LuCI WEB 查看“服务”目录下的 pasteanytext 即可使用

/etc/init.d/rpcd restart

## 界面截图

![pasteanytext文本传送ipk使用截图.jpg](https://image.940304.xyz/i/2026/03/24/69c237d1d5b89.jpg)
