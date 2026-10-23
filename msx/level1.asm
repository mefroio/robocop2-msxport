; Game logic of level 1 (bank BANK_L1, mapped at A000h while the game ticks: logic_map).
; The bank starts with lv_htab (objects.asm): per object type 0-52 its handler and death routine,
; then lv_init (jump to the level's start).

lv_htab_l1:
        dw obj_none, death_none     ; 0
        dw obj_none, death_none     ; 1
        dw obj_none, death_none     ; 2
        dw t3, death_c2ee        ; 3
        dw t4, death_c31e        ; 4
        dw obj_none, death_none     ; 5
        dw obj_none, death_none     ; 6
        dw obj_none, death_none     ; 7
        dw obj_none, death_none     ; 8
        dw obj_none, death_none     ; 9
        dw obj_none, death_none     ; 10
        dw obj_none, death_none     ; 11
        dw t12, death_c31e      ; 12
        dw t13, death_c31e      ; 13
        dw obj_none, death_none     ; 14
        dw t15, death_c31e       ; 15
        dw obj_none, death_none     ; 16
        dw obj_none, death_none     ; 17
        dw t15, death_c31e       ; 18
        dw obj_none, death_none     ; 19
        dw obj_none, death_none     ; 20
        dw obj_none, death_none     ; 21
        dw obj_none, death_none     ; 22
        dw t23, death_c35a      ; 23
        dw t24, death_c31e       ; 24
        dw t25, death_c2d8      ; 25
        dw t26, death_c31e      ; 26
        dw t27, death_c2ee      ; 27
        dw t28, death_c2ee       ; 28
        dw t29, death_c2ee       ; 29
        dw t30, death_c31e       ; 30
        dw t31, death_c31e       ; 31
        dw t32, death_c31e      ; 32
        dw obj_none, death_none     ; 33
        dw obj_none, death_none     ; 34
        dw obj_none, death_none     ; 35
        dw obj_none, death_none     ; 36
        dw obj_none, death_none     ; 37
        dw obj_none, death_none     ; 38
        dw obj_none, death_none     ; 39
        dw obj_none, death_none     ; 40
        dw obj_none, death_none     ; 41
        dw obj_none, death_none     ; 42
        dw obj_none, death_none     ; 43
        dw t44, death_none      ; 44
        dw t45, death_c1fc          ; 45: hostage
        dw obj_none, death_none     ; 46
        dw obj_none, death_none     ; 47
        dw obj_none, death_none     ; 48
        dw obj_none, death_none     ; 49
        dw obj_none, death_none     ; 50
        dw obj_none, death_none     ; 51
        dw obj_none, death_none     ; 52
lv_init_l1:
        jp l1_init
        jp lt0                      ; (lv_tick)
        dw hz_l1                    ; (lv_hz)

; The level's start (level_init $871A with the header at $8664, level 0): the lists the game
; changes are copied into RAM, the pointers patched into the code become variables.
l1_init:
        ld a,(lv_fresh)             ; a new level: its lists into RAM (a death keeps them)
        or a
        jr z,l1i_hdr
        xor a
        ld (lv_fresh),a
        ld hl,spawn_l1
        ld de,spawn_ram
        ld bc,spawn_l1_end - spawn_l1
        ldir
        ld hl,objl_l1
        ld de,objl_ram
        ld bc,objl_l1_end - objl_l1
        ldir
        call l1i_sp0
l1i_hdr:
        ld hl,(l1_hdr + 2)          ; (header +0: the object list, $9C18)
        ld (ac_objlA),hl
        ld hl,spawn_ram
        ld (AM + 0x0B0E),hl         ; ($B0E: the spawn list)
        ld hl,(l1_hdr + 20)         ; (header +20, +22: where the cracked wall sends RoboCop,
        ld (AM + 0x15D6),hl         ; $87A4: obj_relocate $9FC4, mapobj.asm act_10)
        ld hl,(l1_hdr + 22)
        ld (AM + 0x15D8),hl
        ld hl,(l1_hdr + 26)         ; (header +24: the marker table, $C598 and $C692)
        ld de,mk_tab - 0xC59C
        add hl,de
        ld (ac_mkptr),hl
        ld (ac_mktab),hl
        ld hl,(l1_hdr + 32)
        ld (AM + 0x16B8),hl         ; (header +32: the spawn delay)
        ld a,(l1_hdr + 34)
        ld (ac_mkmask),a            ; (header +34, the word's low byte)
        ld hl,(l1_hdr + 30)
        ld (AG + 0x804A),hl         ; (header +30: the timer, BCD minutes and seconds)
        xor a
        ld (AG + (0x804C ^ 1)),a    ; (setup_ciab_timer $F9DC: no time out)
        jp sw_init                  ; (the port: the logic shortcuts' caches from the lists)
l1i_sp0:
        ld hl,sp_l1                 ; the special objects ($8B54: $8FC0): records into RAM,
        ld de,SP_RAM
        ld bc,sp_l1_end - sp_l1
        ldir
        ld hl,spl_l1                ;   their list (longs) as MSX pointers
        ld de,sp_ptrs
l1i_sp: ld a,(hl)
        inc hl
        ld b,(hl)
        inc hl
        bit 7,b
        jr nz,l1i_spe
        ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        push hl
        ld hl,SP_RAM - 0x9018       ; (the records' first Amiga address)
        add hl,bc
        ex de,hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ex de,hl
        pop hl
        jr l1i_sp
l1i_spe:
        xor a
        ld (de),a
        inc de
        ld (de),a
        ret

; ----- the game logic's shortcuts (the port): their caches -----

; The spawn walk's candidates this tick (objects.asm uo_free): the entries the walk's window can
; reach from the camera's 64-pixel cells (sw_xm, sw_ym: a mask of entries per cell of camera x
; and per cell of camera y, tools/cellmasks.py, cells_l1.inc) or that may hold a count or their
; spawned bit (sw_dirty), as indices in the list's order, FFh after the last (sw_list). The
; others are outside the window with nothing to reset, so the walk leaves them as they are.
; Built again only when the cells or the dirty mask changed (sw_key). Also sw_bc, the walk's
; D0 + 1. Called at update_objects' start: nothing moves the camera inside it.
sw_prep:
        ld hl,(gcam_x)
        ld de,0x5E
        add hl,de
        ld (sw_bc),hl
        ld hl,(gcam_x)
        ld b,SW_XN
        call sw_cell
        ld c,a
        ld hl,(gcam_y)
        ld b,SW_YN
        call sw_cell
        ld b,a                      ; B = the y cell, C = the x cell (FFh: outside the tables)
        ld hl,sw_key
        ld a,c
        cp (hl)
        jr nz,swp_new
        inc hl
        ld a,b
        cp (hl)
        jr nz,swp_new
        inc hl
        ld de,sw_dirty
        ld a,(de)
        cp (hl)
        jr nz,swp_new
        inc hl
        inc de
        ld a,(de)
        cp (hl)
        jr nz,swp_new
        inc hl
        inc de
        ld a,(de)
        cp (hl)
        jr nz,swp_new
        inc hl
        inc de
        ld a,(de)
        cp (hl)
        ret z                       ; (the same: sw_list stands)
swp_new:
        ld hl,sw_key
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ex de,hl
        ld hl,sw_dirty
        push bc
        ld bc,4
        ldir
        pop bc
        ld hl,sw_all
        ld a,c
        cp 0xFF
        jr z,swp_x
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,sw_xm
        add hl,de
swp_x:  ld (sw_px),hl
        ld hl,sw_all
        ld a,b
        cp 0xFF
        jr z,swp_y
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,sw_ym
        add hl,de
swp_y:  ex de,hl                    ; DE = the y cell's mask
        ld hl,(sw_px)               ; HL = the x cell's
        ld ix,sw_dirty
        ld iy,sw_list
        ld c,0                      ; the index of the byte's bit 0
swp_b:  ld a,(de)
        and (hl)
        or (ix+0)
        jr z,swp_nb
        ld b,c
swp_bt: srl a
        jr nc,swp_bn
        ld (iy+0),b
        inc iy
swp_bn: inc b
        or a
        jr nz,swp_bt
swp_nb: inc hl
        inc de
        inc ix
        ld a,c
        add a,8
        ld c,a
        cp 32
        jr c,swp_b
        ld (iy+0),0xFF
        ret

; HL = a camera coordinate, B = a table's cells -> A = its 64-pixel cell (HL / 64), or FFh
; outside the table (negative, or past the last cell: the callers then take every entry). Uses E.
sw_cell:
        ld a,h
        cp 0x40
        jr nc,swc_out               ; (negative, or 4000h and more)
        ld a,l
        rlca
        rlca
        and 3
        ld e,a
        ld a,h
        add a,a
        add a,a
        or e
        cp b
        ret c
swc_out:
        ld a,0xFF
        ret

; Every life (l1_init): the lifts' rest flags cleared (special.asm sp_update: worked out again
; at their next run), the spawn walk's dirty mask from the list's contents (a death keeps the
; list: an entry counting or spawned once is dirty) and the candidates built again at the next
; tick (sw_key: no cell is FEh).
sw_init:
        ld hl,sp_rest
        ld b,SP_REST_N
        xor a
swi_r:  ld (hl),a
        inc hl
        djnz swi_r
        ld hl,sw_dirty
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        ld a,0xFE
        ld (sw_key),a
        ld hl,spawn_ram + 10
        xor a
swi_lp: ld (sw_k),a
        push af
        ld a,(hl)                   ; the count (+10, +11) and the spawned byte (+12 ^ 1)
        inc hl
        or (hl)
        inc hl
        inc hl
        or (hl)
        dec hl
        dec hl
        dec hl
        push hl
        call nz,sw_dset
        pop hl
        ld de,14
        add hl,de
        pop af
        inc a
        cp SW_N
        jr c,swi_lp
        ret

; Entry sw_k's dirty bit set (sw_dset) or cleared (sw_dclr). Both use AF, DE, HL.
sw_dset:
        call sw_dbit
        or (hl)
        ld (hl),a
        ret
sw_dclr:
        call sw_dbit
        cpl
        and (hl)
        ld (hl),a
        ret
sw_dbit:                            ; -> HL = the byte of sw_dirty with entry sw_k's bit, A = the bit
        ld a,(sw_k)
        ld e,a
        rrca
        rrca
        rrca
        and 3
        add a,sw_dirty & 0xFF       ; (sw_dirty's four bytes within one 256-byte page)
        ld l,a
        ld h,sw_dirty / 256
        ld a,e
        and 7
        ld e,a
        ld d,0
        push hl
        ld hl,sw_bits
        add hl,de
        ld a,(hl)
        pop hl
        ret
sw_bits: db 1,2,4,8,16,32,64,128

; ----- level_tick_0 ($933A): an electric beam of level 1 -----

; IX = its record (x, top y, the window's x, rows - 1). 16 frames on, 16 off ($B00 & 10h): on, RoboCop
; in its 16-pixel column ([x - 16, x)) and its rows (y .. y + (rows + 2) * 16) loses 10h energy
; with the beam's flash and sound 22h ($B30); its cells are rewritten every frame, the top from
; lt0_top by the random word, the others from lt0_body from (random + x) on; off: E800h and D00h.
lt0:    ld a,(g_frame)
        and 0x10
        jp nz,lt0_off
        ld hl,(p_x)
        ld de,0x10
        add hl,de
        ld e,(ix+0)
        ld d,(ix+1)                 ; D2 = x
        or a
        sbc hl,de
        jp m,lt0_map
        ld hl,(p_x)
        or a
        sbc hl,de
        jp p,lt0_map
        ld hl,(p_y)
        ld e,(ix+2)
        ld d,(ix+3)
        or a
        sbc hl,de                   ; D1 = y - top
        jp m,lt0_map
        ex de,hl
        ld l,(ix+6)
        ld h,(ix+7)
        inc hl
        inc hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; D7 = (rows + 2) * 16
        or a
        sbc hl,de
        jp m,lt0_map
        ld a,PAL_BEAM
        call pal_flash
        ld hl,(AM + 0x169A)
        ld de,-0x10
        add hl,de
        ld (AM + 0x169A),hl
        ld a,0x22
        ld (snd_b30),a
lt0_map:
        call lt0_cell               ; ($EF8E at x, top)
        ld a,(AM + 0x0B32)
        and 6
        ld e,a
        ld d,0
        ld hl,lt0_top
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call lt0_put
        ld a,(AM + 0x0B32)
        add a,(ix+0)                ; D3 = random + x
        ld c,a
        ld b,(ix+6)
        inc b                       ; rows + 1 (dbf)
lt0_bl: push bc
        ld a,c
        and 0x3E
        ld e,a
        ld d,0
        ld hl,lt0_body
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        call lt0_put
        pop bc
        inc c
        inc c
        djnz lt0_bl
        ret
lt0_off:
        call lt0_cell
        ld hl,0xE800
        call lt0_put
        ld b,(ix+6)
        inc b
lt0_ol: push bc
        ld hl,0x0D00
        call lt0_put
        pop bc
        djnz lt0_ol
        ret

; h_row, h_col = the cell $EF8E points at for (x, top) of the record.
lt0_cell:
        ld l,(ix+0)
        ld h,(ix+1)
        ld (t_x),hl
        ld l,(ix+2)
        ld h,(ix+3)
        ld (t_y),hl
        jp t23_cell

; HL = a map word into the cell h_row, h_col, then the next row.
lt0_put:
        ld a,(h_row)
        ld d,a
        ld a,(h_col)
        ld e,a
        call map_write_lin
        ld hl,h_row
        inc (hl)
        ret

; ----- type 3: a walker ($CB6E) -----

; walker2's legs; more than 90 pixels from RoboCop, on every 16th step it kneels (-40h + 1, the
; step counter back to 0); its torso ($4F1D6 + t3_gfx, t3_size by walker2's D2; 16 pixels
; further right when facing right) as the last part.
t3:     call walker2
        ld hl,(t_x)
        ld de,(p_x)
        or a
        sbc hl,de
        jp p,t3_d
        ex de,hl
        ld hl,0
        or a
        sbc hl,de
t3_d:   ld de,0x5A
        or a
        sbc hl,de
        jp m,t3_draw
        ld a,(ix+OS_L0)
        and 15
        jr nz,t3_draw
        ld l,(ix+OS_L40)
        ld h,(ix+OS_L40+1)
        inc hl
        ld (ix+OS_L40),l
        ld (ix+OS_L40+1),h
        xor a
        ld (ix+OS_L0),a
        ld (ix+OS_L0+1),a
t3_draw:
        ld a,(t_d2)
        ld e,a
        ld d,0
        ld hl,t3_size
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,t3_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0xF1D6
        ld a,0x04
        call a2_set
        ld hl,(t_x)
        ld a,(ix+OS_FACE)
        or a
        jr nz,t3_x
        ld de,0x10
        add hl,de
t3_x:   ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        jp bob_part2

; t_x, t_y = the slot's x, y.
t_xy:   ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ret

; The facing byte = FFh when x >= RoboCop's x, else 0 (spl) -> A, Z when 0.
t_face: ld hl,(t_x)
        ld de,(p_x)
        or a
        sbc hl,de
        ld a,0
        jp m,tf_set
        dec a
tf_set: ld (ix+OS_FACE),a
        or a
        ret

; -> A = 0 / 2 / 4: RoboCop's 32-pixel column (x & FFE0h) left of / equal to / right of the
; object's (x - 24 & FFE0h), Z when equal.
t_col:  ld hl,(t_x)
        ld de,-0x18
        add hl,de
        ld a,l
        and 0xE0
        ld l,a
        ex de,hl
        ld hl,(p_x)
        ld a,l
        and 0xE0
        ld l,a
        or a
        sbc hl,de
        ld a,2
        ret z
        ld a,0
        ret m
        ld a,4
        or a
        ret

; HL = a pointer to a word table entry -> BC = the word, HL past it.
t_word: ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        ret

; ----- type 12: a gunner behind cover ($CEF8) -----

; Its gun follows RoboCop's 32-pixel column against its own (D3 = 0 left, 2 level, 4 right).
; The cover ($567F6, 6C3h) at (x + 4, y + 15h); when ($B02 & 2Eh) = 0, the muzzle flash
; ($6C940 - 50h * D3, 402h) and a bullet (type 3, direction 10 - D3) 7 px right of it and 21h
; down; the gunner ($56076 + t12_gfx, 803h) at x + t12_dx.
t12:    call t_xy
        call t_col
        ld (t_save),a
        ld hl,(t_x)
        inc hl
        inc hl
        inc hl
        inc hl
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,0x15
        add hl,de
        ld (bob_y),hl
        ld hl,0x67F6
        ld (bob_a2),hl
        ld a,0x05
        ld (bob_a2+2),a
        ld hl,0x6C3
        ld (bob_d4),hl
        call bob_part
        ld a,(AM + 0x0B02)
        and 0x2E
        jr nz,t12_gun
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,t12_my
        add hl,de
        call t_word
        ld hl,(t_y)
        add hl,bc
        ld (bob_y),hl
        ld hl,t12_mx
        add hl,de
        call t_word
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld l,e
        ld h,d
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld c,l
        ld b,h
        add hl,hl
        add hl,hl
        add hl,bc                   ; D3 * 50h
        ex de,hl
        ld hl,0xC940
        or a
        sbc hl,de
        ld (bob_a2),hl
        ld a,0x06
        ld (bob_a2+2),a
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw
        ld hl,(bob_x)
        ld de,7
        add hl,de
        ld (eb_x),hl
        ld hl,(t_y)
        ld de,0x21
        add hl,de
        ld (eb_y),hl
        ld a,3
        ld (eb_type),a
        ld a,(t_save)
        neg
        add a,10
        ld (eb_dir),a
        call ebullet_add
t12_gun:
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,t12_dx
        add hl,de
        call t_word
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        ld hl,t12_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x6076
        ld a,0x05
        call a2_set
        ld hl,0x803
        ld (bob_d4),hl
        jp bob_part2

; ----- type 13: a gunner standing ($CE72) -----

; On its first frame it chooses its look by the frame (bit 1 of $B01: the other torso). With
; RoboCop in its 32-pixel column, every 8th frame a bullet (type 3, direction 1Ah) from
; (x + 15, y + 18h) and the drawing 1 px up; legs ($56F12, 803h) at (x + 2, y + 15h), torso
; ($56A12, + 280h for the other look) at (x, y + 7).
t13:    ld a,(ix-0x40)              ; (byte A3 - 3Fh)
        or a
        jr nz,t13_go
        ld (ix-0x40),0xFF
        ld a,(AM + (0x0B01 ^ 1))
        bit 1,a
        jr z,t13_go
        ld (ix-0x3F),0xFF           ; (byte A3 - 40h)
t13_go: call t_xy
        call t_col
        jr nz,t13_d
        ld a,(g_frame)
        and 7
        jr nz,t13_d
        ld hl,(t_x)
        ld de,0x0F
        add hl,de
        ld (eb_x),hl
        ld hl,(t_y)
        ld de,0x18
        add hl,de
        ld (eb_y),hl
        ld a,3
        ld (eb_type),a
        ld a,0x1A
        ld (eb_dir),a
        call ebullet_add
        ld hl,(t_y)
        dec hl
        ld (t_y),hl
t13_d:  ld hl,(t_x)
        inc hl
        inc hl
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,0x15
        add hl,de
        ld (bob_y),hl
        ld hl,0x6F12
        ld (bob_a2),hl
        ld a,0x05
        ld (bob_a2+2),a
        ld hl,0x803
        ld (bob_d4),hl
        call bob_part
        ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,7
        add hl,de
        ld (bob_y),hl
        ld hl,0x6A12
        ld a,(ix-0x3F)
        or a
        jr z,t13_t
        ld hl,0x6A12 + 0x280
t13_t:  ld (bob_a2),hl
        ld a,0x05
        ld (bob_a2+2),a
        ld hl,0x803
        ld (bob_d4),hl
        jp bob_part2

; ----- type 26: a gunner kneeling ($DAFA) -----

; Turned to RoboCop; every frame with (frame & 37h) = 0 a bullet (type 5 left / 6 right,
; direction 1Eh / 16h) from x - 10h / + 38h, y + 11h, its muzzle flash ($6CDA0 / + 140h, 403h) 8 px
; left and 9 up of it, and the body drawn 1 px right; the body ($3CE20, + 4B0h facing right,
; A04h).
t26:    call t_xy
        call t_face
        ld a,(g_frame)
        and 0x37
        jr nz,t26_d
        ld hl,(t_x)
        ld de,-0x18
        add hl,de
        ld bc,0x1E05                ; D7 = 1Eh, D6 = 5
        ld de,0xCDA0                ; the flash
        ld a,(ix+OS_FACE)
        or a
        jr nz,t26_l
        push de
        ld de,0x48
        add hl,de
        pop de
        ld bc,0x1606
        ld de,0xCDA0 + 0x140
t26_l:  push de
        ld de,8
        add hl,de
        ld (eb_x),hl
        ld hl,(t_y)
        ld de,0x11
        add hl,de
        ld (eb_y),hl
        ld a,c
        ld (eb_type),a
        ld a,b
        ld (eb_dir),a
        call ebullet_add
        ld hl,(eb_x)
        ld de,-8
        add hl,de
        ld (bob_x),hl
        ld hl,(eb_y)
        ld de,-9
        add hl,de
        ld (bob_y),hl
        pop hl
        ld (bob_a2),hl
        ld a,0x06
        ld (bob_a2+2),a
        ld hl,0x403
        ld (bob_d4),hl
        call bob_draw
        ld hl,(t_x)
        inc hl
        ld (t_x),hl
t26_d:  ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        ld hl,0xCE20
        ld a,(ix+OS_FACE)
        or a
        jr nz,t26_b
        ld hl,0xCE20 + 0x4B0
t26_b:  ld (bob_a2),hl
        ld a,0x03
        ld (bob_a2+2),a
        ld hl,0xA04
        ld (bob_d4),hl
        jp bob_part2

; ----- type 27: a gunner who walks and fires bursts ($D9A4) -----

; Its counter (A3) under 30h: walking (walker2, torso $406B0 / + 280h and 14h right facing
; right, bobbing by t27_dy). From 30h on it stands, its y on its cell's top, turned to RoboCop,
; the counter going round to 96h; every frame with (frame & 1Bh) = 0 it fires (type 1
; leftwards from x + 22h / type 2 rightwards from x + 4, y + 0Eh, direction 4 / 0Ch) recoiling
; 2 px, the bullet with C0h = +-9000h and E0h = (that & $B32) - 7FFFh, and the smoke
; (explosion 3 / 2) at the gun; body $3EFE0 (+ 4B0h facing right) at y + 9.
t27:    ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        ld de,0x30
        or a
        sbc hl,de
        jp m,t27_walk
        call t_xy
        ld a,(t_y)
        and 0xF0
        ld (t_y),a
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld de,0x96
        or a
        sbc hl,de
        jp m,t27_c
        ld (ix+OS_L0),0
        ld (ix+OS_L0+1),0
t27_c:  call t_face
        ld a,(g_frame)
        and 0x1B
        jp nz,t27_d
        ld hl,(t_x)
        ld de,0x22
        add hl,de
        ld bc,0x0401                ; D7 = 4, D6 = 1
        ld de,-2                    ; the recoil
        ld a,(ix+OS_FACE)
        or a
        jr z,t27_s
        ld de,-0x1E
        add hl,de
        ld bc,0x0C02
        ld de,2
t27_s:  ld (eb_x),hl
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        add hl,de
        ld (ix+OS_X),l
        ld (ix+OS_X+1),h
        ld hl,(t_y)
        ld de,0x0E
        add hl,de
        ld (eb_y),hl
        ld a,c
        ld (eb_type),a
        ld a,b
        ld (eb_dir),a
        call ebullet_add
        jr z,t27_d
        ld hl,(eb_slot)
        ld de,0xC0
        add hl,de
        ld bc,0x9000                ; C0h = 9000h (facing left) or -9000h
        ld de,0
        ld a,(ix+OS_FACE)
        or a
        jr z,t27_ax
        ld bc,0x7000
        dec de
t27_ax: ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld (hl),b
        ld de,0x1D
        add hl,de                   ; E0h
        ld de,(AM + 0x0B32)
        ld a,c
        and e
        ld e,a
        ld a,b
        and d
        ld d,a
        push hl
        ex de,hl
        ld de,-0x7FFF
        add hl,de
        ex de,hl
        pop hl
        ld a,d
        rla
        sbc a,a
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d                   ; ext.l
        ld hl,(eb_x)
        ld de,-0x30
        add hl,de
        ld bc,3
        ld a,(ix+OS_FACE)
        or a
        jr z,t27_e
        ld de,0x4A
        add hl,de
        dec c
t27_e:  ld de,(eb_y)
        ex de,hl
        ld de,-8
        add hl,de
        ex de,hl
        call expl_add
t27_d:  ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,9
        add hl,de
        ld (bob_y),hl
        ld hl,0xEFE0
        ld a,(ix+OS_FACE)
        or a
        jr nz,t27_b
        ld hl,0xEFE0 + 0x4B0
t27_b:  ld a,0x03
        ld de,0
        call a2_set
        ld hl,0xA04
        ld (bob_d4),hl
        jp bob_part2
t27_walk:
        call walker2
        ld a,(t_d2)
        and 0x0E
        ld e,a
        ld d,0
        ld hl,t27_dy
        add hl,de
        call t_word
        ld hl,(t_y)
        add hl,bc
        dec hl
        dec hl
        dec hl
        ld (bob_y),hl
        ld hl,(t_x)
        dec hl
        dec hl
        ld de,0x06B0
        ld a,(ix+OS_FACE)
        or a
        jr nz,t27_w
        ld bc,0x14
        add hl,bc
        ld de,0x06B0 + 0x280
t27_w:  ld (bob_x),hl
        ex de,hl
        ld a,0x04
        ld de,0
        call a2_set
        ld hl,0x803
        ld (bob_d4),hl
        jp bob_part2

; ----- type 25: the machine at the top ($DB70) -----

; Only when the camera is at the top (y < 20h) and no other one is about ($16D5): it stays at
; the x it appeared at, with message $DC76 then and every 64 frames. Its body ($3FEE0, + 3C0h
; when (frame & 32h) = 0; C03h) drawn normally, black, normally or white by (frame & 0Ch);
; when (frame & 32h) is not 0 the gun ($3F940, 604h) at (x - 2Ch, y + 2): on odd frames 2 px
; lower ($3F940 + 2D0h) and firing (type 7, direction 0Ch, 10h lower; C0h = -1.0, E0h = $B32 / 2).
; RoboCop touching it: a last bullet (type 17h, direction 2, E0h = 1.0), message $DC8A, full
; energy, and it is gone. -> D0 = 0 (it never leaves the screen on its own).
t25:    ld a,(ix-0x1D)              ; (byte A3 - 1Eh)
        or a
        jr nz,t25_on
        ld hl,(gcam_y)
        ld de,0x20
        or a
        sbc hl,de
        jp p,t25_gone
        ld (ix-0x1D),0xFF
        ld a,(AM + (0x16D5 ^ 1))
        or a
        jr nz,t25_gone
        dec a
        ld (AM + (0x16D5 ^ 1)),a
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (ix+OS_L40),l
        ld (ix+OS_L40+1),h
        jr t25_msg
t25_gone:
        ld a,0xFF
        ret
t25_on: ld a,(g_frame)
        and 0x3F
        jr nz,t25_dr
t25_msg:
        ld a,HUD_MSG_DC76
        call game_msg
t25_dr: ld l,(ix+OS_L40)
        ld h,(ix+OS_L40+1)
        ld (ix+OS_X),l
        ld (ix+OS_X+1),h
        ld (t_x),hl
        ld (bob_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ld (bob_y),hl
        ld a,(g_frame)
        and 0x32
        ld (t_save),a               ; D4
        ld hl,0xFEE0
        jr nz,t25_a
        ld hl,0xFEE0 + 0x3C0
t25_a:  ld (bob_a2),hl
        ld a,0x03
        ld (bob_a2+2),a
        ld hl,0xC03
        ld (bob_d4),hl
        ld a,(g_frame)
        and 0x0C
        cp 4
        jr z,t25_k
        cp 0x0C
        jr z,t25_w
        call bob_part2
        jr t25_g
t25_k:  call bob_black
        jr t25_g
t25_w:  call bob_flashd
t25_g:  ld a,(t_save)
        or a
        jr nz,t25_t
        ld hl,0xF940
        ld de,(t_y)
        ld a,(g_frame)
        rra
        jr nc,t25_gd
        ld hl,0xF940 + 0x2D0
        inc de
        inc de
        push hl
        push de
        ld hl,(t_x)
        ld (eb_x),hl
        ld hl,0x10
        add hl,de
        ld (eb_y),hl
        ld a,7
        ld (eb_type),a
        ld a,0x0C
        ld (eb_dir),a
        call ebullet_add
        jr z,t25_nb
        ld hl,(eb_slot)
        ld de,0xC0
        add hl,de
        ld (hl),0xFF
        inc hl
        ld (hl),0xFF                ; C0h's high word -1
        ld de,0x1F
        add hl,de                   ; E0h
        ld de,(AM + 0x0B32)
        sra d
        rr e
        ld a,d
        rla
        sbc a,a
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
t25_nb: pop de
        pop hl
t25_gd: ld (bob_a2),hl
        ld a,0x03
        ld (bob_a2+2),a
        ex de,hl
        inc hl
        inc hl
        ld (bob_y),hl
        ld hl,(t_x)
        ld de,-0x2C
        add hl,de
        ld (bob_x),hl
        ld hl,0x604
        ld (bob_d4),hl
        call bob_draw
t25_t:  ld a,(ix+OS_TOUCH)
        or a
        ret z                       ; (A = 0: D0 = 0)
        ld hl,(t_x)
        ld (eb_x),hl
        ld hl,(t_y)
        ld (eb_y),hl
        ld a,0x17
        ld (eb_type),a
        ld a,2
        ld (eb_dir),a
        call ebullet_add
        jr z,t25_m
        ld hl,(eb_slot)
        ld de,0xE0
        add hl,de
        ld (hl),1
        inc hl
        ld (hl),0                   ; E0h's high word 1
t25_m:  ld a,HUD_MSG_DC8A
        call game_msg
        ld hl,0x102
        ld (AM + 0x169A),hl
        ld a,0xFF
        ret

; ----- type 23: the rail crawler ($DD04) -----

; Placed first: from the camera's top-left cell (x + 70h) it looks for a cell with attribute bit
; 5 (its rail), one search per frame by its phase (3, 2, 1, 0): 18 columns right then down 10
; rows; along the row (18 cells); down 10 rows (2 columns right); along the row 10 rows lower.
; Found: it sits centred on the cell above it (and moves on in the same frame); none after the
; four: gone. Then it follows the rail at 4 px per frame: every 4th frame it turns (direction - 1,
; then + 1 until the neighbour that way of the cell under it is rail; none: back by 3), centred
; across its way. Its BOB: $3BFC0 (+ 280h on every other pair of frames), 803h.
t23:    ld a,(ix-0x3F)              ; (byte A3 - 40h)
        or a
        jr nz,t23_1
        ld (ix-0x3F),0xFF
        ld (ix-0x1F),0xFF           ; x's high byte: not placed
        ld (ix-0x7F),0xFF
        ld (ix-0x5F),3              ; (byte A3 - 60h): the turn counter
        ld (ix-0x40),3              ; (byte A3 - 3Fh): phase / direction
t23_1:  bit 7,(ix-0x1F)
        jp z,t23_mv
        ld a,(ix-0x40)
        bit 7,a
        jr z,t23_s
        ld a,0xFF                   ; no rail: gone
        ret
t23_s:  dec (ix-0x40)
        ld (t_save),a               ; D7
        ld hl,(gcam_x)
        ld a,l
        and 0xF0
        ld l,a
        ld de,0x70
        add hl,de
        ld (t_x),hl                 ; D0
        ld hl,(gcam_y)
        ld a,l
        and 0xF0
        ld l,a
        ld (t_y),hl                 ; D1
        call t23_cell               ; A0
        ld a,(t_save)
        or a
        jr nz,t23_p1
        ld a,(h_row)                ; 0: 10 rows lower, along it
        add a,10
        ld (h_row),a
        ld hl,(t_y)
        ld de,0xA0
        add hl,de
        ld (t_y),hl
        jr t23_row
t23_p1: cp 2
        jr z,t23_row
        cp 1
        jr z,t23_col
        ld a,(h_col)                ; 3: 16 columns right, down
        add a,16
        ld (h_col),a
        ld hl,(t_x)
        inc h
        ld (t_x),hl
t23_col:
        ld a,(h_col)                ; down a column (2 more right)
        add a,2
        ld (h_col),a
        ld hl,(t_x)
        ld de,0x20
        add hl,de
        ld (t_x),hl
        ld b,10
t23_cl: push bc
        ld hl,h_row
        inc (hl)
        ld hl,(t_y)
        ld de,0x10
        add hl,de
        ld (t_y),hl
        call t23_rail
        pop bc
        jr nz,t23_at
        djnz t23_cl
        xor a
        ret
t23_row:
        ld b,18
t23_rl: push bc
        ld hl,h_col
        inc (hl)
        ld hl,(t_x)
        ld de,0x10
        add hl,de
        ld (t_x),hl
        call t23_rail
        pop bc
        jr nz,t23_at
        djnz t23_rl
        xor a
        ret
t23_at: ld hl,(t_y)                 ; found: centred on the cell above
        ld de,-0x10
        add hl,de
        ld a,l
        and 0xF0
        add a,8
        ld l,a
        ld (ix+OS_Y),l
        ld (ix+OS_Y+1),h
        ld hl,(t_x)
        ld a,l
        and 0xF0
        add a,8
        ld l,a
        ld (ix+OS_X),l
        ld (ix+OS_X+1),h
t23_mv: ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,0x10
        add hl,de
        ld (t_y),hl
        call t23_cell               ; the cell under it
        ld hl,(t_x)
        ld de,(t_y)
        call cell_solid             ; ($EF8E: D1 on the cell's top when it is solid)
        ld hl,-0x10
        add hl,de
        ld (t_y),hl
        dec (ix-0x5F)
        jp p,t23_go
        dec (ix-0x40)               ; turn: the direction before, then on
        ld b,4
t23_tl: push bc
        ld a,(ix-0x40)
        and 3
        call t23_nb
        pop bc
        jr nz,t23_tf
        inc (ix-0x40)
        djnz t23_tl
        ld a,(ix-0x40)
        sub 3
        ld (ix-0x40),a
t23_tf: ld (ix-0x5F),3
        ld a,(ix-0x40)
        and 3
        ld (ix-0x40),a
t23_go: ld a,(ix-0x40)
        add a,a
        ld e,a
        ld d,0
        ld hl,t23_dx
        add hl,de
        call t_word
        ld hl,(t_x)
        ld a,b
        or c
        jr nz,t23_x
        ld a,l
        and 0xF0
        add a,8
        ld l,a
t23_x:  add hl,bc
        ld (t_x),hl
        ld (ix+OS_X),l
        ld (ix+OS_X+1),h
        ld hl,t23_dy
        add hl,de
        call t_word
        ld hl,(t_y)
        ld a,b
        or c
        jr nz,t23_y
        ld a,l
        and 0xF0
        add a,8
        ld l,a
t23_y:  add hl,bc
        ld (t_y),hl
        ld (ix+OS_Y),l
        ld (ix+OS_Y+1),h
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld de,0xBFC0
        ld a,l
        and 2
        jr z,t23_b
        ld de,0xBFC0 + 0x280
t23_b:  ld (bob_a2),de
        ld a,0x03
        ld (bob_a2+2),a
        ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        ld hl,0x803
        ld (bob_d4),hl
        jp bob_part2

; t_x, t_y (D0, D1) -> h_row, h_col: the cell $EF8E's A0 points at (row y >> 4, or 0 outside the
; map's rows; column (x >> 4) - 8).
t23_cell:
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
        ld (h_col),a
        ld hl,(t_y)
        ld a,l
        bit 7,h
        jr nz,t23c_0
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        inc h
        dec h
        jr nz,t23c_0
        cp MAP_ROWS
        jr c,t23c_r
t23c_0: xor a
t23c_r: ld (h_row),a
        ret

; -> NZ when the cell h_row, h_col is rail (attribute bit 5).
t23_rail:
        ld a,(h_row)
        ld d,a
        ld a,(h_col)
        ld e,a
        call atr_lin
        and 0x20
        ret

; A = a direction 0-3: NZ when the neighbour that way (t23_nb's offsets: a row is 140h) of the
; cell h_row, h_col is rail. Keeps the cell.
t23_nb: add a,a
        ld e,a
        ld d,0
        ld hl,t23_nbo
        add hl,de
        call t_word                 ; BC = the offset in bytes
        ld a,(h_row)
        ld d,a
        ld a,(h_col)
        ld e,a
        ld a,b
        or a
        jp m,t23n_m
        jr nz,t23n_d                ; +140h: the row below
        srl c                       ; +2: the next column
        ld a,e
        add a,c
        ld e,a
        jr t23n_t
t23n_d: inc d
        jr t23n_t
t23n_m: inc b
        jr nz,t23n_u                ; -140h: the row above
        ld a,c                      ; -2: the column before
        sra a
        add a,e
        ld e,a
        jr t23n_t
t23n_u: dec d
t23n_t: call atr_lin
        and 0x20
        ret

; HL - DE as the 68000's cmp.w (S, Z of the difference). Keeps HL, DE.
t_cmp:  push hl
        or a
        sbc hl,de
        pop hl
        ret

; ----- type 44: pickups from the sky ($EC22) -----

; Inside the vehicle's stretch (camera x 348h..49Fh, y E0h..23Fh) the camera looks higher ($B2FC
; -70h, -B0h while RoboCop rides the vehicle), and every 16th frame he rides one of these drops a
; random pickup (type 4-32, random's high byte) at x 460h + (random & 3Fh) + t44_dx, from the
; camera's top - 8, falling at 1.75 ($16D7: one per frame, the other is gone). Outside the stretch
; it is gone (offset -70h again); below y 240h it waits.
t44:    ld hl,(gcam_x)
        ld de,0x348
        call t_cmp
        jp m,t44_gone
        ld de,0x4A0
        call t_cmp
        jp p,t44_gone
        ld hl,(gcam_y)
        ld de,0xE0
        call t_cmp
        jp m,t44_gone
        ld de,0x240
        call t_cmp
        jp p,t44_out
        ld hl,-0x70
        ld (ac_camdy),hl
        ld a,(AM + (0x16D8 ^ 1))
        or a
        jr z,t44_out
        ld hl,-0xB0
        ld (ac_camdy),hl
        ld a,(g_frame)
        and 15
        jr nz,t44_out
        ld a,(AM + (0x16D7 ^ 1))
        or a
        jr nz,t44_free
        dec a
        ld (AM + (0x16D7 ^ 1)),a
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld a,l
        and 6
        ld e,a
        ld d,0
        ld hl,t44_dx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,(AM + 0x0B32)
        and 0x3F
        ld l,a
        ld h,0
        add hl,de
        ld de,0x460
        add hl,de                   ; x
        push hl
        ld hl,(gcam_y)
        ld de,-8
        add hl,de
        ld b,h
        ld c,l                      ; y
        ld a,(AM + (0x0B32 ^ 1))    ; (the byte at $B32: the word's high byte)
        and 0x1C
        add a,4
        ld e,a
        ld d,0
        pop hl
        call pickup_drop
        ld a,(ea_k)
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,AM + 0x0DA4
        add hl,de
        ld (hl),1
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0xC0                ; vy 1.75
        xor a
        ret
t44_out:
        xor a
        ld (AM + (0x16D7 ^ 1)),a
        ret
t44_gone:
        xor a
        ld (AM + (0x16D7 ^ 1)),a
t44_free:
        ld hl,-0x70
        ld (ac_camdy),hl
        ld a,0xFF
        ret

; ----- type 32: the end of level 1 ($DF6E) -----

; The camera's offsets become 80h / -30h and RoboCop stays below y 2D0h; no spawns ($16B8 0, the
; markers' mask 0). On its first frame it notes 10 more henchmen than are down ($16C2); once they
; are: no more spawns or markers, full energy, and the sequence counts (A3): every frame / 4
; below 24h its next map word (t32_map: x, y, word; column (x >> 4) - 7) with explosion 5 there
; on odd frames; at 44h the level is done ($16D0, $16C4 = 40h); every 4th frame an explosion
; (t32_ex by (A3) & 6) at x 940h + random's high byte, y 2B0h + (its low byte & 3Fh), and when
; bit 2 of the frame is set another (408h) at the camera's x + 20h + random's high byte, y 320h,
; with the controls locked ($804D, $802E cleared) and sound 2Ah unless random's high byte is
; negative. -> D0 = 0.
t32:    ld hl,0x80
        ld (ac_camdx),hl
        ld hl,-0x30
        ld (ac_camdy),hl
        ld hl,(p_y)
        ld de,0x2D0
        call t_cmp
        jp p,t32_y
        ld (p_y),de
t32_y:  ld hl,0
        ld (AM + 0x16B8),hl
        xor a
        ld (ac_mkmask),a
        ld a,(ix+OS_B3)
        or a
        jr nz,t32_w
        ld (ix+OS_B3),0xFF
        ld hl,(AM + 0x16C2)
        ld de,10
        add hl,de
        ld (ix+OS_L60+2),l
        ld (ix+OS_L60+3),h          ; (word A3 - 5Eh)
t32_w:  ld hl,(AM + 0x16C2)
        ld e,(ix+OS_L60+2)
        ld d,(ix+OS_L60+3)
        call t_cmp
        jp m,t32_end
        ld hl,-1
        ld (AM + 0x16B8),hl
        ld a,0xFF
        ld (ac_mkmask),a
        ld hl,0x100
        ld (AM + 0x169A),hl
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        srl h
        rr l
        srl h
        rr l                        ; D2 = (A3) / 4
        ld a,h
        or a
        jr nz,t32_lv
        ld a,l
        cp 0x44
        jr c,t32_m
t32_lv: ld a,(AM + (0x16D0 ^ 1))
        or a
        jr nz,t32_m
        ld de,0x40
        ld (AM + 0x16C4),de
        dec a
        ld (AM + (0x16D0 ^ 1)),a
t32_m:  ld a,h
        or a
        jr nz,t32_x
        ld a,l
        cp 0x24
        jr nc,t32_x
        add a,a
        ld e,a
        add a,a
        add a,e                     ; * 6
        ld e,a
        ld d,0
        ld hl,t32_map
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (t_x),de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (t_y),de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                      ; the map word
        push hl
        ld hl,(t_y)
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
        sub 7
        ld e,a                      ; column (x >> 4) - 7 ($37FF2)
        pop hl
        call map_write_lin
        ld a,(AM + (0x0B01 ^ 1))
        rra
        jr nc,t32_x
        ld hl,(t_x)
        ld de,(t_y)
        ld bc,5
        call expl_add
t32_x:  ld a,(g_frame)
        and 3
        jr nz,t32_end
        ld a,(AM + (0x0B32 ^ 1))    ; (the byte at $B32)
        ld l,a
        ld h,0
        ld de,0x940
        add hl,de
        push hl
        ld a,(AM + 0x0B32)          ; (the byte at $B33)
        and 0x3F
        ld e,a
        ld d,0
        ld hl,0x2B0
        add hl,de
        ex de,hl
        ld a,(ix+OS_L0)
        and 6
        ld c,a
        ld b,0
        ld hl,t32_ex
        add hl,bc
        ld c,(hl)
        inc hl
        ld b,(hl)
        pop hl
        call expl_add
        ld a,(AM + (0x0B01 ^ 1))
        bit 2,a
        jr z,t32_end
        ld a,(AM + (0x0B32 ^ 1))
        ld l,a
        ld h,0
        ld de,(gcam_x)
        add hl,de
        ld de,0x20
        add hl,de
        ld de,0x320
        ld bc,0x408
        call expl_add
        ld a,0xFF
        ld (g_lock),a
        xor a
        ld (g_joy),a
        ld a,(AM + (0x0B32 ^ 1))
        or a
        jp m,t32_end
        ld a,0x2A
        ld (snd_b30),a
t32_end:
        xor a
        ret

; ----- type 45: a hostage ($ED1E) -----

; Inside the window it waves (sound 9 every 64 frames); on its first frame its y snaps to its
; cell (+4) and the cell offset (y & 15) is its number among the level's hostages ($16DB: a
; rescued one does not come back). RoboCop touching it rescues it ($ECAC).
t45:    call obj_window
        jr c,t45_gone
        ld a,(ix+OS_B3)
        or a
        jr nz,t45_on
        ld (ix+OS_B3),0xFF
        ld a,(ix+OS_Y)
        and 15
        ld (ix+OS_YF),a
        ld (ix+OS_YF+1),0           ; (its y fraction holds the number)
        ld (ix+OS_L40),a
        ld (ix+OS_L40+1),0
        ld e,a
        ld a,(ix+OS_Y)
        and 0xF0
        add a,4
        ld (ix+OS_Y),a
        ld d,0
        ld hl,AM + 0x16DB
        add hl,de
        ld a,l
        xor 1
        ld l,a                      ; ($16DB + n: a byte)
        ld a,(hl)
        or a
        jr z,t45_on
t45_gone:
        ld a,0xFF                   ; D0 = -1: freed
        ret
t45_on: ld a,(ix+OS_TOUCH)
        or a
        jp nz,t45_save
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld a,l
        and 0x7F
        cp 0x68
        jr nz,t45_d
        ld a,9
        ld (snd_b30),a
t45_d:  ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld de,8
        add hl,de
        ld (bob_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,0x1B
        add hl,de
        ld (bob_y),hl
        ld hl,0xB31C
        ld (bob_a2),hl
        ld a,0x04
        ld (bob_a2+2),a
        ld hl,0x503
        ld (bob_d4),hl
        call bob_part               ; legs
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (bob_x),hl
        ld a,(g_frame)
        and 0x1E
        ld e,a
        ld d,0
        ld hl,t45_dy
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        add hl,bc
        ld (bob_y),hl
        ld hl,t45_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x98DC
        ld a,0x04
        call a2_set
        ld hl,0x704
        ld (bob_d4),hl
        jp bob_part2                ; waving top

; $ECAC: rescued.
t45_save:
        ld hl,0x2100
        ld (AG + 0x8032),hl         ; (move.w: key $21 new, the counts are shown next frame)
        ld e,(ix+OS_L40)
        ld d,(ix+OS_L40+1)
        ld hl,AM + 0x16DB
        add hl,de
        ld a,l
        xor 1
        ld l,a
        ld (hl),0xFF
        ld hl,(AM + 0x16BE)
        inc hl
        ld (AM + 0x16BE),hl
        ld a,HUD_MSG_ED04           ; "MAN RESCUED."
        call game_msg
        ld a,0x13
        ld (snd_b2f),a
        ld hl,(AM + 0x169A)
        ld de,0x20
        add hl,de
        ld (AM + 0x169A),hl
        jp extra_life

; ----- type 4: a gunman behind cover ($CFB0) -----

; Legs, then the torso and arm aimed at RoboCop ($D0A6, from 38h below its y); every 64th
; value of $B02 (& 3Eh = 0) the muzzle flash and a bullet (type 3) in that direction.
t4:     ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (bob_x),hl
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ld de,0x1A
        add hl,de
        ld (bob_y),hl
        ld hl,0x860A
        ld (bob_a2),hl
        ld a,0x05
        ld (bob_a2+2),a
        ld hl,0x743
        ld (bob_d4),hl
        call bob_part               ; legs
        ld hl,(t_y)
        ld de,0x38
        add hl,de
        ex de,hl
        ld hl,(t_x)
        call aim_at                 ; A = direction (D3)
        ld (t_save),a
        ld a,(AM + 0x0B02)
        and 0x3E
        jr nz,t4_torso
        ld a,(t_save)               ; fires: the muzzle flash
        ld e,a
        ld d,0
        ld hl,t4_gx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld bc,6
        add hl,bc
        ld (eb_x),hl
        ld hl,t4_gy
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_y)
        add hl,bc
        ld (bob_y),hl
        ld bc,0x0A
        add hl,bc
        ld (eb_y),hl
        ld a,(t_save)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; D3 * 16
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de                   ; D3 * 50h
        ex de,hl
        ld hl,0xC620
        ld a,0x06
        call a2_set
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw
        ld a,3
        ld (eb_type),a
        ld a,(t_save)
        ld (eb_dir),a
        call ebullet_add
t4_torso:
        ld a,(t_save)
        ld e,a
        ld d,0
        ld hl,t4_tx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,t4_ty
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_y)
        add hl,bc
        ld (bob_y),hl
        ld hl,t4_tsize
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,t4_tgfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x7192
        ld a,0x05
        call a2_set
        jp bob_part2                ; torso and arm (the result: D0)

; ----- types 15 and 18: a walking gunman ($CA78) -----
t15:    call walker1
        jp gunman_aim

; ----- type 30: a gunman walking, kneeling to shoot ($CA14) -----
t30:    call walker2
        ld a,(t_d2)
        and 0x0E
        ld e,a
        ld d,0
        ld hl,t30_dy
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(t_y)
        add hl,de
        ld (t_y),hl
        ld hl,(t_x)
        inc hl
        inc hl
        ld a,(ix+OS_FACE)
        or a
        jr z,t30_x
        ld de,-4
        add hl,de
t30_x:  ld (t_x),hl
        jp gunman_aim

; ----- type 31: a gunman standing ($CA3E): aims every frame, faces left -----
t31:    ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ld de,0x38
        add hl,de
        ex de,hl
        ld hl,(t_x)
        call aim_at
        ld (ix+OS_XF),a
        ld (ix+OS_XF+1),0
        ld (ix+OS_FACE),0xFF
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld hl,(t_x)
        ld de,8
        add hl,de
        ld (bob_x),hl
        ld hl,(t_y)
        ld de,0x17
        add hl,de
        ld (bob_y),hl
        ld hl,0x860A
        ld (bob_a2),hl
        ld a,0x05
        ld (bob_a2+2),a
        ld hl,0x743
        ld (bob_d4),hl
        call bob_part               ; legs
        jp gunman

; ----- type 24: a walker shooting sideways ($DC9C) -----
t24:    call walker1
        ld a,(g_frame)
        and 0x1B
        jp nz,t24_body
        ld hl,(t_y)
        ld de,0x0C
        add hl,de
        ld (bob_y),hl
        ld de,8
        add hl,de
        ld (eb_y),hl
        ld hl,(t_x)
        ld de,-0x16
        add hl,de
        ld bc,0x1E05                ; direction 1Eh, type 5
        ld de,0
        ld a,(ix+OS_FACE)
        or a
        jr nz,t24_f
        ld de,0x44
        add hl,de
        ld bc,0x1606
        ld de,0x140
t24_f:  ld (eb_x),hl
        ld (bob_x),hl
        ld a,c
        ld (eb_type),a
        ld a,b
        ld (eb_dir),a
        push de
        call ebullet_add
        pop de
        ld hl,0xCDA0
        ld a,0x06
        call a2_set
        ld hl,0x403
        ld (bob_d4),hl
        call bob_draw               ; the muzzle flash
t24_body:
        ld hl,(t_y)
        inc hl
        inc hl
        inc hl
        ld (bob_y),hl
        ld hl,(t_x)
        ld de,0
        ld a,(ix+OS_FACE)
        or a
        jr nz,t24_g
        ld de,0x10
        add hl,de
        ld de,0x208
t24_g:  ld (bob_x),hl
        ld hl,0xEBD0
        ld a,0x03
        call a2_set
        ld hl,0x683
        ld (bob_d4),hl
        jp bob_part2

; ----- type 28: a gun turret ($DA8C): faces RoboCop, every 48th frame a shot -----
t28:    ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld (t_y),hl
        ld hl,(t_x)
        ld de,(p_x)
        or a
        sbc hl,de
        ld a,0
        jp m,t28_f
        dec a
t28_f:  ld (ix+OS_FACE),a
        ld bc,0x2000                ; D7 = 20h, D6 = 0
        ld de,0                     ; the graphic's offset
        or a
        jr nz,t28_g
        ld bc,0x142C
        ld de,0x4B0
t28_g:  push de
        ld a,(g_frame)
        and 0x2F
        jr nz,t28_d
        push bc
        ld e,c
        ld d,0
        ld hl,(t_x)
        add hl,de
        ld de,-4
        add hl,de
        ld (eb_x),hl
        ld de,(t_y)
        ld bc,1
        call expl_add               ; type 1 at x + D6 - 4
        pop bc
        ld hl,(t_y)
        ld de,6
        add hl,de
        ld (eb_y),hl
        ld a,4
        ld (eb_type),a
        ld a,b
        ld (eb_dir),a
        call ebullet_add
        jr z,t28_d
        ld hl,(AM + 0x0B32)         ; C0h: ($B32 >> 3) sign-extended, E0h: 4000h
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        ex de,hl
        ld hl,(eb_slot)
        ld bc,0xC0
        add hl,bc
        ld a,d
        rla
        sbc a,a
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ld bc,0x1D
        add hl,bc
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0x40
t28_d:  pop de
        ld hl,(t_x)
        ld (bob_x),hl
        ld hl,(t_y)
        ld (bob_y),hl
        ld hl,0xC4C0
        ld a,0x03
        call a2_set
        ld hl,0xA04
        ld (bob_d4),hl
        jp bob_part2

; ----- type 29: a walker that stops to throw ($D876) -----
; 64 steps walking (walker1, torso by step), then 24 frames turned to RoboCop: falling or
; standing ($EF72 at y + 34h); at its 14th an aimed bullet (type 8) 0FAh px ahead and 48h up,
; with E0h = 4000h; then it walks again.
t29:    ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        ld (t_save),hl              ; D6 = (A3)
        ld de,0x40
        or a
        sbc hl,de
        jp p,t29_stop
        call walker1
        ld hl,(t_x)
        dec hl
        dec hl
        ld de,0
        ld a,(ix+OS_FACE)
        or a
        jr nz,t29_f
        inc hl
        inc hl
        inc hl
        inc hl
        ld de,0x2210
t29_f:  ld bc,0x0C
        add hl,bc
        ld (bob_x),hl
        push de
        ld a,(ix+OS_L0)
        and 0x0E
        ld e,a
        ld d,0
        ld hl,t29_dy
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_y)
        add hl,bc
        inc hl
        inc hl
        ld (bob_y),hl
        ld hl,t29_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        pop hl
        add hl,de
        ex de,hl
        ld hl,0x0BB0
        ld a,0x04
        call a2_set
        ld hl,0x603
        ld (bob_d4),hl
        jp bob_part2
t29_stop:
        ld l,(ix+OS_L0)
        ld h,(ix+OS_L0+1)
        inc hl
        ld (ix+OS_L0),l
        ld (ix+OS_L0+1),h
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld (t_x),hl
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,0x34
        add hl,de
        ld (ao_y),hl
        ex de,hl
        ld hl,(t_x)
        call obj_fall
        ld hl,-0x2D
        add hl,de
        ld (t_y),hl                 ; D1
        ld hl,(t_x)
        ld de,(p_x)
        or a
        sbc hl,de
        ld a,0
        jp m,t29_fc
        dec a
t29_fc: ld (ix+OS_FACE),a
        ld a,(t_save)
        and 0x3F
        ld (t_save),a
        cp 0x0E
        jr nz,t29_end
        ld hl,(t_x)                 ; the throw
        ld de,0x28
        add hl,de
        ld de,0xFA
        ld a,(ix+OS_FACE)
        or a
        jr z,t29_t
        ld de,-0x2C
        add hl,de
        ld de,-0xFA
t29_t:  ld (eb_x),hl
        add hl,de
        ld (eb_tx),hl
        ld hl,(t_y)
        ld de,-0x48
        add hl,de
        ld (eb_ty),hl
        ld hl,(t_y)
        ld de,6
        add hl,de
        ld (eb_y),hl
        ld a,8
        ld (eb_type),a
        ld a,0xFF
        ld (eb_dir),a
        call ebullet_add
        jr z,t29_end
        ld hl,(eb_slot)
        ld de,0xE0
        add hl,de
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0x40                ; E0h: 4000h
t29_end:
        ld a,(t_save)
        cp 0x17
        jp m,t29_k
        ld (ix+OS_L0),0
        ld (ix+OS_L0+1),0
t29_k:  ld a,(t_save)
        srl a
        and 0x3E
        ld c,a
        ld a,(ix+OS_FACE)
        or a
        ld a,c
        jr nz,t29_s
        add a,0x0E
t29_s:  ld e,a
        ld d,0
        ld hl,t29_sdx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(t_x)
        add hl,bc
        ld (bob_x),hl
        ld hl,(t_y)
        ld bc,-5
        add hl,bc
        ld (bob_y),hl
        ld hl,t29_ssize
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (bob_d4),bc
        ld hl,t29_sgfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x1150
        ld a,0x04
        call a2_set
        jp bob_part2
