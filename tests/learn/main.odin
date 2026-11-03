// LEARN record test (core/learn.odin), on a file in the OS temp directory:
// runs written through learn_begin, learn_fetch, learn_store and learn_end
// read back the same; a repeated run is written once; a store into a run's
// range marks it .Smc and one outside does not, a store by another run in
// progress included; stores past the log mark .Smc_Unknown; a range over
// LEARN_SPAN_MAX is .Large with no words; and a reader drops a truncated
// record and one whose words do not match its hash. The directory is
// removed at the end whether the test passes or fails.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "ps:core"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL learn: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// The fake memory: each word is its address with a tag.
@(private = "file")
word :: proc(a: u32) -> u32 {
	return a ~ 0xdead0000
}

// One run from entry fetching each of pcs and storing at each of stores.
@(private = "file")
run :: proc(cpu: core.Learn_Cpu, entry: u32, pcs: []u32, stores: []u32 = nil) {
	f := core.learn_begin(cpu, entry)
	for pc in pcs {core.learn_fetch(&f, pc)}
	for a in stores {core.learn_store(&f, a)}
	core.learn_end(&f, word)
}

@(private = "file")
Want :: struct {
	cpu:   core.Learn_Cpu,
	flags: core.Learn_Flags,
	entry: u32,
	lo, n: u32,
}

@(private = "file")
check_recs :: proc(recs: []core.Learn_Record, want: []Want, what: string) {
	if len(recs) != len(want) {
		check(false, fmt.tprintf("%s: %d records, want %d", what, len(recs), len(want)))
		return
	}
	for r, i in recs {
		w := want[i]
		ok := r.cpu == w.cpu && r.flags == w.flags && r.entry == w.entry && r.lo == w.lo && u32(len(r.words)) == w.n
		for v, j in r.words {
			ok &&= v == word(r.lo + u32(j) * 4)
		}
		check(ok, fmt.tprintf("%s: record %d is %v %v %08x %08x n %d", what, i, r.cpu, r.flags, r.entry, r.lo, len(r.words)))
	}
}

main :: proc() {
	tmp, err := os.make_directory_temp("", "ps_learn_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL learn: no temp directory:", err)
		os.exit(1)
	}
	path, _ := filepath.join({tmp, "learn.bin"}, context.allocator)
	check(core.learn_open_path(path), "open")
	cycles: u64 = 1000
	core.learn_cpu(.Ee, &cycles, 1)

	run(.Ee, 0x1000, {0x1000, 0x1004, 0x1008, 0x100c}, {0x8000})
	run(.Ee, 0x1000, {0x1000, 0x1004, 0x1008, 0x100c}, {0x8000}) // a repeat
	run(.Psx, 0x1000, {0x1000, 0x1008}, {0x1004})
	run(.Ee, 0x3000, {0x3000, 0x3000 + core.LEARN_SPAN_MAX})
	// The range is 0x1010..0x1014: a word store just below it misses, one
	// overlapping its first byte hits.
	run(.Iop, 0x1010, {0x1010, 0x1014}, {0x100c})
	run(.Iop, 0x1020, {0x1020, 0x1024}, {0x101d})
	// More stores than the log holds, none in range.
	{
		f := core.learn_begin(.Iop, 0x1030)
		core.learn_fetch(&f, 0x1030)
		for i in 0 ..= u32(core.LEARN_STORES_MAX) {core.learn_store(&f, 0x9000_0000 + i * 4)}
		core.learn_end(&f, word)
	}
	// Two runs in progress at once, as guest threads switching mid-run: the
	// inner one's store into the outer's range marks the outer, and the
	// inner's end does not lose it.
	{
		g := core.learn_begin(.Ee, 0x1100)
		core.learn_fetch(&g, 0x1100)
		h := core.learn_begin(.Ee, 0x2000)
		core.learn_fetch(&h, 0x2000)
		core.learn_store(&h, 0x1104)
		core.learn_end(&h, word)
		core.learn_fetch(&g, 0x1108)
		core.learn_end(&g, word)
	}
	core.learn_report()

	want := []Want {
		{.Ee, {}, 0x1000, 0x1000, 4},
		{.Psx, {.Smc}, 0x1000, 0x1000, 3},
		{.Ee, {.Large}, 0x3000, 0x3000, 0},
		{.Iop, {}, 0x1010, 0x1010, 2},
		{.Iop, {.Smc}, 0x1020, 0x1020, 2},
		{.Iop, {.Smc_Unknown}, 0x1030, 0x1030, 1},
		{.Ee, {}, 0x2000, 0x2000, 1},
		{.Ee, {.Smc}, 0x1100, 0x1100, 3},
	}
	data, rerr := os.read_entire_file(path, context.allocator)
	check(rerr == nil, "read back")
	recs, bad := core.learn_read(data)
	check(bad == 0, fmt.tprintf("round trip: %d bad", bad))
	check_recs(recs[:], want, "round trip")

	// Cut into the last record: it is dropped, the rest kept.
	recs, bad = core.learn_read(data[:len(data) - 5])
	check(bad == 1, fmt.tprintf("truncated: %d bad", bad))
	check_recs(recs[:], want[:len(want) - 1], "truncated")

	// A word of the first record changed: that record is dropped, and the
	// read goes on past it.
	data[core.LEARN_HEADER + 4] ~= 1
	recs, bad = core.learn_read(data)
	check(bad == 1, fmt.tprintf("hash mismatch: %d bad", bad))
	check_recs(recs[:], want[1:], "hash mismatch")

	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok learn")
}
