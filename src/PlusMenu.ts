import { haptic } from '@zakisheriff/liquid-glass';
import { $, $$ } from '../dom';

/**
 * iMessage-style expanding "+" menu. A glass panel grows out of the "+" button, upward, in a
 * fixed layer above the composer: nothing in the composer's layout moves. Every action just
 * triggers an existing, working control (photo picker, emoji picker, quick reactions).
 */

const PLUS = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>';
const PHOTO = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>';
const SMILE = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M8.5 14.5c1 1.4 2.2 2 3.5 2s2.5-.6 3.5-2M9 9.5h.01M15 9.5h.01"/></svg>';

interface Item {
  label: string;
  icon: string;
  tone: string;
  run: () => void;
}

let panel: HTMLElement | null = null;
let opener: HTMLElement | null = null;

export function closePlus(restore = true) {
  if (!panel) return;
  const p = panel;
  panel = null;
  p.dataset.state = 'closing';
  opener?.setAttribute('aria-expanded', 'false');
  opener?.removeAttribute('data-open');
  if (restore) opener?.focus({ preventScroll: true });
  window.setTimeout(() => p.remove(), 220);
}

function openPlus(btn: HTMLElement, anchor: HTMLElement, items: Item[], reactions: HTMLElement[]) {
  closePlus(false);
  opener = btn;
  btn.setAttribute('aria-expanded', 'true');
  btn.setAttribute('data-open', '');
  const p = document.createElement('div');
  p.className = 'bmn-plus-panel';
  p.setAttribute('role', 'menu');
  p.setAttribute('aria-label', 'Add to message');
  p.dataset.state = 'opening';
  const stage = document.getElementById('lgttStage') || document.body;
  const rows = items
    .map(
      (it, i) =>
        `<button type="button" role="menuitem" class="bmn-plus-item" data-i="${i}" data-tone="${it.tone}" style="--i:${i}"><span class="bmn-plus-ic">${it.icon}</span><span>${it.label}</span></button>`,
    )
    .join('');
  const chips = reactions.length
    ? `<div class="bmn-plus-react" style="--i:${items.length}">${reactions
        .map((r, i) => `<button type="button" role="menuitem" data-r="${i}" aria-label="${r.getAttribute('aria-label') || 'Reaction'}">${r.textContent}</button>`)
        .join('')}</div>`
    : '';
  p.innerHTML = rows + chips;
  stage.appendChild(p);
  panel = p;
  // Fixed position from the composer's rectangle: opens upward, never shifts the composer.
  const a = anchor.getBoundingClientRect();
  const b = btn.getBoundingClientRect();
  const vw = window.innerWidth;
  const w = p.offsetWidth || 236;
  const left = Math.max(12, Math.min(vw - w - 12, b.left - 2));
  p.style.left = left + 'px';
  p.style.bottom = Math.round(window.innerHeight - a.top + 10) + 'px';
  p.style.transformOrigin = `${Math.round(b.left + b.width / 2 - left)}px 100%`;
  requestAnimationFrame(() => requestAnimationFrame(() => (p.dataset.state = 'open')));
  haptic('tap');
  p.addEventListener('click', (e) => {
    const t = (e.target as HTMLElement).closest<HTMLElement>('[data-i],[data-r]');
    if (!t) return;
    const it = t.dataset.i != null ? items[+t.dataset.i] : null;
    closePlus(false);
    window.setTimeout(() => (it ? it.run() : reactions[+t.dataset.r!]?.click()), 30);
  });
  p.querySelector<HTMLElement>('.bmn-plus-item')?.focus({ preventScroll: true });
}

const onOutside = (e: Event) => {
  if (!panel) return;
  const t = e.target as Element;
  if (panel.contains(t) || opener?.contains(t)) return;
  closePlus(false);
};
const onKey = (e: KeyboardEvent) => {
  if (panel && e.key === 'Escape') {
    e.stopPropagation();
    closePlus();
  }
};

function inboxPlus() {
  const shell = $('#bmnRealInbox .bmn-ri-composer-shell');
  if (!shell || shell.querySelector('.bmn-plus-btn')) return;
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'bmn-plus-btn';
  btn.setAttribute('aria-label', 'Add to message');
  btn.setAttribute('aria-haspopup', 'menu');
  btn.setAttribute('aria-expanded', 'false');
  btn.innerHTML = PLUS;
  shell.insertBefore(btn, shell.firstChild);
  shell.classList.add('bmn-has-plus');
  btn.addEventListener('click', () => {
    if (panel) return closePlus();
    const items: Item[] = [
      { label: 'Photo', icon: PHOTO, tone: 'blue', run: () => $('#bmnRiAttach')?.click() },
      { label: 'Emoji', icon: SMILE, tone: 'gold', run: () => shell.querySelector<HTMLElement>('.bmn-emo-btn')?.click() },
    ];
    openPlus(btn, shell, items, $$('#bmnRiQuick [data-q]'));
  });
}

function lgttPlus() {
  const form = $('#lgttChatForm');
  const btn = form && $('[data-act="chat-attach"]', form);
  if (!form || !btn || btn.dataset.bmnPlus) return;
  btn.dataset.bmnPlus = '1';
  btn.classList.add('bmn-plus-btn');
  btn.setAttribute('aria-haspopup', 'menu');
  btn.setAttribute('aria-expanded', 'false');
  btn.setAttribute('aria-label', 'Add to message');
  // Capture phase: replaces the old "not wired" toast with the menu.
  btn.addEventListener(
    'click',
    (e) => {
      e.stopImmediatePropagation();
      e.preventDefault();
      if (panel) return closePlus();
      const items: Item[] = [
        { label: 'Emoji', icon: SMILE, tone: 'gold', run: () => form.querySelector<HTMLElement>('.bmn-emo-btn')?.click() },
        {
          label: 'Send a heart',
          icon: '<span style="font-size:20px;line-height:1">❤️</span>',
          tone: 'red',
          run: () => $('[data-act="chat-heart"]', form)?.click(),
        },
      ];
      openPlus(btn, form, items, []);
    },
    true,
  );
}

export function scanPlus() {
  inboxPlus();
  lgttPlus();
}

export function bridgePlusMenu() {
  scanPlus();
  document.addEventListener('pointerdown', onOutside, true);
  document.addEventListener('keydown', onKey, true);
  window.addEventListener('resize', () => closePlus(false));
}
