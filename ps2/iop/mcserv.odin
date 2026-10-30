// HLE mcserv (sid 0x80000400, old MCSERV function numbers). Each memory card
// port is a host directory, memcard0/ and memcard1/ in mc_root (or in MC,
// so scripted runs can start from a blank card), holding the card's save
// directories and files as plain host files.
//
// The card's contents are emulated state: read from the host directory at
// init into `mc.card` (emulator heap), which every command works on, so
// save states and rollback rewind the card with the game. Each change is
// written through to the host files at once (through a temporary file, so a
// crash mid-write keeps the old file whole). A rollback rewrites the host
// paths changed since the last one from the restored card, so frames it
// discards leave nothing on the host; loading a save state leaves the host
// card as it is.
//
// Listings must not depend on the host: entries are sorted by name and carry
// one fixed timestamp, so runs (and netplay peers) see identical cards.
package ps2_iop

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

MC_PORTS :: 2

// Results, as libmc reports them.
MC_OK :: 0
MC_NO_ENTRY :: -4
MC_DENIED :: -5
MC_NOT_EMPTY :: -6

// Open flags.
MC_RDONLY :: 0x0001
MC_WRONLY :: 0x0002
MC_RDWR :: 0x0003
MC_CREATE_DIR :: 0x0040
MC_CREAT :: 0x0200
MC_TRUNC :: 0x0400

// Entry attributes: 0x8000 exists, 0x0400 always set, 0x0080 closed,
// 0x0020 directory, 0x0010 file, 0x0007 read/write/execute.
MC_ATTR_DIR :: 0x8427
MC_ATTR_FILE :: 0x8497
MC_ATTR_RENAME :: 0x0010 // SetFileInfo: take the name from the entry

// sceMcTblGetDir: two 8-byte times, size, attributes, reserved, name[32].
MC_ENTRY_SIZE :: 64

@(private = "file")
Mc_File :: struct {
	port: u32,
	path: string, // guest path; "" is a free handle
	pos:  i64,
}

// A file or directory on the card, keyed by its guest path.
@(private = "file")
Mc_Node :: struct {
	is_dir: bool,
	data:   [dynamic]u8,
}

@(private = "file")
mc: struct {
	card:    [MC_PORTS]map[string]Mc_Node,
	loaded:  [MC_PORTS]bool,
	cwd:     [MC_PORTS]string, // "" is the root, else "/DIR"
	known:   [MC_PORTS]bool, // GetInfo reported the card once already
	files:   [dynamic]Mc_File, // handle = index
	dir:     [dynamic][MC_ENTRY_SIZE]u8, // pending GetDir results
	dir_pos: int,
}

// Guest paths changed on the host, per port, each with the rollback commit
// it was last changed at; kept while a rewind can still reach back past it.
// Host state (host allocator, not registered with snap_add): a rewind must
// not forget what reached the host.
@(private = "file")
mc_dirty: [MC_PORTS]map[string]u64

// Rollback commits so far, and whether each port's host root exists.
@(private = "file")
mc_commits: u64
@(private = "file")
mc_root_made: [MC_PORTS]bool

// Request layouts. Path commands: {port, slot, flags, max entries, table
// address, name[0x400]}. File commands: {handle, ?, ?, size, offset,
// origin, buffer, param, data[16]}.
@(private = "file") MC_NAME :: 0x14
@(private = "file") MC_DATA :: 0x20

@(private)
mcserv_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r: i32
	switch fno {
	case 0x01: r = mc_get_info(w)
	case 0x02: r = mc_open(w[0], w[2], mc_name(buf))
	case 0x03: r = mc_close(w[0])
	case 0x04: r = mc_seek(w[0], i32(w[4]), w[5])
	case 0x05: r = mc_read(w[0], w[3], w[6], w[7])
	case 0x06: r = mc_write(w[0], w[3], w[6], buf[MC_DATA:][:min(w[5], 16)])
	case 0x0a: r = MC_OK // Flush: changes are written through at once
	case 0x0c: r = mc_chdir(w[0], w[4], mc_name(buf))
	case 0x0d: r = mc_get_dir(w[0], w[2], w[3], w[4], mc_name(buf))
	case 0x0e: r = mc_set_file_info(w[0], w[2], w[4], mc_name(buf))
	case 0x0f: r = mc_delete(w[0], mc_name(buf))
	case 0x10, 0x11: r = MC_OK // Format, Unformat
	case 0x12: r = mc_get_ent_space(w[0], mc_name(buf))
	case 0x14: r = MC_OK // ChangeThreadPriority
	case 0xfe, 0x70: // Init {result, mcserv version, mcman version}
		w[0], w[1], w[2] = 0, 0x20a, 0x20e
		return true
	case:
		return false
	}
	if cpu.debug >= 1 {fmt.eprintfln("mc: fno %02x -> %d", fno, r)}
	w[0] = u32(r)
	return true
}

@(private = "file")
mc_name :: proc(buf: []u8) -> string {
	return strings.clone(string(cstring(raw_data(buf[MC_NAME:]))), context.temp_allocator)
}

@(private = "file")
mc_port_ok :: proc(port: u32) -> bool {return port < MC_PORTS}

// A guest path normalized against the port's current directory: "" for
// the root, else "/A/B". "." and ".." never climb out of the card.
@(private = "file")
mc_guest_path :: proc(port: u32, name: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	full := name if strings.has_prefix(name, "/") else strings.concatenate({mc.cwd[port], "/", name}, context.temp_allocator)
	rest := full
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".":
		case "..": if len(parts) > 0 {pop(&parts)}
		case: append(&parts, part)
		}
	}
	if len(parts) == 0 {return ""}
	return strings.concatenate({"/", strings.join(parts[:], "/", context.temp_allocator)}, context.temp_allocator)
}

// The host directory holding the card directories, where MC is unset; set
// before the game first uses a card.
mc_root := "."

// The host path of a normalized guest path.
@(private = "file")
mc_card_path :: proc(port: u32, guest: string) -> string {
	root := core.env("MC")
	return fmt.tprintf("%s/memcard%d%s", root if root != "" else mc_root, port, guest)
}

// The port's card, read from the host on first use.
@(private = "file")
mc_card :: proc(port: u32) -> ^map[string]Mc_Node {
	card := &mc.card[port]
	if mc.loaded[port] {return card}
	mc.loaded[port] = true
	load :: proc(card: ^map[string]Mc_Node, port: u32, guest: string) {
		infos, _ := os.read_all_directory_by_path(mc_card_path(port, guest), context.temp_allocator)
		for fi in infos {
			// A write cut short by a crash; the target beside it is whole.
			if fi.type != .Directory && strings.has_suffix(fi.name, core.ATOMIC_TMP) {continue}
			path := strings.concatenate({guest, "/", fi.name})
			if fi.type == .Directory {
				card[path] = {is_dir = true}
				load(card, port, path)
			} else {
				data, _ := os.read_entire_file(fi.fullpath, context.temp_allocator)
				node := Mc_Node{}
				append(&node.data, ..data)
				card[path] = node
			}
		}
	}
	load(card, port, "")
	return card
}

// The node at a guest path; the root is a directory with no node.
@(private = "file")
mc_node :: proc(port: u32, guest: string) -> (node: ^Mc_Node, is_dir: bool, ok: bool) {
	if guest == "" {return nil, true, true}
	card := mc_card(port)
	if guest not_in card {return}
	node = &card[guest]
	return node, node.is_dir, true
}

// Write a node (or its removal) through to the host.
@(private = "file")
mc_sync :: proc(port: u32, guest: string) {
	if core.host_writes_off {return}
	mc_mark(port, guest)
	mc_write_host(port, guest)
}

// Note a guest path whose host copy changed.
@(private = "file")
mc_mark :: proc(port: u32, guest: string) {
	if entry, ok := &mc_dirty[port][guest]; ok {
		entry^ = mc_commits
		return
	}
	mc_dirty[port][strings.clone(guest, core.host_allocator)] = mc_commits
}

// Make the host copy of a guest path match the card. A host entry of the
// other kind (a file where the card has a directory, or the reverse) goes
// first.
@(private = "file")
mc_write_host :: proc(port: u32, guest: string) {
	path := mc_card_path(port, guest)
	node, is_dir, ok := mc_node(port, guest)
	if ok && !mc_root_made[port] {
		mc_root_made[port] = os.make_directory_all(mc_card_path(port, "")) == nil
	}
	if ok && os.exists(path) && os.is_dir(path) != is_dir {
		if err := os.remove_all(path); err != nil {
			fmt.eprintfln("mcserv: cannot remove %s: %v", path, err)
		}
	}
	switch {
	case !ok:
		// A host file the loader skipped (a crash's temporary file) keeps a
		// directory from going; say so rather than leave a ghost save behind.
		if err := os.remove(path); err != nil && err != .Not_Exist {
			fmt.eprintfln("mcserv: cannot remove %s: %v", path, err)
		}
	case is_dir: _ = os.make_directory(path)
	case:
		if err := core.write_file_atomic(path, node.data[:]); err != nil {
			fmt.eprintfln("mcserv: cannot write %s: %v", path, err)
		}
	}
}

// GetInfo {?, port, slot, want formatted, want free, want type, ?, result
// address}: the card is always a formatted 8 MB PS2 card.
@(private = "file")
mc_get_info :: proc(w: [^]u32) -> i32 {
	port := w[1]
	if !mc_port_ok(port) {return -1}
	out := ([^]u32)(raw_data(mem.ram_slice(w[7], 0x94)))
	if w[5] != 0 {out[0] = 2} // PS2 card
	if w[4] != 0 {out[1] = 0x2000} // free clusters of 1 KB
	if w[3] != 0 {out[0x24] = 1} // formatted
	// 0: same card as last call, -1: new formatted card.
	known := mc.known[port]
	mc.known[port] = true
	return 0 if known else -1
}

@(private = "file")
mc_open :: proc(port, flags: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	guest := mc_guest_path(port, name)
	node, is_dir, exists := mc_node(port, guest)
	if flags == MC_CREATE_DIR {
		if exists {return MC_NO_ENTRY}
		mc_card(port)[strings.clone(guest)] = {is_dir = true}
		mc_sync(port, guest)
		return MC_OK
	}
	if !exists && flags & MC_CREAT == 0 {return MC_NO_ENTRY}
	if is_dir {return MC_DENIED}
	if !exists {
		mc_card(port)[strings.clone(guest)] = {}
		mc_sync(port, guest)
	} else if flags & MC_TRUNC != 0 {
		clear(&node.data)
		mc_sync(port, guest)
	}
	if cpu.debug >= 1 {fmt.eprintfln("mc: open \"%s\" flags %x", guest, flags)}
	f := Mc_File{port, strings.clone(guest), 0}
	for &e, i in mc.files {
		if e.path == "" {
			e = f
			return i32(i)
		}
	}
	append(&mc.files, f)
	return i32(len(mc.files) - 1)
}

// An open file and its node (nil if the file was deleted while open).
@(private = "file")
mc_file :: proc(h: u32) -> (^Mc_File, ^Mc_Node) {
	if int(h) >= len(mc.files) || mc.files[h].path == "" {return nil, nil}
	f := &mc.files[h]
	node, _, _ := mc_node(f.port, f.path)
	return f, node
}

@(private = "file")
mc_close :: proc(h: u32) -> i32 {
	f, _ := mc_file(h)
	if f == nil {return -1}
	delete(f.path)
	f^ = {}
	return MC_OK
}

@(private = "file")
mc_seek :: proc(h: u32, off: i32, origin: u32) -> i32 {
	f, node := mc_file(h)
	if node == nil {return -1}
	switch origin {
	case 0: f.pos = i64(off)
	case 1: f.pos += i64(off)
	case 2: f.pos = i64(len(node.data)) + i64(off)
	}
	f.pos = max(f.pos, 0)
	return i32(f.pos)
}

// Read {handle, ?, ?, size, ?, ?, buffer, param}. The real server sends the
// unaligned head and tail through the param block; here the whole read
// lands in the buffer and the param block says nothing is left over.
@(private = "file")
mc_read :: proc(h, size, dst, param: u32) -> i32 {
	f, node := mc_file(h)
	if node == nil {return MC_DENIED}
	if param != 0 {
		p := ([^]u32)(raw_data(mem.ram_slice(param, 8)))
		p[0], p[1] = 0, 0
	}
	n := 0
	if f.pos < i64(len(node.data)) {n = copy(mem.ram_slice(dst, size), node.data[f.pos:])}
	f.pos += i64(n)
	return i32(n)
}

// Write {handle, ?, ?, size, ?, head size, buffer, ?, head[16]}: the
// unaligned head bytes travel in the request, the rest is read from EE RAM.
@(private = "file")
mc_write :: proc(h, size, src: u32, head: []u8) -> i32 {
	f, node := mc_file(h)
	if node == nil {return MC_DENIED}
	for b in ([][]u8{head, mem.ram_slice(src, size)}) {
		end := int(f.pos) + len(b)
		if end > len(node.data) {resize(&node.data, end)}
		copy(node.data[f.pos:], b)
		f.pos = i64(end)
	}
	mc_sync(f.port, f.path)
	return i32(len(head) + int(size))
}

// ChDir {port, slot, ?, ?, old dir address, new dir}: reports the current
// directory, then changes to an existing one.
@(private = "file")
mc_chdir :: proc(port, out: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	if out != 0 {
		cur := mc.cwd[port] if mc.cwd[port] != "" else "/"
		dst := mem.ram_slice(out, 1024)
		n := copy(dst[:len(dst) - 1], cur)
		dst[n] = 0
	}
	guest := mc_guest_path(port, name)
	if _, is_dir, ok := mc_node(port, guest); !ok || !is_dir {return MC_NO_ENTRY}
	delete(mc.cwd[port])
	mc.cwd[port] = strings.clone(guest)
	return MC_OK
}

// Glob match with "*" and "?", as mcman matches GetDir patterns.
@(private = "file")
mc_glob :: proc(pat, s: string) -> bool {
	if len(pat) == 0 {return len(s) == 0}
	switch pat[0] {
	case '*':
		for i in 0 ..= len(s) {
			if mc_glob(pat[1:], s[i:]) {return true}
		}
		return false
	case '?':
		return len(s) > 0 && mc_glob(pat[1:], s[1:])
	case:
		return len(s) > 0 && s[0] == pat[0] && mc_glob(pat[1:], s[1:])
	}
}

@(private = "file")
mc_entry :: proc(name: string, size: i64, is_dir: bool) -> (e: [MC_ENTRY_SIZE]u8) {
	// {?, sec, min, hour, day, month, year lo, year hi}: 2006-01-01 00:00:00.
	stamp := [8]u8{0, 0, 0, 0, 1, 1, u8(2006 & 0xff), u8(2006 >> 8)}
	copy(e[0:8], stamp[:])
	copy(e[8:16], stamp[:])
	(^u32)(&e[0x10])^ = u32(size)
	(^u16)(&e[0x14])^ = MC_ATTR_DIR if is_dir else MC_ATTR_FILE
	copy(e[0x20:0x3f], name)
	return
}

// GetDir {port, slot, flags, max entries, table, pattern}: flags 0 starts a
// search, anything else continues the last one.
@(private = "file")
mc_get_dir :: proc(port, flags, max_entries, table: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	if flags == 0 {
		clear(&mc.dir)
		mc.dir_pos = 0
		guest := mc_guest_path(port, name)
		slash := strings.last_index_byte(guest, '/')
		pat := guest[slash + 1:]
		dir := guest[:max(slash, 0)]
		if _, is_dir, ok := mc_node(port, dir); !ok || !is_dir {return MC_NO_ENTRY}
		if slash > 0 {
			// Inside a save directory the listing starts with "." and "..".
			for n in ([]string{".", ".."}) {
				if mc_glob(pat, n) {append(&mc.dir, mc_entry(n, 0, true))}
			}
		}
		names := make([dynamic]string, context.temp_allocator)
		for path in mc_card(port) {
			if mc_parent(path) == dir {append(&names, path[len(dir) + 1:])}
		}
		slice.sort(names[:])
		for n in names {
			if !mc_glob(pat, n) {continue}
			path := strings.concatenate({dir, "/", n}, context.temp_allocator)
			node := mc_card(port)[path]
			// A directory's length is its entry count, "." and ".." included.
			size := len(node.data)
			if node.is_dir {
				size = 2
				for p in mc_card(port) {
					if mc_parent(p) == path {size += 1}
				}
			}
			append(&mc.dir, mc_entry(n, i64(size), node.is_dir))
		}
	}
	n := min(int(max_entries), len(mc.dir) - mc.dir_pos)
	if n > 0 {
		out := mem.ram_slice(table, u32(n) * MC_ENTRY_SIZE)
		for i in 0 ..< n {
			copy(out[i * MC_ENTRY_SIZE:][:MC_ENTRY_SIZE], mc.dir[mc.dir_pos + i][:])
		}
		mc.dir_pos += n
	}
	if cpu.debug >= 1 {fmt.eprintfln("mc: getdir \"%s\" flags %d -> %d", name, flags, n)}
	return i32(max(n, 0))
}

@(private = "file")
mc_parent :: proc(path: string) -> string {
	return path[:max(strings.last_index_byte(path, '/'), 0)]
}

// SetFileInfo {port, slot, flags, ?, entry, name}: only renames are kept;
// entries carry fixed times and attributes.
@(private = "file")
mc_set_file_info :: proc(port, flags, table: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	guest := mc_guest_path(port, name)
	if guest == "" {return MC_DENIED}
	if _, _, ok := mc_node(port, guest); !ok {return MC_NO_ENTRY}
	if flags & MC_ATTR_RENAME == 0 {return MC_OK}
	new_name := string(cstring(raw_data(mem.ram_slice(table + 0x20, 0x20))))
	to := strings.concatenate({mc_parent(guest), "/", new_name}, context.temp_allocator)
	if _, _, taken := mc_node(port, to); taken {return MC_DENIED}
	// The entry and, for a directory, everything under it.
	card := mc_card(port)
	moved := make([dynamic]string, context.temp_allocator)
	for path in card {
		if path == guest || strings.has_prefix(path, guest) && path[len(guest)] == '/' {append(&moved, path)}
	}
	for path in moved {
		key, node := delete_key(card, path)
		card[strings.concatenate({to, path[len(guest):]})] = node
		delete(key)
	}
	for &f in mc.files {
		if f.port == port && f.path == guest {
			delete(f.path)
			f.path = strings.clone(to)
		}
	}
	// The host copy keeps the old name while writes are off. Nothing on ps2
	// sets host_writes_off yet; a ps2 user that clears it again must first
	// rewrite the card dir from mc.card.
	if core.host_writes_off {return MC_OK}
	for path in moved {
		mc_mark(port, path)
		mc_mark(port, strings.concatenate({to, path[len(guest):]}, context.temp_allocator))
	}
	if err := os.rename(mc_card_path(port, guest), mc_card_path(port, to)); err != nil {
		fmt.eprintfln("mcserv: cannot rename %s: %v", mc_card_path(port, guest), err)
	}
	return MC_OK
}

@(private = "file")
mc_delete :: proc(port: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	guest := mc_guest_path(port, name)
	if guest == "" {return MC_DENIED}
	if _, is_dir, ok := mc_node(port, guest); !ok {
		return MC_NO_ENTRY
	} else if is_dir {
		for path in mc_card(port) {
			if mc_parent(path) == guest {return MC_NOT_EMPTY}
		}
	}
	key, node := delete_key(mc_card(port), guest)
	delete(key)
	delete(node.data)
	mc_sync(port, guest)
	return MC_OK
}

// GetEntSpace: free entries in a directory; a directory cluster holds plenty.
@(private = "file")
mc_get_ent_space :: proc(port: u32, name: string) -> i32 {
	if !mc_port_ok(port) {return -1}
	_, is_dir, ok := mc_node(port, mc_guest_path(port, name))
	return 0xfe if ok && is_dir else MC_NO_ENTRY
}

// Emulated state, saved and restored by snapshots (snap.odin).
mcserv_snap :: proc() {
	core.snap_add(&mc)
}

// Read both cards (on the emulator heap, so every snapshot holds them
// loaded) and hook rollback to repair the host copies.
mcserv_init :: proc() {
	for port in 0 ..< u32(MC_PORTS) {
		mc_card(port)
		mc_dirty[port] = make(map[string]u64, core.host_allocator)
	}
	context.allocator = core.host_allocator
	append(&core.snap_hooks, core.Snap_Hook{save = mc_committed, load = mc_rewound})
}

// After a snapshot is saved. A rollback commit: forget paths last changed
// before any frame a rewind can still reach. While host writes are off,
// rewinds skip their repair, so the paths are kept for when they come on.
@(private = "file")
mc_committed :: proc(id: int) {
	if id < core.RB_HOOK_ID || core.host_writes_off {return}
	mc_commits += 1
	for port in 0 ..< u32(MC_PORTS) {
		dirty := &mc_dirty[port]
		if len(dirty) == 0 {continue}
		old := make([dynamic]string, context.temp_allocator)
		for path, at in dirty {
			if mc_commits - at > core.RB_FRAMES {append(&old, path)}
		}
		for path in old {
			key, _ := delete_key(dirty, path)
			delete(key, core.host_allocator)
		}
	}
}

// After a snapshot is restored. A rollback: rewrite each host path changed
// within reach of a rewind from the restored card, parents before children,
// and removals children first; the paths stay noted, since a deeper rewind
// may follow. A save state: leave the host card alone (the load also drops
// the frames rollback held, so no rewind reaches back past it).
@(private = "file")
mc_rewound :: proc(id: int) {
	for port in 0 ..< u32(MC_PORTS) {
		dirty := &mc_dirty[port]
		if id < core.RB_HOOK_ID {
			for path in dirty {delete(path, core.host_allocator)}
			clear(dirty)
			continue
		}
		if core.host_writes_off {continue}
		paths, _ := slice.map_keys(dirty^, context.temp_allocator)
		slice.sort(paths)
		for path in paths {
			if _, _, ok := mc_node(port, path); ok {mc_write_host(port, path)}
			dirty[path] = mc_commits
		}
		#reverse for path in paths {
			if _, _, ok := mc_node(port, path); !ok {mc_write_host(port, path)}
		}
	}
}
