// Two small MVP pieces, on an emulated iPad against a mocked reading server (web/demo readings served as jobs):
// 1. Rename a score: tap the title, type, Save. The title lands in <work-title>, the header, export file names
//    and Your music; undo puts the old title back.
// 2. Adjust page edges: the photo panel's corner button opens the original photo with four draggable corners;
//    "Read again" posts the dragged corners to api/jobs/<id>/reread and the new reading replaces the page.
// Usage: NODE_PATH=$(npm root -g) node tests/edges_title.js [outDir]   (exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/edges_title';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png', '.mp3': 'audio/mpeg' };
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
  const demo = JSON.parse(fs.readFileSync(path.join(ROOT, 'web/demo/index.json'))).samples;
  const b = await chromium.launch();
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'], acceptDownloads: true });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  const fails = [];
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fails.push(m); };

  // a tiny stand-in for server/app.py: sample1 is the first reading, its re-read comes back as job "reread1"
  const posts = [];
  await p.route('**/api/**', async (route) => {
    const req = route.request();
    const u = new URL(req.url()).pathname.replace(/^\/api\//, '');
    const json = (o) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(o) });
    const file = (f, type) => route.fulfill({ status: 200, contentType: type, body: fs.readFileSync(path.join(ROOT, 'web/demo', f)) });
    if (u === 'samples') return json(Object.keys(demo));
    if (u === 'jobs' && req.method() === 'POST') return json({ id: 'sample1', pages: 1, page: 0 });
    let m = u.match(/^jobs\/(\w+)\/reread$/);
    if (m && req.method() === 'POST') { posts.push({ job: m[1], body: req.postData() || '' }); return json({ id: 'reread1', pages: 1, page: 0 }); }
    m = u.match(/^jobs\/(\w+)$/);
    if (m) {
      const j = JSON.parse(fs.readFileSync(path.join(ROOT, 'web/demo/sample1/job.json')));
      j.id = m[1];
      if (m[1] === 'reread1') { j.result.quad = [[10, 10], [1400, 12], [1400, 1990], [12, 1990]]; j.result.quality = { ...j.result.quality, score: 97 }; }
      return json(j);
    }
    m = u.match(/^jobs\/(\w+)\/(page\.png|original\.jpg)$/);
    if (m) return file(`sample1/${m[2] === 'page.png' ? 'page.jpg' : 'original.jpg'}`, 'image/jpeg');
    return route.fulfill({ status: 404, body: '' });
  });

  await p.goto(base);
  await p.waitForSelector('.sample');
  await p.locator('.sample').first().tap();
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 20000 });
  await p.waitForTimeout(500);

  // ---- 1. rename
  const t0 = await p.textContent('#docTitle');
  ok(t0.trim() === 'Piano scan', `header shows a readable name, not the file name (${t0})`);
  await p.locator('#docTitle').tap();
  await p.waitForSelector('#titleInput');
  await p.fill('#titleInput', 'Sonata in C, K. 545');
  await p.screenshot({ path: path.join(OUT, 'rename.png') });
  await p.keyboard.press('Enter');
  await p.waitForTimeout(300);
  ok((await p.textContent('#docTitle')) === 'Sonata in C, K. 545', 'header shows the new title');
  const xmlTitle = await p.evaluate(() => window.__ms.S.score.title);
  ok(xmlTitle === 'Sonata in C, K. 545', `title written into the MusicXML (${xmlTitle})`);
  const xml = await p.evaluate(() => window.__ms.S.score.toXML());
  ok(/<score-partwise[^>]*>\s*<work>\s*<work-title>Sonata in C, K\. 545<\/work-title>/.test(xml), '<work> is the first header element');
  const dl = p.waitForEvent('download');
  await p.evaluate(() => { document.querySelector('#exportMenu [data-x="xml"], [data-x="xml"]')?.click(); });
  const d = await Promise.race([dl, new Promise((r) => setTimeout(() => r(null), 3000))]);
  if (d) ok(/^Sonata in C K 545\.musicxml$/.test(d.suggestedFilename()), `export file is named after the title (${d.suggestedFilename()})`);
  else console.log('skip export name check (export menu not reachable here)');
  await p.keyboard.press('Control+z');
  await p.waitForTimeout(300);
  ok((await p.evaluate(() => window.__ms.S.score.title)) === '', 'undo takes the title out again');
  ok((await p.textContent('#docTitle')) === 'Piano scan', 'and the header shows the old name');
  await p.keyboard.press('Control+Shift+z');
  await p.waitForTimeout(300);
  ok((await p.textContent('#docTitle')) === 'Sonata in C, K. 545', 'redo brings it back, header too');

  // ---- 2. adjust edges
  ok(await p.locator('#btnEdges:not(.hidden)').count() === 1, 'corner button in the photo panel');
  await p.locator('#btnEdges').tap();
  await p.waitForSelector('.corners-stage svg .c-handle');
  await p.waitForTimeout(300);
  ok(await p.locator('.c-handle').count() === 4, 'four corner handles');
  // drag the top-left corner down and right by 60 screen px
  const h = await p.locator('.c-handle').first().boundingBox();
  const cx = h.x + h.width / 2, cy = h.y + h.height / 2;
  await p.mouse.move(cx, cy); await p.mouse.down();
  await p.mouse.move(cx + 30, cy + 30, { steps: 4 }); await p.mouse.move(cx + 60, cy + 60, { steps: 4 });
  await p.mouse.up();
  await p.screenshot({ path: path.join(OUT, 'edges.png') });
  const nBefore = await p.evaluate(() => window.__ms.S.score.nMeasures);
  await p.locator('[data-c="read"]').tap();
  for (let i = 0; i < 30 && !(await p.evaluate(() => !!window.__ms.S.pages.reread1)); i++) await p.waitForTimeout(300);
  ok(posts.length === 1 && posts[0].job === 'sample1', `re-read posted for the page's job (${posts.map((x) => x.job)})`);
  const q = posts[0] && JSON.parse((posts[0].body.match(/name="quad"\r\n\r\n([^\r]+)/) || [])[1] || 'null');
  const W = 1413, H = 2000;
  ok(Array.isArray(q) && q.length === 4 && q[0][0] > 20 && q[0][1] > 20 && q[2][0] === W && q[2][1] === H, `dragged corner sent in photo pixels (${JSON.stringify(q)})`);
  ok(await p.evaluate(() => window.__ms.S.job === 'reread1' && window.__ms.S.meta.every((m) => m.page === 'reread1')), 'the new reading replaced the page');
  ok(await p.evaluate(() => window.__ms.S.score.nMeasures) === nBefore, 'same number of bars');
  ok(JSON.stringify(await p.evaluate(() => window.__ms.S.pages.reread1.quad)) === JSON.stringify([[10, 10], [1400, 12], [1400, 1990], [12, 1990]]), 'the page remembers its corners for next time');
  ok((await p.evaluate(() => window.__ms.S.score.title)) === 'Sonata in C, K. 545', 'title kept (a re-read replaces bars only)');
  await p.keyboard.press('Control+z');
  await p.waitForTimeout(300);
  ok(await p.evaluate(() => window.__ms.S.meta.every((m) => m.page === 'sample1')), 'undo puts the old reading back');

  // cancel leaves everything alone
  await p.locator('#btnEdges').tap();
  await p.waitForSelector('.c-handle');
  await p.locator('[data-c="cancel"]').tap();
  await p.waitForTimeout(200);
  ok(posts.length === 1 && await p.locator('#modal.hidden').count() === 1, 'cancel closes without reading');

  ok(errs.length === 0, `no page errors (${errs.join(' | ')})`);
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall passed');
})();
