import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { GlassSheet } from '@zakisheriff/liquid-glass';
import { theme, watch, whenReady } from '../dom';
import { mount } from '../mount';

/**
 * GlassSheet for BMN's shared sheet host (#bmnSheetHost): sign-in, sign-up,
 * install offer, report and share-style sheets all go through it.
 *
 * The existing `sheet()` keeps building the content into its `.bmn-sh` box and
 * wiring every button. We move that box, untouched, inside a GlassSheet, so
 * the sheet gets glass material, a spring entrance and drag / flick to
 * dismiss, while all of BMN's logic keeps running on the same DOM.
 */

/**
 * Holds BMN's original `.bmn-sh` box while the glass sheet is on screen and,
 * crucially, hands it BACK to the host when the sheet goes away: `sheet()` looks
 * the box up in the host on every call, so React must never take it with it.
 */
const Slot: React.FC<{ host: HTMLElement }> = ({ host }) => {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const target = ref.current;
    const box = host.querySelector<HTMLElement>('.bmn-sh');
    if (box && target) target.appendChild(box);
    return () => {
      const parked = target?.querySelector<HTMLElement>('.bmn-sh');
      if (parked) host.appendChild(parked);
    };
  }, [host]);
  return <div ref={ref} className="bmn-gsh-slot" />;
};

const Bridge: React.FC<{ host: HTMLElement }> = ({ host }) => {
  const [open, setOpen] = useState(host.dataset.open === '1');
  const [mode, setMode] = useState(theme());
  const closing = useRef(0);

  useEffect(() => {
    const stop = watch(host, () => {
      const next = host.dataset.open === '1';
      setOpen((prev) => {
        if (prev && !next) {
          // Keep the host painted while the glass sheet springs away.
          host.setAttribute('data-glass-closing', '1');
          window.clearTimeout(closing.current);
          closing.current = window.setTimeout(() => host.removeAttribute('data-glass-closing'), 520);
        }
        if (!prev && next) {
          // A sheet opened by a touch release must not be closed by that touch's ghost click.
          host.setAttribute('data-glass-fresh', '1');
          window.setTimeout(() => host.removeAttribute('data-glass-fresh'), 450);
        }
        return next;
      });
    }, { attributes: true, attributeFilter: ['data-open'] });
    // The synthesized click that follows the touch RELEASE which opened this sheet lands on
    // the scrim; swallow it (capture phase, before React's delegated handler) so the sheet
    // can't be dismissed by the very gesture that opened it.
    const ghost = (e: Event) => {
      if (Date.now() - (Number(host.dataset.t0) || 0) < 450 && (e.target as HTMLElement).closest?.('.lg-sheet__scrim')) {
        e.stopPropagation();
        e.preventDefault();
      }
    };
    host.addEventListener('click', ghost, true);
    const stopBody = watch(document.body, () => setMode(theme()), { attributes: true, attributeFilter: ['class'] });
    return () => {
      stop();
      stopBody();
      host.removeEventListener('click', ghost, true);
    };
  }, [host]);

  return (
    <div data-theme={mode} className="bmn-gsh">
      <GlassSheet
        open={open}
        container={host}
        intensity={6}
        tint="rgb(150 24 40 / 0.10)"
        aria-label="BMN"
        onClose={() => (window as unknown as { bmnCloseSheet?: () => void }).bmnCloseSheet?.()}
      >
        <Slot host={host} />
      </GlassSheet>
    </div>
  );
};

export function bridgeSheetHost() {
  // sheet() builds #bmnSheetHost lazily, on first use.
  whenReady('#bmnSheetHost', (host) => {
    if (host.dataset.bmnGlass) return;
    host.dataset.bmnGlass = '1';
    mount(host, <Bridge host={host} />, 'bmn-gsh-host');
  }, 600000);
}
