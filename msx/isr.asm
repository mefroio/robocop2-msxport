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
; line (R#19 - R#23) & 255; R#1 (blank), R#8 (sprites) and R#18 take effect at the start of
; the next line, while R#2, R#23, R#26, R#27 and the palette take effect immediately. HR
; (S#2 bit 5) is 1 for 312 VDP ticks from the right border, computed with the current
; horizontal adjust (so writing R#18 moves the window).

isr_init:
        ld hl,IM2_TABLE
        ld de,IM2_TABLE+1
        ld bc,256
        ld (hl),IM2_VEC
        ldir
        ld a,0xC3                   ; JP isr
        ld (IM2_JUMP),a
        ld hl,isr
        ld (IM2_JUMP+1),hl
        ld a,IM2_I
        ld i,a
        im 2
        xor a
        ld (split_armed),a
        ld (tick),a
        ld (last_tick),a
        ld (pk_state),a             ; (the sprite engine's state the interrupts share)
        ld (pk_mux),a
        ld (pq_buf),a
        ld (bq_head),a
        ld (bq_tail),a
        ld (vram_busy),a
        ld (sat_due),a
        ld (sat_mux_n),a
        ld (spr_vblank),a
        ld (pub_seq),a              ; the list on screen until the first one is published: one
        ld (app_seq),a              ; that changes nothing (R#15 = 0). At power-on the RAM holds
        ld hl,vbl_list_a            ; anything, and a list read from it once wrote R#14 and an
        ld (vbl_ptr),hl             ; address in the middle of the tiles' upload after the title
        ld (pk_list),hl
        ld (hl),a                   ; (seq 0)
        inc hl
        ld (hl),2
        inc hl
        ld (hl),a
        inc hl
        ld (hl),0x8F
        ld hl,sat_pair0
        ld (sat_cur),hl
        ld (sat_nb),hl
        ld hl,pq_buf
        ld (pq_rd),hl
        ld a,R5_SET_A
        ld (spr_dsp),a
        ret

isr:    push af
        push bc
        push hl
        ld c,VDP_CTRL
        ld a,1
        out (c),a
        ld a,0x8F
        out (c),a
        in b,(c)                    ; S#1: bit 0 = FH (the read acknowledges it)
        xor a
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        bit 0,b
        jr z,isr_s0
        ld a,(split_armed)
        or a
        call nz,isr_split
isr_s0: in a,(c)                    ; S#0: bit 7 = VBLANK (the read acknowledges it)
        or a
        call m,isr_vblank
        pop hl
        pop bc
        pop af
        ei
        reti

; HUD split (V = VIEW_LINES): the interrupt fires at the end of line V-4 and the ISR reaches
; the first HR poll ~1.1-1.7 lines later, inside line V-2. Blanks the display from line V
; (written during line V-1); once line V-1 is complete (its right border) switches page,
; scroll, adjust and palette with unrolled OUTI, and turns the display back on while still in
; line V+3, so the HUD shows from line V+4. On the V9958 the border mask is then turned off
; (the HUD's left columns are still black there) so that the HUD uses all 256 px. The line
; interrupt stays enabled: a match created by the HUD's R#23 is acknowledged and ignored.
isr_split:
        xor a
        ld (split_armed),a
        ld a,2
        out (c),a
        ld a,0x8F
        out (c),a                   ; S#2 (HR polling)
sp_e1: in a,(c)
        and 0x20
        jr z,sp_e1                  ; right border of line V-2
sp_s0:  in a,(c)
        and 0x20
        jr nz,sp_s0                 ; line V-1 has started
        ld a,R1_BLANK
        out (c),a
        ld a,0x81
        out (c),a                   ; display off from line V
        ld a,R8_SPR_OFF
        out (c),a
        ld a,0x88
        out (c),a                   ; sprites off from line V
sp_e0: in a,(c)
        and 0x20
        jr z,sp_e0                  ; right border of line V-1: nothing visible changes now
        ld hl,split_list+1
        outi
        outi
        outi
        outi
        outi
        outi                        ; R#2 = page 3, R#23 = HUD_R23, R#18 = 0
        ld a,(split_list)
        cp 6
        jr z,sp_pal
        outi
        outi
        outi
        outi                        ; V9958: R#26/R#27 = page 3 unscrolled
sp_pal: ld a,1
        out (c),a
        ld a,0x90
        out (c),a                   ; R#16 = colour 1
        ld hl,hud_palette+2
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
        ld a,R1_ON
        out (c),a
        ld a,0x81
        out (c),a                   ; still in line V+3: HUD visible from line V+4
        ld a,(hud_msk)
        or a
        jr z,sp_msk
        ld a,R25_HUD
        out (c),a
        ld a,0x99
        out (c),a                   ; V9958: no border mask in the HUD
sp_msk: ld a,SPLIT_R19
        out (c),a
        ld a,0x80 + 19
        out (c),a                   ; R#19 against the HUD's R#23: its match (line V-4) is behind
        ld a,1                      ; us, so no second line interrupt comes before the VBLANK's
        out (c),a                   ; list (the play field's R#19 against the HUD's R#23 matched
        ld a,0x8F                   ; below the split, while the uploads below kept the interrupts
        out (c),a                   ; off: the VBLANK re-armed the split and that late match ran
        in a,(c)                    ; it in the blank, the next picture all HUD page); one that
        xor a                       ; came meanwhile is acknowledged (S#1)
        out (c),a
        ld a,0x8F
        out (c),a                   ; R#15 = 0
        jp spr_upload               ; sprites off until the next frame: their uploads

; VBLANK: registers of the frame being shown next, the play-field palette (pf_pal) and, when
; the list is a new one, the SAT built for it (it must be in VRAM before the first display
; line: written by the main program it often came in the middle of the picture); in the front
; end (front_mode) only the frame count and the sound.
isr_vblank:
        ld a,(front_mode)
        or a
        jr nz,iv_tick
        ld a,(pk_state)
        cp 1
        jr nz,iv_rdy
        ld a,(split_armed)          ; (no split since the last VBLANK: the display or the line
        or a                        ; interrupt is off) the published frame's uploads now
        call nz,spr_upload
        ld a,(pk_state)
iv_rdy: cp 2
        jr nz,iv_list
        xor a
        ld (pk_state),a
        ld hl,(pk_list)
        ld (vbl_ptr),hl             ; the published frame from this one on
iv_list:
        ld hl,(vbl_ptr)
        ld a,(app_seq)
        cp (hl)
        ld a,(hl)
        ld (app_seq),a
        push af                     ; (NZ: a new list)
        inc hl
        ld b,(hl)
        inc hl
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
        jr nz,iv_new
        ld a,(pk_mux)               ; the same frame: objects alternating take turns
        or a
        call nz,iv_satw
        jr iv_late
iv_new: call iv_sat                 ; (sprites.asm)
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
        ld (hl),HUD_R23
        inc hl
        ld (hl),0x97                ; R#23: HUD_VRAM_LINE shown at display line V+4
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0x92                ; R#18 = 0
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
        ld b,10
si_len: ld a,b
        ld (split_list),a
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
wf_ok:  ld hl,(frame)
        inc hl
        ld (frame),hl
        ret
