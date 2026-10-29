// GS register state, fed by the GIF. A renderer hooks in through state.write
// and state.transfer; without one only the side effects the EE can observe
// (CSR SIGNAL/FINISH, interrupts) are emulated.
package ps2_gs

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

GS_PRIM :: 0x00
GS_RGBAQ :: 0x01
GS_ST :: 0x02
GS_UV :: 0x03
GS_XYZF2 :: 0x04
GS_XYZ2 :: 0x05
GS_FOG :: 0x0a
GS_XYZF3 :: 0x0c
GS_XYZ3 :: 0x0d
GS_TRXDIR :: 0x53
GS_HWREG :: 0x54
GS_SIGNAL :: 0x60
GS_FINISH :: 0x61
GS_LABEL :: 0x62

GS_CSR_SIGNAL :: 0x1
GS_CSR_FINISH :: 0x2

state: struct {
	regs:    [0x64]u64,
	q:       f32, // from the last ST, latched into RGBAQ
	siglbl:  u64,
	// Renderer entry points: every register write, after it is stored, and
	// host-to-local transfer data.
	write:    proc(reg: u8, v: u64),
	transfer: proc(data: []u8),
}

// Write a GS general register (GIF A+D, REGLIST, or decoded PACKED data).
// No bounds checks: reg is range-checked first.
gs_write :: proc(reg: u8, v: u64) #no_bounds_check {
	if reg >= len(state.regs) {return}
	if cpu.debug == 3 {fmt.eprintfln("gs: %02x = %016x", reg, v)}
	state.regs[reg] = v
	if state.write != nil {state.write(reg, v)}
	switch reg {
	case GS_SIGNAL: // ID/IDMSK into SIGLBLID low word
		m := v >> 32
		state.siglbl = (state.siglbl &~ m) | (v & m & 0xffffffff)
		gs_raise(GS_CSR_SIGNAL, 0x100)
	case GS_FINISH:
		gs_raise(GS_CSR_FINISH, 0x200)
	case GS_LABEL:
		m := (v >> 32) << 32
		state.siglbl = (state.siglbl &~ m) | ((v << 32) & m)
	}
}

// Set a CSR event bit and interrupt the EE unless IMR masks it.
@(private)
gs_raise :: proc(bit: u32, imr_mask: u32) {
	mem.gs_csr |= bit
	if cpu.debug == 2 {fmt.eprintfln("gs: raise %x imr %x", bit, mem.gs_imr)}
	if mem.gs_imr & imr_mask == 0 {
		mem.intc_raise(mem.INTC_GS)
	}
}

// IMAGE-mode GIF data, bound for local memory through HWREG.
gs_image :: proc(data: []u8) {
	if state.transfer != nil {state.transfer(data)}
}

// Privileged GS register (PMODE, DISPFBn, DISPLAYn, ...) by byte offset,
// masked to mem.gsregs.
gs_priv :: proc(off: u32) -> u64 #no_bounds_check {
	return (^u64)(&mem.gsregs[off & (len(mem.gsregs) - 8)])^
}

// Emulated state, saved and restored by snapshots (snap.odin).
gs_snap :: proc() {
	core.snap_add(&state)
}
