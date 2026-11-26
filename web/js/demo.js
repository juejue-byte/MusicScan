// Demo mode: when no MusicScan server answers (a static preview host), the sample photos open
// precomputed results from web/demo/ instead. Built by scripts/build_demo.py from the real pipeline.
// Everything else (editing, playback, export) runs in the browser exactly as with the server.

let mode = null; // 'server' | 'demo'
let index = null;

async function detect() {
  if (mode) return mode;
  if (new URLSearchParams(location.search).has('demo')) mode = 'demo';
  else {
    try {
      const r = await fetch('api/samples');
      mode = r.ok && (r.headers.get('content-type') || '').includes('json') ? 'server' : 'demo';
    } catch (e) { mode = 'demo'; }
  }
  if (mode === 'demo') {
    try { index = await (await fetch('demo/index.json')).json(); } catch (e) { index = { samples: {} }; }
  }
  return mode;
}

export const isDemo = () => mode === 'demo';
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });
const fail = (msg) => json({ detail: msg }, 503);
const NEEDS_SERVER = 'This is a preview without the reading server, so only the sample photos work here. Run MusicScan locally (scripts/run.sh) to read your own photos.';

/** fetch() for MusicScan's api/... routes; answers from web/demo/ in demo mode. */
export async function api(path, opts = {}) {
  if ((await detect()) === 'server') return fetch(path, opts);
  const p = path.replace(/^\/?api\//, '');
  if (p === 'samples') return json(Object.keys(index.samples));
  if (p === 'jobs' && opts.method === 'POST') {
    const name = opts.body?.get?.('file')?.name;
    const id = index.samples[name];
    return id ? json({ id }) : fail(NEEDS_SERVER);
  }
  let m = p.match(/^jobs\/([\w-]+)\/rescan$/);
  if (m) {
    const fd = opts.body;
    if (fd?.get?.('file')) return fail('Close-up rescans need the reading server. ' + NEEDS_SERVER.split('. ')[1]);
    const job = await (await fetch(`demo/${m[1]}/job.json`)).json();
    const meas = job.result.measures;
    const sel = String(fd.get('measures')).split(',').map(Number);
    const systems = [...new Set(sel.map((i) => meas[i]?.system).filter((s) => s != null))].sort((a, b) => a - b);
    const attempt = Number(fd.get('attempt') || 0) % 3;
    if (systems.length !== 1) return fail('In the preview, rescan one row at a time.');
    const r = await fetch(`demo/${m[1]}/rescan_${systems[0]}_${attempt}.json`);
    return r.ok ? r : fail('No precomputed rescan for that row. ' + NEEDS_SERVER.split('. ')[1]);
  }
  m = p.match(/^jobs\/([\w-]+)$/);
  if (m) return fetch(`demo/${m[1]}/job.json`);
  return fail(NEEDS_SERVER);
}

/** URL of a job's page.png / original.jpg. */
export function jobFile(job, name) {
  return mode === 'demo' ? `demo/${job}/${name === 'page.png' ? 'page.jpg' : name}` : `api/jobs/${job}/${name}`;
}

// ---------------------------------------------------------------- saving files inside a claude.ai preview
// A claude.ai Artifact frame blocks <a download>; it offers a "downloads" capability instead, which only takes
// common extensions, so .musicxml and .mid go out wrapped in a .zip.
let hostDownloads = null;
try { window.claude?.use?.('downloads').then((d) => { hostDownloads = d; }).catch(() => {}); } catch (e) { /* not in a preview frame */ }
const SAVE_OK = /\.(txt|json|md|csv|html|svg|pdf|png|jpe?g|zip)$/i;

/** True when this page runs in a frame that saves through the host. */
export const hostSaves = () => !!hostDownloads;

/** Save a file through the host frame; resolves false when there is no such host. */
export async function hostSave(name, blob) {
  if (!hostDownloads) return false;
  let filename = name, data = blob;
  if (!SAVE_OK.test(name)) { filename = name.replace(/\.[^.]+$/, '') + '.zip'; data = await zipStore([[name, blob]]); }
  await hostDownloads.save({ filename, data });
  return true;
}

const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = (b) => { let c = 0xffffffff; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };

/** A .zip (stored, no compression) of [name, Blob|string] entries. */
export async function zipStore(entries) {
  const enc = new TextEncoder();
  const parts = [], central = [];
  let off = 0;
  for (const [name, data] of entries) {
    const body = data instanceof Blob ? new Uint8Array(await data.arrayBuffer()) : enc.encode(String(data));
    const fn = enc.encode(name), crc = crc32(body);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true);
    h.setUint32(14, crc, true); h.setUint32(18, body.length, true); h.setUint32(22, body.length, true); h.setUint16(26, fn.length, true);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true);
    c.setUint32(16, crc, true); c.setUint32(20, body.length, true); c.setUint32(24, body.length, true); c.setUint16(28, fn.length, true); c.setUint32(42, off, true);
    parts.push(h, fn, body); central.push(c, fn);
    off += 30 + fn.length + body.length;
  }
  const size = central.reduce((a, p) => a + p.byteLength, 0);
  const e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, entries.length, true); e.setUint16(10, entries.length, true);
  e.setUint32(12, size, true); e.setUint32(16, off, true);
  return new Blob([...parts, ...central, e], { type: 'application/zip' });
}
