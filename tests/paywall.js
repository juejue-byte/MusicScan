// Paywall UI (web/js/paywall.js), payments not connected: off by default (export just works); with ?paywall the first
// page is free with every feature, the next scan shows the first half and blurs the rest, taps, keys, Play and Export
// ask to unlock, the sheet has two plans with renewal terms, Terms and Restore, Continue unlocks, Pro has 30 pages.
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

  // 2. preview on: the first page is free with every feature
  await p.goto(url('&paywall'));
  await p.waitForSelector('.sample');
  ok(/first page is free/.test(await p.locator('#freeScans').textContent()), 'start screen says the first page is free');
  await sample(1);
  ok(await p.locator('#lockVeil').count() === 0, 'the free page is not blurred');
  let dl = await exportXml();
  ok(!!dl && (await sheet()) === 0, 'the free page exports without the paywall');

  // 3. the second scan opens as a half-page preview
  await tap('#btnNew');
  ok(/first half/.test(await p.locator('#freeScans').textContent()), 'start screen explains the preview after the free page');
  await sample(2);
  const veil = await p.locator('#lockVeil').boundingBox();
  const sc = await p.locator('#score').boundingBox();
  ok(!!veil && veil.y > sc.y + 40, `the lower part of the page is blurred (veil at ${veil && Math.round(veil.y - sc.y)} px)`);
  ok(/more bars? on this page/.test(await p.locator('#lockVeil b').textContent()), 'the veil says how many bars are hidden');
  await p.screenshot({ path: path.join(OUT, 'ipad_preview.png') });
  const before = await p.evaluate(() => window.__ms.S.score.toXML());
  await p.locator('#score').tap({ position: { x: 200, y: 60 } });
  await p.waitForTimeout(300);
  ok((await sheet()) === 1, 'tapping the score asks to unlock');
  await p.screenshot({ path: path.join(OUT, 'ipad_paywall.png') });
  const plans = await p.$$eval('.pw-plan', (xs) => xs.map((x) => x.querySelector('.pw-price').textContent));
  ok(plans.join() === '$99.99,$15.99', `two plans, no weekly (${plans.join(' ')})`);
  ok(/Start 7-day free trial/.test(await p.locator('.pw-go').textContent()), 'Yearly is picked by default and offers the 7-day trial');
  ok(/Free for 7 days, then \$99\.99 per year\. Renews automatically.*before the trial ends/.test(await p.locator('.pw-terms').textContent()), 'trial terms say the length, the price after and how to cancel');
  ok(/7 days free/.test(await p.locator('.pw-plan[data-plan="year"] .pw-best').textContent()), 'the yearly card says 7 days free');
  ok(await p.locator('.pw-foot a', { hasText: 'Terms of Use' }).count() === 1 && await p.locator('[data-a=restore]').count() === 1, 'Terms of Use and Restore purchases are on the sheet');
  await tap('.pw-plan[data-plan="month"]');
  ok(/Monthly/.test(await p.locator('.pw-go').textContent()) && /\$15\.99 per month/.test(await p.locator('.pw-terms').textContent()), 'tapping a plan picks it and updates the terms');
  await tap('.pw-close');
  await p.waitForTimeout(300);
  ok((await sheet()) === 0, 'Not now closes the sheet');
  await p.keyboard.press('ArrowUp'); await p.keyboard.press('Delete');
  await p.waitForTimeout(200);
  const after = await p.evaluate(() => window.__ms.S.score.toXML());
  ok(before === after, 'keys do not edit a preview');
  if (await sheet()) await tap('.pw-close');
  await tap('#btnPlay');
  ok((await sheet()) === 1 && !(await p.evaluate(() => window.__ms.audio.isPlaying())), 'Play asks to unlock and does not play');
  await tap('.pw-close');
  await tap('#btnExport');
  ok((await sheet()) === 1 && await p.locator('#exportMenu.open').count() === 0, 'Export asks to unlock');
  await tap('.pw-go');
  await p.waitForTimeout(500);
  ok((await sheet()) === 0 && await p.evaluate(() => window.__ms.paywall.isPro()), 'Starting the trial unlocks the preview');
  ok(/7-day free trial has started/.test(await p.locator('#toast').textContent()), 'says the trial started');
  ok(await p.locator('#lockVeil').count() === 0, 'the whole page shows after unlocking');
  dl = await exportXml();
  ok(!!dl, 'after unlocking the export goes through');

  // a trial is once only: after it, the sheet shows the plain price
  await p.evaluate(() => localStorage.removeItem('musicscan:pro'));
  await p.evaluate(() => { window.__ms.paywall.show(); });
  await p.waitForTimeout(300);
  ok(/Continue with Yearly/.test(await p.locator('.pw-go').textContent()) && /^\$99\.99 per year/.test(await p.locator('.pw-terms').textContent()), 'no second trial: plain price after a trial was used');
  await tap('.pw-go');
  await p.waitForTimeout(300);

  // 4. Pro allowance: 30 pages a month
  await tap('#btnNew');
  ok(/of 30 pages left/.test(await p.locator('#freeScans').textContent()), 'Pro sees the pages left this month');
  await p.evaluate(() => localStorage.setItem('musicscan:pages', JSON.stringify({ m: new Date().toISOString().slice(0, 7), n: 30 })));
  await tap('.sample:nth-of-type(2)');
  await p.waitForTimeout(500);
  ok(await p.locator('#viewUpload:not(.hidden)').count() === 1 && /all 30 pages/.test(await p.locator('#toast').textContent()), 'after 30 pages a scan says when more pages come');
  await ctx.close();

  // 5. phone: a bottom sheet that fits
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
