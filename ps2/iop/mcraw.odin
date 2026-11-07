// The raw memory card behind the HLE mc2_d driver (dbcman.odin): an 8 MiB
// card of 16384 pages, each 512 data bytes and 16 spare bytes, erased in
// blocks of 16 pages to all 0xff. A game that drives the card through mc2_d
// keeps its own filesystem on it; the driver only reads, writes and erases
// pages.
//
// The host copy of port N's card is the image memcard<N>.ps2, 8,650,752
// bytes of raw pages in order, beside mcserv's memcard<N> directories under
// the same root. Port 0 always has a card: a blank, unformatted one until
// the game first writes it, when the image is made. Port 1 has one only
// while its image exists. An image of any other size is refused, and that
// port has no card, so a wrong file is never written over.
//
// The card is emulated state: a table of blocks per port, each allocated on
// the emulated heap at its first write and freed when erased, so a snapshot
// copies only the blocks in use and a rewind restores them. The image is
// read in at init. Changed blocks wait in a pending set and are written in
// place into the image at most once a frame, at vblank before any snapshot,
// and at exit (one write per block, then one sync), so no fsync lands on a
// command. A write that fails keeps its blocks pending for the next flush,
// logged once until one succeeds. Changes are also kept in Card_Dirty for
// rollback. Under FLAT and on wasi the image goes
// through the same core:os calls; web/wasi.js keeps it in the page's memory,
// lost when the page goes, as mcserv's directories are.
package ps2_iop

import "core:fmt"
import "core:os"
import "ps:core"

MCRAW_PORTS :: 2
MCRAW_PAGE :: 528 // 512 data bytes, 16 spare
MCRAW_PPB :: 16 // pages per erase block
MCRAW_BLOCKS :: 1024
MCRAW_PAGES :: MCRAW_BLOCKS * MCRAW_PPB
MCRAW_BLOCK :: MCRAW_PAGE * MCRAW_PPB
MCRAW_SIZE :: MCRAW_BLOCK * MCRAW_BLOCKS // 8,650,752 bytes

Mcraw_Block :: [MCRAW_BLOCK]u8

Mcraw_Card :: struct {
	present: bool,
	blocks:  [MCRAW_BLOCKS]^Mcraw_Block, // nil: erased
}

mcraw: [MCRAW_PORTS]Mcraw_Card

// Host state: the blocks not yet written to the image, whether its last
// write failed, and what rollback keeps.
@(private = "file")
mcraw_pending: [MCRAW_PORTS][MCRAW_BLOCKS]bool
@(private = "file")
mcraw_any_pending: [MCRAW_PORTS]bool
@(private = "file")
mcraw_failed: [MCRAW_PORTS]bool
@(private = "file")
mcraw_dirty: [MCRAW_PORTS]Card_Dirty(u32)

mcraw_snap :: proc() {core.snap_add(&mcraw)}

// Insert each port's card from its image (boot sets the root first). Read
// here, before the first snapshot, so a rewind never reaches back past it.
mcraw_init :: proc() {
	for port in 0 ..< MCRAW_PORTS {
		c := &mcraw[port]
		for &b in c.blocks {if b != nil {free(b, core.emu_allocator())}}
		c^ = {}
		mcraw_pending[port] = {}
		mcraw_any_pending[port] = false
		mcraw_failed[port] = false
		mcraw_load(port)
	}
	if !mcraw_hooked {
		mcraw_hooked = true
		for port in 0 ..< MCRAW_PORTS {card_dirty_init(&mcraw_dirty[port])}
		append(&core.snap_hooks, core.Snap_Hook{save = mcraw_committed, load = mcraw_rewound})
	}
}

@(private = "file")
mcraw_hooked: bool

// The host path of port `port`'s image.
mcraw_path :: proc(port: int) -> string {
	return fmt.tprintf("%s/memcard%d.ps2", mc_host_root(), port)
}

// Whether port `port` has a card.
mcraw_present :: proc(port: int) -> bool {return mcraw[port].present}

// Read port `port`'s image in: only blocks that are not erased take memory.
@(private = "file")
mcraw_load :: proc(port: int) {
	c := &mcraw[port]
	path := mcraw_path(port)
	if !os.exists(path) {
		c.present = port == 0 // blank
		return
	}
	data, err := os.read_entire_file(path, core.host_allocator)
	defer delete(data, core.host_allocator)
	switch {
	case err != nil:
		fmt.eprintfln("mc2: cannot read %s: %v; no card in port %d", path, err, port)
		return
	case len(data) != MCRAW_SIZE:
		fmt.eprintfln("mc2: %s is %d bytes, not %d; no card in port %d", path, len(data), MCRAW_SIZE, port)
		return
	}
	c.present = true
	for b in 0 ..< MCRAW_BLOCKS {
		src := data[b * MCRAW_BLOCK:][:MCRAW_BLOCK]
		if mcraw_erased(src) {continue}
		blk := new(Mcraw_Block, core.emu_allocator())
		copy(blk[:], src)
		c.blocks[b] = blk
	}
}

@(private = "file")
mcraw_erased :: proc(b: []u8) -> bool {
	for x in b {if x != 0xff {return false}}
	return true
}

// Read the first len(dst) bytes of page `page`; false past the card or the
// page.
mcraw_read :: proc(port: int, page: u32, dst: []u8) -> bool {
	if page >= MCRAW_PAGES || len(dst) > MCRAW_PAGE {return false}
	blk := mcraw[port].blocks[page / MCRAW_PPB]
	if blk == nil {
		for &x in dst {x = 0xff}
	} else {
		copy(dst, blk[page % MCRAW_PPB * MCRAW_PAGE:][:len(dst)])
	}
	return true
}

// Write src over the start of page `page`; the rest of the page keeps what
// it held. False past the card or the page, or with no card.
mcraw_write :: proc(port: int, page: u32, src: []u8) -> bool {
	if !mcraw[port].present || page >= MCRAW_PAGES || len(src) > MCRAW_PAGE {return false}
	c := &mcraw[port]
	b := page / MCRAW_PPB
	if c.blocks[b] == nil {
		c.blocks[b] = new(Mcraw_Block, core.emu_allocator())
		for &x in c.blocks[b] {x = 0xff}
	}
	copy(c.blocks[b][page % MCRAW_PPB * MCRAW_PAGE:], src)
	mcraw_touch(port, b)
	return true
}

// Erase the block holding page `page`. False past the card, or with no card.
mcraw_erase :: proc(port: int, page: u32) -> bool {
	if !mcraw[port].present || page >= MCRAW_PAGES {return false}
	c := &mcraw[port]
	b := page / MCRAW_PPB
	if c.blocks[b] != nil {
		free(c.blocks[b], core.emu_allocator())
		c.blocks[b] = nil
	}
	mcraw_touch(port, b)
	return true
}

// A block changed: to be written to the image. While host writes are off
// the change is not noted at all, and never reaches the image.
@(private = "file")
mcraw_touch :: proc(port: int, b: u32) {
	if core.host_writes_off {return}
	card_dirty_note(&mcraw_dirty[port], b)
	mcraw_pending[port][b] = true
	mcraw_any_pending[port] = true
}

// Write each port's pending blocks to its image: at vblank, before any
// snapshot is taken or restored, and at exit.
mcraw_flush_all :: proc() {
	for port in 0 ..< MCRAW_PORTS {mcraw_flush(port)}
}

// Write port `port`'s pending blocks to the image. On a failure they all
// stay pending, to be written again at the next flush; the first failure
// after a success is logged.
@(private = "file")
mcraw_flush :: proc(port: int) {
	if !mcraw_any_pending[port] || core.host_writes_off {return}
	blocks := make([dynamic]u32, context.temp_allocator)
	for p, b in mcraw_pending[port] {if p {append(&blocks, u32(b))}}
	if msg := mcraw_write_host(port, blocks[:]); msg != "" {
		if !mcraw_failed[port] {fmt.eprintln(msg)}
		mcraw_failed[port] = true
		return
	}
	mcraw_failed[port] = false
	mcraw_pending[port] = {}
	mcraw_any_pending[port] = false
}

// Make blocks of the image match the card; the whole image when there is
// none yet. "" on success, else what failed (temp allocator).
@(private = "file")
mcraw_write_host :: proc(port: int, blocks: []u32) -> string {
	path := mcraw_path(port)
	c := &mcraw[port]
	bytes :: proc(c: ^Mcraw_Card, b: u32, dst: []u8) {
		if c.blocks[b] == nil {
			for &x in dst {x = 0xff}
		} else {
			copy(dst, c.blocks[b][:])
		}
	}
	if !os.exists(path) {
		img := make([]u8, MCRAW_SIZE, core.host_allocator)
		defer delete(img, core.host_allocator)
		for b in 0 ..< u32(MCRAW_BLOCKS) {bytes(c, b, img[b * MCRAW_BLOCK:][:MCRAW_BLOCK])}
		if err := os.make_directory_all(mc_host_root()); err != nil && err != .Exist {
			return fmt.tprintf("mc2: cannot make %s: %v", mc_host_root(), err)
		}
		if err := core.write_file_atomic(path, img); err != nil {
			return fmt.tprintf("mc2: cannot write %s: %v", path, err)
		}
		return ""
	}
	f, err := os.open(path, {.Write})
	if err != nil {return fmt.tprintf("mc2: cannot open %s: %v", path, err)}
	defer os.close(f)
	buf: Mcraw_Block
	for b in blocks {
		bytes(c, b, buf[:])
		if _, err = os.write_at(f, buf[:], i64(b) * MCRAW_BLOCK); err != nil {
			return fmt.tprintf("mc2: cannot write %s: %v", path, err)
		}
	}
	if err = os.sync(f); err != nil {return fmt.tprintf("mc2: cannot sync %s: %v", path, err)}
	return ""
}

@(private = "file")
mcraw_committed :: proc(id: int) {
	for port in 0 ..< MCRAW_PORTS {card_dirty_committed(&mcraw_dirty[port], id)}
}

// After a snapshot is restored. A rollback: each block changed within reach
// of a rewind is pending, to be rewritten from the restored card at the next
// flush. A save state: leave the image alone, as mcserv does.
@(private = "file")
mcraw_rewound :: proc(id: int) {
	for port in 0 ..< MCRAW_PORTS {
		mcraw_pending[port] = {}
		mcraw_any_pending[port] = false
		for b in card_dirty_rewound(&mcraw_dirty[port], id) {
			mcraw_pending[port][b] = true
			mcraw_any_pending[port] = true
		}
	}
}
