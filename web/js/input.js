// Note input the way the familiar notation editors do it: a caret walks through the score and the letter keys
// A-G write notes of the chosen length there (picking the octave nearest the note before), 0 writes a rest,
// R repeats the last note or chord, Shift+letter adds a chord tone above, ↑↓ move by a semitone, Alt+↑↓ by a
// scale step, Ctrl/⌘+↑↓ by an octave. Outside note input, a letter re-pitches the selected note and moves on, which
// is the quick way to correct a misread bar.
import { Score, STEPS, keyAlter, midiOf, pitchName, clefTop } from './score.js';

const TYPE_QL = { whole: 4, half: 2, quarter: 1, eighth: 0.5, '16th': 0.25, '32nd': 0.125, '64th': 0.0625 };
const TYPE_NAME = { whole: 'whole', half: 'half', quarter: 'quarter', eighth: 'eighth', '16th': '16th', '32nd': '32nd', '64th': '64th' };
const EPS = 1e-6;
const P = Score.prototype;

// ---------------------------------------------------------------- score helpers
P.voiceEvents = function (pi, mi, staff, voice) {
  return this.events(pi, mi).filter((e) => !e.grace && e.staff === staff && (voice == null || e.voice === voice)).sort((a, b) => a.onset - b.onset);
};
P.barQl = function (pi, mi) { return this.measureLength(pi, mi) / this.attrs(pi, mi).divisions; };

// Write a note (pitch) or rest (pitch null) of type/dots where ev starts, overwriting what follows in its voice, the
// way note input works in notation editors. A value too long for the rest of the bar is shortened to fit; a tuplet
// keeps its own rhythm. Returns { el, ql, fitted }.
P.overwrite = function (ev, pitch, type, dots) {
  if (ev.tuplet) {
    if (pitch) {
      if (ev.rest) this.restToNote(ev, pitch);
      else { for (const c of ev.chord.slice(1)) c.el.remove(); this.setPitch(ev.el, pitch); }
    } else if (!ev.rest) this.toRest(ev);
    this._attrCache = null;
    return { el: ev.el, ql: ev.dur / ev.div, fitted: false };
  }
  const q0 = ev.onset / ev.div;
  const room = this.barQl(ev.pi, ev.mi) - q0;
  let want = TYPE_QL[type] * (dots ? 1.5 : 1);
  let fitted = false;
  const fit = (ql) => {
    const sp = Score.split(Math.round(ql * 1024), 1024);
    if (!sp || !sp.length) return false;
    type = sp[0].type; dots = sp[0].dots; want = TYPE_QL[type] * (dots ? 1.5 : 1); fitted = true;
    return true;
  };
  if (want > room + EPS && !fit(room)) throw new Error('There is no room left in this bar');
  // free the time: the run of events from here becomes rests (a tuplet further on stops the run)
  const run = this.voiceEvents(ev.pi, ev.mi, ev.staff, ev.voice).filter((e) => e.onset >= ev.onset);
  let got = 0;
  for (const e of run) {
    if (got >= want - EPS) break;
    if (e.tuplet && e.el !== ev.el) break;
    if (!e.rest) this.toRest(e);
    got += e.dur / e.div;
  }
  if (got < want - EPS && run.length && got > EPS) fit(got);
  const fresh = this.events(ev.pi, ev.mi).find((e) => e.el === ev.el) || ev;
  const el = this.placeNote(fresh, pitch || { step: 'B', octave: 4, alter: 0 }, type, dots, 'at');
  if (!pitch) {
    const e2 = this.events(ev.pi, ev.mi).find((e) => e.el === el);
    if (e2) this.toRest(e2);
  }
  this._attrCache = null;
  return { el, ql: want, fitted, type, dots };
};

// Open another voice on a staff in a bar: a bar of rests in that voice, after a backup to the bar start.
P.addVoice = function (pi, mi, staff, voice) {
  const m = this.parts[pi].measures[mi];
  const a = this.attrs(pi, mi);
  const len = this.measureLength(pi, mi);
  let cur = 0, ref = null;
  for (const c of m.children) {
    const n = c.localName;
    if (n === 'note') {
      if (!c.querySelector(':scope > chord') && !c.querySelector(':scope > grace')) cur += +(c.querySelector(':scope > duration')?.textContent || 0);
      ref = null;
    } else if (n === 'backup') { cur -= +c.querySelector('duration').textContent; ref = null; }
    else if (n === 'forward') { cur += +c.querySelector('duration').textContent; ref = null; }
    else if (n === 'barline' && !ref) ref = c;
  }
  const add = [];
  if (cur > 0) {
    const b = this.doc.createElement('backup'); const d = this.doc.createElement('duration'); d.textContent = String(cur); b.appendChild(d); add.push(b);
  }
  for (const r of this._rests(len, a.divisions, voice, staff)) { if (a.staves > 1) this._setText(r, 'staff', staff); add.push(r); }
  for (const el of add) m.insertBefore(el, ref);
  this._attrCache = null;
};

// a semitone up or down, spelled the way a musician would: notes of the key first, then sharps going up and flats
// going down
P.stepChromatic = function (ev, noteEl, dir) {
  const m = ev.chord.find((c) => c.el === noteEl) || ev.chord[0];
  if (!m) return null;
  const fifths = this.attrs(ev.pi, ev.mi).fifths;
  const target = midiOf(m.pitch) + dir;
  const cands = [];
  for (let oct = m.pitch.octave - 1; oct <= m.pitch.octave + 1; oct++) {
    for (const step of STEPS) for (const alter of [-1, 0, 1]) {
      const p = { step, octave: oct, alter };
      if (midiOf(p) === target) cands.push(p);
    }
  }
  const score = (p) => (p.alter === keyAlter(fifths, p.step) ? 0 : p.alter === 0 ? 1 : p.alter === dir ? 2 : 3);
  cands.sort((a, b) => score(a) - score(b));
  const np = cands[0];
  if (!np) return null;
  this.setPitch(m.el, np, np.alter !== keyAlter(fifths, np.step));
  return np;
};

// the pitch of letter `step` closest to ref, in the key
export function nearestPitch(step, ref, fifths) {
  const rd = ref.octave * 7 + STEPS.indexOf(ref.step);
  const si = STEPS.indexOf(step);
  let best = null;
  for (let oct = ref.octave - 1; oct <= ref.octave + 1; oct++) {
    const idx = oct * 7 + si;
    if (best === null || Math.abs(idx - rd) < Math.abs(best - rd)) best = idx;
  }
  return { step, octave: Math.floor(best / 7), alter: keyAlter(fifths, step) };
}
// the pitch of letter `step` just above p (a chord tone added on top)
function pitchAbove(step, p, fifths) {
  const rd = p.octave * 7 + STEPS.indexOf(p.step);
  let idx = p.octave * 7 + STEPS.indexOf(step);
  while (idx <= rd) idx += 7;
  return { step, octave: Math.floor(idx / 7), alter: keyAlter(fifths, step) };
}

// ---------------------------------------------------------------- the caret
export function createNoteInput(ctx) {
  const { S } = ctx;
  const score = () => S.score;
  // S.caret = { pi, staff, voice, mi, q }   (q: quarter notes from the start of the bar)

  function caretAt(ev) {
    const vs = staffVoices(ev.pi, ev.mi, ev.staff);
    S.caret = { pi: ev.pi, staff: ev.staff, voice: ev.voice, vk: Math.max(1, vs.indexOf(ev.voice) + 1), mi: ev.mi, q: ev.onset / ev.div };
  }
  // the voices used on a staff in a bar, lowest number first
  function staffVoices(pi, mi, staff) {
    return [...new Set(score().voiceEvents(pi, mi, staff, null).map((e) => e.voice))].sort((a, b) => +a - +b);
  }
  function caretAfter(el) {
    const ev = findEv(el);
    if (!ev) return;
    caretAt(ev);
    advance(ev.dur / ev.div);
  }
  function findEv(el) {
    if (!el || !S.score) return null;
    const m = el.closest('measure'), p = m?.closest('part');
    if (!m || !p) return null;
    const pi = S.score.parts.findIndex((x) => x.el === p || x.id === p.getAttribute('id'));
    const mi = S.score.parts[pi]?.measures.indexOf(m);
    if (pi < 0 || mi < 0) return null;
    return S.score.events(pi, mi).find((e) => e.el === el || e.chord.some((c) => c.el === el)) || null;
  }
  function advance(ql) {
    const c = S.caret;
    c.q += ql;
    while (c.mi < score().nMeasures && c.q >= score().barQl(c.pi, c.mi) - EPS) {
      c.q -= score().barQl(c.pi, c.mi);
      c.mi += 1;
      if (c.q < EPS) c.q = 0;
    }
  }
  // the event under the caret, or { after } when the voice ends before the caret, or { empty } for a bar with nothing
  // on this staff
  function resolve() {
    const c = S.caret;
    if (!c || !S.score) return null;
    if (c.pi >= score().parts.length) c.pi = 0;
    if (c.mi >= score().nMeasures) return { end: true };
    // the caret writes in the staff's first, second... voice (vk), whatever numbers the file gives them
    const vs = staffVoices(c.pi, c.mi, c.staff);
    if (!vs.length) return { empty: true };
    const vk = c.vk || 1;
    if (vk > vs.length) { c.voice = String(+vs[0] + vk - 1); return { needVoice: true }; }
    c.voice = vs[vk - 1];
    const evs = score().voiceEvents(c.pi, c.mi, c.staff, c.voice);
    for (const e of evs) {
      const a = e.onset / e.div, b = (e.onset + e.dur) / e.div;
      if (c.q >= a - EPS && c.q < b - EPS) { c.q = a; return { ev: e }; }
    }
    return { after: evs[evs.length - 1] };
  }
  // the last note before the caret on this staff (looking back a few bars)
  function prevEvent() {
    const c = S.caret;
    for (let mi = Math.min(c.mi, score().nMeasures - 1); mi >= Math.max(0, c.mi - 8); mi--) {
      const evs = score().voiceEvents(c.pi, mi, c.staff, c.voice).filter((e) => !e.rest && (mi < c.mi || e.onset / e.div < c.q - EPS));
      if (evs.length) return evs[evs.length - 1];
    }
    return null;
  }
  function refPitch() {
    const prev = prevEvent();
    if (prev && !prev.rest) {
      const ch = [...prev.chord].sort((a, b) => midiOf(a.pitch) - midiOf(b.pitch));
      return ch[0].pitch;
    }
    const c = S.caret;
    const mi = Math.min(c.mi, score().nMeasures - 1);
    const a = score().attrs(c.pi, mi);
    const clef = a.clefs[c.staff] || a.clefs['1'] || { sign: 'G', line: 2 };
    return score().pitchAt(clefTop(clef) - 4, a.fifths);
  }
  const fifthsHere = () => { const c = S.caret; return score().attrs(c.pi, Math.min(c.mi, score().nMeasures - 1)).fifths; };

  function ensureCaret() {
    if (S.caret && S.caret.mi <= score().nMeasures) { resolve(); return; }
    const s = ctx.selected();
    if (s) { caretAt(s.ev); return; }
    const mi = S.measures.size ? Math.min(...S.measures) : 0;
    const ev = score().voiceEvents(0, mi, '1', null)[0];
    S.caret = { pi: 0, staff: '1', voice: ev?.voice || '1', vk: 1, mi, q: 0 };
  }
  // put the caret on the selection (entering note input on a note starts there)
  function startAtSelection() {
    const s = ctx.selected();
    if (s) caretAt(s.ev);
    else if (S.measures.size) {
      const mi = Math.min(...S.measures);
      const pi = S.caret?.pi ?? 0, staff = S.caret?.staff ?? '1';
      const ev = score().voiceEvents(pi, mi, staff, null)[0];
      S.caret = { pi, staff, voice: ev?.voice || '1', vk: 1, mi, q: 0 };
    } else ensureCaret();
  }

  // write at the caret: pitches (array) or null for a rest
  function write(pitches, { type = S.dur, dots = S.dot ? 1 : 0, tieFrom = null } = {}) {
    ensureCaret();
    let res = null;
    const ok = ctx.act(() => { res = place(pitches, type, dots, tieFrom); return res.el; });
    if (!ok || !res) return null;
    S.sel = res.el;
    S.measures = new Set([S.caret.mi]);
    advance(res.ql);
    if (res.fitted) ctx.toast(`Shortened to a ${res.dots ? 'dotted ' : ''}${TYPE_NAME[res.type]} to fit the bar`, 1800);
    if (pitches) ctx.preview(pitches.map(midiOf));
    ctx.redraw();
    ctx.scrollToBar(Math.min(S.caret.mi, score().nMeasures - 1));
    return res.el;
  }
  // the score edit behind write(), without undo or redraw (callers wrap it in one undo step)
  function place(pitches, type, dots, tieFrom = null) {
      let res;
      let r = resolve();
      if (r?.end) {
        const idx = score().insertBar(score().nMeasures - 1, 'after');
        ctx.metaInsert?.(idx);
        r = resolve();
      }
      if (r?.needVoice) {
        // the first note in a second voice: that voice gets a bar of rests, then the note goes in
        score().addVoice(S.caret.pi, S.caret.mi, S.caret.staff, S.caret.voice);
        r = resolve();
      }
      const c = S.caret;
      let el;
      if (r.empty) {
        el = score().addToEmpty(c.pi, c.mi, c.staff, pitches ? pitches[0] : { step: 'B', octave: 4, alter: 0 }, type, dots);
        if (!pitches) { const e2 = score().events(c.pi, c.mi).find((e) => e.el === el); if (e2) score().toRest(e2); }
        res = { el, ql: TYPE_QL[type] * (dots ? 1.5 : 1) };
      } else if (r.after) {
        el = score().placeNote(r.after, pitches ? pitches[0] : { step: 'B', octave: 4, alter: 0 }, type, dots, 'after');
        if (!pitches) { const e2 = score().events(c.pi, c.mi).find((e) => e.el === el); if (e2) score().toRest(e2); }
        res = { el, ql: TYPE_QL[type] * (dots ? 1.5 : 1) };
      } else {
        res = score().overwrite(r.ev, pitches ? pitches[0] : null, type, dots);
        el = res.el;
      }
      if (pitches && pitches.length > 1) {
        const ev = findEv(el);
        for (const p of pitches.slice(1)) score().addChordTone(findEv(el) || ev, p);
      }
      if (tieFrom) {
        const from = findEv(tieFrom);
        if (from && !from.rest && !score().isTied(from)) score().toggleTie(from);
      }
      return res;
  }

  // ⌘⇧↑↓: move the selected note or chord to the staff above or below (a scan often puts a piano note on the wrong
  // staff). It joins a chord already there with the same length, fills a rest, or goes in its own voice.
  function moveToStaff(dir) {
    const s = ctx.selected();
    if (!s || s.ev.rest) { ctx.toast('Select a note to move it to the other staff'); return; }
    const ev = s.ev;
    const n = score().attrs(ev.pi, ev.mi).staves || 1;
    const target = String(+ev.staff + dir);
    if (+target < 1 || +target > n) { ctx.toast(n > 1 ? `There is no staff ${dir < 0 ? 'above' : 'below'}` : 'This part has one staff'); return; }
    if (ev.tuplet) { ctx.toast('Triplet notes stay on their staff for now'); return; }
    const pitches = ev.chord.map((c) => ({ ...c.pitch }));
    const q = ev.onset / ev.div, type = ev.type || 'quarter', dots = ev.dots;
    let el = null;
    const ok = ctx.act(() => {
      score().toRest(ev);
      const evs = score().voiceEvents(ev.pi, ev.mi, target, null);
      const at = evs.find((e) => Math.abs(e.onset / e.div - q) < EPS);
      if (at && !at.rest && !at.tuplet && Math.abs(at.dur / at.div - ev.dur / ev.div) < EPS) {
        for (const p of pitches) score().addChordTone(score().events(ev.pi, ev.mi).find((e) => e.el === at.el), p);
        el = at.el;
        return;
      }
      const vs = staffVoices(ev.pi, ev.mi, target);
      const vk = at && at.rest ? vs.indexOf(at.voice) + 1 : vs.length + 1;
      const keep = S.caret;
      S.caret = { pi: ev.pi, staff: target, voice: at?.voice || '1', vk: Math.max(1, vk), mi: ev.mi, q };
      el = place(pitches, type, dots).el;
      S.caret = keep;
    });
    if (!ok || !el) return;
    S.sel = el;
    ctx.preview(pitches.map(midiOf));
    ctx.redraw();
    ctx.toast(`Moved to the ${dir < 0 ? 'upper' : 'lower'} staff`, 1200);
  }

  // the last note written (or selected) in note input, for chord tones and repeats
  function lastNote() {
    const s = ctx.selected();
    if (s && !s.ev.rest) return s.ev;
    const p = prevEvent();
    return p && !p.rest ? p : null;
  }

  function letter(step, shift) {
    if (S.mode !== 'add') return repitch(step);
    ensureCaret();
    if (shift) {
      const ln = lastNote();
      if (!ln) { ctx.toast('Write a note first, then Shift+letter adds a note above it'); return; }
      const top = [...ln.chord].sort((a, b) => midiOf(b.pitch) - midiOf(a.pitch))[0].pitch;
      const p = pitchAbove(step, top, score().attrs(ln.pi, ln.mi).fifths);
      ctx.act(() => score().addChordTone(ln, p));
      S.sel = ln.el;
      ctx.preview([midiOf(p)]);
      ctx.redraw();
      return;
    }
    write([nearestPitch(step, refPitch(), fifthsHere())]);
  }

  // select mode: give the selected note this letter (nearest octave) and move to the next note
  function repitch(step) {
    const s = ctx.selected();
    if (!s) { ctx.toast('Select a note, then type a letter to change it. Press N to write new notes.'); return; }
    const fifths = score().attrs(s.ev.pi, s.ev.mi).fifths;
    let ref = s.ev.rest ? null : s.member.pitch;
    if (!ref) { caretAt(s.ev); ref = refPitch(); }
    const p = nearestPitch(step, ref, fifths);
    if (s.ev.rest) ctx.act(() => score().restToNote(s.ev, p));
    else ctx.act(() => score().setPitch(s.member.el, p));
    ctx.preview([midiOf(p)]);
    ctx.stepSel(1, { quiet: true });
  }

  // the iPad piano outside note input: the selected note takes the key's exact pitch, then the next note is selected
  function setSelectedPitch(p) {
    const s = ctx.selected();
    if (!s) { ctx.toast('Tap a note, then a key to give it that pitch'); return; }
    const fifths = score().attrs(s.ev.pi, s.ev.mi).fifths;
    const ok = s.ev.rest
      ? ctx.act(() => { score().restToNote(s.ev, p); })
      : ctx.act(() => score().setPitch(s.member.el, p, (p.alter || 0) !== keyAlter(fifths, p.step)));
    if (!ok) return;
    ctx.preview([midiOf(p)]);
    ctx.stepSel(1, { quiet: true });
  }

  function repeat() {
    if (S.mode !== 'add') {
      const s = ctx.selected();
      if (!s) { ctx.toast('Select a note to repeat it'); return; }
      caretAfter(s.ev.el);
      const type = s.ev.type || S.dur;
      write(s.ev.rest ? null : s.ev.chord.map((c) => ({ ...c.pitch })), { type, dots: s.ev.dots });
      return;
    }
    ensureCaret();
    const p = prevEvent();
    if (!p) { ctx.toast('Nothing to repeat yet'); return; }
    write(p.rest ? null : p.chord.map((c) => ({ ...c.pitch })));
  }

  // T in note input: a note tied to the last one (same pitches) at the caret
  function tieOn() {
    const ln = lastNote();
    if (!ln) { ctx.toast('Write a note first, then T adds a tied note'); return; }
    write(ln.chord.map((c) => ({ ...c.pitch })), { tieFrom: ln.el });
  }

  function moveCaret(dir, byBar = false) {
    ensureCaret();
    const c = S.caret;
    if (byBar) {
      c.mi = Math.max(0, Math.min(score().nMeasures - 1, c.mi + dir)); c.q = 0;
    } else {
      const r = resolve();
      if (dir > 0) {
        if (r?.ev) advance(r.ev.dur / r.ev.div);
        else if (r?.after || r?.empty) { c.mi = Math.min(score().nMeasures, c.mi + 1); c.q = 0; }
      } else {
        if (c.mi >= score().nMeasures) { c.mi = score().nMeasures - 1; c.q = score().barQl(c.pi, c.mi); }
        const evs = score().voiceEvents(c.pi, c.mi, c.staff, c.voice).filter((e) => e.onset / e.div < c.q - EPS);
        if (evs.length) c.q = evs[evs.length - 1].onset / evs[evs.length - 1].div;
        else if (c.mi > 0) {
          c.mi -= 1;
          const pv = score().voiceEvents(c.pi, c.mi, c.staff, null);
          c.q = pv.length ? pv[pv.length - 1].onset / pv[pv.length - 1].div : 0;
          if (pv.length) c.voice = pv[pv.length - 1].voice;
        }
      }
    }
    const r = resolve();
    S.sel = r?.ev ? r.ev.el : null;
    S.measures = new Set([Math.min(c.mi, score().nMeasures - 1)]);
    if (r?.ev && !r.ev.rest) ctx.preview(r.ev.chord.map((x) => midiOf(x.pitch)));
    ctx.redraw();
    ctx.scrollToBar(Math.min(c.mi, score().nMeasures - 1));
  }

  // move the caret to the staff above/below
  function changeStaff(dir) {
    ensureCaret();
    const c = S.caret;
    const list = [];
    score().parts.forEach((p, pi) => { const n = score().attrs(pi, 0).staves || 1; for (let s = 1; s <= n; s++) list.push({ pi, staff: String(s) }); });
    const i = list.findIndex((x) => x.pi === c.pi && x.staff === c.staff);
    const nx = list[i + dir];
    if (!nx) return;
    c.pi = nx.pi; c.staff = nx.staff; c.vk = 1; c.voice = score().voiceEvents(nx.pi, Math.min(c.mi, score().nMeasures - 1), nx.staff, null)[0]?.voice || c.voice;
    const r = resolve();
    S.sel = r?.ev ? r.ev.el : null;
    ctx.redraw();
  }

  // Backspace in note input: step back and clear that note (it becomes a rest), like a typewriter
  function backspace() {
    ensureCaret();
    moveCaret(-1);
    const r = resolve();
    if (r?.ev && !r.ev.rest) {
      ctx.act(() => score().toRest(r.ev));
      S.sel = r.ev.el;
      ctx.redraw();
    }
  }

  // ↑↓ semitone, Alt+↑↓ scale step, Ctrl/⌘+↑↓ (or Shift) octave, on the selected note
  function pitchKey(dir, how) {
    const s = ctx.selected();
    if (!s && S.measures.size && S.mode !== 'add') return pitchBars(dir, how);
    if (!s || s.ev.rest) return;
    let p;
    const ok = ctx.act(() => {
      if (how === 'octave') {
        // an octave keeps the accidental
        const q = s.member.pitch;
        p = { ...q, octave: q.octave + dir };
        score().setPitch(s.member.el, p, !!s.member.el.querySelector(':scope > accidental'));
      }
      else if (how === 'step') p = score().moveDiatonic(s.ev, s.member.el, dir);
      else p = score().stepChromatic(s.ev, s.member.el, dir);
    });
    if (ok && p) ctx.preview([midiOf(p)]);
  }

  // with bars selected, ↑↓ / Alt+↑↓ / ⌘↑↓ move every note in them (a passage read an octave off is one keystroke)
  function pitchBars(dir, how) {
    const bars = [...S.measures].sort((a, b) => a - b);
    let n = 0;
    const ok = ctx.act(() => {
      for (const mi of bars) score().parts.forEach((part, pi) => {
        for (const e of score().events(pi, mi)) {
          if (e.rest) continue;
          if (S.barStaff && (S.barStaff.pi !== pi || S.barStaff.staff !== e.staff)) continue;
          for (const c of e.chord) {
            const fresh = score().events(pi, mi).find((x) => x.el === e.el) || e;
            if (how === 'octave') score().setPitch(c.el, { ...c.pitch, octave: c.pitch.octave + dir }, !!c.el.querySelector(':scope > accidental'));
            else if (how === 'step') score().moveDiatonic(fresh, c.el, dir);
            else score().stepChromatic(fresh, c.el, dir);
            n++;
          }
        }
      });
    });
    if (ok && n) ctx.toast(`${n} note${n > 1 ? 's' : ''} ${dir > 0 ? 'up' : 'down'} ${how === 'octave' ? 'an octave' : how === 'step' ? 'a step' : 'a semitone'}`, 1400);
  }

  // the caret: a translucent bar across the staff where the next note goes
  function drawCaret() {
    const ov = document.querySelector('#overlay');
    for (const el of ov.querySelectorAll('.caret')) el.remove();
    if (S.mode !== 'add' || !S.caret || !S.layout || !S.score) return;
    const c = S.caret;
    const mi = Math.min(c.mi, score().nMeasures - 1);
    const st = S.layout.staves.find((s) => s.mi === mi && s.pi === c.pi && s.staff === c.staff);
    if (!st) return;
    let x;
    const r = resolve();
    if (r?.ev) {
      const n = S.layout.notes.find((q) => q.ev.el === r.ev.el);
      x = n ? ctx.noteX(n) - 9 : st.x0 + 12;
    } else if (r?.after) {
      const n = S.layout.notes.find((q) => q.ev.el === r.after.el);
      x = n ? ctx.noteX(n) + 14 : st.x1 - 20;
    } else if (r?.end) x = st.x1 - 6;
    else x = st.x0 + 14;
    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    Object.entries({ x, y: st.top - 12, width: 18, height: 64, rx: 3, class: 'caret' }).forEach(([k, v]) => rect.setAttribute(k, v));
    ov.appendChild(rect);
  }

  function beatLabel() {
    const c = S.caret;
    const mi = Math.min(c.mi, score().nMeasures - 1);
    const a = score().attrs(c.pi, mi);
    const beat = 1 + c.q / (4 / a.beatType);
    return Number.isInteger(+beat.toFixed(3)) ? String(Math.round(beat)) : beat.toFixed(2).replace(/0+$/, '');
  }

  function status(touch) {
    if (!S.caret || !S.score) return '';
    const c = S.caret;
    const where = c.mi >= score().nMeasures ? 'end of the score' : `bar ${ctx.barNumber(c.mi)}, beat ${beatLabel()}`;
    const what = `${S.restMode ? 'rest' : 'note'}: ${S.dot ? 'dotted ' : ''}${TYPE_NAME[S.dur]}`;
    const staffs = score().parts.reduce((n, p, pi) => n + (score().attrs(pi, 0).staves || 1), 0);
    const staffTxt = (staffs > 1 ? ` · staff ${c.pi > 0 ? c.pi + 1 + '.' : ''}${c.staff}` : '') + ((c.vk || 1) > 1 ? ` · voice ${c.vk}` : '');
    const keys = touch
      ? 'Tap a key below or the staff to write it'
      : 'A–G write · Shift+A–G chord · 0 rest · R repeat · 1–7 length · ↑↓ semitone · ⌘↑↓ octave · ←→ move · Esc done';
    return `Note input · ${where}${staffTxt} · ${what}.  ${keys}`;
  }

  // ⌘⌥1-4: write in the staff's first to fourth voice from the caret on
  function setVoice(k) {
    ensureCaret();
    S.caret.vk = k;
    const r = resolve();
    S.sel = r?.ev ? r.ev.el : null;
    ctx.redraw();
    ctx.toast(k === 1 ? 'Voice 1' : `Voice ${k}: notes go in a separate voice on this staff${r?.needVoice ? ' (stems down)' : ''}`, 1600);
  }
  // the on-screen keyboard: write this exact pitch at the caret, or add it to the last note as a chord tone
  function writePitch(p, chord = false) {
    ensureCaret();
    if (chord) {
      const ln = lastNote();
      if (!ln) { ctx.toast('Write a note first, then add chord tones to it'); return; }
      ctx.act(() => score().addChordTone(ln, p));
      S.sel = ln.el;
      ctx.preview([midiOf(p)]);
      ctx.redraw();
      return;
    }
    write([p]);
  }
  function refPitchAt(ev) { const keep = S.caret; caretAt(ev); const r = refPitch(); S.caret = keep; return r; }
  function context() {
    if (!S.score) return null;
    const s = S.mode !== 'add' ? ctx.selected() : null;
    if (s) return { ref: s.ev.rest ? refPitchAt(s.ev) : s.member.pitch, fifths: score().attrs(s.ev.pi, s.ev.mi).fifths, staff: `${s.ev.pi}/${s.ev.staff}` };
    if (S.mode !== 'add' && !S.caret) return { ref: { step: 'B', octave: 4, alter: 0 }, fifths: score().attrs(0, 0).fifths, staff: '0/1' };
    ensureCaret();
    return { ref: refPitch(), fifths: fifthsHere(), staff: `${S.caret.pi}/${S.caret.staff}` };
  }

  return { setSelectedPitch, moveToStaff, setVoice, writePitch, context, letter, repeat, tieOn, write, moveCaret, changeStaff, backspace, pitchKey, drawCaret, status, caretAt, caretAfter, startAtSelection, ensureCaret, resolve, findEv };
}

export { pitchName };
