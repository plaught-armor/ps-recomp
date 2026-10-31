// play test: play runs small synthetic PS1 discs (a PS-X EXE that loops on
// one branch), and in compat mode PS2 ones (an ELF), headless to FRAMES,
// under a DATA setting in the OS temp directory. The test runs itself as
// play, the converter child included.
// - native, psx_exe: a disc with SYSTEM.CNF, and one with only PSX.EXE,
//   convert; the blob and its key land in the disc's directory, the
//   temporary file a crash left there is overwritten and gone, the memory
//   cards directory is made, and the game runs to FRAMES with status 0. A
//   second run uses the stored blob with no conversion;
// - bad_blob: a stored blob with a whole header but cut short will not
//   load; play says so, removes its key and exits with status 1;
// - interpreted: a converter that cannot write its output (a directory in
//   the way) fails; play says it has no native code, stores nothing, and
//   runs the game to FRAMES interpreted;
// - compat: play --compat on a directory of discs, PS1 and PS2 (one of
//   each that loops, one that makes a BIOS call or an EE syscall the HLE
//   lacks, one that starts on an invalid instruction), and a file that is
//   not a disc gives one compat.tsv row per disc (ok, ok with the call
//   stubbed, fatal) and skips the file; the looping PS1 disc run again
//   with a vblank count it cannot reach in COMPAT_WAIT is a hang, and once
//   more to FRAMES ok, each time in place. Three PS1 discs load a second
//   executable no native code covers: LoadExec of it, over the boot
//   executable, checks its argc, stack and BSS; LoadExec of a missing file
//   runs the boot executable again; Load and Exec of it return to the boot
//   executable with its registers. The second executable's entry is in the
//   row's entries. Three PS2 discs switch programs: LoadExecPS2 of an ELF
//   over the boot text, which runs interpreted and checks its argc and the
//   memory cleared; LoadExecPS2 of a missing file, fatal; and a program that
//   changes a word of its recompiled text and ExecPS2s into itself, which
//   turns the function table off.
// It is all removed at the end whether the test passes or fails. Build it
// with -define:COMMIT=test: a dev build never uses a stored blob.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import "ps:play"
import "ps:ps2/kernel"
import "ps:tests/discimg"

@(private = "file")
FRAMES :: 5

@(private = "file")
failed: int

@(private = "file")
check :: proc(name: string, ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL play %s: %s (line %d)", name, what, loc.line)
		failed += 1
	}
}

@(private = "file")
tmp: string

main :: proc() {
	if len(os.args) > 1 {
		os.exit(play.run(os.args))
	}
	if core.COMMIT != "test" {
		fmt.eprintln("FAIL play: build with -define:COMMIT=test")
		os.exit(1)
	}
	err: os.Error
	tmp, err = os.make_directory_temp("", "ps_play_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL play: no temp directory:", err)
		os.exit(1)
	}
	data, _ := filepath.join({tmp, "data"}, context.allocator)
	os.set_env(core.env_name("DATA"), data)
	os.set_env(core.env_name("HEADLESS"), "1")
	os.set_env(core.env_name("FRAMES"), fmt.tprint(FRAMES))
	os.set_env(core.env_name("SW"), "1") // no Vulkan device needed
	os.set_env(core.env_name("GPU"), "sw")
	test_native("native", cnf_disc())
	test_bad_blob(test_native("psx_exe", exe_disc()))
	test_interpreted()
	test_compat()
	if os.remove_all(tmp) != nil {
		check("", false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok play")
}

// A PS-X EXE: header, then at 0x80010000 `b .` and its delay slot, or
// the code given.
@(private = "file")
exe :: proc(code: ..u32) -> []u8 {
	return exe_at({code = code})
}

// A PS-X EXE's layout: the header fields, the code at pc and a string at
// text + EXE_DATA.
@(private = "file")
Exe :: struct {
	pc, text, size: u32,
	bss:            [2]u32, // address, size
	code:           []u32,
	data:           string,
}

@(private = "file")
EXE_DATA :: 0x400

@(private = "file")
exe_at :: proc(x: Exe) -> []u8 {
	x := x
	if x.text == 0 {
		x.text, x.pc, x.size = 0x80010000, 0x80010000, 0x800
	}
	e := make([]u8, 0x800 + x.size, context.temp_allocator)
	copy(e, "PS-X EXE")
	endian.put_u32(e[0x10:], .Little, x.pc)
	endian.put_u32(e[0x18:], .Little, x.text)
	endian.put_u32(e[0x1c:], .Little, x.size)
	endian.put_u32(e[0x28:], .Little, x.bss[0])
	endian.put_u32(e[0x2c:], .Little, x.bss[1])
	endian.put_u32(e[0x30:], .Little, 0x801ffff0) // sp
	at := int(0x800 + x.pc - x.text)
	endian.put_u32(e[at:], .Little, 0x1000ffff)
	for w, k in x.code {
		endian.put_u32(e[at + 4 * k:], .Little, w)
	}
	if x.data != "" {
		copy(e[0x800 + EXE_DATA:], x.data)
	}
	return e
}

// A disc with SYSTEM.CNF naming DATA/PSX.EXE; extra goes in SYSTEM.CNF.
@(private = "file")
cnf_disc :: proc(extra := "", code: ..u32) -> []u8 {
	cnf := strings.concatenate({"BOOT = cdrom:\\DATA\\PSX.EXE;1\n", extra}, context.temp_allocator)
	return discimg.make_iso(cnf, sub_name = "PSX.EXE;1", sub = string(exe(..code)))
}

// A disc whose boot executable is boot and, with code, DATA/SECOND.EXE second.
@(private = "file")
exec_disc :: proc(boot: Exe, second: Exe = {}) -> []u8 {
	sub2 := len(second.code) > 0 ? string(exe_at(second)) : ""
	cnf :: "BOOT = cdrom:\\DATA\\PSX.EXE;1\n"
	return discimg.make_iso(cnf, sub_name = "PSX.EXE;1", sub = string(exe_at(boot)), sub2_name = sub2 != "" ? "SECOND.EXE;1" : "", sub2 = sub2)
}

@(private = "file")
SECOND :: "cdrom:\\DATA\\SECOND.EXE;1"
@(private = "file")
BOOT_DATA :: 0x80010000 + EXE_DATA

// LoadExec(SECOND, 0x801ff000, 0x100) after a pattern in the words at 0x704
// and 0x708 past the text. SECOND loads over the boot text and starts at
// 0x80010100, which no native code covers; its BSS of 0x106 bytes at 0x600
// clears whole words, 0x108 bytes. It checks argc, the stack and the BSS's
// last word cleared and the next one not, then loops; any check failing runs
// a reserved instruction.
@(private = "file")
loadexec_disc :: proc() -> []u8 {
	pat := la(T0, 0x80010704)
	path := la(A0, BOOT_DATA)
	stack := la(A1, 0x801ff000)
	fill := la(S0, 0x5a5a5a5a)
	boot := [?]u32 {
		pat[0], pat[1], fill[0], fill[1], sw(S0, 0, T0), sw(S0, 4, T0),
		path[0], path[1], stack[0], stack[1], li(A2, 0x100),
		li(T1, 0x51), JAL_A0, NOP,
		LOOP, NOP,
	}
	sp := la(T0, 0x801ff100)
	second := [?]u32 {
		li(T0, 1), bne(A0, T0, 17), NOP, // 0
		sp[0], sp[1], bne(SP, T0, 13), NOP, // 3
		pat[0], pat[1], lw(T1, 0, T0), NOP, bne(T1, 0, 7), NOP, // 7
		lw(T1, 4, T0), NOP, beq(T1, 0, 3), NOP, // 13
		LOOP, NOP, // 17
		RESERVED, // 19
	}
	return exec_disc(
		{code = boot[:], data = SECOND},
		{pc = 0x80010100, text = 0x80010000, size = 0x600, bss = {0x80010600, 0x106}, code = second[:]},
	)
}

// The word at 0x80100000 0: it is set to 1 and LoadExec of a missing file
// runs the boot executable again, which finds it 1 and loops. The word is
// outside the boot executable's text and BSS, which the run again copies and
// clears.
@(private = "file")
loadexec_missing_disc :: proc() -> []u8 {
	path := la(A0, BOOT_DATA)
	boot := [?]u32 {
		lui(T0, 0x8010), lw(T1, 0, T0), NOP, bne(T1, 0, 10), NOP, // 0
		li(S0, 1), sw(S0, 0, T0), path[0], path[1], li(A1, 0), li(A2, 0), // 5
		li(T1, 0x51), JAL_A0, NOP, // 11
		LOOP, NOP, // 14
	}
	return exec_disc({code = boot[:], data = "cdrom:\\DATA\\NONE.EXE"})
}

// Load(SECOND, hdr) and Exec(hdr, 1, 0) each return 1, and s0, sp and gp are
// what they were before; SECOND, at 0x80020000 clear of the boot text, checks
// argc and returns 7. Any check failing runs a reserved instruction.
@(private = "file")
load_exec_disc :: proc() -> []u8 {
	s0 := la(S0, 0x12345678)
	path := la(A0, BOOT_DATA)
	hdr := la(A1, BOOT_DATA + 0x100)
	hdr0 := la(A0, BOOT_DATA + 0x100)
	t0 := la(T0, 0x12345678)
	boot := [?]u32 {
		s0[0], s0[1], move(S1, SP), move(S2, GP), // 0
		path[0], path[1], hdr[0], hdr[1], li(T1, 0x42), JAL_A0, NOP, // 4
		li(T0, 1), bne(V0, T0, 21), NOP, // 11
		hdr0[0], hdr0[1], li(A1, 1), li(A2, 0), li(T1, 0x43), JAL_A0, NOP, // 14
		li(T0, 1), bne(V0, T0, 11), NOP, // 21
		t0[0], t0[1], bne(S0, T0, 7), NOP, bne(SP, S1, 5), NOP, bne(GP, S2, 3), NOP, // 24
		LOOP, NOP, // 32
		RESERVED, // 34
	}
	second := [?]u32{li(T0, 1), bne(A0, T0, 3), NOP, JR_RA, li(V0, 7), RESERVED}
	return exec_disc({code = boot[:], data = SECOND}, {pc = 0x80020000, text = 0x80020000, size = 0x100, code = second[:]})
}

// A PS2 ELF: code at text (32 words at most, `b .` and its delay slot when
// none), the recompiler's .text section, and data at text + ELF_DATA, all in
// one segment; it starts at entry, or text when that is 0.
@(private = "file")
Elf :: struct {
	text:  u32,
	entry: u32,
	code:  []u32,
	data:  string,
}
@(private = "file")
ELF_DATA :: 0x80

@(private = "file")
elf :: proc(code: ..u32) -> []u8 {
	return elf_at({text = 0x00100000, code = code})
}

@(private = "file")
elf_at :: proc(x: Elf) -> []u8 {
	CODE :: 0x100 // file offset of the code
	SEGMENT_SIZE :: 0x100
	SHSTRTAB :: "\x00.text\x00.shstrtab\x00"
	SH :: CODE + SEGMENT_SIZE // file offset of the section headers
	assert(len(x.code) * 4 <= ELF_DATA && len(x.data) <= SEGMENT_SIZE - ELF_DATA)
	e := make([]u8, SH + 3 * 40, context.temp_allocator)
	copy(e, "\x7fELF\x01\x01\x01")
	endian.put_u16(e[16:], .Little, 2) // executable
	endian.put_u16(e[18:], .Little, 8) // MIPS
	endian.put_u32(e[20:], .Little, 1)
	endian.put_u32(e[24:], .Little, x.entry != 0 ? x.entry : x.text)
	endian.put_u32(e[28:], .Little, 52) // program headers
	endian.put_u32(e[32:], .Little, SH)
	endian.put_u16(e[40:], .Little, 52)
	endian.put_u16(e[42:], .Little, 32)
	endian.put_u16(e[44:], .Little, 1)
	endian.put_u16(e[46:], .Little, 40)
	endian.put_u16(e[48:], .Little, 3)
	endian.put_u16(e[50:], .Little, 2) // .shstrtab
	ph := e[52:]
	endian.put_u32(ph[0:], .Little, 1) // PT_LOAD
	endian.put_u32(ph[4:], .Little, CODE)
	endian.put_u32(ph[8:], .Little, x.text)
	endian.put_u32(ph[12:], .Little, x.text)
	endian.put_u32(ph[16:], .Little, SEGMENT_SIZE)
	endian.put_u32(ph[20:], .Little, SEGMENT_SIZE)
	endian.put_u32(ph[24:], .Little, 5) // read, execute
	endian.put_u32(ph[28:], .Little, 16)
	copy(e[0x80:], SHSTRTAB)
	text := e[SH + 40:]
	endian.put_u32(text[0:], .Little, 1) // ".text"
	endian.put_u32(text[4:], .Little, 1) // PROGBITS
	endian.put_u32(text[8:], .Little, 6) // alloc, execute
	endian.put_u32(text[12:], .Little, x.text)
	endian.put_u32(text[16:], .Little, CODE)
	endian.put_u32(text[20:], .Little, ELF_DATA)
	endian.put_u32(text[32:], .Little, 4)
	strtab := e[SH + 80:]
	endian.put_u32(strtab[0:], .Little, 7) // ".shstrtab"
	endian.put_u32(strtab[4:], .Little, 3) // STRTAB
	endian.put_u32(strtab[16:], .Little, 0x80)
	endian.put_u32(strtab[20:], .Little, len(SHSTRTAB))
	endian.put_u32(e[CODE:], .Little, LOOP)
	for w, k in x.code {
		endian.put_u32(e[CODE + 4 * k:], .Little, w)
	}
	copy(e[CODE + ELF_DATA:], x.data)
	return e
}

@(private = "file")
PS2_CNF :: "BOOT2 = cdrom0:\\DATA\\SLUS_123.45;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n"

// A PS2 disc with SYSTEM.CNF naming DATA/SLUS_123.45, the ELF of code.
@(private = "file")
ps2_disc :: proc(code: ..u32) -> []u8 {
	return discimg.make_iso(PS2_CNF, sub_name = "SLUS_123.45;1", sub = string(elf(..code)))
}

// A PS2 disc booting boot, with DATA/SECOND.ELF second when it has code.
@(private = "file")
ps2_exec_disc :: proc(boot: Elf, second: Elf = {}) -> []u8 {
	sub2 := len(second.code) > 0 ? string(elf_at(second)) : ""
	return discimg.make_iso(
		PS2_CNF,
		sub_name = "SLUS_123.45;1",
		sub = string(elf_at(boot)),
		sub2_name = sub2 != "" ? "SECOND.ELF;1" : "",
		sub2 = sub2,
	)
}

// LoadExecPS2(name, 0, 0) after a 1 in the word at 0x00300000. SECOND.ELF
// loads over the boot text and starts at 0x00100040, which differs from the
// recompiled code; through SetupThread it checks argc 1 (the file), and the
// word cleared, then loops. Any check failing, or LoadExecPS2 returning, runs
// an instruction the EE lacks.
@(private = "file")
ps2_loadexec_disc :: proc(name := "cdrom0:\\DATA\\SECOND.ELF;1") -> []u8 {
	path := la(A0, 0x00100000 + ELF_DATA)
	boot := [?]u32 {
		lui(T0, 0x0030), li(T1, 1), sw(T1, 0, T0), // 0
		path[0], path[1], li(A1, 0), li(A2, 0), li(V1, 6), SYSCALL, // 3
		EE_BAD, // 9
	}
	second := [?]u32 {
		lui(A3, 0x0020), li(A1, 0xffff), li(A2, 0), li(A0, 0), li(V1, 0x3c), SYSCALL, // 0: SetupThread(0, -1, 0, args)
		lw(T0, 0, A3), li(T1, 1), bne(T0, T1, 7), NOP, // 6
		lui(T2, 0x0030), lw(T2, 0, T2), bne(T2, 0, 3), NOP, // 10
		LOOP, NOP, // 14
		EE_BAD, // 16
	}
	return ps2_exec_disc(
		{text = 0x00100000, code = boot[:], data = strings.concatenate({name, "\x00"}, context.temp_allocator)},
		{text = 0x00100040, code = second[:]},
	)
}

// The first run sets the word at 0x00200000, changes a word of its own text
// inside the recompiled range and ExecPS2s into itself; the second, now
// interpreted, finds the word set, calls the function at the range's end and
// loops.
@(private = "file")
ps2_execps2_disc :: proc() -> []u8 {
	code := [?]u32 {
		lui(T0, 0x0020), lw(T1, 0, T0), bne(T1, 0, 9), li(T1, 1), // 0
		sw(T1, 0, T0), lui(T2, 0x0010), sw(T1, 0x40, T2), // 4: the word at 16
		lui(A0, 0x0010), li(A2, 0), li(V1, 7), SYSCALL, // 7: ExecPS2(0x00100000, gp, 0)
		EE_BAD, // 11
		jal(0x00100048), NOP, LOOP, NOP, // 12
		NOP, NOP, JR_RA, NOP, // 16
	}
	return ps2_exec_disc({text = 0x00100000, code = code[:]})
}

// A disc with PSX.EXE in the root, where make_iso puts SYSTEM.CNF, and no
// SYSTEM.CNF; the file runs on over the sectors after.
@(private = "file")
exe_disc :: proc() -> []u8 {
	e := exe()
	img := discimg.make_iso(string(e), cnf_name = "PSX.EXE;1")
	copy(img[22 * disc.DATA:], e)
	return img
}

@(private = "file")
test_native :: proc(name: string, img: []u8) -> (path, dir: string) {
	path = write(name, img)
	dir = disc_dir(name, path)
	if dir == "" {
		return
	}
	blob := core.disc_path(dir, .Native, context.temp_allocator)
	stale := strings.concatenate({blob, ".convert"}, context.temp_allocator)
	if os.write_entire_file(stale, "not a blob") != nil {
		check(name, false, "cannot write the stale temporary file")
	}
	errs := run(name, path) or_else ""
	check(name, strings.contains(errs, "converting"), "no progress from the converter")
	check(name, !strings.contains(errs, "no native code"), "no native code")
	b, _ := os.read_entire_file(blob, context.temp_allocator)
	check(name, core.blob_valid(b), "no blob")
	check(name, os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "no key")
	check(name, !os.exists(stale), "temporary file left")
	check(name, os.is_dir(core.disc_path(dir, .Cards, context.temp_allocator)), "no cards directory")
	errs = run(name, path) or_else ""
	check(name, !strings.contains(errs, "converting") && !strings.contains(errs, "no native code"), "stored blob not used")
	return
}

// A blob header of this format and host arch whose code (64 bytes) is
// missing, stored for this build.
@(private = "file")
test_bad_blob :: proc(path, dir: string) {
	if dir == "" {
		return
	}
	b: [core.NATIVE_HEADER]u8
	endian.put_u32(b[0:], .Little, core.NATIVE_MAGIC)
	endian.put_u32(b[4:], .Little, core.NATIVE_VERSION)
	endian.put_u32(b[8:], .Little, core.NATIVE_ARCH)
	// The header ends with the code's size and where its import slots start.
	endian.put_u32(b[core.NATIVE_HEADER - 8:], .Little, 64)
	endian.put_u32(b[core.NATIVE_HEADER - 4:], .Little, 64)
	if !core.blob_valid(b[:]) || !core.blob_store(dir, b[:]) || !core.blob_cached(dir) {
		check("bad_blob", false, "cannot store the blob")
		return
	}
	errs := run("bad_blob", path, 1) or_else ""
	check("bad_blob", strings.contains(errs, "play: the stored native code would not load; it is converted again next run"), "no load failure")
	check("bad_blob", !strings.contains(errs, "converting"), "converted")
	check("bad_blob", !os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "key left")
}

@(private = "file")
test_interpreted :: proc() {
	path := write("interpreted", cnf_disc("TCB = 4\n"))
	dir := disc_dir("interpreted", path)
	if dir == "" {
		return
	}
	// The converter writes its output to the temporary file's path.
	stale := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	in_way, _ := filepath.join({stale, "in the way"}, context.temp_allocator)
	if os.make_directory(stale) != nil || os.write_entire_file(in_way, "") != nil {
		check("interpreted", false, "cannot block the converter")
		return
	}
	errs := run("interpreted", path) or_else ""
	check("interpreted", strings.contains(errs, "play: no native code (the conversion failed"), "no conversion failure")
	check("interpreted", strings.contains(errs, "psx: no native code, interpreting everything"), "not interpreted")
	check("interpreted", !os.exists(core.disc_path(dir, .Native, context.temp_allocator)), "a blob")
	check("interpreted", !os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "a key")
}

@(private = "file")
write :: proc(name: string, data: []u8) -> string {
	path, _ := filepath.join({tmp, strings.concatenate({name, ".iso"}, context.temp_allocator)}, context.temp_allocator)
	if os.write_entire_file(path, data) != nil {
		check(name, false, fmt.tprintf("cannot write %s", path))
	}
	return path
}

// The disc's directory under DATA, created; "" on a failure.
@(private = "file")
disc_dir :: proc(name, path: string) -> string {
	d, ok := disc.open(path, context.temp_allocator)
	if !ok {
		check(name, false, "the image does not open")
		return ""
	}
	defer disc.close(&d)
	id, has_id := disc.id(&d, context.temp_allocator)
	dir, has_dir := core.disc_dir(id, context.temp_allocator)
	check(name, has_id && has_dir, "no disc directory")
	return dir if has_id && has_dir else ""
}

// Run play on the image and check it ends with status, at FRAMES for 0; its
// stderr.
@(private = "file")
run :: proc(name, path: string, status := 0) -> (errs: string, ok: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	state: os.Process_State
	out, e: []u8
	if err == nil {
		state, out, e, err = os.process_exec({command = {self, path}}, context.temp_allocator)
	}
	if err != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", err))
		return
	}
	errs = string(e)
	frames := strings.contains(errs, fmt.tprintf("frames: %d reached", FRAMES))
	if !state.exited || state.exit_code != status || frames != (status == 0) {
		check(name, false, fmt.tprintf("status %d, stdout:\n%s\nstderr:\n%s", state.exit_code, out, errs))
		return errs, false
	}
	return errs, true
}

// play --compat on a directory, then twice on its looping disc.
@(private = "file")
test_compat :: proc() {
	name := "compat"
	dir, _ := filepath.join({tmp, "compat"}, context.temp_allocator)
	if os.make_directory(dir) != nil {
		check(name, false, "cannot make the disc directory")
		return
	}
	Fixture :: struct {
		file:   string,
		img:    []u8,
		system: string,
		result: string,
		status: string,
		unimpl: string,
		entry:  string, // in the row's entries, with interp_insns > 0
		log:    string, // in compat.log
	}
	fixtures := [?]Fixture {
		{"loop.iso", cnf_disc(), "ps1", "ok", "0", "", "", ""},
		// li t1, 0xff; jal 0xa0; nop; b .; nop: BIOS A(ffh), then loop.
		{"stub.iso", cnf_disc("", 0x240900ff, 0x0c000028, 0, 0x1000ffff, 0), "ps1", "ok", "0", "BIOS A(ffh)=1", "", ""},
		// Opcode 0x3f is reserved.
		{"fatal.iso", cnf_disc("", 0xfc000000), "ps1", "fatal", "1", "", "", ""},
		{"ps2_loop.iso", ps2_disc(), "ps2", "ok", "0", "", "", ""},
		// li v1, 1; syscall; b .; nop: ResetEE, which only the retail ROM
		// has (checked below), then loop.
		{"ps2_stub.iso", ps2_disc(0x24030001, 0x0000000c, 0x1000ffff, 0), "ps2", "ok", "0", "syscall 1=1", "", ""},
		// Opcode 0x3b is not an EE instruction.
		{"ps2_fatal.iso", ps2_disc(0xec000000), "ps2", "fatal", "1", "", "", ""},
		{"loadexec.iso", loadexec_disc(), "ps1", "ok", "0", "", "80010100:", ""},
		{"loadexec_missing.iso", loadexec_missing_disc(), "ps1", "ok", "0", "", "", "running the boot executable again"},
		{"load_exec.iso", load_exec_disc(), "ps1", "ok", "0", "", "80020000:", ""},
		{"ps2_loadexec.iso", ps2_loadexec_disc(), "ps2", "ok", "0", "", "00100040:", "kernel: LoadExecPS2"},
		{"ps2_loadexec_missing.iso", ps2_loadexec_disc("cdrom0:\\DATA\\NONE.ELF;1"), "ps2", "fatal", "1", "", "", "LoadExecPS2: no ELF"},
		{"ps2_execps2.iso", ps2_execps2_disc(), "ps2", "ok", "0", "", "00100000:", "differs from the recompiled program; interpreting"},
	}
	// ps2_stub needs a syscall the HLE lacks that stops a run outside
	// COMPAT; one the kernel implements stubs nothing.
	check(name, kernel.ROM_ONLY_SYSCALLS[1] == "ResetEE", "syscall 1 is no longer one only the retail ROM has")
	ids: [len(fixtures)]string
	for f, k in fixtures {
		path, _ := filepath.join({dir, f.file}, context.temp_allocator)
		if os.write_entire_file(path, f.img) != nil {
			check(name, false, fmt.tprintf("cannot write %s", path))
			return
		}
		ids[k] = disc_id(name, path)
	}
	loop, _ := filepath.join({dir, "loop.iso"}, context.temp_allocator)
	junk, _ := filepath.join({dir, "notadisc.bin"}, context.temp_allocator)
	if os.write_entire_file(junk, make([]u8, 64 * 1024, context.temp_allocator)) != nil {
		check(name, false, "cannot write the file that is not a disc")
		return
	}

	out, errs, ok := run_compat(name, {dir, fmt.tprint(FRAMES)})
	rows := compat_rows(name)
	check(name, ok, fmt.tprintf("status, stdout:\n%s\nstderr:\n%s", out, errs))
	check(name, strings.count(out, "\n") == len(fixtures), fmt.tprintf("stdout:\n%s", out))
	check(name, len(rows) == len(fixtures), fmt.tprintf("%d rows, want %d", len(rows), len(fixtures)))
	first_when: string
	for f, k in fixtures {
		row, found := compat_row(rows, ids[k])
		if !found {
			check(name, false, fmt.tprintf("no row for %s", f.file))
			continue
		}
		what := fmt.tprintf("%s: %v", f.file, row)
		check(name, row[.Result] == f.result && row[.Status] == f.status, what)
		check(name, row[.Unimplemented] == f.unimpl, what)
		check(name, row[.System] == f.system && row[.Frames_Wanted] == fmt.tprint(FRAMES), what)
		check(name, row[.Vmode] == (f.system == "ps2" ? "NTSC" : ""), what)
		check(name, row[.Native] == "yes" && row[.Build] == "test", what)
		if f.entry != "" {
			check(name, strings.contains(row[.Entries], f.entry) && row[.Interp_Insns] != "0", what)
		}
		if f.result == "ok" {
			check(name, row[.Frames] == fmt.tprint(FRAMES), what)
		} else {
			check(name, row[.Fatal] != "", what)
		}
		if ddir, has := core.disc_dir(ids[k], context.temp_allocator); has {
			log, err := os.read_entire_file(core.disc_path(ddir, .Compat_Log, context.temp_allocator), context.temp_allocator)
			check(name, err == nil && len(log) > 0, fmt.tprintf("%s: the child's output is not in compat.log (%v)", f.file, err))
			check(name, strings.contains(string(log), f.log), fmt.tprintf("%s: %q not in compat.log", f.file, f.log))
		}
		if k == 0 {
			first_when = row[.When]
		}
	}

	os.set_env(core.env_name("COMPAT_WAIT"), "2")
	out, errs, ok = run_compat(name, {loop, "1000000000"})
	os.unset_env(core.env_name("COMPAT_WAIT"))
	rows = compat_rows(name)
	check(name, ok && len(rows) == len(fixtures), fmt.tprintf("hang run: %d rows, stdout:\n%s\nstderr:\n%s", len(rows), out, errs))
	if row, found := compat_row(rows, ids[0]); found {
		check(name, row[.Result] == "hang" && row[.Status] == "", fmt.tprintf("hang: %v", row))
	} else {
		check(name, false, "hang: no row")
	}

	out, errs, ok = run_compat(name, {loop, fmt.tprint(FRAMES)})
	rows = compat_rows(name)
	check(name, ok && len(rows) == len(fixtures), fmt.tprintf("rerun: %d rows, stdout:\n%s\nstderr:\n%s", len(rows), out, errs))
	if row, found := compat_row(rows, ids[0]); found {
		check(name, row[.Result] == "ok" && row[.When] != first_when, fmt.tprintf("rerun: %v", row))
	} else {
		check(name, false, "rerun: no row")
	}
}

// The disc's id; "" on a failure.
@(private = "file")
disc_id :: proc(name, path: string) -> string {
	d, ok := disc.open(path, context.temp_allocator)
	if !ok {
		check(name, false, fmt.tprintf("%s does not open", path))
		return ""
	}
	defer disc.close(&d)
	id, has_id := disc.id(&d, context.temp_allocator)
	check(name, has_id, fmt.tprintf("%s has no id", path))
	return id
}

// Run play --compat with args: stdout, stderr, and whether it ended with
// status 0.
@(private = "file")
run_compat :: proc(name: string, args: []string) -> (out, errs: string, ok: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", err))
		return
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, self, "--compat")
	append(&command, ..args)
	state: os.Process_State
	o, e: []u8
	state, o, e, err = os.process_exec({command = command[:]}, context.temp_allocator)
	if err != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", err))
		return
	}
	return string(o), string(e), state.exited && state.exit_code == 0
}

// compat.tsv's rows, after checking its header.
@(private = "file")
compat_rows :: proc(name: string) -> []play.Row {
	data, _ := core.data_dir()
	path, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		check(name, false, fmt.tprintf("cannot read %s: %v", path, err))
		return nil
	}
	cols := play.COLUMNS
	rest := string(text)
	header, _ := strings.split_lines_iterator(&rest)
	check(name, header == strings.join(slice.enumerated_array(&cols), "\t", context.temp_allocator), fmt.tprintf("header %q", header))
	rows := make([dynamic]play.Row, context.temp_allocator)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != len(play.Column) {
			check(name, false, fmt.tprintf("row %q", line))
			continue
		}
		row: play.Row
		for &f, c in row {
			f = fields[int(c)]
		}
		append(&rows, row)
	}
	return rows[:]
}

@(private = "file")
compat_row :: proc(rows: []play.Row, id: string) -> (play.Row, bool) {
	for r in rows {
		if r[.Id] == id {
			return r, true
		}
	}
	return {}, false
}

// MIPS encodings for the hand-built executables.
@(private = "file")
V0 :: 2
@(private = "file")
V1 :: 3
@(private = "file")
A0 :: 4
@(private = "file")
A1 :: 5
@(private = "file")
A2 :: 6
@(private = "file")
A3 :: 7
@(private = "file")
T0 :: 8
@(private = "file")
T1 :: 9
@(private = "file")
T2 :: 10
@(private = "file")
S0 :: 16
@(private = "file")
S1 :: 17
@(private = "file")
S2 :: 18
@(private = "file")
GP :: 28
@(private = "file")
SP :: 29
@(private = "file")
NOP :: 0
@(private = "file")
LOOP :: 0x1000ffff // b .
@(private = "file")
RESERVED :: 0xfc000000 // opcode 0x3f
@(private = "file")
JAL_A0 :: 0x0c000028
@(private = "file")
JR_RA :: 0x03e00008
@(private = "file")
SYSCALL :: 0x0000000c
@(private = "file")
EE_BAD :: 0xec000000 // opcode 0x3b, no EE instruction

@(private = "file")
lui :: proc(rt, imm: u32) -> u32 {return 0x3c000000 | rt << 16 | imm}
@(private = "file")
ori :: proc(rt, rs, imm: u32) -> u32 {return 0x34000000 | rs << 21 | rt << 16 | imm}
@(private = "file")
li :: proc(rt, imm: u32) -> u32 {return 0x24000000 | rt << 16 | imm}
@(private = "file")
lw :: proc(rt, off, base: u32) -> u32 {return 0x8c000000 | base << 21 | rt << 16 | off}
@(private = "file")
sw :: proc(rt, off, base: u32) -> u32 {return 0xac000000 | base << 21 | rt << 16 | off}
@(private = "file")
move :: proc(rd, rs: u32) -> u32 {return rs << 21 | rd << 11 | 0x21}
// Branches to the instruction `to` words after the one after the branch.
@(private = "file")
beq :: proc(rs, rt, to: u32) -> u32 {return 0x10000000 | rs << 21 | rt << 16 | to}
@(private = "file")
bne :: proc(rs, rt, to: u32) -> u32 {return 0x14000000 | rs << 21 | rt << 16 | to}
@(private = "file")
jal :: proc(to: u32) -> u32 {return 0x0c000000 | (to >> 2) & 0x3ffffff}
// rt = the 32-bit value.
@(private = "file")
la :: proc(rt, v: u32) -> [2]u32 {return {lui(rt, v >> 16), ori(rt, rt, v & 0xffff)}}
