// Slurs and articulations: drawn on the score (they come out of the reader on most printed pages) and edited with
// the keys the familiar notation editors use: S slur, Shift+S staccato, Shift+V accent, Shift+N tenuto,
// Shift+O marcato. Like every edit, they patch the MusicXML in place.
import { Score } from './score.js';
import './edits.js';

const P = Score.prototype;
// MusicXML articulation -> VexFlow articulation code
export const ARTICS = {
  staccato: { vf: 'a.', name: 'Staccato', key: 'Shift+S' },
  accent: { vf: 'a>', name: 'Accent', key: 'Shift+V' },
  tenuto: { vf: 'a-', name: 'Tenuto', key: 'Shift+N' },
  'strong-accent': { vf: 'a^', name: 'Marcato', key: 'Shift+O' },
  staccatissimo: { vf: 'av', name: 'Staccatissimo', key: '' },
};
const ORDER = ['accent', 'strong-accent', 'staccato', 'tenuto', 'detached-legato', 'staccatissimo', 'spiccato', 'scoop', 'plop', 'doit', 'falloff', 'breath-mark', 'caesura', 'stress', 'unstress', 'soft-accent', 'other-articulation'];
const kids = (el, name) => [...el.children].filter((c) => c.localName === name);
const kid = (el, name) => kids(el, name)[0] || null;

export function articulationsOf(el) {
  const a = el.querySelector(':scope > notations > articulations');
  return a ? [...a.children].map((c) => c.localName).filter((n) => ARTICS[n]) : [];
}

P._notations = function (el, create = true) {
  let n = kid(el, 'notations');
  if (!n && create) { n = this.doc.createElement('notations'); this._insertInOrder(el, n); }
  return n;
};

P.hasArticulation = function (ev, kind) { return articulationsOf(ev.el).includes(kind); };

// Toggle an articulation on a note (it sits on the chord's first note, as engravers write it)
P.toggleArticulation = function (ev, kind) {
  if (ev.rest) throw new Error('Select a note to give it a ' + (ARTICS[kind]?.name || kind).toLowerCase());
  const el = ev.el;
  const on = this.hasArticulation(ev, kind);
  const nots = this._notations(el);
  let arts = kid(nots, 'articulations');
  if (on) {
    for (const c of kids(arts, kind)) c.remove();
    if (!arts.children.length) arts.remove();
    if (!nots.children.length) nots.remove();
  } else {
    // staccato and staccatissimo, accent and marcato exclude each other
    const rival = { staccato: 'staccatissimo', staccatissimo: 'staccato', accent: 'strong-accent', 'strong-accent': 'accent' }[kind];
    if (!arts) { arts = this.doc.createElement('articulations'); nots.appendChild(arts); }
    if (rival) for (const c of kids(arts, rival)) c.remove();
    const a = this.doc.createElement(kind);
    const rank = ORDER.indexOf(kind);
    const before = [...arts.children].find((c) => ORDER.indexOf(c.localName) > rank);
    arts.insertBefore(a, before || null);
  }
  this._attrCache = null;
  return !on;
};

// ---------------------------------------------------------------- slurs
// every slur in a part as { start: el, stop: el, number } in reading order
P.slurs = function (pi) {
  const open = {};
  const out = [];
  for (const m of this.parts[pi].measures) {
    for (const n of m.querySelectorAll(':scope > note')) {
      for (const s of n.querySelectorAll(':scope > notations > slur')) {
        const num = s.getAttribute('number') || '1';
        const t = s.getAttribute('type');
        if (t === 'start') open[num] = { start: n, number: num, startEl: s };
        else if (t === 'stop' && open[num]) { out.push({ ...open[num], stop: n, stopEl: s }); delete open[num]; }
      }
    }
  }
  return out;
};

const noteOf = (el) => (el.querySelector(':scope > chord') ? (() => { let p = el.previousElementSibling; while (p && p.querySelector(':scope > chord')) p = p.previousElementSibling; return p || el; })() : el);

// the slur a note starts, if any
P.slurFrom = function (ev) {
  return this.slurs(ev.pi).find((s) => noteOf(s.start) === ev.el) || null;
};

// S: slur this note to `toEv` (default: the next note in its voice). On a note that starts a slur, removes it.
P.toggleSlur = function (ev, toEv = null) {
  const have = this.slurFrom(ev);
  if (have && !toEv) {
    have.startEl.remove(); have.stopEl.remove();
    for (const el of [have.start, have.stop]) { const n = kid(el, 'notations'); if (n && !n.children.length) n.remove(); }
    this._attrCache = null;
    return false;
  }
  if (ev.rest) throw new Error('Select a note to start a slur');
  let to = toEv;
  if (!to) {
    to = this.nextEvent(ev);
    // a slur skips rests to the next note, within two bars
    for (let i = 0; to && to.rest && i < 16; i++) to = this.nextEvent(to);
  }
  if (!to || to.rest || to.el === ev.el) throw new Error('There is no next note to slur to');
  // a number not used by a slur that is open here
  const used = new Set(this.slurs(ev.pi).filter((s) => {
    const all = [...this.parts[ev.pi].el.querySelectorAll('note')];
    const a = all.indexOf(s.start), b = all.indexOf(s.stop), x = all.indexOf(ev.el), y = all.indexOf(to.el);
    return a <= y && b >= x;
  }).map((s) => s.number));
  let num = 1;
  while (used.has(String(num))) num++;
  const mk = (type) => { const s = this.doc.createElement('slur'); s.setAttribute('type', type); s.setAttribute('number', String(num)); return s; };
  this._notations(ev.el).appendChild(mk('start'));
  this._notations(to.el).appendChild(mk('stop'));
  this._attrCache = null;
  return true;
};

// ---------------------------------------------------------------- drawing (called by render.js)
export function addArticulations(VF, note, e) {
  for (const k of articulationsOf(e.el)) {
    try {
      const a = new VF.Articulation(ARTICS[k].vf);
      note.addModifier(a, 0);
    } catch (err) { /* unknown glyph in this VexFlow */ }
  }
}

export function drawSlurs(VF, ctx, score, layout) {
  const byEl = new Map();
  for (const n of layout.notes) if (!n.ghost) byEl.set(n.ev.el, n);
  for (let pi = 0; pi < score.parts.length; pi++) {
    let list = [];
    try { list = score.slurs(pi); } catch (err) { list = []; }
    for (const s of list) {
      const a = byEl.get(noteOf(s.start)), b = byEl.get(noteOf(s.stop));
      if (!a && !b) continue;
      // VexFlow puts the slur on the note-head side, as engravers do
      const opts = {};
      const draw = (from, to) => { try { new VF.Curve(from, to, opts).setContext(ctx).draw(); } catch (err) { /* ignore */ } };
      if (a && b && a.rowIdx === b.rowIdx) draw(a.vf, b.vf);
      else {
        if (a) draw(a.vf, null);
        if (b) draw(null, b.vf);
      }
    }
  }
}

// ---------------------------------------------------------------- grace notes
// grace notes of a bar, grouped onto the note they lead into (same staff and voice): Map(mainEl -> [grace events])
export function graceMap(score, pi, mi) {
  const out = new Map();
  const pending = {};
  for (const e of score.events(pi, mi)) {
    const k = `${e.staff}/${e.voice}`;
    if (e.grace) { (pending[k] ||= []).push(e); continue; }
    if (pending[k]?.length) { out.set(e.el, pending[k]); pending[k] = []; }
  }
  return out;
}

// small notes before the main note, with a slash for acciaccaturas, beamed when there are several
export function addGraces(VF, note, graces, { clef, fifths, keyAlter, vfClef }) {
  if (!graces?.length) return;
  try {
    const dur = { whole: 'w', half: 'h', quarter: 'q', eighth: '8', '16th': '16', '32nd': '32' };
    const gn = graces.filter((g) => !g.rest && g.chord.length).map((g) => {
      const keys = g.chord.map((c) => `${c.pitch.step.toLowerCase()}/${c.pitch.octave - (clef?.octaveChange || 0)}`);
      const slash = g.el.querySelector(':scope > grace')?.getAttribute('slash') === 'yes';
      const n = new VF.GraceNote({ keys, duration: dur[g.type] || '8', slash, clef: vfClef });
      g.chord.forEach((c, i) => {
        const al = c.pitch.alter || 0;
        if (al !== keyAlter(fifths, c.pitch.step) || c.el.querySelector(':scope > accidental')) n.addModifier(new VF.Accidental({ '-2': 'bb', '-1': 'b', 0: 'n', 1: '#', 2: '##' }[al]), i);
      });
      return n;
    });
    if (!gn.length) return;
    const group = new VF.GraceNoteGroup(gn, true);
    if (gn.length > 1) group.beamNotes();
    note.addModifier(group, 0);
  } catch (err) { /* this VexFlow cannot draw it */ }
}
