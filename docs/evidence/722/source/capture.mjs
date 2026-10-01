import { createRequire } from 'module';
const require = createRequire(process.env.HOME + '/.local/share/ui-browser/package.json');
const { chromium } = require('playwright');
const url = 'file://' + process.cwd() + '/index.html';
const out = process.argv[2] || 'shots';
const browser = await chromium.launch({ headless: true });
for (const [scale, filter] of [[2, s => !s.startsWith('tv-')], [1, s => s.startsWith('tv-')]]) {
  const ctx = await browser.newContext({ viewport: { width: scale === 1 ? 4200 : 2800, height: 1200 }, deviceScaleFactor: scale });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => { document.body.classList.remove('show-zones'); document.querySelectorAll('[data-shot]').forEach(e => e.style.zoom = ''); const st = document.createElement('style'); st.textContent = '.wrap{max-width:none!important}.stage{overflow:visible!important}'; document.head.appendChild(st); });
  const ids = await page.$$eval('[data-shot]', els => els.map(e => e.dataset.shot));
  for (const id of ids.filter(filter)) {
    await page.locator(`[data-shot="${id}"]`).screenshot({ path: `${out}/${id}.png` });
  }
  if (scale === 2) {
    await page.evaluate(() => { document.body.classList.add('show-zones'); });
    for (const id of ['macMedium-light', 'macLarge-dark', 'overview-light']) await page.locator(`[data-shot="${id}"]`).screenshot({ path: `${out}/zones-${id}.png` });
  }
  await ctx.close();
}
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 });
const page = await ctx.newPage(); await page.goto(url, { waitUntil: 'networkidle' });
await page.screenshot({ path: `${out}/_fullpage.png`, fullPage: true });
const ov = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }));
console.log('overflow', JSON.stringify(ov));
await browser.close();
