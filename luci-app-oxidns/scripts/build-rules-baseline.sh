#!/bin/sh
#
# Build the OxiDNS rule baseline tarball used by the oxidns-rules-baseline
# package and by the LuCI "Rules" update page.
#
#   ./scripts/build-rules-baseline.sh [VERSION]     # default: today, YYYY.MM.DD
#
# Output: dist/oxidns-rules-baseline-<VERSION>.tar.gz
#         dist/oxidns-rules-baseline/            (unpacked tree, for inspection)
#
# The archive root is oxidns-rules-baseline/ and it contains:
#   4 upstream rule lists + cn-domains.txt (converted) + MANIFEST.txt
#   + VERSION + SHA256SUMS + LICENSES/
#
# Everything is validated before the tarball is written: OxiDNS aborts the
# whole process when a domain_set file contains a single unparsable line, so a
# bad baseline must never reach a release.
#
# Supply chain notes
# ------------------
# All downloads are HTTPS-only and are pinned by REF + expected SHA256. The
# defaults track the upstream branches so the scheduled workflow can detect
# list changes; set the *_REF / *_SHA256 variables to the commit SHA and hash
# of a reviewed release to make a build fully immutable. To update a pin:
#
#   REF=$(curl -fsSL https://api.github.com/repos/<owner>/<repo>/commits/<branch> \
#         | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)
#   SHA256=$(curl -fsSL <raw-url-at-REF> | sha256sum | awk '{print $1}')
#   ./scripts/build-rules-baseline.sh VERSION  # with REF/SHA256 exported
#
# A configured *_SHA256 is always verified; a mismatch is fatal, including on
# a fallback mirror. SOURCE_DATE_EPOCH may be exported to override the
# VERSION-derived archive timestamp.
set -eu

export LC_ALL=C

VERSION="${1:-${VERSION:-$(date -u +%Y.%m.%d)}}"
OUT_DIR="${OUT_DIR:-dist}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_NAME="oxidns-rules-baseline"
BASE_DIR="$OUT_DIR/$BASE_NAME"
ASSET="$OUT_DIR/$BASE_NAME-$VERSION.tar.gz"
CHINA_SRC="$OUT_DIR/.accelerated-domains.china.conf.$$"
trap 'rm -f "$CHINA_SRC"' EXIT HUP INT TERM

# Upstream refs. Mutable branch names by default (scheduled builds must see
# updates); replace with a 40-hex commit SHA for a reproducible, immutable
# build. The matching *_SHA256 variables are optional but strongly recommended
# whenever a ref is pinned.
ADGUARD_URL="${ADGUARD_URL:-https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt}"
ADGUARD_SHA256="${ADGUARD_SHA256:-}"
ANTI_AD_REF="${ANTI_AD_REF:-master}"
ANTI_AD_SHA256="${ANTI_AD_SHA256:-}"
ADRULES_REF="${ADRULES_REF:-main}"
ADRULES_SHA256="${ADRULES_SHA256:-}"
NEODEVHOST_REF="${NEODEVHOST_REF:-master}"
NEODEVHOST_SHA256="${NEODEVHOST_SHA256:-}"
CHINA_REF="${CHINA_REF:-master}"
CHINA_SHA256="${CHINA_SHA256:-}"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'required command not found: %s\n' "$1" >&2
		exit 1
	}
}

need_cmd awk
need_cmd curl
need_cmd grep
need_cmd sed
need_cmd sort
need_cmd tar
need_cmd wc

# GNU coreutils and BusyBox both ship sha256sum; macOS only has shasum.
if command -v sha256sum >/dev/null 2>&1; then
	sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }
	sha256_list() { sha256sum "$@"; }
	sha256_stdin() { sha256sum | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
	sha256_list() { shasum -a 256 "$@"; }
	sha256_stdin() { shasum -a 256 | awk '{ print $1 }'; }
else
	printf 'required command not found: sha256sum (or shasum)\n' >&2
	exit 1
fi

# fetch <dest> <expected-sha256> <url> [fallback-url]...
# HTTPS is enforced before curl runs, and the expected digest is checked for
# every candidate mirror so a compromised mirror cannot win the race.
fetch() {
	dest="$1"
	expected="$2"
	shift 2
	rm -f "$dest"
	for url in "$@"; do
		case "$url" in
			https://*) ;;
			*)
				printf 'ERROR: refusing non-https URL: %s\n' "$url" >&2
				continue
				;;
		esac
		if curl -fsSL --proto '=https' --proto-redir '=https' \
			--max-redirs 3 --retry 3 --max-time 180 -o "$dest" "$url"; then
			if [ -n "$expected" ]; then
				actual="$(sha256_of "$dest")"
				if [ "$actual" != "$expected" ]; then
					printf 'ERROR: SHA256 mismatch for %s: expected %s, got %s\n' \
						"$url" "$expected" "$actual" >&2
					rm -f "$dest"
					continue
				fi
			fi
			return 0
		fi
	done
	printf 'ERROR: failed to download a verified copy for %s\n' "$dest" >&2
	return 1
}

# validate_domain_set <file> <min-lines>
# Mirrors what domain_set accepts: blank lines, '#' comments, prefixed rules
# (domain:/full:/keyword:/regexp:), or a bare domain containing a dot.
validate_domain_set() {
	file="$1"
	min_lines="$2"
	lines="$(wc -l < "$file" | awk '{ print $1 + 0 }')"
	if [ "$lines" -lt "$min_lines" ]; then
		printf 'ERROR: %s has only %s lines (minimum %s)\n' "$file" "$lines" "$min_lines" >&2
		return 1
	fi
	if ! awk '
		/^[[:space:]]*$/ { next }
		/^[[:space:]]*#/ { next }
		/^(domain|full|keyword|regexp):.+/ { next }
		/^[A-Za-z0-9_.-]+$/ && index($0, ".") > 0 { next }
		{
			printf "ERROR: %s: illegal line %d: %.80s\n", FILENAME, NR, $0 > "/dev/stderr";
			exit 1
		}
	' "$file"; then
		return 1
	fi
	return 0
}

# validate_plain_list <file> <min-lines>
validate_plain_list() {
	file="$1"
	min_lines="$2"
	lines="$(wc -l < "$file" | awk '{ print $1 + 0 }')"
	if [ "$lines" -lt "$min_lines" ]; then
		printf 'ERROR: %s has only %s lines (minimum %s)\n' "$file" "$lines" "$min_lines" >&2
		return 1
	fi
	if head -n 5 "$file" | grep -qi '<html'; then
		printf 'ERROR: %s looks like an HTML error page\n' "$file" >&2
		return 1
	fi
	return 0
}

# validate_adguard_list <file> <min-lines>
# AdGuard DNS filter syntax differs from domain_set: '!' comments, '[section]'
# headers, '||domain^' rules, '@@' exceptions, '/' regex rules, '.domain^'
# address masks, and bare domains/IPs with optional '$modifiers'. Reject HTML
# error pages, whitespace, control characters and lines that match none of
# those forms, so a truncated or corrupted download is never published.
validate_adguard_list() {
	file="$1"
	min_lines="$2"
	lines="$(wc -l < "$file" | awk '{ print $1 + 0 }')"
	if [ "$lines" -lt "$min_lines" ]; then
		printf 'ERROR: %s has only %s lines (minimum %s)\n' "$file" "$lines" "$min_lines" >&2
		return 1
	fi
	if head -n 5 "$file" | grep -qi '<html'; then
		printf 'ERROR: %s looks like an HTML error page\n' "$file" >&2
		return 1
	fi
	if LC_ALL=C grep -q '[^ -~]' "$file"; then
		printf 'ERROR: %s contains non-printable or non-ASCII bytes\n' "$file" >&2
		return 1
	fi
	if ! awk '
		/^[[:space:]]*$/ { next }
		/^[[:space:]]*[!#]/ { next }
		/^\[[^]]*\]$/ { next }
		{
			line = $0
			if (line ~ /[[:space:]]/ || line ~ /[<>"]/ || index(line, "\047") > 0) {
				printf "ERROR: %s: illegal character on line %d: %.80s\n", FILENAME, NR, line > "/dev/stderr";
				exit 1
			}
			# Any printable, whitespace-free token is a valid AdGuard DNS
			# filter expression (||domain^, @@ exception, /regex/, .mask^,
			# bare domain/IP, optional $modifiers, etc.).
			next
		}
	' "$file"; then
		return 1
	fi
	return 0
}

# Only wipe this script's own outputs: --out dir may hold other artifacts
# (ipk/apk from scripts/build-luci-package.sh).
rm -rf "$BASE_DIR" "$ASSET" "$ASSET.sha256"
mkdir -p "$BASE_DIR/LICENSES"

printf '== downloading upstream lists ==\n'
fetch "$BASE_DIR/adguard-hostlist.txt" "$ADGUARD_SHA256" "$ADGUARD_URL"
fetch "$BASE_DIR/anti-ad-domains.txt" "$ANTI_AD_SHA256" \
	"https://cdn.jsdelivr.net/gh/privacy-protection-tools/anti-AD@$ANTI_AD_REF/anti-ad-domains.txt" \
	"https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/$ANTI_AD_REF/anti-ad-domains.txt"
fetch "$BASE_DIR/adrules-domains.txt" "$ADRULES_SHA256" \
	"https://cdn.jsdelivr.net/gh/Cats-Team/AdRules@$ADRULES_REF/mosdns_adrules.txt" \
	"https://raw.githubusercontent.com/Cats-Team/AdRules/$ADRULES_REF/mosdns_adrules.txt"
fetch "$BASE_DIR/neodevhost-domains.txt" "$NEODEVHOST_SHA256" \
	"https://cdn.jsdelivr.net/gh/neodevpro/neodevhost@$NEODEVHOST_REF/domain" \
	"https://raw.githubusercontent.com/neodevpro/neodevhost/$NEODEVHOST_REF/domain"
fetch "$CHINA_SRC" "$CHINA_SHA256" \
	"https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@$CHINA_REF/accelerated-domains.china.conf" \
	"https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/$CHINA_REF/accelerated-domains.china.conf"

printf '== converting dnsmasq-china-list to cn-domains.txt ==\n'
sed -n 's|^server=/\([^/]*\)/.*|\1|p' "$CHINA_SRC" \
	| grep -F . \
	| LC_ALL=C sort -u > "$BASE_DIR/cn-domains.txt"
rm -f "$CHINA_SRC"

printf '== validating ==\n'
validate_adguard_list "$BASE_DIR/adguard-hostlist.txt" 50000
validate_domain_set "$BASE_DIR/anti-ad-domains.txt" 50000
validate_domain_set "$BASE_DIR/adrules-domains.txt" 100000
validate_domain_set "$BASE_DIR/neodevhost-domains.txt" 100000
validate_domain_set "$BASE_DIR/cn-domains.txt" 50000
printf 'all rule files passed validation\n'

cp "$ROOT_DIR"/rules-baseline/LICENSES/*.LICENSE "$BASE_DIR/LICENSES/"

printf '%s\n' "$VERSION" > "$BASE_DIR/VERSION"

{
	printf '# OxiDNS rule baseline - bundled, read-only reference copy\n'
	printf '# Installed by oxidns-rules-baseline to /usr/share/oxidns/rules-baseline.\n'
	printf '# Seeded into /etc/oxidns/rules by /etc/init.d/oxidns when a file is missing.\n'
	printf '# Updated at runtime by the LuCI "Rules" page (release tags rules-v<version>).\n'
	printf '#\n'
	printf '# version: %s\n' "$VERSION"
	printf '# built:   %s\n' "${BUILD_STAMP:-$(printf '%s' "$VERSION" | tr '.' '-')}"
	printf '#\n'
	printf '%-34s %10s %8s  %s\n' FILE BYTES LINES LICENSE
	for entry in \
		"adguard-hostlist.txt:GPL-3.0-or-later" \
		"anti-ad-domains.txt:MIT" \
		"adrules-domains.txt:0BSD" \
		"neodevhost-domains.txt:MIT" \
		"cn-domains.txt:WTFPL"
	do
		name="${entry%%:*}"
		license="${entry##*:}"
		printf '%-34s %10s %8s  %s\n' "$name" \
			"$(wc -c < "$BASE_DIR/$name" | awk '{ print $1 + 0 }')" \
			"$(wc -l < "$BASE_DIR/$name" | awk '{ print $1 + 0 }')" \
			"$license"
	done
	printf '#\n'
	printf '# sources:\n'
	printf '#  adguard-hostlist.txt          %s\n' "$ADGUARD_URL"
	printf '#  anti-ad-domains.txt           https://github.com/privacy-protection-tools/anti-AD@%s\n' "$ANTI_AD_REF"
	printf '#  adrules-domains.txt           https://github.com/Cats-Team/AdRules@%s\n' "$ADRULES_REF"
	printf '#  neodevhost-domains.txt        https://github.com/neodevpro/neodevhost@%s\n' "$NEODEVHOST_REF"
	printf '#  cn-domains.txt                converted from dnsmasq-china-list@%s (source not shipped)\n' "$CHINA_REF"
	printf '#\n'
	printf '# License texts: LICENSES/ (GPL-3.0-or-later for the AdGuard filter, MIT for\n'
	printf '# anti-AD and neodevhost, 0BSD for AdRules, WTFPL for dnsmasq-china-list).\n'
} > "$BASE_DIR/MANIFEST.txt"

(
	cd "$BASE_DIR"
	sha256_list *.txt > SHA256SUMS
)

# Reproducible timestamps: two builds of the same rule data must produce the
# same archive bytes, otherwise PKG_HASH in the package Makefile would break
# on every re-run. SOURCE_DATE_EPOCH (if exported) wins; otherwise the stamp is
# derived from VERSION. Touch works on both BSD and GNU systems, and gzip -n
# drops the gzip header timestamp. GNU tar additionally gets --mtime; bsdtar
# honours the touched mtimes and SOURCE_DATE_EPOCH.
stamp_of() {
	printf '%s\n' "$VERSION" | awk -F. '{
		hh = "00"; mm = "00";
		if (NF >= 4 && length($4) == 4) { hh = substr($4, 1, 2); mm = substr($4, 3, 2) }
		printf "%s%s%s%s%s.00\n", $1, $2, $3, hh, mm
	}'
}
iso_of() {
	printf '%s\n' "$VERSION" | awk -F. '{
		hh = "00"; mm = "00";
		if (NF >= 4 && length($4) == 4) { hh = substr($4, 1, 2); mm = substr($4, 3, 2) }
		printf "%s-%s-%s %s:%s:00\n", $1, $2, $3, hh, mm
	}'
}
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	EPOCH="$SOURCE_DATE_EPOCH"
else
	ISO="$(iso_of)"
	EPOCH="$(date -u -d "$ISO" +%s 2>/dev/null || true)"
	if [ -z "$EPOCH" ]; then
		# BSD/macOS date: -j -f <format> <value> +%s
		EPOCH="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$ISO" +%s 2>/dev/null || true)"
	fi
	if [ -z "$EPOCH" ]; then
		printf 'ERROR: cannot derive a UTC epoch for version %s\n' "$VERSION" >&2
		exit 1
	fi
fi
case "$EPOCH" in
	''|*[!0-9]*) printf 'ERROR: invalid SOURCE_DATE_EPOCH: %s\n' "$EPOCH" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH="$EPOCH"
TOUCH_STAMP="$(date -u -r "$EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || true)"
if [ -z "$TOUCH_STAMP" ]; then
	TOUCH_STAMP="$(date -u -d "@$EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || true)"
fi
[ -n "$TOUCH_STAMP" ] || { printf 'ERROR: cannot format epoch %s for touch\n' "$EPOCH" >&2; exit 1; }
find "$BASE_DIR" -exec touch -t "$TOUCH_STAMP" {} +

printf '== packaging %s ==\n' "$ASSET"
# gzip -n keeps the timestamp out of the gzip header; without it two runs
# produce different bytes even with identical content.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
	TAR_ARGS="--sort=name --owner=0 --group=0 --numeric-owner --format=ustar --mtime=@$EPOCH"
	# shellcheck disable=SC2086
	tar $TAR_ARGS -c -C "$OUT_DIR" "$BASE_NAME" | gzip -n -9 > "$ASSET"
else
	# bsdtar: normalise ownership and feed a sorted file list so the archive
	# layout does not depend on directory readdir order.
	(
		cd "$OUT_DIR"
		find "$BASE_NAME" -print | LC_ALL=C sort \
			| tar --no-recursion --format=ustar --uid 0 --gid 0 --uname root --gname root \
				-c -T - | gzip -n -9 > "$(basename "$ASSET")"
	)
fi

sha256_of "$ASSET" > "$ASSET.sha256"

# Content hash: independent of tar metadata, so CI can tell whether the rule
# data actually changed between two builds.
{
	for name in adguard-hostlist.txt anti-ad-domains.txt \
		adrules-domains.txt neodevhost-domains.txt cn-domains.txt; do
		printf '%s  %s\n' "$(sha256_of "$BASE_DIR/$name")" "$name"
	done
} | LC_ALL=C sort | sha256_stdin > "$OUT_DIR/CONTENT-SHA256"

printf '\nasset:  %s\nsha256: %s\n' "$ASSET" "$(cat "$ASSET.sha256")"
