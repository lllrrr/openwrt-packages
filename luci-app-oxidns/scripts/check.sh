#!/bin/sh

set -eu

node -e "const fs=require('fs'); const dir='htdocs/luci-static/resources/view/oxidns/'; for (const n of ['overview','core','config','rules','geo','logs','settings','upload']) { const f=dir+n+'.js'; if (fs.existsSync(f)) new Function(fs.readFileSync(f,'utf8')); }"
node -e "for (const f of ['root/usr/share/luci/menu.d/luci-app-oxidns.json','root/usr/share/rpcd/acl.d/luci-app-oxidns.json','root/usr/share/oxidns/targets.json']) JSON.parse(require('fs').readFileSync(f,'utf8'));"
node <<'NODE'
const fs = require('fs');

const required = new Set();
for (const file of [
	'htdocs/luci-static/resources/view/oxidns/overview.js',
	'htdocs/luci-static/resources/view/oxidns/core.js',
	'htdocs/luci-static/resources/view/oxidns/config.js',
	'htdocs/luci-static/resources/view/oxidns/rules.js',
	'htdocs/luci-static/resources/view/oxidns/geo.js',
	'htdocs/luci-static/resources/view/oxidns/logs.js',
	'htdocs/luci-static/resources/view/oxidns/settings.js',
]) {
	const source = fs.readFileSync(file, 'utf8');
	const re = /_\(\s*(['"])((?:\\.|[^\\])*?)\1\s*\)/g;
	let match;
	while ((match = re.exec(source)))
		required.add(Function(`return ${match[1]}${match[2]}${match[1]}`)());
}

const menu = JSON.parse(fs.readFileSync('root/usr/share/luci/menu.d/luci-app-oxidns.json', 'utf8'));
for (const entry of Object.values(menu)) {
	if (entry.title)
		required.add(entry.title);
}

function poIds(file) {
	const ids = new Set();
	const content = fs.readFileSync(file, 'utf8');
	const re = /^msgid "((?:\\.|[^"\\])*)"$/mg;
	let match;
	while ((match = re.exec(content))) {
		const id = JSON.parse(`"${match[1]}"`);
		if (id)
			ids.add(id);
	}
	return ids;
}

const pot = poIds('po/templates/oxidns.pot');
const zh = poIds('po/zh_Hans/oxidns.po');
const failures = [];
for (const [label, ids] of [['POT', pot], ['zh_Hans PO', zh]]) {
	for (const id of [...required].sort()) {
		if (!ids.has(id))
			failures.push(`${label} missing msgid: ${id}`);
	}
}
for (const id of [...pot].sort()) {
	if (!required.has(id))
		failures.push(`POT stale msgid: ${id}`);
}
if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}
NODE
node <<'NODE'
const fs = require('fs');
const path = require('path');

function walk(dir, out) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory())
			walk(full, out);
		else if (entry.isFile())
			out.push(full);
	}
}

const files = [];
for (const root of ['htdocs', 'root', 'po', 'scripts', 'Makefile', 'README.md']) {
	const stat = fs.statSync(root, { throwIfNoEntry: false });
	if (!stat)
		continue;
	if (stat.isDirectory())
		walk(root, files);
	else
		files.push(root);
}

const crlf = files.filter((file) => fs.readFileSync(file).includes(Buffer.from('\r\n')));
if (crlf.length) {
	console.error('CRLF line endings found in packaged sources:');
	for (const file of crlf)
		console.error(`  ${file}`);
	console.error('These files are packaged for the router, where the rpcd backend and init script are executed.');
	console.error('Keep them LF: check .gitattributes and core.autocrlf, then rebuild.');
	process.exit(1);
}
NODE
node <<'NODE'
const fs = require('fs');

const failures = [];

// ------------------------------------------------------------ 包控制脚本
// 发版走官方 SDK（.github/workflows/build-packages.yml 用 gh-action-sdk），它的
// postinst/postrm 只来自 Makefile 的 define 块；scripts/build-luci-package.sh 里
// 那份 heredoc 只在本地造包时会被跑到。两份一旦漂移，"本地解包核对"核的就不是
// 线上那个包 —— 0.1.5-r5 之前正是如此：heredoc 里有 cron 路径迁移，Makefile 里
// 没有，于是那段迁移在线上安装从来没执行过。
const makefile = fs.readFileSync('Makefile', 'utf8');

function block(name) {
	const m = new RegExp(`^define Package/luci-app-oxidns/${name}$([\\s\\S]*?)^endef$`, 'm').exec(makefile);
	return m ? m[1] : null;
}

const postinst = block('postinst');
const postrm = block('postrm');

if (!postinst)
	failures.push('Makefile: 找不到 Package/luci-app-oxidns/postinst');
if (!postrm)
	failures.push('Makefile: 找不到 Package/luci-app-oxidns/postrm');

for (const [label, needle] of [
	['IPKG_INSTROOT 守卫', '[ -n "$${IPKG_INSTROOT:-}" ] && exit 0'],
	['cron 路径迁移', 's#/usr/bin/oxidns-learn-reset\\.sh#/usr/libexec/oxidns/learn-reset.sh#g'],
	['迁移后重启 cron', '/etc/init.d/cron restart'],
	['DNS 劫持 family 迁移（否则只劫持 IPv4）', 'firewall.$$hijack_sect.family=any'],
]) {
	if (postinst && !postinst.includes(needle))
		failures.push(`Makefile postinst 缺少「${label}」`);
}

const builder = fs.readFileSync('scripts/build-luci-package.sh', 'utf8');
if (!builder.includes('makefile_block'))
	failures.push('build-luci-package.sh: 没有从 Makefile 里取 postinst/postrm');
if (/^write_rpcd_restart_script\(\)/m.test(builder))
	failures.push('build-luci-package.sh: 那份重复的 postinst heredoc 又回来了');

if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}
NODE
for script in scripts/po2lmo.mjs scripts/strip-tar-eof.mjs scripts/write-apk-data-tar.mjs scripts/write-ar-archive.mjs; do
	node --check "$script"
done
node scripts/po2lmo.mjs po/zh_Hans/oxidns.po "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
test -s "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
rm -f "${TMPDIR:-/tmp}/oxidns.zh-cn.lmo"
if command -v msgfmt >/dev/null 2>&1; then
	msgfmt --check po/zh_Hans/oxidns.po -o /dev/null
fi
sh -n root/usr/libexec/rpcd/luci.oxidns
sh -n root/usr/libexec/oxidns/learn-reset.sh
sh -n root/etc/init.d/oxidns
sh -n scripts/build-luci-package.sh
sh -n scripts/integration-check.sh
sh -n scripts/release-check.sh
sh -n scripts/core-update-check.sh

# ---------------------------------------------------------------- 源码守卫
# OpenWrt 25.12 的 busybox **没有 stat applet**（设备实测 `ash: stat: not found`，
# rc=127）。`stat -c %Y` 失败会被 2>/dev/null 吞掉，调用方只拿到空串：Geo 页的
# 「修改时间」显示 `-`，config/rules 的 mtime 乐观锁永不生效。
# 开发机是 GNU stat、能跑通，所以这类缺陷只能靠源码守卫挡 —— 断言 stat_mtime
# 的第一条有效语句是 `date -r`（busybox date 支持 -r）。
stat_mtime_first=$(
	awk '/^stat_mtime\(\)/{f=1;next} f&&/^\}/{exit} f' root/usr/libexec/rpcd/luci.oxidns |
		grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -1
)
case "$stat_mtime_first" in
	*'date -r'*) ;;
	*)
		echo "stat_mtime 的第一条有效语句必须是 date -r（25.12 的 busybox 没有 stat applet）；实际: [$stat_mtime_first]" >&2
		exit 1
		;;
esac
if ! grep -q 'fmtTime(info\.mtime)' htdocs/luci-static/resources/view/oxidns/geo.js; then
	echo 'geo.js 的「修改时间」必须经 fmtTime() 换算成本地时间，不能直接输出 Unix 秒' >&2
	exit 1
fi
# 同一根因的另一处：拿权限位也不能用 stat（规则文件保存时保留原 mode）
if grep -q 'stat -c %a' root/usr/libexec/rpcd/luci.oxidns; then
	echo 'luci.oxidns 里不能用 stat -c %a 取权限位（25.12 的 busybox 没有 stat applet），用 file_mode_octal' >&2
	exit 1
fi
