// The VU1 microprograms of an EE program's .vutext compiled to Odin, as
// <out>/vu1/code.odin, and captured VU0 microprograms as <out>/vu0/code.odin.
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
// vu0_capture and vu1_capture options name VU0_CAPTURE and VU1_CAPTURE files
// recorded from a run (the runtime's vu/capture.odin). VU0 microcode comes
// only from a capture. Each captured entry into each captured micro
// image becomes a program holding only the pairs reachable from that entry:
// fallthrough and branch targets, stopping at a JR/JALR (whose captured
// targets are entries of their own) and after an E bit. Its code is
// registered as ranges of micro memory, which the runtime compares against
// the live micro memory before running it; a pair no program covers runs in
// the interpreter.
//
// On VU1, MAC flags are computed only where a later FMAND/FMEQ/FMOR or an
// exit can see them. Status flags are never computed: no program reads them
// (no FSEQ/FSAND/FSOR/FSSET), and the EE cannot read VU1 status. On VU0 the
// EE reads MAC and status with CFC2 after a program, so both are always
// computed, as for macro instructions.
//
// The same upper ops, and the register-only lower ops, also serve the EE
// recompiler as VU0 macro instructions (emit_macro), where CFC2 can read MAC
// and status at any time, so both are always computed.
//
// Which programs there are, and what is known of their pairs, is
// program.odin's; this file writes them as Odin.
package vu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../mips"

// Each unit's data memory size, for mq.
@(private = "file", rodata)
MEM := [Unit]string {
	.VU0 = "vu.VU0_MEM",
	.VU1 = "vu.VU1_MEM",
}

// -define:VU_CLAMP_ELIDE=false clamps every operand, as the interpreter.
VU_CLAMP_ELIDE :: #config(VU_CLAMP_ELIDE, true)

// What straight-line code knows of the VF registers. lanes: the lanes of
// each (dest bits: x 8, y 4, z 2, w 1) holding a value clamp4 leaves alone;
// an operand read only from those lanes skips its clamp4. clamped: the
// local c<r>_<n> of the case body holding clamp4(vf[r].f), n, or 0; a
// later operand vf[r] reads it instead of clamping again.
@(private = "file")
Known :: struct {
	lanes:   [32]u8,
	clamped: [32]int,
	n:       int, // the locals declared, for unique names
	nested:  bool, // in a block, whose locals the case body cannot see
}

// The lanes every pair entered from a jump, a call or a resume knows: vf0
// is always (0, 0, 0, 1).
@(private = "file")
KNOWN_NONE :: [32]u8{0 = 15}

// Forget all but vf0 and the locals' names.
@(private = "file")
forget :: proc(known: ^Known) {
	known.lanes = KNOWN_NONE
	known.clamped = {}
}

// vf[r]'s dest lanes were written: no longer known, nor clamped in a local.
@(private = "file")
overwrite :: proc(known: ^Known, r, dest: u32) {
	if known == nil {return}
	known.lanes[r] &~= u8(dest)
	known.clamped[r] = 0
}

@(private = "file")
lanes :: proc(dest: u32) -> [4]bool {
	return {dest & 8 != 0, dest & 4 != 0, dest & 2 != 0, dest & 1 != 0}
}

// Which flags an upper op computes: none, MAC (micro mode, where it is
// live), or MAC and status (macro mode).
@(private)
Flags :: enum u8 {None, Mac, Mac_Status}

// Emit the upper op, or nothing and slow when it is not specialized.
// known, when not nil, is updated for the registers written and elides
// clamps of operands it covers.
@(private = "file")
emit_upper :: proc(sb: ^strings.Builder, uw: u32, flags: Flags, known: ^Known) -> (slow: bool) {
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
	// multiply family clamps its operands as the interpreter's vu_op does,
	// except the lanes read (sl of fs, tl of ft) known clamped, and clamps
	// each other operand once per case body.
	arith :: proc(sb: ^strings.Builder, expr: string, dst: string, dest, fs, ft, sl, tl: u32, flags: Flags, known: ^Known) {
		if dst == "" && flags == .None {return}
		operand :: proc(sb: ^strings.Builder, known: ^Known, r, l: u32) -> string {
			if known == nil {return fmt.tprintf("clamp4(vf[%d].f)", r)}
			if u32(known.lanes[r]) & l == l {return fmt.tprintf("vf[%d].f", r)}
			if known.clamped[r] == 0 {
				if known.nested {return fmt.tprintf("clamp4(vf[%d].f)", r)}
				known.n += 1
				known.clamped[r] = known.n
				fmt.sbprintfln(sb, "\t\t\tc%d_%d := clamp4(vf[%d].f)", r, known.n, r)
			}
			return fmt.tprintf("c%d_%d", r, known.clamped[r])
		}
		e, _ := strings.replace_all(expr, "v.q", "fclamp(v.q)", context.temp_allocator)
		e, _ = strings.replace_all(e, "v.i", "fclamp(v.i)", context.temp_allocator)
		s := operand(sb, known, fs, sl)
		t := strings.contains(expr, "t") ? operand(sb, known, ft, tl) : ""
		fmt.sbprintf(sb, "\t\t\t{{s := %s; ", s)
		if t != "" {fmt.sbprintf(sb, "t := %s; ", t)}
		fmt.sbprintf(sb, "x := clamp4(%s); ", e)
		if flags != .None {fmt.sbprintf(sb, "v.mac = mac4(x, 0x%x); ", dest)}
		if flags == .Mac_Status {fmt.sbprintf(sb, "put_status(v); ")}
		store(sb, dst, dest)
		end_block(sb)
	}
	// fd's dest lanes now hold a clamp4 result.
	wrote :: proc(known: ^Known, fd, dest: u32) {
		if known == nil || fd == 0 {return}
		known.lanes[fd] |= u8(dest)
		known.clamped[fd] = 0
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
			arith(sb, "v.acc.f - [4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", vfd, 0xe, fs, ft, 0xe, 0xe, flags, known)
			wrote(known, fd, 0xe)
			return
		case 0x2f: op, b = .Mini, "t"
		case: return true
		}
		if op == .Max || op == .Mini {
			// The raw words, unclamped, and no flags: vmax in VU_HELPERS.
			// Each lane is one of the operands' lanes, so it is known when
			// both are.
			if vfd == "" {return}
			if known != nil {
				kt: u8 = 0 // v.i is never known
				if b == "t" {kt = known.lanes[ft]} else if fn < 0x1c && known.lanes[ft] & (8 >> bc) != 0 {kt = 15}
				k := u8(dest) & known.lanes[fs] & kt
				overwrite(known, fd, dest)
				known.lanes[fd] |= k
			}
			fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].u; ", fs)
			if b != "sp(v.i)" {fmt.sbprintf(sb, "t := vf[%d].u; ", ft)}
			if b == "sp(v.i)" {b = "spu(transmute(u32)v.i)"}
			if strings.has_prefix(b, "sp(") {b = strings.concatenate({"spu(", b[3:]}, context.temp_allocator)}
			fmt.sbprintf(sb, "x := %s(s, %s); ", OPS[op], b)
			store(sb, vfd, dest, "u")
			end_block(sb)
			return
		}
		tl: u32 = b == "t" ? dest : 0
		if fn < 0x1c {tl = 8 >> bc}
		arith(sb, fmt.tprintf(OPS[op], b), vfd, dest, fs, ft, dest, tl, flags, known)
		wrote(known, fd, dest)
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
		wrote(known, ft, dest)
		return
	case 0x14 ..= 0x17: // FTOI
		if ft == 0 || dest == 0 {return}
		SCALE := [4]string{"1", "16", "4096", "32768"}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; ", fs)
		for on, k in lanes(dest) {
			if on {fmt.sbprintf(sb, "vf[%d].i[%d] = cvt_w(s[%d] * %s); ", ft, k, k, SCALE[bc])}
		}
		end_block(sb)
		overwrite(known, ft, dest)
		return
	case 0x18 ..= 0x1b: op, b = .Mul, BC[bc]
	case 0x1c: op, b = .Mul, "sp(v.q)"
	case 0x1d: // ABS
		if ft == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{s := vf[%d].f; x := clamp4([4]f32{{abs(s.x), abs(s.y), abs(s.z), abs(s.w)}}); ", fs)
		store(sb, fmt.tprintf("vf[%d]", ft), dest)
		end_block(sb)
		wrote(known, ft, dest)
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
		arith(sb, "[4]f32{s.y * t.z, s.z * t.x, s.x * t.y, 0}", acc, 0xe, fs, ft, 0xe, 0xe, flags, known)
		return
	case 0x2f: return // NOP
	case: return true
	}
	tl: u32 = b == "t" ? dest : 0
	if sp < 0x10 || (sp >= 0x18 && sp < 0x1c) {tl = 8 >> bc}
	arith(sb, fmt.tprintf(OPS[op], b), acc, dest, fs, ft, dest, tl, flags, known)
	return
}

// VU0 macro instruction w (COP2 with CO set) as one statement for the EE
// recompiler, with the semantics of the interpreter's vu_op: a block binding
// VU0 as `v`, `vf` or `vi`, a call, or "" for an op that does nothing. ok is
// false, with no code, for the ops left to the interpreter (the lower ops
// that touch P, R or other registers). The
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
		if emit_upper(&sb, w, .Mac_Status, nil) {return}
	case fn == 0x38: return fmt.tprintf("vu.vu0_call_micro(0x%x)", ((w >> 6) & 0x7fff) * 8), true // VCALLMS
	case fn == 0x39: return "vu.vu0_call_micro(vu.vu0.cmsar * 8)", true // VCALLMSR
	case fn < 0x3c:
		if fn > 0x35 || fn == 0x33 {return} // no op
		bind = "vi := &vu.vu0.vi; "
	case sp == 0x30 || sp == 0x31 || sp == 0x3b: // VMOVE, VMR32, VWAITQ
		bind = "vf := &vu.vu0.vf; "
	case sp == 0x3c || sp == 0x3d: // VMTIR, VMFIR
		bind = "vf := &vu.vu0.vf; vi := &vu.vu0.vi; "
	case sp == 0x38 || sp == 0x3a: // VDIV, VRSQRT
		flags = fmt.tprintf("div_flags(v, vf[%d].f[%d], vf[%d].f[%d]); ", (w >> 11) & 31, (w >> 21) & 3, (w >> 16) & 31, (w >> 23) & 3)
	case sp == 0x39: // VSQRT
		flags = fmt.tprintf("div_flags(v, 1, vf[%d].f[%d] < 0 ? 0 : 1); ", (w >> 16) & 31, (w >> 23) & 3)
	case sp >= 0x34 && sp <= 0x37, sp == 0x3e, sp == 0x3f: // VLQI, VSQI, VLQD, VSQD, VILWR, VISWR
		// VLQI with ft 0 or no dest lanes and VSQI with none never touch vf
		bind = "v := &vu.vu0; vf := &v.vf; vi := &v.vi; _ = vf; "
	case:
		return
	}
	if fn >= 0x30 && (fn < 0x3c || sp >= 0x30) {
		// The micro lower word (opcode 0x40) has the same fields. Its
		// fallback calls VU0's micro-mode interpreter, never right for a
		// macro op.
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

// The unit emit_lower's interpreter fallback calls, from its mem.
@(private = "file", thread_local)
lower_unit: int

// Emit a non-branch lower op. mem names the VU's data memory size for mq.
@(private = "file")
emit_lower :: proc(sb: ^strings.Builder, lw, pc: u32, mem: string) -> (slow: bool) {
	lower_unit = mem == MEM[.VU0] ? 0 : 1
	dest := (lw >> 21) & 15
	ft, fs, fd := (lw >> 16) & 31, (lw >> 11) & 31, (lw >> 6) & 31
	it, is := ft & 15, fs & 15
	fsf := (lw >> 21) & 3
	imm11 := u16(i16(u16(lw & 0x7ff) << 5) >> 5)
	imm15 := u16(((lw >> 10) & 0x7800) | (lw & 0x7ff))
	imm24 := lw & 0xffffff
	L := lanes(dest)
	// Lane k of src to lane k of dst for the dest lanes; all four as one
	// whole-array copy.
	copy_lanes :: proc(sb: ^strings.Builder, L: [4]bool, dst, src: string) {
		if L == {true, true, true, true} {
			fmt.sbprintf(sb, "%s = %s; ", dst, src)
			return
		}
		for on, k in L {
			if on {fmt.sbprintf(sb, "%s[%d] = %s[%d]; ", dst, k, src, k)}
		}
	}
	// ILW and ILWR at address addr: the last dest lane wins.
	ilw :: proc(sb: ^strings.Builder, L: [4]bool, it: u32, addr, mem: string) {
		if it == 0 || L == {} {return}
		k := 3
		for !L[k] {k -= 1}
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = u16(mq(v, %s, %s)[%d])", it, addr, mem, k)
	}
	// ISW and ISWR at address addr.
	isw :: proc(sb: ^strings.Builder, L: [4]bool, it: u32, addr, mem: string) {
		if L == {} {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, %s, %s); x := u32(vi[%d]); ", addr, mem, it)
		for on, k in L {
			if on {fmt.sbprintf(sb, "q[%d] = x; ", k)}
		}
		end_block(sb)
	}
	efu :: proc(sb: ^strings.Builder, fs: u32, p: string) {
		fmt.sbprintfln(sb, "\t\t\t{{s := clamp4(vf[%d].f); v.p = %s}", fs, p)
	}
	interp :: proc(sb: ^strings.Builder, lw, pc: u32) -> bool {
		fmt.sbprintfln(sb, "\t\t\tvu.vu%d_lower(0x%08x, 0x%04x)", lower_unit, lw, pc)
		return true
	}
	// XTOP and XGKICK exist only on VU1: VU0's interpreter stops on them.
	if lower_unit == 0 && lw >> 25 == 0x40 && lw & 0x3c == 0x3c {
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x68, 0x6c: return interp(sb, lw, pc)
		}
	}
	switch lw >> 25 {
	case 0x00: // LQ
		if ft == 0 || dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x, %s); ", is, imm11, mem)
		copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q^")
		end_block(sb)
	case 0x01: // SQ
		if dest == 0 {return}
		fmt.sbprintf(sb, "\t\t\t{{q := mq(v, vi[%d] + 0x%x, %s); ", it, imm11, mem)
		copy_lanes(sb, L, "q^", fmt.tprintf("vf[%d].u", fs))
		end_block(sb)
	case 0x04: ilw(sb, L, it, fmt.tprintf("vi[%d] + 0x%x", is, imm11), mem) // ILW
	case 0x05: isw(sb, L, it, fmt.tprintf("vi[%d] + 0x%x", is, imm11), mem) // ISW
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
				copy_lanes(sb, L, fmt.tprintf("vf[%d].u", ft), "q^")
			}
			if lw & 3 == 0 && is != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", is)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x35, 0x37: // SQI, SQD
			fmt.sbprint(sb, "\t\t\t{")
			if lw & 3 == 3 {fmt.sbprintf(sb, "vi[%d] -= 1; ", it)}
			if dest != 0 {
				fmt.sbprintf(sb, "q := mq(v, vi[%d], %s); ", it, mem)
				copy_lanes(sb, L, "q^", fmt.tprintf("vf[%d].u", fs))
			}
			if lw & 3 == 1 && it != 0 {fmt.sbprintf(sb, "vi[%d] += 1; ", it)}
			fmt.sbprintln(sb, "vi[0] = 0}")
		case 0x38: // DIV
			fmt.sbprintfln(sb, "\t\t\tv.q = fdiv(vf[%d].f[%d], vf[%d].f[%d])", fs, (lw >> 21) & 3, ft, (lw >> 23) & 3)
		case 0x39: // SQRT
			fmt.sbprintfln(sb, "\t\t\tv.q = math.sqrt(abs(fclamp(vf[%d].f[%d])))", ft, (lw >> 23) & 3)
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
		case 0x3e: ilw(sb, L, it, fmt.tprintf("vi[%d]", is), mem) // ILWR
		case 0x3f: isw(sb, L, it, fmt.tprintf("vi[%d]", is), mem) // ISWR
		case 0x6c: fmt.sbprintfln(sb, "\t\t\tvu.vu1_xgkick(vi[%d])", is) // XGKICK
		case 0x64: // MFP: no flags, clamped as the interpreter's put_raw
			if ft == 0 || dest == 0 {return}
			fmt.sbprint(sb, "\t\t\t{p := fclamp(v.p); ")
			for on, k in L {
				if on {fmt.sbprintf(sb, "vf[%d].f[%d] = p; ", ft, k)}
			}
			end_block(sb)
		// The EFU, as the interpreter: P written at once, the operand
		// clamped, the sums in the same order.
		case 0x70: efu(sb, fs, "fclamp(s.x * s.x + s.y * s.y + s.z * s.z)") // ESADD
		case 0x71: efu(sb, fs, "fdiv(1, s.x * s.x + s.y * s.y + s.z * s.z)") // ERSADD
		case 0x72: efu(sb, fs, "math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)") // ELENG
		case 0x73: efu(sb, fs, "frsqrt(1, s.x * s.x + s.y * s.y + s.z * s.z)") // ERLENG
		case 0x74: efu(sb, fs, "math.atan(fdiv(s.y, s.x))") // EATANxy
		case 0x75: efu(sb, fs, "math.atan(fdiv(s.z, s.x))") // EATANxz
		case 0x76: efu(sb, fs, "fclamp(s.x + s.y + s.z + s.w)") // ESUM
		case 0x78: efu(sb, fs, fmt.tprintf("math.sqrt(abs(s[%d]))", fsf)) // ESQRT
		case 0x79: efu(sb, fs, fmt.tprintf("frsqrt(1, s[%d])", fsf)) // ERSQRT
		case 0x7a: efu(sb, fs, fmt.tprintf("fdiv(1, s[%d])", fsf)) // ERCPR
		case 0x7c: efu(sb, fs, fmt.tprintf("math.sin(s[%d])", fsf)) // ESIN
		case 0x7d: efu(sb, fs, fmt.tprintf("math.atan(s[%d])", fsf)) // EATAN
		case 0x7e: efu(sb, fs, fmt.tprintf("fclamp(math.exp(-s[%d]))", fsf)) // EEXP
		case: return interp(sb, lw, pc)
		}
	case: return interp(sb, lw, pc)
	}
	return
}

// Whether lower op lw can write a VF register (its ft). Lists the ops that
// cannot, so an op not listed counts as a writer.
@(private = "file")
lower_writes_vf :: proc(lw: u32) -> bool {
	switch lw >> 25 {
	case 0x01, 0x04, 0x05, 0x08, 0x09, 0x10 ..= 0x18, 0x1a ..= 0x1c, 0x20 ..= 0x2f: return false
	case 0x40:
		if lw & 0x3c != 0x3c {return false}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x35, 0x37 ..= 0x3c, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x70 ..= 0x76, 0x78 ..= 0x7e: return false
		}
	}
	return true
}

// Emit pair p at pc, without its branch. Counts the halves that call the
// interpreter in slow, by opcode. known, when not nil, tracks the clamped
// lanes past it.
@(private = "file")
emit_pair :: proc(sb: ^strings.Builder, p: Pair, pc: u32, unit: Unit, slow: ^map[string]int, known: ^Known) {
	// The keys outlive the temp allocator, which each program frees.
	count :: proc(slow: ^map[string]int, key: string) {
		if key not_in slow {slow[strings.clone(key)] = 0}
		slow[key] += 1
	}
	// VU0 computes status. A DIV-family lower sets it too, and as vu_pair
	// its write replaces the upper's when it changes status at all.
	merge := unit == .VU0 && !p.ibit && p.mode != .Slow && p.lw >> 25 == 0x40 && p.lw & 0x3c == 0x3c
	merge &&= ((p.lw >> 4) & 0x7c) | (p.lw & 3) >= 0x38 && ((p.lw >> 4) & 0x7c) | (p.lw & 3) <= 0x3a
	upper :: proc(sb: ^strings.Builder, p: Pair, unit: Unit, merge: bool, slow: ^map[string]int, known: ^Known) {
		defer if merge {fmt.sbprintln(sb, "\t\t\tust := v.status\n\t\t\tv.status = st0")}
		flags := Flags.Mac_Status
		if unit == .VU1 {flags = p.mac_live ? .Mac : .None}
		if !emit_upper(sb, p.uw, flags, known) {return}
		if known != nil {forget(known)}
		fmt.sbprintfln(sb, "\t\t\tvu.vu%d_upper(0x%08x)", int(unit), p.uw)
		fn := p.uw & 63
		if fn & 0x3c != 0x3c {
			count(slow, fmt.tprintf("upper %02x", fn))
		} else {
			count(slow, fmt.tprintf("upper special %02x", ((p.uw >> 4) & 0x7c) | (p.uw & 3)))
		}
	}
	lower :: proc(sb: ^strings.Builder, p: Pair, pc: u32, unit: Unit, merge: bool, slow: ^map[string]int, known: ^Known) {
		if !emit_lower(sb, p.lw, pc, MEM[unit]) {
			if lower_writes_vf(p.lw) {overwrite(known, (p.lw >> 16) & 31, (p.lw >> 21) & 15)}
			if !merge {return}
			// DIV and RSQRT fs.fsf / ft.ftf, SQRT ft.ftf, as emit_macro
			ft, fs := (p.lw >> 16) & 31, (p.lw >> 11) & 31
			if p.lw & 3 == 1 {
				fmt.sbprintfln(sb, "\t\t\tdiv_flags(v, 1, vf[%d].f[%d] < 0 ? 0 : 1)", ft, (p.lw >> 23) & 3)
			} else {
				fmt.sbprintfln(sb, "\t\t\tdiv_flags(v, vf[%d].f[%d], vf[%d].f[%d])", fs, (p.lw >> 21) & 3, ft, (p.lw >> 23) & 3)
			}
			fmt.sbprintln(sb, "\t\t\tif v.status == st0 {v.status = ust}")
			return
		}
		if known != nil {forget(known)}
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
		upper(sb, p, unit, false, slow, known)
		fmt.sbprintfln(sb, "\t\t\tv.i = transmute(f32)u32(0x%08x)", p.lw)
		return
	}
	if merge {fmt.sbprintln(sb, "\t\t\t{\n\t\t\tst0 := v.status")}
	defer if merge {fmt.sbprintln(sb, "\t\t\t}")}
	if known != nil && merge {known.nested = true}
	defer if known != nil {known.nested = false}
	switch p.mode {
	case .Serial:
		upper(sb, p, unit, merge, slow, known)
		if p.branch == .None {lower(sb, p, pc, unit, merge, slow, known)}
	case .Lower_First:
		lower(sb, p, pc, unit, merge, slow, known)
		upper(sb, p, unit, merge, slow, known)
	case .Hazard:
		// As vu_pair: the lower reads the upper's dest from before the
		// upper, and its own write to it, if any, wins unless it leaves the
		// register as it was. A block, as an E-bit pair and its successor
		// share a case.
		ud := upper_dest(p.uw)
		fmt.sbprintln(sb, "\t\t\t{")
		if known != nil {known.nested = true}
		fmt.sbprintfln(sb, "\t\t\tsaved := vf[%d]", ud)
		upper(sb, p, unit, merge, slow, known)
		fmt.sbprintfln(sb, "\t\t\tresult := vf[%d]", ud)
		fmt.sbprintfln(sb, "\t\t\tvf[%d] = saved", ud)
		lower(sb, p, pc, unit, merge, slow, known)
		if (p.lw >> 16) & 31 == ud { // every lower VF write goes to ft
			fmt.sbprintfln(sb, "\t\t\tif vf[%d].q == saved.q {{vf[%d] = result}}", ud, ud)
		} else {
			fmt.sbprintfln(sb, "\t\t\tvf[%d] = result", ud)
		}
		fmt.sbprintln(sb, "\t\t\t}")
		if ud != 0 {overwrite(known, ud, 15)} // either half's value
	case .Slow:
		fmt.sbprintfln(sb, "\t\t\tvu.vu%d_pair(0x%08x, 0x%08x, 0x%04x)", int(unit), p.uw, p.lw, pc)
		count(slow, "pair")
		if known != nil {forget(known)}
	}
}

// Emit a branch's condition into `tk` and its target into `tg`, plus the
// link register.
@(private = "file")
emit_branch :: proc(sb: ^strings.Builder, lw, pc, mask: u32) {
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
	case 0x24, 0x25: fmt.sbprintfln(sb, "\t\t\ttg := u32(vi[%d]) * 8 & 0x%x", is, mask)
	case: fmt.sbprintfln(sb, "\t\t\ttg: u32 = 0x%04x", branch_target(lw, pc, mask))
	}
	if (lw >> 25 == 0x21 || lw >> 25 == 0x25) && it != 0 {
		fmt.sbprintfln(sb, "\t\t\tvi[%d] = 0x%x", it, u16((pc + 16) / 8))
	}
}

@(private = "file")
emit_program :: proc(sb: ^strings.Builder, n: int, words: []u32, ext: []bool, entries: []u32, unit: Unit, slow: ^map[string]int) {
	mask := MASK[unit]
	pairs, target := analyze(words, ext, entries, unit)
	in_ext :: proc(ext: []bool, i: int) -> bool {return ext == nil || ext[i]}
	// A pair reached only by falling through from one whose known lanes
	// are not KNOWN_NONE gets no case label, so the lanes carry into it.
	// Without entries (emit_micro's default) every pair keeps its label.
	known := Known{lanes = KNOWN_NONE}
	k := VU_CLAMP_ELIDE && entries != nil ? &known : nil
	fell := false // the previous pair falls through, its fallthrough unwritten

	fmt.sbprintfln(sb, "run_%d :: proc(pc: u32, budget: ^int) -> (u32, vu.Vu_Exit) {{", n)
	fmt.sbprintfln(sb, "\tv := &vu.vu%d", int(unit))
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
		if !fell || k == nil || target[i] || known.lanes == KNOWN_NONE {
			if fell {fmt.sbprintln(sb, "\t\t\tfallthrough")}
			fmt.sbprintfln(sb, "\t\tcase 0x%04x:", pc)
			forget(&known)
		}
		fell = false
		branch := !p.ibit && p.branch != .None
		switch {
		case branch && (p.ebit || i + 1 >= len(pairs) || !plain(next)),
		     !branch && p.ebit && (i + 1 >= len(pairs) || !plain(next)):
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", pc)
		case branch:
			emit_pair(sb, p, pc, unit, slow, k)
			emit_branch(sb, p.lw, pc, mask)
			emit_pair(sb, next, pc + 8, unit, slow, k)
			fmt.sbprintln(sb, "\t\t\tif tk {")
			fmt.sbprintln(sb, "\t\t\t\tbudget^ -= 1")
			fmt.sbprintln(sb, "\t\t\t\tif budget^ <= 0 {return tg, .Leave}")
			fmt.sbprintln(sb, "\t\t\t\tpc = tg")
			fmt.sbprintln(sb, "\t\t\t} else {")
			fmt.sbprintfln(sb, "\t\t\t\tpc = 0x%04x", (pc + 16) & mask)
			fmt.sbprintln(sb, "\t\t\t}")
			fmt.sbprintln(sb, "\t\t\tcontinue")
		case p.ebit:
			emit_pair(sb, p, pc, unit, slow, k)
			emit_pair(sb, next, pc + 8, unit, slow, k)
			fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .End", (pc + 16) & mask)
		case:
			emit_pair(sb, p, pc, unit, slow, k)
			if i + 1 < len(pairs) && in_ext(ext, i + 1) {
				fell = true
			} else {
				fmt.sbprintfln(sb, "\t\t\treturn 0x%04x, .Leave", (pc + 8) & mask)
			}
		}
	}
	fmt.sbprintln(sb, "\t\tcase:")
	fmt.sbprintln(sb, "\t\t\treturn pc, .Leave")
	fmt.sbprintln(sb, "\t\t}")
	fmt.sbprintln(sb, "\t}")
	fmt.sbprintln(sb, "}\n")
}

// One microprogram for unit at micro address 0, compiled whole as run_<n>,
// as generate compiles a .vutext program (tests/vu_micro). The caller writes
// the package header and VU_HELPERS, and for VU0 MACRO_HELPERS. Counts the
// pair halves that call the interpreter in slow, by opcode. With entries, it
// is compiled as a captured image entered only there, eliding clamps as
// VU_CLAMP_ELIDE says.
emit_micro :: proc(n: int, words: []u32, unit: Unit, slow: ^map[string]int, entries: []u32 = nil) -> string {
	sb := strings.builder_make()
	emit_program(&sb, n, words, nil, entries, unit, slow)
	return strings.to_string(sb)
}

// Write out_dir/vu<unit>/code.odin (package vu0 or vu1); runtime is the ps2
// runtime's import path relative to out_dir. Returns the number of programs.
// Counts the pair halves that call the interpreter in slow, by opcode. VU0
// has programs only from a capture: without one it writes nothing.
generate :: proc(img: mips.Image, out_dir, runtime, capture: string, unit: Unit, slow: ^map[string]int) -> (programs: int, ok: bool) {
	if unit == .VU0 && capture == "" {return 0, true}
	progs := load_programs(img, capture, unit) or_return
	u := int(unit)
	sb := strings.builder_make()
	fmt.sbprintln(&sb, "// Generated by ps-recomp. Do not edit.")
	fmt.sbprintfln(&sb, "package vu%d\n", u)
	fmt.sbprintln(&sb, "import \"core:math\"")
	fmt.sbprintln(&sb, "import \"core:simd\"")
	fmt.sbprintfln(&sb, "import vu \"%s/vu\"\n", mips.import_path(runtime, 1))
	fmt.sbprintln(&sb, VU_HELPERS)
	if unit == .VU0 {fmt.sbprintln(&sb, MACRO_HELPERS)}
	fmt.sbprintln(&sb, "register :: proc() {")
	for p, n in progs {
		if p.ext == nil {
			fmt.sbprintfln(&sb, "\tvu.vu1_register(code_%d[:], run_%d)", n, n)
			continue
		}
		fmt.sbprintf(&sb, "\tvu.vu%d_register_ranges({{", u)
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
		emit_program(&sb, n, p.words[:], p.ext, p.entries, unit, slow)
		free_all(context.temp_allocator)
	}
	dir, _ := filepath.join({out_dir, fmt.tprintf("vu%d", u)})
	os.make_directory(dir)
	path, _ := filepath.join({dir, "code.odin"})
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintln("cannot write", path, err)
		return
	}
	fmt.printfln("%d VU%d programs, %d pairs -> %s", len(progs), u, pairs, path)
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

// fdiv and frsqrt clamp their operands first, as cpu.fdiv and cpu.frsqrt.
fdiv :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	x, y := fclamp(a), fclamp(b)
	if transmute(u32)y & 0x7f800000 == 0 {
		sign := (transmute(u32)x ~ transmute(u32)y) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(x / y)
}

frsqrt :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	x := fclamp(a)
	s := math.sqrt(abs(fclamp(b)))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)x & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(x / s)
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
// size, and the mask keeps the quadword inside it whatever vi holds. size
// is not a $ parameter: with -use-separate-modules Odin puts a polymorphic
// instance in a module of its own, where the callers cannot inline it.
// For the same reason mq is here and not in the runtime's vu package.
mq :: #force_inline proc "contextless" (v: ^vu.Vu, n: u16, size: u32) -> ^[4]u32 #no_bounds_check {
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
