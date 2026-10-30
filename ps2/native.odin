// Native code from the recompiler (its native_arch and native_out options)
// in place of the recompiled Odin: the same functions, as machine code built
// apart from the game. This names every runtime procedure and variable the
// code imports and puts its functions in the call table.
//
// A game calls load_native after registering its recompiled functions, so
// the native ones replace them. Setting NATIVE=0 keeps the Odin functions,
// for comparing the two.
package ps2

import "base:intrinsics"
import "core:fmt"
import "core:os"

import "ps:core"
import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"
import vu "vu"

// The native code addresses cpu.state by these offsets
// (recomp/r5900/native.odin).
#assert(offset_of(cpu.Cpu, r) == 0)
#assert(size_of(cpu.Gpr) == 16)
#assert(offset_of(cpu.Cpu, hi) == 512)
#assert(offset_of(cpu.Cpu, lo) == 528)
#assert(offset_of(cpu.Cpu, sa) == 544)
#assert(offset_of(cpu.Cpu, f) == 548 && size_of(cpu.Fpr) == 4)
#assert(offset_of(cpu.Cpu, acc) == 676)
#assert(offset_of(cpu.Cpu, fcr31) == 680)
#assert(offset_of(cpu.Cpu, cop0) == 684)
#assert(offset_of(cpu.Cpu, cycles) == 816)
// And VU0's VI registers by this offset from import vu.vf.
#assert(offset_of(vu.Vu, vi) - offset_of(vu.Vu, vf) == 512)

// bc_cond for native code, which reads a 32-bit result.
@(private = "file")
native_bc_cond :: proc(w: u32) -> u32 {return bc_cond(w) ? 1 : 0}

// cpu.fpu_slow for native code, which passes the f32 bits and the
// operation in integer registers.
@(private = "file")
native_fpu_slow :: proc(x, y, op: u32) -> u32 {
	return transmute(u32)cpu.fpu_slow(cpu.Fpu_Op(op), transmute(f32)x, transmute(f32)y)
}

// The page bytes of native code's RAM (recomp/r5900/native.odin
// native_ram): no page of RAM is ever armed.
@(private = "file", rodata)
no_pages: [mem.RAM_SIZE >> 12]u8

// Scratch for native QFSRV, which puts its two registers side by side here.
@(private = "file")
funnel: [32]u8

// Bus accesses for native code, which passes and reads 32-bit words; the s
// loads sign-extend.
@(private = "file")
rd8 :: proc(a: u32) -> u32 {return u32(mem.rd8(a))}
@(private = "file")
rd8s :: proc(a: u32) -> u32 {return u32(i32(i8(mem.rd8(a))))}
@(private = "file")
rd16 :: proc(a: u32) -> u32 {return u32(mem.rd16(a))}
@(private = "file")
rd16s :: proc(a: u32) -> u32 {return u32(i32(i16(mem.rd16(a))))}
@(private = "file")
rd32 :: proc(a: u32) -> u32 {return mem.rd32(a)}
@(private = "file")
wr8 :: proc(a, v: u32) {mem.wr8(a, u8(v))}
@(private = "file")
wr16 :: proc(a, v: u32) {mem.wr16(a, u16(v))}
@(private = "file")
wr32 :: proc(a, v: u32) {mem.wr32(a, v)}

// Host pointer for a plain RAM or scratchpad address, else nil: the fast
// path of recompiled code (recomp/r5900/gen.odin FAST_HELPERS fast), as a
// call into package mem is not inlined here either. No bounds check, as
// there.
@(private = "file")
fast :: #force_inline proc "contextless" (a: u32) -> rawptr #no_bounds_check {
	if a < mem.fast_lim {return &mem.ram_base[a]}
	if a - mem.SPR_BASE < mem.SPR_SIZE {return &mem.spr[a - mem.SPR_BASE]}
	return nil
}

// The doubleword and quadword accesses, with guest register n; the loads
// have n not zero.
@(private = "file")
ld :: proc(a, n: u32) {
	p := fast(a)
	cpu.state.r[n].d[0] = p != nil ? intrinsics.unaligned_load((^u64)(p)) : mem.rd64(a)
}
@(private = "file")
sd :: proc(a, n: u32) {
	if p := fast(a); p != nil {
		intrinsics.unaligned_store((^u64)(p), cpu.state.r[n].d[0])
	} else {
		mem.wr64(a, cpu.state.r[n].d[0])
	}
}
@(private = "file")
lq :: proc(a, n: u32) {
	p := fast(a &~ 15)
	cpu.state.r[n].q = p != nil ? intrinsics.unaligned_load((^u128)(p)) : mem.rd128(a)
}
@(private = "file")
sq :: proc(a, n: u32) {
	v := n == 0 ? 0 : cpu.state.r[n].q
	if p := fast(a &~ 15); p != nil {
		intrinsics.unaligned_store((^u128)(p), v)
	} else {
		mem.wr128(a, v)
	}
}
@(private = "file")
lqc2 :: proc(a, n: u32) {
	p := fast(a &~ 15)
	vu.vu0_set_vf(u8(n), p != nil ? intrinsics.unaligned_load((^u128)(p)) : mem.rd128(a))
}
@(private = "file")
sqc2 :: proc(a, n: u32) {
	v := vu.vu0.vf[n].q
	if p := fast(a &~ 15); p != nil {
		intrinsics.unaligned_store((^u128)(p), v)
	} else {
		mem.wr128(a, v)
	}
}

// The unaligned accesses, with guest register n, through the mem
// procedures as the Odin code calls them; the loads have n not zero.
@(private = "file")
lwl :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LWL(a, cpu.state.r[n].d[0])}
@(private = "file")
lwr :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LWR(a, cpu.state.r[n].d[0])}
@(private = "file")
ldl :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LDL(a, cpu.state.r[n].d[0])}
@(private = "file")
ldr :: proc(a, n: u32) {cpu.state.r[n].d[0] = mem.LDR(a, cpu.state.r[n].d[0])}
@(private = "file")
swl :: proc(a, n: u32) {mem.SWL(a, cpu.state.r[n].d[0])}
@(private = "file")
swr :: proc(a, n: u32) {mem.SWR(a, cpu.state.r[n].d[0])}
@(private = "file")
sdl :: proc(a, n: u32) {mem.SDL(a, cpu.state.r[n].d[0])}
@(private = "file")
sdr :: proc(a, n: u32) {mem.SDR(a, cpu.state.r[n].d[0])}

// exec for an instruction the recompiler decoded, which passes its op; the
// fields come straight from the word, without decoding it again.
@(private = "file")
exec_op :: proc(pc, w, op: u32) {
	exec_insn(
		{
			pc = pc,
			w = w,
			op = r5900.Op(op),
			rs = u8((w >> 21) & 31),
			rt = u8((w >> 16) & 31),
			rd = u8((w >> 11) & 31),
			sa = u8((w >> 6) & 31),
			fn = u8(w & 63),
			imm = u16(w),
		},
	)
}

// Lane masks for inline VU0 ops, at the offsets r5900's native code uses:
// the exponent, the sign, the largest finite value, the magnitude, zero,
// then the lanes of each dest field, the ITOF4/12/15 and FTOI4/12/15
// scales, and the bits of the largest f32 below 2^31.
@(private = "file")
vu_k: [5 + 16 + 7][4]u32

// The runtime procedures and variables native code imports, by name.
native_imports :: proc() -> map[string]u64 {
	p :: proc(v: rawptr) -> u64 {return u64(uintptr(v))}
	m := make(map[string]u64, context.temp_allocator)
	vu_k[0], vu_k[1], vu_k[2], vu_k[3] = 0x7f800000, 0x80000000, 0x7f7fffff, 0x7fffffff
	for d in u32(0) ..< 16 {
		for k in u32(0) ..< 4 {vu_k[5 + d][k] = d & (8 >> k) != 0 ? max(u32) : 0}
	}
	for x, n in ([6]f32{1.0 / 16, 1.0 / 4096, 1.0 / 32768, 16, 4096, 32768}) {
		u := transmute(u32)x
		vu_k[21 + n] = {u, u, u, u}
	}
	vu_k[27] = {0x4effffff, 0x4effffff, 0x4effffff, 0x4effffff}
	m["mem.ram"] = p(mem.ram_base)
	m["ps2.no_pages"] = p(&no_pages)
	m["mem.spr"] = p(&mem.spr)
	m["ps2.funnel"] = p(&funnel)
	m["mem.watch_on"] = p(&mem.watch_on)
	m["ps2.rd8"] = p(rawptr(rd8))
	m["ps2.rd8s"] = p(rawptr(rd8s))
	m["ps2.rd16"] = p(rawptr(rd16))
	m["ps2.rd16s"] = p(rawptr(rd16s))
	m["ps2.rd32"] = p(rawptr(rd32))
	m["ps2.wr8"] = p(rawptr(wr8))
	m["ps2.wr16"] = p(rawptr(wr16))
	m["ps2.wr32"] = p(rawptr(wr32))
	m["cpu.state"] = p(&cpu.state)
	m["cpu.next_event"] = p(&cpu.next_event)
	m["cpu.call"] = p(rawptr(cpu.call))
	m["cpu.jump_unknown"] = p(rawptr(cpu.jump_unknown))
	m["cpu.bad_insn"] = p(rawptr(cpu.bad_insn))
	m["cpu.brk"] = p(rawptr(cpu.brk))
	m["cpu.div"] = p(rawptr(cpu.div))
	m["cpu.divu"] = p(rawptr(cpu.divu))
	m["cpu.plzcw"] = p(rawptr(cpu.plzcw))
	m["cpu.pmultw"] = p(rawptr(cpu.pmultw))
	m["cpu.pmultuw"] = p(rawptr(cpu.pmultuw))
	m["cpu.pmaddw"] = p(rawptr(cpu.pmaddw))
	m["cpu.pmadduw"] = p(rawptr(cpu.pmadduw))
	m["cpu.pmsubw"] = p(rawptr(cpu.pmsubw))
	m["cpu.pmulth"] = p(rawptr(cpu.pmulth))
	m["cpu.pmaddh"] = p(rawptr(cpu.pmaddh))
	m["cpu.pmsubh"] = p(rawptr(cpu.pmsubh))
	m["cpu.phmsbh"] = p(rawptr(cpu.phmsbh))
	m["cpu.pdivbw"] = p(rawptr(cpu.pdivbw))
	m["cpu.pmfhl"] = p(rawptr(cpu.pmfhl))
	m["kernel.ei"] = p(rawptr(kernel.ei))
	m["kernel.syscall"] = p(rawptr(kernel.syscall))
	m["kernel.trace_on"] = p(&kernel.trace_on)
	m["kernel.trace_call"] = p(rawptr(kernel.trace_call))
	m["kernel.run_events"] = p(rawptr(kernel.run_events))
	m["ps2.exec_op"] = p(rawptr(exec_op))
	m["ps2.ld"] = p(rawptr(ld))
	m["ps2.sd"] = p(rawptr(sd))
	m["ps2.lq"] = p(rawptr(lq))
	m["ps2.sq"] = p(rawptr(sq))
	m["ps2.lqc2"] = p(rawptr(lqc2))
	m["ps2.sqc2"] = p(rawptr(sqc2))
	m["ps2.lwl"] = p(rawptr(lwl))
	m["ps2.lwr"] = p(rawptr(lwr))
	m["ps2.ldl"] = p(rawptr(ldl))
	m["ps2.ldr"] = p(rawptr(ldr))
	m["ps2.swl"] = p(rawptr(swl))
	m["ps2.swr"] = p(rawptr(swr))
	m["ps2.sdl"] = p(rawptr(sdl))
	m["ps2.sdr"] = p(rawptr(sdr))
	m["vu.vf"] = p(&vu.vu0.vf)
	m["vu.acc"] = p(&vu.vu0.acc)
	m["vu.q"] = p(&vu.vu0.q)
	m["vu.i"] = p(&vu.vu0.i)
	m["vu.mac"] = p(&vu.vu0.mac)
	m["vu.status"] = p(&vu.vu0.status)
	m["vu.k"] = p(&vu_k)
	m["vu.macro"] = p(rawptr(vu.vu0_macro))
	m["vu.call_micro"] = p(rawptr(vu.vu0_call_micro))
	m["vu.cmsar"] = p(&vu.vu0.cmsar)
	m["vu.mem"] = p(&vu.vu0_mem)
	m["vu.ctrl_read"] = p(rawptr(vu.vu0_ctrl_read))
	m["vu.ctrl_write"] = p(rawptr(vu.vu0_ctrl_write))
	m["ps2.bc_cond"] = p(rawptr(native_bc_cond))
	m["cpu.fpu_slow"] = p(rawptr(native_fpu_slow))
	return m
}

// Replace the registered functions with the native code in the file at
// path. False, with the reason printed, when it cannot be used; the Odin
// functions then stay.
load_native :: proc(path: string) -> bool {
	if core.env("NATIVE") == "0" {
		return false
	}
	if mem.ram_base == nil {
		fmt.eprintln("native: load_native comes after init, which maps RAM")
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
	// A function the build does not have means the blob is from other code:
	// use none of it rather than a mix.
	missing := 0
	for f in code.funcs {
		if cpu.lookup(f.addr) == nil {missing += 1}
	}
	if missing != 0 {
		fmt.eprintfln("native: %s: %d functions are not registered (built from other code?)", path, missing)
		core.native_free(&code)
		return false
	}
	for f in code.funcs {
		cpu.register(f.addr, cast(cpu.Func_Proc)rawptr(code.base + uintptr(f.off)))
	}
	fmt.eprintfln("native: %d functions from %s", len(code.funcs), path)
	return true
}
