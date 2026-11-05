// The play Worker: runs play.wasm (or, for the gate, another module with the
// same imports) on web/wasi.js and web/sdl.js. It never yields while the
// module runs; the page reaches it only through the SharedArrayBuffers.
import { discOf } from "./readers.js";
import { Sdl } from "./sdl.js";
import { Wasi } from "./wasi.js";

addEventListener("securitypolicyviolation", (e) =>
	postMessage({ csp: `csp (worker): ${e.effectiveDirective} blocked ${e.blockedURI || "inline"}` }));

// wasm: the module's URL. args: argv after the program name. files or urls:
// the disc (web/readers.js). control, audio, present: the page's buffers.
onmessage = async ({ data: { wasm, args, files, urls, control, audio, present } }) => {
	try {
		const module = await WebAssembly.compileStreaming(fetch(wasm));
		const log = (_fd, text) => postMessage({ log: text });
		const wasi = new Wasi({ args: [wasm.replace(/\.wasm$/, ""), ...args], disc: discOf({ files, urls }), log });
		const sdl = new Sdl({ control, audio, present, post: (m) => postMessage(m) });
		const instance = await WebAssembly.instantiate(module, { ...wasi.imports, "system:SDL2": sdl.imports });
		sdl.attach(instance);
		const code = wasi.run(instance);
		postMessage({ done: { code, stats: wasi.stats } });
	} catch (e) {
		postMessage({ error: String(e?.stack ?? e) });
	}
};
