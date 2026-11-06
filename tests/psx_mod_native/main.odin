// The mods' native code (psx/native/mods.odin, psx/cpu/mod_ram.odin,
// core/mod_dir.odin), on hand-built mod ELFs with a .symtab in the OS temp
// directory. Each load runs in a child process, as hooks cannot be taken
// out again:
//
//   - mod_elf_read lists an ELF's .symtab functions; with no .symtab there
//     are none.
//   - mod_set_hash is stable, and changes for a mod.elf byte, a mod.tsv
//     byte, another order, an added mod and a removed mod.
//   - A before hook on a game function calls a second mod function (jal in
//     the region) and a hooked game function (whose hook is that second
//     function). Run from a blob of the mods' functions, its count equals
//     the interpreted run's although the region's code was changed under
//     it after the load, every mod call ran native, and a checkpoint pass
//     keeps it native. Under FLAT there is no native code: the run is
//     interpreted, and sees the changed code.
//   - A blob compiled from other code is refused with a message, and the
//     mods are interpreted. So is one whose span is not one whole mod
//     function entered at its start (the region's zero data, a function's
//     first words, an entry past a function's start), though the words
//     match the region.
//   - An ELF whose loadable segments overlap is refused.
//   - A store into a mod function's code is fatal, naming the mod.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "ps:core"
import "ps:psx"
import cpu "ps:psx/cpu"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_mod_native: %s (line %d)", what, loc.line)
		failed += 1
	}
}

GAME :: 0x80010000
GAME2 :: 0x80010100
HOOK :: 0x1f400000
ADD :: 0x1f400040
DATA :: 0x1f401000
GAME_SP :: 0x801ffe00

// addiu v0, a0, 1; jr ra; nop; nop
@(private = "file", rodata)
GAME_CODE := [4]u32{0x24820001, 0x03e00008, 0, 0}

// HOOK: addiu sp, sp, -8; sw ra, 0(sp); jal ADD; nop; lui t9, 0x8001;
// ori t9, t9, 0x100; jalr t9 (GAME2); nop; lw ra, 0(sp); jr ra;
// addiu sp, sp, 8, then nops to ADD: lui t0, 0x1f40; lw t1, 0x1000(t0);
// nop (the load's delay slot); addiu t1, t1, K; sw t1, 0x1000(t0); jr ra;
// nop.
@(private = "file")
mod_code :: proc(k: u32) -> []u32 {
	c := make([]u32, 23)
	copy(c, []u32{0x27bdfff8, 0xafbf0000, 0x0fd00010, 0, 0x3c198001, 0x37390100, 0x0320f809, 0, 0x8fbf0000, 0x03e00008, 0x27bd0008})
	copy(c[16:], []u32{0x3c081f40, 0x8d091000, 0, 0x25290000 | k, 0xad091000, 0x03e00008, 0})
	return c
}

// The word of ADD's addiu, at region offset ADD_K.
ADD_K :: ADD - HOOK + 12

// HOOK as lui t0, 0x1f40; sw zero, 0x40(t0) (ADD's first word); jr ra; nop.
@(private = "file")
store_code :: proc() -> []u32 {
	c := mod_code(1)
	copy(c, []u32{0x3c081f40, 0xad000040, 0x03e00008, 0})
	return c
}

@(private = "file")
FUNCS := [2][2]u32{{HOOK, 44}, {ADD, 28}}

@(private = "file")
Seg :: struct {
	addr: u32,
	code: []u32,
	mem:  u32,
}

// A mod ELF: segs, a .mod_hooks section of hooks' words, and a .symtab of
// funcs ({address, size} each; none, no .symtab).
@(private = "file")
elf_make :: proc(segs: []Seg, hooks: []u32, funcs: [][2]u32) -> []u8 {
	b := make([dynamic]u8)
	w16 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8))}
	w32 :: proc(b: ^[dynamic]u8, v: u32) {w16(b, v);w16(b, v >> 16)}
	names := "\x00.mod_hooks\x00.shstrtab\x00.symtab\x00"
	at := u32(52 + 32 * len(segs))
	offs := make([]u32, len(segs), context.temp_allocator)
	for s, k in segs {offs[k] = at;at += u32(len(s.code)) * 4}
	hooks_at := at
	names_at := hooks_at + u32(len(hooks)) * 4
	syms_at := (names_at + u32(len(names)) + 3) &~ 3
	nsyms := u32(len(funcs) + 1) if len(funcs) > 0 else 0
	sh_at := syms_at + 16 * nsyms
	nsh := u32(4) if nsyms > 0 else 3

	append(&b, 0x7f, 'E', 'L', 'F', 1, 1, 1)
	for len(b) < 16 {append(&b, 0)}
	w16(&b, 2);w16(&b, 8);w32(&b, 1);w32(&b, segs[0].addr)
	w32(&b, 52);w32(&b, sh_at);w32(&b, 0);w16(&b, 52);w16(&b, 32);w16(&b, u32(len(segs)))
	w16(&b, 40);w16(&b, nsh);w16(&b, 2)
	for s, k in segs {
		for v in ([]u32{1, offs[k], s.addr, s.addr, u32(len(s.code)) * 4, s.mem, 7, 4}) {w32(&b, v)}
	}
	for s in segs {for v in s.code {w32(&b, v)}}
	for v in hooks {w32(&b, v)}
	append(&b, names)
	for u32(len(b)) < syms_at {append(&b, 0)}
	if nsyms > 0 {
		for _ in 0 ..< 4 {w32(&b, 0)}
		// st_name 0, st_value, st_size, STB_GLOBAL STT_FUNC, st_shndx 1
		for f in funcs {w32(&b, 0);w32(&b, f[0]);w32(&b, f[1]);w32(&b, 0x0001_0012)}
	}
	for _ in 0 ..< 10 {w32(&b, 0)}
	for v in ([]u32{1, 1, 0, 0, hooks_at, u32(len(hooks)) * 4, 0, 0, 4, 0}) {w32(&b, v)}
	for v in ([]u32{12, 3, 0, 0, names_at, u32(len(names)), 0, 0, 1, 0}) {w32(&b, v)}
	if nsyms > 0 {
		for v in ([]u32{22, 2, 0, 0, syms_at, 16 * nsyms, 2, 1, 4, 16}) {w32(&b, v)}
	}
	return b[:]
}

// Before hooks: on GAME calling HOOK, on GAME2 calling ADD.
@(private = "file")
hooks_words :: proc() -> []u32 {
	h := make([]u32, 2 * core.MOD_HOOK_WORDS)
	for at, k in ([2][2]u32{{GAME, HOOK}, {GAME2, ADD}}) {
		w := h[k * core.MOD_HOOK_WORDS:]
		w[3], w[8] = at[0], at[1]
		copy(w[4:8], GAME_CODE[:])
	}
	return h
}

@(private = "file")
mod_elf :: proc(code: []u32, symtab := true) -> []u8 {
	segs := []Seg{{HOOK, code, u32(len(code)) * 4}, {DATA, nil, 8}}
	return elf_make(segs, hooks_words(), FUNCS[:] if symtab else nil)
}

@(private = "file")
write :: proc(dir, name: string, data: []u8) -> string {
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, name})
	check(os.write_entire_file(path, data) == nil, fmt.tprintf("write %s", path))
	return path
}

@(private = "file")
TSV :: "id\tcounter\nversion\t1.0.0\napi\t1\ndisc\tTEST-00001\n"

// A mods directory under tmp with one mod, counter, of elf; its path.
@(private = "file")
mods_dir :: proc(tmp, name: string, elf: []u8) -> string {
	mods, _ := filepath.join({tmp, name})
	one, _ := filepath.join({mods, "counter"})
	write(one, "mod.tsv", transmute([]u8)string(TSV))
	write(one, "mod.elf", elf)
	return mods
}

// The mods blob for elf, as play's --mods child compiles it.
@(private = "file")
blob_of :: proc(elf: []u8) -> []u8 {
	img, err := core.mod_elf_read(elf, cpu.MOD_BASE, cpu.MOD_BASE + cpu.MOD_REGION, 0)
	check(err == "", fmt.tprintf("blob ELF: %s", err))
	runs := make([dynamic]r3000.Learned)
	for f in img.funcs {
		words := make([]u32, len(f.bytes) / 4)
		for &w, i in words {w = u32((^u32le)(&f.bytes[i * 4])^)}
		append(&runs, r3000.Learned{f.addr, f.addr, words})
	}
	return blob_runs(runs[:])
}

@(private = "file")
blob_runs :: proc(runs: []r3000.Learned) -> []u8 {
	return r3000.learned_blob(runs, native.Arch(core.NATIVE_ARCH))
}

@(private = "file")
count :: proc() -> u32 {return u32((^u32le)(&cpu.mod_ram[DATA - cpu.MOD_BASE])^)}

@(private = "file")
call_game :: proc(a0: u32) -> u32 {
	cpu.state.r[4], cpu.state.r[29], cpu.state.r[31] = a0, GAME_SP, 0
	cpu.call(GAME)
	return cpu.state.r[2]
}

// The child: load the mods in dir with blob ("-" none), then, when patch is
// "1", make ADD add 100 in the region. Call GAME five times, a checkpoint
// pass around the fourth, and print its last result, the count and the
// native calls.
@(private = "file")
child :: proc(dir, blob, patch: string) {
	for at in ([2]u32{GAME, GAME2}) {
		for w, k in GAME_CODE {(^u32le)(&cpu.ram[(at & 0x1fffff) + u32(k) * 4])^ = u32le(w)}
	}
	set, read := psx.mods_identify(dir, "TEST-00001.0123456789abcdef")
	ok := read && psx.mods_load(set, blob == "-" ? "" : blob, proc() {
		fmt.eprintln("child: blob failed")
	})
	if !ok || cpu.mod_ram == nil {
		fmt.eprintln("child: no mods loaded")
		os.exit(2)
	}
	if patch == "1" {(^u32le)(&cpu.mod_ram[ADD_K])^ = 0x25290064}
	r: u32
	for _ in 0 ..< 3 {r = call_game(5)}
	cp := new(psx.Checkpoint)
	if !psx.checkpoint_save(cp) {os.exit(4)}
	r = call_game(5)
	psx.checkpoint_restore(cp)
	r = call_game(5)
	fmt.printfln("%d %d %d", r, count(), cpu.mod_native_hits)
	os.exit(0)
}

Run :: struct {
	result, count, hits: u64,
	err:                 string,
	ok:                  bool,
}

@(private = "file")
run :: proc(self, dir, blob, patch: string) -> (r: Run) {
	state, out, errs, err := os.process_exec({command = {self, "child", dir, blob, patch}}, context.temp_allocator)
	r.err = string(errs)
	if err != nil || state.exit_code != 0 {
		check(false, fmt.tprintf("child %s %s %s: %v exit %d: %s", dir, blob, patch, err, state.exit_code, r.err))
		return
	}
	f := strings.fields(strings.trim_space(string(out)), context.temp_allocator)
	if len(f) != 3 {
		check(false, fmt.tprintf("child said %q", string(out)))
		return
	}
	ok1, ok2, ok3: bool
	r.result, ok1 = strconv.parse_u64(f[0])
	r.count, ok2 = strconv.parse_u64(f[1])
	r.hits, ok3 = strconv.parse_u64(f[2])
	r.ok = ok1 && ok2 && ok3
	check(r.ok, fmt.tprintf("child said %q", string(out)))
	return
}

@(private = "file")
test_funcs :: proc() {
	lo, hi := u32(cpu.MOD_BASE), u32(cpu.MOD_BASE + cpu.MOD_REGION)
	img, err := core.mod_elf_read(mod_elf(mod_code(1)), lo, hi, 0)
	check(err == "" && len(img.funcs) == 2, fmt.tprintf("functions: %s, %d", err, len(img.funcs)))
	if len(img.funcs) == 2 {
		check(img.funcs[0].addr == HOOK && len(img.funcs[0].bytes) == 44, "HOOK function")
		check(img.funcs[1].addr == ADD && len(img.funcs[1].bytes) == 28, "ADD function")
	}
	img, err = core.mod_elf_read(mod_elf(mod_code(1), false), lo, hi, 0)
	check(err == "" && len(img.funcs) == 0, fmt.tprintf("no .symtab: %s, %d functions", err, len(img.funcs)))
	code := mod_code(1)
	overlap := elf_make({{HOOK, code, u32(len(code)) * 4}, {HOOK + 8, nil, 8}}, hooks_words(), FUNCS[:])
	_, err = core.mod_elf_read(overlap, lo, hi, 0)
	check(err == "segments 1f400000-1f40005c and 1f400008-1f400010 overlap", fmt.tprintf("overlapping segments: %q", err))
}

@(private = "file")
test_hash :: proc() {
	elf_a, elf_b := mod_elf(mod_code(1)), mod_elf(mod_code(2))
	tsv := transmute([]u8)string(TSV)
	tsv2 := transmute([]u8)string("id\tcounter\nversion\t1.0.1\napi\t1\ndisc\tTEST-00001\n")
	set :: proc(ids: []string, tsv, elf: [][]u8, order: []int) -> core.Mod_Set {
		mods := make([]core.Mod_Manifest, len(ids), context.temp_allocator)
		for id, k in ids {mods[k].id = id}
		return {mods = mods, order = order, tsv = tsv, elf = elf}
	}
	two := set({"a", "b"}, {tsv, tsv}, {elf_a, elf_b}, {0, 1})
	h := core.mod_set_hash(two)
	check(h == core.mod_set_hash(set({"a", "b"}, {tsv, tsv}, {elf_a, elf_b}, {0, 1})), "hash stable")
	diff := [?]struct {
		what: string,
		set:  core.Mod_Set,
	} {
		{"mod.elf byte", set({"a", "b"}, {tsv, tsv}, {elf_a, elf_a}, {0, 1})},
		{"mod.tsv byte", set({"a", "b"}, {tsv, tsv2}, {elf_a, elf_b}, {0, 1})},
		{"order", set({"a", "b"}, {tsv, tsv}, {elf_a, elf_b}, {1, 0})},
		{"added mod", set({"a", "b", "c"}, {tsv, tsv, tsv}, {elf_a, elf_b, elf_a}, {0, 1, 2})},
		{"removed mod", set({"a"}, {tsv}, {elf_a}, {0})},
		{"id", set({"a", "c"}, {tsv, tsv}, {elf_a, elf_b}, {0, 1})},
	}
	for d in diff {check(core.mod_set_hash(d.set) != h, fmt.tprintf("hash kept for another %s", d.what))}
}

main :: proc() {
	cpu.next_event = max(u64)
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	if len(os.args) == 5 && os.args[1] == "child" {child(os.args[2], os.args[3], os.args[4])}

	test_funcs()
	test_hash()

	tmp, terr := os.make_directory_temp("", "ps_mod_native_test_*", context.allocator)
	if terr != nil {
		fmt.eprintln("FAIL psx_mod_native: no temp directory:", terr)
		os.exit(1)
	}
	defer os.remove_all(tmp)
	self, _ := os.get_executable_path(context.allocator)
	elf_a := mod_elf(mod_code(1))
	dir_a := mods_dir(tmp, "a", elf_a)
	dir_b := mods_dir(tmp, "b", mod_elf(mod_code(2)))
	blob_a := write(tmp, "a.bin", blob_of(elf_a))

	// Five calls, each counting 2K (HOOK's call of ADD, and GAME2's hook);
	// the pass takes one back.
	want :: proc(k: u64) -> u64 {return 8 * k}
	interp := run(self, dir_a, "-", "0")
	check(interp.ok && interp.result == 6 && interp.count == want(1) && interp.hits == 0, fmt.tprintf("interpreted: %v", interp))

	// Native: ADD is changed in the region after the load, which only
	// interpreted code sees. 3 native calls each (HOOK, ADD, ADD).
	nat := run(self, dir_a, blob_a, "1")
	when core.FLAT {
		check(nat.ok && nat.result == 6 && nat.count == want(100) && nat.hits == 0, fmt.tprintf("FLAT, with a blob: %v", nat))
	} else {
		check(nat.ok && nat.result == interp.result && nat.count == interp.count, fmt.tprintf("native %v, interpreted %v", nat, interp))
		check(nat.hits == 15, fmt.tprintf("native calls %d, want 15", nat.hits))
		check(strings.contains(nat.err, "mods: 2 functions from"), fmt.tprintf("native load said %q", nat.err))
	}

	// A stale blob: refused, interpreted.
	stale := run(self, dir_b, blob_a, "0")
	check(stale.ok && stale.count == want(2) && stale.hits == 0, fmt.tprintf("stale blob: %v", stale))
	when !core.FLAT {
		check(strings.contains(stale.err, "is not the mods' code; the mods are interpreted") && strings.contains(stale.err, "child: blob failed"), fmt.tprintf("stale blob said %q", stale.err))
	}

	// Blobs whose words match the region but whose span is not one whole
	// mod function entered at its start: refused, interpreted.
	when !core.FLAT {
		code := mod_code(1)
		bad := [?]struct {
			what: string,
			run:  r3000.Learned,
		} {
			{"the region's zero data", {DATA, DATA, {0, 0}}},
			{"HOOK's first words", {HOOK, HOOK, code[:4]}},
			{"an entry past HOOK's start", {HOOK + 4, HOOK, code[:11]}},
		}
		for b, k in bad {
			runs := []r3000.Learned{b.run}
			blob := write(tmp, fmt.tprintf("bad%d.bin", k), blob_runs(runs))
			r := run(self, dir_a, blob, "0")
			check(r.ok && r.count == want(1) && r.hits == 0, fmt.tprintf("blob of %s: %v", b.what, r))
			check(strings.contains(r.err, "is not the mods' code; the mods are interpreted"), fmt.tprintf("blob of %s said %q", b.what, r.err))
		}
	}

	// A store into ADD's code, from HOOK (native but under FLAT).
	{
		elf := mod_elf(store_code())
		dir := mods_dir(tmp, "s", elf)
		blob := write(tmp, "s.bin", blob_of(elf))
		state, _, errs, err := os.process_exec({command = {self, "child", dir, blob, "0"}}, context.temp_allocator)
		check(err == nil && state.exit_code == 1, fmt.tprintf("store child: %v exit %d", err, state.exit_code))
		check(strings.contains(string(errs), "fatal: mod counter: store into its code at 1f400040 (mods cannot change their code)"), fmt.tprintf("store child said %q", string(errs)))
	}

	if failed > 0 {
		fmt.eprintfln("psx_mod_native: %d failed", failed)
		os.exit(1)
	}
	when core.FLAT {
		fmt.println("ok psx_mod_native (FLAT): .symtab functions; overlapping segments are refused; the set hash; a blob is not loaded and the mods are interpreted; a store into mod code is fatal")
	} else {
		fmt.println("ok psx_mod_native: .symtab functions; the set hash; mod functions run native from a blob, as interpreted, through a pass; a stale blob, or one not of whole mod functions, is refused and interpreted; overlapping segments are refused; a store into mod code is fatal")
	}
}
