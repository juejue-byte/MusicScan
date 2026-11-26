// Practice bar (web/js/practicebar.js): on an emulated iPad and iPhone in demo mode, Play brings up the dark bar
// under the score; it follows the bar being played, its tempo slider and +/- set the practice tempo, Click and
// Count-in switch the same settings as the Practice panel, Loop toggles looping, Parts opens the panel, and Stop
// (or the Play button) hides it again.
// Usage: node tests/practicebar.js [outDir]     (serves web/ itself; exits non-zero on failure)
const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(__dirname, '..');
const OUT = process.argv[2] || '/tmp/practicebar_ui';

function serve() {
  const types = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html', '.css': 'text/css', '.json': 'application/json', '.jpg': 'image/jpeg', '.png': 'image/png' };
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
  const base = `http://127.0.0.1:${srv.address().port}/?demo`;
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
  const fails = [];
  const errs = [];
  const ok = (c, m) => { console.log(`${c ? 'ok  ' : 'FAIL'} ${m}`); if (!c) fails.push(m); };

  for (const dev of ['iPad Pro 11 landscape', 'iPhone 14']) {
    const ctx = await b.newContext({ ...devices[dev] });
    const p = await ctx.newPage();
    p.on('pageerror', (e) => errs.push(e.message));
    const tap = async (sel) => { await p.locator(sel).first().tap(); await p.waitForTimeout(250); };
    const st = () => p.evaluate(() => {
      const P = window.__ms.practice.state, bar = document.querySelector('#practiceBar');
      const r = bar.getBoundingClientRect();
      return { shown: !bar.classList.contains('hidden'), playing: window.__ms.audio.isPlaying(), bpm: P.bpm, written: P.written, click: P.metronome, count: P.countIn,
        loop: !!window.__ms.S.loop, where: bar.querySelector('.pb-bar').textContent, panel: document.querySelector('#practicePanel').classList.contains('open'),
        inView: r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth, w: r.width };
    });
    await p.goto(base);
    await p.waitForSelector('.sample');
    await tap('.sample:nth-of-type(1)');
    await p.waitForSelector('#viewEditor:not(.hidden)', { timeout: 15000 });
    await p.waitForTimeout(400);
    let s = await st();
    ok(!s.shown, `${dev}: no practice bar before playing`);
    await tap('#btnPlay');
    await p.waitForTimeout(900);
    s = await st();
    ok(s.shown && s.playing, `${dev}: Play shows the practice bar`);
    ok(s.inView, `${dev}: the bar fits on screen (${Math.round(s.w)} px wide)`);
    ok(/^Bar \d+/.test(s.where), `${dev}: the bar says where you are (${s.where})`);
    await p.screenshot({ path: path.join(OUT, `${dev.replace(/ /g, '_')}_playing.png`) });

    const w = s.written;
    await tap('#practiceBar .pb-step[data-d="-5"]');
    s = await st();
    ok(s.bpm === w - 5, `${dev}: − slows down by 5 (${w} → ${s.bpm})`);
    await p.locator('#practiceBar .pb-range').fill(String(w - 20));
    s = await st();
    ok(s.bpm === w - 20, `${dev}: the slider sets the tempo (${s.bpm})`);
    const tempoField = await p.$eval('#tempo', (x) => +x.value);
    ok(tempoField === w - 20, `${dev}: the header tempo follows (${tempoField})`);

    const click0 = s.click;
    await tap('#practiceBar [data-t=click]');
    s = await st();
    ok(s.click === !click0, `${dev}: Click switches the metronome`);
    const c0 = s.count;
    await tap('#practiceBar [data-t=count]');
    s = await st();
    ok(s.count === (c0 + 1) % 3, `${dev}: Count-in steps 0 → 1 → 2 bars (${c0} → ${s.count})`);
    await tap('#practiceBar [data-t=loop]');
    s = await st();
    ok(s.loop && s.shown, `${dev}: Loop turns looping on and keeps playing`);
    await tap('#practiceBar [data-t=parts]');
    s = await st();
    ok(s.panel, `${dev}: Parts opens the Practice panel`);
    const sync = await p.evaluate(() => document.querySelector('#practicePanel .pseg[data-k=metronome] .on')?.dataset.v);
    ok(sync === (s.click ? '1' : '0'), `${dev}: the panel shows the same Click setting`);
    await p.screenshot({ path: path.join(OUT, `${dev.replace(/ /g, '_')}_parts.png`) });
    await tap('#practiceClose');
    await tap('#practiceBar .pb-stop');
    s = await st();
    ok(!s.shown && !s.playing, `${dev}: Stop stops playback and hides the bar`);
    // put settings back so the next device starts clean
    await p.evaluate(() => { const pr = window.__ms.practice; pr.setOption('metronome', false); pr.setOption('countIn', 0); });
    await ctx.close();
  }

  ok(errs.length === 0, 'no page errors' + (errs.length ? ': ' + errs.join(' | ') : ''));
  await b.close(); srv.close();
  if (fails.length) { console.log(`\n${fails.length} failed`); process.exit(1); }
  console.log('\nall practice bar checks passed');
})();
