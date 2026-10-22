; Game logic, module 2 (bank BANK_LC2, mapped at 8000h in place of module 1 while it runs): the
; map objects of the level's object list (activate_objects $9C06 and the activators), the
; level's start for them (ao_start). Uses the helpers of logic.asm and the level bank at A000h.

; The map objects' part of the level's start (level_init $8848, after the level's data, lv_init):
; every entry of the object list but those of type 58h gets look 0 and 4 hits; then ($886E) the
; activation pass over the whole map: the camera at x 0, 12Ch... < 900h and y 0, B4h... < 300h,
; activate_objects at each.
ao_start:
        ld hl,lk_cache
        ld bc,LK_CACHE_N*2
        xor a
        call fill                   ; no look written yet
        call ao_sort                ; (the port: the entries sorted by x)
        ld iy,objl_ram
as_ol:  bit 7,(iy+1)
        jr nz,as_pass
        ld a,(iy+0)
        cp 0x58
        jr z,as_on
        ld (iy+2),0
        ld (iy+3),0
        ld (iy+4),4
        ld (iy+5),0
as_on:  ld de,12
        add iy,de
        jr as_ol
as_pass:
        ld hl,(gcam_x)
        push hl
        ld hl,(gcam_y)
        push hl
        ld hl,0
        ld (gcam_y),hl
as_py:  ld hl,0
        ld (gcam_x),hl
as_px:  call activate_objects
        ld hl,(gcam_x)
        ld de,0x12C
        add hl,de
        ld (gcam_x),hl
        ld de,-0x900
        add hl,de
        jr nc,as_px
        ld hl,(gcam_y)
        ld de,0xB4
        add hl,de
        ld (gcam_y),hl
        ld de,-0x300
        add hl,de
        jr nc,as_py
        pop hl
        ld (gcam_y),hl
        pop hl
        ld (gcam_x),hl
        ret


; The level's object list (objl_ram, 12-byte records as the mirror keeps them: type, look
; index, hits (high byte bit 7: animated), value, x, y): every entry inside the window (x in
; camera x + 60h..1ABh, y in camera y - 20h..AFh) runs its type's activator, if any, then its
; current look (a block of map words) is written into the map at its cell ($EF8E). A4 = $BD8 +
; 4k (ao_a4) goes on by 4 for each look written; while it is not $BEC the entry also fills that
; collision slot (x + 7, y, the type's flags, the entry, 5) and loses one hit when the shots hit
; it ($42,A4). Past $BEC the slots overlap the enemy slots' fields, as on the Amiga. A look of
; -1 destroys it ($F98C drops its value as a pickup) and its look index becomes negative.
activate_objects:
        xor a
        ld (AM + (0x0C18 ^ 1)),a
        ld (AM + (0x0C1C ^ 1)),a
        ld (AM + (0x0C20 ^ 1)),a
        ld hl,AM + 0x0BD8
        ld (ao_a4),hl
        call ao_cands               ; (the port: the entries with x in the window, in list order)
ao_lp:  ld hl,(ao_cnd)
        ld a,(hl)
        cp 0xFF
        ret z                       ; no candidate left
        inc hl
        ld (ao_cnd),hl
        ld (ao_curn),a
        ld l,a
        ld h,0
        push hl
        add hl,hl
        ld de,lk_cache
        add hl,de
        ld (ao_lkc),hl              ; the entry's look cache
        pop hl
        add hl,hl
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,de                   ; 12 n
        push hl
        ld de,(ac_objlA)
        add hl,de
        ld (ao_a1),hl               ; the entry's Amiga address (what the slots keep)
        pop de
        ld iy,objl_ram
        add iy,de
        ld l,(iy+8)
        ld h,(iy+9)                 ; D0 = x (inside camera x + 60h..1ABh: ao_cands)
        ld (ao_x),hl
        ld l,(iy+10)
        ld h,(iy+11)                ; D1 = y
        ld (ao_y),hl
        ld de,(gcam_y)
        or a
        sbc hl,de
        ld de,-0x20
        or a
        sbc hl,de
        jp m,ao_next
        ld de,0xD0
        or a
        sbc hl,de
        jp p,ao_next
        ld hl,(ao_x)
        ld de,(ao_y)
        call map_cell               ; ao_row, ao_col; D1 snapped to its cell's top when solid
        ld (ao_y),de
        bit 7,(iy+3)
        jp nz,ao_next               ; destroyed (look index negative)
        ld l,(iy+0)
        ld h,0
        ld de,obj_types + 0x8A
        add hl,de
        ld a,(hl)                   ; the activator ($9EC4 + offset: multiples of 4)
        or a
        jr z,ao_look
        rra
        ld e,a
        ld d,0
        ld hl,ao_acts
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        jp (hl)
ao_acts:                            ; per offset / 4 (offsets 0Ch, 20h: levels 2 and 3)
        dw ao_look, act_04, act_08, ao_look, act_10, act_14, act_18, act_1c, ao_look

; ($9C76) the default: a collision slot unless A4 is $BEC, then the look.
ao_look:
        ld hl,(ao_a4)
        ld de,(0 - (AM + 0x0BEC)) & 0xFFFF
        add hl,de
        ld a,h
        or l
        jr z,ao_get
        push ix
        ld ix,(ao_a4)
        ld hl,(ao_x)
        ld de,7
        add hl,de
        ld (ix+0),l
        ld (ix+1),h                 ; x + 7
        ld hl,(ao_y)
        ld (ix-0x60),l
        ld (ix-0x5F),h              ; y
        ld l,(ix+0x22)
        ld h,(ix+0x23)              ; the entry this slot had (its long's low word)
        ld de,(ao_a1)
        or a
        sbc hl,de
        jr nz,ao_reg
        ld a,(ix+0x20)
        or (ix+0x21)
        jr nz,ao_reg
        ld a,(ix+(0x42 ^ 1))
        or a
        jr z,ao_reg
        ld (ix+(0x42 ^ 1)),0        ; it was hit: one hit less
        ld l,(iy+4)
        ld h,(iy+5)
        dec hl
        ld (iy+4),l
        ld (iy+5),h
ao_reg: ld l,(iy+0)
        ld h,0
        ld de,obj_types + 0x88
        add hl,de
        ld a,(hl)                   ; (the flags word's low byte)
        ld (ix+(0x40 ^ 1)),a
        ld hl,(ao_a1)
        ld (ix+0x22),l
        ld (ix+0x23),h
        ld (ix+0x20),0
        ld (ix+0x21),0              ; the entry (a long: its high word 0)
        ld (ix+(0x41 ^ 1)),5
        pop ix
ao_get: call ao_lookp               ; HL = the look (Amiga address), carry: destroyed
        jr nc,ao_alive
        ld hl,(ao_a4)               ; ($9CBA) destroyed now: its slot cleared, its value dropped
        ld de,0x40 ^ 1
        add hl,de
        ld (hl),0
        ld hl,(ao_x)
        ld de,0x18
        add hl,de
        ld e,(iy+6)
        ld d,(iy+7)                 ; D2 = value
        ld bc,(ao_y)
        call pickup_drop
        ld (iy+3),0xFF              ; (st (2,A1): the look index's high byte)
        jp ao_next
ao_alive:
        ex de,hl
        ld hl,(ao_a4)
        inc hl
        inc hl
        inc hl
        inc hl
        ld (ao_a4),hl
        ex de,hl
; ($9CD2) the activators that keep no slot come here too: HL = the look (Amiga address).
ao_copy:
        bit 7,(iy+5)
        jr z,ao_cp
        ld a,(g_frame)
        rra
        jr nc,ao_cp
        ld e,(iy+2)                 ; animated: the next look from the next frame on
        ld d,(iy+3)
        inc de
        inc de
        inc de
        inc de
        ld (iy+2),e
        ld (iy+3),d
ao_cp:  ex de,hl                     ; (the port: a look already written there is not written
        ld hl,(ao_lkc)              ; again; the cells of the looks have no other writer)
        ld a,(hl)
        cp e
        jr nz,ao_lkw
        inc hl
        ld a,(hl)
        cp d
        jp z,ao_next
        dec hl
ao_lkw: ld (hl),e
        inc hl
        ld (hl),d
        ex de,hl
        ld de,obj_looks - 0xA1AA
        add hl,de                   ; the look block here
        push hl
        ld l,(iy+0)
        ld h,0
        ld de,obj_types + 0x110
        add hl,de
        ld b,(hl)                   ; width - 1
        inc hl
        inc hl
        ld c,(hl)                   ; height - 1
        pop hl
        ld a,(ao_row)
        ld d,a
        ld a,(ao_col)
        ld e,a                      ; D = row, E = column
ao_rlp: push bc
        push de
ao_clp: push bc
        push hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call map_write_lin
        pop hl
        inc hl
        inc hl
        inc e
        pop bc
        dec b
        jp p,ao_clp
        pop de
        pop bc
        inc d                       ; next row (140h bytes on: 160 cells)
        dec c
        jp p,ao_rlp
ao_next:
        jp ao_lp

; The entries are sorted by x once (ao_sort, at the level's start: so_x, so_n); the range of
; those with x in [camera x + 60h, camera x + 1ACh) follows the camera (ao_lo..ao_hi), and its
; entry numbers, sorted, are the candidates (ao_cand, FFh after the last; ao_cnd the next one).
; Entries outside that range do nothing on the Amiga, so visiting only these, in the list's
; order, is the same.
ao_cands:
        ld hl,(gcam_x)
        ld de,0x60
        add hl,de
        ld (ao_xlo),hl
        ld de,0x14C
        add hl,de
        ld (ao_xhi),hl
        ld a,(ao_lo)
        ld de,(ao_xlo)
        call ao_seek
        ld (ao_lo),a
        ld a,(ao_hi)
        ld de,(ao_xhi)
        call ao_seek
        ld (ao_hi),a
        ld hl,ao_cand
        ld (ao_cnd),hl
        ex de,hl                    ; DE = the buffer's end
        ld a,(ao_lo)
        ld c,a
        ld a,(ao_hi)
        sub c
        jr z,ac_end
        ld b,a                      ; candidates
        ld l,c
        ld h,0
        push de
        ld de,so_n
        add hl,de                   ; so_n[lo]
        pop de
ac_ins: ld a,(hl)                   ; the next one, inserted into the sorted run [ao_cand, DE)
        inc hl
        push hl
        ld h,d
        ld l,e                      ; the slot to fill
ac_sh:  ld c,a
        ld a,l
        cp ao_cand & 0xFF
        jr z,ac_put                 ; at the start
        dec hl
        ld a,(hl)
        cp c
        jr c,ac_aft                 ; (the one before is smaller: after it)
        inc hl
        ld (hl),a                   ; (bigger: one place up)
        dec hl
        ld a,c
        jr ac_sh
ac_aft: inc hl
ac_put: ld (hl),c
        inc de
        pop hl
        djnz ac_ins
ac_end: ld a,0xFF
        ld (de),a
        ret

; A = an index into so_x (the bound found last time), DE = x -> A = the first index whose x is
; DE or more (searching down, then up from there).
ao_seek:
        ld c,a
as_dn:  ld a,c
        or a
        jr z,as_up
        dec a
        call so_xat
        or a
        sbc hl,de
        jp m,as_up                  ; (the one before is below DE)
        dec c
        jr as_dn
as_up:  ld a,(ao_cnt)
        cp c
        jr z,as_end                 ; (all of them below DE)
        ld a,c
        call so_xat
        or a
        sbc hl,de
        jp p,as_end
        inc c
        jr as_up
as_end: ld a,c
        ret

; A = an index -> HL = so_x[A]. Keeps BC, DE.
so_xat: ld l,a
        ld h,0
        add hl,hl
        push de
        ld de,so_x
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        pop de
        ret

; At the level's start: so_x / so_n = the entries' x and numbers sorted by x, ao_cnt of them;
; the window's range empty.
ao_sort:
        ld iy,objl_ram
        ld c,0                      ; entry number
ast_lp: bit 7,(iy+1)
        jr nz,ast_end
        ld l,(iy+8)
        ld h,(iy+9)                 ; its x
        ld (ao_tmp),hl
        ld a,c
        ld b,a                      ; insertion place: from the end down
ast_sh: ld a,b
        or a
        jr z,ast_put
        dec a
        call so_xat                 ; the one before
        ld de,(ao_tmp)
        or a
        sbc hl,de
        jp m,ast_put                ; (smaller: stays before)
        jr z,ast_put                ; (equal: keeps the list's order)
        ld a,b                      ; bigger: one place up
        dec a
        call so_xat
        ld a,b
        call so_set
        ld a,b
        dec a
        ld e,a
        ld d,0
        ld hl,so_n
        add hl,de
        ld a,(hl)
        inc hl
        ld (hl),a
        dec b
        jr ast_sh
ast_put:
        ld hl,(ao_tmp)
        ld a,b
        call so_set
        ld e,b
        ld d,0
        ld hl,so_n
        add hl,de
        ld (hl),c
        inc c
        ld de,12
        add iy,de
        jr ast_lp
ast_end:
        ld a,c
        ld (ao_cnt),a
        xor a
        ld (ao_lo),a
        ld (ao_hi),a
        ret

; A = an index, HL = x: so_x[A] = HL. Keeps BC.
so_set: push hl
        ld l,a
        ld h,0
        add hl,hl
        ld de,so_x
        add hl,de
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        ret

; -> the entry's current look: the type's look table (+0, a long) + the look index -> carry when
; that look is negative (destroyed), else HL = its Amiga address. Keeps IY.
ao_lookp:
        ld l,(iy+0)
        ld h,0
        ld de,obj_types + 2
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; the look table (its long's low word)
        ld l,(iy+2)
        ld h,(iy+3)
        add hl,de                   ; + the look index
        ld de,obj_looks - 0xA1AA
        add hl,de
        inc hl
        ld a,(hl)                   ; the long's high byte (the high word's, little-endian)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                    ; HL = its low word
        rla
        ret                         ; carry: negative

; $9F84 (offset 4): a floor switch: RoboCop on its row ((y + 8), low byte & F0h) within x -
; 2Ah..+11h of it switches it on (hits high byte FFh, sound $E). No collision slot.
act_04: ld hl,(p_y)
        ld de,8
        add hl,de
        ld a,l
        and 0xF0
        ld l,a
        ld de,(ao_y)
        or a
        sbc hl,de
        jr nz,a04_l
        ld hl,(p_x)
        ld de,-0x2A
        add hl,de                   ; D2
        ld de,(ao_x)
        or a
        sbc hl,de
        jp p,a04_l                  ; (cmp.w D0,D2; bpl)
        ld de,0x3C
        or a
        adc hl,de
        jp m,a04_l                  ; (D2 + 3Ch - D0 < 0)
        ld (iy+5),0xFF              ; (st (4,A1))
        ld a,0x0E
        ld (snd_b2d),a
a04_l:  call ao_lookp               ; ($9FAE)
        jp nc,ao_copy
        ld (iy+3),0xFF
        jp ao_next

; $9EA4 (offset 8): at look index 4 an explosion (type 0) at x + 10h; then as the default.
act_08: ld a,(iy+2)
        cp 4
        jp nz,ao_look
        ld a,(iy+3)
        or a
        jp nz,ao_look
        ld hl,(ao_x)
        ld de,0x10
        add hl,de
        ld de,(ao_y)
        ld bc,0
        call expl_add
        jp ao_look

; $9FC4 (offset 10h): while RoboCop is in state 12/13 debris flies and $169E counts; at 50h he
; and the camera go to $15D6/$15D8 (which become 90h, 50h), state 10h is asked for, the palette
; fades in again and the entry is switched on. Then as the default. The entries after this one
; meet the new camera's window, as the Amiga's loop goes on with it (the candidates again, from
; the next entry); the scroll engine draws the new view before the next picture (jump_pend:
; rc2.asm, field.asm engines_jump).
act_10: ld a,(p_state)
        and 0xFE
        cp 0x0C
        jr nz,a10_c
        ld a,(AM + 0x0B32)          ; ($B32 & 1Fh: the random word's low byte)
        and 0x1F
        ld e,a
        ld d,0
        ld hl,(ao_x)
        add hl,de
        push hl
        ld a,(g_frame)
        and 0x3F
        ld e,a
        ld hl,(ao_y)
        add hl,de
        ex de,hl
        pop hl
        ld bc,0
        call expl_add
        ld hl,(AM + 0x169E)
        inc hl
        ld (AM + 0x169E),hl
a10_c:  ld hl,(AM + 0x169E)
        ld de,0x50
        or a
        sbc hl,de
        jp m,ao_look
        ld hl,(AM + 0x15D6)
        ld (p_x),hl
        ld (gcam_x),hl
        ld hl,(AM + 0x15D8)
        ld (p_y),hl
        ld (gcam_y),hl
        ld hl,0x90
        ld (AM + 0x15D6),hl
        ld hl,0x50
        ld (AM + 0x15D8),hl
        ld hl,0x10
        ld (p_pend),hl
        xor a
        ld (p_fade),a
        ld (AM + 0x169E),a
        ld (AM + 0x169F),a
        ld a,0xFF
        ld (p_fadein),a
        ld (iy+5),a
        ld (jump_pend),a
        call ao_cands
        ld a,(ao_curn)
        ld c,a
        ld hl,(ao_cnd)
a10_sk: ld a,(hl)                   ; (FFh, the end, is above every entry)
        cp c
        jr z,a10_n
        jr nc,a10_cd
a10_n:  inc hl
        jr a10_sk
a10_cd: ld (ao_cnd),hl
        jp ao_look

; $A038 / $A03E (offsets 14h, 18h): a conveyor belt of value + 1 cells moving left (14h) or
; right (18h): RoboCop on it ((y + 1) & F0h on its row, x + 14h within its length) is carried
; 4 px (sound $C); its phase steps by 4 and its row of map words is written (left end, the
; middles alternating, right end). No look, no slot.
act_14: ld a,-2
        jr act_cv
act_18: ld a,2
act_cv: ld (ao_dir),a
        ld e,(iy+6)
        ld d,(iy+7)
        ld (ao_len),de              ; D7 = the value
        ld hl,(p_y)
        inc hl
        ld a,l
        and 0xF0
        ld l,a
        ld de,(ao_y)
        or a
        sbc hl,de
        jr nz,acv_ph
        ld hl,(ao_len)
        inc hl
        inc hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld (ao_tmp),hl              ; D5 = (D7 + 2) << 4
        ld hl,(p_x)
        ld de,0x14
        add hl,de                   ; D2 = x + 14h
        ld de,(ao_x)
        push hl
        or a
        sbc hl,de
        pop hl
        jp m,acv_ph                 ; (cmp.w D0,D2; bmi)
        ld de,(ao_tmp)
        or a
        sbc hl,de                   ; D2 - D5
        ld de,(ao_x)
        push hl
        or a
        sbc hl,de
        pop hl
        jp p,acv_ph                 ; (bpl)
        ld de,(ao_tmp)
        add hl,de                   ; D2 again
        ld de,(ao_x)
        or a
        sbc hl,de
        jp m,acv_ph
        ld a,0x0C
        ld (snd_b2d),a
        ld hl,(p_x)
        ld de,-4
        ld a,(ao_dir)
        or a
        jp m,acv_x
        ld de,4
acv_x:  add hl,de
        ld (p_x),hl
acv_ph: ld a,(ao_dir)
        add a,a
        add a,(iy+2)                ; (add.b D4,(3,A1): the look word's low byte)
        ld (iy+2),a
        ld (iy+3),0                 ; (clr.b (2,A1))
        and 0x18
        ld e,a
        ld d,0
        ld hl,conv_words
        add hl,de                   ; A2: the phase's 4 words
        ld (ao_tmp),hl
        ld a,(ao_row)
        ld d,a
        ld a,(ao_col)
        ld e,a                      ; D = row, E = column
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call map_write_lin          ; the left end
        inc e
        ld bc,(ao_len)
acv_lp: dec bc
        ld a,b
        or c
        jr z,acv_end
        ld hl,(ao_tmp)
        inc hl
        inc hl                      ; odd: (2,A2)
        bit 0,c
        jr nz,acv_m
        inc hl
        inc hl
        inc hl
        inc hl                      ; even: (6,A2)
acv_m:  ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        push bc
        call map_write_lin
        pop bc
        inc e
        jr acv_lp
acv_end:
        ld hl,(ao_tmp)
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call map_write_lin          ; the right end
        jp ao_next

; $A0D4 (offset 1Ch): an electric barrier. Within D2h px of RoboCop it hums (sound 19h once
; every 64 frames); far, or on that frame, it is switched on (st (3,A1)). Switched on (look
; high byte: rows) it reaches one row further down per frame up to 4 rows, then switches off;
; off, it draws back. RoboCop inside it (its y 20h..50h below his, his x + 8 - 28h..+8 around
; it) is hit: flash, sound 14h, shown energy negative (dead), pushed 4 px back.
act_1c: ld hl,(p_x)
        ld de,(ao_x)
        or a
        sbc hl,de
        jp p,a1c_abs
        ex de,hl
        ld hl,0
        or a
        sbc hl,de
a1c_abs:
        ld de,0xD2
        or a
        sbc hl,de
        jp p,a1c_on
        ld hl,(g_frame)
        ld de,(ao_x)
        add hl,de
        ld a,l
        and 0x3F
        jr nz,a1c_st
        ld a,0x19
        ld (snd_b2d),a
a1c_on: ld (iy+2),0xFF              ; (st (3,A1))
a1c_st: ld a,(iy+3)                 ; (tst.b (2,A1))
        or a
        jp z,a1c_draw
        ld hl,(p_y)
        ld de,-0x20
        add hl,de
        ex de,hl                    ; D2 = y - 20h
        ld hl,(ao_y)
        push hl
        or a
        sbc hl,de
        pop hl
        jp p,a1c_draw               ; (cmp.w D2,D1; bpl)
        push hl
        ld hl,-0x30
        add hl,de
        ex de,hl                    ; D2 - 30h
        pop hl
        or a
        sbc hl,de
        jp m,a1c_draw
        ld hl,(p_x)
        ld de,8
        add hl,de
        ld de,(ao_x)
        or a
        sbc hl,de
        jp m,a1c_draw               ; (x + 8 - D0 < 0)
        ld de,0x28
        or a
        sbc hl,de
        jp p,a1c_draw               ; (x - 20h - D0 >= 0)
        ld a,PAL_ELECTRIC
        call pal_flash
        ld a,0x14
        ld (snd_b2d),a
        ld a,0xFF
        ld (AM + (0x169C ^ 1)),a    ; (st $169C: the shown energy's high byte)
        ld hl,(p_x)
        ld de,-4
        ld a,(p_state)
        rra
        jr nc,a1c_x
        ld de,4
a1c_x:  add hl,de
        ld (p_x),hl
a1c_draw:
        ld a,(iy+3)                 ; rows down (the look's high byte)
        ld b,a
        ld a,(ao_row)
        add a,b
        ld d,a
        ld a,(ao_col)
        ld e,a                      ; D = row + rows, E = column
        ld hl,0x0D00
        call map_write_lin
        inc e
        ld hl,0x7980
        call map_write_lin
        inc e
        ld hl,0x0D00
        call map_write_lin
        ld a,(iy+3)
        ld b,a
        ld a,(iy+2)                 ; (tst.b (3,A1))
        or a
        jr z,a1c_back
        ld a,b
        cp 4
        jr nz,a1c_dn
        ld (iy+2),0                 ; at 4 rows: off (clr.b (3,A1)), and back this frame
        jr a1c_back
a1c_dn: inc b
        ld (iy+3),b
        jr a1c_end
a1c_back:
        ld a,b
        or a
        jr z,a1c_end
        dec b
        ld (iy+3),b
a1c_end:
        ld a,(ao_row)
        add a,b
        ld d,a
        ld a,(ao_col)
        ld e,a
        ld hl,0xCD80
        call map_write_lin
        inc e
        ld hl,0xCE00
        call map_write_lin
        inc e
        ld hl,0xCE80
        call map_write_lin
        jp ao_next

; ----- explosions ($F366) -----

