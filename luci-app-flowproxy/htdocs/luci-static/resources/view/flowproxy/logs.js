'use strict';
'require form';
'require uci';
'require rpc';
'require view';
'require ui';

var callGetLogs = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_logs',
    params: ['lines']
});

var callClearLogs = rpc.declare({
    object: 'luci.flowproxy',
    method: 'clear_logs'
});

return L.view.extend({
    load: function() {
        return uci.load('flowproxy');
    },

    render: function() {
        var m, s, o;

        m = new form.Map('flowproxy', _('flowproxy - logs'),
            _('configure and view service runtime logs.'));

        // 日志设置区块
        s = m.section(form.NamedSection, 'global', 'flowproxy', _('log settings'));
        
        o = s.option(form.ListValue, 'log_level', _('log level'));
        o.value('debug', 'debug'); o.value('info', 'info'); o.value('warn', 'warn'); o.value('error', 'error');
        o.default = 'info';

        o = s.option(form.Value, 'log_size', _('log size (kb)'));
        o.datatype = 'uinteger';
        o.default = '1024';

        o = s.option(form.Value, 'log_count', _('log count'));
        o.datatype = 'uinteger';
        o.default = '3';

        // 样式适配
        var style = E('style', {}, `
            #log-content { 
                width: 100%; height: 600px; font-family: monospace; font-size: 12px; 
                background: #f5f5f5 !important; color: #333 !important; 
                border: 1px solid #ccc !important; padding: 10px; resize: vertical; 
                border-radius: 4px;
            }
        `);
        document.head.appendChild(style);

        // 日志查看区块
        s = m.section(form.NamedSection, '_logs', 'flowproxy', _('log output'));
        s.render = L.bind(function() {
            return E('div', { 'class': 'cbi-section-node' }, [
                E('div', { 'class': 'cbi-page-actions', 'style': 'margin-bottom: 10px' }, [
                    E('button', { 'class': 'cbi-button cbi-button-refresh', 'click': L.bind(this.refreshLogs, this) }, _('refresh logs')),
                    E('button', { 'class': 'cbi-button cbi-button-reset', 'click': L.bind(this.clearLogs, this) }, _('clear logs'))
                ]),
                E('textarea', {
                    'id': 'log-content',
                    'readonly': true
                }, _('loading logs...'))
            ]);
        }, this);

        return m.render().then(L.bind(function(node) {
            this.refreshLogs();
            return node;
        }, this));
    },

    refreshLogs: function() {
        callGetLogs(500).then(L.bind(function(data) {
            var logEl = document.getElementById('log-content');
            var logs = (data && Array.isArray(data.logs)) ? data.logs : [];
            if (logEl) {
                logEl.value = logs.length > 0 ? logs.join('\n') : _('no logs available');
                if (logs.length > 0) logEl.scrollTop = logEl.scrollHeight;
            }
        }, this));
    },

    clearLogs: function() {
        if (confirm(_('really clear all service logs?'))) {
            callClearLogs().then(L.bind(this.refreshLogs, this));
        }
    }
});