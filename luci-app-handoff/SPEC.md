# handoff 前后端约定（多网关版）

前端（LuCI）和后端（`/usr/sbin/handoff` 脚本）之间只通过两样东西交流：UCI 配置 `/etc/config/handoff`，和 `handoff status --json` / `handoff update` 两条命令。双方都按本文件实现，不要各自发明字段。

## UCI：/etc/config/handoff

```
config handoff 'main'              # 固定段名 main
	option enabled '0'             # 0/1
	option lan 'lan'               # 局域网逻辑接口名
	option interval '10'           # 检测间隔（秒，≥2）
	option url 'https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/{}.list'

config gateway                     # 可多个；段名（匿名段的 cfgXXXX 也行）就是网关 ID，规则的 target / 网关的 fallback 引用它
	option name '旁路由'           # 显示名
	option ip '192.168.99.3'       # 必填，IPv4 地址
	option ip6_mode 'auto'         # 'auto'（默认，按 MAC 自动发现同网段 IPv6）| 'manual'（手动填 ip6）| 'off'（不使用 IPv6）
	                               # 兼容旧配置：未设 ip6_mode 但填了 ip6 时按 'manual' 处理
	option ip6_prefer 'ula_lla_gua' # auto 模式地址优先级：'ula_lla_gua'（ULA > fe80:: > GUA，默认）| 'lla_ula_gua'（fe80:: > ULA > GUA）| 'gua_ula_lla'（GUA > ULA > fe80::）
	option ip6 ''                  # ip6_mode='manual' 时使用的 IPv6 地址（不带前缀长度）
	option v6_fallback 'reject'    # IPv6 关闭、未发现或不通时：'reject'（拒绝并回退 v4）| 'direct'（直连）| 'blackhole'（黑洞丢弃）
	option dns_port '53'           # 1–65535，默认 53
	option probe ''                # 可空，IPv4 字面量网址，如 http://1.1.1.1/ ，仅本机（iif lo）经该网关访问
	option fallback 'direct'       # 该网关不通时：'direct' 或另一个网关的段名（只换一次，备用也不通就直连）

config group                       # 设备组，可多个；段名是组 ID
	option name '孩子'
	list mac 'aa:bb:cc:11:22:33'
	list ip '192.168.99.50'        # IPv4 / IPv6 地址或网段

config ipgroup                     # 目标 IP 组（自定义），可多个；段名是组 ID
	option name '公司'
	list ip '10.20.0.0/16'         # IPv4 / IPv6 地址或网段，可混填；正向匹配允许命中私有网段（如公司 VPN 网段）
	list ip '2001:db8:abcd::/48'

config rule                        # 分流规则，按段的先后顺序，第一条命中的生效
	option name '国外交给网关'
	option enabled '1'
	list group 'kids'              # 组段名；不写 = 全部设备
	list geoip 'cn'                # GeoIP 类别名（小写字母数字下划线）
	list ipgroup 'office'          # 目标 IP 组段名
	                               # geoip 和 ipgroup 是「或」：目标在任一类别或任一 IP 组里就算在内；两个都不写 = 任何目标
	option invert '0'              # 1 = 目标不在上面这些类别和 IP 组里才命中（自动排除私网段）
	option target 'direct'         # 'direct' 或网关段名
```

兼容：旧版单网关配置（main 里的 gateway / gateway6 / dns_port / probe，规则 target='gateway'）不必兼容，直接丢弃。

## 命令

- `handoff status --json`：输出一行 JSON，前端每 5 秒调用一次：

```json
{
  "running": true,
  "gateways": [
    { "id": "side", "name": "旁路由", "ip": "192.168.99.3", "ip6": "2001:db8::3",
      "ip6_mode": "auto", "ip6_prefer": "ula_lla_gua", "v6_fallback": "reject",
      "up": true, "up6": true, "via": "side" }
  ],
  "geoip": [ { "cat": "cn", "count": 9665, "mtime": 1764000000 } ],
  "missing": [ "netflix" ],
  "stats": {
    "rules": { "rside": 83, "rkids": 12 },
    "matched": 95,
    "default": 45
  }
}
```

  - `running`：nft 表 `inet handoff` 是否存在。没在运行时 `gateways` 仍按配置列出，`up`/`up6` 为 null。
  - `ip6`：当前实际生效的 IPv6 地址（`auto` 模式下为自动发现结果，`manual` 模式下为配置值，`off` 或未发现为空字符串）。
  - `ip6_mode`：`"auto"` / `"manual"` / `"off"`。
  - `ip6_prefer`：`"ula_lla_gua"` / `"lla_ula_gua"` / `"gua_ula_lla"`。
  - `v6_fallback`：`"reject"` / `"direct"` / `"blackhole"`。
  - `up`：IPv4 检测是否正常；`up6`：IPv6 检测是否正常（关闭或无 IPv6 地址时为 null）。
  - `via`：交给该网关的新连接实际去向：自己的 id、备用网关的 id，或 `"direct"`。
  - `geoip`：已下载的类别（mtime 为 Unix 秒）；`missing`：规则用到但还没有数据的类别。
  - `stats`：规则新连接命中统计（仅按 `ct state new` 计数，避免非对称路由重复计包）：`rules` 为各生效规则段名对应的命中次数，`matched` 为所有规则命中总数，`default` 为未命中任何规则的默认直连新连接数。
- `handoff update`：立即下载规则用到的 GeoIP 类别，有变化时重新加载规则。退出码 0 = 完成。
