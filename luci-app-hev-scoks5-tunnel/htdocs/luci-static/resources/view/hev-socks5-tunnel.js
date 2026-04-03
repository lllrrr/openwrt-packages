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

        // --- Basic Configuration Tab ---
        s.tab('general', _('General'));

        // Enable switch as the first line
        o = s.taboption('general', form.Flag, 'enabled', _('Enable'));
        o.default = 0;
        o.rmempty = false;

        // Tunnel settings
        o = s.taboption('general', form.Value, 'tunnel_name', _('Interface Name'));
        o.placeholder = 'tun0';
        o.default = 'tun0';

        o = s.taboption('general', form.Value, 'tunnel_mtu', _('MTU'));
        o.datatype = 'range(576,9000)';
        o.placeholder = '8500';
        o.default = '8500';

        // Multi-queue flag
        o = s.taboption('general', form.Flag, 'tunnel_multi_queue', _('Multi-queue'));
        o.default = '0';
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'tunnel_ipv4', _('IPv4 Address'));
        o.datatype = 'ip4addr';
        o.placeholder = '198.18.0.1';
        o.default = '198.18.0.1';

        o = s.taboption('general', form.Value, 'tunnel_ipv6', _('IPv6 Address'));
        o.datatype = 'ip6addr';
        o.placeholder = 'fc00::1';
        o.default = 'fc00::1';

        // SOCKS5 Server settings
        o = s.taboption('general', form.Value, 'socks5_address', _('Server Address'));
        o.datatype = 'ipaddr';
        o.placeholder = '127.0.0.1';
        o.default = '127.0.0.1';

        o = s.taboption('general', form.Value, 'socks5_port', _('Port'));
        o.datatype = 'port';
        o.placeholder = '1080';
        o.default = '1080';

        o = s.taboption('general', form.ListValue, 'socks5_udp', _('UDP Relay Mode'));
        o.value('tcp', _('TCP'));
        o.value('udp', _('UDP'));
        o.default = 'udp';

        o = s.taboption('general', form.Flag, 'socks5_handshake_with_pipeline', _('Enable Handshake with Pipeline'));
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'socks5_username', _('Username (optional)'));
        o.optional = true;

        o = s.taboption('general', form.Value, 'socks5_password', _('Password (optional)'));
        o.password = true;
        o.optional = true;

        // Mapped DNS settings
        o = s.taboption('general', form.Flag, 'mapdns_enabled', _('Enable Mapped DNS'));
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'mapdns_address', _('DNS Address'));
        o.datatype = 'ip4addr';
        o.placeholder = '198.18.0.2';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('general', form.Value, 'mapdns_port', _('DNS Port'));
        o.datatype = 'port';
        o.placeholder = '53';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('general', form.Value, 'mapdns_network', _('IP Network Base'));
        o.datatype = 'ip4addr';
        o.placeholder = '100.64.0.0';
        o.depends('mapdns_enabled', '1');

        o = s.taboption('general', form.Value, 'mapdns_netmask', _('Network Mask'));
        o.datatype = 'ip4addr';
        o.placeholder = '255.192.0.0';
        o.depends('mapdns_enabled', '1');

        // --- Advanced Tab ---
        s.tab('advanced', _('Advanced'));

        // Tunnel advanced options
        o = s.taboption('advanced', form.Value, 'tunnel_post_up_script', _('Post-up Script'));
        o.placeholder = '/path/to/up.sh';
        o.optional = true;

        o = s.taboption('advanced', form.Value, 'tunnel_pre_down_script', _('Pre-down Script'));
        o.placeholder = '/path/to/down.sh';
        o.optional = true;

        // SOCKS5 advanced options
        o = s.taboption('advanced', form.Value, 'socks5_udp_address', _('Override UDP Address (optional)'));
        o.datatype = 'ipaddr';
        o.placeholder = '0.0.0.0';
        o.optional = true;

        o = s.taboption('advanced', form.Value, 'socks5_mark', _('Socket Mark'));
        o.datatype = 'uinteger';
        o.placeholder = '0';


        // Mapped DNS advanced options
        o = s.taboption('advanced', form.Value, 'mapdns_cache_size', _('DNS Cache Size'));
        o.datatype = 'uinteger';
        o.placeholder = '10000';

        // Misc / Performance options
        o = s.taboption('advanced', form.Value, 'misc_task_stack_size', _('Task Stack Size (bytes)'));
        o.datatype = 'uinteger';
        o.placeholder = '86016';

        o = s.taboption('advanced', form.Value, 'misc_tcp_buffer_size', _('TCP Buffer Size (bytes)'));
        o.datatype = 'uinteger';
        o.placeholder = '65536';

        o = s.taboption('advanced', form.Value, 'misc_udp_recv_buffer_size', _('UDP Recv Buffer Size (bytes)'));
        o.datatype = 'uinteger';
        o.placeholder = '524288';

        o = s.taboption('advanced', form.Value, 'misc_udp_copy_buffer_nums', _('UDP Copy Buffer Count'));
        o.datatype = 'uinteger';
        o.placeholder = '10';

        o = s.taboption('advanced', form.Value, 'misc_max_session_count', _('Max Session Count (0 = unlimited)'));
        o.datatype = 'uinteger';
        o.placeholder = '0';

        o = s.taboption('advanced', form.Value, 'misc_connect_timeout', _('Connect Timeout (ms)'));
        o.datatype = 'uinteger';
        o.placeholder = '10000';

        o = s.taboption('advanced', form.Value, 'misc_tcp_read_write_timeout', _('TCP Read/Write Timeout (ms)'));
        o.datatype = 'uinteger';
        o.placeholder = '300000';

        o = s.taboption('advanced', form.Value, 'misc_udp_read_write_timeout', _('UDP Read/Write Timeout (ms)'));
        o.datatype = 'uinteger';
        o.placeholder = '60000';

        o = s.taboption('advanced', form.Value, 'misc_pid_file', _('PID File (daemon mode)'));
        o.placeholder = '/run/hev-socks5-tunnel.pid';
        o.optional = true;

        o = s.taboption('advanced', form.Value, 'misc_limit_nofile', _('Limit NOFILE (ulimit -n)'));
        o.datatype = 'uinteger';
        o.placeholder = '65535';
        o.optional = true;

        // Logging options
        o = s.taboption('advanced', form.ListValue, 'log_level', _('Log Level'));
        o.value('debug', _('Debug'));
        o.value('info', _('Info'));
        o.value('warn', _('Warn'));
        o.value('error', _('Error'));
        o.default = 'warn';

        o = s.taboption('advanced', form.Value, 'log_file', _('Log File'));
        o.placeholder = 'stderr';
        o.default = 'stderr';

        return m.render();
    }
});