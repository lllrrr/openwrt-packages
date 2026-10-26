#!/bin/sh
# Shared whitelist validation for luci-app-trusted.
#
# Sourced by /etc/init.d/trusted, which is the authoritative filter before the
# nft ruleset is generated, and by /usr/sbin/trusted, so that a shell user gets
# exactly the same verdict as the firewall.  Change it in one place only.
#
# Only plain IPv4 addresses and CIDR prefixes are accepted.  Everything else
# has to be rejected: the generated ruleset is the only thing between a
# mistyped value and an open root shell.

valid_cidr4() {
	local ip="$1" bits="" o n=0 has_bits=0

	case "$ip" in
	*/*) has_bits=1; bits="${ip#*/}"; ip="${ip%%/*}" ;;
	esac

	case "$ip" in
	''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
	esac

	local IFS=.
	for o in $ip; do
		case "$o" in
		''|*[!0-9]*) return 1 ;;
		esac
		# reject leading zeros: "010" is 10 to nft but not to every shell
		case "$o" in
		0) ;;
		0*) return 1 ;;
		esac
		[ "$o" -le 255 ] 2>/dev/null || return 1
		n=$((n + 1))
	done
	[ "$n" -eq 4 ] || return 1

	[ "$has_bits" = "1" ] || return 0

	case "$bits" in
	''|*[!0-9]*) return 1 ;;
	0) ;;
	0*) return 1 ;;
	esac
	[ "$bits" -le 32 ] 2>/dev/null
}

# ------------------------------------------------------------------ i18n ---

# The plugin speaks the language LuCI is set to, not the shell locale: the web
# page and this command must never disagree.  LuCI master keeps the setting in
# luci.main.lang, older releases in system.@system[0].language.  Both are
# checked, then the shell locale, then English.
#
# Only two catalogs exist.  Anything that is not Chinese gets English, so a
# missing translation degrades to readable text, not to blank output.

TRUSTED_LANG=""

trusted_lang() {
	local l=""

	if [ -n "$TRUSTED_LANG" ]; then
		echo "$TRUSTED_LANG"
		return 0
	fi

	l=$(uci -q get luci.main.lang 2>/dev/null)
	[ "$l" = "auto" ] && l=""
	[ -n "$l" ] || l=$(uci -q get system.@system[0].language 2>/dev/null)
	[ -n "$l" ] || l="${LC_ALL}"
	[ -n "$l" ] || l="${LC_MESSAGES}"
	[ -n "$l" ] || l="${LANG}"

	l=$(echo "$l" | tr 'A-Z' 'a-z')

	case "$l" in
	zh*) TRUSTED_LANG=zh_cn ;;
	*)   TRUSTED_LANG=en ;;
	esac

	echo "$TRUSTED_LANG"
}

# Read the catalog for the current language.  Returns 1 when neither the wanted
# catalog nor the English one is readable; t() then prints the key name, which
# makes a broken installation visible instead of silently printing nothing.
i18n_init() {
	local f

	f="/usr/share/trusted/i18n/$(trusted_lang).sh"
	[ -r "$f" ] || f="/usr/share/trusted/i18n/en.sh"
	[ -r "$f" ] || return 1

	. "$f"
	return 0
}

# t <key> [argument...] - print catalog entry T_<key> through printf.
t() {
	local k="T_$1" fmt=""

	[ $# -gt 0 ] && shift
	eval "fmt=\${$k-}"

	if [ -z "$fmt" ]; then
		printf '%s\n' "$k"
		return 1
	fi

	if [ $# -gt 0 ]; then
		printf "$fmt" "$@"
	else
		printf '%s' "$fmt"
	fi
}
