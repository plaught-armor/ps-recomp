// The VIFs: DMA'd command streams unpacked into VU memory, with VIF1
// starting VU1 microprograms and passing packets on to the GIF.
package ps2_vu

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import gif "../gif"

Vif :: struct {
	id:          int,
	vu:          ^Vu,
	cl, wl:      u32,
	mode, mask:  u32,
	row, col:    [4]u32,
	base, ofst:  u32,
	tops, top:   u32,
	itops, itop: u32,
	dbf:         bool,
	pending:     [dynamic]u8, // a command split across transfers
}

vifs: [2]Vif

vif_init :: proc() {
	vifs[0] = {id = 0, vu = &vu0, cl = 1, wl = 1}
	vifs[1] = {id = 1, vu = &vu1, cl = 1, wl = 1}
}

@(private)
vif_warned: map[u32]bool

// Feed a transfer's words to a VIF; an incomplete trailing command waits
// for the next transfer.
vif_feed :: proc(v: ^Vif, data: []u8) {
	t := cpu.prof_start()
	defer cpu.prof_end(.VIF, t)
	buf := data
	if len(v.pending) != 0 {
		append(&v.pending, ..data)
		buf = v.pending[:]
	}
	used := vif_run(v, ([^]u32)(raw_data(buf))[:len(buf) / 4])
	rest := buf[used * 4:]
	if len(v.pending) != 0 {
		remove_range(&v.pending, 0, used * 4)
	} else {
		append(&v.pending, ..rest)
	}
}

// Execute VIF codes; returns the words consumed. No bounds checks: i stays
// below len(w), a code runs only when its `need` words are all in w, arg
// holds the need - 1 after the code (DIRECT and MPG always have one, MASK
// one, ROW and COL four), and MPG wraps its destination in micro memory.
@(private)
vif_run :: proc(v: ^Vif, w: []u32) -> int #no_bounds_check {
	i := 0
	for i < len(w) {
		code := w[i]
		cmd := (code >> 24) & 0x7f
		imm := code & 0xffff
		num := (code >> 16) & 0xff
		need := 1
		switch {
		case cmd == 0x20: need = 2
		case cmd == 0x30 || cmd == 0x31: need = 5
		case cmd == 0x4a: need = 1 + 2 * int(num == 0 ? 256 : num)
		case cmd == 0x50 || cmd == 0x51: need = 1 + 4 * int(imm == 0 ? 0x10000 : imm)
		case cmd >= 0x60: need = 1 + vif_unpack_words(v, cmd, num)
		}
		if i + need > len(w) {return i}
		arg := w[i + 1:][:need - 1]
		switch cmd {
		case 0x00: // NOP
		case 0x01: // STCYCL
			v.cl, v.wl = imm & 0xff, imm >> 8
		case 0x02: // OFFSET
			v.ofst = imm & 0x3ff
			v.dbf = false
			v.tops = v.base
		case 0x03: v.base = imm & 0x3ff
		case 0x04: v.itops = imm & 0x3ff
		case 0x05: v.mode = imm & 3
		case 0x06, 0x07: // MSKPATH3, MARK
		case 0x10, 0x11, 0x13: // FLUSHE/FLUSH/FLUSHA: the VU runs synchronously
		case 0x14, 0x15: vif_mscal(v, imm * 8)
		case 0x17: vif_mscal(v, v.vu.tpc)
		case 0x20: v.mask = arg[0]
		case 0x30: v.row = {arg[0], arg[1], arg[2], arg[3]}
		case 0x31: v.col = {arg[0], arg[1], arg[2], arg[3]}
		case 0x4a: // MPG
			dst := (imm * 8) % u32(len(v.vu.micro))
			src := ([^]u8)(&arg[0])[:len(arg) * 4]
			for b, j in src {v.vu.micro[(dst + u32(j)) % u32(len(v.vu.micro))] = b}
			if v.vu == &vu1 {vu1_micro_touch()}
		case 0x50, 0x51: // DIRECT, DIRECTHL
			gif.gif_feed(1, ([^]u8)(&arg[0])[:len(arg) * 4])
		case 0x60 ..= 0x7f:
			vif_unpack(v, cmd, imm, num, arg)
		case:
			if !vif_warned[cmd] {
				vif_warned[cmd] = true
				fmt.eprintfln("vif%d: unknown code %08x", v.id, code)
			}
		}
		i += need
	}
	return i
}

@(private)
vif_mscal :: proc(v: ^Vif, addr: u32) {
	v.itop = v.itops
	if v.id == 1 {
		v.top = v.tops
		v.dbf = !v.dbf
		v.tops = v.base + (v.dbf ? v.ofst : 0)
		vu1_start(addr)
	} else {
		vu0_call_micro(addr)
	}
}

// Source vectors an UNPACK reads for `num` writes under the cycle setting.
@(private)
vif_unpack_srcs :: proc(v: ^Vif, num: u32) -> u32 {
	num := num == 0 ? 256 : num
	if v.wl <= v.cl {return num}
	return num / v.wl * v.cl + min(num % v.wl, v.cl)
}

@(private)
vif_unpack_bits :: proc(cmd: u32) -> u32 {
	vn, vl := (cmd >> 2) & 3, cmd & 3
	if vl == 3 {return 16} // V4-5
	return (32 >> vl) * (vn + 1)
}

@(private)
vif_unpack_words :: proc(v: ^Vif, cmd, num: u32) -> int {
	return int((vif_unpack_srcs(v, num) * vif_unpack_bits(cmd) + 31) / 32)
}

// Unchecked: the destination quadword wraps by mask inside v.vu.mem, val
// and dst take lanes c <= vn <= 3, col takes mc <= 3, and src is read
// through a multi-pointer, sized by vif_unpack_words for exactly the source
// vectors this loop consumes.
@(private)
vif_unpack :: proc(v: ^Vif, cmd, imm, num: u32, src: []u32) #no_bounds_check {
	#assert(VU0_MEM & (VU0_MEM - 1) == 0 && VU1_MEM & (VU1_MEM - 1) == 0)
	vn, vl := (cmd >> 2) & 3, cmd & 3
	masked := cmd & 0x10 != 0
	unsigned := imm & 0x4000 != 0
	qmask := u32(len(v.vu.mem) / 16) - 1
	addr := imm & 0x3ff
	if v.id == 1 && imm & 0x8000 != 0 {addr += v.tops}
	num := num == 0 ? 256 : num
	bits := vif_unpack_bits(cmd)
	bytes := ([^]u8)(raw_data(src))
	elem := u32(32) >> vl
	sidx: u32 = 0 // source vector index
	cyc: u32 = 0
	for _ in 0 ..< num {
		dst := (^[4]u32)(&v.vu.mem[(addr & qmask) * 16])
		filling := v.wl > v.cl && cyc >= v.cl
		val: [4]u32
		if !filling {
			bit := sidx * bits
			if vl == 3 {
				h := u32((^u16)(&bytes[bit / 8])^)
				val = {(h & 0x1f) << 3, ((h >> 5) & 0x1f) << 3, ((h >> 10) & 0x1f) << 3, (h >> 15) << 7}
			} else {
				for c in 0 ..= vn {
					off := (bit + c * elem) / 8
					switch vl {
					case 0: val[c] = (^u32)(&bytes[off])^
					case 1:
						h := (^u16)(&bytes[off])^
						val[c] = unsigned ? u32(h) : u32(i32(i16(h)))
					case 2:
						b := bytes[off]
						val[c] = unsigned ? u32(b) : u32(i32(i8(b)))
					}
				}
				switch vn {
				case 0: val = {val[0], val[0], val[0], val[0]}
				case 1: val = {val[0], val[1], val[0], val[1]}
				}
			}
			sidx += 1
		}
		mc := min(cyc, 3)
		for c in 0 ..< 4 {
			sel: u32 = masked ? (v.mask >> (mc * 8 + u32(c) * 2)) & 3 : 0
			if filling && sel == 0 {sel = 1}
			switch sel {
			case 0:
				x := val[c]
				switch v.mode {
				case 1: x += v.row[c]
				case 2:
					x += v.row[c]
					v.row[c] = x
				}
				dst[c] = x
			case 1: dst[c] = v.row[c]
			case 2: dst[c] = v.col[mc]
			}
		}
		addr += 1
		cyc += 1
		if v.wl <= v.cl {
			if cyc == v.wl {
				addr += v.cl - v.wl
				cyc = 0
			}
		} else if cyc == v.wl {
			cyc = 0
		}
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
vif_snap :: proc() {
	core.snap_add(&vifs)
	core.snap_add(&vif_warned)
}
