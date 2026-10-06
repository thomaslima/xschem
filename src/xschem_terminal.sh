#!/bin/sh
#  File: xschem_terminal.sh
#
#  This file is part of XSCHEM,
#  a schematic capture and Spice/Vhdl/Verilog netlisting tool for circuit
#  simulation.
#  Copyright (C) 2026 Thomas Ferreira de Lima
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

# macOS replacement for xterm, used as the default 'terminal' on native (Aqua) builds.
#   xschem_terminal.sh                  login shell in the current directory
#   xschem_terminal.sh -e cmd [args]    run cmd in the current directory
#   xschem_terminal.sh -e 'cmd string'  a single argument is run by the shell, as xterm does
#   xschem_terminal.sh -a iTerm ...     use another terminal application (default Terminal)
# Other xterm options before -e are ignored. A command goes into a temporary .command
# file that the terminal application runs in a new window; the file removes itself when it
# starts.

quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

app=Terminal
cmd=
while [ $# -gt 0 ]; do
  if [ "$1" = "-a" ] && [ $# -gt 1 ]; then
    app=$2
    shift 2
    continue
  fi
  if [ "$1" = "-e" ]; then
    shift
    if [ $# -eq 1 ]; then
      cmd=$1
    else
      for a in "$@"; do cmd="$cmd $(quote "$a")"; done
    fi
    break
  fi
  shift
done
# no command: let the terminal open its own login shell in the directory, so closing the
# window does not ask about a running process
[ -n "$cmd" ] || exec open -a "$app" "$(pwd)"

f=$(mktemp "${TMPDIR:-/tmp}/xschem_term.XXXXXX") || exit 1
mv "$f" "$f.command" || exit 1
f=$f.command
{
  echo '#!/bin/sh'
  echo 'rm -f "$0"'
  echo "cd $(quote "$(pwd)")"
  echo "$cmd"
} > "$f"
chmod 700 "$f"
exec open -a "$app" "$f"
