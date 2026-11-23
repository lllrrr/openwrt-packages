# LuCI 页面检查：登录后逐页打开智能分流各标签，收集脚本错误、检查横向溢出，并按 浅色/深色 × 桌面/手机 截图
# 用法（开发机 ~/shot/venv）: python luci.py <LuCI 地址，如 http://192.168.5.203:18080> <root 密码> <截图前缀> [语言，默认 zh-CN；en-US 看英文原文]
import sys
from playwright.sync_api import sync_playwright

BASE, PW, OUT = sys.argv[1:4]
LANG = sys.argv[4] if len(sys.argv) > 4 else "zh-CN"
TABS = ["overview", "flows", "devices", "exits", "sources", "diag", "prefs"]

def login(pg):
    pg.goto(BASE + "/cgi-bin/luci/admin/network/smartroute/overview")
    if pg.locator("input[name=luci_password]").count():
        pg.fill("input[name=luci_password]", PW)
        pg.press("input[name=luci_password]", "Enter")
        pg.wait_for_load_state("networkidle")

with sync_playwright() as p:
    b = p.chromium.launch()
    bad = []
    # 环境变量 COMBOS 可只跑部分组合，如 "light:1440 dark:1440 light:400"
    import os
    combos = [(c.split(":")[0], int(c.split(":")[1])) for c in os.environ.get("COMBOS", "light:1440 light:400 dark:1440 dark:400").split()]
    for scheme, w in combos:
        if True:
            ctx = b.new_context(viewport={"width": w, "height": 900}, color_scheme=scheme, locale=LANG)
            pg = ctx.new_page()
            errs = []
            pg.on("pageerror", lambda e: errs.append(str(e)))
            pg.on("console", lambda m: m.type == "error" and "favicon" not in m.text and errs.append(m.text))
            login(pg)
            for t in TABS:
                errs.clear()
                pg.goto(f"{BASE}/cgi-bin/luci/admin/network/smartroute/{t}")
                pg.wait_for_load_state("networkidle")
                pg.wait_for_timeout(800)
                sw = pg.evaluate("document.documentElement.scrollWidth")
                if sw > w:
                    bad.append(f"{scheme} {w} {t}：页面超宽 {sw}px")
                if pg.locator(".alert-message.error, .alert-message.danger").count():
                    bad.append(f"{scheme} {w} {t}：页面报错 " + pg.locator(".alert-message").first.inner_text()[:200])
                bad += [f"{scheme} {w} {t}：脚本错误 {e[:300]}" for e in errs]
                pg.screenshot(path=f"{OUT}-{t}-{w}-{scheme}.png", full_page=True)
            ctx.close()
    print("\n".join(bad) or "无脚本错误、无超宽")
    b.close()
