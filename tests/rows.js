// Rows as printed: the editor keeps each row of the photo on one line (iPad both ways, iPhone landscape),
// for every demo sample. iPhone upright may wrap a row, but never joins two printed rows.
// Usage: node tests/rows.js     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs'), path = require('path'), http = require('http');
const ROOT = path.resolve(__dirname, '..');
function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png', '.svg': 'image/svg+xml' };
  const srv = http.createServer((req, res) => {
    const p = path.join(ROOT, 'web', decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(path.join(ROOT, 'web')) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}
(async () => {
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/?demo`;
  const b = await chromium.launch();
  const fails = [];
  for (const [dev, exact] of [['iPad Pro 11 landscape', true], ['iPad Pro 11', true], ['iPhone 14 landscape', true], ['iPhone 14', false]]) {
    for (const k of [1, 2, 3, 4]) {
      const ctx = await b.newContext({ ...devices[dev] });
      const p = await ctx.newPage();
      await p.goto(base); await p.waitForSelector('.sample');
      await p.locator(`.sample:nth-of-type(${k})`).first().tap();
      await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 20000 }); await p.waitForTimeout(400);
      const r = await p.evaluate(() => {
        const S = window.__ms.S;
        const printed = [];
        for (let i = 0; i < S.score.nMeasures; i++) { if (i === 0 || S.score.newSystem(i)) printed.push([]); printed[printed.length - 1].push(i); }
        return { printed: printed.map((x) => x.join(',')), shown: S.layout.rows.map((r) => r.measures.map((m) => m.mi).join(',')), zoom: S.zoom };
      });
      const joined = r.shown.some((row) => { const bars = row.split(',').map(Number); return r.printed.filter((pr) => pr.split(',').map(Number).some((x) => bars.includes(x))).length > 1; });
      const same = r.printed.join(' / ') === r.shown.join(' / ');
      const good = exact ? same : !joined;
      console.log(`${good ? 'ok  ' : 'FAIL'} ${dev} sample ${k}: zoom ${r.zoom}, ${r.printed.length} printed rows, ${r.shown.length} shown`);
      if (!good) fails.push(`${dev} sample ${k}: printed ${r.printed.join(' / ')} shown ${r.shown.join(' / ')}`);
      await ctx.close();
    }
  }
  await b.close(); srv.close();
  if (fails.length) { console.log(fails.join('\n')); process.exit(1); }
  console.log('rows: all checks passed');
})();
