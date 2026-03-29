'use strict';
'require form';
'require fs';
'require ui';
'require view';
'require tools.widgets as widgets';

return view.extend({
    render: function() {
        var m, s, o;

        m = new form.Map('block_host', _('Host Blocker'), 
            _('Block specified hosts by hostname using nftables. Devices will be blocked from accessing the network.'));

        s = m.section(form.TypedSection, 'config', _('Settings'));
        s.anonymous = true;

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.default = '0';
        o.rmempty = false;

        o = s.option(form.Value, 'hostnames', _('Target Hostnames'),
            _('Enter hostnames to block, separated by spaces. Do not use commas.'));
        o.placeholder = 'Xiaomi-12X lian-xiang-xiao-xinPad-Pro-12-7';
        o.rmempty = false;

        return m.render();
    }
});
