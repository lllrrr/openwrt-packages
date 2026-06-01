# FlowLens

[English](README.md)

FlowLens 是一个 LuCI 应用，用来把 OpenWrt 做成更直观的路由器设备流量看板。它可以在 LuCI 中展示局域网设备、在线/离线状态、当前 IPv4/IPv6、设备实时上下行速率，以及当前统计周期的累计流量。

项目以独立 OpenWrt 包的方式组织：路由器上运行轻量的 rpcd shell 后端和静态 LuCI 资源；React/Vite 只在开发机上用于构建浏览器端 bundle，路由器运行时不需要 Node.js。

## 功能

- 在线/离线设备列表，包含 MAC 地址、IPv4、IPv6 和设备名。
- 每台设备实时下载/上传速率，固定以 MB/s 显示。
- 在线设备、离线设备、下载速率、上传速率汇总卡片。
- 搜索、在线状态筛选、表头排序、响应式卡片视图。
- 适配 LuCI 主题，并支持深色/浅色实时切换。
- 显示 `nlbwmon` 当前统计周期和年月日区间。
- 更克制的地址选择策略：
  - IPv4 主显示优先使用当前 DHCP 租约。
  - IPv6 主显示只显示一个最有用地址，优先公网地址，其次 ULA，默认隐藏 `fe80::`。
  - STALE neighbor 和额外地址进入 IP 浮窗里的“历史/邻居缓存”区域。
  - FlowLens 缓存只保留离线设备的最后主地址，避免完整 IP 列表越积越多。

## 数据来源

FlowLens 尽量使用 OpenWrt 上风险较低、容易理解的数据来源：

- `/tmp/dhcp.leases`：当前 DHCP IPv4 租约和设备名。
- `/proc/net/arp` 与 `ip neigh show`：在线状态与邻居缓存。
- `conntrack`：可用时用于计算秒级实时流量差值。
- `nlbwmon`：当前统计周期的按 MAC 流量计数与累计。
- `/tmp/run/flowlens`：短生命周期本地状态，用来计算速率差值，以及记住离线设备最后主地址。

路由器运行时不需要安装 Node.js、npm、Vite 或 React 依赖。

## 目录结构

```text
.
├── Makefile
├── README.md
├── README.zh-CN.md
├── AGENTS.md
├── htdocs/
│   └── luci-static/resources/
│       ├── flowlens/dist/          # 随 LuCI 发布的前端构建产物
│       └── view/flowlens/          # LuCI view 入口
├── root/
│   ├── etc/config/flowlens         # 默认 UCI 配置
│   └── usr/
│       ├── libexec/rpcd/           # rpcd 后端脚本
│       └── share/
│           ├── luci/menu.d/        # LuCI 菜单入口
│           └── rpcd/acl.d/         # ubus ACL
├── tests/                          # 后端契约测试
└── web/                            # React/Vite 源码和前端测试
```

## 依赖

OpenWrt 打包需要：

- 可用的 OpenWrt/ImmortalWrt buildroot，并包含 LuCI feed。
- 包 Makefile 中声明的运行时依赖：
  - `nlbwmon`
  - `ip-full`

前端开发需要：

- Node.js 与 npm。
- macOS/Linux 上可用的 shell 工具，用于本地测试。

## 构建 OpenWrt 包

将 `luci-app-flowlens` 放入 OpenWrt package feed 后，在 OpenWrt buildroot 中执行：

```sh
./scripts/feeds update luci
./scripts/feeds install luci-app-flowlens
make menuconfig
make package/luci-app-flowlens/compile V=s
```

如有需要，在 LuCI 应用分类中启用该包。

## 前端开发

LuCI 包会直接携带以下构建产物：

```text
htdocs/luci-static/resources/flowlens/dist/
```

修改 `web/src` 下的前端源码后，需要重新构建静态 bundle：

```sh
cd web
npm install
npm test
npm run build
```

构建会写入：

```text
htdocs/luci-static/resources/flowlens/dist/flowlens-app.js
htdocs/luci-static/resources/flowlens/dist/flowlens-app.css
```

如果修改了前端 bundle，也要同步提升缓存版本号：

- `web/src/main.jsx`
- `htdocs/luci-static/resources/view/flowlens/overview.js`

## 测试

运行前端单元测试：

```sh
cd web
npm test
```

运行后端契约测试：

```sh
tests/test_rpc_devices.sh
```

检查 shell 与 LuCI JavaScript 语法：

```sh
sh -n root/usr/libexec/rpcd/luci.flowlens
node --check htdocs/luci-static/resources/view/flowlens/overview.js
```

## 开发环境安装到路由器

如果要快速在真实路由器上调试，可以把这些文件复制到 OpenWrt 对应绝对路径：

```text
/usr/libexec/rpcd/luci.flowlens
/www/luci-static/resources/view/flowlens/overview.js
/www/luci-static/resources/flowlens/dist/flowlens-app.js
/www/luci-static/resources/flowlens/dist/flowlens-app.css
```

然后重启服务：

```sh
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

打开 LuCI：

```text
状态 -> FlowLens
```

开发时如果遇到浏览器缓存，可以在页面 URL 后追加版本参数，例如：

```text
/cgi-bin/luci/admin/status/flowlens?flowlens_v=0.1.18
```

## 注意事项

- 第一次刷新时，实时速率可能显示 `0.00 MB/s`，需要至少两次采样后才能计算差值。
- `nlbwmon` 累计值来自当前数据库统计周期，不是设备历史总流量。
- rpcd 后端需要兼容 POSIX shell 与 BusyBox awk，不要在路由器侧脚本中使用 bash 专属语法。

## 许可证

Apache-2.0
