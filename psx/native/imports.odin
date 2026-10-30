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

// The runtime procedures and variables native code imports, by name.
imports :: proc() -> map[string]u64 {
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
	m["cpu.lw_u"] = p(rawptr(cpu.lw_u))
	m["cpu.sw_u"] = p(rawptr(cpu.sw_u))
	m["cpu.syscall"] = p(rawptr(cpu.syscall))
	m["cpu.brk"] = p(rawptr(cpu.brk))
	m["cpu.mfc0"] = p(rawptr(cpu.mfc0))
	m["cpu.mtc0"] = p(rawptr(cpu.mtc0))
	m["cpu.rfe"] = p(rawptr(cpu.rfe))
	m["cpu.bad_insn"] = p(rawptr(cpu.bad_insn))
	m["cpu.call"] = p(rawptr(cpu.call))
	m["cpu.jump_unknown"] = p(rawptr(cpu.jump_unknown))
	m["cpu.trace_block"] = p(rawptr(cpu.trace_block))
	m["gte.state"] = p(&gte.state)
	m["gte.gte_read"] = p(rawptr(gte.gte_read))
	m["gte.gte_write"] = p(rawptr(gte.gte_write))
	m["gte.gte_cmd"] = p(rawptr(gte.gte_cmd))
	m["gte.cmd_rtps"] = p(rawptr(gte.cmd_rtps))
	m["gte.cmd_rtpt"] = p(rawptr(gte.cmd_rtpt))
	m["gte.cmd_mvmva"] = p(rawptr(gte.cmd_mvmva))
	m["io.run_events"] = p(rawptr(io.run_events))
	return m
}
