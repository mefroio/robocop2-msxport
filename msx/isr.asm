; Interrupts: IM 2 through a 257-byte vector table (any data-bus value leads to IM2_JUMP),
; the line interrupt for the HUD split and VBLANK for the per-frame registers.
;
; Rules for the main program:
; - every port 99h sequence (register write, VRAM address, status read) runs with
;   interrupts disabled, and R#15 is 0 whenever interrupts are enabled;
; - the registers of the next frame are published as a list [seq, len, value, reg|80h, ...,
;   cam_x, cam_y, game frame] (the tail is not sent to the VDP; with the list's pub_spr copy it
;   records what the list shows, for verification)
;   (publish) together with the sprite engine's uploads for it (sprites.asm: pq, run by
;   spr_upload in the split interrupt); the VBLANK after they ran puts the list on screen
;   (vbl_ptr: applied at every VBLANK, seq copied to app_seq) with its SAT;
; - both interrupts write VRAM, so every VRAM stream of the main program sets vram_busy before
;   its address and ends with vram_done (which writes a SAT the interrupt left meanwhile); the
;   uploads then wait for the next frame.
;
; Split timing (openMSX VDP model): the line interrupt fires at the right border of display
; line (R#19 - R#23) & 255, where S#1 FH goes up too; R#1 (blank), R#8 (sprites) and R#18
; take effect at the start of the next line (144 VDP ticks after its sync), while R#2, R#23,
; R#26, R#27 and the palette take effect immediately. HR (S#2 bit 5) is 1 for 312 VDP ticks
; from the right border, computed with the current horizontal adjust (so writing R#18 moves
; the window); with R#18 = 0 it goes down 226 ticks into the next line, past its latch point.
; The One Chip MSX's VDP (ESE-VDP, OCM-PLD: the SX-2) matches R#19 the same way (live, against
; the line + R#23, at the line's last pixel), but its HR is 1 from the end of the line to 17
; ticks into the next one's pixels (236 ticks, R#18 does not move it): 125 ticks later than
; openMSX's. Only an edge of FH tells the lines apart on both.

isr:    push af
        push bc
        push hl
        ld c,VDP_CTRL
        ld a,1
        out (c),a
        ld a,0x8F
        out (c),a
        in b,(c)                    ; S#1: bit 0 = FH (the read acknowledges it)
        bit 0,b
        jr z,isr_r15
        ld a,(split_armed)
        or a
        call nz,isr_split           ; (R#15 still 1: the split polls S#1 first)
isr_r15:
        xor a
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        in a,(c)                    ; S#0: bit 7 = VBLANK (the read acknowledges it)
        or a
        call m,isr_vblank
        pop hl
        pop bc
        pop af
        ei
        reti

; HUD split (V = VIEW_LINES): the interrupt fires at the end of line V-5. The routine goes by the
; line match (S#1 FH, R#19 against the line + R#23 at the line's last pixel: the same on the
; V9938, the V9958 and the One Chip MSX's ESE-VDP) and delays worked out on this machine
; (split_cal), never by S#2 HR, whose window differs between those chips (2026-10-23: the
; user's SX-2 flickered at the play field's end). With R#19 at the play field's R#23 + V - 2
; (split_r19) it polls FH for the end of line V-2, sets R#19 for the end of line V-1, waits
; split_dly and blanks the display and the sprites: written in the middle of line V-1 (~970 VDP
; ticks after the match), the blank is past line V-1's latch of R#1 (the next line's sync + 144
; ticks in openMSX's V9938, the dot before the next line's first pixel on the ESE-VDP: 230 and
; 344 ticks after the match) and before line V's (1368 later): display off from line V, sprites
; off there. At FH of line V-1 (its pixels drawn: nothing visible changes any more) the page, the
; scroll and the HUD's colours 1-15 go in during the blank lines V..V+4 (sp_regs: 36-38 port
; accesses, 4.0 lines on the T9769 engines, whose VDP ports take cycles more, 3.3 on a plain
; Z80), then split_dly2 and the display on: ~970 ticks after the end of line V+3 whatever the CPU
; and its I/O waits (split_cal times sp_regs itself), so the HUD shows from line V+5. The blank
; lines are five (HUD_BLACK): four held the registers and the palette only with the display-on
; just before the HUD's first line (0.1.0's split landed a line late on the FS-A1FX), and the
; design of that morning wrote 10 colours while the HUD showed. Colour 0 is not written: the
; HUD's is the play field's (tools/mkrom.py checks). On the V9958 the border mask is turned off
; (the HUD's left columns are still black there) so that the HUD uses all 256 px. R#19 then
; goes behind (SPLIT_R19) and S#1 is read: the line interrupt stays enabled, a match the play
; field's R#19 makes against the HUD's R#23 is acknowledged and ignored (isr: split_armed 0).
; A split serviced past line V-2 (never seen: the main program's longest DI is ~50 T) finds its
; first match behind (sp_fh: SPLIT_POLLS) and writes everything at once: the HUD a few lines
; late that frame.
isr_split:
        ld a,(split_r19)
        ld l,a                      ; (HL is saved by the ISR)
        out (c),a
        ld a,0x93
        out (c),a                   ; R#19: a match at the end of line V-2
        xor a
        ld (split_armed),a
        call sp_fh                  ; FH of line V-2
        jr nc,sp_late
        ld a,l
        inc a
        out (c),a
        ld a,0x93
        out (c),a                   ; R#19: the end of line V-1 (the write clears FH on the ESE-VDP)
        ld a,(split_dly)
        or a
        call nz,sp_wait
        ld a,R1_BLANK
        out (c),a
        ld a,0x81
        out (c),a                   ; display off from line V
        ld a,R8_SPR_OFF
        out (c),a
        ld a,0x88
        out (c),a                   ; sprites off from line V
        call sp_fh                  ; FH of line V-1
        ld hl,split_list+1
        call sp_regs                ; the HUD's page, scroll and palette (lines V..V+4 are blank)
        ld a,(split_dly2)
        or a
        call nz,sp_wait
sp_on:  ld a,R1_ON
        out (c),a
        ld a,0x81
        out (c),a                   ; display on from line V+5: the HUD
        ld a,(hud_msk)
        or a
        jr z,sp_r19
        ld a,R25_HUD
        out (c),a
        ld a,0x99
        out (c),a                   ; V9958: no border mask in the HUD
sp_r19: ld a,SPLIT_R19
        out (c),a
        ld a,0x93
        out (c),a                   ; R#19 against the HUD's R#23: its match (line V-5) is behind
        in a,(c)                    ; (S#1: a match that came meanwhile is acknowledged)
        xor a
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        call isr_fbgo               ; a play-field copy waiting: it starts as the beam leaves
        jp spr_upload               ; sprites off until the next frame: their uploads
sp_late:
        ld a,R1_BLANK               ; (serviced too late for its matches: everything at once)
        out (c),a
        ld a,0x81
        out (c),a
        ld a,R8_SPR_OFF
        out (c),a
        ld a,0x88
        out (c),a
        ld hl,split_list+1
        call sp_regs
        jr sp_on

; Polls S#1 (R#15 = 1) for FH, the match R#19 was set for, SPLIT_POLLS times at most (the read
; acknowledges it) -> C when it came, NC when the bound ran out (its match was behind). Keeps C.
sp_fh:  ld b,SPLIT_POLLS
spf_lp: in a,(c)
        rrca
        ret c
        djnz spf_lp
        ret

; A (not 0) iterations of the split's timing loop (sp_wait: a poll of S#1 whose test never
; passes, bit 7 is the light pen's; split_cal counts the same loop): 40 T-states and a port
; read each.
sp_wait:
        ld b,a
spw_lp: in a,(c)
        rlca
        jr c,spw_x                  ; (never)
        djnz spw_lp
spw_x:  ret

; The HUD's registers (HL = the pairs of split_list: R#2 = page 3, V9938: R#18 = 0, R#23 =
; HUD_R23, V9958: R#26/R#27 = page 3 unscrolled; split_init) and the palette at sp_palp
; (hud_palette = gen/hud_split.pal: colours 1-15) with unrolled OUTIs. Keeps C = VDP_CTRL.
; (split_cal runs it on a list of R#16 writes and the play field's palette: the same timing.)
sp_regs:
        outi
        outi
        outi
        outi
        outi
        outi
        ld a,(split_list)
        cp 6
        jr z,sp_pal
        outi
        outi
sp_pal: ld a,1
        out (c),a
        ld a,0x90
        out (c),a                   ; R#16 = colour 1
        ld hl,(sp_palp)
        ld c,VDP_PAL
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        ld c,VDP_CTRL
        ret

; The split's delays for this machine (split_dly, split_dly2: iterations of sp_wait's loop),
; worked out with the display off (display_on, every level start; interrupts off meanwhile,
; the VDP's are off: display_on turns them on after; leaves R#15 = 0). R#23 = 0 meanwhile (the
; VBLANK's list sets the play field's again). The loop's iterations N between the FH of line
; CAL_LINE and that of line CAL_LINE + 32 (174 at 3.58 MHz; the loop is a port read and 40
; T-states: I/O waits count as they do in the split's own polls and writes), then, four times
; from a match: sp_regs on cal_list (R#16 writes) and the play field's palette, R#23 = 0 and
; R#19 for 8 lines on, and the iterations left until that match (M, their mean: a poll's
; worth of jitter in each). The blank must land ~0.71 line (970 ticks) after its match:
; split_dly = 0.71 N / 32 - the routine's own time between the match and the write (~116
; T-states and 4 port accesses, ~3 iterations) - the poll's half = N / 45 - 3, 0 below. The
; display-on lands ~0.71 line after the end of line V+3, 4.71 lines after the match of line
; V-1 from which the writes run: split_dly2 = 4.71 N / 32 - (8 N / 32 - M - the 4 accesses
; after sp_regs here) - the 2 before the display-on there = M - 27 N / 256 + SPLIT_K, 0 below.
; Any match missing (no VDP): the 3.58 MHz values.
CAL_LINE:   equ 40
SPLIT_K:    equ 4                   ; (the accesses' difference and the polls' halves, in iterations: measured)
split_cal:
        di
        ld c,VDP_CTRL
        xor a
        out (c),a
        ld a,0x97
        out (c),a                   ; R#23 = 0
        ld a,1
        out (c),a
        ld a,0x8F
        out (c),a                   ; S#1
        in a,(c)                    ; (an FH pending: acknowledged)
        ld a,CAL_LINE
        call sc_r19
        call sc_count               ; (the first match)
        jp nc,sc_dflt
        ld a,CAL_LINE + 32
        call sc_r19
        call sc_count               ; N: the iterations of 32 lines
        jp nc,sc_dflt
        push hl
        ld hl,pf_pal + 2
        ld (sp_palp),hl             ; (the play field's colours 1-15: what the VBLANK writes)
        ld de,0                     ; the sum of the four M
        ld a,CAL_LINE + 40
sc_lp:  push de
        push af
        ld hl,cal_list
        call sp_regs                ; (from the match just seen)
        xor a
        out (c),a
        ld a,0x97
        out (c),a                   ; R#23 = 0 (cal_list leaves it; the HUD's list would not)
        pop af
        push af
        call sc_r19                 ; R#19: 8 lines on
        call sc_count               ; M: the iterations left of the 8 lines
        pop af
        pop de
        jr nc,sc_none               ; (its match missed: the slowest machine's value)
        add hl,de
        ex de,hl
        add a,8
        cp CAL_LINE + 40 + 4*8
        jr nz,sc_lp
        srl d
        rr e
        srl d
        rr e                        ; DE = the mean M
sc_none:
        ld hl,hud_palette
        ld (sp_palp),hl
        pop hl                      ; HL = N (DE = M, 0 when a match was missed)
        push de
        ld d,h
        ld e,l
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l                        ; N / 8
        push hl
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l                        ; N / 64
        ld a,l                      ; (N below 8192: one byte)
        srl l                       ; N / 128
        add a,l                     ; N / 64 + N / 128 = N / 45 (within 1)
        sub 3
        jr nc,sc_db
        xor a
sc_db:  ld (split_dly),a            ; split_dly = N / 45 - 3
        pop hl                      ; N / 8 (one byte: N below 2048)
        ld d,h
        ld e,l
        add hl,hl
        add hl,de
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,de
        add hl,de
        add hl,de                   ; 27 N / 8
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l                        ; 27 N / 256 = 0.1055 N (N / 8 - N / 48 = 0.1042 N)
        ld b,l
        pop hl                      ; M
        ld a,h
        or a
        ld a,255
        jr nz,sc_dp                 ; (M >= 256: a very fast CPU, 255 at most)
        ld a,l
        add a,SPLIT_K
        sub b
        jr nc,sc_dp
        xor a
sc_dp:  ld (split_dly2),a           ; split_dly2 = M + SPLIT_K - 27 N / 256
        jr sc_end
sc_dflt:
        xor a
        ld (split_dly),a            ; (a T9769 at 3.58 MHz: N 165, M 13)
        ld a,1
        ld (split_dly2),a
sc_end: xor a
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        ei
        ret

; A = a line: R#19 = it (R#23 is 0). Keeps C.
sc_r19: out (c),a
        ld a,0x93
        out (c),a
        ret

; Polls S#1 for FH with sp_wait's loop, 8192 times at most -> C and HL = the iterations until it
; came, NC when it did not (8192). Keeps C.
sc_count:
        ld b,0
        ld h,0
scc_lp: in a,(c)
        rrca
        jr c,scc_x
        djnz scc_lp
        inc h
        ld a,h
        cp 0x20
        jr nz,scc_lp
        ld l,0                      ; (8192: NC)
        ret
scc_x:  xor a
        sub b
        ld l,a                      ; HL = 256 * H + (256 - B) & 255
        scf
        ret

; A play-field copy for the page shown waiting (field.asm fb_cq 1 or 3), its picture published
; (its stamp not fb_tick) with its sprites uploaded (pk_state not 1: both go on screen at the
; same VBLANK), the VDP idle and the main program not giving it a command (cmd_lock): it starts
; now (fb_cq 2 or 4). No copy waiting: a command of theirs for page 3 (ifg_rdy). C = VDP_CTRL
; (kept), AF, B, HL.
isr_fbgo:
        ld a,(fb_cq)
        rra
        jr nc,ifg_rdy
        ld a,(pk_state)
        dec a
        ret z
        ld a,(cmd_lock)
        or a
        ret nz
        ld a,(fb_tick)
        ld hl,fb_cur + 11
        cp (hl)
        ret z
        call ifg_idle
        ret nz                      ; (a command runs)
        ld hl,fb_cmd
        call ifg_send
        ld hl,fb_cq
        inc (hl)                    ; (2, 4: started)
        ld a,(fb_c2)                ; the pair's second part (fb_cmd2) right after it, so that
        dec a                       ; both show from the same frame
        ret nz
        ld b,110                    ; (about 3 ms at most: else fb_wait starts it)
ifg_wt: call ifg_idle
        jr z,ifg_2
        djnz ifg_wt
        ret
ifg_2:  ld hl,fb_cmd2
        call ifg_send
        ld a,2
        ld (fb_c2),a
        ret

; A command of the play-field BOBs for page 3 ready (field.asm fb_rdy 1: the scratch, the caches,
; off the screen, so any time), the VDP idle and the main program not writing a command
; (cmd_lock): it starts now (fb_rdy 2). C = VDP_CTRL (kept), AF, HL.
ifg_rdy:
        ld a,(fb_rdy)
        dec a
        ret nz
        ld a,(cmd_lock)
        or a
        ret nz
        call ifg_idle
        ret nz
        ld hl,fb_cmd
        call ifg_send
        ld a,2
        ld (fb_rdy),a
        ret

; -> Z when the VDP's command engine is idle (S#2 CE). Keeps BC, HL.
ifg_idle:
        ld a,2
        out (c),a
        ld a,0x8F
        out (c),a
        in a,(c)                    ; S#2
        push af
        xor a
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        pop af
        and 1
        ret

; HL = 15 bytes -> R#32-R#46 (the command starts). Keeps BC.
ifg_send:
        push bc
        ld a,32
        out (c),a
        ld a,0x80 + 17
        out (c),a                   ; R#17 = 32
        ld bc,15*256 + VDP_IND
        otir
        pop bc
        ret

; VBLANK: registers of the frame being shown next, the play-field palette (pf_pal) and, when
; the list is a new one, the SAT built for it (it must be in VRAM before the first display
; line: written by the main program it often came in the middle of the picture); in the front
; end (front_mode) only the frame count and the sound.
isr_vblank:
        ld a,(front_mode)
        or a
        jp nz,iv_tick
        ld a,(fb_vok)               ; (a play-field copy that keeps ahead of the beam from here,
        or a                        ;  else a command of theirs for page 3: isr_fbgo, ifg_rdy)
        jr z,iv_fbr
        call isr_fbgo
        jr iv_pk
iv_fbr: call ifg_rdy
iv_pk:  ld a,(pk_state)
        cp 1
        jr nz,iv_rdy
        ld a,(split_armed)          ; (no split since the last VBLANK: the display or the line
        or a                        ; interrupt is off) the published frame's uploads now
        call nz,spr_upload
        ld a,(pk_state)
iv_rdy: cp 2
        jr nz,iv_list
        call fb_pend                ; (its play-field BOBs not all composed yet: it waits for them,
        jr z,iv_take                ; FB_HOLD VBLANKs at most, so that they change with the sprites)
        ld hl,fb_hold
        inc (hl)
        ld a,(hl)
        cp FB_HOLD
        jr c,iv_list
iv_take:
        if EXTJOY
        ld hl,fb_visrec             ; (test builds: what the pictures are checked against)
        call field_call
        ld c,VDP_CTRL
        endif
        xor a
        ld (fb_hold),a
        ld (pk_state),a
        ld hl,(pk_list)
        ld (vbl_ptr),hl             ; the published frame from this one on
iv_list:
        ld c,VDP_CTRL               ; (fb_pend changes it)
        ld hl,(vbl_ptr)
        ld a,(app_seq)
        cp (hl)
        ld a,(hl)
        ld (app_seq),a
        push af                     ; (NZ: a new list)
        inc hl
        ld b,(hl)
        inc hl
        ld a,(hl)                   ; (every list starts with R#23, the play field's scroll)
        add a,VIEW_LINES - 2
        ld (split_r19),a            ; the split's R#19: a match at the end of line V-2
        otir
        ld a,1
        out (c),a
        ld a,0x90
        out (c),a                   ; R#16 = colour 1
        ld hl,pf_pal+2
        ld bc,30*256 + VDP_PAL
        otir
        ld a,1
        ld (split_armed),a
        pop af
        call nz,iv_sat              ; (sprites.asm: a new list, its sprite set from now on)
iv_late:
        call spr_late               ; more of the sprites' background uploads
iv_tick:
        ld hl,tick
        inc (hl)
        jp snd_frame                ; the music and the sound effects (AF, BC, HL saved; it keeps
                                    ; DE, IX, IY and the alternate registers)

; Builds split_list for the engine in use: A = 2 for the V9958 engine, else the V9938 one.
split_init:
        ld (hud_msk),a              ; 2 (non-zero) = V9958 engine: mask off in the HUD
        ld hl,split_list+1
        ld (hl),R2_PAGE3
        inc hl
        ld (hl),0x82
        inc hl
        or a
        jr nz,si_r23
        ld (hl),a                   ; V9938: R#18 = 0 (the V9958 engine keeps R#18 at 0)
        inc hl
        ld (hl),0x92
        inc hl
si_r23: ld (hl),HUD_R23
        inc hl
        ld (hl),0x97                ; R#23: HUD_VRAM_LINE shown at display line V+5
        inc hl
        ld b,6
        ld a,(hud_msk)
        or a
        jr z,si_len
        ld (hl),R26_PAGE3
        inc hl
        ld (hl),0x9A                ; R#26: page 3, no horizontal scroll
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0x9B                ; R#27 = 0
        ld b,8
si_len: ld a,b
        ld (split_list),a
        ld hl,cal_list              ; (split_cal's list: as many pairs, R#16 = 1 each)
        srl b
si_cal: ld (hl),1
        inc hl
        ld (hl),0x90
        inc hl
        djnz si_cal
        ld hl,hud_palette
        ld (sp_palp),hl
        ret

; Publishes the register list at HL (filled by the engine) for the next VBLANK.
; The list starts with [seq, len]; seq is set here.
publish:
        ld a,(pub_seq)
        inc a
        ld (pub_seq),a
        ld (hl),a
        ld (pk_list),hl
        push hl
        ld hl,pq_buf
        ld (pq_rd),hl               ; (its queue from the start)
        pop hl
        ld a,(pq_buf)               ; no uploads for it: ready at once
        or a
        ld a,1
        jr nz,pb_st
        inc a
pb_st:  ld (pk_state),a             ; (last: the interrupts see a complete frame)
        ret

; Ends a register list being filled (HL past its last pair, the list's address on the stack):
; appends the camera, the game frame ($B00: the tick shown is the one before) and the sprite
; state it shows (not sent to the VDP; for verification) and publishes it.
list_tail:
        ld de,(cam_x)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld de,(cam_y)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld de,(g_frame)
        ld (hl),e
        inc hl
        ld (hl),d
        pop hl                      ; the list: what its SAT shows goes to its pub_spr copy
        if EXTJOY                   ; (test builds)
        push hl
        ld de,pub_spr
        ld a,l
        cp vbl_list_a & 0xFF
        jr z,lt_a
        ld de,pub_spr + MAX_OBJ*8
lt_a:   ld hl,pub_cur
        ld bc,MAX_OBJ*8
        ldir
        pop hl
        endif
        jp publish

; Returns HL = the list not in use by the ISR.
next_list:
        ld hl,(vbl_ptr)
        ld a,l
        cp vbl_list_a & 0xFF
        ld hl,vbl_list_a
        ret nz
        ld hl,vbl_list_b
        ret

; Waits until a VBLANK has put the last published list on screen (so the next frame never
; starts on top of one that is still pending), calling idle_work meanwhile; counts frames and
; late frames (more than one VBLANK since the previous call).
wait_frame:
        if LOCKSTEP
        ld a,(last_tick)            ; (test builds: every frame starts LOCKSTEP VBLANKs after the
        add a,LOCKSTEP              ; one before; lk_over counts those that came later)
        ld b,a
wfk_lp: ld a,(tick)
        sub b
        jp p,wfk_go
        push bc
        call idle_work
        pop bc
        jr wfk_lp
wfk_go: jr z,wfk_ok
        ld hl,lk_over
        inc (hl)
wfk_ok: ld a,b
        ld (last_tick),a
        ld a,2
        ld (wf_n),a
        jr wf_ok
        endif
        ld a,(last_tick)
        ld b,a
wf_lp:  ld a,(app_seq)
        ld c,a
        ld a,(pub_seq)
        cp c
        jr nz,wf_idle               ; the last list is not on screen yet
        ld a,(tick)
        cp b
        jr nz,wf_got
wf_idle:
        push bc
        call idle_work
        pop bc
        jr wf_lp
wf_got: ld (last_tick),a
        sub b
        ld (wf_n),a                 ; (the cadence counts them)
        dec a
        jr z,wf_ok
        ld hl,(late)
        inc hl
        ld (late),hl
wf_ok:  ld a,1
        ld (iw_more),a              ; (every frame's first feed_vdp looks at the scroll engine)
        ld hl,(frame)
        inc hl
        ld (frame),hl
        ret
