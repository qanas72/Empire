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

// Display server-sent Web Push notifications.
self.addEventListener("push", event => {
  event.waitUntil((async () => {
    let payload = {};
    try { payload = event.data ? event.data.json() : {}; }
    catch (_) { payload = { body: event.data ? event.data.text() : "" }; }
    const title = payload.title || "EMPIRE";
    const options = {
      body: payload.body || "You have a new notification.",
      icon: payload.icon || "./icons/empire-icon.svg",
      badge: payload.badge || "./icons/empire-icon.svg",
      tag: payload.tag || "empire-notification",
      renotify: Boolean(payload.renotify),
      data: { url: payload.url || payload.target_url || "./notifications.html" }
    };
    await self.registration.showNotification(title, options);
  })());
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL(
    event.notification.data && event.notification.data.url
      ? event.notification.data.url
      : "./notifications.html",
    self.location.origin
  );
  if (target.origin !== self.location.origin) target.href = self.location.origin + "/notifications.html";
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin === self.location.origin) {
        await client.focus();
        if ("navigate" in client) await client.navigate(target.href);
        return;
      }
    }
    await self.clients.openWindow(target.href);
  })());
});
