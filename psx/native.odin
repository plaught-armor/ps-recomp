// Native code from the recompiler (its native_arch and native_out options)
// in place of the recompiled Odin: the same functions, as machine code built
// apart from the game. This names every runtime procedure and variable the
// code imports and puts its functions in the dispatch tables.
//
// A game calls load_native after registering its recompiled functions and
// before installing hooks, so hooks replace the native functions as they
// would the Odin ones. Setting NATIVE=0 keeps the Odin functions, for
// comparing the two.
package psx

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "cpu"
import gte "gte"
import io "io"

// The native code addresses cpu.state by these offsets
// (recomp/r3000/native.odin).
#assert(offset_of(cpu.Cpu, r) == 0)
#assert(offset_of(cpu.Cpu, hi) == 128)
#assert(offset_of(cpu.Cpu, lo) == 132)
#assert(offset_of(cpu.Cpu, cycles) == 136)

// The bus accesses are inlined into the Odin code; the native code calls
// these copies.
@(private = "file")
lb :: proc(a: u32) -> u32 {return cpu.lb(a)}
@(private = "file")
lh :: proc(a: u32) -> u32 {return cpu.lh(a)}
@(private = "file")
lw :: proc(a: u32) -> u32 {return cpu.lw(a)}
@(private = "file")
lbu :: proc(a: u32) -> u32 {return cpu.lbu(a)}
@(private = "file")
lhu :: proc(a: u32) -> u32 {return cpu.lhu(a)}
@(private = "file")
sb :: proc(a, v: u32) {cpu.sb(a, v)}
@(private = "file")
sh :: proc(a, v: u32) {cpu.sh(a, v)}
@(private = "file")
sw :: proc(a, v: u32) {cpu.sw(a, v)}

@(private = "file")
native_imports :: proc() -> map[string]u64 {
	p :: proc(v: rawptr) -> u64 {return u64(uintptr(v))}
	m := make(map[string]u64, context.temp_allocator)
	m["cpu.state"] = p(&cpu.state)
	m["cpu.next_event"] = p(&cpu.next_event)
	m["cpu.host_camera"] = p(&cpu.host_camera)
	m["trace.block_byte"] = p(&core.trace.active) + u64(core.Trace_Channel.Block) / 8
	m["trace.block_bit"] = 1 << (u64(core.Trace_Channel.Block) % 8)
	m["trace.watching"] = p(&core.trace.watching)
	m["cpu.ram"] = p(&cpu.ram)
	m["cpu.ram_armed"] = p(&cpu.ram_armed)
	m["cpu.sr_isolate"] = p(&cpu.cop0.sr) + 2
	m["cpu.lb"] = p(rawptr(lb))
	m["cpu.lh"] = p(rawptr(lh))
	m["cpu.lw"] = p(rawptr(lw))
	m["cpu.lbu"] = p(rawptr(lbu))
	m["cpu.lhu"] = p(rawptr(lhu))
	m["cpu.sb"] = p(rawptr(sb))
	m["cpu.sh"] = p(rawptr(sh))
	m["cpu.sw"] = p(rawptr(sw))
	m["cpu.lwl"] = p(rawptr(cpu.lwl))
	m["cpu.lwr"] = p(rawptr(cpu.lwr))
	m["cpu.swl"] = p(rawptr(cpu.swl))
	m["cpu.swr"] = p(rawptr(cpu.swr))
	m["cpu.div"] = p(rawptr(cpu.div))
	m["cpu.divu"] = p(rawptr(cpu.divu))
	m["cpu.syscall"] = p(rawptr(cpu.syscall))
	m["cpu.brk"] = p(rawptr(cpu.brk))
	m["cpu.mfc0"] = p(rawptr(cpu.mfc0))
	m["cpu.mtc0"] = p(rawptr(cpu.mtc0))
	m["cpu.rfe"] = p(rawptr(cpu.rfe))
	m["cpu.bad_insn"] = p(rawptr(cpu.bad_insn))
	m["cpu.call"] = p(rawptr(cpu.call))
	m["cpu.jump_unknown"] = p(rawptr(cpu.jump_unknown))
	m["cpu.trace_block"] = p(rawptr(cpu.trace_block))
	m["gte.gte_read"] = p(rawptr(gte.gte_read))
	m["gte.gte_write"] = p(rawptr(gte.gte_write))
	m["gte.gte_cmd"] = p(rawptr(gte.gte_cmd))
	m["io.run_events"] = p(rawptr(io.run_events))
	return m
}

// Replace the registered functions with the native code in the file at
// path. False, with the reason printed, when it cannot be used; the Odin
// functions then stay.
load_native :: proc(path: string) -> bool {
	if core.env("NATIVE") == "0" {
		return false
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("native: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	code, msg := core.native_load(blob, native_imports())
	if msg != "" {
		fmt.eprintfln("native: %s: %s", path, msg)
		return false
	}
	defer delete(code.funcs)
	defer delete(code.ovls)
	fn :: proc(code: core.Native_Code, off: u32) -> cpu.Func_Proc {
		return cast(cpu.Func_Proc)rawptr(code.base + uintptr(off))
	}
	// A function the build does not have means the blob is from other code:
	// use none of it rather than a mix.
	ovl_match :: proc(e: cpu.Ovl_Entry, o: core.Native_Ovl) -> bool {
		return e.slot == o.slot && e.id == o.id && e.sig == o.sig
	}
	missing := 0
	for f in code.funcs {
		if !cpu.registered(f.addr) {missing += 1}
	}
	for o in code.ovls {
		found := false
		for e in cpu.dispatch.overlay[o.addr] {
			if ovl_match(e, o) {found = true}
		}
		if !found {missing += 1}
	}
	if missing != 0 {
		fmt.eprintfln("native: %s: %d functions are not registered (built from other code?)", path, missing)
		return false
	}
	for f in code.funcs {
		cpu.hook(f.addr, fn(code, f.off))
	}
	for o in code.ovls {
		for &e in cpu.dispatch.overlay[o.addr] {
			if ovl_match(e, o) {e.fn = fn(code, o.off)}
		}
	}
	fmt.eprintfln("native: %d functions from %s", len(code.funcs) + len(code.ovls), path)
	return true
}
