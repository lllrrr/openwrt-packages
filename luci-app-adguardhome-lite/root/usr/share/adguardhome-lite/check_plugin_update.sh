#!/bin/sh
# AdGuard Home 管理中心 - 检查插件是否有新版本
# 由控制器在缓存过期时后台调用，结果写入 /var/run/adguardhome_lite_plugin_update
# 说明：插件 Release 都是正式版，没有正式版 / 预发布版之分；
#       用 releases.atom 取最新标签，且不受 api.github.com 限流影响，可走反代

CACHE="/var/run/adguardhome_lite_plugin_update"
LOCK="/var/run/adguardhome_lite_plugin_update.lock"
REPO="Ozero-top/luci-app-adguardhome-lite"
FEED="https://github.com/$REPO/releases.atom"
# 当前安装的插件版本，由控制器传入；用于合并中间版本的更新说明
CURRENT="${1:-}"
CURRENT=${CURRENT#v}

# 跟随面板里的 GitHub 反代设置；选择「关闭」或未配置时只走直连
proxy="$(uci -q get adguardhome_lite.main.github_proxy 2>/dev/null)"
case "$proxy" in
    gh-proxy.org|ghproxy.cc|ghproxy.com|ghfast.top) ;;
    *) proxy="" ;;
esac
PROXY_PREFIX=""
[ -n "$proxy" ] && PROXY_PREFIX="https://$proxy/"

# 避免多个页面同时刷新时重复请求 GitHub
if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# 从同一份 atom 里取指定版本的更新说明，转成纯文本供升级弹窗展示
extract_notes() {
    _tag="$1"
    _html=$(printf '%s' "$_out" | tr '\n' ' ' | sed 's#<entry>#\n<entry>#g' \
        | grep -F "releases/tag/v$_tag" | head -n 1 \
        | sed -n 's#.*<content type="html">\(.*\)</content>.*#\1#p')
    [ -n "$_html" ] || return 0
    printf '%s' "$_html" | sed \
        -e 's#&lt;#<#g' \
        -e 's#&gt;#\>#g' \
        -e 's#&quot;#"#g' \
        -e "s/&#39;/'/g" \
        -e "s/&#x27;/'/g" \
        -e 's|&#x2F;|/|g' \
        -e 's|&#47;|/|g' \
        -e 's#&nbsp;# #g' \
        -e 's#&amp;#\&#g' \
        -e 's#<br[^>]*>#\n#g' \
        -e 's#</p>#\n#g' \
        -e 's#</li>#\n#g' \
        -e 's#</div>#\n#g' \
        -e 's#</h[1-6]>#\n#g' \
        -e 's#<li>#• #g' \
        -e 's#<[^>]*>##g' \
        | sed -e 's/[[:space:]]*$//' -e '/^$/d' | head -n 40
}

# 合并「当前版本之后」所有版本的说明，跨版本升级时也能看到每一步改了什么。
# 按 atom 的新到旧顺序取条目，写入临时文件后反序拼接（旧版本在前）；
# 上限 12KB，足以覆盖 atom 里的 10 个版本，避免落后很多时丢掉最早的几条。
collect_notes() {
    _cur="$1"
    _top="$2"

    _tags=$(printf '%s' "$_out" | grep -o 'releases/tag/[^"]*' \
        | sed 's#.*tag/##' | sed 's#^[vV]##' | awk '!seen[$0]++')
    [ -n "$_tags" ] || return 0

    _want=""
    if [ -n "$_cur" ] && printf '%s\n' "$_tags" | grep -Fqx "$_cur"; then
        # 只取比当前版本新的条目（atom 新到旧，遇到当前版本即停止）
        _want=$(printf '%s\n' "$_tags" | awk -v cur="$_cur" '$0 == cur { exit } { print }')
    elif [ -n "$_cur" ]; then
        # 当前版本比 atom 里最老的还旧（或不在最近 10 条内），atom 里的都算新版本
        _want="$_tags"
    else
        # 没有传入当前版本时只看最新版
        _want="$_top"
    fi
    if [ -n "$_want" ] && ! printf '%s\n' "$_want" | grep -Fqx "$_top"; then
        _want="$_top
$_want"
    fi

    _dir="/tmp/agh_plugin_notes.$$"
    mkdir -p "$_dir" 2>/dev/null || { printf '%s\n' "$_top"; return 0; }

    _i=0
    _total=0
    for _tag in $_want; do
        _body=$(extract_notes "$_tag")
        [ -n "$_body" ] || continue
        _i=$((_i + 1))
        {
            printf '【v%s】\n' "$_tag"
            printf '%s\n\n' "$_body"
        } > "$_dir/$_i"
        _total=$((_total + $(wc -c < "$_dir/$_i" 2>/dev/null || echo 0)))
        [ "$_total" -ge 12000 ] && break
    done

    if [ "$_i" -gt 0 ]; then
        for _f in $(ls "$_dir" 2>/dev/null | sort -nr); do
            cat "$_dir/$_f"
        done
    fi
    rm -rf "$_dir"
}

latest=""
for prefix in $PROXY_PREFIX ""; do
    # 单个节点最多 6 秒，避免多个节点串行把前端的检测等待拖到超时
    _out=$(curl -fsS --connect-timeout 3 -m 6 "$prefix$FEED" 2>/dev/null) || continue
    tags=$(printf '%s' "$_out" | grep -o 'releases/tag/[^"]*' | sed 's#.*tag/##' | sed 's#^[vV]##')
    [ -n "$tags" ] || continue
    # GitHub 会把 1.3.7-2 当成 1.3.7 的预发布排在其后，这里自行取最高版本
    latest=$(printf '%s\n' "$tags" | sort -V 2>/dev/null | tail -n 1)
    [ -n "$latest" ] || latest=$(printf '%s\n' "$tags" | head -n 1)
    [ -n "$latest" ] && break
done

# 网络不可达：保留上次结果并记录 failed，控制器会等 10 分钟再重试
if [ -z "$latest" ]; then
    _old=$(cat "$CACHE" 2>/dev/null)
    _prev_latest=$(printf '%s\n' "$_old" | sed -n 's/^latest=//p' | head -n 1)
    _prev_notes=$(printf '%s\n' "$_old" | sed -n '/^notes<<EOF$/,/^EOF$/p')
    {
        [ -n "$_prev_latest" ] && printf 'latest=%s\n' "$_prev_latest"
        printf 'time=%s\n' "$(date +%s)"
        [ -n "$_prev_notes" ] && printf '%s\n' "$_prev_notes"
        printf 'failed=1\n'
    } > "$CACHE"
    exit 0
fi

latest=${latest#v}

{
    printf 'latest=%s\n' "$latest"
    printf 'time=%s\n' "$(date +%s)"
    notes=$(collect_notes "$CURRENT" "$latest" | sed '/^EOF$/d')
    if [ -n "$notes" ]; then
        printf 'notes<<EOF\n%s\nEOF\n' "$notes"
    else
        printf 'nonotes=1\n'
    fi
} > "$CACHE"
