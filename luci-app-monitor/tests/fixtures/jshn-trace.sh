#!/bin/sh

json_init() { :; }
json_cleanup() { :; }
json_dump() { :; }

json_add_object() { printf 'object\t%s\n' "$1"; }
json_close_object() { printf 'close-object\n'; }
json_add_array() { printf 'array\t%s\n' "$1"; }
json_close_array() { printf 'close-array\n'; }
json_add_string() { printf 'string\t%s\t%s\n' "$1" "$2"; }
json_add_int() { printf 'int\t%s\t%s\n' "$1" "$2"; }
json_add_boolean() { printf 'boolean\t%s\t%s\n' "$1" "$2"; }

json_load() { JSON_TRACE_INPUT="$1"; }
json_get_var() {
	case "$2" in
		hours) eval "$1=24" ;;
		*) eval "$1=" ;;
	esac
}
