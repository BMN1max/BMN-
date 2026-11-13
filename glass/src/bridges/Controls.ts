import { $$ } from '../dom';

/**
 * Universal control material. Every button, pill, slider and select in the app gets the same
 * glass finish (specular rim, inner depth, calm press) through ONE class and ONE delegated
 * pointer listener, never one SVG filter per control, so hundreds of controls stay cheap.
 * Coloured controls (red, gold, blue, purple, green) keep their own colour and become
 * translucent tinted glass.
 */

const SEL = [
  '#lgtt button',
  '#lgtt [role="button"]',
  '#lgtt select',
  '#bmnRealInbox button',
  '#bmnSheetHost button',
  '.bmn-plus-panel button',
  '.bmn-emo-tabs button',
  '.bmn-emo-btn',
  '.bmn-follow-pill',
  '#bmnDiscoverResults button',
  '.bmn-act-panel button',
  '.bmn-conversation-page button',
  '#bmnInboxV2 button',
  '#lgtt .lgtt-set-row',
  '#lgtt .lgtt-set-prof',
  '#lgtt .lgtt-opts',
  '#bmnRealInbox .bmn-ri-filters button',
  '#bmnRealInbox .bmn-ri-row',
].join(',');

// Never decorate: the dock (its own glass), emoji cells, anything the library already owns.
const SKIP = '.lg-glass, [data-bmn-glass-host], [data-bmn-glass-host] *, .lgtt-dock, .lgtt-dock *, .bmn-emo-grid button, .lg-track, .lg-track *';

const done = new WeakSet<Element>();
const press = new WeakSet<Element>();
let queue: HTMLElement[] = [];
let raf = 0;

function rgba(c: string): [number, number, number, number] | null {
  const m = c.match(/rgba?\(([^)]+)\)/);
  if (!m) return null;
  const p = m[1].split(/[ ,/]+/).filter(Boolean).map(parseFloat);
  if (p.length < 3 || p.some((n) => Number.isNaN(n))) return null;
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
}

function toneName(r: number, g: number, b: number): string {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  if (!d) return '';
  let h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  h = (h * 60 + 360) % 360;
  if (h < 18 || h >= 335) return 'red';
  if (h < 70) return 'gold';
  if (h < 170) return 'green';
  if (h < 255) return 'blue';
  return 'purple';
}

export function toneOf(el: HTMLElement) {
  const cs = getComputedStyle(el);
  const c = rgba(cs.backgroundColor);
  if (c && c[3] >= 0.45 && Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]) >= 60) {
    el.dataset.bmnTone = toneName(c[0], c[1], c[2]);
    el.style.setProperty('--bmn-tone', `${c[0]} ${c[1]} ${c[2]}`);
  } else if (el.dataset.bmnTone) {
    delete el.dataset.bmnTone;
    el.style.removeProperty('--bmn-tone');
  }
}

function decorate(el: HTMLElement) {
  if (done.has(el)) return;
  done.add(el);
  if (el.matches(SKIP) || el.closest(SKIP)) return;
  const cs = getComputedStyle(el);
  if (cs.display === 'inline' || cs.position === 'fixed') return;
  // Only controls that already have a visible body get the material: a flat transparent or
  // square-cornered hit target (avatar button, text link) would show a rectangle.
  const bg = rgba(cs.backgroundColor);
  const body = (bg && bg[3] > 0.04) || cs.backgroundImage !== 'none' || (parseFloat(cs.borderTopWidth) > 0 && cs.borderTopStyle !== 'none');
  if (!body || parseFloat(cs.borderTopLeftRadius) < 6) return;
  el.classList.add('bmn-ctl');
  // ::after is only free for us when the app did not already use it.
  const after = getComputedStyle(el, '::after').content;
  if (!after || after === 'none' || after === 'normal') el.classList.add('bmn-ctl-ov');
  if (cs.position === 'static') el.classList.add('bmn-ctl-rel');
  toneOf(el);
}

function flush() {
  raf = 0;
  const batch = queue.splice(0, 40);
  for (const el of batch) decorate(el);
  if (queue.length) raf = requestAnimationFrame(flush);
}

export function tagControls() {
  for (const el of $$(SEL)) if (!done.has(el)) queue.push(el);
  if (queue.length && !raf) raf = requestAnimationFrame(flush);
}

let stopFns: Array<() => void> = [];

/** Removes the delegated listeners and decorations (kill switch / teardown). */
export function stopControls() {
  for (const f of stopFns.splice(0)) f();
  if (raf) cancelAnimationFrame(raf);
  raf = 0;
  queue = [];
  for (const el of $$('.bmn-ctl')) {
    el.classList.remove('bmn-ctl', 'bmn-ctl-ov', 'bmn-ctl-rel');
    el.removeAttribute('data-bmn-pressed');
  }
}

export function startControls() {
  if (stopFns.length) return; // already running: never register a second listener set
  tagControls();
  // One delegated press listener: calm swell via the `scale` property (no transform clash).
  const down = (e: Event) => {
    const el = (e.target as Element).closest<HTMLElement>('.bmn-ctl');
    if (!el) return;
    el.dataset.bmnPressed = '';
    press.add(el);
    toneOf(el);
  };
  const up = () => {
    for (const el of $$('[data-bmn-pressed]')) delete el.dataset.bmnPressed;
  };
  const opts = { passive: true, capture: true } as AddEventListenerOptions;
  document.addEventListener('pointerdown', down, opts);
  document.addEventListener('pointerup', up, opts);
  document.addEventListener('pointercancel', up, opts);
  stopFns.push(() => {
    document.removeEventListener('pointerdown', down, opts);
    document.removeEventListener('pointerup', up, opts);
    document.removeEventListener('pointercancel', up, opts);
  });
}
