#!/bin/sh
# Resolve source identity before copying files into the SDK; write only the supplied version.
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
  # A package copied into a firmware tree must not inherit that tree's Git identity.
  [ -e "$base/.git" ] || fail 'No package Git metadata; provide PULSE_VERSION.'
  [ "$(git -C "$base" rev-parse --is-shallow-repository)" = false ] || fail 'Fetch complete Git history and tags, or provide PULSE_VERSION.'
  tag="v$release"
  git -C "$base" rev-parse --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1 || fail "Missing release tag $tag."
  git -C "$base" merge-base --is-ancestor "refs/tags/$tag" HEAD || fail "Release tag $tag is not an ancestor of HEAD."
  count=$(git -C "$base" rev-list --count "refs/tags/$tag..HEAD")
  if [ "$count" -eq 0 ]; then printf '%s\n' "$release"; else printf '%s_git%s\n' "$release" "$count"; fi
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
