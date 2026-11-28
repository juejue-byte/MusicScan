// Transpose the whole piece by an interval: every note moves by the interval (spelled by its scale step), every key
// signature moves with it, and keys past seven sharps or flats are respelled (C♯ major becomes D♭ major).
import { Score, midiOf } from './score.js';
import './edits.js';

// interval: diatonic steps, semitones, change of key signature in fifths
export const INTERVALS = [
  { id: 'm2', name: 'minor 2nd (half step)', d: 1, semis: 1, fifths: -5 },
  { id: 'M2', name: 'major 2nd (whole step)', d: 1, semis: 2, fifths: 2 },
  { id: 'm3', name: 'minor 3rd', d: 2, semis: 3, fifths: -3 },
  { id: 'M3', name: 'major 3rd', d: 2, semis: 4, fifths: 4 },
  { id: 'P4', name: 'perfect 4th', d: 3, semis: 5, fifths: -1 },
  { id: 'P5', name: 'perfect 5th', d: 4, semis: 7, fifths: 1 },
  { id: 'P8', name: 'octave', d: 7, semis: 12, fifths: 0 },
];
const ACC = { '-2': 'flat-flat', '-1': 'flat', 0: 'natural', 1: 'sharp', 2: 'double-sharp' };

Score.prototype.transpose = function (id, dir = 1) {
  const iv = INTERVALS.find((x) => x.id === id);
  if (!iv) throw new Error('Unknown interval');
  for (const part of this.parts) {
    // the key signature in force decides respelling; take the first one of the part
    const first = part.el.querySelector('key > fifths');
    let f0 = first ? +first.textContent : 0;
    let nf = f0 + dir * iv.fifths, d = dir * iv.d;
    if (nf > 7) { nf -= 12; d += 1; } else if (nf < -7) { nf += 12; d -= 1; }
    const shift = nf - f0;
    for (const k of part.el.querySelectorAll('key > fifths')) {
      let v = +k.textContent + shift;
      if (v > 7) v -= 12; else if (v < -7) v += 12;
      k.textContent = String(v);
    }
    for (const n of part.el.querySelectorAll('note')) {
      const p = n.querySelector(':scope > pitch');
      if (!p) continue;
      const step = p.querySelector('step').textContent.trim();
      const octave = +p.querySelector('octave').textContent;
      const alter = +(p.querySelector('alter')?.textContent || 0);
      const midi = midiOf({ step, octave, alter }) + dir * iv.semis;
      const idx = this.diatonic({ step, octave }) + d;
      const nat = this.pitchAt(idx, 0);
      let na = midi - midiOf({ ...nat, alter: 0 });
      na = Math.max(-2, Math.min(2, na));
      const explicit = !!n.querySelector(':scope > accidental');
      this.setPitch(n, { step: nat.step, octave: nat.octave, alter: na }, explicit);
      if (explicit) n.querySelector(':scope > accidental').textContent = ACC[na];
    }
  }
  this._attrCache = null;
};
