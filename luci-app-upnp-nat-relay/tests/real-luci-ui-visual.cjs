'use strict';
/* Real LuCI screenshot matrix. Automated checks cover route/render/assets and
 * clipping; screenshots require a separate full-resolution visual review. */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const base = process.env.UPNP_UI_BASE || 'http://127.0.0.1:18083';
const container = process.env.UPNP_UI_CONTAINER || 'upnp-ui-gate';
const password = process.env.UPNP_UI_PASSWORD || 'upnp-gate';
const output = process.env.UPNP_VISUAL_OUT || path.join(process.cwd(), 'real-luci-ui-evidence');
const language = process.env.UPNP_UI_LANG || 'en';
const lang = language === 'en' ? 0 : language === 'zh_cn' ? 1 : -1;
if (lang < 0) throw new Error('Unsupported UPNP_UI_LANG: ' + language);

const routes = [
	{ path: 'overview', id: 'overview', label: ['Overview', '概览'] },
	{ path: 'wizard', id: 'wizard', label: ['Setup Wizard', '设置向导'] },
	{ path: 'settings', id: 'settings', label: ['Settings', '设置'] },
	{ path: 'network', id: 'network', label: ['Network', '网络'] },
	{ path: 'security', id: 'security', label: ['Security', '安全'] },
	{ path: 'mappings', id: 'mappings', label: ['Mappings', '映射表'] },
	{ path: 'openclash', id: 'openclash', label: ['OpenClash', 'OpenClash'] },
	{ path: 'diagnostics', id: 'diagnostics', label: ['Logs', '日志'] }
];
const commonWidths = [320, 360, 375, 390, 430, 640, 768, 1024, 1280, 1440, 1920];
const breakpoints = [600, 700, 768, 900, 991, 1023, 1048, 1319];
const allWidths = [...new Set([...commonWidths, ...breakpoints.flatMap(w => [w - 1, w, w + 1])])].sort((a, b) => a - b);
const shortViewports = [{ width: 320, height: 568 }, { width: 568, height: 320 }];
const themes = [
	{ id: 'bootstrap-default-light', media: 'bootstrap', theme: 'bootstrap', colorScheme: 'light', dark: 'false' },
	{ id: 'bootstrap-default-dark', media: 'bootstrap', theme: 'bootstrap', colorScheme: 'dark', dark: 'true' },
	{ id: 'bootstrap-light', media: 'bootstrap-light', theme: 'bootstrap-light', colorScheme: 'light', dark: 'false' },
	{ id: 'bootstrap-dark', media: 'bootstrap-dark', theme: 'bootstrap-dark', colorScheme: 'dark', dark: 'true' },
	{ id: 'aurora-light', media: 'aurora', theme: 'aurora', colorScheme: 'light', dark: 'false', aurora: 'light' },
	{ id: 'aurora-dark', media: 'aurora', theme: 'aurora', colorScheme: 'dark', dark: 'true', aurora: 'dark' }
];
const smoke = process.env.UPNP_UI_SMOKE_ONLY === '1';
if (smoke && process.env.GITHUB_ACTIONS === 'true') throw new Error('Smoke-only mode is prohibited in GitHub Actions');
const selectedThemes = smoke ? themes.filter(t => t.id === 'aurora-light') : themes;
const selectedWidths = smoke ? [320, 1280] : allWidths;
const report = {
	schemaVersion: 1, sha: process.env.GITHUB_SHA || 'unknown', language,
	environment: 'OpenWrt 24.10.8 rootfs with LuCI and UPnP NAT Relay files; service remains disabled',
	mode: smoke ? 'local-smoke-only' : 'full-matrix', routes: routes.map(r => r.path),
	widths: selectedWidths, shortViewports,
	method: 'Eight registered views and root alias; common and breakpoint-adjacent CSS widths; short portrait/landscape; Bootstrap system/default, explicit Light/Dark, Aurora Light/Dark.',
	notCovered: ['manual visual review', 'wizard step transitions and real service/network mutations', 'populated mappings and long logs'], rows: [], errors: []
};
fs.mkdirSync(output, { recursive: true });

function shell(cmd) { return execFileSync('docker', ['exec', container, 'sh', '-c', cmd], { encoding: 'utf8' }).trim(); }

async function login(page) {
	await page.goto(base + '/cgi-bin/luci/', { waitUntil: 'domcontentloaded' });
	const username = page.locator('input[name="luci_username"]');
	if (await username.count()) {
		await username.fill('root');
		await page.locator('input[name="luci_password"]').fill(password);
		const submit = page.locator('button[type="submit"], input[type="submit"]').first();
		if (await submit.count()) await submit.click(); else await page.locator('input[name="luci_password"]').press('Enter');
	}
	await page.waitForTimeout(800);
	if (await page.locator('input[name="luci_password"]').count()) throw new Error('LuCI login failed');
}

async function capture(page, theme, route, width, height, view) {
	const size = height === 900 ? `${width}` : `${width}x${height}`;
	const name = `${theme.id}-${size}-${view}.png`;
	const errors = [];
	const onConsole = m => { if (m.type() === 'error') errors.push(m.text()); };
	const onPageError = e => errors.push('PAGE_ERROR ' + e.message);
	page.on('console', onConsole); page.on('pageerror', onPageError);
	let metrics = null, navigationError = null;
	try {
		await page.setViewportSize({ width, height });
		const pathPart = route ? '/' + route.path : '';
		await page.goto(base + '/cgi-bin/luci/admin/services/upnp_nat_relay' + pathPart, { waitUntil: 'domcontentloaded', timeout: 30000 });
		await page.waitForFunction(() => {
			const main = document.querySelector('#maincontent');
			return main && main.innerText.trim().length > 10 && !/Loading view|加载视图/.test(main.innerText);
		}, null, { timeout: 20000 });
		await page.waitForTimeout(400);
		metrics = await page.evaluate(({ media, routeId }) => {
			const root = document.documentElement, main = document.querySelector('#maincontent');
			const overviewStatsGrid = routeId === 'overview' && main ? main.querySelector('.ubr-stats-grid') : null;
			const overviewStatusBanner = overviewStatsGrid && overviewStatsGrid.previousElementSibling;
			const overviewFirstStatValue = overviewStatsGrid && overviewStatsGrid.querySelector('.ubr-stat-value');
			const overviewStatLabels = overviewStatsGrid ? Array.from(overviewStatsGrid.querySelectorAll('.ubr-stat-label')) : [];
			const overviewLastStatLabel = overviewStatLabels.length ? overviewStatLabels[overviewStatLabels.length - 1] : null;
			const visibleTextRect = (element, edge) => {
				if (!element) return null;
				const range = document.createRange();
				range.selectNodeContents(element);
				const rects = Array.from(range.getClientRects());
				if (!rects.length) return null;
				const rect = edge === 'bottom' ? rects[rects.length - 1] : rects[0];
				return edge === 'bottom' ? rect.bottom : rect.top;
			};
			const overviewControlSection = routeId === 'overview' && main
				? main.querySelector('.ubr-overview-control-section') : null;
			const overviewControlHeading = overviewControlSection && overviewControlSection.querySelector('h3');
			const dependencyHeading = routeId === 'overview' && main
				? Array.from(main.querySelectorAll('.cbi-section h3')).map(el => el.textContent.trim()).find(text => text === 'Dependency Status' || text === '依赖状态') || null
				: null;
			const overviewStatsVisibleTopGap = overviewStatusBanner && overviewFirstStatValue
				? Math.round(visibleTextRect(overviewFirstStatValue, 'top') - overviewStatusBanner.getBoundingClientRect().bottom) : null;
			const overviewStatsVisibleBottomGap = overviewLastStatLabel && overviewControlHeading
				? Math.round(visibleTextRect(overviewControlHeading, 'top') - visibleTextRect(overviewLastStatLabel, 'bottom')) : null;
			const overviewStatsVisibleGapDelta = overviewStatsVisibleTopGap == null || overviewStatsVisibleBottomGap == null
				? null : Math.abs(overviewStatsVisibleTopGap - overviewStatsVisibleBottomGap);
			const overviewControlNext = overviewControlSection && overviewControlSection.nextElementSibling;
			const overviewControlGap = overviewControlSection && overviewControlNext
				? Math.round(overviewControlNext.getBoundingClientRect().top - overviewControlSection.getBoundingClientRect().bottom) : null;
			const wizardProgress = routeId === 'wizard' && main && main.querySelector('.ubr-wizard-progress');
		const logArea = routeId === 'diagnostics' && main && main.querySelector('.ubr-log-area');
		const rollbackSection = routeId === 'diagnostics' && main && main.querySelector('.ubr-rollback-section');
		const logToRollbackGap = logArea && rollbackSection ? Math.round(rollbackSection.getBoundingClientRect().top - logArea.getBoundingClientRect().bottom) : null;
		const mappingEmptyState = routeId === 'mappings' && main ? {
			tables: ['raw-mappings-table', 'synced-mappings-table', 'rejected-mappings-table'].filter(id => main.querySelector('#' + id)).length,
			messages: Array.from(main.querySelectorAll('[data-empty-mapping-state]')).filter(el => el.textContent.trim() && el.getClientRects().length).length
		} : null;
		// Connector lines sit on the dots' center line, so count only the step
		// markers when measuring rows; treating each child top as a row creates a
		// false second row even when all markers are on one line.
		const wizardProgressRows = wizardProgress ? new Set(Array.from(wizardProgress.querySelectorAll('.ubr-wizard-dot')).map(el => Math.round(el.getBoundingClientRect().top))).size : null;
			const duplicateTableLabels = Array.from((main && main.querySelectorAll('tr')) || []).filter(row => {
				const heading = row.querySelector('th');
				const value = row.querySelector('td[data-title]');
				return heading && value && heading.textContent.trim() === value.getAttribute('data-title').trim();
			}).length;
			const menu = document.querySelector('#tabmenu');
			const assets = Array.from(document.querySelectorAll('link[href],script[src]')).map(x => x.href || x.src);
			const footer = document.querySelector('.ys-tool-footer');
			const footerMark = footer && footer.querySelector('.ys-tool-footer-mark');
			const footerSocial = footer && footer.querySelector('.ys-tool-footer-link.github');
			const footerLabel = footerSocial && footerSocial.querySelector('.ys-tool-footer-link-label');
			const footerCssFresh = assets.some(src => src.includes('upnp-nat-relay.css') && src.includes('ui=footer-pm-match-1'));
			const footerMarkHeight = footerMark ? footerMark.getBoundingClientRect().height : null;
			const footerSocialRect = footerSocial && footerSocial.getBoundingClientRect();
			const footerLabelRect = footerLabel && footerLabel.getBoundingClientRect();
			const footerSocialBg = footerSocial && getComputedStyle(footerSocial, '::before');
			const footerMatchesPm = !!(footerMarkHeight && footerSocialRect && footerLabelRect && footerSocialBg &&
				Math.abs(parseFloat(footerSocialBg.height) - footerMarkHeight) <= 1 &&
				footerSocialBg.left === '0px' && footerSocialBg.right === '0px' &&
				footerSocialBg.backgroundColor !== 'rgba(0, 0, 0, 0)' &&
				getComputedStyle(footerSocial).backgroundColor === 'rgba(0, 0, 0, 0)' &&
				footerLabelRect.left >= footerSocialRect.left && footerLabelRect.right <= footerSocialRect.right + 1);
			const links = menu ? Array.from(menu.querySelectorAll('a')).map(a => {
				const r = a.getBoundingClientRect();
				return { label: a.textContent.trim(), active: !!a.closest('li.active, [aria-current="page"]'),
					left: Math.round(r.left), right: Math.round(r.right), visible: r.width > 0 && r.height > 0 && r.left >= -1 && r.right <= innerWidth + 1 };
			}) : [];
			const active = links.filter(x => x.active);
			const truncation = Array.from((main || document).querySelectorAll('*')).filter(el => {
				if (/^(INPUT|TEXTAREA|SELECT|CAPTION)$/.test(el.tagName) || el.closest('.cbi-dropdown, #tabmenu')) return false;
				const css = getComputedStyle(el);
				return css.whiteSpace === 'nowrap' && el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 2;
			}).slice(0, 8).map(el => ({ tag: el.tagName, text: (el.innerText || '').trim().slice(0, 80) }));
			return { heading: (main && main.querySelector('h2[name="content"], .view h2, h2') || {}).textContent?.trim() || '',
				hasMain: !!main, mainLength: (main && main.innerText || '').trim().length,
				loading: !!(main && /Loading view|加载视图/.test(main.innerText)),
				darkMode: root.getAttribute('data-darkmode'), scrollWidth: root.scrollWidth, width: innerWidth,
				overflow: root.scrollWidth > innerWidth + 1,
				duplicateTableLabels,
				themeLoaded: assets.some(src => src.includes('/luci-static/' + media + '/')),
				pluginCssLoaded: assets.some(src => src.includes('upnp-nat-relay/upnp-nat-relay.css')),
				footerCssFresh,
				footerMatchesPm,
				tabMenu: { count: links.length, visibleCount: links.filter(x => x.visible).length, links, active },
				wizardProgressRows,
				dependencyHeading,
				overviewControlGap,
				overviewStatsVisibleTopGap,
				overviewStatsVisibleBottomGap,
				overviewStatsVisibleGapDelta,
				logToRollbackGap,
				mappingEmptyState,
				truncation };
		}, { media: theme.media, routeId: route && route.id });
		await page.screenshot({ path: path.join(output, name), fullPage: true, animations: 'disabled' });
		if (height < 900) {
			const viewportName = name.replace(/\.png$/, '-viewport.png');
			await page.screenshot({ path: path.join(output, viewportName), fullPage: false, animations: 'disabled' });
			var viewportScreenshot = viewportName;
		}
	} catch (e) { navigationError = e.message; }
	finally { page.off('console', onConsole); page.off('pageerror', onPageError); }
	const failures = [];
	if (navigationError) failures.push('navigation-or-render: ' + navigationError);
	if (metrics) {
		if (!metrics.hasMain || metrics.mainLength < 10 || metrics.loading) failures.push('blank-or-loading-view');
		if (!metrics.themeLoaded) failures.push('theme-assets-not-loaded');
		if (!metrics.pluginCssLoaded) failures.push('plugin-css-not-loaded');
		if (!metrics.footerCssFresh || !metrics.footerMatchesPm) failures.push('footer-not-matched-to-performance-manager');
		if (metrics.overflow) failures.push('horizontal-overflow');
		if (metrics.duplicateTableLabels) failures.push('duplicate-mobile-table-labels');
		if (route && route.id === 'overview' && !metrics.dependencyHeading) failures.push('dependency-status-heading-missing');
		if (metrics.truncation.length) failures.push('truncated-non-dropdown-text');
		if (metrics.darkMode !== theme.dark) failures.push('theme-dark-mode-mismatch');
		if (metrics.tabMenu.active.some(x => !x.visible)) failures.push('active-tab-outside-visible-strip');
		if (metrics.tabMenu.count !== routes.length || metrics.tabMenu.visibleCount !== metrics.tabMenu.count) failures.push('route-tab-outside-visible-strip');
		if (route && !metrics.tabMenu.active.some(x => x.label === route.label[lang])) failures.push('wrong-active-tab');
		if (route && route.id === 'wizard' && width <= 375 && metrics.wizardProgressRows !== 1) failures.push('wizard-progress-wraps-at-mobile-width');
		if (route && route.id === 'overview' && (metrics.overviewControlGap == null || metrics.overviewControlGap < 16)) failures.push('overview-controls-and-service-information-too-close');
		if (route && route.id === 'diagnostics' && metrics.logToRollbackGap < 12) failures.push('log-output-and-rollback-section-too-close');
		if (route && route.id === 'mappings' && metrics.mappingEmptyState && (metrics.mappingEmptyState.tables !== 0 || metrics.mappingEmptyState.messages !== 3)) failures.push('empty-mapping-state-renders-unused-table-headers');
	}
	if (errors.length) failures.push('browser-errors');
	const row = { theme: theme.id, language, route: 'admin/services/upnp_nat_relay' + (route ? '/' + route.path : ''),
		view, viewport: `${width}x${height}`, result: failures.length ? 'FAIL' : 'PASS', failures, metrics,
		screenshot: name, viewportScreenshot: typeof viewportScreenshot === 'undefined' ? undefined : viewportScreenshot, errors: errors.slice(0, 8) };
	report.rows.push(row);
	if (failures.length) report.errors.push({ route: row.route, theme: theme.id, viewport: row.viewport, failures, errors: errors.slice(0, 8) });
	fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
	console.log(`${row.result} ${theme.id} ${row.viewport} ${view}${failures.length ? ' -- ' + failures.join(', ') : ''}`);
}

(async () => {
	const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE || undefined });
	try {
		for (const theme of selectedThemes) {
			shell(`uci set luci.main.mediaurlbase='/luci-static/${theme.media}'; uci set luci.main.theme='${theme.theme}'; uci commit luci; rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/uhttpd restart >/dev/null 2>&1`);
			await new Promise(resolve => setTimeout(resolve, 900));
			const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: theme.colorScheme });
			if (theme.aurora) await context.addInitScript(mode => localStorage.setItem('aurora.theme', mode), theme.aurora);
			const page = await context.newPage();
			try {
				await login(page);
				for (const width of selectedWidths) for (const route of routes) await capture(page, theme, route, width, 900, route.id);
				for (const viewport of shortViewports) for (const route of routes) await capture(page, theme, route, viewport.width, viewport.height, route.id);
				await capture(page, theme, null, 1280, 900, 'root-alias', false);
			} finally { await context.close(); }
		}
	} finally { await browser.close(); }
	const expected = selectedThemes.length * ((selectedWidths.length + shortViewports.length) * routes.length + 1);
	console.log('VISUAL_MATRIX ' + JSON.stringify({ total: report.rows.length, expected, pass: report.rows.filter(x => x.result === 'PASS').length, fail: report.errors.length }));
	if (report.rows.length !== expected || report.errors.length) process.exitCode = 1;
})().catch(e => {
	report.errors.push({ fatal: e.stack || e.message });
	fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
	console.error(e); process.exitCode = 1;
});
