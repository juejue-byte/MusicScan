// Paywall (UI only, no payments yet): the "Take your music anywhere" sheet shown before export, the free-scan
// allowance, and the plan picker. Everything a product decision touches is in PLAN below, so prices, copy and
// the free allowance change in one place.
//
// It is OFF by default, so export keeps working for everyone. Turn it on to review it:
//   ?paywall in the URL (remembered), or localStorage 'musicscan:paywall' = '1'; ?paywall=off turns it off again.
// "Continue" does not charge anything: it marks this browser as Pro for the preview and says so.
export const PLAN = {
  freeScansPerMonth: 3,
  title: 'Take your music anywhere',
  sub: 'Export to MuseScore, Finale, Sibelius, Dorico or any app that opens MusicXML.',
  features: ['Unlimited scans and pages', 'MusicXML and MIDI export', 'All practice instruments', 'Your ink and marks kept in the file'],
  plans: [
    { id: 'year', name: 'Yearly', price: '$44.99', per: 'about $0.87 a week', badge: 'Best value' },
    { id: 'month', name: 'Monthly', price: '$6.99', per: 'per month' },
    { id: 'week', name: 'Weekly', price: '$5.99', per: 'per week' },
  ],
  defaultPlan: 'year',
  freeNote: 'Editing and practice stay free.',
};

const K = { on: 'musicscan:paywall', pro: 'musicscan:pro', scans: 'musicscan:scans' };
const get = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const set = (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) { /* blocked */ } };
const month = () => new Date().toISOString().slice(0, 7);

(() => {
  const q = new URLSearchParams(location.search).get('paywall');
  if (q === null) return;
  if (q === 'off' || q === '0') { set(K.on, null); set(K.pro, null); } else set(K.on, '1');
})();

export const enabled = () => get(K.on) === '1';
export const isPro = () => get(K.pro) === '1';
export function scansUsed() {
  try { const s = JSON.parse(get(K.scans) || '{}'); return s.m === month() ? s.n || 0 : 0; } catch (e) { return 0; }
}
export function countScan() { set(K.scans, JSON.stringify({ m: month(), n: scansUsed() + 1 })); }
export const scansLeft = () => Math.max(0, PLAN.freeScansPerMonth - scansUsed());

let el = null, chosen = PLAN.defaultPlan, done = null;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const CHECK = '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12l4 4 10-10"/></svg>';

function render(reason) {
  const used = scansUsed();
  el.innerHTML = `
    <div class="pw-card" role="dialog" aria-modal="true" aria-labelledby="pwTitle">
      <button class="pw-close" aria-label="Not now"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      <div class="pw-head">
        <span class="pw-badge"><svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12M7 8l5-5 5 5M5 14v6h14v-6"/></svg></span>
        <div><h2 id="pwTitle">${esc(PLAN.title)}</h2><p>${esc(reason || PLAN.sub)}</p></div>
      </div>
      <ul class="pw-features">${PLAN.features.map((f) => `<li>${CHECK}${esc(f)}</li>`).join('')}</ul>
      <div class="pw-plans" role="radiogroup" aria-label="Plan">${PLAN.plans.map((p) => `
        <button class="pw-plan${p.id === chosen ? ' on' : ''}" role="radio" aria-checked="${p.id === chosen}" data-plan="${p.id}">
          ${p.badge ? `<span class="pw-best">${esc(p.badge)}</span>` : ''}<span class="pw-name">${esc(p.name)}</span><span class="pw-price">${esc(p.price)}</span><span class="pw-per">${esc(p.per)}</span>
        </button>`).join('')}</div>
      <button class="btn primary pw-go">Continue with ${esc(PLAN.plans.find((p) => p.id === chosen).name)}</button>
      <div class="pw-foot"><span>${used ? `You've used ${Math.min(used, PLAN.freeScansPerMonth)} of ${PLAN.freeScansPerMonth} free scans this month. ` : ''}${esc(PLAN.freeNote)}</span><span><button class="pw-link" data-a="restore">Restore</button></span></div>
      <div class="pw-preview">Preview: payments aren't connected yet, so nothing is charged.</div>
    </div>`;
  el.querySelector('.pw-close').onclick = () => close(false);
  for (const b of el.querySelectorAll('[data-plan]')) b.onclick = () => { chosen = b.dataset.plan; render(reason); el.querySelector(`[data-plan="${chosen}"]`).focus(); };
  el.querySelector('.pw-go').onclick = () => { set(K.pro, '1'); close(true, 'Pro is on for this preview. No payment was taken.'); };
  el.querySelector('[data-a=restore]').onclick = () => close(isPro(), isPro() ? 'Pro is already on.' : 'No purchase to restore on this device.');
}

let toastFn = () => {};
export function init({ toast }) { toastFn = toast; }

// show the sheet; resolves true when the person is Pro afterwards
export function show(reason) {
  if (!el) {
    el = document.createElement('div');
    el.id = 'paywall';
    el.className = 'paywall hidden';
    el.addEventListener('click', (e) => { if (e.target === el) close(false); });
    document.addEventListener('keydown', (e) => { if (!el.classList.contains('hidden') && e.key === 'Escape') { e.stopImmediatePropagation(); close(false); } }, true);
    document.body.appendChild(el);
  }
  chosen = PLAN.defaultPlan;
  render(reason);
  el.classList.remove('hidden');
  el.querySelector('.pw-go').focus();
  return new Promise((ok) => { done = ok; });
}
function close(pro, msg) {
  el.classList.add('hidden');
  if (msg) toastFn(msg);
  const d = done; done = null;
  d && d(!!pro);
}

// gate an action: runs it when the paywall is off or the person is Pro, otherwise shows the sheet first
export async function gate(action, reason) {
  if (!enabled() || isPro()) return action();
  if (await show(reason)) return action();
}
