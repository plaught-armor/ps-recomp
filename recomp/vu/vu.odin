// The VU1 microprograms of an EE program's .vutext compiled to Odin, as
// <out>/vu1/code.odin.
//
// .vutext holds whole programs, each a run of VIF MPG chunks loading
// consecutive micro memory from address 0. A program becomes one proc with a
// switch case per instruction pair, so it can be entered at any pair:
// straight-line pairs fall through, a branch inlines its delay slot and
// re-dispatches. Pairs keep the interpreter's semantics (the runtime's
// vu/vu.odin): the common ops are specialized, the rest call back into it.
// Whatever does not fit (a branch or E bit in a delay slot, code running past
// the program) returns to the interpreter at that pair.
//
// Microcode the EE builds from VIF MPG packets in data has no .vutext; the
// vu1_capture option names a VU1_CAPTURE file recorded from a run (the
// runtime's vu/capture.odin). Each captured entry into each captured micro
// image becomes a program holding only the pairs reachable from that entry:
// fallthrough and branch targets, stopping at a JR/JALR (whose captured
// targets are entries of their own) and after an E bit. Its code is
// registered as ranges of micro memory, which the runtime compares against
// the live micro memory before running it; a pair no program covers runs in
// the interpreter.
//
// MAC flags are computed only where a later FMAND/FMEQ/FMOR or an exit can
// see them. Status flags are never computed: no program reads them (no
// FSEQ/FSAND/FSOR/FSSET), and the EE cannot read VU1 status.
//
// The same upper ops, and the register-only lower ops, also serve the EE
// recompiler as VU0 macro instructions (emit_macro), where CFC2 can read MAC
// and status at any time, so both are always computed.
package vu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../mips"

@(private = "file")
MASK :: 0x3ff8

@(private = "file")
Branch :: enum u8 {None, Uncond, Cond, Reg}

@(private = "file")
Pair :: struct {
	lw, uw:     u32,
	ibit, ebit: bool,
	branch:     Branch,
	mode:       Mode,
	mac_rd:     bool, // reads MAC before writing it
	mac_wr:     bool, // the upper op sets MAC
	mac_live:   bool, // MAC after this pair can be read
}

// How a pair's halves are ordered against the interpreter's vu_pair.
@(private = "file")
Mode :: enum u8 {
	Serial, // upper then lower: neither sees the other's writes
	Lower_First, // the lower reads flags the upper writes, and writes only VI
	Slow, // vu.vu1_pair
}

@(private = "file")
Prog :: struct {
	words: [dynamic]u32, // lw, uw from micro address 0
	ext:   []bool, // the pairs compiled, for a captured image; nil: all
}

@(private = "file")
find_programs :: proc(img: mips.Image) -> (progs: [dynamic]Prog, ok: bool) {
	sec := mips.find_section(img, ".vutext")
	if sec == nil {return progs, true}
	n := sec.size / 4
	w := ([^]u32)(raw_data(sec.data))[:n]
	end: u32 = 0
	for i: u32 = 0; i < n; {
		code := w[i]
		if (code >> 24) & 0x7f != 0x4a {
			i += 1
			continue
		}
		num := (code >> 16) & 0xff
		if num == 0 {num = 256}
		addr := (code & 0xffff) * 8
		if i + 1 + num * 2 > n {
			fmt.eprintfln("vu: MPG at %08x runs past .vutext", sec.addr + i * 4)
			return progs, false
		}
		if addr == 0 {
			append(&progs, Prog{})
			end = 0
		}
		if len(progs) == 0 || addr != end {
			fmt.eprintfln("vu: MPG at %08x loads %04x, expected %04x", sec.addr + i * 4, addr, end)
			return progs, false
		}
		append(&progs[len(progs) - 1].words, ..w[i + 1:][:num * 2])
		end = addr + num * 8
		i += 1 + num * 2
	}
	return progs, true
}

@(private = "file")
upper_writes_mac :: proc(uw: u32) -> bool {
	if uw & 63 < 0x3c {
		switch uw & 63 {
		case 0x10 ..= 0x17, 0x1d, 0x1f, 0x2b, 0x2f: return false // MAX, MINI
		}
		return true
	}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d, 0x1f, 0x2f: return false // ITOF, FTOI, ABS, CLIP, NOP
	}
	return true
}

// The VF register the upper op writes (0 for ACC-only or none), as
// vu_upper_dest.
@(private = "file")
upper_dest :: proc(uw: u32) -> u32 {
	if uw & 63 < 0x3c {return (uw >> 6) & 31}
	switch ((uw >> 4) & 0x7c) | (uw & 3) {
	case 0x10 ..= 0x17, 0x1d: return (uw >> 16) & 31
	}
	return 0
}

@(private = "file")
classify :: proc(lw, uw: u32) -> Pair {
	p := Pair{lw = lw, uw = uw, ibit = uw & (1 << 31) != 0, ebit = uw & (1 << 30) != 0}
	p.mac_wr = upper_writes_mac(uw)
	if p.ibit {return p}
	switch lw >> 25 {
	case 0x20, 0x21: p.branch = .Uncond
	case 0x24, 0x25: p.branch = .Reg
	case 0x28, 0x29, 0x2c ..= 0x2f: p.branch = .Cond
	}
	// As vu_pair_info, plus flag readers that can run first.
	ud := upper_dest(uw)
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	touches := ud != 0 && (ft == ud || fs == ud)
	p.mode = .Slow
	switch lw >> 25 {
	case 0x00: if ud == 0 || ft != ud {p.mode = .Serial}
	case 0x01: if ud == 0 || fs != ud {p.mode = .Serial}
	case 0x04, 0x05, 0x08, 0x09, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f:
		p.mode = .Serial
	case 0x11: // FCSET: unless CLIP also writes the clip flags
		if uw & 0x7ff != 0x1ff {p.mode = .Serial}
	case 0x10, 0x12, 0x13, 0x1c, 0x18, 0x1a, 0x1b: // FCEQ/FCAND/FCOR/FCGET, FMEQ/FMAND/FMOR
		p.mode = .Lower_First
		p.mac_rd = lw >> 25 >= 0x18 && lw >> 25 <= 0x1b
	case 0x40:
		if lw & 63 < 0x3c {
			p.mode = .Serial
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x38 ..= 0x3a: if !touches {p.mode = .Serial} // only status (dead) is shared
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: p.mode = .Serial
		case: if !touches {p.mode = .Serial}
		}
	}
	if p.mode == .Slow {p.mac_rd = true} // vu_pair merges against the old flags
	return p
}

// Backward dataflow: MAC after pair n is live when a successor reads it
// before setting it, or control can leave compiled code.
@(private = "file")
mac_liveness :: proc(pairs: []Pair, ext: []bool) {
	n := len(pairs)
	live_in := make([]bool, n, context.temp_allocator)
	at :: proc(live_in, ext: []bool, pc: int) -> bool {
		i := pc / 8
		return i >= len(live_in) || (ext != nil && !ext[i]) ? true : live_in[i]
	}
	for changed := true; changed; {
		changed = false
		for i := n - 1; i >= 0; i -= 1 {
			p := &pairs[i]
			out := at(live_in, ext, (i + 1) * 8)
			if i > 0 && !pairs[i - 1].ibit { // a delay slot also goes to the target
				prev := pairs[i - 1]
				switch prev.branch {
				case .None:
				case .Reg: out = true
				case .Uncond, .Cond: out ||= at(live_in, ext, int(branch_target(prev.lw, u32(i - 1) * 8)))
				}
				if prev.ebit {out = true}
			}
			if p.ebit && i + 1 < n {pairs[i + 1].mac_live = true}
			out ||= p.mac_live
			inn := p.mac_rd || (!p.mac_wr && out)
			if out != p.mac_live || inn != live_in[i] {changed = true}
			p.mac_live, live_in[i] = out, inn
		}
	}
}

@(private = "file")
branch_target :: proc(lw, pc: u32) -> u32 {
	imm11 := i32(i16(u16(lw & 0x7ff) << 5) >> 5)
	return (pc + 8 + u32(imm11) * 8) & MASK
}

@(private = "file")
lanes :: proc(dest: u32) -> [4]bool {
	return {dest & 8 != 0, dest & 4 != 0, dest & 2 != 0, dest & 1 != 0}
}

// Which flags an upper op computes: none, MAC (micro mode, where it is
// live), or MAC and status (macro mode).
@(private = "file")
Flags :: enum u8 {None, Mac, Mac_Status}

// Emit the upper op, or nothing and slow when it is not specialized.
@(private = "file")
emit_upper :: proc(sb: ^strings.Builder, uw: u32, flags: Flags) -> (slow: bool) {
	dest := (uw >> 21) & 15
	ft, fs, fd := (uw >> 16) & 31, (uw >> 11) & 31, (uw >> 6) & 31
	fn := uw & 63
	bc := uw & 3
	Op :: enum {Add, Sub, Madd, Msub, Max, Mini, Mul}
	OPS := [Op]string {
		.Add  = "s + %s",
		.Sub  = "s - %s",
		.Madd = "v.acc.f + s * %s",
		.Msub = "v.acc.f - s * %s",
		.Max  = "vmax",
		.Mini = "vmin",
		.Mul  = "s * %s",
	}
	BC := [4]string{"sp(t.x)", "sp(t.y)", "sp(t.z)", "sp(t.w)"}
	// Write r to fd (or ACC), with the flags asked for. The add and
	// multiply family clamps its operands as the interpreter's vu_op does.
	arith :: proc(sb: ^strings.Builder, expr: string, dst: string, dest, fs, ft: u32, flags: Flags) {
		if dst == "" && flags == .None {return}
		e, _ := strings.replace_all(expr, "v.q", "fclamp(v.q)", context.temp_allocator)
		e, _ = strings.replace_all(e, "v.i", "fclamp(v.i)", context.temp_allocator)
		fmt.sbprintf(sb, "\t\t\t{{s := clamp4(vf[%d].f); ", fs)
		if strings.contains(expr, "t") {fmt.sbprintf(sb, "t := clamp4(vf[%d].f); ", ft)}
		fmt.sbprintf(sb, "x := clamp4(%s); ", e)
		if flags != .None {fmt.sbprintf(sb, "v.mac = mac4(x, 0x%x); ", dest)}
		if flags == .Mac_Status {fmt.sbprintf(sb, "put_status(v); ")}
		store(sb, dst, dest)
		end_block(sb)
	}
	vfd := fd == 0 ? "" : fmt.tprintf("vf[%d]", fd)
	if fn < 0x3c {
		op: Op
		b: string
		switch fn {
		case 0x00 ..= 0x1b:
			op = Op(fn >> 2)
			b = BC[bc]
		case 0x1c: op, b = .Mul, "sp(v.q)"
		case 0x1d: op, b = .Max, "sp(v.i)"
		case 0x1e: op, b = .Mul, "sp(v.i)"
		case 0x1f: op, b = .Mini, "sp(v.i)"
		case 0x20: op, b = .Add, "sp(v.q)"
		case 0x21: op, b = .Madd, "sp(v.q)"
		case 0x22: op, b = .Add, "sp(v.i)"
		case 0x23: op, b = .Madd, "sp(v.i)"
		case 0x24: op, b = .Sub, "sp(v.q)"
		case 0x25: op, b = .Msub, "sp(v.q)"
		case 0x26: op, b = .Sub, "sp(v.i)"
		case 0x27: op, b = .Msub, "sp(v.i)"
		case 0x28: op, b = .Add, "t"
		case 0x29: op, b = .Madd, "t"
		case 0x2a: op, b = .Mul, "t"
		case 0x2b: op, b = .Max, "t"
		case 0x2c: op, b = .Sub, "t"
		case 0x2d: op, b = .Msub, "t"
		case 0x2e: // OPMSUB
			arith(sb, "v.acc.f - [4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", vfd, 0xe, fs, ft, flags)
			return
		case 0x2f: op, b = .Mini, "t"
		case: return true
		}
		if op == .Max || op == .Mini {
			// The raw words, unclamped, and no flags: vmax in VU_HELPERS.
			if vfd == "" {return}
			fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].u; ", fs)
			if b != "sp(v.i)" {fmt.sbprintf(sb, "t := vf[%d].u; ", ft)}
			if b == "sp(v.i)" {b = "spu(transmute(u32)v.i)"}
			if strings.has_prefix(b, "sp(") {b = strings.concatenate({"spu(", b[3:]}, context.temp_allocator)}
			fmt.sbprintf(sb, "x := %s(s, %s); ", OPS[op], b)
			store(sb, vfd, dest, "u")
			end_block(sb)
			return
		}
		arith(sb, fmt.tprintf(OPS[op], b), vfd, dest, fs, ft, flags)
		return
	}
	sp := ((uw >> 4) & 0x7c) | (uw & 3)
	acc :: "v.acc"
	op: Op
	b: string
	switch sp {
	case 0x00 ..= 0x0f:
		op = Op(sp >> 2)
		b = BC[bc]
	case 0x10 ..= 0x13: // ITOF
		if ft == 0 {return}
		SCALE := [4]string{"1", "1.0 / 16", "1.0 / 4096", "1.0 / 32768"}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].i; x := clamp4([4]f32{{f32(s.x), f32(s.y), f32(s.z), f32(s.w)}} * sp(%s)); ",
			fs, SCALE[bc])
		store(sb, fmt.tprintf("vf[%d]", ft), dest)
		end_block(sb)
		return
	case 0x14 ..= 0x17: // FTOI
		if ft == 0 || dest == 0 {return}
		SCALE := [4]string{"1", "16", "4096", "32768"}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; ", fs)
		for on, k in lanes(dest) {
			if on {fmt.sbprintf(sb, "vf[%d].i[%d] = cvt_w(s[%d] * %s); ", ft, k, k, SCALE[bc])}
		}
		end_block(sb)
		return
	case 0x18 ..= 0x1b: op, b = .Mul, BC[bc]
	case 0x1c: op, b = .Mul, "sp(v.q)"
	case 0x1d: // ABS
		if ft == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; x := clamp4([4]f32{{abs(s.x), abs(s.y), abs(s.z), abs(s.w)}}); ", fs)
		store(sb, fmt.tprintf("vf[%d]", ft), dest)
		end_block(sb)
		return
	case 0x1e: op, b = .Mul, "sp(v.i)"
	case 0x1f: // CLIP
		fmt.sbprintfln(sb, "\t\t\tclip(v, vf[%d].f, vf[%d].f)", fs, ft)
		return
	case 0x20: op, b = .Add, "sp(v.q)"
	case 0x21: op, b = .Madd, "sp(v.q)"
	case 0x22: op, b = .Add, "sp(v.i)"
	case 0x23: op, b = .Madd, "sp(v.i)"
	case 0x24: op, b = .Sub, "sp(v.q)"
	case 0x25: op, b = .Msub, "sp(v.q)"
	case 0x26: op, b = .Sub, "sp(v.i)"
	case 0x27: op, b = .Msub, "sp(v.i)"
	case 0x28: op, b = .Add, "t"
	case 0x29: op, b = .Madd, "t"
	case 0x2a: op, b = .Mul, "t"
	case 0x2c: op, b = .Sub, "t"
	case 0x2d: op, b = .Msub, "t"
	case 0x2e: // OPMULA
		arith(sb, "[4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", acc, 0xe, fs, ft, flags)
		return
	case 0x2f: return // NOP
	case: return true
	}
	arith(sb, fmt.tprintf(OPS[op], b), acc, dest, fs, ft, flags)
	return
}

// VU0 macro instruction w (COP2 with CO set) as one statement for the EE
// recompiler, with the semantics of the interpreter's vu_op: a block binding
// VU0 as `v`, `vf` or `vi`, or "" for an op that does nothing. ok is false,
// with no code, for the ops left to the interpreter (VCALLMS and VCALLMSR,
// and the lower ops that touch P, R or other registers). The
// code needs VU_HELPERS and MACRO_HELPERS in its package and the runtime's
// vu as `vu`.
emit_macro :: proc(w: u32) -> (code: string, ok: bool) {
	sb := strings.builder_make(context.temp_allocator)
	fn := w & 63
	sp := ((w >> 4) & 0x7c) | (w & 3)
	bind := "v := &vu.vu0; vf := &v.vf; "
	flags := ""
	switch {
	case fn < 0x30 || (fn >= 0x3c && sp < 0x30):
		if emit_upper(&sb, w, .Mac_Status) {return}
	case fn < 0x3c:
		if fn > 0x35 || fn == 0x33 {return} // VCALLMS, VCALLMSR, and no op
		bind = "vi := &vu.vu0.vi; "
	case sp == 0x30 || sp == 0x31 || sp == 0x3b: // VMOVE, VMR32, VWAITQ
		bind = "vf := &vu.vu0.vf; "
	case sp == 0x38 || sp == 0x3a: // VDIV, VRSQRT
		flags = fmt.tprintf("div_flags(v, vf[%d].f[%d], vf[%d].f[%d]); ", (w >> 11) & 31, (w >> 21) & 3, (w >> 16) & 31, (w >> 23) & 3)
	case sp == 0x39: // VSQRT
		flags = fmt.tprintf("div_flags(v, 1, vf[%d].f[%d] < 0 ? 0 : 1); ", (w >> 16) & 31, (w >> 23) & 3)
	case sp >= 0x34 && sp <= 0x37: // VLQI, VSQI, VLQD, VSQD
		// VLQI with ft 0 or no dest lanes and VSQI with none never touch vf
		bind = "v := &vu.vu0; vf := &v.vf; vi := &v.vi; _ = vf; "
	case:
		return
	}
	if fn >= 0x30 && (fn < 0x3c || sp >= 0x30) {
		// The micro lower word (opcode 0x40) has the same fields. Its
		// fallback calls VU1's interpreter, never right for a macro op.
		if emit_lower(&sb, (w & 0x1ffffff) | 0x40 << 25, 0, "vu.VU0_MEM") {return "", false}
	}
	body := strings.trim_space(strings.to_string(sb))
	if body == "" {return "", true}
	return fmt.tprintf("{{%s%s%s}}", bind, flags, body), true
}

// Close a one-line block of "stmt; " statements without the last "; ",
// which -strict-style rejects.
@(private = "file")
end_block :: proc(sb: ^strings.Builder) {
	if strings.has_suffix(strings.to_string(sb^), "; ") {resize(&sb.buf, len(sb.buf) - 2)}
	fmt.sbprintln(sb, "}")
}

// Store the dest lanes of x into dst's field ("" discards).
@(private = "file")
store :: proc(sb: ^strings.Builder, dst: string, dest: u32, field := "f") {
	if dst == "" {return}
	if dest == 15 {
		fmt.sbprintf(sb, "%s.%s = x", dst, field)
		return
	}
	for on, k in lanes(dest) {
		if on {fmt.sbprintf(sb, "%s.%s[%d] = x[%d]; ", dst, field, k, k)}
	}
}

// Emit a non-branch lower op. mem names the VU's data memory size for mq.
@(private = "file")
emit_lower :: proc(sb: ^strings.Builder, lw, pc: u32, mem: string) -> (slow: bool) {
	dest := (lw >> 21) & 15
	ft, fs, fd := (lw >> 16) & 31, (lw >> 11) & 31, (lw >> 6) & 31
	it, is := ft & 15, fs & 15
	imm11 := u16(i16(u16(lw & 0x7ff) << 5) >> 5)
	imm15 := u16(((lw >> 10) & 0x7800) | (lw & 0x7ff))
	imm24 := lw & 0xffffff
	L := lanes(dest)
	copy_lanes :: proc(sb: ^strings.Builder, L: [4]bool, dst, src: string) {
		for on, k in L {
			if on {fmt.sbprintf(sb, "%s[%d] = %s[%d]; ", dst, k, src, k)}
		}
	}
	interp :: proc(sb: ^strings.Builder, lw, pc: u32) -> bool {
		fmt.sbprintfln(sb, "\t\t\tvu.vu1_lower(0x%08x, 0x%04x)", lw, pc)
		return true
	}
	switch lw >> 25 {
	case 0x00: // LQ
		if ft == 0 || dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x, %s); ", is, imm11, mem)
		copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q")
		end_block(sb)
	case 0x01: // SQ
		if dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x, %s); ", it, imm11, mem)
		copy_lanes(sb, L, "q", fmt.tprintf("vf[%d].u", fs))
		end_block(sb)
	case 0x04: // ILW: the last dest lane wins
		if it == 0 || dest == 0 {return}
		k := 3
		for !L[k] {k -= 1}
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(mq(v, vi[%d] + 0x%x, %s)[%d])", it, is, imm11, mem, k)
	case 0x05: // ISW
		if dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x, %s); x := u32(vi[%d]); ", is, imm11, mem, it)
		for on, k in L {
			if on {fmt.sbprintf(sb, "q[%d] = x; ", k)}
		}
		end_block(sb)
	case 0x08: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + 0x%x", it, is, imm15)} // IADDIU
	case 0x09: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] - 0x%x", it, is, imm15)} // ISUBIU
	case 0x10: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16(v.clip & 0xffffff == 0x%x)", imm24) // FCEQ
	case 0x11: fmt.sbprintfln(sb, "\t\t\tv.clip = 0x%x", imm24) // FCSET
	case 0x12: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16(v.clip & 0x%x != 0)", imm24) // FCAND
	case 0x13: fmt.sbprintfln(sb, "\t\t\tvi[1] = u16((v.clip | 0x%x) & 0xffffff == 0xffffff)", imm24) // FCOR
	case 0x18: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.mac & 0xffff == u32(vi[%d]))", it, is)} // FMEQ
	case 0x1a: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.mac) & vi[%d]", it, is)} // FMAND
	case 0x1b: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16((v.mac | u32(vi[%d])) & 0xffff == 0xffff)", it, is)} // FMOR
	case 0x1c: if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(v.clip & 0xfff)", it)} // FCGET
	case 0x40:
		if lw & 63 < 0x3c {
			switch lw & 63 {
			case 0x30: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x31: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] - vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x32: // IADDI: imm5 in the fd field
				imm := u16(i16(i8(u8(fd) << 3) >> 3))
				if ft != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] + 0x%x", ft & 15, fs & 15, imm)}
			case 0x34: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] & vi[%d]", fd & 15, fs & 15, ft & 15)}
			case 0x35: if fd != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = vi[%d] | vi[%d]", fd & 15, fs & 15, ft & 15)}
			case: return interp(sb, lw, pc)
			}
			return
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x30: // MOVE
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{r := vf[%d].u; ", fs)
			copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "r")
			end_block(sb)
		case 0x31: // MR32
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{r := vf[%d].u; ", fs)
			for on, k in L {
				if on {fmt.sbprintf(sb, "vf[%d].u[%d] = r[%d]; ", ft, k, (k + 1) & 3)}
			}
			end_block(sb)
		case 0x34, 0x36: // LQI, LQD
			fmt.sbprint(sb, "\t\t\t{")
			if lw & 3 == 2 {fmt.sbprintf(sb, "vi[%d] -= 1; ", is)}
			if ft != 0 && dest != 0 {
				fmt.sbprintf(sb, "q := mq(v, vi[%d], %s); ", is, mem)
				copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q")
			}
			if lw & 3 == 0 && is != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", is)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x35, 0x37: // SQI, SQD
			fmt.sbprint(sb, "\t\t\t{")
			if lw & 3 == 3 {fmt.sbprintf(sb, "vi[%d] -= 1; ", it)}
			if dest != 0 {
				fmt.sbprintf(sb, "q := mq(v, vi[%d], %s); ", it, mem)
				copy_lanes(sb, L, "q", fmt.tprintf("vf[%d].u", fs))
			}
			if lw & 3 == 1 && it != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", it)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x38: // DIV
			fmt.sbprintfln(sb, "\t\t\tv.q = fdiv(vf[%d].f[%d], vf[%d].f[%d])", fs, (lw >> 21) & 3, ft, (lw >> 23) & 3)
		case 0x39: // SQRT
			fmt.sbprintfln(sb, "\t\t\tv.q = math.sqrt(abs(vf[%d].f[%d]))", ft, (lw >> 23) & 3)
		case 0x3a: // RSQRT
			fmt.sbprintfln(sb, "\t\t\tv.q = frsqrt(vf[%d].f[%d], vf[%d].f[%d])", fs, (lw >> 21) & 3, ft, (lw >> 23) & 3)
		case 0x3b, 0x7b: // WAITQ, WAITP
		case 0x3c: // MTIR
			if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(vf[%d].u[%d])", it, fs, (lw >> 21) & 3)}
		case 0x3d: // MFIR
			if ft == 0 || dest == 0 {return}
			fmt.sbprintf(sb, "\t\t\t{{x := u32(i32(i16(vi[%d]))); ", is)
			for on, k in L {
				if on {fmt.sbprintf(sb, "vf[%d].u[%d] = x; ", ft, k)}
			}
			end_block(sb)
		case 0x68, 0x69: // XTOP (VU1 only), XITOP: from the VU's own VIF
			// Only VIF MSCAL sets TOP and ITOP, before it runs the program
			// synchronously, so they hold for the whole run.
			vif := mem == "vu.VU1_MEM" ? 1 : 0
			assert(vif == 1 || lw & 3 == 1, "vu: XTOP exists only on VU1")
			if it != 0 {fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(vu.vifs[%d].%s)", it, vif, lw & 3 == 0 ? "top" : "itop")}
		case 0x6c: fmt.sbprintfln(sb, "\t\t\tvu.vu1_xgkick(vi[%d])", is) // XGKICK
		case: return interp(sb, lw, pc)
		}
	case: return interp(sb, lw, pc)
	}
	return
}

// Emit a whole pair, without its branch. Counts the halves that call the
// interpreter in slow, by opcode.
@(private = "file")
emit_pair :: proc(sb: ^strings.Builder, p: Pair, pc: u32, slow: ^map[string]int) {
	// The keys outlive the temp allocator, which each program frees.
	count :: proc(slow: ^map[string]int, key: string) {
		if key not_in slow {slow[strings.clone(key)] = 0}
		slow[key] += 1
	}
	upper :: proc(sb: ^strings.Builder, p: Pair, slow: ^map[string]int) {
		if !emit_upper(sb, p.uw, p.mac_live ? .Mac : .None) {return}
		fmt.sbprintfln(sb, "\t\t\tvu.vu1_upper(0x%08x)", p.uw)
		fn := p.uw & 63
		if fn & 0x3c != 0x3c {
			count(slow, fmt.tprintf("upper %02x", fn))
		} else {
			count(slow, fmt.tprintf("upper special %02x", ((p.uw >> 4) & 0x7c) | (p.uw & 3)))
		}
	}
	lower :: proc(sb: ^strings.Builder, p: Pair, pc: u32, slow: ^map[string]int) {
		if !emit_lower(sb, p.lw, pc, "vu.VU1_MEM") {return}
		fn := p.lw & 63
		switch {
		case p.lw >> 25 != 0x40:
			count(slow, fmt.tprintf("lower %02x", p.lw >> 25))
		case fn < 0x3c:
			count(slow, fmt.tprintf("lower 40 %02x", fn))
		case:
			count(slow, fmt.tprintf("lower 40 special %02x", ((p.lw >> 4) & 0x7c) | (p.lw & 3)))
		}
	}
	if p.ibit { // the upper still reads the old I
		upper(sb, p, slow)
		fmt.sbprintfln(sb, "\t\t\tv.i = transmute(f32)u32(0x%08x)", p.lw)
		return
	}
	switch p.mode {
	case .Serial:
		upper(sb, p, slow)
		if p.branch == .None {lower(sb, p, pc, slow)}
	case .Lower_First:
		lower(sb, p, pc, slow)
		upper(sb, p, slow)
	case .Slow:
		fmt.sbprintfln(sb, "\t\t\tvu.vu1_pair(0x%08x, 0x%08x, 0x%04x)", p.uw, p.lw, pc)
		count(slow, "pair")
	}
}

// Emit a branch's condition into `tk` and its target into `tg`, plus the
// link register.
@(private = "file")
emit_branch :: proc(sb: ^strings.Builder, lw, pc: u32) {
	it, is := (lw >> 16) & 15, (lw >> 11) & 15
	switch lw >> 25 {
	case 0x20, 0x21, 0x24, 0x25: fmt.sbprintln(sb, "\t\t\ttk := true")
	case 0x28: fmt.sbprintfln(sb, "\t\t\ttk := vi[%d] == vi[%d]", it, is)
	case 0x29: fmt.sbprintfln(sb, "\t\t\ttk := vi[%d] != vi[%d]", it, is)
	case 0x2c: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) < 0", is)
	case 0x2d: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) > 0", is)
	case 0x2e: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) <= 0", is)
	case 0x2f: fmt.sbprintfln(sb, "\t\t\ttk := i16(vi[%d]) >= 0", is)
	}
	switch lw >> 25 {
	case 0x24, 0x25: fmt.sbprintfln(sb, "\t\t\ttg := u32(vi[%d]) * 8 & 0x%x", is, MASK)
	case: fmt.sbprintfln(sb, "\t\t\ttg: u32 = 0x%04x", branch_target(lw, pc))
	}
	if (lw >> 25 == 0x21 || lw >> 25 == 0x25) && it != 0 {
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = 0x%x", it, u16((pc + 16) / 8))
	}
}

@(private = "file")
emit_program :: proc(sb: ^strings.Builder, n: int, words: []u32, ext: []bool, slow: ^map[string]int) {
	pairs := make([]Pair, len(words) / 2, context.temp_allocator)
	for &p, i in pairs {p = classify(words[2 * i], words[2 * i + 1])}
	mac_liveness(pairs, ext)
	in_ext :: proc(ext: []bool, i: int) -> bool {return ext == nil || ext[i]}

	fmt.sbprintfln(sb, "run_%d :: proc(pc: u32, budget: ^int) -> (u32, vu.Vu1_Exit) {{", n)
	fmt.sbprintln(sb, "\tv := &vu.vu1")
	fmt.sbprintln(sb, "\tvf, vi := &v.vf, &v.vi")
	fmt.sbprintln(sb, "\t_, _ = vf, vi")
	fmt.sbprintln(sb, "\tpc := pc")
	fmt.sbprintln(sb, "\tfor {")
	fmt.sbprintln(sb, "\t\tswitch pc {")
	plain :: proc(p: Pair) -> bool {return !p.ebit && (p.ibit || p.branch == .None)}
	for p, i in pairs {
		if !in_ext(ext, i) {continue}
		pc := u32(i) * 8
		next := i + 1 < len(pairs) ? pairs[i + 1] : Pair{}
		fmt.sbprintfln(sb, "\t\tcase 0x%04x:", pc)
		branch := !p.ibit && p.branch != .None
		switch {
		case branch && (p.ebit || i + 1 >= len(pairs) || !plain(next)),
		     !branch && p.ebit && (i + 1 >= len(pairs) || !plain(next)):
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", pc)
		case branch:
			emit_pair(sb, p, pc, slow)
			emit_branch(sb, p.lw, pc)
			emit_pair(sb, next, pc + 8, slow)
			fmt.sbprintln(sb, "\t\t\tif tk {")
			fmt.sbprintln(sb, "\t\t\t\tbudget^ -= 1")
			fmt.sbprintln(sb, "\t\t\t\tif budget^ <= 0 {return tg, .Leave}")
			fmt.sbprintln(sb, "\t\t\t\tpc = tg")
			fmt.sbprintln(sb, "\t\t\t} else {")
			fmt.sbprintfln(sb, "\t\t\t\tpc = 0x%04x", (pc + 16) & MASK)
			fmt.sbprintln(sb, "\t\t\t}")
			fmt.sbprintln(sb, "\t\t\tcontinue")
		case p.ebit:
			emit_pair(sb, p, pc, slow)
			emit_pair(sb, next, pc + 8, slow)
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .End", (pc + 16) & MASK)
		case:
			emit_pair(sb, p, pc, slow)
			if i + 1 < len(pairs) && in_ext(ext, i + 1) {
				fmt.sbprintln(sb, "\t\t\tfallthrough")
			} else {
				fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", (pc + 8) & MASK)
			}
		}
	}
	fmt.sbprintln(sb, "\t\tcase:")
	fmt.sbprintln(sb, "\t\t\treturn pc, .Leave")
	fmt.sbprintln(sb, "\t\t}")
	fmt.sbprintln(sb, "\t}")
	fmt.sbprintln(sb, "}\n")
}

// One VU1 microprogram at micro address 0, compiled whole as run_<n>, as
// generate compiles a .vutext program (tests/vu_micro). The caller writes
// the package header and VU_HELPERS.
emit_micro :: proc(n: int, words: []u32) -> string {
	sb := strings.builder_make()
	slow: map[string]int
	emit_program(&sb, n, words, nil, &slow)
	return strings.to_string(sb)
}

// Write out_dir/vu1/code.odin (package vu1); runtime is the ps2 runtime's
// import path relative to out_dir. Returns the number of programs. Counts
// the pair halves that call the interpreter in slow, by opcode.
generate :: proc(img: mips.Image, out_dir, runtime, capture: string, slow: ^map[string]int) -> (programs: int, ok: bool) {
	progs := find_programs(img) or_return
	if capture != "" {load_capture(&progs, capture) or_return}
	sb := strings.builder_make()
	fmt.sbprintln(&sb, "// Generated by ps-recomp. Do not edit.")
	fmt.sbprintln(&sb, "package vu1\n")
	fmt.sbprintln(&sb, "import \"core:math\"")
	fmt.sbprintln(&sb, "import \"core:simd\"")
	fmt.sbprintfln(&sb, "import vu \"%s/vu\"\n", mips.import_path(runtime, 1))
	fmt.sbprintln(&sb, VU_HELPERS)
	fmt.sbprintln(&sb, "register :: proc() {")
	for p, n in progs {
		if p.ext == nil {
			fmt.sbprintfln(&sb, "\tvu.vu1_register(code_%d[:], run_%d)", n, n)
			continue
		}
		fmt.sbprint(&sb, "\tvu.vu1_register_ranges({")
		for r, k in ranges(p.ext) {
			fmt.sbprintf(&sb, "%s{{0x%04x, code_%d_%d[:]}}", k == 0 ? "" : ", ", r[0] * 8, n, k)
		}
		fmt.sbprintfln(&sb, "}, run_%d)", n)
	}
	fmt.sbprintln(&sb, "}\n")
	pairs := 0
	for p, n in progs {
		if p.ext == nil {
			emit_words(&sb, fmt.tprintf("code_%d", n), p.words[:])
			pairs += len(p.words) / 2
		}
		for r, k in ranges(p.ext) {
			emit_words(&sb, fmt.tprintf("code_%d_%d", n, k), p.words[r[0] * 2:r[1] * 2])
			pairs += r[1] - r[0]
		}
		emit_program(&sb, n, p.words[:], p.ext, slow)
		free_all(context.temp_allocator)
	}
	dir, _ := filepath.join({out_dir, "vu1"})
	os.make_directory(dir)
	path, _ := filepath.join({dir, "code.odin"})
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintln("cannot write", path, err)
		return
	}
	fmt.printfln("%d VU1 programs, %d pairs -> %s", len(progs), pairs, path)
	return len(progs), true
}

@(private = "file")
emit_words :: proc(sb: ^strings.Builder, name: string, words: []u32) {
	fmt.sbprintfln(sb, "@(rodata)\n%s := [%d]u32{{", name, len(words))
	for w, i in words {
		fmt.sbprintf(sb, i % 8 == 0 ? "\t0x%08x," : " 0x%08x,", w)
		if i % 8 == 7 || i == len(words) - 1 {fmt.sbprintln(sb)}
	}
	fmt.sbprintln(sb, "}\n")
}

// The runs of pairs in an extent, as [first, end) pair indices.
@(private = "file")
ranges :: proc(ext: []bool) -> [dynamic][2]int {
	rs := make([dynamic][2]int, context.temp_allocator)
	for i := 0; i < len(ext); {
		if !ext[i] {
			i += 1
			continue
		}
		j := i
		for j < len(ext) && ext[j] {j += 1}
		append(&rs, [2]int{i, j})
		i = j
	}
	return rs
}

// Programs from a VU1_CAPTURE file (ps2/vu/capture.odin): for each entry
// into each captured image, the pairs reachable from it. A JR or JALR ends
// an extent; its targets were captured as entries of their own. Extents
// with the same pairs at the same addresses compile once.
@(private = "file")
load_capture :: proc(progs: ^[dynamic]Prog, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("vu: cannot read", path, err)
		return false
	}
	IMAGE :: 16 << 10
	images: map[u64][]u32
	entries: map[u64][dynamic]u32
	seen: map[[2]u64]bool
	for pos := 0; pos < len(data); {
		if pos + 9 > len(data) {
			fmt.eprintfln("vu: %s: record at %d cut short", path, pos)
			return false
		}
		kind := data[pos]
		hash := u64(endian_u64(data[pos + 1:]))
		switch kind {
		case 'I':
			if pos + 9 + IMAGE > len(data) {
				fmt.eprintfln("vu: %s: image at %d cut short", path, pos)
				return false
			}
			if hash not_in images {
				w := make([]u32, IMAGE / 4)
				for &x, k in w {x = endian_u32(data[pos + 9 + k * 4:])}
				images[hash] = w
			}
			pos += 9 + IMAGE
		case 'E':
			if pos + 13 > len(data) {
				fmt.eprintfln("vu: %s: entry at %d cut short", path, pos)
				return false
			}
			pc := endian_u32(data[pos + 9:]) & MASK
			key := [2]u64{hash, u64(pc)}
			if key not_in seen {
				seen[key] = true
				if hash not_in entries {entries[hash] = {}}
				append(&entries[hash], pc)
			}
			pos += 13
		case:
			fmt.eprintfln("vu: %s: bad record %02x at %d", path, kind, pos)
			return false
		}
	}
	hashes := make([dynamic]u64, context.temp_allocator)
	for h in images {append(&hashes, h)}
	slice.sort(hashes[:])
	keys: map[string]bool
	for h in hashes {
		pcs := entries[h][:]
		slice.sort(pcs)
		words := make([dynamic]u32, IMAGE / 4)
		copy(words[:], images[h])
		for pc in pcs {
			ext := extent(words[:], pc)
			key := strings.builder_make()
			for r in ranges(ext) {
				fmt.sbprintf(&key, "%d:", r[0])
				for w in words[r[0] * 2:r[1] * 2] {fmt.sbprintf(&key, "%x,", w)}
			}
			if strings.to_string(key) in keys {
				strings.builder_destroy(&key)
				continue
			}
			keys[strings.to_string(key)] = true
			append(progs, Prog{words = words, ext = ext})
		}
	}
	return true
}

@(private = "file")
endian_u32 :: proc(b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}
@(private = "file")
endian_u64 :: proc(b: []u8) -> u64 {return u64(endian_u32(b)) | u64(endian_u32(b[4:])) << 32}

// The pairs control can reach from entry without leaving through a JR or
// JALR or an E bit: fallthrough, branch targets, and the return pair after
// BAL and JALR. A delay slot is included without following it.
@(private = "file")
extent :: proc(words: []u32, entry: u32) -> []bool {
	n := len(words) / 2
	ext := make([]bool, n)
	walked := make([]bool, n, context.temp_allocator)
	work := make([dynamic]int, context.temp_allocator)
	append(&work, int(entry / 8))
	for len(work) > 0 {
		i := pop(&work)
		if walked[i] {continue}
		walked[i], ext[i] = true, true
		p := classify(words[2 * i], words[2 * i + 1])
		next := (i + 1) % n
		branch := !p.ibit && p.branch != .None
		if !branch && !p.ebit {
			append(&work, next)
			continue
		}
		ext[next] = true // the delay slot
		if !branch || p.ebit {continue}
		after := (i + 2) % n
		op := p.lw >> 25
		switch p.branch {
		case .None:
		case .Uncond: append(&work, int(branch_target(p.lw, u32(i) * 8) / 8))
		case .Cond: append(&work, int(branch_target(p.lw, u32(i) * 8) / 8), after)
		case .Reg:
		}
		if op == 0x21 || op == 0x25 {append(&work, after)} // BAL, JALR return
	}
	return ext
}

// Inline versions of the interpreter's helpers (ps2/vu/vu.odin,
// ps2/cpu/alu.odin): a call into ps2 is never inlined across modules.
VU_HELPERS :: `sp :: #force_inline proc "contextless" (x: f32) -> [4]f32 {return {x, x, x, x}}

// fclamp on all four lanes: infinities and NaNs become the largest
// finite value, denormals zero, keeping the sign.
clamp4 :: #force_inline proc "contextless" (r: [4]f32) -> [4]f32 {
	u := transmute(#simd[4]u32)r
	e := u & 0x7f800000
	sign := u & 0x80000000
	u = simd.select(simd.lanes_eq(e, 0), sign, u)
	u = simd.select(simd.lanes_eq(e, 0x7f800000), sign | 0x7f7fffff, u)
	return transmute([4]f32)u
}

fclamp :: #force_inline proc "contextless" (x: f32) -> f32 {
	u := transmute(u32)x
	switch u & 0x7f800000 {
	case 0x7f800000: return transmute(f32)((u & 0x80000000) | 0x7f7fffff)
	case 0:          return transmute(f32)(u & 0x80000000)
	}
	return x
}

fdiv :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	if transmute(u32)b & 0x7f800000 == 0 {
		sign := (transmute(u32)a ~ transmute(u32)b) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(a / b)
}

frsqrt :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	s := math.sqrt(abs(b))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)a & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(a / s)
}

cvt_w :: #force_inline proc "contextless" (x: f32) -> i32 {
	u := transmute(u32)x
	if u & 0x7f800000 >= 0x4f000000 {
		return u & 0x80000000 != 0 ? min(i32) : max(i32)
	}
	return i32(x)
}

spu :: #force_inline proc "contextless" (x: u32) -> [4]u32 {return {x, x, x, x}}

// MAX and MINI as the interpreter's vu_op (ps2/vu vmax): the raw words in
// sign and magnitude order.
vmax :: #force_inline proc "contextless" (a, b: [4]u32) -> [4]u32 {
	ka, kb := transmute(#simd[4]i32)a, transmute(#simd[4]i32)b
	neg := simd.lanes_lt(ka & kb, 0)
	return transmute([4]u32)simd.select(neg, simd.min(ka, kb), simd.max(ka, kb))
}
vmin :: #force_inline proc "contextless" (a, b: [4]u32) -> [4]u32 {
	ka, kb := transmute(#simd[4]i32)a, transmute(#simd[4]i32)b
	neg := simd.lanes_lt(ka & kb, 0)
	return transmute([4]u32)simd.select(neg, simd.max(ka, kb), simd.min(ka, kb))
}

// Quadword n of v's data memory of size bytes (vu.VU0_MEM or vu.VU1_MEM),
// wrapping. Unchecked: the generated code passes vu.vu0 with VU0_MEM and
// vu.vu1 with VU1_MEM, vu_init sets each mem to an array of exactly that
// size, and the mask keeps the quadword inside it whatever vi holds.
mq :: #force_inline proc "contextless" (v: ^vu.Vu, n: u16, $size: u32) -> ^[4]u32 #no_bounds_check {
	return (^[4]u32)(&v.mem[(u32(n) * 16) & (size - 1)])
}

// MAC Z/S bits of the dest lanes of x. mac4 and clip are unchecked: k
// only runs over the loop's constant range, inside the [4]f32.
mac4 :: #force_inline proc "contextless" (x: [4]f32, dest: u32) -> u32 #no_bounds_check {
	mac: u32 = 0
	for k in 0 ..< 4 {
		u := transmute(u32)x[k]
		bit := u32(8) >> u32(k)
		mac |= u32(u << 1 == 0) * bit | (u >> 31) * (bit << 4)
	}
	return mac & (dest | dest << 4)
}

clip :: #force_inline proc "contextless" (v: ^vu.Vu, s, t: [4]f32) #no_bounds_check {
	lim := abs(t.w)
	f: u32 = 0
	for k in 0 ..< 3 {
		if s[k] > lim {f |= 1 << (2 * u32(k))}
		if s[k] < -lim {f |= 2 << (2 * u32(k))}
	}
	v.clip = ((v.clip << 6) | f) & 0xffffff
}
`

// The macro-mode helpers on top of VU_HELPERS.
MACRO_HELPERS :: `// Status from the MAC just written, as the interpreter's vu_put_flags: Z
// (bit 0) when any dest lane is zero, S (bit 1) when any is negative, each
// also sticky (bits 6 and 7); U and O (bits 2, 3) clear, the rest stay.
put_status :: #force_inline proc "contextless" (v: ^vu.Vu) {
	st := u32(v.mac & 0x0f != 0) | u32(v.mac & 0xf0 != 0) << 1
	v.status = (v.status &~ 0xf) | st | st << 6
}

// Status I (bit 4, 0/0) and D (bit 5, x/0) for a DIV-family op of a / b, as
// the interpreter's vu_div_flags, each also sticky (bits 10 and 11).
div_flags :: #force_inline proc "contextless" (v: ^vu.Vu, a, b: f32) {
	f: u32 = 0
	if b == 0 {f = a == 0 ? 0x10 : 0x20}
	v.status = (v.status &~ 0x30) | f | f << 6
}
`
