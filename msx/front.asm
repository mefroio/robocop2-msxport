; The front end (bank BANK_FRONT at 8000h while it runs; called from the fixed code through
; front_call): the pictures in SCREEN 8 - the title (TPIC, shown by game_boot $11A20) and the
; game over (PIC9, main_loop $82A8) - converted by tools/msxpic.py (256 x lines, the fixed
; G7 palette) and stored from their banks on (PIC_..._BANK, 32 lines per bank, read through
; the A000h window).
;
; While a picture shows, the VBLANK interrupt only counts frames and runs the sound (front_mode:
; no register list, no HUD split, no play-field palette).

PIC_TOP:    equ 106                 ; (the picture's centre line on the 212-line screen)

; ----- the title -----

; TPIC until fire is pressed (after it was released); then the music stops. With the PSG alone
; RoboCop's speech plays then (the title's end on the Amiga, on start here: the user's choice for
; the PSG); on the SCC / OPLL it has its place in the music (front_fire).
front_title:
        ld a,PIC_TITLE_BANK
        ld b,PIC_TITLE_LINES
        call pic_show
        call snd_music              ; (TITM tune 1: $10884)
        call front_fire
        call snd_stop
        ld a,(mus_mode)
        or a
        ret nz
        ld hl,vm_alone              ; (music.asm: tools/msxvoice.py's PCM on the PSG)
        jp mus_call

; ----- the game over -----

; PIC9 with GAME OVER below it (tools/msxtext.py) for 30 seconds, or until fire is pressed once
; released (the fire held as RoboCop fell does not skip it); then the title. (The original:
; 128 VBLs, main_loop $82A8: show_picture D0 = 8; the user's choice: longer, and a way out.)
FO_TICKS:   equ 30 * 50             ; 50 Hz ticks (fs_tick: the same time at 60 Hz)
front_over:
        call snd_stop               ; (show_picture $11E06: $FE14)
        ld a,PIC_GAMEOVER_BANK
        ld b,PIC_GAMEOVER_LINES
        call pic_show
        ld hl,FO_TICKS
        ld c,0                      ; (fire not released yet)
fo_lp:  push hl
        push bc
        call fs_tick
        call ff_bits
        pop bc
        pop hl
        jr z,fo_rel
        dec c
        inc c
        ret nz                      ; (pressed after a release)
        jr fo_n
fo_rel: ld c,1
fo_n:   dec hl
        ld a,h
        or l
        jr nz,fo_lp
        ret

; ----- the level's statistics -----

; show_level_stats ($85D8: script $1132F through $10762): the henchmen killed ($16C2), the nukes
; collected ($16C0) and the hostages rescued ($16BE) typed into the play area, one script
; element a tick (50 a second: at 60 Hz every sixth VBLANK is skipped), in the text screens'
; font and palette (tools/msxtext.py; column c at x 8c - 16, row r at line 67 + 8r); no cursor
; ($FE14 cleared $B00); the HUD stays below. It ends after the script's wait (362 ticks), or
; with fire from tick 50 on; then the play area goes black at once ($FE14).
front_stats:
        call snd_stop               ; ($10768: $FE14)
        ld hl,fb_init
        call field_call             ; (no play-field BOB holds a list now)
        ld hl,pf_pal
        ld bc,32
        xor a
        call fill                   ; black from the next VBLANK
        call fs_vbl
        ld hl,fs_clear
        call vdp_cmd                ; the play area of page 0 black
        call fs_list                ; page 0 unscrolled, no sprites
fs_on:  call fs_vbl
        ld a,(app_seq)
        ld b,a
        ld a,(pub_seq)
        cp b
        jr nz,fs_on                 ; (until that list is on screen)
        call vdp_wait
        ld hl,txt_pal
        ld de,pf_pal
        ld bc,32
        ldir                        ; ($109A8 at once)
        ld hl,txt_stats
        ld de,fs_buf
        ld bc,TXT_STATS_LEN
        ldir
        ld hl,(AM + 0x16C2)
        ld de,fs_buf + TXT_F1
        call fs_num
        ld hl,(AM + 0x16C0)
        ld de,fs_buf + TXT_F2
        call fs_num
        ld hl,(AM + 0x16BE)
        ld de,fs_buf + TXT_F3
        call fs_num
        ld hl,fs_buf
        ld (fs_ptr),hl
        ld hl,0
        ld (fs_wait),hl
        ld (fs_n),hl
        xor a
        ld (fs_done),a
        ld (fs_col),a
        ld (fs_row),a
fs_lp:  call fs_tick
        call fs_step
        ld hl,(fs_n)
        inc hl
        ld (fs_n),hl
        ld de,50
        or a
        sbc hl,de
        jr c,fs_lp                  ; (not before tick 50)
        ld a,(fs_done)
        or a
        jr nz,fs_end
        call ff_bits
        jr z,fs_lp
fs_end: ld hl,pf_pal
        ld bc,32
        xor a
        jp fill

; One element of the script ($116CA): a wait going on, a position (00 x y), a character, a wait
; (80-FF 2 n: max(1, 4n) calls, this one the first) or the end (80-FF 7: done).
fs_step:
        ld hl,(fs_wait)
        ld a,h
        or l
        jr z,fst_rd
        dec hl
        ld (fs_wait),hl
        ret
fst_rd: ld hl,(fs_ptr)
        ld a,(hl)
        inc hl
        or a
        jr nz,fst_c
        ld a,(hl)
        inc hl
        ld (fs_col),a
        ld a,(hl)
        inc hl
        ld (fs_row),a
        ld (fs_ptr),hl
        ret
fst_c:  bit 7,a
        jr nz,fst_cmd
        ld (fs_ptr),hl
        jr fs_char
fst_cmd:
        ld a,(hl)
        inc hl
        cp 2
        jr nz,fst_end
        ld e,(hl)
        inc hl
        ld (fs_ptr),hl
        ld d,0
        ex de,hl
        add hl,hl
        add hl,hl                   ; 4n
        ld a,h
        or l
        jr nz,fst_w
        inc hl
fst_w:  dec hl
        ld (fs_wait),hl
        ret
fst_end:
        ld (fs_ptr),hl
        ld a,1
        ld (fs_done),a
        ret

; A = a character: its glyph ($118D6: ' ' 41, from '@' code - 'A', else code - 16h) written over
; the cursor's cell, the cursor one column on.
fs_char:
        ld b,41
        cp 0x20
        jr z,fsc_g
        sub 0x16
        ld b,a
        cp 0x40 - 0x16
        jr c,fsc_g
        sub 0x41 - 0x16
        ld b,a
fsc_g:  ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,txt_glyphs
        add hl,de
        ex de,hl                    ; DE = its 8 lines of 4 bytes
        ld a,(fs_col)
        ld c,a
        inc a
        ld (fs_col),a
        ld a,c
        add a,a
        add a,a
        sub 8
        ld c,a                      ; C = the byte in the line (x / 2)
        ld a,(fs_row)
        add a,a
        add a,a
        add a,a
        add a,67                    ; A = its first line
        ld b,8
fsc_ln: push bc
        push af
        ld h,a
        ld l,0
        srl h
        rr l
        ld a,l
        or c
        ld l,a                      ; HL = line * 128 + byte (page 0)
        push de
        ld e,0
        call vram_write
        pop hl
        ld bc,4 * 256 + VDP_DATA
        otir
        ex de,hl
        pop af
        inc a
        pop bc
        djnz fsc_ln
        jp vram_done

; HL = a number (0..32767), DE = its field: the digits from the field's last character back
; ('[' + digit), the field's spaces before them ($11DC6: leading zeros as spaces).
fs_num: ex de,hl
        ld bc,7
        add hl,bc
        ex de,hl
fsn_lp: ld b,16                     ; HL / 10, A = the remainder
        xor a
fsn_d:  add hl,hl
        rla
        cp 10
        jr c,fsn_n
        sub 10
        inc l
fsn_n:  djnz fsn_d
        add a,0x5B
        ld (de),a
        dec de
        ld a,h
        or l
        jr nz,fsn_lp
        ret

; The next 50 Hz tick (a VBLANK; at 60 Hz every sixth one is skipped).
fs_tick:
        call fs_vbl
        ld a,(RG9SAV)
        and 2
        ret nz
        ld hl,fs_div
        inc (hl)
        ld a,(hl)
        cp 6
        ret c
        ld (hl),0
        jr fs_tick
fs_vbl: ld a,(tick)
        ld b,a
fsv_lp: ld a,(tick)
        cp b
        jr z,fsv_lp
        ret

; A register list for the next VBLANK (isr.asm publish): page 0 unscrolled, no sprites; the
; split shows the HUD as in the game.
fs_list:
        call next_list
        push hl
        inc hl
        ld (hl),14                  ; 7 registers (10 on the V9958)
        inc hl
        ex de,hl
        ld hl,fs_regs
        ld bc,12
        ldir
        ex de,hl
        ld a,(spr_set)
        ld (hl),a
        inc hl
        ld (hl),0x85
        inc hl
        ld a,(vdp_id)
        cp 2
        jp nz,list_tail
        ex (sp),hl
        inc hl
        ld (hl),20
        dec hl
        ex (sp),hl
        ex de,hl
        ld hl,fs_r58
        ld bc,6
        ldir
        ex de,hl
        jp list_tail
fs_regs:
        db R1_ON, 0x81
        db R8_SPR_OFF, 0x88
        db R2_PAGE0, 0x82
        db 0, 0x97                  ; R#23
        db SPLIT_LINE, 0x93         ; R#19: the HUD's split
        db 0, 0x92                  ; R#18
fs_r58: db 0, 0x99                  ; V9958: one page (the split sets the HUD's R#25), unscrolled
        db 0, 0x9A
        db 0, 0x9B
fs_clear:
        dw 0, 0, 0, 0, 256, VIEW_LINES  ; SX, SY, DX, DY, NX, NY
        db 0, 0, 0xC0                   ; colour 0, ARG, HMMV

; ----- pictures -----

; A = the picture's first bank, B = its lines: SCREEN 8 (G7) with it centred, the rest black;
; the display back on.
pic_show:
        ld (ps_bank),a
        ld a,b
        ld (ps_lines),a
        di
        ld a,1
        ld (front_mode),a
        xor a
        ld (split_armed),a
        ei
        ld a,R1_BLANK
        ld b,1
        call wrreg                  ; display off (the VBLANK interrupt stays on)
        ld a,0x0E
        ld b,0
        call wrreg                  ; G7, no line interrupt
        ld a,R8_SPR_OFF
        ld b,8
        call wrreg
        ld a,R2_PAGE0
        ld b,2
        call wrreg
        xor a
        ld b,18
        call wrreg
        xor a
        ld b,23
        call wrreg
        ld a,(vdp_id)
        cp 2
        jr nz,ps_clr
        xor a
        ld b,25
        call wrreg                  ; V9958: no YJK, no border mask, one page
        xor a
        ld b,26
        call wrreg
        xor a
        ld b,27
        call wrreg
ps_clr: call vdp_wait               ; black everywhere (HMMV)
        ld hl,ps_hmmv
        call vdp_cmd
        call vdp_wait
        ld a,(ps_lines)
        ld b,a
        srl a
        neg
        add a,PIC_TOP
        ld h,a                      ; the first line
        ld l,0
        ld e,0
        push bc
        call vram_write
        pop bc
        ld a,(ps_bank)
        call bank_a000
        ld hl,0xA000
ps_lp:  push bc
        ld bc,VDP_DATA              ; (B = 0: 256 bytes, one line)
        otir
        pop bc
        ld a,h
        cp 0xC0
        jr nz,ps_nb
        ld a,(ps_bank)
        inc a
        ld (ps_bank),a
        call bank_a000
        ld hl,0xA000
ps_nb:  djnz ps_lp
        call vram_done
        ld a,R1_ON
        ld b,1
        jp wrreg                    ; display on

ps_hmmv:
        dw 0, 0, 0, 0, 256, 212     ; SX, SY, DX, DY, NX, NY
        db 0, 0, 0xC0               ; colour 0, ARG, HMMV

; Fire (joystick trigger A or a fire key: player.asm key_bits) pressed, after it was released.
; Until fire is pressed once released (vp_rel). Meanwhile, when the music on the SCC / OPLL
; reaches RoboCop's speech (mus_speak), the speech plays with the music going on (music.asm
; vm_music: the interrupts off; fire pressed meanwhile ends both).
front_fire:
        xor a
        ld (vp_rel),a
ff_lp:  halt
        ld a,(mus_speak)
        or a
        jr z,ff_k
        ld hl,vm_music
        call mus_call
        ld a,(vm_hit)
        or a
        ret nz
ff_k:   call ff_bits
        ld hl,vp_rel
        jr z,ff_up
        ld a,(hl)
        or a
        jr z,ff_lp
        ret
ff_up:  ld (hl),1
        jr ff_lp

ff_bits:
        call stick_bits
        and 0x10
        ld c,a
        push bc
        call key_bits
        pop bc
        and 0x10
        or c
        ret

; The game's display again: SCREEN 5 (G4, linear VRAM: what is written next lands where the
; game expects it), display off; the VBLANK interrupt does its frame work (the game sets the
; rest itself: new_game, display_on).
front_done:
        call snd_stop               ; (level_init $8720)
        ld a,R1_BLANK
        ld b,1
        call wrreg
        ld a,R0_IE1_OFF
        ld b,0
        call wrreg
        di
        xor a
        ld (front_mode),a
        ei
        ret
