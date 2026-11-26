// MusicXML document model for MusicScan. All edits patch the MusicXML DOM in place, so anything the editor
// does not touch (slurs, dynamics, articulations, beams on other bars) survives every edit and export.

export const STEPS = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const SEMI = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
const SHARP_ORDER = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
const FLAT_ORDER = ['B', 'E', 'A', 'D', 'G', 'C', 'F'];
export const TYPES = ['whole', 'half', 'quarter', 'eighth', '16th', '32nd', '64th'];
const TYPE_QL = { breve: 8, whole: 4, half: 2, quarter: 1, eighth: 0.5, '16th': 0.25, '32nd': 0.125, '64th': 0.0625 };
// top staff line as a diatonic index (octave*7 + step) per clef
const CLEF_TOP = { G2: 38, F4: 26, C3: 32, C4: 30, C1: 36, F3: 28, G1: 40 };

const gcd = (a, b) => (b ? gcd(b, a % b) : Math.abs(a));
const lcm = (a, b) => (a * b) / gcd(a, b);

export function keyAlter(fifths, step) {
  if (fifths > 0 && SHARP_ORDER.slice(0, fifths).includes(step)) return 1;
  if (fifths < 0 && FLAT_ORDER.slice(0, -fifths).includes(step)) return -1;
  return 0;
}
export function midiOf(p) { return 12 * (p.octave + 1) + SEMI[p.step] + (p.alter || 0); }
export function pitchName(p) {
  const acc = { '-2': '𝄫', '-1': '♭', '0': '', '1': '♯', '2': '𝄪' }[String(p.alter || 0)];
  return `${p.step}${acc}${p.octave}`;
}
export function clefKey(c) { return c ? `${c.sign}${c.line}` : 'G2'; }
export function clefTop(c) {
  const base = CLEF_TOP[clefKey(c)] ?? 38;
  return base + 7 * (c?.octaveChange || 0);
}
function child(el, name) { for (const c of el.children) if (c.localName === name) return c; return null; }
function children(el, name) { return [...el.children].filter((c) => c.localName === name); }
function txt(el, name, d = null) { const c = child(el, name); return c ? c.textContent.trim() : d; }

export class Score {
  static _ids = 0;
  constructor(xml) {
    this.load(xml);
  }

  load(xml) {
    const doc = new DOMParser().parseFromString(xml, 'application/xml');
    if (doc.querySelector('parsererror')) throw new Error('Could not read this MusicXML file');
    if (doc.documentElement.localName === 'score-timewise') throw new Error('Timewise MusicXML is not supported');
    this.doc = doc;
    this.root = doc.documentElement;
    const names = {};
    for (const sp of this.root.querySelectorAll('part-list > score-part')) names[sp.getAttribute('id')] = txt(sp, 'part-name', '');
    this.parts = children(this.root, 'part').map((p) => ({ id: p.getAttribute('id'), el: p, name: names[p.getAttribute('id')] || '', measures: children(p, 'measure') }));
    this.nMeasures = Math.max(0, ...this.parts.map((p) => p.measures.length));
    this._attrCache = null;
    // events() is read many times per redraw (layout, widths, overflow checks): cache it per bar, and let a
    // MutationObserver say which bars an edit touched. takeRecords() is synchronous, so the cache is never stale.
    this._mo?.disconnect();
    this._evCache = new WeakMap();
    this._barVer = new WeakMap();
    this._barId = new WeakMap();
    this._rev = 0;
    this._xml = null;
    this._mo = typeof MutationObserver === 'undefined' ? null : new MutationObserver(() => {});
    this._mo?.observe(doc, { subtree: true, childList: true, attributes: true, characterData: true });
  }

  _dropStaleEvents() {
    if (!this._mo) return;
    const recs = this._mo.takeRecords();
    if (!recs.length) return;
    this._rev++;
    const touched = new Set();
    for (const r of recs) {
      let n = r.target;
      while (n && n.localName !== 'measure') n = n.parentNode;
      if (n) touched.add(n);
      // a bar taken out of or put into a part
      for (const x of [...r.addedNodes, ...r.removedNodes]) if (x.localName === 'measure') touched.add(x);
    }
    for (const m of touched) { this._evCache.delete(m); this._barVer.set(m, (this._barVer.get(m) || 0) + 1); }
  }

  // changes whenever the bar's MusicXML does (and differs between bar elements); null when edits are not tracked
  barRevision(m) {
    if (!this._mo || !m) return null;
    this._dropStaleEvents();
    let id = this._barId.get(m);
    if (!id) { id = ++Score._ids; this._barId.set(m, id); }
    return id + '.' + (this._barVer.get(m) || 0);
  }

  toXML() {
    // the undo snapshot and the autosave both ask for it, often with nothing changed in between
    if (this._mo) { this._dropStaleEvents(); if (this._xml && this._xml.rev === this._rev) return this._xml.s; }
    let s = new XMLSerializer().serializeToString(this.doc);
    if (!s.startsWith('<?xml')) s = '<?xml version="1.0" encoding="UTF-8"?>\n' + s;
    if (this._mo) this._xml = { rev: this._rev, s };
    return s;
  }

  refresh() {
    for (const p of this.parts) p.measures = children(p.el, 'measure');
    this.nMeasures = Math.max(0, ...this.parts.map((p) => p.measures.length));
    this._attrCache = null;
  }

  // attributes in force at the start of every measure, per part
  attrs(pi, mi) {
    if (!this._attrCache) this._computeAttrs();
    return this._attrCache[pi][mi];
  }

  _computeAttrs() {
    this._attrCache = this.parts.map((p) => {
      const cur = { divisions: 1, fifths: 0, beats: 4, beatType: 4, staves: 1, clefs: { 1: { sign: 'G', line: 2, octaveChange: 0 } }, timeShown: false };
      const out = [];
      p.measures.forEach((m, mi) => {
        const start = { ...cur, clefs: { ...cur.clefs }, changed: {} };
        // attributes at the very start of the bar count as the bar's own attributes
        for (const c of m.children) {
          if (c.localName === 'note') break;
          if (c.localName === 'attributes') this._applyAttrs(c, start, true);
        }
        out.push(start);
        Object.assign(cur, { ...start, clefs: { ...start.clefs } });
        for (const a of children(m, 'attributes')) this._applyAttrs(a, cur, false);
      });
      return out;
    });
  }

  _applyAttrs(a, st, markChanged) {
    const d = txt(a, 'divisions');
    if (d) st.divisions = parseInt(d, 10);
    const k = a.querySelector('key > fifths');
    if (k) { st.fifths = parseInt(k.textContent, 10); if (markChanged) st.changed.key = true; }
    const t = child(a, 'time');
    if (t && txt(t, 'beats')) { st.beats = parseInt(txt(t, 'beats'), 10); st.beatType = parseInt(txt(t, 'beat-type'), 10); if (markChanged) st.changed.time = true; }
    const sv = txt(a, 'staves');
    if (sv) st.staves = parseInt(sv, 10);
    for (const c of children(a, 'clef')) {
      const n = c.getAttribute('number') || '1';
      st.clefs[n] = { sign: txt(c, 'sign', 'G'), line: parseInt(txt(c, 'line', '2'), 10), octaveChange: parseInt(txt(c, 'clef-octave-change', '0'), 10) };
      if (markChanged) st.changed['clef' + n] = true;
    }
  }

  // The events of one measure: notes/rests with onsets (in divisions), chord members grouped.
  events(pi, mi) {
    const m = this.parts[pi]?.measures[mi];
    if (!m) return [];
    const a = this.attrs(pi, mi);
    let key = null;
    if (this._mo) {
      this._dropStaleEvents();
      key = `${pi}/${mi}/${a.divisions}/${JSON.stringify(a.clefs)}`;
      const hit = this._evCache.get(m);
      if (hit && hit.key === key) return hit.evs.slice();
    }
    const evs = this._readEvents(m, pi, mi, a);
    if (key) this._evCache.set(m, { key, evs: evs.slice() });
    return evs;
  }

  _readEvents(m, pi, mi, a) {
    let div = a.divisions;
    const clefs = { ...a.clefs };
    let cur = 0, last = null;
    const evs = [];
    for (const c of m.children) {
      const n = c.localName;
      if (n === 'attributes') {
        const d = txt(c, 'divisions'); if (d) div = parseInt(d, 10);
        for (const cl of children(c, 'clef')) clefs[cl.getAttribute('number') || '1'] = { sign: txt(cl, 'sign', 'G'), line: parseInt(txt(cl, 'line', '2'), 10), octaveChange: parseInt(txt(cl, 'clef-octave-change', '0'), 10) };
      }
      else if (n === 'backup') cur -= +txt(c, 'duration', 0);
      else if (n === 'forward') cur += +txt(c, 'duration', 0);
      else if (n === 'note') {
        const grace = child(c, 'grace') !== null;
        const chord = child(c, 'chord') !== null;
        const dur = grace ? 0 : +txt(c, 'duration', 0);
        const p = child(c, 'pitch');
        const pitch = p ? { step: txt(p, 'step'), octave: +txt(p, 'octave'), alter: +txt(p, 'alter', 0) } : null;
        if (chord && last) {
          if (pitch) last.chord.push({ el: c, pitch });
          continue;
        }
        const ev = {
          el: c, pi, mi, onset: cur, dur, div, grace,
          rest: child(c, 'rest') !== null || !pitch,
          hidden: c.getAttribute('print-object') === 'no',
          staff: txt(c, 'staff', '1'), voice: txt(c, 'voice', '1'),
          clef: clefs[txt(c, 'staff', '1')] || clefs['1'] || { sign: 'G', line: 2, octaveChange: 0 },
          type: txt(c, 'type'), dots: children(c, 'dot').length,
          tuplet: child(c, 'time-modification') ? { actual: +c.querySelector('time-modification > actual-notes').textContent, normal: +c.querySelector('time-modification > normal-notes').textContent } : null,
          measureRest: child(c, 'rest')?.getAttribute('measure') === 'yes',
          chord: pitch ? [{ el: c, pitch }] : [],
          tieStop: [...c.querySelectorAll(':scope > tie')].some((t) => t.getAttribute('type') === 'stop'),
          explicitAcc: txt(c, 'accidental'),
          fermata: (() => { const f = c.querySelector(':scope > notations > fermata'); return f ? (f.getAttribute('type') || 'upright') : null; })(),
        };
        if (!grace) { cur += dur; last = ev; }
        evs.push(ev);
      }
    }
    return evs;
  }

  measureLength(pi, mi) {
    const a = this.attrs(pi, mi);
    return (a.beats * 4 / a.beatType) * a.divisions;
  }

  // per (staff, voice): does it overflow / underfill the bar?
  measureProblems(pi, mi) {
    const len = this.measureLength(pi, mi);
    const ends = {};
    for (const e of this.events(pi, mi)) {
      if (e.grace) continue;
      const k = `${e.staff}/${e.voice}`;
      ends[k] = Math.max(ends[k] || 0, e.onset + e.dur);
    }
    const over = Object.values(ends).some((v) => v > len + 1e-6);
    return { over, len, ends };
  }

  // ---------- edits ----------
  setPitch(noteEl, pitch, explicitAccidental = false) {
    let p = child(noteEl, 'pitch');
    const r = child(noteEl, 'rest');
    if (!p) {
      p = this.doc.createElement('pitch');
      if (r) noteEl.replaceChild(p, r); else noteEl.insertBefore(p, child(noteEl, 'duration'));
    }
    p.textContent = '';
    const add = (n, v) => { const e = this.doc.createElement(n); e.textContent = String(v); p.appendChild(e); };
    add('step', pitch.step);
    if (pitch.alter) add('alter', pitch.alter);
    add('octave', pitch.octave);
    const acc = child(noteEl, 'accidental');
    if (acc) acc.remove();
    if (explicitAccidental) {
      const a = this.doc.createElement('accidental');
      a.textContent = { '-2': 'flat-flat', '-1': 'flat', 0: 'natural', 1: 'sharp', 2: 'double-sharp' }[pitch.alter || 0];
      this._insertInOrder(noteEl, a);
    }
    if (noteEl.getAttribute('print-object') === 'no') noteEl.removeAttribute('print-object');
    this._attrCache = null;
  }

  // the pitch a diatonic index has in this bar's key
  pitchAt(idx, fifths) {
    const octave = Math.floor(idx / 7), step = STEPS[((idx % 7) + 7) % 7];
    return { step, octave, alter: keyAlter(fifths, step) };
  }
  diatonic(p) { return p.octave * 7 + STEPS.indexOf(p.step); }

  moveDiatonic(ev, noteEl, delta) {
    const m = ev.chord.find((c) => c.el === noteEl) || ev.chord[0];
    const fifths = this.attrs(ev.pi, ev.mi).fifths;
    const np = this.pitchAt(this.diatonic(m.pitch) + delta, fifths);
    this.setPitch(m.el, np);
    return np;
  }

  setAlter(ev, noteEl, alter) {
    const m = ev.chord.find((c) => c.el === noteEl) || ev.chord[0];
    if (!m) return;
    this.setPitch(m.el, { ...m.pitch, alter }, true);
  }

  _insertInOrder(noteEl, el) {
    const order = ['grace', 'cue', 'chord', 'pitch', 'unpitched', 'rest', 'duration', 'tie', 'instrument', 'voice', 'type', 'dot', 'accidental', 'time-modification', 'stem', 'notehead', 'notehead-text', 'staff', 'beam', 'notations', 'lyric', 'play'];
    const rank = order.indexOf(el.localName);
    for (const c of noteEl.children) {
      if (order.indexOf(c.localName) > rank) { noteEl.insertBefore(el, c); return; }
    }
    noteEl.appendChild(el);
  }

  _setText(noteEl, name, value) {
    let e = child(noteEl, name);
    if (!e) { e = this.doc.createElement(name); this._insertInOrder(noteEl, e); }
    e.textContent = String(value);
  }

  _ensureDivisionsFor(pi, mi, ql) {
    // make sure ql quarter notes is a whole number of divisions in this part
    const div = this.attrs(pi, mi).divisions;
    const v = ql * div;
    if (Math.abs(v - Math.round(v)) < 1e-9) return;
    let k = 1;
    while (Math.abs(ql * div * k - Math.round(ql * div * k)) > 1e-9 && k < 64) k *= 2;
    this.rescalePart(pi, k);
  }

  rescalePart(pi, k) {
    const part = this.parts[pi].el;
    for (const d of part.querySelectorAll('divisions')) d.textContent = String(+d.textContent * k);
    for (const d of part.querySelectorAll('note > duration, backup > duration, forward > duration')) d.textContent = String(Math.round(+d.textContent * k));
    this._attrCache = null;
  }

  // durations (in divisions) -> list of {type, dots} that add up exactly (largest first)
  static split(dur, div) {
    const out = [];
    let left = dur;
    const vals = [];
    for (const t of TYPES) {
      const base = TYPE_QL[t] * div;
      vals.push({ type: t, dots: 1, v: base * 1.5 }, { type: t, dots: 0, v: base });
    }
    vals.sort((a, b) => b.v - a.v);
    for (const c of vals) {
      while (Number.isInteger(c.v) && c.v > 0 && left >= c.v - 1e-9) { out.push(c); left -= c.v; }
    }
    return left > 1e-9 ? null : out;
  }

  makeNote({ pitch = null, type = 'quarter', dots = 0, dur, voice = '1', staff = '1', chord = false, hidden = false }) {
    const n = this.doc.createElement('note');
    if (hidden) n.setAttribute('print-object', 'no');
    const add = (name, v) => { const e = this.doc.createElement(name); if (v !== undefined) e.textContent = String(v); n.appendChild(e); return e; };
    if (chord) add('chord');
    if (pitch) {
      const p = add('pitch');
      const a = (nm, v) => { const e = this.doc.createElement(nm); e.textContent = String(v); p.appendChild(e); };
      a('step', pitch.step); if (pitch.alter) a('alter', pitch.alter); a('octave', pitch.octave);
    } else add('rest');
    add('duration', dur);
    add('voice', voice);
    add('type', type);
    for (let i = 0; i < dots; i++) add('dot');
    if (this._multiStaff(n) || staff !== '1') add('staff', staff);
    return n;
  }
  _multiStaff() { return false; }

  _afterChord(ev) {
    // last element of the event (its last chord member)
    return ev.chord.length ? ev.chord[ev.chord.length - 1].el : ev.el;
  }

  _rests(dur, div, voice, staff) {
    const parts = Score.split(dur, div) || [{ type: 'quarter', dots: 0, v: dur }];
    return parts.map((p) => this.makeNote({ type: p.type, dots: p.dots, dur: p.v, voice, staff }));
  }

  // consume `need` divisions of the voice after `afterEl`: rests are eaten (or shortened); stops at a note
  _consume(ev, need) {
    const evs = this.events(ev.pi, ev.mi).filter((e) => e.voice === ev.voice && e.staff === ev.staff && !e.grace && e.onset >= ev.onset + 0 && e.el !== ev.el);
    const after = evs.filter((e) => e.onset > ev.onset || (e.onset === ev.onset && false)).sort((a, b) => a.onset - b.onset);
    for (const e of after) {
      if (need <= 0) break;
      if (!e.rest) break;
      if (e.dur <= need) { need -= e.dur; e.el.remove(); }
      else {
        const left = e.dur - need;
        const repl = this._rests(left, e.div, e.voice, e.staff);
        for (const r of repl) e.el.parentNode.insertBefore(r, e.el);
        e.el.remove();
        need = 0;
      }
    }
    this._attrCache = null;
    return need; // > 0 means the bar now overflows
  }

  setDuration(ev, type, dots) {
    const ql = TYPE_QL[type] * (dots ? 1.5 : 1) * (ev.tuplet ? ev.tuplet.normal / ev.tuplet.actual : 1);
    this._ensureDivisionsFor(ev.pi, ev.mi, ql);
    const fresh = this.events(ev.pi, ev.mi).find((e) => e.el === ev.el);
    const div = fresh.div;
    const nd = Math.round(ql * div);
    const delta = nd - fresh.dur;
    for (const c of (fresh.chord.length ? fresh.chord : [{ el: fresh.el }])) {
      this._setText(c.el, 'duration', nd);
      this._setText(c.el, 'type', type);
      for (const d of children(c.el, 'dot')) d.remove();
      for (let i = 0; i < dots; i++) this._insertInOrder(c.el, this.doc.createElement('dot'));
      for (const b of children(c.el, 'beam')) b.remove();
    }
    if (delta < 0) {
      const rests = this._rests(-delta, div, fresh.voice, fresh.staff);
      let ref = this._afterChord(fresh).nextSibling;
      for (const r of rests) fresh.el.parentNode.insertBefore(r, ref);
    } else if (delta > 0) {
      this._consume({ ...fresh, onset: fresh.onset }, delta);
    }
    this._attrCache = null;
  }

  toRest(ev) {
    for (const c of ev.chord.slice(1)) c.el.remove();
    const el = ev.el;
    const p = child(el, 'pitch');
    if (p) el.replaceChild(this.doc.createElement('rest'), p);
    for (const n of ['accidental', 'tie', 'stem', 'beam', 'notehead']) for (const c of children(el, n)) c.remove();
    const nots = child(el, 'notations');
    if (nots) nots.remove();
    this._attrCache = null;
  }

  removeChordTone(ev, noteEl) {
    if (ev.chord.length < 2) return this.toRest(ev);
    if (noteEl === ev.el) {
      // promote the next member to carry the event
      const next = ev.chord[1].el;
      const ch = child(next, 'chord');
      if (ch) ch.remove();
      ev.el.remove();
    } else noteEl.remove();
    this._attrCache = null;
  }

  // Swap an event with the next one in the same voice (drag left/right). Only for neighbours that sit next to each
  // other in the file, which is the normal case inside one voice.
  swapWithNext(ev) {
    const group = (e) => (e.chord.length ? e.chord.map((c) => c.el) : [e.el]);
    const evs = this.events(ev.pi, ev.mi).filter((e) => !e.grace && e.voice === ev.voice && e.staff === ev.staff).sort((a, b) => a.onset - b.onset);
    const i = evs.findIndex((e) => e.el === ev.el);
    const next = evs[i + 1];
    if (i < 0 || !next) return false;
    const A = group(evs[i]), B = group(next);
    if (A[A.length - 1].nextElementSibling !== B[0]) return false;
    const parent = A[0].parentNode;
    for (const el of B) parent.insertBefore(el, A[0]);
    for (const el of [...A, ...B]) for (const b of el.querySelectorAll(':scope > beam')) b.remove();
    this._attrCache = null;
    return true;
  }

  // true when the source file starts a new line of music at this bar
  newSystem(mi) {
    const m = this.parts[0]?.measures[mi];
    if (!m) return false;
    for (const c of m.children) {
      if (c.localName === 'note') return false;
      if (c.localName === 'print' && (c.getAttribute('new-system') === 'yes' || c.getAttribute('new-page') === 'yes')) return true;
    }
    return false;
  }

  deleteRest(ev) { ev.el.remove(); this._attrCache = null; }

  addChordTone(ev, pitch) {
    if (ev.rest) { this.setPitch(ev.el, pitch); return; }
    if (ev.chord.some((c) => midiOf(c.pitch) === midiOf(pitch))) return;
    const n = this.makeNote({ pitch, type: ev.type || 'quarter', dots: ev.dots, dur: ev.dur, voice: ev.voice, staff: ev.staff, chord: true });
    const after = this._afterChord(ev);
    after.parentNode.insertBefore(n, after.nextSibling);
    if (child(ev.el, 'staff') && !child(n, 'staff')) this._setText(n, 'staff', ev.staff);
    this._attrCache = null;
  }

  // Put a note at an existing rest (fill it), or after/before a note; following rests make room.
  placeNote(ev, pitch, type, dots, where = 'at') {
    const ql = TYPE_QL[type] * (dots ? 1.5 : 1);
    this._ensureDivisionsFor(ev.pi, ev.mi, ql);
    const fresh = this.events(ev.pi, ev.mi).find((e) => e.el === ev.el) || ev;
    const nd = Math.round(ql * fresh.div);
    const hasStaff = !!child(fresh.el, 'staff');
    if (where === 'at' && fresh.rest) {
      // the rest becomes the note; its time is reused
      const restDur = fresh.dur;
      this.setPitch(fresh.el, pitch);
      fresh.el.removeAttribute('print-object');
      const rm = child(fresh.el, 'rest'); if (rm) rm.remove();
      this._setText(fresh.el, 'duration', nd);
      this._setText(fresh.el, 'type', type);
      for (const d of children(fresh.el, 'dot')) d.remove();
      for (let i = 0; i < dots; i++) this._insertInOrder(fresh.el, this.doc.createElement('dot'));
      if (nd < restDur) {
        const rests = this._rests(restDur - nd, fresh.div, fresh.voice, fresh.staff);
        for (const r of rests) { if (hasStaff) this._setText(r, 'staff', fresh.staff); fresh.el.parentNode.insertBefore(r, fresh.el.nextSibling); }
      } else if (nd > restDur) {
        const e2 = this.events(ev.pi, ev.mi).find((e) => e.el === fresh.el);
        this._consume(e2, nd - restDur);
      }
      this._attrCache = null;
      return fresh.el;
    }
    const n = this.makeNote({ pitch, type, dots, dur: nd, voice: fresh.voice, staff: fresh.staff });
    if (hasStaff && !child(n, 'staff')) this._setText(n, 'staff', fresh.staff);
    if (where === 'before') fresh.el.parentNode.insertBefore(n, fresh.el);
    else { const a = this._afterChord(fresh); a.parentNode.insertBefore(n, a.nextSibling); }
    this._attrCache = null;
    const e2 = this.events(ev.pi, ev.mi).find((e) => e.el === n);
    this._consume(e2, nd);
    this._attrCache = null;
    return n;
  }

  // insert a note into an empty voice/staff of a bar
  addToEmpty(pi, mi, staff, pitch, type, dots) {
    const ql = TYPE_QL[type] * (dots ? 1.5 : 1);
    this._ensureDivisionsFor(pi, mi, ql);
    const div = this.attrs(pi, mi).divisions;
    const m = this.parts[pi].measures[mi];
    const n = this.makeNote({ pitch, type, dots, dur: Math.round(ql * div), voice: staff === '1' ? '1' : '5', staff });
    if (this.attrs(pi, mi).staves > 1 && !child(n, 'staff')) this._setText(n, 'staff', staff);
    // place at the end, after backing up to the bar start
    const end = this.events(pi, mi).reduce((a, e) => Math.max(a, e.grace ? 0 : e.onset + e.dur), 0);
    let pos = 0; for (const e of this.events(pi, mi)) if (!e.grace) pos = Math.max(pos, e.onset + e.dur);
    if (end > 0) { const b = this.doc.createElement('backup'); const d = this.doc.createElement('duration'); d.textContent = String(end); b.appendChild(d); m.appendChild(b); }
    m.appendChild(n);
    const rest = this.measureLength(pi, mi) - Math.round(ql * div);
    if (rest > 0) for (const r of this._rests(rest, div, n.querySelector('voice').textContent, staff)) { if (this.attrs(pi, mi).staves > 1) this._setText(r, 'staff', staff); m.appendChild(r); }
    this._attrCache = null;
    return n;
  }

  // ---------- key / time for the whole piece ----------
  // Set the key from bar `from` on. Notes that followed the old key follow the new one (so a misread key is fixed
  // with one change); notes with a printed accidental keep their pitch.
  setKey(fifths, from = 0) {
    for (let pi = 0; pi < this.parts.length; pi++) {
      const old = this.attrs(pi, from).fifths;
      const ms = this.parts[pi].measures;
      for (let mi = from; mi < ms.length; mi++) {
        const a = this.attrs(pi, mi);
        if (mi > from && a.changed?.key) break;
        for (const e of this.events(pi, mi)) {
          for (const c of e.chord) {
            const hasAcc = !!c.el.querySelector(':scope > accidental');
            if (!hasAcc && (c.pitch.alter || 0) === keyAlter(old, c.pitch.step)) this.setPitch(c.el, { ...c.pitch, alter: keyAlter(fifths, c.pitch.step) });
          }
        }
      }
      const at = this._attrsEl(ms[from]);
      let k = at.querySelector(':scope > key');
      if (!k) { k = this.doc.createElement('key'); const f = this.doc.createElement('fifths'); k.appendChild(f); const d = at.querySelector(':scope > divisions'); at.insertBefore(k, d ? d.nextSibling : at.firstChild); }
      let f = k.querySelector(':scope > fifths');
      if (!f) { f = this.doc.createElement('fifths'); k.insertBefore(f, k.firstChild); }
      f.textContent = String(fifths);
      this._attrCache = null;
    }
  }

  setTime(beats, beatType, from = 0) {
    for (let pi = 0; pi < this.parts.length; pi++) {
      const at = this._attrsEl(this.parts[pi].measures[from]);
      let t = at.querySelector(':scope > time');
      if (!t) {
        t = this.doc.createElement('time');
        const after = at.querySelector(':scope > key') || at.querySelector(':scope > divisions');
        at.insertBefore(t, after ? after.nextSibling : at.firstChild);
      }
      t.textContent = '';
      for (const [n, v] of [['beats', beats], ['beat-type', beatType]]) { const e = this.doc.createElement(n); e.textContent = String(v); t.appendChild(e); }
    }
    this._attrCache = null;
  }

  _attrsEl(m) {
    let at = null;
    for (const c of m.children) { if (c.localName === 'note') break; if (c.localName === 'attributes') { at = c; break; } }
    if (!at) { at = this.doc.createElement('attributes'); m.insertBefore(at, m.firstChild); }
    return at;
  }

  // ---------- rescan splice ----------
  spliceMeasures(targets, other) {
    // replace bars `targets` (consecutive global indices) with all bars of `other` (a Score), part by part.
    // The new bars get our divisions; a clef/key change the new reading saw inside the row is kept, and the bar
    // after the splice re-states whatever was in force there before, so nothing leaks past the replaced rows.
    const nNew = other.nMeasures;
    const lastOld = targets[targets.length - 1];
    const after = this.parts.map((p, pi) => (lastOld + 1 < p.measures.length ? this.attrs(pi, lastOld + 1) : null));
    for (let pi = 0; pi < this.parts.length; pi++) {
      const op = other.parts[pi];
      if (!op) continue;
      const part = this.parts[pi];
      const first = targets[0];
      const oldDiv = this.attrs(pi, first).divisions;
      // divisions: make ours a multiple of theirs (every bar of theirs)
      let L = oldDiv;
      for (let k = 0; k < op.measures.length; k++) L = lcm(L, other.attrs(pi, k).divisions);
      if (L !== oldDiv) this.rescalePart(pi, L / oldDiv);
      const ourDiv = this.attrs(pi, first).divisions;
      const olds = targets.map((t) => part.measures[t]).filter(Boolean);
      const nextBar = part.measures[lastOld + 1] || null;
      for (let k = 0; k < Math.max(olds.length, nNew); k++) {
        const nm = op.measures[k];
        let om = olds[k];
        if (!om) {
          // more new bars than old: add a bar after the last one
          om = this.doc.createElement('measure');
          const prev = olds[olds.length - 1] || part.measures[first - 1];
          prev.parentNode.insertBefore(om, prev.nextSibling);
          olds.push(om);
        }
        if (!nm) { om.remove(); continue; }
        // keep only what opens the old bar (its own attributes, print, left barline) and its right barline
        const lead = [], tail = [];
        for (const c of [...om.children]) {
          if (c.localName === 'note' || c.localName === 'backup' || c.localName === 'forward') break;
          if (['attributes', 'print'].includes(c.localName) || (c.localName === 'barline' && c.getAttribute('location') === 'left')) lead.push(c);
        }
        for (const c of [...om.children]) if (c.localName === 'barline' && (c.getAttribute('location') || 'right') === 'right') tail.push(c);
        for (const c of [...om.children]) if (!lead.includes(c) && !tail.includes(c)) c.remove();
        for (const c of tail) c.remove();
        const f = ourDiv / other.attrs(pi, k).divisions;
        let opening = true;
        for (const c of nm.children) {
          const n = c.localName;
          if (n === 'print' || n === 'barline' || n === 'sound') continue;
          if (n === 'attributes') {
            // a clef or key change the new reading saw after its first bar or mid-bar (never its divisions,
            // staves or time: the score's own stay in force)
            if (k === 0 && opening) continue;
            const a = this.doc.importNode(c, true);
            for (const d of [...a.children]) if (!['clef', 'key'].includes(d.localName)) d.remove();
            if (a.children.length) om.appendChild(a);
            continue;
          }
          if (n === 'note') opening = false;
          const cl = this.doc.importNode(c, true);
          for (const d of cl.querySelectorAll(':scope > duration')) d.textContent = String(Math.round(+d.textContent * f));
          om.appendChild(cl);
        }
        for (const c of tail) om.appendChild(c);
      }
      // restore the state that was in force after the replaced bars
      this._attrCache = null;
      const was = after[pi];
      if (was && nextBar) {
        this.refresh();
        const ni = this.parts[pi].measures.indexOf(nextBar);
        const now = this.attrs(pi, ni);
        const at = () => this._attrsEl(nextBar);
        if (now.fifths !== was.fifths && !at().querySelector(':scope > key')) {
          const k = this.doc.createElement('key'); const fi = this.doc.createElement('fifths'); fi.textContent = String(was.fifths); k.appendChild(fi);
          const d = at().querySelector(':scope > divisions'); at().insertBefore(k, d ? d.nextSibling : at().firstChild);
        }
        for (const [num, c] of Object.entries(was.clefs)) {
          const cur = now.clefs[num];
          if (cur && cur.sign === c.sign && cur.line === c.line && (cur.octaveChange || 0) === (c.octaveChange || 0)) continue;
          if (at().querySelector(`:scope > clef[number="${num}"]`)) continue;
          const el = this.doc.createElement('clef'); el.setAttribute('number', num);
          for (const [t, v] of [['sign', c.sign], ['line', c.line]]) { const e = this.doc.createElement(t); e.textContent = String(v); el.appendChild(e); }
          if (c.octaveChange) { const e = this.doc.createElement('clef-octave-change'); e.textContent = String(c.octaveChange); el.appendChild(e); }
          at().appendChild(el);
        }
        this._attrCache = null;
      }
    }
    this.renumber();
    this.refresh();
  }

  renumber() {
    for (const p of this.parts) {
      let n = 1;
      const ms = children(p.el, 'measure');
      const pickup = ms[0]?.getAttribute('implicit') === 'yes';
      ms.forEach((m, i) => m.setAttribute('number', String(pickup ? i : i + 1)));
    }
  }

  // ---------- playback / MIDI ----------
  tempo() {
    const s = this.root.querySelector('sound[tempo]');
    return s ? +s.getAttribute('tempo') : 90;
  }

  // bar lines of one bar: { left: {style, repeat}, right: {style, repeat, times}, ending: {numbers, start, stop} }
  barlines(pi, mi) {
    const m = this.parts[pi]?.measures[mi];
    const out = { left: null, right: null, ending: null };
    if (!m) return out;
    for (const b of children(m, 'barline')) {
      const loc = b.getAttribute('location') || 'right';
      const rep = child(b, 'repeat');
      const info = { style: txt(b, 'bar-style'), repeat: rep ? rep.getAttribute('direction') : null, times: rep ? +(rep.getAttribute('times') || 2) : 0 };
      if (loc === 'left' || loc === 'right') out[loc] = info;
      const end = child(b, 'ending');
      if (end) {
        const nums = (end.getAttribute('number') || '1').split(/[ ,]+/).map(Number).filter((x) => x > 0);
        const type = end.getAttribute('type');
        out.ending = out.ending || { numbers: nums, start: false, stop: false };
        if (type === 'start') out.ending.start = true;
        if (type === 'stop' || type === 'discontinue') { out.ending.stop = true; out.ending.open = type === 'discontinue'; }
      }
    }
    return out;
  }

  // the first/second-time ending bar mi lies in: {numbers, first, last, open} or null
  endingAt(mi) {
    let cur = null;
    for (let j = 0; j <= mi && j < this.nMeasures; j++) {
      const e = this.barlines(0, j).ending;
      if (e?.start) cur = { numbers: e.numbers, from: j };
      if (j === mi) return cur ? { numbers: cur.numbers, first: cur.from === mi, last: !!e?.stop, open: !!e?.open } : null;
      if (e?.stop) cur = null;
    }
    return null;
  }

  // The order bars are played in, with repeats and first/second endings unrolled (from the first part's bar lines).
  playOrder() {
    const n = this.nMeasures;
    const endingOf = [];
    let active = null;
    for (let mi = 0; mi < n; mi++) {
      const b = this.barlines(0, mi);
      if (b.ending?.start) active = b.ending.numbers;
      endingOf.push(active);
      if (b.ending?.stop) active = null;
    }
    const order = [];
    const done = {};
    let i = 0, start = 0, pass = 1;
    while (i < n && order.length < 8 * n) {
      const b = this.barlines(0, i);
      if (b.left?.repeat === 'forward' && pass === 1) start = i;
      if (endingOf[i] && !endingOf[i].includes(pass)) { i++; continue; }
      order.push(i);
      if (b.right?.repeat === 'backward') {
        const times = b.right.times || 2;
        const k = done[i] || 1;
        if (k < times) { done[i] = k + 1; pass = k + 1; i = start; continue; }
        pass = 1;
        start = i + 1;
      } else if (endingOf[i] && b.ending?.stop && pass > 1 && !endingOf[i + 1]) {
        pass = 1;
        start = i + 1;
      }
      i++;
    }
    return order;
  }

  // [{time (quarters), dur (quarters), midi, part, measure, step}], the start time of every played bar (step), and
  // `order`: the bar index played at each step (repeats unrolled; without repeats step === bar)
  playEvents() {
    const lens = [];
    for (let mi = 0; mi < this.nMeasures; mi++) {
      let len = 0;
      for (let pi = 0; pi < this.parts.length; pi++) {
        const a = this.attrs(pi, mi);
        if (!a) continue;
        const nominal = a.beats * 4 / a.beatType;
        const actual = Math.max(0, ...this.events(pi, mi).filter((e) => !e.grace).map((e) => (e.onset + e.dur) / e.div));
        const implicit = this.parts[pi].measures[mi]?.getAttribute('implicit') === 'yes';
        len = Math.max(len, implicit && actual > 0 ? actual : Math.max(nominal, actual));
      }
      lens.push(len);
    }
    const order = this.playOrder();
    const starts = [];
    let t = 0;
    for (const mi of order) { starts.push(t); t += lens[mi]; }
    starts.push(t);
    const out = [];
    for (let pi = 0; pi < this.parts.length; pi++) {
      const open = {};
      order.forEach((mi, step) => {
        for (const e of this.events(pi, mi)) {
          if (e.grace || e.rest) continue;
          for (const c of e.chord) {
            const midi = midiOf(c.pitch);
            const time = starts[step] + e.onset / e.div, dur = e.dur / e.div;
            const tie = [...c.el.querySelectorAll(':scope > tie')].map((x) => x.getAttribute('type'));
            if (tie.includes('stop') && open[midi]) { open[midi].dur = time + dur - open[midi].time; if (!tie.includes('start')) delete open[midi]; continue; }
            const ev = { time, dur, midi, part: pi, staff: e.staff, voice: e.voice, measure: mi, step, el: c.el };
            out.push(ev);
            if (tie.includes('start')) open[midi] = ev;
          }
        }
      });
    }
    out.sort((a, b) => a.time - b.time);
    // time signature of each played step (first part that has one), for the metronome and count-in
    const meters = order.map((mi) => { const a = this.attrs(0, mi) || {}; return { beats: a.beats || 4, beatType: a.beatType || 4 }; });
    return { events: out, starts, order, meters };
  }
}

// Minimal Standard MIDI File writer (format 1, one track per part). programs: optional GM program per part.
export function toMidi(score, bpm, programs = []) {
  const { events } = score.playEvents();
  const TPQ = 480;
  const vlq = (n) => { const b = [n & 0x7f]; while ((n >>= 7)) b.unshift((n & 0x7f) | 0x80); return b; };
  const u32 = (n) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  const u16 = (n) => [(n >>> 8) & 255, n & 255];
  const track = (evs) => {
    let bytes = [], last = 0;
    evs.sort((a, b) => a.t - b.t || a.order - b.order);
    for (const e of evs) { bytes.push(...vlq(e.t - last), ...e.data); last = e.t; }
    bytes.push(0, 0xff, 0x2f, 0);
    return [0x4d, 0x54, 0x72, 0x6b, ...u32(bytes.length), ...bytes];
  };
  const tracks = [];
  const mpq = Math.round(60000000 / (bpm || score.tempo()));
  tracks.push(track([{ t: 0, order: 0, data: [0xff, 0x51, 0x03, (mpq >> 16) & 255, (mpq >> 8) & 255, mpq & 255] }]));
  score.parts.forEach((p, pi) => {
    const ch = pi % 16 === 9 ? 10 : pi % 16;
    const evs = [];
    const name = [...new TextEncoder().encode(p.name || `Part ${pi + 1}`)];
    evs.push({ t: 0, order: 0, data: [0xff, 0x03, ...vlq(name.length), ...name] });
    if (programs[pi] && ch !== 9) evs.push({ t: 0, order: 0, data: [0xc0 | ch, programs[pi] & 127] });
    for (const e of events.filter((x) => x.part === pi)) {
      const t0 = Math.round(e.time * TPQ), t1 = Math.round((e.time + e.dur) * TPQ);
      evs.push({ t: t0, order: 2, data: [0x90 | ch, e.midi, 80] });
      evs.push({ t: Math.max(t0 + 1, t1), order: 1, data: [0x80 | ch, e.midi, 0] });
    }
    tracks.push(track(evs));
  });
  const head = [0x4d, 0x54, 0x68, 0x64, ...u32(6), ...u16(1), ...u16(tracks.length), ...u16(TPQ)];
  return new Uint8Array([...head, ...tracks.flat()]);
}
