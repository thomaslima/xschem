# Native macOS (Aqua) build of xschem: reviewer's guide

This guide accompanies the patch that lets xschem run on macOS as an ordinary application,
drawing through the native macOS Tk ("Aqua" Tk) instead of an X server. It explains what the
patch does and why, hunk by hunk, so that the diff can be checked against it.

The patch is based on commit `c15c6c05`. It changes 13 existing files:

```
git diff c15c6c05 -- .gitignore Makefile.conf.in README_MacOS.md scconfig/hooks.c src
```

and adds `src/aqua.m`, `src/aqua.h`, `src/xschem_terminal.sh` and
`XSchemMac/{launcher.c,make_app.sh,Info.plist.in,README.md}`. `XSchemMac/build/` is generated
output. This guide is `XSchemMac/AQUA_PORT.md` and is not part of the code.

## Contents

1. [Summary](#1-summary)
2. [Building and trying it](#2-building-and-trying-it)
3. [How it works](#3-how-it-works)
4. [Walk-through of the changes, file by file](#4-walk-through-of-the-changes-file-by-file)
5. [The C change outside the flag: width casts in draw.c](#5-the-c-change-outside-the-flag-width-casts-in-drawc)
6. [What does not change for X11 and Windows](#6-what-does-not-change-for-x11-and-windows)
7. [Testing](#7-testing)
8. [Known limitations and behaviour differences](#8-known-limitations-and-behaviour-differences)
9. [Questions for the maintainer](#9-questions-for-the-maintainer)
10. [Future work: Tk 9](#10-future-work-tk-9)

---

## 1. Summary

The patch builds xschem against Tk 8.6 for Aqua (Homebrew `tcl-tk@8`), the same way the Windows
build uses Tk's Xlib emulation. xschem keeps calling Xlib; Tk translates the calls to
CoreGraphics, Apple's 2D drawing library. The result needs no XQuartz or X server, and the
xschem binary links no X11 library directly; Homebrew's cairo does link Homebrew's X11 client
libraries (`libX11`, `libxcb`, `libXext`, `libXrender`), so they are loaded at run time and
copied into the bundle, but nothing opens an X display. A user gets a normal Mac application:
native menu bar, Command-key shortcuts, native save dialogs, Quit from the application menu,
files opened from the Finder, full Retina resolution, and an optional self-contained
`Xschem.app` meant to be copied to other Macs (not yet tried on one; section 7.4).

Everything is behind one C preprocessor symbol, `XSCHEM_AQUA`, set only by
`./configure --aqua` (or `--aqua-tk`), and one Tcl test, the proc `is_aqua`, which returns 1
only when `[tk windowingsystem]` is `aqua`. The exceptions are a fix in `draw.c` for undefined
behaviour in width computations, which gives wrong widths on arm64 (seen in the Aqua build,
expected on any arm64 platform; section 5), the bison command in `src/Makefile.in`, which
becomes a configure variable that expands to `bison` without `--aqua` (section 4.1), and two
lines in `tab_ctx_cmd` in `xschem.tcl`, which now run `eval execute 0 $terminal` on every
platform, as `get_shell` already does; for a one-word `$terminal` the call is the same as
before (section 6).

Size of the patch, computed with `git diff --numstat c15c6c05` and `wc -l`:

| Part | Files | Lines added / removed |
|---|---|---|
| C sources and header | `callback.c`, `draw.c`, `move.c`, `psprint.c`, `scheduler.c`, `xinit.c`, `xschem.h` | +189 / -46, of which +20 / -20 is the `draw.c` cast fix, so +169 / -26 for Aqua |
| Tcl | `xschem.tcl` | +271 / -6: one delimited block of 251 lines (252 added lines with the blank line after it), 16 one- or two-line hooks, and the two `eval` lines of section 6 |
| Build | `scconfig/hooks.c`, `Makefile.conf.in`, `src/Makefile.in` | +246 / -3 |
| Documentation, ignore list | `README_MacOS.md`, `.gitignore` | +97 / -0 |
| **Existing files, total** | **13** | **+803 / -55** |

| New file | Lines | Purpose |
|---|---|---|
| `src/aqua.m` | 599 | Display layer (Objective-C) |
| `src/aqua.h` | 100 | Prototypes and Xlib redirect macros (C89) |
| `src/xschem_terminal.sh` | 68 | `xterm -e` replacement that opens Terminal.app |
| `XSchemMac/make_app.sh` | 344 | Builds `Xschem.app` |
| `XSchemMac/Info.plist.in` | 109 | Template for the bundle's `Info.plist` |
| `XSchemMac/launcher.c` | 93 | Bundle executable that sets paths and execs xschem |
| `XSchemMac/README.md` | 93 | Bundle documentation |
| **Total** | **1406** | |

The existing C files contain 42 preprocessor conditionals that mention `XSCHEM_AQUA`
(`grep -c '^ *#.*XSCHEM_AQUA'`: `xinit.c` 24, `callback.c` 6, `draw.c` 4, `xschem.h` 3,
`scheduler.c` 3, `move.c` 1, `psprint.c` 1). Eighteen of them read
`defined(__unix__) && !defined(XSCHEM_AQUA)`: sixteen add `&& !defined(XSCHEM_AQUA)` to an
existing `__unix__` test, and two are new conditionals around file statics in `xinit.c`.
One, in `scheduler.c`, is an `#ifndef XSCHEM_AQUA` around the `fix_broken_tiled_fill` setter.
`xschem.tcl` has 16 `is_aqua` hook sites outside the Aqua block (`grep -n is_aqua`, lines
outside the block).

**X11 and Windows.** With `XSCHEM_AQUA` undefined and the X11 configuration, every C file of
the tree preprocesses to the same text as at `c15c6c05`, ignoring blank lines, except
`draw.c`, whose difference is exactly the 20 cast lines (`scheduler.c` was compared again
after the `#ifndef XSCHEM_AQUA` around its `fix_broken_tiled_fill` setter was added, with
the same result); a plain and a `--debug` `./configure` generate
byte-identical `Makefile.conf`, `config.h` and `src/Makefile`. Both checks were run
on macOS with the X11 configuration (MacPorts Tcl/Tk and XQuartz headers); no Linux or Windows
build was made. For Windows, reading the conditionals shows one difference: three
declarations that only X11 code uses are no longer compiled in `xinit.c` (section 6). The Tcl
hooks are inert unless `tk windowingsystem` is `aqua`, and the two `eval` lines make the same
call as before for a one-word `$terminal`; no X11 GUI session was run with the modified
`xschem.tcl`. Section 6 gives the details.

**Testing.** On one Apple Silicon Mac (macOS 26, Retina display, Homebrew Tk 8.6.18) the Aqua
build compiles without warnings, writes netlists byte-identical to an X11 build in all 1496
checks of the `netlisting` suite and passes scripted GUI checks of drawing, printing, input and
menus (input injected with `event generate`, native menus and dialogs replaced by stubs). Not
tested: non-Retina displays, moving a window between displays, Intel Macs, Tk 9, real Finder
and Dock events, native fullscreen, and a real Save through the native save sheet. Two
hands-on reports of the canvas no longer responding, one after a context-menu choice and one
after PDF export through xschem's own file dialog, were not reproduced by script; the first
did not recur when retried by hand on the rebuilt application, and on Aqua the native save
sheet replaces the dialog of the second (section 7.5).

## 2. Building and trying it

Build instructions are in `README_MacOS.md` (first section). In short:

```
brew install tcl-tk@8 cairo jpeg-turbo bison
./configure --aqua            # --debug, --prefix and --aqua-tk=<prefix> are also accepted
make
cd src && ./xschem
```

`XSchemMac/make_app.sh` then packages `src/xschem` into `XSchemMac/build/Xschem.app`; see
`XSchemMac/README.md`. Setting the environment variable `XSCHEM_AQUA_SCALE=1` before
starting xschem draws at one pixel per point, which shows on a Retina display what a
non-Retina display gets (section 3.2).

## 3. How it works

### 3.1 Why Tk's Xlib emulation alone is not enough on macOS

Tk on macOS implements a subset of Xlib on top of CoreGraphics, as it does on Windows on top of
GDI. xschem's Windows build already relies on this. On macOS six things stand in the way. The
Tk behaviour cited below was read in the Tk 8.6.18 sources; missing functions were checked
with `nm -gU` on Homebrew's `libtk8.6.dylib`:

1. **Drawing on a window is dropped outside a redraw.** macOS draws windows with Core
   Animation; a view can only be drawn into while AppKit (the Cocoa application framework)
   runs the view's `drawRect:` method, during which that view is the "focus view". In
   `TkMacOSXSetupDrawingContext()` (`macosx/tkMacOSXDraw.c`), a draw request on a window whose
   view is not the focus view only marks the area dirty (`addTkDirtyRect:`) and returns
   without drawing. Tk's own widgets cope because they draw from idle callbacks that Tk runs
   inside `drawRect:` (`-[TKContentView generateExposeEvents:]` in
   `macosx/tkMacOSXWindowEvent.c` services the Expose events, then all idle events). xschem
   draws on its window whenever it likes, for instance a rubber band on every pointer motion,
   so most of that drawing would be lost.
2. **A pixmap is one pixel per point.** On a Retina display the "backing scale factor" (pixels
   per point of the window's backing store) is 2. The `CGBitmapContext` (an in-memory bitmap
   that CoreGraphics draws into) behind a Tk pixmap has exactly the requested size in pixels
   (`TkMacOSXGetCGContextForDrawable()` in `macosx/tkMacOSXDraw.c`), so a window-sized
   `save_pixmap` has half the display's resolution in each direction and everything copied
   from it looks soft.
3. **`XCopyArea` addresses the source in pixels.** Tk's `XCopyArea()`
   (`macosx/tkMacOSXImage.c`) makes a `CGImage` of the whole source pixmap and cuts the source
   rectangle out of it in pixel units. With a pixmap made at 2 pixels per point, xschem's
   point coordinates select the wrong area.
4. **Missing Xlib calls.** `libtk8.6.dylib` does not export `XFreePixmap`, `XPending`,
   `XMaxRequestSize`, `XGetKeyboardControl`, `XGetWindowAttributes`, `XLookupColor`,
   `XAllocNamedColor`, `XGetErrorText`, `XSetTile`, `XDrawRectangles`, `XDrawArcs`,
   `XFillArcs`, nor the Xpm and window-manager-hint calls used for the icon. Nor does it export
   `Tk_MacOSXGetCGContextForDrawable()` and `Tk_MacOSXGetNSWindowForDrawable()`; these exist
   only in Tk's stubs table.
5. **Stipples are filled solid, and zero-width lines are not drawn.**
   `TkMacOSXSetupDrawingContext()` never looks at `gc->fill_style` or `gc->stipple`, so a
   `FillStippled` fill covers everything below it. It passes `gc->line_width` to
   `CGContextSetLineWidth()`, and CoreGraphics strokes nothing for width 0, where X11 draws
   its thinnest line. xschem uses width 0 for the crosshair, the snap cursor and grid points.
   With the measures of section 3.4 for these two problems, and the idle-callback present of
   section 3.2, disabled, the smoke test of section 7 fails exactly its stippled-fill,
   crosshair and preview-pane checks (run on a build that predates the last edits to the
   display code).
6. **Cairo has no Xlib surface to attach to.** On X11, xschem's cairo surfaces are
   cairo-xlib surfaces on the window and on `save_pixmap`. On Aqua there is no X display;
   cairo needs image surfaces on the pixmaps' memory instead.

### 3.2 The display model

xschem keeps working in points, exactly as on X11 and Windows: window size, pointer
coordinates, line widths, zoom, pick tolerances and every value seen by `xschem.tcl` are
unchanged. Only the bitmaps behind pixmaps are scaled.

- **Scaled bitmaps.** `aqua_create_pixmap()` asks Tk for a pixmap of `width*scale` by
  `height*scale` pixels, where `scale` is the window's backing scale factor (or 1 when the
  caller asks for a 1x pixmap), forces its `CGBitmapContext` into existence and applies
  `CGContextScaleCTM(scale, scale)` to it once. The CTM (current transformation matrix) maps
  user coordinates to pixels, so Tk's Xlib emulation then draws in points at device
  resolution. Tk's own flip from X to CoreGraphics coordinates still works because, for a
  pixmap, `TkMacOSXSetupDrawingContext()` takes the height from
  `CGContextGetClipBoundingBox()`, which is in user space (points).
- **Cairo on the same memory.** A Tk pixmap's bitmap is premultiplied ARGB, 32 bits per pixel
  in host byte order (`TkMacOSXGetCGContextForDrawable()`), which is cairo's
  `CAIRO_FORMAT_ARGB32`. Each pixmap made by `aqua_create_pixmap()` gets one cairo image
  surface on the same memory, with `cairo_surface_set_device_scale(scale, scale)`. Xlib
  drawing (through Tk) and cairo drawing (text, images, graphs) land in the same pixels.
  `aqua_pixmap_surface()` hands that surface to the places that call
  `cairo_xlib_surface_create()` on X11.
- **Front buffers.** The drawing window of each schematic context (`xctx->window`) gets a
  "front buffer", a window-sized pixmap made the same way, created in `resetcairo()`. The
  macros in `aqua.h` pass the drawable argument of every Xlib drawing call that xschem uses
  (listed in section 3.4) through `aqua_drawable()`, which returns the window's front buffer
  for a window and the drawable itself for anything else. xschem's own drawing therefore never
  targets a window, and the problem of point 1 above does not arise at drawing time.
- **Presenting.** A front buffer reaches the screen only from inside `drawRect:`. The path:

```
xschem C code                         aqua.h / aqua.m
-----------------------------------   ------------------------------------------------
XDrawLine(display, xctx->window, ..)  -> Tk XDrawLine on aqua_drawable(window) = front buffer
XCopyArea(save_pixmap -> window)      -> aqua_copy_area(): cairo copy into the front buffer
cairo_*(xctx->cairo_ctx, ...)         -> cairo_sfc is an image surface on the front buffer

end of the outermost 'xschem' command (xschem_and_present in xinit.c)
  -> aqua_flush() -> aqua_present(win) for each front buffer drawn on
       not inside drawRect: -> [view addTkDirtyRect: window rect]  (ask AppKit for a redraw)

AppKit: -[TKContentView drawRect:] -> Tk Expose event -> <Expose> binding
  -> xschem callback ... Expose -> callback(): aqua_present(win)
       inside drawRect: -> Tcl_DoWhenIdle(draw_front)
  -> Tk runs idle callbacks before drawRect: returns
  -> draw_front(): CGContextDrawImage(part of the front buffer -> window, in points)
```

`draw_front()` runs as an idle callback, not directly in the Expose handler, because a
frame's own idle redraw, queued earlier, would otherwise paint its `-background` over the
image afterwards; the preview pane of the file dialog is such a case.

Because every frame reaches the screen through an Expose event, the Expose case in
`callback()` must not do what `handle_expose()` does (copy `save_pixmap` to the window): that
would erase rubber bands, move ghosts and other temporary drawing on every present. The front
buffer holds exactly what the window should show, so an Expose only presents it again.

With `draw_window` set to 1 xschem draws the same primitives into the window and into
`save_pixmap`; on Aqua the window drawing goes to the front buffer, so both drawing models
work.

**The alternative not taken.** Making xschem's coordinates device pixels would also give full
resolution, but every place where window geometry or pointer positions enter xschem (C callback
coordinates, Tcl `%x %y`, `xschem get` results, line widths, pick tolerances, popups) would
have to be scaled, in shared code. The cost of the chosen model is that the thinnest line is
one point (two device pixels on Retina) and that geometry is rounded to whole points
(section 8).

**Scale changes.** `aqua_scale_mismatch()` compares a pixmap's scale with its window's
current backing scale. The check runs in `xschem_and_present()` after every outermost command
(for the current context) and in the Expose case of `callback()` (for the exposed window, when
it is the window of the context that is current while its Expose is handled). It
covers two cases: a window moved to a display with another scale, and `save_pixmap` left at 1x
by printing at a set size (see `resetwin()` in section 4.6). `aqua_front_sync()` remakes a
front buffer whose size or scale no longer matches its window.

### 3.3 Ownership of pixmap memory

`aqua.m` keeps two lists: registered pixmaps (`AquaPix`: pixmap, `CGContextRef`, cairo
surface, scale, size in points) and front buffers (`AquaFront`, keyed by `Window`).

The bitmap memory is reference counted by CoreGraphics: Tk creates the `CGBitmapContext`
with a NULL data pointer, so CoreGraphics owns the pixels and frees them with the last
reference to the context. The registry entry holds one reference to the `CGContext`; the one
cairo surface made on it holds its own, released by a cairo user-data destroy callback.
`aqua_pixmap_surface()` returns a new reference to that surface
(`cairo_surface_reference()`), which the caller destroys, the same contract as
`cairo_xlib_surface_create()`. `aqua_free_pixmap()` drops the entry and calls
`Tk_FreePixmap()`. A cairo surface still held elsewhere keeps the memory alive and draws
into an orphaned bitmap until its owner recreates it; it never draws into freed memory.

A front buffer is freed when its window gets `DestroyNotify` (an event handler installed with
`Tk_CreateEventHandler(StructureNotifyMask)`), because Tk reuses window ids. `aqua_drawable()`
runs for every redirected Xlib call; it is a list walk with a one-entry hit cache and a
one-entry miss cache, with no `Tk_IdToWindow()` on the drawing path.

### 3.4 Redirect macros and missing calls

`aqua.h` is included by `xschem.h` after `<tk.h>` and defines:

- `XDrawLine`, `XDrawLines`, `XDrawSegments`, `XDrawPoints`, `XDrawRectangle`, `XDrawArc`:
  the real call, on `aqua_drawable(w)`.
- `XSetLineAttributes`: width 0 becomes 1 (point 5 above).
- `XFillArc`, `XFillRectangle`, `XFillRectangles`, `XFillPolygon`: to `aqua_fill_*()`, which
  fill a `FillStippled` GC on a registered pixmap with cairo (the GC foreground masked by the
  stipple, repeated from the drawable origin, one stipple bit per point, the GC clip rectangle
  and fill rule honoured) and pass everything else to Tk. A depth-1 Tk pixmap is an 8-bit
  alpha-only bitmap, used directly as a `CAIRO_FORMAT_A8` surface.
- `XCopyArea`: to `aqua_copy_area()`, a cairo `SOURCE` paint between registered pixmaps,
  clipped to the destination rectangle and the GC clip rectangle; cairo resamples when the two
  scales differ. Unregistered drawables fall back to Tk's `XCopyArea()`.
- `cairo_toy_font_face_create`: to `aqua_toy_font_face()`. Cairo's Quartz toy-font backend
  matches the generic families (`sans-serif`, `monospace`, ...) only in lower case, so
  xschem's `Sans-Serif` and `Monospace` would give plain Helvetica with no bold, and slanted
  faces are found by style name (Oblique for Helvetica and Courier, Italic for Times). The function
  lower-cases the family and picks the slant accordingly.
- For Tk 8.6, `aqua.m` defines `XDrawRectangles`, `XDrawArcs` and `XFillArcs` as loops over
  the single-shape calls on `aqua_drawable(w)` (these loops call Tk directly, so `XFillArcs`
  gets no stipple handling; xschem only uses it with the solid layer GCs), and `XSetTile` as a
  no-op (on Aqua `fix_broken_tiled_fill` is set to 1 at startup in C and in Tcl, and its
  Options menu entry is disabled, and `xschem set fix_broken_tiled_fill` does not change the
  C value; section 8).
  For Tk 9 `aqua.h` assumes these exist and only redirects them.

The GC clip rectangle is read from Tk's GC structure through `TkpClipMask` and `TkClipBox()`,
declared in Tk's private header `tkInt.h`, because no public Tk call returns a GC's clip
(section 9.3).

### 3.5 Input

Aqua Tk reports mouse buttons and modifiers differently from X11. The translation is done once,
in Tcl, in `aqua_bindings`, which `set_bindings` calls after it has made the usual bindings;
the C code keeps its X11 meaning, and so do `replace_key` remaps of keys (button numbers in
remaps are not translated, section 8).

- **Buttons.** Aqua Tk numbers buttons as `[NSEvent buttonNumber] + 1`
  (`macosx/tkMacOSXMouseEvent.c`): right is 2, middle is 3, side buttons 4 and 5.
  `aqua_button` swaps 2 and 3 and maps 4 and 5 to 8 and 9, so side buttons are not taken
  for wheel steps.
- **Modifiers.** Aqua Tk sets Mod1 for Command, Mod2 for Option, Mod3 for the numeric-pad flag
  and Mod4 for the function-key flag (`setupXEvent()` in `macosx/tkMacOSXKeyEvent.c` for keys,
  the same mapping in `macosx/tkMacOSXMouseEvent.c` for the pointer).
  `aqua_state` keeps Shift, Lock, Control and Button1, turns Option into Mod1 (xschem's Alt),
  drops Command, Mod3 and Mod4, and swaps the Button2 and Button3 masks. The comment in
  `aqua_state` says that arrow and function keys carry the keypad and Fn flags (macOS sets
  them on those keys; not observed here with a physical keyboard, section 7.4); with them,
  tests such as `state == ControlMask` (Ctrl-Left, Ctrl-Right) would fail. `aqua_bindings`
  also rewrites the drawing's existing `<Leave>` binding so that its `%s` goes through
  `aqua_state`; the `LeaveNotify` case of `callback()` passes the state to `draw_crosshair()`,
  which compares it with `ShiftMask`.
- **Wheel.** Aqua sends `<MouseWheel>`, and a trackpad sends a stream of small deltas.
  `aqua_wheel` accumulates `%D` (resetting on a change of direction) and makes one zoom or pan
  step once the sum reaches `aqua_wheel_units`, at most one step per `aqua_wheel_interval`
  milliseconds (defaults 1 and 50); the sum is cleared after each step, so delta that arrives
  faster than that is dropped. The step is sent as the usual button 4/5 callback with the
  state computed by the existing Tk 8.7 branch of `set_bindings`, which derives the zoom and
  pan modifiers from `replace_key(Button-4)`, `replace_key(Shift-Button-4)` and
  `replace_key(Control-Button-4)`; those remaps therefore still apply. The `.sim`, `.cv` and
  `.trav` dialogs get `<MouseWheel>` bindings for scrolling.
- **Option-composed characters.** On a Mac keyboard Option composes characters (Option-s is
  `ssharp`). The generic `<KeyPress>` binding passes Tk's `%k` in the `aux` argument; at the
  top of `callback()` (after the reentrancy test), when Alt is set, the keysym is replaced by
  `XkbKeycodeToKeysym(display, keycode, 0, shift)`, the key without Option, so Option-s arrives
  as Alt-s. `aux` is then cleared. `key_binding` rewrites `Alt-` to `Option-` in `replace_key`
  event patterns, since `Alt-` never matches on Aqua (Aqua Tk sets no Alt modifier mask,
  `TkpInitKeymapInfo()` in `macosx/tkMacOSXKeyboard.c`).
- **Command keys.** Command does not act as Alt. A table, `aqua_command_keys`, binds Command
  shortcuts to the xschem key they perform; `<Command-KeyPress>` is bound to a no-op so other
  Command combinations do nothing. Control keys keep their meaning. Keys that macOS reserves
  are not used (Command-H, -M, -Q, -comma, -question, -Tab, -space, -grave). The default
  table (`set_ne`, so `xschemrc` can replace it):

| Command key | Performs xschem key | Menu entry that shows it |
|---|---|---|
| Cmd-S | Ctrl-S | File > Save |
| Cmd-Shift-S | Ctrl-Shift-S | File > Save as |
| Cmd-O | Ctrl-O | File > Open |
| Cmd-W | Ctrl-W | File > Close schematic |
| Cmd-N | Ctrl-T | (none) |
| Cmd-T | Ctrl-T | File > Create new window/tab |
| Cmd-Z | u | Edit > Undo |
| Cmd-Shift-Z | Shift-U | Edit > Redo |
| Cmd-X | Ctrl-X | Edit > Cut |
| Cmd-C | Ctrl-C | Edit > Copy |
| Cmd-V | Ctrl-V | Edit > Paste |
| Cmd-A | Ctrl-A | Edit > Select all |
| Cmd-F | Ctrl-F | Tools > Search |
| Cmd-Backspace | Delete | Edit > Delete |
| Cmd-= | Shift-Z | View > Zoom In |
| Cmd-+ | Shift-Z | (none) |
| Cmd-minus | Ctrl-Z | View > Zoom Out |
| Cmd-0 | f | View > Zoom Full |
| Cmd-Shift-} | Ctrl-Right | (none) |
| Cmd-Shift-{ | Ctrl-Left | (none) |

### 3.6 Menus and application integration

- **Native menu bar.** Aqua Tk shows a toplevel's menu in the macOS menu bar. `aqua_menus`
  (called at the end of `build_widgets`) inserts Netlist and Simulate at the top of the
  Simulation menu, because, as its comment states, the menu bar shows only cascades and the
  top-level Netlist and Simulate entries would not appear. It adds a cascade named `window`,
  which Aqua Tk fills with Minimize, Zoom and the window list (`ENTRY_WINDOWS_MENU` in
  `macosx/tkMacOSXMenu.c`), and disables the Options entry "Fix for GPUs with broken tiled
  fill" (section 3.4). It sets the `-accelerator` of the entries named in the table above,
  and of File > Quit Xschem, to `Cmd+...` strings. Aqua Tk parses accelerator strings
  (`ParseAccelerator()` in `macosx/tkMacOSXMenu.c`) into native menu key equivalents, which the
  menu shows with the macOS symbols (⌘S rather than the text `Cmd+s`); the stock `Ctrl+...`
  accelerators of the other entries become Control key equivalents the same way. The
  on-screen rendering was not checked; the tests read the `-accelerator` values. An Aqua menu
  key equivalent only flashes the menu and does not run the entry's command
  (`-[TKMenu performKeyEquivalent:]`); the bindings of section 3.5 do the work.
- **Quit.** `::tk::mac::Quit` (Quit in the application menu, Cmd-Q, logout) calls
  `quit_xschem`, which asks to save as File > Quit Xschem does; it returns at once when
  `xschem get semaphore` is 2 or more, the threshold xschem's own callbacks use to refuse
  re-entry. If it returns, Tk keeps running (`ReallyKillMe()` in
  `macosx/tkMacOSXHLEvents.c` exits only when `::tk::mac::Quit` is not defined).
  `tkAboutDialog` opens xschem's About box; `::tk::mac::ReopenApplication` (Dock click)
  raises the main window.
- **Files from the Finder.** `::tk::mac::OpenDocument` receives files opened from the Finder or
  dropped on the Dock icon. Files that arrive while xschem starts are queued until
  `Tcl_AppInit()` calls `aqua_open_pending`; later ones are opened at once. A file goes into
  the current window if it is an unmodified `untitled` schematic, otherwise into a new
  window or tab.
- **No console window.** `TkpInit()` (`macosx/tkMacOSXInit.c`) opens a Tk console when stdin is
  closed or `/dev/null` and no startup script is set, which is the case for a Finder launch or
  a background start. `Tcl_AppInit()` sets a dummy startup script around `Tk_Init()` (when
  none is set) and clears it again so that `Tk_Main()` does not run it. `TK_CONSOLE` still
  forces a console. A side effect, from the same Tk code: when stdin is closed or `/dev/null`
  and no console is opened, `TkpInit()` redirects stdout and stderr to `/dev/null`, so a GUI
  run started with `</dev/null` from a terminal prints nothing, including `-d` debug output
  (from reading the Tk source; xschem already does the same itself for a background start).
- **Fullscreen.** `toggle_fullscreen()` uses `wm attributes -fullscreen` instead of EWMH
  messages. States 1 and 2 both turn native fullscreen on and state 0 turns it off; state 2
  also hides the menu, toolbar, tabs and status bar through the shared code above the new
  branch.
- **Context menus.** xschem's context menus are override-redirect toplevels of buttons that
  rely on Enter, Leave and Motion events. Aqua Tk delivers mouse motion and enter/leave only to
  the key window (the window that receives keyboard input; `tkMacOSXMouseEvent.c`), and never
  gives focus to an override-redirect toplevel (`TkpChangeFocus()` in
  `macosx/tkMacOSXWm.c`), so those menus get no hover events. `aqua_popup_menu` copies the
  buttons' labels, commands, states and images into a native menu and posts it with
  `tk_popup`. On Aqua `tk_popup` runs NSMenu's own tracking loop (`TkpPostMenu()` in
  `macosx/tkMacOSXMenu.c`), which takes all input until the user chooses or dismisses. The
  button toplevel is destroyed before the menu is posted and before it is ever mapped (no
  idle processing runs in between), so, as the procedure's comment says, it never gets an
  NSWindow; the window list logged by the harness of section 7.5 during the menu confirms
  this. Destroying a toplevel that has one makes Tk reset the key window and its mouse event
  target (`TkWmDeadWindow()` in `macosx/tkMacOSXWm.c`), which should not happen while the
  menu tracks. The procedure runs no `update` afterwards; its comment gives as the reason that
  `context_menu` is called from C with the semaphore raised (by `context_menu_action()` in
  `callback.c`), so no nested event loop may run there. `tab_context_menu`, which the tab
  buttons' binding calls directly, runs without the semaphore. Section 7.5 gives the status of
  a reported freeze after a context-menu choice.
- **Save dialogs.** `save_file_dialog` returns `aqua_save_file_dialog` on Aqua, which calls
  the native `tk_getSaveFile` with `-parent [xschem get topwindow]`; Aqua Tk shows the panel as
  a sheet attached to that window (`showOpenSavePanel()` in `macosx/tkMacOSXDialog.c`) and
  runs it modally. The initial folder and name come from the `initialf` argument (its
  directory and tail) or, without one, from the global variable named by `global_initdir`,
  which is read and not changed. An `ext` of the form `*.png`, `*.svg` or `*.{ps,pdf}` becomes
  one `-filetypes` entry (for the last, `{.ps, .pdf} {.ps .pdf}`); `*` gives no filter. When
  the proposed file name ends in `.eps` (EPS export, which passes `*.{ps,pdf}`), `.eps` is
  added to that entry, because the panel accepts only the listed extensions (section 8).
  `overwrt` becomes `-confirmoverwrite`, so the panel asks before replacing a file. The
  semaphore is raised by one while the panel is up, as `load_file_dialog` raises it for its
  own dialog. The result is the chosen path or the empty string, as before. The callers are
  all in C: Save as (`saveas()`, schematics and symbols), saving an unnamed schematic before
  descending into a symbol (`descend_schematic()`), Symbol > "Make schematic and symbol from
  selected components" (`make_schematic_symbol_from_sel()`), and PNG, PostScript/PDF/EPS and
  SVG export when no file name is given (`print_image()`, `ps_draw()`, `svg_draw()`).
  `load_file_dialog` (Open, Merge, symbol insertion, with its preview pane) is unchanged and stays
  xschem's own two-pane window. The comment above `aqua_save_file_dialog` gives two reasons:
  xschem's dialog lists library paths, so an arbitrary folder is hard to reach, and it is a
  separate, non-transient window (the `wm transient` call in `load_file_dialog` is commented
  out) that, if it ends up behind the main window, still waits while the drawing ignores
  input; a sheet cannot be hidden that way (section 7.5).
- **Tabs.** Aqua buttons ignore `-background`, so `aqua_tabs` marks the current tab with
  `-default active`; it also binds the tab menu to `<ButtonPress-2>`, the right button on Aqua.

### 3.7 External tools and PDF export

When xschem runs on Aqua with a GUI, the Aqua block of `xschem.tcl` sets these defaults with
`set_ne`, before the generic defaults, so `xschemrc` still wins:

- `launcher_default_program` is `open`;
- `editor` is `open -W -n -e`: TextEdit in a new instance, returning when it quits (like
  `gvim -f`);
- `terminal` is `/bin/sh $XSCHEM_SHAREDIR/xschem_terminal.sh`, a replacement for `xterm -e`
  that writes the command into a temporary `.command` file and opens it in Terminal.app
  (every place that starts `$terminal`, including the two terminal entries of the tab menu,
  expands it with `eval`, so the two words become a program and its argument; section 6).
  "Open directory" in the tab menu uses `open` instead of `xdg-open`.

PDF export converts PostScript with `$to_pdf` (default `ps2pdf`). macOS has no PostScript to PDF
converter, and an application started from the Finder does not search Homebrew's `bin`
directory. In the unix branch of `convert_to_pdf`, a converter that cannot be started gets
only the generic "Can not execute ..." dialog of `execute`, with the PostScript left in
`XSCHEM_TMP_DIR`, and a converter that runs and fails is not reported at all (observed on the
Aqua build before this hunk was added). On Aqua the branch calls `aqua_convert_to_pdf`. When
the converter is not found (`auto_execok`), or runs and fails (non-zero exit code or no PDF
written), it shows an error dialog naming the problem and `brew install ghostscript`, and
moves the PostScript next to the requested file as `<name>.ps`. When the converter is found
but cannot be started, `execute` has already shown its "Can not execute" dialog and the
procedure returns without a second one; the PostScript then stays in `XSCHEM_TMP_DIR`. The
`Xschem.app` launcher appends `/opt/homebrew/bin` and `/usr/local/bin` to `PATH`.

### 3.8 Headless detection

On X11 `xserver_ok()` (called from `main()`) tests `DISPLAY` and opens the display. On Aqua
there is no `DISPLAY`; the version in `aqua.m` returns 0 when
`CGSessionCopyCurrentDictionary()` returns NULL, which Apple documents as the case when the
caller is not running within a Quartz GUI session or the window server is disabled. An ssh
login and a launch daemon are expected to be such cases; only a sandboxed process without
window-server access was tried (section 7.4). xschem then starts without GUI, as the X11
build does without `DISPLAY`. `-x` works as before.

## 4. Walk-through of the changes, file by file

### 4.1 Build system

**`scconfig/hooks.c`**

- `#include <stdlib.h>`, for `atoi()` and `free()` in the new code.
- New static functions, placed after `find_sul_libjpeg()`:
  - `aqua_brew_prefix()`: runs `brew --prefix <formula>` (with Homebrew's auto-update and
    analytics off) through scconfig's `run_shell()`, falls back to
    `/opt/homebrew/opt/<formula>`, and returns NULL unless a probe file exists there.
  - `aqua_cfgvar()`: reads `NAME='value'` from `tclConfig.sh` or `tkConfig.sh`.
  - `aqua_icl()`: a `try_icl()` compile-and-run test with an error message that names the
    flags and `scconfig/config.log`.
  - `find_aqua()`: locates `tcl-tk@8` (or the `--aqua-tk` prefix), `cairo`, `jpeg-turbo` and
    `bison`; if any is missing it prints one `brew install ...` line and fails. It reads the
    Tcl/Tk library names from the config scripts (8.6: `-ltk8.6 -ltkstub8.6`,
    `-ltcl8.6 -ltclstub8.6`; the stub libraries are needed by `aqua.m`, section 4.9), adds
    `-Dinline=__inline__` for Tcl 9 headers, tests Tk, cairo and libjpeg with small programs,
    and stores the results in the scconfig nodes `libs/script/tcl`, `libs/script/tk`,
    `libs/gui/cairo`, `libs/sul/libjpeg`. `-DXSCHEM_AQUA -DMAC_OSX_TK` travel in the Tk
    cflags, and `-framework Cocoa` in the Tk ldflags. It marks Xpm absent, sets
    `/local/xschem/bison` to Homebrew's bison and builds `/local/xschem/objcflags` for
    `aqua.m` (optimisation from `--debug`/`--symbols`, `-Wall -fno-objc-arc`, no `-std=c89`).
- `help()`: two lines each for `--aqua` and `--aqua-tk=path`.
- `hook_custom_arg()`: `--aqua` sets `/local/xschem/aqua`; `--aqua-tk=p` also sets
  `/local/xschem/aqua-tk`.
- `hook_postinit()`: defaults `aqua=false` and `bison=bison`.
- `hook_detect_target()`: after the bison test, `find_aqua()` runs when `--aqua` is given and
  exits on failure. Because it has already filled the nodes, the unchanged
  `require("libs/script/tk/*")`, `require("libs/gui/xpm/*")` and cairo/libjpeg lines find
  them present and run no X11 or pkg-config detection. The cairo-xcb test is skipped for
  Aqua, so `HAS_XCB` is not defined.
- `hook_generate()`: the summary prints ` aqua:      yes (native macOS, no X11)` for Aqua
  builds only.

`icon.c` stays in the source list and is compiled; its Xpm array is simply not referenced on
Aqua.

**`Makefile.conf.in`**: the template's single print block is split after `LDFLAGS=` so that
`OBJCFLAGS=` can be printed only for Aqua builds. For other builds the generated text is
unchanged (section 6).

**`src/Makefile.in`** (all additions conditional on `/local/xschem/aqua`, except the bison
recipes):

- `xschem_terminal.sh` is appended to `install_shares`.
- `aqua.o` is appended to the object list.
- A rule `aqua.o: aqua.m` compiled with `$(CC) -c $(OBJCFLAGS)`, and `$(OBJ): aqua.h`.
- The two bison recipes use `&/local/xschem/bison&` instead of `bison`. The value is `bison`
  unless `find_aqua()` sets it, so other builds generate the same `src/Makefile`. macOS
  ships bison 2.3, which is too old.

**`.gitignore`**: `XSchemMac/build/`, where `make_app.sh` writes the bundle.

### 4.2 `src/xschem.h`

- A comment after the Apple `#define __unix__` explains `XSCHEM_AQUA`: `__unix__` stays defined
  so that POSIX code is shared, and `XSCHEM_AQUA` disables only what needs a real X server.
- `<X11/xpm.h>` is not included (there is no Xpm library in the Aqua build).
- The cairo-xlib includes are replaced by a comment; cairo surfaces come from
  `aqua_pixmap_surface()`.
- `aqua.h` is included after `<tk.h>`.

### 4.3 `src/draw.c`

Besides the cast fix of section 5:

- `xserver_ok()`: X11 version excluded; the Aqua version is in `aqua.m`.
- `print_image()`: the PNG export surface is `aqua_pixmap_surface(xctx->save_pixmap)`.
- `grabscreen()`: excluded (it captures the screen through a cairo-xlib surface).
- `svg_embedded_graph()`: the surface for the graph bitmap is
  `aqua_pixmap_surface(xctx->save_pixmap)`.

### 4.4 `src/psprint.c`, `src/move.c`, `src/scheduler.c`

- `psprint.c`, `ps_embedded_graph()`: same surface change as `svg_embedded_graph()`.
- `move.c`, `draw_selection()`: the `pending_events()` interruption is excluded (`XPending` is
  not in Aqua Tk). A long selection redraw therefore runs to the end.
- `scheduler.c`, `xschem globals`: the "Xserver options" section (`XMaxRequestSize`) is excluded.
- `scheduler.c`, `xschem grabscreen`: excluded; the command does nothing on Aqua.
- `scheduler.c`, `xschem set fix_broken_tiled_fill`: the assignment is excluded, so the C value
  stays at the 1 forced at startup (section 4.6).

### 4.5 `src/callback.c`

- `handle_key_press()`, case `XK_Print`: excluded (screen grab).
- `update_statusbar()`, two sites: the `XKeyboardState` declaration is excluded, and an Aqua
  branch clears the lock-key indicator instead of calling `XGetKeyboardControl()`.
- `callback()`, after the reentrancy test: the Option-key handling of section 3.5.
- `callback()`, the `GRABSCREEN` dispatch: excluded.
- `callback()`, case `Expose`: `handle_expose()` is not called (`(void)handle_expose;` keeps
  the static function from warning). The exposed window is looked up from `win_path`. If it is
  the current context's window and the callback is not nested inside another `xschem`
  command (`aqua_nesting(0) == 1`), `save_pixmap` is remade first when it does not match the
  window: on a size difference with `resetwin(1, 1, 0, 0, 0)` (the first `ConfigureNotify` of a
  new window can arrive before xschem binds to it), on a scale mismatch with
  `resetwin(1, 1, 1, 0, 0)`; both followed by `draw()`. Then `aqua_present(win)`. The
  nesting test keeps an Expose that arrives during printing from resizing the print pixmap.
  The comment explains why this check exists here as well as in `xschem_and_present()`: the
  Expose of another window runs with that window's context current.

### 4.6 `src/xinit.c`

Exclusions of calls that Aqua Tk lacks, grouped (all `#if defined(__unix__) &&
!defined(XSCHEM_AQUA)`; where an `#else` branch exists, it is the code the Windows build
compiles, which Aqua now compiles too):

| Function or place | What Aqua gets |
|---|---|
| file statics `hints_ptr`; `xcolor_exact, xcolor` (two new conditionals, kept separate so declaration order is unchanged) | not declared (on Windows neither, which declared them unused before; section 6) |
| `windowid()` (two sites) | no Xpm icon and no WM hints |
| `err()` | returns 0 without `XGetErrorText()`; the `int l` used only by that call moved inside the `#if` |
| `find_best_color()` | the Windows branch, `Tk_GetColor()` |
| `xwin_exit()` (two sites) | the Windows branch, `Tk_FreePixmap()` for the icon and stipple pixmaps |
| `build_colors()` | the Windows branch, `Tk_GetColor()` instead of `XLookupColor()` |
| `pending_events()` | not defined (only `draw_selection()` used it) |
| `Tcl_AppInit()`, the debug line with `XMaxRequestSize()` | the existing `#else` debug line |

Aqua code:

- `toggle_fullscreen()`: native fullscreen through `wm attributes <toplevel> -fullscreen`,
  `pending_fullzoom` set as the X11 branch does; the EWMH helpers are marked unused.
- `resetcairo()`: `cairo_save_sfc` is `aqua_pixmap_surface(save_pixmap)`. For `cairo_sfc`,
  `aqua_front_sync(window)` creates or remakes the window's front buffer at the window's size
  and scale, and the surface is that front buffer's.
- `resetwin()`, four sites: the window size comes from `Tk_Width()`/`Tk_Height()` of
  `Tk_IdToWindow()` (no `XGetWindowAttributes()`); `save_pixmap` is freed with
  `aqua_free_pixmap()` and created with `aqua_create_pixmap()`, at the window's backing scale,
  or at 1x when `w` and `h` are given. The callers that pass `w` and `h` are the print and
  graph-embedding paths (and `xschem resetwin` when given sizes), so
  `xschem print png file 400 300` writes exactly 400 by 300 pixels. The print paths restore
  the window with explicit sizes too, which leaves `save_pixmap` at 1x;
  `xschem_and_present()` then remakes it (section 3.2).
- `xschem_and_present()`, new static function: the `xschem` command on Aqua. It increments
  the nesting counter, calls `xschem()`, and at nesting depth 0 remakes `save_pixmap` if its
  scale does not match the window, then calls `aqua_flush()`. When `has_x` is 0 the counter is
  incremented and never decremented; nothing reads it in that mode.
- `Tcl_AppInit()`:
  - around `Tk_Init()`: the dummy startup script of section 3.6;
  - `Tcl_CreateCommand()` registers `xschem_and_present` as `xschem`;
  - after `fix_broken_tiled_fill` is read from Tcl: forced to 1 (no tiled fills in Aqua Tk);
  - after `display` is set: `aqua_init(interp, display, &debug_var)`, which initialises the
    Tcl and Tk stubs used by `aqua.m` and reads `XSCHEM_AQUA_SCALE`;
  - after the extra files on the command line are loaded: `aqua_open_pending` when `has_x`.

### 4.7 `src/xschem.tcl`

Hooks at existing sites (16):

| Proc or place | Change |
|---|---|
| `convert_to_pdf`, unix branch | returns `aqua_convert_to_pdf` |
| `key_binding` | `Alt-` becomes `Option-` |
| simulation configuration dialog (`.sim`) | `<MouseWheel>` scrolling |
| `cellview` (`.cv`) | `<MouseWheel>` scrolling |
| `traversal` (`.trav`) | `<MouseWheel>` scrolling |
| `save_file_dialog` | returns `aqua_save_file_dialog` with the same arguments |
| `context_menu` | returns `aqua_popup_menu .ctxmenu` once the buttons are packed |
| `tab_ctx_cmd`, "Open directory" | `open` instead of `xdg-open` (two lines) |
| `tab_context_menu` | returns `aqua_popup_menu .ctxmenu` |
| `set_tab_names` | calls `aqua_tabs` |
| `set_bindings`, the `DISPLAY` test | `|| [is_aqua]` (no `DISPLAY` on a Mac) |
| `set_bindings`, the `[info tclversion] >= 8.7` wheel branch | `|| [is_aqua]`, to compute the wheel states |
| `set_bindings`, after the Windows bindings | calls `aqua_bindings` |
| `pack_widgets`, the `DISPLAY` test | `|| [is_aqua]` |
| `build_widgets`, at the end | calls `aqua_menus` |
| widget construction at file level, the `DISPLAY` test | `|| [is_aqua]` |

One more change in `tab_ctx_cmd` is not a hook and applies on every platform: the actions
`term` and `simterm` (tab menu entries "Open circuit dir. term." and "Open sim. dir. term.")
call `eval execute 0 $terminal` instead of `execute 0 $terminal` (two lines; section 6).

The block between `### macOS native Tk (Aqua)` and `### end of macOS native Tk`, after
`getmousey`, holds in order: `is_aqua`, `aqua_button`, `aqua_state`, `aqua_wheel`,
`aqua_bindings`, `aqua_menus`, `aqua_tabs`, `aqua_popup_menu`, `aqua_save_file_dialog`,
`aqua_convert_to_pdf`, and a section that runs only when `has_x` exists and `is_aqua` is
true: `::tk::mac::Quit`, `tkAboutDialog`, `::tk::mac::ReopenApplication`,
`::tk::mac::OpenDocument` with `aqua_open_pending`, the `set_ne` defaults of section 3.7,
`aqua_wheel_units`, `aqua_wheel_interval`, `fix_broken_tiled_fill` set to 1 with `set`, so
that, unlike the defaults, it overrides an `xschemrc` value and matches the value forced in C
(section 4.6), and `aqua_command_keys`. `aqua_menus` also disables the Options menu entry "Fix
for GPUs with broken tiled fill". Each proc is described in section 3.

`is_aqua` returns 0 when the `tk` command does not exist, which is every run with `-x`, so the
hooks are also inert in headless runs of the Aqua build.

### 4.8 `README_MacOS.md`

A new first section, "Build instructions for macOS (native Aqua build)": a note that the build
belongs to this fork and was developed with an AI coding assistant, prerequisites (with
Ghostscript for PDF export), `./configure --aqua`, `--aqua-tk`, running from `src/`, installing,
and a pointer to the
application bundle, described as intended to run on other Macs without Homebrew and verified
so far only on the build machine with a scrubbed environment. The existing XQuartz
instructions follow under a new heading, "X11 build with XQuartz", unchanged.

### 4.9 New files

**`src/aqua.h`** (C89, included by `xschem.h`). In reading order: a check that `HAS_CAIRO` is 1
(the Aqua build requires cairo); prototypes grouped as init, pixmaps, front buffers, redirected
Xlib calls, present, fonts; declarations of the Xlib calls `aqua.m` supplies (`XSetTile`, and
for Tk 8.6 `XDrawRectangles`, `XDrawArcs`, `XFillArcs`); the redirect macros of section 3.4,
skipped when `AQUA_NO_REDIRECT` is defined, which `aqua.m` does so that its own calls reach
Tk.

**`src/aqua.m`** (Objective-C, compiled with `OBJCFLAGS`, not C89). In reading order:

1. Licence header and a module comment that states the model of section 3.2.
2. Includes: `../config.h`; `USE_TCL_STUBS` and `USE_TK_STUBS`, because libtk 8.6 does not
   export `Tk_MacOSXGetCGContextForDrawable()` and `Tk_MacOSXGetNSWindowForDrawable()`;
   Cocoa, Tcl, Tk, `tkInt.h` (section 9.3), `tkMacOSX.h`, cairo, and `aqua.h` with
   `AQUA_NO_REDIRECT`. The file does not include `xschem.h`, so its two lists use `calloc()`
   and `free()`.
3. The `AquaPix` and `AquaFront` structures, a category declaring Tk's
   `-[NSView addTkDirtyRect:]`, file statics, and `dbg_aqua()`, which prints when xschem's
   `debug_var` is at least the given level.
4. `xserver_ok()` (section 3.8).
5. `aqua_init()`: stubs initialisation (exits with a message on failure) and
   `XSCHEM_AQUA_SCALE`. Every `aqua_*` function that calls Tcl or Tk runs after it, since all
   are reached only when `has_x` is set. The exceptions do not use the stubs: `xserver_ok()`
   runs from `main()` before Tcl starts, and `aqua_nesting()`, a plain counter, is called by
   every `xschem` command, also when `has_x` is 0 and `aqua_init()` never runs. The module
   comment says the same: the functions that draw or present run after `aqua_init()`, and
   `aqua_nesting()` and `xserver_ok()` do not need it.
6. `window_scale()`: `XSCHEM_AQUA_SCALE` if set to a positive value (used as given),
   otherwise the window's `backingScaleFactor`, or the main screen's when the window has no
   NSWindow yet, at least 1.
7. Pixmaps: `find_pix()`, `release_cg()`, `bitmap_surface()`, `aqua_create_pixmap()`,
   `aqua_free_pixmap()`, `aqua_pixmap_surface()`, `aqua_scale_mismatch()`.
   `aqua_create_pixmap()` returns the unregistered pixmap if Tk gives no 32-bit bitmap, and
   prints a message; `aqua_pixmap_surface()` of an unregistered drawable prints a message and
   returns a 1x1 scratch surface, because the callers, written for X11, never expect a NULL
   surface. xschem keeps running and its cairo drawing is lost.
8. Front buffers: `find_front()`, `front_event()` (DestroyNotify), `aqua_front_sync()`,
   `aqua_drawable()`, which also marks the front buffer dirty.
9. Xlib calls: `clip_to_gc()`, `aqua_copy_area()`, `stipple_begin()`/`stipple_end()` and the
   four `aqua_fill_*()` functions. `aqua_fill_arc()` fills a pie slice, the GC default arc
   mode.
10. Present: `window_rect()` (the Tk window's rectangle in its NSWindow's content view, in
    AppKit's bottom-left coordinates, summing `Tk_X + border_width` up to the toplevel),
    `draw_front()`, `aqua_present()`, `aqua_nesting()`, `aqua_flush()`. `aqua_present()` uses
    `addTkDirtyRect:` when the view responds to it and `setNeedsDisplayInRect:` otherwise.
    `draw_front()` crops the needed pixel rectangle from a `CGBitmapContextCreateImage()`
    snapshot and draws it with interpolation off when the scales match.
11. `aqua_toy_font_face()` (section 3.4).
12. `XSetTile()` and, for Tk 8.6, `XDrawRectangles()`, `XDrawArcs()`, `XFillArcs()`.

**`src/xschem_terminal.sh`**: accepts `-e cmd args...` (each argument shell-quoted) or
`-e 'cmd string'` (a single argument, run by the shell as `xterm` does) and ignores other
options, except `-a app`, which names the terminal application (default `Terminal`; a user's
`xschemrc` can set `terminal` to `/bin/sh $XSCHEM_SHAREDIR/xschem_terminal.sh -a iTerm`).
Without `-e` it runs `open -a` on the current directory, so the terminal opens its own login
shell there and closing the window asks no question. With a command it writes a `.command`
file under `$TMPDIR` that removes itself, changes to the current directory and runs the
command, and opens it with `open -a`. Only Terminal.app has been tried. It is installed only for `--aqua` builds and is run through `/bin/sh`, so
its execute bit does not matter.

**`XSchemMac/`** (documented in `XSchemMac/README.md`):

- `make_app.sh`: refuses a binary that links libX11 or MacPorts libraries directly (`otool -L`
  of the binary only; libraries pulled in by cairo are copied like any other); copies the
  binary to `Contents/MacOS/xschem-bin` and the closure of its non-system libraries into
  `Contents/Frameworks`, rewrites their install names to `@rpath/...`, drops build-machine
  rpaths and adds `@executable_path/../Frameworks`; copies the Tcl and Tk script
  libraries; copies xschem's runtime files using the file lists of the `install` targets of the
  Makefiles (including the `append` line for `xschem_terminal.sh`); appends to the bundled
  `xschemrc` a block that maps the compiled-in `XSCHEM_LIBRARY_PATH` into the bundle; builds
  the launcher with the minimum macOS version read from the binaries; makes the icon from the
  Windows installer's 256x256 image; fills `Info.plist`; copies the licence texts of xschem and
  of each Homebrew package; signs everything ad hoc (Apple Silicon requires every binary to be
  signed, and `install_name_tool` invalidates the original signatures); and fails if any
  bundled Mach-O file still references `/opt/homebrew`, `/opt/local` or `/usr/local`, or if a
  Mach-O file lies outside `Contents/MacOS` and `Contents/Frameworks`.
- `launcher.c`: the bundle's executable. It resolves its own path, sets `TCL_LIBRARY`,
  `TK_LIBRARY` and `XSCHEM_SHAREDIR` to the bundle's copies, appends `/opt/homebrew/bin` and
  `/usr/local/bin` to `PATH` (an application started from the Finder gets
  `/usr/bin:/bin:/usr/sbin:/sbin`), and `execv()`s `Contents/MacOS/xschem-bin`, keeping the
  process id that Launch Services (the macOS service that starts applications) started, so
  Apple events and the Dock icon belong to xschem.
- `Info.plist.in`: bundle metadata, `NSHighResolutionCapable`, document types for `.sch` and
  `.sym`, declared as imported types so that Xschem does not claim the extensions, which other
  EDA tools also use.
- `README.md`: build, bundle layout, how to hand the app to someone else (ad hoc signature and
  Gatekeeper, the macOS check that blocks unsigned downloaded applications), licences. Its
  introduction states that the app is intended to run without Homebrew or XQuartz on the
  target Mac, has been verified only on the build machine with a scrubbed environment, and
  has not been tried on a Mac without Homebrew.

## 5. The C change outside the flag: width casts in draw.c

**The bug.** `filledrect()`, `drawrect()`, `drawtemprect()` and `MyXCopyAreaDouble()` compute
widths and heights as

```
(unsigned int)x2 - (unsigned int)x1
```

with `x1`, `x2` doubles. When a shape is clipped at the left or top edge, `x1` is negative.
Converting a double whose integral part cannot be represented in the unsigned type, such as a
negative one, is undefined in C (ANSI C89 3.2.1.3, C99 6.3.1.4). On x86-64 the generated code
in practice yields the value modulo `2^32` (the test below confirms this for the compiler used),
so the subtraction gives `x2 - x1`. On arm64 the conversion instruction saturates negative
values to 0, so the width becomes `x2` instead of `x2 - x1`. Visible effects: the right edge
of a rectangle outline clipped at the left edge is drawn in the wrong place, small rectangles
near the edge vanish, and `MyXCopyAreaDouble()` leaves selection and move-ghost residue near
the top and left edges. The code is shared, so the same should happen in an X11 build on any
arm64 machine; that was not tested.

**The fix.** Twenty lines, each operand converted to `int` first:

```
(unsigned int)(int)x2 - (unsigned int)(int)x1
```

All 20 sites have `double` operands (`xx1`...`yy2` and `x1`...`y2` in `filledrect()` and
`drawrect()`, `x1`...`y2` in `drawtemprect()`, `isx1`...`isy2` in `MyXCopyAreaDouble()`).
Conversion of a double to `int` is defined for values in `int` range, and `int` to
`unsigned int` is defined modulo `UINT_MAX + 1` (`2^32` here), so the result is exactly what
x86-64 produced before for every coordinate in `int` range. Outside that range the new
expression is undefined as well (the old one was defined for positive values below `2^32`);
at the arc sites, whose `xx`/`yy` coordinates are not clipped, such values already make the
unchanged `(int)xx1` position argument undefined.
`(unsigned int)(x2 - x1)` would not be equivalent, because truncating the difference differs
from the difference of the truncations.

**Checks.** A standalone program evaluated the old and the new expression over 142,823,023
`(x1, x2)` pairs: `k + f` for integers `k` from -1500 to 1500 and `-(k + f)` for `k` from 1
to 1500, with seven fractions `f` from 0 to 0.999999, plus 56 values of each sign (eight
magnitudes from 32767 to 2147483000, each with the seven fractions); `x1` takes all 31,619
values and `x2` every seventh. Built for x86-64 (run under Rosetta) at `-O0` and `-O2`, old
and new agree on every pair. Built for arm64, the new expression has the same checksum as the
x86-64 results and the old one differs on 126,832,358 pairs. In the GUI, a scripted test on
`0_examples_top.sch` moving a selection over stippled shapes and pressing Escape, and drawing
a rubber band over them, left 7536 and 7104 differing pixels with the old code and 0 and 0
with the fix. The test program and GUI script are not part of the patch.

With `XSCHEM_AQUA` undefined, the preprocessed `draw.c` differs from the base commit's only in
these 20 lines (section 6). The hunks do not depend on anything else in the patch and can be
taken as a separate commit.

## 6. What does not change for X11 and Windows

**C sources.** Apart from the casts and a comment in `xschem.h`, every hunk in the existing C
files has one of these forms:

- `&& !defined(XSCHEM_AQUA)` added to an existing `__unix__` test (16 sites);
- a new `#if defined(__unix__) && !defined(XSCHEM_AQUA)` ... `#endif` around a file static
  that only X11 code uses (`hints_ptr`, and `xcolor_exact, xcolor`, in `xinit.c`);
- a new `#if defined(XSCHEM_AQUA)` branch placed before an existing `#ifdef __unix__ ... #else`
  chain, which becomes `#elif defined(__unix__)` with its body unchanged;
- in `update_statusbar()`, an existing `#else` that becomes `#elif !defined(XSCHEM_AQUA)`; there
  and in the declarations of `resetwin()`, an `#elif defined(XSCHEM_AQUA)` branch inserted
  before an existing `#else`;
- a new `#ifdef XSCHEM_AQUA` (in `xschem.h`, `#ifndef XSCHEM_AQUA` around the Xpm include, and
  in `scheduler.c` around the one statement of the `xschem set fix_broken_tiled_fill` setter)
  block. In `toggle_fullscreen()`, at `Tcl_CreateCommand()` and in the Expose case it has an
  `#else` that holds the existing code unchanged; before `Tk_Init()` it ends in a C `else`, so
  that the existing call becomes that branch;
- in `err()`, the declaration `int l=250;` moved inside the existing conditional.

The static wrappers and the `err()` change leave the X11 text unchanged, since `__unix__` is
defined there, but they do change the Windows text of `xinit.c`: `hints_ptr`, `xcolor_exact`,
`xcolor` and the `l` in `err()` were compiled, unused, on Windows and no longer are (see
**Windows** below).

**Check.** Every `src/*.c` file of the tree and of `c15c6c05` was preprocessed with the
`CFLAGS` and `config.h` of a plain `./configure` (X11 build, on macOS with MacPorts Tcl/Tk and
XQuartz headers), `gcc -E -P`, and compared after removing blank lines (added comment and `#if`
lines shift blank lines). Result: 34 files compared, all identical except `draw.c`, whose
difference is exactly the 20 cast lines of section 5. The `#ifndef XSCHEM_AQUA` in the
`fix_broken_tiled_fill` setter of `scheduler.c` was added after that run; `scheduler.c` was
then preprocessed again on its own with the same flags, and its text (17828 non-blank lines)
is identical to the base commit's. The
generated parsers (`expandlabel.c`, `eval_expr.c`, `parselabel.c`) are not tracked in git and were not compared; their bison and
flex sources are unchanged. The same comparison with a `--debug` configuration differs, in
addition, in `scheduler.c`, by the `__TIME__` string behind `xschem get build_date`. The
headers are covered because every `.c` file except `icon.c` and `rawtovcd.c` includes
`xschem.h`; `aqua.h` is not included when the flag is off.

To repeat this on Linux (in `sh` or `bash`, from a clone of the patched tree):

```
mkdir /tmp/xschem-base
git archive c15c6c05 | tar -x -C /tmp/xschem-base
(cd /tmp/xschem-base && ./configure)
./configure
CF=$(sed -n 's/^CFLAGS=//p' Makefile.conf)
for f in src/*.c; do
  b=$(basename "$f")
  [ -f "/tmp/xschem-base/src/$b" ] || continue
  (cd src && gcc -E -P $CF "$b" | grep -v '^ *$') > /tmp/port.i
  (cd /tmp/xschem-base/src && gcc -E -P $CF "$b" | grep -v '^ *$') > /tmp/base.i
  cmp -s /tmp/port.i /tmp/base.i || echo "differs: $b"
done
```

Expected output: `differs: draw.c` only.

**Generated build files.** A plain `./configure` and a `./configure --debug` of the patched
tree and of `c15c6c05` (in separate copies, on the same Mac) produce byte-identical
`Makefile.conf`, `config.h` and `src/Makefile`. The only differences in configure's output are
the line numbers in three pre-existing `-Wcomment` warnings printed while `hooks.c` is
compiled, and the path of the scratch copy. `./configure --help` lists the two new options.

**Tcl.** All new procs live in the Aqua block; the only top-level code that runs there is
guarded by `[info exists has_x] && [is_aqua]`. Each of the 16 hooks either sits behind an
`[is_aqua]` test (`if`, or `elseif` in `tab_ctx_cmd`) or adds `|| [is_aqua]` to an existing
condition. `is_aqua` is `[info commands tk] ne {} && [tk windowingsystem] eq {aqua}`, which
is 0 on X11 (including
XQuartz Tk, whose windowing system is `x11`), on Windows (`win32`) and in every run without Tk.
Headless runs therefore execute the same Tcl paths in both builds, and the `netlisting` and
`create_save` suites below exercise them. No X11 GUI session was run with the modified
`xschem.tcl`; that part rests on reading the code.

**Tcl, on every platform.** Two lines of `tab_ctx_cmd` change outside any `is_aqua` test: the
tab menu entries "Open circuit dir. term." and "Open sim. dir. term." (actions `term` and
`simterm`) run `eval execute 0 $terminal` instead of `execute 0 $terminal`. `get_shell`
(Simulation > "Shell [simulation path]") already runs `eval execute 0 $terminal`, and the
simulator commands expand `$terminal` through `subst` and `eval execute`. For a one-word
`$terminal`, such as the default `xterm`, `eval` produces the same call as before. A value of
several words, such as the Aqua default `/bin/sh .../xschem_terminal.sh`, used to reach
`open "|..."` in `execute` as a single program name and fail with "Can not execute"; it is
now split into a program and its arguments, as in `get_shell`. A single program path that
contains spaces now needs list quoting in these two entries, as it already does in
`get_shell` (from reading the code). The Windows branch of both actions does not use
`$terminal` and is unchanged.

**Windows.** No new `.c` file is added, so `XSchemWin/XSchemWin.vcxproj` is unchanged;
`aqua.m` is built only by the `--aqua` makefile rule. The Windows build was not compiled; the
argument is the structure of the conditionals above, under which Windows (`__unix__`
undefined) takes the same branches as before. The one difference in the compiled text is in
`xinit.c`: the file statics `hints_ptr`, `xcolor_exact`, `xcolor` and the local `int l` of
`err()`, which only X11 code uses, are no longer declared on Windows (from reading the
conditionals).

**`./configure --aqua` elsewhere.** On a system without Homebrew, `find_aqua()` finds none of
the packages under `/opt/homebrew/opt`, prints the `brew install` line and stops; it does not
affect builds without `--aqua`.

## 7. Testing

### 7.1 Machine

One Apple Silicon Mac, macOS 26, built-in Retina display (backing scale 2), Homebrew
`tcl-tk@8` 8.6.18 and cairo 1.18.6. The X11 reference build, on the same Mac, used MacPorts
Tcl/Tk 8.6.17 for X11, MacPorts libX11 and MacPorts cairo 1.17.6; its C sources preprocess
to the same text as the base commit's. Its `Makefile.conf` needed one hand edit: the plain
`./configure` picked the MacPorts 8.6 headers but `-ltcl8.5 -ltk8.5`, changed to
`-ltcl8.6 -ltk8.6`. GUI checks ran with `DISPLAY` unset and stdin from `/dev/null`, as a
Finder launch has.

### 7.2 Results on the submitted code

| Check | Result |
|---|---|
| `./configure --aqua && make` (release) | 38 compiler invocations, 0 warnings; the binary links Homebrew Tcl, Tk, cairo, libjpeg and system frameworks only (`otool -L`), no X11 library directly (Homebrew's cairo links `libX11`, `libxcb`, `libXext` and `libXrender`) |
| `./configure --aqua --debug` build | 394 warnings: 350 `-Wstrict-prototypes` from `xschem.h`, the rest `-Wstrict-prototypes`, `-Wfloat-conversion`, `-Wshorten-64-to-32` and `-Wmisleading-indentation` in shared files; one, `-Wshorten-64-to-32` on `return xc->pixel;` in `find_best_color()`, is in the existing Windows branch that only the Aqua build compiles with clang |
| `aqua.m` | no warnings with `-Wall` at `-O0` and `-O2` |
| Flag-off preprocessing, generated build files | section 6 |
| `netlisting` suite, Aqua release binary, gold from the X11 release build | 1496 of 1496 PASS; the 1476 result files are identical |
| `create_save` suite (10 files), same gold | 10 of 10 PASS, both with `-x` added to the suite's command and as shipped (the shipped suite does not pass `-x`; it ran headless because the process had no window-server access, section 3.8) |
| Headless detection | a process without window-server access starts with `has_x` 0, creates no Tk window and writes the netlist without `-x`; a normal session starts the GUI |
| Scripted GUI smoke test, `cmos_inv.sch`, `poweramp.sch` and `0_examples_top.sch` | 21 of 21: window captured at 2 pixels per point; rubber band drawn and erased by Escape (0 pixels differ); move ghost drawn and the schematic restored by Escape (0 pixels differ); 2 Expose events in 1.5 s idle; pointer position to schematic coordinates; a wire drawn under the pointer; `xschem print png` at 400x300 and at `0 0` of exact size; `print svg`; window back at native scale after printing (0 pixels differ); resize and redraw; second tab (`poweramp.sch`) drawn; stippled fill visible; crosshair drawn and removed; file-dialog preview pane drawn |
| Scripted input and UI test, Tk events injected with `event generate` | 41 of 41: button translation, wheel zoom and pans, trackpad rate limit, the Command keys A, Backspace, Z, =, minus, 0, T, W, Shift-{ and Shift-} of the table (not S, Shift-S, O, N, Shift-Z, X, C, V, F, +), Command-Q and unassigned Command keys not acting as Alt, Option-s as Alt-s, arrows and Ctrl-arrows with Fn/keypad flags, Ctrl-$ and `xschem set draw_window 1`, tabs, menu labels and entries, defaults, context menu through `aqua_popup_menu` with `tk_popup` replaced by a stub, `::tk::mac::OpenDocument` and `::tk::mac::Quit` called directly, fullscreen with `wm attributes` replaced by a stub |
| Pointer motion load: 100 moves in wire mode | 894 ms and 130 Expose events (883 to 1339 ms in the five smoke runs of the final integration builds, one of them with `draw_window 1`; earlier builds measured up to 1819 ms on the same, shared machine); no X11 comparison |
| `make_app.sh` | no warnings, `codesign --verify --deep --strict` passes, bundle 43 MB, minimum macOS 26.0, arm64 |
| Bundle, launched with `env -i HOME=<scratch> PATH=/usr/bin:/bin` on the build Mac (from a shell, not from the Finder) | GUI up, no console, share directory and Tcl/Tk libraries from inside the bundle, `PATH` extended, `xschem print pdf` wrote a 17 kB PDF through `/opt/homebrew/bin/ps2pdf` |

The smoke test and the input test ran before the last change to `xschem.tcl` (the native save
dialog, the `<Leave>` binding, the `fix_broken_tiled_fill` setting and menu entry, the two
`eval` lines, and the unstartable-converter branch of `aqua_convert_to_pdf`) and were not
repeated after it. The headless suites do not run the changed procedures. The change was
checked by separate scripted runs, listed below. Three later edits came after all checks in
this section and were not tested: the `.eps` entry added to the save panel's filter, the
reworded comments of `aqua_popup_menu` and `aqua_save_file_dialog`, and the `#ifndef
XSCHEM_AQUA` around the `fix_broken_tiled_fill` setter in `scheduler.c`. `src/xschem` was
rebuilt after the last of them; none of the checks in this section was repeated with that
binary.


- The two tab menu terminal entries, with the Aqua default `terminal` and `open` replaced by a
  stub that logs its arguments: each runs `open -a Terminal <file>.command`, with no error
  dialog.
- With `fix_broken_tiled_fill` set to 0 by `--preinit` (as an `xschemrc` could set it), the
  Tcl variable and the C value are both 1 and the Options menu entry is disabled.
- The drawing's `<Leave>` binding passes `[aqua_state %s]` (the binding text was checked; no
  Leave event was injected).
- With `to_pdf` set to a file that exists but cannot be started, `xschem print pdf` shows
  exactly one dialog, the one from `execute`.
- PDF export through the native save sheet: Cancel, and Save with `tk_getSaveFile` stubbed
  (section 7.5).

Checked on a build that predates the last edits to `callback.c`, `xinit.c`, `aqua.m` and
`aqua.h`, and not repeated on the submitted binary:

- `draw_window 1`: the smoke test (21 of 21) and the stipple residue test (0 and 0 pixels).
- EPS export: headless `xschem print eps` after `select_all` writes a byte-identical file with
  the Aqua and the X11 build; in the GUI, `xschem print eps` and File > Image export > EPS
  Selection Export write the file, and without a selection the "works only on a selection"
  alert appears.
- PDF export error dialog: with `to_pdf` set to a missing program, to `/usr/bin/false`, and
  with `ps2pdf` absent from `PATH`, the dialog of section 3.7 appears with the matching message
  and the PostScript is kept. The procedure has changed since only in the branch for a
  converter that is found but cannot be started, checked on the current code above.
- `open_close` suite (debug builds, 1903 files): 33 files differ between the Aqua and the X11
  build, all in `symbol bbox: text bbox` lines of multi-line texts. An X11 build linked against
  the Homebrew cairo used by the Aqua build differs from the Aqua build in 0 files and from the
  MacPorts-cairo X11 build in the same 33, so the difference comes from the cairo version
  (1.18.4 against 1.17.6), not from the port.

### 7.3 What a reviewer can rerun

With what is in the patch:

- The build itself (section 2) and the flag-off and configure comparisons (section 6).
- The `tests/` suites against the Aqua binary, from `tests/` with `xschem` on `PATH` (or
  `xschem_cmd` set in `tests/test_utility.tcl`). `netlisting.tcl` and `open_close.tcl` pass
  `-x` and run headless anywhere. `create_save.tcl` does not pass `-x`, so in a normal macOS
  login session it opens xschem windows, as it does on X11 when `DISPLAY` is set. Gold
  directories are not in git; produce them from an X11 build. Comparing `open_close` across
  machines also compares cairo versions (section 7.2).
- Visual checks by hand: `XSCHEM_AQUA_SCALE=1` shows the 1x rendering for comparison.

The GUI smoke test, the input test, the cast test program, the event-injection harness of
section 7.5 and the window-capture helper are not part of the submission. On the fork, the
smoke test, the window-capture helper and the debug build script are in `XSchemMac/devtools/`
(its `README.md` explains how to run them).

### 7.4 Not verified

- A non-Retina display, and moving a window between displays of different scale. The Expose
  path that remakes `save_pixmap` on a scale change has not run; the same check in
  `xschem_and_present()` runs after every print at a set size.
- An ssh login or a launch daemon for `xserver_ok()`; only a sandboxed process without
  window-server access was tried.
- Intel Macs and the `/usr/local` Homebrew prefix; `--aqua-tk` with a non-Homebrew Tcl/Tk.
- Tk 9: `aqua.h` and `find_aqua()` contain provisions for Tk 9 headers and library names, but
  the submitted code has not been built or run against Tk 9 (an earlier version of the port
  compiled and linked against Homebrew Tk 9.1 and wrote a headless netlist; its GUI was not
  started).
- `make install` with the final build files: an earlier version, before `xschem_terminal.sh`
  was added to the install list, was installed under a `DESTDIR`.
- How the native menus render the `Cmd+...` accelerators (section 3.6); the tests read the
  `-accelerator` values only.
- Real Finder Open and Dock drops, the real Quit Apple event, native fullscreen, and the
  native context menu with a physical mouse: the automated checks call the Tcl procs directly
  or stub `tk_popup` and `wm attributes`. The context menu was used by hand only for the case
  of section 7.5.
- A real Save through the native save sheet (only Cancel, and Save with `tk_getSaveFile`
  stubbed, section 7.5), and the sheet for the callers other than PDF export (Save as, PNG,
  SVG and EPS export, saving before descending, making a schematic from the selection).
- Physical keyboards: modifier states, Option composition and Fn/keypad flags were injected.
  Non-US keyboard layouts and Caps Lock combined with Command shortcuts were not tried.
- The external editor (TextEdit through `open -W -n -e`) and `xschem_terminal.sh` with a real
  Terminal window; the wrapper was checked on its own, with `open` replaced by a stub that
  runs the generated `.command` file (quoting, a directory name containing a quote,
  self-removal); started from xschem only by the two tab menu entries, with `open` replaced by
  a stub that logs its arguments (section 7.2).
- Simulation end to end (ngspice or other simulators started from xschem).
- `Xschem.app` on a Mac without Homebrew, quarantine and Gatekeeper handling, and the bundle
  running from a read-only or randomized location.
- The X11 GUI and the Windows build with the patch applied (section 6).
- Performance against X11 on the same hardware, and memory use, beyond the figure in 7.2.

### 7.5 Reports of an unresponsive canvas

Two hands-on reports on the build Mac described the drawing area no longer responding. Neither
was reproduced by script, and the cause of neither is known.

**After a context-menu choice.** After choosing "Insert wire" from the native context menu
with a real mouse, the canvas stopped responding. `aqua_popup_menu` destroys the button
toplevel before posting the menu, so that no NSWindow is destroyed while the menu tracks
(section 3.6), and runs no `update` afterwards. With this procedure the application was
rebuilt and the same action retried by hand on that Mac, and the freeze did not recur. That
is one manual observation; since the failure was never reproduced, it does not show that the
change removed its cause.

In a fork-local harness that posts mouse events as NSEvents inside the application, the
submitted procedure keeps the xschem window as key window through the menu, and a click after
choosing "Insert wire" places the wire (4 of 4 checks, one run). A variant that withdraws the
toplevel, posts the menu, then destroys both and calls `update` was run three times with
clicks (once with an earlier version of the harness): it kept the key window in one run and
lost it after the menu in the other two, and in one of those two the click after the menu did
not place a wire (1 of 4 checks failed), although a later click still selected. The
conditions of that failing run, in which the key window was already gone while the menu was
up, were not repeated with the submitted procedure. A keyboard-driven form of the same check
did not select "Insert wire" with either procedure and says nothing either way. The reported
unresponsiveness itself was not observed with either procedure in the harness.

**After PDF export through xschem's file dialog.** In the second report, PDF export through
xschem's own two-pane file dialog, then used by every `save_file_dialog` caller on Aqua, was
hard to use, because reaching another folder took many steps, and afterwards the canvas did
not respond. Scripted runs of the same export with the same harness, ending the dialog with
OK, OK with the overwrite confirmation, Cancel, the window's close button, Escape, and after a
click on the drawing while the dialog was open, did not reproduce it: every exit left the
semaphore at 0 and the xschem window as key window, and afterwards a click selected and
pointer motion reached the drawing (every check passed in each of the six runs). In the run with the
click the dialog stayed in front of the main window. The likeliest explanation, from
reasoning and not from an observation, is that the dialog, which is not transient for the
main window, ended up behind it while still waiting, so that the drawing stayed locked by the
semaphore with no dialog in sight. On Aqua `save_file_dialog` now uses the native save panel
as a sheet attached to the xschem window (section 3.6), which cannot end up behind that
window.

The sheet was checked with the same harness for PDF export only. Cancel: the panel came up as
a sheet with the expected title, folder and name, was answered with Cancel, the semaphore was
back at 0, and a click afterwards selected. Save: only with `tk_getSaveFile` replaced by a
stub that returns a path; the PDF was written (17,522 bytes) and a click afterwards selected.
In these runs the application was not the active one (no key window before or after the
export), so their pointer-motion checks failed before the export as well as after it and say
nothing either way. A real Save through the sheet has not been tried and needs a manual
check.

## 8. Known limitations and behaviour differences

Consequences of the display model:

- **Minimum line weight.** The thinnest line is one point: two device pixels on Retina. X11 on
  a 1x screen draws one-pixel lines; this build cannot draw one-device-pixel hairlines.
- **Whole-point geometry.** Xlib coordinates are integers in points, so curves are flattened
  to a one-point grid; beziers (for instance the logo in `title.sym`) show steps of two device
  pixels. Drawing beziers with cairo in `draw.c` would avoid this; it is not done.
- **Stipples** are one stipple bit per point, the size they have on a 1x X11 screen.
- **PNG export without a size** (`xschem print png file` with no selection) writes
  `save_pixmap` as it is, at the backing scale: 2000x1256 pixels for a 1000x628-point
  window on Retina. With explicit sizes, or `0 0`, the size is exact.
- **Memory.** Each window holds a front buffer and a `save_pixmap`, both at the backing scale:
  about 10 MB each at 4 bytes per pixel for a 1000x628-point window on Retina (from the
  allocation sizes; not measured).
- **Present cost.** Every present requests a redraw of the whole drawing area; there is no
  dirty-rectangle tracking.
- **Cairo-only updates.** `aqua_drawable()` marks a front buffer dirty; cairo drawing into
  `cairo_sfc` does not. A command whose only drawing on the window is cairo drawing would not
  be presented by `aqua_flush()` until something else draws or an Expose arrives. No case was
  found in testing; the code was not searched for one.

Features not implemented on Aqua:

- Screen grab (Print key, `xschem grabscreen`).
- Caps Lock and Num Lock indicator in the status bar (left empty).
- Interrupting a long selection redraw with new events (`pending_events()`).
- The "Xserver options" section of `xschem globals`.
- A window icon outside the application bundle (the Xpm icon code is excluded).
- Tiled fills. `fix_broken_tiled_fill` is set to 1 at startup in C and in Tcl, whatever
  `xschemrc` says, and the Options menu entry "Fix for GPUs with broken tiled fill" is
  disabled. `xschem set fix_broken_tiled_fill` leaves the C value at 1 (the assignment is
  compiled out), so the Tcl variable, the checkbox and the C value stay at 1; `XSetTile()` is
  a no-op and Aqua Tk ignores the fill style, so turning the setting off would break the
  erasing of temporary drawing. `xschem get fix_broken_tiled_fill` keeps returning 1.
- Translation of mouse-button numbers in `replace_key` remaps: `key_binding` binds the user's
  button numbers directly, so a remap of `Button-3` acts on Aqua's middle button (from reading
  the code).
- Simulation status colour: on X11 the Simulate entry of the menu bar changes colour with the
  simulation state; on Aqua the Netlist and Simulate entries used are plain entries in the
  Simulation menu.
- The links in the About dialog still call `xdg-open`.

Other differences:

- Save-type dialogs (`save_file_dialog`) are the native save panel, shown as a sheet; the
  Open, Merge and symbol-insertion dialog (`load_file_dialog`) is xschem's own, with its library
  path list and preview (section 3.6). Open bug: in that dialog the preview pane stays blank
  when a schematic is selected with the mouse (observed by hand on the application bundle; the
  smoke test's preview check draws into a frame of its own and passes, so it does not cover the
  real dialog). The cause has not been found. The panel's filter accepts only the extensions of the
  caller's pattern: Tk sets the panel's allowed file types to them and, since
  `aqua_save_file_dialog` adds no all-files (`*`) entry, does not allow other extensions
  (`Tk_GetSaveFileObjCmd()` in `macosx/tkMacOSXDialog.c`).
  EPS export proposes `<name>.eps` with the pattern `*.{ps,pdf}`; `aqua_save_file_dialog` adds
  `.eps` to the list when the proposed name has that extension, so the panel accepts it (from
  reading the code; EPS export through the panel was not tried).

- The `-accelerator` strings read `Cmd+s`, `Cmd+Shift+S` and so on, built from the Tk event
  names; the menus show them as native key equivalents (section 3.6).
- PDF export needs Ghostscript (`brew install ghostscript`); without it a dialog explains this
  and the PostScript file is kept.
- `Xschem.app` requires the macOS version the Homebrew bottles were built for (26.0 for the
  bundle tested) and the architecture of the binary. `XSchemMac/README.md` says Apple Silicon;
  `make_app.sh` itself packages whatever architecture `src/xschem` has, and only arm64 was
  built.
- `aqua.m` is compiled with `$(CC)`; on macOS `gcc` is clang. A real GCC as `CC` is not
  expected to compile it (Apple's Cocoa headers need clang; not tried). No `-rpath` is added,
  which is fine for Homebrew's absolute install names but not for a custom `--aqua-tk` Tk
  built with `@rpath` names.
- In testing (on an earlier build), erasing the graph cursor left two antialiased pixels on
  the graph's dashed border. Not investigated.
- With stdin closed or `/dev/null`, a GUI run's stdout and stderr go to `/dev/null`
  (section 3.6).

## 9. Questions for the maintainer

### 9.1 Parts that could be left out of a first submission

Line counts from the current files. Each part can be removed without breaking the rest,
except where noted.

| Part | Approximate lines | Without it |
|---|---|---|
| `XSchemMac/` bundle | 639 in four files, plus 3 in `.gitignore` and the bundle paragraph in `README_MacOS.md` | users run `src/xschem` or `make install` |
| `./configure --aqua` | `hooks.c` +223, `Makefile.conf.in` +7, `src/Makefile.in` +13 of its +16 (the other 3 install `xschem_terminal.sh`) | `Makefile.conf` and `src/Makefile` must be edited by hand: Homebrew Tcl/Tk (with the stub libraries), cairo and libjpeg flags, `-DXSCHEM_AQUA -DMAC_OSX_TK`, `OBJCFLAGS`, the `aqua.o` rule and bison |
| Command-key table and accelerator labels | about 47 Tcl (table 25, bindings 13, labels 9) | Control keys work. If the one-line `<Command-KeyPress>` no-op binding is kept, Command keys do nothing; without it, Command plus a key acts as the plain key, because `aqua_state` drops Command |
| `aqua_convert_to_pdf` | 24 Tcl (23 plus the hook) | as on Linux: a missing `ps2pdf` gets the generic "Can not execute" dialog and the PostScript stays in `XSCHEM_TMP_DIR`; a converter that fails is not reported |
| Native save panel (`aqua_save_file_dialog`) | 27 Tcl (26 plus the hook) | every `save_file_dialog` caller gets xschem's own two-pane dialog, the one of the second report in section 7.5 |
| Finder Open queue | 20 Tcl, 4 C | files opened from the Finder are not loaded |
| Trackpad rate limiting (`aqua_wheel`) | 14 Tcl, 3 bind lines, 2 defaults | the existing Tk 8.7 wheel bindings apply: one zoom or pan step per wheel event, including every event of a trackpad's stream |
| `xschem_terminal.sh` | 58, plus 3 in `src/Makefile.in` and 1 default | `terminal` stays `xterm`; the two `eval` lines of section 6 then make no difference |
| Dialog wheel bindings | 3 Tcl | the `.sim`, `.cv`, `.trav` dialogs do not scroll with the wheel |
| Netlist, Simulate and Window menu additions | 7 Tcl | Netlist and Simulate missing from the menu bar (per the comment in `aqua_menus`); no Window menu |
| `XSCHEM_AQUA_SCALE` | 8 in `aqua.m` | no way to see 1x rendering on Retina |
| Stipple emulation | 88 in `aqua.m`, 5 macro lines and 6 prototype lines in `aqua.h` | stippled layers paint solid over what is below |
| Font family mapping | 21 in `aqua.m`, 2 macro lines, 2 prototype lines | `Sans-Serif` text is never bold and `Monospace` text is not monospaced |

### 9.2 How the commits are split

On the fork's branch the patch is seven commits, in reading order. The first and third are
independent of the port and can be cherry-picked onto upstream on their own (checked with
`git apply --check` against `upstream/master`):

1. The `draw.c` casts (section 5).
2. Build support: `hooks.c`, `Makefile.conf.in`, `src/Makefile.in`.
3. The two `eval` lines of `tab_ctx_cmd` (section 6).
4. The Aqua port itself: `aqua.h`, `aqua.m`, `xschem_terminal.sh` and every `XSCHEM_AQUA`
   and `is_aqua` change in `src/`.
5. `README_MacOS.md`.
6. `XSchemMac/` and the `.gitignore` line.
7. This guide and the fork-local GUI check tools (now `XSchemMac/devtools/`).

Within commit 4 the display, input and menu parts interleave in the same files, so a finer
split would need hunk-level surgery; section 4 walks through them by function instead.

### 9.3 Dependence on Tk's private header `tkInt.h`

`aqua.m` includes `tkInt.h` for two things: the `TkpClipMask` structure that `gc->clip_mask`
points to in Tk's Xlib emulation, and `TkClipBox()`. They are used only by `clip_to_gc()`, so
that `aqua_copy_area()` and the stipple fills honour the GC clip rectangle. Homebrew installs
the header; other Tk distributions may not, and the structure is not a public interface. xschem
sets clips only with `XSetClipRectangles()` (one rectangle) and `XSetClipMask(None)`, so
`aqua.h` could record the rectangle per GC through two more macros and drop the include. That is
not implemented.

`aqua.m` also relies on Tk's `-[TKContentView addTkDirtyRect:]`, declared in a category and
used only if the view responds to it, and on the layout of Tk pixmaps (32-bit premultiplied
ARGB, 8-bit alpha for depth 1) as created by `TkMacOSXGetCGContextForDrawable()`.

### 9.4 Copyright headers and the bundle identifier

The seven new files carry "Copyright (C) 2026 Thomas Ferreira de Lima" with the GPL notice
used by the other sources (`XSchemMac/README.md` and `AQUA_PORT.md` have no header).
`Info.plist.in` puts xschem's own copyright line in the bundle's `NSHumanReadableCopyright`,
followed by the packaging copyright. `make_app.sh` defaults the bundle identifier to
`io.github.stefanschippers.xschem`, which names a namespace on the maintainer's behalf; `-i`
overrides it, and the maintainer may prefer another default.

### 9.5 Issues noticed in shared code and left alone

- `write_recent_file` uses the undefined variable `$f` in its error branch, so a non-writable
  `recent_files` produces "can't read "f": no such variable" instead of the intended message.
  Reproduced with both builds.
- `xschem print png|svg|pdf` with an explicit size ends with `change_linewidth(save_lw)`.
  After printing a zoomed-in view, all lines stayed thick (observed on the Aqua build; the code
  is shared).
- SVG export: `svg_embedded_image()` writes no `preserveAspectRatio="none"`, so images keep
  their aspect ratio in SVG while the window and PNG stretch them; `svg_draw()` sets
  `stroke-linecap:round` globally, so dashes have round caps, unlike the screen.
- `./configure --debug` on macOS leaves `scconfig/scc_*.dSYM` directories behind (scconfig's
  test programs are built with `-g`), with or without `--aqua`.

## 10. Future work: Tk 9

The port targets Tk 8.6 (Homebrew `tcl-tk@8`). Tk 9 support is planned once the Tk 8.6
version has been in use for a while; until then `--aqua` looks only for `tcl-tk@8`, and Tk 9
is reached only through `--aqua-tk=<prefix>` (`XSchemMac/devtools/build.sh 9`).

**What exists for Tk 9.** `find_aqua()` in `scconfig/hooks.c` reads the Tk 9 library names
from `tclConfig.sh` and `tkConfig.sh` and adds `-Dinline=__inline__` for Tcl 9, whose `tcl.h`
uses `inline`, which is not a C89 keyword. `aqua.h` defines its own `XDrawRectangles`,
`XDrawArcs` and `XFillArcs` only for Tk 8.6 and redirects Tk 9's. The current code has not
been built or run against Tk 9 (section 7.4).

**What an early version of the port showed on Tk 9.1.0.** Before the display model of
section 3.2 was written, an early version built and ran against Homebrew `tcl-tk` 9.1.0, on
the machine of section 7.1:

- Worked: the build, headless netlisting (netlists identical to the Tk 8.6 build), Xlib
  drawing and cairo text into pixmaps (`xschem print png` was correct), and drawing directly
  on the window at any time, which Tk 8.6 does not allow (section 3.1). Pointer-motion
  handling was about five times faster: 100 pointer moves in about 0.15 s, against 0.7 to
  1.2 s on Tk 8.6 with the same version.
- Broken: the canvas stayed black. Tk 9.1's `XCopyArea()` (rewritten in
  `macosx/tkMacOSXImage.c`) takes the source size from the source's `NSView`, which a pixmap
  does not have, so it returns `BadDrawable` (9) for every copy from a pixmap; the Tk source
  marks the case with `// XXXX Need to deal with pixmaps!`. xschem displays by copying
  pixmaps to the window, so nothing reached the screen and rubber bands were never erased.

**Why the current code may avoid that failure.** The current display path no longer relies on
Tk's `XCopyArea()` for its own buffers: `aqua_copy_area()` copies between registered pixmaps
with cairo, and `draw_front()` draws the front buffer into the window as a `CGImage` during
AppKit's redraw (section 3.2). `aqua_copy_area()` still falls back to Tk's `XCopyArea()` when
either drawable is not a registered pixmap; on Tk 9.1 that fallback fails if the source is a
pixmap.

**Steps to take.**

1. Build with `XSchemMac/devtools/build.sh 9` and run `smoke.tcl`
   (`XSchemMac/devtools/README.md`); compare its captures with the Tk 8.6 build.
2. Find out which copies reach the `XCopyArea()` fallback, and whether a Tk 9 release later
   than 9.1.0 handles pixmap sources.
3. Simplify for Tk 9: `Tk_MacOSXGetCGContextForDrawable()` is exported there, so the stubs
   lookup in `aqua_init()` is needed only for Tk 8.6. The Tk package is named `tk`, in lower
   case, under Tcl 9. Check that the Homebrew Tk 9 keg still installs `tkInt.h` (section 9.3).
4. Rerun the checks of section 7.2 on Tk 9, then decide which Tk the build recommends and
   whether `--aqua` should look for `tcl-tk` as well as `tcl-tk@8`.
