#!/bin/sh
# AdGuard Home 管理中心 - 应用 LuCI 设置
# 功能：停止服务、更新端口、重新应用 DNS 接管模式并启动服务。

. /usr/share/adguardhome-lite/common.sh

# 整段应用过程（含 stop/start 触发的 dns_mode.sh 调用）必须串行，
# 否则面板连点保存会并发改写 DNSMasq 端口与 nft 规则，留下断网布局。
lock_action || exit 1

load_conf

# 老版本升级：UCI 没有缓存选项时，沿用当前 YAML 状态，避免覆盖用户选择。
migrate_cache_conf

# 「Clash 串联」已下线：dnsmasq 会优先采用 Clash 写入的默认上游，
# 过滤实际不生效，这里自动迁移到「接管 53 端口」。
if [ "$dns_mode" = "openclash" ]; then
    log_msg "「Clash 串联」模式已下线，已切换为「接管 53 端口」。"
    openclash_forward_del
    uci -q set "$CONF.main.dns_mode=takeover"
    uci -q commit "$CONF" 2>/dev/null
    dns_mode="takeover"
    dnsport="53"
fi

case "$webport" in
    ''|*[!0-9]*) webport="13800" ;;
esac
if [ "$webport" -lt 1 ] || [ "$webport" -gt 65535 ] 2>/dev/null; then
    webport="13800"
fi

mkdir -p /var/run 2>/dev/null
log_msg "开始应用 AdGuard Home 设置..."

# 停止服务时会触发 service_stopped，自动恢复 DNSMasq 原始设置。
# 但这里紧接着要重新接管，恢复动作会把 DNSMasq 抢回 53，与尚未完全退出的
# AdGuard Home 抢端口（实测 dnsmasq 连续崩溃 6 次），因此标记为「重新应用中」。
if [ -x /etc/init.d/adguardhome_lite ]; then
    AGH_APPLYING=1
    export AGH_APPLYING
    /etc/init.d/adguardhome_lite stop >/dev/null 2>&1
    unset AGH_APPLYING
fi

# 防御性处理：procd 未成功结束进程时强制清理，确保端口修改能生效
i="0"
while [ "$i" -lt 8 ]; do
    is_agh_running || break
    sleep 1
    i=$(( i + 1 ))
done
force_stop_agh

# 已生成配置文件时，同步面板端口和 DNS 端口
if [ -s "$configpath" ]; then
    cp -f "$configpath" "$configpath.bak" 2>/dev/null
    yaml_set_scalar "$configpath" "address" "$webaddr:$webport"
    yaml_set_scalar "$configpath" "port" "$dnsport"

    # 只调整插件自己写入的上游；用户自定义的上游保持不变，
    # 也不再写死公共 DNS（DNSMasq 上游模式按实际环境选择 Clash / WAN DNS）。
    _cur_up=$(yaml_get_list "$configpath" "upstream_dns")
    _auto_up=$(uci -q get "$CONF.main.auto_upstream" 2>/dev/null)
    _self_ip=$(lan_ipv4)
    _crypto_up="$(dns_crypto_url)"

    # 自定义上游优先：固定使用用户填写的列表，不再按接管方式改写。
    _custom_up_applied=0
    if [ "$upstream_source" = "custom" ] && [ -n "$upstream_custom" ]; then
        _custom_up_applied=1
        if [ "$_cur_up" != "$upstream_custom" ]; then
            yaml_set_list "$configpath" "upstream_dns" "$upstream_custom"
        fi
        uci -q set "$CONF.main.auto_upstream=$upstream_custom"
        log_msg "已应用自定义上游 DNS：$upstream_custom"

        # 自定义上游含 DoH/DoT/DoQ 域名时，bootstrap 为空会导致解析失败
        case " $upstream_custom " in
            *" https://"*|*" tls://"*|*" quic://"*)
                _cur_boot=$(yaml_get_list "$configpath" "bootstrap_dns")
                if [ -z "$_cur_boot" ]; then
                    yaml_set_list "$configpath" "bootstrap_dns" "223.5.5.5 119.29.29.29"
                    log_msg "bootstrap DNS 为空，已补充 223.5.5.5、119.29.29.29。"
                fi
                ;;
        esac

        if [ -n "$_crypto_up" ]; then
            log_msg "已使用自定义上游 DNS，加密预设未应用。"
        fi
    fi

    if [ "$_custom_up_applied" = "0" ]; then
        case "$dns_mode" in
            takeover) _target_up="127.0.0.1:1745" ;;
            openclash) _target_up="127.0.0.1:$clash_dns_port" ;;
            clashfirst)
                if [ -n "$_crypto_up" ]; then
                    _target_up="$_crypto_up"
                else
                    _target_up="$(detect_real_upstream_dns)"
                fi
                ;;
            upstream) _target_up="$(detect_upstream_dns)" ;;
            passwall)
                _target_up="$(passwall_upstream_dns)"
                if ! passwall_enabled; then
                    log_msg "PassWall 未启用，AdGuard Home 上游回退到本机 DNSMasq（1745）。"
                elif [ -z "$(passwall_runtime_var)" ]; then
                    log_msg "PassWall 尚未启动，暂按默认端口 $(passwall_dns_port) 设置上游；实际端口不同时插件会自动跟随。"
                fi
                ;;
            *) _target_up="127.0.0.1:$(dnsmasq_port)" ;;
        esac

        # 加密上游只对「AdGuard Home → 真实上游」这一段有效；
        # 其它模式的上游是本机 DNSMasq/Clash，开启也不会加密出公网的查询。
        if [ -n "$_crypto_up" ] && [ "$dns_mode" != "clashfirst" ]; then
            log_msg "加密上游仅在「Clash 前置」模式生效，当前模式已忽略。"
        fi

        # 兼容旧版本：auto_upstream 缺失时，current 为插件曾写入的默认值也视为可改
        _is_auto=0
        [ -n "$_auto_up" ] && [ "$_cur_up" = "$_auto_up" ] && _is_auto=1
        case "$_cur_up" in
            "127.0.0.1"|"127.0.0.1:53"|"127.0.0.1:1745"|"127.0.0.1:$clash_dns_port"|"127.0.0.1:5335"|127.0.0.1:114[0-9][0-9]|"223.5.5.5 119.29.29.29"|"$_self_ip")
                _is_auto=1
                ;;
        esac
        # PassWall 模式的上游是本机局域网 IP:PassWall DNS 端口，同样视为插件写入
        if [ "$dns_mode" = "passwall" ] && [ -n "$_self_ip" ]; then
            case "$_cur_up" in
                "$_self_ip":*) _is_auto=1 ;;
            esac
        fi

        if [ "$_is_auto" = "1" ] && [ "$_cur_up" != "$_target_up" ]; then
            yaml_set_list "$configpath" "upstream_dns" "$_target_up"
            uci -q set "$CONF.main.auto_upstream=$_target_up"
            log_msg "已根据 DNS 接管方式调整上游 DNS：$_target_up"
        elif [ "$_is_auto" = "1" ] && [ "$_auto_up" != "$_target_up" ]; then
            # 上游已是目标值（如手动改过地址）时，同步记录，避免下次判断拿到旧值
            uci -q set "$CONF.main.auto_upstream=$_target_up"
        fi

        # DoH/DoT 上游需要 bootstrap 解析解析器域名。
        # 只改插件管理的上游；用户手工填写的上游和 bootstrap 保持不动。
        if [ "$dns_mode" = "clashfirst" ] && [ -n "$_crypto_up" ]; then
            if [ "$_is_auto" != "1" ]; then
                log_msg "检测到自定义上游 DNS，加密预设未应用。"
            else
                _cur_boot=$(yaml_get_list "$configpath" "bootstrap_dns")
                if [ -z "$_cur_boot" ]; then
                    yaml_set_list "$configpath" "bootstrap_dns" "223.5.5.5 119.29.29.29"
                    log_msg "bootstrap DNS 为空，已补充 223.5.5.5、119.29.29.29。"
                elif [ "$_cur_boot" != "223.5.5.5 119.29.29.29" ]; then
                    log_msg "检测到自定义 bootstrap DNS，已保持用户设置。"
                fi
                log_msg "已启用加密上游：$_crypto_up"
            fi
        fi
    fi

    # 本地 PTR 解析：只调整插件自己写入的值，用户自定义的反向解析保持不动。
    # 接管 53 模式才可以指向 DNSMasq（1745），其它模式会形成反向查询环。
    _ptr_up="127.0.0.1:53"
    [ "$dns_mode" = "takeover" ] && _ptr_up="127.0.0.1:1745"
    _cur_ptr=$(yaml_get_list "$configpath" "local_ptr_upstreams")
    _auto_ptr=$(uci -q get "$CONF.main.auto_ptr" 2>/dev/null)
    _ptr_owned=0
    case "$_cur_ptr" in
        ""|"127.0.0.1"|"127.0.0.1:53"|"127.0.0.1:1745")
            _ptr_owned=1
            ;;
        *)
            if [ -n "$_auto_ptr" ] && [ "$_cur_ptr" = "$_auto_ptr" ]; then
                _ptr_owned=1
            fi
            ;;
    esac

    if [ "$_ptr_owned" = "1" ]; then
        if [ "$dns_mode" = "takeover" ]; then
            yaml_set_scalar "$configpath" "use_private_ptr_resolvers" "true"
            yaml_set_list "$configpath" "local_ptr_upstreams" "$_ptr_up"
            uci -q set "$CONF.main.auto_ptr=$_ptr_up"
        else
            yaml_set_scalar "$configpath" "use_private_ptr_resolvers" "false"
            yaml_set_list "$configpath" "local_ptr_upstreams" ""
            uci -q set "$CONF.main.auto_ptr="
        fi
    else
        log_msg "检测到自定义反向解析（PTR）配置，已保持用户设置。"
    fi

    # DNS 缓存：由插件配置控制，默认开启；老配置已在上方迁移。
    # 注意不要自动开启安全浏览（safebrowsing）：它依赖 AdGuard 的在线服务，
    # 国内网络不可达时会拖慢甚至阻塞解析，需要时请用户在面板手动开启。
    # 缓存已通过 AdGuard Home API 在线应用时，跳过 YAML 写入，避免重复覆盖
    _cache_api=0
    if [ "$(uci -q get "$CONF.main.cache_api_applied" 2>/dev/null)" = "1" ]; then
        _cache_api=1
        uci -q delete "$CONF.main.cache_api_applied"
        uci -q commit "$CONF" 2>/dev/null
        log_event info cache_api_applied "缓存设置已通过 AdGuard Home API 在线应用，跳过 YAML 写入。"
    fi

    if [ "$_cache_api" = "0" ]; then
    case "$cache_enabled" in 0|1) ;; *) cache_enabled=1 ;; esac
    case "$cache_optimistic" in 0|1) ;; *) cache_optimistic=0 ;; esac
    case "$cache_size_mb" in ''|*[!0-9]*) cache_size_mb=16 ;; esac
    [ "$cache_size_mb" -ge 1 ] 2>/dev/null && [ "$cache_size_mb" -le 256 ] 2>/dev/null || cache_size_mb=16
    case "$cache_ttl_min" in ''|*[!0-9]*) cache_ttl_min=0 ;; esac
    [ "$cache_ttl_min" -le 604800 ] 2>/dev/null || cache_ttl_min=604800
    case "$cache_ttl_max" in ''|*[!0-9]*) cache_ttl_max=0 ;; esac
    [ "$cache_ttl_max" -le 604800 ] 2>/dev/null || cache_ttl_max=604800
    if [ "$cache_ttl_max" -gt 0 ] && [ "$cache_ttl_min" -gt "$cache_ttl_max" ]; then
        cache_ttl_min="$cache_ttl_max"
    fi

    # 缓存单一配置源：以 AdGuard Home 的 YAML 为准。
    # 插件 UI 没改过（UCI 与上次写入一致）但 YAML 被 AGH 面板改过时，采纳 YAML；
    # 否则把插件 UI 的值写入 YAML（保存动作本身就是显式修改）。
    _cache_sig="$cache_enabled|$cache_size_mb|$cache_ttl_min|$cache_ttl_max|$cache_optimistic"
    _cache_applied="$(uci -q get "$CONF.main.cache_applied" 2>/dev/null)"
    _cache_yaml="$(cache_yaml_signature "$configpath" 2>/dev/null)"
    _cache_adopt=0
    if [ -n "$_cache_yaml" ]; then
        if [ -z "$_cache_applied" ]; then
            # 首次运行或老版本升级：以现有 YAML 为准
            _cache_adopt=1
        elif [ "$_cache_sig" = "$_cache_applied" ] && [ "$_cache_yaml" != "$_cache_applied" ]; then
            # 插件 UI 没改过，但 YAML 被 AGH 面板改过：采纳 YAML
            _cache_adopt=1
        fi
    fi
    if [ "$_cache_adopt" = "1" ]; then
        _old_ifs="$IFS"
        IFS='|'
        set -- $_cache_yaml
        IFS="$_old_ifs"
        cache_enabled="$1"
        cache_size_mb="$2"
        cache_ttl_min="$3"
        cache_ttl_max="$4"
        cache_optimistic="$5"
        uci -q set "$CONF.main.cache_enabled=$cache_enabled"
        uci -q set "$CONF.main.cache_size_mb=$cache_size_mb"
        uci -q set "$CONF.main.cache_ttl_min=$cache_ttl_min"
        uci -q set "$CONF.main.cache_ttl_max=$cache_ttl_max"
        uci -q set "$CONF.main.cache_optimistic=$cache_optimistic"
        _cache_sig="$_cache_yaml"
        log_msg "已按 AdGuard Home 现有配置同步缓存设置。"
    fi

    _cache_bool="false"
    _opt_bool="false"
    if [ "$cache_enabled" = "1" ]; then
        _cache_bool="true"
        if [ "$cache_optimistic" = "1" ]; then
            _opt_bool="true"
        fi
    fi

    yaml_set_scalar "$configpath" "cache_enabled" "$_cache_bool"
    yaml_set_scalar "$configpath" "cache_size" "$(( cache_size_mb * 1024 * 1024 ))"
    yaml_set_scalar "$configpath" "cache_ttl_min" "$cache_ttl_min"
    yaml_set_scalar "$configpath" "cache_ttl_max" "$cache_ttl_max"
    yaml_set_scalar "$configpath" "cache_optimistic" "$_opt_bool"
    uci -q set "$CONF.main.cache_applied=$_cache_sig"
    uci -q commit "$CONF" 2>/dev/null

    if [ "$_cache_bool" = "true" ]; then
        log_msg "已应用 DNS 缓存：开启（${cache_size_mb}MB，TTL ${cache_ttl_min}-${cache_ttl_max}，乐观缓存 ${_opt_bool}）。"
    else
        log_msg "已应用 DNS 缓存：关闭。"
    fi
    fi

    # 过滤列表下载代理：只改插件自己写入的值，用户自定义的 http_proxy 保持不动。
    _proxy="$(detect_http_proxy)"
    _cur_proxy="$(yaml_get_root_scalar "$configpath" "http_proxy")"
    _auto_proxy="$(uci -q get "$CONF.main.auto_http_proxy" 2>/dev/null)"
    if [ -z "$_cur_proxy" ] || { [ -n "$_auto_proxy" ] && [ "$_cur_proxy" = "$_auto_proxy" ]; }; then
        yaml_set_root_scalar "$configpath" "http_proxy" "$_proxy"
        uci -q set "$CONF.main.auto_http_proxy=$_proxy"
        if [ -n "$_proxy" ]; then
            log_msg "过滤列表下载已走 Clash 代理：$_proxy"
        else
            log_msg "未检测到可用的 Clash HTTP 代理，过滤列表将直连下载。"
        fi
    else
        log_msg "检测到自定义 http_proxy，已保持用户设置。"
    fi

    # 前置模式下来源全是 127.0.0.1，回环地址必须跳出限速，
    # 否则一个客户端超过 20 qps 就会被 AdGuard Home 拒绝。
    # 注意：ratelimit_whitelist 只接受单个 IP，写 CIDR 会导致配置校验失败。
    if [ "$dns_mode" = "clashfirst" ]; then
        _rl=$(awk '$0 ~ "^  ratelimit:" {print $2; exit}' "$configpath" 2>/dev/null)
        _wl=$(yaml_get_list "$configpath" "ratelimit_whitelist")
        if [ -n "$_rl" ] && [ "$_rl" != "0" ] && [ -z "$_wl" ]; then
            yaml_set_list "$configpath" "ratelimit_whitelist" "127.0.0.1 ::1"
            log_msg "已把回环地址加入限速白名单（前置模式查询来源都是 127.0.0.1）。"
        fi
    fi

    # 兼容 1.1.4/1.1.5 生成的配置：把白名单里的 CIDR 改回单个 IP
    _wl_cidr=$(awk '/^  ratelimit_whitelist:/{f=1;next} f&&/^    - /{print;next} f{f=0}' "$configpath" 2>/dev/null | grep -cE '127\.0\.0\.0/8|::1/128')
    if [ "${_wl_cidr:-0}" != "0" ]; then
        yaml_fix_ratelimit_whitelist "$configpath"
        log_msg "已修正限速白名单格式（CIDR 改为单个 IP）。"
    fi

    if ! check_agh_config; then
        _err=$(tail -n 3 /var/run/adguardhome_lite_check.log 2>/dev/null | tr '\n' ' ')
        log_event warn config_check_failed "配置校验失败，正在恢复备份。${_err}"
        if ! cp -f "$configpath.bak" "$configpath" 2>/dev/null || ! check_agh_config; then
            state_write last_apply "failed:config_restore_failed:$(date '+%Y-%m-%dT%H:%M:%S')"
            log_event error config_restore_failed "恢复备份失败，已中止本次应用，避免使用损坏的配置启动。"
            exit 1
        fi
        state_write last_apply "reverted:config_check_failed:$(date '+%Y-%m-%dT%H:%M:%S')"
    fi
fi

if [ "$enabled" = "1" ]; then
    /etc/init.d/adguardhome_lite enable >/dev/null 2>&1
    log_msg "正在启动 AdGuard Home..."
    /etc/init.d/adguardhome_lite start >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        state_write last_apply "failed:service_start_failed:$(date '+%Y-%m-%dT%H:%M:%S')"
        log_event error service_start_failed "启动命令返回错误码 $_rc，请到“运行日志”查看原因。"
    else
        state_write last_apply "ok:$(date '+%Y-%m-%dT%H:%M:%S')"
    fi

    # 前置模式下 AdGuard Home 先启动，再让 Clash 重载上游，
    # 避免重启 Clash 时 5335 还没有监听导致 DNS 中断。
    if [ "$dns_mode" = "clashfirst" ]; then
        clashfirst_clash_refresh
    fi
else
    /etc/init.d/adguardhome_lite disable >/dev/null 2>&1
    # stop 阶段跳过了自动恢复，这里必须显式还原，否则 DNSMasq 留在 1745 而 53 无人监听
    /usr/share/adguardhome-lite/dns_mode.sh revert >/dev/null 2>&1
    log_msg "服务已停止，并已取消开机自启。"
fi

log_msg "设置应用完成。"
exit 0
