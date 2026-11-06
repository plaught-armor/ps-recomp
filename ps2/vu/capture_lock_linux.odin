package ps2_vu

import "core:os"
import "core:sys/linux"

// Take f's capture lock: an exclusive flock(2), without waiting. It is
// held while f stays open and goes when f is closed. busy: another run
// holds it.
@(private)
capture_lock :: proc(f: ^os.File) -> (held: bool, busy: bool) {
	err := linux.flock(linux.Fd(os.fd(f)), {.EX, .NB})
	return err == .NONE, err == .EWOULDBLOCK
}
