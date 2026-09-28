#!/bin/sh
# DeviceMaster UCI bootstrap helpers
#
# Sourced by BOTH
#   /etc/uci-defaults/90_devicemaster   (first boot after install/upgrade)
#   /etc/init.d/devicemaster            (every service start)
#
# Every helper is idempotent, so running them on every start is safe.
# Running them from the init script is also *necessary*: /etc/config/devicemaster
# is shipped with the package, therefore the "create the config if missing"
# branch in uci-defaults never fires on an existing installation, and things like
# the built-in device groups would silently never be created.
#
# IMPORTANT: `uci commit` rewrites the config file, i.e. it writes to flash.
# The init script runs on every boot, so a helper must only commit when it
# actually changed something - hence dm_changed/dm_commit().

# Set to 1 by every dm_* helper that modifies the config; dm_commit() flushes
# and resets it. Reset on source so the state never leaks between callers.
dm_changed=0

dm_commit() {
	[ "$dm_changed" = "1" ] || return 0
	uci -q commit devicemaster
	dm_changed=0
	return 0
}

# Number of sections of a given type.
#
# Only true section lines are counted. `uci show` prints
#   devicemaster.@group[0]=group     (anonymous)
#   devicemaster.phones=group        (named)
#   devicemaster.phones.name='手机'   (option - always has a second dot)
# so requiring exactly one dot before '=' excludes every option line. A plain
# `grep -c "=group$"` would also match an option whose value happens to be
# "group".
dm_section_count() {
	uci -q show devicemaster 2>/dev/null | awk -F= -v want="$1" '
		$1 ~ /^[^.]+\.[^.]+$/ && $2 == want { n++ }
		END { print n + 0 }'
}

# ---------------------------------------------------------------------------
# Remove the empty template stanzas that old versions of the package shipped
# inside /etc/config/devicemaster (config device/group/schedule with nothing but
# empty options).
#
# Consequences of leaving them in place:
#   * config device without mac  -> shows up as a blank device card, because
#     uci:foreach() hands out a section whose .mac is the empty string ("" is
#     truthy in Lua).
#   * config group/schedule without a name -> empty rows in 分组配置.
#
# Only anonymous sections are inspected: @type[idx] addresses anonymous sections
# only, and named sections (e.g. the built-in groups) always carry their id, so
# they can never be mistaken for an empty template.
# ---------------------------------------------------------------------------
dm_prune_template_sections() {
	local spec field key idx val del

	for spec in "device mac" "group name" "schedule name"; do
		field="${spec%% *}"
		key="${spec##* }"
		del=""

		idx=0
		while uci -q get "devicemaster.@$field[$idx]" >/dev/null 2>&1; do
			val=$(uci -q get "devicemaster.@$field[$idx].$key" 2>/dev/null)
			[ -z "$val" ] && del="$del $idx"
			idx=$((idx + 1))
		done

		# Delete from the highest index down, otherwise the indices shift.
		for idx in $(echo $del | tr ' ' '\n' | sort -rn); do
			uci -q delete "devicemaster.@$field[$idx]"
			dm_changed=1
		done
	done

	dm_commit
	return 0
}

# ---------------------------------------------------------------------------
# Ensure the named 'settings' section used by the OUI management page exists.
# ---------------------------------------------------------------------------
dm_ensure_settings() {
	[ -n "$(uci -q get devicemaster.settings.oui_mode 2>/dev/null)" ] && return 0

	uci -q set devicemaster.settings=settings
	uci -q set devicemaster.settings.oui_mode='remote'
	uci -q set devicemaster.settings.remote_api='maclookup'
	dm_changed=1
	dm_commit
	return 0
}

# ---------------------------------------------------------------------------
# Create the built-in device groups, but only when the user has no group yet.
# ---------------------------------------------------------------------------
dm_ensure_default_groups() {
	[ "$(dm_section_count group)" -gt 0 ] && return 0

	dm_add_group 'phones'    '手机'     '📱' '#3498db'
	dm_add_group 'computers' '电脑'     '💻' '#2ecc71'
	dm_add_group 'iot'       '智能家居' '🏠' '#9b59b6'
	dm_add_group 'network'   '网络设备' '🌐' '#e74c3c'

	dm_commit
	return 0
}

# Add one group as a NAMED section (devicemaster.<id>=group).
#
# Named matters: the group id has to be identical everywhere it is used -
# `devicemaster.@device[n].group`, the group dropdown in the device editor, and
# `api/get_groups`. With an anonymous section the UCI section name is an opaque
# `cfg0a1b2c`, so the id stored on devices ('phones') never matched the id the
# API reported and the group filter silently matched nothing.
#
# Idempotent: an existing section is left untouched, so user edits to the
# icon/colour survive every boot.
dm_add_group() {
	local id="$1" name="$2" icon="$3" color="$4"

	uci -q get "devicemaster.$id" >/dev/null 2>&1 && return 0

	uci -q set "devicemaster.$id=group"
	uci -q set "devicemaster.$id.id=$id"
	uci -q set "devicemaster.$id.name=$name"
	[ -n "$icon" ] && uci -q set "devicemaster.$id.icon=$icon"
	[ -n "$color" ] && uci -q set "devicemaster.$id.color=$color"
	dm_changed=1
	return 0
}

# Convenience wrapper used by the init script.
dm_bootstrap_uci() {
	dm_changed=0
	dm_ensure_settings
	dm_prune_template_sections
	dm_ensure_default_groups
	dm_commit
	return 0
}
