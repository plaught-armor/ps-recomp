#+build windows, wasi
package ps2_vu

import "core:os"

// No capture lock: always held. On Windows a second run capturing into the
// same file is not caught. On wasi the player's data directory is memory
// of its own run (web/wasi.js), which no other run can open, and a FLAT
// build captures only when asked (play/main.odin).
@(private)
capture_lock :: proc(_: ^os.File) -> (held: bool, busy: bool) {
	return true, false
}
