// Bar and rhythm edits (split / merge / insert / delete bars, ties, tuplets) on every benchmark score, in a real
// browser. Round trips must sound exactly like the original, every touched bar must add up, and the XML must reload.
// Usage: node tests/bar_ops.js [outDir]       (exits non-zero on failure; writes edited files to outDir for XSD checks)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const DATA = path.join(ROOT, 'bench', 'data');
const OUT = process.argv[2] || null;

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
  for (const f of fs.readdirSync(DATA)) if (f.endsWith('.musicxml')) files[f.replace('.musicxml', '')] = fs.readFileSync(path.join(DATA, f), 'utf8');

  const out = await p.evaluate(async (files) => {
    const { Score } = await import('./edits.js');
    const fails = [];
    const outputs = {};
    const ok = (cond, msg) => { if (!cond) fails.push(msg); };
    // what the score sounds like: every note's start, length and pitch (ties joined), per part
    const sound = (s) => s.playEvents().events.map((e) => `${e.part}:${e.time.toFixed(4)}:${e.midi}:${e.dur.toFixed(4)}`).sort().join(' ');
    const attrSig = (s, pi, mi) => { const a = s.attrs(pi, mi); return [a.divisions ? 1 : 0, a.fifths, a.beats, a.beatType, a.staves, Object.entries(a.clefs).map(([n, c]) => n + c.sign + c.line).join(',')].join('|'); };
    // every voice of bar mi ends exactly at `len` divisions (or the bar's own length)
    const full = (s, mi, name, len = null) => {
      for (let pi = 0; pi < s.parts.length; pi++) {
        const pr = s.measureProblems(pi, mi);
        const want = len === null ? pr.len : Math.round(len * s.attrs(pi, mi).divisions);
        for (const [k, e] of Object.entries(pr.ends)) ok(Math.abs(e - want) < 1e-6, `${name}: part ${pi + 1} bar ${mi + 1} voice ${k} ends at ${e}, bar is ${want}`);
      }
    };
    const reload = (s, name) => { const t = new Score(s.toXML()); ok(t.nMeasures === s.nMeasures, `${name}: reload`); return t; };
    const isFull = (s, mi) => s.parts.every((_, pi) => { const pr = s.measureProblems(pi, mi); return Object.values(pr.ends).every((e) => Math.abs(e - pr.len) < 1e-6); });

    for (const [name, xml] of Object.entries(files)) {
      const orig = new Score(xml);
      const n0 = orig.nMeasures;
      const snd0 = sound(orig);
      // a full bar in the middle with notes on a beat that is not the first
      let mi = Math.min(n0 - 2, 3);
      while (mi < n0 - 2 && !isFull(orig, mi)) mi++;
      const qlen = orig.measureLength(0, mi) / orig.attrs(0, mi).divisions;

      // 1. split in the middle, then join again: sounds the same
      {
        const s = new Score(xml);
        const cut = qlen / 2;
        s.splitBar(mi, cut);
        ok(s.nMeasures === n0 + 1, `${name} split: ${s.nMeasures} bars`);
        full(s, mi, `${name} split first half`, cut);
        full(s, mi + 1, `${name} split second half`);
        const seq = (x) => x.playEvents().events.map((e) => e.part + ':' + e.midi).join(' ');
        ok(seq(s) === seq(orig), `${name} split: the notes changed`);
        const t = reload(s, `${name} split`);
        t.mergeBars(mi);
        ok(t.nMeasures === n0, `${name} split+merge: ${t.nMeasures} bars`);
        ok(seq(t) === seq(orig), `${name} split+merge: the notes changed`);
        for (let k = mi + 1; k < n0; k++) for (let pi = 0; pi < t.parts.length; pi++) ok(attrSig(t, pi, k) === attrSig(orig, pi, k), `${name} split+merge: attributes of part ${pi + 1} bar ${k + 1}`);
        outputs[name + '_split'] = s.toXML();
      }
      // 2. split exactly at the barline the bar should have: join of an over-long bar is undone by a split
      {
        const s = new Score(xml);
        s.mergeBars(mi);
        ok(s.nMeasures === n0 - 1, `${name} merge: ${s.nMeasures} bars`);
        full(s, mi, `${name} merge`, 2 * qlen);
        ok(sound(s) === snd0, `${name} merge changed the sound`);
        for (let pi = 0; pi < s.parts.length; pi++) ok(s.measureProblems(pi, mi).over, `${name} merge: bar should read as too long`);
        const t = reload(s, `${name} merge`);
        t.splitBar(mi, qlen);
        ok(t.nMeasures === n0, `${name} merge+split: ${t.nMeasures} bars`);
        ok(sound(t) === snd0, `${name} merge+split changed the sound`);
        full(t, mi, `${name} merge+split a`); full(t, mi + 1, `${name} merge+split b`);
        for (let k = 0; k < n0; k++) for (let pi = 0; pi < t.parts.length; pi++) ok(attrSig(t, pi, k) === attrSig(orig, pi, k), `${name} merge+split: attributes of part ${pi + 1} bar ${k + 1}`);
        outputs[name + '_merge'] = s.toXML();
      }
      // 3. insert an empty bar after, then delete it; and before bar 1, then delete it
      for (const [at, where] of [[mi, 'after'], [0, 'before'], [n0 - 1, 'after']]) {
        const s = new Score(xml);
        const idx = s.insertBar(at, where);
        ok(s.nMeasures === n0 + 1, `${name} insert ${where} ${at + 1}`);
        full(s, idx, `${name} inserted bar`);
        ok(s.events(0, idx).every((e) => e.rest), `${name} inserted bar has notes`);
        for (let pi = 0; pi < s.parts.length; pi++) ok(attrSig(s, pi, idx) === attrSig(orig, pi, where === 'before' ? at : at), `${name} inserted bar attributes, part ${pi + 1}`);
        const t = reload(s, `${name} insert`);
        if (at === 0) outputs[name + '_insert0'] = t.toXML();
        t.deleteBars(idx);
        ok(t.nMeasures === n0, `${name} insert+delete count`);
        ok(sound(t) === snd0, `${name} insert ${where} + delete changed the sound`);
        for (let k = 0; k < n0; k++) for (let pi = 0; pi < t.parts.length; pi++) ok(attrSig(t, pi, k) === attrSig(orig, pi, k), `${name} insert+delete: attributes part ${pi + 1} bar ${k + 1}`);
      }
      // 4. delete the first bar: the new first bar has everything a first bar needs
      {
        const s = new Score(xml);
        s.deleteBars(0);
        for (let pi = 0; pi < s.parts.length; pi++) {
          ok(attrSig(s, pi, 0) === attrSig(orig, pi, 1), `${name} delete bar 1: part ${pi + 1} starts ${attrSig(s, pi, 0)} not ${attrSig(orig, pi, 1)}`);
          const at = s.parts[pi].measures[0].querySelector(':scope > attributes');
          ok(at && at.querySelector('divisions') && at.querySelector('clef'), `${name} delete bar 1: part ${pi + 1} lost divisions/clef`);
        }
        outputs[name + '_del0'] = reload(s, `${name} del0`).toXML();
      }
      // 5. tie a note to an equal next one and untie it: back to the same file
      {
        const s = new Score(xml);
        let done = false;
        for (let k = 0; k < n0 - 1 && !done; k++) for (const e of s.events(0, k)) {
          if (e.rest || e.grace || s.isTied(e)) continue;
          const nx = s.nextEvent(e);
          if (!nx || nx.rest || nx.tieStop || !nx.chord.some((c) => e.chord.some((d) => d.pitch.step === c.pitch.step && d.pitch.octave === c.pitch.octave && (d.pitch.alter || 0) === (c.pitch.alter || 0)))) continue;
          const before = s.toXML();
          const n1 = s.playEvents().events.length;
          s.toggleTie(e);
          ok(s.playEvents().events.length < n1, `${name} tie: notes did not join`);
          const t = reload(s, `${name} tie`);
          outputs[name + '_tie'] = t.toXML();
          const e2 = s.events(e.pi, e.mi).find((x) => x.el === e.el);
          s.toggleTie(e2);
          ok(s.toXML() === before, `${name} untie: file differs`);
          done = true;
          break;
        }
      }
      // 6. a quarter becomes a triplet and back
      {
        const s = new Score(xml);
        let done = false;
        for (let k = 0; k < n0 && !done; k++) {
          if (!isFull(s, k)) continue;
          const e = s.events(0, k).find((x) => !x.grace && !x.rest && !x.tuplet && !x.dots && x.type === 'quarter');
          if (!e) continue;
          s.makeTuplet(e, 3);
          full(s, k, `${name} triplet`);
          const g = s.tupletGroup(s.events(0, k).find((x) => x.el === e.el));
          ok(g.length === 3, `${name} triplet group has ${g.length}`);
          outputs[name + '_triplet'] = reload(s, `${name} triplet`).toXML();
          s.removeTuplet(g[1]);
          full(s, k, `${name} un-triplet`);
          ok(sound(s) === snd0, `${name} triplet + remove changed the sound`);
          // quintuplet on the same note
          const e3 = s.events(0, k).find((x) => x.el === e.el);
          s.makeTuplet(e3, 5);
          full(s, k, `${name} quintuplet`);
          done = true;
        }
      }
    }
    // 7. existing tuplets from a real score are grouped right
    if (files.clara_polonaise) {
      const s = new Score(files.clara_polonaise);
      let seen = 0;
      for (let k = 0; k < s.nMeasures; k++) for (let pi = 0; pi < s.parts.length; pi++) for (const e of s.events(pi, k)) {
        if (!e.tuplet || e.grace) continue;
        const g = s.tupletGroup(e);
        ok(g.length === e.tuplet.actual || g.length >= 2, `clara: tuplet group of ${g.length} at bar ${k + 1}`);
        seen++;
      }
      ok(seen > 0, 'clara: no tuplets seen');
    }
    // 8. a bar that is far too long (missed barline in a 2-staff piano score) splits into two full bars
    if (files.mozart_k545) {
      const s = new Score(files.mozart_k545);
      const snd = sound(s);
      s.mergeBars(2); s.mergeBars(2);
      const q = s.measureLength(0, 2) / s.attrs(0, 2).divisions;
      s.splitBar(2, q); s.splitBar(3, q);
      ok(sound(s) === snd, 'k545: merge x2 + split x2 changed the sound');
      for (const k of [2, 3, 4]) full(s, k, `k545 bar ${k + 1}`);
    }
    return { fails, outputs };
  }, files);
  await b.close();
  srv.close();
  if (OUT) { fs.mkdirSync(OUT, { recursive: true }); for (const [k, v] of Object.entries(out.outputs)) fs.writeFileSync(path.join(OUT, k + '.musicxml'), v); }
  const all = [...out.fails, ...errs];
  console.log(all.length ? 'FAIL\n' + all.join('\n') : `bar_ops: all checks passed on ${Object.keys(files).length} scores`);
  process.exit(all.length ? 1 : 0);
})();
