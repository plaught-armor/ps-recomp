// Compat line test (core/compat). The test runs itself as a child per case,
// headless, and reads the child's compat line from stderr:
// - psx: under COMPAT an unknown BIOS call returns 0 and the game goes on;
//   a RAM function is interpreted twice; the run ends at FRAMES with a line
//   that names the call and counts the interpreter's entries and work;
// - psx_fatal: a fatal error ends the run with status 1 and a fatal line;
// - psx_off: without COMPAT the unknown BIOS call stops the game, and no
//   line is printed;
// - ps2: under COMPAT a syscall only the retail ROM has returns 0, a bind to
//   a SIF server the HLE lacks goes on, a function is interpreted twice,
//   and the run ends at FRAMES.
// Each unimplemented call is named with where the first was made: ra, the
// pc of a syscall, and the client data of a SIF bind. Neither run shows a
// picture, and main RAM is the same at the end as at FRAMES/2.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:ps2"
import ps2_cpu "ps:ps2/cpu"
import ps2_host "ps:ps2/host"
import "ps:ps2/iop"
import "ps:ps2/kernel"
import "ps:ps2/mem"
import _ "ps:psx"
import psx_cpu "ps:psx/cpu"
import psx_host "ps:psx/host"

@(private = "file")
FRAMES :: 5

@(private = "file")
failed: int

@(private = "file")
check :: proc(name: string, ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL compat %s: %s (line %d)", name, what, loc.line)
		failed += 1
	}
}

// A RAM function: v0 = 7, return.
@(private = "file")
PSX_FUNC :: 0x80001000
// A function: MTSA $zero, return.
@(private = "file")
PS2_FUNC :: 0x00100000
// The ra each unimplemented call is made with.
@(private = "file")
PSX_RA :: 0x80002000
@(private = "file")
PS2_RA :: 0x00100100
// The SifSetDma syscall that sends the bind, and the bind's client data.
@(private = "file")
SIF_PC :: 0x00100008
@(private = "file")
SIF_CLIENT :: 0x00200000

main :: proc() {
	if len(os.args) == 2 {
		child(os.args[1])
	}
	if l, ok := run("psx", true, 0); ok {
		check("psx", l.system == "ps1" && l.result == "frames" && l.frames == FRAMES, "result")
		// No picture, and nothing in RAM moved after the call.
		check("psx", l.shown == 0 && l.ram_still_since == FRAMES / 2, "progress")
		check("psx", l.fatal == "" && l.cycles > 0 && l.cycles_per_insn == 2 && l.build == core.COMMIT, "fields")
		check("psx", len(l.unimplemented) == 1 && l.unimplemented[0] == {"BIOS A(ffh)", 1, "", "80002000", ""}, "unimplemented")
		check("psx", len(l.interp_entries) == 1 && l.interp_entries[0] == {"80001000", 2}, "entries")
		check("psx", l.interp_insns >= 4 && l.interp_entries_other == 0, "interpreter work")
	}
	if l, ok := run("psx_fatal", true, 1); ok {
		check("psx_fatal", l.result == "fatal" && strings.contains(l.fatal, "reserved instruction"), "result")
	}
	run("psx_off", false, 1)
	if l, ok := run("ps2", true, 0); ok {
		check("ps2", l.system == "ps2" && l.result == "frames" && l.frames == FRAMES && l.cycles_per_insn == 1, "result")
		// No picture, and nothing in RAM moved after the call.
		check("ps2", l.shown == 0 && l.ram_still_since == FRAMES / 2, "progress")
		check("ps2", len(l.unimplemented) == 2, "unimplemented")
		if len(l.unimplemented) == 2 {
			check("ps2", l.unimplemented[0] == {"SIF server 0badc0de", 1, "00100008", "00100100", "00200000"}, "SIF bind")
			check("ps2", l.unimplemented[1] == {"syscall 1", 1, "00100000", "00100100", ""}, "syscall")
		}
		check("ps2", len(l.interp_entries) == 1 && l.interp_entries[0] == {"00100000", 2}, "entries")
		check("ps2", l.interp_insns == 4 && l.interp_entries_other == 0, "interpreter work")
	}
	if failed > 0 {
		os.exit(1)
	}
	fmt.println("ok compat")
}

// Run a case's child and check its status and its line: one, which parses,
// under COMPAT; none without.
@(private = "file")
run :: proc(name: string, compat: bool, status: int) -> (l: core.Compat_Line, ok: bool) {
	os.set_env(core.env_name("HEADLESS"), "1")
	os.set_env(core.env_name("FRAMES"), fmt.tprint(FRAMES))
	os.set_env(core.env_name("SW"), "1") // no Vulkan device needed
	os.set_env(core.env_name("GPU"), "sw")
	os.set_env(core.env_name("COMPAT"), compat ? "1" : "")
	self, err := os.get_executable_path(context.temp_allocator)
	state: os.Process_State
	out, errs: []u8
	if err == nil {
		state, out, errs, err = os.process_exec({command = {self, name}}, context.temp_allocator)
	}
	if err != nil {
		check(name, false, fmt.tprintf("cannot run the child: %v", err))
		return
	}
	lines: [dynamic]string
	lines.allocator = context.temp_allocator
	for s in strings.split_lines(string(errs), context.temp_allocator) {
		if strings.has_prefix(s, "compat: ") {
			append(&lines, s[len("compat: "):])
		}
	}
	if !state.exited || state.exit_code != status || len(lines) != (compat ? 1 : 0) {
		check(name, false, fmt.tprintf("status %d, %d compat lines, stdout:\n%s\nstderr:\n%s", state.exit_code, len(lines), out, errs))
		return
	}
	if !compat {
		check(name, strings.contains(string(errs), "fatal: unimplemented BIOS A(ffh)"), "no fatal error")
		return
	}
	if jerr := json.unmarshal_string(lines[0], &l, allocator = context.temp_allocator); jerr != nil {
		check(name, false, fmt.tprintf("line does not parse (%v): %s", jerr, lines[0]))
		return
	}
	return l, true
}

// Run a case, then drive the host's vblank; the host exits at FRAMES.
@(private = "file")
child :: proc(name: string) -> ! {
	vblank: proc()
	switch name {
	case "psx", "psx_fatal", "psx_off":
		if !psx_cpu.trace_init() || !psx_host.platform_init("compat") {os.exit(2)}
		vblank = psx_host.platform_frame
		psx_cpu.register_funcs(nil)
		if name == "psx_fatal" {
			psx_cpu.bad_insn(PSX_FUNC, 0xffffffff)
		}
		psx_cpu.state.r[2] = 1
		psx_cpu.state.r[9] = 0xff
		psx_cpu.state.r[31] = PSX_RA
		psx_cpu.call(0xa0)
		if psx_cpu.state.r[2] != 0 {os.exit(3)}
		for w, i in ([]u32{0x24020007, 0x03e00008, 0}) {
			psx_cpu.w32(PSX_FUNC + 4 * u32(i), w)
		}
		psx_cpu.state.r[31] = PSX_FUNC - 0x10
		for _ in 0 ..< 2 {
			psx_cpu.state.r[2] = 0
			psx_cpu.call(PSX_FUNC)
			if psx_cpu.state.r[2] != 7 {os.exit(3)}
		}
	case "ps2":
		if !ps2_host.platform_init("compat") {os.exit(2)}
		vblank = kernel.vblank_hook
		mem.mem_init()
		kernel.kernel_init()
		iop.sif_init()
		ps2_cpu.state.r[31].d[0] = PS2_RA
		ps2_cpu.state.r[2].d[0] = 1
		ps2_cpu.state.r[3].d[0] = 1 // ResetEE
		kernel.syscall(PS2_FUNC)
		if ps2_cpu.state.r[2].d[0] != 0 {os.exit(3)}
		// SifSetDma of an RPC bind packet {header, rec_id, pkt, rpc_id,
		// client, sid} to the IOP's command buffer.
		PKT :: 0x00200100
		LIST :: 0x00200200
		for w, i in ([]u32{0x40, 0, iop.SIF_CMD_RPC_BIND, 0, 0, PKT, 1, SIF_CLIENT, 0x0badc0de}) {
			mem.wr32(PKT + 4 * u32(i), w)
		}
		for w, i in ([]u32{PKT, iop.IOP_CMDBUF, 0x40, 0}) {
			mem.wr32(LIST + 4 * u32(i), w)
		}
		ps2_cpu.state.r[3].d[0] = 0x77
		ps2_cpu.state.r[4].d[0] = LIST
		ps2_cpu.state.r[5].d[0] = 1
		kernel.syscall(SIF_PC)
		for w, i in ([]u32{0x00000029, 0x03e00008, 0}) {
			mem.wr32(PS2_FUNC + 4 * u32(i), w)
		}
		for _ in 0 ..< 2 {
			ps2.interp_call(PS2_FUNC)
		}
	case:
		os.exit(2)
	}
	for _ in 1 ..= FRAMES + 3 {
		vblank()
	}
	os.exit(1)
}
