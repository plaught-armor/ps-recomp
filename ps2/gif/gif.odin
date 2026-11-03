// The GIF: packets from PATH1 (VU1 XGKICK), PATH2 (VIF1 DIRECT) and PATH3
// (GIF DMA and FIFO) unpacked into GS register writes.
//
// One path at a time owns the GIF, from a packet's first tag to the end of
// the tag with EOP; a path that arrives meanwhile waits. When the GIF is
// free the waiting paths go in priority order, PATH1, PATH2, PATH3. With
// GIF_MODE.IMT set, a PATH3 packet in IMAGE mode gives the GIF up between
// 8-qword slices to a waiting PATH1 or DIRECT (not DIRECTHL, which waits
// for the IMAGE to end) and resumes once that packet is done.
//
// Everything runs synchronously, so what waits is held here: PATH1 and
// PATH3 data in queues, PATH2 by stalling VIF1 before its DIRECT
// (the VIF keeps the rest of its stream). Arbitration is at the boundaries
// of the data each feed brings, and for PATH3 also at its own EOPs and
// slices: a DIRECT's data always goes in whole.
//
// GIF_MODE.M3R and VIF1's MSKPATH3 mask PATH3 between packets: a packet
// that has not started waits in gif_q3 until the mask is lifted, and one in
// flight runs to its EOP. GIF_STAT is computed from this state (gif_stat).
package ps2_gif

import "ps:core"
import cpu "../cpu"
import gs "../gs"
import mem "../mem"

@(private)
Gif_Path :: struct {
	nloop:  u32, // loops left in the current packet; 0 = expecting a tag
	flg:    u32,
	nreg:   u32,
	regs:   u64,
	reg:    u32, // register index within the loop
	open:   bool, // the current tag has no EOP: the packet goes on after it
}

@(private)
gif_paths: [3]Gif_Path

// Who owns the GIF and who waits for it (GIF_STAT's APATH, P1Q-P3Q, IP3).
@(private)
Gif_Arb :: struct {
	apath:    u32, // 0 idle, 1-3 the path in a packet
	ip3:      bool, // PATH3 was sliced and has the rest of its IMAGE to go
	p2_wait:  bool, // VIF1 holds a DIRECT until the GIF is free
	p2_hl:    bool, // and it is a DIRECTHL
	q3_head:  int, // bytes of gif_q3 already run
	draining: bool, // gif_arbitrate is running further up the stack
	m3p:      bool, // VIF1 MSKPATH3 masks PATH3 (GIF_STAT.M3P)
	dma_hold: bool, // the GIF DMA channel keeps STR set until gif_q3 has run
}

@(private)
gif_arb: Gif_Arb

// The waiting PATH1 and PATH3 data, emulated state on the console's heap.
// A queue is freed once it has all run, so a snapshot carries only data
// that waits; most games never fill one. The limits bound a hold: PATH1
// holds XGKICK packets, each at most VU1 memory (16 KiB), and VU1 kicks
// only a few while the GIF is held: 4 packets. A waiting PATH3 is a whole
// GIF DMA chain or what is left of one; 4 MiB is all of GS memory, more
// than a chain uploads. A queue that would pass its limit stops the run
// (gif_push): data is never dropped.
@(private)
GIF_Q1 :: 4 * 16 * 1024
@(private)
GIF_Q3 :: 4 * 1024 * 1024
@(private)
gif_q1, gif_q3: [dynamic]u8

// Runs VIF1 on from a DIRECT the GIF made wait (set once, by the VIF).
@(private)
gif_p2_resume: proc()

// GIF_CTRL and GIF_MODE, by hardware register offset, and their bits.
@(private)
GIF_CTRL :: 0x3000
@(private)
GIF_CTRL_PSE :: 8
@(private)
GIF_MODE :: 0x3010
@(private)
GIF_MODE_M3R :: 1
@(private)
GIF_MODE_IMT :: 4

// The GIF_STAT bits that show a path or a queue busy: IP3, P3Q, P2Q, P1Q,
// OPH, APATH and FQC.
GIF_STAT_BUSY :: 0x1f000fe0

// What one GIF_STAT read saw, with gif_moves at the time (gif_stat_guard).
@(private)
Gif_Stat_Read :: struct {
	stat:   u32,
	q1, q3: int, // bytes waiting in gif_q1 and gif_q3
	moves:  u64,
}

// Host diagnostics, not emulated state: the last GIF_STAT read, and a count
// of the calls that may move the GIF on (feeds, mask changes, resets).
@(private)
gif_stat_last: Gif_Stat_Read
@(private)
gif_moves: u64

// Take the VIF's resume proc; once, before the first feed.
gif_init :: proc(p2_resume: proc()) {
	gif_p2_resume = p2_resume
}

// Free a queue that has all run (or is dropped).
@(private)
gif_q_free :: proc(q: ^[dynamic]u8) {
	delete(q^)
	q^ = nil
}

// GIF_CTRL.RST: every path drops its packet and the waiting PATH1 and PATH3
// data, GIF_MODE and the MSKPATH3 mask clear, and the GIF is free. A GIF
// DMA held for its dropped data finishes. A DIRECT VIF1 holds goes in now,
// from its start.
gif_reset :: proc() {
	wait, hold := gif_arb.p2_wait, gif_arb.dma_hold
	gif_moves += 1
	gif_paths = {}
	gif_arb = {draining = gif_arb.draining}
	gif_q_free(&gif_q1)
	gif_q_free(&gif_q3)
	mem.hw_reg(GIF_MODE)^ = 0
	if hold {mem.dma_finish(mem.DMA_GIF)}
	if wait {gif_p2_resume()}
}

// GIF_MODE was written (M3R) or VIF1 ran MSKPATH3: a PATH3 the mask let go
// runs once the GIF is free.
gif_mask_changed :: proc() {
	gif_moves += 1
	if gif_arb.apath == 0 && !gif_p3_masked() {gif_arbitrate()}
}

// VIF1 MSKPATH3: on masks PATH3 from its next packet, off lets it run.
gif_mskpath3 :: proc(on: bool) {
	gif_arb.m3p = on
	gif_mask_changed()
}

// A GIF DMA transfer was fed: whether its channel stays started (STR set)
// because PATH3 data waits in gif_q3. The channel finishes once the queue
// has run (gif_arbitrate) or the GIF is reset.
gif_dma_hold :: proc() -> bool {
	gif_arb.dma_hold = len(gif_q3) != 0
	return gif_arb.dma_hold
}

// GIF_STAT, computed from the arbiter: M3R, M3P, IMT, PSE, IP3, P3Q, P2Q,
// P1Q, OPH, APATH and FQC (the PATH3 qwords waiting, at most the 16 the
// FIFO holds). DIR stays 0: GS-to-host transfers do not go through here.
// ra is the reader's return address, for gif_stat_guard.
gif_stat :: proc(ra: u32) -> u32 {
	a := &gif_arb
	mode := mem.hw_reg(GIF_MODE)^
	q3 := len(gif_q3) - a.q3_head
	s := mode & GIF_MODE_M3R | u32(a.m3p) << 1 | mode & GIF_MODE_IMT | mem.hw_reg(GIF_CTRL)^ & GIF_CTRL_PSE
	s |= u32(a.ip3) << 5 | u32(q3 != 0) << 6 | u32(a.p2_wait) << 7 | u32(len(gif_q1) != 0) << 8
	s |= u32(a.apath != 0) << 9 | a.apath << 10 | u32(min(q3 / 16, 16)) << 24
	gif_stat_guard(s, q3, ra)
	return s
}

// A read that shows the GIF busy, the same as the last read with nothing
// fed, masked or reset since, is a wait the synchronous GIF will not end
// by itself (hardware would be streaming the transfer): a compat row by the
// reader's return address. The value read stays the honest one.
@(private)
gif_stat_guard :: proc(s: u32, q3: int, ra: u32) {
	r := Gif_Stat_Read{s, len(gif_q1), q3, gif_moves}
	if s & GIF_STAT_BUSY != 0 && r == gif_stat_last {core.compat_unknown(.Gif_Stat_Busy, ra, ra = ra)}
	gif_stat_last = r
}

// VIF1 was reset: the DIRECT it held no longer waits for the GIF.
gif_p2_drop :: proc() {
	gif_arb.p2_wait, gif_arb.p2_hl = false, false
}

@(private)
gif_busy :: #force_inline proc(p: ^Gif_Path) -> bool {return p.nloop != 0 || p.open}

// PATH3 is masked (GIF_MODE.M3R or MSKPATH3) and between packets.
@(private)
gif_p3_masked :: #force_inline proc() -> bool {
	return (mem.hw_reg(GIF_MODE)^ & GIF_MODE_M3R != 0 || gif_arb.m3p) && !gif_busy(&gif_paths[2])
}

// PATH3 is in an IMAGE packet with data still to come.
@(private)
gif_p3_image :: #force_inline proc() -> bool {return gif_paths[2].flg >= 2 && gif_paths[2].nloop != 0}

// Whether path (0-2) may put data into the GIF now.
@(private)
gif_can :: proc(path: int, hl: bool) -> bool {
	if path == 2 && gif_p3_masked() {return false}
	a := gif_arb.apath
	if a == 0 {return !(hl && gif_p3_image())} // DIRECTHL waits for a sliced IMAGE too
	if a == u32(path) + 1 {return true}
	return a == 3 && path != 2 && !hl && gif_p3_image() && mem.hw_reg(GIF_MODE)^ & GIF_MODE_IMT != 0
}

// Feed qwords to a GIF path (0-2 for PATH1-3); hl marks a DIRECTHL. PATH1
// and PATH3 data that must wait is queued. PATH2 data is not: the call
// returns false and VIF1 holds the DIRECT until gif_p2_resume.
gif_feed :: proc(path: int, data: []u8, hl := false) -> bool {
	t := cpu.prof_start()
	defer cpu.prof_end(.GIF, t)
	gif_moves += 1
	queued := path == 0 ? len(gif_q1) != 0 : path == 2 && len(gif_q3) != 0
	if queued || !gif_can(path, hl) {
		if path == 1 {
			gif_arb.p2_wait, gif_arb.p2_hl = true, hl
			return false
		}
		gif_push(path, data)
		return true
	}
	if gif_arb.apath == 3 && path != 2 {gif_arb.apath, gif_arb.ip3 = 0, true} // a PATH3 slice ends here
	used := gif_run(path, data)
	if used < len(data) {gif_push(path, data[used:])} // PATH3 stopped for a waiting path
	if gif_arb.apath == 0 {gif_arbitrate()}
	return true
}

@(private)
gif_push :: proc(path: int, data: []u8) {
	if path == 0 {
		if len(gif_q1) + len(data) > GIF_Q1 {
			cpu.fatal("gif: PATH1 queue overflow (%d bytes waiting, %d more): XGKICKs held too long", len(gif_q1), len(data))
		}
		append(&gif_q1, ..data)
		return
	}
	a := &gif_arb
	n := len(gif_q3) - a.q3_head
	if n + len(data) > GIF_Q3 {
		cpu.fatal("gif: PATH3 queue overflow (%d bytes waiting, %d more): GIF DMA held too long", n, len(data))
	}
	if a.q3_head != 0 && a.q3_head >= n { // drop what has run once it is the larger part
		remove_range(&gif_q3, 0, a.q3_head)
		a.q3_head = 0
	}
	append(&gif_q3, ..data)
}

// Hand the free GIF to the waiting paths in priority order until one holds
// it again or none waits. A run called from here (VIF1 resumed, its XGKICKs)
// leaves the arbitration to this loop.
@(private)
gif_arbitrate :: proc() {
	a := &gif_arb
	if a.draining {return}
	a.draining = true
	defer a.draining = false
	for a.apath == 0 {
		switch {
		case len(gif_q1) != 0:
			gif_run(0, gif_q1[:]) // XGKICK packets end at EOP and are never cut
			gif_q_free(&gif_q1)
		case a.p2_wait && gif_can(1, a.p2_hl):
			a.p2_wait = false
			gif_p2_resume() // may wait again, behind what it let in
		case len(gif_q3) != 0 && !gif_p3_masked():
			a.q3_head += gif_run(2, gif_q3[a.q3_head:])
			if a.q3_head == len(gif_q3) {
				gif_q_free(&gif_q3)
				a.q3_head = 0
				if a.dma_hold {
					a.dma_hold = false
					mem.dma_finish(mem.DMA_GIF)
				}
			}
		case gif_busy(&gif_paths[2]):
			a.apath, a.ip3 = 3, false // a sliced PATH3 takes the GIF back for its rest
		case:
			return
		}
	}
}

// Parse a path's qwords into GS writes; returns the bytes used. Only PATH3
// stops early, at the end of a packet or an IMAGE slice, when another path
// waits, or at the end of a packet when it is masked.
@(private)
gif_run :: proc(path: int, data: []u8) -> int {
	p := &gif_paths[path]
	a := &gif_arb
	q := ([^]u64)(raw_data(data))
	n := len(data) / 16
	if gif_busy(p) {gif_take(path)} // the rest of a packet, or a sliced PATH3's
	for i := 0; i < n; i += 1 {
		lo, hi := q[2 * i], q[2 * i + 1]
		if p.nloop == 0 {
			if !p.open {
				if path == 2 && (len(gif_q1) != 0 || a.p2_wait || gif_p3_masked()) {return 16 * i}
				gif_take(path)
			}
			p.nloop = u32(lo & 0x7fff)
			p.flg = u32(lo >> 58) & 3
			p.nreg = u32(lo >> 60)
			if p.nreg == 0 {p.nreg = 16}
			p.regs = hi
			p.reg = 0
			p.open = lo & 0x8000 == 0
			gs.state.q = 1 // reading a GIFtag initializes Q to 1.0
			if lo & (1 << 46) != 0 && p.flg == 0 {gs.gs_write(gs.GS_PRIM, (lo >> 47) & 0x7ff)}
			if !gif_busy(p) {a.apath = 0}
			continue
		}
		switch p.flg {
		case 0: // PACKED
			gif_packed(u8(p.regs >> (4 * p.reg)) & 0xf, lo, hi)
			gif_next_reg(p)
		case 1: // REGLIST: two registers per qword
			for v in ([2]u64{lo, hi}) {
				if p.nloop == 0 {break}
				r := u8(p.regs >> (4 * p.reg)) & 0xf
				if r != 0xe && r != 0xf {gs.gs_write(r, v)}
				gif_next_reg(p)
			}
		case: // IMAGE
			cnt := min(int(p.nloop), n - i)
			slice := path == 2 && (len(gif_q1) != 0 || a.p2_wait && !a.p2_hl) && mem.hw_reg(GIF_MODE)^ & GIF_MODE_IMT != 0
			if slice {cnt = min(cnt, 8)}
			gs.gs_image(data[16 * i:][:16 * cnt])
			p.nloop -= u32(cnt)
			i += cnt - 1
			if slice && p.nloop != 0 {
				a.apath, a.ip3 = 0, true
				return 16 * (i + 1)
			}
		}
		if !gif_busy(p) {a.apath = 0}
	}
	return 16 * n
}

@(private)
gif_take :: #force_inline proc(path: int) {
	gif_arb.apath = u32(path) + 1
	if path == 2 {gif_arb.ip3 = false}
}

@(private)
gif_next_reg :: #force_inline proc(p: ^Gif_Path) {
	p.reg += 1
	if p.reg == p.nreg {
		p.reg = 0
		p.nloop -= 1
	}
}

@(private)
gif_packed :: proc(r: u8, lo, hi: u64) {
	switch r {
	case gs.GS_PRIM:
		gs.gs_write(gs.GS_PRIM, lo & 0x7ff)
	case gs.GS_RGBAQ:
		q := u64(transmute(u32)gs.state.q)
		gs.gs_write(gs.GS_RGBAQ, lo & 0xff | (lo >> 24) & 0xff00 | (hi & 0xff) << 16 | (hi >> 8) & 0xff000000 | q << 32)
	case gs.GS_ST:
		gs.state.q = transmute(f32)u32(hi)
		gs.gs_write(gs.GS_ST, lo)
	case gs.GS_UV:
		gs.gs_write(gs.GS_UV, lo & 0x3fff | (lo >> 16) & 0x3fff0000)
	case gs.GS_XYZF2:
		v := lo & 0xffff | (lo >> 16) & 0xffff0000 | ((hi >> 4) & 0xffffff) << 32 | ((hi >> 36) & 0xff) << 56
		gs.gs_write(hi & (1 << 47) != 0 ? gs.GS_XYZF3 : gs.GS_XYZF2, v)
	case gs.GS_XYZ2:
		v := lo & 0xffff | (lo >> 16) & 0xffff0000 | (hi & 0xffffffff) << 32
		gs.gs_write(hi & (1 << 47) != 0 ? gs.GS_XYZ3 : gs.GS_XYZ2, v)
	case gs.GS_FOG:
		gs.gs_write(gs.GS_FOG, ((hi >> 36) & 0xff) << 56)
	case 0xe: // A+D
		gs.gs_write(u8(hi), lo)
	case 0xf: // NOP
	case:
		gs.gs_write(r, lo)
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
gif_snap :: proc() {
	core.snap_add(&gif_paths)
	core.snap_add(&gif_arb)
	core.snap_add(&gif_q1)
	core.snap_add(&gif_q3)
}
