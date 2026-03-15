'use strict';
'require form';
'require uci';
'require view';
'require fs';
'require ui';

return L.view.extend({
    load: function() {
        return uci.load('flowproxy');
    },

    render: function() {
        var m, s, o;

        m = new form.Map('flowproxy', _('flowproxy - lists'),
            _('manage nftables set collections. use the global "save & apply" button at the bottom to take effect.'));

        // --- 1. 预设名单区域 ---
        var predefined = [
            { id: 'no_proxy_src_mac', name: _('no_proxy_src_mac'), type: 'macaddr', placeholder: 'aa:bb:cc:dd:ee:ff' },
            { id: 'no_proxy_src_ip_v4', name: _('no_proxy_src_ip_v4'), type: 'or(ip4addr, cidr4)', placeholder: '192.168.1.100' },
            { id: 'no_proxy_dst_ip_v4', name: _('no_proxy_dst_ip_v4'), type: 'or(ip4addr, cidr4)', placeholder: '8.8.8.8' },
            { id: 'no_proxy_dst_tcp_ports', name: _('no_proxy_dst_tcp_ports'), type: 'or(port, portrange)', placeholder: '80, 443' },
            { id: 'no_proxy_dst_udp_ports', name: _('no_proxy_dst_udp_ports'), type: 'or(port, portrange)', placeholder: '53, 123' }
        ];

        predefined.forEach(L.bind(function(p) {
            // 修复：使用纯文本拼接，确保在所有 LuCI 版本下都能正常显示标题
            var fullTitle = p.name + ' (@' + p.id + ')';
            
            s = m.section(form.NamedSection, p.id, 'nftset', fullTitle);
            o = s.option(form.Flag, 'enabled', _('enabled'));
            o.rmempty = false; o.default = '1';
            o = s.option(form.DynamicList, 'elements', _('elements'));
            o.datatype = p.type; o.placeholder = p.placeholder;
        }, this));

        // 特殊预设：私有地址
        s = m.section(form.NamedSection, 'private_dst_ip_v4', 'nftset', _('private_dst_ip_v4') + ' (@private_dst_ip_v4)');
        o = s.option(form.Flag, 'enabled', _('enabled'));
        o.rmempty = false; o.default = '1';
        o = s.option(form.Flag, 'auto_generate', _('auto_generate'));
        o.default = '1';
        o = s.option(form.DynamicList, 'elements', _('elements'));
        o.datatype = 'cidr4'; o.depends('auto_generate', '0');

        // 特殊预设：中国路由
        s = m.section(form.NamedSection, 'chnroute_dst_ip_v4', 'nftset', _('chnroute_dst_ip_v4') + ' (@chnroute_dst_ip_v4)');
        o = s.option(form.Flag, 'enabled', _('enabled'));
        o.rmempty = false; o.default = '1';
        o = s.option(form.Value, 'file_path', _('file_path'));
        o.default = '/usr/share/flowproxy/chnroute.txt';
        o.render = function(section_id, option_index, backup) {
            return form.Value.prototype.render.apply(this, [section_id, option_index, backup]).then(L.bind(function(node) {
                var path = uci.get('flowproxy', section_id, 'file_path') || this.default;
                var statusNode = E('span', { 
                    'style': 'margin-left: 10px; vertical-align: middle; font-weight: bold; color: #444;',
                    'id': 'line_count_status' 
                }, '...');
                var input = node.querySelector('input');
                if (input) input.parentNode.appendChild(statusNode);

                fs.exec('/usr/bin/wc', ['-l', path]).then(function(res) {
                    statusNode.innerText = (res.code === 0) ? '(' + res.stdout.trim().split(' ')[0] + ' ' + _('lines') + ')' : '(' + _('n/a') + ')';
                });
                return node;
            }, this));
        };

        o = s.option(form.Value, 'download_url', _('download_url'));
        o.placeholder = 'https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt';

        o = s.option(form.Button, '_download', _('update chnroute'));
        o.inputstyle = 'apply';
        o.onclick = L.bind(function(ev, section_id) {
            ev.preventDefault();

            // 获取当前 UI 中的值，即使尚未点击 "Save & Apply"
            var url_opt = s.children.filter(function(o) { return o.option === 'download_url' })[0];
            var url = url_opt ? url_opt.formvalue(section_id) : null;
            if (!url) url = uci.get('flowproxy', section_id, 'download_url');

            var path_opt = s.children.filter(function(o) { return o.option === 'file_path' })[0];
            var path = path_opt ? path_opt.formvalue(section_id) : null;
            if (!path) path = uci.get('flowproxy', section_id, 'file_path') || '/usr/share/flowproxy/chnroute.txt';

            if (!url) {
                ui.addNotification(null, E('p', _('Please set download_url first')), 'error');
                return;
            }
            ui.showModal(null, [
                E('p', { 'id': 'download_status', 'class': 'spinning' }, _('Downloading chnroute data...'))
            ]);
            return fs.exec('/usr/bin/wget', ['-q', '-O', path, url, '--timeout=10', '--no-check-certificate']).then(function(res) {
                var statusEl = document.getElementById('download_status');
                if (res.code === 0) {
                    if (statusEl) {
                        statusEl.classList.remove('spinning');
                        statusEl.innerText = _('Chnroute data updated successfully.');
                    }
                    
                    // 实时更新行数显示
                    var countNode = document.getElementById('line_count_status');
                    if (countNode) {
                        countNode.innerText = '...';
                        fs.exec('/usr/bin/wc', ['-l', path]).then(function(res) {
                            countNode.innerText = (res.code === 0) ? '(' + res.stdout.trim().split(' ')[0] + ' ' + _('lines') + ')' : '(' + _('n/a') + ')';
                        });
                    }

                    // 1.5秒后自动关闭弹窗
                    setTimeout(function() { ui.hideModal(); }, 1500);
                } else {
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Download failed')), 'error');
                }
            }).catch(function(e) {
                ui.hideModal();
                ui.addNotification(null, E('p', _('Error: ') + e.message), 'error');
            });
        }, this);

        // --- 2. 自定义名单区域 ---
        s = m.section(form.GridSection, 'nftset', _('custom nftables sets'));
        s.addremove = true;
        s.anonymous = false;
        s.nodescription = true;
        s.filter = function(section_id) {
            var pre_ids = predefined.map(function(p) { return p.id; });
            pre_ids.push('private_dst_ip_v4', 'chnroute_dst_ip_v4');
            return (pre_ids.indexOf(section_id) === -1);
        };

        o = s.option(form.Flag, 'enabled', _('enabled'));
        o.rmempty = false; o.default = '1';

        o = s.option(form.ListValue, 'type', _('element type'));
        o.value('ipv4_addr', 'IPv4 Address/CIDR');
        o.value('ether_addr', 'MAC Address');
        o.value('inet_service', 'Port/Service');
        o.default = 'ipv4_addr';

        o = s.option(form.DynamicList, 'elements', _('elements'));

        return m.render();
    }
});