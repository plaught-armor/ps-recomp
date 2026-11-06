// The play Worker: runs play.wasm (or, for the gate, another module with the
// same imports) on web/wasi.js and web/sdl.js. It never yields while the
// module runs; the page reaches it only through the SharedArrayBuffers.
import { buildId, NetImports, NO_NET } from "./net.js";
import { dataLoad, dataSave, discOf, openStored, store } from "./readers.js";
import { Native } from "./native.js";
import { Sdl } from "./sdl.js";
import { Wasi } from "./wasi.js";

addEventListener("securitypolicyviolation", (e) =>
	postMessage({ csp: `csp (worker): ${e.effectiveDirective} blocked ${e.blockedURI || "inline"}` }));

// The bytes of a list of Int16Array chunks, one after the other.
function concat(chunks) {
	const out = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
	let at = 0;
	for (const c of chunks) {
		out.set(new Uint8Array(c.buffer, c.byteOffset, c.byteLength), at);
		at += c.byteLength;
	}
	return out;
}

// The transfer list for written files: each one's own buffer.
const buffers = (files) => (files ?? []).map(([, b]) => b.buffer);

// The disc for Wasi, {disc, close()}, and how it is read, which goes to the
// page as {store: {kind, ...}}. stored: play that stored disc. store with
// files or urls: copy them into the store under that name first, and read
// them as picked or by URL if that fails (no OPFS, a full quota). Neither:
// read files or urls directly.
async function discFor({ files, urls, store: name, stored }) {
	if (stored) {
		const d = await openStored(stored).catch((e) => {
			if (e.name !== "NoModificationAllowedError") throw e;
			throw new Error(`${stored}: this disc is playing in another tab`);
		});
		return { ...d, info: { kind: "stored", name: stored } };
	}
	if (name) {
		const t0 = performance.now();
		try {
			await store(name, files ?? urls);
			const d = await openStored(name);
			return { ...d, info: { kind: "opfs", name, copyMs: Math.round(performance.now() - t0) } };
		} catch (e) {
			const estimate = await navigator.storage?.estimate?.().catch(() => null);
			const fallback = { kind: files ? "file" : "url", stored: false, error: `${e.name}: ${e.message}`, estimate };
			return { disc: discOf({ files, urls }), close() {}, info: fallback };
		}
	}
	return { disc: discOf({ files, urls }), close() {}, info: { kind: files ? "file" : "url" } };
}

// wasm: the module's URL. args: argv after the program name. env: the
// module's environment. files, urls, store, stored: the disc (discFor). control,
// audio, present: the page's buffers; net, for netplay, the NET one. test: also send back, with done or
// error, the files the module wrote and, as ring.pcm, every sample it
// queued (their buffers transferred, not copied), plus the compile and run
// times.
onmessage = async ({ data }) => {
	const { wasm, args, env = {}, test = false, control, audio, present, net: netBuffer } = data;
	let wasi = null;
	let disc = null;
	const ring = [];
	const times = { compileMs: null, runMs: null };
	let t1 = null; // when the module started
	let stored = null; // what dataLoad gave, null when /data is not stored
	// /data back into the store, before done or error goes to the page: a
	// run started after it then finds the store whole.
	const save = async () => {
		if (stored === null) return;
		await dataSave(wasi.files(wasi.data), stored).catch((e) =>
			postMessage({ log: `play: the data of this run cannot be stored (${e.name}: ${e.message})\n` }));
	};
	// The files for the page, copied out of the shim's buffers.
	const written = () => {
		if (!test || wasi === null) return undefined;
		const out = [...wasi.files()].map(([name, bytes]) => [name, bytes.slice()]);
		out.push(["ring.pcm", concat(ring)]);
		return out;
	};
	try {
		const t0 = performance.now();
		// The bytes, not a stream: netplay's build id is their hash.
		const response = await fetch(wasm);
		if (!response.ok) throw new Error(`${wasm}: ${response.status}`);
		const bytes = await response.arrayBuffer();
		const module = await WebAssembly.compile(bytes);
		const net = netBuffer ? new NetImports(netBuffer, await buildId(bytes)) : null;
		times.compileMs = Math.round(performance.now() - t0);
		const log = (_fd, text) => postMessage({ log: text });
		disc = await discFor(data);
		postMessage({ store: disc.info });
		wasi = new Wasi({ args: [wasm.replace(/\.wasm$/, ""), ...args], env, disc: disc.disc, log });
		// /data from the store (readers.js), but in test mode, whose runs start
		// from an empty /data so they compare with native ones.
		if (!test && typeof navigator.storage?.getDirectory === "function") {
			try {
				stored = await dataLoad();
				wasi.seed(stored);
			} catch (e) {
				stored = null;
				postMessage({ log: `play: the stored data cannot be read (${e.name}: ${e.message}); this run starts without it and stores nothing\n` });
			}
		}
		const tee = test ? (samples) => ring.push(samples.slice()) : null;
		const sdl = new Sdl({ control, audio, present, post: (m) => postMessage(m), tee });
		const native = new Native({ log: (text) => postMessage({ log: text }) });
		const instance = await WebAssembly.instantiate(module, {
			...wasi.imports,
			"system:SDL2": sdl.imports,
			"system:ps_native": native.imports,
			"system:ps_net": net?.imports ?? NO_NET,
		});
		sdl.attach(instance);
		native.attach(instance);
		net?.attach(instance);
		t1 = performance.now();
		const code = wasi.run(instance);
		times.runMs = Math.round(performance.now() - t1);
		await save();
		const files = written();
		postMessage({ done: { code, stats: wasi.stats, ...times }, files }, buffers(files));
	} catch (e) {
		if (t1 !== null) times.runMs = Math.round(performance.now() - t1);
		await save();
		const files = written();
		postMessage({ error: String(e?.stack ?? e), times, files }, buffers(files));
	} finally {
		disc?.close();
	}
};
