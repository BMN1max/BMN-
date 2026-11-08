import React, { useEffect, useMemo } from 'react';
import { usePress, useRefraction, type GlassShape, type PressOptions } from '@zakisheriff/liquid-glass';
import { $$ } from '../dom';
import { mount } from '../mount';

/**
 * Material adapter. Gives EXISTING elements their own optical material using
 * the library's engine hooks (useRefraction for rim refraction and specular
 * edge, usePress for swell / lean / jelly settle) without replacing them.
 * Each family gets different bezel, depth and strength: buttons are small
 * thick droplets, the sheets are large shallow slabs.
 */

interface Family {
  selector: string;
  shape: GlassShape;
  press?: PressOptions | false;
  tag: string;
}

const FAMILIES: Family[] = [
  // Round icon buttons in the headers: small, thick, strongly refracting droplets.
  // Press feedback is deliberately calm: a small swell, almost no lean or stretch.
  { selector: '#lgtt .lgtt-btn.lgtt-round', shape: { kind: 'surface', bezel: 12, thickness: 22, strength: 1.15, ior: 1.5 }, press: { grow: 0.1, lean: 3, stretch: 0.04 }, tag: 'button' },
  // Input pills (comments, chat, search, inbox composer): the PILL is the glass, the field inside stays transparent.
  { selector: '#lgtt .lgtt-compose-pill, #lgtt .lgtt-search, #bmnRealInbox .bmn-ri-composer-shell, #bmnRealInbox .bmn-ri-search', shape: { kind: 'surface', bezel: 18, thickness: 20, strength: 0.7 }, press: false, tag: 'pill' },
  // Sheets (comments, DMs, settings, share): large and shallow, softer rim.
  { selector: '#lgtt aside.lgtt-sheet', shape: { kind: 'surface', bezel: 24, thickness: 30, strength: 0.8 }, press: false, tag: 'sheet' },
  // Menu / confirm cards that BMN renders itself.
  { selector: '#lgtt .lgtt-modal-card', shape: { kind: 'surface', bezel: 20, thickness: 26, strength: 0.9 }, press: false, tag: 'card' },
];

const Surface: React.FC<{ el: HTMLElement; family: Family }> = ({ el, family }) => {
  const ref = useMemo(() => ({ current: el }), [el]);
  useEffect(() => {
    el.classList.add('lg-glass', 'bmn-surface');
    el.dataset.bmnMaterial = family.tag;
    return () => {
      el.classList.remove('lg-glass', 'bmn-surface');
      delete el.dataset.bmnMaterial;
    };
  }, [el, family]);
  useRefraction(ref, family.shape, true);
  usePress(ref, family.press === false ? { disabled: true } : family.press || {});
  return null;
};

const live = new Map<HTMLElement, { unmount: () => void }>();
let stageEl: HTMLElement | null = null;

/** Mounts a material on every matching element that does not have one yet; drops the ones that left the DOM. */
export function scanSurfaces() {
  if (!stageEl) return;
  for (const [el, h] of live) {
    if (!el.isConnected) {
      h.unmount();
      live.delete(el);
    }
  }
  for (const family of FAMILIES) {
    for (const el of $$(family.selector)) {
      if (live.has(el)) continue;
      live.set(el, mount(stageEl, <Surface el={el} family={family} />, 'bmn-surfaces'));
    }
  }
}

export function bridgeSurfaces(stage: HTMLElement) {
  stageEl = stage;
  scanSurfaces();
}
