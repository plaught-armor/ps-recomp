// Runtime probes, configured from the environment so a debugging session
// needs no rebuild:
//   TRACE=3a0110,3a01b0   log entry to these recompiled functions
//   TRACE_SYS=43,44       log these syscalls (interrupt variants too)
//   WATCH=883580[:len]    log guest stores into [addr, addr+len) (len 4)
//   TRACE_FRAMES=lo-hi    only during these kernel frames (default all)
// Each line carries a0..a3, ra, thread, frame, cycle and the code addresses
// found on the guest stack, which approximates the call chain.
package ps2_kernel

import "core:fmt"
import "core:strconv"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

trace_on: bool // any TRACE function; checked at every recompiled entry
@(private = "file")
trace_fns: map[u32]bool
trace_sys_on: bool
@(private = "file")
trace_sys: map[i32]bool
@(private = "file")
trace_lo, trace_hi: u64 = 0, max(u64)

trace_init :: proc() {
	if v, ok := core.env_lookup("TRACE"); ok {
		for s in strings.split(v, ",", context.temp_allocator) {
			if a, ok2 := strconv.parse_u64_of_base(strings.trim_space(s), 16); ok2 {trace_fns[u32(a)] = true}
		}
		trace_on = len(trace_fns) > 0
	}
	if v, ok := core.env_lookup("TRACE_SYS"); ok {
		for s in strings.split(v, ",", context.temp_allocator) {
			if n, ok2 := strconv.parse_u64_of_base(strings.trim_space(s), 16); ok2 {trace_sys[i32(n)] = true}
		}
		trace_sys_on = len(trace_sys) > 0
	}
	if v, ok := core.env_lookup("WATCH"); ok {
		parts := strings.split(v, ":", context.temp_allocator)
		if a, ok2 := strconv.parse_u64_of_base(parts[0], 16); ok2 {
			mem.watch_lo, mem.watch_len = u32(a) & 0x0fffffff, 4
			if len(parts) > 1 {
				if n, ok3 := strconv.parse_u64_of_base(parts[1], 16); ok3 {mem.watch_len = u32(n)}
			}
			mem.fast_lim = 0
			mem.watch_on = 1
		}
	}
	if v, ok := core.env_lookup("TRACE_FRAMES"); ok {
		parts := strings.split(v, "-", context.temp_allocator)
		trace_lo, _ = strconv.parse_u64(parts[0])
		if len(parts) > 1 {trace_hi, _ = strconv.parse_u64(parts[1])}
	}
}

trace_call :: proc(addr: u32) {
	if !trace_fns[addr] || k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("trace f_%08x a0 %x a1 %x a2 %x a3 %x", addr,
		u32(cpu.state.r[4].d[0]), u32(cpu.state.r[5].d[0]), u32(cpu.state.r[6].d[0]), u32(cpu.state.r[7].d[0]))
	trace_tail()
}

trace_syscall :: proc(n: i32) {
	if !trace_sys[abs(n)] || k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("syscall %x a0 %x a1 %x a2 %x a3 %x", n,
		u32(cpu.state.r[4].d[0]), u32(cpu.state.r[5].d[0]), u32(cpu.state.r[6].d[0]), u32(cpu.state.r[7].d[0]))
	trace_tail()
}

trace_store :: proc(a: u32, v: u128) {
	if k.frame < trace_lo || k.frame > trace_hi {return}
	fmt.eprintf("watch %08x = %x", a, v)
	trace_tail()
}

@(private = "file")
trace_tail :: proc() {
	cur := k.current != nil ? k.current.id : -1
	fmt.eprintf(" ra %x thread %d frame %d cyc %d stack", u32(cpu.state.r[31].d[0]), cur, k.frame, cpu.state.cycles)
	sp := u32(cpu.state.r[29].d[0]) & (mem.RAM_SIZE - 1) &~ 3
	for o: u32 = 0; o < 0x200 && sp + o < mem.RAM_SIZE; o += 4 {
		w := (^u32)(&mem.ram[sp + o])^
		if w >= cpu.text_lo && w < cpu.text_hi && w & 3 == 0 {fmt.eprintf(" %x", w)}
	}
	fmt.eprintln()
}
