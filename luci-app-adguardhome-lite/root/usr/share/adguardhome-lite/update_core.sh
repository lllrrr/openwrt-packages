#!/bin/sh
# AdGuard Home 管理中心 - 内核安装/更新脚本
# 功能：自动识别架构、下载官方最新正式版/预发布版、校验并替换内核。
# 说明：本脚本由 LuCI 概览页按钮调用，也可以手动执行。

. /usr/share/adguardhome-lite/common.sh

LOCK="/var/run/adguardhome_lite_update.lock"
PIDFILE="/var/run/adguardhome_lite_update.pid"
RESULT="/var/run/adguardhome_lite_update.code"
ARCHIVE=""
EXTRACT=""

# 失败原因码：用于状态文件与面板过滤
ERR_REASON="core_update_failed"

die() {
    ERR_REASON="${2:-core_update_failed}"
    log_event error "$ERR_REASON" "$1"
    exit 1
}

cleanup() {
    [ -n "$EXTRACT" ] && rm -rf "$EXTRACT"
    rm -rf "$LOCK"
    [ -n "$ARCHIVE" ] && rm -f "$ARCHIVE"
    rm -f "$PIDFILE" "/tmp/adguardhome_lite_core_check.log"
    # flock 文件保留复用，不能删除：删除后新进程会锁住新 inode，互斥失效。
    [ "$LOCK_KIND" = "flock" ] && exec 9>&-
}

# 无论成功失败都写入结果码，供 LuCI 页面轮询
finish() {
    rc=$?
    echo "$rc" > "$RESULT"
    if [ "$rc" = "0" ]; then
        state_write last_update "ok:${newver:-unknown}:$(date '+%Y-%m-%dT%H:%M:%S')"
    else
        state_write last_update "failed:${ERR_REASON:-core_update_failed}:$(date '+%Y-%m-%dT%H:%M:%S')"
    fi
    cleanup
    exit "$rc"
}

trap finish EXIT
trap 'exit 1' INT TERM

mkdir -p /var/run
rm -f "$RESULT"

# 互斥锁优先使用 flock；没有 flock 时回退到目录锁。
# 目录锁回收必须先改名再删除，避免删掉其他进程刚重建的锁（TOCTOU）。
LOCK_KIND=""
FLOCK_FILE="/var/run/adguardhome_lite_update.flock"
if have_cmd flock; then
    exec 9>"$FLOCK_FILE" 2>/dev/null || die "无法创建更新锁文件。" update_busy
    flock -n 9 || die "已有内核更新任务正在运行，请稍候。" update_busy
    LOCK_KIND="flock"
fi

if mkdir "$LOCK" 2>/dev/null; then
    :
else
    oldpid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        die "已有内核更新任务正在运行（PID $oldpid），请稍候。" update_busy
    fi
    stale="${LOCK}.stale.$$"
    if mv "$LOCK" "$stale" 2>/dev/null; then
        rm -rf "$stale"
    fi
    mkdir "$LOCK" 2>/dev/null || die "无法创建更新锁文件。" update_busy
fi
echo $$ > "$PIDFILE"

load_conf

# 页面已确认的目标通道与版本（由 LuCI 传入），优先于 UCI 当前值，
# 保证「提示的版本」和「实际安装的版本」一致
target_channel="$1"
target_ver="$2"
target_ver=${target_ver#v}
case "$target_channel" in
    stable|beta|legacy) channel="$target_channel" ;;
esac

[ -n "$binpath" ] || die "内核路径为空，请到“基础设置”中检查配置。" invalid_param
[ -n "$webport" ] || webport="13800"

arch=$(detect_agh_arch)
[ -n "$arch" ] || die "暂不支持当前设备架构：$(uname -m)。" core_arch_mismatch

case "$channel" in
    beta)
        base_url="https://static.adguard.com/adguardhome/beta"
        channel_name="预发布版"
        ;;
    legacy)
        base_url="https://static.adguard.com/adguardhome/release"
        channel_name="旧版本"
        ;;
    *)
        base_url="https://static.adguard.com/adguardhome/release"
        channel_name="正式版"
        ;;
esac

# 记录实际安装通道，供页面区分「预发布版」标识；回退正式版时会改写
installed_channel="stable"
[ "$channel" = "beta" ] && installed_channel="beta"
[ "$channel" = "legacy" ] && installed_channel="legacy"

log_msg "开始安装 AdGuard Home 内核（${channel_name}）"
log_msg "设备架构：$arch，目标路径：$binpath"

# 尽量下载到内存盘，减少闪存写入
tmp_free=$(free_kb /tmp)
if [ -n "$tmp_free" ] && [ "$tmp_free" -lt 45000 ]; then
    log_msg "提示：/tmp 可用空间约 ${tmp_free}KB，若下载失败请改用内置存储或清理空间。"
fi

static_url="$base_url/AdGuardHome_linux_${arch}.tar.gz"
release_url="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${arch}.tar.gz"
github_url="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${arch}.tar.gz"

# GitHub 反代白名单，避免 UCI 中被写入任意地址
proxy_host=""
case "$github_proxy" in
    gh-proxy.org|ghproxy.cc|ghproxy.com|ghfast.top)
        proxy_host="$github_proxy"
        ;;
esac

# 正式版下载链：页面已确认版本时按 tag 直连，其次官方 CDN 兜底
if [ -n "$target_ver" ] && [ "$channel" != "beta" ]; then
    tagged_url="https://github.com/AdguardTeam/AdGuardHome/releases/download/v${target_ver}/AdGuardHome_linux_${arch}.tar.gz"
    if [ -n "$proxy_host" ]; then
        stable_list="https://${proxy_host}/${tagged_url} ${tagged_url} ${release_url}"
    else
        stable_list="${tagged_url} ${release_url}"
    fi
elif [ -n "$proxy_host" ]; then
    stable_list="https://${proxy_host}/${github_url} $release_url $github_url"
else
    stable_list="$release_url $github_url"
fi

# 旧版本按页面确认的正式版标签直连下载；不能用 release 地址兜底，否则会装成最新正式版
legacy_tag=""
if [ "$channel" = "legacy" ]; then
    legacy_tag="$target_ver"
    if [ -z "$legacy_tag" ]; then
        die "未能确定旧版本号，请回到概览页等待版本检查完成后重试。" core_download_failed
    fi
    legacy_github="https://github.com/AdguardTeam/AdGuardHome/releases/download/v${legacy_tag}/AdGuardHome_linux_${arch}.tar.gz"
    if [ -n "$proxy_host" ]; then
        url_list="https://${proxy_host}/${legacy_github} $legacy_github"
    else
        url_list="$legacy_github"
    fi
    log_msg "使用旧版本：$legacy_tag"
fi

# 预发布版优先使用页面已确认的版本；没有时再取 GitHub 预发布标签（atom 可走反代），官方 beta 通道作兜底
beta_tag=""
beta_github=""
if [ "$channel" = "beta" ]; then
    beta_tag="$target_ver"
fi
if [ "$channel" = "beta" ] && [ -z "$beta_tag" ]; then
    atom_url="https://github.com/AdguardTeam/AdGuardHome/releases.atom"
    FEED_FILE="/tmp/adguardhome_lite_releases_$$.xml"
    atom_urls="$atom_url"
    [ -n "$proxy_host" ] && atom_urls="$atom_url https://${proxy_host}/${atom_url}"
    for _fu in $atom_urls; do
        if download_file "$_fu" "$FEED_FILE" >/dev/null 2>&1 && [ -s "$FEED_FILE" ]; then
            beta_tag=$(grep -o 'releases/tag/[^"]*' "$FEED_FILE" | sed 's#releases/tag/##' | grep -m 1 -E -- '-b\.?[0-9]')
            beta_tag=${beta_tag#v}
            [ -n "$beta_tag" ] && break
        fi
        rm -f "$FEED_FILE"
    done
    rm -f "$FEED_FILE"
fi

if [ "$channel" = "beta" ]; then
    if [ -n "$beta_tag" ]; then
        beta_github="https://github.com/AdguardTeam/AdGuardHome/releases/download/v${beta_tag}/AdGuardHome_linux_${arch}.tar.gz"
        if [ -n "$proxy_host" ]; then
            url_list="https://${proxy_host}/${beta_github} $beta_github $static_url"
        else
            url_list="$beta_github $static_url"
        fi
        log_msg "使用 GitHub 预发布版本：$beta_tag"
    else
        url_list="$static_url"
        [ -n "$proxy_host" ] && url_list="$url_list https://${proxy_host}/${static_url}"
        log_msg "未能获取预发布版标签，使用官方 beta 下载通道。"
    fi
else
    if [ "$channel" != "legacy" ]; then
        url_list="$stable_list"
        [ -n "$proxy_host" ] && log_msg "已启用 GitHub 反代：$proxy_host（优先使用）"
    fi
fi

ARCHIVE="/tmp/adguardhome_lite_update_$$.tar.gz"

try_download() {
    for _url in $1; do
        [ -n "$_url" ] || continue
        log_msg "下载地址：$_url"
        if download_file "$_url" "$ARCHIVE"; then
            # 部分反代失败时会返回 HTTP 200 的 HTML 错误页，必须校验压缩包内容
            if [ -s "$ARCHIVE" ] && tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
                return 0
            fi
            log_msg "下载内容不是有效的内核压缩包，尝试下一个..."
        else
            log_msg "该地址下载失败，尝试下一个..."
        fi
        rm -f "$ARCHIVE"
    done
    return 1
}

download_ok="0"
if try_download "$url_list"; then
    download_ok="1"
elif [ "$channel" = "beta" ]; then
    log_msg "预发布版通道不可用，回退到正式版安装..."
    channel_name="正式版"
    installed_channel="stable"
    # 回退后不再按预发布版目标版本比对，避免把正常回退判成版本不一致
    target_ver=""
    if try_download "$stable_list"; then
        download_ok="1"
    fi
fi

[ "$download_ok" = "1" ] || die "下载失败，请检查路由器网络、DNS，或在“基础设置”中更换 GitHub 反代。" core_download_failed

[ -s "$ARCHIVE" ] || die "下载文件为空，请重试。" core_integrity_failed
tar -tzf "$ARCHIVE" >/dev/null 2>&1 || die "下载文件损坏，请重试。" core_integrity_failed

# 基础完整性校验：压缩包过小或结构不符时直接拒绝，避免把错误页/半截文件当成内核。
_arc_size=$(wc -c < "$ARCHIVE" 2>/dev/null | tr -d ' ')
case "$_arc_size" in
    ''|*[!0-9]*) die "无法读取下载文件大小，请重试。" core_integrity_failed ;;
esac
[ "$_arc_size" -ge 1048576 ] || die "下载文件仅 ${_arc_size} 字节，明显小于正常内核包，已取消安装。" core_integrity_failed

_arc_entries=$(tar -tzf "$ARCHIVE" 2>/dev/null | sed 's#^\./##' | grep -c '^AdGuardHome/AdGuardHome$')
[ "$_arc_entries" = "1" ] || die "安装包结构异常（缺少 AdGuardHome/AdGuardHome），已取消安装。" core_integrity_failed

# 记录摘要便于事后核对；官方未提供固定清单时作为可追溯信息，不冒充强校验。
if have_cmd sha256sum; then
    _arc_sha=$(sha256sum "$ARCHIVE" 2>/dev/null | awk '{print $1}')
    [ -n "$_arc_sha" ] && log_msg "内核包 SHA256：$_arc_sha"
elif have_cmd openssl; then
    _arc_sha=$(openssl dgst -sha256 "$ARCHIVE" 2>/dev/null | awk '{print $NF}')
    [ -n "$_arc_sha" ] && log_msg "内核包 SHA256：$_arc_sha"
fi

EXTRACT="/tmp/adguardhome_lite_extract_$$"
mkdir -p "$EXTRACT"
tar -xzf "$ARCHIVE" -C "$EXTRACT" || die "解压失败，可能是存储空间不足。" core_integrity_failed

newbin="$EXTRACT/AdGuardHome/AdGuardHome"
[ -f "$newbin" ] || die "安装包中未找到 AdGuardHome 可执行文件。" core_integrity_failed

chmod 755 "$newbin"

# 检查新内核能否在当前 CPU 上运行
newver=$("$newbin" --version 2>/dev/null | awk '
    NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[vV][0-9]/) {
                v = $i
                # 保留 -b.2 这类预发布后缀，只去掉标点等尾部字符
                sub(/[^0-9A-Za-z.-].*$/, "", v)
                print v
                exit
            }
        }
    }')
if [ -z "$newver" ]; then
    die "新内核无法在当前设备运行，可能是架构识别错误（识别结果：$arch）。" core_arch_mismatch
fi

# 页面提示过具体版本时，拒绝安装其它版本，保证「提示的版本」与「实际安装的版本」一致
if [ -n "$target_ver" ]; then
    _nv="${newver#v}"
    _tv="${target_ver#v}"
    if [ "$_nv" != "$_tv" ]; then
        die "下载的内核版本为 $_nv，与页面确认的目标版本 $_tv 不一致，已取消安装。" core_version_mismatch
    fi
fi

newsize=$(wc -c < "$newbin" 2>/dev/null | tr -d ' ')
[ -n "$newsize" ] || die "无法读取新内核大小。" core_integrity_failed
[ "$newsize" -ge 1048576 ] || die "内核可执行文件过小（${newsize} 字节），可能已损坏。" core_integrity_failed

# 每次更换内核前都备份配置，且必须在 --check-config 之前：
# 新版内核校验时会把旧 schema 原地迁移，备份晚了就只剩迁移后的配置
cfg_bak=""
if [ -s "$configpath" ]; then
    cfg_bak="${configpath}.bak-$(date +%Y%m%d%H%M%S)"
    if cp -p "$configpath" "$cfg_bak" 2>/dev/null; then
        log_msg "更新前已备份配置：$cfg_bak"
    else
        cfg_bak=""
        log_msg "提示：配置备份失败，继续升级（原文件未被修改）。"
    fi
fi

# 用新内核校验现有配置；避免升级后服务无法启动
# 旧版本内核可能读不了已升级的配置 schema，此时从已有备份里找一份兼容的
cfg_from_backup=""
if [ -s "$configpath" ]; then
    if ! "$newbin" --check-config -c "$configpath" >/tmp/adguardhome_lite_core_check.log 2>&1; then
        log_msg "$(cat /tmp/adguardhome_lite_core_check.log 2>/dev/null)"
        if [ "$channel" = "legacy" ]; then
            for _bak in $(ls -1t "${configpath}".bak-* 2>/dev/null); do
                if "$newbin" --check-config -c "$_bak" >/dev/null 2>&1; then
                    cfg_from_backup="$_bak"
                    break
                fi
            done
            if [ -n "$cfg_from_backup" ]; then
                log_msg "当前配置与旧版本内核不兼容，将改用兼容备份：$cfg_from_backup"
            else
                die "旧版本内核无法解析当前配置（配置可能已升级到新 schema）。请恢复升级前的配置备份后重试，本次未改动内核。" config_check_failed
            fi
        else
            die "新内核无法解析现有配置文件，已取消更新。请先备份并检查配置。" config_check_failed
        fi
    fi
fi


targetdir=$(dirname "$binpath")
# 旧版本可能把内核直接放在该路径，导致同名文件挡住目录创建，先备份再建目录
if [ -e "$targetdir" ] && [ ! -d "$targetdir" ]; then
    backup="${targetdir}.bak-$(date +%Y%m%d%H%M%S)"
    mv "$targetdir" "$backup" || die "内核路径冲突：$targetdir 不是目录且无法备份。"
    log_msg "检测到同名文件，已备份为：$backup"
fi
mkdir -p "$targetdir" || die "无法创建内核目录：$targetdir"

avail=$(free_kb "$targetdir")
need=$(( newsize / 1024 + 1024 ))
if [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
    die "目标分区空间不足：需要约 ${need}KB，可用约 ${avail}KB。请清理空间或把内核路径改为 /tmp。"
fi

# 记录当前服务状态
was_running=0
is_agh_running && was_running=1
was_enabled=$(uci -q get "$CONF.main.enabled" 2>/dev/null)
[ -n "$was_enabled" ] || was_enabled="0"

log_msg "正在停止服务并替换内核..."
/etc/init.d/adguardhome_lite stop >/dev/null 2>&1

i=0
while [ $i -lt 10 ]; do
    is_agh_running || break
    sleep 1
    i=$(( i + 1 ))
done

# 服务已停止，再写入兼容配置，避免退出时又把新 schema 配置写回去
if [ -n "$cfg_from_backup" ]; then
    if cp -f "$cfg_from_backup" "$configpath" 2>/dev/null; then
        log_msg "已恢复兼容配置：$cfg_from_backup"
    else
        die "写入兼容配置失败，已取消更新，内核未改动。" config_restore_failed
    fi
fi

# 空间足够时保留一份旧内核，启动失败可自动回滚
backup=""
backup_need=$(( newsize / 1024 * 2 + 2048 ))
if [ -f "$binpath" ] && [ -n "$avail" ] && [ "$avail" -ge "$backup_need" ]; then
    if cp -f "$binpath" "$binpath.bak" 2>/dev/null; then
        backup="$binpath.bak"
    fi
fi

if ! cp -f "$newbin" "$binpath.new" 2>/dev/null; then
    die "复制内核失败，请检查目标分区空间。"
fi
chmod 755 "$binpath.new" 2>/dev/null
if ! mv -f "$binpath.new" "$binpath" 2>/dev/null; then
    rm -f "$binpath.new"
    die "替换内核失败，请检查文件权限或空间。"
fi

log_msg "内核已替换，版本：$newver，大小：$(( newsize / 1024 / 1024 ))MB"

# 内核已更换，清掉控制器缓存的版本号，避免页面继续显示旧版本
rm -f /var/run/adguardhome_lite_core_version

# 如果原来在运行或已设置开机自启，则启动服务
if [ "$was_enabled" = "1" ] || [ "$was_running" = "1" ]; then
    log_msg "正在启动 AdGuard Home..."
    /etc/init.d/adguardhome_lite start >/dev/null 2>&1

    i=0
    while [ $i -lt 12 ]; do
        is_agh_running && break
        sleep 1
        i=$(( i + 1 ))
    done

    if ! is_agh_running; then
        log_msg "新内核启动失败，开始回滚..."
        /etc/init.d/adguardhome_lite stop >/dev/null 2>&1
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            mv -f "$backup" "$binpath" 2>/dev/null
            /etc/init.d/adguardhome_lite start >/dev/null 2>&1
            if [ -n "$cfg_bak" ]; then
                die "新内核启动失败，已回滚到旧版本。如配置也需要回退，执行：cp -f $cfg_bak $configpath" core_start_failed
            fi
            die "新内核启动失败，已回滚到旧版本。请查看运行日志。" core_start_failed
        fi
        die "新内核启动失败，且没有可回滚的旧版本。请查看运行日志。" core_start_failed
    fi
fi

[ -n "$backup" ] && rm -f "$backup"

uci -q set "$CONF.main.core_version=$newver" 2>/dev/null
uci -q set "$CONF.main.core_channel=$installed_channel" 2>/dev/null
uci -q commit "$CONF" 2>/dev/null

log_msg "AdGuard Home 内核安装/更新成功：$newver"
if [ -n "$cfg_bak" ]; then
    log_msg "切换前的配置备份：$cfg_bak（回退配置：cp -f $cfg_bak $configpath）"
fi
exit 0
