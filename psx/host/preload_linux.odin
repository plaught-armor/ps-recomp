// Background machines on Linux: fork().
package psx_host

import "core:sys/linux"
import "core:sys/posix"

import "ps:core"
import spu "../spu"
import render "../render"
import io "../io"

@(private = "file")
PR_SET_PDEATHSIG :: 1

// Fork a child. In the parent, returns its pid; in the child, 0. ok is
// false when the fork failed, or was not tried inside a frozen-time pass:
// the pass's saved picture may be the Vulkan target's plane, a mapping the
// child would share with the parent.
preload_fork :: proc() -> (pid: i32, ok: bool) {
	if io.events_frozen {
		return 0, false
	}
	render.raster_sync()
	// The child mixes on its own thread alone, from where the parent's mix
	// stands.
	spu.spu_sync()
	parent := linux.getpid()
	// libc's fork, not the raw syscall: it runs the atfork handlers SDL and
	// the C library's own locks rely on.
	render.gpu_fork_save()
	p := posix.fork()
	if p != 0 {
		render.gpu_fork_parent()
	}
	if p < 0 {
		return 0, false
	}
	if p == 0 {
		// End with the parent: a load left running when the game quits.
		// core's prctl reads all four argument slots.
		linux.prctl(PR_SET_PDEATHSIG, uint(linux.Signal.SIGKILL), 0, 0, 0)
		if linux.getppid() != parent {
			linux.exit_group(0)
		}
		io.preload_child = true
		core.host_writes_off = true
		render.gpu_fork_child()
		core.audio.dev = 0
		core.audio.dump = nil
		// The input record is the parent's: the child's own pad reads would
		// land in it out of order.
		record_close()
	}
	return i32(p), true
}

// End the child at once, running no exit handlers of the parent's (window,
// sound, files).
preload_exit :: proc() -> ! {
	linux.exit_group(0)
}

// Whether the child `pid` has ended; reaps it when it has.
preload_ended :: proc(pid: i32) -> bool {
	status: u32
	ended, err := linux.waitpid(linux.Pid(pid), &status, {.WNOHANG}, nil)
	return ended != 0 || err != .NONE
}

// Stop the child `pid` and reap it.
preload_kill :: proc(pid: i32) {
	linux.kill(linux.Pid(pid), .SIGKILL)
	status: u32
	linux.waitpid(linux.Pid(pid), &status, {}, nil)
}

// Memory of `size` bytes the parent and every later child share, zeroed.
preload_shared :: proc(size: int) -> rawptr {
	p, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED, .ANONYMOUS})
	return err == .NONE ? p : nil
}
