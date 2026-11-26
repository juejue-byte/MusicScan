// Rescan splicing on multi-staff and C-clef scores, in a real browser (no server needed).
// Usage: node tests/splice.js            (exits non-zero on failure)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'bench', 'data');

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
  const files = {
    piano: fs.readFileSync(path.join(DATA, 'mozart_k545.musicxml'), 'utf8'),
    cello: fs.readFileSync(path.join(DATA, 'beethoven_18_vc.musicxml'), 'utf8'),
    quartet: fs.readFileSync(path.join(DATA, 'mozart_k458_quartet.musicxml'), 'utf8'),
  };
  const viola = path.join(DATA, 'haydn_74_viola.musicxml');
  if (fs.existsSync(viola)) files.viola = fs.readFileSync(viola, 'utf8');

  const out = await p.evaluate(async (files) => {
    const { Score } = await import('./score.js');
    const fails = [];
    const ok = (cond, msg) => { if (!cond) fails.push(msg); };
    // what you hear and see per bar: [staff, voice-less pitch/duration list] for every part
    const sig = (s, mi) => s.parts.map((_, pi) => s.events(pi, mi).filter((e) => !e.grace && !e.hidden).map((e) => `${e.staff}:${e.rest ? 'r' : e.chord.map((c) => c.pitch.step + (c.pitch.alter || 0) + c.pitch.octave).join('+')}/${e.dur / e.div}`).sort().join(' ')).join(' | ');
    const clefs = (s, pi, mi) => Object.entries(s.attrs(pi, mi).clefs).map(([n, c]) => `${n}${c.sign}${c.line}`).join(',');
    // a "re-read row": bars idxs of the score as a standalone file, like the server returns it
    const crop = (xml, idxs, mutate) => {
      const c = new Score(xml);
      c.parts.forEach((p, pi) => {
        const keepAttrs = c.attrs(pi, idxs[0]);
        p.measures.forEach((m, i) => { if (!idxs.includes(i)) m.remove(); });
        const first = p.el.querySelector(':scope > measure');
        const at = c._attrsEl(first);
        at.innerHTML = '';
        const add = (h) => at.insertAdjacentHTML('beforeend', h);
        add(`<divisions>${keepAttrs.divisions}</divisions><key><fifths>${keepAttrs.fifths}</fifths></key><time><beats>${keepAttrs.beats}</beats><beat-type>${keepAttrs.beatType}</beat-type></time>`);
        if (keepAttrs.staves > 1) add(`<staves>${keepAttrs.staves}</staves>`);
        for (const [n, cl] of Object.entries(keepAttrs.clefs)) add(`<clef number="${n}"><sign>${cl.sign}</sign><line>${cl.line}</line></clef>`);
      });
      c.refresh();
      if (mutate) mutate(c);
      return new Score(c.toXML());
    };
    const check = (name, xml, idxs, mutate, expect) => {
      const s = new Score(xml);
      const n0 = s.nMeasures;
      const before = Array.from({ length: n0 }, (_, mi) => sig(s, mi));
      const clefsBefore = s.parts.map((_, pi) => Array.from({ length: n0 }, (_, mi) => clefs(s, pi, mi)));
      const c = crop(xml, idxs, mutate);
      s.spliceMeasures(idxs, c);
      const delta = c.nMeasures - idxs.length;
      ok(s.nMeasures === n0 + delta, `${name}: ${s.nMeasures} bars, expected ${n0 + delta}`);
      // bars outside the splice are untouched (what they sound like and which clefs are in force)
      for (let mi = 0; mi < n0; mi++) {
        if (idxs.includes(mi)) continue;
        const nmi = mi > idxs[idxs.length - 1] ? mi + delta : mi;
        ok(sig(s, nmi) === before[mi], `${name}: bar ${mi + 1} changed`);
        s.parts.forEach((_, pi) => ok(clefs(s, pi, nmi) === clefsBefore[pi][mi], `${name}: clefs of part ${pi + 1} bar ${mi + 1} are ${clefs(s, pi, nmi)}, were ${clefsBefore[pi][mi]}`));
      }
      for (let mi = 0; mi < s.nMeasures; mi++) for (let pi = 0; pi < s.parts.length; pi++) ok(!s.measureProblems(pi, mi).over, `${name}: part ${pi + 1} bar ${mi + 1} overflows`);
      if (expect) expect(s, ok);
      // still valid XML that loads again
      const again = new Score(s.toXML());
      ok(again.nMeasures === s.nMeasures, `${name}: reload`);
      return s;
    };
    // 1. grand staff: identical re-read of bars 5-6 changes nothing
    check('piano same', files.piano, [4, 5]);
    // 2. grand staff: the re-read saw a treble clef on the bass staff from its 2nd bar; the bar after the row
    //    must be back in the bass clef
    check('piano clef leak', files.piano, [4, 5], (c) => {
      const at = c._attrsEl(c.parts[0].measures[1]);
      at.insertAdjacentHTML('beforeend', '<clef number="2"><sign>G</sign><line>2</line></clef>');
    }, (s, ok) => {
      ok(clefs(s, 0, 5) === '1G2,2G2', 'piano clef leak: the change inside the row is kept');
      ok(clefs(s, 0, 6) === '1G2,2F4', 'piano clef leak: bass clef restored after the row');
    });
    // 3. grand staff: re-read found 3 bars where there were 2 (bar count change)
    check('piano 2->3', files.piano, [4, 5], (c) => {
      for (const p of c.parts) p.el.appendChild(p.measures[1].cloneNode(true));
      c.refresh();
    });
    // 4. a re-read whose first bar shows a treble clef must not replace the cello's clef for the row
    check('cello row', files.cello, [8, 9, 10], (c) => {
      const at = c._attrsEl(c.parts[0].measures[0]);
      at.querySelector('clef').innerHTML = '<sign>G</sign><line>2</line>';
    }, (s, ok) => ok(clefs(s, 0, 8) === clefs(new Score(files.cello), 0, 8), 'cello row: clef kept'));
    // 5. string quartet (4 parts, alto clef viola): splice keeps every part aligned
    check('quartet', files.quartet, [3, 4]);
    // 6. viola part in alto clef, with a key change inside the re-read row that must not leak
    if (files.viola) {
      const v = new Score(files.viola);
      const k0 = v.attrs(0, 12).fifths;
      check('viola key leak', files.viola, [10, 11], (c) => {
        const at = c._attrsEl(c.parts[0].measures[1]);
        at.insertAdjacentHTML('afterbegin', `<key><fifths>${k0 + 2}</fifths></key>`);
      }, (s, ok) => ok(s.attrs(0, 12).fifths === k0, `viola key leak: key after the row is ${s.attrs(0, 12).fifths}, expected ${k0}`));
    }
    // 7. an old bar with a mid-bar clef change (bass staff to treble halfway through bar 7): the replacement
    //    reading has none, so the stale change must not jump to the start of the bar, and bar 8 must still
    //    start in the treble clef the old bar ended in
    const pz = new Score(files.piano);
    const m7 = pz.parts[0].measures[6];
    const half = pz.measureLength(0, 6) / 2;
    const ev = pz.events(0, 6).find((e) => e.staff === '2' && e.onset >= half);
    ev.el.insertAdjacentHTML('beforebegin', '<attributes><clef number="2"><sign>G</sign><line>2</line></clef></attributes>');
    pz.refresh();
    check('mid-bar attrs', pz.toXML(), [6], (c) => {
      for (const a of c.parts[0].measures[0].querySelectorAll('attributes')) if (a.previousElementSibling) a.remove();
      c.refresh();
    }, (s, ok) => {
      ok(clefs(s, 0, 6) === '1G2,2F4', `mid-bar attrs: bar 7 starts with ${clefs(s, 0, 6)}`);
      ok(clefs(s, 0, 7) === '1G2,2G2', `mid-bar attrs: bar 8 starts with ${clefs(s, 0, 7)}`);
    });
    return fails;
  }, files);
  await b.close();
  srv.close();
  const all = [...out, ...errs];
  console.log(all.length ? 'FAIL\n' + all.join('\n') : 'splice: all checks passed');
  process.exit(all.length ? 1 : 0);
})();
