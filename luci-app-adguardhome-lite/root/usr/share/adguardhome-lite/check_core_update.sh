#!/bin/sh
# AdGuard Home 管理中心 - 检查内核是否有新版本（含预发布）
# 由控制器在缓存过期时后台调用，结果写入 /var/run/adguardhome_lite_core_update
#
# 通道判定以 GitHub Releases API 的 prerelease 字段为准：正式版通道只取
# prerelease=false 的最新条目，预发布通道取 prerelease=true 的最新条目。
# 版本号里的 -b 只作为 Atom 兜底时的近似判断（官方可能调整命名）。
# API 不可用时回退 releases.atom（仅最近 10 条）。

CACHE="/var/run/adguardhome_lite_core_update"
LOCK="/var/run/adguardhome_lite_core_update.lock"
REPO="AdguardTeam/AdGuardHome"
API="https://api.github.com/repos/$REPO/releases?per_page=30"
FEED="https://github.com/$REPO/releases.atom"

# 跟随面板里的 GitHub 反代设置；选择「关闭」或未配置时只走直连
proxy="$(uci -q get adguardhome_lite.main.github_proxy 2>/dev/null)"
case "$proxy" in
    gh-proxy.org|ghproxy.cc|ghproxy.com|ghfast.top) ;;
    *) proxy="" ;;
esac
PROXY_PREFIX=""
[ -n "$proxy" ] && PROXY_PREFIX="https://$proxy/"

# 避免多个页面同时刷新时重复请求 GitHub，触发限流
# 异常退出可能残留锁目录，超过 10 分钟视为失效
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
fi
if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

fetch() {
    curl -fsS --connect-timeout 6 -m 20 "$1" 2>/dev/null
}

# 从 API 返回的 JSON 中提取「标签 + prerelease 标记」，跳过 draft
parse_api() {
    awk '
    {
        line = $0
        if (line ~ /"tag_name"[[:space:]]*:/) {
            sub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            tag = line
        } else if (line ~ /"draft"[[:space:]]*:/) {
            draft = (line ~ /true/) ? 1 : 0
        } else if (line ~ /"prerelease"[[:space:]]*:/) {
            pre = (line ~ /true/) ? 1 : 0
            if (tag != "") {
                if (draft != 1) print tag " " pre
                tag = ""
                draft = 0
            }
        }
    }'
}

stable=""
beta=""
stable_tags=""
beta_tags=""

# 所有标签都保留下来，由控制器按语义版本取最大值，
# 避免依赖 GitHub 返回顺序（旧 beta 的基版本可能比新正式版更低，也可能被重新编辑排序）。
to_tags() {
    tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

data=""
for prefix in $PROXY_PREFIX ""; do
    data=$(fetch "$prefix$API")
    [ -n "$data" ] && break
done

if [ -n "$data" ]; then
    list=$(printf '%s\n' "$data" | parse_api)
    if [ -n "$list" ]; then
        stable_tags=$(printf '%s\n' "$list" | awk '$2 == 0 { print $1 }' | to_tags)
        beta_tags=$(printf '%s\n' "$list" | awk '$2 == 1 { print $1 }' | to_tags)
        stable=$(printf '%s\n' "$stable_tags" | awk '{ print $1 }')
        beta=$(printf '%s\n' "$beta_tags" | awk '{ print $1 }')
    fi
fi

# API 被限流或不可用时回退 Atom
if [ -z "$stable" ] && [ -z "$beta" ]; then
    tags=""
    for prefix in $PROXY_PREFIX ""; do
        _out=$(fetch "$prefix$FEED")
        [ -n "$_out" ] || continue
        # 只取合法标签字符，避免把正文里被转义的 changelog 链接（&quot;...）当成版本号
        tags=$(printf '%s' "$_out" | grep -o 'releases/tag/[A-Za-z0-9._-]*' | sed 's#.*tag/##')
        [ -n "$tags" ] && break
    done
    if [ -n "$tags" ]; then
        stable_tags=$(printf '%s\n' "$tags" | grep -vE -- '-b\.?[0-9]' | to_tags)
        beta_tags=$(printf '%s\n' "$tags" | grep -E -- '-b\.?[0-9]' | to_tags)
        stable=$(printf '%s\n' "$stable_tags" | awk '{ print $1 }')
        beta=$(printf '%s\n' "$beta_tags" | awk '{ print $1 }')
    fi
fi

# 全部失败时不写缓存，控制器会在一小时后重试
[ -n "$stable" ] || [ -n "$beta" ] || exit 0

stable=${stable#v}
beta=${beta#v}

{
    printf 'stable=%s\n' "$stable"
    printf 'beta=%s\n' "$beta"
    printf 'stable_tags=%s\n' "$stable_tags"
    printf 'beta_tags=%s\n' "$beta_tags"
    printf 'time=%s\n' "$(date +%s)"
} > "$CACHE"
