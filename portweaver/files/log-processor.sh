#!/bin/sh
# PortWeaver Log Processor - Real-time log rotation handler
LOG_FILE="${1:-/tmp/portweaver.log}"
MAX_SIZE=$((${2:-1024} * 1024))
MAX_FILES=${3:-3}
CHECK_INTERVAL=0

rotate() {
	local i
	for i in $(seq $((MAX_FILES - 1)) -1 1); do
		[ -f "${LOG_FILE}.$i" ] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i + 1))" 2>/dev/null
	done
	[ -f "$LOG_FILE" ] && mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
	rm -f "${LOG_FILE}.$((MAX_FILES + 1))" 2>/dev/null
}

while IFS= read -r line; do
	echo "$line" >> "$LOG_FILE"
	CHECK_INTERVAL=$((CHECK_INTERVAL + 1))
	[ $CHECK_INTERVAL -lt 50 ] && continue
	CHECK_INTERVAL=0
	[ $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) -ge $MAX_SIZE ] && rotate
done
