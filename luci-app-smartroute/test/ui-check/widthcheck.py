import sys
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch(); bad = []
    for scheme in ("light", "dark"):
        for w in (1440, 400):
            pg = b.new_page(viewport={"width": w, "height": 900}, color_scheme=scheme)
            for h in ["overview", "flows", "devices", "exits", "sources", "diag", "prefs"]:
                pg.goto("file://" + sys.argv[1] + "#" + h); pg.wait_for_timeout(250)
                sw = pg.evaluate("document.documentElement.scrollWidth")
                if sw > w: bad.append(f"{scheme} {w} {h} {sw}")
            pg.close()
    print("超宽页面：", bad or "无"); b.close()
