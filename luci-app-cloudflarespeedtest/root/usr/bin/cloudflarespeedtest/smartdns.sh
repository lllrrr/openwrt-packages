#!/bin/sh

RESULT_CSV=''
IP_COUNT='3'
MODE='update'

SMARTDNS_CONFIG_FILE="${SMARTDNS_CONFIG_FILE:-/etc/smartdns/conf.d/cloudflarespeedtest.conf}"
SMARTDNS_SOURCE_FILE="${SMARTDNS_SOURCE_FILE:-/usr/share/CloudflareSpeedTest/ip.txt}"
SMARTDNS_INCLUDE_NAME="${SMARTDNS_INCLUDE_NAME:-cloudflarespeedtest.conf}"
SMARTDNS_SECTION="${SMARTDNS_SECTION:-smartdns.@smartdns[0]}"
SMARTDNS_INIT="${SMARTDNS_INIT:-/etc/init.d/smartdns}"
SMARTDNS_RELOAD_WAIT="${SMARTDNS_RELOAD_WAIT:-1}"
UCI_BIN="${UCI_BIN:-uci}"
MANAGED_MARKER='# Managed by luci-app-cloudflarespeedtest. Do not edit.'

usage() {
	cat <<'EOF'
Usage:
  smartdns.sh --result-csv FILE [--source-file FILE] [--ip-count NUMBER]
  smartdns.sh --disable

Updates or removes the SmartDNS configuration managed by
luci-app-cloudflarespeedtest.
EOF
}

log() {
	printf '%s\n' "$*"
}

uci_available() {
	command -v "$UCI_BIN" >/dev/null 2>&1
}

smartdns_section_exists() {
	uci_available && "$UCI_BIN" -q get "$SMARTDNS_SECTION" >/dev/null 2>&1
}

smartdns_enabled() {
	[ "$("$UCI_BIN" -q get "${SMARTDNS_SECTION}.enabled" 2>/dev/null)" = '1' ]
}

include_registered() {
	"$UCI_BIN" -q get "${SMARTDNS_SECTION}.conf_files" 2>/dev/null |
		tr ' ' '\n' | grep -Fqx "$SMARTDNS_INCLUDE_NAME"
}

add_include() {
	include_registered && return 0
	"$UCI_BIN" -q add_list "${SMARTDNS_SECTION}.conf_files=${SMARTDNS_INCLUDE_NAME}" || return 1
	if ! "$UCI_BIN" -q commit smartdns; then
		"$UCI_BIN" -q del_list "${SMARTDNS_SECTION}.conf_files=${SMARTDNS_INCLUDE_NAME}" >/dev/null 2>&1
		"$UCI_BIN" -q commit smartdns >/dev/null 2>&1
		return 1
	fi
}

remove_include() {
	include_registered || return 0
	"$UCI_BIN" -q del_list "${SMARTDNS_SECTION}.conf_files=${SMARTDNS_INCLUDE_NAME}" || return 1
	if ! "$UCI_BIN" -q commit smartdns; then
		"$UCI_BIN" -q add_list "${SMARTDNS_SECTION}.conf_files=${SMARTDNS_INCLUDE_NAME}" >/dev/null 2>&1
		"$UCI_BIN" -q commit smartdns >/dev/null 2>&1
		return 1
	fi
}

reload_smartdns() {
	smartdns_enabled || return 0
	[ -x "$SMARTDNS_INIT" ] || return 1

	"$SMARTDNS_INIT" reload >/dev/null 2>&1 || return 1
	sleep "$SMARTDNS_RELOAD_WAIT"
	"$SMARTDNS_INIT" running >/dev/null 2>&1
}

extract_ipv4_aliases() {
	awk -F, -v limit="$IP_COUNT" -v source="$SMARTDNS_SOURCE_FILE" '
		BEGIN {
			while ((status = getline line < source) > 0) {
				sub(/#.*/, "", line)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
				if (line == "")
					continue
				count = split(line, cidr, "/")
				if (count > 2 || !valid_ipv4(cidr[1]) ||
				    (count == 2 && (cidr[2] !~ /^[0-9]+$/ || cidr[2] + 0 > 32))) {
					exit 1
				}
				prefix = count == 2 ? cidr[2] + 0 : 32
				sizes[++range_count] = 2 ^ (32 - prefix)
				starts[range_count] = int(ip_number(cidr[1]) / sizes[range_count]) * sizes[range_count]
			}
			close(source)
			if (status < 0 || range_count == 0)
				exit 1
		}
		NR == 1 || /^#/ { next }

		function valid_ipv4(ip, parts, count, i) {
			count = split(ip, parts, ".")
			if (count != 4)
				return 0

			for (i = 1; i <= 4; i++) {
				if (parts[i] !~ /^[0-9]+$/ || parts[i] + 0 > 255)
					return 0
			}
			return 1
		}

		function ip_number(ip, parts) {
			split(ip, parts, ".")
			return ((parts[1] * 256 + parts[2]) * 256 + parts[3]) * 256 + parts[4]
		}

		function in_source_ranges(ip, value, i) {
			value = ip_number(ip)
			for (i = 1; i <= range_count; i++)
				if (value >= starts[i] && value < starts[i] + sizes[i])
					return 1
			return 0
		}

		NF >= 7 {
			ip = $1
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
			if (found < limit && valid_ipv4(ip) && in_source_ranges(ip) && !seen[ip]++) {
				aliases = aliases (aliases == "" ? "" : ",") ip
				found++
			}
		}

		END {
			if (found > 0)
				print aliases
		}
	' "$RESULT_CSV"
}

restore_update() {
	if [ "$CONFIG_CHANGED" = '1' ]; then
		if [ "$HAD_CONFIG" = '1' ]; then
			cp -p "$BACKUP_FILE" "$SMARTDNS_CONFIG_FILE"
		else
			rm -f "$SMARTDNS_CONFIG_FILE"
		fi
	fi

	if [ "$INCLUDE_ADDED" = '1' ]; then
		remove_include >/dev/null 2>&1
	fi

	reload_smartdns >/dev/null 2>&1
}

update_config() {
	local aliases config_dir temp_file

	[ -f "$RESULT_CSV" ] || {
		log "SmartDNS update failed: result file not found: $RESULT_CSV"
		return 1
	}
	[ -r "$SMARTDNS_SOURCE_FILE" ] || {
		log "SmartDNS update failed: source range file not found: $SMARTDNS_SOURCE_FILE"
		return 1
	}
	smartdns_section_exists || {
		log 'SmartDNS update failed: SmartDNS UCI configuration was not found'
		return 1
	}
	[ -x "$SMARTDNS_INIT" ] || {
		log "SmartDNS update failed: service script not found: $SMARTDNS_INIT"
		return 1
	}
	if [ -f "$SMARTDNS_CONFIG_FILE" ] && ! grep -Fqx "$MANAGED_MARKER" "$SMARTDNS_CONFIG_FILE"; then
		log "SmartDNS update failed: refusing to overwrite unmanaged file: $SMARTDNS_CONFIG_FILE"
		return 1
	fi

	aliases="$(extract_ipv4_aliases)" || {
		log 'SmartDNS update failed: invalid or unreadable source range file'
		return 1
	}
	[ -n "$aliases" ] || {
		log 'SmartDNS update skipped: no IPv4 address in the source ranges found in the speed test result'
		return 1
	}

	config_dir="${SMARTDNS_CONFIG_FILE%/*}"
	mkdir -p "$config_dir" || return 1
	temp_file="$(mktemp "${config_dir}/.cloudflarespeedtest.conf.XXXXXX")" || return 1

	{
		echo "$MANAGED_MARKER"
		echo '# Source ranges are a snapshot of the speed test IP list.'
		awk -v aliases="$aliases" '
			{
				sub(/#.*/, "")
				gsub(/^[[:space:]]+|[[:space:]]+$/, "")
				if ($0 != "")
					printf "ip-rules %s -ip-alias %s\n", $0, aliases
			}
		' "$SMARTDNS_SOURCE_FILE"
	} > "$temp_file" || {
		rm -f "$temp_file"
		return 1
	}
	chmod 0644 "$temp_file"

	HAD_CONFIG='0'
	CONFIG_CHANGED='0'
	INCLUDE_ADDED='0'
	BACKUP_FILE=''

	if [ -f "$SMARTDNS_CONFIG_FILE" ]; then
		HAD_CONFIG='1'
	fi

	if [ "$HAD_CONFIG" = '1' ] && cmp -s "$temp_file" "$SMARTDNS_CONFIG_FILE"; then
		rm -f "$temp_file"
	else
		if [ "$HAD_CONFIG" = '1' ]; then
			BACKUP_FILE="$(mktemp /tmp/cloudflarespeedtest-smartdns.XXXXXX)" || {
				rm -f "$temp_file"
				return 1
			}
			cp -p "$SMARTDNS_CONFIG_FILE" "$BACKUP_FILE" || {
				rm -f "$temp_file" "$BACKUP_FILE"
				return 1
			}
		fi
		mv -f "$temp_file" "$SMARTDNS_CONFIG_FILE" || {
			rm -f "$temp_file" "$BACKUP_FILE"
			return 1
		}
		CONFIG_CHANGED='1'
	fi

	if ! include_registered; then
		if ! add_include; then
			restore_update
			rm -f "$BACKUP_FILE"
			log 'SmartDNS update failed: could not register the managed config file'
			return 1
		fi
		INCLUDE_ADDED='1'
	fi

	if [ "$CONFIG_CHANGED" = '0' ] && [ "$INCLUDE_ADDED" = '0' ]; then
		if smartdns_enabled && ! "$SMARTDNS_INIT" running >/dev/null 2>&1; then
			if ! reload_smartdns; then
				log 'SmartDNS update failed: service is not running and could not be started'
				return 1
			fi
		fi
		log "SmartDNS aliases unchanged: $aliases"
		return 0
	fi

	if ! reload_smartdns; then
		restore_update
		rm -f "$BACKUP_FILE"
		log 'SmartDNS update failed: service reload failed; previous configuration restored'
		return 1
	fi

	rm -f "$BACKUP_FILE"
	if smartdns_enabled; then
		log "SmartDNS aliases updated: $aliases"
	else
		log "SmartDNS aliases updated: $aliases (service is disabled)"
	fi
}

disable_config() {
	local backup_file had_config had_include changed

	had_config='0'
	had_include='0'
	changed='0'
	backup_file=''

	if [ -f "$SMARTDNS_CONFIG_FILE" ]; then
		if ! grep -Fqx "$MANAGED_MARKER" "$SMARTDNS_CONFIG_FILE"; then
			log "SmartDNS cleanup skipped: unmanaged file was left unchanged: $SMARTDNS_CONFIG_FILE"
			return 0
		fi
		had_config='1'
		backup_file="$(mktemp /tmp/cloudflarespeedtest-smartdns.XXXXXX)" || return 1
		cp -p "$SMARTDNS_CONFIG_FILE" "$backup_file" || {
			rm -f "$backup_file"
			return 1
		}
		if ! rm -f "$SMARTDNS_CONFIG_FILE"; then
			rm -f "$backup_file"
			return 1
		fi
		changed='1'
	fi

	if smartdns_section_exists && include_registered; then
		had_include='1'
		if ! remove_include; then
			[ "$had_config" = '1' ] && cp -p "$backup_file" "$SMARTDNS_CONFIG_FILE"
			rm -f "$backup_file"
			return 1
		fi
		changed='1'
	fi

	if [ "$changed" = '0' ]; then
		rm -f "$backup_file"
		return 0
	fi

	if smartdns_section_exists && ! reload_smartdns; then
		[ "$had_config" = '1' ] && cp -p "$backup_file" "$SMARTDNS_CONFIG_FILE"
		[ "$had_include" = '1' ] && add_include >/dev/null 2>&1
		reload_smartdns >/dev/null 2>&1
		rm -f "$backup_file"
		log 'SmartDNS cleanup failed: service reload failed; previous configuration restored'
		return 1
	fi

	rm -f "$backup_file"
	log 'SmartDNS integration disabled and managed aliases removed'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--result-csv)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			RESULT_CSV="$2"
			shift 2
			;;
		--source-file)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			SMARTDNS_SOURCE_FILE="$2"
			shift 2
			;;
		--ip-count)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			IP_COUNT="$2"
			shift 2
			;;
		--disable)
			MODE='disable'
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
	esac
done

case "$IP_COUNT" in
	''|*[!0-9]*|0)
		log "Invalid SmartDNS IP count: $IP_COUNT" >&2
		exit 2
		;;
esac

if [ "$IP_COUNT" -gt 10 ]; then
	IP_COUNT='10'
fi

if [ "$MODE" = 'disable' ]; then
	disable_config
else
	[ -n "$RESULT_CSV" ] || { usage >&2; exit 2; }
	update_config
fi
