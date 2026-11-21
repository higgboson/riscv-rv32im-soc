import sys, base64, asyncio
from playwright.async_api import async_playwright
async def main(js, out):
    html = f"""<!doctype html><html><body style='margin:0'><canvas id='c'></canvas>
<script>{open('lib.js').read()}</script><script>{open(js).read()}</script></body></html>"""
    async with async_playwright() as p:
        b = await p.chromium.launch(args=['--no-sandbox'])
        pg = await b.new_page()
        errs = []; pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('console', lambda m: errs.append(m.text) if m.type=='error' else None)
        await pg.set_content(html); await pg.wait_for_timeout(400)
        if errs: print('ERRORS:', errs)
        d = await pg.evaluate("document.getElementById('c').toDataURL('image/png')")
        open(out, 'wb').write(base64.b64decode(d.split(',')[1])); await b.close()
asyncio.run(main(sys.argv[1], sys.argv[2]))
