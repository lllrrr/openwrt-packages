#!/usr/bin/ucode
// 排查：curl 在 ucode popen 环境里是否行为异常（步骤3出现 0.0s 瞬间失败）
import { popen } from 'fs';

function sh(cmd) {
	let p = popen(cmd, 'r');
	if (!p) { printf('  popen 返回 null\n'); return ''; }
	let o = p.read('all');
	p.close();
	return o;
}

printf('=== A. 同步 curl（前台，popen 直读）===\n');
let t0 = time();
let r1 = sh("curl -s -L -m 30 -o /tmp/pa.xml -w 'code=%{http_code} size=%{size_download}' https://live.fanmingming.cn/e.xml 2>&1");
printf('  结果=[%s] 耗时=%.1fs\n', trim(r1), time() - t0);
printf('  文件字节=%s\n', trim(sh('wc -c < /tmp/pa.xml 2>/dev/null || echo NONE')));

printf('\n=== B. 同样命令但输出重定向到文件再读（隔离 stdout 影响）===\n');
t0 = time();
sh("curl -s -L -m 30 -o /tmp/pb.xml https://live.fanmingming.cn/e.xml > /tmp/pb.log 2>&1");
printf('  耗时=%.1fs 文件字节=%s\n', time() - t0, trim(sh('wc -c < /tmp/pb.xml 2>/dev/null || echo NONE')));

printf('\n=== C. 后台化 + 轮询（服务采用的形态）===\n');
sh('rm -f /tmp/pc.xml /tmp/pc.done');
t0 = time();
sh("( curl -s -L -m 30 -o /tmp/pc.xml https://live.fanmingming.cn/e.xml; wc -c < /tmp/pc.xml > /tmp/pc.done ) >/dev/null 2>&1 &");
printf('  启动耗时=%.2fs（应接近 0）\n', time() - t0);
let n = 0, done = '';
while (n < 20) {
	n++;
	sleep(1);
	done = trim(sh('cat /tmp/pc.done 2>/dev/null'));
	if (done !== '') break;
}
printf('  等待 %ds 后 done=[%s]\n', n, done);

printf('\n=== D. 检查 PATH / 环境是否在 popen 下不同 ===\n');
printf('  PATH=%s\n', trim(sh('echo $PATH')));
printf('  which curl=%s\n', trim(sh('which curl')));
printf('  curl 版本=%s\n', trim(sh('curl --version | head -1')));

printf('\n=== E. 完整校验（服务里用的判据）===\n');
let c = trim(sh('if [ -s /tmp/pc.xml ] && tail -c 200 /tmp/pc.xml | grep -q "</tv>"; then echo COMPLETE; else echo TRUNCATED; fi'));
printf('  /tmp/pc.xml 判定=%s 字节=%s\n', c, trim(sh('wc -c < /tmp/pc.xml 2>/dev/null || echo 0')));
let ids = trim(sh("sed -n 's/.*<channel[^>]*id=\"\\([^\"]*\\)\".*/\\1/p' /tmp/pc.xml | sort -u | wc -l"));
printf('  解析出 id 数=%s\n', ids);

printf('\n=== F. 服务器是否支持断点续传（决定能否用 -C - 加固）===\n');
printf('  Range 请求响应:\n');
printf('%s\n', sh("curl -s -L -m 20 -r 0-99 -o /dev/null -w 'code=%{http_code} size=%{size_download}' https://live.fanmingming.cn/e.xml"));
printf('\n  Accept-Ranges 头: [%s]\n', trim(sh("curl -s -I -m 20 https://live.fanmingming.cn/e.xml | grep -i 'accept-ranges'")));
