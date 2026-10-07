#!/bin/sh
# 1.3.0 部署后验证 + 前后对比基准
B=http://127.0.0.1:8788

echo "=== A. EPG 是否已拉取 ==="
curl -s -m 10 $B/health | tr ',' '\n' | grep -E "epg|version|streamTtl|failTtl|maxConns"

echo ""
echo "=== B. /m3u 输出（前 12 行，看 x-tvg-url 与 tvg-id）==="
curl -s -m 15 $B/m3u > /tmp/m3u-130.txt
wc -c /tmp/m3u-130.txt
head -12 /tmp/m3u-130.txt

echo ""
echo "=== C. tvg-id 映射抽样 ==="
grep -o 'tvg-id="[^"]*"' /tmp/m3u-130.txt | head -20
echo "--- 统计：仍然用中文名的（含「综合/体育/高清」等后缀的）---"
grep -c 'tvg-id="[^"]*[综合体育高清影视新闻纪录少儿]' /tmp/m3u-130.txt || true

echo ""
echo "=== D. 取流缓存 TTL 验证（关键改动）==="
echo "--- 第一次（冷，应 ~500-1200ms）---"
curl -s -m 30 -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" $B/ch/641886681
echo "--- 第二次（热，应 ~2ms）---"
curl -s -m 30 -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" $B/ch/641886681
echo "--- 第三次（热）---"
curl -s -m 30 -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" $B/ch/641886681

echo ""
echo "=== E. 缓存有效性：等 65 秒后（旧版 TTL=60 已过期，新版 TTL=300 应仍命中）==="
echo "（跳过等待，用 /health 的 streamCacheOk 判断）"
curl -s -m 10 $B/health | tr ',' '\n' | grep -E "streamCache|chCache|chHit|avgResolve"

echo ""
echo "=== F. 多个频道冷/热对比 ==="
for P in 641886684 641886685 641886686; do
  C=$(curl -s -m 30 -o /dev/null -w "%{time_total}" $B/ch/$P)
  H=$(curl -s -m 30 -o /dev/null -w "%{time_total}" $B/ch/$P)
  echo "pid=$P 冷=${C}s 热=${H}s"
done

echo ""
echo "=== G. 无效 pid 失败缓存验证（failTtl=15）==="
echo "--- 第 1 次（冷，走完整降级链，应较慢）---"
curl -s -m 40 -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" $B/ch/99999999
echo "--- 第 2 次（应命中失败缓存，明显快）---"
curl -s -m 40 -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" $B/ch/99999999

echo ""
echo "=== H. 并发测试（3 个未缓存频道同时）==="
for P in 641886690 641886691 641886692; do
  ( curl -s -m 30 -o /dev/null -w "pid=$P time=%{time_total}s\n" $B/ch/$P ) &
done
wait

echo ""
echo "=== I. 内存与 fd（对比改造前 VmRSS 2920kB / fd 10）==="
PID=$(pgrep -f "[m]igu.uc" | head -1)
grep -E "VmRSS|Threads" /proc/$PID/status
echo "fd 数量: $(ls /proc/$PID/fd | wc -l)"

echo ""
echo "=== J. 最终 /health ==="
curl -s -m 10 $B/health
