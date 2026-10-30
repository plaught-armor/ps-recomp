// Host FRAMES test: each host, headless with FRAMES=5, exits with status 0
// at vblank 5, not before and not after. The test runs itself once per host
// as a child (the exit ends the process); the child calls the host's vblank
// itself, printing each call's number first, and exits with status 1 if
// the host lets it run past FRAMES.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import ps2_host "ps:ps2/host"
import "ps:ps2/kernel"
import psx_cpu "ps:psx/cpu"
import psx_host "ps:psx/host"

@(private = "file")
FRAMES :: 5

main :: proc() {
	if len(os.args) == 2 {
		child(os.args[1])
	}
	failed := 0
	for name in ([]string{"psx", "ps2"}) {
		if !run(name) {
			failed += 1
		}
	}
	if failed > 0 {
		os.exit(1)
	}
	fmt.println("ok host_frames")
}

// Run the child for one host and check how it ended.
@(private = "file")
run :: proc(name: string) -> bool {
	os.set_env(core.env_name("HEADLESS"), "1")
	os.set_env(core.env_name("FRAMES"), fmt.tprint(FRAMES))
	os.set_env(core.env_name("SW"), "1") // no Vulkan device needed
	os.set_env(core.env_name("GPU"), "sw")
	self, err := os.get_executable_path(context.temp_allocator)
	state: os.Process_State
	out, errs: []u8
	if err == nil {
		state, out, errs, err = os.process_exec({command = {self, name}}, context.temp_allocator)
	}
	if err != nil {
		fmt.eprintfln("FAIL host_frames %s: cannot run the child: %v", name, err)
		return false
	}
	lines := strings.split_lines(strings.trim_space(string(out)), context.temp_allocator)
	last := lines[len(lines) - 1]
	want_err := fmt.tprintf("frames: %d reached", FRAMES)
	if !state.exited || state.exit_code != 0 || last != fmt.tprint(FRAMES) || !strings.contains(string(errs), want_err) {
		fmt.eprintfln("FAIL host_frames %s: status %d, last vblank %q, stderr:\n%s", name, state.exit_code, last, errs)
		return false
	}
	return true
}

// Set the host up and drive its vblank; the host exits at FRAMES.
@(private = "file")
child :: proc(name: string) -> ! {
	vblank: proc()
	switch name {
	case "psx":
		// As psx.run does: the host's trace lines read the vblank count.
		if !psx_cpu.trace_init() || !psx_host.platform_init("host_frames") {os.exit(2)}
		vblank = psx_host.platform_frame
	case "ps2":
		if !ps2_host.platform_init("host_frames") {os.exit(2)}
		vblank = kernel.vblank_hook
	case:
		os.exit(2)
	}
	for i in 1 ..= FRAMES + 3 {
		fmt.println(i)
		os.flush(os.stdout)
		vblank()
	}
	os.exit(1)
}
