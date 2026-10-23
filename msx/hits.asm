; Game logic, module 1 (continued, BANK_LC1): RoboCop against the others, and the pickups.
;
;   $FA7C -> pl_hits: the enemy bullets, an enemy's touch and the pickups against RoboCop's
;            hitbox (main_loop runs it right after player_move)
;   $F900 -> pk_update: the pickups fall and are drawn
;
; Pickups: 4 slots, type at $D80 + k (byte: 4-40 in steps of 4, 0 none), x at $D84 + 4k (word),
; y at $D94 + 4k and vy at $DA4 + 4k (16.16 longs); pickup_drop (logic.asm, $F98C) starts them.

PK_X:       equ AM + 0x0D84
PK_Y:       equ AM + 0x0D94
PK_VY:      equ AM + 0x0DA4

; ----- $FA7C -----

; RoboCop's box [x + dx, x + dx + w) x [y + dy, y + dy + h) (the state's hitbox, $168E):
; - the first 6 enemy bullets (of 8; $C34 + 4k: x, y at +20h, type at +40h) whose box, per type
;   ($FA35 width: negative, the type never hits; $FA4C height; both unsigned), overlaps it:
;   unless the death sequence's counter has its high byte ($16BC) set, the bullet is gone, the
;   energy ($169A) loses the type's damage ($FA63; times DAMAGE_X, the missile of types 1 and 2
;   at most twice), the palette flashes
;   (PAL_SHOT) and, when
;   the bullet was less than 50 pixels right of him, the hit spark runs 7 frames ($16A0) at
;   ($16A2, $16A4) = y + 3Ch - his y, 0..32h, twice (the x written first is overwritten);
; - the first of the 5 enemies whose box (obj_desc width, height; no -8 margins here) overlaps
;   it: its touch byte (+23h) set, the palette flashes (PAL_ENEMYHIT), energy - 1 (DAMAGE_X);
; - the pickups (slot 3 to 0) no longer rising whose box (x - 8, y - 8, 15 x 15) overlaps it:
;   the first one is taken: its message, its sound ($FC0B), the vehicle's vy + 6 when he rides it
;   ($16D8, $D7C), and its effect ($FBE0 + type) - nothing more this frame.
pl_hits:
        ld a,(p_hb)
        ld e,a
        ld d,0
        ld hl,pl_hitbox
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,(p_x)
        add hl,de
        ld (ph_x0),hl               ; D0
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,(p_y)
        add hl,de
        ld (ph_y0),hl               ; D1
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,(ph_x0)
        add hl,de
        ld (ph_x1),hl               ; D4
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(ph_y0)
        add hl,de
        ld (ph_y1),hl               ; D5
        ld hl,AM + 0x0C34 + (0x40 ^ 1)  ; (the port) none of the 6 bullets in use: the enemies next
        ld de,4
        ld b,6
        xor a
phb_t:  or (hl)
        add hl,de
        djnz phb_t
        jp z,phb_end                ; (djnz and add hl,de leave Z)
        ld iy,AM + 0x0C34           ; the enemy bullets
        ld b,6
phb_lp: ld a,(iy + (0x40 ^ 1))
        or a
        jp z,phb_nx
        ld c,a
        ld l,(iy+0)
        ld h,(iy+1)
        ld de,(ph_x1)
        or a
        sbc hl,de
        jp p,phb_nx                 ; x >= D4
        ld e,c
        ld d,0
        ld hl,ebh_w
        add hl,de
        ld a,(hl)
        or a
        jp m,phb_nx
        ld e,a
        ld l,(iy+0)
        ld h,(iy+1)
        add hl,de
        ld de,(ph_x0)
        or a
        sbc hl,de
        jp m,phb_nx                 ; x + width < D0
        ld l,(iy+0x20)
        ld h,(iy+0x21)
        ld de,(ph_y1)
        or a
        sbc hl,de
        jp p,phb_nx
        ld e,c
        ld d,0
        ld hl,ebh_h
        add hl,de
        ld e,(hl)
        ld l,(iy+0x20)
        ld h,(iy+0x21)
        add hl,de
        ld de,(ph_y0)
        or a
        sbc hl,de
        jp m,phb_nx
        ld a,(AM + (0x16BC ^ 1))
        or a
        jp nz,phb_nx
        ld (iy + (0x40 ^ 1)),0
        ld e,c
        ld d,0
        ld hl,ebh_dmg
        add hl,de
        ld a,(hl)
        ld (ph_dmg),a
        ld l,(iy+0)
        ld h,(iy+1)
        ld de,(p_x)
        or a
        sbc hl,de
        jp p,phb_dx
        ld hl,0
phb_dx: ld a,h
        or a
        jr nz,phb_en
        ld a,l
        cp 0x32
        jr nc,phb_en                ; 50 pixels or more right of him: no spark
        ld l,(iy+0x20)
        ld h,(iy+0x21)
        ld de,0x3C
        add hl,de
        ld de,(p_y)
        or a
        sbc hl,de
        jp p,phb_dy
        ld hl,0
phb_dy: ld a,h
        or a
        jr nz,phb_32
        ld a,l
        cp 0x32
        jr c,phb_sp
phb_32: ld hl,0x32
phb_sp: ld (AM + 0x16A2),hl
        ld (AM + 0x16A4),hl
        ld hl,7
        ld (AM + 0x16A0),hl
phb_en: ld a,(ph_dmg)
        ld e,a
        ld d,0
        if DAMAGE_X > 1             ; (the port, tools/mkrom.py DAMAGE_X: fewer enemies, harder
        ld l,e                      ; hits)
        ld h,d
        add hl,de
        if DAMAGE_X > 2
        ld a,c
        cp 3
        jr c,phb_mx                 ; (the missile, types 1 and 2, damage 40h, of the enemies of
        add hl,de                   ; types 3 and 27: twice only, the user's choice)
phb_mx:
        endif
        ex de,hl
        endif
        ld hl,(AM + 0x169A)
        or a
        sbc hl,de
        ld (AM + 0x169A),hl
        ld a,PAL_SHOT
        call pal_flash
phb_nx: ld de,4
        add iy,de
        dec b
        jp nz,phb_lp
phb_end:
        ld ix,OBJ_SLOTS             ; the enemies
        ld b,5
pht_lp: ld a,(ix+OS_TYPE)
        or a
        jp z,pht_nx
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,obj_desc + 4
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (ph_w),de
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (ph_h),de
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld de,(ph_x1)
        or a
        sbc hl,de
        jp p,pht_nx                 ; x >= D4
        ld l,(ix+OS_X)
        ld h,(ix+OS_X+1)
        ld de,(ph_w)
        add hl,de
        ld de,(ph_x0)
        or a
        sbc hl,de
        jp m,pht_nx                 ; x + width < D0
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,(ph_y1)
        or a
        sbc hl,de
        jp p,pht_nx
        ld l,(ix+OS_Y)
        ld h,(ix+OS_Y+1)
        ld de,(ph_h)
        add hl,de
        ld de,(ph_y0)
        or a
        sbc hl,de
        jp m,pht_nx
        ld (ix+OS_TOUCH),0xFF
        ld a,PAL_ENEMYHIT
        call pal_flash
        ld hl,(AM + 0x169A)
        ld de,0 - DAMAGE_X          ; (the original: 1)
        add hl,de
        ld (AM + 0x169A),hl
        jr php_go
pht_nx: ld de,4
        add ix,de
        dec b
        jp nz,pht_lp
php_go: ld hl,AM + 0x0D80           ; (the port) no pickup: done
        ld a,(hl)
        inc l
        or (hl)
        inc l
        or (hl)
        inc l
        or (hl)
        ret z
        ld b,4                      ; the pickups, slot 3 first
php_lp: dec b
        ld a,b
        xor 1
        ld e,a
        ld d,0
        ld hl,AM + 0x0D80
        add hl,de
        ld a,(hl)
        or a
        jp z,php_nx
        ld c,a                      ; D3 = type
        ld a,b
        add a,a
        add a,a
        ld e,a                      ; 4k
        ld hl,PK_VY + 1
        add hl,de
        bit 7,(hl)
        jp nz,php_nx                ; still rising
        ld hl,PK_X
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        push hl
        ld de,-8
        add hl,de
        ld de,(ph_x1)
        or a
        sbc hl,de
        pop hl
        jp p,php_nx                 ; x - 8 >= D4
        ld de,7
        add hl,de
        ld de,(ph_x0)
        or a
        sbc hl,de
        jp m,php_nx                 ; x + 7 < D0
        ld a,b
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,PK_Y
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        push hl
        ld de,-8
        add hl,de
        ld de,(ph_y1)
        or a
        sbc hl,de
        pop hl
        jp p,php_nx
        ld de,7
        add hl,de
        ld de,(ph_y0)
        or a
        sbc hl,de
        jp m,php_nx
        ld a,b                      ; taken
        xor 1
        ld e,a
        ld d,0
        ld hl,AM + 0x0D80
        add hl,de
        ld (hl),d
        ld a,c
        rrca
        rrca
        and 0x0F
        ld (ph_dmg),a               ; (type / 4)
        add a,HUD_MSG_FC3E - 1      ; its message ($FD76: $FC12 + type)
        call game_msg
        ld a,(ph_dmg)
        ld e,a
        ld d,0
        ld hl,pk_snd
        add hl,de
        ld a,(hl)
        ld (snd_b2d),a
        ld a,(AM + (0x16D8 ^ 1))
        or a
        jr z,php_fx
        ld hl,(AM + 0x0D7C)         ; riding the vehicle: its long $D7C + 6.0000
        ld de,6
        add hl,de
        ld (AM + 0x0D7C),hl
php_fx: ld a,(ph_dmg)               ; the effect ($FBE0 + type)
        dec a
        add a,a
        ld e,a
        ld d,0
        ld hl,pk_fx
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        jp (hl)
php_nx: inc b
        dec b
        jp nz,php_lp
        ret

pk_fx:  dw pk_scatter, pk_rapid, pk_tlost, pk_tgain, pk_reverse, pk_shield, pk_energy
        dw pk_three, pk_nuke, pk_nuke

pk_scatter:                         ; 4: SCATTER GUN
        ld a,3
        jp set_weapon
pk_rapid:                           ; 8: RAPID FIRE
        ld a,1
        jp set_weapon
pk_three:                           ; 32: THREE WAY GUN
        ld a,2
        jp set_weapon
pk_tlost:                           ; 12: TIME LOST - a minute; at 0 the timer is 00:00
        ld hl,AG + (0x804A ^ 1)
        ld a,(hl)
        sub 1
        daa
        jp m,pkt_zero               ; (SBCD's N: bit 7 of the result)
        ld (hl),a
        ret
pkt_zero:
        ld hl,0
        ld (AG + 0x804A),hl
        ret
pk_tgain:                           ; 16: TIME GAIN + a minute (BCD)
        ld hl,AG + (0x804A ^ 1)
        ld a,(hl)
        add a,1
        daa
        ld (hl),a
        ret
pk_reverse:                         ; 20: REVERSE CONTROL: 100h frames, or back to normal
        ld hl,(p_conf)
        ld a,h
        or l
        ld hl,0x100
        jr z,pkr_set
        ld hl,0
pkr_set:
        ld (p_conf),hl
        ret
pk_shield:                          ; 24: SHIELD (the refill counter $16AA)
        ld hl,0x100
        ld (AM + 0x16AA),hl
        ret
pk_energy:                          ; 28: ENERGY: full
        ld hl,0x102
        ld (AM + 0x169A),hl
        ret
pk_nuke:                            ; 36, 40: NUKE RETRIEVED: energy + 20h, a nuke more, and
        ld hl,(AM + 0x169A)         ; the key code 21h that shows the counts (frame_keys)
        ld de,0x20
        add hl,de
        ld (AM + 0x169A),hl
        ld hl,(AM + 0x16C0)
        inc hl
        ld (AM + 0x16C0),hl
        ld hl,0x2100
        ld (AG + 0x8032),hl
        ret

; ----- $F900: the pickups fall -----

; Slot 3 to 0: y += vy; rising above y 4 it bounces (vy negated), vy + 0.2800h; on a solid cell
; under it ($EF8E at y + 15: attributes & 15, or above the map) vy = 0 and it is drawn on the
; cell's top; its BOB ($F964 + type, BLTSIZE 402h).
pk_update:
        ld a,BC_PICKUP
        ld (bob_cat),a
        xor a
        ld (bob_own+1),a
        ld hl,AM + 0x0D80           ; (the port) no pickup: nothing to move or draw; bob_own as
        or (hl)                     ; the loop leaves it (slot 0)
        inc l
        or (hl)
        inc l
        or (hl)
        inc l
        or (hl)
        jr nz,pku_go
        ld (bob_own),a
        ret
pku_go: ld b,4
pku_lp: dec b
        ld a,b
        ld (bob_own),a              ; (the identity of its BOB: the slot, bob.asm)
        xor 1
        ld e,a
        ld d,0
        ld hl,AM + 0x0D80
        add hl,de
        ld a,(hl)
        or a
        jp z,pku_nx
        ld (ph_dmg),a               ; (D2 = type)
        push bc
        ld a,b
        add a,a
        add a,a
        ld e,a
        ld d,0                      ; 4k
        ld hl,PK_X
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld (bob_x),hl               ; D0
        ld hl,PK_Y
        add hl,de
        push de
        ex de,hl
        ld hl,PK_VY - PK_Y
        add hl,de
        ex de,hl                    ; HL = y, DE = vy
        call add_l                  ; y += vy
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                      ; D1 = y
        pop de
        ld (bob_y),hl
        push hl
        ld hl,PK_VY + 1
        add hl,de
        bit 7,(hl)
        pop hl
        jr z,pku_g
        push de
        ld de,4
        or a
        sbc hl,de
        pop de
        jp p,pku_g                  ; (y >= 4)
        ld hl,PK_VY                 ; neg.l vy
        add hl,de
        push de
        xor a
        ld c,a
        inc hl
        inc hl
        ld a,c
        sub (hl)
        ld (hl),a
        inc hl
        ld a,c
        sbc a,(hl)
        ld (hl),a
        dec hl
        dec hl
        dec hl
        ld a,c
        sbc a,(hl)
        ld (hl),a
        inc hl
        ld a,c
        sbc a,(hl)
        ld (hl),a
        pop de
pku_g:  ld hl,PK_VY + 3             ; vy + 0.2800h
        add hl,de
        ld a,(hl)
        add a,0x28
        ld (hl),a
        dec hl
        dec hl
        dec hl
        ld a,(hl)
        adc a,0
        ld (hl),a
        inc hl
        ld a,(hl)
        adc a,0
        ld (hl),a
        push de
        ld hl,(bob_y)
        ld de,15
        add hl,de
        ex de,hl
        ld hl,(bob_x)
        call cell_solid             ; ($EF8E)
        ex de,hl
        pop de
        jr nc,pku_d
        push hl
        ld hl,PK_VY
        add hl,de
        xor a
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a                   ; clr.l vy
        pop hl
pku_d:  ld de,-15
        add hl,de
        ld (bob_y),hl
        ld a,(ph_dmg)
        ld l,a
        ld h,0
        ld de,pk_gfx
        add hl,de
        call a2_long
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw
        pop bc
pku_nx: inc b
        dec b
        jp nz,pku_lp
        ret

; HL = x, DE = y ($EF8E's result) -> carry when solid: the cell's attributes & 15 not 0, or y
; above the map (no cell; past its rows: not solid); DE = y with its low byte & F0h when the
; cell is solid.
cell_solid:
        bit 7,d
        scf
        ret nz
        push de
        ld a,e
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
        jr nz,cs_out
        cp MAP_ROWS
        jr nc,cs_out
        ld d,a
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
        ld e,a
        call atr_lin
        pop de
        and 15
        ret z
        ld a,e
        and 0xF0
        ld e,a
        scf
        ret
cs_out: pop de
        or a
        ret
