// The on-screen piano for note input on an emulated iPad (landscape, touch) and a phone: keys write at the caret,
// black keys follow the key signature, Chord adds to the last note, Rest/Repeat/⌫, hide and show, no page errors.
// Usage: node tests/note_pad.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');
const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/note_pad';
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
  for (const dev of ['iPad Pro 11 landscape', 'iPhone 13']) {
    const ctx = await b.newContext({ ...devices[dev] });
    const p = await ctx.newPage();
    const errs = [];
    p.on('pageerror', (e) => errs.push(e.message));
    await p.goto(base);
    await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(path.join(ROOT, 'bench/data/bach_bwv66.musicxml'), 'utf8'));
    await p.waitForTimeout(300);
    const tap = async (sel) => { const r = await p.locator(sel).first().boundingBox(); await p.touchscreen.tap(r.x + r.width / 2, r.y + r.height / 2); await p.waitForTimeout(120); };
    const bar = (mi) => p.evaluate((mi) => window.__ms.S.score.voiceEvents(0, mi, '1', null).map((e) => (e.rest ? 'r' : e.chord.map((c) => c.pitch.step + ({ 1: '#', '-1': 'b' }[c.pitch.alter] || '') + c.pitch.octave).join('+'))), mi);
    await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([2]); window.__ms.redraw(); });
    ok(await p.locator('#notePad').isHidden(), `${dev}: no piano outside note input`);
    await tap('[data-mode="add"]');
    ok(await p.locator('#notePad').isVisible(), `${dev}: piano shows in note input`);
    const range = await p.evaluate(() => [...document.querySelectorAll('.pk.white span')].map((s) => s.textContent).filter((t) => /\d/.test(t)));
    ok(range[0] === 'C4', `${dev}: soprano keyboard starts at C4 (${range.join(' ')})`);
    await tap('.pk.white >> nth=4'); await tap('.pk.white >> nth=5');
    await tap('.pk.black >> nth=2');
    await tap('[data-p="chord"]'); await tap('.pk.white >> nth=9'); await tap('[data-p="chord"]');
    await tap('[data-p="rest"]');
    const r = await bar(2);
    ok(r.join(' ') === 'G4 A4 F#4+E5 r', `${dev}: keys, black key in A major, chord and rest land at the caret (${r.join(' ')})`);
    await tap('[data-p="back"]');
    ok((await bar(2))[3] === 'r', `${dev}: ⌫ steps back`);
    await p.screenshot({ path: `${OUT}/${dev.replace(/\W+/g, '_')}.png` });
    const scrollW = await p.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    ok(scrollW <= 1, `${dev}: no sideways page scroll (${scrollW})`);
    await tap('[data-p="hide"]');
    ok(await p.locator('#notePad').isHidden() && await p.locator('#btnPad').isVisible(), `${dev}: hide leaves a Keyboard button`);
    await tap('#btnPad');
    ok(await p.locator('#notePad').isVisible(), `${dev}: and it comes back`);
    await tap('[data-mode="select"]');
    ok(await p.locator('#notePad').isHidden(), `${dev}: piano goes away with note input`);
    // the piano outside note input: opened from the Keyboard button, a key re-pitches the selected note and moves on
    if (dev.startsWith('iPad')) {
      ok(await p.locator('#btnPad').isVisible() && await p.locator('#notePad').isHidden(), `${dev}: in Select the piano waits behind the Keyboard button`);
      await tap('#btnPad');
      const first = await p.evaluate(() => { const S = window.__ms.S; const e = S.score.voiceEvents(0, 5, '1', null).filter((x) => !x.rest); S.sel = e[0].el; window.__ms.redraw(); return [e[0].el === S.sel, e[1].chord[0].pitch.step]; });
      await tap('.pk.black >> nth=0');
      const r2 = await p.evaluate(() => { const S = window.__ms.S; const e = S.score.voiceEvents(0, 5, '1', null).filter((x) => !x.rest); return { p: e[0].chord[0].pitch, next: S.sel === e[1].el }; });
      ok(r2.p.alter !== 0 && r2.next, `${dev}: a black key re-pitches the selected note (${JSON.stringify(r2.p)}) and selects the next`);
      await tap('#notePad [data-p="hide"]');
    }
    // copy bar 2 and paste it over bar 4 from the Bar menu (touch only, no keyboard)
    if (dev.startsWith('iPad')) {
      const sig = (mi) => p.evaluate((mi) => { const s = window.__ms.S.score; return s.parts.map((pp, pi) => s.events(pi, mi).map((e) => (e.rest ? 'r' : e.chord.map((c) => c.pitch.step + c.pitch.octave).join('+')) + e.type).join(' ')).join('|'); }, mi);
      await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.measures = new Set([1]); window.__ms.redraw(); });
      await tap('#btnBar'); await tap('[data-bar="copy"]');
      await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.measures = new Set([3]); window.__ms.redraw(); });
      await tap('#btnBar'); await tap('[data-bar="paste"]');
      ok(await sig(3) === await sig(1), `${dev}: Bar menu copies and pastes a bar`);
      const oc = () => p.evaluate(() => window.__ms.S.score.events(0, 3).filter((e) => !e.rest).flatMap((e) => e.chord.map((c) => c.pitch.octave)).join());
      const before = await oc();
      await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.barStaff = null; S.measures = new Set([3]); window.__ms.redraw(); });
      await tap('#btnBar'); await tap('[data-bar="octdown"]');
      ok((await oc()) === before.split(',').map((o) => +o - 1).join(), `${dev}: Bar menu moves a bar down an octave`);
    }
    ok(!errs.length, `${dev}: no page errors ${errs.join('; ')}`);
    await ctx.close();
  }
  await b.close(); srv.close();
  if (fails.length) { console.log('\nFAILED:\n' + fails.join('\n')); process.exit(1); }
  console.log('\nall passed');
})();
