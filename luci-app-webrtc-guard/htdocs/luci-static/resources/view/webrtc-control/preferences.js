'use strict';
'require view';
'require form';
'require uci';
'require network';

return view.extend({
    load: function () {
        return Promise.all([uci.load('webrtc-control'), uci.load('firewall'), network.getHostHints()]);
    },
    render: function (data) {
        var hints = data[2] || {};
        var map = new form.Map('webrtc-control', _('防护设置'), _('默认设置适合大多数网络，调整后保存并应用即可'));
        var section = map.section(form.NamedSection, 'global', 'webrtc-control');
        section.tab('basic', _('基本设置'));
        section.tab('advanced', _('高级设置'));
        section.tab('devices', _('设备例外'), _('仅放行设备的直接转发，OpenClash 重新建立的连接仍受防护'));
        var option = section.taboption('basic', form.Flag, 'enabled', _('开启防护'));
        option.rmempty = false;
        option = section.taboption('basic', form.Flag, 'ports', _('辅助拦截'), _('拦截常见 STUN/TURN 端口；部分通话或代理连接异常时可尝试关闭'));
        option.default = '1';
        option.rmempty = false;
        option = section.taboption('basic', form.Flag, 'log', _('记录拦截日志'));
        option.default = '1';
        option.rmempty = false;

        option = section.taboption('advanced', form.ListValue, 'mode', _('检查出口'));
        option.value('proxy', _('真实上网出口（推荐）'));
        option.value('block', _('全部出口（含内网与隧道）'));
        option.default = 'proxy';
        option = section.taboption('advanced', form.Flag, 'dpi', _('识别 STUN 特征'), _('识别明文 UDP/TCP 探测，建议保持开启'));
        option.default = '1';
        option.rmempty = false;
        option = section.taboption(
            'advanced',
            form.Flag,
            'manage_offload',
            _('自动管理流量卸载'),
            _('防护开启时关闭加速以避免绕过，停用时按记录恢复；可能影响最高转发速度'),
        );
        option.default = '1';
        option.rmempty = false;
        option = section.taboption('advanced', form.DynamicList, 'egress_zones', _('上网出口区域'), _('通常为 wan；多出口请补全，不填写 OpenClash 隧道'));
        option.datatype = 'uciname';
        uci.sections('firewall', 'zone').forEach(function (zone) {
            if (zone.name) option.value(zone.name);
        });
        option = section.taboption(
            'advanced',
            form.DynamicList,
            'egress_devices',
            _('补充出口接口'),
            _('通常留空；仅补充区域中未关联的真实出口，例如 pppoe-wan'),
        );
        option.datatype = 'and(minlength(1),maxlength(15))';
        option = section.taboption('advanced', form.Flag, 'all_zones', _('检查所有来源网络'));
        option.default = '1';
        option.rmempty = false;
        option = section.taboption('advanced', form.DynamicList, 'zone', _('指定来源区域'), _('仅限定设备直接转发的流量，路由器本机出站仍受防护'));
        option.ucisection = 'scope';
        option.datatype = 'uciname';
        option.depends({ 'webrtc-control.global.all_zones': '0' });
        option.retain = true;
        uci.sections('firewall', 'zone').forEach(function (zone) {
            if (zone.name) option.value(zone.name);
        });

        option = section.taboption('devices', form.DynamicList, 'ip', _('放行 IP / 网段'));
        option.ucisection = 'whitelist';
        option.datatype = 'or(ipaddr,cidr4,cidr6)';
        Object.keys(hints).forEach(function (mac) {
            var host = hints[mac] || {},
                ip = host.ipv4 || (host.ipaddrs && host.ipaddrs[0]);
            if (ip) option.value(ip, ip + (host.name ? ' (' + host.name + ')' : ''));
        });
        option = section.taboption('devices', form.DynamicList, 'mac', _('放行 MAC 地址'));
        option.ucisection = 'whitelist';
        option.datatype = 'macaddr';
        Object.keys(hints).forEach(function (mac) {
            var host = hints[mac] || {};
            option.value(mac, mac + (host.name ? ' (' + host.name + ')' : ''));
        });
        return map.render();
    },
});
