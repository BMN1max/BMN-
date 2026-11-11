import React, { useEffect, useRef, useState } from 'react';
import { GlassInput, GlassSegmented, GlassSlider, GlassSwitch } from '@zakisheriff/liquid-glass';
import { $$, theme, watch } from '../dom';
import { mount } from '../mount';

/**
 * Bridges for form-like controls. In every case the ORIGINAL element stays in
 * the DOM and stays the source of truth (its listeners, state and `.value` are
 * untouched). The glass control is a view over it: it reads the original's
 * state and, when the user acts, drives the original through its normal events.
 */

const useTheme = () => {
  const [mode, setMode] = useState(theme());
  useEffect(() => watch(document.body, () => setMode(theme()), { attributes: true, attributeFilter: ['class'] }), []);
  return mode;
};

/* ---------------------------------------------------------------- Segmented */

const SegBridge: React.FC<{ el: HTMLElement }> = ({ el }) => {
  const read = () => {
    const buttons = $$('button[role="tab"]', el);
    return { labels: buttons.map((b) => (b.textContent || '').trim()), index: Math.max(0, buttons.findIndex((b) => b.classList.contains('on') || b.getAttribute('aria-selected') === 'true')), buttons };
  };
  const [state, setState] = useState(read);
  const mode = useTheme();
  useEffect(() => watch(el, () => setState(read()), { attributes: true, childList: true, subtree: true, characterData: true, attributeFilter: ['class', 'aria-selected'] }), [el]);
  if (!state.labels.length) return null;
  return (
    <div className="bmn-gs" data-theme={mode} data-bmn-glass="segmented">
      <GlassSegmented
        options={state.labels}
        value={state.index}
        size={el.classList.contains('lgtt-seg-4') ? 'sm' : 'md'}
        intensity={5}
        aria-label={el.getAttribute('aria-label') || undefined}
        onChange={(i) => read().buttons[i]?.click()}
      />
    </div>
  );
};

/** Keeps `host` exactly over `target` (same offset parent), without living inside it:
 *  BMN styles `.lgtt-tabs button` / `.lgtt-seg button`, which must not reach the glass control's own buttons. */
function overlay(host: HTMLElement, target: HTMLElement) {
  const place = () => {
    host.style.position = 'absolute';
    host.style.left = target.offsetLeft + 'px';
    host.style.top = target.offsetTop + 'px';
    host.style.width = target.offsetWidth + 'px';
    host.style.height = target.offsetHeight + 'px';
    host.style.zIndex = '2';
  };
  const ro = new ResizeObserver(place);
  ro.observe(target);
  const stop = watch(target.parentElement || target, place, { attributes: true, childList: true, subtree: false, attributeFilter: ['class', 'style', 'hidden'] });
  window.addEventListener('resize', place);
  place();
  return () => {
    ro.disconnect();
    stop();
    window.removeEventListener('resize', place);
  };
}

export function bridgeSegmented() {
  for (const sel of ['#lgttTabs', '#lgttCmtSort', '#lgttDmTabs', '#lgttSetTabs']) {
    const el = document.querySelector<HTMLElement>(sel);
    if (!el || el.dataset.bmnSeg || !el.parentElement) continue;
    el.dataset.bmnSeg = '1';
    const h = mount(el.parentElement, <SegBridge el={el} />, 'bmn-gs-host', el.nextSibling);
    overlay(h.host, el);
  }
}

/* ------------------------------------------------------------------- Switch */

const SwitchBridge: React.FC<{ btn: HTMLElement }> = ({ btn }) => {
  const [on, setOn] = useState(btn.getAttribute('aria-checked') === 'true');
  const mode = useTheme();
  useEffect(() => watch(btn, () => setOn(btn.getAttribute('aria-checked') === 'true'), { attributes: true, attributeFilter: ['aria-checked'] }), [btn]);
  return (
    <span className="bmn-gw" data-theme={mode} data-bmn-glass="switch">
      <GlassSwitch checked={on} tint="#d1323e" intensity={5} aria-label={btn.getAttribute('aria-label') || undefined} onChange={() => btn.click()} />
    </span>
  );
};

const bridged = new Map<HTMLElement, { unmount: () => void }>();

function sweep() {
  for (const [slot, handle] of bridged) {
    if (!slot.isConnected) {
      handle.unmount();
      bridged.delete(slot);
    }
  }
}

export function bridgeSwitches() {
  sweep();
  for (const btn of $$('button.lgtt-switch[role="switch"], button#powerToggle[role="switch"]')) {
    if (btn.dataset.bmnSw) continue;
    btn.dataset.bmnSw = '1';
    const slot = document.createElement('span');
    slot.className = 'bmn-gw-slot';
    btn.after(slot);
    bridged.set(slot, mount(slot, <SwitchBridge btn={btn} />, 'bmn-gw-host'));
  }
}

/* ------------------------------------------------------------------- Slider */

const SliderBridge: React.FC<{ input: HTMLInputElement }> = ({ input }) => {
  const num = (v: string, d: number) => (Number.isFinite(parseFloat(v)) ? parseFloat(v) : d);
  const [value, setValue] = useState(num(input.value, 0));
  const mode = useTheme();
  useEffect(() => {
    const sync = () => setValue(num(input.value, 0));
    input.addEventListener('input', sync);
    input.addEventListener('change', sync);
    return () => {
      input.removeEventListener('input', sync);
      input.removeEventListener('change', sync);
    };
  }, [input]);
  const push = (v: number) => {
    setValue(v);
    const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    set?.call(input, String(v));
    input.dispatchEvent(new Event('input', { bubbles: true }));
  };
  return (
    <span className="bmn-gsl" data-theme={mode} data-bmn-glass="slider">
      <GlassSlider
        min={num(input.min, 0)}
        max={num(input.max, 100)}
        step={num(input.step, 1)}
        value={value}
        onChange={push}
        tint="#d1323e"
        aria-label={input.getAttribute('aria-label') || undefined}
      />
    </span>
  );
};

export function bridgeSliders(root: ParentNode = document) {
  sweep();
  for (const input of Array.from(root.querySelectorAll<HTMLInputElement>('#lgtt input[type="range"], .app input[type="range"]'))) {
    if (input.dataset.bmnSl) continue;
    input.dataset.bmnSl = '1';
    const slot = document.createElement('span');
    slot.className = 'bmn-gsl-slot';
    input.after(slot);
    bridged.set(slot, mount(slot, <SliderBridge input={input} />, 'bmn-gsl-host'));
  }
}

/* -------------------------------------------------------------------- Input */

const InputBridge: React.FC<{ input: HTMLInputElement }> = ({ input }) => {
  const [value, setValue] = useState(input.value);
  const mine = useRef<HTMLInputElement>(null);
  const mode = useTheme();
  const search = input.type === 'search';

  useEffect(() => {
    // Programmatic writes by BMN (e.g. clearing the composer after send) reach the glass field.
    const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!;
    Object.defineProperty(input, 'value', {
      configurable: true,
      get() {
        return desc.get!.call(this);
      },
      set(v: string) {
        desc.set!.call(this, v);
        setValue(String(v));
      },
    });
    // Programmatic focus (opening a chat, tapping the comment button) lands on the visible field.
    const nativeFocus = input.focus.bind(input);
    input.focus = (opts?: FocusOptions) => (mine.current ? mine.current.focus(opts) : nativeFocus(opts));
    input.blur = () => mine.current?.blur();
    return () => {
      delete (input as unknown as Record<string, unknown>).value;
      delete (input as unknown as Record<string, unknown>).focus;
      delete (input as unknown as Record<string, unknown>).blur;
    };
  }, [input]);

  const forward = (e: React.KeyboardEvent<HTMLInputElement>) => {
    input.dispatchEvent(new KeyboardEvent(e.type, { key: e.key, code: e.code, bubbles: true, cancelable: true }));
  };

  return (
    <div className="bmn-gi" data-theme={mode} data-bmn-glass="input">
      <GlassInput
        ref={mine}
        type={search ? 'search' : 'text'}
        value={value}
        placeholder={input.placeholder}
        maxLength={input.maxLength > 0 ? input.maxLength : undefined}
        enterKeyHint={input.enterKeyHint as React.HTMLAttributes<HTMLInputElement>['enterKeyHint']}
        autoComplete={input.autocomplete || 'off'}
        aria-label={input.getAttribute('aria-label') || undefined}
        tint="#ff4d5e"
        intensity={4}
        onKeyDown={forward}
        onKeyUp={forward}
        onChange={(e) => {
          setValue(e.target.value);
          const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
          set?.call(input, e.target.value);
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }}
        onFocus={() => input.dispatchEvent(new FocusEvent('focus'))}
        onBlur={() => input.dispatchEvent(new FocusEvent('blur'))}
      />
    </div>
  );
};

export function bridgeInputs() {
  for (const sel of ['#lgttChatInput', '#lgttCmtInput', '#lgttCmtSearch', '#lgttDmSearch', '#lgtt .lgtt-search input[type="search"]']) {
    for (const input of $$<HTMLInputElement>(sel)) {
      // Never bridge the <input> that GlassInput itself renders: `.lgtt-search input[type=search]`
      // also matches it, which re-wrapped the glass field in another glass field on every DOM change.
      if (input.dataset.bmnIn || input.closest('.bmn-gi-host')) continue;
      input.dataset.bmnIn = '1';
      const parent = input.parentElement!;
      parent.classList.add('bmn-gi-wrap');
      mount(parent, <InputBridge input={input} />, 'bmn-gi-host', input);
    }
  }
}
