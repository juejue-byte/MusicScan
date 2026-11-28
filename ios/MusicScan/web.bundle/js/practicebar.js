// The practice bar: a dark bar docked under the score while the music plays, with the controls you reach for
// mid-practice (stop, where you are, tempo, loop, click, count-in) and a door to the full Practice panel
// (parts, instruments, speed-up). It drives the same settings as the panel (web/js/practice.js).
import * as practice from './practice.js';

const $ = (s, r = document) => r.querySelector(s);
let el = null, api = null;

const ICON = {
  stop: '<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
  loop: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 3l3 3-3 3M4 12v-2a4 4 0 0 1 4-4h12M7 21l-3-3 3-3M20 12v2a4 4 0 0 1-4 4H4"/></svg>',
  click: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 3h6l4 18H5zM12 16l5-8M7 16h10"/></svg>',
  mixer: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" aria-hidden="true"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>',
};

function build() {
  el = document.createElement('div');
  el.id = 'practiceBar';
  el.className = 'pbar hidden';
  el.setAttribute('role', 'toolbar');
  el.setAttribute('aria-label', 'Practice');
  el.innerHTML = `
    <button class="pb-stop" aria-label="Stop">${ICON.stop}</button>
    <div class="pb-where"><b class="pb-bar">Bar 1</b><span class="pb-of"></span></div>
    <div class="pb-tempo">
      <div class="pb-tline"><span>Tempo</span><span><b class="pb-bpm">♩ 90</b> <span class="pb-pct"></span></span></div>
      <div class="pb-trow"><button class="pb-step" data-d="-5" aria-label="Slower">−</button><input type="range" class="pb-range" min="30" max="240" step="1" aria-label="Tempo"><button class="pb-step" data-d="5" aria-label="Faster">+</button></div>
    </div>
    <div class="pb-toggles">
      <button class="pb-t" data-t="loop" aria-pressed="false">${ICON.loop}<span>Loop</span></button>
      <button class="pb-t" data-t="click" aria-pressed="false">${ICON.click}<span>Click</span></button>
      <button class="pb-t" data-t="count" aria-pressed="false"><span class="pb-n">1</span><span>Count-in</span></button>
      <button class="pb-t" data-t="parts" aria-label="Parts and instruments">${ICON.mixer}<span>Parts</span></button>
    </div>`;
  document.body.appendChild(el);
  el.addEventListener('click', (e) => e.stopPropagation());
  $('.pb-stop', el).onclick = () => api.stop();
  $('.pb-range', el).oninput = (e) => practice.setBpm(+e.target.value);
  for (const b of el.querySelectorAll('.pb-step')) b.onclick = () => practice.setBpm(practice.state.bpm + +b.dataset.d);
  el.querySelector('[data-t=loop]').onclick = () => { api.toggleLoop(); sync(); };
  el.querySelector('[data-t=click]').onclick = () => practice.setOption('metronome', !practice.state.metronome);
  el.querySelector('[data-t=count]').onclick = () => practice.setOption('countIn', (practice.state.countIn + 1) % 3);
  el.querySelector('[data-t=parts]').onclick = () => { practice.open(); placePanel(); };
  practice.onChange(sync);
}

// the full panel opens just above the bar
function placePanel() {
  const box = $('#practicePanel');
  if (!box || window.innerWidth < 600) return;
  const r = el.getBoundingClientRect();
  box.style.top = `${Math.max(8, r.top - Math.min(box.offsetHeight, window.innerHeight - 100) - 8)}px`;
  box.style.right = `${Math.max(8, window.innerWidth - r.right)}px`;
}

function sync() {
  if (!el) return;
  const P = practice.state;
  const r = $('.pb-range', el);
  if (document.activeElement !== r) r.value = P.bpm;
  $('.pb-bpm', el).textContent = `♩ ${P.bpm}`;
  $('.pb-pct', el).textContent = P.written && P.bpm !== P.written ? `${Math.round(P.bpm / P.written * 100)}%` : '';
  const set = (t, on) => { const b = el.querySelector(`[data-t=${t}]`); b.classList.toggle('on', !!on); b.setAttribute('aria-pressed', String(!!on)); };
  set('loop', api.isLoop());
  set('click', P.metronome);
  set('count', P.countIn > 0);
  $('.pb-n', el).textContent = P.countIn ? String(P.countIn) : '0';
  el.querySelector('[data-t=count] span:last-child').textContent = P.countIn ? (P.countIn === 1 ? 'Count 1 bar' : 'Count 2 bars') : 'Count-in';
}

export function init(o) { api = o; build(); }
export function show(bar) {
  el.classList.remove('hidden');
  document.body.classList.add('playing');
  setBar(bar);
  sync();
}
export function hide() {
  el?.classList.add('hidden');
  document.body.classList.remove('playing');
}
export function setBar(mi) {
  if (!el || mi == null) return;
  const n = api.bars();
  $('.pb-bar', el).textContent = `Bar ${api.label(mi)}`;
  $('.pb-of', el).textContent = `of ${n}`;
}
