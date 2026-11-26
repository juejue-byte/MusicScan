// Pinch to zoom on an emulated iPad (two-finger CDP touches), a pinch that starts on a note does not move it, and
// Ctrl + wheel zoom on a desktop browser. Usage: node tests/zoom.js [outDir]   (serves web/ itself; non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');
const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/zoom';
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
  const xml = fs.readFileSync(path.join(ROOT, 'bench/data/bach_bwv66.musicxml'), 'utf8');
  // iPad
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'] });
  const p = await ctx.newPage();
  const errs = []; p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  await p.evaluate((x) => window.__ms.openScore(x), xml);
  await p.waitForTimeout(300);
  const cdp = await ctx.newCDPSession(p);
  const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i + 1 })) });
  async function pinch(c, from, to, firstOn = null) {
    const a0 = firstOn || [c.x - from, c.y];
    await touch('touchStart', [a0]);
    await touch('touchStart', [a0, [c.x + from, c.y]]);
    for (let i = 1; i <= 8; i++) { const d = from + (to - from) * i / 8; await touch('touchMove', [[c.x - d, c.y], [c.x + d, c.y]]); await p.waitForTimeout(16); }
    await touch('touchEnd', []);
    await p.waitForTimeout(250);
  }
  const box = await p.locator('#scoreScroll').boundingBox();
  const c = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  const z0 = await p.evaluate(() => window.__ms.S.zoom);
  await pinch(c, 60, 120);
  const z1 = await p.evaluate(() => window.__ms.S.zoom);
  ok(z1 > z0 * 1.6, `pinch out zooms in (${z0} -> ${z1})`);
  await p.screenshot({ path: OUT + '/pinched.png' });
  await pinch(c, 120, 60);
  const z2 = await p.evaluate(() => window.__ms.S.zoom);
  ok(z2 < z1 * 0.7, `pinch in zooms out (${z1} -> ${z2})`);
  // a pinch whose first finger lands on a note: the note keeps its pitch, nothing goes on the undo stack
  const n = await p.evaluate(() => { const L = window.__ms.S.layout; const q = L.notes.find((x) => !x.ghost && !x.ev.rest && x.ev.mi === 2); const r = L.svg.getBoundingClientRect(); const k = r.width / L.width; const c0 = q.ev.chord[0].pitch; const idx = c0.octave * 7 + 'CDEFGAB'.indexOf(c0.step); return { x: r.left + (q.vf.getAbsoluteX() + 6) * k, y: r.top + (q.stave.getYForLine(0) + (q.top - idx) * 5) * k, p: c0.step + c0.octave, el: [...document.querySelectorAll('x')].length }; });
  const xmlBefore = await p.evaluate(() => window.__ms.S.score.toXML());
  const undo0 = await p.evaluate(() => window.__ms.S.undo.length);
  await pinch({ x: n.x + 60, y: n.y + 40 }, 60, 100, [n.x, n.y]);
  ok(await p.evaluate(() => window.__ms.S.score.toXML()) === xmlBefore && await p.evaluate(() => window.__ms.S.undo.length) === undo0, 'a pinch starting on a note leaves the score alone');
  // in note input, a pinch does not write a note
  await p.evaluate(() => window.__ms.S.mode !== 'add' && document.querySelector('[data-mode="add"]').click());
  await pinch(c, 100, 60);
  ok(await p.evaluate(() => window.__ms.S.score.toXML()) === xmlBefore, 'a pinch in note input writes nothing');
  ok(!errs.length, 'no page errors ' + errs.join('; '));
  await ctx.close();
  // desktop: Ctrl + wheel
  const d = await b.newPage({ viewport: { width: 1440, height: 900 } });
  await d.goto(base);
  await d.evaluate((x) => window.__ms.openScore(x), xml);
  await d.waitForTimeout(300);
  const w0 = await d.evaluate(() => window.__ms.S.zoom);
  await d.mouse.move(700, 500);
  await d.keyboard.down('Control');
  for (let i = 0; i < 5; i++) await d.mouse.wheel(0, -20);
  await d.keyboard.up('Control');
  await d.waitForTimeout(400);
  const w1 = await d.evaluate(() => window.__ms.S.zoom);
  ok(w1 > w0 * 1.3, `Ctrl + wheel zooms (${w0} -> ${w1})`);
  await b.close(); srv.close();
  if (fails.length) { console.log('\nFAILED:\n' + fails.join('\n')); process.exit(1); }
  console.log('\nall passed');
})();
