'use strict';
'require form';
'require fs';
'require uci';

return L.view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(fs.read('/tmp/devicemaster_device_cache'), '{}'),
            uci.load('devicemaster')
        ]);
    },

    render: function(data) {
        var cacheContent = data[0] || '{}';
        var m, s, o;

        m = new form.Map('devicemaster');

        // ========== 设备分组 ==========
        s = m.section(form.TypedSection, 'group', _('设备分组'));
        s.anonymous = true;
        s.addremove = true;

        o = s.option(form.Value, 'name', _('分组名称'));
        o.rmempty = false;

        o = s.option(form.MultiValue, '_devices', _('设备'));
        o.modalonly = false;

        // Load devices from cache or UCI
        var devices = [];
        try {
            var parsed = JSON.parse(cacheContent);
            if (parsed && parsed.devices && Array.isArray(parsed.devices)) {
                devices = parsed.devices;
            }
        } catch (e) {}

        if (devices.length === 0) {
            var sections = uci.sections('devicemaster', 'device') || [];
            for (var i = 0; i < sections.length; i++) {
                var sec = sections[i];
                if (sec.mac) {
                    devices.push({
                        mac: sec.mac,
                        hostname: sec.hostname || sec.name || '',
                        last_ip: sec.last_ip || '',
                        is_controllable: sec.is_controllable !== '0'
                    });
                }
            }
        }

        // Populate device options
        devices.forEach(function(dev) {
            if (dev.is_controllable === false) return;
            var ip = dev.ip || dev.last_ip || '';
            if (!ip) return;
            var name = dev.custom_name || dev.hostname || dev.mac;
            o.value(dev.mac, name + ' (' + ip + ')');
        });

        o.cfgvalue = function(section_id) {
            var group_name = uci.get('devicemaster', section_id, 'name');
            if (!group_name) return [];
            var selected = [];
            var sections = uci.sections('devicemaster', 'device') || [];
            for (var i = 0; i < sections.length; i++) {
                var sec = sections[i];
                if (sec.group && sec.group === group_name && sec.mac) {
                    selected.push(sec.mac);
                }
            }
            return selected;
        };

        o.write = function(section_id, formvalue) {
            var group_name = uci.get('devicemaster', section_id, 'name');
            var sections = uci.sections('devicemaster', 'device') || [];
            for (var i = 0; i < sections.length; i++) {
                var sec = sections[i];
                if (sec.group === group_name) {
                    uci.unset('devicemaster', sec['.name'], 'group');
                }
            }

            if (formvalue && formvalue.length) {
                for (var j = 0; j < formvalue.length; j++) {
                    var mac = formvalue[j];
                    var sections2 = uci.sections('devicemaster', 'device') || [];
                    for (var k = 0; k < sections2.length; k++) {
                        var d = sections2[k];
                        if (d.mac && d.mac.toLowerCase() === mac.toLowerCase()) {
                            uci.set('devicemaster', d['.name'], 'group', group_name);
                        }
                    }
                }
            }
        };

        o.remove = function(section_id) {
            var group_name = uci.get('devicemaster', section_id, 'name');
            var sections = uci.sections('devicemaster', 'device') || [];
            for (var i = 0; i < sections.length; i++) {
                var sec = sections[i];
                if (sec.group === group_name) {
                    uci.unset('devicemaster', sec['.name'], 'group');
                }
            }
        };

        // ========== 定时规则 ==========
        s = m.section(form.TypedSection, 'schedule', _('定时规则'));
        s.anonymous = true;
        s.addremove = true;

        o = s.option(form.Value, 'name', _('规则名称'));
        o.rmempty = false;

        // 目标分组
        o = s.option(form.ListValue, 'group', _('目标分组'));
        o.value('all', _('全部设备'));
        var groupSections = uci.sections('devicemaster', 'group') || [];
        groupSections.forEach(function(g) {
            if (g.name) {
                o.value(g.name, g.name);
            }
        });
        o.default = 'all';

        // 操作类型
        o = s.option(form.ListValue, 'action', _('操作类型'));
        o.value('block', _('封禁网络'));
        o.value('limit', _('限速'));
        o.default = 'block';

        // 限速值
        o = s.option(form.ListValue, 'rate', _('限速值'));
        o.depends('action', 'limit');
        o.value('1mbit', '1 Mbps');
        o.value('2mbit', '2 Mbps');
        o.value('5mbit', '5 Mbps');
        o.value('10mbit', '10 Mbps');
        o.value('20mbit', '20 Mbps');
        o.value('50mbit', '50 Mbps');
        o.value('custom', _('自定义'));
        o.default = '1mbit';

        // 自定义限速值
        o = s.option(form.Value, 'custom_rate', _('自定义限速'));
        o.depends('rate', 'custom');
        o.placeholder = '例如: 5mbit, 10mbit';
        o.description = _('输入限速值，如 5mbit, 10mbit, 1gbit 等');

        // 开始时间
        o = s.option(form.Value, 'start_time', _('开始时间'));
        o.placeholder = 'HH:MM';
        o.default = '22:00';
        o.description = _('每天开始封禁/限速的时间');

        // 结束时间
        o = s.option(form.Value, 'end_time', _('结束时间'));
        o.placeholder = 'HH:MM';
        o.default = '08:00';
        o.description = _('每天自动解除封禁/限速的时间');

        // 生效日期
        o = s.option(form.MultiValue, 'days', _('生效日期'));
        o.value('0', _('周日'));
        o.value('1', _('周一'));
        o.value('2', _('周二'));
        o.value('3', _('周三'));
        o.value('4', _('周四'));
        o.value('5', _('周五'));
        o.value('6', _('周六'));
        o.modalonly = false;

        return m.render();
    }
});
