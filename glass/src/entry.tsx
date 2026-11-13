import React from 'react';
import { setGlassQuality, haptic, SPRINGS, createSpring } from '@zakisheriff/liquid-glass';
import './glass.css';
import { whenReady, $ } from './dom';
import { NavBridge, LGTT_DOCK, APP_DOCK, type DockSpec } from './bridges/NavBridge';
import { bridgeSegmented, bridgeSliders, bridgeSwitches } from './bridges/ControlBridges';
import { bridgeSheetHost } from './bridges/SheetBridge';
import { bridgeMenu } from './bridges/MenuBridge';
import { bridgeSurfaces, scanSurfaces } from './bridges/Surfaces';
import { bridgePlusMenu, scanPlus } from './bridges/PlusMenu';
import { tagControls, startControls, stopControls } from './bridges/Controls';
import { mount, unmountAll } from './mount';

/**
 * BMN Liquid Glass layer: an isolated React tree mounted over the existing,
 * unmodified vanilla DOM. Kill switch: `?glass=off` (remembered), `?glass=on`
 * to restore, or `BMNGlass.disable()` in the console. With the switch off this
 * file mounts nothing and adds no class, so BMN renders exactly as before.
 */

const VERSION = '1.1.0';
const KEY = 'bmn-glass';
const QKEY = 'bmn-glass-quality';

type Tier = 'ios' | 'desktop' | 'lite';

/**
 * Device tier, by capability first and platform second:
 *   ios      iPhone / iPad (incl. iPadOS reporting as a Mac): the full engine, tuned for WebKit.
 *   desktop  everything else with backdrop-filter: the full engine, desktop profile.
 *   lite     Android, or no backdrop-filter at all: NO engine. index.html does not even load this
 *            bundle there (see the loader in index.html); this check is the second line of defence.
 * `?glass=full` forces the engine on Android for testing only.
 */
function tier(): Tier {
  const w = window as unknown as { __bmnGlassTier?: Tier };
  if (w.__bmnGlassTier) return w.__bmnGlassTier;
  const n = navigator as Navigator & { userAgentData?: { platform?: string } };
  const ua = n.userAgent || '';
  const android = /Android/i.test(ua) || n.userAgentData?.platform === 'Android';
  const ios = /iP(hone|ad|od)/.test(ua) || (n.platform === 'MacIntel' && n.maxTouchPoints > 1);
  let forced = false;
  try {
    forced = new URLSearchParams(location.search).get('glass') === 'full';
  } catch {
    /* ignore */
  }
  if (android && !forced) return 'lite';
  return ios ? 'ios' : 'desktop';
}

/** Everything the layer starts (observers, listeners) registers a disposer here, so teardown is complete. */
const disposers: Array<() => void> = [];

function flag(): 'on' | 'off' {
  try {
    const q = new URLSearchParams(location.search).get('glass');
    if (q === 'off') localStorage.setItem(KEY, 'off');
    if (q === 'on') localStorage.removeItem(KEY);
    return localStorage.getItem(KEY) === 'off' ? 'off' : 'on';
  } catch {
    return 'on';
  }
}

function supported() {
  const css = (window as unknown as { CSS?: { supports?: (a: string, b?: string) => boolean } }).CSS;
  return !!css?.supports && (css.supports('backdrop-filter', 'blur(1px)') || css.supports('-webkit-backdrop-filter', 'blur(1px)'));
}

function bridgeDock(spec: DockSpec) {
  whenReady(spec.dock, (dock) => {
    if (dock.querySelector(':scope > .bmn-gn-host')) return;
    mount(dock, <NavBridge spec={spec} dock={dock} />, 'bmn-gn-host');
  });
}

/** Hidden tab / backgrounded PWA: pause every glass animation (CSS keys off this class). */
function watchVisibility() {
  const root = document.documentElement;
  const apply = () => root.classList.toggle('bmn-page-hidden', document.hidden);
  apply();
  document.addEventListener('visibilitychange', apply, { passive: true });
  disposers.push(() => {
    document.removeEventListener('visibilitychange', apply);
    root.classList.remove('bmn-page-hidden');
  });
}

function quality(t: Tier) {
  let q: string | null = null;
  try {
    const url = new URLSearchParams(location.search).get('glassq');
    if (url) localStorage.setItem(QKEY, url);
    q = localStorage.getItem(QKEY);
  } catch {
    /* storage is optional */
  }
  // iOS: WebKit cannot run SVG backdrop displacement, so the engine there is cheap (blur + rim + lens): pin it
  // high. Desktop: leave it on auto, the engine's own frame-time governor drops to a lighter profile if needed.
  setGlassQuality(q === 'high' || q === 'low' ? q : t === 'ios' ? 'high' : 'auto');
}

function boot() {
  const root = document.documentElement;
  const t = tier();
  if (t === 'lite') {
    // Android / no backdrop-filter: CSS-only frosted glass (bmn-glass-lite.css). No React, no engine.
    root.classList.add('bmn-glass-lite');
    return;
  }
  if (flag() === 'off' || !supported()) {
    root.classList.add('bmn-glass-off');
    return;
  }
  root.classList.add(t === 'ios' ? 'bmn-glass-ios' : 'bmn-glass-desktop');
  quality(t);
  watchVisibility();
  root.classList.add('bmn-glass-on');
  bridgeDock(LGTT_DOCK);
  bridgeDock(APP_DOCK);
  whenReady('#lgtt', (stage) => {
    bridgeSegmented();
    bridgeSwitches();
    bridgeSliders();
    bridgeMenu();
    bridgeSurfaces(stage);
    bridgePlusMenu();
    startControls();
    // Settings rows (and any later-built controls) are rendered on demand: bridge what appears.
    let queued = 0;
    // Only the app's own DOM changes matter: nodes our React roots add (glass hosts, their
    // children, SVG filters) are ignored, otherwise every glass render would trigger a rescan.
    const foreign = (n: Node) => {
      const el = n.nodeType === 1 ? (n as Element) : n.parentElement;
      return !!el && !el.closest('[data-bmn-glass-host], .lg-glass:not(.bmn-surface), .lg-sheet-layer');
    };
    const obs = new MutationObserver((records) => {
      if (queued) return;
      if (!records.some((r) => Array.from(r.addedNodes).some(foreign))) return;
      queued = requestAnimationFrame(() => {
        queued = 0;
        bridgeSwitches();
        bridgeSliders();
        scanSurfaces();
        scanPlus();
        tagControls();
      });
    });
    obs.observe(stage, { childList: true, subtree: true });
    const sh = document.getElementById('bmnSheetHost');
    if (sh) obs.observe(sh, { childList: true, subtree: true });
    // Quick Glass (long-press actions / speed pill) is created lazily inside posts, outside #lgtt. The app announces it
    // with one event, so no page-wide observer is needed.
    const rescan = () => scanSurfaces();
    window.addEventListener('bmn-glass-rescan', rescan, { passive: true } as AddEventListenerOptions);
    disposers.push(() => {
      obs.disconnect();
      if (queued) cancelAnimationFrame(queued);
      window.removeEventListener('bmn-glass-rescan', rescan);
    });
  });
  bridgeSheetHost();
  const ls = document.getElementById('settingsScrim');
  if (ls) bridgeSwitches();
}

function teardown() {
  document.documentElement.classList.remove('bmn-glass-on', 'bmn-glass-ios', 'bmn-glass-desktop');
  document.documentElement.classList.add('bmn-glass-off');
  for (const d of disposers.splice(0)) d();
  stopControls();
  unmountAll();
}

const g = window as unknown as { BMNGlass?: unknown };
// Initialise once: a second copy of the bundle (cached + fresh, two script tags, a SW swap) must not mount a second layer.
if (!g.BMNGlass) {
g.BMNGlass = {
  version: VERSION,
  get enabled() {
    return document.documentElement.classList.contains('bmn-glass-on');
  },
  disable() {
    try {
      localStorage.setItem(KEY, 'off');
    } catch {
      /* ignore */
    }
    teardown();
  },
  enable() {
    try {
      localStorage.removeItem(KEY);
    } catch {
      /* ignore */
    }
    location.reload();
  },
  quality(q: 'auto' | 'high' | 'low') {
    try {
      localStorage.setItem(QKEY, q);
    } catch {
      /* ignore */
    }
    setGlassQuality(q);
  },
  haptic,
  SPRINGS,
  createSpring,
};

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
else boot();
}
void $;
