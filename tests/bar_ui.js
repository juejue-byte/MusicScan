// The bar and rhythm tools in the real editor on an emulated iPad (landscape, touch): tap a note, split the bar there
// from the Bar menu, join it back, insert and delete a bar, tie, triplet, and turn a rest into a note from the palette.
// Usage: node tests/bar_ui.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/bar_ui';

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
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'] });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const fails = [];
  const ok = (c, m) => { if (!c) fails.push(m); };
  await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(path.join(ROOT, 'bench/data/mozart_k545.musicxml'), 'utf8'));
  await p.waitForTimeout(400);
  const st = () => p.evaluate(() => ({ bars: window.__ms.S.score.nMeasures, undo: window.__ms.S.undo.length, toast: document.querySelector('#toast').textContent }));
  // tap the k-th note of bar mi in the top staff
  async function tapNote(mi, k, rest = false) {
    const pt = await p.evaluate(([mi, k, rest]) => {
      const L = window.__ms.S.layout;
      const ns = L.notes.filter((n) => !n.ghost && n.ev.pi === 0 && n.ev.staff === '1' && n.ev.mi === mi && n.ev.rest === rest).sort((a, b) => a.ev.onset - b.ev.onset);
      const n = ns[k]; if (!n) return null;
      const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width;
      let y;
      if (rest) { const bb = n.vf.getBoundingBox(); y = bb.getY() + bb.getH() / 2; } else { const c = n.ev.chord[0]; const idx = c.pitch.octave * 7 + 'CDEFGAB'.indexOf(c.pitch.step); y = n.stave.getYForLine(0) + (n.top - idx) * 5; }
      return { x: r.left + (n.vf.getAbsoluteX() + 6) * sx, y: r.top + y * sx };
    }, [mi, k, rest]);
    if (!pt) return false;
    await p.touchscreen.tap(pt.x, pt.y);
    await p.waitForTimeout(120);
    return true;
  }
  const tapSel = async (sel) => { const r = await p.locator(sel).boundingBox(); await p.touchscreen.tap(r.x + r.width / 2, r.y + r.height / 2); await p.waitForTimeout(150); };
  const s0 = await st();
  const xml0 = await p.evaluate(() => window.__ms.S.score.toXML());

  // 1. split bar 3 before its 3rd note, from the Bar menu
  ok(await tapNote(2, 2), 'could not find a note in bar 3');
  await tapSel('#btnBar');
  await p.screenshot({ path: OUT + '/01_bar_menu.png' });
  ok(await p.locator('#barMenu').isVisible(), 'bar menu did not open');
  await tapSel('#barMenu [data-bar="split"]');
  let s1 = await st();
  ok(s1.bars === s0.bars + 1, `split: ${s1.bars} bars, expected ${s0.bars + 1}`);
  await p.screenshot({ path: OUT + '/02_split.png' });
  // 2. join it back (bar 3 + new bar 4)
  ok(await tapNote(2, 0), 'no note in bar 3 after split');
  await tapSel('#btnBar');
  await tapSel('#barMenu [data-bar="join"]');
  s1 = await st();
  ok(s1.bars === s0.bars, `join: ${s1.bars} bars`);
  // 3. insert an empty bar after, then delete it
  await tapSel('#btnBar');
  await tapSel('#barMenu [data-bar="after"]');
  s1 = await st();
  ok(s1.bars === s0.bars + 1, `insert: ${s1.bars} bars`);
  await p.screenshot({ path: OUT + '/03_inserted.png' });
  await tapSel('#btnBar');
  await tapSel('#barMenu [data-bar="delete"]');
  s1 = await st();
  ok(s1.bars === s0.bars, `delete: ${s1.bars} bars`);
  // 5. triplet on a quarter in the top staff; then fill one of its rests by tapping a length
  const qBar = await p.evaluate(() => { const s = window.__ms.S.score; for (let mi = 0; mi < s.nMeasures; mi++) { const ns = s.events(0, mi).filter((e) => !e.rest && !e.grace && e.staff === '1').sort((a, b) => a.onset - b.onset); const k = ns.findIndex((e) => e.type === 'quarter' && !e.dots && !e.tuplet); if (k >= 0) return { mi, k }; } return null; });
  if (qBar) {
    await tapNote(qBar.mi, qBar.k);
    await tapSel('[data-act="tuplet"]');
    const trip = await p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.chord.some((c) => c.el === S.sel)); return n ? S.score.tupletGroup(n.ev).length : 0; });
    ok(trip === 3, `triplet group of ${trip}`);
    await p.screenshot({ path: OUT + '/05_triplet.png' });
    // tap the first rest of the triplet, then the eighth button: the rest becomes a note and keeps the triplet
    const restK = await p.evaluate((mi) => { const L = window.__ms.S.layout; const rs = L.notes.filter((n) => !n.ghost && n.ev.pi === 0 && n.ev.staff === '1' && n.ev.mi === mi && n.ev.rest).sort((a, b) => a.ev.onset - b.ev.onset); return rs.findIndex((n) => n.ev.tuplet); }, qBar.mi);
    ok(restK >= 0, 'triplet rests not drawn');
    await tapNote(qBar.mi, restK, true);
    await tapSel('[data-dur="eighth"]');
    const filled = await p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.chord.some((c) => c.el === S.sel) || n.ev.el === S.sel); return n ? { rest: n.ev.rest, tuplet: !!n.ev.tuplet } : null; });
    ok(filled && !filled.rest && filled.tuplet, `rest -> note: ${JSON.stringify(filled)}`);
    const over = await p.evaluate((mi) => window.__ms.S.score.parts.some((_, pi) => window.__ms.S.score.measureProblems(pi, mi).over), qBar.mi);
    ok(!over, 'triplet bar overflows');
    await p.screenshot({ path: OUT + '/06_triplet_filled.png' });
    // and Rest turns that note back into a rest
    await tapSel('[data-act="rest"]');
    ok(await p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.el === S.sel); return !!n?.ev.rest; }), 'Rest did not make a rest');
  } else fails.push('no quarter in k545');
  // 6. undo everything: back to the file we opened
  const n = (await st()).undo;
  for (let i = 0; i < n; i++) await tapSel('#btnUndo');
  ok(await p.evaluate(() => window.__ms.S.score.toXML()) === xml0, 'undo all: score differs from the original');
  ok(await p.evaluate(() => !!document.querySelector('#btnUndo svg') && !!document.querySelector('#btnRedo svg')), 'undo/redo icons');
  // 7. buttons are finger-sized
  const small = await p.evaluate(() => [...document.querySelectorAll('.toolbar button')].filter((b) => b.offsetParent && b.getBoundingClientRect().height < 44).map((b) => b.textContent.trim()));
  ok(!small.length, 'buttons under 44 px: ' + small.join(', '));
  await p.screenshot({ path: OUT + '/07_end.png' });
  // 8. tie, on a chorale (repeated notes): a note whose next note has the same pitch, found by the model
  await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(path.join(ROOT, 'bench/data/bach_bwv66.musicxml'), 'utf8'));
  await p.waitForTimeout(400);
  const tieTarget = await p.evaluate(() => {
    const s = window.__ms.S.score;
    for (let mi = 0; mi < s.nMeasures - 1; mi++) for (const e of s.events(0, mi)) {
      if (e.rest || e.grace || e.staff !== '1') continue;
      const nx = s.nextEvent(e);
      if (nx && !nx.rest && nx.chord.some((c) => e.chord.some((d) => d.pitch.step === c.pitch.step && d.pitch.octave === c.pitch.octave && (d.pitch.alter || 0) === (c.pitch.alter || 0)))) {
        return { mi, k: s.events(0, mi).filter((x) => !x.rest && !x.grace && x.staff === '1').sort((a, b) => a.onset - b.onset).findIndex((x) => x.el === e.el) };
      }
    }
    return null;
  });
  if (tieTarget) {
    await tapNote(tieTarget.mi, tieTarget.k);
    await tapSel('[data-act="tie"]');
    const tied = await p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.chord.some((c) => c.el === S.sel)); return n ? S.score.isTied(n.ev) : null; });
    ok(tied === true, 'tie did not apply');
    ok(await p.evaluate(() => document.querySelectorAll('#score svg path').length > 0), 'no drawing');
    await p.screenshot({ path: OUT + '/08_tie.png' });
  } else fails.push('no tie target in bwv66');
  await b.close();
  srv.close();
  const all = [...fails, ...errs];
  console.log(all.length ? 'FAIL\n' + all.join('\n') : 'bar_ui: all checks passed');
  process.exit(all.length ? 1 : 0);
})();
