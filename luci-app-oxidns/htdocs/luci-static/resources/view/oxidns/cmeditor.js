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

var STYLES = [ 'codemirror.min.css' ];
var SCRIPTS = [ 'codemirror.min.js', 'yaml.min.js', 'autorefresh.min.js' ];

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
			link.href = BASE + name;
			document.head.appendChild(link);
		});

		this._promise = SCRIPTS.reduce(function(chain, name) {
			return chain.then(function() {
				return new Promise(function(resolve) {
					var script = document.createElement('script');
					script.src = BASE + name;
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
			lineNumbers: true,
			lineWrapping: true,
			autoRefresh: true,
			styleActiveLine: true,
			indentUnit: 2,
			tabSize: 2,
			viewportMargin: 12
		});

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
