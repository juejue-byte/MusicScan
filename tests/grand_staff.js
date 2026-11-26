// Piano (grand staff) ergonomics on an emulated iPad and desktop: the piano's staff button moves the caret between
// treble and bass, ⌘⇧↓ moves a note the scan put on the wrong staff, and bars stay full.
// Usage: node tests/grand_staff.js [outDir]   (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');
const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/grand_staff';
function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json' };
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
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const b = await chromium.launch();
  const fails = [];
  const ok = (c, m) => { if (!c) fails.push(m); console.log(c ? 'ok  ' : 'FAIL', m); };
  const xml = fs.readFileSync(path.join(ROOT, 'bench/data/mozart_k545.musicxml'), 'utf8');
  const over = (p) => p.evaluate(() => { const s = window.__ms.S.score; const o = []; for (let mi = 0; mi < s.nMeasures; mi++) for (let pi = 0; pi < s.parts.length; pi++) if (s.measureProblems(pi, mi).over) o.push(mi); return o.join(','); });
  // iPad: the staff button
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'] });
  const p = await ctx.newPage();
  const errs = []; p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  await p.evaluate((x) => window.__ms.openScore(x), xml);
  await p.waitForTimeout(300);
  const tap = async (sel) => { const r = await p.locator(sel).first().boundingBox(); await p.touchscreen.tap(r.x + r.width / 2, r.y + r.height / 2); await p.waitForTimeout(120); };
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([4]); window.__ms.redraw(); });
  await tap('[data-mode="add"]');
  ok(await p.locator('[data-p="staff"]').isVisible(), 'piano shows a staff button on a grand staff');
  const lowTop = await p.evaluate(() => document.querySelector('.pk.white span').textContent);
  await tap('[data-p="staff"]');
  ok(await p.evaluate(() => window.__ms.S.caret.staff) === '2', 'it moves the caret to the lower staff');
  const lowest = await p.evaluate(() => document.querySelector('.pk.white span').textContent);
  console.log('keyboard', lowTop, '->', lowest);
  await tap('.pk.white >> nth=0');
  const w = await p.evaluate(() => { const e = window.__ms.S.score.voiceEvents(0, 4, '2', null)[0]; return e.rest ? 'rest' : e.chord[0].pitch.step + e.chord[0].pitch.octave; });
  ok(w === lowest, `a key writes in the lower staff (${w})`);
  await tap('[data-p="staff"]');
  ok(await p.evaluate(() => window.__ms.S.caret.staff) === '1', 'and back to the treble');
  ok(await over(p) === '', 'bars stay full');
  ok(!errs.length, 'no page errors ' + errs.join('; '));
  await ctx.close();
  // desktop: ⌘⇧↓ moves a treble note to the bass staff
  const d = await b.newPage({ viewport: { width: 1440, height: 900 } });
  await d.goto(base);
  await d.evaluate((x) => window.__ms.openScore(x), xml);
  await d.waitForTimeout(300);
  const before = await d.evaluate(() => { const S = window.__ms.S; const e = S.score.voiceEvents(0, 1, '1', null).find((x) => !x.rest); S.sel = e.el; window.__ms.redraw(); return { q: e.onset / e.div, p: e.chord.map((c) => c.pitch.step + c.pitch.octave).join('+'), n2: S.score.voiceEvents(0, 1, '2', null).length }; });
  await d.keyboard.press('Control+Shift+ArrowDown');
  await d.waitForTimeout(100);
  const after = await d.evaluate((q) => { const s = window.__ms.S.score; const top = s.voiceEvents(0, 1, '1', null).find((e) => Math.abs(e.onset / e.div - q) < 1e-6); const bass = s.voiceEvents(0, 1, '2', null).filter((e) => Math.abs(e.onset / e.div - q) < 1e-6 && !e.rest); return { topRest: !!top?.rest, bass: bass.map((e) => e.chord.map((c) => c.pitch.step + c.pitch.octave).join('+')) }; }, before.q);
  console.log('moved', before.p, '->', JSON.stringify(after));
  ok(after.topRest && after.bass.some((x) => x.includes(before.p.split('+')[0])), 'the note left the treble and sounds in the bass staff');
  ok(await over(d) === '', 'bars stay full');
  await d.keyboard.press('Control+z');
  ok(await d.evaluate(() => window.__ms.S.score.voiceEvents(0, 1, '1', null).some((e) => !e.rest)), 'one undo puts it back');
  await b.close(); srv.close();
  if (fails.length) { console.log('\nFAILED:\n' + fails.join('\n')); process.exit(1); }
  console.log('\nall passed');
})();
