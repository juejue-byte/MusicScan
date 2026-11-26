// MusicScan web app: upload -> transcribe -> edit on the staff -> play -> export.
import { Score, pitchName, midiOf, clefTop, toMidi } from './score.js';
import { render, pitchAtY, noteYs } from './render.js';
import * as audio from './audio.js';
import * as native from './native.js';
import { api, jobFile, isDemo } from './demo.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const SVGNS = 'http://www.w3.org/2000/svg';
const LS_KEY = 'musicscan:last';

const S = {
  score: null, meta: [], job: null, result: null, name: '',
  mode: 'select', dur: 'quarter', dot: false,
  sel: null,                 // selected note/rest element (a <note>)
  measures: new Set(),       // selected bars (for rescan / playback start)
  focus: -1,                 // bar shown in the photo inspector
  undo: [], redo: [], layout: null, drag: null, photo: 'page',
  zoom: window.innerWidth < 600 ? 0.72 : 1,
};

// ---------------------------------------------------------------- helpers
function toast(msg, ms = 2600) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add('hidden'), ms);
}
function show(view) {
  for (const v of ['viewUpload', 'viewProgress', 'viewEditor']) $('#' + v).classList.toggle('hidden', v !== view);
  const editing = view === 'viewEditor';
  document.body.classList.toggle('editing', editing);
  for (const b of ['#btnPlay', '#btnExport']) $(b).disabled = !editing;
  $('.top-actions').classList.toggle('hidden', !editing);
  if (!editing) $('#docTitle').textContent = '';
  updateUndoButtons();
}
function download(name, data, type) {
  const blob = data instanceof Blob ? data : new Blob([data], { type });
  if (native.isNative) { native.share(name, blob).catch((e) => toast('Could not share the file: ' + e.message)); return; }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
const baseName = () => (S.name || 'score').replace(/\.[^.]+$/, '').replace(/[^\w\- ]+/g, '').trim() || 'score';
function saveLocal() {
  try { localStorage.setItem(LS_KEY, JSON.stringify({ job: S.job, xml: S.score.toXML(), meta: S.meta, name: S.name, result: S.result ? { quality: S.result.quality, page_size: S.result.page_size, systems: S.result.systems } : null, t: Date.now() })); } catch (e) { /* storage full or blocked */ }
}

// ---------------------------------------------------------------- upload flow
async function startUpload(file) {
  if (!file) return;
  S.name = file.name || 'photo.jpg';
  const lower = S.name.toLowerCase();
  if (lower.endsWith('.musicxml') || lower.endsWith('.xml')) {
    const text = await file.text();
    try { openScore(text, [], null, null); toast('Opened ' + S.name); } catch (e) { toast(e.message); }
    return;
  }
  if (lower.endsWith('.mxl')) { toast('Compressed .mxl is not supported yet. Export uncompressed MusicXML.'); return; }
  show('viewProgress');
  const thumb = $('#progressThumb');
  if (file.type.startsWith('image/') && !/heic|heif/i.test(file.type + lower)) { thumb.src = URL.createObjectURL(file); thumb.classList.remove('hidden'); } else thumb.classList.add('hidden');
  setStep('upload');
  const fast = $('#optFast').checked;
  const fd = new FormData();
  fd.append('file', file, S.name);
  fd.append('detector', fast ? '2m' : '28m');
  const t0 = Date.now();
  const expected = fast ? 6 : 18;
  const tick = setInterval(() => {
    const p = Math.min(95, ((Date.now() - t0) / 1000 / expected) * 100);
    $('#progressBar').style.width = p + '%';
  }, 300);
  try {
    const r = await api('api/jobs', { method: 'POST', body: fd });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Upload failed');
    const { id } = await r.json();
    S.job = id;
    for (;;) {
      await new Promise((res) => setTimeout(res, 700));
      const j = await (await api('api/jobs/' + id)).json();
      if (j.status === 'done') { setStep('done'); clearInterval(tick); $('#progressBar').style.width = '100%'; openResult(j.result); return; }
      if (j.status === 'error') throw new Error(j.error || 'Transcription failed');
      setStep(/Clean/.test(j.status) ? 'clean' : /Read|Double/.test(j.status) ? 'read' : 'upload');
      $('#progressText').textContent = `${j.status}… ${Math.round((Date.now() - t0) / 1000)} s`;
    }
  } catch (e) {
    clearInterval(tick);
    show('viewUpload');
    toast('Sorry, that did not work: ' + e.message, 5000);
  }
}
function setStep(s) {
  const order = ['upload', 'clean', 'read', 'done'];
  const k = order.indexOf(s);
  for (const el of $$('.step')) {
    const i = order.indexOf(el.dataset.s);
    el.classList.toggle('done', i < k);
    el.classList.toggle('active', i === k);
  }
}

function openResult(res) {
  if (!res.stats?.measures) {
    show('viewUpload');
    const card = $('#modalCard');
    $('#modal').classList.remove('hidden');
    card.innerHTML = `<h2>No music found in this photo</h2>
      <p class="muted">We couldn't find any staff lines. Make sure the page is printed sheet music, fills most of the frame, and is in focus, then try again.</p>
      <div class="modal-actions"><button class="btn primary" data-m="close">Try another photo</button></div>`;
    card.onclick = (ev) => { if (ev.target.closest('[data-m]')) closeModal(); };
    return;
  }
  S.result = res;
  openScore(res.xml, res.measures, res.quality, S.job);
}

function openScore(xml, meta, quality, job) {
  S.score = new Score(xml);
  S.meta = (meta || []).map((m) => ({ ...m }));
  S.job = job;
  S.sel = null; S.measures = new Set(); S.focus = -1; S.undo = []; S.redo = [];
  $('#docTitle').textContent = S.name;
  show('viewEditor');
  renderBanner(quality);
  setupPhoto();
  setMode('select');
  $('#tempo').value = Math.round(S.score.tempo());
  redraw();
  saveLocal();
  if (job) setTimeout(() => { const firstBad = S.meta.findIndex((m) => m.level === 'bad'); if (firstBad >= 0) focusBar(firstBad, false); }, 50);
}

// why a bar is marked, in words
function barReason(m) {
  if (m.level === 'ok') return 'read with confidence';
  const r = [];
  if (m.disagree) r.push('a second reading disagrees');
  if (m.low_n) r.push(`${m.low_n} uncertain symbol${m.low_n === 1 ? '' : 's'}`);
  if (m.fixes?.length) r.push('timing was repaired');
  if (!r.length) r.push(m.n ? 'low confidence' : 'nothing was read here');
  return r.join(' · ');
}

function renderBanner(q) {
  const b = $('#qualityBanner');
  if (!q) { b.classList.add('hidden'); return; }
  const flagged = S.meta.filter((m) => m.level !== 'ok').length;
  const red = S.meta.filter((m) => m.level === 'bad').length;
  const icon = { good: '✓', check: '!', retake: '⚠' }[q.level];
  const title = {
    good: flagged ? `Photo looks good. ${red ? `${red} bar${red > 1 ? 's' : ''} likely wrong (red)` : 'No bars likely wrong'}, ${flagged - red} to glance at (amber).` : 'Photo looks good. Every bar was read with confidence.',
    check: `Parts of this photo were hard to read. Check the highlighted bars (${flagged}).`,
    retake: 'This photo is low quality, so the transcription is likely to have many mistakes.',
  }[q.level];
  b.className = 'banner ' + q.level;
  b.innerHTML = `<div class="b-icon">${icon}</div><div class="b-body"><div class="b-title"></div>${q.reasons.length ? '<ul></ul>' : ''}</div>
    <div class="b-actions">${q.level !== 'good' ? '<button class="btn small" data-b="retake">Retake photo</button>' : ''}<button class="btn small ghost" data-b="close">✕</button></div>`;
  b.querySelector('.b-title').textContent = `${title} (quality ${q.score}/100)`;
  const ul = b.querySelector('ul');
  if (ul) for (const r of q.reasons) { const li = document.createElement('li'); li.textContent = r; ul.appendChild(li); }
  b.onclick = (e) => {
    const a = e.target.closest('[data-b]')?.dataset.b;
    if (a === 'close') b.classList.add('hidden');
    if (a === 'retake') { audio.stop(); show('viewUpload'); }
  };
}

// ---------------------------------------------------------------- drawing
function scoreWidth() { return $('#scoreScroll').clientWidth - 4; }

function redraw() {
  if (!S.score) return;
  const el = $('#score');
  const keep = $('#scoreScroll').scrollTop;
  S.layout = render(S.score, el, { width: scoreWidth(), zoom: S.zoom, selected: S.measures, selectedNote: S.sel, meta: S.meta });
  const ov = $('#overlay');
  ov.setAttribute('width', S.layout.pxWidth);
  ov.setAttribute('height', S.layout.height * S.zoom);
  ov.setAttribute('viewBox', `0 0 ${S.layout.width} ${S.layout.height}`);
  $('#zoomVal').textContent = Math.round(S.zoom * 100) + '%';
  ov.style.top = el.offsetTop + 'px';
  $('#scoreScroll').scrollTop = keep;
  el.classList.toggle('mode-add', S.mode === 'add');
  drawPhotoOverlay();
  updateToolbar();
  updateStatus();
  updateUndoButtons();
  $('#btnRescan').disabled = !S.job || targetBars().length === 0;
}

function updateUndoButtons() {
  $('#btnUndo').disabled = !S.undo.length || $('#viewEditor').classList.contains('hidden');
  $('#btnRedo').disabled = !S.redo.length || $('#viewEditor').classList.contains('hidden');
}

function selEvent() {
  if (!S.sel || !S.layout) return null;
  const n = S.layout.notes.find((n) => n.ev.el === S.sel || n.ev.chord.some((c) => c.el === S.sel));
  return n || null;
}

function updateToolbar() {
  const n = S.mode === 'add' ? null : selEvent();
  const dur = n && !n.ghost ? n.ev.type : S.dur;
  const dot = n && !n.ghost ? n.ev.dots > 0 : S.dot;
  for (const b of $$('[data-dur]')) b.classList.toggle('on', b.dataset.dur === dur);
  $('[data-act="dot"]').classList.toggle('on', !!dot);
  const member = n && n.ev.chord.find((c) => c.el === S.sel);
  for (const b of $$('[data-acc]')) b.classList.toggle('on', !!member && (member.pitch.alter || 0) === +b.dataset.acc && !!member.el.querySelector(':scope > accidental, :scope > pitch > alter'));
}

function updateStatus() {
  const n = selEvent();
  const st = $('#status');
  const over = [];
  for (let mi = 0; mi < S.score.nMeasures; mi++) if (S.score.parts.some((p, pi) => S.score.measureProblems(pi, mi).over)) over.push(mi);
  let txt = '';
  if (n) {
    const num = barNumber(n.ev.mi);
    const what = n.ev.rest ? `${n.ev.type || ''} rest` : n.ev.chord.map((c) => pitchName(c.pitch)).join(' + ') + ` · ${n.ev.type || ''}${n.ev.dots ? ' dotted' : ''}`;
    const keys = S.touch ? 'Drag up/down for pitch, sideways to swap' : '↑↓ pitch · Shift+↑↓ octave · 1–6 duration · R rest · Del delete';
    txt = `Bar ${num} · staff ${n.ev.staff} · ${what}.  ${keys}`;
  } else if (S.measures.size) {
    txt = `${S.measures.size} bar${S.measures.size > 1 ? 's' : ''} selected. Rescan re-reads them from the photo; Play starts here.`;
  } else txt = `${S.score.nMeasures} bars · ${S.score.parts.length} part${S.score.parts.length > 1 ? 's' : ''}`;
  if (over.length) txt += `  ·  ⚠ ${over.length} bar${over.length > 1 ? 's are' : ' is'} too long (${over.map(barNumber).slice(0, 6).join(', ')})`;
  st.textContent = txt;
}
const barNumber = (mi) => S.score.parts[0].measures[mi]?.getAttribute('number') ?? String(mi + 1);

// ---------------------------------------------------------------- undo
function snapshot() { return { xml: S.score.toXML(), meta: JSON.stringify(S.meta) }; }
function restore(s) {
  const pathOfSel = selPath();
  S.score = new Score(s.xml);
  S.meta = JSON.parse(s.meta);
  S.sel = elFromPath(pathOfSel);
  redraw();
  saveLocal();
}
function edit(fn, { keepRedo = false } = {}) {
  S.undo.push(snapshot());
  if (S.undo.length > 200) S.undo.shift();
  if (!keepRedo) S.redo = [];
  try { fn(); } catch (e) { console.error(e); toast('That edit did not work: ' + e.message); }
  redraw();
  saveLocal();
}
function undo() { if (!S.undo.length) return; S.redo.push(snapshot()); restore(S.undo.pop()); }
function redo() { if (!S.redo.length) return; S.undo.push(snapshot()); restore(S.redo.pop()); }
// keep a selection across undo by remembering where the note sat
function selPath() {
  if (!S.sel) return null;
  const m = S.sel.closest('measure'), p = m?.closest('part');
  if (!m || !p) return null;
  return { part: p.getAttribute('id'), mi: [...p.querySelectorAll(':scope > measure')].indexOf(m), idx: [...m.querySelectorAll(':scope > note')].indexOf(S.sel) };
}
function elFromPath(path) {
  if (!path) return null;
  const p = S.score.parts.find((x) => x.id === path.part);
  return p?.measures[path.mi]?.querySelectorAll(':scope > note')[path.idx] || null;
}

// ---------------------------------------------------------------- hit testing
function localPoint(e) {
  const r = S.layout.svg.getBoundingClientRect();
  return { x: (e.clientX - r.left) * (S.layout.width / r.width), y: (e.clientY - r.top) * (S.layout.height / r.height) };
}
function noteX(n) {
  try { return n.vf.getAbsoluteX() + (n.ghost ? 0 : 6); } catch (e) { return 0; }
}
function restY(n) {
  try { const bb = n.vf.getBoundingBox(); return bb.getY() + bb.getH() / 2; } catch (e) { return n.stave.getYForLine(2); }
}
function staveAt(x, y) {
  let best = null, bd = 1e9;
  for (const st of S.layout.staves) {
    if (x < st.x0 || x > st.x1) continue;
    const mid = st.top + 20;
    const d = Math.abs(y - mid);
    if (d < 70 && d < bd) { bd = d; best = st; }
  }
  return best;
}
function notesIn(st) {
  return S.layout.notes.filter((n) => n.ev.mi === st.mi && n.ev.pi === st.pi && n.ev.staff === st.staff).sort((a, b) => noteX(a) - noteX(b));
}
// fingers are less precise than a mouse: widen the hit area while the last pointer was a touch
const TOUCH = { dx: 24, dy: 14, rest: 22 };
function hitTest(x, y, touch = S.touch) {
  for (const m of S.layout.measures) if (m && x >= m.x0 && x <= m.x1 && y >= m.y0 - 16 && y < m.y0 + 2) return { type: 'num', mi: m.mi };
  const st = staveAt(x, y);
  if (!st) return null;
  const notes = notesIn(st);
  let best = null, bd = 1e9;
  for (const n of notes) {
    if (n.ghost) continue;
    const dx = Math.abs(x - noteX(n));
    if (dx > (touch ? TOUCH.dx : 16)) continue;
    const ys = n.ev.rest ? [{ el: n.ev.el, y: restY(n) }] : noteYs(n);
    for (const m of ys) {
      const dy = Math.abs(y - m.y);
      const d = Math.hypot(dx, dy * 1.3);
      if (dy < (n.ev.rest ? (touch ? TOUCH.rest : 16) : (touch ? TOUCH.dy : 8)) && d < bd) { bd = d; best = { n, member: m.el, my: m.y }; }
    }
  }
  if (best) return { type: 'note', st, ...best };
  return { type: 'staff', st, notes };
}

// where a click on empty staff would put a note
function placementAt(st, notes, x) {
  if (!notes.length) return { where: 'empty' };
  const xs = notes.map(noteX);
  for (let i = 0; i < notes.length; i++) {
    const n = notes[i];
    const x0 = xs[i] - 14, x1 = i + 1 < notes.length ? xs[i + 1] - 14 : st.x1;
    if (n.ev.rest && x >= x0 && x < x1) return { where: 'at', n, x: xs[i] };
  }
  let prev = null;
  for (let i = 0; i < notes.length; i++) if (xs[i] < x && !notes[i].ghost) prev = i;
  if (prev === null) return { where: 'before', n: notes.find((n) => !n.ghost) || notes[0], x: Math.max(st.x0 + 10, xs[0] - 18) };
  return { where: 'after', n: notes[prev], x: xs[prev] + 22 };
}

function staffPitch(st, y, x) {
  // clef can change mid-bar: use the clef of the closest event
  const notes = notesIn(st);
  let clef = st.clef;
  if (notes.length && x !== undefined) {
    let bestN = notes[0];
    for (const n of notes) if (Math.abs(noteX(n) - x) < Math.abs(noteX(bestN) - x)) bestN = n;
    clef = bestN.clef || clef;
  }
  return pitchAtY({ ...st, clef, top: st.top }, y, st.fifths);
}

// ---------------------------------------------------------------- pointer interaction
function onPointerDown(e) {
  if (!S.layout || e.button > 0) return;
  S.touch = e.pointerType === 'touch' || e.pointerType === 'pen';
  audio.audioCtx();
  const { x, y } = localPoint(e);
  const h = hitTest(x, y);
  // touch in Add mode: the ghost note follows the finger and the note is written when the finger lifts
  if (S.touch && S.mode === 'add' && h && (h.type === 'staff' || (h.type === 'note' && h.n.ev.rest))) {
    S.drag = { addTouch: true, x, y, startX: e.clientX, startY: e.clientY, pointer: e.pointerId };
    $('#score').setPointerCapture(e.pointerId);
    drawGhost(x, y);
    native.haptic('light');
    e.preventDefault();
    return;
  }
  if (!h) { S.sel = null; S.measures.clear(); redraw(); hideInspector(); return; }
  if (h.type === 'num') { toggleBar(h.mi, e.shiftKey || e.metaKey || e.ctrlKey); return; }
  const addMode = S.mode === 'add';
  if (h.type === 'note' && !(addMode && (e.shiftKey || h.n.ev.rest))) {
    S.sel = h.member;
    S.measures = new Set([h.n.ev.mi]);
    focusBar(h.n.ev.mi, false);
    const ev = h.n.ev;
    if (!ev.rest) {
      const member = ev.chord.find((c) => c.el === h.member);
      audio.preview(midiOf(member.pitch));
      S.drag = { el: h.member, evEl: ev.el, startY: e.clientY, startX: e.clientX, axis: null, steps: 0, orig: member.pitch, origIdx: S.score.diatonic(member.pitch), pushed: false, pointer: e.pointerId };
      $('#score').setPointerCapture(e.pointerId);
    } else {
      S.drag = { el: h.member, evEl: ev.el, startY: e.clientY, startX: e.clientX, axis: null, rest: true, pushed: false };
      $('#score').setPointerCapture(e.pointerId);
    }
    redraw();
    e.preventDefault();
    return;
  }
  if (!addMode) {
    const st = h.st;
    // empty staff in select mode: select the bar
    S.sel = null;
    toggleBar(st.mi, e.shiftKey || e.metaKey || e.ctrlKey, true);
    return;
  }
  addAt(h, x, y, e.shiftKey);
}

// Add mode: write a note (or a chord tone with shift) at a point on the staff
function addAt(h, x, y, shift) {
  const st = h.st;
  const { pitch } = staffPitch(st, y, x);
  if (h.type === 'note' && shift && !h.n.ev.rest) {
    const n = h.n;
    edit(() => S.score.addChordTone(n.ev, pitch));
    S.sel = null;
    audio.preview(midiOf(pitch));
    redraw();
    return;
  }
  // shift-click near a note column adds to the chord
  const near = (h.notes || []).find((n) => !n.ghost && !n.ev.rest && Math.abs(noteX(n) - x) < 9);
  if (near && shift) { edit(() => S.score.addChordTone(near.ev, pitch)); audio.preview(midiOf(pitch)); return; }
  const place = h.type === 'note' && h.n.ev.rest ? { where: 'at', n: h.n } : placementAt(st, h.notes || [], x);
  let created = null;
  edit(() => {
    if (place.where === 'empty') created = S.score.addToEmpty(st.pi, st.mi, st.staff, pitch, S.dur, S.dot ? 1 : 0);
    else created = S.score.placeNote(place.n.ev, pitch, S.dur, S.dot ? 1 : 0, place.where);
  });
  S.sel = created;
  S.measures = new Set([st.mi]);
  audio.preview(midiOf(pitch));
  native.haptic('medium');
  redraw();
}

function onPointerMove(e) {
  if (!S.layout) return;
  const { x, y } = localPoint(e);
  if (S.drag?.addTouch) {
    S.drag.x = x; S.drag.y = y;
    const before = $('#overlay .ghost text')?.textContent;
    drawGhost(x, y, true);
    if ($('#overlay .ghost text')?.textContent !== before) native.haptic('selection');
    return;
  }
  if (S.drag) {
    const dx = e.clientX - S.drag.startX, dy = e.clientY - S.drag.startY;
    if (!S.drag.axis) {
      if (Math.abs(dx) < 7 && Math.abs(dy) < 4) return;
      S.drag.axis = Math.abs(dx) > Math.abs(dy) * 1.5 ? 'x' : (S.drag.rest ? null : 'y');
      if (!S.drag.axis) return;
    }
    if (S.drag.axis === 'x') { dragSideways(x); return; }
    // one staff step per half line-space; a finger gets a little more travel per step so it is easy to hit
    const stepPx = 5 * S.zoom * (S.touch ? 1.6 : 1);
    const steps = Math.round((S.drag.startY - e.clientY) / stepPx);
    if (steps !== S.drag.steps) {
      if (!S.drag.pushed) { S.undo.push(snapshot()); S.redo = []; S.drag.pushed = true; }
      S.drag.steps = steps;
      const n = selEvent();
      if (n) {
        const p = S.score.pitchAt(S.drag.origIdx + steps, S.score.attrs(n.ev.pi, n.ev.mi).fifths);
        S.score.setPitch(S.drag.el, p);
        S.sel = S.drag.el;
        redraw();
        audio.preview(midiOf(p));
        native.haptic('selection');
        drawDragLabel(p, x, y);
      }
    }
    return;
  }
  if (e.pointerType === 'mouse') S.touch = false;
  if (S.mode === 'add') { drawGhost(x, y); return; }
  // hover feedback in select mode
  const h = hitTest(x, y);
  $('#score').style.cursor = h?.type === 'note' ? (h.n.ev.rest ? 'pointer' : 'ns-resize') : h?.type === 'num' ? 'pointer' : h ? 'cell' : 'default';
}

// drag left/right: swap with the neighbour once the pointer passes its middle
function dragSideways(x) {
  const n = S.layout.notes.find((q) => q.ev.el === S.drag.evEl);
  if (!n) return;
  const same = S.layout.notes.filter((q) => !q.ghost && q.ev.mi === n.ev.mi && q.ev.pi === n.ev.pi && q.ev.staff === n.ev.staff && q.ev.voice === n.ev.voice).sort((a, b) => a.ev.onset - b.ev.onset);
  const i = same.indexOf(n);
  const next = same[i + 1], prev = same[i - 1];
  let ok = false;
  const doSwap = (ev) => {
    if (!S.drag.pushed) { S.undo.push(snapshot()); S.redo = []; S.drag.pushed = true; }
    return S.score.swapWithNext(ev);
  };
  if (next && x > noteX(next) - 4) ok = doSwap(n.ev);
  else if (prev && x < noteX(prev) + 4) ok = doSwap(prev.ev);
  if (ok) { redraw(); clearOverlay('drag'); native.haptic('light'); }
}

function onPointerUp(e) {
  if (S.drag?.addTouch) {
    const { x, y } = S.drag;
    S.drag = null;
    clearOverlay('ghost');
    if (e?.type === 'pointercancel') return;
    const h = hitTest(x, y);
    if (h && h.type !== 'num') addAt(h, x, y, false);
    return;
  }
  if (S.drag) {
    if (S.drag.pushed) saveLocal();
    S.drag = null;
    clearOverlay('drag');
  }
}

function clearOverlay(cls) { for (const el of $('#overlay').querySelectorAll('.' + cls)) el.remove(); }

function drawGhost(x, y, finger = false) {
  clearOverlay('ghost');
  const h = hitTest(x, y);
  if (!h || h.type === 'num') return;
  const st = h.st;
  const { pitch, y: sy } = staffPitch(st, y, x);
  const place = h.type === 'note' ? { x: noteX(h.n) } : placementAt(st, h.notes || [], x);
  const gx = place.x ?? x;
  const g = document.createElementNS(SVGNS, 'g');
  g.setAttribute('class', 'ghost');
  // ledger lines
  const top = st.top, bot = st.top + 40;
  for (let ly = top - 10; ly >= sy - 1; ly -= 10) g.appendChild(line(gx - 10, ly, gx + 10, ly));
  for (let ly = bot + 10; ly <= sy + 1; ly += 10) g.appendChild(line(gx - 10, ly, gx + 10, ly));
  const head = document.createElementNS(SVGNS, 'ellipse');
  Object.entries({ cx: gx, cy: sy, rx: 6.2, ry: 4.6, fill: '#2563eb', 'fill-opacity': 0.45, transform: `rotate(-20 ${gx} ${sy})` }).forEach(([k, v]) => head.setAttribute(k, v));
  g.appendChild(head);
  const t = document.createElementNS(SVGNS, 'text');
  Object.entries({ x: gx - 10, y: Math.min(sy, top) - (finger ? 48 : 14), 'font-size': finger ? 16 : 12, fill: '#1e40af', 'font-family': 'system-ui, sans-serif', 'font-weight': 600 }).forEach(([k, v]) => t.setAttribute(k, v));
  t.textContent = pitchName(pitch);
  t.setAttribute('paint-order', 'stroke');
  t.setAttribute('stroke', '#fff');
  t.setAttribute('stroke-width', '4');
  g.appendChild(t);
  $('#overlay').appendChild(g);
}
function line(x1, y1, x2, y2) {
  const l = document.createElementNS(SVGNS, 'line');
  Object.entries({ x1, y1, x2, y2, stroke: '#2563eb', 'stroke-opacity': 0.5, 'stroke-width': 1.2 }).forEach(([k, v]) => l.setAttribute(k, v));
  return l;
}
function drawDragLabel(p, x, y) {
  clearOverlay('drag');
  const t = document.createElementNS(SVGNS, 'text');
  Object.entries({ x: x + (S.touch ? -8 : 14), y: y - (S.touch ? 46 : 10), 'font-size': S.touch ? 16 : 13, fill: '#1e40af', 'font-weight': 700, 'font-family': 'system-ui, sans-serif', class: 'drag' }).forEach(([k, v]) => t.setAttribute(k, v));
  t.textContent = pitchName(p);
  $('#overlay').appendChild(t);
}

function toggleBar(mi, extend, viaStaff = false) {
  if (extend && S.measures.size) {
    const lo = Math.min(mi, ...S.measures), hi = Math.max(mi, ...S.measures);
    S.measures = new Set(Array.from({ length: hi - lo + 1 }, (_, i) => lo + i));
  } else if (S.measures.size === 1 && S.measures.has(mi) && !viaStaff) {
    S.measures = new Set();
  } else S.measures = new Set([mi]);
  S.sel = null;
  if (S.measures.size) focusBar(mi, false); else hideInspector();
  redraw();
}

// ---------------------------------------------------------------- keyboard + toolbar actions
function selected() {
  const n = selEvent();
  if (!n || n.ghost) return null;
  return { n, ev: n.ev, member: n.ev.chord.find((c) => c.el === S.sel) || n.ev.chord[0] };
}

function moveSel(delta) {
  const s = selected();
  if (!s || s.ev.rest) return;
  let p;
  edit(() => { p = S.score.moveDiatonic(s.ev, s.member.el, delta); });
  if (p) audio.preview(midiOf(p));
}
function setDur(type) {
  const s = selected();
  if (!s || S.mode === 'add') { S.dur = type; if (S.mode !== 'add') setMode('add'); else setMode('add'); updateToolbar(); return; }
  edit(() => S.score.setDuration(s.ev, type, s.ev.dots));
}
function toggleDot() {
  const s = selected();
  if (!s || S.mode === 'add') { S.dot = !S.dot; if (S.mode === 'add') setMode('add'); updateToolbar(); return; }
  edit(() => S.score.setDuration(s.ev, s.ev.type || 'quarter', s.ev.dots ? 0 : 1));
}
function setAcc(alter) {
  const s = selected();
  if (!s || s.ev.rest) { toast('Select a note first, then choose ♭ ♮ ♯'); return; }
  edit(() => S.score.setAlter(s.ev, s.member.el, alter));
  const n = selEvent();
  const m = n?.ev.chord.find((c) => c.el === S.sel);
  if (m) audio.preview(midiOf(m.pitch));
}
function toggleRest() {
  const s = selected();
  if (!s) return;
  if (s.ev.rest) {
    const a = S.score.attrs(s.ev.pi, s.ev.mi);
    const p = S.score.pitchAt(clefTop(s.ev.clef) - 4, a.fifths);
    edit(() => S.score.setPitch(s.ev.el, p));
    audio.preview(midiOf(p));
  } else {
    edit(() => S.score.toRest(s.ev));
    S.sel = s.ev.el;
    redraw();
  }
}
function del() {
  const s = selected();
  if (!s) return;
  if (s.ev.rest) { edit(() => S.score.deleteRest(s.ev)); S.sel = null; redraw(); toast('Rest removed'); return; }
  const others = s.ev.chord.filter((c) => c.el !== s.member.el);
  edit(() => S.score.removeChordTone(s.ev, s.member.el));
  S.sel = others.length ? (s.member.el === s.ev.el ? others[0].el : s.ev.el) : s.ev.el;
  redraw();
}
function stepSel(dir) {
  const notes = S.layout.notes.filter((n) => !n.ghost).sort((a, b) => a.ev.mi - b.ev.mi || a.staffIdx - b.staffIdx || noteX(a) - noteX(b));
  const n = selEvent();
  if (!n) { if (notes.length) { S.sel = notes[0].ev.el; redraw(); } return; }
  const same = notes.filter((x) => x.staffIdx === n.staffIdx).sort((a, b) => a.ev.mi - b.ev.mi || noteX(a) - noteX(b));
  const i = same.findIndex((x) => x.ev === n.ev);
  const next = same[i + dir];
  if (next) {
    S.sel = next.ev.el;
    S.measures = new Set([next.ev.mi]);
    if (!next.ev.rest) audio.preview(midiOf(next.ev.chord[0].pitch));
    focusBar(next.ev.mi, false);
    redraw();
    scrollToBar(next.ev.mi);
  }
}
function setMode(m) {
  S.mode = m;
  updateToolbar();
  for (const b of $$('[data-mode]')) b.classList.toggle('on', b.dataset.mode === m);
  $('#score').classList.toggle('mode-add', m === 'add');
  $('#hint').innerHTML = m === 'add'
    ? 'Click on the staff to write a <b>' + S.dur + (S.dot ? ' (dotted)' : '') + '</b> note there. Clicking a rest fills it. <b>Shift-click</b> a note to build a chord. Press <b>V</b> or Esc to stop.'
    : 'Click a note to select it. <b>Drag up/down</b> to change pitch, <b>left/right</b> to swap it with its neighbour. Click a bar number to select bars. <b>Add notes</b> (N) writes new ones.';
  clearOverlay('ghost');
}

function onKey(e) {
  if ($('#viewEditor').classList.contains('hidden') || !$('#modal').classList.contains('hidden')) return;
  if (e.target.closest('input, textarea')) return;
  const k = e.key;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (k === 'z' || k === 'Z')) { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
  if (mod && k === 'y') { e.preventDefault(); redo(); return; }
  if (mod) return;
  const map = { 1: 'whole', 2: 'half', 3: 'quarter', 4: 'eighth', 5: '16th', 6: '32nd' };
  if (map[k]) { e.preventDefault(); setDur(map[k]); return; }
  switch (k) {
    case 'ArrowUp': e.preventDefault(); moveSel(e.shiftKey ? 7 : 1); break;
    case 'ArrowDown': e.preventDefault(); moveSel(e.shiftKey ? -7 : -1); break;
    case 'ArrowLeft': e.preventDefault(); stepSel(-1); break;
    case 'ArrowRight': e.preventDefault(); stepSel(1); break;
    case '.': toggleDot(); break;
    case '+': case '#': setAcc(1); break;
    case '-': case '_': setAcc(-1); break;
    case '=': setAcc(0); break;
    case 'r': case 'R': toggleRest(); break;
    case 'Delete': case 'Backspace': e.preventDefault(); del(); break;
    case 'n': case 'N': setMode(S.mode === 'add' ? 'select' : 'add'); break;
    case 'v': case 'V': setMode('select'); break;
    case 'Escape': if (S.mode === 'add') setMode('select'); else { S.sel = null; S.measures.clear(); hideInspector(); redraw(); } break;
    case ' ': e.preventDefault(); togglePlay(); break;
    default: break;
  }
}

// ---------------------------------------------------------------- photo panel + inspector
let pageImg = null;
function setupPhoto() {
  const has = !!S.job;
  $('#btnPhoto').disabled = !has;
  $('#photoCol').classList.toggle('closed', !has || window.innerWidth < 860);
  if (window.innerWidth < 600 && S.zoom === 1) S.zoom = 0.72;
  if (!has) return;
  pageImg = new Image();
  pageImg.src = jobFile(S.job, 'page.png');
  pageImg.onload = () => { if (S.focus >= 0) drawInspector(S.focus); };
  setPhotoKind('page');
}
function setPhotoKind(kind) {
  S.photo = kind;
  for (const b of $$('[data-ph]')) b.classList.toggle('on', b.dataset.ph === kind);
  $('#photoImg').src = jobFile(S.job, kind === 'page' ? 'page.png' : 'original.jpg');
  $('#photoSvg').style.display = kind === 'page' ? '' : 'none';
  $('#photoImg').onload = drawPhotoOverlay;
}
function drawPhotoOverlay() {
  const svg = $('#photoSvg');
  const img = $('#photoImg');
  if (!S.job || !S.result || !img.naturalWidth) { svg.innerHTML = ''; return; }
  const [W, H] = S.result.page_size;
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  svg.setAttribute('width', img.clientWidth);
  svg.setAttribute('height', img.clientHeight);
  svg.innerHTML = '';
  S.meta.forEach((m, mi) => {
    if (!m.bbox || m.bbox[2] <= m.bbox[0]) return;
    const [x0, y0, x1, y1] = m.bbox;
    const r = document.createElementNS(SVGNS, 'rect');
    const sel = S.measures.has(mi);
    const col = sel ? '#2563eb' : m.level === 'bad' ? '#dc2626' : m.level === 'check' ? '#d97706' : '#16a34a';
    Object.entries({ x: x0, y: y0 - 6, width: x1 - x0, height: y1 - y0 + 12, fill: col, 'fill-opacity': sel ? 0.18 : m.level === 'ok' ? 0.03 : 0.14, stroke: col, 'stroke-width': sel ? 4 : m.level === 'ok' ? 1 : 2.5, rx: 6 }).forEach(([k, v]) => r.setAttribute(k, v));
    r.addEventListener('click', () => { S.measures = new Set([mi]); S.sel = null; focusBar(mi, true); redraw(); });
    const t = document.createElementNS(SVGNS, 'title');
    t.textContent = `Bar ${barNumber(mi)}: ${barReason(m)}`;
    r.appendChild(t);
    svg.appendChild(r);
  });
}
function photoOpen() { return !$('#photoCol').classList.contains('closed'); }
function focusBar(mi, scroll) {
  S.focus = mi;
  if (scroll) scrollToBar(mi);
  if (photoOpen() && window.innerWidth >= 860) {
    $('#inspector').classList.add('hidden');
    scrollPhotoTo(mi);
  } else drawInspector(mi);
}
function scrollPhotoTo(mi) {
  const m = S.meta[mi];
  const img = $('#photoImg');
  if (!m?.bbox || !S.result || !img.clientWidth) return;
  const k = img.clientWidth / S.result.page_size[0];
  const wrap = $('#photoWrap');
  const y = m.bbox[1] * k - 60;
  if (y < wrap.scrollTop || m.bbox[3] * k > wrap.scrollTop + wrap.clientHeight) wrap.scrollTo({ top: Math.max(0, y), behavior: 'smooth' });
}
function scrollToBar(mi) {
  const m = S.layout?.measures[mi];
  if (!m) return;
  const sc = $('#scoreScroll');
  const y = m.y0 - 40;
  if (y < sc.scrollTop || m.y1 > sc.scrollTop + sc.clientHeight) sc.scrollTo({ top: Math.max(0, y), behavior: 'smooth' });
}
function hideInspector() { S.focus = -1; $('#inspector').classList.add('hidden'); }
function drawInspector(mi) {
  const m = S.meta[mi];
  if (!S.job || !m || !m.bbox || m.bbox[2] <= m.bbox[0] || !pageImg?.complete || !pageImg.naturalWidth) { $('#inspector').classList.add('hidden'); return; }
  $('#inspector').classList.remove('hidden');
  const sys = (S.result.systems || []).find((s) => s.measures.includes(mi)) || { bbox: m.bbox };
  const pad = 40;
  const sx = 0, sw = pageImg.naturalWidth;
  const sy = Math.max(0, Math.min(sys.bbox[1], m.bbox[1]) - pad), sh = Math.min(pageImg.naturalHeight - sy, Math.max(sys.bbox[3], m.bbox[3]) - sy + pad);
  const c = $('#inspCanvas');
  const cw = Math.min(1400, $('#inspector').clientWidth - 24);
  const scale = cw / sw;
  c.width = cw * devicePixelRatio; c.height = Math.max(40, sh * scale) * devicePixelRatio;
  c.style.width = cw + 'px'; c.style.height = Math.max(40, sh * scale) + 'px';
  const g = c.getContext('2d');
  g.setTransform(devicePixelRatio * scale, 0, 0, devicePixelRatio * scale, 0, 0);
  g.drawImage(pageImg, sx, sy, sw, sh, 0, 0, sw, sh);
  const col = m.level === 'bad' ? '#dc2626' : m.level === 'check' ? '#d97706' : '#2563eb';
  g.strokeStyle = col; g.lineWidth = 3 / scale;
  g.strokeRect(m.bbox[0], m.bbox[1] - sy - 8, m.bbox[2] - m.bbox[0], m.bbox[3] - m.bbox[1] + 16);
  g.fillStyle = col; g.globalAlpha = 0.6;
  for (const b of m.low || []) g.fillRect(b[0], b[3] - sy + 2, Math.max(4, b[2] - b[0]), 3 / scale);
  g.globalAlpha = 1;
  $('#inspTitle').textContent = `Bar ${barNumber(mi)} in your photo`;
  const why = barReason(m);
  $('#inspConf').textContent = why[0].toUpperCase() + why.slice(1) + (m.low_n ? ' (underlined)' : '');
}

// ---------------------------------------------------------------- rescan
function targetBars() {
  if (S.measures.size) return [...S.measures].sort((a, b) => a - b);
  const n = selEvent();
  return n ? [n.ev.mi] : [];
}
function rescanContext(score, mi) {
  return { parts: score.parts.map((p, pi) => {
    const a = score.attrs(pi, Math.min(mi, p.measures.length - 1));
    const clefs = {};
    for (const [n, c] of Object.entries(a.clefs)) clefs[n] = `${c.sign}${c.line}`;
    return { staves: a.staves, fifths: a.fifths, beats: a.beats, beat_type: a.beatType, clefs };
  }) };
}
function subScoreXML(score, idxs) {
  // a standalone score holding only bars idxs, with the clef/key/time in force at the first one
  const doc = score.doc.cloneNode(true);
  const parts = [...doc.documentElement.querySelectorAll(':scope > part')];
  parts.forEach((p, pi) => {
    const ms = [...p.querySelectorAll(':scope > measure')];
    ms.forEach((m, i) => { if (!idxs.includes(i)) m.remove(); });
    const first = p.querySelector(':scope > measure');
    if (!first) return;
    const a = score.attrs(pi, idxs[0]);
    let at = first.querySelector(':scope > attributes');
    if (!at) { at = doc.createElement('attributes'); first.insertBefore(at, first.firstChild); }
    const want = (name, build) => { if (!at.querySelector(':scope > ' + name)) { const el = build(); at.insertBefore(el, at.firstChild); } };
    const mk = (n, kids) => { const e = doc.createElement(n); for (const [k, v] of kids) { const c = doc.createElement(k); c.textContent = v; e.appendChild(c); } return e; };
    // order: divisions, key, time, staves, clef
    for (const [n, cl] of Object.entries(a.clefs).reverse()) if (!at.querySelector(`:scope > clef[number="${n}"]`) && !(n === '1' && at.querySelector(':scope > clef:not([number])'))) { const c = mk('clef', [['sign', cl.sign], ['line', cl.line]]); c.setAttribute('number', n); at.appendChild(c); }
    if (a.staves > 1 && !at.querySelector(':scope > staves')) { const s = mk('staves', []); s.textContent = a.staves; const c = at.querySelector(':scope > clef'); at.insertBefore(s, c); }
    want('time', () => mk('time', [['beats', a.beats], ['beat-type', a.beatType]]));
    want('key', () => mk('key', [['fifths', a.fifths]]));
    want('divisions', () => mk('divisions', []));
    const d = at.querySelector(':scope > divisions'); if (!d.textContent) d.textContent = a.divisions;
  });
  return new XMLSerializer().serializeToString(doc);
}

async function rescan(attempt = 0, file = null) {
  const bars = targetBars();
  if (!bars.length) { toast('Select a bar first'); return; }
  if (!S.job) { toast('Rescan needs a photo; this score was opened from a file'); return; }
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  card.innerHTML = `<h2>Rescanning</h2><p><span class="spinner"></span>Re-reading the row${bars.length > 1 ? 's' : ''} holding bar ${barNumber(bars[0])}${bars.length > 1 ? '–' + barNumber(bars[bars.length - 1]) : ''}${file ? ' from your close-up' : ''}…</p>`;
  const fd = new FormData();
  fd.append('measures', bars.join(','));
  fd.append('attempt', String(attempt));
  // the layout, key, time and clefs in force where the re-read rows start, as edited so far
  const sys = S.meta[bars[0]]?.system;
  const rowStart = sys === undefined ? bars[0] : Math.max(0, S.meta.findIndex((m) => m.system === sys));
  fd.append('context', JSON.stringify(rescanContext(S.score, rowStart)));
  if (file) fd.append('file', file, file.name);
  let res;
  try {
    const r = await api(`api/jobs/${S.job}/rescan`, { method: 'POST', body: fd });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || r.statusText);
    res = await r.json();
  } catch (e) {
    card.innerHTML = `<h2>Rescan failed</h2><p class="muted"></p><div class="modal-actions"><button class="btn" data-m="close">Close</button></div>`;
    card.querySelector('p').textContent = e.message;
    card.onclick = (ev) => { if (ev.target.dataset.m === 'close') closeModal(); };
    return;
  }
  const target = res.target;
  let fresh;
  try { fresh = new Score(res.xml); } catch (e) { fresh = null; }
  const oldN = target.length, newN = fresh ? fresh.nMeasures : 0;
  const lowOld = target.reduce((a, i) => a + (S.meta[i]?.low_n || 0), 0);
  const lowNew = res.measures.reduce((a, m) => a + m.low_n, 0);
  card.innerHTML = `<h2>New reading of bars ${barNumber(target[0])}–${barNumber(target[target.length - 1])}</h2>
    <p class="muted">Method: ${res.way} · ${res.seconds}s · uncertain symbols: ${lowOld} before, ${lowNew} now.
    ${newN !== oldN ? `<br><b>Heads up:</b> the new reading has ${newN} bar${newN === 1 ? '' : 's'} where the score had ${oldN}.` : ''}</p>
    <div class="cmp"><div class="lbl">Current</div><div class="box" id="cmpOld"></div><div class="lbl">New</div><div class="box" id="cmpNew"></div></div>
    <div class="modal-actions">
      <label class="btn"><input type="file" accept="image/*,.heic,.heif" hidden id="closeup">📷 Use a close-up photo…</label>
      <button class="btn" data-m="again">⟳ Try another way</button>
      <button class="btn ghost" data-m="close">Cancel</button>
      <button class="btn primary" data-m="use" ${newN ? '' : 'disabled'}>Use the new reading</button>
    </div>`;
  const w = Math.min(940, card.clientWidth - 40);
  try { render(new Score(subScoreXML(S.score, target)), $('#cmpOld'), { width: w }); } catch (e) { $('#cmpOld').textContent = 'Could not draw'; }
  try { if (fresh) render(fresh, $('#cmpNew'), { width: w, meta: res.measures }); else $('#cmpNew').textContent = 'Nothing was read.'; } catch (e) { $('#cmpNew').textContent = 'Could not draw the new reading'; }
  $('#closeup').onchange = (ev) => { const f = ev.target.files[0]; if (f) rescan(0, f); };
  card.onclick = (ev) => {
    const a = ev.target.closest('[data-m]')?.dataset.m;
    if (a === 'close') closeModal();
    if (a === 'again') rescan(attempt + 1);
    if (a === 'use') {
      edit(() => {
        S.score.spliceMeasures(target, fresh);
        const box = (i) => S.meta[target[Math.min(i, target.length - 1)]]?.bbox;
        const newMeta = res.measures.map((m, i) => ({ ...m, system: S.meta[target[0]]?.system ?? m.system, bbox: box(i), boxes: [], low: [] }));
        S.meta.splice(target[0], target.length, ...newMeta);
      });
      S.sel = null;
      S.measures = new Set(target.slice(0, newN).length ? Array.from({ length: newN }, (_, i) => target[0] + i) : []);
      closeModal();
      redraw();
      toast(`Replaced ${oldN} bar${oldN > 1 ? 's' : ''} with the new reading. Undo with Ctrl+Z.`);
    }
  };
}
const KEY_NAMES = { '-7': 'C♭ major / A♭ minor', '-6': 'G♭ major / E♭ minor', '-5': 'D♭ major / B♭ minor', '-4': 'A♭ major / F minor', '-3': 'E♭ major / C minor', '-2': 'B♭ major / G minor', '-1': 'F major / D minor', 0: 'C major / A minor', 1: 'G major / E minor', 2: 'D major / B minor', 3: 'A major / F♯ minor', 4: 'E major / C♯ minor', 5: 'B major / G♯ minor', 6: 'F♯ major / D♯ minor', 7: 'C♯ major / A♯ minor' };
function keyTimeDialog() {
  const from = S.measures.size ? Math.min(...S.measures) : 0;
  const a = S.score.attrs(0, from);
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  let opts = '';
  for (let f = -7; f <= 7; f++) opts += `<option value="${f}" ${f === a.fifths ? 'selected' : ''}>${f > 0 ? f + '♯' : f < 0 ? -f + '♭' : 'no ♯/♭'} · ${KEY_NAMES[f]}</option>`;
  card.innerHTML = `<h2>Key and time signature</h2>
    <p class="muted">Applies from bar ${barNumber(from)} to the next change. Notes that followed the old key move to the new key, so a misread key is fixed in one step.</p>
    <div class="form">
      <label>Key <select id="ktKey">${opts}</select></label>
      <label>Time <input id="ktBeats" type="number" min="1" max="32" value="${a.beats}"> / <select id="ktType">${[1, 2, 4, 8, 16, 32].map((v) => `<option ${v === a.beatType ? 'selected' : ''}>${v}</option>`).join('')}</select></label>
    </div>
    <div class="modal-actions"><button class="btn ghost" data-m="close">Cancel</button><button class="btn primary" data-m="apply">Apply</button></div>`;
  card.onclick = (ev) => {
    const m = ev.target.closest('[data-m]')?.dataset.m;
    if (m === 'close') closeModal();
    if (m === 'apply') {
      const f = +$('#ktKey').value, bt = +$('#ktBeats').value, ty = +$('#ktType').value;
      edit(() => {
        if (f !== a.fifths) S.score.setKey(f, from);
        if (bt !== a.beats || ty !== a.beatType) S.score.setTime(bt, ty, from);
      });
      closeModal();
      toast('Updated. Undo with Ctrl+Z.');
    }
  };
}
function closeModal() { $('#modal').classList.add('hidden'); $('#modalCard').innerHTML = ''; }

// ---------------------------------------------------------------- playback + export
function togglePlay() {
  if (!S.score) return;
  if (audio.isPlaying()) { stopPlay(); return; }
  const from = S.measures.size ? Math.min(...S.measures) : 0;
  const bpm = Math.max(30, Math.min(240, +$('#tempo').value || 90));
  $('#btnPlay').querySelector('.pi').textContent = '■';
  $('#btnPlay').querySelector('.pl').textContent = 'Stop';
  const pe = S.score.playEvents();
  // where each sounding note sits on screen
  const pos = new Map();
  for (const n of S.layout.notes) if (!n.ghost && !n.ev.rest) for (const m of noteYs(n)) pos.set(m.el, { x: noteX(n), y: m.y });
  let lastKey = '';
  audio.play(pe, {
    bpm, fromMeasure: from,
    onMeasure: (m) => drawCursor(m),
    onTime: (q) => {
      const on = pe.events.filter((e) => e.time <= q && q < e.time + Math.max(e.dur, 0.05));
      const key = on.map((e) => e.time + ':' + e.midi).join(',');
      if (key === lastKey) return;
      lastKey = key;
      clearOverlay('sounding');
      for (const e of on) {
        const p = pos.get(e.el);
        if (!p) continue;
        const c = document.createElementNS(SVGNS, 'circle');
        Object.entries({ cx: p.x, cy: p.y, r: 8, fill: '#10b981', 'fill-opacity': 0.55, class: 'sounding' }).forEach(([k, v]) => c.setAttribute(k, v));
        $('#overlay').appendChild(c);
      }
    },
    onEnd: () => stopPlay(),
  });
}
function stopPlay() {
  audio.stop();
  clearOverlay('cursor');
  clearOverlay('sounding');
  $('#btnPlay').querySelector('.pi').textContent = '▶';
  $('#btnPlay').querySelector('.pl').textContent = 'Play';
}
function drawCursor(mi) {
  clearOverlay('cursor');
  const m = S.layout?.measures[mi];
  if (!m) return;
  const r = document.createElementNS(SVGNS, 'rect');
  Object.entries({ x: m.x0 + 1, y: m.y0, width: m.x1 - m.x0 - 2, height: m.y1 - m.y0, fill: '#10b981', 'fill-opacity': 0.16, stroke: '#10b981', 'stroke-width': 2, rx: 4, class: 'cursor' }).forEach(([k, v]) => r.setAttribute(k, v));
  $('#overlay').appendChild(r);
  scrollToBar(mi);
}
function exportAs(kind) {
  $('#exportMenu').classList.remove('open');
  if (!S.score) return;
  if (kind === 'xml') download(baseName() + '.musicxml', S.score.toXML(), 'application/vnd.recordare.musicxml+xml');
  if (kind === 'mid') download(baseName() + '.mid', new Blob([toMidi(S.score, +$('#tempo').value || 90)], { type: 'audio/midi' }));
}

function noteIcon(type) {
  const filled = !['whole', 'half'].includes(type);
  const flags = { eighth: 1, '16th': 2, '32nd': 3 }[type] || 0;
  let f = '';
  for (let i = 0; i < flags; i++) f += `<path d="M11.2 ${2 + i * 4.2} q5 3 4 8" fill="none" stroke="currentColor" stroke-width="1.6"/>`;
  const stem = type === 'whole' ? '' : '<line x1="11.2" y1="17" x2="11.2" y2="2" stroke="currentColor" stroke-width="1.4"/>';
  return `<svg width="20" height="22" viewBox="0 0 20 22" aria-hidden="true"><ellipse cx="7.4" cy="17.4" rx="4.4" ry="3.1" transform="rotate(-20 7.4 17.4)" fill="${filled ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.5"/>${stem}${f}</svg>`;
}

// ---------------------------------------------------------------- wiring
function wire() {
  const drop = $('#drop');
  $('#fileInput').onchange = (e) => startUpload(e.target.files[0]);
  $('#cameraInput').onchange = (e) => startUpload(e.target.files[0]);
  // phones and tablets can't drop files: say what a tap does instead
  if (matchMedia('(pointer: coarse)').matches) {
    $('.drop-main').textContent = 'Choose a photo or PDF';
    $('.drop-sub').textContent = 'JPG, PNG, HEIC, PDF · MusicXML to edit';
  }
  if (native.isNative) {
    // in the iOS app: Apple's document camera finds the page edges and flattens the page before upload
    const cam = $('#cameraInput').closest('label');
    cam.lastChild.textContent = '📷 Scan a page';
    cam.addEventListener('click', async (e) => {
      e.preventDefault();
      try {
        const f = await native.scanDocument();
        if (!f) return;
        startUpload(f);
        if (f.pages > 1) toast(`Reading the first of ${f.pages} pages. Multi-page scores are coming later.`, 4000);
      } catch (err) { toast(err.message); }
    });
    const srv = document.createElement('button');
    srv.className = 'btn ghost server-link';
    srv.textContent = 'Server: ' + location.host;
    srv.onclick = () => native.openSettings();
    $('.upload-row').appendChild(srv);
  }
  for (const ev of ['dragenter', 'dragover']) drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); });
  for (const ev of ['dragleave', 'drop']) drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); });
  drop.addEventListener('drop', (e) => startUpload(e.dataTransfer.files[0]));
  document.addEventListener('paste', (e) => { const f = [...(e.clipboardData?.files || [])][0]; if (f && !$('#viewUpload').classList.contains('hidden')) startUpload(f); });

  const sc = $('#score');
  // on touch screens a drag that starts on a note edits it; anywhere else it scrolls
  sc.addEventListener('touchstart', (e) => {
    if (!S.layout || e.touches.length !== 1) return;
    const t = e.touches[0];
    const { x, y } = localPoint(t);
    const h = hitTest(x, y, true);
    if (h && (h.type === 'note' || S.mode === 'add')) e.preventDefault();
  }, { passive: false });
  // and once a note drag is under way the page must not start scrolling under the finger
  sc.addEventListener('touchmove', (e) => { if (S.drag) e.preventDefault(); }, { passive: false });
  sc.addEventListener('pointerdown', onPointerDown);
  sc.addEventListener('pointermove', onPointerMove);
  sc.addEventListener('pointerup', onPointerUp);
  sc.addEventListener('pointercancel', onPointerUp);
  sc.addEventListener('pointerleave', () => clearOverlay('ghost'));
  document.addEventListener('keydown', onKey);

  for (const b of $$('[data-mode]')) b.onclick = () => setMode(b.dataset.mode);
  for (const b of $$('[data-dur]')) b.onclick = () => setDur(b.dataset.dur);
  for (const b of $$('[data-acc]')) b.onclick = () => setAcc(+b.dataset.acc);
  $('[data-act="dot"]').onclick = toggleDot;
  $('[data-act="rest"]').onclick = toggleRest;
  $('[data-act="delete"]').onclick = del;
  $('#btnRescan').onclick = () => rescan(0);
  $('#btnKeyTime').onclick = keyTimeDialog;
  $('#inspRescan').onclick = () => { if (S.focus >= 0 && !S.measures.has(S.focus)) S.measures = new Set([S.focus]); rescan(0); };
  $('#inspClose').onclick = hideInspector;
  $('#btnPhoto').onclick = () => { $('#photoCol').classList.toggle('closed'); setTimeout(() => { redraw(); if (S.focus >= 0) focusBar(S.focus, false); }, 0); };
  for (const b of $$('[data-ph]')) b.onclick = () => setPhotoKind(b.dataset.ph);
  $('#zoomIn').onclick = () => { S.zoom = Math.min(1.6, +(S.zoom + 0.1).toFixed(2)); redraw(); };
  $('#zoomOut').onclick = () => { S.zoom = Math.max(0.5, +(S.zoom - 0.1).toFixed(2)); redraw(); };
  $('#photoClose').onclick = () => { $('#photoCol').classList.add('closed'); redraw(); if (S.focus >= 0) focusBar(S.focus, false); };
  for (const b of $$('[data-dur]')) b.querySelector('.g').innerHTML = noteIcon(b.dataset.dur);
  $('#btnUndo').onclick = undo;
  $('#btnRedo').onclick = redo;
  $('#btnPlay').onclick = togglePlay;
  $('#btnNew').onclick = () => { stopPlay(); show('viewUpload'); loadResume(); };
  $('#btnExport').onclick = (e) => { e.stopPropagation(); $('#exportMenu').classList.toggle('open'); };
  for (const b of $$('#exportMenu button')) b.onclick = () => exportAs(b.dataset.x);
  document.addEventListener('click', () => $('#exportMenu').classList.remove('open'));
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
  let rt;
  window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { if (S.score && !$('#viewEditor').classList.contains('hidden')) redraw(); }, 150); });
}

async function loadSamples() {
  try {
    const names = await (await api('api/samples')).json();
    if (isDemo()) document.body.classList.add('demo');
    const box = $('#samples');
    box.innerHTML = names.length ? '<div class="samples-title">No photo handy? Try a sample:</div>' : '';
    for (const n of names) {
      const b = document.createElement('button');
      b.className = 'sample';
      const label = n.replace(/\.jpg$/, '').replace(/^\d+_/, '').replace(/_/g, ' ');
      b.innerHTML = `<img alt="" loading="lazy"><span></span>`;
      b.querySelector('img').src = 'samples/' + n;
      b.querySelector('span').textContent = label;
      b.onclick = async () => { const blob = await (await fetch('samples/' + n)).blob(); startUpload(new File([blob], n, { type: 'image/jpeg' })); };
      box.appendChild(b);
    }
  } catch (e) { /* no server samples */ }
  loadResume();
}
function loadResume() {
  let last = null;
  try { last = JSON.parse(localStorage.getItem(LS_KEY) || 'null'); } catch (e) { last = null; }
  $('#resume')?.remove();
  if (!last?.xml) return;
  const b = document.createElement('button');
  b.id = 'resume';
  b.className = 'btn';
  b.textContent = `↺ Continue editing ${last.name || 'your last score'}`;
  b.onclick = () => {
    S.name = last.name || 'score';
    S.result = last.result ? { ...last.result, xml: last.xml } : null;
    try { openScore(last.xml, last.meta, last.result?.quality, last.job); } catch (e) { toast(e.message); }
  };
  $('.upload-row').appendChild(b);
}

wire();
loadSamples();
show('viewUpload');
// for automated tests
window.__ms = { S, openScore: (xml, meta) => { S.name = 'test.musicxml'; openScore(xml, meta || [], null, null); }, redraw };
