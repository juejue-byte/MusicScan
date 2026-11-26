// Multi-page end to end, against a running server: a 2-page PDF is read into one score, a photo is added as a
// third page, pages are reordered and removed, and the export covers every page.
// Usage: NODE_PATH=$(npm root -g) node tests/multipage_e2e.js <two-page.pdf> <page.png> [baseUrl] [outDir]
const { chromium } = require('playwright');
const fs = require('fs');
const [pdf, png] = process.argv.slice(2, 4);
const base = process.argv[4] || 'http://localhost:8000/';
const out = process.argv[5] || '/tmp/multipage';
fs.mkdirSync(out, { recursive: true });
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1366, height: 1024 }, acceptDownloads: true });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text()); });
  await p.goto(base);
  await p.waitForSelector('#drop');
  await p.setInputFiles('#fileInput', pdf);
  await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 180000 });
  const one = await p.evaluate(() => window.__ms.S.score.nMeasures);
  console.log('page 1 open:', one, 'bars');
  // page 2 of the PDF is read in the background and appended
  await p.waitForFunction(() => !document.querySelector('#pageReading'), null, { timeout: 180000 });
  const info = () => p.evaluate(() => {
    const S = window.__ms.S;
    const sc = S.score;
    const pages = [];
    S.meta.forEach((m, i) => { const l = pages[pages.length - 1]; if (l && l.id === m.page) l.hi = i; else pages.push({ id: m.page, lo: i, hi: i }); });
    const a = (mi) => { const x = sc.attrs(0, mi); return `${x.fifths} ${x.beats}/${x.beatType} ${Object.values(x.clefs).map((c) => c.sign + c.line).join(',')}`; };
    return { bars: sc.nMeasures, meta: S.meta.length, pages: pages.map((r) => `${r.lo}-${r.hi}`), starts: pages.map((r) => a(r.lo)),
      numbers: sc.parts[0].measures.map((m) => m.getAttribute('number')).join(','), tabs: document.querySelector('#pageTabs').innerText.replace(/\s+/g, ' '),
      over: Array.from({ length: sc.nMeasures }, (_, mi) => mi).filter((mi) => sc.parts.some((_, pi) => sc.measureProblems(pi, mi).over)).length };
  });
  let i1 = await info();
  console.log('after PDF:', JSON.stringify(i1));
  await p.screenshot({ path: out + '/01_two_pages.png' });
  // add a photo as page 3 from the Pages dialog
  await p.click('#btnPages'); await p.waitForTimeout(200);
  await p.waitForSelector('.page-row');
  await p.screenshot({ path: out + '/02_pages_dialog.png' });
  const [chooser] = await Promise.all([p.waitForEvent('filechooser'), p.click('[data-pg="file"]')]);
  await chooser.setFiles(png);
  await p.waitForSelector('#pageReading');
  await p.screenshot({ path: out + '/03_reading_page3.png' });
  await p.waitForFunction(() => !document.querySelector('#pageReading'), null, { timeout: 180000 });
  const i2 = await info();
  console.log('after photo:', JSON.stringify(i2));
  // photo panel follows a bar on page 2
  await p.evaluate(() => { const S = window.__ms.S; const mi = S.meta.findIndex((m, i) => i > 0 && m.page !== S.meta[0].page); window.__mi = mi; });
  await p.click('#pageTabs button >> nth=1');
  await p.waitForTimeout(800);
  const photo = await p.evaluate(() => ({ src: document.querySelector('#photoImg').src.split('/').slice(-2).join('/'), boxes: document.querySelectorAll('#photoSvg rect').length, page: window.__ms.S.photoPage }));
  console.log('photo panel on page 2:', JSON.stringify(photo));
  await p.screenshot({ path: out + '/04_photo_page2.png' });
  // move page 3 up, then remove it, then undo the removal
  await p.click('#btnPages'); await p.waitForTimeout(200);
  await p.click('.page-row >> nth=2 >> [data-pg="up"]');
  const i3 = await info();
  console.log('page 3 moved up:', JSON.stringify(i3));
  await p.screenshot({ path: out + '/05_moved.png' });
  await p.click('.page-row >> nth=1 >> [data-pg="remove"]');
  const i4 = await info();
  console.log('removed:', JSON.stringify(i4));
  await p.click('[data-pg="close"]');
  await p.keyboard.press('Control+z');
  const i5 = await info();
  console.log('undo:', JSON.stringify(i5));
  await p.keyboard.press('Control+z');
  const i6 = await info();
  console.log('undo move:', JSON.stringify(i6));
  // rescan a bar on page 2 goes to page 2's photo
  const req = [];
  p.on('request', (r) => { if (r.url().includes('/rescan')) req.push(r.url()); });
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([window.__mi]); window.__ms.redraw(); });
  await p.click('#btnRescan');
  await p.waitForSelector('[data-m="use"]', { timeout: 120000 });
  console.log('rescan request:', req[0]?.split('/api/')[1], (await p.textContent('#modalCard h2')));
  await p.click('[data-m="close"]');
  // export: one file with every bar
  const [dl] = await Promise.all([p.waitForEvent('download'), (async () => { await p.click('#btnExport'); await p.click('[data-x="xml"]'); })()]);
  const path = out + '/score.musicxml';
  await dl.saveAs(path);
  const xml = fs.readFileSync(path, 'utf8');
  console.log('export:', (xml.match(/<measure /g) || []).length, 'measure elements,', (xml.match(/new-page="yes"/g) || []).length, 'page breaks');
  console.log(errs.length ? 'ERRORS\n' + errs.join('\n') : 'no page errors');
  await b.close();
})();
