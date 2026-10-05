# GUI smoke test for the Aqua build: drives xschem with synthetic events and lets the
# application capture its own window (no Screen Recording permission involved).
# Usage, from src/, outside the Claude Code sandbox (a GUI needs the window server):
#   clang -dynamiclib -fobjc-arc -I/opt/homebrew/opt/tcl-tk@8/include/tcl-tk \
#         ../plans/macos-aqua-tools/grab.m -undefined dynamic_lookup \
#         -framework Cocoa -framework ImageIO -o $OUT/grab.dylib
#   OUT=<dir> ./xschem -r --script ../plans/macos-aqua-tools/smoke.tcl \
#         ../xschem_library/examples/cmos_inv.sch
# (build grab.dylib with the headers of the Tcl/Tk the xschem binary is linked to)
# Writes $OUT/report.txt and $OUT/shotN_*.png. Use a schematic without embedded tcleval()
# scripts, otherwise xschem's modal authorization prompt blocks the run.
set ::out $env(OUT)
load $::out/grab.dylib Grab
set ::rep [open $::out/report.txt w]
set ::nexpose 0
proc say {s} {puts $::rep $s; flush $::rep}
proc shot {name} {
  foreach r [grabwin $::out/$name] {
    if {![string match Console:* $r]} { say "$name: [lindex [split $r :] 1] [lindex [split $r :] 2]" }
  }
}
# xschem callback <win> <X event type> <x> <y> <keysym> <button> <aux> <state>
# event types: 2 KeyPress, 4 ButtonPress, 5 ButtonRelease, 6 MotionNotify
proc step1 {} {
  bind .drw <Expose> {+incr ::nexpose}
  say "ws=[tk windowingsystem] patch=[info patchlevel] drw=[winfo geometry .drw] draw_window=[xschem get draw_window]"
  raise .
  update
  shot shot1 ;# static schematic
  xschem callback .drw 2 150 120 119 0 0 0 ;# 'w': start wire
  xschem callback .drw 6 420 330 0 0 0 0
  after 600 step2
}
proc step2 {} {
  shot shot2 ;# rubber band wire visible
  xschem callback .drw 6 560 150 0 0 0 0
  after 600 step3
}
proc step3 {} {
  shot shot3 ;# old rubber band erased, new one drawn
  xschem callback .drw 2 560 150 65307 0 0 0 ;# Escape
  xschem select_all
  xschem callback .drw 2 300 300 109 0 0 0 ;# 'm': move
  xschem callback .drw 6 380 240 0 0 0 0
  after 600 step4
}
proc step4 {} {
  shot shot4 ;# ghost of the moved selection follows the pointer
  xschem callback .drw 2 380 240 65307 0 0 0
  xschem unselect_all
  after 600 step5
}
proc step5 {} {
  shot shot5 ;# clean schematic again
  set e0 $::nexpose
  xschem callback .drw 2 150 120 119 0 0 0
  set t0 [clock milliseconds]
  for {set i 0} {$i < 100} {incr i} {
    xschem callback .drw 6 [expr {200 + $i * 4}] [expr {150 + $i * 2}] 0 0 0 0
    update
  }
  say "100 pointer moves in wire mode: [expr {[clock milliseconds] - $t0}] ms, [expr {$::nexpose - $e0}] expose events"
  shot shot6
  xschem callback .drw 2 600 350 65307 0 0 0
  after 1500 [list step6 $::nexpose]
}
proc step6 {e1} {
  say "idle 1.5 s: [expr {$::nexpose - $e1}] expose events (must stay near zero)"
  close $::rep
  exit
}
after 3500 step1
