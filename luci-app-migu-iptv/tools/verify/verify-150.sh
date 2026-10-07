#!/bin/sh
# verify-150.sh — 1.5.0 功能验收：外部源两段式检查路径、频道取流、统计字段
set -x

echo "==== 1. 外部源直连 pid=9001（触发 checkExternalSource 两段式）===="
curl -s -m 15 -o /dev/null -w "pid9001 HTTP=%{http_code} TIME=%{time_total}s\n" http://127.0.0.1:8788/ch/9001 || echo "pid9001 FAIL"

echo "==== 2. 真实频道取流（冷/热）===="
curl -s -m 15 -o /dev/null -w "ch-cold HTTP=%{http_code} TIME=%{time_total}s\n" http://127.0.0.1:8788/ch/608807420
curl -s -m 15 -o /dev/null -w "ch-hot  HTTP=%{http_code} TIME=%{time_total}s\n" http://127.0.0.1:8788/ch/608807420

echo "==== 3. /health 关键字段 ===="
curl -s -m 5 http://127.0.0.1:8788/health | tr ',' '\n' | grep -E '"version"|"streamTtl"|"epgIds"|"epgOk"|"epgAge"|"chFallback"|"activeConns"|"maxConns"|"rejectedByLimit"|"denied"'

echo "==== 4. 崩溃类日志（部署后）===="
logread | grep -iE "migu.*(Syntax error|Reference error|not a function|Type error)" | tail -n 20 || echo "无崩溃类日志"

echo "==== 5. 外部源探测日志（应见 外部源不可用/连续失败 或 成功 记录）===="
logread | grep -iE "外部源" | tail -n 10

echo "==== 6. EPG 状态 ===="
ls -l /tmp/.migu-epg.lm 2>/dev/null
cat /tmp/.migu-epg.lm 2>/dev/null
echo
echo "DONE_VERIFY_150"