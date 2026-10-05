#!/bin/sh
# Spike build of xschem against native (Aqua) Tk from Homebrew. Run ./configure once first.
#   build.sh 9 [make args]    Tcl/Tk 9.x   (brew install tcl-tk)
#   build.sh 8 [make args]    Tcl/Tk 8.6   (brew install tcl-tk@8)
# Also needs: brew install bison cairo jpeg-turbo
# Objects of the two variants are not compatible: the script cleans when the variant changes.
HB=${HB:-/opt/homebrew}
case "$1" in
  9) TKP=$HB/opt/tcl-tk
     # tcl.h of Tcl 9.1 uses 'inline', not a C89 keyword; keep C89 checking for xschem code
     EXTRA="-Dinline=__inline__"
     TKLIBS="-ltcl9tk$(. $TKP/lib/tkConfig.sh; echo $TK_VERSION) -ltcl$(. $TKP/lib/tclConfig.sh; echo $TCL_VERSION)" ;;
  8) TKP=$HB/opt/tcl-tk@8
     TKLIBS="-ltk8.6 -ltcl8.6" ;;
  *) echo "usage: $0 8|9 [make args]" >&2; exit 1 ;;
esac
VARIANT=$1; shift
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT/src" || exit 1

# expandlabel.y needs bison >= 3, stock macOS bison is 2.3
PATH=$HB/opt/bison/bin:$PATH; export PATH

MARK="$ROOT/plans/macos-aqua-tools/.variant"
if [ "$(cat "$MARK" 2>/dev/null)" != "$VARIANT" ]; then
  make clean > /dev/null 2>&1
  echo "$VARIANT" > "$MARK"
fi

make xschem \
  CFLAGS="-pipe -g -O0 -Wall -std=c89 -pedantic -DXSCHEM_AQUA -DMAC_OSX_TK $EXTRA -I$TKP/include/tcl-tk -I$HB/opt/cairo/include/cairo -I$HB/opt/jpeg-turbo/include -I$HB/include" \
  LDFLAGS="-lm -L$TKP/lib $TKLIBS -L$HB/opt/cairo/lib -lcairo -L$HB/opt/jpeg-turbo/lib -ljpeg -framework CoreGraphics" "$@"
