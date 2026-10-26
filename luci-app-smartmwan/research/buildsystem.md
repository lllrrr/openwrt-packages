# OpenWrt 25.12 构建与打包审计要点

> **来源与可信度声明**：同 `research/luci.md`，这是把早前一次上游源码审计（`openwrt.git` 的
> `include/`、`package/`，以及 ImmortalWrt 的 `openwrt-25.12` 分支）压缩成的笔记。
> **执行 M9 打包前必须在真实 SDK 里复核**：文件是否仍存在、宏名是否有变、apk 元数据字段要求。
> 本环境（云沙箱）没有 OpenWrt SDK，也没有 `make` 构建固件的能力。

## 1. 包产物已是 apk，不再是 ipk

* 25.12 起包管理器由 opkg 换为 apk（Alpine Package Keeper），
  源配置从 `/etc/opkg/distfeeds.conf` 变为 `/etc/apk/repositories.d/distfeeds.list`；
* 构建侧对应 `include/package-pack.mk`，产物扩展名 `.apk`；
* ImmortalWrt 的 25.12 分支同样切换到 apk ⇒ 一份 Makefile 可以同时服务两个发行版，
  但**包名与依赖声明要分别验证**（两家的 feeds 不同）。

对插件的要求：

1. 不得再用 opkg 的 `control`/`postinst-pkg` 老写法，维护脚本要走 apk 的 hooks；
2. 卸载清理逻辑不能假设 `/usr/lib/opkg/info/*.list` 存在；
3. `no-lua-check.sh` 检查 Makefile 时按关键字匹配（`luci-lua-runtime`、`liblua`、`lua54`、
   `DEPENDS.*lua`、`luasrc`）—— 一旦 Makefile 落地，这条检查才真正有牙齿。

## 2. Rust 交叉编译

上游提供 `include/rust-package.mk`（`Build/Compile/rust`），典型用法：

```make
include $(INCLUDE_DIR)/rust-package.mk

MAKE_FLAGS += \
    CARGO_TARGET_$(CARGO_BUILD_TARGET)_LINKER="$(TARGET_CC)" \
    CARGO_FEATURES=...
```

要点：

* 目标三元组由工具链推导（`aarch64-openwrt-linux-gnu`、`x86_64-openwrt-linux-gnu`、
  `armv7-openwrt-linux-gnueabi` 等），**不要硬编码**；musl 与 glibc 要分别处理；
* `cargo` 需要 `.cargo/config.toml` 指定 linker 与 `--offline`（构建机可能无网）；
* 依赖必须在 Makefile 的 `DEPENDS` 里显式声明，但**具体声明什么要由产物决定**：
  编好后用 SDK 的 `readelf -d` / 目标设备 `ldd` 看真实 soname 需求再写
  （Rust 通常只需系统 libc；是否额外需要 `libgcc`/`目标工具的 runtime` 取决于 musl/glibc 与链接方式）。
  凭印象写 `+libstdc++` 之类是错的 —— C++ 运行时与 Rust 无关；
* 可复现性：`Cargo.lock` 已入库，crate 版本固定；构建环境差异要记录在
  `docs/TESTING.md`（本机沙箱的 rustc 1.98.1 只是开发验证版本，不代表 SDK 版本）。

## 3. procd 服务

`root/etc/init.d/smartmwan` 用 procd 的 `service_load_script` + `start_service()` 风格：

* `use procd; procd_open_service / procd_set_param command / procd_close_service`；
* 关键参数：`respawn`（失败重启但有阈值）、`nice`、`TERM_TIMEOUT`（**优雅关停必须留足时间撤销内核对象**）、
  `file /var/run/smartmwan/rpc.sock`（依赖 socket 就绪）、`pidfile`；
* `enabled=0` 时服务应能启动但不改路由（真正的开关在 UCI 的 `global.enabled`），
  这样 `procd enabled` 与插件语义不冲突；
* 卸载时必须 `service_stop` + `service_disable`，然后由维护脚本删除自己的 nft 表与 `ip rule`。

## 4. nftables 安装机制（本插件的数据面入口）

* firewall4（ucode 实现，主表 `inet fw4`）在生成规则时会读取 UCI 的 include 段：

```text
config include 'smartmwan'
    option type 'nftables'
    option path '/etc/nftables.d/smartmwan.nft'
    option position 'after'          # 相对 fw4 自身包含的顺序
    option enabled '1'
```

* `/etc/nftables.d/*.nft` 里的内容会被拼进 fw4 的一次 `nft -f` 原子提交；
* 结论：插件**不需要**自己抢 hook，也**不需要**改 `/etc/config/firewall` 的规则段；
  只需在自己的 `inet smw` 表里放对象。写错 include 类型/位置会导致 fw4 启动失败，
  因此该文件必须由 `src/system/firewall.rs::include_file_text()` 生成（与代码同源），
  且只声明「确定可用的语法」（详见 `docs/HANDOVER.md` §3）。

## 5. menu.d 与 ACL JSON

* `usr/share/luci/menu.d/luci-app-smartmwan.json`：定义 `/admin/network/smartmwan` 层级与 7 个子页；
* `usr/share/rpcd/acl.d/luci-app-smartmwan.json`：给 LuCI 视图授权 rpcd 方法，
  读/写分离，粒度到方法名（`docs/SECURITY.md` §3）；
* 两者都是 JSON，不是 Lua —— 这是零 Lua 方案能成立的关键。

## 6. 需要真机/SDK 才能确认的开放项

| 项 | 为什么现在确认不了 |
|---|---|
| `rust-package.mk` 的确切宏名与 MAKE_FLAGS 形式 | 沙箱无 SDK 源码；凭记忆写会静默构建失败 |
| apk 维护脚本 hook 名称（pre/post install、upgrade） | apk 3.x 的 hook 约定需查上游 `apk` 包与 `package-pack.mk` |
| `PKGARCH` 与目标三元组的映射表 | 需在 SDK 里按 `CONFIG_TARGET_ARCH_PACKAGES` 实测 |
| LuCI 静态资源打包路径（`htdocs` → `/usr/lib/lua`?） | 25.12 已去 Lua，路径规则要在真实 luci-base 里核对 |

处理方式：M9 动手前先在 SDK 中跑一次最小包构建（打印 `$(1)/install` 结果与产物名），
把结论回写本文件；不允许「按 21.x/22.x 的印象」直接写 Makefile。
