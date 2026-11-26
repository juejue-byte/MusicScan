// Clef changes, for the two reasons people need them on a scanned page: a clef the reader got wrong (the notes
// stay where they are printed on the staff and are re-read in the right clef), or a real clef change (the notes
// keep their pitch and move on the staff).
import { Score, keyAlter, clefTop } from './score.js';
import './edits.js';

export const CLEFS = {
  treble: { sign: 'G', line: 2, name: 'Treble' },
  bass: { sign: 'F', line: 4, name: 'Bass' },
  alto: { sign: 'C', line: 3, name: 'Alto' },
  tenor: { sign: 'C', line: 4, name: 'Tenor' },
  treble8vb: { sign: 'G', line: 2, octaveChange: -1, name: 'Treble 8vb (tenor voice)' },
};
const ATTR_AFTER_CLEF = ['staff-details', 'transpose', 'for-part', 'directive', 'measure-style'];

export function clefId(c) {
  if (!c) return 'treble';
  for (const [id, d] of Object.entries(CLEFS)) if (d.sign === c.sign && d.line === c.line && (d.octaveChange || 0) === (c.octaveChange || 0)) return id;
  return 'treble';
}

// set the clef of `staff` in part pi from bar `from` to the next clef change on that staff
Score.prototype.setClef = function (pi, staff, from, id, keepPlace) {
  const want = CLEFS[id];
  const ms = this.parts[pi].measures;
  const old = this.attrs(pi, from).clefs[staff] || { sign: 'G', line: 2 };
  const delta = clefTop(want) - clefTop(old);
  if (keepPlace && delta) {
    for (let mi = from; mi < ms.length; mi++) {
      if (mi > from && this.attrs(pi, mi).changed?.['clef' + staff]) break;
      const fifths = this.attrs(pi, mi).fifths;
      for (const e of this.events(pi, mi)) {
        if (e.staff !== staff) continue;
        for (const c of e.chord) {
          const idx = this.diatonic(c.pitch) + delta;
          const np = this.pitchAt(idx, fifths);
          const explicit = !!c.el.querySelector(':scope > accidental');
          // a printed accidental stays on its note; otherwise the note follows the key
          if (explicit || (c.pitch.alter || 0) !== keyAlter(fifths, c.pitch.step)) np.alter = c.pitch.alter || 0;
          this.setPitch(c.el, np, explicit);
        }
      }
    }
  }
  const at = this._attrsEl(ms[from]);
  const multi = (this.attrs(pi, from).staves || 1) > 1;
  let cl = [...at.querySelectorAll(':scope > clef')].find((c) => (c.getAttribute('number') || '1') === staff);
  if (!cl) {
    cl = this.doc.createElement('clef');
    if (multi || staff !== '1') cl.setAttribute('number', staff);
    const before = [...at.children].find((c) => ATTR_AFTER_CLEF.includes(c.localName) || (c.localName === 'clef' && +(c.getAttribute('number') || 1) > +staff));
    at.insertBefore(cl, before || null);
  }
  cl.textContent = '';
  const add = (n, v) => { const e = this.doc.createElement(n); e.textContent = String(v); cl.appendChild(e); };
  add('sign', want.sign); add('line', want.line);
  if (want.octaveChange) add('clef-octave-change', want.octaveChange);
  this._attrCache = null;
};
