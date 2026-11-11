import React, { useEffect, useState } from 'react';
import { usePress, useRefraction, type GlassShape, type PressOptions } from '@zakisheriff/liquid-glass';
import { $$ } from '../dom';
import { mount } from '../mount';

/**
 * Material adapter. Gives EXISTING elements the Dock's glass material using
 * the library's engine hooks (useRefraction: bezel refraction + specular rim,
 * usePress: swell / lean / jelly settle) without replacing them.
 *
 * Each family keeps its own geometry (bezel, thickness, strength) but they all
 * paint from the same tokens, see "Unified material" in glass.css.
 *
 * tone: 'dark' = Quick Glass over video, always dark glass with white text.
 *       'auto' = buttons and panels: the tone is chosen from the element's real text/icon colour, so
 *                it stays legible in any BMN theme or view (see pickTone / watchTone).
 */

interface Family {
  selector: string;
  shape: GlassShape;
  press?: PressOptions | false;
  tag: string;
  tone: 'dark' | 'auto';
}

const FAMILIES: Family[] = [
  // Round icon buttons in the headers and feed rails: small, thick droplets.
  { selector: '#lgtt .lgtt-btn.lgtt-round', shape: { kind: 'surface', bezel: 12, thickness: 22, strength: 1.15, ior: 1.5 }, press: {}, tag: 'button', tone: 'auto' },
  // Quick Glass: the long-press quick actions (Like / Save / Repost / Share) and the speed pill.
  // They are created lazily inside posts, so they are picked up as they appear.
  { selector: '.bmn-quick-actions button', shape: { kind: 'surface', bezel: 14, thickness: 22, strength: 1.15, ior: 1.5 }, press: {}, tag: 'quick', tone: 'dark' },
  { selector: '.bmn-speed-hold', shape: { kind: 'surface', bezel: 16, thickness: 24, strength: 1, ior: 1.5 }, press: false, tag: 'speed', tone: 'dark' },
  // Sheets (comments, DMs, settings, share): large and shallow, softer rim.
  { selector: '#lgtt aside.lgtt-sheet', shape: { kind: 'surface', bezel: 24, thickness: 30, strength: 0.8 }, press: false, tag: 'sheet', tone: 'auto' },
  // Menu / confirm cards that BMN renders itself.
  { selector: '#lgtt .lgtt-modal-card', shape: { kind: 'surface', bezel: 20, thickness: 26, strength: 0.9 }, press: false, tag: 'card', tone: 'auto' },
];

interface Item {
  id: number;
  el: HTMLElement;
  family: Family;
}

/** One persistent root. Elements come and go (feed slides, sheets), so the list is reconciled, never re-mounted. */
const store = { items: [] as Item[], active: new Set<HTMLElement>(), next: 0, listeners: new Set<() => void>(), mounted: false };

/** Light text needs dark glass; dark text needs light glass. */
function pickTone(el: HTMLElement): 'dark' | 'light' {
  const m = getComputedStyle(el).color.match(/[\d.]+/g) || [];
  const lum = (0.2126 * +m[0] + 0.7152 * +m[1] + 0.0722 * +m[2]) / 255;
  return lum > 0.6 ? 'dark' : 'light';
}

/** One shared observer re-checks every 'auto' surface when the theme or the stage view changes. */
const toneAppliers = new Set<() => void>();
let toneObserver: MutationObserver | null = null;
function watchTone(fn: () => void) {
  toneAppliers.add(fn);
  if (!toneObserver) {
    let q = 0;
    toneObserver = new MutationObserver(() => {
      if (q) return;
      q = requestAnimationFrame(() => {
        q = 0;
        toneAppliers.forEach((f) => f());
      });
    });
    toneObserver.observe(document.body, { attributes: true, attributeFilter: ['class'] });
    toneObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-bmn-theme'] });
    const stage = document.getElementById('lgttStage');
    if (stage) toneObserver.observe(stage, { attributes: true, attributeFilter: ['data-view', 'class'] });
  }
  return () => {
    toneAppliers.delete(fn);
  };
}

const Surface: React.FC<{ el: HTMLElement; family: Family }> = ({ el, family }) => {
  // `el` is a long-lived DOM node; useRefraction only reads `.current`.
  const [ref] = useState(() => ({ current: el }));
  useEffect(() => {
    el.classList.add('lg-glass', 'bmn-surface');
    el.dataset.bmnMaterial = family.tag;
    let stop = () => {};
    if (family.tone === 'dark') {
      el.dataset.bmnTone = 'dark';
    } else {
      const apply = () => {
        const t = pickTone(el);
        if (el.dataset.bmnTone !== t) el.dataset.bmnTone = t;
      };
      apply();
      const unwatch = watchTone(apply);
      // Panels can restyle themselves when opened, so they also watch their own class.
      const own = family.tag === 'sheet' || family.tag === 'card' ? new MutationObserver(apply) : null;
      own?.observe(el, { attributes: true, attributeFilter: ['class'] });
      stop = () => {
        unwatch();
        own?.disconnect();
      };
    }
    return () => {
      stop();
      el.classList.remove('lg-glass', 'bmn-surface');
      delete el.dataset.bmnMaterial;
      delete el.dataset.bmnTone;
    };
  }, [el, family]);
  useRefraction(ref, family.shape, true);
  usePress(ref, family.press === false ? { disabled: true } : family.press || {});
  return null;
};

const App: React.FC = () => {
  const [, force] = useState(0);
  useEffect(() => {
    const l = () => force((n) => n + 1);
    store.listeners.add(l);
    return () => {
      store.listeners.delete(l);
    };
  }, []);
  return (
    <>
      {store.items.map(({ id, el, family }) => (
        <Surface key={id} el={el} family={family} />
      ))}
    </>
  );
};

/** Idempotent: call whenever DOM may have changed. Bridges new elements, releases removed ones. */
export function bridgeSurfaces(stage: HTMLElement) {
  let changed = false;
  store.items = store.items.filter((it) => {
    if (it.el.isConnected) return true;
    store.active.delete(it.el);
    changed = true;
    return false;
  });
  for (const family of FAMILIES) {
    for (const el of $$(family.selector)) {
      if (store.active.has(el)) continue;
      store.active.add(el);
      store.items.push({ id: ++store.next, el, family });
      changed = true;
    }
  }
  if (!store.mounted) {
    store.mounted = true;
    mount(stage, <App />, 'bmn-surfaces');
  } else if (changed) {
    store.listeners.forEach((l) => l());
  }
}
