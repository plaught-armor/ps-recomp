// libsd as IOP modules import it (PS_IRX=1): the SPU2 calls of Sony's sound
// library, over the voices, cores and block transfers of spu.odin, and its
// interrupt handlers.
//
// A transfer handler (sceSdSetTransIntrHandler) runs when a voice transfer
// on its channel is done, at once here, and at each half of a block
// transfer's buffer; the SPU2 handler (sceSdSetSpu2IntrHandler) when a core
// with its IRQ enabled reaches IRQA. They run as the IOP's clock reaches
// them (sd_intr_run, from iop_tick), on the handler coroutine sifcmd's
// command handlers run on (th_intr). An id a call does not decode changes
// nothing and raises a compat row.
package ps2_iop

import "core:fmt"
import "core:math"
import "ps:core"
import cpu "../cpu"
import mem "../mem"
import r3000 "ps:psx/cpu"

// iop_sd.pending bits: a channel's transfer done, from bit 0; a core's IRQ,
// from bit 2.
SD_PENDING_TRANS :: 1
SD_PENDING_SPU2 :: 4

// The most half-buffer crossings of one block transfer a tick runs; any
// left run at the next, which is due at once.
@(private = "file")
SD_INTR_MAX :: 16

Sd_Handler :: struct {
	func, arg: u32, // IOP addresses; func 0 is none
}

Iop_Sd :: struct {
	trans:   [2]Sd_Handler, // per channel
	spu2:    Sd_Handler,
	pending: u8, // the interrupts raised and not yet run, SD_PENDING_*
	effect:  [2]Sd_Effect, // per core, as the last sceSdSetEffectAttr left it
}

Sd_Effect :: struct {
	mode, delay, feedback: u32,
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sd: Iop_Sd

// Function fno of libsd, as stdio_fn.
libsd_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	s := &iop_sd
	spu_catch_up() // the voices as they are at this call's cycle
	switch fno {
	case 4: // sceSdInit(flag)
		sd_init()
		sd_lib_init()
		s^ = {}
		return 0, true
	case 5 ..= 12: // sceSdSet/GetParam, Switch, Addr, CoreAttr(entry[, value])
		return sd_entry(fno, a0, a1), true
	case 15: // sceSdProcBatch(sceSdBatch *, returns, count)
		return sd_proc_batch(a0, a1, a2), true
	case 16: // sceSdProcBatchEx(sceSdBatch *, returns, count, voice mask)
		return sd_proc_batch_ex(a0, a1, a2, a3), true
	case 13: // sceSdNote2Pitch(center note, center fine, note, fine)
		p, found := sd_note_pitch(u16(a0), u16(a1), u16(a2), i16(a3))
		if !found {libsd_unknown(fno, a3 & 0xffff)}
		return p, true
	case 14: // sceSdPitch2Note(center note, center fine, pitch)
		return sd_pitch_note(a0, a1, a2), true
	case 17: // sceSdVoiceTrans(channel, mode, iop address, spu address, size): done at once
		size := r32(r[29] + 16)
		if a1 & 3 > 1 {return 0, true}
		n := sd_voice_trans(a1, a2, a3, size)
		if s.trans[a0 & 1].func != 0 {s.pending |= SD_PENDING_TRANS << (a0 & 1)}
		return n, true
	case 18: // sceSdBlockTrans(channel, mode, iop address, size, start address)
		v := sd_block_trans(a0, a1, a2, a3, r32(r[29] + 16))
		if a1 & 3 != 2 {sd_block_arm(a0)} // not a stop
		iop_wake_set()
		return v, true
	case 19: // sceSdVoiceTransStatus(channel, flag): always done
		return 1, true
	case 20: // sceSdBlockTransStatus(channel, flag)
		return sd_block_status(a0), true
	case 23: // sceSdSetEffectAttr(core, sceSdEffectAttr *)
		e := a1
		return sd_set_effect_attr(a0, {r32(e), r32(e + 4), r32(e + 8), r32(e + 12), r32(e + 16)}), true
	case 24: // sceSdGetEffectAttr(core, sceSdEffectAttr *)
		for v, i in sd_get_effect_attr(a0) {w32(a1 + u32(i) * 4, v)}
		return 0, true
	case 25: // sceSdClearEffectWorkArea(core, channel, effect mode)
		sd_clear_effect(a0)
		return 0, true
	case 26: // sceSdSetTransIntrHandler(channel, func, arg): the previous func
		h := &s.trans[a0 & 1]
		old := h.func
		h^ = {a1, a2}
		iop_wake_set()
		return old, true
	case 27: // sceSdSetSpu2IntrHandler(func, arg): the previous func
		old := s.spu2.func
		s.spu2 = {a0, a1}
		return old, true
	case 28: // sceSdGetTransIntrHandlerArgument(channel): the arg 26 set
		if a0 > 1 { // retail reads past its two channels
			libsd_unknown(fno, a0)
			return 0, true
		}
		return s.trans[a0].arg, true
	}
	return 0, false
}

// libsd's set and get calls on one entry, for libsd_fn and the batches:
// sceSdSetParam (fno 5), GetParam (6), SetSwitch (7), GetSwitch (8),
// SetAddr (9), GetAddr (10), SetCoreAttr (11) and GetCoreAttr (12). What a
// get reads, 0 for a set.
@(private = "file")
sd_entry :: proc(fno, entry, value: u32) -> u32 {
	v, found := u32(0), true
	switch fno {
	case 5: found = sd_set_param(entry, value) || sd_core_param(entry, value)
	case 6:
		v, found = sd_get_param(entry)
		if !found {v, found = sd_core_get(entry)}
	case 7: found = sd_set_switch(entry, value) || sd_switch_extra(entry, value)
	case 8: v, found = sd_get_switch(entry)
	case 9: found = sd_set_addr(entry, value) || sd_addr_extra(entry, value)
	case 10:
		v, found = sd_get_addr(entry)
		if !found {v, found = sd_get_addr_extra(entry)}
	case 11: found = sd_core_attr(entry, value)
	case 12: v, found = sd_get_core_attr(entry)
	case: found = false
	}
	if !found {libsd_unknown(fno, entry)}
	return v
}

// A sceSdBatch's func: 1 to 4 set (SetParam, SetSwitch, SetAddr,
// SetCoreAttr), 17 to 20 the matching get; 5 writes the entry to the IOP
// word at value; 6 sends it, a word, to EE address value, and 7 `entry`
// bytes from the returns array, both by SIF DMA, done at once. Param and
// CoreAttr values, and what their gets read, are 16 bits.
@(private = "file")
SD_BATCH_IOP_WRITE :: 5
@(private = "file")
SD_BATCH_EE_WRITE :: 6
@(private = "file")
SD_BATCH_EE_RETURNS :: 7

// Batch entry i at `batch`: {u16 func, u16 entry, u32 value}.
@(private = "file")
sd_batch_entry :: proc(batch, i: u32) -> (func, entry, value: u32) {
	w := r32(batch + 8 * i)
	return w & 0xffff, w >> 16, r32(batch + 8 * i + 4)
}

// Runs batch func `func` on entry and value as ProcBatch does: what goes
// to its returns slot, and false for a func retail does not know.
@(private = "file")
sd_batch_one :: proc(func, entry, value, returns: u32) -> (v: u32, ok: bool) {
	switch func {
	case 1, 4: return sd_entry(func * 2 + 3, entry, value & 0xffff), true
	case 2, 3: return sd_entry(func * 2 + 3, entry, value), true
	case 17, 20: return sd_entry(func * 2 - 28, entry, 0) & 0xffff, true
	case 18, 19: return sd_entry(func * 2 - 28, entry, 0), true
	case SD_BATCH_IOP_WRITE: w32(value, entry)
	case SD_BATCH_EE_WRITE:
		w := entry
		copy(mem.ram_slice(value, 4), ([^]u8)(&w)[:4])
	case SD_BATCH_EE_RETURNS: copy(mem.ram_slice(value, entry), iop_ram_at(returns, entry))
	case: return 0, false
	}
	return 0, true
}

// sceSdProcBatch(batch, returns, count): runs count entries in order,
// each one's result to returns[i] when returns is not 0; count, or ~i for
// an entry i whose func retail does not know, which ends the batch there.
@(private = "file")
sd_proc_batch :: proc(batch, returns, count: u32) -> u32 {
	for i in 0 ..< count {
		func, entry, value := sd_batch_entry(batch, i)
		v, ok := sd_batch_one(func, entry, value, returns)
		if !ok {
			libsd_unknown(15, func)
			return ~i
		}
		if returns != 0 {w32(returns + 4 * i, v)}
	}
	return count
}

// sceSdProcBatchEx(batch, returns, count, voice mask): as ProcBatch, but a
// SetParam or GetParam whose entry has voice bits 0x3e all set, or a SetAddr
// or GetAddr with 0x7e all set, runs on each voice of the 24 in mask
// instead, the voice in place of bits 1 to 5. Slot n of returns counts the
// results written, as retail's does: a set on k voices takes k slots, 0 in
// the last; GetParam writes all 24, a voice not in mask the read before (0
// at first), then the last again; GetAddr one per voice in mask, then the
// last again. The number of slots, or ~i as ProcBatch.
@(private = "file")
sd_proc_batch_ex :: proc(batch, returns, count, mask: u32) -> u32 {
	n: u32
	put :: proc(returns, n, v: u32) {if returns != 0 {w32(returns + 4 * n, v)}}
	for i in 0 ..< count {
		func, entry, value := sd_batch_entry(batch, i)
		all: bool
		switch func {
		case 1, 17: all = entry & 0x3e == 0x3e
		case 3, 19: all = entry & 0x7e == 0x7e
		}
		v: u32
		if all {
			for voice in u32(0) ..< 24 {
				in_mask := mask & (1 << voice) != 0
				e := entry & 0xffc1 | voice << 1
				switch func {
				case 1, 3:
					if !in_mask {continue}
					n += 1
					sd_batch_one(func, e, value, returns)
				case 17:
					if in_mask {v, _ = sd_batch_one(func, e, value, returns)}
					put(returns, n, v)
					n += 1
				case 19:
					if !in_mask {continue}
					v, _ = sd_batch_one(func, e, value, returns)
					put(returns, n, v)
					n += 1
				}
			}
			// Retail's: the last slot is written again below. With no
			// voice of a set in the mask and n 0, n wraps and the write
			// lands at returns - 4; retail has no guard and does the same.
			n -= 1
		} else {
			ok: bool
			v, ok = sd_batch_one(func, entry, value, returns)
			if !ok {
				libsd_unknown(16, func)
				return ~i
			}
		}
		put(returns, n, v)
		n += 1
	}
	return n
}

// After a failed load: puts back each handler it left with its func or arg
// in `freed`, the memory its undo frees, as it was when the load began
// (`saved`), and drops what it had raised; stops the block transfers whose
// buffer is there.
sd_undo :: proc(saved: Iop_Sd, freed: []Sys_Block) {
	s := &iop_sd
	for c in u32(0) ..< 2 {
		if sys_in(freed, s.trans[c].func) || sys_in(freed, s.trans[c].arg) {
			s.trans[c] = saved.trans[c]
			s.pending &~= SD_PENDING_TRANS << c
		}
	}
	if sys_in(freed, s.spu2.func) || sys_in(freed, s.spu2.arg) {
		s.spu2 = saved.spu2
		s.pending &~= SD_PENDING_SPU2 | SD_PENDING_SPU2 << 1
	}
	sd_block_drop(freed)
}

// sceSdNote2Pitch's pitch for `note` and `fine` (128ths of a semitone), the
// note played at 0x1000 being `center_note` and `center_fine`, as retail
// libsd 1.5 computes it. The fines add, the sum's whole semitones (truncated)
// move the note; note minus center, as 16 bits, splits into octaves and a
// semitone (truncated, a negative semitone or fine borrowing from the one
// above). The semitone's ratio, 0x8000 times 2 to the semitone/12, rounded
// down, times the fine's, 0x8000 times 2 to the fine/1536, rounded down, is
// the pitch two octaves up, halved, rounding, once per octave under that.
// Retail shifts by the low 5 bits as MIPS does, and gives a note three
// octaves up or more its pitch two octaves up. A fine sum under -128 that is not a whole
// semitone borrows twice and reads past retail's tables: found false, 0.
@(private = "file")
sd_note_pitch :: proc(center_note, center_fine, note: u16, fine: i16) -> (pitch: u32, found: bool) {
	f := i32(fine) + i32(center_fine)
	q := f / 128
	f -= q * 128
	n := i32(i16(i32(note) + q - i32(center_note)))
	oct := n / 12
	semi, shift := n - oct * 12, oct - 2
	if semi < 0 || semi == 0 && f < 0 {
		semi += 12
		shift -= 1
	}
	if f < 0 {
		semi += q - 1
		f += (q + 1) * 128
	}
	if u32(semi) >= 12 || u32(f) >= 128 {return 0, false}
	p := (sd_semi_ratio(semi) * sd_fine_ratio(f)) >> 16
	if shift < 0 {
		s := u32(-shift)
		p = (p + 1 << ((s - 1) & 31)) >> (s & 31)
	}
	return p & 0xffff, true
}

// The ratios of retail libsd's pitch tables, as 0x8000 is 1: a semitone's
// (0 to 11), 0x8000 times 2 to the semitone/12, and a fine's (0 to 127,
// 128ths of a semitone), 0x8000 times 2 to the fine/1536, each rounded down.
@(private = "file")
sd_semi_ratio :: proc(semi: i32) -> u32 {return u32(math.floor(0x8000 * math.pow(2, f64(semi) / 12)))}
@(private = "file")
sd_fine_ratio :: proc(fine: i32) -> u32 {return u32(math.floor(0x8000 * math.pow(2, f64(fine) / 1536)))}

// sceSdPitch2Note's note for `pitch`, the note played at 0x1000 being
// `center_note` and `center_fine`, as retail libsd computes it: the note in
// the high byte, its fine in 128ths of a semitone, even, in the low. A pitch
// past 0x3fff is 0x3fff. Its top bit gives the octave; the pitch shifted up
// to bit 15 falls between two semitone ratios, the lower its semitone, and
// that over the semitone's ratio, as 0x8000 is 1, between two fine ratios,
// the lower its fine. The fine plus 1 adds to center_fine, whole semitones
// carrying into the note, which adds to center_note, the octave counted from
// 12 (0x1000's top bit) as 12 semitones each. The sums wrap, as retail's 32
// bits do, and only the low 16 are given.
@(private = "file")
sd_pitch_note :: proc(center_note, center_fine, pitch: u32) -> u32 {
	p := min(pitch & 0xffff, 0x3fff)
	oct: u32
	for b in u32(0) ..< 14 {
		if p >> b & 1 != 0 {oct = b}
	}
	m := (p << (15 - oct)) & 0xffff
	semi: i32
	for i := i32(11); i >= 0; i -= 1 {
		if m >= sd_semi_ratio(i) {
			semi = i
			break
		}
	}
	r := ((m << 15) / sd_semi_ratio(semi)) & 0xffff
	fine: i32
	for j := i32(127); j >= 0; j -= 1 {
		if r >= sd_fine_ratio(j) {
			fine = j
			break
		}
	}
	f := center_fine + u32(fine) + 1
	note := center_note + u32(semi) + oct * 12 - 144 + ((f & 0xffff) >> 7)
	return ((note << 8) + (f & 0x7e)) & 0xfffe
}

// sceSdEffectAttr as words: core, mode, depth (L in the low 16 bits, R in
// the high), delay, feedback.
Sd_Effect_Attr :: [5]u32

// sceSdSetEffectAttr(core, attr), for libsd and sdrdrv's 0x8130: 0, or
// KE -1 for a mode spu_effect refuses. The attr's own core is not read.
sd_set_effect_attr :: proc(core_id: u32, a: Sd_Effect_Attr) -> u32 {
	c := core_id & 1
	if !spu_effect(int(c), a[1], i16(a[2]), i16(a[2] >> 16)) {return ke(-1)}
	// Only the two echo modes take delay and feedback from the caller.
	mode := a[1] & 0xff
	echo := mode == 7 || mode == 8
	iop_sd.effect[c] = {mode, a[3] if echo else 0, a[4] if echo else 0}
	return 0
}

// sceSdGetEffectAttr(core), for libsd and sdrdrv's 0x8140: the attr the
// last set left, the depth read back from EVOL.
sd_get_effect_attr :: proc(core_id: u32) -> Sd_Effect_Attr {
	c := core_id & 1
	fx := iop_sd.effect[c]
	return {core_id, fx.mode, sd_effect_depth(c), fx.delay, fx.feedback}
}

// A call's id libsd_fn does not decode: a compat row, and a line under
// PS_DEBUG. sdrdrv's 0x8070 raises it too, as the libsd call it makes.
@(private)
libsd_unknown :: proc(fno, id: u32) {
	core.compat_unknown(.Iop_Sd, id, sub = fno, pc = r3000.state.r[31])
	if cpu.debug >= 1 {fmt.eprintfln("iop: libsd fno %d id %04x not decoded", fno, id)}
}

// Runs libsd's interrupt handlers due by EE cycle `now`: each block
// transfer's half-buffer crossings, then the interrupts raised since the
// last run, as they were when it began.
sd_intr_run :: proc(now: u64) {
	s := &iop_sd
	for c in u32(0) ..< 2 {
		for _ in 0 ..< SD_INTR_MAX {
			h := s.trans[c]
			if h.func == 0 || !sd_block_cross(c, now) {break}
			sd_intr(h, c)
		}
	}
	sd_in_cross(now)
	p := s.pending
	s.pending = 0
	for c in u32(0) ..< 2 {
		if p & (SD_PENDING_TRANS << c) != 0 && s.trans[c].func != 0 {sd_intr(s.trans[c], c)}
	}
	// One call for the cores raised, a0 a bit each, as libsd's handler
	// passes them (ps2sdk's freesd, Spu2Interrupt).
	cores := u32(p / SD_PENDING_SPU2) & 3
	if cores != 0 && s.spu2.func != 0 {sd_intr(s.spu2, cores)}
}

// Runs handler h with a0 `a0` and a1 its argument; one that waits is
// stopped there with a compat row.
@(private = "file")
sd_intr :: proc(h: Sd_Handler, a0: u32) {
	switch th_intr(h.func, a0, h.arg) {
	case .None:
	case .Blocked:
		core.compat_unknown(.Iop_Sd_Intr, h.func, pc = h.func)
		fmt.eprintfln("iop: libsd handler at %x blocked", h.func)
	case .Call:
		fmt.eprintfln("iop: libsd handler at %x stopped", h.func)
	}
}
