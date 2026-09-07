#!/bin/sh
# AutoSign Core Execution Engine for OpenWrt
# Ultra-lightweight POSIX Shell Implementation

LOG_FILE="/var/log/autosign.log"
MAX_LOG_LINES=300
CONFIG_NAME="autosign"

. /lib/functions.sh

log() {
	local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
	local msg="[$timestamp] $1"
	echo "$msg"
	echo "$msg" >> "$LOG_FILE"
}

rotate_log() {
	if [ -f "$LOG_FILE" ]; then
		local line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
		if [ "$line_count" -gt "$MAX_LOG_LINES" ]; then
			local tmp_log="${LOG_FILE}.tmp"
			tail -n 100 "$LOG_FILE" > "$tmp_log" 2>/dev/null && mv "$tmp_log" "$LOG_FILE"
		fi
	fi
}

send_notify() {
	local title="$1"
	local content="$2"
	local notify_type="$3"
	local token="$4"
	local secret="$5"

	[ -z "$notify_type" ] || [ "$notify_type" = "none" ] && return 0
	[ -z "$token" ] && return 0

	log "正在发送消息通知 [$notify_type]..."

	local has_curl=0
	command -v curl >/dev/null 2>&1 && has_curl=1

	case "$notify_type" in
		pushplus)
			if [ "$has_curl" -eq 1 ]; then
				curl -s -k -m 10 -X POST "http://www.pushplus.plus/send" \
					-H "Content-Type: application/json" \
					-d "{\"token\":\"$token\",\"title\":\"$title\",\"content\":\"$content\",\"template\":\"txt\"}" >/dev/null 2>&1
			else
				wget -q -O /dev/null --post-data "{\"token\":\"$token\",\"title\":\"$title\",\"content\":\"$content\",\"template\":\"txt\"}" \
					--header "Content-Type: application/json" "http://www.pushplus.plus/send" 2>/dev/null
			fi
			;;
		serverchan)
			if [ "$has_curl" -eq 1 ]; then
				curl -s -k -m 10 -X POST "https://sctapi.ftqq.com/${token}.send" \
					-d "title=${title}&desp=${content}" >/dev/null 2>&1
			else
				wget -q -O /dev/null --no-check-certificate --post-data "title=${title}&desp=${content}" \
					"https://sctapi.ftqq.com/${token}.send" 2>/dev/null
			fi
			;;
		telegram)
			if [ -n "$secret" ]; then
				if [ "$has_curl" -eq 1 ]; then
					curl -s -k -m 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
						-d "chat_id=${secret}&text=${title}%0A%0A${content}" >/dev/null 2>&1
				else
					wget -q -O /dev/null --no-check-certificate --post-data "chat_id=${secret}&text=${title}%0A%0A${content}" \
						"https://api.telegram.org/bot${token}/sendMessage" 2>/dev/null
				fi
			fi
			;;
		bark)
			local encoded_title=$(echo "$title" | tr ' ' '+')
			local encoded_content=$(echo "$content" | tr ' ' '+')
			if [ "$has_curl" -eq 1 ]; then
				curl -s -k -m 10 "https://api.day.app/${token}/${encoded_title}/${encoded_content}" >/dev/null 2>&1
			else
				wget -q -O /dev/null --no-check-certificate "https://api.day.app/${token}/${encoded_title}/${encoded_content}" 2>/dev/null
			fi
			;;
		webhook)
			if [ "$has_curl" -eq 1 ]; then
				curl -s -k -m 10 -X POST "$token" \
					-H "Content-Type: application/json" \
					-d "{\"title\":\"$title\",\"message\":\"$content\"}" >/dev/null 2>&1
			else
				wget -q -O /dev/null --no-check-certificate --header "Content-Type: application/json" \
					--post-data "{\"title\":\"$title\",\"message\":\"$content\"}" "$token" 2>/dev/null
			fi
			;;
	esac
}

execute_http_task() {
	local task_id="$1"
	local name="$2"
	local url="$3"
	local method="$4"
	local headers="$5"
	local cookie="$6"
	local data="$7"
	local match_keyword="$8"
	local retry_count="$9"
	local retry_interval="${10:-10}"

	[ -z "$method" ] && method="GET"
	[ -z "$retry_count" ] && retry_count=1

	local attempt=1
	local success=0

	while [ "$attempt" -le "$retry_count" ]; do
		log "[$name] 正在执行 HTTP 请求 (第 $attempt/$retry_count 次)..."

		local has_curl=0
		command -v curl >/dev/null 2>&1 && has_curl=1

		local full_resp=""
		local exit_code=0
		local http_code=""
		local resp_body=""

		if [ "$has_curl" -eq 1 ]; then
			local curl_cmd="curl -s -S -k -L -m 30 -X $method"

			# 处理 Cookie
			if [ -n "$cookie" ]; then
				curl_cmd="$curl_cmd -H 'Cookie: $cookie'"
			fi

			# 处理 Headers
			if [ -n "$headers" ]; then
				local old_ifs="$IFS"
				IFS='
'
				for h in $headers; do
					[ -n "$h" ] && curl_cmd="$curl_cmd -H '$h'"
				done
				IFS="$old_ifs"
			fi

			# 处理 POST/PUT 数据
			if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
				if [ -n "$data" ]; then
					curl_cmd="$curl_cmd --data '$data'"
				fi
			fi

			curl_cmd="$curl_cmd -w '\nHTTP_CODE:%{http_code}' '$url'"

			full_resp=$(eval "$curl_cmd" 2>&1)
			exit_code=$?

			http_code=$(echo "$full_resp" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
			resp_body=$(echo "$full_resp" | sed 's/HTTP_CODE:[0-9]*$//')
		else
			# 没有 curl 时降级使用系统内置 wget / uclient-fetch
			local wget_cmd="wget -q -O - --no-check-certificate --timeout=30"

			if [ -n "$cookie" ]; then
				wget_cmd="$wget_cmd --header 'Cookie: $cookie'"
			fi

			if [ -n "$headers" ]; then
				local old_ifs="$IFS"
				IFS='
'
				for h in $headers; do
					[ -n "$h" ] && wget_cmd="$wget_cmd --header '$h'"
				done
				IFS="$old_ifs"
			fi

			if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
				if [ -n "$data" ]; then
					wget_cmd="$wget_cmd --post-data '$data'"
				else
					wget_cmd="$wget_cmd --post-data ''"
				fi
			fi

			resp_body=$(eval "$wget_cmd '$url'" 2>&1)
			exit_code=$?
			if [ "$exit_code" -eq 0 ]; then
				http_code=200
			else
				http_code=000
			fi
		fi

		local body_snippet=$(echo "$resp_body" | head -c 200 | tr '\r\n' ' ')

		if [ "$exit_code" -eq 0 ] && [ -n "$http_code" ]; then
			local is_keyword_matched=1
			if [ -n "$match_keyword" ]; then
				echo "$resp_body" | grep -q "$match_keyword"
				if [ $? -ne 0 ]; then
					is_keyword_matched=0
				fi
			fi

			if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ] && [ "$is_keyword_matched" -eq 1 ]; then
				log "[$name] 签到成功！(状态码: $http_code)"
				[ -n "$body_snippet" ] && log "[$name] 响应摘要: $body_snippet"
				success=1
				break
			else
				log "[$name] 校验未通过 (状态码: $http_code, 关键字匹配: $is_keyword_matched)"
				[ -n "$body_snippet" ] && log "[$name] 响应摘要: $body_snippet"
			fi
		else
			log "[$name] 请求发生异常 (curl错误码: $exit_code, HTTP状态: $http_code)"
		fi

		if [ "$attempt" -lt "$retry_count" ]; then
			log "[$name] 等待 $retry_interval 秒后重试..."
			sleep "$retry_interval"
		fi
		attempt=$((attempt + 1))
	done

	return $((1 - success))
}

execute_script_task() {
	local task_id="$1"
	local name="$2"
	local script_cmd="$3"

	if [ -z "$script_cmd" ]; then
		log "[$name] 脚本命令为空，跳过执行"
		return 1
	fi

	log "[$name] 开始执行自定义脚本..."
	local script_out=$(eval "$script_cmd" 2>&1)
	local exit_code=$?

	if [ "$exit_code" -eq 0 ]; then
		log "[$name] 脚本执行成功 (退出码: 0)"
		[ -n "$script_out" ] && log "[$name] 输出: $script_out"
		return 0
	else
		log "[$name] 脚本执行失败 (退出码: $exit_code)"
		[ -n "$script_out" ] && log "[$name] 错误输出: $script_out"
		return 1
	fi
}

run_task() {
	local section="$1"
	local enabled name type url method headers cookie data match_keyword script_cmd

	config_get_bool enabled "$section" enabled 0
	[ "$enabled" -ne 1 ] && return 0

	config_get name "$section" name "$section"
	config_get type "$section" type "http"
	config_get url "$section" url ""
	config_get method "$section" method "GET"
	config_get headers "$section" headers ""
	config_get cookie "$section" cookie ""
	config_get data "$section" data ""
	config_get match_keyword "$section" match_keyword ""
	config_get script_cmd "$section" script_cmd ""

	TOTAL_TASKS=$((TOTAL_TASKS + 1))

	local result=0
	if [ "$type" = "http" ]; then
		execute_http_task "$section" "$name" "$url" "$method" "$headers" "$cookie" "$data" "$match_keyword" "$RETRY_COUNT" "$RETRY_INTERVAL"
		result=$?
	elif [ "$type" = "script" ]; then
		execute_script_task "$section" "$name" "$script_cmd"
		result=$?
	fi

	if [ "$result" -eq 0 ]; then
		SUCCESS_TASKS=$((SUCCESS_TASKS + 1))
		SUMMARY_MSG="${SUMMARY_MSG}\n- [$name]: 成功"
	else
		FAILED_TASKS=$((FAILED_TASKS + 1))
		SUMMARY_MSG="${SUMMARY_MSG}\n- [$name]: 失败"
	fi
}

do_run() {
	local target_task="${1:-all}"
	local force_mode="$2"

	if [ "$target_task" = "force" ]; then
		target_task="all"
		force_mode="force"
	fi

	rotate_log

	config_load "$CONFIG_NAME"

	local global_enabled random_delay notify_type notify_token notify_secret
	config_get_bool global_enabled global enabled 0
	config_get random_delay global random_delay 0
	config_get RETRY_COUNT global retry_count 3
	config_get RETRY_INTERVAL global retry_interval 60
	config_get notify_type global notify_type "none"
	config_get notify_token global notify_token ""
	config_get notify_secret global notify_secret ""

	if [ "$force_mode" != "force" ] && [ "$global_enabled" -ne 1 ]; then
		log "AutoSign 插件处于全局停用状态，跳过本次任务"
		exit 0
	fi

	if [ "$target_task" != "all" ]; then
		# 单任务模式
		local task_name
		config_get task_name "$target_task" name "$target_task"
		log "=================================================="
		log ">>> AutoSign 定时任务 [$task_name] 启动 <<<"

		if [ "$force_mode" != "force" ] && [ "$random_delay" -gt 0 ]; then
			local seed=$(awk 'BEGIN{srand(); print int(rand()*32768)}')
			local delay=$(( seed % random_delay ))
			log "[$task_name] 已启用防封延迟，随机休眠 $delay 秒后开始执行..."
			sleep "$delay"
		fi

		TOTAL_TASKS=0
		SUCCESS_TASKS=0
		FAILED_TASKS=0
		SUMMARY_MSG=""

		run_task "$target_task"

		if [ "$TOTAL_TASKS" -eq 0 ]; then
			log "[$task_name] 任务不存在或未启用！"
		else
			local status_str="失败"
			[ "$SUCCESS_TASKS" -gt 0 ] && status_str="成功"
			log ">>> 任务 [$task_name] 执行完成: $status_str <<<"
			log "=================================================="

			local notify_title="OpenWrt 签到提醒: [$task_name] $status_str"
			local notify_content="任务 [$task_name] 执行完成，状态: $status_str。$(echo -e "$SUMMARY_MSG")"
			send_notify "$notify_title" "$notify_content" "$notify_type" "$notify_token" "$notify_secret"
		fi
	else
		# 全部任务模式
		log "=================================================="
		log ">>> AutoSign 全量签到任务启动 <<<"

		if [ "$force_mode" != "force" ] && [ "$random_delay" -gt 0 ]; then
			local seed=$(awk 'BEGIN{srand(); print int(rand()*32768)}')
			local delay=$(( seed % random_delay ))
			log "已启用随机延迟，随机休眠 $delay 秒后开始签到..."
			sleep "$delay"
		fi

		TOTAL_TASKS=0
		SUCCESS_TASKS=0
		FAILED_TASKS=0
		SUMMARY_MSG=""

		config_foreach run_task task

		if [ "$TOTAL_TASKS" -eq 0 ]; then
			log "未检测到任何已启用的签到任务！请在 Web 界面中添加并启用任务。"
		else
			log ">>> 全量签到完成: 共 $TOTAL_TASKS 个任务，成功: $SUCCESS_TASKS，失败: $FAILED_TASKS <<<"
			log "=================================================="

			local notify_title="OpenWrt 每日签到通知"
			local notify_content="签到完成统计: 共 $TOTAL_TASKS 个任务，成功 $SUCCESS_TASKS 个，失败 $FAILED_TASKS 个。详情: $(echo -e "$SUMMARY_MSG")"
			send_notify "$notify_title" "$notify_content" "$notify_type" "$notify_token" "$notify_secret"
		fi
	fi
}

case "$1" in
	run)
		do_run "$2" "$3"
		;;
	clearlog)
		echo "" > "$LOG_FILE"
		log "日志已清空"
		;;
	*)
		echo "用法: $0 {run [task_id|all] [force]|clearlog}"
		exit 1
		;;
esac

