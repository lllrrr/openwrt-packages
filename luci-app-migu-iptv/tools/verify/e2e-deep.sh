#!/bin/sh
# 深链验证：master -> variant -> TS 分片，确认真的出画面数据
P=$(pgrep -f 'migu.uc' | head -1)

LOC=$(curl -s -D - -o /dev/null http://127.0.0.1:8788/ch/608807420 | sed -n 's/^[Ll]ocation: //p' | tr -d '\r')
curl -s -L -m 20 "$LOC" -o /tmp/l1.m3u8

V=$(grep -v '^#' /tmp/l1.m3u8 | head -1)
case "$V" in
  http*) VURL="$V" ;;
  *)     VURL="$(echo "$LOC" | sed 's#/[^/]*$#/#' )$V" ;;
esac
echo "=== variant 播放列表 ==="
echo "URL 前缀: $(echo "$VURL" | cut -c1-70)..."
curl -s -L -m 20 "$VURL" -o /tmp/l2.m3u8 -w 'code=%{http_code} bytes=%{size_download}\n'
echo "variant 里 EXTINF 条数: $(grep -c '^#EXTINF' /tmp/l2.m3u8)"
head -c 300 /tmp/l2.m3u8; echo

S=$(grep -v '^#' /tmp/l2.m3u8 | head -1)
case "$S" in
  http*) SURL="$S" ;;
  *)     SURL="$(echo "$VURL" | sed 's#/[^/]*$#/#' )$S" ;;
esac
echo
echo "=== TS 分片 ==="
curl -s -L -m 25 "$SURL" -o /tmp/seg.ts -w 'code=%{http_code} bytes=%{size_download} speed=%{speed_download}B/s time=%{time_total}s\n'
echo "大小: $(wc -c < /tmp/seg.ts) 字节"
echo "首 16 字节 (TS 应为 0x47 开头):"
hexdump -C -n 16 /tmp/seg.ts
echo "0x47 同步字节在前 2KB 内的出现次数: $(head -c 2048 /tmp/seg.ts | od -An -tx1 | tr ' ' '\n' | grep -c '^47$')"
echo "被识别为 MPEG-TS 的特征 (file 命令若可用):"
file /tmp/seg.ts 2>/dev/null || echo "(无 file 命令)"
echo
echo "=== 通过 8788 端口完整走一遍（含 302 跟随）==="
curl -s -L -m 30 -r 0-200000 http://127.0.0.1:8788/ch/608807420 -o /tmp/via8788.bin -w 'code=%{http_code} bytes=%{size_download} time=%{time_total}s\n'
echo "首 16 字节:"
hexdump -C -n 16 /tmp/via8788.bin

echo
echo "=== 订阅地址可用性（TV-BOX 场景）==="
curl -s -o /dev/null -w '/m3u code=%{http_code} bytes=%{size_download} time=%{time_total}s\n' http://127.0.0.1:8788/m3u
curl -s -o /dev/null -w '/txt code=%{http_code} bytes=%{size_download} time=%{time_total}s\n' http://127.0.0.1:8788/txt
TOK=${PUBLIC_TOKEN}
curl -s -o /dev/null -w "公网风格 /$TOK/m3u code=%{http_code} bytes=%{size_download}\n" http://127.0.0.1:8788/$TOK/m3u
curl -s -o /dev/null -w "查询串 /m3u?token= code=%{http_code} bytes=%{size_download}\n" "http://127.0.0.1:8788/m3u?token=$TOK"
curl -s -o /dev/null -w "错误令牌 /m3u?token=bad code=%{http_code}\n" "http://127.0.0.1:8788/m3u?token=bad"

echo
echo "=== 最终 /health ==="
curl -s http://127.0.0.1:8788/health
