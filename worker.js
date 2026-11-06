// The converter Worker: runs recomp.wasm on the disc files (web/readers.js).
import { discOf } from "./readers.js";
import { Wasi } from "./wasi.js";

let module;

addEventListener("securitypolicyviolation", (e) =>
	postMessage({ csp: `csp (worker): ${e.effectiveDirective} blocked ${e.blockedURI || "inline"}` }));

onmessage = async ({ data: { files, urls, image, arch } }) => {
	try {
		module ??= await WebAssembly.compileStreaming(fetch("recomp.wasm"));
		const disc = discOf({ files, urls });
		const wasi = new Wasi({
			args: ["recomp", "--arch", arch, "/disc/" + image],
			disc,
			log: (_fd, text) => postMessage({ log: text }),
		});
		const start = performance.now();
		const code = wasi.run(await WebAssembly.instantiate(module, wasi.imports));
		const ms = Math.round(performance.now() - start);
		const out = [...wasi.files()].map(([name, b]) => ({ name, buffer: b.buffer, size: b.length }));
		postMessage({ done: { code, ms, stats: wasi.stats, out } }, out.map((o) => o.buffer));
	} catch (e) {
		postMessage({ error: String(e?.stack ?? e) });
	}
};
