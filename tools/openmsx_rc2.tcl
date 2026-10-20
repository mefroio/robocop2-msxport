# openMSX helpers for the Robocop 2 prototype (load with: source tools/openmsx_rc2.tcl).
# Headless openMSX runs unthrottled: schedule pauses with 'after time', then call these
# while paused, and resume with 'set pause off' from the top level.

# Saves what tools/msxframe.py needs: VRAM, RAM C000h-CFFFh, page 0 RAM (0000h-3FFFh: the tile
# cache and the map patches) and the 48 VDP registers.
proc rc2_snap {dir} {
	file mkdir $dir
	save_debuggable VRAM [file join $dir vram.bin]
	set f [open [file join $dir ram.bin] wb]
	fconfigure $f -translation binary
	puts -nonewline $f [debug read_block memory 0xC000 0x1000]
	close $f
	set f [open [file join $dir ram0.bin] wb]
	fconfigure $f -translation binary
	puts -nonewline $f [debug read_block memory 0x0000 0x4000]
	close $f
	set regs {}
	for {set i 0} {$i < 48} {incr i} { lappend regs [debug read "VDP regs" $i] }
	set f [open [file join $dir regs.txt] w]
	puts $f $regs
	close $f
	return $dir
}

# Logs, for 'secs' of emulated time, the line/VBLANK interrupts (with R#18), every read of
# port 99h (with S#2 and R#15) and every write to port 99h; written to 'file' when done.
# Analyse with the split timeline script (lines labelled from the line interrupt).
proc rc2_log {secs file} {
	set ::rc2_hl {}; set ::rc2_vl {}; set ::rc2_rl {}; set ::rc2_wl {}
	set bp1 [debug probe set_bp VDP.IRQhorizontal {} {lappend ::rc2_hl [list [machine_info time] [debug probe read VDP.IRQhorizontal] [debug read "VDP regs" 18]]}]
	set bp2 [debug probe set_bp VDP.IRQvertical {} {lappend ::rc2_vl [list [machine_info time] [debug probe read VDP.IRQvertical] 0]}]
	set wp1 [debug set_watchpoint write_io 0x99 {} {lappend ::rc2_wl [list [machine_info time] $::wp_last_value]}]
	set wp2 [debug set_watchpoint read_io 0x99 {} {lappend ::rc2_rl [list [machine_info time] [debug read "VDP status regs" 2] [debug read "VDP regs" 15]]}]
	set ::rc2_log_state [list $bp1 $bp2 $wp1 $wp2 $file]
	after time $secs {set pause on; rc2_log_end}
	return "logging; resume with 'set pause off'"
}

proc rc2_log_end {} {
	lassign $::rc2_log_state bp1 bp2 wp1 wp2 file
	debug probe remove_bp $bp1
	debug probe remove_bp $bp2
	debug remove_watchpoint $wp1
	debug remove_watchpoint $wp2
	set f [open $file w]
	foreach e $::rc2_hl { puts $f "H [join $e]" }
	foreach e $::rc2_vl { puts $f "V [join $e]" }
	foreach e $::rc2_rl { puts $f "R [join $e]" }
	foreach e $::rc2_wl { puts $f "W [join $e]" }
	close $f
}

# Counts VRAM accesses the VDP loses because the CPU made them too fast (setting
# too_fast_vram_access = real); ::rc2_too_fast holds the count, ::rc2_too_fast_pc the last PCs.
proc rc2_count_too_fast {} {
	set ::rc2_too_fast 0
	set ::rc2_too_fast_pc {}
	set {::VDP.too_fast_vram_access_callback} {incr ::rc2_too_fast; if {[llength $::rc2_too_fast_pc] < 16} {lappend ::rc2_too_fast_pc [format %04x [reg pc]]}}
	return "counting lost VRAM accesses"
}

# Takes 'n' snapshots (rc2_snap) every 'secs' of emulated time into dir/s00, dir/s01, ...
# without pausing (an 'after time' callback runs between two CPU instructions); pauses after
# the last one and sets ::rc2_snaps_done.
proc rc2_snaps {dir n secs} {
	set ::rc2_snaps_state [list $dir $n $secs 0]
	set ::rc2_snaps_done 0
	after time $secs rc2_snaps_step
	return "taking $n snapshots; resume with 'set pause off'"
}

proc rc2_snaps_step {} {
	lassign $::rc2_snaps_state dir n secs k
	rc2_snap [file join $dir [format s%02d $k]]
	incr k
	set ::rc2_snaps_state [list $dir $n $secs $k]
	if {$k < $n} {
		after time $secs rc2_snaps_step
	} else {
		set ::rc2_snaps_done 1
		set ::pause on
	}
}

# Logs, for 'secs' of emulated time, the emulated time at which the CPU reaches each address
# of 'labels' (a list of name address pairs); written to 'file' as "name time" lines (the
# emulation goes on). Analyse with tools/proflog.py.
proc rc2_prof {secs file labels} {
	set ::rc2_prof {}
	set bps {}
	foreach {name addr} $labels {
		lappend bps [debug set_bp $addr {} "lappend ::rc2_prof \[list $name \[machine_info time\]\]"]
	}
	set ::rc2_prof_state [list $bps $file]
	after time $secs rc2_prof_end
	return "profiling"
}

proc rc2_prof_end {} {
	lassign $::rc2_prof_state bps file
	foreach bp $bps { debug remove_bp $bp }
	set f [open $file w]
	foreach e $::rc2_prof { puts $f [join $e] }
	close $f
}

# Takes up to 'n' snapshots (rc2_snap) into dir/s00, dir/s01, ... when the CPU reaches 'addr'
# with 'cond' true (a Tcl expression, e.g. {[peek 0xC0D6] != 0}), at least 'gap' seconds of
# emulated time apart; pauses after the last one and sets ::rc2_snaps_done.
proc rc2_snaps_when {dir n addr cond gap} {
	set ::rc2_sw [list $dir $n $gap 0 -1000.0]
	set ::rc2_snaps_done 0
	set ::rc2_sw_bp [debug set_bp $addr $cond rc2_sw_hit]
	return "waiting for $n snapshots; resume with 'set pause off'"
}

proc rc2_sw_hit {} {
	lassign $::rc2_sw dir n gap k last
	set t [machine_info time]
	if {$t - $last < $gap} return
	rc2_snap [file join $dir [format s%02d $k]]
	incr k
	set ::rc2_sw [list $dir $n $gap $k $t]
	if {$k >= $n} {
		debug remove_bp $::rc2_sw_bp
		set ::rc2_snaps_done 1
		set ::pause on
	}
}

# Game-logic trace: at each hit of 'addr' (the game tick's start, label tick_start in
# build/msx/rc2.labels: 'call game_tick', whose target is 'target') records the game variables
# of msx/msx.inc (the Amiga mirror: g_frame, p_x, p_y, p_state, p_anim, p_aim, p_vy, gcam_x,
# gcam_y as unsigned words; p_air, g_joy, and p_rec as bytes); after 'n' hits writes them to 'file' (one line per game
# frame), pauses and sets ::rc2_trace_done. Hits where 'addr' does not hold that call (the
# machine's own ROMs in page 1 while it boots) are ignored. Compare with tools/amigaemu.py game
# --trace using tools/tracecmp.py.
proc rc2_w {addr} { expr {[peek $addr] + 256 * [peek [expr {$addr + 1}]]} }

proc rc2_trace {file n addr target} {
	set ::rc2_tr {}
	set ::rc2_tr_state [list $file $n]
	set ::rc2_trace_done 0
	set cond "\[peek $addr\] == 0xCD && \[rc2_w [expr {$addr + 1}]\] == $target"
	set ::rc2_tr_bp [debug set_bp $addr $cond rc2_trace_hit]
	return "tracing $n game frames; resume with 'set pause off'"
}

proc rc2_trace_hit {} {
	lassign $::rc2_tr_state file n
	set v {}
	foreach a {0xD000 0xDAD0 0xDAD4 0xDAE2 0xDADC 0xDADA 0xDAE0 0xD004 0xD006} { lappend v [rc2_w $a] }
	lappend v [peek 0xDAE6] [peek 0xDC2E] [peek 0xCE36]
	lappend ::rc2_tr $v
	if {[llength $::rc2_tr] >= $n} {
		debug remove_bp $::rc2_tr_bp
		set f [open $file w]
		foreach e $::rc2_tr { puts $f [join $e] }
		close $f
		set ::rc2_trace_done 1
		set ::pause on
	}
}

# Full game-state trace: like rc2_trace, but each line holds the whole mirror of the game's
# variables (AM: $B00-$16EB at D000h, AG: $8000-$80FF at DC00h, msx/msx.inc), the variables of
# the Amiga's code area and the spawn list (DD00h-DFFFh) and the object list (EE00h-F0FFh) as hex, for
# tools/tracecmp.py --ram.
proc rc2_trace_ram {file n addr target} {
	set ::rc2_trr {}
	set ::rc2_trr_state [list $file $n]
	set ::rc2_trace_done 0
	set cond "\[peek $addr\] == 0xCD && \[rc2_w [expr {$addr + 1}]\] == $target"
	set ::rc2_trr_bp [debug set_bp $addr $cond rc2_trace_ram_hit]
	return "tracing $n game frames; resume with 'set pause off'"
}

proc rc2_trace_ram_hit {} {
	lassign $::rc2_trr_state file n
	binary scan [debug read_block memory 0xD000 0x0BEC] H* ram
	binary scan [debug read_block memory 0xDC00 0x100] H* glob
	binary scan [debug read_block memory 0xDD00 0x300] H* ac
	binary scan [debug read_block memory 0xEE00 0x300] H* lists
	lappend ::rc2_trr "$ram $glob $ac $lists"
	if {[llength $::rc2_trr] >= $n} {
		debug remove_bp $::rc2_trr_bp
		set f [open $file w]
		foreach e $::rc2_trr { puts $f $e }
		close $f
		set ::rc2_trace_done 1
		set ::pause on
	}
}

# Sampling profile: every 'dt' seconds of emulated time, 'n' times, records the PC and the bank
# of the 8000h window (act_8000, msx/msx.inc) as "pc bank" pairs into 'file' (an 'after time'
# callback runs between two instructions). Analyse with tools/msxprof.py.
proc rc2_sample {n dt file} {
	set ::rs_left $n
	set ::rs_dt $dt
	set ::rs_file $file
	set ::rs_pcs {}
	set ::rs_done 0
	after time $dt rc2_sample_step
	return "sampling"
}

proc rc2_sample_step {} {
	lappend ::rs_pcs "[reg pc] [peek 0xC07C]"
	incr ::rs_left -1
	if {$::rs_left > 0} {
		after time $::rs_dt rc2_sample_step
	} else {
		set f [open $::rs_file w]
		foreach e $::rs_pcs { puts $f $e }
		close $f
		set ::rs_done 1
	}
}
