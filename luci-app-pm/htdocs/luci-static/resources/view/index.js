'use strict';
'require view';
'require rpc';
'require ui';
'require fs';

var callReboot = rpc.declare({
    object: 'system',
    method: 'reboot',
    expect: { result: 0 }
});

return view.extend({
    render: function() {
        return E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('PowerManager')),
                 E('p', {}, [
                     _('Luci plugin that make ImmortalWRT poweroff and reboot to easy.'),
                   ' ',
                   E('a', {
                       'href': 'https://github.com/mokanove/luci-app-powermanager',
                       'target': '_blank',
                       'rel': 'noreferrer noopener',
                       'style': 'color: #007bff; text-decoration: none; margin-left: 5px;'
                   }, _('GitHub Project Address'))
                 ]),

                 E('hr'),

                 E('div', {
                     'style': 'display: flex; flex-direction: column; align-items: flex-start; gap: 8px;'
                 }, [
                     E('button', {
                         'class': 'cbi-button cbi-button-action important',
                         'style': 'min-width: 80px; width: auto; padding: 5px 15px;',
                         'click': ui.createHandlerFn(this, 'handleReboot')
                     }, _('Reboot')),

                   E('button', {
                       'class': 'cbi-button cbi-button-reset important',
                       'style': 'min-width: 80px; width: auto; padding: 5px 15px;',
                       'click': ui.createHandlerFn(this, 'handlePowerOff')
                   }, _('PowerOff'))
                 ])
        ]);
    },

    handleReboot: function(ev) {
        ui.showModal(_('Are you sure?'), [
            E('p', {}, _('Do you want to reboot this system?')),
                     E('div', { 'class': 'right' }, [
                         E('button', {
                             'class': 'btn cbi-button-action important',
                             'click': function() {
                                 ui.hideModal();
                                 callReboot().then(function(res) {
                                     ui.showModal(_('Rebooting...'), [
                                         E('p', { 'class': 'spinning' }, _('Waiting for device reconnect...'))
                                     ]);
                                     ui.awaitReconnect();
                                 }).catch(function(e) {
                                     ui.addNotification(null, E('p', _('Reboot failed')));
                                 });
                             }
                         }, _('Reboot')),
                       ' ',
                       E('button', {
                           'class': 'btn',
                           'click': ui.hideModal
                       }, _('Cancel'))
                     ])
        ]);
    },

    handlePowerOff: function(ev) {
        ui.showModal(_('Are you sure?'), [
            E('p', {}, _('Do you really want to shutdown the system? Problems may occur on unsupported devices.')),
                     E('div', { 'class': 'right' }, [
                         E('button', {
                             'class': 'btn cbi-button-reset important',
                             'click': function() {
                                 ui.hideModal();
                                 ui.showModal(_('Shutting down...'), [
                                     E('p', { 'class': 'spinning' }, _('The device is powering off...'))
                                 ]);
                                 fs.exec('/sbin/poweroff').catch(function(e) {
                                     ui.addNotification(null, E('p', _('PowerOff failed')));
                                 });
                             }
                         }, _('PowerOff')),
                       ' ',
                       E('button', {
                           'class': 'btn',
                           'click': ui.hideModal
                       }, _('Cancel'))
                     ])
        ]);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
