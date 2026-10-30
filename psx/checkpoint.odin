// Frozen-time passes: run game code to draw an extra picture between two
// game frames, then put the machine back exactly as it was.
//
// A pass starts with checkpoint_save, which copies every piece of machine state
// that game code reaching the GPU can change (RAM a page at a time, on the
// pass's first write to each page: ram_guard in bus.odin), and freezes emulated
// time: events (vblank, DMA completion, CD, timers) and interrupts are held
// back, so no interrupt handler, vblank or present runs inside the pass. The
// caller then calls game functions with `call`, draws with the game's own GPU
// calls, and copies the picture with capture_extra_frame. checkpoint_restore
// puts RAM, VRAM, CPU, GTE, GPU, DMA, interrupt, event and BIOS state (the
// rand() seed among it) and the ordering-table cull back and lets time run
// again. Sound, CD, controller and memory card state are not saved; draw code
// never touches them, except the sound library's voice commit in the frame's
// end, whose SPU register writes spu_write drops in a pass.
package psx

@(require) import "core:fmt"

import cpu "cpu"
import gte "gte"
import bios "bios"
import gpu "gpu"
import render "render"
import io "io"

Checkpoint :: struct {
	// RAM is saved a page at a time, on the pass's first write to the page
	// (ram_keep); only the pages in `kept` hold saved bytes.
	ram:        [cpu.RAM_SIZE]u8,
	kept:       Ram_Pages,
	ram_ver:    [cpu.RAM_PAGES]u32,
	// RAM_KEEP_CHECK builds: all of RAM at save, to prove at restore that
	// every page the pass changed was kept.
	ram_check:  [RAM_SIZE when RAM_KEEP_CHECK else 0]u8,
	scratch:    [cpu.SCRATCH_SIZE]u8,
	vram:       [render.VRAM_W * render.VRAM_H]u16,
	vram_key:   u32,
	// The hi-res target's saved picture, and the depth and world undo.
	pass:       render.Pass,
	// The pass this one runs inside (a room drawn for an in-between
	// picture), nil for one saved from the running machine.
	outer:      ^Checkpoint,
	cpu_state:  cpu.Cpu,
	cop0:       type_of(cpu.cop0),
	gte_state:  gte.Gte,
	draw:       render.Draw_State,
	gp:         type_of(gpu.gp),
	display:    type_of(gpu.display),
	dma:        type_of(io.dma),
	irq:        type_of(io.irq_regs),
	bios:       type_of(bios.bios),
	events:     [io.Event]u64,
	next_event: u64,
	see:        type_of(render.see_through),
}

// Memory as one game frame's drawing found it, for replaying that drawing.
Draw_Start :: struct {
	ram:     [cpu.RAM_SIZE]u8,
	// ram's page versions (ram_ver).
	ram_ver: [cpu.RAM_PAGES]u32,
	scratch: [cpu.SCRATCH_SIZE]u8,
	gte_state: gte.Gte,
}

// One bit per RAM page.
@(private)
Ram_Pages :: [cpu.RAM_PAGES / 64]u64

// Build with -define:RAM_KEEP_CHECK=true to check, at every restore, that
// no RAM write went around ram_guard / ram_touch.
RAM_KEEP_CHECK :: #config(RAM_KEEP_CHECK, false)

@(private)
page_has :: #force_inline proc(set: ^Ram_Pages, p: u32) -> bool {
	return set[p / 64] & (1 << (p % 64)) != 0
}

// Before an armed page's write: give RAM page p a new version, and inside a
// pass copy it into the running pass's checkpoint when that has not saved it
// yet, and into the outer pass's too when that has not: the page is
// unchanged since the outer save, since any write since would have kept it.
ram_keep :: proc(p: u32) #no_bounds_check {
	assert(p < cpu.RAM_PAGES, "RAM page out of range")
	cpu.ram_armed[p] = false
	cpu.ram_ver_last += 1
	cpu.ram_ver[p] = cpu.ram_ver_last
	cp := pass_checkpoint
	if cp == nil {
		return
	}
	at := p * cpu.RAM_PAGE
	if !page_has(&cp.kept, p) {
		copy(cp.ram[at:][:cpu.RAM_PAGE], cpu.ram[at:][:cpu.RAM_PAGE])
		cp.kept[p / 64] |= 1 << (p % 64)
	}
	if o := cp.outer; o != nil && !page_has(&o.kept, p) {
		copy(o.ram[at:][:cpu.RAM_PAGE], cpu.ram[at:][:cpu.RAM_PAGE])
		o.kept[p / 64] |= 1 << (p % 64)
	}
}

// Put the kept pages of cp back into RAM, runs of neighbouring pages at once.
@(private)
ram_put_back :: proc(cp: ^Checkpoint) #no_bounds_check {
	p := u32(0)
	for p < cpu.RAM_PAGES {
		if !page_has(&cp.kept, p) {
			p += 1
			continue
		}
		first := p
		for p < cpu.RAM_PAGES && page_has(&cp.kept, p) {
			p += 1
		}
		copy(cpu.ram[first * cpu.RAM_PAGE:p * cpu.RAM_PAGE], cp.ram[first * cpu.RAM_PAGE:p * cpu.RAM_PAGE])
	}
}

// The running pass's checkpoint.
@(private)
pass_checkpoint: ^Checkpoint

// Copy the machine into cp and freeze time. Returns false, changing nothing,
// when the GPU is midway through a command or transfer, which a pass would
// corrupt. Inside a pass, cp nests in it: restore goes back to the pass.
checkpoint_save :: proc(cp: ^Checkpoint) -> bool {
	assert(!io.events_frozen || pass_checkpoint != nil, "pass without its checkpoint")
	assert(cp != pass_checkpoint, "checkpoint saved twice")
	if gpu.gp.need != 0 || gpu.gp.polyline || gpu.gp.uploading || gpu.gp.downloading {
		return false
	}
	render.raster_sync()
	cp.kept = {}
	cp.ram_ver = cpu.ram_ver
	cpu.ram_armed = true
	when RAM_KEEP_CHECK {
		cp.ram_check = ram
	}
	cp.scratch = cpu.scratch
	cp.vram = render.vram
	cp.vram_key = render.vram_key
	cp.pass.hi_tiles = 0
	cp.pass.hi_swapped = false
	if render.target_count == 2 {
		if len(cp.pass.hi) != len(render.targets[1].rgb) {
			delete(cp.pass.hi)
			cp.pass.hi = make([]u32, len(render.targets[1].rgb))
		}
		render.targets[1].rgb, cp.pass.hi = cp.pass.hi, render.targets[1].rgb
		cp.pass.hi_swapped = true
	}
	cp.outer = io.events_frozen ? pass_checkpoint : nil
	assert(cp.outer == nil || cp.outer.outer == nil, "passes nested twice")
	pass_checkpoint = cp
	cp.pass.outer = cp.outer != nil ? &cp.outer.pass : nil
	render.running_pass = &cp.pass
	cp.cpu_state = cpu.state
	cp.cop0 = cpu.cop0
	cp.gte_state = gte.state
	cp.draw = render.gpu
	cp.gp = gpu.gp
	cp.display = gpu.display
	cp.dma = io.dma
	cp.irq = io.irq_regs
	cp.bios = bios.bios
	cp.events = io.events
	cp.next_event = cpu.next_event
	// The frame's packets are drawn again from scratch, projected anew, and
	// its own projections wait for its own walk.
	cp.see = render.see_through
	render.depth_undo_begin(&cp.pass.depths)
	render.pass_save()
	io.events_frozen = true
	cpu.next_event = io.EVENT_OFF
	return true
}

// Put back the machine saved in cp and let time run again (or, for a nested
// pass, go back to the pass it ran in).
checkpoint_restore :: proc(cp: ^Checkpoint) {
	assert(io.events_frozen, "restore without a checkpoint")
	render.raster_sync()
	ram_put_back(cp)
	when RAM_KEEP_CHECK {
		for p in u32(0) ..< RAM_PAGES {
			at := p * RAM_PAGE
			if string(ram[at:][:RAM_PAGE]) != string(cp.ram_check[at:][:RAM_PAGE]) {
				fmt.panicf("RAM page %#x changed in a pass without being kept (present %d)", 0x80000000 + at, presents)
			}
		}
	}
	// Pages ram_put_back wrote are as they were at save, and the others
	// unchanged since: the saved versions name them all.
	cpu.ram_ver = cp.ram_ver
	cpu.ram_armed = true
	cpu.scratch = cp.scratch
	render.vram = cp.vram
	render.vram_world(cp.vram_key)
	if cp.pass.hi_swapped && render.hi_saved(&cp.pass) {
		render.targets[1].rgb, cp.pass.hi = cp.pass.hi, render.targets[1].rgb
	}
	cp.pass.hi_tiles = 0
	cp.pass.hi_swapped = false
	pass_checkpoint = cp.outer
	render.running_pass = cp.pass.outer
	cpu.state = cp.cpu_state
	cpu.cop0 = cp.cop0
	gte.state = cp.gte_state
	render.gpu = cp.draw
	// The command buffer may have grown during the pass; keep its storage
	// (the saved header could point at freed memory). It was empty at save.
	cmd := gpu.gp.cmd
	gpu.gp = cp.gp
	gpu.gp.cmd = cmd
	clear(&gpu.gp.cmd)
	gpu.display = cp.display
	io.dma = cp.dma
	io.irq_regs = cp.irq
	bios.bios = cp.bios
	io.events = cp.events
	cpu.next_event = cp.next_event
	render.see_through = cp.see
	render.depth_undo_end(&cp.pass.depths)
	render.pass_restore()
	io.events_frozen = cp.outer != nil
	cp.outer = nil
	cp.pass.outer = nil
}

draw_start_save :: proc(ds: ^Draw_Start) {
	draw_start_take_ram(ds)
	ds.scratch = cpu.scratch
	ds.gte_state = gte.state
}

// Copy RAM, as it is now, into a draw start.
draw_start_take_ram :: proc(ds: ^Draw_Start) {
	ds.ram = cpu.ram
	ds.ram_ver = cpu.ram_ver
	cpu.ram_armed = true
}

// New versions for a draw start made by another process (a preload child,
// whose versions go on from the same numbers as this one's).
draw_start_adopt :: proc(ds: ^Draw_Start) {
	for &v in ds.ram_ver {
		cpu.ram_ver_last += 1
		v = cpu.ram_ver_last
	}
}

// Load a draw-start copy into the machine; only valid inside a pass.
draw_start_load :: proc(ds: ^Draw_Start) #no_bounds_check {
	assert(io.events_frozen, "draw start loaded outside a pass")
	// Most pages match already (the same version); only the others are kept
	// and written.
	for p in u32(0) ..< cpu.RAM_PAGES {
		at := p * cpu.RAM_PAGE
		if cpu.ram_ver[p] == ds.ram_ver[p] {
			when RAM_KEEP_CHECK {
				if string(ram[at:][:RAM_PAGE]) != string(ds.ram[at:][:RAM_PAGE]) {
					fmt.panicf("RAM page %#x changed without a new version (present %d)", 0x80000000 + at, presents)
				}
			}
			continue
		}
		cpu.ram_guard(at)
		copy(cpu.ram[at:][:cpu.RAM_PAGE], ds.ram[at:][:cpu.RAM_PAGE])
		cpu.ram_ver[p] = ds.ram_ver[p]
		cpu.ram_armed[p] = true
	}
	cpu.scratch = ds.scratch
	gte.state = ds.gte_state
}

// Load a draw-start copy's scratchpad and GTE, outside a pass: the machine
// goes on from there (for example an instant door).
draw_start_enter :: proc(ds: ^Draw_Start) {
	cpu.scratch = ds.scratch
	gte.state = ds.gte_state
}
