// Bar and rhythm edits for the Score model: split / merge / insert / delete bars across all parts, ties and tuplets.
// Like score.js, every edit patches the MusicXML DOM: anything it does not touch (directions, slurs, lyrics,
// barlines, other bars) is kept, and every voice of a bar it rebuilds still adds up to the bar.
import { Score, TYPES, midiOf } from './score.js';

const TYPE_QL = { breve: 8, whole: 4, half: 2, quarter: 1, eighth: 0.5, '16th': 0.25, '32nd': 0.125, '64th': 0.0625 };
const ATTR_ORDER = ['footnote', 'level', 'divisions', 'key', 'time', 'staves', 'part-symbol', 'instruments', 'clef', 'staff-details', 'transpose', 'for-part', 'directive', 'measure-style'];
const gcd = (a, b) => (b ? gcd(b, a % b) : Math.abs(a));

function child(el, name) { for (const c of el.children) if (c.localName === name) return c; return null; }
function children(el, name) { return [...el.children].filter((c) => c.localName === name); }
function txt(el, name, d = null) { const c = child(el, name); return c ? c.textContent.trim() : d; }
// make q quarter notes a whole number of divisions in part pi (q may be a triplet position like 1/3)
function fracOf(q) { for (let d = 1; d <= 960; d++) if (Math.abs(q * d - Math.round(q * d)) < 1e-6) return [Math.round(q * d), d]; return [Math.round(q * 960), 960]; }
Score.prototype._ensureQl = function (pi, mi, q) {
  const [num, den] = fracOf(q);
  const div = this.attrs(pi, mi).divisions;
  const k = den / gcd(num * div, den);
  if (k > 1) this.rescalePart(pi, k);
};
const vkey = (it) => `${it.staff}/${it.voice}`;

const P = Score.prototype;

// ---------------------------------------------------------------- reading and rewriting one bar
// A bar as { lead, items, tail }: lead = what opens it (print, its own attributes, left barline), tail = the right
// barline, items = everything with a time position: note groups (a note and its chord members) and other elements
// (directions, harmony, mid-bar attributes) with their onset in divisions.
P._read = function (pi, mi) {
  const m = this.parts[pi].measures[mi];
  const div = this.attrs(pi, mi).divisions;
  const lead = [], tail = [], items = [];
  let cur = 0, started = false, last = null, ord = 0;
  for (const c of [...m.children]) {
    const n = c.localName;
    if (!started && (n === 'print' || n === 'attributes' || (n === 'barline' && c.getAttribute('location') === 'left'))) { lead.push(c); continue; }
    if (n === 'barline' && (c.getAttribute('location') || 'right') === 'right') { tail.push(c); continue; }
    started = true;
    if (n === 'backup') { cur -= +txt(c, 'duration', 0); continue; }
    if (n === 'forward') { cur += +txt(c, 'duration', 0); continue; }
    if (n === 'note') {
      const grace = !!child(c, 'grace');
      if (child(c, 'chord') && last) { last.els.push(c); continue; }
      const tm = child(c, 'time-modification');
      const it = {
        kind: 'note', els: [c], onset: cur, dur: grace ? 0 : +txt(c, 'duration', 0), ord: ord++,
        voice: txt(c, 'voice', '1'), staff: txt(c, 'staff', '1'), grace, rest: !!child(c, 'rest') || !child(c, 'pitch'),
        tuplet: tm ? { actual: +txt(tm, 'actual-notes'), normal: +txt(tm, 'normal-notes') } : null,
      };
      items.push(it);
      last = it;
      cur += it.dur;
      continue;
    }
    items.push({ kind: 'other', els: [c], onset: cur, dur: 0, ord: ord++ });
  }
  return { m, div, lead, items, tail };
};

P._mkDur = function (name, d, voice, staff) {
  const e = this.doc.createElement(name);
  const du = this.doc.createElement('duration'); du.textContent = String(d); e.appendChild(du);
  if (name === 'forward' && voice) {
    const v = this.doc.createElement('voice'); v.textContent = voice; e.appendChild(v);
    if (staff) { const s = this.doc.createElement('staff'); s.textContent = staff; e.appendChild(s); }
  }
  return e;
};

// write items back as one stream per voice, joined by <backup>; gaps become <forward>
P._write = function (m, lead, items, tail, order = null) {
  while (m.firstChild) m.removeChild(m.firstChild);
  for (const c of lead) m.appendChild(c);
  const voices = [];
  for (const k of order || []) if (!voices.includes(k)) voices.push(k);
  for (const it of items) if (it.kind === 'note' && !voices.includes(vkey(it))) voices.push(vkey(it));
  if (!voices.length) voices.push(null);
  const others = items.filter((i) => i.kind !== 'note');
  const multi = items.some((i) => i.kind === 'note' && child(i.els[0], 'staff'));
  let cur = 0;
  voices.forEach((v, vi) => {
    let its = items.filter((i) => i.kind === 'note' && vkey(i) === v);
    if (!its.length && vi > 0) return;
    if (vi === 0) its = its.concat(others);
    its.sort((a, b) => a.onset - b.onset || a.ord - b.ord);
    if (vi > 0 && cur > 0) { m.appendChild(this._mkDur('backup', cur)); cur = 0; }
    const [staff, voice] = v ? v.split('/') : [null, null];
    for (const it of its) {
      if (it.onset > cur) m.appendChild(this._mkDur('forward', it.onset - cur, voice, multi ? staff : null));
      else if (it.onset < cur) m.appendChild(this._mkDur('backup', cur - it.onset));
      cur = it.onset;
      for (const e of it.els) m.appendChild(e);
      cur += it.dur;
    }
  });
  for (const c of tail) m.appendChild(c);
  this._attrCache = null;
};

// rests filling [from, to) of one voice, as items
P._restItems = function (from, to, div, voice, staff, staffTag, ord) {
  const out = [];
  let t = from;
  for (const r of this._rests(to - from, div, voice, staff)) {
    if (staffTag) this._setText(r, 'staff', staff);
    const d = +txt(r, 'duration', 0);
    out.push({ kind: 'note', els: [r], onset: t, dur: d, ord: ord + out.length, voice, staff, rest: true, grace: false });
    t += d;
  }
  return out;
};

// fill every voice up to `to`; staves of the part that have no notes at all get one voice of rests
P._pad = function (items, to, div, staves, ord = 1e7) {
  const ends = {};
  for (const it of items) if (it.kind === 'note' && !it.grace) ends[vkey(it)] = Math.max(ends[vkey(it)] || 0, it.onset + it.dur);
  for (const it of items) if (it.kind === 'note' && !(vkey(it) in ends)) ends[vkey(it)] = 0;
  const out = [...items];
  const multi = staves > 1;
  for (const [k, e] of Object.entries(ends)) {
    if (e >= to) continue;
    const [staff, voice] = k.split('/');
    out.push(...this._restItems(e, to, div, voice, staff, multi, ord));
    ord += 100;
  }
  for (let s = 1; s <= staves; s++) {
    if (Object.keys(ends).some((k) => k.split('/')[0] === String(s))) continue;
    if (to > 0) out.push(...this._restItems(0, to, div, s === 1 ? '1' : String(4 * (s - 1) + 1), String(s), multi, ord));
    ord += 100;
  }
  return out;
};

// ---------------------------------------------------------------- ties
P._tie = function (el, type, on) {
  for (const t of children(el, 'tie')) if (t.getAttribute('type') === type) t.remove();
  let nots = child(el, 'notations');
  if (nots) { for (const t of children(nots, 'tied')) if (t.getAttribute('type') === type) t.remove(); if (!nots.children.length) { nots.remove(); nots = null; } }
  if (!on || !child(el, 'pitch')) return;
  const t = this.doc.createElement('tie'); t.setAttribute('type', type);
  const start = type === 'stop' ? children(el, 'tie').find((x) => x.getAttribute('type') === 'start') : null;
  if (start) el.insertBefore(t, start); else this._insertInOrder(el, t);
  if (!nots) { nots = this.doc.createElement('notations'); this._insertInOrder(el, nots); }
  const td = this.doc.createElement('tied'); td.setAttribute('type', type);
  nots.insertBefore(td, nots.firstChild);
};
const hasTie = (el, type) => children(el, 'tie').some((t) => t.getAttribute('type') === type);

// The event that follows `ev` in its voice: later in the bar, or at the start of the next bar.
P.nextEvent = function (ev) {
  const end = ev.onset + ev.dur;
  const here = this.events(ev.pi, ev.mi).filter((e) => !e.grace && e.staff === ev.staff && e.voice === ev.voice && e.el !== ev.el && e.onset >= end).sort((a, b) => a.onset - b.onset);
  if (here.length) return here[0];
  if (ev.mi + 1 >= this.parts[ev.pi].measures.length) return null;
  const nx = this.events(ev.pi, ev.mi + 1).filter((e) => !e.grace && e.staff === ev.staff && e.onset === 0);
  return nx.find((e) => e.voice === ev.voice) || nx.find((e) => !e.rest) || null;
};

P.isTied = function (ev) { return ev.chord.some((c) => hasTie(c.el, 'start')); };

// Tie a note to the next one (every chord tone that the next note also has). Again removes the tie.
P.toggleTie = function (ev) {
  if (ev.rest) throw new Error('Select a note to tie it');
  const nx = this.nextEvent(ev);
  if (this.isTied(ev)) {
    for (const c of ev.chord) {
      if (!hasTie(c.el, 'start')) continue;
      this._tie(c.el, 'start', false);
      const d = nx?.chord.find((x) => midiOf(x.pitch) === midiOf(c.pitch));
      if (d) this._tie(d.el, 'stop', false);
    }
    this._attrCache = null;
    return false;
  }
  if (!nx || nx.rest) throw new Error('A tie needs a next note of the same pitch');
  let n = 0;
  for (const c of ev.chord) {
    const d = nx.chord.find((x) => midiOf(x.pitch) === midiOf(c.pitch));
    if (d) { this._tie(c.el, 'start', true); this._tie(d.el, 'stop', true); n++; }
  }
  if (!n) throw new Error('The next note has a different pitch, so it cannot be tied');
  this._attrCache = null;
  return true;
};

// ---------------------------------------------------------------- cutting a note in two (tied)
P._retime = function (el, piece, first, last, keepStop, keepStart) {
  const c = el.cloneNode(true);
  this._setText(c, 'duration', piece.v);
  this._setText(c, 'type', piece.type);
  for (const d of children(c, 'dot')) d.remove();
  for (let i = 0; i < piece.dots; i++) this._insertInOrder(c, this.doc.createElement('dot'));
  for (const b of children(c, 'beam')) b.remove();
  if (c.getAttribute('print-object') !== 'no' && child(c, 'rest')) child(c, 'rest').removeAttribute('measure');
  if (!first) {
    for (const x of children(c, 'lyric')) x.remove();
    const nots = child(c, 'notations');
    if (nots) for (const x of [...nots.children]) if (x.localName !== 'tied') x.remove();
  }
  if (child(c, 'pitch')) {
    this._tie(c, 'stop', first ? keepStop : true);
    this._tie(c, 'start', last ? keepStart : true);
  }
  return c;
};

// split a note group at `at` (divisions from the bar start): tied pieces, each a plain written value
P._cut = function (it, at, div) {
  const a = Score.split(at - it.onset, div), b = Score.split(it.onset + it.dur - at, div);
  if (!a || !b) throw new Error('That beat cannot be written with plain note values here');
  const pieces = [...a, ...b];
  const keepStop = hasTie(it.els[0], 'stop'), keepStart = hasTie(it.els[0], 'start');
  const out = [];
  let t = it.onset;
  pieces.forEach((p, i) => {
    const els = it.els.map((el) => this._retime(el, p, i === 0, i === pieces.length - 1, keepStop, keepStart));
    out.push({ ...it, els, onset: t, dur: p.v, ord: it.ord + i / 100 });
    t += p.v;
  });
  for (const el of it.els) el.remove();
  return out;
};

// ---------------------------------------------------------------- bars
// Put a barline `q` quarter notes into bar `mi`, in every part. A note across that point is cut into two tied
// notes. The second half becomes a new bar; voices that come up short are filled with rests.
P.splitBar = function (mi, q) {
  if (!(q > 0)) throw new Error('Pick a note after the first beat to split the bar there');
  for (let pi = 0; pi < this.parts.length; pi++) if (this.parts[pi].measures[mi]) this._ensureQl(pi, mi, q);
  for (let pi = 0; pi < this.parts.length; pi++) {
    const part = this.parts[pi];
    if (!part.measures[mi]) continue;
    const { m, div, lead, items, tail } = this._read(pi, mi);
    const at = Math.round(q * div);
    const len = this.measureLength(pi, mi);
    const staves = this.attrs(pi, mi).staves;
    const order = [...new Set(items.filter((i) => i.kind === 'note').map(vkey))];
    const A = [], B = [];
    for (const it of items) {
      if (it.kind === 'note' && !it.grace && it.onset < at && it.onset + it.dur > at) {
        if (it.tuplet) throw new Error('That point falls inside a triplet. Split before or after it.');
        for (const p of this._cut(it, at, div)) (p.onset < at ? A : B).push(p);
      } else (it.onset < at ? A : B).push(it);
    }
    for (const it of B) it.onset -= at;
    for (const it of B) if (it.kind === 'note') for (const el of it.els) child(el, 'rest')?.removeAttribute('measure');
    for (const it of A) if (it.kind === 'note') for (const el of it.els) child(el, 'rest')?.removeAttribute('measure');
    const bEnd = Math.max(0, ...B.filter((i) => i.kind === 'note').map((i) => i.onset + i.dur));
    this._write(m, lead, this._pad(A, at, div, staves), [], order);
    const nm = this.doc.createElement('measure');
    m.parentNode.insertBefore(nm, m.nextSibling);
    this._write(nm, [], this._pad(B, Math.max(len, bEnd), div, staves), tail, order);
  }
  this.renumber();
  this.refresh();
};

// Remove the barline between bar `mi` and the next one, in every part. The second bar's music follows the first
// bar's (the first bar is filled with rests up to its longest part first, so parts stay lined up).
P.mergeBars = function (mi) {
  if (mi + 1 >= this.nMeasures) throw new Error('There is no next bar to join');
  let q = 0;
  for (let pi = 0; pi < this.parts.length; pi++) {
    if (!this.parts[pi].measures[mi]) continue;
    const r = this._read(pi, mi);
    const end = Math.max(0, ...r.items.filter((i) => i.kind === 'note').map((i) => i.onset + i.dur));
    q = Math.max(q, end / r.div);
  }
  if (q <= 0) q = this.measureLength(0, mi) / this.attrs(0, mi).divisions;
  // the bar after the two keeps the divisions, time, key and clefs it had
  const want = this.parts.map((p, pi) => (p.measures[mi + 2] ? this.attrs(pi, mi + 2) : null));
  for (let pi = 0; pi < this.parts.length; pi++) {
    const part = this.parts[pi];
    if (!part.measures[mi] || !part.measures[mi + 1]) continue;
    this._ensureQl(pi, mi, q);
    let dA = this.attrs(pi, mi).divisions, dB = this.attrs(pi, mi + 1).divisions;
    if (dA !== dB) {
      const k = dB / gcd(dA, dB);
      if (k > 1) this.rescalePart(pi, k);
      dA = this.attrs(pi, mi).divisions; dB = this.attrs(pi, mi + 1).divisions;
    }
    const f = dA / dB;
    const A = this._read(pi, mi), B = this._read(pi, mi + 1);
    const at = Math.round(q * dA);
    const staves = this.attrs(pi, mi).staves;
    const order = [...new Set([...A.items, ...B.items].filter((i) => i.kind === 'note').map(vkey))];
    const items = this._pad(A.items, at, dA, staves);
    // what opened bar B: a clef or key change stays where B began (a time change is restated after the join)
    for (const el of B.lead) {
      if (el.localName !== 'attributes') continue;
      for (const c of [...el.children]) if (!['clef', 'key'].includes(c.localName)) c.remove();
      if (el.children.length) items.push({ kind: 'other', els: [el], onset: at, dur: 0, ord: 5e5 });
    }
    for (const it of B.items) {
      if (f !== 1) { it.onset = Math.round(it.onset * f); it.dur = Math.round(it.dur * f); for (const el of it.els) if (child(el, 'duration')) this._setText(el, 'duration', Math.round(+txt(el, 'duration') * f)); }
      it.onset += at;
      it.ord += 1e6;
      items.push(it);
    }
    for (const it of items) if (it.kind === 'note') for (const el of it.els) child(el, 'rest')?.removeAttribute('measure');
    const end = Math.max(0, ...items.filter((i) => i.kind === 'note').map((i) => i.onset + i.dur));
    const filled = this._pad(items, end, dA, 0);
    this._write(A.m, A.lead, filled, B.tail.length ? B.tail : A.tail, order);
    B.m.remove();
  }
  this.refresh();
  this.parts.forEach((p, pi) => { if (want[pi] && p.measures[mi + 1]) this._restate(pi, mi + 1, want[pi]); });
  this.renumber();
  this.refresh();
  return q;
};

P._putAttr = function (at, el) {
  const rank = ATTR_ORDER.indexOf(el.localName);
  for (const c of at.children) if (ATTR_ORDER.indexOf(c.localName) > rank) { at.insertBefore(el, c); return; }
  at.appendChild(el);
};

// make bar `mi` of part `pi` state `want` (divisions, key, time, staves, clefs) where it would differ
P._restate = function (pi, mi, want, force = false) {
  const now = this.attrs(pi, mi);
  const m = this.parts[pi].measures[mi];
  const doc = this.doc;
  const mk = (name, kids) => { const e = doc.createElement(name); for (const [k, v] of kids) { const c = doc.createElement(k); c.textContent = String(v); e.appendChild(c); } return e; };
  const own = (name) => { for (const c of m.children) { if (c.localName === 'note') return null; if (c.localName === 'attributes') { const x = child(c, name); if (x) return x; } } return null; };
  if ((force || now.divisions !== want.divisions) && !own('divisions')) { const d = doc.createElement('divisions'); d.textContent = String(want.divisions); this._putAttr(this._attrsEl(m), d); }
  if ((force || now.fifths !== want.fifths) && !own('key')) this._putAttr(this._attrsEl(m), mk('key', [['fifths', want.fifths]]));
  if ((force || now.beats !== want.beats || now.beatType !== want.beatType) && !own('time')) this._putAttr(this._attrsEl(m), mk('time', [['beats', want.beats], ['beat-type', want.beatType]]));
  if ((force ? want.staves > 1 : now.staves !== want.staves) && !own('staves')) { const s = doc.createElement('staves'); s.textContent = String(want.staves); this._putAttr(this._attrsEl(m), s); }
  for (const [num, c] of Object.entries(want.clefs)) {
    const cur = now.clefs[num];
    const same = cur && cur.sign === c.sign && cur.line === c.line && (cur.octaveChange || 0) === (c.octaveChange || 0);
    if (same && !force) continue;
    const at = this._attrsEl(m);
    if ([...children(at, 'clef')].some((x) => (x.getAttribute('number') || '1') === num)) continue;
    const el = mk('clef', [['sign', c.sign], ['line', c.line]]);
    if (want.staves > 1 || num !== '1') el.setAttribute('number', num);
    if (c.octaveChange) { const e = doc.createElement('clef-octave-change'); e.textContent = String(c.octaveChange); el.appendChild(e); }
    this._putAttr(at, el);
  }
  this._attrCache = null;
};

// An empty bar (whole-bar rests on every staff) before or after bar `mi`, in every part.
P.insertBar = function (mi, where = 'after') {
  const idx = where === 'before' ? mi : mi + 1;
  for (const part of this.parts) {
    const ref = part.measures[mi];
    if (!ref) continue;
    const nm = this.doc.createElement('measure');
    if (where === 'before') {
      ref.parentNode.insertBefore(nm, ref);
      if (idx === 0) {
        // the new first bar takes over what opened the piece (clefs, key, time, layout)
        for (const c of [...ref.children]) { if (['note', 'backup', 'forward'].includes(c.localName)) break; if (['attributes', 'print'].includes(c.localName)) nm.appendChild(c); }
      }
    } else ref.parentNode.insertBefore(nm, ref.nextSibling);
  }
  this.refresh();
  this.parts.forEach((part, pi) => {
    const nm = part.measures[idx];
    if (!nm) return;
    const len = this.measureLength(pi, idx), staves = this.attrs(pi, idx).staves;
    const nb = this.events(pi, where === 'before' ? idx + 1 : idx - 1);
    const items = [];
    for (let s = 1; s <= staves; s++) {
      const v = nb.find((e) => e.staff === String(s))?.voice || (s === 1 ? '1' : String(4 * (s - 1) + 1));
      const r = this.makeNote({ type: 'whole', dur: len, voice: v, staff: String(s) });
      child(r, 'rest').setAttribute('measure', 'yes');
      if (staves > 1) this._setText(r, 'staff', String(s));
      items.push({ kind: 'note', els: [r], onset: 0, dur: len, ord: s, voice: v, staff: String(s) });
    }
    const lead = [...nm.children].filter((c) => ['attributes', 'print'].includes(c.localName));
    this._write(nm, lead, items, []);
  });
  this.renumber();
  this.refresh();
  return idx;
};

// Delete bars lo..hi in every part. The bar that follows keeps the clef, key and time it had.
P.deleteBars = function (lo, hi = lo) {
  if (hi - lo + 1 >= this.nMeasures) throw new Error('A score needs at least one bar');
  const want = this.parts.map((p, pi) => (hi + 1 < p.measures.length ? this.attrs(pi, hi + 1) : null));
  const systemStart = this.newSystem(lo);
  for (const part of this.parts) for (const m of part.measures.slice(lo, hi + 1)) m.remove();
  this.refresh();
  this.parts.forEach((p, pi) => { if (want[pi] && p.measures[lo]) this._restate(pi, lo, want[pi], lo === 0); });
  if (systemStart && this.parts[0].measures[lo] && !this.newSystem(lo) && lo > 0) {
    const pr = this.doc.createElement('print'); pr.setAttribute('new-system', 'yes');
    const m = this.parts[0].measures[lo];
    m.insertBefore(pr, m.firstChild);
  }
  this.renumber();
  this.refresh();
};

// ---------------------------------------------------------------- tuplets
const TUPLET_NORMAL = { 3: 2, 5: 4, 6: 4, 7: 4, 9: 8 };

P._tupletMarks = function (el, n, normal, mark) {
  let tm = child(el, 'time-modification');
  if (tm) tm.remove();
  if (n) {
    tm = this.doc.createElement('time-modification');
    for (const [k, v] of [['actual-notes', n], ['normal-notes', normal]]) { const e = this.doc.createElement(k); e.textContent = String(v); tm.appendChild(e); }
    this._insertInOrder(el, tm);
  }
  let nots = child(el, 'notations');
  if (nots) for (const t of children(nots, 'tuplet')) t.remove();
  if (mark) {
    if (!nots) { nots = this.doc.createElement('notations'); this._insertInOrder(el, nots); }
    const t = this.doc.createElement('tuplet'); t.setAttribute('type', mark);
    if (mark === 'start') t.setAttribute('bracket', 'yes');
    nots.appendChild(t);
  }
  if (nots && !nots.children.length) nots.remove();
};

// Turn a note (or rest) into an n-tuplet in its own time: a quarter becomes three triplet eighths, the first
// keeping the pitch and the others rests that are filled like any rest.
P.makeTuplet = function (ev, n = 3) {
  const normal = TUPLET_NORMAL[n];
  if (!normal) throw new Error('Tuplets of 3, 5, 6, 7 or 9 notes are supported');
  if (ev.tuplet) throw new Error('This note is already in a tuplet');
  if (ev.dots) throw new Error('Remove the dot first, then make the tuplet');
  if (ev.grace) throw new Error('Grace notes cannot be tuplets');
  let ti = TYPES.indexOf(ev.type);
  if (ti < 0) ti = TYPES.findIndex((t) => Math.abs(TYPE_QL[t] - ev.dur / ev.div) < 1e-9);
  if (ti < 0) throw new Error('Give the note a plain length first');
  const shift = Math.round(Math.log2(normal));
  const type = TYPES[ti + shift];
  if (!type) throw new Error('That note is too short to divide');
  const k = n / gcd(ev.dur, n);
  if (k > 1) this.rescalePart(ev.pi, k);
  const fresh = this.events(ev.pi, ev.mi).find((e) => e.el === ev.el);
  const d = fresh.dur / n;
  const group = fresh.chord.length ? fresh.chord.map((c) => c.el) : [fresh.el];
  for (const el of group) {
    this._setText(el, 'duration', d);
    this._setText(el, 'type', type);
    for (const x of children(el, 'beam')) x.remove();
    child(el, 'rest')?.removeAttribute('measure');
    this._tupletMarks(el, n, normal, el === group[0] ? 'start' : null);
  }
  const hasStaff = !!child(fresh.el, 'staff');
  let ref = group[group.length - 1];
  for (let i = 1; i < n; i++) {
    const r = this.makeNote({ type, dur: d, voice: fresh.voice, staff: fresh.staff });
    if (hasStaff) this._setText(r, 'staff', fresh.staff);
    this._tupletMarks(r, n, normal, i === n - 1 ? 'stop' : null);
    ref.parentNode.insertBefore(r, ref.nextSibling);
    ref = r;
  }
  this._attrCache = null;
  return fresh.el;
};

// the events of the tuplet `ev` belongs to (from its start/stop marks, or else by filling one beat group)
P.tupletGroup = function (ev) {
  if (!ev.tuplet) return [];
  const evs = this.events(ev.pi, ev.mi).filter((e) => !e.grace && e.staff === ev.staff && e.voice === ev.voice).sort((a, b) => a.onset - b.onset);
  const runs = [];
  let run = [];
  for (const e of evs) {
    const same = e.tuplet && run.length && run[0].tuplet.actual === e.tuplet.actual && run[0].tuplet.normal === e.tuplet.normal && run[run.length - 1].onset + run[run.length - 1].dur === e.onset;
    if (e.tuplet && (same || !run.length)) run.push(e);
    else { if (run.length) runs.push(run); run = e.tuplet ? [e] : []; }
  }
  if (run.length) runs.push(run);
  const mark = (e) => e.el.querySelector(':scope > notations > tuplet')?.getAttribute('type');
  for (const r of runs) {
    if (!r.some((e) => e.el === ev.el)) continue;
    // split the run into groups
    const groups = [];
    let g = [], sum = 0;
    const unit = Math.min(...r.map((e) => (TYPE_QL[e.type] || e.dur / e.div) * e.div));
    const span = unit * r[0].tuplet.normal;
    const marked = r.some((e) => mark(e) === 'start');
    for (const e of r) {
      if (marked && mark(e) === 'start' && g.length) { groups.push(g); g = []; sum = 0; }
      g.push(e); sum += e.dur;
      if (marked ? mark(e) === 'stop' : sum >= span - 1e-6) { groups.push(g); g = []; sum = 0; }
    }
    if (g.length) groups.push(g);
    return groups.find((x) => x.some((e) => e.el === ev.el)) || r;
  }
  return [ev];
};

// Undo a tuplet: the group becomes one note (the first pitch in it) or one rest of the group's whole length.
P.removeTuplet = function (ev) {
  const g = this.tupletGroup(ev);
  if (!g.length) throw new Error('This note is not in a tuplet');
  const total = g.reduce((a, e) => a + e.dur, 0);
  const div = g[0].div;
  const pieces = Score.split(total, div);
  if (!pieces) throw new Error('That tuplet does not add up to a plain length');
  const keep = g.find((e) => !e.rest) || g[0];
  const els = keep.chord.length ? keep.chord.map((c) => c.el) : [keep.el];
  const anchor = g[0].el;
  const parent = anchor.parentNode;
  if (keep !== g[0]) for (const el of els) parent.insertBefore(el, anchor);
  for (const el of els) {
    this._setText(el, 'duration', pieces[0].v);
    this._setText(el, 'type', pieces[0].type);
    for (const x of children(el, 'dot')) x.remove();
    for (let i = 0; i < pieces[0].dots; i++) this._insertInOrder(el, this.doc.createElement('dot'));
    for (const x of children(el, 'beam')) x.remove();
    this._tupletMarks(el, 0, 0, null);
  }
  for (const e of g) if (e !== keep) for (const c of (e.chord.length ? e.chord.map((x) => x.el) : [e.el])) c.remove();
  let ref = els[els.length - 1];
  for (const p of pieces.slice(1)) {
    const r = this.makeNote({ type: p.type, dots: p.dots, dur: p.v, voice: keep.voice, staff: keep.staff });
    if (child(keep.el, 'staff')) this._setText(r, 'staff', keep.staff);
    parent.insertBefore(r, ref.nextSibling);
    ref = r;
  }
  this._attrCache = null;
  return keep.el;
};

// ---------------------------------------------------------------- palette: turn the selection into what was picked
// A rest becomes a note on the middle line (or `pitch`); a note becomes a rest of the same length.
P.restToNote = function (ev, pitch) {
  if (!ev.rest) return ev.el;
  this.setPitch(ev.el, pitch);
  const r = child(ev.el, 'rest'); if (r) r.remove();
  ev.el.removeAttribute('print-object');
  if (!child(ev.el, 'type')) {
    const p = Score.split(ev.dur, ev.div);
    if (p && p.length === 1) { this._setText(ev.el, 'type', p[0].type); for (let i = 0; i < p[0].dots; i++) this._insertInOrder(ev.el, this.doc.createElement('dot')); }
  }
  this._attrCache = null;
  return ev.el;
};

// bar onset of an event in quarter notes
P.onsetQl = function (ev) { return ev.onset / ev.div; };

export { Score };
