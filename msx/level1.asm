; Game logic of level 1 (bank BANK_L1, mapped at A000h while the game ticks: logic_map).
; The bank starts with lv_htab (objects.asm): per object type 0-52 its handler and death routine,
; then lv_init (jump to the level's start).

lv_htab_l1:
        dw obj_none, death_none     ; 0
        dw obj_none, death_none     ; 1
        dw obj_none, death_none     ; 2
        dw obj_none, death_c2ee  ; 3
        dw t4, death_c31e        ; 4
        dw obj_none, death_none     ; 5
        dw obj_none, death_none     ; 6
        dw obj_none, death_none     ; 7
        dw obj_none, death_none     ; 8
        dw obj_none, death_none     ; 9
        dw obj_none, death_none     ; 10
        dw obj_none, death_none     ; 11
        dw obj_none, death_c31e  ; 12
        dw obj_none, death_c31e  ; 13
        dw obj_none, death_none     ; 14
        dw t15, death_c31e       ; 15
        dw obj_none, death_none     ; 16
        dw obj_none, death_none     ; 17
        dw t15, death_c31e       ; 18
        dw obj_none, death_none     ; 19
        dw obj_none, death_none     ; 20
        dw obj_none, death_none     ; 21
        dw obj_none, death_none     ; 22
        dw obj_none, death_c35a  ; 23
        dw t24, death_c31e       ; 24
        dw obj_none, death_c2d8  ; 25
        dw obj_none, death_c31e  ; 26
        dw obj_none, death_c2ee  ; 27
        dw t28, death_c2ee       ; 28
        dw t29, death_c2ee       ; 29
        dw t30, death_c31e       ; 30
        dw t31, death_c31e       ; 31
        dw obj_none, death_c31e  ; 32
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
        dw obj_none, death_none  ; 44
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

; The level's start (level_init $871A with the header at $8664, level 0): the lists the game
; changes are copied into RAM, the pointers patched into the code become variables.
l1_init:
        ld hl,spawn_l1
        ld de,spawn_ram
        ld bc,spawn_l1_end - spawn_l1
        ldir
        ld hl,objl_l1
        ld de,objl_ram
        ld bc,objl_l1_end - objl_l1
        ldir
        ld hl,(l1_hdr + 2)          ; (header +0: the object list, $9C18)
        ld (ac_objlA),hl
        ld hl,spawn_ram
        ld (AM + 0x0B0E),hl         ; ($B0E: the spawn list)
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
