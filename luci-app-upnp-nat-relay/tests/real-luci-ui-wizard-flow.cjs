'use strict';

/* Exercise every setup-wizard step in Safe mode across the existing viewport
 * and theme matrix. Only the read-only network-check RPC is fixture-backed;
 * the final Safe-mode Save uses real LuCI UCI/apply RPCs with the service off. */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const base = process.env.UPNP_UI_BASE || 'http://127.0.0.1:18083';
const container = process.env.UPNP_UI_CONTAINER || 'upnp-ui-gate';
const password = process.env.UPNP_UI_PASSWORD || 'upnp-gate';
const language = process.env.UPNP_UI_LANG || 'en';
const output = path.join(process.env.UPNP_VISUAL_OUT || path.join(process.cwd(), 'real-luci-ui-evidence'), 'wizard-flow');
if (!['en', 'zh_cn'].includes(language)) throw new Error('Unsupported UPNP_UI_LANG: ' + language);

const commonWidths = [320, 360, 375, 390, 430, 640, 768, 1024, 1280, 1440, 1920];
const breakpoints = [600, 700, 768, 900, 991, 1023, 1048, 1319];
const widths = [...new Set([...commonWidths, ...breakpoints.flatMap(w => [w - 1, w, w + 1])])].sort((a, b) => a - b);
const viewports = [...widths.map(width => ({ width, height: 900 })), { width: 320, height: 568 }, { width: 568, height: 320 }];
const themes = [
	{ id: 'bootstrap-default-light', media: 'bootstrap', theme: 'bootstrap', colorScheme: 'light', dark: 'false' },
	{ id: 'bootstrap-default-dark', media: 'bootstrap', theme: 'bootstrap', colorScheme: 'dark', dark: 'true' },
	{ id: 'bootstrap-light', media: 'bootstrap-light', theme: 'bootstrap-light', colorScheme: 'light', dark: 'false' },
	{ id: 'bootstrap-dark', media: 'bootstrap-dark', theme: 'bootstrap-dark', colorScheme: 'dark', dark: 'true' },
	{ id: 'aurora-light', media: 'aurora', theme: 'aurora', colorScheme: 'light', dark: 'false', aurora: 'light' },
	{ id: 'aurora-dark', media: 'aurora', theme: 'aurora', colorScheme: 'dark', dark: 'true', aurora: 'dark' }
];
const themeSet = process.env.LUCI_UI_THEME_SET || 'all';
if (!['all', 'bootstrap-only'].includes(themeSet))
	throw new Error('Unsupported LUCI_UI_THEME_SET: ' + themeSet);
const selectedThemes = themeSet === 'bootstrap-only'
	? themes.filter(theme => theme.media !== 'aurora')
	: themes;
const report = {
	schemaVersion: 1,
	sha: process.env.GITHUB_SHA || 'unknown',
	language,
	mode: 'all-wizard-steps-with-real-read-only-checks-plus-real-safe-save',
	themeSet,
	themes: selectedThemes.map(theme => theme.id),
	widths,
	shortViewports: viewports.filter(v => v.height !== 900),
	notCovered: ['Auto mode network/firewall changes and service start are intentionally excluded from this disposable host-network LuCI container.'],
	rows: [],
	errors: [],
	safeSave: null
};
fs.mkdirSync(output, { recursive: true });

function shell(command) {
	return execFileSync('docker', ['exec', container, 'sh', '-c', command], { encoding: 'utf8' }).trim();
}

async function login(page) {
	await page.goto(base + '/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
	const passwordField = page.locator('input[name="luci_password"]');
	if (await passwordField.count()) {
		await page.locator('input[name="luci_username"]').fill('root');
		await passwordField.fill(password);
		const submit = page.locator('button[type="submit"], input[type="submit"]').first();
		if (await submit.count()) await submit.click(); else await passwordField.press('Enter');
	}
	await page.waitForTimeout(700);
	if (await page.locator('input[name="luci_password"]').count()) throw new Error('LuCI login failed');
}

async function waitForStep(page, step) {
	await page.waitForFunction(n => {
		const title = document.querySelector('#wizard-step h3');
		return title && (title.textContent.includes(`Step ${n} of 10`) || title.textContent.includes(`第 ${n} 步，共 10 步`));
	}, step, { timeout: 12000 });
	await page.waitForTimeout(100);
}

async function ensureChoice(select, value, label) {
	await select.evaluate((el, choice) => {
		if (!Array.from(el.options).some(option => option.value === choice.value))
			el.appendChild(new Option(choice.label, choice.value));
	}, { value, label });
	await select.selectOption(value);
	await select.dispatchEvent('change');
}

async function prepareStep(page, step) {
	if (step === 1) {
		const iface = page.locator('#wiz-ifname');
		await page.waitForTimeout(150);
		await ensureChoice(iface, 'eth-ui-gate', 'eth-ui-gate (test fixture)');
	} else if (step === 2) {
		await page.locator('#wiz-bind-ip').fill('192.0.2.10');
	} else if (step === 3) {
		await page.locator('#wiz-lan-gw').fill('192.0.2.1');
		await page.locator('#wiz-lan-subnet').fill('192.0.2.0/24');
	} else if (step === 4 || step === 5) {
		const result = page.locator(step === 4 ? '#wiz-ping-result' : '#wiz-upnpc-result');
		await result.waitFor({ state: 'visible', timeout: 5000 });
		await page.waitForFunction(selector => {
			const node = document.querySelector(selector);
			return node && (!node.textContent.includes('Testing') && !node.textContent.includes('正在测试'));
		}, step === 4 ? '#wiz-ping-result' : '#wiz-upnpc-result', { timeout: 25000 });
	} else if (step === 6) {
		await page.locator('#wiz-wan-ip').fill('198.51.100.2');
	} else if (step === 7) {
		await page.waitForTimeout(150);
		await ensureChoice(page.locator('#wiz-wan-if'), 'wan-ui-gate', 'wan-ui-gate (test fixture)');
	} else if (step === 8) {
		await page.locator('#wiz-port-range').fill('40000-40100');
	} else if (step === 9) {
		await page.locator('#wiz-oc-mode').selectOption('prompt');
	} else if (step === 10) {
		await page.locator('#wiz-enable').selectOption('0');
	}
}

async function captureStep(page, theme, viewport, step) {
	const key = `${viewport.width}x${viewport.height}`;
	const dir = path.join(output, 'visual', language);
	const name = `${theme.id}-${key}-step-${String(step).padStart(2, '0')}.png`;
	const metrics = await page.evaluate(() => {
		const root = document.documentElement;
		const main = document.querySelector('#maincontent');
		const title = document.querySelector('#wizard-step h3');
		const nav = document.querySelector('#wizard-step .ubr-wizard-nav');
		const progress = document.querySelector('.ubr-wizard-progress');
		return {
			width: innerWidth,
			height: innerHeight,
			scrollWidth: root.scrollWidth,
			overflow: root.scrollWidth > innerWidth + 1,
			step: title && title.textContent.trim(),
			progressRows: progress ? new Set(Array.from(progress.querySelectorAll('.ubr-wizard-dot')).map(el => Math.round(el.getBoundingClientRect().top))).size : null,
			navigationVisible: !!nav && getComputedStyle(nav).display !== 'none',
			mainText: (main && main.innerText || '').slice(0, 1600)
		};
	});
	const errors = [];
	if (metrics.overflow) errors.push('horizontal-overflow');
	if (metrics.step !== `Step ${step} of 10` && !metrics.step.endsWith(`第 ${step} 步，共 10 步`)) errors.push('wrong-step-title');
	if (!metrics.navigationVisible) errors.push('navigation-not-visible');
	if (viewport.width <= 375 && metrics.progressRows !== 1) errors.push('wizard-progress-wraps-at-mobile-width');
	const file = path.join(dir, name);
	fs.mkdirSync(dir, { recursive: true });
	await page.screenshot({ path: file, fullPage: true, animations: 'disabled' });
	if (viewport.height < 900)
		await page.screenshot({ path: file.replace(/\.png$/, '-viewport.png'), fullPage: false, animations: 'disabled' });
	const row = { theme: theme.id, language, viewport: key, step, result: errors.length ? 'FAIL' : 'PASS', metrics, screenshot: path.relative(output, file), errors };
	report.rows.push(row);
	if (errors.length) report.errors.push(row);
	fs.writeFileSync(path.join(output, `report-${language}.json`), JSON.stringify(report, null, 2) + '\n');
	if (errors.length) throw new Error(`${theme.id} ${key} step ${step}: ${errors.join(', ')}`);
}

async function advance(page, step) {
	await page.locator('#wizard-step .ubr-wizard-nav button').last().click();
	await waitForStep(page, step + 1);
}

async function openWizard(page, viewport) {
	await page.setViewportSize(viewport);
	await page.goto(base + '/cgi-bin/luci/admin/services/upnp_nat_relay/wizard', {
		waitUntil: 'domcontentloaded', timeout: 30000
	});
	await page.waitForFunction(() => {
		const main = document.querySelector('#maincontent');
		return main && main.innerText.trim().length > 10 && !/Loading view|加载视图/.test(main.innerText);
	}, null, { timeout: 20000 });
	await waitForStep(page, 1);
}

async function runFlow(page, theme, viewport, takeScreenshots) {
	await openWizard(page, viewport);
	for (let step = 1; step <= 10; step++) {
		await waitForStep(page, step);
		await prepareStep(page, step);
		if (takeScreenshots) await captureStep(page, theme, viewport, step);
		if (step < 10) await advance(page, step);
	}
}

(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE || undefined });
	report.browser = { version: browser.version(), playwrightVersion: require('playwright/package.json').version };
	let page;
	try {
		for (const theme of selectedThemes) {
			shell(`uci set luci.main.mediaurlbase='/luci-static/${theme.media}'; uci set luci.main.theme='${theme.theme}'; uci commit luci; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/uhttpd restart >/dev/null 2>&1`);
			await new Promise(resolve => setTimeout(resolve, 600));
			const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: theme.colorScheme });
			if (theme.aurora) await context.addInitScript(mode => localStorage.setItem('aurora.theme', mode), theme.aurora);
			page = await context.newPage();
			await login(page);
			for (const viewport of viewports)
				await runFlow(page, theme, viewport, true);
			await context.close();
		}

		// One real Safe-mode submission per language, in the isolated OpenWrt
		// job container. Keep the service disabled and verify persisted UCI.
		const baselineConfigSha = shell('sha256sum /etc/config/upnp_nat_relay');
		shell("uci set luci.main.mediaurlbase='/luci-static/bootstrap'; uci set luci.main.theme='bootstrap'; uci commit luci; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/uhttpd restart >/dev/null 2>&1");
		const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: 'light' });
		page = await context.newPage();
		await login(page);
		await runFlow(page, { id: 'safe-save-real' }, { width: 1280, height: 900 }, false);
		await page.locator('#wiz-apply-btn').click();
		const savedMessage = language === 'en' ? 'Configuration saved successfully.' : '配置保存成功。';
		await page.getByText(savedMessage).waitFor({ state: 'visible', timeout: 30000 });
		const persisted = shell("uci get upnp_nat_relay.main.bind_ifname; uci get upnp_nat_relay.main.bind_ip; uci get upnp_nat_relay.main.downstream_lan_gateway; uci get upnp_nat_relay.main.downstream_lan_subnet; uci get upnp_nat_relay.main.downstream_wan_ip; uci get upnp_nat_relay.main.upstream_wan_if; uci get upnp_nat_relay.main.allowed_external_ports; uci get upnp_nat_relay.main.enabled");
		const values = persisted.split('\n');
		const expected = ['eth-ui-gate', '192.0.2.10', '192.0.2.1', '192.0.2.0/24', '198.51.100.2', 'wan-ui-gate', '40000-40100', '0'];
		const pending = shell('uci changes upnp_nat_relay');
		if (JSON.stringify(values) !== JSON.stringify(expected) || pending)
			throw new Error('Safe-mode UCI save mismatch: ' + JSON.stringify({ values, pending }));
		await page.screenshot({ path: path.join(output, `safe-save-${language}-success.png`), fullPage: true, animations: 'disabled' });
		report.safeSave = {
			result: 'PASS', values, serviceEnabled: false,
			baselineConfigSha, finalConfigSha: shell('sha256sum /etc/config/upnp_nat_relay'),
			isolatedContainerWillBeRemoved: true, screenshot: `safe-save-${language}-success.png`
		};
		fs.writeFileSync(path.join(output, `report-${language}.json`), JSON.stringify(report, null, 2) + '\n');
		await context.close();
	} catch (error) {
		report.errors.push({ fatal: error.stack || error.message });
		fs.writeFileSync(path.join(output, `report-${language}.json`), JSON.stringify(report, null, 2) + '\n');
		throw error;
	} finally {
		if (page) await page.close().catch(() => {});
		await browser.close();
	}
	const expectedRows = selectedThemes.length * viewports.length * 10;
	const pass = report.rows.filter(row => row.result === 'PASS').length;
	console.log('WIZARD_FLOW_MATRIX ' + JSON.stringify({ themeSet, themes: selectedThemes.map(theme => theme.id), total: report.rows.length, expected: expectedRows, pass, fail: report.errors.length, safeSave: report.safeSave }));
	if (report.rows.length !== expectedRows || report.errors.length || report.safeSave?.result !== 'PASS') process.exitCode = 1;
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
