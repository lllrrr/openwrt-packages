'use strict';
'require view';
'require ui';
'require uci';
'require rpc';
'require vnt2.common';

function rpcDeclare(method, params) {
    return rpc.declare({ object: 'luci.vnt2', method: method, params: params || [] });
}

var callGetSystemInfo      = rpcDeclare('get_system_info',      []);
var callCheckBinaries      = rpcDeclare('check_binaries',       []);
var callGetUpstreamVersion = rpcDeclare('get_upstream_version', ['project', 'mirror']);
var callGetUpdateStatus    = rpcDeclare('get_update_status',    ['project']);
var callDoUpdate           = rpcDeclare('do_update',            ['project', 'tag', 'filename', 'upx']);
var callSaveSettings       = rpcDeclare('save_settings', [
    'config_path','bin_path','arch','mirror','web_token','web_addr','web_enabled','web_data_dir',
    'auto_update','update_interval','upx_compressed',
    'respawn_threshold','respawn_timeout','respawn_retry',
    'log_to_file','log_errors_only','log_max_kb','startup_check_window','kill_interval',
    'fw_vnt_to_lan','fw_lan_to_vnt',
    'fw_vnt_to_wan','fw_wan_to_vnt',
    'fw_vnt_web','fw_vnts_web'
]);

var MIRROR_OPTIONS = [
    { value: 'github',     label: 'GitHub'     },
    { value: 'gitee',      label: 'Gitee'      },
    { value: 'gitlab',     label: 'GitLab'     },
    { value: 'cloudflare', label: 'Cloudflare' },
];

var COMPONENTS = [
    { name: 'vnt2_cli',  binKey: 'vnt2_cli',  versionKey: 'vnt_cli_version'  },
    { name: 'vnt2_ctrl', binKey: 'vnt2_ctrl', versionKey: 'vnt_ctrl_version' },
    { name: 'vnt2_web',  binKey: 'vnt2_web',  versionKey: 'vnt_version'      },
    { name: 'vnts2',     binKey: 'vnts2',     versionKey: 'vnts_version'     },
];

var FW_OPTIONS = [
    { key: 'fw_vnt_to_lan', label: 'VNT → LAN', desc: _('Allow virtual network to access LAN') },
    { key: 'fw_lan_to_vnt', label: 'LAN → VNT', desc: _('Allow LAN to access virtual network') },
    { key: 'fw_vnt_to_wan', label: 'VNT → WAN', desc: _('Allow virtual network to access WAN')       },
    { key: 'fw_wan_to_vnt', label: 'WAN → VNT', desc: _('Allow WAN to access virtual network')       },
    { key: 'fw_vnt_web',  label: _('VNT Web External Access'),  desc: _('Allow WAN to access the vnt2_web listen port') },
    { key: 'fw_vnts_web', label: _('VNTS Web External Access'), desc: _('Requires web_bind configuration') },
];

return view.extend({

    load: function() {
        return Promise.all([
            L.require('vnt2.common'),
            uci.load('vnt2'),
            callGetSystemInfo(),
            callCheckBinaries()
        ]);
    },

    render: function(data) {
        var self       = this;
        self._ui       = data[0].VNT2UI;
        self._events   = data[0].VNT2Events;
        self._fmt      = data[0].VNT2Format;
        self._sysinfo  = data[2] || {};
        self._binaries = data[3] || {};
        window.requestAnimationFrame(function() {
            var initHash = location.hash.replace('#','');
            var footer = document.querySelector('.cbi-page-actions');
            if (footer) footer.style.display = initHash === 'tab-update' ? 'none' : '';
        });
        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('VNT2 Settings & Update')),
            self._buildTabContainer([
                { id: 'tab-settings', label: _('Settings'), content: self._buildSettingsTab() },
                { id: 'tab-update',   label: _('Update'), content: self._buildUpdateTab()   }
            ])
        ]);
    },

    _getUciSettings: function() {
        var g = function(k) { return uci.get('vnt2', 'global', k); };
        var domVal = function(id, fallback) {
            var el = document.getElementById(id);
            return el ? (el.value || '').trim() : fallback;
        };
        var boolStr = function(v) { return v === '1' ? '1' : '0'; };
        return [
            domVal('s-config-path', g('config_path') || '/etc/vnt2_config'),
            domVal('s-bin-path',    g('bin_path')    || '/usr/bin'),
            domVal('s-arch',        g('arch')        || 'auto'),
            g('mirror')                    || 'github',
            g('web_token')                  || '',
            g('web_addr')                   || '0.0.0.0:19099',
            boolStr(g('web_enabled') == null ? '1' : g('web_enabled')),
            domVal('s-web-data-dir', g('web_data_dir') || '/vnt_config'),
            boolStr(g('auto_update')),
            parseInt(g('update_interval')) || 7,
            boolStr(g('upx_compressed')),
            parseInt(g('respawn_threshold')) || 3600,
            parseInt(g('respawn_timeout'))   || 5,
            parseInt(g('respawn_retry'))     || 5,
            boolStr(g('log_to_file')),
            boolStr(g('log_errors_only')),
            parseInt(g('log_max_kb'))        || 300,
            parseInt(g('startup_check_window')) || 60,
            parseInt(g('kill_interval')) || 1800,
            boolStr(g('fw_vnt_to_lan')),
            boolStr(g('fw_lan_to_vnt')),
            boolStr(g('fw_vnt_to_wan')),
            boolStr(g('fw_wan_to_vnt')),
            boolStr(g('fw_vnt_web')),
            boolStr(g('fw_vnts_web')),
        ];
    },

    _validateSettings: function() {
        var self = this;
        var fields = [
            ['s-config-path', _('Configuration Path')],
            ['s-bin-path', _('Binary Path')],
            ['s-web-data-dir', _('vnt2_web Data Directory')],
            ['s-arch', _('Device Architecture')],
            ['s-interval', _('Update Interval (Days)')],
            ['s-startup-check-window', _('Public IP Check Timeout (s)')],
            ['s-kill-interval', _('Restart Cooldown (s)')],
            ['s-respawn-threshold', _('Failure Threshold (s)')],
            ['s-respawn-timeout', _('Restart Delay (s)')],
            ['s-respawn-retry', _('Restart Retries')],
            ['s-log-max-kb', _('Log Max Size (KB)')]
        ];
        var missing = [];
        fields.forEach(function(item) {
            var el = document.getElementById(item[0]);
            if (el && !(el.value || '').trim()) {
                missing.push(item[1]);
                el.classList.add('vnt2-input-error');
            } else if (el) {
                el.classList.remove('vnt2-input-error');
            }
        });
        if (missing.length) {
            self._ui.notify(_('The following required fields are not filled: %s').format(missing.join(', ')), 'error');
            var first = document.getElementById(fields.filter(function(item) {
                var el = document.getElementById(item[0]);
                return el && !(el.value || '').trim();
            })[0][0]);
            if (first) first.focus();
            return false;
        }
        return true;
    },

    handleSave: function() {
        var self = this;
        if (!self._validateSettings()) return Promise.resolve({ result:'error', code:'invalid_settings' });
        return callSaveSettings.apply(null, self._getUciSettings()).then(function(r) {
            if (!r || r.result !== 'ok')
                self._ui.notify(_('Token must be exactly 64 hexadecimal characters'), 'error');
            return r;
        });
    },

    handleSaveApply: function() {
        var self = this;
        if (!self._validateSettings()) return Promise.resolve({ result:'error', code:'invalid_settings' });
        return callSaveSettings.apply(null, self._getUciSettings())
            .then(function(r) {
                if (!r || r.result !== 'ok') {
                    self._ui.notify(_('Token must be exactly 64 hexadecimal characters'), 'error');
                    return r;
                }
                return ui.changes.apply();
            });
    },

    handleReset: function() {
        return uci.load('vnt2').then(function() { location.reload(); });
    },

    _buildTabContainer: function(tabs) {
        var self   = this;
        var header = E('div', { 'class':'vnt2-page-tabs' });
        var body   = E('div', {});
        var activeHash = location.hash.replace('#','') || tabs[0].id;
        var hasMatch = tabs.some(function(t){ return t.id === activeHash; });
        if(!hasMatch) activeHash = tabs[0].id;
        tabs.forEach(function(tab) {
            var active = tab.id === activeHash;
            header.appendChild(E('button', {
                'type':'button',
                'data-tab': tab.id,
                'class':'vnt2-page-tab' + (active ? ' active' : ''),
                'click': function(ev) {
                    self._switchTab(ev.currentTarget.getAttribute('data-tab'));
                }
            }, tab.label));
            body.appendChild(E('div', {
                'id': tab.id, 'style': 'display:' + (active ? 'block' : 'none') + ';'
            }, [tab.content]));
        });
        return E('div', {}, [header, body]);
    },

    _switchTab: function(activeId) {
        location.hash = activeId;
        document.querySelectorAll('[data-tab]').forEach(function(el) {
            var active = el.getAttribute('data-tab') === activeId;
            el.classList.toggle('active', active);
        });
        ['tab-settings', 'tab-update'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) el.style.display = id === activeId ? 'block' : 'none';
        });
        var footer = document.querySelector('.cbi-page-actions');
        if (footer) footer.style.display = activeId === 'tab-update' ? 'none' : '';
    },

    _buildSettingsTab: function() {
        var self = this, vui = self._ui;
        var g    = function(k) { return uci.get('vnt2', 'global', k); };

        function buildCheck(id, uciKey) {
            return vui.toggleSwitch(id, g(uciKey) === '1', function(ev, cb) {
                uci.set('vnt2', 'global', uciKey, cb.checked ? '1' : '0');
            }, _('Enabled'));
        }

        function buildText(id, uciKey, style, fallback) {
            return E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': id,
                'value':  g(uciKey) || fallback || '',
                'style':  style || 'width:100%;max-width:360px;box-sizing:border-box;',
                'change': function() { uci.set('vnt2', 'global', uciKey, this.value.trim()); }
            });
        }

        function buildCheckRow(opt) {
            return vui.buildFormRow(opt.label,
                buildCheck('s-' + opt.key, opt.key), opt.desc || '');
        }

        var mirrorSel = E('select', { 'class': 'cbi-input-select', 'id': 's-mirror',
            'style': 'width:auto;',
            'change': function() { uci.set('vnt2', 'global', 'mirror', this.value); }
        }, MIRROR_OPTIONS.map(function(o) {
            var a = { 'value': o.value };
            if (o.value === (g('mirror') || 'github')) a['selected'] = 'selected';
            return E('option', a, o.label);
        }));

        return E('div', {}, [
            E('div', { 'class': 'cbi-section vnt2-settings-card' }, [
                E('h3', {}, _('Basic Settings')),
                vui.buildFormRow(_('Configuration Path'),
                    buildText('s-config-path', 'config_path'),
                    _('Directory of configuration files, default /etc/vnt2_config')),
                vui.buildFormRow(_('Binary Path'),
                    buildText('s-bin-path', 'bin_path', 'width:100%;max-width:360px;box-sizing:border-box;', '/usr/bin'),
                    _('Directory shared by vnt2_cli, vnt2_ctrl, vnt2_web and vnts2. Default /usr/bin')),
                vui.buildFormRow(_('vnt2_web Data Directory'),
                    buildText('s-web-data-dir', 'web_data_dir', 'width:100%;max-width:360px;box-sizing:border-box;', '/vnt_config'),
                    _('Directory where vnt2_web instance files (*.toml) are stored, default /vnt_config. Restart vnt2_web after changing')),
                vui.buildFormRow(_('Device Architecture'),
                    buildText('s-arch', 'arch', 'width:100%;max-width:200px;box-sizing:border-box;'),
                    _('Current detected: %s, automatic recognition by auto, or manual specification')
                       .format(self._sysinfo.arch || _('Unknown'))),
                vui.buildFormRow(_('Download Mirror'), mirrorSel, _('Multiple mirrors ensure successful downloads')),
                vui.buildFormRow(_('Auto Update'),
                    vui.toggleSwitch('s-auto-update', g('auto_update') === '1', function(ev, cb) {
                        uci.set('vnt2', 'global', 'auto_update', cb.checked ? '1' : '0');
                        var row = document.getElementById('s-interval-row');
                        if (row) row.style.display = cb.checked ? '' : 'none';
                    }, _('Enable auto update')), _('Automatically check and update programs periodically')),
                E('div', { 'id': 's-interval-row', 'style': 'display:' + (g('auto_update') === '1' ? '' : 'none') + ';' }, [
                    (function() {
                        var inpInterval = E('input', { 'type': 'number', 'class': 'cbi-input-text',
                            'id': 's-interval',
                            'value': g('update_interval') || '7',
                            'min': '1', 'max': '365', 'style': 'width:80px;',
                            'input': function() {
                                descInterval.textContent = _('Check for updates every %d days').format(this.value || '7');
                            },
                            'change': function() {
                                uci.set('vnt2', 'global', 'update_interval', this.value || '7');
                            }
                        });
                        var descInterval = E('span', {}, _('Check for updates every %d days').format(inpInterval.value));
                        return vui.buildFormRow(_('Update Interval (Days)'), inpInterval, descInterval);
                    })()
                ]),
                vui.buildFormRow(_('UPX Compression'),
                    buildCheck('s-upx', 'upx_compressed'), _('Significantly reduce binary file size'))
            ]),
            E('div', { 'class': 'cbi-section vnt2-settings-card' }, [
                E('h3', {}, _('Process Watchdog (Respawn)')),
                (function() {
                    var inp = E('input', { 'type':'number', 'class':'cbi-input-text',
                        'id':'s-startup-check-window', 'value': g('startup_check_window') || '60', 'min':'0', 'max':'3600', 'style':'width:100px;',
                        'input': function() {
                            desc.textContent = _('Restart if no public IP is received within %d seconds; 0 disables this check.').format(this.value || '60');
                        },
                        'change': function() { uci.set('vnt2', 'global', 'startup_check_window', this.value || '60'); }
                    });
                    var desc = E('span', {}, _('Restart if no public IP is received within %d seconds; 0 disables this check.').format(inp.value));
                    return vui.buildFormRow(_('Public IP Check Timeout (s)'), inp, desc);
                })(),
                (function() {
                    var inp = E('input', { 'type':'number', 'class':'cbi-input-text',
                        'id':'s-kill-interval', 'value': g('kill_interval') || '1800', 'min':'0', 'max':'86400', 'style':'width:100px;',
                        'input': function() {
                            desc.textContent = _('Do not trigger another wrapper restart within %d seconds; 0 disables cooldown.').format(this.value || '1800');
                        },
                        'change': function() { uci.set('vnt2', 'global', 'kill_interval', this.value || '1800'); }
                    });
                    var desc = E('span', {}, _('Do not trigger another wrapper restart within %d seconds; 0 disables cooldown.').format(inp.value));
                    return vui.buildFormRow(_('Restart Cooldown (s)'), inp, desc);
                })(),
                    ...(function() {
                        var inpThreshold = E('input', { 'type': 'number', 'class': 'cbi-input-text',
                            'id': 's-respawn-threshold',
                            'value': g('respawn_threshold') || '3600', 'min': '0', 'style': 'width:100px;',
                            'input':  function() {
                                descThreshold.textContent = _('Count crashes within %d seconds, 0 = unlimited').format(this.value || '3600');
                            },
                            'change': function() {
                                uci.set('vnt2', 'global', 'respawn_threshold', this.value || '3600');
                            }
                        });
                        var descThreshold = E('span', {}, _('Count crashes within %d seconds, 0 = unlimited').format(inpThreshold.value));

                        var inpTimeout = E('input', { 'type': 'number', 'class': 'cbi-input-text',
                            'id': 's-respawn-timeout',
                            'value': g('respawn_timeout') || '5', 'min': '0', 'style': 'width:100px;',
                            'input': function() {
                                uci.set('vnt2', 'global', 'respawn_timeout', this.value || '5');
                                descTimeout.textContent = _('Wait %d seconds before restart after crash').format(this.value || '5');
                            }
                        });
                        var descTimeout = E('span', {}, _('Wait %d seconds before restart after crash').format(inpTimeout.value));

                        var inpRetry = E('input', { 'type': 'number', 'class': 'cbi-input-text',
                            'id': 's-respawn-retry',
                            'value': g('respawn_retry') || '5', 'min': '0', 'style': 'width:100px;',
                            'input': function() {
                                uci.set('vnt2', 'global', 'respawn_retry', this.value || '5');
                                descRetry.textContent = _('Max %d restarts then give up, 0 = unlimited').format(this.value || '5');
                            }
                        });
                        var descRetry = E('span', {}, _('Max %d restarts then give up, 0 = unlimited').format(inpRetry.value));

                        return [
                            vui.buildFormRow(_('Failure Threshold (s)'), inpThreshold, descThreshold),
                            vui.buildFormRow(_('Restart Delay (s)'),     inpTimeout,   descTimeout),
                            vui.buildFormRow(_('Restart Retries'),        inpRetry,     descRetry),
                        ];
                    })()
                ]),
            E('div', { 'class': 'cbi-section vnt2-settings-card' }, [
                E('h3', {}, _('Log Settings')),
                ...(function() {
                    var logEnabled = g('log_to_file') !== '0';
                    var cbLog = vui.toggleSwitch('s-log-to-file', logEnabled, function(ev, cb) {
                        uci.set('vnt2', 'global', 'log_to_file', cb.checked ? '1' : '0');
                        var box = document.getElementById('s-log-options');
                        if (box) box.style.display = cb.checked ? '' : 'none';
                    }, _('Save instance output to log file'));
                    var cbErrors = vui.toggleSwitch('s-log-errors-only', g('log_errors_only') === '1', function(ev, cb) {
                        uci.set('vnt2', 'global', 'log_errors_only', cb.checked ? '1' : '0');
                    }, _('Only save WARN and ERROR output'));
                    var inpLogMax = E('input', { 'type': 'number', 'class': 'cbi-input-text',
                        'id': 's-log-max-kb', 'value': g('log_max_kb') || '300',
                        'min': '50', 'max': '10240', 'style': 'width:100px;',
                        'change': function() { uci.set('vnt2', 'global', 'log_max_kb', this.value || '300'); }
                    });
                    return [
                        vui.buildFormRow(_('Enable instance log'), cbLog,
                            _('Disabling this only stops saving logs; process supervision is still handled by procd respawn.')),
                        E('div', {'id':'s-log-options', 'style':'display:'+(logEnabled?'':'none')+';'}, [
                            vui.buildFormRow(_('Errors and warnings only'), cbErrors,
                                _('Only WARN and ERROR lines are written to the instance log file.')),
                            vui.buildFormRow(_('Log Max Size (KB)'), inpLogMax,
                                _('Each instance log truncated at %d KB').format(inpLogMax.value))
                        ])
                    ];
                })()
            ]),
            E('div', { 'class': 'cbi-section vnt2-settings-card' }, [
                E('h3', {}, _('Firewall Forwarding')),
                E('div', {}, FW_OPTIONS.map(buildCheckRow))
            ])
        ]);
    },

    _buildUpdateTab: function() {
        var self = this, sys = self._sysinfo, bins = self._binaries;

        return E('div', { 'class': 'cbi-section vnt2-settings-card' }, [
            E('h3', {}, _('Current Version Info')),
            E('div', { 'class':'vnt2-version-box' },
                E('table', {}, [
                    E('thead', {}, E('tr', {},
                        [_('Component'), _('Version'), _('Status')].map(function(h) {
                            return E('th', {}, h);
                        })
                    )),
                    E('tbody', {}, [
                        E('tr', {}, [
                            E('td', {}, 'luci-app-vnt2'),
                            E('td', {}, sys.luci_version || _('Unknown')),
                            E('td', { 'class':'vnt2-ok-text' }, _('Installed'))
                        ])
                    ].concat(self._buildVersionRows(sys, bins)))
                ])
            ),
            E('h3', {}, _('Check Update')),
            self._buildUpdateBlock('luci-app-vnt2', _('LuCI Plugin (luci-app-vnt2)')),
            self._buildUpdateBlock('vnt',  _('VNT Client Web (vnt2_web)')),
            self._buildUpdateBlock('vnts', _('VNTS Server (vnts2)'))
        ]);
    },

    _buildVersionRows: function(sys, bins) {
        return COMPONENTS.map(function(comp) {
            var installed = !!bins[comp.binKey];
            return E('tr', { 'data-comp': comp.name }, [
                E('td', {}, comp.name),
                E('td', {},
                    installed ? (sys[comp.versionKey] || _('Unknown')) : _('Not installed')),
                E('td', { 'class': installed ? 'vnt2-ok-text' : 'vnt2-err-text' },
                    installed ? _('Installed') : _('Not installed'))
            ]);
        });
    },

    _refreshVersionTable: function() {
        var self = this;
        Promise.all([callGetSystemInfo(), callCheckBinaries()]).then(function(res) {
            self._sysinfo  = res[0] || {};
            self._binaries = res[1] || {};
            var tbody = document.querySelector('[data-comp]');
            if (!tbody) return;
            tbody = tbody.parentNode;
            var newRows = self._buildVersionRows(self._sysinfo, self._binaries);
            var old = tbody.querySelectorAll('[data-comp]');
            old.forEach(function(el) { el.parentNode.removeChild(el); });
            newRows.forEach(function(row) { tbody.appendChild(row); });
        });
    },

    _buildUpdateBlock: function(project, title) {
        var self   = this;
        var bid    = 'upd-' + project;
        var mirror = uci.get('vnt2', 'global', 'mirror') || 'github';

        return E('div', { 'class':'vnt2-update-block' }, [
            E('h4', {}, title),
            E('div', { 'class': 'vnt2-row-flex', 'style': 'gap:10px;' }, [
                E('button', {
                    'class': 'btn cbi-button-action',
                    'id':    bid + '-check-btn',
                    'click': function() { self._checkUpstream(project, bid); }
                }, _('Check Upstream Version')),
                E('span', { 'id': bid + '-status', 'class': 'vnt2-update-status' },
                    _('Click to check and get version info'))
            ]),
            E('div', { 'id': bid + '-progress', 'style': 'display:none;margin-top:10px;' }, [
                E('div', { 'id': bid + '-meter' }, self._ui.progressBar(0, _('Progress'), 'vnt2-download-meter', 'green'))
            ]),
            E('div', { 'id': bid + '-mirror-row',
                'style': 'display:none;margin-top:8px;align-items:center;gap:8px;' }, [
                E('span', { 'class':'vnt2-update-status' }, _('Switch mirror and retry:')),
                E('select', {
                    'class': 'cbi-input-select',
                    'id':    bid + '-mirror',
                    'style': 'width:auto;'
                }, MIRROR_OPTIONS.map(function(o) {
                    var a = { 'value': o.value };
                    if (o.value === mirror) a['selected'] = 'selected';
                    return E('option', a, o.label);
                })),
                E('button', {
                    'class': 'btn cbi-button-action',
                    'click': function() { self._checkUpstream(project, bid); }
                }, _('Retry'))
            ]),
            E('div', { 'id': bid + '-selects',
                'style': 'display:none;margin-top:10px;' }, [
                E('div', { 'class': 'vnt2-row-flex', 'style': 'width:100%;box-sizing:border-box;overflow:hidden;' }, [
                    E('label', {}, _('Version:')),
                    E('select', { 'class': 'cbi-input-select', 'id': bid + '-tag',
                        'style': 'width:auto;max-width:100%;min-width:0;box-sizing:border-box;' }),
                    E('label', {}, _('File:')),
                    E('select', { 'class': 'cbi-input-select', 'id': bid + '-file',
                        'style': 'width:auto;max-width:100%;min-width:0;overflow:hidden;text-overflow:ellipsis;box-sizing:border-box;' }),
                    E('button', {
                        'class': 'btn cbi-button-apply',
                        'id':    bid + '-btn',
                        'click': function() { self._doUpdate(project, bid); }
                    }, _('Update Now'))
                ])
            ]),
            E('pre', { 'id': bid + '-log' })
        ]);
    },

    _el: function(id) { return document.getElementById(id); },

    _setBar: function(bid, pct) {
        var progress = this._el(bid + '-progress');
        if (!progress) return;
        var p = Math.min(100, Math.max(0, pct || 0));
        progress.style.display = 'block';
        var meter = progress.querySelector('.vnt2-meter');
        if (meter && this._ui && this._ui.updateProgressBar)
            this._ui.updateProgressBar(meter, p, _('Progress'), 'green');
    },

    _setStatus: function(bid, text, state) {
        var el = this._el(bid + '-status');
        if (!el) return;
        el.textContent = text;
        el.className = 'vnt2-update-status' + (state ? ' ' + state : '');
    },

    _showLog: function(bid, text) {
        var el = this._el(bid + '-log');
        if (!el) return;
        el.style.display = 'block';
        var self = this;
        el.innerHTML = '';
        text.split('\n').forEach(function(line) {
            if (!line) return;
            var span = document.createElement('span');
            span.className = 'vnt2-log-line';
            span.textContent = (self._events && self._events.line(line)) || line;
            el.appendChild(span);
        });
        el.scrollTop = el.scrollHeight;
    },

    _show: function(id, flex) {
        var el = this._el(id);
        if (el) el.style.display = flex ? 'flex' : 'block';
    },

    _hide: function(id) {
        var el = this._el(id);
        if (el) el.style.display = 'none';
    },

    _checkUpstream: function(project, bid) {
        var self     = this;
        var mirrorEl = this._el(bid + '-mirror');
        var mirror   = mirrorEl ? mirrorEl.value
                                : (uci.get('vnt2','global','mirror') || 'github');
        var checkBtn = this._el(bid + '-check-btn');
        if (checkBtn) checkBtn.disabled = true;
        self._hide(bid + '-mirror-row');
        self._hide(bid + '-selects');
        self._hide(bid + '-log');
        self._hide(bid + '-progress');
        self._setStatus(bid, _('Checking...'), '');
        callGetUpstreamVersion(project, mirror).then(function() {
            self._pollStatus(project, bid, 'check');
        }).catch(function(err) {
            if (checkBtn) checkBtn.disabled = false;
            self._setStatus(bid, _('Start failed: %s').format(String(err)), 'err');
            self._show(bid + '-mirror-row', true);
        });
    },

    _doUpdate: function(project, bid) {
        var self   = this;
        var tagEl  = this._el(bid + '-tag');
        var fileEl = this._el(bid + '-file');
        var btn    = this._el(bid + '-btn');
        var tag    = tagEl  ? tagEl.value  : '';
        var fname  = fileEl ? fileEl.value : '';

        if (!tag || !fname) {
            self._setStatus(bid, _('Please check version first'), 'err');
            return;
        }

        var upx = project !== 'luci-app-vnt2' &&
                  !!(this._el('s-upx') || {}).checked;

        if (project === 'luci-app-vnt2' && fname.toLowerCase().indexOf('i18n') === -1) {
            var lang = self._fmt.detectLang();
            var langFile = '';
            var releases = self._currentReleases || [];
            for (var i = 0; i < releases.length; i++) {
                if (releases[i].tag === tag) {
                    var files = releases[i].filenames || [];
                    for (var j = 0; j < files.length; j++) {
                        var fn = files[j].toLowerCase();
                        if (fn.indexOf('i18n') !== -1 && fn.indexOf(lang) !== -1) {
                            langFile = files[j];
                            break;
                        }
                    }
                    break;
                }
            }
            if (langFile) fname = fname + ' ' + langFile;
        }

        if (btn) btn.disabled = true;
        self._hide(bid + '-mirror-row');
        self._setBar(bid, 0);
        self._showLog(bid, _('Preparing to download...'));
        self._setStatus(bid, _('Downloading...'), '');

        callDoUpdate(project, tag, fname, upx).then(function(r) {
            if (!r || r.result !== 'ok') {
                if (btn) btn.disabled = false;
                self._setStatus(bid, _('Download start failed'), 'err');
                self._show(bid + '-mirror-row', true);
                return;
            }
            self._pollStatus(project, bid, 'download');
        }).catch(function(err) {
            if (btn) btn.disabled = false;
            self._setStatus(bid, _('Error: %s').format(String(err)), 'err');
            self._show(bid + '-mirror-row', true);
        });
    },

    _pollStatus: function(project, bid, phase) {
        var tr = function(s) {
            return s || '';
        };
        var self     = this;
        var checkBtn = this._el(bid + '-check-btn');
        var btn      = this._el(bid + '-btn');
        var dots     = 0;
        var done     = false;
        var timer    = null;
        var timeout  = null;

        function stopAll() {
            done = true;
            if (timer)   { clearInterval(timer);  timer   = null; }
            if (timeout) { clearTimeout(timeout);  timeout = null; }
        }

        timer = setInterval(function() {
            if (done) return;
            dots++;
            callGetUpdateStatus(project).then(function(s) {
                if (done || !s) return;
                var dot = '.'.repeat(dots % 4 + 1);
                if (s.status === 'checking') {
                    self._setStatus(bid, _('Checking') + dot, '');
                    return;
                }
                if (s.status === 'downloading') {
                    if (s.log) self._showLog(bid, s.log);
                    var p = s.progress || {};
                    if (p.pct != null && p.pct >= 0) {
                        self._setBar(bid, p.pct);
                        self._setStatus(bid, _('Downloading... %d%%').format(p.pct), '');
                    } else if (p.done) {
                        self._setBar(bid, 0);
                        self._setStatus(bid, _('Downloading... %s').format(self._fmt.bytes(p.done)), '');
                    } else {
                        self._setBar(bid, 0);
                        self._setStatus(bid, _('Downloading...'), '');
                    }
                    return;
                }
                if (s.status === 'installing' || s.status === 'processing') {
                    if (s.log) self._showLog(bid, s.log);
                    self._setBar(bid, 100);
                    self._setStatus(bid, _('Installing...'), '');
                    return;
                }
                stopAll();
                if (s.status === 'idle') {
                    if (checkBtn) checkBtn.disabled = false;
                    if (btn) btn.disabled = false;
                    self._setStatus(bid, _('Update task did not start or status was lost'), 'err');
                    self._show(bid + '-mirror-row', true);
                    return;
                }
                if (s.status === 'ready') {
                    if (checkBtn) checkBtn.disabled = false;
                    self._setStatus(bid, _('Found %d versions').format(s.count), 'ok');
                    self._populateReleases(s.releases, bid);
                    self._show(bid + '-selects');
                    return;
                }
                if (s.status === 'done') {
                    if (btn) btn.disabled = false;
                    self._setBar(bid, 100);
                    var installed = tr(s.installed) || '';
                    self._setStatus(bid, _('Installation complete: %s').format(installed), 'ok');
                    if (s.log) self._showLog(bid, s.log);
                    self._refreshVersionTable();
                    return;
                }
                if (s.status === 'error') {
                    if (checkBtn) checkBtn.disabled = false;
                    if (btn)      btn.disabled      = false;
                    var msg = (s.event && self._events)
                        ? self._events.text(s.event, s.args || {})
                        : ((s.code && self._events) ? self._events.text(s.code, s.args || {}) : '');
                    msg = msg || tr(s.msg) || _('Failed');
                    self._setStatus(bid, msg, 'err');
                    if (s.log) self._showLog(bid, s.log);
                    self._show(bid + '-mirror-row', true);
                    return;
                }
            }).catch(function() {});
        }, 1500);

        var timeoutMs = phase === 'check' ? 60000 : 600000;
        timeout = setTimeout(function() {
            if (done) return;
            stopAll();
            if (checkBtn) checkBtn.disabled = false;
            if (btn)      btn.disabled      = false;
            self._setStatus(bid, _('Timeout, please retry'), 'err');
            self._show(bid + '-mirror-row', true);
        }, timeoutMs);
    },

    _populateReleases: function(releasesData, bid) {
        var self = this;
        if (!releasesData || !releasesData.releases) return;
        var releases = releasesData.releases;
        self._currentReleases = releases;
        var tagSel   = this._el(bid + '-tag');
        var fileSel  = this._el(bid + '-file');
        if (!tagSel || !fileSel) return;
        tagSel.innerHTML = '';
        releases.forEach(function(r) {
            tagSel.appendChild(E('option', { 'value': r.tag }, r.tag));
        });
        function updateFiles() {
            var tag = tagSel.value, release = null;
            for (var i = 0; i < releases.length; i++) {
                if (releases[i].tag === tag) { release = releases[i]; break; }
            }
            fileSel.innerHTML = '';
            if (!release || !release.filenames) return;
            var uciArch   = uci.get('vnt2', 'global', 'arch') || '';
            var sysArch   = (self._sysinfo && self._sysinfo.arch) || '';
            var rawArch   = (uciArch && uciArch !== 'auto') ? uciArch : sysArch;
            var archParts = rawArch ? rawArch.split(' ') : [];
            if (archParts.length === 1 && sysArch) {
                var sysParts = sysArch.split(' ');
                if (sysParts[0] === archParts[0] && sysParts[1]) {
                    archParts.push(sysParts[1]);
                }
            }
            var arch1     = archParts[0] || '';
            var arch2     = archParts[1] || '';
            var matched   = -1;
            release.filenames.forEach(function(fname, idx) {
                fileSel.appendChild(E('option', { 'value': fname }, fname));
                if (matched < 0 && bid.indexOf('luci-app') !== -1
                    && fname.indexOf('luci-app') !== -1) matched = idx;
                if (matched >= 0) return;
                if (!arch1) return;
                var hit = arch2
                    ? (fname.indexOf(arch1) !== -1 && fname.indexOf(arch2) !== -1
                       && !(arch2.slice(-1) !== 'f' && fname.indexOf(arch2 + 'hf') !== -1))
                    : (fname.indexOf(arch1) !== -1);
                if (hit) matched = idx;
            });
            if (matched >= 0) fileSel.selectedIndex = matched;
        }
        tagSel.onchange = updateFiles;
        updateFiles();
    }
});
