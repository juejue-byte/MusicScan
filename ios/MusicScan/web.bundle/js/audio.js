// Playback engine: bundled instrument samples (FluidR3 GM, MIT; built by scripts/build_sounds.py) with a built-in
// synth fallback, a look-ahead scheduler (so tempo, mute, solo and volume change live), count-in, metronome and
// speed-up-per-loop for practice.
let ctx = null, master = null, clickBus = null;
let manifest = null, manifestP = null;
const banks = {};            // instrument id -> AudioBuffer | null (failed) ; bankP: id -> Promise
const bankP = {};
const live = new Set();      // sounding sources, for stop()
const trackBus = new Map();  // track key -> GainNode
let mix = { tracks: {}, inst: {} };  // tracks: key -> {mute, solo, vol}; inst: part index -> instrument id
let T = null;                // the running transport
export const debug = { log: null };  // tests: set to [] to record what gets scheduled

const SOUNDS = new URL('../vendor/sounds/', import.meta.url);
// labels and GM programs, so the picker and MIDI export work before (or without) the manifest
export const INSTRUMENTS = [
  ['piano', 'Piano', 0], ['epiano', 'Electric piano', 4], ['organ', 'Organ', 16], ['strings', 'Strings', 48],
  ['violin', 'Violin', 40], ['cello', 'Cello', 42], ['flute', 'Flute', 73], ['clarinet', 'Clarinet', 71],
  ['choir', 'Choir', 52], ['trumpet', 'Trumpet', 56], ['sax', 'Saxophone', 65], ['guitar', 'Guitar', 24],
].map(([id, label, program]) => ({ id, label, program }));
export const programOf = (id) => (INSTRUMENTS.find((i) => i.id === id) || INSTRUMENTS[0]).program;

export function audioCtx() {
  if (!ctx) {
    ctx = new (window.AudioContext || window.webkitAudioContext)();
    master = ctx.createGain(); master.gain.value = 0.9;
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -14; comp.ratio.value = 4;
    master.connect(comp); comp.connect(ctx.destination);
    clickBus = ctx.createGain(); clickBus.gain.value = 0.7; clickBus.connect(master);
  }
  if (ctx.state === 'suspended') ctx.resume();
  return ctx;
}

async function loadManifest() {
  if (!manifestP) manifestP = fetch(new URL('sounds.json', SOUNDS)).then((r) => r.json()).then((m) => (manifest = m)).catch(() => (manifest = {}));
  return manifestP;
}

// Loads one instrument (≈150-450 KB); resolves to the buffer, or null when it can't load (then the synth plays).
export function loadInstrument(id = 'piano') {
  if (id in banks) return Promise.resolve(banks[id]);
  if (!bankP[id]) {
    bankP[id] = (async () => {
      try {
        const m = (await loadManifest())[id];
        if (!m) throw new Error('unknown instrument ' + id);
        const data = await (await fetch(new URL(m.file, SOUNDS))).arrayBuffer();
        const buf = await new Promise((res, rej) => audioCtx().decodeAudioData(data, res, rej));
        banks[id] = buf;
      } catch (e) {
        console.info(`Samples for ${id} unavailable, using the built-in synth`, e?.message);
        banks[id] = null;
      }
      return banks[id];
    })();
  }
  return bankP[id];
}
export const loadPiano = () => loadInstrument('piano');
export const samplesLoaded = (id) => !!banks[id];

function track(key) {
  audioCtx();
  let g = trackBus.get(key);
  if (!g) { g = ctx.createGain(); g.connect(master); trackBus.set(key, g); applyGain(key, g, true); }
  return g;
}
function gainFor(key) {
  const t = mix.tracks || {};
  const anySolo = Object.values(t).some((x) => x && x.solo);
  const me = t[key] || {};
  if (me.mute || (anySolo && !me.solo)) return 0;
  return me.vol ?? 1;
}
function applyGain(key, g, now) {
  const v = gainFor(key);
  if (now) g.gain.value = v; else g.gain.setTargetAtTime(v, ctx.currentTime, 0.02);
}
// mixer: {tracks: {key: {mute, solo, vol 0..1.5}}, inst: {part: id}}; applies at once, even mid-note
export function setMix(m) {
  mix = { tracks: { ...(m.tracks || {}) }, inst: { ...(m.inst || {}) } };
  for (const [k, g] of trackBus) applyGain(k, g, false);
  for (const id of new Set(Object.values(mix.inst))) loadInstrument(id);
}

// ------------------------------------------------------------------ voices
const SUSTAINED = new Set(['organ', 'strings', 'violin', 'cello', 'flute', 'clarinet', 'choir', 'trumpet', 'sax']);

function sampleVoice(id, buf, midi, when, dur, vel, dest) {
  const m = manifest[id];
  let best = 0;
  for (let i = 1; i < m.notes.length; i++) if (Math.abs(m.notes[i] - midi) < Math.abs(m.notes[best] - midi)) best = i;
  const shift = midi - m.notes[best];
  if (Math.abs(shift) > 7) return false;  // outside the instrument: let the synth take it
  const rate = Math.pow(2, shift / 12);
  const s = ctx.createBufferSource();
  s.buffer = buf; s.playbackRate.value = rate;
  const off = best * m.slot + m.lead;
  const room = (m.slot - m.lead - 0.1) / rate;   // real seconds before the slot ends
  const rel = SUSTAINED.has(id) ? 0.12 : 0.22;
  let hold = dur;
  if (m.loop && dur + rel > room) {
    s.loop = true; s.loopStart = off + m.loop[0]; s.loopEnd = off + m.loop[1];
  } else hold = Math.min(dur, room - rel);
  const g = ctx.createGain();
  const peak = (vel / 127) * 1.1;
  g.gain.setValueAtTime(0, when);
  g.gain.linearRampToValueAtTime(peak, when + 0.004);
  g.gain.setValueAtTime(peak, when + Math.max(0.005, hold));
  g.gain.setTargetAtTime(0, when + Math.max(0.005, hold), rel / 3);
  s.connect(g); g.connect(dest);
  s.start(when, off);
  s.stop(when + hold + rel * 2);
  keep(s);
  return true;
}

// built-in synth, one patch per instrument family so the picker still means something without samples
function synthVoice(id, midi, when, dur, vel, dest) {
  const f = 440 * Math.pow(2, (midi - 69) / 12);
  const P = {
    organ: { w: ['sine', 'sine', 'sine'], r: [1, 2, 4], a: [1, 0.5, 0.25], att: 0.01, dec: 0, sus: 1, rel: 0.06 },
    strings: { w: ['sawtooth', 'sawtooth'], r: [1, 1.004], a: [0.5, 0.5], att: 0.12, dec: 0, sus: 1, rel: 0.25, lp: 3 },
    violin: { w: ['sawtooth'], r: [1], a: [0.8], att: 0.07, dec: 0, sus: 1, rel: 0.18, lp: 4, vib: 5.5 },
    cello: { w: ['sawtooth'], r: [1], a: [0.8], att: 0.08, dec: 0, sus: 1, rel: 0.2, lp: 4, vib: 5 },
    flute: { w: ['sine', 'triangle'], r: [1, 2], a: [1, 0.12], att: 0.06, dec: 0, sus: 1, rel: 0.12, vib: 5 },
    clarinet: { w: ['square'], r: [1], a: [0.6], att: 0.03, dec: 0, sus: 1, rel: 0.1, lp: 2.5 },
    choir: { w: ['triangle', 'sawtooth'], r: [1, 1.003], a: [0.8, 0.25], att: 0.15, dec: 0, sus: 1, rel: 0.3, lp: 2.2, vib: 5 },
    trumpet: { w: ['sawtooth'], r: [1], a: [0.7], att: 0.03, dec: 0, sus: 1, rel: 0.08, lp: 5 },
    sax: { w: ['sawtooth', 'square'], r: [1, 1], a: [0.4, 0.3], att: 0.03, dec: 0, sus: 1, rel: 0.1, lp: 3 },
    guitar: { w: ['triangle', 'sine'], r: [1, 2], a: [1, 0.3], att: 0.004, dec: 0.5, sus: 0.0, rel: 0.2, lp: 5 },
  }[id] || { w: ['triangle', 'sine'], r: [1, 2], a: [1, 0.25], att: 0.012, dec: 0.25, sus: 0.45, rel: 0.25, lp: 6 };
  const g = ctx.createGain();
  let out = g;
  if (P.lp) { const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = Math.min(12000, f * P.lp + 400); g.connect(lp); out = lp; }
  out.connect(dest);
  const peak = 0.22 * (vel / 127);
  const end = when + Math.max(0.08, dur);
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(peak, when + P.att);
  if (P.dec) g.gain.setTargetAtTime(Math.max(0.0001, peak * P.sus), when + P.att, P.dec / 3);
  g.gain.setValueAtTime(P.dec ? Math.max(0.0001, peak * Math.max(P.sus, 0.05)) : peak, Math.max(when + P.att, end - 0.01));
  g.gain.setTargetAtTime(0.0001, end, P.rel / 3);
  let lfo = null;
  if (P.vib) { lfo = ctx.createOscillator(); lfo.frequency.value = P.vib; const d = ctx.createGain(); d.gain.value = f * 0.004; lfo.connect(d); lfo.start(when + 0.15); lfo.stop(end + P.rel * 2); lfo.d = d; keep(lfo); }
  P.w.forEach((w, i) => {
    const o = ctx.createOscillator();
    o.type = w; o.frequency.value = Math.min(f * P.r[i], 18000);
    if (lfo) lfo.d.connect(o.frequency);
    const a = ctx.createGain(); a.gain.value = P.a[i];
    o.connect(a); a.connect(g);
    o.start(when); o.stop(end + P.rel * 2);
    keep(o);
  });
}

function keep(node) { live.add(node); node.onended = () => live.delete(node); }

function hit(id, midi, when, dur, vel, dest) {
  const buf = banks[id];
  if (buf && manifest?.[id] && sampleVoice(id, buf, midi, when, dur, vel, dest)) return;
  synthVoice(id, midi, when, dur, vel, dest);
}

function click(when, accent) {
  const o = ctx.createOscillator(), g = ctx.createGain();
  o.type = 'square'; o.frequency.value = accent ? 1760 : 1175;
  g.gain.setValueAtTime(0.0001, when);
  g.gain.exponentialRampToValueAtTime(accent ? 0.5 : 0.3, when + 0.002);
  g.gain.exponentialRampToValueAtTime(0.0001, when + 0.045);
  o.connect(g); g.connect(clickBus);
  o.start(when); o.stop(when + 0.06);
  keep(o);
}

export function preview(midi, inst = 'piano') {
  audioCtx();
  loadInstrument(inst);
  hit(inst, midi, ctx.currentTime + 0.01, 0.45, 75, master);
}

// ------------------------------------------------------------------ transport
// Beat positions (in quarters, from the bar start) for one bar: compound meters click on dotted quarters; a short
// bar (pickup or a bar split by a repeat) counts its beats back from the bar end, so it lands on the right beats.
export function beatsOf(meter, len) {
  const { beats = 4, beatType = 4 } = meter || {};
  const compound = beatType === 8 && beats % 3 === 0 && beats > 3;
  const step = compound ? 1.5 : 4 / beatType;
  const nominal = beats * 4 / beatType;
  const out = [];
  if (len >= nominal - 1e-6) { for (let q = 0; q < len - 1e-6; q += step) out.push({ q, accent: q === 0 }); }
  else { for (let q = nominal - step; q > -1e-6; q -= step) if (q - (nominal - len) > -1e-6) out.unshift({ q: q - (nominal - len), accent: q === 0 }); }
  return out;
}

// events: [{time, dur, midi, part, track}] in quarter notes; starts: start time of each played step in quarters;
// order: the bar played at each step (repeats); meters: {beats, beatType} per step.
// opts: bpm, fromMeasure, toMeasure, loop, countIn (bars), metronome, speedUp {step, max} (bpm per loop pass),
// onMeasure(bar), onTime(q), onCount(n, of) during the count-in, onTempo(bpm) when speed-up changes it, onEnd.
export async function play({ events, starts, order, meters }, opts = {}) {
  stop();
  audioCtx();
  await Promise.race([
    Promise.all([loadManifest(), ...[...new Set([...Object.values(mix.inst), 'piano'])].map(loadInstrument)]),
    new Promise((r) => setTimeout(r, 6000)),
  ]);
  reopenBuses();
  const { fromMeasure = 0, toMeasure = null, loop = false } = opts;
  const steps = starts.length - 1;
  const step0 = order ? Math.max(0, order.indexOf(fromMeasure)) : fromMeasure;
  let step1 = steps;
  if (toMeasure !== null) {
    const i = order ? order.indexOf(toMeasure, step0) : toMeasure;
    if (i >= step0) step1 = Math.min(steps, i + 1);
  }
  const t0q = starts[step0] || 0, endQ = starts[step1];
  // one pass of the range: notes + metronome clicks, by time
  const notes = events.filter((e) => e.time >= t0q - 1e-6 && e.time < endQ - 1e-6);
  const clicks = [];
  for (let s = step0; s < step1; s++) for (const b of beatsOf(meters?.[s], starts[s + 1] - starts[s])) clicks.push({ time: starts[s] + b.q, accent: b.accent, click: true });
  const pass = [...notes, ...clicks].sort((a, b) => a.time - b.time);
  // count-in: whole bars of the first bar's meter, plus the beats a pickup leaves out
  const m0 = meters?.[step0] || { beats: 4, beatType: 4 };
  const nominal = m0.beats * 4 / m0.beatType, len0 = starts[step0 + 1] - t0q;
  const pre = opts.countIn ? opts.countIn * nominal + Math.max(0, nominal - len0) : 0;
  const pre0 = [];
  if (pre) {
    const bb = beatsOf(m0, nominal);
    for (let bar = 0; bar * nominal < pre - 1e-6; bar++) bb.forEach((b, k) => {
      const q = t0q - pre + bar * nominal + b.q;
      if (q < t0q - 1e-6) pre0.push({ time: q, accent: b.accent, click: true, count: k + 1 });
    });
  }
  T = {
    opts, steps: { starts, order, step0, step1 }, t0q, endQ, pass, metro: !!opts.metronome,
    bpm: opts.bpm || 90, items: [...pre0, ...pass], idx: 0, passNo: 0,
    anchorT: ctx.currentTime + 0.12, anchorQ: t0q - pre, last: -1, countN: pre0.length, counted: 0, done: false,
  };
  T.timer = setInterval(pump, 25);
  pump();
  T.raf = requestAnimationFrame(ui);
}

const spq = () => 60 / T.bpm;
const timeAt = (q) => T.anchorT + (q - T.anchorQ) * spq();
const qAt = (t) => T.anchorQ + (t - T.anchorT) / spq();

function pump() {
  if (!T) return;
  const horizon = ctx.currentTime + 0.2;
  for (;;) {
    if (T.idx >= T.items.length) {
      // end of a pass
      const endT = timeAt(T.endQ);
      if (!T.opts.loop) { if (ctx.currentTime >= endT + 0.05) finish(); return; }
      if (endT > horizon) return;
      // next pass starts exactly where this one ends; speed-up changes the tempo at the seam
      T.anchorT = endT; T.anchorQ = T.t0q; T.items = T.pass; T.idx = 0; T.passNo++;
      const su = T.opts.speedUp;
      if (su && su.step) {
        const nb = Math.min(su.max || 999, T.bpm + su.step);
        if (nb !== T.bpm) { T.bpm = nb; const at = endT; setTimeout(() => T && T.opts.onTempo && T.opts.onTempo(nb), Math.max(0, (at - ctx.currentTime) * 1000)); }
      }
      continue;
    }
    const it = T.items[T.idx];
    const when = timeAt(it.time);
    if (when > horizon) return;
    T.idx++;
    if (when < ctx.currentTime - 0.05) continue;   // late (tab was asleep): skip, don't pile up
    if (debug.log) debug.log.push(it.click ? { t: when, click: true, count: !!it.count, on: !!(it.count || T.metro), accent: it.accent } : { t: when, midi: it.midi, track: it.track, part: it.part, q: it.time, bpm: T.bpm, pass: T.passNo });
    if (it.click) { if (it.count || T.metro) click(Math.max(when, ctx.currentTime), it.accent); continue; }
    const dur = Math.min(it.dur, T.endQ - it.time) * spq() * 0.96;
    hit(mix.inst[it.part] || 'piano', it.midi, Math.max(when, ctx.currentTime), dur, it.vel || 80, track(it.track || `${it.part}`));
  }
}

function ui() {
  if (!T) return;
  const q = qAt(ctx.currentTime);
  const { starts, order, step0, step1 } = T.steps;
  if (q < T.t0q - 1e-6) {
    // count-in: report the beat number
    const k = T.items.slice(0, T.countN).filter((x) => x.count && timeAt(x.time) <= ctx.currentTime).length;
    if (k && k !== T.counted) { T.counted = k; T.opts.onCount && T.opts.onCount(T.items[k - 1].count, T.countN); }
  } else {
    if (T.counted) { T.counted = 0; T.opts.onCount && T.opts.onCount(0, T.countN); }
    const qq = Math.min(q, T.endQ - 1e-6);
    let m = step0;
    while (m + 1 < step1 && starts[m + 1] <= qq) m++;
    if (m !== T.last) { T.last = m; T.opts.onMeasure && T.opts.onMeasure(order ? order[m] : m); }
    T.opts.onTime && T.opts.onTime(qq);
  }
  T.raf = requestAnimationFrame(ui);
}

function finish() { const cb = T?.opts.onEnd; stop(); cb && cb(); }

// live changes while playing
export function setTempo(bpm) {
  if (!T || !(bpm > 0) || bpm === T.bpm) { if (T) T.bpm = bpm || T.bpm; return; }
  const now = ctx.currentTime, q = qAt(now);
  T.anchorQ = q; T.anchorT = now; T.bpm = bpm;
}
export function setMetronome(on) { if (T) T.metro = !!on; }
export function setSpeedUp(su) { if (T) T.opts.speedUp = su; }
export function tempo() { return T ? T.bpm : null; }

export function stop() {
  if (T) { clearInterval(T.timer); cancelAnimationFrame(T.raf); T = null; }
  if (!ctx) return;
  const t = ctx.currentTime;
  for (const g of trackBus.values()) { g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(g.gain.value, t); g.gain.linearRampToValueAtTime(0, t + 0.03); }
  for (const n of live) { try { n.stop(t + 0.035); } catch (e) { /* ignore */ } }
  live.clear();
  // reopen the buses after the fade
  setTimeout(reopenBuses, 60);
}
function reopenBuses() {
  const t = ctx.currentTime;
  for (const [k, g] of trackBus) { g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(gainFor(k), t + 0.04); }
}

export function isPlaying() { return T !== null; }
