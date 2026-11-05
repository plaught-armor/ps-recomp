// No launcher or export on wasm: the launcher is a desktop window over the
// library (launcher_window.odin), and an export writes a repository to
// build natively (export.odin). A disc image runs as on any host.
package play

import "core:fmt"

launcher :: proc(exe: string) -> int {
	fmt.eprintln("play: no launcher on wasm; give a disc image")
	return 2
}

export :: proc(image, dir: string) -> int {
	fmt.eprintln("play: no export on wasm")
	return 2
}
