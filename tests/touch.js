// Touch editing on an emulated iPhone, with a fake iOS bridge: drag a note up with a finger, swap sideways,
// write a note in Add mode (ghost follows the finger, the note lands on lift), export through the share sheet.
// Usage: node tests/touch.js http://localhost:8000/ bench/data/bach_bwv66.musicxml [outDir]
const { chromium, devices } = require('playwright');
const fs = require('fs');
(async () => {
  const [base, file, out = '/tmp/touch'] = process.argv.slice(2);
  fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPhone 13'] });
  // stand-in for ios/MusicScan/WebView.swift's message handler
  await ctx.addInitScript(() => {
    window.__bridge = [];
    window.webkit = { messageHandlers: { musicscan: { postMessage: (m) => {
      window.__bridge.push(m.cmd === 'share' ? { ...m, b64: m.b64.length } : m);
      if (m.id) setTimeout(() => window.__msNativeReply(m.id, {}), 10);
    } } } };
  });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const ui = await p.evaluate(() => ({ native: document.documentElement.classList.contains('native'), cam: document.querySelector('#cameraInput').closest('label').textContent.trim(), server: !!document.querySelector('.server-link') }));
  await p.screenshot({ path: out + '/01_upload.png' });
  await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(file, 'utf8'));
  await p.waitForTimeout(500);
  const cdp = await ctx.newCDPSession(p);
  const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
  async function drag(x, y, dx, dy, steps = 20) {
    await touch('touchStart', x, y);
    for (let i = 1; i <= steps; i++) { await touch('touchMove', x + (dx * i) / steps, y + (dy * i) / steps); await p.waitForTimeout(8); }
    await touch('touchEnd');
  }
  const noteAt = (k) => p.evaluate((k) => {
    const L = window.__ms.S.layout; const ns = L.notes.filter((n) => !n.ghost && !n.ev.rest && n.ev.pi === 0).sort((a, b) => a.ev.mi - b.ev.mi || a.ev.onset - b.ev.onset);
    const n = ns[k]; const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width;
    const c = n.ev.chord[0]; const idx = c.pitch.octave * 7 + 'CDEFGAB'.indexOf(c.pitch.step);
    return { x: r.left + (n.vf.getAbsoluteX() + 6) * sx, y: r.top + (n.stave.getYForLine(0) + (n.top - idx) * 5) * sx, name: c.pitch.step + c.pitch.octave, mi: n.ev.mi };
  }, k);
  const selName = () => p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.chord.some((c) => c.el === S.sel)); return n ? n.ev.chord.map((c) => c.pitch.step + c.pitch.octave).join(',') : null; });
  const res = { ui };

  // 1. finger lands slightly off the note head (10 px low): it should still grab it; drag up ~3 steps
  const n0 = await noteAt(2);
  const scrollPos = () => p.evaluate(() => { const e = document.querySelector('.score-scroll'); return [e.scrollLeft, e.scrollTop, window.scrollX, window.scrollY].join(','); });
  const scrollBefore = await scrollPos();
  await drag(n0.x + 6, n0.y + 7, 0, -26);
  res.drag = [n0.name, await selName()];
  res.scrolled = [scrollBefore, await scrollPos()];
  await p.screenshot({ path: out + '/02_after_drag.png' });

  // 2. sideways swap with the next note
  const a = await noteAt(0), bnext = await noteAt(1);
  await drag(a.x, a.y, bnext.x - a.x + 6, 0, 14);
  res.swap = [a.name, bnext.name, (await noteAt(0)).name, (await noteAt(1)).name];

  // 3. Add mode: touch empty staff, slide, lift -> one new note
  await p.evaluate(() => document.querySelector('[data-mode="add"]').click());
  const before = await p.evaluate(() => window.__ms.S.score.events(0, 1).length);
  const m1 = await p.evaluate(() => { const L = window.__ms.S.layout; const st = L.staves.find((s) => s.mi === 1 && s.pi === 0); const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width; return { x: r.left + (st.x1 - 8) * sx, y: r.top + (st.top + 20) * sx }; });
  await touch('touchStart', m1.x, m1.y);
  await touch('touchMove', m1.x, m1.y - 6);
  const ghost = await p.evaluate(() => !!document.querySelector('#overlay .ghost'));
  await p.screenshot({ path: out + '/03_add_ghost.png' });
  await touch('touchEnd');
  res.add = { ghostWhileTouching: ghost, eventsBefore: before, eventsAfter: await p.evaluate(() => window.__ms.S.score.events(0, 1).length), undo: await p.evaluate(() => window.__ms.S.undo.length) };

  // 4. export goes to the share sheet
  await p.evaluate(() => document.querySelector('[data-mode="select"]').click());
  await p.evaluate(() => document.querySelector('#exportMenu [data-x="xml"]').click());
  await p.waitForTimeout(100);
  const br = await p.evaluate(() => window.__bridge);
  res.bridge = { haptics: br.filter((m) => m.cmd === 'haptic').length, share: br.find((m) => m.cmd === 'share') || null };
  await p.screenshot({ path: out + '/04_end.png' });
  res.errors = errs;
  console.log(JSON.stringify(res, null, 1));
  await b.close();
})();
