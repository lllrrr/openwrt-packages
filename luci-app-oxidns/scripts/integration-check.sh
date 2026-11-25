#!/bin/sh

set -eu

json_ok() {
	node -e "const v=JSON.parse(require('fs').readFileSync(0,'utf8')); if (!($1)) process.exit(1);"
}

tar_has_member() {
	tar -tzf "$1" | awk -v member="$2" '
		{
			path = $0;
			sub(/^\.\//, "", path);
			sub(/\/$/, "", path);
			if (path == member)
				found = 1;
		}
		END { exit found ? 0 : 1 }
	'
}

tar_member_contains() {
	tar -xOzf "$1" "$2" 2>/dev/null | grep -q "$3"
}

apk_data_has_checksum() {
	gzip -dc "$1" | grep -q 'APK-TOOLS.checksum.SHA1='
}

tar_nested_has_member() {
	outer="$1"
	inner="$2"
	member="$3"
	nested="$(mktemp "${TMPDIR:-/tmp}/luci-app-oxidns-nested.XXXXXX")"
	if ! tar -xOf "$outer" "$inner" > "$nested" 2>/dev/null &&
		! tar -xOf "$outer" "./$inner" > "$nested" 2>/dev/null; then
		rm -f "$nested"
		return 1
	fi

	if tar -tzf "$nested" | awk -v member="$member" '
		{
			path = $0;
			sub(/^\.\//, "", path);
			if (path == member)
				found = 1;
		}
		END { exit found ? 0 : 1 }
	'; then
		rm -f "$nested"
		return 0
	fi

	rm -f "$nested"
	return 1
}

# ipk is an ar archive (debian-binary + control.tar.gz + data.tar.gz).
ar_has_member() {
	ar t "$1" | grep -qx "$2"
}

ar_member_contains() {
	ar p "$1" "$2" | tar -xOzf - "$3" 2>/dev/null | grep -q "$4"
}

ar_nested_has_member() {
	ar p "$1" "$2" | tar -tzf - 2>/dev/null | awk -v member="$3" '
		{
			path = $0;
			sub(/^\.\//, "", path);
			sub(/\/$/, "", path);
			if (path == member)
				found = 1;
		}
		END { exit found ? 0 : 1 }
	'
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

# Core uploads are default-deny. These tests must reach the path/archive
# validators, so opt in with a scoped UCI stub (no real device state).
UPLOAD_ENABLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-upload-enable.XXXXXX")"
cat > "$UPLOAD_ENABLE_DIR/uci" <<'EOF'
#!/bin/sh
set -eu
if [ "$*" = "-q get oxidns.main.allow_core_upload" ]; then
	printf '1\n'
	exit 0
fi
exit 1
EOF
chmod 755 "$UPLOAD_ENABLE_DIR/uci"

assert_unsafe_upload_rejected() {
	upload="$1"
	printf '{"path":"%s"}' "$upload" |
		PATH="$UPLOAD_ENABLE_DIR:$PATH" root/usr/libexec/rpcd/luci.oxidns call core_upload_install |
		json_ok "v.ok === false && v.code === 'uploaded_archive_unsafe'"
}

INIT_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-init-stub.XXXXXX")"
printf '#!/bin/sh\nsleep 30\n' > "$INIT_STUB_DIR/oxidns"
: > "$INIT_STUB_DIR/config.yaml"
chmod 755 "$INIT_STUB_DIR/oxidns"
# The init script now refuses to start without the five baseline rule files.
# Provide a local fixture tree so this test exercises log destination wiring
# rather than the optional baseline package.
mkdir -p "$INIT_STUB_DIR/rules-baseline"
for RULE_FIXTURE in adguard-hostlist.txt anti-ad-domains.txt adrules-domains.txt \
	neodevhost-domains.txt cn-domains.txt; do
	printf 'example.com\n' > "$INIT_STUB_DIR/rules-baseline/$RULE_FIXTURE"
done
printf 'fixture\n' > "$INIT_STUB_DIR/rules-baseline/VERSION"
# Drive start_service from the real init script and record the procd params it sets.
printf '%s\n' \
	'set -eu' \
	'PROCD_ARGS="'"$INIT_STUB_DIR"'/procd-args"' \
	'config_load() { :; }' \
	'config_get() { case "$1" in CONFIG_PATH) CONFIG_PATH="'"$INIT_STUB_DIR"'/config.yaml" ;; WORKING_DIR) WORKING_DIR="'"$INIT_STUB_DIR"'" ;; esac; }' \
	'config_get_bool() { eval "$1=\$FAKE_UCI_VALUE"; }' \
	'RULES_DIR="'"$INIT_STUB_DIR"'/rules"' \
	'RULES_BASELINE_DIR="'"$INIT_STUB_DIR"'/rules-baseline"' \
	'PREWARM_DIR="'"$INIT_STUB_DIR"'/prewarm"' \
	'PREWARM_FILE="'"$INIT_STUB_DIR"'/prewarm/prewarm.txt"' \
	'PREWARM_DEFAULT_FILE="'"$PWD"'/root/usr/share/oxidns/prewarm.default.txt"' \
	'procd_open_instance() { :; }' \
	'procd_close_instance() { :; }' \
	'procd_set_param() { printf "%s\n" "$*" >> "$PROCD_ARGS"; }' \
	'. "'"$PWD"'/root/etc/init.d/oxidns"' \
	'PROG="'"$INIT_STUB_DIR"'/oxidns"' \
	'start_service' > "$INIT_STUB_DIR/drive.sh"
INIT_STUB_ARGS="$INIT_STUB_DIR/procd-args"
init_log_destination_args() {
	: > "$INIT_STUB_ARGS"
	FAKE_UCI_VALUE="$1" /bin/sh "$INIT_STUB_DIR/drive.sh"
}
init_log_destination_args 1
grep -qx 'stdout 1' "$INIT_STUB_ARGS"
grep -qx 'stderr 1' "$INIT_STUB_ARGS"
init_log_destination_args 0
grep -qx 'stdout 0' "$INIT_STUB_ARGS"
grep -qx 'stderr 0' "$INIT_STUB_ARGS"
rm -rf "$INIT_STUB_DIR"

scripts/check.sh
scripts/service-check.sh

root/usr/libexec/rpcd/luci.oxidns list | json_ok "'status' in v && 'core_install' in v && 'core_reinstall' in v && 'core_upload_install' in v && 'core_progress' in v && 'core_remove' in v && 'logs_recent' in v && 'settings_read' in v && 'prewarm_read' in v && 'prewarm_save' in v && 'prewarm_run' in v && !('config_basic_read' in v) && !('config_basic_save' in v)"
root/usr/libexec/rpcd/luci.oxidns call status | json_ok "v.ok === true && v.core && v.core.installed === false && v.webui && v.webui.installed === false && typeof v.webui.url === 'string' && typeof v.webui.local_only === 'boolean' && typeof v.webui.wildcard === 'boolean' && !('api' in v) && !('api_base_url' in v) && !('package' in v) && !('package_manager' in v)"
TARGET_FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-target-fake-bin.XXXXXX")"
TARGET_CASES="$(mktemp "${TMPDIR:-/tmp}/oxidns-target-cases.XXXXXX")"
cat > "$TARGET_FAKE_BIN/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-m" ]; then
	printf '%s\n' "${FAKE_UNAME_M:?}"
	exit 0
fi
exec /usr/bin/uname "$@"
EOF
chmod 755 "$TARGET_FAKE_BIN/uname"
node -e "const data=JSON.parse(require('fs').readFileSync('root/usr/share/oxidns/targets.json','utf8')); for (const target of data.targets) for (const arch of target.uname_arches) console.log(arch + ' ' + target.rust_target);" > "$TARGET_CASES"
while read -r TARGET_ARCH TARGET_RUST; do
	PATH="$TARGET_FAKE_BIN:$PATH" FAKE_UNAME_M="$TARGET_ARCH" OXIDNS_TARGETS_FILE="$PWD/root/usr/share/oxidns/targets.json" \
		root/usr/libexec/rpcd/luci.oxidns call status |
		json_ok "v.ok === true && v.core && v.core.target === '$TARGET_RUST'"
done < "$TARGET_CASES"
rm -rf "$TARGET_FAKE_BIN"
rm -f "$TARGET_CASES"
root/usr/libexec/rpcd/luci.oxidns call core_progress | json_ok "v.ok === true && typeof v.text === 'string'"
root/usr/libexec/rpcd/luci.oxidns call core_reinstall | json_ok "v.ok === false && v.code === 'core_not_installed'"
printf '%s' '{"path":"/etc/passwd"}' | PATH="$UPLOAD_ENABLE_DIR:$PATH" root/usr/libexec/rpcd/luci.oxidns call core_upload_install | json_ok "v.ok === false && v.code === 'invalid_upload_path'"
LOCK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-lock-test.XXXXXX")"
mkdir -p "$LOCK_TEST_DIR/luci-oxidns/core-operation.lock"
printf '%s\n' "$$" > "$LOCK_TEST_DIR/luci-oxidns/core-operation.lock/pid"
TMPDIR="$LOCK_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_reinstall | json_ok "v.ok === false && v.code === 'core_operation_busy'"
rm -rf "$LOCK_TEST_DIR"
node -e "const acl=JSON.parse(require('fs').readFileSync('root/usr/share/rpcd/acl.d/luci-app-oxidns.json','utf8'))['luci-app-oxidns']; const read=acl.read.ubus['luci.oxidns']; const write=acl.write.ubus['luci.oxidns']; if (read.includes('config_validate') || !write.includes('config_validate')) process.exit(1);"
JSON_ESCAPED="$(printf '%s\n' 'listen: "127.0.0.1:9199"' | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "\\") printf "\\\\"; else if (c == "\"") printf "\\\""; else if (c == "\t") printf "\\t"; else if (c == "\r") printf "\\r"; else printf "%s", c; } }')"
test "$JSON_ESCAPED" = 'listen: \"127.0.0.1:9199\"'
PROGRESS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-progress-test.XXXXXX")"
printf 'original' > "$PROGRESS_TEST_DIR/target"
mkdir "$PROGRESS_TEST_DIR/luci-oxidns"
ln -s "$PROGRESS_TEST_DIR/target" "$PROGRESS_TEST_DIR/luci-oxidns/core-progress.log"
TMPDIR="$PROGRESS_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_reinstall >/dev/null 2>&1 || true
test "$(cat "$PROGRESS_TEST_DIR/target")" = "original"
rm -rf "$PROGRESS_TEST_DIR"
# The backend correctly rejects a symlinked parent directory. macOS makes
# /tmp a symlink, so the archive-shape negative cases cannot be exercised on
# this host; CI on Linux runs them. The invalid-path case above still runs.
if [ -L /tmp ]; then
	echo "skipping crafted upload archives: /tmp is a symlink on this host"
	rm -rf "$UPLOAD_ENABLE_DIR"
else
	UNSAFE_UPLOAD="$(mktemp "/tmp/oxidns-core-upload-unsafe.XXXXXX")"
	UNSAFE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-core-upload-unsafe-dir.XXXXXX")"
	rm -f "$UNSAFE_UPLOAD"
	ln -s /etc/passwd "$UNSAFE_DIR/oxidns"
	tar -czf "$UNSAFE_UPLOAD" -C "$UNSAFE_DIR" oxidns 2>/dev/null
	assert_unsafe_upload_rejected "$UNSAFE_UPLOAD"
	rm -f "$UNSAFE_UPLOAD" "$UNSAFE_DIR/oxidns"
	mkfifo "$UNSAFE_DIR/oxidns"
	tar -czf "$UNSAFE_UPLOAD" -C "$UNSAFE_DIR" oxidns 2>/dev/null
	assert_unsafe_upload_rejected "$UNSAFE_UPLOAD"
	rm -f "$UNSAFE_UPLOAD"
	rm -rf "$UNSAFE_DIR"
	rm -rf "$UPLOAD_ENABLE_DIR"
fi
printf '%s' '{"content":""}' | root/usr/libexec/rpcd/luci.oxidns call config_validate | json_ok "v.ok === false && v.code === 'missing_content'"
root/usr/libexec/rpcd/luci.oxidns call config_read | json_ok "v.ok === false && v.code === 'config_not_found'"
root/usr/libexec/rpcd/luci.oxidns call settings_read | json_ok "v.ok === true && v.log_syslog === true && v.core_repository === 'svenshi/oxidns' && v.core_bundle === 'full' && v.download_proxy === '' && v.github_token === '' && v.download_proxy_set === false && v.github_token_set === false && !('api_base_url' in v)"
FAKE_UCI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-fake-uci.XXXXXX")"
FAKE_UCI_STATE="$FAKE_UCI_DIR/state"
cat > "$FAKE_UCI_DIR/uci" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = "-q" ] && shift
CMD="${1:-}"
shift || true
STATE="${FAKE_UCI_STATE:?}"
case "$CMD" in
	get)
		KEY="${1:-}"
		[ -f "$STATE" ] || exit 1
		grep -F "$KEY=" "$STATE" | tail -n 1 | sed 's/^[^=]*=//' || exit 1
		;;
	set)
		ASSIGNMENT="${1:-}"
		KEY="${ASSIGNMENT%%=*}"
		VALUE="${ASSIGNMENT#*=}"
		TMP_STATE="$STATE.tmp"
		if [ -f "$STATE" ]; then
			grep -F -v "$KEY=" "$STATE" > "$TMP_STATE" || true
		else
			: > "$TMP_STATE"
		fi
		printf '%s=%s\n' "$KEY" "$VALUE" >> "$TMP_STATE"
		mv "$TMP_STATE" "$STATE"
		;;
	delete)
		KEY="${1:-}"
		TMP_STATE="$STATE.tmp"
		if [ -f "$STATE" ]; then
			grep -F -v "$KEY=" "$STATE" > "$TMP_STATE" || true
			mv "$TMP_STATE" "$STATE"
		fi
		;;
	commit)
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod 755 "$FAKE_UCI_DIR/uci"
	PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_read |
		json_ok "v.ok === true && v.log_syslog === true"
	for LOG_SYSLOG_TEST in 0 1 0; do
		printf '{"log_syslog":"%s"}' "$LOG_SYSLOG_TEST" |
			PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
			json_ok "v.ok === true && v.log_syslog === ($LOG_SYSLOG_TEST === 1)"
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_read |
			json_ok "v.ok === true && v.log_syslog === ($LOG_SYSLOG_TEST === 1)"
	done
	printf '%s' '{}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === true && v.log_syslog === false"
	printf '%s' '{"log_syslog":"invalid"}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === false && v.code === 'invalid_log_syslog'"
	PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_read |
		json_ok "v.ok === true && v.log_syslog === false"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"etc/oxidns/config.yaml","working_dir":"/var/lib/oxidns","download_proxy":"","github_token":""}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === false && v.code === 'invalid_config_path'"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"/etc/oxidns/config.yaml","working_dir":"/var","download_proxy":"","github_token":""}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === false && v.code === 'invalid_working_dir'"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"/etc/oxidns/config.yaml","working_dir":"/var/lib/oxidns","download_proxy":"","github_token":""}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === true && v.core_repository === 'svenshi/oxidns' && v.config_path === '/etc/oxidns/config.yaml' && v.working_dir === '/var/lib/oxidns' && v.download_proxy === '' && v.download_proxy_set === false"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"/etc/oxidns/config.yaml","working_dir":"/var/lib/oxidns","download_proxy":"http://user:pass@example.invalid:8080","github_token":"github-secret-token"}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === true && v.download_proxy === 'http://user:pass@example.invalid:8080' && v.github_token === '' && v.download_proxy_set === true && v.github_token_set === true && JSON.stringify(v).indexOf('github-secret-token') === -1"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"/etc/oxidns/config.yaml","working_dir":"/var/lib/oxidns","download_proxy":"","github_token":""}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === true && v.download_proxy_set === true && v.github_token === '' && v.github_token_set === true"
	printf '%s' '{"core_repository":"svenshi/oxidns","core_bundle":"full","config_path":"/etc/oxidns/config.yaml","working_dir":"/var/lib/oxidns","download_proxy":"","github_token":"","clear_download_proxy":"true","clear_github_token":"true"}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" root/usr/libexec/rpcd/luci.oxidns call settings_save |
		json_ok "v.ok === true && v.download_proxy === '' && v.download_proxy_set === false && v.github_token_set === false"
	cat > "$FAKE_UCI_STATE" <<'EOF'
oxidns.main.core_repository=svenshi/oxidns
oxidns.main.core_bundle=full
oxidns.main.config_path=/etc/oxidns/config.yaml
oxidns.main.working_dir=/var
oxidns.main.download_proxy=
oxidns.main.github_token=
EOF
	REMOVE_PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-remove-preflight.XXXXXX")"
	printf '%s' '{"remove_workdir":"true"}' |
		PATH="$FAKE_UCI_DIR:$PATH" FAKE_UCI_STATE="$FAKE_UCI_STATE" TMPDIR="$REMOVE_PREFLIGHT_DIR" root/usr/libexec/rpcd/luci.oxidns call core_remove |
		json_ok "v.ok === false && v.code === 'unsafe_working_dir'"
	test -f "$REMOVE_PREFLIGHT_DIR/luci-oxidns/core-progress.log"
	! grep -q 'rm -f /usr/bin/oxidns' "$REMOVE_PREFLIGHT_DIR/luci-oxidns/core-progress.log"
	! grep -q 'rm -rf /usr/share/oxidns/webui' "$REMOVE_PREFLIGHT_DIR/luci-oxidns/core-progress.log"
	rm -rf "$REMOVE_PREFLIGHT_DIR"
	rm -rf "$FAKE_UCI_DIR"
# logs_recent reads OpenWrt syslogs via `logread`. Provide a scoped stub so the
# test runs on hosts (macOS) without that command.
LOGREAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-logread-test.XXXXXX")"
cat > "$LOGREAD_DIR/logread" <<'EOF'
#!/bin/sh
printf '%s\n' 'Nov 25 12:00:00 router oxidns[1234]: integration test log line'
EOF
chmod 755 "$LOGREAD_DIR/logread"
printf '%s' '{"limit":"20"}' | PATH="$LOGREAD_DIR:$PATH" root/usr/libexec/rpcd/luci.oxidns call logs_recent | json_ok "v.ok === true && v.source === 'logread' && Array.isArray(v.lines) && !('entries' in v)"
rm -rf "$LOGREAD_DIR"
SERVICE_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-service-log-test.XXXXXX")"
# Records only the last argument, which is the message passed after `-t <tag>`.
cat > "$SERVICE_LOG_DIR/logger" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "$last" >> "$FAKE_LOGGER_OUT"
EOF
chmod 755 "$SERVICE_LOG_DIR/logger"
assert_service_event() {
	: > "$SERVICE_LOG_DIR/events.log"
	printf '%s' '{}' |
		PATH="$SERVICE_LOG_DIR:$PATH" FAKE_LOGGER_OUT="$SERVICE_LOG_DIR/events.log" \
		root/usr/libexec/rpcd/luci.oxidns call "service_$1" |
		json_ok "v.ok === false && v.code === '$2'"
	test "$(cat "$SERVICE_LOG_DIR/events.log")" = "$3"
}
assert_service_event start core_not_installed "service start ignored: OxiDNS core is not installed"
assert_service_event stop service_unavailable "service stop failed: init script not found: /etc/init.d/oxidns"
rm -rf "$SERVICE_LOG_DIR"

PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' Makefile | head -n 1)"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' Makefile | head -n 1)"
PKG_BASE="luci-app-oxidns_${PKG_VERSION}-r${PKG_RELEASE}_all"
I18N_BASE="luci-i18n-oxidns-zh-cn_${PKG_VERSION}-r${PKG_RELEASE}_all"

DIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-dist.XXXXXX")"
scripts/build-luci-package.sh "$PKG_VERSION" "$DIST_DIR" >/dev/null
ar_has_member "$DIST_DIR/${PKG_BASE}.ipk" debian-binary
ar_has_member "$DIST_DIR/${PKG_BASE}.ipk" control.tar.gz
ar_has_member "$DIST_DIR/${PKG_BASE}.ipk" data.tar.gz
ar_member_contains "$DIST_DIR/${PKG_BASE}.ipk" control.tar.gz postinst '#!/bin/sh'
ar_member_contains "$DIST_DIR/${PKG_BASE}.ipk" control.tar.gz postrm 'luci-indexcache'
ar_nested_has_member "$DIST_DIR/${PKG_BASE}.ipk" data.tar.gz etc/init.d/oxidns
# Uninstall must never recreate sysupgrade entries, unpack the bundle or links.
if ar p "$DIST_DIR/${PKG_BASE}.ipk" control.tar.gz | tar -xOzf - postrm | \
	grep -q 'sysupgrade.conf\|core-bundle\|oxidns/core/webui\|ln -s'; then
	echo "postrm must only clear caches and restart rpcd" >&2
	exit 1
fi
ar_has_member "$DIST_DIR/${I18N_BASE}.ipk" control.tar.gz
ar_has_member "$DIST_DIR/${I18N_BASE}.ipk" data.tar.gz
ar_member_contains "$DIST_DIR/${I18N_BASE}.ipk" control.tar.gz postinst '#!/bin/sh'
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" .PKGINFO
tar_member_contains "$DIST_DIR/${PKG_BASE}.apk" .PKGINFO '^arch = noarch$'
tar_member_contains "$DIST_DIR/${PKG_BASE}.apk" .PKGINFO '^datahash = [0-9a-f][0-9a-f]*$'
tar_member_contains "$DIST_DIR/${PKG_BASE}.apk" .PKGINFO "^pkgver = ${PKG_VERSION}-r${PKG_RELEASE}$"
apk_data_has_checksum "$DIST_DIR/${PKG_BASE}.apk"
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" etc
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" etc/config
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" usr/share/luci/menu.d
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" www/luci-static/resources/view/oxidns
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" usr/libexec/rpcd/luci.oxidns
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" etc/init.d/oxidns
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" .post-install
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" .post-upgrade
tar_has_member "$DIST_DIR/${PKG_BASE}.apk" .post-deinstall
tar_has_member "$DIST_DIR/${I18N_BASE}.apk" .PKGINFO
tar_member_contains "$DIST_DIR/${I18N_BASE}.apk" .PKGINFO '^arch = noarch$'
tar_member_contains "$DIST_DIR/${I18N_BASE}.apk" .PKGINFO '^datahash = [0-9a-f][0-9a-f]*$'
apk_data_has_checksum "$DIST_DIR/${I18N_BASE}.apk"
tar_has_member "$DIST_DIR/${I18N_BASE}.apk" usr/lib/lua/luci/i18n
tar_has_member "$DIST_DIR/${I18N_BASE}.apk" usr/lib/lua/luci/i18n/oxidns.zh-cn.lmo
tar_has_member "$DIST_DIR/${I18N_BASE}.apk" .post-install
tar_has_member "$DIST_DIR/${I18N_BASE}.apk" .post-upgrade

# [F3] Embedded core/rule archives: checksums are mandatory, safe archives are
# unpacked into the data tree, and malicious archives are refused.
EMBED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-embed.XXXXXX")"
mkdir -p "$EMBED_DIR/core" "$EMBED_DIR/rules/oxidns-rules-baseline" \
	"$EMBED_DIR/evil" "$EMBED_DIR/out"
printf '#!/bin/sh\nexit 0\n' > "$EMBED_DIR/core/oxidns"
printf 'example.com\n' > "$EMBED_DIR/rules/oxidns-rules-baseline/cn-domains.txt"
tar -czf "$EMBED_DIR/core.tar.gz" -C "$EMBED_DIR/core" oxidns
tar -czf "$EMBED_DIR/rules.tar.gz" -C "$EMBED_DIR/rules" oxidns-rules-baseline
CORE_SHA="$(sha256_of "$EMBED_DIR/core.tar.gz")"
RULES_SHA="$(sha256_of "$EMBED_DIR/rules.tar.gz")"
scripts/build-luci-package.sh "$PKG_VERSION" "$EMBED_DIR/out" \
	"$EMBED_DIR/core.tar.gz" "$EMBED_DIR/rules.tar.gz" "$CORE_SHA" "$RULES_SHA" >/dev/null
ar_nested_has_member "$EMBED_DIR/out/${PKG_BASE}.ipk" data.tar.gz usr/share/oxidns/core-bundle.tar.gz
ar_nested_has_member "$EMBED_DIR/out/${PKG_BASE}.ipk" data.tar.gz usr/share/oxidns/rules-baseline/cn-domains.txt
tar_has_member "$EMBED_DIR/out/${PKG_BASE}.apk" usr/share/oxidns/core-bundle.tar.gz
tar_has_member "$EMBED_DIR/out/${PKG_BASE}.apk" usr/share/oxidns/rules-baseline/cn-domains.txt

if scripts/build-luci-package.sh "$PKG_VERSION" "$EMBED_DIR/out" \
	"$EMBED_DIR/core.tar.gz" "$EMBED_DIR/rules.tar.gz" "$CORE_SHA" \
	deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1; then
	echo "build must reject a mismatched embedded archive SHA256" >&2
	exit 1
fi
if scripts/build-luci-package.sh "$PKG_VERSION" "$EMBED_DIR/out" \
	"$EMBED_DIR/core.tar.gz" "$EMBED_DIR/rules.tar.gz" >/dev/null 2>&1; then
	echo "build must require SHA256 for embedded archives" >&2
	exit 1
fi
printf '/etc/passwd\n' > "$EMBED_DIR/evil/passwd"
# tar records ../evil as a traversal entry; the build must reject it before
# extraction even when the archive's checksum is correct.
tar -czf "$EMBED_DIR/evil-rules.tar.gz" -C "$EMBED_DIR/rules" \
	../evil/passwd 2>/dev/null || true
if tar -tzf "$EMBED_DIR/evil-rules.tar.gz" 2>/dev/null | grep -q '\.\./'; then
	EVIL_SHA="$(sha256_of "$EMBED_DIR/evil-rules.tar.gz")"
	if scripts/build-luci-package.sh "$PKG_VERSION" "$EMBED_DIR/out" "" \
		"$EMBED_DIR/evil-rules.tar.gz" "" "$EVIL_SHA" >/dev/null 2>&1; then
		echo "build accepted a path-traversal rules archive" >&2
		exit 1
	fi
fi
rm -rf "$EMBED_DIR"

# Two quick builds of the same tree must be byte-identical.
DIST_DIR_2="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-dist2.XXXXXX")"
scripts/build-luci-package.sh "$PKG_VERSION" "$DIST_DIR_2" >/dev/null
cmp "$DIST_DIR/sha256sums.txt" "$DIST_DIR_2/sha256sums.txt" || {
	echo "quick packages are not reproducible" >&2
	exit 1
}
(cd "$DIST_DIR" && sha256sum -c sha256sums.txt 2>/dev/null || shasum -a 256 -c sha256sums.txt)

rm -rf "$DIST_DIR" "$DIST_DIR_2"
