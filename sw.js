// Cross-origin isolation for hosts that cannot send headers (GitHub Pages):
// adds COOP and COEP to every same-origin response this page loads, so it
// gets SharedArrayBuffer. The play page registers it and reloads once; a
// server that sends the headers itself (serve.py) needs none of this.
// Unverified on Safari: WebKit may not isolate a page through a service
// worker's headers.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (e) => {
	const req = e.request;
	if (new URL(req.url).origin !== self.location.origin) return;
	// Firefox throws on this mode outside same-origin requests.
	if (req.cache === "only-if-cached" && req.mode !== "same-origin") return;
	e.respondWith((async () => {
		const res = await fetch(req);
		// Opaque or error responses cannot be rebuilt.
		if (res.status === 0) return res;
		const headers = new Headers(res.headers);
		headers.set("Cross-Origin-Opener-Policy", "same-origin");
		headers.set("Cross-Origin-Embedder-Policy", "require-corp");
		headers.set("Cross-Origin-Resource-Policy", "same-origin");
		return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
	})());
});
