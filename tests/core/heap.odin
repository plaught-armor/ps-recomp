package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"

// The child for test_heap_full: allocate past a 1 MiB emulated heap. The
// allocation that does not fit must end the process with core's message;
// coming back from it, with nil, is the silent failure the test catches.
heap_full_child :: proc() -> ! {
	core.snap_init(1 << 20)
	context.allocator = core.emu_allocator()
	for _ in 0 ..< 32 {
		_ = make([]u8, 64 << 10)
	}
	fmt.println("heap full: no panic")
	os.exit(0)
}

// core.emu_allocator: a request past the heap's end is fatal, with a
// message that says so, as make and append would otherwise drop it quietly.
test_heap_full :: proc() {
	self, err := os.get_executable_path(context.temp_allocator)
	state: os.Process_State
	out, errs: []u8
	if err == nil {
		state, out, errs, err = os.process_exec({command = {self, "heap-full"}}, context.temp_allocator)
	}
	if err != nil {
		fmt.eprintfln("FAIL heap full: cannot run the child: %v", err)
		os.exit(1)
	}
	if state.exited && state.exit_code == 0 || !strings.contains(string(errs), "snapshot heap full: 65536 bytes asked") {
		fmt.eprintfln("FAIL heap full: exited %v, status %d, stdout %q, stderr:\n%s", state.exited, state.exit_code, out, errs)
		os.exit(1)
	}
	fmt.println("ok heap full")
}
