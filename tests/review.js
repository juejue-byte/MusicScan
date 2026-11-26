// Fix it review mode on an emulated iPad (landscape, touch), in demo mode on the blurry sample (many flags):
// open Fix it from the banner, step next/prev, accept with a tap and with Enter, edit in place, rescan the row,
// undo an accept, finish all flags, use a second reading, and check the photo crop and the bar's reading are drawn.
// Usage: node tests/review.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/review_ui';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg' };
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
  const ok = (c, m) => { if (!c) fails.push(m); };
  await p.goto(base);
  await p.waitForSelector('.sample');
  const tap = async (sel) => { await p.locator(sel).first().tap(); await p.waitForTimeout(250); };
  await tap('.sample:nth-of-type(4)');
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
  await p.waitForTimeout(600);
  const st = () => p.evaluate(() => {
    const S = window.__ms.S, R = window.__msReview;
    return { on: R.isActive(), cur: R.state.cur, flags: R.flagged().length, checked: S.meta.filter((m) => m.reviewed).length, undo: S.undo.length,
      count: document.querySelector('#rvCount').textContent, why: document.querySelector('#rvWhy').textContent, bar: document.querySelector('#rvBar').textContent,
      sel: [...S.measures], note: !!S.sel, crop: document.querySelector('#rvCrop').width, read: !!document.querySelector('#rvRead svg'),
      fixN: [...document.querySelectorAll('.fix-btn')].find((x) => x.offsetParent).querySelector('.n').textContent, modal: !document.querySelector('#modal').classList.contains('hidden') };
  });
  const s0 = await st();
  ok(s0.flags >= 5, `expected flags on the blurry sample, got ${s0.flags}`);
  ok(s0.fixN === String(s0.flags), `Fix it button should count ${s0.flags} open flags, shows "${s0.fixN}"`);

  // 1. open from the banner
  await tap('[data-b="fix"]');
  let s = await st();
  ok(s.on, 'Fix it did not open from the banner');
  ok(s.count === `0 of ${s0.flags} checked`, `progress reads "${s.count}"`);
  ok(s.crop > 50, 'photo crop not drawn');
  ok(s.read, 'reading of the bar not drawn');
  ok(s.sel.length === 1 && s.sel[0] === s.cur, 'flagged bar is not selected in the score');
  ok(s.why.length > 5, 'no reason shown');
  const first = s.cur;
  await p.screenshot({ path: path.join(OUT, '1_open.png') });

  // 2. next / prev
  await tap('#rvNext');
  s = await st();
  ok(s.cur > first, 'next did not move forward');
  await tap('#rvPrev');
  s = await st();
  ok(s.cur === first, 'prev did not come back');

  // 3. accept with a tap: marked checked, moves to the next open flag, undoable
  await tap('#rvAccept');
  s = await st();
  ok(s.checked === 1 && s.count === `1 of ${s0.flags} checked`, `accept: ${s.count}`);
  ok(s.cur !== first, 'accept did not advance');
  ok(s.fixN === String(s0.flags - 1), `badge after accept: ${s.fixN}`);
  // 4. accept with the keyboard
  await p.keyboard.press('Enter');
  s = await st();
  ok(s.checked === 2, 'Enter did not accept');
  await p.keyboard.press('Control+z');
  s = await st();
  ok(s.checked === 1, 'undo did not unmark the last accept');

  // 5. edit in place: a note in the bar is selected and editable with the normal tools
  await tap('#rvEdit');
  s = await st();
  ok(s.note, 'Edit did not select a note in the bar');
  const xmlBefore = await p.evaluate(() => window.__ms.S.score.toXML());
  await p.keyboard.press('ArrowUp');
  const xmlAfter = await p.evaluate(() => window.__ms.S.score.toXML());
  ok(xmlBefore !== xmlAfter, 'arrow key did not edit the selected note');
  ok((await p.locator('#rvAccept').textContent()).includes('Done'), 'accept button should read Done while editing');
  await p.screenshot({ path: path.join(OUT, '2_edit.png') });
  await p.keyboard.press('Escape'); // deselect the note (stays in review)
  s = await st();
  ok(s.on, 'Esc with a note selected should only deselect');
  await p.keyboard.press('Enter');
  s = await st();
  ok(s.checked === 2, 'Done did not mark the edited bar');

  // 6. rescan the row from the panel (demo has precomputed rescans)
  await tap('#rvRescan');
  await p.waitForSelector('[data-m="use"]', { timeout: 10000 });
  await p.screenshot({ path: path.join(OUT, '3_rescan.png') });
  await tap('[data-m="use"]');
  s = await st();
  ok(s.on && !s.modal, 'review should continue after a rescan');
  ok(s.read, 'panel not redrawn after rescan');

  // 7. finish every flag with Enter
  for (let i = 0; i < 80; i++) {
    s = await st();
    if (s.checked === s.flags) break;
    await p.keyboard.press('Enter');
  }
  s = await st();
  ok(s.checked === s.flags, `could not finish: ${s.count}`);
  ok(s.fixN === '✓', 'Fix it button should show a check when done');
  await p.screenshot({ path: path.join(OUT, '4_done.png') });
  // 8. close with Esc, reopen with F
  await p.keyboard.press('Escape');
  s = await st();
  ok(!s.on, 'Esc did not close Fix it');
  await p.keyboard.press('f');
  s = await st();
  ok(s.on, 'F did not reopen Fix it');

  // 9. second reading: when the two models disagreed on a bar, Fix it shows the other reading and swaps it in
  const alt = await p.evaluate(() => {
    const S = window.__ms.S;
    window.__msReview.stop();
    const mi = 3;
    const doc = new DOMParser().parseFromString(S.score.toXML(), 'application/xml');
    const step = doc.querySelectorAll('part')[0].querySelectorAll(':scope > measure')[mi].querySelector('note pitch step');
    step.textContent = step.textContent === 'C' ? 'D' : 'C';
    const want = step.textContent;
    S.result.second_opinion = { aligned: true, bars: 1, xml: new XMLSerializer().serializeToString(doc) };
    S.meta.forEach((m, i) => { m.index = i; });
    Object.assign(S.meta[mi], { disagree: true, level: 'bad' });
    delete S.meta[mi].reviewed;
    window.__ms.redraw();
    window.__msReview.start(mi);
    return { mi, want };
  });
  await p.waitForTimeout(200);
  Object.assign(alt, await p.evaluate(() => ({ shown: !document.querySelector('#rvUseAlt').classList.contains('hidden'), drawn: !!document.querySelector('#rvAlt svg') })));
  ok(alt.shown && alt.drawn, 'second reading not offered for a disagreeing bar');
  await p.screenshot({ path: path.join(OUT, '5_second.png') });
  await tap('#rvUseAlt');
  const got = await p.evaluate((mi) => {
    const S = window.__ms.S;
    return { step: S.score.parts[0].measures[mi].querySelector('note pitch step').textContent, reviewed: !!S.meta[mi].reviewed, n: S.score.nMeasures };
  }, alt.mi);
  ok(got.step === alt.want && got.reviewed, `second reading not used: ${JSON.stringify(got)}`);

  // 10. iPhone portrait: the panel fits and the main button is full width
  const ph = await b.newContext({ ...devices['iPhone 13'] });
  const q = await ph.newPage();
  q.on('pageerror', (e) => errs.push('iphone: ' + e.message));
  await q.goto(base);
  await q.waitForSelector('.sample');
  await q.locator('.sample').nth(3).tap();
  await q.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
  await q.waitForTimeout(500);
  await q.locator('.fix-btn:visible').tap();
  await q.waitForTimeout(400);
  const fit = await q.evaluate(() => { const r = document.querySelector('#review').getBoundingClientRect(); return { h: r.height, sw: document.documentElement.scrollWidth, w: innerWidth }; });
  ok(fit.sw <= fit.w + 1, `iPhone: page scrolls sideways (${fit.sw} > ${fit.w})`);
  ok(fit.h < 560, `iPhone: panel too tall (${fit.h}px)`);
  await q.screenshot({ path: path.join(OUT, '6_iphone.png') });

  ok(!errs.length, 'page errors: ' + errs.join(' | '));
  await b.close();
  srv.close();
  if (fails.length) { console.log('FAIL\n  ' + fails.join('\n  ')); process.exit(1); }
  console.log(`ok: review mode (${s0.flags} flags) · screenshots in ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
