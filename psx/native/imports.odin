// The names native code from the recompiler imports, apart from package
// psx so that tests can load native code without its host side.
package psx_native

import "ps:core"
import cpu "../cpu"
import gte "../gte"
import io "../io"

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
// Without the Odin code's k (cpu.load_slow): native code raises the cycles
// itself (recomp/native access_call).
@(private = "file")
lwl :: proc(a, cur: u32) -> u32 {return cpu.lwl(a, cur)}
@(private = "file")
lwr :: proc(a, cur: u32) -> u32 {return cpu.lwr(a, cur)}
@(private = "file")
swl :: proc(a, v: u32) {cpu.swl(a, v)}
@(private = "file")
swr :: proc(a, v: u32) {cpu.swr(a, v)}
@(private = "file")
lw_u :: proc(a: u32) -> u32 {return cpu.lw_u(a)}
@(private = "file")
sw_u :: proc(a, v: u32) {cpu.sw_u(a, v)}

// The runtime procedures and variables native code imports, by name; with
// types, each procedure's type too, for the signatures wasm32 calls with
// (recomp/r3000 R3000_SIGS, which tests/wasm_sigs checks).
imports :: proc(types: ^map[string]typeid = nil) -> map[string]u64 {
	p :: proc(v: rawptr) -> u64 {return u64(uintptr(v))}
	f :: proc(m: ^map[string]u64, types: ^map[string]typeid, name: string, v: $T) {
		m[name] = u64(uintptr(rawptr(v)))
		if types != nil {types[name] = T}
	}
	m := make(map[string]u64, context.temp_allocator)
	m["cpu.state"] = p(&cpu.state)
	m["cpu.next_event"] = p(&cpu.next_event)
	m["cpu.host_camera"] = p(&cpu.host_camera)
	m["trace.block_byte"] = p(&core.trace.active) + u64(core.Trace_Channel.Block) / 8
	m["trace.block_bit"] = 1 << (u64(core.Trace_Channel.Block) % 8)
	m["trace.watching"] = p(&core.trace.watching)
	m["cpu.ram"] = p(&cpu.ram)
	m["cpu.ram_armed"] = p(&cpu.ram_armed)
	m["cpu.scratch"] = p(&cpu.scratch)
	m["cpu.sr_isolate"] = p(&cpu.cop0.sr) + 2
	f(&m, types, "cpu.lb", lb)
	f(&m, types, "cpu.lh", lh)
	f(&m, types, "cpu.lw", lw)
	f(&m, types, "cpu.lbu", lbu)
	f(&m, types, "cpu.lhu", lhu)
	f(&m, types, "cpu.sb", sb)
	f(&m, types, "cpu.sh", sh)
	f(&m, types, "cpu.sw", sw)
	f(&m, types, "cpu.lwl", lwl)
	f(&m, types, "cpu.lwr", lwr)
	f(&m, types, "cpu.swl", swl)
	f(&m, types, "cpu.swr", swr)
	f(&m, types, "cpu.lw_u", lw_u)
	f(&m, types, "cpu.sw_u", sw_u)
	f(&m, types, "cpu.syscall", cpu.syscall)
	f(&m, types, "cpu.brk", cpu.brk)
	m["cpu.cop0"] = p(&cpu.cop0)
	f(&m, types, "cpu.mtc0", cpu.mtc0)
	f(&m, types, "cpu.rfe", cpu.rfe)
	f(&m, types, "cpu.bad_insn", cpu.bad_insn)
	f(&m, types, "cpu.call", cpu.call)
	f(&m, types, "cpu.jump_unknown", cpu.jump_unknown)
	f(&m, types, "cpu.trace_block", cpu.trace_block)
	m["gte.state"] = p(&gte.state)
	f(&m, types, "gte.gte_read", gte.gte_read)
	f(&m, types, "gte.gte_write", gte.gte_write)
	m["gte.matrix_filter"] = p(&gte.gte_matrix_filter)
	f(&m, types, "gte.gte_cmd", gte.gte_cmd)
	f(&m, types, "gte.cmd_rtps", gte.cmd_rtps)
	f(&m, types, "gte.cmd_rtpt", gte.cmd_rtpt)
	f(&m, types, "gte.cmd_mvmva", gte.cmd_mvmva)
	f(&m, types, "io.run_events", io.run_events)
	return m
}
