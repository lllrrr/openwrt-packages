#!/bin/sh

. $IPKG_INSTROOT/etc/init.d/naived

check_run_environment

nft_support=1
echolog "gfw2ipset: Using nftables"

netflix() {
	local port="$1"
	if [ -f "$TMP_DNSMASQ_PATH/gfw_list.conf" ] && [ -s /etc/naived/netflix.list ]; then
		grep -vE '^\s*#|^\s*$' /etc/naived/netflix.list > /tmp/naived_netflix.list.clean
		if [ -s /tmp/naived_netflix.list.clean ]; then
			grep -v -F -f /tmp/naived_netflix.list.clean "$TMP_DNSMASQ_PATH/gfw_list.conf" > "$TMP_DNSMASQ_PATH/gfw_list.conf.tmp"
			mv "$TMP_DNSMASQ_PATH/gfw_list.conf.tmp" "$TMP_DNSMASQ_PATH/gfw_list.conf"
			if [ -f "$TMP_DNSMASQ_PATH/gfw_base.conf" ]; then
				grep -v -F -f /tmp/naived_netflix.list.clean "$TMP_DNSMASQ_PATH/gfw_base.conf" > "$TMP_DNSMASQ_PATH/gfw_base.conf.tmp"
				mv "$TMP_DNSMASQ_PATH/gfw_base.conf.tmp" "$TMP_DNSMASQ_PATH/gfw_base.conf"
			fi
		fi
		rm -f /tmp/naived_netflix.list.clean
	fi
	if [ "$nft_support" = "1" ]; then
		# Replace ipset rules with nftset rules
		cat /etc/naived/netflix.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1#$port\nnftset=\/&\/4#inet#ss_spec#netflix/" >$TMP_DNSMASQ_PATH/netflix_forward.conf
	elif [ "$nft_support" = "0" ]; then
		cat /etc/naived/netflix.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1#$port\nipset=\/&\/netflix/" >$TMP_DNSMASQ_PATH/netflix_forward.conf
	fi
}
mkdir -p $TMP_DNSMASQ_PATH

run_mode=$(uci_get_by_type global run_mode router)

if [ "$run_mode" = "oversea" ]; then
	cp -rf /etc/naived/oversea_list.conf $TMP_DNSMASQ_PATH/
else
	cp -rf /etc/naived/gfw_list.conf $TMP_DNSMASQ_PATH/
	cp -rf /etc/naived/gfw_base.conf $TMP_DNSMASQ_PATH/
fi

for conf_file in gfw_base.conf gfw_list.conf; do
	conf="$TMP_DNSMASQ_PATH/$conf_file"
	[ -f "$conf" ] || continue

	if [ "$run_mode" = "gfw" ]; then
		if [ "$nft_support" = "1" ]; then
			# gfw + nft：ipset → nftset
			sed -i 's|ipset=/\([^/]*\)/\([^[:space:]]*\)|nftset=/\1/4#inet#ss_spec#\2|g' "$conf"
		fi
	else
		# Non-GFW mode: always remove split-routing references
		# sed -i '/^[[:space:]]*\(ipset=\|nftset=\)/d' "$conf"
		sed -i '/^[[:space:]]*ipset=/d' "$conf"
	fi
done

if [ "$(uci_get_by_type global netflix_enable 0)" == "1" ]; then
	# Only read the value when Netflix shunt is enabled
	SHUNT_SERVER=$(uci_get_by_type global netflix_server nil)
else
	# Set to nil when the feature is disabled
	SHUNT_SERVER=nil
fi
case "$SHUNT_SERVER" in
nil)
	rm -f $TMP_DNSMASQ_PATH/netflix_forward.conf
	;;
$(uci_get_by_type global global_server nil) | $switch_server | same)
	netflix $dns_port
	;;
*)
	netflix $tmp_shunt_dns_port
	;;
esac

# Use a for-loop to process list files safely, even when entries contain spaces.
# Optimize: Batch filter using grep
for list_file in /etc/naived/black.list /etc/naived/white.list /etc/naived/deny.list; do
	if [ -s "$list_file" ]; then
		grep -vE '^\s*#|^\s*$' "$list_file" > "${list_file}.clean"
		if [ -s "${list_file}.clean" ]; then
			for target_file in "$TMP_DNSMASQ_PATH/gfw_list.conf" "$TMP_DNSMASQ_PATH/gfw_base.conf"; do
				if [ -f "$target_file" ]; then
					grep -v -F -f "${list_file}.clean" "$target_file" > "${target_file}.tmp"
					mv "${target_file}.tmp" "$target_file"
				fi
			done
		fi
		rm -f "${list_file}.clean"
	fi
done

# Use cat here because comments have already been stripped by sed '/#/d'.
if [ "$nft_support" = "1" ]; then
	cat /etc/naived/black.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1#$dns_port\nnftset=\/&\/4#inet#ss_spec#blacklist/" >$TMP_DNSMASQ_PATH/blacklist_forward.conf
	cat /etc/naived/white.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1\nnftset=\/&\/4#inet#ss_spec#whitelist/" >$TMP_DNSMASQ_PATH/whitelist_forward.conf
elif [ "$nft_support" = "0" ]; then
	cat /etc/naived/black.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1#$dns_port\nipset=\/&\/blacklist/" >$TMP_DNSMASQ_PATH/blacklist_forward.conf
	cat /etc/naived/white.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/server=\/&\/127.0.0.1\nipset=\/&\/whitelist/" >$TMP_DNSMASQ_PATH/whitelist_forward.conf
fi
cat /etc/naived/deny.list | sed '/^$/d' | sed '/#/d' | sed "/.*/s/.*/address=\/&\//" >$TMP_DNSMASQ_PATH/denylist.conf

if [ "$(uci_get_by_type global adblock 0)" == "1" ]; then
	cp -f /etc/naived/ad.conf $TMP_DNSMASQ_PATH/
	if [ -f "$TMP_DNSMASQ_PATH/ad.conf" ]; then
		for list_file in /etc/naived/black.list /etc/naived/white.list /etc/naived/deny.list /etc/naived/netflix.list; do
			if [ -s "$list_file" ]; then
				grep -vE '^\s*#|^\s*$' "$list_file" > "${list_file}.clean"
				if [ -s "${list_file}.clean" ]; then
					grep -v -F -f "${list_file}.clean" "$TMP_DNSMASQ_PATH/ad.conf" > "$TMP_DNSMASQ_PATH/ad.conf.tmp"
					mv "$TMP_DNSMASQ_PATH/ad.conf.tmp" "$TMP_DNSMASQ_PATH/ad.conf"
				fi
				rm -f "${list_file}.clean"
			fi
		done
	fi
else
	rm -f $TMP_DNSMASQ_PATH/ad.conf
fi
