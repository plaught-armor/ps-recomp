// The host copies a memory card store changed, kept for rollback: each key
// (a guest path, a block) with the rollback commit it last changed at, while
// a rewind can still reach back past that commit. A rewind rewrites the host
// copy of every key kept from the restored card, so frames it discards leave
// nothing on the host. Host state (host allocator, not registered with
// snap_add): a rewind must not forget what reached the host. mcserv's file
// store and mc2's raw card image share it.
package ps2_iop

import "core:slice"
import "core:strings"
import "ps:core"

Card_Dirty :: struct($K: typeid) {
	at:      map[K]u64,
	commits: u64, // rollback commits so far
}

card_dirty_init :: proc(d: ^Card_Dirty($K)) {
	d.at = make(map[K]u64, core.host_allocator)
}

// Note a key whose host copy changed.
card_dirty_note :: proc(d: ^Card_Dirty($K), key: K) {
	if entry, ok := &d.at[key]; ok {
		entry^ = d.commits
		return
	}
	when K == string {
		d.at[strings.clone(key, core.host_allocator)] = d.commits
	} else {
		d.at[key] = d.commits
	}
}

// After a snapshot is saved. A rollback commit: forget keys last changed
// before any frame a rewind can still reach. While host writes are off no
// commit counts and rewinds skip their repair, so keys noted before writes
// went off are kept for when they come on. The stores note no key while
// writes are off: those changes never reach the host.
card_dirty_committed :: proc(d: ^Card_Dirty($K), id: int) {
	if id < core.RB_HOOK_ID || core.host_writes_off {return}
	d.commits += 1
	if len(d.at) == 0 {return}
	old := make([dynamic]K, context.temp_allocator)
	for key, at in d.at {
		if d.commits - at > core.RB_FRAMES {append(&old, key)}
	}
	for key in old {
		when K == string {
			k, _ := delete_key(&d.at, key)
			delete(k, core.host_allocator)
		} else {
			delete_key(&d.at, key)
		}
	}
}

// After a snapshot is restored. A rollback: the keys whose host copies the
// store must rewrite from the restored card, sorted (temp allocator); they
// stay noted, since a deeper rewind may follow. A save state: none, and all
// are forgotten (the load also drops the frames rollback held, so no rewind
// reaches back past it). None while host writes are off.
card_dirty_rewound :: proc(d: ^Card_Dirty($K), id: int) -> []K {
	if id < core.RB_HOOK_ID {
		when K == string {
			for key in d.at {delete(key, core.host_allocator)}
		}
		clear(&d.at)
		return nil
	}
	if core.host_writes_off {return nil}
	keys, _ := slice.map_keys(d.at, context.temp_allocator)
	slice.sort(keys)
	for key in keys {d.at[key] = d.commits}
	return keys
}
