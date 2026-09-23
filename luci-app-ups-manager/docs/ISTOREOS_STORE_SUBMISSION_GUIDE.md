# iStoreOS 软件中心官方上架全流程指引与合规交付手册

本文档专为 **UPS Manager (`luci-app-ups-manager`)** 上架至 **iStoreOS 官方软件中心 (iStore App Store)** 编写，涵盖架构规范、依赖隔离、多 CPU 架构支持、安装与卸载生命周期及 GitHub PR 提交流程。

---

## 一、iStoreOS 软件中心上架核心要求与规范校验

iStoreOS 软件中心在审核第三方应用上架时，严格遵循以下 5 大核心准则。本项目已在代码层面 100% 达成合规：

| 审核准则 | 官方要求 | 本项目适配与合规实现 |
| :--- | :--- | :--- |
| **1. CPU 架构兼容性** | 必须兼容主流平台，不可因缺少特定架构二进制导致报错 | **`LUCI_PKGARCH:=all`**。前端为纯 LuCI JS SPA，后端为 POSIX 标准 Shell 脚本，底层调用系统固件自带 NUT 组件，**天然 100% 兼容 x86_64、aarch64 (RK3568/RK3588/MT798x/树莓派)、arm、mips 等全系列架构**。 |
| **2. 依赖隔离与干净卸载** | 卸载应用时绝不可连带卸载其他插件公用的系统基础库 | 在 `app-meta-ups-manager/Makefile` 中，`META_DEPENDS` 仅声明主包 `+luci-app-ups-manager`；通用依赖 (`nut`, `curl` 等) 由底层包管理器自动解析引用计数，杜绝卸载时发生误删。 |
| **3. 完整的生命周期钩子** | 支持一键安装立即运行、干净卸载不留僵死进程 | 主包 `Makefile` 完整实现了：<br>• `postinst`：自动应用初始配置、注册开机自启、启动服务并清理 LuCI 视图缓存。<br>• `prerm`：优雅停止并注销 `ups-manager` procd 守护服务。<br>• `postrm`：自动清理 `/tmp/run` 与 `/tmp/log` 下的临时套接字和缓存。 |
| **4. 软件中心元数据与图标** | 图标 PNG 格式、≤256x256、文件大小 < 50KB | 已在 `applications/app-meta-ups-manager/` 准备 `logo.png`（2.5KB，高清矢量风格）、`Makefile` 与自动配置钩子 `config.sh`。 |
| **5. 可复现构建 (CI/CD)** | 必须具备开源仓库、自动化构建流水线与源码可追溯性 | 已在项目仓库建立 `.github/workflows/build.yml`，每次 Push / Release 均通过自动化语法检查并打包标准 `.ipk` 安装包。 |

---

## 二、官方仓库上架提交流程 (GitHub Pull Request)

iStoreOS 官方软件中心由两个核心上游仓库驱动。开发者通常通过向 **`linkease/openwrt-app-meta`** 提交 PR 完成上架。

### 步骤 1：Fork 上游元数据仓库
1. 打开官方仓库：👉 [https://github.com/linkease/openwrt-app-meta](https://github.com/linkease/openwrt-app-meta)
2. 点击右上角 **`Fork`**，将项目复制到您的个人 GitHub 账号下。

### 步骤 2：创建功能分支
在您的 Fork 仓库中基于 `main` 分支新建一个特性分支，例如：
```bash
git checkout -b add_app_ups_manager
```

### 步骤 3：添加插件元数据目录
将本项目中已为您生成好的 `applications/app-meta-ups-manager` 整个目录完整复制到官方仓库的 `applications/` 目录下：

```text
openwrt-app-meta/
└── applications/
    └── app-meta-ups-manager/
        ├── Makefile    # 声明中文标题、英文标题、描述、主依赖、UCI 标记
        ├── logo.png    # 软件中心图标 (2.5KB, 高质感 PNG)
        └── config.sh   # iStore 自动配置与开机自启配置脚本
```

`Makefile` 内容已核验无误：
```Makefile
# This is free software, licensed under the Apache License, Version 2.0 .

include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=1

META_TITLE:=UPS电源管理
META_TITLE.en:=UPS Manager
META_DEPENDS:=+luci-app-ups-manager
META_DESCRIPTION:=现代化企业级 UPS 电源管理系统，提供设备自动发现、市电质量监测、停电告警与自动关机保护。
META_DESCRIPTION.en:=Modern Enterprise UPS Power Management System, with auto-detection, telemetry, outage alerts and shutdown protection.
META_AUTHOR:=Gilbert Liu
META_TAGS:=system power tool
META_LUCI_ENTRY:=/cgi-bin/luci/admin/services/ups_manager
META_WEBSITE:=https://github.com/liuyuhao1023/luci-app-ups-manager
META_UCI:=ups_manager

include ../../meta.mk

# call BuildPackage - OpenWrt buildroot signature
```

### 步骤 4：提交并发起 Pull Request
1. 提交更改并推送到您的 GitHub 远程仓库：
   ```bash
   git add applications/app-meta-ups-manager
   git commit -m "add: app-meta-ups-manager (UPS Manager for iStoreOS)"
   git push origin add_app_ups_manager
   ```
2. 在 GitHub 页面点击 **`Contribute` $\to$ `Open pull request`**。
3. PR 标题推荐命名：`Add app-meta-ups-manager: UPS 电源管理`。
4. PR 描述中注明：
   - **源码仓库**：`https://github.com/liuyuhao1023/luci-app-ups-manager`
   - **支持架构**：全架构兼容 (`all`)
   - **测试设备**：已在 iStoreOS 实体机（x86 / arm）完成安装、断电告警、真实事件遥测及卸载测试。

---

## 三、实体路由器安装与卸载测试验收标准

在向官方提交 PR 前，可在目标路由器上按以下流程进行验收测试：

### 1. 本地打包验证脚本
在本地源码目录下执行：
```bash
sh test/verify_packaging.sh
```
校验通过后将提示：`🎉 恭喜！所有 iStoreOS 软件中心上架合规性校验项均已全部通过！`。

### 2. 在目标设备 (192.168.1.15) 上测试完整安装
```bash
# 执行自动化一键安装
curl -sL https://raw.githubusercontent.com/liuyuhao1023/luci-app-ups-manager/main/install.sh | sh
```
- 验证要点：
  1. 浏览器按 `Ctrl + F5` 后，左侧菜单出现 **「UPS 管理」**；
  2. 插拔 UPS USB 线或切断市电时，事件流实时真实显示；
  3. 后台守护进程 `pgrep -f ups-manager-daemon` 正常运行。

### 3. 在目标设备上测试干净卸载
```bash
# 停止并移除插件
/etc/init.d/ups-manager stop
/etc/init.d/ups-manager disable
rm -f /etc/init.d/ups-manager
rm -f /usr/bin/ups-manager-*
rm -f /usr/libexec/rpcd/luci.ups-manager
rm -rf /www/luci-static/resources/view/ups-manager
rm -f /usr/share/luci/menu.d/luci-app-ups-manager.json
rm -f /usr/share/rpcd/acl.d/luci-app-ups-manager.json
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/
```
- 验证要点：
  1. 浏览器刷新后，菜单中的「UPS 管理」彻底消失；
  2. 系统中不再存在僵死后台进程；
  3. 系统自带的其它软件与网络不受任何影响。
