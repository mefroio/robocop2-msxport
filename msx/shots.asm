; Game logic, module 1 (continued, BANK_LC1): RoboCop's fire, his shots and the effects.
;
;   update_player $ACEC, after the aim (player.asm pl_aim) -> pl_fire: the fire button, the
;                 weapon's shots and muzzle flash, then every shot and effect moves ($AEBA)
;   spawn_effect  $ACBC -> fx_add (also player_move $AFC4: pl_punch)
;   $AF08 shot, $AF90 the punch's hit box -> fx_shot, fx_punch
;   $BE48 -> hit_test: a point against the enemies and the map objects' collision slots
;   set_weapon $FD30, $AC9A (ammo - 1) -> set_weapon, ammo_dec
;
; Shots and effects: 8 slots, IX = AM + $15F4 + 2k: type (word: 0 none, 4 shot, 8 punch), then
; words at FX_DIR (direction 0-14: 0 up, 2 up right ... 0Eh up left; the punch counts its
; frames there), FX_X, FX_Y; the next slot to use is $1692 & 14.

FX_SLOTS:   equ AM + 0x15F4
FX_DIR:     equ 0x20
FX_X:       equ 0x40
FX_Y:       equ 0x60

; ----- update_player ($ACEC): the fire -----

; Weapon 1 (rapid fire) lets the button fire again every 4 frames ($D78 cleared). A press fires
; once: on a floor with bit 2 (but in states 14/15) it asks for state 12/13 and starts the punch
; above him; in the other states but 6, 7, 12, 13, 16, 17 ($330C0) a shot leaves from the
; offsets of the facing and aim plus the state's, with sound 4 ($B31). Weapons 1-3 use ammo
; ($8030, BCD): when there is none, weapon 0 again and nothing else this frame (the shots do not
; move: bra.w set_weapon). Weapon 2 adds two shots 4 directions apart (sound 0Bh), weapon 3
; alternates that with two shots 2 apart, which leaves D7 one direction back: its muzzle flash
; turns with it. The muzzle flash ($6B9A0 + 50h * direction) is drawn at the shot's start.
pl_fire:
        ld a,BC_EFFECT
        ld (bob_cat),a
        ld a,(AG + 0x805C)
        cp 1
        jr nz,pf_trig
        ld a,(AM + 0x0B00)
        and 3
        jr nz,pf_trig
        ld (fire_latch),a
pf_trig:
        ld a,(g_joy)
        and 0x10
        jp z,pf_release
        ld a,(fire_latch)
        or a
        jp nz,pf_fx
        dec a
        ld (fire_latch),a
        ld a,(p_floor)
        and 4
        jr z,pf_shot
        ld a,(p_state)
        and 0xFE
        cp 14
        jr z,pf_shot
        ld a,(p_state)              ; a bit-2 floor ($AD52)
        and 1
        add a,12
        ld l,a
        ld h,0
        ld (p_pend),hl
        ld l,h
        ld (p_anim),hl
        ld hl,(p_x)
        ld (pf_x),hl
        ld hl,(p_y)
        ld de,-50
        add hl,de
        ld (pf_y),hl
        ld a,(sp_d7)                ; (D7 is what the special objects $8B32 left)
        ld (pf_d7),a
        ld a,8
        call fx_add
        jp pf_fx
pf_shot:
        ld a,(p_state)
        ld c,a
        and 1
        add a,a
        add a,a
        ld b,a
        ld a,(p_aim)
        and 6
        rrca
        add a,b
        add a,a
        ld (pf_d7),a                ; D7 = ((state & 1) * 4 + (aim & 6) / 2) * 2
        ld a,c
        and 0xFE
        cp 6
        jp z,pf_release
        cp 12
        jp z,pf_release
        cp 16
        jp z,pf_release
        ld a,(pf_d7)
        ld e,a
        ld d,0
        ld hl,pf_ox
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,7
        add hl,bc
        ld (pf_x),hl
        ld hl,pf_oy
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld (pf_y),hl
        ld a,e
        cp 8
        jr nz,pf_st
        xor a
        ld (pf_d7),a                ; (facing left, aimed up: 8 -> 0)
pf_st:  ld a,(p_state)
        add a,a
        ld e,a
        ld hl,pf_sx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(pf_x)
        add hl,bc
        ld (pf_x),hl
        ld hl,pf_sy
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,(pf_y)
        add hl,bc
        ld (pf_y),hl
        ld a,(AG + 0x805C)
        or a
        jr z,pf_go
        ld hl,(AG + 0x8030)
        ld a,h
        or l
        jr nz,pf_ammo
        xor a
        jp set_weapon
pf_ammo:
        call ammo_dec
pf_go:  ld a,4
        ld (snd_b31),a
        ld hl,(p_x)
        ld de,(pf_x)
        add hl,de
        ld (pf_x),hl
        ld hl,(p_y)
        ld de,(pf_y)
        add hl,de
        ld (pf_y),hl
        ld a,4
        call fx_add
        ld a,(AG + 0x805C)
        cp 3
        jr nz,pf_w2
        ld hl,w3_alt
        ld a,(hl)
        cpl
        ld (hl),a
        or a
        jr z,pf_wide
        ld a,-2
        call pf_side
        ld a,4
        call pf_side
        ld a,(pf_d7)
        sub 4
        ld (pf_d7),a
        ld a,4
        ld (snd_b31),a
        jr pf_flash
pf_w2:  cp 2
        jr nz,pf_flash
pf_wide:
        ld a,-4
        call pf_side
        ld a,8
        call pf_side
        ld a,(pf_d7)
        sub 4
        ld (pf_d7),a
        ld a,0x0B
        ld (snd_b31),a
pf_flash:
        ld a,(pf_d7)
        and 0x0E
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
        add hl,de                   ; * 50h
        ex de,hl
        ld hl,0xB9A0
        ld a,0x06
        call a2_set
        ld hl,0x402
        ld (bob_d4),hl
        ld hl,(pf_x)
        ld (bob_x),hl
        ld hl,(pf_y)
        ld (bob_y),hl
        ld hl,0xFF00
        ld (bob_own),hl             ; (the identity of the muzzle flash: bob.asm)
        call bob_draw
        jr pf_fx
pf_release:
        xor a
        ld (fire_latch),a
pf_fx:  xor a
        ld (ht_ok),a                ; (hit_test: the boxes of this tick)
        ld ix,FX_SLOTS              ; every slot's handler ($AECA + type)
        ld b,8
pfx_lp: ld (bob_own),ix             ; (the identity of its BOBs: bob.asm)
        push bc
        ld a,(ix+0)
        cp 4
        jr nz,pfx_8
        call fx_shot
        jr pfx_nx
pfx_8:  cp 8
        call z,fx_punch
pfx_nx: pop bc
        inc ix
        inc ix
        djnz pfx_lp
        ret

; A = the change of direction: one more shot (D7 += A, then spawn_effect).
pf_side:
        ld hl,pf_d7
        add a,(hl)
        ld (hl),a
        ld a,4
        jr fx_add

; ----- player_move $AFC4: the punch of states 6/7 (at their step 4) -----

; The hit box (type 8, direction 0) 48 pixels up and ahead of him ($AFAE: +48 facing right, -16
; facing left).
pl_punch:
        ld a,(p_state)
        and 1
        add a,a
        ld e,a
        ld d,0
        ld hl,pl_punchdx
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld de,(p_x)
        add hl,de
        ld (pf_x),hl
        ld hl,(p_y)
        ld de,-48
        add hl,de
        ld (pf_y),hl
        xor a
        ld (pf_d7),a
        ld a,8
        ; (falls into fx_add)

; ----- spawn_effect ($ACBC) -----

; A = type (D3), pf_d7 = direction (D7, & 14 from now on), pf_x / pf_y = position (D0 / D1): into
; slot $1692 & 14, then $1692 += 2. Keeps IX.
fx_add: ld c,a
        ld a,(pf_d7)
        and 0x0E
        ld (pf_d7),a
        ld b,a
        ld a,(AM + 0x1692)
        and 0x0E
        ld e,a
        ld d,0
        ld hl,FX_SLOTS
        add hl,de
        ld (hl),c
        inc hl
        ld (hl),d
        ld de,FX_DIR - 1
        add hl,de
        ld (hl),b
        inc hl
        ld (hl),0
        add hl,de
        ld bc,(pf_x)
        ld (hl),c
        inc hl
        ld (hl),b
        add hl,de
        ld bc,(pf_y)
        ld (hl),c
        inc hl
        ld (hl),b
        ld hl,(AM + 0x1692)
        inc hl
        inc hl
        ld (AM + 0x1692),hl
        ret

; ----- the shot ($AF08) -----

; IX = the slot. It moves 16 pixels (8 + 8 on the diagonals); where it was: an enemy or a map
; object there is hit (pushed by a quarter of the step, explosion 1, the shot is gone), then the
; map cell 8 pixels left of it: a wall (bit 1) ends it with explosion 1 (a second one when it
; also hit), else its BOB is drawn and it is gone when that is off the screen.
fx_shot:
        ld l,(ix+FX_X)
        ld h,(ix+FX_X+1)
        ld (pf_x),hl
        ld l,(ix+FX_Y)
        ld h,(ix+FX_Y+1)
        ld (pf_y),hl
        ld a,(ix+FX_DIR)
        ld (pf_d7),a
        ld e,a
        ld d,0
        ld hl,fx_dy
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld l,(ix+FX_Y)
        ld h,(ix+FX_Y+1)
        add hl,bc
        ld (ix+FX_Y),l
        ld (ix+FX_Y+1),h
        ld hl,fx_dx
        add hl,de
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld (pf_dx),bc
        ld l,(ix+FX_X)
        ld h,(ix+FX_X+1)
        add hl,bc
        ld (ix+FX_X),l
        ld (ix+FX_X+1),h
        call hit_test
        jr z,fxs_wall
        ld hl,(pf_dx)
        sra h
        rr l
        sra h
        rr l
        ld e,(iy+0)
        ld d,(iy+1)
        add hl,de
        ld (iy+0),l
        ld (iy+1),h
        ld (ix+0),0
        call fxs_expl
fxs_wall:
        ld hl,(pf_x)
        ld de,-8
        add hl,de
        ld de,(pf_y)
        call map_atr                ; ($EF8E)
        and WALL
        jr z,fxs_draw
        ld (ix+0),0
fxs_expl:
        ld hl,(pf_x)
        ld de,(pf_y)
        ld bc,1                     ; explosion type 1 (D5 = 1)
        jp expl_add
fxs_draw:
        ld a,(pf_d7)
        ld e,a
        ld d,0
        ld hl,fx_gfx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0xBEA0
        ld a,0x06
        call a2_set                 ; $6BEA0 + the direction's offset
        ld hl,0x402
        ld (bob_d4),hl
        ld hl,(pf_x)
        ld (bob_x),hl
        ld hl,(pf_y)
        ld (bob_y),hl
        call bob_draw
        ret z
        ld (ix+0),0
        ret

; ----- the punch's hit box ($AF90) -----

; IX = the slot: tests its point for 6 frames from direction 0 (frames counted in FX_DIR; from
; another start fewer, from 6 on none), gone at the first hit.
fx_punch:
        ld a,(ix+FX_DIR)
        cp 6
        jr nc,fxp_end
        inc (ix+FX_DIR)
        ld l,(ix+FX_X)
        ld h,(ix+FX_X+1)
        ld (pf_x),hl
        ld l,(ix+FX_Y)
        ld h,(ix+FX_Y+1)
        ld (pf_y),hl
        call hit_test
        ret z
fxp_end:
        ld (ix+0),0
        ret

; ----- $BE48: a point against the 10 collision slots -----

; (pf_x, pf_y) against the 5 enemy slots and the 5 map objects' slots after them (A0 = $BC4 +
; 4k: x; y at -60h, type at +40h, hit points +41h, flash +42h): the first one in use whose box
; [x - 8, x + width) x [y - 8, y + height) (the type's record, obj_desc +4 / +6) holds the point
; flashes and, with hit points 0 or more, loses one: going below 0 clears its byte +23h. ->
; IY = its A0 (AM + A0), NZ; Z when none. Keeps IX.
; (The port: the boxes are worked out once per pass over the shots - ht_ok, cleared by pl_fire -
; as nothing moves the slots meanwhile but the push of a hit, after which they are worked out
; again; the bounds are compared by their signs, as the original does: one type's width is
; negative.)
hit_test:
        ld a,(ht_ok)
        or a
        call z,ht_build
        ld a,(ht_n)
        or a
        ret z                       ; (Z: no slot in use)
        ld b,a
        ld de,(pf_x)
        ld hl,ht_box                ; (ht_box does not cross a 256-byte boundary)
ht_lp:  ld a,e
        sub (hl)
        inc l
        ld a,d
        sbc a,(hl)
        jp m,ht_n9                  ; D0 < x - 8
        inc l
        ld a,e
        sub (hl)
        inc l
        ld a,d
        sbc a,(hl)
        jp p,ht_n7                  ; D0 >= x + width
        inc l
        ld a,(pf_y)
        sub (hl)
        inc l
        ld a,(pf_y+1)
        sbc a,(hl)
        jp m,ht_n5
        inc l
        ld a,(pf_y)
        sub (hl)
        inc l
        ld a,(pf_y+1)
        sbc a,(hl)
        jp p,ht_n3
        inc l
        ld a,(hl)
        inc l
        ld h,(hl)
        ld l,a
        push hl
        pop iy                      ; its A0
        xor a
        ld (ht_ok),a                ; (it is pushed: the boxes again next time)
        ld (iy + (0x42 ^ 1)),1      ; hit: the flash,
        ld a,(iy + (0x41 ^ 1))
        or a
        jp m,ht_hit
        dec a
        ld (iy + (0x41 ^ 1)),a      ;   a hit point
        jp p,ht_hit
        ld (iy + (0x23 ^ 1)),0
ht_hit: or 0xFF                     ; (NZ)
        ret
ht_n9:  ld a,9                      ; (the next box)
        jr ht_nx
ht_n7:  ld a,7
        jr ht_nx
ht_n5:  ld a,5
        jr ht_nx
ht_n3:  ld a,3
ht_nx:  add a,l
        ld l,a
        djnz ht_lp
        xor a
        ret

; The boxes of the slots in use, in their order: x - 8, x + width, y - 8, y + height and A0
; (words) each, their count in ht_n.
ht_build:
        push ix
        ld ix,ht_box
        ld iy,AM + 0x0BC4
        ld bc,10 * 256              ; B = slots, C = boxes
hb_lp:  ld a,(iy + (0x40 ^ 1))
        or a
        jr z,hb_nx
        inc c
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,obj_desc + 4
        add hl,de                   ; the type's width, height
        ld e,(iy+0)
        ld d,(iy+1)
        ld a,e
        sub 8
        ld (ix+0),a
        ld a,d
        sbc a,0
        ld (ix+1),a                 ; x - 8
        ld a,(hl)
        inc hl
        add a,e
        ld (ix+2),a
        ld a,(hl)
        inc hl
        adc a,d
        ld (ix+3),a                 ; x + width
        ld e,(iy-0x60)
        ld d,(iy-0x5F)
        ld a,e
        sub 8
        ld (ix+4),a
        ld a,d
        sbc a,0
        ld (ix+5),a                 ; y - 8
        ld a,(hl)
        inc hl
        add a,e
        ld (ix+6),a
        ld a,(hl)
        adc a,d
        ld (ix+7),a                 ; y + height
        push iy
        pop hl
        ld (ix+8),l
        ld (ix+9),h                 ; A0
        ld de,10
        add ix,de
hb_nx:  ld de,4
        add iy,de
        djnz hb_lp
        ld a,c
        ld (ht_n),a
        ld a,1
        ld (ht_ok),a
        pop ix
        ret

; ----- set_weapon ($FD30), $AC9A -----

; A = weapon 0-3 ($805C): its ammo ($8030, BCD: 0, 500, 300, 400) and its icon on the panel
; (panel_draw_icon $896A: a HUD job).
set_weapon:
        ld e,a
        ld d,0
        ld (AG + 0x805C),de
        ld hl,wpn_ammo
        add hl,de
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld (AG + 0x8030),hl
        ld hl,wpn_icon
        add hl,de
        add hl,de
        ld c,(hl)
        ld a,JOB_ICON
        jp hud_request

; The ammo ($8030, 4 BCD digits) minus one.
ammo_dec:
        ld hl,AG + 0x8030
        ld a,(hl)
        sub 1
        daa
        ld (hl),a
        inc hl
        ld a,(hl)
        sbc a,0
        daa
        ld (hl),a
        ret
