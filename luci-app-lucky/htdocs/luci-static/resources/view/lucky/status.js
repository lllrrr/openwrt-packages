'use strict';
'require view';
'require poll';
'require dom';
'require lucky/common';

var C   = lucky_common;
var api = {
    status:   C.rpc('get_status'),
    info:     C.rpc('get_system_info'),
    settings: C.rpc('get_settings'),
    stats:    C.rpc('get_process_stats'),
    toggle:   C.rpc('toggle_service', ['action']),
    download: C.rpc('run_update'),
    updStat:  C.rpc('get_update_status')
};

function fmtUptime(sec) {
    if (!sec || sec < 0) return _('N/A');
    var d = Math.floor(sec / 86400),
        h = Math.floor((sec % 86400) / 3600),
        m = Math.floor((sec % 3600) / 60),
        s = sec % 60;
    return (d ? d + _('d') + ' ' : '') +
           (d || h ? h + _('h') + ' ' : '') +
           (d || h || m ? m + _('m') + ' ' : '') +
           s + _('s');
}

function fmtMem(kb) {
    if (!kb) return '—';
    return kb >= 1024 ? (kb / 1024).toFixed(1) + ' MB' : kb + ' KB';
}

function buildMissingCard() {
    var logEl   = E('pre', { id: 'miss_log', class: 'lucky-log' });
    var barWrap = E('div', { style: 'display:none;' },
        [C.buildBar('bar_missing', 'progress')]);
    var statEl  = E('span', { id: 'miss_stat', class: 'lucky-state' });
    var cardEl;

    var dlBtn = E('button', {
        type: 'button',
        class: 'lucky-btn lucky-btn-primary',
        click: function() {
            dlBtn.disabled = true;
            barWrap.style.display = 'block';
            C.setBar('bar_missing', 0);
            C.setState('miss_stat', _('Starting download…'), 'busy');

            L.resolveDefault(api.download(), {}).then(function(res) {
                if (!res || res.result !== 'ok') {
                    dlBtn.disabled = false;
                    barWrap.style.display = 'none';
                    C.setState('miss_stat',
                        _('Failed to start, please check the log.'), 'err');
                    return;
                }
                logEl.classList.add('is-open');
                var p = C.LogPoller({
                    status:   function() { return L.resolveDefault(api.updStat(), {}); },
                    textEl:   'miss_log',
                    bar:      'bar_missing',
                    interval: 1500,
                    terminal: function(s) {
                        var code = s.code || s.status;
                        return code === 'done' || code === 'error';
                    },
                    onTick: function(s) {
                        var code = s.code || s.status;
                        if (code === 'downloading')
                            C.setState('miss_stat', _('Downloading…'), 'busy');
                        else if (code === 'installing')
                            C.setState('miss_stat', _('Installing…'), 'busy');
                        else if (code === 'checking' || code === 'ready')
                            C.setState('miss_stat', _('Checking upstream…'), 'busy');
                    },
                    onDone: function(s) {
                        var code = s.code || s.status;
                        if (code === 'done') {
                            C.setBar('bar_missing', 100);
                            var card = document.getElementById('missing_card');
                            if (card) card.style.display = 'none';
                            C.showToast({
                                ok: true,
                                msg: _('Lucky core downloaded successfully. Service is starting…'),
                                timeout: 3000
                            });
                        } else {
                            dlBtn.disabled = false;
                            C.setState('miss_stat',
                                C.taskMessage(s), 'err');
                        }
                    }
                });
                p.start();
            });
        }
    }, [C.icon('download', 14), E('span', {}, _('Download Lucky Core'))]);

    cardEl = E('div', { id: 'missing_card', class: 'lucky-card lucky-card--warn' }, [
        E('div', { class: 'lucky-warn-head' }, [
            C.icon('alert', 18),
            E('span', { class: 'lucky-warn-title' }, _('Lucky core binary not found'))
        ]),
        E('div', { class: 'lucky-form-desc', style: 'margin:0 0 12px;font-size:13px;' },
            _('The Lucky executable is missing. Download it to start the service.')),
        E('div', { class: 'lucky-banner-row' }, [dlBtn, statEl]),
        barWrap,
        logEl
    ]);
    return cardEl;
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    _prevProc:  0,
    _prevTotal: 0,
    _startPending: false,
    _startPendingAt: 0,
    _startPendingUntil: 0,

    load: function() {
        this._startPending = false;
        this._startPendingAt = 0;
        this._startPendingUntil = 0;
        return Promise.all([
            L.resolveDefault(api.status(),   {}),
            L.resolveDefault(api.settings(), {}),
            L.resolveDefault(api.stats(),    {})
        ]);
    },

    render: function(data) {
        var self         = this;
        var status       = data[0] || {};
        var cfg          = data[1] || {};
        var initialStats = data[2] || {};
        var initialRun   = !!status.running;

        if (initialRun) {
            self._prevProc = initialStats.proc_ticks || 0;
            self._prevTotal = initialStats.total_ticks || 0;
        }

        function showStarting() {
            self._startPending = true;
            self._startPendingAt = Date.now();
            self._startPendingUntil = self._startPendingAt + 5000;

            var dotEl = document.getElementById('st_dot');
            if (dotEl) {
                dotEl.textContent = '◌ Lucky — ' + _('STARTING');
                dotEl.className = 'lucky-dot lucky-dot--starting lucky-pulse';
            }

            var uptimeEl = document.getElementById('st_uptime');
            if (uptimeEl) {
                uptimeEl.textContent = _('Please wait for Lucky to start…');
                uptimeEl.classList.remove('is-off');
                uptimeEl.classList.add('is-starting');
            }
        }

        function clearStarting() {
            self._startPending = false;
            self._startPendingAt = 0;
            self._startPendingUntil = 0;
        }

        var port     = cfg.port || '16601';
        var safe     = cfg.safe || '';
        var internet = cfg.internet === '1';
        var url      = window.location.protocol + '//' + window.location.hostname +
                       ':' + port + '/' + (safe ? safe + '/' : '');

        var toggleInput = null;
        var restartBtn = null;
        var enabledState = cfg.enabled === '1';

        function syncToggleState() {
            L.resolveDefault(api.settings(), {}).then(function(settings) {
                settings = settings || {};
                enabledState = settings.enabled === '1';
                if (toggleInput) toggleInput.checked = enabledState;
                if (restartBtn) restartBtn.disabled = !enabledState;
            });
        }

        var toggleEl = C.buildToggle('st_enabled', cfg.enabled === '1',
            function() {
                toggleInput = this;
                var action = this.checked ? 'enable' : 'disable';
                enabledState = action === 'enable';

                if (action === 'enable') {
                    showStarting();
                    if (restartBtn) restartBtn.disabled = false;
                } else {
                    clearStarting();
                    if (restartBtn) restartBtn.disabled = true;
                }

                L.resolveDefault(api.toggle(action), {}).then(function(res) {
                    if (!res || res.result !== 'ok') {
                        clearStarting();
                        syncToggleState();
                    }
                });
            });

        restartBtn = C.buildIconBtn('refresh', _('Restart Lucky'), function() {
            if (!enabledState) return;
            this.disabled = true;
            this.classList.add('is-spinning');
            showStarting();
            L.resolveDefault(api.toggle('restart'), {}).then(function(res) {
                if (!res || res.result !== 'ok')
                    clearStarting();
                window.setTimeout(function() {
                    restartBtn.disabled = !enabledState;
                    restartBtn.classList.remove('is-spinning');
                }, 3000);
            });
        });
        restartBtn.disabled = cfg.enabled !== '1';

        var bannerEl = E('div', { class: 'lucky-card' }, [
            E('div', { class: 'lucky-banner-row' }, [
                toggleEl,
                E('span', { class: 'lucky-banner-label' }, _('Enable Lucky')),
                restartBtn
            ]),
            E('div', { class: 'lucky-banner-status' }, [
                E('div', {}, [
                    E('div', {
                        id: 'st_dot',
                        class: 'lucky-dot ' + (initialRun
                            ? 'lucky-dot--run lucky-pulse' : 'lucky-dot--stop')
                    }, initialRun
                        ? '● Lucky — ' + _('RUNNING')
                        : '○ Lucky — ' + _('NOT RUNNING')),
                    E('div', {
                        id: 'st_uptime',
                        class: 'lucky-uptime' + (initialRun ? '' : ' is-off')
                    }, initialRun
                        ? _('Uptime:') + fmtUptime(initialStats.uptime_seconds)
                        : '—')
                ]),
                E('div', { id: 'st_btn' })
            ])
        ]);

        var metricsGrid = C.buildGrid(200, [
            E('div', { class: 'lucky-card' }, [
                E('div', { class: 'lucky-card-title' }, _('CPU Usage')),
                E('div', { id: 'st_cpu', class: 'lucky-metric-value' }, '—'),
                C.buildBar('bar_cpu', 'load'),
                E('div', { id: 'st_thr', class: 'lucky-metric-sub' }, '—')
            ]),
            E('div', { class: 'lucky-card' }, [
                E('div', { class: 'lucky-card-title' }, _('Memory')),
                E('div', { id: 'st_mem', class: 'lucky-metric-value' }, '—'),
                C.buildBar('bar_mem', 'load'),
                E('div', { id: 'st_memp', class: 'lucky-metric-sub' }, '—')
            ]),
            E('div', { class: 'lucky-card' }, [
                E('div', { class: 'lucky-card-title' }, _('Process')),
                E('div', { id: 'st_pid', class: 'lucky-metric-value' }, '—'),
                E('div', { id: 'st_thr2', class: 'lucky-metric-sub' }, '—')
            ])
        ]);

        var infoGrid = C.buildGrid(240, [
            C.buildCard(_('Version Info'), C.buildKVGrid([
                ['Lucky',              'si_ver',   _('Loading…')],
                [_('Release Tag'),     'si_tag',   _('Loading…')],
                ['LuCI',               'si_luci',  _('Loading…')],
                [_('Variant'),         'si_var',   _('Loading…')],
                [_('Arch'),            'si_arch',  _('Loading…')],
                [_('Build Date'),      'si_build', _('Loading…')]
            ]), { icon: 'info' }),
            C.buildCard(_('Access Info'), C.buildKVGrid([
                [_('Port'),            'si_port', port],
                [_('Internet Access'), 'si_internet', internet ? _('Enabled') : _('Disabled')],
                [_('Entrance'),        'si_safe', safe ? '/' + safe + '/' : '/'],
                [_('URL'),             'si_url', url]
            ]), { icon: 'globe' })
        ]);

        L.resolveDefault(api.info(), {}).then(function(info) {
            info = info || {};
            [
                ['si_ver',   info.version],
                ['si_tag',   info.release_tag],
                ['si_luci',  info.luci_version],
                ['si_var',   info.variant],
                ['si_arch',  info.arch],
                ['si_build', info.build_date]
            ].forEach(function(item) {
                var el = infoGrid.querySelector('#' + item[0]);
                if (el) el.textContent = item[1] || _('Unknown');
            });
        });

        var linkCard = C.buildCard(null,
            E('div', {
                style: 'display:flex;justify-content:center;align-items:center;' +
                       'flex-wrap:wrap;gap:12px;'
            }, [
                C.buildLinkBtn(_('Official Website'), 'https://lucky666.cn/', 'globe'),
                C.buildLinkBtn(_('GitHub Lucky'),
                    'https://github.com/gdy666/lucky/releases', 'box'),
                C.buildLinkBtn(_('GitHub LuCI'),
                    'https://github.com/whzhni1/luci-app-lucky', 'box')
            ]), { icon: null });

        var children = [E('h2', {}, _('Lucky — Status'))];
        if (status.binary_missing) children.push(buildMissingCard());
        children.push(bannerEl, metricsGrid, infoGrid, linkCard);

        var mapEl = E('div', { class: 'cbi-map lucky-page' }, children);
        C.initThemeButton();

        poll.add(function() {
            return Promise.all([
                L.resolveDefault(api.status(), {}),
                L.resolveDefault(api.stats(),  {})
            ]).then(function(r) {
                var st  = r[0] || {}, ps = r[1] || {};
                var run = !!st.running;

                var starting = self._startPending &&
                    (!run || Date.now() < self._startPendingUntil);
                if (run && !starting) clearStarting();

                var dotEl = document.getElementById('st_dot');
                if (dotEl) {
                    if (run)
                        dotEl.textContent = '● Lucky — ' + _('RUNNING');
                    else if (starting)
                        dotEl.textContent = '◌ Lucky — ' + _('STARTING');
                    else
                        dotEl.textContent = '○ Lucky — ' + _('NOT RUNNING');

                    dotEl.className = 'lucky-dot lucky-dot--' +
                        (run ? 'run' : starting ? 'starting' : 'stop') +
                        (run || starting ? ' lucky-pulse' : '');
                }

                var uptEl = document.getElementById('st_uptime');
                if (uptEl) {
                    var waited = self._startPendingAt
                        ? Date.now() - self._startPendingAt : 0;
                    uptEl.textContent = run
                        ? _('Uptime:') + fmtUptime(ps.uptime_seconds)
                        : starting
                            ? (waited > 30000
                                ? _('Still starting. Check the log if this takes much longer.')
                                : _('Please wait for Lucky to start…'))
                            : '—';
                    uptEl.classList.toggle('is-off', !run && !starting);
                    uptEl.classList.toggle('is-starting', starting);
                }

                var btnEl = document.getElementById('st_btn');
                if (btnEl) {
                    if (run && !btnEl.hasChildNodes()) {
                        dom.content(btnEl, E('button', {
                            type: 'button',
                            class: 'lucky-btn lucky-btn-primary',
                            click: function() { window.open(url); }
                        }, [C.icon('external', 14), E('span', {}, _('Open Lucky Web UI'))]));
                    } else if (!run && btnEl.hasChildNodes()) {
                        dom.content(btnEl, []);
                    }
                }

                var cpu = 0;
                if (run && ps.proc_ticks !== undefined) {
                    var pd = ps.proc_ticks  - self._prevProc;
                    var td = ps.total_ticks - self._prevTotal;
                    if (td > 0 && self._prevTotal > 0) {
                        cpu = Math.round(pd * (ps.cores || 1) * 1000 / td) / 10;
                        cpu = Math.max(0, Math.min(100, cpu));
                    }
                    self._prevProc  = ps.proc_ticks;
                    self._prevTotal = ps.total_ticks;
                }

                C.setText('st_cpu', run ? cpu.toFixed(1) + '%' : '—');
                C.setBar('bar_cpu', cpu);
                C.setText('st_thr', run && ps.cores
                    ? _('Cores:') + ps.cores : '—');

                var memp = run ? (ps.mem_percent || 0) : 0;
                C.setText('st_mem',  run ? fmtMem(ps.mem_rss) : '—');
                C.setText('st_memp', run ? memp.toFixed(1) + '%' : '—');
                C.setBar('bar_mem', memp);

                C.setText('st_pid',  run && ps.pid ? String(ps.pid) : '—');
                C.setText('st_thr2', run && ps.threads
                    ? _('Threads:') + ps.threads : '—');
            });
        }, 3);

        return mapEl;
    }
});

