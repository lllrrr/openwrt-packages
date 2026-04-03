#!/bin/sh

. $IPKG_INSTROOT/etc/init.d/naived

check_run_environment

# Set china_ip and verify that the file exists
china_ip="${1:-${china_ip:-/etc/naived/china_ip.txt}}"
[ -f "$china_ip" ] || exit 1

skip_inet="${SKIP_INET:-0}"

case "$skip_inet" in
	1)
		{
			# ss_spec / inet (add only when the table and set exist)
			if nft list set inet ss_spec china >/dev/null 2>&1; then
				echo "add element inet ss_spec china {"
				grep -vE '^\s*#|^\s*$' "$china_ip" | sed 's/^/  /;s/$/,/'
				echo "}"
			fi
		} | nft -f - || exit 1
		;;
	2)
		{
			# ss_spec_mangle / ip (add only when the table and set exist)
			if nft list set ip ss_spec_mangle china >/dev/null 2>&1; then
				echo "add element ip ss_spec_mangle china {"
				grep -vE '^\s*#|^\s*$' "$china_ip" | sed 's/^/  /;s/$/,/'
				echo "}"
			fi
		} | nft -f - || exit 1
		;;
	*)
		echolog "chinaipset: invalid SKIP_INET=$skip_inet"
		exit 1
		;;
esac
