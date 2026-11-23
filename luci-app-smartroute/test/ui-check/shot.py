# 用无界面 Chromium 给原型截图：shot.py <html文件> <输出前缀> <hash...>
import sys, asyncio
from playwright.async_api import async_playwright
async def main(path, out, hashes):
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for scheme in ("dark", "light"):
            for w, tag in ((1440, "desk"), (400, "phone")):
                pg = await b.new_page(viewport={"width": w, "height": 900}, color_scheme=scheme, device_scale_factor=1)
                for h in hashes:
                    await pg.goto(f"file://{path}#{h}"); await pg.wait_for_timeout(400)
                    await pg.screenshot(path=f"{out}-{h}-{tag}-{scheme}.png", full_page=True)
                await pg.close()
        await b.close()
asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3:]))
