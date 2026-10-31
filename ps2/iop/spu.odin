// SPU2 voices behind sdrdrv, Sony's libsd RPC server (libsdr on the EE).
//
// The game drives raw voices through it only for movie sound: two voices of
// core 0 play stereo SPU ADPCM from looping rings in sound RAM, which the
// game refills by polling each voice's playback address (NAX). So this
// models what that needs: sound RAM, voice transfers, ADPCM playback with
// the block loop flags, pitch (gaussian interpolated, gauss.odin), volume
// key on/off and the ADSR envelope (stepping after ps2-web-recomp's
// spu2.cpp, MIT, Samir Nuri). Volume sweeps are taken at full scale.
//
// Voices advance by the samples spu_mix renders, the same clock the FMOD
// voices run on. A block transfer (a PCM stream into a core) only keeps the
// time: the game polls where it reads to refill its ring, and that address
// moves with EE time.
//
// A port whose sound driver is its own HLE code, not sdrdrv, drives the same
// voices through spu_write, spu_voice_on, spu_voice_set, spu_voice_off and
// spu_voice_status, each core's reverb through spu_effect,
// spu_effect_enable and spu_voice_send (reverb.odin), and each core's master
// volume through spu_master. sdrdrv's effect and master volume calls are not
// handled: its cores stay dry, at full volume.
package ps2_iop

import "core:fmt"
import "core:mem"
import "ps:core"
import cpu "../cpu"

SPU_RAM_SIZE :: 2 << 20

@(private = "file")
Spu_Phase :: enum u8 {Attack, Decay, Sustain, Release}

@(private = "file")
Spu_Voice :: struct {
	on:         bool,
	phase:      Spu_Phase,
	adsr1:      u32,
	adsr2:      u32,
	level:      i32, // envelope, 0..0x7fff
	counter:    i32, // samples since its last step
	ssa, lsa:   u32, // byte addresses in sound RAM
	nax:        u32, // the block playing
	endx:       bool, // a block with the end flag has finished since key on
	flags:      u8, // its loop flags
	pcm:        [28]i16, // its samples
	idx:        u32, // the sample playing in it
	frac:       u32, // 4.12, as PITCH
	last:       [3]i32, // the samples before idx, oldest first, for interpolation
	hist:       [2]i32, // ADPCM predictor history
	pitch:      u32,
	voll, volr: i32,
	dry:        bool, // out of the effect send (VMIXEL/VMIXER), which libsd's init opens to every voice
}

@(private = "file")
spu: struct {
	ram:   []u8,
	voice:  [2][24]Spu_Voice,
	effect: [2]bool, // the core's effect enable, ATTR bit 7
	reverb: [2]Reverb, // its work area is here, not in sound RAM at ESA .. EEA
	// MVOLL, MVOLR as spu_volume gives them, or 0x4000 until set: an exact
	// unity (x * 0x4000 >> 14 == x) that spu_volume never returns, where its
	// 0x3fff loses a step on loud samples.
	master: [2][2]i32,
	block:  [2]Sdr_Block, // sdrdrv's block transfers, per channel
}

// A block transfer (sceSdBlockTrans) as a clock only: its samples are not
// played. It reads its buffer from `start` on, at a modelled 48 kHz of
// 16-bit stereo (4 bytes a sample), unverified against retail; a looping
// one wraps to `base`, a one-shot one stops at its end.
@(private = "file")
Sdr_Block :: struct {
	base, size: u32, // its buffer, IOP addresses
	start:      u32, // the offset it started at
	cycles:     u64, // the EE cycle it started at
	loop:       bool,
	on:         bool,
}

// sceSdBlockTrans mode bits, from what the EE side sends: 2 stops, 3
// starts at the address after the size; SD_BLOCK_LOOP repeats the buffer.
@(private = "file")
SD_TRANS_STOP :: 2
@(private = "file")
SD_TRANS_START_AT :: 3
@(private = "file")
SD_BLOCK_LOOP :: 0x10
@(private = "file")
SD_BLOCK_RATE :: 48000 * 4

// Where block transfer b reads now: an IOP address.
@(private = "file")
sdr_block_pos :: proc(b: ^Sdr_Block) -> u32 {
	if !b.on || b.size == 0 {return b.base + b.start}
	moved := (cpu.state.cycles - b.cycles) * SD_BLOCK_RATE / cpu.EE_CLOCK
	off := u64(b.start) + moved
	off = b.loop ? off % u64(b.size) : min(off, u64(b.size))
	return b.base + u32(off)
}

// libsd parameter and address ids; the low bits name core and voice.
@(private = "file")
SD_VP_VOLL :: 0x0000
@(private = "file")
SD_VP_VOLR :: 0x0100
@(private = "file")
SD_VP_PITCH :: 0x0200
@(private = "file")
SD_VP_ADSR1 :: 0x0300
@(private = "file")
SD_VP_ADSR2 :: 0x0400
@(private = "file")
SD_S_KON :: 0x1500
@(private = "file")
SD_S_KOFF :: 0x1600
@(private = "file")
SD_VA_SSA :: 0x2040
@(private = "file")
SD_VA_LSAX :: 0x2140
@(private = "file")
SD_VA_NAX :: 0x2240

@(private = "file")
spu_voice :: proc(id: u32) -> ^Spu_Voice {
	return &spu.voice[id & 1][min((id >> 1) & 31, 23)]
}

// Decode the block at v.nax, taking its loop start flag.
@(private = "file")
spu_block :: proc(v: ^Spu_Voice) {
	F := [5][2]i32{{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}}
	b := spu.ram[v.nax & (SPU_RAM_SIZE - 16):][:16]
	shift := u32(b[0] & 15)
	f := min(int(b[0] >> 4), 4)
	v.flags = b[1]
	if v.flags & 4 != 0 {v.lsa = v.nax}
	for n in 0 ..< 28 {
		nib := (b[2 + n / 2] >> (u32(n & 1) * 4)) & 15
		s := i32(i16(u16(nib) << 12)) >> shift
		s += (v.hist[0] * F[f][0] + v.hist[1] * F[f][1] + 32) >> 6
		s = clamp(s, -32768, 32767)
		v.hist[1], v.hist[0] = v.hist[0], s
		v.pcm[n] = i16(s)
	}
}

@(private = "file")
spu_start :: proc(v: ^Spu_Voice) {
	v.on, v.endx = true, false
	v.phase, v.level, v.counter = .Attack, 0, 0
	v.nax, v.lsa = v.ssa, v.ssa
	v.idx, v.frac, v.last, v.hist = 0, 0, {}, {}
	spu_block(v)
}

// Step the envelope one sample at `rate` (7 bits: shift in the high 5,
// step in the low 2).
@(private = "file")
spu_env_step :: proc(v: ^Spu_Voice, rate: u32, decrease, exponential: bool) {
	shift := i32(rate >> 2)
	cycles := i32(1) << u32(max(0, shift - 11))
	if exponential && !decrease && v.level > 0x6000 {cycles *= 4}
	v.counter += 1
	if v.counter < cycles {return}
	v.counter = 0
	step := i32(rate & 3)
	delta := (decrease ? -8 + step : 7 - step) << u32(max(0, 11 - shift))
	if exponential && decrease {delta = delta * v.level / 0x8000}
	v.level = clamp(v.level + delta, 0, 0x7fff)
}

// Advance the envelope one sample; a release that reaches zero stops the voice.
@(private = "file")
spu_envelope :: proc(v: ^Spu_Voice) {
	switch v.phase {
	case .Attack:
		spu_env_step(v, (v.adsr1 >> 8) & 0x7f, false, v.adsr1 & 0x8000 != 0)
		if v.level >= 0x7fff {v.phase = .Decay}
	case .Decay:
		spu_env_step(v, ((v.adsr1 >> 4) & 15) << 2, true, true)
		if v.level <= i32((v.adsr1 & 15) + 1) * 0x800 {v.phase = .Sustain}
	case .Sustain:
		spu_env_step(v, (v.adsr2 >> 6) & 0x7f, v.adsr2 & 0x4000 != 0, v.adsr2 & 0x8000 != 0)
	case .Release:
		spu_env_step(v, (v.adsr2 & 31) << 2, true, v.adsr2 & 0x20 != 0)
		if v.level == 0 {v.on = false}
	}
}

// One sample of a playing voice, then advance it by its pitch.
@(private = "file")
spu_sample :: proc(v: ^Spu_Voice) -> i32 {
	s := gauss(v.last[0], v.last[1], v.last[2], i32(v.pcm[v.idx]), v.frac >> 4)
	v.frac += v.pitch
	for v.frac >= 0x1000 && v.on {
		v.frac -= 0x1000
		v.last = {v.last[1], v.last[2], i32(v.pcm[v.idx])}
		v.idx += 1
		if v.idx < 28 {continue}
		v.idx = 0
		if v.flags & 1 != 0 {v.endx = true}
		switch {
		case v.flags & 1 == 0: v.nax += 16
		case v.flags & 2 != 0: v.nax = v.lsa
		case: // end without repeat: the voice stops, its envelope at 0
			v.on, v.level = false, 0
			return s
		}
		spu_block(v)
	}
	return s
}

// Add the voices to interleaved stereo at MIX_RATE, the SPU2 output rate.
// Each core sums its voices and reverb return wide and saturates once, at its
// output, so voices that cancel do not clip on the way. Core 1's sum takes
// CRI ADX's streams too (adx_mix).
spu_mix :: proc(out: []i32) {
	acc := make([]i32, len(out), context.temp_allocator)
	for &core, c in spu.voice {
		mem.zero_slice(acc)
		// A core runs its reverb only with effects enabled and a mode set.
		w := &spu.reverb[c]
		wet := spu.effect[c] && w.mode != 0
		send: []i32
		if wet {send = make([]i32, len(out), context.temp_allocator)}
		for &v in core {
			if !v.on {continue}
			for n := 0; n < len(out); n += 2 {
				if !v.on {break}
				// The level before the sample: an end without repeat zeroes it.
				level := v.level
				s := spu_sample(&v) * level >> 15
				if v.on {spu_envelope(&v)}
				sl, sr := s * v.voll >> 14, s * v.volr >> 14
				acc[n] += sl
				acc[n + 1] += sr
				if wet && !v.dry {
					send[n] += sl
					send[n + 1] += sr
				}
			}
		}
		if wet {reverb_mix(w, send, acc)}
		if c == ADX_CORE {adx_mix(acc)}
		// The master volume scales the core's whole output, reverb included
		// (an assumption from PCSX2 practice, not checked on hardware); 24
		// loud voices times a volume overflow 32 bits.
		m := spu.master[c]
		for x, i in acc {out[i] += i32(clamp(i64(x) * i64(m[i & 1]) >> 14, -32768, 32767))}
	}
}

// A volume register (VOLL, VOLR, MVOLL, MVOLR share one format): with bit
// 15 clear, bits 14-0 are a signed level, half the gain, so 0x3fff is unity
// and 0x4000 (-0x4000) inverts; with bit 15 set the level sweeps, and sweeps
// are taken at full scale.
@(private = "file")
spu_volume :: proc(r: u32) -> i32 {
	if r & 0x8000 != 0 {return 0x3fff}
	return i32(i16(u16(r << 1))) >> 1
}

// A PITCH register value: 4.12, 0x1000 plays at 48 kHz.
@(private = "file")
spu_pitch :: proc(r: u32) -> u32 {
	return min(r & 0xffff, 0x3fff)
}

// Voice `voice` (0..23) of core `core` (0 or 1).
@(private = "file")
spu_voice_at :: proc(core, voice: int) -> ^Spu_Voice {
	assert(core >= 0 && core < 2 && voice >= 0 && voice < 24, "spu: no such voice")
	return &spu.voice[core][voice]
}

// Copy data into sound RAM at byte address addr, clipped at its end.
// Returns the bytes copied.
spu_write :: proc(addr: u32, data: []u8) -> u32 {
	dst := addr & (SPU_RAM_SIZE - 1)
	return u32(copy(spu.ram[dst:], data))
}

// What a voice is keyed on with, as register values: pitch 4.12 (0x1000 is
// 48 kHz), volumes as VOLL and VOLR (spu_volume), envelope as ADSR1 and
// ADSR2. ssa is a byte address in sound RAM; the loop comes from the
// blocks' flags.
Spu_Key :: struct {
	ssa, pitch, voll, volr, adsr1, adsr2: u32,
}

// Set a voice up from k and key it on, as SSA, the parameters and KON.
spu_voice_on :: proc(core, voice: int, k: Spu_Key) {
	v := spu_voice_at(core, voice)
	v.ssa = k.ssa & (SPU_RAM_SIZE - 16)
	v.pitch = spu_pitch(k.pitch)
	v.voll, v.volr = spu_volume(k.voll), spu_volume(k.volr)
	v.adsr1, v.adsr2 = k.adsr1 & 0xffff, k.adsr2 & 0xffff
	spu_start(v)
}

// Change the pitch and volumes of a voice, playing or not.
spu_voice_set :: proc(core, voice: int, pitch, voll, volr: u32) {
	v := spu_voice_at(core, voice)
	v.pitch = spu_pitch(pitch)
	v.voll, v.volr = spu_volume(voll), spu_volume(volr)
}

// Put a voice in or out of its core's effect send, as its VMIXEL and VMIXER
// bits.
spu_voice_send :: proc(core, voice: int, on: bool) {
	spu_voice_at(core, voice).dry = !on
}

// Set a core's effect as libsd's sceSdSetEffectAttr: mode 0 (off) .. 9 the
// reverb.odin presets, with 0x100 to clear the work area; depth_l and
// depth_r are the return volume (EVOLL, EVOLR). Delay and feedback, which
// only echo and delay take, are not applied. As libsd, any other mode bits
// are an error: nothing changes and it returns false, as for a bad core.
spu_effect :: proc(core: int, mode: u32, depth_l, depth_r: i16) -> bool {
	m := mode &~ 0x100
	if core < 0 || core > 1 || m > 9 {return false}
	reverb_set(&spu.reverb[core], m, i32(depth_l), i32(depth_r), mode & 0x100 != 0)
	return true
}

// Set a core's master volume, as MVOLL and MVOLR register values
// (spu_volume). It scales the core's output, voices and reverb, before it
// saturates. Until set it is an exact unity, which keeps the output of
// ports that never set it.
spu_master :: proc(core: int, l, r: u32) {
	assert(core >= 0 && core < 2, "spu: no such core")
	spu.master[core] = {spu_volume(l), spu_volume(r)}
}

// Turn a core's effects on or off, as SD_C_EFFECT_ENABLE (ATTR bit 7).
spu_effect_enable :: proc(core: int, on: bool) {
	assert(core >= 0 && core < 2, "spu: no such core")
	spu.effect[core] = on
}

// Key a voice off, as KOFF: its envelope goes to release.
spu_voice_off :: proc(core, voice: int) {
	spu_voice_at(core, voice).phase = .Release
}

Spu_Status :: struct {
	on:   bool, // playing (a release that reaches zero or an end without repeat stops it)
	endx: bool, // ENDX: a block with the end flag has finished since key on
	envx: u16, // ENVX: the envelope level, 0..0x7fff
	nax:  u32, // NAX: the block playing, a byte address
	lsax: u32, // LSAX: the loop start, a byte address
}

spu_voice_status :: proc(core, voice: int) -> Spu_Status {
	v := spu_voice_at(core, voice)
	return {on = v.on, endx = v.endx, envx = u16(v.level), nax = v.nax, lsax = v.lsa}
}

// libsd's calls on the voices, as both of its front ends take them: sdrdrv
// over RPC (sdr_server) and libsd as an IOP module imports it (libsd.odin).
// The id names core and voice in its low bits. Those that return a bool say
// whether they decoded the id; one they do not changes nothing.

// sceSdInit: every voice off and cleared.
sd_init :: proc() {
	for &core in spu.voice {for &v in core {v = {}}}
}

// sceSdSetParam(id, value) for a voice's VOLL, VOLR, PITCH, ADSR1, ADSR2.
sd_set_param :: proc(id, value: u32) -> bool {
	v := spu_voice(id)
	switch id & 0xff00 {
	case SD_VP_VOLL: v.voll = spu_volume(value)
	case SD_VP_VOLR: v.volr = spu_volume(value)
	case SD_VP_PITCH: v.pitch = spu_pitch(value)
	case SD_VP_ADSR1: v.adsr1 = value & 0xffff
	case SD_VP_ADSR2: v.adsr2 = value & 0xffff
	case: return false
	}
	return true
}

// sceSdSetSwitch(id, voice mask) for KON and KOFF.
sd_set_switch :: proc(id, mask: u32) -> bool {
	switch id & 0xff00 {
	case SD_S_KON, SD_S_KOFF:
	case: return false
	}
	core := &spu.voice[id & 1]
	for i in 0 ..< 24 {
		if mask & (1 << u32(i)) == 0 {continue}
		switch id & 0xff00 {
		case SD_S_KON: spu_start(&core[i])
		case SD_S_KOFF: core[i].phase = .Release
		}
	}
	return true
}

// sceSdSetAddr(id, address) for a voice's SSA and LSAX.
sd_set_addr :: proc(id, addr: u32) -> bool {
	v := spu_voice(id)
	switch id & 0xff00 {
	case SD_VA_SSA & 0xff00: v.ssa = addr & (SPU_RAM_SIZE - 16)
	case SD_VA_LSAX & 0xff00: v.lsa = addr & (SPU_RAM_SIZE - 16)
	case: return false
	}
	return true
}

// sceSdGetAddr(id) for a voice's SSA, LSAX and NAX.
sd_get_addr :: proc(id: u32) -> (u32, bool) {
	v := spu_voice(id)
	switch id & 0xff00 {
	case SD_VA_SSA & 0xff00: return v.ssa, true
	case SD_VA_LSAX & 0xff00: return v.lsa, true
	case SD_VA_NAX & 0xff00: return v.nax, true
	}
	return 0, false
}

// sceSdVoiceTrans(channel, mode, IOP address, SPU address, size), done at
// once: bit 0 of mode reads sound RAM back. The bytes moved.
sd_voice_trans :: proc(mode, iop_addr, spu_addr, size: u32) -> u32 {
	dst := spu_addr & (SPU_RAM_SIZE - 1)
	src := iop_mem(iop_addr, min(size, SPU_RAM_SIZE - dst))
	if mode & 1 == 0 {return spu_write(dst, src)}
	return u32(copy(src, spu.ram[dst:][:len(src)]))
}

// sceSdBlockTrans(channel, mode, IOP address, size, start address). A stop
// returns where it read; a start returns 0.
sd_block_trans :: proc(channel, mode, addr, size, start: u32) -> u32 {
	b := &spu.block[channel & 1]
	if mode & 3 == SD_TRANS_STOP {
		r := sdr_block_pos(b)
		b.start, b.on = r - b.base, false
		return r
	}
	b^ = {base = addr, size = size, cycles = cpu.state.cycles, loop = mode & SD_BLOCK_LOOP != 0, on = true}
	if mode & 3 == SD_TRANS_START_AT && start - addr < size {b.start = start - addr}
	return 0
}

// sceSdBlockTransStatus(channel, flag): where it reads now, 24 bits.
sd_block_status :: proc(channel: u32) -> u32 {
	return sdr_block_pos(&spu.block[channel & 1]) & 0xffffff
}

// sdrdrv: {?, args...} in, the result in the first word out.
@(private)
sdr_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r: u32 = 0
	switch fno {
	case 0x8000: sd_init()
	case 0x8010: sd_set_param(w[1], w[2])
	case 0x8030: sd_set_switch(w[1], w[2])
	case 0x8050: sd_set_addr(w[1], w[2])
	case 0x8060: r, _ = sd_get_addr(w[1])
	case 0x80d0: r = sd_voice_trans(w[2], w[3], w[4], w[5])
	case 0x80e0: r = sd_block_trans(w[1], w[2], w[3], w[4], w[5])
	case 0x80f0: r = 1 // sceSdVoiceTransStatus {channel, flag}: always complete
	case 0x8100: r = sd_block_status(w[1])
	case:
		if cpu.debug >= 1 {fmt.eprintfln("sdr: unhandled fno %x", fno)}
	}
	for &b in buf[:64] {b = 0}
	w[0] = r
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin). Sound RAM is
// a snapshot area, so it is saved whichever allocator is current when it is
// first written.
spu_snap :: proc() {
	spu.ram = core.snap_area(SPU_RAM_SIZE)
	spu.master = {{0x4000, 0x4000}, {0x4000, 0x4000}}
	core.snap_add(&spu)
}
