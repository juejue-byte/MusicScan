// Paywall (UI only, no payments yet). Everything a product decision touches is in PLAN below, so prices, copy and
// allowances change in one place.
//
// The model (Allen, 2026-11-26):
//   - A new person's first page is free, with every feature (edit, play, export).
//   - After that, a scan without Pro opens as a preview: the first half of the page is shown, the rest is blurred, and
//     editing, playback and export ask to unlock. Going Pro unlocks the whole page and everything else.
//   - Pro: $15.99 a month or $99.99 a year, about 30 pages a month. No weekly plan.
//   - Yearly starts with a 7-day free trial (a StoreKit introductory offer: once per Apple ID, new subscribers only).
//
// It is OFF by default, so everything keeps working for everyone. Turn it on to review it:
//   ?paywall in the URL (remembered), or localStorage 'musicscan:paywall' = '1'; ?paywall=off turns it off again.
// "Continue" does not charge anything: it marks this browser as Pro for the preview and says so.
//
// Before payments go live (App Store Review Guidelines 3.1.1, 3.1.2, 5.1.1):
//   - Buy through StoreKit 2 In-App Purchase, both plans in ONE subscription group so monthly -> yearly is an upgrade.
//   - The trial is an introductory offer set on the yearly product in App Store Connect. Ask StoreKit
//     (Product.SubscriptionInfo.isEligibleForIntroOffer) and set introEligible() from it: someone who already had a
//     trial must see the plain price, never a trial they can't get (guideline 3.1.2).
//   - Check entitlements on the server (App Store Server API + notifications). The server, not this file, decides what
//     a scan returns: for a preview it should send only the first half of the reading, because anything sent to the
//     browser can be read out of it. Count pages on the server too.
//   - Fill in PLAN.privacyUrl (and your own terms if not using Apple's standard EULA); both links must be on this sheet
//     and in the App Store listing. If accounts are added, the app must also offer account deletion in the app.
export const PLAN = {
  freePages: 1,
  proPagesPerMonth: 30,
  title: 'Unlock the whole page',
  sub: 'See every bar, fix it on the staff, play it and export it.',
  features: ['The whole page, every bar', 'Edit, fix and rescan any bar', 'Practice playback: loop, tempo, parts', 'MusicXML and MIDI export', `Up to 30 pages a month`, 'Multi-page scores and PDFs'],
  plans: [
    { id: 'year', name: 'Yearly', price: '$99.99', period: 'year', per: '$8.33 a month, save 48%', badge: 'Best value', trialDays: 7 },
    { id: 'month', name: 'Monthly', price: '$15.99', period: 'month', per: 'per month' },
  ],
  defaultPlan: 'year',
  termsUrl: 'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
  privacyUrl: '', // required before App Review: a public privacy policy page
};

const K = { on: 'musicscan:paywall', pro: 'musicscan:pro', pages: 'musicscan:pages', free: 'musicscan:freeUsed', access: 'musicscan:access', trial: 'musicscan:hadTrial' };
const get = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const set = (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) { /* blocked */ } };
const month = () => new Date().toISOString().slice(0, 7);

(() => {
  const q = new URLSearchParams(location.search).get('paywall');
  if (q === null) return;
  if (q === 'off' || q === '0') { for (const k of Object.values(K)) set(k, null); } else set(K.on, '1');
})();

export const enabled = () => get(K.on) === '1';
export const isPro = () => get(K.pro) === '1';
export const freeLeft = () => (get(K.free) ? 0 : PLAN.freePages);
// whether this person can still get the free trial (preview: yes until they've gone Pro once on this device)
export const introEligible = () => get(K.pro) == null && get(K.trial) == null;
const trialOf = (p) => (p.trialDays && introEligible() ? p.trialDays : 0);

// pages read this calendar month (the Pro allowance; the real count belongs on the server)
export function pagesUsed() {
  try { const s = JSON.parse(get(K.pages) || '{}'); return s.m === month() ? s.n || 0 : 0; } catch (e) { return 0; }
}
export const pagesLeft = () => Math.max(0, PLAN.proPagesPerMonth - pagesUsed());
function countPage() { set(K.pages, JSON.stringify({ m: month(), n: pagesUsed() + 1 })); }
function renewDate() {
  const d = new Date(); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toLocaleDateString(undefined, { month: 'long', day: 'numeric' });
}
const capMessage = () => `You've read all ${PLAN.proPagesPerMonth} pages for this month. More pages on ${renewDate()}.`;

// what each score in Your music may do: 'free' (the free page), 'preview' (half page, locked), absent = full
function accessMap() { try { return JSON.parse(get(K.access) || '{}'); } catch (e) { return {}; } }
export function setAccess(id, mode) {
  if (!id || !mode || mode === 'full') return;
  const m = accessMap(); m[id] = mode; set(K.access, JSON.stringify(m));
}
export const accessFor = (id) => accessMap()[id] || 'full';
export const locked = (id) => enabled() && !isPro() && accessFor(id) === 'preview';

let el = null, chosen = PLAN.defaultPlan, done = null;
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const CHECK = '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M5 12l4 4 10-10"/></svg>';

function render(reason) {
  const plan = PLAN.plans.find((p) => p.id === chosen);
  const trial = trialOf(plan);
  const terms = trial
    ? `Free for ${trial} days, then ${plan.price} per ${plan.period}. Renews automatically until you cancel. Cancel anytime in Settings › your name › Subscriptions, at least 24 hours before the trial ends, and you won't be charged. Payment is charged to your Apple ID when the trial ends.`
    : `${plan.price} per ${plan.period}. Renews automatically until you cancel. Cancel anytime in Settings › your name › Subscriptions, at least 24 hours before it renews. Payment is charged to your Apple ID.`;
  el.innerHTML = `
    <div class="pw-card" role="dialog" aria-modal="true" aria-labelledby="pwTitle">
      <button class="pw-close" aria-label="Not now"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      <div class="pw-head">
        <span class="pw-badge"><svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.5-2"/></svg></span>
        <div><h2 id="pwTitle">${esc(PLAN.title)}</h2><p>${esc(reason || PLAN.sub)}</p></div>
      </div>
      <ul class="pw-features">${PLAN.features.map((f) => `<li>${CHECK}${esc(f)}</li>`).join('')}</ul>
      <div class="pw-plans" role="radiogroup" aria-label="Plan" style="--n: ${PLAN.plans.length}">${PLAN.plans.map((p) => `
        <button class="pw-plan${p.id === chosen ? ' on' : ''}" role="radio" aria-checked="${p.id === chosen}" data-plan="${p.id}">
          ${trialOf(p) || p.badge ? `<span class="pw-best">${trialOf(p) ? `${trialOf(p)} days free` : esc(p.badge)}</span>` : ''}<span class="pw-name">${esc(p.name)}</span><span class="pw-price">${esc(p.price)}</span><span class="pw-per">${esc(p.per)}</span>
        </button>`).join('')}</div>
      <button class="btn primary pw-go">${trial ? `Start ${trial}-day free trial` : `Continue with ${esc(plan.name)}`}</button>
      <p class="pw-terms">${esc(terms)}</p>
      <div class="pw-foot"><span>${PLAN.termsUrl ? `<a class="pw-link" href="${esc(PLAN.termsUrl)}" target="_blank" rel="noopener">Terms of Use</a>` : ''}${PLAN.privacyUrl ? ` · <a class="pw-link" href="${esc(PLAN.privacyUrl)}" target="_blank" rel="noopener">Privacy Policy</a>` : ''}</span><span><button class="pw-link" data-a="restore">Restore purchases</button></span></div>
      <div class="pw-preview">Preview: payments aren't connected yet, so nothing is charged.</div>
    </div>`;
  el.querySelector('.pw-close').onclick = () => close(false);
  for (const b of el.querySelectorAll('[data-plan]')) b.onclick = () => { chosen = b.dataset.plan; render(reason); el.querySelector(`[data-plan="${chosen}"]`).focus(); };
  el.querySelector('.pw-go').onclick = () => {
    set(K.pro, '1');
    if (trial) set(K.trial, '1');
    close(true, trial ? `Your ${trial}-day free trial has started (preview, nothing is charged).` : 'Pro is on for this preview. No payment was taken.');
  };
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
export const isOpen = () => !!el && !el.classList.contains('hidden');
function close(pro, msg) {
  el.classList.add('hidden');
  if (msg) toastFn(msg);
  const d = done; done = null;
  d && d(!!pro);
}

// Before a new scan: 'full' (paywall off or Pro), 'free' (the free page), 'preview' (half page), or null (don't scan).
// Counts the page when it goes ahead.
export async function beforeScan() {
  if (!enabled()) return 'full';
  if (isPro()) {
    if (pagesLeft() === 0) { toastFn(capMessage()); return null; }
    countPage(); return 'full';
  }
  countPage();
  if (freeLeft()) { set(K.free, '1'); return 'free'; }
  return 'preview';
}

// Before reading one more page into an open score (multi-page). Without Pro, asks first.
export async function allowPage() {
  if (!enabled()) return true;
  if (!isPro() && !(await show('Add more pages and read whole PDFs with Pro.'))) return false;
  if (pagesLeft() === 0) { toastFn(capMessage()); return false; }
  countPage();
  return true;
}

// gate an action on a score: runs it when the paywall is off, the person is Pro, or the score isn't a preview
export async function gate(action, reason, id) {
  if (!locked(id)) return action();
  if (await show(reason)) return action();
}
