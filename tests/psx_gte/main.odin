// GTE register moves as native code, run on every target in CI: mtc2, mfc2,
// lwc2 and swc2 (data registers) and ctc2 and cfc2 (control registers), the
// native backend's inline field stores and loads and the calls it keeps,
// against gte.gte_write and gte.gte_read from the same GTE state.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import psx_native "ps:psx/native"
import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
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
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_gte %v: %d checks", arch, checks)
}
