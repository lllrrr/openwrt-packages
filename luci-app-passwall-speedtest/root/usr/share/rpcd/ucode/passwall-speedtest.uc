'use strict';

const fs = require('fs');
const uci = require('uci');

const LOG_FILE = '/tmp/passwall-speedtest.log';
const RESULT_DIR = '/tmp/passwall-speedtest';
const RESULT_FILE = RESULT_DIR + '/result.csv';
const RUN_PID_FILE = RESULT_DIR + '/current_run';
const HISTORY_FILE = '/etc/passwall-speedtest/history.csv';
const RUN_SCRIPT = '/usr/bin/passwall-speedtest/passwall-speedtest.sh';

function command(cmd) {
	let rc = system(cmd);

	return {
		code: rc
	};
}

function command_output(cmd) {
	let pipe = fs.popen(cmd, 'r');
	let out = '';
	let rc = -1;

	if (pipe) {
		out = pipe.read('all') || '';
		rc = pipe.close();
	}

	return {
		code: rc,
		stdout: out
	};
}

function shquote(value) {
	return "'" + replace("" + value, "'", "'\\''") + "'";
}

function read_file(path) {
	if (!fs.access(path, 'f'))
		return '';

	let fd = fs.open(path, 'r');
	let data = '';

	if (fd) {
		data = fd.read('all') || '';
		fd.close();
	}

	return data;
}

function read_lines(path) {
	let content = read_file(path);

	if (content == '')
		return [];

	return split(replace(content, /\r/g, ''), '\n');
}

// 注意：本文件以 'use strict' 开头，ucode 严格模式下函数声明不提升（forward
// reference 会报 undeclared）——被新函数调用的辅助函数必须定义在调用者之前。
function load_config(cur, name) {
	if (!fs.access('/etc/config/' + name, 'f'))
		return false;

	try {
		cur.load(name);
		return true;
	}
	catch (e) {
		return false;
	}
}

function file_size(path) {
	let res = command_output('wc -c < ' + shquote(path) + ' 2>/dev/null');
	let size = int(trim(res.stdout || '') || 0);

	return size > 0 ? size : 0;
}

function read_file_chunk(path, pos, first_tail) {
	if (!fs.access(path, 'f'))
		return { pos: 0, content: '' };

	let size = file_size(path);
	pos = int(pos || 0);

	if (pos < 0 || pos > size)
		pos = 0;

	// 首次加载（pos=0）只取文件末尾 first_tail 字节：长跑日志动辄数 MB，
	// 全量传到前端会把页面拖死（用户实测点击其它页签会崩溃）
	if (pos == 0 && first_tail > 0 && size > first_tail)
		pos = size - first_tail;

	let pipe = fs.popen('dd if=' + shquote(path) + ' bs=1 skip=' + pos + ' count=1048576 2>/dev/null', 'r');
	let content = '';

	if (pipe) {
		content = pipe.read('all') || '';
		pipe.close();
	}

	return {
		pos: pos + length(content),
		content: content
	};
}

function status() {
	let cur = uci.cursor();
	let enabled = '0';

	try {
		cur.load('passwall-speedtest');
		enabled = cur.get('passwall-speedtest', 'global', 'enabled') || '0';
	}
	catch (e) {}

	// 走节点测速无独立二进制进程，用脚本主进程判定运行中
	let running = (command('pgrep -f "[p]asswall-speedtest\\.sh" >/dev/null 2>&1').code == 0);

	return {
		running: running,
		cron: enabled == '1'
	};
}

function start() {
	command('pgrep -f "[p]asswall-speedtest\\.sh" | xargs kill -9 >/dev/null 2>&1');
	command(shquote(RUN_SCRIPT) + ' start >/dev/null 2>&1 &');

	return {};
}

// 复测现有最优 IP：只对当前 result.csv + 各节点现有 address 做一轮延迟 + 下载实测，
// 不重新下载在线列表。不 kill 现有运行——脚本入口的单实例锁会跳过并记一行日志，
// 避免用户误点把正在跑的整轮测速杀掉。
function start_retest() {
	command(shquote(RUN_SCRIPT) + ' retest >/dev/null 2>&1 &');

	return {};
}

// 记录的主进程 PID 是否还活着、且确实是本脚本。只看 /proc/<pid> 存在会被「PID 被无关进程
// 复用」骗过（同脚本 run_lock_acquire 的判据），故再匹配一次 cmdline。
function run_pid_alive(pid) {
	return command('[ -d /proc/' + pid + ' ] && grep -q "passwall-speedtest\\.sh" /proc/' + pid + '/cmdline 2>/dev/null').code == 0;
}

// 本次运行的主进程 PID：脚本在整跑入口把 PID 写进 current_run。取不到、不是纯数字、
// 或进程已不在（上一次运行被强杀留下的 current_run）时返回 null —— 死 PID 的会话目录
// 不能当成本次会话，否则停止标志会写进没人看的目录。
function run_pid() {
	let pid = '';

	try {
		pid = trim(read_file(RUN_PID_FILE) || '');
	}
	catch (e) {
		pid = '';
	}

	return (match(pid, /^[0-9]+$/) && run_pid_alive(pid)) ? pid : null;
}

// 当前会话目录：本次运行的全部中间状态（含 .nt_stop / .iter_stop 停止标志）都在 run.<PID>/ 下，
// 多个整跑并发时互不干扰。取不到（脚本未运行 / 旧版本把状态平铺在 RESULT_DIR）时返回 null。
function run_dir() {
	let pid = run_pid();

	return pid ? RESULT_DIR + '/run.' + pid : null;
}

// 协作式停止：写本次会话的停止标志 .nt_stop，各 worker 跑完当前 IP 自行 break；
// 另写 .iter_stop，限时迭代模式据此在轮间不再开新轮。
// .user_stop 区分「用户手动停止」与「首个 worker 完成后的自动提前停止」（后者写 .auto_stop）：
// 用户停止第一轮后，脚本仍会对已通过的 IP 做完下载实测再写回；自动提前停止则不排队下载。
// 停止的语义是「停止测速，但把已测到的各节点最优 IP 写完再退」：脚本收尾要还原测前快照、
// 原子写回配置、再重启 passwall 才生效，而 passwall 的 restart 会在自己的锁上等最多 600s，
// 所以这里不按固定秒数强杀：进程还活着就一直等；只有没进提交阶段（无 .nt_committing）且
// 长时间不动（真挂死，~120s）才升级信号；进了提交/下载收尾阶段（.nt_committing）则放宽到
// ~1200s 才兜底。强杀只针对记录的 PID 本身，不再 pgrep 通杀 —— 否则会误杀随后新起的那次运行。
function stop() {
	let dir = run_dir();
	let pid = run_pid();

	if (dir == null || pid == null)
		return {};

	command('touch ' + shquote(dir + '/.nt_stop') + ' ' + shquote(dir + '/.iter_stop') + ' ' + shquote(dir + '/.user_stop') + ' 2>/dev/null');
	command('( _w=0; while kill -0 ' + pid + ' 2>/dev/null; do' +
		' if [ -f ' + shquote(dir + '/.nt_committing') + ' ]; then [ "$_w" -ge 1200 ] && break; else [ "$_w" -ge 120 ] && break; fi;' +
		' sleep 3; _w=$((_w + 3));' +
		' done;' +
		' kill -0 ' + pid + ' 2>/dev/null || exit 0;' +
		' kill -INT ' + pid + ' 2>/dev/null;' +
		' sleep 15;' +
		' kill -9 ' + pid + ' 2>/dev/null ) >/dev/null 2>&1 &');

	return {};
}

function get_log(req) {
	let pos = int(req.args.pos || 0);
	let chunk = read_file_chunk(LOG_FILE, pos, (pos == 0) ? 262144 : 0);

	// 原样返回整行（含 [节点] / [保留] 等方括号段）——此前把 [..] 替换成换行
	// 会把节点 ID 和保留/丢弃标签从日志页吞掉，无法按节点核对轮次。
	return {
		pos: chunk.pos,
		content: chunk.content
	};
}

// worker 序号（1 起）：与脚本 worker 遍历顺序一致——node_ip 段（配置顺序）的 node 字段
// 在前，兼容旧 servers.passwall_services 多选追加，按首次出现去重。
// 图表连线按此序号分组：同序号（同一配置行）的历次结果相连。
function worker_ids() {
	let cur = uci.cursor();
	let ids = [];

	if (load_config(cur, 'passwall-speedtest')) {
		cur.foreach('passwall-speedtest', 'node_ip', s => {
			if (s.node && index(ids, s.node) < 0)
				push(ids, s.node);
		});

		let legacy = cur.get('passwall-speedtest', 'servers', 'passwall_services');

		if (type(legacy) == 'array') {
			for (let i = 0; i < length(legacy); i++)
				if (legacy[i] && index(ids, legacy[i]) < 0)
					push(ids, legacy[i]);
		}
		else if (legacy != null && legacy != '') {
			push(ids, legacy);
		}
	}

	return ids;
}

// passwall 节点 section id → remarks（同名 remarks 以先出现者为准）
function remarks_map() {
	let cur = uci.cursor();
	let m = {};

	if (load_config(cur, 'passwall')) {
		cur.foreach('passwall', 'nodes', s => {
			if (s.remarks && m[s['.name']] == null)
				m[s['.name']] = s.remarks;
		});
	}

	return m;
}

// 解析一次运行的结果文件：全局最优（首条数据行）+ 各节点自己的最优
// （result.csv 全局延迟升序，某节点末列值首次出现的行即该节点最优）。
// 节点不在 worker 配置内（如被移除/改名）时 idx 为 null，前端按节点名独立展示不连线。
function parse_run_file(path, idx_of_remarks) {
	let lines = read_lines(path);
	let time = null;
	let best = null;
	let nodes = [];
	let seen = {};
	let header = '';

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i] != null ? lines[i] : '');

		if (line == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			let m = match(line, /^# Speed test time: (.+)$/);

			if (m)
				time = m[1];

			continue;
		}

		// 首个非注释行是表头，不能当作数据行（否则会混入「IP 地址」全局最优与「节点」假分组）
		if (header == '') {
			header = line;
			continue;
		}

		let parts = split(line, ',');

		if (length(parts) < 7)
			continue;

		// 8 列 = ...,地区码,节点；7 列 = 旧格式无节点列，末列即地区码
		let node = (length(parts) >= 8) ? parts[length(parts) - 1] : '';

		if (!best)
			best = { ip: parts[0], latency: +parts[4] || 0, speed: +parts[5] || 0, region: parts[6] };

		if (node != '' && !seen[node]) {
			seen[node] = true;
			push(nodes, {
				node: node,
				idx: (idx_of_remarks[node] != null) ? idx_of_remarks[node] : null,
				ip: parts[0],
				latency: +parts[4] || 0,
				speed: +parts[5] || 0,
				region: parts[6] || ''
			});
		}
	}

	if (!best || !time)
		return null;

	return {
		time: time,
		ip: best.ip,
		region: best.region,
		latency: best.latency,
		speed: best.speed,
		nodes: nodes
	};
}

// 解析持久历史文件（/etc/passwall-speedtest/history.csv）：多个
// "# Speed test time: ..." 块，每块数据行 = 该次各节点最优（全局延迟升序去重首现）。
// 修剪可能产生无时间头的孤立数据行，直接忽略（cur 为空时跳过）。
function parse_history_file(path, idx_of_remarks) {
	let lines = read_lines(path);
	let runs = [];
	let cur = null;

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i] != null ? lines[i] : '');

		if (line == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			let m = match(line, /^# Speed test time: (.+)$/);

			if (m) {
				cur = { time: m[1], best: null, nodes: [], seen: {} };
				push(runs, cur);
			}

			continue;
		}

		if (cur == null)
			continue;

		let parts = split(line, ',');

		if (length(parts) < 7)
			continue;

		let node = (length(parts) >= 8) ? parts[length(parts) - 1] : '';

		if (!cur.best)
			cur.best = { ip: parts[0], latency: +parts[4] || 0, speed: +parts[5] || 0, region: parts[6] };

		if (node != '' && !cur.seen[node]) {
			cur.seen[node] = true;
			push(cur.nodes, {
				node: node,
				idx: (idx_of_remarks[node] != null) ? idx_of_remarks[node] : null,
				ip: parts[0],
				latency: +parts[4] || 0,
				speed: +parts[5] || 0,
				region: parts[6] || ''
			});
		}
	}

	let out = [];

	for (let i = 0; i < length(runs); i++) {
		let r = runs[i];

		if (r.best)
			push(out, {
				time: r.time,
				ip: r.best.ip,
				region: r.best.region,
				latency: r.best.latency,
				speed: r.best.speed,
				nodes: r.nodes
			});
	}

	return out;
}

function get_history() {
	let history = [];
	let idx_of_remarks = {};
	let workers = worker_ids();
	let remarks = remarks_map();

	for (let i = 0; i < length(workers); i++) {
		let r = remarks[workers[i]];

		if (r != null && idx_of_remarks[r] == null)
			idx_of_remarks[r] = i + 1;
	}

	// 持久历史为主（/etc 下，重启与轮转不清）；尚无归档时回退 /tmp 轮转文件（老安装）
	history = parse_history_file(HISTORY_FILE, idx_of_remarks);

	if (!length(history)) {
		let item = parse_run_file(RESULT_FILE, idx_of_remarks);

		if (item)
			push(history, item);

		for (let i = 1; i <= 9; i++) {
			item = parse_run_file(RESULT_FILE + '.' + i, idx_of_remarks);

			if (item)
				push(history, item);
		}
	}

	sort(history, (a, b) => b.time > a.time ? 1 : (b.time < a.time ? -1 : 0));

	return {
		history: history
	};
}

function get_best_result() {
	let lines = read_lines(RESULT_FILE);
	// 按节点独立排序展示：result.csv 本身保持全局排序（有下载实测速度时按吞吐降序，
	// 否则按延迟升序；DNS 取全局最优/前 N 依赖首行序），此处在展示层按末列节点分组——
	// 全局序里同一节点的行仍保序，每组首行即该节点自己的最优 IP。节点顺序 = 其最优 IP
	// 在全局排序中首次出现的顺序。
	// 全量展示（日志的「其余 N 条见最佳 IP 表」指向这里），不再截尾 500 行。
	let header = '';
	let time_line = '';
	let order = [];
	let rows = {};

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i] != null ? lines[i] : '');

		if (line == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			if (match(line, /^# Speed test time:/))
				time_line = line;

			continue;
		}

		if (header == '') {
			header = line;
			continue;
		}

		let parts = split(line, ',');
		let node = (length(parts) > 0) ? parts[length(parts) - 1] : '';

		if (!rows[node]) {
			rows[node] = [];
			push(order, node);
		}

		push(rows[node], line);
	}

	let out = [];

	if (header != '')
		push(out, header);

	for (let i = 0; i < length(order); i++) {
		let node_rows = rows[order[i]];
		let best = (length(node_rows) > 0) ? split(node_rows[0], ',') : [];

		let best_speed = +best[5] || 0;

		push(out, '# ── ' + (order[i] != '' ? order[i] : '(无节点)') +
			'：最优 ' + (best[0] || '-') + ' / ' + (best[4] || '-') + 'ms' +
			(best_speed > 0 ? (' / ' + best[5] + ' MB/s') : '') +
			'，共 ' + length(node_rows) + ' 条 ──');

		for (let j = 0; j < length(node_rows); j++)
			push(out, node_rows[j]);
	}

	if (time_line != '')
		push(out, time_line);

	return {
		content: join('\n', out)
	};
}

function add_node(nodes, name, label, type) {
	if (name)
		push(nodes, { value: name, label: label || name, type: type || '' });
}

function sorted_nodes(nodes) {
	sort(nodes, (a, b) => a.value > b.value ? 1 : (a.value < b.value ? -1 : 0));
	return nodes;
}

function list_nodes() {
	let cur = uci.cursor();
	let result = {};
	let nodes;

	nodes = [];
	if (load_config(cur, 'shadowsocksr')) {
		cur.foreach('shadowsocksr', 'servers', s => {
			let proto = uc(s.v2ray_protocol || s.type || '');

			if (s.alias)
				add_node(nodes, s['.name'], `[${proto}]:${s.alias}`);
			else if (s.server && s.server_port)
				add_node(nodes, s['.name'], `[${proto}]:${s.server}:${s.server_port}`);
		});
		result.ssr = { exists: true, nodes: sorted_nodes(nodes) };
	}
	else {
		result.ssr = { exists: false, nodes: [] };
	}

	nodes = [];
	if (load_config(cur, 'passwall')) {
		cur.foreach('passwall', 'nodes', s => {
			if (s.remarks)
				add_node(nodes, s['.name'], `[${uc(s.protocol || s.type || '')}]:${s.remarks}`, uc(s.type || ''));
		});
		result.passwall = { exists: true, nodes: sorted_nodes(nodes) };
	}
	else {
		result.passwall = { exists: false, nodes: [] };
	}

	nodes = [];
	if (load_config(cur, 'passwall2')) {
		cur.foreach('passwall2', 'nodes', s => {
			if (s.remarks)
				add_node(nodes, s['.name'], `[${uc(s.protocol || s.type || '')}]:${s.remarks}`, uc(s.type || ''));
		});
		result.passwall2 = { exists: true, nodes: sorted_nodes(nodes) };
	}
	else {
		result.passwall2 = { exists: false, nodes: [] };
	}

	nodes = [];
	if (load_config(cur, 'bypass')) {
		cur.foreach('bypass', 'servers', s => {
			let proto = uc(s.protocol || s.type || '');

			if (s.alias)
				add_node(nodes, s['.name'], `[${proto}]:${s.alias}`);
			else if (s.server && s.server_port)
				add_node(nodes, s['.name'], `[${proto}]:${s.server}:${s.server_port}`);
		});
		result.bypass = { exists: true, nodes: sorted_nodes(nodes) };
	}
	else {
		result.bypass = { exists: false, nodes: [] };
	}

	nodes = [];
	if (load_config(cur, 'vssr')) {
		cur.foreach('vssr', 'servers', s => {
			let proto = uc(s.protocol || s.type || '');

			if (s.alias)
				add_node(nodes, s['.name'], `[${proto}]:${s.alias}`);
			else if (s.server && s.server_port)
				add_node(nodes, s['.name'], `[${proto}]:${s.server}:${s.server_port}`);
		});
		result.vssr = { exists: true, nodes: sorted_nodes(nodes) };
	}
	else {
		result.vssr = { exists: false, nodes: [] };
	}

	return result;
}

return {
	'passwall-speedtest': {
		status: {
			call: function() {
				return status();
			}
		},

		start: {
			call: function() {
				return start();
			}
		},

		start_retest: {
			call: function() {
				return start_retest();
			}
		},

		stop: {
			call: function() {
				return stop();
			}
		},

		get_log: {
			args: {
				pos: 0
			},
			call: function(req) {
				return get_log(req);
			}
		},

		get_history: {
			call: function() {
				return get_history();
			}
		},

		get_best_result: {
			call: function() {
				return get_best_result();
			}
		},

		list_nodes: {
			call: function() {
				return list_nodes();
			}
		}
	}
};
