const CACHE_NAME = "empire-pwa-static-v1";
const APP_ICONS = ["./icons/empire-icon.svg"];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_ICONS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(key => key.startsWith("empire-pwa-") && key !== CACHE_NAME)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

// Only cache the public app icon. Never cache HTML, authenticated pages,
// Supabase API responses, wallet data, messages, or other private content.
self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || !url.pathname.includes("/icons/")) return;

  event.respondWith(
    caches.match(request).then(cached => cached || fetch(request))
  );
});