// SPU2 voice test: the API a port's own sound driver uses (spu_write,
// spu_voice_on, spu_voice_set, spu_voice_off, spu_voice_status), played by
// spu_mix, and sound RAM through a snapshot.
//
// Voices play SPU ADPCM blocks (16 bytes: shift and filter, loop flags, 28
// samples) at pitch 0x1000, one sample per mixed sample, so a block lasts 28.
// The snapshot part keys a voice on, saves, mixes, scribbles over its
// blocks and loads: mixing again must give the same samples.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"

LOOP :: 0x1000 // start, plain, end with repeat
ONCE :: 0x2000 // plain, end without repeat
SNAP :: 0x10000 // varied samples, end with repeat
BLOCKS :: 3

// Envelope: fastest attack, sustain at full level, fastest linear release.
ADSR1 :: 0x00ff
ADSR2 :: 0x1fc0

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
	iop.spu_voice_on(1, 23, key(ONCE))
	st = iop.spu_voice_status(1, 23)
	check(st.on && !st.endx && st.nax == ONCE, "key on clears ENDX")
	iop.spu_voice_off(1, 23)
	mix(4)

	edge: [8]u8
	check(iop.spu_write(iop.SPU_RAM_SIZE - 4, edge[:]) == 4, "spu_write clipped at the end of sound RAM")
}

game :: proc(_: rawptr) {
	voices()
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
