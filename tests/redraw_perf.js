// Edit redraw cost on an iPad-class CPU: an edit re-renders only the row it touched (VexFlow formatting is the
// expensive part), and the result is identical to drawing the whole score again. Runs with the CPU throttled 4x.
// Usage: node tests/redraw_perf.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/redraw_perf';
const THROTTLE = +(process.env.THROTTLE || 4);

function serve() {
  const types = { '.js': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json' };
  const srv = http.createServer((req, res) => {
    const p = path.join(ROOT, 'web', decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(path.join(ROOT, 'web')) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}

const median = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1194, height: 834 } });
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const cdp = await p.context().newCDPSession(p);
  const fails = [];
  const ok = (c, m) => { if (!c) fails.push(m); console.log(c ? 'ok  ' : 'FAIL', m); };

  for (const file of ['mozart_k545', 'haydn_74_vn1', 'joplin_rag']) {
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
    await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(path.join(ROOT, `bench/data/${file}.musicxml`), 'utf8'));
    await p.waitForTimeout(300);
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: THROTTLE });
    // the whole page, as an open or a reflow draws it
    const full = await p.evaluate(() => {
      const S = window.__ms.S; const t = [];
      for (let i = 0; i < 3; i++) { S.layout = null; const t0 = performance.now(); window.__ms.redraw(); t.push(performance.now() - t0); }
      return { t, rows: S.layout.rows.length };
    });
    // edits from the keyboard: select a note in the middle of the page, then Alt+↑ ↓ (each one is a full edit:
    // pitch change, undo step, redraw)
    // (one key at a time with a pause between, as a person types, so the autosave runs in between)
    const res = { t: [], rows: [] };
    await p.evaluate(() => {
      const S = window.__ms.S;
      const notes = S.layout.notes.filter((n) => !n.ghost && !n.ev.rest);
      S.sel = notes[Math.floor(notes.length / 2)].ev.el; S.measures = new Set(); window.__ms.redraw();
    });
    for (let i = 0; i < 12; i++) {
      await p.waitForTimeout(150);
      const r = await p.evaluate((key) => {
        const S = window.__ms.S;
        const t0 = performance.now();
        // Alt+↑↓ is a scale step: the note stays in the key, so the bar usually keeps its spacing
        document.body.dispatchEvent(new KeyboardEvent('keydown', { key, altKey: true, bubbles: true }));
        return { t: performance.now() - t0, rows: [S.layout.redrawn, S.layout.redrawnBars] };
      }, i % 2 ? 'ArrowDown' : 'ArrowUp');
      res.t.push(r.t); res.rows.push(r.rows);
    }
    await p.waitForTimeout(150);
    // selecting the next note redraws the two bars involved at most; the playhead redraws none
    Object.assign(res, await p.evaluate(() => {
      const S = window.__ms.S;
      const notes = S.layout.notes.filter((n) => !n.ghost && !n.ev.rest);
      const i = notes.findIndex((n) => n.ev.el === S.sel);
      const t1 = performance.now();
      S.sel = notes[i + 1].ev.el; window.__ms.redraw();
      const selT = performance.now() - t1, selRows = S.layout.redrawnBars;
      const t2 = performance.now();
      window.__ms.redraw();
      return { selT, selRows, idleT: performance.now() - t2, idleBars: S.layout.redrawnBars };
    }));
    // the incrementally drawn page matches a full redraw (VexFlow's generated ids aside)
    const same = await p.evaluate(() => {
      const S = window.__ms.S;
      const snap = () => {
        const svg = document.querySelector('#score svg');
        const rows = [...svg.querySelectorAll(':scope > g[data-bar]')].sort((a, b) => a.dataset.bar - b.dataset.bar).map((g) => g.outerHTML.replace(/ id="[^"]*"/g, ''));
        const notes = S.layout.notes.map((n) => `${n.rowIdx}:${n.ev.el === S.sel ? '*' : ''}${Math.round(n.vf.getAbsoluteX?.() || 0)}`).join(' ');
        return { rows, notes, ties: svg.querySelector(':scope > g[data-ties]')?.outerHTML.replace(/ id="[^"]*"/g, '') };
      };
      const a = snap();
      S.layout = null; window.__ms.redraw();
      const b = snap();
      const diff = a.rows.map((r, i) => (r === b.rows[i] ? -1 : i)).filter((i) => i >= 0);
      return { diff, n: [a.rows.length, b.rows.length], notes: a.notes === b.notes, ties: a.ties === b.ties };
    });
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
    const edit = median(res.t.slice(2));
    console.log(`${file}: ${full.rows} rows · full redraw ${median(full.t).toFixed(1)} ms · edit ${edit.toFixed(1)} ms (bars redrawn ${[...new Set(res.rows.map((r) => r[1]))].join('/')}) · select ${res.selT.toFixed(1)} ms (${res.selRows} bars) at ${THROTTLE}x CPU throttle`);
    ok(res.rows.every(([r]) => r === 1) && res.rows.filter(([, n]) => n === 1).length >= res.rows.length / 2, `${file}: an edit redraws its bar (its row when the spacing changed), never more`);
    ok(res.idleBars === 0, `${file}: a redraw with nothing changed draws no bars (${res.idleT.toFixed(1)} ms)`);
    ok(res.selRows <= 2, `${file}: moving the selection redraws the two bars involved at most`);
    ok(edit < median(full.t) / 3, `${file}: an edit costs well under a full redraw`);
    ok(same.n[0] === same.n[1] && !same.diff.length && same.notes && same.ties, `${file}: incremental drawing matches a full redraw${same.diff.length ? ' (bars ' + same.diff + ' differ)' : ''}`);
    await p.screenshot({ path: `${OUT}/${file}.png` });
  }
  // undo replaces the score: the next draw is a full one and still correct
  const undo = await p.evaluate(() => { const S = window.__ms.S; const before = S.score.toXML(); document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', ctrlKey: true, bubbles: true })); return { bars: S.layout.redrawnBars, changed: S.score.toXML() !== before, n: document.querySelectorAll('#score svg > g[data-bar]').length, total: S.score.nMeasures }; });
  ok(undo.changed && undo.bars >= 1 && undo.n === undo.total, `undo redraws (${undo.bars} bars, ${undo.n} of ${undo.total} on the page)`);
  ok(!errs.length, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall passed');
})();
