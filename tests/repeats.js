// Repeats, first/second endings and fermatas: play order, MIDI length, and drawing, in a real browser.
// Usage: node tests/repeats.js [score.musicxml screenshot.png]   (exits non-zero on failure)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css' };
  const srv = http.createServer((req, res) => {
    const p = path.join(ROOT, 'web', decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(path.join(ROOT, 'web')) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}

// 6 bars of 2/4, one quarter-note pair per bar: |: 1 2 :| 3 [1. 4 :| [2. 5 | 6 with a fermata on bar 6.
// After a finished repeat the next one goes back to the bar after it: 1 2 1 2 3 4 3 5 6
function bars() {
  const note = (step, extra = '') => `<note><pitch><step>${step}</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type>${extra}</note>`;
  const steps = ['C', 'D', 'E', 'F', 'G', 'A'];
  const bl = {
    0: '<barline location="left"><bar-style>heavy-light</bar-style><repeat direction="forward"/></barline>',
    2: '', 3: '<barline location="left"><ending number="1" type="start"/></barline>',
    4: '<barline location="left"><ending number="2" type="start"/></barline>',
  };
  const br = {
    1: '<barline location="right"><bar-style>light-heavy</bar-style><repeat direction="backward"/></barline>',
    3: '<barline location="right"><bar-style>light-heavy</bar-style><ending number="1" type="stop"/><repeat direction="backward"/></barline>',
    4: '<barline location="right"><ending number="2" type="discontinue"/></barline>',
    5: '<barline location="right"><bar-style>light-heavy</bar-style></barline>',
  };
  let ms = '';
  steps.forEach((s, i) => {
    const attrs = i === 0 ? '<attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>' : '';
    const ferm = i === 5 ? '<notations><fermata type="upright"/></notations>' : '';
    ms += `<measure number="${i + 1}">${attrs}${bl[i] || ''}${note(s)}${note(s, ferm)}${br[i] || ''}</measure>`;
  });
  return `<?xml version="1.0"?><score-partwise version="4.0"><part-list><score-part id="P1"><part-name>T</part-name></score-part></part-list><part id="P1">${ms}</part></score-partwise>`;
}

(async () => {
  const [extra, shot] = process.argv.slice(2);
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1300, height: 900 } });
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  p.on('console', (m) => { if ((m.type() === 'warning' || m.type() === 'error') && !/Failed to load resource/.test(m.text())) errs.push('console: ' + m.text()); });
  await p.goto(base + 'index.html');
  const fails = await p.evaluate(async ([xml, extraXml]) => {
    const { Score, toMidi } = await import('./js/score.js');
    const { render } = await import('./js/render.js');
    const fails = [];
    const ok = (c, m) => { if (!c) fails.push(m); };
    const s = new Score(xml);
    const order = s.playOrder();
    ok(JSON.stringify(order) === JSON.stringify([0, 1, 0, 1, 2, 3, 2, 4, 5]), 'play order ' + JSON.stringify(order));
    const pe = s.playEvents();
    ok(pe.events.length === 18 && pe.starts.length === 10 && pe.starts[9] === 18, `events ${pe.events.length}, starts ${pe.starts.length}/${pe.starts[pe.starts.length - 1]}`);
    ok(toMidi(s, 120).length > 100, 'midi');
    const el = document.createElement('div');
    el.style.width = '1200px';
    document.body.prepend(el);
    render(s, el, { width: 1200 });
    const svg = el.querySelector('svg').innerHTML;
    // repeat dots are drawn as small filled rects/circles next to thick bar lines; endings as text "1." / "2."
    ok(/>1\.</.test(svg) && />2\.</.test(svg), 'first/second ending brackets drawn');
    ok(s.events(0, 5)[1].fermata === 'upright', 'fermata read');
    // the score round-trips with its bar lines
    const again = new Score(s.toXML());
    ok(JSON.stringify(again.playOrder()) === JSON.stringify(order), 'export keeps repeats');
    if (extraXml) {
      const e2 = document.createElement('div'); e2.id = 'extra'; e2.style.width = '1200px'; e2.style.background = 'white';
      document.body.prepend(e2);
      const sc = new Score(extraXml);
      render(sc, e2, { width: 1200 });
      window.__extra = { order: sc.playOrder(), n: sc.nMeasures };
    }
    return fails;
  }, [bars(), extra ? fs.readFileSync(extra, 'utf8') : null]);
  if (extra && shot) {
    console.log('extra', JSON.stringify(await p.evaluate(() => window.__extra)));
    await p.locator('#extra').screenshot({ path: shot });
  }
  await b.close();
  srv.close();
  const all = [...fails, ...errs];
  console.log(all.length ? 'FAIL\n' + all.join('\n') : 'repeats: all checks passed');
  process.exit(all.length ? 1 : 0);
})();
