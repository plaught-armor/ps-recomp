// A .rodata.x section past the image's end: the check at the end of mod.ld
// covers it, so the link must fail.
__attribute__((section(".rodata.x"), used)) const unsigned char big[0x400000] = {1};
