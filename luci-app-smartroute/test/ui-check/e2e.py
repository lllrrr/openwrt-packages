# 界面端到端：从空配置开始，全部通过 LuCI 界面建出 test/pve/sr.sh 的测试配置，再“保存并应用”
#   设备组 组A（client-a，MAC 规则）、组B（client-b，IP 规则，命名）；出口 网关 lab-side；规则组 国内（geoip:cn）、测试域名（domain:foreign.lab）
#   分流 1：组A × 国内 取反 → lab-side；分流 2：client-b × 测试域名 → lab-side；最后开启总开关
# 用法: python e2e.py <LuCI 地址> <root 密码> <截图前缀>；之后在管理机上跑 test/pve/check.sh 与 sr.sh dns 验证
import sys
from playwright.sync_api import sync_playwright

BASE, PW, OUT = sys.argv[1:4]
URL = BASE + "/cgi-bin/luci/admin/network/smartroute/"

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1440, "height": 900}, locale="zh-CN")  # 按中文界面文字定位，需要中文语言包
    errs = []
    step = 0
    pg.on("pageerror", lambda e: errs.append(f"[第 {step} 步 {pg.url.rsplit('/', 1)[-1]}] {str(e)[:200]}"))

    def go(tab):
        pg.goto(URL + tab)
        pg.wait_for_load_state("networkidle")
        pg.wait_for_timeout(500)

    def ok():  # 对话框的确定按钮
        global step
        pg.locator(".modal .right button").last.click()
        pg.wait_for_timeout(800)
        step += 1
        pg.screenshot(path=f"{OUT}-step{step}.png", full_page=True)

    def click(name):
        pg.get_by_role("button", name=name).first.click()
        pg.wait_for_timeout(300)

    pg.goto(URL + "overview")
    if pg.locator("input[name=luci_password]").count():
        pg.fill("input[name=luci_password]", PW)
        pg.press("input[name=luci_password]", "Enter")
        pg.wait_for_load_state("networkidle")

    go("devices")
    for name, line in (("组A", "02:5a:00:00:05:0a"), ("组B", "192.168.99.11 client-b")):
        click("新建设备组")
        pg.fill(".modal input[placeholder='例如：电视盒子']", name)
        ok()
        pg.locator(f".cbi-section:has(h3:has-text('{name}'))").get_by_role("button", name="添加设备").click()
        pg.wait_for_timeout(500)
        pg.fill(".modal textarea", line)
        ok()

    go("exits")
    click("添加出口")
    pg.fill(".modal input[placeholder='192.168.1.3']", "192.168.99.3")
    pg.fill(".modal input[placeholder='留空则使用主机名或地址']", "lab-side")
    ok()
    pg.locator(".cbi-section .cbi-radio > span", has_text="转发给网关").first.wait_for()

    go("sources")
    for name, rule in (("国内", "geoip:cn"), ("测试域名", "domain:foreign.lab")):
        click("新建规则组")
        pg.fill(".modal input[placeholder='例如：流媒体']", name)
        pg.fill(".modal textarea", rule)
        ok()

    go("flows")
    for src, rg, invert in (("组A", "国内", True), ("client-b", "测试域名", False)):
        click("新建分流")
        pg.locator(".modal .cbi-radio > span", has_text="指定设备组或设备").click()
        pg.locator(".modal .sr-pick label", has_text=src).locator("input").check()
        pg.locator(".modal .cbi-radio > span", has_text="指定规则组").click()
        pg.locator(".modal .sr-pick label", has_text=rg).locator("input").check()
        if invert:
            pg.check("#sr-not")
        pg.select_option("#sr-exit", label="网关 lab-side")
        ok()

    go("overview")
    pg.check("#sr-enabled")
    pg.wait_for_timeout(800)
    pg.locator(".cbi-page-actions .cbi-button-apply").first.click()
    pg.wait_for_timeout(15000)  # 应用配置并等待回滚确认
    go("overview")
    pg.wait_for_timeout(6000)
    pg.screenshot(path=f"{OUT}-final.png", full_page=True)
    print("脚本错误：", errs or "无")
    b.close()
