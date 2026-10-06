# Native macOS port of xschem on Aqua Tk

Date: 2026-10-05. Branch: `macos-aqua-spike` (uncommitted working-tree changes on top of `main`).

## Goal

Run xschem on macOS without XQuartz, as a normal macOS application, while keeping the
Tcl/Tk GUI and the `xschem` Tcl command set untouched. Users' `xschemrc` files, PDK setup
scripts and upstream's `xschem.tcl` must keep working.

## Constraints

- **One feature flag.** Every change is behind `#ifdef XSCHEM_AQUA` (C) or
  `[tk windowingsystem] eq "aqua"` (Tcl). With the flag off, the X11 and Windows builds must
  compile to what they are today.
- **Dependencies come from Homebrew.** Base: `tcl-tk@8` (Tk 8.6.18). The user welcomes a
  newer Tk; Tk 9.1 does not work yet (see "Tk 9.1"). Do not mix in MacPorts libraries.
- **Tcl stays.** No GUI rewrite, no new toolkit.
- **C89**, `my_*` allocators, spaces only, and the other conventions in `CLAUDE.md`.
- **Small, mergeable diff.** This fork merges `upstream/master` regularly. Prefer adding
  Aqua branches next to existing code over restructuring it.
- **Not for upstream as-is.** `CONTRIBUTING_AI_POLICY.md` rejects primarily AI-written PRs.
  `plans/`, `CLAUDE.md` and `.claude/` never go upstream.
- **No screen recording.** GUI checks use the self-capture helper below, never
  `screencapture` or a Screen Recording grant.
- **No commits** unless the user asks.

## What the spike proved

Measured on one Mac: macOS 26 (Darwin 25.6), Apple Silicon, Homebrew `tcl-tk@8` 8.6.18,
cairo 1.18.4, jpeg-turbo, bison 3.8.2. The same results were obtained earlier with MacPorts
Tk 8.6.17.

| Check | Result on Tk 8.6.18 |
|---|---|
| Build against Aqua Tk | Compiles and links; binary depends on libtk, libtcl, libcairo, libjpeg, no X11 library |
| X11 build with flag off | The six changed `.c` files still compile with the stock `Makefile.conf` flags |
| Headless netlisting (`-x -q -s -n`) | Produces the SPICE netlist, identical across the Tk 8.6 and Tk 9.1 builds |
| Static drawing in the real window | Correct: wires, symbols, filled pins, dashed boxes, cairo text, title block |
| Rubber-band wire | Drawn, and erased/redrawn correctly as the pointer moves |
| Move ghost (`select_all`, `m`) | Follows the pointer; Escape restores a clean schematic |
| Redraw load | 100 pointer moves in 0.7 to 1.2 s (7 to 12 ms each), 130 expose events; 2 expose events in 1.5 s idle |

Not tested yet: everything in the phases below.

## How it works

1. **Xlib calls go to Tk's Xlib emulation**, as in the Windows build. `__unix__` stays defined
   on macOS so POSIX code is shared; `XSCHEM_AQUA` switches off only what needs an X server.
2. **Missing emulated calls are shimmed** in `draw.c`: on Tk 8.6 `XDrawRectangles`,
   `XDrawArcs`, `XFillArcs` loop over the single-item call (Tk 9 has them); `XSetTile` is a
   no-op and `fix_broken_tiled_fill` is forced to 1 (the same model Windows uses).
3. **Front buffer.** Aqua Tk 8.6 drops any drawing on a window that happens outside a redraw
   request, and xschem draws rubber bands at any time. So drawing calls aimed at a window are
   redirected by macros in `xschem.h` (`XDrawLine`, `XCopyArea`, ...) through
   `aqua_drawable()` to an off-screen pixmap, one per window. Pixmaps can be drawn on at any
   time.
4. **Present.** `aqua_present()` copies the front buffer to the window. It runs on every
   Expose event (replacing `handle_expose()`, since the front buffer never loses content) and,
   through `aqua_flush()`, at the end of every `xschem` Tcl command (`xschem_and_present()`
   wrapper in `xinit.c`). A copy made outside a redraw request is dropped by Tk, which then
   schedules a redraw that comes back as an Expose event, where the copy lands.
5. **Cairo draws into the same pixels.** A Tk pixmap on Aqua is a `CGBitmapContext` with
   premultiplied host-order ARGB32, which is `CAIRO_FORMAT_ARGB32`. `aqua_pixmap_surface()`
   wraps that memory with `cairo_image_surface_create_for_data()`. No cairo-quartz, no
   separate text layer.
6. **`draw_window` is forced to 0**: everything is drawn on `save_pixmap` and copied.

## Tk 9.1

Homebrew `tcl-tk` is 9.1.0. The spike builds and runs against it, with these results:

- **Works:** build, headless netlisting, Xlib drawing and cairo text into pixmaps
  (`xschem print png` is correct), direct drawing on the window at any time, and the event
  loop is about five times faster (100 pointer moves in about 0.15 s).
- **Broken:** the canvas stays black. `XCopyArea()` returns `BadDrawable` whenever the source
  is a pixmap. Tk 9.1 rewrote that function (`macosx/tkMacOSXImage.c`) and it reads the
  source size from the source's `NSView`, which a pixmap does not have; the source carries the
  comment `// XXXX Need to deal with pixmaps!`. xschem's display model is pixmap to window,
  so nothing reaches the screen and rubber bands are never erased.
- **Simpler on Tk 9:** `Tk_MacOSXGetCGContextForDrawable()` is exported (no stub-table
  lookup) and `XDrawRectangles`, `XDrawArcs`, `XFillArcs` exist. The code already switches on
  `TK_MAJOR_VERSION`.
- **Build notes:** `tcl.h` of Tcl 9.1 uses `inline`, so a `-std=c89` build needs
  `-Dinline=__inline__`. The Tk package name is lower-case `tk` in Tcl 9.

Routes to Tk 9 support, to evaluate in phase 10 (route 1 overlaps with phase 4, HiDPI):

1. Replace `XCopyArea()` in the Aqua path: copy pixmap to pixmap through the shared ARGB32
   memory (cairo or `memcpy`), and present front buffer to window with `XPutImage()` or by
   drawing a `CGImage` into the window's context. This also has to honour the GC clip that
   xschem sets for partial redraws.
2. Check whether a later Tk 9 release fixes `XCopyArea()` for pixmaps, and whether Tk 9.0
   behaves differently.

## Known hacks in the spike to replace

- **Stub-table lookup (Tk 8.6 only).** libtk 8.6 does not export
  `Tk_MacOSXGetCGContextForDrawable()`; the spike fetches it from the Tk stubs table via
  `Tcl_PkgPresentEx()` (`aqua_cg_context()` in `draw.c`). Look for a cleaner route first
  (linking the Tk stub library for this one call is the obvious candidate); keep the lookup
  only if nothing better works.
- **Hand-written CoreGraphics prototypes** in `draw.c`, because the CoreGraphics headers are
  not strict C89. Move the Aqua code to its own file compiled without `-std=c89 -pedantic`,
  or keep the four prototypes if a separate flag set is not worth it.
- **Build by command-line override** (`plans/macos-aqua-tools/build.sh`). Needs a real
  configure option.
- **Front-buffer lifetime.** A cairo surface points into pixmap memory. If a front buffer is
  resized while another tab's context still holds a surface on it, that surface dangles until
  the tab's next `resetwin()`. Needs an ownership rule, not luck.
- **Fixed table of 64 front buffers**, with a `Tk_IdToWindow()` lookup on every draw call.

## Phases

Each phase ends with the smoke test passing and the flag-off X11 compile check passing.

### 1. Build system
- Add `--aqua` (name open) to `scconfig/hooks.c`: skip X11/xcb/Xpm detection, find Homebrew
  `tcl-tk@8`, cairo and jpeg-turbo, add `-DXSCHEM_AQUA -DMAC_OSX_TK` and the CoreGraphics
  framework. Plain `./configure` on this machine currently picks MacPorts headers and
  `-ltcl8.5 -ltk8.5`.
- Decide where the Aqua code lives (`src/aqua.c` plus `Makefile.in` entry is the default
  proposal; `CLAUDE.md` also asks for a `XSchemWin.vcxproj` entry for any new `.c`).
- Update `README_MacOS.md` with the new build path. bison 3 or later is required
  (`brew install bison`; the stock macOS bison 2.3 cannot process `expandlabel.y`).

### 2. Drawing correctness
Compare the window capture with `xschem print png` and `xschem print svg` for the example
library. Cover: dashed lines, stipple fills (`gcstipple`, `FillStippled`), arcs, polygons,
bezier curves, grid points, embedded images, graphs with waveforms (they rely on
`XSetClipRectangles`), crosshair, net highlighting, selection colours (selected objects
looked dimmer than expected in the spike capture; check against the X11 look), text in all
rotations and fonts.

### 3. Windows, tabs, previews
Tabbed interface, multiple windows (`.x1.drw` ...), the file-dialog preview pane
(`xschem preview_window`), window resize, closing windows, printing at a custom size
(`resetwin()` with explicit width and height). Fix the front-buffer lifetime rule here.

### 4. HiDPI
Required for the first usable version (user decision): the 1x drawing scaled up on a Retina
display is too soft to work with.

- Today pixmaps are created at 1x (one pixel per point) and Tk scales them up on screen.
- Direction to evaluate first: make `save_pixmap` and the front buffer 2x in pixels and let
  xschem treat the drawing area as 2x wide and high (window size, pointer coordinates, line
  widths and font sizes all scale by the backing factor). xschem already draws at arbitrary
  zoom, so the drawing code should not need to change, only the places where window
  geometry and pointer positions enter.
- The present step must then draw a 2x buffer into a 1x-point window rectangle.
  `XCopyArea()` in Tk 8.6 does not scale, so this needs an own present routine (draw the
  buffer's `CGImage` into the window's context during a redraw request). Untested.
- That own present routine is also route 1 for Tk 9.1 (its `XCopyArea()` cannot read
  pixmaps). Design it once so it serves both.
- Handle moving a window between a Retina and a non-Retina display (backing factor changes).
- Extend `smoke.tcl` to capture at native resolution (`grab.m` currently asks for nominal
  resolution) and check line crispness.

### 5. Input
- Mouse buttons: Aqua Tk 8.6 reports the right button as 2 and the middle as 3.
- Scroll wheel and trackpad scrolling, with Shift and Control variants.
- Modifier masks: xschem compares numeric state masks; Windows passes `Mod1Mask` and friends
  to Tcl for this. Check Option, Command and Control on Aqua.
- Command key (user decision: yes if safe): add Command equivalents only where the result
  matches macOS conventions and does not shadow a system shortcut. Audit xschem's Control
  bindings first and present the proposed table to the user. Never bind Cmd-H, Cmd-M, Cmd-Q
  (leave to the application menu), Cmd-Tab, Cmd-Space or Cmd-`. Control bindings stay as
  they are, so existing xschem habits and documentation remain valid.
- Caps-lock indicator (stubbed out in the spike), `XQueryPointer` uses, cursor shapes,
  focus and Enter/Leave handling.

### 6. Tk user interface on Aqua
- On Tk 8.6 a Tk console window opens at startup when stdin is not a terminal; hide it.
- Menu bar placement, application menu (About, Quit via `::tk::mac::Quit`), opening `.sch`
  and `.sym` files from Finder (`::tk::mac::OpenDocument`).
- Fullscreen: `toggle_fullscreen()` sends EWMH messages; use `wm attributes -fullscreen`.
- Window icon (`windowid()` is a no-op on Aqua now), fonts, dialog sizes, dark colour scheme.
- Screen grab (`grabscreen()`, Print key) is disabled on Aqua; decide whether to restore it.

### 7. External tools
Defaults in `xschem.tcl` assume Linux: `terminal xterm`, `editor {gvim -f}`,
`launcher_default_program xdg-open`. Provide macOS defaults (`open`, Terminal) under the
Aqua check. Verify simulation launch with a native ngspice and the built-in graph viewer.

### 8. Packaging
User decision: a `.app` bundle that can be handed to someone else.

- `Info.plist`, icon, document types for `.sch` and `.sym`, relocatable `XSCHEM_SHAREDIR`.
- Bundle Tcl, Tk, cairo and their dependent libraries inside the app and rewrite their
  install names, so the recipient needs neither Homebrew nor XQuartz.
- Sharing with other Macs needs at least ad-hoc code signing; an unsigned or ad-hoc signed
  app shows a Gatekeeper warning on first launch. Notarization needs an Apple Developer
  account; raise this with the user before assuming it.
- Licences: xschem is GPL-2.0-or-later; ship the licence texts of the bundled libraries.

### 9. Regression
- Headless suites in `tests/` (`create_save`, `netlisting`): gold from the flag-off build,
  results from the Aqua build, must match byte for byte.
- Grow `plans/macos-aqua-tools/smoke.tcl` into the GUI check for each phase.
- One unexplained message seen in headless runs, not investigated:
  `update_recent_file ...: can't read "f": no such variable`. Check whether it also appears
  on the X11 build before treating it as a port issue.

### 10. Tk 9
After a usable Tk 8.6 version (user decision). Make the display path work on Tk 9.1 (see
"Tk 9.1"), then decide which Tk the port recommends. If the HiDPI present routine of phase 4
already works on Tk 9.1, most of this phase is testing.

## Tools

In `plans/macos-aqua-tools/`:

- `build.sh 8|9 [make args]`: wrapper over `./configure --aqua --debug --aqua-tk=<Homebrew
  tcl-tk@8 or tcl-tk>` and `make -C src xschem`. Reconfigures and cleans only when
  `Makefile.conf` is not an Aqua build of the requested Tk. The normal build is
  `./configure --aqua && make` (`README_MacOS.md`).
- `grab.m`: tiny loadable Tcl extension adding `grabwin <prefix>`, which writes a PNG of each
  of the application's own windows. A process may capture its own windows without the Screen
  Recording permission, and the capture works when the window is unfocused or covered.
  Spike-only; never ship it. Compile it against the headers of the Tcl the binary uses.
- `smoke.tcl`: scripted GUI check (static draw, wire rubber band, move ghost, redraw load).
  Writes `report.txt` and `shotN_*.png` to `$OUT`. Verified on Tk 8.6.18; on Tk 9.1 it runs
  and shows the black canvas described above.

Running notes:

- A GUI process cannot start inside the Claude Code sandbox (no window-server connection;
  Tk reports a non-numeric `tk scaling`). Launch GUI tests with the sandbox disabled, bounded
  by `perl -e 'alarm N; exec @ARGV'`.
- Pass `--preinit "set XSCHEM_TMP_DIR <dir>"` when `/tmp` is not writable.
- Test with schematics that contain no `tcleval(...)` attributes (for example
  `xschem_library/examples/cmos_inv.sch`); otherwise xschem's modal script-authorization
  prompt blocks the script.
- `puts` goes to the Tk console window on Aqua, not to stdout. Write reports to a file.
- `aqua_present()` logs the `XCopyArea()` return value at debug level 1 (`-d 1`); 9 means
  `BadDrawable`.

## Decisions

Made by the user on 2026-10-05:

- **Dependencies from Homebrew.** A newer Tk is welcome once it works.
- **No screen recording** for GUI checks.
- **Command key:** add Command shortcuts if safe and not overlapping macOS defaults (phase 5).
- **Packaging:** `.app` bundle, so it can be shared (phase 8).
- **HiDPI:** required for the first usable version (phase 4).
- **Tk 9:** after a usable Tk 8.6 version (phase 10).
- **Starting point:** continue from the experimental code on `macos-aqua-spike` and clean it
  up; do not rewrite from scratch. The items under "Known hacks in the spike to replace" are
  the clean-up list.

Nothing is open. The Command-key table (phase 5) and notarization (phase 8) need the user's
input when those phases are reached.
