// SDL 2 for play.wasm in a Worker: the "system:SDL2" imports vendor:sdl2
// makes on wasi_wasm32, over the page's SharedArrayBuffers (web/layout.js).
// The Worker never yields to its event loop, so everything it gets from the
// page comes through those buffers: input from the control buffer, sound
// out through the audio ring, frames out through the present slots, which
// main replays in WebGL2 (web/present.js).
//
// Only what the tree calls is here; the rest of SDL is not imported. The
// renderer records each frame's commands and the textures they use; the
// window is a canvas at the logical size. Strings and the keyboard state
// SDL returns live in one wasm page grown before the run: Odin's allocator
// takes the page count memory.grow returns, so it never hands that page
// out. SDL_free does nothing.
import { AUDIO, BLEND, CMD, CONTROL, EV, KIND, PAD, PRESENT } from "./layout.js";
import { NAME_OF_SCANCODE, SCANCODE_OF_NAME, keycode } from "./keys.js";

// SDL_EventType values.
const T = {
	QUIT: 0x100, WINDOWEVENT: 0x200, KEYDOWN: 0x300, KEYUP: 0x301,
	AXIS: 0x650, BUTTONDOWN: 0x651, BUTTONUP: 0x652, ADDED: 0x653, REMOVED: 0x654,
};
const WINDOW_FOCUS_GAINED = 12;
const WINDOW_FOCUS_LOST = 13;
const EVENT_SIZE = 56; // sizeof(SDL_Event)
const NUM_SCANCODES = 512;
const WINDOW_SHOWN = 0x4;
const WINDOW_INPUT_FOCUS = 0x200;
const AUDIO_S16LSB = 0x8010;
const AUDIO_DEVICE = 2;
const WINDOW = 1;
const RENDERER = 2;
const PAD_HANDLE = 0x100; // a controller handle is this plus its instance id
const PAD_AXES = 6;

// SDL_PixelFormatEnum values the tree creates textures in.
const KIND_OF_FORMAT = new Map([
	[0x16161804, KIND.BGRX], // XRGB8888 (= RGB888)
	[0x16362004, KIND.BGRA], // ARGB8888
	[0x16762004, KIND.RGBA], // ABGR8888
]);

// SDL_GameControllerButton by its mapping-string name.
const BUTTON_OF_NAME = new Map([
	"a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
	"leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright",
	"misc1", "paddle1", "paddle2", "paddle3", "paddle4", "touchpad",
].map((n, i) => [n, i]));

// SDL_Keymod bits of the modifier scancodes.
const MOD_OF_SCANCODE = new Map([
	[224, 0x40], [225, 0x1], [226, 0x100], [227, 0x400],
	[228, 0x80], [229, 0x2], [230, 0x200], [231, 0x800],
]);

const utf8 = new TextEncoder();
const text = new TextDecoder();

export class Sdl {
	// control, audio, present: the page's SharedArrayBuffers. post(message)
	// sends to the page: {log}, {title}, {audio: rate}, {fullscreen}.
	constructor({ control, audio, present, post }) {
		this.ctl = new Int32Array(control);
		this.ctlView = new DataView(control);
		this.ctlBytes = new Uint8Array(control);
		this.audioWords = new Int32Array(audio, 0, AUDIO.RING / 4);
		this.ring = new Int16Array(audio, AUDIO.RING, AUDIO.RING_FRAMES * 2);
		this.presentBuf = present;
		this.presentWords = new Int32Array(present, 0, PRESENT.SLOTS / 4);
		this.post = post;
		this.memory = null;
		this.page = 0; // the SDL page: keyboard state, then strings
		this.top = 0;
		this.strings = new Map(); // text -> its C string in the SDL page
		this.error = "";
		this.start = performance.now();
		this.queue = []; // events: functions writing one into an SDL_Event
		this.focus = 0;
		this.pads = Array.from({ length: CONTROL.PADS_MAX }, () => ({
			connected: false, instance: -1, open: false, buttons: 0, axes: new Int16Array(PAD_AXES),
		}));
		this.window = { w: 0, h: 0 };
		this.logical = null; // {w, h} or null
		this.integer = 0;
		this.color = [0, 0, 0, 255];
		this.drawBlend = BLEND.NONE;
		this.textures = new Map(); // handle -> {kind, w, h, pixels, version, scale, blend, alpha}
		this.nextTexture = 0x1000;
		this.cmds = [];
		this.frame = 0;
		this.warned = new Set();
		this.audioRate = 0;
		this.imports = this.makeImports();
	}

	// Call after instantiating, before the run: grows the SDL page.
	attach(instance) {
		this.memory = instance.exports.memory;
		this.page = this.memory.grow(1) * 65536;
		this.top = this.page + NUM_SCANCODES;
	}

	u8() {
		return new Uint8Array(this.memory.buffer);
	}

	dv() {
		if (!this.view || this.view.buffer !== this.memory.buffer) this.view = new DataView(this.memory.buffer);
		return this.view;
	}

	cstring(ptr) {
		const m = this.u8();
		let end = ptr;
		while (m[end] !== 0) end++;
		return text.decode(m.subarray(ptr, end));
	}

	// The C string for s, in the SDL page; the same pointer each time.
	cstr(s) {
		let p = this.strings.get(s);
		if (p !== undefined) return p;
		const b = utf8.encode(s);
		if (this.top + b.length + 1 > this.page + 65536) throw new Error("sdl.js: the SDL page is full of strings");
		p = this.top;
		this.u8().set(b, p);
		this.u8()[p + b.length] = 0;
		this.top += b.length + 1;
		this.strings.set(s, p);
		return p;
	}

	fail(message, result = -1) {
		this.error = message;
		return result;
	}

	warnOnce(message) {
		if (this.warned.has(message)) return;
		this.warned.add(message);
		this.post({ log: `sdl.js: ${message}\n` });
	}

	ticks() {
		return Math.floor(performance.now() - this.start) >>> 0;
	}

	// Queues an event; fill(dv, ptr) writes the fields after the timestamp.
	push(type, fill = () => {}) {
		this.queue.push((dv, p) => {
			dv.setUint32(p, type, true);
			dv.setUint32(p + 4, this.ticks(), true);
			fill(dv, p);
		});
	}

	// SDL_PumpEvents: takes what the page sent since the last pump.
	pump() {
		const focus = Atomics.load(this.ctl, CONTROL.FOCUS_WORD);
		if (focus !== this.focus) {
			this.focus = focus;
			this.push(T.WINDOWEVENT, (dv, p) => {
				dv.setUint32(p + 8, WINDOW, true);
				dv.setUint8(p + 12, focus ? WINDOW_FOCUS_GAINED : WINDOW_FOCUS_LOST);
			});
		}
		const w = Atomics.load(this.ctl, CONTROL.RING_WRITE_WORD);
		let r = Atomics.load(this.ctl, CONTROL.RING_READ_WORD);
		for (; r !== w; r = (r + 1) | 0) {
			const at = CONTROL.RING + (r & (CONTROL.RING_LEN - 1)) * CONTROL.EVENT_SIZE;
			const type = this.ctlView.getInt32(at, true);
			const a = this.ctlView.getInt32(at + 4, true), b = this.ctlView.getInt32(at + 8, true);
			if (type === EV.KEYDOWN || type === EV.KEYUP) this.key(type === EV.KEYDOWN, a, b);
			else if (type === EV.QUIT) this.push(T.QUIT);
		}
		Atomics.store(this.ctl, CONTROL.RING_READ_WORD, r);
		for (let i = 0; i < CONTROL.PADS_MAX; i++) this.padPump(i);
	}

	key(down, scancode, repeat) {
		if (scancode <= 0 || scancode >= NUM_SCANCODES) return;
		this.u8()[this.page + scancode] = down ? 1 : 0;
		let mod = 0;
		const m = this.u8();
		for (const [s, bit] of MOD_OF_SCANCODE) if (m[this.page + s]) mod |= bit;
		this.push(down ? T.KEYDOWN : T.KEYUP, (dv, p) => {
			dv.setUint32(p + 8, WINDOW, true);
			dv.setUint8(p + 12, down ? 1 : 0);
			dv.setUint8(p + 13, repeat ? 1 : 0);
			dv.setInt32(p + 16, scancode, true);
			dv.setInt32(p + 20, keycode(scancode), true);
			dv.setUint16(p + 24, mod, true);
		});
	}

	slot(i) {
		return CONTROL.PADS + i * CONTROL.PAD_SIZE;
	}

	// Hotplug, then button and axis changes, of pad slot i.
	padPump(i) {
		const pad = this.pads[i], at = this.slot(i);
		const connected = Atomics.load(this.ctl, (at + PAD.CONNECTED) / 4) === 1;
		const instance = this.ctlView.getInt32(at + PAD.INSTANCE, true);
		if (pad.connected && (!connected || instance !== pad.instance)) {
			const which = pad.instance;
			this.push(T.REMOVED, (dv, p) => dv.setInt32(p + 8, which, true));
			Object.assign(pad, { connected: false, instance: -1, open: false, buttons: 0 });
			pad.axes.fill(0);
		}
		if (!connected) return;
		if (!pad.connected) {
			Object.assign(pad, { connected: true, instance });
			this.push(T.ADDED, (dv, p) => dv.setInt32(p + 8, i, true)); // the device index
		}
		const buttons = this.ctlView.getUint32(at + PAD.BUTTONS, true);
		for (let b = 0, changed = buttons ^ pad.buttons; changed !== 0; b++, changed >>>= 1) {
			if (!(changed & 1)) continue;
			const down = (buttons >>> b) & 1;
			this.push(down ? T.BUTTONDOWN : T.BUTTONUP, (dv, p) => {
				dv.setInt32(p + 8, instance, true);
				dv.setUint8(p + 12, b);
				dv.setUint8(p + 13, down);
			});
		}
		pad.buttons = buttons;
		for (let a = 0; a < PAD_AXES; a++) {
			const v = this.ctlView.getInt16(at + PAD.AXES + a * 2, true);
			if (v === pad.axes[a]) continue;
			pad.axes[a] = v;
			this.push(T.AXIS, (dv, p) => {
				dv.setInt32(p + 8, instance, true);
				dv.setUint8(p + 12, a);
				dv.setInt16(p + 16, v, true);
			});
		}
	}

	// The open pad a controller handle names, or null.
	pad(handle) {
		const id = handle - PAD_HANDLE;
		const i = this.pads.findIndex((p) => p.connected && p.open && p.instance === id);
		return i < 0 ? null : { pad: this.pads[i], at: this.slot(i) };
	}

	output() {
		return this.logical ?? this.window;
	}

	rect(ptr, whole) {
		if (ptr === 0) return whole;
		const dv = this.dv();
		return [0, 4, 8, 12].map((o) => dv.getInt32(ptr + o, true));
	}

	// Writes the frame into a free present slot and publishes it.
	present() {
		const P = this.presentWords;
		const latest = Atomics.load(P, PRESENT.LATEST_WORD), reading = Atomics.load(P, PRESENT.READING_WORD);
		let s = 0;
		while (s === latest || s === reading) s++;
		const base = PRESENT.SLOTS + s * PRESENT.SLOT_SIZE;
		const words = new Int32Array(this.presentBuf, base, PRESENT.TEXTURES / 4);
		const bytes = new Uint8Array(this.presentBuf, base, PRESENT.SLOT_SIZE);
		const out = this.output();
		let cmds = this.cmds;
		if (cmds.length > PRESENT.CMDS_MAX) {
			this.warnOnce(`more than ${PRESENT.CMDS_MAX} draw commands in a frame; the rest are dropped`);
			cmds = cmds.slice(0, PRESENT.CMDS_MAX);
		}
		const used = new Set();
		cmds.forEach((c, i) => {
			words.fill(0, (PRESENT.CMDS / 4) + i * PRESENT.CMD_WORDS, (PRESENT.CMDS / 4) + (i + 1) * PRESENT.CMD_WORDS);
			words.set(c, (PRESENT.CMDS / 4) + i * PRESENT.CMD_WORDS);
			if (c[0] === CMD.COPY) used.add(c[1]);
		});
		let at = PRESENT.TEXTURES, ntex = 0;
		for (const id of used) {
			const t = this.textures.get(id);
			if (!t) continue;
			if (at + PRESENT.TEX_HEADER + t.pixels.length > PRESENT.SLOT_SIZE) {
				this.warnOnce("a frame's textures overflow the present slot; some are not shown");
				break;
			}
			new Int32Array(this.presentBuf, base + at, PRESENT.TEX_HEADER / 4).set([id, t.kind, t.w, t.h, t.version, t.scale, 0, 0]);
			bytes.set(t.pixels, at + PRESENT.TEX_HEADER);
			at += PRESENT.TEX_HEADER + t.pixels.length;
			ntex++;
		}
		words[PRESENT.W_WORD] = out.w;
		words[PRESENT.H_WORD] = out.h;
		words[PRESENT.NCMD_WORD] = cmds.length;
		words[PRESENT.NTEX_WORD] = ntex;
		words[PRESENT.INTEGER_WORD] = this.integer;
		words[PRESENT.FRAME_WORD] = ++this.frame;
		Atomics.store(P, PRESENT.LATEST_WORD, s);
		Atomics.add(P, PRESENT.FRAMES_WORD, 1);
		this.cmds = [];
	}

	makeImports() {
		const ok = () => 0;
		const none = () => {};
		const imports = {
			// Init and stubs.
			Init: ok,
			InitSubSystem: ok,
			Quit: none,
			SetHint: () => 1,
			GetError: () => this.cstr(this.error),
			GetNumVideoDrivers: () => 1,
			GetVideoDriver: (i) => (i === 0 ? this.cstr("browser") : 0),
			LoadObject: () => this.fail("no shared objects in the browser", 0),
			LoadFunction: () => this.fail("no shared objects in the browser", 0),
			free: none,
			RWFromFile: () => this.fail("no SDL files in the browser", 0),
			GameControllerAddMappingsFromRW: () => this.fail("no mapping files in the browser"),
			SetRelativeMouseMode: () => this.fail("no mouse in the browser host"),
			GetTicks: () => this.ticks() | 0,
			GetPrefPath: () => this.cstr("/data/"),

			// Window and renderer.
			CreateWindow: (title, _x, _y, w, h) => {
				this.window = { w, h };
				this.post({ title: title ? this.cstring(title) : "" });
				return WINDOW;
			},
			DestroyWindow: none,
			GetWindowFlags: () => WINDOW_SHOWN | (this.focus ? WINDOW_INPUT_FOCUS : 0),
			GetWindowDisplayMode: (_win, mode) => {
				const dv = this.dv();
				dv.setUint32(mode, 0x16161804, true);
				dv.setInt32(mode + 4, this.window.w, true);
				dv.setInt32(mode + 8, this.window.h, true);
				dv.setInt32(mode + 12, 60, true);
				dv.setUint32(mode + 16, 0, true);
				return 0;
			},
			SetWindowFullscreen: (_win, flags) => {
				this.post({ fullscreen: flags !== 0 });
				return 0;
			},
			CreateRenderer: () => RENDERER,
			DestroyRenderer: none,
			GetRendererOutputSize: (_r, w, h) => {
				const dv = this.dv();
				if (w) dv.setInt32(w, this.window.w, true);
				if (h) dv.setInt32(h, this.window.h, true);
				return 0;
			},
			RenderSetLogicalSize: (_r, w, h) => {
				this.logical = w > 0 && h > 0 ? { w, h } : null;
				return 0;
			},
			RenderSetIntegerScale: (_r, on) => {
				this.integer = on ? 1 : 0;
				return 0;
			},
			SetRenderDrawBlendMode: (_r, mode) => {
				this.drawBlend = mode;
				return 0;
			},
			SetRenderDrawColor: (_r, r, g, b, a) => {
				this.color = [r & 255, g & 255, b & 255, a & 255];
				return 0;
			},
			RenderClear: () => {
				this.cmds.push([CMD.CLEAR, ...this.color]);
				return 0;
			},
			RenderFillRect: (_r, rect) => {
				const out = this.output();
				this.cmds.push([CMD.FILL, ...this.color, this.drawBlend, ...this.rect(rect, [0, 0, out.w, out.h])]);
				return 0;
			},
			RenderReadPixels: () => this.fail("SDL_RenderReadPixels: not in the browser host"),
			RenderPresent: () => this.present(),

			// Textures.
			CreateTexture: (_r, format, _access, w, h) => {
				const kind = KIND_OF_FORMAT.get(format >>> 0);
				if (kind === undefined) return this.fail(`texture format 0x${(format >>> 0).toString(16)} is not supported`, 0);
				if (w <= 0 || h <= 0) return this.fail("texture size", 0);
				const id = this.nextTexture++;
				this.textures.set(id, {
					kind, w, h, pixels: new Uint8Array(w * h * 4), version: 0,
					scale: 0, blend: BLEND.NONE, alpha: 255,
				});
				return id;
			},
			DestroyTexture: (t) => void this.textures.delete(t),
			UpdateTexture: (t, rect, pixels, pitch) => {
				const tex = this.textures.get(t);
				if (!tex) return this.fail("invalid texture");
				const [x, y, w, h] = this.rect(rect, [0, 0, tex.w, tex.h]);
				if (x < 0 || y < 0 || w < 0 || h < 0 || x + w > tex.w || y + h > tex.h) return this.fail("rect outside the texture");
				const m = this.u8();
				for (let row = 0; row < h; row++) {
					const src = pixels + row * pitch;
					tex.pixels.set(m.subarray(src, src + w * 4), ((y + row) * tex.w + x) * 4);
				}
				tex.version++;
				return 0;
			},
			SetTextureScaleMode: (t, mode) => this.texSet(t, "scale", mode),
			SetTextureBlendMode: (t, mode) => this.texSet(t, "blend", mode),
			SetTextureAlphaMod: (t, a) => this.texSet(t, "alpha", a & 255),
			RenderCopy: (_r, t, src, dst) => {
				const tex = this.textures.get(t);
				if (!tex) return this.fail("invalid texture");
				const out = this.output();
				this.cmds.push([CMD.COPY, t, tex.alpha, tex.blend,
					...this.rect(src, [0, 0, tex.w, tex.h]), ...this.rect(dst, [0, 0, out.w, out.h])]);
				return 0;
			},

			// Events and keyboard.
			PollEvent: (ev) => {
				if (this.queue.length === 0) this.pump();
				if (this.queue.length === 0) return 0;
				if (ev === 0) return 1;
				const dv = this.dv();
				new Uint8Array(dv.buffer, ev, EVENT_SIZE).fill(0);
				this.queue.shift()(dv, ev);
				return 1;
			},
			GetKeyboardState: (numkeys) => {
				if (numkeys) this.dv().setInt32(numkeys, NUM_SCANCODES, true);
				return this.page;
			},
			GetScancodeName: (s) => this.cstr(NAME_OF_SCANCODE.get(s) ?? ""),
			GetScancodeFromName: (name) => SCANCODE_OF_NAME.get(this.cstring(name).toLowerCase()) ?? 0,

			// Game controllers. The device index is the page's pad slot.
			JoystickGetDeviceInstanceID: (i) => (i >= 0 && i < CONTROL.PADS_MAX && this.pads[i].connected ? this.pads[i].instance : -1),
			GameControllerOpen: (i) => {
				const pad = this.pads[i];
				if (!pad?.connected) return this.fail(`no pad at index ${i}`, 0);
				pad.open = true;
				return PAD_HANDLE + pad.instance;
			},
			GameControllerClose: (h) => {
				const p = this.pad(h);
				if (p) p.pad.open = false;
			},
			GameControllerFromInstanceID: (id) => (this.pad(PAD_HANDLE + id) ? PAD_HANDLE + id : 0),
			GameControllerGetJoystick: (h) => h,
			JoystickInstanceID: (h) => (this.pad(h) ? h - PAD_HANDLE : -1),
			GameControllerGetType: (h) => {
				const p = this.pad(h);
				return p ? this.ctlView.getInt32(p.at + PAD.TYPE, true) : 0;
			},
			GameControllerName: (h) => {
				const p = this.pad(h);
				if (!p) return 0;
				const name = this.ctlBytes.subarray(p.at + PAD.NAME, p.at + PAD.NAME + PAD.NAME_MAX + 1);
				const end = name.indexOf(0);
				return this.cstr(text.decode(name.slice(0, end < 0 ? PAD.NAME_MAX : end)));
			},
			GameControllerSetPlayerIndex: none,
			GameControllerGetButton: (h, b) => {
				const p = this.pad(h);
				return p && b >= 0 && b < 32 ? (p.pad.buttons >>> b) & 1 : 0;
			},
			GameControllerGetAxis: (h, a) => {
				const p = this.pad(h);
				return p && a >= 0 && a < PAD_AXES ? p.pad.axes[a] : 0;
			},
			GameControllerGetButtonFromString: (s) => BUTTON_OF_NAME.get(this.cstring(s).toLowerCase()) ?? -1,
			GameControllerRumble: (h, lo, hi, ms) => {
				const p = this.pad(h);
				if (!p) return this.fail("invalid controller");
				if (this.ctlView.getInt32(p.at + PAD.RUMBLE_OK, true) !== 1) return this.fail("this browser has no rumble for it");
				this.ctlView.setInt32(p.at + PAD.RUMBLE_LO, lo & 0xffff, true);
				this.ctlView.setInt32(p.at + PAD.RUMBLE_HI, hi & 0xffff, true);
				this.ctlView.setInt32(p.at + PAD.RUMBLE_MS, ms >>> 0, true);
				Atomics.add(this.ctl, (p.at + PAD.RUMBLE_SEQ) / 4, 1);
				return 0;
			},

			// Audio: one s16 stereo output device on the page's ring.
			OpenAudioDevice: (_name, capture, desired, obtained) => {
				if (capture) return this.fail("no audio capture in the browser host", 0);
				const dv = this.dv();
				const freq = dv.getInt32(desired, true), format = dv.getUint16(desired + 4, true), channels = dv.getUint8(desired + 6);
				if (format !== AUDIO_S16LSB || channels !== 2) return this.fail("audio: s16 stereo only", 0);
				const A = this.audioWords;
				Atomics.store(A, AUDIO.PAUSED_WORD, 1);
				Atomics.store(A, AUDIO.READ_WORD, Atomics.load(A, AUDIO.WRITE_WORD));
				Atomics.store(A, AUDIO.RATE_WORD, freq);
				if (freq !== this.audioRate) {
					this.audioRate = freq;
					this.post({ audio: freq });
				}
				if (obtained) {
					const samples = dv.getUint16(desired + 8, true);
					new Uint8Array(dv.buffer, obtained, 24).set(new Uint8Array(dv.buffer, desired, 24));
					dv.setUint8(obtained + 7, 0); // silence
					dv.setUint32(obtained + 12, samples * 4, true); // size
				}
				return AUDIO_DEVICE;
			},
			CloseAudioDevice: () => {
				const A = this.audioWords;
				Atomics.store(A, AUDIO.PAUSED_WORD, 1);
				Atomics.store(A, AUDIO.READ_WORD, Atomics.load(A, AUDIO.WRITE_WORD));
			},
			PauseAudioDevice: (_dev, on) => void Atomics.store(this.audioWords, AUDIO.PAUSED_WORD, on ? 1 : 0),
			GetQueuedAudioSize: () => {
				const A = this.audioWords;
				return ((Atomics.load(A, AUDIO.WRITE_WORD) - Atomics.load(A, AUDIO.READ_WORD)) | 0) * 4;
			},
			// Queues what fits in the ring; the rest is dropped (core/audio
			// keeps the queue at its target, far under the ring).
			QueueAudio: (_dev, data, len) => {
				const A = this.audioWords, N = AUDIO.RING_FRAMES;
				const w = Atomics.load(A, AUDIO.WRITE_WORD), r = Atomics.load(A, AUDIO.READ_WORD);
				const n = Math.min(len >>> 2, N - ((w - r) | 0));
				if (n < len >>> 2) this.warnOnce("the audio ring is full; sound dropped");
				const src = new Int16Array(this.memory.buffer, data, n * 2);
				const at = w & (N - 1), first = Math.min(n, N - at);
				this.ring.set(src.subarray(0, first * 2), at * 2);
				this.ring.set(src.subarray(first * 2), 0);
				Atomics.store(A, AUDIO.WRITE_WORD, (w + n) | 0);
				return 0;
			},
		};
		return Object.fromEntries(Object.entries(imports).map(([k, f]) => [`SDL_${k}`, f]));
	}

	texSet(t, field, value) {
		const tex = this.textures.get(t);
		if (!tex) return this.fail("invalid texture");
		tex[field] = value;
		return 0;
	}
}
