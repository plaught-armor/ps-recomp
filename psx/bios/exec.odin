// The executable loaders: A(41h) LoadTest, A(42h) Load, A(43h) Exec and
// A(51h) LoadExec, verified against v4.5 retail kernel. An executable is read
// from the disc whole; its header fills the caller's exec header and its text
// goes into RAM through mem_slice, so psx/cpu's code watch demotes the
// functions it overwrites. An executable no native code covers is
// interpreted.
package psx_bios

import "core:fmt"
import "core:strings"

import "ps:core"
import cpu "../cpu"

// The file at a disc path (device and `;N` ignored), allocated with the
// allocator given; set by package psx (hooks.odin).
disc_file: proc(path: string, allocator := context.allocator) -> ([]u8, bool)

// The exec header (the caller's, or the kernel's for LoadExec): pc0, gp0,
// t_addr, t_size, d_addr, d_size, b_addr, b_size, s_addr, s_size, then Exec's
// save area for sp, fp, gp, ra and s0.
@(private)
EXEC_PC0 :: 0x00
@(private)
EXEC_GP0 :: 0x04
@(private)
EXEC_T_ADDR :: 0x08
@(private)
EXEC_T_SIZE :: 0x0c
@(private)
EXEC_B_ADDR :: 0x18
@(private)
EXEC_B_SIZE :: 0x1c
@(private)
EXEC_S_ADDR :: 0x20
@(private)
EXEC_S_SIZE :: 0x24
@(private)
EXEC_SAVE :: 0x28
// The bytes of an executable's file header Load copies, from FILE_HEADER on:
// pc0 through s_size and the save area's slots.
@(private)
EXEC_HEADER_SIZE :: 0x3c
@(private)
FILE_HEADER :: 0x10
// The text's file offset, and the header a file must hold all of.
@(private)
FILE_TEXT :: 0x800

// The kernel's own exec header, which LoadExec loads into, in the kernel
// area after the table stubs.
@(private)
KERNEL_EXEC :: 0x3800

// Nested Exec calls, LoadExec's included: each keeps its caller's host frames
// under the program it runs, and LoadExec's caller never resumes. Past this
// many the host stack of the 1 MiB Windows main thread, which the game runs
// on, is at risk. Measured on linux amd64 with -o:speed (load_exec's trace
// line): a hop takes 2816 bytes interpreted (2592 native), and 496 more for
// each guest call under the LoadExec (384 native). With 32 guest calls a hop
// is 18688 bytes, and 1 MiB less 128 KiB of headroom holds 49 of them.
MAX_EXEC_DEPTH :: 49

exec_state: struct {
	// The boot executable's bytes, which LoadExec runs again when the one it
	// was given is missing or returns.
	boot:  []u8,
	// The kernel header's s_addr and s_size as the last LoadExec set them
	// (the boot executable's to begin with): what the boot executable runs
	// with again.
	stack: [2]u32,
	depth: int,
}

// The executable psx.run booted, for LoadExec to fall back on.
exec_boot :: proc(exe: []u8) {
	exec_state.boot = exe
	exec_state.depth = 0
	if len(exe) >= FILE_TEXT {
		exec_state.stack = {get_u32(exe, FILE_HEADER + EXEC_S_ADDR), get_u32(exe, FILE_HEADER + EXEC_S_SIZE)}
	}
}

// A(41h) LoadTest(name, hdr) and A(42h) Load(name, hdr): 1 when the file's
// header (and with text, its text) is loaded, else 0. Only the disc is read;
// no magic is checked, and a short file loads the text it has.
@(private)
exec_load :: proc(name: string, hdr: u32, text: bool) -> u32 {
	if disc_file == nil || !on_disc(name) {
		return 0
	}
	data, ok := disc_file(name, context.allocator)
	if !ok {
		return 0
	}
	defer delete(data)
	return load_bytes(data, hdr, text)
}

// Load's work on a file's bytes.
@(private)
load_bytes :: proc(data: []u8, hdr: u32, text: bool) -> u32 {
	if len(data) < FILE_TEXT {
		return 0
	}
	for k := u32(0); k < EXEC_HEADER_SIZE; k += 4 {
		cpu.w32(hdr + k, get_u32(data, FILE_HEADER + int(k)))
	}
	if text {
		size := min(cpu.r32(hdr + EXEC_T_SIZE), u32(len(data) - FILE_TEXT))
		dst := ram_span(cpu.r32(hdr + EXEC_T_ADDR), size)
		copy(dst, data[FILE_TEXT:][:len(dst)])
	}
	return 1
}

// RAM from addr through mem_slice, n bytes or up to the end of RAM: the
// header's addresses and sizes are the game's.
@(private)
ram_span :: proc(addr, n: u32) -> []u8 {
	off := addr & (cpu.RAM_SIZE - 1)
	return cpu.mem_slice(off, min(n, cpu.RAM_SIZE - off))
}

// The disc's device, or none.
@(private)
on_disc :: proc(name: string) -> bool {
	i := strings.index_byte(name, ':')
	return i < 0 || strings.has_prefix(name, "cdrom")
}

// A(43h) Exec(hdr, argc, argv): clears the BSS, sets the stack from s_addr
// when it is nonzero, and calls pc0 with argc and argv; 1 when the program
// returns, with sp, fp, gp, ra and s0 as hdr's save area holds them then.
@(private)
exec :: proc(hdr, argc, argv: u32) {
	r := &cpu.state.r
	save := hdr + EXEC_SAVE
	cpu.w32(save, r[29])
	cpu.w32(save + 4, r[30])
	cpu.w32(save + 8, r[28])
	cpu.w32(save + 12, r[31])
	cpu.w32(save + 16, r[16])
	// Whole words, the last one rounded up.
	if n := cpu.r32(hdr + EXEC_B_SIZE); n != 0 {
		for &b in ram_span(cpu.r32(hdr + EXEC_B_ADDR), (n + 3) &~ 3) {
			b = 0
		}
	}
	if s := cpu.r32(hdr + EXEC_S_ADDR); s != 0 {
		r[29] = s + cpu.r32(hdr + EXEC_S_SIZE)
		r[30] = r[29]
	}
	r[28] = cpu.r32(hdr + EXEC_GP0)
	r[4] = argc
	r[5] = argv
	if exec_state.depth >= MAX_EXEC_DEPTH {
		cpu.fatal("Exec/LoadExec nested %d deep (pc0 %#08x)", exec_state.depth, cpu.r32(hdr + EXEC_PC0))
	}
	exec_state.depth += 1
	cpu.call(cpu.r32(hdr + EXEC_PC0))
	exec_state.depth -= 1
	r[29] = cpu.r32(save)
	r[30] = cpu.r32(save + 4)
	r[28] = cpu.r32(save + 8)
	r[31] = cpu.r32(save + 12)
	r[16] = cpu.r32(save + 16)
	ret(1)
}

// A(51h) LoadExec(name, sp_addr, sp_size): runs the executable with the stack
// given (sp_addr 0: the caller's sp, there being no BIOS frame on the guest
// stack here, where retail's is 0x50 bytes below it). When the file is
// missing or the program returns, the boot executable runs again with the
// stack the last LoadExec gave; when that returns too, the game is over.
// Never returns.
@(private)
load_exec :: proc(name: string, sp_addr, sp_size: u32) -> ! {
	// The host stack one hop takes is the difference of these addresses
	// from one LoadExec to the next (TRACE=bios).
	probe: u8
	if .Bios in core.trace.active {
		core.tracef(.Bios, "LoadExec %s depth %d host stack %#x", name, exec_state.depth, uintptr(&probe))
	}
	saved := exec_state.stack
	cpu.exit_critical()
	if exec_load(name, KERNEL_EXEC, true) == 1 {
		exec_state.stack = {sp_addr, sp_size}
		cpu.w32(KERNEL_EXEC + EXEC_S_ADDR, sp_addr)
		cpu.w32(KERNEL_EXEC + EXEC_S_SIZE, sp_size)
		exec(KERNEL_EXEC, 1, 0)
		fmt.eprintfln("bios: LoadExec: %s returned, running the boot executable again", name)
	} else {
		fmt.eprintfln("bios: LoadExec: no executable %s, running the boot executable again", name)
	}
	cpu.exit_critical()
	if load_bytes(exec_state.boot, KERNEL_EXEC, true) == 1 {
		exec_state.stack = saved
		cpu.w32(KERNEL_EXEC + EXEC_S_ADDR, saved[0])
		cpu.w32(KERNEL_EXEC + EXEC_S_SIZE, saved[1])
		exec(KERNEL_EXEC, 1, 0)
	}
	cpu.fatal("LoadExec: %s and the boot executable both failed or returned", name)
}
