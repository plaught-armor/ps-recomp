// The audio worklet: plays the s16 stereo ring web/sdl.js fills (web/layout.js
// AUDIO). The page makes the AudioContext at the ring's rate, so frames go
// out one for one. An empty ring or a paused device plays silence.
//
// processorOptions: {audio: the SharedArrayBuffer}. About once a second it
// posts {frames, rms, silent} to the port: the frames taken from the ring,
// their RMS, and the frames it played as silence while the device was not
// paused, an empty ring (an underrun: the stutter a report counts).
import { AUDIO } from "./layout.js";

const N = AUDIO.RING_FRAMES;

class Ring extends AudioWorkletProcessor {
	constructor({ processorOptions: { audio } }) {
		super();
		this.words = new Int32Array(audio, 0, AUDIO.RING / 4);
		this.ring = new Int16Array(audio, AUDIO.RING, N * 2);
		this.frames = 0; // frames taken from the ring since the last report
		this.squares = 0; // their sum of squared samples
		this.elapsed = 0; // frames played since the last report
		this.silent = 0; // frames played as silence while not paused
	}

	process(_inputs, [out]) {
		const left = out[0], right = out[1] ?? out[0];
		const want = left.length;
		const A = this.words;
		let n = 0;
		const paused = Atomics.load(A, AUDIO.PAUSED_WORD) !== 0;
		if (!paused) {
			const r = Atomics.load(A, AUDIO.READ_WORD), w = Atomics.load(A, AUDIO.WRITE_WORD);
			n = Math.max(0, Math.min(want, (w - r) | 0));
			for (let i = 0; i < n; i++) {
				const at = ((r + i) & (N - 1)) * 2;
				left[i] = this.ring[at] / 32768;
				right[i] = this.ring[at + 1] / 32768;
			}
			// Fails when the Worker dropped the queue meanwhile: this
			// quantum is silent and the ring keeps the Worker's READ.
			if (n > 0 && Atomics.compareExchange(A, AUDIO.READ_WORD, r, (r + n) | 0) !== r) n = 0;
		}
		left.fill(0, n);
		if (right !== left) right.fill(0, n);
		if (!paused) this.silent += want - n;
		this.measure(left, right, n, want);
		return true;
	}

	measure(left, right, n, want) {
		for (let i = 0; i < n; i++) this.squares += left[i] * left[i] + right[i] * right[i];
		this.frames += n;
		this.elapsed += want;
		if (this.elapsed < sampleRate) return;
		this.port.postMessage({ frames: this.frames, rms: this.frames ? Math.sqrt(this.squares / (2 * this.frames)) : 0, silent: this.silent });
		this.frames = this.squares = this.elapsed = this.silent = 0;
	}
}

registerProcessor("ring", Ring);
