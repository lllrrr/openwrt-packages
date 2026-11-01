#!/bin/sh

# cron 触发时 PATH 由 crond 继承，部分固件下不含 /sbin（uci 所在目录）。
# uci 一旦取不到值，镜像 / 发布通道 / 架构 / 安装路径都会静默退回默认值，
# 最坏情况是把 gately 装到 /usr/bin/gately 而不是自定义路径，所以在这里固定 PATH。
export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

UPDATE_DIR="/tmp/gately-plus-update"
RUN_DIR="$UPDATE_DIR/.run_$$"
STATUS_FILE="$UPDATE_DIR/status"
AUTO_STATUS_FILE="$UPDATE_DIR/autostatus"
LOG_FILE="$UPDATE_DIR/log"
RELEASES_FILE="$UPDATE_DIR/releases.json"
AUTO_LOG="$UPDATE_DIR/autoupdate.log"
LOCK_DIR="$UPDATE_DIR/.lock"
AUTO_LOG_MAX=65536

PROGRESS_FILE="$UPDATE_DIR/progress"
CHECKSUMS_FILE="$UPDATE_DIR/checksums.txt"

trap 'rm -rf "$RUN_DIR"; release_lock' EXIT

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    [ -n "$LOG_TO_FILE" ] && echo "$msg" >> "$LOG_TO_FILE"
}

# 同一时间只允许一个更新任务（cron 撞上手动点击时避免互相覆盖二进制）
# 锁内记录持有者 pid：同进程重复获取（auto → check → download）视为已持有。
acquire_lock() {
    local holder
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ -n "$holder" ] && [ "$holder" = "$$" ] && return 0
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        log "Another update is already running (pid $holder)"
        return 1
    fi
    log "Removing stale lock (pid ${holder:-?})"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    echo $$ > "$LOCK_DIR/pid"
    return 0
}

release_lock() {
    local holder
    holder=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ "$holder" = "$$" ] && rm -rf "$LOCK_DIR"
}

# 自动更新日志改为追加（保留历史），超过上限时只留后半段，避免 tmpfs 被写满
auto_log_open() {
    mkdir -p "$UPDATE_DIR"
    local sz=""
    [ -f "$AUTO_LOG" ] && sz=$(wc -c < "$AUTO_LOG" 2>/dev/null | tr -d ' ')
    case "$sz" in
        ''|*[!0-9]*) ;;
        *) [ "$sz" -gt "$AUTO_LOG_MAX" ] && tail -c $((AUTO_LOG_MAX / 2)) "$AUTO_LOG" > "$AUTO_LOG.tmp" \
               && mv "$AUTO_LOG.tmp" "$AUTO_LOG" ;;
    esac
    printf '\n===== %s (%s) =====\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-cron}" >> "$AUTO_LOG"
}

# Gately 仅在 GitHub 发布。为避免 GitHub REST API 未认证限流（60 次/小时），
# 版本列表走 git smart-http 的 info/refs（纯 HTTP，不走 API，不限流），
# 下载地址按发布命名规律直接构造。
REPO_URL="https://github.com/wangwanjie/gately"

# 可选 GitHub 加速镜像前缀（如 https://ghfast.top/）。
# 直连 github.com 超时（curl rc=28）时在「下载与更新」页填写；留空则直连。
GH_MIRROR=$(uci -q get gately_plus.gately.github_mirror 2>/dev/null)
case "$GH_MIRROR" in
    ""|*/) ;;
    *) GH_MIRROR="$GH_MIRROR/" ;;
esac

# 镜像开关：默认启用；一旦镜像请求失败就置 0，本次运行剩余请求全部回退直连，
# 避免无人值守的自动更新因为镜像站点故障整个失败。
USE_MIRROR=1

gh_url() {
    local u="$1"
    if [ -n "$GH_MIRROR" ] && [ "$USE_MIRROR" = "1" ]; then
        printf '%s%s' "$GH_MIRROR" "$u"
    else
        printf '%s' "$u"
    fi
}

# 去掉 URL 上的镜像前缀，得到直连地址
direct_url() {
    printf '%s' "$1" | sed "s#^${GH_MIRROR}##"
}

# 镜像请求失败时关闭镜像；调用方据此用直连重试一次
mirror_off() {
    { [ -n "$GH_MIRROR" ] && [ "$USE_MIRROR" = "1" ]; } || return 1
    USE_MIRROR=0
    log "Mirror request failed (rc=${1:-?}), falling back to direct github.com"
    return 0
}

init_dir() {
    [ -d "$UPDATE_DIR" ] || mkdir -p "$UPDATE_DIR"
    mkdir -p "$RUN_DIR"
}

tag_to_ver() { echo "$1" | sed 's/^v//'; }

uci_get() {
    local v; v=$(uci -q get "gately_plus.gately.$1" 2>/dev/null)
    echo "${v:-$2}"
}

write_status() {
    echo "$1" > "${STATUS_TARGET:-$STATUS_FILE}"
}

die() {
    local code="$1" detail="${2:-$1}"
    log "ERROR: $detail"
    write_status "error:$code"
    exit 1
}

CURL_UA="Mozilla/5.0 (compatible; luci-app-gately-plus)"

http_get() {
    local url="$1" out="$2" t="${3:-60}"
    curl -fsSL -A "$CURL_UA" --connect-timeout 10 --max-time "$t" -o "$out" "$url"
}

# 输出 body 到 stdout；把 curl 的错误合并捕获，失败时记到日志便于诊断
# （rc=6 DNS 失败、rc=7 连接被拒、rc=28 超时、rc=22 HTTP 错误）
http_get_var() {
    local url="$1" t="${2:-30}" out rc
    out=$(curl -fsSL -A "$CURL_UA" --connect-timeout 10 --max-time "$t" "$url" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        log "curl rc=$rc url=$url: $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
        return $rc
    fi
    printf '%s' "$out"
}

# Gately 为 Go 架构命名，文件名形如 gately_<tag>_linux_<arch>.tar.gz
detect_arch() {
    local a; a=$(uci -q get gately_plus.gately.arch 2>/dev/null)
    [ -n "$a" ] && [ "$a" != "auto" ] && echo "$a" && return
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "arm" ;;
        armv8*)        echo "arm64" ;;
        riscv64)       echo "riscv64" ;;
        mips)          echo "mips" ;;
        mipsel|mipsle) echo "mipsle" ;;
        *)             echo "amd64" ;;
    esac
}

fmt_size() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "unknown"
        return
    fi
    awk -v b="$bytes" 'BEGIN{
        if(b>=1048576) printf "%.1fM", b/1048576
        else           printf "%.1fKB", b/1024
    }'
}

# 预发布后缀归一化：dev<alpha<beta<rc，输出 rank.num
pre_key() {
    local s="$1" word num rank
    word=$(printf '%s' "$s" | grep -oE '[a-zA-Z]+' | head -1)
    num=$(printf '%s' "$s" | grep -oE '[0-9]+' | head -1)
    num=${num:-0}
    case "$word" in
        dev)               rank=0 ;;
        alpha|a)           rank=1 ;;
        beta|b)            rank=2 ;;
        rc|c)              rank=3 ;;
        *)                 rank=0 ;;
    esac
    echo "${rank}.${num}"
}

# 语义化版本比较：返回 0 表示 $1 < $2
version_lt() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    # 空值没有可比性：不声称「更旧」，交给调用方按「未知」处理
    [ -z "$a" ] && return 1
    [ -z "$b" ] && return 1
    [ "$a" = "$b" ] && return 1

    local ca cb pa pb
    ca="${a%%-*}"; [ "$ca" = "$a" ] && pa="" || pa="${a#*-}"
    cb="${b%%-*}"; [ "$cb" = "$b" ] && pb="" || pb="${b#*-}"

    # 比较数字核心（逐段，缺省补 0）
    local i n na nb va vb
    na=$(printf '%s' "$ca" | awk -F. '{print NF}')
    nb=$(printf '%s' "$cb" | awk -F. '{print NF}')
    n=$na; [ "$nb" -gt "$n" ] && n=$nb
    for i in $(seq 1 "$n"); do
        va=$(printf '%s' "$ca" | awk -F. -v i="$i" '{print $i}'); va=${va:-0}
        vb=$(printf '%s' "$cb" | awk -F. -v i="$i" '{print $i}'); vb=${vb:-0}
        # 非数字段按 0 处理：手工改坏的版本串不能把 [ -lt ] 变成语法错误
        case "$va" in ''|*[!0-9]*) va=0 ;; esac
        case "$vb" in ''|*[!0-9]*) vb=0 ;; esac
        [ "$va" -lt "$vb" ] && return 0
        [ "$va" -gt "$vb" ] && return 1
    done

    # 核心相同：正式版 > 预发布版
    if [ -z "$pa" ] && [ -n "$pb" ]; then return 1; fi
    if [ -n "$pa" ] && [ -z "$pb" ]; then return 0; fi
    [ -z "$pa" ] && [ -z "$pb" ] && return 1

    # 都为预发布：比较后缀
    local ka kb lo
    ka=$(pre_key "$pa"); kb=$(pre_key "$pb")
    [ "$ka" = "$kb" ] && return 1
    lo=$(printf '%s\n%s' "$ka" "$kb" | sort -V | head -1)
    [ "$lo" = "$ka" ]
}

# 从二进制自身读取版本，这是唯一可信的来源。
# gately -version 输出小写 JSON：{"version":"0.6.2","commit":...,"buildDate":...,"go":...}
# uci 里的 installed_version 只在本插件下载安装时写入，用户手动放置/替换过的
# 二进制与它毫无关系，拿它当「当前版本」会得出错误结论。
probe_binary_version() {
    local bin="$1" out ver
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 10 "$bin" -version 2>&1)
    else
        out=$("$bin" -version 2>&1)
    fi
    [ -n "$out" ] || return 1
    # 紧凑化后按 JSON 取 version 字段，避免受空格/换行/附加日志影响
    ver=$(printf '%s' "$out" | tr -d ' \t\r\n' \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$ver" ] || return 1
    printf '%s\n' "$ver" | sed 's/^v//'
}

# uci 里记录的版本，仅作二进制探测失败时的兜底。
# 记录里带路径：用户换过 binpath 后，旧记录说的是另一个文件，不能沿用。
get_installed_version() {
    local v p cur
    v=$(uci -q get gately_plus.gately.installed_version 2>/dev/null)
    [ -n "$v" ] || return 0
    p=$(uci -q get gately_plus.gately.installed_version_path 2>/dev/null)
    cur=$(uci_get binpath /usr/bin/gately)
    if [ -n "$p" ] && [ "$p" != "$cur" ]; then
        log "Ignore recorded version $v: it belongs to $p (current binpath $cur)"
        return 0
    fi
    printf '%s\n' "$v"
}

save_installed_version() {
    uci -q set gately_plus.gately.installed_version="$1" 2>/dev/null
    [ -n "$2" ] && uci -q set gately_plus.gately.installed_version_path="$2" 2>/dev/null
    uci -q commit gately_plus 2>/dev/null
}

# 判断 tag 是否为预发布（去 v 后含 - 后缀，如 v0.6.0-rc1）
is_prerelease_tag() {
    local v; v=$(tag_to_ver "$1")
    case "$v" in
        *-*) return 0 ;;
        *)   return 1 ;;
    esac
}

# 从 info/refs 拉取全部 tag（每行一个，已去重、去掉 ^{}）
# 字符类需含 "-"，否则 v0.6.0-rc1 这类预发布 tag 会被截断成 v0.6.0。
fetch_tags() {
    local i url out rc tags
    # 最多 4 轮：第 1 轮走镜像（若配置），失败后关闭镜像再用直连重试 3 轮
    for i in 1 2 3 4; do
        url=$(gh_url "$REPO_URL/info/refs?service=git-upload-pack")
        out=$(http_get_var "$url" 30); rc=$?
        if [ $rc -eq 0 ]; then
            tags=$(printf '%s' "$out" \
                | grep -aoE 'refs/tags/v[0-9][0-9A-Za-z.-]*' \
                | sed 's#refs/tags/##' | sort -u)
            if [ -n "$tags" ]; then
                printf '%s\n' "$tags"
                return 0
            fi
        fi
        # 镜像不可用 → 关掉镜像立刻用直连重试（不消耗重试次数）
        if mirror_off "$rc"; then
            continue
        fi
        log "Tag list empty, retrying ($i/4)..."
        sleep 2
    done
    return 1
}

# 对 stdin 的 tag 行做降序排序（最新在前）。
# 关键：在弱性能路由器上不能用 O(n^2) 的 shell 逐版比较（会 fork 上千进程、
# 长时间卡在 checking）。这里用单个 awk 把每个版本转成「定长、可字典序排序」
# 的键，再交给单个 sort -r，全程只 fork 3 个进程，与版本数量无关。
sort_tags_desc() {
    awk '{
        v = $0; sub(/^v/, "", v);
        p = index(v, "-");
        if (p > 0) { core = substr(v, 1, p - 1); pre = substr(v, p + 1); }
        else       { core = v; pre = ""; }

        m = split(core, seg, ".");
        key = "";
        for (i = 1; i <= 4; i++) {
            x = (i <= m) ? (seg[i] + 0) : 0;
            key = key sprintf("%06d", x);
        }

        if (pre == "") {
            # 正式版：末位给 9，保证排在同核心的预发布版之前
            key = key "9";
        } else {
            w = pre; gsub(/[0-9].*/, "", w);
            n = pre; sub(/^[a-zA-Z]*/, "", n); if (n == "") n = 0;
            r = 0;
            if (w == "dev")                         r = 0;
            else if (w == "alpha" || w == "a")      r = 1;
            else if (w == "beta"  || w == "b")      r = 2;
            else if (w == "rc"    || w == "c")      r = 3;
            key = key sprintf("%d%06d", r, n + 0);
        }
        print key "\t" $0;
    }' | sort -r | cut -f2
}

# 构造某个 tag + arch 的文件名
file_for() {
    echo "gately_${1}_linux_${2}.tar.gz"
}

# 从已排序的 tags 文件构造 releases JSON（每个版本针对当前 arch 提供一个 tar.gz）
build_releases_from_tags() {
    local tags_file="$1" arch="$2" reltype="$3"
    local result="" tag fname url download_base
    download_base=$(gh_url "$REPO_URL/releases/download")
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if is_prerelease_tag "$tag" && [ "$reltype" != "prerelease" ]; then
            continue
        fi
        fname=$(file_for "$tag" "$arch")
        url="${download_base}/${tag}/${fname}"
        result="${result:+$result,}{\"tag\":\"$tag\",\"best\":\"$fname\",\"best_url\":\"$url\",\"files\":[{\"name\":\"$fname\",\"url\":\"$url\"}]}"
    done < "$tags_file"
    printf '[%s]\n' "$result"
}

check_releases_count() {
    local json="$1" count
    { [ -z "$json" ] || [ "$json" = "[]" ]; } && return 1
    count=$(printf '%s' "$json" | grep -o '"tag"' | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$count"
}

extract_url_from_releases() {
    local esc
    esc=$(printf '%s' "$2" | sed 's/\./\\./g')
    grep -o "\"name\":\"${esc}\",\"url\":\"[^\"]*\"" "$1" \
        | grep -o '"url":"[^"]*"' | cut -d'"' -f4 | head -1
}

# Gately 提供标准 sha256sum 格式的 checksums.txt：<hash>  <filename>
fetch_checksums() {
    local tag="$1" url rc
    url="$(gh_url "$REPO_URL/releases/download")/${tag}/checksums.txt"
    rm -f "$CHECKSUMS_FILE"
    http_get "$url" "$CHECKSUMS_FILE" 30 && [ -s "$CHECKSUMS_FILE" ]
    rc=$?
    if [ $rc -eq 0 ]; then
        log "Got checksums.txt for $tag"
        return 0
    fi
    # 镜像取 checksums 失败时同样回退直连，否则校验会被静默跳过
    if mirror_off "$rc"; then
        url=$(direct_url "$url")
        rm -f "$CHECKSUMS_FILE"
        http_get "$url" "$CHECKSUMS_FILE" 30 && [ -s "$CHECKSUMS_FILE" ] \
            && { log "Got checksums.txt for $tag (direct)"; return 0; }
    fi
    rm -f "$CHECKSUMS_FILE"
    log "WARN: checksums.txt not available, verification will be skipped"
    return 0
}

verify_sha256() {
    local file="$1" checksums="$2" fname expected actual
    [ -s "$checksums" ] || return 0
    fname="${file##*/}"
    expected=$(awk -v f="$fname" '$2==f{print $1; exit}' "$checksums")
    if [ -z "$expected" ]; then
        log "WARN: no checksum entry for $fname, verification skipped"
        return 0
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    log "Expected sha256: $expected"
    log "Computed sha256: $actual"
    if [ "$expected" = "$actual" ]; then
        log "SHA256 verified OK"
        return 0
    fi
    log "SHA256 verification failed"
    return 1
}

do_download() {
    local releases_file="$1" tag="$2" filename="$3"
    local progress
    local url
    url=$(extract_url_from_releases "$releases_file" "$filename")
    [ -z "$url" ] && die "url_not_found" "No download URL found for $filename"

    init_dir
    echo 0 > "$PROGRESS_FILE"
    write_status "downloading:$tag"
    log "Downloading: $filename"
    log "URL: $url"

    local f="$UPDATE_DIR/$filename"

    local total_size
    total_size=$(curl -sIL --connect-timeout 15 "$url" 2>/dev/null \
        | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r')

    if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null; then
        log "Total size: $(fmt_size "$total_size")"
        (
            while true; do
                sleep 1
                [ -f "$f" ] || continue
                downloaded=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
                [ "${downloaded:-0}" -gt 0 ] 2>/dev/null || continue
                pct=$(awk "BEGIN{printf \"%d\", $downloaded*100/$total_size}")
                echo "$pct" > "$PROGRESS_FILE"
                [ "$pct" -ge 100 ] && break
            done
        ) &
        local progress_pid=$!

        http_get "$url" "$f" 300
        local ret=$?
        kill "$progress_pid" 2>/dev/null
        wait "$progress_pid" 2>/dev/null
    else
        log "Total size: unknown"
        http_get "$url" "$f" 300
        local ret=$?
    fi
    # 镜像下载失败 → 剥掉镜像前缀，用直连重试一次
    if [ $ret -ne 0 ] && mirror_off "$ret"; then
        url=$(direct_url "$url")
        log "Retry URL: $url"
        echo 0 > "$PROGRESS_FILE"
        http_get "$url" "$f" 300
        ret=$?
    fi
    echo 100 > "$PROGRESS_FILE"

    [ $ret -ne 0 ] && die "download_failed" "Download failed: $url"
    [ -s "$f" ]    || die "download_empty" "Downloaded file is empty"
    log "Download complete: $(fmt_size "$(wc -c < "$f" | tr -d ' ')")"

    fetch_checksums "$tag"
    verify_sha256 "$f" "$CHECKSUMS_FILE" \
        || die "checksum_failed" "SHA256 verification failed, file may be corrupted"
    echo "$f"
}

cmd_check() {
    local reltype="${1:-$(uci_get release_type stable)}"
    local arch="${2:-$(detect_arch)}"
    [ "$arch" = "auto" ] && arch=$(detect_arch)

    init_dir
    acquire_lock || die "busy" "Another update task is already running"
    write_status "checking"
    log "Checking upstream versions (channel=$reltype arch=$arch)"
    if [ -n "$GH_MIRROR" ]; then
        log "Mirror enabled: $GH_MIRROR"
    else
        log "Mirror: none (direct to github.com)"
    fi

    # 只拉取一次 info/refs，直接排序落盘。
    # fetch_tags 失败时自身会把 curl rc/原因写进日志（rc=6 DNS、7 连接、28 超时）。
    local tags_file="$RUN_DIR/tags.sorted"
    # 不能用命令替换调用 fetch_tags：命令替换在子 shell 中执行，
    # 里面的镜像回退（USE_MIRROR=0）传不回当前 shell，后面构造出的下载地址
    # 还会带镜像前缀。这里重定向到文件，保证 fetch_tags 在当前 shell 运行。
    if fetch_tags > "$RUN_DIR/tags.raw"; then
        sort_tags_desc < "$RUN_DIR/tags.raw" > "$tags_file"
    fi

    if [ ! -s "$tags_file" ] || ! grep -aq . "$tags_file"; then
        die "check_failed" "Cannot reach github.com to fetch versions. Check WAN/DNS, or configure a proxy. Details in the log."
    fi

    local releases_json
    releases_json=$(build_releases_from_tags "$tags_file" "$arch" "$reltype")

    local count; count=$(check_releases_count "$releases_json") \
        || die "no_releases" "No gately versions found"
    printf '%s\n' "$releases_json" > "$RELEASES_FILE"
    rm -f "$tags_file"
    log "Found $count versions"
    write_status "ready:$count"
}

backup_config() {
    local configdir
    configdir=$(uci_get configdir "")
    { [ -z "$configdir" ] || [ ! -d "$configdir" ]; } && return 0
    local ver; ver=$(uci_get installed_version "")
    [ -z "$ver" ] && ver="unknown"
    local backup_file="$UPDATE_DIR/gately_${ver}_$(date +%Y%m%d%H%M%S).tar.gz"
    tar -czf "$backup_file" -C "$(dirname "$configdir")" "$(basename "$configdir")" 2>/dev/null
    log "Config backed up: $backup_file"
}

cmd_download() {
    local tag="$1" filename="$2" binpath="${3:-$(uci_get binpath /usr/bin/gately)}"
    [ -z "$tag" ]      && die "invalid_request" "download: missing tag"
    [ -z "$filename" ] && die "invalid_request" "download: missing filename"
    acquire_lock || die "busy" "Another update task is already running"

    local dl
    dl=$(do_download "$RELEASES_FILE" "$tag" "$filename") || exit 1
    write_status "installing:$tag"

    local xdir="$UPDATE_DIR/extract"
    rm -rf "$xdir" && mkdir -p "$xdir"
    log "Extracting..."
    case "$filename" in
        *.tar.gz|*.tgz) tar -xzf "$dl" -C "$xdir" 2>/dev/null \
                             || die "extract_failed" "Extract failed: $filename" ;;
        *) die "unsupported_format" "Unsupported format: $filename" ;;
    esac

    local bin; bin=$(find "$xdir" -type f -name "gately" | head -1)
    [ -z "$bin" ] && die "binary_not_found" "Binary 'gately' not found in archive"
    log "Found binary: $bin"

    mkdir -p "$(dirname "$binpath")"
    backup_config
    log "Stopping service..."
    /etc/init.d/gately-plus stop 2>/dev/null; sleep 1

    log "Installing to: $binpath"
    cp "$bin" "$binpath" && chmod 755 "$binpath" \
        || die "install_failed" "Failed to install to $binpath"
    rm -rf "$xdir" "$dl"

    log "Starting service..."
    /etc/init.d/gately-plus start 2>/dev/null
    local ver actual
    ver=$(tag_to_ver "$tag")
    actual=$(probe_binary_version "$binpath")
    save_installed_version "${actual:-$ver}" "$binpath"
    log "Installation complete: ${actual:-$ver} (tag $tag)"
    write_status "done:${actual:-$ver}"
}

# 返回 0 = 需要下载安装；1 = 无需动作。
# 只有「当前版本确实落后」才下载，相同或更新都不动现有二进制。
maybe_update() {
    local cur="$1" latest="$2" label="$3"
    if [ -z "$latest" ]; then
        log "$label: upstream version unknown, skip"
        return 1
    fi
    if [ -z "$cur" ]; then
        log "$label: current version unknown, install $latest"
        return 0
    fi
    if version_lt "$cur" "$latest"; then
        log "$label: $cur < $latest, update required"
        return 0
    fi
    if [ "$cur" = "$latest" ]; then
        log "$label is up to date ($cur)"
    else
        log "$label: installed $cur is newer than upstream $latest, keep it"
    fi
    return 1
}

# 长间隔（> 28 天）无法用 cron 的「日/步长」精确表达（*/29 只会在 1 号、30 号跑，
# 且每逢月初重新计数）。这类间隔改用「每天触发 + 距上次成功满 N 天」的判定。
auto_due() {
    local iv last now wait
    iv=$(uci_get update_interval 7)
    case "$iv" in ''|*[!0-9]*) iv=7 ;; esac
    [ "$iv" -le 28 ] && return 0
    last=$(uci -q get gately_plus.gately.last_auto_run 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now=$(date +%s)
    wait=$((iv * 86400))
    if [ $((now - last)) -lt "$wait" ]; then
        log "Skip: interval ${iv}d not reached (next in $(( (wait - (now - last)) / 3600 ))h)"
        return 1
    fi
    return 0
}

cmd_auto() {
    local reltype arch binpath trigger="${1:-cron}"
    reltype=$(uci_get release_type stable)
    arch=$(detect_arch)
    binpath=$(uci_get binpath /usr/bin/gately)

    init_dir

    if ! acquire_lock; then
        write_status "error:busy"
        log "ERROR: another update task is already running"
        exit 1
    fi

    if [ "$trigger" != "manual" ] && ! auto_due; then
        local skip_ver
        skip_ver=$(probe_binary_version "$binpath")
        [ -z "$skip_ver" ] && skip_ver=$(get_installed_version)
        write_status "done:skipped:${skip_ver:-unknown}"
        return 0
    fi

    rm -f "$PROGRESS_FILE"
    write_status "checking"
    log "Auto update: trigger=$trigger channel=$reltype arch=$arch"
    log "Effective settings: mirror=${GH_MIRROR:-none} binpath=$binpath arch=$arch"

    local cur_ver="" cur_src=""
    if [ -x "$binpath" ]; then
        # 优先问二进制自己；问不出来再回退 uci 记录
        cur_ver=$(probe_binary_version "$binpath") && cur_src="binary"
        if [ -z "$cur_ver" ]; then
            cur_ver=$(get_installed_version)
            if [ -n "$cur_ver" ]; then
                cur_src="recorded"
                log "WARN: cannot read version from $binpath, fall back to recorded $cur_ver"
            fi
        fi
        log "Current gately: ${cur_ver:-unknown} (source=${cur_src:-none})"
    else
        log "Gately binary not found, will download and install it"
    fi

    cmd_check "$reltype" "$arch"
    [ -f "$RELEASES_FILE" ] || die "check_failed" "Failed to check upstream versions"

    local latest_tag best_file
    latest_tag=$(grep -o '"tag":"[^"]*"' "$RELEASES_FILE" | head -1 | cut -d'"' -f4)
    best_file=$(grep -o '"best":"[^"]*"' "$RELEASES_FILE" | head -1 | cut -d'"' -f4)
    [ -z "$latest_tag" ] && die "check_failed" "Cannot parse latest tag"
    [ -z "$best_file" ]  && die "check_failed" "Cannot parse best file"

    log "Latest: $latest_tag (current: ${cur_ver:-none})"

    local state="uptodate" show_ver="$cur_ver"
    if maybe_update "$cur_ver" "$(tag_to_ver "$latest_tag")" "Gately"; then
        cmd_download "$latest_tag" "$best_file" "$binpath"
        state="updated"
        # 以装好之后的二进制实际版本为准：tag 与内部 version 不一定逐字相同
        show_ver=$(probe_binary_version "$binpath")
        [ -z "$show_ver" ] && show_ver=$(tag_to_ver "$latest_tag")
    fi

    [ -z "$show_ver" ] && show_ver="unknown"
    uci -q set gately_plus.gately.last_auto_run="$(date +%s)" 2>/dev/null
    uci -q commit gately_plus 2>/dev/null

    write_status "done:${state}:${show_ver}"
    log "Auto update complete ($state) version=$show_ver"
}

# 关键命令缺失时明确报错退出，不要静默用默认值继续跑
for _c in uci curl; do
    command -v "$_c" >/dev/null 2>&1 || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: command not found: $_c (PATH=$PATH)" >&2
        exit 1
    }
done

case "$1" in
    check)       init_dir; LOG_TO_FILE="$LOG_FILE"; : > "$LOG_FILE"; cmd_check "$2" "$3" ;;
    download)    init_dir; LOG_TO_FILE="$LOG_FILE"; : > "$LOG_FILE"; cmd_download "$2" "$3" "$4" ;;
    auto|"")
        # 自动更新用独立的 status/log，避免和「检查更新」面板互相覆盖
        init_dir
        LOG_TO_FILE="$AUTO_LOG"
        STATUS_TARGET="$AUTO_STATUS_FILE"
        auto_log_open "${2:-cron}"
        cmd_auto "${2:-cron}"
        ;;
    detect_arch) detect_arch ;;
    *)
        echo "Usage: $0 {check|download|auto [manual]|detect_arch}"
        exit 1 ;;
esac
