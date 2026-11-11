'use strict';

const fs = require('fs');
const uci = require('uci');

const LOG_FILE = '/tmp/cfpick.log';
const RESULT_DIR = '/tmp/cfpick';
const RESULT_FILE = RESULT_DIR + '/result.csv';
const RUN_PID_FILE = RESULT_DIR + '/current_run';
const RUN_LOCK_DIR = RESULT_DIR + '/.run.lock';
// 按 worker 并发的任务登记表：每个运行写一个 /tmp/cfpick/.runs/<pid>。
const RUN_REGISTRY = RESULT_DIR + '/.runs';
// 与 cfpick.sh 保持一致：下载/写回使用一个全局锁，锁被占用时节点页按钮全禁用。
const COMMIT_LOCK_DIR = RESULT_DIR + '/.commit.lock';
// 成功后监测：每个成功 worker 一个后台 monitor（锁 + 最近一次复测状态）。
const MONITOR_LOCK_ROOT = RESULT_DIR + '/.monitor-locks';
const MONITOR_STATE_DIR = RESULT_DIR + '/.monitor-state';
const HISTORY_FILE = '/etc/cfpick/history.csv';
// 任务日志：cfpick.sh 每次测速开始/结束与特殊处理各写一行，
// 格式与 debian/cfpick/tasklog.py 一致（制表符分隔）。
const TASKLOG_FILE = '/etc/cfpick/tasklog.tsv';
const RUN_SCRIPT = '/usr/lib/cfpick/bin/cfpick.sh';

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

// pgrep pattern for the run script, derived from RUN_SCRIPT so a rename cannot
// leave status() watching the old name.  The bracket keeps pgrep from matching
// its own command line, e.g. "[c]fpick\.sh".
function run_script_pattern() {
	let name = replace(RUN_SCRIPT, /^.*\//, '');
	let escaped = replace(name, /[.]/g, '\\.');

	return '[' + substr(escaped, 0, 1) + ']' + substr(escaped, 1);
}

function status() {
	// 定时任务现在就是普通的 crontab 行；状态以 crontab 里是否存在启用的
	// 本插件任务为准，不再看 UCI 的旧 enabled 字段。
	let cron = false;
	let lines = split(read_file('/etc/crontabs/root') || '', '\n');

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);

		if (line == '' || substr(line, 0, 1) == '#')
			continue;
		if (index(line, 'cfpick') >= 0) {
			cron = true;
			break;
		}
	}

	// 走节点测速无独立二进制进程，用脚本主进程判定运行中。
	// 成功后的后台 monitor 也是 cfpick.sh 进程，必须排除：否则控制台会一直
	// 显示「测速运行中」并禁用整轮测速，pid=0 还会让阶段显示成 starting。
	let running = (command('pgrep -af "' + run_script_pattern() +
		'" 2>/dev/null | grep -v " monitor " >/dev/null 2>&1').code == 0);

	return {
		running: running,
		cron: cron
	};
}

// 记录的主进程 PID 是否还活着、且确实是本脚本。只看 /proc/<pid> 存在会被「PID 被无关进程
// 复用」骗过（同脚本 run_lock_acquire 的判据），故再匹配一次 cmdline。
function run_pid_alive(pid) {
	return command('[ -d /proc/' + pid + ' ] && grep -q "cfpick\\.sh" /proc/' + pid + '/cmdline 2>/dev/null').code == 0;
}

// 所有活动运行的主进程 PID。按 worker 并发后可能同时有多个任务；先扫登记表，
// 再兼容旧版的 current_run。
function run_pids() {
	let out = [];
	let seen = {};
	let text = command_output('ls -1 ' + shquote(RUN_REGISTRY) + ' 2>/dev/null').stdout || '';
	let lines = split(text, '\n');

	for (let i = 0; i < length(lines); i++) {
		let pid = trim(lines[i]);

		if (!match(pid, /^[0-9]+$/) || seen[pid] || !run_pid_alive(pid))
			continue;

		seen[pid] = true;
		push(out, pid);
	}

	let pid = '';

	try {
		pid = trim(read_file(RUN_PID_FILE) || '');
	}
	catch (e) {
		pid = '';
	}

	if (match(pid, /^[0-9]+$/) && !seen[pid] && run_pid_alive(pid)) {
		seen[pid] = true;
		push(out, pid);
	}

	return out;
}

// 保留单 PID 接口给状态展示：取最早登记的一个运行。
function run_pid() {
	let pids = run_pids();

	return length(pids) ? pids[0] : null;
}

// 当前会话目录：本次运行的全部中间状态（含 .nt_stop / .iter_stop 停止标志）都在 run.<PID>/ 下，
// 多个整跑并发时互不干扰。取不到（脚本未运行 / 旧版本把状态平铺在 RESULT_DIR）时返回 null。
function run_dir() {
	let pid = run_pid();

	return pid ? RESULT_DIR + '/run.' + pid : null;
}

// 锁目录的持有者是否还活着（与 cfpick.sh 的 lock_owner_alive 同判据）。
function lock_alive(dir) {
	let pid = trim(read_file(dir + '/pid') || '');

	return match(pid, /^[0-9]+$/) != null && run_pid_alive(pid);
}

// worker id → { pid, mode, stopping }。登记表的 workers= 字段由脚本在抢到
// worker 锁后写入，节点页三个按钮据此同步：正在测的行只能停止。
function worker_states() {
	let out = {};
	let pids = run_pids();

	for (let i = 0; i < length(pids); i++) {
		let pid = pids[i];
		let text = '';

		try {
			text = read_file(RUN_REGISTRY + '/' + pid) || '';
		}
		catch (e) {
			text = '';
		}

		let lines = split(text, '\n');
		let workers = '';
		let mode = '';

		for (let j = 0; j < length(lines); j++) {
			let line = trim(lines[j]);
			let m = match(line, /^workers=(.*)$/);

			if (m != null) {
				workers = m[1];
				continue;
			}

			m = match(line, /^mode=(.*)$/);

			if (m != null)
				mode = m[1];
		}

		let dir = RESULT_DIR + '/run.' + pid;
		let stopping = fs.access(dir + '/.nt_stop', 'f') ||
			fs.access(dir + '/.iter_stop', 'f');
		let ids = split(workers, ',');

		for (let k = 0; k < length(ids); k++) {
			let id = trim(ids[k]);

			if (id != '')
				out[id] = { pid: int(pid), mode: mode, stopping: stopping };
		}
	}

	return out;
}

// 下载实测 + 写回占用全局下载锁时，节点页所有 worker 按钮都禁用。
function download_active() {
	return fs.access(COMMIT_LOCK_DIR + '/pid', 'f') && lock_alive(COMMIT_LOCK_DIR);
}

// ubus 参数里的 node 是逗号分隔的 worker id 列表。
function node_list(req) {
	let raw = '' + ((req && req.args && req.args.node) || '');
	// 兼容逗号/空格分隔（CGI 的 nodes_text 用空格拼接）。
	let parts = split(replace(raw, /,/g, ' '), ' ');
	let out = [];

	for (let i = 0; i < length(parts); i++) {
		let id = trim(parts[i]);

		if (id != '' && index(out, id) < 0)
			push(out, id);
	}

	return out;
}

// 带 node 时只跑该 worker（cfpick.sh --node），不同 worker 的探测可以并行；
// 不带 node 的整轮测速仍在已有任务运行时拒绝，保持原行为。
function start(node) {
	if (node) {
		if (worker_states()[node])
			return { started: false, running: true, node: node };

		command(shquote(RUN_SCRIPT) + ' start --node=' + shquote(node) + ' >/dev/null 2>&1 &');

		return { started: true, running: true, node: node };
	}

	if (status().running)
		return { started: false, running: true };

	command(shquote(RUN_SCRIPT) + ' start >/dev/null 2>&1 &');

	return { started: true, running: true };
}

// 复测现有最优 IP：只对当前 result.csv + 各节点现有 address 做一轮延迟 + 下载实测，
// 不重新下载在线列表。运行中同样直接拒绝，避免用户误点；带 node 时只复测该 worker。
function start_retest(node) {
	if (node) {
		if (worker_states()[node])
			return { started: false, running: true, node: node };

		command(shquote(RUN_SCRIPT) + ' retest --node=' + shquote(node) + ' >/dev/null 2>&1 &');

		return { started: true, running: true, node: node };
	}

	if (status().running)
		return { started: false, running: true };

	command(shquote(RUN_SCRIPT) + ' retest >/dev/null 2>&1 &');

	return { started: true, running: true };
}

// 协作式停止：写本次会话的停止标志 .nt_stop，各 worker 跑完当前 IP 自行 break；
// 另写 .iter_stop，限时迭代模式据此在轮间不再开新轮。
// 停止的语义是「停止测速，但把已通过 IP 的下载实测做完、各节点最优 IP 写完再退」：
// 用户手动停止与「首个 worker 完成」的自动提前停止都一样——所有 worker 停止探测后，
// 脚本再逐节点串行完成下载实测并写回。.user_stop 仅用于日志区分两种停止来源。
// 脚本收尾要还原测前快照、原子写回配置、再重启 passwall 才生效，而 passwall 的 restart
// 会在自己的锁上等最多 600s，所以这里不按固定秒数强杀：进程还活着就一直等；只有没进
// 提交阶段（无 .nt_committing）且长时间不动（真挂死，~120s）才升级信号；进了提交/下载
// 收尾阶段（.nt_committing）则放宽到 ~1200s 才兜底。强杀只针对记录的 PID 本身，不再
// pgrep 通杀 —— 否则会误杀随后新起的那次运行。
function stop(nodes) {
	let pids = run_pids();

	// 节点页单行的停止只停包含该 worker 的运行；不带 nodes 的顶部停止仍通知全部。
	if (nodes != null && length(nodes) > 0) {
		let states = worker_states();
		let wanted = {};

		for (let i = 0; i < length(nodes); i++) {
			let info = states[nodes[i]];

			if (info != null)
				wanted[info.pid] = true;
		}

		let selected = [];

		for (let i = 0; i < length(pids); i++)
			if (wanted[int(pids[i])])
				push(selected, pids[i]);

		if (length(selected) == 0)
			return { stopped: false, message: '所选节点没有运行中的测速' };

		pids = selected;
	}

	// 按 worker 并发时可能有多个任务同时运行：停止按钮通知全部，各自完成下载/写回后退。
	for (let i = 0; i < length(pids); i++) {
		let pid = pids[i];
		let dir = RESULT_DIR + '/run.' + pid;

		command('touch ' + shquote(dir + '/.nt_stop') + ' ' + shquote(dir + '/.iter_stop') + ' ' + shquote(dir + '/.user_stop') + ' 2>/dev/null');
		command('( _w=0; while kill -0 ' + pid + ' 2>/dev/null; do' +
			' if [ -f ' + shquote(dir + '/.nt_committing') + ' ]; then [ "$_w" -ge 1200 ] && break; else [ "$_w" -ge 120 ] && break; fi;' +
			' sleep 3; _w=$((_w + 3));' +
			' done;' +
			' kill -0 ' + pid + ' 2>/dev/null || exit 0;' +
			' kill -INT ' + pid + ' 2>/dev/null;' +
			' sleep 15;' +
			' kill -9 ' + pid + ' 2>/dev/null ) >/dev/null 2>&1 &');
	}

	return { stopped: true };
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

	if (load_config(cur, 'cfpick')) {
		cur.foreach('cfpick', 'node_ip', s => {
			if (s.node && index(ids, s.node) < 0)
				push(ids, s.node);
		});

		let legacy = cur.get('cfpick', 'servers', 'passwall_services');

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
// （result.csv 全局延迟升序，某节点首条出现的行即该节点最优）。
// 节点 ID（passwall section id）是稳定主键：优先用它连线和去重，remarks
// 只做展示；旧格式没有 ID 列时退回按节点名匹配。
function parse_run_file(path, idx_of_remarks, idx_of_ids) {
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

		// 9 列 = ...,地区码,节点,节点ID；8 列 = 旧格式有节点无 ID；7 列 = 无节点列
		let node = (length(parts) >= 8) ? parts[7] : '';
		let node_id = (length(parts) >= 9) ? parts[8] : '';
		let key = (node_id != '') ? node_id : node;

		if (!best)
			best = { ip: parts[0], latency: +parts[4] || 0, speed: +parts[5] || 0, region: parts[6] };

		if (node != '' && !seen[key]) {
			seen[key] = true;
			push(nodes, {
				node: node,
				node_id: node_id,
				idx: (node_id != '' && idx_of_ids[node_id] != null) ? idx_of_ids[node_id] :
					((idx_of_remarks[node] != null) ? idx_of_remarks[node] : null),
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

// 解析持久历史文件（/etc/cfpick/history.csv）：多个
// "# Speed test time: ..." 块，每块数据行 = 该次各节点最优（全局延迟升序去重首现）。
// 修剪可能产生无时间头的孤立数据行，直接忽略（cur 为空时跳过）。
function parse_history_file(path, idx_of_remarks, idx_of_ids) {
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

		let node = (length(parts) >= 8) ? parts[7] : '';
		let node_id = (length(parts) >= 9) ? parts[8] : '';
		let key = (node_id != '') ? node_id : node;

		if (!cur.best)
			cur.best = { ip: parts[0], latency: +parts[4] || 0, speed: +parts[5] || 0, region: parts[6] };

		if (node != '' && !cur.seen[key]) {
			cur.seen[key] = true;
			push(cur.nodes, {
				node: node,
				node_id: node_id,
				idx: (node_id != '' && idx_of_ids[node_id] != null) ? idx_of_ids[node_id] :
					((idx_of_remarks[node] != null) ? idx_of_remarks[node] : null),
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
	let idx_of_ids = {};
	let workers = worker_ids();
	let remarks = remarks_map();

	for (let i = 0; i < length(workers); i++) {
		let r = remarks[workers[i]];

		idx_of_ids[workers[i]] = i + 1;

		if (r != null && idx_of_remarks[r] == null)
			idx_of_remarks[r] = i + 1;
	}

	// 持久历史为主（/etc 下，重启与轮转不清）；尚无归档时回退 /tmp 轮转文件（老安装）
	history = parse_history_file(HISTORY_FILE, idx_of_remarks, idx_of_ids);

	if (!length(history)) {
		let item = parse_run_file(RESULT_FILE, idx_of_remarks, idx_of_ids);

		if (item)
			push(history, item);

		for (let i = 1; i <= 9; i++) {
			item = parse_run_file(RESULT_FILE + '.' + i, idx_of_remarks, idx_of_ids);

			if (item)
				push(history, item);
		}
	}

	sort(history, (a, b) => b.time > a.time ? 1 : (b.time < a.time ? -1 : 0));

	return {
		history: history
	};
}

// 任务日志明细列（第 11 列）：node|ip|latency|speed|status|method，
// 多条用 ; 分隔。老文件没有这一列，按空数组返回。
function parse_task_details(text) {
	let out = [];
	let items = split(text || '', ';');

	for (let i = 0; i < length(items); i++) {
		let p = split(items[i], '|');

		if (length(p) < 6 || p[0] == '')
			continue;

		push(out, {
			node: p[0],
			ip: p[1],
			latency: +p[2] || 0,
			speed: +p[3] || 0,
			status: p[4],
			method: p[5]
		});
	}

	return out;
}

// 任务日志（/etc/cfpick/tasklog.tsv）：cfpick.sh 每次测速开始/结束和特殊
// 处理各写一行，这里按最新优先返回。格式与 debian/cfpick/tasklog.py 一致。
function get_tasklog() {
	let lines = read_lines(TASKLOG_FILE);
	let tasks = [];

	for (let i = length(lines) - 1; i >= 0; i--) {
		let line = lines[i];

		if (line == null || line == '')
			continue;

		let p = split(line, "\t");

		if (length(p) < 10)
			continue;

		push(tasks, {
			time: p[0],
			kind: p[1],
			mode: p[2],
			status: p[3],
			node: p[4],
			ip: p[5],
			latency: +p[6] || 0,
			speed: +p[7] || 0,
			ddns: p[8],
			message: p[9],
			details: (length(p) >= 11) ? parse_task_details(p[10]) : []
		});

		if (length(tasks) >= 200)
			break;
	}

	return { tasks: tasks };
}

function get_best_result() {
	let lines = read_lines(RESULT_FILE);
	// 按节点独立排序展示：result.csv 本身保持全局排序（有下载实测速度时按吞吐降序，
	// 否则按延迟升序；DNS 取全局最优/前 N 依赖首行序），此处在展示层按节点分组——
	// 全局序里同一节点的行仍保序，每组首行即该节点自己的最优 IP。节点顺序 = 其最优 IP
	// 在全局排序中首次出现的顺序。分组键优先用稳定的 passwall section ID，
	// 没有 ID 列的旧结果退回节点名。
	// 全量展示（日志的「其余 N 条见最佳 IP 表」指向这里），不再截尾 500 行。
	let header = '';
	let time_line = '';
	let order = [];
	let rows = {};
	let labels = {};

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
		let node = (length(parts) >= 8) ? parts[7] : '';
		let node_id = (length(parts) >= 9) ? parts[8] : '';
		let key = (node_id != '') ? node_id : node;

		if (!rows[key]) {
			rows[key] = [];
			labels[key] = node;
			push(order, key);
		}

		push(rows[key], line);
	}

	let out = [];

	if (header != '')
		push(out, header);

	for (let i = 0; i < length(order); i++) {
		let node_rows = rows[order[i]];
		let best = (length(node_rows) > 0) ? split(node_rows[0], ',') : [];
		let label = labels[order[i]] || order[i];

		let best_speed = +best[5] || 0;

		push(out, '# ── ' + (label != '' ? label : '(无节点)') +
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

// ── standardized management API ──────────────────────────────────────
// The legacy methods above (status, get_log, ...) keep their original shapes
// for the existing LuCI pages and external scripts.  The api_* methods below
// are the stable interface for the new Management page:
//
//   { ok: true,  data: <object>, ts: <epoch> }
//   { ok: false, error: "<message>", ts: <epoch> }
//
// New endpoints belong here and must be wrapped with api(), which turns any
// exception into a normal error response instead of failing the whole call.

function api_ok(data) {
	return { ok: true, data: data, ts: time() };
}

function api_fail(message) {
	return { ok: false, error: '' + message, ts: time() };
}

function api(fn, args) {
	let method = {
		call: function(req) {
			try {
				return api_ok(fn(req));
			}
			catch (e) {
				return api_fail(e);
			}
		}
	};

	if (args != null)
		method.args = args;

	return method;
}

function best_per_node(rows) {
	let out = [];
	let seen = {};

	for (let i = 0; i < length(rows); i++) {
		let key = (rows[i].node_id != null && rows[i].node_id != '') ? rows[i].node_id : rows[i].node;

		if (!seen[key]) {
			seen[key] = true;
			push(out, rows[i]);
		}
	}

	return out;
}

// ucode's numeric coercion yields the string "NaN" for junk input; result.csv
// is generated by the shell script, but a partially written/legacy line must
// still produce a usable JSON response instead of a stringified NaN.
function to_number(value, fallback) {
	let number = +value;

	// NaN fails the self-comparison; ucode has no reliable isnan() builtin.
	return (number == number) ? number : fallback;
}

// Parse one result.csv data line into a row object.
function parse_result_row(line) {
	let parts = split(line, ',');

	if (length(parts) < 7)
		return null;

	return {
		ip: parts[0],
		sent: int(to_number(parts[1], 0)),
		recv: int(to_number(parts[2], 0)),
		loss: to_number(parts[3], 0),
		latency: to_number(parts[4], 0),
		speed: to_number(parts[5], 0),
		region: parts[6],
		node: (length(parts) > 7) ? parts[7] : '',
		node_id: (length(parts) > 8) ? parts[8] : ''
	};
}

// Full parse for api_results / history fallbacks.  api_status only needs the
// first row and the time line, which parse_result_status() extracts without
// building an object per row (it is polled every few seconds by the UI).
function parse_result_summary() {
	let lines = read_lines(RESULT_FILE);
	let when = '';
	let header = '';
	let rows = [];

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i] != null ? lines[i] : '');

		if (line == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			if (match(line, /^# Speed test time:/))
				when = trim(substr(line, 18));

			continue;
		}

		if (header == '') {
			header = line;
			continue;
		}

		let row = parse_result_row(line);

		if (row != null)
			push(rows, row);
	}

	return { time: when, rows: rows };
}

function parse_result_status() {
	let lines = read_lines(RESULT_FILE);
	let when = '';
	let header = '';
	let best = null;
	let count = 0;

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i] != null ? lines[i] : '');

		if (line == '')
			continue;

		if (substr(line, 0, 1) == '#') {
			if (match(line, /^# Speed test time:/))
				when = trim(substr(line, 18));

			continue;
		}

		if (header == '') {
			header = line;
			continue;
		}

		count++;

		if (best == null)
			best = parse_result_row(line);
	}

	return { time: when, best: best, rows: count };
}

function run_started() {
	let pids = run_pids();
	let best = 0;

	for (let i = 0; i < length(pids); i++) {
		let lines = split(read_file(RUN_REGISTRY + '/' + pids[i]) || '', '\n');

		for (let j = 0; j < length(lines); j++) {
			let m = match(trim(lines[j]), /^started=([0-9]+)$/);

			if (m != null) {
				let started = int(m[1]);

				if (started > 0 && (best == 0 || started < best))
					best = started;
			}
		}
	}

	if (best == 0) {
		let text = trim(read_file(RUN_LOCK_DIR + '/started') || '');

		best = match(text, /^[0-9]+$/) ? int(text) : 0;
	}

	return best;
}

function run_mode(pid) {
	let cmdline = read_file('/proc/' + pid + '/cmdline') || '';

	return index(cmdline, 'retest') >= 0 ? 'retest' : 'start';
}

// Coarse phase derived from the session markers written by the shell script:
// .nt_committing during the final write-back, .nt_stop / .iter_stop while
// stopping.  Anything else means probing or downloading.
function run_phase() {
	let pids = run_pids();
	let stopping = false;

	if (length(pids) == 0)
		return 'idle';

	for (let i = 0; i < length(pids); i++) {
		let dir = RESULT_DIR + '/run.' + pids[i];

		if (fs.access(dir + '/.nt_committing', 'f'))
			return 'committing';

		if (fs.access(dir + '/.nt_stop', 'f') || fs.access(dir + '/.iter_stop', 'f'))
			stopping = true;
	}

	return stopping ? 'stopping' : 'testing';
}

// 是否已有停止请求（任一运行的 .nt_stop/.iter_stop）。与 phase 分开算：
// 进入 .nt_committing 后 phase 会变成 committing，但停止请求仍然有效，
// 顶部停止按钮应保持「停止中…」。
function stop_requested() {
	let pids = run_pids();

	for (let i = 0; i < length(pids); i++) {
		let dir = RESULT_DIR + '/run.' + pids[i];

		if (fs.access(dir + '/.nt_stop', 'f') || fs.access(dir + '/.iter_stop', 'f'))
			return true;
	}

	return false;
}

// worker id → 最近一次后台监测状态。状态文件由 cfpick.sh monitor 写：
// node \t target \t ip \t latency \t ok \t failures \t checked_at。
// 定义在 worker_ids()/to_number() 之后：ucode 严格模式要求先声明后引用。
function monitor_states() {
	let out = {};
	let ids = worker_ids();

	for (let i = 0; i < length(ids); i++) {
		let id = ids[i];
		let dir = MONITOR_LOCK_ROOT + '/' + id + '.lock';

		if (!fs.access(dir + '/pid', 'f') || !lock_alive(dir))
			continue;

		let fields = split(trim(read_file(MONITOR_STATE_DIR + '/' + id) || ''), '\t');
		let entry = {
			pid: int(trim(read_file(dir + '/pid') || '') || 0),
			started: int(trim(read_file(dir + '/started') || '') || 0),
			node: id,
			target: '',
			ip: '',
			latency: 0,
			ok: false,
			failures: 0,
			checked_at: 0
		};

		if (length(fields) >= 7) {
			entry.target = fields[1];
			entry.ip = fields[2];
			entry.latency = to_number(fields[3], 0);
			entry.ok = (fields[4] == '1');
			entry.failures = int(to_number(fields[5], 0));
			entry.checked_at = int(to_number(fields[6], 0));
		}

		out[id] = entry;
	}

	return out;
}

function api_status_data() {
	let base = status();
	let pid = run_pid();
	let summary = parse_result_status();
	let started = run_started();
	let now = time();
	let running = base.running;
	let mode = 'idle';
	let phase = 'idle';

	if (running) {
		mode = pid ? run_mode(pid) : 'start';
		// pgrep saw the script but current_run is not readable yet: the
		// session directory is still being created.
		phase = pid ? run_phase() : 'starting';
	}

	return {
		running: running,
		runs: length(run_pids()),
		cron: base.cron,
		pid: pid ? int(pid) : 0,
		mode: mode,
		phase: phase,
		elapsed: (running && started > 0 && now > started) ? now - started : 0,
		started_at: started,
		node_count: length(worker_ids()),
		result_rows: summary.rows,
		last_time: summary.time,
		best: summary.best,
		// 节点页三个按钮的状态来源：哪些 worker 正在测/停止中，以及下载阶段。
		workers: worker_states(),
		download_active: download_active(),
		// 成功后监测：每个 worker 最近一次复测的延迟/失败计数。
		monitor: monitor_states(),
		stop_requested: (running && stop_requested())
	};
}

function api_results_data(req) {
	let summary = parse_result_summary();
	let total = length(summary.rows);
	let limit = int((req && req.args && req.args.limit) || 0);
	let rows = summary.rows;

	if (limit > 0 && total > limit) {
		let trimmed = [];

		for (let i = 0; i < limit; i++)
			push(trimmed, summary.rows[i]);

		rows = trimmed;
	}

	return {
		generated_at: summary.time,
		total: total,
		returned: length(rows),
		best: total ? summary.rows[0] : null,
		nodes: best_per_node(summary.rows),
		rows: rows
	};
}

function api_log_data(req) {
	let pos = int((req && req.args && req.args.pos) || 0);

	if (pos < 0)
		pos = 0;

	return get_log({ args: { pos: pos } });
}

// Whitespace tokenizer.  ucode's split() is string/regex based; this keeps the
// crontab parser independent of multiple spaces and tabs.
function split_ws(line) {
	let out = [];
	let current = '';

	for (let i = 0; i < length(line); i++) {
		let ch = substr(line, i, 1);

		if (ch == ' ' || ch == '\t') {
			if (current != '') {
				push(out, current);
				current = '';
			}
		}
		else {
			current += ch;
		}
	}

	if (current != '')
		push(out, current);

	return out;
}

const CRON_FILES = [ '/etc/crontabs/root', '/etc/crontab' ];
// Only root's crontab is rewritten directly.  /etc/crontab has a user column
// between the schedule and the command, so parsing/editing it here could
// produce a wrong line; it stays read-only in the panel.
const CRON_WRITABLE = '/etc/crontabs/root';
// Marker for a task disabled from the console.  The original schedule and
// command stay on the line, so the panel can show and re-enable it.
const CRON_DISABLED_PREFIX = '# [cfpick-disabled] ';
// A run can be limited to specific PassWall node sections.  The selection is
// stored in the command so the task stays self-contained in the crontab:
//   /usr/lib/cfpick/bin/cfpick.sh retest --node=cfg0a1b2c --node=cfg0a1b2d
const CRON_NODE_FLAG = '--node=';

function cron_command_nodes(command) {
	let parts = split_ws(command);
	let nodes = [];

	for (let i = 0; i < length(parts); i++) {
		if (substr(parts[i], 0, length(CRON_NODE_FLAG)) != CRON_NODE_FLAG)
			continue;

		let name = trim(substr(parts[i], length(CRON_NODE_FLAG)));

		if (name != '' && index(nodes, name) < 0)
			push(nodes, name);
	}

	return nodes;
}

// Normalize the console's selection (array or whitespace/comma string) into
// " --node=id" flags.  Junk is dropped rather than written into crontab.
function cron_node_flags(nodes) {
	let list = [];

	if (type(nodes) == 'array') {
		for (let i = 0; i < length(nodes); i++)
			push(list, trim('' + (nodes[i] ?? '')));
	}
	else if (nodes != null) {
		let parts = split_ws(replace('' + nodes, /,/g, ' '));

		for (let i = 0; i < length(parts); i++)
			push(list, parts[i]);
	}

	let flags = '';

	for (let i = 0; i < length(list); i++) {
		let name = list[i];

		if (!match(name, /^[A-Za-z0-9_]+$/))
			continue;
		if (index(flags, ' ' + CRON_NODE_FLAG + name) >= 0)
			continue;

		flags += ' ' + CRON_NODE_FLAG + name;
	}

	return flags;
}

// Rewrite just the node selection, keeping paths and redirections byte-for-byte.
function cron_set_nodes(command, nodes) {
	return trim(replace(command, /[ \t]+--node=[^ \t]*/g, '')) +
		cron_node_flags(nodes);
}

function cron_is_run_command(command) {
	// POSIX ERE (ucode): no "(?:...)" non-capturing groups.
	return match(command, /^\S*cfpick(\.sh)?[ \t]+(start|retest|test|replace)([ \t]|$)/) != null;
}

// A task belongs to this plugin when its command references the run script,
// one of its helper scripts (aliddns.sh, astra-dns.sh) or the standalone
// `cfpick` binary.  Hand-written lines (retest/replace, helper scripts) are
// picked up too, not just the one line init.d maintains.
function cron_related(command) {
	return index(command, 'cfpick') >= 0 ||
		index(command, '/usr/bin/cfpick') >= 0 ||
		index(command, 'cfpick') >= 0;
}

function cron_valid_schedule(schedule) {
	if (match(schedule, /^@(reboot|hourly|daily|weekly|monthly|yearly|annually|midnight)$/))
		return true;

	let parts = split_ws(schedule);

	if (length(parts) != 5)
		return false;

	for (let i = 0; i < length(parts); i++)
		if (!match(parts[i], /^[0-9A-Za-z*,\/-]+$/))
			return false;

	return true;
}

function cron_normalize_schedule(value) {
	return join(' ', split_ws(trim('' + (value ?? ''))));
}

// Return the part of a crontab line after the first `count` whitespace-separated
// fields, byte-for-byte.  Keeping the original command text means a schedule
// edit never rewrites quoting or redirections inside the command.
function cron_command_suffix(line, count) {
	let i = 0;
	let size = length(line);

	for (let n = 0; n < count; n++) {
		while (i < size && (substr(line, i, 1) == ' ' || substr(line, i, 1) == '\t'))
			i++;

		while (i < size && substr(line, i, 1) != ' ' && substr(line, i, 1) != '\t')
			i++;
	}

	while (i < size && (substr(line, i, 1) == ' ' || substr(line, i, 1) == '\t'))
		i++;

	return substr(line, i);
}

// Parse one crontab line into the panel's task model.  Ordinary comments and
// environment assignments return null; a line carrying the disabled marker is
// returned with disabled=true and its raw line preserved for later matching.
function cron_parse_line(raw, source, index) {
	let line = trim(raw != null ? raw : '');

	if (line == '')
		return null;

	let disabled = false;

	if (substr(line, 0, length(CRON_DISABLED_PREFIX)) == CRON_DISABLED_PREFIX) {
		disabled = true;
		line = trim(substr(line, length(CRON_DISABLED_PREFIX)));
	}
	else if (substr(line, 0, 1) == '#') {
		return null;
	}

	if (match(line, /^[A-Za-z_][A-Za-z0-9_]*=/))
		return null;

	let parts = split_ws(line);
	let schedule;
	let command;

	if (length(parts) > 0 && substr(parts[0], 0, 1) == '@') {
		schedule = parts[0];
		command = cron_command_suffix(line, 1);
	}
	else if (length(parts) >= 6) {
		schedule = parts[0] + ' ' + parts[1] + ' ' + parts[2] + ' ' +
			parts[3] + ' ' + parts[4];
		command = cron_command_suffix(line, 5);
	}
	else {
		return null;
	}

	if (command == '')
		return null;

	return {
		id: source + '#' + index,
		source: source,
		schedule: schedule,
		command: command,
		line: disabled ? CRON_DISABLED_PREFIX + line : line,
		related: cron_related(command),
		nodes: cron_command_nodes(command),
		disabled: disabled,
		writable: source == CRON_WRITABLE
	};
}

function cron_file_lines(path) {
	if (!fs.access(path, 'f'))
		return [];

	return split(replace(read_file(path), /\r/g, ''), '\n');
}

// Atomic replace: write a sibling temp file, fix its mode (crontabs/root is
// 0600), then rename.  A half-written crontab would silently drop every task.
function cron_write_lines(path, lines) {
	let count = length(lines);

	while (count > 0 && trim(lines[count - 1]) == '')
		count--;

	let content = '';

	for (let i = 0; i < count; i++)
		content += lines[i] + '\n';

	let tmp = path + '.cfpick-tmp';
	let fd = fs.open(tmp, 'w');

	if (!fd)
		return false;

	fd.write(content);
	fd.close();

	let rc = system('chmod 600 ' + shquote(tmp) + ' && mv -f ' + shquote(tmp) + ' ' + shquote(path));

	if (rc != 0) {
		try { fs.unlink(tmp); } catch (e) {}
		return false;
	}

	return true;
}

function cron_find_line(lines, target) {
	target = trim(target);

	for (let i = 0; i < length(lines); i++)
		if (trim(lines[i]) == target)
			return i;

	return -1;
}

function api_tasks_data() {
	let sources = [];
	let entries = [];

	for (let i = 0; i < length(CRON_FILES); i++) {
		let path = CRON_FILES[i];
		let exists = fs.access(path, 'f') ? true : false;
		let lines = exists ? cron_file_lines(path) : [];
		let parsed = [];

		for (let j = 0; j < length(lines); j++) {
			let entry = cron_parse_line(lines[j], path, j);

			// The console is a cfpick panel, not a general crontab
			// editor: only lines addressing this plugin are surfaced.
			if (entry == null || !entry.related)
				continue;

			push(parsed, entry);
			push(entries, entry);
		}

		push(sources, { source: path, exists: exists, entries: parsed });
	}

	return {
		sources: sources,
		entries: entries,
		run_script: RUN_SCRIPT,
		writable: CRON_WRITABLE
	};
}

function cron_task_source(args) {
	let source = trim('' + ((args && args.source) ?? ''));

	return source == CRON_WRITABLE ? source : '';
}

function cron_task_entry(req) {
	let args = (req && req.args) || {};
	let source = cron_task_source(args);
	let line = trim('' + (args.line ?? ''));

	if (source == '')
		die('只能修改 /etc/crontabs/root 中的任务');

	if (line == '')
		die('缺少任务行');

	let lines = cron_file_lines(source);
	let index = cron_find_line(lines, line);

	if (index < 0)
		die('任务已被修改，请刷新后重试');

	let entry = cron_parse_line(lines[index], source, index);

	if (entry == null || !entry.related)
		die('只能修改本插件相关的任务');

	return { args: args, source: source, lines: lines, index: index, entry: entry };
}

function api_task_save_data(req) {
	let task = cron_task_entry(req);
	let schedule = cron_normalize_schedule(task.args.schedule);
	let enabled = ('' + (task.args.enabled ?? '1')) != '0';
	let command = task.entry.command;
	let mode = trim('' + (task.args.mode ?? ''));

	if (!cron_valid_schedule(schedule))
		die('计划必须是合法的五段 cron 表达式或 @reboot 等简写');

	if (mode != '') {
		// Group 1 = runner prefix, group 2 = optional ".sh", group 3 = mode,
		// group 4 = trailing args (node flags / redirection).
		let found = match(command, /^(\S*cfpick(\.sh)?)[ \t]+(start|retest|test|replace)(.*)$/);

		if (found == null)
			die('该任务不支持修改任务类型');
		if (mode != 'start' && mode != 'retest' && mode != 'test' && mode != 'replace')
			die('不支持的任务类型');

		// Keep the trailing args (node selection / redirection) when swapping
		// the task type.
		command = found[1] + ' ' + mode + found[4];
	}

	// An explicit nodes value (even empty) rewrites the selection; leaving the
	// field out keeps whatever the task already had.
	if (task.args.nodes != null && cron_is_run_command(command))
		command = cron_set_nodes(command, task.args.nodes);

	let line = schedule + ' ' + command;

	if (!enabled)
		line = CRON_DISABLED_PREFIX + line;

	task.lines[task.index] = line;

	if (!cron_write_lines(task.source, task.lines))
		die('写入 crontab 失败');

	system('/etc/init.d/cron restart >/dev/null 2>&1');

	return api_tasks_data();
}

function api_task_delete_data(req) {
	let task = cron_task_entry(req);
	let kept = [];

	for (let i = 0; i < length(task.lines); i++)
		if (i != task.index)
			push(kept, task.lines[i]);

	if (!cron_write_lines(task.source, kept))
		die('写入 crontab 失败');

	system('/etc/init.d/cron restart >/dev/null 2>&1');

	return api_tasks_data();
}

function api_task_add_data(req) {
	let args = (req && req.args) || {};
	let source = trim('' + (args.source ?? '')) || CRON_WRITABLE;
	let schedule = cron_normalize_schedule(args.schedule);
	let command = replace(trim('' + (args.command ?? '')), /[\r\n]+/g, ' ');

	if (source != CRON_WRITABLE)
		die('只能写入 /etc/crontabs/root');

	if (!cron_valid_schedule(schedule))
		die('计划必须是合法的五段 cron 表达式或 @reboot 等简写');

	if (command == '' || length(command) > 512)
		die('命令无效');

	if (!cron_related(command))
		die('只能添加本插件相关的命令');

	if (args.nodes != null && cron_is_run_command(command))
		command = cron_set_nodes(command, args.nodes);

	let line = schedule + ' ' + command;

	// Every task is a normal crontab line now, including start.  An identical
	// line is rejected as a duplicate below.
	let lines = cron_file_lines(source);
	let kept = [];
	let count = length(lines);

	// Drop the trailing empty element produced by the file's final newline
	// before appending, otherwise every add leaves a blank separator line.
	while (count > 0 && trim(lines[count - 1]) == '')
		count--;

	for (let i = 0; i < count; i++) {
		if (trim(lines[i]) == line) {
			if (command == RUN_SCRIPT + ' start')
				die('已存在相同的完整测速任务，请直接修改列表中的那一行');
			die('相同任务已存在');
		}

		push(kept, lines[i]);
	}

	push(kept, line);

	if (!cron_write_lines(source, kept))
		die('写入 crontab 失败');

	system('/etc/init.d/cron restart >/dev/null 2>&1');

	return api_tasks_data();
}

// Called after the console removes nodes from its worker table: drop those
// names from task selections so no task keeps a reference to a gone node.
// A task whose selection becomes empty is deleted instead of silently
// widening to "run every node".
function api_task_prune_data(req) {
	let args = (req && req.args) || {};
	let removed = split_ws(replace('' + (args.nodes ?? ''), /,/g, ' '));
	let report = { removed: [], deleted: [] };

	if (length(removed) == 0 || !fs.access(CRON_WRITABLE, 'f'))
		return report;

	let lines = cron_file_lines(CRON_WRITABLE);
	let kept = [];
	let changed = false;

	for (let i = 0; i < length(lines); i++) {
		let entry = cron_parse_line(lines[i], CRON_WRITABLE, i);

		if (entry == null || !entry.related || length(entry.nodes) == 0) {
			push(kept, lines[i]);
			continue;
		}

		let remaining = [];
		let dropped = [];

		for (let j = 0; j < length(entry.nodes); j++) {
			let name = entry.nodes[j];

			if (index(removed, name) >= 0) {
				if (index(dropped, name) < 0)
					push(dropped, name);
				continue;
			}

			if (index(remaining, name) < 0)
				push(remaining, name);
		}

		if (length(dropped) == 0) {
			push(kept, lines[i]);
			continue;
		}

		for (let j = 0; j < length(dropped); j++)
			if (index(report.removed, dropped[j]) < 0)
				push(report.removed, dropped[j]);

		if (length(remaining) == 0) {
			push(report.deleted, trim(lines[i]));
			changed = true;
			continue;
		}

		let line = entry.schedule + ' ' + cron_set_nodes(entry.command, remaining);

		if (entry.disabled)
			line = CRON_DISABLED_PREFIX + line;

		push(kept, line);
		changed = true;
	}

	if (changed && cron_write_lines(CRON_WRITABLE, kept))
		system('/etc/init.d/cron restart >/dev/null 2>&1');

	return report;
}

// Called from LuCI's minimal Settings page: forget the console password and
// invalidate the current console session.  The next console visit offers the
// first-run "create admin password" form again.
function api_web_reset_data() {
	let cur = uci.cursor();

	try { cur.load('cfpick'); } catch (e) {}
	try { cur.delete('cfpick', 'global', 'web_password'); } catch (e) {}
	cur.commit('cfpick');

	try { fs.unlink('/tmp/cfpick-web.session'); } catch (e) {}

	return { reset: true };
}

// ── standalone core mode (cfpick) ─────────────────────────────────
// The unified test can run its per-IP probes through a locally managed
// mihomo/Xray core instead of PassWall's run_socks.  Nodes, IP lists and
// settings still come from this package's UCI config; the core binary can be
// installed/upgraded independently.  The shell pipeline does the actual run,
// so this block only reports the option, manages the core download and lets
// the console save the two UCI keys.
const STANDALONE_BIN = '/usr/bin/cfpick';
const STANDALONE_LOG = '/tmp/cfpick-core-update.log';
const STANDALONE_PID = '/tmp/cfpick-core-update.pid';
const STANDALONE_TYPE_FILE = '/tmp/cfpick-core-update.type';
const STANDALONE_UCI = 'cfpick';

function standalone_settings() {
	let cur = uci.cursor();
	let enabled = false;
	let core = 'xray';

	try { cur.load(STANDALONE_UCI); } catch (e) {}
	// 独立内核是固定项；旧配置里的 standalone_enabled 不再生效。
	enabled = true;
	core = (cur.get(STANDALONE_UCI, 'global', 'standalone_core') == 'mihomo') ? 'mihomo' : 'xray';

	return { enabled: enabled, core: core };
}

function standalone_cores() {
	let out = command_output(STANDALONE_BIN + ' cores 2>/dev/null');

	if (out.code != 0 || out.stdout == '')
		return { active: '', cores: {} };

	try { return json(out.stdout) || { active: '', cores: {} }; }
	catch (e) { return { active: '', cores: {} }; }
}

function standalone_updating() {
	let pid = trim(read_file(STANDALONE_PID) || '');

	return (match(pid, /^[0-9]+$/) &&
		system('kill -0 ' + pid + ' 2>/dev/null') == 0) ? true : false;
}

function standalone_status() {
	let settings = standalone_settings();
	let cores = standalone_cores();
	let log = read_file(STANDALONE_LOG);
	let updating = standalone_updating();
	let updating_type = updating ? trim(read_file(STANDALONE_TYPE_FILE) || '') : '';

	if (length(log) > 4000)
		log = substr(log, length(log) - 4000);

	return {
		enabled: settings.enabled,
		core: settings.core,
		cores: cores,
		updating: updating,
		// Lets the card show "更新中…" on the right core while the other
		// card stays actionable after the update finishes.
		updating_type: (updating_type == 'mihomo' || updating_type == 'xray') ? updating_type : '',
		update_log: log
	};
}

// ── online package update ───────────────────────────────────────────────
// The actual download/install runs detached in app-update.sh: replacing the
// package files (and restarting rpcd) would otherwise cut off this RPC call.
const APP_UPDATE_SCRIPT = '/usr/lib/cfpick/app-update.sh';
const APP_UPDATE_STATUS = '/tmp/cfpick-app-update.json';
const APP_UPDATE_PID = '/tmp/cfpick-app-update.pid';
const APP_UPDATE_LOG = '/tmp/cfpick-app-update.log';

// 当前安装的 luci-app-cfpick 版本（opkg 优先，apk 兜底）。
function app_current_version() {
	let out = command_output('opkg list-installed luci-app-cfpick 2>/dev/null');

	let m = match(out.stdout || '', /luci-app-cfpick[ \t]+-[ \t]+([0-9][^ \t\n]*)/);

	if (m)
		return m[1];

	out = command_output('apk info -v luci-app-cfpick 2>/dev/null');
	m = match(out.stdout || '', /luci-app-cfpick-([0-9][^ \t\n]*)/);

	return m ? m[1] : '';
}

function app_version_parts(version) {
	let clean = replace(trim('' + (version || '')), /^[vV]/, '');
	let raw = split(clean, '.');
	let out = [];

	for (let i = 0; i < length(raw); i++) {
		let m = match(raw[i], /^[0-9]+/);

		push(out, m ? +m[0] : 0);
	}

	return out;
}

function app_version_compare(a, b) {
	let pa = app_version_parts(a);
	let pb = app_version_parts(b);
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);

	for (let i = 0; i < n; i++) {
		let x = (i < length(pa)) ? pa[i] : 0;
		let y = (i < length(pb)) ? pb[i] : 0;

		if (x != y)
			return (x > y) ? 1 : -1;
	}

	return 0;
}

function app_update_status_data() {
	let pid = trim(read_file(APP_UPDATE_PID) || '');
	let alive = (match(pid, /^[0-9]+$/) &&
		system('kill -0 ' + pid + ' 2>/dev/null') == 0);
	let info = {};

	try { info = json(read_file(APP_UPDATE_STATUS) || '{}') || {}; }
	catch (e) { info = {}; }

	info.updating = alive || info.updating == true;
	info.current_version = app_current_version();

	return info;
}

// 检查远端最新 Release，不下载、不安装。只在前端点「检查更新」时调用。
function app_update_check_data() {
	let current = app_current_version();

	if (current == '')
		return { ok: false, current: '', latest: '', available: false,
			error: '无法读取当前版本' };

	let res = command_output('curl -fsSL --max-time 20 ' +
		shquote('https://api.github.com/repos/urbanescavenger/CFPick/releases/latest') +
		' 2>/dev/null');
	let raw = trim(res.stdout || '');

	if (raw == '')
		return { ok: false, current: current, latest: '', available: false,
			error: '无法获取远端版本（GitHub API 不可达）' };

	let info = {};

	try { info = json(raw) || {}; }
	catch (e) { info = {}; }

	let tag = trim('' + (info.tag_name || ''));
	let latest = replace(tag, /^[vV]/, '');

	if (latest == '')
		return { ok: false, current: current, latest: '', available: false,
			error: 'Release 信息中没有版本号' };

	return {
		ok: true,
		current: current,
		latest: latest,
		tag: tag,
		available: app_version_compare(latest, current) > 0,
		error: ''
	};
}

function app_update_start_data() {
	if (status().running)
		return { started: false, error: '测速正在运行，请先停止后再更新' };

	if (standalone_updating())
		return { started: false, error: '内核正在更新，请稍候再更新程序' };

	let current = app_update_status_data();

	if (current.updating)
		return { started: false, error: '已有在线更新正在进行' };

	if (!fs.access(APP_UPDATE_SCRIPT, 'f'))
		return { started: false, error: '缺少在线更新脚本' };

	let run = '/tmp/cfpick-app-update-run.sh';

	// Execute a copy: opkg replaces the installed script while it is running.
	command('cp -f ' + shquote(APP_UPDATE_SCRIPT) + ' ' + shquote(run) +
		' && chmod 700 ' + shquote(run));
	command('rm -f ' + shquote(APP_UPDATE_STATUS) + ' ' +
		shquote(APP_UPDATE_PID) + ' ' + shquote(APP_UPDATE_LOG));

	// -m -p is required: without a pidfile start-stop-daemon refuses because
	// /bin/sh itself is already running.
	let rc = system('start-stop-daemon -S -b -m -p ' + shquote(APP_UPDATE_PID) +
		' -x /bin/sh -- ' + shquote(run) + ' >/dev/null 2>&1');

	if (rc != 0)
		command('nohup sh ' + shquote(run) + ' >/dev/null 2>&1 &');

	return { started: true };
}


return {
	'cfpick': {
		// Legacy API: kept for the existing Settings/Log pages and external
		// scripts.  Return shapes here must not change; new endpoints and
		// clients should use the api_* methods below.
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
		},

		// Stable management API (see the api_ok/api_fail comment above).
		api_ping: api(function() {
			return { name: 'cfpick', api: 1, time: time() };
		}),

		api_status: api(function() {
			return api_status_data();
		}),

		api_results: api(function(req) {
			return api_results_data(req);
		}, { limit: 0 }),

		api_history: api(function() {
			return get_history();
		}),

		api_tasklog: api(function() {
			return get_tasklog();
		}),

		api_nodes: api(function() {
			return list_nodes();
		}),

		api_log: api(function(req) {
			return api_log_data(req);
		}, { pos: 0 }),

		api_tasks: api(function() {
			return api_tasks_data();
		}),

		// Configure tasks owned by this plugin.  The panel only allows editing
		// lines it recognised as related, so arbitrary crontab commands cannot
		// be introduced through these methods.
		api_task_save: api(function(req) {
			return api_task_save_data(req);
		}, { source: '', line: '', schedule: '', enabled: '', mode: '', nodes: '' }),

		api_task_delete: api(function(req) {
			return api_task_delete_data(req);
		}, { source: '', line: '' }),

		api_task_add: api(function(req) {
			return api_task_add_data(req);
		}, { source: '', schedule: '', command: '', nodes: '' }),

		api_task_prune: api(function(req) {
			return api_task_prune_data(req);
		}, { nodes: '' }),

		api_update_start: api(function() {
			return app_update_start_data();
		}),

		api_update_status: api(function() {
			return app_update_status_data();
		}),

		api_update_check: api(function() {
			return app_update_check_data();
		}),

		api_web_reset: api(function() {
			return api_web_reset_data();
		}),

		// rpcd 只把声明在 args 里的字段传给方法；不声明时带 node 的调用
		// 会被 ubus 以 UBUS_STATUS_INVALID_ARGUMENT 拒绝（返回空，前端报
		// "Cannot read properties of null"）。节点页按钮依赖 node。
		api_run_start: api(function(req) {
			let nodes = node_list(req);
			let result = start(length(nodes) > 0 ? nodes[0] : '');
			result.mode = 'start';
			return result;
		}, { node: '' }),

		api_run_retest: api(function(req) {
			let nodes = node_list(req);
			let result = start_retest(length(nodes) > 0 ? nodes[0] : '');
			result.mode = 'retest';
			return result;
		}, { node: '' }),

		api_run_stop: api(function(req) {
			return stop(node_list(req));
		}, { node: '' }),

		// Standalone core mode: option/status and independent core updates.
		standalone_status: {
			call: function() {
				return standalone_status();
			}
		},

	}
};
