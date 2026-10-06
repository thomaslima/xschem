/* File: launcher.c
 *
 * This file is part of XSCHEM,
 * a schematic capture and Spice/Vhdl/Verilog netlisting tool for circuit
 * simulation.
 * Copyright (C) 2026 Thomas Ferreira de Lima
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/* Main executable of Xschem.app (Contents/MacOS/xschem).
 * The xschem binary and the Tcl/Tk libraries look for their script files in
 * the directories they were configured with at build time, which do not exist
 * on another Mac. This launcher points them at the copies inside the bundle,
 * wherever the bundle has been moved, and then replaces itself with the real
 * binary (Contents/MacOS/xschem-bin). exec keeps the process id, so the
 * process Launch Services started is the one that receives Apple events and
 * owns the Dock icon.
 * TCL_DIR and TK_DIR are passed by make_app.sh (for example "tcl8.6").
 * A linked bundle (make_app.sh -l, used by the Homebrew formula) holds no libraries or
 * script files of its own; built with -DLINKED, the launcher leaves those paths to the
 * binary and only extends PATH. */

#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char contents[PATH_MAX];

#ifndef LINKED
static void set_bundle_path(const char *var, const char *rel)
{
  char buf[PATH_MAX];
  snprintf(buf, sizeof(buf), "%s/%s", contents, rel);
  setenv(var, buf, 1);
}
#endif

/* append dir to PATH unless it is already there */
static void append_path(const char *dir)
{
  char buf[8192];
  const char *old = getenv("PATH"), *p;
  size_t n = strlen(dir);

  if(!old) old = "";
  for(p = old; (p = strstr(p, dir)) != NULL; p += n) {
    if((p == old || p[-1] == ':') && (p[n] == ':' || p[n] == '\0')) return;
  }
  snprintf(buf, sizeof(buf), "%s%s%s", old, old[0] ? ":" : "", dir);
  setenv("PATH", buf, 1);
}

int main(int argc, char **argv)
{
  char exe[PATH_MAX], bin[PATH_MAX];
  uint32_t size = sizeof(exe);
  char *slash;
  int i;

  (void)argc;
  /* resolve symlinks, so a link to this launcher in /usr/local/bin works */
  if(_NSGetExecutablePath(exe, &size) || !realpath(exe, contents)) {
    fprintf(stderr, "xschem launcher: cannot locate own executable\n");
    return 1;
  }
  for(i = 0; i < 2; i++) { /* strip "/xschem" and "/MacOS" */
    slash = strrchr(contents, '/');
    if(slash) *slash = '\0';
  }
#ifndef LINKED
  set_bundle_path("TCL_LIBRARY", "Resources/lib/" TCL_DIR);
  set_bundle_path("TK_LIBRARY", "Resources/lib/" TK_DIR);
  set_bundle_path("XSCHEM_SHAREDIR", "Resources/share/xschem");
#endif
  /* apps started from the Finder get PATH=/usr/bin:/bin:/usr/sbin:/sbin: let xschem find
   * ps2pdf, ngspice, gaw ... installed by Homebrew (Apple silicon, Intel) */
  append_path("/opt/homebrew/bin");
  append_path("/usr/local/bin");
  snprintf(bin, sizeof(bin), "%s/MacOS/xschem-bin", contents);
  argv[0] = bin;
  execv(bin, argv);
  perror(bin);
  return 1;
}
