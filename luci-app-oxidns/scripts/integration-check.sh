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

assert_unsafe_upload_rejected() {
	upload="$1"
	printf '{"path":"%s"}' "$upload" |
		root/usr/libexec/rpcd/luci.oxidns call core_upload_install |
		json_ok "v.ok === false && v.code === 'uploaded_archive_unsafe'"
}

INIT_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-init-stub.XXXXXX")"
printf '#!/bin/sh\nsleep 30\n' > "$INIT_STUB_DIR/oxidns"
: > "$INIT_STUB_DIR/config.yaml"
chmod 755 "$INIT_STUB_DIR/oxidns"
# Drive start_service from the real init script and record the procd params it sets.
printf '%s\n' \
	'set -eu' \
	'PROCD_ARGS="'"$INIT_STUB_DIR"'/procd-args"' \
	'config_load() { :; }' \
	'config_get() { case "$1" in CONFIG_PATH) CONFIG_PATH="'"$INIT_STUB_DIR"'/config.yaml" ;; WORKING_DIR) WORKING_DIR="'"$INIT_STUB_DIR"'" ;; esac; }' \
	'config_get_bool() { eval "$1=\$FAKE_UCI_VALUE"; }' \
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

root/usr/libexec/rpcd/luci.oxidns list | json_ok "'status' in v && 'core_install' in v && 'core_reinstall' in v && 'core_update' in v && 'core_upload_install' in v && 'core_webui_install' in v && 'core_progress' in v && 'core_remove' in v && 'logs_recent' in v && 'logs_path_read' in v && 'logs_path_save' in v && 'settings_read' in v && 'config_read' in v && 'config_schema' in v && 'config_plugin_types' in v && 'config_save' in v && 'dns_integration_status' in v && 'dns_integration_enable' in v && 'dns_integration_disable' in v && !('config_basic_read' in v) && !('config_basic_save' in v)"
root/usr/libexec/rpcd/luci.oxidns call status | json_ok "v.ok === true && v.core && v.core.installed === false && v.webui && v.webui.installed === false && typeof v.webui.url === 'string' && typeof v.webui.local_only === 'boolean' && typeof v.webui.wildcard === 'boolean' && !('api' in v) && !('api_base_url' in v) && !('package' in v) && !('package_manager' in v)"
root/usr/libexec/rpcd/luci.oxidns call dns_integration_status | json_ok "v.ok === true && v.supported === false && v.managed === false && v.can_enable === false && v.can_disable === false && v.message === 'dnsmasq is not available'"
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
root/usr/libexec/rpcd/luci.oxidns call core_update | json_ok "v.ok === false && v.code === 'core_not_installed'"
root/usr/libexec/rpcd/luci.oxidns call core_webui_install | json_ok "v.ok === false && v.code === 'core_not_installed'"
printf '%s' '{"path":"/etc/passwd"}' | root/usr/libexec/rpcd/luci.oxidns call core_upload_install | json_ok "v.ok === false && v.code === 'invalid_upload_path'"
LOCK_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-lock-test.XXXXXX")"
mkdir -p "$LOCK_TEST_DIR/luci-oxidns/core-operation.lock"
printf '%s\n' "$$" > "$LOCK_TEST_DIR/luci-oxidns/core-operation.lock/pid"
TMPDIR="$LOCK_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_reinstall | json_ok "v.ok === false && v.code === 'core_operation_busy'"
TMPDIR="$LOCK_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_update | json_ok "v.ok === false && v.code === 'core_operation_busy'"
TMPDIR="$LOCK_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_webui_install | json_ok "v.ok === false && v.code === 'core_operation_busy'"
rm -rf "$LOCK_TEST_DIR"
eval "$(sed -n '/^version_is_newer()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
version_is_newer v1.7.0 1.6.1
! version_is_newer v1.6.1 1.6.1
! version_is_newer v1.6.1 1.7.0
version_is_newer v1.7.0 v1.7.0-rc1
! version_is_newer v1.7.0-rc1 v1.7.0
version_is_newer 1.7.0+build 1.6.1
! version_is_newer dev 1.6.1
eval "$(sed -n '/^bundle_includes_webui()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
eval "$(sed -n '/^webui_install_bundle()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
eval "$(sed -n '/^dir_has_files()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
eval "$(sed -n '/^stage_webui_files()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
eval "$(sed -n '/^install_staged_webui()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
eval "$(sed -n '/^install_core_files()/,/^}/p' root/usr/libexec/rpcd/luci.oxidns)"
bundle_includes_webui full
bundle_includes_webui standard
! bundle_includes_webui minimal
! bundle_includes_webui ""
! bundle_includes_webui custom
test "$(webui_install_bundle full minimal)" = "full"
test "$(webui_install_bundle standard minimal)" = "standard"
test "$(webui_install_bundle minimal standard)" = "standard"
test "$(webui_install_bundle minimal full)" = "full"
test "$(webui_install_bundle minimal minimal)" = "standard"
test "$(webui_install_bundle '' '')" = "standard"
test "$(webui_install_bundle custom full)" = "full"
WEBUI_HELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-webui-helper.XXXXXX")"
mkdir -p "$WEBUI_HELPER_DIR/source/sub" "$WEBUI_HELPER_DIR/empty"
printf 'asset' > "$WEBUI_HELPER_DIR/source/sub/app.js"
dir_has_files "$WEBUI_HELPER_DIR/source"
! dir_has_files "$WEBUI_HELPER_DIR/empty"
! dir_has_files "$WEBUI_HELPER_DIR/missing"
stage_webui_files "$WEBUI_HELPER_DIR/source" "$WEBUI_HELPER_DIR/stage"
test -f "$WEBUI_HELPER_DIR/stage/sub/app.js"
! stage_webui_files "$WEBUI_HELPER_DIR/empty" "$WEBUI_HELPER_DIR/empty-stage"
test ! -e "$WEBUI_HELPER_DIR/empty-stage"
WEBUI_DIR="$WEBUI_HELPER_DIR/webui"
mkdir -p "$WEBUI_DIR"
printf 'old' > "$WEBUI_DIR/old.txt"
stage_webui_files "$WEBUI_HELPER_DIR/source" "$WEBUI_HELPER_DIR/stage2"
install_staged_webui "$WEBUI_HELPER_DIR/stage2"
test -f "$WEBUI_DIR/sub/app.js"
test ! -e "$WEBUI_DIR/old.txt"
! install_staged_webui "$WEBUI_HELPER_DIR/missing-stage"
test -f "$WEBUI_DIR/sub/app.js"
OXIDNS_BIN="$WEBUI_HELPER_DIR/bin/oxidns"
WORKING_DIR="$WEBUI_HELPER_DIR/work"
core_progress_command() { :; }
mkdir -p "$(dirname "$OXIDNS_BIN")" "$WORKING_DIR" "$WEBUI_DIR"
printf 'old-core' > "$OXIDNS_BIN"
printf 'new-core' > "$WEBUI_HELPER_DIR/new-oxidns"
stage_webui_files "$WEBUI_HELPER_DIR/source" "$WEBUI_HELPER_DIR/stage3"
install_core_files "$WEBUI_HELPER_DIR/new-oxidns" "$WEBUI_HELPER_DIR/stage3"
test "$(cat "$OXIDNS_BIN")" = "new-core"
test -f "$WEBUI_DIR/sub/app.js"
printf 'old-core-2' > "$OXIDNS_BIN"
! install_core_files "$WEBUI_HELPER_DIR/new-oxidns" "$WEBUI_HELPER_DIR/missing-stage"
test "$(cat "$OXIDNS_BIN")" = "old-core-2"
test -f "$WEBUI_DIR/sub/app.js"
test -z "$(find "$(dirname "$OXIDNS_BIN")" -name '.oxidns.previous.*' -print -quit)"
rm -rf "$WEBUI_HELPER_DIR"
node -e "const acl=JSON.parse(require('fs').readFileSync('root/usr/share/rpcd/acl.d/luci-app-oxidns.json','utf8'))['luci-app-oxidns']; const read=acl.read.ubus['luci.oxidns']; const write=acl.write.ubus['luci.oxidns']; if (read.includes('core_update') || !write.includes('core_update') || read.includes('core_webui_install') || !write.includes('core_webui_install') || read.includes('config_validate') || !write.includes('config_validate') || !read.includes('config_schema') || write.includes('config_schema') || !read.includes('config_plugin_types') || write.includes('config_plugin_types') || !read.includes('dns_integration_status') || write.includes('dns_integration_status') || read.includes('dns_integration_enable') || !write.includes('dns_integration_enable') || read.includes('dns_integration_disable') || !write.includes('dns_integration_disable')) process.exit(1);"
JSON_ESCAPED="$(printf '%s\n' 'listen: "127.0.0.1:9199"' | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "\\") printf "\\\\"; else if (c == "\"") printf "\\\""; else if (c == "\t") printf "\\t"; else if (c == "\r") printf "\\r"; else printf "%s", c; } }')"
test "$JSON_ESCAPED" = 'listen: \"127.0.0.1:9199\"'
PROGRESS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-progress-test.XXXXXX")"
printf 'original' > "$PROGRESS_TEST_DIR/target"
mkdir "$PROGRESS_TEST_DIR/luci-oxidns"
ln -s "$PROGRESS_TEST_DIR/target" "$PROGRESS_TEST_DIR/luci-oxidns/core-progress.log"
TMPDIR="$PROGRESS_TEST_DIR" root/usr/libexec/rpcd/luci.oxidns call core_reinstall >/dev/null 2>&1 || true
test "$(cat "$PROGRESS_TEST_DIR/target")" = "original"
rm -rf "$PROGRESS_TEST_DIR"
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
printf '%s' '{"content":""}' | root/usr/libexec/rpcd/luci.oxidns call config_validate | json_ok "v.ok === false && v.code === 'missing_content'"
root/usr/libexec/rpcd/luci.oxidns call config_read | json_ok "v.ok === false && v.code === 'config_not_found'"
OXIDNS_SCHEMA_FILE="$PWD/root/usr/share/oxidns/config-schema.json" root/usr/libexec/rpcd/luci.oxidns call config_schema | json_ok "v.ok === true && v.schema && v.schema.version === 1 && v.schema.plugins && typeof v.schema.plugins === 'object'"
OXIDNS_SCHEMA_FILE=/nonexistent/config-schema.json root/usr/libexec/rpcd/luci.oxidns call config_schema | json_ok "v.ok === false && v.code === 'schema_not_found'"
PLUGIN_STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oxidns-plugin-types.XXXXXX")"
cat > "$PLUGIN_STUB_DIR/jsonfilter" <<'EOF'
#!/usr/bin/env node
'use strict';
const fs = require('fs');
const args = process.argv.slice(2);
const at = args.indexOf('-e');
if (at === -1)
	process.exit(2);
const expr = args[at + 1];
let doc;
try {
	doc = JSON.parse(fs.readFileSync(0, 'utf8'));
}
catch (err) {
	process.exit(1);
}
let value = doc;
if (expr !== '@') {
	for (const part of expr.replace(/^@\.?/, '').split('.').filter(Boolean)) {
		if (value === null || typeof value !== 'object' || !(part in value))
			process.exit(1);
		value = value[part];
	}
}
if (value === undefined)
	process.exit(1);
if (typeof value === 'string')
	process.stdout.write(value + '\n');
else
	process.stdout.write(JSON.stringify(value) + '\n');
EOF
chmod 755 "$PLUGIN_STUB_DIR/jsonfilter"
cat > "$PLUGIN_STUB_DIR/oxidns" <<'EOF'
#!/bin/sh
[ "${1:-}" = "build-info" ] || exit 2
cat <<'JSON'
{
  "version": "9.9.9-test",
  "bundle": "full",
  "enabled_bundles": ["full"],
  "enabled_features": ["plugin-response"],
  "supported_plugins": {
    "servers": ["udp_server", "tcp_server"],
    "executors": ["forward", "sequence"],
    "matchers": ["qname"],
    "providers": ["domain_set"]
  }
}
JSON
EOF
chmod 755 "$PLUGIN_STUB_DIR/oxidns"
printf '%s\n' '#!/bin/sh' 'printf "not-json\n"' > "$PLUGIN_STUB_DIR/bad-oxidns"
chmod 755 "$PLUGIN_STUB_DIR/bad-oxidns"
PATH="$PLUGIN_STUB_DIR:$PATH" OXIDNS_BIN="$PLUGIN_STUB_DIR/oxidns" \
	root/usr/libexec/rpcd/luci.oxidns call config_plugin_types |
	json_ok "v.ok === true && v.source === 'core' && v.version === '9.9.9-test' && v.plugins.servers.length === 2 && v.plugins.servers[0] === 'udp_server' && v.plugins.executors.includes('forward') && v.plugins.matchers[0] === 'qname' && v.plugins.providers[0] === 'domain_set' && !('bundle' in v) && !('enabled_bundles' in v) && !('enabled_features' in v)"
PATH="$PLUGIN_STUB_DIR:$PATH" OXIDNS_BIN="$PLUGIN_STUB_DIR/bad-oxidns" OXIDNS_PLUGIN_TYPES_FILE="$PWD/root/usr/share/oxidns/plugin-types.json" \
	root/usr/libexec/rpcd/luci.oxidns call config_plugin_types |
	json_ok "v.ok === true && v.source === 'static' && v.plugins.executors.includes('forward')"
PATH="$PLUGIN_STUB_DIR:$PATH" OXIDNS_BIN="$PLUGIN_STUB_DIR/missing-oxidns" OXIDNS_PLUGIN_TYPES_FILE="$PWD/root/usr/share/oxidns/plugin-types.json" \
	root/usr/libexec/rpcd/luci.oxidns call config_plugin_types |
	json_ok "v.ok === true && v.source === 'static' && v.version === '' && v.plugins.servers.includes('udp_server') && v.plugins.servers.includes('quic_server') && v.plugins.executors.includes('forward') && v.plugins.executors.includes('prefer_ipv4') && v.plugins.matchers.includes('qname') && v.plugins.providers.includes('domain_set')"
PATH="$PLUGIN_STUB_DIR:$PATH" OXIDNS_BIN="$PLUGIN_STUB_DIR/missing-oxidns" OXIDNS_PLUGIN_TYPES_FILE=/nonexistent/plugin-types.json \
	root/usr/libexec/rpcd/luci.oxidns call config_plugin_types |
	json_ok "v.ok === false && v.code === 'plugin_types_not_found'"
rm -rf "$PLUGIN_STUB_DIR"
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
printf '%s' '{"limit":"20"}' | root/usr/libexec/rpcd/luci.oxidns call logs_recent | json_ok "v.ok === true && v.source === 'logread' && Array.isArray(v.lines) && !('entries' in v)"
printf '%s' '{}' | root/usr/libexec/rpcd/luci.oxidns call logs_path_read | json_ok "v.ok === true && typeof v.log_dir === 'string' && v.log_dir.length > 0 && typeof v.log_file === 'string' && v.default_dir === '/tmp/oxidns' && typeof v.configured === 'boolean'"
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

DIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-oxidns-dist.XXXXXX")"
scripts/build-luci-package.sh 0.1.0 "$DIST_DIR" >/dev/null
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.ipk" control.tar.gz
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.ipk" data.tar.gz
tar_nested_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.ipk" control.tar.gz postinst
tar_nested_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.ipk" control.tar.gz postrm
tar_nested_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.ipk" data.tar.gz etc/init.d/oxidns
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.ipk" control.tar.gz
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.ipk" data.tar.gz
tar_nested_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.ipk" control.tar.gz postinst
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .PKGINFO
tar_member_contains "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .PKGINFO '^arch = noarch$'
tar_member_contains "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .PKGINFO '^datahash = [0-9a-f][0-9a-f]*$'
apk_data_has_checksum "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk"
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" etc
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" etc/config
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" usr/share/luci/menu.d
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" www/luci-static/resources/view/oxidns
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" usr/libexec/rpcd/luci.oxidns
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" etc/init.d/oxidns
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .post-install
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .post-upgrade
tar_has_member "$DIST_DIR/luci-app-oxidns_0.1.0-r1_all.apk" .post-deinstall
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" .PKGINFO
tar_member_contains "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" .PKGINFO '^arch = noarch$'
tar_member_contains "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" .PKGINFO '^datahash = [0-9a-f][0-9a-f]*$'
apk_data_has_checksum "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk"
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" usr/lib/lua/luci/i18n
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" usr/lib/lua/luci/i18n/oxidns.zh-cn.lmo
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" .post-install
tar_has_member "$DIST_DIR/luci-i18n-oxidns-zh-cn_0.1.0-r1_all.apk" .post-upgrade

rm -rf "$DIST_DIR"
