// Pinch to zoom the score on iPad (two fingers), and ⌘/Ctrl + scroll or a trackpad pinch on a computer, as in any
// score or document app. While the fingers move the drawn score is scaled; it is re-engraved at the new size when
// they lift, keeping the point between the fingers in place.
const MIN = 0.5, MAX = 1.8;

export function installZoom({ S, redraw, cancelDrag }) {
  const scroll = document.querySelector('#scoreScroll');
  const layers = () => [document.querySelector('#score'), document.querySelector('#overlay')];
  const pts = new Map();
  let g = null;
  let before = null;   // the gesture: { d0, z0, z, cx, cy, sx, sy }

  const dist = () => { const [a, b] = [...pts.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
  const mid = () => { const [a, b] = [...pts.values()]; return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; };

  function begin(cx, cy) {
    const r = scroll.getBoundingClientRect();
    // the content point under (cx, cy), in unscaled pixels
    g = { z0: S.zoom, z: S.zoom, vx: cx - r.left, vy: cy - r.top, sx: scroll.scrollLeft + cx - r.left, sy: scroll.scrollTop + cy - r.top };
    for (const el of layers()) { el.style.transformOrigin = `${g.sx - el.offsetLeft}px ${g.sy - el.offsetTop}px`; }
  }
  function preview(z) {
    g.z = Math.max(MIN, Math.min(MAX, z));
    for (const el of layers()) el.style.transform = `scale(${g.z / g.z0})`;
  }
  function finish() {
    if (!g) return;
    const { z, z0, sx, sy, vx, vy } = g;
    g = null;
    for (const el of layers()) { el.style.transform = ''; el.style.transformOrigin = ''; }
    if (Math.abs(z - z0) < 0.01) return;
    S.autoZoom = false;
    S.zoom = +z.toFixed(2);
    redraw();
    const k = S.zoom / z0;
    scroll.scrollTop = Math.max(0, sy * k - vy);
    scroll.scrollLeft = Math.max(0, sx * k - vx);
  }

  // two fingers: a pinch, never a note drag or a note written by the first finger
  scroll.addEventListener('pointerdown', (e) => {
    if (e.pointerType !== 'touch') return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    // what the first finger may change (it selects a note or a bar) is put back if a pinch follows
    if (pts.size === 1) before = { sel: S.sel, measures: new Set(S.measures) };
    if (pts.size === 2 && S.layout && !S.stroke) {
      cancelDrag();
      if (before) { S.sel = before.sel; S.measures = before.measures; redraw(); }
      S.pinch = true;
      const m = mid();
      begin(m.x, m.y);
      g.d0 = dist();
      e.stopImmediatePropagation();
      e.preventDefault();
    } else if (S.pinch) e.stopImmediatePropagation();
  }, true);
  scroll.addEventListener('pointermove', (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (!S.pinch || !g) return;
    e.stopImmediatePropagation();
    if (pts.size >= 2) preview(g.z0 * dist() / g.d0);
  }, true);
  const up = (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.delete(e.pointerId);
    if (S.pinch) {
      e.stopImmediatePropagation();
      if (pts.size < 2) finish();
      if (pts.size === 0) S.pinch = false;
    }
  };
  scroll.addEventListener('pointerup', up, true);
  scroll.addEventListener('pointercancel', up, true);
  // with two fingers down the page must not scroll under them
  scroll.addEventListener('touchmove', (e) => { if (S.pinch) e.preventDefault(); }, { passive: false });

  // ⌘/Ctrl + wheel, and the trackpad pinch (which browsers send as a Ctrl + wheel)
  let wt = null;
  scroll.addEventListener('wheel', (e) => {
    if (!(e.ctrlKey || e.metaKey) || !S.layout) return;
    e.preventDefault();
    if (!g) begin(e.clientX, e.clientY);
    preview(g.z * Math.exp(-e.deltaY * 0.01));
    clearTimeout(wt);
    wt = setTimeout(finish, 180);
  }, { passive: false });
}
