# Developer tools for the native macOS (Aqua) build

Scripts used to build and check the Aqua port during development. They are not installed by
`make install` and not copied into `Xschem.app`. `AQUA_PORT.md` (one directory up), section 7,
reports the results obtained with them.

| File | Purpose |
|---|---|
| `build.sh 8\|9 [make args]` | Debug build: `./configure --aqua --debug --aqua-tk=<Homebrew tcl-tk@8 or tcl-tk>`, then `make -C src xschem`. Reconfigures and cleans only when `Makefile.conf` is not an Aqua build of the requested Tk. The normal build is `./configure --aqua && make` (`README_MacOS.md`). |
| `grab.m` | Loadable Tcl extension adding `grabwin <prefix> ?nominal?`, which writes a PNG of each of the application's own windows. A process may capture its own windows without the Screen Recording permission, and the capture works when the window is unfocused or covered. Compile it against the headers of the Tcl that the xschem binary uses (command line at the top of `smoke.tcl`). |
| `smoke.tcl` | Scripted GUI check: static drawing, wire rubber band, move ghost, redraw load, printing, tabs, stipples, crosshair, file-dialog preview. Writes `report.txt` and `shotN_*.png` to `$OUT`. Usage and options are at the top of the file. |
| `pngcheck.py` | Crispness and pixel-difference checks on the `smoke.tcl` captures (Python 3 standard library only). |

GUI checks never use `screencapture` or a Screen Recording grant; `grab.m` replaces them.

## Running GUI checks

- A GUI process needs a connection to the window server. It cannot start inside a sandbox that
  blocks it (Tk then reports a non-numeric `tk scaling`). Bound each run with a timeout, for
  example `perl -e 'alarm 60; exec @ARGV' ./xschem ...`.
- Pass `--preinit "set XSCHEM_TMP_DIR <dir>"` when `/tmp` is not writable.
- Use schematics without `tcleval(...)` attributes (for example
  `xschem_library/examples/cmos_inv.sch`), or pass `set xschem_execute_scripts 0` in
  `--preinit`; otherwise xschem's modal script-authorization prompt blocks the script.
- On Aqua, `puts` from a GUI run goes to the Tk console or to `/dev/null`, not to the terminal.
  Write reports to a file, as `smoke.tcl` does.
- `aqua.m` logs the display path at debug level 1 and 2 (`-d 1`, `-d 2`).
