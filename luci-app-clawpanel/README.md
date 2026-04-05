# luci-app-clawpanel

**版本**: v1.2.0 | OpenClaw 智能管理面板 LuCI 插件

---

## 核心设计：/Configs 统一目录结构

所有 ClawPanel 和 OpenClaw 相关文件统一存放在存储盘的 `/Configs` 目录下，便于管理、备份和迁移。

```
/mnt/sda1/Configs/           ← 统一存放点（用户数据盘）
├── clawpanel/              ← ClawPanel Go 二进制 + 数据
│   ├── clawpanel           ← 可执行文件
│   ├── .version            ← 版本记录
│   └── data/
│       └── clawpanel.json  ← ClawPanel 配置
├── openclaw/               ← OpenClaw npm 包
│   └── node_modules/openclaw/
├── .openclaw/              ← OpenClaw 工作区配置
│   └── openclaw.json
└── .openclaw-work/         ← OpenClaw 运行时数据

/usr/local/bin/             ← 系统级工具（全局可用）
├── node                    ← Node.js v22（系统级，全 OpenWrt 可用）
├── npm
└── openclaw                ← OpenClaw CLI
```

### 设计原则

- **用户数据统一存放**：`/Configs` 目录下所有子目录归属清晰，不东一堆西一堆
- **系统工具系统级安装**：Node.js 安装到 `/usr/local/bin`，OpenWrt 所有插件均可调用
- **自动识别存储**：安装时自动扫描 `/mnt/*`、`/ext/*`、`/storage/*`，多盘时让用户选择
- **Node.js 自动更新**：安装时自动从 GitHub 获取最新 LTS 版本，配置软链接
- **一键恢复**：系统重装后只需运行 `CP_BASE_PATH=/mnt/sda1 sh install.sh`

---

## 功能特性

- ✅ **统一管理面板**：ClawPanel + OpenClaw + Node.js 一站式状态监控
- ✅ **存储选择器**：自动检测外置存储，显示容量和使用率，支持多盘选择
- ✅ **一键安装/重装/卸载**：后台异步安装，实时日志输出
- ✅ **服务控制**：启动 / 停止 / 重启 / 开机自启
- ✅ **版本检测**：ClawPanel 版本 + OpenClaw 版本 + Node.js 版本
- ✅ **Node.js 系统级**：安装到 `/usr/local/bin`，全系统可用
- ✅ **实时状态**：PID、内存、运行时间、剩余空间
- ✅ **多语言**：中文界面

---

## 安装方式

### 方式一：编译进固件

```bash
# 放入 OpenWrt package 目录
git clone https://github.com/a10463981/luci-app-clawpanel.git package/luci-app-clawpanel
make menuconfig  # 选择 LuCI → Applications → luci-app-clawpanel
make -j$(nproc)
```

### 方式二：手动安装 IPK

```bash
opkg update
opkg install luci-app-clawpanel_*.ipk
```

### 方式三：SSH 一键安装（推荐）

```bash
# 自动检测最大存储盘
sh install.sh

# 手动指定存储盘
CP_BASE_PATH=/mnt/sda1 sh install.sh
```

---

## 插件使用

1. 进入 LuCI → 服务 → ClawPanel
2. 点击「安装 / 重装」
3. 从存储列表中选择安装盘（显示可用空间和使用率）
4. 选择 ClawPanel 版本（最新版 / 指定版本）
5. 点击「开始安装」，等待完成
6. 访问 http://路由器IP:19527 → 令牌: `clawpanel`

---

## 系统恢复（重装固件后）

```bash
# 1. 安装插件
opkg install luci-app-clawpanel_*.ipk

# 2. 恢复数据（所有 /Configs 数据完整保留）
CP_BASE_PATH=/mnt/sda1 sh install.sh
```

---

## CLI 命令

```bash
# 服务管理
/etc/init.d/clawpanel start
/etc/init.d/clawpanel stop
/etc/init.d/clawpanel restart
/etc/init.d/clawpanel status
/etc/init.d/clawpanel enable

# Node.js
node --version
npm --version

# OpenClaw
openclaw --version
```

---

## 目录结构（插件包）

```
luci-app-clawpanel/
├── Makefile
├── VERSION
├── README.md
├── install.sh                    # 一键安装脚本
├── clawpanel-install.sh
├── uninstall.sh
├── luasrc/
│   ├── controller/clawpanel.lua  # LuCI API 控制器
│   ├── model/cbi/clawpanel/basic.lua
│   └── view/clawpanel/
│       ├── main.htm              # 主界面（重写 v1.2.0）
│       └── basic.htm             # 最小占位
├── root/
│   ├── etc/
│   │   ├── config/clawpanel     # UCI 配置
│   │   └── init.d/clawpanel     # 服务脚本
│   └── usr/bin/clawpanel-env    # 安装脚本
└── .github/workflows/build.yml
```

---

## UCI 配置

```bash
config clawpanel 'main'
    option enabled '1'
    option disk '/mnt/sda1'               # 存储盘挂载点
    option install_path '/mnt/sda1/Configs' # /Configs 目录
    option port '19527'
    option version 'pro-v5.3.3'
```

---

## 架构说明

- **ClawPanel**：Go 二进制，管理 OpenClaw 的 Web 面板（端口 19527）
- **OpenClaw**：Node.js 应用，Claude AI 助手框架（npm 包）
- **Node.js**：v22 LTS，系统级安装到 `/usr/local/bin`，全 OpenWrt 可用
- **数据路径**：`/Configs` 统一存放，存储盘持久化，系统重装无损

---

## License

CC-BY-NC-SA-4.0
