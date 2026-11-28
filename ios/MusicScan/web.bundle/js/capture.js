// Live photo check while shooting (web): a camera view with corner guides that grades every frame for light,
// sharpness, steadiness and how much of the frame the page fills, so a bad photo is caught before the 20 s read.
// Falls back to the system camera (the hidden file input) when the browser has no camera access.
// The thresholds mirror musicscan/quality.py on a 480 px frame (calibrated on web/samples: the blurry sample scores
// ~0.46 sharp, crisp pages 0.7+, a 2 px blur ~0.15).
const T = {
  sharpBad: 0.3, sharpOk: 0.55,     // p99.5 edge step / (paper - ink)
  paperBad: 90, paperOk: 130,       // grey level of the paper (75th percentile)
  fillBad: 0.2,                     // share of the frame that is paper
  moveBad: 12,                      // mean grey change between checks
};

// grade one grey frame (Float32Array or Uint8ClampedArray, w x h). Returns {checks: [{id, level, title, tip}], ok}
export function grade(g, w, h, prev) {
  const n = w * h;
  const hist = new Uint32Array(256);
  for (let i = 0; i < n; i++) hist[g[i] | 0]++;
  const pct = (p) => { let c = 0; const k = p * n; for (let v = 0; v < 256; v++) { c += hist[v]; if (c >= k) return v; } return 255; };
  const paper = pct(0.75), ink = pct(0.03), contrast = Math.max(1, paper - ink);
  const mags = new Uint32Array(512);
  let m = 0;
  for (let y = 0; y < h - 1; y++) for (let x = 0; x < w - 1; x++) {
    const i = y * w + x, dx = Math.abs(g[i + 1] - g[i]), dy = Math.abs(g[i + w] - g[i]);
    const v = Math.min(511, Math.round(Math.hypot(dx, dy))); mags[v]++; m++;
  }
  let c = 0, p995 = 0;
  for (let v = 0; v < 512; v++) { c += mags[v]; if (c >= 0.995 * m) { p995 = v; break; } }
  const sharp = p995 / contrast;
  let bright = 0;
  for (let i = 0; i < n; i++) if (g[i] > paper * 0.8) bright++;
  const fill = bright / n;
  let move = 0;
  if (prev && prev.length === n) { for (let i = 0; i < n; i += 4) move += Math.abs(g[i] - prev[i]); move /= n / 4; }
  const checks = [
    fill < T.fillBad
      ? { id: 'fill', level: 'bad', title: 'No page in view', tip: 'Fill the frame with the page.' }
      : { id: 'fill', level: 'ok', title: 'Page in view', tip: 'Keep it inside the corners.' },
    move > T.moveBad
      ? { id: 'still', level: 'check', title: 'Hold still', tip: 'Rest your elbows on the table.' }
      : sharp < T.sharpBad
        ? { id: 'still', level: 'bad', title: 'Blurry', tip: 'Hold steady and tap the page to focus.' }
        : sharp < T.sharpOk
          ? { id: 'still', level: 'check', title: 'A little soft', tip: 'Move a bit closer or tap to focus.' }
          : { id: 'still', level: 'ok', title: 'Sharp', tip: 'Notes are crisp enough to read.' },
    paper < T.paperBad
      ? { id: 'light', level: 'bad', title: 'Too dark', tip: 'Turn on a lamp or move near a window.' }
      : paper < T.paperOk
        ? { id: 'light', level: 'check', title: 'A bit dark', tip: 'Brighter, even light reads best.' }
        : { id: 'light', level: 'ok', title: 'Good light', tip: 'Avoid your own shadow on the page.' },
  ];
  return { checks, ok: checks.every((x) => x.level === 'ok'), stats: { paper, ink, sharp: +sharp.toFixed(3), fill: +fill.toFixed(2), move: +move.toFixed(1) } };
}

const ICON = {
  ok: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12l4 4 10-10"/></svg>',
  check: '<svg viewBox="0 0 12 12" width="18" height="18" aria-hidden="true"><circle cx="6" cy="6" r="5" fill="currentColor"/></svg>',
  bad: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M12 3l10 18H2z" fill="currentColor"/></svg>',
};

let el = null, stream = null, timer = 0, prev = null, onShot = null, last = null;

function build() {
  el = document.createElement('div');
  el.id = 'capture';
  el.className = 'capture hidden';
  el.setAttribute('role', 'dialog');
  el.setAttribute('aria-label', 'Take a photo of the page');
  el.innerHTML = `
    <div class="cap-view">
      <video playsinline muted autoplay></video>
      <svg class="cap-corners" viewBox="0 0 100 130" preserveAspectRatio="none" aria-hidden="true"><path d="M2 14V2h12M86 2h12v12M98 116v12H86M14 128H2v-12" vector-effect="non-scaling-stroke"/></svg>
      <button class="cap-close" aria-label="Close camera"><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      <div class="cap-bottom">
        <span class="cap-say">Fit the page inside the corners</span>
        <button class="cap-shutter" aria-label="Take photo"></button>
        <button class="cap-system">Use the system camera</button>
      </div>
    </div>
    <aside class="cap-panel">
      <h2>Photo check</h2>
      <p class="cap-sub">Live, before you shoot, so a bad photo never costs you a 20-second read.</p>
      <div class="cap-checks" aria-live="polite"></div>
    </aside>
    <canvas hidden></canvas>`;
  document.body.appendChild(el);
  el.querySelector('.cap-close').onclick = close;
  el.querySelector('.cap-shutter').onclick = shoot;
  el.querySelector('.cap-system').onclick = () => { const f = onFallback; close(); f && f(); };
  // while the camera is up, Escape closes it and Space/Enter take the photo (the editor's keys stay out of it)
  document.addEventListener('keydown', (e) => {
    if (el.classList.contains('hidden')) return;
    if (e.key === 'Escape') close();
    else if (e.key === ' ' || e.key === 'Enter') shoot();
    else return;
    e.preventDefault(); e.stopImmediatePropagation();
  }, true);
}

let onFallback = null;
export function available() { return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia); }

// open the live camera. shot(file) gets the photo; fallback() opens the system camera instead.
export async function open({ shot, fallback }) {
  if (!el) build();
  onShot = shot; onFallback = fallback;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment', width: { ideal: 3840 }, height: { ideal: 2160 } }, audio: false });
  } catch (e) {
    stream = null;
    fallback && fallback();
    return false;
  }
  const v = el.querySelector('video');
  v.srcObject = stream;
  el.classList.remove('hidden');
  document.body.classList.add('capturing');
  try { await v.play(); } catch (e) { /* autoplay with muted video is allowed */ }
  prev = null; last = null;
  render({ checks: [], ok: false });
  timer = setInterval(tick, 300);
  return true;
}

export function close() {
  clearInterval(timer); timer = 0;
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = null;
  if (el) { el.classList.add('hidden'); el.querySelector('video').srcObject = null; }
  document.body.classList.remove('capturing');
}

function frame(maxSide) {
  const v = el.querySelector('video');
  const vw = v.videoWidth, vh = v.videoHeight;
  if (!vw || !vh) return null;
  const k = Math.min(1, maxSide / Math.max(vw, vh));
  const c = el.querySelector('canvas');
  c.width = Math.round(vw * k); c.height = Math.round(vh * k);
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(v, 0, 0, c.width, c.height);
  return { c, ctx, w: c.width, h: c.height };
}

function tick() {
  const f = frame(480);
  if (!f) return;
  const d = f.ctx.getImageData(0, 0, f.w, f.h).data;
  const g = new Uint8ClampedArray(f.w * f.h);
  for (let i = 0, j = 0; j < g.length; i += 4, j++) g[j] = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8;
  last = grade(g, f.w, f.h, prev);
  prev = g;
  render(last);
}

function render(r) {
  const box = el.querySelector('.cap-checks');
  box.innerHTML = r.checks.map((c) => `<div class="cap-check ${c.level}" data-check="${c.id}"><span class="ci">${ICON[c.level]}</span><div><b>${c.title}</b><small>${c.tip}</small></div></div>`).join('')
    || '<div class="cap-check wait"><div><b>Starting the camera…</b></div></div>';
  el.querySelector('.cap-shutter').classList.toggle('ready', r.ok);
  const worst = r.checks.find((c) => c.level === 'bad') || r.checks.find((c) => c.level === 'check');
  el.querySelector('.cap-say').textContent = !r.checks.length ? 'Fit the page inside the corners' : worst ? worst.tip : 'Looks good. Take the photo.';
}

async function shoot() {
  const f = frame(4096);
  if (!f) return;
  const blob = await new Promise((ok) => f.c.toBlob(ok, 'image/jpeg', 0.92));
  const verdict = last;
  const cb = onShot;
  close();
  if (blob && cb) cb(new File([blob], 'camera.jpg', { type: 'image/jpeg' }), verdict);
}

export const state = () => ({ open: !!el && !el.classList.contains('hidden'), last });
