// The mod region and loader (psx/cpu/mod_ram.odin, psx/mods.odin,
// core/mod_elf.odin), on hand-built mod ELFs in the OS temp directory:
//
//   - With no mods the region is not there: mod_ram is nil and its first
//     word reads 0, as unmapped.
//   - mod_elf_read rejects a file that is not an ELF, a segment outside the
//     region, a hook of an unknown kind and a hook whose function is not in
//     the image; two mods' overlapping images are an error naming both.
//   - psx.mods_load reads mods/<id>/mod.tsv and mod.elf, puts the image in
//     the region and installs its before hook on a game function in RAM.
//     The hook, interpreted from the region, counts its calls in its own
//     .bss and sees the region's stack; the game's result is kept and RAM
//     is untouched, so a RAM dump does not see the mod.
//   - A checkpoint pass puts the region back: the hook's count is as it was.
//   - LEARN notes the game function's run and not the hook's.
//   - A hook that writes below the mod stack's 16 KiB reaches the guard
//     word under it, and mod_call stops the run (in a child process).
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"
import "ps:psx"
import cpu "ps:psx/cpu"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_mod_region: %s (line %d)", what, loc.line)
		failed += 1
	}
}

GAME :: 0x80010000
HOOK :: 0x1f400000
DATA :: 0x1f401000
GAME_SP :: 0x801ffe00

// addiu v0, a0, 1; jr ra; nop; nop
@(private = "file", rodata)
GAME_CODE := [4]u32{0x24820001, 0x03e00008, 0, 0}

// lui t0, 0x1f40; lw t1, 0x1000(t0); addiu t1, t1, 1; sw t1, 0x1000(t0);
// sw sp, 0x1004(t0); jr ra; nop
@(private = "file", rodata)
HOOK_CODE := [7]u32{0x3c081f40, 0x8d091000, 0x25290001, 0xad091000, 0xad1d1004, 0x03e00008, 0}

// sw zero, -0x4ff0(sp); jr ra; nop: from the top of the 0x6000-byte region
// (the image to 0x1f401008, the guard at 0x1010), a store to the guard.
@(private = "file", rodata)
DEEP_CODE := [3]u32{0xafa0b010, 0x03e00008, 0}

@(private = "file")
Seg :: struct {
	addr: u32,
	code: []u32,
	mem:  u32,
}

// A mod ELF: segs, then a .mod_hooks section of hooks' words.
@(private = "file")
elf_make :: proc(segs: []Seg, hooks: []u32) -> []u8 {
	b := make([dynamic]u8)
	w16 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8))}
	w32 :: proc(b: ^[dynamic]u8, v: u32) {w16(b, v);w16(b, v >> 16)}
	names := "\x00.mod_hooks\x00.shstrtab\x00"
	at := u32(52 + 32 * len(segs))
	offs := make([]u32, len(segs), context.temp_allocator)
	for s, k in segs {offs[k] = at;at += u32(len(s.code)) * 4}
	hooks_at := at
	names_at := hooks_at + u32(len(hooks)) * 4
	sh_at := (names_at + u32(len(names)) + 3) &~ 3

	append(&b, 0x7f, 'E', 'L', 'F', 1, 1, 1)
	for len(b) < 16 {append(&b, 0)}
	w16(&b, 2);w16(&b, 8);w32(&b, 1);w32(&b, segs[0].addr if len(segs) > 0 else 0)
	w32(&b, 52);w32(&b, sh_at);w32(&b, 0);w16(&b, 52);w16(&b, 32);w16(&b, u32(len(segs)))
	w16(&b, 40);w16(&b, 3);w16(&b, 2)
	for s, k in segs {
		for v in ([]u32{1, offs[k], s.addr, s.addr, u32(len(s.code)) * 4, s.mem, 7, 4}) {w32(&b, v)}
	}
	for s in segs {for v in s.code {w32(&b, v)}}
	for v in hooks {w32(&b, v)}
	append(&b, names)
	for u32(len(b)) < sh_at {append(&b, 0)}
	for _ in 0 ..< 10 {w32(&b, 0)}
	for v in ([]u32{1, 1, 0, 0, hooks_at, u32(len(hooks)) * 4, 0, 0, 4, 0}) {w32(&b, v)}
	for v in ([]u32{12, 3, 0, 0, names_at, u32(len(names)), 0, 0, 1, 0}) {w32(&b, v)}
	return b[:]
}

// A before hook on GAME calling fn.
@(private = "file")
hook_words :: proc(fn: u32, kind: u32 = 0) -> []u32 {
	h := make([]u32, core.MOD_HOOK_WORDS)
	h[0], h[3], h[8] = kind, GAME, fn
	copy(h[4:8], GAME_CODE[:])
	return h
}

@(private = "file")
mod_segs :: proc(code: []u32) -> []Seg {
	s := make([]Seg, 2)
	s[0] = {HOOK, code, u32(len(code)) * 4}
	s[1] = {DATA, nil, 8}
	return s
}

@(private = "file")
write :: proc(dir, name: string, data: []u8) {
	os.make_directory_all(dir)
	path, _ := filepath.join({dir, name})
	check(os.write_entire_file(path, data) == nil, fmt.tprintf("write %s", path))
}

@(private = "file")
count :: proc() -> u32 {return u32((^u32le)(&cpu.mod_ram[DATA - cpu.MOD_BASE])^)}

@(private = "file")
call_game :: proc(a0: u32) -> u32 {
	cpu.state.r[4], cpu.state.r[29], cpu.state.r[31] = a0, GAME_SP, 0
	cpu.call(GAME)
	check(cpu.state.r[29] == GAME_SP, "game sp kept")
	return cpu.state.r[2]
}

@(private = "file")
temp_dir :: proc() -> string {
	tmp, err := os.make_directory_temp("", "ps_mod_region_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL psx_mod_region: no temp directory:", err)
		os.exit(1)
	}
	return tmp
}

// Load a mod of code hooking GAME from a new mods directory under tmp.
@(private = "file")
load :: proc(tmp: string, code: []u32) -> bool {
	for w, k in GAME_CODE {(^u32le)(&cpu.ram[(GAME & 0x1fffff) + u32(k) * 4])^ = u32le(w)}
	mods, _ := filepath.join({tmp, "mods"})
	one, _ := filepath.join({mods, "counter"})
	write(one, "mod.tsv", transmute([]u8)string("id\tcounter\nversion\t1.0.0\napi\t1\ndisc\tTEST-00001\n"))
	write(one, "mod.elf", elf_make(mod_segs(code), hook_words(HOOK)))
	return psx.mods_load(mods, "TEST-00001.0123456789abcdef")
}

// The child: a hook overflows the mod stack, which is fatal.
@(private = "file")
overflow :: proc() {
	tmp := temp_dir()
	ok := load(tmp, DEEP_CODE[:])
	os.remove_all(tmp)
	if !ok || len(cpu.mod_ram) != 0x6000 {
		fmt.eprintln("overflow: layout", ok, len(cpu.mod_ram))
		os.exit(2)
	}
	call_game(1)
	fmt.eprintln("overflow: returned")
	os.exit(3)
}

main :: proc() {
	cpu.next_event = max(u64)
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	if len(os.args) == 2 && os.args[1] == "overflow" {overflow()}
	{
		self, _ := os.get_executable_path(context.allocator)
		state, _, errs, err := os.process_exec({command = {self, "overflow"}}, context.temp_allocator)
		check(err == nil && state.exit_code == 1, fmt.tprintf("overflow child: %v exit %d", err, state.exit_code))
		check(strings.contains(string(errs), "fatal: mod: the hook at 1f400000 overflowed the 16384-byte mod stack"), fmt.tprintf("overflow child said %q", string(errs)))
	}

	// No mods.
	check(cpu.mod_ram == nil, "mod_ram with no mods")
	check(cpu.lw(HOOK) == 0, "region read with no mods")
	check(psx.mods_load("", "") && psx.mods_load("/nonexistent/mods", ""), "no mods dir loads")
	check(cpu.mod_ram == nil, "mod_ram after loading no mods")

	// ELF errors.
	lo, hi := u32(cpu.MOD_BASE), u32(cpu.MOD_BASE + cpu.MOD_REGION)
	{
		img, err := core.mod_elf_read(elf_make(mod_segs(HOOK_CODE[:]), hook_words(HOOK)), lo, hi, 3)
		check(err == "" && img.lo == HOOK && img.hi == DATA + 8 && len(img.segments) == 2, fmt.tprintf("good ELF: %s", err))
		check(len(img.hooks) == 1 && img.hooks[0].fn == HOOK && img.hooks[0].mod == 3 && img.hooks[0].key.sig == GAME_CODE, "good ELF hook")
		check(core.mod_image_has(img, 0x9f401004) && !core.mod_image_has(img, DATA + 8), "image addresses")
		_, err = core.mod_elf_read(transmute([]u8)string("not an elf at all, not at all, not at all, not at all"), lo, hi, 0)
		check(err != "", "not an ELF read")
		_, err = core.mod_elf_read(elf_make({{0x1f800000, HOOK_CODE[:], 28}}, nil), lo, hi, 0)
		check(strings.contains(err, "outside the mod region"), fmt.tprintf("segment outside: %q", err))
		_, err = core.mod_elf_read(elf_make(mod_segs(HOOK_CODE[:]), hook_words(HOOK, 3)), lo, hi, 0)
		check(strings.contains(err, "kind 3"), fmt.tprintf("bad kind: %q", err))
		_, err = core.mod_elf_read(elf_make(mod_segs(HOOK_CODE[:]), hook_words(DATA + 8)), lo, hi, 0)
		check(strings.contains(err, "not in the image"), fmt.tprintf("fn outside: %q", err))
	}
	{
		a := core.Mod_Image{lo = 0x1f400000, hi = 0x1f401000}
		b := core.Mod_Image{lo = 0x1f400800, hi = 0x1f402000}
		err := cpu.mod_ram_load({a, b}, {"first", "second"})
		check(strings.contains(err, "mod first and mod second") && strings.contains(err, "overlap"), fmt.tprintf("overlap: %q", err))
		check(cpu.mod_ram == nil, "region after an overlap")
	}

	// A mod on disk.
	tmp := temp_dir()
	defer os.remove_all(tmp)
	learn, _ := filepath.join({tmp, "learn.bin"})
	check(core.learn_open_path(learn, {.Psx}), "learn open")
	core.learn_cpu(.Psx, &cpu.state.cycles, cpu.CYCLES_PER_INSN, proc(a: u32) -> u32 {return cpu.lw(a)}, cpu.RAM_SIZE, true)

	check(load(tmp, HOOK_CODE[:]), "mods_load")
	if cpu.mod_ram == nil {
		fmt.eprintln("FAIL psx_mod_region: no region loaded")
		os.exit(1)
	}
	check(len(cpu.mod_ram) % 4096 == 0 && len(cpu.mod_ram) >= 0x1008 + cpu.MOD_STACK, "region size")
	check(cpu.mod_sp == cpu.MOD_BASE + u32(len(cpu.mod_ram)), "mod_sp at the region's top")
	check(cpu.lw(HOOK) == HOOK_CODE[0] && cpu.lw(0x9f400004) == HOOK_CODE[1], "image in the region")
	ram := new([cpu.RAM_SIZE]u8)
	ram^ = cpu.ram
	check(call_game(5) == 6 && count() == 1, "hook ran once, game result kept")
	check(u32((^u32le)(&cpu.mod_ram[DATA + 4 - cpu.MOD_BASE])^) == cpu.mod_sp, "hook ran on the mod stack")
	check(string(ram[:]) == string(cpu.ram[:]), "RAM untouched by the mod")

	// A pass puts the region back.
	cp := new(psx.Checkpoint)
	check(psx.checkpoint_save(cp), "checkpoint_save")
	check(call_game(7) == 8 && count() == 2, "hook ran in the pass")
	psx.checkpoint_restore(cp)
	check(count() == 1, "region put back")
	check(call_game(1) == 2 && count() == 2, "hook after the pass")

	// LEARN: the game's runs only.
	data, rerr := os.read_entire_file(learn, context.allocator)
	check(rerr == nil, "learn read")
	recs, bad := core.learn_read(data)
	game_runs := 0
	for r in recs {
		check(r.entry & 0x1fffffff - cpu.MOD_BASE >= cpu.MOD_REGION, fmt.tprintf("learned a run at %08x", r.entry))
		if r.entry == GAME {game_runs += 1}
	}
	check(bad == 0 && game_runs > 0, fmt.tprintf("learned game runs: %d of %d, %d bad", game_runs, len(recs), bad))

	if failed > 0 {
		fmt.eprintfln("psx_mod_region: %d failed", failed)
		os.exit(1)
	}
	fmt.println("ok psx_mod_region: no region with no mods; ELF and overlap errors; a mod loaded from disk runs its hook from the region on its stack, leaves RAM alone, is put back by a pass, and is not learned; a stack overflow is fatal")
}
