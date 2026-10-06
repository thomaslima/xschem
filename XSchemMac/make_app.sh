#!/bin/sh
# File: make_app.sh
#
# This file is part of XSCHEM,
# a schematic capture and Spice/Vhdl/Verilog netlisting tool for circuit
# simulation.
# Copyright (C) 2026 Thomas Ferreira de Lima
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

# Package a built Aqua xschem binary and the source tree into a self-contained,
# relocatable Xschem.app. See XSchemMac/README.md.

set -eu

usage() {
  cat <<EOF
usage: $0 [-b binary] [-s source_tree] [-i bundle_id] [output.app]
  -b  xschem binary to package           (default: <source_tree>/src/xschem)
  -s  xschem source tree                 (default: parent of this script's dir)
  -i  CFBundleIdentifier                 (default: io.github.stefanschippers.xschem)
  output.app                             (default: <source_tree>/XSchemMac/build/Xschem.app)
EOF
  exit 2
}

die() { echo "make_app.sh: error: $*" >&2; exit 1; }
warn() { echo "make_app.sh: warning: $*" >&2; }

here=$(cd "$(dirname "$0")" && pwd -P)
srctree=$(cd "$here/.." && pwd -P)
bin=""
bundle_id=io.github.stefanschippers.xschem
while getopts b:s:i:h opt; do
  case $opt in
    b) bin=$OPTARG ;;
    s) srctree=$(cd "$OPTARG" && pwd -P) ;;
    i) bundle_id=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -le 1 ] || usage
[ -n "$bin" ] || bin=$srctree/src/xschem
app=${1:-$srctree/XSchemMac/build/Xschem.app}

for t in otool install_name_tool codesign sips iconutil plutil ditto cc; do
  command -v $t >/dev/null 2>&1 || die "$t not found (install the Xcode command line tools)"
done
[ -f "$bin" ] || die "binary $bin not found; build xschem first"
[ -f "$srctree/src/xschem.tcl" ] || die "$srctree is not an xschem source tree"
case $app in *.app) ;; *) die "output must end in .app: $app" ;; esac
case $(otool -L "$bin" 2>/dev/null) in
  *libX11*) die "$bin links libX11: package the Aqua build, not the X11 one" ;;
  */opt/local/*) die "$bin links MacPorts libraries (/opt/local); build against Homebrew" ;;
esac

# physical path of $1, following symlinks
resolve() {
  _f=$1
  while [ -L "$_f" ]; do
    _l=$(readlink "$_f")
    case $_l in /*) _f=$_l ;; *) _f=$(dirname "$_f")/$_l ;; esac
  done
  echo "$(cd "$(dirname "$_f")" && pwd -P)/$(basename "$_f")"
}

# dependencies of Mach-O file $1, without its own install name
deps() {
  _id=$(otool -D "$1" 2>/dev/null | sed -n 2p)
  otool -L "$1" 2>/dev/null | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version .*/\1/p' |
    while IFS= read -r _d; do [ "$_d" = "$_id" ] || echo "$_d"; done
}

rpaths() {
  otool -l "$1" 2>/dev/null | awk '/cmd LC_RPATH/ { r = 1 } r && $1 == "path" { print $2; r = 0 }'
}

# real file behind dependency $1 of original file $2; empty for system libraries
locate_dep() {
  case $1 in
    /usr/lib/*|/System/*) return 0 ;;
    @executable_path/*) _p=$(dirname "$bin")/${1#@executable_path/} ;;
    @loader_path/*) _p=$(dirname "$2")/${1#@loader_path/} ;;
    @rpath/*)
      _p=""
      for _r in $(rpaths "$2") $(rpaths "$bin"); do
        case $_r in
          @loader_path*) _r=$(dirname "$2")${_r#@loader_path} ;;
          @executable_path*) _r=$(dirname "$bin")${_r#@executable_path} ;;
        esac
        if [ -f "$_r/${1#@rpath/}" ]; then _p=$_r/${1#@rpath/}; break; fi
      done ;;
    /*) _p=$1 ;;
    *) die "$2: unsupported install name $1" ;;
  esac
  [ -n "$_p" ] && [ -f "$_p" ] || die "$2 needs $1, which was not found"
  resolve "$_p"
}

work=$(mktemp -d "${TMPDIR:-/tmp}/make_app.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -e "$app" ]; then
  [ -f "$app/Contents/Info.plist" ] || die "$app exists and is not an app bundle; not removing it"
  rm -rf "$app"
fi
contents=$app/Contents
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/lib" \
  "$contents/Resources/licenses"
macos=$contents/MacOS
fw=$contents/Frameworks
res=$contents/Resources

echo "make_app.sh: packaging $bin into $app"

# ---------------------------------------------------------------------------
# 1. Binary and the closure of its non-system dylibs. Every bundled library is
#    named after its own install name and referenced as @rpath/<name>.
# ---------------------------------------------------------------------------
bin=$(resolve "$bin")
cp -X "$bin" "$macos/xschem-bin"
printf '%s\t%s\n' "$bin" "$macos/xschem-bin" > "$work/files"   # original -> bundle copy
: > "$work/libs"                                                 # real path -> name
: > "$work/refs"                                                 # bundle copy, old name, new name
n=1
while :; do
  line=$(sed -n "${n}p" "$work/files")
  [ -n "$line" ] || break
  n=$((n + 1))
  orig=$(printf '%s' "$line" | cut -f1)
  copy=$(printf '%s' "$line" | cut -f2)
  deps "$orig" > "$work/deps"
  while IFS= read -r dep; do
    real=$(locate_dep "$dep" "$orig")
    [ -n "$real" ] || continue
    name=$(awk -F'\t' -v r="$real" '$1 == r { print $2 }' "$work/libs")
    if [ -z "$name" ]; then
      name=$(basename "$(otool -D "$real" 2>/dev/null | sed -n 2p)")
      [ -n "$name" ] || name=$(basename "$real")
      if awk -F'\t' -v b="$name" '$2 == b { f = 1 } END { exit !f }' "$work/libs"; then
        die "two different libraries are both named $name"
      fi
      printf '%s\t%s\n' "$real" "$name" >> "$work/libs"
      cp -X "$real" "$fw/$name"
      chmod u+w "$fw/$name"
      printf '%s\t%s\n' "$real" "$fw/$name" >> "$work/files"
    fi
    printf '%s\t%s\t%s\n' "$copy" "$dep" "@rpath/$name" >> "$work/refs"
  done < "$work/deps"
done

while IFS="$(printf '\t')" read -r copy old new; do
  install_name_tool -change "$old" "$new" "$copy" 2>/dev/null
done < "$work/refs"
while IFS="$(printf '\t')" read -r real name; do
  install_name_tool -id "@rpath/$name" "$fw/$name" 2>/dev/null
done < "$work/libs"
# drop build-machine rpaths, then let the binary find Contents/Frameworks
for f in "$macos/xschem-bin" "$fw"/*.dylib; do
  for r in $(rpaths "$f"); do
    case $r in @*) ;; *) install_name_tool -delete_rpath "$r" "$f" 2>/dev/null ;; esac
  done
done
install_name_tool -add_rpath @executable_path/../Frameworks "$macos/xschem-bin" 2>/dev/null

# ---------------------------------------------------------------------------
# 2. Tcl and Tk script libraries, from next to the bundled dylibs.
#    lib/tcl8 holds the Tcl modules (msgcat, ...) that Tk loads.
# ---------------------------------------------------------------------------
tcl_real=$(awk -F'\t' '$2 ~ /^libtcl[0-9.]*\.dylib$/ { print $1 }' "$work/libs")
tk_real=$(awk -F'\t' '$2 ~ /^libtk[0-9.]*\.dylib$/ { print $1 }' "$work/libs")
[ -n "$tcl_real" ] && [ -n "$tk_real" ] || die "binary does not link libtcl and libtk dynamically"
tcl_dir=$(basename "$tcl_real" .dylib | sed 's/^lib//')     # tcl8.6
tk_dir=$(basename "$tk_real" .dylib | sed 's/^lib//')       # tk8.6
tcl_major=$(echo "$tcl_dir" | sed 's/^tcl\([0-9]*\).*/\1/')
for d in "$tcl_dir" "$tk_dir" "tcl$tcl_major"; do
  src=$(dirname "$tcl_real")/$d
  [ -d "$src" ] || src=$(dirname "$tk_real")/$d
  [ -f "$src/init.tcl" ] || [ -f "$src/tk.tcl" ] || [ "$d" = "tcl$tcl_major" ] ||
    die "script library $d not found next to $(dirname "$tcl_real")"
  if [ -d "$src" ]; then ditto --norsrc --noextattr --noacl "$src" "$res/lib/$d"; fi
done

# ---------------------------------------------------------------------------
# 3. xschem runtime files, laid out as 'make install' does under share/:
#    share/xschem (XSCHEM_SHAREDIR) and share/doc/xschem. The file lists are
#    read from the install targets of the Makefiles, so they stay in sync.
# ---------------------------------------------------------------------------
share=$res/share
mkdir -p "$share/xschem" "$share/doc/xschem"
{ sed -n '/^put \/local\/install_shares {/,/^}/p' "$srctree/src/Makefile.in" | sed '1d;$d'
  sed -n 's/^ *append \/local\/install_shares {\(.*\)}$/\1/p' "$srctree/src/Makefile.in"; } |
  tr ' ' '\n' | while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$srctree/src/$f" ] || die "src/$f listed in install_shares is missing"
    cp -X "$srctree/src/$f" "$share/xschem/$f"
  done
for mk in src/Makefile.in xschem_library/Makefile doc/Makefile src/utile/Makefile; do
  dir=$srctree/$(dirname "$mk")
  # an scconfig template line may end in the block terminator " @]"; a line
  # still holding @...@ substitutions is the install_shares loop handled above
  awk '{ sub(/[ \t]*@\]$/, "") }
       $1 == "$(SCCBOX)" && $2 == "install" && $0 !~ /@/ {
         n = 0
         for(i = 3; i <= NF; i++) if($i != "-f" && $i != "-d") a[++n] = $i
         dest = a[n]; gsub(/"/, "", dest)
         for(i = 1; i < n; i++) print a[i] "\t" dest
       }' "$dir/$(basename "$mk")" > "$work/install"
  while IFS="$(printf '\t')" read -r pat dest; do
    case $dest in
      '$(XSHAREDIR)'*) dest=xschem${dest#'$(XSHAREDIR)'} ;;
      '$(XDOCDIR)'*) dest=doc/xschem${dest#'$(XDOCDIR)'} ;;
      '$(system_library_dir)'*) dest=xschem/xschem_library/devices${dest#'$(system_library_dir)'} ;;
      '$(BINDIR)'*|'$(MANDIR)'*) continue ;;
      *) warn "$mk: install destination $dest not understood, skipped"; continue ;;
    esac
    mkdir -p "$share/$dest"
    for f in $(cd "$dir" && echo $pat); do
      [ -e "$dir/$f" ] || continue          # pattern matched nothing
      case $(basename "$f") in Makefile*) continue ;; esac
      ditto --norsrc --noextattr --noacl "$dir/$f" "$share/$dest/$(basename "$f")"
    done
  done < "$work/install"
done

# The library search path compiled into xschem points at the configure
# prefix. Inside the bundle, rewrite it to the bundle's own share/ directory.
# The guard keeps this inert in the copy xschem makes into ~/.xschem/xschemrc
# on first start when that file is later used by a non-bundled xschem.
cat >> "$share/xschem/xschemrc" <<'EOF'

###########################################################################
#### Xschem.app (added by XSchemMac/make_app.sh)
###########################################################################
#### The compiled-in XSCHEM_LIBRARY_PATH points at the build machine's install
#### prefix; map its share/xschem and share/doc/xschem entries into the bundle.
if {[string match */Contents/Resources/share/xschem $XSCHEM_SHAREDIR]} {
  set _bundle_libpath {}
  foreach _p [split $XSCHEM_LIBRARY_PATH :] {
    if {[regexp {/share/((doc/)?xschem/.*)$} $_p -> _tail]} {
      set _p [file dirname $XSCHEM_SHAREDIR]/$_tail
    }
    lappend _bundle_libpath $_p
  }
  set XSCHEM_LIBRARY_PATH [join $_bundle_libpath :]
  unset -nocomplain _bundle_libpath _p _tail
}
EOF

# ---------------------------------------------------------------------------
# 4. Launcher (CFBundleExecutable), icon, Info.plist
# ---------------------------------------------------------------------------
min_macos=$( (otool -l "$macos/xschem-bin"; for f in "$fw"/*.dylib; do otool -l "$f"; done) 2>/dev/null |
  awk '$1 == "minos" { print $2 }' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ -n "$min_macos" ] || die "cannot read the minimum macOS version from the binaries"
cc -O2 -Wall -mmacosx-version-min="$min_macos" -DTCL_DIR="\"$tcl_dir\"" -DTK_DIR="\"$tk_dir\"" \
  -o "$macos/xschem" "$here/launcher.c"

# The only full-size artwork in the tree is the 256x256 image in the Windows
# installer icon; sizes above 256 are left out rather than upscaled.
iconset=$work/xschem.iconset
mkdir -p "$iconset"
sips -s format png "$srctree/XSchemWin/XSchemWix/xschem_icon.ico" --out "$work/icon256.png" >/dev/null
for s in 16 32 128 256; do
  sips -z $s $s "$work/icon256.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  if [ $d -le 256 ]; then sips -z $d $d "$work/icon256.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null; fi
done
iconutil -c icns -o "$res/xschem.icns" "$iconset"

version=$(sed -n 's/^#define XSCHEM_VERSION "\(.*\)"/\1/p' "$srctree/src/xschem.h")
short_version=$(echo "$version" | sed 's/^\([0-9.]*\).*/\1/')
[ -n "$short_version" ] || die "cannot read XSCHEM_VERSION from src/xschem.h"
sed -e "s/@BUNDLE_ID@/$bundle_id/g" -e "s/@VERSION@/$version/g" \
    -e "s/@SHORT_VERSION@/$short_version/g" -e "s/@MIN_MACOS@/$min_macos/g" \
    "$here/Info.plist.in" > "$contents/Info.plist"
plutil -lint -s "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"

# ---------------------------------------------------------------------------
# 5. Licences: xschem's, and those of every Homebrew keg a library came from
# ---------------------------------------------------------------------------
mkdir -p "$res/licenses/xschem"
cp -X "$srctree/LICENSE" "$res/licenses/xschem/LICENSE"
{
  echo "Libraries bundled in Xschem.app/Contents/Frameworks and where they came from."
  echo "Licence texts are in the directory named after each source package."
  echo
} > "$res/licenses/README.txt"
while IFS="$(printf '\t')" read -r real name; do
  keg=$(echo "$real" | sed -n 's|^\(.*/Cellar/[^/]*/[^/]*\)/.*|\1|p')
  if [ -z "$keg" ]; then
    warn "$name does not come from a Homebrew keg; add its licence by hand"
    printf '%s\t%s\n' "$name" "$real" >> "$res/licenses/README.txt"
    continue
  fi
  pkg=$(basename "$(dirname "$keg")")
  printf '%s\t%s %s\n' "$name" "$pkg" "$(basename "$keg")" >> "$res/licenses/README.txt"
  if [ -d "$res/licenses/$pkg" ]; then continue; fi
  mkdir -p "$res/licenses/$pkg"
  for f in "$keg"/COPYING* "$keg"/LICENSE* "$keg"/LICENCE* "$keg"/license.terms \
           "$keg"/sbom.spdx.json "$keg"/share/doc/*/LICENSE* "$keg"/share/doc/*/COPYING* \
           "$keg"/share/doc/*/README.ijg; do
    if [ -f "$f" ]; then cp -X "$f" "$res/licenses/$pkg/"; fi
  done
  ls "$res/licenses/$pkg" | grep -qv sbom.spdx.json || warn "no licence text found in $keg"
done < "$work/libs"

# ---------------------------------------------------------------------------
# 6. Ad-hoc signature, inside out (mandatory on Apple Silicon after
#    install_name_tool), then checks
# ---------------------------------------------------------------------------
chmod -R u+w,go-w "$app"     # Homebrew installs read-only files
xattr -cr "$app"
for f in "$fw"/*.dylib "$macos/xschem-bin" "$app"; do
  codesign --force --sign - --timestamp=none "$f" 2> "$work/codesign" ||
    { cat "$work/codesign" >&2; die "codesign failed on $f"; }
done
codesign --verify --deep --strict "$app"

find "$app" -type f | while IFS= read -r f; do
  case $(file -b "$f") in Mach-O*) echo "$f:"; otool -L "$f" 2>/dev/null | sed -n '2,$p'; rpaths "$f" ;; esac
done > "$work/macho"
if grep -E '/opt/homebrew|/opt/local|/usr/local' "$work/macho"; then
  die "bundle still references build-machine libraries (listed above)"
fi
if grep '^/.*:$' "$work/macho" | grep -v -e '/Contents/MacOS/' -e '/Contents/Frameworks/'; then
  die "Mach-O files outside Contents/MacOS and Contents/Frameworks (listed above)"
fi

echo "make_app.sh: done: $app ($(du -sh "$app" | cut -f1), macOS $min_macos or later, $(lipo -archs "$macos/xschem-bin"))"
