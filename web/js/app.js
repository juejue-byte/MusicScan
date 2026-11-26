// MusicScan web app: upload -> transcribe -> edit on the staff -> play -> export.
import * as capture from './capture.js';
import * as library from './library.js';
import * as pbar from './practicebar.js';
import { Score, pitchName, midiOf, clefTop, toMidi } from './score.js';
import './edits.js';
import { DYNAMICS, WORDS } from './markup.js';
import * as ink from './ink.js';
import { render, pitchAtY, noteYs, fitZoom } from './render.js';
import * as audio from './audio.js';
import * as practice from './practice.js';
import * as native from './native.js';
import { api, jobFile, isDemo } from './demo.js';
import * as review from './review.js';
import { createNoteInput } from './input.js';
import { createPad } from './pad.js';
import { ARTICS } from './notations.js';
import { CLEFS, clefId } from './clefs.js';
import { INTERVALS } from './transpose.js';
import { installZoom } from './zoom.js';
import { pageRanges } from './pages.js';

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const SVGNS = 'http://www.w3.org/2000/svg';
const LS_KEY = 'musicscan:last';
const lsGet = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* blocked */ } };

const S = {
  score: null, meta: [], job: null, result: null, name: '',
  pages: {}, photoPage: null, // multi-page: job id -> { job, name, page_size, systems, quality }; page in the photo panel
  mode: 'select', dur: 'quarter', dot: false, restMode: false,
  sel: null,                 // selected note/rest element (a <note>)
  measures: new Set(),       // selected bars (for rescan / playback start)
  focus: -1,                 // bar shown in the photo inspector
  undo: [], redo: [], layout: null, drag: null, photo: 'page',
  zoom: window.innerWidth < 600 ? 0.72 : 1,
  selMark: null,             // selected typed marking (its <direction> or <fingering> element)
  inkPen: 'red', eraser: false, // Ink mode tool
  inkHidden: lsGet('musicscan:inkHidden') === '1',
  penSeen: lsGet('musicscan:penSeen') === '1', // once an Apple Pencil has drawn, fingers scroll in Ink mode
  stroke: null, inkPlaced: [],
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
  for (const b of ['#btnPlay', '#btnLoop', '#btnPractice', '#btnExport']) $(b).disabled = !editing;
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
// autosave after the frame is drawn, so it never adds to an edit's response time. The score and its details are
// taken now (by reference; serializing is the slow part), so opening another score meanwhile cannot mix them up.
let saveTimer = null, pending = null;
function saveLocal() {
  if (!S.score) return;
  if (pending && pending.score !== S.score && pending.libId !== S.libId) saveLocalNow();
  pending = { score: S.score, libId: S.libId, name: S.name, meta: S.meta, pages: S.pages, job: S.job, result: S.result };
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveLocalNow, 60);
}
function flushSave() { if (pending) saveLocalNow(); }
addEventListener('pagehide', flushSave);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flushSave(); });
function saveLocalNow() {
  clearTimeout(saveTimer); saveTimer = null;
  const P = pending; pending = null;
  if (!P) return;
  const xml = P.score.toXML();
  const result = P.result ? { quality: P.result.quality, page_size: P.result.page_size, systems: P.result.systems, second_opinion: P.result.second_opinion } : null;
  if (P.libId) library.save({ id: P.libId, name: P.name, xml, meta: P.meta, pages: P.pages, job: P.job, bars: P.score.nMeasures, parts: P.score.parts.length, t: Date.now(), result });
  try { localStorage.setItem(LS_KEY, JSON.stringify({ libId: P.libId, job: P.job, xml, meta: P.meta, pages: P.pages, name: P.name, result, t: Date.now() })); } catch (e) { /* storage full or blocked */ }
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
    const { id, result, pages } = await readPage(fd, (status) => {
      setStep(/Clean/.test(status) ? 'clean' : /Read|Double/.test(status) ? 'read' : 'upload');
      $('#progressText').textContent = `${status}… ${Math.round((Date.now() - t0) / 1000)} s`;
    });
    S.job = id;
    setStep('done'); clearInterval(tick); $('#progressBar').style.width = '100%';
    openResult(result);
    // a PDF with more pages: the rest are read one after another and added to the end as they finish
    if (pages > 1 && result.stats?.measures) addPages(file, { from: 1, total: pages });
  } catch (e) {
    clearInterval(tick);
    show('viewUpload');
    toast('Sorry, that did not work: ' + e.message, 5000);
  }
}
// upload one page (fd: the job form) and wait for its reading; onStatus gets the server's progress text
async function readPage(fd, onStatus) {
  const r = await api('api/jobs', { method: 'POST', body: fd });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || 'Upload failed');
  const { id, pages } = await r.json();
  for (;;) {
    await new Promise((res) => setTimeout(res, 700));
    const j = await (await api('api/jobs/' + id)).json();
    if (j.status === 'done') return { id, result: j.result, pages: pages || j.pages || 1 };
    if (j.status === 'error') throw new Error(j.error || 'Transcription failed');
    onStatus?.(j.status);
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
  res.job = S.job;
  openScore(res.xml, res.measures, res.quality, S.job, { [S.job]: pageRec(S.job, res, S.name) });
}

function openScore(xml, meta, quality, job, pages = null) {
  review.stop();
  S.score = new Score(xml);
  S.libId = S.openLib || library.newId(); S.openLib = null; // a new scan or file gets its own place in Your music
  S.meta = (meta || []).map((m) => ({ ...m }));
  S.job = job;
  S.pages = pages || (job && S.result ? { [job]: pageRec(job, S.result, S.name) } : {});
  if (job) for (const m of S.meta) m.page ??= job;
  S.photoPage = job;
  scoreSession++;
  setReading(null);
  S.sel = null; S.measures = new Set(); S.focus = -1; S.undo = []; S.redo = []; S.caret = null;
  $('#docTitle').textContent = S.name;
  show('viewEditor');
  renderBanner(quality);
  setupPhoto();
  setMode('select');
  $('#tempo').value = Math.round(S.score.tempo());
  practice.setScore(S.score);
  redraw();
  saveLocal();
  if (job) setTimeout(() => { const firstBad = S.meta.findIndex((m) => m.level === 'bad'); if (firstBad >= 0) focusBar(firstBad, false); }, 50);
}

// why a bar is marked, in words
function barReason(m) {
  if (m.level === 'ok') return 'read with confidence';
  const r = [];
  if (m.notes?.length) r.push(...m.notes);
  if (m.disagree) r.push('a second reading disagrees');
  if (m.filled) r.push('notes filled in from a second reading');
  if (m.low_n) r.push(`${m.low_n} uncertain symbol${m.low_n === 1 ? '' : 's'}`);
  if (m.fixes?.length) r.push('timing was repaired');
  if (!r.length) r.push(m.n ? 'low confidence' : 'nothing was read here');
  return r.join(' · ');
}

function renderBanner(q, pid = null) {
  const b = $('#qualityBanner');
  if (!q) { b.classList.add('hidden'); return; }
  const ms = pid ? S.meta.filter((m) => m.page === pid) : S.meta;
  const flagged = ms.filter((m) => m.level !== 'ok').length;
  const red = ms.filter((m) => m.level === 'bad').length;
  const icon = { good: '✓', check: '!', retake: '⚠' }[q.level];
  const title = {
    good: flagged ? `Photo looks good. ${red ? `${red} bar${red > 1 ? 's' : ''} likely wrong (red)` : 'No bars likely wrong'}, ${flagged - red} to glance at (amber).` : 'Photo looks good. Every bar was read with confidence.',
    check: `Parts of this photo were hard to read. Check the highlighted bars (${flagged}).`,
    retake: 'This photo is low quality, so the transcription is likely to have many mistakes.',
  }[q.level];
  b.className = 'banner ' + q.level;
  b.innerHTML = `<div class="b-icon">${icon}</div><div class="b-body"><div class="b-title"></div>${q.reasons.length ? '<ul></ul>' : ''}</div>
    <div class="b-actions">${flagged ? `<button class="btn small primary" data-b="fix">✓ Fix it: check ${flagged} bar${flagged > 1 ? 's' : ''}</button>` : ''}${q.level !== 'good' ? '<button class="btn small" data-b="retake">Retake photo</button>' : ''}<button class="btn small ghost" data-b="close">✕</button></div>`;
  const pno = pid ? pageNumber(pid) : 0;
  b.querySelector('.b-title').textContent = `${pno ? `Page ${pno}: ` : ''}${title} (quality ${q.score}/100)`;
  const ul = b.querySelector('ul');
  if (ul) for (const r of q.reasons) { const li = document.createElement('li'); li.textContent = r; ul.appendChild(li); }
  b.onclick = (e) => {
    const a = e.target.closest('[data-b]')?.dataset.b;
    if (a === 'close') b.classList.add('hidden');
    if (a === 'fix') { b.classList.add('hidden'); review.start(); }
    if (a === 'retake' && pid && pageList().length > 1) { retakePage(pid); return; }
    if (a === 'retake') { audio.stop(); show('viewUpload'); }
  };
}

// ---------------------------------------------------------------- drawing
function scoreWidth() { return $('#scoreScroll').clientWidth - 4; }

function redraw() {
  if (!S.score) return;
  const el = $('#score');
  const keep = $('#scoreScroll').scrollTop;
  if (S.selMark && !S.selMark.isConnected) S.selMark = null;
  // rows as printed: the zoom at which each row of the photo fits on one line, within a readable range
  if (S.autoZoom) S.zoom = Math.max(window.innerWidth < 600 ? 0.6 : 0.55, Math.min(1, Math.floor(fitZoom(S.score, scoreWidth()) * 20) / 20));
  S.layout = render(S.score, el, { width: scoreWidth(), zoom: S.zoom, selected: S.measures, selectedNote: S.sel, selectedMark: S.selMark, meta: S.meta, prev: S.layout });
  const ov = $('#overlay');
  ov.setAttribute('width', S.layout.pxWidth);
  ov.setAttribute('height', S.layout.height * S.zoom);
  ov.setAttribute('viewBox', `0 0 ${S.layout.width} ${S.layout.height}`);
  $('#zoomVal').textContent = Math.round(S.zoom * 100) + '%';
  ov.style.top = el.offsetTop + 'px';
  $('#ink').style.top = el.offsetTop + 'px';
  drawInk();
  $('#scoreScroll').scrollTop = keep;
  el.classList.toggle('mode-add', S.mode === 'add');
  drawPhotoOverlay();
  NI.drawCaret();
  PAD?.sync();
  updateToolbar();
  updateStatus();
  updateUndoButtons();
  $('#btnRescan').disabled = !pageInfo(pageIdOf(targetBars()[0])) || targetBars().length === 0;
  review.afterRedraw();
  drawPageMarks();
  drawPageTabs();
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
  const isRest = n && !n.ghost ? n.ev.rest : S.mode === 'add' && S.restMode;
  for (const b of $$('[data-dur]')) b.classList.toggle('on', b.dataset.dur === dur);
  $('[data-act="dot"]').classList.toggle('on', !!dot);
  $('[data-act="rest"]').classList.toggle('on', !!isRest);
  $('[data-act="tie"]').classList.toggle('on', !!(n && !n.ghost && !n.ev.rest && S.score.isTied(n.ev)));
  $('[data-act="tuplet"]').classList.toggle('on', !!(n && !n.ghost && n.ev.tuplet));
  const member = n && n.ev.chord.find((c) => c.el === S.sel);
  for (const b of $$('[data-acc]')) b.classList.toggle('on', !!member && (member.pitch.alter || 0) === +b.dataset.acc && !!member.el.querySelector(':scope > accidental, :scope > pitch > alter'));
}

function updateStatus() {
  const n = selEvent();
  const st = $('#status');
  const over = [];
  for (let mi = 0; mi < S.score.nMeasures; mi++) if (S.score.parts.some((p, pi) => S.score.measureProblems(pi, mi).over)) over.push(mi);
  let txt = '';
  const mk = selMarkInfo();
  if (S.mode === 'add' && S.caret) txt = NI.status(S.touch || matchMedia('(pointer: coarse)').matches);
  else if (S.mode === 'ink') {
    const nInk = ink.strokes(S.score).length;
    txt = `Ink · ${nInk} stroke${nInk === 1 ? '' : 's'}. Ink is saved with the score and kept in the MusicXML export; other apps ignore it.`;
  } else if (mk) {
    txt = `${describeMark(mk)} · bar ${barNumber(mk.mi)}. Delete removes it; Marks ▾ (K) changes it.`;
  } else if (n) {
    const num = barNumber(n.ev.mi);
    const what = n.ev.rest ? `${n.ev.type || ''} rest` : n.ev.chord.map((c) => pitchName(c.pitch)).join(' + ') + ` · ${n.ev.type || ''}${n.ev.dots ? ' dotted' : ''}`;
    const keys = S.touch ? 'Drag up/down for pitch, sideways to swap. Tap a length to change it' : 'A–G change pitch · ↑↓ semitone · ⌘↑↓ octave · 1–7 length · 0 rest · R repeat · T tie · N write notes here';
    txt = `Bar ${num}, beat ${beatOf(n.ev)} · staff ${n.ev.staff} · ${what}.  ${keys}`;
  } else if (S.measures.size) {
    txt = `${S.measures.size} bar${S.measures.size > 1 ? 's' : ''} selected. Rescan re-reads them from the photo; Play starts here; Bar ▾ splits, joins, adds or deletes bars.`;
  } else txt = `${S.score.nMeasures} bars · ${S.score.parts.length} part${S.score.parts.length > 1 ? 's' : ''}`;
  if (over.length) txt += `  ·  ⚠ ${over.length} bar${over.length > 1 ? 's are' : ' is'} too long (${over.map(barNumber).slice(0, 6).join(', ')})`;
  st.textContent = txt;
}
function beatOf(ev) {
  const a = S.score.attrs(ev.pi, ev.mi);
  const b = 1 + (ev.onset / ev.div) / (4 / a.beatType);
  return Number.isInteger(+b.toFixed(3)) ? String(Math.round(b)) : b.toFixed(2).replace(/0+$/, '');
}
const barNumber = (mi) => S.score.parts[0].measures[mi]?.getAttribute('number') ?? String(mi + 1);

// ---------------------------------------------------------------- undo
function snapshot() { return { xml: S.score.toXML(), meta: JSON.stringify(S.meta) }; }
function restore(s) {
  const pathOfSel = selPath();
  S.score = new Score(s.xml);
  S.meta = JSON.parse(s.meta);
  S.sel = elFromPath(pathOfSel);
  S.selMark = null;
  syncPages();
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
// Like edit(), but an edit that cannot be done (it throws) leaves the score exactly as it was and says why.
function act(fn) {
  const snap = snapshot();
  const path = selPath();
  try {
    const r = fn();
    S.undo.push(snap);
    if (S.undo.length > 200) S.undo.shift();
    S.redo = [];
    redraw();
    saveLocal();
    return r === undefined ? true : r;
  } catch (e) {
    S.score = new Score(snap.xml);
    S.meta = JSON.parse(snap.meta);
    S.sel = elFromPath(path);
    toast(e.message, 3600);
    redraw();
    return false;
  }
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
  // a high note can sit on the bar-number strip: the note wins
  const num = S.layout.measures.find((m) => m && x >= m.x0 && x <= m.x1 && y >= m.y0 - 16 && y < m.y0 + 2);
  const st = staveAt(x, y);
  if (!st) return num ? { type: 'num', mi: num.mi } : null;
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
  if (num) return { type: 'num', mi: num.mi };
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
  // finger: wide hit area, label above the finger. Apple Pencil: precise like a mouse (and it can hover).
  S.touch = e.pointerType === 'touch';
  S.pen = e.pointerType === 'pen';
  audio.audioCtx();
  if (S.mode === 'ink') { inkDown(e); return; }
  const { x, y } = localPoint(e);
  const h = hitTest(x, y);
  // a typed marking (dynamic, hairpin, fingering, text) under the pointer in Select mode: select it
  if (S.mode === 'select' && h?.type !== 'note') {
    const mk = markAt(x, y);
    if (mk) { S.selMark = mk.el; S.sel = null; S.measures = new Set([mk.mi]); redraw(); e.preventDefault(); return; }
  }
  if (S.selMark) S.selMark = null;
  // touch or Pencil in Add mode: the ghost note follows the tip and the note is written when it lifts
  if ((S.touch || S.pen) && S.mode === 'add' && h && (h.type === 'staff' || (h.type === 'note' && h.n.ev.rest))) {
    S.drag = { addTouch: true, x, y, startX: e.clientX, startY: e.clientY, pointer: e.pointerId };
    $('#score').setPointerCapture(e.pointerId);
    drawGhost(x, y);
    native.haptic('light');
    e.preventDefault();
    return;
  }
  if (!h) { S.sel = null; S.measures.clear(); redraw(); hideInspector(); return; }
  if (h.type === 'num') { S.barStaff = null; toggleBar(h.mi, e.shiftKey || e.metaKey || e.ctrlKey); return; }
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
    // an empty spot on a staff selects the bar; ↑↓ then move only that staff's notes (as in MuseScore)
    S.barStaff = { pi: st.pi, staff: st.staff };
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
    if (place.where === 'at' && place.n.ev.tuplet) created = S.score.restToNote(place.n.ev, pitch); // a triplet rest keeps its rhythm
    else if (place.where === 'empty') created = S.score.addToEmpty(st.pi, st.mi, st.staff, pitch, S.dur, S.dot ? 1 : 0);
    else created = S.score.placeNote(place.n.ev, pitch, S.dur, S.dot ? 1 : 0, place.where);
    if (S.restMode && created) { const ev = S.score.events(st.pi, st.mi).find((e) => e.el === created); if (ev && !ev.rest) S.score.toRest(ev); }
  });
  S.sel = created;
  S.measures = new Set([st.mi]);
  if (created) NI.caretAfter(created);
  if (!S.restMode) audio.preview(midiOf(pitch));
  native.haptic('medium');
  redraw();
}

function onPointerMove(e) {
  if (!S.layout) return;
  if (S.mode === 'ink') { inkMove(e); return; }
  const { x, y } = localPoint(e);
  if (S.drag?.addTouch) {
    S.drag.x = x; S.drag.y = y;
    const before = $('#overlay .ghost text')?.textContent;
    drawGhost(x, y, S.touch);
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
  if (e.pointerType !== 'touch') S.touch = false;  // mouse or a hovering Apple Pencil
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
  if (S.mode === 'ink' || S.stroke) { inkUp(e); return; }
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
  Object.entries({ cx: gx, cy: sy, rx: 6.2, ry: 4.6, fill: '#1769C2', 'fill-opacity': 0.45, transform: `rotate(-20 ${gx} ${sy})` }).forEach(([k, v]) => head.setAttribute(k, v));
  g.appendChild(head);
  const t = document.createElementNS(SVGNS, 'text');
  Object.entries({ x: gx - 10, y: Math.min(sy, top) - (finger ? 48 : 14), 'font-size': finger ? 16 : 12, fill: '#0F56A3', 'font-family': 'system-ui, sans-serif', 'font-weight': 600 }).forEach(([k, v]) => t.setAttribute(k, v));
  t.textContent = pitchName(pitch);
  t.setAttribute('paint-order', 'stroke');
  t.setAttribute('stroke', '#fff');
  t.setAttribute('stroke-width', '4');
  g.appendChild(t);
  $('#overlay').appendChild(g);
}
function line(x1, y1, x2, y2) {
  const l = document.createElementNS(SVGNS, 'line');
  Object.entries({ x1, y1, x2, y2, stroke: '#1769C2', 'stroke-opacity': 0.5, 'stroke-width': 1.2 }).forEach(([k, v]) => l.setAttribute(k, v));
  return l;
}
function drawDragLabel(p, x, y) {
  clearOverlay('drag');
  const t = document.createElementNS(SVGNS, 'text');
  Object.entries({ x: x + (S.touch ? -8 : 14), y: y - (S.touch ? 46 : 10), 'font-size': S.touch ? 16 : 13, fill: '#0F56A3', 'font-weight': 700, 'font-family': 'system-ui, sans-serif', class: 'drag' }).forEach(([k, v]) => t.setAttribute(k, v));
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
// The palette turns the selection into what you pick: a length makes it a note of that length (a rest becomes a
// note), Rest makes it a rest of the same length. With nothing selected it sets what Add notes writes.
function setDur(type) {
  const s = selected();
  if (!s || S.mode === 'add') { S.dur = type; S.restMode = false; setMode('add'); updateToolbar(); return; }
  if (s.ev.rest) {
    const p = guessPitch(s.ev);
    act(() => {
      S.score.restToNote(s.ev, p);
      const e = S.score.events(s.ev.pi, s.ev.mi).find((x) => x.el === s.ev.el);
      if (e && (e.type !== type || e.dots)) S.score.setDuration(e, type, 0);
    });
    S.sel = s.ev.el;
    audio.preview(midiOf(p));
    redraw();
    return;
  }
  edit(() => S.score.setDuration(s.ev, type, s.ev.dots));
}
// a pitch for a rest that becomes a note: the note before it in the same staff, else the middle line
function guessPitch(ev) {
  for (let mi = ev.mi; mi >= Math.max(0, ev.mi - 4); mi--) {
    const prev = S.score.events(ev.pi, mi).filter((e) => !e.rest && !e.grace && e.staff === ev.staff && (mi < ev.mi || e.onset < ev.onset)).sort((a, b) => b.onset - a.onset)[0];
    if (prev) return { ...prev.chord[0].pitch };
  }
  return S.score.pitchAt(clefTop(ev.clef) - 4, S.score.attrs(ev.pi, ev.mi).fifths);
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
function makeRest() {
  const s = selected();
  if (!s || S.mode === 'add') { S.restMode = S.mode === 'add' ? !S.restMode : true; setMode('add'); updateToolbar(); return; }
  if (s.ev.rest) { toast('This is already a rest. Pick a note length to turn it into a note.'); return; }
  edit(() => S.score.toRest(s.ev));
  S.sel = s.ev.el;
  redraw();
}
function tie() {
  const s = selected();
  if (!s || s.ev.rest) { toast('Select a note, then tie it to the next note of the same pitch'); return; }
  const on = act(() => S.score.toggleTie(s.ev));
  if (on !== false) toast(S.score.isTied(S.score.events(s.ev.pi, s.ev.mi).find((e) => e.el === s.ev.el) || s.ev) ? 'Tied to the next note' : 'Tie removed', 1600);
}
function tuplet(n = 3) {
  const s = selected();
  if (!s) { toast('Select a note to divide it into a triplet'); return; }
  const name = { 3: 'triplet', 5: 'quintuplet', 6: 'sextuplet', 7: 'septuplet', 9: 'nonuplet' }[n] || n + '-tuplet';
  if (s.ev.tuplet) { if (act(() => { S.sel = S.score.removeTuplet(s.ev); })) toast(`Back to one note`, 1600); return; }
  if (act(() => { S.sel = S.score.makeTuplet(s.ev, n); })) toast(`Made a ${name}. Click its rests in Add notes to fill them.`, 3200);
}

// ---------------------------------------------------------------- bars: split, join, insert, delete (every part)
const metaOn = () => S.meta.length > 0;
function metaSplit(mi, frac) {
  if (!metaOn() || !S.meta[mi]) return;
  const m = S.meta[mi];
  const a = { ...m }, b = { ...m, low: [], boxes: [], low_n: 0 };
  if (m.bbox) { const [x0, y0, x1, y1] = m.bbox; const xm = x0 + (x1 - x0) * frac; a.bbox = [x0, y0, xm, y1]; b.bbox = [xm, y0, x1, y1]; }
  S.meta.splice(mi, 1, a, b);
}
function metaJoin(mi) {
  if (!metaOn()) return;
  const a = S.meta[mi], b = S.meta[mi + 1];
  if (!a || !b) { S.meta.splice(mi + 1, 1); return; }
  const rank = { ok: 0, check: 1, bad: 2 };
  const m = { ...a, level: (rank[b.level] || 0) > (rank[a.level] || 0) ? b.level : a.level, low_n: (a.low_n || 0) + (b.low_n || 0), low: [...(a.low || []), ...(b.low || [])] };
  if (a.bbox && b.bbox && a.system === b.system) m.bbox = [Math.min(a.bbox[0], b.bbox[0]), Math.min(a.bbox[1], b.bbox[1]), Math.max(a.bbox[2], b.bbox[2]), Math.max(a.bbox[3], b.bbox[3])];
  S.meta.splice(mi, 2, m);
}
function metaInsert(idx) {
  if (!metaOn()) return;
  const near = S.meta[idx] || S.meta[idx - 1] || {};
  S.meta.splice(idx, 0, { level: 'ok', low_n: 0, low: [], boxes: [], system: near.system, bbox: null });
}
function metaDelete(lo, hi) { if (metaOn()) S.meta.splice(lo, hi - lo + 1); }
const isOver = (mi) => S.score.parts.some((p, pi) => S.score.measureProblems(pi, mi).over);
const barQl = (mi) => S.score.measureLength(0, mi) / S.score.attrs(0, mi).divisions;
function barRange() {
  const s = selected();
  if (s) return [s.ev.mi, s.ev.mi];
  const bars = targetBars();
  return bars.length ? [bars[0], bars[bars.length - 1]] : null;
}
// where Split would put the barline: before the selected note, or at the time signature of an over-long bar
function splitPoint() {
  const s = selected();
  if (s) { const q = S.score.onsetQl(s.ev); return q > 0 ? { mi: s.ev.mi, q } : null; }
  const r = barRange();
  if (r && isOver(r[0])) return { mi: r[0], q: barQl(r[0]) };
  return null;
}
function splitBar() {
  const sp = splitPoint();
  if (!sp) { toast(selected() ? 'This note already starts the bar. Select the note that should start the new bar.' : 'Select the note that should start the new bar'); return; }
  const content = Math.max(barQl(sp.mi), ...S.score.parts.map((p, pi) => (S.score.measureProblems(pi, sp.mi).ends ? Math.max(0, ...Object.values(S.score.measureProblems(pi, sp.mi).ends)) / S.score.attrs(pi, sp.mi).divisions : 0)));
  const keep = S.sel;
  if (act(() => { S.score.splitBar(sp.mi, sp.q); metaSplit(sp.mi, Math.min(1, sp.q / content)); ink.onSplit(S.score, sp.mi, Math.min(1, sp.q / content)); })) {
    S.sel = keep && keep.isConnected ? keep : null;
    S.measures = new Set([sp.mi + 1]);
    redraw();
    toast(`Split bar ${barNumber(sp.mi)}: the new bar starts here. Undo with Ctrl+Z.`);
  }
}
function joinBars() {
  const r = barRange();
  if (!r) { toast('Select a bar (or a note in it) to join it with the next bar'); return; }
  const mi = r[0];
  if (mi + 1 >= S.score.nMeasures) { toast('This is the last bar'); return; }
  if (act(() => { const wa = S.layout.measures[mi], wb = S.layout.measures[mi + 1]; S.score.mergeBars(mi); metaJoin(mi); ink.onJoin(S.score, mi, wa && wb ? (wa.x1 - wa.x0) / (wa.x1 - wa.x0 + wb.x1 - wb.x0) : 0.5); })) { S.sel = null; S.measures = new Set([mi]); redraw(); toast(`Joined bars ${barNumber(mi)} and ${+barNumber(mi) + 1 || 'next'}. Undo with Ctrl+Z.`); }
}
function insertBar(where) {
  const r = barRange();
  const mi = r ? (where === 'before' ? r[0] : r[1]) : S.score.nMeasures - 1;
  let idx = -1;
  if (act(() => { idx = S.score.insertBar(mi, where); metaInsert(idx); ink.onInsert(S.score, idx); })) { S.sel = null; S.measures = new Set([idx]); redraw(); scrollToBar(idx); }
}
function deleteBars() {
  const r = barRange();
  if (!r) { toast('Select the bars to delete'); return; }
  const [lo, hi] = r;
  const label = lo === hi ? `bar ${barNumber(lo)}` : `bars ${barNumber(lo)}–${barNumber(hi)}`;
  if (act(() => { S.score.deleteBars(lo, hi); metaDelete(lo, hi); ink.onDelete(S.score, lo, hi); })) { S.sel = null; S.measures = new Set(); hideInspector(); redraw(); toast(`Deleted ${label}. Undo with Ctrl+Z.`); }
}
function openBarMenu(btn) {
  const menu = $('#barMenu');
  if (menu.classList.contains('open')) { menu.classList.remove('open'); return; }
  const r = barRange(), sp = splitPoint();
  const split = menu.querySelector('[data-bar="split"]');
  split.disabled = !sp;
  split.firstChild.textContent = !selected() && sp ? 'Split this too-long bar at its time signature ' : 'Split the bar before this note ';
  menu.querySelector('[data-bar="join"]').disabled = !r || r[0] + 1 >= S.score.nMeasures;
  menu.querySelector('[data-bar="delete"]').disabled = !r || r[1] - r[0] + 1 >= S.score.nMeasures;
  menu.querySelector('[data-bar="delete"]').firstChild.textContent = r && r[1] > r[0] ? `Delete ${r[1] - r[0] + 1} bars ` : 'Delete the bar ';
  const cp = menu.querySelector('[data-bar="copy"]'), ps = menu.querySelector('[data-bar="paste"]');
  cp.disabled = !r;
  cp.firstChild.textContent = r && r[1] > r[0] ? `Copy ${r[1] - r[0] + 1} bars ` : 'Copy the bar ';
  ps.disabled = !r || CLIP?.kind !== 'bars';
  for (const k of ['octup', 'octdown']) menu.querySelector(`[data-bar="${k}"]`).disabled = !r;
  ps.firstChild.textContent = CLIP?.kind === 'bars' && CLIP.n > 1 ? `Paste ${CLIP.n} bars here ` : 'Paste over this bar ';
  menu.classList.add('open');
  const b = btn.getBoundingClientRect();
  const w = menu.offsetWidth;
  menu.style.left = Math.max(8, Math.min(window.innerWidth - w - 8, b.left)) + 'px';
  menu.style.top = (b.bottom + 4) + 'px';
}
// Bar menu: a whole bar (or the selected bars) up or down an octave; with a note selected, its bar
function barOctave(dir) {
  const s = selected();
  if (s) { S.measures = new Set([s.ev.mi]); S.barStaff = { pi: s.ev.pi, staff: s.ev.staff }; S.sel = null; }
  if (!S.measures.size) { toast('Select a bar first'); return; }
  NI.pitchKey(dir, 'octave');
}
function barAction(a) {
  $('#barMenu').classList.remove('open');
  if (!S.score) return;
  ({ split: splitBar, join: joinBars, before: () => insertBar('before'), after: () => insertBar('after'), delete: deleteBars, copy: () => copySel(false, true), paste: () => paste(true), octup: () => barOctave(1), octdown: () => barOctave(-1) })[a]?.();
}
function del() {
  if (S.selMark) { removeSelMark(); return; }
  const s = selected();
  if (!s) return;
  if (s.ev.rest) { edit(() => S.score.deleteRest(s.ev)); S.sel = null; redraw(); toast('Rest removed'); return; }
  const others = s.ev.chord.filter((c) => c.el !== s.member.el);
  edit(() => S.score.removeChordTone(s.ev, s.member.el));
  S.sel = others.length ? (s.member.el === s.ev.el ? others[0].el : s.ev.el) : s.ev.el;
  redraw();
}
function stepSel(dir, opts = {}) {
  const notes = S.layout.notes.filter((n) => !n.ghost).sort((a, b) => a.ev.mi - b.ev.mi || a.staffIdx - b.staffIdx || noteX(a) - noteX(b));
  const n = selEvent();
  if (!n) { if (notes.length) { S.sel = notes[0].ev.el; redraw(); } return; }
  const same = notes.filter((x) => x.staffIdx === n.staffIdx).sort((a, b) => a.ev.mi - b.ev.mi || noteX(a) - noteX(b));
  const i = same.findIndex((x) => x.ev === n.ev);
  const next = same[i + dir];
  if (next) {
    S.sel = next.ev.el;
    S.measures = new Set([next.ev.mi]);
    if (!next.ev.rest && !opts.quiet) audio.preview(midiOf(next.ev.chord[0].pitch));
    focusBar(next.ev.mi, false);
    redraw();
    scrollToBar(next.ev.mi);
  }
}
function setMode(m) {
  const was = S.mode;
  S.mode = m;
  if (m === 'add' && was !== 'add' && S.score) NI.startAtSelection();
  updateToolbar();
  for (const b of $$('[data-mode]')) b.classList.toggle('on', b.dataset.mode === m);
  $('#score').classList.toggle('mode-add', m === 'add');
  document.body.classList.toggle('ink-mode', m === 'ink');
  document.body.classList.toggle('eraser', m === 'ink' && S.eraser);
  if (m === 'ink') { S.sel = null; S.selMark = null; if (S.inkHidden) setInkHidden(false); if (S.layout) redraw(); }
  clearOverlay('inkcursor');
  const tap = matchMedia('(pointer: coarse)').matches;
  $('#hint').innerHTML = m === 'ink' ? inkHint() : m === 'add'
    ? (tap
      ? 'Tap a piano key to write a <b>' + S.dur + (S.dot ? ' (dotted)' : '') + '</b> note at the blue caret, or touch the staff and slide to the pitch; it is written when you lift. Tap <b>Select</b> to stop.'
      : 'Type <b>A–G</b> to write ' + S.dur + (S.dot ? ' (dotted)' : '') + ' notes at the blue caret, or click on the staff. <b>0</b> rest · <b>R</b> repeat · <b>Shift+letter</b> chord · <b>?</b> all shortcuts · <b>Esc</b> to stop.')
    : (tap ? 'Tap' : 'Click') + ' a note to select it. <b>Drag up/down</b> to change pitch, <b>left/right</b> to swap it. Pick a length, <b>Rest</b>, <b>Tie</b> or <b>Triplet</b> to turn it into that. <b>Bar ▾</b> splits, joins, adds or deletes bars.';
  if (S.score && S.layout) { NI.drawCaret(); PAD?.sync(); updateStatus(); }
  clearOverlay('ghost');
}

// One shortcut map for the whole editor, following the conventions of the popular notation editors.
// SHORTCUTS drives the ? help sheet, so keep it in step with onKey.
const SHORTCUTS = [
  ['Write notes', [
    ['N', 'Note input on / off (the caret starts at the selection)'],
    ['A – G', 'Write that note at the caret, nearest octave. Outside note input: re-pitch the selected note and move on'],
    ['Shift + A – G', 'Add that note above the last one (a chord)'],
    ['0', 'Rest (at the caret, or turn the selection into a rest)'],
    ['R', 'Repeat the last note or chord'],
    ['1 – 7', 'Length: 64th, 32nd, 16th, eighth, quarter, half, whole'],
    ['.', 'Dotted'],
    ['+  −  =', 'Sharp, flat, natural'],
    ['T', 'Tie (in note input: a tied note of the same pitch)'],
    ['Alt + 3', 'Triplet (Alt+5, 6, 7, 9 for other tuplets)'],
    ['S', 'Slur to the next note (or over the selected bars); again removes it'],
    ['Shift + S, V, N, O', 'Staccato, accent, tenuto, marcato (again removes it)'],
    ['Backspace', 'In note input: step back and clear that note'],
    ['⌘/Ctrl + Alt + 1 – 4', 'Write in voice 1 – 4 of the staff (two melodies on one staff)'],
  ]],
  ['Move and change', [
    ['↑ ↓', 'Up or down a semitone (every note when bars are selected)'],
    ['Alt + ↑ ↓', 'Up or down a scale step'],
    ['⌘/Ctrl + ↑ ↓', 'Up or down an octave'],
    ['← →', 'Previous / next note (the caret in note input)'],
    ['⌘/Ctrl + ← →', 'Previous / next bar'],
    ['⌘/Ctrl + Shift + ↑ ↓', 'Move the note to the staff above / below (piano)'],
    ['Alt + Shift + ↑ ↓', 'In note input: the caret goes to the staff above / below'],
    ['Delete', 'Delete the note (a rest stays in its place)'],
    ['⌘/Ctrl + C, X, V', 'Copy, cut, paste: the selected note or chord, or whole bars'],
    ['Shift + ← →', 'Select more bars'],
    ['⌘/Ctrl + A', 'Select every bar'],
    ['Pinch, ⌘/Ctrl + scroll', 'Zoom the score'],
    ['⌘/Ctrl + Z,  ⇧⌘/Ctrl + Z', 'Undo, redo'],
    ['Esc', 'Leave note input, then clear the selection'],
  ]],
  ['Bars', [
    ['|', 'Split the bar before the selected note'],
    ['J', 'Join with the next bar'],
    ['I,  Shift + I', 'Insert an empty bar after / before'],
    ['Shift + Delete', 'Delete the selected bars'],
  ]],
  ['While Fix it is open', [
    ['Enter', 'This bar looks right'],
    ['[  ]', 'Previous / next flagged bar'],
    ['P', 'Play the bar'],
    ['E', 'Edit the bar in the score (A – G then change the selected note)'],
    ['F or Esc', 'Close Fix it (with no note selected)'],
  ]],
  ['Play and mark up', [
    ['Space', 'Play / stop'],
    ['L', 'Loop the selected bars'],
    ['[  ]', 'Slower / faster'],
    ['M', 'Metronome click on / off'],
    ['K', 'Marks menu (dynamics, fingering, text)'],
    ['P', 'Ink (draw with Apple Pencil); X switches to the eraser'],
    ['F', 'Fix it: step through the flagged bars (when no note is selected)'],
    ['V', 'Select'],
    ['?', 'This list'],
  ]],
];
function showShortcuts() {
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  card.innerHTML = `<h2>Keyboard shortcuts</h2><div class="keys-grid">${SHORTCUTS.map(([h, rows]) => `<section><h3>${h}</h3><dl>${rows.map(([k, d]) => `<dt><kbd>${k}</kbd></dt><dd>${d}</dd>`).join('')}</dl></section>`).join('')}</div>
    <div class="modal-actions"><button class="btn primary" data-m="close">Done</button></div>`;
  card.onclick = (ev) => { if (ev.target.closest('[data-m]')) closeModal(); };
}

// length keys, as in MuseScore and Dorico: 5 is a quarter, up for longer, down for shorter
const DUR_KEYS = { 1: '64th', 2: '32nd', 3: '16th', 4: 'eighth', 5: 'quarter', 6: 'half', 7: 'whole' };
function onKey(e) {
  if (e.key === 'Escape' && !$('#modal').classList.contains('hidden')) { closeModal(); return; }
  if ($('#viewEditor').classList.contains('hidden') || !$('#modal').classList.contains('hidden')) return;
  if (e.target.closest('input, textarea, select')) return;
  const k = e.key;
  const mod = e.metaKey || e.ctrlKey;
  const add = S.mode === 'add';
  if (mod && (k === 'z' || k === 'Z')) { e.preventDefault(); e.shiftKey ? redo() : undo(); return; }
  if (mod && k === 'y') { e.preventDefault(); redo(); return; }
  if (mod && e.altKey && /^Digit[1-4]$/.test(e.code)) { e.preventDefault(); if (!add) setMode('add'); NI.setVoice(+e.code.slice(5)); return; }
  if (mod && !e.shiftKey && !e.altKey && (k === 'c' || k === 'C')) { if (copySel()) e.preventDefault(); return; }
  if (mod && !e.shiftKey && !e.altKey && (k === 'x' || k === 'X')) { if (copySel(true)) e.preventDefault(); return; }
  if (mod && !e.shiftKey && !e.altKey && (k === 'v' || k === 'V')) { if (paste()) e.preventDefault(); return; }
  if (mod && !e.shiftKey && (k === 'a' || k === 'A')) { e.preventDefault(); S.sel = null; S.measures = new Set(Array.from({ length: S.score.nMeasures }, (_, i) => i)); redraw(); toast(`All ${S.score.nMeasures} bars selected`, 1400); return; }
  if (mod && e.shiftKey && (k === 'ArrowUp' || k === 'ArrowDown')) { e.preventDefault(); NI.moveToStaff(k === 'ArrowUp' ? -1 : 1); return; }
  if (mod && (k === 'ArrowUp' || k === 'ArrowDown')) { e.preventDefault(); NI.pitchKey(k === 'ArrowUp' ? 1 : -1, 'octave'); return; }
  if (mod && (k === 'ArrowLeft' || k === 'ArrowRight')) { e.preventDefault(); const d = k === 'ArrowRight' ? 1 : -1; if (add) NI.moveCaret(d, true); else stepBar(d); return; }
  if (mod) return;
  // Alt+3 / Alt+5 ...: tuplets (by key position, so it works with any keyboard layout's Alt characters)
  if (e.altKey && /^Digit[35679]$/.test(e.code)) { e.preventDefault(); tuplet(+e.code.slice(5)); return; }
  if (e.altKey && e.shiftKey && add && (k === 'ArrowUp' || k === 'ArrowDown')) { e.preventDefault(); NI.changeStaff(k === 'ArrowUp' ? -1 : 1); return; }
  if (e.altKey && (k === 'ArrowUp' || k === 'ArrowDown')) { e.preventDefault(); NI.pitchKey(k === 'ArrowUp' ? 1 : -1, 'step'); return; }
  if (e.altKey) return;
  // number keys by position too, so Shift or a non-US layout still picks a length
  const dk = /^Digit[0-7]$/.test(e.code) ? e.code.slice(5) : /^[0-7]$/.test(k) ? k : null;
  if (dk === '0') { e.preventDefault(); if (add) NI.write(null); else makeRest(); return; }
  if (dk && DUR_KEYS[dk]) { e.preventDefault(); setDur(DUR_KEYS[dk]); return; }
  // articulations and slurs, as in MuseScore
  const ART_KEYS = { S: 'staccato', V: 'accent', N: 'tenuto', O: 'strong-accent' };
  if (e.shiftKey && ART_KEYS[k]) { e.preventDefault(); articulation(ART_KEYS[k]); return; }
  if (k === 's' && !e.shiftKey) { e.preventDefault(); slur(); return; }
  // note names
  if (/^[a-gA-G]$/.test(k)) {
    if (S.mode === 'ink') return;
    e.preventDefault();
    NI.letter(k.toUpperCase(), e.shiftKey && add);
    return;
  }
  switch (k) {
    case 'ArrowUp': e.preventDefault(); NI.pitchKey(1, e.shiftKey ? 'octave' : 'semi'); break;
    case 'ArrowDown': e.preventDefault(); NI.pitchKey(-1, e.shiftKey ? 'octave' : 'semi'); break;
    case 'ArrowLeft': e.preventDefault(); if (e.shiftKey && !add) extendBars(-1); else if (add) NI.moveCaret(-1); else stepSel(-1); break;
    case 'ArrowRight': e.preventDefault(); if (e.shiftKey && !add) extendBars(1); else if (add) NI.moveCaret(1); else stepSel(1); break;
    case '.': toggleDot(); break;
    case '+': case '#': setAcc(1); break;
    case '-': case '_': setAcc(-1); break;
    case '=': setAcc(0); break;
    case 'r': case 'R': NI.repeat(); break;
    case 't': case 'T': if (add) NI.tieOn(); else tie(); break;
    case '|': splitBar(); break;
    case 'j': case 'J': joinBars(); break;
    case 'i': insertBar('after'); break;
    case 'I': insertBar('before'); break;
    case 'Backspace': if (add && !e.shiftKey) { e.preventDefault(); NI.backspace(); break; } // falls through
    case 'Delete': e.preventDefault(); if (e.shiftKey || (!selected() && S.measures.size)) deleteBars(); else del(); break;
    case 'n': case 'N': setMode(add ? 'select' : 'add'); break;
    case 'p': case 'P': setMode(S.mode === 'ink' ? 'select' : 'ink'); break;
    case 'x': case 'X': if (S.mode === 'ink') setPen(S.eraser ? S.inkPen : 'eraser'); break;
    case 'k': case 'K': if (S.mode !== 'ink') openMarksMenu($('#btnMarks')); break;
    case 'v': case 'V': setMode('select'); break;
    case '?': e.preventDefault(); showShortcuts(); break;
    case 'Escape': if ($('#marksMenu').classList.contains('open')) closeMenus(); else if (S.mode !== 'select') setMode('select'); else { S.sel = null; S.measures.clear(); hideInspector(); redraw(); } break;
    case ' ': e.preventDefault(); togglePlay(); break;
    case 'l': case 'L': toggleLoop(); break;
    default: practice.key(e); break;
  }
}
// Copy and paste, as everywhere: a selected note or chord, or whole bars (every part). Cut clears the bars to rests.
var CLIP = null;
function copySel(cut = false, barsOnly = false) {
  if (!S.score) return false;
  const s = selected();
  if (s && !cut && !barsOnly) {
    CLIP = { kind: 'note', rest: s.ev.rest, pitches: s.ev.chord.map((c) => ({ ...c.pitch })), type: s.ev.type || 'quarter', dots: s.ev.dots };
    toast('Copied the ' + (s.ev.rest ? 'rest' : s.ev.chord.length > 1 ? 'chord' : 'note') + '. Select a note and press ⌘V to paste over it.', 2200);
    return true;
  }
  const bars = s ? [s.ev.mi] : targetBars();
  if (!bars.length) return false;
  const lo = bars[0], hi = bars[bars.length - 1];
  const idxs = Array.from({ length: hi - lo + 1 }, (_, i) => lo + i);
  CLIP = { kind: 'bars', xml: subScoreXML(S.score, idxs), n: idxs.length };
  const label = idxs.length > 1 ? `${idxs.length} bars` : `bar ${barNumber(lo)}`;
  if (cut) {
    if (act(() => { for (const mi of idxs) S.score.parts.forEach((p, pi) => { for (const ev of S.score.events(pi, mi)) if (!ev.rest && !ev.grace) S.score.toRest(ev); }); })) toast(`Cut ${label}. Select a bar and press ⌘V to paste.`, 2200);
  } else toast(`Copied ${label}. Select a bar and press ⌘V to paste.`, 2200);
  return true;
}
function paste() {
  if (!S.score || !CLIP) { if (S.score) toast('Copy a note or some bars first (⌘C)'); return !!S.score; }
  if (CLIP.kind === 'note') {
    const s = selected();
    if (!s && !(S.mode === 'add' && S.caret)) { toast('Select where the note should go'); return true; }
    if (s) NI.caretAt(s.ev);
    NI.write(CLIP.rest ? null : CLIP.pitches.map((p) => ({ ...p })), { type: CLIP.type, dots: CLIP.dots });
    return true;
  }
  const s = selected();
  const start = s ? s.ev.mi : targetBars()[0];
  if (start === undefined) { toast('Select the bar to paste into'); return true; }
  const other = new Score(CLIP.xml);
  const end = Math.min(S.score.nMeasures, start + CLIP.n);
  const targets = Array.from({ length: end - start }, (_, i) => start + i);
  if (act(() => {
    S.score.spliceMeasures(targets, other);
    for (let i = targets.length; i < CLIP.n; i++) metaInsert(start + i);
    for (let i = 0; i < CLIP.n; i++) if (S.meta[start + i]) S.meta[start + i] = { ...S.meta[start + i], level: 'ok', low: [], low_n: 0, disagree: false, fixes: [] };
  })) {
    S.sel = null;
    S.measures = new Set(Array.from({ length: CLIP.n }, (_, i) => start + i));
    redraw();
    toast(`Pasted ${CLIP.n > 1 ? CLIP.n + ' bars' : 'the bar'} at bar ${barNumber(start)}. Undo with ⌘Z.`, 2200);
  }
  return true;
}
// Shift+← / Shift+→: grow or shrink the bar selection
function extendBars(dir) {
  const n = selEvent();
  if (!S.measures.size && n) S.measures = new Set([n.ev.mi]);
  if (!S.measures.size) return;
  if (S.anchor === undefined || !S.measures.has(S.anchor)) S.anchor = Math.min(...S.measures);
  const lo = Math.min(...S.measures), hi = Math.max(...S.measures);
  let a = S.anchor, b = S.anchor === lo ? hi : lo;
  b = Math.max(0, Math.min(S.score.nMeasures - 1, b + dir));
  S.sel = null;
  S.measures = new Set(Array.from({ length: Math.abs(b - a) + 1 }, (_, i) => Math.min(a, b) + i));
  redraw();
  scrollToBar(b);
}
// Shift+S/V/N/O: staccato, accent, tenuto, marcato on the selected note (again removes it)
function articulation(kind) {
  const s = selected();
  if (!s || s.ev.rest) { toast(`Select a note, then add a ${ARTICS[kind].name.toLowerCase()}`); return; }
  let on = false;
  if (act(() => { on = S.score.toggleArticulation(s.ev, kind); })) toast(`${ARTICS[kind].name} ${on ? 'added' : 'removed'}`, 1200);
}
// S: slur the selected note to the next one (again removes it); with bars selected, over the whole selection
function slur() {
  const s = selected();
  if (s) {
    let on = false;
    if (act(() => { on = S.score.toggleSlur(s.ev); })) toast(on ? 'Slur to the next note. Select a later note and press S again to start another.' : 'Slur removed', 1800);
    return;
  }
  const bars = targetBars();
  if (!bars.length) { toast('Select a note (or some bars), then press S for a slur'); return; }
  const evs = (mi) => S.score.voiceEvents(0, mi, '1', null).filter((e) => !e.rest);
  const first = evs(bars[0])[0];
  const lastList = evs(bars[bars.length - 1]).filter((e) => e.voice === first?.voice);
  const last = lastList[lastList.length - 1];
  if (!first || !last || first.el === last.el) { toast('A slur needs two notes'); return; }
  if (act(() => S.score.toggleSlur(first, last))) toast(`Slur over ${bars.length > 1 ? bars.length + ' bars' : 'the bar'} (top staff)`, 1600);
}
// ⌘← / ⌘→ outside note input: the first note of the previous / next bar
function stepBar(dir) {
  const n = selEvent();
  const cur = n ? n.ev.mi : S.measures.size ? Math.min(...S.measures) : -1;
  const mi = Math.max(0, Math.min(S.score.nMeasures - 1, cur + dir));
  const first = S.layout.notes.filter((x) => !x.ghost && x.ev.mi === mi && (!n || x.staffIdx === n.staffIdx)).sort((a, b) => noteX(a) - noteX(b))[0];
  S.sel = first ? first.ev.el : null;
  S.measures = new Set([mi]);
  focusBar(mi, false);
  redraw();
  scrollToBar(mi);
}

// ---------------------------------------------------------------- photo panel + inspector
const pageImgs = {};          // job id -> loaded Image of its cleaned page (for the inspector)
function pageImgOf(id) {
  if (!id) return null;
  if (!pageImgs[id]) { const im = new Image(); im.src = jobFile(id, 'page.png'); im.onload = () => { if (S.focus >= 0 && pageIdOf(S.focus) === id) drawInspector(S.focus); }; pageImgs[id] = im; }
  return pageImgs[id];
}
function setupPhoto() {
  const has = !!S.job;
  $('#btnPhoto').disabled = !has;
  $('#photoCol').classList.toggle('closed', !has || window.innerWidth < 860);
  S.autoZoom = true; // until the reader zooms by hand, keep the photo's rows whole (see redraw)
  if (!has) return;
  pageImgOf(S.photoPage || S.job);
  setPhotoKind('page');
}
function setPhotoKind(kind) {
  S.photo = kind;
  for (const b of $$('[data-ph]')) b.classList.toggle('on', b.dataset.ph === kind);
  const id = S.photoPage || S.job;
  if (!id) return;
  $('#photoImg').src = jobFile(id, kind === 'page' ? 'page.png' : 'original.jpg');
  $('#photoSvg').style.display = kind === 'page' ? '' : 'none';
  $('#photoImg').onload = drawPhotoOverlay;
}
// show page `id` in the photo panel
function showPhotoPage(id) {
  if (!id || !pageInfo(id) || id === S.photoPage) return;
  S.photoPage = id;
  pageImgOf(id);
  $('#photoSvg').innerHTML = '';
  setPhotoKind(S.photo);
  drawPageTabs();
}
function drawPhotoOverlay() {
  const svg = $('#photoSvg');
  const img = $('#photoImg');
  const pg = pageInfo(S.photoPage);
  if (!pg?.page_size || !img.naturalWidth) { svg.innerHTML = ''; return; }
  const [W, H] = pg.page_size;
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  svg.setAttribute('width', img.clientWidth);
  svg.setAttribute('height', img.clientHeight);
  svg.innerHTML = '';
  S.meta.forEach((m, mi) => {
    if (m.page !== S.photoPage || !m.bbox || m.bbox[2] <= m.bbox[0]) return;
    const [x0, y0, x1, y1] = m.bbox;
    const r = document.createElementNS(SVGNS, 'rect');
    const sel = S.measures.has(mi);
    const col = sel ? '#1769C2' : m.level === 'bad' ? '#C2362B' : m.level === 'check' ? '#E39B1B' : '#1D7A4E';
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
  if (m?.page && m.page !== S.photoPage && pageInfo(m.page)) { showPhotoPage(m.page); img.addEventListener('load', () => scrollPhotoTo(mi), { once: true }); return; }
  const pg = pageInfo(S.photoPage);
  if (!m?.bbox || !pg?.page_size || !img.clientWidth) return;
  const k = img.clientWidth / pg.page_size[0];
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
  const pid = pageIdOf(mi);
  const pageImg = pageImgOf(pageInfo(pid) ? pid : null);
  if (!pageImg || !m || !m.bbox || m.bbox[2] <= m.bbox[0] || !pageImg.complete || !pageImg.naturalWidth) { $('#inspector').classList.add('hidden'); return; }
  $('#inspector').classList.remove('hidden');
  const sys = (pageInfo(pid).systems || []).find((s) => s.index === m.system) || { bbox: m.bbox };
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
  const col = m.level === 'bad' ? '#C2362B' : m.level === 'check' ? '#E39B1B' : '#1769C2';
  g.strokeStyle = col; g.lineWidth = 3 / scale;
  g.strokeRect(m.bbox[0], m.bbox[1] - sy - 8, m.bbox[2] - m.bbox[0], m.bbox[3] - m.bbox[1] + 16);
  g.fillStyle = col; g.globalAlpha = 0.6;
  for (const b of m.low || []) g.fillRect(b[0], b[3] - sy + 2, Math.max(4, b[2] - b[0]), 3 / scale);
  g.globalAlpha = 1;
  $('#inspTitle').textContent = `Bar ${barNumber(mi)} in your photo${pageList().length > 1 ? ` (page ${pageNumber(pid)})` : ''}`;
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
  let bars = targetBars();
  if (!bars.length) { toast('Select a bar first'); return; }
  // a rescan re-reads rows of one photo: the page of the first selected bar
  const pid = pageIdOf(bars[0]);
  if (!pageInfo(pid)) { toast('Rescan needs a photo; this score was opened from a file'); return; }
  const onPage = bars.filter((mi) => pageIdOf(mi) === pid);
  if (onPage.length < bars.length) toast(`Rescanning the bars on page ${pageNumber(pid)} only`);
  bars = onPage;
  const base = pageStart(pid);
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  card.innerHTML = `<h2>Rescanning</h2><p><span class="spinner"></span>Re-reading the row${bars.length > 1 ? 's' : ''} holding bar ${barNumber(bars[0])}${bars.length > 1 ? '–' + barNumber(bars[bars.length - 1]) : ''}${file ? ' from your close-up' : ''}…</p>`;
  const fd = new FormData();
  fd.append('measures', bars.map((mi) => mi - base).join(','));
  fd.append('attempt', String(attempt));
  // the layout, key, time and clefs in force where the re-read rows start, as edited so far
  const sys = S.meta[bars[0]]?.system;
  const rowStart = sys === undefined ? bars[0] : Math.max(0, S.meta.findIndex((m) => m.page === pid && m.system === sys));
  fd.append('context', JSON.stringify(rescanContext(S.score, rowStart)));
  if (file) fd.append('file', file, file.name);
  let res;
  try {
    const r = await api(`api/jobs/${pid}/rescan`, { method: 'POST', body: fd });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || r.statusText);
    res = await r.json();
  } catch (e) {
    card.innerHTML = `<h2>Rescan failed</h2><p class="muted"></p><div class="modal-actions"><button class="btn" data-m="close">Close</button></div>`;
    card.querySelector('p').textContent = e.message;
    card.onclick = (ev) => { if (ev.target.dataset.m === 'close') closeModal(); };
    return;
  }
  const target = res.target.map((t) => t + base).filter((t) => t < S.score.nMeasures);
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
        const newMeta = res.measures.map((m, i) => ({ ...m, page: pid, system: S.meta[target[0]]?.system ?? m.system, bbox: box(i), boxes: [], low: [] }));
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
  const from = selected() ? selected().ev.mi : S.measures.size ? Math.min(...S.measures) : 0;
  const a = S.score.attrs(0, from);
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  let opts = '';
  for (let f = -7; f <= 7; f++) opts += `<option value="${f}" ${f === a.fifths ? 'selected' : ''}>${f > 0 ? f + '♯' : f < 0 ? -f + '♭' : 'no ♯/♭'} · ${KEY_NAMES[f]}</option>`;
  // the clef of the selected note's staff (or the caret's, else the top staff)
  const sn = selected();
  const cpi = sn ? sn.ev.pi : S.caret?.pi ?? 0, cst = sn ? sn.ev.staff : S.caret?.staff ?? '1';
  const staffList = [];
  S.score.parts.forEach((p, pi) => { const n = S.score.attrs(pi, from).staves || 1; for (let st = 1; st <= n; st++) staffList.push({ pi, st: String(st), label: [S.score.parts.length > 1 ? `part ${pi + 1}` : '', n > 1 ? (st === 1 ? 'upper staff' : st === 2 && n === 2 ? 'lower staff' : `staff ${st}`) : ''].filter(Boolean).join(', ') || 'the staff' }); });
  const curClef = clefId(S.score.attrs(cpi, from).clefs[cst]);
  card.innerHTML = `<h2>Key, time and clef</h2>
    <p class="muted">Applies from bar ${barNumber(from)} to the next change. Notes that followed the old key move to the new key, so a misread key is fixed in one step.</p>
    <div class="form">
      <label>Key <select id="ktKey">${opts}</select></label>
      <label>Time <input id="ktBeats" type="number" min="1" max="32" value="${a.beats}"> / <select id="ktType">${[1, 2, 4, 8, 16, 32].map((v) => `<option ${v === a.beatType ? 'selected' : ''}>${v}</option>`).join('')}</select></label>
      <label>Clef of ${staffList.length > 1 ? `<select id="ktStaff">${staffList.map((x) => `<option value="${x.pi}/${x.st}" ${x.pi === cpi && x.st === cst ? 'selected' : ''}>${x.label}</option>`).join('')}</select>` : 'the staff'} <select id="ktClef">${Object.entries(CLEFS).map(([id, c]) => `<option value="${id}" ${id === curClef ? 'selected' : ''}>${c.name}</option>`).join('')}</select></label>
      <fieldset class="kt-clef-how"><label><input type="radio" name="ktHow" value="place" checked> The clef was misread: keep the notes where they are printed</label>
      <label><input type="radio" name="ktHow" value="pitch"> A new clef: keep the notes' pitch</label></fieldset>
    </div>
    <h2 class="kt-sub">Transpose the whole piece</h2>
    <div class="form">
      <label><select id="trDir"><option value="1">Up</option><option value="-1">Down</option></select> a <select id="trIv">${INTERVALS.map((iv) => `<option value="${iv.id}" ${iv.id === 'M2' ? 'selected' : ''}>${iv.name}</option>`).join('')}</select></label>
      <button class="btn" data-m="transpose">Transpose</button>
    </div>
    <div class="modal-actions"><button class="btn ghost" data-m="close">Cancel</button><button class="btn primary" data-m="apply">Apply</button></div>`;
  const stSel = $('#ktStaff');
  if (stSel) stSel.onchange = () => { const [pi, st] = stSel.value.split('/'); $('#ktClef').value = clefId(S.score.attrs(+pi, from).clefs[st]); };
  card.onclick = (ev) => {
    const m = ev.target.closest('[data-m]')?.dataset.m;
    if (m === 'close') closeModal();
    if (m === 'transpose') {
      const dir = +$('#trDir').value, iv = $('#trIv').value;
      edit(() => S.score.transpose(iv, dir));
      closeModal();
      toast(`Transposed ${dir > 0 ? 'up' : 'down'} a ${INTERVALS.find((x) => x.id === iv).name.replace(/ \(.*/, '')}. Undo with ⌘Z.`);
    }
    if (m === 'apply') {
      const f = +$('#ktKey').value, bt = +$('#ktBeats').value, ty = +$('#ktType').value;
      const [spi, sst] = ($('#ktStaff')?.value || `${cpi}/${cst}`).split('/');
      const clef = $('#ktClef').value, keepPlace = card.querySelector('[name="ktHow"]:checked')?.value !== 'pitch';
      edit(() => {
        if (f !== a.fifths) S.score.setKey(f, from);
        if (bt !== a.beats || ty !== a.beatType) S.score.setTime(bt, ty, from);
        if (clef !== clefId(S.score.attrs(+spi, from).clefs[sst])) S.score.setClef(+spi, sst, from, clef, keepPlace);
      });
      closeModal();
      toast('Updated. Undo with Ctrl+Z.');
    }
  };
}
function closeModal() { $('#modal').classList.add('hidden'); $('#modalCard').innerHTML = ''; }

// ---------------------------------------------------------------- markup: freehand ink (its own layer)
function closeMenus() { for (const m of ['#exportMenu', '#barMenu', '#marksMenu']) $(m).classList.remove('open'); }
function inkHint() {
  const who = S.penSeen ? '<b>Apple Pencil</b> draws, fingers scroll' : 'Draw with <b>Apple Pencil</b>, a mouse or a finger';
  return `<b>Ink</b>: ${who}. Ink sits on its own layer and never changes the notes. <b>Eraser</b> (X${native.isNative ? ' or double-tap the Pencil' : ''}) rubs strokes out. Press <b>Done</b> or Esc to edit notes again.`;
}
function setPen(id) {
  if (id === 'eraser') S.eraser = true;
  else { S.eraser = false; S.inkPen = id; }
  for (const b of $$('[data-pen]')) b.classList.toggle('on', S.eraser ? b.dataset.pen === 'eraser' : b.dataset.pen === S.inkPen);
  document.body.classList.toggle('eraser', S.mode === 'ink' && S.eraser);
  if (S.mode !== 'ink') setMode('ink');
}
function setInkHidden(h) {
  S.inkHidden = h;
  lsSet('musicscan:inkHidden', h ? '1' : '0');
  if (h && S.mode === 'ink') setMode('select');
  drawInk();
  if (h) toast('Ink hidden. It is still saved with the score.', 1800);
}
function drawInk() {
  if (!S.layout || !S.score) return;
  S.inkPlaced = ink.draw(S.score, S.layout, $('#ink'), S.inkHidden);
  const any = ink.hasInk(S.score);
  const b = $('#btnInkVis');
  b.classList.toggle('hidden', !any);
  b.classList.toggle('off', S.inkHidden);
  b.textContent = S.inkHidden ? 'Ink: hidden' : 'Ink: shown';
  b.setAttribute('aria-pressed', String(!S.inkHidden));
}
const penOf = () => ink.PENS.find((p) => p.id === S.inkPen) || ink.PENS[0];
const penWidth = (pen) => (pen.tool === 'hl' ? 14 : pen.id === 'graphite' ? 1.9 : 2.6);
// a mouse reports 0.5 while pressed and a finger 0 or 1 depending on the browser: only a Pencil's pressure is real
const pressureOf = (e) => (e.pointerType === 'pen' && e.pressure > 0 ? e.pressure : 0.5);
function inkCommit(change) {
  S.undo.push(snapshot());
  if (S.undo.length > 200) S.undo.shift();
  S.redo = [];
  change();
  drawInk();
  saveLocal();
  updateUndoButtons();
  updateStatus();
}
function inkDown(e) {
  if (e.pointerType === 'pen' && !S.penSeen) {
    S.penSeen = true;
    lsSet('musicscan:penSeen', '1');
    $('#hint').innerHTML = inkHint();
    toast('Apple Pencil found: the Pencil draws and fingers scroll.', 3000);
  }
  if (e.pointerType === 'touch' && S.penSeen) return; // a finger scrolls once a Pencil is in use
  e.preventDefault();
  audio.audioCtx();
  const { x, y } = localPoint(e);
  $('#score').setPointerCapture(e.pointerId);
  clearOverlay('inkcursor');
  if (S.eraser) { S.stroke = { erase: true, pointer: e.pointerId, pushed: false }; eraseAt(x, y); return; }
  const pen = penOf();
  S.stroke = { pointer: e.pointerId, pen, w: penWidth(pen), pts: [[x, y, pressureOf(e)]], el: null };
  liveStroke();
}
function inkMove(e) {
  const { x, y } = localPoint(e);
  if (!S.stroke) {
    // a hovering Pencil (or a mouse) shows where the tip will draw
    if (e.pointerType !== 'touch' && !S.inkHidden) inkCursor(x, y);
    return;
  }
  if (e.pointerId !== S.stroke.pointer) return;
  const evs = e.getCoalescedEvents?.() || [];
  const list = evs.length ? evs : [e];
  for (const c of list) {
    const q = localPoint(c);
    if (S.stroke.erase) eraseAt(q.x, q.y);
    else S.stroke.pts.push([q.x, q.y, pressureOf(c)]);
  }
  if (!S.stroke.erase) liveStroke();
  e.preventDefault();
}
function inkUp(e) {
  const st = S.stroke;
  S.stroke = null;
  if (!st) return;
  if (st.erase) { if (st.pushed) saveLocal(); return; }
  st.el?.remove();
  if (e?.type === 'pointercancel' && st.pts.length < 3) return;
  const s = ink.makeStroke(S.layout, st.pts, st.pen, st.w);
  inkCommit(() => ink.setStrokes(S.score, [...ink.strokes(S.score), s]));
}
function liveStroke() {
  const st = S.stroke;
  const el = ink.strokeEl({ tool: st.pen.tool, c: st.pen.color, w: st.w }, st.pts);
  if (st.el) st.el.replaceWith(el); else $('#ink').appendChild(el);
  st.el = el;
}
function eraseAt(x, y) {
  const near = ink.strokesNear(S.inkPlaced, x, y, S.touch ? 14 : 9);
  inkCursor(x, y, true);
  if (!near.length) return;
  const gone = new Set(near);
  const apply = () => ink.setStrokes(S.score, ink.strokes(S.score).filter((_, i) => !gone.has(i)));
  // one undo step for a whole rub of the eraser
  if (!S.stroke.pushed) { S.stroke.pushed = true; inkCommit(apply); } else { apply(); drawInk(); }
  native.haptic('light');
}
function inkCursor(x, y, eraser = S.eraser) {
  clearOverlay('inkcursor');
  const c = document.createElementNS(SVGNS, 'circle');
  const pen = penOf();
  const r = eraser ? 9 : Math.max(2, penWidth(pen) / 2);
  Object.entries({ cx: x, cy: y, r, fill: eraser ? 'none' : pen.color, 'fill-opacity': eraser ? 0 : 0.5, stroke: eraser ? '#4E647C' : 'none', 'stroke-width': 1.2, class: 'inkcursor' }).forEach(([k, v]) => c.setAttribute(k, v));
  $('#overlay').appendChild(c);
}
function clearInk() {
  if (!ink.hasInk(S.score)) { toast('There is no ink to clear'); return; }
  inkCommit(() => ink.setStrokes(S.score, []));
  toast('Ink cleared. Undo brings it back.');
}

// ---------------------------------------------------------------- markup: typed markings (real MusicXML)
function markAt(x, y) {
  const hit = (S.layout.marks || []).find((h) => x >= h.x0 && x <= h.x1 && y >= h.y0 && y <= h.y1);
  return hit ? hit.mark : null;
}
function selMarkInfo() {
  if (!S.selMark) return null;
  return S.score.allMarks().find((m) => m.el === S.selMark) || null;
}
const MARK_NAMES = { dynamics: 'Dynamic', wedge: 'Hairpin', words: 'Text', rehearsal: 'Rehearsal mark', fingering: 'Fingering' };
function describeMark(m) {
  if (m.kind === 'wedge') return m.value === 'diminuendo' ? 'Diminuendo hairpin' : m.value === 'stop' ? 'Hairpin end' : 'Crescendo hairpin';
  return `${MARK_NAMES[m.kind]} ${m.value}`;
}
function removeSelMark() {
  const m = selMarkInfo();
  if (!m) { S.selMark = null; return; }
  if (act(() => S.score.removeMark(m))) { S.selMark = null; redraw(); toast(`${describeMark(m)} removed`, 1600); }
}
// the note a marking goes on: the selected note, else the first note of the first selected bar
function markTarget() {
  const s = selected();
  if (s) return { ev: s.ev, member: s.member };
  const m = selMarkInfo();
  const bars = [...S.measures].sort((a, b) => a - b);
  const mi = m ? m.mi : bars[0];
  if (mi === undefined) return null;
  const evs = S.score.events(m ? m.pi : 0, mi).filter((e) => !e.grace && !e.hidden && (m ? e.staff === m.staff : e.staff === '1')).sort((a, b) => a.onset - b.onset);
  if (m) { const at = evs.find((e) => e.onset >= m.onset); if (at) return { ev: at, member: at.chord[0] }; }
  return evs[0] ? { ev: evs[0], member: evs[0].chord[0] } : null;
}
function openMarksMenu(btn) {
  if (!S.score) return;
  closeMenus();
  const menu = $('#marksMenu');
  const t = markTarget();
  const m = selMarkInfo();
  const note = t && !t.ev.rest;
  const bars = [...S.measures].sort((a, b) => a - b);
  const where = m ? `${describeMark(m)} in bar ${barNumber(m.mi)}` : t ? (selected() ? `On the selected ${t.ev.rest ? 'rest' : 'note'}, bar ${barNumber(t.ev.mi)}` : `At the start of bar ${barNumber(t.ev.mi)}`) : 'Select a note or a bar first, then pick a marking.';
  const curFinger = t?.member?.el?.querySelector(':scope > notations > technical > fingering')?.textContent.trim();
  const curDyn = m?.kind === 'dynamics' ? m.value : t ? S.score._markAt(t.ev, 'dynamics')?.value : null;
  const dis = (on) => (on ? '' : ' disabled');
  const span = bars.length > 1 ? `bars ${barNumber(bars[0])}–${barNumber(bars[bars.length - 1])}` : 'to the end of the bar';
  menu.innerHTML = `<div class="mk-head"></div>
    <div class="mk-row"><span class="mk-label">Dynamics</span>${DYNAMICS.map((d) => `<button data-mk="dyn" data-v="${d}" class="dyn${curDyn === d ? ' on' : ''}"${dis(t)}>${d}</button>`).join('')}</div>
    <div class="mk-row"><span class="mk-label">Hairpin · ${span}</span><button data-mk="wedge" data-v="crescendo"${dis(t)} title="Crescendo">&lt;&nbsp; cresc.</button><button data-mk="wedge" data-v="diminuendo"${dis(t)} title="Diminuendo">&gt;&nbsp; dim.</button></div>
    <div class="mk-row"><span class="mk-label">Articulation</span>${['staccato', 'accent', 'tenuto', 'strong-accent'].map((a) => `<button data-mk="artic" data-v="${a}" class="art${note && S.score.hasArticulation(t.ev, a) ? ' on' : ''}"${dis(note)} title="${ARTICS[a].name} (${ARTICS[a].key})">${{ staccato: '·', accent: '>', tenuto: '–', 'strong-accent': '^' }[a]}&nbsp;${ARTICS[a].name}</button>`).join('')}<button data-mk="slur"${dis(note || bars.length)} title="Slur (S)">⌒ Slur</button></div>
    <div class="mk-row"><span class="mk-label">Fingering</span>${[1, 2, 3, 4, 5].map((f) => `<button data-mk="finger" data-v="${f}" class="${curFinger === String(f) ? 'on' : ''}"${dis(note)}>${f}</button>`).join('')}<button data-mk="finger" data-v=""${dis(note && curFinger)} title="Remove the fingering">✕</button></div>
    <div class="mk-row"><span class="mk-label">Text</span>${WORDS.map((w) => `<button data-mk="words" data-v="${w}" class="words"${dis(t)}>${w}</button>`).join('')}<button data-mk="words-custom"${dis(t)}>${m?.kind === 'words' ? 'Edit text…' : 'Your own…'}</button></div>
    <div class="mk-row"><span class="mk-label">Bar</span><button data-mk="rehearsal"${dis(t || bars.length)}><span class="reh">${S.score.nextRehearsal()}</span> Rehearsal mark</button>${m ? `<button data-mk="remove" class="danger">Remove ${MARK_NAMES[m.kind].toLowerCase()}</button>` : ''}</div>`;
  menu.querySelector('.mk-head').textContent = where;
  menu.classList.add('open');
  const b = btn.getBoundingClientRect();
  const w = menu.offsetWidth;
  menu.style.left = Math.max(8, Math.min(window.innerWidth - w - 8, b.left)) + 'px';
  menu.style.top = Math.min(b.bottom + 4, Math.max(8, window.innerHeight - menu.offsetHeight - 8)) + 'px';
}
function markAction(kind, v) {
  const t = markTarget();
  const m = selMarkInfo();
  const keepNote = S.sel;
  let made = null;
  const done = (msg) => { closeMenus(); S.sel = keepNote && keepNote.isConnected ? keepNote : null; if (made && !S.sel) S.selMark = made; redraw(); if (msg) toast(msg, 2200); };
  if (kind === 'remove') { closeMenus(); removeSelMark(); return; }
  if (kind === 'artic') { closeMenus(); articulation(v); return; }
  if (kind === 'slur') { closeMenus(); slur(); return; }
  if (kind === 'words-custom') { closeMenus(); textDialog(m?.kind === 'words' ? m : null, t); return; }
  if (!t && kind !== 'rehearsal') { toast('Select a note or a bar first'); return; }
  if (kind === 'dyn') {
    const ok = m?.kind === 'dynamics' ? act(() => S.score.changeDynamic(m.el, v)) : act(() => { made = S.score.setDynamic(t.ev, v); });
    if (ok) done(); return;
  }
  if (kind === 'wedge') {
    const bars = [...S.measures].sort((a, b) => a - b);
    const end = bars.length ? Math.max(t.ev.mi, bars[bars.length - 1]) : t.ev.mi;
    if (act(() => { made = S.score.addHairpin(t.ev, v, end); })) done(`${v === 'crescendo' ? 'Crescendo' : 'Diminuendo'} to the end of bar ${barNumber(end)}. Select bars first to make it longer.`);
    return;
  }
  if (kind === 'finger') {
    if (act(() => S.score.setFingering(t.member.el, v || null))) done();
    return;
  }
  if (kind === 'words') {
    const ok = m?.kind === 'words' ? act(() => S.score.changeWords(m.el, v)) : act(() => { made = S.score.addWords(t.ev, v); });
    if (ok) done(); return;
  }
  if (kind === 'rehearsal') {
    const mi = t ? t.ev.mi : Math.min(...S.measures);
    if (act(() => { made = S.score.setRehearsal(mi); })) done();
  }
}
function textDialog(mark, t) {
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  card.innerHTML = `<h2>${mark ? 'Edit text' : 'Add text'}</h2>
    <p class="muted">Shown above the staff and saved as MusicXML words, for example <i>rit.</i>, <i>con moto</i> or a breath reminder.</p>
    <input class="text" id="markText" maxlength="80" autocomplete="off" placeholder="Type here">
    <div class="modal-actions"><button class="btn ghost" data-m="cancel">Cancel</button><button class="btn primary" data-m="ok">${mark ? 'Save' : 'Add'}</button></div>`;
  const input = card.querySelector('#markText');
  input.value = mark ? mark.value : '';
  setTimeout(() => input.focus(), 30);
  const ok = () => {
    const text = input.value.trim();
    closeModal();
    if (!text) return;
    let made = null;
    const r = mark ? act(() => S.score.changeWords(mark.el, text)) : act(() => { made = S.score.addWords(t.ev, text); });
    if (r) { if (made) S.selMark = made; redraw(); }
  };
  input.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); ok(); } if (e.key === 'Escape') closeModal(); };
  card.onclick = (ev) => { const a = ev.target.closest('[data-m]')?.dataset.m; if (a === 'ok') ok(); if (a === 'cancel') closeModal(); };
}

// ---------------------------------------------------------------- playback + export
function togglePlay() {
  if (!S.score) return;
  if (audio.isPlaying()) { stopPlay(); return; }
  const from = S.measures.size ? Math.min(...S.measures) : 0;
  // Loop on: repeat the selected bars (one bar selected loops that bar), or the whole piece with nothing selected
  const loop = !!S.loop;
  const to = loop && S.measures.size ? Math.max(...S.measures) : null;
  $('#btnPlay').querySelector('.pi').textContent = '■';
  $('#btnPlay').querySelector('.pl').textContent = 'Stop';
  const pe = S.score.playEvents();
  for (const e of pe.events) e.track = practice.trackOf(e);
  // where each sounding note sits on screen
  const pos = new Map();
  for (const n of S.layout.notes) if (!n.ghost && !n.ev.rest) for (const m of noteYs(n)) pos.set(m.el, { x: noteX(n), y: m.y });
  let lastKey = '';
  audio.play(pe, {
    ...practice.playOptions(loop), fromMeasure: from, toMeasure: to, loop,
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
        Object.entries({ cx: p.x, cy: p.y, r: 8, fill: '#5FAEEB', 'fill-opacity': 0.55, class: 'sounding' }).forEach(([k, v]) => c.setAttribute(k, v));
        $('#overlay').appendChild(c);
      }
    },
    onEnd: () => stopPlay(),
  });
  pbar.show(from);
}
function toggleLoop() {
  S.loop = !S.loop;
  $('#btnLoop').classList.toggle('on', S.loop);
  $('#btnLoop').setAttribute('aria-pressed', String(S.loop));
  if (audio.isPlaying()) { stopPlay(); togglePlay(); }
  toast(S.loop ? (S.measures.size ? 'Loop on: the selected bars repeat.' : 'Loop on. Select bars to loop just those.') : 'Loop off.');
}
function stopPlay() {
  audio.stop();
  practice.stopped();
  clearOverlay('cursor');
  clearOverlay('sounding');
  $('#btnPlay').querySelector('.pi').textContent = '▶';
  $('#btnPlay').querySelector('.pl').textContent = 'Play';
  pbar.hide();
}
function drawCursor(mi) {
  clearOverlay('cursor');
  const m = S.layout?.measures[mi];
  if (!m) return;
  const r = document.createElementNS(SVGNS, 'rect');
  Object.entries({ x: m.x0 + 1, y: m.y0, width: m.x1 - m.x0 - 2, height: m.y1 - m.y0, fill: '#5FAEEB', 'fill-opacity': 0.16, stroke: '#5FAEEB', 'stroke-width': 2, rx: 4, class: 'cursor' }).forEach(([k, v]) => r.setAttribute(k, v));
  $('#overlay').appendChild(r);
  scrollToBar(mi);
  pbar.setBar(mi);
}
function exportAs(kind) {
  $('#exportMenu').classList.remove('open');
  if (!S.score) return;
  if (kind === 'xml') download(baseName() + '.musicxml', S.score.toXML(), 'application/vnd.recordare.musicxml+xml');
  if (kind === 'mid') download(baseName() + '.mid', new Blob([toMidi(S.score, +$('#tempo').value || 90, practice.programs())], { type: 'audio/midi' }));
}

function noteIcon(type) {
  const filled = !['whole', 'half'].includes(type);
  const flags = { eighth: 1, '16th': 2, '32nd': 3 }[type] || 0;
  let f = '';
  for (let i = 0; i < flags; i++) f += `<path d="M11.2 ${2 + i * 4.2} q5 3 4 8" fill="none" stroke="currentColor" stroke-width="1.6"/>`;
  const stem = type === 'whole' ? '' : '<line x1="11.2" y1="17" x2="11.2" y2="2" stroke="currentColor" stroke-width="1.4"/>';
  return `<svg width="20" height="22" viewBox="0 0 20 22" aria-hidden="true"><ellipse cx="7.4" cy="17.4" rx="4.4" ry="3.1" transform="rotate(-20 7.4 17.4)" fill="${filled ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.5"/>${stem}${f}</svg>`;
}

// ---------------------------------------------------------------- multi-page scores
// Each page is its own reading (job); its bars are appended to the one score, so editing, playback and export cover
// the whole piece. meta[mi].page says which page (job) bar mi came from; the bar order gives the page order.
function pageRec(job, res, name) {
  return { job, name: name || '', page_size: res.page_size, systems: res.systems, quality: res.quality, pdf_page: res.pdf_page ?? null, second_opinion: res.second_opinion };
}
const pageInfo = (id) => (id && S.pages[id]) || null;
const pageIdOf = (mi) => (mi == null ? null : S.meta[mi]?.page ?? S.job);
const pageList = () => (S.score ? pageRanges(S.meta, S.score.nMeasures, S.job) : []);
const pageNumber = (id) => pageList().findIndex((r) => r.id === id) + 1;
const pageStart = (id) => Math.max(0, pageList().find((r) => r.id === id)?.lo ?? 0);
const blankMeta = (page = null) => ({ level: 'ok', low_n: 0, low: [], boxes: [], bbox: null, page });
let pageQueue = Promise.resolve();
let scoreSession = 0;            // bumps when another score is opened: pages still being read are then dropped

// after page edits: the first page with a photo is the score's "own" job, and the photo panel shows a real page
function syncPages() {
  const list = pageList();
  const firstPhoto = list.find((r) => pageInfo(r.id));
  if (firstPhoto) S.job = firstPhoto.id;
  if (!list.some((r) => r.id === S.photoPage) && firstPhoto) { S.photoPage = null; showPhotoPage(firstPhoto.id); }
}
function markPages() { S.score.markPages(pageList().map((r) => r.lo)); }
// ink strokes are pinned to bar indices: renumber them when pages move (map: old index -> new index or null)
function inkRemap(map) { const l = ink.strokes(S.score); if (l.length) ink.setStrokes(S.score, l.map((st) => (map(st.mi) == null ? null : { ...st, mi: map(st.mi) })).filter(Boolean)); }

function setReading(text) {
  let el = $('#pageReading');
  if (!text) { el?.remove(); return; }
  if (!el) {
    el = document.createElement('div');
    el.id = 'pageReading';
    el.className = 'page-reading';
    el.innerHTML = '<span class="spinner"></span><span class="t"></span>';
    document.body.appendChild(el);
  }
  el.querySelector('.t').textContent = text;
}

/** Read `file` and add it to the end of the score: a photo is one page, a PDF adds its pages from `from` on. */
function addPages(file, opts = {}) {
  const session = scoreSession;
  pageQueue = pageQueue.then(() => readMorePages(file, opts, session)).catch((e) => { setReading(null); toast('Could not add the page: ' + e.message, 5000); });
  return pageQueue;
}
async function readMorePages(file, { from = 0, total = null }, session) {
  if (session !== scoreSession || !S.score) return;
  const isPdf = /\.pdf$/i.test(file.name || '') || file.type === 'application/pdf';
  let n = total ?? 1;
  for (let k = from; k < n; k++) {
    const label = isPdf && total ? `page ${k + 1} of ${n}` : `page ${pageList().length + 1}`;
    setReading(`Reading ${label}…`);
    const fd = new FormData();
    fd.append('file', file, file.name || 'page.jpg');
    fd.append('detector', $('#optFast').checked ? '2m' : '28m');
    if (isPdf) fd.append('page', String(k));
    // key, time, clefs and the part layout in force at the end of the score so far carry onto the new page
    fd.append('context', JSON.stringify(S.score.endContext()));
    const t0 = Date.now();
    const { id, result, pages } = await readPage(fd, (st) => setReading(`Reading ${label}: ${st.toLowerCase()}… ${Math.round((Date.now() - t0) / 1000)} s`));
    if (session !== scoreSession) { setReading(null); return; }
    if (isPdf && total == null) n = pages;
    appendPage(id, result, isPdf ? `${file.name} p${k + 1}` : file.name);
  }
  setReading(null);
}
function appendPage(id, res, name) {
  if (!res.stats?.measures) { toast(`No music was found on ${name || 'that page'}, so it was not added.`, 4000); return; }
  let fresh;
  try { fresh = new Score(res.xml); } catch (e) { toast('Could not read that page: ' + e.message); return; }
  S.pages[id] = pageRec(id, res, name);
  const lo = S.score.nMeasures;
  let dropped = 0;
  edit(() => {
    if (S.meta.length < lo) S.meta.push(...Array.from({ length: lo - S.meta.length }, () => blankMeta()));
    S.meta.length = lo;
    ({ dropped } = S.score.appendScore(fresh));
    const add = S.score.nMeasures - lo;
    const ms = res.measures.slice(0, add).map((m) => ({ ...m, page: id }));
    while (ms.length < add) ms.push(blankMeta(id));
    S.meta.push(...ms);
    markPages();
  });
  const hadPhoto = !!S.job && !!pageInfo(S.job);
  syncPages();
  if (!hadPhoto) setupPhoto();
  const no = pageNumber(id);
  const hi = S.score.nMeasures - 1;
  if (res.quality && res.quality.level !== 'good') renderBanner(res.quality, id);
  toast(`Added page ${no}: bars ${barNumber(lo)}–${barNumber(hi)}${dropped ? `. That page had ${dropped} more part${dropped > 1 ? 's' : ''} than the score; ${dropped > 1 ? 'they were' : 'it was'} left out` : ''}.`, 3600);
  if (photoOpen()) showPhotoPage(id);
}

function movePage(id, dir) {
  const list = pageList();
  const i = list.findIndex((r) => r.id === id);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= list.length) return;
  const r = list[i];
  const dest = dir < 0 ? list[j].lo : list[j].hi + 1;
  edit(() => {
    S.score.moveBars(r.lo, r.hi, dest);
    const block = S.meta.splice(r.lo, r.hi - r.lo + 1);
    const at = dir < 0 ? dest : dest - block.length;
    S.meta.splice(at, 0, ...block);
    const order = Array.from({ length: S.meta.length }, (_, i) => i);
    order.splice(at, 0, ...order.splice(r.lo, r.hi - r.lo + 1));
    const to = new Map(order.map((old, i) => [old, i]));
    inkRemap((mi) => to.get(mi) ?? mi);
    markPages();
  });
  S.measures = new Set(); S.sel = null;
  syncPages();
  redraw();
}
function removePage(id) {
  const list = pageList();
  const r = list.find((x) => x.id === id);
  if (!r) return;
  if (list.length < 2) { toast('A score needs at least one page'); return; }
  edit(() => {
    S.score.deleteBars(r.lo, r.hi);
    S.meta.splice(r.lo, r.hi - r.lo + 1);
    ink.onDelete(S.score, r.lo, r.hi);
    markPages();
  });
  S.measures = new Set(); S.sel = null;
  syncPages();
  redraw();
  toast(`Removed page ${list.indexOf(r) + 1}. Undo brings it back.`);
}
// read a new photo of page `id` and put it in that page's place
function retakePage(id, file = null) {
  if (!file) { pickFile((f) => retakePage(id, f), 'image/*,.heic,.heif'); return; }
  const session = scoreSession;
  pageQueue = pageQueue.then(async () => {
    const r0 = pageList().find((x) => x.id === id);
    if (!r0) return;
    const no = pageNumber(id);
    setReading(`Reading the new photo of page ${no}…`);
    const fd = new FormData();
    fd.append('file', file, file.name || 'page.jpg');
    fd.append('detector', $('#optFast').checked ? '2m' : '28m');
    fd.append('context', JSON.stringify(rescanContext(S.score, r0.lo)));
    const { id: nid, result } = await readPage(fd, (st) => setReading(`Page ${no}: ${st.toLowerCase()}…`));
    setReading(null);
    if (session !== scoreSession) return;
    const r = pageList().find((x) => x.id === id);
    if (!r || !result.stats?.measures) { toast('No music was found in that photo; the page was kept.'); return; }
    const fresh = new Score(result.xml);
    S.pages[nid] = pageRec(nid, result, file.name);
    edit(() => {
      const targets = Array.from({ length: r.hi - r.lo + 1 }, (_, i) => r.lo + i);
      S.score.spliceMeasures(targets, fresh);
      const ms = result.measures.slice(0, fresh.nMeasures).map((m) => ({ ...m, page: nid }));
      while (ms.length < fresh.nMeasures) ms.push(blankMeta(nid));
      S.meta.splice(r.lo, targets.length, ...ms);
      // ink on the old reading of this page is dropped; ink on later pages moves with its bars
      const delta = ms.length - targets.length;
      inkRemap((mi) => (mi < r.lo ? mi : mi > r.hi ? mi + delta : null));
      markPages();
    });
    syncPages();
    if (S.photoPage === id) { S.photoPage = null; showPhotoPage(nid); }
    renderBanner(result.quality, nid);
    toast(`Page ${no} was read again from the new photo. Undo puts the old reading back.`, 3600);
  }).catch((e) => { setReading(null); toast('Could not read the new photo: ' + e.message, 5000); });
}
function pickFile(onFile, accept = 'image/*,.heic,.heif,.pdf', capture = false) {
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = accept;
  if (capture) inp.setAttribute('capture', 'environment');
  inp.onchange = () => { const f = inp.files[0]; if (f) onFile(f); };
  inp.click();
}
// "add a page" from the camera: the iOS document camera (any number of pages) or the browser's camera
async function addFromCamera() {
  if (native.isNative) {
    try {
      const f = await native.scanDocument();
      if (!f) return;
      addPages(f);
      for (const m of f.more || []) addPages(m);
    } catch (e) { toast(e.message); }
    return;
  }
  pickFile((f) => addPages(f), 'image/*', true);
}

// the page tabs over the photo: 1 2 3 … and + to add one
function drawPageTabs() {
  const box = $('#pageTabs');
  if (!box) return;
  const list = pageList();
  box.innerHTML = '';
  if (!S.score) return;
  if (list.length > 1) list.forEach((r, i) => {
    const b = document.createElement('button');
    b.textContent = String(i + 1);
    b.title = `Page ${i + 1}: bars ${barNumber(r.lo)}–${barNumber(r.hi)}`;
    b.disabled = !pageInfo(r.id);
    const bad = S.meta.slice(r.lo, r.hi + 1).some((m) => m.level === 'bad');
    b.className = (r.id === S.photoPage ? 'on ' : '') + (bad ? 'flag' : '');
    b.onclick = () => { showPhotoPage(r.id); scrollToBar(r.lo); };
    box.appendChild(b);
  });
  const add = document.createElement('button');
  add.className = 'add';
  add.textContent = '+ Page';
  add.title = 'Add the next page (a photo or a PDF)';
  add.onclick = () => pagesDialog();
  box.appendChild(add);
}
// "Page 2" over the first bar of every page after the first
function drawPageMarks() {
  clearOverlay('pagemark');
  const list = pageList();
  if (list.length < 2 || !S.layout) return;
  list.forEach((r, i) => {
    if (i === 0) return;
    const m = S.layout.measures[r.lo];
    if (!m) return;
    // a small tag at the right end of the line the page starts on (bar numbers sit at the left of each bar)
    const g = document.createElementNS(SVGNS, 'g');
    g.setAttribute('class', 'pagemark');
    const x1 = S.layout.width - 6, w = 52;
    const bg = document.createElementNS(SVGNS, 'rect');
    Object.entries({ x: x1 - w, y: m.y0 - 2, width: w, height: 18, rx: 9, fill: '#D8EAFC' }).forEach(([k, v]) => bg.setAttribute(k, v));
    const t = document.createElementNS(SVGNS, 'text');
    Object.entries({ x: x1 - w / 2, y: m.y0 + 11, 'text-anchor': 'middle', 'font-size': 11, 'font-weight': 600, fill: '#0F56A3' }).forEach(([k, v]) => t.setAttribute(k, v));
    t.textContent = `Page ${i + 1}`;
    g.append(bg, t);
    $('#overlay').appendChild(g);
  });
}

// the page manager: thumbnails in order, move up/down, retake, remove, add photos or a PDF
function pagesDialog() {
  const card = $('#modalCard');
  $('#modal').classList.remove('hidden');
  const draw = () => {
    const list = pageList();
    const rows = list.map((r, i) => {
      const pg = pageInfo(r.id);
      const ms = S.meta.slice(r.lo, r.hi + 1);
      const red = ms.filter((m) => m.level === 'bad').length, amber = ms.filter((m) => m.level === 'check').length;
      const flags = red || amber ? ` · ${red ? `${red} likely wrong` : ''}${red && amber ? ', ' : ''}${amber ? `${amber} to check` : ''}` : '';
      return `<div class="page-row" data-id="${r.id ?? ''}">
        <div class="page-thumb">${pg ? `<img alt="" src="${jobFile(r.id, 'page.png')}">` : '<span>♪</span>'}</div>
        <div class="page-info"><b>Page ${i + 1}</b><span class="muted">Bars ${barNumber(r.lo)}–${barNumber(r.hi)}${flags}${pg?.quality ? ` · photo ${pg.quality.score}/100` : ''}</span></div>
        <div class="page-btns">
          <button class="btn icon" data-pg="up" title="Move up" ${i === 0 ? 'disabled' : ''}>↑</button>
          <button class="btn icon" data-pg="down" title="Move down" ${i === list.length - 1 ? 'disabled' : ''}>↓</button>
          ${pg ? '<button class="btn" data-pg="retake" title="Read this page again from a new photo">Retake</button>' : ''}
          <button class="btn icon" data-pg="remove" title="Remove this page" ${list.length < 2 ? 'disabled' : ''}>✕</button>
        </div></div>`;
    }).join('');
    card.innerHTML = `<h2>Pages</h2>
      <p class="muted">Add the pages one at a time, in order, or a whole PDF. Bars are numbered straight through, and the key, time signature and clefs carry over from one page to the next. Playback and export cover every page.</p>
      <div class="page-list">${rows}</div>
      <div class="modal-actions">
        <button class="btn" data-pg="file">＋ Add a photo or PDF</button>
        <button class="btn" data-pg="camera">${native.isNative ? 'Scan pages' : 'Take a photo'}</button>
        <button class="btn primary" data-pg="close">Done</button>
      </div>`;
  };
  draw();
  card.onclick = (ev) => {
    const b = ev.target.closest('[data-pg]');
    if (!b || b.disabled) return;
    const a = b.dataset.pg;
    const row = b.closest('.page-row');
    const id = row ? (row.dataset.id || null) : null;
    if (a === 'close') { closeModal(); return; }
    if (a === 'file') { closeModal(); pickFile((f) => addPages(f)); return; }
    if (a === 'camera') { closeModal(); addFromCamera(); return; }
    if (a === 'retake') { closeModal(); retakePage(id); return; }
    if (a === 'up' || a === 'down') movePage(id, a === 'up' ? -1 : 1);
    if (a === 'remove') removePage(id);
    draw();
  };
}

// ---------------------------------------------------------------- wiring
function wire() {
  const drop = $('#drop');
  $('#fileInput').onchange = (e) => startUpload(e.target.files[0]);
  $('#cameraInput').onchange = (e) => startUpload(e.target.files[0]);
  // live photo check (web/js/capture.js) where the browser can show the camera; the iOS app keeps Apple's scanner
  if (!native.isNative && capture.available()) {
    $('#cameraInput').closest('label').addEventListener('click', (e) => {
      if (e.target.id === 'cameraInput') return; // the system-camera fallback clicks the input itself
      e.preventDefault();
      capture.open({ shot: (file) => startUpload(file), fallback: () => $('#cameraInput').click() });
    });
  }
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
        await startUpload(f);
        // the other pages of a multi-page scan are read after the first and added in order
        if (S.score && f.more?.length) for (const m of f.more) addPages(m);
      } catch (err) { toast(err.message); }
    });
    const srv = document.createElement('button');
    srv.className = 'btn ghost server-link';
    srv.textContent = `Server: ${location.host} · Change`;
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
    // Ink mode: the Pencil draws and never scrolls; a finger draws too until a Pencil has been used, then it scrolls
    if (S.mode === 'ink') { if (t.touchType === 'stylus' || !S.penSeen) e.preventDefault(); return; }
    const h = hitTest(x, y, true);
    if (h && (h.type === 'note' || S.mode === 'add')) e.preventDefault();
  }, { passive: false });
  // and once a note drag is under way the page must not start scrolling under the finger
  sc.addEventListener('touchmove', (e) => { if (S.drag || S.stroke) e.preventDefault(); }, { passive: false });
  sc.addEventListener('pointerdown', onPointerDown);
  sc.addEventListener('pointermove', onPointerMove);
  sc.addEventListener('pointerup', onPointerUp);
  sc.addEventListener('pointercancel', onPointerUp);
  sc.addEventListener('pointerleave', () => { clearOverlay('ghost'); clearOverlay('inkcursor'); });
  document.addEventListener('keydown', onKey);

  for (const b of $$('[data-mode]')) b.onclick = () => setMode(b.dataset.mode);
  for (const b of $$('[data-dur]')) b.onclick = () => setDur(b.dataset.dur);
  for (const b of $$('[data-acc]')) b.onclick = () => setAcc(+b.dataset.acc);
  $('[data-act="dot"]').onclick = toggleDot;
  $('[data-act="rest"]').onclick = makeRest;
  $('[data-act="tie"]').onclick = tie;
  $('[data-act="tuplet"]').onclick = () => tuplet(3);
  $('#btnBar').onclick = (e) => { e.stopPropagation(); openBarMenu(e.currentTarget); };
  for (const b of $$('#barMenu button')) b.onclick = (e) => { e.stopPropagation(); barAction(b.dataset.bar); };
  $('[data-act="delete"]').onclick = del;
  for (const b of $$('[data-pen]')) b.onclick = () => setPen(b.dataset.pen);
  $('[data-act="ink-clear"]').onclick = clearInk;
  $('[data-act="ink-done"]').onclick = () => setMode('select');
  $('#btnInkVis').onclick = () => setInkHidden(!S.inkHidden);
  $('#btnMarks').onclick = (e) => { e.stopPropagation(); openMarksMenu(e.currentTarget); };
  $('#marksMenu').onclick = (e) => { e.stopPropagation(); const b = e.target.closest('button[data-mk]'); if (b && !b.disabled) markAction(b.dataset.mk, b.dataset.v); };
  $('#btnRescan').onclick = () => rescan(0);
  $('#btnKeyTime').onclick = keyTimeDialog;
  $('#btnPages').onclick = pagesDialog;
  $('#inspRescan').onclick = () => { if (S.focus >= 0 && !S.measures.has(S.focus)) S.measures = new Set([S.focus]); rescan(0); };
  $('#inspClose').onclick = hideInspector;
  $('#btnPhoto').onclick = () => { $('#photoCol').classList.toggle('closed'); setTimeout(() => { redraw(); if (S.focus >= 0) focusBar(S.focus, false); }, 0); };
  for (const b of $$('[data-ph]')) b.onclick = () => setPhotoKind(b.dataset.ph);
  $('#zoomIn').onclick = () => { S.autoZoom = false; S.zoom = Math.min(1.6, +(S.zoom + 0.1).toFixed(2)); redraw(); };
  $('#zoomOut').onclick = () => { S.autoZoom = false; S.zoom = Math.max(0.5, +(S.zoom - 0.1).toFixed(2)); redraw(); };
  $('#photoClose').onclick = () => { $('#photoCol').classList.add('closed'); redraw(); if (S.focus >= 0) focusBar(S.focus, false); };
  for (const b of $$('[data-dur]')) b.querySelector('.g').innerHTML = noteIcon(b.dataset.dur);
  $('#btnUndo').onclick = undo;
  $('#btnKeys').onclick = showShortcuts;
  $('#btnRedo').onclick = redo;
  $('#btnPlay').onclick = togglePlay;
  $('#btnLoop').onclick = toggleLoop;
  $('#btnPractice').onclick = (e) => { e.stopPropagation(); practice.toggle(); };
  practice.init({ tempoField: (b) => { $('#tempo').value = b; }, toast: (m) => toast(m, 1400) });
  $('#tempo').addEventListener('input', () => { const b = +$('#tempo').value; if (b >= 30 && b <= 240) practice.setBpm(b, true); });
  $('#tempo').addEventListener('change', () => practice.setBpm(+$('#tempo').value || 90));
  $('#btnNew').onclick = () => { stopPlay(); show('viewUpload'); loadResume(); };
  // iPad app: ⌘ shortcuts from a hardware keyboard (listed when you hold ⌘) and Apple Pencil double-tap
  native.onCommand((cmd) => {
    const editing = !$('#viewEditor').classList.contains('hidden');
    if (cmd === 'new') return $('#btnNew').click();
    if (cmd === 'scan') return $('#cameraInput').closest('label').click();
    if (!editing) return;
    if (cmd === 'undo') undo();
    else if (cmd === 'redo') redo();
    else if (cmd === 'play') togglePlay();
    else if (cmd === 'export-xml') exportAs('xml');
    else if (cmd === 'export-mid') exportAs('mid');
    else if (cmd === 'mode-select') setMode('select');
    else if (cmd === 'mode-add') setMode('add');
    else if (cmd === 'mode-ink') setMode(S.mode === 'ink' ? 'select' : 'ink');
    // Pencil double-tap: in Ink mode it swaps pen and eraser (as in Notes); otherwise Select <-> Add notes
    else if (cmd === 'toggle-mode' && S.mode === 'ink') { setPen(S.eraser ? S.inkPen : 'eraser'); toast(S.eraser ? 'Eraser' : 'Pen', 900); }
    else if (cmd === 'toggle-mode') { setMode(S.mode === 'add' ? 'select' : 'add'); toast(S.mode === 'add' ? 'Add notes' : 'Select', 900); }
    else if (cmd === 'zoom-in') $('#zoomIn').click();
    else if (cmd === 'zoom-out') $('#zoomOut').click();
    else if (cmd === 'photo') $('#btnPhoto').click();
  });
  $('#btnExport').onclick = (e) => { e.stopPropagation(); $('#exportMenu').classList.toggle('open'); };
  for (const b of $$('#exportMenu button')) b.onclick = () => exportAs(b.dataset.x);
  document.addEventListener('click', closeMenus);
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
  flushSave();
  let last = null;
  try { last = JSON.parse(localStorage.getItem(LS_KEY) || 'null'); } catch (e) { last = null; }
  $('#resume')?.remove();
  $('#viewUpload').scrollTop = 0;
  library.flush().then(renderLibrary);
  if (!last?.xml || document.body.classList.contains('has-library')) return;
  const b = document.createElement('button');
  b.id = 'resume';
  b.className = 'btn';
  b.textContent = `↺ Continue editing ${last.name || 'your last score'}`;
  b.onclick = () => {
    S.openLib = last.libId || null;
    S.name = last.name || 'score';
    S.result = last.result ? { ...last.result, xml: last.xml } : null;
    try { openScore(last.xml, last.meta, last.result?.quality, last.job, last.pages); } catch (e) { toast(e.message); }
  };
  $('.upload-row').appendChild(b);
}

// ---------------------------------------------------------------- Your music (web/js/library.js)
const STAFF_ART = `<svg viewBox="0 0 120 80" preserveAspectRatio="none" aria-hidden="true"><g stroke="#B9D9F7" stroke-width="1.2"><path d="M8 14h104M8 19h104M8 24h104M8 29h104M8 34h104M8 48h104M8 53h104M8 58h104M8 63h104M8 68h104"/></g><g fill="#5FAEEB"><circle cx="30" cy="29" r="3"/><circle cx="50" cy="24" r="3"/><circle cx="70" cy="19" r="3"/><circle cx="90" cy="24" r="3"/><circle cx="30" cy="63" r="3"/><circle cx="70" cy="58" r="3"/></g></svg>`;
let libFilter = 'all';
async function renderLibrary() {
  const box = $('#library');
  if (!box) return;
  let items = [];
  try { items = await library.list(); } catch (e) { items = []; }
  document.body.classList.toggle('has-library', items.length > 0);
  if (items.length) $('#resume')?.remove();
  box.classList.toggle('hidden', !items.length);
  if (!items.length) return;
  const toCheck = items.filter((e) => library.summary(e).status.kind !== 'ok').length;
  const shown = libFilter === 'check' ? items.filter((e) => library.summary(e).status.kind !== 'ok') : items;
  box.innerHTML = `<div class="lib-head"><h2>Your music</h2>
    <div class="lib-tabs" role="tablist"><button role="tab" data-f="all" aria-selected="${libFilter === 'all'}">All <span>${items.length}</span></button><button role="tab" data-f="check" aria-selected="${libFilter === 'check'}">To check <span>${toCheck}</span></button></div></div>
    <div class="lib-grid"></div>`;
  for (const t of box.querySelectorAll('[data-f]')) t.onclick = () => { libFilter = t.dataset.f; renderLibrary(); };
  const grid = box.querySelector('.lib-grid');
  if (!shown.length) grid.innerHTML = '<p class="lib-empty">Nothing to check. Every score is ready to play.</p>';
  for (const e of shown) {
    const sm = library.summary(e);
    const card = document.createElement('div');
    card.className = 'lib-card';
    card.dataset.id = e.id;
    card.innerHTML = `<button class="lib-open"><span class="lib-thumb"></span><span class="lib-title"></span><span class="lib-meta"></span><span class="lib-status ${sm.status.kind}">${sm.status.text}</span></button>
      <button class="lib-del" aria-label="Remove from Your music"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>`;
    card.querySelector('.lib-title').textContent = (e.name || 'Score').replace(/\.(jpe?g|png|heic|heif|pdf|musicxml|xml)$/i, '').replace(/^\d+_/, '').replace(/_/g, ' ');
    card.querySelector('.lib-meta').textContent = [`${sm.bars} bars`, sm.pages > 1 ? `${sm.pages} pages` : '', library.when(e.t)].filter(Boolean).join(' · ');
    const th = card.querySelector('.lib-thumb');
    if (e.job) { const im = new Image(); im.alt = ''; im.loading = 'lazy'; im.onerror = () => { th.innerHTML = STAFF_ART; }; im.src = jobFile(e.job, 'page.png'); th.appendChild(im); } else th.innerHTML = STAFF_ART;
    card.querySelector('.lib-open').onclick = () => openFromLibrary(e.id);
    const del = card.querySelector('.lib-del');
    del.onclick = async () => {
      if (!card.classList.contains('confirm')) { card.classList.add('confirm'); del.setAttribute('aria-label', 'Tap again to remove'); setTimeout(() => card.classList.remove('confirm'), 3000); return; }
      await library.remove(e.id);
      if (lsGet(LS_KEY)?.includes(`"libId":"${e.id}"`)) { try { localStorage.removeItem(LS_KEY); } catch (err) { /* blocked */ } }
      renderLibrary();
      toast(`Removed ${card.querySelector('.lib-title').textContent}`);
    };
    grid.appendChild(card);
  }
}
async function openFromLibrary(id) {
  const e = await library.get(id);
  if (!e) return renderLibrary();
  S.openLib = e.id;
  S.name = e.name || 'score';
  S.result = e.result ? { ...e.result, xml: e.xml } : null;
  try { openScore(e.xml, e.meta, e.result?.quality, e.job, e.pages); } catch (err) { toast(err.message); }
}

const NI = createNoteInput({
  S, act, redraw, toast, selected, stepSel, scrollToBar, noteX, barNumber, metaInsert,
  preview: (midis) => midis.forEach((m, i) => setTimeout(() => audio.preview(m), i * 25)),
});
var PAD = createPad(NI, { S, setDur, makeRest, stepSel, del });
installZoom({
  S, redraw,
  // a second finger turns a note drag (or a note being placed) into a pinch: put back anything the drag changed
  cancelDrag: () => {
    if (!S.drag) return;
    const pushed = S.drag.pushed;
    S.drag = null;
    clearOverlay('ghost'); clearOverlay('drag');
    if (pushed) { S.redo = []; restore(S.undo.pop()); }
  },
});

wire();
pbar.init({ stop: () => stopPlay(), toggleLoop, isLoop: () => !!S.loop, bars: () => S.score?.nMeasures || 0, label: (mi) => barNumber(mi) });
addEventListener('pagehide', () => library.flush());
review.initReview({
  S, redraw, edit, toast, setMode, scrollToBar, scrollPhotoTo, rescan, pageOf: (mi) => pageInfo(pageIdOf(mi)), stopPlay, drawCursor, clearOverlay, barNumber, barReason, subScoreXML,
  haptic: native.haptic,
  // one bar at a time: the practice tempo, instruments and mutes, but no count-in, click or speed-up
  playEvents: () => { const pe = S.score.playEvents(); for (const e of pe.events) e.track = practice.trackOf(e); return pe; },
  playOptions: () => ({ ...practice.playOptions(false), countIn: 0, metronome: false, speedUp: null, onCount: () => {} }),
  showPhoto: (mi) => { if (!S.job) return; $('#photoCol').classList.remove('closed'); setTimeout(() => { redraw(); scrollPhotoTo(mi); }, 0); },
});
loadSamples();
show('viewUpload');
// for automated tests
window.__ms = { S, audio, practice, library, renderLibrary, openScore: (xml, meta) => { S.name = 'test.musicxml'; openScore(xml, meta || [], null, null); }, redraw };
