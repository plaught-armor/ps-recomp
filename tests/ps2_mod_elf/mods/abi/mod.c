// The EE mod tests/ps2_mod_elf loads: hooks on the test's game
// (tests/ps2_mod_elf/main.odin), logging into its RAM from LOG.
#include "mod_api.h"

#define LOG ((volatile u64 *)0x00180040)

// ram_00100400 takes and returns a 64-bit value.
static void before_wide(u64 x) { LOG[0] = x; }
static void after_wide(u64 x) { LOG[1] = x; }
static u64 replace_wide(u64 x) {
	return ((u64 (*)(u64))mod_call_original)(x + 0x100000000ull) + 1;
}
MOD_BEFORE(ram_00100400, before_wide);
MOD_AFTER(ram_00100400, after_wide);
MOD_REPLACE(ram_00100400, replace_wide);

// ram_00100500 adds its 8 arguments, ram_00100600 its 9 (the ninth on the
// stack).
typedef u32 (*add8)(u32, u32, u32, u32, u32, u32, u32, u32);
typedef u32 (*add9)(u32, u32, u32, u32, u32, u32, u32, u32, u32);
static u32 replace_add8(u32 a, u32 b, u32 c, u32 d, u32 e, u32 f, u32 g, u32 h) {
	return ((add8)mod_call_original)(a + 1, b, c, d, e, f, g, h + 1) + ((add9)ram_00100600)(a, b, c, d, e, f, g, h, 100);
}
MOD_REPLACE(ram_00100500, replace_add8);

// Change all 128 bits of s0 (pcpyld s0, zero, s0 clears the upper 64; n32
// code saves and restores only the lower 64): the runtime puts the upper
// half back, the code's own restore the lower.
static void clobber_s0(void) { __asm__ volatile(".word 0x70108389\n\tli $16, 7" ::: "$16"); }
// Change $f21 and $f31, which the game keeps across a call and n32 code
// does not: the runtime puts them back.
static void clobber_f(void) { __asm__ volatile("mtc1 $0, $f21\n\tmtc1 $0, $f31" ::: "$f21", "$f31"); }
static volatile float minus_2_75 = -2.75f;
static void before_keep(void) {
	clobber_s0();
	clobber_f();
	LOG[2] += 1;
	LOG[3] = (u64)(long long)mod_f2i(minus_2_75);
}
static void replace_keep(void) {
	clobber_s0();
	clobber_f();
	((void (*)(void))mod_call_original)();
}
MOD_BEFORE(ram_00100700, before_keep);
MOD_REPLACE(ram_00100700, replace_keep);
