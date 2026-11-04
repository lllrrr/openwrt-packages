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
 * 都不需要改。加载失败时（资源缺失、老浏览器）自动退回原来的 textarea 行为。
 */

var BASE = '/luci-static/resources/oxidns-codemirror/';

/* cmtheme.css 必须排在 codemirror.min.css 之后：后者自带 cm-s-default 的取色，
   同名特异性下靠顺序覆盖。 */
/* 资源版本：改动 cmtheme.css 或随包脚本时递增。
   浏览器缓存的键是完整 URL，而 LuCI 的模块 URL 只带 luci-base 的
   ?v=<luci-base 版本>，应用自己更新不会改变它 —— 不加这一层，
   用户刷新页面也拿不到新样式（Firefox 尤其是）。 */
var ASSET_VERSION = '20261104d';

var STYLES = [ 'codemirror.min.css', 'cmtheme.css' ];
var SCRIPTS = [ 'codemirror.min.js', 'yaml.min.js', 'autorefresh.min.js' ];

/* 主题名，对应 cmtheme.css 里的 .cm-s-lucicode */
var THEME = 'lucicode';

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

/*
 * 主题可能在编辑器挂载之后才被切换（bootstrap 的深色按钮就是运行时改
 * <html data-darkmode>，不刷新页面），所以挂载时判一次、之后持续跟随。
 */
function watchTheme(cm, el) {
	var apply = function() {
		if (!cm || !cm.getWrapperElement)
			return;

		cm.getWrapperElement().classList.toggle('cm-dark', preferDark(el));
	};

	apply();

	if (typeof MutationObserver === 'function') {
		var observer = new MutationObserver(apply);
		var opts = { attributes: true, attributeFilter: [ 'data-darkmode', 'class', 'style' ] };

		if (document.documentElement)
			observer.observe(document.documentElement, opts);
		if (document.body)
			observer.observe(document.body, opts);
	}

	if (typeof window.matchMedia === 'function') {
		var mq = window.matchMedia('(prefers-color-scheme: dark)');

		if (typeof mq.addEventListener === 'function')
			mq.addEventListener('change', apply);
	}
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

		STYLES.forEach(function(name) {
			var link = document.createElement('link');
			link.rel = 'stylesheet';
			link.href = BASE + name + '?v=' + ASSET_VERSION;
			document.head.appendChild(link);
		});

		this._promise = SCRIPTS.reduce(function(chain, name) {
			return chain.then(function() {
				return new Promise(function(resolve) {
					var script = document.createElement('script');
					script.src = BASE + name + '?v=' + ASSET_VERSION;
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
			styleActiveLine: true,
			indentUnit: 2,
			tabSize: 2,
			viewportMargin: 12
		});

		watchTheme(cm, textarea.parentElement || document.body);

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

			if (document.body && document.body.contains(textarea)) {
				self.attach(textarea, opts);
				return;
			}

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
