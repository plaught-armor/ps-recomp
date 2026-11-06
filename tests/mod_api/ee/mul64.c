// A 64-bit multiply, which the R5900 does not have: the build fails.
#include "mod_api.h"

u64 product;

static void before(u64 a0, u64 a1) {
	product = a0 * a1;
}

MOD_BEFORE(ram_00100000, before);
