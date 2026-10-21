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
# the Amiga's code area and the spawn list (DD00h-DFFFh), the object list (EE00h-F0FFh) and the special
# objects' records (E900h-E9FFh) as hex, for
# tools/tracecmp.py --ram.
proc rc2_trace_ram {file n addr target {from 0}} {
	set ::rc2_trr {}
	set ::rc2_trr_state [list $file $n]
	set ::rc2_trace_done 0
	set cond "\[peek $addr\] == 0xCD && \[rc2_w [expr {$addr + 1}]\] == $target && \[rc2_w 0xCEE0\] >= $from"
	set ::rc2_trr_bp [debug set_bp $addr $cond rc2_trace_ram_hit]
	return "tracing $n game frames; resume with 'set pause off'"
}

proc rc2_trace_ram_hit {} {
	lassign $::rc2_trr_state file n
	binary scan [debug read_block memory 0xD000 0x0BEC] H* ram
	binary scan [debug read_block memory 0xDC00 0x100] H* glob
	binary scan [debug read_block memory 0xDD00 0x300] H* ac
	binary scan [debug read_block memory 0xEE00 0x300] H* lists
	binary scan [debug read_block memory 0xE900 0x100] H* sp
	lappend ::rc2_trr "$ram $glob $ac $lists $sp"
	if {[llength $::rc2_trr] >= $n} {
		debug remove_bp $::rc2_trr_bp
		set f [open $file w]
		foreach e $::rc2_trr { puts $f $e }
		close $f
		set ::rc2_trace_done 1
		set ::pause on
	}
}

# Driven full-state trace for EXTJOY=1 test builds (tools/mkrom.py): at every game tick's start
# (addr / target: tick_start and game_tick from the ROM's labels, build/msx/rc2_ext.labels) the row is written to 'file' (from game
# frame 'from' on, 'n' rows), then the frame's input is applied as tools/amigaemu.py game does after
# recording: the joystick byte for the game frame (tick_n, msx/msx.inc: the ticks since the
# power-on) into ext_joy, the teleports (RoboCop
# at x, y; the camera at x - 108h within 0..8E0h, y - 70h from 0) and god mode (energy and $16C4
# 100h, lives 2) and the pokes (the game's variables by their Amiga address: AM / AG of
# msx/msx.inc, a byte at A ^ 1, a word little-endian). 'script' holds four lines: the joystick
# byte of every game frame as hex, the teleports as "frame:x:y ...", god 0/1, the pokes as
# "frame:address:value:size ..." (tools/drivejoy.py writes it).
proc rc2_drive_trace {file n addr target from script} {
	set f [open $script r]
	set ::rd_joy [string trim [gets $f]]
	set ::rd_tele {}
	foreach t [split [string trim [gets $f]]] {
		if {$t ne ""} { lappend ::rd_tele [split $t :] }
	}
	set ::rd_god [string trim [gets $f]]
	set ::rd_poke {}
	foreach t [split [string trim [gets $f]]] {
		if {$t ne ""} { lappend ::rd_poke [split $t :] }
	}
	close $f
	set ::rd_left $n
	set ::rd_from $from
	set ::rd_out [open $file w]
	set ::rc2_trace_done 0
	set cond "\[peek $addr\] == 0xCD && \[rc2_w [expr {$addr + 1}]\] == $target"
	set ::rd_bp [debug set_bp $addr $cond rc2_drive_hit]
	return "driving; resume with 'set pause off'"
}

# A label's address from a z80asm label file (build/msx/rc2.labels: "name:\tequ $hex").
proc rc2_label {labels name} {
	set f [open $labels r]
	set v ""
	while {[gets $f line] >= 0} {
		if {[regexp "^${name}:\\s+equ \\\$(\[0-9a-fA-F\]+)" $line -> h]} { set v "0x$h"; break }
	}
	close $f
	if {$v eq ""} { error "no label $name in $labels" }
	return $v
}

# rc2_drive_trace on a fresh start of 'rom' (an EXTJOY=1 build; 'labels' its label file): the
# breakpoints and conditions removed, the cartridge inserted again, the machine reset.
proc rc2_drive_rom {rom labels file n from script} {
	foreach {id opts} [debug breakpoint list] { debug breakpoint remove $id }
	foreach {id opts} [debug condition list] { debug condition remove $id }
	carta eject
	carta insert $rom -romtype KonamiSCC
	if {[debug breaked]} { debug cont }
	set ::pause off
	reset
	rc2_drive_trace $file $n [rc2_label $labels tick_start] [rc2_label $labels game_tick] $from $script
}

proc rc2_wset {addr v} {
	poke $addr [expr {$v & 0xFF}]
	poke [expr {$addr + 1}] [expr {($v >> 8) & 0xFF}]
}

proc rc2_drive_hit {} {
	set gf [rc2_w 0xCEE0]
	if {$gf >= $::rd_from && $::rd_left > 0} {
		binary scan [debug read_block memory 0xD000 0x0BEC] H* ram
		binary scan [debug read_block memory 0xDC00 0x100] H* glob
		binary scan [debug read_block memory 0xDD00 0x300] H* ac
		binary scan [debug read_block memory 0xEE00 0x300] H* lists
		binary scan [debug read_block memory 0xE900 0x100] H* sp
		puts $::rd_out "$ram $glob $ac $lists $sp"
		incr ::rd_left -1
		if {$::rd_left == 0} {
			close $::rd_out
			debug remove_bp $::rd_bp
			set ::rc2_trace_done 1
			set ::pause on
			return
		}
	}
	set i [expr {2 * $gf}]
	set b [string range $::rd_joy $i [expr {$i + 1}]]
	poke 0xCE5A [expr {$b eq "" ? 0 : "0x$b"}]
	foreach t $::rd_tele {
		lassign $t tf tx ty
		if {$tf == $gf} {
			rc2_wset 0xDAD0 $tx
			rc2_wset 0xDAD4 $ty
			set cx [expr {$tx - 0x108}]
			if {$cx < 0} { set cx 0 }
			if {$cx > 0x8E0} { set cx 0x8E0 }
			set cy [expr {$ty - 0x70}]
			if {$cy < 0} { set cy 0 }
			rc2_wset 0xD004 $cx
			rc2_wset 0xD006 $cy
		}
	}
	foreach t $::rd_poke {
		lassign $t pf pa pv ps
		if {$pf == $gf} {
			set m [expr {$pa >= 0x8000 ? 0x5C00 + $pa : 0xC500 + $pa}]
			if {$ps == 1} { poke [expr {$m ^ 1}] [expr {$pv & 0xFF}] } else { rc2_wset $m $pv }
		}
	}
	if {$::rd_god} {
		rc2_wset 0xDB9A 0x100
		rc2_wset 0xDBC4 0x100
		rc2_wset 0xDC34 2
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

# Sampling profile of one stretch of the main loop: like rc2_sample, but only the samples taken
# between the CPU reaching 'from' and 'to' (e.g. game_tick and do_update from rc2.labels) count;
# 'n' of them are written to 'file'. Analyse with tools/msxprof.py.
proc rc2_sample_span {n dt file from to} {
	set ::rss_in 0
	set ::rss_bps [list [debug set_bp $from {} {set ::rss_in 1}] [debug set_bp $to {} {set ::rss_in 0}]]
	set ::rs_left $n
	set ::rs_dt $dt
	set ::rs_file $file
	set ::rs_pcs {}
	set ::rs_done 0
	after time $dt rc2_sample_span_step
	return "sampling"
}

proc rc2_sample_span_step {} {
	if {$::rss_in} {
		lappend ::rs_pcs "[reg pc] [peek 0xC07C]"
		incr ::rs_left -1
	}
	if {$::rs_left > 0} {
		after time $::rs_dt rc2_sample_span_step
	} else {
		foreach b $::rss_bps { debug remove_bp $b }
		set f [open $::rs_file w]
		foreach e $::rs_pcs { puts $f $e }
		close $f
		set ::rs_done 1
	}
}

# Real-renderer capture (needs a renderer: 'set renderer SDLGL-PP'): for 'n' frames in a row,
# at each VBLANK interrupt request (the end of a frame's display, before the ISR puts the next
# list on screen) the state of that frame is saved as with rc2_snap into dir/fNNNN, and the
# picture openMSX rendered for it into dir/fNNNN/real.png once the frame is finished. Check
# with tools/msxreal.py.
proc rc2_real {dir n} {
	set ::rr_dir $dir
	set ::rr_left $n
	set ::rr_k 0
	set ::rr_done 0
	set ::rr_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 1} rc2_real_hit]
	return "capturing"
}

proc rc2_real_hit {} {
	if {$::rr_left <= 0} { return }
	set d [file join $::rr_dir [format "f%04d" $::rr_k]]
	rc2_snap $d
	after frame [list screenshot -raw [file join $d real.png]]
	incr ::rr_k
	incr ::rr_left -1
	if {$::rr_left == 0} {
		debug probe remove_bp $::rr_bp
		after frame {set ::rr_done 1}
	}
}

# The BOBs the MSX shows (EXTJOY build driven like rc2_drive_rom): at every bob_flush, the
# game tick counter (CEE0h) and the records of bob_list (msx/bob.asm: A2 (3), D4, x, y, mode |
# category << 4, link) into 'file', 'n' lines, as "tick count hexrecords". Compare with the
# bench's draw_bob calls (tools/amigaemu.py game --bobs) in tools/bobcmp.py.
proc rc2_bobs_rom {rom labels file n script} {
	rc2_drive_rom $rom $labels [file join [file dirname $file] bobs_drive.txt] 1 999999 $script
	set ::rb_out [open $file w]
	set ::rb_left $n
	set ::rb_done 0
	set ::rb_bp [debug set_bp [rc2_label $labels bob_flush] {} rc2_bobs_hit]
	return "recording"
}

proc rc2_bobs_hit {} {
	set n [peek 0xCE8A]
	binary scan [debug read_block memory 0xEA60 [expr {12 * $n}]] H* recs
	puts $::rb_out "[rc2_w 0xCEE0] $n $recs"
	incr ::rb_left -1
	if {$::rb_left == 0} {
		close $::rb_out
		debug remove_bp $::rb_bp
		set ::rb_done 1
		set ::pause on
	}
}

# What every new list shows (EXTJOY build driven like rc2_drive_rom): at each VBLANK interrupt
# request, when the list on screen is a new one, a line "seq cam_x cam_y game_frame pub_spr"
# (the list's tail and its pub_spr copy as hex: MAX_OBJ x [flags, id (2), drop, x (2), y (2)])
# into 'file', 'n' lines. Compare with the bench's draw_bob calls in tools/objcmp.py.
proc rc2_objs_rom {rom labels file n script} {
	rc2_drive_rom $rom $labels [file join [file dirname $file] objs_drive.txt] 1 999999 $script
	set ::ro_out [open $file w]
	set ::ro_left $n
	set ::ro_done 0
	set ::ro_seq -1
	set ::ro_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 1} rc2_objs_hit]
	return "recording"
}

proc rc2_objs_hit {} {
	set seq [peek 0xC006]
	if {$seq == $::ro_seq} { return }
	set ::ro_seq $seq
	foreach {base pub} {0xC080 0xC700 0xC0A0 0xC780} {
		if {[peek $base] == $seq} {
			set len [peek [expr {$base + 1}]]
			set t [expr {$base + 2 + $len}]
			binary scan [debug read_block memory $pub 128] H* objs
			puts $::ro_out "$seq [rc2_w $t] [rc2_w [expr {$t + 2}]] [rc2_w [expr {$t + 4}]] $objs"
			incr ::ro_left -1
			break
		}
	}
	if {$::ro_left <= 0} {
		close $::ro_out
		debug probe remove_bp $::ro_bp
		set ::ro_done 1
		set ::pause on
	}
}

# Exact display record for LOCKSTEP test builds (tools/mkrom.py LOCKSTEP=K: the frames come at
# fixed VBLANKs whatever the CPU time, so builds whose sprite engines decide alike give the same
# record): at the line interrupt of the HUD split (the play area's sprites shown, the uploads of
# the blank time not yet run) of every frame that shows a new list, "seq game_frame park_y mux
# SATs colour_table pattern_table pub_spr cam_x cam_y" (the list's SAT pair in RAM, sat_cur: both halves, 256
# bytes; VRAM 1E000h 512, 1D800h 2048; hex) into 'file' (compare with tools/dispcmp.py),
# 'n' lines; ::rx_over then holds how many frames started late meanwhile (lk_over: then the record
# is not exact from there on), ::rx_late the game frames around which they did.
proc rc2_disp_rom {rom labels file n script} {
	rc2_drive_rom $rom $labels [file join [file dirname $file] disp_drive.txt] 1 999999 $script
	set ::rx_out [open $file w]
	set ::rx_left $n
	set ::rx_done 0
	set ::rx_seq -1
	set ::rx_late {}
	unset -nocomplain ::rx_over0
	set ::rx_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_disp_hit]
	return "recording"
}

proc rc2_disp_hit {} {
	set seq [peek 0xC006]
	if {$seq == $::rx_seq} { return }
	set ::rx_seq $seq
	if {![info exists ::rx_over0]} { set ::rx_over0 [peek 0xF168]; set ::rx_last0 $::rx_over0 }
	if {[peek 0xF168] != $::rx_last0} { set ::rx_last0 [peek 0xF168]; lappend ::rx_late [rc2_w 0xD000] }
	foreach {base pub} {0xC080 0xC700 0xC0A0 0xC780} {
		if {[peek $base] == $seq} {
			set len [peek [expr {$base + 1}]]
			set t [expr {$base + 2 + $len}]
			binary scan [debug read_block memory [rc2_w 0xCA6E] 256] H* sat
			binary scan [debug read_block VRAM [rc2_sprset_col] 512] H* col
			binary scan [debug read_block VRAM 0x1D800 2048] H* pat
			binary scan [debug read_block memory $pub 128] H* objs
			puts $::rx_out "$seq [rc2_w [expr {$t + 4}]] [peek 0xC050] [peek 0xC0E3] $sat $col $pat $objs [rc2_w $t] [rc2_w [expr {$t + 2}]]"
			incr ::rx_left -1
			break
		}
	}
	if {$::rx_left <= 0} {
		close $::rx_out
		debug probe remove_bp $::rx_bp
		set ::rx_over [expr {([peek 0xF168] - $::rx_over0) & 255}]
		set ::rx_done 1
		set ::pause on
	}
}

# SAT check: at the line interrupt of every frame for 'n' frames, the SAT of the set on screen against
# the half of the SAT pair on screen (sat_cur) that the frame's VBLANK put there (+80h on odd
# frames while objects alternate, pk_mux), unless a SAT write is due (sat_due: vram_done writes
# it). ::rs_sat_bad counts the frames that differ, ::rs_sat_mux those that alternated; pauses
# when done (::rs_sat_done).
proc rc2_satcheck {n} {
	set ::rs_sat_left $n
	set ::rs_sat_bad 0
	set ::rs_sat_mux 0
	set ::rs_sat_log {}
	set ::rs_sat_done 0
	set ::rs_sat_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_satcheck_hit]
	return "checking"
}

proc rc2_satcheck_hit {} {
	if {[peek 0xC002] == 0} { return }
	if {[peek 0xEC51] == 0} {
		set cur [rc2_w 0xCA6E]
		set mux [peek 0xC0E3]
		if {$mux && ([peek 0xC001] - 1) & 1} { set cur [expr {$cur + 0x80}] }
		if {$mux} { incr ::rs_sat_mux }
		set v [debug read_block VRAM [expr {[rc2_sprset_col] + 0x200}] 128]
		set m [debug read_block memory $cur 128]
		if {$v ne $m} {
			incr ::rs_sat_bad
			if {[llength $::rs_sat_log] < 12} {
				binary scan $v cu* vb
				binary scan $m cu* mb
				set d {}
				for {set i 0} {$i < 128} {incr i} {
					if {[lindex $vb $i] != [lindex $mb $i]} { lappend d "$i:[lindex $vb $i]/[lindex $mb $i]" }
				}
				lappend ::rs_sat_log "f=[rc2_w 0xD000] tick=[peek 0xC001] mux=$mux cur=[format %04x $cur] app=[peek 0xC006] pub=[peek 0xC005] pk=[peek 0xC0E0] busy=[peek 0xEC50] [lrange $d 0 11]"
			}
		}
	}
	incr ::rs_sat_left -1
	if {$::rs_sat_left <= 0} {
		debug probe remove_bp $::rs_sat_bp
		set ::rs_sat_done 1
		set ::pause on
	}
}

# Picture rate: drives 'rom' with 'script' and counts, between game frames g1 and g2, the
# register lists put on screen (pictures) and the emulated time they took; ::rr_result then holds
# "pictures seconds pictures_per_second ticks_per_second" and the machine pauses.
proc rc2_rate {rom labels script g1 g2} {
	rc2_drive_rom $rom $labels [file join [file dirname $rom] rate_drive.txt] 1 999999 $script
	set ::rr_g1 $g1
	set ::rr_g2 $g2
	set ::rr_seq -1
	set ::rr_n 0
	set ::rr_t0 -1
	set ::rr_armed 0
	set ::rr_result ""
	set ::rr_bp [debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 1} rc2_rate_hit]
	return "measuring"
}

proc rc2_rate_hit {} {
	set seq [peek 0xC006]
	if {$seq == $::rr_seq} { return }
	set ::rr_seq $seq
	set gf [rc2_w 0xD000]
	if {$gf < $::rr_g1} { set ::rr_armed 1; return }
	if {!$::rr_armed} { return }
	if {$::rr_t0 < 0} { set ::rr_t0 [machine_info time]; set ::rr_f0 $gf; return }
	incr ::rr_n
	if {$gf >= $::rr_g2} {
		set dt [expr {[machine_info time] - $::rr_t0}]
		set ::rr_result [format "%d %.3f %.2f %.2f" $::rr_n $dt [expr {$::rr_n / $dt}] [expr {($gf - $::rr_f0) / $dt}]]
		debug probe remove_bp $::rr_bp
		set ::pause on
	}
}

# Sprite VRAM writes by scan line: follows the VDP's address (port 99h: address setup, R#14) and
# every port 98h write for 'secs' of emulated time; a write into the colour table or SAT of the
# sprite set on screen (R#5) is logged with its line, counted from the line interrupt (the HUD
# split, display line SPLIT_LINE) at 228 CPU cycles a line (60 Hz: 262 lines). ::rv_hist then
# holds per line the writes, ::rv_bad those made on lines 0..vis-1 (sprites on screen there),
# ::rv_late per PC the writes from line 240 on or on those lines.
proc rc2_sprvram {secs vis split_line} {
	set ::rv_latch -1
	set ::rv_addr 0
	set ::rv_r14 0
	set ::rv_tsplit -1
	set ::rv_split $split_line
	set ::rv_vis $vis
	array unset ::rv_hist
	array unset ::rv_late
	set ::rv_bad 0
	set ::rv_badlog {}
	set ::rv_n 0
	set ::rv_wps [list \
		[debug set_watchpoint write_io 0x99 {} rc2_sv_99] \
		[debug set_watchpoint read_io 0x99 {} {set ::rv_latch -1}] \
		[debug set_watchpoint write_io 0x98 {} rc2_sv_98]]
	set ::rv_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} {if {[peek 0xC002]} {set ::rv_tsplit [machine_info time]}}]
	after time $secs rc2_sv_end
	return "logging"
}

proc rc2_sv_99 {} {
	set v $::wp_last_value
	if {$::rv_latch < 0} { set ::rv_latch $v; return }
	set lo $::rv_latch
	set ::rv_latch -1
	if {$v & 0x80} {
		if {($v & 0x3F) == 14} { set ::rv_r14 [expr {$lo & 7}] }
	} else {
		set ::rv_addr [expr {($::rv_r14 << 14) | (($v & 0x3F) << 8) | $lo}]
	}
}

proc rc2_sv_98 {} {
	set a $::rv_addr
	set ::rv_addr [expr {($a + 1) & 0x1FFFF}]
	set c [rc2_sprset_col]
	if {$a < $c || $a >= $c + 0x280 || $::rv_tsplit < 0} { return }
	incr ::rv_n
	set dt [expr {[machine_info time] - $::rv_tsplit}]
	set line [expr {int(($::rv_split + $dt * 3579545.0 / 228.0)) % 262}]
	if {[info exists ::rv_hist($line)]} { incr ::rv_hist($line) } else { set ::rv_hist($line) 1 }
	if {$line >= 240 || $line < $::rv_vis} {
		set pc [format %04x [reg pc]]
		if {[info exists ::rv_late($pc)]} { incr ::rv_late($pc) } else { set ::rv_late($pc) 1 }
	}
	if {$line < $::rv_vis} {
		incr ::rv_bad
		if {[llength $::rv_badlog] < 20} { lappend ::rv_badlog [format "line %d addr %05x pc %04x" $line $a [reg pc]] }
	}
}

proc rc2_sv_end {} {
	foreach w $::rv_wps { debug remove_watchpoint $w }
	debug probe remove_bp $::rv_bp
	set ::pause on
}

# Interrupt timing by scan line (lines counted as rc2_sprvram does, from the line interrupt at
# display line split_line): for 'secs', the line at which each address of 'labels' (name address
# pairs) is reached, as a histogram per name in ::ri_hist(name) ("line count ..."); pauses when done.
proc rc2_isrlines {secs split_line labels} {
	set ::ri_tsplit -1
	set ::ri_split $split_line
	array unset ::ri_h
	set ::ri_bps {}
	foreach {name addr} $labels {
		lappend ::ri_bps [debug set_bp $addr {} [list rc2_ri_hit $name]]
	}
	set ::ri_pb [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} {if {[peek 0xC002]} {set ::ri_tsplit [machine_info time]}}]
	after time $secs rc2_ri_end
	return "timing"
}

proc rc2_ri_hit {name} {
	if {$::ri_tsplit < 0} { return }
	set dt [expr {[machine_info time] - $::ri_tsplit}]
	set line [expr {int(($::ri_split + $dt * 3579545.0 / 228.0)) % 262}]
	if {[info exists ::ri_h($name,$line)]} { incr ::ri_h($name,$line) } else { set ::ri_h($name,$line) 1 }
}

proc rc2_ri_end {} {
	foreach b $::ri_bps { debug remove_bp $b }
	debug probe remove_bp $::ri_pb
	set ::pause on
}

# The histogram of one name: "line:count ..." in line order.
proc rc2_ri_hist {name} {
	set out {}
	foreach k [lsort -dictionary [array names ::ri_h "$name,*"]] {
		set line [lindex [split $k ,] 1]
		lappend out [list $line $::ri_h($k)]
	}
	set out [lsort -integer -index 0 $out]
	set s {}
	foreach e $out { lappend s "[lindex $e 0]:[lindex $e 1]" }
	return [join $s " "]
}

# Late interrupts: for 'secs', at every entry of the interrupt routine ('isr_addr') on a line
# outside 'ok' (a list of lines where interrupts are expected), logs the line and the address
# the main program was interrupted at (the return address on the stack) into ::rl_log.
proc rc2_lateirq {secs split_line isr_addr ok} {
	set ::rl_tsplit -1
	set ::rl_split $split_line
	set ::rl_ok $ok
	set ::rl_log {}
	set ::rl_bp [debug set_bp $isr_addr {} rc2_rl_hit]
	set ::rl_pb [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} {if {[peek 0xC002]} {set ::rl_tsplit [machine_info time]}}]
	after time $secs {debug remove_bp $::rl_bp; debug probe remove_bp $::rl_pb; set ::pause on}
	return "watching"
}

proc rc2_rl_hit {} {
	if {$::rl_tsplit < 0} { return }
	set dt [expr {[machine_info time] - $::rl_tsplit}]
	set line [expr {int(($::rl_split + $dt * 3579545.0 / 228.0)) % 262}]
	if {[lsearch -exact $::rl_ok $line] >= 0} { return }
	if {[llength $::rl_log] < 40} {
		set sp [reg sp]
		lappend ::rl_log [format "line %d ret %04x" $line [expr {[peek $sp] + 256 * [peek [expr {$sp + 1}]]}]]
	}
}

# Sprite data check: at the start of each plan (msx/sprites.asm spr_plan, 'plan_addr') while the
# list last published is on screen (pk_state 0: what disp holds is what the screen shows), every
# entry of every shown version (disp, its entry page in page 0 RAM) against VRAM: the pattern its
# slot holds (1D800h + 32 slot) must be the pattern id's (the ROM's pattern pool), and the colour
# row of its SAT entry (the colour table of the set on screen, R#5, + 16 entry) the colour id's
# (colour pool; bit 15: the early clock,
# bit 7 of every byte). 'rom' is the ROM file, 'base', 'patbank', 'colbank' SPR_BASE_BANK,
# SPR_PAT_BANK, SPR_COL_BANK. For 'n' plans; ::rp_bad counts wrong patterns and rows, ::rp_log
# details the first ones, ::rp_n the entries checked; pauses when done.
proc rc2_patcheck {rom plan_addr base patbank colbank n} {
	set f [open $rom rb]
	set ::rp_rom [read $f]
	close $f
	set ::rp_base $base
	set ::rp_pat $patbank
	set ::rp_col $colbank
	set ::rp_left $n
	set ::rp_bad 0
	set ::rp_n 0
	set ::rp_log {}
	set ::rp_bp [debug set_bp $plan_addr {[peek 0xC0E0] == 0} rc2_rp_hit]
	return "checking"
}

proc rc2_rp_hit {} {
	for {set o 0} {$o < 16} {incr o} {
		set d [expr {0xC800 + 16 * $o}]
		if {[peek $d] == 0} { continue }
		set run [peek [expr {$d + 6}]]
		set nent [peek [expr {$d + 7}]]
		set page [expr {0x2000 + 256 * (2 * $o + [peek [expr {$d + 11}]])}]
		for {set i 0} {$i < $nent} {incr i} {
			set e [expr {$page + 8 * $i}]
			set slot [peek [expr {$e + 3}]]
			set pid [expr {[peek [expr {$e + 4}]] + 256 * [peek [expr {$e + 5}]]}]
			set cid [expr {[peek [expr {$e + 6}]] + 256 * [peek [expr {$e + 7}]]}]
			incr ::rp_n
			set po [expr {8192 * ($::rp_base + $::rp_pat + ($pid >> 8)) + 32 * ($pid & 0xFF)}]
			set want [string range $::rp_rom $po [expr {$po + 31}]]
			set have [debug read_block VRAM [expr {0x1D800 + 32 * $slot}] 32]
			if {$want ne $have} {
				incr ::rp_bad
				if {[llength $::rp_log] < 20} { lappend ::rp_log [format "f=%d obj %d entry %d slot %d pattern %04x" [rc2_w 0xD000] $o $i $slot $pid] }
			}
			set c [expr {$cid & 0x7FFF}]
			set co [expr {8192 * ($::rp_base + $::rp_col + ($c >> 9)) + 16 * ($c & 0x1FF)}]
			binary scan [string range $::rp_rom $co [expr {$co + 15}]] cu* cw
			if {$cid & 0x8000} { set cw2 {}; foreach b $cw { lappend cw2 [expr {$b | 0x80}] }; set cw $cw2 }
			binary scan [debug read_block VRAM [expr {[rc2_sprset_col] + 16 * ($run + $i)}] 16] cu* ch
			if {$cw ne $ch} {
				incr ::rp_bad
				if {[llength $::rp_log] < 20} { lappend ::rp_log [format "f=%d obj %d entry %d sat %d colour %04x" [rc2_w 0xD000] $o $i [expr {$run + $i}] $cid] }
			}
		}
	}
	incr ::rp_left -1
	if {$::rp_left <= 0} {
		debug remove_bp $::rp_bp
		set ::pause on
	}
}

# Sprites per line: at the line interrupt of 'n' frames (the play area shown, R#23 still its
# scroll; a match the HUD's R#23 makes after the split, split_armed 0, is not one), the SAT of
# the set on screen (R#5; up to y = 216): a sprite at y covers display lines
# (y + 1 - R#23) & 255 .. + 15; lines 0..vis-1 with more than 8 lose their later sprites (the VDP
# shows 8). ::rx8_frames counts the frames with such a line, ::rx8_log details the first ones.
proc rc2_sprlines {n vis} {
	set ::rx8_left $n
	set ::rx8_vis $vis
	set ::rx8_frames 0
	set ::rx8_log {}
	set ::rx8_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rx8_hit]
	return "counting"
}

proc rc2_rx8_hit {} {
	if {[peek 0xC002] == 0} { return }
	set r23 [debug read {VDP regs} 23]
	binary scan [debug read_block VRAM [expr {[rc2_sprset_col] + 0x200}] 128] cu* sat
	array set cnt {}
	for {set e 0} {$e < 32} {incr e} {
		set y [lindex $sat [expr {4 * $e}]]
		if {$y == 216} { break }
		set top [expr {($y + 1 - $r23) & 255}]
		for {set k 0} {$k < 16} {incr k} {
			set l [expr {($top + $k) & 255}]
			if {$l < $::rx8_vis} {
				if {[info exists cnt($l)]} { incr cnt($l) } else { set cnt($l) 1 }
			}
		}
	}
	set worst 0
	set wl -1
	foreach l [array names cnt] { if {$cnt($l) > $worst} { set worst $cnt($l); set wl $l } }
	if {$worst > 8} {
		incr ::rx8_frames
		if {[llength $::rx8_log] < 12} {
			set objs {}
			for {set o 0} {$o < 16} {incr o} {
				set b [expr {0xCC00 + 32 * $o}]
				set d [expr {0xC800 + 16 * $o}]
				if {[peek $d] == 0} { continue }
				set run [peek [expr {$d + 6}]]
				set n [peek [expr {$d + 7}]]
				set hit 0
				for {set e $run} {$e < $run + $n} {incr e} {
					set y [lindex $sat [expr {4 * $e}]]
					set top [expr {($y + 1 - $r23) & 255}]
					if {(($wl - $top) & 255) < 16} { incr hit }
				}
				if {$hit} {
					lappend objs [format "o%d want %d/%02x shows %d/%02x fl %02x out %d n%d on-line %d" $o \
						[rc2_w [expr {$b + 19}]] [peek [expr {$b + 4}]] [rc2_w [expr {$d + 9}]] [peek [expr {$d + 4}]] \
						[peek $b] [peek [expr {$b + 27}]] $n $hit]
				}
			}
			lappend ::rx8_log "f=[rc2_w 0xD000] line $wl: $worst sprites (mux [peek 0xC0E3]): [join $objs {; }]"
		}
	}
	incr ::rx8_left -1
	if {$::rx8_left <= 0} {
		debug probe remove_bp $::rx8_bp
		set ::pause on
	}
}

# The sprite set on screen (R#5: C7h set A, CFh set B) -> its colour table's VRAM address (the SAT
# is 200h on).
proc rc2_sprset_col {} {
	if {[debug read {VDP regs} 5] & 8} { return 0x1E400 }
	return 0x1E000
}

# Display guard: for 'secs' of emulated time, every VDP access that can spoil the picture, timed
# by scan line from the HUD split (the line interrupt at the end of display line 'split_line';
# 'nl' lines a frame: 262 at 60 Hz, 313 at 50 Hz; the play area is display lines 0..vis-1).
# 'labels' is the build's label file. ::rg_n(kind) counts, ::rg_log details (the first 300):
#   reg  a register write in the play area (but R#14, R#15, R#17: VRAM address, status and
#        command pointers) outside the split, or a split that finds R#2 not a play page (1Fh, 3Fh);
#   pal  a palette write in the play area;
#   cmd  a VDP command started while the beam draws the play area (or in the 4 lines before it)
#        with its destination in what the screen shows (R#2's page, lines (R#23 + 0..vis-1) &
#        255; with the V9958's SP2 the ring's two pages, only the columns shown: rc2_rg_hits), or
#        still running into it once a VBLANK list is in;
#   tear a command into what the screen shows that ran while the beam drew one of its lines
#        (rc2_rg_cend: that picture shows the cell half drawn);
#   cpu  a CPU write (port 98h) into the play pages (0-FFFFh), or into the sprite tables on
#        screen in the play area;
#   vbl  a VBLANK interrupt with no list applied before the next one, a list (its registers and
#        SAT: isr.asm iv_late) applied on a play-area line, a frame of the game without its HUD
#        split (the HUD would not show), the split routine running elsewhere than right after
#        the split's line interrupt (rc2_rg_isr: a late match taken in the blank), or
#        a split at another line than split_line (an early one shows the HUD's page over the
#        play area).
# Pauses when done (::rg_done).
proc rc2_guard {secs split_line nl vis labels} {
	set ::rg_split $split_line
	set ::rg_nl $nl
	set ::rg_vis $vis
	set ::rg_tsplit -1
	set ::rg_latch -1
	set ::rg_r14 0
	set ::rg_addr 0
	set ::rg_r17 0
	set ::rg_ai 1
	set ::rg_cmd {}
	set ::rg_vpend 0
	set ::rg_tv -1
	set ::rg_log {}
	set ::rg_done 0
	set ::rg_frames 0
	set ::rg_cmds 0
	array unset ::rg_n
	foreach k {reg pal cmd cpu vbl tear} { set ::rg_n($k) 0 }
	set ::rg_tc {}
	set ::rg_split0 [rc2_label $labels isr_split]
	set ::rg_split1 [rc2_label $labels isr_vblank]
	set ::rg_wps [list \
		[debug set_watchpoint write_io 0x99 {} rc2_rg_99] \
		[debug set_watchpoint read_io 0x99 {} {set ::rg_latch -1}] \
		[debug set_watchpoint write_io 0x98 {} rc2_rg_98] \
		[debug set_watchpoint write_io 0x9A {} rc2_rg_9a] \
		[debug set_watchpoint write_io 0x9B {} rc2_rg_9b]]
	set ::rg_pbs [list \
		[debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rg_split] \
		[debug probe set_bp VDP.IRQvertical {[debug probe read VDP.IRQvertical] == 1} rc2_rg_virq]]
	if {![info exists ::rg_notear]} {      ;# (set ::rg_notear: no tear counting, a run about 3x faster)
		lappend ::rg_pbs [debug probe set_bp VDP.commandExecuting {[debug probe read VDP.commandExecuting] == 0} rc2_rg_cend]
	}
	set ::rg_bp [debug set_bp [rc2_label $labels iv_late] {} rc2_rg_vbl]   ;# (the list and its SAT in)
	set a [rc2_label $labels isr_split]
	set ::rg_isb [debug set_bp $a "\[peek $a\] == 0xAF" rc2_rg_isr]   ;# (where the split routine really runs)
	after time $secs rc2_rg_end
	return "guarding"
}

proc rc2_rg_line {} {
	if {$::rg_tsplit < 0} { return -1 }
	set dt [expr {[machine_info time] - $::rg_tsplit}]
	return [expr {int($::rg_split + $dt * 3579545.0 / 228.0) % $::rg_nl}]
}

proc rc2_rg_bad {kind msg} {
	incr ::rg_n($kind)
	if {[llength $::rg_log] < 300} { lappend ::rg_log "f=[rc2_w 0xD000] $kind $msg" }
}

proc rc2_rg_99 {} {
	set v $::wp_last_value
	if {$::rg_latch < 0} { set ::rg_latch $v; return }
	set lo $::rg_latch
	set ::rg_latch -1
	if {!($v & 0x80)} {
		set ::rg_addr [expr {($::rg_r14 << 14) | (($v & 0x3F) << 8) | $lo}]
		return
	}
	set r [expr {$v & 0x3F}]
	if {$r == 14} { set ::rg_r14 [expr {$lo & 7}]; return }
	if {$r == 15} { return }
	if {$r == 17} { set ::rg_r17 [expr {$lo & 0x3F}]; set ::rg_ai [expr {!($lo & 0x80)}]; return }
	set pc [reg pc]
	if {$pc >= $::rg_split0 && $pc < $::rg_split1} { return }
	set line [rc2_rg_line]
	if {$line >= 0 && $line < $::rg_vis} {
		rc2_rg_bad reg [format "line %d R#%d = %02x pc %04x" $line $r $lo $pc]
	}
	if {$r == 46} { rc2_rg_cmd $lo }
}

proc rc2_rg_98 {} {
	set a $::rg_addr
	set ::rg_addr [expr {($a + 1) & 0x1FFFF}]
	if {$a < 0x10000} {
		rc2_rg_bad cpu [format "line %d VRAM %05x pc %04x" [rc2_rg_line] $a [reg pc]]
		return
	}
	set c [rc2_sprset_col]
	if {$a >= $c && $a < $c + 0x280} {
		set line [rc2_rg_line]
		if {$line >= 0 && $line < $::rg_vis} {
			rc2_rg_bad cpu [format "line %d sprite table %05x pc %04x" $line $a [reg pc]]
		}
	}
}

proc rc2_rg_9a {} {
	set pc [reg pc]
	if {$pc >= $::rg_split0 && $pc < $::rg_split1} { return }
	set line [rc2_rg_line]
	if {$line >= 0 && $line < $::rg_vis} { rc2_rg_bad pal [format "line %d pc %04x" $line $pc] }
}

proc rc2_rg_9b {} {
	set r $::rg_r17
	if {$::rg_ai} { set ::rg_r17 [expr {($r + 1) & 0x3F}] }
	if {$r == 46} { rc2_rg_cmd $::wp_last_value }
}

# A command (op = R#46) starts with R#32-R#45 in place: its destination lines.
proc rc2_rg_cmd {op} {
	if {($op >> 4) < 8} { return }
	incr ::rg_cmds
	set dx [expr {[debug read "VDP regs" 36] | (([debug read "VDP regs" 37] & 1) << 8)}]
	set dy [expr {[debug read "VDP regs" 38] | (([debug read "VDP regs" 39] & 3) << 8)}]
	set nx [expr {[debug read "VDP regs" 40] | (([debug read "VDP regs" 41] & 1) << 8)}]
	set ny [expr {[debug read "VDP regs" 42] | (([debug read "VDP regs" 43] & 3) << 8)}]
	set arg [debug read "VDP regs" 45]
	if {$ny == 0} { set ny 1024 }
	set ::rg_cmd [list $op $dx $dy $nx $ny $arg]
	set line [rc2_rg_line]
	set shown [rc2_rg_shown]
	set ::rg_tc [expr {[llength $shown] && $line >= 0 ? [list $line $shown] : {}}]
	if {$line >= $::rg_vis && $line < $::rg_nl - 4} { return }
	set hit [rc2_rg_hits]
	if {$hit >= 0} {
		set stk ""
		for {set i 0} {$i < 8} {incr i 2} { append stk [format " %04x" [rc2_w [expr {[reg sp] + $i}]]] }
		rc2_rg_bad cmd [format "line %d op %02x dest (%d,%d) %dx%d arg %02x hits shown line %d pc %04x stack%s" \
			$line $op $dx $dy $nx $ny $arg $hit [reg pc] $stk]
	}
}

# A command that ended: a tear when the beam drew one of the play-area lines it wrote while it ran
# (that line shows the cell half drawn for one picture).
proc rc2_rg_cend {} {
	if {$::rg_tc eq {}} { return }
	lassign $::rg_tc ls shown
	set ::rg_tc {}
	set le [rc2_rg_line]
	foreach y $shown {
		if {($ls <= $le && $y >= $ls && $y <= $le) || ($ls > $le && ($y >= $ls || $y <= $le))} {
			rc2_rg_bad tear [format "beam lines %d-%d over shown line %d of command %s" $ls $le $y $::rg_cmd]
			return
		}
	}
}

# The play-area lines (0..vis-1) the last command's destination shows on (rc2_rg_hits' rules).
proc rc2_rg_shown {} {
	set out {}
	set first [rc2_rg_hits]
	if {$first < 0} { return $out }
	lassign $::rg_cmd op dx dy nx ny arg
	set r23 [debug read "VDP regs" 23]
	set step [expr {($arg & 8) ? -1 : 1}]
	for {set k 0} {$k < $ny} {incr k} {
		set y [expr {((($dy + $step * $k) & 255) - $r23) & 255}]
		if {$y < $::rg_vis} { lappend out $y }
	}
	return $out
}

# The last command's destination against what the screen shows -> the first ring line hit, or -1:
# the lines (R#23 + 0..vis-1) & 255 of R#2's page, with the V9958's SP2 of its pair of pages, the
# 512 px ring, only where the columns the screen shows (248 past the MSK, from R#26/R#27) are.
proc rc2_rg_hits {} {
	lassign $::rg_cmd op dx dy nx ny arg
	set page [expr {([debug read "VDP regs" 2] >> 5) & 3}]
	set r23 [debug read "VDP regs" 23]
	set step [expr {($arg & 8) ? -1 : 1}]
	set sp2 [expr {([debug read "VDP regs" 25] & 1) && ($page & 1)}]
	if {$sp2} {
		set r26 [debug read "VDP regs" 26]
		set x0 [expr {(256 * (($r26 >> 5) & 1) + 8 * ($r26 & 31) + 8 - ([debug read "VDP regs" 27] & 7)) & 511}]
		set xs [expr {($arg & 4) ? -1 : 1}]
		set vis {0 0}
		for {set i 0} {$i < $nx} {incr i} {
			set cx [expr {($dx + $xs * $i) & 255}]
			if {(($cx - $x0) & 511) < 248} { lset vis 0 1 }
			if {(($cx + 256 - $x0) & 511) < 248} { lset vis 1 1 }
		}
	}
	for {set k 0} {$k < $ny} {incr k} {
		set y [expr {($dy + $step * $k) & 1023}]
		if {$sp2} {
			if {($y >> 9) != ($page >> 1) || ![lindex $vis [expr {($y >> 8) & 1}]]} { continue }
		} elseif {($y >> 8) != $page} { continue }
		if {((($y & 255) - $r23) & 255) < $::rg_vis} { return [expr {$y & 255}] }
	}
	return -1
}

# The split routine (isr.asm isr_split) entered: it must run right after the HUD split's line
# interrupt; a late match taken when the VBLANK has re-armed it (in the blank) shows the next
# picture all HUD page.
proc rc2_rg_isr {} {
	if {$::rg_tv < 0} { return }
	set n [expr {int(([machine_info time] - $::rg_tv) * 3579545.0 / 228.0 + 0.5)}]
	set want [expr {$::rg_nl - 212 + $::rg_split}]
	if {$n < $want - 1 || $n > $want + 4} { rc2_rg_bad vbl [format "the split routine ran %d lines after the VBLANK (%d expected)" $n $want] }
}

proc rc2_rg_split {} {
	if {[peek 0xC002] == 0} { return }
	set t [machine_info time]
	if {$::rg_tv >= 0} {
		set n [expr {int(($t - $::rg_tv) * 3579545.0 / 228.0 + 0.5)}]
		set want [expr {$::rg_nl - 212 + $::rg_split}]
		if {abs($n - $want) > 2} { rc2_rg_bad vbl [format "the HUD split came %d lines after the VBLANK (%d expected)" $n $want] }
	}
	set ::rg_tsplit $t
	incr ::rg_frames
	set r2 [debug read "VDP regs" 2]
	if {$r2 != 0x1F && $r2 != 0x3F} { rc2_rg_bad reg [format "split finds R#2 = %02x" $r2] }
}

proc rc2_rg_virq {} {
	set ::rg_tv [machine_info time]
	if {$::rg_vpend} { rc2_rg_bad vbl [format "line %d: VBLANK with the last one's list not applied" [rc2_rg_line]] }
	if {[peek 0xC002] && [peek 0xEC44] == 0 && $::rg_tsplit >= 0} { rc2_rg_bad vbl "a frame without its HUD split" }
	set ::rg_vpend 1
}

proc rc2_rg_vbl {} {
	set ::rg_vpend 0
	set line [rc2_rg_line]
	if {$line >= 0 && $line < $::rg_vis} { rc2_rg_bad vbl [format "list applied on line %d" $line] }
	if {$::rg_cmd ne {} && $line >= $::rg_vis && ([debug read "VDP status regs" 2] & 1)} {
		set hit [rc2_rg_hits]
		if {$hit >= 0} {
			set ::rg_runcmd $::rg_cmd
			after time [expr {($::rg_nl - $line) * 228.0 / 3579545.0}] [list rc2_rg_run $line $hit]
		}
	}
}

# A command that was running into what the new list shows when it went in: flagged only when it
# still runs as the picture starts (line 0).
proc rc2_rg_run {line hit} {
	if {$::rg_cmd eq $::rg_runcmd && ([debug read "VDP status regs" 2] & 1)} {
		rc2_rg_bad cmd [format "line %d command %s still running into shown line %d as the picture starts" $line $::rg_cmd $hit]
	}
}

proc rc2_rg_end {} {
	foreach w $::rg_wps { debug remove_watchpoint $w }
	foreach p $::rg_pbs { debug probe remove_bp $p }
	debug remove_bp $::rg_bp
	debug remove_bp $::rg_isb
	set ::rg_done 1
	set ::pause on
}

# Keyboard script: 'events' is a list of {secs row mask down} (down 1 presses, 0 releases), the
# times in emulated seconds from now.
proc rc2_keys {events} {
	foreach e $events {
		lassign $e t row mask down
		if {$down} {
			after time $t [list keymatrixdown $row $mask]
		} else {
			after time $t [list keymatrixup $row $mask]
		}
	}
	return "[llength $events] key events"
}

# Lines above 8 sprites, every one: like rc2_sprlines for 'n' frames, but each frame with such a
# line goes to 'file' as "frame line count | object kind/id want-drop shows-id/shows-drop tier
# on-line ..." (obj_tab: the wanted composition and drops; disp: what the SAT shows), for
# tools-side statistics. Pauses when done (::ro_done).
proc rc2_overlines {n vis file} {
	set ::ro_left $n
	set ::ro_vis $vis
	set ::ro_out [open $file w]
	set ::ro_done 0
	set ::ro_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_ro_hit]
	return "logging"
}

proc rc2_ro_hit {} {
	if {[peek 0xC002] == 0} { return }
	set r23 [debug read {VDP regs} 23]
	binary scan [debug read_block VRAM [expr {[rc2_sprset_col] + 0x200}] 128] cu* sat
	array set cnt {}
	for {set e 0} {$e < 32} {incr e} {
		set y [lindex $sat [expr {4 * $e}]]
		if {$y == 216} { break }
		set top [expr {($y + 1 - $r23) & 255}]
		for {set k 0} {$k < 16} {incr k} {
			set l [expr {($top + $k) & 255}]
			if {$l < $::ro_vis} {
				if {[info exists cnt($l)]} { incr cnt($l) } else { set cnt($l) 1 }
			}
		}
	}
	set worst 0
	set wl -1
	foreach l [array names cnt] { if {$cnt($l) > $worst} { set worst $cnt($l); set wl $l } }
	if {$worst > 8} {
		set objs {}
		for {set o 0} {$o < 16} {incr o} {
			set b [expr {0xCC00 + 32 * $o}]
			set d [expr {0xC800 + 16 * $o}]
			if {[peek $d] == 0} { continue }
			set run [peek [expr {$d + 6}]]
			set nn [peek [expr {$d + 7}]]
			set hit 0
			for {set e $run} {$e < $run + $nn} {incr e} {
				set y [lindex $sat [expr {4 * $e}]]
				set top [expr {($y + 1 - $r23) & 255}]
				if {(($wl - $top) & 255) < 16} { incr hit }
			}
			if {$hit} {
				lappend objs [format "o%d %d/%d %02x %d/%02x t%d %d" $o [peek [expr {$b + 18}]] [rc2_w [expr {$b + 19}]] \
					[peek [expr {$b + 4}]] [rc2_w [expr {$d + 9}]] [peek [expr {$d + 4}]] [peek [expr {$b + 25}]] $hit]
			}
		}
		puts $::ro_out "[rc2_w 0xD000] $wl $worst | [join $objs { | }]"
	}
	incr ::ro_left -1
	if {$::ro_left <= 0} {
		debug probe remove_bp $::ro_bp
		close $::ro_out
		set ::ro_done 1
		set ::pause on
	}
}

# The view against the camera: at every HUD split for 'n' frames, the distance between the view
# shown (cam_x, cam_y) and the one the game wants (v_x, v_y), and RoboCop's screen x (object 0's
# O_X); ::rvl holds "max_dx max_dy frames_dx>=32 min_x max_x", ::rvl_h(x / 16) and ::rvl_v((y +
# lines) / 16) count the frames per 16 px of his left edge and of his composition's end.
proc rc2_viewlag {n} {
	array unset ::rvl_h
	array unset ::rvl_v
	set ::rvl_left $n
	set ::rvl [list 0 0 0 9999 -9999]
	set ::rvl_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rvl_hit]
	return "watching"
}

proc rc2_rvl_s {v} { expr {$v >= 32768 ? $v - 65536 : $v} }

proc rc2_rvl_hit {} {
	if {[peek 0xC002] == 0} { return }
	lassign $::rvl mdx mdy nbig mnx mxx
	set dx [expr {abs([rc2_w 0xCE6A] - [rc2_w 0xC020])}]
	set dy [expr {abs([rc2_w 0xCE6C] - [rc2_w 0xC022])}]
	if {$dx > $mdx} { set mdx $dx }
	if {$dy > $mdy} { set mdy $dy }
	if {$dx >= 32} { incr nbig }
	if {[peek 0xCC00] & 0x80} {
		set x [rc2_rvl_s [rc2_w 0xCC06]]
		if {$x < $mnx} { set mnx $x }
		if {$x > $mxx} { set mxx $x }
		set b [expr {$x >> 4}]
		if {[info exists ::rvl_h($b)]} { incr ::rvl_h($b) } else { set ::rvl_h($b) 1 }
		set yb [expr {([rc2_rvl_s [rc2_w 0xCC08]] + [peek 0xCC0B]) >> 4}]
		if {[info exists ::rvl_v($yb)]} { incr ::rvl_v($yb) } else { set ::rvl_v($yb) 1 }
	}
	set ::rvl [list $mdx $mdy $nbig $mnx $mxx]
	incr ::rvl_left -1
	if {$::rvl_left <= 0} { debug probe remove_bp $::rvl_bp }
}

# RoboCop near the screen's right edge: at every HUD split for 'n' frames, when his object's x
# (O_X) is 'xmin' or more, records (game frame, O_X, min/max dx, p_x, p_hotx, v_x, cam_x,
# gcam_x, cam_held) into ::rre (first 30).
proc rc2_rcedge {n xmin} {
	set ::rre_left $n
	set ::rre_min $xmin
	set ::rre {}
	set ::rre_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rre_hit]
	return "watching"
}

proc rc2_rre_hit {} {
	if {[peek 0xC002] == 0} { return }
	incr ::rre_left -1
	if {$::rre_left <= 0} { debug probe remove_bp $::rre_bp }
	if {!([peek 0xCC00] & 0x80)} { return }
	set x [rc2_rvl_s [rc2_w 0xCC06]]
	if {$x < $::rre_min || [llength $::rre] >= 30} { return }
	set mn [peek 0xCC0D]; if {$mn >= 128} { incr mn -256 }
	set mx [peek 0xCC0E]; if {$mx >= 128} { incr mx -256 }
	lappend ::rre [list f=[rc2_w 0xD000] ox=$x dx=$mn..$mx px=[rc2_w 0xDAD0] hot=[rc2_rvl_s [rc2_w 0xDACC]] vx=[rc2_w 0xCE6A] camx=[rc2_w 0xC020] gcam=[rc2_w 0xD004] held=[peek 0xF16F]]
}

# Sprites against the background: at every register list's end (list_tail: the camera it
# publishes), RoboCop's screen place (object 0's O_X, O_Y) must be his world place against that
# camera, as pl_show takes it (p_x + p_hotx + SPR_X_OFS + 8 - cam_x, p_y + p_hoty + SPR_Y_OFS -
# cam_y); a frame without a tick that moved the camera without moving the objects shows every
# sprite off the background by the camera's step. For 'n' lists; ::rcc_n lists checked,
# ::rcc_bad the ones off, ::rcc_log the first 30.
proc rc2_camcheck {n labels} {
	set ::rcc_left $n
	set ::rcc_n 0
	set ::rcc_bad 0
	set ::rcc_log {}
	set ::rcc_xo [expr {[rc2_label $labels SPR_X_OFS] - 0x100000000 + 8}]
	set ::rcc_yo [expr {[rc2_label $labels SPR_Y_OFS] - 0x100000000}]
	set a [rc2_label $labels list_tail]
	set ::rcc_bp [debug set_bp $a "\[peek $a\] == 0xED && \[peek [expr {$a + 1}]\] == 0x5B" rc2_rcc_hit]
	return "checking"
}

proc rc2_rcc_hit {} {
	if {[incr ::rcc_left -1] <= 0} { debug remove_bp $::rcc_bp }
	if {!([peek 0xCC00] & 0x80)} { return }
	incr ::rcc_n
	set cx [rc2_w 0xC020]
	set cy [rc2_w 0xC022]
	set wx [expr {[rc2_w 0xDAD0] + [rc2_rvl_s [rc2_w 0xDACC]] + $::rcc_xo - $cx}]
	set wy [expr {[rc2_w 0xDAD4] + [rc2_rvl_s [rc2_w 0xDACE]] + $::rcc_yo - $cy}]
	set ox [rc2_rvl_s [rc2_w 0xCC06]]
	set oy [rc2_rvl_s [rc2_w 0xCC08]]
	if {$ox != $wx || $oy != $wy} {
		incr ::rcc_bad
		if {[llength $::rcc_log] < 30} {
			lappend ::rcc_log [list f=[rc2_w 0xD000] obj=$ox,$oy want=$wx,$wy cam=$cx,$cy v=[rc2_w 0xCE6A],[rc2_w 0xCE6C] tick=[peek 0xCE05]]
		}
	}
}

# Frames after jumps: when RoboCop leaves the ground (p_air at DAE7h becomes non-zero), the next
# 'n' pictures are recorded at their HUD split (the play area's registers and VRAM as the beam
# drew it) into dir/jJJJ_fFFFF.bin: R#0-R#63, the palette (32 bytes), the page shown (R#2) as
# 32 KiB (with the V9958's SP2 its pair of pages, 64 KiB), VRAM 1D800h-1FFFFh (sprite tables,
# HUD), RAM C000h-CFFFh, page-0 RAM 0A00h-0FFFh (the map patches); at most 'jumps' jumps.
# tools/recframes.py renders and checks them.
proc rc2_jumprec {dir n jumps} {
	file mkdir $dir
	set ::rj_dir $dir
	set ::rj_n $n
	set ::rj_jumps $jumps
	set ::rj_j 0
	set ::rj_f 0
	set ::rj_left 0
	set ::rj_air 0
	set ::rj_done 0
	set ::rj_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rj_hit]
	return "recording"
}

proc rc2_rj_hit {} {
	if {[peek 0xC002] == 0} { return }
	set air [peek 0xDAE7]
	if {$::rj_left == 0 && $air != 0 && $::rj_air == 0 && $::rj_j < $::rj_jumps} {
		incr ::rj_j
		set ::rj_left $::rj_n
		set ::rj_f 0
	}
	set ::rj_air $air
	if {$::rj_left == 0} { return }
	set regs ""
	for {set i 0} {$i < 64} {incr i} { append regs [binary format cu [debug read "VDP regs" $i]] }
	set page [expr {([debug read "VDP regs" 2] >> 5) & 3}]
	set f [open [file join $::rj_dir [format j%03d_f%04d.bin $::rj_j $::rj_f]] wb]
	fconfigure $f -translation binary
	puts -nonewline $f $regs
	puts -nonewline $f [debug read_block "VDP palette" 0 32]
	if {([debug read "VDP regs" 25] & 1) && ($page & 1)} {
		puts -nonewline $f [debug read_block VRAM [expr {($page & 2) * 0x8000}] 0x10000]
	} else {
		puts -nonewline $f [debug read_block VRAM [expr {$page * 0x8000}] 0x8000]
	}
	puts -nonewline $f [debug read_block VRAM 0x1D800 0x2800]
	puts -nonewline $f [debug read_block memory 0xC000 0x1000]
	puts -nonewline $f [debug read_block memory 0x0A00 0x600]
	close $f
	incr ::rj_f
	incr ::rj_left -1
	if {$::rj_left == 0 && $::rj_j >= $::rj_jumps} {
		debug probe remove_bp $::rj_bp
		set ::rj_done 1
	}
}

# Every picture: the next 'n' pictures recorded as rc2_jumprec does (one "jump" 0, files
# j000_fFFFF.bin), from now on; for a stretch of a replay (rc2_replay).
proc rc2_framerec {dir n} {
	file mkdir $dir
	set ::rj_dir $dir
	set ::rj_jumps 0
	set ::rj_j 0
	set ::rj_f 0
	set ::rj_left $n
	set ::rj_air 1
	set ::rj_done 0
	set ::rj_bp [debug probe set_bp VDP.IRQhorizontal {[debug probe read VDP.IRQhorizontal] == 1} rc2_rj_hit]
	return "recording"
}

# A replay the user saved (openMSX console: reverse savereplay NAME, file in
# ~/.openMSX/replays/NAME.omr): loaded, taken to 'secs' before its end, then its last pictures
# recorded into 'dir' (rc2_framerec, tools/recframes.py) with the display guard on; pauses at
# the end ('labels': the ROM's label file).
proc rc2_replay {file secs dir labels} {
	reverse loadreplay $file
	set end [dict get [reverse status] end]
	set t0 [expr {$end - $secs}]
	if {$t0 < 0} { set t0 0 }
	reverse goto $t0
	rc2_framerec $dir [expr {int($secs * 60) + 30}]
	rc2_guard $secs 159 262 163 $labels
	return "replaying from $t0 to $end"
}
