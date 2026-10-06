# Xschem.app for macOS

`make_app.sh` turns a native (Aqua Tk) build of xschem into a self-contained
`Xschem.app` intended to run without Homebrew or XQuartz on the target Mac. So far it has
been verified only on the build machine, launched with a scrubbed environment; a Mac without
Homebrew has not been tried.

## Build

Build xschem against Homebrew `tcl-tk@8`, `cairo` and `jpeg-turbo` first, so that
`src/xschem` exists and links no X11 library. Then:

```
XSchemMac/make_app.sh                       # -> XSchemMac/build/Xschem.app
XSchemMac/make_app.sh -b path/to/xschem out/Xschem.app
XSchemMac/make_app.sh -i org.example.xschem # different bundle identifier
```

The script needs the Xcode command line tools (`cc`, `otool`, `install_name_tool`,
`codesign`) and the macOS tools `sips`, `iconutil`, `ditto`, `plutil`. It does not run
`make`; the file lists for the runtime data are read from the `install` targets of the
Makefiles.

## Linked bundle

```
XSchemMac/make_app.sh -l -b <prefix>/bin/xschem <prefix>/Xschem.app
```

With `-l` the bundle holds only the binary, the launcher, `Info.plist`, the icon and xschem's
licence (about 1 MB). The binary keeps loading Tcl/Tk, cairo and libjpeg from the
installation it was built against, and keeps the `XSCHEM_SHAREDIR` it was configured with,
so it must come from `make install` and only works on the Mac that has that installation.
The launcher is built with `-DLINKED`: it sets no Tcl, Tk or xschem paths and only extends
`PATH` (see below). The Homebrew formula `xschem-mac` uses this mode, so that Finder, the
Dock and file associations work for a Homebrew-built xschem.

## What is in the bundle

| Path in `Contents/` | Content |
|---|---|
| `MacOS/xschem` | Launcher (`launcher.c`), the bundle's main executable |
| `MacOS/xschem-bin` | The xschem binary |
| `Frameworks/` | Tcl, Tk, cairo, libjpeg and every non-system library they load, referenced as `@rpath/...` |
| `Resources/lib/` | Tcl and Tk script libraries (`tcl8.6`, `tk8.6`, `tcl8`) |
| `Resources/share/xschem/` | `XSCHEM_SHAREDIR`: `xschem.tcl`, awk filters, `systemlib`, `utile`, device library |
| `Resources/share/doc/xschem/` | Example libraries and the HTML manual |
| `Resources/licenses/` | Licence texts of xschem and of each bundled package |

The launcher finds the bundle from its own path (symlinks resolved), sets
`TCL_LIBRARY`, `TK_LIBRARY` and `XSCHEM_SHAREDIR` to the bundle's copies, and
replaces itself with `xschem-bin`. The app therefore works from any folder, including
paths with spaces; the same mechanism should cover the randomized read-only location
macOS uses for quarantined apps run from Downloads (not tested). Programs that xschem
starts inherit these variables. A block appended to the bundled `xschemrc` maps the compiled-in
`XSCHEM_LIBRARY_PATH` into the bundle. For command-line use, run or symlink
`Xschem.app/Contents/MacOS/xschem`, not `xschem-bin`.

An app started from Finder gets a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). The
launcher appends `/opt/homebrew/bin` and `/usr/local/bin`, so external programs installed
by Homebrew (ngspice, `ps2pdf` from ghostscript for PDF export) are found; programs
installed elsewhere need their full path configured in xschem.

Text is drawn by cairo's CoreText (Quartz) font backend, so no fontconfig
configuration is bundled.

The Homebrew libraries are built for the macOS version of the build machine. The app
requires that macOS version or later (`LSMinimumSystemVersion`, read from the
binaries) and an Apple Silicon Mac.

## Giving the app to someone else

`make_app.sh` signs the app ad hoc (`codesign -s -`). That satisfies Apple Silicon's
requirement that all code be signed, but it does not identify a developer. Gatekeeper
blocks such an app when it carries the quarantine flag (downloaded, received by
AirDrop, Mail or a chat program):

1. The recipient double-clicks Xschem and macOS says it cannot verify the app. They
   click Done (not Move to Trash).
2. They open System Settings > Privacy & Security, find the message about Xschem
   near the bottom, click Open Anyway and authenticate.
3. They open Xschem again and confirm with Open. Later launches start normally.

Alternatively, `xattr -dr com.apple.quarantine /Applications/Xschem.app` in Terminal
removes the quarantine flag. A copy made from a USB disk or a network share usually
has no quarantine flag and opens directly.

Package the app with `ditto -c -k --keepParent Xschem.app Xschem.zip` or in a disk
image (`hdiutil create -srcfolder Xschem.app Xschem.dmg`) so that permissions and
signatures survive the transfer.

Opening without these steps requires a Developer ID signature and notarization by
Apple, which needs a paid Apple Developer Program membership. The script does not do
this.

## Releases

Releases of this fork are tagged `v<xschem version>-mac.<n>`, for example `v3.4.8RC-mac.3`,
where `<n>` counts the fork's releases of one xschem version. Two GitHub Actions workflows
make a release, each started by hand with the same tag:

1. **Release** (`.github/workflows/release.yml` in this repository) builds `Xschem.app` with
   the checks of CI and publishes `Xschem-<version>-<arch>.dmg` on a new GitHub Release. Run
   it from Actions > Release > Run workflow: choose the branch and enter the tag. A tag that
   does not exist yet is created at the head of that branch; an existing tag is built as it
   is. Pushing a `v*` tag starts the same workflow. It stops if the release already exists.
2. **Update formula** (`.github/workflows/update-formula.yml` in
   [thomaslima/homebrew-tap](https://github.com/thomaslima/homebrew-tap)) points the
   `xschem-mac` formula at the tag: it sets `url`, `version` and `sha256`, builds and tests the
   formula on macOS, and commits the change to the tap. `brew update` and
   `brew upgrade xschem-mac` then install it.

The formula builds from the tag's source archive, not from the release's disk image, so the
two workflows do not depend on each other beyond the tag; run Release first when it creates
the tag.

## Licences

xschem is GPL-2.0-or-later. Tcl/Tk, pixman, libpng, freetype, libjpeg-turbo, the X11
libraries and fontconfig use permissive licences; cairo is LGPL-2.1 or MPL-1.1;
libintl (from gettext) is LGPL-2.1-or-later. Homebrew's gettext keg ships only the
GPL-3 `COPYING` of the gettext tools; the LGPL-2.1 text is in
`licenses/cairo/COPYING-LGPL-2.1`. Each package folder also holds Homebrew's
`sbom.spdx.json` with the upstream source URL.

Whoever distributes the app takes on the GPL and LGPL source obligations: provide the
xschem source revision the app was built from and point to the sources of the bundled
libraries.
