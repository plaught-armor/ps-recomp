// SPU2 voices behind sdrdrv, Sony's libsd RPC server (libsdr on the EE).
//
// The game drives raw voices through it only for movie sound: two voices of
// core 0 play stereo SPU ADPCM from looping rings in sound RAM, which the
// game refills by polling each voice's playback address (NAX). So this
// models what that needs: sound RAM, voice transfers, ADPCM playback with
// the block loop flags, pitch (gaussian interpolated, gauss.odin), volume
// key on/off and the ADSR envelope (stepping after ps2-web-recomp's
// spu2.cpp, MIT, Samir Nuri) and the voice volume sweeps (Spu_Vol), both
// counted as PCSX2 counts them (spu_rate_step); a master volume's sweep is
// taken at full scale.
//
// Voices advance by the samples spu_mix renders, the same clock the FMOD
// voices run on, and between its passes by those spu_catch_up renders ahead
// of it at each libsd and sdrdrv call, so a call sees its voices as they are
// at its IOP cycle (an ENVX read just after a key on reads the attack under
// way) and its writes take effect from that sample on. A block transfer (a
// PCM stream into a core) through sdrdrv only keeps the time: the game polls
// where it reads to refill its ring, and that address moves with EE time.
//
// libsd as an IOP module imports it (libsd.odin, PS_IRX=1) takes the same
// voice calls and more: core volumes, effect, IRQA and the cores' IRQ, and
// interrupt handlers. Its block transfers play: 16-bit stereo in the ADMA
// layout, 512 bytes of left then 512 of right in each 1024, read from where
// the transfer is in EE time, dry into its core at its BVOL, as the input
// area it fills would. Each raises its transfer interrupt at every half of
// its buffer. Without one, a core's input area in sound RAM plays dry at its
// BVOL. A core with its IRQ enabled raises it
// when any voice of either core enters the block at its IRQA or is in the
// block starting there, or the input area's read (SPU_IN_BASE) or output
// areas' write (SPU_OUT_BASE) reaches it, which libsd takes by disabling
// it. The layout, the half-buffer interrupt, the input read and the IRQ's
// sources are PCSX2 practice, unverified on hardware.
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
import r3000 "ps:psx/cpu"

SPU_RAM_SIZE :: 2 << 20

@(private = "file")
Spu_Phase :: enum u8 {Stopped, Attack, Decay, Sustain, Release}

@(private = "file")
Spu_Voice :: struct {
	phase:      Spu_Phase, // Stopped: not playing (PCSX2's PHASE_STOPPED)
	adsr1:      u32,
	adsr2:      u32,
	level:      i32, // envelope, 0..0x7fff
	counter:    u32, // toward its next step (spu_rate_step)
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
	vol:        [2]Spu_Vol, // VOLL, VOLR
	dry:        bool, // out of the effect send (VMIXEL/VMIXER), which libsd's init opens to every voice (sd_lib_init)
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
	block:  [2]Sdr_Block, // the block transfers, per channel
	irqa:   [2]u32, // IRQA, a byte address, per core (libsd)
	irq_watch: u8, // the cores with IRQ_ENABLE set, a bit each (libsd)
	// The EE cycle at which the input area's read or the output areas'
	// write reaches IRQA, per core whose bit irq_watch has and whose IRQA
	// is in those areas, else max(u64) (sd_in_arm).
	in_irq: [2]u64,
	bvol:   [2][2]i32, // BVOLL, BVOLR, the input area's volume, per core (libsd)
	switches: [2][Spu_Switch]u32, // the voice masks sd_switch_extra keeps, 24 bits, per core
	// The voice samples spu_catch_up rendered ahead of spu_mix, per core:
	// the voices' sums and their effect send, interleaved stereo, early_n
	// samples of them, which the next spu_mix outputs first.
	early_acc:  [2][2 * SPU_AHEAD]i32,
	early_send: [2][2 * SPU_AHEAD]i32,
	early_n:    u32,
	// The input clock's sample (spu_in_sample) the samples ahead start at:
	// early_n samples rendered is the voices' state at frame_s + early_n.
	frame_s: u64,
}

// The most voice samples spu_catch_up renders ahead of spu_mix. The host
// mixes a vblank of the input clock (vblank_samples, 800 or 801), but the
// mix reads the IOP's clock where its threads left it, up to a slice
// (IOP_SLICE, 48 samples) past the EE's, or further while a thread runs on
// past its slice. Two vblanks bound that, so only a mixer truly behind
// starts the frame again; a vblank's cap did so most frames, a call there
// rendering nothing, and a key on's ENVX read in that stretch read 0.
@(private = "file")
SPU_AHEAD :: MIX_RATE / 30

// Whether spu_catch_up has said once, under cpu.debug, that it started the
// frame again. Host-side diagnostics, not snapshotted.
@(private = "file")
spu_restart_logged: bool

// The voice masks sceSdSetSwitch writes and sceSdGetSwitch reads back.
@(private = "file")
Spu_Switch :: enum u8 {PMON, NON, VMIXL, VMIXEL, VMIXR, VMIXER}

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
	play:       bool, // libsd's: its samples play and it raises its interrupt (sd_block_arm)
	next:       u64, // the bytes moved since `cycles` at its next half-buffer crossing
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

// Enter the block at v.nax: take its loop flags (a loop start sets LSA),
// decode it if the voice plays, and raise the IRQ if it is at IRQA. A
// stopped voice's blocks are not decoded, its ADPCM history kept, as
// PCSX2's DecodeSamples.
@(private = "file")
spu_block :: proc(v: ^Spu_Voice) {
	F := [5][2]i32{{0, 0}, {60, 0}, {115, -52}, {98, -55}, {122, -60}}
	b := spu.ram[v.nax & (SPU_RAM_SIZE - 16):][:16]
	v.flags = b[1]
	if v.flags & 4 != 0 {v.lsa = v.nax}
	if v.phase != .Stopped {
		shift := u32(b[0] & 15)
		f := min(int(b[0] >> 4), 4)
		for n in 0 ..< 28 {
			nib := (b[2 + n / 2] >> (u32(n & 1) * 4)) & 15
			s := i32(i16(u16(nib) << 12)) >> shift
			s += (v.hist[0] * F[f][0] + v.hist[1] * F[f][1] + 32) >> 6
			s = clamp(s, -32768, 32767)
			v.hist[1], v.hist[0] = v.hist[0], s
			v.pcm[n] = i16(s)
		}
	}
	if spu.irq_watch != 0 {sd_irq_check(v, ~u32(15))}
}

// Raises the IRQ of each core with its IRQ enabled whose IRQA, masked by
// `mask`, is the block at v.nax: with ~15 any address in the block, as a
// voice entering it reads its words in turn (PCSX2's IncrementNextA); with
// ~0 only the block's start, as PCSX2's UpdateBlockHeader compares it with
// every voice's block every sample. Either core's IRQ, the voice's own or
// the other's: PCSX2 checks both for every voice's address.
@(private = "file")
sd_irq_check :: proc(v: ^Spu_Voice, mask: u32) {
	for c in u32(0) ..< 2 {
		if spu.irq_watch & (1 << c) != 0 && spu.irqa[c] & mask == v.nax &~ 15 {sd_irq_raise(c)}
	}
}

// Raises core c's IRQ, and takes it as libsd's interrupt handler does
// before it calls the game's: it clears the core's IRQ_ENABLE (ps2sdk's
// freesd, Spu2Interrupt), so the core raises no more until it is enabled
// again.
@(private = "file")
sd_irq_raise :: proc(c: u32) {
	iop_sd.pending |= SD_PENDING_SPU2 << c
	spu.irq_watch &~= 1 << c
	spu.in_irq[c] = max(u64)
}

// The input area: per core, 0x200 samples of left then 0x200 of right,
// 16-bit, core 0's at SPU_IN_BASE and core 1's 0x800 bytes on. Every
// output sample, both cores read the sample at one position common to both,
// which steps at MIX_RATE and wraps at 0x200; a read at a core's IRQA raises
// its IRQ, a left read and a right one alike (IRQA's bit 0x400 ignored), so
// either core's read raises it. That is PCSX2 practice (ReadInput.cpp),
// unverified on hardware, as are the position's phase and that core 1
// reads even in its bypass mode (PCSX2 skips its read then). The position
// runs on EE time, as block transfers do, so its IRQ comes at its own cycle
// whatever the mixer's pace.
//
// The read does not wait for an ADMA (AutoDMA) transfer: a sound driver can
// write the area itself with voice transfers and have it play, its own IRQ at
// IRQA in the area its refill clock. PCSX2 gated the read on ADMA in 2021
// (c84e563) and took the gate out four days later (83fcd4b) as it broke a
// game's sounds; it now zeroes the area when an ADMA is turned off.
//
// Below the input areas, from SPU_OUT_BASE, PCSX2 writes the cores' outputs
// to sound RAM at that same position every sample (Mixer.cpp: voices 1 and
// 3, the external input, each core's dry and wet sums), 0x200 samples
// each, and a write at a core's IRQA raises its IRQ as a read does. They
// are not written here, but an IRQA among them raises the IRQ at its write's
// cycle all the same, on the input read's clock.
@(private = "file")
SPU_IN_BASE :: 0x4000
@(private = "file")
SPU_OUT_BASE :: 0x800

// Input samples read by EE cycle t.
@(private = "file")
spu_in_sample :: proc(t: u64) -> u64 {
	return t * MIX_RATE / cpu.EE_CLOCK
}

// The samples the host mixes at vblank v, counted from 1: the input clock's
// samples between vblanks v - 1 and v. A vblank is NTSC's 59.94 Hz, 800.8
// samples, so this is 800 or 801 and the mix stays within a sample of the
// clock that the voices, the input area and the streams run on.
vblank_samples :: proc(v: u64) -> int {
	return int(spu_in_sample(v * cpu.CYCLES_PER_FRAME) - spu_in_sample((v - 1) * cpu.CYCLES_PER_FRAME))
}

// Sets core c's in_irq, the cycle of the first input read or output write
// past now (the IOP's clock) at its IRQA if its IRQ is enabled and IRQA is
// in the input or output areas, and the IOP's wake to match.
@(private = "file")
sd_in_arm :: proc(c: u32) {
	spu.in_irq[c] = max(u64)
	a := spu.irqa[c]
	if spu.irq_watch & (1 << c) != 0 && a >= SPU_OUT_BASE && a < SPU_IN_BASE + 0x1000 {
		// The first position not yet read at IRQA, read once spu_in_sample
		// passes it, as sd_input_mix takes it.
		k := spu_in_sample(r3000.state.cycles * IOP_EE_RATIO)
		k += (u64(a >> 1) - k) & 0x1ff
		spu.in_irq[c] = ((k + 1) * cpu.EE_CLOCK + MIX_RATE - 1) / MIX_RATE
	}
	iop_wake_set()
}

// Raises the IRQ of each core whose input read or output write at IRQA is
// due by EE cycle now.
sd_in_cross :: proc(now: u64) {
	for c in u32(0) ..< 2 {
		if spu.irq_watch & (1 << c) != 0 && spu.in_irq[c] <= now {sd_irq_raise(c)}
	}
}

// Adds core c's input area, scaled by its BVOL, to the interleaved stereo
// acc: the samples read over the acc's length up to now.
@(private = "file")
sd_input_mix :: proc(c: u32, acc: []i32) {
	k := spu_in_sample(cpu.state.cycles) - u64(len(acc) / 2)
	vol := spu.bvol[c]
	base := SPU_IN_BASE + c * 0x800
	for n := 0; n + 1 < len(acc); n += 2 {
		at := base + u32(k & 0x1ff) * 2
		acc[n] += spu_ram16(at) * vol[0] >> 15
		acc[n + 1] += spu_ram16(at + 0x400) * vol[1] >> 15
		k += 1
	}
}

@(private = "file")
spu_ram16 :: #force_inline proc(a: u32) -> i32 {
	return i32(i16(u16(spu.ram[a]) | u16(spu.ram[a + 1]) << 8))
}

// Keys v on at its SSA. spu_block checks IRQA against the whole SSA block
// (~15), an approximation for a pitch-0 key-on: PCSX2 stops such a voice
// with NextA at SSA+5 halfwords, so an IRQA at bytes SSA+10 to SSA+14 never
// raises there, while here it does.
@(private = "file")
spu_start :: proc(v: ^Spu_Voice) {
	v.endx = false
	v.phase, v.level, v.counter = .Attack, 0, 0
	v.nax, v.lsa = v.ssa, v.ssa
	v.idx, v.frac, v.last, v.hist = 0, 0, {}, {}
	spu_block(v)
}

// One sample of a level's stepping at `rate` (7 bits: shift in the high 5,
// step in the low 2), the envelope's and a volume sweep's, as PCSX2 counts
// it (ADSR.cpp): the counter adds 0x8000 >> (shift - 11), all of 0x8000 at
// shift 11 and under, a quarter of that in an exponential increase over
// 0x6000, and at least 1; once it reaches 0x8000 it clears and the level
// steps by delta (stepped true, and only then is the level clamped). The
// step is (7 - step) up, (step - 8) down, << (11 - shift) at shift 11 and
// under; an exponential decrease scales it by level / 0x8000, rounded down
// (>> 15). A sweep's add may be 0, so it never steps, at step 3 or at
// shift 31: PCSX2's V_VolumeSlide reads its "all bits of the rate set" as
// either; the envelope's add never is 0. A rate change keeps the counter.
@(private = "file")
spu_rate_step :: proc(level: i32, counter: ^u32, rate: u32, decrease, exponential, sweep: bool) -> (delta: i32, stepped: bool) {
	shift := rate >> 2
	inc := u32(0x8000) >> (max(shift, 11) - 11)
	if exponential && !decrease && level > 0x6000 {inc >>= 2}
	if !sweep || (rate & 3 != 3 && shift != 31) {inc = max(inc, 1)}
	counter^ += inc
	if counter^ < 0x8000 {return 0, false}
	counter^ = 0
	step := i32(rate & 3)
	delta = (decrease ? step - 8 : 7 - step) << (11 - min(shift, 11))
	if exponential && decrease {delta = i32(i16((delta * level) >> 15))}
	return delta, true
}

// Step an envelope level (0..0x7fff) one sample (spu_rate_step).
@(private = "file")
spu_env_step :: proc(level: ^i32, counter: ^u32, rate: u32, decrease, exponential: bool) {
	if d, ok := spu_rate_step(level^, counter, rate, decrease, exponential, false); ok {
		level^ = clamp(level^ + d, 0, 0x7fff)
	}
}

// Advance the envelope of a playing voice one sample; a sustain or a
// release that reaches zero stops the voice (PCSX2's V_ADSR::Calculate; its
// decay stops at the sustain level, never 0). ENDX is left as it is.
@(private = "file")
spu_envelope :: proc(v: ^Spu_Voice) {
	switch v.phase {
	case .Attack:
		spu_env_step(&v.level, &v.counter, (v.adsr1 >> 8) & 0x7f, false, v.adsr1 & 0x8000 != 0)
		if v.level >= 0x7fff {v.phase = .Decay}
	case .Decay:
		spu_env_step(&v.level, &v.counter, ((v.adsr1 >> 4) & 15) << 2, true, true)
		if v.level <= i32((v.adsr1 & 15) + 1) * 0x800 {v.phase = .Sustain}
	case .Sustain:
		spu_env_step(&v.level, &v.counter, (v.adsr2 >> 6) & 0x7f, v.adsr2 & 0x4000 != 0, v.adsr2 & 0x8000 != 0)
		if v.level == 0 {v.phase = .Stopped}
	case .Release:
		spu_env_step(&v.level, &v.counter, (v.adsr2 & 31) << 2, true, v.adsr2 & 0x20 != 0)
		if v.level == 0 {v.phase = .Stopped}
	case .Stopped:
	}
}

// A voice volume, VOLL or VOLR: the register as written and the volume it
// gives now (VOLXL, VOLXR), -0x8000..0x7fff, 0x7fff about unity. With bit
// 15 clear the register's bits 14-0 are a signed level, half the volume, so
// 0x3fff is unity and 0x4000 (-0x4000) inverts. With bit 15 set the volume
// sweeps from where it is: bit 13 down (else up), bit 14 exponential (else
// linear), bits 6-0 the rate, stepped as the envelope's (spu_rate_step).
// Bit 12, the negative phase, turns the step's sign: an increase heads for
// -0x8000, and a decrease rises to 0 from below (a positive volume goes
// straight to 0); it does nothing to an exponential decrease. An increase runs over the
// whole range, a decrease stops at 0. A write keeps the sweep's counter,
// even of a new rate. That is PCSX2's V_VolumeSlide, unverified on SPU2
// hardware. A sweep steps every sample, its voice playing or not, before
// the sample takes the volume (PCSX2's MixVoice).
@(private = "file")
Spu_Vol :: struct {
	reg:     u16,
	cur:     i32,
	counter: u32, // toward the sweep's next step (spu_rate_step)
}

@(private = "file")
spu_vol_set :: proc(x: ^Spu_Vol, r: u32) {
	x.reg = u16(r)
	if r & 0x8000 == 0 {x.cur = i32(i16(u16(r << 1)))}
}

// Steps a sweeping volume one sample.
@(private = "file")
spu_sweep :: proc(x: ^Spu_Vol) {
	r := u32(x.reg)
	if r & 0x8000 == 0 {return}
	decrease, exponential := r & 0x2000 != 0, r & 0x4000 != 0
	d, ok := spu_rate_step(x.cur, &x.counter, r & 0x7f, decrease, exponential, true)
	if !ok {return}
	switch {
	case decrease && exponential: x.cur = clamp(x.cur + d, 0, 0x7fff)
	case r & 0x1000 != 0: x.cur = clamp(x.cur - d, -0x8000, decrease ? 0 : 0x7fff)
	case: x.cur = clamp(x.cur + d, decrease ? 0 : -0x8000, 0x7fff)
	}
}

// One sample of a voice, then advance it by its pitch. A block with the end
// flag sets ENDX and goes on at LSA; without the repeat flag the voice stops
// there, its envelope at 0. A stopped voice advances all the same, through
// its blocks' flags and the IRQ at IRQA, silent: PCSX2's MixVoice runs every
// voice's address for its IRQs (its sample, of a stopped voice, unused).
@(private = "file")
spu_sample :: proc(v: ^Spu_Voice) -> i32 {
	s := gauss(v.last[0], v.last[1], v.last[2], i32(v.pcm[v.idx]), v.frac >> 4)
	v.frac += v.pitch
	for v.frac >= 0x1000 {
		v.frac -= 0x1000
		v.last = {v.last[1], v.last[2], i32(v.pcm[v.idx])}
		v.idx += 1
		if v.idx < 28 {continue}
		v.idx = 0
		if v.flags & 1 == 0 {
			v.nax += 16
		} else {
			v.endx, v.nax = true, v.lsa
			if v.flags & 2 == 0 {v.phase, v.level = .Stopped, 0}
		}
		spu_block(v)
	}
	return s
}

// Adds core c's voices to the interleaved stereo acc, each a sample on per
// stereo pair, and those in the effect send to send too unless it is nil:
// one pass.
@(private = "file")
spu_voices :: proc(c: int, acc, send: []i32) {
	for &v in spu.voice[c] {
		// Every sample, every voice's block start at IRQA raises the IRQ,
		// stopped or at pitch 0 (PCSX2's UpdateBlockHeader). IRQA and the
		// IRQ enables change only between passes (each libsd call catches
		// the voices up first, spu_catch_up), an IRQ raised only clears its
		// enable, and a voice changes block only by entering one (spu_block
		// checks it), so one check at the pass's start is that check's
		// every sample.
		if spu.irq_watch != 0 {sd_irq_check(&v, ~u32(0))}
		// A stopped voice still sweeps and advances (spu_sample); at pitch
		// 0 with no sweep it has nothing to do. Nor has one parked, ended
		// and looping back on its own block (as sd_init leaves every
		// voice): each pass it would enter that same block again, its
		// state the same, but for the block's IRQ, any address in it,
		// checked here as spu_block would.
		sweeping := (v.vol[0].reg | v.vol[1].reg) & 0x8000 != 0
		if v.phase == .Stopped && !sweeping {
			if v.pitch == 0 {continue}
			if v.endx && v.lsa == v.nax && spu.ram[v.nax + 1] & 3 == 3 {
				if spu.irq_watch != 0 {sd_irq_check(&v, ~u32(15))}
				continue
			}
		}
		for n := 0; n + 1 < len(acc); n += 2 {
			spu_sweep(&v.vol[0])
			spu_sweep(&v.vol[1])
			s := spu_sample(&v)
			// An end without repeat in this sample stopped it, silent.
			if v.phase == .Stopped {continue}
			// The sample takes the envelope's level after this sample's
			// step, as PCSX2's MixVoice: 0 if the step stopped it.
			spu_envelope(&v)
			s = s * v.level >> 15
			sl, sr := s * v.vol[0].cur >> 15, s * v.vol[1].cur >> 15
			acc[n] += sl
			acc[n + 1] += sr
			if send != nil && !v.dry {
				send[n] += sl
				send[n + 1] += sr
			}
		}
	}
}

// Renders the voices ahead of spu_mix up to the IOP's clock, so a libsd or
// sdrdrv call, which calls this first, reads and changes them as they are
// at its cycle, not as the last vblank's mix left them. The invariant: the
// voices' state is that after frame_s + early_n samples of the input clock
// (spu_in_sample), and every voice read or write, IRQA and IRQ enable
// change goes through a call that has caught them up, so each lands between
// the samples at its time and a voice's IRQ at IRQA raises at its own
// sample, as the input area's read and the output areas' write do on that
// same clock (sd_in_arm, sd_input_mix), not at the next vblank. At most
// SPU_AHEAD samples are rendered ahead; past that the mixer is behind (a
// stall, or tests mixing by hand), and the frame starts again at now with
// the samples ahead kept, the time between not rendered, as before the
// catch-up.
spu_catch_up :: proc() {
	s := spu_in_sample(r3000.state.cycles * IOP_EE_RATIO)
	due := s - min(s, spu.frame_s)
	if due > SPU_AHEAD {
		if cpu.debug >= 1 && !spu_restart_logged {
			spu_restart_logged = true
			fmt.eprintfln("spu: catch-up %d samples past the last mix, over %d: the frame starts again (logged once)", due, SPU_AHEAD)
		}
		spu.frame_s = s - min(s, u64(spu.early_n))
		return
	}
	if due <= u64(spu.early_n) {return}
	from, to := 2 * int(spu.early_n), 2 * int(due)
	for c in 0 ..< 2 {
		acc, send := spu.early_acc[c][from:to], spu.early_send[c][from:to]
		mem.zero_slice(acc)
		mem.zero_slice(send)
		spu_voices(c, acc, send)
	}
	spu.early_n = u32(due)
	if iop_sd.pending != 0 {iop_wake_set()}
}

// Add the voices to interleaved stereo at MIX_RATE, the SPU2 output rate.
// Each core sums its voices and reverb return wide and saturates once, at its
// output, so voices that cancel do not clip on the way. Core 1's sum takes
// CRI ADX's streams too (adx_mix). The voice samples spu_catch_up rendered
// ahead come first, the rest rendered here; any past out's length (only a
// mix shorter than a vblank's) stay ahead for the next.
spu_mix :: proc(out: []i32) {
	acc := make([]i32, len(out), context.temp_allocator)
	early := 2 * min(int(spu.early_n), len(out) / 2)
	for c in 0 ..< 2 {
		mem.zero_slice(acc)
		// A core runs its reverb only with effects enabled and a mode set.
		w := &spu.reverb[c]
		wet := spu.effect[c] && w.mode != 0
		send: []i32
		copy(acc, spu.early_acc[c][:early])
		if wet {
			send = make([]i32, len(out), context.temp_allocator)
			copy(send, spu.early_send[c][:early])
			spu_voices(c, acc[early:], send[early:])
		} else {spu_voices(c, acc[early:], nil)}
		// A block transfer playing into the core fills its input area, which
		// it plays from IOP memory here; else the area plays from sound RAM.
		// Either plays at the core's BVOL, dry, MMIX's gates not modelled.
		if spu.bvol[c] != {} {
			if b := &spu.block[c]; b.on && b.play {
				sd_block_mix(b, spu.bvol[c], acc)
			} else {sd_input_mix(u32(c), acc)}
		}
		if wet {reverb_mix(w, send, acc)}
		if c == ADX_CORE {adx_mix(acc)}
		// The master volume scales the core's whole output, reverb included
		// (an assumption from PCSX2 practice, not checked on hardware); 24
		// loud voices times a volume overflow 32 bits.
		m := spu.master[c]
		for x, i in acc {out[i] += i32(clamp(i64(x) * i64(m[i & 1]) >> 14, -32768, 32767))}
	}
	left := 2 * int(spu.early_n) - early
	for c in 0 ..< 2 {
		copy(spu.early_acc[c][:], spu.early_acc[c][early:][:left])
		copy(spu.early_send[c][:], spu.early_send[c][early:][:left])
	}
	spu.early_n = u32(left / 2)
	s := spu_in_sample(r3000.state.cycles * IOP_EE_RATIO)
	spu.frame_s = s - min(s, u64(spu.early_n))
	if iop_sd.pending != 0 {iop_wake_set()}
}

// Adds block transfer b's samples, scaled by vol (BVOLL, BVOLR), to the
// interleaved stereo acc, from where it reads now on; a one-shot one is
// silent past its end.
@(private = "file")
sd_block_mix :: proc(b: ^Sdr_Block, vol: [2]i32, acc: []i32) {
	off := sdr_block_pos(b) - b.base
	s16 :: #force_inline proc(a: u32) -> i32 {
		p := iop_mem(a &~ 1, 2)
		return len(p) < 2 ? 0 : i32(i16(u16(p[0]) | u16(p[1]) << 8))
	}
	for n := 0; n + 1 < len(acc); n += 2 {
		if off >= b.size {
			if !b.loop {return}
			off = 0
		}
		l := b.base + (off &~ 1023) + (off & 1023) / 4 * 2
		acc[n] += s16(l) * vol[0] >> 15
		acc[n + 1] += s16(l + 512) * vol[1] >> 15
		off += 4
	}
}

// A master volume register, MVOLL or MVOLR, in a voice volume's format
// (Spu_Vol): with bit 15 clear, bits 14-0 are a signed level, half the
// gain, so 0x3fff is unity and 0x4000 (-0x4000) inverts; with bit 15 set the
// level sweeps, and a master's sweep is taken at full scale.
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
	spu_vol_set(&v.vol[0], k.voll)
	spu_vol_set(&v.vol[1], k.volr)
	v.adsr1, v.adsr2 = k.adsr1 & 0xffff, k.adsr2 & 0xffff
	spu_start(v)
}

// Change the pitch and volumes of a voice, playing or not.
spu_voice_set :: proc(core, voice: int, pitch, voll, volr: u32) {
	v := spu_voice_at(core, voice)
	v.pitch = spu_pitch(pitch)
	spu_vol_set(&v.vol[0], voll)
	spu_vol_set(&v.vol[1], volr)
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

// Key a voice off, as KOFF: a playing voice's envelope goes to release, its
// counter cleared; a stopped one stays stopped (PCSX2's V_ADSR::Release).
spu_voice_off :: proc(core, voice: int) {
	spu_release(spu_voice_at(core, voice))
}

@(private = "file")
spu_release :: proc(v: ^Spu_Voice) {
	if v.phase != .Stopped {v.phase, v.counter = .Release, 0}
}

Spu_Status :: struct {
	on:   bool, // playing (a sustain or release that reaches zero, or an end without repeat, stops it)
	endx: bool, // ENDX: a block with the end flag has finished since key on
	envx: u16, // ENVX: the envelope level, 0..0x7fff
	nax:  u32, // NAX: the block playing, a byte address
	lsax: u32, // LSAX: the loop start, a byte address
}

spu_voice_status :: proc(core, voice: int) -> Spu_Status {
	v := spu_voice_at(core, voice)
	return {on = v.phase != .Stopped, endx = v.endx, envx = u16(v.level), nax = v.nax, lsax = v.lsa}
}

// libsd's calls on the voices, as both of its front ends take them: sdrdrv
// over RPC (sdr_server) and libsd as an IOP module imports it (libsd.odin).
// The id names core and voice in its low bits. Those that return a bool say
// whether they decoded the id; one they do not changes nothing.

// sceSdInit's InitVoices (ps2sdk's freesd): it writes a block at
// SPU_VOICE_PARK that loops on itself, its header 0x07 0x07 (shift 7, end,
// repeat and loop start), then sets every voice's volumes, ADSR 0, pitch
// 0x3FFF and start there, and keys every voice on and off. Each is left
// stopped, cleared, looping on that block, so none rests at an address a
// game's IRQA may name (sd_irq_check).
sd_init :: proc() {
	park := spu.ram[SPU_VOICE_PARK:][:32]
	mem.zero_slice(park)
	mem.set(raw_data(park), 0x07, 16)
	for &core in spu.voice {for &v in core {
		spu_voice_reset(&v)
		v.flags = 0x07
	}}
}

// Where every voice starts and rests: PCSX2's V_Core::Init sets each
// voice's StartA and LoopStartA to 0x2800 (halfwords) and NextA to 0x2801,
// in the block at byte 0x5000, and freesd's InitVoices keys them all there.
@(private = "file")
SPU_VOICE_PARK :: 0x5000

// A voice as reset leaves it: stopped at SPU_VOICE_PARK, pitch 0x3FFF
// (PCSX2's V_Core::Init and freesd's InitVoices), all else cleared.
@(private = "file")
spu_voice_reset :: proc(v: ^Spu_Voice) {
	v^ = {ssa = SPU_VOICE_PARK, lsa = SPU_VOICE_PARK, nax = SPU_VOICE_PARK, pitch = 0x3fff}
}

// sceSdSetParam(id, value) for a voice's VOLL, VOLR, PITCH, ADSR1, ADSR2.
sd_set_param :: proc(id, value: u32) -> bool {
	v := spu_voice(id)
	switch id & 0xff00 {
	case SD_VP_VOLL: spu_vol_set(&v.vol[0], value)
	case SD_VP_VOLR: spu_vol_set(&v.vol[1], value)
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
		case SD_S_KOFF: spu_release(&core[i])
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

// sceSdBlockTransStatus as libsd answers it: sd_block_status, and in bit 24
// the half of the buffer it reads now.
sd_block_status_half :: proc(channel: u32) -> u32 {
	b := &spu.block[channel & 1]
	pos := sdr_block_pos(b)
	half := u32(pos - b.base >= b.size / 2 && b.size != 0)
	return pos & 0xffffff | half << 24
}

// libsd's calls past sdrdrv's, which only libsd.odin makes, after the shared
// ones above did not decode the id.

@(private = "file")
SD_VP_ENVX :: 0x0500
@(private = "file")
SD_VP_VOLXL :: 0x0600
@(private = "file")
SD_VP_VOLXR :: 0x0700
@(private = "file")
SD_P_MMIX :: 0x0800
@(private = "file")
SD_P_MVOLL :: 0x0900
@(private = "file")
SD_P_MVOLR :: 0x0a00
@(private = "file")
SD_P_EVOLL :: 0x0b00
@(private = "file")
SD_P_EVOLR :: 0x0c00
@(private = "file")
SD_P_AVOLL :: 0x0d00
@(private = "file")
SD_P_AVOLR :: 0x0e00
@(private = "file")
SD_P_BVOLL :: 0x0f00
@(private = "file")
SD_P_BVOLR :: 0x1000
@(private = "file")
SD_P_MVOLXL :: 0x1100
@(private = "file")
SD_P_MVOLXR :: 0x1200
@(private = "file")
SD_S_PMON :: 0x1300
@(private = "file")
SD_S_NON :: 0x1400
@(private = "file")
SD_S_ENDX :: 0x1700
@(private = "file")
SD_S_VMIXL :: 0x1800
@(private = "file")
SD_S_VMIXEL :: 0x1900
@(private = "file")
SD_S_VMIXR :: 0x1a00
@(private = "file")
SD_S_VMIXER :: 0x1b00
@(private = "file")
SD_A_ESA :: 0x1c00
@(private = "file")
SD_A_EEA :: 0x1d00
@(private = "file")
SD_A_TSA :: 0x1e00
@(private = "file")
SD_A_IRQA :: 0x1f00
@(private = "file")
SD_C_EFFECT_ENABLE :: 0x2
@(private = "file")
SD_C_IRQ_ENABLE :: 0x4
@(private = "file")
SD_C_MUTE :: 0x6
@(private = "file")
SD_C_NOISE_CLK :: 0x8
@(private = "file")
SD_C_SPDIF :: 0xa

// sceSdGetParam(id) for a voice's VOLL, VOLR (as set, bit 15 lost), PITCH,
// ADSR1, ADSR2, ENVX and VOLXL, VOLXR (its volume now, the sweep's where it
// sweeps; the envelope is ENVX's, apart).
sd_get_param :: proc(id: u32) -> (u32, bool) {
	v := spu_voice(id)
	switch id & 0xff00 {
	case SD_VP_VOLL: return u32(v.vol[0].reg) & 0x7fff, true
	case SD_VP_VOLR: return u32(v.vol[1].reg) & 0x7fff, true
	case SD_VP_PITCH: return v.pitch, true
	case SD_VP_ADSR1: return v.adsr1, true
	case SD_VP_ADSR2: return v.adsr2, true
	case SD_VP_ENVX: return u32(v.level), true
	case SD_VP_VOLXL: return u32(u16(i16(v.vol[0].cur))), true
	case SD_VP_VOLXR: return u32(u16(i16(v.vol[1].cur))), true
	}
	return 0, false
}

// sceSdSetParam(id, value) for a core's: MVOLL, MVOLR, EVOLL, EVOLR and the
// input area's volume BVOLL, BVOLR (a signed 16-bit level, 0x7fff about
// unity, as PCSX2 takes it) set; MMIX, the external input's AVOL and the
// read-only MVOLX are taken and change nothing.
sd_core_param :: proc(id, value: u32) -> bool {
	c := id & 1
	switch id & 0xff00 {
	case SD_P_MVOLL: spu.master[c][0] = spu_volume(value)
	case SD_P_MVOLR: spu.master[c][1] = spu_volume(value)
	case SD_P_EVOLL: spu.reverb[c].evol[0] = i32(i16(u16(value)))
	case SD_P_EVOLR: spu.reverb[c].evol[1] = i32(i16(u16(value)))
	case SD_P_BVOLL: spu.bvol[c][0] = i32(i16(u16(value)))
	case SD_P_BVOLR: spu.bvol[c][1] = i32(i16(u16(value)))
	case SD_P_MMIX, SD_P_AVOLL, SD_P_AVOLR, SD_P_MVOLXL, SD_P_MVOLXR:
	case: return false
	}
	return true
}

// sceSdGetParam(id) for a core's EVOLL, EVOLR.
sd_core_get :: proc(id: u32) -> (u32, bool) {
	c := id & 1
	switch id & 0xff00 {
	case SD_P_EVOLL: return u32(u16(spu.reverb[c].evol[0])), true
	case SD_P_EVOLR: return u32(u16(spu.reverb[c].evol[1])), true
	}
	return 0, false
}

// A core's EVOLL and EVOLR, as sceSdEffectAttr's two depth halfwords.
sd_effect_depth :: proc(c: u32) -> u32 {
	evol := spu.reverb[c].evol
	return u32(u16(evol[0])) | u32(u16(evol[1])) << 16
}

// sceSdSetSwitch(id, voice mask) for PMON, NON, the dry mixes VMIXL, VMIXR
// and the effect mixes VMIXEL, VMIXER: the mask is kept for sceSdGetSwitch,
// 24 bits as LIBSD 1.5 writes them, and only the effect mixes change what
// plays, a voice in the effect send with its bit set. Both share the one
// send here, so the last of the two written decides for both, though each
// reads back its own mask. ENDX: LIBSD 1.5 writes both halves of the core's
// ENDX register, and a write there clears the end flags whatever the value
// (as known of the SPU2, not seen on hardware), so every voice of the core
// loses its end flag.
sd_switch_extra :: proc(id, mask: u32) -> bool {
	c := id & 1
	if id & 0xff00 == SD_S_ENDX {
		for &v in spu.voice[c] {v.endx = false}
		return true
	}
	s, found := spu_switch(id)
	if !found {return false}
	spu.switches[c][s] = mask & 0xffffff
	if s == .VMIXEL || s == .VMIXER {
		for &v, i in spu.voice[c] {v.dry = mask & (1 << u32(i)) == 0}
	}
	return true
}

// sceSdGetSwitch(id) for ENDX, voice n's end flag in bit n, left set (LIBSD
// 1.5 only reads the register), and the masks sd_switch_extra keeps. KON
// and KOFF are not: LIBSD 1.5 reads their registers, whose value is not
// known.
sd_get_switch :: proc(id: u32) -> (u32, bool) {
	c := id & 1
	if id & 0xff00 == SD_S_ENDX {
		bits: u32
		for &v, i in spu.voice[c] {if v.endx {bits |= 1 << u32(i)}}
		return bits, true
	}
	s, found := spu_switch(id)
	if !found {return 0, false}
	return spu.switches[c][s], true
}

// The mask id names, its core aside.
@(private = "file")
spu_switch :: proc(id: u32) -> (Spu_Switch, bool) {
	switch id & 0xff00 {
	case SD_S_PMON: return .PMON, true
	case SD_S_NON: return .NON, true
	case SD_S_VMIXL: return .VMIXL, true
	case SD_S_VMIXEL: return .VMIXEL, true
	case SD_S_VMIXR: return .VMIXR, true
	case SD_S_VMIXER: return .VMIXER, true
	}
	return {}, false
}

// sceSdSetAddr(id, address) for a core's IRQA; ESA, EEA and TSA are taken
// and change nothing (the effect's work area is not in sound RAM here).
sd_addr_extra :: proc(id, addr: u32) -> bool {
	switch id & 0xff00 {
	case SD_A_IRQA:
		spu.irqa[id & 1] = addr & (SPU_RAM_SIZE - 1)
		sd_in_arm(id & 1)
	case SD_A_ESA, SD_A_EEA, SD_A_TSA:
	case: return false
	}
	return true
}

// sceSdGetAddr(id) for a core's IRQA.
sd_get_addr_extra :: proc(id: u32) -> (u32, bool) {
	if id & 0xff00 != SD_A_IRQA {return 0, false}
	return spu.irqa[id & 1], true
}

// sceSdSetCoreAttr(entry, value) for EFFECT_ENABLE and IRQ_ENABLE; MUTE,
// NOISE_CLK and SPDIF are taken and change nothing.
sd_core_attr :: proc(entry, value: u32) -> bool {
	c := entry & 1
	switch entry &~ 1 {
	case SD_C_EFFECT_ENABLE: spu_effect_enable(int(c), value != 0)
	case SD_C_IRQ_ENABLE:
		spu.irq_watch &~= 1 << c
		if value != 0 {spu.irq_watch |= 1 << c}
		sd_in_arm(c)
	case SD_C_MUTE, SD_C_NOISE_CLK, SD_C_SPDIF:
	case: return false
	}
	return true
}

// sceSdClearEffectWorkArea(core, ...): the work area zeroed, mode and
// return volume kept.
sd_clear_effect :: proc(core: u32) {
	w := &spu.reverb[core & 1]
	reverb_set(w, w.mode, w.evol[0], w.evol[1], true)
}

// sceSdInit's part past sd_init: the cores' IRQs off, their input areas
// silent (BVOL 0, its value at power on not known), every block transfer
// stopped, and every voice in the four mixes, as LIBSD 1.5's init writes
// VMIXL, VMIXEL, VMIXR and VMIXER all ones on both cores (sd_init's voices
// are out of no send already). It does not write PMON or NON: they are
// kept 0, the zero state, as their value at power on is not known.
sd_lib_init :: proc() {
	spu.irqa, spu.irq_watch, spu.in_irq, spu.bvol = {}, 0, {max(u64), max(u64)}, {}
	spu.block = {}
	for &c in spu.switches {c = {.PMON = 0, .NON = 0, .VMIXL = 0xffffff, .VMIXEL = 0xffffff, .VMIXR = 0xffffff, .VMIXER = 0xffffff}}
}

// Stops the block transfers whose buffer starts in `freed`, the memory a
// failed IOP load frees (sd_undo).
sd_block_drop :: proc(freed: []Sys_Block) {
	for &b in spu.block {
		if b.on && sys_in(freed, b.base) {b.on, b.play = false, false}
	}
}

// Makes channel's block transfer, just started by sd_block_trans, libsd's:
// it plays, and its first half-buffer crossing is set.
sd_block_arm :: proc(channel: u32) {
	b := &spu.block[channel & 1]
	b.play = true
	half := u64(b.size / 2)
	b.next = half == 0 ? max(u64) : (u64(b.start) / half + 1) * half - u64(b.start)
}

// The EE cycle of b's next half-buffer crossing, or max(u64): it has none
// while stopped, and a one-shot one none past its end.
@(private = "file")
sd_block_due :: proc(b: ^Sdr_Block) -> u64 {
	if !b.on || !b.play || b.next == max(u64) {return max(u64)}
	if !b.loop && u64(b.start) + b.next > u64(b.size) {return max(u64)}
	return b.cycles + (b.next * cpu.EE_CLOCK + SD_BLOCK_RATE - 1) / SD_BLOCK_RATE
}

// Takes channel's next half-buffer crossing if it is due by EE cycle now.
sd_block_cross :: proc(channel: u32, now: u64) -> bool {
	b := &spu.block[channel & 1]
	if sd_block_due(b) > now {return false}
	b.next += u64(b.size / 2)
	return true
}

// When, in EE cycles, libsd's interrupts are due: at once (the IOP's clock)
// while one is raised, else at the first half-buffer crossing of a block
// transfer with a transfer handler or input read or output write at an
// enabled IRQA; max(u64) when none is.
sd_next_ee :: proc() -> u64 {
	if iop_sd.pending != 0 {return r3000.state.cycles * IOP_EE_RATIO}
	t := max(u64)
	for &b, c in spu.block {
		if iop_sd.trans[c].func != 0 {t = min(t, sd_block_due(&b))}
		if spu.irq_watch & (1 << u32(c)) != 0 {t = min(t, spu.in_irq[c])}
	}
	return t
}

// sdrdrv: {?, args...} in, the result in the first word out.
@(private)
sdr_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r: u32 = 0
	spu_catch_up()
	switch fno {
	case 0x8000: sd_init()
	case 0x8010: if !sd_set_param(w[1], w[2]) {sd_core_param(w[1], w[2])} // as libsd's sceSdSetParam
	case 0x8030: sd_set_switch(w[1], w[2])
	case 0x8050: sd_set_addr(w[1], w[2])
	case 0x8060: r, _ = sd_get_addr(w[1])
	case 0x80d0: r = sd_voice_trans(w[2], w[3], w[4], w[5])
	case 0x80e0: r = sd_block_trans(w[1], w[2], w[3], w[4], w[5])
	case 0x80f0: r = 1 // sceSdVoiceTransStatus {channel, flag}: always complete
	case 0x8100: r = sd_block_status(w[1])
	case:
		if h := sdr_user_handler(fno); h != 0 {
			sdr_user_unrun(fno, h, w[:16]) // an IOP module's handler (sdrdrv.odin)
		} else if cpu.debug >= 1 {fmt.eprintfln("sdr: unhandled fno %x", fno)}
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
	spu.in_irq = {max(u64), max(u64)}
	// Power on, as PCSX2's V_Core::Init: IRQA 0x800 halfwords, the IRQ off,
	// every voice stopped at SPU_VOICE_PARK, pitch 0x3FFF. Sound RAM is 0,
	// so until sceSdInit writes its block there the voices run on through
	// it, as PCSX2's do.
	spu.irqa = {0x1000, 0x1000}
	for &core in spu.voice {for &v in core {spu_voice_reset(&v)}}
	core.snap_add(&spu)
}
