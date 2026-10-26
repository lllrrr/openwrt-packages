'use strict';
'require view';
'require rpc';
'require dom';
'require poll';
'require ui';

var call_logs = rpc.declare({ object: 'webrtc-control', method: 'logs', expect: { '': {} } });
var call_clear_logs = rpc.declare({ object: 'webrtc-control', method: 'clear_logs', expect: { '': {} } });

function parse_record(line) {
    var type = line.match(/webrtc-drop-(stun_udp|stun_tcp|stun_ports)\b/);
    if (!type) return null;
    var source = line.match(/\bSRC=([^\s]+)/),
        target = line.match(/\bDST=([^\s]+)/),
        port = line.match(/\bDPT=(\d+)/);
    var time = line.match(/^(.*?)\s+(?:kern\.\w+\s+)?kernel:/);
    return [
        time ? time[1] : '—',
        source ? source[1] : '—',
        (target ? target[1] : '—') + (port ? ' / ' + port[1] : ''),
        type[1] === 'stun_udp' ? _('STUN · UDP') : type[1] === 'stun_tcp' ? _('STUN · TCP') : _('常见端口'),
    ];
}

return view.extend({
    load: function () {
        return call_logs();
    },
    render: function (data) {
        var body = E('tbody'),
            raw = E('pre', { style: 'max-height:60vh;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere' });
        var revision = 0;
        var clearing = false;
        var clear_button = E('button', { type: 'button', class: 'cbi-button cbi-button-neutral', title: _('只清空本插件展示的历史记录') }, _('清空记录'));
        function fill_logs(value) {
            var entries = value.entries || [];
            var records = entries
                .map(parse_record)
                .filter(function (record) {
                    return record !== null;
                })
                .slice(-50)
                .reverse();
            dom.content(
                body,
                records.length
                    ? records.map(function (record) {
                          return E(
                              'tr',
                              { class: 'tr' },
                              record.map(function (value) {
                                  return E('td', { class: 'td' }, value);
                              }),
                          );
                      })
                    : E('tr', { class: 'tr' }, [E('td', { class: 'td', colspan: 4 }, _('暂无拦截记录'))]),
            );
            dom.content(raw, entries.join('\n') || _('暂无日志'));
        }
        fill_logs(data || {});
        poll.add(function () {
            if (clearing) return Promise.resolve();
            var request_revision = revision;
            return call_logs().then(function (value) {
                if (request_revision === revision && !clearing) fill_logs(value);
            });
        }, 5);
        clear_button.addEventListener('click', function () {
            clearing = true;
            revision++;
            clear_button.disabled = true;
            return call_clear_logs()
                .then(function (result) {
                    if (!result.success) throw new Error(result.error || _('清空失败，请重试'));
                    return call_logs();
                })
                .then(function (value) {
                    fill_logs(value);
                    ui.addNotification(null, E('p', _('历史记录已清空，拦截次数保留')), 'info');
                })
                .catch(function (failure) {
                    ui.addNotification(null, E('p', String(failure)), 'error');
                })
                .finally(function () {
                    clearing = false;
                    clear_button.disabled = false;
                });
        });
        var raw_button = E(
            'button',
            {
                type: 'button',
                class: 'cbi-button cbi-button-neutral',
                click: function () {
                    ui.showModal(_('原始日志'), [
                        raw,
                        E('div', { class: 'right' }, [E('button', { type: 'button', class: 'cbi-button', click: ui.hideModal }, _('关闭'))]),
                    ]);
                },
            },
            _('原始日志'),
        );
        return E('div', { class: 'cbi-map' }, [
            E('h2', _('拦截日志')),
            E('p', { class: 'cbi-map-descr' }, _('最近 50 条拦截，每 5 秒刷新；日志按速率采样，次数以总览为准')),
            E('div', { class: 'cbi-section' }, [
                E('h3', _('拦截记录')),
                E('div', { class: 'cbi-section-node', style: 'overflow-x:auto' }, [
                    E('table', { class: 'table' }, [
                        E('thead', [
                            E(
                                'tr',
                                { class: 'tr' },
                                [_('时间'), _('来源 IP'), _('目标 IP / 端口'), _('拦截方式')].map(function (label) {
                                    return E('th', { class: 'th' }, label);
                                }),
                            ),
                        ]),
                        body,
                    ]),
                ]),
            ]),
            E('div', { class: 'cbi-page-actions' }, [raw_button, ' ', clear_button]),
        ]);
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,
});
