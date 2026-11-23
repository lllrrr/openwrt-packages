'use strict';
// 智能分流界面的 rpc：转接到 /usr/bin/smartroute，另提供设备扫描、配置导入导出。
// 参数在交给 shell 前按严格格式校验。错误信息为英文，界面负责翻译。

import { popen, readfile, writefile, stat, mkdir } from 'fs';

const BIN = '/usr/bin/smartroute';
const RE_MAC = /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/;
const RE_IP4 = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const RE_TARGET = /^[A-Za-z0-9.:_-]{1,253}$/;

function sh(cmd) {
	const p = popen(cmd, 'r');
	if (!p)
		return null;
	const out = p.read('all');
	p.close();
	return out;
}

// 命令输出 JSON 时解析，否则把输出当作错误信息
function run(cmd) {
	const out = sh(cmd + ' 2>&1');
	try {
		return json(out);
	}
	catch (e) {
		return { error: trim(out ?? '') || 'Command failed' };
	}
}

const methods = {
	status: {
		call: function() {
			return run(`${BIN} status`);
		}
	},

	trace: {
		args: { device: 'device', target: 'target' },
		call: function(req) {
			const d = req.args?.device, t = req.args?.target;
			if (!(match(d, RE_MAC) || match(d, RE_IP4)) || !match(t, RE_TARGET))
				return { error: 'The device must be a MAC or IPv4 address and the target a domain name or IP address' };
			return run(`${BIN} trace ${d} ${t}`);
		}
	},

	dns: {
		args: { q: 'q' },
		call: function(req) {
			const q = req.args?.q ?? '';
			if (q != '' && !match(q, RE_TARGET))
				return { error: 'Enter a domain name or IP address' };
			const r = run(`${BIN} dns ${q}`);
			return type(r) == 'array' ? { records: r } : r;
		}
	},

	cats: {
		call: function() {
			return run(`${BIN} cats`);
		}
	},

	update: {
		call: function() {
			system(`${BIN} update >/dev/null 2>&1 &`);
			return {};
		}
	},

	// 重新应用配置（重新解析网关 MAC 与 IPv6 下一跳）
	reload: {
		call: function() {
			system('/etc/init.d/smartroute reload >/dev/null 2>&1');
			return {};
		}
	},

	// 扫描局域网设备：DHCP 租约 + IPv4 邻居表；厂商按 MAC 前缀查 oui.txt（本地管理的随机 MAC 没有厂商）
	scan: {
		call: function() {
			const devs = {};
			for (let line in split(readfile('/tmp/dhcp.leases') ?? '', '\n')) {
				const f = split(trim(line), ' ');
				if (length(f) >= 4 && match(f[1], RE_MAC))
					devs[lc(f[1])] = { mac: lc(f[1]), ip: f[2], host: f[3] == '*' ? '' : f[3], online: false };
			}
			for (let line in split(sh('ip -4 neigh show') ?? '', '\n')) {
				const m = match(line, /^([0-9.]+) dev ([^ ]+) lladdr ([0-9a-fA-F:]+) (.*)$/);
				if (!m)
					continue;
				const mac = lc(m[3]);
				devs[mac] ??= { mac: mac, host: '' };
				devs[mac].ip = m[1];
				devs[mac].online = !match(m[4], /FAILED|INCOMPLETE/);
			}
			const list = values(devs);
			const pre = uniq(map(filter(list, d => !match(d.mac, /^.[26ae]/)), d => uc(replace(substr(d.mac, 0, 8), /:/g, ''))));
			if (length(pre) && stat('/usr/share/smartroute/oui.txt')) {
				const vendor = {};
				for (let line in split(sh(`grep -E '^(${join('|', pre)}) ' /usr/share/smartroute/oui.txt`) ?? '', '\n'))
					if (length(line) > 7)
						vendor[substr(line, 0, 6)] = substr(line, 7);
				for (let d in list)
					d.vendor = vendor[uc(replace(substr(d.mac, 0, 8), /:/g, ''))];
			}
			return { devices: list };
		}
	},

	// 诊断与出口页用的系统信息；networks：netifd 逻辑接口（接口出口从中选择）
	info: {
		call: function() {
			let networks = [];
			try {
				for (let i in json(sh('ubus call network.interface dump') ?? '{}').interface ?? [])
					if (i.interface != 'loopback')
						push(networks, { name: i.interface, device: i.l3_device ?? i.device ?? '', up: !!i.up });
			}
			catch (e) {}
			return {
				kernel: trim(readfile('/proc/sys/kernel/osrelease') ?? ''),
				networks: networks,
				// ImmortalWrt 的 DNS 劫持（dnsmasq dns_redirect）：出口页据此提示网关的“不被劫持”选项是否起作用
				dns_redirect: match(sh('uci -q show dhcp') ?? '', /\.dns_redirect='1'/) != null
			};
		}
	},

	export: {
		call: function() {
			return { data: readfile('/etc/config/smartroute') ?? '' };
		}
	},

	// 导入配置：先在临时目录用 uci 校验，通过后替换并立即生效
	import: {
		args: { data: 'data' },
		call: function(req) {
			const data = req.args?.data ?? '';
			if (length(data) == 0 || length(data) > 1048576)
				return { error: 'The configuration is empty or too large' };
			mkdir('/tmp/smartroute-import');
			writefile('/tmp/smartroute-import/smartroute', data);
			if (system('uci -c /tmp/smartroute-import show smartroute >/dev/null 2>&1') != 0 ||
			    system('uci -c /tmp/smartroute-import -q get smartroute.main >/dev/null 2>&1') != 0)
				return { error: 'Not a valid SmartRoute configuration' };
			system('cp /tmp/smartroute-import/smartroute /etc/config/smartroute; rm -rf /tmp/smartroute-import; /etc/init.d/smartroute reload >/dev/null 2>&1');
			return {};
		}
	}
};

return { smartroute: methods };
