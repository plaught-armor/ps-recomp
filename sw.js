const COMMIT = "663e3e91f358e521cfd2672482dd28118bd35cf7";
const SHELL = ["index.html", "page.css", "page.js", "worker.js", "readers.js", "wasi.js", "play.html", "play.js", "play-worker.js", "band.js", "band-worker.js", "learn.js", "native.js", "sdl.js", "net.js", "keys.js", "layout.js", "present.js", "audio.js", "recomp.wasm", "play.wasm", "commit.txt", ];
// The pages' service worker. It does two things.
//
// It adds the cross-origin isolation headers (COOP, COEP, CORP) to every
// same-origin response, for a host that cannot send them (GitHub Pages):
// play.js registers it and reloads once.
//
// It keeps the build's own files (SHELL: the pages, their scripts,
// recomp.wasm, play.wasm and commit.txt) in a cache named for the build's
// commit, so the pages load with no network. Discs and play's data are in
// OPFS already (web/readers.js, play-worker.js), so a stored disc plays
// offline. web/build.sh writes COMMIT and SHELL at the top of this file,
// so every build has its own sw.js bytes and the browser installs it as a
// new worker. Install fetches the whole shell past the HTTP cache and
// checks that commit.txt names COMMIT (a host can serve an older file for
// a while after a deploy); if any fetch fails, the install fails and the
// old worker keeps its whole old cache. Activate deletes every other
// build's cache.
//
// A page loaded from cache while a newer build is deployed would run the
// old build once more. So each navigation, when online, asks the network
// for commit.txt (2 s at most); when it names another build, this worker
// is stale: it serves the shell from the network, as it would with no
// cache, and asks the browser to update it. Offline, or past the 2 s, the
// cache serves.
//
// A tree with changes builds COMMIT "<hash>-dirty", which stays the same
// across rebuilds: such a worker caches nothing. Requests other than GET,
// and paths outside SHELL (test discs, the test server's POSTs and
// signal queue), go to the network as they always did.
const CACHE = `ps-recomp-${COMMIT}`;
const CACHING = !COMMIT.endsWith("-dirty");
const SCOPE = new URL("./", self.location).pathname;
const CHECK_MS = 2000;
let stale = false;

// The SHELL name for a same-origin URL, or "" when it is not one. The
// scope's own path is index.html.
function shellName(url) {
	if (url.origin !== self.location.origin || !url.pathname.startsWith(SCOPE)) return "";
	const name = url.pathname.slice(SCOPE.length) || "index.html";
	return SHELL.includes(name) ? name : "";
}

function isolated(res) {
	if (res.status === 0) return res;
	const headers = new Headers(res.headers);
	headers.set("Cross-Origin-Opener-Policy", "same-origin");
	headers.set("Cross-Origin-Embedder-Policy", "require-corp");
	headers.set("Cross-Origin-Resource-Policy", "same-origin");
	return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

self.addEventListener("install", (e) => {
	self.skipWaiting();
	if (!CACHING) return;
	e.waitUntil((async () => {
		// addAll stores nothing unless every fetch is ok.
		const cache = await caches.open(CACHE);
		await cache.addAll(SHELL.map((name) => new Request(name, { cache: "reload" })));
		const commit = (await (await cache.match("commit.txt")).text()).trim();
		if (commit !== COMMIT) {
			await caches.delete(CACHE);
			throw new Error(`sw: commit.txt is ${commit}, not ${COMMIT}`);
		}
	})());
});

self.addEventListener("activate", (e) => e.waitUntil((async () => {
	for (const key of await caches.keys()) {
		if (key.startsWith("ps-recomp-") && key !== CACHE) await caches.delete(key);
	}
	await self.clients.claim();
})()));

// On a navigation, whether the deployed build is still this one.
async function check() {
	try {
		const res = await fetch(new Request("commit.txt", { cache: "no-store" }), { signal: AbortSignal.timeout(CHECK_MS) });
		if (!res.ok) return;
		const commit = (await res.text()).trim();
		if (commit !== COMMIT) {
			stale = true;
			self.registration.update().catch(() => {});
		}
	} catch {
		// Offline or slow: the cache serves.
	}
}

async function serve(req, name) {
	if (CACHING && req.method === "GET" && name) {
		if (req.mode === "navigate") await check();
		if (!stale) {
			const hit = await caches.match(name, { cacheName: CACHE });
			if (hit) return isolated(hit);
		}
	}
	return isolated(await fetch(req));
}

self.addEventListener("fetch", (e) => {
	const req = e.request;
	const url = new URL(req.url);
	if (url.origin !== self.location.origin) return;
	if (req.cache === "only-if-cached" && req.mode !== "same-origin") return;
	e.respondWith(serve(req, shellName(url)));
});
