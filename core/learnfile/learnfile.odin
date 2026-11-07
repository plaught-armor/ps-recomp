// The LEARN file format: what core/learn.odin writes and the player and
// the recompiler read. No host state, so any target can build it.
//
// A LEARN file is a run of records, appended and never rewritten, so
// several runs can share one file and a run that never reaches its end
// keeps what it wrote:
//	'E', cpu: u8, flags: u8, 0: u8, entry: u32, lo: u32, n: u32, hash: u64,
//	words: [n]u32
// lo is the first word's address; hash is the XXH3-64 of the words' bytes,
// so a reader drops a record whose words do not match it. Integers are
// little-endian. Records repeat across runs; readers dedupe. The tag is the
// stream's version: earlier files are not read, as 'C' (no .Open, ring-only
// checks) and 'D' (fetched words not checked) records may hold code that
// changed mid-run.
package learnfile

import "core:hash/xxhash"
import "core:slice"

Learn_Cpu :: enum u8 {
	Psx,
	Ee,
	Iop,
}

Learn_Flag :: enum u8 {
	Smc,         // the run stored into its own range
	Smc_Unknown, // its stores could not all be checked
	Large,       // the range is over LEARN_SPAN_MAX; no words kept
	Open,        // the run had not returned when the process reported
}
Learn_Flags :: bit_set[Learn_Flag;u8]

// The widest range kept, in bytes.
LEARN_SPAN_MAX :: 64 * 1024

// A record's header: tag, cpu, flags, 0, entry, lo, n, hash.
LEARN_HEADER :: 24
LEARN_TAG :: 'E'

Learn_Record :: struct {
	cpu:   Learn_Cpu,
	flags: Learn_Flags,
	entry: u32,
	lo:    u32,
	hash:  u64,
	words: []u32,
}

// A record's identity: records equal in it are one record.
Learn_Key :: struct {
	cpu:   Learn_Cpu,
	flags: Learn_Flags,
	entry: u32,
	lo, n: u32,
	hash:  u64,
}

// r's identity.
learn_key :: proc(r: Learn_Record) -> Learn_Key {
	return {r.cpu, r.flags, r.entry, r.lo, u32(len(r.words)), r.hash}
}

// Writes a record's header into h (LEARN_HEADER bytes).
learn_header :: proc(h: []u8, cpu: Learn_Cpu, flags: Learn_Flags, entry, lo, n: u32, hash: u64) {
	h[0] = LEARN_TAG
	h[1] = u8(cpu)
	h[2] = transmute(u8)flags
	h[3] = 0
	(^u32le)(&h[4])^ = u32le(entry)
	(^u32le)(&h[8])^ = u32le(lo)
	(^u32le)(&h[12])^ = u32le(n)
	(^u64le)(&h[16])^ = u64le(hash)
}

// The records in data, in order. A record whose words do not hash to its
// hash is dropped (bad); a short or unknown tail ends the read (bad, once).
// The words point into data.
learn_read :: proc(data: []u8, allocator := context.allocator) -> (recs: [dynamic]Learn_Record, bad: int) {
	recs = make([dynamic]Learn_Record, allocator)
	for at := 0; at < len(data); {
		h := data[at:]
		if len(h) < LEARN_HEADER || h[0] != LEARN_TAG || h[1] > u8(max(Learn_Cpu)) {
			return recs, bad + 1
		}
		n := int((^u32le)(&h[12])^)
		size := LEARN_HEADER + n * 4
		if n > LEARN_SPAN_MAX / 4 || len(h) < size {
			return recs, bad + 1
		}
		at += size
		hash := u64((^u64le)(&h[16])^)
		if u64(xxhash.XXH3_64_default(h[LEARN_HEADER:size])) != hash {
			bad += 1
			continue
		}
		append(&recs, Learn_Record {
			cpu = Learn_Cpu(h[1]),
			flags = transmute(Learn_Flags)h[2],
			entry = u32((^u32le)(&h[4])^),
			lo = u32((^u32le)(&h[8])^),
			hash = hash,
			words = ([^]u32)(raw_data(h[LEARN_HEADER:]))[:n],
		})
	}
	return recs, bad
}

// The records in data each once, without bad ones, sorted by cpu, entry,
// lo, words, hash and flags: a LEARN file's bytes compacted, which a
// rewrite of the file bounds growth across runs with. In context.allocator;
// n is the records it holds.
learn_compact :: proc(data: []u8) -> (out: []u8, n: int) {
	recs, _ := learn_read(data, context.temp_allocator)
	seen := make(map[Learn_Key]bool, context.temp_allocator)
	keep := make([dynamic]Learn_Record, context.temp_allocator)
	size := 0
	for r in recs {
		key := learn_key(r)
		if key in seen {continue}
		seen[key] = true
		append(&keep, r)
		size += LEARN_HEADER + 4 * len(r.words)
	}
	slice.sort_by(keep[:], learn_less)
	buf := make([]u8, size)
	at := 0
	for r in keep {
		learn_header(buf[at:][:LEARN_HEADER], r.cpu, r.flags, r.entry, r.lo, u32(len(r.words)), r.hash)
		at += LEARN_HEADER
		copy(buf[at:], ([^]u8)(raw_data(r.words))[:4 * len(r.words)])
		at += 4 * len(r.words)
	}
	return buf, len(keep)
}

@(private = "file")
learn_less :: proc(a, b: Learn_Record) -> bool {
	if a.cpu != b.cpu {return a.cpu < b.cpu}
	if a.entry != b.entry {return a.entry < b.entry}
	if a.lo != b.lo {return a.lo < b.lo}
	if len(a.words) != len(b.words) {return len(a.words) > len(b.words)}
	if a.hash != b.hash {return a.hash < b.hash}
	return transmute(u8)a.flags < transmute(u8)b.flags
}

// The records of cpu in recs that native code can stand for, each entry
// and words once: those of runs that kept their words (not .Large) and
// never stored into them. An entry and words that any run stored into
// (.Smc), or may have (.Smc_Unknown), is left out, as a copy of its words
// would not see the stores. .Open runs are kept. Also how many records
// are left out as .Large and as stored into. In allocator; the words are
// recs'.
learn_compilable :: proc(recs: []Learn_Record, cpu: Learn_Cpu, allocator := context.allocator) -> (out: [dynamic]Learn_Record, large, smc: int) {
	Code :: struct {
		entry, lo, n: u32,
		hash:         u64,
	}
	stored := make(map[Code]bool, context.temp_allocator)
	for r in recs {
		if r.cpu == cpu && r.flags & {.Smc, .Smc_Unknown} != {} {
			stored[{r.entry, r.lo, u32(len(r.words)), r.hash}] = true
		}
	}
	taken := make(map[Code]bool, context.temp_allocator)
	out = make([dynamic]Learn_Record, allocator)
	for r in recs {
		if r.cpu != cpu {continue}
		if .Large in r.flags {
			large += 1
			continue
		}
		c := Code{r.entry, r.lo, u32(len(r.words)), r.hash}
		if stored[c] {
			smc += 1
			continue
		}
		if len(r.words) == 0 || taken[c] {continue}
		taken[c] = true
		append(&out, r)
	}
	return
}
