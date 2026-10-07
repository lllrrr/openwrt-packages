// 检查 LuCI 视图里用到的 form.* 类名是否都真实存在，
// 并核对版本号 / BOM / 文件大小的一致性。
// 背景：form.TextArea 并不存在（form.js 只导出 form.TextValue），
// 一旦用错会抛 `Class must be a descendant of CBIAbstractValue`，整页渲染失败。
const fs = require('fs');

// 从路由器 /www/luci-static/resources/form.js 末尾 return 语句里实测得到的完整清单
const valid = new Set(['Map', 'JSONMap', 'AbstractSection', 'AbstractValue',
	'TypedSection', 'TableSection', 'GridSection', 'NamedSection', 'Value',
	'DynamicList', 'ListValue', 'RichListValue', 'RangeSliderValue', 'Flag',
	'MultiValue', 'TextValue', 'DummyValue', 'Button', 'HiddenValue',
	'FileUpload', 'DirectoryPicker', 'SectionValue']);

const base = 'D:/AI/luci-app-migu-iptv/';
const views = ['files/www/luci-static/resources/view/migu/config.js',
	'files/www/luci-static/resources/view/migu/status.js'];

// 去掉行注释与块注释后再扫描 —— 否则我自己写的
// 「写成 form.TextArea 会抛错」这类说明性注释会被误报为非法用法。
function stripComments(src) {
	return src.replace(/\/\*[\s\S]*?\*\//g, '')
		.split(/\r?\n/)
		.map(l => l.replace(/\/\/.*$/, ''))
		.join('\n');
}

console.log('=== LuCI form 类名合法性 ===');
let bad = 0;
for (const rel of views) {
	const s = stripComments(fs.readFileSync(base + rel, 'utf8'));
	const used = [...new Set([...s.matchAll(/form\.([A-Za-z]+)\b/g)].map(m => m[1]))];
	const illegal = used.filter(u => !valid.has(u));
	console.log('  ' + rel.split('/').pop() + ' 用到 [' + used.join(', ') + ']');
	console.log('    → 非法: ' + (illegal.length ? illegal.join(', ') : '无'));
	bad += illegal.length;
}
console.log('  ' + (bad === 0 ? '✅ 全部合法' : '❌ 存在非法类名'));

// 正向对照：喂一段故意用错类的代码，确认这个检查器真的抓得到。
// （教训：报 0 的检查器必须先证明它抓得到，否则 0 无意义。）
const control = "o = s.option(form.TextArea, 'x', _('y'));\no2 = s.option(form.NotAClass, 'z', _('w'));";
const ctlSrc = stripComments(control);
const ctlUsed = [...new Set([...ctlSrc.matchAll(/form\.([A-Za-z]+)\b/g)].map(m => m[1]))];
const ctlIllegal = ctlUsed.filter(u => !valid.has(u));
console.log('  对照样本 → 非法: ' + (ctlIllegal.length ? ctlIllegal.join(', ') : '无') +
	(ctlIllegal.length >= 2 ? '  ✅ 检查器有效（能抓到 TextArea 与 NotAClass）' : '  ❌ 检查器失效，上面的结论不可信'));

console.log('');
console.log('=== 版本一致性 ===');
const mk = fs.readFileSync(base + 'Makefile', 'utf8');
const uc = fs.readFileSync(base + 'files/usr/share/ucode/migu.uc', 'utf8');
const mkVer = (mk.match(/PKG_VERSION:=([\d.]+)/) || [])[1];
const ucVer = (uc.match(/APP_VERSION = '([\d.]+)'/) || [])[1];
console.log('  Makefile PKG_VERSION = ' + mkVer);
console.log('  migu.uc  APP_VERSION = ' + ucVer);
console.log('  一致: ' + (mkVer === ucVer ? '✅ 是' : '❌ 否'));
console.log('  LUCI_DEPENDS: ' + ((mk.match(/LUCI_DEPENDS:=.*/) || [])[0] || '').trim());
console.log('  ucode 里 openssl 残留(代码行): ' + uc.split(/\r?\n/).filter(l => /openssl/.test(l) && !/^\s*\/\//.test(l)).length);

console.log('');
console.log('=== 文件完整性 / BOM ===');
const files = ['Makefile', 'README.md', 'files/etc/config/migu', 'files/etc/init.d/migu',
	'files/usr/share/rpcd/ucode/migu', 'files/usr/share/ucode/migu.uc',
	'files/usr/share/rpcd/acl.d/luci-app-migu-iptv.json',
	'files/usr/share/luci/menu.d/luci-app-migu-iptv.json', ...views];
for (const rel of files) {
	try {
		const buf = fs.readFileSync(base + rel);
		const bom = buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF;
		const lines = buf.toString('utf8').split(/\r?\n/).length;
		console.log('  ' + rel.padEnd(58) + String(buf.length).padStart(7) + ' 字节 ' +
			String(lines).padStart(5) + ' 行' + (bom ? '  ⚠️ 有 BOM' : ''));
	} catch (e) {
		console.log('  ' + rel + '  ❌ ' + e.message);
	}
}
