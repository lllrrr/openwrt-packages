#!/bin/sh
# 1.3.1 EPG 修复效果验证
echo "=== /m3u 输出 ==="
curl -s -m 15 http://127.0.0.1:8788/m3u > /tmp/m3u131.txt
echo "bytes=$(wc -c < /tmp/m3u131.txt)"
echo "EXTINF 总数=$(grep -c '^#EXTINF' /tmp/m3u131.txt)"

echo ""
echo "--- 前 6 行（含 x-tvg-url）---"
head -6 /tmp/m3u131.txt

echo ""
echo "--- 前 12 个 tvg-id ---"
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | head -12

echo ""
echo "=== 决定性对比 ==="
echo -n "仍是中文名(频道名)的条数，改造前 174: "
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | grep -c '[综合体育高清影视新闻纪录少儿]'

echo -n "已映射成标准 id 的条数: "
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | grep -cE 'tvg-id="(CCTV[0-9]+|CCTV5\+|CCTV4K|CGTN|CETV|东方卫视|凤凰|CHC|湖南卫视|浙江卫视|江苏卫视|北京卫视|广东卫视|深圳卫视|湖北卫视|安徽卫视|山东卫视|天津卫视|重庆卫视|四川卫视|河南卫视|辽宁卫视|黑龙江卫视|江西卫视|贵州卫视|云南卫视|广西卫视|甘肃卫视|宁夏卫视|青海卫视|新疆卫视|西藏卫视|内蒙古卫视|吉林卫视|河北卫视|山西卫视|陕西卫视|福建东南卫视|海南卫视|厦门卫视|兵团卫视|延边卫视|三沙卫视|海峡卫视|南方卫视|嘉佳卡通|金鹰卡通|卡酷少儿|优漫卡通|哈哈炫动|炫动卡通|CGTN俄语|CGTN纪录|CGTN阿拉伯语|CCTV中视购物|CCTV发现之旅|CCTV老故事|CCTV证券资讯|CCTV新科动漫|CCTV文化精品|CCTV电视指南|CCTV女性时尚|CCTV卫生健康|CCTV风云音乐|CCTV风云足球|CCTV风云剧场|CCTV第一剧场|CCTV怀旧剧场|CCTV高尔夫网球|CCTV国防军事|CCTV世界地理|CCTV兵器科技|CCTV央视台球|CCTV汽摩|CCTV乡土|CCTV戏曲|CCTV音乐|CCTV体育|CCTV电影|CCTV电视剧|CCTV科教|CCTV社会与法|CCTV新闻|CCTV少儿|CCTV军事农业|CCTV纪录|CCTV综合|CCTV财经|CCTV综艺|CCTV中文国际|CCTV体育赛事)'

echo ""
echo "--- 未映射到标准 id 的前 20 条（看是哪些频道）---"
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | grep -vE 'tvg-id="(CCTV[0-9]+|CCTV5\+|CCTV4K|CGTN|CETV)' | grep '[综合体育高清影视新闻纪录少儿]' | sort -u | head -20

echo ""
echo "=== 全量 tvg-id 去重清单 ==="
grep -o 'tvg-id="[^"]*"' /tmp/m3u131.txt | sort -u | head -60
