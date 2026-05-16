/**
 * status.js - QMODEM 故障切换状态实时监控前端
 * 位置: /htdocs/luci-static/qmodem_failover/status.js
 * 功能: 每 3 秒轮询 API，更新状态显示，提供手动切换按钮
 */

(function () {
    'use strict';

    var API_BASE = '/cgi-bin/luci/admin/network/qmodem_failover/api';
    var POLL_INTERVAL = 3000;  // 3 秒轮询一次
    var pollTimer = null;

    // ─────────────────────────────────────────────
    // DOM 工具
    // ─────────────────────────────────────────────
    function $(id) {
        return document.getElementById(id);
    }

    function setText(id, text) {
        var el = $(id);
        if (el) el.textContent = text;
    }

    function setHTML(id, html) {
        var el = $(id);
        if (el) el.innerHTML = html;
    }

    function setClass(id, cls) {
        var el = $(id);
        if (el) el.className = cls;
    }

    // ─────────────────────────────────────────────
    // 格式化时间戳为可读字符串
    // ─────────────────────────────────────────────
    function formatTime(ts) {
        if (!ts || ts === 0) return '—';
        var d = new Date(ts * 1000);
        return d.getFullYear() + '-' +
            pad(d.getMonth() + 1) + '-' +
            pad(d.getDate()) + ' ' +
            pad(d.getHours()) + ':' +
            pad(d.getMinutes()) + ':' +
            pad(d.getSeconds());
    }

    function pad(n) {
        return n < 10 ? '0' + n : '' + n;
    }

    // 计算持续时间
    function formatDuration(ts) {
        if (!ts || ts === 0) return '—';
        var now = Math.floor(Date.now() / 1000);
        var diff = now - ts;
        if (diff < 60) return diff + ' 秒前';
        if (diff < 3600) return Math.floor(diff / 60) + ' 分钟前';
        if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
        return Math.floor(diff / 86400) + ' 天前';
    }

    // ─────────────────────────────────────────────
    // 拉取状态数据
    // ─────────────────────────────────────────────
    function fetchStatus() {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', API_BASE + '/status', true);
        xhr.timeout = 5000;
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    updateUI(data);
                } catch (e) {
                    showError('数据解析失败');
                }
            } else {
                showError('API 请求失败 (' + xhr.status + ')');
            }
        };
        xhr.onerror = function () { showError('网络错误'); };
        xhr.ontimeout = function () { showError('请求超时'); };
        xhr.send();
    }

    // ─────────────────────────────────────────────
    // 更新状态 UI
    // ─────────────────────────────────────────────
    function updateUI(data) {
        // ── 主状态卡片 ──
        var isLTE = (data.mode === 'lte');
        var modeName = isLTE ? '📱 移动网络 (LTE)' : '🔌 有线网络 (WAN)';
        var modeClass = isLTE ? 'badge-lte' : 'badge-wan';

        setText('qmf-mode-text', modeName);
        setClass('qmf-mode-badge', 'qmf-badge ' + modeClass);
        setText('qmf-switch-time', formatTime(data.switch_time));
        setText('qmf-switch-ago', formatDuration(data.switch_time));

        // ── WAN 状态 ──
        var wanOk = data.wan_alive;
        var wanCarrier = data.wan_carrier;

        setText('qmf-wan-status', wanOk ? '✅ 正常' : (wanCarrier ? '⚠️ 链路UP但无法访问' : '❌ 链路断开'));
        setClass('qmf-wan-status', 'qmf-status-text ' + (wanOk ? 'text-green' : 'text-red'));
        setText('qmf-wan-ip', data.wan_ip || '—');
        setText('qmf-wan-iface', data.wan_iface || 'eth0');

        // ── LTE 状态 ──
        var lteOk = !!(data.lte_ip && data.lte_ip.length > 0);
        setText('qmf-lte-status', lteOk ? '✅ 已连接' : '⭕ 待机');
        setClass('qmf-lte-status', 'qmf-status-text ' + (lteOk ? 'text-green' : 'text-gray'));
        setText('qmf-lte-ip', data.lte_ip || '—');
        setText('qmf-lte-iface', data.lte_iface || 'usb0');

        // ── 服务状态 ──
        setText('qmf-service-status', data.service_running ? '🟢 运行中' : '🔴 未运行');

        // ── 默认路由 ──
        setText('qmf-default-route', data.default_route || '—');

        // ── 手动切换按钮 ──
        var btnToLTE = $('qmf-btn-lte');
        var btnToWAN = $('qmf-btn-wan');
        if (btnToLTE) btnToLTE.disabled = isLTE;
        if (btnToWAN) btnToWAN.disabled = !isLTE;

        // ── 更新时间 ──
        setText('qmf-last-update', '最后更新: ' + formatTime(Math.floor(Date.now() / 1000)));

        // 清除错误
        var errEl = $('qmf-error');
        if (errEl) errEl.style.display = 'none';
    }

    function showError(msg) {
        var errEl = $('qmf-error');
        if (errEl) {
            errEl.textContent = '⚠️ ' + msg;
            errEl.style.display = 'block';
        }
    }

    // ─────────────────────────────────────────────
    // 手动切换
    // ─────────────────────────────────────────────
    function doSwitch(target) {
        var btnToLTE = $('qmf-btn-lte');
        var btnToWAN = $('qmf-btn-wan');
        if (btnToLTE) btnToLTE.disabled = true;
        if (btnToWAN) btnToWAN.disabled = true;

        setText('qmf-switch-result', '⏳ 切换中...');

        var xhr = new XMLHttpRequest();
        xhr.open('POST', API_BASE + '/switch', true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.timeout = 20000;
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            var msg = '';
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    msg = data.success
                        ? '✅ 切换成功: ' + (target === 'lte' ? '→ 移动网络' : '→ 有线网络')
                        : '❌ 切换失败: ' + (data.error || '未知错误');
                } catch (e) {
                    msg = '❌ 响应解析失败';
                }
            } else {
                msg = '❌ 请求失败 (' + xhr.status + ')';
            }
            setText('qmf-switch-result', msg);
            // 立即刷新状态
            setTimeout(fetchStatus, 1000);
        };
        xhr.onerror = function () {
            setText('qmf-switch-result', '❌ 网络错误');
        };
        xhr.send('target=' + encodeURIComponent(target));
    }

    // ─────────────────────────────────────────────
    // 加载日志
    // ─────────────────────────────────────────────
    function loadLogs() {
        var logEl = $('qmf-logs');
        if (!logEl) return;
        logEl.textContent = '加载中...';

        var xhr = new XMLHttpRequest();
        xhr.open('GET', API_BASE + '/logs', true);
        xhr.timeout = 5000;
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4) return;
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    var lines = data.logs || [];
                    if (lines.length === 0) {
                        logEl.textContent = '（暂无日志）';
                    } else {
                        logEl.textContent = lines.reverse().join('\n');
                    }
                } catch (e) {
                    logEl.textContent = '日志解析失败';
                }
            }
        };
        xhr.send();
    }

    // ─────────────────────────────────────────────
    // 初始化：绑定事件，启动轮询
    // ─────────────────────────────────────────────
    function init() {
        // 绑定手动切换按钮
        var btnToLTE = $('qmf-btn-lte');
        var btnToWAN = $('qmf-btn-wan');
        if (btnToLTE) {
            btnToLTE.addEventListener('click', function () {
                if (confirm('确认切换至 QMODEM 移动网络？')) {
                    doSwitch('lte');
                }
            });
        }
        if (btnToWAN) {
            btnToWAN.addEventListener('click', function () {
                if (confirm('确认切回有线 WAN 网络？')) {
                    doSwitch('wan');
                }
            });
        }

        // 刷新日志按钮
        var btnLogs = $('qmf-btn-logs');
        if (btnLogs) {
            btnLogs.addEventListener('click', loadLogs);
        }

        // 立即获取一次状态
        fetchStatus();

        // 启动轮询
        pollTimer = setInterval(fetchStatus, POLL_INTERVAL);
    }

    // DOM 就绪后初始化
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // 页面隐藏时暂停轮询，节省资源
    document.addEventListener('visibilitychange', function () {
        if (document.hidden) {
            clearInterval(pollTimer);
        } else {
            fetchStatus();
            pollTimer = setInterval(fetchStatus, POLL_INTERVAL);
        }
    });

})();

