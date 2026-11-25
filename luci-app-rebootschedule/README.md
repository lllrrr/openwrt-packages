# luci-app-rebootschedule

一个给 OpenWrt 25.12（apk 包管理器）用的**定时重启**插件。

- 支持三种触发方式：每天定时 / 指定星期几 / 按开机时长（每 N 小时）
- 配置改完立即生效（daemon 每 20 秒重读一次配置，不需要重启服务）
- 开机前 5 分钟和重启失败后 1 小时内不会重复触发，避免循环重启
- 附带一个「立即重启」按钮（带二次确认）

## 目录结构

```
luci-app-rebootschedule/
├── Makefile                                   # 打包定义（luci.mk）
├── htdocs/luci-static/resources/view/rebootschedule/overview.js
├── root/etc/config/rebootschedule             # UCI 配置
├── root/etc/init.d/rebootschedule             # procd 服务
├── root/usr/libexec/rebootschedule/daemon     # 调度脚本
└── root/usr/share/{luci/menu.d,rpcd/acl.d}/…
```

## 为什么不能直接给你一个 .apk

25.12 的包是 apk-tools 3 的 **ADB(v3)** 二进制格式（文件头 `ADBd`，内含 schema
哈希和逐文件校验和），**不是 tar.gz**。`apk` 本身没有打包命令（`apk mkpkg`
只在 OpenWrt 的 host 工具里），所以只能用 SDK / buildroot 编译：

```sh
./build-apk.sh          # 在任意 Linux 上，一条命令出包
```

（在本机 Windows 上产不出来：WSL 没有发行版、没有 Docker，而且到镜像站的
实测带宽只有 31 KB/s，拉 150 MB 的 SDK 要一个多小时。）

## 方式一：编译成 apk（推荐，可分发）

需要对应固件分支的 SDK（25.12 是 apk 分支）：

```sh
# 1. 下载并解压 SDK（以本机 aarch64_cortex-a53 为例）
wget https://downloads.immortalwrt.org/snapshots/targets/airoha/an7581/immortalwrt-sdk-*-airoha-an7581_gcc-*-Linux-x86_64.tar.zst
tar --zstd -xf immortalwrt-sdk-*.tar.zst
cd immortalwrt-sdk-*/

# 2. 拉取 luci feed（luci.mk 来自这里）
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 放入插件源码
cp -r ../luci-app-rebootschedule package/

# 4. 编译
make package/luci-app-rebootschedule/compile V=s

# 5. 产物
find bin/ -name 'luci-app-rebootschedule*.apk'
```

装到路由器：

```sh
scp bin/packages/aarch64_cortex-a53/base/luci-app-rebootschedule-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/luci-app-rebootschedule-*.apk
/etc/init.d/rebootschedule enable
/etc/init.d/rebootschedule start
```

> 25.12 的包是 apk-tools 3 的 ADB 格式，只能用 SDK / buildroot 生成，
> 无法像老 ipk 那样手工打 tar 包，所以下面还有一个「免编译」的部署方式。

## 方式二：免编译，直接铺文件（调试用）

```sh
# 在电脑上，于本仓库根目录执行
scp -r luci-app-rebootschedule/root/* root@192.168.1.1:/
ssh root@192.168.1.1
scp -r luci-app-rebootschedule/htdocs/luci-static/resources/view/rebootschedule \
    root@192.168.1.1:/www/luci-static/resources/view/
ssh root@192.168.1.1
chmod +x /etc/init.d/rebootschedule /usr/libexec/rebootschedule/daemon
/etc/init.d/rebootschedule enable
/etc/init.d/rebootschedule start
rm -f /tmp/luci-indexcache*; /etc/init.d/uhttpd restart
```

LuCI 菜单：**服务 → Scheduled Reboot**。

## 配置项（/etc/config/rebootschedule）

| 选项 | 说明 | 默认 |
|---|---|---|
| `enabled` | 总开关 | `0` |
| `mode` | `daily` / `weekly` / `interval` | `daily` |
| `time` | 24 小时制 `HH:MM` | `03:30` |
| `weekdays` | 空格分隔，`0`=周日 … `6`=周六 | `0 1 2 3 4 5 6` |
| `hours` | interval 模式下的开机小时数 | `24` |
| `dry_run` | `1` 时只写日志、不真的重启（调试用） | `0` |

调试用 dry-run：

```sh
uci set rebootschedule.settings.enabled=1
uci set rebootschedule.settings.dry_run=1
uci set rebootschedule.settings.time="$(date -d '+2 minutes' +%H:%M)"
uci commit rebootschedule
logread -f -e rebootschedule
```

日志里出现 `dry-run: would reboot` 就说明调度逻辑正常；测完记得
`uci set rebootschedule.settings.dry_run=0`。

## 注意

- 定时重启会中断拨号/VoIP，如果有重要业务请把时间放在凌晨。
- `interval` 模式按「开机多久」算，不是固定时刻，重启后重新计时。
- 首次启动 5 分钟内不会触发（此时 NTP 还没同步，避免误判）。

## License

GPL-2.0 — <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
