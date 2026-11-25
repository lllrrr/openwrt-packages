#!/bin/sh
# AdGuard Home 管理中心 - 首次配置生成脚本
# 功能：从内置默认配置模板生成 /etc/AdGuardHome.yaml，并同步面板端口、DNS 端口和上游 DNS。
# 说明：仅在配置文件不存在时由 init 脚本自动调用，一般无需手动执行。

. /usr/share/adguardhome-lite/common.sh

TEMPLATE="/usr/share/adguardhome-lite/AdGuardHome.yaml.template"
DEFAULT_ADMIN="admin"
DEFAULT_PASS="admin123"

fail_bootstrap() {
    log_msg "错误：$*"
    # 首次配置失败时不要留下半成品配置，否则下次启动会跳过自动生成
    rm -f "$configpath" "$configpath.pre_tun"
    exit 1
}

# 按物理内存选择预置规则档位：512MB / 1GB / 2GB 及以上
detect_mem_tier() {
    _mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    case "$_mem_kb" in
        ''|*[!0-9]*) echo 512; return ;;
    esac
    if [ "$_mem_kb" -le 614400 ]; then
        echo 512
    elif [ "$_mem_kb" -le 1572864 ]; then
        echo 1024
    else
        echo 2048
    fi
}

# 生成对应档位的预置订阅条目，id 固定，重复生成时保持稳定
preset_filters() {
    _tier="$1"
    _base="https://cdn.jsdelivr.net/gh/Ozero-top/AdguardHome-Rrules@dist"
    cat <<EOF
  - enabled: true
    url: $_base/$_tier/security.txt
    name: AGH 安全防护
    id: 601
  - enabled: true
    url: $_base/$_tier/chinese.txt
    name: AGH 中文广告
    id: 602
  - enabled: true
    url: $_base/$_tier/ads.txt
    name: AGH 全站广告
    id: 603
EOF
    [ "$_tier" = "1024" ] || [ "$_tier" = "2048" ] || return 0
    cat <<EOF
  - enabled: true
    url: $_base/$_tier/tracking.txt
    name: AGH 跟踪统计
    id: 604
EOF
    [ "$_tier" = "2048" ] || return 0
    cat <<EOF
  - enabled: true
    url: $_base/$_tier/annoyances.txt
    name: AGH 网页干扰
    id: 605
  - enabled: true
    url: $_base/$_tier/intl.txt
    name: AGH 外语分区
    id: 606
EOF
}

load_conf

[ -x "$binpath" ] || fail_bootstrap "尚未安装内核，请先在概览页安装内核。"
[ -s "$configpath" ] && exit 0
[ -f "$TEMPLATE" ] || fail_bootstrap "缺少默认配置模板：$TEMPLATE"

case "$webport" in
    ''|*[!0-9]*) webport="13800" ;;
esac
if [ "$webport" -lt 1 ] || [ "$webport" -gt 65535 ] 2>/dev/null; then
    webport="13800"
fi

mkdir -p "$workdir" "$(dirname "$configpath")" 2>/dev/null

log_msg "正在从内置模板生成首次配置..."
cp -f "$TEMPLATE" "$configpath" || fail_bootstrap "复制默认配置模板失败。"
chmod 600 "$configpath" 2>/dev/null

# 按设备内存写入预置规则（512MB 用 3 个列表，1GB 用 4 个，2GB 及以上用 5 个）
preset_tier=$(detect_mem_tier)
preset_block="$configpath.preset.$$"
preset_tmp="$configpath.tmp.$$"
preset_filters "$preset_tier" > "$preset_block" || fail_bootstrap "生成预置规则条目失败。"
if ! awk -v block="$preset_block" '
    /^[[:space:]]*# AGH_PRESET_FILTERS/ {
        while ((getline line < block) > 0) print line
        close(block)
        next
    }
    { print }
' "$configpath" > "$preset_tmp"; then
    rm -f "$preset_block" "$preset_tmp"
    fail_bootstrap "写入预置规则失败。"
fi
mv -f "$preset_tmp" "$configpath" || { rm -f "$preset_block" "$preset_tmp"; fail_bootstrap "替换配置文件失败。"; }
chmod 600 "$configpath" 2>/dev/null
rm -f "$preset_block"
log_msg "已按内存写入 $preset_tier 档预置规则。"

# 新装默认开启 DNS 缓存（16MB、TTL 不覆盖、乐观缓存关闭）；
# 若 UCI 已存在缓存选项，则以用户配置为准。
migrate_cache_conf

# 同步面板端口和 DNS 端口
yaml_set_scalar "$configpath" "address" "0.0.0.0:$webport"
yaml_set_scalar "$configpath" "port" "$dnsport"

# 上游 DNS 适配：避免 AdGuard Home 与自身 53 端口形成回环
case "$dns_mode" in
    takeover)
        # DNSMasq 已被移到 1745，指向 DNSMasq 继续解析，避免指向自身 53
        upstream="127.0.0.1:1745"
        upstream_note="DNSMasq（1745）"
        ;;
    passwall)
        # AGH 占 53，查询交给 PassWall 自己的 DNS 做分流；PassWall 未启用时回退 DNSMasq
        upstream="$(passwall_upstream_dns)"
        upstream_note="PassWall DNS（$upstream）"
        ;;
    openclash)
        # Clash 串联：DNSMasq 把查询转发给 AdGuard Home，再交给 Clash 的 DNS
        upstream="127.0.0.1:$clash_dns_port"
        upstream_note="Clash DNS（$clash_dns_port）"
        ;;
    clashfirst)
        # 前置模式：Clash 把上游交给 AdGuard Home，AdGuard Home 必须查询真实 DNS
        _crypto_up="$(dns_crypto_url)"
        if [ -n "$_crypto_up" ]; then
            upstream="$_crypto_up"
            upstream_note="加密上游（$_crypto_up）"
        else
            upstream="$(detect_real_upstream_dns)"
            upstream_note="真实上游 DNS（$upstream）"
        fi
        ;;
    upstream)
        # DNSMasq 在 53 且转发给 AdGuard Home，本机 53 会形成回环，
        # 改用实际的 Clash DNS 或 WAN 下发的 DNS，避免写死公共 DNS。
        upstream="$(detect_upstream_dns)"
        upstream_note="系统上游 DNS（$upstream）"
        ;;
    *)
        # 仅面板模式：DNSMasq 保持原端口，AGH 上游必须跟随实际端口
        _dmp="$(dnsmasq_port)"
        upstream="127.0.0.1:$_dmp"
        upstream_note="系统 DNSMasq（$_dmp）"
        ;;
esac
yaml_set_list "$configpath" "upstream_dns" "$upstream"

# 记录自动写入的上游，后续切换模式时只改动插件自己写入的值
uci -q set "$CONF.main.auto_upstream=$upstream"

# 本地 PTR 解析只允许接管 53 / PassWall 前置指向 DNSMasq，其它模式会形成查询环
if [ "$dns_mode" = "takeover" ] || [ "$dns_mode" = "passwall" ]; then
    yaml_set_scalar "$configpath" "use_private_ptr_resolvers" "true"
    yaml_set_list "$configpath" "local_ptr_upstreams" "127.0.0.1:1745"
else
    yaml_set_scalar "$configpath" "use_private_ptr_resolvers" "false"
    yaml_set_list "$configpath" "local_ptr_upstreams" ""
fi

if ! check_agh_config; then
    _err=$(tail -n 5 /var/run/adguardhome_lite_check.log 2>/dev/null | tr '\n' ' ')
    fail_bootstrap "默认配置校验失败：${_err}"
fi

uci -q set "$CONF.main.adminuser=$DEFAULT_ADMIN"
uci -q set "$CONF.main.adminpass=$DEFAULT_PASS"
uci -q commit "$CONF" 2>/dev/null

log_msg "首次配置生成完成：面板端口 $webport，DNS 端口 $dnsport，上游 DNS $upstream_note。"
log_msg "默认管理员：$DEFAULT_ADMIN，默认密码：$DEFAULT_PASS（建议首次登录后修改）。"
exit 0
