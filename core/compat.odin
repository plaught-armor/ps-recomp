// Compatibility counters and the compat line. The runtimes count, on their
// slow paths only (interpreter entry and instructions, the unknown-call
// paths of the HLE BIOS, kernel and SIF), never in recompiled code:
// - interpreter instructions, and interpreter entries by pc (the hottest
//   COMPAT_TOP reported);
// - calls the HLE does not implement, by name, with where the first was
//   made;
// - once a vblank, whether the display was on and, under COMPAT, a hash of
//   main RAM halfway to FRAMES, so the line can say a run made no progress;
// - under COMPAT, from the host, how much of the last frame of a run to
//   FRAMES was drawn;
// - and under COMPAT, every COMPAT_SAMPLE vblanks, the picture the host
//   hands over and main RAM, so the line can list the stretches of at least
//   COMPAT_STRETCH vblanks the picture was black, the picture did not
//   change, the picture barely changed (with or without scripted presses
//   meanwhile), or RAM did not change.
// Built with -define:COMPAT_COUNT=false the counters compile away.
//
// COMPAT=1 makes a run a compatibility run: a call the HLE does not
// implement returns 0 and the game goes on, where it would stop the game,
// and one JSON line tagged `compat:` goes to stderr when the run ends at
// FRAMES, on an exit and on a fatal error. A run that ends with no line
// crashed. With COMPAT_PROGRESS=<path> as well (play --compat sets it), the
// vblank count goes to that file, an 8-byte little-endian u64 at offset 0,
// at vblank 1 and every COMPAT_PROGRESS_EVERY vblanks after, so the parent
// can tell a slow run from a hung one.
package core

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"

COMPAT_COUNT :: #config(COMPAT_COUNT, true)

// The vblanks between writes of the count to COMPAT_PROGRESS.
COMPAT_PROGRESS_EVERY :: 60

// How many interpreter entries the line lists, hottest first.
COMPAT_TOP :: 10

// Under COMPAT, the vblanks between samples of the picture and main RAM
// (5 s at 60 Hz).
COMPAT_SAMPLE :: 300

// The shortest stretch the line lists, in vblanks (30 s at 60 Hz): the
// first sample of it to the last.
COMPAT_STRETCH :: 1800

// The most stretches the line lists; later ones count in stretches_other.
COMPAT_STRETCHES :: 32

// A still stretch's thumbnail: the mean of each COMPAT_BLOCK x COMPAT_BLOCK
// block of the picture (whole blocks only), at most COMPAT_THUMB of them.
COMPAT_BLOCK :: 16
COMPAT_THUMB :: 4096

// The most a picture's thumbnail may differ from its still stretch's first
// one and the stretch go on: the mean, over the blocks, of the change in
// block brightness (0..255). A blinking cursor or a pulsing highlight stays
// under it; a camera move or a walking character goes far past it.
COMPAT_STILL_DIFF :: 2.0

// What a stretch is: the display off or every pixel black (Black), the
// same picture as the sample before, not black (Frozen), main RAM the same
// as at the sample before (Ram_Still), or a lit picture that changed but
// stayed within COMPAT_STILL_DIFF of the stretch's first one (Still when
// no press of the loaded PRESS script started in it, so the game may wait
// for input on purpose; Deaf when one did, so the presses changed nothing
// to see: a soft lock, or a script pressing the wrong thing). A stretch
// that is frozen throughout is listed as frozen only.
Compat_Stretch_Kind :: enum u8 {
	Black,
	Frozen,
	Ram_Still,
	Still, // followed for Deaf too; which it is is decided when listed
	Deaf,
}

COMPAT_STRETCH_NAMES :: [Compat_Stretch_Kind]string {
	.Black     = "black",
	.Frozen    = "frozen",
	.Ram_Still = "ram_still",
	.Still     = "still",
	.Deaf      = "deaf",
}

// A stretch in the line: from its first sample's vblank to its last's.
Compat_Stretch :: struct {
	kind: string,
	from: u64,
	to:   u64,
}

// A stretch being followed: on while each sample since `from` showed it.
@(private = "file")
Stretch_Run :: struct {
	on:         bool,
	from, last: u64,
}

// The kinds of call the HLE may not implement. Id and sub per kind:
// Bios_A/B/C the function number; Syscall the syscall number (as an i32);
// Sif_Bind the server id; Sif_Rpc the server id and function number (of
// padman, its command word), or of a call to no descriptor a bind handed out, its server word and function
// number;
// Sif_Cmd the command id; Iop_Call an IOP library's name (compat_name) and
// function number; Iop_Import a library's name no module registered, or
// with sub the version of a Sony library's import the HLE does not serve;
// Iop_Start a module's name, whose start ran out of its budget;
// Iop_Blocked a module's name, whose start waited with no thread ready;
// Iop_Threads a module's name, whose threads ran out of the load's budget
// after its start returned; Iop_Fallback a module's name, whose load failed
// or was refused as one that failed, answered as a module not run; Iop_Intr
// the command id whose IOP handler waited or ran out of its budget; Iop_Sd the id an IOP libsd call did not
// decode and its function number; Iop_Sd_Intr the address of a libsd
// interrupt handler that waited or ran out of its budget; Iop_Cd the data
// pattern of an IOP sceCdRead, which reads only 2048-byte sectors; Iop_Io
// the first 4 bytes of a path an IOP ioman open names on a device other than
// the disc; Iop_Rpc the server id and function number of an RPC to an IOP
// module's server that got no RPC_END, or whose request or reply did not
// fit (function number all ones: a server, or by its descriptor a queue,
// with no room); or, of an IOP module's RPC client (sifclient.odin), the
// server id of a bind no EE server answered (function number 0xfffffffe), the
// client and function number of a call refused, or the client and command of
// an RPC_END with no packet out; Iop_Rpc_Busy the server id and function
// number of an RPC to an IOP module's server that arrived while the server
// held an earlier request, its buffer possibly overwritten; Iop_Sdr an EE
// sdrdrv RPC whose IOP user command handler is set and was not run, the EE
// answered 0; Iop_Timer the source and mode of an IOP hardware timer set
// up to count what is not timed here; Iop_Timer_Intr the address of a timer
// compare handler that waited or ran out of its budget; Iop_Cd_Intr the
// address of a cdvdman callback that did, or by its function code a run
// of it dropped with CD_PENDING owed; Iop_Vblank_Intr the address of a
// vblank handler that waited or ran out of its budget, or, marked 1, one
// AddVblankHandler had no room for; Iop_Sif_Intr the address of a sifman
// DMA completion callback that waited or ran out of its budget;
// Iop_Other_Data the EE
// address and size of an IOP sceSifGetOtherData whose source or destination
// runs past RAM, nothing copied; Iop_Adx a PS2RNA command CRI ADX's HLE
// driver does not serve (adx.odin); Irx_Reloc the relocation type;
// Vu1_Status the reader (the runtime's vu.Vu_Status_Reader: 0 a VU0 window
// load, 1 an EE macro one, 2 FSEQ, FSAND or FSOR) and micro pc of a read of
// VU1 status that compiled VU1 code had left stale; Gif_Stat_Busy the
// return address of a GIF_STAT read that showed a path or a queue busy,
// read again with nothing moved since: a wait the synchronous GIF never
// ends, as hardware would by streaming the rest of a transfer.
Compat_Call :: enum u8 {
	Bios_A,
	Bios_B,
	Bios_C,
	Syscall,
	Sif_Bind,
	Sif_Rpc,
	Sif_Cmd,
	Iop_Call,
	Iop_Import,
	Iop_Start,
	Iop_Blocked,
	Iop_Threads,
	Iop_Fallback,
	Iop_Intr,
	Iop_Sd,
	Iop_Sd_Intr,
	Iop_Cd,
	Iop_Io,
	Iop_Rpc,
	Iop_Rpc_Busy,
	Iop_Sdr,
	Iop_Timer,
	Iop_Timer_Intr,
	Iop_Cd_Intr,
	Iop_Vblank_Intr,
	Iop_Sif_Intr,
	Iop_Other_Data,
	Iop_Adx,
	Irx_Reloc,
	Vu1_Status,
	Gif_Stat_Busy,
}

// The names the IOP's rows carry, by the id compat_name gives them, so a key
// stays three words. Host data, never freed: a name is the same whatever
// state a snapshot restores.
@(private = "file")
compat_names: [dynamic]string

// The id of name s, interned on first use.
compat_name :: proc(s: string) -> u32 {
	for n, i in compat_names {
		if n == s {
			return u32(i)
		}
	}
	if compat_names.allocator.procedure == nil {
		compat_names.allocator = runtime.heap_allocator()
	}
	append(&compat_names, strings.clone(s, runtime.heap_allocator()))
	return u32(len(compat_names) - 1)
}

Compat_Key :: struct {
	kind:    Compat_Call,
	id, sub: u32,
}

// A call's count, and where the first was made (0: not known): the guest's
// pc and ra, and for a SIF bind or RPC the client data it was made with.
Compat_Hit :: struct {
	n:              u64,
	pc, ra, client: u32,
}

// Entry pcs in a table of fixed size, so counting never allocates: each pc
// probes a few slots from its hash, and one that finds none free counts in
// entries_other.
@(private = "file")
ENTRY_SLOTS :: 1024
@(private = "file")
ENTRY_PROBES :: 8

@(private = "file")
Entry_Slot :: struct {
	pc1: u32, // pc + 1; 0 is a free slot
	n:   u64,
}

compat: struct {
	on:            bool,
	// The console ("ps1", "ps2"), its cycle counter, the cycles of it its
	// kernel skipped with every thread waiting (nil: none skipped) and the
	// cycles its interpreter charges an instruction, from the host.
	system:        string,
	cycles:        ^u64,
	idle:          ^u64,
	cpi:           u64,
	interp_insns:  u64,
	entries:       [ENTRY_SLOTS]Entry_Slot,
	entries_other: u64,
	calls:         map[Compat_Key]Compat_Hit,
	// Vblanks with the display on; main RAM as of the last vblank, and its
	// hash at vblank ram_at (FRAMES/2; 0 before it).
	shown:         u64,
	ram:           []u8,
	ram_at:        u64,
	ram_hash:      u64,
	// The non-black pixels of the picture at vblank FRAMES, which the host
	// sets; -1 until it does.
	lit:           i64,
	// The samples (compat_sample): the last one's vblank (0: none yet), the
	// hashes it took (pic_ok: its picture was not black), the stretches
	// being followed, and those ended long enough to list.
	sample_at:      u64,
	sample_pic:     u64,
	sample_pic_ok:  bool,
	sample_ram:     u64,
	runs:           [Compat_Stretch_Kind]Stretch_Run,
	// The still stretch: its first picture's thumbnail (thumb_n blocks, of
	// a w x h picture; 0 blocks: none), the scripted presses started as of
	// its first sample and its last, and whether the picture changed at
	// any sample of it.
	thumb:          [COMPAT_THUMB]f32,
	thumb_n:        int,
	thumb_w:        int,
	thumb_h:        int,
	still_presses:  [2]u64,
	still_moved:    bool,
	stretches:      [COMPAT_STRETCHES]struct {kind: Compat_Stretch_Kind, from, to: u64},
	stretches_n:    int,
	stretches_other: u64,
	reported:      bool,
	// COMPAT_PROGRESS, open under COMPAT; nil without it.
	progress:      ^os.File,
}

// Read COMPAT, for the host's console, its cycle counter, the cycles its
// interpreter charges an instruction and the idle cycles its kernel skips
// (nil for none). Call from the host's init.
compat_init :: proc(system: string, cycles: ^u64, cycles_per_insn: u64, idle: ^u64 = nil) {
	compat.on = env("COMPAT") == "1"
	compat.system = system
	compat.cycles = cycles
	compat.idle = idle
	compat.lit = -1
	compat.cpi = cycles_per_insn
	if path := env("COMPAT_PROGRESS"); compat.on && path != "" && compat.progress == nil {
		f, err := os.open(path, {.Write, .Create}, os.Permissions_Default_File)
		if err != nil {
			fmt.eprintln("compat: cannot open", env_name("COMPAT_PROGRESS"), path, err)
		}
		compat.progress = f
	}
}

// Count an interpreter entry at pc.
compat_entry :: proc(pc: u32) {
	when COMPAT_COUNT {
		h := (pc >> 2) * 0x9e3779b1 >> 22
		for i in u32(0) ..< ENTRY_PROBES {
			s := &compat.entries[(h + i) % ENTRY_SLOTS]
			if s.pc1 == pc + 1 || s.pc1 == 0 {
				s.pc1 = pc + 1
				s.n += 1
				return
			}
		}
		compat.entries_other += 1
	}
}

// Count a call the HLE does not implement, made at pc with ra (and, for a
// SIF bind or RPC, client), which the first of each keeps. True under
// COMPAT: the caller returns 0 to the game and goes on. The first of each
// says so on stderr.
compat_unknown :: proc(kind: Compat_Call, id: u32, sub: u32 = 0, pc: u32 = 0, ra: u32 = 0, client: u32 = 0) -> (stub: bool) {
	when COMPAT_COUNT {
		key := Compat_Key{kind, id, sub}
		h := compat.calls[key]
		if h.n == 0 {
			h.pc, h.ra, h.client = pc, ra, client
		}
		h.n += 1
		compat.calls[key] = h
		if compat.on && h.n == 1 {
			c := client != 0 ? fmt.tprintf(" client %08x", client) : ""
			fmt.eprintfln("compat stub: %s (pc %08x ra %08x%s)", compat_call_name(key), pc, ra, c)
		}
	}
	return compat.on
}

// Count vblank n, with the display on or not, with main RAM as it
// stands. Under COMPAT, vblank FRAMES/2 hashes RAM, and vblank 1 and every
// COMPAT_PROGRESS_EVERY go to COMPAT_PROGRESS. Call once a vblank.
compat_vblank :: proc(n: u64, shown: bool, ram: []u8) {
	// Outside COMPAT_COUNT: the parent's hang check needs it either way.
	if compat.progress != nil && (n == 1 || n % COMPAT_PROGRESS_EVERY == 0) {
		b: [8]u8
		endian.unchecked_put_u64le(b[:], n)
		_, _ = os.write_at(compat.progress, b[:], 0)
	}
	when COMPAT_COUNT {
		if shown {
			compat.shown += 1
		}
		compat.ram = ram
		if compat.on && frames >= 2 && n == frames / 2 {
			compat.ram_at, compat.ram_hash = n, xxhash.XXH3_64_default(ram)
		}
	}
}

// Whether vblank n is a sample (compat_sample): under COMPAT, every
// COMPAT_SAMPLE vblanks from COMPAT_SAMPLE. Outside COMPAT never, so a
// host draws and reads what it did without it.
compat_sample_due :: proc(n: u64) -> bool {
	when COMPAT_COUNT {
		return compat.on && n > 0 && n % COMPAT_SAMPLE == 0
	} else {
		return false
	}
}

// Whether a sample is due within `within` vblanks after n, or at n: a host
// that draws only the pictures it reads draws from then.
compat_sample_near :: proc(n, within: u64) -> bool {
	d := (COMPAT_SAMPLE - n % COMPAT_SAMPLE) % COMPAT_SAMPLE
	return d <= within && compat_sample_due(n + d)
}

// At a sample vblank n, after compat_vblank, take the picture on screen
// (w x h pixels, rows stride apart, 0xffffff the color bits; w or h 0 with
// the display off) and main RAM, and follow the stretches. Any other
// vblank, or a vblank not after the last sample, does nothing.
compat_sample :: proc(n: u64, px: []u32, stride, w, h: int) {
	when COMPAT_COUNT {
		if !compat_sample_due(n) || n <= compat.sample_at {
			return
		}
		lit := false
		pic: u64
		if w > 0 && h > 0 {
			for y in 0 ..< h {
				row := px[y * stride:][:w]
				if !lit {
					for c in row {
						if c & 0xffffff != 0 {
							lit = true
							break
						}
					}
				}
				pic = xxhash.XXH3_64_with_seed(slice.to_bytes(row), pic)
			}
		}
		ram := xxhash.XXH3_64_default(compat.ram)
		prev := compat.sample_at
		frozen := lit && compat.sample_pic_ok && pic == compat.sample_pic
		stretch_step(.Black, !lit, n, n)
		stretch_step(.Frozen, frozen, prev, n)
		stretch_step(.Ram_Still, prev != 0 && ram == compat.sample_ram, prev, n)
		still_step(n, px, stride, w, h, lit, frozen)
		compat.sample_at, compat.sample_pic, compat.sample_pic_ok, compat.sample_ram = n, pic, lit, ram
	}
}

// One sample of stretch k at vblank n: it holds (since `from` when it
// starts) or not, which ends it.
@(private = "file")
stretch_step :: proc(k: Compat_Stretch_Kind, holds: bool, from, n: u64) {
	r := &compat.runs[k]
	switch {
	case holds && !r.on: r^ = {true, from, n}
	case holds: r.last = n
	case r.on:
		stretch_keep(k, r^)
		r.on = false
	}
}

// One sample of the still stretch at vblank n: on while the picture's
// thumbnail stays within COMPAT_STILL_DIFF of the stretch's first, which a
// sample that holds it not starts again from. A picture of another size,
// or a dark one, ends it with no first picture to compare with.
@(private = "file")
still_step :: proc(n: u64, px: []u32, stride, w, h: int, lit, frozen: bool) {
	bw, bh := w / COMPAT_BLOCK, h / COMPAT_BLOCK
	thumb: [COMPAT_THUMB]f32
	ok := lit && bw > 0 && bh > 0 && bw * bh <= COMPAT_THUMB
	if ok {
		for y in 0 ..< bh * COMPAT_BLOCK {
			row := px[y * stride:][:bw * COMPAT_BLOCK]
			t := thumb[y / COMPAT_BLOCK * bw:][:bw]
			for c, x in row {
				t[x / COMPAT_BLOCK] += f32(c & 0xff + c >> 8 & 0xff + c >> 16 & 0xff)
			}
		}
		for &v in thumb[:bw * bh] {
			v /= 3 * COMPAT_BLOCK * COMPAT_BLOCK
		}
	}
	same_size := compat.thumb_n > 0 && w == compat.thumb_w && h == compat.thumb_h
	near := false
	if ok && same_size {
		diff: f32
		for v, i in thumb[:bw * bh] {
			diff += abs(v - compat.thumb[i])
		}
		near = diff / f32(bw * bh) < COMPAT_STILL_DIFF
	}
	r := &compat.runs[.Still]
	if near {
		if !r.on {
			r^ = {true, compat.sample_at, n}
		}
		r.last = n
		compat.still_presses[1] = input.script_started
		compat.still_moved ||= !frozen
		return
	}
	if r.on {
		if k := still_kind(); k != .Frozen {
			stretch_keep(k, r^)
		}
		r.on = false
	}
	compat.thumb_n = 0
	if ok {
		copy(compat.thumb[:], thumb[:bw * bh])
		compat.thumb_n, compat.thumb_w, compat.thumb_h = bw * bh, w, h
		compat.still_presses = {input.script_started, input.script_started}
		compat.still_moved = false
	}
}

// What the still stretch is listed as: Still or Deaf, or Frozen, which the
// frozen stretch over the same samples lists already, when its picture
// never changed.
@(private = "file")
still_kind :: proc() -> Compat_Stretch_Kind {
	switch {
	case !compat.still_moved: return .Frozen
	case compat.still_presses[1] > compat.still_presses[0]: return .Deaf
	}
	return .Still
}

// Keep run r of kind k for the line when it lasted COMPAT_STRETCH vblanks.
@(private = "file")
stretch_keep :: proc(k: Compat_Stretch_Kind, r: Stretch_Run) {
	if r.last - r.from < COMPAT_STRETCH {
		return
	}
	if compat.stretches_n == COMPAT_STRETCHES {
		compat.stretches_other += 1
		return
	}
	compat.stretches[compat.stretches_n] = {k, r.from, r.last}
	compat.stretches_n += 1
}

// The name a call has in the line, temp allocated.
compat_call_name :: proc(k: Compat_Key) -> string {
	switch k.kind {
	case .Bios_A: return fmt.tprintf("BIOS A(%02xh)", k.id)
	case .Bios_B: return fmt.tprintf("BIOS B(%02xh)", k.id)
	case .Bios_C: return fmt.tprintf("BIOS C(%02xh)", k.id)
	case .Syscall: return fmt.tprintf("syscall %d", i32(k.id))
	case .Sif_Bind: return fmt.tprintf("SIF server %08x", k.id)
	case .Sif_Rpc: return fmt.tprintf("SIF server %08x fno %d", k.id, k.sub)
	case .Sif_Cmd: return fmt.tprintf("SIF command %08x", k.id)
	case .Iop_Call: return fmt.tprintf("IOP %s fno %d", compat_names[k.id], k.sub)
	case .Iop_Import:
		if k.sub != 0 {return fmt.tprintf("IOP import %s version %x", compat_names[k.id], k.sub)}
		return fmt.tprintf("IOP import %s", compat_names[k.id])
	case .Iop_Start: return fmt.tprintf("IOP start %s budget", compat_names[k.id])
	case .Iop_Blocked: return fmt.tprintf("IOP start %s blocked", compat_names[k.id])
	case .Iop_Threads: return fmt.tprintf("IOP threads budget %s", compat_names[k.id])
	case .Iop_Fallback: return fmt.tprintf("IOP fallback %s", compat_names[k.id])
	case .Iop_Intr: return fmt.tprintf("IOP command handler %08x blocked", k.id)
	case .Iop_Sd: return fmt.tprintf("IOP libsd fno %d id %04x", k.sub, k.id)
	case .Iop_Sd_Intr: return fmt.tprintf("IOP libsd handler %08x blocked", k.id)
	case .Iop_Cd: return fmt.tprintf("IOP cdvdman read pattern %d", k.id)
	case .Iop_Io:
		dev := transmute([4]u8)k.id
		return fmt.tprintf("IOP ioman device %q", strings.truncate_to_byte(string(dev[:]), 0))
	case .Iop_Rpc: return fmt.tprintf("IOP server %08x fno %d", k.id, i32(k.sub))
	case .Iop_Rpc_Busy: return fmt.tprintf("IOP server %08x fno %d called while busy (possible overwrite)", k.id, i32(k.sub))
	case .Iop_Sdr: return fmt.tprintf("IOP sdrdrv command %04x handler not run", k.id)
	case .Iop_Timer: return fmt.tprintf("IOP timer source %d mode %d not timed", k.id, k.sub)
	case .Iop_Timer_Intr: return fmt.tprintf("IOP timer handler %08x blocked", k.id)
	case .Iop_Cd_Intr:
		if k.sub != 0 {return fmt.tprintf("IOP cdvdman callback %08x code %d dropped", k.id, k.sub)}
		return fmt.tprintf("IOP cdvdman callback %08x blocked", k.id)
	case .Iop_Vblank_Intr:
		if k.sub != 0 {return fmt.tprintf("IOP vblank handler %08x no room", k.id)}
		return fmt.tprintf("IOP vblank handler %08x blocked", k.id)
	case .Iop_Sif_Intr: return fmt.tprintf("IOP sifman DMA callback %08x blocked", k.id)
	case .Iop_Other_Data: return fmt.tprintf("IOP GetOtherData from %08x size %x out of range", k.id, k.sub)
	case .Iop_Adx: return fmt.tprintf("IOP ADX RNA command %d", k.id)
	case .Irx_Reloc: return fmt.tprintf("IRX relocation %d", k.id)
	case .Vu1_Status:
		READER := [3]string{"VU0 window", "EE macro", "FS"}
		return fmt.tprintf("VU1 status stale, read by %s at %04x", READER[min(k.id, 2)], k.sub)
	case .Gif_Stat_Busy: return fmt.tprintf("GIF_STAT busy with no progress, read from %08x", k.id)
	}
	return ""
}

Compat_Pc :: struct {
	pc: string, // 8 hex digits
	n:  u64,
}

// A call and its count, with where the first was made: 8 hex digits, ""
// when not known (client only for a SIF bind or RPC).
Compat_Name :: struct {
	name:   string,
	n:      u64,
	pc:     string,
	ra:     string,
	client: string `json:"client,omitempty"`,
}

// The compat line's fields. result: "frames" (FRAMES reached), "fatal" or
// "exit" (any other exit); frames: the last vblank the host counted;
// idle_cycles: the cycles skipped with every guest thread waiting (0 where
// the kernel skips none), so idle_cycles / cycles is the share of the run the
// game sat idle; cycles_per_insn: what the interpreter charges an
// instruction, so interp_insns * cycles_per_insn / cycles is about the share
// of the run interpreted (the cycles also hold stalls and skipped idle loops,
// so it errs low); shown: the vblanks with the display on, whether anything
// was drawn or not; lit: the non-black pixels of the picture at vblank
// FRAMES, -1 when not counted (a run that ended before it, a host that does
// not count); ram_still_since: the vblank from which main RAM was the same at
// the end, else 0 (also when not checked: no FRAMES, or the run ended before
// FRAMES/2); fallback: an IOP module's load failed and the HLE stood in for
// it (an Iop_Fallback row); build: the ps-recomp commit (COMMIT);
// stretches: the sampled stretches of at least COMPAT_STRETCH vblanks
// (compat_sample), by first vblank, those still on at the end included,
// and stretches_other the ones past COMPAT_STRETCHES.
Compat_Line :: struct {
	system:               string,
	result:               string,
	frames:               u64,
	cycles:               u64,
	idle_cycles:          u64,
	cycles_per_insn:      u64,
	interp_insns:         u64,
	interp_entries:       []Compat_Pc,
	interp_entries_other: u64,
	unimplemented:        []Compat_Name,
	fatal:                string,
	shown:                u64,
	lit:                  i64,
	ram_still_since:      u64,
	fallback:             bool,
	build:                string,
	stretches:            []Compat_Stretch,
	stretches_other:      u64,
}

// The line as it stands, temp allocated.
compat_line :: proc(fatal := "") -> Compat_Line {
	l := Compat_Line {
		system               = compat.system,
		frames               = vblank,
		cycles_per_insn      = compat.cpi,
		interp_insns         = compat.interp_insns,
		interp_entries_other = compat.entries_other,
		fatal                = fatal,
		shown                = compat.shown,
		lit                  = compat.lit,
		build                = COMMIT,
	}
	if compat.ram_at != 0 && xxhash.XXH3_64_default(compat.ram) == compat.ram_hash {
		l.ram_still_since = compat.ram_at
	}
	switch {
	case fatal != "": l.result = "fatal"
	case frames != 0 && vblank >= frames: l.result = "frames"
	case: l.result = "exit"
	}
	if compat.cycles != nil {
		l.cycles = compat.cycles^
	}
	if compat.idle != nil {
		l.idle_cycles = compat.idle^
	}
	slots := make([dynamic]Entry_Slot, 0, 64, context.temp_allocator)
	for s in compat.entries {
		if s.pc1 != 0 {
			append(&slots, s)
		}
	}
	slice.sort_by(slots[:], proc(a, b: Entry_Slot) -> bool {
		return a.n > b.n || a.n == b.n && a.pc1 < b.pc1
	})
	top := make([]Compat_Pc, min(len(slots), COMPAT_TOP), context.temp_allocator)
	for &t, i in top {
		t = {fmt.tprintf("%08x", slots[i].pc1 - 1), slots[i].n}
	}
	l.interp_entries = top
	calls := make([]Compat_Name, len(compat.calls), context.temp_allocator)
	i := 0
	hex :: proc(v: u32) -> string {return v != 0 ? fmt.tprintf("%08x", v) : ""}
	for k, h in compat.calls {
		calls[i] = {compat_call_name(k), h.n, hex(h.pc), hex(h.ra), hex(h.client)}
		l.fallback ||= k.kind == .Iop_Fallback
		i += 1
	}
	slice.sort_by(calls, proc(a, b: Compat_Name) -> bool {
		return a.n > b.n || a.n == b.n && a.name < b.name
	})
	l.unimplemented = calls
	l.stretches, l.stretches_other = compat_stretches()
	return l
}

// The line's stretches: those ended, then those still on that are long
// enough, within COMPAT_STRETCHES, by first vblank; and how many did not
// fit. Temp allocated; the runs go on.
@(private = "file")
compat_stretches :: proc() -> (list: []Compat_Stretch, other: u64) {
	names := COMPAT_STRETCH_NAMES
	out := make([dynamic]Compat_Stretch, 0, COMPAT_STRETCHES, context.temp_allocator)
	for s in compat.stretches[:compat.stretches_n] {
		append(&out, Compat_Stretch{names[s.kind], s.from, s.to})
	}
	other = compat.stretches_other
	for r, k in compat.runs {
		if !r.on || r.last - r.from < COMPAT_STRETCH {
			continue
		}
		k := k
		if k == .Still {
			// Frozen throughout: the frozen run lists it.
			if k = still_kind(); k == .Frozen {
				continue
			}
		}
		if len(out) == COMPAT_STRETCHES {
			other += 1
			continue
		}
		append(&out, Compat_Stretch{names[k], r.from, r.last})
	}
	slice.sort_by(out[:], proc(a, b: Compat_Stretch) -> bool {
		return a.from < b.from || a.from == b.from && a.kind < b.kind
	})
	return out[:], other
}

// Under COMPAT, print the compat line once; fatal is the fatal error's
// message, "" for an exit. Call where the run ends.
compat_report :: proc(fatal := "") {
	if !compat.on || compat.reported {
		return
	}
	compat.reported = true
	l := compat_line(fatal)
	data, err := json.marshal(l, allocator = context.temp_allocator)
	if err != nil {
		fmt.eprintln("compat: cannot write the line:", err)
		return
	}
	fmt.eprintfln("compat: %s", data)
}
