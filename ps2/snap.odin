// Save states and rollback (ps:core snap.odin, rollback_linux.odin): every
// file registers its emulated globals with core.snap_add from its X_snap
// proc, called here before anything is allocated; EE and IOP RAM come from
// core.snap_area; everything allocated during init and on every coroutine
// comes from core.emu_allocator. New emulated globals must be registered or
// save states and rollback desync.
package ps2

import "ps:core"
import cpu "cpu"
import dma "dma"
import gif "gif"
import gs "gs"
import iop "iop"
import ipu "ipu"
import kernel "kernel"
import mem "mem"
import vu "vu"

// About 19 MiB is in use in a 4-player level. Rollback scans the whole
// heap for written pages every frame, at a cost that grows with its size.
@(private)
EMU_HEAP :: 1 << 27

// Set up the machine; what it allocates is emulated state.
init :: proc() {
	core.snap_init(EMU_HEAP)
	mem.mem_snap()
	cpu.cpu_snap()
	dma.dma_snap()
	gif.gif_snap()
	vu.vif_snap()
	mem.hw_snap()
	kernel.kernel_snap()
	gs.gs_snap()
	ipu.ipu_snap()
	iop.fmod_snap()
	vu.vu_snap()
	iop.sif_snap()
	iop.mcserv_snap()
	iop.pad_snap()
	iop.spu_snap()
	core.snap_add(&cpu.unmapped_seen)
	context.allocator = core.emu_allocator()
	core.co_allocator = core.emu_allocator()
	mem.hw_read = hw_read
	mem.hw_write = hw_write
	mem.hw_read128 = hw_read128
	mem.hw_write128 = hw_write128
	mem.vu_mem_addr = vu.vu_mem_addr
	mem.trace_store = kernel.trace_store
	cpu.interp_hook = interp_call
	mem.mem_init()
	vu.vu_init()
	iop.sif_init()
	iop.mcserv_init()
	kernel.kernel_init()
}

// Host main thread: run the game from `entry` on thread 1's coroutine,
// serving snapshot requests. Never returns.
run :: proc(entry: u32) -> ! {
	kernel.exec_boot()
	t := kernel.k.threads[1]
	t.co = core.co_create(proc(arg: rawptr) {
		cpu.call(u32(uintptr(arg)))
		cpu.fatal("entry returned")
	}, rawptr(uintptr(entry)), core.emu_allocator())
	core.snap_run(t.co)
}
