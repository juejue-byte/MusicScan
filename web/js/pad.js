// On-screen note input for iPad and phones (and anyone without a keyboard handy): a two-octave piano under the score
// while note input is on, like the virtual keyboards in the familiar web notation editors. A key writes that exact
// pitch at the caret; Chord adds it to the last note instead. Rest, Repeat, ⌫ and ◀ ▶ mirror 0, R, Backspace and ←→.
import { STEPS, keyAlter, midiOf } from './score.js';

const $ = (s) => document.querySelector(s);
const WHITE = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
const BLACK_AFTER = { C: 1, D: 1, F: 1, G: 1, A: 1 };   // a black key follows these white keys
const LS = 'musicscan:pad';

export function createPad(NI, { S, setDur, makeRest, stepSel, del }) {
  const st = { base: null, staff: null, chord: false, open: true, openSelect: false };
  // open by default on touch screens; with a mouse and keyboard it waits behind the Keyboard button
  st.open = matchMedia('(pointer: coarse)').matches;
  try { const v = localStorage.getItem(LS); if (v) st.open = v === 'open'; st.openSelect = localStorage.getItem(LS + ':select') === 'open'; } catch (e) { /* storage blocked */ }

  const el = document.createElement('div');
  el.className = 'pad hidden';
  el.id = 'notePad';
  el.innerHTML = `
    <div class="pad-side">
      <button class="pad-btn" data-p="oct-" title="Lower octave" aria-label="Lower octave">‹ 8va</button>
      <button class="pad-btn" data-p="oct+" title="Higher octave" aria-label="Higher octave">8va ›</button>
    </div>
    <div class="pad-keys" role="group" aria-label="Piano keyboard"></div>
    <div class="pad-side pad-actions">
      <button class="pad-btn" data-p="chord" aria-pressed="false" title="Keys add to the last note (a chord)">+ Chord</button>
      <button class="pad-btn" data-p="voice" aria-pressed="false" title="Write a second melody on this staff (voice 2, ⌘⌥2)">Voice 2</button>
      <button class="pad-btn" data-p="rest" title="Write a rest (0)">𝄽 Rest</button>
      <button class="pad-btn" data-p="repeat" title="Repeat the last note (R)">⟳ Repeat</button>
      <button class="pad-btn" data-p="left" title="Move the caret back (←)" aria-label="Caret back">◀</button>
      <button class="pad-btn" data-p="right" title="Move the caret on (→)" aria-label="Caret forward">▶</button>
      <button class="pad-btn" data-p="back" title="Step back and clear (Backspace)" aria-label="Step back and clear">⌫</button>
      <button class="pad-btn pad-staff" data-p="staff" title="Write on the other staff (⌥⇧↑↓)">Bass ⇣</button>
    </div>
    <button class="pad-hide" data-p="hide" title="Hide the keyboard" aria-label="Hide the keyboard">⌄</button>`;
  const statusbar = document.querySelector('.statusbar');
  statusbar.parentNode.insertBefore(el, statusbar);
  const show = document.createElement('button');
  show.className = 'btn small ghost pad-show hidden';
  show.id = 'btnPad';
  show.textContent = '🎹 Keyboard';
  show.title = 'Show the on-screen keyboard';
  statusbar.insertBefore(show, statusbar.querySelector('.zoom'));
  show.onclick = () => { setOpen(true); };
  const isOpen = () => (S.mode === 'add' ? st.open : st.openSelect);
  function setOpen(v) { if (S.mode === 'add') st.open = v; else st.openSelect = v; save(); sync(); }

  function save() { try { localStorage.setItem(LS, st.open ? 'open' : 'closed'); localStorage.setItem(LS + ':select', st.openSelect ? 'open' : 'closed'); } catch (e) { /* ignore */ } }

  // the keys, for octaves base and base+1 plus the top C
  function build() {
    const keys = el.querySelector('.pad-keys');
    const ctx = NI.context();
    const fifths = ctx?.fifths ?? 0;
    keys.innerHTML = '';
    const whites = [];
    for (let o = st.base; o <= st.base + 1; o++) for (const s of WHITE) whites.push({ step: s, octave: o });
    whites.push({ step: 'C', octave: st.base + 2 });
    const n = whites.length;
    whites.forEach((w, i) => {
      const b = document.createElement('button');
      b.className = 'pk white' + (w.step === 'C' ? ' c' : '');
      b.style.left = `calc(${(i / n) * 100}% )`;
      b.style.width = `calc(${100 / n}% - 2px)`;
      const p = { step: w.step, octave: w.octave, alter: 0 };
      b.dataset.midi = midiOf(p);
      b.innerHTML = `<span>${w.step}${w.step === 'C' ? w.octave : ''}</span>`;
      b.onclick = () => hit(p);
      keys.appendChild(b);
      if (BLACK_AFTER[w.step] && i < n - 1) {
        // spelled the way the key signature leans: sharps, or flats in flat keys
        const up = { step: w.step, octave: w.octave, alter: 1 };
        const nextStep = STEPS[(STEPS.indexOf(w.step) + 1) % 7];
        const down = { step: nextStep, octave: w.octave, alter: -1 };
        const sp = fifths < 0 || keyAlter(fifths, nextStep) === -1 ? down : up;
        const k = document.createElement('button');
        k.className = 'pk black';
        k.style.left = `calc(${((i + 1) / n) * 100}% - ${100 / n / 3}%)`;
        k.style.width = `calc(${100 / n / 1.5}%)`;
        k.dataset.midi = midiOf(sp);
        k.setAttribute('aria-label', `${sp.step}${sp.alter > 0 ? ' sharp' : ' flat'} ${sp.octave}`);
        k.onclick = () => hit(sp);
        keys.appendChild(k);
      }
    });
    mark();
  }
  // note input: write at the caret. Select: the selected note takes this pitch (Chord adds it instead)
  function hit(p) {
    if (S.mode === 'add' || st.chord) NI.writePitch({ ...p }, st.chord);
    else NI.setSelectedPitch({ ...p });
  }
  // light up the keys of the selected note
  function mark() {
    const s = S.sel && S.layout?.notes.find((n) => n.ev.el === S.sel || n.ev.chord.some((c) => c.el === S.sel));
    const on = new Set(s && !s.ev.rest ? s.ev.chord.map((c) => midiOf(c.pitch)) : []);
    for (const k of el.querySelectorAll('.pk')) k.classList.toggle('on', on.has(+k.dataset.midi));
  }

  function sync() {
    const active = (S.mode === 'add' || S.mode === 'select') && !!S.score && !document.querySelector('#viewEditor')?.classList.contains('hidden');
    const open = isOpen();
    el.classList.toggle('hidden', !active || !open);
    show.classList.toggle('hidden', !active || open);
    document.body.classList.toggle('pad-open', active && open);
    el.dataset.mode = S.mode;
    if (!active || !open) return;
    const ctx = NI.context();
    if (!ctx) return;
    // follow the staff: the note before the caret sits near the middle of the keyboard
    if (st.staff !== ctx.staff || st.base === null) {
      st.staff = ctx.staff;
      st.base = Math.max(1, Math.min(6, Math.round((ctx.ref.octave * 7 + STEPS.indexOf(ctx.ref.step) - 7) / 7)));
      build();
    } else mark();
    el.querySelector('[data-p="chord"]').setAttribute('aria-pressed', String(st.chord));
    // piano: one tap switches between the treble and bass staff
    const sb = el.querySelector('[data-p="staff"]');
    const nStaves = S.caret ? S.score.attrs(S.caret.pi, Math.min(S.caret.mi, S.score.nMeasures - 1)).staves || 1 : 1;
    sb.classList.toggle('hidden', nStaves < 2);
    const sel = S.mode !== 'add' && S.sel ? S.layout?.notes.find((n) => n.ev.el === S.sel || n.ev.chord.some((c) => c.el === S.sel)) : null;
    const onStaff = S.mode === 'add' ? S.caret?.staff : sel?.ev.staff;
    sb.textContent = S.mode === 'add' ? (onStaff === '1' ? 'Lower ⇣' : 'Upper ⇡') : (onStaff === '1' ? 'Move ⇣' : 'Move ⇡');
    sb.title = S.mode === 'add' ? 'Write on the other staff (⌥⇧↑↓)' : 'Move the note to the other staff (⌘⇧↑↓)';
    el.querySelector('[data-p="left"]').title = S.mode === 'add' ? 'Move the caret back (←)' : 'Previous note (←)';
    el.querySelector('[data-p="right"]').title = S.mode === 'add' ? 'Move the caret on (→)' : 'Next note (→)';
    el.querySelector('[data-p="back"]').title = S.mode === 'add' ? 'Step back and clear (Backspace)' : 'Delete the note (Delete)';
    el.querySelector('[data-p="voice"]').setAttribute('aria-pressed', String((S.caret?.vk || 1) > 1));
  }

  el.addEventListener('click', (e) => {
    const b = e.target.closest('[data-p]');
    if (!b) return;
    e.stopPropagation();
    const a = b.dataset.p;
    if (a === 'oct-') { st.base = Math.max(0, st.base - 1); build(); }
    else if (a === 'oct+') { st.base = Math.min(7, st.base + 1); build(); }
    else if (a === 'staff') {
      if (S.mode === 'add') { const c = S.caret; NI.changeStaff(c && c.staff !== '1' ? -1 : 1); }
      else { const n = S.sel && S.layout?.notes.find((q) => q.ev.el === S.sel || q.ev.chord.some((c) => c.el === S.sel)); NI.moveToStaff(n && n.ev.staff !== '1' ? -1 : 1); }
    }
    else if (a === 'chord') { st.chord = !st.chord; sync(); }
    else if (a === 'voice') NI.setVoice((S.caret?.vk || 1) > 1 ? 1 : 2);
    else if (S.mode !== 'add' && a === 'rest') makeRest();
    else if (S.mode !== 'add' && (a === 'left' || a === 'right')) stepSel(a === 'left' ? -1 : 1);
    else if (S.mode !== 'add' && a === 'back') del();
    else if (a === 'rest') NI.write(null);
    else if (a === 'repeat') NI.repeat();
    else if (a === 'left') NI.moveCaret(-1);
    else if (a === 'right') NI.moveCaret(1);
    else if (a === 'back') NI.backspace();
    else if (a === 'hide') setOpen(false);
  });
  // keys must not steal focus or start a page zoom on double tap
  el.addEventListener('pointerdown', (e) => { if (e.target.closest('button')) e.preventDefault(); });

  return { sync, state: st };
}
