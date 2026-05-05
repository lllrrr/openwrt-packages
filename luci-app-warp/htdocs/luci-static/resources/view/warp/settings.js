'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('warp'),
            L.resolveDefault(fs.exec('/bin/netstat', ['-tln']), { stdout: '' }),
            L.resolveDefault(fs.stat('/etc/warp/reg.json'), null)
        ]);
    },

    render: function (data) {
        var netstatOutput = data[1].stdout || '';
        var accountExists = data[2] !== null;
        var socksPort = uci.get('warp', 'config', 'socks_port') || '1080';
        var httpPort = uci.get('warp', 'config', 'http_port') || '8118';

        var m, s, o;

        m = new form.Map('warp', _('Cloudflare WARP'),
            _('Cloudflare WARP 是一个免费的VPN服务，可以加密您的网络流量并提供更快、更安全的互联网访问。'));

        // 状态区域
        s = m.section(form.NamedSection, 'config', 'warp', _('运行状态'));
        s.anonymous = true;

        o = s.option(form.DummyValue, '_status', _('服务状态'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            var isRunning = netstatOutput.indexOf(':' + socksPort + ' ') !== -1 || netstatOutput.indexOf(':' + httpPort + ' ') !== -1;

            var status = '<span style="color: ' + (isRunning ? '#28a745' : '#dc3545') + '; font-weight: bold;">';
            status += isRunning ? '✓ 运行中' : '✗ 已停止';
            status += '</span>';

            return status;
        };

        o = s.option(form.DummyValue, '_account', _('账户状态'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            return accountExists
                ? '<span style="color: #28a745; font-weight: bold;">✓ 已注册</span>'
                : '<span style="color: #ffc107; font-weight: bold;">⚠ 未注册</span>';
        };

        // 基本设置
        s = m.section(form.NamedSection, 'config', 'warp', _('基本设置'));
        s.anonymous = true;

        o = s.option(form.Flag, 'enabled', _('启用'));
        o.rmempty = false;
        o.default = '0';

        o = s.option(form.Value, 'endpoint', _('服务器地址'));
        o.placeholder = '162.159.193.1:2408';
        o.rmempty = true;
        o.description = _('自定义 WARP 服务器端点地址和端口 (例如: engage.cloudflareclient.com:2408)。如果留空，将使用默认端点。');

        // 代理设置
        s = m.section(form.NamedSection, 'config', 'warp', _('代理设置'));
        s.anonymous = true;

        o = s.option(form.Flag, 'global_proxy', _('全局代理'));
        o.default = '0';
        o.description = _('启用后，通过 nftables TPROXY 透明代理将所有局域网流量转发到 WARP。与 OpenClash 等透明代理共存时必须关闭。');

        o = s.option(form.Flag, 'bypass_china', _('绕过中国大陆IP'));
        o.default = '0';
        o.description = _('仅在全局代理开启时有效。启用后，访问中国大陆IP将直连不走 WARP。');
        o.depends('global_proxy', '1');

        // SOCKS5 代理
        s = m.section(form.NamedSection, 'config', 'warp', _('SOCKS5 代理'));
        s.anonymous = true;

        o = s.option(form.Flag, 'socks_enabled', _('启用 SOCKS5 代理'));
        o.default = '1';
        o.description = _('在本地开启 SOCKS5 代理端口。注意：全局代理功能依赖 SOCKS5 代理。');

        o = s.option(form.Value, 'socks_port', _('SOCKS5 端口'));
        o.datatype = 'port';
        o.default = '1080';
        o.depends('socks_enabled', '1');

        // HTTP 代理
        s = m.section(form.NamedSection, 'config', 'warp', _('HTTP 代理'));
        s.anonymous = true;

        o = s.option(form.Flag, 'http_enabled', _('启用 HTTP 代理'));
        o.default = '0';
        o.description = _('在本地开启 HTTP 代理端口。');

        o = s.option(form.Value, 'http_port', _('HTTP 端口'));
        o.datatype = 'port';
        o.default = '8118';
        o.depends('http_enabled', '1');

        // 账户信息
        s = m.section(form.NamedSection, 'config', 'warp', _('账户信息'));
        s.anonymous = true;

        o = s.option(form.Value, 'license_key', _('WARP+ License Key'));
        o.password = true;
        o.rmempty = true;
        o.description = _('如果您有WARP+ License Key，可以在此输入并应用。保存本页面后，请前往“状态”页面点击“应用License Key”按钮（如果没有该按钮，可通过“启动/重启”触发配置更新，或在命令行运行 warp-manager license）。');

        return m.render();
    }
});
