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
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_sd: Iop_Sd

// Function fno of libsd, as stdio_fn.
libsd_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	s := &iop_sd
	switch fno {
	case 4: // sceSdInit(flag)
		sd_init()
		sd_lib_init()
		s^ = {}
		return 0, true
	case 5: // sceSdSetParam(entry, value)
		if !sd_set_param(a0, a1) && !sd_core_param(a0, a1) {libsd_unknown(fno, a0)}
		return 0, true
	case 6: // sceSdGetParam(entry)
		v, found := sd_get_param(a0)
		if !found {libsd_unknown(fno, a0)}
		return v, true
	case 7: // sceSdSetSwitch(entry, value)
		if !sd_set_switch(a0, a1) && !sd_switch_extra(a0, a1) {libsd_unknown(fno, a0)}
		return 0, true
	case 8: // sceSdGetSwitch(entry)
		v, found := sd_get_switch(a0)
		if !found {libsd_unknown(fno, a0)}
		return v, true
	case 9: // sceSdSetAddr(entry, value)
		if !sd_set_addr(a0, a1) && !sd_addr_extra(a0, a1) {libsd_unknown(fno, a0)}
		return 0, true
	case 10: // sceSdGetAddr(entry)
		v, found := sd_get_addr(a0)
		if !found {v, found = sd_get_addr_extra(a0)}
		if !found {libsd_unknown(fno, a0)}
		return v, true
	case 11: // sceSdSetCoreAttr(entry, value)
		if !sd_core_attr(a0, a1) {libsd_unknown(fno, a0)}
		return 0, true
	case 13: // sceSdNote2Pitch(center note, center fine, note, fine)
		p, found := sd_note_pitch(u16(a0), u16(a1), u16(a2), i16(a3))
		if !found {libsd_unknown(fno, a3 & 0xffff)}
		return p, true
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
		return sd_block_status_half(a0), true
	case 23: // sceSdSetEffectAttr(core, sceSdEffectAttr *)
		e := a1
		set := spu_effect(int(a0 & 1), r32(e + 4), i16(r32(e + 8)), i16(r32(e + 8) >> 16))
		return set ? 0 : ke(-1), true
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
	ratio := math.floor(0x8000 * math.pow(2, f64(semi) / 12)) * math.floor(0x8000 * math.pow(2, f64(f) / 1536))
	p := u32(ratio) >> 16
	if shift < 0 {
		s := u32(-shift)
		p = (p + 1 << ((s - 1) & 31)) >> (s & 31)
	}
	return p & 0xffff, true
}

// A call's id libsd_fn does not decode: a compat row, and a line under
// PS_DEBUG.
@(private = "file")
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
	p := s.pending
	s.pending = 0
	for c in u32(0) ..< 2 {
		if p & (SD_PENDING_TRANS << c) != 0 && s.trans[c].func != 0 {sd_intr(s.trans[c], c)}
		if p & (SD_PENDING_SPU2 << c) != 0 && s.spu2.func != 0 {sd_intr(s.spu2, 1 << c)}
	}
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
