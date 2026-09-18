'use strict';
'require view';
'require rpc';
'require poll';
'require vnt2.common';

function rpcDeclare(method, params) {
    return rpc.declare({ object:'luci.vnt2', method:method, params:params||[] });
}
var callListInstances = rpcDeclare('list_instances', []);
var callGetLog        = rpcDeclare('get_log',        ['name','lines','type']);
var callClearLog      = rpcDeclare('clear_log',      ['name','type']);

var LINE_OPTIONS  = [100, 200, 500, 1000, 0];
var DEFAULT_LINES = 200;

var MONTH_MAP = {
    Jan:'01',Feb:'02',Mar:'03',Apr:'04',May:'05',Jun:'06',
    Jul:'07',Aug:'08',Sep:'09',Oct:'10',Nov:'11',Dec:'12'
};

var LOG_LEVELS = [
    [/\]［ERROR］/, 'vnt2-log-error'],
    [/\]［WARN］/,  'vnt2-log-warn'],
    [/\]［INFO］/,  'vnt2-log-info'],
    [/\]［DEBUG］/, 'vnt2-log-debug'],
];

var RE_LOG1 = /^(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+\S+\s+\S+\s+(.*)$/;
var RE_LOG2 = /^(\w{3}\s+\d+\s+[\d:]+)\s+\S+\s+\S+\s+(.*)$/;
var RE_ISO  = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\s*/;

function getLogEl() {
    return document.getElementById('vnt2-log-content');
}

function scrollLog(toBottom) {
    var el = getLogEl();
    if (el) el.scrollTop = toBottom ? el.scrollHeight : 0;
}

function parseLogreadTime(raw) {
    raw = raw.trim();
    var pad = function(n) { return String(n).padStart(2,'0'); };
    var m1  = raw.match(/^\w{3}\s+(\w{3})\s+(\d+)\s+([\d:]+)\s+(\d{4})$/);
    if (m1) return m1[4]+'-'+(MONTH_MAP[m1[1]]||'01')+'-'+pad(m1[2])+' '+m1[3];
    var m2  = raw.match(/^(\w{3})\s+(\d+)\s+([\d:]+)$/);
    if (m2) return new Date().getFullYear()+'-'+(MONTH_MAP[m2[1]]||'01')+'-'+pad(m2[2])+' '+m2[3];
    return raw;
}

function getLineClass(line) {
    for (var i=0; i<LOG_LEVELS.length; i++)
        if (LOG_LEVELS[i][0].test(line)) return LOG_LEVELS[i][1];
    return 'vnt2-log-default';
}

function buildLogLine(timeStr, body, events) {
    var span = E('span', {'class':'vnt2-log-line'});
    if (timeStr)
        span.appendChild(E('span', {'class':'vnt2-log-time'}, timeStr));
    var lineClass = getLineClass(body);
    var eventText = events && events.line(body);
    var displayBody = eventText || body;
    span.appendChild(E('span', {'class':'vnt2-log-body '+lineClass}, displayBody));
    return span;
}

function instValue(inst) {
    return inst.name + '@' + (inst.type || '');
}

function buildInstOptions(instances, current, instLabel) {
    var opts = instances.length
        ? instances.map(function(inst) {
            return E('option', {
                'value':    instValue(inst),
                'selected': instValue(inst) === current ? 'selected' : null
            }, instLabel(inst));
        })
        : [E('option', {'value':''}, _('No Instance'))];
    opts.push(E('option', {
        'value':    'update_all',
        'selected': current === 'update_all' ? 'selected' : null
    }, _('Auto Download & Update')));
    return opts;
}

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    _pollHandle:     null,
    _instPollHandle: null,

    load: function() {
        return Promise.all([
            L.require('vnt2.common'),
            callListInstances()
        ]);
    },

    render: function(data) {
        var self      = this;
        self._ui      = data[0].VNT2UI;
        self._events  = data[0].VNT2Events;
        self._fmt     = data[0].VNT2Format;

        var instances = (data[1] && Array.isArray(data[1].instances))
            ? data[1].instances : [];
        self._instances       = instances;
        self._currentInstance = instances.length ? instValue(instances[0]) : null;

        var node = E('div', {'class':'cbi-map'}, [
            E('h2', {}, _('VNT2 Log')),
            E('div', {'class':'cbi-section vnt2-card'}, [
                self._renderToolbar(),
                E('pre', {
                    'id':    'vnt2-log-content',
                    'class': 'vnt2-console'
                }, self._currentInstance ? _('Loading...') : _('No Instance'))
            ])
        ]);

        if (self._currentInstance)
            window.setTimeout(function() { self._loadLog(); }, 200);

        self._instPollHandle = window.setInterval(function() {
            self._refreshInstances();
        }, 5000);

        return node;
    },

    _instLabel: function(inst) {
        var type   = inst.type === 'web' ? 'vnt2_web' : (inst.type === 'vnt' ? _('Client') : _('Server'));
        var status = inst.running ? _('Running') : _('Stopped');
        return inst.name+' ('+type+' · '+status+')';
    },

    _renderToolbar: function() {
        var self = this;

        var instanceSelect = E('select', {
            'id':     'vnt2-inst-select',
            'class':  'cbi-input-select',
            'style':  'width:auto;max-width:180px;min-width:0;box-sizing:border-box;',
            'change': function(ev) {
                self._currentInstance = ev.target.value;
                self._loadLog();
            },
            'focus': function() {
                if (self._instPollHandle) {
                    window.clearInterval(self._instPollHandle);
                    self._instPollHandle = null;
                }
            },
            'blur': function() {
                if (!self._instPollHandle)
                    self._instPollHandle = window.setInterval(function() {
                        self._refreshInstances();
                    }, 5000);
            }
        }, buildInstOptions(self._instances, self._currentInstance,
            function(inst) { return self._instLabel(inst); }));

        var linesSelect = E('select', {
            'class':  'cbi-input-select',
            'id':     'vnt2-log-lines',
            'style':  'width:auto;',
            'change': function() { self._loadLog(); }
        }, LINE_OPTIONS.map(function(n) {
            return E('option', {
                'value':    String(n),
                'selected': n === DEFAULT_LINES ? 'selected' : null
            }, n === 0 ? _('All') : _('Last %d lines').format(n));
        }));

        var autoCheck = self._ui.toggleSwitch('vnt2-log-auto-refresh', false, function(ev, input) {
            self._toggleAuto(input.checked);
        }, _('Auto Refresh (5s)'));

        var btns = [
            {label:_('Refresh'),          cls:'btn cbi-button-action',  fn:function(){self._loadLog();}},
            {label:_('Clear Log'),        cls:'btn cbi-button-negative', fn:function(){self._clearLog();}},
            {label:_('Scroll to Top'),    cls:'btn',                     fn:function(){scrollLog(false);}},
            {label:_('Scroll to Bottom'), cls:'btn',                     fn:function(){scrollLog(true);}},
        ];

        return E('div', {'class':'vnt2-log-toolbar'}, [
            E('label', {}, _('Instance:')),
            instanceSelect,
            linesSelect,
            autoCheck,
        ].concat(btns.map(function(b) {
            return E('button', {'class':b.cls,'click':b.fn}, b.label);
        })));
    },

    _refreshInstances: function() {
        var self = this;
        callListInstances().then(function(r) {
            var instances = (r && Array.isArray(r.instances)) ? r.instances : [];
            self._instances = instances;
            if (!instances.some(function(i) { return instValue(i) === self._currentInstance; })
                && self._currentInstance !== 'update_all')
                self._currentInstance = instances.length ? instValue(instances[0]) : null;
            self._rebuildSelect(instances);
        }).catch(function() {});
    },

    _rebuildSelect: function(instances) {
        var self = this;
        var sel  = document.getElementById('vnt2-inst-select');
        if (!sel) return;
        sel.innerHTML = '';
        buildInstOptions(instances, self._currentInstance,
            function(inst) { return self._instLabel(inst); }
        ).forEach(function(opt) { sel.appendChild(opt); });
        if (!instances.length) {
            var el = getLogEl();
            if (el) el.textContent = _('No Instance');
        }
    },

    _formatLog: function(content) {
        var el = getLogEl();
        if (!el) return;
        el.innerHTML = '';
        var self      = this;
        var stripAnsi = self._fmt.stripAnsi;
        var isUpdate  = self._currentInstance === 'update_all';
        var hasContent = false;

        content.split('\n').forEach(function(line) {
            if (!line.trim()) return;
            hasContent = true;
            var timeStr = '', body = line;
            if (!isUpdate) {
                var m1 = line.match(RE_LOG1);
                var m2 = !m1 && line.match(RE_LOG2);
                if (m1)      { timeStr = parseLogreadTime(m1[1]); body = m1[2]; }
                else if (m2) { timeStr = parseLogreadTime(m2[1]); body = m2[2]; }
            }
            body = stripAnsi(body.replace(RE_ISO, ''));
            el.appendChild(buildLogLine(timeStr, body || stripAnsi(line), self._events));
        });

        if (!hasContent)
            el.appendChild(E('span', {}, _('(No logs yet)')));
        el.scrollTop = el.scrollHeight;
    },

    _loadLog: function() {
        var self = this;
        if (!self._currentInstance) return;
        var linesEl  = document.getElementById('vnt2-log-lines');
        var lines    = linesEl ? parseInt(linesEl.value) : DEFAULT_LINES;
        var el       = getLogEl();
        if (!el) return;
        el.textContent = _('Loading...');

        var at = self._currentInstance.indexOf('@');
        var logName = at >= 0 ? self._currentInstance.slice(0, at) : self._currentInstance;
        var logType = at >= 0 ? self._currentInstance.slice(at + 1) : null;
        callGetLog(logName, lines === 0 ? null : lines, logType)
            .then(function(r) {
                var content = (r && r.content) || '';
                if (!content.trim()) {
                    el.innerHTML = '';
                    el.appendChild(E('span', {},
                        _('(No logs yet. The instance might not be started or has no output)')));
                    return;
                }
                self._formatLog(content);
            })
            .catch(function() {
                el.textContent = _('Failed to load log');
            });
    },

    _clearLog: function() {
        var self = this;
        if (!self._currentInstance) return;
        var at2 = self._currentInstance.indexOf('@');
        callClearLog(at2 >= 0 ? self._currentInstance.slice(0, at2) : self._currentInstance,
                     at2 >= 0 ? self._currentInstance.slice(at2 + 1) : null)
            .then(function() { self._loadLog(); });
    },

    _stopAuto: function() {
        if (this._pollHandle) {
            window.clearInterval(this._pollHandle);
            this._pollHandle = null;
        }
    },

    _toggleAuto: function(enabled) {
        var self = this;
        self._stopAuto();
        if (enabled)
            self._pollHandle = window.setInterval(function() { self._loadLog(); }, 5000);
    },

    destroy: function() {
        this._stopAuto();
        if (this._instPollHandle) {
            window.clearInterval(this._instPollHandle);
            this._instPollHandle = null;
        }
    }
});
