#!/bin/sh
# Install the latest stable release, including all available translations.
set -eu

REPO='w9315273/luci-app-pulse'
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Run this script as root.'
for tool in apk uclient-fetch jsonfilter sha256sum; do
 command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"
done

work=$(mktemp -d /tmp/pulse-install.XXXXXX)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
fetch() { uclient-fetch -q -O "$2" "$1" || fail "Download failed: $1"; }

echo 'Getting the latest Pulse release...'
fetch "https://api.github.com/repos/$REPO/releases/latest" "$work/release.json"
jsonfilter -i "$work/release.json" -e '@.assets[*].browser_download_url' > "$work/assets"
[ -s "$work/assets" ] || fail 'No release assets found.'

# Resolve actual asset names rather than deriving filenames from the tag.
asset() {
 matches=$(grep -E "^https://github.com/$REPO/releases/download/[^/]+/$1$" "$work/assets" || true)
 [ -n "$matches" ] || fail "Missing release asset: $1"
 [ "$(printf '%s\n' "$matches" | wc -l)" -eq 1 ] || fail "Ambiguous release asset: $1"
 printf '%s\n' "$matches"
}
fetch "$(asset 'SHA256SUMS')" "$work/SHA256SUMS"
asset 'luci-app-pulse-[A-Za-z0-9._+~-]+[.]apk' > "$work/packages"
grep -E "^https://github.com/$REPO/releases/download/[^/]+/luci-i18n-pulse-[A-Za-z0-9._+~-]+[.]apk$" "$work/assets" >> "$work/packages" || true
set --
while IFS= read -r url; do
 name=${url##*/}
 echo "Downloading $name..."
 fetch "$url" "$work/$name"
 # Only verify selected files; never follow paths supplied by the manifest.
 checksum=$(awk -v name="$name" '$2 == name || $2 == "./" name {print $1}' "$work/SHA256SUMS")
 [ "${#checksum}" -eq 64 ] || fail "Missing or invalid checksum: $name"
 case "$checksum" in *[!0-9a-fA-F]*) fail "Invalid checksum: $name" ;; esac
 printf '%s  %s\n' "$checksum" "$work/$name" | sha256sum -c - || fail "Checksum mismatch: $name"
 set -- "$@" "$work/$name"
done < "$work/packages"

echo 'Installing Pulse...'
apk add --allow-untrusted "$@"
/etc/init.d/pulse-traffic enable
/etc/init.d/pulse-traffic restart
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache/*
/etc/init.d/rpcd reload
echo 'Done. Refresh LuCI and open Dashboard.'
