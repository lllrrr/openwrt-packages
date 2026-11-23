#!/bin/sh
# 生成设备组页“厂商”列用的 MAC 前缀表：oui.sh <输出文件>
# 数据来自 Wireshark 的 manuf（https://www.wireshark.org/download/automated/data/manuf），
# 只取 24 位前缀，用完整厂商名并去掉公司后缀，每行“AABBCC 厂商”
set -eu
mkdir -p "$(dirname "$1")"
curl -fsSL -m 300 https://www.wireshark.org/download/automated/data/manuf | awk '
BEGIN { FS = "\t" }
/^#/ { next }
{
	gsub(/ +$/, "", $1); if (length($1) != 8) next
	n = ($3 != "") ? $3 : $2
	gsub(/,/, " ", n); gsub(/\./, "", n)
	for (i = 0; i < 2; i++)
		gsub(/ (Co|CO|Ltd|LTD|Limited|LIMITED|Inc|INC|Incorporated|Corp|CORP|Corporation|CORPORATION|LLC|GmbH|AG|SA|SAS|BV|AB|Oy|PLC|Pte|Pty|SpA|Srl|KK|Company|COMPANY)( |$)/, " ", n)
	gsub(/  +/, " ", n); gsub(/^ | $/, "", n)
	if (length(n) > 28) n = substr(n, 1, 28)
	gsub(":", "", $1); print toupper($1) " " n
}' > "$1.tmp"
[ "$(wc -l < "$1.tmp")" -gt 10000 ] || { echo "oui: 数据异常" >&2; rm -f "$1.tmp"; exit 1; }
mv "$1.tmp" "$1"
