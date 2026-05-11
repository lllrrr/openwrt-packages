#!/bin/sh
# Parental Control backend - manages nftables rules based on UCI config

. /lib/functions.sh

NFTABLES_FILE="/tmp/parentalcontrol.nft"
CONFIG_NAME="parentalcontrol"

generate_rules() {
	local enabled
	config_load "$CONFIG_NAME"
	config_get enabled global enabled '0'

	mkdir -p "$(dirname "$NFTABLES_FILE")"

	if [ "$enabled" != "1" ]; then
		cat > "$NFTABLES_FILE" <<-'NFTEOF'
		table inet parentalcontrol {
		}
		NFTEOF
		reload_nftables
		return 0
	fi

	local now
	now=$(date +%s)

	local rules=""

	generate_rule() {
		local section="$1"
		local name mac rule_enabled override_until
		config_get name "$section" name ""
		config_get mac "$section" mac ""
		config_get rule_enabled "$section" enabled '1'
		config_get override_until "$section" override_until '0'

		[ -z "$mac" ] && return
		[ "$rule_enabled" != "1" ] && return

		if [ -n "$override_until" ] && [ "$override_until" != "0" ]; then
			if [ "$now" -lt "$override_until" ]; then
				return
			else
				uci_set "$CONFIG_NAME" "$section" override_until '0'
			fi
		fi

		local mac_lower
		mac_lower=$(echo "$mac" | tr 'A-Z' 'a-z')
		local comment
		comment=$(echo "$name" | tr '"' '_')

		config_list_foreach "$section" schedule _process_schedule "$mac_lower" "$comment"
	}

	_days_to_nft() {
		echo "$1" | tr ',' '\n' | while read -r d; do
			case "$d" in
				mon|Mon) echo -n "Monday," ;;
				tue|Tue) echo -n "Tuesday," ;;
				wed|Wed) echo -n "Wednesday," ;;
				thu|Thu) echo -n "Thursday," ;;
				fri|Fri) echo -n "Friday," ;;
				sat|Sat) echo -n "Saturday," ;;
				sun|Sun) echo -n "Sunday," ;;
			esac
		done | sed 's/,$//'
	}

	_next_day() {
		case "$1" in
			mon) echo "tue" ;; tue) echo "wed" ;; wed) echo "thu" ;;
			thu) echo "fri" ;; fri) echo "sat" ;; sat) echo "sun" ;; sun) echo "mon" ;;
		esac
	}

	_shift_days() {
		local result="" sep=""
		echo "$1" | tr ',' '\n' | while read -r d; do
			printf "%s%s" "$sep" "$(_next_day "$d")"
			sep=","
		done
	}

	_process_schedule() {
		local schedule="$1"
		local mac="$2"
		local comment="$3"

		local days time_range
		days=$(echo "$schedule" | awk '{print $1}')
		time_range=$(echo "$schedule" | awk '{print $2}')

		[ -z "$time_range" ] && return

		local start_time end_time
		start_time=$(echo "$time_range" | cut -d- -f1)
		end_time=$(echo "$time_range" | cut -d- -f2)

		local start_h end_h
		start_h=$(echo "$start_time" | cut -d: -f1 | sed 's/^0//')
		end_h=$(echo "$end_time" | cut -d: -f1 | sed 's/^0//')
		[ -z "$start_h" ] && start_h=0
		[ -z "$end_h" ] && end_h=0

		local nft_days
		nft_days=$(_days_to_nft "$days")

		local day_match=""
		if [ -n "$nft_days" ]; then
			day_match="meta day { $nft_days } "
		fi

		if [ "$start_h" -gt "$end_h" ]; then
			# Midnight crossing: second half uses next day
			local next_days next_nft_days next_day_match
			next_days=$(_shift_days "$days")
			next_nft_days=$(_days_to_nft "$next_days")
			next_day_match=""
			if [ -n "$next_nft_days" ]; then
				next_day_match="meta day { $next_nft_days } "
			fi

			rules="$rules
		${day_match}ether saddr $mac meta hour \"${start_time}\"-\"23:59:59\" counter drop comment \"${comment}\"
		${next_day_match}ether saddr $mac meta hour \"00:00\"-\"${end_time}\" counter drop comment \"${comment}\""
		else
			rules="$rules
		${day_match}ether saddr $mac meta hour \"${start_time}\"-\"${end_time}\" counter drop comment \"${comment}\""
		fi
	}

	config_foreach generate_rule rule

	cat > "$NFTABLES_FILE" <<NFTEOF
table inet parentalcontrol {
	chain forward {
		type filter hook forward priority -1; policy accept;$rules
	}
}
NFTEOF

	uci_commit "$CONFIG_NAME"
	reload_nftables
}

reload_nftables() {
	nft list table inet parentalcontrol >/dev/null 2>&1 && \
		nft delete table inet parentalcontrol
	nft -f "$NFTABLES_FILE" 2>/dev/null
}

check_overrides() {
	local now
	now=$(date +%s)
	local changed=0

	config_load "$CONFIG_NAME"

	_check_override() {
		local section="$1"
		local override_until
		config_get override_until "$section" override_until '0'

		if [ -n "$override_until" ] && [ "$override_until" != "0" ] && [ "$now" -ge "$override_until" ]; then
			uci_set "$CONFIG_NAME" "$section" override_until '0'
			changed=1
		fi
	}

	config_foreach _check_override rule

	if [ "$changed" -eq 1 ]; then
		uci_commit "$CONFIG_NAME"
		generate_rules
	fi
}

clear_rules() {
	nft list table inet parentalcontrol >/dev/null 2>&1 && \
		nft delete table inet parentalcontrol
	rm -f "$NFTABLES_FILE"
}

case "$1" in
	apply)
		generate_rules
		;;
	check_overrides)
		check_overrides
		;;
	clear)
		clear_rules
		;;
	*)
		echo "Usage: $0 {apply|check_overrides|clear}"
		exit 1
		;;
esac
