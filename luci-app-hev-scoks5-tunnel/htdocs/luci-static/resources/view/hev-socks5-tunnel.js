'use strict';
'require form';
'require poll';
'require rpc';
'require uci';
'require view';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});


function getServiceStatus() {
    return L.resolveDefault(callServiceList('hev-socks5-tunnel'), {}).then(function (res) {
        var isRunning = false;
        try {
            isRunning = res['hev-socks5-tunnel']['instances']['hev-socks5-tunnel']['running'];
        } catch (e) { }
        return isRunning;
    });
}

function renderStatus(isRunning) {
    var spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';
    var renderHTML;
    if (isRunning) {
        renderHTML = spanTemp.format('green', _('hev-socks5-tunnel'), _('RUNNING'));
    } else {
        renderHTML = spanTemp.format('red', _('hev-socks5-tunnel'), _('NOT RUNNING'));
    }
    return renderHTML;
}

return view.extend({
    render: function() {
        var m, s, o;    

        m = new form.Map('hev-socks5-tunnel', _('Hev Socks5 Tunnel'),
            _('Hev Socks5 Tunnel - A tunnel over Socks5 proxy.'));

        // Status section
        s = m.section(form.TypedSection);
        s.anonymous = true;
        s.render = function () {
            poll.add(function () {
                return L.resolveDefault(getServiceStatus()).then(function (res) {
                    var view = document.getElementById('service_status');
                    view.innerHTML = renderStatus(res);
                });
            });

            return E('div', { class: 'cbi-section', id: 'status_bar' }, [
                E('p', { id: 'service_status' }, _('Collecting data...'))
            ]);
            
        }
		// ========== Config Section ==========
        s = m.section(form.NamedSection, 'config', 'hev-socks5-tunnel');
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;

        // --- Tunnel Settings ---
        s.tab('tunnel', _('Tunnel'));

        o = s.taboption('tunnel', form.Value, 'tunnel_name', _('Interface Name'));
        o.placeholder = 'tun0';
        o.default = 'tun0';

        o = s.taboption('tunnel', form.Value, 'tunnel_mtu', _('MTU'));
        o.datatype = 'range(576,9000)';
        o.placeholder = '8500';
        o.default = '8500';

        o = s.taboption('tunnel', form.Value, 'tunnel_ipv4', _('IPv4 Address'));
        o.datatype = 'ip4addr';
        o.placeholder = '198.18.0.1';
        o.default = '198.18.0.1';

        o = s.taboption('tunnel', form.Value, 'tunnel_ipv6', _('IPv6 Address'));
        o.datatype = 'ip6addr';
        o.placeholder = 'fc00::1';
        o.default = 'fc00::1';

        // --- SOCKS5 Settings ---
        s.tab('socks5', _('SOCKS5 Server'));

        o = s.taboption('socks5', form.Value, 'socks5_address', _('Server Address'));
        o.datatype = 'ipaddr';
        o.placeholder = '127.0.0.1';
        o.default = '127.0.0.1';

        o = s.taboption('socks5', form.Value, 'socks5_port', _('Port'));
        o.datatype = 'port';
        o.placeholder = '1080';
        o.default = '1080';

        o = s.taboption('socks5', form.ListValue, 'socks5_udp', _('UDP Relay Mode'));
        o.value('tcp', _('TCP'));
        o.value('udp', _('UDP'));
        o.default = 'udp';

        o = s.taboption('socks5', form.Value, 'socks5_username', _('Username (optional)'));
        o.optional = true;

        o = s.taboption('socks5', form.Value, 'socks5_password', _('Password (optional)'));
        o.password = true;
        o.optional = true;

        // --- Mapped DNS ---
        s.tab('dns', _('Mapped DNS'));

        o = s.taboption('dns', form.Flag, 'mapdns_enabled', _('Enable Mapped DNS'));
        o.rmempty = false;

        o = s.taboption('dns', form.Value, 'mapdns_address', _('DNS Address'));
        o.datatype = 'ip4addr';
        o.placeholder = '198.18.0.2';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('dns', form.Value, 'mapdns_port', _('DNS Port'));
        o.datatype = 'port';
        o.placeholder = '53';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('dns', form.Value, 'mapdns_network', _('IP Network Base'));
        o.datatype = 'ip4addr';
        o.placeholder = '100.64.0.0';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('dns', form.Value, 'mapdns_netmask', _('Network Mask'));
        o.datatype = 'ip4addr';
        o.placeholder = '255.192.0.0';
        o.depends('mapdns_enabled', '1');

        // --- Advanced ---
        s.tab('misc', _('Advanced'));

        o = s.taboption('misc', form.ListValue, 'log_level', _('Log Level'));
        o.value('debug', _('Debug'));
        o.value('info', _('Info'));
        o.value('warn', _('Warn'));
        o.value('error', _('Error'));
        o.default = 'warn';

        o = s.taboption('misc', form.Value, 'log_file', _('Log File'));
        o.placeholder = 'stderr';
        o.default = 'stderr';

        return m.render();
    }

});