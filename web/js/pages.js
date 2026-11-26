// Multi-page scores. Every page is read on its own (one photo or one PDF page = one job), then its bars are
// appended to the one score being edited, so editing, playback and export always cover the whole piece.
// Which page a bar came from lives in the bar's meta (meta[mi].page = the job id); the page order is the order of
// the bars. Like the rest of the editor, these edits patch the MusicXML DOM in place.
import { Score } from './score.js';
import './edits.js';

const gcd = (a, b) => (b ? gcd(b, a % b) : Math.abs(a));
const lcm = (a, b) => (a * b) / gcd(a, b);
function child(el, name) { for (const c of el.children) if (c.localName === name) return c; return null; }
function children(el, name) { return [...el.children].filter((c) => c.localName === name); }
const LEAD = (c) => ['note', 'backup', 'forward'].includes(c.localName);

const P = Score.prototype;

// the attributes in force after the last bar (its own mid-bar changes included): what a next page continues from
P.endState = function (pi) {
  const p = this.parts[pi];
  const last = p.measures.length - 1;
  if (last < 0) return null;
  const st = { ...this.attrs(pi, last), changed: {} };
  st.clefs = { ...st.clefs };
  let opening = true;
  for (const c of p.measures[last].children) {
    if (c.localName === 'note') opening = false;
    if (c.localName === 'attributes' && !opening) this._applyAttrs(c, st, false);
  }
  return st;
};

// the context the server needs to read a page that continues this score (same shape as for rescans)
P.endContext = function () {
  return { parts: this.parts.map((p, pi) => {
    const a = this.endState(pi);
    const clefs = {};
    for (const [n, c] of Object.entries(a.clefs)) clefs[n] = `${c.sign}${c.line}`;
    return { staves: a.staves, fifths: a.fifths, beats: a.beats, beat_type: a.beatType, clefs };
  }) };
};

// remove the key / time / clef / staves a bar restates although they are already in force (a page's reading
// declares everything on its first bar; once joined to the page before, that would show a stray time signature)
P._dropRedundant = function (pi, mi) {
  if (mi <= 0) return;
  const m = this.parts[pi].measures[mi];
  if (!m) return;
  const before = this.endStateBefore(pi, mi);
  for (const at of [...m.children]) {
    if (LEAD(at)) break;
    if (at.localName !== 'attributes') continue;
    for (const c of [...at.children]) {
      const n = c.localName;
      if (n === 'divisions' && +c.textContent === before.divisions) c.remove();
      else if (n === 'key' && +(child(c, 'fifths')?.textContent ?? NaN) === before.fifths && !child(c, 'mode')) c.remove();
      else if (n === 'time' && +(child(c, 'beats')?.textContent ?? NaN) === before.beats && +(child(c, 'beat-type')?.textContent ?? NaN) === before.beatType && !c.getAttribute('symbol')) c.remove();
      else if (n === 'staves' && +c.textContent === before.staves) c.remove();
      else if (n === 'clef') {
        const num = c.getAttribute('number') || '1';
        const cur = before.clefs[num];
        const sign = child(c, 'sign')?.textContent.trim(), line = +(child(c, 'line')?.textContent ?? 0), oc = +(child(c, 'clef-octave-change')?.textContent ?? 0);
        if (cur && cur.sign === sign && cur.line === line && (cur.octaveChange || 0) === oc) c.remove();
      }
    }
    if (!at.children.length) at.remove();
  }
  this._attrCache = null;
};

// the state after bar mi-1 (attributes inside it included)
P.endStateBefore = function (pi, mi) {
  const st = { ...this.attrs(pi, mi - 1), changed: {} };
  st.clefs = { ...st.clefs };
  let opening = true;
  for (const c of this.parts[pi].measures[mi - 1].children) {
    if (c.localName === 'note') opening = false;
    if (c.localName === 'attributes' && !opening) this._applyAttrs(c, st, false);
  }
  return st;
};

// a bar of whole-bar rests on every staff (for a part the new page did not have)
P._restBar = function (pi, len, staves) {
  const m = this.doc.createElement('measure');
  for (let s = 1; s <= staves; s++) {
    if (s > 1) {
      const b = this.doc.createElement('backup');
      const d = this.doc.createElement('duration'); d.textContent = String(len); b.appendChild(d);
      m.appendChild(b);
    }
    const r = this.makeNote({ type: 'whole', dur: len, voice: s === 1 ? '1' : String(4 * (s - 1) + 1), staff: String(s) });
    child(r, 'rest').setAttribute('measure', 'yes');
    if (staves > 1) this._setText(r, 'staff', String(s));
    m.appendChild(r);
  }
  return m;
};

// mark where each page starts (<print new-page>), and nowhere else; `starts` = global bar indices
P.markPages = function (starts) {
  const set = new Set(starts.filter((i) => i > 0));
  const ms = this.parts[0]?.measures || [];
  ms.forEach((m, mi) => {
    let pr = null;
    for (const c of m.children) { if (LEAD(c)) break; if (c.localName === 'print') { pr = c; break; } }
    if (set.has(mi)) {
      if (!pr) { pr = this.doc.createElement('print'); m.insertBefore(pr, m.firstChild); }
      pr.setAttribute('new-page', 'yes');
      pr.removeAttribute('new-system');
    } else if (pr && pr.getAttribute('new-page') === 'yes') {
      pr.removeAttribute('new-page');
      if (mi > 0) pr.setAttribute('new-system', 'yes');
      if (!pr.attributes.length && !pr.children.length) pr.remove();
    }
  });
};

/** Append every bar of `other` (a Score: the next page's reading) after the last bar, part by part.
 * The parts are matched in order; a part the page lacks gets bars of rests, extra parts on the page are dropped.
 * Durations are brought to this score's divisions. Returns { added, dropped } (bars added, parts dropped). */
P.appendScore = function (other) {
  const start = this.nMeasures;
  const n = other.nMeasures;
  if (!n) return { added: 0, dropped: 0 };
  const lens = [];
  for (let k = 0; k < n; k++) {
    // bar k's length in quarter notes, from the page's first part (all parts agree after the sanitizer)
    const a = other.attrs(0, k);
    lens.push(other.measureLength(0, k) / a.divisions || (a.beats * 4) / a.beatType);
  }
  this.parts.forEach((part, pi) => {
    const op = other.parts[pi];
    let L = this.attrs(pi, Math.max(0, part.measures.length - 1)).divisions;
    if (op) for (let k = 0; k < op.measures.length; k++) L = lcm(L, other.attrs(pi, k).divisions);
    const cur = this.attrs(pi, Math.max(0, part.measures.length - 1)).divisions;
    if (L !== cur) this.rescalePart(pi, L / cur);
    const div = this.attrs(pi, Math.max(0, part.measures.length - 1)).divisions;
    const staves = this.endState(pi).staves;
    for (let k = 0; k < n; k++) {
      const nm = op?.measures[k];
      let m;
      if (nm) {
        m = this.doc.importNode(nm, true);
        const f = div / other.attrs(pi, k).divisions;
        for (const d of m.querySelectorAll(':scope > note > duration, :scope > backup > duration, :scope > forward > duration')) d.textContent = String(Math.round(+d.textContent * f));
        for (const d of m.querySelectorAll(':scope > attributes > divisions')) d.remove();
        for (const a of m.querySelectorAll(':scope > attributes')) if (!a.children.length) a.remove();
        if (k === 0) m.removeAttribute('implicit');
      } else {
        m = this._restBar(pi, Math.round(lens[k] * div), staves);
      }
      part.el.appendChild(m);
    }
  });
  this.refresh();
  // the page's first bar restates what its reading saw; keep only real changes
  this.parts.forEach((p, pi) => this._dropRedundant(pi, start));
  this.renumber();
  this.refresh();
  return { added: n, dropped: Math.max(0, other.parts.length - this.parts.length) };
};

/** Move bars lo..hi (a page) so they sit before bar `dest` (an index in the current score; nMeasures = the end).
 * Every bar the move touches re-states what must be in force there, then repeats are dropped again. */
P.moveBars = function (lo, hi, dest) {
  if (dest >= lo && dest <= hi + 1) return;
  const N = this.nMeasures;
  const want = (mi) => this.parts.map((p, pi) => (mi < p.measures.length ? { ...this.attrs(pi, mi), clefs: { ...this.attrs(pi, mi).clefs } } : null));
  const touched = [lo, hi + 1, dest].filter((i) => i < N);
  const wants = touched.map(want);
  // remember the elements (indices change once moved)
  const els = touched.map((mi) => this.parts.map((p) => p.measures[mi]));
  // the first bar of the whole score must declare everything; so must every touched bar for now
  touched.forEach((mi, t) => this.parts.forEach((p, pi) => { if (wants[t][pi]) this._restate(pi, mi, wants[t][pi], true); }));
  this.parts.forEach((p) => {
    const block = p.measures.slice(lo, hi + 1);
    const ref = p.measures[dest] || null;
    for (const m of block) p.el.insertBefore(m, ref);
  });
  this.refresh();
  // the new first bar keeps everything (it opens the piece); the others drop what is already in force
  for (const row of els) row.forEach((el, pi) => {
    const mi = this.parts[pi].measures.indexOf(el);
    if (mi > 0) this._dropRedundant(pi, mi);
  });
  this.renumber();
  this.refresh();
};

// ---------------------------------------------------------------- page ranges from the bar meta
/** [{ id, lo, hi }] in score order. Bars without a page belong to `fallback` (the first page's job). */
export function pageRanges(meta, n, fallback) {
  const out = [];
  for (let mi = 0; mi < n; mi++) {
    const id = meta[mi]?.page ?? fallback ?? null;
    const last = out[out.length - 1];
    if (last && last.id === id) last.hi = mi;
    else out.push({ id, lo: mi, hi: mi });
  }
  return out;
}
