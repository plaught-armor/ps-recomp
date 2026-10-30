const int F_RECT = 1 << 0, F_TEXTURED = 1 << 1, F_RAW = 1 << 2, F_SEMI = 1 << 3,
	F_GOURAUD = 1 << 4, F_DITHER = 1 << 5, F_DEPTH = 1 << 6, F_PERSP = 1 << 7,
	F_FLAT = 1 << 8, F_SPRITE = 1 << 9, F_SET_MASK = 1 << 10, F_CHECK_MASK = 1 << 11,
	F_SEE_ACTIVE = 1 << 12, F_SEE_DIRECT = 1 << 13, F_READ_OK = 1 << 14,
	F_FLIP_X = 1 << 15, F_FLIP_Y = 1 << 16, F_GHOST_ACC = 1 << 18, F_SMOOTH = 1 << 22,
	F_GLOW = 1 << 23, F_SMOOTH_ALL = 1 << 24, F_FOG = 1 << 25, F_Z_TEST = 1 << 26,
	F_Z_WRITE = 1 << 27, F_Z_PLANE = 1 << 28, F_Z_EXACT = 1 << 29, F_Z_DECAL = 1 << 30;
// depth_buffer.odin's Z_BIAS, Z_BIAS_SPRITE, Z_BIAS_SHIFT, Z_LIFT.
const uint Z_BIAS = 8u, Z_BIAS_SPRITE = 192u, Z_BIAS_SHIFT = 7u;
const float Z_LIFT = 4.0;
// gpu.odin's GLOW_FLOOR.
const int GLOW_FLOOR = 48;

// View depth z as a depth step (z_step).
uint z_step(float z) {
	precise float q = clamp(z * 4.0 + 0.5, 1.0, 65535.0);
	return uint(q);
}


int64_t edge(ivec2 a, ivec2 b, int64_t px, int64_t py) {
	return int64_t(b.x - a.x) * (py - int64_t(a.y)) - int64_t(b.y - a.y) * (px - int64_t(a.x));
}

// floor((w0 a0 + w1 a1 + w2 a2 + area / 2) / area), as attr_start.
int attr(int64_t w0, int64_t w1, int64_t w2, int a0, int a1, int a2, int64_t area) {
	int64_t n = w0 * int64_t(a0) + w1 * int64_t(a1) + w2 * int64_t(a2) + (area >> 1);
	int64_t q = int64_t(floor(double(n) / double(area)));
	int64_t r = n - q * area;
	if (r < 0) {
		q -= 1;
	} else if (r >= area) {
		q += 1;
	}
	return int(q);
}

// attr split for smoothing (smooth_split): the texel at or before the
// exact value, the one after, within lo ..= hi, and the place between them
// in 256ths.
ivec3 attr_split(int64_t w0, int64_t w1, int64_t w2, int a0, int a1, int a2, int64_t area, int lo, int hi) {
	int64_t n = w0 * int64_t(a0) + w1 * int64_t(a1) + w2 * int64_t(a2) + (area >> 1);
	int64_t q = int64_t(floor(double(n) / double(area)));
	int64_t r = n - q * area;
	if (r < 0) {
		q -= 1;
		r += area;
	} else if (r >= area) {
		q += 1;
		r -= area;
	}
	int64_t h = 2l * r - area;
	if (h < 0) {
		q -= 1;
		h += 2l * area;
	}
	int64_t fn = h * 128l;
	int64_t f = int64_t(floor(double(fn) / double(area)));
	int64_t fr = fn - f * area;
	if (fr < 0) {
		f -= 1;
	} else if (fr >= area) {
		f += 1;
	}
	return ivec3(clamp(int(q), lo, hi), clamp(int(q) + 1, lo, hi), int(f));
}

// persp_coord: n / d in 256ths, rounded down (gpu.odin).
int persp_coord(int64_t n, int64_t d) {
	if (d <= 0l) {
		return 0;
	}
	n *= 256l;
	if (n >= (d << 17)) {
		return 1 << 17;
	}
	if (n < -(d << 16)) {
		return -(1 << 16);
	}
	int64_t q = int64_t(floor(double(n) / double(d)));
	int64_t r = n - q * d;
	if (r < 0l) {
		q -= 1l;
	} else if (r >= d) {
		q += 1l;
	}
	return int(q);
}

// smooth_split_p: a coordinate t in 256ths split for smoothing.
ivec3 split_p(int t, int lo, int hi) {
	int q = t >> 8;
	return ivec3(clamp(q, lo, hi), clamp(q + 1, lo, hi), t & 255);
}

float smooth_step(float lo, float hi, float v) {
	precise float t = clamp((v - lo) / (hi - lo), 0.0, 1.0);
	precise float s = t * t * (3.0 - 2.0 * t);
	return s;
}

float see_cover_alpha(float x, float y, float z, float weight, bool sprite) {
	precise float near = smooth_step(see3.x, see3.y, z);
	if (weight <= 0.0 || near <= 0.0) {
		return near;
	}
	// As unproject (depth.odin): the GTE's divide stops at 0x1ffff.
	precise float k = max(z, see0.x * (65536.0 / 131071.0)) / see0.x;
	precise vec3 p = vec3((x - see0.y) * k, (y - see0.z) * k, z);
	precise float t = (p.x * see1.x + p.y * see1.y + p.z * see1.z) / see0.w;
	if (t >= see1.w) {
		return near;
	}
	t = max(t, 0.0);
	precise vec3 q = p - see1.xyz * t;
	precise float d = sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
	precise float r = max(t, see4.z);
	precise float below = -(q.x * see2.x + q.y * see2.y + q.z * see2.z) - see2.w * r;
	precise float inside = weight * (1.0 - smooth_step(see3.z * r, see3.w * r, d)) * (1.0 - smooth_step(see4.x * r, see4.y * r, below));
	vec2 g = sprite ? see5.zw : see5.xy;
	precise float ghost = g.x + (g.y - g.x) * t / see1.w;
	precise float a = min(near, 1.0 - inside * (1.0 - ghost));
	return a;
}

float see_alpha(float x, float y, float z, vec4 e, bool sprite) {
	precise float a = see_cover_alpha(x, y, z, e.x, sprite) * (1.0 - e.z);
	return a;
}

vec2 port_corner(int pi, int i) {
	vec4 c = ports[pi].corner[i >> 1];
	return (i & 1) != 0 ? c.zw : c.xy;
}

bool portal_lets(int pi, vec2 at) {
	int n = int(ports[pi].info.x);
	float turn = ports[pi].info.y;
	bool holds = n >= 3;
	for (int i = 0; i < n && holds; i++) {
		vec2 a = port_corner(pi, i);
		vec2 b = port_corner(pi, (i + 1) % n);
		precise float c = ((b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x)) * turn;
		if (c < 0.0) {
			holds = false;
		}
	}
	return holds == (ports[pi].info.z != 0.0);
}

// An 8-bit color channel, kept at 8 bits (to8).
uint to8(int c) {
	return uint(clamp(c, 0, 255));
}

uint blend(int abr, uint back, uint front) {
	ivec3 b = ivec3(back & 255u, (back >> 8) & 255u, (back >> 16) & 255u);
	ivec3 f = ivec3(front & 255u, (front >> 8) & 255u, (front >> 16) & 255u);
	ivec3 o;
	if (abr == 0) {
		o = (b + f) >> 1;
	} else if (abr == 1) {
		o = b + f;
	} else if (abr == 2) {
		o = b - f;
	} else {
		o = b + (f >> 2);
	}
	o = clamp(o, 0, 255);
	return uint(o.r) | uint(o.g) << 8 | uint(o.b) << 16 | (front & HI_MASK);
}

uint texel(Prim P, int u_in, int v_in) {
	uint tw = uint(P.m.y);
	uint mx = tw & 31u, my = (tw >> 5) & 31u, ox = (tw >> 10) & 31u, oy = (tw >> 15) & 31u;
	uint u = (uint(u_in) & 0xffu & ~(mx * 8u)) | ((ox & mx) * 8u);
	uint v = (uint(v_in) & 0xffu & ~(my * 8u)) | ((oy & my) * 8u);
	int tp = P.m.x & 3;
	if (tp == 0) {
		uint w = vfetch(P.t.x + int(u >> 2), P.t.y + int(v));
		int idx = int((w >> ((u & 3u) * 4u)) & 0xfu);
		return vfetch(P.t.z + idx, P.t.w);
	}
	if (tp == 1) {
		uint w = vfetch(P.t.x + int(u >> 1), P.t.y + int(v));
		int idx = int((w >> ((u & 1u) * 8u)) & 0xffu);
		return vfetch(P.t.z + idx, P.t.w);
	}
	return vfetch(P.t.x + int(u), P.t.y + int(v));
}

// The four texels s (u0, u1, v0, v1) names mixed by weights f, as a hi-res
// pixel (smooth_texel).
uint smooth_texel(Prim P, ivec4 s, ivec2 f, uint near) {
	uint q[4] = uint[4](texel(P, s.x, s.z), texel(P, s.y, s.z), texel(P, s.x, s.w), texel(P, s.y, s.w));
	uint o = (near & 0x8000u) << 16;
	for (int i = 0; i < 3; i++) {
		int c[4];
		for (int j = 0; j < 4; j++) {
			uint t = q[j] == 0u ? near : q[j];
			c[j] = int((t >> (5 * i)) & 31u) << 3;
		}
		int top = c[0] * (256 - f.x) + c[1] * f.x;
		int bottom = c[2] * (256 - f.x) + c[3] * f.x;
		o |= uint((top * (256 - f.y) + bottom * f.y + 32768) >> 16) << (16 - 8 * i);
	}
	return o;
}

void main() {
	Prim P = prims[pid];
	int fl = P.h.x;
	if (zpass != 0 && (fl & F_Z_WRITE) == 0) {
		discard;
	}
	ivec2 xy = ivec2(gl_FragCoord.xy);
	int x = xy.x, y = xy.y;
	int r, g, b, u = 0, v = 0;
	float z = 0.0;
	bool soft = false;
	ivec4 su;
	ivec2 sf;
	ivec2 sp = ivec2(0);
	if ((fl & F_RECT) == 0) {
		int st = 16 >> k;
		ivec2 p0 = P.a.xy, p1 = P.a.zw, p2 = P.b.xy;
		int64_t px = int64_t(x * st), py = int64_t(y * st);
		int64_t w0 = edge(p1, p2, px, py);
		int64_t w1 = edge(p2, p0, px, py);
		int64_t w2 = edge(p0, p1, px, py);
		int64_t b0 = (fl & (1 << 19)) != 0 ? -1l : 0l;
		int64_t b1 = (fl & (1 << 20)) != 0 ? -1l : 0l;
		int64_t b2 = (fl & (1 << 21)) != 0 ? -1l : 0l;
		if (w0 + b0 < 0l || w1 + b1 < 0l || w2 + b2 < 0l) {
			discard;
		}
		int64_t area = edge(p0, p1, int64_t(p2.x), int64_t(p2.y));
		int64_t o = int64_t(st / 2 - 8);
		int64_t a0 = w0 + o * int64_t((p2.x - p1.x) - (p2.y - p1.y));
		int64_t a1 = w1 + o * int64_t((p0.x - p2.x) - (p0.y - p2.y));
		int64_t a2 = w2 + o * int64_t((p1.x - p0.x) - (p1.y - p0.y));
		ivec3 c0 = ivec3(P.b.z & 255, (P.b.z >> 8) & 255, (P.b.z >> 16) & 255);
		// Laying down depths needs no colour or smoothing.
		if ((fl & F_GOURAUD) != 0 && zpass == 0) {
			ivec3 c1 = ivec3(P.b.w & 255, (P.b.w >> 8) & 255, (P.b.w >> 16) & 255);
			ivec3 c2 = ivec3(P.c.x & 255, (P.c.x >> 8) & 255, (P.c.x >> 16) & 255);
			r = attr(a0, a1, a2, c0.r, c1.r, c2.r, area);
			g = attr(a0, a1, a2, c0.g, c1.g, c2.g, area);
			b = attr(a0, a1, a2, c0.b, c1.b, c2.b, area);
		} else {
			r = c0.r;
			g = c0.g;
			b = c0.b;
		}
		ivec3 us = ivec3(P.c.y & 255, P.c.z & 255, P.c.w & 255);
		ivec3 vs = ivec3((P.c.y >> 8) & 255, (P.c.z >> 8) & 255, (P.c.w >> 8) & 255);
		// Mapped with perspective, u and v come below.
		if ((fl & F_TEXTURED) != 0 && (fl & (F_DEPTH | F_PERSP)) != (F_DEPTH | F_PERSP)) {
			u = attr(a0, a1, a2, us.x, us.y, us.z, area);
			v = attr(a0, a1, a2, vs.x, vs.y, vs.z, area);
		}
		if ((fl & F_DEPTH) != 0) {
			precise float fa = float(area);
			precise float iz = (float(w0) / P.z.x + float(w1) / P.z.y + float(w2) / P.z.z) / fa;
			z = iz > 0.0 ? 1.0 / iz : 0.0;
			if ((fl & F_PERSP) != 0) {
				int64_t q0 = (a0 >> P.w.w) * int64_t(P.w.x);
				int64_t q1 = (a1 >> P.w.w) * int64_t(P.w.y);
				int64_t q2 = (a2 >> P.w.w) * int64_t(P.w.z);
				int64_t pd = q0 + q1 + q2;
				sp = ivec2(persp_coord(q0 * int64_t(us.x) + q1 * int64_t(us.y) + q2 * int64_t(us.z), pd),
					persp_coord(q0 * int64_t(vs.x) + q1 * int64_t(vs.y) + q2 * int64_t(vs.z), pd));
				u = clamp((sp.x + 128) >> 8, min(us.x, min(us.y, us.z)), max(us.x, max(us.y, us.z)));
				v = clamp((sp.y + 128) >> 8, min(vs.x, min(vs.y, vs.z)), max(vs.x, max(vs.y, vs.z)));
			}
		}
		if ((fl & F_READ_OK) != 0) {
			u = clamp(u, (P.m.z << 16) >> 16, P.m.z >> 16);
			v = clamp(v, (P.m.w << 16) >> 16, P.m.w >> 16);
		}
		if ((fl & (F_SMOOTH | F_TEXTURED)) == (F_SMOOTH | F_TEXTURED) && zpass == 0) {
			ivec4 lo = ivec4(min(us.x, min(us.y, us.z)), max(us.x, max(us.y, us.z)),
				min(vs.x, min(vs.y, vs.z)), max(vs.x, max(vs.y, vs.z)));
			if ((fl & F_READ_OK) != 0) {
				lo = ivec4((P.m.z << 16) >> 16, P.m.z >> 16, (P.m.w << 16) >> 16, P.m.w >> 16);
			}
			ivec3 a, c;
			if ((fl & F_PERSP) != 0) {
				a = split_p(sp.x, lo.x, lo.y);
				c = split_p(sp.y, lo.z, lo.w);
			} else {
				a = attr_split(a0, a1, a2, us.x, us.y, us.z, area, lo.x, lo.y);
				c = attr_split(a0, a1, a2, vs.x, vs.y, vs.z, area, lo.z, lo.w);
			}
			su = ivec4(a.xy, c.xy);
			sf = ivec2(a.z, c.z);
			soft = true;
		}
	} else {
		r = P.b.z & 255;
		g = (P.b.z >> 8) & 255;
		b = (P.b.z >> 16) & 255;
		int du = (fl & F_FLIP_X) != 0 ? -1 : 1;
		int dv = (fl & F_FLIP_Y) != 0 ? -1 : 1;
		u = P.a.z + ((x >> k) - P.a.x) * du;
		v = P.a.w + ((y >> k) - P.a.y) * dv;
	}
	// plot
	uint dst = 0u;
	bool have = false;
	if ((fl & F_CHECK_MASK) != 0) {
		dst = main_at(xy);
		have = true;
		if ((dst & HI_MASK) != 0u) {
			discard;
		}
	}
	precise float unit = 1.0 / float(1 << k);
	precise float sx = float(x) * unit - float(P.h.y);
	precise float sy = float(y) * unit - float(P.h.z);
	if (P.h.w >= 0 && !portal_lets(P.h.w, vec2(sx + 0.5 * unit, sy + 0.5 * unit))) {
		discard;
	}
	// The depth buffer (plot, z_test).
	uint zw = 0u;
	if ((fl & F_Z_TEST) != 0) {
		float zd = z;
		if ((fl & F_Z_PLANE) != 0) {
			precise float iz = max(intBitsToFloat(P.w.x) * sy + intBitsToFloat(P.w.y), intBitsToFloat(P.w.z));
			zd = iz > 0.0 ? 1.0 / iz : 0.0;
		}
		if ((fl & F_Z_DECAL) != 0) {
			zd = max(zd - Z_LIFT, 0.5 * zd);
		}
		if (zd > 0.0) {
			uint key = uint(P.e.y) << 16;
			zw = key | z_step(zd);
			uint s = z_at(xy);
			uint d = s & 0xffffu;
			bool sprite = (fl & F_Z_PLANE) != 0;
			if (zpass == 0 && (s >> 16) == (key >> 16) &&
				(zw & 0xffffu) > d + (sprite ? Z_BIAS_SPRITE : Z_BIAS) + ((fl & F_Z_EXACT) != 0 ? 0u : d >> Z_BIAS_SHIFT)) {
				discard;
			}
		}
	}
	bool see_active = (fl & F_SEE_ACTIVE) != 0;
	float alpha = 1.0;
	if (z > 0.0 && see_active) {
		alpha = see_alpha(sx, sy, z, P.e, (fl & F_SPRITE) != 0);
		if (alpha <= 0.0) {
			discard;
		}
	}
	bool semi = (fl & F_SEMI) != 0;
	// Laying down depths: only solid pixels drawn in full, after the texel
	// (below) when textured.
	if (zpass != 0 && (alpha < 1.0 || (fl & F_TEXTURED) == 0)) {
		if (alpha >= 1.0 && !semi && zw != 0u) {
			z_min(xy, zw);
		}
		discard;
	}
#ifdef INTERLOCK
	// In queue order (draw.frag's interlock): a solid pixel drawn in full
	// lays its depth as it draws, as the software target's z_write.
	if ((fl & (F_Z_WRITE | F_TEXTURED)) == F_Z_WRITE && alpha >= 1.0 && !semi && zw != 0u) {
		z_min(xy, zw);
	}
#endif
	if (!have && (alpha < 1.0 || semi)) {
		dst = main_at(xy);
	}
	uint under = dst;
	bool ghost = false;
	if (alpha < 1.0 && (fl & F_FLAT) != 0) {
		uvec2 gv = ghost_at(xy);
		uint ga = gv.x >> 24;
		if (ga != 0u && uintBitsToFloat(gv.y) > z) {
			ghost_put(xy, uvec2(gv.x & 0xffffffu, gv.y));
			under = fade_mix(under, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | under & HI_KEPT;
		}
	} else if (alpha < 1.0 && (fl & F_SEE_DIRECT) == 0) {
		uvec2 gv = ghost_at(xy);
		if ((gv.x >> 24) == 0u) {
			dst = under;
		} else if (z > uintBitsToFloat(gv.y)) {
			discard;
		} else {
			dst = gv.x & 0xffffffu;
		}
		ghost = true;
	}
	uint c;
	if ((fl & F_TEXTURED) != 0) {
		uint tx = texel(P, u, v);
		if (tx == 0u) {
			discard;
		}
		semi = semi && (tx & 0x8000u) != 0u;
		if (zpass != 0) {
			if (!semi && zw != 0u) {
				z_min(xy, zw);
			}
			discard;
		}
#ifdef INTERLOCK
		if ((fl & F_Z_WRITE) != 0 && alpha >= 1.0 && !semi && zw != 0u) {
			z_min(xy, zw);
		}
#endif
		uint t8;
		if (soft && (semi || (fl & F_SMOOTH_ALL) != 0)) {
			int sk = int(P.e.w);
			if (sk > 0) {
				sk <<= k;
				sf = clamp(((sf - 128) * sk >> 8) + 128, 0, 256);
			}
			t8 = smooth_texel(P, su, sf, tx);
		} else {
			t8 = hi(tx);
		}
		// A filed sprite's additive texels less GLOW_FLOOR (glow_floor).
		if (semi && (fl & F_FLAT) != 0 && ((P.m.x >> 2) & 3) == 1) {
			uint o = t8 & HI_MASK;
			for (int i = 0; i < 3; i++) {
				o |= uint(max(int((t8 >> (8 * i)) & 255u) - GLOW_FLOOR, 0)) << (8 * i);
			}
			t8 = o;
		}
		if ((fl & F_RAW) != 0) {
			c = t8;
		} else {
			uint cr = to8((int((t8 >> 16) & 255u) * r) >> 7);
			uint cg = to8((int((t8 >> 8) & 255u) * g) >> 7);
			uint cb = to8((int(t8 & 255u) * b) >> 7);
			c = cr << 16 | cg << 8 | cb | t8 & HI_MASK;
		}
	} else {
		c = to8(r) << 16 | to8(g) << 8 | to8(b);
	}
	// Distance fog (fog_mix).
	if ((fl & F_FOG) != 0 && z > 0.0 && !semi) {
		precise float ft = clamp((z - fog0.x) * fog0.y, 0.0, 1.0);
		precise float fw = ft * fog0.z;
		int w = int(fw);
		if (w > 0) {
			uint o = c & HI_MASK;
			for (int i = 0; i < 3; i++) {
				int a = int((c >> (8 * i)) & 255u), b = int((fog_c >> (8 * i)) & 255u);
				o |= uint((a * (256 - w) + b * w + 128) >> 8) << (8 * i);
			}
			c = o;
		}
	}
	// A pixel without depth drawn after a ghost: the ghost is laid down
	// under it (ghost_settle).
	if (z <= 0.0 && see_active && (fl & F_GHOST_ACC) != 0 && (fl & F_SEE_DIRECT) == 0) {
		uvec2 gv = ghost_at(xy);
		uint ga = gv.x >> 24;
		if (ga != 0u) {
			ghost_put(xy, uvec2(gv.x & 0xffffffu, gv.y));
			if (semi) {
				dst = fade_mix(dst, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | dst & HI_KEPT;
			}
		}
	}
	if (semi) {
		c = blend((P.m.x >> 2) & 3, dst, c);
		if ((fl & F_GLOW) != 0 && ((P.m.x >> 2) & 3) == 1) {
			c |= HI_GLOW;
		}
	}
	if ((fl & F_SET_MASK) != 0) {
		c |= HI_MASK;
	}
	if (ghost) {
		precise float fa = max(1.0, alpha * 255.0);
		ghost_put(xy, uvec2(c & 0xffffffu | uint(fa) << 24, floatBitsToUint(z)));
		discard;
	}
	if (alpha < 1.0) {
		c = fade_mix(under, c, alpha);
	} else if (z > 0.0 && see_active && (fl & F_GHOST_ACC) != 0) {
		uvec2 gv = ghost_at(xy);
		if ((gv.x >> 24) != 0u && uintBitsToFloat(gv.y) > z) {
			ghost_put(xy, uvec2(gv.x & 0xffffffu, gv.y));
		}
	}
	out_c = c & ~HI_DEPTH | (semi ? dst & HI_DEPTH : depth_bits(z));
	out_tag = (uint(P.m.x) >> 16) << 8 | ((uint(P.m.x) >> 8) & 255u);
}
