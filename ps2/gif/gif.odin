// The GIF: packets from PATH1 (VU1 XGKICK), PATH2 (VIF1 DIRECT) and PATH3
// (GIF DMA and FIFO) unpacked into GS register writes.
package ps2_gif

import "ps:core"
import cpu "../cpu"
import gs "../gs"

@(private)
Gif_Path :: struct {
	nloop:  u32, // loops left in the current packet; 0 = expecting a tag
	flg:    u32,
	nreg:   u32,
	regs:   u64,
	reg:    u32, // register index within the loop
}

@(private)
gif_paths: [3]Gif_Path

// Feed qwords to a GIF path (0-2 for PATH1-3).
gif_feed :: proc(path: int, data: []u8) {
	t := cpu.prof_start()
	defer cpu.prof_end(.GIF, t)
	p := &gif_paths[path]
	q := ([^]u64)(raw_data(data))
	n := len(data) / 16
	for i := 0; i < n; i += 1 {
		lo, hi := q[2 * i], q[2 * i + 1]
		if p.nloop == 0 {
			p.nloop = u32(lo & 0x7fff)
			p.flg = u32(lo >> 58) & 3
			p.nreg = u32(lo >> 60)
			if p.nreg == 0 {p.nreg = 16}
			p.regs = hi
			p.reg = 0
			gs.state.q = 1 // reading a GIFtag initializes Q to 1.0
			if lo & (1 << 46) != 0 && p.flg == 0 {gs.gs_write(gs.GS_PRIM, (lo >> 47) & 0x7ff)}
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
			gs.gs_image(data[16 * i:][:16 * cnt])
			p.nloop -= u32(cnt)
			i += cnt - 1
		}
	}
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
}
