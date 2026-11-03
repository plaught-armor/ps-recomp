// The launcher's window: `play` with no disc image. Keyboard, controller and
// mouse each become an Action (launcher.odin), and a file or directory
// dropped on the window joins the library in place; a disc launched runs as a
// child `play <disc image>` with this process's environment unchanged but
// for the TTY hint (core/env.odin), while the window hides. Its stderr
// reaches the terminal as it would without the launcher and is copied to
// the disc's play.log as plain lines; a run that fails shows its last
// stderr line.
//
// Hiding the window while a run plays, and dropping a file on it, are
// untested off Linux.
package play

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import sdl "vendor:sdl2"

// A held direction repeats after REPEAT_FIRST ms, then every REPEAT_NEXT.
@(private = "file")
REPEAT_FIRST :: 400
@(private = "file")
REPEAT_NEXT :: 80

// A stick past this (of 32767) is a direction.
@(private = "file")
STICK_DEADZONE :: 16000

// The window's first size.
@(private = "file")
WINDOW_W :: 960
@(private = "file")
WINDOW_H :: 720

@(private = "file")
Window :: struct {
	win:      ^sdl.Window,
	renderer: ^sdl.Renderer,
	tex:      ^sdl.Texture,
	px:       []u32,
	w, h:     int,
	held:     Action, // a direction held on a controller
	next:     u32, // when it next repeats, SDL ticks (ms, wrapping)
	stick:    Action, // the direction the left stick points
}

// Run the launcher; exe is the play executable it starts each disc with.
// The exit status: 0, or 1 on a failure.
launcher :: proc(exe: string) -> int {
	l: Launcher
	defer launcher_destroy(&l)
	if !launcher_init(&l) {
		return 1
	}
	if sdl.Init({.VIDEO, .EVENTS, .GAMECONTROLLER}) != 0 {
		fmt.eprintln("SDL_Init:", sdl.GetError())
		return 1
	}
	defer sdl.Quit()
	w: Window
	w.win = sdl.CreateWindow("ps-recomp", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, WINDOW_W, WINDOW_H, {.RESIZABLE})
	if w.win == nil {
		fmt.eprintln("SDL_CreateWindow:", sdl.GetError())
		return 1
	}
	defer sdl.DestroyWindow(w.win)
	w.renderer = sdl.CreateRenderer(w.win, -1, {})
	if w.renderer == nil {
		fmt.eprintln("SDL_CreateRenderer:", sdl.GetError())
		return 1
	}
	defer sdl.DestroyRenderer(w.renderer)
	defer delete(w.px)
	defer if w.tex != nil {sdl.DestroyTexture(w.tex)}
	// Its own path, so a run started from another directory finds it.
	self := exe
	if p, err := os.get_executable_path(context.allocator); err == nil {
		self = p
	}
	for {
		free_all(context.temp_allocator)
		if !window_fit(&w, &l) {
			return 1
		}
		launcher_draw(&l, w.px)
		sdl.UpdateTexture(w.tex, nil, raw_data(w.px), i32(w.w * 4))
		sdl.RenderClear(w.renderer)
		sdl.RenderCopy(w.renderer, w.tex, nil, nil)
		sdl.RenderPresent(w.renderer)
		cmd := launcher_step(&l, window_wait(&w, &l))
		switch cmd {
		case .None:
		case .Quit:
			return 0
		case .Launch:
			path := strings.clone(l.discs[l.sel].info[.Path], context.temp_allocator)
			id := strings.clone(l.discs[l.sel].id, context.temp_allocator)
			sdl.HideWindow(w.win)
			ok, last := run_disc(self, path, id)
			sdl.FlushEvents(.FIRSTEVENT, .LASTEVENT)
			w.held, w.stick = .None, .None
			sdl.ShowWindow(w.win)
			sdl.RaiseWindow(w.win)
			if !launcher_reload(&l, path) {
				return 1
			}
			if !ok {
				launcher_toast(&l, fmt.tprintf("The run failed: %s", last if last != "" else "(it printed nothing)"))
			}
		}
	}
}

// Size the picture and its texture to the window's drawable size. False,
// after a message, when the texture cannot be made.
@(private = "file")
window_fit :: proc(w: ^Window, l: ^Launcher) -> bool {
	ow, oh: i32
	if sdl.GetRendererOutputSize(w.renderer, &ow, &oh) != 0 || ow <= 0 || oh <= 0 {
		ow, oh = WINDOW_W, WINDOW_H
	}
	if int(ow) == w.w && int(oh) == w.h && w.tex != nil {
		return true
	}
	if w.tex != nil {
		sdl.DestroyTexture(w.tex)
	}
	w.tex = sdl.CreateTexture(w.renderer, .RGB888, .STREAMING, ow, oh)
	if w.tex == nil {
		fmt.eprintln("SDL_CreateTexture:", sdl.GetError())
		return false
	}
	delete(w.px)
	w.w, w.h = int(ow), int(oh)
	w.px = make([]u32, w.w * w.h)
	launcher_resize(l, w.w, w.h)
	return true
}

// The next action: an event, or a held direction's repeat. A window event
// that needs only a redraw gives None.
@(private = "file")
window_wait :: proc(w: ^Window, l: ^Launcher) -> Action {
	timeout := i32(-1)
	if w.held != .None {
		now := sdl.GetTicks()
		if i32(now - w.next) >= 0 {
			w.next = now + REPEAT_NEXT
			return w.held
		}
		timeout = i32(w.next - now)
	}
	e: sdl.Event
	if !sdl.WaitEventTimeout(&e, timeout) {
		return .None
	}
	core.input_event(e) // controller hotplug
	#partial switch e.type {
	case .QUIT:
		return .Quit
	case .KEYDOWN:
		#partial switch e.key.keysym.sym {
		case .UP:
			return .Up
		case .DOWN:
			return .Down
		case .LEFT:
			return .Left
		case .RIGHT:
			return .Right
		case .PAGEUP:
			return .Page_Up
		case .PAGEDOWN:
			return .Page_Down
		case .RETURN, .KP_ENTER:
			return .Ok
		case .ESCAPE, .BACKSPACE:
			return .Back
		case .TAB:
			return .Menu
		case .DELETE:
			return .Remove
		}
	case .CONTROLLERBUTTONDOWN:
		#partial switch sdl.GameControllerButton(e.cbutton.button) {
		case .DPAD_UP:
			return press(w, .Up)
		case .DPAD_DOWN:
			return press(w, .Down)
		case .DPAD_LEFT:
			return press(w, .Left)
		case .DPAD_RIGHT:
			return press(w, .Right)
		case .LEFTSHOULDER:
			return .Page_Up
		case .RIGHTSHOULDER:
			return .Page_Down
		case .A:
			return .Ok
		case .B:
			return .Back
		case .X:
			return .Menu
		case .Y:
			return .Remove
		case .START:
			return .Launch
		}
	case .CONTROLLERBUTTONUP:
		#partial switch sdl.GameControllerButton(e.cbutton.button) {
		case .DPAD_UP:
			release(w, .Up)
		case .DPAD_DOWN:
			release(w, .Down)
		case .DPAD_LEFT:
			release(w, .Left)
		case .DPAD_RIGHT:
			release(w, .Right)
		}
	case .CONTROLLERAXISMOTION:
		axis := sdl.GameControllerAxis(e.caxis.axis)
		if axis != .LEFTX && axis != .LEFTY {
			return .None
		}
		pad := sdl.GameControllerFromInstanceID(e.caxis.which)
		if pad == nil {
			return .None
		}
		x := int(sdl.GameControllerGetAxis(pad, .LEFTX))
		y := int(sdl.GameControllerGetAxis(pad, .LEFTY))
		dir := Action.None
		if max(abs(x), abs(y)) > STICK_DEADZONE {
			dir = (.Up if y < 0 else .Down) if abs(y) >= abs(x) else (.Left if x < 0 else .Right)
		}
		if dir == w.stick {
			return .None
		}
		release(w, w.stick)
		w.stick = dir
		return press(w, dir) if dir != .None else .None
	case .MOUSEBUTTONDOWN:
		if e.button.button != sdl.BUTTON_LEFT {
			return .None
		}
		r := launcher_row_at(l, mouse_x(w, e.button.x), mouse_y(w, e.button.y))
		if r < 0 {
			return .None
		}
		if l.screen == .Settings {
			again := r == l.row
			l.row = r
			return .Ok if again && e.button.clicks >= 2 else .None
		}
		again := r == l.sel
		launcher_select_row(l, r)
		return .Ok if again && e.button.clicks >= 2 else .None
	case .DROPFILE:
		// SDL's copy is ours to free.
		path := strings.clone_from_cstring(e.drop.file, context.temp_allocator)
		sdl.free(rawptr(e.drop.file))
		launcher_add(l, path)
	case .MOUSEWHEEL:
		if e.wheel.y > 0 {
			return .Up
		}
		if e.wheel.y < 0 {
			return .Down
		}
	}
	return .None
}

// A held direction: act now, repeat while held.
@(private = "file")
press :: proc(w: ^Window, a: Action) -> Action {
	w.held, w.next = a, sdl.GetTicks() + REPEAT_FIRST
	return a
}

@(private = "file")
release :: proc(w: ^Window, a: Action) {
	if a != .None && w.held == a {
		w.held = .None
	}
}

// A window point as a picture point (they differ on a high-density display).
@(private = "file")
mouse_x :: proc(w: ^Window, x: i32) -> int {
	ww, wh: i32
	sdl.GetWindowSize(w.win, &ww, &wh)
	return int(x) * w.w / max(int(ww), 1)
}

@(private = "file")
mouse_y :: proc(w: ^Window, y: i32) -> int {
	ww, wh: i32
	sdl.GetWindowSize(w.win, &ww, &wh)
	return int(y) * w.h / max(int(wh), 1)
}

// Run `exe path` and wait for it, its stderr copied to the terminal and to
// the play.log of disc id. Whether it ended with status 0, and its last
// non-empty stderr line (temp allocated) or why it could not start.
run_disc :: proc(exe, path, id: string) -> (ok: bool, last: string) {
	dir, has_dir := core.disc_dir(id, context.temp_allocator)
	if !has_dir {
		return false, "no directory for the disc"
	}
	log_path := core.disc_path(dir, .Play_Log, context.temp_allocator)
	log, lerr := os.open(log_path, {.Write, .Create, .Trunc})
	if lerr != nil {
		fmt.eprintln("play: cannot write", log_path, lerr)
	}
	defer if log != nil {os.close(log)}
	r, wr, perr := os.pipe()
	if perr != nil {
		return false, fmt.tprint("cannot make a pipe:", perr)
	}
	defer os.close(r)
	// The run writes its stderr as it would to the terminal this one's
	// stderr is (convert.odin).
	if os.is_tty(os.stderr) {
		_ = os.set_env(core.env_name("TTY"), "1")
	}
	p, serr := os.process_start({command = {exe, path}, stdin = os.stdin, stdout = os.stdout, stderr = wr})
	os.close(wr)
	if serr != nil {
		return false, fmt.tprint("cannot start", exe, serr)
	}
	last = tee(r, log)
	state, werr := os.process_wait(p)
	if werr != nil {
		return false, fmt.tprint("cannot wait for the run:", werr)
	}
	return state.exited && state.success && state.exit_code == 0, last
}

// Copy r to stderr as it is and to log (when not nil) as log_strip makes
// it, until r closes. The last non-empty line, temp allocated.
@(private = "file")
tee :: proc(r: ^os.File, log: ^os.File) -> string {
	buf, plain: [4096]u8
	line, last: [dynamic]u8
	line.allocator = context.temp_allocator
	last.allocator = context.temp_allocator
	esc: Log_Escape
	for {
		n, err := os.read(r, buf[:])
		if n > 0 {
			_, _ = os.write(os.stderr, buf[:n])
			k := log_strip(&esc, buf[:n], plain[:])
			for c in plain[:k] {
				if c != '\n' {
					append(&line, c)
					continue
				}
				if len(strings.trim_space(string(line[:]))) > 0 {
					clear(&last)
					append(&last, ..line[:])
				}
				clear(&line)
			}
			if log != nil {
				_, _ = os.write(log, plain[:k])
			}
		}
		if err != nil || n <= 0 {
			break
		}
	}
	if len(strings.trim_space(string(line[:]))) > 0 {
		return string(line[:])
	}
	return string(last[:])
}

// Where log_strip is in a terminal escape sequence, kept from one chunk of
// output to the next.
Log_Escape :: enum u8 {
	None,
	Esc, // after ESC
	Csi, // inside ESC [, until its final byte
}

// Copy src to dst (at least as long) as plain lines for a log: a carriage
// return (a line a terminal overwrites) a line break, every ESC sequence
// dropped (ESC [ ... to its final byte 0x40..0x7e; ESC and one byte
// otherwise). esc carries a sequence cut between chunks. The bytes written.
log_strip :: proc(esc: ^Log_Escape, src, dst: []u8) -> int {
	k := 0
	for c in src {
		switch esc^ {
		case .Esc:
			esc^ = .Csi if c == '[' else .None
			continue
		case .Csi:
			if c >= 0x40 && c <= 0x7e {
				esc^ = .None
			}
			continue
		case .None:
		}
		switch c {
		case 0x1b:
			esc^ = .Esc
		case '\r':
			dst[k] = '\n'
			k += 1
		case:
			dst[k] = c
			k += 1
		}
	}
	return k
}
