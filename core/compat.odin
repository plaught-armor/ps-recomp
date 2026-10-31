// Compatibility counters and the compat line. The runtimes count, on their
// slow paths only (interpreter entry and instructions, the unknown-call
// paths of the HLE BIOS, kernel and SIF), never in recompiled code:
// - interpreter instructions, and interpreter entries by pc (the hottest
//   COMPAT_TOP reported);
// - calls the HLE does not implement, by name, with where the first was
//   made.
// Built with -define:COMPAT_COUNT=false the counters compile away.
//
// COMPAT=1 makes a run a compatibility run: a call the HLE does not
// implement returns 0 and the game goes on, where it would stop the game,
// and one JSON line tagged `compat:` goes to stderr when the run ends at
// FRAMES, on an exit and on a fatal error. A run that ends with no line
// crashed.
package core

import "core:encoding/json"
import "core:fmt"
import "core:slice"

COMPAT_COUNT :: #config(COMPAT_COUNT, true)

// How many interpreter entries the line lists, hottest first.
COMPAT_TOP :: 10

// The kinds of call the HLE may not implement. Id and sub per kind:
// Bios_A/B/C the function number; Syscall the syscall number (as an i32);
// Sif_Bind the server id; Sif_Rpc the server id and function number;
// Sif_Cmd the command id.
Compat_Call :: enum u8 {
	Bios_A,
	Bios_B,
	Bios_C,
	Syscall,
	Sif_Bind,
	Sif_Rpc,
	Sif_Cmd,
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
	// The console ("ps1", "ps2"), its cycle counter and the cycles its
	// interpreter charges an instruction, from the host.
	system:        string,
	cycles:        ^u64,
	cpi:           u64,
	interp_insns:  u64,
	entries:       [ENTRY_SLOTS]Entry_Slot,
	entries_other: u64,
	calls:         map[Compat_Key]Compat_Hit,
	reported:      bool,
}

// Read COMPAT, for the host's console, its cycle counter and the cycles its
// interpreter charges an instruction. Call from the host's init.
compat_init :: proc(system: string, cycles: ^u64, cycles_per_insn: u64) {
	compat.on = env("COMPAT") == "1"
	compat.system = system
	compat.cycles = cycles
	compat.cpi = cycles_per_insn
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
// cycles_per_insn: what the interpreter charges an instruction, so
// interp_insns * cycles_per_insn / cycles is about the share of the run
// interpreted (the cycles also hold stalls and skipped idle loops, so it
// errs low); build: the ps-recomp commit (COMMIT).
Compat_Line :: struct {
	system:               string,
	result:               string,
	frames:               u64,
	cycles:               u64,
	cycles_per_insn:      u64,
	interp_insns:         u64,
	interp_entries:       []Compat_Pc,
	interp_entries_other: u64,
	unimplemented:        []Compat_Name,
	fatal:                string,
	build:                string,
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
		build                = COMMIT,
	}
	switch {
	case fatal != "": l.result = "fatal"
	case frames != 0 && vblank >= frames: l.result = "frames"
	case: l.result = "exit"
	}
	if compat.cycles != nil {
		l.cycles = compat.cycles^
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
		i += 1
	}
	slice.sort_by(calls, proc(a, b: Compat_Name) -> bool {
		return a.n > b.n || a.n == b.n && a.name < b.name
	})
	l.unimplemented = calls
	return l
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
