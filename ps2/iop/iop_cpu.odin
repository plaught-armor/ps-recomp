// The IOP's processor: the R3000 of package psx_cpu, whose globals a ps2
// binary owns as the IOP. Its RAM is iop_ram. Its loads and stores fold
// physical 0..8 MiB onto that 2 MiB, as the retail mirror does, so IOP code
// never reaches iop_hle.
//
// It runs only with PS_IRX=1, synchronously, from the EE's side: a module's
// load (loadcore.odin), a command packet's handler (sifcmd.odin) and the
// IOP's threads when its clock is due (thread.odin). Its devices are a stub
// that logs each address once and reads 0.
package ps2_iop

import "core:fmt"
import "ps:core"
@(require) import cpu "../cpu" // used only under FLAT
import r3000 "ps:psx/cpu"

IOP_EVENT_OFF :: max(u64)

when core.FLAT {
	// Point psx_cpu's hooks at the IOP. Every hook is set, nil included: a
	// binary that links psx too has had them set to the PS1's at init.
	// FLAT: the step of the continuation h on top of run x (r3000.flat_step).
	// The guest calls host code makes on the IOP, and how FLAT runs each:
	//   - a thread's entry (th_main): the thread's own run (th_flat_run);
	//   - a command or interrupt handler (th_intr_main): the handlers' run;
	//   - sceSifRpcLoop's server calls (rpc_exec): FLAT_RPC_LOOP;
	//   - sdrdrv's user command handler (sdr_serve): FLAT_SDR_SERVE.
	// None is nested (r3000.flat_nested), where a wait would be fatal.
	@(private = "file")
	iop_flat_step :: proc(x: ^r3000.Flat_Ctx, h: ^r3000.Flat_Host) {
		switch h.tag {
		case FLAT_RPC_LOOP:
			rpc_loop_step(h)
		case FLAT_SDR_SERVE:
			sdr_serve_step(h)
		case:
			r3000.fatal("iop: flat continuation %d", h.tag)
		}
	}
}

iop_cpu_init :: proc() {
	r3000.state = {}
	r3000.learn_cpu = .Iop
	core.learn_cpu(.Iop, &r3000.state.cycles, r3000.CYCLES_PER_INSN, proc(a: u32) -> u32 {return r3000.lw(a)}, r3000.RAM_SIZE, true)
	r3000.cop0 = {}
	r3000.scratch = {}
	r3000.next_event = IOP_EVENT_OFF
	r3000.bios_a = iop_no_bios
	r3000.bios_b = iop_no_bios
	r3000.bios_c = iop_no_bios
	r3000.bios_syscall = proc() {r3000.fatal("iop: syscall %d", r3000.state.r[4])}
	r3000.bios_entry = iop_hle_entry
	r3000.irq_check = proc() {}
	when core.FLAT {
		r3000.interp_run = r3000.flat_nested
		r3000.flat_step = iop_flat_step
		cpu.iop_flat_print = r3000.flat_print
	} else {
		r3000.interp_run = r3000.interp_loop
		cpu.iop_flat_print = r3000.interp_print
	}
	r3000.run_events = proc() {}
	r3000.gte_cmd = nil
	r3000.gte_read = nil
	r3000.gte_write = nil
	r3000.io_read = iop_io_read
	r3000.io_write = iop_io_write
	r3000.io_far_read = iop_io_read
	r3000.io_far_write = iop_io_write
	r3000.ram_keep = nil
	clear(&iop_io_seen)
	iop_dispatch_init()
}

// The PS1's A0, B0 and C0 vectors are not the IOP's: no IOP code calls them.
// host_call matches them before bios_entry, so a jump to IOP address 0xa0,
// 0xb0 or 0xc0 lands here; those are exception vectors and kernel data,
// far below any module.
@(private = "file")
iop_no_bios :: proc(fn: u32) {
	r3000.fatal("iop: call to a PS1 BIOS vector, function %#x", fn)
}

// Device addresses read or written, each logged once. Emulated state like
// the other warned-once maps: its storage is in the emu heap, so it is
// snapshotted with it, or a load would leave it pointing at blocks the
// heap's restore has freed or reused.
iop_io_seen: map[u32]bool

@(private = "file")
iop_io_read :: proc(p: u32, size: u32) -> u32 {
	iop_io_note(p, size, "read")
	return 0
}

@(private = "file")
iop_io_write :: proc(p, v: u32, size: u32) {
	iop_io_note(p, size, "write")
}

@(private = "file")
iop_io_note :: proc(p: u32, size: u32, what: string) {
	if p in iop_io_seen {return}
	iop_io_seen[p] = true
	fmt.eprintfln("iop: unmapped io %s%d %08x", what, size * 8, p)
}

// The IOP's emulated state, saved and restored by snapshots. RAM is
// copied whole, not page-tracked like a snap_area.
iop_cpu_snap :: proc() {
	core.snap_add(&r3000.state)
	core.snap_add(&r3000.cop0)
	core.snap_add(&r3000.next_event)
	core.snap_add(&r3000.scratch)
	core.snap_add_bytes(r3000.ram[:])
	core.snap_add(&iop_io_seen)
	core.snap_add(&r3000.dispatch.reported) // report_once grows it
	// RAM put back without the guard: learned functions are compared again.
	append(&core.snap_hooks, core.Snap_Hook{save = proc(_: int) {}, load = proc(_: int) {r3000.learned_epoch += 1}})
}
