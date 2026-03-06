'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';
'require fs';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

var callArgoStatus = rpc.declare({
    object: 'luci.argo',
    method: 'get_status',
    expect: { '': {} }
});

var callArgoInstall = rpc.declare({
    object: 'luci.argo',
    method: 'install',
    expect: { '': {} }
});

var callArgoArch = rpc.declare({
    object: 'luci.argo',
    method: 'get_arch',
    expect: { '': {} }
});

function getServiceStatus() {
    return L.resolveDefault(callServiceList('argo'), {}).then(function (res) {
        var isRunning = false;
        try {
            isRunning = res['argo']['instances']['argo']['running'];
        } catch (e) { }
        return isRunning;
    });
}

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('argo'),
            L.resolveDefault(callArgoStatus(), {}),
            L.resolveDefault(callArgoArch(), {})
        ]);
    },

    render: function (data) {
        var m, s, o;
        var status = data[1] || {};
        var archInfo = data[2] || {};
        var isInstalled = status.installed === true;
        var isRunning = status.running === true;
        var version = status.version || _('未安装');
        var tokenConfigured = status.token_configured === true;
        var arch = archInfo.arch || 'unknown';
        var archSupported = archInfo.supported === true;

        m = new form.Map('argo', _('Argo 隧道'),
            _('Cloudflare Tunnel (Argo) 管理界面。使用 Cloudflare 远程管理隧道方式，需要先在 Cloudflare Zero Trust 面板创建隧道获取 Token。'));

        // 状态信息区域
        s = m.section(form.TypedSection, 'argo', _('服务状态'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.DummyValue, '_status', _('运行状态'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            var color = isRunning ? 'green' : 'red';
            var text = isRunning ? _('运行中') : _('未运行');
            return '<span style="color:' + color + '; font-weight: bold;">● ' + text + '</span>';
        };

        o = s.option(form.DummyValue, '_installed', _('安装状态'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            var color = isInstalled ? 'green' : 'orange';
            var text = isInstalled ? _('已安装') : _('未安装');
            return '<span style="color:' + color + '; font-weight: bold;">● ' + text + '</span>';
        };

        o = s.option(form.DummyValue, '_version', _('程序版本'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            return '<code style="background: #f0f0f0; padding: 2px 8px; border-radius: 4px;">' + version + '</code>';
        };

        o = s.option(form.DummyValue, '_arch', _('系统架构'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            var color = archSupported ? 'green' : 'red';
            var status = archSupported ? '✓ 支持' : '✗ 不支持';
            return '<code style="background: #f0f0f0; padding: 2px 8px; border-radius: 4px;">' + arch + '</code> ' +
                '<span style="color:' + color + ';">' + status + '</span>';
        };

        o = s.option(form.DummyValue, '_token_status', _('Token 状态'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            var color = tokenConfigured ? 'green' : 'orange';
            var text = tokenConfigured ? _('已配置') : _('未配置');
            return '<span style="color:' + color + '; font-weight: bold;">● ' + text + '</span>';
        };

        // 安装管理区域
        s = m.section(form.TypedSection, 'argo', _('安装管理'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Button, '_install', _('安装 Cloudflared'));
        o.inputtitle = isInstalled ? _('重新安装') : _('安装');
        o.inputstyle = isInstalled ? 'apply' : 'positive';
        o.onclick = function () {
            if (!archSupported) {
                ui.addNotification(null, E('p', _('当前架构不支持，无法安装。')), 'error');
                return;
            }

            ui.showModal(_('安装 Cloudflared'), [
                E('p', { 'class': 'spinning' }, _('正在下载并安装 cloudflared，请稍候...')),
                E('p', {}, _('这可能需要几分钟时间，取决于网络速度。'))
            ]);

            return L.resolveDefault(callArgoInstall(), {}).then(function (res) {
                ui.hideModal();
                if (res.success) {
                    ui.addNotification(null, E('p', _('安装完成！请刷新页面查看状态。')), 'info');
                    window.location.reload();
                } else {
                    ui.addNotification(null, E('p', _('安装失败：') + (res.message || '未知错误')), 'error');
                }
            }).catch(function (err) {
                ui.hideModal();
                ui.addNotification(null, E('p', _('安装失败：') + err.message), 'error');
            });
        };

        // 基本设置
        s = m.section(form.TypedSection, 'argo', _('基本设置'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Flag, 'enabled', _('启用服务'));
        o.rmempty = false;
        o.default = '0';
        o.description = _('启用后，Argo 将在保存配置时自动启动，并设置为开机自启。');

        o = s.option(form.Value, 'token', _('Tunnel Token'),
            _('在 Cloudflare Zero Trust 面板创建隧道后获取的 Token。这是一个以 eyJ 开头的 Base64 编码长字符串。'));
        o.password = true;
        o.rmempty = true;
        o.placeholder = 'eyJhIjoixxxxxxxxxxxxxxxxxxxxxxxx...';
        o.validate = function (section_id, value) {
            if (value && value.length > 0 && !value.startsWith('eyJ')) {
                return _('Token 格式可能不正确。正确的 Token 通常以 "eyJ" 开头。');
            }
            return true;
        };

        // Token 获取指南
        s = m.section(form.TypedSection, 'argo', _('Token 获取指南'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.DummyValue, '_guide');
        o.rawhtml = true;
        o.cfgvalue = function () {
            return '<div style="padding: 15px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); border-radius: 10px; color: white; box-shadow: 0 4px 15px rgba(102, 126, 234, 0.4);">' +
                '<h4 style="margin: 0 0 15px 0; font-size: 16px;">📋 如何获取 Cloudflare Tunnel Token</h4>' +
                '<ol style="margin: 0; padding-left: 20px; line-height: 2;">' +
                '<li>打开 <a href="https://one.dash.cloudflare.com/" target="_blank" style="color: #ffd700; text-decoration: underline;">Cloudflare Zero Trust 面板</a></li>' +
                '<li>使用您的 Cloudflare 账户登录</li>' +
                '<li>在左侧菜单中点击 <b>Networks</b> → <b>Tunnels</b></li>' +
                '<li>点击 <b style="color: #90EE90;">Create a tunnel</b> 按钮</li>' +
                '<li>选择 <b>Cloudflared</b> 作为连接器类型</li>' +
                '<li>为隧道命名 (例如: openwrt-tunnel)</li>' +
                '<li>在安装页面找到命令: <code style="background: rgba(255,255,255,0.2); padding: 2px 6px; border-radius: 3px;">cloudflared tunnel run --token eyJhIjoi...</code></li>' +
                '<li>复制 <b>--token</b> 后面的长字符串</li>' +
                '<li>将 Token 粘贴到上方配置中，保存并应用</li>' +
                '</ol>' +
                '</div>';
        };

        // 日志查看
        s = m.section(form.TypedSection, 'argo', _('运行日志'));
        s.anonymous = true;
        s.addremove = false;

        o = s.option(form.Button, '_viewlogs', _('查看日志'));
        o.inputtitle = _('刷新日志');
        o.inputstyle = 'action';
        o.onclick = function () {
            return fs.exec('/usr/bin/logread', ['-e', 'argo']).then(function (res) {
                var log = (res.stdout || '').trim();
                if (!log) {
                    log = _('暂无 Argo 相关日志。\n\n提示：如果服务刚启动，请稍等片刻后再刷新。');
                }
                var lines = log.split('\n').slice(-100).join('\n');

                ui.showModal(_('Argo 运行日志'), [
                    E('pre', {
                        'style': 'white-space: pre-wrap; word-wrap: break-word; max-height: 500px; overflow-y: auto; padding: 15px; background: linear-gradient(180deg, #1a1a2e 0%, #16213e 100%); color: #0f0; font-family: "Consolas", "Monaco", monospace; font-size: 12px; border-radius: 8px; border: 1px solid #0f0;'
                    }, [lines]),
                    E('div', { 'class': 'right', 'style': 'margin-top: 15px;' }, [
                        E('button', {
                            'class': 'btn',
                            'click': ui.hideModal,
                            'style': 'background: #667eea; color: white; border: none; padding: 8px 20px; border-radius: 5px; cursor: pointer;'
                        }, _('关闭'))
                    ])
                ]);
            }).catch(function (err) {
                ui.addNotification(null, E('p', _('读取日志失败：') + err.message), 'error');
            });
        };

        return m.render();
    }
});
