<div align="center">

# WAN IP Selector

**一直重拨，直到公网 IP 落在你想要的网段**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-00B5E2)](https://openwrt.org/)
[![LuCI](https://img.shields.io/badge/LuCI-JS%20view-ff8c00)](https://github.com/openwrt/luci)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Language](https://img.shields.io/badge/UI-%E4%B8%AD%20%2F%20EN-lightgrey)](#界面语言)

简体中文 · [English](README-EN.md)

</div>

---

## 简介

有些运营商的公网 IP 来自多个不同的地址池，而这些池**并不等价**——落在哪个池里，直接影响国际路由、对等互联、延迟，有时甚至影响 NAT 行为和 MTU。重拨可以换一个池，但手动重拨再逐次核对地址，很快就会让人失去耐心。

WAN IP Selector 把这件事自动化：每次拨号完成后读取接口地址，与你配置的网段比对，不满意就自动重拨，直到拨中为止。

它**不绑定任何特定运营商或国家**——地址池由你自己填。

## 功能

**匹配**

- 支持任意逻辑接口（`wan` / `wan2` / PPPoE / DHCP 线路都行），不限于默认的 `wan`
- **包含模式**：只接受落在你列出的网段里的地址
- **排除模式**：接受除此之外的任意地址——用来**躲开**某几个烂池
- 网段可写 CIDR（`203.0.113.0/24`），也可以只写前缀（`203.0.113.` 或 `203.0`），自动展开为 `/24` 和 `/16`
- 可配多条，留空表示接受任意地址

**控制**

- 重试上限、重试间隔、拨号等待、冷却时间全部可配
- 支持**无限重试**（`max_attempts = 0`），拨不中就一直拨
- 两种触发方式：**接口 up 事件**（拨号完成立刻判断）+ **后台监听**（按秒数周期检查）
- 后台监听用来应对运营商**自己换 IP** —— 通常每隔几天一次，且未必产生接口事件
- LuCI 页面上也有手动按钮

**界面**

- LuCI 页面带**实时状态面板**，5 秒刷新，能看到当前地址、是否符合、已重拨几次
- 三个按钮：立即重拨 / 立即检查 / 停止并清锁
- 界面支持中文与英文

**实现**

- 后端是**纯 shell**，无 Python、无额外运行时，只依赖 OpenWrt 自带的 `jsonfilter`
- 装完约 20 KB
- 附带 70 项单元测试（地址匹配 28 项 + 翻译编译器 42 项）

## 安装

发布的是**两个包**，沿用 LuCI 官方 feed 的惯例：

| 包 | 作用 |
|---|---|
| `luci-app-wanip-selector` | 本体，界面为英文 |
| `luci-i18n-wanip-selector-zh-cn` | 简体中文界面 |

### 方式一：下载 ipk（推荐）

到 [Releases](https://github.com/System32X-code/luci-app-wanip-selector/releases) 下载，然后：

```sh
scp -P <端口> luci-*-wanip-selector*_all.ipk root@<路由器>:/tmp/
ssh -p <端口> root@<路由器> "opkg install /tmp/luci-app-wanip-selector_*.ipk /tmp/luci-i18n-wanip-selector-zh-cn_*.ipk"
```

只要英文界面的话，装本体那一个就够了。也可以在 LuCI 的 **系统 → 软件包** 里上传安装。

装完刷新页面（Ctrl+F5），菜单在 **网络 → WAN IP Selector**。

### 方式二：自己打包

不需要 OpenWrt SDK，有 Python 3 就行：

```sh
python3 tools/build-ipk.py
# dist/luci-app-wanip-selector_1.0.0-1_all.ipk
# dist/luci-i18n-wanip-selector-zh-cn_1.0.0-1_all.ipk
```

翻译由 `tools/po2lmo.py` 编译——它是 SDK 里那个 `po2lmo` 的纯 Python 等价实现，输出与官方工具**逐字节一致**（用固件自带的翻译库验证过）。

### 方式三：在 OpenWrt 源码树里编译

```sh
git clone https://github.com/System32X-code/luci-app-wanip-selector.git package/luci-app-wanip-selector

make menuconfig               # LuCI → Applications → luci-app-wanip-selector
make package/luci-app-wanip-selector/compile V=s
```

## 使用

打开 **网络 → WAN IP Selector**。

### 状态面板

页面顶部实时显示当前地址、是否符合要求、已重拨次数与运行状态，5 秒刷新一次。重拨过程中可以直接在这里看进度。

三个按钮无视总开关，随时可用：

| 按钮 | 作用 |
|---|---|
| 立即重拨 | 马上开始重拨循环 |
| 立即检查 | 只判断当前地址合不合格，不重拨 |
| 停止 / 清除锁 | 中断循环并释放锁（异常中断后用它复位） |

### 基本设置

| 设置 | 说明 |
|---|---|
| 启用 | 总开关。关闭时不会自动重拨，但按钮仍可用 |
| 接口 | 要监控并重拨的逻辑接口，下拉框列出 `/etc/config/network` 里的接口 |
| 匹配模式 | 包含（只要列表内的）/ 排除（避开列表内的） |
| 目标地址池 | 可加多条。CIDR 或裸前缀。**留空表示接受任意地址** |
| 最大重试次数 | 超过就放弃。**填 0 表示一直重试** |

### 后台监听

| 设置 | 默认 | 说明 |
|---|---|---|
| 启用后台监听 | 关 | 常驻检查地址，不只在链路重新拨上时检查 |
| 检查间隔 | 300 秒 | 几分钟足够——地址最多几天才变一次 |

运营商一般每隔几天会自行更换一次公网 IP，而这**未必会产生接口 up 事件**，
光靠热插拔触发会漏掉。开了监听之后，一旦地址漂出你要的网段就会自动重拨拉回来。

### 高级设置

| 设置 | 默认 | 说明 |
|---|---|---|
| 重试间隔 | 15 秒 | 两次重拨之间等多久 |
| 拨号等待时间 | 8 秒 | 重拨后等接口拿到地址的时间，慢速 PPPoE 会自动追加 30 秒宽限 |
| 冷却时间 | 600 秒 | 达到重试上限后暂停多久，防止不停骚扰运营商 |
| 详细日志 | 开 | 每次重拨都写系统日志 |

### 前缀展开规则

| 你填的 | 实际含义 |
|---|---|
| `203.0.113.0/24` | `203.0.113.0/24` |
| `203.0.113.` | `203.0.113.0/24` |
| `203.0` | `203.0.0.0/16` |
| `203.` | `203.0.0.0/8` |

## 命令行

```sh
wanip-selector check     # 判断当前地址，合格返回 0
wanip-selector status    # 输出 JSON 状态，供程序读取
wanip-selector run       # 遵守总开关，重拨到合格为止
wanip-selector force     # 同上，但无视总开关（手动触发）
wanip-selector trigger   # 后台启动一轮重拨，立即返回（LuCI 按钮与热插拔用它）
wanip-selector monitor   # 前台运行周期检查器（由 procd 托管，一般不用手动调）
wanip-selector stop      # 中断正在跑的循环、清除锁、置为空闲

/etc/init.d/wanip_selector {start|stop|reload|status|check|force}

logread -e wanip-selector    # 看它都干了什么
```

## 原理

```
接口 up ────────────────┐          后台监听 ────────────┐
   │ hotplug 钩子        │          每 check_interval 秒 │
   │ 仅监控接口且已启用   │          由 procd 托管常驻     │
   ▼                     ▼                              ▼
        /usr/sbin/wanip-selector  （setsid 脱离，调用方不阻塞）
                          │
                          │  mkdir 原子锁（锁内记 PID）
                          │  锁被占 → 直接退出；持有者已死 → 回收陈旧锁
                          ▼
              ubus + jsonfilter 读取接口地址
                          │
        ┌─────────────────┴─────────────────┐
      符合                                不符合
        │                                   │
   写状态文件，结束          ifdown / ifup → 等待 → 重新判断 → 循环
                            直到符合，或达到上限后进入冷却
```

## 注意事项

- **重拨会中断所有连接。** 如果你正通过这条 WAN 远程管理路由器，每次尝试都会把你自己踢下线。
- **`最大重试次数 = 0` 意味着拨不中就一直没网。** 如果运营商根本不给你想要的那个池，线路会无限期中断。除非你确信那个池很常见，否则建议设一个有限值。
- **频繁重连可能触发运营商的限速或临时封禁。** 请把重试间隔保持在合理值，默认值是刻意取保守的。
- **只判断 IPv4。** IPv6 前缀不参与匹配。
- 能不能拨到想要的池，取决于运营商的分配策略——这个插件只能提高尝试效率，**不能创造原本不存在的可能性**。

## 兼容性

- OpenWrt **21.02** 及以上，以及各类衍生版（iStoreOS、ImmortalWrt 等）
- LuCI 的 JS（客户端渲染）视图，21.02 起为默认
- 依赖 `jsonfilter`（标准固件自带）

## 界面语言

LuCI 会跟随你在 **系统 → 语言和界面** 里选择的语言，目前提供中文与英文。

## 贡献

欢迎提 Issue 和 Pull request。

如果你发现某个运营商需要特殊处理（比如判断地址的方式不同、或者需要在重拨前后做额外动作），欢迎反馈——这类需求可能值得做成可配置的钩子。

## 作者

**System32X-code**

## 许可证

[MIT](LICENSE)
