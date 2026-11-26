// Bridge to the iOS app shell (ios/). In a normal browser every function here falls back to the web behaviour,
// so the editor is the same code on the web and inside the app.
//
// Web -> native: window.webkit.messageHandlers.musicscan.postMessage({ id, cmd, ...args })
// Native -> web: window.__msNativeReply(id, result)   (result is JSON; { error } on failure)

const handler = window.webkit?.messageHandlers?.musicscan;
export const isNative = !!handler;
if (isNative) document.documentElement.classList.add('native');
// In the app a pinch should not zoom the whole page (header and toolbar slide off screen); the score has its own
// zoom. Browsers keep normal page zoom.
if (isNative) document.querySelector('meta[name=viewport]')?.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover');
// a music app should be heard with the silent switch on (Safari 16.4+ Audio Session API)
if (isNative && navigator.audioSession) { try { navigator.audioSession.type = 'playback'; } catch (e) { /* older WebKit */ } }

let seq = 0;
const pending = new Map();
window.__msNativeReply = (id, result) => {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  if (result && result.error) p.reject(new Error(result.error)); else p.resolve(result);
};
function call(cmd, args = {}) {
  if (!isNative) return Promise.reject(new Error('Not running in the app'));
  const id = ++seq;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    handler.postMessage({ id, cmd, ...args });
  });
}
function fire(cmd, args = {}) { if (isNative) handler.postMessage({ id: 0, cmd, ...args }); }

function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function blobToB64(blob) {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let s = '';
  for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
  return btoa(s);
}

/** Light tap feedback. kind: 'selection' (a pitch step), 'light', 'medium', 'success', 'warning'. */
export function haptic(kind = 'selection') { fire('haptic', { kind }); }

/** Open Apple's document camera (edge detection, perspective fix). Resolves to a File, or null if cancelled. */
export async function scanDocument() {
  const r = await call('scan');
  if (!r || !r.b64) return null;
  const f = new File([b64ToBytes(r.b64)], r.name || 'scan.jpg', { type: 'image/jpeg' });
  f.pages = r.pages || 1;
  // further pages of a multi-page document scan, in order (read into the same score)
  const base = (r.name || 'scan.jpg').replace(/\.jpg$/i, '');
  f.more = (r.more || []).map((b, i) => new File([b64ToBytes(b)], `${base} p${i + 2}.jpg`, { type: 'image/jpeg' }));
  return f;
}

/** Save or send a file with the iOS share sheet (Files, AirDrop, Mail...). Returns false outside the app. */
export async function share(name, blob) {
  if (!isNative) return false;
  await call('share', { name, b64: await blobToB64(blob), type: blob.type || 'application/octet-stream' });
  return true;
}

/** Commands sent by the app: hardware-keyboard ⌘ shortcuts and Apple Pencil double-tap ('toggle-mode'). */
export function onCommand(fn) { window.__msCommand = (cmd) => { try { fn(cmd); } catch (e) { console.error(e); } }; }

/** Open the app's server settings. */
export function openSettings() { fire('settings'); }
