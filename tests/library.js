// Your music (web/js/library.js): scores you open are kept on the device and listed on the start screen.
// On an emulated iPad in demo mode: open two samples, see both cards with their flag status, filter to the ones to
// check, reopen a score with its edits, survive a reload, and remove one with two taps.
// Usage: node tests/library.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/library_ui';

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
  const base = `http://127.0.0.1:${srv.address().port}/?demo`;
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'] });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  const fails = [];
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fails.push(m); };
  const tap = async (sel) => { await p.locator(sel).first().tap(); await p.waitForTimeout(300); };
  const home = async () => { await tap('#btnNew'); await p.waitForSelector('#viewUpload:not(.hidden)'); await p.waitForTimeout(500); };
  const cards = () => p.$$eval('.lib-card', (xs) => xs.map((x) => ({ title: x.querySelector('.lib-title').textContent, status: x.querySelector('.lib-status').textContent, kind: x.querySelector('.lib-status').className.split(' ').pop() })));

  await p.goto(base);
  await p.waitForSelector('.sample');
  ok(await p.locator('#library.hidden').count() === 1, 'no library section before any music');

  await tap('.sample:nth-of-type(1)');
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
  const before = await p.evaluate(() => window.__ms.S.score.toXML().length);
  await home();
  let c = await cards();
  ok(c.length === 1 && /Piano scan/i.test(c[0].title), `one card after the first score (${JSON.stringify(c)})`);
  ok(c[0] && /to check|Ready/.test(c[0].status), `card shows the flag status (${c[0]?.status})`);

  await tap('.sample:nth-of-type(4)');
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
  await p.waitForTimeout(300);
  await home();
  c = await cards();
  ok(c.length === 2 && /Blurry/i.test(c[0].title), `newest first, two cards (${c.map((x) => x.title).join(', ')})`);
  await p.screenshot({ path: path.join(OUT, 'ipad_library.png') });

  await tap('.lib-tabs [data-f="check"]');
  const checkOnly = await cards();
  ok(checkOnly.every((x) => x.kind !== 'ok') && checkOnly.length >= 1, `"To check" shows only scores with open flags (${checkOnly.length})`);
  await tap('.lib-tabs [data-f="all"]');

  // reopen the piano scan: same score, same place in the library (no duplicate)
  await p.locator('.lib-card', { hasText: 'Piano scan' }).locator('.lib-open').tap();
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
  const after = await p.evaluate(() => ({ len: window.__ms.S.score.toXML().length, name: window.__ms.S.name }));
  ok(after.name === '1_Piano_scan.jpg' && Math.abs(after.len - before) < 50, 'reopening restores the score');
  await home();
  ok((await cards()).length === 2, 'reopening does not add a duplicate');

  await p.reload();
  await p.waitForSelector('.lib-card', { timeout: 5000 }).catch(() => {});
  ok((await cards()).length === 2, 'the library survives a reload');

  const card = p.locator('.lib-card', { hasText: 'Blurry' });
  await card.locator('.lib-del').tap();
  await p.waitForTimeout(200);
  ok((await cards()).length === 2, 'first tap on remove only asks');
  await card.locator('.lib-del').tap();
  await p.waitForTimeout(500);
  c = await cards();
  ok(c.length === 1 && /Piano/i.test(c[0].title), 'second tap removes the score');

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall library checks passed');
})();
