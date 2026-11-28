#!/bin/sh
# WRTBox Core Manager for reF1nd/sing-box-releases

REPO="reF1nd/sing-box-releases"
API_URL="https://api.github.com/repos/${REPO}/releases?per_page=25"
ATOM_URL="https://github.com/${REPO}/releases.atom"
DEFAULT_CDNS="https://ghfast.top/ https://gh-proxy.com/ https://gh-proxy.org/ https://ghproxy.net/ https://gh.llkk.cc/ https://ghproxy.cc/ https://mirror.ghproxy.com/ https://gh.ddlc.top/ https://v6.gh-proxy.com/ https://edgeone.gh-proxy.com/"
TASK_STATE="/tmp/wrtbox_core_task.json"
TASK_LOCK="/tmp/wrtbox_core_update.lock"
TASK_LOG="/tmp/log/wrtbox-tasks.log"

log_task() {
	mkdir -p /tmp/log
	if [ -f "$TASK_LOG" ] && [ "$(wc -c < "$TASK_LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
		tail -n 300 "$TASK_LOG" > "${TASK_LOG}.tmp" && mv -f "${TASK_LOG}.tmp" "$TASK_LOG"
	fi
	printf '[%s] [core] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$TASK_LOG"
}

set_task_state() {
	local status="$1"
	local progress="$2"
	local message="$3"
	ucode -e '
		let fs = require("fs");
		fs.writefile(ARGV[0], sprintf("%J\n", {
			status: ARGV[1],
			progress: int(ARGV[2]),
			message: ARGV[3],
			updated_at: time()
		}));
	' "$TASK_STATE" "$status" "$progress" "$message" 2>/dev/null || true
}

get_uci() {
	local key="$1"
	local def="$2"
	local val
	val="$(uci -q get "wrtbox.main.${key}")"
	if [ -n "$val" ]; then
		printf '%s' "$val"
	else
		printf '%s' "$def"
	fi
}

detect_arch() {
	local machine has_avx2
	machine="$(uname -m)"
	case "$machine" in
		x86_64|amd64)
			has_avx2=0
			if grep -qE '(^| )avx2( |$)' /proc/cpuinfo 2>/dev/null; then
				has_avx2=1
			fi
			if [ "$has_avx2" -eq 1 ]; then
				echo "amd64-v3"
			else
				echo "amd64-v1"
			fi
			;;
		aarch64|arm64)
			echo "arm64"
			;;
		armv7l|armv7*)
			echo "armv7"
			;;
		armv6l|armv6*)
			echo "armv6"
			;;
		i386|i686)
			echo "386"
			;;
		mips64*)
			echo "mips64"
			;;
		mips*)
			if command -v apk >/dev/null 2>&1 && apk --print-arch 2>/dev/null | grep -q 'mipsel'; then
				echo "mipsle"
			else
				echo "mips"
			fi
			;;
		riscv64)
			echo "riscv64"
			;;
		*)
			echo "$machine"
			;;
	esac
}

apply_cdn() {
	local raw_url="$1"
	local custom_cdn="$2"
	local cdn_enabled cdn_url
	if [ -n "$custom_cdn" ]; then
		cdn_enabled="1"
		cdn_url="$custom_cdn"
	else
		cdn_enabled="$(get_uci cdn_enabled 1)"
		cdn_url="$(get_uci cdn_url 'https://ghfast.top/')"
	fi

	if [ "$cdn_enabled" != "1" ] || [ -z "$cdn_url" ]; then
		printf '%s' "$raw_url"
		return
	fi

	case "$cdn_url" in
		*%s*)
			printf '%s' "$cdn_url" | sed "s|%s|$raw_url|g"
			;;
		*/)
			printf '%s%s' "$cdn_url" "$raw_url"
			;;
		*)
			printf '%s/%s' "$cdn_url" "$raw_url"
			;;
	esac
}

get_current_version() {
	local core_path
	core_path="$(get_uci core_path '/usr/libexec/wrtbox/sing-box')"
	if [ -x "$core_path" ]; then
		"$core_path" version 2>/dev/null | awk '/sing-box version/{print $3; exit}'
	fi
}

fetch_via_atom() {
	local channel="$1"
	local target_tag="$2"
	local arch="$3"
	local cdn_enabled="$4"
	local cdn_url="$5"
	local use_cdn_prefix="$6"
	local atom_tmp="$7"
	local assets_tmp="$8"

	local atom_fetch_url="$ATOM_URL"
	if [ -n "$use_cdn_prefix" ]; then
		atom_fetch_url="$(apply_cdn "$ATOM_URL" "$use_cdn_prefix")"
	fi

	if ! curl -fsSL --connect-timeout 6 --max-time 12 -H "User-Agent: luci-app-wrtbox" "$atom_fetch_url" -o "$atom_tmp" 2>/dev/null; then
		return 1
	fi
	if ! grep -qE '<feed|<entry' "$atom_tmp" 2>/dev/null; then
		return 1
	fi

	local resolved_tag
	resolved_tag="$(ucode -e '
		let fs = require("fs");
		let xml = fs.readfile(ARGV[0]) || "";
		let channel = ARGV[1];
		let target = ARGV[2];
		let entries = [];
		let reEntry = /<entry>([\s\S]*?)<\/entry>/g;
		let m;
		while ((m = reEntry.exec(xml)) !== null) {
			let body = m[1];
			let tm = match(body, /<id>tag:github\.com,2008:Repository\/\d+\/([^<]+)<\/id>/);
			if (!tm) tm = match(body, /releases\/tag\/([^"<\s]+)/);
			if (!tm) continue;
			let tag = tm[1];
			let isPre = (match(tag, /-(alpha|beta|rc|dev|test)/i) != null)
				|| (match(body, /&lt;code&gt;testing&lt;\/code&gt;|<code>testing<\/code>/i) != null);
			push(entries, { tag: tag, pre: isPre });
		}
		if (target != "") {
			for (let e in entries) {
				if (e.tag == target) {
					print(target);
					exit(0);
				}
			}
		}
		for (let e in entries) {
			if (channel == "stable" && !e.pre) {
				print(e.tag);
				exit(0);
			}
			if (channel == "prerelease") {
				print(e.tag);
				exit(0);
			}
		}
		if (length(entries) > 0) print(entries[0].tag);
	' "$atom_tmp" "$channel" "$target_tag")"

	if [ -z "$resolved_tag" ]; then
		return 1
	fi

	local exp_raw="https://github.com/${REPO}/releases/expanded_assets/${resolved_tag}"
	local exp_url="$exp_raw"
	if [ -n "$use_cdn_prefix" ]; then
		exp_url="$(apply_cdn "$exp_raw" "$use_cdn_prefix")"
	fi

	if curl -fsSL --connect-timeout 6 --max-time 10 -H "User-Agent: luci-app-wrtbox" "$exp_url" -o "$assets_tmp" 2>/dev/null; then
		if grep -q '\.tar\.gz' "$assets_tmp" 2>/dev/null; then
			ucode -e '
				let fs = require("fs");
				let html = fs.readfile(ARGV[0]) || "";
				let tag = ARGV[1];
				let arch = ARGV[2];
				let channel = ARGV[3];
				let cdn_enabled = ARGV[4];
				let cdn_url = ARGV[5];
				let current_ver = ARGV[6];

				let links = [];
				let re = /href="([^"]*\/releases\/download\/[^"]+\.tar\.gz)"/g;
				let m;
				while ((m = re.exec(html)) !== null) {
					let href = m[1];
					if (substr(href, 0, 1) == "/") href = "https://github.com" + href;
					let parts = split(href, "/");
					push(links, { name: parts[length(parts) - 1], url: href });
				}

				function scoreAsset(name, arch) {
					let low = lc(name);
					if (!match(low, /linux/) || !match(low, /\.tar\.gz$/)) return -1;
					if (match(low, /android|windows|darwin|macos|ios|sha256|\.sig$/)) return -1;

					let s = 0;
					if (arch == "amd64-v3") {
						if (!match(low, /amd64|x86_64/)) return -1;
						if (match(low, /amd64[-_]?v3/)) s += 100;
						else if (match(low, /amd64[-_]?v1/)) s += 30;
						else s += 60;
					} else if (arch == "amd64-v1") {
						if (!match(low, /amd64|x86_64/)) return -1;
						if (match(low, /amd64[-_]?v3/)) return -1;
						if (match(low, /amd64[-_]?v1/)) s += 100;
						else s += 80;
					} else if (arch == "arm64") {
						if (!match(low, /arm64|aarch64/)) return -1;
						s += 90;
					} else if (arch == "armv7") {
						if (!match(low, /armv7/)) return -1;
						s += 90;
					} else {
						if (!match(low, arch)) return -1;
						s += 80;
					}
					if (match(low, /musl/)) s += 20;
					else if (match(low, /purego/)) s += 15;
					else if (match(low, /glibc/)) s -= 20;
					return s;
				}

				let best = null;
				let bestScore = -1;
				for (let a in links) {
					let sc = scoreAsset(a.name, arch);
					if (sc > bestScore) {
						bestScore = sc;
						best = a;
					}
				}

				if (!best) exit(1);

				let accel = best.url;
				if (cdn_enabled == "1" && cdn_url != "") {
					if (index(cdn_url, "%s") >= 0) accel = replace(cdn_url, "%s", best.url);
					else if (substr(cdn_url, -1) == "/") accel = cdn_url + best.url;
					else accel = cdn_url + "/" + best.url;
				}

				let is_pre = match(tag, /-(alpha|beta|rc|dev|test)/i) != null;
				printf("%J\n", {
					ok: true,
					source: "atom-cdn",
					channel: channel,
					tag: tag,
					prerelease: is_pre,
					published_at: "",
					arch: arch,
					asset_name: best.name,
					download_url: best.url,
					accelerated_url: accel,
					current_version: current_ver
				});
			' "$assets_tmp" "$resolved_tag" "$arch" "$channel" "$cdn_enabled" "$cdn_url" "$(get_current_version)" && return 0
		fi
	fi

	# Fallback when CDN blocks expanded_assets: probe deterministic reF1nd asset names
	local ver="${resolved_tag#v}"
	local cands=""
	case "$arch" in
		amd64-v3)
			cands="sing-box-${ver}-linux-amd64v3-musl.tar.gz sing-box-${ver}-linux-amd64v3-purego.tar.gz sing-box-${ver}-linux-amd64-musl.tar.gz sing-box-${ver}-linux-amd64-purego.tar.gz"
			;;
		amd64-v1)
			cands="sing-box-${ver}-linux-amd64-musl.tar.gz sing-box-${ver}-linux-amd64-purego.tar.gz"
			;;
		arm64)
			cands="sing-box-${ver}-linux-arm64-musl.tar.gz sing-box-${ver}-linux-arm64-purego.tar.gz"
			;;
		*)
			cands="sing-box-${ver}-linux-${arch}-musl.tar.gz sing-box-${ver}-linux-${arch}-purego.tar.gz sing-box-${ver}-linux-${arch}.tar.gz"
			;;
	esac

	local cand raw_dl accel_dl
	for cand in $cands; do
		raw_dl="https://github.com/${REPO}/releases/download/${resolved_tag}/${cand}"
		accel_dl="$raw_dl"
		if [ -n "$use_cdn_prefix" ]; then
			accel_dl="$(apply_cdn "$raw_dl" "$use_cdn_prefix")"
		fi
		if curl -fsIL --connect-timeout 4 --max-time 6 -H "User-Agent: luci-app-wrtbox" "$accel_dl" >/dev/null 2>&1 || \
		   curl -fsSL -r 0-0 -o /dev/null --connect-timeout 4 --max-time 6 -H "User-Agent: luci-app-wrtbox" "$accel_dl" >/dev/null 2>&1; then
			ucode -e '
				let tag = ARGV[0];
				let channel = ARGV[1];
				let arch = ARGV[2];
				let asset_name = ARGV[3];
				let raw_dl = ARGV[4];
				let accel_dl = ARGV[5];
				let current_ver = ARGV[6];
				let is_pre = match(tag, /-(alpha|beta|rc|dev|test)/i) != null;
				printf("%J\n", {
					ok: true,
					source: "atom-probe",
					channel: channel,
					tag: tag,
					prerelease: is_pre,
					published_at: "",
					arch: arch,
					asset_name: asset_name,
					download_url: raw_dl,
					accelerated_url: accel_dl,
					current_version: current_ver
				});
			' "$resolved_tag" "$channel" "$arch" "$cand" "$raw_dl" "$accel_dl" "$(get_current_version)"
			return 0
		fi
	done

	return 1
}

fetch_release_info() {
	local channel="$1"
	local target_tag="$2"
	local arch cdn_enabled cdn_url
	arch="$(detect_arch)"
	cdn_enabled="$(get_uci cdn_enabled 1)"
	cdn_url="$(get_uci cdn_url 'https://ghfast.top/')"

	local api_tmp="/tmp/wrtbox_api_$$.json"
	local atom_tmp="/tmp/wrtbox_atom_$$.xml"
	local assets_tmp="/tmp/wrtbox_assets_$$.html"
	local got_api=0

	if [ "$cdn_enabled" = "1" ] && [ -n "$cdn_url" ]; then
		local cdn_api_url
		cdn_api_url="$(apply_cdn "$API_URL" "$cdn_url")"
		if curl -fsSL --connect-timeout 6 --max-time 12 -H "Accept: application/vnd.github+json" -H "User-Agent: luci-app-wrtbox" "$cdn_api_url" -o "$api_tmp" 2>/dev/null; then
			if [ -s "$api_tmp" ] && tr -d ' \t\r\n' < "$api_tmp" | head -c 1 | grep -q '\['; then
				got_api=1
			fi
		fi

		if [ "$got_api" -eq 0 ]; then
			if fetch_via_atom "$channel" "$target_tag" "$arch" "$cdn_enabled" "$cdn_url" "$cdn_url" "$atom_tmp" "$assets_tmp"; then
				rm -f "$api_tmp" "$atom_tmp" "$assets_tmp"
				return 0
			fi
		fi
	else
		if curl -fsSL --connect-timeout 6 --max-time 15 -H "Accept: application/vnd.github+json" -H "User-Agent: luci-app-wrtbox" "$API_URL" -o "$api_tmp" 2>/dev/null; then
			if [ -s "$api_tmp" ] && tr -d ' \t\r\n' < "$api_tmp" | head -c 1 | grep -q '\['; then
				got_api=1
			fi
		fi

		if [ "$got_api" -eq 0 ]; then
			if fetch_via_atom "$channel" "$target_tag" "$arch" "0" "" "" "$atom_tmp" "$assets_tmp"; then
				rm -f "$api_tmp" "$atom_tmp" "$assets_tmp"
				return 0
			fi
		fi
	fi

	if [ "$got_api" -eq 0 ]; then
		rm -f "$api_tmp" "$atom_tmp" "$assets_tmp"
		ucode -e 'printf("%J\n", { ok: false, error: "Failed to fetch release metadata. Please test and select an available CDN or check network connectivity." });'
		return 1
	fi

	ucode -e '
		let fs = require("fs");
		let raw = fs.readfile(ARGV[0]) || "[]";
		let channel = ARGV[1];
		let target_tag = ARGV[2];
		let arch = ARGV[3];
		let cdn_enabled = ARGV[4];
		let cdn_url = ARGV[5];
		let current_ver = ARGV[6];

		let releases;
		try {
			releases = json(raw);
		} catch (e) {
			printf("%J\n", { ok: false, error: "Invalid JSON from GitHub API" });
			exit(1);
		}

		let chosen = null;
		for (let r in releases) {
			if (r.draft) continue;
			if (target_tag != "") {
				if (r.tag_name == target_tag) { chosen = r; break; }
				continue;
			}
			let is_pre = r.prerelease || (match(r.tag_name, /-(alpha|beta|rc|dev|test)/i) != null);
			if (channel == "stable" && !is_pre) {
				chosen = r;
				break;
			}
			if (channel == "prerelease") {
				if (is_pre || !chosen) chosen = r;
				if (is_pre) break;
			}
		}

		if (!chosen) {
			printf("%J\n", { ok: false, error: "No release found for channel: " + channel });
			exit(1);
		}

		function scoreAsset(name, arch) {
			let low = lc(name);
			if (!match(low, /linux/) || !match(low, /\.tar\.gz$/)) return -1;
			if (match(low, /android|windows|darwin|macos|ios|sha256|\.sig$/)) return -1;

			let s = 0;
			if (arch == "amd64-v3") {
				if (!match(low, /amd64|x86_64/)) return -1;
				if (match(low, /amd64[-_]?v3/)) s += 100;
				else if (match(low, /amd64[-_]?v1/)) s += 30;
				else s += 60;
			} else if (arch == "amd64-v1") {
				if (!match(low, /amd64|x86_64/)) return -1;
				if (match(low, /amd64[-_]?v3/)) return -1;
				if (match(low, /amd64[-_]?v1/)) s += 100;
				else s += 80;
			} else if (arch == "arm64") {
				if (!match(low, /arm64|aarch64/)) return -1;
				s += 90;
			} else if (arch == "armv7") {
				if (!match(low, /armv7/)) return -1;
				s += 90;
			} else {
				if (!match(low, arch)) return -1;
				s += 80;
			}
			if (match(low, /musl/)) s += 20;
			else if (match(low, /purego/)) s += 15;
			else if (match(low, /glibc/)) s -= 20;
			return s;
		}

		let best = null;
		let bestScore = -1;
		for (let a in (chosen.assets || [])) {
			let sc = scoreAsset(a.name, arch);
			if (sc > bestScore) {
				bestScore = sc;
				best = a;
			}
		}

		if (!best) {
			printf("%J\n", { ok: false, error: "No matching linux .tar.gz asset found for arch " + arch + " in tag " + chosen.tag_name });
			exit(1);
		}

		let accel = best.browser_download_url;
		if (cdn_enabled == "1" && cdn_url != "") {
			if (index(cdn_url, "%s") >= 0) accel = replace(cdn_url, "%s", best.browser_download_url);
			else if (substr(cdn_url, -1) == "/") accel = cdn_url + best.browser_download_url;
			else accel = cdn_url + "/" + best.browser_download_url;
		}

		printf("%J\n", {
			ok: true,
			source: "github-api",
			channel: channel,
			tag: chosen.tag_name,
			prerelease: !!(chosen.prerelease || match(chosen.tag_name, /-(alpha|beta|rc|dev|test)/i)),
			published_at: chosen.published_at || "",
			arch: arch,
			asset_name: best.name,
			size: best.size || 0,
			download_url: best.browser_download_url,
			accelerated_url: accel,
			current_version: current_ver
		});
	' "$api_tmp" "$channel" "$target_tag" "$arch" "$cdn_enabled" "$cdn_url" "$(get_current_version)"
	local rc=$?
	rm -f "$api_tmp" "$atom_tmp" "$assets_tmp"
	return $rc
}

install_core() {
	local req_channel="${1:-$(get_uci core_channel stable)}"
	local req_tag="$2"
	local core_path core_dir
	core_path="$(get_uci core_path '/usr/libexec/wrtbox/sing-box')"
	core_dir="$(dirname "$core_path")"

	if [ -f "$TASK_LOCK" ]; then
		local old_pid
		old_pid="$(cat "$TASK_LOCK" 2>/dev/null)"
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			echo '{"ok":false,"error":"Another core update is already in progress"}'
			return 1
		fi
	fi
	echo "$$" > "$TASK_LOCK"
	trap 'rm -f "$TASK_LOCK"' EXIT

	set_task_state "running" 10 "Checking release metadata for ${req_channel} channel..."
	log_task "Starting core install/update (channel=${req_channel}, tag=${req_tag:-latest})"

	local info_json
	info_json="$(fetch_release_info "$req_channel" "$req_tag")"
	if [ $? -ne 0 ]; then
		local err_msg
		err_msg="$(printf '%s' "$info_json" | ucode -e 'let fs=require("fs"); let d=json(fs.stdin.read("all")); print(d.error || "Metadata fetch failed");' 2>/dev/null)"
		set_task_state "error" 0 "$err_msg"
		log_task "ERROR: $err_msg"
		printf '%s\n' "$info_json"
		return 1
	fi

	local tag asset_name download_url accelerated_url
	tag="$(printf '%s' "$info_json" | ucode -e 'let fs=require("fs"); print(json(fs.stdin.read("all")).tag)')"
	asset_name="$(printf '%s' "$info_json" | ucode -e 'let fs=require("fs"); print(json(fs.stdin.read("all")).asset_name)')"
	download_url="$(printf '%s' "$info_json" | ucode -e 'let fs=require("fs"); print(json(fs.stdin.read("all")).download_url)')"
	accelerated_url="$(printf '%s' "$info_json" | ucode -e 'let fs=require("fs"); print(json(fs.stdin.read("all")).accelerated_url)')"

	mkdir -p "$core_dir"
	local tmp_kb target_kb
	tmp_kb="$(df -k /tmp | awk 'NR==2{print $4}')"
	target_kb="$(df -k "$core_dir" | awk 'NR==2{print $4}')"
	if [ "${tmp_kb:-0}" -lt 40960 ]; then
		local msg="Insufficient /tmp free space (${tmp_kb}KB < 40MB)"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi
	if [ "${target_kb:-0}" -lt 30720 ]; then
		local msg="Insufficient target directory space at ${core_dir} (${target_kb}KB < 30MB)"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi

	local work_dir="/tmp/wrtbox_core_$$"
	local archive_file="${work_dir}/${asset_name}"
	mkdir -p "$work_dir"

	set_task_state "running" 30 "Downloading ${asset_name} (${tag})..."
	log_task "Downloading ${accelerated_url}"

	local dl_ok=0
	if curl -fSL --connect-timeout 15 --max-time 300 -H "User-Agent: luci-app-wrtbox" "$accelerated_url" -o "$archive_file" 2>/dev/null; then
		dl_ok=1
	fi

	if [ "$dl_ok" -ne 1 ] || [ ! -s "$archive_file" ]; then
		rm -rf "$work_dir"
		local msg="Failed to download ${asset_name}"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi

	set_task_state "running" 70 "Extracting and verifying binary..."
	if ! tar -xzf "$archive_file" -C "$work_dir" 2>/dev/null; then
		rm -rf "$work_dir"
		local msg="Archive extraction failed (corrupted .tar.gz)"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi

	local new_bin
	new_bin="$(find "$work_dir" -type f -name 'sing-box' | head -n 1)"
	if [ -z "$new_bin" ]; then
		rm -rf "$work_dir"
		local msg="sing-box executable not found inside archive"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi

	chmod 0755 "$new_bin"
	local ver_out
	ver_out="$("$new_bin" version 2>&1)"
	if [ $? -ne 0 ]; then
		rm -rf "$work_dir"
		local msg="Binary verification failed (incompatible ABI/arch): ${ver_out}"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"Binary verification failed\"}"
		return 1
	fi

	set_task_state "running" 85 "Installing binary to ${core_path}..."
	local was_running=0
	if ubus -S call service list '{"name":"wrtbox"}' 2>/dev/null | grep -q '"running":true'; then
		was_running=1
		/etc/init.d/wrtbox stop >/dev/null 2>&1 || true
	fi

	if [ -f "$core_path" ]; then
		cp -f "$core_path" "${core_path}.bak" 2>/dev/null || true
	fi

	if ! mv -f "$new_bin" "$core_path"; then
		if [ -f "${core_path}.bak" ]; then
			mv -f "${core_path}.bak" "$core_path" 2>/dev/null || true
		fi
		rm -rf "$work_dir"
		local msg="Failed to move binary to ${core_path}"
		set_task_state "error" 0 "$msg"
		log_task "ERROR: $msg"
		echo "{\"ok\":false,\"error\":\"$msg\"}"
		return 1
	fi

	chmod 0755 "$core_path"
	rm -f "${core_path}.bak"
	rm -rf "$work_dir"

	uci set wrtbox.main.core_version="$tag"
	uci commit wrtbox

	if [ "$was_running" -eq 1 ]; then
		set_task_state "running" 95 "Restarting wrtbox service..."
		/etc/init.d/wrtbox start >/dev/null 2>&1 || true
	fi

	set_task_state "success" 100 "Installed ${tag} successfully"
	log_task "Successfully installed ${tag} to ${core_path}"
	printf '{"ok":true,"tag":"%s","core_path":"%s"}\n' "$tag" "$core_path"
	return 0
}

uninstall_core() {
	local core_path
	core_path="$(get_uci core_path '/usr/libexec/wrtbox/sing-box')"

	if [ -f "$TASK_LOCK" ]; then
		local old_pid
		old_pid="$(cat "$TASK_LOCK" 2>/dev/null)"
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			echo '{"ok":false,"error":"Another core operation is in progress"}'
			return 1
		fi
	fi

	if [ "$core_path" = "/usr/bin/sing-box" ] || [ -z "$core_path" ] || [ "$core_path" = "/" ]; then
		echo '{"ok":false,"error":"Refusing to remove system or invalid path"}'
		return 1
	fi

	if ubus -S call service list '{"name":"wrtbox"}' 2>/dev/null | grep -q '"running":true'; then
		/etc/init.d/wrtbox stop >/dev/null 2>&1 || true
	fi

	rm -f "$core_path" "${core_path}.bak"
	uci -q delete wrtbox.main.core_version || true
	uci commit wrtbox
	set_task_state "idle" 0 ""
	log_task "Uninstalled core binary from ${core_path}"

	printf '{"ok":true,"core_path":"%s"}\n' "$core_path"
	return 0
}

test_cdn() {
	local extra_url="$1"
	local current_url
	current_url="$(get_uci cdn_url '')"
	local probe="$ATOM_URL"
	local tmp_dir="/tmp/wrtbox_cdntest_$$"
	mkdir -p "$tmp_dir"

	local candidates="$DEFAULT_CDNS"
	for u in "$extra_url" "$current_url"; do
		[ -n "$u" ] || continue
		case " $candidates " in
			*" $u "*) ;;
			*) candidates="$candidates $u" ;;
		esac
	done

	local idx=0
	for u in $candidates; do
		idx=$((idx + 1))
		(
			local target body_file res code latency ok_flag
			target="$(apply_cdn "$probe" "$u")"
			body_file="${tmp_dir}/${idx}.body"
			ok_flag=0
			code=0
			latency=99999
			res="$(curl -fsSL -o "$body_file" -w '%{http_code} %{time_total}' --connect-timeout 4 --max-time 6 -H "User-Agent: luci-app-wrtbox" "$target" 2>/dev/null)"
			if [ $? -eq 0 ] && [ -s "$body_file" ] && grep -qE '<feed|<entry' "$body_file" 2>/dev/null; then
				code="$(echo "$res" | awk '{print $1}')"
				latency="$(echo "$res" | awk '{printf "%.0f", $2 * 1000}')"
				if [ "${code:-0}" -ge 200 ] && [ "${code:-0}" -lt 400 ]; then
					ok_flag=1
				fi
			fi
			rm -f "$body_file"
			printf '%s\t%s\t%s\t%s\n' "$ok_flag" "$latency" "${code:-0}" "$u" > "${tmp_dir}/${idx}.res"
		) &
	done
	wait

	local json_out best_url
	json_out="$(ucode -e '
		let fs = require("fs");
		let dir = ARGV[0];
		let files = fs.lsdir(dir) || [];
		let results = [];
		for (let f in files) {
			if (!match(f, /\.res$/)) continue;
			let line = trim(fs.readfile(dir + "/" + f) || "");
			if (line == "") continue;
			let parts = split(line, "\t");
			if (length(parts) < 4) continue;
			push(results, {
				ok: parts[0] == "1",
				latency_ms: int(parts[1]),
				http_code: int(parts[2]),
				url: parts[3]
			});
		}
		results = sort(results, (a, b) => {
			if (a.ok != b.ok) return a.ok ? -1 : 1;
			return a.latency_ms - b.latency_ms;
		});
		let avail = filter(results, (r) => r.ok);
		let best = length(avail) > 0 ? avail[0] : null;
		if (best) {
			printf("%J\n", {
				ok: true,
				best_url: best.url,
				best_latency_ms: best.latency_ms,
				best_http_code: best.http_code,
				tested: length(results),
				available: length(avail),
				results: results
			});
		} else {
			printf("%J\n", {
				ok: false,
				error: "All CDN nodes failed or timed out",
				tested: length(results),
				available: 0,
				results: results
			});
		}
	' "$tmp_dir")"

	rm -rf "$tmp_dir"

	best_url="$(printf '%s' "$json_out" | ucode -e 'let fs=require("fs"); let d=json(fs.stdin.read("all")); print(d.best_url || "");' 2>/dev/null)"
	if [ -n "$best_url" ]; then
		uci set wrtbox.main.cdn_enabled='1'
		uci set wrtbox.main.cdn_url="$best_url"
		uci commit wrtbox
		log_task "Auto-selected fastest CDN: ${best_url}"
	fi

	printf '%s\n' "$json_out"
}

case "$1" in
	arch)
		detect_arch
		;;
	version)
		get_current_version
		;;
	check)
		fetch_release_info "${2:-$(get_uci core_channel stable)}" "$3"
		;;
	install)
		install_core "$2" "$3"
		;;
	uninstall)
		uninstall_core
		;;
	test_cdn)
		test_cdn "$2"
		;;
	*)
		echo "Usage: $0 {arch|version|check [channel] [tag]|install [channel] [tag]|uninstall|test_cdn [url]}" >&2
		exit 1
		;;
esac
