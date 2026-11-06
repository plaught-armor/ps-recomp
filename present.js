// Main-thread side of the renderer: replays the frames web/sdl.js writes into
// the present slots (web/layout.js) on a WebGL2 canvas. One GL texture per
// SDL texture, uploaded again only when its version changes; the pixel kind
// is swizzled in the shader, alpha mod is a uniform, and SDL's blend modes
// are GL blend functions.
import { BLEND, CMD, KIND, PRESENT } from "./layout.js";

const VERTEX = `#version 300 es
uniform vec4 dst; // x, y, w, h in output pixels
uniform vec4 src; // x, y, w, h in texels
uniform vec2 out_size;
uniform vec2 tex_size;
out vec2 uv;
void main() {
	vec2 c = vec2(gl_VertexID & 1, gl_VertexID >> 1);
	vec2 p = (dst.xy + c * dst.zw) / out_size;
	uv = (src.xy + c * src.zw) / tex_size;
	gl_Position = vec4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}`;

const FRAGMENT = `#version 300 es
precision mediump float;
uniform sampler2D tex;
uniform int kind; // KIND, or -1 for a solid fill
uniform vec4 color; // the fill colour, or (1, 1, 1, alpha mod)
in vec2 uv;
out vec4 frag;
void main() {
	if (kind < 0) {
		frag = color;
		return;
	}
	vec4 t = texture(tex, uv);
	if (kind == ${KIND.BGRX}) t = vec4(t.bgr, 1.0);
	else if (kind == ${KIND.BGRA}) t = t.bgra;
	frag = vec4(t.rgb, t.a * color.a);
}`;

// Textures not drawn for this many frames are dropped (SDL_DestroyTexture
// does not reach main).
const STALE_FRAMES = 600;

export class Present {
	// canvas: the page's canvas. present: the present SharedArrayBuffer.
	constructor(canvas, present) {
		this.canvas = canvas;
		this.buf = present;
		this.words = new Int32Array(present, 0, PRESENT.SLOTS / 4);
		const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false });
		if (!gl) throw new Error("WebGL2 is not available");
		this.gl = gl;
		this.program = link(gl);
		this.loc = {};
		for (const u of ["dst", "src", "out_size", "tex_size", "tex", "kind", "color"]) {
			this.loc[u] = gl.getUniformLocation(this.program, u);
		}
		gl.bindVertexArray(gl.createVertexArray());
		gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
		this.textures = new Map(); // id -> {gl, w, h, version, scale, used}
		this.shown = 0; // FRAME_WORD of the last frame drawn
		this.drawn = 0; // frames replayed
		// Whether texSubImage2D took a view of the SharedArrayBuffer itself:
		// null until the first upload; false when it threw and uploads go
		// through a copy.
		this.sabUpload = null;
		this.scratch = new Uint8Array(0);
	}

	// Draws the newest frame if it is new. Call on each animation frame.
	frame() {
		return this.withLatest((slot) => {
			const size = this.fit();
			this.replay(slot, size, this.letterbox(slot, size));
		});
	}

	// The newest frame drawn at its own size (one canvas pixel per output
	// pixel, no letterbox), as RGBA rows from the top, for the gate's
	// checksum: {w, h, frame, pixels}. Null before the first frame.
	capture() {
		let result = null;
		this.withLatest((slot) => {
			const gl = this.gl;
			const w = slot.w, h = slot.h;
			const fb = gl.createFramebuffer();
			const rb = gl.createRenderbuffer();
			gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
			gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGBA8, w, h);
			gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
			gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rb);
			this.replay(slot, { w, h }, [0, 0, w, h]);
			const pixels = new Uint8Array(w * h * 4);
			gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
			gl.bindFramebuffer(gl.FRAMEBUFFER, null);
			gl.deleteFramebuffer(fb);
			gl.deleteRenderbuffer(rb);
			// GL rows run from the bottom.
			const flipped = new Uint8Array(pixels.length);
			for (let y = 0; y < h; y++) flipped.set(pixels.subarray((h - 1 - y) * w * 4, (h - y) * w * 4), y * w * 4);
			result = { w, h, frame: slot.frame, pixels: flipped };
		}, true);
		return result;
	}

	// Calls f(slot) with the newest slot held against the Worker's writes
	// (the READING handshake in web/layout.js). Skips a frame already shown
	// unless again is set. Returns whether f ran.
	withLatest(f, again = false) {
		const P = this.words;
		let s = Atomics.load(P, PRESENT.LATEST_WORD);
		if (s < 0) return false;
		for (;;) {
			Atomics.store(P, PRESENT.READING_WORD, s);
			const now = Atomics.load(P, PRESENT.LATEST_WORD);
			if (now === s) break;
			s = now;
		}
		try {
			const slot = this.slot(s);
			if (!again && slot.frame === this.shown) return false;
			f(slot);
			this.shown = slot.frame;
			return true;
		} finally {
			Atomics.store(P, PRESENT.READING_WORD, -1);
		}
	}

	// Slot s's header, commands and texture records.
	slot(s) {
		const base = PRESENT.SLOTS + s * PRESENT.SLOT_SIZE;
		const w = new Int32Array(this.buf, base, PRESENT.TEXTURES / 4);
		const cmds = [];
		for (let i = 0; i < w[PRESENT.NCMD_WORD]; i++) {
			const at = PRESENT.CMDS / 4 + i * PRESENT.CMD_WORDS;
			cmds.push(w.subarray(at, at + PRESENT.CMD_WORDS));
		}
		const textures = new Map();
		let at = PRESENT.TEXTURES;
		for (let i = 0; i < w[PRESENT.NTEX_WORD]; i++) {
			const [id, kind, tw, th, version, scale] = new Int32Array(this.buf, base + at, PRESENT.TEX_HEADER / 4);
			const n = tw * th * 4;
			textures.set(id, { kind, w: tw, h: th, version, scale, pixels: new Uint8Array(this.buf, base + at + PRESENT.TEX_HEADER, n) });
			at += PRESENT.TEX_HEADER + n;
		}
		return {
			w: w[PRESENT.W_WORD], h: w[PRESENT.H_WORD], integer: w[PRESENT.INTEGER_WORD] !== 0,
			frame: w[PRESENT.FRAME_WORD], cmds, textures,
		};
	}

	// Sizes the canvas's drawing buffer to its CSS box in device pixels.
	fit() {
		const c = this.canvas, r = devicePixelRatio || 1;
		const w = Math.max(1, Math.round(c.clientWidth * r)), h = Math.max(1, Math.round(c.clientHeight * r));
		if (c.width !== w || c.height !== h) {
			c.width = w;
			c.height = h;
		}
		return { w, h };
	}

	// The output's place in the canvas: as large as fits, centred, by whole
	// multiples when the frame asks for integer scaling and one fits.
	letterbox(slot, size) {
		let k = Math.min(size.w / slot.w, size.h / slot.h);
		if (slot.integer && k >= 1) k = Math.floor(k);
		const w = Math.round(slot.w * k), h = Math.round(slot.h * k);
		return [(size.w - w) >> 1, (size.h - h) >> 1, w, h];
	}

	// Draws slot's commands into the bound framebuffer of the given size, the
	// output at view = [x, y, w, h] (from the top left).
	replay(slot, size, view) {
		const gl = this.gl, L = this.loc;
		this.drawn++;
		for (const [id, t] of slot.textures) this.upload(id, t);
		gl.useProgram(this.program);
		gl.uniform2f(L.out_size, slot.w, slot.h);
		gl.uniform1i(L.tex, 0);
		gl.disable(gl.SCISSOR_TEST);
		gl.viewport(0, 0, size.w, size.h);
		gl.clearColor(0, 0, 0, 1);
		gl.clear(gl.COLOR_BUFFER_BIT);
		gl.viewport(view[0], size.h - view[1] - view[3], view[2], view[3]);
		for (const c of slot.cmds) {
			switch (c[0]) {
			case CMD.CLEAR:
				// SDL_RenderClear clears the whole target.
				gl.disable(gl.BLEND);
				gl.clearColor(c[1] / 255, c[2] / 255, c[3] / 255, 1);
				gl.clear(gl.COLOR_BUFFER_BIT);
				break;
			case CMD.FILL:
				this.blend(c[5]);
				gl.uniform1i(L.kind, -1);
				gl.uniform4f(L.color, c[1] / 255, c[2] / 255, c[3] / 255, c[4] / 255);
				gl.uniform4f(L.dst, c[6], c[7], c[8], c[9]);
				gl.uniform4f(L.src, 0, 0, 1, 1);
				gl.uniform2f(L.tex_size, 1, 1);
				gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
				break;
			case CMD.COPY: {
				const t = this.textures.get(c[1]);
				if (!t || !slot.textures.has(c[1])) break;
				t.used = this.drawn;
				this.blend(c[3]);
				gl.bindTexture(gl.TEXTURE_2D, t.gl);
				gl.uniform1i(L.kind, t.kind);
				gl.uniform4f(L.color, 1, 1, 1, c[2] / 255);
				gl.uniform4f(L.src, c[4], c[5], c[6], c[7]);
				gl.uniform2f(L.tex_size, t.w, t.h);
				gl.uniform4f(L.dst, c[8], c[9], c[10], c[11]);
				gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
				break;
			}
			}
		}
		for (const [id, t] of this.textures) {
			if (this.drawn - t.used > STALE_FRAMES) {
				gl.deleteTexture(t.gl);
				this.textures.delete(id);
			}
		}
	}

	// SDL_BlendMode as GL blend functions (SDL 2's definitions).
	blend(mode) {
		const gl = this.gl;
		if (mode === BLEND.NONE) {
			gl.disable(gl.BLEND);
			return;
		}
		gl.enable(gl.BLEND);
		gl.blendEquation(gl.FUNC_ADD);
		switch (mode) {
		case BLEND.BLEND: gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA); break;
		case BLEND.ADD: gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE, gl.ZERO, gl.ONE); break;
		case BLEND.MOD: gl.blendFuncSeparate(gl.ZERO, gl.SRC_COLOR, gl.ZERO, gl.ONE); break;
		case BLEND.MUL: gl.blendFuncSeparate(gl.DST_COLOR, gl.ONE_MINUS_SRC_ALPHA, gl.ZERO, gl.ONE); break;
		default: gl.disable(gl.BLEND);
		}
	}

	// Brings texture id up to date with its record t from a slot.
	upload(id, t) {
		const gl = this.gl;
		let g = this.textures.get(id);
		if (!g || g.w !== t.w || g.h !== t.h) {
			if (g) gl.deleteTexture(g.gl);
			g = { gl: gl.createTexture(), w: t.w, h: t.h, kind: t.kind, version: -1, scale: -1, used: this.drawn };
			gl.bindTexture(gl.TEXTURE_2D, g.gl);
			gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, t.w, t.h);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
			this.textures.set(id, g);
		}
		gl.bindTexture(gl.TEXTURE_2D, g.gl);
		g.kind = t.kind;
		if (g.scale !== t.scale) {
			// SDL_ScaleMode: 0 nearest, 1 linear, 2 best (linear here).
			const f = t.scale === 0 ? gl.NEAREST : gl.LINEAR;
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, f);
			gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, f);
			g.scale = t.scale;
		}
		if (g.version === t.version) return;
		g.version = t.version;
		if (this.sabUpload !== false) {
			try {
				gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, t.w, t.h, gl.RGBA, gl.UNSIGNED_BYTE, t.pixels);
				this.sabUpload = true;
				return;
			} catch {
				this.sabUpload = false;
			}
		}
		if (this.scratch.length < t.pixels.length) this.scratch = new Uint8Array(t.pixels.length);
		const copy = this.scratch.subarray(0, t.pixels.length);
		copy.set(t.pixels);
		gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, t.w, t.h, gl.RGBA, gl.UNSIGNED_BYTE, copy);
	}
}

function link(gl) {
	const shader = (type, text) => {
		const s = gl.createShader(type);
		gl.shaderSource(s, text);
		gl.compileShader(s);
		if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(`shader: ${gl.getShaderInfoLog(s)}`);
		return s;
	};
	const p = gl.createProgram();
	gl.attachShader(p, shader(gl.VERTEX_SHADER, VERTEX));
	gl.attachShader(p, shader(gl.FRAGMENT_SHADER, FRAGMENT));
	gl.linkProgram(p);
	if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`program: ${gl.getProgramInfoLog(p)}`);
	return p;
}
