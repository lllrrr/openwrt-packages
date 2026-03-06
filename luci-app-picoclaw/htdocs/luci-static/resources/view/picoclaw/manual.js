/*   Copyright (C) 2021-2026 LIKE2000-ART */
'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

const CONFIG_PATH = '/etc/picoclaw/config.json';

const getConfig = rpc.declare({
    object: 'luci.picoclaw',
    method: 'get_config',
    expect: { '': {} }
});

const setConfig = rpc.declare({
    object: 'luci.picoclaw',
    method: 'set_config',
    params: ['content']
});

return view.extend({
    load: function () {
        return getConfig().then(function (result) {
            return result.content || '{}';
        }).catch(function () {
            return '{}';
        });
    },

    render: function (configContent) {
        var css = '\
            .config-actions { margin-top: 15px; display: flex; gap: 10px; align-items: center; } \
            .config-msg { margin-left: 15px; font-size: 14px; font-weight: bold; } \
            .config-msg.ok { color: #28a745; } \
            .config-msg.err { color: #dc3545; } \
            .config-footer { \
                margin-top: 20px; text-align: right; font-style: italic; \
                display: flex; justify-content: space-between; align-items: center; \
            } \
            .config-path { font-size: 13px; color: #6c757d; font-family: monospace; background: #e9ecef; padding: 2px 6px; border-radius: 4px; } \
            .CodeMirror { border: 1px solid #ccc; border-radius: 4px; font-family: "SF Mono", "Fira Code", monospace; font-size: 14px; min-height: 500px; height: auto; } \
        ';

        try {
            var parsed = JSON.parse(configContent);
            configContent = JSON.stringify(parsed, null, 2);
        } catch (e) { }

        var textareaId = 'picoclaw-config-editor-' + Math.floor(Math.random() * 100000);
        var textarea = E('textarea', {
            'id': textareaId,
            'style': 'display: none;'
        }, configContent);

        var msgSpan = E('span', { 'class': 'config-msg' });
        var cmInstance = null;

        var deps = [
            E('link', { 'rel': 'stylesheet', 'href': '/luci-static/resources/codemirror/lib/codemirror.css' }),
            E('link', { 'rel': 'stylesheet', 'href': '/luci-static/resources/codemirror/theme/dracula.css' }),
            E('script', { 'src': '/luci-static/resources/codemirror/lib/codemirror.js' }),
            E('script', { 'src': '/luci-static/resources/codemirror/mode/javascript/javascript.js' })
        ];

        var formatBtn = E('button', {
            'class': 'cbi-button cbi-button-neutral',
            'click': function () {
                var content = cmInstance ? cmInstance.getValue() : textarea.value;
                try {
                    var obj = JSON.parse(content);
                    var formatted = JSON.stringify(obj, null, 2);
                    if (cmInstance) {
                        cmInstance.setValue(formatted);
                    } else {
                        textarea.value = formatted;
                    }
                    msgSpan.className = 'config-msg ok';
                    msgSpan.textContent = '✓ ' + _('JSON Formatted');
                } catch (e) {
                    msgSpan.className = 'config-msg err';
                    msgSpan.textContent = '✗ ' + _('JSON Error') + ': ' + e.message;
                }
            }
        }, _('Format JSON'));

        var mapDiv = E('div', { 'class': 'cbi-map' }, [
            E('style', [css]),
            deps[0], deps[1], deps[2], deps[3],
            E('h2', {}, _('📝 Manual Settings')),
            E('div', { 'class': 'cbi-map-descr' },
                _('Edit the raw <code>config.json</code> using the advanced CodeMirror editor. The service restarts automatically upon saving.')),
            E('div', { 'class': 'cbi-section' }, [
                textarea,
                E('div', { 'class': 'config-actions' }, [
                    formatBtn,
                    msgSpan
                ]),
                E('div', { 'class': 'config-footer' }, [
                    E('span', { 'class': 'config-path' }, '📁 ' + CONFIG_PATH),
                    E('span', {}, [
                        E('a', {
                            'href': 'https://github.com/sipeed/picoclaw/blob/main/README.md',
                            'target': '_blank',
                            'style': 'text-decoration: none; color: #007bff; font-weight: bold;'
                        }, '📖 ' + _('Config Reference'))
                    ])
                ])
            ])
        ]);

        // Init CodeMirror after DOM attaches
        setTimeout(function () {
            var el = document.getElementById(textareaId);
            if (el && window.CodeMirror) {
                cmInstance = window.CodeMirror.fromTextArea(el, {
                    mode: "application/json",
                    theme: "dracula",
                    lineNumbers: true,
                    lineWrapping: true,
                    matchBrackets: true,
                    tabSize: 2
                });
                // Store instance on the window so LuCI handlers can access it
                window.picoclawCMInstance = cmInstance;
            }
        }, 500);

        return mapDiv;
    },

    handleSave: function (ev) {
        var content = window.picoclawCMInstance ? window.picoclawCMInstance.getValue() : '';
        if (!content) return Promise.resolve();

        try {
            JSON.parse(content);
        } catch (e) {
            ui.addNotification(null, E('p', _('JSON Error') + ': ' + e.message), 'error');
            return Promise.reject(new Error('Invalid JSON'));
        }

        return setConfig(content).then(function (res) {
            if (res && res.code === 0) {
                ui.addNotification(null, E('p', _('Config saved successfully.')), 'info');
            } else {
                ui.addNotification(null, E('p', _('Save failed')), 'error');
                return Promise.reject(new Error('Save failed'));
            }
        });
    },

    handleSaveApply: function (ev) {
        return this.handleSave(ev).then(function () {
            ui.showModal(_('Applying changes'), [
                E('p', { 'class': 'spinning' }, _('Waiting for configuration to be applied...'))
            ]);

            return fs.exec('/etc/init.d/picoclaw', ['restart']).then(function () {
                window.setTimeout(function () {
                    ui.hideModal();
                }, 2500);
            });
        });
    },

    handleReset: function (ev) {
        return getConfig().then(function (result) {
            var content = result.content || '{}';
            try {
                content = JSON.stringify(JSON.parse(content), null, 2);
            } catch (e) { }

            if (window.picoclawCMInstance) {
                window.picoclawCMInstance.setValue(content);
            }
        });
    }
});
