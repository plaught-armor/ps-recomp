// The GPU GS: local memory lives in a GPU buffer, one copy per subsample of
// the upscaled image, and every primitive runs the per-pixel pipeline of
// draw.odin in a fragment shader (shaders/prim.frag) that reads and writes
// that memory directly, ordered by pixel interlock. Transfers are unpacked
// on the CPU (mem.odin keeps its own copy of local memory for CLUT loads)
// and stored on the GPU by compute dispatches.
//
// Commands are recorded as the GS sees them into one of two frame slots;
// each vblank submits the slot with the read circuit's output.
package ps2_gs

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import sdl "vendor:sdl2"
import vk "vendor:vulkan"
import "ps:core"

// Set by hw_init: draws, transfers and scanout go to the GPU.
hw_on: bool

@(private)
VERT_CAP :: 1 << 18 // vertices per slot (16 MiB)
@(private)
STATE_CAP :: 1 << 14
@(private)
CLUT_CAP :: 1 << 10 // CLUT copies of 512 words
@(private)
UP_CAP :: 1 << 22 // transfer words per slot (16 MiB)
@(private)
PAGES :: 512 // 8 KiB pages of local memory
@(private)
CONST_Z :: 0x8000_0000 // Hw_Vert.state: z is the same at every vertex
@(private)
DEC_WORDS :: 1 << 24 // decoded texture words, all layers (64 MiB)
@(private)
DEC_FIRST :: 16 // offset 0 means no decoded texture

// Layouts of Vert and State in shaders/draw.glsl.
@(private)
Hw_Vert :: struct {
	x, y, zf:    f32,
	zi:          u32,
	c:           [4]f32,
	s, t, q, fog: f32,
	state:       u32,
	st_min:      [2]f32, // texels: see uv_clamp; open when it doesn't apply
	st_max:      [2]f32,
	_:           [3]u32,
}
#assert(size_of(Hw_Vert) == 80)

@(private)
Hw_State :: struct {
	fbp, fbw, fpsm, fbmsk:                   u32,
	zbp, zpsm, flags:                        u32,
	sx0, sx1, sy0, sy1:                      u32,
	atst, aref, afail, ztst:                 u32,
	blend, fix, fogcol:                      u32,
	tbp, tbw, tpsm, tw, th, tfx, cpsm, csa:  u32,
	wrap, umm, vmm, ta, clut:                u32,
	mip:                                     u32, // LCM | MXL << 1 | MMIN << 4 | L << 7 | K << 16
	mtb:                                     [6]u32, // levels 1..6: TBP | TBW << 16
	dec, dec_ls:                             u32, // see hw_dec: offset in hw.dec (0: none), words per layer
}
#assert(size_of(Hw_State) == 160)

@(private)
Hw_Flag :: enum u32 {TME, FGE, ABE, FST, ATE, DATE, DATM, ZTE, ZMSK, PABE, FBA, COLCLAMP, TCC, BILINEAR, AEM}

// Push constants, as declared by each shader.
@(private)
Draw_PC :: struct {
	vram, states, cluts, verts, dec: vk.DeviceAddress,
	scale:                           u32,
}
@(private)
Upload_PC :: struct {
	vram, data:                                vk.DeviceAddress,
	psm, bp, bw, x0, y0, w, start, count, layers: u32,
}
@(private)
Copy_PC :: struct {
	vram:                                                       vk.DeviceAddress,
	sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h, layers: u32,
}
@(private)
Clut_PC :: struct {
	vram, cur, outp:                            vk.DeviceAddress,
	cpsm, cbp, cbw, cou, cov, csm2, n, base: u32,
}
@(private)
Decode_PC :: struct {
	vram, outp:                             vk.DeviceAddress,
	psm, ta, aem, tw, th, nlev, stride: u32,
	tb:                                     [7]u32,
}
@(private)
Scan_PC :: struct {
	vram, outp:                         vk.DeviceAddress,
	psm, fbp, fbw, dbx, dby, w, h, scale: u32,
}

@(private)
Slot :: struct {
	cmd:                           vk.CommandBuffer,
	fence:                         vk.Fence,
	acquire:                       vk.Semaphore,
	verts, states, cluts, up, scan: core.Vk_Buf,
	nverts, nstates, ncluts, nup:  int,
	scan_w, scan_h:                int,
}

@(private)
Page_Set :: [PAGES / 64]u64

// A decoded texture: the texels decode.comp writes, Decode_PC's fields.
@(private)
Dec_Key :: struct {
	psm, ta, aem, tw, th, nlev: u32,
	tb:                         [7]u32,
}
@(private)
Dec_Entry :: struct {
	off, stride: u32,
	seq:         u64, // hw.seq when decoded
}

@(private)
hw: struct {
	scale:               u32,
	window:              bool,
	slots:               [2]Slot,
	cur:                 int,
	vram:                core.Vk_Buf,
	down:                core.Vk_Buf, // host copy of vram's first layer, for hw_download
	draw_layout:         vk.PipelineLayout,
	comp_layout:         vk.PipelineLayout,
	prim, upload, copy:  vk.Pipeline,
	scan, clut, decode:  vk.Pipeline,
	clut_cur:            core.Vk_Buf, // the CLUT as the last load left it
	out_img:             vk.Image,
	out_mem:             vk.DeviceMemory,
	rendering:           bool, // inside vkCmdBeginRendering
	barrier_due:         bool, // a memory barrier must precede the next command
	batch:               int, // first vertex not yet drawn
	// The union of the GS scissors of the vertices since batch, in GS
	// pixels (x0, y0, x1, y1 inclusive); empty while x1 < x0.
	clip:                [4]i32,
	state:               Hw_State, // last state appended
	state_idx:           u32,
	state_ok:            bool, // state is in this slot's ring
	clut_off:            u32, // the CLUT's copy in the slot's ring
	clut_ok:             bool,
	// Pages drawn since the last barrier; a primitive texturing from one
	// must wait for the barrier. Pixel interlock orders fragments by
	// framebuffer pixel, not by address, so a page drawn through a different
	// buffer layout (base, width, format) must wait for it too: owner holds
	// the layout key each dirty page was drawn through.
	dirty:               Page_Set,
	owner:               [PAGES]u32,
	fb_key, z_key:       u32,
	fb_marked:           bool, // the current state's frame/depth pages are in dirty
	tex_ok:              bool, // the current state's texture misses dirty
	fb_pages, z_pages:   [2]u32, // first page, count
	tex_pages:           [2]u32,
	// Writes to local memory in command order: seq counts them and page_seq
	// holds the last to write each page. A decoded texture is valid while no
	// page of its span has been written since it was decoded.
	seq:                 u64,
	page_seq:            [PAGES]u64,
	// Decoded textures, allocated upward from DEC_FIRST in dec and all
	// dropped when it fills. Writes to them are ordered by the same barriers
	// as local memory, so an entry is rewritten in place.
	dec:                 core.Vk_Buf,
	dec_map:             map[Dec_Key]Dec_Entry,
	dec_top:             u32,
	dec_seq:             u64, // seq when the current state's texture was looked up
	// The transfer being gathered into one dispatch.
	up:                  struct {
		active:                                bool,
		psm, bp, bw, x0, y0, w, start, count: u32,
		first:                                 int, // index in the slot's ring
	},
}

// Start the Vulkan GS: false, reported, when there is no device that will
// do; a later failure ends the game (core's helpers).
hw_init :: proc(win: ^sdl.Window, scale: u32) -> bool {
	hw.scale, hw.window = scale, win != nil
	exts: [dynamic]cstring
	if win != nil {
		n: u32
		sdl.Vulkan_GetInstanceExtensions(win, &n, nil)
		resize(&exts, int(n))
		sdl.Vulkan_GetInstanceExtensions(win, &n, raw_data(exts))
	}
	if !core.vk_instance(exts[:]) {return false}
	if win != nil && !sdl.Vulkan_CreateSurface(win, core.vkc.instance, &core.vkc.surface) {
		fmt.eprintln("vulkan: SDL_Vulkan_CreateSurface:", sdl.GetError())
		core.vk_release()
		return false
	}
	if !core.vk_device(pixel_interlock = true) {return false}
	hw_on = true
	if win != nil {swap_create()}

	layers := int(scale * scale)
	hw.vram = core.vk_buf_create(layers * VRAM_WORDS * 4, {.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}, {.DEVICE_LOCAL})
	hw.clut_cur = core.vk_buf_create(512 * 4, {.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}, {.DEVICE_LOCAL})
	hw.dec = core.vk_buf_create(DEC_WORDS * 4, {.STORAGE_BUFFER}, {.DEVICE_LOCAL})
	hw.dec_top = DEC_FIRST
	RING :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
	READBACK :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED}
	scan_size := DISP_W * DISP_H * layers * 4
	for &s in hw.slots {
		s.verts = core.vk_buf_create(VERT_CAP * size_of(Hw_Vert), {.STORAGE_BUFFER}, RING)
		s.states = core.vk_buf_create(STATE_CAP * size_of(Hw_State), {.STORAGE_BUFFER}, RING)
		s.cluts = core.vk_buf_create(CLUT_CAP * 512 * 4, {.STORAGE_BUFFER}, RING)
		s.up = core.vk_buf_create(UP_CAP * 4, {.STORAGE_BUFFER}, RING)
		s.scan = core.vk_buf_create(scan_size, {.STORAGE_BUFFER, .TRANSFER_SRC}, READBACK)
		s.cmd, s.fence = core.vk_cmd_create()
		sinfo := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		core.vk_check(vk.CreateSemaphore(core.vkc.device, &sinfo, nil, &s.acquire), "vkCreateSemaphore")
	}
	if win != nil {
		hw.out_img, hw.out_mem = core.vk_image_create(DISP_W * scale, DISP_H * scale, .R8G8B8A8_UNORM, {.TRANSFER_SRC, .TRANSFER_DST})
	}

	hw.draw_layout = core.vk_layout_create({.VERTEX, .FRAGMENT}, size_of(Draw_PC))
	hw.comp_layout = core.vk_layout_create({.COMPUTE}, 128)
	hw.prim = core.vk_draw_pipeline(#load("shaders/prim.vert.spv"), #load("shaders/prim.frag.spv"), hw.draw_layout)
	hw.upload = core.vk_compute_pipeline(#load("shaders/upload.comp.spv"), hw.comp_layout)
	hw.copy = core.vk_compute_pipeline(#load("shaders/copy.comp.spv"), hw.comp_layout)
	hw.scan = core.vk_compute_pipeline(#load("shaders/scanout.comp.spv"), hw.comp_layout)
	hw.clut = core.vk_compute_pipeline(#load("shaders/clut.comp.spv"), hw.comp_layout)
	hw.decode = core.vk_compute_pipeline(#load("shaders/decode.comp.spv"), hw.comp_layout)

	hw_begin_slot()
	vk.CmdFillBuffer(hw.slots[0].cmd, hw.vram.buf, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
	vk.CmdFillBuffer(hw.slots[0].cmd, hw.clut_cur.buf, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
	fmt.eprintfln("gs: GPU renderer, scale %d", scale)
	return true
}

// ------------------------------------------------------------- commands

@(private)
hw_barrier :: proc(cmd: vk.CommandBuffer) {
	core.vk_barrier(cmd)
	hw.dirty = {}
	hw.fb_marked, hw.tex_ok = false, false
}

@(private)
hw_begin_slot :: proc() {
	s := &hw.slots[hw.cur]
	core.vk_begin(s.cmd, s.fence)
	s.nverts, s.nstates, s.ncluts, s.nup = 0, 0, 0, 0
	hw.batch = 0
	hw.clip = CLIP_EMPTY
	hw.state_ok, hw.clut_ok = false, false
	hw.rendering = false
	hw.barrier_due = true // orders this slot after the previous one
}

@(private)
hw_end_render :: proc() {
	if hw.rendering {
		vk.CmdEndRendering(hw.slots[hw.cur].cmd)
		hw.rendering = false
	}
}

// Record the vertices gathered since the last flush as one draw.
@(private)
hw_flush_draws :: proc() {
	s := &hw.slots[hw.cur]
	n := s.nverts - hw.batch
	if n == 0 {return}
	if !hw.rendering {
		if hw.barrier_due {
			hw_barrier(s.cmd)
			hw.barrier_due = false
		}
		size := 2048 * hw.scale
		info := vk.RenderingInfo {
			sType      = .RENDERING_INFO,
			renderArea = {extent = {size, size}},
			layerCount = 1,
		}
		vk.CmdBeginRendering(s.cmd, &info)
		vk.CmdBindPipeline(s.cmd, .GRAPHICS, hw.prim)
		vp := vk.Viewport{0, 0, f32(size), f32(size), 0, 1}
		vk.CmdSetViewport(s.cmd, 0, 1, &vp)
		pc := Draw_PC{hw.vram.addr, s.states.addr, s.cluts.addr, s.verts.addr, hw.dec.addr, hw.scale}
		vk.CmdPushConstants(s.cmd, hw.draw_layout, {.VERTEX, .FRAGMENT}, 0, size_of(pc), &pc)
		hw.rendering = true
	}
	// The fragment shader tests the GS scissor exactly; the Vulkan scissor
	// only keeps the rasterizer from running it on fragments outside every
	// scissor of the draw. A primitive reaching past them (one crossing the
	// camera plane spans the whole render area) costs nothing there.
	// Emptiness is tested in GS pixels, before CLIP_EMPTY could be scaled.
	if hw.clip[2] >= hw.clip[0] && hw.clip[3] >= hw.clip[1] {
		sc, size := i64(hw.scale), i64(2048 * hw.scale)
		x0, y0 := clamp(i64(hw.clip[0]) * sc, 0, size), clamp(i64(hw.clip[1]) * sc, 0, size)
		x1, y1 := clamp((i64(hw.clip[2]) + 1) * sc, 0, size), clamp((i64(hw.clip[3]) + 1) * sc, 0, size)
		if x1 > x0 && y1 > y0 { // else no pixel passes the shader's test
			r := vk.Rect2D{{i32(x0), i32(y0)}, {u32(x1 - x0), u32(y1 - y0)}}
			vk.CmdSetScissor(s.cmd, 0, 1, &r)
			vk.CmdDraw(s.cmd, u32(n), 1, u32(hw.batch), 0)
		}
	}
	hw.batch = s.nverts
	hw.clip = CLIP_EMPTY
}

@(private)
CLIP_EMPTY :: [4]i32{max(i32), max(i32), min(i32), min(i32)}

// Make every draw so far visible to the commands after.
@(private)
hw_split :: proc() {
	hw_flush_draws()
	hw_end_render()
	hw.barrier_due = true
	hw.dirty = {}
	hw.fb_marked, hw.tex_ok = false, false
}

@(private)
hw_dispatch :: proc(p: vk.Pipeline, pc: ^$T, gx, gy: u32) where size_of(T) <= 128 {
	hw_flush_draws()
	hw_end_render()
	cmd := hw.slots[hw.cur].cmd
	hw_barrier(cmd)
	vk.CmdBindPipeline(cmd, .COMPUTE, p)
	vk.CmdPushConstants(cmd, hw.comp_layout, {.COMPUTE}, 0, size_of(T), pc)
	vk.CmdDispatch(cmd, gx, gy, 1)
	hw.barrier_due = true
}

@(private)
hw_flush_upload :: proc() {
	u := &hw.up
	if !u.active {return}
	u.active = false
	s := &hw.slots[hw.cur]
	pc := Upload_PC {
		vram   = hw.vram.addr,
		data   = s.up.addr + vk.DeviceAddress(u.first * 4),
		psm    = u.psm,
		bp     = u.bp,
		bw     = u.bw,
		x0     = u.x0,
		y0     = u.y0,
		w      = u.w,
		start  = u.start,
		count  = u.count,
		layers = hw.scale * hw.scale,
	}
	pages_write(rect_pages(u.psm, u.bp, u.bw, u.x0, u.y0 + u.start / u.w, u.w, (u.start + u.count - 1) / u.w - u.start / u.w + 1))
	hw_dispatch(hw.upload, &pc, (u.count + 63) / 64, 1)
}

@(private)
hw_submit :: proc(wait, signal: vk.Semaphore) {
	s := &hw.slots[hw.cur]
	core.vk_submit(s.cmd, s.fence, wait, signal)
}

// A ring is full: run what the slot holds and start it again.
@(private)
hw_overflow :: proc() {
	hw_flush_upload()
	hw_flush_draws()
	hw_end_render()
	hw_submit(0, 0)
	hw_begin_slot()
}

// ------------------------------------------------------------ transfers

// Copy local memory's first sample layer back into vram for a local-to-host
// transfer: runs the slot so far and waits for it.
hw_download :: proc() {
	size :: VRAM_WORDS * 4
	if hw.down.size == 0 {
		hw.down = core.vk_buf_create(size, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED})
	}
	hw_flush_upload()
	hw_flush_draws()
	hw_end_render()
	s := &hw.slots[hw.cur]
	hw_barrier(s.cmd)
	r := vk.BufferCopy{0, 0, size}
	vk.CmdCopyBuffer(s.cmd, hw.vram.buf, hw.down.buf, 1, &r)
	hw_submit(0, 0)
	vk.WaitForFences(core.vkc.device, 1, &s.fence, true, max(u64))
	copy(mem.ptr_to_bytes(&vram), hw.down.ptr[:size])
	hw_begin_slot()
}

// Pixels `start` onward of the host-to-local transfer (psm, bp, bw, x0, y0,
// w), already unpacked to one word each.
@(private)
hw_upload :: proc(psm, bp, bw, x0, y0, w, start: u32, px: []u32) {
	px, start := px, start
	for len(px) > 0 {
		s := &hw.slots[hw.cur]
		if s.nup == UP_CAP {
			hw_overflow()
			continue
		}
		u := &hw.up
		if !(u.active && u.psm == psm && u.bp == bp && u.bw == bw && u.x0 == x0 && u.y0 == y0 && u.w == w &&
			   u.start + u.count == start && u.first + int(u.count) == s.nup) {
			hw_flush_upload()
			u^ = {true, psm, bp, bw, x0, y0, w, start, 0, s.nup}
		}
		n := min(len(px), UP_CAP - s.nup)
		mem.copy(&([^]u32)(s.up.ptr)[s.nup], raw_data(px), n * 4)
		s.nup += n
		u.count += u32(n)
		start += u32(n)
		px = px[n:]
	}
}

@(private)
hw_copy :: proc(sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h: u32) {
	if w == 0 || h == 0 {return}
	hw_flush_upload()
	pc := Copy_PC{hw.vram.addr, sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h, hw.scale * hw.scale}
	pages_write(rect_pages(dpsm, dbp, dbw, dx, dy, w, h))
	hw_dispatch(hw.copy, &pc, (w + 7) / 8, (h + 7) / 8)
}

// CLUT load: entries base..base+n from local memory, as `clut_load` reads
// them, then the whole CLUT into the slot's ring for the primitives after.
// n = 0 only brings the CLUT into a new slot.
@(private)
hw_clut :: proc(cpsm, cbp, cbw, cou, cov: u32, csm2: bool, n, base: u32) {
	if hw.slots[hw.cur].ncluts == CLUT_CAP {hw_overflow()}
	s := &hw.slots[hw.cur]
	hw_flush_upload()
	hw.clut_off = u32(s.ncluts * 512)
	s.ncluts += 1
	hw.clut_ok = true
	pc := Clut_PC {
		vram = hw.vram.addr,
		cur  = hw.clut_cur.addr,
		outp = s.cluts.addr + vk.DeviceAddress(hw.clut_off * 4),
		cpsm = cpsm,
		cbp  = cbp,
		cbw  = cbw,
		cou  = cou,
		cov  = cov,
		csm2 = u32(csm2),
		n    = n,
		base = base,
	}
	hw_dispatch(hw.clut, &pc, 512 / 64, 1)
}

// ----------------------------------------------------------- primitives

// Pages holding rows y0..y1 of a buffer at block `bp`, `bw` 64-pixel units
// wide; a superset, for hazard tracking.
@(private)
page_span :: proc(psm, bp, bw, y0, y1: u32) -> [2]u32 {
	pw, ph: u32 = 64, 32
	switch psm_bits(psm) {
	case 16: ph = 64
	case 8: pw, ph = 128, 64
	case 4:
		if psm == PSMT4 {pw, ph = 128, 128}
	}
	if psm == PSMT8H || psm == PSMT4HL || psm == PSMT4HH {pw, ph = 64, 32}
	per_row := max(bw * 64 / pw, 1)
	first := bp / 32 + (y0 / ph) * per_row
	n := (y1 / ph - y0 / ph + 1) * per_row + 1 // +1: bp need not be page-aligned
	return {first, min(n, PAGES)}
}

// Pages of every level the texture can sample, as one span.
@(private)
tex_span :: proc(t: ^Tex) -> [2]u32 {
	span := page_span(t.psm, t.tbp, t.tbw, 0, t.h - 1)
	if t.mmin < 2 {return span}
	lo, hi := span[0], span[0] + span[1]
	for n in 1 ..= t.mxl {
		l := page_span(t.psm, t.mtbp[n], t.mtbw[n], 0, max(t.h >> n, 1) - 1)
		lo, hi = min(lo, l[0]), max(hi, l[0] + l[1])
	}
	return {lo, min(hi - lo, PAGES)}
}

// Pages a transfer of h rows from (x0, y0), w wide, writes; every page when
// it wraps past the buffer's width or local memory's last row.
@(private)
rect_pages :: proc(psm, bp, bw, x0, y0, w, h: u32) -> [2]u32 {
	if x0 + w > bw * 64 || y0 + h > 2048 {return {0, PAGES}}
	return page_span(psm, bp, bw, y0, y0 + h - 1)
}

// Record a write to the pages of span (see hw.seq).
@(private)
pages_write :: proc(span: [2]u32) {
	hw.seq += 1
	for i in 0 ..< span[1] {hw.page_seq[(span[0] + i) % PAGES] = hw.seq}
}

// The last write to a page of span.
@(private)
pages_seq :: proc(span: [2]u32) -> (seq: u64) {
	for i in 0 ..< span[1] {seq = max(seq, hw.page_seq[(span[0] + i) % PAGES])}
	return
}

@(private)
pages_mark :: proc(set: ^Page_Set, span: [2]u32) {
	for i in 0 ..< span[1] {
		p := (span[0] + i) % PAGES
		set[p / 64] |= 1 << (p % 64)
	}
}

@(private)
pages_mark_owner :: proc(span: [2]u32, key: u32) {
	pages_mark(&hw.dirty, span)
	for i in 0 ..< span[1] {hw.owner[(span[0] + i) % PAGES] = key}
}

// A page of span is dirty from a buffer laid out other than key.
@(private)
pages_alias :: proc(span: [2]u32, key: u32) -> bool {
	for i in 0 ..< span[1] {
		p := (span[0] + i) % PAGES
		if hw.dirty[p / 64] & (1 << (p % 64)) != 0 && hw.owner[p] != key {return true}
	}
	return false
}

// The layout of a frame or depth buffer: which pixel each address holds.
// 24-bit formats share their 32-bit layout.
@(private)
layout_key :: proc(psm, bp, bw: u32) -> u32 {
	f := psm == PSMCT24 || psm == PSMZ24 ? psm - 1 : psm
	return bp | bw << 14 | f << 20
}

@(private)
pages_hit :: proc(set: ^Page_Set, span: [2]u32) -> bool {
	for i in 0 ..< span[1] {
		p := (span[0] + i) % PAGES
		if set[p / 64] & (1 << (p % 64)) != 0 {return true}
	}
	return false
}

// The decoded copy of a state's texture, decoding it now when there is no
// valid one: its offset in hw.dec and words per layer, or offset 0 to read
// local memory. Only direct-colour textures that repeat or clamp, whose
// sampled texels all lie inside each level's w x h. A texture sharing a page
// with the state's frame or depth buffer may read the state's own writes
// and is never decoded.
@(private)
hw_dec :: proc(t: ^Tex, st: ^Hw_State, fb, z, tex: [2]u32) -> (off, stride: u32) {
	switch t.psm {
	case PSMCT32, PSMCT24, PSMCT16, PSMCT16S: // the formats fetch converts directly
	case: return
	}
	if t.wms >= 2 || t.wmt >= 2 {return}
	if spans_meet(tex, fb) || spans_meet(tex, z) {return}
	k := Dec_Key{psm = t.psm, ta = st.ta, aem = u32(t.aem), tw = t.w, th = t.h, nlev = 1}
	if t.mmin >= 2 && t.mmin <= 5 {k.nlev = t.mxl + 1}
	if k.nlev > 7 {return}
	k.tb[0] = t.tbp | t.tbw << 16
	for n in 1 ..< k.nlev {k.tb[n] = st.mtb[n - 1]}
	size: u32
	for n in 0 ..< k.nlev {size += max(t.w >> n, 1) * max(t.h >> n, 1)}
	layers := hw.scale * hw.scale
	if size * layers > DEC_WORDS / 4 {return}
	e, ok := hw.dec_map[k]
	if ok && pages_seq(tex) <= e.seq {return e.off, e.stride}
	if !ok {
		if hw.dec_top + size * layers > DEC_WORDS {
			clear(&hw.dec_map)
			hw.dec_top = DEC_FIRST
		}
		e = {off = hw.dec_top, stride = size}
		hw.dec_top += size * layers
	}
	e.seq = hw.seq
	hw.dec_map[k] = e
	pc := Decode_PC {
		vram   = hw.vram.addr,
		outp   = hw.dec.addr + vk.DeviceAddress(e.off * 4),
		psm    = k.psm,
		ta     = k.ta,
		aem    = k.aem,
		tw     = k.tw,
		th     = k.th,
		nlev   = k.nlev,
		stride = size,
		tb     = k.tb,
	}
	hw_dispatch(hw.decode, &pc, (size + 63) / 64, layers)
	return e.off, e.stride
}

@(private)
spans_meet :: proc(a, b: [2]u32) -> bool {
	set: Page_Set
	pages_mark(&set, b)
	return pages_hit(&set, a)
}

// The primitive's state index, appending the state if it changed.
@(private)
hw_state :: proc(c: ^Ctx) -> u32 {
	s := &hw.slots[hw.cur]
	t := &c.tex
	f: bit_set[Hw_Flag; u32]
	if c.tme {f += {.TME}}
	if c.fge {f += {.FGE}}
	if c.abe {f += {.ABE}}
	if c.fst {f += {.FST}}
	if c.ate {f += {.ATE}}
	if c.date {f += {.DATE}}
	if c.datm {f += {.DATM}}
	if c.zte {f += {.ZTE}}
	if c.zmsk {f += {.ZMSK}}
	if c.pabe {f += {.PABE}}
	if c.fba {f += {.FBA}}
	if c.colclamp {f += {.COLCLAMP}}
	st := Hw_State {
		fbp    = c.fbp,
		fbw    = c.fbw,
		fpsm   = c.fpsm,
		fbmsk  = c.fbmsk,
		zbp    = c.zbp,
		zpsm   = c.zpsm,
		sx0    = u32(c.sx0),
		sx1    = u32(c.sx1),
		sy0    = u32(c.sy0),
		sy1    = u32(c.sy1),
		atst   = c.atst,
		aref   = c.aref,
		afail  = c.afail,
		ztst   = c.ztst,
		blend  = c.a | c.b << 2 | c.c << 4 | c.d << 6,
		fix    = c.fix,
		fogcol = u32(c.fogcol[0]) | u32(c.fogcol[1]) << 8 | u32(c.fogcol[2]) << 16,
	}
	if c.tme {
		if t.tcc {f += {.TCC}}
		if t.bilinear {f += {.BILINEAR}}
		if t.aem {f += {.AEM}}
		st.tbp, st.tbw, st.tpsm, st.tw, st.th = t.tbp, t.tbw, t.psm, t.w, t.h
		st.tfx, st.cpsm, st.csa = t.tfx, t.cpsm, t.csa
		st.wrap = t.wms | t.wmt << 2
		st.umm = t.minu | t.maxu << 16
		st.vmm = t.minv | t.maxv << 16
		st.ta = t.ta0 | t.ta1 << 8
		st.mip = u32(t.lcm) | t.mxl << 1 | t.mmin << 4 | t.l << 7 | (u32(t.k) & 0xfff) << 16
		for i in 1 ..= 6 {st.mtb[i - 1] = t.mtbp[i] | t.mtbw[i] << 16}
		if psm_bits(t.psm) <= 8 {
			if !hw.clut_ok {hw_clut(0, 0, 0, 0, 0, false, 0, 0)}
			st.clut = hw.clut_off
		}
	}
	st.flags = transmute(u32)f
	// The texture's decoded copy stands until a page is written.
	if c.tme {st.dec, st.dec_ls = hw.state.dec, hw.state.dec_ls}
	if hw.state_ok && st == hw.state && (!c.tme || hw.dec_seq == hw.seq) {return hw.state_idx}
	fb := page_span(c.fpsm, c.fbp, c.fbw, st.sy0, st.sy1)
	z := c.zte && !c.zmsk ? page_span(c.zpsm, c.zbp, c.fbw, st.sy0, st.sy1) : {}
	tex := c.tme ? tex_span(t) : {}
	if c.tme {
		st.dec, st.dec_ls = hw_dec(t, &st, fb, z, tex)
		hw.dec_seq = hw.seq
		if hw.state_ok && st == hw.state {return hw.state_idx}
	}
	hw.state, hw.state_ok = st, true
	hw.state_idx = u32(s.nstates)
	([^]Hw_State)(s.states.ptr)[s.nstates] = st
	s.nstates += 1
	hw.fb_pages, hw.z_pages, hw.tex_pages = fb, z, tex
	hw.fb_key, hw.z_key = layout_key(c.fpsm, c.fbp, c.fbw), layout_key(c.zpsm, c.zbp, c.fbw)
	hw.fb_marked, hw.tex_ok = false, false
	return hw.state_idx
}

@(private)
hw_vert :: #force_inline proc(v: ^Vertex, fst: bool, state: u32) -> Hw_Vert {
	o := Hw_Vert {
		x     = v.x,
		y     = v.y,
		zf    = f32(v.z),
		zi    = u32(min(v.z, 4294967295)),
		c     = v.c,
		s     = v.s,
		t     = v.t,
		q     = v.q,
		fog   = v.fog,
		state = state,
		st_min = {-max(f32), -max(f32)},
		st_max = {max(f32), max(f32)},
	}
	if fst {o.s, o.t = v.u, v.v}
	return o
}

// Upscaled, a pixel just inside a primitive's edge samples nearer that edge
// than any native pixel centre does, and bilinear filtering there reaches
// the texel beyond it: seams where a picture is drawn as tiles (the logos'
// quads end at half pixels with u = 0 on the edge). Keep the texture
// coordinates (texels, after the divide) half a texel inside the vertices'
// range. Only with constant Q, so perspective 3D is left alone; scale 1
// stays exact.
@(private)
uv_clamp :: proc(vs: []Hw_Vert, fst: bool, tw, th: u32) {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
	for v in vs {
		if v.q != vs[0].q {return}
		uv := fst ? [2]f32{v.s, v.t} : [2]f32{v.s / v.q * f32(tw), v.t / v.q * f32(th)}
		lo, hi = linalg.min(lo, uv), linalg.max(hi, uv)
	}
	mid := (lo + hi) * 0.5
	lo, hi = linalg.min(lo + 0.5, mid), linalg.max(hi - 0.5, mid)
	for &v in vs {v.st_min, v.st_max = lo, hi}
}

// Upscaled, a sprite covers every sample of the GS pixels it covers
// natively (x0 <= p < x1) and no other. Its edges at half pixels otherwise
// leave the later samples of its last row and column unwritten and write the
// earlier ones of the pixel before its first: a picture copied with sprites
// from -0.5 to 255.5 keeps stale samples on its last row and column, which a
// repeating texture's seam then reads. Move each edge to the next whole pixel
// and extend the texture coordinates with it. Point sampled, keep them inside
// the vertices' range so the extension reads the edge texel; bilinear,
// uv_clamp has already done so.
@(private)
sprite_snap :: proc(vs: []Hw_Vert, point: bool, fst: bool, tw, th: u32) {
	if point {
		lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{-max(f32), -max(f32)}
		for v in vs {
			uv := fst ? [2]f32{v.s, v.t} : [2]f32{v.s / v.q * f32(tw), v.t / v.q * f32(th)}
			lo, hi = linalg.min(lo, uv), linalg.max(hi, uv)
		}
		for &v in vs {v.st_min, v.st_max = lo, linalg.max(hi - 1.0 / 16, lo)}
	}
	// vs[0] and vs[1] differ in x only, vs[0] and vs[2] in y only.
	dx, dy := vs[1].x - vs[0].x, vs[2].y - vs[0].y
	if dx == 0 || dy == 0 {return}
	ds, dt := (vs[1].s - vs[0].s) / dx, (vs[2].t - vs[0].t) / dy
	for &v in vs {
		x, y := math.ceil(v.x), math.ceil(v.y)
		v.s += (x - v.x) * ds
		v.t += (y - v.y) * dt
		v.x, v.y = x, y
	}
}

// Queue a primitive of `kind` from the vertex queue.
@(private)
hw_draw :: proc(c: ^Ctx, kind: u64) {
	s := &hw.slots[hw.cur]
	if s.nverts + 6 > VERT_CAP || s.nstates == STATE_CAP || s.ncluts == CLUT_CAP {
		hw_overflow()
		s = &hw.slots[hw.cur]
	}
	hw_flush_upload()
	st := hw_state(c)
	if !hw.fb_marked && (pages_alias(hw.fb_pages, hw.fb_key) || pages_alias(hw.z_pages, hw.z_key)) {
		hw_split()
	}
	if c.tme && !hw.tex_ok {
		if pages_hit(&hw.dirty, hw.tex_pages) {hw_split()}
		hw.tex_ok = true
	}
	if !hw.fb_marked {
		pages_mark_owner(hw.fb_pages, hw.fb_key)
		pages_mark_owner(hw.z_pages, hw.z_key)
		pages_write(hw.fb_pages)
		pages_write(hw.z_pages)
		hw.fb_marked, hw.tex_ok = true, false
	}

	// Built here and copied once: s.verts is mapped write-combined memory,
	// and reading it back (uv_clamp) stalls on every load.
	out: [6]Hw_Vert
	n := 0
	switch kind {
	case 3, 4, 5: // triangles
		a, b, d := &queue[0], &queue[1], &queue[2]
		if a.z == b.z && b.z == d.z {st |= CONST_Z}
		out[0], out[1], out[2] = hw_vert(a, c.fst, st), hw_vert(b, c.fst, st), hw_vert(d, c.fst, st)
		if !c.iip {out[0].c, out[1].c = d.c, d.c}
		n = 3
	case 6: // sprite: a and b are opposite corners; x attributes follow x
		a, b := &queue[0], &queue[1]
		base := hw_vert(b, c.fst, st | CONST_Z)
		corner :: #force_inline proc(base: Hw_Vert, xv, yv: ^Vertex, fst: bool) -> Hw_Vert {
			o := base
			o.x, o.y = xv.x, yv.y
			o.s, o.t = fst ? xv.u : xv.s, fst ? yv.v : yv.t
			return o
		}
		aa, ba := corner(base, a, a, c.fst), corner(base, b, a, c.fst)
		ab, bb := corner(base, a, b, c.fst), corner(base, b, b, c.fst)
		out[0], out[1], out[2] = aa, ba, ab
		out[3], out[4], out[5] = ba, bb, ab
		n = 6
	case 1, 2: // line: a one-pixel-wide quad across the minor axis
		a, b := hw_vert(&queue[0], c.fst, st), hw_vert(&queue[1], c.fst, st)
		if !c.iip {a.c = b.c}
		a2, b2 := a, b
		if abs(b.x - a.x) >= abs(b.y - a.y) {
			a2.y += 1
			b2.y += 1
		} else {
			a2.x += 1
			b2.x += 1
		}
		out[0], out[1], out[2] = a, b, b2
		out[3], out[4], out[5] = a, b2, a2
		n = 6
	case 0: // point: the pixel it falls in
		p := hw_vert(&queue[0], c.fst, st | CONST_Z)
		p.x, p.y = math.floor(p.x), math.floor(p.y)
		r, d, rd := p, p, p
		r.x += 1
		d.y += 1
		rd.x += 1
		rd.y += 1
		out[0], out[1], out[2] = p, r, d
		out[3], out[4], out[5] = r, rd, d
		n = 6
	}
	if c.tme && c.tex.bilinear && hw.scale > 1 && kind >= 3 {uv_clamp(out[:n], c.fst, c.tex.w, c.tex.h)}
	if kind == 6 && hw.scale > 1 {sprite_snap(out[:n], c.tme && !c.tex.bilinear, c.fst, c.tex.w, c.tex.h)}
	copy(([^]Hw_Vert)(s.verts.ptr)[s.nverts:][:n], out[:n])
	s.nverts += n
	hw.clip = {min(hw.clip[0], c.sx0), min(hw.clip[1], c.sy0), max(hw.clip[2], c.sx1), max(hw.clip[3], c.sy1)}
}

// -------------------------------------------------------------- frames

// End the frame: scan out the read circuit's buffer (w x h GS pixels),
// present it in the window, submit, and move to the other slot.
@(private)
hw_frame :: proc(psm, fbp, fbw, dbx, dby: u32, w, h: int) {
	hw_flush_upload()
	s := &hw.slots[hw.cur]
	sc := int(hw.scale)
	s.scan_w, s.scan_h = w * sc, h * sc
	if w > 0 && h > 0 {
		pc := Scan_PC{hw.vram.addr, s.scan.addr, psm, fbp, fbw, dbx, dby, u32(s.scan_w), u32(s.scan_h), hw.scale}
		hw_dispatch(hw.scan, &pc, (u32(s.scan_w) + 7) / 8, (u32(s.scan_h) + 7) / 8)
	}
	hw_flush_draws()
	hw_end_render()
	hw_barrier(s.cmd)
	hw.barrier_due = false

	img: u32
	acquired := false
	if hw.window && !skip_present && core.vkc.swap != 0 && w > 0 && h > 0 {
		r := vk.AcquireNextImageKHR(core.vkc.device, core.vkc.swap, max(u64), s.acquire, 0, &img)
		if r == .ERROR_OUT_OF_DATE_KHR {
			swap_create()
		} else {
			acquired = r == .SUCCESS || r == .SUBOPTIMAL_KHR
		}
	}
	if acquired {hw_present_record(s, core.vkc.swap_imgs[img])}
	hw_submit(acquired ? s.acquire : 0, acquired ? core.vkc.swap_done[img] : 0)
	if acquired {
		info := vk.PresentInfoKHR {
			sType              = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &core.vkc.swap_done[img],
			swapchainCount     = 1,
			pSwapchains        = &core.vkc.swap,
			pImageIndices      = &img,
		}
		r := vk.QueuePresentKHR(core.vkc.queue, &info)
		if r == .ERROR_OUT_OF_DATE_KHR || r == .SUBOPTIMAL_KHR {swap_create()}
	}
	hw.cur ~= 1
	hw_begin_slot()
}

@(private)
image_barrier :: proc(cmd: vk.CommandBuffer, img: vk.Image, from, to: vk.ImageLayout) {
	b := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.MEMORY_READ, .MEMORY_WRITE},
		dstAccessMask       = {.MEMORY_READ, .MEMORY_WRITE},
		oldLayout           = from,
		newLayout           = to,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = img,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cmd, {.ALL_COMMANDS}, {.ALL_COMMANDS}, {}, 0, nil, 0, nil, 1, &b)
}

// Scaled output to the swapchain image, 4:3 and centred.
@(private)
hw_present_record :: proc(s: ^Slot, dst: vk.Image) {
	cmd := s.cmd
	sw, sh := u32(s.scan_w), u32(s.scan_h)
	image_barrier(cmd, hw.out_img, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent      = {sw, sh, 1},
	}
	vk.CmdCopyBufferToImage(cmd, s.scan.buf, hw.out_img, .TRANSFER_DST_OPTIMAL, 1, &region)
	image_barrier(cmd, hw.out_img, .TRANSFER_DST_OPTIMAL, .TRANSFER_SRC_OPTIMAL)

	image_barrier(cmd, dst, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	black: vk.ClearColorValue
	rng := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	vk.CmdClearColorImage(cmd, dst, .TRANSFER_DST_OPTIMAL, &black, 1, &rng)
	W, H := i32(core.vkc.swap_ext.width), i32(core.vkc.swap_ext.height)
	dw, dh := W, H
	if W * 3 > H * 4 {dw = H * 4 / 3} else {dh = W * 3 / 4}
	ox, oy := (W - dw) / 2, (H - dh) / 2
	blit := vk.ImageBlit {
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		srcOffsets     = {{0, 0, 0}, {i32(sw), i32(sh), 1}},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstOffsets     = {{ox, oy, 0}, {ox + dw, oy + dh, 1}},
	}
	vk.CmdBlitImage(cmd, hw.out_img, .TRANSFER_SRC_OPTIMAL, dst, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
	image_barrier(cmd, dst, .TRANSFER_DST_OPTIMAL, .PRESENT_SRC_KHR)
}

// The last frame's output, RGBA8888 at the output scale, once the GPU is
// done with it.
hw_screen :: proc() -> (px: []u32, w, h: int) {
	s := &hw.slots[hw.cur ~ 1]
	vk.WaitForFences(core.vkc.device, 1, &s.fence, true, max(u64))
	return ([^]u32)(s.scan.ptr)[:s.scan_w * s.scan_h], s.scan_w, s.scan_h
}

// ---------------------------------------------------------- save states

// Emulated GS state outside gs, for save states (add registers a
// region): the front end's, and local memory itself when the software GS
// holds it; the GPU GS saves its copy through hw_snap_save/hw_snap_load.
snap_regions :: proc(add: proc(b: []u8)) {
	add(mem.ptr_to_bytes(&xfer))
	add(mem.ptr_to_bytes(&clut))
	add(mem.ptr_to_bytes(&cbp0))
	add(mem.ptr_to_bytes(&cbp1))
	add(mem.ptr_to_bytes(&cur))
	add(mem.ptr_to_bytes(&queue))
	add(mem.ptr_to_bytes(&nq))
	if !hw_on {add(mem.ptr_to_bytes(&vram))}
}

// GPU copies of local memory and the CLUT, by snapshot id.
@(private)
hw_snaps: map[int]core.Vk_Buf

// Copy local memory and the CLUT at this point of the command stream.
hw_snap_save :: proc(id: int) {
	b, ok := hw_snaps[id]
	if !ok {
		b = core.vk_buf_create(hw.vram.size + hw.clut_cur.size, {.TRANSFER_SRC, .TRANSFER_DST}, {.DEVICE_LOCAL})
		hw_snaps[id] = b
	}
	hw_snap_copy(b, true)
}

hw_snap_load :: proc(id: int) {
	b, ok := hw_snaps[id]
	assert(ok, "GS snapshot missing")
	hw_snap_copy(b, false)
}

@(private)
hw_snap_copy :: proc(b: core.Vk_Buf, save: bool) {
	hw_flush_upload()
	hw_split()
	cmd := hw.slots[hw.cur].cmd
	hw_barrier(cmd)
	vsize, csize := vk.DeviceSize(hw.vram.size), vk.DeviceSize(hw.clut_cur.size)
	if save {
		r := [2]vk.BufferCopy{{0, 0, vsize}, {0, vsize, csize}}
		vk.CmdCopyBuffer(cmd, hw.vram.buf, b.buf, 1, &r[0])
		vk.CmdCopyBuffer(cmd, hw.clut_cur.buf, b.buf, 1, &r[1])
	} else {
		r := [2]vk.BufferCopy{{0, 0, vsize}, {vsize, 0, csize}}
		vk.CmdCopyBuffer(cmd, b.buf, hw.vram.buf, 1, &r[0])
		vk.CmdCopyBuffer(cmd, b.buf, hw.clut_cur.buf, 1, &r[1])
	}
	hw.barrier_due = true
	hw.clut_ok = false // the slot's ring copy is of the CLUT before
	if !save {pages_write({0, PAGES})}
}
