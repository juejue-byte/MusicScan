// "Fix it": a review mode that steps through the flagged bars one at a time. At each flag it plays just that bar,
// shows the bar from the photo beside the reading, says why it was flagged, and offers one-tap answers:
// Looks right (Enter), Edit in place (E), Rescan the row, or the second reading when the two models disagreed.
// It drives the existing editor (selection, edit/undo, rescan dialog); it does not edit notes itself.
import { Score } from './score.js';
import { render, layoutRows, ROW_PAD_TOP, ROW_PAD_BOTTOM, STAFF_GAP } from './render.js';
import * as audio from './audio.js';
import { jobFile } from './demo.js';

const $ = (s) => document.querySelector(s);
let A = null;            // the app's hooks (see initReview)
const R = { on: false, cur: -1, editing: false, img: null, imgJob: null, alt: null, altFor: null, drawn: '', raf: 0, autoplay: true };

/** Bars that are flagged, or were flagged and the user has checked. In score order. */
export function flagged(meta) {
  const out = [];
  meta.forEach((m, i) => { if (m && (m.reviewed || (m.level && m.level !== 'ok'))) out.push(i); });
  return out;
}
const isOpen = (mi) => { const m = A.S.meta[mi]; return !!m && !m.reviewed && m.level && m.level !== 'ok'; };
const wasLevel = (m) => (m.reviewed ? m.flag || 'check' : m.level);

export function isActive() { return R.on; }

export function start(from = null) {
  const S = A.S;
  if (!S.score) return;
  const list = flagged(S.meta);
  if (!list.length) { A.toast('No flagged bars. Every bar was read with confidence.'); return; }
  R.on = true;
  R.editing = false;
  document.body.classList.add('reviewing');
  $('#review').classList.remove('hidden');
  $('#inspector').classList.add('hidden');
  if (S.mode === 'add') A.setMode('select');
  const firstOpen = list.find(isOpen);
  go(from ?? firstOpen ?? list[0], { play: false });
}

export function stop() {
  if (!R.on) return;
  R.on = false;
  R.editing = false;
  audio.stop();
  A.clearOverlay('cursor');
  document.body.classList.remove('reviewing');
  $('#review').classList.add('hidden');
  updateButton();
}

function go(mi, { play = R.autoplay } = {}) {
  const S = A.S;
  if (mi == null || mi < 0 || mi >= S.score.nMeasures) return;
  R.cur = mi;
  R.editing = false;
  R.drawn = '';
  S.sel = null;
  S.measures = new Set([mi]);
  S.focus = mi;
  A.redraw();
  A.scrollToBar(mi);
  A.scrollPhotoTo(mi);
  if (play) playBar();
}

function step(dir) {
  const list = flagged(A.S.meta);
  if (!list.length) return;
  let i = list.findIndex((x) => (dir > 0 ? x > R.cur : x >= R.cur));
  if (dir > 0) { if (i < 0) i = 0; } else { i = (i < 0 ? list.length : i) - 1; if (i < 0) i = list.length - 1; }
  go(list[i]);
}

// the next bar still to check after the current one (wrapping), or null when all are done
function nextOpen() {
  const list = flagged(A.S.meta);
  return list.find((x) => x > R.cur && isOpen(x)) ?? list.find(isOpen) ?? null;
}

function accept() {
  const S = A.S;
  const mi = R.cur;
  const m = S.meta[mi];
  if (!m) return;
  if (m.reviewed) { // already checked: Enter just moves on
    const n = nextOpen();
    if (n === null) { refresh(true); return; }
    go(n);
    return;
  }
  A.edit(() => { m.flag = m.level; m.reviewed = true; m.level = 'ok'; });
  A.haptic('success');
  const n = nextOpen();
  if (n === null) { R.drawn = ''; refresh(true); A.toast('All flagged bars checked.'); return; }
  go(n);
}

function unmark() {
  const m = A.S.meta[R.cur];
  if (!m?.reviewed) return;
  A.edit(() => { m.level = m.flag || 'check'; delete m.reviewed; delete m.flag; });
}

function editInPlace() {
  const S = A.S;
  const mi = R.cur;
  const notes = (S.layout?.notes || []).filter((n) => !n.ghost && n.ev.mi === mi).sort((a, b) => a.staffIdx - b.staffIdx || a.ev.onset - b.ev.onset);
  R.editing = true;
  S.sel = notes.find((n) => !n.ev.rest)?.ev.el || notes[0]?.ev.el || null;
  S.measures = new Set([mi]);
  A.setMode('select');
  A.redraw();
  A.scrollToBar(mi);
  A.toast(S.touch ? 'Edit the bar in the score, then tap Done.' : 'Edit the bar in the score (arrows, 1–6, R…), then press Enter.', 3000);
}

function rescanBar() {
  const S = A.S;
  if (!S.job) { A.toast('Rescan needs the photo; this score was opened from a file.'); return; }
  S.sel = null;
  S.measures = new Set([R.cur]);
  A.rescan(0);
}

// ---------------------------------------------------------------- the second reading (small model)
// the reading a bar came from: its page's (multi-page scores), else the score's own
const pageOf = (mi) => (A.pageOf && A.pageOf(mi)) || A.S.result || null;
function altScore(mi) {
  const so = pageOf(mi)?.second_opinion;
  if (!so?.xml) return null;
  if (R.altFor !== so.xml) { R.altFor = so.xml; try { R.alt = new Score(so.xml); } catch (e) { R.alt = null; } }
  return R.alt;
}
// the second reading of bar mi as its own little score, when it can still be lined up with ours
function altBar(mi) {
  const S = A.S;
  const m = S.meta[mi];
  if (!m?.disagree || m.index == null) return null;
  if (S.meta.filter((x) => x?.index === m.index && x?.disagree).length !== 1) return null; // split or duplicated since
  const alt = altScore(mi);
  if (!alt || m.index >= alt.nMeasures || alt.parts.length !== S.score.parts.length) return null;
  try { return new Score(A.subScoreXML(alt, [m.index])); } catch (e) { return null; }
}
function useAlt() {
  const S = A.S;
  const mi = R.cur;
  const sub = altBar(mi);
  if (!sub) return;
  const m = S.meta[mi];
  A.edit(() => {
    S.score.spliceMeasures([mi], sub);
    S.meta[mi] = { ...m, disagree: false, flag: m.level, reviewed: true, level: 'ok', used: 'second' };
  });
  A.toast('Using the second reading for this bar. Undo with Ctrl+Z.');
  R.drawn = '';
  playBar();
}

// ---------------------------------------------------------------- play just this bar
function playBar() {
  const S = A.S;
  const mi = R.cur;
  if (!S.score || mi < 0) return;
  A.stopPlay();
  const bpm = Math.max(30, Math.min(240, +$('#tempo').value || 90));
  $('#rvPlay')?.classList.add('on');
  const pe = A.playEvents ? A.playEvents() : S.score.playEvents();
  audio.play(pe, {
    bpm, ...(A.playOptions ? A.playOptions() : {}), fromMeasure: mi, toMeasure: mi, loop: false,
    onMeasure: (m) => A.drawCursor(m),
    onEnd: () => { A.clearOverlay('cursor'); $('#rvPlay')?.classList.remove('on'); },
  }).catch(() => {});
}

// ---------------------------------------------------------------- drawing the panel
function pageImage(mi) {
  const job = pageOf(mi)?.job || A.S.job;
  if (!job) return null;
  if (R.imgJob !== job) {
    R.imgJob = job;
    R.img = new Image();
    R.img.onload = () => { R.drawn = ''; refresh(); };
    R.img.src = jobFile(job, 'page.png');
  }
  return R.img.complete && R.img.naturalWidth ? R.img : null;
}

function drawCrop(canvas, mi, maxW, maxH) {
  const S = A.S;
  const m = S.meta[mi];
  const img = pageImage(mi);
  const pg = pageOf(mi);
  if (!img || !m?.bbox || m.bbox[2] <= m.bbox[0] || !pg?.page_size) return false;
  // page.png may be stored smaller than page_size (the demo keeps a jpg): scale boxes to the image
  const k = img.naturalWidth / pg.page_size[0];
  const sys = (pg.systems || []).find((s) => s.measures?.includes(m.index ?? mi)) || { bbox: m.bbox };
  const padX = 60, padY = 26;
  const x0 = Math.max(0, (m.bbox[0] - padX) * k), x1 = Math.min(img.naturalWidth, (m.bbox[2] + padX) * k);
  const y0 = Math.max(0, (Math.min(sys.bbox[1], m.bbox[1]) - padY) * k), y1 = Math.min(img.naturalHeight, (Math.max(sys.bbox[3], m.bbox[3]) + padY) * k);
  const sw = x1 - x0, sh = y1 - y0;
  const scale = Math.min(maxW / sw, maxH / sh, 2.2);
  const cw = Math.round(sw * scale), ch = Math.round(sh * scale);
  const dpr = window.devicePixelRatio || 1;
  canvas.width = cw * dpr; canvas.height = ch * dpr;
  canvas.style.width = cw + 'px'; canvas.style.height = ch + 'px';
  const g = canvas.getContext('2d');
  g.setTransform(dpr * scale, 0, 0, dpr * scale, 0, 0);
  g.drawImage(img, x0, y0, sw, sh, 0, 0, sw, sh);
  const lvl = wasLevel(m);
  const col = m.reviewed ? '#16a34a' : lvl === 'bad' ? '#dc2626' : '#d97706';
  g.strokeStyle = col; g.lineWidth = 2.5 / scale;
  g.strokeRect(m.bbox[0] * k - x0, m.bbox[1] * k - y0 - 8, (m.bbox[2] - m.bbox[0]) * k, (m.bbox[3] - m.bbox[1]) * k + 16);
  // the symbols the reader was unsure of, underlined
  g.fillStyle = col; g.globalAlpha = 0.75;
  for (const b of m.low || []) g.fillRect(b[0] * k - x0, b[3] * k - y0 + 2, Math.max(4, (b[2] - b[0]) * k), 3 / scale);
  g.globalAlpha = 1;
  return true;
}

function drawBar(el, sub, maxW, maxH) {
  try {
    // same height as the photo crop, so the two read side by side
    const { rows, staves } = layoutRows(sub, 99999);
    const natural = (rows[0]?.reduce((a, m) => a + m.w, 0) || 260) + 30;
    const h = ROW_PAD_TOP + (staves.length - 1) * STAFF_GAP + 40 + ROW_PAD_BOTTOM + 20;
    const zoom = Math.max(0.45, Math.min(1, maxH / h, maxW / natural));
    const L = render(sub, el, { width: Math.max(160, Math.min(maxW, natural * zoom * 1.1)), zoom });
    // render() draws at least 300 px wide: shrink to the column when it is narrower (three pictures on an iPad)
    const svg = el.querySelector('svg');
    if (svg && L.pxWidth > maxW) {
      const H = L.height * L.zoom;
      svg.setAttribute('viewBox', `0 0 ${L.pxWidth} ${H}`);
      const h = Math.round(H * maxW / L.pxWidth);
      svg.setAttribute('width', maxW); svg.setAttribute('height', h);
      svg.style.width = maxW + 'px'; svg.style.height = h + 'px';
    }
  } catch (e) { el.textContent = 'Could not draw this bar'; }
}

function reasonText(m) {
  return A.barReason(m.reviewed ? { ...m, level: m.flag || 'check' } : m);
}

function refresh(done = false) {
  if (!R.on) return;
  const S = A.S;
  const list = flagged(S.meta);
  if (!list.length) { stop(); return; }
  if (!list.includes(R.cur) && !done) {
    // the bar under review is no longer flagged (e.g. a rescan read it with confidence): stay on it so the user sees it
    if (R.cur >= S.score.nMeasures) R.cur = list[list.length - 1];
  }
  const mi = R.cur;
  const m = S.meta[mi] || {};
  const checked = list.filter((i) => S.meta[i].reviewed).length;
  const all = checked === list.length;
  const pos = list.indexOf(mi);
  $('#rvCount').textContent = innerWidth < 700 ? `${checked}/${list.length}` : `${checked} of ${list.length} checked`;
  $('#rvMeter').style.width = (100 * checked / list.length) + '%';
  $('#rvPos').textContent = pos >= 0 ? `Flag ${pos + 1} of ${list.length}` : '';
  const lvl = wasLevel(m);
  const badge = $('#rvBadge');
  badge.className = 'rv-badge ' + (m.reviewed ? 'ok' : m.level === 'ok' ? 'ok' : lvl);
  badge.textContent = m.reviewed ? (m.used === 'second' ? '✓ Second reading used' : '✓ Checked') : m.level === 'ok' ? '✓ Now reads clearly' : lvl === 'bad' ? 'Likely wrong' : 'Worth a look';
  $('#rvBar').textContent = `Bar ${A.barNumber(mi)}`;
  $('#rvWhy').textContent = all ? 'All flagged bars are checked. You can still step through them, or close Fix it.' : capital(reasonText(m)) + (m.low_n ? '. Unsure symbols are underlined in the photo.' : '.');
  // actions
  const acc = $('#rvAccept');
  acc.innerHTML = m.reviewed ? (all ? '✓ All checked' : 'Next unchecked <kbd>↵</kbd>') : R.editing ? '✓ Done, next <kbd>↵</kbd>' : '✓ Looks right <kbd>↵</kbd>';
  acc.disabled = m.reviewed && all;
  $('#rvUnmark').classList.toggle('hidden', !m.reviewed);
  $('#rvRescan').disabled = !S.job;
  $('#rvEdit').classList.toggle('on', R.editing);
  const sub2 = altBar(mi);
  $('#rvUseAlt').classList.toggle('hidden', !sub2 || !!m.reviewed);
  document.querySelector('#review').classList.toggle('editing', R.editing);
  // pictures: only when the bar or its reading changed (refresh runs on every redraw)
  const key = [mi, S.score.parts.map((p) => p.measures[mi]?.outerHTML || '').join('|'), !!pageImage(mi), !!sub2, R.editing, innerWidth].join('#');
  if (key === R.drawn) return;
  R.drawn = key;
  const box = $('#rvPics');
  const w = box.clientWidth || 900;
  const cols = (sub2 ? 3 : 2) - (R.editing ? 1 : 0);
  const colW = innerWidth < 700 ? w - 8 : Math.floor((w - 16 * (cols - 1)) / cols);
  const maxH = innerWidth < 700 ? 110 : 150;
  const has = drawCrop($('#rvCrop'), mi, colW, maxH);
  $('#rvPhotoBox').classList.toggle('hidden', !has);
  $('#rvReadBox').classList.toggle('hidden', R.editing && has);
  if (!(R.editing && has)) drawBar($('#rvRead'), new Score(A.subScoreXML(S.score, [mi])), colW, maxH + 20);
  $('#rvAltBox').classList.toggle('hidden', !sub2 || (R.editing && has));
  if (sub2 && !(R.editing && has)) drawBar($('#rvAlt'), sub2, colW, maxH + 20);
}
const capital = (s) => (s ? s[0].toUpperCase() + s.slice(1) : s);

/** Number of flags still to check, shown on the Fix it button. */
export function updateButton() {
  const S = A.S;
  const list = S.score ? flagged(S.meta) : [];
  const open = list.filter(isOpen).length;
  for (const b of document.querySelectorAll('.fix-btn')) {
    b.disabled = !list.length;
    b.classList.toggle('on', R.on);
    b.classList.toggle('done', !!list.length && !open);
    b.querySelector('.n').textContent = list.length ? (open ? String(open) : '✓') : '';
    b.title = list.length ? (open ? `Fix it: check the ${open} flagged bar${open > 1 ? 's' : ''} one by one (F)` : 'Every flagged bar is checked (F to step through them again)') : 'No flagged bars';
  }
}

/** Called after every redraw of the score. */
export function afterRedraw() {
  updateButton();
  if (!R.on) return;
  cancelAnimationFrame(R.raf);
  R.raf = requestAnimationFrame(() => refresh());
}

function onKey(e) {
  if (!A.S.score || $('#viewEditor').classList.contains('hidden') || !$('#modal').classList.contains('hidden')) return;
  if (e.target.closest?.('input, textarea, select') || e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key;
  // F is also a note name: in note input, or with a note selected, the letter belongs to the editor
  const letterForEditor = A.S.mode === 'add' || (!!A.S.sel && !R.on);
  if (!R.on) {
    if ((k === 'f' || k === 'F') && !e.shiftKey && !letterForEditor) { e.preventDefault(); e.stopImmediatePropagation(); start(); }
    return;
  }
  const take = () => { e.preventDefault(); e.stopImmediatePropagation(); };
  // note letters belong to the editor in note input, and while editing a selected note of the bar (E and F too)
  if ((A.S.mode === 'add' || A.S.sel) && /^[a-gA-G]$/.test(k)) return;
  if (k === 'Enter') { take(); accept(); }
  else if (k === ']' || k === 'PageDown') { take(); step(1); }
  else if (k === '[' || k === 'PageUp') { take(); step(-1); }
  else if (k === 'p' || k === 'P') { take(); playBar(); }
  else if (k === 'e' || k === 'E') { take(); editInPlace(); }
  else if (k === 'f' || k === 'F') { take(); stop(); }
  else if (k === 'Escape' && !A.S.sel && A.S.mode !== 'add') { take(); stop(); }
}

/**
 * hooks: { S, redraw, edit, toast, setMode, scrollToBar, scrollPhotoTo, rescan, stopPlay, drawCursor, clearOverlay,
 *          barNumber, barReason, subScoreXML, haptic, showPhoto, playEvents?, playOptions? }
 */
export function initReview(hooks) {
  A = hooks;
  for (const b of document.querySelectorAll('.fix-btn')) b.onclick = () => (R.on ? stop() : start());
  $('#rvClose').onclick = stop;
  $('#rvPrev').onclick = () => step(-1);
  $('#rvNext').onclick = () => step(1);
  $('#rvAccept').onclick = accept;
  $('#rvUnmark').onclick = unmark;
  $('#rvEdit').onclick = () => (R.editing ? (R.editing = false, R.drawn = '', refresh()) : editInPlace());
  $('#rvRescan').onclick = rescanBar;
  $('#rvPlay').onclick = playBar;
  $('#rvUseAlt').onclick = useAlt;
  const ap = $('#rvAuto');
  try { R.autoplay = localStorage.getItem('musicscan:review-autoplay') !== '0'; } catch (e) { /* storage blocked */ }
  ap.checked = R.autoplay;
  ap.onchange = () => { R.autoplay = ap.checked; try { localStorage.setItem('musicscan:review-autoplay', ap.checked ? '1' : '0'); } catch (e) { /* storage blocked */ } };
  // the photo crop opens the full photo panel at that bar
  $('#rvPhotoBox').onclick = () => { A.showPhoto?.(R.cur); };
  document.addEventListener('keydown', onKey, true);
  // iPad hardware-keyboard ⌘ shortcuts from the app shell (ios/): review commands, everything else to the editor
  const prev = window.__msCommand;
  window.__msCommand = (cmd) => {
    if (cmd === 'review') return R.on ? stop() : start();
    if (cmd === 'review-next') return R.on ? step(1) : start();
    if (cmd === 'review-prev') return R.on ? step(-1) : start();
    if (cmd === 'review-accept') return R.on && accept();
    return prev && prev(cmd);
  };
  window.__msReview = { start, stop, isActive, state: R, flagged: () => flagged(A.S.meta) };
}
