// Practice panel: tempo slider (with speed-up on each loop), count-in, metronome, and a mixer with mute / solo /
// volume per hand, staff or voice and an instrument per part. Settings apply live while playing.
import * as audio from './audio.js';

const $ = (s, r = document) => r.querySelector(s);
const LS = 'musicscan:practice';
const P = {
  countIn: 0, metronome: false, speedUp: false, step: 5, target: 100,  // remembered between scores
  written: 90, bpm: 90, startBpm: null,
  parts: [],     // [{pi, label, inst, tracks: [{key, label}]}]
  tracks: {},    // key -> {mute, solo, vol}
  split: {},     // `${pi}/${staff}` -> true when the staff's voices get their own rows
};
let onTempoField = () => {}, hint = () => {};
try { Object.assign(P, JSON.parse(localStorage.getItem(LS) || '{}')); } catch (e) { /* private mode */ }
const save = () => { try { localStorage.setItem(LS, JSON.stringify({ countIn: P.countIn, metronome: P.metronome, speedUp: P.speedUp, step: P.step, target: P.target })); } catch (e) { /* ignore */ } };

const VOICE_NAMES = { soprano: 'Soprano', alto: 'Alto', tenor: 'Tenor', bass: 'Bass' };
function guessInst(name) {
  const n = (name || '').toLowerCase();
  const table = [[/sopran|alto\b|tenor|bass\b|bariton|choir|chorus|voice|vocal|satb|^[satb]\.?$/, 'choir'], [/violin|viola/, 'violin'],
    [/cello|contrabass|double bass/, 'cello'], [/flute|piccolo/, 'flute'], [/clarinet|oboe|bassoon/, 'clarinet'],
    [/trumpet|horn|trombone|cornet/, 'trumpet'], [/sax/, 'sax'], [/guitar/, 'guitar'], [/organ/, 'organ'], [/string/, 'strings']];
  for (const [re, id] of table) if (re.test(n)) return id;
  return null;
}

// Work out the rows of the mixer from the score: hands for piano, S/A/T/B for choir, voices sharing a staff.
export function setScore(score) {
  P.parts = []; P.tracks = {}; P.split = {};
  if (!score) return render();
  P.written = Math.round(score.tempo()) || 90;
  P.bpm = P.written;
  const nP = score.parts.length;
  const info = score.parts.map((p, pi) => {
    const a = score.attrs(pi, 0) || {};
    const staves = a.staves || 1;
    const voices = {};  // staff -> {voice: notes}
    for (let mi = 0; mi < score.nMeasures; mi++) for (const e of score.events(pi, mi)) {
      if (e.rest || e.grace) continue;
      ((voices[e.staff] ||= {})[e.voice] ||= 0);
      voices[e.staff][e.voice] += e.chord.length;
    }
    const clefs = Object.values(a.clefs || {}).map((c) => c.sign);
    return { pi, name: p.name || '', staves, voices, clefs };
  });
  const generic = (n) => !n || /^(part|staff|p)\s*\d*$/i.test(n.trim());
  const choirish = info.some((x) => guessInst(x.name) === 'choir') || (nP === 4 && info.every((x) => x.staves === 1 && generic(x.name)));
  info.forEach((x, k) => {
    const piano = x.staves === 2 && !choirish;
    let label = generic(x.name) ? (nP === 1 ? (piano ? 'Piano' : 'Music') : `Part ${k + 1}`) : x.name;
    if (choirish && nP === 4 && generic(x.name)) label = ['Soprano', 'Alto', 'Tenor', 'Bass'][k];
    const inst = guessInst(x.name) || (choirish ? 'choir' : 'piano');
    const tracks = [];
    const staffs = Object.keys(x.voices).length ? Object.keys(x.voices).sort() : ['1'];
    for (const st of staffs) {
      const v = x.voices[st] || {};
      const tot = Object.values(v).reduce((s, n) => s + n, 0);
      const big = Object.entries(v).filter(([, n]) => n >= tot * 0.25).map(([id]) => id).sort((a, b) => a - b);
      const stLabel = piano ? (st === '1' ? 'Right hand' : 'Left hand') : x.staves > 1 ? `Staff ${st}` : null;
      if (!piano && big.length === 2) {
        // two real voices on one staff (closed-score choir, divisi): one row each
        P.split[`${x.pi}/${st}`] = true;
        const treble = (x.clefs[+st - 1] || x.clefs[0]) !== 'F';
        const names = choirish ? (treble ? ['Soprano', 'Alto'] : ['Tenor', 'Bass']) : ['Upper voice', 'Lower voice'];
        big.forEach((vid, j) => tracks.push({ key: `${x.pi}/${st}/${vid}`, label: (stLabel ? stLabel + ' · ' : '') + names[j], voices: [vid] }));
        // stray voices on that staff follow the nearer real voice
        for (const vid of Object.keys(v)) if (!big.includes(vid)) tracks[tracks.length - (+vid < +big[1] ? 2 : 1)].voices.push(vid);
      } else tracks.push({ key: `${x.pi}/${st}`, label: stLabel || label });
    }
    P.parts.push({ pi: x.pi, label, inst, tracks });
  });
  pushMix();
  render();
}

export function trackOf(e) {
  const k = `${e.part}/${e.staff || '1'}`;
  if (!P.split[k]) return k;
  const p = P.parts.find((x) => x.pi === e.part);
  const t = p?.tracks.find((x) => x.key.startsWith(k + '/') && x.voices.includes(e.voice));
  return t ? t.key : k;
}

// options for audio.play() from the panel
export function playOptions(loop) {
  P.startBpm = P.bpm;
  const su = loop && P.speedUp ? { step: P.step, max: Math.max(P.bpm, Math.round(P.written * P.target / 100)) } : null;
  return { bpm: P.bpm, countIn: P.countIn, metronome: P.metronome, speedUp: su, onTempo: (b) => setBpm(b, false, true), onCount: showCount };
}
export function stopped() {
  showCount(0);
  if (P.startBpm && P.speedUp && P.bpm !== P.startBpm) { setBpm(P.startBpm, false); }
  P.startBpm = null;
}
export const programs = () => { const out = []; for (const p of P.parts) out[p.pi] = audio.programOf(p.inst); return out; };
export const instOf = (pi) => P.parts.find((p) => p.pi === pi)?.inst || 'piano';

export function setBpm(b, fromField = false, fromEngine = false) {
  P.bpm = Math.max(30, Math.min(240, Math.round(b) || P.written));
  if (!fromField) onTempoField(P.bpm);
  if (!fromEngine) audio.setTempo(P.bpm);
  syncTempo();
}

function pushMix() {
  const inst = {};
  for (const p of P.parts) inst[p.pi] = p.inst;
  audio.setMix({ tracks: P.tracks, inst });
  $('#btnPractice')?.classList.toggle('dot', Object.values(P.tracks).some((t) => t.mute || t.solo || (t.vol ?? 1) !== 1) || P.metronome || !!P.countIn || P.speedUp);
}

// ------------------------------------------------------------------ count-in overlay
function showCount(n, of) {
  let el = $('#countIn');
  if (!el) { el = document.createElement('div'); el.id = 'countIn'; el.setAttribute('aria-live', 'polite'); document.body.appendChild(el); }
  if (!n) { el.classList.remove('on'); return; }
  el.textContent = String(n);
  el.classList.remove('on'); void el.offsetWidth; el.classList.add('on');
}

// ------------------------------------------------------------------ panel
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function render() {
  const box = $('#practicePanel');
  if (!box) return;
  const seg = (name, val, opts) => `<div class="pseg" data-k="${name}">${opts.map(([v, l]) => `<button data-v="${v}" class="${String(v) === String(val) ? 'on' : ''}">${l}</button>`).join('')}</div>`;
  const instSel = (p) => `<select data-inst="${p.pi}" aria-label="Instrument for ${esc(p.label)}">${audio.INSTRUMENTS.map((i) => `<option value="${i.id}"${i.id === p.inst ? ' selected' : ''}>${i.label}</option>`).join('')}</select>`;
  const row = (t, head) => {
    const s = P.tracks[t.key] || {};
    return `<div class="ptrack${s.mute ? ' muted' : ''}" data-key="${t.key}">
      <span class="pname">${esc(t.label)}</span>${head || ''}
      <button class="pm${s.mute ? ' on' : ''}" data-act="mute" title="Mute" aria-pressed="${!!s.mute}">M</button>
      <button class="ps${s.solo ? ' on' : ''}" data-act="solo" title="Solo: hear only this" aria-pressed="${!!s.solo}">S</button>
      <input type="range" min="0" max="150" value="${Math.round((s.vol ?? 1) * 100)}" data-act="vol" aria-label="Volume of ${esc(t.label)}"></div>`;
  };
  const parts = P.parts.map((p) => p.tracks.length === 1 && p.tracks[0].label === p.label
    ? `<div class="ppart">${row(p.tracks[0], instSel(p))}</div>`
    : `<div class="ppart"><div class="phead"><span class="pname">${esc(p.label)}</span>${instSel(p)}</div>${p.tracks.map((t) => row(t)).join('')}</div>`).join('');
  box.innerHTML = `
    <div class="ptitle"><b>Practice</b><button class="btn icon small" id="practiceClose" aria-label="Close">✕</button></div>
    <div class="psec"><div class="plabel">Tempo <span id="pTempoTxt"></span></div>
      <div class="prow"><button class="btn icon" data-bpm="-5" aria-label="Slower">−</button>
        <input type="range" id="pTempo" min="30" max="240" step="1" aria-label="Tempo">
        <button class="btn icon" data-bpm="5" aria-label="Faster">+</button></div>
      <div class="prow chips">${[50, 75, 100].map((x) => `<button class="chip" data-pct="${x}">${x}%</button>`).join('')}</div>
      <label class="pcheck"><input type="checkbox" id="pSpeed"${P.speedUp ? ' checked' : ''}> Speed up each loop</label>
      <div class="pgrid sub${P.speedUp ? '' : ' off'}" id="pSpeedRow"><span>Add</span>${seg('step', P.step, [[2, '+2'], [5, '+5'], [10, '+10']])}<span>Stop at</span>${seg('target', P.target, [[90, '90%'], [100, '100%'], [120, '120%']])}</div>
    </div>
    <div class="psec two"><div><div class="plabel">Count-in</div>${seg('countIn', P.countIn, [[0, 'Off'], [1, '1 bar'], [2, '2 bars']])}</div>
      <div><div class="plabel">Click</div>${seg('metronome', P.metronome ? 1 : 0, [[0, 'Off'], [1, 'On']])}</div></div>
    <div class="psec"><div class="plabel">Parts <span class="muted">M mutes · S plays only that part</span></div>${parts || '<div class="muted">Open a score first.</div>'}
      ${Object.keys(P.tracks).length ? '<button class="btn small" id="pReset">Hear everything</button>' : ''}</div>`;
  syncTempo();
  wirePanel(box);
}
function syncTempo() {
  const r = $('#pTempo');
  if (!r) return;
  r.value = P.bpm;
  $('#pTempoTxt').textContent = `♩ = ${P.bpm} · ${Math.round(P.bpm / P.written * 100)}%`;
  for (const c of document.querySelectorAll('#practicePanel [data-pct]')) c.classList.toggle('on', Math.round(P.written * c.dataset.pct / 100) === P.bpm);
}
function wirePanel(box) {
  box.onclick = (e) => e.stopPropagation();
  $('#practiceClose').onclick = () => close();
  $('#pTempo').oninput = (e) => setBpm(+e.target.value);
  for (const b of box.querySelectorAll('[data-bpm]')) b.onclick = () => setBpm(P.bpm + +b.dataset.bpm);
  for (const b of box.querySelectorAll('[data-pct]')) b.onclick = () => setBpm(P.written * b.dataset.pct / 100);
  $('#pSpeed').onchange = (e) => {
    P.speedUp = e.target.checked; save(); render(); pushMix(); audio.setSpeedUp(playOptions(true).speedUp);
    if (P.speedUp && !document.querySelector('#btnLoop.on')) hint('Turn on Loop (L) to speed up on each repeat.');
  };
  for (const s of box.querySelectorAll('.pseg')) for (const b of s.querySelectorAll('button')) b.onclick = () => {
    const k = s.dataset.k, v = +b.dataset.v;
    if (k === 'metronome') { P.metronome = !!v; audio.setMetronome(P.metronome); } else P[k] = v;
    if (k === 'step' || k === 'target') audio.setSpeedUp(playOptions(true).speedUp);
    save(); render(); pushMix();
  };
  for (const sel of box.querySelectorAll('[data-inst]')) sel.onchange = () => {
    const p = P.parts.find((x) => x.pi === +sel.dataset.inst);
    p.inst = sel.value; pushMix();
    audio.loadInstrument(p.inst).then(() => { if (!audio.isPlaying()) audio.preview(60, p.inst); });
  };
  for (const r of box.querySelectorAll('.ptrack')) {
    const key = r.dataset.key;
    const st = () => (P.tracks[key] ||= {});
    r.querySelector('[data-act=mute]').onclick = () => { st().mute = !st().mute; pushMix(); render(); };
    r.querySelector('[data-act=solo]').onclick = () => { st().solo = !st().solo; if (st().solo) st().mute = false; pushMix(); render(); };
    r.querySelector('[data-act=vol]').oninput = (e) => { st().vol = +e.target.value / 100; pushMix(); };
  }
  const reset = $('#pReset');
  if (reset) reset.onclick = () => { P.tracks = {}; pushMix(); render(); };
}

export function open() {
  const box = $('#practicePanel');
  render();
  box.classList.add('open');
  $('#btnPractice').setAttribute('aria-expanded', 'true');
  const b = $('#btnPractice').getBoundingClientRect();
  if (window.innerWidth >= 600) { box.style.top = `${b.bottom + 8}px`; box.style.right = `${Math.max(8, window.innerWidth - b.right - 60)}px`; }
  else { box.style.top = ''; box.style.right = ''; }
}
export function close() { $('#practicePanel')?.classList.remove('open'); $('#btnPractice')?.setAttribute('aria-expanded', 'false'); }
export const toggle = () => ($('#practicePanel').classList.contains('open') ? close() : open());

// m: metronome, [ and ]: tempo -/+5 (while editing, not typing)
export function key(e) {
  if (e.metaKey || e.ctrlKey || e.altKey) return false;
  if (e.key === 'm' || e.key === 'M') { P.metronome = !P.metronome; audio.setMetronome(P.metronome); save(); pushMix(); render(); hint(P.metronome ? 'Click on.' : 'Click off.'); return true; }
  if (e.key === '[' || e.key === ']') { setBpm(P.bpm + (e.key === ']' ? 5 : -5)); hint(`♩ = ${P.bpm} (${Math.round(P.bpm / P.written * 100)}%)`); return true; }
  return false;
}

export function init({ tempoField, toast }) {
  onTempoField = tempoField; hint = toast;
  document.addEventListener('click', (e) => { if (!e.target.closest('#practicePanel, #btnPractice')) close(); });
}
export const state = P;   // for tests
