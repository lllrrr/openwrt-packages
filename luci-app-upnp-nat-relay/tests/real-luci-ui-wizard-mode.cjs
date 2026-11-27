'use strict';

/* Capture both interactive selection states in the setup wizard. This only
 * changes client-side mode selection; it never advances a step or submits. */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const base = process.env.UPNP_UI_BASE || 'http://127.0.0.1:18083';
const container = process.env.UPNP_UI_CONTAINER || 'upnp-ui-gate';
const password = process.env.UPNP_UI_PASSWORD || 'upnp-gate';
const language = process.env.UPNP_UI_LANG || 'en';
const output = path.join(process.env.UPNP_VISUAL_OUT || path.join(process.cwd(), 'real-luci-ui-evidence'), 'wizard-mode');
const labels = language === 'en'
	? { safe: 'Safe Mode (Detect Only)', auto: 'Auto Mode (Apply Changes)' }
	: language === 'zh_cn'
		? { safe: '安全模式（仅检测）', auto: '自动模式（应用更改）' }
		: null;
if (!labels) throw new Error('Unsupported UPNP_UI_LANG: ' + language);

const commonWidths = [320, 360, 375, 390, 430, 640, 768, 1024, 1280, 1440, 1920];
const breakpoints = [600, 700, 768, 900, 991, 1023, 1048, 1319];
const widths = [...new Set([...commonWidths, ...breakpoints.flatMap(w => [w - 1, w, w + 1])])]
	.sort((a, b) => a - b);
const shortViewports = [{ width: 320, height: 568 }, { width: 568, height: 320 }];
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
const viewports = [...widths.map(width => ({ width, height: 900 })), ...shortViewports];
const report = {
	schemaVersion: 1,
	sha: process.env.GITHUB_SHA || 'unknown',
	language,
	mode: 'wizard-mode-selection-only',
	themeSet,
	themes: selectedThemes.map(theme => theme.id),
	notCovered: ['wizard step transitions and final configuration submission'],
	rows: [],
	errors: []
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
		if (await submit.count()) await submit.click();
		else await passwordField.press('Enter');
	}
	await page.waitForTimeout(800);
	if (await page.locator('input[name="luci_password"]').count()) throw new Error('LuCI login failed');
}

async function assertMode(page, mode) {
	const safe = page.locator('.ubr-wizard-mode-bar button').nth(0);
	const auto = page.locator('.ubr-wizard-mode-bar button').nth(1);
	if (await page.locator('.ubr-wizard-mode-bar button').count() !== 2)
		throw new Error('Wizard mode selector must render exactly two buttons');
	const expected = mode === 'safe' ? ['true', 'false'] : ['false', 'true'];
	const actual = [await safe.getAttribute('aria-pressed'), await auto.getAttribute('aria-pressed')];
	const active = [
		await safe.evaluate(el => el.classList.contains('cbi-button-apply')),
		await auto.evaluate(el => el.classList.contains('cbi-button-apply'))
	];
	if (actual[0] !== expected[0] || actual[1] !== expected[1] ||
		active[0] !== (mode === 'safe') || active[1] !== (mode === 'auto')) {
		throw new Error(`Wrong ${mode} selection: aria=${actual.join(',')} active=${active.join(',')}`);
	}
}

async function capture(page, theme, viewport, mode) {
	const { width, height } = viewport;
	const suffix = height === 900 ? `${width}` : `${width}x${height}`;
	const name = `${theme.id}-${suffix}-${mode}.png`;
	const errors = [];
	const onConsole = m => { if (m.type() === 'error') errors.push(m.text()); };
	const onPageError = e => errors.push('PAGE_ERROR ' + e.message);
	page.on('console', onConsole);
	page.on('pageerror', onPageError);
	let metrics = null;
	try {
		await page.setViewportSize({ width, height });
		await page.goto(base + '/cgi-bin/luci/admin/services/upnp_nat_relay/wizard', {
			waitUntil: 'domcontentloaded', timeout: 30000
		});
		await page.waitForFunction(() => {
			const main = document.querySelector('#maincontent');
			return main && main.innerText.trim().length > 10 && !/Loading view|加载视图/.test(main.innerText);
		}, null, { timeout: 20000 });
		const safe = page.locator('.ubr-wizard-mode-bar button').nth(0);
		const auto = page.locator('.ubr-wizard-mode-bar button').nth(1);
		await (mode === 'safe' ? safe : auto).click();
		await assertMode(page, mode);
		metrics = await page.evaluate(({ expectedDark }) => {
			const root = document.documentElement;
			const main = document.querySelector('#maincontent');
			const bar = main && main.querySelector('.ubr-wizard-mode-bar');
			const buttons = bar ? Array.from(bar.querySelectorAll('button')) : [];
			return {
				width: innerWidth,
				height: innerHeight,
				scrollWidth: root.scrollWidth,
				overflow: root.scrollWidth > innerWidth + 1,
				darkMode: root.getAttribute('data-darkmode'),
				themeDarkExpected: expectedDark,
				buttonCount: buttons.length,
				buttonRects: buttons.map(el => {
					const r = el.getBoundingClientRect();
					return { left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top), bottom: Math.round(r.bottom) };
				}),
				mainText: (main && main.innerText || '').slice(0, 900)
			};
		}, { expectedDark: theme.dark });
		if (metrics.overflow) throw new Error('Horizontal overflow in wizard mode selection');
		if (metrics.darkMode !== theme.dark) throw new Error('Theme dark mode mismatch');
		await page.screenshot({ path: path.join(output, name), fullPage: true, animations: 'disabled' });
		if (height < 900)
			await page.screenshot({ path: path.join(output, name.replace(/\.png$/, '-viewport.png')), fullPage: false, animations: 'disabled' });
	} catch (e) {
		report.errors.push({ theme: theme.id, viewport: `${width}x${height}`, mode, error: e.message, browserErrors: errors.slice(0, 8) });
	} finally {
		page.off('console', onConsole);
		page.off('pageerror', onPageError);
	}
	if (errors.length) report.errors.push({ theme: theme.id, viewport: `${width}x${height}`, mode, error: 'browser-errors', browserErrors: errors.slice(0, 8) });
	const row = { theme: theme.id, language, mode, viewport: `${width}x${height}`, result: metrics && !errors.length ? 'PASS' : 'FAIL', metrics, screenshot: name, viewportScreenshot: height < 900 ? name.replace(/\.png$/, '-viewport.png') : null, errors: errors.slice(0, 8) };
	report.rows.push(row);
	fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
	console.log(`${row.result} ${theme.id} ${row.viewport} mode=${mode}${row.errors.length ? ' -- ' + row.errors.join(', ') : ''}`);
}

(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE || undefined });
	report.browser = { version: browser.version(), playwrightVersion: require('playwright/package.json').version };
	try {
		for (const theme of selectedThemes) {
			shell(`uci set luci.main.mediaurlbase='/luci-static/${theme.media}'; uci set luci.main.theme='${theme.theme}'; uci commit luci; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/uhttpd restart >/dev/null 2>&1`);
			await new Promise(resolve => setTimeout(resolve, 900));
			const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: theme.colorScheme });
			if (theme.aurora) await context.addInitScript(mode => localStorage.setItem('aurora.theme', mode), theme.aurora);
			const page = await context.newPage();
			try {
				await login(page);
				for (const viewport of viewports) {
					await capture(page, theme, viewport, 'safe');
					await capture(page, theme, viewport, 'auto');
				}
			} finally { await context.close(); }
		}
	} finally { await browser.close(); }
	const expected = selectedThemes.length * viewports.length * 2;
	const pass = report.rows.filter(row => row.result === 'PASS').length;
	console.log('WIZARD_MODE_MATRIX ' + JSON.stringify({ themeSet, themes: selectedThemes.map(theme => theme.id), total: report.rows.length, expected, pass, fail: report.errors.length }));
	if (report.rows.length !== expected || report.errors.length) process.exitCode = 1;
})().catch(error => {
	report.errors.push({ fatal: error.stack || error.message });
	fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
	console.error(error);
	process.exitCode = 1;
});
