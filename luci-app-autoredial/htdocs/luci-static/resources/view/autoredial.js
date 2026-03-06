'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

return view.extend({
    load: function() {
        return Promise.all([
            uci.load('autoredial'),
            fs.list('/etc/init.d').then(function(res) {
                return res.map(x => x.name);
            })
        ]);
    },

    render: function(data) {
        var m, s, o;

        m = new form.Map('autoredial', _('自动重拨'),
            _('通过 Ping 或 URL 监测网络连通性，如果断网自动重拨指定接口。'));

        s = m.section(form.TypedSection, 'config', _('设置'));
        s.anonymous = true;
        s.addremove = false;

        // 启用开关
        o = s.option(form.Flag, 'enabled', _('启用'));
        o.rmempty = false;

        // 检测模式
        o = s.option(form.ListValue, 'method', _('检测模式'));
        o.value('ping', 'Ping (ICMP)');
        o.value('url', 'URL (HTTP/HTTPS)');
        o.default = 'ping';

        // 目标地址
        o = s.option(form.Value, 'target', _('检测目标'));
        o.datatype = 'host';
        o.description = _('Ping模式填写IP (如 8.8.8.8)；URL模式填写完整网址。');
        o.depends({'method': 'ping', 'contains': ''}); // 这里简化处理，实际JS中需动态显示
        o.default = '8.8.8.8';

        // 网络接口
        o = s.option(form.Value, 'interface', _('重拨接口'));
        o.description = _('指定要重启的网络接口名称 (如 wan, wan6)，通常对应/etc/config/network中的wan。');
        o.default = 'wan';
        
        // 检测间隔
        o = s.option(form.Value, 'interval', _('检测间隔 (秒)'));
        o.datatype = 'uinteger';
        o.default = '30';

        // 失败次数
        o = s.option(form.Value, 'count', _('失败次数阈值'));
        o.description = _('连续失败多少次后触发重拨。');
        o.datatype = 'uinteger';
        o.default = '3';

        return m.render();
    }
});