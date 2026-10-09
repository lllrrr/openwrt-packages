#!/bin/sh
# common.sh 白盒测试：逐分支覆盖日子判定 / 节假日解析 / 额度 / 用量 / 配额。
# 运行： sh test/common_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
t_setup

# ============================================================
echo '== uci 助手（pc_ids_all / pc_ids_on）=='
cfg_reset
cat > "$T_TMP/ids" <<'EOF'
config weburl
	option enable '1'
config weburl
	option enable '0'
config weburl
	option enable '1'
config weburl
	option enabled '1'
EOF
# 位置无关：直接用 uci 写多位数下标
cfg_set 'parentcontrol.@weburl[11].enable' '1'
cfg_set 'parentcontrol.@weburl[11].sd_mode' 'quota'
cfg_load parentcontrol "$T_TMP/ids"
t_eq 'ids_all 含 0..3/11' '0 1 2 3 11' "$(pc_ids_all weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'ids_on 只取 enable=1' '0 2 11' "$(pc_ids_on weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'ids_all 空配置' '' "$(cfg_reset; pc_ids_all time)"

# ============================================================
# F5：命名 section 必须与匿名 section 等价。真机上命名节在 @type[N] 下标空间里**同样占位**
# （「匿名 / 命名 / 匿名」→ @weburl[0] / [1] / [2]），而 uci show 只对命名节打印它的名字。
# 修复前 pc_ids_* 只匹配 `parentcontrol.@weburl[N].*`，命名条目被整条链路静默跳过。
echo '== uci 助手：命名 section（F5）=='
cfg_reset
cat > "$T_TMP/named" <<'EOF'
config weburl 'kid'
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:11'
	option ip '192.0.2.11'
	option domains 'xiaohongshu.com'
config weburl
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:22'
	option domains 'xiaohongshu.com'
config weburl 'dad'
	option enable '0'
	option mac 'aa:bb:cc:dd:ee:33'
	option ip '192.0.2.33'
	option domains 'xiaohongshu.com'
EOF
cfg_load parentcontrol "$T_TMP/named"
t_eq 'F5 ids_all：命名节同样占位（0 1 2）' '0 1 2' "$(pc_ids_all weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'F5 ids_on：命名节 enable=1 也算，=0 不算' '0 1' "$(pc_ids_on weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'F5 opts_all mac：三个节（含命名）全收到' 'aa:bb:cc:dd:ee:11 aa:bb:cc:dd:ee:22 aa:bb:cc:dd:ee:33' "$(pc_opts_all weburl mac | tr '\n' ' ' | sed 's/ $//')"
t_eq 'F5 opts_all ip：命名节的 ip 也收到' '192.0.2.11 192.0.2.33' "$(pc_opts_all weburl ip | tr '\n' ' ' | sed 's/ $//')"
t_eq 'F5 按类型过滤：命名 weburl 节不进别的模块' '' "$(pc_ids_all time)"

# ============================================================
echo '== pc_holiday_flag：jsonfilter 路径 =='
put_holiday 2026 '{"year": 2026, "days": [
    {"name": "元旦", "date": "2026-01-01", "isOffDay": true},
    {"name": "春节", "date": "2026-02-16", "isOffDay": false}
]}'
FAKE_JSONFILTER=on
t_eq 'jsonfilter 放假 → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq 'jsonfilter 调休 → 0' 0 "$(pc_holiday_flag 2026-02-16)"
t_eq 'jsonfilter 无此日期 → 空' '' "$(pc_holiday_flag 2026-03-03)"
t_eq 'jsonfilter 无该年文件 → 空' '' "$(pc_holiday_flag 2027-01-01)"

echo '== pc_holiday_flag：兜底路径（jsonfilter 不可用）=='
FAKE_JSONFILTER=off
t_eq '兜底 带空格 JSON → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq '兜底 带空格 JSON → 0' 0 "$(pc_holiday_flag 2026-02-16)"
put_holiday 2026 '{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"2026-03-03 提示","date":"2026-04-04","isOffDay":true},{"name":"春节","date":"2026-02-16","isOffDay":false}]}'
t_eq '兜底 压缩 JSON → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq '兜底 压缩 JSON → 0' 0 "$(pc_holiday_flag 2026-02-16)"
t_eq '兜底 只有 name 含该日期 → 不误命中' '' "$(pc_holiday_flag 2026-03-03)"
t_eq '兜底 无该年文件 → 空' '' "$(pc_holiday_flag 2027-01-01)"
FAKE_JSONFILTER=on

# ============================================================
echo '== pc_in_vacation =='
cfg_reset
cat > "$T_TMP/vac" <<'EOF'
config vacation
	option name 'summer'
	option start '07-01'
	option end '08-31'
config vacation
	option name 'winter'
	option start '2026-01-20'
	option end '2026-02-16'
config vacation
	option name 'newyear'
	option start '12-28'
	option end '01-03'
config vacation
	option name 'broken'
	option start '05-01'
EOF
cfg_load parentcontrol "$T_TMP/vac"
t_eq 'MM-DD 每年重复：区间内' 1 "$(pc_in_vacation 2027-07-15)"
t_eq 'MM-DD 每年重复：区间外' 0 "$(pc_in_vacation 2027-06-30)"
t_eq 'MM-DD 起点当日含' 1 "$(pc_in_vacation 2026-07-01)"
t_eq 'MM-DD 终点当日含' 1 "$(pc_in_vacation 2026-08-31)"
t_eq 'MM-DD 起点前一天' 0 "$(pc_in_vacation 2026-06-30)"
t_eq 'MM-DD 终点后一天' 0 "$(pc_in_vacation 2026-09-01)"
t_eq '绝对日期：区间内' 1 "$(pc_in_vacation 2026-02-01)"
t_eq '绝对日期：跨年不适用' 0 "$(pc_in_vacation 2027-02-01)"
t_eq '跨年区间：12 月' 1 "$(pc_in_vacation 2026-12-30)"
t_eq '跨年区间：1 月' 1 "$(pc_in_vacation 2026-01-02)"
t_eq '跨年区间：11 月' 0 "$(pc_in_vacation 2026-11-30)"
t_eq '跨年区间：1/4' 0 "$(pc_in_vacation 2026-01-04)"
t_eq '缺 end 的坏行被跳过' 0 "$(pc_in_vacation 2026-05-01)"

# ============================================================
echo '== pc_today_type 优先级 =='
cfg_reset
cat > "$T_TMP/day" <<'EOF'
config vacation
	option name 'winter'
	option start '01-01'
	option end '01-10'
EOF
cfg_load parentcontrol "$T_TMP/day"
put_holiday 2026 '{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"调休","date":"2026-01-11","isOffDay":false}]}'
FAKE_DATE_YMD=2026-01-05 FAKE_DATE_DOW=1
t_eq '寒暑假优先于周末/工作日判定' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-01-01 FAKE_DATE_DOW=4
t_eq '法定放假 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-01-11 FAKE_DATE_DOW=7
t_eq '调休上班的周末 → 平日' school "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-06 FAKE_DATE_DOW=6
t_eq '无数据 周六 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-07 FAKE_DATE_DOW=7
t_eq '无数据 周日 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1
t_eq '无数据 周一 → 平日' school "$(pc_today_type)"
FAKE_DATE_YMD=2028-06-06 FAKE_DATE_DOW=6
t_eq '无该年数据 周六 → 降级节假日' holiday "$(pc_today_type)"

# ============================================================
echo '== pc_suffix / 时间换算（HH:MM:SS 秒级）=='
t_eq 'suffix holiday→hd' hd "$(pc_suffix holiday)"
t_eq 'suffix school→sd' sd "$(pc_suffix school)"
t_eq 'HH:MM:SS→秒 09:00:00' 32400 "$(pc_hhmmss_to_sec 09:00:00)"
t_eq 'HH:MM:SS→秒 23:59:59' 86399 "$(pc_hhmmss_to_sec 23:59:59)"
t_eq 'HH:MM→秒（补 0 秒）' 32400 "$(pc_hhmmss_to_sec 09:00)"
t_eq '秒→HH:MM:SS 09:00:00' '09:00:00' "$(pc_sec_hhmmss 32400)"
t_eq '秒→HH:MM:SS 23:59:59' '23:59:59' "$(pc_sec_hhmmss 86399)"
t_eq '非法 x → 空' '' "$(pc_hhmmss_to_sec x)"
t_eq '24:00:00 → 空' '' "$(pc_hhmmss_to_sec 24:00:00)"
t_eq '09:99:00 → 空' '' "$(pc_hhmmss_to_sec 09:99:00)"

echo '== pc_utc_ranges：本地秒区间 → UTC（跨零点切两段）=='
# 本地 00:00:00-08:59:59 → UTC 16:00:00-23:59:59 + 00:00:00-00:59:59
t_eq '跨 UTC 零点切两段' '57600 86399
0 3599' "$(pc_utc_ranges 0 32399)"
t_eq '不跨 UTC 零点一段' '46801 57599' "$(pc_utc_ranges 75601 86399)"
cfg_reset
cfg_set 'parentcontrol.@weburl[0].sd_qstart' '09:00:00'
cfg_set 'parentcontrol.@weburl[0].sd_qend' '21:00:00'
t_eq '本地 09:00-21:00 → 时段外共 3 段（含跨 UTC 零点那段）' '57600 86399
0 3599
46801 57599' "$(pc_qwin_out_ranges weburl 0 school)"

echo '== pc_qwin_sec / pc_entry_unlimited =='
cfg_reset
cfg_set 'parentcontrol.@weburl[0].sd_mode' 'quota'
cfg_set 'parentcontrol.@weburl[0].sd_qstart' '09:00:00'
cfg_set 'parentcontrol.@weburl[0].sd_qend' '21:00:00'
t_eq '可用时段→秒' '32400 75600' "$(pc_qwin_sec weburl 0 school)"
t_eq '未设时段→空（= 不限制）' '' "$(pc_qwin_sec weburl 0 holiday)"
cfg_set 'parentcontrol.@weburl[0].sd_qstart' '00:00:00'
cfg_set 'parentcontrol.@weburl[0].sd_qend' '23:59:59'
t_eq '全天→空（= 不限制）' '' "$(pc_qwin_sec weburl 0 school)"
cfg_set 'parentcontrol.@weburl[0].sd_qstart' '21:00:00'
cfg_set 'parentcontrol.@weburl[0].sd_qend' '09:00:00'
t_eq '起>止（脏数据）→空，按不限制兜底' '' "$(pc_qwin_sec weburl 0 school)"
cfg_set 'parentcontrol.@weburl[0].sd_qstart' '09:00:00'
cfg_set 'parentcontrol.@weburl[0].sd_qend' '09:00:00'
t_eq '起=止（脏数据）→空，按不限制兜底' '' "$(pc_qwin_sec weburl 0 school)"
cfg_reset
t_eq '不限/额度都没设 → 1（fail-open，避免静默全禁）' 1 "$(pc_entry_unlimited weburl 0 school)"
cfg_set 'parentcontrol.@weburl[0].sd_quota' '60'
t_eq '写了额度 → 0（按有限额处理）' 0 "$(pc_entry_unlimited weburl 0 school)"
cfg_set 'parentcontrol.@weburl[0].sd_unlimited' '1'
t_eq '显式勾选不限 → 1' 1 "$(pc_entry_unlimited weburl 0 school)"

# ============================================================
echo '== 用量读写 =='
FAKE_DATE_YMD=2026-03-01
t_eq '无文件时用量为 0' 0 "$(pc_usage_get weburl_0)"
pc_usage_add weburl_0 1
pc_usage_add weburl_0 2
pc_usage_add weburl_1 5
t_eq '同键累加' 3 "$(pc_usage_get weburl_0)"
t_eq '不同键独立' 5 "$(pc_usage_get weburl_1)"
t_eq '不存在的键 → 0' 0 "$(pc_usage_get weburl_9)"
FAKE_DATE_YMD=2026-03-02
t_eq '跨天清零' 0 "$(pc_usage_get weburl_0)"
FAKE_DATE_YMD=2026-03-01

# ============================================================
echo '== pc_lan_nets（防自锁用）=='
cfg_reset
cat > "$T_TMP/net.uci" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
config interface 'wan'
	option proto 'dhcp'
EOF
cfg_load network "$T_TMP/net.uci"
t_eq '静态 LAN 网段' '192.0.2.1/255.255.255.0' "$(pc_lan_nets)"
cfg_reset
t_eq '无 network 配置 → 空' '' "$(pc_lan_nets)"

echo '== 配额归一 / 池 =='
t_eq '空 → 0（新语义 0 = 全禁；是否真的不限由 pc_entry_unlimited 决定）' 0 "$(pc_quota_positive '')"
t_eq '非数字 → 0（新语义 0 = 全禁）' 0 "$(pc_quota_positive abc)"
t_eq '0 → 0（全禁）' 0 "$(pc_quota_positive 0)"
t_eq '正常数字' 60 "$(pc_quota_positive 60)"
t_eq '带空格 → 0（老白名单口径；是否真的不限由 pc_entry_unlimited 决定）' 0 "$(pc_quota_positive ' 60')"
cfg_reset
cat > "$T_TMP/pool" <<'EOF'
config quota
	option name 'kid1'
	option sd_quota '60'
	option hd_quota '120'
config quota
	option name 'onlyone'
	option quota '45'
EOF
cfg_load parentcontrol "$T_TMP/pool"
t_eq '池 平日额度' 60 "$(pc_pool_quota kid1 school)"
t_eq '池 节假日额度' 120 "$(pc_pool_quota kid1 holiday)"
t_eq '池 单 quota 兜底(平日)' 45 "$(pc_pool_quota onlyone school)"
t_eq '池 单 quota 兜底(节假日)' 45 "$(pc_pool_quota onlyone holiday)"
t_eq '不存在的池 → 空' '' "$(pc_pool_quota nope school)"

echo '== 条目档案取值 =='
cfg_reset
cat > "$T_TMP/entry" <<'EOF'
config weburl
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '30'
	option sd_pool 'kid1'
	option hd_mode 'time'
	option hd_start '08:00'
	option hd_end '20:00'
config weburl
	option enable '1'
config weburl
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '10'
config weburl
	option enable '0'
	option sd_mode 'quota'
	option sd_quota '99'
config time
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '7'
EOF
cfg_load parentcontrol "$T_TMP/entry"
t_eq '平日 quota' 30 "$(pc_entry_quota weburl 0 school)"
t_eq '平日 pool' kid1 "$(pc_entry_pool weburl 0 school)"
t_eq '节假日 pool 为空' '' "$(pc_entry_pool weburl 0 holiday)"

echo '== pc_active_keys：唯一的条目遍历入口（不再有"模式"）=='
t_eq '列出所有 enable=1 的条目（模块序 time/protocol/weburl）' 'time_0 weburl_0 weburl_1 weburl_2' \
	"$(pc_active_keys | tr '\n' ' ' | sed 's/ $//')"
t_eq '条目数 = 4（不再按模式过滤）' 4 "$(pc_active_keys | wc -l | tr -d ' ')"

# ============================================================
echo '== F3：pc_lan_nets6（LAN on-link IPv6 前缀）=='
cfg_reset
cat > "$T_TMP/net6.uci" <<'EOF'
config interface 'loopback'
	option proto 'static'
	option device 'lo'
config interface 'lan'
	option proto 'static'
	option device 'br-lan'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
EOF
cfg_load network "$T_TMP/net6.uci"
FAKE_IP_ROUTE6="$T_TMP/route6.txt"; export FAKE_IP_ROUTE6

# W-F3-01：直连三行（GUA/ULA/link-local，复刻真机 dev br-lan）→ 恰好 3 行
cat > "$FAKE_IP_ROUTE6" <<'EOF'
2001:db8:1::/64 dev br-lan proto static metric 1024 pref medium
fd9b:a1::/64 dev br-lan proto static metric 1024 pref medium
fe80::/64 dev br-lan proto kernel metric 256 pref medium
EOF
EXP6="$(printf '2001:db8:1::/64\nfd9b:a1::/64\nfe80::/64\n' | sort -u)"
GOT6="$(pc_lan_nets6)"
t_eq 'W-F3-01: 恰好 3 行且逐行等于预期（sort -u 序）' "$EXP6" "$GOT6"
t_eq 'W-F3-01: 行数 = 3' 3 "$(printf '%s\n' "$GOT6" | grep -c .)"

# W-F3-02：default / via 转发 / throw / blackhole 全部被白名单拒掉
cat >> "$FAKE_IP_ROUTE6" <<'EOF'
default dev br-lan proto static metric 1024
default from 2001:db8:ffff:: via 2001:db8::1 dev br-lan proto static metric 1024
throw 2001:db8:dead::/64 dev br-lan
blackhole fd00:dead::/64 dev br-lan
2001:db8:2::/64 via fe80::9 dev br-lan proto static metric 1024
EOF
t_eq 'W-F3-02: default/via/throw/blackhole 一律不产出' "$EXP6" "$(pc_lan_nets6)"

# W-F3-03：复刻真机 dev lo 的 unreachable 三行 → lo 节产出为空，lan 不受影响
cat > "$FAKE_IP_ROUTE6" <<'EOF'
unreachable 2001:db8:b200::/64 dev lo proto static metric 2147483647 pref medium
unreachable 2001:db8:b201::/64 dev lo proto static metric 2147483647 pref medium
unreachable fd9b:a1::/48 dev lo proto static metric 2147483647 pref medium
2001:db8:1::/64 dev br-lan proto static metric 1024 pref medium
fe80::/64 dev br-lan proto kernel metric 256 pref medium
EOF
t_eq 'W-F3-03: lo 节产出为空（unreachable 被拒），lan 不受影响' \
	"$(printf '2001:db8:1::/64\nfe80::/64\n' | sort -u)" "$(pc_lan_nets6)"

# W-F3-04：无 v6 路由数据 → 空输出、rc=0
: > "$FAKE_IP_ROUTE6"
t_eq 'W-F3-04: 路由文件为空 → 输出为空' '' "$(pc_lan_nets6)"
pc_lan_nets6 >/dev/null
t_eq 'W-F3-04: rc=0（不报错）' 0 "$?"
FAKE_IP_ROUTE6=; export FAKE_IP_ROUTE6
t_eq 'W-F3-04: 未设置 → 输出为空' '' "$(pc_lan_nets6)"
pc_lan_nets6 >/dev/null
t_eq 'W-F3-04: 未设置 rc=0' 0 "$?"
FAKE_IP_ROUTE6="$T_TMP/route6.txt"; export FAKE_IP_ROUTE6

# W-F3-05：静态节既无 device 也无 ifname → 跳过该节（不对空设备名调 ip）
cfg_reset
cat > "$T_TMP/net6b.uci" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
EOF
cfg_load network "$T_TMP/net6b.uci"
cat > "$FAKE_IP_ROUTE6" <<'EOF'
2001:db8:1::/64 dev br-lan proto static metric 1024 pref medium
EOF
t_eq 'W-F3-05: 无 device/ifname 的静态节被跳过' '' "$(pc_lan_nets6)"
pc_lan_nets6 >/dev/null
t_eq 'W-F3-05: rc=0' 0 "$?"
# 对照组（阶段 5 复审 Nit-1：上面的「空」必须可鉴别）：同一节配上 device 即有输出，
# 证明空是因为「跳过」，而不是实现恒空。
printf "\toption device 'br-lan'\n" >> "$T_TMP/net6b.uci"
cfg_reset
cfg_load network "$T_TMP/net6b.uci"
t_eq 'W-F3-05: 对照组——配上 device 即有输出' '2001:db8:1::/64' "$(pc_lan_nets6)"

# W-F3-06：两条不同节产出同一前缀 → sort -u 去重后只出现一次
cfg_reset
cat > "$T_TMP/net6c.uci" <<'EOF'
config interface 'lan'
	option proto 'static'
	option device 'br-lan'
config interface 'iot'
	option proto 'static'
	option device 'br-lan'
EOF
cfg_load network "$T_TMP/net6c.uci"
t_eq 'W-F3-06: 同一前缀去重后只出现一次' '2001:db8:1::/64' "$(pc_lan_nets6)"

# W-F3-13（阶段 5 SF-1）：行首为 ::/0 / 数字形式全零前缀 → 零长前缀被排除。
# 它们能通过行首白名单，但进链会生成 "-d ::/0 -j RETURN" = 放行一切。
cat >> "$FAKE_IP_ROUTE6" <<'EOF'
::/0 dev br-lan proto static metric 1024 pref medium
0:0:0:0:0:0:0:0/0 dev br-lan proto static metric 1024 pref medium
EOF
t_eq 'W-F3-13: ::/0 与全零前缀被排除，直连前缀照常' '2001:db8:1::/64' "$(pc_lan_nets6)"

FAKE_IP_ROUTE6=; export FAKE_IP_ROUTE6
cfg_reset

t_summary
