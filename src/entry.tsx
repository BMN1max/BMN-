import React from 'react';
import { setGlassQuality, haptic, SPRINGS, createSpring } from '@zakisheriff/liquid-glass';
import './glass.css';
import { whenReady, $ } from './dom';
import { NavBridge, LGTT_DOCK, APP_DOCK, type DockSpec } from './bridges/NavBridge';
import { bridgeInputs, bridgeSegmented, bridgeSliders, bridgeSwitches } from './bridges/ControlBridges';
import { bridgeSheetHost } from './bridges/SheetBridge';
import { bridgeMenu } from './bridges/MenuBridge';
import { bridgeSurfaces } from './bridges/Surfaces';
import { mount, unmountAll } from './mount';

/**
 * BMN Liquid Glass layer: an isolated React tree mounted over the existing,
 * unmodified vanilla DOM. Kill switch: `?glass=off` (remembered), `?glass=on`
 * to restore, or `BMNGlass.disable()` in the console. With the switch off this
 * file mounts nothing and adds no class, so BMN renders exactly as before.
 */

const VERSION = '1.0.0';
const KEY = 'bmn-glass';
const QKEY = 'bmn-glass-quality';

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

function quality() {
  let q: string | null = null;
  try {
    const url = new URLSearchParams(location.search).get('glassq');
    if (url) localStorage.setItem(QKEY, url);
    q = localStorage.getItem(QKEY);
  } catch {
    /* storage is optional */
  }
  setGlassQuality(q === 'high' || q === 'low' ? q : 'auto');
}

function boot() {
  const root = document.documentElement;
  if (flag() === 'off' || !supported()) {
    root.classList.add('bmn-glass-off');
    return;
  }
  quality();
  root.classList.add('bmn-glass-on');
  bridgeDock(LGTT_DOCK);
  bridgeDock(APP_DOCK);
  whenReady('#lgtt', (stage) => {
    bridgeSegmented();
    bridgeInputs();
    bridgeSwitches();
    bridgeSliders();
    bridgeMenu();
    bridgeSurfaces(stage);
    // Settings rows (and any later-built controls) are rendered on demand: bridge what appears.
    let queued = 0;
    new MutationObserver(() => {
      if (queued) return;
      queued = requestAnimationFrame(() => {
        queued = 0;
        bridgeSwitches();
        bridgeSliders();
        bridgeInputs();
      });
    }).observe(stage, { childList: true, subtree: true });
  });
  bridgeSheetHost();
  const ls = document.getElementById('settingsScrim');
  if (ls) bridgeSwitches();
}

function teardown() {
  document.documentElement.classList.remove('bmn-glass-on');
  document.documentElement.classList.add('bmn-glass-off');
  unmountAll();
}

(window as unknown as { BMNGlass: unknown }).BMNGlass = {
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
void $;
