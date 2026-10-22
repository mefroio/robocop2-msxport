; Game logic helpers in the fixed code (4000h-7FFFh), shared by the logic modules at 8000h
; (objects.asm, mapobj.asm) and the level banks: the map cell of a point ($EF8E), the linear map's
; reads and writes, explosions ($F366), pickups ($F98C), the palette flash ($F80E), the score
; ($F6A0), 24-bit BOB addresses and 32-bit longs of the mirror.

; DE = BCD points (the Amiga's D2, a word here): added to the score ($8046-$8049, 4 BCD bytes,
; the first the highest; byte A at A ^ 1).
add_score:
        ld hl,AG + (0x8049 ^ 1)
        ld a,(hl)
        add a,e
        daa
        ld (hl),a
        inc hl                      ; ($8048)
        ld a,(hl)
        adc a,d
        daa
        ld (hl),a
        ld hl,AG + (0x8047 ^ 1)
        ld a,(hl)
        adc a,0
        daa
        ld (hl),a
        inc hl                      ; ($8046)
        ld a,(hl)
        adc a,0
        daa
        ld (hl),a
        ret

; A:HL = a 24-bit address, DE = a word offset (sign-extended, adda.w): bob_a2 = their sum.
a2_set: add hl,de
        ld (bob_a2),hl
        adc a,0
        bit 7,d
        jr z,a2s_p
        dec a
a2s_p:  ld (bob_a2+2),a
        ret

; D = row, E = column -8..167 (the linear map: a negative column is the row above's end, 160 and
; more the next row's start), HL = a map word: map_write. Keeps DE.
map_write_lin:
        ld a,e
        cp MAP_COLS
        jp c,map_write
        push de
        cp 0xF8
        jr c,mwl_n
        add a,MAP_COLS
        dec d
        jr mwl_w
mwl_n:  sub MAP_COLS
        inc d
mwl_w:  ld e,a
        call map_write
        pop de
        ret

; D = row, E = column -8..167 (as map_write_lin) -> A = attributes.
atr_lin:
        ld a,e
        cp MAP_COLS
        jp c,atr_rc
        push de
        cp 0xF8
        jr c,al_n
        add a,MAP_COLS
        dec d
        jr al_w
al_n:   sub MAP_COLS
        inc d
al_w:   ld e,a
        call atr_rc
        pop de
        ret

; HL = x, DE = y ($EF8E): the map cell of (x, y) -> ao_row, ao_col (column (x >> 4) - 8: the
; Amiga's map pointer starts at $37FF0; rows above or below the map leave it on row 0) and
; DE = y, its low byte & F0h when the cell's attributes & 15 are not 0 (then carry: solid; also
; for rows above the map).
map_cell:
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        sub 8
        ld (ao_col),a
        bit 7,d
        jr nz,mc_above
        ld a,e
        srl d
        rra
        srl d
        rra
        srl d
        rra
        srl d
        rra                         ; y >> 4
        ld d,a
        ld a,e
        and 0xF0
        ld l,a                      ; (y's low byte & F0h)
        ld a,d
        cp MAP_ROWS
        jr nc,mc_below
        ld (ao_row),a
        ld a,(ao_col)
        ld e,a
        push hl
        call atr_lin
        pop hl
        ld de,(ao_y)
        and 15
        ret z
        ld e,l
        scf
        ret
mc_above:
        xor a
        ld (ao_row),a
        scf
        ret
mc_below:
        xor a
        ld (ao_row),a
        ld de,(ao_y)
        ret

; HL = x, DE = y -> A = the attributes of the cell $EF8E leaves in A0 (the shots test (1,A0)):
; row y >> 4, column (x >> 4) - 8; above the map or past its rows A0 stays on row 0.
map_atr:
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        sub 8
        ld c,a
        ld a,e
        bit 7,d
        jr nz,mat_r0
        srl d
        rra
        srl d
        rra
        srl d
        rra
        srl d
        rra
        inc d
        dec d
        jr nz,mat_r0
        cp MAP_ROWS
        jr c,mat_r
mat_r0: xor a
mat_r:  ld d,a
        ld e,c
        jp atr_lin

; ----- the activators of level 1's object types ($9EC4 + offset) -----

; HL = x, DE = y, B = D5's high byte, C = explosion type: the last free one of the 8 slots
; ($D34 + k, bytes) starts (1), with the type's sound ($B2D) and its two bytes ($D44 + k,
; $D4C + k), B at $D3C + k, the position at $D54 + 2k / $D64 + 2k (words). Nothing when all 8
; are busy. Keeps IX, IY.
expl_add:
        ld (ea_x),hl
        ld (ea_y),de
        ld a,8
ea_lp:  dec a
        ret m                       ; all busy
        ld (ea_k),a
        xor 1
        ld e,a
        ld d,0
        ld hl,AM + 0x0D34
        add hl,de                   ; byte $D34 + k
        ld a,(hl)
        or a
        ld a,(ea_k)
        jr nz,ea_lp
        ld (hl),1
        push hl
        ld e,c
        ld hl,expl_snd
        add hl,de
        ld a,(hl)
        ld (snd_b2d),a
        ld hl,expl_t1
        add hl,de
        ld c,(hl)
        ld hl,expl_t2
        add hl,de
        ld a,(hl)
        pop hl
        ld de,8
        add hl,de
        ld (hl),b                   ; $D3C + k
        add hl,de
        ld (hl),c                   ; $D44 + k
        add hl,de
        ld (hl),a                   ; $D4C + k
        ld a,(ea_k)
        add a,a
        ld e,a
        ld d,0
        ld hl,AM + 0x0D54
        add hl,de
        ld de,(ea_x)
        ld (hl),e
        inc hl
        ld (hl),d
        ld de,0x0F
        add hl,de
        ld de,(ea_y)
        ld (hl),e
        inc hl
        ld (hl),d                   ; $D64 + 2k
        ret

; ----- pickups ($F98C) -----

; HL = x, BC = y, DE = the pickup's type (D2): it pops out into the next of the 4 pickup slots
; ($1694 & 3): type at $D80 + k (byte), vy -2.8000h at $DA4 + 4k, x at $D84 + 4k (word), y at
; $D94 + 4k (16.16). Keeps IY.
pickup_drop:
        push hl
        ld a,(AM + 0x1694)
        and 3
        ld (ea_k),a
        xor 1
        ld l,a
        ld h,0
        push de
        ld de,AM + 0x0D80
        add hl,de
        pop de
        ld (hl),e                   ; type
        ld a,(ea_k)
        add a,a
        add a,a
        ld l,a
        ld h,0
        ld de,AM + 0x0D84
        add hl,de
        pop de
        ld (hl),e
        inc hl
        ld (hl),d                   ; x
        ld de,0x0F
        add hl,de                   ; $D94 + 4k
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0                   ; y.0000
        ld de,0x0D
        add hl,de                   ; $DA4 + 4k
        ld (hl),0xFD
        inc hl
        ld (hl),0xFF
        inc hl
        ld (hl),0x00
        inc hl
        ld (hl),0x80                ; FFFD.8000
        ld hl,(AM + 0x1694)
        inc hl
        ld (AM + 0x1694),hl
        ret

; ----- $BDCE: the random word $B32 -----

; Every game frame rotated left by CIA-A timer A's low byte and XORed with timer B. The Z80's
; refresh register stands in for the timers; builds with a JOY script read them as the execution
; bench does (FFh: a rotation by 63, i.e. 15, and FFFFh), so that the traces compare.
rnd_step:
        if INPUT_SCRIPT
        ld b,15
        ld de,0xFFFF
        else
        ld a,r
        and 15
        ld b,a
        ld a,r
        ld d,a
        ld a,(AM + 0x0B02)
        xor d
        ld e,a
        endif
        ld hl,(AM + 0x0B32)
        inc b
        jr rnd_n
rnd_l:  add hl,hl
        jr nc,rnd_n
        inc l
rnd_n:  djnz rnd_l
        ld a,h
        xor d
        ld h,a
        ld a,l
        xor e
        ld l,a
        ld (AM + 0x0B32),hl
        ret

; ----- the palette on screen: the copper's colours ($1049E) -----

; pf_pal (the play field's palette, loaded at every VBLANK) changes as the copper's colours do:
; the fade ($F8C4) computes all of it from the level's palette, a flash ($F80E) and its end
; ($F878) rewrite RoboCop's colours. The Amiga tints his sprite colours (COLOR17-31); here his
; entries that neither the background nor the play-field BOBs use (flash_idx, tools/msxsprites.py)
; take the tint, so that only the sprites change colour.

; A = flash palette (PAL_...): RoboCop in its colours for 4 more game frames ($F826), then in the
; level's again (pl_fade). Keeps BC, DE, IX, IY.
PAL_LEVEL:  equ 0
PAL_ENEMYHIT: equ 1                 ; $100B0 (an enemy touched RoboCop)
PAL_SHOT:   equ 2                   ; $10092 (an enemy shot hit him)
PAL_ELECTRIC: equ 3                 ; $100CE (an electric barrier)
PAL_REFILL: equ 4                   ; $100EC (energy refill)
PAL_BEAM:   equ 5                   ; $10074 (an electric beam of level 1, $933A)
PAL_REVERSE: equ 6                  ; $1010A (the reversed controls, every 8th frame)
pal_flash:
        ld (ac_flpal),a
        ld hl,4
        ld (ac_flash),hl
        push bc
        push de
        call pal_robo
        pop de
        pop bc
        ret

; A = flash palette (PAL_LEVEL: the level's own): RoboCop's entries of pf_pal from it ($F816).
pal_robo:
        ld hl,flash_pals - 2 * FLASH_N
        ld de,2 * FLASH_N
        or a
        jr z,prb_lv
prb_f:  add hl,de
        dec a
        jr nz,prb_f
        ex de,hl                    ; DE: the flash's colours
        ld hl,flash_idx
        ld b,FLASH_N
prb_lp: push hl
        ld l,(hl)
        ld h,0
        add hl,hl
        push de
        ld de,pf_pal
        add hl,de
        pop de
        ld a,(de)
        ld (hl),a
        inc de
        inc hl
        ld a,(de)
        ld (hl),a
        inc de
        pop hl
        inc hl
        djnz prb_lp
        ret
prb_lv: ld de,flash_idx
        ld b,FLASH_N
prl_lp: ld a,(de)
        inc de
        push de
        add a,a
        ld e,a
        ld d,0
        ld hl,palette
        add hl,de
        push hl
        ld hl,pf_pal
        add hl,de
        ex de,hl
        pop hl
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        ld a,(hl)
        ld (de),a
        pop de
        djnz prl_lp
        ret

; A = the fade level ($16CD, 0-1Fh): pf_pal = the level's palette with every 3-bit component
; at most A >> 2 ($F8C4: every 4-bit component at most (A >> 1) & 1Eh, 0-Eh: the same eight
; steps).
pal_fade:
        rrca
        rrca
        and 7
        ld c,a                      ; the limit for B and G
        rlca
        rlca
        rlca
        rlca
        ld b,a                      ; the limit for R (bits 4-6)
        ld hl,palette
        ld de,pf_pal
pfd_lp: ld a,(hl)
        and 0x70
        cp b
        jr c,pfd_r
        ld a,b
pfd_r:  ld (de),a                   ; R
        ld a,(hl)
        and 7
        cp c
        jr c,pfd_b
        ld a,c
pfd_b:  ex de,hl
        or (hl)
        ld (hl),a                   ; R | B
        ex de,hl
        inc hl
        inc de
        ld a,(hl)
        cp c
        jr c,pfd_g
        ld a,c
pfd_g:  ld (de),a                   ; G
        inc hl
        inc de
        ld a,e
        cp (pf_pal + 32) & 0xFF
        jr nz,pfd_lp
        ret

; ----- update_energy_can ($89BE), the logic -----

; HL = a long (two little-endian words, the high one first), DE = another: (HL) += (DE).
; -> S: the sum's sign. Keeps HL, DE.
add_l:  push hl
        push de
        inc hl
        inc hl
        inc de
        inc de
        ld a,(de)
        add a,(hl)
        ld (hl),a
        inc hl
        inc de
        ld a,(de)
        adc a,(hl)
        ld (hl),a                   ; the low word
        pop de
        pop hl
        ld a,(de)
        adc a,(hl)
        ld (hl),a
        inc hl
        inc de
        ld a,(de)
        adc a,(hl)
        ld (hl),a                   ; the high word, with the carry
        dec hl
        dec de
        ret

; HL = a long (two little-endian words, the high one first) holding a 24-bit address -> bob_a2.
a2_long:
        ld a,(hl)
        ld (bob_a2+2),a
        inc hl
        inc hl
        ld a,(hl)
        ld (bob_a2),a
        inc hl
        ld a,(hl)
        ld (bob_a2+1),a
        ret

