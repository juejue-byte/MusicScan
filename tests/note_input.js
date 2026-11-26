// Keyboard note input like the familiar notation editors, in the real editor on a desktop browser:
// N, A-G at the caret (nearest octave), 1-7 lengths, 0 rest, R repeat, Shift+letter chord, ↑↓ semitone,
// ⌘/Ctrl+↑↓ octave, Backspace, re-pitching in select mode, auto-added bar at the end, and the ? sheet.
// Usage: node tests/note_input.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/note_input';

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
  const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const fails = [];
  const ok = (c, m) => { if (!c) fails.push(m); console.log(c ? 'ok  ' : 'FAIL', m); };
  await p.evaluate((xml) => window.__ms.openScore(xml), fs.readFileSync(path.join(ROOT, 'bench/data/mozart_k545.musicxml'), 'utf8'));
  await p.waitForTimeout(300);
  const key = async (...ks) => { for (const k of ks) { await p.keyboard.press(k); await p.waitForTimeout(30); } };
  // the notes of bar mi, staff 1, voice of the first event: "C5/eighth" etc.
  const bar = (mi, staff = '1') => p.evaluate(([mi, staff]) => {
    const s = window.__ms.S.score;
    const evs = s.voiceEvents(0, mi, staff, null);
    const v = evs[0]?.voice;
    return evs.filter((e) => e.voice === v).map((e) => (e.rest ? 'r' : e.chord.map((c) => c.pitch.step + (c.pitch.alter === 1 ? '#' : c.pitch.alter === -1 ? 'b' : '') + c.pitch.octave).join('+')) + '/' + e.type + (e.dots ? '.' : ''));
  }, [mi, staff]);
  const over = () => p.evaluate(() => { const s = window.__ms.S.score; const o = []; for (let mi = 0; mi < s.nMeasures; mi++) for (let pi = 0; pi < s.parts.length; pi++) if (s.measureProblems(pi, mi).over) o.push(mi); return o; });
  const overBefore = await over();

  // 1. start note input on bar 3 (index 2): select the bar by its number, press N, type eighths
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([2]); S.sel = null; window.__ms.redraw(); });
  await key('n', '4', 'c', 'd', 'e', 'f', 'g', 'a', 'b', 'c');
  let b3 = await bar(2);
  console.log('bar 3:', b3.join(' '));
  ok(b3.slice(0, 8).every((x) => x.endsWith('/eighth')), 'eight eighths written');
  ok(b3[0].startsWith('C') && b3[7].startsWith('C'), 'letters land as typed');
  const oct = b3.slice(0, 8).map((x) => +x.match(/\d/)[0]);
  ok(oct[7] === oct[0] + 1 || oct[7] === oct[0], 'nearest-octave walk goes up the scale');
  ok(JSON.stringify(await over()) === JSON.stringify(overBefore), 'no bar overflows');
  const caret = await p.evaluate(() => ({ ...window.__ms.S.caret, drawn: !!document.querySelector('#overlay .caret') }));
  ok(caret.mi === 3 && caret.q === 0 && caret.drawn, 'caret moved on to the next bar and is drawn');
  await p.screenshot({ path: OUT + '/01_typed.png' });

  // 2. quarter, rest, repeat, chord
  await key('5', 'g', '0', 'r');
  await key('Shift+B');
  let b4 = await bar(3);
  console.log('bar 4:', b4.join(' '));
  ok(b4[0].startsWith('G') && b4[0].endsWith('/quarter'), '5 = quarter, G written');
  ok(b4[1] === 'r/quarter', '0 = quarter rest');
  ok(b4[2].startsWith('G') && b4[2].includes('+B'), 'R repeated G and Shift+B added B above');
  // 3. semitone up, octave up on the last note
  const before = await p.evaluate(() => { const s = window.__ms.S; const e = s.score.events(0, 3).find((x) => x.chord.some((c) => c.el === s.sel)); return e.chord.map((c) => c.pitch); });
  await key('ArrowUp', 'Control+ArrowUp');
  const after = await p.evaluate(() => { const s = window.__ms.S; const e = s.score.events(0, 3).find((x) => x.chord.some((c) => c.el === s.sel)); return e.chord.map((c) => c.pitch); });
  console.log('↑ then ⌘↑:', JSON.stringify(before), '->', JSON.stringify(after));
  const midi = (q) => 12 * (q.octave + 1) + { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[q.step] + (q.alter || 0);
  ok(after.some((q) => before.some((r) => midi(q) - midi(r) === 13)), 'a semitone then an octave up');
  // 4. backspace clears the note before the caret
  await key('Backspace');
  b4 = await bar(3);
  ok(b4[2].startsWith('r'), 'Backspace turned the last note into a rest: ' + b4[2]);
  // 5. Esc leaves note input; a letter re-pitches the selected note and moves on
  await key('Escape');
  await p.evaluate(() => { const S = window.__ms.S; const e = S.score.voiceEvents(0, 2, '1', null)[0]; S.sel = e.el; window.__ms.redraw(); });
  await key('e', 'f');
  b3 = await bar(2);
  ok(b3[0].startsWith('E') && b3[1].startsWith('F') && b3[0].endsWith('/eighth'), 'select mode: E, F re-pitch two notes and keep their lengths');
  // 6. typing past the end adds a bar
  const n0 = await p.evaluate(() => window.__ms.S.score.nMeasures);
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([S.score.nMeasures - 1]); S.sel = null; window.__ms.redraw(); });
  await key('n', '7', 'c', 'd');
  const n1 = await p.evaluate(() => window.__ms.S.score.nMeasures);
  ok(n1 === n0 + 1, `a bar was added at the end (${n0} -> ${n1})`);
  await key('Escape');
  // 7. undo goes back step by step
  const u = await p.evaluate(() => window.__ms.S.undo.length);
  ok(u >= 15, 'every entry is one undo step (' + u + ')');
  // 8. the shortcut sheet
  await key('Shift+Slash');
  const sheet = await p.evaluate(() => !document.querySelector('#modal').classList.contains('hidden') && document.querySelectorAll('.keys-grid dt').length);
  ok(sheet > 20, '? opens the shortcut sheet (' + sheet + ' rows)');
  await p.screenshot({ path: OUT + '/02_keys.png' });
  await key('Escape');
  ok(await p.evaluate(() => document.querySelector('#modal').classList.contains('hidden')), 'Esc closes it');
  // 9. copy bar 2 (both staves) onto bar 6, then a note onto another note
  const barSig = (mi) => p.evaluate((mi) => { const s = window.__ms.S.score; return s.parts.map((pp, pi) => s.events(pi, mi).map((e) => (e.rest ? 'r' : e.chord.map((c) => c.pitch.step + c.pitch.octave).join('+')) + e.type).join(' ')).join(' | '); }, mi);
  await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.measures = new Set([1]); window.__ms.redraw(); });
  await key('Control+c');
  await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.measures = new Set([5]); window.__ms.redraw(); });
  const nBars = await p.evaluate(() => window.__ms.S.score.nMeasures);
  await key('Control+v');
  ok(await barSig(5) === await barSig(1), 'pasted bar 2 over bar 6 in every staff');
  ok(await p.evaluate(() => window.__ms.S.score.nMeasures) === nBars, 'bar count unchanged');
  await key('Shift+ArrowRight', 'Shift+ArrowRight');
  ok(await p.evaluate(() => window.__ms.S.measures.size) === 3, 'Shift+→ grows the bar selection');
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set(); S.sel = S.score.voiceEvents(0, 3, '1', null)[0].el; window.__ms.redraw(); });
  await key('Control+c');
  await p.evaluate(() => { const S = window.__ms.S; S.sel = S.score.voiceEvents(0, 4, '1', null)[0].el; window.__ms.redraw(); });
  await key('Control+v');
  const a4 = (await bar(3))[0], a5 = (await bar(4))[0];
  ok(a4 === a5, `pasted a note over another (${a4} -> ${a5})`);
  ok(JSON.stringify(await over()) === JSON.stringify(overBefore), 'still no bar overflows');
  // 10. a second voice: ⌘⌥2 on bar 8, two half notes, stems split; voice 1 untouched
  const v1 = await p.evaluate(() => { const s = window.__ms.S.score; return s.voiceEvents(0, 7, '1', null).map((e) => e.voice + ':' + e.onset).join(','); });
  await p.evaluate(() => { const S = window.__ms.S; S.sel = null; S.measures = new Set([7]); window.__ms.redraw(); });
  await key('n', 'Control+Alt+Digit2', '6', 'c', 'e');
  const vv = await p.evaluate(() => { const s = window.__ms.S.score; const evs = s.voiceEvents(0, 7, '1', null); return { voices: [...new Set(evs.map((e) => e.voice))], v2: evs.filter((e) => e.voice === '2').map((e) => (e.rest ? 'r' : e.chord[0].pitch.step) + '/' + e.type), v1: evs.filter((e) => e.voice === '1').map((e) => e.voice + ':' + e.onset).join(',') }; });
  console.log('voice 2:', JSON.stringify(vv));
  ok(vv.voices.length === 2 && vv.v2.join(' ') === 'C/half E/half', 'voice 2 holds the two half notes');
  ok(vv.v1 === v1, 'voice 1 is untouched');
  ok(JSON.stringify(await over()) === JSON.stringify(overBefore), 'no bar overflows with two voices');
  await p.screenshot({ path: OUT + '/03_voice2.png' });
  await key('Control+Alt+Digit1', 'Escape');
  // 11. slur and articulations
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set(); S.sel = S.score.voiceEvents(0, 2, '1', null)[0].el; window.__ms.redraw(); });
  await key('s', 'Shift+S', 'Shift+V');
  const nt = await p.evaluate(() => { const S = window.__ms.S; const el = S.sel; return { slurs: S.score.slurs(0).filter((x) => x.start === el).length, arts: [...el.querySelectorAll('notations > articulations > *')].map((x) => x.localName) }; });
  ok(nt.slurs === 1 && nt.arts.join() === 'accent,staccato', 'S slurs to the next note, Shift+S/V add staccato and accent: ' + JSON.stringify(nt));
  await key('s', 'Shift+S');
  const nt2 = await p.evaluate(() => { const S = window.__ms.S; const el = S.sel; return { slurs: S.score.slurs(0).filter((x) => x.start === el).length, arts: [...el.querySelectorAll('notations > articulations > *')].map((x) => x.localName) }; });
  ok(nt2.slurs === 0 && nt2.arts.join() === 'accent', 'pressing them again removes them');
  // 12. a misread clef: staff 2 of bar 1 becomes bass, the notes keep their place on the staff (move down a 13th)
  const lowBefore = await p.evaluate(() => window.__ms.S.score.voiceEvents(0, 0, '2', null).filter((e) => !e.rest).map((e) => e.chord[0].pitch.step + e.chord[0].pitch.octave));
  await p.evaluate(() => { const S = window.__ms.S; S.measures = new Set([0]); S.sel = S.score.voiceEvents(0, 0, '2', null)[0].el; window.__ms.redraw(); });
  await p.click('#btnKeyTime');
  await p.selectOption('#ktClef', 'bass');
  await p.click('[data-m="apply"]');
  const lowAfter = await p.evaluate(() => window.__ms.S.score.voiceEvents(0, 0, '2', null).filter((e) => !e.rest).map((e) => e.chord[0].pitch.step + e.chord[0].pitch.octave));
  const clef = await p.evaluate(() => window.__ms.S.score.attrs(0, 0).clefs['2'].sign);
  console.log('clef fix:', lowBefore.slice(0, 4).join(' '), '->', lowAfter.slice(0, 4).join(' '));
  ok(clef === 'F' && lowBefore[0] === 'C4' && lowAfter[0] === 'E2', 'misread clef fixed: C4 in treble is E2 in bass');
  // 13. transpose the piece up a major 2nd and back down: C major -> D major, every pitch +2 semitones
  const snap = () => p.evaluate(() => { const s = window.__ms.S.score; const out = []; for (let mi = 0; mi < s.nMeasures; mi++) for (const e of s.events(0, mi)) for (const c of e.chord) out.push(12 * (c.pitch.octave + 1) + { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 }[c.pitch.step] + (c.pitch.alter || 0)); return { m: out, f: s.attrs(0, 0).fifths }; });
  const t0 = await snap();
  await p.click('#btnKeyTime'); await p.selectOption('#trIv', 'M2'); await p.click('[data-m="transpose"]');
  const t1 = await snap();
  ok(t1.f === t0.f + 2 && t1.m.every((m, i) => m === t0.m[i] + 2), `transpose up a major 2nd (key ${t0.f} -> ${t1.f}, ${t1.m.length} notes +2)`);
  await p.click('#btnKeyTime'); await p.selectOption('#trDir', '-1'); await p.selectOption('#trIv', 'M2'); await p.click('[data-m="transpose"]');
  const t2 = await snap();
  ok(t2.f === t0.f && t2.m.every((m, i) => m === t0.m[i]), 'and back down');
  // the XML still parses
  const xml = await p.evaluate(() => window.__ms.S.score.toXML());
  fs.writeFileSync(OUT + '/out.musicxml', xml);
  ok(!/parsererror/.test(xml), 'XML is well formed');
  ok(!errs.length, 'no page errors ' + errs.join('; '));
  await b.close(); srv.close();
  if (fails.length) { console.log('\nFAILED:\n' + fails.join('\n')); process.exit(1); }
  console.log('\nall passed');
})();
