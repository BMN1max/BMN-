/* BMN Community service worker — delivery/cache/update layer only.
   SUPABASE = source of truth · FRONTEND = application · SERVICE WORKER = static delivery + updates.
   Never caches: Supabase/API traffic, private media, realtime, non-GET requests, range/media requests. */
const CACHE_NAME = 'bmn-application-v1.0.6';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((cacheNames) => Promise.all(
        cacheNames.map((cacheName) => {
          // delete only OLD BMN application caches — never unrelated caches
          if (cacheName.startsWith('bmn-application-') && cacheName !== CACHE_NAME) {
            return caches.delete(cacheName);
          }
          return undefined;
        })
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;                              // never intercept writes
  if (request.headers.has('range')) return;                          // video seeking must hit the network
  if (request.destination === 'video' || request.destination === 'audio') return;

  const url = new URL(request.url);
  if (url.hostname.includes('supabase.co')) return;                  // API, auth, realtime, storage: never cached
  if (url.origin !== self.location.origin) return;                   // no blind cross-origin caching

  event.respondWith(
    fetch(request)
      .then(async (response) => {
        if (response.ok && response.type === 'basic') {
          try {
            const cache = await caches.open(CACHE_NAME);
            await cache.put(request, response.clone());
          } catch (cacheError) {
            console.warn('[BMN SW] Cache write failed', cacheError);   // cache failures must never break the network response
          }
        }
        return response;
      })
      .catch(async () => {
        const cached = await caches.match(request);
        if (cached) return cached;
        if (request.mode === 'navigate') {
          const shell = (await caches.match('/index.html')) || (await caches.match('/'));
          if (shell) return shell;
        }
        throw new Error('BMN resource unavailable offline');
      })
  );
});
