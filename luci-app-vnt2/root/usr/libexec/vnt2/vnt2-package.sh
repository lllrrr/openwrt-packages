#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

BACKUP_DIR=/tmp/vnt2-luci-app-backup
UPGRADE_MARKER=/tmp/vnt2-luci-app-upgrade
PURGE_LIST=/tmp/vnt2-luci-app-purge
INITD=/etc/init.d

pkg_upgrading() {
    local pid="$$" depth=0 args
    [ "$PKG_UPGRADE" = "1" ] && return 0
    case " $* " in *" upgrade "*) return 0 ;; esac
    while [ "$depth" -lt 16 ]; do
        case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
        args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
        case "${args%% *}" in
            opkg|*/opkg) case " $args " in *" install "*|*" upgrade "*) return 0 ;; esac ;;
            apk|*/apk) case " $args " in *" add "*|*" upgrade "*|*" fix "*) return 0 ;; esac ;;
        esac
        pid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
        depth=$((depth + 1))
    done
    return 1
}

do_prerm() {
    rm -f "$PURGE_LIST"
    if pkg_upgrading "$@"; then
        : > "$UPGRADE_MARKER"
        return 0
    fi
    rm -f "$UPGRADE_MARKER"

    local cfg_dir web_dir bin_dir
    cfg_dir="$(uci -q get vnt2.global.config_path)"
    web_dir="$(uci -q get vnt2.global.web_data_dir)"
    bin_dir="$(uci -q get vnt2.global.bin_path)"
    cfg_dir="${cfg_dir:-/etc/vnt2_config}"
    web_dir="${web_dir:-/vnt_config}"
    bin_dir="${bin_dir:-/usr/bin}"

    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/web"
    cp -f /etc/config/vnt2 "$BACKUP_DIR/vnt2" 2>/dev/null
    for f in "$cfg_dir"/*.vnt "$cfg_dir"/*.vnts; do
        [ -f "$f" ] && cp -p "$f" "$BACKUP_DIR/config/"
    done
    for f in "$web_dir"/*.toml; do
        [ -f "$f" ] && cp -p "$f" "$BACKUP_DIR/web/"
    done

    {
        for b in vnt2_web vnt2_cli vnt2_ctrl vnts2; do
            printf 'file %s\n' "$bin_dir/$b"
        done
        printf 'file %s\n' /etc/config/vnt2
        printf 'tree %s\n' /tmp/vnt2_log /var/run/vnt2
        printf 'glob %s\n' "$cfg_dir/*.vnt" "$cfg_dir/*.vnts" "$web_dir/*.toml"
        printf 'dir %s\n' "$cfg_dir" "$web_dir"
    } > "$PURGE_LIST"
}

do_postinst() {
    rm -f "$PURGE_LIST"
    if [ -f /etc/uci-defaults/99-vnt2 ]; then
        /etc/uci-defaults/99-vnt2 || true
        rm -f /etc/uci-defaults/99-vnt2
    fi

    local upgrade=0 as cfg_dir web_dir
    if [ "$PKG_UPGRADE" = "1" ] || [ -e "$UPGRADE_MARKER" ] || pidof vnt2_web vnt2_cli vnts2 >/dev/null 2>&1; then
        upgrade=1
    fi
    rm -f "$UPGRADE_MARKER"

    if [ "$upgrade" = "0" ]; then
        if [ -d "$BACKUP_DIR" ]; then
            [ -f "$BACKUP_DIR/vnt2" ] && cp -f "$BACKUP_DIR/vnt2" /etc/config/vnt2
            cfg_dir="$(uci -q get vnt2.global.config_path)"
            web_dir="$(uci -q get vnt2.global.web_data_dir)"
            cfg_dir="${cfg_dir:-/etc/vnt2_config}"
            web_dir="${web_dir:-/vnt_config}"
            mkdir -p "$cfg_dir" "$web_dir"
            for f in "$BACKUP_DIR"/config/*; do
                [ -f "$f" ] && cp -p "$f" "$cfg_dir/"
            done
            for f in "$BACKUP_DIR"/web/*; do
                [ -f "$f" ] && cp -p "$f" "$web_dir/"
            done
            rm -rf "$BACKUP_DIR"
        fi
        as="$(uci -q get vnt2.global.autostart)"
        if [ "$as" != "0" ]; then
            "$INITD/vnt2" enable
            ( setsid "$INITD/vnt2" start </dev/null >/dev/null 2>&1 & )
        fi
    fi

    "$INITD/rpcd" reload >/dev/null 2>&1 || true
    rm -rf /tmp/luci-*
}

do_postrm() {
    [ -e "$INITD/vnt2" ] && return 0
    [ -f "$PURGE_LIST" ] || return 0

    ubus call service delete '{"name":"vnt2"}' >/dev/null 2>&1 || true
    for p in $(pidof vnt2_web vnt2_cli vnt2_ctrl vnts2 2>/dev/null); do
        kill "$p" 2>/dev/null
    done

    uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\(vnt2[^.=]*\)=.*/\1/p' | while read -r sid; do
        uci -q delete "firewall.${sid}"
    done
    uci -q commit firewall
    uci -q show network 2>/dev/null | sed -n 's/^network\.\(vnt2[^.=]*\)=interface$/\1/p' | while read -r sid; do
        uci -q delete "network.${sid}"
    done
    uci -q commit network

    sed -i '/vnt2_auto_update/d' /etc/crontabs/root 2>/dev/null
    "$INITD/network" reload >/dev/null 2>&1 || true
    "$INITD/firewall" reload >/dev/null 2>&1 || true

    while read -r kind path; do
        case "$kind" in
            file) rm -f "$path" ;;
            tree) rm -rf "$path" ;;
            glob)
                for f in $path; do
                    [ -f "$f" ] && rm -f "$f"
                done
                ;;
            dir) rmdir "$path" 2>/dev/null ;;
        esac
    done < "$PURGE_LIST"

    rm -f "$PURGE_LIST" "$UPGRADE_MARKER"
    "$INITD/rpcd" reload >/dev/null 2>&1 || true
    rm -rf /tmp/luci-*
}

action="$1"
shift
case "$action" in
    prerm) do_prerm "$@" ;;
    postinst) do_postinst "$@" ;;
    postrm) do_postrm "$@" ;;
    *) exit 1 ;;
esac
exit 0
