// Freehand ink (Apple Pencil, mouse or finger) on its own layer, apart from the notes.
//
// Strokes are kept inside the MusicXML itself, as JSON in
//   <identification><miscellaneous><miscellaneous-field name="musicscan-ink">
// so they are saved, undone and exported with the score, other apps ignore them, and reopening an exported file
// brings the ink back. Each stroke is pinned to the bar it starts in: x as a fraction of that bar's width, y in
// pixels from the bar's top, so ink follows its bar when the score reflows on another screen width or zoom.
const SVGNS = 'http://www.w3.org/2000/svg';
const FIELD = 'musicscan-ink';
export const PENS = [
  { id: 'red', tool: 'pen', color: '#dc2626', label: 'Red pen' },
  { id: 'blue', tool: 'pen', color: '#2563eb', label: 'Blue pen' },
  { id: 'graphite', tool: 'pen', color: '#374151', label: 'Pencil' },
  { id: 'hl', tool: 'hl', color: '#facc15', label: 'Highlighter' },
];
const HEADER_BEFORE = ['defaults', 'credit', 'part-list'];

function field(score, create) {
  const root = score.root;
  let ident = [...root.children].find((c) => c.localName === 'identification');
  if (!ident) {
    if (!create) return null;
    ident = score.doc.createElement('identification');
    const before = [...root.children].find((c) => HEADER_BEFORE.includes(c.localName) || c.localName === 'part');
    root.insertBefore(ident, before || null);
  }
  let misc = [...ident.children].find((c) => c.localName === 'miscellaneous');
  if (!misc) {
    if (!create) return null;
    misc = score.doc.createElement('miscellaneous');
    ident.appendChild(misc); // the last child of <identification>
  }
  let f = [...misc.children].find((c) => c.localName === 'miscellaneous-field' && c.getAttribute('name') === FIELD);
  if (!f && create) {
    f = score.doc.createElement('miscellaneous-field');
    f.setAttribute('name', FIELD);
    misc.appendChild(f);
  }
  return f;
}

/** The strokes of a score: [{ mi, tool: 'pen'|'hl', c: color, w: width, p: [[u, v, pressure], ...] }] */
export function strokes(score) {
  const f = field(score, false);
  if (!f) return [];
  try { const d = JSON.parse(f.textContent); return Array.isArray(d.strokes) ? d.strokes : []; } catch (e) { return []; }
}
export function setStrokes(score, list) {
  if (!list.length) {
    const f = field(score, false);
    if (f) {
      const misc = f.parentNode, ident = misc.parentNode;
      f.remove();
      if (!misc.children.length) misc.remove();
      if (!ident.children.length) ident.remove();
    }
    return;
  }
  field(score, true).textContent = JSON.stringify({ v: 1, strokes: list });
}
export const hasInk = (score) => strokes(score).length > 0;

// ---------------------------------------------------------------- bar anchors
/** The bar a point belongs to, and the point in that bar's terms. */
export function anchor(layout, x, y) {
  let row = layout.rows.find((r) => y >= r.y0 && y < r.y1);
  if (!row) row = y < layout.rows[0].y0 ? layout.rows[0] : layout.rows[layout.rows.length - 1];
  const ms = row.measures;
  const m = ms.find((q) => x >= q.x0 && x < q.x1) || (x < ms[0].x0 ? ms[0] : ms[ms.length - 1]);
  return { mi: m.mi, m };
}
const toLocal = (m, x, y) => [+((x - m.x0) / Math.max(1, m.x1 - m.x0)).toFixed(4), +(y - m.y0).toFixed(1)];
function toPage(m, u, v) { return [m.x0 + u * (m.x1 - m.x0), m.y0 + v]; }

/** Keep ink on its bars when bars are split, joined, inserted or deleted (indexes as in edits.js). */
export function onSplit(score, mi, frac) {
  frac = Math.min(0.95, Math.max(0.05, frac));
  shift(score, (s) => {
    if (s.mi < mi) return s;
    if (s.mi > mi) return { ...s, mi: s.mi + 1 };
    const u0 = s.p[0][0];
    if (u0 < frac) return { ...s, p: s.p.map(([u, v, q]) => [+(u / frac).toFixed(4), v, q]) };
    return { ...s, mi: mi + 1, p: s.p.map(([u, v, q]) => [+((u - frac) / (1 - frac)).toFixed(4), v, q]) };
  });
}
export function onJoin(score, mi, fracA = 0.5) {
  shift(score, (s) => {
    if (s.mi < mi) return s;
    if (s.mi === mi) return { ...s, p: s.p.map(([u, v, q]) => [+(u * fracA).toFixed(4), v, q]) };
    if (s.mi === mi + 1) return { ...s, mi, p: s.p.map(([u, v, q]) => [+(fracA + u * (1 - fracA)).toFixed(4), v, q]) };
    return { ...s, mi: s.mi - 1 };
  });
}
export function onInsert(score, idx) { shift(score, (s) => (s.mi >= idx ? { ...s, mi: s.mi + 1 } : s)); }
export function onDelete(score, lo, hi) { shift(score, (s) => (s.mi < lo ? s : s.mi > hi ? { ...s, mi: s.mi - (hi - lo + 1) } : null)); }
function shift(score, fn) {
  const list = strokes(score);
  if (!list.length) return;
  setStrokes(score, list.map(fn).filter(Boolean));
}

// ---------------------------------------------------------------- drawing
// A pen stroke is a filled outline whose width follows the Pencil's pressure; a highlighter is a wide, flat,
// see-through band.
function penOutline(pts, w) {
  if (pts.length === 1) {
    const [x, y, p] = pts[0];
    const r = w * (0.5 + p) / 2;
    return `M${x - r} ${y} a${r} ${r} 0 1 0 ${2 * r} 0 a${r} ${r} 0 1 0 ${-2 * r} 0`;
  }
  // light smoothing of the pressure, so a jittery reading does not make a beaded line
  const ps = pts.map((q, i) => { const a = pts[Math.max(0, i - 1)][2], c = pts[Math.min(pts.length - 1, i + 1)][2]; return (a + 2 * q[2] + c) / 4; });
  const L = [], R = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
    let dx = b[0] - a[0], dy = b[1] - a[1];
    const len = Math.hypot(dx, dy) || 1;
    dx /= len; dy /= len;
    const r = (w * (0.35 + ps[i] * 0.9)) / 2;
    L.push([pts[i][0] - dy * r, pts[i][1] + dx * r]);
    R.push([pts[i][0] + dy * r, pts[i][1] - dx * r]);
  }
  const f = (q) => `${q[0].toFixed(1)} ${q[1].toFixed(1)}`;
  const rEnd = (w * (0.35 + ps[ps.length - 1] * 0.9)) / 2, rStart = (w * (0.35 + ps[0] * 0.9)) / 2;
  let d = `M${f(L[0])}`;
  for (let i = 1; i < L.length; i++) d += ` L${f(L[i])}`;
  d += ` A${rEnd.toFixed(1)} ${rEnd.toFixed(1)} 0 0 0 ${f(R[R.length - 1])}`;
  for (let i = R.length - 2; i >= 0; i--) d += ` L${f(R[i])}`;
  d += ` A${rStart.toFixed(1)} ${rStart.toFixed(1)} 0 0 0 ${f(L[0])} Z`;
  return d;
}
function polyline(pts) {
  let d = `M${pts[0][0].toFixed(1)} ${pts[0][1].toFixed(1)}`;
  for (let i = 1; i < pts.length; i++) d += ` L${pts[i][0].toFixed(1)} ${pts[i][1].toFixed(1)}`;
  if (pts.length === 1) d += ` l0.1 0`;
  return d;
}
/** An SVG element for a stroke given in page (layout) coordinates. */
export function strokeEl(s, pts) {
  const p = document.createElementNS(SVGNS, 'path');
  if (s.tool === 'hl') {
    Object.entries({ d: polyline(pts), stroke: s.c, 'stroke-width': s.w || 14, 'stroke-opacity': 0.38, fill: 'none', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }).forEach(([k, v]) => p.setAttribute(k, v));
    p.style.mixBlendMode = 'multiply';
  } else {
    Object.entries({ d: penOutline(pts, s.w || 2.6), fill: s.c }).forEach(([k, v]) => p.setAttribute(k, v));
  }
  p.setAttribute('class', 'ink-stroke');
  return p;
}
/** Where a stored stroke sits on this layout, or null when its bar is gone. */
export function pagePoints(layout, s) {
  const m = layout.measures[s.mi];
  if (!m) return null;
  return s.p.map(([u, v, q]) => [...toPage(m, u, v), q]);
}
/** Draw every stroke into `svg` (sized like the score). Returns the strokes' page points for erasing. */
export function draw(score, layout, svg, hidden) {
  svg.innerHTML = '';
  svg.setAttribute('width', layout.pxWidth);
  svg.setAttribute('height', layout.height * layout.zoom);
  svg.setAttribute('viewBox', `0 0 ${layout.width} ${layout.height}`);
  svg.style.display = hidden ? 'none' : '';
  const list = strokes(score);
  const placed = [];
  // highlighter under pen
  for (const pass of ['hl', 'pen']) {
    list.forEach((s, i) => {
      if ((s.tool === 'hl') !== (pass === 'hl')) return;
      const pts = pagePoints(layout, s);
      if (!pts) return;
      svg.appendChild(strokeEl(s, pts));
      placed[i] = pts;
    });
  }
  return placed;
}

/** A finished stroke, from page points [[x, y, pressure]], pinned to the bar where it starts. */
export function makeStroke(layout, pts, pen, width) {
  const { mi, m } = anchor(layout, pts[0][0], pts[0][1]);
  // drop points closer than half a pixel to the last kept one (a Pencil reports 240 per second)
  const kept = [pts[0]];
  for (const q of pts.slice(1)) { const l = kept[kept.length - 1]; if (Math.hypot(q[0] - l[0], q[1] - l[1]) >= 0.6) kept.push(q); }
  if (kept.length > 1 && kept[kept.length - 1] !== pts[pts.length - 1]) kept.push(pts[pts.length - 1]);
  return { mi, tool: pen.tool, c: pen.color, w: width, p: kept.map(([x, y, q]) => [...toLocal(m, x, y), +(q ?? 0.5).toFixed(2)]) };
}

/** Indexes of the strokes that pass within r of (x, y). */
export function strokesNear(placed, x, y, r = 9) {
  const out = [];
  placed.forEach((pts, i) => {
    if (!pts) return;
    for (let k = 0; k < pts.length; k++) {
      const a = pts[k], b = pts[k + 1] || a;
      // distance to the segment a-b
      const dx = b[0] - a[0], dy = b[1] - a[1];
      const t = dx || dy ? Math.max(0, Math.min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy))) : 0;
      if (Math.hypot(x - (a[0] + t * dx), y - (a[1] + t * dy)) <= r) { out.push(i); return; }
    }
  });
  return out;
}
