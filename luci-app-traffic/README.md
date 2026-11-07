# luci-app-traffic

**OpenWrt / LuCI 的 WAN 流量监控插件**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-00B5E2)](https://openwrt.org)
[![LuCI](https://img.shields.io/badge/LuCI-JS%20API-1E90FF)](https://github.com/openwrt/luci)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**中文** | [English](README.en.md)

---

## 简介

直接读取内核接口计数器 `/proc/net/dev`，统计并可视化单个 WAN 接口的上下行流量。

**不依赖 conntrack**，因此在开启 `flow offloading` 的环境下依然准确 —— 这是 nlbwmon、vnstat2 等基于 conntrack / netfilter 的方案做不到的（连接命中 flowtable 后，conntrack 字节数会冻结）。

## 特性

- **6 个时间维度**
  - `3 分钟`：1 秒采样，支持实时刷新开关
  - `1 小时`：分钟级曲线
  - `1 天`：**自然日 00:00–24:00 的小时柱状图**，可左右切换今天 / 昨天 / 前天，**保留峰值卡片**
  - `近 30 天`
  - `月`：整月柱状图，可左右翻月（本月 / 上月 / 更早）
  - `年`：固定 12 列（1~12 月），可按年份切换
- **五层降采样**：内存（tmpfs）+ flash 混合存储，按**真实时钟边界**聚合
- **分钟级落盘**：`1 天` 的数据每分钟写一次 flash，断电最多丢 1 分钟
- **峰值 = 窗口内最高的 1 秒速率**（上下行分开），不是「总量 ÷ 时长」
- **实时性分级**：`本月` / `近 30 天` 含当天实时数据，**每小时**增长；`年` 视图**每天**增长
- **纯 SVG 前端**：无 CDN、无任何外部依赖，自动跟随系统深色 / 浅色主题
- **安全升级**：只覆盖代码、升级前快照数据、格式版本校验、行数校验失败自动回滚
- **资源占用低**：CPU ≈ 1.3%、内存 ≈ 1.1 MB、flash 写入约 150 MB/年（分钟级落盘的代价）

## 数据分层

| 层 | 采样间隔 | 保留条数 | 覆盖范围 | 存储位置 | 用途 |
|---|---|---|---|---|---|
| L1 | 1 秒 | 180 | 3 分钟 | tmpfs（内存） | 3 分钟视图 |
| L2 | 60 秒 | 60 | 1 小时 | tmpfs（内存） | 1 小时视图 |
| L3 | **60 秒** | **4320** | **3 天** | flash | 1 天视图；日聚合的数据源 |
| L4 | 1 天 | 93 | 约 3 个月 | flash | 近 30 天 / 月视图 |
| L5 | 1 月 | 永久 | 不限 | flash | 年视图 |

> **保留期**：分钟档 3 天、日档约 3 个月（月视图最多回看 3 个月）；月汇总档保留给年视图长期使用。

数据格式（CSV）：

```text
ts,dn_rate,up_rate,dn_bytes,up_bytes[,dn_peak,up_peak]
```

- **第 6/7 列** = 该周期内「最高的 1 秒速率」，用于峰值卡片；老格式没有这两列时自动退回用均值
- **L1 / L2 / L3** 存**累计字节**，流量由相邻两条记录做差得到
- **L4 / L5** 存**当期增量**，每条记录自包含，只有一条数据也能正确显示
- 累计值出现**回绕**（接口重连 / 重启导致计数器归零）时按「当前值」计算增量，不会算出负数

## 聚合时机

不依赖进程内部计时器，而是按**真实时钟边界**触发：

- **每分钟** → 把最新一条 L2 记录镜像落盘到 L3（所以断电最多丢 1 分钟）
- **每跨过一天** → 把最近 24 小时的 L3 聚合成 1 条 L4，并在月初结算上月到 L5

因此**守护进程重启不会打乱记录节奏**。

`1 天` 视图里每个小时点的速率 = **该小时累计流量 ÷ 3600 秒**。整点刚过时数值很小，随着分钟累积逐步上升，整点走满后即为该小时的真实平均——这样不会出现「小时开头几分钟被放大成尖峰」的问题。

### 时区

「整点 / 跨天 / 月份」的判定依赖时区，由 UCI 配置项 `traffic.main.timezone` 指定（POSIX 时区串，默认 `CST-8` 即北京时间）。

该配置**只影响边界判定，不影响存储的 Unix 时间戳**，不会改动系统全局时区。没有 zoneinfo 包也能用。

## 安装

### 方式一：手动部署

```sh
# 在本地仓库根目录执行
scp -r root/.   root@192.168.1.1:/
scp -r htdocs/. root@192.168.1.1:/www/

ssh root@192.168.1.1 '
  chmod 755 /usr/sbin/trafficd.sh /etc/init.d/trafficd /www/cgi-bin/traffic
  /etc/init.d/trafficd enable
  /etc/init.d/trafficd start
  rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
  /etc/init.d/rpcd restart
  /etc/init.d/uhttpd restart
'
```

### 方式二：OpenWrt SDK / 源码编译

把本仓库放到 buildroot 的 `package/` 目录下，然后：

```sh
make package/luci-app-traffic/compile V=s
# 产物：bin/packages/*/base/luci-app-traffic_*.ipk
```

## 访问

- **LuCI**：状态 → 流量监控
- **直连**：`http://192.168.1.1/traffic/`

## 安全升级

`tools/traffic-upgrade.sh` 提供五条硬保证：

1. 绝不删除 / 截断任何 `.dat` 数据文件
2. 升级前把持久层数据快照到 `/etc/traffic/.backup/<时间戳>`，只保留最近 3 份
3. 数据格式版本不符时直接中止并要求迁移，**禁止静默清空**
4. 升级前后比对行数，任何减少立即从快照还原数据
5. **仅当采集守护进程自身代码变更时才重启它**，避免无谓重置聚合计数器

```sh
# 先预览会做什么
sh tools/traffic-upgrade.sh /path/to/new/package --dry-run

# 确认后执行
sh tools/traffic-upgrade.sh /path/to/new/package
```

## 文件结构

```text
root/                                   -> 路由器根目录 /
├── usr/sbin/trafficd.sh                采集守护进程
├── etc/init.d/trafficd                 procd 服务
├── etc/uci-defaults/99-traffic         首次安装写入默认配置
└── usr/share/luci|rpcd/...             菜单与 ACL

htdocs/                                 -> /www
├── cgi-bin/traffic                     JSON API
├── traffic/index.html                  纯 SVG 前端
└── luci-static/resources/view/traffic/main.js   LuCI 内嵌视图

tools/traffic-upgrade.sh                安全升级脚本
```

## 已知限制

- **只统计单个接口**。开启 flow offload 后无法可靠地按设备 / 应用拆分流量（连接命中 flowtable 后 conntrack 不再更新）
- **历史数据从安装那一刻开始**，早于安装的流量无法回溯
- 日 / 月边界依赖时区配置；未配置时跟随系统时区
- `L3` 只保留 3 天，因此「1 天」视图最多回看前天

## 兼容性

开发与测试环境：

| 项目 | 版本 |
|---|---|
| 设备 | Xiaomi AX3000T V1（MT7981B + MT7531） |
| 系统 | OpenWrt 25.12.6 (apk) |
| 前端 | LuCI JS API |

理论上面向所有使用 **LuCI JS API** 的 OpenWrt 21.02+ 系统。

## 许可

[MIT](LICENSE)
