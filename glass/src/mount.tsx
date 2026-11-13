import React from 'react';
import { createRoot, type Root } from 'react-dom/client';

/** Every React root the layer creates, so the kill switch can unmount all of them. */
const roots: Array<{ root: Root; host: HTMLElement }> = [];

/** Mounts `node` in a new host div appended to `parent`. Returns an unmount handle. */
export function mount(parent: HTMLElement, node: React.ReactNode, className: string, before?: Node | null) {
  const host = document.createElement('div');
  host.className = className;
  host.setAttribute('data-bmn-glass-host', '');
  parent.insertBefore(host, before ?? null);
  const root = createRoot(host);
  root.render(node);
  const entry = { root, host };
  roots.push(entry);
  return {
    host,
    unmount() {
      const i = roots.indexOf(entry);
      if (i >= 0) roots.splice(i, 1);
      root.unmount();
      host.remove();
    },
  };
}

export function unmountAll() {
  for (const { root, host } of roots.splice(0)) {
    root.unmount();
    host.remove();
  }
}
