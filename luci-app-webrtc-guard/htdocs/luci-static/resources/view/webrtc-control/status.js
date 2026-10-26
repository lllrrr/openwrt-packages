'use strict';
'require view';
'require rpc';
'require uci';
'require ui';
'require dom';
'require poll';

var call_status = rpc.declare({ object: 'webrtc-control', method: 'status', expect: { '': {} } });
var call_stats = rpc.declare({ object: 'webrtc-control', method: 'stats', expect: { '': {} } });

return view.extend({
    load: function () {
        return Promise.all([call_status(), call_stats(), uci.load('webrtc-control')]);
    },
    render: function (data) {
        var state = E('span', { role: 'status' });
        var error = E('div', { class: 'alert-message warning', role: 'alert', hidden: true });
        var engine = E('span');
        var total = E('span');
        var counts = E('span');
        var button = E('button', { class: 'cbi-button cbi-button-action', type: 'button' });
        var current = data[0] || {};

        function fill_status(next) {
            current = next;
            dom.content(state, !next.enabled ? _('防护已关闭') : next.healthy ? _('防护运行中') : _('防护需要处理'));
            var message =
                next.error ||
                (next.outdated
                    ? _('设置尚未生效，请到设置页重新保存并应用')
                    : next.enabled && !next.loaded
                      ? _('防护规则未加载，请到设置页重新保存并应用')
                      : next.enabled && !next.healthy
                        ? _('防护检查未通过，请查看日志')
                        : '');
            error.hidden = !message;
            error.style.display = message ? '' : 'none';
            dom.content(error, message);
            dom.content(engine, next.openclash ? _('已适配 OpenClash，检查真实上网出口') : _('检查真实上网出口'));
            button.textContent = next.enabled ? _('关闭防护') : _('开启防护');
            button.className = 'cbi-button ' + (next.enabled ? 'cbi-button-action' : 'cbi-button-save');
        }
        function fill_stats(stats) {
            var udp = Number(stats.udp) || 0,
                tcp = Number(stats.tcp) || 0,
                ports = Number(stats.ports) || 0;
            dom.content(total, String(udp + tcp + ports));
            dom.content(counts, _('UDP 特征：%s · TCP 特征：%s · 常见端口：%s').format(udp, tcp, ports));
        }
        fill_status(current);
        fill_stats(data[1] || {});
        poll.add(function () {
            return Promise.all([call_status(), call_stats()]).then(function (result) {
                fill_status(result[0] || {});
                fill_stats(result[1] || {});
            });
        }, 5);
        button.addEventListener('click', function () {
            button.disabled = true;
            uci.set('webrtc-control', 'global', 'enabled', current.enabled ? '0' : '1');
            return uci
                .save()
                .then(function () {
                    return uci.apply();
                })
                .then(function () {
                    return call_status();
                })
                .then(function (status) {
                    fill_status(status);
                    ui.addNotification(null, E('p', _('设置已提交，防护状态将自动更新')), 'info');
                })
                .catch(function (failure) {
                    ui.addNotification(null, E('p', String(failure)), 'error');
                })
                .finally(function () {
                    button.disabled = false;
                });
        });
        function row(label, value) {
            return E('tr', { class: 'tr' }, [E('td', { class: 'td left', width: '33%' }, label), E('td', { class: 'td left' }, value)]);
        }
        return E('div', { class: 'cbi-map' }, [
            E('h2', _('WebRTC 防泄漏')),
            E('p', { class: 'cbi-map-descr' }, _('拦截可能暴露真实公网 IP 的 WebRTC 探测连接')),
            E('div', { class: 'cbi-section' }, [
                E('h3', _('运行状态')),
                E('div', { class: 'cbi-section-node' }, [
                    error,
                    E('table', { class: 'table' }, [
                        row(_('防护状态'), state),
                        row(_('出口检查'), engine),
                        row(_('本次拦截'), E('span', [total, _(' 次')])),
                        row(_('拦截分类'), counts),
                    ]),
                ]),
            ]),
            E('div', { class: 'cbi-page-actions' }, [
                button,
                ' ',
                E(
                    'a',
                    { class: 'cbi-button cbi-button-action', href: 'https://browserleaks.com/webrtc', target: '_blank', rel: 'noopener noreferrer' },
                    _('检测泄漏'),
                ),
                ' ',
                E(
                    'button',
                    {
                        type: 'button',
                        class: 'cbi-button cbi-button-neutral',
                        click: function () {
                            ui.showModal(_('防护说明'), [
                                E('p', _('拦截次数自本次规则加载起统计，每 5 秒更新')),
                                E('p', _('防护可能影响部分语音、视频通话；如有需要，可在设置中调整')),
                                E('p', _('默认关闭流量卸载以避免绕过检查，可能降低最高转发速度；停用时按记录恢复')),
                                E('p', _('加密或特殊通道仍可能绕过识别，本机地址的读取需由终端限制')),
                                E('div', { class: 'right' }, [E('button', { type: 'button', class: 'cbi-button', click: ui.hideModal }, _('关闭'))]),
                            ]);
                        },
                    },
                    _('说明'),
                ),
            ]),
        ]);
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,
});
