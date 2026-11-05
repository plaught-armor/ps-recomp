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
// - compat: play --compat on a directory of discs, PS1 and PS2 (one of each
//   that loops, one that makes a BIOS call or an EE syscall the HLE lacks,
//   one that starts on an invalid instruction), and a file that is not a disc
//   gives one compat.tsv row per disc (stalled with no picture, stalled with
//   the call stubbed, fatal) and skips the file, keeping the row of a
//   compat.tsv from before the shown column; a PS1 disc that turns the
//   display on and counts in RAM, and a PS2 one that draws, turns it on and
//   counts, are ok (lit counted on PS2 rows only, 0 on none that is ok); a
//   PS1 one that turns it on and loops is stalled with main RAM unchanged;
//   PS2 ones that turn it on and count with nothing drawn, or sleep their
//   only thread, are stalled with nothing drawn (the idle_share of every PS2
//   row past 0.95 only for the one that sleeps). Each disc whose display
//   was on, and no fatal one, leaves a thumb.ppm (lit for the PS2 one that
//   draws). The looping PS1 disc run
//   again to FRAMES is stalled, in place, and leaves vblank 1 in
//   compat.progress. Its child replaced by a fake one (PLAY_TEST_CHILD,
//   fake_child) under a 1 s COMPAT_WAIT: one whose count stops is a hang, as
//   is one that writes none within the 5 s boot window; one that starts
//   after 2 s and keeps counting for 4.8 s is not. Three PS1 discs load a
//   second executable no native code covers: LoadExec of it, over the boot
//   executable, checks its argc, stack and BSS; LoadExec of a missing file
//   runs the boot executable again; Load and Exec of it return to the boot
//   executable with its registers. The second executable's entry is in the
//   row's entries. Three PS2 discs switch programs: LoadExecPS2 of an ELF
//   over the boot text, which runs interpreted and checks its argc and the
//   memory and scratchpad cleared; LoadExecPS2 of a missing file, fatal; and
//   a program that changes a word of its recompiled text and ExecPS2s into
//   itself, which turns the function table off.
// - compat_learned: play --compat on a PS1 disc with LEARN records (one of
//   them twice) compiles its learned code before the child starts: a fake
//   child finds the blob and key stored. Then, the blob removed, the real
//   child's compat.log has no compile but loads the blob the parent
//   compiled, and neither rewrites the records the first run compacted. A
//   compile that fails in the parent (a directory in the way of its output)
//   is not tried again in the child, which runs without learned code. A
//   compile that hangs (a fake one) is stopped after its window, 5 s under
//   a 1 s COMPAT_WAIT, and the child runs without learned code.
// - compat_cards: play --compat on a PS1 disc whose cards hold a card of the
//   wrong size, and whose compat-cards hold a stale file, runs on blank
//   cards by default: the row says fresh, the child finds no card in
//   compat-cards, the stale file is gone and the disc's card is untouched.
//   COMPAT_CARDS=keep runs on the disc's cards (kept, the bad card read);
//   any other value is an error with no run.
// - quit: a PS2 disc that draws and a PS1 one that fills VRAM run in a
//   window (SDL's dummy video driver, software drawing) until a picture is
//   written (SHOT, DUMP), then get SIGTERM, which SDL turns into the quit
//   event a closed window sends: play exits with status 0 and the thumb.ppm
//   it writes is the last picture shrunk, the one last shown (test_quit;
//   not on Windows, which has no SIGTERM).
// - orphan: play --compat whose parent is stopped (SIGTERM, then SIGKILL;
//   on Windows terminated) while its child, a fake one that watches its
//   parent as a compat child does, runs: the child ends within
//   ORPHAN_WITHIN (test_orphan).
// - library: play.library_add, library_load and library_remove
//   (test_library).
// - export: play --export of a PS1 disc with saved settings, a PRESS script,
//   a thumb.ppm and a compat.tsv row, and of a PS2 disc with none, under a
//   DATA of their own (test_export).
// - press: PRESS scripts as input_poll plays them (test_press): one of
//   buttons only holds them for exactly their frames with both sticks
//   centred; a held LRight is full deflection right on the left stick for
//   exactly its frames and centred outside them; LUp&LRight, and LUp and
//   RDown in entries that overlap, push both axes at once; a name that is
//   neither a button nor a direction is a bad entry.
// - launcher: the launcher's steps, settings, picture, dropped files and
//   runs (test_launcher), a value cut to its width on a rune boundary
//   (test_launcher_fit), and play.log's plain lines (test_log_strip).
// It is all removed at the end whether the test passes or fails. Build it
// with -define:COMMIT=test: a dev build never uses a stored blob.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
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

// Set, a disc run (play <image>) is fake_child in that mode instead.
@(private = "file")
PLAY_TEST_CHILD :: "PS_PLAY_TEST_CHILD"

// A compat child that writes vblank counts to COMPAT_PROGRESS as a game
// would, then ends with no compat line. "stuck": vblank 1, then nothing for
// 60 s; "boot": nothing for 60 s; "slow": vblanks 1 to 12, 0.4 s apart,
// after 2 s; "learned": none, its last line whether the disc's learned blob
// and key were stored before it started; "hang": as "learned", and a learned
// compile (play --learned) is fake_compile; "orphan": watches its parent as
// a compat child does (play.parent_watch), writes its pid to ORPHAN_PID in
// the disc directory and vblank 1, then sleeps 60 s.
@(private = "file")
fake_child :: proc(mode: string) -> ! {
	f, err := os.open(core.env("COMPAT_PROGRESS"), {.Write})
	if err != nil {
		fmt.eprintln("fake child: no COMPAT_PROGRESS:", err)
		os.exit(1)
	}
	put :: proc(f: ^os.File, n: u64) {
		b: [8]u8
		endian.unchecked_put_u64le(b[:], n)
		_, _ = os.write_at(f, b[:], 0)
	}
	switch mode {
	case "stuck":
		put(f, 1)
		time.sleep(60 * time.Second)
	case "boot":
		time.sleep(60 * time.Second)
	case "slow":
		time.sleep(2 * time.Second)
		for n in u64(1) ..= 12 {
			put(f, n)
			time.sleep(400 * time.Millisecond)
		}
		fmt.eprintln("fake child: done")
	case "orphan":
		play.parent_watch()
		pid_path, _ := filepath.join({filepath.dir(core.env("COMPAT_PROGRESS")), ORPHAN_PID}, context.temp_allocator)
		_ = os.write_entire_file(pid_path, fmt.tprint(os.get_pid()))
		put(f, 1)
		time.sleep(60 * time.Second)
	case "learned", "hang":
		dir := filepath.dir(core.env("COMPAT_PROGRESS"))
		blob, _ := os.read_entire_file(core.disc_path(dir, .Learned, context.temp_allocator), context.temp_allocator)
		stored := core.blob_valid(blob) && os.exists(core.disc_path(dir, .Learned_Key, context.temp_allocator))
		fmt.eprintln("fake child: learned blob", "stored" if stored else "missing")
	}
	os.exit(0)
}

// A learned compile that hangs: it writes its pid to HANG_PID in the
// directory of its output, then sleeps 60 s and writes nothing.
@(private = "file")
fake_compile :: proc(out: string) -> ! {
	pid_path, _ := filepath.join({filepath.dir(out), HANG_PID}, context.temp_allocator)
	_ = os.write_entire_file(pid_path, fmt.tprint(os.get_pid()))
	time.sleep(60 * time.Second)
	os.exit(0)
}

// fake_compile's pid file, in the disc directory.
@(private = "file")
HANG_PID :: "hang.pid"

main :: proc() {
	if mode := os.get_env(PLAY_TEST_CHILD, context.temp_allocator); mode != "" && len(os.args) == 2 {
		fake_child(mode)
	}
	if os.get_env(PLAY_TEST_CHILD, context.temp_allocator) == "hang" && len(os.args) == 5 && os.args[1] == "--learned" {
		fake_compile(os.args[4])
	}
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
	test_settings()
	test_compat()
	test_compat_learned()
	test_compat_cards()
	test_quit()
	test_orphan()
	test_line_row()
	test_library()
	test_export()
	test_press()
	test_log_strip()
	test_launcher_fit()
	test_launcher()
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

// lui t0, 0x1f80; lui t1, 0x0300; sw t1, 0x1814(t0): GP1(03000000), the
// display on; then lui t2, 0x8002; 1: lw t3, 0(t2); nop; addiu t3, 1;
// sw t3, 0(t2); b 1b; nop: the word at 0x80020000 counts up.
@(private = "file")
PS1_SHOW := [?]u32{0x3c081f80, 0x3c090300, 0xad091814, 0x3c0a8002, 0x8d4b0000, 0, 0x256b0001, 0xad4b0000, 0x1000fffb, 0}
// The display on as PS1_SHOW turns it on, then b .; nop.
@(private = "file")
PS1_STILL := [?]u32{0x3c081f80, 0x3c090300, 0xad091814, 0x1000ffff, 0}

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

// lui t0, 0x1200; li t1, 1; sd t1, 0(t0): PMODE 1, read circuit 1 on (its
// DISPLAY 0 is 1x1 at frame buffer 0); then the word at 0x00300000 counts up
// as PS1_COUNT's.
@(private = "file")
PS2_DARK := [?]u32{0x3c081200, 0x24090001, 0xfd090000, 0x3c0a0030, 0x8d4b0000, 0, 0x256b0001, 0xad4b0000, 0x1000fffb, 0}
// The display on as PS2_DARK turns it on, then the 7 quadwords of
// PS2_PACKET at text + ELF_DATA stored to the GIF FIFO at 0x10006000 (lq,
// sq in a loop), then the count as PS2_DARK's.
@(private = "file")
PS2_SHOW := [?]u32 {
	0x3c081200, 0x24090001, 0xfd090000, 0x3c0a1000, 0x354a6000, 0x3c0b0010, 0x356b0080, 0x240c0007,
	0x796d0000, 0x256b0010, 0x258cffff, 0x7d4d0000, 0x1580fffb, 0,
	0x3c0a0030, 0x8d4b0000, 0, 0x256b0001, 0xad4b0000, 0x1000fffb, 0,
}
// A GIF packet that writes 4 white pixels at the start of frame buffer 0
// (width 64, 32-bit): an A+D tag of BITBLTBUF, TRXPOS, TRXREG (4x1) and
// TRXDIR (host to local), then an IMAGE tag and the pixels.
@(private = "file")
PS2_PACKET := [7][2]u64 {
	{0x1000000000000004, 0xe},
	{0x0001000000000000, 0x50},
	{0, 0x51},
	{0x0000000100000004, 0x52},
	{0, 0x53},
	{0x0800000000008001, 0},
	{0xffffffffffffffff, 0xffffffffffffffff},
}
// The display on as PS2_DARK turns it on, then li v1, 0x32; syscall; b .;
// nop: SleepThread, and with no thread left to run the kernel idles.
@(private = "file")
PS2_SLEEP := [?]u32{0x3c081200, 0x24090001, 0xfd090000, 0x24030032, 0x0000000c, 0x1000ffff, 0}

// A PS2 disc with SYSTEM.CNF naming DATA/SLUS_123.45, the ELF of code.
@(private = "file")
ps2_disc :: proc(code: ..u32) -> []u8 {
	return discimg.make_iso(PS2_CNF, sub_name = "SLUS_123.45;1", sub = string(elf(..code)))
}

// A PS2 disc that draws PS2_PACKET, turns the display on and counts
// (PS2_SHOW).
@(private = "file")
ps2_show_disc :: proc() -> []u8 {
	return discimg.make_iso(PS2_CNF, sub_name = "SLUS_123.45;1", sub = string(elf_at({text = 0x00100000, code = PS2_SHOW[:], data = string(slice.to_bytes(PS2_PACKET[:]))})))
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

// LoadExecPS2(name, 0, 0) after a 1 in the word at 0x00300000, in the
// scratchpad's last word and in the word at 0x00081ffc. SECOND.ELF loads over
// the boot text and starts at 0x00100040, which differs from the recompiled
// code; through SetupThread it checks argc 1 (the file), the first two words
// cleared and the last kept (below the clear), then loops. Any check
// failing, or LoadExecPS2 returning, runs an instruction the EE lacks.
@(private = "file")
ps2_loadexec_disc :: proc(name := "cdrom0:\\DATA\\SECOND.ELF;1") -> []u8 {
	path := la(A0, 0x00100000 + ELF_DATA)
	boot := [?]u32 {
		lui(T0, 0x0030), li(T1, 1), sw(T1, 0, T0), // 0
		lui(T0, 0x7000), sw(T1, 0x3ffc, T0), // 3
		lui(T0, 0x0008), sw(T1, 0x1ffc, T0), // 5
		path[0], path[1], li(A1, 0), li(A2, 0), li(V1, 6), SYSCALL, // 7
		EE_BAD, // 13
	}
	second := [?]u32 {
		lui(A3, 0x0020), li(A1, 0xffff), li(A2, 0), li(A0, 0), li(V1, 0x3c), SYSCALL, // 0: SetupThread(0, -1, 0, args)
		lw(T0, 0, A3), li(T1, 1), bne(T0, T1, 15), NOP, // 6
		lui(T2, 0x0030), lw(T2, 0, T2), bne(T2, 0, 11), NOP, // 10
		lui(T2, 0x7000), lw(T2, 0x3ffc, T2), bne(T2, 0, 7), NOP, // 14
		lui(T2, 0x0008), lw(T2, 0x1ffc, T2), bne(T2, T1, 3), NOP, // 18
		LOOP, NOP, // 22
		EE_BAD, // 24
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

// Saved settings: none leaves a run as before; the disc's file applies, only
// for names it may set; the environment beats it, it beats the global file.
@(private = "file")
test_settings :: proc() {
	name := "settings"
	// Parse, save and load: unknown, malformed and over-long rows dropped, the
	// first of two rows with one name kept.
	long := strings.repeat("x", core.SETTING_MAX + 1, context.temp_allocator)
	text := strings.concatenate({"NATIVE\t0\r\nDATA\t/nowhere\nSCALE\nGPU\t", long, "\nSW\t1\nSW\t2\n"}, context.temp_allocator)
	s := core.settings_parse(text, context.temp_allocator)
	check(name, s.set == {.Native, .Sw} && s.value[.Native] == "0" && s.value[.Sw] == "1", fmt.tprint("parsed", s))
	file, _ := filepath.join({tmp, "settings_unit.tsv"}, context.temp_allocator)
	ok_save := core.settings_save(file, s)
	saved, _ := os.read_entire_file(file, context.temp_allocator)
	check(name, ok_save && string(saved) == "SW\t1\nNATIVE\t0\n", fmt.tprintf("saved %q", saved))
	back := core.settings_load(file, context.temp_allocator)
	check(name, back.set == s.set && back.value == s.value, "load after save differs")
	check(name, core.settings_save(file, {}) && !os.exists(file), "saving nothing leaves the file")
	check(name, core.settings_load(file, context.temp_allocator).set == {}, "a missing file has settings")

	path := write(name, cnf_disc("TCB = 6\n"))
	dir := disc_dir(name, path)
	global, has_global := core.settings_global_path(context.temp_allocator)
	check(name, has_global, "no global settings path")
	if dir == "" || !has_global {
		return
	}
	interpreted :: "psx: no native code, interpreting everything"
	// No files: converted, then the stored blob runs.
	errs := run(name, path) or_else ""
	check(name, strings.contains(errs, "converting") && !strings.contains(errs, interpreted), "no settings changed the run")
	errs = run(name, path) or_else ""
	check(name, !strings.contains(errs, interpreted), "no settings: not native")
	disc_file := core.disc_path(dir, .Settings, context.temp_allocator)
	put :: proc(name, file, text: string) {
		if os.write_entire_file(file, text) != nil {
			check(name, false, fmt.tprintf("cannot write %s", file))
		}
	}
	// DATA is not a setting the file may set: the run still finds its blob.
	put(name, disc_file, "NATIVE\t0\nDATA\t/nowhere\n")
	errs = run(name, path) or_else ""
	check(name, strings.contains(errs, interpreted), "the disc's NATIVE=0 not applied")
	check(name, !strings.contains(errs, "converting"), "DATA taken from the file")
	os.set_env(core.env_name("NATIVE"), "1")
	errs = run(name, path) or_else ""
	os.unset_env(core.env_name("NATIVE"))
	check(name, !strings.contains(errs, interpreted), "the file beat the environment")
	_ = os.remove(disc_file)
	put(name, global, "NATIVE\t0\n")
	errs = run(name, path) or_else ""
	check(name, strings.contains(errs, interpreted), "the global NATIVE=0 not applied")
	put(name, disc_file, "NATIVE\t1\n")
	errs = run(name, path) or_else ""
	check(name, !strings.contains(errs, interpreted), "the global file beat the disc's")
	// --compat reads neither file: its row is the one the environment alone
	// gives, whatever the player saved.
	_ = os.remove(disc_file)
	_ = os.remove(global)
	id := disc_id(name, path)
	run_compat(name, {path, fmt.tprint(FRAMES)})
	bare, has_bare := compat_row(compat_rows(name), id)
	put(name, disc_file, "NATIVE\t0\n")
	put(name, global, "NATIVE\t0\n")
	run_compat(name, {path, fmt.tprint(FRAMES)})
	saved_row, has_saved := compat_row(compat_rows(name), id)
	check(name, has_bare && has_saved, "no compat row for the disc")
	for c in play.Column {
		if c != .Wall_S && c != .User_S && c != .When {
			check(name, bare[c] == saved_row[c], fmt.tprintf("compat %v: %q with no settings, %q with them", c, bare[c], saved_row[c]))
		}
	}
	log, _ := os.read_entire_file(core.disc_path(dir, .Compat_Log, context.temp_allocator), context.temp_allocator)
	check(name, len(log) > 0 && !strings.contains(string(log), interpreted), "--compat applied the saved NATIVE=0")
	_ = os.remove(disc_file)
	_ = os.remove(global)
	data, _ := core.data_dir(context.temp_allocator)
	tsv, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	_ = os.remove(tsv)
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

// img with label as its volume identifier, space padded.
@(private = "file")
labeled :: proc(img: []u8, label: string) -> []u8 {
	field := img[16 * disc.DATA + 40:][:32]
	slice.fill(field, ' ')
	copy(field, label)
	return img
}

// The disc id of the image at path; "" when it has none.
@(private = "file")
id_of :: proc(path: string) -> string {
	d, ok := disc.open(path, context.temp_allocator)
	if !ok {
		return ""
	}
	defer disc.close(&d)
	return disc.id(&d, context.temp_allocator) or_else ""
}

// play --export under a DATA of its own. A PS1 disc whose directory has
// settings.tsv, press.txt, thumb.ppm, a compat.tsv row (a fatal message with
// a '|' in it) and a native blob, learn records and a memory card exports to
// exactly README.md (ps-recomp pinned to the player's commit), .gitignore
// (port/src/rec left out), local.tsv, settings.tsv and press.txt (the same
// bytes), docs/notes.md (the row, the '|' escaped), shots/thumb.png (the
// picture's size) and the port: setup.sh (whose rec mode stops before
// port/build.sh), tools/recomp.tsv (r3000, no
// disc), port/build.sh, port/src/local.odin, port/src/main.odin (psx.run)
// and tests/run.sh; a PS2 disc with none of them to the same but
// settings.tsv, press.txt and the thumb, docs/notes.md saying no run yet,
// recomp.tsv r5900 and main.odin ps2.boot (with the IOP and EE learned
// blobs). No file holds a
// 16-byte run of the executable, nor of the blob, records or card. The
// .gitignore lists every file but local.tsv. An export into the directory
// again, or into one holding another file, is refused and changes nothing;
// one into an empty directory is written there, its local.tsv naming the
// VU1 capture the PS2 disc's directory holds by then (and no VU0 one).
@(private = "file")
test_export :: proc() {
	name := "export"
	data, _ := filepath.join({tmp, "export_data"}, context.temp_allocator)
	old_data := core.env("DATA")
	os.set_env(core.env_name("DATA"), data)
	defer os.set_env(core.env_name("DATA"), old_data)
	self, _ := os.get_executable_path(context.temp_allocator)
	export :: proc(self, image, out: string) -> int {
		return play.run({self, "--export", image, out})
	}
	// What no exported file may hold: each 16-byte run of these, but for
	// runs of one byte value.
	Run :: [16]u8
	forbidden := make(map[Run]bool, context.temp_allocator)
	forbid :: proc(forbidden: ^map[Run]bool, b: []u8) {
		for i in 0 ..< max(len(b) - 15, 0) {
			r: Run
			copy(r[:], b[i:])
			if slice.all_of(r[:], r[0]) {continue}
			forbidden[r] = true
		}
	}
	// The relative paths of the files under dir, sorted.
	walk :: proc(dir, rel: string, files: ^[dynamic]string) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {
			sub := e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
			if e.type == .Directory {
				walk(e.fullpath, sub, files)
			} else {
				append(files, strings.clone(sub, context.temp_allocator))
			}
		}
	}
	listed :: proc(out: string) -> []string {
		files := make([dynamic]string, context.temp_allocator)
		walk(out, "", &files)
		slice.sort(files[:])
		return files[:]
	}
	read :: proc(out, file: string) -> string {
		path, _ := filepath.join({out, file}, context.temp_allocator)
		b, _ := os.read_entire_file(path, context.temp_allocator)
		return string(b)
	}
	clean :: proc(name, out: string, files: []string, forbidden: map[Run]bool) {
		ignore := read(out, ".gitignore")
		for f in files {
			b := transmute([]u8)read(out, f)
			for i in 0 ..< max(len(b) - 15, 0) {
				r: Run
				copy(r[:], b[i:])
				if r in forbidden {
					check(name, false, fmt.tprintf("%s holds disc or player bytes at %d", f, i))
					break
				}
			}
			top, _, _ := strings.partition(f, "/")
			line := fmt.tprintf("!/%s%s\n", top, "/" if top != f else "")
			check(name, strings.contains(ignore, line) == (f != "local.tsv"), fmt.tprintf("%s tracked wrong in .gitignore", f))
		}
	}
	put :: proc(name, dir, file: string, b: []u8) {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(path))
		if os.write_entire_file(path, b) != nil {
			check(name, false, fmt.tprintf("cannot write %s", path))
		}
	}

	ps1 := write("export_ps1", cnf_disc())
	ps1_dir := disc_dir(name, ps1)
	ps2 := write("export_ps2", ps2_disc())
	ps2_dir := disc_dir(name, ps2)
	if ps1_dir == "" || ps2_dir == "" {
		return
	}
	id := id_of(ps1)
	forbid(&forbidden, exe())
	forbid(&forbidden, elf())
	settings :: "GPU\tsw\n"
	press :: "Start@100\n"
	put(name, ps1_dir, "settings.tsv", transmute([]u8)string(settings))
	put(name, ps1_dir, "press.txt", transmute([]u8)string(press))
	rgb := [?]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18}
	put(name, ps1_dir, "thumb.ppm", core.ppm_encode(3, 2, rgb[:]))
	tsv, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	put(name, data, "compat.tsv", transmute([]u8)fmt.tprintf("id\tresult\tfatal\n%s\tfatal\tbad|call\n", id))
	player := [?]string{core.DISC_FILES[.Native], "learn/psx.bin", "cards/slot1.mcd"}
	for f, i in player {
		b := transmute([]u8)fmt.tprintf("player file %d not exported", i)
		put(name, ps1_dir, f, b)
		forbid(&forbidden, b)
	}

	out1, _ := filepath.join({tmp, "export_ps1_repo"}, context.temp_allocator)
	check(name, export(self, ps1, out1) == 0, "the PS1 export failed")
	files := listed(out1)
	port := []string{"port/build.sh", "port/src/local.odin", "port/src/main.odin"}
	tools := []string{"tests/run.sh", "tools/recomp.tsv"}
	want := slice.concatenate([][]string{{".gitignore", "README.md", "docs/notes.md", "local.tsv"}, port, {"press.txt", "settings.tsv", "setup.sh", "shots/thumb.png"}, tools}, context.temp_allocator)
	ps2_want := slice.concatenate([][]string{{".gitignore", "README.md", "docs/notes.md", "local.tsv"}, port, {"setup.sh"}, tools}, context.temp_allocator)
	check(name, slice.equal(files, want), fmt.tprint("PS1 files:", files))
	check(name, read(out1, "settings.tsv") == settings && read(out1, "press.txt") == press, "settings or press not copied")
	png := read(out1, "shots/thumb.png")
	check(name, len(png) > 24 && endian.unchecked_get_u32be(transmute([]u8)png[16:]) == 3 && endian.unchecked_get_u32be(transmute([]u8)png[20:]) == 2, "thumb.png not 3x2")
	notes := read(out1, "docs/notes.md")
	check(name, strings.contains(notes, "| result | fatal |") && strings.contains(notes, "| fatal | bad\\|call |"), fmt.tprintf("notes:\n%s", notes))
	local := read(out1, "local.tsv")
	check(name, strings.contains(local, fmt.tprintf("\nid\t%s\n", id)) && strings.contains(local, "\ncommit\ttest\n") && strings.contains(local, "\nsystem\tps1\n"), fmt.tprintf("local.tsv:\n%s", local))
	recomp := read(out1, "tools/recomp.tsv")
	check(name, strings.contains(recomp, "\nbackend\tr3000\n") && strings.contains(recomp, "\nout\tport/src/rec\n") && !strings.contains(recomp, "\ndisc\t"), fmt.tprintf("PS1 recomp.tsv:\n%s", recomp))
	check(name, strings.contains(read(out1, "port/src/main.odin"), "psx.run(b)"), "PS1 main.odin does not run psx")
	setup := read(out1, "setup.sh")
	check(name, strings.contains(setup, "if [ \"$1\" = rec ]; then\n\tdu -sh port/src/rec\n\texit 0\nfi\nsh port/build.sh\n"), fmt.tprintf("setup.sh has no rec mode before the build:\n%s", setup))
	check(name, strings.contains(setup, "\t\tif [ -n \"$cap\" ] && [ -f \"$cap\" ]; then\n\t\t\tprintf '%s_capture\t%s\n' \"$vu\" \"$cap\"\n\t\tfi\n\tdone\n} >build/recomp.tsv\n"), fmt.tprintf("setup.sh does not add the VU captures:\n%s", setup))
	check(name, !strings.contains(local, "_capture\t"), fmt.tprintf("PS1 local.tsv names a VU capture:\n%s", local))
	check(name, strings.contains(read(out1, ".gitignore"), "\n/port/src/rec/\n"), ".gitignore tracks port/src/rec")
	check(name, strings.contains(read(out1, "README.md"), "git -C ps-recomp checkout test\n"), "README does not pin ps-recomp to the player's commit")
	clean(name, out1, files, forbidden)

	out2, _ := filepath.join({tmp, "export_ps2_repo"}, context.temp_allocator)
	check(name, export(self, ps2, out2) == 0, "the PS2 export failed")
	files = listed(out2)
	check(name, slice.equal(files, ps2_want), fmt.tprint("PS2 files:", files))
	check(name, strings.contains(read(out2, "tools/recomp.tsv"), "\nbackend\tr5900\n"), "PS2 recomp.tsv not r5900")
	check(name, !strings.contains(read(out2, "local.tsv"), "_capture\t"), "PS2 local.tsv names a VU capture the player has not written")
	ps2_main := read(out2, "port/src/main.odin")
	check(name, strings.contains(ps2_main, "ps2.boot("), "PS2 main.odin does not boot ps2")
	check(name, strings.contains(ps2_main, ".Learned_Iop_Key)") && strings.contains(ps2_main, ".Learned_Ee_Key)"), "PS2 main.odin does not pass both learned blobs")
	check(name, strings.contains(read(out2, "docs/notes.md"), "No compatibility run yet"), "PS2 notes name a run")
	readme := read(out2, "README.md")
	check(name, strings.contains(readme, "PS2 disc") && !strings.contains(readme, "- `settings.tsv`"), fmt.tprintf("PS2 README:\n%s", readme))
	clean(name, out2, files, forbidden)

	// Refused: the directory again, and one holding another file.
	before := read(out1, "README.md")
	check(name, export(self, ps1, out1) == 1, "an export over an export")
	check(name, read(out1, "README.md") == before && slice.equal(listed(out1), want), "a refused export changed the directory")
	other, _ := filepath.join({tmp, "export_other"}, context.temp_allocator)
	put(name, other, "mine.txt", transmute([]u8)string("mine"))
	check(name, export(self, ps1, other) == 1, "an export into a directory with a file")
	check(name, slice.equal(listed(other), []string{"mine.txt"}) && read(other, "mine.txt") == "mine", "a refused export changed the other directory")
	check(name, !os.exists(strings.concatenate({other, ".ps-recomp-export"}, context.temp_allocator)), "a refused export left its directory")
	// An empty directory is exported into; the VU1 capture the PS2 disc's
	// directory holds now is named in local.tsv, never copied.
	vu1 := core.disc_path(ps2_dir, .Vu1_Capture, context.temp_allocator)
	put(name, ps2_dir, core.DISC_FILES[.Vu1_Capture], transmute([]u8)string("vu1 capture not exported"))
	forbid(&forbidden, transmute([]u8)string("vu1 capture not exported"))
	empty, _ := filepath.join({tmp, "export_empty"}, context.temp_allocator)
	_ = os.make_directory_all(empty)
	check(name, export(self, ps2, empty) == 0, "an export into an empty directory failed")
	got := listed(empty)
	check(name, slice.equal(got, ps2_want), fmt.tprint("files in the empty directory:", got))
	ps2_local := read(empty, "local.tsv")
	check(name, strings.contains(ps2_local, fmt.tprintf("\nvu1_capture\t%s\n", vu1)) && !strings.contains(ps2_local, "vu0_capture"), fmt.tprintf("PS2 local.tsv with a VU1 capture:\n%s", ps2_local))
	clean(name, empty, got, forbidden)
	_ = os.remove(tsv)
}

// The library under a DATA of its own: a directory of a PS1 disc, a PS2 one
// and a file that is not a disc adds the two, each with its id, serial,
// system and volume label (the title too), and its compat.tsv row found by
// header name; adding again adds no row. A disc.tsv whose path, size and
// mtime match is used as it is, the title kept; an image grown by a sector
// is scanned again, its title kept; one replaced by another disc is that
// disc's now in library.tsv; one gone is missing with what was known of it,
// until it is removed. All of it goes through a symlink to the discs'
// directory (where one can be made), and library.tsv holds the resolved
// paths.
@(private = "file")
test_library :: proc() {
	name := "library"
	data, _ := filepath.join({tmp, "library_data"}, context.temp_allocator)
	old_data := core.env("DATA")
	os.set_env(core.env_name("DATA"), data)
	defer os.set_env(core.env_name("DATA"), old_data)
	// The discs are added, changed and removed through a symlink to their
	// directory; the library keeps the resolved path. Windows makes a
	// symlink only in Developer Mode or as an administrator: without one
	// the discs are used where they are.
	real_dir, _ := filepath.join({tmp, "library_real"}, context.temp_allocator)
	dir, _ := filepath.join({tmp, "library"}, context.temp_allocator)
	if os.make_directory(real_dir) != nil {
		check(name, false, "cannot make the library directory")
		return
	}
	linked := os.symlink(real_dir, dir) == nil
	if !linked {
		when ODIN_OS == .Windows {
			fmt.println("skip play library: no symlink on this system, the discs used where they are")
			dir = real_dir
		} else {
			check(name, false, "cannot make the library directory's symlink")
			return
		}
	}
	resolved, rerr := filepath.abs(real_dir, context.temp_allocator)
	check(name, rerr == nil, "cannot resolve the library directory")
	in_real :: proc(dir, file: string) -> string {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		return path
	}
	a_real, b_real := in_real(resolved, "a.iso"), in_real(resolved, "b.iso")
	check(name, !linked || a_real != in_real(dir, "a.iso"), "the symlink spelling is the resolved one")
	put :: proc(dir, file: string, img: []u8) -> string {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		if os.write_entire_file(path, img) != nil {
			check("library", false, fmt.tprintf("cannot write %s", path))
		}
		return path
	}
	a := put(dir, "a.iso", labeled(cnf_disc(), "DISC A"))
	b := put(dir, "b.iso", labeled(ps2_disc(), " DISC\tB "))
	_ = put(dir, "c.iso", transmute([]u8)string("not a disc"))
	a_id, b_id := id_of(a), id_of(b)
	check(name, a_id != "" && b_id != "" && a_id != b_id, "no disc ids")

	// Each column by its name, in another order and one missing.
	compat, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	_ = os.make_directory_all(data)
	tsv := fmt.tprintf("result\tid\tfatal\nok\t%s\t\nfatal\tother\tx\n", a_id)
	if os.write_entire_file(compat, transmute([]u8)tsv) != nil {
		check(name, false, "cannot write compat.tsv")
	}

	added, _, ok := play.library_add(dir)
	check(name, ok && added == 2, fmt.tprintf("added %d, %v", added, ok))
	added, _, ok = play.library_add(a)
	check(name, ok && added == 1, "adding a again")
	discs, loaded := play.library_load(context.temp_allocator)
	check(name, loaded && len(discs) == 2, fmt.tprintf("%d discs", len(discs)))
	if len(discs) != 2 {
		return
	}
	da, db := discs[0], discs[1]
	check(name, da.id == a_id && da.info[.Path] == a_real && da.info[.System] == "ps1" && da.info[.Serial] == "", fmt.tprint("a:", da))
	check(name, da.info[.Label] == "DISC A" && da.info[.Title] == "DISC A" && !da.missing, fmt.tprint("a label:", da.info))
	check(name, da.compat[.Result] == "ok" && da.compat[.Id] == a_id && da.compat[.Lit] == "", fmt.tprint("a compat:", da.compat))
	check(name, db.id == b_id && db.info[.System] == "ps2" && db.info[.Serial] == "SLUS-12345", fmt.tprint("b:", db))
	check(name, db.info[.Label] == "DISC B" && db.compat[.Result] == "", fmt.tprint("b label:", db.info, db.compat))

	// The cached info is used while the file is unchanged.
	b_dir, _ := core.disc_dir(b_id, context.temp_allocator)
	b_info := core.disc_path(b_dir, .Info, context.temp_allocator)
	text, _ := os.read_entire_file(b_info, context.temp_allocator)
	edited, _ := strings.replace_all(string(text), "label\tDISC B\n", "label\tCACHED\n", context.temp_allocator)
	edited, _ = strings.replace_all(edited, "title\tDISC B\n", "title\tMine\n", context.temp_allocator)
	check(name, edited != string(text), fmt.tprintf("disc.tsv %q", text))
	_ = os.write_entire_file(b_info, transmute([]u8)edited)
	discs, _ = play.library_load(context.temp_allocator)
	check(name, len(discs) == 2 && discs[1].info[.Label] == "CACHED" && discs[1].info[.Title] == "Mine", "cached info not used")

	// A sector more: scanned again, the same disc, its title kept.
	grown := make([]u8, len(ps2_disc()) + disc.DATA, context.temp_allocator)
	copy(grown, labeled(ps2_disc(), " DISC\tB "))
	_ = put(dir, "b.iso", grown)
	discs, _ = play.library_load(context.temp_allocator)
	check(name, len(discs) == 2 && discs[1].id == b_id && discs[1].info[.Label] == "DISC B" && discs[1].info[.Title] == "Mine", fmt.tprint("grown b:", discs[1]))

	// Another disc in a's place, larger so its size differs.
	other := make([]u8, len(cnf_disc()) + disc.DATA, context.temp_allocator)
	copy(other, labeled(cnf_disc("", 0, 0, 0x1000ffff, 0), "DISC C"))
	_ = put(dir, "a.iso", other)
	c_id := id_of(a)
	discs, _ = play.library_load(context.temp_allocator)
	check(name, c_id != "" && c_id != a_id && len(discs) == 2 && discs[0].id == c_id && discs[0].info[.Title] == "DISC C", fmt.tprint("replaced a:", discs[0]))
	index, _ := filepath.join({data, "library.tsv"}, context.temp_allocator)
	rows, _ := os.read_entire_file(index, context.temp_allocator)
	check(name, string(rows) == fmt.tprintf("%s\t%s\n%s\t%s\n", a_real, c_id, b_real, b_id), fmt.tprintf("library.tsv %q", rows))

	// Gone: missing with what was known, until removed.
	_ = os.remove(a)
	discs, _ = play.library_load(context.temp_allocator)
	check(name, len(discs) == 2 && discs[0].missing && discs[0].info[.Label] == "DISC C" && !discs[1].missing, "a not missing")
	check(name, play.library_remove(a), "remove failed")
	discs, _ = play.library_load(context.temp_allocator)
	check(name, len(discs) == 1 && discs[0].id == b_id, fmt.tprint("after remove:", discs))
}

// The result of a run that reached FRAMES with progress and a fallen-back
// IOP module: fallback, unless it stalled, which comes first.
@(private = "file")
test_line_row :: proc() {
	name := "line_row"
	row: play.Row
	l := core.Compat_Line{result = "frames", frames = FRAMES, shown = 1, lit = 1, fallback = true}
	play.line_row(&row, l)
	check(name, row[.Result] == "fallback" && row[.Status] == "" && row[.Fatal] == "", fmt.tprintf("fallback: %v", row))
	row = {}
	l.lit = 0
	play.line_row(&row, l)
	check(name, row[.Result] == "stalled" && row[.Status] == "1" && row[.Fatal] == "stalled: nothing drawn", fmt.tprintf("stalled: %v", row))
	row = {}
	l.lit, l.fallback = 1, false
	play.line_row(&row, l)
	check(name, row[.Result] == "ok", fmt.tprintf("ok: %v", row))
}

// play --compat with COMPAT_CARDS unset, keep, and a bad value.
@(private = "file")
test_compat_cards :: proc() {
	name := "compat_cards"
	path := write(name, labeled(cnf_disc(), "COMPAT CARDS"))
	dir := disc_dir(name, path)
	if dir == "" {
		return
	}
	cards := core.disc_path(dir, .Cards, context.temp_allocator)
	fresh := core.disc_path(dir, .Compat_Cards, context.temp_allocator)
	card, _ := filepath.join({cards, "slot1.mcd"}, context.temp_allocator)
	stale, _ := filepath.join({fresh, "stale"}, context.temp_allocator)
	// 10 bytes: a card this short does not load.
	bad :: "not a card"
	if os.make_directory_all(cards) != nil || os.make_directory_all(fresh) != nil || os.write_entire_file(card, bad) != nil || os.write_entire_file(stale, "") != nil {
		check(name, false, "cannot write the cards")
		return
	}
	log_path := core.disc_path(dir, .Compat_Log, context.temp_allocator)
	id := disc_id(name, path)

	out, errs, ok := run_compat(name, {path, fmt.tprint(FRAMES)})
	row, found := compat_row(compat_rows(name), id)
	log, _ := os.read_entire_file(log_path, context.temp_allocator)
	what := fmt.tprintf("fresh: %v\nstdout:\n%s\nstderr:\n%s\ncompat.log:\n%s", row, out, errs, log)
	check(name, ok && found && row[.Cards] == "fresh" && row[.Result] == "stalled", what)
	blank, _ := filepath.join({fresh, "slot1.mcd"}, context.temp_allocator)
	check(name, strings.contains(string(log), fmt.tprintf("memcard: %s not found, using a blank card", blank)), what)
	check(name, !os.exists(stale), "the stale compat card kept")
	kept, _ := os.read_entire_file(card, context.temp_allocator)
	check(name, string(kept) == bad, fmt.tprintf("the disc's card changed: %q", kept))

	os.set_env(core.env_name("COMPAT_CARDS"), "keep")
	out, errs, ok = run_compat(name, {path, fmt.tprint(FRAMES)})
	row, found = compat_row(compat_rows(name), id)
	log, _ = os.read_entire_file(log_path, context.temp_allocator)
	what = fmt.tprintf("keep: %v\nstdout:\n%s\nstderr:\n%s\ncompat.log:\n%s", row, out, errs, log)
	check(name, ok && found && row[.Cards] == "kept", what)
	check(name, strings.contains(string(log), fmt.tprintf("memcard: %s is 10 bytes, expected", card)), what)

	os.set_env(core.env_name("COMPAT_CARDS"), "old")
	before := row
	out, errs, ok = run_compat(name, {path, fmt.tprint(FRAMES)})
	os.unset_env(core.env_name("COMPAT_CARDS"))
	row, found = compat_row(compat_rows(name), id)
	check(name, !ok && strings.contains(errs, "is not fresh or keep: old"), fmt.tprintf("bad value: stdout:\n%s\nstderr:\n%s", out, errs))
	check(name, found && row == before, fmt.tprintf("bad value ran: %v", row))
}

// play --compat on a disc with LEARN records: the parent compiles, never
// the child.
@(private = "file")
test_compat_learned :: proc() {
	name := "compat_learned"
	path := write(name, labeled(cnf_disc(), "COMPAT LEARNED"))
	dir := disc_dir(name, path)
	if dir == "" {
		return
	}
	learn := core.disc_path(dir, .Learn, context.temp_allocator)
	records, _ := filepath.join({learn, "psx.bin"}, context.temp_allocator)
	// jr ra; nop at 0x80010000, written twice: compacting keeps one.
	words := [?]u32{0x03e00008, 0}
	rec: [core.LEARN_HEADER + size_of(words)]u8
	rec[0], rec[1] = core.LEARN_TAG, u8(core.Learn_Cpu.Psx)
	endian.put_u32(rec[4:], .Little, 0x80010000)
	endian.put_u32(rec[8:], .Little, 0x80010000)
	endian.put_u32(rec[12:], .Little, len(words))
	copy(rec[core.LEARN_HEADER:], slice.to_bytes(words[:]))
	endian.put_u64(rec[16:], .Little, u64(xxhash.XXH3_64_default(rec[core.LEARN_HEADER:])))
	twice := slice.concatenate([][]u8{rec[:], rec[:]}, context.temp_allocator)
	if os.make_directory_all(learn) != nil || os.write_entire_file(records, twice) != nil {
		check(name, false, "cannot write the records")
		return
	}
	blob := core.disc_path(dir, .Learned, context.temp_allocator)
	key := core.disc_path(dir, .Learned_Key, context.temp_allocator)
	log_path := core.disc_path(dir, .Compat_Log, context.temp_allocator)
	id := disc_id(name, path)
	// The compile's own line; a child loading the blob prints
	// "learned: <n> functions from <path>".
	compiled :: "records (not compiled:"

	os.set_env(PLAY_TEST_CHILD, "learned")
	out, errs, ok := run_compat(name, {path, fmt.tprint(FRAMES)})
	os.unset_env(PLAY_TEST_CHILD)
	row, found := compat_row(compat_rows(name), id)
	what := fmt.tprintf("fake child: %v\nstdout:\n%s\nstderr:\n%s", row, out, errs)
	check(name, ok && found && row[.Fatal] == "fake child: learned blob stored", what)
	check(name, strings.contains(errs, compiled), what)
	compact, _ := os.read_entire_file(records, context.temp_allocator)
	check(name, string(compact) == string(rec[:]), "the records not compacted")
	before, serr := os.stat(records, context.temp_allocator)
	check(name, serr == nil, fmt.tprintf("cannot stat %s: %v", records, serr))

	// The real child.
	_ = os.remove(blob)
	_ = os.remove(key)
	out, errs, ok = run_compat(name, {path, fmt.tprint(FRAMES)})
	row, found = compat_row(compat_rows(name), id)
	log, _ := os.read_entire_file(log_path, context.temp_allocator)
	what = fmt.tprintf("real child: %v\nstderr:\n%s\ncompat.log:\n%s", row, errs, log)
	check(name, ok && found && row[.Result] == "stalled" && row[.Native] == "yes" && row[.Learned] == "yes", what)
	check(name, strings.contains(errs, compiled) && !strings.contains(string(log), compiled), what)
	check(name, strings.contains(string(log), "learned: 1 functions from"), what)
	check(name, !strings.contains(string(log), "play: no learned code"), what)
	b, _ := os.read_entire_file(blob, context.temp_allocator)
	check(name, core.blob_valid(b) && os.exists(key), "no blob after the real child")
	after, aerr := os.stat(records, context.temp_allocator)
	check(name, aerr == nil && serr == nil && after.modification_time == before.modification_time, "the compacted records rewritten")

	// A compile that fails: its output's path is a directory.
	_ = os.remove(blob)
	_ = os.remove(key)
	in_way := strings.concatenate({blob, ".compile"}, context.temp_allocator)
	in_way_file, _ := filepath.join({in_way, "in the way"}, context.temp_allocator)
	if os.make_directory(in_way) != nil || os.write_entire_file(in_way_file, "") != nil {
		check(name, false, "cannot block the compile")
		return
	}
	out, errs, ok = run_compat(name, {path, fmt.tprint(FRAMES)})
	_ = os.remove_all(in_way)
	row, found = compat_row(compat_rows(name), id)
	log, _ = os.read_entire_file(log_path, context.temp_allocator)
	what = fmt.tprintf("failed compile: %v\nstderr:\n%s\ncompat.log:\n%s", row, errs, log)
	check(name, ok && found && row[.Result] == "stalled" && row[.Learned] == "no", what)
	check(name, strings.contains(errs, "play: no learned code (the compile failed"), what)
	check(name, strings.contains(string(log), "play: no learned code (not compiled in the compat run)"), what)
	check(name, !strings.contains(string(log), "learned:"), what)
	check(name, !os.exists(blob) && !os.exists(key), "a blob from the failed compile")

	// A compile that hangs, stopped after COMPAT_BOOT_FACTOR (5) times a
	// 1 s COMPAT_WAIT. The fake compile sleeps 60 s: a run that did not
	// stop it takes that long, and one left running is killed here.
	pid_path, _ := filepath.join({dir, HANG_PID}, context.temp_allocator)
	_ = os.remove(pid_path)
	defer kill_fake_compile(pid_path)
	os.set_env(core.env_name("COMPAT_WAIT"), "1")
	os.set_env(PLAY_TEST_CHILD, "hang")
	start := time.tick_now()
	out, errs, ok = run_compat(name, {path, fmt.tprint(FRAMES)})
	took := time.duration_seconds(time.tick_since(start))
	os.unset_env(PLAY_TEST_CHILD)
	os.unset_env(core.env_name("COMPAT_WAIT"))
	row, found = compat_row(compat_rows(name), id)
	what = fmt.tprintf("hung compile: %.1f s %v\nstdout:\n%s\nstderr:\n%s", took, row, out, errs)
	check(name, ok && found && row[.Fatal] == "fake child: learned blob missing", what)
	check(name, os.exists(pid_path), what)
	check(name, took >= 5 && took < 15, what)
	check(name, strings.contains(errs, "play: no learned code (the compile took over 5 s, stopped)"), what)
	check(name, !os.exists(blob) && !os.exists(key) && !os.exists(in_way), "a blob from the hung compile")
	data, _ := core.data_dir(context.temp_allocator)
	tsv, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	_ = os.remove(tsv)
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
		fatal:  string, // of a stalled row
	}
	fixtures := [?]Fixture {
		{"loop.iso", cnf_disc(), "ps1", "stalled", "1", "", "", "", "stalled: no picture shown"},
		// li t1, 0xff; jal 0xa0; nop; b .; nop: BIOS A(ffh), then loop.
		{"stub.iso", cnf_disc("", 0x240900ff, 0x0c000028, 0, 0x1000ffff, 0), "ps1", "stalled", "1", "BIOS A(ffh)=1", "", "", "stalled: no picture shown"},
		// Opcode 0x3f is reserved.
		{"fatal.iso", cnf_disc("", 0xfc000000), "ps1", "fatal", "1", "", "", "", ""},
		{"ps2_loop.iso", ps2_disc(), "ps2", "stalled", "1", "", "", "", "stalled: no picture shown"},
		// li v1, 1; syscall; b .; nop: ResetEE, which only the retail ROM
		// has (checked below), then loop. compat.log says where it was made.
		{"ps2_stub.iso", ps2_disc(0x24030001, 0x0000000c, 0x1000ffff, 0), "ps2", "stalled", "1", "syscall 1=1", "", "\"pc\":\"00100004\",\"ra\":\"", "stalled: no picture shown"},
		// Opcode 0x3b is not an EE instruction.
		{"ps2_fatal.iso", ps2_disc(0xec000000), "ps2", "fatal", "1", "", "", "", ""},
		{"loadexec.iso", loadexec_disc(), "ps1", "stalled", "1", "", "80010100:", "", "stalled: no picture shown"},
		{"loadexec_missing.iso", loadexec_missing_disc(), "ps1", "stalled", "1", "", "", "running the boot executable again", "stalled: no picture shown"},
		{"load_exec.iso", load_exec_disc(), "ps1", "stalled", "1", "", "80020000:", "", "stalled: no picture shown"},
		{"ps2_loadexec.iso", ps2_loadexec_disc(), "ps2", "stalled", "1", "", "00100040:", "kernel: LoadExecPS2", "stalled: no picture shown"},
		{"ps2_loadexec_missing.iso", ps2_loadexec_disc("cdrom0:\\DATA\\NONE.ELF;1"), "ps2", "fatal", "1", "", "", "LoadExecPS2: no ELF", ""},
		{"ps2_execps2.iso", ps2_execps2_disc(), "ps2", "stalled", "1", "", "00100000:", "differs from the recompiled program; interpreting", "stalled: no picture shown"},
		// GP1(03000000) turns the display on, then a word in RAM counts up.
		{"show.iso", cnf_disc("", ..PS1_SHOW[:]), "ps1", "ok", "0", "", "", "", ""},
		// The display on, then b .: a picture, and RAM still.
		{"still.iso", cnf_disc("", ..PS1_STILL[:]), "ps1", "stalled", "1", "", "", "", fmt.tprintf("stalled: main RAM unchanged f%d-f%d", FRAMES / 2, FRAMES)},
		// A picture drawn, PMODE 1 turns read circuit 1 on, then a word in
		// RAM counts up.
		{"ps2_show.iso", ps2_show_disc(), "ps2", "ok", "0", "", "", "", ""},
		// The same with nothing drawn.
		{"ps2_dark.iso", ps2_disc(..PS2_DARK[:]), "ps2", "stalled", "1", "", "", "", "stalled: nothing drawn"},
		{"ps2_sleep.iso", ps2_disc(..PS2_SLEEP[:]), "ps2", "stalled", "1", "", "", "", "stalled: nothing drawn"},
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

	// A compat.tsv from before the shown column keeps its rows.
	cols := play.COLUMNS
	old := slice.enumerated_array(&cols)[:int(play.Column.Shown)]
	data, _ := core.data_dir()
	tsv, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	old_row := strings.repeat("\tx", len(old) - 1, context.temp_allocator)
	old_text := strings.concatenate({strings.join(old, "\t", context.temp_allocator), "\nOLD", old_row, "\n"}, context.temp_allocator)
	if os.write_entire_file(tsv, transmute([]u8)old_text) != nil {
		check(name, false, fmt.tprintf("cannot write %s", tsv))
		return
	}

	out, errs, ok := run_compat(name, {dir, fmt.tprint(FRAMES)})
	rows := compat_rows(name)
	if row, found := compat_row(rows, "OLD"); found {
		check(name, row[.When] == "x" && row[.Shown] == "" && row[.Idle_Share] == "" && row[.Lit] == "", fmt.tprintf("old row: %v", row))
	} else {
		check(name, false, "the old compat.tsv's row is gone")
	}
	check(name, ok, fmt.tprintf("status, stdout:\n%s\nstderr:\n%s", out, errs))
	check(name, strings.count(out, "\n") == len(fixtures), fmt.tprintf("stdout:\n%s", out))
	check(name, len(rows) == len(fixtures) + 1, fmt.tprintf("%d rows, want %d", len(rows), len(fixtures) + 1))
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
		switch f.result {
		case "ok":
			check(name, row[.Frames] == fmt.tprint(FRAMES) && row[.Fatal] == "" && row[.Shown] != "0", what)
			check(name, row[.Lit] != "0", what)
		case "stalled":
			check(name, row[.Frames] == fmt.tprint(FRAMES) && row[.Fatal] == f.fatal, what)
			check(name, (row[.Shown] == "0") == (f.fatal == "stalled: no picture shown"), what)
			check(name, f.fatal != "stalled: nothing drawn" || row[.Lit] == "0", what)
		case:
			check(name, row[.Fatal] != "", what)
		}
		if f.result != "fatal" {
			idle, has_idle := strconv.parse_f64(row[.Idle_Share])
			check(name, has_idle && (idle > 0.95) == (f.file == "ps2_sleep.iso") && (f.system == "ps2" || idle == 0), what)
			check(name, (row[.Lit] != "") == (f.system == "ps2"), what)
		}
		if ddir, has := core.disc_dir(ids[k], context.temp_allocator); has {
			log, err := os.read_entire_file(core.disc_path(ddir, .Compat_Log, context.temp_allocator), context.temp_allocator)
			check(name, err == nil && len(log) > 0, fmt.tprintf("%s: the child's output is not in compat.log (%v)", f.file, err))
			check(name, strings.contains(string(log), f.log), fmt.tprintf("%s: %q not in compat.log", f.file, f.log))
			// The last vblank's picture, when the display was on, as the
			// launcher's thumbnail.
			thumb := core.thumb_load(core.disc_path(ddir, .Thumb, context.temp_allocator), context.temp_allocator)
			check(name, (thumb != nil) == (f.result != "fatal" && row[.Shown] != "0"), fmt.tprintf("%s: thumb.ppm %v, shown %s", f.file, thumb != nil, row[.Shown]))
			if f.file == "ps2_show.iso" {
				check(name, thumb != nil && slice.any_of_proc(thumb, proc(b: u8) -> bool {return b != 0}), "ps2_show.iso: a black thumbnail")
			}
		}
		if k == 0 {
			first_when = row[.When]
		}
	}

	out, errs, ok = run_compat(name, {loop, fmt.tprint(FRAMES)})
	rows = compat_rows(name)
	check(name, ok && len(rows) == len(fixtures) + 1, fmt.tprintf("rerun: %d rows, stdout:\n%s\nstderr:\n%s", len(rows), out, errs))
	if row, found := compat_row(rows, ids[0]); found {
		check(name, row[.Result] == "stalled" && row[.When] != first_when, fmt.tprintf("rerun: %v", row))
	} else {
		check(name, false, "rerun: no row")
	}
	if ddir, has := core.disc_dir(ids[0], context.temp_allocator); has {
		b, err := os.read_entire_file(core.disc_path(ddir, .Compat_Progress, context.temp_allocator), context.temp_allocator)
		check(name, err == nil && len(b) == 8 && endian.unchecked_get_u64le(b) == 1, fmt.tprintf("rerun: compat.progress %v %v", b, err))
	}

	// Fake children, timed by the parent's progress windows.
	os.set_env(core.env_name("COMPAT_WAIT"), "1")
	Wait_Case :: struct {
		mode, result: string,
		// Bounds of the row's wall_s.
		lo, hi:       f64,
	}
	for c in ([]Wait_Case{{"stuck", "hang", 1, 4}, {"boot", "hang", 5, 8}, {"slow", "crash", 6.5, 10}}) {
		os.set_env(PLAY_TEST_CHILD, c.mode)
		out, errs, ok = run_compat(name, {loop})
		os.unset_env(PLAY_TEST_CHILD)
		rows = compat_rows(name)
		what := fmt.tprintf("%s child: stdout:\n%s\nstderr:\n%s", c.mode, out, errs)
		row, found := compat_row(rows, ids[0])
		check(name, ok && found, what)
		wall, has_wall := strconv.parse_f64(row[.Wall_S])
		what = fmt.tprintf("%s child: %v", c.mode, row)
		check(name, row[.Result] == c.result && has_wall && wall >= c.lo && wall < c.hi, what)
		check(name, row[.Status] == ("" if c.result == "hang" else "0"), what)
		check(name, c.result == "hang" ? row[.Fatal] == "" : row[.Fatal] == "fake child: done", what)
	}
	os.unset_env(core.env_name("COMPAT_WAIT"))
}

// fake_child's "orphan" pid file, in the disc directory.
@(private = "file")
ORPHAN_PID :: "orphan.pid"

// How soon an orphaned compat child must end.
@(private = "file")
ORPHAN_WITHIN :: 2 * time.Second

test_orphan :: proc() {
	name := "orphan"
	self, serr := os.get_executable_path(context.temp_allocator)
	if serr != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", serr))
		return
	}
	// A disc id of its own: no other test's row or files change.
	path := write(name, labeled(cnf_disc(), "ORPHAN"))
	ddir, has := core.disc_dir(disc_id(name, path), context.temp_allocator)
	if !has {
		check(name, false, "no disc directory")
		return
	}
	pid_path, _ := filepath.join({ddir, ORPHAN_PID}, context.temp_allocator)
	os.set_env(PLAY_TEST_CHILD, "orphan")
	defer os.unset_env(PLAY_TEST_CHILD)
	for how in STOPS {
		what := fmt.tprintf("%v", how)
		_ = os.remove(pid_path)
		parent, err := os.process_start({command = {self, "--compat", path}})
		if err != nil {
			check(name, false, fmt.tprintf("%s: cannot run play: %v", what, err))
			return
		}
		// The child's pid, once it has started watching.
		child := 0
		for _ in 0 ..< 300 {
			if text, rerr := os.read_entire_file(pid_path, context.temp_allocator); rerr == nil {
				if pid, ok := strconv.parse_int(string(text), 10); ok {
					child = pid
					break
				}
			}
			time.sleep(100 * time.Millisecond)
		}
		check(name, child != 0, fmt.tprintf("%s: the child wrote no pid", what))
		check(name, stop(parent, how), fmt.tprintf("%s: cannot stop the parent", what))
		_, _ = os.process_wait(parent)
		if child == 0 {
			continue
		}
		start := time.tick_now()
		for alive(child) && time.tick_since(start) < ORPHAN_WITHIN {
			time.sleep(50 * time.Millisecond)
		}
		gone := !alive(child)
		check(name, gone, fmt.tprintf("%s: the child still runs %v after its parent ended", what, ORPHAN_WITHIN))
		if !gone {
			kill_fake_compile(pid_path)
		}
	}
}

// Presents test_quit writes a picture of, from 1: it sends SIGTERM once
// picture QUIT_AFTER is written, and the run must quit before the last one.
@(private = "file")
QUIT_PICTURES :: 600
@(private = "file")
QUIT_AFTER :: 10

// GP1(03000000), the display on; GP0(02ffffff), (0, 0), (320 x 240): VRAM's
// top left filled white; then the count as PS1_SHOW's.
@(private = "file")
PS1_FILL := [?]u32 {
	0x3c081f80, 0x3c090300, 0xad091814, 0x3c0902ff, 0x3529ffff, 0xad091810, 0xad001810, 0x3c0900f0,
	0x35290140, 0xad091810, 0x3c0a8002, 0x8d4b0000, 0, 0x256b0001, 0xad4b0000, 0x1000fffb, 0,
}

test_quit :: proc() {
	name := "quit"
	when ODIN_OS == .Windows {
		return
	}
	self, serr := os.get_executable_path(context.temp_allocator)
	if serr != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", serr))
		return
	}
	dir, _ := filepath.join({tmp, "quit"}, context.temp_allocator)
	if os.make_directory(dir) != nil {
		check(name, false, fmt.tprintf("cannot make %s", dir))
		return
	}
	vblanks := make([dynamic]string, context.temp_allocator)
	for v in 1 ..= QUIT_PICTURES {
		append(&vblanks, fmt.tprint(v))
	}
	// A window, not headless and not to FRAMES; SDL's dummy drivers need no
	// display or sound device. SDL 2's dummy video has no accelerated
	// renderer, so there the PS1 window and the PS2 software GS's take the
	// software fallback (play quits when its renderer is not made).
	os.unset_env(core.env_name("HEADLESS"))
	os.unset_env(core.env_name("FRAMES"))
	os.set_env("SDL_VIDEODRIVER", "dummy")
	os.set_env("SDL_AUDIODRIVER", "dummy")
	defer {
		os.set_env(core.env_name("HEADLESS"), "1")
		os.set_env(core.env_name("FRAMES"), fmt.tprint(FRAMES))
		os.unset_env("SDL_VIDEODRIVER")
		os.unset_env("SDL_AUDIODRIVER")
	}
	// PS2: SHOT pictures (shot_<vblank>.ppm); PS1: DUMP's (frame_<present,
	// 5 digits>.ppm), written as the frame is presented.
	cases := [?]struct {
		file, setting, value, picture: string,
		image:                         []u8,
	} {
		{"ps2_show.iso", "SHOT", strings.join(vblanks[:], ",", context.temp_allocator), "shot_%d.ppm", ps2_show_disc()},
		{"fill.iso", "DUMP", dir, "frame_%05d.ppm", cnf_disc("", ..PS1_FILL[:])},
	}
	for c in cases {
		what := c.file
		iso, _ := filepath.join({dir, c.file}, context.temp_allocator)
		log, _ := filepath.join({dir, strings.concatenate({c.file, ".log"}, context.temp_allocator)}, context.temp_allocator)
		if os.write_entire_file(iso, c.image) != nil {
			check(name, false, fmt.tprintf("%s: cannot write it", what))
			continue
		}
		id := disc_id(name, iso)
		ddir, has_dir := core.disc_dir(id, context.temp_allocator)
		if !has_dir {
			check(name, false, fmt.tprintf("%s: no disc directory", what))
			continue
		}
		// An earlier run of the disc (test_compat's) may have left one.
		thumb_path := core.disc_path(ddir, .Thumb, context.temp_allocator)
		_ = os.remove(thumb_path)
		picture :: proc(dir, format: string, v: int) -> string {
			path, _ := filepath.join({dir, fmt.tprintf(format, v)}, context.temp_allocator)
			return path
		}
		out, ferr := os.create(log)
		if ferr != nil {
			check(name, false, fmt.tprintf("%s: cannot make %s: %v", what, log, ferr))
			continue
		}
		os.set_env(core.env_name(c.setting), c.value)
		p, perr := os.process_start({command = {self, iso}, working_dir = dir, stdout = out, stderr = out})
		os.unset_env(core.env_name(c.setting))
		os.close(out)
		if perr != nil {
			check(name, false, fmt.tprintf("%s: cannot run play: %v", what, perr))
			continue
		}
		// Stops at once if play exits before the picture (a timeout of 0
		// only polls).
		start := time.tick_now()
		state, werr := os.process_wait(p, 0)
		for werr == os.General_Error.Timeout && !os.exists(picture(dir, c.picture, QUIT_AFTER)) && time.tick_since(start) < 60 * time.Second {
			time.sleep(20 * time.Millisecond)
			state, werr = os.process_wait(p, 0)
		}
		if werr != os.General_Error.Timeout {
			text, _ := os.read_entire_file(log, context.temp_allocator)
			check(name, false, fmt.tprintf("%s: play quit by itself before picture %d: %v %v, its output: %s", what, QUIT_AFTER, werr, state, text))
			continue
		}
		check(name, os.exists(picture(dir, c.picture, QUIT_AFTER)), fmt.tprintf("%s: no picture %d within 60 s", what, QUIT_AFTER))
		check(name, sigterm(p.pid), fmt.tprintf("%s: cannot send SIGTERM", what))
		state, werr = os.process_wait(p, 30 * time.Second)
		if werr != nil {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
		}
		text, _ := os.read_entire_file(log, context.temp_allocator)
		check(name, werr == nil && state.exited && state.exit_code == 0, fmt.tprintf("%s: play %v %v, its output: %s", what, werr, state, text))
		// The picture of the last present before the quit: the last one
		// shown.
		last := 0
		for v in 1 ..= QUIT_PICTURES {
			if os.exists(picture(dir, c.picture, v)) {last = v}
		}
		check(name, last >= QUIT_AFTER && last < QUIT_PICTURES, fmt.tprintf("%s: last picture %d", what, last))
		data, _ := os.read_entire_file(picture(dir, c.picture, last), context.temp_allocator)
		w, h, rgb, ok := core.ppm_parse(data)
		if !ok {
			check(name, false, fmt.tprintf("%s: picture %d unread", what, last))
			continue
		}
		px := make([]u32, w * h, context.temp_allocator)
		for &v, i in px {
			v = u32(rgb[i * 3]) << 16 | u32(rgb[i * 3 + 1]) << 8 | u32(rgb[i * 3 + 2])
		}
		want := core.thumb_make(px, w, w, h, .Xrgb)
		thumb := core.thumb_load(thumb_path, context.temp_allocator)
		check(name, thumb != nil && slice.equal(thumb, want), fmt.tprintf("%s: thumb.ppm %v, not picture %d shrunk", what, thumb != nil, last))
		check(name, slice.any_of_proc(want, proc(b: u8) -> bool {return b != 0}), fmt.tprintf("%s: picture %d is black", what, last))
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

// Kill the fake compile whose pid is in the file at path, if it still runs.
@(private = "file")
kill_fake_compile :: proc(path: string) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	pid, ok := strconv.parse_int(string(text), 10)
	if !ok {
		return
	}
	// One already reaped is not found.
	if p, perr := os.process_open(pid); perr == nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
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

// The launcher under a DATA of its own, with a PS1 and a PS2 disc: moving
// stays within the list; Ok runs a disc; the settings screen cycles only the
// values the runtime reads and saves them to the disc's settings.tsv (the
// file gone when all are unset), refuses one the environment sets and shows
// it locked; Tab/X switches it to all discs' settings, saved to the global
// file, which a disc's own value overrides; a clear takes the row out of
// the scope's file and writes nothing when the file has no such row; the
// picture has the selection bar and the thumbnail, and a
// point maps to its row; Export (X, or Y on the list) asks for an export
// and launcher_export writes one under a free name; a missing disc will not
// run or export and can be removed; a
// dropped disc or directory joins the library, a duplicate or a non-disc
// does not.
// run_disc runs a disc to FRAMES with its stderr in play.log, and reports a
// failed run's last stderr line.
test_launcher :: proc() {
	name := "launcher"
	data, _ := filepath.join({tmp, "launcher_data"}, context.temp_allocator)
	dir, _ := filepath.join({tmp, "launcher"}, context.temp_allocator)
	old_data, old_sw, old_gpu := core.env("DATA"), core.env("SW"), core.env("GPU")
	os.set_env(core.env_name("DATA"), data)
	os.unset_env(core.env_name("SW"))
	os.unset_env(core.env_name("GPU"))
	defer {
		os.set_env(core.env_name("DATA"), old_data)
		os.set_env(core.env_name("SW"), old_sw)
		os.set_env(core.env_name("GPU"), old_gpu)
	}
	if os.make_directory(dir) != nil {
		check(name, false, "cannot make the launcher directory")
		return
	}
	a, _ := filepath.join({dir, "a.iso"}, context.temp_allocator)
	b, _ := filepath.join({dir, "b.iso"}, context.temp_allocator)
	if os.write_entire_file(a, labeled(cnf_disc(), "DISC A")) != nil || os.write_entire_file(b, ps2_disc()) != nil {
		check(name, false, "cannot write the discs")
		return
	}
	// The library keeps a path with its symlinks resolved (a macOS temp
	// directory is under /var).
	a_real, _ := filepath.abs(a, context.temp_allocator)
	b_real, _ := filepath.abs(b, context.temp_allocator)
	_, _, added := play.library_add(dir)
	l: play.Launcher
	defer play.launcher_destroy(&l)
	if !added || !play.launcher_init(&l) || len(l.discs) != 2 {
		check(name, false, fmt.tprintf("library of %d", len(l.discs)))
		return
	}
	W, H :: 480, 360
	play.launcher_resize(&l, W, H)
	lo := l.layout
	check(name, lo.scale == 1 && lo.rows > 2, fmt.tprint("layout:", lo))
	play.launcher_resize(&l, 2 * W + 7, 3 * H)
	check(name, l.layout.scale == 2, fmt.tprint("scale at 967 x 1080:", l.layout.scale))
	play.launcher_resize(&l, W, H)

	step :: proc(l: ^play.Launcher, a: play.Action) -> play.Command {return play.launcher_step(l, a)}
	_ = step(&l, .Down)
	_ = step(&l, .Page_Down)
	check(name, l.sel == 1, fmt.tprint("down past the end:", l.sel))
	_ = step(&l, .Page_Up)
	check(name, l.sel == 0, fmt.tprint("page up:", l.sel))
	check(name, step(&l, .Ok) == .Launch && step(&l, .Quit) == .Quit, "ok, quit")

	// PS1 settings: GPU vk, sw, unset; the file holds only what is set.
	a_dir, _ := core.disc_dir(l.discs[0].id, context.temp_allocator)
	a_set := core.disc_path(a_dir, .Settings, context.temp_allocator)
	saved :: proc(path: string) -> string {
		text, _ := os.read_entire_file(path, context.temp_allocator)
		return string(text)
	}
	_ = step(&l, .Menu)
	check(name, l.screen == .Settings && len(play.launcher_choices(&l)) == 2, "ps1 settings screen")
	_ = step(&l, .Right)
	check(name, saved(a_set) == "GPU\tvk\n", fmt.tprintf("GPU vk: %q", saved(a_set)))
	_ = step(&l, .Ok)
	check(name, saved(a_set) == "GPU\tsw\n", fmt.tprintf("GPU sw: %q", saved(a_set)))
	_ = step(&l, .Right)
	check(name, !os.exists(a_set) && l.settings.set == {}, "GPU unset leaves no file")
	_ = step(&l, .Left)
	check(name, saved(a_set) == "GPU\tsw\n", fmt.tprintf("GPU back to sw: %q", saved(a_set)))
	// Set in the environment, even to "": locked. Windows has no empty
	// variable (setting one to "" removes it), so there it is "1".
	os.set_env(core.env_name("NATIVE"), "1" when ODIN_OS == .Windows else "")
	_ = step(&l, .Down)
	_ = step(&l, .Right)
	text, locked := play.launcher_setting_text(&l, play.launcher_choices(&l)[1])
	check(name, saved(a_set) == "GPU\tsw\n" && locked && strings.contains(text, core.env_name("NATIVE")), fmt.tprintf("locked: %q %q", text, saved(a_set)))
	check(name, strings.contains(l.toast, core.env_name("NATIVE")), fmt.tprintf("locked toast %q", l.toast))
	os.unset_env(core.env_name("NATIVE"))
	_ = step(&l, .Back)
	check(name, l.screen == .List && l.toast == "", "back to the list")

	// PS2 settings: SCALE steps back from unset to 8.
	_ = step(&l, .Down)
	_ = step(&l, .Menu)
	check(name, len(play.launcher_choices(&l)) == 4, "ps2 settings screen")
	_ = step(&l, .Down)
	_ = step(&l, .Left)
	b_dir, _ := core.disc_dir(l.discs[1].id, context.temp_allocator)
	b_set := core.disc_path(b_dir, .Settings, context.temp_allocator)
	check(name, saved(b_set) == "SCALE\t8\n", "SCALE 8")

	// All discs: Tab/X switches the scope. An edit there writes only the
	// global file; clearing a row a file lacks writes nothing.
	g_set, _ := core.settings_global_path(context.temp_allocator)
	_ = step(&l, .Menu)
	check(name, l.screen == .Settings && l.scope == .Global && l.row == 0 && len(play.launcher_choices(&l)) == 5, "all discs screen")
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	_ = step(&l, .Right)
	_ = step(&l, .Right)
	text, _ = play.launcher_setting_text(&l, play.launcher_choices(&l)[2])
	check(name, saved(g_set) == "SCALE\t2\n" && saved(b_set) == "SCALE\t8\n" && text == "2x (all discs)", fmt.tprintf("all discs SCALE 2: %q %q %q", saved(g_set), saved(b_set), text))
	_ = step(&l, .Down)
	_ = step(&l, .Remove)
	check(name, saved(g_set) == "SCALE\t2\n" && l.row == 3 && l.toast != "", fmt.tprintf("clear an unset IRX: %q %d %q", saved(g_set), l.row, l.toast))

	// The disc's own value wins on its screen; cleared, the global one shows;
	// cleared again with no file, none is made.
	_ = step(&l, .Menu)
	check(name, l.scope == .Disc && l.row == 0, "back to the disc's scope")
	_ = step(&l, .Down)
	text, _ = play.launcher_setting_text(&l, play.launcher_choices(&l)[1])
	check(name, text == "8x (this disc)", fmt.tprintf("disc over global: %q", text))
	_ = step(&l, .Remove)
	text, _ = play.launcher_setting_text(&l, play.launcher_choices(&l)[1])
	check(name, !os.exists(b_set) && text == "2x (all discs)", fmt.tprintf("disc cleared: %v %q", os.exists(b_set), text))
	_ = step(&l, .Remove)
	check(name, !os.exists(b_set) && l.toast != "", "clear with no file makes none")

	// Set in the environment: locked on the all discs screen too, neither
	// changed nor cleared. Then cleared there, the default shows.
	os.set_env(core.env_name("SCALE"), "3")
	_ = step(&l, .Menu)
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	_ = step(&l, .Right)
	check(name, saved(g_set) == "SCALE\t2\n" && strings.contains(l.toast, core.env_name("SCALE")), fmt.tprintf("locked change: %q %q", saved(g_set), l.toast))
	_ = step(&l, .Remove)
	text, locked = play.launcher_setting_text(&l, play.launcher_choices(&l)[2])
	check(name, saved(g_set) == "SCALE\t2\n" && strings.contains(l.toast, core.env_name("SCALE")) && locked && text == fmt.tprintf("3x (set by %s)", core.env_name("SCALE")), fmt.tprintf("locked clear: %q %q %q", saved(g_set), l.toast, text))
	os.unset_env(core.env_name("SCALE"))
	_ = step(&l, .Remove)
	text, locked = play.launcher_setting_text(&l, play.launcher_choices(&l)[2])
	check(name, !os.exists(g_set) && text == "default" && !locked, fmt.tprintf("all discs cleared: %v %q", os.exists(g_set), text))
	_ = step(&l, .Back)
	check(name, l.screen == .List, "Esc/B back to the list")

	// The picture: the bar on the selected row, the thumbnail, rows by point.
	red := make([]u32, 320 * 240, context.temp_allocator)
	slice.fill(red, 0xff0000)
	core.thumb_path = core.disc_path(b_dir, .Thumb, context.temp_allocator)
	core.thumb_save(red, 320, 320, 240, .Xrgb)
	core.thumb_path = ""
	check(name, play.launcher_reload(&l, b) && l.sel == 1 && l.thumb != nil, "reload keeps b with its thumbnail")
	px := make([]u32, W * H, context.temp_allocator)
	play.launcher_draw(&l, px)
	lo = l.layout
	bar_y := lo.list_y + lo.line
	check(name, px[bar_y * W + lo.margin] == 0x2c4c70 && px[lo.list_y * W + lo.margin] != 0x2c4c70, "selection bar")
	check(name, px[lo.list_y * W + lo.panel_x] == 0xff0000 && px[(lo.list_y + core.THUMB_H - 1) * W + lo.panel_x + core.THUMB_W - 1] == 0xff0000, "thumbnail")
	check(name, play.launcher_row_at(&l, lo.margin, bar_y) == 1 && play.launcher_row_at(&l, lo.margin, lo.list_y + 2 * lo.line) == -1 && play.launcher_row_at(&l, 0, bar_y) == -1, "row at a point")

	// A title with runes outside ASCII: each such rune one blank cell, the
	// ASCII after it at its rune's cell, in the list row and the panel's
	// title line, and the cell past the last rune blank. Both fit the title.
	TITLE :: "é中Z-x"
	l.discs[1].info[.Title] = TITLE
	play.launcher_draw(&l, px)
	runes := utf8.rune_count_in_string(TITLE)
	check(name, lo.list_w / (core.FONT_GLYPH * lo.scale) - 1 > runes && core.THUMB_W / core.FONT_GLYPH > runes, "the title fits both lines")
	bad := glyph_cells(px, W, lo.margin + lo.scale, bar_y, lo.scale, TITLE)
	check(name, bad == "", fmt.tprint("list title:", bad))
	bad = glyph_cells(px, W, lo.panel_x, lo.list_y + core.THUMB_H * lo.scale + lo.line, lo.scale, TITLE)
	check(name, bad == "", fmt.tprint("panel title:", bad))

	// Export: Y exports on the list and clears on the settings screen; the
	// disc goes to <root>/<title as a file name>, then to "<name> 2".
	check(name, play.launcher_y(&l) == .Export && step(&l, .Export) == .Export, "export a disc")
	_ = step(&l, .Menu)
	check(name, play.launcher_y(&l) == .Remove, "Y clears in the settings")
	_ = step(&l, .Back)
	ports, _ := filepath.join({tmp, "launcher_ports"}, context.temp_allocator)
	l.discs[l.sel].info[.Title] = " x/y: z. "
	for want in ([]string{"x_y_ z", "x_y_ z 2"}) {
		out, _ := filepath.join({ports, want}, context.temp_allocator)
		readme, _ := filepath.join({out, "README.md"}, context.temp_allocator)
		play.launcher_export(&l, ports)
		check(name, l.toast == fmt.tprintf("Exported to %s", out) && os.exists(readme), fmt.tprintf("exported to %q: %q", want, l.toast))
	}

	// A missing disc: no run, no settings, no export; removed.
	_ = os.rename(a, fmt.tprint(a, ".gone"))
	check(name, play.launcher_reload(&l, a) && l.sel == 0 && l.discs[0].missing, "a missing")
	check(name, step(&l, .Launch) == .None && l.toast != "" && step(&l, .Menu) == .None && l.screen == .List, "a missing runs")
	check(name, play.launcher_y(&l) == .Remove && step(&l, .Export) == .None && l.toast != "", "a missing exports")
	_ = step(&l, .Remove)
	check(name, len(l.discs) == 1 && l.discs[0].info[.Path] == b_real, fmt.tprint("removed:", len(l.discs)))
	_ = os.rename(fmt.tprint(a, ".gone"), a)

	// Dropped on the window: a disc, selected and back on the list; the
	// same again; a file that is not a disc; a directory of two more.
	_ = step(&l, .Menu)
	play.launcher_add(&l, a)
	check(name, len(l.discs) == 2 && l.sel == 1 && l.discs[1].info[.Path] == a_real && l.screen == .List && l.toast == "Added 1 disc.", fmt.tprintf("dropped a: %d %d %q", len(l.discs), l.sel, l.toast))
	play.launcher_select_row(&l, 0)
	play.launcher_add(&l, a)
	check(name, len(l.discs) == 2 && l.sel == 1 && l.toast == "Already in the library.", fmt.tprintf("dropped a again: %d %d %q", len(l.discs), l.sel, l.toast))
	drop, _ := filepath.join({tmp, "launcher_drop"}, context.temp_allocator)
	c, _ := filepath.join({drop, "c.iso"}, context.temp_allocator)
	e, _ := filepath.join({drop, "e.iso"}, context.temp_allocator)
	junk, _ := filepath.join({drop, "junk.iso"}, context.temp_allocator)
	if os.make_directory(drop) != nil || os.write_entire_file(c, labeled(cnf_disc(), "DISC C")) != nil || os.write_entire_file(e, labeled(cnf_disc(), "DISC E")) != nil || os.write_entire_file(junk, transmute([]u8)string("not a disc")) != nil {
		check(name, false, "cannot write the dropped discs")
		return
	}
	c_real, _ := filepath.abs(c, context.temp_allocator)
	play.launcher_add(&l, junk)
	check(name, len(l.discs) == 2 && l.sel == 1 && strings.has_prefix(l.toast, "No disc image"), fmt.tprintf("dropped junk: %d %q", len(l.discs), l.toast))
	play.launcher_add(&l, drop)
	check(name, len(l.discs) == 4 && l.sel == 2 && l.discs[2].info[.Path] == c_real && l.toast == "Added 2 discs, 1 not a disc image (see the terminal).", fmt.tprintf("dropped a directory: %d %d %q", len(l.discs), l.sel, l.toast))
	check(name, step(&l, .Down) == .None && l.toast == "", "the toast goes with the next action")

	// One drop of several paths: one toast for them all, the first new disc
	// selected. A drop begun and never ended counts no more once another
	// begins; a path dropped after an end is a drop of its own.
	burst, _ := filepath.join({tmp, "launcher_burst"}, context.temp_allocator)
	f, _ := filepath.join({burst, "f.iso"}, context.temp_allocator)
	g, _ := filepath.join({burst, "g.iso"}, context.temp_allocator)
	if os.make_directory(burst) != nil || os.write_entire_file(f, labeled(cnf_disc(), "DISC F")) != nil || os.write_entire_file(g, labeled(cnf_disc(), "DISC G")) != nil {
		check(name, false, "cannot write the burst's discs")
		return
	}
	f_real, _ := filepath.abs(f, context.temp_allocator)
	n := len(l.discs)
	play.launcher_drop_begin(&l)
	play.launcher_add(&l, f)
	play.launcher_add(&l, a)
	play.launcher_add(&l, junk)
	play.launcher_add(&l, g)
	play.launcher_drop_end(&l)
	check(name, len(l.discs) == n + 2 && l.sel == n && l.discs[n].info[.Path] == f_real && l.toast == "Added 2 discs, 1 already in the library, 1 not a disc image (see the terminal).", fmt.tprintf("a burst: %d %d %q", len(l.discs), l.sel, l.toast))
	play.launcher_drop_begin(&l)
	play.launcher_add(&l, f)
	play.launcher_drop_begin(&l)
	play.launcher_add(&l, junk)
	check(name, l.toast == "No disc image there (see the terminal).", fmt.tprintf("a burst never ended: %q", l.toast))
	play.launcher_drop_end(&l)
	play.launcher_add(&l, g)
	check(name, l.toast == "Already in the library.", fmt.tprintf("a drop after the end: %q", l.toast))

	// At the smallest window each value a choice can take, from wherever it
	// comes, fits the settings' value column whole, across the panel's
	// width; a value from the environment that is no choice ends in "..."
	// where it is cut.
	vc := play.launcher_value_chars(&l)
	worst := ""
	setting_names := core.SETTING_NAMES
	for row in 0 ..< 2 {
		play.launcher_select_row(&l, row)
		for scope in play.Scope {
			l.scope = scope
			for c in play.launcher_choices(&l) {
				for v in c.values {
					for from in 0 ..< 3 {
						l.settings, l.global = {}, {}
						switch from {
						case 0:
							l.settings.set, l.settings.value[c.setting] = {c.setting}, v
						case 1:
							l.global.set, l.global.value[c.setting] = {c.setting}, v
						case 2:
							when ODIN_OS == .Windows {
								if v == "" {continue}
							}
							os.set_env(core.env_name(setting_names[c.setting]), v)
						}
						t, _ := play.launcher_setting_text(&l, c)
						if len(t) > vc {
							worst = t
						}
						os.unset_env(core.env_name(setting_names[c.setting]))
					}
				}
			}
		}
	}
	check(name, vc > 0 && worst == "", fmt.tprintf("a value cut at %d: %q", vc, worst))
	l.scope = .Global
	os.set_env(core.env_name("SCALE"), "a value no choice has, set by hand")
	text, _ = play.launcher_setting_text(&l, play.GLOBAL_CHOICES[2])
	cut := play.launcher_fit(text, vc)
	check(name, len(text) > vc && len(cut) == vc && strings.has_suffix(cut, "...") && strings.has_prefix(text, cut[:vc - 3]), fmt.tprintf("a long value cut: %q", cut))
	// A value of 3-byte runes: its cut falls inside a rune's bytes unless it
	// is made on a rune boundary, and still ends in "...".
	os.set_env(core.env_name("SCALE"), strings.repeat("€", vc, context.temp_allocator))
	text, _ = play.launcher_setting_text(&l, play.GLOBAL_CHOICES[2])
	cut = play.launcher_fit(text, vc)
	check(name, utf8.rune_count_in_string(text) > vc && utf8.valid_string(cut) && utf8.rune_count_in_string(cut) == vc && strings.has_suffix(cut, "...") && strings.has_prefix(text, cut[:len(cut) - 3]), fmt.tprintf("a long value of 3-byte runes cut: %q", cut))
	os.unset_env(core.env_name("SCALE"))
	check(name, play.launcher_reload(&l, "") && step(&l, .Menu) == .None, "back to the disc's settings")
	play.launcher_draw(&l, px)
	lo = l.layout
	check(name, px[lo.list_y * W + lo.margin + lo.wide_w - 1] == 0x2c4c70 && px[lo.list_y * W + lo.panel_x] == 0x2c4c70, "the settings rows take the panel's width")
	_ = step(&l, .Back)

	// A window too short for every row: the list and the settings scroll to
	// keep the selected row in view, and a point maps through the scroll.
	play.launcher_resize(&l, W, lo.list_y + 4 * lo.line + lo.margin)
	lo = l.layout
	check(name, lo.rows == 2 && len(l.discs) >= 6, fmt.tprintf("a short window: %d rows, %d discs", lo.rows, len(l.discs)))
	play.launcher_select_row(&l, 0)
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	check(name, l.sel == 3 && l.top == 2 && play.launcher_row_at(&l, lo.margin, lo.list_y) == 2 && play.launcher_row_at(&l, lo.margin, lo.list_y + lo.line) == 3 && play.launcher_row_at(&l, lo.margin, lo.list_y + 2 * lo.line) == -1, fmt.tprintf("list scrolled: sel %d top %d", l.sel, l.top))
	_ = step(&l, .Page_Up)
	check(name, l.sel == 1 && l.top == 1, fmt.tprintf("list page up: sel %d top %d", l.sel, l.top))
	_ = step(&l, .Menu)
	_ = step(&l, .Menu)
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	_ = step(&l, .Down)
	check(name, l.scope == .Global && l.row == 3 && l.row_top == 2 && play.launcher_row_at(&l, lo.margin, lo.list_y + lo.line) == 3, fmt.tprintf("settings scrolled: row %d top %d", l.row, l.row_top))
	for _ in 0 ..< 4 {
		_ = step(&l, .Up)
	}
	check(name, l.row == 4 && l.row_top == 3, fmt.tprintf("settings up past the top: row %d top %d", l.row, l.row_top))
	_ = step(&l, .Page_Up)
	check(name, l.row == 2 && l.row_top == 2, fmt.tprintf("settings page up: row %d top %d", l.row, l.row_top))
	_ = step(&l, .Back)
	play.launcher_resize(&l, W, H)

	// A run: to FRAMES, its stderr in play.log; a failed one's last line.
	self, _ := os.get_executable_path(context.temp_allocator)
	ok, last := play.run_disc(self, a, id_of(a))
	log := saved(core.disc_path(a_dir, .Play_Log, context.temp_allocator))
	check(name, ok && strings.contains(log, fmt.tprintf("frames: %d reached", FRAMES)), fmt.tprintf("run: %v %q, play.log %q", ok, last, log))
	not_disc, _ := filepath.join({dir, "c.iso"}, context.temp_allocator)
	_ = os.write_entire_file(not_disc, transmute([]u8)string("not a disc"))
	ok, last = play.run_disc(self, not_disc, l.discs[0].id)
	check(name, !ok && strings.contains(last, "is not a disc image"), fmt.tprintf("failed run: %v %q", ok, last))
}

LAUNCHER_TEXT :: 0xd8d8d8 // the launcher's text color
GLYPH_CELL :: core.FONT_GLYPH * core.FONT_GLYPH

// Check the launcher text str drawn at (x, y) of a picture stride pixels
// wide, cell by cell against the font: a rune outside ASCII and the cell
// past the last rune blank. A pixel is lit when it is the launcher's text
// color. Returns "" or the first cell that differs.
glyph_cells :: proc(px: []u32, stride, x, y, scale: int, str: string) -> string {
	k := 0
	for r in str {
		want: [GLYPH_CELL]u32
		if r < 0x80 {
			core.font_glyph(want[:], core.FONT_GLYPH, u8(r), 0, 0, LAUNCHER_TEXT)
		}
		if !glyph_cell_is(px, stride, x + k * core.FONT_GLYPH * scale, y, scale, want) {
			return fmt.tprintf("cell %d (%q)", k, r)
		}
		k += 1
	}
	if !glyph_cell_is(px, stride, x + k * core.FONT_GLYPH * scale, y, scale, {}) {
		return fmt.tprintf("cell %d past the end", k)
	}
	return ""
}

// One cell of glyph_cells: lit where want is, unlit elsewhere.
glyph_cell_is :: proc(px: []u32, stride, x, y, scale: int, want: [GLYPH_CELL]u32) -> bool {
	for row in 0 ..< core.FONT_GLYPH * scale {
		for col in 0 ..< core.FONT_GLYPH * scale {
			lit := px[(y + row) * stride + x + col] == LAUNCHER_TEXT
			if lit != (want[(row / scale) * core.FONT_GLYPH + col / scale] != 0) {
				return false
			}
		}
	}
	return true
}

// launcher_fit at every width from 0 to past the whole string, of strings of
// 1-, 2-, 3- and 4-byte runes and a mix: valid UTF-8, at most the width in
// runes, the string itself when it fits, else its first runes and "..." (or
// only its first runes under 3).
test_launcher_fit :: proc() {
	name :: "launcher_fit"
	strs := [?]string{"abcdefgh", "éèêëàâîï", "€₤₹₩₽₴₦₱", "😀😁😂🤣😃😄😅😆", "a€é😀b€é😀c", ""}
	for str in strs {
		count := utf8.rune_count_in_string(str)
		for n in 0 ..= count + 2 {
			cut := play.launcher_fit(str, n)
			runes := utf8.rune_count_in_string(cut)
			ok := utf8.valid_string(cut) && runes <= n
			if count <= n {
				ok &&= cut == str
			} else if n < 3 {
				ok &&= runes == n && strings.has_prefix(str, cut)
			} else {
				ok &&= runes == n && strings.has_suffix(cut, "...") && strings.has_prefix(str, cut[:len(cut) - 3])
			}
			check(name, ok, fmt.tprintf("%q cut to %d: %q", str, n, cut))
		}
	}
}

// PRESS scripts through input_script_load and input_poll (see the header).
@(private = "file")
test_press :: proc() {
	name := "press"
	defer os.unset_env(core.env_name("PRESS"))
	load :: proc(spec: string) -> bool {
		clear(&core.input.script)
		os.set_env(core.env_name("PRESS"), spec)
		return core.input_script_load(6)
	}
	check(name, load("Cross@10+3,Start@11"), "buttons-only script did not load")
	for f in u64(0) ..< 20 {
		p := core.input_poll(f)[0]
		want: core.Buttons
		if f >= 10 && f < 13 {
			want += {.Cross}
		}
		if f >= 11 && f < 17 {
			want += {.Start}
		}
		check(name, p.buttons == want, fmt.tprintf("frame %d buttons %v, want %v", f, p.buttons, want))
		check(name, p.left == {} && p.right == {}, fmt.tprintf("frame %d sticks %v %v with no stick named", f, p.left, p.right))
	}
	check(name, load("LRight@5+4"), "LRight did not load")
	for f in u64(0) ..< 12 {
		p := core.input_poll(f)[0]
		want := f >= 5 && f < 9 ? [2]f32{1, 0} : [2]f32{}
		check(name, p.left == want && p.right == {} && p.buttons == {}, fmt.tprintf("frame %d LRight gives %v %v %v, want left %v", f, p.left, p.right, p.buttons, want))
	}
	check(name, load("lup&LRIGHT&Cross@2+2,LUp@7+3,RDown@8+3:2,RDown@8+3"), "combined entries did not load")
	p := core.input_poll(2)[0]
	check(name, p.left == {1, -1} && p.buttons == {.Cross}, fmt.tprintf("LUp&LRight&Cross gives %v %v", p.left, p.buttons))
	ps := core.input_poll(8)
	check(name, ps[0].left == {0, -1} && ps[0].right == {0, 1} && ps[1].right == {0, 1} && ps[1].left == {}, fmt.tprintf("overlapping LUp, RDown gives %v", ps))
	check(name, !load("LRight@5,Sideways@6"), "an unknown name loaded")
	clear(&core.input.script)
}

// play.log's text: a carriage return a line break, CSI sequences and
// two-byte ESC sequences dropped, a sequence cut between chunks too.
test_log_strip :: proc() {
	cases := [?]struct {
		chunks: []string,
		want:   string,
	} {
		{{"plain\n"}, "plain\n"},
		{{"1/3\r\x1b[K2/3\r\x1b[K3/3\n"}, "1/3\n2/3\n3/3\n"},
		{{"a\x1b[1;31mred\x1b[0m b\r\n"}, "ared b\n\n"},
		{{"x\x1b", "[2", "Ky"}, "xy"},
		{{"x\x1b", "7y"}, "xy"},
		{{"\x1b"}, ""},
	}
	for c in cases {
		esc: play.Log_Escape
		out := strings.builder_make(context.temp_allocator)
		for chunk in c.chunks {
			dst := make([]u8, len(chunk), context.temp_allocator)
			n := play.log_strip(&esc, transmute([]u8)chunk, dst)
			strings.write_bytes(&out, dst[:n])
		}
		got := strings.to_string(out)
		check("log_strip", got == c.want, fmt.tprintf("%q gave %q, want %q", c.chunks, got, c.want))
	}
}
