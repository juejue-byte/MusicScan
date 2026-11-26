// Markup checks in a real browser: typed markings (dynamics, hairpins, fingering, text, rehearsal marks) written as
// MusicXML and drawn on the score, and freehand ink on its own layer (Pencil strokes, eraser, undo, hide, bar edits,
// saved inside the exported MusicXML). Usage:
//   node tests/markup.js [outDir]            (serves web/ itself)
// outDir gets screenshots and the exported files (validate them against the MusicXML 4.0 XSD).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const UA = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

function serve() {
  const types = { '.js': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
  const web = path.join(ROOT, 'web');
  const srv = http.createServer((req, res) => {
    const p = path.join(web, decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(web) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((done) => srv.listen(0, '127.0.0.1', () => done(srv)));
}

(async () => {
  const [out = '/tmp/markup'] = process.argv.slice(2);
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  fs.mkdirSync(out, { recursive: true });
  const fails = [];
  const ok = (cond, msg) => { if (!cond) fails.push(msg); console.log((cond ? 'ok   ' : 'FAIL ') + msg); };
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1194, height: 834 }, hasTouch: true, userAgent: UA, deviceScaleFactor: 2 });
  await ctx.addInitScript(() => { window.__bridge = []; window.webkit = { messageHandlers: { musicscan: { postMessage: (m) => { window.__bridge.push(m); if (m.id) setTimeout(() => window.__msNativeReply(m.id, {}), 10); } } } }; });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const open = async (file) => { await p.evaluate((x) => window.__ms.openScore(x), fs.readFileSync(path.join(ROOT, file), 'utf8')); await p.waitForTimeout(300); };
  const S = (fn, arg) => p.evaluate(fn, arg);

  // 1. markings already in a file are drawn: dynamics and hairpins in the Weber clarinet part
  await open('bench/data/weber_clarinet.musicxml');
  const w = await S(() => { const L = window.__ms.S.layout; const k = {}; for (const h of L.marks) k[h.mark.kind] = (k[h.mark.kind] || 0) + 1; return k; });
  ok(w.dynamics >= 10 && w.wedge >= 8, `existing dynamics and hairpins are drawn (${JSON.stringify(w)})`);
  await p.screenshot({ path: `${out}/existing_marks.png` });

  // 2. typed markings through the Marks menu on a piano score
  await open('bench/data/mozart_k545.musicxml');
  const pt = (sel) => S((sel) => {
    const L = window.__ms.S.layout; const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width;
    const n = L.notes.filter((q) => !q.ghost && !q.ev.rest && q.ev.pi === 0 && q.ev.staff === '1')[sel];
    const c = n.ev.chord[0]; const idx = c.pitch.octave * 7 + 'CDEFGAB'.indexOf(c.pitch.step);
    return { x: r.left + (n.vf.getAbsoluteX() + 6) * sx, y: r.top + (n.stave.getYForLine(0) + (n.top - idx) * 5) * sx };
  }, sel);
  const tapNote = async (i) => { const q = await pt(i); await p.mouse.click(q.x, q.y); await p.waitForTimeout(80); };
  const menu = async (mk, v) => {
    await p.click('#btnMarks');
    await p.click(`#marksMenu button[data-mk="${mk}"]${v !== undefined ? `[data-v="${v}"]` : ''}`);
    await p.waitForTimeout(80);
  };
  await tapNote(0);
  await menu('dyn', 'p');
  await menu('finger', '3');
  await menu('rehearsal');
  await tapNote(4);
  await menu('words', 'dolce');
  await menu('dyn', 'mf');
  await menu('dyn', 'f'); // replaces the mf on the same note
  await tapNote(2);
  await menu('wedge', 'crescendo');
  let x = await S(() => window.__ms.S.score.toXML());
  const count = (re) => (x.match(re) || []).length;
  ok(count(/<dynamics><p\/><\/dynamics>/g) === 1 && count(/<dynamics><f\/><\/dynamics>/g) === 1 && count(/<dynamics><mf\/>/g) === 0, 'dynamics p and f written, mf replaced by f');
  ok(count(/<fingering>3<\/fingering>/g) === 1, 'fingering written in notations/technical');
  ok(/<rehearsal enclosure="square">A<\/rehearsal>/.test(x), 'rehearsal mark A written');
  ok(/<words font-style="italic">dolce<\/words>/.test(x), 'text written as words');
  ok(count(/<wedge type="crescendo" number="1"\/>/g) === 1 && count(/<wedge type="stop" number="1"\/>/g) === 1, 'hairpin start and stop written');
  const drawn = await S(() => window.__ms.S.layout.marks.map((h) => h.mark.kind).sort().join(','));
  ok(drawn === 'dynamics,dynamics,fingering,rehearsal,wedge,words', `all of them are drawn (${drawn})`);
  // playback still sees the same notes
  const evs = await S(() => window.__ms.S.score.playEvents().events.length);
  ok(evs > 50, `playback reads the score with markings (${evs} events)`);
  await p.screenshot({ path: `${out}/typed_marks.png` });
  fs.writeFileSync(`${out}/typed_marks.musicxml`, x);

  // select a marking by tapping it, change it, delete it, undo
  const hitOf = (kind) => S((kind) => { const L = window.__ms.S.layout; const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width; const h = L.marks.find((q) => q.mark.kind === kind); return h && { x: r.left + ((h.x0 + h.x1) / 2) * sx, y: r.top + ((h.y0 + h.y1) / 2) * sx }; }, kind);
  const d = await hitOf('words');
  await p.mouse.click(d.x, d.y);
  ok(await S(() => window.__ms.S.selMark?.localName === 'direction'), 'tapping text selects it');
  await p.keyboard.press('Delete');
  ok(!/dolce/.test(await S(() => window.__ms.S.score.toXML())), 'Delete removes the selected marking');
  await p.keyboard.press('Control+z');
  ok(/dolce/.test(await S(() => window.__ms.S.score.toXML())), 'undo brings it back');
  const wd = await hitOf('wedge');
  await p.mouse.click(wd.x, wd.y);
  await p.keyboard.press('Delete');
  x = await S(() => window.__ms.S.score.toXML());
  ok(!/<wedge/.test(x), 'deleting a hairpin removes both of its ends');
  await p.keyboard.press('Control+z');

  // 3. ink: a Pencil stroke, a finger that scrolls, the eraser, undo, hide, bar insert, export and reopen
  await p.click('[data-mode="ink"]');
  ok(await S(() => document.body.classList.contains('ink-mode') && getComputedStyle(document.querySelector('.durs')).display === 'none'), 'Ink mode hides the note tools');
  ok(await S(() => document.querySelector('.toolbar').offsetHeight < 70), 'the Ink toolbar fits on one row in iPad landscape');
  const cdp = await ctx.newCDPSession(p);
  const pen = (type, x, y, buttons = 1, force = 0.6) => cdp.send('Input.dispatchMouseEvent', { type, x, y, pointerType: 'pen', button: type === 'mouseMoved' ? 'none' : 'left', buttons, clickCount: 1, force });
  const xml0 = await S(() => window.__ms.S.score.toXML());
  const q0 = await pt(6);
  await pen('mousePressed', q0.x - 30, q0.y - 40);
  for (let i = 1; i <= 24; i++) await pen('mouseMoved', q0.x - 30 + i * 3, q0.y - 40 + Math.sin(i / 3) * 8, 1, 0.2 + i / 40);
  await pen('mouseReleased', q0.x + 42, q0.y - 40, 0);
  await p.waitForTimeout(80);
  let st = await S(() => { const f = [...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')].find((e) => e.getAttribute('name') === 'musicscan-ink'); return f ? JSON.parse(f.textContent).strokes : []; });
  ok(st.length === 1 && st[0].p.length > 10, `a Pencil stroke is stored (${st.length} stroke, ${st[0]?.p.length} points)`);
  ok(new Set(st[0].p.map((q) => q[2])).size > 3, 'the stroke keeps the Pencil pressure');
  const notesSame = await S((x0) => { const strip = (s) => s.replace(/<identification>[\s\S]*?<\/identification>/, ''); return strip(window.__ms.S.score.toXML()) === strip(x0); }, xml0);
  ok(notesSame, 'ink leaves every note untouched');
  ok(await S(() => document.querySelectorAll('#ink .ink-stroke').length === 1), 'the stroke is drawn on the ink layer');
  // a finger now scrolls instead of drawing
  await p.touchscreen.tap(q0.x, q0.y + 30);
  ok((await S(() => JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes.length)) === 1, 'after the Pencil, a finger does not draw');
  // highlighter, then the eraser rubs out only the stroke it touches
  await p.click('[data-pen="hl"]');
  await pen('mousePressed', q0.x - 20, q0.y + 60);
  for (let i = 1; i <= 10; i++) await pen('mouseMoved', q0.x - 20 + i * 8, q0.y + 60);
  await pen('mouseReleased', q0.x + 60, q0.y + 60, 0);
  ok(await S(() => { const l = JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes; return l[1]?.tool === 'hl' && l[1].c === '#facc15'; }), 'the highlighter draws a yellow highlight');
  await p.click('[data-pen="red"]');
  await p.screenshot({ path: `${out}/ink.png` });
  await p.evaluate(() => window.__msCommand('toggle-mode')); // Pencil double-tap: eraser
  ok(await S(() => window.__ms.S.eraser), 'Pencil double-tap in Ink mode picks the eraser');
  await pen('mousePressed', q0.x + 20, q0.y + 54);
  await pen('mouseMoved', q0.x + 22, q0.y + 60);
  await pen('mouseMoved', q0.x + 24, q0.y + 66);
  await pen('mouseReleased', q0.x + 24, q0.y + 66, 0);
  st = await S(() => JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes);
  ok(st.length === 1 && st[0].tool === 'pen', 'the eraser removed the highlight and kept the pen stroke');
  await p.keyboard.press('Control+z');
  ok((await S(() => JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes.length)) === 2, 'undo brings the erased stroke back');
  await p.evaluate(() => window.__msCommand('toggle-mode'));
  ok(await S(() => !window.__ms.S.eraser), 'double-tap again: back to the pen');
  // ink survives reflow and follows its bar when a bar is inserted before it
  const before = await S(() => { const s = JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes[0]; return s.mi; });
  await p.click('[data-act="ink-done"]');
  await S((mi) => { window.__ms.S.measures = new Set([0]); window.__ms.redraw(); }, before);
  await p.keyboard.press('Shift+I');
  const after = await S(() => JSON.parse([...window.__ms.S.score.doc.querySelectorAll('miscellaneous-field')][0].textContent).strokes[0].mi);
  ok(after === before + 1, `ink follows its bar when a bar is inserted (${before} -> ${after})`);
  await p.keyboard.press('Control+z');
  // hide and show
  await p.click('#btnInkVis');
  ok(await S(() => getComputedStyle(document.querySelector('#ink')).display === 'none'), 'Ink: hidden hides the layer');
  await p.click('#btnInkVis');
  ok(await S(() => getComputedStyle(document.querySelector('#ink')).display !== 'none'), 'Ink: shown shows it again');
  // export keeps ink and markings; reopening the file brings the ink back
  x = await S(() => window.__ms.S.score.toXML());
  fs.writeFileSync(`${out}/with_ink.musicxml`, x);
  await p.evaluate((xx) => window.__ms.openScore(xx), x);
  await p.waitForTimeout(200);
  ok(await S(() => document.querySelectorAll('#ink .ink-stroke').length === 2), 'reopening the exported MusicXML restores the ink');
  // narrower screen (iPad portrait): ink is still drawn on its bar
  await p.setViewportSize({ width: 834, height: 1194 });
  await p.waitForTimeout(400);
  ok(await S(() => document.querySelectorAll('#ink .ink-stroke').length === 2 && window.__ms.S.inkPlaced.filter(Boolean).length === 2), 'ink reflows with the score at portrait width');
  await p.screenshot({ path: `${out}/ink_portrait.png` });
  ok(await S(() => document.documentElement.scrollWidth <= innerWidth), 'no sideways page scroll in portrait');
  await p.setViewportSize({ width: 1194, height: 834 });
  await p.waitForTimeout(300);
  await p.click('#btnMarks');
  await p.waitForTimeout(100);
  await p.screenshot({ path: `${out}/marks_menu.png` });

  // a touch-only iPad in landscape: the editing toolbar, with Ink and Marks added, still fits one row
  const ctx2 = await b.newContext({ viewport: { width: 1194, height: 834 }, hasTouch: true, isMobile: true, userAgent: UA });
  const p2 = await ctx2.newPage();
  await p2.goto(base);
  await p2.evaluate((xx) => window.__ms.openScore(xx), fs.readFileSync(path.join(ROOT, 'bench/data/mozart_k545.musicxml'), 'utf8'));
  await p2.waitForTimeout(300);
  const tb = await p2.evaluate(() => ({ segs: [...document.querySelector('.toolbar').children].filter((c) => c.offsetWidth).map((c) => c.offsetWidth), cw: document.querySelector('.toolbar').clientWidth, h: document.querySelector('.toolbar').offsetHeight, hidden: document.querySelector('.toolbar').scrollWidth > document.querySelector('.toolbar').clientWidth + 1 }));
  ok(tb.h < 70 && !tb.hidden, `the editing toolbar fits one row on a touch iPad in landscape (${tb.h}px ${JSON.stringify(tb.segs)} of ${tb.cw})`);
  await p2.screenshot({ path: `${out}/ipad_toolbar.png` });
  await ctx2.close();

  ok(!errs.length, 'no page errors' + (errs.length ? ': ' + errs.slice(0, 3).join(' | ') : ''));
  await b.close();
  srv.close();
  if (fails.length) { console.log(`\n${fails.length} check(s) failed`); process.exit(1); }
  console.log('\nall markup checks passed');
})();
