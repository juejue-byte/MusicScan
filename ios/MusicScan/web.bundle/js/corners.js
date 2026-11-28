// Adjust page edges: when the automatic page finder missed the page (a row cut off, the desk read as paper), the
// user drags the four corners onto the page's corners on the original photo and the page is read again.
// openCorners({ card, src, quad, onRead, onClose }) fills the modal card; quad = [[x, y] x4] in photo pixels or null.

const SVGNS = 'http://www.w3.org/2000/svg';

// no corners found: the page was read as the whole photo, so start from the photo's own corners
export function defaultQuad(w, h) {
  return [[0, 0], [w, 0], [w, h], [0, h]];
}

export function openCorners({ card, src, quad, onRead, onClose }) {
  card.classList.add('corners-card');
  card.innerHTML = `<h2>Adjust the page edges</h2>
    <p class="muted small">Drag the four corners onto the corners of the printed page, then read it again. Every row of music should be inside the frame.</p>
    <div class="corners-stage"><div class="c-wrap"><img alt="Your photo" draggable="false"><svg></svg></div></div>
    <div class="modal-actions corners-actions">
      <button class="btn ghost" data-c="whole" title="Read the whole photo as it is, without flattening">Whole photo</button>
      <span class="grow"></span>
      <button class="btn ghost" data-c="cancel">Cancel</button>
      <button class="btn primary" data-c="read">Read again</button>
    </div>`;
  const img = card.querySelector('img');
  const svg = card.querySelector('svg');
  let W = 0, H = 0, pts = null, drag = null;
  const close = () => { card.classList.remove('corners-card'); onClose?.(); };

  function draw() {
    if (!W) return;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    const k = W / Math.max(1, img.clientWidth);          // photo pixels per screen pixel
    const r = 16 * k, hit = 26 * k;
    const poly = pts.map((p) => p.join(',')).join(' ');
    svg.innerHTML = `<path class="c-shade" fill-rule="evenodd" d="M0 0H${W}V${H}H0Z M${pts.map((p) => p.join(' ')).join(' L')}Z"/>
      <polygon class="c-edge" points="${poly}" stroke-width="${3 * k}"/>` +
      pts.map((p, i) => `<g class="c-handle" data-i="${i}"><circle cx="${p[0]}" cy="${p[1]}" r="${hit}" class="c-hit"/><circle cx="${p[0]}" cy="${p[1]}" r="${r}" stroke-width="${3 * k}"/></g>`).join('');
  }
  function toPhoto(e) {
    const b = svg.getBoundingClientRect();
    return [Math.min(W, Math.max(0, ((e.clientX - b.left) / b.width) * W)), Math.min(H, Math.max(0, ((e.clientY - b.top) / b.height) * H))];
  }
  svg.addEventListener('pointerdown', (e) => {
    const g = e.target.closest('.c-handle');
    let i = g ? +g.dataset.i : -1;
    if (i < 0) {                                           // a tap near a corner grabs the nearest one
      const p = toPhoto(e);
      const d = pts.map((q) => Math.hypot(q[0] - p[0], q[1] - p[1]));
      i = d.indexOf(Math.min(...d));
      if (d[i] > 0.25 * Math.max(W, H)) return;
    }
    e.preventDefault();
    svg.setPointerCapture(e.pointerId);
    drag = { i, id: e.pointerId };
    pts[i] = toPhoto(e);
    draw();
  });
  svg.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    e.preventDefault();
    pts[drag.i] = toPhoto(e);
    draw();
  });
  const end = (e) => { if (drag && e.pointerId === drag.id) drag = null; };
  svg.addEventListener('pointerup', end);
  svg.addEventListener('pointercancel', end);
  img.onload = () => {
    W = img.naturalWidth; H = img.naturalHeight;
    pts = (quad && quad.length === 4 ? quad : defaultQuad(W, H)).map(([x, y]) => [Math.min(W, Math.max(0, x)), Math.min(H, Math.max(0, y))]);
    draw();
  };
  img.onerror = () => { card.querySelector('.corners-stage').innerHTML = '<p class="muted">The photo of this page is not available any more. Retake it from Pages instead.</p>'; card.querySelector('[data-c="read"]').disabled = true; card.querySelector('[data-c="whole"]').disabled = true; };
  img.src = src;
  const onResize = () => draw();
  addEventListener('resize', onResize);
  card.onclick = (ev) => {
    const b = ev.target.closest('[data-c]');
    if (!b) return;
    removeEventListener('resize', onResize);
    if (b.dataset.c === 'cancel') { close(); return; }
    const q = b.dataset.c === 'whole' ? [] : pts.map(([x, y]) => [Math.round(x), Math.round(y)]);
    close();
    onRead(q);
  };
  return { points: () => pts && pts.map((p) => [...p]) };
}
