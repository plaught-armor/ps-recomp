// A game tail call without long_call (no mod_api.h): a j, which cannot
// reach the game either, and tests/mod_api must see it. clang does not tail
// call on this target, so it is written out, as hand-written code would.
__asm__(".text\n"
	".globl hook\n"
	".type hook, @function\n"
	"hook:\n"
	".set noreorder\n"
	"	j ram_80010000\n"
	"	nop\n"
	".set reorder\n"
	".size hook, . - hook\n");
