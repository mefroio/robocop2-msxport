; Game logic, module 1 (bank BANK_LC1, mapped at 8000h while the game ticks: logic_map): the
; enemies (update_objects and the types' shared parts), their bullets and the explosions.
; The other modules: mapobj.asm (BANK_LC2, the map objects); helpers they share: logic.asm (fixed
; code).
; The original's routines with their variables (msx.inc AM/AG mirror: every Amiga word at its own
; address, little-endian; a long is its two words in the Amiga's order) and the original's tables
; (tools/amitab.py, analysis/amiga_tables.tsv -> at_common.inc). The level's own routines and
; data live in its bank at A000h (level1.asm), which starts with the handler table lv_htab.
;
; Enemy slots (update_objects): 5, A3 = $BE4 + 4k on the Amiga, IX = AM + $BE4 + 4k here, with the
; fields as structure-of-arrays at fixed offsets from it (OS_...).

OS_Y:       equ -0x80               ; word: y (a 16.16 long with OS_YF)
OS_YF:      equ -0x7E
OS_L60:     equ -0x60               ; long (words at -60h, -5Eh)
OS_L40:     equ -0x40               ; long
OS_X:       equ -0x20               ; word: x (a 16.16 long with OS_XF)
OS_XF:      equ -0x1E
OS_L0:      equ 0                   ; long: the type's own use (bytes +2: facing, +3)
OS_FACE:    equ 2 ^ 1               ; byte +2: FFh when spawned right of RoboCop
OS_B3:      equ 3 ^ 1               ; byte +3
OS_TYPE:    equ 0x20 ^ 1            ; byte +20h: 0 = free
OS_HP:      equ 0x21 ^ 1            ; byte +21h: hit points (bit 7: dying)
OS_FLASH:   equ 0x22 ^ 1            ; byte +22h: hit flash (the BOBs drawn as a silhouette once)
OS_TOUCH:   equ 0x23 ^ 1            ; byte +23h: RoboCop touched it ($FA7C)
; (bytes at Amiga offset d from A3 are at IX + (d ^ 1): IX is even)
OBJ_SLOTS:  equ AM + 0x0BE4
OBJ_END:    equ AM + 0x0BF8

; The level's handler table (start of each level bank, A000h): per type 0-52 the handler and the
; death routine.
lv_htab:    equ 0xA000

lv_init:    equ lv_htab + 53*4      ; jp to the level's start
lv_tick:    equ lv_init + 3         ; jp to the level's hazard handler ($91B0 + 4 * level)
lv_hz:      equ lv_init + 6         ; dw: the level's hazard list ($915E's immediate)

; The objects' part of the level's start (level_init $871A; load_level0 $8314 sets $8060).
obj_start:
        ld hl,dbg_tpl
        ld de,dbg_msg
        ld bc,20
        ldir                        ; the counts' message (written by frame_keys)
        ld hl,diff_tab
        ld (ac_diff),hl
        ld hl,0x108
        ld (ac_camdx),hl            ; (level_init $880E)
        ld hl,-0x70
        ld (ac_camdy),hl            ; ($8816)
        ld hl,0x100
        ld (AM + 0x169A),hl         ; energy ($87F0)
        ld hl,0xF0
        ld (AM + 0x169C),hl         ; the can shown ($87F6)
        ld a,0xFF
        ld (AM + (0x16AD ^ 1)),a    ; ($87DC)
        jp lv_init                  ; the level's own data (the map objects: ao_start)

death_none:
        ret

; ----- update_objects ($C3E4) -----

; Every slot in use runs its type's handler (a negative D0 frees it) or, when dying (hit points
; bit 7), adds its score, grows the spawn delay by 5Ah, counts a henchman and runs its death
; routine (then the slot is free). A free slot looks for a spawn: the level's list ($B0E, one
; pass per frame shared by the free slots: $B12), then, past its end, the spawn delay ($16B8)
; and the map's spawn markers.
update_objects:
        ld hl,(AM + 0x0B0E)
        ld (AM + 0x0B12),hl         ; the list from its start
        ld ix,OBJ_SLOTS
uo_lp:  ld (bob_own),ix             ; (the identity of its BOBs: bob.asm)
        ld a,(ix+OS_TYPE)
        or a
        if ENEMY_CAP
        jp z,uo_cap
        else
        jp z,uo_free
        endif
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,obj_desc
        add hl,de                   ; the type's record ($BEA6 + 16 t)
        bit 7,(ix+OS_HP)
        jr z,uo_run
        ld de,8
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        call add_score              ; ($F6A0, D2 = the type's score)
        ld hl,(AM + 0x16B8)
        ld de,0x5A
        add hl,de
        ld (AM + 0x16B8),hl
        ld hl,(AM + 0x16C2)
        inc hl
        ld (AM + 0x16C2),hl
        ld a,(ix+OS_TYPE)
        add a,a
        add a,a
        add a,2                     ; the death routine
        call obj_call
        ld (ix+OS_TYPE),0
        jr uo_next
uo_run: ld a,0xFF
        ld (AM + 0x16BB),a          ; (st $16BA: the word's high byte)
        ld a,(ix+OS_TYPE)
        add a,a
        add a,a
        call obj_call               ; the handler: A = D0's high byte
        or a
        jp p,uo_next
        ld (ix+OS_TYPE),0
uo_next:
        ld de,4
        add ix,de
        push ix
        pop hl
        ld de,(0 - OBJ_END) & 0xFFFF
        add hl,de
        jr nc,uo_lp
        ret

        if ENEMY_CAP
; (The port, tools/mkrom.py ENEMY_CAP: the MSX shows two large characters in full colour at
; most; with ENEMY_CAP slots in use a free slot spawns nothing, so the level's spawns wait. Only
; the enemies count: not 32, the level's end, which spawns the henchmen it waits for, nor 44,
; the ride's pickup dropper (both draw nothing), nor 45, the hostage (drawn into the play field:
; it shows together with an enemy, the user's choice).)
uo_cap: ld hl,OBJ_SLOTS + OS_TYPE
        ld de,4
        ld bc,5 * 256               ; B = slots, C = in use
uoc_lp: ld a,(hl)
        or a
        jr z,uoc_n
        cp 32
        jr z,uoc_n
        cp 44
        jr z,uoc_n
        cp 45
        jr z,uoc_n
        inc c
uoc_n:  add hl,de
        djnz uoc_lp
        ld a,c
        cp ENEMY_CAP
        jp c,uo_free
        jp uo_next
        endif

; A = offset in lv_htab: calls that routine (IX = the slot).
obj_call:
        ld l,a
        ld h,lv_htab/256
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        jp (hl)

; A free slot ($C44C): the next entries of the spawn list inside the window (x in camera x +
; 5Dh..+1AFh, y in camera y - 28h..+A8h) count down (an entry once spawned is skipped while bit 6
; of its flags is set); the first one at zero spawns here. Entries outside the window are reset.
uo_free:
        ld hl,(gcam_y)
        ld de,-0x28
        add hl,de
        ld (uo_d1),hl               ; D1
        ld de,0xD0
        add hl,de
        ld (uo_d3),hl               ; D3
        ld hl,(gcam_x)
        ld bc,0x5E
        add hl,bc
        ld b,h
        ld c,l                      ; BC = D0 + 1 (D0 = camera x + 5Dh, D2 = D0 + 152h)
        ld hl,(AM + 0x0B12)         ; (the port walks the list with HL, most entries being out
        jr uf_at                    ; of the window, and sets $B12 - the entry reached - when
uf_nxi: push iy                     ; it leaves: at a spawn or at the end)
        pop hl
        ld de,14
        add hl,de
uf_at:  ld e,(hl)
        inc hl
        ld a,(hl)
        or a
        jp m,uf_last                ; (x < 0: the end; HL = it + 1)
        ld d,a                      ; D4 = x
        ld a,e
        sub c
        ld e,a
        ld a,d
        sbc a,b                     ; x - D0 - 1: inside (cmp.w D4,D0; bpl, cmp.w D4,D2; bmi)
        jr z,uf_xin                 ; when below 152h
        dec a
        jr nz,uf_out
        ld a,e
        cp 0x52
        jr c,uf_xin
uf_out: ld de,9                     ; out of the window (HL = the entry + 1): its count reset
        add hl,de
        xor a
        ld (hl),a
        inc hl
        ld (hl),a                   ; (+10: the count)
        inc hl
        inc hl
        ld (hl),a                   ; (+12 ^ 1: bit 7 spawned)
        inc hl
        jp uf_at
uf_xin: dec hl                      ; HL = the entry
        push hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (uo_d4),de               ; D4 = x
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; D5 = y
        ld hl,(uo_d1)
        or a
        sbc hl,de
        jp p,uf_yout
        ld hl,(uo_d3)
        or a
        sbc hl,de
        jp m,uf_yout
        pop iy                      ; inside the window: IY = the entry
        bit 6,(iy+7^1)
        jr z,uf_cnt
        bit 7,(iy+12^1)
        jr nz,uf_nxi                ; spawned once already
uf_cnt: ld l,(iy+10)
        ld h,(iy+11)
        dec hl
        ld (iy+10),l
        ld (iy+11),h
        bit 7,h
        jr z,uf_nxi                 ; still counting
        set 7,(iy+12^1)
        ld l,(iy+8)
        ld h,(iy+9)
        ld (iy+10),l
        ld (iy+11),h                ; the count starts again
        ld (AM + 0x0B12),iy         ; ($B12: the entry reached)
        call slot_clear
        ld (ix+OS_Y),e
        ld (ix+OS_Y+1),d
        ld a,(iy+4^1)
        ld (ix+OS_TYPE),a           ; type
        call type_rec               ; HL = its record
        ld de,(uo_d4)
        bit 7,(iy+7^1)
        jr z,uf_x                   ; at its place, else at the screen's edge on its side:
        push hl
        ld hl,(gcam_x)
        ex de,hl
        or a
        sbc hl,de                   ; x - camera x
        ld bc,0x75
        ex de,hl
        add hl,bc
        ex de,hl                    ; D4 = camera x + 75h
        ld bc,0x120
        or a
        sbc hl,bc
        pop hl
        jp m,uf_left
        ex de,hl
        ld bc,0x136
        add hl,bc                   ; right edge
        ex de,hl
        jr uf_x
uf_left:
        push hl
        inc hl
        inc hl
        inc hl
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; the type's width
        ex de,hl
        or a
        sbc hl,bc
        ex de,hl
        pop hl
uf_x:   call slot_place
        jp uo_next
uf_yout:
        pop hl
        inc hl
        jp uf_out

; The list's end (HL = it + 1): $B12 is the last entry, unless the walk started at the end.
uf_last:
        dec hl
        ld de,(AM + 0x0B12)
        or a
        sbc hl,de
        jr z,uf_end
        add hl,de
        ld de,-14
        add hl,de
        ld (AM + 0x0B12),hl

; The list is done: the spawn delay counts down; once it is negative a map marker can spawn,
; every (mask + 1) game frames ($C53D, patched by the level and its end).
uf_end: ld hl,(AM + 0x16B8)
        bit 7,h
        jr nz,uf_mk
        dec hl
        ld (AM + 0x16B8),hl
        jp uo_next
uf_mk:  ld a,(ac_mkmask)
        ld l,a
        rla
        sbc a,a
        ld h,a                      ; moveq: sign-extended
        ld a,(g_frame)
        and l
        ld l,a
        ld a,(g_frame+1)
        and h
        or l
        jp nz,uo_next
        ; the scan ($C546): step 0..19, the cell left of the view (even steps) or right of it
        ; (odd), rows 2..11 below the view's top
        ld hl,(ac_mkstep)
        inc hl
        ld de,-20
        add hl,de
        jr nc,mk_s
        ld hl,-20
mk_s:   ld de,20
        add hl,de
        ld (ac_mkstep),hl
        ld a,l
        ld (uo_d2),a                ; D2 (0..19)
        call cam_cell               ; D = row, E = column of the view's top left
        ld bc,0x0060                ; D0
        ld a,(uo_d2)
        rra
        jr nc,mk_l
        ld bc,0x01A0
        ld a,e
        add a,20                    ; (the right edge: 20 cells on)
        ld e,a
mk_l:   ld a,(uo_d2)
        and 0xFE
        ld l,a
        rra
        add a,2
        add a,d
        ld d,a                      ; row + 2 + step / 2
        dec e                       ; column - 1 ($27E = a row and 159 cells on)
        ld a,e
        cp 0xFF
        jr nz,mk_c0
        ld e,MAP_COLS - 1           ; (the linear map: column -1 is the row above's last cell,
        dec d                       ; column 160 the next row's first)
        jr mk_c
mk_c0:  cp MAP_COLS
        jr c,mk_c
        sub MAP_COLS
        ld e,a
        inc d
mk_c:   ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,l
        add a,0x20
        ld l,a                      ; D1 = 20h + 8 (step & ~1)
        ld (uo_d0),bc
        ld (uo_d1),hl
        call atr_rc
        and 8
        jp z,uo_next
        ; $C670: the band of the marker's height chooses which types may come (bits 1, 2, 4)
        ld hl,(uo_d1)
        ld c,1
        ld de,0x50
        or a
        sbc hl,de
        jp m,mk_b
        ld c,2
        ld hl,(uo_d1)
        ld de,0x96
        or a
        sbc hl,de
        jp m,mk_b
        ld c,4
mk_b:   ld hl,(ac_mkptr)            ; the next entry of the level's marker table that allows it
mk_nx:  ld de,6
        add hl,de
mk_rd:  ld a,(hl)
        inc hl
        ld b,(hl)
        dec hl
        bit 7,b
        jr z,mk_ok
        ld hl,(ac_mktab)
        jr mk_rd
mk_ok:  and c
        jr z,mk_nx
        ld (ac_mkptr),hl
        push hl
        ld hl,(gcam_x)
        ld a,l
        and 0xF0
        ld l,a
        ld de,15
        add hl,de
        ld de,(uo_d0)
        add hl,de
        ld (uo_d0),hl               ; x = 60h or 1A0h + (camera x & ~15) + 15
        ld hl,(gcam_y)
        ld a,l
        and 0xF0
        ld l,a
        ld de,15 - 0xBE
        add hl,de
        ld de,(uo_d1)
        add hl,de                   ; y - BEh
        ld de,(gcam_ymax)
        or a
        sbc hl,de
        add hl,de
        pop iy
        jp p,uo_next                ; not below the level's lowest camera
        ld de,0xBE
        add hl,de
        ld e,(iy+4)
        ld d,(iy+5)
        or a
        sbc hl,de                   ; - the entry's y offset
        ex de,hl
        call slot_clear
        ld (ix+OS_Y),e
        ld (ix+OS_Y+1),d
        ld a,(iy+2)
        ld (ix+OS_TYPE),a
        call type_rec
        ld de,(uo_d0)
        call slot_place
        jp uo_next

; The slot's fields cleared for a new object ($C4B0). Keeps DE, IY.
slot_clear:
        xor a
        ld (ix+OS_TYPE),a
        ld (ix+OS_HP),a
        ld (ix+OS_FLASH),a
        ld (ix+OS_TOUCH),a
        ld (ix+OS_L60),a
        ld (ix+OS_L60+1),a
        ld (ix+OS_L60+2),a
        ld (ix+OS_L60+3),a
        ld (ix+OS_L40),a
        ld (ix+OS_L40+1),a
        ld (ix+OS_L40+2),a
        ld (ix+OS_L40+3),a
        ld (ix+OS_L0),a
        ld (ix+OS_L0+1),a
        ld (ix+OS_L0+2),a
        ld (ix+OS_L0+3),a
        ld (ix+OS_XF),a
        ld (ix+OS_XF+1),a
        ld (ix+OS_YF),a
        ld (ix+OS_YF+1),a
        ret

; A = type -> HL = its record ($BEA6 + 16 t). Keeps DE.
type_rec:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,obj_desc
        add hl,bc
        ret

; DE = x, HL = the type's record: x, the side RoboCop is on and the hit points of the
; difficulty ($8060: diff_tab set) for the type's index.
slot_place:
        ld (ix+OS_X),e
        ld (ix+OS_X+1),d
        push hl
        ld hl,(p_x)
        ex de,hl
        or a
        sbc hl,de
        ld a,0
        jp m,sp_f
        dec a
sp_f:   ld (ix+OS_FACE),a           ; spl: x - RoboCop's x >= 0
        pop hl
        ld de,14
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; the index ($BEB4 + 16 t)
        ld hl,(ac_diff)
        add hl,de
        ld a,(hl)
        ld (ix+OS_HP),a
        ret

; -> D = row, E = column of the map cell at the game camera's top left ($B1A, draw_background).
cam_cell:
        ld hl,(gcam_y)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld d,a
        ld hl,(gcam_x)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld e,a
        ret

; ----- score ($F6A0) -----

; IX = slot -> carry when the object is outside the window the spawns use (x in camera x +
; 5Eh..1AFh, y in camera y - 27h..A8h, $C47A; several handlers free their object outside it).
obj_window:
        ld hl,(gcam_x)
        ld de,0x5D
        add hl,de                   ; D0
        ld e,(ix+OS_X)
        ld d,(ix+OS_X+1)            ; D4
        push hl
        or a
        sbc hl,de
        pop hl
        jp p,ow_out                 ; cmp.w D4,D0; bpl
        ld bc,0x152
        add hl,bc                   ; D2
        or a
        sbc hl,de
        jp m,ow_out                 ; cmp.w D4,D2; bmi
        ld hl,(gcam_y)
        ld de,-0x28
        add hl,de                   ; D1
        ld e,(ix+OS_Y)
        ld d,(ix+OS_Y+1)            ; D5
        push hl
        or a
        sbc hl,de
        pop hl
        jp p,ow_out
        ld bc,0xD0
        add hl,bc                   ; D3
        or a
        sbc hl,de
        jp m,ow_out
        or a
        ret
ow_out: scf
        ret

; $ECD8: the tenth hostage rescued ($16BE) is an extra life ("EXTRA LIFE.", a life more, head 0
; in slot lives - 1 when that is slot 0 or 1). -> A = FFh (D0 = -1).
extra_life:
        ld hl,(AM + 0x16BE)
        ld de,10
        or a
        sbc hl,de
        jr nz,el_end
        ld a,HUD_MSG_ED11
        call game_msg
        ld hl,(AG + 0x8034)
        inc hl
        ld (AG + 0x8034),hl
        dec hl                      ; D1 = lives - 1
        ld de,2
        or a
        sbc hl,de
        jp p,el_end                 ; (cmpi.w #2,D1; bpl)
        add hl,de
        ld c,l
        xor a
        call head_draw
el_end: ld a,0xFF
        ret

; Handler of a type not ported (yet): it stays and does nothing.
obj_none:
        xor a
        ret

; ----- activate_objects ($9C06) -----

; A refill ($16AA game frames) keeps the target at 102h (flashing every 8 frames); a shown
; level below 0 kills (death flag $16CC, target 0). The shown level ($169C) moves 8 towards the
; target ($169A, both & ~7); a target of 100h or more sets both to 100h. The HUD draws the can
; from $169C (hud_energy).
en_update:
        ld hl,(AM + 0x16AA)
        ld a,h
        or l
        jr z,eu_dead
        ld de,0x102
        ld (AM + 0x169A),de
        dec hl
        ld (AM + 0x16AA),hl
        ld a,l                      ; (btst #3,$16AB: the word's low byte, after the decrement)
        and 8
        jr z,eu_dead
        ld a,PAL_REFILL
        call pal_flash
eu_dead:
        ld a,(AM + 0x169D)
        or a
        jp p,eu_step
        ld a,0xFF
        ld (AM + (0x16CC ^ 1)),a    ; the death flag
        ld hl,0
        ld (AM + 0x169A),hl
eu_step:
        ld hl,(AM + 0x169A)
        ld a,l
        and 0xF8
        ld l,a
        ld de,(AM + 0x169C)
        ld a,e
        and 0xF8
        ld e,a
        or a
        sbc hl,de
        ret z
        ld hl,(AM + 0x169C)
        ld de,-8
        jp m,eu_add
        ld de,8
eu_add: add hl,de
        ld (AM + 0x169C),hl
        ld hl,(AM + 0x169A)
        ld de,0x100
        or a
        sbc hl,de
        ret m
        ld (AM + 0x169A),de
        ld (AM + 0x169C),de
        ret

; ----- shared helpers of the enemy handlers -----

; $D0A6: HL = x, DE = y -> A = direction (word index 0-0Eh: 0 up, 4 right, 8 down, 0Ch left)
; towards RoboCop, comparing x & ~1Fh and y & ~1Fh. Keeps HL, DE, IX, IY.
aim_at: push hl
        push de
        ld c,4
        ld a,l
        and 0xE0
        ld l,a
        push hl
        ld hl,(p_x)
        ld a,l
        and 0xE0
        ld l,a
        pop de
        or a
        sbc hl,de                   ; (player x & ~1Fh) - (x & ~1Fh)
        jr z,aa_y
        jp p,aa_r
        dec c
        dec c
aa_r:   inc c
aa_y:   pop de
        push de
        ld a,e
        and 0xE0
        ld e,a
        ld hl,(p_y)
        ld a,l
        and 0xE0
        ld l,a
        or a
        sbc hl,de
        jr z,aa_t
        jp p,aa_d
        ld a,c
        sub 6
        ld c,a
aa_d:   ld a,c
        add a,3
        ld c,a
aa_t:   ld b,0
        ld hl,aim_dir
        add hl,bc
        ld a,(hl)
        pop de
        pop hl
        ret

; $F5BC: eb_x, eb_y = position (D0, D1), eb_type = bullet type (D6), eb_dir = direction (D7,
; a word index; bit 7 set: aimed at eb_tx, eb_ty) -> the first free of the 8 enemy bullets
; (A0 = $C34 + 4k: x and y longs at 0 / +20h (their fractions stay), type byte +40h, vx / vy
; longs +60h / +80h, word +A0h, longs +C0h / +E0h cleared); its sound ($B2F) by type.
; -> NZ, A = FFh (D5 = -1) and eb_slot = A0 (MSX), or Z when all are busy. Keeps IX, IY.
ebullet_add:
        ld hl,AM + 0x0C34 + (0x40 ^ 1)
        ld b,8
eba_lp: ld a,(hl)
        or a
        jr z,eba_got
        inc hl
        inc hl
        inc hl
        inc hl
        djnz eba_lp
        xor a                       ; (D5 = 0)
        ret
eba_got:
        ld de,(0 - (0x40 ^ 1)) & 0xFFFF
        add hl,de                   ; A0
        ld (eb_slot),hl
        ld de,(eb_x)
        ld (hl),e
        inc hl
        ld (hl),d
        ld de,0x1F
        add hl,de                   ; +20h
        ld de,(eb_y)
        ld (hl),e
        inc hl
        ld (hl),d
        ld de,0x20
        add hl,de                   ; the type (Amiga +40h)
        ld a,(eb_type)
        ld (hl),a
        ld de,0x5F
        add hl,de                   ; +A0h
        xor a
        ld (hl),a
        inc hl
        ld (hl),a
        ld de,0x1F
        add hl,de                   ; +C0h
        ld b,4
eba_c1: ld (hl),a
        inc hl
        djnz eba_c1
        ld de,0x1C
        add hl,de                   ; +E0h
        ld b,4
eba_c2: ld (hl),a
        inc hl
        djnz eba_c2
        ld a,(eb_type)
        ld e,a
        ld d,0
        ld hl,eb_snd
        add hl,de
        ld a,(hl)
        ld (snd_b2f),a
        ld a,(eb_dir)
        or a
        jp m,eba_aim
        ld e,a
        ld hl,eb_vx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; vx
        ld hl,eb_vy
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; vy
        ld hl,0
        ld (eb_vxf),hl
        ld (eb_vyf),hl
        jr eba_v
eba_aim:                            ; ((target - position) << 16) >> 5, as 16.16
        ld hl,(eb_tx)
        ld de,(eb_x)
        or a
        sbc hl,de
        call eba_d32
        ld (eb_vxf),de
        push hl
        ld hl,(eb_ty)
        ld de,(eb_y)
        or a
        sbc hl,de
        call eba_d32
        ld (eb_vyf),de
        ex de,hl                    ; DE = vy
        pop bc                      ; BC = vx
eba_v:  ld hl,(eb_slot)
        push de
        ld de,0x60
        add hl,de
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld de,(eb_vxf)
        ld (hl),e
        inc hl
        ld (hl),d
        ld de,0x1D
        add hl,de                   ; +80h
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld de,(eb_vyf)
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,0xFF
        or a
        ret

; HL = a signed difference d -> HL = d >> 5 (arithmetic), DE = (d & 31) << 11.
eba_d32:
        ld a,l
        and 31
        add a,a
        add a,a
        add a,a
        ld d,a
        ld e,0
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        ret

; ----- death routines (update_objects runs them with D0, D1 = the slot's x, y) -----

; $C31E: an explosion (type 4) 12 px up, a sound by the game frame.
death_c31e:
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld e,(ix+OS_Y)
        ld d,(ix+OS_Y+1)
dc31e_xy:
        push hl
        ld hl,-0x0C
        add hl,de
        ex de,hl
        pop hl
        ld bc,0x0004
        call expl_add
        ld a,(g_frame)
        and 7
        ld e,a
        ld d,0
        ld hl,death_snd
        add hl,de
        ld a,(hl)
        ld (snd_b2d),a
        ret

; $C35A: an explosion (type 0) at its place.
death_c35a:
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld e,(ix+OS_Y)
        ld d,(ix+OS_Y+1)
        ld bc,0
        jp expl_add

; $C2D8: energy - 30h, "SUSPECT DESTROYED.", then $C2EE.
death_c2d8:
        ld hl,(AM + 0x169A)
        ld de,-0x30
        add hl,de
        ld (AM + 0x169A),hl
        ld a,HUD_MSG_C238
        call game_msg
; $C2EE: an explosion (type 8, 4) on the floor below it ((y + 10h) & ~0Fh) + 20h), sound 2Ah.
; (its loop over $EF8E ends at once: D7 holds the type * 16, never 0)
death_c2ee:
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,0x10
        add hl,de
        ld a,l
        and 0xF0
        ld l,a
        ld de,0x20
        add hl,de
        ex de,hl
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld a,0x2A
        ld (snd_b30),a
        ld bc,0x0408
        jp expl_add

; $C1FC: a hostage shot: energy - 20h, marked done ($16DB + its number), "PROTECT THE
; INNOCENT.", then $C31E.
death_c1fc:
        ld hl,(AM + 0x169A)
        ld de,-0x20
        add hl,de
        ld (AM + 0x169A),hl
        ld e,(ix+OS_L40)
        ld d,(ix+OS_L40+1)
        ld hl,AM + 0x16DB
        add hl,de
        ld a,l
        xor 1
        ld l,a
        ld (hl),0xFF
        ld a,HUD_MSG_C222
        call game_msg
        jp death_c31e

; ----- falling and walking ($EF72, $EF42) -----

; $EF72: HL = x, DE = y (a point under the object): when its cell is not solid ($EF8E) the
; object falls (vy += 2800h, y += vy, 16.16 longs at -60h / -80h), else vy = 0. -> DE = that
; y, snapped to the cell's top when solid; ao_row / ao_col = the cell (A0). Keeps IX.
obj_fall:
        call map_cell
        jr nc,of_air
        xor a
        ld (ix+OS_L60),a
        ld (ix+OS_L60+1),a
        ld (ix+OS_L60+2),a
        ld (ix+OS_L60+3),a
        ret
of_air: push de
        ld l,(ix+OS_L60+2)
        ld h,(ix+OS_L60+3)          ; vy's low word
        ld bc,0x2800
        add hl,bc
        ld (ix+OS_L60+2),l
        ld (ix+OS_L60+3),h
        ld c,l
        ld b,h
        ld l,(ix+OS_L60)
        ld h,(ix+OS_L60+1)
        ld de,0
        adc hl,de
        ld (ix+OS_L60),l
        ld (ix+OS_L60+1),h          ; vy's high word (+ the carry)
        ex de,hl                    ; DE:BC = vy
        ld l,(ix+OS_YF)
        ld h,(ix+OS_YF+1)
        add hl,bc
        ld (ix+OS_YF),l
        ld (ix+OS_YF+1),h
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        adc hl,de
        ld (ix+OS_Y),l
        ld (ix+OS_Y+1),h            ; y += vy
        pop de
        ret

; $EF42: A = step (D4); the cell beside the one obj_fall/map_cell found (A0), on the side the
; object faces (left when its facing byte is set), must be a walkway (attributes & 18h = 8) and
; the cell above that no wall (bit 1), else the object turns round; then x += the step.
; Keeps IX.
obj_walk:
        ld c,a
        ld b,1
        ld a,(ix+OS_FACE)
        or a
        jr z,ow_r
        ld b,-1
        ld a,c
        neg
        ld c,a
ow_r:   ld a,(ao_row)
        ld d,a
        ld a,(ao_col)
        add a,b
        ld e,a
        push bc
        push de
        call atr_lin
        pop de
        pop bc
        and 0x18
        cp 8
        jr nz,ow_turn
        dec d
        push bc
        call atr_lin
        pop bc
        and 2
        jr nz,ow_turn
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld a,c
        ld e,a
        rla
        sbc a,a
        ld d,a
        add hl,de
        ld (ix+OS_X),l
        ld (ix+OS_X+1),h
        ret
ow_turn:
        ld a,(ix+OS_FACE)
        cpl
        ld (ix+OS_FACE),a
        ret

; ----- walker $C948 -----

; One step: the counter (A3) goes on, it falls or stands ($EF72 at y + 34h), walks 4 px
; ($EF42) and draws its legs (frame per step and facing, at the x of before the step).
; -> t_x = D0 (that x), t_y = D1 (y, its point snapped, plus the step's bob), t_d2 = D2.
walker1:
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld a,l
        and 0x0E
        ld c,a
        ld a,(ix+OS_FACE)
        or a
        jr nz,wk1_f
        ld a,c
        add a,0x10
        ld c,a
wk1_f:  ld a,c
        ld (t_d2),a
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld e,(ix+OS_Y)
        ld d,(ix+OS_Y+1)
        ld (ao_y),de
        ex de,hl
        ld bc,0x34
        add hl,bc
        ld (ao_y),hl
        ex de,hl
        call obj_fall
        ld hl,-0x34
        add hl,de
        ld (t_y),hl                 ; D1
        ld a,4
        call obj_walk
        ld a,(t_d2)
        ld e,a
        ld d,0
        ld hl,wk1_size
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,wk1_dx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,(t_y)
        ld bc,0x19
        add hl,bc
        ld (bob_y),hl
        ld hl,wk1_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0xBD06
        ld a,0x04
        call a2_set
        call bob_part               ; legs
        ld a,(t_d2)
        and 0x0E
        ld e,a
        ld d,0
        ld hl,wk1_dy
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(t_y)
        add hl,de
        ld (t_y),hl
        ret

; ----- walker $CC4A -----

; As walker1, walking 3 px ($EF72 at y + 32h); kneeling while -40h counts (gunmen: $CCFA turns
; it to RoboCop and from 24h shoots every 32 frames, at 7Eh it stands up); (3,A3) set: the
; crouched legs only. -> t_x, t_y, t_d2.
walker2:
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld a,l
        and 0x0E
        ld (t_d2),a
        ld a,(ix+OS_B3)
        or a
        jr z,wk2_w
        ld hl,0x743                 ; crouched: legs $4BD06, at (x + 5, y - 4 + 17h)
        ld (bob_d4),hl
        ld hl,0xBD06
        ld (bob_a2),hl
        ld a,0x04
        ld (bob_a2+2),a
        xor a
        ld (t_d2),a
        ld hl,(t_x)
        ld de,5
        add hl,de
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,-4 + 0x17
        add hl,de
        ld (bob_y),hl
        jr wk2_draw
wk2_w:  ld a,(ix+OS_FACE)
        or a
        jr nz,wk2_f
        ld a,(t_d2)
        add a,0x14
        ld (t_d2),a
wk2_f:  ld hl,(t_y)
        ld de,0x32
        add hl,de
        ld (ao_y),hl
        ex de,hl
        ld hl,(t_x)
        call obj_fall
        ld hl,-0x32
        add hl,de
        ld (t_y),hl
        ld l,(ix+OS_L40)
        ld h,(ix+OS_L40+1)
        ld a,h
        or l
        jr z,wk2_go
        inc hl
        ld (ix+OS_L40),l
        ld (ix+OS_L40+1),h
        dec hl
        call gm_kneel               ; D3 = the counter before
        jr wk2_lg
wk2_go: ld a,3
        call obj_walk
wk2_lg: ld a,(t_d2)
        ld e,a
        ld d,0
        ld hl,wk2_size
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,wk2_dx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,(t_y)
        ld bc,0x17
        add hl,bc
        ld (bob_y),hl
        ld hl,wk2_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0xF1D6
        ld a,0x04
        call a2_set
wk2_draw:
        call bob_part               ; legs
        ld l,(ix+OS_L40)
        ld h,(ix+OS_L40+1)
        ld a,h
        or l
        ret z
        ld hl,(t_y)
        inc hl
        inc hl
        inc hl
        inc hl
        ld (t_y),hl
        ret

; $CCFA: HL = the kneeling counter (D3): faces RoboCop; legs frame 10h (+14h facing right);
; at 7Eh it stands up (-40h = 0); from 24h, every 32 frames, a bullet (type 1 right / 2 left,
; direction 4 / 0Ch, x + 30h / -4) with a spin (C0h: +-9000h) and a muzzle explosion (type 3 /
; 2).
gm_kneel:
        push hl
        ld hl,(t_x)
        ld de,(p_x)
        or a
        sbc hl,de
        ld a,0
        jp m,gk_f
        dec a
gk_f:   ld (ix+OS_FACE),a
        ld c,0x10
        or a
        jr nz,gk_f2
        ld c,0x10 + 0x14
gk_f2:  ld a,c
        ld (t_d2),a
        pop hl
        ld de,0x7E
        or a
        sbc hl,de
        jr nz,gk_24
        ld (ix+OS_L40),0
        ld (ix+OS_L40+1),0
        ret
gk_24:  add hl,de
        ld de,0x24
        or a
        sbc hl,de
        ret m
        ld a,(g_frame)
        and 0x1F
        ret nz
        ld a,(t_d2)
        add a,2
        ld (t_d2),a
        ld hl,(t_y)
        ld de,0x0B
        add hl,de
        ld (eb_y),hl
        ld hl,(t_x)
        ld de,0x30
        add hl,de
        ld bc,0x0401                ; direction 4, type 1
        ld a,(ix+OS_FACE)
        or a
        jr z,gk_r
        ld de,-0x34
        add hl,de
        ld bc,0x0C02
gk_r:   ld (eb_x),hl
        ld a,c
        ld (eb_type),a
        ld a,b
        ld (eb_dir),a
        call ebullet_add
        ret z
        ld hl,(eb_slot)
        ld de,0xC0
        add hl,de
        ld de,0x9000                ; spin 9000h (-9000h facing left)
        ld bc,0
        ld a,(ix+OS_FACE)
        or a
        jr z,gk_s
        ld de,-0x9000
        ld bc,-1
gk_s:   ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ld hl,(eb_x)
        ld de,-0x3B
        add hl,de
        ld a,(ix+OS_FACE)
        ld c,3
        or a
        jr z,gk_e
        ld de,0x5A
        add hl,de
        ld c,2
gk_e:   ld de,(eb_y)
        ex de,hl
        ld bc,-8
        add hl,bc
        ex de,hl
        ld a,(ix+OS_FACE)
        or a
        ld bc,3
        jr z,gk_e2
        ld bc,2
gk_e2:  jp expl_add

; ----- gunman ($CA7C, $CA9A): types 15, 18, 30, 31 -----

; Every 16th step it aims at RoboCop ($D0A6 from y + 38h; kept in -1Eh, the x fraction) and
; faces him; the aim is kept on its side (facing left: 9-0Eh else 0Ch; right: 0-7 else 4).
; Every 64 frames ((A3) & 3Bh = 0) unless -7Eh is set: a bullet (type 3) and the muzzle flash.
; Then the torso. t_x, t_y = D0, D1.
gunman_aim:
        ld a,(ix+OS_L0)
        and 0x0F
        jr nz,gunman
        ld hl,(t_y)
        ld de,0x38
        add hl,de
        ex de,hl
        ld hl,(t_x)
        call aim_at
        ld (ix+OS_XF),a
        ld (ix+OS_XF+1),0
        sub 8
        ld a,0
        jp m,gma_f
        dec a
gma_f:  ld (ix+OS_FACE),a
gunman: ld a,(ix+OS_XF)
        ld c,a
        ld a,(ix+OS_FACE)
        or a
        ld a,c
        jr z,gm_r
        cp 9
        jp p,gm_d                   ; (cmpi.b #9; bpl)
        ld a,0x0C
        jr gm_d
gm_r:   cp 8
        jp m,gm_d
        ld a,4
gm_d:   ld e,a
        ld d,0
        ld hl,gm_bdir
        add hl,de
        ld a,(hl)
        ld (t_save+1),a             ; D7: the bullet's direction
        ld hl,gm_dir
        add hl,de
        ld a,(hl)
        ld (t_save),a               ; D3: the drawing index
        ld a,(ix+(-0x7E ^ 1))       ; (tst.b (-7Eh,A3): the y fraction's high byte)
        or a
        jr nz,gm_torso
        ld a,(ix+OS_L0)
        and 0x3B
        jr nz,gm_torso
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,gm_bx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (eb_x),hl
        ld hl,gm_by
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_y)
        add hl,bc
        ld (eb_y),hl
        ld a,3
        ld (eb_type),a
        ld a,(t_save+1)
        ld (eb_dir),a
        call ebullet_add
        jr z,gm_torso
        ld hl,(eb_x)
        ld de,-8
        add hl,de
        ld (bob_x),hl
        ld hl,(eb_y)
        add hl,de
        ld (bob_y),hl
        ld a,(t_save+1)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de                   ; D7 * 50h
        ex de,hl
        ld hl,0xC620
        ld a,0x06
        call a2_set
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw               ; the muzzle flash
gm_torso:
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,gm_dx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        ld hl,gm_size
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,gm_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0xE466
        ld a,0x04
        call a2_set
        jp bob_part2

; ----- explosions ($F080) -----

; $D76 cycles 0..34h by 4. While $16AC (a count, high byte; low byte the type, FFh: none) runs,
; every other frame pair a chain explosion at ($16AE + rnd & 7Fh, $16B0 + $D76) with a chance of
; 48 in 128. Then the 8 explosion slots - the first 6 only, as the original does - step their
; frame every other game frame ($F07E) and are drawn; one at its last frame is freed.
expl_update:
        ld hl,(AM + 0x0D76)
        ld de,4
        add hl,de
        ld (AM + 0x0D76),hl
        ld de,(ex_lim)
        or a
        sbc hl,de
        jp m,xu_ch
        ld hl,0
        ld (AM + 0x0D76),hl
xu_ch:  ld a,(AM + (0x16AD ^ 1))
        or a
        jp m,xu_sl
        ld a,(g_frame)
        and 2
        jr z,xu_sl
        ld a,(AM + 0x0B32)
        and 0x7F
        ld l,a
        ld h,0
        ld de,(ex_lim + 2)
        or a
        sbc hl,de
        jp p,xu_sl
        add hl,de
        ld de,(AM + 0x16AE)
        add hl,de                   ; x
        push hl
        ld hl,(AM + 0x0D76)
        ld de,(AM + 0x16B0)
        add hl,de
        ex de,hl                    ; y
        pop hl
        ld a,(AM + (0x16AD ^ 1))
        ld c,a
        ld b,0
        call expl_add
        ld hl,AM + (0x16AC ^ 1)
        dec (hl)
        jr nz,xu_sl
        ld hl,0x20FF
        ld (AM + 0x16AC),hl
xu_sl:  ld hl,ac_ediv
        dec (hl)
        xor a
        ld (bob_own+1),a
xu_lp:  ld (ea_k),a
        ld (bob_own),a              ; (the identity of its BOBs: the slot, bob.asm)
        xor 1
        ld e,a
        ld d,0
        ld hl,AM + 0x0D34
        add hl,de                   ; the slot's state ($D34 + k)
        ld a,(hl)
        or a
        jp z,xu_nx
        ld c,a
        ld a,(ac_ediv)
        or a
        ld de,0x10
        jr z,xu_fr
        push hl
        add hl,de
        ld a,(hl)
        add a,c
        ld (hl),a                   ; frame += speed ($D44 + k)
        pop hl
        ld a,1
        ld (ac_ediv),a
xu_fr:  push hl
        add hl,de
        ld a,(hl)
        ld (t_save),a               ; D5 = frame
        ld e,8
        add hl,de
        cp (hl)                     ; the last frame ($D4C + k)?
        pop hl
        jr nz,xu_p
        ld (hl),0                   ; freed (still drawn now)
xu_p:   ld de,8
        add hl,de
        ld a,(hl)                   ; D5's high byte at the start ($D3C + k)
        ld (t_save+1),a
        ld a,(ea_k)
        add a,a
        ld e,a
        ld d,0
        ld hl,AM + 0x0D54
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (t_x),bc
        ld de,0x0F
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (t_y),bc
        ld a,(t_save+1)
        or a
        jr nz,xu_comp
        ld a,(t_save)
        ld l,a
        ld h,0
        add hl,hl
        ld de,ex_size
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld a,(t_save)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld de,ex_gfx
        add hl,de
        call a2_long                ; bob_a2 = the long at HL
        ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        call bob_draw
        jr xu_nx
xu_comp:                            ; ($F266) two parts from $45250 per frame - 1
        ld a,(t_save)
        dec a
        jp p,xu_c0
        xor a
xu_c0:  add a,a
        ld (t_save),a
        ld de,exc_dx
        ld bc,exc_dy
        ld hl,exc_gfx
        ld ix,exc_size
        call xu_part
        ld de,exc_dx2
        ld bc,exc_dy2
        ld hl,exc_gfx2
        ld ix,exc_size2
        call xu_part
xu_nx:  ld a,(ea_k)
        inc a
        cp 6
        jp c,xu_lp
        ret

; t_save = D5 (word index), t_x / t_y the explosion; DE / BC / HL / IX = its tables of x, y,
; graphic offset (from $45250) and size: that part drawn when its size is not 0.
xu_part:
        push ix
        ld a,(t_save)
        push de
        ld e,a
        ld d,0
        add ix,de                   ; (keeps E = D5)
        ld a,(ix+0)
        ld (bob_d4),a
        ld a,(ix+1)
        ld (bob_d4+1),a
        or (ix+0)
        pop ix                      ; (IX = the x table)
        jr z,xp_none
        push bc
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x5250
        ld a,0x04
        call a2_set
        pop hl                      ; the y table
        ld a,(t_save)
        ld e,a
        ld d,0
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_y)
        add hl,bc
        ld (bob_y),hl
        add ix,de
        ld c,(ix+0)
        ld b,(ix+1)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        pop ix
        jp bob_draw
xp_none:
        pop ix
        ret

; ----- enemy bullets ($F3CE) -----

; The 8 bullets (A0 = $C34 + 4k; here IX = A0 + 80h, so every field is in reach: x -80h, y -60h,
; type -40h, vx -20h, vy 0, animation +20h, C0h +40h, E0h +60h): vy += E0h, y += vy, vx += C0h,
; x += vx (a bullet going below x 0 is freed), y += vy once more (as the original does); on odd
; frames the animation steps (back to 0 past its limit). At (x - 8, y - 8): a wall (bit 1) ends
; it with its type's explosion (a negative explosion type goes through walls); rows outside
; 0-51 end it; else it is drawn, and freed once off the play field.
EB_X:       equ -0x80
EB_Y:       equ -0x60
EB_TYPE:    equ -0x40 ^ 1
EB_VX:      equ -0x20
EB_VY:      equ 0
EB_ANIM:    equ 0x20
EB_AX:      equ 0x40
EB_AY:      equ 0x60
eb_update:
        ld ix,AM + 0x0C34 + 0x80
        ld b,8
ebu_lp: ld (bob_own),ix             ; (the identity of its BOB: bob.asm)
        ld a,(ix+EB_TYPE)
        or a
        jp z,ebu_nx
        push bc
        ld (eb_type),a
        ld a,(ix+EB_VY+2)           ; vy += E0h (each long: high word, then low word)
        add a,(ix+EB_AY+2)
        ld (ix+EB_VY+2),a
        ld a,(ix+EB_VY+3)
        adc a,(ix+EB_AY+3)
        ld (ix+EB_VY+3),a
        ld a,(ix+EB_VY)
        adc a,(ix+EB_AY)
        ld (ix+EB_VY),a
        ld a,(ix+EB_VY+1)
        adc a,(ix+EB_AY+1)
        ld (ix+EB_VY+1),a
        call ebu_yv                 ; y += vy
        ld a,(ix+EB_VX+2)           ; vx += C0h
        add a,(ix+EB_AX+2)
        ld (ix+EB_VX+2),a
        ld a,(ix+EB_VX+3)
        adc a,(ix+EB_AX+3)
        ld (ix+EB_VX+3),a
        ld a,(ix+EB_VX)
        adc a,(ix+EB_AX)
        ld (ix+EB_VX),a
        ld a,(ix+EB_VX+1)
        adc a,(ix+EB_AX+1)
        ld (ix+EB_VX+1),a
        ld a,(ix+EB_X+2)            ; x += vx
        add a,(ix+EB_VX+2)
        ld (ix+EB_X+2),a
        ld a,(ix+EB_X+3)
        adc a,(ix+EB_VX+3)
        ld (ix+EB_X+3),a
        ld a,(ix+EB_X)
        adc a,(ix+EB_VX)
        ld (ix+EB_X),a
        ld a,(ix+EB_X+1)
        adc a,(ix+EB_VX+1)
        ld (ix+EB_X+1),a
        jp p,ebu_x
        ld (ix+EB_TYPE),0           ; (below x 0: freed, but still handled now)
ebu_x:  call ebu_yv                 ; y += vy again
        ld a,(eb_type)
        add a,a
        add a,a
        ld (t_save),a               ; D2 = type * 4
        ld e,a
        ld d,0
        ld a,(g_frame)
        rra
        jr nc,ebu_draw
        ld hl,eb_anim + 2
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; the limit
        ld l,(ix+EB_ANIM)
        ld h,(ix+EB_ANIM+1)
        push hl
        ld h,b
        ld l,c
        pop bc                      ; BC = the offset
        or a
        sbc hl,bc
        jp m,ebu_a0                 ; (limit - offset < 0: back to 0)
        ld hl,eb_anim
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        add hl,bc
        ld (ix+EB_ANIM),l
        ld (ix+EB_ANIM+1),h
        jr ebu_draw
ebu_a0: ld (ix+EB_ANIM),0
        ld (ix+EB_ANIM+1),0
ebu_draw:
        ld hl,eb_par
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc              ; D4
        ld l,(ix+EB_X)
        ld h,(ix+EB_X+1)
        ld bc,-8
        add hl,bc
        ld (t_x),hl
        ld (bob_x),hl
        ld l,(ix+EB_Y)
        ld h,(ix+EB_Y+1)
        add hl,bc
        ld (t_y),hl
        ld (bob_y),hl
        bit 7,h
        jr nz,ebu_free              ; (row < 0)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld d,a                      ; row
        ld a,h
        or a
        jr nz,ebu_free
        ld a,d
        cp 52
        jr nc,ebu_free
        ld hl,(t_x)
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
        ld e,a                      ; column (x >> 4) - 8
        call atr_lin
        and 2
        jr z,ebu_show
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,eb_par + 2
        add hl,de
        ld c,(hl)
        inc hl
        ld a,(hl)
        or a
        jp m,ebu_show               ; (it goes through walls)
        ld b,0                      ; (D5 = the explosion type, high byte 0)
        ld hl,(t_x)
        ld de,(t_y)
        call expl_add
        jr ebu_free
ebu_show:
        ld a,(t_save)
        ld l,a
        ld h,0
        ld de,eb_gfx
        add hl,de
        call a2_long
        ld e,(ix+EB_ANIM)
        ld d,(ix+EB_ANIM+1)         ; + the animation offset (adda.w)
        ld hl,(bob_a2)
        ld a,(bob_a2+2)
        call a2_set
        call bob_draw
        jr z,ebu_end
ebu_free:
        ld (ix+EB_TYPE),0
ebu_end:
        pop bc
ebu_nx: ld de,4
        add ix,de
        dec b
        jp nz,ebu_lp
        ret

; y += vy (IX = the bullet + 80h).
ebu_yv: ld a,(ix+EB_Y+2)
        add a,(ix+EB_VY+2)
        ld (ix+EB_Y+2),a
        ld a,(ix+EB_Y+3)
        adc a,(ix+EB_VY+3)
        ld (ix+EB_Y+3),a
        ld a,(ix+EB_Y)
        adc a,(ix+EB_VY)
        ld (ix+EB_Y),a
        ld a,(ix+EB_Y+1)
        adc a,(ix+EB_VY+1)
        ld (ix+EB_Y+1),a
        ret
