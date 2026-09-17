(function () {
  'use strict';
  var attr = 'data-wan-latency-entry';
  var panelId = 'wan-latency-native-panel';
  var hidden = 'data-wan-latency-hidden';

  function root() {
    var h = Array.from(document.querySelectorAll('h1')).find(function (x) { return x.textContent.trim() === '其他设置'; });
    return h && h.parentElement && h.parentElement.parentElement && h.parentElement.parentElement.parentElement;
  }

  function restore() {
    document.querySelectorAll('[' + hidden + ']').forEach(function (x) {
      x.style.display = x.getAttribute(hidden) || '';
      x.removeAttribute(hidden);
    });
    var p = document.getElementById(panelId);
    if (p) p.style.display = 'none';
  }

  function makePanel(tabs) {
    var p = document.getElementById(panelId);
    if (p) return p;
    p = document.createElement('section');
    p.id = panelId;
    p.style.cssText = 'display:none;margin-top:16px;color:#e5edf9';
    p.innerHTML = '<div style="border:1px solid rgba(100,116,139,.35);border-radius:14px;background:rgba(15,23,42,.58);padding:20px">' +
      '<div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:18px"><div><b style="font-size:20px">公网延迟</b><div id="wl-sub" style="font-size:13px;color:#94a3b8;margin-top:4px">正在读取…</div></div>' +
      '<div style="display:flex;gap:10px"><button id="wl-refresh" style="border:1px solid #475569;border-radius:10px;background:#334155;color:#fff;padding:9px 16px;cursor:pointer">刷新</button>' +
      '<button id="wl-full" style="border:0;border-radius:10px;background:#2563eb;color:#fff;padding:9px 16px;cursor:pointer">打开完整图表</button></div></div>' +
      '<div id="wl-cards" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px"></div></div>';
    tabs.insertAdjacentElement('afterend', p);
    p.querySelector('#wl-refresh').onclick = load;
    p.querySelector('#wl-full').onclick = function () { window.open('https://' + location.hostname + '/cgi-bin/luci/admin/status/wan_latency', '_blank', 'noopener,noreferrer'); };
    return p;
  }

  function load() {
    var p = document.getElementById(panelId);
    if (!p || p.style.display === 'none') return;
    fetch('/wan-latency-native/latest.json?t=' + Date.now(), { cache: 'no-store' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      p.querySelector('#wl-sub').textContent = '接口 ' + (data.iface || '--') + ' · 更新于 ' + new Date((data.ts || 0) * 1000).toLocaleString();
      var box = p.querySelector('#wl-cards'); box.textContent = '';
      (data.items || []).forEach(function (item) {
        var c = document.createElement('div');
        var rtt = Number.isFinite(Number(item.rtt)) ? Number(item.rtt).toFixed(1) : '--';
        c.style.cssText = 'border:1px solid rgba(100,116,139,.35);border-radius:12px;background:rgba(30,41,59,.72);padding:16px';
        c.innerHTML = '<div style="display:flex;justify-content:space-between"><strong class="n"></strong><span class="m" style="font-size:11px;color:#94a3b8;border:1px solid #475569;border-radius:999px;padding:2px 7px"></span></div>' +
          '<div style="font-size:32px;font-weight:750;margin:12px 0 8px;color:' + (item.color || '#60a5fa') + '">' + rtt + '<small style="font-size:14px;color:#94a3b8;margin-left:4px">ms</small></div><div class="h" style="font-size:12px;color:#94a3b8"></div><div class="f" style="font-size:12px;color:#94a3b8;margin-top:5px"></div>';
        c.querySelector('.n').textContent = item.name || item.id || '未命名';
        c.querySelector('.m').textContent = item.method || 'unknown';
        c.querySelector('.h').textContent = (item.host || '--') + (item.ip && item.ip !== item.host ? ' (' + item.ip + ')' : '');
        c.querySelector('.f').textContent = '连续失败：' + Number(item.failures || 0);
        box.appendChild(c);
      });
    }).catch(function (e) { p.querySelector('#wl-sub').textContent = '读取失败：' + e.message; });
  }

  function install() {
    if (location.pathname !== '/other' || document.querySelector('[' + attr + ']')) return;
    var ts = Array.from(document.querySelectorAll('button')).find(function (b) { return b.textContent.trim() === 'Tailscale'; });
    var r = root();
    if (!ts || !r) return;
    var tabs = Array.from(r.children).find(function (x) { return x.contains(ts); });
    if (!tabs) return;
    var e = ts.cloneNode(true); e.setAttribute(attr, 'true'); e.removeAttribute('disabled');
    var w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT), n;
    while ((n = w.nextNode())) if (n.nodeValue.trim() === 'Tailscale') n.nodeValue = n.nodeValue.replace('Tailscale', '公网延迟');
    e.onclick = function (event) {
      event.preventDefault(); event.stopPropagation();
      var p = makePanel(tabs);
      Array.from(r.children).forEach(function (x) {
        if (x === tabs || x === p || x.contains(r.querySelector('h1'))) return;
        if (!x.hasAttribute(hidden)) x.setAttribute(hidden, x.style.display || '');
        x.style.display = 'none';
      });
      p.style.display = 'block'; e.style.background = 'linear-gradient(135deg,#3b82f6,#2563eb)'; e.style.color = '#fff'; load();
    };
    ts.insertAdjacentElement('afterend', e);
  }

  document.addEventListener('click', function (ev) {
    var b = ev.target.closest && ev.target.closest('button');
    if (b && !b.hasAttribute(attr) && ['磁盘管理','文件共享','Zerotier','Tailscale','Watchcat'].indexOf(b.textContent.trim()) >= 0) restore();
  }, true);
  install(); document.addEventListener('DOMContentLoaded', install);
  new MutationObserver(install).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(function () { install(); load(); }, 5000);
})();
