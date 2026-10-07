#!/bin/sh
# 隔离：curl 到管道 vs curl 到文件 —— 重复 3 轮
EPG="https://live.fanmingming.cn/e.xml"
cd /tmp

echo "=== A. curl 到管道拿到的字节数（3 轮）==="
i=1
while [ $i -le 3 ]; do
  N=$(curl -s -L -m 60 "$EPG" | wc -c)
  echo "第 $i 轮: 管道字节 = $N"
  i=$((i+1))
done

echo ""
echo "=== B. curl 到文件拿到的字节数（3 轮）==="
i=1
while [ $i -le 3 ]; do
  curl -s -L -m 60 -o /tmp/e$i.xml "$EPG"
  echo "第 $i 轮: 文件字节 = $(wc -c < /tmp/e$i.xml)"
  i=$((i+1))
done

echo ""
echo "=== C. 对同一个已落盘文件跑原管道（排除网络）==="
echo "grep -o 计数: $(grep -o '<channel[^>]*id="[^"]*"' /tmp/e1.xml | wc -l)"
echo "grep -o|sed|sort -u: $(grep -o '<channel[^>]*id="[^"]*"' /tmp/e1.xml | sed 's/.*id="//;s/"//' | sort -u | wc -l)"
echo "sed|sort -u: $(sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' /tmp/e1.xml | sort -u | wc -l)"

echo ""
echo "=== D. 把文件 cat 进管道，再跑一次（模拟管道输入但内容确定）==="
echo "cat|grep -o: $(cat /tmp/e1.xml | grep -o '<channel[^>]*id="[^"]*"' | wc -l)"
echo "cat|sed|sort -u: $(cat /tmp/e1.xml | sed -n 's/.*<channel[^>]*id="\([^"]*\)".*/\1/p' | sort -u | wc -l)"

echo ""
echo "=== E. curl 到管道的头部内容（看是否拿到错误页）==="
curl -s -L -m 60 "$EPG" | head -c 300
echo ""
echo "--- 管道前 300 字节的字节数 ---"
curl -s -L -m 60 "$EPG" | head -c 300 | wc -c

echo ""
echo "=== F. curl 是否支持 --compressed / 服务器是否 gzip ==="
curl -s -I -L -m 30 "$EPG" 2>&1 | head -20

echo ""
echo "=== G. 内存状态 ==="
free | head -3

echo ""
echo "=== H. 清理 ==="
rm -f /tmp/e1.xml /tmp/e2.xml /tmp/e3.xml
echo done
