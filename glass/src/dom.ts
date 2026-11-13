/** Small DOM helpers shared by the bridges. Nothing here knows about React. */

export const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector<T>(sel);
export const $$ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => Array.from(root.querySelectorAll<T>(sel));

/**
 * Runs `cb` once an element matching `sel` exists (the app builds some DOM lazily).
 * All pending waiters share ONE MutationObserver on <body>/<html>, checked at most once per frame, and it
 * disconnects as soon as nobody is waiting (or after `timeout`), so a missing element never leaves an
 * observer behind.
 */
const waiters = new Set<{ sel: string; cb: (el: HTMLElement) => void; timer: number }>();
let sharedMo: MutationObserver | null = null;
let sharedRaf = 0;

function checkWaiters() {
  sharedRaf = 0;
  for (const w of Array.from(waiters)) {
    const el = $(w.sel);
    if (el) {
      waiters.delete(w);
      clearTimeout(w.timer);
      w.cb(el);
    }
  }
  if (!waiters.size) {
    sharedMo?.disconnect();
    sharedMo = null;
  }
}

export function whenReady(sel: string, cb: (el: HTMLElement) => void, timeout = 30000) {
  const found = $(sel);
  if (found) return cb(found), () => {};
  const w = {
    sel,
    cb,
    timer: window.setTimeout(() => {
      waiters.delete(w);
      if (!waiters.size) {
        sharedMo?.disconnect();
        sharedMo = null;
      }
    }, timeout),
  };
  waiters.add(w);
  if (!sharedMo) {
    sharedMo = new MutationObserver(() => {
      if (!sharedRaf) sharedRaf = requestAnimationFrame(checkWaiters);
    });
    sharedMo.observe(document.documentElement, { childList: true, subtree: true });
  }
  return () => {
    clearTimeout(w.timer);
    waiters.delete(w);
    if (!waiters.size) {
      sharedMo?.disconnect();
      sharedMo = null;
    }
  };
}

/** Observe attribute / child changes of `target`; returns a disposer. */
export function watch(target: Node, cb: () => void, opts: MutationObserverInit = { attributes: true, childList: true, subtree: true, characterData: true }) {
  let queued = 0;
  const mo = new MutationObserver(() => {
    if (queued) return;
    queued = requestAnimationFrame(() => {
      queued = 0;
      cb();
    });
  });
  mo.observe(target, opts);
  return () => {
    mo.disconnect();
    if (queued) cancelAnimationFrame(queued);
  };
}

export function signedIn(): boolean {
  const w = window as unknown as { bmnSession?: { user?: { id?: string } } | null };
  return !!w.bmnSession?.user;
}

export function toast(message: string) {
  try {
    (window as unknown as { LGTT?: { toast?: (m: string, i?: string) => void } }).LGTT?.toast?.(message, 'info');
  } catch {
    /* toast is a nicety */
  }
}

/** Resolves the light/dark token set the library CSS should use for a node. */
export function theme(): 'light' | 'dark' {
  const light = document.body.classList.contains('light') || document.documentElement.getAttribute('data-bmn-theme') === 'light';
  return light ? 'light' : 'dark';
}
