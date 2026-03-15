'use strict';
'require form';
'require uci';
'require rpc';
'require poll';
'require view';
'require dom';
'require fs';

var callGetStatus = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_status'
});

var callGetInterfaces = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_interfaces'
});

return L.view.extend({
    load: function() {
        return Promise.all([
            uci.load('flowproxy').catch(function() { return {}; }),
            callGetInterfaces().catch(function() { return { interfaces: [] }; })
        ]);
    },

    render: function(data) {
        var ifdata = data[1];
        var m, s, o;

        m = new form.Map('flowproxy', _('代理分流'),
            _('traffic diversion based on nftables rules. the service will automatically start/stop when you click "save & apply".'));

        s = m.section(form.NamedSection, 'global', 'flowproxy', _('basic settings'));

        o = s.option(form.DummyValue, '_service_status', _('current status'));
        o.rawhtml = true;
        o.cfgvalue = function() {
            return '<div id="service-status" style="display:inline-block;"><em class="spinning">' + _('checking...') + '</em></div>';
        };

        o = s.option(form.DummyValue, '_dns_status', _('dns redirection'));
        o.rawhtml = true;
        o.cfgvalue = function() {
            return '<div id="dns-status" style="display:inline-block;">-</div>';
        };

        o = s.option(form.Flag, 'enabled', _('enable flowproxy'));
        o.rmempty = false; o.default = '0';
        o.description = _('to enable or disable TCP and UDP protocols, please go to the "Rules" page.');

        o = s.option(form.Flag, 'dns_proxy_enabled', _('force upstream dns to proxy server'));
        o.rmempty = false; o.default = '0';
        o.description = _('when enabled, dnsmasq will use the proxy server as the upstream dns server. "dns redirect" feature will be disabled.<br/>note: the "enable flowproxy" option must also be turned on for this to take effect.');

        o = s.option(form.Value, 'proxy_server_ip_addr', _('proxy server ip address'));
        o.datatype = 'ip4addr'; o.rmempty = false;
        o.default = '192.168.1.100';
        o.description = _('The server that has the proxy enabled and can forward IP traffic.');

        o = s.option(form.Value, 'proxy_server_dns_port', _('proxy server dns port'));
        o.datatype = 'port'; o.rmempty = false;
        o.default = '5353';
        o.description = _('The port of the DNS proxy service that provides DNS resolution for the local network.');

        o = s.option(form.ListValue, 'interface', _('network interface'));
        if (ifdata && ifdata.interfaces) {
            ifdata.interfaces.forEach(function(i) {
                o.value(i.name, i.name);
            });
        }
        o.default = 'br-lan';
        o.description = _('The network interface where the proxy server is located (usually LAN).');

        o = s.option(form.Value, 'traffic_mark', _('Traffic Mark'));
        o.datatype = 'and(uinteger,range(1, 4294967295))';
        o.default = '100';
        o.description = _('Mark value (fwmark) used to identify packets for diversion. 32-bit unsigned integer.');

        o = s.option(form.Value, 'routing_table', _('Routing Table ID'));
        o.datatype = 'and(uinteger,range(1, 4294967295))';
        o.default = '100';
        o.validate = function(section_id, value) {
            var v = parseInt(value);
            if (v === 0 || v === 253 || v === 254 || v === 255) {
                return _('IDs 0, 253, 254, 255 are reserved by the system.');
            }
            return true;
        };
        o.description = _('Routing table ID used for diverted traffic. Default is 100. Do not modify unless you have specific requirements.');

        return m.render().then(L.bind(function(node) {
            this.refreshStatus(m);

            poll.add(L.bind(function() {
                return this.refreshStatus(m);
            }, this), 5);

            return node;
        }, this));
    },

    refreshStatus: function(map) {
        return callGetStatus().then(L.bind(function(status) {
            if (!status) return;
            var isRunning = (status.running == 1);
            
            var statusEl = document.getElementById('service-status');
            if (statusEl) {
                if (isRunning) {
                    var chains = [];
                    if (status.nft && status.nft.tcp) chains.push('TCP');
                    if (status.nft && status.nft.udp) chains.push('UDP');
                    var ip = status.proxy_server_ip_addr || '-';
                    var protoHtml = chains.length > 0 ? 
                        '<span style="color: #FF9800; font-weight: bold;">' + chains.join('+') + '</span>' : '-';
                    statusEl.innerHTML = '<span style="color: green; font-weight: bold;">' + _('running') + '</span>' + 
                                         ' (' + ip + ':' + protoHtml + ')';
                } else {
                    statusEl.innerHTML = '<span style="color: red; font-weight: bold;">' + _('stopped') + '</span>';
                }
            }

            var dnsEl = document.getElementById('dns-status');
            if (dnsEl) {
                if (status.dns_running == 1) {
                    var ip = status.proxy_server_ip_addr || '-';
                    var portHtml = '<span style="color: #FF9800; font-weight: bold;">' + (status.proxy_server_dns_port || '5353') + '</span>';
                    dnsEl.innerHTML = '<span style="color: green; font-weight: bold;">' + _('running') + '</span>' + 
                                      ' (' + ip + ':' + portHtml + ')';
                } else {
                    dnsEl.innerHTML = '<span style="color: red; font-weight: bold;">' + _('stopped') + '</span>';
                }
            }

            ['dns-status'].forEach(function(id) {
                var el = document.getElementById(id);
                if (el) {
                    var rowEl = el.closest('.cbi-value') || el.parentNode.parentNode;
                    if (rowEl) rowEl.style.display = isRunning ? '' : 'none';
                }
            });

            // 核心修复：预填 Proxy Server IP 为 LAN IP + 1
            if (status.lan_ip) {
                var parts = status.lan_ip.split('.');
                if (parts.length === 4) {
                    parts[3] = parseInt(parts[3]) + 1;
                    var suggestedIp = parts.join('.');
                    
                    var ipOpt = map.lookupOption('proxy_server_ip_addr', 'global')[0];
                    if (ipOpt) {
                        ipOpt.placeholder = suggestedIp;
                        // 如果当前 UCI 值为空，则直接设置 default
                        var currentVal = uci.get('flowproxy', 'global', 'proxy_server_ip_addr');
                        if (!currentVal) {
                            var input = document.querySelector('input[name="cbid.flowproxy.global.proxy_server_ip_addr"]');
                            if (input && !input.value) {
                                input.value = suggestedIp;
                                // 触发 change 事件以确保 uci 状态同步
                                input.dispatchEvent(new CustomEvent('change', { bubbles: true }));
                            }
                        }
                    }
                }
            }
        }, this));
    }
});