#!/bin/sh
# 决定性实验：busybox grep -o 读「文件」vs 读「管道」的可靠性差异
EPG="https://live.fanmingming.cn/e.xml"
cd /tmp

echo "=== 1. 先稳定落盘一份 ==="
curl -s -L -m 60 -o /tmp/epgfix.xml "$EPG"
B=$(wc -c < /tmp/epgfix.xml)
echo "bytes=$B"
echo "grep -c '<channel' = $(grep -c '<channel' /tmp/epgfix.xml)"

echo ""
echo "=== 2. 同一份文件：grep -o 直接读文件 vs 经 cat 管道（各 3 轮，无网络）==="
i=1
while [ $i -le 3 ]; do
  A=$(grep -o '<channel[^>]*id="[^"]*"' /tmp/epgfix.xml | wc -l)
  Bp=$(cat /tmp/epgfix.xml | grep -o '<channel[^>]*id="[^"]*"' | wc -l)
  C=$(sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgfix.xml | sort -u | wc -l)
  D=$(cat /tmp/epgfix.xml | sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' | sort -u | wc -l)
  echo "轮$i: grep读文件=$A  grep读管道=$Bp  sed读文件=$C  sed读管道=$D"
  i=$((i+1))
done

echo ""
echo "=== 3. curl 进管道（tee 落盘），2 轮 ==="
i=1
while [ $i -le 2 ]; do
  N=$(curl -s -L -m 60 "$EPG" | tee /tmp/pipe$i.xml | wc -c)
  G=$(grep -o '<channel[^>]*id="[^"]*"' /tmp/pipe$i.xml | wc -l)
  S=$(sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/pipe$i.xml | sort -u | wc -l)
  echo "轮$i: 管道字节=$N  落盘后grep=$G  落盘后sed=$S"
  i=$((i+1))
done

echo ""
echo "=== 4. 原样管道（curl 直接进 grep），3 轮 ==="
i=1
while [ $i -le 3 ]; do
  R=$(curl -s -L -m 60 "$EPG" | grep -o '<channel[^>]*id="[^"]*"' | sed 's/.*id="//;s/"//' | sort -u | wc -l)
  echo "轮$i: curl|grep -o|sed|sort -u = $R 行"
  i=$((i+1))
done

echo ""
echo "=== 5. 原样管道换 sed，3 轮 ==="
i=1
while [ $i -le 3 ]; do
  R=$(curl -s -L -m 60 "$EPG" | sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' | sort -u | wc -l)
  echo "轮$i: curl|sed|sort -u = $R 行"
  i=$((i+1))
done

echo ""
echo "=== 6. sed 结果的真实内容抽样（确认 124 个 id 正确）==="
sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/epgfix.xml | sort -u > /tmp/epg-final.txt
echo "总数=$(wc -l < /tmp/epg-final.txt)"
cat /tmp/epg-final.txt

echo ""
echo "=== 7. 清理 ==="
rm -f /tmp/pipe1.xml /tmp/pipe2.xml
echo done
