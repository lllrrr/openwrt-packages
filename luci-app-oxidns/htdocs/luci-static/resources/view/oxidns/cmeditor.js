'use strict';
'require baseclass';

/*
 * CodeMirror 5 包装器：把普通 <textarea> 换成带行号、自动换行、固定视口的编辑器。
 *
 * 为什么要换：直接给 textarea 设 rows / min-height，编辑长文件时光标一走页面
 * 就跟着上下滚动（"输入框上下滑动"），超长行还会把整页横向撑开。CodeMirror 把
 * 内容放进固定高度的滚动容器，滚动只发生在编辑器内部，页面不再跳动。
 * 参考实现：sbwml/luci-app-mosdns 的 basic.js（CodeMirror.fromTextArea + autoRefresh）。
 *
 * 兼容既有代码：所有调用点仍然通过 textarea.value 读写内容 —— 这里把编辑器的
 * change 事件回写到 textarea，同时派发 input 事件，因此保存 / 校验 / dirty 判断
 * 都不需要改。加载失败时（资源缺失、老浏览器、SRI 不匹配）自动退回原来的 textarea 行为。
 */

/* 用 LuCI 的 resource 前缀，避免硬编码 /luci-static；老版本 LuCI 回退到常见路径 */
function assetBase() {
	if (typeof L === 'object' && L && typeof L.resource === 'function') {
		var base = L.resource('oxidns-codemirror');
		if (base)
			return base.replace(/\/*$/, '/');
	}

	return '/luci-static/resources/oxidns-codemirror/';
}

/* cmtheme.css 必须排在 codemirror.min.css 之后：后者自带 cm-s-default 的取色，
   同名特异性下靠顺序覆盖。 */
/* 资源版本：改动 cmtheme.css 或随包脚本时递增。manifest.json 保存同一版本与sha384。 */
var ASSET_VERSION = '20261125a';

var STYLES = [ 'codemirror.min.css', 'cmtheme.css' ];
var SCRIPTS = [ 'codemirror.min.js', 'yaml.min.js', 'autorefresh.min.js' ];

/* 本地计算得到的 sha384；SRI 校验失败时 onerror 会 resolve，页面退回 textarea */
var INTEGRITY = {
	'codemirror.min.css': 'sha384-6VWUkFlGT2mt2I7XhCqUho+vO2BKFrbXlB7IUw6icpZVOVYK7l2Uh369qZC4XWBJ',
	'cmtheme.css': 'sha384-ZoPwXPhXLEXwqIma0+wEIz6wCFssKfHxK/NfHNmlxcTH27Dusm9Fx6oHn+rshLkT',
	'codemirror.min.js': 'sha384-NWch1Syf1vprGF9U8eVPYsii8hcHqUbiN0DiKeQxtJInX81CD9tvSVN2aPNmm42+',
	'yaml.min.js': 'sha384-9q49Jm3hZMwxEMLImsxPxLiaptHpFz1PVa26Dg6SVIO+rj5kx0cgOM2+4ikKJFH9',
	'autorefresh.min.js': 'sha384-pn83o6MtS8kicn/sV6AhRaBqXQ5tau8NzA2ovcobkcc1uRFP7D8CMhRx231QwKST'
};

/* 主题名，对应 cmtheme.css 里的 .cm-s-lucicode */
var THEME = 'lucicode';

var themeWatches = [];
var cleanupObserver = null;

function isAttached(el) {
	return !!(el && document.body && typeof document.body.contains === 'function' && document.body.contains(el));
}

function setDarkClass(node, dark) {
	if (!node)
		return;

	var list = node.classList;

	if (!list) {
		var classes = String(node.className || '').split(/\s+/).filter(function(c) { return c && c !== 'cm-dark'; });
		if (dark)
			classes.push('cm-dark');
		node.className = classes.join(' ');
		return;
	}

	if (typeof list.toggle === 'function') {
		list.toggle('cm-dark', dark);
		/* 老浏览器把第二个参数当真值：用 contains 兜底校正 */
		if (list.contains && list.contains('cm-dark') !== dark) {
			if (dark)
				list.add('cm-dark');
			else
				list.remove('cm-dark');
		}
		return;
	}

	if (dark)
		list.add('cm-dark');
	else
		list.remove('cm-dark');
}

/*
 * 判断当前 LuCI 主题是深色还是浅色。
 *
 * 三条依据，按可靠性排序：
 *   1. <html>/<body> 上的 data-darkmode="true" —— bootstrap 主题的显式信号；
 *   2. 从编辑器自身往上找第一个不透明背景色（有的主题只给容器上色，body 是透明白）；
 *   3. 以上都判不出来就按浅色。
 *
 * 不认具体主题的类名（bootstrap / argon / material 各有一套），换主题也不会误判。
 */
function preferDark(el) {
	if (typeof window === 'undefined' || !window.getComputedStyle)
		return false;

	var attr = function(node) {
		return (node && typeof node.getAttribute === 'function')
			? node.getAttribute('data-darkmode') : null;
	};

	if (attr(document.documentElement) === 'true' || attr(document.body) === 'true')
		return true;

	for (var node = el || document.body; node && node.nodeType === 1; node = node.parentElement) {
		var m = /^rgba?\(([^)]+)\)/.exec(window.getComputedStyle(node).backgroundColor || '');
		if (!m)
			continue;

		var p = m[1].split(',').map(function(v) { return parseFloat(v); });

		/* 完全透明 = 这一层没上色，继续往上 */
		if (p.length >= 4 && p[3] === 0)
			continue;

		return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255 < 0.5;
	}

	return false;
}

function disposeThemeWatch(watch) {
	if (!watch)
		return;

	var idx = themeWatches.indexOf(watch);
	if (idx >= 0)
		themeWatches.splice(idx, 1);

	try {
		if (watch.observer)
			watch.observer.disconnect();
	} catch (e) {}

	try {
		if (watch.mq) {
			if (typeof watch.mq.removeEventListener === 'function')
				watch.mq.removeEventListener('change', watch.onChange);
			else if (typeof watch.mq.removeListener === 'function')
				watch.mq.removeListener(watch.onChange);
		}
	} catch (e) {}

	watch.observer = null;
	watch.mq = null;
	watch.onChange = null;
	watch.el = null;
	watch.cm = null;
}

function stopDetachedWatchers() {
	themeWatches.slice().forEach(function(watch) {
		if (!isAttached(watch.el))
			disposeThemeWatch(watch);
	});
}

function ensureCleanupObserver() {
	if (cleanupObserver || typeof MutationObserver !== 'function')
		return;

	var vp = document.getElementById('view');
	if (!vp)
		return;

	cleanupObserver = new MutationObserver(stopDetachedWatchers);
	cleanupObserver.observe(vp, { childList: true, subtree: false });
}

/*
 * 主题可能在编辑器挂载之后才被切换（bootstrap 的深色按钮就是运行时改
 * <html data-darkmode>，不刷新页面），所以挂载时判一次、之后持续跟随。
 * 返回的 watch 对象在视图卸载时必须 dispose()，否则 Observer 会泄漏。
 */
function watchTheme(cm, el) {
	var apply = function() {
		if (!cm || !cm.getWrapperElement)
			return;

		setDarkClass(cm.getWrapperElement(), preferDark(el));
	};

	var watch = { cm: cm, el: el, observer: null, mq: null, onChange: apply };

	apply();
	themeWatches.push(watch);
	ensureCleanupObserver();

	if (typeof MutationObserver === 'function') {
		watch.observer = new MutationObserver(apply);
		var opts = { attributes: true, attributeFilter: [ 'data-darkmode', 'class', 'style' ] };

		if (document.documentElement)
			watch.observer.observe(document.documentElement, opts);
		if (document.body)
			watch.observer.observe(document.body, opts);
	}

	if (typeof window.matchMedia === 'function') {
		watch.mq = window.matchMedia('(prefers-color-scheme: dark)');

		if (typeof watch.mq.addEventListener === 'function')
			watch.mq.addEventListener('change', apply);
		else if (typeof watch.mq.addListener === 'function')
			watch.mq.addListener(apply);
	}

	return watch;
}

return baseclass.extend({
	_promise: null,

	/* 资源只注入一次；返回 Promise<boolean> 表示 CodeMirror 是否可用 */
	load: function() {
		if (this._promise)
			return this._promise;

		if (typeof document === 'undefined') {
			this._promise = Promise.resolve(false);
			return this._promise;
		}

		var base = assetBase();

		STYLES.forEach(function(name) {
			var link = document.createElement('link');
			link.rel = 'stylesheet';
			link.href = base + name + '?v=' + ASSET_VERSION;
			if (INTEGRITY[name])
				link.integrity = INTEGRITY[name];
			document.head.appendChild(link);
		});

		this._promise = SCRIPTS.reduce(function(chain, name) {
			return chain.then(function() {
				return new Promise(function(resolve) {
					var script = document.createElement('script');
					script.src = base + name + '?v=' + ASSET_VERSION;
					if (INTEGRITY[name])
						script.integrity = INTEGRITY[name];
					script.onload = resolve;
					script.onerror = resolve;
					document.head.appendChild(script);
				});
			});
		}, Promise.resolve()).then(function() {
			return (typeof CodeMirror !== 'undefined' &&
				typeof CodeMirror.fromTextArea === 'function');
		});

		return this._promise;
	},

	/* 视口高度固定：页面不滚，只有编辑器内部滚 */
	defaultHeight: function() {
		var vh = (typeof window !== 'undefined' && window.innerHeight) ? window.innerHeight : 0;
		var px = vh ? Math.round(vh * 0.62) : 480;

		return Math.max(320, Math.min(560, px)) + 'px';
	},

	attach: function(textarea, opts) {
		if (!textarea || typeof CodeMirror === 'undefined' ||
		    typeof CodeMirror.fromTextArea !== 'function')
			return null;

		if (textarea._cmeditor)
			return textarea._cmeditor;

		opts = opts || {};

		var cm = CodeMirror.fromTextArea(textarea, {
			mode: opts.mode || null,
			theme: THEME,
			lineNumbers: true,
			lineWrapping: true,
			autoRefresh: true,
			/* styleActiveLine 需要未随包提供的 active-line.js，保持关闭 */
			indentUnit: 2,
			tabSize: 2,
			viewportMargin: 12
		});

		cm._oxidnsThemeWatch = watchTheme(cm, textarea.parentElement || document.body);

		cm.setSize('100%', opts.height || this.defaultHeight());

		/* change -> 回写 textarea + 派发 input，既有逻辑零改动 */
		cm.on('change', function() {
			textarea.value = cm.getValue();

			if (typeof Event === 'function')
				textarea.dispatchEvent(new Event('input'));
		});

		textarea._cmeditor = cm;

		return cm;
	},

	/* 视图卸载时调用：断开 Observer / matchMedia 监听并恢复 textarea */
	detach: function(textarea) {
		if (!textarea)
			return;

		var cm = textarea._cmeditor;

		if (cm) {
			if (cm._oxidnsThemeWatch)
				disposeThemeWatch(cm._oxidnsThemeWatch);

			try {
				if (typeof cm.toTextArea === 'function')
					cm.toTextArea();
			} catch (e) {}

			delete textarea._cmeditor;
		}

		stopDetachedWatchers();
	},

	/*
	 * fromTextArea 必须量到已挂载的尺寸，而 view 渲染出的节点要等 LuCI
	 * 插进文档后才在 DOM 里，所以这里轮询等待挂载（最多 6 秒），然后挂编辑器。
	 */
	defer: function(textarea, opts) {
		var self = this;
		var tries = 0;

		var tick = function() {
			if (typeof document === 'undefined')
				return;

			if (isAttached(textarea)) {
				self.attach(textarea, opts);
				return;
			}

			/* 最多等 6 秒，视图卸载时由调用方通过 detach() 主动清理 */
			if (++tries < 120)
				setTimeout(tick, 50);
		};

		setTimeout(tick, 0);
	},

	getValue: function(textarea) {
		if (textarea && textarea._cmeditor)
			return textarea._cmeditor.getValue();

		return textarea ? String(textarea.value === null || textarea.value === undefined ? '' : textarea.value) : '';
	},

	setValue: function(textarea, value) {
		if (!textarea)
			return;

		var text = (value === null || value === undefined) ? '' : String(value);

		if (textarea._cmeditor)
			textarea._cmeditor.setValue(text);

		textarea.value = text;
	}
});
