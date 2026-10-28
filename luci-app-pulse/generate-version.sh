#!/bin/sh
# Validate the configured version and write it into the frontend.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail() { echo "ERROR: $*" >&2; exit 1; }
validate() {
 printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(_git[0-9]+)?$' || fail 'Expected X.Y.Z or X.Y.Z_gitN.'
}
case "${1:-}" in
 --resolve)
  [ "$#" -eq 2 ] || fail 'Usage: generate-version.sh --resolve X.Y.Z'
  release=$2
  printf '%s\n' "$release" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'Invalid release version.'
  if [ -n "${PULSE_VERSION:-}" ]; then validate "$PULSE_VERSION"; printf '%s\n' "$PULSE_VERSION"; exit 0; fi
  printf '%s\n' "$release"
  ;;
 --write)
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'Usage: generate-version.sh --write VERSION [OUTPUT]'
  version=$2
  validate "$version"
  output=${3:-"$base/htdocs/luci-static/resources/view/pulse/index.js"}
  [ "$(grep -c '^var VERSION=.*// @pulse-version$' "$output")" = 1 ] || fail 'Missing or duplicate version marker.'
  temporary=$(mktemp "$output.XXXXXX")
  trap 'rm -f "$temporary"' 0
  sed "s/^var VERSION=.*\/\/ @pulse-version$/var VERSION='$version'; \/\/ @pulse-version/" "$output" > "$temporary"
  chmod 644 "$temporary"
  mv "$temporary" "$output"
  ;;
 *) fail 'Usage: generate-version.sh --resolve X.Y.Z | --write VERSION [OUTPUT]' ;;
esac
