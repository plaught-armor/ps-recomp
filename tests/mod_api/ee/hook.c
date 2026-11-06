// An EE mod on the fixture: a before hook that keeps its 64-bit argument
// and calls a game function, an after hook, and a replacement that calls
// mod_call_original. Every call into the game is a plain jal.
#include "mod_api.h"

static u32 count;
static u64 wide;

static void before(u64 a0) {
	count++;
	wide = a0;
	ram_00100020();
}

static void after(void) {
	count++;
}

static u32 replacement(u32 a, u32 b) {
	return ((u32 (*)(u32, u32))mod_call_original)(a, b) + 1;
}

MOD_BEFORE(ram_00100000, before);
MOD_AFTER(ram_00100020, after);
MOD_REPLACE(ram_00100040, replacement);
