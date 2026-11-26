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
