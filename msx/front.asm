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

; TPIC until fire is pressed (after it was released).
front_title:
        ld a,PIC_TITLE_BANK
        ld b,PIC_TITLE_LINES
        call pic_show
        jp front_fire

; ----- the game over -----

; PIC9 for 128 frames (main_loop $82A8: show_picture D0 = 8, then 128 VBLs).
front_over:
        ld a,PIC_GAMEOVER_BANK
        ld b,PIC_GAMEOVER_LINES
        call pic_show
        ld b,128
fo_lp:  halt
        djnz fo_lp
        ret

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
front_fire:
ff_rel: halt
        call ff_bits
        jr nz,ff_rel
ff_lp:  halt
        call ff_bits
        jr z,ff_lp
        ret

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
