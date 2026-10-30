// The SIF link to the IOP, emulated at the sifcmd packet level.
//
// There is no IOP processor: DMA the EE sends to the IOP lands in an 8 MB
// buffer, command packets addressed to the IOP's command buffer are handled
// here, and replies are written into the EE's receive buffer followed by a
// SIF0 DMAC interrupt, exactly as the real IOP's sifcmd would deliver them.
// RPC servers (loadfile, file I/O, CD, pad, ...) are implemented in Odin.
package ps2_iop

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import cpu "../cpu"
import mem "../mem"

IOP_RAM_SIZE :: 8 << 20
IOP_CMDBUF :: 0x0001f000 // where the IOP receives command packets
IOP_SERVERS :: 0x00100000 // fake server descriptors and receive buffers

SIF_CMD_CHANGE_SADDR :: 0x80000000
SIF_CMD_SET_SREG :: 0x80000001
SIF_CMD_INIT_CMD :: 0x80000002
SIF_CMD_RESET :: 0x80000003
SIF_CMD_RPC_END :: 0x80000008
SIF_CMD_RPC_BIND :: 0x80000009
SIF_CMD_RPC_CALL :: 0x8000000a
SIF_CMD_RPC_RDATA :: 0x8000000c

SIF_STAT_SIFINIT :: 0x10000
SIF_STAT_CMDINIT :: 0x20000
SIF_STAT_BOOTEND :: 0x40000

iop_ram: []u8

// Host directory holding the disc's files; `cdrom0:\X;1` opens disc_dir/X.
// After disc_image_open, the disc image is read in its place.
disc_dir := "."

// An RPC server: gets the function number and the request in the server's
// buffer, writes its reply into the same buffer.
Rpc_Server :: proc(fno: u32, buf: []u8, send_size: u32) -> (ok: bool)

sif: struct {
	mscom, smcom, msflg, smflg, ctrl, bd6: u32,
	sreg:      [32]u32,
	ee_buf:    u32, // EE receive buffer for replies
	replies:   [dynamic][]u8,
	servers:   map[u32]Rpc_Server,
	bound:     map[u32]u32, // sid -> fake server descriptor address
	next_dma:  i32,
}

sif_init :: proc() {
	iop_ram = core.snap_area(IOP_RAM_SIZE)
	sif.smflg = SIF_STAT_SIFINIT | SIF_STAT_CMDINIT | SIF_STAT_BOOTEND
	sif.sreg[0] = IOP_CMDBUF // SIF_SYSREG_SUBADDR
	sif.next_dma = 1
	pad_init()
	sif.servers[0x80000006] = loadfile_server
	sif.servers[0x80000001] = fileio_server
	sif.servers[0x80000592] = cdvd_init_server
	sif.servers[0x80000593] = cdvd_scmd_server
	sif.servers[0x80000595] = cdvd_ncmd_server
	sif.servers[0x80000597] = cdvd_search_server
	sif.servers[0x8000059a] = cdvd_ready_server
	sif.servers[0x8000059c] = cdvd_ready_server
	sif.servers[0x80000003] = iop_heap_server
	sif.servers[0x80000400] = mcserv_server
	sif.servers[0x80000100] = padman_server
	sif.servers[0x80000101] = padman_server
	sif.servers[0x80000900] = mtap_server
	sif.servers[0x80000701] = sdr_server
	sif.servers[0x90000200] = adx_server
}

iop_u32 :: #force_inline proc(a: u32) -> ^u32 {
	return (^u32)(&iop_ram[a & (IOP_RAM_SIZE - 4)])
}

sif_reg_read :: proc(o: u32) -> u32 {
	switch o &~ 0xf {
	case 0xf200: return sif.mscom
	case 0xf210: return sif.smcom
	case 0xf220: return sif.msflg
	case 0xf230: return sif.smflg
	case 0xf240: return sif.ctrl
	case 0xf260: return sif.bd6
	}
	return 0
}

sif_reg_write :: proc(o: u32, v: u32) {
	switch o &~ 0xf {
	case 0xf200: sif.mscom = v
	case 0xf210: sif.smcom = v
	case 0xf220: sif.msflg |= v
	case 0xf230: // EE writes clear bits; the HLE IOP stays booted
	case 0xf240: sif.ctrl = v
	case 0xf260: sif.bd6 = v
	}
}

// SifSetReg / SifGetReg: 1-4 are the hardware registers, 0x80000000+ the
// software registers sifcmd keeps.
sif_reg_set :: proc(reg, v: u32) {
	switch reg {
	case 1: sif.mscom = v
	case 2: sif.smcom = v
	case 3: sif.msflg |= v
	case 4:
	case 0x80000000: // SUBADDR: cleared on IOP reset, but the HLE IOP's
		// command buffer never moves
	case:
		if reg & 0x80000000 != 0 {sif.sreg[reg & 31] = v}
	}
}

sif_reg_get :: proc(reg: u32) -> u32 {
	switch reg {
	case 1: return sif.mscom
	case 2: return sif.smcom
	case 3: return sif.msflg
	case 4: return sif.smflg
	}
	if reg & 0x80000000 != 0 {return sif.sreg[reg & 31]}
	return 0
}

sif_dma_stat :: proc(id: i32) -> i64 {
	return -1 // every transfer completes immediately
}

// SifSetDma(list, count): copy each {src, dest, size, attr} to IOP memory and
// act on command packets.
sif_set_dma :: proc(list, count: u32) -> u32 {
	for n in 0 ..< count {
		e := list + n * 16
		src, dest, size := mem.rd32(e), mem.rd32(e + 4), mem.rd32(e + 8)
		d := dest & (IOP_RAM_SIZE - 1)
		size = min(size, IOP_RAM_SIZE - d)
		copy(iop_ram[d:][:size], mem.ram_slice(src, size))
		if cpu.debug == 2 {fmt.eprintfln("sif: dma %08x -> %08x size %x (%d/%d)", src, dest, size, n, count)}
		if d == IOP_CMDBUF {sif_command(d)}
		adx_dma(d, size)
	}
	id := sif.next_dma
	sif.next_dma = sif.next_dma % 0xffff + 1
	return u32(id)
}

// Queue a packet for the EE: header {psize | dsize << 8, dest, cid, opt}.
@(private)
sif_reply :: proc(cid: u32, opt: u32, payload: []u32) {
	p := make([]u8, 16 + 4 * len(payload))
	w := ([^]u32)(raw_data(p))
	w[0] = u32(len(p))
	w[2] = cid
	w[3] = opt
	for v, i in payload {w[4 + i] = v}
	append(&sif.replies, p)
	if !cpu.in_interrupt {cpu.next_event = cpu.state.cycles}
}

// Move the next queued reply into the EE buffer once the EE has consumed
// the previous one. Called while delivering interrupts.
sif_pump :: proc() {
	if len(sif.replies) == 0 || sif.ee_buf == 0 || mem.dmac_stat & (1 << mem.DMA_SIF0) != 0 {return}
	p := sif.replies[0]
	ordered_remove(&sif.replies, 0)
	copy(mem.ram_slice(sif.ee_buf, u32(len(p))), p)
	delete(p)
	mem.dmac_stat |= 1 << mem.DMA_SIF0
}

@(private)
sif_command :: proc(a: u32) {
	cid := iop_u32(a + 8)^
	if cpu.debug == 2 {fmt.eprintfln("sif: cmd %08x opt %x a0 %08x ee_buf %08x", cid, iop_u32(a + 12)^, iop_u32(a + 16)^, sif.ee_buf)}
	opt := iop_u32(a + 12)^
	arg :: proc(a: u32, n: u32) -> u32 {return iop_u32(a + 16 + 4 * n)^}
	switch cid {
	case SIF_CMD_CHANGE_SADDR:
		sif.ee_buf = arg(a, 0)
	case SIF_CMD_SET_SREG:
		sif.sreg[arg(a, 0) & 31] = arg(a, 1)
	case SIF_CMD_INIT_CMD:
		if opt == 0 {
			sif_reply(SIF_CMD_INIT_CMD, 1, {})
			sif.sreg[2] = 1 // SIF_SYSREG_RPCINIT
		}
		// sceSifInitRpc then spins on the EE-side software register
		// SIF_SREG_RPCINIT (0), which the IOP sets with a SET_SREG packet.
		sif_reply(SIF_CMD_SET_SREG, 0, {0, 1})
	case SIF_CMD_RESET:
		path := cstring(&iop_ram[a + 24])
		fmt.eprintfln("sif: IOP reset \"%s\"", path)
		clear(&sif.bound)
		sif.ee_buf = 0
		clear(&sif.replies)
	case SIF_CMD_RPC_BIND:
		rec_id, pkt, rpc_id, client, sid := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3), arg(a, 4)
		sd, ok := sif.bound[sid]
		if !ok {
			sd = IOP_SERVERS + u32(len(sif.bound)) * 0x10000
			sif.bound[sid] = sd
			if sid not_in sif.servers {
				core.compat_unknown(.Sif_Bind, sid)
				fmt.eprintfln("sif: bind to unimplemented server %08x", sid)
			}
		}
		iop_u32(sd)^ = sid
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_BIND, sd, sd + 0x100, sd + 0x100})
	case SIF_CMD_RPC_CALL:
		rec_id, pkt, rpc_id, client := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3)
		fno, send_size, receive, recv_size, server := arg(a, 4), arg(a, 5), arg(a, 6), arg(a, 7), arg(a, 9)
		sid := iop_u32(server)^
		buf := iop_ram[(server + 0x100) & (IOP_RAM_SIZE - 1):][:0xff00]
		handler, ok := sif.servers[sid]
		if !ok || !handler(fno, buf, send_size) {
			core.compat_unknown(.Sif_Rpc, sid, fno)
			fmt.eprintfln("sif: unhandled rpc %08x fno %d send %d recv %d", sid, fno, send_size, recv_size)
		}
		if receive != 0 && recv_size != 0 {
			copy(mem.ram_slice(receive, recv_size), buf[:min(recv_size, u32(len(buf)))])
		}
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_CALL, server, 0, 0})
	case SIF_CMD_RPC_RDATA:
		rec_id, pkt, rpc_id, client := arg(a, 0), arg(a, 1), arg(a, 2), arg(a, 3)
		src, dest, size := arg(a, 4), arg(a, 5), arg(a, 6)
		s := src & (IOP_RAM_SIZE - 1)
		copy(mem.ram_slice(dest, size), iop_ram[s:][:min(size, IOP_RAM_SIZE - s)])
		sif_reply(SIF_CMD_RPC_END, 0, {rec_id, pkt, rpc_id, client, SIF_CMD_RPC_RDATA, 0, 0, 0})
	case:
		if cid & 0x80000000 == 0 {
			fmod_command(cid, opt, a)
		} else {
			core.compat_unknown(.Sif_Cmd, cid)
			fmt.eprintfln("sif: unhandled command %08x", cid)
		}
	}
}

// ------------------------------------------------------------- servers

// loadfile: modules are native here, so loading one only reports success.
@(private)
loadfile_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0: // LoadModule {result, modres, path[252], args[252]}
		fmt.eprintfln("sif: load module \"%s\"", cstring(&buf[8]))
		w[0] = 2
		w[1] = 0
		return true
	case 6: // LoadModuleBuffer {IOP address, arg length, unused[252], args[252]}:
		// the EE copied the IRX image to IOP RAM first
		if cpu.debug >= 1 {fmt.eprintfln("sif: load module buffer %x \"%s\"", w[0], irx_name(w[0]))}
		w[0] = 2
		w[1] = 0
		return true
	case 255: // version handshake: the EE library checks for "3000"
		copy(buf, "3000")
		return true
	}
	return false
}

// The name in an IRX image's .iopmod header, or "" if `a` holds no IRX.
@(private)
irx_name :: proc(a: u32) -> string {
	PT_SCE_IOPMOD :: 0x70000080
	img := iop_ram[a & (IOP_RAM_SIZE - 1):]
	if len(img) < 0x34 || string(img[:4]) != "\x7fELF" {return ""}
	ph := (^u32)(&img[0x1c])^
	if ph > u32(len(img)) - 8 || (^u32)(&img[ph])^ != PT_SCE_IOPMOD {return ""}
	off := (^u32)(&img[ph + 4])^ + 0x1a // name follows {info, entry, gp, sizes, version}
	if off >= u32(len(img)) {return ""}
	return strings.truncate_to_byte(string(img[off:][:min(64, u32(len(img)) - off)]), 0)
}

// fileio: the EE library sends {sema, result ptr, result size, args...} and
// waits on `sema`. The IOP writes a reply {sema, command, result ptr, result
// size, result, extra...} to the EE buffer it was given at init, then sends
// command 0x80000011, whose EE handler copies the result and signals `sema`.
FILEIO_REPLY :: 0x80000011
ENOENT :: 2
EBADF :: 9

@(private)
fileio: struct {
	reply_buf: u32,
	files:     [dynamic]Iop_File, // fd = index; nil handle is a free slot
}

@(private)
Iop_File :: struct {
	using file: Disc_File,
	pos:        i64,
}

@(private)
fileio_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	if fno == 255 { // init: {reply buffer, second buffer} -> {version, slots}
		fileio.reply_buf = w[0]
		copy(buf, "3000")
		w[1] = 0 // one reply buffer
		return true
	}
	result: i32
	extra: [3]u32 // READ: unaligned head/tail sizes (zero: data goes straight to RAM)
	switch fno {
	case 0: // OPEN {hdr, flags, mode, name[0x400], slot}
		result = fileio_open(string(cstring(&buf[0x14])), w[3])
	case 1: // CLOSE {hdr, fd, slot}
		if f := fileio_file(w[3]); f != nil {
			f^ = {} // the host file stays open: see disc_open
		} else {result = -EBADF}
	case 2: // READ {hdr, fd, buffer, size, slot}
		f := fileio_file(w[3])
		if f == nil {result = -EBADF; break}
		n := i64(min(w[5], u32(max(f.size - f.pos, 0))))
		// Through a host buffer: on macOS, rollback keeps RAM write-protected
		// and a kernel write into it fails (rollback_darwin.odin).
		tmp := make([]u8, n, context.temp_allocator)
		got := disc_file_read(f.file, f.pos, tmp)
		copy(mem.ram_slice(w[4], u32(got)), tmp[:got])
		f.pos += i64(got)
		result = i32(got)
	case 3: // WRITE {hdr, fd, buffer, size, unaligned size, data...}: read-only disc
		result = -EBADF
	case 4: // SEEK {hdr, fd, offset, whence, slot}
		f := fileio_file(w[3])
		if f == nil {result = -EBADF; break}
		base := [3]i64{0, f.pos, f.size}
		if w[5] > 2 {result = -22; break}
		f.pos = clamp(base[w[5]] + i64(i32(w[4])), 0, f.size)
		result = i32(f.pos)
	case:
		return false
	}
	if cpu.debug == 2 {fmt.eprintfln("fileio: fno %d fd %d -> %d", fno, i32(w[3]), result)}
	if fileio.reply_buf != 0 {
		r := ([^]u32)(raw_data(mem.ram_slice(fileio.reply_buf, 0x20)))
		r[0], r[1], r[2], r[3] = w[0], fno, w[1], w[2]
		r[4] = u32(result)
		r[5], r[6], r[7] = extra[0], extra[1], extra[2]
	}
	sif_reply(FILEIO_REPLY, 0, {})
	w[0] = 1 // accepted; zero makes the EE library return EAGAIN
	return true
}

@(private)
fileio_file :: proc(fd: u32) -> ^Iop_File {
	if int(fd) >= len(fileio.files) || fileio.files[fd].f == nil {return nil}
	return &fileio.files[fd]
}

// Disc files stay open for the life of the process, one handle per path: a
// snapshot may hold a handle the game closed after it was taken.
@(private)
disc_files: map[string]^os.File

@(private)
disc_open :: proc(path: string) -> (f: ^os.File, err: os.Error) {
	context.allocator = core.host_allocator
	if cached, ok := disc_files[path]; ok {return cached, nil}
	f = os.open(path) or_return
	disc_files[strings.clone(path)] = f
	return f, nil
}

@(private)
fileio_open :: proc(name: string, flags: u32) -> i32 {
	file, path, ok := disc_find(name)
	if !ok || flags & 3 != 1 { // O_RDONLY is 1 in the IOP's ioman
		fmt.eprintfln("fileio: open \"%s\" flags %x failed", name, flags)
		return -ENOENT
	}
	if cpu.debug >= 1 {fmt.eprintfln("fileio: open \"%s\" -> %s lba %d (%d bytes)", name, path, file.lba, file.size)}
	for &e, i in fileio.files {
		if e.f == nil {
			e = {file, 0}
			return i32(i)
		}
	}
	append(&fileio.files, Iop_File{file, 0})
	return i32(len(fileio.files) - 1)
}

// A file of the disc: the host file holding it, its first LBA on the disc
// image (0 under disc_dir) and its size.
@(private)
Disc_File :: struct {
	f:    ^os.File,
	lba:  u32,
	size: i64,
}

// The disc image disc_image_open opened (host state, like disc_files), and
// its files found by the names the game passed: a game may open a file
// every frame, and a lookup reads each directory on the way.
@(private)
image: disc.Disc
@(private)
image_found: map[string]disc.Entry

// Read the disc's files and sectors from a disc image (a .iso, or a .cue
// or .bin of 2048-byte data) in place of disc_dir. False, with the reason
// printed, when it holds no ISO9660 volume. An image open before is closed.
disc_image_open :: proc(path: string) -> bool {
	disc_image_close()
	d := disc.open(path, core.host_allocator) or_return
	if d.volume == 0 {
		fmt.eprintln("disc: no ISO9660 volume on", path)
		disc.close(&d)
		return false
	}
	image = d
	return true
}

// Close the disc image disc_image_open opened; files are read from disc_dir
// again.
disc_image_close :: proc() {
	context.allocator = core.host_allocator
	for name in image_found {
		delete(name)
	}
	delete(image_found)
	image_found = nil
	disc.close(&image)
}

// Find a disc file by its IOP name (`cdrom0:\DIR\FILE.EXT;1`); path is its
// host path under disc_dir, "" on the image.
@(private)
disc_find :: proc(name: string) -> (file: Disc_File, path: string, ok: bool) {
	if image.volume == 0 {
		path = host_path(name) or_return
		if os.is_dir(path) {return {}, "", false}
		f, err := disc_open(path)
		if err != nil {return {}, "", false}
		size, _ := os.file_size(f)
		return {f, 0, size}, path, true
	}
	context.allocator = core.host_allocator
	e, cached := image_found[name]
	if !cached {
		e = disc.find(&image, name) or_return
		image_found[strings.clone(name)] = e
	}
	t := disc.track_of(&image, e.lba)
	if e.dir || t == nil {return {}, "", false}
	return {t.file, e.lba, i64(e.size)}, "", true
}

// Read len(buf) bytes from byte pos of a disc file; the count read.
@(private)
disc_file_read :: proc(file: Disc_File, pos: i64, buf: []u8) -> int {
	if image.volume != 0 {
		return disc.read_at(&image, file.lba, pos, buf)
	}
	n, _ := os.read_at(file.f, buf, pos)
	return max(n, 0)
}

// The bytes of a file of the disc, by its IOP or ISO9660 name: how a port
// loads its executable (disc_boot) from the disc.
disc_file :: proc(name: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	file, _ := disc_find(name) or_return
	data = make([]u8, file.size, allocator)
	if disc_file_read(file, 0, data) != len(data) {
		delete(data, allocator)
		return nil, false
	}
	return data, true
}

// The PS2 executable the disc image's SYSTEM.CNF names (BOOT2), as a disc
// path for disc_file. False with no image open or no BOOT2 line.
disc_boot :: proc(allocator := context.allocator) -> (string, bool) {
	if image.volume == 0 {return "", false}
	cnf, ok := disc.system_cnf(&image, context.temp_allocator)
	if !ok || !cnf.ps2 {return "", false}
	return strings.clone(cnf.boot, allocator), true
}

// Map an IOP device path ("cdrom0:\DIR\FILE.EXT;1") to a file under
// disc_dir, matching each component case-insensitively as ISO9660 does.
@(private)
host_path :: proc(name: string) -> (string, bool) {
	rest := name
	if i := strings.index_byte(rest, ':'); i >= 0 {rest = rest[i + 1:]}
	if i := strings.index_byte(rest, ';'); i >= 0 {rest = rest[:i]}
	rest, _ = strings.replace_all(rest, "\\", "/", context.temp_allocator)
	dir := disc_dir
	for part in strings.split_iterator(&rest, "/") {
		if part == "" || part == "." {continue}
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return "", false}
		found := false
		for e in entries {
			if strings.equal_fold(e.name, part) {
				dir = strings.clone(e.fullpath, context.temp_allocator)
				found = true
				break
			}
		}
		if !found {return "", false}
	}
	return dir, dir != disc_dir
}

// Replies are modelled on what Play!'s HLE modules return.

// Answers every call with zeros: "no device" or "nothing to do".
@(private)
zero_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if cpu.debug >= 1 {fmt.eprintfln("sif: stub rpc fno %d send %d", fno, send_size)}
	for &b in buf[:64] {b = 0}
	return true
}

// IOP heap (sceSifAllocIopHeap, sceSifFreeIopHeap): a bump allocator over
// IOP RAM no HLE module uses. Freeing the newest block returns it, which
// covers the alloc, copy, LoadModuleBuffer, free pattern of module loading;
// other frees are ignored.
IOP_HEAP_START :: 0x00040000
IOP_HEAP_END :: IOP_SERVERS

@(private = "file")
iop_heap_top: u32 = IOP_HEAP_START

@(private = "file")
iop_heap_last: u32 // start of the newest block, 0 once it is freed

@(private)
iop_heap_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 1: // alloc {size} -> address, 0 when full
		size := (w[0] + 0xff) &~ 0xff
		if iop_heap_top + size > IOP_HEAP_END {
			w[0] = 0
		} else {
			w[0] = iop_heap_top
			iop_heap_last = iop_heap_top
			iop_heap_top += size
		}
		if cpu.debug >= 1 {fmt.eprintfln("sif: iop heap alloc %x -> %x", size, w[0])}
	case 2: // free {address} -> 0
		if w[0] == iop_heap_last && iop_heap_last != 0 {
			iop_heap_top = iop_heap_last
			iop_heap_last = 0
		}
		w[0] = 0
	case:
		return false
	}
	return true
}

// cdvdfsv init: {result, cdvdfsv version, cdvdman version, 0xff}.
@(private)
cdvd_init_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	if fno != 0 {return false}
	w[0], w[1], w[2], w[3] = 1, 0, 0, 0xff
	return true
}

// cdvdfsv S-commands. Everything succeeds; the disc is a ready PS2 DVD.
@(private)
cdvd_scmd_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x01: // ReadClock {result, clock[8]}
		w[0], w[1], w[2] = 1, 0, 0
	case 0x03: w[0] = 0x14 // GetDiskType: PS2 DVD
	case 0x04: w[0] = 0 // GetError
	case 0x05: w[0], w[1] = 1, 0 // TrayReq {result, tray check}
	case 0x0c: w[0] = 0x0a // Status: paused
	case 0x16, 0x22: w[0] = 1 // Break, MMode
	case: return false
	}
	return true
}

// cdvdfsv DiskReady: 2 is ready.
@(private)
cdvd_ready_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if fno != 0 {return false}
	(^u32)(raw_data(buf))^ = 2
	return true
}

// Sector reads: from the disc image when one is open, else over disc_dir,
// which has files but no LSNs: SearchFile places each file it finds at the
// next free LSN, and a read maps back to its file. A sector no search
// placed (a volume descriptor, a hard-coded LSN) reads as zeros. Host state
// like disc_files: a path keeps its LSN across rollbacks.
@(private)
DISC_SECTOR :: 2048
@(private)
DISC_FIRST_LSN :: 0x400 // past the system area and volume descriptors

@(private)
Disc_Extent :: struct {
	lsn, sectors: u32,
	path:         string,
}

@(private)
disc_extents: [dynamic]Disc_Extent

@(private)
disc_place :: proc(path: string, size: i64) -> u32 {
	context.allocator = core.host_allocator
	next: u32 = DISC_FIRST_LSN
	for e in disc_extents {
		if e.path == path {return e.lsn}
		next = max(next, e.lsn + e.sectors)
	}
	sectors := u32(max((size + DISC_SECTOR - 1) / DISC_SECTOR, 1))
	append(&disc_extents, Disc_Extent{next, sectors, strings.clone(path)})
	return next
}

// Reads `sectors` sectors from `lsn` into EE RAM at `dest`, through a host
// buffer as fileio's READ does.
@(private)
disc_read :: proc(lsn, sectors, dest: u32) {
	tmp := make([]u8, sectors * DISC_SECTOR, context.temp_allocator)
	if image.volume != 0 {
		if disc.read_at(&image, lsn, 0, tmp) != len(tmp) { // the rest stays zero
			fmt.eprintfln("cdvd: read of lsn %x (%d sectors) past the image", lsn, sectors)
		}
		copy(mem.ram_slice(dest, u32(len(tmp))), tmp)
		return
	}
	found := false
	for e in disc_extents {
		if lsn < e.lsn || lsn >= e.lsn + e.sectors {continue}
		if f, err := disc_open(e.path); err == nil {
			_, _ = os.read_at(f, tmp, i64(lsn - e.lsn) * DISC_SECTOR) // past the end stays zero
		}
		found = true
		break
	}
	if !found {fmt.eprintfln("cdvd: read of unplaced lsn %x (%d sectors)", lsn, sectors)}
	copy(mem.ram_slice(dest, u32(len(tmp))), tmp)
}

// cdvdfsv N-commands. The EE library sends them without waiting and learns
// of completion from the RPC end callback, so a read finishes at once.
@(private)
cdvd_ncmd_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 0x01: // Read {lsn, sectors, buffer, mode[4], align buffer, status}
		if buf[0xe] != 0 { // data pattern: 0x918- and 0x924-byte sectors
			fmt.eprintfln("cdvd: read with data pattern %d", buf[0xe])
			return false
		}
		if cpu.debug >= 1 {fmt.eprintfln("cdvd: read lsn %x sectors %d -> %08x", w[0], w[1], w[2])}
		disc_read(w[0], w[1], w[2])
		// The data went straight to the buffer: no unaligned head or tail
		// for the end callback to copy out of {size1, size2, dest1, dest2}.
		if w[4] != 0 {
			a := ([^]u32)(raw_data(mem.ram_slice(w[4], 8)))
			a[0], a[1] = 0, 0
		}
		w[0] = 1
	case 0x05: w[0] = 1 // Seek {lsn}
	case 0x0e: w[0] = 2 // DiskReady (non-blocking): 2 is ready, 6 not ready
	case: return false
	}
	return true
}

// cdvdfsv SearchFile {file[0x24], path[256], EE address of the request,
// layer}: the IOP writes the sceCdlFILE {lsn, size, name[16], date[8], flag}
// back over the start of the EE's request and returns 1 found, 0 not.
@(private)
cdvd_search_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	if fno != 0 || len(buf) < 0x12c {return false}
	name := strings.truncate_to_byte(string(buf[0x24:0x124]), 0)
	w[0] = 0
	found, path, ok := disc_find(name)
	if !ok {
		fmt.eprintfln("cdvd: search \"%s\" not found", name)
		return true
	}
	size := found.size
	file: [0x24]u8
	fw := ([^]u32)(&file)
	fw[0], fw[1] = image.volume != 0 ? found.lba : disc_place(path, size), u32(size)
	// The ISO9660 name of the last component, version included.
	base := name[strings.last_index_any(name, "\\/") + 1:]
	copy(file[8:0x17], base)
	copy(mem.ram_slice(w[0x124 / 4], len(file)), file[:])
	if cpu.debug >= 1 {fmt.eprintfln("cdvd: search \"%s\" -> lsn %x size %d", name, fw[0], size)}
	w[0] = 1
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin).
sif_snap :: proc() {
	core.snap_add(&sif)
	core.snap_add(&fileio)
	core.snap_add(&iop_heap_top)
	core.snap_add(&iop_heap_last)
	adx_snap()
}
