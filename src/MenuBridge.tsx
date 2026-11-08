import React, { useEffect, useRef, useState } from 'react';
import { GlassMenu, haptic } from '@zakisheriff/liquid-glass';
import { $, $$, theme, watch } from '../dom';
import { mount } from '../mount';

/**
 * GlassMenu for BMN's contextual menus (#lgttMenu: post options, message
 * actions, chat actions...). BMN keeps building the items and owning every
 * action: when it opens the menu we read its buttons, show a GlassMenu that
 * grows out of the control you pressed, and a pick simply clicks the matching
 * original button, so the existing close logic and callbacks run unchanged.
 */

interface Origin {
  x: number;
  y: number;
  w: number;
  h: number;
  t: number;
}

let lastPress: Origin | null = null;
const IGNORE = '#lgttMenu, .bmn-gm';

function trackPress() {
  document.addEventListener(
    'pointerdown',
    (e) => {
      const t = e.target as HTMLElement | null;
      if (!t || t.closest(IGNORE)) return;
      const btn = t.closest<HTMLElement>('button, [role="button"], [data-act]');
      const r = btn?.getBoundingClientRect();
      lastPress = r && r.width <= 96 && r.height <= 96 ? { x: r.left, y: r.top, w: r.width, h: r.height, t: performance.now() } : { x: e.clientX - 22, y: e.clientY - 22, w: 44, h: 44, t: performance.now() };
    },
    true,
  );
}

const Dots = (
  <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true">
    <circle cx="5" cy="12" r="1.8" />
    <circle cx="12" cy="12" r="1.8" />
    <circle cx="19" cy="12" r="1.8" />
  </svg>
);

const Bridge: React.FC<{ menu: HTMLElement; list: HTMLElement; origin: Origin; done: () => void }> = ({ menu, list, origin, done }) => {
  const wrap = useRef<HTMLDivElement>(null);
  const items = $$('[data-mi]', list);
  const picked = useRef(false);
  const [mode] = useState(theme());
  const end = origin.x + origin.w / 2 > window.innerWidth / 2 ? 'end' : 'start';
  // Keep the whole expanded panel on screen: the menu grows from the anchor, so the
  // anchor itself is nudged until a 236px-wide, item-count-tall panel fits.
  const PANEL_W = 236;
  const EDGE = 12;
  const panelH = Math.min(items.length * 46 + 16, window.innerHeight - EDGE * 2);
  const left = end === 'start'
    ? Math.max(EDGE, Math.min(origin.x, window.innerWidth - PANEL_W - EDGE))
    : Math.min(window.innerWidth - EDGE - origin.w, Math.max(origin.x, PANEL_W + EDGE - origin.w));
  const top = Math.max(EDGE, Math.min(origin.y, window.innerHeight - panelH - origin.h - EDGE));

  useEffect(() => {
    const trigger = wrap.current?.querySelector<HTMLButtonElement>('button[aria-haspopup]');
    if (!trigger) return;
    // Grow out of the trigger on the next frame, exactly as if it had been tapped.
    const open = requestAnimationFrame(() => trigger.click());
    let wasOpen = false;
    const stop = watch(trigger, () => {
      const exp = trigger.getAttribute('aria-expanded') === 'true';
      if (exp) wasOpen = true;
      if (wasOpen && !exp) {
        // Dismissed without a pick (outside tap, Escape): let BMN close its own layer.
        if (!picked.current && menu.classList.contains('is-open')) menu.click();
        window.setTimeout(done, 420);
      }
    }, { attributes: true, attributeFilter: ['aria-expanded'] });
    return () => {
      cancelAnimationFrame(open);
      stop();
    };
  }, []);

  return (
    <div
      ref={wrap}
      className="bmn-gm"
      data-theme={mode}
      data-bmn-glass="menu"
      style={{ left, top, width: origin.w, height: origin.h }}
    >
      <GlassMenu
        icon={Dots}
        aria-label="More options"
        align={end}
        size="md"
        width={236}
        items={items.map((b) => {
          const href = b.querySelector('use')?.getAttribute('href');
          return {
            label: (b.childNodes[0]?.textContent || b.textContent || '').trim(),
            icon: href ? (
              <svg viewBox="0 0 24 24" width="20" height="20" className="bmn-gm-ico" aria-hidden="true">
                <use href={href} />
              </svg>
            ) : undefined,
            destructive: b.classList.contains('danger'),
            disabled: (b as HTMLButtonElement).disabled,
            onSelect: () => {
              picked.current = true;
              haptic();
              b.click();
            },
          };
        })}
      />
    </div>
  );
};

export function bridgeMenu() {
  const menu = $('#lgttMenu');
  const list = $('#lgttMenuList');
  const stage = $('#lgtt');
  if (!menu || !list || !stage) return;
  trackPress();
  let handle: { unmount: () => void } | null = null;
  const finish = () => {
    handle?.unmount();
    handle = null;
  };
  watch(menu, () => {
    const open = menu.classList.contains('is-open');
    if (open && !handle && $$('[data-mi]', list).length) {
      const o = lastPress && performance.now() - lastPress.t < 2500 ? lastPress : { x: window.innerWidth / 2 - 22, y: window.innerHeight / 2 - 22, w: 44, h: 44, t: 0 };
      handle = mount(stage, <Bridge menu={menu} list={list} origin={o} done={finish} />, 'bmn-gm-layer');
    } else if (!open && handle) {
      window.setTimeout(finish, 420);
    }
  }, { attributes: true, attributeFilter: ['class'] });
}
