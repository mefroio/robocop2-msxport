; Game logic, module 3 (continued, BANK_LC3 at 8000h around its call in player.asm game_tick):
; RoboCop's player_move ($AFF8), out of the fixed code. It calls only fixed routines (map
; attributes, the palette flash) and, through player.asm pm_punch, shots.asm pl_punch.

; ----- player_move ($AFF8) -----

pl_move:
        call pl_cellof              ; A0: the cell of the frame's start position
        ld a,(p_state)
        ld (pm_d1),a                ; D1 = state
        and 0x7E
        ld (pm_d5),a                ; D5 = state & 7Eh
        ld a,0xFF
        ld (pm_d2),a                ; D2 = -1: no new state
        ld hl,ac_jmask              ; (the immediate $B02B: 0 while the vehicle steers)
        ld a,(g_joy)
        and (hl)
        ld (pm_d0),a                ; D0 = joystick bits
        ld hl,(p_conf)              ; reversed controls ($1698)
        ld a,h
        or l
        jr z,pm_pend
        dec hl
        ld (p_conf),hl
        ld a,(g_frame)
        and 7
        call z,pl_flash
        ld a,(pm_d0)
        ld c,a
        and 0x0C
        jr z,pm_pend
        ld a,c
        xor 0x0C
        ld (pm_d0),a
pm_pend:
        ld a,(p_pend+1)             ; a state the last frame asked for ($1696)
        bit 7,a
        jr nz,pm_10
        ld a,0xFF
        ld (p_pend+1),a
        ld a,(p_pend)
        ld (pm_d2),a
pm_10:  ld a,(pm_d5)
        cp 0x0A
        jr nz,pm_14
        ld a,(pm_d0)                ; states 10/11: left and right only, no fire
        and 0x0C
        ld (pm_d0),a
        ld hl,g_joy
        res 4,(hl)
pm_14:  ld a,(pm_d5)
        cp 0x0E
        jr nz,pm_8
        ld a,(pm_d0)                ; states 14/15: up only
        and 1
        ld (pm_d0),a
pm_8:   ld a,(pm_d5)
        cp 8
        jr nz,pm_6
        ld a,(pm_d0)                ; crouching: only up goes on
        cp 1
        jp nz,pm_b170
pm_6:   ld a,(pm_d5)
        cp 6
        jp z,pm_afb2
        ld a,(pm_d0)
        bit 2,a
        jr z,pm_right
        ld c,1                      ; left: state 1 (5 in the air)
        ld a,(p_air)
        or a
        jr z,pm_left1
        ld c,5
pm_left1:
        ld a,c
        ld (pm_d2),a
pm_right:
        ld a,(pm_d0)
        bit 3,a
        jr z,pm_step
        ld c,0                      ; right: state 0 (4 in the air)
        ld a,(p_air)
        or a
        jr z,pm_right1
        ld c,4
pm_right1:
        ld a,c
        ld (pm_d2),a
        ; the current state's step, unless the cell beside is a wall (the row above while vy < 0,
        ; i.e. on the ground or going up)
pm_step:
        ld a,(pm_d1)
        ld e,a
        ld d,0
        ld hl,pl_xstep
        add hl,de
        ld a,(hl)
        or a
        jr z,pm_add
        ld (pm_d4),a
        ld hl,(p_row)
        ld d,l                      ; D = row
        ld e,h                      ; E = column
        ld a,(p_vy+1)
        bit 7,a
        jr z,pm_side
        dec d                       ; the row above
pm_side:
        ld a,(pm_d4)
        bit 7,a
        jr z,pm_east
        dec e
        jr pm_wall
pm_east:
        inc e
pm_wall:
        call atr_rc
        and WALL
        jr nz,pm_b0fe
        ld a,(p_anim)
        and 6
        cp 6
        jr nz,pm_go
        ld a,6
        ld (snd_b30),a              ; footstep
pm_go:  ld a,(pm_d4)
pm_add: ld l,a
        rla
        sbc a,a
        ld h,a
        ld de,(p_x)
        add hl,de
        ld (p_x),hl
pm_b0fe:
        ld a,(pm_d0)
        and 0x0C
        jp nz,pm_b170
        ld a,(pm_d0)
        bit 0,a
        jr z,pm_b142
        ld a,(p_floor)              ; up on a floor with bit 2 ($1675) is fire
        bit 2,a
        jr z,pm_up
        ld a,0x10
        ld (g_joy),a
        jr pm_b142
pm_up:  ld a,(p_jwait)              ; just landed: stands a frame more
        or a
        jr z,pm_jump
        dec a
        ld (p_jwait),a
        ld a,2
        ld (pm_d2),a
        jp pm_b170
pm_jump:
        ld a,(p_air)
        or a
        jp nz,pm_b170
        ld a,(pm_d0)
        bit 4,a
        jp nz,pm_b170               ; up + fire: aims up, no jump
        ld a,(pm_d1)
        and 1
        add a,4
        ld (pm_d2),a                ; jump: state 4/5
        ld a,0xFF
        ld (p_air),a
pm_b142:
        xor a
        ld (p_jwait),a
        ld a,(pm_d0)
        bit 1,a
        jr z,pm_b170
        ld a,(g_joy)
        bit 4,a
        jr z,pm_crouch
        ld a,(pm_d1)                ; down + fire: state 6/7, next frame
        and 1
        add a,6
        ld (pm_d2),a
        ld (p_pend),a
        xor a
        ld (p_pend+1),a
        jr pm_b170
pm_crouch:
        ld a,(pm_d1)
        call st_c0f
        jr z,pm_b170
        ld a,(pm_d1)
        and 1
        add a,8
        ld (pm_d2),a                ; crouch: state 8/9
pm_b170:
        ld a,(pm_d5)
        cp 8
        jr nz,pm_count
        ld a,3
        ld (p_jwait),a
        ld a,(pm_d0)
        cp 1
        jr z,pm_rise
        xor a                       ; crouched: holds step 4, turning with left/right
        ld (p_rev),a
        ld hl,(p_anim)
        ld de,4
        or a
        sbc hl,de
        jp m,pm_count
        ld a,(pm_d0)
        bit 2,a
        jr z,pm_c8
        ld hl,9
        ld (p_state),hl
pm_c8:  ld a,(pm_d0)
        bit 3,a
        jr z,pm_c4
        ld hl,8
        ld (p_state),hl
pm_c4:  ld hl,4
        ld (p_anim),hl
        jr pm_count
pm_rise:
        ld a,0xFF                   ; up: rises (the animation backwards), stands at step 1
        ld (p_rev),a
        ld hl,(p_anim)
        ld a,h
        or a
        jr nz,pm_count
        ld a,l
        cp 1
        jr nz,pm_count
        ld a,2
        ld (pm_d2),a
pm_count:
        ld a,(p_rev)
        or a
        jr z,pm_fwd
        ld hl,(p_anim)
        dec hl
        bit 7,h
        jr z,pm_aset
        ld hl,(p_last)
        jr pm_aset
pm_fwd: ld hl,(p_anim)
        ld de,(p_last)
        or a
        sbc hl,de
        add hl,de
        jr nz,pm_inc
        ld hl,-1
pm_inc: inc hl
pm_aset:
        ld (p_anim),hl
        ; in the air y += vy / 4 and vy += 2 up to 1Fh; on the ground vy = -14h (a jump's start)
        ld a,(p_air)
        or a
        jr z,pm_ground
        ld hl,(p_vy)
        sra h
        rr l
        sra h
        rr l
        ld de,(p_y)
        add hl,de
        ld (p_y),hl
        ld hl,(p_vy)
        ld de,0x1F
        or a
        sbc hl,de
        jp p,pm_floor
        ld hl,(p_vy)
        inc hl
        inc hl
        ld (p_vy),hl
        jr pm_floor
pm_ground:
        ld hl,-0x14
        ld (p_vy),hl
        ; floors: a lift, else the start cell's attributes (bits 0/2); landing needs vy >= 0
pm_floor:
        call pl_lift
        jr c,pm_b24a
        ld hl,(p_row)
        ld d,l                      ; D = row
        ld e,h                      ; E = column
        call atr_rc
        ld de,(p_y)
        and FLOOR
        ld (p_floor),a
        ld hl,p_floor+1
        ld (hl),0
        jr z,pm_b26a
        ld a,(p_vy+1)
        bit 7,a
        call z,pm_land
        ld a,(p_air)
        or a
        jr nz,pm_b24a
        ld a,e
        and 0xF0                    ; on the cell's top
        ld e,a
        ld (p_y),de
        jr pm_b282
pm_b24a:
        ld (p_y),de
        ld a,(p_vy+1)
        bit 7,a
        call z,pm_land
        jr pm_b282
pm_b26a:
        ld a,(p_air)                ; no floor: falls from rest (state 4/5)
        or a
        jr nz,pm_b282
        ld a,(p_state)
        and 1
        add a,4
        ld (pm_d2),a
        ld a,0xFF
        ld (p_air),a
        ld hl,0
        ld (p_vy),hl
        ; walking or standing states with nothing asked for stand; so does a 2
pm_b282:
        ld a,(pm_d1)
        call st_c0f
        jr z,pm_b28e
        ld a,(pm_d2)
        bit 7,a
        jr nz,pm_stand
pm_b28e:
        ld a,(pm_d2)
        cp 2
        jr nz,pm_change
pm_stand:
        ld a,(pm_d1)
        and 1
        add a,2
        ld (pm_d2),a
pm_change:
        ld a,(pm_d2)
        bit 7,a
        jr nz,pm_cam
        ld hl,p_state
        cp (hl)
        jr nz,pm_new
        inc hl
        ld a,(hl)
        or a
        jr z,pm_cam
        ld a,(pm_d2)
pm_new: ld hl,0
        ld (p_anim),hl
        ld l,a
        ld (p_state),hl
        ld e,a                      ; the state's parameters ($B3AE): $15DF, $15E4, hitbox
        ld d,0
        ld hl,pl_stparm
        add hl,de
        add hl,de
        add hl,de
        ld a,(hl)
        ld (p_de),a
        inc hl
        ld a,(hl)
        ld (p_rev),a
        inc hl
        ld a,(hl)
        ld (p_hb),a
        xor a
        ld (p_hb+1),a
        ; camera: x eases by 1/16 towards x - CAM_DX (0..CAM_XMAX), y by 1/8 towards y - CAM_DY,
        ; or towards -60h when that is above 38h (0..the level's lowest)
pm_cam: ld hl,(p_x)
        ld de,(ac_camdx)            ; (the immediates $B2D8 and $B2FC: obj32 changes them)
        or a
        sbc hl,de
        ld de,(gcam_x)
        or a
        sbc hl,de
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        add hl,de
        bit 7,h
        jr z,pm_cx
        ld hl,0
        jr pm_cxs
pm_cx:  ld de,CAM_XMAX
        or a
        sbc hl,de
        add hl,de
        jr c,pm_cxs
        ex de,hl
pm_cxs: ld (gcam_x),hl
        ld hl,(p_y)
        ld de,(ac_camdy)
        add hl,de
        ld de,0x38
        or a
        sbc hl,de
        add hl,de
        jp p,pm_cy
        ld hl,-0x60
pm_cy:  ld de,(gcam_y)
        or a
        sbc hl,de
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        add hl,de
        bit 7,h
        jr z,pm_cy1
        ld hl,0
        jr pm_cys
pm_cy1: ld de,(gcam_ymax)
        or a
        sbc hl,de
        add hl,de
        jp m,pm_cys
        ex de,hl
pm_cys: ld (gcam_y),hl
        ; the start of the level ($15CA clear): standing, aim 2, controls locked; from game frame
        ; 1Ch the arm poses 8..25 (sound 303h every few), then $15CA is set
        ld a,(p_started)
        or a
        jr nz,pm_view
        ld hl,4
        ld (p_aim),hl
        ld hl,0
        ld (p_anim),hl
        ld hl,2
        ld (p_de),hl
        ld (p_state),hl
        ld a,0xFF
        ld (g_lock),a
        ld hl,8
        ld (p_arm),hl
        ld hl,(g_frame)
        ld de,0x1C
        or a
        sbc hl,de
        jp m,pm_view
        ld a,(p_startn)
        ld c,a
        and 0x0B
        jr nz,pm_s1
        ld hl,0x0303
        ld (AM + 0x0B2E),hl         ; (move.w #$303,$B2E)
pm_s1:  ld a,c
        srl a
        add a,8
        ld l,a
        ld h,0
        ld (p_arm),hl
        inc c
        ld a,c
        ld (p_startn),a
        cp 0x25
        jr nz,pm_view
        ld a,0xFF
        ld (p_started),a
        xor a
        ld (p_startn),a
        ld (g_lock),a
        ld hl,0
        ld (p_arm),hl
pm_view:
        jp pl_view

; States 6/7 ($AFB2): at step 8 back to standing; at step 4 the effect of type 8 ahead of him.
pm_afb2:
        ld hl,(p_anim)
        ld a,h
        or a
        jp nz,pm_b170
        ld a,l
        cp 8
        jr nz,pm_a4
        ld a,2
        ld (pm_d2),a
pm_a4:  ld a,l
        cp 4
        jp nz,pm_b170
        ld a,0x14
        ld (snd_b2c),a
        call pm_punch              ; (module 1's: player.asm)
        jp pm_b170

; Landing: on the ground, standing (state 2 asked for), vy 0, a frame before jumping again.
; Keeps DE.
pm_land:
        xor a
        ld (p_air),a
        ld hl,0
        ld (p_anim),hl
        ld (p_vy),hl
        ld a,2
        ld (pm_d2),a
        ld a,1
        ld (p_jwait),a
        ret

; A = state -> NZ for those of the walking/standing set (bits of $C0F: 0-3, 10, 11).
st_c0f: cp 4
        jr c,sc_yes
        cp 10
        jr z,sc_yes
        cp 11
        jr z,sc_yes
        xor a
        ret
sc_yes: or 1
        ret

; The lift check ($BD72): on lift 3, 2, 1 or 0 (x in [left, right), y in (top - 15, top], not in
; the air going up) -> Carry, DE = top - 4, x moved by the lift's dx, its flag ($167A + index)
; set. The lifts' table (left, right, top, dx, index: 4 words each) is the special objects'.
pl_lift:
        ld b,4
        ld ix,lifts + 6
pli_lp: ld a,(p_air)
        or a
        jr z,pli_x
        ld a,(p_vy+1)
        bit 7,a
        jr nz,pli_next
pli_x:  ld hl,(p_x)
        ld e,(ix+0)
        ld d,(ix+1)
        or a
        sbc hl,de
        jp m,pli_next               ; x < left
        ld hl,(p_x)
        ld e,(ix+8)
        ld d,(ix+9)
        or a
        sbc hl,de
        jp p,pli_next               ; x >= right
        ld l,(ix+16)
        ld h,(ix+17)
        ld de,(p_y)
        or a
        sbc hl,de
        jp m,pli_next               ; top < y
        ld de,15
        or a
        sbc hl,de
        jp p,pli_next               ; top - 15 >= y
        ld e,(ix+16)
        ld d,(ix+17)
        dec de
        dec de
        dec de
        dec de
        ld l,(ix+24)
        ld h,(ix+25)
        push de
        ld de,(p_x)
        add hl,de
        ld (p_x),hl
        ld e,(ix+32)
        ld d,(ix+33)
        ld hl,p_onlift
        add hl,de
        ld a,l
        xor 1
        ld l,a                      ; (byte n at p_onlift + (n ^ 1))
        ld (hl),0xFF
        pop de
        scf
        ret
pli_next:
        dec ix
        dec ix
        djnz pli_lp
        or a
        ret

; -> p_row, p_col: the map cell of (x, y): row y >> 4, column (x >> 4) - 7 (A0 = $37FF2 + ...:
; the map at $38000 starts 7 cells to the right of x = 0).
pl_cellof:
        ld hl,(p_y)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld (p_row),a
        ld hl,(p_x)
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
        ld (p_col),a
        ret
