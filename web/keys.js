// The keys the browser host knows: SDL scancodes (USB HID usages), their SDL
// names, and the KeyboardEvent.code that gives each. Shared by the page
// (code -> scancode) and web/sdl.js (scancode <-> name). Names are SDL 2's,
// so bindings saved by a desktop build read the same here.

const KEYS = [];
const add = (scancode, name, code) => KEYS.push([scancode, name, code]);

for (let i = 0; i < 26; i++) {
	const c = String.fromCharCode(65 + i);
	add(4 + i, c, `Key${c}`);
}
for (let i = 1; i <= 9; i++) add(29 + i, String(i), `Digit${i}`);
add(39, "0", "Digit0");
[
	[40, "Return", "Enter"], [41, "Escape", "Escape"], [42, "Backspace", "Backspace"],
	[43, "Tab", "Tab"], [44, "Space", "Space"], [45, "-", "Minus"], [46, "=", "Equal"],
	[47, "[", "BracketLeft"], [48, "]", "BracketRight"], [49, "\\", "Backslash"],
	[51, ";", "Semicolon"], [52, "'", "Quote"], [53, "`", "Backquote"], [54, ",", "Comma"],
	[55, ".", "Period"], [56, "/", "Slash"], [57, "CapsLock", "CapsLock"],
].forEach((k) => add(...k));
for (let i = 1; i <= 12; i++) add(57 + i, `F${i}`, `F${i}`);
[
	[70, "PrintScreen", "PrintScreen"], [71, "ScrollLock", "ScrollLock"], [72, "Pause", "Pause"],
	[73, "Insert", "Insert"], [74, "Home", "Home"], [75, "PageUp", "PageUp"],
	[76, "Delete", "Delete"], [77, "End", "End"], [78, "PageDown", "PageDown"],
	[79, "Right", "ArrowRight"], [80, "Left", "ArrowLeft"], [81, "Down", "ArrowDown"],
	[82, "Up", "ArrowUp"], [83, "Numlock", "NumLock"], [84, "Keypad /", "NumpadDivide"],
	[85, "Keypad *", "NumpadMultiply"], [86, "Keypad -", "NumpadSubtract"],
	[87, "Keypad +", "NumpadAdd"], [88, "Keypad Enter", "NumpadEnter"],
].forEach((k) => add(...k));
for (let i = 1; i <= 9; i++) add(88 + i, `Keypad ${i}`, `Numpad${i}`);
[
	[98, "Keypad 0", "Numpad0"], [99, "Keypad .", "NumpadDecimal"],
	[101, "Application", "ContextMenu"], [103, "Keypad =", "NumpadEqual"],
].forEach((k) => add(...k));
for (let i = 13; i <= 24; i++) add(91 + i, `F${i}`, `F${i}`);
[
	[224, "Left Ctrl", "ControlLeft"], [225, "Left Shift", "ShiftLeft"],
	[226, "Left Alt", "AltLeft"], [227, "Left GUI", "MetaLeft"],
	[228, "Right Ctrl", "ControlRight"], [229, "Right Shift", "ShiftRight"],
	[230, "Right Alt", "AltRight"], [231, "Right GUI", "MetaRight"],
].forEach((k) => add(...k));

export const SCANCODE_OF_CODE = new Map(KEYS.map(([s, , c]) => [c, s]));
export const NAME_OF_SCANCODE = new Map(KEYS.map(([s, n]) => [s, n]));
// SDL_GetScancodeFromName ignores case.
export const SCANCODE_OF_NAME = new Map(KEYS.map(([s, n]) => [n.toLowerCase(), s]));

// SDL_Keycode for a scancode: the character for keys that type one, else the
// scancode with bit 30 set, as SDL's default US layout.
export const keycode = (scancode) => {
	const n = NAME_OF_SCANCODE.get(scancode);
	if (scancode >= 4 && scancode <= 29) return n.toLowerCase().charCodeAt(0);
	if (scancode >= 30 && scancode <= 39) return n.charCodeAt(0);
	const sym = { 40: 13, 41: 27, 42: 8, 43: 9, 44: 32 }[scancode];
	if (sym !== undefined) return sym;
	if (scancode >= 45 && scancode <= 56 && scancode !== 50) return n.charCodeAt(0);
	return scancode | 1 << 30;
};
