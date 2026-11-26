// Playback: a sampled piano (smplr, FluidR3 GM, MIT) when it can load, otherwise a soft built-in synth.
let ctx = null, piano = null, loading = null, timer = null, stopAt = 0, voices = [];

export function audioCtx() {
  if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
  if (ctx.state === 'suspended') ctx.resume();
  return ctx;
}

export async function loadPiano() {
  if (piano || loading) return loading;
  loading = (async () => {
    try {
      const { Soundfont } = await import('../vendor/smplr.mjs');
      const sf = new Soundfont(audioCtx(), { instrument: 'acoustic_grand_piano', kit: 'FluidR3_GM' });
      await Promise.race([sf.load, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 8000))]);
      piano = sf;
    } catch (e) {
      console.info('Sampled piano unavailable, using the built-in synth', e?.message);
      piano = null;
    }
    return piano;
  })();
  return loading;
}

function synth(midi, when, dur, vel = 0.5) {
  const c = audioCtx();
  const f = 440 * Math.pow(2, (midi - 69) / 12);
  const g = c.createGain();
  const lp = c.createBiquadFilter();
  lp.type = 'lowpass'; lp.frequency.value = Math.min(9000, f * 6);
  const o1 = c.createOscillator(), o2 = c.createOscillator();
  o1.type = 'triangle'; o2.type = 'sine';
  o1.frequency.value = Math.min(f, 18000); o2.frequency.value = Math.min(f * 2, 18000);
  const g2 = c.createGain(); g2.gain.value = 0.25;
  o1.connect(g); o2.connect(g2); g2.connect(g); g.connect(lp); lp.connect(c.destination);
  const peak = 0.18 * vel;
  const end = when + Math.max(0.15, dur);
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(peak, when + 0.012);
  g.gain.exponentialRampToValueAtTime(peak * 0.45, when + 0.25);
  g.gain.setValueAtTime(peak * 0.45, Math.max(when + 0.25, end - 0.08));
  g.gain.exponentialRampToValueAtTime(0.0001, end + 0.25);
  o1.start(when); o2.start(when); o1.stop(end + 0.3); o2.stop(end + 0.3);
  voices.push(o1, o2);
}

function hit(midi, when, dur, vel = 80) {
  if (piano) {
    try { piano.start({ note: midi, time: when, duration: Math.max(0.12, dur), velocity: vel }); return; } catch (e) { /* fall through */ }
  }
  synth(midi, when, dur, vel / 127);
}

export function preview(midi) {
  const c = audioCtx();
  loadPiano();
  hit(midi, c.currentTime + 0.01, 0.45, 75);
}

// events: [{time, dur, midi, measure}] in quarter notes; starts: start time of each played bar in quarters;
// order (optional): the bar played at each step, when repeats make the playing order differ from the page
// toMeasure (optional): last bar to play; with loop, the bars fromMeasure..toMeasure repeat until stop()
export async function play({ events, starts, order }, { bpm = 90, fromMeasure = 0, toMeasure = null, loop = false, onMeasure, onTime, onEnd } = {}) {
  stop();
  const c = audioCtx();
  await loadPiano();
  const spq = 60 / bpm;
  const steps = starts.length - 1;
  const step0 = order ? Math.max(0, order.indexOf(fromMeasure)) : fromMeasure;
  let step1 = steps;
  if (toMeasure !== null) {
    const i = order ? order.indexOf(toMeasure, step0) : toMeasure;
    if (i >= step0) step1 = Math.min(steps, i + 1);
  }
  const t0q = starts[step0] || 0;
  const endQ = starts[step1];
  let base = c.currentTime + 0.12;
  const schedule = (at) => {
    for (const e of events) {
      if (e.time < t0q - 1e-6 || e.time >= endQ - 1e-6) continue;
      hit(e.midi, at + (e.time - t0q) * spq, Math.min(e.dur, endQ - e.time) * spq * 0.95, 78);
    }
  };
  schedule(base);
  stopAt = base + (endQ - t0q) * spq;
  let last = -1, queued = false;
  const tick = () => {
    if (loop && !queued && c.currentTime >= stopAt - 0.25) { schedule(stopAt); queued = true; }
    if (c.currentTime >= stopAt) {
      if (!loop) { stop(); onEnd && onEnd(); return; }
      base = stopAt; stopAt = base + (endQ - t0q) * spq; queued = false; last = -1;
    }
    const q = (c.currentTime - base) / spq + t0q;
    let m = step0;
    while (m + 1 < step1 && starts[m + 1] <= q) m++;
    if (m !== last && q >= t0q) { last = m; onMeasure && onMeasure(order ? order[m] : m); }
    if (onTime && q >= t0q) onTime(q);
    timer = requestAnimationFrame(tick);
  };
  timer = requestAnimationFrame(tick);
}

export function stop() {
  if (timer) cancelAnimationFrame(timer);
  timer = null;
  if (piano) { try { piano.stop(); } catch (e) { /* ignore */ } }
  for (const v of voices) { try { v.stop(); } catch (e) { /* ignore */ } }
  voices = [];
}

export function isPlaying() { return timer !== null; }
