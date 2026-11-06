// The C library calls clang may emit in a mod's code (struct copies and
// clears), built into every mod by mods/build.sh: a mod must not call into
// the game for them.
typedef __SIZE_TYPE__ size_t;

void *memcpy(void *dst, const void *src, size_t n) {
	unsigned char *d = dst;
	const unsigned char *s = src;
	while (n--) *d++ = *s++;
	return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
	unsigned char *d = dst;
	const unsigned char *s = src;
	if (d < s) {
		while (n--) *d++ = *s++;
	} else {
		while (n--) d[n] = s[n];
	}
	return dst;
}

void *memset(void *dst, int c, size_t n) {
	unsigned char *d = dst;
	while (n--) *d++ = (unsigned char)c;
	return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
	const unsigned char *x = a, *y = b;
	for (; n--; x++, y++) {
		if (*x != *y) return *x - *y;
	}
	return 0;
}
