// A game call without long_call (no mod_api.h): the jal cannot reach the
// game, and tests/mod_api must see it.
unsigned ram_80010000();

unsigned calls;

void hook(void) { calls += ram_80010000(); }
