#!/bin/sh
# Developer build of the native macOS (Aqua) port: ./configure --aqua --debug, then make in src/.
#   build.sh 8 [make args]    Tcl/Tk 8.6, Homebrew tcl-tk@8
#   build.sh 9 [make args]    Tcl/Tk 9.x, Homebrew tcl-tk (--aqua-tk); builds, but the canvas
#                             stays black on Tk 9.1 (plan, "Tk 9.1")
# Needs: brew install tcl-tk@8 cairo jpeg-turbo bison   (plus tcl-tk for 9)
# Reconfigures and cleans only when Makefile.conf is not an Aqua build of the requested Tk;
# otherwise it builds with the flags of the last ./configure (debug or not).
case "$1" in
  8) TKP=$(brew --prefix tcl-tk@8 2>/dev/null || echo /opt/homebrew/opt/tcl-tk@8) ;;
  9) TKP=$(brew --prefix tcl-tk 2>/dev/null || echo /opt/homebrew/opt/tcl-tk) ;;
  *) echo "usage: $0 8|9 [make args]" >&2; exit 1 ;;
esac
shift
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

if ! grep -q "^OBJCFLAGS=.* -I$TKP/include" "$ROOT/Makefile.conf" 2>/dev/null; then
  (cd "$ROOT" && ./configure --aqua --debug --aqua-tk="$TKP") > "$ROOT/plans/macos-aqua-tools/configure.out" 2>&1 ||
    { tail -n 20 "$ROOT/plans/macos-aqua-tools/configure.out"; exit 1; }
  echo "configured: ./configure --aqua --debug --aqua-tk=$TKP"
  make -C "$ROOT/src" clean > /dev/null
fi
exec make -C "$ROOT/src" xschem "$@"
