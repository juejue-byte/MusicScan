// Practice playback on an emulated iPad: mixer rows (hands, S/A/T/B), mute/solo, count-in, metronome, live tempo,
// speed-up on each loop, repeats in the playing order, bundled samples, and MIDI programs.
// Usage: node tests/practice.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/practice';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.mp3': 'audio/mpeg' };
  const srv = http.createServer((req, res) => {
    const p = path.join(ROOT, 'web', decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!p.startsWith(path.join(ROOT, 'web')) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  });
  return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok(srv)));
}
const demoXml = (n) => JSON.parse(fs.readFileSync(path.join(ROOT, `web/demo/sample${n}/job.json`), 'utf8')).result.xml;

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
  const ctx = await b.newContext({ ...devices['iPad Pro 11 landscape'] });
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  await p.goto(base);
  const fails = [];
  const ok = (c, m) => { if (!c) fails.push(m); else console.log('ok  ', m); };
  const tap = (sel) => p.tap(sel);

  // ---- choir: four parts -> Soprano, Alto, Tenor, Bass with the choir sound
  await p.evaluate((xml) => window.__ms.openScore(xml), demoXml(3));
  await p.waitForTimeout(300);
  await tap('#btnPractice');
  const rows = await p.$$eval('#practicePanel .ptrack .pname', (els) => els.map((e) => e.textContent));
  ok(JSON.stringify(rows) === JSON.stringify(['Soprano', 'Alto', 'Tenor', 'Bass']), 'choir rows are S/A/T/B: ' + rows.join(', '));
  const insts = await p.$$eval('#practicePanel select', (els) => els.map((e) => e.value));
  ok(insts.every((v) => v === 'choir'), 'choir parts default to the choir sound');
  await p.screenshot({ path: path.join(OUT, 'choir_panel.png') });

  // solo the alto: only part 1 sounds; the mixer gain says so
  await p.tap('#practicePanel .ptrack[data-key="1/1"] [data-act=solo]');
  const tracks = await p.evaluate(() => window.__ms.practice.state.tracks);
  ok(tracks['1/1']?.solo, 'solo alto recorded');
  ok(await p.evaluate(() => document.querySelector('#btnPractice').classList.contains('dot')), 'practice button shows a dot when the mix is changed');

  // count-in 1 bar + click, then play from the start
  await p.tap('#practicePanel .pseg[data-k=countIn] button[data-v="1"]');
  await p.tap('#practicePanel .pseg[data-k=metronome] button[data-v="1"]');
  await p.tap('#practicePanel [data-pct="100"]');
  await p.evaluate(() => { window.__ms.audio.debug.log = []; });
  await p.mouse.click(5, 300);  // close the panel
  ok(!(await p.evaluate(() => document.querySelector('#practicePanel').classList.contains('open'))), 'tapping outside closes the panel');
  await p.evaluate(() => document.querySelector('#btnPlay').click());
  await p.waitForTimeout(4600);
  let log = await p.evaluate(() => window.__ms.audio.debug.log);
  const counts = log.filter((x) => x.count);
  const meter = await p.evaluate(() => { const a = window.__ms.S.score.attrs(0, 0); return a.beats; });
  ok(counts.length >= meter, `count-in clicks: ${counts.length} (meter ${meter})`);
  const firstNote = log.find((x) => x.midi);
  ok(firstNote && counts.every((c) => c.t < firstNote.t - 0.01), 'count-in finishes before the first note');
  ok(log.some((x) => x.click && !x.count && x.on), 'metronome clicks during the music');
  ok(log.filter((x) => x.midi).every((x) => x.part >= 0), 'notes carry their part');
  // live tempo: ] speeds up by 5 while playing
  const before = await p.evaluate(() => window.__ms.audio.tempo());
  await p.keyboard.press(']');
  ok((await p.evaluate(() => window.__ms.audio.tempo())) === before + 5, `] raises the tempo live (${before} -> ${before + 5})`);
  await p.evaluate(() => document.querySelector('#btnPlay').click());  // stop
  ok(!(await p.evaluate(() => window.__ms.audio.isPlaying())), 'stop');
  ok(await p.evaluate(() => window.__ms.audio.samplesLoaded('choir')), 'bundled choir samples load and decode');

  // ---- piano: two staves -> Right hand / Left hand; mute the left hand mid-play
  await p.evaluate((xml) => window.__ms.openScore(xml), demoXml(1));
  await p.waitForTimeout(300);
  await tap('#btnPractice');
  const prow = await p.$$eval('#practicePanel .pname', (els) => els.map((e) => e.textContent));
  ok(prow.includes('Right hand') && prow.includes('Left hand'), 'piano rows: ' + prow.join(', '));
  await p.tap('#practicePanel .pseg[data-k=countIn] button[data-v="0"]');
  await p.tap('#practicePanel .pseg[data-k=metronome] button[data-v="0"]');
  // speed up: loop bar 1, +10 per pass up to 120%; start at 200 bpm so passes are short
  await p.tap('#pSpeed');
  await p.tap('#practicePanel .pseg[data-k=step] button[data-v="10"]');
  await p.tap('#practicePanel .pseg[data-k=target] button[data-v="120"]');
  await p.screenshot({ path: path.join(OUT, 'piano_panel.png') });
  await p.mouse.click(5, 300);
  await p.evaluate(() => { const ms = window.__ms; ms.practice.state.written = 200; ms.practice.setBpm(150); ms.S.measures = new Set([0]); document.querySelector('#btnLoop').click(); ms.audio.debug.log = []; document.querySelector('#btnPlay').click(); });
  await p.waitForTimeout(5200);
  log = await p.evaluate(() => window.__ms.audio.debug.log);
  const passes = [...new Set(log.filter((x) => x.midi).map((x) => x.pass))];
  const bpms = [...new Set(log.filter((x) => x.midi).map((x) => x.bpm))];
  ok(passes.length >= 3, `loop passes: ${passes.length}`);
  ok(bpms.length >= 3 && bpms[1] === bpms[0] + 10, `speed-up per pass: ${bpms.join(' -> ')}`);
  const written = await p.evaluate(() => window.__ms.practice.state.written);
  ok(Math.max(...bpms) <= Math.round(written * 1.2), 'speed-up stops at the target');
  const q1 = await p.evaluate(() => window.__ms.S.score.playEvents().starts[1]);
  ok(log.filter((x) => x.midi).every((x) => x.q < q1), 'notes stay in the looped bar');
  await p.evaluate(() => document.querySelector('#btnPlay').click());
  ok((await p.evaluate(() => window.__ms.practice.state.bpm)) === 150, 'tempo returns to where the speed-up started');
  await p.evaluate(() => document.querySelector('#btnLoop').click());

  // ---- repeats: the played order follows the repeat signs (choir sample has one)
  const ord = await p.evaluate((xml) => { window.__ms.openScore(xml); const pe = window.__ms.S.score.playEvents(); return { order: pe.order, meters: pe.meters.length, n: window.__ms.S.score.nMeasures }; }, demoXml(3));
  ok(ord.order.length > ord.n && ord.meters === ord.order.length, `repeat order plays ${ord.order.length} bars for ${ord.n} written`);

  // ---- MIDI: program change per part from the picker
  const midi = await p.evaluate(async () => {
    const { toMidi } = await import('./js/score.js');
    const bytes = toMidi(window.__ms.S.score, 90, window.__ms.practice.programs());
    return Array.from(bytes);
  });
  const progs = [];
  for (let i = 0; i < midi.length - 1; i++) if ((midi[i] & 0xf0) === 0xc0 && midi[i - 1] === 0 && midi[i + 1] === 52) progs.push(midi[i] & 15);
  ok(progs.length === 4, `MIDI carries the choir program on each of 4 tracks (${progs.length})`);
  ok(String.fromCharCode(...midi.slice(0, 4)) === 'MThd', 'MIDI header');

  // ---- phone: the panel is a bottom sheet
  const ph = await b.newContext({ ...devices['iPhone 13'] });
  const pp = await ph.newPage();
  pp.on('pageerror', (e) => errs.push(e.message));
  await pp.goto(base);
  await pp.evaluate((xml) => window.__ms.openScore(xml), demoXml(1));
  await pp.waitForTimeout(300);
  await pp.tap('#btnPractice');
  const r = await pp.$eval('#practicePanel', (e) => { const b = e.getBoundingClientRect(); return { w: b.width, bottom: b.bottom, vw: innerWidth, vh: innerHeight }; });
  ok(Math.abs(r.w - r.vw) < 2 && Math.abs(r.bottom - r.vh) < 2, 'phone: panel is a full-width bottom sheet');
  await pp.screenshot({ path: path.join(OUT, 'phone_panel.png') });

  ok(errs.length === 0, 'no page errors ' + errs.join(' | '));
  await b.close(); srv.close();
  if (fails.length) { console.error('FAIL\n  ' + fails.join('\n  ')); process.exit(1); }
  console.log('all practice checks passed');
})();
