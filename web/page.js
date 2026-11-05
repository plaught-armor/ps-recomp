// The converter page: picks the disc files and the player's arch, runs the
// Worker, and offers the blob as a download.
//
// Test mode, for tests/wasi/serve.py: index.html?test=<disc url>[&arch=<arch>]
// converts the disc read from that URL, then posts the blob to `blob` and
// {sha256, size, ms, arch, userAgent, errors} to `result` on the same origin.
const $ = (id) => document.getElementById(id);
let files = [];
let worker = null;
let link = null;

// The arch of this machine, as the default for the select.
async function guessArch() {
	const ua = navigator.userAgentData;
	if (ua) {
		try {
			const h = await ua.getHighEntropyValues(["architecture"]);
			if (ua.platform === "Windows") return "x64_win";
			return h.architecture === "arm" ? "arm64" : "x64_sysv";
		} catch {
			// fall through to the UA string
		}
	}
	const s = navigator.userAgent;
	if (/Windows/.test(s)) return "x64_win";
	if (/aarch64|arm64|Macintosh/i.test(s)) return "arm64";
	return "x64_sysv";
}

// The file recomp is given: the .cue when there is one, else the only one.
function image(list) {
	return list.find((f) => /\.cue$/i.test(f.name)) ?? (list.length === 1 ? list[0] : null);
}

function pick(list) {
	files = [...list];
	const img = image(files);
	$("picked").textContent = img ? `Disc: ${img.name}` + (files.length > 1 ? ` (+${files.length - 1} files)` : "") :
		"Pick one image, or a .cue together with its track files.";
	$("convert").disabled = !img;
}

function log(text) {
	$("log").textContent += text;
	$("log").scrollTop = $("log").scrollHeight;
}

// Runs one conversion in the Worker: msg is {files} or {urls}, plus image
// and arch. Resolves to the Worker's done record; rejects on a trap.
function run(msg) {
	worker ??= new Worker("worker.js", { type: "module" });
	return new Promise((resolve, reject) => {
		worker.onmessage = ({ data }) => {
			if (data.log !== undefined) return log(data.log);
			if (data.error !== undefined) {
				// A trap leaves the instance unusable: start a fresh Worker next time.
				worker.terminate();
				worker = null;
				return reject(new Error(data.error));
			}
			resolve(data.done);
		};
		worker.postMessage(msg);
	});
}

async function convert() {
	$("convert").disabled = true;
	$("log").textContent = "";
	$("result").textContent = "Converting...";
	if (link) URL.revokeObjectURL(link);
	link = null;
	try {
		const { code, ms, out } = await run({ files, image: image(files).name, arch: $("arch").value });
		const blob = out.find((o) => o.name.endsWith(".bin"));
		if (code !== 0 || !blob) {
			$("result").textContent = `Failed (exit ${code}).`;
			return;
		}
		link = URL.createObjectURL(new Blob([new Uint8Array(blob.buffer, 0, blob.size)]));
		const a = document.createElement("a");
		a.href = link;
		a.download = blob.name;
		a.textContent = `Download ${blob.name}`;
		$("result").replaceChildren(a, ` (${blob.size} bytes, ${(ms / 1000).toFixed(1)} s)`);
	} catch (e) {
		$("result").textContent = "Failed.";
		log(e.message + "\n");
	} finally {
		$("convert").disabled = false;
	}
}

async function selfTest(url, arch) {
	const report = { userAgent: navigator.userAgent, arch, errors: [] };
	try {
		const head = await fetch(url, { method: "HEAD" });
		const size = Number(head.headers.get("Content-Length"));
		const name = decodeURIComponent(new URL(url, location.href).pathname.split("/").pop());
		$("picked").textContent = `Test: ${name}, ${size} bytes, ${arch}`;
		const done = await run({ urls: [{ name, url, size }], image: name, arch });
		Object.assign(report, { code: done.code, ms: done.ms, stats: done.stats });
		const blob = done.out.find((o) => o.name.endsWith(".bin"));
		if (done.code !== 0 || !blob) throw new Error(`exit ${done.code}, no blob`);
		const bytes = new Uint8Array(blob.buffer, 0, blob.size);
		report.name = blob.name;
		report.size = blob.size;
		// crypto.subtle needs a secure context (not plain http over a LAN);
		// the server hashes the posted blob either way.
		if (crypto.subtle) {
			const h = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
			report.sha256 = [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
		}
		await fetch("blob", { method: "POST", body: bytes });
	} catch (e) {
		report.errors.push(String(e?.message ?? e));
	}
	report.log = $("log").textContent;
	$("result").textContent = report.errors.length ? "Test failed." : "Test done.";
	await fetch("result", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(report) });
}

$("disc").addEventListener("change", (e) => pick(e.target.files));
$("drop").addEventListener("dragover", (e) => {
	e.preventDefault();
	$("drop").classList.add("over");
});
$("drop").addEventListener("dragleave", () => $("drop").classList.remove("over"));
$("drop").addEventListener("drop", (e) => {
	e.preventDefault();
	$("drop").classList.remove("over");
	pick(e.dataTransfer.files);
});
$("convert").addEventListener("click", convert);
fetch("commit.txt").then((r) => (r.ok ? r.text() : "?")).then((t) => ($("sha").textContent = t.trim()));
const params = new URLSearchParams(location.search);
guessArch().then((a) => {
	$("arch").value = params.get("arch") ?? a;
	if (params.has("test")) selfTest(params.get("test"), $("arch").value);
});
