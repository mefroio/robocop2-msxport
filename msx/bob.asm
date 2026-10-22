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
; Each system's loop sets bob_own to the object it draws (its slot): a BOB's identity is its
; category, its owner and its place among the owner's BOBs of the tick (legs, torso, flash...),
; so that it keeps its sprite object from tick to tick (bob_flush).

BOB_MAX:    equ 30                  ; BOBs recorded per game frame (the original draws up to 18)
BOB_REC:    equ 15                  ; record: A2 (3), D4 (2), x (2), y (2), mode | category << 4,
                                    ; the category's record drawn before it (2; 0: none), owner (2),
                                    ; part
BM_NORMAL:  equ 0                   ; cookie-cut ($CA)
BM_FLASH:   equ 1                   ; the mask ORed into every plane: a colour 15 silhouette ($FA)
BM_BLACK:   equ 2                   ; the mask cleared from every plane: a colour 0 silhouette ($0A)

; At the start of the game's tick: no BOB yet.
bob_begin:
        ld hl,0xFFFF
        ld (bob_lown),hl            ; (no owner yet)
        xor a
        ld (bob_n),a
        ld hl,bob_list
        ld (bob_ptr),hl
        ld hl,cat_head
        ld b,2 * BOB_CATS
bbg_c:  ld (hl),a
        inc hl
        djnz bbg_c
        ret

; $AC44: flash-aware; the result also goes into $16BA (the first part of a multi-part object).
; (The port: a hit flash drawn in a tick whose picture the display skips is held for the next
; tick shown - fl_pend - or it would never be seen; only the BOBs' look changes.)
bob_part:
        ld a,(ix+OS_FLASH)
        or a
        jr nz,bp_fl
        call fl_held
        call bd_mode
        ld (AM + 0x16BA),a
        ld (AM + 0x16BB),a
        ret
bp_fl:  call fl_note
        jr bob_flashd

; $AC56: flash-aware (the flash byte is cleared: the object's last part); when this part is not
; drawn the result is $16BA's (the first part's).
bob_part2:
        ld a,(ix+OS_FLASH)
        or a
        jr z,bp2_n
        ld (ix+OS_FLASH),0
        call fl_note
        jr bob_flashd
bp2_n:  call fl_held
        or a
        jr z,bp2_d
        call fl_slot                ; (the object's last part: the held flash is done)
        ld (hl),0
        ld a,BM_FLASH
bp2_d:  call bd_mode
        ret z
        ld a,(AM + 0x16BB)
        or a
        ret

; IX = an enemy slot -> HL = its fl_pend byte. Keeps BC, DE.
fl_slot:
        push ix
        pop hl
        ld a,l
        sub OBJ_SLOTS & 0xFF
        rrca
        rrca
        and 7
        add a,fl_pend & 0xFF
        ld l,a
        ld h,fl_pend / 256          ; (fl_pend does not cross a 256-byte boundary)
        ret

; A flash drawn now: held when this tick's picture is skipped (bob_skip).
fl_note:
        ld a,(bob_skip)
        or a
        ret z
        call fl_slot
        ld (hl),1
        ret

; -> A = BM_FLASH when this tick is shown and a flash of a skipped one waits, else BM_NORMAL.
fl_held:
        ld a,(bob_skip)
        or a
        ld a,BM_NORMAL
        ret nz
        call fl_slot
        ld a,(hl)
        or a
        ret z
        ld a,BM_FLASH
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
; (The port: the original's clipping only says whether some of the BOB is inside: for BOBs of
; 1-15 words and fewer than 256 lines, with D0 = x - camera x from -3F71h on, its arithmetic
; comes down to: nothing when D0 >= 1C0h, or when D0 < 8Fh and (8Eh - D0) >> 4 >= the words
; (cut on the left: no right cut can come with it there); else, the cuts leaving the height,
; nothing when D1 = y - camera y >= B1h, or when D1 < 0 and -D1 >= the height. Other BOBs: its
; arithmetic as it is, bd_slow.)
bob_draw:
        xor a
bd_mode:
        ld (bob_mode),a
        ld a,(bob_d4+1)
        cp 0x40
        jp nc,bd_slow               ; (256 lines or more)
        ld a,(bob_d4)
        and 63
        jp z,bd_slow                ; (no words)
        cp 16
        jp nc,bd_slow               ; (more than 15)
        add a,a
        add a,a
        add a,a
        add a,a
        ld c,a                      ; C = 16 * words
        ld hl,(bob_x)
        ld de,(gcam_x)
        or a
        sbc hl,de
        ld de,-0x8F
        add hl,de                   ; D0 - 8Fh
        bit 7,h
        jr nz,bd_lf
        ld de,-0x131
        add hl,de
        jp c,bd_none                ; D0 >= 1C0h: past the right edge
        jr bd_v
bd_lf:  ld a,h
        cp 0xC0
        jp c,bd_slow                ; (far out)
        ld e,c
        ld d,0
        add hl,de                   ; no carry: (8Eh - D0) >> 4 >= the words, all of it left
        jp nc,bd_none
bd_v:   ld hl,(bob_y)
        ld de,(gcam_y)
        or a
        sbc hl,de                   ; D1
        bit 7,h
        jr nz,bd_up
        ld de,-0xB1
        add hl,de
        jp c,bd_none                ; D1 >= B1h: below the field
        jp bd_rec
bd_up:  ld a,(bob_d4)               ; above the top: drawn when some of its lines are not
        rlca
        rlca
        and 3
        ld e,a
        ld a,(bob_d4+1)
        add a,a
        add a,a
        or e
        ld e,a
        ld d,0                      ; DE = its height
        add hl,de
        bit 7,h
        jp nz,bd_none
        ld a,h
        or l
        jp z,bd_none
        jp bd_rec
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
        jp nc,bd_none               ; (cmp.w (SP),D2; bcc: all of it above)
        ld hl,(bd_d4)
        call bd_lines
        jp c,bd_none
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
bd_rec: ld a,(bob_skip)             ; drawn: recorded (unless this tick's picture is skipped)
        or a
        jr nz,bd_full
        ld a,(bob_n)
        cp BOB_MAX
        jr nc,bd_full
        inc a
        ld (bob_n),a
        ld de,(bob_ptr)
        push de
        ld hl,bob_a2
        ld bc,9
        ldir                        ; A2, D4, x, y (contiguous in RAM)
        ld a,(bob_cat)
        ld c,a
        add a,a
        add a,a
        add a,a
        add a,a
        ld hl,bob_mode
        or (hl)
        ld (de),a                   ; mode | category << 4
        inc de
        ld a,c
        add a,a
        add a,cat_head & 0xFF
        ld l,a
        ld h,cat_head / 256         ; (cat_head does not cross a 256-byte boundary)
        ld a,(hl)
        ld (de),a
        inc de
        inc hl
        ld a,(hl)
        ld (de),a                   ; the category's record before it
        inc de
        push hl
        ld hl,(bob_own)
        ld a,l
        ld (de),a
        inc de
        ld a,h
        ld (de),a                   ; owner
        inc de
        ld bc,(bob_lown)
        ld (bob_lown),hl
        or a
        sbc hl,bc                   ; Z: the same owner as the BOB recorded before
        ld a,0
        jr nz,bd_pn
        ld a,(bob_pno)
        inc a
bd_pn:  ld (bob_pno),a
        ld (de),a                   ; part
        inc de
        ld (bob_ptr),de
        pop hl
        pop bc
        ld (hl),b                   ; it heads its category now
        dec hl
        ld (hl),c
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
; objects 1..SPARK_OBJ-1. A BOB keeps the object its identity (category, owner, part: bd_rec)
; had in the tick shown before: the sprite engine's layouts are per object, and while a new frame
; of a BOB is on its way to VRAM, the one on screen must be the same BOB's older frame (objects
; taken in drawing order swapped legs and torsos whenever that order changed). The records,
; category by category (each one's list: the later drawn first), first take the objects of their
; identities; then the new ones take the free objects, lowest first. Each one's frame comes from
; the level's table (BOBHASH, tools/mkrom.py: A2 and D4 -> frame id); its place against the view
; as RoboCop's: map x = x - 143, map y = y. Objects left without a record are hidden and forget
; their identity. The play-field frames (the hostage, the gunners that stay put, the lifts, the
; vehicle) take no object (fb_add, field.asm), but a gunner's hit flash also takes one: its
; silhouette over the play field.
bob_flush:
        xor a
        ld (fb_n),a                 ; (the play-field BOBs of the tick: fb_add)
        ld hl,bf_claim
        ld b,MAX_OBJ
        xor a
bf_cl:  ld (hl),a
        inc hl
        djnz bf_cl
        ld (bf_nnew),a
        ld hl,obj_key + 4 + 3       ; the objects with an identity (bf_match looks at every
        ld bc,(SPARK_OBJ - 1) * 256 ; object only while some of them are not taken yet)
bf_un:  ld a,(hl)
        or a
        jr z,bf_un0
        inc c
bf_un0: inc l
        inc l
        inc l
        inc l
        djnz bf_un
        ld a,c
        ld (bf_unm),a
        ld hl,cat_head
        ld c,0                      ; category
bf_cat: ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        push bc
bf_rec: ld a,d
        or e
        jr z,bf_catx
        push de
        pop ix                      ; IX = the record
        call bf_vis
        jr c,bf_nx                  ; (not on the MSX's screen: no object)
        ld a,(ix+9)                 ; the hostage and the gunners that stay put (enemies'), the lifts
        and 0xF0                    ; and the vehicle (special), the explosion and the smoke are drawn
        cp BC_ENEMY << 4            ; into the play field (field.asm): no object
        jr z,bf_fq
        cp BC_SPECIAL << 4
        jr z,bf_fq
        cp BC_EXPL << 4
        jr nz,bf_ob
bf_fq:  call bf_fid
        cp 0xFF
        jr z,bf_ob                  ; (not one of the level's frames: hidden there)
        sub FIELD_ID0
        jr c,bf_ob
        push de
        call fb_add
        pop de
        ld a,(ix+9)                 ; a gunner's hit flash: its silhouette too, a sprite object
        and 15                      ; over the play field (bf_frame gives that frame)
        jr z,bf_nx
        inc de
        ld a,(de)
        inc a
        jr z,bf_nx
bf_ob:  call bf_match               ; A = its identity's object, or C: none
        jr c,bf_nw
        call bf_show
        jr bf_nx
bf_nw:  ld a,(bf_nnew)              ; (an object for it after the others)
        cp BOB_MAX
        jr nc,bf_nx
        inc a
        ld (bf_nnew),a
        add a,a
        add a,(bf_new - 2) & 0xFF
        ld l,a
        ld h,bf_new / 256           ; (bf_new does not cross a 256-byte boundary)
        push ix
        pop de
        ld (hl),e
        inc l
        ld (hl),d
bf_nx:  ld e,(ix+10)
        ld d,(ix+11)
        jr bf_rec
bf_catx:
        call feed_vdp               ; (the scroll engine's VDP commands)
        pop bc
        pop hl
        inc c
        ld a,c
        cp BOB_CATS
        jr c,bf_cat
        ld a,(bf_nnew)              ; the new identities take the free objects, lowest first
        or a
        jr z,bf_hide
        ld b,a
        ld hl,bf_new
        ld c,1
bf_nl:  ld e,(hl)
        inc l
        ld d,(hl)
        inc l
        push hl
        push de
        pop ix
bf_fr:  ld a,c
        cp SPARK_OBJ
        jr nc,bf_full               ; every object taken
        add a,bf_claim & 0xFF
        ld l,a
        ld h,bf_claim / 256
        inc c
        ld a,(hl)
        or a
        jr nz,bf_fr
        ld (hl),1
        ld a,c
        dec a
        push bc                     ; (bf_show uses BC)
        call bf_key
        call bf_show
        pop bc
        pop hl
        djnz bf_nl
        jr bf_hide
bf_full:
        pop hl
bf_hide:
        ld c,1                      ; the objects without a record
bf_hl:  ld a,c
        add a,bf_claim & 0xFF
        ld l,a
        ld h,bf_claim / 256
        ld a,(hl)
        or a
        jr nz,bf_hn
        ld a,c
        add a,a
        add a,a
        add a,(obj_key + 3) & 0xFF
        ld l,a
        ld h,obj_key / 256
        ld a,(hl)
        or a
        jr z,bf_hn                  ; (no identity already: hidden and forgotten then)
        ld (hl),0                   ; no identity
        ld a,1
        ld (bo_dirty),a             ; (the budget's order of importance again)
        ld a,c
        call bf_forget
        ld a,c
        call obj_hide
bf_hn:  inc c
        ld a,c
        cp SPARK_OBJ
        jr c,bf_hl
        ret

; IX = a record -> C when its BOB is wholly outside the play area the MSX shows (256 x 163, the
; left 8 columns masked; the original's field is 288 x 177): it takes no object, which the BOBs
; on screen need. Its size from D4: (words - 1) x 16 pixels, D4 >> 6 lines.
bf_vis: ld l,(ix+5)
        ld h,(ix+6)
        ld de,-135
        add hl,de
        ld de,(cam_x)
        or a
        sbc hl,de                   ; screen x
        bit 7,h
        jr nz,bv_left
        ld a,h
        or a
        scf
        ret nz                      ; at 256 or past it
        jr bv_y
bv_left:
        ex de,hl
        ld a,(ix+3)
        and 63
        dec a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; its width
        add hl,de
        ld de,-9
        add hl,de                   ; right edge - 9: negative when it ends in the masked columns
        bit 7,h
        scf
        ret nz
bv_y:   ld l,(ix+7)
        ld h,(ix+8)
        ld de,(cam_y)
        or a
        sbc hl,de                   ; screen y
        bit 7,h
        jr nz,bv_up
        ld a,h
        or a
        scf
        ret nz
        ld a,l
        cp VIEW_LINES
        ccf                         ; (C: at the play area's end or below it)
        ret
bv_up:  ex de,hl
        ld l,(ix+4)
        ld h,0
        add hl,hl
        add hl,hl
        ld a,(ix+3)
        rlca
        rlca
        and 3
        or l
        ld l,a                      ; its height
        add hl,de
        dec hl                      ; bottom edge - 1: negative when it ends above the screen
        bit 7,h
        scf
        ret nz
        or a
        ret

; IX = a record -> A = the object that showed its identity in the tick before, now taken (NC);
; C when there is none (not shown before, or that object is taken by a record of the same
; identity already). bf_htab gives the object an identity was given last (a hint, checked);
; failing that, every object is looked at.
bf_match:
        ld a,(ix+9)
        and 0xF0
        rrca
        rrca
        rrca
        rrca
        inc a
        ld e,a                      ; category + 1
        ld d,(ix+14)                ; part
        call bf_hash
        ld h,bf_htab / 256
        ld a,(hl)
        or a
        jr z,bm_scan
        cp SPARK_OBJ
        jr nc,bm_scan
        ld c,a
        call bm_try
        ld a,c
        ret z                       ; (NC)
bm_scan:
        ld a,(bf_unm)
        or a
        scf
        ret z                       ; (every identity of the tick before has its record)
        ld c,1
        ld b,SPARK_OBJ - 1
bm_lp:  call bm_try
        ld a,c
        ret z
        inc c
        djnz bm_lp
        scf
        ret

; C = object, D = part, E = category + 1, IX = a record: Z (and NC) when the object has the
; record's identity and no record took it yet (now it is taken). Keeps BC, DE.
bm_try: ld a,c
        add a,a
        add a,a
        add a,obj_key & 0xFF
        ld l,a
        ld h,obj_key / 256          ; (obj_key does not cross a 256-byte boundary)
        ld a,(hl)
        cp d
        ret nz
        inc l
        ld a,(hl)
        cp (ix+12)
        ret nz
        inc l
        ld a,(hl)
        cp (ix+13)
        ret nz
        inc l
        ld a,(hl)
        cp e
        ret nz
        ld a,c
        add a,bf_claim & 0xFF
        ld l,a
        ld h,bf_claim / 256
        ld a,(hl)
        or a
        ret nz
        inc (hl)                    ; (taken)
        ld hl,bf_unm
        dec (hl)
        xor a                       ; (Z, NC)
        ret

; IX = a record, D = part, E = category + 1 -> L = its identity's place in bf_htab. Keeps BC,
; DE.
bf_hash:
        ld a,(ix+13)
        add a,a
        xor (ix+12)
        add a,d
        add a,d
        add a,d
        ld l,a
        ld a,e
        rrca
        rrca
        rrca
        add a,l
        ld l,a
        ret

; A = object, IX = a record: the object's identity becomes the record's; what it showed and
; prepared was another BOB's (sprites.asm spr_forget). Keeps AF, BC, DE, IX.
bf_key: push af
        ld a,1
        ld (bo_dirty),a             ; (the budget's order of importance again)
        pop af
        push af
        push bc
        push de
        push af
        call bf_forget
        pop af
        call spr_forget
        ld a,(ix+9)                 ; the hint for its identity
        and 0xF0
        rrca
        rrca
        rrca
        rrca
        inc a
        ld e,a
        ld d,(ix+14)
        call bf_hash
        ld h,bf_htab / 256
        pop de
        pop bc
        pop af
        ld (hl),a
        push af
        add a,a
        add a,a
        add a,obj_key & 0xFF
        ld l,a
        ld h,obj_key / 256
        ld a,(ix+14)
        ld (hl),a
        inc l
        ld a,(ix+12)
        ld (hl),a
        inc l
        ld a,(ix+13)
        ld (hl),a
        inc l
        ld a,(ix+9)
        and 0xF0
        rrca
        rrca
        rrca
        rrca
        inc a
        ld (hl),a
        pop af
        ret

; A = object, IX = a BOB record: the object shows its frame (the hash table; not one of the
; level's frames: hidden) at its place. Keeps IX.
bf_show:
        ld (bf_obj),a
        add a,a                     ; the same frame and silhouette as the tick before: only its
        ld c,a                      ; place (bf_last: A2, D4, mode of the object's last frame)
        add a,a
        add a,c                     ; * 6
        add a,bf_last & 0xFF
        ld l,a
        ld h,bf_last / 256          ; (bf_last does not cross a 256-byte boundary)
        ld (bf_lp),hl
        ld a,(ix+0)
        cp (hl)
        jr nz,bfs_new
        inc l
        ld a,(ix+1)
        cp (hl)
        jr nz,bfs_new
        inc l
        ld a,(ix+2)
        cp (hl)
        jr nz,bfs_new
        inc l
        ld a,(ix+3)
        cp (hl)
        jr nz,bfs_new
        inc l
        ld a,(ix+4)
        cp (hl)
        jr nz,bfs_new
        inc l
        ld a,(ix+9)
        and 15
        cp (hl)
        jr nz,bfs_new
        push ix
        ld a,(bf_obj)
        call obj_ix
        pop iy                      ; the record
        jp bfs_pos
bfs_new:
        ld hl,(bf_lp)               ; (remembered for the next tick)
        push ix
        pop de
        ex de,hl
        ld bc,5
        ldir
        ld a,(ix+9)
        and 15
        ld (de),a
        call bf_frame
        inc a
        jp z,bfs_none               ; not one of the level's frames
        dec a
        push af
        push ix
        ld a,(bf_obj)
        call obj_ix
        pop iy                      ; the record
        pop af
        ld l,a
        ld h,0                      ; the frame
        ld a,(iy+9)
        and 15
        ld (os_mode),a              ; (BM_NORMAL, BM_FLASH, BM_BLACK: its silhouette)
        ld a,1                      ; (a BOB)
        call obj_set
        jp bfs_pos

; IX = a BOB record -> A = the sprite frame it shows: bf_fid's, but for a play-field frame drawn
; as a silhouette (a gunner's hit flash: bob_flush) the sprite frame of that silhouette (its
; BOBHASH slot's byte after the id). Keeps IX.
bf_frame:
        call bf_fid
        cp FIELD_ID0
        ret c                       ; (a sprite frame)
        cp 0xFF
        ret z                       ; (not one of the level's frames)
        ld a,(ix+9)
        and 15
        ld a,(de)
        ret z                       ; (drawn as it is)
        inc de
        ld a,(de)
        cp 0xFF
        ret nz                      ; (its silhouette's sprite frame)
        dec de
        ld a,(de)
        ret

; IX = a BOB record -> A = its frame id in the level's table (BOBHASH: A2 and D4), FFh when it is
; not one of the level's frames, DE = that id's place in its slot; LEVEL_BANK mapped at 8000h.
; Keeps IX.
bf_fid:
        ld a,LEVEL_BANK             ; (obj_set maps the sprite banks)
        call bank_8000
        ld a,(ix+0)                 ; the slot: the XOR of the key's 5 bytes, + 256 with A2's
        ld c,a                      ; bit 4
        xor (ix+1)
        xor (ix+2)
        xor (ix+3)
        xor (ix+4)
        ld l,a
        ld a,c
        rrca
        rrca
        rrca
        rrca
        and 1
        ld h,a
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,BOBHASH
        add hl,de
bfs_lp: ld a,l
        or 5
        ld e,a
        ld d,h                      ; DE = the slot's frame id
        ld a,(de)
        cp 0xFF
        ret z                       ; an empty slot: not one of the level's frames
        ld a,(ix+0)
        cp (hl)
        jr nz,bfs_nx
        inc l
        ld a,(ix+1)
        cp (hl)
        jr nz,bfs_nx
        inc l
        ld a,(ix+2)
        cp (hl)
        jr nz,bfs_nx
        inc l
        ld a,(ix+3)
        cp (hl)
        jr nz,bfs_nx
        inc l
        ld a,(ix+4)
        cp (hl)
        jr z,bfs_got
bfs_nx: ld a,l                      ; the next slot (the table does not wrap)
        and 0xF8
        add a,8
        ld l,a
        jr nc,bfs_lp
        inc h
        jr bfs_lp
bfs_got:
        ld a,(de)
        ret

bfs_pos:
        ld l,(iy+5)
        ld h,(iy+6)
        ld de,-135
        add hl,de
        ld de,(cam_x)
        or a
        sbc hl,de                   ; screen x: x - 143 against the view, + 8 (left border)
        ex de,hl
        ld l,(iy+7)
        ld h,(iy+8)
        ld bc,(cam_y)
        or a
        sbc hl,bc
        ex de,hl                    ; DE = screen y
        call obj_pos_ix
        push iy
        pop ix
        ret
bfs_none:
        push ix
        ld a,(bf_obj)
        call bf_forget
        ld a,(bf_obj)
        call obj_hide
        pop ix
        ret

; A = play-field frame (field.asm), IX = its BOB record: into the tick's field list (fb_new: frame,
; x, y as the record has them, owner), FB_MAX at most.
fb_add: ld c,a
        ld a,(fb_n)
        cp FB_MAX
        ret nc
        inc a
        ld (fb_n),a
        dec a
        ld e,a
        add a,a
        add a,a
        add a,a
        sub e                       ; * 7
        ld e,a
        ld d,0
        ld hl,fb_new
        add hl,de
        ld (hl),c
        inc hl
        ld a,(ix+5)
        ld (hl),a
        inc hl
        ld a,(ix+6)
        ld (hl),a
        inc hl
        ld a,(ix+7)
        ld (hl),a
        inc hl
        ld a,(ix+8)
        ld (hl),a
        inc hl
        ld a,(ix+12)                ; (the owner)
        ld (hl),a
        inc hl
        ld a,(ix+13)
        ld (hl),a
        ret

; A = object: the frame it showed is not remembered (bf_show sets it again). Keeps BC, DE.
bf_forget:
        add a,a
        ld l,a
        add a,a
        add a,l
        add a,bf_last & 0xFF
        ld l,a
        ld h,bf_last / 256
        ld (hl),0xFF                ; (no A2 low byte matches: frames start at even addresses...)
        inc l
        ld (hl),0xFF
        inc l
        ld (hl),0xFF                ; (... and no A2 is FFFFFFh)
        ret
