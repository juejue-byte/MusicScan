// End-to-end check of the MusicScan web app in Chromium. Usage: node tests/e2e.js [baseUrl] [outDir]
const { chromium } = require('playwright');
const base = process.argv[2] || 'http://localhost:8000/';
const out = process.argv[3] || '/tmp/e2e';
require('fs').mkdirSync(out, { recursive: true });
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
  const p = await ctx.newPage();
  const errs = [];
  p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errs.push(m.type() + ': ' + m.text()); });
  p.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  await p.goto(base);
  await p.waitForSelector('.sample');
  await p.screenshot({ path: out + '/01_upload.png' });
  await p.click('.sample >> nth=1');
  await p.waitForTimeout(1500);
  await p.screenshot({ path: out + '/02_progress.png' });
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 120000 });
  await p.waitForTimeout(800);
  await p.screenshot({ path: out + '/03_editor.png' });
  const info = await p.evaluate(() => ({ notes: window.__ms.S.layout.notes.length, bars: window.__ms.S.score.nMeasures, banner: document.querySelector('#qualityBanner').innerText }));
  console.log('editor', JSON.stringify(info));
  // click the first real note and drag it up 3 steps
  const pt = await p.evaluate(() => {
    const L = window.__ms.S.layout; const n = L.notes.find((n) => !n.ghost && !n.ev.rest);
    const r = L.svg.getBoundingClientRect(); const k = r.width / L.width;
    const x = n.vf.getAbsoluteX() + 6; const ys = n.ev.chord.map((c) => c.pitch);
    const idx = (ys[0].octave) * 7 + 'CDEFGAB'.indexOf(ys[0].step);
    return { x: r.left + x * k, y: r.top + (n.stave.getYForLine(0) + (n.top - idx) * 5) * k, before: ys.map((q) => q.step + q.octave).join(',') };
  });
  await p.mouse.move(pt.x, pt.y); await p.mouse.down();
  for (let i = 1; i <= 15; i++) await p.mouse.move(pt.x, pt.y - i);
  await p.mouse.up();
  const after = await p.evaluate(() => { const S = window.__ms.S; const n = S.layout.notes.find((n) => n.ev.chord.some((c) => c.el === S.sel)); return n ? n.ev.chord.map((c) => c.pitch.step + c.pitch.octave).join(',') : null; });
  console.log('drag', pt.before, '->', after);
  await p.screenshot({ path: out + '/04_dragged.png' });
  await p.keyboard.press('ArrowDown'); await p.keyboard.press('4'); await p.keyboard.press('+');  // semitone down, eighth, sharp
  console.log('status', await p.textContent('#status'));
  await p.keyboard.press('Control+z'); await p.keyboard.press('Control+z');
  // add mode: click an empty spot in the last bar
  await p.keyboard.press('n');
  const spot = await p.evaluate(() => { const L = window.__ms.S.layout; const st = L.staves.find((s) => s.rowIdx === 1 && s.staff === '1'); document.querySelector('#scoreScroll').scrollTop = st.top - 120; const r = L.svg.getBoundingClientRect(); const k = r.width / L.width; return { x: r.left + (st.x1 - 25) * k, y: r.top + (st.top + 15) * k }; });
  await p.mouse.move(spot.x, spot.y); await p.waitForTimeout(100);
  await p.screenshot({ path: out + '/05_ghost.png' });
  await p.mouse.click(spot.x, spot.y);
  await p.screenshot({ path: out + '/05b_added.png' });
  console.log('after add', await p.textContent('#status'));
  await p.keyboard.press('Escape');
  // select a bar via its number and open rescan
  const num = await p.evaluate(() => { const L = window.__ms.S.layout; const m = L.measures[1]; const r = L.svg.getBoundingClientRect(); const k = r.width / L.width; return { x: r.left + (m.x0 + 8) * k, y: r.top + (m.y0 - 6) * k }; });
  await p.mouse.click(num.x, num.y);
  await p.screenshot({ path: out + '/06_bar_selected.png' });
  await p.click('#btnRescan');
  await p.waitForSelector('[data-m="use"]', { timeout: 120000 });
  await p.waitForTimeout(300);
  await p.screenshot({ path: out + '/07_rescan.png' });
  await p.click('[data-m="use"]');
  console.log('after rescan', await p.textContent('#status'));
  // play
  await p.click('#btnPlay'); await p.waitForTimeout(1500);
  await p.screenshot({ path: out + '/08_playing.png' });
  await p.click('#btnPlay');
  // export
  await p.click('#btnExport');
  const [d1] = await Promise.all([p.waitForEvent('download'), p.click('[data-x="xml"]')]);
  await d1.saveAs(out + '/export.musicxml');
  await p.click('#btnExport');
  const [d2] = await Promise.all([p.waitForEvent('download'), p.click('[data-x="mid"]')]);
  await d2.saveAs(out + '/export.mid');
  // phone layout
  await p.setViewportSize({ width: 390, height: 844 });
  await p.waitForTimeout(500);
  await p.screenshot({ path: out + '/09_phone.png' });
  console.log('errors:\n' + errs.slice(0, 20).join('\n'));
  await b.close();
})();
