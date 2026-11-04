package ps2_cpu

import "core:fmt"

// Learned EE functions (ps2/learned.odin): how many are loaded, the calls
// that ran one, the words compared with RAM to choose, and the calls none
// matched (interpreted). Host state.
learned_loaded: int
learned_calls, learned_words, learned_stale: u64

// One line on stderr, when any are loaded.
learned_print :: proc() {
	if learned_loaded == 0 {return}
	fmt.eprintfln("ee learned: %d functions, %d calls, %d words compared, %d interpreted", learned_loaded, learned_calls, learned_words, learned_stale)
}
