// The play Worker: runs play.wasm (or, for the gate, another module with the
// same imports) on web/wasi.js and web/sdl.js. It never yields while the
// module runs; the page reaches it only through the SharedArrayBuffers.
import { discOf } from "./readers.js";
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

// wasm: the module's URL. args: argv after the program name. env: the
// module's environment. files or urls: the disc (web/readers.js). control,
// audio, present: the page's buffers. test: also send back, with done or
// error, the files the module wrote and, as ring.pcm, every sample it
// queued, plus the compile and run times.
onmessage = async ({ data: { wasm, args, env = {}, files, urls, test = false, control, audio, present } }) => {
	let wasi = null;
	const ring = [];
	const times = { compileMs: null, runMs: null };
	let t1 = null; // when the module started
	// The files for the page, copied out of the shim's buffers.
	const written = () => {
		if (!test || wasi === null) return undefined;
		const out = [...wasi.files()].map(([name, bytes]) => [name, bytes.slice()]);
		out.push(["ring.pcm", concat(ring)]);
		return out;
	};
	try {
		const t0 = performance.now();
		const module = await WebAssembly.compileStreaming(fetch(wasm));
		times.compileMs = Math.round(performance.now() - t0);
		const log = (_fd, text) => postMessage({ log: text });
		wasi = new Wasi({ args: [wasm.replace(/\.wasm$/, ""), ...args], env, disc: discOf({ files, urls }), log });
		const tee = test ? (samples) => ring.push(samples.slice()) : null;
		const sdl = new Sdl({ control, audio, present, post: (m) => postMessage(m), tee });
		const instance = await WebAssembly.instantiate(module, { ...wasi.imports, "system:SDL2": sdl.imports });
		sdl.attach(instance);
		t1 = performance.now();
		const code = wasi.run(instance);
		times.runMs = Math.round(performance.now() - t1);
		postMessage({ done: { code, stats: wasi.stats, ...times }, files: written() });
	} catch (e) {
		if (t1 !== null) times.runMs = Math.round(performance.now() - t1);
		postMessage({ error: String(e?.stack ?? e), times, files: written() });
	}
};
