; BOBs: draw_bob ($AB08) and its wrappers, for the ported game logic.
;
; The Amiga blits a BOB (mask + 4 planes, A2 = its graphics, D4 = BLTSIZE) into the play field,
; clipped to 288 x 177 (x from camera + 90h); it returns D0 = 0, or -1 when nothing of it is
; inside, and the game frees an object whose parts are all outside. Here the clipping is the
; original's arithmetic (so the result is the same) and a drawn BOB goes into bob_list; after
; the tick, bob_flush gives the list to the sprite engine.
;
; Calls: bob_x, bob_y = D0, D1 (world), bob_a2 = A2 (3 bytes, low first), bob_d4 = D4, then
; bob_draw / bob_part / bob_part2 / bob_flashd / bob_black (A3 = IX for the flash byte).
; -> A = D0's high byte (0 drawn, FFh not), Z set when drawn. Keep IX, IY.

BOB_MAX:    equ 38                  ; BOBs recorded per game frame
BOB_REC:    equ 10                  ; record: A2 (3), D4 (2), x (2), y (2), mode | category << 4
BM_NORMAL:  equ 0                   ; cookie-cut ($CA)
BM_FLASH:   equ 1                   ; the mask ORed into every plane: a colour 15 silhouette ($FA)
BM_BLACK:   equ 2                   ; the mask cleared from every plane: a colour 0 silhouette ($0A)

; At the start of the game's tick: no BOB yet.
bob_begin:
        xor a
        ld (bob_n),a
        ld hl,bob_list
        ld (bob_ptr),hl
        ret

; $AC44: flash-aware; the result also goes into $16BA (the first part of a multi-part object).
bob_part:
        ld a,(ix+0x22)
        or a
        jr nz,bob_flashd
        call bob_draw
        ld (AM + 0x16BA),a
        ld (AM + 0x16BB),a
        ret

; $AC56: flash-aware (the flash byte is cleared: the object's last part); when this part is not
; drawn the result is $16BA's (the first part's).
bob_part2:
        ld a,(ix+0x22)
        or a
        jr z,bp2_n
        ld (ix+0x22),0
        jr bob_flashd
bp2_n:  call bob_draw
        ret z
        ld a,(AM + 0x16BB)
        or a
        ret

; $AC6E: drawn as a colour 15 silhouette (minterm $FA).
bob_flashd:
        ld a,BM_FLASH
        jr bd_mode

; $AC84: drawn as a colour 0 silhouette (minterm $0A).
bob_black:
        ld a,BM_BLACK
        jr bd_mode

; $AB08.
bob_draw:
        xor a
bd_mode:
        ld (bob_mode),a
        ld hl,(bob_x)               ; (the port: a BOB wholly inside - x - camera x in 8Fh..1B0h
        ld de,(gcam_x)              ; - its width, y - camera y in 0..B1h - its height, both
        or a                        ; unsigned - is cut nowhere: drawn at once)
        sbc hl,de
        ld de,-0x8F
        add hl,de
        ld a,(bob_d4)
        and 63
        jr z,bd_slow
        dec a
        push hl
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; width in px
        ex de,hl
        ld hl,0x121
        or a
        sbc hl,de
        ex de,hl                    ; 121h - width
        pop hl
        jr c,bd_slow
        or a
        sbc hl,de
        jr nc,bd_slow               ; x is not inside
        ld hl,(bob_d4)
        call bd_h                   ; DE = height
        ld hl,0xB1
        or a
        sbc hl,de
        jr c,bd_slow
        ex de,hl
        ld hl,(bob_y)
        ld bc,(gcam_y)
        or a
        sbc hl,bc
        or a
        sbc hl,de
        jp c,bd_rec                 ; y is inside too
bd_slow:
        ld hl,(bob_x)
        ld de,(gcam_x)
        or a
        sbc hl,de
        ld (bd_d0),hl               ; D0 = x - camera x
        ld hl,(bob_y)
        ld de,(gcam_y)
        or a
        sbc hl,de
        ld (bd_d1),hl               ; D1 = y - camera y
        ld hl,(bob_d4)
        ld (bd_d4),hl
        ld a,l
        and 63
        ld l,a
        ld h,0
        dec hl
        add hl,hl
        ld (bd_wb),hl               ; D2 = bytes per line ((D4 & 63) - 1) * 2
        ex de,hl
        ld hl,0x96
        or a
        sbc hl,de
        ld (bd_dmod),hl             ; destination modulo 96h - bytes
        ; right: past camera x + 1B0h, whole words cut
        ex de,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; bytes * 8
        ld de,(bd_d0)
        add hl,de
        ld de,0x1B0
        or a
        sbc hl,de
        jr c,bd_left                ; (bcs)
        call bd_cut                 ; HL = D2: words cut (lsr 4) from the width, the modulo grows
        ld de,0x98
        or a
        sbc hl,de
        jp nc,bd_none               ; (cmpi.w #$98,D6; bcc: nothing left)
bd_left:
        ld hl,0x8E
        ld de,(bd_d0)
        or a
        sbc hl,de
        jp m,bd_top                 ; (bmi: nothing cut on the left)
        call bd_cut
        ld de,0x98
        or a
        sbc hl,de
        jp p,bd_none                ; (cmpi.w #$98,D6; bpl)
bd_top: ld hl,(bd_d1)
        bit 7,h
        jr z,bd_bot
        ex de,hl
        ld hl,0
        or a
        sbc hl,de                   ; lines cut at the top (-D1)
        push hl
        ld hl,(bd_d4)
        call bd_h                   ; DE = height
        pop hl
        push hl
        or a
        sbc hl,de
        pop de                      ; DE = cut
        jr nc,bd_none               ; (cmp.w (SP),D2; bcc: all of it above)
        ld hl,(bd_d4)
        call bd_lines
        jr c,bd_none
        jr bd_rec
bd_bot: ld de,0xB1
        or a
        sbc hl,de                   ; D1 - B1h
        jr nc,bd_none               ; (subi.w #$b1,D2; bcc: below the field)
        push hl
        ld hl,(bd_d4)
        call bd_h
        pop hl
        add hl,de                   ; lines past the bottom
        bit 7,h
        jr nz,bd_rec                ; (bmi: none)
        ex de,hl
        ld hl,(bd_d4)
        call bd_lines
        jr c,bd_none
bd_rec: ld a,(bob_n)                ; drawn: recorded
        cp BOB_MAX
        jr nc,bd_full
        inc a
        ld (bob_n),a
        ld de,(bob_ptr)
        ld hl,bob_a2
        ld bc,9
        ldir                        ; A2, D4, x, y (contiguous in RAM)
        ld a,(bob_cat)
        add a,a
        add a,a
        add a,a
        add a,a
        ld hl,bob_mode
        or (hl)
        ld (de),a                   ; mode | category << 4
        inc de
        ld (bob_ptr),de
bd_full:
        xor a
        ret
bd_none:
        ld a,0xFF
        or a
        ret

; HL = D2 (lsr 4: whole words beyond the edge): the width shrinks by them, the modulo grows by
; twice them -> HL = the new destination modulo.
bd_cut: srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ex de,hl
        ld hl,(bd_d4)
        or a
        sbc hl,de
        ld (bd_d4),hl               ; (sub.w D2,D4)
        ex de,hl
        add hl,hl
        ld de,(bd_dmod)
        add hl,de
        ld (bd_dmod),hl
        ret

; HL = a BLTSIZE -> DE = its height (>> 6). Keeps HL.
bd_h:   ld a,l
        rlca
        rlca
        and 3
        ld e,a
        ld a,h
        add a,a
        add a,a
        or e
        ld e,a
        ld a,h
        rlca
        rlca
        and 3
        ld d,a
        ret

; HL = BLTSIZE, DE = lines cut: HL -= DE << 6 -> carry when it borrows or no line is left
; ((D4 & ~63) = 0). The new size goes into bd_d4.
bd_lines:
        push hl
        ex de,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ex de,hl
        pop hl
        or a
        sbc hl,de
        ret c
        ld (bd_d4),hl
        ld a,l
        and 0xC0
        or h
        ret nz
        scf
        ret

; ----- the BOBs on screen: sprite objects -----

; BOB categories, in the order they get sprite objects (what matters most first; lower objects
; are also drawn in front): the systems of the game's tick set bob_cat before drawing.
BC_EBULLET: equ 0                   ; enemy bullets ($F3CE)
BC_ENEMY:   equ 1                   ; enemies (update_objects)
BC_PICKUP:  equ 2                   ; pickups ($F900)
BC_EFFECT:  equ 3                   ; RoboCop's shots and effects (update_player)
BC_SPECIAL: equ 4                   ; lifts, the vehicle ($8B32)
BC_EXPL:    equ 5                   ; explosions ($F080)
BOB_CATS:   equ 6

; After the game's tick (main loop, after pl_show): the BOBs it drew (bob_list) become sprite
; objects 1..MAX_OBJ-1, category by category, the later drawn first within one (the Amiga drew
; them over the earlier ones: lower objects are in front). Each one's frame comes from the
; level's table (BOBHASH, tools/mkrom.py: A2 and D4 -> frame id; a frame not there is not
; shown); its place against the view as RoboCop's: map x = x - 143, map y = y. The objects
; left over are hidden.
bob_flush:
        ld a,LEVEL_BANK
        call bank_8000
        ld a,1
        ld (bf_obj),a
        xor a
bf_cat: ld (bf_catn),a
        ld a,(bob_n)
        or a
        jr z,bf_end
        ld b,a
        ld ix,(bob_ptr)             ; past the last record
bf_rec: ld de,-BOB_REC
        add ix,de
        ld a,(ix+9)
        rrca
        rrca
        rrca
        rrca
        and 15
        ld c,a
        ld a,(bf_catn)
        cp c
        jr nz,bf_nx
        push bc
        call bf_show
        pop bc
        ld a,(bf_obj)
        cp MAX_OBJ
        jr nc,bf_end                ; every object taken
bf_nx:  djnz bf_rec
        ld a,(bf_catn)
        inc a
        cp BOB_CATS
        jr c,bf_cat
bf_end: ld a,(bf_obj)
bf_hd:  cp MAX_OBJ
        ret nc
        push af
        call obj_hide
        pop af
        inc a
        jr bf_hd

; IX = a BOB record: its frame (the hash table) as object bf_obj, at its place; bf_obj moves on.
bf_show:
        ld a,LEVEL_BANK             ; (obj_bob maps the sprite banks)
        call bank_8000
        ld a,(ix+0)
        xor (ix+1)
        xor (ix+2)
        xor (ix+3)
        xor (ix+4)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,BOBHASH
        add hl,de
bfs_lp: push hl
        pop iy
        ld a,(iy+5)
        cp 0xFF
        ret z                       ; not one of the level's frames: not shown
        ld a,(iy+0)
        cp (ix+0)
        jr nz,bfs_nx
        ld a,(iy+1)
        cp (ix+1)
        jr nz,bfs_nx
        ld a,(iy+2)
        cp (ix+2)
        jr nz,bfs_nx
        ld a,(iy+3)
        cp (ix+3)
        jr nz,bfs_nx
        ld a,(iy+4)
        cp (ix+4)
        jr z,bfs_got
bfs_nx: ld de,8
        add hl,de
        ld a,h
        cp (BOBHASH + 0x800) / 256
        jr nz,bfs_lp
        ld hl,BOBHASH
        jr bfs_lp
bfs_got:
        ld e,(iy+5)
        ld d,0
        ld a,(bf_obj)
        push ix
        call obj_bob
        pop ix
        ld l,(ix+5)
        ld h,(ix+6)
        ld de,-135
        add hl,de
        ld de,(cam_x)
        or a
        sbc hl,de                   ; screen x: x - 143 against the view, + 8 (left border)
        push hl
        ld l,(ix+7)
        ld h,(ix+8)
        ld de,(cam_y)
        or a
        sbc hl,de
        ex de,hl                    ; screen y
        pop hl
        ld a,(bf_obj)
        push ix
        call obj_pos
        pop ix
        ld hl,bf_obj
        inc (hl)
        ret
