// Typed markings as real MusicXML: dynamics, hairpins (wedges), fingerings, rehearsal marks and text (words).
// Like edits.js this patches Score.prototype and the MusicXML DOM in place, so other apps read the markings and
// everything else in the file survives. drawMarks() draws them on the rendered score and returns hit boxes.
import { Score } from './score.js';

const SVGNS = 'http://www.w3.org/2000/svg';
export const DYNAMICS = ['pp', 'p', 'mp', 'mf', 'f', 'ff', 'sfz', 'fp'];
const DYN_ALL = new Set(['pppppp', 'ppppp', 'pppp', 'ppp', 'pp', 'p', 'mp', 'mf', 'f', 'ff', 'fff', 'ffff', 'fffff', 'ffffff', 'fp', 'sf', 'sfp', 'sfpp', 'sfz', 'sffz', 'sfzp', 'fz', 'rf', 'rfz', 'pf', 'n']);
export const WORDS = ['cresc.', 'dim.', 'rit.', 'a tempo', 'dolce', 'legato', 'espress.', 'poco a poco'];

const kids = (el, name) => [...el.children].filter((c) => c.localName === name);
const kid = (el, name) => kids(el, name)[0] || null;
const num = (el, name, d = 0) => { const c = kid(el, name); return c ? +c.textContent.trim() || 0 : d; };

// MusicXML element order inside <direction> and <notations>
const DIR_ORDER = ['direction-type', 'offset', 'footnote', 'level', 'voice', 'staff', 'sound', 'listening'];
function insertOrdered(parent, el, order) {
  const rank = order.indexOf(el.localName);
  for (const c of parent.children) if (order.indexOf(c.localName) > rank) { parent.insertBefore(el, c); return el; }
  parent.appendChild(el);
  return el;
}

// One direction's meaning: the first direction-type MusicScan knows how to show
function readDirection(d) {
  for (const dt of kids(d, 'direction-type')) {
    for (const c of dt.children) {
      const n = c.localName;
      if (n === 'dynamics') {
        const v = [...c.children].map((x) => (x.localName === 'other-dynamics' ? x.textContent.trim() : x.localName)).join('');
        if (v) return { kind: 'dynamics', value: v };
      }
      if (n === 'wedge') return { kind: 'wedge', value: c.getAttribute('type'), number: c.getAttribute('number') || '1', wedgeEl: c };
      if (n === 'words' && c.textContent.trim()) return { kind: 'words', value: kids(dt, 'words').map((w) => w.textContent).join('').trim(), italic: c.getAttribute('font-style') !== 'normal' };
      if (n === 'rehearsal' && c.textContent.trim()) return { kind: 'rehearsal', value: c.textContent.trim() };
    }
  }
  return null;
}

// Every marking in one measure of one part, with its onset in divisions (where it sits in time)
// (cached per bar while the bar is unchanged: every redraw walks all of them)
const marksCache = new WeakMap();
Score.prototype.marksIn = function (pi, mi) {
  const m = this.parts[pi]?.measures[mi];
  if (!m) return [];
  const rev = this.barRevision?.(m);
  const key = rev && `${rev}/${pi}/${mi}`;
  const hit = key && marksCache.get(m);
  if (hit && hit.key === key) return hit.out.map((o) => ({ ...o }));
  const out = readMarks(m, pi, mi);
  if (key) marksCache.set(m, { key, out: out.map((o) => ({ ...o })) });
  return out;
};
function readMarks(m, pi, mi) {
  const out = [];
  let cur = 0, last = null;
  for (const c of m.children) {
    const n = c.localName;
    if (n === 'backup') cur -= num(c, 'duration');
    else if (n === 'forward') cur += num(c, 'duration');
    else if (n === 'note') {
      const chord = !!kid(c, 'chord');
      const grace = !!kid(c, 'grace');
      const onset = chord && last ? last.onset : cur;
      for (const f of c.querySelectorAll(':scope > notations > technical > fingering')) {
        out.push({ kind: 'fingering', value: f.textContent.trim(), el: f, noteEl: c, pi, mi, onset, staff: kid(c, 'staff')?.textContent.trim() || '1' });
      }
      if (!chord) { last = { onset: cur }; if (!grace) cur += num(c, 'duration'); }
    } else if (n === 'direction') {
      const r = readDirection(c);
      if (!r) continue;
      const placement = c.getAttribute('placement') || (r.kind === 'dynamics' || r.kind === 'wedge' ? 'below' : 'above');
      out.push({ ...r, el: c, pi, mi, onset: cur + num(c, 'offset'), staff: kid(c, 'staff')?.textContent.trim() || '1', placement });
    }
  }
  return out;
}

Score.prototype.allMarks = function () {
  const out = [];
  this.parts.forEach((p, pi) => { for (let mi = 0; mi < p.measures.length; mi++) out.push(...this.marksIn(pi, mi)); });
  return out;
};

Score.prototype._direction = function (ev, placement, build) {
  const d = this.doc.createElement('direction');
  d.setAttribute('placement', placement);
  const dt = this.doc.createElement('direction-type');
  build(dt);
  d.appendChild(dt);
  if (this._staffCount(ev.pi) > 1 || ev.staff !== '1') {
    const s = this.doc.createElement('staff');
    s.textContent = ev.staff;
    insertOrdered(d, s, DIR_ORDER);
  }
  return d;
};
Score.prototype._staffCount = function (pi) {
  let n = 1;
  for (let mi = 0; mi < this.parts[pi].measures.length; mi++) n = Math.max(n, this.attrs(pi, mi).staves || 1);
  return n;
};
// the mark of a kind that already sits on this note (same part, bar, staff and onset), if any
Score.prototype._markAt = function (ev, kind) {
  return this.marksIn(ev.pi, ev.mi).find((k) => k.kind === kind && k.onset === ev.onset && k.staff === ev.staff && k.el.nextElementSibling === ev.el) || null;
};

/** Put a dynamic (pp ... ff, sfz, fp) under a note. A dynamic already on that note is replaced. Returns the <direction>. */
Score.prototype.setDynamic = function (ev, value) {
  if (!DYN_ALL.has(value)) throw new Error(`Unknown dynamic ${value}`);
  const old = this._markAt(ev, 'dynamics');
  const d = this._direction(ev, 'below', (dt) => {
    const dy = this.doc.createElement('dynamics');
    dy.appendChild(this.doc.createElement(value));
    dt.appendChild(dy);
  });
  if (old) old.el.replaceWith(d); else ev.el.parentNode.insertBefore(d, ev.el);
  return d;
};

/** Change the value of a dynamic marking (its <direction>). */
Score.prototype.changeDynamic = function (dirEl, value) {
  if (!DYN_ALL.has(value)) throw new Error(`Unknown dynamic ${value}`);
  const dy = dirEl.querySelector(':scope > direction-type > dynamics');
  if (!dy) throw new Error('That marking is not a dynamic');
  dy.replaceChildren(this.doc.createElement(value));
};

/** Change the text of a words marking. */
Score.prototype.changeWords = function (dirEl, text) {
  text = String(text || '').trim();
  if (!text) throw new Error('Type the text first');
  const ws = [...dirEl.querySelectorAll(':scope > direction-type > words')];
  if (!ws.length) throw new Error('That marking is not text');
  ws[0].textContent = text;
  for (const w of ws.slice(1)) w.remove();
};

/** Text such as "rit." or "dolce" at a note (above the staff unless placement says below). Returns the <direction>. */
Score.prototype.addWords = function (ev, text, placement = 'above') {
  text = String(text || '').trim();
  if (!text) throw new Error('Type the text first');
  const d = this._direction(ev, placement, (dt) => {
    const w = this.doc.createElement('words');
    w.setAttribute('font-style', 'italic');
    w.textContent = text;
    dt.appendChild(w);
  });
  ev.el.parentNode.insertBefore(d, ev.el);
  return d;
};

/** The next free rehearsal letter: A, B, ... Z, AA ... */
Score.prototype.nextRehearsal = function () {
  const used = new Set(this.allMarks().filter((m) => m.kind === 'rehearsal').map((m) => m.value));
  for (let i = 0; i < 702; i++) {
    const s = i < 26 ? String.fromCharCode(65 + i) : String.fromCharCode(65 + Math.floor(i / 26) - 1) + String.fromCharCode(65 + (i % 26));
    if (!used.has(s)) return s;
  }
  return '?';
};

/** A boxed rehearsal mark at the start of bar mi (top part). An existing one there is replaced. Returns the <direction>. */
Score.prototype.setRehearsal = function (mi, text) {
  const m = this.parts[0].measures[mi];
  if (!m) throw new Error('No such bar');
  text = String(text || this.nextRehearsal()).trim();
  const old = this.marksIn(0, mi).find((k) => k.kind === 'rehearsal' && k.onset === 0);
  const d = this.doc.createElement('direction');
  d.setAttribute('placement', 'above');
  const dt = this.doc.createElement('direction-type');
  const r = this.doc.createElement('rehearsal');
  r.setAttribute('enclosure', 'square');
  r.textContent = text;
  dt.appendChild(r);
  d.appendChild(dt);
  if (this._staffCount(0) > 1) { const s = this.doc.createElement('staff'); s.textContent = '1'; d.appendChild(s); }
  if (old) { old.el.replaceWith(d); return d; }
  // after the bar's own attributes and print/barline, before its first note
  let at = null;
  for (const c of m.children) if (!['attributes', 'print', 'barline', 'sound'].includes(c.localName)) { at = c; break; }
  m.insertBefore(d, at);
  return d;
};

/**
 * A hairpin from note ev to the end of bar endMi (same part and staff). type: 'crescendo' | 'diminuendo'.
 * Writes a <wedge type=...> before the start note and a <wedge type="stop"> at the end of the last bar.
 */
Score.prototype.addHairpin = function (ev, type, endMi = ev.mi) {
  if (type !== 'crescendo' && type !== 'diminuendo') throw new Error('A hairpin is a crescendo or a diminuendo');
  if (endMi < ev.mi) endMi = ev.mi;
  // a number not used by a wedge that is open across this span
  const used = new Set();
  for (let mi = 0; mi <= endMi; mi++) for (const k of this.marksIn(ev.pi, mi)) if (k.kind === 'wedge') { if (k.value === 'stop') used.delete(k.number); else used.add(k.number); }
  let n = 1;
  while (used.has(String(n)) && n < 6) n++;
  const wedge = (t) => (dt) => { const w = this.doc.createElement('wedge'); w.setAttribute('type', t); w.setAttribute('number', String(n)); dt.appendChild(w); };
  const start = this._direction(ev, 'below', wedge(type));
  ev.el.parentNode.insertBefore(start, ev.el);
  const stop = this._direction(ev, 'below', wedge('stop'));
  const m = this.parts[ev.pi].measures[endMi];
  // at the end of the bar: after the last note, before a closing barline
  let at = null;
  for (let c = m.lastElementChild; c; c = c.previousElementSibling) {
    if (c.localName === 'barline' && c.getAttribute('location') !== 'left') { at = c; continue; }
    break;
  }
  // the end of the bar in time: the stop must land at the bar end, not at the end of a short last voice
  const len = this.measureLength(ev.pi, endMi);
  let cur = 0;
  for (const c of m.children) {
    if (c === at) break;
    if (c.localName === 'backup') cur -= num(c, 'duration');
    else if (c.localName === 'forward') cur += num(c, 'duration');
    else if (c.localName === 'note' && !kid(c, 'chord') && !kid(c, 'grace')) cur += num(c, 'duration');
  }
  if (cur < len) {
    const o = this.doc.createElement('offset');
    o.textContent = String(len - cur);
    insertOrdered(stop, o, DIR_ORDER);
  }
  m.insertBefore(stop, at);
  return start;
};

/** Fingering on one note of a chord (noteEl). value '' or null removes it. */
Score.prototype.setFingering = function (noteEl, value) {
  for (const f of [...noteEl.querySelectorAll(':scope > notations > technical > fingering')]) {
    const tech = f.parentNode, nots = tech.parentNode;
    f.remove();
    if (!tech.children.length) tech.remove();
    if (!nots.children.length) nots.remove();
  }
  if (value === null || value === undefined || value === '') return null;
  let nots = kid(noteEl, 'notations');
  if (!nots) { nots = this.doc.createElement('notations'); this._insertInOrder(noteEl, nots); }
  let tech = kid(nots, 'technical');
  if (!tech) { tech = this.doc.createElement('technical'); nots.appendChild(tech); }
  const f = this.doc.createElement('fingering');
  f.textContent = String(value);
  tech.appendChild(f);
  return f;
};

/** Remove a marking (an entry of marksIn). A hairpin goes with its other end. */
Score.prototype.removeMark = function (mark) {
  if (mark.kind === 'fingering') { this.setFingering(mark.noteEl, null); return; }
  if (mark.kind === 'wedge') {
    const other = this._wedgePartner(mark);
    if (other) other.el.remove();
  }
  mark.el.remove();
};
// the other end of a hairpin: the next stop after a start, or the last start before a stop (same part and number)
Score.prototype._wedgePartner = function (mark) {
  const list = [];
  const p = this.parts[mark.pi];
  for (let mi = 0; mi < p.measures.length; mi++) for (const k of this.marksIn(mark.pi, mi)) if (k.kind === 'wedge' && k.number === mark.number) list.push(k);
  const i = list.findIndex((k) => k.el === mark.el);
  if (i < 0) return null;
  if (mark.value !== 'stop') { for (let j = i + 1; j < list.length; j++) if (list[j].value === 'stop') return list[j]; else break; return null; }
  for (let j = i - 1; j >= 0; j--) if (list[j].value !== 'stop') return list[j]; else break;
  return null;
};

export { Score };

// ---------------------------------------------------------------- drawing
function el(tag, attrs, parent) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (parent) parent.appendChild(e);
  return e;
}
const noteX = (n) => { try { return n.vf.getAbsoluteX() + (n.ghost ? 0 : 6); } catch (e) { return 0; } };
function bbox(n) { try { const b = n.vf.getBoundingBox(); return b ? { y0: b.getY(), y1: b.getY() + b.getH() } : null; } catch (e) { return null; } }

/**
 * Draw the markings of `score` on a rendered layout (render.js). Returns [{ mark, x0, y0, x1, y1 }] hit boxes in layout
 * units. `selected` is the element of the selected marking (drawn in blue).
 */
export function drawMarks(score, layout, { selected = null } = {}) {
  const svg = layout.svg;
  const g = el('g', { class: 'ms-marks' });
  svg.appendChild(g);
  const hits = [];
  const staveOf = new Map();
  for (const st of layout.staves) staveOf.set(`${st.pi}/${st.mi}/${st.staff}`, st);
  const notesBy = new Map();
  for (const n of layout.notes) {
    if (n.ghost) continue;
    const k = `${n.ev.pi}/${n.ev.mi}`;
    if (!notesBy.has(k)) notesBy.set(k, []);
    notesBy.get(k).push(n);
  }
  // x of a moment in a bar: the note that starts then (same staff first), else a proportional spot in the bar
  const xAt = (pi, mi, staff, onset) => {
    const ns = notesBy.get(`${pi}/${mi}`) || [];
    const same = ns.filter((n) => n.ev.onset === onset);
    const hit = same.find((n) => n.ev.staff === staff) || same[0];
    if (hit) return noteX(hit);
    const m = layout.measures[mi];
    const st = staveOf.get(`${pi}/${mi}/${staff}`) || staveOf.get(`${pi}/${mi}/1`);
    const len = score.measureLength(pi, mi) || 1;
    const x0 = st ? st.stave.getNoteStartX() + 6 : m.x0 + 10;
    return x0 + (m.x1 - 10 - x0) * Math.min(1, Math.max(0, onset / len));
  };
  // a clear line under (or over) the notes of one staff in one bar
  const belowY = (st, pi, mi) => {
    const base = st.stave.getYForLine(4);
    let y = base + 24;
    for (const n of notesBy.get(`${pi}/${mi}`) || []) if (n.ev.staff === st.staff) { const b = bbox(n); if (b) y = Math.max(y, b.y1 + 16); }
    return Math.min(y, base + 44);
  };
  const aboveY = (st, pi, mi) => {
    const top = st.stave.getYForLine(0);
    let y = top - 14;
    for (const n of notesBy.get(`${pi}/${mi}`) || []) if (n.ev.staff === st.staff) { const b = bbox(n); if (b) y = Math.min(y, b.y0 - 8); }
    return Math.max(y, top - 36);
  };
  const color = (m) => (selected && m.el === selected ? '#2563eb' : '#111827');
  const text = (str, x, y, attrs, m) => {
    const t = el('text', { x, y, fill: color(m), 'text-anchor': 'middle', ...attrs }, g);
    t.textContent = str;
    let b;
    try { b = t.getBBox(); } catch (e) { b = { x: x - 10, y: y - 14, width: 20, height: 16 }; }
    if (!b.width) b = { x: x - 4 * str.length, y: y - 14, width: 8 * str.length, height: 16 };
    hits.push({ mark: m, x0: b.x - 4, y0: b.y - 4, x1: b.x + b.width + 4, y1: b.y + b.height + 4 });
    return t;
  };

  const marks = score.allMarks();
  const wedges = [];
  for (const m of marks) {
    const st = staveOf.get(`${m.pi}/${m.mi}/${m.staff}`) || staveOf.get(`${m.pi}/${m.mi}/1`);
    if (!st) continue;
    if (m.kind === 'dynamics') {
      text(m.value, xAt(m.pi, m.mi, m.staff, m.onset), m.placement === 'above' ? aboveY(st, m.pi, m.mi) : belowY(st, m.pi, m.mi), { 'font-family': "'Times New Roman', Times, serif", 'font-style': 'italic', 'font-weight': 700, 'font-size': 18, class: 'ms-dyn' }, m);
    } else if (m.kind === 'words') {
      const t = text(m.value, xAt(m.pi, m.mi, m.staff, m.onset), m.placement === 'below' ? belowY(st, m.pi, m.mi) : aboveY(st, m.pi, m.mi), { 'font-family': "'Times New Roman', Times, serif", 'font-style': m.italic ? 'italic' : 'normal', 'font-size': 14, 'text-anchor': 'start', class: 'ms-words' }, m);
      t.setAttribute('x', xAt(m.pi, m.mi, m.staff, m.onset) - 6);
      const h = hits[hits.length - 1];
      try { const b = t.getBBox(); Object.assign(h, { x0: b.x - 4, x1: b.x + b.width + 4 }); } catch (e) { /* keep */ }
    } else if (m.kind === 'rehearsal') {
      const ms = layout.measures[m.mi];
      const top = st.stave.getYForLine(0);
      // beside the bar number, not over it
      const x = (m.onset === 0 ? ms.x0 + 30 : xAt(m.pi, m.mi, m.staff, m.onset)) + 2;
      const t = text(m.value, x, top - 24, { 'font-family': 'system-ui, sans-serif', 'font-weight': 700, 'font-size': 15, class: 'ms-rehearsal' }, m);
      try { const b = t.getBBox(); el('rect', { x: b.x - 4, y: b.y - 2, width: b.width + 8, height: b.height + 4, fill: 'none', stroke: color(m), 'stroke-width': 1.4 }, g); } catch (e) { /* ignore */ }
    } else if (m.kind === 'fingering') {
      const n = (notesBy.get(`${m.pi}/${m.mi}`) || []).find((q) => q.ev.el === m.noteEl || q.ev.chord.some((c) => c.el === m.noteEl));
      if (!n) continue;
      const b = bbox(n);
      const stemUp = (() => { try { return n.vf.getStemDirection() === 1; } catch (e) { return false; } })();
      const heads = n.ev.chord.length;
      // stack chord fingerings above the chord, the highest note's on top
      const order = [...n.ev.chord].sort((a, c) => (c.pitch.octave * 7 + 'CDEFGAB'.indexOf(c.pitch.step)) - (a.pitch.octave * 7 + 'CDEFGAB'.indexOf(a.pitch.step)));
      const fingered = order.filter((c) => c.el.querySelector(':scope > notations > technical > fingering'));
      const k = Math.max(0, fingered.findIndex((c) => c.el === m.noteEl));
      const topY = Math.min(b ? b.y0 : st.stave.getYForLine(0), st.stave.getYForLine(0) + 4);
      const x = noteX(n) - (stemUp && heads === 1 ? 2 : 0);
      text(m.value, x, topY - 5 - (fingered.length - 1 - k) * 12, { 'font-family': 'system-ui, sans-serif', 'font-weight': 600, 'font-size': 12, class: 'ms-finger' }, m);
    } else if (m.kind === 'wedge') {
      wedges.push({ m, st });
    }
  }

  // hairpins: pair each start with the next stop of the same part and number, then draw across rows
  const open = new Map();
  const pairs = [];
  for (const w of wedges) {
    const k = `${w.m.pi}/${w.m.number}`;
    if (w.m.value === 'stop') { const s = open.get(k); if (s) { pairs.push([s, w]); open.delete(k); } }
    else { if (open.has(k)) pairs.push([open.get(k), null]); open.set(k, w); }
  }
  for (const s of open.values()) pairs.push([s, null]);
  for (const [a, b] of pairs) {
    const m = a.m;
    const x0 = xAt(m.pi, m.mi, m.staff, m.onset) - 4;
    const endMi = b ? b.m.mi : m.mi;
    const lenEnd = score.measureLength(m.pi, endMi);
    const x1 = b ? (b.m.onset >= lenEnd ? layout.measures[endMi].x1 - 8 : xAt(b.m.pi, b.m.mi, b.m.staff, b.m.onset) - 6) : layout.measures[m.mi].x1 - 8;
    const r0 = layout.measures[m.mi].rowIdx, r1 = layout.measures[endMi].rowIdx;
    const cresc = m.value === 'crescendo';
    // y: below the start staff in each row
    for (let r = r0; r <= r1; r++) {
      const row = layout.rows[r];
      const xs = r === r0 ? x0 : row.measures[0].x0 + 8;
      const xe = r === r1 ? x1 : row.measures[row.measures.length - 1].x1 - 4;
      if (xe - xs < 6) continue;
      // the lowest clear line across the bars this piece of the hairpin crosses
      let y = 0;
      for (const ms of row.measures) {
        if (ms.x1 < xs || ms.x0 > xe) continue;
        const st = staveOf.get(`${m.pi}/${ms.mi}/${m.staff}`);
        if (st) y = Math.max(y, belowY(st, m.pi, ms.mi) - 6);
      }
      if (!y) continue;
      // the opening grows along the whole hairpin and carries on over a line break
      const openAt = (x) => {
        if (r0 === r1) return ((x - x0) / Math.max(1, x1 - x0)) * 5;
        return r === r0 ? ((x - xs) / Math.max(1, xe - xs)) * 2.5 : 2.5 + ((x - xs) / Math.max(1, xe - xs)) * 2.5;
      };
      const h0 = cresc ? openAt(xs) : 5 - openAt(xs), h1 = cresc ? openAt(xe) : 5 - openAt(xe);
      const stroke = color(m);
      el('path', { d: `M${xe} ${y - h1} L${xs} ${y - h0} M${xs} ${y + h0} L${xe} ${y + h1}`, stroke, 'stroke-width': 1.3, fill: 'none', 'stroke-linecap': 'round', class: 'ms-wedge' }, g);
      hits.push({ mark: m, x0: xs - 4, y0: y - 10, x1: xe + 4, y1: y + 10 });
    }
  }
  return hits;
}
