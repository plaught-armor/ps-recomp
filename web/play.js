// The play page: picks the disc, makes the shared buffers (web/layout.js),
// runs play-worker.js, and on the main thread draws frames (web/present.js),
// plays the audio ring (web/audio.js) and feeds the keyboard and gamepads
// into the control buffer.
//
// The Worker never yields, so all of this goes through SharedArrayBuffers,
// which need cross-origin isolation. A server that sends COOP and COEP
// (tests/wasi/serve.py) gives it directly; elsewhere web/sw.js adds them
// and the page reloads once under it.
//
// Test mode, play.html?test=1[&wasm=<url>][&disc=<url>...][&env=<K=V>...]
// [&input=0][&store=url][&seconds=<n>]: runs that module (play.wasm by
// default) on the disc files read from those URLs, if any (the module's
// argument is the .cue among them, else the only one), with those
// environment variables. The files are copied into the browser's storage
// and read from there first, as a picked disc is, unless store=url.
// Only test mode has the fake standard gamepad, driven by window.testPad.
// Once the first frame is drawn the page presses A on it and the Z key for
// half a second each (not with input=0, which leaves emulation untouched),
// then, when the module exits or after <n> seconds (default 20), posts
// each file the module wrote, and ring.pcm (every sample it queued), to
// `file/<name>`, then window.testState() to `result`, both on the same
// origin (tests/wasi/serve.py --play).
//
// Netplay, &net=<room>&player=1|2 (tests/wasi/serve.py --net): the module
// plays that slot of a two-player session (PS_NET_PEER=<room>,
// PS_NET_PLAYER), and its datagrams go over a WebRTC data channel to the
// page with the other slot, found through the server's /signal in that
// room. Host candidates only, no STUN, and /signal answers loopback only:
// both pages on one machine.
// In test mode the files go to `file/p<N>/<name>` and the state to
// `result?player=<N>`.
import { SCANCODE_OF_CODE } from "./keys.js";
import { AUDIO, CONTROL, EV, NET, PAD, PRESENT } from "./layout.js";
import { serveLink } from "./net.js";
import { Present } from "./present.js";
import { forget, storedNames } from "./readers.js";

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const test = params.get("test") === "1";
const errors = [];
const violation = (e) => errors.push(`csp: ${e.effectiveDirective} blocked ${e.blockedURI || "inline"}`);
document.addEventListener("securitypolicyviolation", violation);

// The worker posts its output a line at a time, thousands of lines while a
// game boots. Each line is appended as its own text node, and the log
// scrolls at most once a frame (tick): scrolling reads the log's height,
// which lays out the whole log, so doing it per line made the page's thread
// fall seconds behind and starved netplay's data channel.
let logMoved = false;
function log(text) {
	$("log").append(text);
	logMoved = true;
}

function scrollLog() {
	if (!logMoved) return;
	logMoved = false;
	$("log").scrollTop = $("log").scrollHeight;
}

// Cross-origin isolation, through web/sw.js when the server does not send
// the headers. Resolves to whether the page is isolated and has
// SharedArrayBuffer.
async function isolate() {
	if (crossOriginIsolated) {
		if (typeof SharedArrayBuffer === "function") return true;
		// A reload cannot help: the browser withholds it even when isolated.
		return refuse("The page is cross-origin isolated, but this browser does not provide SharedArrayBuffer");
	}
	const KEY = "ps-recomp-sw-reload";
	if (navigator.serviceWorker && !sessionStorage.getItem(KEY)) {
		try {
			await navigator.serviceWorker.register("sw.js");
			await navigator.serviceWorker.ready;
			sessionStorage.setItem(KEY, "1");
			location.reload();
			return new Promise(() => {}); // the reload takes over
		} catch (e) {
			errors.push(`service worker: ${e.message}`);
		}
	}
	sessionStorage.removeItem(KEY);
	return refuse(window.isSecureContext ? "The page could not be cross-origin isolated" :
		"The page is not in a secure context (use https or localhost), so it cannot be cross-origin isolated");
}

// Shows why the player cannot run. Returns false, for isolate().
function refuse(why) {
	$("isolation").textContent = `${why}. The player needs SharedArrayBuffer, which only an isolated page has.`;
	$("isolation").hidden = false;
	return false;
}

// The shared buffers, made once the page is isolated (SharedArrayBuffer
// does not exist before).
let shared = null;
let ctl = null;
let ctlView = null;

function makeShared() {
	shared = {
		control: new SharedArrayBuffer(CONTROL.SIZE),
		audio: new SharedArrayBuffer(AUDIO.SIZE),
		present: new SharedArrayBuffer(PRESENT.SIZE),
	};
	ctl = new Int32Array(shared.control);
	ctlView = new DataView(shared.control);
	const P = new Int32Array(shared.present, 0, PRESENT.SLOTS / 4);
	Atomics.store(P, PRESENT.LATEST_WORD, -1);
	Atomics.store(P, PRESENT.READING_WORD, -1);
}

// ---- netplay ----

const netRoom = params.get("net");
const netPlayer = params.get("player") ?? "1";
let netLink = null;

// The signal server's queue for this page: post sends a message to the
// other page, next waits for one from it.
function signalBox() {
	const url = `signal?room=${encodeURIComponent(netRoom)}&peer=${netPlayer}`;
	return {
		async post(m) {
			const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(m) });
			if (!r.ok) throw new Error(`net: signal: ${r.status}`);
		},
		async next() {
			for (;;) {
				const r = await fetch(url);
				if (r.status === 200) return r.json();
				if (r.status !== 204) throw new Error(`net: signal: ${r.status}`);
			}
		},
	};
}

// connect for serveLink (web/net.js): a data channel to the other page,
// unordered and never resent, as UDP. Player 1 offers, player 2 answers;
// each sends its description once ICE gathering is done, so the candidates
// go with it.
async function connectPeer(_bind, _peer, deliver) {
	const box = signalBox();
	const pc = new RTCPeerConnection({ iceServers: [] });
	const gathered = () =>
		new Promise((resolve) => {
			const check = () => pc.iceGatheringState === "complete" && resolve();
			pc.addEventListener("icegatheringstatechange", check);
			check();
		});
	let channel;
	const wire = (c) => {
		channel = c;
		c.binaryType = "arraybuffer";
		c.onmessage = (e) => deliver(new Uint8Array(e.data));
	};
	if (netPlayer === "1") {
		wire(pc.createDataChannel("net", { ordered: false, maxRetransmits: 0 }));
		await pc.setLocalDescription(await pc.createOffer());
		await gathered();
		await box.post({ sdp: pc.localDescription });
		await pc.setRemoteDescription((await box.next()).sdp);
	} else {
		const offered = new Promise((resolve) => pc.addEventListener("datachannel", (e) => resolve(e.channel), { once: true }));
		await pc.setRemoteDescription((await box.next()).sdp);
		await pc.setLocalDescription(await pc.createAnswer());
		await gathered();
		await box.post({ sdp: pc.localDescription });
		wire(await offered);
	}
	if (channel.readyState !== "open") {
		await new Promise((resolve, reject) => {
			channel.onopen = resolve;
			channel.onclose = () => reject(new Error("net: the data channel closed before it opened"));
		});
	}
	channel.onclose = () => log("net: the data channel closed\n");
	return {
		// A datagram the channel cannot take now is dropped, as a socket's
		// would be; the protocol resends.
		send(d) {
			if (channel.readyState === "open" && channel.bufferedAmount < 1 << 16) channel.send(d);
		},
		close() {
			pc.close();
		},
	};
}

// The NET buffer for the Worker, and the link that serves it; env gets
// the module's netplay settings. Throws when the page cannot play.
function startNet(env) {
	if (!crossOriginIsolated) throw new Error("net: the page is not cross-origin isolated, so netplay cannot run");
	if (!/^[\w-]{1,64}$/.test(netRoom)) throw new Error(`net: not a room name: ${netRoom}`);
	if (netPlayer !== "1" && netPlayer !== "2") throw new Error(`net: player ${netPlayer} is not 1 or 2`);
	const buffer = new SharedArrayBuffer(NET.SIZE);
	netLink = serveLink(buffer, connectPeer);
	netLink.done.catch((e) => {
		errors.push(String(e?.message ?? e));
		log(`${e?.message ?? e}\n`);
	});
	env.PS_NET_PEER = netRoom;
	env.PS_NET_PLAYER = netPlayer;
	return buffer;
}

// ---- the disc ----

let files = [];

// The file play is given: the .cue when there is one, else the only one.
function image(list) {
	return list.find((f) => /\.cue$/i.test(f.name)) ?? (list.length === 1 ? list[0] : null);
}

function pick(list) {
	files = [...list];
	const img = image(files);
	$("picked").textContent = img ? `Disc: ${img.name}` + (files.length > 1 ? ` (+${files.length - 1} files)` : "") :
		"Pick one image, or a .cue together with its track files.";
	$("start").disabled = !img || worker !== null;
}

// ---- stored discs ----

const canStore = typeof navigator.storage?.getDirectory === "function";
let storeInfo = null; // how the running disc is read: the Worker's {store}

// Lists the stored discs, each with Play and Forget, while nothing runs.
async function showStored() {
	if (!canStore) return;
	const list = $("stored");
	let names;
	try {
		names = await storedNames();
	} catch (e) {
		errors.push(`stored discs: ${e.message}`);
		return;
	}
	list.replaceChildren(...names.map((name) => {
		const li = document.createElement("li");
		const play = document.createElement("button");
		play.type = "button";
		play.textContent = `Play ${name} (stored)`;
		play.disabled = worker !== null;
		play.addEventListener("click", () => playStored(name));
		const drop = document.createElement("button");
		drop.type = "button";
		drop.textContent = "Forget";
		drop.disabled = worker !== null;
		drop.addEventListener("click", () => forget(name).catch((e) => log(`Forget ${name}: ${e.message}\n`)).then(showStored));
		li.append(play, " ", drop);
		return li;
	}));
	list.hidden = names.length === 0;
}

// The build's commit (commit.txt), null for a dev build (-dirty) or none:
// play keys stored native code by it and stores none for a dev build.
let commit = null;

// Plays a stored disc. First a Worker runs `play --convert-store`, which
// converts the disc's code to native code and stores it in /data unless
// this build's is there already; then the game starts and takes it.
// While it converts the page shows the time so far and Skip, which stops
// the conversion and plays the disc interpreted now; it is tried again on
// the next Play. A failed conversion stores nothing (failSaves: false)
// and the game starts interpreted. Once the Worker says {saving} it is
// writing /data, so Skip goes away and the page waits for it.
function playStored(name) {
	const play = () => start({ wasm: "play.wasm", args: [`/disc/${name}`], stored: name });
	if (commit === null) return play();
	$("start").disabled = true;
	for (const b of $("stored").querySelectorAll("button")) b.disabled = true;
	const box = $("convert");
	const skip = $("skip");
	const t0 = performance.now();
	let last = "";
	const show = () => ($("convert-text").textContent =
		`Converting ${name} to native code (${Math.round((performance.now() - t0) / 1000)} s)${last ? `: ${last}` : ""}`);
	const timer = setInterval(show, 1000);
	const conv = new Worker("play-worker.js", { type: "module" });
	let over = false;
	const finish = (note) => {
		if (over) return;
		over = true;
		clearInterval(timer);
		conv.terminate();
		box.hidden = true;
		skip.onclick = null;
		play(); // clears the log, so the note goes after
		if (note) log(note);
	};
	conv.onmessage = ({ data }) => {
		if (data.log !== undefined) {
			const line = data.log.trim().split("\n").pop();
			if (line) last = line;
			show();
		} else if (data.saving !== undefined) {
			skip.hidden = true;
		} else if (data.done !== undefined) {
			finish(data.done.code === 0 ? "" : `The native code was not made (${last || `exit ${data.done.code}`}); this run is interpreted.\n`);
		} else if (data.error !== undefined) {
			finish(`The native code was not made (${data.error.split("\n")[0]}); this run is interpreted.\n`);
		}
	};
	conv.onerror = (e) => finish(`The native code was not made (${e.message || "worker failed to load"}); this run is interpreted.\n`);
	skip.hidden = false;
	skip.onclick = () => finish("Conversion skipped; this run is interpreted.\n");
	show();
	box.hidden = false;
	conv.postMessage({ wasm: "play.wasm", args: ["--convert-store", `/disc/${name}`], stored: name, failSaves: false, ...shared });
}

// The Worker's word on the disc: stored, or why not.
function onStore(info) {
	storeInfo = info;
	if (info.error) log(`The disc is not stored (${info.error}); it is read as ${info.kind === "file" ? "picked" : "served"} instead.\n`);
	showStored();
}

// ---- the keyboard ----

// Pushes an event into the control ring; drops it when the ring is full.
function pushEvent(type, a = 0, b = 0, c = 0) {
	const w = Atomics.load(ctl, CONTROL.RING_WRITE_WORD);
	const r = Atomics.load(ctl, CONTROL.RING_READ_WORD);
	if (((w - r) | 0) >= CONTROL.RING_LEN) return;
	const at = CONTROL.RING + (w & (CONTROL.RING_LEN - 1)) * CONTROL.EVENT_SIZE;
	ctlView.setInt32(at, type, true);
	ctlView.setInt32(at + 4, a, true);
	ctlView.setInt32(at + 8, b, true);
	ctlView.setInt32(at + 12, c, true);
	Atomics.store(ctl, CONTROL.RING_WRITE_WORD, (w + 1) | 0);
}

function onKey(e) {
	const scancode = SCANCODE_OF_CODE.get(e.code);
	if (scancode === undefined) return;
	e.preventDefault();
	pushEvent(e.type === "keydown" ? EV.KEYDOWN : EV.KEYUP, scancode, e.repeat ? 1 : 0);
}

function wireKeyboard(canvas) {
	canvas.addEventListener("keydown", onKey);
	canvas.addEventListener("keyup", onKey);
	canvas.addEventListener("focus", () => Atomics.store(ctl, CONTROL.FOCUS_WORD, 1));
	canvas.addEventListener("blur", () => Atomics.store(ctl, CONTROL.FOCUS_WORD, 0));
	canvas.addEventListener("pointerdown", () => canvas.focus());
}

// ---- gamepads ----

// SDL_GameControllerButton of each standard-mapping button index.
// Standard: 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 LT, 7 RT, 8 back, 9 start,
// 10 LS, 11 RS, 12-15 up down left right, 16 guide. LT and RT are axes.
const SDL_BUTTON_OF_STANDARD = [0, 1, 2, 3, 9, 10, -1, -1, 4, 6, 7, 8, 11, 12, 13, 14, 5];
// SDL_GameControllerType: XBOXONE 2, PS4 4, NINTENDO_SWITCH_PRO 5, PS5 7.
const PS5_PRODUCTS = new Set(["0ce6", "0df2"]);

function padType(id) {
	// Chromium: "... (STANDARD GAMEPAD Vendor: 054c Product: 09cc)";
	// Firefox: "054c-09cc-...".
	const m = /Vendor: ([0-9a-f]{4}) Product: ([0-9a-f]{4})/i.exec(id) ?? /^([0-9a-f]{1,4})-([0-9a-f]{1,4})-/i.exec(id);
	if (!m) return 0;
	const vendor = m[1].padStart(4, "0").toLowerCase(), product = m[2].padStart(4, "0").toLowerCase();
	if (vendor === "045e") return 2;
	if (vendor === "054c") return PS5_PRODUCTS.has(product) ? 7 : 4;
	if (vendor === "057e") return 5;
	return 0;
}

const encoder = new TextEncoder();
let nextInstance = 0;
// Per slot: the browser pad's index there (or null), and the last rumble
// request seen.
const slots = Array.from({ length: CONTROL.PADS_MAX }, () => ({ index: null, rumbleSeq: 0 }));

const padAt = (i) => CONTROL.PADS + i * CONTROL.PAD_SIZE;
const axis = (v) => Math.max(-32768, Math.min(32767, Math.round(v * 32767)));

function connect(i, pad) {
	const at = padAt(i);
	new Uint8Array(shared.control, at, CONTROL.PAD_SIZE).fill(0);
	ctlView.setInt32(at + PAD.INSTANCE, nextInstance++, true);
	ctlView.setInt32(at + PAD.TYPE, padType(pad.id), true);
	ctlView.setInt32(at + PAD.RUMBLE_OK, pad.vibrationActuator ? 1 : 0, true);
	const name = encoder.encode(pad.id.replace(/\s*\(.*\)\s*$/, "") || "Gamepad").slice(0, PAD.NAME_MAX);
	new Uint8Array(shared.control, at + PAD.NAME, name.length).set(name);
	slots[i].index = pad.index;
	slots[i].rumbleSeq = 0;
	write(i, pad);
	Atomics.store(ctl, (at + PAD.CONNECTED) / 4, 1);
}

function disconnect(i) {
	Atomics.store(ctl, (padAt(i) + PAD.CONNECTED) / 4, 0);
	slots[i].index = null;
}

// The pad's buttons and axes into slot i, and its rumble requests out.
function write(i, pad) {
	const at = padAt(i);
	let buttons = 0;
	pad.buttons.forEach((b, s) => {
		const sdl = SDL_BUTTON_OF_STANDARD[s] ?? -1;
		if (sdl >= 0 && b.pressed) buttons |= 1 << sdl;
	});
	ctlView.setUint32(at + PAD.BUTTONS, buttons >>> 0, true);
	const a = pad.axes;
	const values = [a[0] ?? 0, a[1] ?? 0, a[2] ?? 0, a[3] ?? 0, pad.buttons[6]?.value ?? 0, pad.buttons[7]?.value ?? 0];
	values.forEach((v, k) => ctlView.setInt16(at + PAD.AXES + k * 2, axis(v), true));
	const seq = Atomics.load(ctl, (at + PAD.RUMBLE_SEQ) / 4);
	if (seq !== slots[i].rumbleSeq) {
		slots[i].rumbleSeq = seq;
		pad.vibrationActuator?.playEffect("dual-rumble", {
			duration: ctlView.getInt32(at + PAD.RUMBLE_MS, true),
			strongMagnitude: ctlView.getInt32(at + PAD.RUMBLE_LO, true) / 0xffff,
			weakMagnitude: ctlView.getInt32(at + PAD.RUMBLE_HI, true) / 0xffff,
		}).catch(() => {});
	}
}

// Test mode's fake standard gamepad: the gate sets window.testPad.buttons
// (17 booleans) and .axes (4 numbers in -1..1).
function fakePad() {
	const t = window.testPad;
	if (!t) return null;
	return {
		id: "Test pad (STANDARD GAMEPAD Vendor: 045e Product: 0000)",
		index: -1,
		mapping: "standard",
		connected: true,
		buttons: Array.from({ length: 17 }, (_, k) => ({ pressed: !!t.buttons?.[k], value: t.buttons?.[k] ? 1 : 0 })),
		axes: Array.from({ length: 4 }, (_, k) => t.axes?.[k] ?? 0),
		vibrationActuator: null,
	};
}

function pollPads() {
	const pads = [...(navigator.getGamepads?.() ?? [])].filter((p) => p && p.connected && p.mapping === "standard");
	if (test) {
		const fake = fakePad();
		if (fake) pads.unshift(fake);
	}
	const byIndex = new Map(pads.map((p) => [p.index, p]));
	slots.forEach((s, i) => {
		if (s.index !== null && !byIndex.has(s.index)) disconnect(i);
	});
	for (const pad of pads) {
		const i = slots.findIndex((s) => s.index === pad.index);
		if (i >= 0) {
			write(i, pad);
			continue;
		}
		const free = slots.findIndex((s) => s.index === null);
		if (free >= 0) connect(free, pad);
	}
}

// ---- audio ----

let audioContext = null;
const audioStats = { frames: 0, rms: 0, reports: 0 };

async function startAudio(rate) {
	try {
		audioContext?.close();
		audioContext = new AudioContext({ sampleRate: rate, latencyHint: "interactive" });
		await audioContext.audioWorklet.addModule("audio.js");
		const node = new AudioWorkletNode(audioContext, "ring", {
			numberOfInputs: 0,
			outputChannelCount: [2],
			processorOptions: { audio: shared.audio, report: test },
		});
		node.port.onmessage = ({ data }) => {
			audioStats.frames += data.frames;
			audioStats.rms = Math.max(audioStats.rms, data.rms);
			audioStats.reports++;
		};
		node.connect(audioContext.destination);
		await audioContext.resume();
	} catch (e) {
		errors.push(`audio: ${e.message}`);
		log(`audio: ${e.message}\n`);
	}
}

// ---- running ----

let worker = null;
let present = null;
let done = null;
let startedAt = 0; // performance.now() at start()
let firstPresentMs = null; // from start() to the first frame seen
let written = []; // test mode: [name, bytes] of the module's files

function onMessage({ data }) {
	if (data.log !== undefined) return log(data.log);
	if (data.csp !== undefined) return errors.push(data.csp);
	if (data.title !== undefined) {
		document.title = data.title || "ps-recomp player";
		return;
	}
	if (data.audio !== undefined) return startAudio(data.audio);
	if (data.store !== undefined) return onStore(data.store);
	if (data.fullscreen !== undefined) {
		if (data.fullscreen && !document.fullscreenElement) $("screen").requestFullscreen?.().catch(() => {});
		else if (!data.fullscreen && document.fullscreenElement) document.exitFullscreen().catch(() => {});
		return;
	}
	if (data.error !== undefined) {
		errors.push(data.error);
		log(`\n${data.error}\n`);
		done = { code: -1, ...data.times };
		written = data.files ?? [];
	} else if (data.done !== undefined) {
		done = data.done;
		written = data.files ?? [];
		log(`\nExited with code ${done.code}.\n`);
	} else {
		return;
	}
	log("Reload the page to play again.\n");
	audioContext?.close();
	audioContext = null;
}

function tick() {
	if (worker && firstPresentMs === null && Atomics.load(new Int32Array(shared.present, 0, 4), PRESENT.FRAMES_WORD) > 0)
		firstPresentMs = Math.round(performance.now() - startedAt);
	if (present) {
		try {
			present.frame();
		} catch (e) {
			errors.push(`present: ${e.message}`);
			present = null;
		}
	}
	pollPads();
	scrollLog();
	requestAnimationFrame(tick);
}

// msg: {wasm, args} plus {files} or {urls}, and in test mode {env, test}.
function start(msg) {
	if (netRoom !== null) {
		msg = { ...msg, env: { ...msg.env } };
		msg.net = startNet(msg.env);
	}
	$("start").disabled = true;
	$("log").textContent = "";
	const canvas = $("screen");
	present = new Present(canvas, shared.present);
	canvas.focus();
	worker = new Worker("play-worker.js", { type: "module" });
	worker.onmessage = onMessage;
	worker.onerror = (e) => onMessage({ data: { error: e.message || "worker failed to load" } });
	startedAt = performance.now();
	worker.postMessage({ ...msg, ...shared });
	for (const b of $("stored").querySelectorAll("button")) b.disabled = true;
}

// The gate's view of the run.
async function testState() {
	const shot = present?.capture();
	let checksum = null;
	if (shot && crypto.subtle) {
		const h = new Uint8Array(await crypto.subtle.digest("SHA-256", shot.pixels));
		checksum = [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
	}
	return {
		isolated: crossOriginIsolated,
		controlled: !!navigator.serviceWorker?.controller,
		frames: Atomics.load(new Int32Array(shared.present, 0, 4), PRESENT.FRAMES_WORD),
		capture: shot && { w: shot.w, h: shot.h, frame: shot.frame, sha256: checksum },
		audio: { ...audioStats, state: audioContext?.state ?? null },
		sabUpload: present?.sabUpload ?? null,
		done,
		store: storeInfo,
		firstPresentMs,
		files: written.map(([name, bytes]) => ({ name, size: bytes.length })),
		net: netLink && { player: netPlayer, ...netLink.stats },
		log: $("log").textContent,
		errors: [...errors],
		userAgent: navigator.userAgent,
	};
}

async function main() {
	fetch("commit.txt").then((r) => (r.ok ? r.text() : "?")).then((t) => {
		$("sha").textContent = t.trim();
		commit = /^[0-9a-f]{40}$/.test(t.trim()) ? t.trim() : null;
	});
	if (!(await isolate())) {
		if (test) await postReport({ isolated: crossOriginIsolated, errors, userAgent: navigator.userAgent });
		return;
	}
	makeShared();
	wireKeyboard($("screen"));
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
	$("start").addEventListener("click", () => {
		const img = image(files);
		// Asked on the click: some browsers grant it only on a user gesture.
		if (canStore) navigator.storage.persist?.().catch(() => {});
		start({ wasm: "play.wasm", args: [`/disc/${img.name}`], files, store: canStore ? img.name : undefined });
	});
	requestAnimationFrame(tick);
	showStored();
	if (!test) return;
	window.testState = testState;
	const wasm = params.get("wasm") ?? "play.wasm";
	const urls = [];
	for (const disc of params.getAll("disc")) {
		const head = await fetch(disc, { method: "HEAD" });
		const name = decodeURIComponent(new URL(disc, location.href).pathname.split("/").pop());
		urls.push({ name, url: disc, size: Number(head.headers.get("Content-Length")) });
	}
	const img = image(urls);
	if (urls.length && !img) throw new Error("test: several discs and no .cue among them");
	const env = {};
	for (const kv of params.getAll("env")) {
		const eq = kv.indexOf("=");
		if (eq <= 0) throw new Error(`test: env=${kv} is not K=V`);
		env[kv.slice(0, eq)] = kv.slice(eq + 1);
	}
	$("picked").textContent = `Test: ${wasm}` + (img ? ` on ${img.name}` : "");
	const store = img && canStore && params.get("store") !== "url" ? img.name : undefined;
	start({ wasm, args: img ? [`/disc/${img.name}`] : [], urls, store, env, test: true });
	await selfTest(Number(params.get("seconds") ?? 20) * 1000, params.get("input") !== "0");
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Test mode's input (when `input`) and report, after start().
async function selfTest(limit, input) {
	const t0 = performance.now();
	const frames = new Int32Array(shared.present, 0, 4);
	const over = () => done !== null || performance.now() - t0 > limit;
	while (!over() && Atomics.load(frames, PRESENT.FRAMES_WORD) === 0) await sleep(50);
	if (input && !over()) {
		window.testPad ??= { buttons: [], axes: [] };
		await sleep(500); // the pad's add first
		window.testPad.buttons[0] = true;
		await sleep(500);
		window.testPad.buttons[0] = false;
		const canvas = $("screen");
		const key = (type) => canvas.dispatchEvent(new KeyboardEvent(type, { code: "KeyZ", bubbles: true }));
		key("keydown");
		await sleep(500);
		key("keyup");
	}
	while (!over()) await sleep(100);
	await sleep(1000); // the last log lines
	const report = await testState();
	const dir = netRoom !== null ? `p${netPlayer}/` : "";
	for (const [name, bytes] of written) {
		const r = await fetch(`file/${dir}${encodeURIComponent(name)}`, { method: "POST", body: bytes }).catch((e) => e);
		if (!r.ok) report.errors.push(`file/${dir}${name}: ${r.status ?? r.message}`);
	}
	await postReport(report);
}

// Test mode's report, to tests/wasi/serve.py.
async function postReport(report) {
	await fetch(netRoom !== null ? `result?player=${encodeURIComponent(netPlayer)}` : "result", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(report) })
		.catch(() => {});
}

main().catch((e) => {
	errors.push(String(e?.stack ?? e));
	log(`${e.message}\n`);
	if (test) postReport({ isolated: crossOriginIsolated, errors, userAgent: navigator.userAgent });
});
