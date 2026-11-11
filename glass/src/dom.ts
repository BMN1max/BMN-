/** Small DOM helpers shared by the bridges. Nothing here knows about React. */

export const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector<T>(sel);
export const $$ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => Array.from(root.querySelectorAll<T>(sel));

/** Runs `cb` once an element matching `sel` exists (the app builds some DOM lazily). */
export function whenReady(sel: string, cb: (el: HTMLElement) => void, timeout = 30000) {
  const found = $(sel);
  if (found) return cb(found), () => {};
  const mo = new MutationObserver(() => {
    const el = $(sel);
    if (el) {
      mo.disconnect();
      clearTimeout(timer);
      cb(el);
    }
  });
  mo.observe(document.documentElement, { childList: true, subtree: true });
  const timer = window.setTimeout(() => mo.disconnect(), timeout);
  return () => {
    mo.disconnect();
    clearTimeout(timer);
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
