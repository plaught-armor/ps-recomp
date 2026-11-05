// The converter Worker: runs recomp.wasm on the disc files. Picked files are
// read through FileReaderSync on File.slice, so the image is never read
// whole; the page's test mode gives URLs instead, read by HTTP Range.
import { Wasi } from "./wasi.js";

let module;

const fileReader = (f) => {
	const fr = new FileReaderSync();
	return { size: f.size, read: (offset, length) => new Uint8Array(fr.readAsArrayBuffer(f.slice(offset, offset + length))) };
};

const urlReader = ({ url, size }) => ({
	size,
	read(offset, length) {
		const x = new XMLHttpRequest();
		x.open("GET", url, false);
		x.responseType = "arraybuffer";
		x.setRequestHeader("Range", `bytes=${offset}-${offset + length - 1}`);
		x.send();
		if (x.status !== 206) throw new Error(`${url}: HTTP ${x.status} for a range read`);
		return new Uint8Array(x.response);
	},
});

onmessage = async ({ data: { files, urls, image, arch } }) => {
	try {
		module ??= await WebAssembly.compileStreaming(fetch("recomp.wasm"));
		const disc = new Map(files ? files.map((f) => [f.name, fileReader(f)]) : urls.map((u) => [u.name, urlReader(u)]));
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
