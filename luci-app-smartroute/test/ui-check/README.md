# 界面检查

原型（`docs/prototype/index.html`）与 LuCI 界面的检查脚本，在开发机的 `~/shot/venv`（playwright 1.47.0）里运行。

| 脚本 | 作用 | 用法 |
| --- | --- | --- |
| `smoke.js` | jsdom 冒烟测试：逐页渲染、执行主要操作，报告脚本错误 | `npm i jsdom@24.1.3 && node smoke.js <jsdom 所在目录> ../../docs/prototype/index.html` |
| `widthcheck.py` | Chromium 检查各页面在桌面/手机、深色/浅色下是否出现横向滚动 | `pip install playwright==1.47.0 && playwright install chromium && python widthcheck.py $PWD/../../docs/prototype/index.html` |
| `shot.py` | 各页面截图（桌面 1440 / 手机 400，深色 / 浅色） | `python shot.py <index.html 绝对路径> <输出前缀> devices flows ...` |
| `luci.py` | LuCI：登录后逐页打开智能分流各标签，报告脚本错误与横向溢出并截图 | `python luci.py <LuCI 地址> <root 密码> <截图前缀> [zh-CN\|en-US]` |
| `e2e.py` | LuCI 端到端：从空配置开始全部通过界面建出测试配置并保存应用，之后用 `test/pve/check.sh` 验证 | `python e2e.py <LuCI 地址> <root 密码> <截图前缀>`（浏览器语言为 zh-CN，需要已装中文语言包） |
