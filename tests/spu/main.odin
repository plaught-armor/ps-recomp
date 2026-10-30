// SPU2 voice test: the API a port's own sound driver uses (spu_write,
// spu_voice_on, spu_voice_set, spu_voice_off, spu_voice_status), played by
// spu_mix, and sound RAM through a snapshot.
//
// Voices play SPU ADPCM blocks (16 bytes: shift and filter, loop flags, 28
// samples) at pitch 0x1000, one sample per mixed sample, so a block lasts 28.
// The snapshot part keys a voice on, saves, mixes, scribbles over its
// blocks and loads: mixing again must give the same samples.
// The FMOD reverb (reverb_set, reverb_mix) runs each preset over a fixed
// send, and FMOD's Reverb_SetProperties (fmod_reverb) through a sequence of
// settings; hashes of its return pin the output. A core's reverb (spu_effect,
// spu_effect_enable, spu_voice_send) rings on after its voice ends.
// Mixing is wide: voices that cancel leave no clipped residue, a core
// saturates once at its output, and the host sum is left unclamped for the
// host. A voice at pitch 0 holds its sample while its envelope steps. A
// core's master volume (spu_master) scales its output before it saturates.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"

LOOP :: 0x1000 // start, plain, end with repeat
ONCE :: 0x2000 // plain, end without repeat
SHORT :: 0x3000 // one block, end without repeat
EFFECT :: 0x4000 // one block, end without repeat
WIDE :: 0x5000 // one block looping on itself
SNAP :: 0x10000 // varied samples, end with repeat
BLOCKS :: 3

// Envelope: fastest attack, sustain at full level, fastest linear release.
ADSR1 :: 0x00ff
ADSR2 :: 0x1fc0

// FNV-1a of reverb_mix's return per mode 1 .. 9 for reverb_presets' send.
// The same for reverb_fmod's sequence.
REVERB_FMOD_HASH: u64 = 0x9d814a48644cebf5

REVERB_HASH := [9]u64 {
	0x28fde966e53c1262,
	0x91c1da24c37c8fd4,
	0x31ae4dfafb1f252b,
	0xcbd57958ce6a939f,
	0xbc27f64eb0fffc79,
	0x68b43ebb83b6f583,
	0x70bcb54b68945c07,
	0xe3c21c5196cc3ef4,
	0xcb6373d5bfd50937,
}

rev: iop.Reverb // a work area too big for the stack
failed: bool
snap: core.Snapshot
loaded: bool // not emulated state: tells the run after the load apart
mixed: [2][BLOCKS * 28 * 2]i32 // before and after the load

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL %s (line %d)", what, loc.line)
		failed = true
	}
}

// Write a block of samples all `nib` (shift 0, filter 0) with loop flags.
block :: proc(addr: u32, flags: u8, nib: u8) {
	b: [16]u8
	b[1] = flags
	for &x in b[2:] {x = nib | nib << 4}
	check(iop.spu_write(addr, b[:]) == 16, "spu_write block")
}

// Mix n stereo samples into silence.
mix :: proc(n: int) -> []i32 {
	out := make([]i32, n * 2, context.temp_allocator)
	iop.spu_mix(out)
	return out
}

key :: proc(ssa: u32) -> iop.Spu_Key {
	return {ssa = ssa, pitch = 0x1000, voll = 0x3fff, volr = 0x3fff, adsr1 = ADSR1, adsr2 = ADSR2}
}

voices :: proc() {
	block(LOOP, 4, 1)
	block(LOOP + 16, 0, 1)
	block(LOOP + 32, 3, 1)
	block(ONCE, 0, 2)
	block(ONCE + 16, 1, 2)

	iop.spu_voice_on(0, 0, key(LOOP))
	st := iop.spu_voice_status(0, 0)
	check(st.on && !st.endx && st.nax == LOOP && st.lsax == LOOP, "key on")
	out := mix(56)
	st = iop.spu_voice_status(0, 0)
	check(st.on && !st.endx && st.nax == LOOP + 32, "two blocks played")
	check(st.envx == 0x7fff, "attack reaches full level")
	check(out[100] > 0 && out[100] == out[101], "voice heard in both channels")
	mix(28)
	st = iop.spu_voice_status(0, 0)
	check(st.on && st.endx && st.nax == LOOP && st.lsax == LOOP, "end with repeat loops to LSA, sets ENDX")

	iop.spu_voice_set(0, 0, 0x2000, 0x3fff, 0x3fff)
	mix(14)
	check(iop.spu_voice_status(0, 0).nax == LOOP + 16, "doubled pitch plays a block in 14")

	iop.spu_voice_off(0, 0)
	st = iop.spu_voice_status(0, 0)
	check(st.on && st.envx == 0x7fff, "key off releases, does not cut")
	mix(4)
	st = iop.spu_voice_status(0, 0)
	check(!st.on && st.envx == 0, "release reaches zero and stops")

	iop.spu_voice_on(1, 23, key(ONCE))
	mix(56)
	st = iop.spu_voice_status(1, 23)
	check(!st.on && st.endx && st.nax == ONCE + 16, "end without repeat stops")
	check(st.envx == 0, "end without repeat zeroes ENVX")
	iop.spu_voice_on(1, 23, key(ONCE))
	st = iop.spu_voice_status(1, 23)
	check(st.on && !st.endx && st.nax == ONCE, "key on clears ENDX")
	iop.spu_voice_off(1, 23)
	mix(4)

	// Ends during a slow attack (rate 0x2c: +7 every sample): its last
	// sample is still heard, and ENVX is 0 once it stops.
	block(SHORT, 1, 1)
	k := key(SHORT)
	k.adsr1 = 0x2c00 | ADSR1 & 0xff
	iop.spu_voice_on(1, 0, k)
	out = mix(28)
	st = iop.spu_voice_status(1, 0)
	check(!st.on && st.endx && st.envx == 0, "end during attack zeroes ENVX")
	check(out[54] > 0, "last sample of a one-shot heard")

	edge: [8]u8
	check(iop.spu_write(iop.SPU_RAM_SIZE - 4, edge[:]) == 4, "spu_write clipped at the end of sound RAM")
}

// Mix n stereo samples onto a buffer already holding `base`, as the host's
// is after the sources before the SPU2.
mix_onto :: proc(n: int, base: i32) -> []i32 {
	out := make([]i32, n * 2, context.temp_allocator)
	for &x in out {x = base}
	iop.spu_mix(out)
	return out
}

// Saturation happens once per core output and once at the host, not per
// voice or per source.
wide :: proc() {
	block(WIDE, 7, 7) // every sample 7 << 12, near full scale at full volume
	neg := key(WIDE)
	neg.voll, neg.volr = 0x4001, 0x4001 // -0x3fff

	// Two full-scale voices in opposite phase cancel, over a buffer another
	// source filled near the top: no clipped residue.
	iop.spu_voice_on(1, 10, key(WIDE))
	iop.spu_voice_on(1, 11, neg)
	out := mix_onto(56, 20000)
	ok := true
	for x in out {if abs(x - 20000) > 1 {ok = false}}
	check(ok, "cancelling voices sum to silence")
	check(iop.spu_voice_status(1, 10).envx == 0x7fff, "cancelling voices at full level")

	// Two in phase saturate once, at the core's output.
	iop.spu_voice_on(1, 11, key(WIDE))
	out = mix_onto(28, 0)
	check(out[54] == 32767 && out[55] == 32767, "a core saturates its sum")

	// The core's output adds onto the host buffer unclamped, and the other
	// sources, silent, leave it as it is: the host saturates the total.
	iop.spu_voice_off(1, 11)
	mix(4)
	out = mix_onto(28, 30000)
	check(out[54] > 32767, "a core adds onto the host sum unclamped")
	iop.fmod_mix(out)
	iop.adx_mix(out)
	check(out[54] > 32767, "silent FMOD and ADX leave the host sum")

	// Pitch 0, as a game pauses a voice: the voice holds its sample while
	// its envelope still steps, so a key off releases it to silence.
	iop.spu_voice_set(1, 10, 0, 0x3fff, 0x3fff)
	out = mix(28)
	held := out[0] != 0
	for x in out {if x != out[0] {held = false}}
	check(held, "pitch 0 holds a constant sample")
	iop.spu_voice_off(1, 10)
	mix(4)
	st := iop.spu_voice_status(1, 10)
	check(!st.on && st.envx == 0, "pitch 0 envelope releases to zero")
}

// A loud voice's output before master volume existed (8a73a97).
PRE_MASTER :: 28557

// MVOLL and MVOLR scale a core's output, in the format of a voice volume.
master :: proc() {
	// Never set, it is an exact unity: the output is as it was before. A
	// master volume set to 0x3fff is a step under it.
	iop.spu_voice_on(1, 10, key(WIDE))
	full := mix(28)[54]
	check(full == PRE_MASTER, "an unset master volume leaves the output as it was")
	iop.spu_master(1, 0x3fff, 0x2ccc)
	out := mix(28)
	check(out[54] == i32(i64(full) * 0x3fff >> 14), "MVOLL 0x3fff scales by 0x3fff/0x4000")
	check(out[55] == i32(i64(full) * 0x2ccc >> 14), "MVOLR 0x2ccc scales the right output")
	iop.spu_master(1, 0x4001, 0)
	out = mix(28)
	check(out[54] == i32(i64(full) * -0x3fff >> 14), "a negative MVOLL inverts")
	check(out[55] == 0, "MVOLR 0 mutes the right output")
	iop.spu_master(1, 0x8000, 0x3fff)
	out = mix(28)
	check(out[54] == i32(i64(full) * 0x3fff >> 14), "a sweeping MVOLL is taken at full scale")

	// Every voice of a core at full level and volume: the sum times the
	// master volume saturates, it does not wrap.
	iop.spu_master(1, 0x3fff, 0x3fff)
	for v in 0 ..< 24 {iop.spu_voice_on(1, v, key(WIDE))}
	out = mix(28)
	check(out[54] == 32767 && out[55] == 32767, "a loud core saturates through the master volume")
	for v in 0 ..< 24 {iop.spu_voice_off(1, v)}
	mix(4)
}

CHUNK :: 1024
FNV :: 0xcbf29ce484222325

// Run rev over n chunks of CHUNK frames of noise bursts (on one chunk, off
// three), hashing its return into h.
reverb_feed :: proc(seed: ^u32, h: ^u64, n: int) {
	send, acc: [CHUNK * 2]i32
	for c in 0 ..< n {
		for &x in send {
			seed^ = seed^ * 1103515245 + 12345
			x = c % 4 == 0 ? i32(seed^ >> 16) % 16000 - 8000 : 0
		}
		iop.reverb_mix(&rev, send[:], acc[:])
		for x in acc {
			for b in 0 ..< u32(4) {h^ = (h^ ~ u64(u32(x) >> (b * 8) & 0xff)) * 0x100000001b3}
		}
		acc = {}
	}
}

// Every preset over noise bursts (on 1024 frames, off 3072, so tails
// ring out), 0x20000 frames in chunks of 1024: twice the largest work area
// at the half rate.
reverb_presets :: proc() {
	seed: u32 = 1
	for mode in u32(1) ..= 9 {
		iop.reverb_set(&rev, mode, 0x3fff, 0x3fff, true)
		h: u64 = FNV
		reverb_feed(&seed, &h, 0x20000 / CHUNK)
		if h != REVERB_HASH[mode - 1] {
			fmt.eprintfln("FAIL reverb mode %d: hash %#16x", mode, h)
			failed = true
		}
	}
}

// FMOD's Reverb_SetProperties (fmod_reverb) over a running reverb: room
// -2500 mB (EVOL 0x2fff) on mode 1, mode 1 again at -1000 mB without a
// clear, mode 9 with no core flag (ignored), mode 5 at +500 mB (clamped to
// 0x3fff) from a full work area, then left and right EVOL apart.
reverb_fmod :: proc() {
	seed: u32 = 7
	h: u64 = FNV
	rev = {}
	iop.fmod_reverb(&rev, 1, transmute(u32)i32(-2500), 0x100)
	check(rev.mode == 1 && rev.evol == {0x2fff, 0x2fff}, "fmod_reverb: room level to EVOL")
	reverb_feed(&seed, &h, 32)
	iop.fmod_reverb(&rev, 1, transmute(u32)i32(-1000), 0x100)
	reverb_feed(&seed, &h, 32)
	iop.fmod_reverb(&rev, 9, 0, 0)
	check(rev.mode == 1, "fmod_reverb: no core flag, no change")
	reverb_feed(&seed, &h, 8)
	iop.fmod_reverb(&rev, 5, 500, 0x200)
	check(rev.mode == 5 && rev.evol == {0x3fff, 0x3fff}, "fmod_reverb: EVOL clamped")
	reverb_feed(&seed, &h, 64)
	iop.reverb_set(&rev, 5, 0x2000, 0x800, false)
	reverb_feed(&seed, &h, 32)
	if h != REVERB_FMOD_HASH {
		fmt.eprintfln("FAIL reverb FMOD sequence: hash %#16x", h)
		failed = true
	}
}

// Play the EFFECT block once on core 0 and mix past its end.
effect_play :: proc(send: bool) -> []i32 {
	iop.spu_voice_send(0, 5, send)
	iop.spu_voice_on(0, 5, key(EFFECT))
	return mix(0x4000)
}

// Whether anything is heard after the voice's 28 samples: the reverb.
tail :: proc(out: []i32) -> bool {
	for x in out[64:] {if x != 0 {return true}}
	return false
}

effects :: proc() {
	block(EFFECT, 1, 3)
	dry := effect_play(true)
	check(!tail(dry), "no reverb before effects are set")
	iop.spu_effect(0, 0x105, 0x500, 0x500) // hall, cleared
	check(!tail(effect_play(true)), "no reverb with a mode but effects disabled")
	iop.spu_effect_enable(0, true)
	check(!iop.spu_effect(0, 10, 0, 0) && !iop.spu_effect(0, 0x205, 0, 0) && !iop.spu_effect(2, 5, 0, 0), "bad effect mode or core refused")
	check(tail(effect_play(true)), "hall reverb heard after the voice ends")
	iop.spu_effect(0, 0x105, 0x500, 0x500)
	check(!tail(effect_play(false)), "a voice out of the send gets no reverb")
	iop.spu_effect(0, 0x100, 0, 0)
	off := effect_play(true)
	check(len(off) == len(dry), "mode 0 mixes as many samples")
	for x, i in off {
		if x != dry[i] {
			check(false, "mode 0 mixes as with effects disabled")
			break
		}
	}
	iop.spu_effect_enable(0, false)
}

game :: proc(_: rawptr) {
	voices()
	wide()
	master()
	reverb_presets()
	reverb_fmod()
	effects()
	for n in 0 ..< BLOCKS {
		b: [16]u8
		b[0] = u8(n) << 4 // filters 0..2
		b[1] = n == 0 ? 4 : (n == BLOCKS - 1 ? 3 : 0)
		for &x, k in b[2:] {x = u8(k * 37 + n * 11)}
		iop.spu_write(SNAP + u32(n) * 16, b[:])
	}
	iop.spu_voice_on(0, 7, key(SNAP))
	core.snap_op, core.snap_target = .Save, &snap
	core.snap_yield()
	// Here after the save, and again after the load.
	iop.spu_mix(mixed[1 if loaded else 0][:])
	if !loaded {
		zero: [BLOCKS * 16]u8
		iop.spu_write(SNAP, zero[:])
		iop.spu_voice_off(0, 7)
		loaded = true
		core.snap_op, core.snap_target = .Load, &snap
		core.snap_yield()
	}
	heard := false
	for s in mixed[0] {if s != 0 {heard = true}}
	check(heard, "snapshot voice heard")
	check(mixed[0] == mixed[1], "sound RAM and voice restored by the snapshot")
	if failed {os.exit(1)}
	fmt.println("ok spu")
	os.exit(0)
}

main :: proc() {
	core.snap_init(1 << 20)
	iop.spu_snap()
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	core.snap_run(core.co_create(game, nil))
}
