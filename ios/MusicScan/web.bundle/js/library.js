// Your music: every score you open or scan is kept on this device (IndexedDB), with its flags, ink and pages,
// and listed on the start screen. Nothing leaves the device. When IndexedDB is unavailable (private mode),
// the start screen falls back to the single "Continue editing" button.
const DB = 'musicscan', STORE = 'scores';
let dbp = null;

function db() {
  if (dbp) return dbp;
  dbp = new Promise((ok, no) => {
    if (!('indexedDB' in window)) return no(new Error('no IndexedDB'));
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'id' });
    r.onsuccess = () => ok(r.result);
    r.onerror = () => no(r.error);
  }).catch((e) => { dbp = null; throw e; });
  return dbp;
}
function tx(mode, fn) {
  return db().then((d) => new Promise((ok, no) => {
    const t = d.transaction(STORE, mode);
    const res = fn(t.objectStore(STORE));
    t.oncomplete = () => ok(res && 'result' in res ? res.result : undefined);
    t.onerror = () => no(t.error);
  }));
}

export const newId = () => 's' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
export const get = (id) => tx('readonly', (s) => s.get(id));
export const remove = (id) => tx('readwrite', (s) => s.delete(id));
export async function list() {
  const all = (await tx('readonly', (s) => s.getAll())) || [];
  return all.sort((a, b) => b.t - a.t);
}

// save the open score; writes are coalesced so a drag of many small edits costs one write
let pending = null, timer = 0;
export function save(entry) {
  pending = entry;
  clearTimeout(timer);
  timer = setTimeout(flush, 400);
}
export async function flush() {
  clearTimeout(timer);
  const e = pending; pending = null;
  if (!e) return;
  try {
    const old = await get(e.id);
    await tx('readwrite', (s) => s.put({ ...e, created: old?.created || e.t }));
  } catch (err) { /* storage blocked or full: the localStorage copy of the last score still works */ }
}

// what a card says about a score
export function summary(e) {
  const open = (e.meta || []).filter((m) => (m.level === 'bad' || m.level === 'check') && !m.reviewed);
  const bad = open.filter((m) => m.level === 'bad').length;
  const status = open.length === 0 ? { kind: 'ok', text: 'Ready to play' }
    : { kind: bad ? 'bad' : 'check', text: open.length === 1 ? '1 bar to check' : `${open.length} bars to check` };
  const pages = Object.keys(e.pages || {}).length;
  return { status, bars: e.bars || 0, pages };
}

export function when(t, now = Date.now()) {
  const d = new Date(t), today = new Date(now); today.setHours(0, 0, 0, 0);
  const days = Math.floor((today - new Date(d).setHours(0, 0, 0, 0)) / 864e5);
  if (days <= 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days < 7) return d.toLocaleDateString(undefined, { weekday: 'short' });
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
