#!/bin/sh
# 更新 CloudflareSpeedTest 的 ip.txt
# 源:   https://zip.cm.edu.kg/all.txt  (格式 IP:PORT#国家码)  可用第1个参数或 CF_SRC 覆盖
# 目标: /etc/CloudflareSpeedTest/ip.txt                  可用第2个参数或 CF_DST 覆盖
# 地区: 默认 JP,SG,KR(大陆反代优选,不含 HK)            可用第3个参数或 CF_REGIONS 覆盖;留空=全量 :443
# 放置: /etc/CloudflareSpeedTest/update_cf_ip.sh
# cron: 30 5 * * 2 /etc/CloudflareSpeedTest/update_cf_ip.sh >> /var/log/cf_ip_update.log 2>&1
set -eu

# 自定义源地址:第1个参数 > 环境变量 CF_SRC > 默认值
SRC="${1:-${CF_SRC:-https://zip.cm.edu.kg/all.txt}}"
DST="${2:-${CF_DST:-/etc/CloudflareSpeedTest/ip.txt}}"
REGIONS="${3-${CF_REGIONS-JP,SG,KR}}"     # 逗号分隔国家码;留空=不过滤(保留全部 :443)。注意用 `-` 而非 `:-`,使空值能关闭过滤
TIMEOUT=30
MIN_LINES="${CF_MIN_LINES:-50}"           # JP/SG/KR :443 去重后 ~358;50 为安全地板。全量模式可 CF_MIN_LINES=1000

TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# 下载,最多重试 3 次,规避偶发网络抖动
ok=0
for i in 1 2 3; do
    if curl -fsSL --max-time "$TIMEOUT" -o "$TMP" "$SRC" 2>/dev/null; then ok=1; break; fi
    [ "$i" = 3 ] || echo "[warn] 下载失败(第 $i 次),重试..." >&2
done
[ "$ok" = 1 ] || { echo "[err] 下载失败(重试 3 次): $SRC"; exit 1; }

if [ ! -s "$TMP" ]; then
    echo "[err] 下载内容为空"
    exit 1
fi

# 只保留源里标了 :443 的行;若指定了地区,再按国家码过滤;最后去端口去重,只留纯 IP
if [ -n "$REGIONS" ]; then
    re=$(printf '%s' "$REGIONS" | sed 's/[[:space:],]/|/g')
    { grep ':443#' "$TMP" | grep -E ":443#($re)$" | sed 's/:.*//' | sort -u || true; } > "${TMP}.new"
else
    { grep ':443#' "$TMP" | sed 's/:.*//' | sort -u || true; } > "${TMP}.new"
fi
mv -f "${TMP}.new" "$TMP"

lines=$(wc -l < "$TMP" | tr -d ' ')
if [ "$lines" -lt "$MIN_LINES" ]; then
    echo "[err] 行数过少 ($lines < $MIN_LINES),疑似源异常,中止"
    exit 1
fi

good=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$TMP" || true)
if [ "$good" -lt $((lines * 9 / 10)) ]; then
    echo "[err] 格式异常,合法行 $good/$lines 不足 90%,中止"
    exit 1
fi

mkdir -p "$(dirname "$DST")"
if [ -f "$DST" ]; then
    cp "$DST" "${DST}.bak"
fi
mv -f "$TMP" "$DST"
chmod 644 "$DST"
echo "[ok] $lines 行写入 $DST (备份 ${DST}.bak)"
