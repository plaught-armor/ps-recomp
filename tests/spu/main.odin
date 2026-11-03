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
// CRI ADX streams, driven through the driver's RPC and DTX packets, play
// through core 1: its master volume scales them and its one saturate takes
// them with its voices; core 0's master leaves them alone.
// sdrdrv's block transfer keeps time: its status address moves with EE
// cycles, wraps a looping buffer, stops a one-shot one at its end, and a
// stop answers where it was and resumes from there.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import r3000 "ps:psx/cpu"

LOOP :: 0x1000 // start, plain, end with repeat
ONCE :: 0x2000 // plain, end without repeat
SHORT :: 0x3000 // one block, end without repeat
EFFECT :: 0x4000 // one block, end without repeat
WIDE :: 0x5000 // one block looping on itself
ENV :: 0x6000 // one block looping on itself
INTERP :: 0x7000 // one block of varied samples looping on itself
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

// CRI ADX: a chunk of constant PCM in IOP memory, the two DTX work buffers
// on each side, and the EE's DMA list after its work buffers.
ADX_PCM :: 0x10000
ADX_SAMPLES :: 4096
ADX_LEVEL :: 10000
ADX_IOP_WORK :: 0x20000
ADX_EE_WORK :: 0x100000
ADX_WORK_SIZE :: 0x800

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

// The IRQ at power on (spu_snap, as PCSX2's V_Core::Init): IRQA at byte
// 0x1000, 0x800 halfwords, in the output area, and every voice stopped at
// 0x5000, none keyed. Enabled there, no voice raises it, but the output
// write at IRQA does within 0x200 samples, as PCSX2 means it to; enabled at
// IRQA 0, where the voices rested before, nothing raises it.
reset_irq :: proc() {
	irqa, _ := iop.sd_get_addr_extra(0x1f00)
	check(irqa == 0x1000, "reset: IRQA 0x800 halfwords, byte 0x1000")
	iop.sd_core_attr(0x4, 1)
	mix(0x200)
	check(iop.iop_sd.pending == 0, "reset: IRQ enabled, nothing keyed: no voice raises it at the default IRQA")
	now := r3000.state.cycles * iop.IOP_EE_RATIO
	iop.sd_in_cross(now + (0x200 * cpu.EE_CLOCK + iop.MIX_RATE - 1) / iop.MIX_RATE)
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2, "reset: the output write at the default IRQA raises it within 0x200 samples")
	iop.iop_sd.pending = 0
	iop.sd_addr_extra(0x1f00 | 1, 0)
	iop.sd_core_attr(0x4 | 1, 1)
	mix(0x200)
	iop.sd_in_cross(max(u64) - 1)
	check(iop.iop_sd.pending == 0, "reset: IRQ enabled at IRQA 0, nothing keyed: nothing raises it")
	iop.sd_core_attr(0x4 | 1, 0)
	iop.sd_addr_extra(0x1f00 | 1, 0x1000)
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
	check(!st.on && st.endx && st.nax == ONCE, "end without repeat stops, NAX at LSA")
	check(st.envx == 0, "end without repeat zeroes ENVX")
	iop.spu_voice_on(1, 23, key(ONCE))
	st = iop.spu_voice_status(1, 23)
	check(st.on && !st.endx && st.nax == ONCE, "key on clears ENDX")
	iop.spu_voice_off(1, 23)
	mix(4)
	iop.spu_voice_on(0, 23, key(ONCE))
	mix(56)
	check(iop.spu_voice_status(0, 23).endx, "a one-shot on core 0 ends")

	// Ends during a slow attack (rate 0x2c: +7 every sample): the sample in
	// which it stops is silent, the one before heard, and ENVX is 0.
	block(SHORT, 1, 1)
	k := key(SHORT)
	k.adsr1 = 0x2c00 | ADSR1 & 0xff
	iop.spu_voice_on(1, 0, k)
	out = mix(28)
	st = iop.spu_voice_status(1, 0)
	check(!st.on && st.endx && st.envx == 0, "end during attack zeroes ENVX")
	check(iop.spu_voice_status(0, 23).endx, "core 0's end flag kept by core 1's end")
	e0, _ := iop.sd_get_switch(0x1700)
	e1, _ := iop.sd_get_switch(0x1701)
	e1b, _ := iop.sd_get_switch(0x17ff) // LIBSD 1.5 takes the core from bit 0 alone
	check(e0 & (1 << 23) != 0 && e1 & 1 != 0 && e1b == e1, "GetSwitch ENDX: an ended voice's bit, a core each")
	e0b, _ := iop.sd_get_switch(0x1700)
	check(e0b == e0, "GetSwitch ENDX leaves the flags set")
	check(iop.sd_switch_extra(0x1701, 0) && !iop.spu_voice_status(1, 0).endx && iop.spu_voice_status(0, 23).endx, "SetSwitch ENDX clears the core's end flags, whatever the value, not the other's")
	e1, _ = iop.sd_get_switch(0x1701)
	e0b, _ = iop.sd_get_switch(0x1700)
	check(e1 == 0 && e0b == e0, "GetSwitch ENDX after it: the core's 0, the other's kept")
	check(out[52] > 0 && out[54] == 0, "a one-shot's sample before its end heard, the end's silent")

	edge: [8]u8
	check(iop.spu_write(iop.SPU_RAM_SIZE - 4, edge[:]) == 4, "spu_write clipped at the end of sound RAM")
}

// The envelope steps and the sample takes its new level in the same sample,
// as PCSX2's MixVoice applies V_ADSR::Calculate's value. Every sample of ENV
// is 7 << 12 = 28672; the gauss weights at phase 0 (GAUSS[0], [0x100],
// [0x1ff], [0xff]) are -1, 0x1307, 0x59b3, 0x12c7, so from the zeros before
// key on the samples are 28672 * -1 >> 15 = -1, then 28672 * 0x1307 >> 15
// = 4262 plus that -1, 4261, then 28672 * 0x59b3 >> 15 = 20092 more, 24353,
// then 28672 * 0x12c7 >> 15 = 4206 more, 28559 steady: each product is
// shifted before the sum, as PCSX2's GetVoiceValues does (one shift of the
// sum gives 28560). Each is times the level >> 15, then times VOLL's 0x7ffe
// >> 15: 28559 at 0x7fff gives 28558, then 28556; at 0x3fff 14278, then
// 14277.
envelope :: proc() {
	block(ENV, 7, 7)
	// Attack at rate 0, +0x3800 a sample: 0x3800, 0x7000, 0x7fff. The first
	// sample takes 0x3800, not 0.
	iop.spu_voice_on(0, 1, key(ENV))
	out := mix(3)
	check(out[0] == -1 && out[2] == 3727 && out[4] == 24350, fmt.tprintf("the first attack samples take the stepped level: %d %d %d", out[0], out[2], out[4]))
	// Release at rate 0, -0x4000 a sample from 0x7fff: the first sample
	// takes 0x3fff (28559 * 0x3fff >> 15 = 14278, 14277 at VOLL), the
	// second 0 and the voice stops, one sample sooner than the level
	// before the step gives.
	mix(25)
	iop.spu_voice_off(0, 1)
	out = mix(1)
	check(out[0] == 14277 && iop.spu_voice_status(0, 1).on, fmt.tprintf("release: the first sample takes 0x3fff: %d", out[0]))
	out = mix(1)
	st := iop.spu_voice_status(0, 1)
	check(out[0] == 0 && !st.on && st.envx == 0, "release: the second is silent, the voice stopped")
	// A sustain decreasing at rate 0 (ADSR2 0x4000): attack to 0x7fff over
	// samples 0-2, decay (target 0x8000) to sustain in sample 3, its counter
	// at 0x800, then 0x3fff in sample 4 and 0 in sample 5, which stops the
	// voice as PCSX2's sustain at 0 does, ENDX untouched.
	k := key(ENV)
	k.adsr2 = 0x4000
	iop.spu_voice_on(0, 1, k)
	out = mix(6)
	st = iop.spu_voice_status(0, 1)
	check(out[6] == 28556 && out[8] == 14277 && out[10] == 0, fmt.tprintf("sustain decreases to 0: %d %d %d", out[6], out[8], out[10]))
	check(!st.on && !st.endx && st.envx == 0, "sustain at 0 stops the voice, ENDX clear")
	// Key off leaves a stopped voice stopped (PCSX2 keeps PHASE_STOPPED):
	// no release, nothing heard.
	iop.spu_voice_off(0, 1)
	check(!iop.spu_voice_status(0, 1).on, "key off on a stopped voice leaves it stopped")
	// Stopped, it runs on through its blocks silent: at the end of its block
	// (sample 28) ENDX sets and NAX stays at LSA.
	out = mix(23)
	silent := true
	for x in out {silent &&= x == 0}
	st = iop.spu_voice_status(0, 1)
	check(silent && !st.on && st.endx && st.nax == ENV, "a stopped voice runs on to its end block, silent, ENDX set")
	iop.spu_voice_set(0, 1, 0, 0x3fff, 0x3fff)
}

// The gaussian interpolation shifts each of its four products down before
// it sums them, so each rounds toward minus infinity on its own (PCSX2's
// GetVoiceValues, psx-spx). INTERP's samples, filter 0 and shift 0, are its
// nibbles << 12: 4096, 28672, -28672, 12288, -4096, 8192, -32768, ...; at
// pitch 0x800 a sample sits at position 0 then 0x80 between the same four.
// Sample 6, position 0, takes 4096, 28672, -28672, 12288: 4096 * 0x12c7 >>
// 15 = 600, 28672 * 0x59b3 >> 15 = 20092, -28672 * 0x1307 >> 15 = -4263,
// 12288 * -1 >> 15 = -1, 16428 (one shift of the sum: 16431). Sample 7,
// position 0x80, the same four at 0x19c, 0x3def, 0x3e4c, 0x1a8: 51, 13873,
// -13955, 159, 128 (one shift: 129). Sample 12, position 0, 12288, -4096,
// 8192, -32768: 1802, -2871, 1217, 1, 149 (one shift: 151). Each is then
// times level 0x7fff >> 15 and VOLL's 0x7ffe >> 15: 16425, 126, 147.
interp :: proc() {
	b: [16]u8
	b[1] = 7
	nibs := [14]u8{1, 7, 9, 3, 15, 2, 8, 5, 12, 6, 4, 14, 0, 11}
	for k in 0 ..< 14 {b[2 + k] = nibs[k % 7 * 2] | nibs[k % 7 * 2 + 1] << 4}
	check(iop.spu_write(INTERP, b[:]) == 16, "spu_write block")
	k := key(INTERP)
	k.pitch = 0x800
	iop.spu_voice_on(0, 1, k)
	out := mix(13)
	check(out[12] == 16425 && out[14] == 126 && out[24] == 147, fmt.tprintf("gauss rounds each product: %d %d %d", out[12], out[14], out[24]))
	iop.spu_voice_off(0, 1)
	mix(4)
	iop.spu_voice_set(0, 1, 0, 0x3fff, 0x3fff)
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
	check(out[54] > 32767, "silent FMOD leaves the host sum")

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

// A loud voice's output with no master volume set: 28559 at level 0x7fff
// and VOLL 0x7ffe (envelope).
PRE_MASTER :: 28556

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
	// A core's parameter sent through sdrdrv (sceSdSetParam, 0x8010) lands
	// as libsd's does: MVOLL of core 1.
	sdr_call(0x8010, 0x0901, 0x2000)
	out = mix(28)
	check(out[54] == i32(i64(full) * 0x2000 >> 14), "MVOLL sent through sdrdrv scales the output")

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

// Call CRI ADX's RPC function fno: the reply's first word.
adx_call :: proc(fno: u32, args: ..u32) -> u32 {
	buf: [64]u8
	w := ([^]u32)(&buf)
	for a, i in args {w[i] = a}
	iop.sif.servers[0x90000200](fno, buf[:], u32(len(args) * 4))
	return w[0]
}

// DMA DTX `id` a packet of entries from its EE work buffer.
adx_packet :: proc(id: u32, entries: ..[4]u32) {
	ee := ADX_EE_WORK + id * ADX_WORK_SIZE
	mem.wr32(ee, u32(len(entries)))
	for e, n in entries {
		for x, k in e {mem.wr32(ee + 16 + u32(n * 16 + k * 4), x)}
	}
	list := u32(ADX_EE_WORK + 2 * ADX_WORK_SIZE)
	mem.wr32(list, ee)
	mem.wr32(list + 4, ADX_IOP_WORK + id * ADX_WORK_SIZE)
	mem.wr32(list + 8, ADX_WORK_SIZE)
	iop.sif_set_dma(list, 1, 0)
}

// Play the chunk from its start, through a round trip a second after the
// stream starts: its first vblank, mixed. Each run interpolates at the same
// phases, so runs compare sample by sample.
adx_run :: proc(rna, sjx: u32) -> []i32 {
	adx_packet(0) // hands back what the last run held
	adx_packet(1, {2, rna, 1, 0})
	adx_packet(0, {0, sjx, ADX_PCM, ADX_SAMPLES * 2})
	cpu.state.cycles += cpu.EE_CLOCK
	adx_packet(0)
	out := mix(800)
	adx_packet(1, {2, rna, 0, 0})
	return out
}

// out is the stream of `inv`, a run at master 0x4000 (an exact inversion),
// scaled by l and r.
scaled :: proc(out, inv: []i32, l, r: i64) -> bool {
	for x, i in out {
		if i64(x) != -i64(inv[i]) * (i & 1 == 0 ? l : r) >> 14 {return false}
	}
	return true
}

adx :: proc() {
	for n in 0 ..< ADX_SAMPLES {
		iop.iop_ram[ADX_PCM + n * 2] = u8(ADX_LEVEL & 0xff)
		iop.iop_ram[ADX_PCM + n * 2 + 1] = u8(ADX_LEVEL >> 8)
	}
	for id in u32(0) ..< 2 {
		adx_call(2, id, ADX_EE_WORK + id * ADX_WORK_SIZE, ADX_IOP_WORK + id * ADX_WORK_SIZE, ADX_WORK_SIZE)
	}
	sjx := adx_call(0x400, 0, 0x111, 0, 0) // fed by IOP stream joint 0x111
	rna := adx_call(0x408, 1, 0, 0x111) // one channel, played on both sides
	adx_packet(1, {4, rna, 48000, 0})

	iop.spu_master(1, 0x4000, 0x4000)
	inv := adx_run(rna, sjx) // a new stream: centred, 180 a side
	heard := true
	for x in inv {if x > -ADX_LEVEL * 180 / 256 * 9 / 10 {heard = false}}
	check(heard, "ADX heard through core 1's master")
	iop.spu_master(0, 0x2000, 0x2000)
	check(scaled(adx_run(rna, sjx), inv, -0x4000, -0x4000), "core 0's master leaves ADX alone") // still inverted
	iop.spu_master(1, 0x2ccc, 0x1000)
	check(scaled(adx_run(rna, sjx), inv, 0x2ccc, 0x1000), "core 1's master scales ADX exactly")
	adx_levels(rna, sjx, inv)

	// With a loud voice of core 1, the core saturates the sum once.
	iop.spu_master(1, 0x3fff, 0x3fff)
	iop.spu_voice_on(1, 10, key(WIDE))
	out := adx_run(rna, sjx)
	check(out[1500] == 32767 && out[1501] == 32767, "core 1 saturates its voices and ADX together")
	iop.spu_voice_off(1, 10)
	mix(4)
	silent := true
	for x in mix(4) {if x != 0 {silent = false}}
	check(silent, "a stopped stream is silent")
}

// out is the stream of `ref`, a run at unity on the left and silent on the
// right through master 0x4000, at gains l and r as the driver's mixer plays
// them.
gained :: proc(out, ref: []i32, l, r: i32) -> bool {
	at :: proc(x, g: i32) -> i32 {return g == 255 ? x : x * g >> 8}
	for k := 0; k < len(out); k += 2 {
		x := -ref[k]
		if out[k] != -at(x, l) || out[k + 1] != -at(x, r) {return false}
	}
	return true
}

// PS2RNA volume (5, {RNA, 0, volume}) and pan (9, {RNA, channel, pan}) on
// the one channel of `rna`; `centre` is its run as created.
adx_levels :: proc(rna, sjx: u32, centre: []i32) {
	iop.spu_master(1, 0x4000, 0x4000)
	adx_packet(1, {9, rna, 0, transmute(u32)i32(-15)})
	ref := adx_run(rna, sjx)
	unity := true
	for k := 0; k < len(ref); k += 2 {
		if ref[k] > -ADX_LEVEL * 9 / 10 || ref[k + 1] != 0 {unity = false}
	}
	check(unity, "a channel panned left plays at unity on the left only")
	check(gained(centre, ref, 180, 180), "a new stream plays at full volume, centred")
	adx_packet(1, {5, rna, 0, 103})
	check(gained(adx_run(rna, sjx), ref, 103, 0), "volume scales a channel by volume / 256")
	adx_packet(1, {5, rna, 0, 200}, {9, rna, 0, 5})
	check(gained(adx_run(rna, sjx), ref, 100, 173), "a pan between the sides takes the sine curve, rounded")
	adx_packet(1, {9, rna, 1, 15})
	check(gained(adx_run(rna, sjx), ref, 100, 173), "a pan of a channel the stream lacks is ignored")
	adx_packet(1, {5, rna, 0, 300}, {9, rna, 0, 40})
	check(gained(adx_run(rna, sjx), ref, 0, 255), "volume and pan clamp to their ranges")
	adx_packet(1, {5, rna, 0, transmute(u32)i32(-5)})
	check(gained(adx_run(rna, sjx), ref, 0, 0), "a negative volume clamps to silent")
	adx_packet(1, {8, rna, 1, 0})
	check(core.compat.calls[{.Iop_Adx, 8, 0}].n == 1, "a command the HLE does not serve is a row")
	adx_packet(1, {5, rna, 0, 255}, {9, rna, 0, 0})

	// A stereo stream whose right channel has no SJX: its left plays once.
	half := adx_call(0x408, 2, 0, 0x111, 0x222)
	adx_packet(1, {4, half, 48000, 0})
	check(gained(adx_run(half, sjx), ref, 180, 180), "a stereo stream missing a side plays the other once, centred")
	adx_call(0x409, half)
}

// Call sdrdrv's RPC function fno: the reply's first word. The EE side sends
// the function code, then its arguments.
sdr_call :: proc(fno: u32, args: ..u32) -> u32 {
	buf: [64]u8
	w := ([^]u32)(&buf)
	w[0] = fno
	for a, i in args {w[i + 1] = a}
	iop.sif.servers[0x80000701](fno, buf[:], u32(len(args) * 4 + 4))
	return w[0]
}

BLOCK_BASE :: 0x30000
BLOCK_SIZE :: 0x4000

block_trans :: proc() {
	SECOND :: u64(cpu.EE_CLOCK)
	sdr_call(0x80e0, 1, 0x13, BLOCK_BASE, BLOCK_SIZE, BLOCK_BASE + 0x400) // loop, from 0x400
	check(sdr_call(0x8100, 1, 0) == BLOCK_BASE + 0x400, "a block transfer starts where it is told")
	cpu.state.cycles += SECOND / 100 // 1920 bytes
	check(sdr_call(0x8100, 1, 0) == BLOCK_BASE + 0x400 + 1920, "a block transfer moves at 48 kHz, 4 bytes a sample")
	check(sdr_call(0x8100, 0, 0) == 0, "the other channel stays still")
	cpu.state.cycles += SECOND / 10 // 19200 more
	check(sdr_call(0x8100, 1, 0) == BLOCK_BASE + (0x400 + 1920 + 19200) % BLOCK_SIZE, "a looping block transfer wraps")
	at := sdr_call(0x80e0, 1, 2)
	check(at == BLOCK_BASE + (0x400 + 1920 + 19200) % BLOCK_SIZE, "a stop answers where it was")
	cpu.state.cycles += SECOND
	check(sdr_call(0x8100, 1, 0) == at, "a stopped block transfer stays still")
	sdr_call(0x80e0, 1, 0x03, BLOCK_BASE, BLOCK_SIZE, at) // one-shot, from there
	cpu.state.cycles += SECOND
	check(sdr_call(0x8100, 1, 0) == BLOCK_BASE + BLOCK_SIZE, "a one-shot block transfer stops at its end")
	sdr_call(0x80e0, 1, 2)
}

game :: proc(_: rawptr) {
	reset_irq()
	voices()
	envelope()
	interp()
	wide()
	master()
	reverb_presets()
	reverb_fmod()
	effects()
	adx()
	block_trans()
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
	mem.mem_init()
	iop.sif_init()
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	core.snap_run(core.co_create(game, nil))
}
