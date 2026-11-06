// A loaded section mod.ld does not place: ld.lld would put it past the
// image's end check, so the link must fail (--orphan-handling=error).
__attribute__((section(".stray"), used)) const unsigned stray = 1;
