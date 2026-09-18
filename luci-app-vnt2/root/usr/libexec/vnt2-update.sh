#!/bin/sh
# VNT2 更新脚本 v1.9

CACHE_DIR="/tmp/vnt2_update"
mkdir -p "$CACHE_DIR"

PM="" EXT=""
command -v apk  >/dev/null 2>&1 && { PM=apk  EXT=apk; }
command -v opkg >/dev/null 2>&1 && { PM=opkg EXT=ipk; }

cache_full()    { echo "$CACHE_DIR/$1.full.json"; }
cache_slim()    { echo "$CACHE_DIR/$1.slim.json"; }
status_file()   { echo "$CACHE_DIR/$1.status";    }
log_file()      { echo "$CACHE_DIR/$1.log";       }
event_file()    { echo "$CACHE_DIR/$1.events";    }
tmp_file()      { echo "$CACHE_DIR/$2";           }

MIN_FREE_KB=20480

check_free_space() {
    local mnt avail
    for mnt in /tmp /; do
        avail="$(df -k "$mnt" 2>/dev/null | awk 'NR==2{print $4}')"
        [ -z "$avail" ] && continue
        if [ "$avail" -lt "$MIN_FREE_KB" ]; then
            echo "Not enough free space on $mnt: ${avail} KB available, at least ${MIN_FREE_KB} KB required" >&2
            return 1
        fi
    done
    return 0
}

wait_for_network() {
    local i=0
    while [ $i -lt 30 ]; do
        ip route show default 2>/dev/null | grep -q . && return 0
        sleep 1
        i=$((i+1))
    done
    return 1
}

log() {
    local f="$(log_file "$1")"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$f"
}

event() {
    local f="$(event_file "$1")"; shift
    printf '[%s] EVENT %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$f"
}

set_status() {
    local f="$(status_file "$1")"
    echo "$2" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

format_size() {
    local b="$1"
    [ "$b" -gt 1048576 ] && awk "BEGIN{printf \"%.1f MB\",$b/1048576}" && return
    [ "$b" -gt 1024 ]    && awk "BEGIN{printf \"%.1f KB\",$b/1024}"    && return
    echo "$b B"
}

pm_install() {
    local pkg="$1" rc=0
    shift
    local out="${PM_LOG_FILE:-/dev/null}"

    if [ -z "$PM" ]; then
        echo "No package manager (apk/opkg) found, cannot install $pkg"
        return 1
    fi

    if echo "$pkg" | grep -q '/'; then
        case "$PM" in
            apk)  apk add --allow-untrusted "$pkg" >>"$out" 2>&1 || rc=$? ;;
            opkg) opkg install "$pkg" >>"$out" 2>&1 || rc=$? ;;
        esac

    elif ! command -v "$pkg" >/dev/null 2>&1; then
        echo "Installing dependency: $pkg"
        $PM update >/dev/null 2>&1
        case "$PM" in
            apk)  apk add "$pkg" >>"$out" 2>&1 || rc=$? ;;
            opkg) opkg install "$pkg" >>"$out" 2>&1 || rc=$? ;;
        esac
        if [ $rc -ne 0 ] || ! command -v "$pkg" >/dev/null 2>&1; then
            echo "Failed to install dependency: $pkg"
            return 1
        fi
        echo "Dependency installed: $pkg"
    fi

    [ $rc -eq 0 ] && [ $# -gt 0 ] && "$pkg" "$@"
    return $rc
}

manage_service() {
    local action="$1" name="$2"
    [ -z "$action" ] || [ -z "$name" ] && return
    [ "$name" = "luci-app-vnt2" ] && return
    case "$action" in
        stop)
            if pgrep -f vnt2-run.sh >/dev/null 2>&1; then
                log "$name" "Stopping service before installation"
                /etc/init.d/vnt2 stop >/dev/null 2>&1
            fi
            ;;
        restart|start)
            log "$name" "Restarting service to apply the new binaries"
            setsid /etc/init.d/vnt2 "$action" >/dev/null 2>&1 &
            ;;
        *)
            log "$name" "Running service action $action"
            /etc/init.d/vnt2 "$action" >/dev/null 2>&1
            ;;
    esac
}

api_url() {
    local mirror="$1" proj="$2" owner="vnt-dev"
    [ "$proj" = "luci-app-vnt2" ] && owner="whzhni1"
    case "$mirror" in
        github)     echo "https://api.github.com/repos/${owner}/${proj}/releases"               ;;
        gitee)      echo "https://gitee.com/api/v5/repos/whzhni/${proj}/releases"               ;;
        gitlab)     echo "https://gitlab.com/api/v4/projects/whzhni%2F${proj}/releases"         ;;
        cloudflare) echo "https://pub-8a57d35d70d5423aac22a3316867e7ce.r2.dev/${proj}/releases" ;;
        *)          echo "https://api.github.com/repos/${owner}/${proj}/releases"               ;;
    esac
}

file_type() {
    local magic=""
    command -v hexdump >/dev/null 2>&1 && \
        magic="$(dd if="$1" bs=4 count=1 2>/dev/null | hexdump -e '1/1 "%02x"')"

    if [ -n "$magic" ]; then
        case "$magic" in
            7f454c46*) echo "elf"     ;;
            1f8b*)     echo "gz"      ;;
            504b0304*) echo "zip"     ;;
            *)         echo "unknown" ;;
        esac
        return
    fi

    case "$1" in
        *.tar.gz|*.tgz) echo "gz"  ;;
        *.zip)           echo "zip" ;;
        *)               echo "elf" ;;
    esac
}

detect_arch() {
    local machine; machine="$(uname -m)"
    case "$machine" in
        x86_64)        echo "x86_64"  ;;
        i[3-6]86)      echo "i686"    ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7*)
            grep -q "vfp" /proc/cpuinfo 2>/dev/null \
                && echo "armv7 musleabihf" || echo "armv7 musleabi"
            ;;
        armv6*|armv5*)
            grep -q "vfp" /proc/cpuinfo 2>/dev/null \
                && echo "arm musleabihf" || echo "arm musleabi"
            ;;
        mips*)
            [ "$(dd if=/proc/self/exe bs=1 skip=5 count=1 2>/dev/null \
                 | od -An -tu1 | tr -d ' ')" = "1" ] \
                && echo "mipsel" || echo "mips"
            ;;
        *) echo "$machine" ;;
    esac
}

load_uci() {
    MIRROR="$(uci get vnt2.global.mirror          2>/dev/null || echo github)"
    _arch="$(uci get vnt2.global.arch 2>/dev/null)"
    [ -z "$_arch" ] || [ "$_arch" = "auto" ] && _arch="$(detect_arch)"
    ARCH1="$(echo "$_arch" | cut -d' ' -f1)"
    ARCH2="$(echo "$_arch" | cut -d' ' -f2)"
    [ "$ARCH2" = "$ARCH1" ] && ARCH2=""
    if [ -n "$ARCH1" ] && [ -z "$ARCH2" ]; then
        _detected="$(detect_arch)"
        _det1="$(echo "$_detected" | cut -d' ' -f1)"
        _det2="$(echo "$_detected" | cut -d' ' -f2)"
        [ "$_det1" = "$ARCH1" ] && [ "$_det2" != "$_det1" ] && ARCH2="$_det2"
    fi
    BIN_PATH="$(uci get vnt2.global.bin_path      2>/dev/null || echo /usr/bin)"
    UPX="$(uci get vnt2.global.upx_compressed     2>/dev/null || echo 0)"
    AUTO_UPDATE="$(uci get vnt2.global.auto_update 2>/dev/null || echo 0)"
}

cmd_check() {
    local proj="$1" mirror="${2:-github}"
    local url raw file_ext lines
    local slim_json first_release current_tag assets_slim first_asset fname count line

    rm -f "$(log_file "$proj")" "$(event_file "$proj")" "$(status_file "$proj")" \
          "$(cache_full "$proj")" "$(cache_slim "$proj")"

    set_status "$proj" "checking"
    event "$proj" "checking_version project=$proj mirror=$mirror"
    log "$proj" "Checking for updates (mirror: $mirror)"

    url="$(api_url "$mirror" "$proj")"
    raw="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 3 "$url" 2>&1 | sed 's/": /":/g')"

    if [ -z "$raw" ] || ! echo "$raw" | grep -q '"tag_name"'; then
        event "$proj" "api_request_failed project=$proj mirror=$mirror"
        log "$proj" "Cannot reach the release API, please try another mirror"
        set_status "$proj" "error:Release API unreachable, please switch mirror"
        return 1
    fi

    file_ext=""
    [ "$proj" = "luci-app-vnt2" ] && file_ext="$EXT"

    if [ -n "$file_ext" ]; then
        lines="$(echo "$raw" | grep -o '"tag_name":"[^"]*"\|https://[^"]*\.'"$file_ext"'[^"]*')"
    else
        lines="$(echo "$raw" | grep -o '"tag_name":"[^"]*"\|https://[^"]*linux[^"]*')"
    fi

    slim_json='{"releases":['
    first_release=1 current_tag="" assets_slim="" first_asset=1

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            '"tag_name":"'*)
                if [ -n "$current_tag" ] && [ -n "$assets_slim" ]; then
                    [ "$first_release" -eq 1 ] && first_release=0 || slim_json="${slim_json},"
                    slim_json="${slim_json}{\"tag\":\"$current_tag\",\"filenames\":[$assets_slim]}"
                fi
                current_tag="$(echo "$line" | cut -d'"' -f4)"
                assets_slim="" first_asset=1
                ;;
            https://*)
                fname="${line##*/}"
                [ -z "$fname" ] && continue
                case "$fname" in *sha256*) continue ;; esac
                case "$assets_slim" in *"\"$fname\""*) continue ;; esac
                [ "$first_asset" -eq 1 ] && first_asset=0 || assets_slim="${assets_slim},"
                assets_slim="${assets_slim}\"$fname\""
                ;;
        esac
    done <<EOF
$lines
EOF

    if [ -n "$current_tag" ] && [ -n "$assets_slim" ]; then
        [ "$first_release" -eq 1 ] || slim_json="${slim_json},"
        slim_json="${slim_json}{\"tag\":\"$current_tag\",\"filenames\":[$assets_slim]}"
    fi

    slim_json="${slim_json}]}"
    echo "$raw"       > "$(cache_full "$proj")"
    echo "$slim_json" > "$(cache_slim "$proj")"

    count="$(echo "$slim_json" | grep -o '"tag":' | wc -l | tr -d ' ')"
    log "$proj" "Found $count releases"

    if [ "$count" -eq 0 ]; then
        event "$proj" "no_matching_file project=$proj"
        set_status "$proj" "error:No matching file found, please switch mirror"
        return 1
    fi

    event "$proj" "version_list_ready count=$count"
    set_status "$proj" "ready:$count"
}

verify_download() {
    local proj="$1" tmp="$2"
    local actual cache short
    cache="$(cache_full "$proj")"

    if ! grep -qi 'sha256' "$cache" 2>/dev/null; then
        log "$proj" "Upstream publishes no checksum for this release, verification skipped"
        return 0
    fi

    actual="$(sha256sum "$tmp" 2>/dev/null | cut -d' ' -f1)"
    [ -z "$actual" ] && { log "$proj" "sha256sum unavailable, verification skipped"; return 0; }

    if grep -q "$actual" "$cache" 2>/dev/null; then
        short="$(echo "$actual" | cut -c1-16)"
        event "$proj" "checksum_passed"
        log "$proj" "Checksum OK (sha256 $short...)"
        return 0
    else
        event "$proj" "checksum_failed"
        log "$proj" "Checksum mismatch, the download is corrupted (sha256 $actual)"
        set_status "$proj" "error:Checksum verification failed"
        rm -f "$tmp"
        return 1
    fi
}

cmd_download() {
    local proj="$1" tag="$2" fnames="$3" upx="${4:-}"
    [ -z "$upx" ] || [ "$upx" = "0" ] && \
        upx="$(uci get vnt2.global.upx_compressed 2>/dev/null || echo 0)"

    rm -f "$(log_file "$proj")"
    set_status "$proj" "downloading"
    event "$proj" "download_prepare tag=$tag"
    log "$proj" "Downloading $tag ($fnames)"

    [ ! -f "$(cache_full "$proj")" ] && {
        log "$proj" "Version cache missing, please check for updates first"
        set_status "$proj" "error:Please check upstream version first"
        return 1
    }

    local installed="" fname
    for fname in $fnames; do
        local is_lang=0
        case "$fname" in *i18n*) is_lang=1 ;; esac
        if [ $is_lang -eq 1 ]; then
            _download_and_install "$proj" "$fname" "0" \
                && installed="${installed:+${installed}, }${fname}" \
                || log "$proj" "Skipped language pack $fname"
        else
            _download_and_install "$proj" "$fname" "$upx" || return 1
            installed="${installed:+${installed}, }${fname}"
        fi
    done

    event "$proj" "installation_complete installed=${installed:-$fnames}"
    set_status "$proj" "done:${installed:-$fnames}"
}

_do_install() {
    local proj="$1" src="$2" dst="$3" upx="$4"
    chmod 755 "$src"
    if [ "$upx" = "1" ]; then
        log "$proj" "Compressing $(basename "$dst") with UPX"
        if pm_install upx --no-color -q -q --force "$src" -o "$dst" >> "$(log_file "$proj")" 2>&1; then
            log "$proj" "UPX compression done"
        else
            log "$proj" "UPX failed, installing uncompressed"
            cp "$src" "$dst" 2>>"$(log_file "$proj")" || {
                log "$proj" "Cannot write $dst, the file may be in use"
                return 1
            }
        fi
    else
        cp "$src" "$dst" 2>>"$(log_file "$proj")" || {
            log "$proj" "Cannot write $dst, the file may be in use"
            return 1
        }
    fi
    chmod 755 "$dst"
    log "$proj" "Installed $dst"
}

_download_and_install() {
    local proj="$1" fname="$2" upx="$3"
    local cache dl_url esc_fname f total_size progress_pid rc downloaded pct size
    local avail_kb need_kb i

    cache="$(cache_full "$proj")"
    esc_fname="$(printf '%s' "$fname" | sed 's/[][\.*^$/]/\\&/g')"
    dl_url="$(grep -o "https://[^\"']*/${esc_fname}" "$cache" | head -1)"
    [ -z "$dl_url" ] && { log "$proj" "Download URL not found for $fname"; return 1; }

    f="$CACHE_DIR/$fname"
    rm -f "$f"

    log "$proj" "Downloading $fname"
    set_status "$proj" "downloading"

    total_size="$(curl -sIL --connect-timeout 15 --retry 2 --retry-delay 3 "$dl_url" 2>/dev/null \
        | grep -i content-length | tail -1 | awk '{print $2}' | tr -d '\r')"

    if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null; then
        log "$proj" "File size: $(format_size "$total_size")"

        avail_kb="$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')"
        need_kb=$(( total_size / 512 ))
        if [ -n "$avail_kb" ] && [ "$need_kb" -gt "$avail_kb" ]; then
            log "$proj" "Not enough space in /tmp, need $(format_size $((need_kb * 1024))) but only $(format_size $((avail_kb * 1024))) available"
            set_status "$proj" "error:Not enough temporary space"
            return 1
        fi

        (
            i=0
            while [ $i -lt 330 ]; do
                sleep 1
                i=$((i+1))
                [ -f "$f" ] || continue
                downloaded=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
                [ -n "$downloaded" ] || continue
                pct=$(( downloaded * 100 / total_size ))
                [ $pct -gt 100 ] && pct=100
                set_status "$proj" "downloading:${pct}:${downloaded}:${total_size}"
                [ $pct -ge 100 ] && break
            done
        ) &
        progress_pid=$!

        curl -fsSL --connect-timeout 15 --max-time 300 \
            --retry 3 --retry-delay 5 \
            -o "$f" "$dl_url"
        rc=$?

        kill "$progress_pid" 2>/dev/null
        wait "$progress_pid" 2>/dev/null
        [ $rc -eq 0 ] && [ -s "$f" ] && \
            set_status "$proj" "downloading:100:$(wc -c < "$f" | tr -d ' '):$total_size"
    else
        log "$proj" "File size unknown, percentage progress unavailable"

        (
            i=0
            while [ $i -lt 330 ]; do
                sleep 1
                i=$((i+1))
                [ -f "$f" ] || continue
                downloaded=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
                [ -n "$downloaded" ] && [ "$downloaded" -gt 0 ] && \
                    set_status "$proj" "downloading:-1:${downloaded}:0"
            done
        ) &
        progress_pid=$!

        curl -fsSL --connect-timeout 15 --max-time 300 \
            --retry 3 --retry-delay 5 \
            -o "$f" "$dl_url"
        rc=$?

        kill "$progress_pid" 2>/dev/null
        wait "$progress_pid" 2>/dev/null
    fi

    if [ $rc -ne 0 ] || [ ! -s "$f" ]; then
        event "$proj" "download_failed file=$fname return_code=$rc"
        log "$proj" "Download failed (curl exit $rc): $fname"
        set_status "$proj" "error:Download failed"
        rm -f "$f"
        return 1
    fi

    size="$(wc -c < "$f" | tr -d ' ')"
    log "$proj" "Download complete: $fname ($(format_size "$size"))"
    event "$proj" "download_complete file=$fname"

    verify_download "$proj" "$f" || return 1

    event "$proj" "installation_started"
    set_status "$proj" "installing"
    if [ "$proj" = "luci-app-vnt2" ]; then
        PM_LOG_FILE="$(log_file "$proj")"
        pm_install "$f" \
            && log "$proj" "Package installed: $fname" \
            || { PM_LOG_FILE=""; log "$proj" "Package install failed: $fname"; rm -f "$f"; return 1; }
        PM_LOG_FILE=""
        rm -f "$f"
    else
        _install_bin "$proj" "$f" "$upx"
    fi
}

_install_bin() {
    local proj="$1" tmp="$2" upx="$3"
    local bin_path bins installed="" extract_dir="$CACHE_DIR/${proj}_extract"
    local ftype b src extract_ok
    bin_path="$(uci get vnt2.global.bin_path 2>/dev/null || echo /usr/bin)"
    [ "$proj" = "vnt" ] && bins="vnt2_cli vnt2_web vnt2_ctrl" || bins="vnts2"

    ftype="$(file_type "$tmp")"
    case "$ftype" in
        elf) log "$proj" "Package type: standalone binary" ;;
        gz)  log "$proj" "Package type: tar.gz archive" ;;
        zip) log "$proj" "Package type: zip archive" ;;
        *)   log "$proj" "Package type: unrecognized" ;;
    esac
    manage_service stop "$proj"
    case "$ftype" in
        elf)
            b="$(echo "$bins" | cut -d' ' -f1)"
            if _do_install "$proj" "$tmp" "${bin_path}/${b}" "$upx"; then
                installed="$b"
            fi
            ;;
        gz|zip)
            rm -rf "$extract_dir"; mkdir -p "$extract_dir"
            if [ "$ftype" = "gz" ]; then
                tar -xzf "$tmp" -C "$extract_dir" 2>>"$(log_file "$proj")"
                extract_ok=$?
            else
                pm_install unzip -o "$tmp" -d "$extract_dir" >>"$(log_file "$proj")" 2>&1
                extract_ok=$?
            fi
            if [ "$extract_ok" -ne 0 ]; then
                log "$proj" "Failed to extract the archive"
                set_status "$proj" "error:Failed to extract archive"
                rm -rf "$extract_dir"; rm -f "$tmp"
                return 1
            fi
            for b in $bins; do
                src="$(find "$extract_dir" -name "$b" -type f 2>/dev/null | head -1)"
                [ -z "$src" ] && { log "$proj" "$b not found in the archive, skipped"; continue; }
                [ "$(file_type "$src")" = "elf" ] || { log "$proj" "$b is not an ELF binary, skipped"; continue; }
                if _do_install "$proj" "$src" "${bin_path}/${b}" "$upx"; then
                    installed="${installed:+${installed}, }${b}"
                fi
            done
            rm -rf "$extract_dir"
            ;;
        *)
            rm -f "$tmp"
            log "$proj" "Unrecognized archive format"
            set_status "$proj" "error:Unrecognized archive format"
            return 1
            ;;
    esac

    rm -f "$tmp"
    if [ -n "$installed" ]; then
        log "$proj" "Installed binaries: $installed"
        manage_service restart "$proj"
        set_status "$proj" "done:$installed"
    else
        log "$proj" "The archive contains no installable binaries"
        set_status "$proj" "error:No installable binary found"
        return 1
    fi
}

pick_latest() {
    local proj="$1" arch1="$2" arch2="$3"
    LATEST_TAG="" LATEST_FILE=""

    local slim; slim="$(cache_slim "$proj")"
    [ ! -f "$slim" ] && return 1

    LATEST_TAG="$(grep -oE '"tag":"[^"]*"' "$slim" | head -1 | cut -d'"' -f4)"
    [ -z "$LATEST_TAG" ] && return 1

    local filenames
    filenames="$(grep -o '"filenames":\[[^]]*\]' "$slim" | head -1 \
                 | grep -oE '"[^"]+\.[^"]+"' | tr -d '"')"

    local pattern f
    if [ -n "$arch2" ]; then
        pattern="${arch1}.*${arch2}[^h]"
    else
        pattern="${arch1}[^e]"
    fi

    f="$(echo "$filenames" | grep -E "$pattern" | grep -v 'i18n' | head -1)"
    [ -n "$f" ] && { LATEST_FILE="$f"; return 0; }

    LATEST_FILE="$(echo "$filenames" | grep -v 'i18n' | head -1)"
    [ -n "$LATEST_FILE" ]
}

extract_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

installed_version() {
    local bin="$1"
    [ ! -x "$bin" ] && echo "" && return
    "$bin" --version 2>/dev/null | extract_version
}

auto_update_one() {
    local proj="$1"
    log "$proj" "=== Auto update: $proj ==="

    cmd_check "$proj" "$MIRROR" || return 1

    pick_latest "$proj" "$ARCH1" "$ARCH2" || {
        log "$proj" "No release file matching this architecture"
        return 1
    }

    local latest_ver cur_ver raw_ver
    latest_ver="$(echo "$LATEST_TAG" | extract_version)"

    case "$proj" in
        vnt)  cur_ver="$(installed_version "$BIN_PATH/vnt2_cli")" ;;
        vnts) cur_ver="$(installed_version "$BIN_PATH/vnts2")"    ;;
        luci-app-vnt2)
            case "$PM" in
                apk)  raw_ver="$(apk info luci-app-vnt2 2>/dev/null | head -1)" ;;
                opkg) raw_ver="$(opkg info luci-app-vnt2 2>/dev/null | grep '^Version:')" ;;
                *)    raw_ver="" ;;
            esac
            cur_ver="$(echo "$raw_ver" | extract_version)"
            ;;
    esac

    log "$proj" "Installed ${cur_ver:-none}, latest ${latest_ver:-unknown}"

    if [ -n "$cur_ver" ] && [ -n "$latest_ver" ] && [ "$(printf '%s\n' "$cur_ver" "$latest_ver" | sort -V | tail -1)" = "$cur_ver" ]; then
        log "$proj" "Already up to date ($cur_ver)"
        set_status "$proj" "done:Already up to date($cur_ver)"
        return 0
    fi

    log "$proj" "Updating to $LATEST_TAG ($LATEST_FILE)"

    local fnames="$LATEST_FILE"
    if [ "$proj" = "luci-app-vnt2" ]; then
        local lang lang_file
        lang=$(
            for f in /usr/lib/lua/luci/i18n/*.lmo; do
                [ -f "$f" ] || continue
                tmp="${f%.lmo}"
                echo "${tmp##*.}"
            done | sort | uniq -c | sort -nr | head -n1 | awk '{print $2}'
        )
        if [ -n "$lang" ]; then
            local slim; slim="$(cache_slim "$proj")"
            lang_file=$(grep -oE '"[^"]*i18n[^"]*'"$lang"'[^"]*"' "$slim" | tr -d '"' | head -1)
            [ -n "$lang_file" ] && fnames="$fnames $lang_file" && \
                log "$proj" "Including language pack $lang_file"
        fi
    fi

    cmd_download "$proj" "$LATEST_TAG" "$fnames" "$UPX"
}

cmd_auto_update() {
    load_uci
    wait_for_network || log "auto" "Network still unavailable after 30s, continuing anyway"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting auto update (mirror: $MIRROR, arch: ${ARCH1}${ARCH2:+ $ARCH2})"
    local projects="${*:-vnt vnts luci-app-vnt2}"
    for proj in $projects; do
        auto_update_one "$proj" || true
        log "auto" "$proj -> $(cat "$(status_file "$proj")" 2>/dev/null)"
    done

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done"
}

case "$1" in
    detect_arch) detect_arch; exit 0 ;;
esac

if ! check_free_space; then
    _proj="${2:-auto}"
    log "$_proj" "Aborted: not enough free space, at least 20 MB required"
    event "$_proj" "insufficient_space"
    set_status "$_proj" "error:Not enough storage space, at least 20 MB required"
    exit 1
fi

case "$1" in
    check)    cmd_check    "$2" "$3"           ;;
    download) cmd_download "$2" "$3" "$4" "$5" ;;
    *)        cmd_auto_update "$@"             ;;
esac
