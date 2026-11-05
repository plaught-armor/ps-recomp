// The SharedArrayBuffers between the play page (main thread), its Worker
// (web/sdl.js) and the audio worklet (web/audio.js). The page makes all
// three before the Worker starts. Offsets are in bytes unless named WORD.

// Control: input from the page. Main writes pads and pushes events; the
// Worker reads them when SDL_PollEvent finds its own queue empty.
export const CONTROL = {
	RING_WRITE_WORD: 0, // events pushed by main, a running count
	RING_READ_WORD: 1, // events taken by the Worker, a running count
	FOCUS_WORD: 2, // 1 while the page has keyboard focus
	PADS: 64,
	PAD_SIZE: 128,
	PADS_MAX: 4,
	RING: 64 + 4 * 128,
	RING_LEN: 256, // a power of two
	EVENT_SIZE: 16, // four i32: type, a, b, c
};
CONTROL.SIZE = CONTROL.RING + CONTROL.RING_LEN * CONTROL.EVENT_SIZE;

// A pad slot, offsets from its start. Main fills it in, then stores
// CONNECTED last; a reconnect gets a new INSTANCE. BUTTONS has bit b set
// while SDL_GameControllerButton b is down; AXES are SDL's six axes.
export const PAD = {
	CONNECTED: 0,
	INSTANCE: 4,
	TYPE: 8, // SDL_GameControllerType
	BUTTONS: 12,
	AXES: 16, // 6 x i16
	RUMBLE_OK: 28, // 1 when the pad has a vibrationActuator
	RUMBLE_SEQ: 32, // bumped by the Worker for each request
	RUMBLE_LO: 36,
	RUMBLE_HI: 40,
	RUMBLE_MS: 44,
	NAME: 64, // UTF-8, NUL-terminated, 63 bytes at most
	NAME_MAX: 63,
};

// Event types in the control ring (not SDL's numbers).
export const EV = { KEYDOWN: 1, KEYUP: 2, QUIT: 3 }; // a = scancode, b = repeat

// Audio: an s16 stereo ring. WRITE and READ are running frame counts (i32,
// wrapping), so queued = WRITE - READ. The Worker owns WRITE; the worklet
// moves READ on by compare-and-swap, and the Worker drops the queue by
// storing READ = WRITE, which makes the worklet's swap in flight fail.
export const AUDIO = {
	WRITE_WORD: 0,
	READ_WORD: 1,
	PAUSED_WORD: 2,
	RATE_WORD: 3,
	RING: 16,
	RING_FRAMES: 1 << 15, // 0.68 s at 48 kHz, over AUDIO_LATENCY_MAX (250 ms)
};
AUDIO.SIZE = AUDIO.RING + AUDIO.RING_FRAMES * 4;

// Present: three slots, each one whole frame (header, commands, then every
// texture the commands use, pixels included). The Worker writes a slot that
// is neither LATEST nor READING, then stores LATEST. Main stores READING =
// LATEST, then checks LATEST again before it reads, so the Worker never
// writes the slot being read.
export const PRESENT = {
	LATEST_WORD: 0, // -1 before the first frame
	READING_WORD: 1, // -1 when main reads nothing
	FRAMES_WORD: 2, // frames presented, a running count
	SLOTS: 64,
	SLOT_COUNT: 3,
	SLOT_SIZE: 12 << 20,
	// Slot layout, offsets from the slot's start.
	W_WORD: 0, // output (logical) size
	H_WORD: 1,
	NCMD_WORD: 2,
	NTEX_WORD: 3,
	INTEGER_WORD: 4, // 1: scale by whole multiples only
	FRAME_WORD: 5,
	CMDS: 64,
	CMD_WORDS: 16,
	CMDS_MAX: 64,
	TEX_HEADER: 32, // id, kind, w, h, version, scale mode; then w*h*4 bytes
};
PRESENT.TEXTURES = PRESENT.CMDS + PRESENT.CMD_WORDS * 4 * PRESENT.CMDS_MAX;
PRESENT.SIZE = PRESENT.SLOTS + PRESENT.SLOT_COUNT * PRESENT.SLOT_SIZE;

// Commands: CLEAR r g b a; FILL r g b a blend x y w h; COPY texture alpha
// blend sx sy sw sh dx dy dw dh.
export const CMD = { CLEAR: 1, FILL: 2, COPY: 3 };

// Texture pixel kinds, from the SDL format: the bytes in memory order.
export const KIND = { BGRX: 0, BGRA: 1, RGBA: 2 };

// SDL_BlendMode.
export const BLEND = { NONE: 0, BLEND: 1, ADD: 2, MOD: 4, MUL: 8 };
