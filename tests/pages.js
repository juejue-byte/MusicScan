// Multi-page scores, in a real browser (no server needed): a score cut into "page readings" and joined again must
// sound and look like the original; moving and removing pages keeps key, time and clefs right.
// Usage: NODE_PATH=$(npm root -g) node tests/pages.js [outDir]   (exits non-zero on failure; outDir gets the
// joined scores as .musicxml for the XSD check)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'bench', 'data');
const OUT = process.argv[2];

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

(async () => {
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const b = await chromium.launch();
  const p = await b.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base + 'js/score.js');
  const files = {};
  for (const n of ['mozart_k545', 'beethoven_18_vc', 'mozart_k458_quartet', 'bach_bwv66', 'joplin_rag']) files[n] = fs.readFileSync(path.join(DATA, n + '.musicxml'), 'utf8');

  const out = await p.evaluate(async (files) => {
    const { Score } = await import('./score.js');
    await import('./pages.js');
    const fails = [];
    const saved = {};
    const ok = (cond, msg) => { if (!cond) fails.push(msg); };
    const sig = (s, mi) => s.parts.map((_, pi) => s.events(pi, mi).filter((e) => !e.grace && !e.hidden).map((e) => `${e.staff}:${e.rest ? 'r' : e.chord.map((c) => c.pitch.step + (c.pitch.alter || 0) + c.pitch.octave).join('+')}/${e.dur / e.div}`).sort().join(' ')).join(' | ');
    const state = (s, pi, mi) => { const a = s.attrs(pi, mi); return `${a.fifths} ${a.beats}/${a.beatType} ${a.staves} ` + Object.entries(a.clefs).map(([n, c]) => `${n}${c.sign}${c.line}`).join(','); };
    // a page's reading: bars lo..hi as a standalone score that declares everything on its first bar (like the
    // server returns it), with other divisions (k) to exercise the rescaling
    const page = (xml, lo, hi, k = 1, keepTime = true) => {
      const c = new Score(xml);
      c.parts.forEach((p, pi) => {
        const a = c.attrs(pi, lo);
        p.measures.forEach((m, i) => { if (i < lo || i > hi) m.remove(); });
        const first = p.el.querySelector(':scope > measure');
        const at = c._attrsEl(first);
        for (const x of [...at.children]) if (['divisions', 'key', 'time', 'staves', 'clef'].includes(x.localName)) x.remove();
        const add = (h) => at.insertAdjacentHTML('afterbegin', h);
        for (const [n, cl] of Object.entries(a.clefs).reverse()) add(`<clef number="${n}"><sign>${cl.sign}</sign><line>${cl.line}</line></clef>`);
        if (a.staves > 1) add(`<staves>${a.staves}</staves>`);
        if (keepTime) add(`<time><beats>${a.beats}</beats><beat-type>${a.beatType}</beat-type></time>`);
        add(`<key><fifths>${a.fifths}</fifths></key>`);
        add(`<divisions>${a.divisions}</divisions>`);
      });
      c.refresh();
      if (k !== 1) c.parts.forEach((_, pi) => c.rescalePart(pi, k));
      return new Score(c.toXML());
    };
    const same = (name, s, ref) => {
      ok(s.nMeasures === ref.nMeasures, `${name}: ${s.nMeasures} bars, expected ${ref.nMeasures}`);
      for (let mi = 0; mi < ref.nMeasures; mi++) {
        ok(sig(s, mi) === sig(ref, mi), `${name}: bar ${mi + 1} differs:\n  ${sig(s, mi)}\n  ${sig(ref, mi)}`);
        s.parts.forEach((_, pi) => ok(state(s, pi, mi) === state(ref, pi, mi), `${name}: part ${pi + 1} bar ${mi + 1} has ${state(s, pi, mi)}, expected ${state(ref, pi, mi)}`));
      }
      for (let mi = 0; mi < s.nMeasures; mi++) for (let pi = 0; pi < s.parts.length; pi++) ok(!s.measureProblems(pi, mi).over, `${name}: part ${pi + 1} bar ${mi + 1} overflows`);
      const again = new Score(s.toXML());
      ok(again.nMeasures === s.nMeasures, `${name}: reload`);
    };
    const timeEls = (s, mi) => s.parts[0].measures[mi].querySelectorAll(':scope > attributes > time').length;

    for (const [name, xml] of Object.entries(files)) {
      const ref = new Score(xml);
      const N = ref.nMeasures;
      const cut = [Math.floor(N / 3), Math.floor((2 * N) / 3)];
      // 1. three pages joined back (page 2 with 3x the divisions; page 3 without a time signature, as a page that
      //    does not print one reads after the server carried the time over)
      const s = page(xml, 0, cut[0] - 1);
      const p2 = page(xml, cut[0], cut[1] - 1, 3);
      const p3 = page(xml, cut[1], N - 1, 1, true);
      const r2 = s.appendScore(p2);
      ok(r2.added === cut[1] - cut[0], `${name}: page 2 added ${r2.added} bars`);
      s.appendScore(p3);
      s.markPages([0, cut[0], cut[1]]);
      same(`${name} joined`, s, ref);
      ok(JSON.stringify(s.playOrder()) === JSON.stringify(ref.playOrder()), `${name}: playback order differs`);
      ok(s.playEvents().length === ref.playEvents().length, `${name}: playback has ${s.playEvents().length} events, expected ${ref.playEvents().length}`);
      ok(timeEls(s, cut[0]) === 0 && timeEls(s, cut[1]) === 0, `${name}: a page start restates the time signature`);
      ok(s.parts[0].measures[cut[0]].querySelector(':scope > print')?.getAttribute('new-page') === 'yes', `${name}: page 2 starts no new page`);
      ok(s.newSystem(cut[0]) && s.newSystem(cut[1]), `${name}: a page start is not a new line`);
      const nums = s.parts[0].measures.map((m) => +m.getAttribute('number'));
      ok(nums.every((n, i) => i === 0 || n === nums[i - 1] + 1), `${name}: bar numbers are not continuous: ${nums.join(',')}`);
      // end context = what is in force after the last bar
      const ctx = s.endContext();
      ok(ctx.parts.length === ref.parts.length && ctx.parts[0].beats === ref.attrs(0, N - 1).beats, `${name}: end context`);
      saved[name + '_joined'] = s.toXML();

      // 2. move page 3 to the front and back again: the same piece
      const m = new Score(s.toXML());
      m.moveBars(cut[1], N - 1, 0);
      const moved = N - cut[1];
      for (let mi = 0; mi < moved; mi++) ok(sig(m, mi) === sig(ref, cut[1] + mi), `${name}: moved bar ${mi + 1} differs`);
      for (let mi = 0; mi < cut[1]; mi++) {
        ok(sig(m, moved + mi) === sig(ref, mi), `${name}: bar ${mi + 1} after the move differs`);
        m.parts.forEach((_, pi) => ok(state(m, pi, moved + mi) === state(ref, pi, mi), `${name}: after the move part ${pi + 1} bar ${mi + 1} has ${state(m, pi, moved + mi)}, expected ${state(ref, pi, mi)}`));
      }
      m.moveBars(0, moved - 1, N);
      same(`${name} moved back`, m, ref);

      // 3. remove the middle page: pages 1 and 3 keep their own key/time/clefs
      const d = new Score(s.toXML());
      d.deleteBars(cut[0], cut[1] - 1);
      for (let mi = cut[1]; mi < N; mi++) d.parts.forEach((_, pi) => ok(state(d, pi, mi - (cut[1] - cut[0])) === state(ref, pi, mi), `${name}: after removing page 2, part ${pi + 1} bar ${mi + 1} is ${state(d, pi, mi - (cut[1] - cut[0]))}`));
    }

    // 4. a page with fewer parts than the score: the missing part gets whole-bar rests that add up
    {
      const quartet = new Score(files.mozart_k458_quartet);
      const N = quartet.nMeasures;
      const s = page(files.mozart_k458_quartet, 0, 3);
      const solo = page(files.mozart_k458_quartet, 4, 7);
      for (const p of solo.parts.slice(1)) p.el.remove();
      solo.root.querySelectorAll('part-list > score-part').forEach((sp, i) => { if (i) sp.remove(); });
      const r = s.appendScore(new Score(solo.toXML()));
      ok(r.added === 4 && s.nMeasures === 8, 'fewer parts: bars added');
      for (let mi = 4; mi < 8; mi++) for (let pi = 1; pi < s.parts.length; pi++) {
        const pr = s.measureProblems(pi, mi);
        ok(!pr.over && !pr.under, `fewer parts: part ${pi + 1} bar ${mi + 1} does not add up`);
        ok(s.events(pi, mi).every((e) => e.rest), `fewer parts: part ${pi + 1} bar ${mi + 1} is not rests`);
      }
      ok(N > 8, 'quartet long enough');
    }
    // 5. a key change on page 2 is kept
    {
      const s = page(files.mozart_k545, 0, 3);
      const p2 = page(files.mozart_k545, 4, 7);
      p2.parts[0].measures[0].querySelector(':scope > attributes > key > fifths').textContent = '-2';
      s.appendScore(new Score(p2.toXML()));
      ok(s.attrs(0, 4).fifths === -2 && s.attrs(0, 4).changed.key, 'a real key change on page 2 is kept');
      ok(s.attrs(0, 3).fifths === 0, 'page 1 keeps its key');
    }
    return { fails, saved };
  }, files);

  if (OUT) {
    fs.mkdirSync(OUT, { recursive: true });
    for (const [n, x] of Object.entries(out.saved)) fs.writeFileSync(path.join(OUT, n + '.musicxml'), x);
  }
  await b.close();
  srv.close();
  const all = [...out.fails, ...errs];
  if (all.length) { console.log(all.slice(0, 40).join('\n')); console.log(`${all.length} failures`); process.exit(1); }
  console.log('pages: all checks passed');
})();
