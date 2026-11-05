// The play page's gate program: built for wasi_wasm32, it runs in the page in
// place of play.wasm and uses the same SDL imports (web/sdl.js), so the gate
// checks the browser host without a disc.
//
// It draws a fixed test pattern each frame (a clear, two fills, one with
// additive blending, and a 64x64 streaming texture copied at 2x with
// nearest scaling). Every step is exact in 8-bit arithmetic, so the
// captured frame is the same bytes in every browser. It queues a 440 Hz
// square wave at 48 kHz, s16 stereo, amplitude 8192 (RMS 0.25), and prints
// each controller and key event:
//
//	host: pad added <index> <name>
//	host: button <b> down|up
//	host: key <name> down|up
//
// It runs for SECONDS, then prints `host: done <frames> frames` and exits 0.
package host

import "core:fmt"
import "core:os"
import sdl "vendor:sdl2"

W :: 320
H :: 240
TEX :: 64
RATE :: 48000
TONE :: 440
AMPLITUDE :: 8192
SECONDS :: 6
QUEUE_MS :: 100

// Globals, not locals: the wasm stack is small.
pixels: [TEX * TEX]u32
// One second of the tone, queued a slice at a time.
tone: [RATE * 2]i16

main :: proc() {
	if sdl.Init({.VIDEO, .AUDIO, .EVENTS, .GAMECONTROLLER}) != 0 {
		fmt.eprintln("host: SDL_Init:", sdl.GetError())
		os.exit(1)
	}
	win := sdl.CreateWindow("host test", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, W, H, {})
	r := sdl.CreateRenderer(win, -1, {})
	if win == nil || r == nil {
		fmt.eprintln("host: no window:", sdl.GetError())
		os.exit(1)
	}
	sdl.RenderSetLogicalSize(r, W, H)
	tex := sdl.CreateTexture(r, .RGB888, .STREAMING, TEX, TEX)
	for y in 0 ..< TEX {
		for x in 0 ..< TEX {
			// XRGB: red across, green down, blue on the checkerboard.
			blue: u32 = ((x ~ y) & 8) != 0 ? 0xff : 0
			pixels[y * TEX + x] = u32(x * 4) << 16 | u32(y * 4) << 8 | blue
		}
	}
	sdl.UpdateTexture(tex, nil, &pixels, TEX * 4)

	want := sdl.AudioSpec {
		freq     = RATE,
		format   = sdl.AUDIO_S16LSB,
		channels = 2,
		samples  = 1024,
	}
	dev := sdl.OpenAudioDevice(nil, false, &want, nil, {})
	if dev == 0 {
		fmt.eprintln("host: SDL_OpenAudioDevice:", sdl.GetError())
		os.exit(1)
	}
	sdl.PauseAudioDevice(dev, false)
	// The square wave's half period is RATE / (2 * TONE) frames, rounded
	// to whole frames.
	for i in 0 ..< RATE {
		v := i16(AMPLITUDE) if (i * 2 * TONE / RATE) % 2 == 0 else -AMPLITUDE
		tone[2 * i] = v
		tone[2 * i + 1] = v
	}
	played := 0

	start := sdl.GetTicks()
	last := start
	frames := 0
	for sdl.GetTicks() - start < SECONDS * 1000 {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				fmt.println("host: quit")
				os.exit(0)
			case .CONTROLLERDEVICEADDED:
				pad := sdl.GameControllerOpen(ev.cdevice.which)
				fmt.println("host: pad added", ev.cdevice.which, sdl.GameControllerName(pad))
			case .CONTROLLERBUTTONDOWN, .CONTROLLERBUTTONUP:
				fmt.println("host: button", ev.cbutton.button, "down" if ev.type == .CONTROLLERBUTTONDOWN else "up")
			case .KEYDOWN, .KEYUP:
				if ev.key.repeat == 0 {
					fmt.println("host: key", sdl.GetScancodeName(ev.key.keysym.scancode), "down" if ev.type == .KEYDOWN else "up")
				}
			}
		}
		// Keep about QUEUE_MS of tone queued.
		for sdl.GetQueuedAudioSize(dev) < RATE * 4 * QUEUE_MS / 1000 {
			n := RATE / 100 // 10 ms
			at := played % RATE
			if at + n > RATE do n = RATE - at
			sdl.QueueAudio(dev, &tone[2 * at], u32(n * 4))
			played += n
		}
		now := sdl.GetTicks()
		if now - last < 16 do continue
		last = now
		draw(r, tex)
		frames += 1
	}
	fmt.println("host: done", frames, "frames")
	sdl.Quit()
}

draw :: proc(r: ^sdl.Renderer, tex: ^sdl.Texture) {
	sdl.SetRenderDrawBlendMode(r, .NONE)
	sdl.SetRenderDrawColor(r, 16, 32, 64, 255)
	sdl.RenderClear(r)
	sdl.SetRenderDrawColor(r, 200, 40, 40, 255)
	a := sdl.Rect{16, 16, 96, 64}
	sdl.RenderFillRect(r, &a)
	src := sdl.Rect{0, 0, TEX, TEX}
	dst := sdl.Rect{160, 48, TEX * 2, TEX * 2}
	sdl.RenderCopy(r, tex, &src, &dst)
	// Added over the fill and the texture's corner.
	sdl.SetRenderDrawBlendMode(r, .ADD)
	sdl.SetRenderDrawColor(r, 40, 80, 120, 255)
	b := sdl.Rect{80, 40, 120, 80}
	sdl.RenderFillRect(r, &b)
	sdl.RenderPresent(r)
}
