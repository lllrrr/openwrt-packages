'use strict';
'require view';
'require dom';
'require rpc';
'require ui';

// 恢复为只传 mode, arg1, arg2 两个参数
var callNetSetup = rpc.declare({
    object: 'netwiz',
    method: 'set_network',
    params: ['mode', 'arg1', 'arg2'],
    expect: { result: 0 }
});

return view.extend({
    render: function () {
        var container = dom.create('div', { class: 'cbi-map', id: 'netwiz-container' });

        var htmlTemplate = [
            '<style>',
            '.nw-wrapper { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 55vh; padding-bottom: 10vh; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }',
            '.nw-header { text-align: center; margin-bottom: 40px; background-color: #5e72e4; padding: 25px; margin-top: -35px; border-bottom-left-radius: 15px; border-bottom-right-radius: 15px;}',
            '.nw-main-title { font-size: 45px; font-weight: 600; margin-bottom: 10px; color: #ffffff; letter-spacing: 1px; }',
            '.nw-header p { color: #ffffff; font-size: 18px; }',
            '.nw-step { width: 100%; max-width: 750px; text-align: center; animation: slideUp 0.4s ease-out; }',
            '@keyframes slideUp { from { opacity: 0; transform: translateY(15px); } to { opacity: 1; transform: translateY(0); } }',
            '.nw-card-group { display: flex; gap: 40px; justify-content: center; flex-wrap: wrap; margin-top: 20px; }',

            '.nw-card { width: 210px; padding: 40px 20px; border-radius: 16px; cursor: pointer; backdrop-filter: blur(12px); border: 1px solid rgba(0, 0, 0, 0.03); box-shadow: 0px 0px 15px 2px #b7b7b7; transition: all 0.25s ease; display: flex; flex-direction: column; align-items: center; box-sizing: border-box; }',
            '.nw-card[data-mode="dhcp"] { background: rgba(79, 150, 101, 0.85); }',
            '.nw-card[data-mode="dhcp"]:hover { transform: translateY(-5px);  box-shadow: 0 12px 30px rgba(0, 153, 255, 0.15); border-color: rgba(0, 153, 255, 0.3); }',
            '.nw-card[data-mode="pppoe"] { background: rgba(80, 0, 183, 0.85); }',
            '.nw-card[data-mode="pppoe"]:hover { transform: translateY(-5px); box-shadow: 0 12px 30px rgba(153, 102, 255, 0.15); border-color: rgba(153, 102, 255, 0.3); }',
            '.nw-card[data-mode="bypass"] { background: rgba(253, 0, 115, 0.85); }',
            '.nw-card[data-mode="bypass"]:hover { transform: translateY(-5px); box-shadow: 0 12px 30px rgba(0, 204, 153, 0.15); border-color: rgba(0, 204, 153, 0.3); }',

            '.nw-badge { width: 54px; height: 54px; line-height: 54px; border-radius: 50%; font-size: 20px; font-weight: bold; margin-bottom: 20px; box-shadow: 0 4px 10px rgba(0,0,0,0.05); }',
            '.nw-badge-dhcp { background: #e0f2fe; color: #0284c7; }',
            '.nw-badge-pppoe { background: #f3e8ff; color: #9333ea; }',
            '.nw-badge-bypass { background: #d1fae5; color: #059669; }',
            '.nw-card-title { font-size: 20px; margin: 0 0 10px 0; color: #ffffff; font-weight: 600; }',
            '.nw-card span { font-size: 16px; color: #ffffff; line-height: 1.5; }',

            '.nw-form-area, .nw-confirm-board { max-width: 460px; margin: 0 auto; text-align: left; padding: 40px; border-radius: 16px; background-color: rgba(255, 255, 255, 0.88); backdrop-filter: blur(15px); box-shadow: 0 10px 30px rgba(0,0,0,0.06); border: 1px solid rgba(0, 0, 0, 0.04); }',
            '.nw-step-title { text-align: center; margin-bottom: 30px; color: #111; font-weight: 600; font-size: 20px; background: transparent !important; padding: 0 !important; }',
            '.nw-form-area .cbi-value { border: none; padding: 12px 0; display: flex; flex-direction: column; align-items: flex-start; width: 100%; background: transparent; }',
            '.nw-form-area .cbi-value-title { text-align: left; font-weight: 600; color: #222; font-size: 16px; margin-bottom: 10px; letter-spacing: 0.5px; }',
            '.nw-form-area .cbi-value-field { width: 100%; }',
            '.nw-form-area input[type="text"], .nw-form-area input[type="password"] { width: 100%; box-sizing: border-box; padding: 12px 16px; border: 1px solid #d1d5db; border-radius: 8px; font-size: 15px; outline: none; transition: all 0.25s ease; background: #f9fafb; color: #333; }',
            '.nw-form-area input[type="text"]:focus, .nw-form-area input[type="password"]:focus { border-color: #3b82f6; background: #fff; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15); }',
            
            '.nw-confirm-board p { font-size: 15px; line-height: 1.6; color: #444; }',
            '.nw-highlight { color: #fff; font-weight: bold; font-size: 18px; margin: 20px 0; text-align: center; background: #3b82f6; padding: 12px; border-radius: 10px; border: none; }',

            '.nw-actions { margin-top: 35px; display: flex; justify-content: center; gap: 15px; }',
            '.nw-actions .cbi-button { border-radius: 8px; padding: 10px 24px; font-weight: 500; font-size: 15px; cursor: pointer; transition: all 0.2s; }',
            '.nw-actions .cbi-button-apply { background: #10b981; border: none; color: white; }',
            '.nw-actions .cbi-button-apply:hover { background: #059669; transform: translateY(-2px); }',
            '.nw-actions .cbi-button-reset { background: #f5365c; color: #ffffff; border: 1px solid #e5e7eb; }',
            '.nw-actions .cbi-button-reset:hover { background: #e5e7eb; color: #000000;}',

            /* 强制置顶不可穿透安全弹窗 */
            '.nw-strict-modal { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.65); z-index: 999999; display: flex; align-items: center; justify-content: center; backdrop-filter: blur(6px); flex-direction: column; }',
            '.nw-modal-box { background: #fff; padding: 40px; border-radius: 16px; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.3); max-width: 420px; width: 90%; animation: slideUp 0.3s ease-out; }',
            '.nw-modal-box h3 { margin-top: 0; font-size: 24px; color: #222; margin-bottom: 15px; border:none; padding:0; background:transparent;}',
            '.nw-modal-box p { font-size: 16px; color: #555; line-height: 1.6; }',
            '.nw-spinner { width: 50px; height: 50px; border: 4px solid #f3f3f3; border-top: 4px solid #3b82f6; border-radius: 50%; animation: spin 1s linear infinite; margin: 0 auto 25px; }',
            '.nw-modal-btn-ok { background: #3b82f6; color: white; border: none; padding: 12px 30px; border-radius: 8px; font-size: 16px; cursor: pointer; margin-top: 25px; width: 100%; transition: background 0.2s; }',
            '.nw-modal-btn-ok:hover { background: #2563eb; }',
            '@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }',
            '</style>',

            '<div class="nw-wrapper">',
            '  <div class="nw-header">',
            '    <div class="nw-main-title">网 络 设 置 向 导</div>',
            '    <p>纯净 · 安全 · 零破坏 —— 精准修改底层配置</p>',
            '  </div>',
            '  <div id="step-1" class="nw-step">',
            '    <div class="nw-card-group">',
            '      <div class="nw-card" data-mode="dhcp"><div class="nw-badge nw-badge-dhcp">IP</div><div class="nw-card-title">动态 IP (DHCP)</div><span>适用于光猫已经拨号，路由器作为二级路由接入的场景。</span></div>',
            '      <div class="nw-card" data-mode="pppoe"><div class="nw-badge nw-badge-pppoe">拨号</div><div class="nw-card-title">宽带拨号 (PPPoE)</div><span>适用于光猫为桥接模式，由本路由器直接进行拨号上网。</span></div>',
            '      <div class="nw-card" data-mode="bypass"><div class="nw-badge nw-badge-bypass">旁路</div><div class="nw-card-title">旁路由模式</div><span>将本设备作为局域网内的辅助网关，不改变现有网络拓扑。</span></div>',
            '    </div>',
            '  </div>',
            '  <div id="step-2" class="nw-step" style="display: none;">',
            '    <div class="nw-form-area">',
            '      <div id="fields-pppoe" style="display: none;">',
            '        <div class="nw-step-title">请输入宽带账号信息</div>',
            '        <div class="cbi-value"><label class="cbi-value-title">宽带账号</label><div class="cbi-value-field"><input type="text" id="pppoe-user" class="cbi-input-text" placeholder="请输入运营商提供的账号"></div></div>',
            '        <div class="cbi-value"><label class="cbi-value-title">宽带密码</label><div class="cbi-value-field"><input type="password" id="pppoe-pass" class="cbi-input-password" placeholder="请输入密码"></div></div>',
            '      </div>',
            '      <div id="fields-bypass" style="display: none;">',
            '        <div class="nw-step-title">配置局域网参数</div>',
            '        <div class="cbi-value"><label class="cbi-value-title">本级静态 IP</label><div class="cbi-value-field"><input type="text" id="bypass-ip" class="cbi-input-text" placeholder="例: 192.168.1.2"></div></div>',
            '        <div class="cbi-value"><label class="cbi-value-title">主路由网关</label><div class="cbi-value-field"><input type="text" id="bypass-gw" class="cbi-input-text" placeholder="例: 192.168.1.1"></div></div>',
            '      </div>',
            '    </div>',
            '    <div class="nw-actions"><button id="btn-back-1" class="cbi-button cbi-button-reset">返回重选</button><button id="btn-next-2" class="cbi-button cbi-button-action">下一步</button></div>',
            '  </div>',
            '  <div id="step-3" class="nw-step" style="display: none;">',
            '    <div class="nw-confirm-board">',
            '      <div class="nw-step-title">配置确认</div>',
            '      <p>即将把联网模式切换为：</p>',
            '      <div id="confirm-mode-text" class="nw-highlight">未知模式</div>',
            '      <p style="color:#666; font-size: 13px; margin-top: 15px; border-top: 1px solid #eaeaea; padding-top: 15px;">安全提示： 保存后仅覆盖接口协议，物理网卡绑定配置将被完全保留。网络会短暂重启。</p>',
            '    </div>',
            '    <div class="nw-actions"><button id="btn-back-2" class="cbi-button cbi-button-reset">返回修改</button><button id="btn-apply" class="cbi-button cbi-button-apply">确认并写入</button></div>',
            '  </div>',
            '</div>'
        ].join('');

        container.innerHTML = htmlTemplate;
        this.bindEvents(container);
        return container;
    },

    bindEvents: function (container) {
        var step1 = container.querySelector('#step-1');
        var step2 = container.querySelector('#step-2');
        var step3 = container.querySelector('#step-3');
        var confirmText = container.querySelector('#confirm-mode-text');
        var selectedMode = '';

        /* 强制置顶不可点击外部的安全弹窗 */
        function showStrictModal(title, msg, isSuccessOrError) {
            var m = document.getElementById('nw-strict-modal');
            if(!m) {
                m = document.createElement('div');
                m.id = 'nw-strict-modal';
                m.className = 'nw-strict-modal';
                m.innerHTML = '<div class="nw-modal-box"><div id="nw-modal-spinner" class="nw-spinner"></div><h3 id="nw-modal-title"></h3><p id="nw-modal-msg"></p><button id="nw-modal-btn" class="nw-modal-btn-ok" style="display:none;">好的，我知道了</button></div>';
                document.body.appendChild(m);
            }
            document.getElementById('nw-modal-title').innerText = title;
            document.getElementById('nw-modal-msg').innerText = msg;
            
            var spinner = document.getElementById('nw-modal-spinner');
            var btn = document.getElementById('nw-modal-btn');
            
            if(isSuccessOrError) {
                spinner.style.display = 'none';
                btn.style.display = 'block';
                btn.onclick = function() {
                    m.style.display = 'none';
                    // 点击后强制重置到第一页初始状态
                    step3.style.display = 'none';
                    step2.style.display = 'none';
                    step1.style.display = 'block';
                };
            } else {
                spinner.style.display = 'block';
                btn.style.display = 'none';
            }
            m.style.display = 'flex';
        }

        var cards = container.querySelectorAll('.nw-card');
        cards.forEach(function (card) {
            card.addEventListener('click', function () {
                selectedMode = this.getAttribute('data-mode');
                step1.style.display = 'none';
                if (selectedMode === 'dhcp') {
                    confirmText.innerText = "动态获取 (DHCP)";
                    step3.style.display = 'block';
                } else {
                    container.querySelector('#fields-pppoe').style.display = (selectedMode === 'pppoe') ? 'block' : 'none';
                    container.querySelector('#fields-bypass').style.display = (selectedMode === 'bypass') ? 'block' : 'none';
                    step2.style.display = 'block';
                }
            });
        });

        container.querySelector('#btn-back-1').addEventListener('click', function () {
            step2.style.display = 'none'; step1.style.display = 'block';
        });

        container.querySelector('#btn-next-2').addEventListener('click', function () {
            if (selectedMode === 'pppoe') confirmText.innerText = "宽带拨号 (PPPoE)";
            if (selectedMode === 'bypass') confirmText.innerText = "旁路由接入";
            step2.style.display = 'none'; step3.style.display = 'block';
        });

        container.querySelector('#btn-back-2').addEventListener('click', function () {
            step3.style.display = 'none';
            if (selectedMode === 'dhcp') step1.style.display = 'block';
            else step2.style.display = 'block';
        });

        container.querySelector('#btn-apply').addEventListener('click', function () {
            var arg1 = '', arg2 = '';
            
            if (selectedMode === 'pppoe') {
                arg1 = container.querySelector('#pppoe-user').value;
                arg2 = container.querySelector('#pppoe-pass').value;
                if (!arg1 || !arg2) { alert('账号密码不能为空'); return; }
            } else if (selectedMode === 'bypass') {
                arg1 = container.querySelector('#bypass-ip').value;
                arg2 = container.querySelector('#bypass-gw').value;
                if (!arg1 || !arg2) { alert('IP和网关不能为空'); return; }
            }

            showStrictModal('配置下发中', '底层配置写入中，请勿断电...', false);

            // 前端不传掩码，完全由后端通过 IP 计算
            callNetSetup(selectedMode, arg1, arg2).then(function () {
                showStrictModal('✅ 配置成功', '配置已写入完成。如果您修改了 IP 地址，请在浏览器中输入新的 IP 进行访问。', true);
            }).catch(function (e) {
                var errMsg = e.message || "";
                // 智能识别：网卡重启导致的请求超时，视为配置成功
                if (errMsg.indexOf('timeout') !== -1 || errMsg.indexOf('XHR') !== -1) {
                    showStrictModal('🎉 写入已生效', '请求超时是正常现象（路由器网络服务已重启）。\n如果打不开当前页面，说明新 IP 已生效，请手动输入新 IP 访问。', true);
                } else {
                    showStrictModal('❌ 配置出错', '错误详情: ' + errMsg, true);
                }
            });
        });
    }
});
