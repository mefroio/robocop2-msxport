; Game logic, module 3 (bank BANK_LC3, mapped at 8000h around its calls): the special objects.
;
;   $8B32 -> sp_update: the level's special objects, each through its handler ($8B92 + offset):
;            0 the lifts ($8DE6), 8 the vehicle ($8B9E, level 1); 4 ($8F02, level 2): not yet
;   $9150 -> hz_update: the level's hazards inside the window, each through the level's handler
;            ($91B0 + 4 * level; level 1: its electric beams, level1.asm lt0)
;
; Their records live in the Amiga's code area and change at run time: copies at SP_RAM (words
; little-endian, as the mirror keeps them), the level's list ($8B54; level 1: $8FC0) as MSX
; pointers at sp_ptrs, 0 after the last (the level's init, level1.asm). A record: handler offset,
; x, y (a 16.16 long), path index, then the path's y values (words; a negative one ends it).
; The lifts' table ($B3C-$B63: left, right, top, dx and flag index of 4 entries, msx.inc lifts)
; is what player_move's lift check ($BD72) stands RoboCop on: each visible special object fills
; the next entry (& 3) and is told by its flag byte ($167A + n, set by $BD72) that he is on it.

SR_X:       equ 2
SR_Y:       equ 4                   ; long: the integer word at +4, the fraction at +6
SR_IDX:     equ 8
SR_PATH:    equ 0x0A

; ----- $8B32 -----

; The entries' right, top and dx are cleared (left and the flag index stay), then every record
; runs with D0 = x, D1 = y, the table entry $B4C + (6 & $168C) and the flag $167A + n (n counts
; them from 1, $168A). sp_d7 is what D7 is left at for update_player ($AD78): 6 & $168C before
; the last record, or 0 when that one drew a BOB (draw_bob leaves its lines x words... & 14 = 0
; for every BLTSIZE used here).
sp_update:
        ld a,BC_SPECIAL
        ld (bob_cat),a
        ld hl,AM + 0x0B44           ; ($B44-$B5B: within a 256-byte page here)
        ld b,0x18 / 4
        xor a
spu_c:  ld (hl),a
        inc l
        ld (hl),a
        inc l
        ld (hl),a
        inc l
        ld (hl),a
        inc l
        djnz spu_c
        ld h,a
        ld l,a
        ld (AM + 0x168A),hl
        ld (AM + 0x168C),hl
        ld hl,sp_ptrs
spu_lp: ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,d
        or e
        ret z
        push hl
        push de
        pop ix
        ld (bob_own),ix             ; (the identity of its BOBs: bob.asm)
        ld hl,(AM + 0x168A)
        inc hl
        ld (AM + 0x168A),hl
        ld a,l
        xor 1
        add a,(AM + 0x167A) & 0xFF
        ld l,a
        ld h,(AM + 0x167A) / 256    ; A4: $167A + n (byte (167Ah + n) ^ 1 = 167Ah + (n ^ 1);
        ld (sp_flag),hl             ; n below 16: no carry)
        ld a,(AM + 0x168C)
        and 6
        ld (sp_d7),a
        ld e,a
        ld d,0
        ld iy,AM + 0x0B4C
        add iy,de                   ; A0: the entry's top
        ld l,(ix+SR_X)
        ld h,(ix+SR_X+1)
        ld (sp_x),hl                ; D0
        ld l,(ix+SR_Y)
        ld h,(ix+SR_Y+1)
        ld (sp_y),hl                ; D1
        ld a,(ix+0)
        cp 8
        jr z,spu_veh
        or a
        call z,sp_lift
        jr spu_nx
spu_veh:
        call sp_vehicle
spu_nx: pop hl
        jr spu_lp

; The record's x and y (D0 / D1) against the camera ($B04, $B06): carry when it is not in
; (cam_x, cam_x + 1A0h] x (cam_y, cam_y + C4h] (the port: as unsigned distances from the corner).
sp_seen:
        ld hl,(sp_x)
        ld de,(gcam_x)
        scf
        sbc hl,de
        ld de,-0x1A0
        add hl,de                   ; C: x - camera x - 1 not below 1A0h
        ret c
        ld hl,(sp_y)
        ld de,(gcam_y)
        scf
        sbc hl,de
        ld de,-0xC4
        add hl,de
        ret

; HL = what the entry's right edge adds to x: the lifts' table entry (flag index, top, left,
; right), the next entry ($168C + 2); D7 then comes from draw_bob (0).
sp_entry:
        push hl
        ld hl,(AM + 0x168A)
        ld (iy+0x10),l
        ld (iy+0x11),h
        ld hl,(sp_y)
        ld (iy+0),l
        ld (iy+1),h
        ld hl,(sp_x)
        ld (iy-0x10),l
        ld (iy-0x0F),h
        pop de
        add hl,de
        ld (iy-8),l
        ld (iy-7),h
        ld hl,(AM + 0x168C)
        inc hl
        inc hl
        ld (AM + 0x168C),hl
        xor a
        ld (sp_d7),a
        ret

; ----- a lift ($8DE6) -----

; At its path point (y = the point's) it takes the next one, or with RoboCop on it the previous
; one for up and the next for down; past the path's ends the index stays on them. Then it moves
; 2 pixels towards the point. Seen by the camera: every 4th frame while moving sound 0Ah ($B2D);
; with RoboCop on it, in state 10 his y = its top - 4 and state 10 is asked for ($1696); its flag
; cleared, its table entry (right edge + 30h), its BOB at (x + 22h, y - 12) (level 3: two BOBs,
; not yet).
sp_lift:
        push ix                     ; (the port: HL points at the path point at the index)
        pop hl
        ld de,SR_PATH
        add hl,de
        ld (spl_bas),hl
        ld e,(ix+SR_IDX)
        ld d,(ix+SR_IDX+1)
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        dec hl                      ; DE = the point
        push hl
        ld hl,(sp_y)
        or a
        sbc hl,de
        pop hl
        jr nz,spl_mvq               ; (between two points: the index is right, straight on)
        push hl
        ld hl,(sp_flag)
        ld a,(hl)
        pop hl
        or a
        jr z,spl_auto
        ld a,(g_joy)
        bit 0,a
        jr z,spl_dn
        dec hl                      ; up: the point before
        dec hl
spl_dn: ld a,(g_joy)
        bit 1,a
        jr z,spl_go
spl_auto:
        inc hl                      ; the next point
        inc hl
spl_go: ld de,(spl_bas)
        or a
        sbc hl,de
        add hl,de
        jp p,spl_ip
        ex de,hl                    ; before the path: its first point
        jr spl_mv
spl_ip: inc hl
        bit 7,(hl)
        dec hl
        jr z,spl_mv
        dec hl                      ; past its end (a negative point): the last one
        dec hl
spl_mv: push hl
        ld de,(spl_bas)
        or a
        sbc hl,de
        ld (ix+SR_IDX),l
        ld (ix+SR_IDX+1),h          ; the index
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(sp_y)                ; D1 against the point
        or a
        sbc hl,de
        ld a,0xFF
        jr z,spl_at
spl_mvq:
        ld de,-2
        jp p,spl_y                  ; below it: up
        ld de,2
spl_y:  ld l,(ix+SR_Y)
        ld h,(ix+SR_Y+1)
        add hl,de
        ld (ix+SR_Y),l
        ld (ix+SR_Y+1),h
        xor a
spl_at: ld (sp_atpt),a              ; (seq D4)
        call sp_seen
        ret c
        ld a,(sp_atpt)
        or a
        jr nz,spl_on
        ld a,(g_frame)
        and 3
        jr nz,spl_on
        ld a,0x0A
        ld (snd_b2d),a
spl_on: ld hl,(sp_flag)
        ld a,(hl)
        or a
        jr z,spl_tab
        ld a,(p_state)
        cp 0x0A
        jr nz,spl_ask
        ld hl,(sp_y)
        ld de,-4
        add hl,de
        ld (p_y),hl
spl_ask:
        ld hl,0x0A
        ld (p_pend),hl
spl_tab:
        ld hl,(sp_flag)
        ld (hl),0
        ld hl,0x30
        call sp_entry
        ld hl,(sp_y)
        ld de,-12
        add hl,de
        ld (bob_y),hl
        ld hl,(sp_x)
        ld de,0x22
        add hl,de
        ld (bob_x),hl
        ld hl,0xB68A
        ld (bob_a2),hl
        ld a,0x04
        ld (bob_a2+2),a             ; $4B68A
        ld hl,0x604
        ld (bob_d4),hl
        jp bob_draw

; ----- the vehicle ($8B9E, level 1) -----

; vx ($D7A) within -8..8 moves it by vx / 2 between x 440h and 4DFh (bouncing off with 2 / -2);
; y (the record's long) += vy ($D7C), seen at most at 31Ch (where vy becomes -0.5); $D79 is set
; down there (y >= 300h) and while ridden.
; - Ridden: sound 29h ($B2F) every 4th frame; above y F0h it stops at EFh and vx grows by 4, and
;   from x 4CFh on it lets the joystick go ($B02B, player_move's mask, back to 7Fh) with vy
;   +0.0625; below, the joystick moves it instead of RoboCop (mask 0: on the first such frame vy
;   + 1.0 and his state 3), right: vx + 1, state 2, state 0 asked for; left: vx - 1, state 3;
;   he stands still (state 2 or 3, $8C98) at x + 12h, y - 4 ($16D8 set).
; - Alone: the joystick back (7Fh) and vx towards x 480h (2 / -2, 0 there).
; Seen by the camera: its table entry (right edge + 36h), its body (x + 22h, y - 6), two wheels
; ($3E6D0, or $3E450 with $D79; + 140h on odd frames) at y + 8, and with the joystick left or
; right and RoboCop's controls given back, the exhaust (y + 2). vy eases towards -2.0 with $D79,
; else towards +2.0 (by 1/16 per frame). Not seen: its y goes back to 2F8h.
sp_vehicle:
        xor a
        ld (AM + (0x16D8 ^ 1)),a
        ld hl,(AM + 0x0D7A)
        ld de,-8
        call spv_cmp
        jp p,spv_v1
        ex de,hl
spv_v1: ld de,9
        call spv_cmp
        jp m,spv_v2
        ld hl,8
spv_v2: ld (AM + 0x0D7A),hl
        sra h
        rr l
        ld de,(sp_x)
        add hl,de
        ld de,0x4E0
        call spv_cmp
        jp m,spv_x1
        ld hl,-2
        ld (AM + 0x0D7A),hl
        ld hl,0x4DF
spv_x1: ld de,0x440
        call spv_cmp
        jp p,spv_x2
        ld hl,2
        ld (AM + 0x0D7A),hl
        ex de,hl
spv_x2: ld (ix+SR_X),l
        ld (ix+SR_X+1),h
        ld (sp_x),hl
        push ix
        pop hl
        ld de,SR_Y
        add hl,de
        ld de,AM + 0x0D7C
        call add_l
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld de,0x31C
        call spv_cmp
        jp m,spv_y1
        ex de,hl
        ld de,-1
        ld (AM + 0x0D7C),de
        ld de,0x8000
        ld (AM + 0x0D7E),de         ; vy = -0.5
spv_y1: ld (sp_y),hl
        ld de,0x300
        call spv_cmp
        ld a,0
        jp m,spv_y2
        dec a
spv_y2: ld (AM + (0x0D79 ^ 1)),a
        ld hl,(sp_flag)
        ld a,(hl)
        or a
        jp z,spv_alone
        ld a,0xFF
        ld (AM + (0x0D79 ^ 1)),a
        ld a,(g_frame)
        and 3
        jr nz,spv_r0
        ld a,0x29
        ld (snd_b2f),a
spv_r0: ld hl,(sp_y)
        ld de,0xF0
        call spv_cmp
        jp p,spv_r2
        ld hl,0xEF
        ld (sp_y),hl
        ld hl,(AM + 0x0D7A)
        ld de,4
        add hl,de
        ld (AM + 0x0D7A),hl
        ld hl,(sp_x)
        ld de,0x4CF
        call spv_cmp
        jp m,spv_ride
        ld a,0x7F
        ld (ac_jmask),a
        ld hl,0
        ld (AM + 0x0D7C),hl
        ld hl,0x1000
        ld (AM + 0x0D7E),hl         ; vy = +0.0625
        jp spv_tab
spv_r2: ld a,(ac_jmask)
        or a
        jr z,spv_r3
        ld hl,3
        ld (ac_ridest),hl
        ld hl,(AM + 0x0D7C)
        inc hl
        ld (AM + 0x0D7C),hl
spv_r3: xor a
        ld (ac_jmask),a
        ld a,(g_joy)
        bit 3,a
        jr z,spv_r4
        ld hl,2
        ld (ac_ridest),hl
        ld hl,0
        ld (p_pend),hl
        ld hl,(AM + 0x0D7A)
        inc hl
        ld (AM + 0x0D7A),hl
spv_r4: ld a,(g_joy)
        bit 2,a
        jr z,spv_r5
        ld hl,3
        ld (ac_ridest),hl
        ld hl,(AM + 0x0D7A)
        dec hl
        ld (AM + 0x0D7A),hl
spv_r5: ld hl,(ac_ridest)
        ld (p_state),hl
        ld hl,0
        ld (p_anim),hl
spv_ride:
        ld hl,(sp_x)
        ld de,0x12
        add hl,de
        ld (p_x),hl
        ld a,0xFF
        ld (AM + (0x16D8 ^ 1)),a
        ld hl,(sp_y)
        ld de,-4
        add hl,de
        ld (p_y),hl
        jr spv_tab
spv_alone:
        ld a,0x7F
        ld (ac_jmask),a
        ld hl,0
        ld (AM + 0x0D7A),hl
        ld hl,(sp_x)
        ld de,0x480
        call spv_cmp
        jr z,spv_tab
        ld hl,-2
        jp p,spv_vx
        ld hl,2
spv_vx: ld (AM + 0x0D7A),hl
spv_tab:
        ld hl,(sp_flag)
        ld (hl),0
        call sp_seen
        jr nc,spv_seen
        ld (ix+SR_Y),0xF8
        ld (ix+SR_Y+1),0x02         ; (only the long's integer word)
        ret
spv_seen:
        ld hl,0x36
        call sp_entry
        ld hl,(sp_x)
        ld de,0x22
        add hl,de
        ld (bob_x),hl
        ld hl,(sp_y)
        ld de,-6
        add hl,de
        ld (bob_y),hl
        ld hl,0xE180
        ld (bob_a2),hl
        ld a,0x03
        ld (bob_a2+2),a             ; the body, $3E180
        ld hl,0x604
        ld (bob_d4),hl
        call bob_draw
        ld hl,0xE6D0
        ld a,(AM + (0x0D79 ^ 1))
        or a
        jr z,spv_up
        ld hl,0xE450                ; ($3E6D0 - 280h)
        ld de,(AM + 0x0D7C)
        ld a,e
        cp 0xFE
        jr nz,spv_acc
        inc d
        jr nz,spv_acc
        ld a,(AM + 0x0D7E)
        or a
        jr nz,spv_acc
        ld a,(AM + 0x0D7F)
        or a
        jr z,spv_wh                 ; at -2.0
spv_acc:
        push hl
        ld hl,(AM + 0x0D7E)
        ld de,-0x1000
        add hl,de
        ld (AM + 0x0D7E),hl
        ld hl,(AM + 0x0D7C)
        jr c,spv_acc1
        dec hl
spv_acc1:
        ld (AM + 0x0D7C),hl
        pop hl
        jr spv_wh
spv_up: ld de,(AM + 0x0D7C)
        push hl
        ex de,hl
        ld de,2
        call spv_cmp
        pop hl
        jp p,spv_wh
        push hl
        ld hl,(AM + 0x0D7E)
        ld de,0x1000
        add hl,de
        ld (AM + 0x0D7E),hl
        ld hl,(AM + 0x0D7C)
        jr nc,spv_up1
        inc hl
spv_up1:
        ld (AM + 0x0D7C),hl
        pop hl
spv_wh: ld a,(g_frame)
        rra
        jr nc,spv_w0
        ld de,0x140
        add hl,de
spv_w0: ld (bob_a2),hl
        ld a,0x03
        ld (bob_a2+2),a
        ld hl,(sp_x)
        ld de,0x24
        add hl,de
        ld (bob_x),hl
        ld hl,(sp_y)
        ld de,8
        add hl,de
        ld (bob_y),hl
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw               ; a wheel
        ld hl,(bob_a2)
        ld de,0xA0
        add hl,de
        ld (bob_a2),hl
        ld hl,(sp_x)
        ld de,0x24 + 0x1B
        add hl,de
        ld (bob_x),hl
        ld hl,0x402
        ld (bob_d4),hl
        call bob_draw               ; the other
        ld a,(ac_jmask)
        or a
        ret nz
        ld a,(g_joy)
        and 0x0C
        ret z
        ld c,a
        ld a,(g_frame)
        and 2
        ld e,a
        ld d,0
        ld hl,veh_fl
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(sp_x)
        push de
        ld de,0x22
        add hl,de
        pop de
        bit 2,c
        jr z,spv_ex
        push hl
        ld hl,0xA0
        add hl,de
        ex de,hl
        pop hl
        push de
        ld de,0x20
        add hl,de
        pop de
spv_ex: ld (bob_x),hl
        ld hl,0xE950
        ld a,0x03
        call a2_set                 ; $3E950 + the frame's offset
        ld hl,(sp_y)
        inc hl
        inc hl
        ld (bob_y),hl
        ld hl,0x402
        ld (bob_d4),hl
        jp bob_draw

; HL - DE as the 68000's cmp.w: S and Z of the difference. Keeps HL, DE.
spv_cmp:
        push hl
        or a
        sbc hl,de
        pop hl
        ret

; ----- $9150: the level's hazards -----

; $15F0 cleared ($10356, the beams' copper colour: visual). Every record of the level's list
; (8 bytes: x, y, the window's x, rows - 1; a negative x ends it) whose y is in
; [camera y - 64h, + ACh) and x range meets the camera's x + 73h .. + 1A0h runs the level's
; handler (lv_tick) with IX = the record.
hz_update:
        ld hl,0
        ld (AM + 0x15F0),hl
        ld hl,(gcam_x)
        ld de,0x73
        add hl,de
        ld (hz_xlo),hl              ; D5 (x)
        ld de,0x12D
        add hl,de
        ld (hz_xhi),hl
        ld hl,(gcam_y)
        ld de,-0x64
        add hl,de
        ld b,h
        ld c,l                      ; BC = D5 (y)
        ld hl,(lv_hz)
hz_lp:  inc hl
        ld a,(hl)
        or a
        ret m                       ; (a negative x: the end)
        inc hl
        ld a,(hl)
        sub c
        ld e,a
        inc hl
        ld a,(hl)
        sbc a,b                     ; D3 = y - D5: in when below 110h (the port: unsigned)
        jr z,hz_x
        dec a
        jr nz,hz_no
        ld a,e
        cp 0x10
        jr c,hz_x
hz_no:  ld de,5                     ; (HL = the record + 3)
        add hl,de
        jp hz_lp
hz_x:   dec hl
        dec hl
        dec hl                      ; the record
        push hl
        ld de,4
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                    ; D4 = the window's x
        ld de,(hz_xlo)
        or a
        sbc hl,de
        jp m,hz_nx
        pop hl
        push hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                    ; D2 = x
        ld de,(hz_xhi)
        or a
        sbc hl,de
        jp p,hz_nx
        pop ix
        push ix
        push bc
        call lv_tick
        pop bc
hz_nx:  pop hl
        ld de,8
        add hl,de
        jp hz_lp

