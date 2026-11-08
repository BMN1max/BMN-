import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { GlassNav, haptic } from '@zakisheriff/liquid-glass';
import { $$, signedIn, theme, toast, watch } from '../dom';

/**
 * GlassNav over BMN's existing docks.
 *
 * The original buttons stay in the DOM and keep ALL of their routing
 * (patchDock, requestCommunityAuth, setView, ...). They are only hidden from
 * sight and from the pointer; this component reads their state (which tab is
 * on, label, icon, badge) and activates the real button with `.click()`.
 */

export interface DockSpec {
  /** CSS selector of the dock element that hosts the bridge. */
  dock: string;
  /** Button elements, in visual order. */
  buttons: (dock: HTMLElement) => HTMLElement[];
  key: (b: HTMLElement) => string;
  active: (b: HTMLElement) => boolean;
  label: (b: HTMLElement) => string;
  icon: (b: HTMLElement) => { href?: string; html?: string };
  badge: (b: HTMLElement) => string;
}

/** Destinations that need a signed-in user: the existing router answers a tap with the sign-in sheet. */
const GATED = new Set(['inbox', 'profile', 'create']);
/** Tabs that open something instead of switching the current screen. */
const ACTIONS = new Set(['create']);

export const LGTT_DOCK: DockSpec = {
  dock: '#lgttDock',
  buttons: (d) => $$('.lgtt-dk[data-dock]', d),
  key: (b) => b.dataset.dock || '',
  active: (b) => b.classList.contains('on'),
  label: (b) => (b.querySelector('span:not(.lgtt-plus-pill)')?.textContent || b.getAttribute('aria-label') || b.dataset.dock || '').trim(),
  icon: (b) => ({ href: b.querySelector('use')?.getAttribute('href') || '' }),
  badge: (b) => {
    const n = b.querySelector<HTMLElement>('.lgtt-badge');
    return n && !n.hidden ? (n.textContent || '').trim() : '';
  },
};

export const APP_DOCK: DockSpec = {
  dock: '.app-dock',
  buttons: (d) => $$('button[data-app-view]', d),
  key: (b) => b.dataset.appView || '',
  active: (b) => b.classList.contains('active') || b.getAttribute('aria-current') === 'page',
  label: (b) => (b.querySelector('span:not(.dock-symbol):not(.dock-create-symbol)')?.textContent || b.getAttribute('aria-label') || '').trim(),
  icon: (b) => ({ html: (b.querySelector('.dock-symbol,.dock-create-symbol') as HTMLElement | null)?.innerHTML || '' }),
  badge: (b) => {
    const n = b.querySelector<HTMLElement>('.dock-dot');
    return n && !n.hidden ? '•' : '';
  },
};

interface Tab {
  key: string;
  label: string;
  icon: { href?: string; html?: string };
  badge: string;
  on: boolean;
  el: HTMLElement;
}

function read(spec: DockSpec, dock: HTMLElement): Tab[] {
  return spec.buttons(dock).map((el) => ({
    key: spec.key(el),
    label: spec.label(el),
    icon: spec.icon(el),
    badge: spec.badge(el),
    on: spec.active(el),
    el,
  }));
}

const Icon: React.FC<{ tab: Tab }> = ({ tab }) => {
  const create = tab.key === 'create';
  return (
    <span className={'bmn-gn-icon' + (create ? ' bmn-gn-icon--create' : '')}>
      {tab.icon.href ? (
        <svg className="bmn-gn-ico" viewBox="0 0 24 24" aria-hidden="true">
          <use href={tab.icon.href} />
        </svg>
      ) : (
        <span className="bmn-gn-ico bmn-gn-ico--html" dangerouslySetInnerHTML={{ __html: tab.icon.html || '' }} />
      )}
      {tab.badge && <b className="bmn-gn-badge">{tab.badge === '•' ? '' : tab.badge}</b>}
    </span>
  );
};

export const NavBridge: React.FC<{ spec: DockSpec; dock: HTMLElement }> = ({ spec, dock }) => {
  const [tabs, setTabs] = useState<Tab[]>(() => read(spec, dock));
  const [shown, setShown] = useState<number | null>(null); // transient override used to spring the lens back
  const [mode, setMode] = useState(theme());
  const gesture = useRef({ id: -1, x: 0, drag: false });
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Re-render only when something the glass nav actually shows has changed: the app
    // touches the dock's classes constantly (lens, drag, peek states) and each of those
    // used to rebuild every tab and its icon.
    let last = '';
    const sync = () => {
      const next = read(spec, dock);
      const sig = next.map((t) => `${t.key}|${t.label}|${t.icon.href || t.icon.html || ''}|${t.badge}|${t.on ? 1 : 0}`).join('\u0001');
      if (sig !== last) {
        last = sig;
        setTabs(next);
      }
      setMode(theme());
    };
    const stop = watch(dock, sync);
    const stopBody = watch(document.body, () => setMode(theme()), { attributes: true, attributeFilter: ['class'] });
    sync();
    return () => {
      stop();
      stopBody();
    };
  }, [spec, dock]);

  // Tell a drag from a tap: GlassNav reports both through onChange.
  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const down = (e: PointerEvent) => {
      gesture.current = { id: e.pointerId, x: e.clientX, drag: false };
    };
    const move = (e: PointerEvent) => {
      const g = gesture.current;
      if (e.pointerId === g.id && Math.abs(e.clientX - g.x) > 6) g.drag = true;
    };
    host.addEventListener('pointerdown', down, true);
    host.addEventListener('pointermove', move, true);
    return () => {
      host.removeEventListener('pointerdown', down, true);
      host.removeEventListener('pointermove', move, true);
    };
  }, []);

  const activeIndex = Math.max(0, tabs.findIndex((t) => t.on));

  const springBack = useCallback(
    (to: number, from: number) => {
      // LensTrack already moved its lens to `from`; nudging the controlled
      // index makes it spring back to where the app really is.
      setShown(from);
      requestAnimationFrame(() => requestAnimationFrame(() => setShown(null)));
      void to;
    },
    [],
  );

  const onChange = (index: number) => {
    const tab = tabs[index];
    if (!tab) return;
    const dragged = gesture.current.drag;
    gesture.current.drag = false;
    // A drag that lands on a destination that needs an account must not pop a
    // sheet the finger never asked for: the lens settles back and the tab says
    // why. A deliberate tap still goes straight to the existing sign-in sheet.
    if (dragged && GATED.has(tab.key) && !signedIn()) {
      haptic();
      toast(`Sign in to open ${tab.label}. Tap it to continue.`);
      springBack(activeIndex, index);
      return;
    }
    tab.el.click();
    // Destinations we already know the router will not switch to settle back at once, with one bounce.
    if (ACTIONS.has(tab.key) || (GATED.has(tab.key) && !signedIn())) {
      springBack(activeIndex, index);
      return;
    }
    // Safety net: if the router declines for any other reason, the lens follows the app, not the finger.
    window.setTimeout(() => {
      const now = read(spec, dock);
      if (now.findIndex((t) => t.on) !== index) springBack(activeIndex, index);
    }, 380);
  };

  const items = useMemo(() => tabs.map((t) => ({ label: t.label, icon: <Icon tab={t} /> })), [tabs]);
  if (!tabs.length) return null;
  return (
    <div ref={hostRef} className="bmn-gn" data-theme={mode} data-bmn-glass="nav">
      <GlassNav
        items={items}
        activeIndex={shown ?? activeIndex}
        onChange={onChange}
        intensity={6}
        aria-label={dock.getAttribute('aria-label') || 'Navigation'}
      />
    </div>
  );
};
