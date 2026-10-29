// Host files that must survive a crash mid-write (memory cards).
package core

import "core:fmt"
import "core:os"

// The suffix of the temporary file write_file_atomic writes first. A crash
// can leave one behind next to the target; loaders that list a directory
// skip it. Long and odd, so no guest file name a game picks ends in it.
ATOMIC_TMP :: ".ps-recomp-tmp"

// While set, card writes stay in memory and never reach the host: a forked
// background copy of the game, or a replay, must not change the real cards.
// The game still sees each write succeed.
host_writes_off: bool

// Replace the file at path with data: write <path>.ps-recomp-tmp, sync it to
// disk, then rename it over the target, so the old contents stay whole until
// the new ones are, through a crash or a power loss (on macOS fsync does
// not flush the drive cache). A failed write removes its temporary file.
write_file_atomic :: proc(path: string, data: []u8) -> os.Error {
	if host_writes_off {
		return nil
	}
	tmp := fmt.tprintf("%s%s", path, ATOMIC_TMP)
	err := write_synced(tmp, data)
	if err == nil {
		err = os.rename(tmp, path)
	}
	if err != nil {
		_ = os.remove(tmp)
	}
	return err
}

@(private = "file")
write_synced :: proc(path: string, data: []u8) -> os.Error {
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		return err
	}
	n: int
	n, err = os.write(f, data)
	if err == nil && n != len(data) {
		err = .Short_Write
	}
	if err == nil {
		err = os.sync(f)
	}
	if cerr := os.close(f); err == nil {
		err = cerr
	}
	return err
}
