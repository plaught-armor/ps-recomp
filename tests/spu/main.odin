// SPU2 voice test: the API a port's own sound driver uses (spu_write,
// spu_voice_on, spu_voice_set, spu_voice_off, spu_voice_status), played by
// spu_mix, and sound RAM through a snapshot.
//
// Voices play SPU ADPCM blocks (16 bytes: shift and filter, loop flags, 28
// samples) at pitch 0x1000, one sample per mixed sample, so a block lasts 28.
// The snapshot part keys a voice on, saves, mixes, scribbles over its
// blocks and loads: mixing again must give the same samples.
// The FMOD reverb (reverb_set, reverb_mix) runs each preset over a fixed
// send; a hash of its return pins the output. A core's reverb (spu_effect,
// spu_effect_enable, spu_voice_send) rings on after its voice ends.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"

LOOP :: 0x1000 // start, plain, end with repeat
ONCE :: 0x2000 // plain, end without repeat
SHORT :: 0x3000 // one block, end without repeat
EFFECT :: 0x4000 // one block, end without repeat
SNAP :: 0x10000 // varied samples, end with repeat
BLOCKS :: 3

// Envelope: fastest attack, sustain at full level, fastest linear release.
ADSR1 :: 0x00ff
ADSR2 :: 0x1fc0

// FNV-1a of reverb_mix's return per mode 1 .. 9 for reverb_presets' send.
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
mixed: [2][BLOCKS * 28 * 2]i16 // before and after the load

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
mix :: proc(n: int) -> []i16 {
	out := make([]i16, n * 2, context.temp_allocator)
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

// Every preset over noise bursts (on 1024 frames, off 3072, so tails
// ring out), 0x20000 frames in chunks of 1024: twice the largest work area
// at the half rate.
reverb_presets :: proc() {
	CHUNK :: 1024
	seed: u32 = 1
	send, acc: [CHUNK * 2]i32
	for mode in u32(1) ..= 9 {
		iop.reverb_set(&rev, mode, 0x3fff, 0x3fff, true)
		h: u64 = 0xcbf29ce484222325
		for c in 0 ..< 0x20000 / CHUNK {
			for &x in send {
				seed = seed * 1103515245 + 12345
				x = c % 4 == 0 ? i32(seed >> 16) % 16000 - 8000 : 0
			}
			acc = {}
			iop.reverb_mix(&rev, send[:], acc[:])
			for x in acc {
				for b in 0 ..< u32(4) {h = (h ~ u64(u32(x) >> (b * 8) & 0xff)) * 0x100000001b3}
			}
		}
		if h != REVERB_HASH[mode - 1] {
			fmt.eprintfln("FAIL reverb mode %d: hash %#16x", mode, h)
			failed = true
		}
	}
}

// Play the EFFECT block once on core 0 and mix past its end.
effect_play :: proc(send: bool) -> []i16 {
	iop.spu_voice_send(0, 5, send)
	iop.spu_voice_on(0, 5, key(EFFECT))
	return mix(0x4000)
}

// Whether anything is heard after the voice's 28 samples: the reverb.
tail :: proc(out: []i16) -> bool {
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
	reverb_presets()
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
