// Live photo check (web/js/capture.js): grades the sample photos like the server would (crisp scan passes,
// the blurry dark photo is flagged dark and soft, a blurred scan is flagged blurry), and on an emulated iPad with
// a fake camera the camera view opens from "Take a photo", shows the checks, closes on Escape, and the shutter
// sends a photo to the reader.
// Usage: node tests/capture.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/capture_ui';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
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
  const b = await chromium.launch({ args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const fails = [];
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fails.push(m); };

  // 1. the grader on the sample photos, drawn at the 480 px the camera view uses
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'], permissions: ['camera'] });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  await p.waitForSelector('.sample');
  const grades = await p.evaluate(async () => {
    const { grade } = await import('/js/capture.js');
    const out = {};
    for (const [name, blur] of [['1_Piano_scan.jpg', 0], ['1_Piano_scan.jpg', 2], ['4_Blurry_dark_photo.jpg', 0], ['2_Phone_photo_with_pen_marks.jpg', 0]]) {
      const img = new Image(); img.src = '/samples/' + name; await img.decode();
      const k = 480 / Math.max(img.width, img.height);
      const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
      const x = c.getContext('2d'); if (blur) x.filter = `blur(${blur}px)`; x.drawImage(img, 0, 0, c.width, c.height);
      const d = x.getImageData(0, 0, c.width, c.height).data, g = new Uint8ClampedArray(c.width * c.height);
      for (let i = 0, j = 0; j < g.length; i += 4, j++) g[j] = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
      const r = grade(g, c.width, c.height, null);
      out[name + (blur ? ' blurred' : '')] = { ok: r.ok, levels: Object.fromEntries(r.checks.map((q) => [q.id, q.level])), stats: r.stats };
    }
    return out;
  });
  for (const [k, v] of Object.entries(grades)) console.log('     ', k, JSON.stringify(v));
  ok(grades['1_Piano_scan.jpg'].ok, 'a crisp scan passes every check');
  ok(grades['1_Piano_scan.jpg blurred'].levels.still !== 'ok', 'a blurred scan is flagged soft or blurry');
  ok(grades['4_Blurry_dark_photo.jpg'].levels.light !== 'ok', 'the dark photo is flagged dark');
  ok(grades['4_Blurry_dark_photo.jpg'].levels.still !== 'ok', 'the blurry photo is flagged soft or blurry');
  ok(grades['2_Phone_photo_with_pen_marks.jpg'].levels.still === 'ok' && grades['2_Phone_photo_with_pen_marks.jpg'].levels.light === 'ok', 'a good phone photo is sharp with good light');

  // 2. the camera view (Chromium's fake camera)
  await p.locator('label.btn.camera').tap();
  await p.waitForSelector('#capture:not(.hidden)', { timeout: 5000 }).catch(() => {});
  ok(await p.locator('#capture:not(.hidden)').count() === 1, 'Take a photo opens the live camera view');
  await p.waitForSelector('.cap-check[data-check]', { timeout: 5000 }).catch(() => {});
  const ids = await p.$$eval('.cap-check[data-check]', (xs) => xs.map((x) => x.dataset.check));
  ok(ids.join() === 'fill,still,light', `three live checks shown (${ids.join()})`);
  await p.screenshot({ path: path.join(OUT, 'ipad_camera.png') });
  await p.keyboard.press('Escape');
  ok(await p.locator('#capture.hidden').count() === 1, 'Escape closes the camera');
  const live = await p.evaluate(() => { const v = document.querySelector('#capture video'); return !!(v && v.srcObject); });
  ok(!live, 'closing stops the camera stream');
  await p.locator('label.btn.camera').tap();
  await p.waitForSelector('.cap-check[data-check]', { timeout: 5000 });
  await p.waitForTimeout(400);
  await p.locator('.cap-shutter').tap();
  await p.waitForFunction(() => !document.querySelector('#toast').classList.contains('hidden') || !document.querySelector('#viewProgress').classList.contains('hidden'), null, { timeout: 5000 }).catch(() => {});
  // in demo mode there is no reading server, so the reader answers with its "preview" toast: the photo did reach it
  const after = await p.evaluate(() => ({ cam: !document.querySelector('#capture').classList.contains('hidden'), name: window.__ms.S.name, toast: document.querySelector('#toast').textContent }));
  ok(!after.cam && after.name === 'camera.jpg' && /preview|reading/i.test(after.toast), `the shutter sends the photo to the reader (${after.name}: ${after.toast.slice(0, 40)})`);
  await ctx.close();

  // 3. phone: chips over the viewfinder
  const ctx2 = await b.newContext({ ...devices['iPhone 14'], permissions: ['camera'] });
  const p2 = await ctx2.newPage();
  p2.on('pageerror', (e) => errs.push(e.message));
  await p2.goto(base);
  await p2.waitForSelector('.sample');
  await p2.locator('label.btn.camera').tap();
  await p2.waitForSelector('.cap-check[data-check]', { timeout: 5000 });
  const box = await p2.locator('.cap-checks').boundingBox();
  ok(box && box.width <= 390 && box.y < 200, 'iPhone: checks sit as chips at the top of the viewfinder');
  await p2.screenshot({ path: path.join(OUT, 'iphone_camera.png') });
  await ctx2.close();

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall capture checks passed');
})();
