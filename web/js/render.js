// Draws a Score with VexFlow and returns a layout map used for hit-testing and overlays.
import { Score, STEPS, keyAlter, clefKey, clefTop, midiOf } from './score.js';

const VF = window.Vex.Flow;
const VF_CLEF = { G2: 'treble', F4: 'bass', C3: 'alto', C4: 'tenor', C1: 'soprano', F3: 'baritone-f', C2: 'mezzo-soprano', G1: 'french' };
const KEYS = ['Cb', 'Gb', 'Db', 'Ab', 'Eb', 'Bb', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F#', 'C#'];
const VF_DUR = { breve: '1/2', whole: 'w', half: 'h', quarter: 'q', eighth: '8', '16th': '16', '32nd': '32', '64th': '64' };
const ACC = { '-2': 'bb', '-1': 'b', 0: 'n', 1: '#', 2: '##' };
export const STAFF_GAP = 92;      // distance between staves of a row
export const ROW_PAD_TOP = 46;    // room above the first staff (ledger lines, bar numbers)
export const ROW_PAD_BOTTOM = 40;

function durFromQl(ql) {
  const table = [[4, 'whole', 0], [3, 'half', 1], [2, 'half', 0], [1.5, 'quarter', 1], [1, 'quarter', 0], [0.75, 'eighth', 1], [0.5, 'eighth', 0], [0.375, '16th', 1], [0.25, '16th', 0], [0.125, '32nd', 0], [0.0625, '64th', 0]];
  for (const [q, t, d] of table) if (ql >= q - 1e-6) return [t, d];
  return ['64th', 0];
}

export function staffList(score) {
  // [{pi, staff}] in drawing order
  const out = [];
  score.parts.forEach((p, pi) => {
    let n = 1;
    for (let mi = 0; mi < p.measures.length; mi++) n = Math.max(n, score.attrs(pi, mi).staves || 1);
    for (let s = 1; s <= n; s++) out.push({ pi, staff: String(s) });
  });
  return out;
}

function measureWidth(score, mi, staves, first) {
  let w = 70;
  for (const s of staves) {
    const evs = score.events(s.pi, mi).filter((e) => e.staff === s.staff && !e.grace);
    const onsets = new Set(evs.map((e) => e.onset));
    let ww = 0;
    for (const e of evs) {
      if (!onsets.has(e.onset)) continue;
      onsets.delete(e.onset);
      const ql = e.dur / e.div;
      ww += ql >= 1 ? 34 : ql >= 0.5 ? 27 : 21;
      if (e.chord.some((c) => c.pitch.alter)) ww += 6;
    }
    w = Math.max(w, ww + 36);
  }
  if (first) {
    const a = score.attrs(staves[0].pi, mi);
    w += 42 + 11 * Math.abs(a.fifths) + (mi === 0 || a.changed?.time ? 28 : 0);
  }
  return w;
}

export function layoutRows(score, width) {
  const staves = staffList(score);
  const rows = [];
  let cur = [], used = 0;
  for (let mi = 0; mi < score.nMeasures; mi++) {
    let w = measureWidth(score, mi, staves, cur.length === 0);
    if (cur.length && used + w > width) {
      rows.push(cur); cur = []; used = 0;
      w = measureWidth(score, mi, staves, true);
    }
    cur.push({ mi, w });
    used += w;
  }
  if (cur.length) rows.push(cur);
  return { rows, staves };
}

export function render(score, el, opts = {}) {
  const zoom = opts.zoom || 1;
  const pxWidth = Math.max(300, opts.width || el.clientWidth || 900);
  const width = pxWidth / zoom;
  const left = 14, inner = width - left - 10;
  const { rows, staves } = layoutRows(score, inner);
  const rowH = ROW_PAD_TOP + (staves.length - 1) * STAFF_GAP + 40 + ROW_PAD_BOTTOM;
  const height = rows.length * rowH + 20;
  el.innerHTML = '';
  const renderer = new VF.Renderer(el, VF.Renderer.Backends.SVG);
  renderer.resize(pxWidth, height * zoom);
  const ctx = renderer.getContext();
  if (zoom !== 1) ctx.scale(zoom, zoom);
  const svg = el.querySelector('svg');
  const bg = document.createElementNS('http://www.w3.org/2000/svg', 'g');
  bg.setAttribute('class', 'ms-bg');
  svg.prepend(bg);
  const layout = { width, height, zoom, pxWidth, rowH, rows: [], measures: [], staves: [], notes: [], svg };
  const sel = opts.selected || new Set();
  const selNote = opts.selectedNote || null;
  const meta = opts.meta || [];
  const playing = opts.playing ?? -1;

  rows.forEach((row, ri) => {
    const y0 = 10 + ri * rowH;
    const scale = inner / row.reduce((a, m) => a + m.w, 0);
    const stretch = ri === rows.length - 1 ? Math.min(scale, 1.35) : scale;
    let x = left;
    const rowInfo = { y0, y1: y0 + rowH, measures: [] };
    const rowStaves = [];
    row.forEach((m, k) => {
      const w = m.w * stretch;
      const mi = m.mi;
      const vfStaves = [];
      staves.forEach((s, si) => {
        const a = score.attrs(s.pi, mi);
        const clef = a.clefs[s.staff] || a.clefs['1'] || { sign: 'G', line: 2 };
        const stave = new VF.Stave(x, y0 + ROW_PAD_TOP - 30 + si * STAFF_GAP, w);
        if (k === 0 || a.changed?.['clef' + s.staff]) stave.addClef(VF_CLEF[clefKey(clef)] || 'treble', k === 0 ? 'default' : 'small', clef.octaveChange === -1 ? '8vb' : clef.octaveChange === 1 ? '8va' : undefined);
        if (k === 0 || a.changed?.key) { if (a.fifths !== 0 || a.changed?.key) stave.addKeySignature(KEYS[a.fifths + 7] || 'C'); }
        if (mi === 0 || a.changed?.time) stave.addTimeSignature(`${a.beats}/${a.beatType}`);
        if (k === row.length - 1 && mi === score.nMeasures - 1) stave.setEndBarType(VF.Barline.type.END);
        stave.setContext(ctx);
        vfStaves.push({ stave, s, clef, a });
      });
      const startX = Math.max(...vfStaves.map((v) => v.stave.getNoteStartX()));
      for (const v of vfStaves) { v.stave.setNoteStartX(startX); v.stave.draw(); }
      if (k === 0 && staves.length > 1) {
        new VF.StaveConnector(vfStaves[0].stave, vfStaves[vfStaves.length - 1].stave).setType('singleLeft').setContext(ctx).draw();
      }
      if (staves.length > 1) {
        new VF.StaveConnector(vfStaves[0].stave, vfStaves[vfStaves.length - 1].stave).setType('singleRight').setContext(ctx).draw();
      }
      if (k === 0) {
        // braces for multi-staff parts
        let i = 0;
        while (i < vfStaves.length) {
          let j = i;
          while (j + 1 < vfStaves.length && vfStaves[j + 1].s.pi === vfStaves[i].s.pi) j++;
          if (j > i) new VF.StaveConnector(vfStaves[i].stave, vfStaves[j].stave).setType('brace').setContext(ctx).draw();
          i = j + 1;
        }
      }
      // notes
      const allVoices = [];
      const perStave = [];
      const formatter = new VF.Formatter();
      for (const v of vfStaves) {
        const evs = score.events(v.s.pi, mi).filter((e) => e.staff === v.s.staff && !e.grace);
        const top = clefTop(v.clef);
        const shownTop = top; // pitch already written as notated
        const voices = {};
        for (const e of evs) (voices[e.voice] ||= []).push(e);
        const vkeys = Object.keys(voices).sort((a, b) => +a - +b);
        // display accidentals per staff
        const measAlter = {};
        const order = [...evs].sort((a, b) => a.onset - b.onset);
        const accFor = new Map();
        for (const e of order) {
          if (e.rest) continue;
          for (const c of e.chord) {
            const key = c.pitch.step + c.pitch.octave;
            const cur = key in measAlter ? measAlter[key] : keyAlter(v.a.fifths, c.pitch.step);
            const al = c.pitch.alter || 0;
            const explicit = c.el.querySelector(':scope > accidental');
            if (al !== cur || explicit) accFor.set(c.el, ACC[al] ?? null);
            measAlter[key] = al;
          }
        }
        const vfVoices = [];
        vkeys.forEach((vk, vi) => {
          const tickables = [];
          const stem = vkeys.length > 1 ? (vi === 0 ? 1 : -1) : undefined;
          let lastClef = clefKey(v.clef);
          for (const e of voices[vk]) {
            const ck = clefKey(e.clef);
            if (ck !== lastClef && !e.hidden) {
              try { tickables.push(new VF.ClefNote(VF_CLEF[ck] || 'treble', 'small')); } catch (err) { /* ignore */ }
              lastClef = ck;
            }
            const eclef = e.clef || v.clef;
            const eTop = clefTop(eclef);
            let type = e.type, dots = e.dots;
            if (!type || !VF_DUR[type]) { [type, dots] = durFromQl((e.dur / e.div) * (e.tuplet ? e.tuplet.actual / e.tuplet.normal : 1)); }
            let dur = VF_DUR[type] || 'q';
            if (e.hidden) {
              const g = new VF.GhostNote({ duration: dur, dots });
              tickables.push(g);
              layout.notes.push({ ev: e, vf: g, stave: v.stave, top: eTop, clef: eclef, rowIdx: ri, staffIdx: staves.indexOf(v.s), ghost: true });
              continue;
            }
            let note;
            const vfClef = VF_CLEF[ck] || 'treble';
            if (e.rest) {
              let idx = eTop - 4;
              if (vkeys.length > 1) idx += vi === 0 ? 2 : -2;
              if (e.measureRest || (type === 'whole' && e.dur >= score.measureLength(v.s.pi, mi) - 1e-6)) idx = eTop - 2;
              const key = `${STEPS[((idx % 7) + 7) % 7].toLowerCase()}/${Math.floor(idx / 7)}`;
              note = new VF.StaveNote({ keys: [key], duration: dur + 'r', dots, clef: vfClef });
            } else {
              const members = [...e.chord].sort((a, b) => midiOf(a.pitch) - midiOf(b.pitch));
              const keys = members.map((c) => `${c.pitch.step.toLowerCase()}/${c.pitch.octave - (eclef.octaveChange || 0)}`);
              const opt = { keys, duration: dur, dots, clef: vfClef, auto_stem: stem === undefined };
              if (stem !== undefined) opt.stem_direction = stem;
              note = new VF.StaveNote(opt);
              members.forEach((c, i) => {
                const a = accFor.get(c.el);
                if (a) note.addModifier(new VF.Accidental(a), i);
              });
            }
            if (dots) { try { VF.Dot.buildAndAttach([note], { all: true }); } catch (err) { /* older API */ } }
            const isSel = selNote && (selNote === e.el || e.chord.some((c) => c.el === selNote));
            if (isSel) note.setStyle({ fillStyle: '#2563eb', strokeStyle: '#2563eb' });
            tickables.push(note);
            layout.notes.push({ ev: e, vf: note, stave: v.stave, top: eTop, clef: eclef, rowIdx: ri, staffIdx: staves.indexOf(v.s) });
          }
          if (!tickables.length) return;
          const voice = new VF.Voice({ num_beats: v.a.beats, beat_value: v.a.beatType }).setMode(VF.Voice.Mode.SOFT);
          voice.addTickables(tickables);
          vfVoices.push({ voice, tickables, stem });
        });
        if (!vfVoices.length) {
          const g = new VF.Voice({ num_beats: v.a.beats, beat_value: v.a.beatType }).setMode(VF.Voice.Mode.SOFT);
          g.addTickables([new VF.GhostNote({ duration: 'w' })]);
          vfVoices.push({ voice: g, tickables: [], stem: undefined });
        }
        formatter.joinVoices(vfVoices.map((x) => x.voice));
        allVoices.push(...vfVoices.map((x) => x.voice));
        perStave.push({ v, vfVoices });
        layout.staves.push({ mi, pi: v.s.pi, staff: v.s.staff, stave: v.stave, top: v.stave.getYForLine(0), clef: v.clef, fifths: v.a.fifths, rowIdx: ri, staffIdx: staves.indexOf(v.s), x0: x, x1: x + w });
      }
      const avail = Math.max(30, x + w - startX - 14);
      try { formatter.format(allVoices, avail); } catch (err) { console.warn('format', err); }
      for (const { v, vfVoices } of perStave) {
        for (const { voice, tickables, stem } of vfVoices) {
          let beams = [];
          try {
            const beamable = tickables.filter((t) => t instanceof VF.StaveNote);
            beams = VF.Beam.generateBeams(beamable, { groups: [new VF.Fraction(v.a.beatType >= 8 && v.a.beats % 3 === 0 ? 3 : 1, v.a.beatType >= 8 && v.a.beats % 3 === 0 ? 8 : 4)], stem_direction: stem, beam_rests: false, maintain_stem_directions: stem !== undefined });
          } catch (err) { beams = []; }
          try { voice.draw(ctx, v.stave); } catch (err) { console.warn('draw', err); }
          for (const b of beams) { try { b.setContext(ctx).draw(); } catch (err) { /* ignore */ } }
        }
      }
      // measure overlays (drawn into the background group so they sit under the music)
      const top = y0 + ROW_PAD_TOP - 30 + vfStaves[0].stave.getYForLine(0) - vfStaves[0].stave.getY() - 14;
      const bottom = vfStaves[vfStaves.length - 1].stave.getYForLine(4) + 14;
      const info = { mi, x0: x, x1: x + w, y0: top, y1: bottom, rowIdx: ri };
      rowInfo.measures.push(info);
      layout.measures[mi] = info;
      const level = meta[mi]?.level;
      const problems = staves.some((s) => score.measureProblems(s.pi, mi).over);
      const mk = (tag, attrs) => { const r = document.createElementNS('http://www.w3.org/2000/svg', tag); for (const [a, b] of Object.entries(attrs)) r.setAttribute(a, b); bg.appendChild(r); return r; };
      if (sel.has(mi)) mk('rect', { x: x + 1, y: top, width: w - 2, height: bottom - top, fill: '#3b82f6', 'fill-opacity': '0.10', stroke: '#3b82f6', 'stroke-width': 1.5, rx: 4 });
      else if (level === 'bad') mk('rect', { x: x + 1, y: top, width: w - 2, height: bottom - top, fill: '#ef4444', 'fill-opacity': '0.10', rx: 4 });
      else if (level === 'check') mk('rect', { x: x + 1, y: top, width: w - 2, height: bottom - top, fill: '#f59e0b', 'fill-opacity': '0.12', rx: 4 });
      if (playing === mi) mk('rect', { x: x + 1, y: top, width: w - 2, height: bottom - top, fill: '#10b981', 'fill-opacity': '0.16', rx: 4 });
      if (problems) mk('rect', { x: x + 2, y: top + 1, width: w - 4, height: bottom - top - 2, fill: 'none', stroke: '#dc2626', 'stroke-dasharray': '5 4', 'stroke-width': 1.5, rx: 4 });
      const num = score.parts[0].measures[mi]?.getAttribute('number') ?? String(mi + 1);
      const t = mk('text', { x: x + 4, y: top - 3, 'font-size': 11, fill: level === 'bad' ? '#b91c1c' : level === 'check' ? '#b45309' : '#6b7280', 'font-family': 'system-ui, sans-serif', class: 'ms-num' });
      t.textContent = num + (level === 'bad' ? '  ⚠' : level === 'check' ? '  ?' : '') + (problems ? '  too long' : '');
      x += w;
    });
    layout.rows.push(rowInfo);
  });
  return layout;
}

// pitch under a point on a stave
export function pitchAtY(st, y, fifths) {
  const steps = Math.round((y - st.top) / 5);
  const idx = clefTop(st.clef) - steps;
  const octave = Math.floor(idx / 7), step = STEPS[((idx % 7) + 7) % 7];
  return { pitch: { step, octave, alter: keyAlter(fifths, step) }, y: st.top + steps * 5, steps };
}

export function noteYs(n) {
  // y of each chord member's notehead
  return n.ev.chord.map((c) => {
    const idx = (c.pitch.octave - (n.clef.octaveChange || 0)) * 7 + STEPS.indexOf(c.pitch.step);
    return { el: c.el, pitch: c.pitch, y: n.stave.getYForLine(0) + (clefTop({ ...n.clef, octaveChange: 0 }) - idx) * 5 };
  });
}
