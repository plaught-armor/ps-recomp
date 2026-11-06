package ps2_vu

import "core:c"
import "core:c/libc"
import "core:os"

foreign import lib "system:System"

@(private = "file")
LOCK_EX :: 2
@(private = "file")
LOCK_NB :: 4
@(private = "file")
EWOULDBLOCK :: 35

@(private = "file", default_calling_convention = "c")
foreign lib {
	flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

// Take f's capture lock: an exclusive flock(2), without waiting. It is
// held while f stays open and goes when f is closed. busy: another run
// holds it.
@(private)
capture_lock :: proc(f: ^os.File) -> (held: bool, busy: bool) {
	if flock(c.int(os.fd(f)), LOCK_EX | LOCK_NB) == 0 {return true, false}
	return false, libc.errno()^ == EWOULDBLOCK
}
