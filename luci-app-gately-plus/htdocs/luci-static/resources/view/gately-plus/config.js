'use strict';
'require view';
'require gately-plus/common as C';
var KEYS = [
    'port', 'safe_url', 'internet_access', 'delay',
    'configdir', 'binpath',
    'arch',
    'respawn_threshold', 'respawn_timeout', 'respawn_retry'
];
var SAVE_KEYS = KEYS.concat(['admin_password']);

var api = {
    settings:      C.rpc('get_settings'),
    arch:          C.rpc('get_arch'),
    save:          C.rpc('save_settings', SAVE_KEYS),
    listBackups:   C.rpc('list_backups'),
    restoreBackup: C.rpc('restore_backup', ['filename'])
};

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(api.settings(), {}),
            L.resolveDefault(api.arch(),     {})
        ]);
    },

    handleSave:      function() { return this._save(); },
    handleSaveApply: null,
    handleReset:     function() { location.reload(); },

    _save: function() {
        var pwdEl = document.getElementById('_f_admin_password');
        return api.save.apply(null, SAVE_KEYS.map(C.fval)).then(function(res) {
            var ok = res && res.result === 'ok';
            var msg = _('Settings saved successfully.');
            if (!ok) {
                if (res.msg === 'password_too_short')
                    msg = _('Password must be at least 8 characters.');
                else if (res.msg === 'not_initialized')
                    msg = _('Gately is not initialized yet. Start it once before setting a password.');
                else if (res.msg === 'password_set_failed')
                    msg = _('Password set failed, please check the log.');
                else if (res.msg === 'configdir_invalid')
                    msg = _('Data directory must be a non-empty absolute path.');
                else if (res.msg === 'binpath_invalid')
                    msg = _('Binary path must be a non-empty absolute path.');
                else
                    msg = _('Save failed');
            } else if (res.warn === 'binary_missing') {
                msg = _('Saved. No Gately binary at the new path yet — it will be downloaded when the service starts.');
            }
            C.showToast({
                ok:      ok,
                title:   ok ? _('Saved') : _('Save Failed'),
                msg:     msg,
                timeout: ok ? 2000 : 0
            });
            if (ok && pwdEl) pwdEl.value = '';
        });
    },

    render: function(data) {
        var cfg  = data[0] || {};
        var arch = (data[1] || {}).arch || _('Unknown');

        var restoreBtn = E('button', {
            type: 'button',
            id: '_f_restore',
            class: 'gately-btn gately-btn-primary',
            click: function() {
                restoreBtn.disabled = true;
                L.resolveDefault(api.listBackups(), {}).then(function(res) {
                    restoreBtn.disabled = false;
                    var files = (res && res.files) ? res.files : [];

                    if (!files.length) {
                        C.showToast({
                            ok: false,
                            title: _('No Backups'),
                            msg: _('No backup files found.'),
                            timeout: 2500
                        });
                        return;
                    }

                    var overlay;
                    function closePanel() {
                        if (overlay && overlay.parentNode)
                            overlay.parentNode.removeChild(overlay);
                    }

                    function buildFileBtn(f) {
                        return E('button', {
                            type: 'button',
                            class: 'gately-file-btn',
                            title: f.name,
                            click: function() {
                                closePanel();

                                var doRestore = function() {
                                    L.hideModal();
                                    L.resolveDefault(
                                        api.restoreBackup(f.name), {}
                                    ).then(function(r) {
                                        var ok = r && r.result === 'ok';
                                        C.showToast({
                                            ok:      ok,
                                            title:   ok ? _('Restored') : _('Failed'),
                                            msg:     ok
                                                ? _('Backup restored successfully.')
                                                : _('Restore failed'),
                                            timeout: ok ? 2500 : 0
                                        });
                                    });
                                };

                                var cancelBtn = E('button', {
                                    type: 'button',
                                    class: 'gately-btn',
                                    click: function() { L.hideModal(); }
                                }, [E('span', {}, _('Cancel'))]);

                                var okBtn = E('button', {
                                    type: 'button',
                                    class: 'gately-btn gately-btn-success',
                                    click: doRestore
                                }, [C.icon('check', 14), E('span', {}, _('Confirm Restore'))]);

                                L.showModal(_('Restore Backup'), [
                                    E('div', { class: 'gately-modal' }, [
                                        E('div', { class: 'gately-modal-head' }, [
                                            C.icon('folder', 20),
                                            E('span', {}, _('Restore backup: %s ?').format(f.name))
                                        ]),
                                        E('p', { class: 'gately-modal-note' },
                                            _('The configuration will be overwritten with the contents of this backup and the service will restart.')),
                                        E('div', { class: 'gately-modal-actions' }, [cancelBtn, okBtn])
                                    ])
                                ]);
                            }
                        }, f.name);
                    }

                    var card = E('div', { class: 'gately-panel' }, [
                        E('h3', { class: 'gately-panel-title' },
                            [C.icon('folder', 16), E('span', {}, _('Select Backup to Restore'))]),
                        E('p', { class: 'gately-panel-desc' }, _('Click a file to restore it:')),
                        E('div', { class: 'gately-file-list' }, files.map(buildFileBtn)),
                        E('div', { class: 'gately-panel-foot' }, [
                            E('button', {
                                type: 'button',
                                class: 'gately-btn gately-btn-danger',
                                click: closePanel
                            }, _('Cancel'))
                        ])
                    ]);

                    overlay = E('div', { class: 'gately-panel-overlay' }, [card]);
                    overlay.addEventListener('click', function(ev) {
                        if (ev.target === overlay) closePanel();
                    });
                    card.addEventListener('click', function(ev) {
                        ev.stopPropagation();
                    });
                    document.body.appendChild(overlay);
                });
            }
        }, [C.icon('folder', 14), E('span', {}, _('Restore Backup'))]);

        // 管理员密码：总保存时一并应用；留空则保持原密码不变
        var pwdInput = E('input', {
            type: 'password',
            id: '_f_admin_password',
            class: 'gately-input',
            autocomplete: 'new-password',
            placeholder: _('Leave blank to keep current password'),
            style: 'flex:1;min-width:150px;'
        });

        var descThreshold = E('span', {}, '');
        var descTimeout   = E('span', {}, '');
        var descRetry     = E('span', {}, '');

        function fmtThreshold(v) {
            var n = parseInt(v) || 0;
            return n === 0
                ? _('Uptime > 0s always resets the retry counter')
                : _('Uptime exceeds %ss, retry counter resets').format(n);
        }
        function fmtTimeout(v) {
            return _('Wait %ss before restarting after a crash').format(parseInt(v) || 0);
        }
        function fmtRetry(v) {
            var n = parseInt(v) || 0;
            return n === 0
                ? _('Unlimited retries')
                : _('Stop after %s restart(s), 0 No limits').format(n);
        }

        descThreshold.textContent = fmtThreshold(cfg.respawn_threshold || '3600');
        descTimeout.textContent   = fmtTimeout(cfg.respawn_timeout     || '30');
        descRetry.textContent     = fmtRetry(cfg.respawn_retry         || '5');

        var mapEl = E('div', { class: 'cbi-map gately-page' }, [
            E('h2', {}, _('Gately Plus — Settings')),

            C.buildGrid(280, [
                C.buildCard(_('Admin Panel'), [
                    C.buildFormRow('text', 'port', _('Web UI Port'),
                        cfg.port || '16680',
                        _('Admin panel listen port. Takes effect after Save & restart.'),
                        { style: 'width:110px;' }),
                    C.buildFormRow('text', 'safe_url', _('Safe Entry URL'),
                        cfg.safe_url || '',
                        E('span', {}, [
                            _('Hidden login path, e.g. /mysecret (blank to disable).'), E('br'),
                            _('Cannot start with /api or /assets.')
                        ]),
                        { placeholder: '/mysecret' }),
                    C.buildFormRow('toggle', 'internet_access', _('Allow Internet Access'),
                        cfg.internet_access || '0',
                        _('Off: LAN-only access. On: also reachable from the WAN.')),
                    C.buildFormRow('custom', 'admin_password', _('Admin Password'),
                        null,
                        E('span', {}, [
                            _('Leave this empty to keep your current password. To change it, type a new password of at least 8 characters.'), E('br'),
                            _('Takes effect when you save; the service restarts afterwards.')
                        ]),
                        pwdInput)
                ], { icon: 'shield' }),
                C.buildCard(_('Basic Service'), [
                    C.buildFormRow('number', 'delay', _('Delayed Start (s)'),
                        cfg.delay || '60',
                        _('Delay before starting after boot (only when uptime < 120s)'),
                        { style: 'width:80px;', min: '0' }),
                    C.buildFormRow('custom', 'restore', _('Restore Backup'),
                        null,
                        _('Restore Gately config from a previous backup'),
                        restoreBtn)
                ], { icon: 'gear' })
            ]),

            C.buildGrid(280, [
                C.buildCard(_('Path & Architecture'), [
                    C.buildFormRow('text', 'configdir', _('Data Directory'),
                        cfg.configdir || '/etc/gately',
                        _('Gately runtime data directory (passed via -c)')),
                    C.buildFormRow('text', 'binpath', _('Binary Path'),
                        cfg.binpath || '/usr/bin/gately',
                        _('Full path to the Gately executable')),
                    C.buildFormRow('text', 'arch', _('Architecture'),
                        cfg.arch || 'auto',
                        E('span', {}, [
                            _('Detected:'), E('strong', {}, arch), E('br'),
                            _('Leave "auto" to detect automatically')
                        ]),
                        { style: 'width:120px;' })
                ], { icon: 'folder' })
            ]),

            C.buildGrid(280, [
                C.buildCard(_('Respawn Policy'), [
                    C.buildFormRow('number', 'respawn_threshold', _('Crash Threshold (s)'),
                        cfg.respawn_threshold || '3600',
                        descThreshold,
                        { style: 'width:80px;', min: '0' }),
                    C.buildFormRow('number', 'respawn_timeout', _('Respawn Delay (s)'),
                        cfg.respawn_timeout || '30',
                        descTimeout,
                        { style: 'width:80px;', min: '0' }),
                    C.buildFormRow('number', 'respawn_retry', _('Max Retries'),
                        cfg.respawn_retry || '5',
                        descRetry,
                        { style: 'width:80px;', min: '0' })
                ], { icon: 'refresh' })
            ])
        ]);

        C.initThemeButton();

        window.setTimeout(function() {
            var elThreshold = mapEl.querySelector('#_f_respawn_threshold');
            var elTimeout   = mapEl.querySelector('#_f_respawn_timeout');
            var elRetry     = mapEl.querySelector('#_f_respawn_retry');

            if (elThreshold) elThreshold.addEventListener('input', function() {
                descThreshold.textContent = fmtThreshold(this.value);
            });
            if (elTimeout) elTimeout.addEventListener('input', function() {
                descTimeout.textContent = fmtTimeout(this.value);
            });
            if (elRetry) elRetry.addEventListener('input', function() {
                descRetry.textContent = fmtRetry(this.value);
            });
        }, 0);

        return mapEl;
    }
});
