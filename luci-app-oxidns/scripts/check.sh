#!/bin/sh

set -eu

node -e "for (const f of ['htdocs/luci-static/resources/view/oxidns/overview.js','htdocs/luci-static/resources/view/oxidns/config.js','htdocs/luci-static/resources/view/oxidns/config-guided.js','htdocs/luci-static/resources/view/oxidns/config-yaml.js','htdocs/luci-static/resources/view/oxidns/logs.js','htdocs/luci-static/resources/view/oxidns/settings.js','htdocs/luci-static/resources/oxidns/yaml.js','htdocs/luci-static/resources/oxidns/adfilter.js','htdocs/luci-static/resources/oxidns/i18n.js']) new Function(require('fs').readFileSync(f,'utf8'));"
node -e 'const f="htdocs/luci-static/resources/oxidns/yaml.js";const s=require("fs").readFileSync(f,"utf8");const bad=[...s].filter(c=>c.charCodeAt(0)<32&&c!=="\n");if(bad.length){console.error(f+": raw control characters must be escaped; OpenWrt jsmin rewrites them and breaks the YAML parser");process.exit(1);}'
node -e "for (const f of ['root/usr/share/luci/menu.d/luci-app-oxidns.json','root/usr/share/rpcd/acl.d/luci-app-oxidns.json','root/usr/share/oxidns/targets.json','root/usr/share/oxidns/config-schema.json','root/usr/share/oxidns/plugin-types.json']) JSON.parse(require('fs').readFileSync(f,'utf8'));"
node <<'NODE'
const fs = require('fs');

const required = new Set();
for (const file of [
	'htdocs/luci-static/resources/view/oxidns/overview.js',
	'htdocs/luci-static/resources/view/oxidns/config.js',
	'htdocs/luci-static/resources/view/oxidns/config-guided.js',
	'htdocs/luci-static/resources/view/oxidns/config-yaml.js',
	'htdocs/luci-static/resources/view/oxidns/logs.js',
	'htdocs/luci-static/resources/view/oxidns/settings.js',
	'htdocs/luci-static/resources/oxidns/adfilter.js',
	'htdocs/luci-static/resources/oxidns/i18n.js',
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

const schema = JSON.parse(fs.readFileSync('root/usr/share/oxidns/config-schema.json', 'utf8'));
function addSchemaField(field) {
	for (const key of ['label', 'help', 'item_label']) {
		if (field[key])
			required.add(field[key]);
	}
	for (const value of field.values || []) {
		if (value && typeof value === 'object' && value.label)
			required.add(value.label);
	}
	for (const child of field.fields || [])
		addSchemaField(child);
}
for (const definition of Object.values(schema.plugins || {})) {
	if (definition.title)
		required.add(definition.title);
	if (definition.description)
		required.add(definition.description);
	for (const field of definition.fields || [])
		addSchemaField(field);
}

const pluginTypes = JSON.parse(fs.readFileSync('root/usr/share/oxidns/plugin-types.json', 'utf8'));
const pluginCategories = ['servers', 'executors', 'matchers', 'providers'];
const knownPluginTypes = new Set();
for (const category of pluginCategories) {
	if (!Array.isArray(pluginTypes[category]) || !pluginTypes[category].length)
		throw new Error(`plugin-types.json: ${category} must be a non-empty array`);
	for (const type of pluginTypes[category]) {
		if (typeof type !== 'string' || !type)
			throw new Error(`plugin-types.json: ${category} contains an invalid plugin type`);
		knownPluginTypes.add(type);
	}
}
for (const type of Object.keys(schema.plugins || {})) {
	if (!knownPluginTypes.has(type))
		throw new Error(`plugin-types.json: schema plugin type ${type} is missing from the fallback catalog`);
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
sh -n root/etc/init.d/oxidns
sh -n scripts/build-luci-package.sh
sh -n scripts/integration-check.sh
sh -n scripts/service-check.sh
sh -n scripts/release-check.sh
sh -n scripts/verify-packages.sh
