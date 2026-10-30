// Static coverage of the PS1 backends, run on every target in CI: every
// R3000 primary, SPECIAL, REGIMM, COP0 and COP2 encoding class, with a few
// field values each, goes through the Odin backend (r3000.emit_func) and
// the native one (r3000.native_func) as the function [w, jr ra, nop]. A
// word hands off when its code calls a helper to do the work rather than
// doing it inline:
//
//   emit    the function calls a cpu. or gte. procedure not declared
//           #force_inline in FILES (read from the repository root, as CI
//           runs the test); a called name declared in neither form fails.
//   native  the function makes a host call through an import slot, for
//           X64_SysV (`call [rip+slot]`) and Arm64 (the slot's adrp and
//           ldr into x16, then `blr x16`), assembled only; both must call
//           the same helpers. Data imports and the shared load and store
//           slow routines are not calls of the word.
//
// Calls the function makes without the word ([nop, jr ra, nop]) are taken
// out. Neither backend leaves a word to the interpreter: an unknown one is
// cpu.bad_insn, counted as not an instruction, and both must agree on
// which. Each handoff must be listed in ALLOWED with its reason, and each
// entry must still occur. Out of scope: control transfers (branches,
// jumps, jr and jalr, skipped here) and the dynamic fallbacks behind them,
// cpu.call's call_slow and cpu.jump_unknown, which the FALLBACK_COUNT
// census in tests/psx_fallback covers; "0 left" says nothing of those.
//
//   odin run tests/psx_cover -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_cover: ")
	fmt.eprintfln(format, ..args)
	failed += 1
}

JR_RA :: 0x03e00008

// The sources declaring the procedures emitted code calls, by package.
FILES :: [?][2]string {
	{"cpu", "psx/cpu/bus.odin"},
	{"cpu", "psx/cpu/cpu.odin"},
	{"cpu", "psx/cpu/fallback.odin"},
	{"cpu", "psx/cpu/trace.odin"},
	{"gte", "psx/gte/gte.odin"},
}

Backend :: enum {
	Emit,
	X64,
	Arm64,
}
Backends :: bit_set[Backend]
NATIVE :: Backends{.X64, .Arm64}

Allowed :: struct {
	match:    proc(w: u32) -> bool,
	backends: Backends,
	helper:   string,
	reason:   string,
}

// The handoffs there are on purpose.
ALLOWED := [?]Allowed {
	{proc(w: u32) -> bool {return w >> 26 == 0 && w & 0x3f == 0x0c}, {.Emit} + NATIVE, "cpu.syscall", "SYSCALL: the HLE BIOS call"},
	{proc(w: u32) -> bool {return w >> 26 == 0 && w & 0x3f == 0x0d}, {.Emit} + NATIVE, "cpu.brk", "BREAK: an HLE report"},
	{proc(w: u32) -> bool {return w >> 21 == 0x204}, {.Emit} + NATIVE, "cpu.mtc0", "MTC0: an SR or Cause write can raise a pending interrupt"},
	{proc(w: u32) -> bool {return w >> 21 == 0x210 && w & 0x3f == 0x10}, {.Emit} + NATIVE, "cpu.rfe", "RFE: the SR pop can unmask a pending interrupt"},
	{proc(w: u32) -> bool {return w >> 26 == 0x22}, {.Emit} + NATIVE, "cpu.lwl", "LWL unfused: lower fuses the pairs, a lone one is cold"},
	{proc(w: u32) -> bool {return w >> 26 == 0x26}, {.Emit} + NATIVE, "cpu.lwr", "LWR unfused: lower fuses the pairs, a lone one is cold"},
	{proc(w: u32) -> bool {return w >> 26 == 0x2a}, {.Emit} + NATIVE, "cpu.swl", "SWL unfused: lower fuses the pairs, a lone one is cold"},
	{proc(w: u32) -> bool {return w >> 26 == 0x2e}, {.Emit} + NATIVE, "cpu.swr", "SWR unfused: lower fuses the pairs, a lone one is cold"},
	{proc(w: u32) -> bool {return gte_cmd(w, 0x01)}, {.Emit} + NATIVE, "gte.cmd_rtps", "RTPS: its own proc, given the command word"},
	{proc(w: u32) -> bool {return gte_cmd(w, 0x30)}, {.Emit} + NATIVE, "gte.cmd_rtpt", "RTPT: its own proc, given the command word"},
	{proc(w: u32) -> bool {return gte_cmd(w, 0x12)}, {.Emit}, "gte.cmd_mvmva", "MVMVA: its own proc, given the command word (native code runs it inline)"},
	{proc(w: u32) -> bool {
			fn := w & 0x3f
			return w >> 25 == 0x25 && fn != 0x01 && fn != 0x30 && fn != 0x12 && fn != 0x06 && fn != 0x2d && fn != 0x2e
		}, {.Emit} + NATIVE, "gte.gte_cmd", "the other GTE commands: the generic command helper"},
	{proc(w: u32) -> bool {return w >> 21 == 0x246 && w >> 11 & 31 <= 7}, NATIVE, "gte.gte_write", "CTC2 32-39: the matrix filter hook, called only when one is set"},
}

@(private = "file")
gte_cmd :: proc(w, fn: u32) -> bool {
	return w >> 25 == 0x25 && w & 0x3f == fn
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

// The words: each encoding class at a few register and immediate values.
@(private = "file")
words :: proc() -> []u32 {
	REGS :: [?][3]u32{{4, 5, 2}, {4, 5, 0}, {0, 5, 2}, {4, 0, 2}, {4, 4, 4}} // rs, rt, rd
	IMMS :: [?]u32{0, 1, 3, 0x7fff, 0x8000, 0xffff}
	out: [dynamic]u32
	for r in REGS {
		// SPECIAL, at two shift amounts
		for fn in u32(0) ..< 64 {
			for sa in ([?]u32{0, 7}) {append(&out, r[0] << 21 | r[1] << 16 | r[2] << 11 | sa << 6 | fn)}
		}
		// REGIMM and the primary ops but COP0 and COP2, rt = rd
		for op in u32(1) ..< 64 {
			if op == 16 || op == 18 {continue}
			for imm in IMMS {append(&out, op << 26 | r[0] << 21 | r[2] << 16 | imm)}
		}
		for rt in u32(0) ..< 32 {append(&out, 1 << 26 | r[0] << 21 | rt << 16 | 4)}
	}
	// COP0: every rs at a few rd and fn; RFE is rs 16, fn 16
	for rs in u32(0) ..< 32 {
		for rd in ([?]u32{0, 8, 12, 13, 14, 15}) {
			for fn in ([?]u32{0, 1, 2, 6, 8, 16}) {append(&out, 16 << 26 | rs << 21 | 2 << 16 | rd << 11 | fn)}
		}
	}
	// COP2: the moves at every register, each command with sf, lm and the
	// MVMVA fields, LWC2 and SWC2
	for rs in u32(0) ..< 16 {
		for rd in u32(0) ..< 32 {append(&out, 18 << 26 | rs << 21 | 4 << 16 | rd << 11)}
	}
	for fn in u32(0) ..< 64 {
		for bits in ([?]u32{0, 1 << 19, 1 << 10, 0x1e000}) {append(&out, 0x4a000000 | bits | fn)}
	}
	for rt in u32(0) ..< 32 {append(&out, 0x32 << 26 | 4 << 21 | rt << 16 | 8, 0x3a << 26 | 4 << 21 | rt << 16 | 8)}
	slice.sort(out[:])
	return slice.unique(out[:])
}

// name: whether it is declared #force_inline, for each top-level procedure
// of FILES, as "pkg.name".
@(private = "file")
declarations :: proc() -> map[string]bool {
	decls: map[string]bool
	for f in FILES {
		data, err := os.read_entire_file(f[1], context.allocator)
		if err != nil {
			fail("read %s: %v (run from the repository root)", f[1], err)
			continue
		}
		for l in strings.split_lines(string(data)) {
			k := strings.index(l, " :: ")
			if k <= 0 || !is_ident(l[:k]) {continue}
			rest := l[k + 4:]
			switch {
			case strings.has_prefix(rest, "#force_inline proc"):
				decls[fmt.aprintf("%s.%s", f[0], l[:k])] = true
			case strings.has_prefix(rest, "proc"):
				decls[fmt.aprintf("%s.%s", f[0], l[:k])] = false
			}
		}
	}
	return decls
}

@(private = "file")
is_ident :: proc(s: string) -> bool {
	for c in s {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {return false}
	}
	return true
}

// The cpu. and gte. procedures the Odin code calls.
@(private = "file")
emit_calls :: proc(code: string) -> [dynamic]string {
	calls: [dynamic]string
	for p := 0; p < len(code); p += 1 {
		if p > 0 && is_ident(code[p - 1:p]) {continue}
		if !strings.has_prefix(code[p:], "cpu.") && !strings.has_prefix(code[p:], "gte.") {continue}
		n := p + 4
		for n < len(code) && is_ident(code[n:n + 1]) {n += 1}
		if n < len(code) && code[n] == '(' {append(&calls, code[p:n])}
		p = n - 1
	}
	return calls
}

// The imports the native code from offset from calls, its import
// references from first on. On Arm64 every blr x16 must be such a call.
@(private = "file")
native_calls :: proc(a: ^native.Asm, from, first: int) -> [dynamic]string {
	calls: [dynamic]string
	if a.arch == .Arm64 {
		for at := from; at + 4 <= len(a.code); at += 4 {
			if (^u32le)(&a.code[at])^ != 0xd63f0200 {continue}
			found := false
			for k in first ..< len(a.imp_refs) {
				if a.imp_refs[k].at == at - 8 {found = true}
			}
			if !found {fail("arm64 blr x16 at %x without an import slot load before it", at)}
		}
	}
	for k in first ..< len(a.imp_refs) {
		at := a.imp_refs[k].at
		call: bool
		switch a.arch {
		case .X64_SysV, .X64_Win:
			call = a.code[at - 2] == 0xff && a.code[at - 1] == 0x15
		case .Arm64:
			// at is the adrp; blr x16 follows the ldr
			call = at + 12 <= len(a.code) && (^u32le)(&a.code[at + 8])^ == 0xd63f0200
		}
		if call {append(&calls, a.imports[a.imp_refs[k].target])}
	}
	return calls
}

// calls less one of each of base's.
@(private = "file")
without :: proc(calls: [dynamic]string, base: []string) -> []string {
	out := slice.clone_to_dynamic(calls[:])
	for b in base {
		if k, ok := slice.linear_search(out[:], b); ok {ordered_remove(&out, k)}
	}
	return out[:]
}

main :: proc() {
	decls := declarations()
	na := [Backend]native.Asm {
		.Emit  = {},
		.X64   = native.make_asm(.X64_SysV, r3000.native_ram(), r3000.NATIVE_CACHED[:]),
		.Arm64 = native.make_asm(.Arm64, r3000.native_ram(), r3000.NATIVE_CACHED[:]),
	}
	at := u32(0x80002000)

	gen :: proc(b: Backend, na: ^native.Asm, at: u32, w: u32) -> [dynamic]string {
		f := build(at, {w, JR_RA, 0})
		if b == .Emit {
			sb := strings.builder_make()
			r3000.emit_func(f, &sb, "f", nil, 1)
			return emit_calls(strings.to_string(sb))
		}
		from, first := len(na.code), len(na.imp_refs)
		r3000.native_func(na, f, nil, 1)
		return native_calls(na, from, first)
	}
	base: [Backend][dynamic]string
	for b in Backend {base[b] = gen(b, &na[b], at, 0)}

	used := make([]bool, len(ALLOWED))
	cases, left: [Backend]int
	not_insn := 0
	for w in words() {
		i := r3000.decode(at, w)
		if r3000.has_delay(i) {continue}
		calls: [Backend][]string
		bad: [Backend]bool
		for b in Backend {
			calls[b] = without(gen(b, &na[b], at, w), base[b][:])
			bad[b] = slice.contains(calls[b], "cpu.bad_insn")
		}
		if bad[.Emit] != bad[.X64] || bad[.X64] != bad[.Arm64] {
			fail("%08x: not an instruction to %v", w, bad)
		}
		if bad[.Emit] || bad[.X64] || bad[.Arm64] {
			not_insn += 1
			continue
		}
		slice.sort(calls[.X64])
		slice.sort(calls[.Arm64])
		if !slice.equal(calls[.X64], calls[.Arm64]) {
			fail("%08x: x64 calls %v, arm64 %v", w, calls[.X64], calls[.Arm64])
		}
		for b in Backend {
			cases[b] += 1
			handoff := false
			for c in calls[b] {
				if b == .Emit {
					inline, ok := decls[c]
					if !ok {
						fail("%08x: emit calls %s, declared in none of FILES", w, c)
						continue
					}
					if inline {continue}
				}
				handoff = true
				listed := false
				for e, k in ALLOWED {
					if b in e.backends && e.helper == c && e.match(w) {
						used[k], listed = true, true
					}
				}
				if !listed {fail("%08x: %v hands off to %s, not in ALLOWED", w, b, c)}
			}
			if handoff {left[b] += 1}
		}
		at += 0x10
		free_all(context.temp_allocator)
	}
	for e, k in ALLOWED {
		if !used[k] {fail("ALLOWED %s (%s) never occurs", e.helper, e.reason)}
	}
	fmt.printfln("psx_cover emit: %d cases, %d left to a helper", cases[.Emit], left[.Emit])
	fmt.printfln("psx_cover native x64: %d cases, %d left to a helper", cases[.X64], left[.X64])
	fmt.printfln("psx_cover native arm64: %d cases, %d left to a helper", cases[.Arm64], left[.Arm64])
	fmt.printfln("psx_cover: %d words not instructions", not_insn)
	if failed > 0 {
		fmt.eprintfln("psx_cover: %d failures", failed)
		os.exit(1)
	}
	fmt.println("ok psx_cover")
}
