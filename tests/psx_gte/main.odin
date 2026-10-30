// GTE register moves as native code, run on every target in CI: mtc2, mfc2,
// lwc2 and swc2 (data registers) and ctc2 and cfc2 (control registers), the
// native backend's inline field stores and loads, with
// gte.gte_matrix_filter set and not, against gte.gte_write and gte.gte_read
// from the same GTE state, and a few registers against their values. And the
// inline NCLIP, AVSZ3 and AVSZ4 against gte.gte_cmd. The Odin backend's output for the same
// forms and for GTE commands: which call each names, an inline proc or the
// helper, and the inline ones against the helpers. And RTPS, RTPT and
// MVMVA against a plain reference, and the native MVMVA for every command
// word against gte.gte_cmd (ref.odin).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "ps:core"
import psx_native "ps:psx/native"
import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_gte: ")
	fmt.eprintfln(format, ..args)
	failed += 1
	if failed > 50 {
		fmt.eprintln("FAIL psx_gte: too many failures")
		os.exit(1)
	}
}

JR_RA :: 0x03e00008

// The forms, each on GTE register r with a0 as value or address and v0 as
// result.
Form :: enum {
	Mtc2, // r = a0
	Ctc2, // r + 32 = a0
	Lwc2, // r = the word at a0
	Mfc2, // v0 = r
	Cfc2, // v0 = r + 32
	Swc2, // the word at a0 = r
}

@(private = "file")
word :: proc(f: Form, r: u32) -> u32 {
	switch f {
	case .Mtc2:
		return 0x48800000 | 4 << 16 | r << 11
	case .Ctc2:
		return 0x48c00000 | 4 << 16 | r << 11
	case .Lwc2:
		return 0xc8000000 | 4 << 21 | r << 16
	case .Mfc2:
		return 0x48000000 | 2 << 16 | r << 11
	case .Cfc2:
		return 0x48400000 | 2 << 16 | r << 11
	case .Swc2:
		return 0xe8000000 | 4 << 21 | r << 16
	}
	return 0
}

@(private = "file")
build :: proc(at: u32, words: []u32) -> ^mips.Func {
	data := make([]u8, 4 * len(words), context.temp_allocator)
	for w, n in words {
		data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
	f := mips.func_make(at, at + u32(len(data)))
	mips.discover(r3000.RULES, {base = at, data = data}, f, nil)
	return f
}

// Sign edges in each half, then a fixed pseudo-random run.
@(rodata, private = "file")
EDGES := [?]u32 {
	0, 1, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fff7fff, 0x80008000, 0xffff7fff, 0x7fffffff,
	0x80000000, 0x8000ffff, 0xffff8000, 0xffff0000, 0xffffffff, 0x12345678, 0x9abcdef0,
}

@(private = "file")
seed: u32 = 0x2545f491

@(private = "file")
next :: proc() -> u32 {
	seed ~= seed << 13
	seed ~= seed >> 17
	seed ~= seed << 5
	return seed
}

@(private = "file")
values :: proc() -> [64]u32 {
	v: [64]u32
	for &x, k in v {
		x = EDGES[k] if k < len(EDGES) else next()
	}
	return v
}

// A GTE state of the k'th value pattern: one edge in every word, or noise.
@(private = "file")
gte_state :: proc(k: int) -> gte.Gte_State {
	words: [size_of(gte.Gte_State) / 4]u32
	for &w in words {
		w = EDGES[k] if k < len(EDGES) else next()
	}
	return transmute(gte.Gte_State)words
}

ADDR :: 0x80010000

// NCLIP (COP2 command 0x06), AVSZ3 (0x2d) and AVSZ4 (0x2e).
NCLIP :: 0x4a000006
AVSZ3 :: 0x4b58002d
AVSZ4 :: 0x4b68002e

// SX/SY halves: sign edges (bit 15 set reads as negative), then noise.
@(rodata, private = "file")
EDGES16 := [?]u32{0, 1, 0xffff, 0x7fff, 0x8000, 0x7ffe, 0x8001, 0x4000, 0xc000}

@(private = "file")
half :: proc() -> u32 {
	n := next()
	return EDGES16[n % len(EDGES16)] if n & 0x100 != 0 else n >> 16
}

// The first call into package gte in Odin source: its name and first
// argument.
@(private = "file")
emitted_gte_call :: proc(src: string) -> (name: string, arg: u32) {
	at := strings.index(src, "gte.")
	if at < 0 {
		return "", 0
	}
	rest := src[at + 4:]
	open := strings.index_byte(rest, '(')
	if open < 0 {
		return "", 0
	}
	name = rest[:open]
	rest = rest[open + 1:]
	end := strings.index_any(rest, ",)")
	if end < 0 {
		return name, 0
	}
	v, _ := strconv.parse_uint(rest[:end])
	return name, u32(v)
}

main :: proc() {
	arch := native.Arch(core.NATIVE_ARCH)
	na := native.make_asm(arch, r3000.native_ram(), r3000.NATIVE_CACHED[:])
	funcs := make([dynamic]native.Blob_Func)
	at := u32(0x80002000)
	for f in Form {
		for r in u32(0) ..< 32 {
			words := [?]u32{word(f, r), 0, JR_RA, 0, 0}
			append(&funcs, native.Blob_Func{at, r3000.native_func(&na, build(at, words[:]), nil, 1)})
			at += 0x20
			free_all(context.temp_allocator)
		}
	}
	// NCLIP, AVSZ3 and AVSZ4 inline, then commands called by the native
	// code: RTPS and RTPT through their own procs, NCDS through gte_cmd.
	// Then MVMVA inline, every command word (ref_native_mvmva).
	NATIVE_CMDS :: [?]u32{NCLIP, AVSZ3, AVSZ4, 0x4a180001, 0x4a200430, 0x4ae80413}
	for w in NATIVE_CMDS {
		words := [?]u32{w, 0, JR_RA, 0, 0}
		append(&funcs, native.Blob_Func{at, r3000.native_func(&na, build(at, words[:]), nil, 1)})
		at += 0x20
		free_all(context.temp_allocator)
	}
	mvmva_first := len(funcs)
	for n in u32(0) ..< 256 {
		words := [?]u32{mvmva_word(n), 0, JR_RA, 0, 0}
		append(&funcs, native.Blob_Func{at, r3000.native_func(&na, build(at, words[:]), nil, 1)})
		at += 0x20
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&na, funcs[:], {}), psx_native.imports())
	if err != "" {
		fmt.eprintln("FAIL psx_gte: native_load:", err)
		os.exit(1)
	}
	run :: proc(code: core.Native_Code, f: Form, r: u32) {
		k := int(f) * 32 + int(r)
		(cast(proc())rawptr(code.base + uintptr(code.funcs[k].off)))()
	}
	cpu.next_event = max(u64)
	vals := values()
	checks := 0
	for k in 0 ..< len(vals) {
		start := gte_state(k)
		for f in Form {
			for r in u32(0) ..< 32 {
				g := r + 32 if f == .Ctc2 || f == .Cfc2 else r
				switch f {
				case .Mtc2, .Ctc2, .Lwc2:
					for v in vals {
						gte.gte_load(start)
						gte.gte_write(g, v)
						want := gte.gte_save()
						gte.gte_load(start)
						cpu.state.r[4] = v
						if f == .Lwc2 {
							cpu.sw(ADDR, v)
							cpu.state.r[4] = ADDR
						}
						run(code, f, r)
						if gte.gte_save() != want {fail("%v %d = %08x from state %d: GTE state differs", f, r, v, k)}
						checks += 1
					}
				case .Mfc2, .Cfc2, .Swc2:
					gte.gte_load(start)
					want := gte.gte_read(g)
					cpu.state.r[2], cpu.state.r[4] = 0x5a5a5a5a, ADDR
					cpu.sw(ADDR, 0xa5a5a5a5)
					run(code, f, r)
					got := cpu.lw(ADDR) if f == .Swc2 else cpu.state.r[2]
					if got != want {fail("%v %d from state %d: %08x, want %08x", f, r, k, got, want)}
					if gte.gte_save() != start {fail("%v %d from state %d: GTE state changed", f, r, k)}
					checks += 1
				}
			}
		}
	}
	// Rotation and translation writes take gte.gte_matrix_filter's value
	// while it is set.
	gte.gte_matrix_filter = proc(r, v: u32) -> u32 {return v ~ r * 0x01010101}
	for k in 0 ..< len(vals) {
		start := gte_state(k)
		for r in u32(0) ..< 8 {
			for v in vals {
				gte.gte_load(start)
				gte.gte_write(r + 32, v)
				want := gte.gte_save()
				gte.gte_load(start)
				cpu.state.r[4] = v
				run(code, .Ctc2, r)
				if gte.gte_save() != want {fail("filtered ctc2 %d = %08x from state %d: GTE state differs", r, v, k)}
				checks += 1
			}
		}
	}
	gte.gte_matrix_filter = nil
	// Register w = v reads back as want from register r, by the helpers
	// and natively: LZCR of 0 and -1 is 32, FLAG bit 31 sums bits 13-18
	// and 23-30 and no others, H reads sign-extended, IRGB fills IR1-3.
	Reg_Case :: struct {
		w, v, r, want: u32,
	}
	reg_cases := [?]Reg_Case {
		{30, 0, 31, 32},
		{30, 0xffffffff, 31, 32},
		{30, 1, 31, 31},
		{30, 0xfffffffe, 31, 31},
		{30, 0x40000000, 31, 1},
		{30, 0x80000000, 31, 1},
		{63, 0x00001000, 63, 0x00001000},
		{63, 0x00002000, 63, 0x80002000},
		{63, 0x00040000, 63, 0x80040000},
		{63, 0x00080000, 63, 0x00080000},
		{63, 0x00780000, 63, 0x00780000},
		{63, 0x00800000, 63, 0x80800000},
		{63, 0x40000000, 63, 0xc0000000},
		{63, 0x80000fff, 63, 0},
		{63, 0xffffffff, 63, 0xfffff000},
		{58, 0x8000, 58, 0xffff8000},
		{58, 0x12347fff, 58, 0x7fff},
		{28, 0x7fff, 29, 0x7fff},
		{28, 0x8421, 9, 0x80},
	}
	for c in reg_cases {
		gte.gte_load(gte_state(0))
		gte.gte_write(c.w, c.v)
		if got := gte.gte_read(c.r); got != c.want {
			fail("gte_write(%d, %08x): gte_read(%d) %08x, want %08x", c.w, c.v, c.r, got, c.want)
		}
		gte.gte_load(gte_state(0))
		cpu.state.r[4] = c.v
		run(code, .Ctc2 if c.w >= 32 else .Mtc2, c.w % 32)
		run(code, .Cfc2 if c.r >= 32 else .Mfc2, c.r % 32)
		if got := cpu.state.r[2]; got != c.want {
			fail("native %d = %08x: %d reads %08x, want %08x", c.w, c.v, c.r, got, c.want)
		}
		checks += 1
	}
	// NCLIP over SXY halves; every FLAG outcome (fits, above, below) must
	// show up.
	outcomes: map[u32]int
	defer delete(outcomes)
	for k in 0 ..< 20000 {
		start := gte_state(k % len(vals))
		gte.gte_load(start)
		for r in u32(12) ..< 15 {gte.gte_write(r, half() | half() << 16)}
		start = gte.gte_save()
		gte.gte_cmd(0x06)
		want := gte.gte_save()
		outcomes[gte.state.flag] += 1
		gte.gte_load(start)
		(cast(proc())rawptr(code.base + uintptr(code.funcs[len(Form) * 32].off)))()
		if got := gte.gte_save(); got != want {
			w := transmute(gte.Gte)want
			fail("nclip sxy %v: mac0 %08x flag %08x, want %08x %08x", w.sxy, u32(gte.state.mac[0]), gte.state.flag, u32(w.mac[0]), w.flag)
		}
		checks += 1
	}
	for f in ([?]u32{0, 0x80010000, 0x80008000}) {
		if outcomes[f] == 0 {fail("nclip: no case with flag %08x", f)}
	}
	// AVSZ3 and AVSZ4 from noise and from 16-bit SZ and scales; OTZ held
	// at 0 and at 0xffff (FLAG bit 18), OTZ in range, and MAC0 above and
	// below i32 must all show up.
	Avsz_Outcome :: enum {
		Held_Low,
		Held_High,
		In_Range,
		Above,
		Below,
	}
	avsz_seen: [Avsz_Outcome]int
	for w, n in ([?]u32{AVSZ3, AVSZ4}) {
		for k in 0 ..< 20000 {
			gte.gte_load(gte_state(k % len(vals)))
			if k & 1 != 0 {
				for r in u32(16) ..< 20 {gte.gte_write(r, half() >> (next() % 16))}
				gte.gte_write(61, half())
				gte.gte_write(62, half())
			}
			start := gte.gte_save()
			gte.gte_cmd(w & 0x1ffffff)
			want := gte.gte_save()
			wg := transmute(gte.Gte)want
			if wg.flag & (1 << 18) == 0 {
				avsz_seen[.In_Range] += 1
			} else {
				avsz_seen[.Held_Low if wg.otz == 0 else .Held_High] += 1
			}
			if wg.flag & (1 << 16) != 0 {avsz_seen[.Above] += 1}
			if wg.flag & (1 << 15) != 0 {avsz_seen[.Below] += 1}
			gte.gte_load(start)
			(cast(proc())rawptr(code.base + uintptr(code.funcs[len(Form) * 32 + 1 + n].off)))()
			if got := gte.gte_save(); got != want {
				g := transmute(gte.Gte)got
				fail("native %08x from state %d: mac0 %08x otz %04x flag %08x, want %08x %04x %08x", w, k, u32(g.mac[0]), g.otz, g.flag, u32(wg.mac[0]), wg.otz, wg.flag)
			}
			checks += 1
		}
	}
	for c, o in avsz_seen {
		if c == 0 {fail("avsz: no case %v", o)}
	}
	native_cmds := NATIVE_CMDS
	for w, n in native_cmds[1:] {
		for k in 0 ..< 2000 {
			gte.gte_load(gte_state(k % len(vals)))
			for r in u32(12) ..< 20 {gte.gte_write(r, half() | half() << 16)}
			start := gte.gte_save()
			gte.gte_cmd(w & 0x1ffffff)
			want := gte.gte_save()
			gte.gte_load(start)
			(cast(proc())rawptr(code.base + uintptr(code.funcs[len(Form) * 32 + 1 + n].off)))()
			if gte.gte_save() != want {fail("native %08x from state %d: GTE state differs", w, k)}
			checks += 1
		}
	}
	// The Odin backend's output for the same forms names gte.data_read and
	// gte.data_write for the data registers, gte.ctrl_read and
	// gte.ctrl_write for the control registers, all inline in a port. Each
	// named call runs against the helper.
	for f in Form {
		for r in u32(0) ..< 32 {
			code := [?]u32{word(f, r), 0, JR_RA, 0, 0}
			b := strings.builder_make(context.temp_allocator)
			r3000.emit_func(build(0x80002000, code[:]), &b, "f", nil, 1)
			name, reg := emitted_gte_call(strings.to_string(b))
			ctl := f == .Ctc2 || f == .Cfc2
			g := r + 32 if ctl else r
			write := f == .Mtc2 || f == .Ctc2 || f == .Lwc2
			want_name := write ? (ctl ? "ctrl_write" : "data_write") : (ctl ? "ctrl_read" : "data_read")
			if name != want_name || reg != g {
				fail("odin %v %d: calls gte.%s(%d), want gte.%s(%d)", f, r, name, reg, want_name, g)
			}
			for k in 0 ..< len(vals) {
				start := gte_state(k)
				gte.gte_load(start)
				if !write {
					got := gte.ctrl_read(g) if ctl else gte.data_read(g)
					if want := gte.gte_read(g); got != want {
						fail("odin %v %d from state %d: %08x, want %08x", f, r, k, got, want)
					}
					checks += 1
					continue
				}
				for v in vals {
					gte.gte_load(start)
					gte.gte_write(g, v)
					want := gte.gte_save()
					gte.gte_load(start)
					if ctl {gte.ctrl_write(g, v)} else {gte.data_write(g, v)}
					if gte.gte_save() != want {fail("odin %v %d = %08x from state %d: GTE state differs", f, r, v, k)}
					checks += 1
				}
			}
			free_all(context.temp_allocator)
		}
	}
	// NCLIP, AVSZ3 and AVSZ4 name their inline procs, RTPS, RTPT and MVMVA
	// their own procs with the command word, NCDS gte_cmd; all but gte_cmd
	// run against gte_cmd. Both shifts and lm settings, and every MVMVA
	// matrix, vector and translation field.
	Cmd_Case :: struct {
		w:     u32,
		name:  string,
		whole: bool, // takes the command word
		run:   proc(cmd: u32),
	}
	cmds := [?]Cmd_Case {
		{NCLIP, "cmd_nclip", false, proc(_: u32) {gte.cmd_nclip()}},
		{0x4a00002d, "cmd_avsz3", false, proc(_: u32) {gte.cmd_avsz3()}},
		{0x4a00002e, "cmd_avsz4", false, proc(_: u32) {gte.cmd_avsz4()}},
		{0x4a180001, "cmd_rtps", true, gte.cmd_rtps},
		{0x4a100401, "cmd_rtps", true, gte.cmd_rtps},
		{0x4a280030, "cmd_rtpt", true, gte.cmd_rtpt},
		{0x4a200430, "cmd_rtpt", true, gte.cmd_rtpt},
		{0x4a486012, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a480012, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a49e012, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a4a6412, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a4ec012, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a43a412, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4a4da012, "cmd_mvmva", true, gte.cmd_mvmva},
		{0x4ae80413, "gte_cmd", true, nil},
	}
	for c in cmds {
		code := [?]u32{c.w, 0, JR_RA, 0, 0}
		b := strings.builder_make(context.temp_allocator)
		r3000.emit_func(build(0x80002000, code[:]), &b, "f", nil, 1)
		name, arg := emitted_gte_call(strings.to_string(b))
		if name != c.name || arg != (c.whole ? c.w & 0x1ffffff : 0) {
			fail("odin %08x: calls gte.%s(%#x), want gte.%s", c.w, name, arg, c.name)
		}
		free_all(context.temp_allocator)
		if c.run == nil {
			continue
		}
		for k in 0 ..< 2000 {
			gte.gte_load(gte_state(k % len(vals)))
			for r in u32(12) ..< 20 {gte.gte_write(r, half() | half() << 16)}
			start := gte.gte_save()
			gte.gte_cmd(c.w & 0x1ffffff)
			want := gte.gte_save()
			gte.gte_load(start)
			c.run(c.w & 0x1ffffff)
			if gte.gte_save() != want {fail("odin %08x from state %d: GTE state differs", c.w, k)}
			checks += 1
		}
	}
	checks += ref_check()
	checks += ref_native_mvmva(code, mvmva_first)
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_gte %v: %d checks", arch, checks)
}
