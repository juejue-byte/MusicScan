// Exercises the MusicXML edit operations in a real browser and checks bars stay full and the XML stays valid.
// Usage: node tests/editor_ops.js http://localhost:8000/ <score.musicxml> <out.musicxml>
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [base, file, outFile] = process.argv.slice(2);
  const b = await chromium.launch(); const p = await b.newPage();
  const errs = []; p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const res = await p.evaluate(async (xml) => {
    const { Score, midiOf } = await import('./js/score.js');
    const s = new Score(xml);
    const log = [];
    const full = () => { const bad = []; for (let mi = 0; mi < s.nMeasures; mi++) for (let pi = 0; pi < s.parts.length; pi++) if (s.measureProblems(pi, mi).over) bad.push(mi); return bad; };
    const first = (mi, pred) => s.events(0, mi).find(pred);
    // 1. shorten a quarter to an eighth: a rest fills the gap
    let e = first(2, (x) => !x.rest && x.type === 'quarter');
    if (e) { const before = s.events(0, 2).length; s.setDuration(e, 'eighth', 0); log.push(['shorten', s.events(0, 2).length - before, full()]); }
    // 2. lengthen it back: the rest is eaten
    e = s.events(0, 2).find((x) => x.el === e?.el);
    if (e) { s.setDuration(e, 'quarter', 0); log.push(['lengthen', full()]); }
    // 3. turn a note into a rest and back into a note at the rest
    e = first(3, (x) => !x.rest);
    s.toRest(e); e = s.events(0, 3).find((x) => x.el === e.el);
    s.placeNote(e, { step: 'G', octave: 4, alter: 0 }, e.type, e.dots, 'at'); log.push(['rest->note', full()]);
    // 4. chord add and remove
    e = first(4, (x) => !x.rest);
    s.addChordTone(e, { step: 'E', octave: 4, alter: 0 }); e = s.events(0, 4).find((x) => x.el === e.el);
    log.push(['chord', e.chord.length]);
    s.removeChordTone(e, e.chord[e.chord.length - 1].el); e = s.events(0, 4).find((x) => x.el === e.el); log.push(['unchord', e.chord.length]);
    // 5. sixteenth in a bar of quarters (divisions may need rescaling)
    e = first(5, (x) => !x.rest);
    s.setDuration(e, '32nd', 0); log.push(['32nd', full(), s.attrs(0, 5).divisions]);
    // 6. accidentals and moves
    e = first(6, (x) => !x.rest); s.setAlter(e, e.el, 1); e = s.events(0, 6).find((x) => x.el === e.el);
    log.push(['sharp', e.chord[0].pitch.alter]);
    s.moveDiatonic(e, e.el, 7); e = s.events(0, 6).find((x) => x.el === e.el); log.push(['octave', e.chord[0].pitch.octave]);
    // 7. splice bars 7-8 with bars 1-2 of a copy
    const other = new Score(xml);
    const keep = other.parts.map((pp) => pp.measures.slice(0, 2));
    for (const pp of other.parts) for (const m of pp.measures.slice(2)) m.remove();
    other.refresh();
    s.spliceMeasures([7, 8], other); log.push(['splice', s.nMeasures, full()]);
    const evs = s.playEvents(); log.push(['play', evs.events.length, evs.starts.length]);
    return { log, xml: s.toXML() };
  }, fs.readFileSync(file, 'utf8'));
  console.log(JSON.stringify(res.log));
  fs.writeFileSync(outFile, res.xml);
  console.log('errors', errs);
  await b.close();
})();
