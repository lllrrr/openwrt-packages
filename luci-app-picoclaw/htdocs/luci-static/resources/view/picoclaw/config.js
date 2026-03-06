/*   Copyright (C) 2021-2026 LIKE2000-ART */
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require form';
'require poll';
'require rpc';

const getPicoClawInfo = rpc.declare({
    object: 'luci.picoclaw',
    method: 'get_ver',
    expect: { 'ver': {} }
});

async function checkProcess() {
    try {
        const pidofRes = await fs.exec('/bin/pidof', ['picoclaw']);
        if (pidofRes.code === 0) {
            return {
                running: true,
                pid: pidofRes.stdout.trim()
            };
        }
    } catch (err) { }
    try {
        const psRes = await fs.exec('/bin/ash', ['-c', 'ps | grep -q "[p]icoclaw"']);
        return {
            running: psRes.code === 0,
            pid: null
        };
    } catch (err) {
        return { running: false, pid: null };
    }
}

function getVersionInfo() {
    return L.resolveDefault(getPicoClawInfo(), {}).then(function (result) {
        return result || {};
    }).catch(function (error) {
        console.error('Failed to get version:', error);
        return {};
    });
}

function renderStatus(isRunning, listen_port, version) {
    var statusText = isRunning ? _('RUNNING') : _('NOT RUNNING');
    var color = isRunning ? 'green' : 'red';
    var icon = isRunning ? '✓' : '✗';
    var versionText = version ? 'v' + version : '';

    var html = String.format(
        '<em><span style="color:%s">%s <strong>%s %s - %s</strong></span></em>',
        color, icon, 'PicoClaw', versionText, statusText
    );

    if (isRunning && listen_port) {
        html += String.format('&#160;<a class="btn cbi-button" href="http://%s:%s/health" target="_blank">%s</a>',
            window.location.hostname, listen_port, _('Open Web Interface'));
    }

    return html;
}

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('picoclaw')
        ]);
    },

    render: function (data) {
        var m, s, o;
        var listen_port = uci.get('picoclaw', 'gateway', 'port') || '18790';

        m = new form.Map('picoclaw', _('PicoClaw'),
            _('PicoClaw is an ultra-lightweight AI Assistant. Tiny, Fast, and Deployable anywhere.'));

        // Status section
        s = m.section(form.TypedSection);
        s.anonymous = true;

        s.render = function () {
            var statusView = E('p', { id: 'control_status', style: 'padding: 15px; border-radius: 8px; background: #f8f9fa; border: 1px solid #e9ecef; box-shadow: 0 2px 4px rgba(0,0,0,0.05); font-size: 14px;' },
                '<span class="spinning"></span> ' + _('Checking status...'));

            window.statusPoll = function () {
                return Promise.all([
                    checkProcess(),
                    getVersionInfo()
                ]).then(function (results) {
                    var [processInfo, versionInfo] = results;
                    var version = versionInfo.version || '';
                    statusView.innerHTML = renderStatus(processInfo.running, listen_port, version);
                }).catch(function (err) {
                    console.error('Status check failed:', err);
                    statusView.innerHTML = '<span style="color:orange; font-weight: bold;">⚠ ' + _('Status check error') + '</span>';
                });
            };

            poll.add(window.statusPoll, 5);

            return E('div', { class: 'cbi-section', id: 'status_bar' }, [
                statusView,
                E('div', { 'style': 'text-align: right; font-style: italic; margin-top: 10px; color: #6c757d; font-size: 12px;' }, [
                    E('span', {}, [
                        _('Powered by open source: '),
                        E('a', {
                            'href': 'https://github.com/sipeed/picoclaw',
                            'target': '_blank',
                            'style': 'text-decoration: none; color: #007bff;'
                        }, 'PicoClaw UI by LIKE2000-ART')
                    ])
                ])
            ]);
        };

        // Basic settings
        s = m.section(form.NamedSection, 'config', 'basic');
        s.title = _('⚙️ Basic Settings');

        o = s.option(form.Flag, 'enabled', _('Enable PicoClaw'));
        o.description = _('Enable the PicoClaw background daemon.');
        o.default = '1';
        o.rmempty = false;

        o = s.option(form.Value, 'delay', _('Delayed Start (seconds)'));
        o.description = _('Delay the startup of the service to wait for network readiness.');
        o.default = '0';
        o.datatype = 'uinteger';

        // Gateway settings
        s = m.section(form.NamedSection, 'gateway', 'gateway');
        s.title = _('🌐 Gateway Settings');

        o = s.option(form.Value, 'host', _('Listen Address'));
        o.description = _('The IP address the API server will bind to (0.0.0.0 for all interfaces).');
        o.default = '0.0.0.0';
        o.rmempty = false;

        o = s.option(form.Value, 'port', _('Listen Port'));
        o.description = _('The port number for the PicoClaw local API dashboard.');
        o.default = '18790';
        o.datatype = 'port';
        o.rmempty = false;

        // Agent settings
        s = m.section(form.NamedSection, 'agent', 'agent');
        s.title = _('🤖 Agent Settings');

        o = s.option(form.Value, 'workspace', _('Workspace Path'));
        o.description = _('Absolute path to store AI memories, chats, tasks, and configurations. E.g., /opt/picoclaw/workspace');
        o.default = '/opt/picoclaw/workspace';
        o.rmempty = false;

        o = s.option(form.Flag, 'restrict_to_workspace', _('Restrict to workspace (Sandbox)'));
        o.description = _('Highly recommended. Prevents the AI from reading/modifying files outside the workspace directory.');
        o.default = '0';
        o.rmempty = false;


        // Heartbeat settings
        s = m.section(form.NamedSection, 'heartbeat', 'heartbeat');
        s.title = _('❤️ Heartbeat Settings');

        o = s.option(form.Flag, 'enabled', _('Enable Heartbeat'));
        o.description = _('Send periodic keep-alive signals for active channels (e.g., Telegram, Discord).');
        o.default = '1';
        o.rmempty = false;

        o = s.option(form.Value, 'interval', _('Heartbeat Interval (minutes)'));
        o.default = '30';
        o.datatype = 'uinteger';

        return m.render();
    }
});
