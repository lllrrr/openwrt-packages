#!/bin/sh

set -eu

node -e "const fs=require('fs'),d='htdocs/luci-static/resources/view/oxidns'; for (const f of fs.readdirSync(d).filter(x=>x.endsWith('.js')).map(x=>d+'/'+x).concat(fs.readdirSync(d+'/parts').filter(x=>x.endsWith('.js')).map(x=>d+'/parts/'+x))) new Function(fs.readFileSync(f,'utf8'));"
node -e "for (const f of ['root/usr/share/luci/menu.d/luci-app-oxidns.json','root/usr/share/rpcd/acl.d/luci-app-oxidns.json','root/usr/share/oxidns/targets.json']) JSON.parse(require('fs').readFileSync(f,'utf8'));"
node <<'NODE'
const fs = require('fs');

const required = new Set();
for (const file of [
	'htdocs/luci-static/resources/view/oxidns/overview.js',
	'htdocs/luci-static/resources/view/oxidns/config.js',
	'htdocs/luci-static/resources/view/oxidns/data.js',
	'htdocs/luci-static/resources/view/oxidns/logs.js',
	'htdocs/luci-static/resources/view/oxidns/parts/overview.js',
	'htdocs/luci-static/resources/view/oxidns/parts/core.js',
	'htdocs/luci-static/resources/view/oxidns/parts/config.js',
	'htdocs/luci-static/resources/view/oxidns/parts/settings.js',
	'htdocs/luci-static/resources/view/oxidns/parts/rules.js',
	'htdocs/luci-static/resources/view/oxidns/parts/prewarm.js',
	'htdocs/luci-static/resources/view/oxidns/parts/hijack.js',
	'htdocs/luci-static/resources/view/oxidns/parts/geo.js',
]) {
	const source = fs.readFileSync(file, 'utf8');
	const re = /_\(\s*(['"])((?:\\.|[^\\])*?)\1\s*\)/g;
	let match;
	while ((match = re.exec(source)))
		required.add(Function(`return ${match[1]}${match[2]}${match[1]}`)());
}

const menu = JSON.parse(fs.readFileSync('root/usr/share/luci/menu.d/luci-app-oxidns.json', 'utf8'));
// LuCI looks menu titles up in the same catalogue. A gap silently falls back
// to English in a Chinese UI, so titles are part of the hard requirement.
for (const entry of Object.values(menu)) {
	if (entry.title)
		required.add(entry.title);
}
const viewPaths = Object.keys(menu).filter(k => k !== 'admin/services/oxidns');
if (viewPaths.length !== 4)
	throw new Error(`expected 4 consolidated views, found ${viewPaths.length}: ${viewPaths.join(', ')}`);

function poIds(file) {
	const ids = new Set();
	const content = fs.readFileSync(file, 'utf8');
	const re = /^msgid "((?:\\.|[^"\\])*)"$/mg;
	let match;
	while ((match = re.exec(content))) {
		const id = JSON.parse(`"${match[1]}"`);
		if (id)
			ids.add(id);
	}
	return ids;
}

const pot = poIds('po/templates/oxidns.pot');
const zh = poIds('po/zh_Hans/oxidns.po');
const failures = [];
for (const [label, ids] of [['POT', pot], ['zh_Hans PO', zh]]) {
	for (const id of [...required].sort()) {
		if (!ids.has(id))
			failures.push(`${label} missing msgid: ${id}`);
	}
}
for (const id of [...pot].sort()) {
	if (!required.has(id))
		failures.push(`POT stale msgid: ${id}`);
}
if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}
NODE
for script in scripts/po2lmo.mjs scripts/strip-tar-eof.mjs scripts/write-apk-data-tar.mjs scripts/write-ar-archive.mjs; do
	node --check "$script"
done
node scripts/po2lmo.mjs po/zh_Hans/oxidns.po "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
test -s "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
rm -f "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
if command -v msgfmt >/dev/null 2>&1; then
	msgfmt --check po/zh_Hans/oxidns.po -o /dev/null
fi
sh -n root/usr/libexec/rpcd/luci.oxidns
sh -n root/etc/init.d/oxidns
# [CodeMirror] the YAML config panel must use the cmeditor wrapper and the
# assets must ship. The panel now lives under parts/ so the consolidated
# Configuration tab can embed it.
grep -q 'view.oxidns.cmeditor' htdocs/luci-static/resources/view/oxidns/parts/config.js
grep -q 'cmeditor.defer' htdocs/luci-static/resources/view/oxidns/parts/config.js
test -s htdocs/luci-static/resources/view/oxidns/cmeditor.js
test -s htdocs/luci-static/resources/oxidns-codemirror/codemirror.min.js
test -s htdocs/luci-static/resources/oxidns-codemirror/yaml.min.js
test -s htdocs/luci-static/resources/oxidns-codemirror/codemirror.min.css
test -s htdocs/luci-static/resources/oxidns-codemirror/cmtheme.css

# [API credentials] UCI only keeps the legacy fallback; the root-only file is
# the source of truth. Both callers of `oxidns check/start` must export the
# credentials: init.d for procd, rpcd for config validate/save and core install.
grep -q "option api_pass" root/etc/config/oxidns
test -s root/usr/libexec/oxidns-auth
sh -n root/usr/libexec/oxidns-auth
grep -q 'load_api_credentials' root/etc/init.d/oxidns
grep -q 'load_api_credentials' root/usr/libexec/rpcd/luci.oxidns
grep -q 'procd_set_param env OXIDNS_API_USER=' root/etc/init.d/oxidns
grep -q 'procd_set_param env OXIDNS_API_PASS=' root/etc/init.d/oxidns
grep -q 'export OXIDNS_API_USER' root/usr/libexec/rpcd/luci.oxidns
grep -q 'export OXIDNS_API_PASS' root/usr/libexec/rpcd/luci.oxidns
grep -q 'uci -q delete "$UCI_PACKAGE.$UCI_SECTION.api_pass"' root/usr/libexec/rpcd/luci.oxidns
grep -q 'api-credentials' htdocs/luci-static/resources/view/oxidns/parts/settings.js
grep -q '"credentials_status"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q '"credentials_set"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
# [Upstream probe] keep parser, RPC, ACL and both UI entry points wired.
grep -q 'config_upstreams' root/usr/libexec/rpcd/luci.oxidns
grep -q ',"ttl":' root/usr/libexec/rpcd/luci.oxidns
grep -q '"upstream_probe"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q 'upstream-probe' htdocs/luci-static/resources/view/oxidns/logs.js
grep -q 'upstream-probe' htdocs/luci-static/resources/view/oxidns/parts/overview.js
if grep -q 'credentials_set.*api_pass' root/usr/libexec/rpcd/luci.oxidns; then
	echo "credentials_set must never write the password back into UCI" >&2
	exit 1
fi
# [prewarm] Keep the LuCI panel, ACL endpoint, helper script and default list
# wired together. The panel is now the third tab of the Configuration view.
grep -q 'parts.prewarm' htdocs/luci-static/resources/view/oxidns/config.js
test -s htdocs/luci-static/resources/view/oxidns/parts/prewarm.js
grep -q '"prewarm_read"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q '"prewarm_save"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q '"prewarm_run"' root/usr/share/rpcd/acl.d/luci-app-oxidns.json
grep -q 'config prewarm' root/etc/config/oxidns
# Section IDs must be unique. `config prewarm 'main'` collides with the
# `settings 'main'` section, so `uci get oxidns.main.api_pass` returns the
# prewarm section and ${OXIDNS_API_PASS} expansion fails in the UI check.
grep -q "^config prewarm 'prewarm'" root/etc/config/oxidns
if grep -q "^config prewarm 'main'" root/etc/config/oxidns; then
	echo "prewarm section ID must not be 'main' (collides with settings main)" >&2
	exit 1
fi
# Legacy releases shipped `config prewarm 'main'`, which collided with
# `config settings 'main'` and hid api_pass. The shipped config uses a distinct
# section ID, and the init script migrates persisted bad configs on service
# start -- the only path allowed to rewrite /etc/config/oxidns. rpcd read paths
# must stay read-only, so rpcd no longer heals; it just reads the corrected
# section.
grep -q 'heal_prewarm_section_id' root/etc/init.d/oxidns
if ! awk '/^start_service\(\) \{/{f=1} f{print} f&&/^}/{exit}' \
	root/etc/init.d/oxidns | grep -q 'heal_prewarm_section_id'; then
	echo "start_service() must call heal_prewarm_section_id" >&2
	exit 1
fi
# Regression guard: rpcd's prewarm reader must use the corrected section ID,
# not the legacy 'main' one that shadowed the settings section.
if ! awk '/^load_prewarm_settings\(\) \{/{f=1} f{print} f&&/^}/{exit}' \
	root/usr/libexec/rpcd/luci.oxidns | grep -q 'oxidns\.prewarm\.'; then
	echo "load_prewarm_settings() must read the oxidns.prewarm.* section" >&2
	exit 1
fi
test -s root/usr/share/oxidns/prewarm.default.txt
test -x root/usr/libexec/oxidns-prewarm
sh -n root/usr/libexec/oxidns-prewarm
# BusyBox xargs has no -P; the prewarmer must use shell background jobs.
# `xargs -P ... || true` used to fail silently on stock OpenWrt and warm zero
# domains while still logging "refreshed N queries".
if grep -q 'xargs .*-P' root/usr/libexec/oxidns-prewarm; then
	echo "prewarmer must not use xargs -P (unavailable in BusyBox)" >&2
	exit 1
fi
grep -q 'wait' root/usr/libexec/oxidns-prewarm
sh -n scripts/build-luci-package.sh
sh -n scripts/integration-check.sh
sh -n scripts/service-check.sh
sh -n scripts/release-check.sh
sh -n scripts/build-rules-baseline.sh
sh -n oxidns-rules-baseline/files/90-oxidns-rules

# [cache lookup removed] Keep the page and its RPC surface gone. A stale menu
# entry or ACL method would leave a dead view in LuCI, so fail if any of them
# ever comes back.
if grep -rqi 'cache.js\|Cache Lookup\|cache_suggest\|cache_detail\|probe_upstreams\|zone_info\|trace_route' \
	htdocs root 2>/dev/null; then
	echo "Cache Lookup page artifacts are still present" >&2
	exit 1
fi

# jsonfilter rejects "@.[*]" (dot before the bracket): it exits non-zero and
# prints nothing, which is indistinguishable from an empty result and once
# surfaced as a bogus "no release" error. Only the "@[*].field" form is valid.
if grep -v '^[[:space:]]*#' root/usr/libexec/rpcd/luci.oxidns | grep -q '@\.\['; then
	echo "invalid jsonfilter expression in luci.oxidns: use @[*].field, not @.[*].field" >&2
	exit 1
fi

# Package/xxx/install gets $(1) = $(PKG_BUILD_DIR)/ipkg-<arch>/<pkg>, i.e. a
# directory *inside* the build directory. Copying "$(PKG_BUILD_DIR)/." into it
# makes cp fail with "cannot copy a directory ... into itself", so install from
# a subdirectory instead (this repo uses $(PKG_BUILD_DIR)/src).
self_copy="$(grep -rnF --include=Makefile '$(PKG_BUILD_DIR)/.' . 2>/dev/null \
	| grep -v ': *#' || true)"
if [ -n "$self_copy" ]; then
	echo 'Makefile copies $(PKG_BUILD_DIR)/. into the package dir: use a subdirectory such as $(PKG_BUILD_DIR)/src' >&2
	echo "$self_copy" >&2
	exit 1
fi

# [r13] v12 config and r13 package removed the hand-maintained force_cn /
# force_abroad split lists, their baseline files, and every seeding path.
# Guard against accidental reintroduction (scripts/ itself is excluded
# because this assertion necessarily mentions the names).
if grep -rqi 'force-cn\|force-abroad\|force_cn\|force_abroad' \
	oxidns-rules-baseline root htdocs 2>/dev/null; then
	echo "force split lists must stay removed (r13)" >&2
	exit 1
fi

# [r16] Only the five rule lists actually loaded by OxiDNS are shipped and
# validated. The two redundant files must not reappear in the baseline or in
# any seeding path (scripts/ is excluded: the build script still needs the
# dnsmasq-china-list source to convert into cn-domains.txt).
if grep -rqi 'adguard-antiad\.txt\|accelerated-domains\.china\.conf' \
	oxidns-rules-baseline root htdocs 2>/dev/null; then
	echo "redundant rule files must stay out of the baseline (r16)" >&2
	exit 1
fi

# All rule files shipped by the baseline must come from the release archive
# overlay; there is no longer a local files/rules overlay to install.
if grep -q './files/rules' oxidns-rules-baseline/Makefile; then
	echo "baseline Makefile still installs a local files/rules overlay" >&2
	exit 1
fi

# [r17] DNS hijack, CodeMirror editor and Geo data must stay wired:
# consolidated tabs + ACL methods + rpcd emitters + frontend panels. A missing
# piece leaves a dead tab or a page whose buttons all fail.
grep -q 'parts.hijack' htdocs/luci-static/resources/view/oxidns/overview.js
grep -q 'parts.geo' htdocs/luci-static/resources/view/oxidns/data.js
test -s htdocs/luci-static/resources/view/oxidns/parts/hijack.js
test -s htdocs/luci-static/resources/view/oxidns/parts/geo.js
for method in hijack_get hijack_save geo_get geo_save geo_reset geo_download geo_progress; do
	grep -q "\"$method\"" root/usr/share/rpcd/acl.d/luci-app-oxidns.json
	grep -q "$method)" root/usr/libexec/rpcd/luci.oxidns
done
for view in hijack geo core rules; do
	test -s "htdocs/luci-static/resources/view/oxidns/parts/$view.js"
done
# Geo defaults must stay on the self-maintained rules source, not upstream's.
grep -q 'NetForgeCN/v2ray-rules-dat' root/usr/libexec/rpcd/luci.oxidns
if grep -q 'Loyalsoldier/v2ray-rules-dat@release' root/usr/libexec/rpcd/luci.oxidns; then
	echo "geo default must not fall back to upstream Loyalsoldier release" >&2
	exit 1
fi

# [versions] Makefile, README examples and release workflow must agree. A
# stale example is how users end up building a package whose version does not
# match the Makefile metadata.
ROOT_VERSION="$(sed -n 's/^PKG_VERSION:=//p' Makefile | head -n 1)"
ROOT_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' Makefile | head -n 1)"
RULES_VERSION="$(sed -n 's/^PKG_VERSION:=//p' oxidns-rules-baseline/Makefile | head -n 1)"
RULES_HASH="$(sed -n 's/^PKG_HASH:=//p' oxidns-rules-baseline/Makefile | head -n 1)"
[ -n "$ROOT_VERSION" ] && [ -n "$ROOT_RELEASE" ] || {
	echo "cannot read PKG_VERSION/PKG_RELEASE from Makefile" >&2
	exit 1
}
[ -n "$RULES_VERSION" ] && printf '%s\n' "$RULES_HASH" | grep -Eq '^[0-9a-f]{64}$' || {
	echo "rules baseline PKG_VERSION/PKG_HASH missing or not a SHA256" >&2
	exit 1
}
root_version_re="$(printf '%s' "$ROOT_VERSION" | sed 's/\./\\./g')"
for readme in README.md README.en.md; do
	grep -Eq "build-luci-package\.sh[[:space:]]+${root_version_re}([[:space:]]|$)" "$readme" || {
		echo "$readme quick-packaging example must use PKG_VERSION=$ROOT_VERSION" >&2
		exit 1
	}
	grep -q 'sha256sum -c' "$readme" || {
		echo "$readme must show checksum-verified downloads" >&2
		exit 1
	}
done
grep -q "rules-v\$(PKG_VERSION)" oxidns-rules-baseline/Makefile || {
	echo "rules baseline PKG_SOURCE_URL must use rules-v\$(PKG_VERSION)" >&2
	exit 1
}
# The workflow summary prints the values a maintainer must copy into the
# Makefile; fail if those labels drift.
grep -q 'PKG_VERSION:=\${VERSION}' .github/workflows/rules-release.yml || {
	echo "rules-release.yml summary must print PKG_VERSION:=\${VERSION}" >&2
	exit 1
}
grep -q 'PKG_HASH:=' .github/workflows/rules-release.yml || {
	echo "rules-release.yml summary must print PKG_HASH" >&2
	exit 1
}
grep -q 'rules-v\${VERSION}' .github/workflows/rules-release.yml || {
	echo "rules-release.yml must publish rules-v\${VERSION} tags" >&2
	exit 1
}

# [workflow hardening] every action must be pinned to a full 40-hex SHA with a
# trailing '# vX' comment, every job must declare a timeout, and the default
# GITHUB_TOKEN must be read-only (write scopes are granted per publish job).
for workflow in .github/workflows/*.yml; do
	if grep -E '^[[:space:]]+uses: ' "$workflow" | grep -vE '@[0-9a-f]{40} # v[0-9]+$'; then
		echo "$workflow has an unpinned action (need a full SHA + '# vX' comment)" >&2
		exit 1
	fi
	jobs_count="$(awk '/^jobs:$/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{c++} END{print c+0}' "$workflow")"
	timeouts_count="$(grep -Ec '^    timeout-minutes:' "$workflow")"
	[ "$jobs_count" -eq "$timeouts_count" ] || {
		echo "$workflow: $jobs_count jobs but $timeouts_count timeout-minutes" >&2
		exit 1
	}
	grep -q '^permissions:$' "$workflow" || {
		echo "$workflow missing top-level permissions" >&2
		exit 1
	}
done

# [licenses] core carries the upstream license, rules use a valid SPDX
# expression, and the vendored CodeMirror MIT license ships in metadata.
grep -q '^PKG_LICENSE_FILES:=LICENSE' oxidns-core/Makefile || {
	echo "oxidns-core/Makefile must declare PKG_LICENSE_FILES for upstream LICENSE" >&2
	exit 1
}
grep -q '^PKG_LICENSE:=GPL-3.0-or-later AND MIT AND 0BSD AND WTFPL$' oxidns-rules-baseline/Makefile || {
	echo "rules baseline PKG_LICENSE must be the full SPDX expression" >&2
	exit 1
}
grep -q 'oxidns-codemirror/LICENSE' Makefile || {
	echo "root Makefile must declare the vendored CodeMirror MIT license" >&2
	exit 1
}

# [targets] Buildroot mapping and runtime targets.json must not drift; the
# Makefile's TARGET MAP comment is the cross-check source.
node <<'NODE'
const fs = require('fs');
const mk = fs.readFileSync('oxidns-core/Makefile', 'utf8');
const data = JSON.parse(fs.readFileSync('root/usr/share/oxidns/targets.json', 'utf8'));
const known = new Set(data.targets.map((t) => t.rust_target));
const rows = [...mk.matchAll(/^#\s+(x86_64|aarch64|i386|arm \([^)]*\))\s+->\s+(\S+)/gm)];
if (rows.length !== 5)
	throw new Error(`oxidns-core TARGET MAP has ${rows.length} rows, expected 5`);
for (const [, arch, target] of rows) {
	if (!known.has(target))
		throw new Error(`Makefile mapping ${arch} -> ${target} missing from targets.json`);
}
if (!mk.includes('CONFIG_SOFTFLOAT'))
	throw new Error('soft-float ARM must be excluded from the hard-float core build');

// package.mk calls Download/default whenever PKG_SOURCE_URL is non-empty,
// but FILE comes from PKG_SOURCE which is only set for a recognised ARCH.
// An unconditional URL breaks feed index generation (ARCH is undefined then).
const guard = mk.match(/ifneq \(\$\(OXIDNS_PKG_HASH\),skip\)([\s\S]*?)^endif/m);
if (!guard || !/PKG_SOURCE_URL:=/.test(guard[1]))
	throw new Error('PKG_SOURCE_URL must be inside the OXIDNS_PKG_HASH guard');
if (/^PKG_SOURCE_URL:=/m.test(mk.replace(guard[0], '')))
	throw new Error('PKG_SOURCE_URL must not be declared outside the OXIDNS_PKG_HASH guard');
NODE

# [poll] LuCI poll.start() runs step() immediately on add(). A refresh callback
# that unregisters itself while detach-checking kills the loop before the view
# is ever inserted; registration must also wait for the post-mount setTimeout.
node <<'NODE'
const fs = require('fs');
for (const name of ['logs', 'parts/hijack', 'parts/overview']) {
	const p = `htdocs/luci-static/resources/view/oxidns/${name}.js`;
	const t = fs.readFileSync(p, 'utf8');
	if (/if \(!isAttached\(viewRoot\)\) \{\s*\n\s*unregisterPoll\(\);/.test(t))
		throw new Error(`${name}.js: refresh must not unregisterPoll() while detached`);
	const addIdx = t.search(/^\s*poll\.add\(/m);
	const timeoutIdx = t.lastIndexOf('window.setTimeout(function()', addIdx);
	if (addIdx < 0 || timeoutIdx < 0 || !t.slice(timeoutIdx, addIdx).includes('isAttached(viewRoot)'))
		throw new Error(`${name}.js: poll.add() must be inside the post-mount setTimeout`);
}
NODE

# [build-rules] Negative fixtures for the validators. These must fail on
# malformed input; a validator that accepts everything is worse than none.
(
	eval "$(sed -n '/^validate_domain_set() {/,/^}/p' scripts/build-rules-baseline.sh)"
	eval "$(sed -n '/^validate_plain_list() {/,/^}/p' scripts/build-rules-baseline.sh)"
	eval "$(sed -n '/^validate_adguard_list() {/,/^}/p' scripts/build-rules-baseline.sh)"
	fixtures="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-validator-fixtures.XXXXXX")"
	trap 'rm -rf "$fixtures"' EXIT
	printf 'good.example.com\n' > "$fixtures/domain-ok.txt"
	printf 'this is not a domain\n' > "$fixtures/domain-bad.txt"
	printf '<html><body>error</body></html>\n' > "$fixtures/plain-bad.txt"
	printf '||example.com^\n' > "$fixtures/adguard-ok.txt"
	printf '<html><body>error</body></html>\n' > "$fixtures/adguard-bad.txt"
	validate_domain_set "$fixtures/domain-ok.txt" 1
	validate_plain_list "$fixtures/domain-ok.txt" 1
	validate_adguard_list "$fixtures/adguard-ok.txt" 1
	if validate_domain_set "$fixtures/domain-bad.txt" 1; then
		echo "validate_domain_set accepted a malformed line" >&2
		exit 1
	fi
	if validate_plain_list "$fixtures/plain-bad.txt" 1; then
		echo "validate_plain_list accepted an HTML error page" >&2
		exit 1
	fi
	if validate_adguard_list "$fixtures/adguard-bad.txt" 1; then
		echo "validate_adguard_list accepted an HTML error page" >&2
		exit 1
	fi
)

# [reproducibility] Two offline builds from identical fixture data must
# produce byte-identical tarballs. curl is stubbed from PATH so this needs no
# network access and cannot be affected by upstream list churn.
(
	repro_dir="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-rules-repro.XXXXXX")"
	trap 'rm -rf "$repro_dir"' EXIT
	mkdir -p "$repro_dir/bin" "$repro_dir/fixtures"
	awk 'BEGIN { for (i = 0; i < 50000; i++) print "||example.com^" }' > "$repro_dir/fixtures/filter_1.txt"
	awk 'BEGIN { for (i = 0; i < 50000; i++) print "example.com" }' > "$repro_dir/fixtures/anti-ad-domains.txt"
	awk 'BEGIN { for (i = 0; i < 100000; i++) print "example.com" }' > "$repro_dir/fixtures/mosdns_adrules.txt"
	cp "$repro_dir/fixtures/mosdns_adrules.txt" "$repro_dir/fixtures/domain"
	awk 'BEGIN { for (i = 0; i < 50000; i++) printf "server=/example%d.com/127.0.0.1#53\n", i }' > "$repro_dir/fixtures/accelerated-domains.china.conf"
	cat > "$repro_dir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--proto|--proto-redir|--max-redirs|--retry|--max-time) shift 2 ;;
		--*) shift ;;
		*) url="$1"; shift ;;
	esac
done
case "$url" in
	*filter_1.txt) name=filter_1.txt ;;
	*anti-ad-domains.txt) name=anti-ad-domains.txt ;;
	*mosdns_adrules.txt) name=mosdns_adrules.txt ;;
	*/domain) name=domain ;;
	*accelerated-domains.china.conf) name=accelerated-domains.china.conf ;;
	*) echo "unexpected URL: $url" >&2; exit 1 ;;
esac
cp "${FIXTURE_DIR:?}/$name" "$out"
EOF
	chmod 755 "$repro_dir/bin/curl"
	PATH="$repro_dir/bin:$PATH" FIXTURE_DIR="$repro_dir/fixtures" \
		OUT_DIR="$repro_dir/out1" SOURCE_DATE_EPOCH=1767225600 \
		scripts/build-rules-baseline.sh 2026.01.01 >/dev/null
	PATH="$repro_dir/bin:$PATH" FIXTURE_DIR="$repro_dir/fixtures" \
		OUT_DIR="$repro_dir/out2" SOURCE_DATE_EPOCH=1767225600 \
		scripts/build-rules-baseline.sh 2026.01.01 >/dev/null
	cmp "$repro_dir/out1/oxidns-rules-baseline-2026.01.01.tar.gz.sha256" \
		"$repro_dir/out2/oxidns-rules-baseline-2026.01.01.tar.gz.sha256" || {
		echo "rules baseline rebuild is not reproducible" >&2
		exit 1
	}
	cmp "$repro_dir/out1/CONTENT-SHA256" "$repro_dir/out2/CONTENT-SHA256"
)

# [cross-agent contracts] Guards for fixes owned by other agents. Patterns
# are deliberately tolerant of quoting/formatting changes.
settings_save_emissions="$(grep -c '"settings_save":{' root/usr/libexec/rpcd/luci.oxidns || true)"
if [ "${settings_save_emissions:-0}" -gt 1 ]; then
	echo "rpcd list emits settings_save more than once" >&2
	exit 1
fi
if ! awk '/^valid_upload_path\(\) \{/{f=1} f{print} f&&/^}/{exit}' \
	root/usr/libexec/rpcd/luci.oxidns | grep -Eq '(\.\.|path_has_parent_ref)'; then
	echo "valid_upload_path must reject parent directory references" >&2
	exit 1
fi
if ! grep -q 'mktemp' root/usr/libexec/oxidns-prewarm; then
	echo "prewarmer must use mktemp for its temporary files" >&2
	exit 1
fi
if ! awk '/^valid_geo_url\(\) \{/{f=1} f{print} f&&/^}/{exit}' \
	root/usr/libexec/rpcd/luci.oxidns | grep -Eq '127\.|10\.|192\.168|169\.254|localhost|private'; then
	echo "geo URL validation must reject private/loopback addresses" >&2
	exit 1
fi
grep -q 'run_with_core_lock' root/usr/libexec/rpcd/luci.oxidns || {
	echo "core/rules write paths must hold the shared lock" >&2
	exit 1
}
grep -q 'geo_running' root/usr/libexec/rpcd/luci.oxidns || {
	echo "geo write path needs a busy marker" >&2
	exit 1
}
grep -q 'rollback' root/usr/libexec/rpcd/luci.oxidns || {
	echo "write paths need a rollback path on failure" >&2
	exit 1
}
