# GUI smoke test for the Aqua build: drives xschem with synthetic events and lets the
# application capture its own windows (no Screen Recording permission involved).
# Usage, from src/, outside the Claude Code sandbox (a GUI needs the window server):
#   clang -dynamiclib -fobjc-arc -I/opt/homebrew/opt/tcl-tk@8/include/tcl-tk \
#         ../plans/macos-aqua-tools/grab.m -undefined dynamic_lookup \
#         -framework Cocoa -framework ImageIO -o $OUT/grab.dylib
#   OUT=<dir> perl -e 'alarm 60; exec @ARGV' ./xschem \
#         --preinit "set XSCHEM_TMP_DIR <dir>; set xschem_execute_scripts 0" \
#         -r --script ../plans/macos-aqua-tools/smoke.tcl ../xschem_library/examples/cmos_inv.sch
# (build grab.dylib with the headers of the Tcl/Tk the xschem binary is linked to)
# Optional environment:
#   SMOKE=quick          only the static, rubber band, move and load steps
# The full run also checks stippled fills, the crosshair and the file dialog preview pane.
#   SMOKE_WINDOWS=1      open and close a second window (start with
#                        --preinit "...; set tabbed_interface 0"), otherwise a second tab
#   XSCHEM_AQUA_SCALE=1  (read by xschem) draw at 1x as the spike did: the failure
#                        signature for the crispness check
# Writes $OUT/report.txt and $OUT/shotN_*.png (captured at the native resolution of the
# display). Each check prints PASS or FAIL; a script error ends the run with a FAIL line.
# Crispness is checked afterwards with pngcheck.py (command line in the report).
# never let a tcleval() attribute raise the script authorization dialog
# (also pass --preinit "set xschem_execute_scripts 0")
set ::xschem_execute_scripts 0
set ::out $env(OUT)
set ::mode [expr {[info exists env(SMOKE)] ? $env(SMOKE) : "full"}]
set ::windows [expr {[info exists env(SMOKE_WINDOWS)] && $env(SMOKE_WINDOWS)}]
load $::out/grab.dylib Grab
set ::rep [open $::out/report.txt w]
set ::nexpose 0
set ::nfail 0
proc say {s} {puts $::rep $s; flush $::rep}
# Any error ends the run with a report line instead of a modal bgerror dialog
proc bgerror {msg} {
  catch {say "FAIL script error: $msg\n$::errorInfo"}
  catch {close $::rep}
  exit 2
}
proc run {step args} {
  if {[catch {$step {*}$args} msg]} { bgerror "$step: $msg" }
}
proc later {ms step args} { after $ms [list run $step {*}$args] }
proc check {name ok detail} {
  if {!$ok} {incr ::nfail}
  say "[expr {$ok ? {PASS} : {FAIL}}] $name: $detail"
}

# capture all windows; return {path width height} of the window whose title matches pat
proc shot {name {pat {xschem*}}} {
  update
  set res {}
  foreach r [grabwin $::out/$name] {
    lassign [split $r :] title how status path size
    if {[string match Console* $title]} continue
    say "$name: $title $how $status $size"
    if {$res eq {} && [string match $pat $title]} {
      lassign [split $size x] w h
      set res [list $path $w $h]
    }
  }
  return $res
}

# geometry of drawing window w inside a capture of its toplevel: {scale x0 y0} so that
# point (x, y) of w is at pixel (x0 + x * scale, y0 + y * scale)
proc drw_map {cap w} {
  set top [winfo toplevel $w]
  lassign $cap path cw ch
  set scale [expr {double($cw) / [winfo width $top]}]
  set title [expr {$ch / $scale - [winfo height $top]}] ;# title bar, points
  set x0 [expr {([winfo rootx $w] - [winfo rootx $top]) * $scale}]
  set y0 [expr {($title + [winfo rooty $w] - [winfo rooty $top]) * $scale}]
  return [list $scale $x0 $y0]
}

# number of differing pixels in the drawing window area of two captures
proc drw_diff {capa capb map} {
  lassign $map scale x0 y0
  set w [expr {int([winfo width .drw] * $scale)}]
  set h [expr {int([winfo height .drw] * $scale)}]
  set a [image create photo -file [lindex $capa 0]]
  set b [image create photo -file [lindex $capb 0]]
  set da [$a data -from [expr {int($x0)}] [expr {int($y0)}] [expr {int($x0) + $w}] [expr {int($y0) + $h}]]
  set db [$b data -from [expr {int($x0)}] [expr {int($y0)}] [expr {int($x0) + $w}] [expr {int($y0) + $h}]]
  image delete $a $b
  set n 0
  foreach ra $da rb $db {
    if {$ra ne $rb} {foreach ca $ra cb $rb {if {$ca ne $cb} {incr n}}}
  }
  return $n
}

proc pixel {cap map x y} {
  lassign $map scale x0 y0
  set img [image create photo -file [lindex $cap 0]]
  set c [$img get [expr {int($x0 + $x * $scale)}] [expr {int($y0 + $y * $scale)}]]
  image delete $img
  return $c
}

# number of distinct colours in the drawing area w of a capture (1 or 2: nothing drawn)
proc colours {cap w} {
  lassign [drw_map $cap $w] scale x0 y0
  set img [image create photo -file [lindex $cap 0]]
  set rows [$img data -from [expr {int($x0)}] [expr {int($y0)}] \
    [expr {int($x0 + [winfo width $w] * $scale)}] [expr {int($y0 + [winfo height $w] * $scale)}]]
  image delete $img
  set n 0
  for {set i 0} {$i < [llength $rows]} {incr i 7} {
    foreach c [lindex $rows $i] { if {![info exists seen($c)]} { set seen($c) 1; incr n } }
  }
  return $n
}

proc png_size {file} {
  set img [image create photo -file $file]
  set s "[image width $img]x[image height $img]"
  image delete $img
  return $s
}

# xschem callback <win> <X event type> <x> <y> <keysym> <button> <aux> <state>
# event types: 2 KeyPress, 4 ButtonPress, 5 ButtonRelease, 6 MotionNotify
proc step1 {} {
  bind .drw <Expose> {+incr ::nexpose}
  say "xschem_execute_scripts=$::xschem_execute_scripts"
  say "ws=[tk windowingsystem] patch=[info patchlevel] drw=[winfo width .drw]x[winfo height .drw]\
       top=[winfo width .]x[winfo height .] draw_window=[xschem get draw_window]"
  raise .
  xschem zoom_full
  update
  set ::cap1 [shot shot1] ;# static schematic
  set ::map [drw_map $::cap1 .drw]
  lassign $::map scale x0 y0
  lassign $::cap1 path cw ch
  check "native capture" [expr {$scale > 1.5}] \
    "capture ${cw}x${ch} px of a [winfo width .]x[winfo height .] pt window (+ title bar), scale [format %.2f $scale]"
  # crispness is measured afterwards: pngcheck.py sharp on the lower left part of the
  # drawing area (cmos_inv.sch after zoom_full), compared with a 1x run (XSCHEM_AQUA_SCALE=1)
  say [format "INFO crispness: python3 pngcheck.py sharp %s %d %d %d %d" $path [expr {int($x0)}] \
    [expr {int($y0 + [winfo height .drw] * $scale * 0.4)}] [expr {int([winfo width .drw] * $scale)}] \
    [expr {int([winfo height .drw] * $scale * 0.4)}]]
  xschem callback .drw 2 150 120 119 0 0 0 ;# 'w': start wire
  xschem callback .drw 6 420 330 0 0 0 0
  later 600 step2
}
proc step2 {} {
  set ::cap2 [shot shot2] ;# rubber band wire visible
  check "rubber band drawn" [expr {[drw_diff $::cap1 $::cap2 $::map] > 0}] "shot2 differs from shot1"
  xschem callback .drw 6 560 150 0 0 0 0
  later 600 step3
}
proc step3 {} {
  set ::cap3 [shot shot3] ;# old rubber band erased, new one drawn
  xschem callback .drw 2 560 150 65307 0 0 0 ;# Escape
  later 300 step3b
}
proc step3b {} {
  set c [shot shot3b] ;# rubber band gone
  set n [drw_diff $::cap1 $c $::map]
  check "rubber band erased by Escape" [expr {$n == 0}] "$n pixels differ from shot1"
  xschem select_all
  xschem callback .drw 2 300 300 109 0 0 0 ;# 'm': move
  xschem callback .drw 6 380 240 0 0 0 0
  later 600 step4
}
proc step4 {} {
  set ::cap4 [shot shot4] ;# ghost of the moved selection follows the pointer
  check "move ghost drawn" [expr {[drw_diff $::cap1 $::cap4 $::map] > 0}] "shot4 differs from shot1"
  xschem callback .drw 2 380 240 65307 0 0 0
  xschem unselect_all
  later 600 step5
}
proc step5 {} {
  set ::cap5 [shot shot5] ;# clean schematic again
  set n [drw_diff $::cap1 $::cap5 $::map]
  check "Escape restores the schematic" [expr {$n == 0}] "$n pixels differ from shot1"
  set e0 $::nexpose
  xschem callback .drw 2 150 120 119 0 0 0
  set t0 [clock milliseconds]
  for {set i 0} {$i < 100} {incr i} {
    xschem callback .drw 6 [expr {200 + $i * 4}] [expr {150 + $i * 2}] 0 0 0 0
    update
  }
  set ms [expr {[clock milliseconds] - $t0}]
  say "INFO 100 pointer moves in wire mode: $ms ms, [expr {$::nexpose - $e0}] expose events"
  shot shot6
  xschem callback .drw 2 600 350 65307 0 0 0
  later 1500 step6 $::nexpose
}
proc step6 {e1} {
  set n [expr {$::nexpose - $e1}]
  check "idle" [expr {$n <= 3}] "$n expose events in 1.5 s idle"
  if {$::mode eq "quick"} { finish; return }
  # place a horizontal wire with pointer events and check where it lands
  set nw0 [xschem get wires]
  set px1 230; set px2 330; set py 90
  xschem callback .drw 2 $px1 $py 119 0 0 0 ;# 'w' at (px1, py)
  xschem callback .drw 6 $px2 $py 0 0 0 0
  xschem callback .drw 4 $px2 $py 0 1 0 0
  xschem callback .drw 5 $px2 $py 0 1 0 0
  xschem callback .drw 2 $px2 $py 65307 0 0 0
  set nw1 [xschem get wires]
  set zoom [xschem get zoom]; set xo [xschem get xorigin]; set yo [xschem get yorigin]
  set snap $::cadsnap ;# there is no "xschem get cadsnap"
  set ex1 [expr {round(($px1 * $zoom - $xo) / $snap) * $snap}]
  set ex2 [expr {round(($px2 * $zoom - $xo) / $snap) * $snap}]
  set ey [expr {round(($py * $zoom - $yo) / $snap) * $snap}]
  set wc [xschem wire_coord [expr {$nw1 - 1}]]
  lassign $wc wx1 wy1 wx2 wy2
  set ok [expr {$nw1 == $nw0 + 1 && abs(min($wx1,$wx2) - $ex1) < 1e-6 && abs(max($wx1,$wx2) - $ex2) < 1e-6 &&
                abs($wy1 - $ey) < 1e-6 && abs($wy2 - $ey) < 1e-6}]
  check "pointer to schematic coordinates" $ok "wires $nw0 -> $nw1, wire {$wc}, expected {$ex1 $ey $ex2 $ey}"
  set ::wire [list $wx1 $wy1 $wx2 $wy2 $zoom $xo $yo]
  later 400 step7
}
proc step7 {} {
  # the new wire must show up where the pointer was
  set cap [shot shot7]
  lassign $::wire wx1 wy1 wx2 wy2 zoom xo yo
  set sx [expr {(($wx1 + $wx2) / 2.0 + $xo) / $zoom}]
  set sy [expr {($wy1 + $yo) / $zoom}]
  set on [pixel $cap $::map $sx $sy]
  set off [pixel $cap $::map $sx [expr {$sy + 8}]]
  set before [pixel $::cap1 $::map $sx $sy]
  check "wire drawn under the pointer" [expr {$on ne $off && $on ne $before}] \
    "pixel at wire ($sx, $sy) pt = {$on}, 8 pt below = {$off}, before = {$before}"
  xschem undo
  xschem redraw
  # printing at a set size gives exactly that size, then the window is back at native scale
  xschem print png $::out/print_400x300.png 400 300
  set s [png_size $::out/print_400x300.png]
  check "print png 400 300" [expr {$s eq "400x300"}] "file is $s"
  xschem print png $::out/print_window.png 0 0
  set s [png_size $::out/print_window.png]
  set e "[winfo width .drw]x[winfo height .drw]"
  check "print png 0 0 (window size)" [expr {$s eq $e}] "file is $s, window $e pt"
  xschem print svg $::out/print.svg 400 300
  check "print svg" [file exists $::out/print.svg] "[file size $::out/print.svg] bytes"
  later 600 step8
}
proc step8 {} {
  set cap [shot shot8]
  set n [drw_diff $::cap1 $cap $::map]
  check "window back at native scale after printing" [expr {$n == 0}] "$n pixels differ from shot1"
  # resize to a size the window does not have (xschem remembers the last geometry)
  set ::newsize [list [expr {[winfo width .] == 1000 ? 900 : 1000}] [expr {[winfo height .] == 700 ? 640 : 700}]]
  wm geometry . [join $::newsize x]
  update
  later 1200 step9
}
proc step9 {} {
  set cap [shot shot9]
  lassign $cap path cw ch
  set map [drw_map $cap .drw]
  lassign $map scale x0 y0
  lassign $::newsize nw nh
  set ok [expr {abs($cw - $nw * $scale) < 1 && [winfo width .drw] == $nw && [winfo height .] == $nh}]
  check "resize" $ok "window [winfo width .]x[winfo height .] pt, drw [winfo width .drw]x[winfo height .drw], capture ${cw}x${ch}"
  # bottom right corner of the drawing area must have been redrawn (background, not garbage)
  set c [pixel $cap $map [expr {[winfo width .drw] - 3}] [expr {[winfo height .drw] - 3}]]
  say "INFO pixel near bottom right corner after resize: $c"
  set n [colours $cap .drw]
  check "redrawn after resize" [expr {$n > 20}] "$n colours in .drw"
  # a tab, or a window with tabbed_interface 0; poweramp.sch has graphs and embedded images.
  # win_path {1}: no "already open" dialog
  xschem new_schematic create {1} [file normalize ../xschem_library/examples/poweramp.sch]
  update
  later 1500 step10
}
proc step10 {} {
  set info [xschem new_schematic info]
  say "INFO new_schematic info: [string map {\n { | }} $info]"
  if {$::windows} {
    xschem zoom_full
    update
    set cap [shot shot10 {*poweramp*}]
    set capm [shot shot10m {*cmos_inv*}]
    set n [colours $cap .x1.drw]
    check "second window drawn" [expr {$n > 20}] "$n colours in .x1.drw"
    set n [colours $capm .drw]
    check "main window still drawn" [expr {$n > 20}] "$n colours in .drw"
    xschem new_schematic destroy .x1.drw
  } else {
    xschem zoom_full
    set cap [shot shot10]
    set n [colours $cap .drw]
    check "second tab drawn" [expr {$n > 20}] "$n colours in .drw"
    check "second tab opened" [expr {[xschem get current_win_path] eq {.x1.drw}}] "current [xschem get current_win_path]"
    xschem new_schematic switch .drw
  }
  update
  later 800 step11
}
proc step11 {} {
  set cap [shot shot11]
  set n [colours $cap .drw]
  check "main schematic drawn at the end" [expr {$n > 20}] "$n colours in .drw"
  say "INFO back on main schematic: current [xschem get current_win_path], drw [winfo width .drw]x[winfo height .drw]"
  # 0_examples_top.sch has a rectangle on stippled layer 8 at 860 -630 880 -570
  xschem load [file normalize ../xschem_library/examples/0_examples_top.sch]
  xschem zoom_box 855 -635 885 -565 1.0
  later 600 step12
}
proc step12 {} {
  # the inside of a stippled rectangle shows the stipple, not a solid fill
  set cap [shot shot12]
  set map [drw_map $cap .drw]
  set zoom [xschem get zoom]; set xo [xschem get xorigin]; set yo [xschem get yorigin]
  set img [image create photo -file [lindex $cap 0]]
  lassign $map scale x0 y0
  set lit 0; set n 0
  for {set x 866} {$x <= 874} {incr x} {
    for {set y -620} {$y <= -580} {incr y} {
      set c [$img get [expr {int($x0 + ($x + $xo) / $zoom * $scale)}] [expr {int($y0 + ($y + $yo) / $zoom * $scale)}]]
      if {$c ne {0 0 0}} { incr lit }
      incr n
    }
  }
  image delete $img
  check "stippled fill" [expr {$lit > 0 && $lit < $n / 2}] "$lit of $n samples inside the layer 8 rectangle are lit"
  # crosshair: drawn with line width 0, which CoreGraphics does not draw
  xschem zoom_full
  update
  set ::cap13 [shot shot13a]
  set ::draw_crosshair 1
  xschem callback .drw 7 300 200 0 0 0 0 ;# EnterNotify
  xschem callback .drw 6 310 210 0 0 0 0
  later 400 step13
}
proc step13 {} {
  set cap [shot shot13b]
  set map [drw_map $cap .drw]
  check "crosshair drawn" [expr {[drw_diff $::cap13 $cap $map] > 0}] "shot13b differs from shot13a"
  xschem callback .drw 8 600 400 0 0 0 0 ;# LeaveNotify elsewhere: crosshair removed
  set ::draw_crosshair 0
  update
  set cap [shot shot13c]
  set n [drw_diff $::cap13 $cap $map]
  check "crosshair removed" [expr {$n == 0}] "$n pixels differ from shot13a"
  # preview pane of the load dialog: a frame with a white background
  toplevel .pv
  wm title .pv preview
  wm geometry .pv 360x260+60+60
  frame .pv.draw -width 340 -height 240 -background white
  pack .pv.draw -fill both -expand 1
  update
  set f [file normalize ../xschem_library/examples/cmos_inv.sch]
  xschem preview_window create .pv.draw {}
  xschem preview_window draw .pv.draw $f
  bind .pv.draw <Expose> [list xschem preview_window draw .pv.draw $f]
  later 800 step14
}
proc step14 {} {
  set cap [shot shot14 preview]
  set n [colours $cap .pv.draw]
  check "preview pane drawn" [expr {$n > 20}] "$n colours in .pv.draw"
  xschem preview_window destroy .pv.draw {}
  destroy .pv
  finish
}
proc finish {} {
  say "DONE failures=$::nfail"
  close $::rep
  exit
}
later 3500 step1
