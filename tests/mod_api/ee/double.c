// A double, which the R5900 FPU does not have: the build fails.
#include "mod_api.h"

double scaled;

static void before(u32 a0) {
	scaled = (double)a0 * 1.5;
}

MOD_BEFORE(ram_00100000, before);
