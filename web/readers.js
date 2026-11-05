// Disc readers for web/wasi.js in a Worker: {size, read(offset, length) ->
// Uint8Array}. A picked file is read through FileReaderSync on File.slice,
// so the image is never read whole; a test page's URL is read by HTTP
// Range requests.

export const fileReader = (f) => {
	const fr = new FileReaderSync();
	return { size: f.size, read: (offset, length) => new Uint8Array(fr.readAsArrayBuffer(f.slice(offset, offset + length))) };
};

export const urlReader = ({ url, size }) => ({
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

// The disc map for Wasi from a Worker message: picked files or test URLs.
export const discOf = ({ files, urls }) =>
	new Map(files ? files.map((f) => [f.name, fileReader(f)]) : urls.map((u) => [u.name, urlReader(u)]));
