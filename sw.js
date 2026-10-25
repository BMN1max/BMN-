/* BMN Community service worker — delivery/cache/update layer only.
   SUPABASE = source of truth · FRONTEND = application · SERVICE WORKER = static delivery + updates.
   Never caches: Supabase/API traffic, private media, realtime, non-GET requests, range/media requests.
   v1.0.7: network-first WITH A TIMEOUT. A slow or hanging connection now falls back to the saved copy
   after a few seconds instead of leaving a blank white screen. */
const CACHE_NAME = 'bmn-application-v1.0.7';
const SHELL = ['/', '/index.html', '/manifest.webmanifest', '/bmn-icon.svg', '/bmn-icon-192.png'];
const NAV_TIMEOUT_MS = 3500;     // page loads: give the network 3.5 s, then use the saved copy
const ASSET_TIMEOUT_MS = 5000;   // icons, manifest and other same-origin files

self.addEventListener('install', (event) => {
  self.skipWaiting();
  // Warm the app shell so the very first slow/offline open still has something to show.
  // Each file is added on its own so one missing file can never break installation.
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(SHELL.map((u) => cache.add(new Request(u, { cache: 'reload' })).catch(() => undefined)))
    )
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.map((n) =>
        // delete only OLD BMN application caches — never unrelated caches
        (n.startsWith('bmn-application-') && n !== CACHE_NAME) ? caches.delete(n) : undefined
      )))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

function timeout(ms) {
  return new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms));
}

async function fromCache(request) {
  const cached = await caches.match(request, { ignoreSearch: request.mode === 'navigate' });
  if (cached) return cached;
  if (request.mode === 'navigate') {
    return (await caches.match('/index.html')) || (await caches.match('/'));
  }
  return undefined;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;                              // never intercept writes
  if (request.headers.has('range')) return;                          // video seeking must hit the network
  if (request.destination === 'video' || request.destination === 'audio') return;

  const url = new URL(request.url);
  if (url.hostname.includes('supabase.co')) return;                  // API, auth, realtime, storage: never cached
  if (url.origin !== self.location.origin) return;                   // no blind cross-origin caching

  const limit = request.mode === 'navigate' ? NAV_TIMEOUT_MS : ASSET_TIMEOUT_MS;

  event.respondWith((async () => {
    const network = fetch(request).then(async (response) => {
      if (response.ok && response.type === 'basic') {
        try {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(request, response.clone());              // keeps the saved copy fresh in the background
        } catch (e) { /* cache failures must never break the network response */ }
      }
      return response;
    });
    try {
      return await Promise.race([network, timeout(limit)]);
    } catch (err) {
      const cached = await fromCache(request);
      if (cached) {
        network.catch(() => undefined);                            // let the slow request finish and refresh the cache
        return cached;
      }
      return network;                                              // nothing saved yet: keep waiting for the network
    }
  })());
});
