#!/bin/sh
# read_network_cache 必须给缓存补上 age（秒）：
# UI 靠它判断结果够不够新、要不要再自动检测一次。
#   - 带 updated_at_epoch 的新缓存 → age = 现在 - epoch
#   - 旧版本写的缓存（没有 epoch）→ age=999999，永远按过期处理（宁可重测，不显示陈旧结果）
#   - 没有缓存 → {"cached":0,...}
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELAY="$ROOT/package/luci-app-upnp-nat-relay/root/usr/bin/upnp-nat-relay"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

NETWORK_CACHE_FILE="$TMP/network_cache.json"
export NETWORK_CACHE_FILE

# macOS / CI 都没有 jsonfilter 时用 sed 兜底（只取 updated_at_epoch）。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
sed -n 's/.*"updated_at_epoch":\([0-9][0-9]*\).*/\1/p'
EOF
chmod +x "$TMP/bin/jsonfilter"
PATH="$TMP/bin:$PATH"
export PATH

awk '
	$0 == "read_network_cache() {" { copying = 1 }
	copying { print }
	copying && $0 == "}" { exit }
' "$RELAY" > "$TMP/functions.sh"

. "$TMP/functions.sh"

fail=0
expect_age() {
	_name="$1"; _want="$2"; _out="$3"
	_got="$(printf '%s' "$_out" | sed -n 's/.*"age":\([0-9][0-9]*\).*/\1/p')"
	if [ -z "$_got" ]; then
		echo "FAIL: $_name — 输出里没有 age 字段: $_out" >&2
		fail=1
		return
	fi
	# 时间在跑，允许 2 秒误差
	if [ "$_want" = "recent" ]; then
		[ "$_got" -ge 0 ] && [ "$_got" -le 2 ] && _ok=1 || _ok=0
	elif [ "$_want" = "stale" ]; then
		[ "$_got" -ge 40 ] && [ "$_got" -le 44 ] && _ok=1 || _ok=0
	else
		[ "$_got" = "$_want" ] && _ok=1 || _ok=0
	fi
	if [ "${_ok:-0}" -eq 1 ]; then
		echo "PASS: $_name (age=$_got)"
	else
		echo "FAIL: $_name 期望 age=$_want，实际 $_got" >&2
		fail=1
	fi
}

now="$(date +%s)"

# 1. 刚测过：age 接近 0
printf '%s' "{\"cached\":1,\"updated_at\":\"2026-11-23 14:20:00\",\"updated_at_epoch\":${now},\"bind_ifname\":\"br-lan\"}" > "$NETWORK_CACHE_FILE"
expect_age "刚写入的缓存" recent "$(read_network_cache)"

# 2. 42 秒前测过
printf '%s' "{\"cached\":1,\"updated_at\":\"2026-11-23 14:20:00\",\"updated_at_epoch\":$(( now - 42 )),\"bind_ifname\":\"br-lan\"}" > "$NETWORK_CACHE_FILE"
expect_age "42 秒前的缓存" stale "$(read_network_cache)"

# 3. 旧版本缓存（无 epoch）→ 按过期处理，UI 会重新检测
printf '%s' '{"cached":1,"updated_at":"2026-11-23 14:20:00","bind_ifname":"br-lan"}' > "$NETWORK_CACHE_FILE"
expect_age "无 epoch 的旧缓存" 999999 "$(read_network_cache)"

# 4. 没有缓存文件
rm -f "$NETWORK_CACHE_FILE"
_out="$(read_network_cache)"
case "$_out" in
	*'"cached":0'*) echo "PASS: 无缓存返回 cached:0" ;;
	*) echo "FAIL: 无缓存应返回 cached:0，实际: $_out" >&2; fail=1 ;;
esac

[ "$fail" -eq 0 ] || exit 1
echo "OK: network-cache age contract"
