// iPad checks with a fake iOS bridge: layout at landscape / portrait / Split View widths, Apple Pencil (hover preview,
// precise note grab, write on lift) and the commands the app sends for ⌘ shortcuts and Pencil double-tap.
// Usage: node tests/ipad.js http://localhost:8000/ bench/data/bach_bwv66.musicxml [outDir]
const { chromium } = require('playwright');
const fs = require('fs');
const UA = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
(async () => {
  const [base, file, out = '/tmp/ipad'] = process.argv.slice(2);
  fs.mkdirSync(out, { recursive: true });
  const xml = fs.readFileSync(file, 'utf8');
  const b = await chromium.launch();
  const res = { layout: {} };
  async function open(w, h) {
    const ctx = await b.newContext({ viewport: { width: w, height: h }, hasTouch: true, isMobile: true, userAgent: UA });
    await ctx.addInitScript(() => {
      window.__bridge = [];
      window.webkit = { messageHandlers: { musicscan: { postMessage: (m) => {
        window.__bridge.push(m.cmd === 'share' ? { ...m, b64: m.b64.length } : m);
        if (m.id) setTimeout(() => window.__msNativeReply(m.id, {}), 10);
      } } } };
    });
    const p = await ctx.newPage();
    p.errs = [];
    p.on('pageerror', (e) => p.errs.push(e.message));
    await p.goto(base);
    await p.evaluate((x) => window.__ms.openScore(x), xml);
    await p.waitForTimeout(400);
    return { ctx, p };
  }
  for (const [name, w, h] of [['landscape', 1194, 834], ['portrait', 834, 1194], ['split-half', 590, 834], ['slide-over', 375, 834]]) {
    const { ctx, p } = await open(w, h);
    res.layout[name] = await p.evaluate(() => {
      const tb = document.querySelector('.toolbar');
      return { pageScrollsSideways: document.documentElement.scrollWidth > innerWidth, toolbarHidden: tb.scrollWidth > tb.clientWidth + 1 };
    });
    await p.screenshot({ path: `${out}/${name}.png` });
    await ctx.close();
  }

  const { ctx, p } = await open(1194, 834);
  const cdp = await ctx.newCDPSession(p);
  const pen = (type, x, y, buttons = 1) => cdp.send('Input.dispatchMouseEvent', { type, x, y, pointerType: 'pen', button: type === 'mouseMoved' ? 'none' : 'left', buttons, clickCount: 1 });
  const notePt = () => p.evaluate(() => {
    const L = window.__ms.S.layout; const n = L.notes.find((q) => !q.ghost && !q.ev.rest && q.ev.pi === 0);
    const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width; const c = n.ev.chord[0];
    const idx = c.pitch.octave * 7 + 'CDEFGAB'.indexOf(c.pitch.step);
    return { x: r.left + (n.vf.getAbsoluteX() + 6) * sx, y: r.top + (n.stave.getYForLine(0) + (n.top - idx) * 5) * sx, name: c.pitch.step + c.pitch.octave };
  });
  const sel = () => p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((q) => q.ev.chord.some((c) => c.el === S.sel)); return n ? n.ev.chord[0].pitch.step + n.ev.chord[0].pitch.octave : null; });
  // Pencil 12 px beside a note head: precise, so it does not grab the note (a finger would)
  const n0 = await notePt();
  await pen('mousePressed', n0.x + 30, n0.y + 12); await pen('mouseReleased', n0.x + 30, n0.y + 12, 0);
  res.penOffNoteSelects = await sel();
  // Pencil on the note, drag up 10 px: 2 steps (mouse-like travel)
  await pen('mousePressed', n0.x, n0.y);
  for (let i = 1; i <= 10; i++) await pen('mouseMoved', n0.x, n0.y - i);
  await pen('mouseReleased', n0.x, n0.y - 10, 0);
  res.penDrag = [n0.name, await sel()];
  // Pencil double-tap (sent by the app) switches to Add notes; hovering shows the ghost; lifting writes the note
  await p.evaluate(() => window.__msCommand('toggle-mode'));
  res.modeAfterDoubleTap = await p.evaluate(() => window.__ms.S.mode);
  const m1 = await p.evaluate(() => { const L = window.__ms.S.layout; const st = L.staves.find((s) => s.mi === 1 && s.pi === 0); const r = L.svg.getBoundingClientRect(); const sx = r.width / L.width; return { x: r.left + (st.x1 - 8) * sx, y: r.top + (st.top + 20) * sx }; });
  await pen('mouseMoved', m1.x, m1.y, 0);
  res.hoverGhost = await p.evaluate(() => !!document.querySelector('#overlay .ghost'));
  const before = await p.evaluate(() => window.__ms.S.score.events(0, 1).length);
  await pen('mousePressed', m1.x, m1.y); await pen('mouseMoved', m1.x, m1.y - 5); await pen('mouseReleased', m1.x, m1.y - 5, 0);
  res.penAdd = [before, await p.evaluate(() => window.__ms.S.score.events(0, 1).length)];
  await p.screenshot({ path: `${out}/pencil-add.png` });
  // ⌘ shortcuts arrive as commands
  const undoBefore = await p.evaluate(() => window.__ms.S.undo.length);
  await p.evaluate(() => window.__msCommand('undo'));
  res.cmdUndo = [undoBefore, await p.evaluate(() => window.__ms.S.undo.length)];
  await p.evaluate(() => window.__msCommand('mode-select'));
  await p.evaluate(() => window.__msCommand('export-mid'));
  await p.waitForTimeout(100);
  res.cmdExport = await p.evaluate(() => window.__bridge.filter((m) => m.cmd === 'share').map((m) => m.name));
  res.errors = p.errs;
  console.log(JSON.stringify(res, null, 1));
  await b.close();
})();
