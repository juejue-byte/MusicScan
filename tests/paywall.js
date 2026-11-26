// Paywall UI (web/js/paywall.js), payments not connected: off by default (export just works); with ?paywall the
// export menu opens the sheet, Not now keeps the file back, plans can be picked, Continue unlocks the preview and
// the export goes through; the start screen counts free scans and the 4th scan in a month asks first.
// Usage: node tests/paywall.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/paywall_ui';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
  const srv = http.createServer((req, res) => {
    const p = path.join(ROOT, 'web', decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(path.join(ROOT, 'web')) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await serve();
  const url = (q) => `http://127.0.0.1:${srv.address().port}/?demo${q || ''}`;
  const b = await chromium.launch();
  const fails = [];
  const errs = [];
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fails.push(m); };

  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'], acceptDownloads: true });
  const p = await ctx.newPage();
  p.on('pageerror', (e) => errs.push(e.message));
  const tap = async (sel) => { await p.locator(sel).first().tap(); await p.waitForTimeout(250); };
  const sample = async (k) => { await tap(`.sample:nth-of-type(${k})`); await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 }); await p.waitForTimeout(300); };
  const sheet = () => p.locator('#paywall:not(.hidden)').count();
  const exportXml = async () => {
    let dl = null;
    p.once('download', (d) => { dl = d; });
    await tap('#btnExport'); await tap('[data-x="xml"]');
    await p.waitForTimeout(400);
    return dl;
  };

  // 1. off by default
  await p.goto(url());
  await p.waitForSelector('.sample');
  ok(await p.locator('#freeScans').count() === 0, 'no free-scan meter without the preview');
  await sample(1);
  ok(!!(await exportXml()) && (await sheet()) === 0, 'export works without a paywall by default');

  // 2. preview on
  await p.goto(url('&paywall'));
  await p.waitForSelector('.sample');
  ok(/of 3 free scans left/.test(await p.locator('#freeScans').textContent()), 'start screen shows the free scans left');
  await sample(1);
  let dl = await exportXml();
  ok(!dl && (await sheet()) === 1, 'export opens the paywall first');
  await p.screenshot({ path: path.join(OUT, 'ipad_paywall.png') });
  const plans = await p.$$eval('.pw-plan', (xs) => xs.map((x) => x.querySelector('.pw-price').textContent));
  ok(plans.join() === '$44.99,$6.99,$5.99', `three plans with the brief's prices (${plans.join(' ')})`);
  ok(/Yearly/.test(await p.locator('.pw-go').textContent()), 'Yearly is picked by default');
  await tap('.pw-plan[data-plan="week"]');
  ok(/Weekly/.test(await p.locator('.pw-go').textContent()) && await p.locator('.pw-plan.on[data-plan="week"]').count() === 1, 'tapping a plan picks it');
  await tap('.pw-close');
  await p.waitForTimeout(300);
  ok((await sheet()) === 0, 'Not now closes the sheet and keeps the file back');
  dl = await exportXml();
  await tap('.pw-go');
  await p.waitForTimeout(500);
  ok((await sheet()) === 0 && await p.evaluate(() => window.__ms.paywall.isPro()), 'Continue unlocks the preview');
  dl = await exportXml();
  ok(!!dl, 'after Continue the export goes through');

  // 3. free allowance: the 4th scan this month asks first
  await p.evaluate(() => { localStorage.removeItem('musicscan:pro'); localStorage.setItem('musicscan:scans', JSON.stringify({ m: new Date().toISOString().slice(0, 7), n: 3 })); });
  await p.goto(url());
  await p.waitForSelector('.sample');
  ok(/0 of 3/.test(await p.locator('#freeScans').textContent()), 'the meter shows none left after 3 scans');
  await tap('.sample:nth-of-type(2)');
  await p.waitForTimeout(400);
  ok((await sheet()) === 1 && /free scans/.test(await p.locator('.pw-head p').textContent()), 'a 4th scan opens the paywall with the reason');
  await p.keyboard.press('Escape');
  await p.waitForTimeout(300);
  ok((await sheet()) === 0 && await p.locator('#viewUpload:not(.hidden)').count() === 1, 'Escape closes it and the scan does not start');
  await ctx.close();

  // 4. phone: a bottom sheet that fits
  const ctx2 = await b.newContext({ ...devices['iPhone 14'] });
  const p2 = await ctx2.newPage();
  p2.on('pageerror', (e) => errs.push(e.message));
  await p2.goto(url('&paywall'));
  await p2.waitForSelector('.sample');
  await p2.evaluate(() => { window.__ms.paywall.show(); });
  await p2.waitForTimeout(300);
  const r = await p2.locator('.pw-card').boundingBox();
  const vw = await p2.evaluate(() => innerWidth);
  ok(r && r.width <= vw + 1 && Math.round(r.x) === 0, `iPhone: the paywall is a full-width bottom sheet (${Math.round(r.width)} of ${vw})`);
  await p2.screenshot({ path: path.join(OUT, 'iphone_paywall.png') });
  await p2.goto(url('&paywall=off'));
  await p2.waitForSelector('.sample');
  ok(!(await p2.evaluate(() => window.__ms.paywall.enabled())), '?paywall=off turns the preview off');
  await ctx2.close();

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall paywall checks passed');
})();
