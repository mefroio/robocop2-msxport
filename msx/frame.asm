; Game logic, module 3 (continued, BANK_LC3): main_loop after the game frame ($8144-$82E8): the
; cheat keys, the time out, the level's end and the death sequence. The main loop (rc2.asm)
; carries out what frame_end returns: the level again, game over or the next level.

FE_RESTART: equ 1                   ; a life less: level_init again ($82E4)
FE_OVER:    equ 2                   ; no life left ($82A8)
FE_NEXT:    equ 3                   ; the level done ($81B8: $8050 + 1)

; -> A = 0 (the next frame) or FE_...
; - With the cheats on ($804F): key 59h ends the level, 58h fills the energy.
; - Time out ($804C, set by the timer) while not dying: message $865A and dying ($16CC).
; - The level done ($16D0): 100 points a frame (sound 26h every 4th), $16C4 counts down; then
;   the fade out, and once it is dark the next level.
; - Dying ($16CC): state 16 asked, the controls locked and cleared, $16BC += 4; below 60h an
;   explosion around RoboCop (fe_boom); from 60h the head in the lost life's slot (graphics 3-5
;   while $16BC - 30h < 5Fh); below 100h the fade out, and once dark a life less.
frame_end:
        ld a,(AG + (0x804F ^ 1))
        or a
        jr z,fe_time
        ld a,(g_key)
        cp 0x59
        jr nz,fe_c2
        ld a,0xFF
        ld (AM + (0x16D0 ^ 1)),a
fe_c2:  ld a,(g_key)
        cp 0x58
        jr nz,fe_time
        ld hl,0x102
        ld (AM + 0x169A),hl
fe_time:
        ld a,(AG + (0x804C ^ 1))
        or a
        jr z,fe_lv
        ld a,(AM + (0x16CC ^ 1))
        or a
        jr nz,fe_lv
        ld a,HUD_MSG_865A
        call game_msg
        ld a,0xFF
        ld (AM + (0x16CC ^ 1)),a
fe_lv:  ld a,(AM + (0x16D0 ^ 1))
        or a
        jr z,fe_dead
        ld a,(g_frame)
        and 3
        jr nz,fe_sc
        ld a,0x26
        ld (snd_b31),a
fe_sc:  ld de,0x100
        call add_score
        ld hl,(AM + 0x16C4)
        dec hl
        ld (AM + 0x16C4),hl
        bit 7,h
        jr z,fe_dead
        xor a
        ld (p_fadein),a
        ld a,(p_fade)
        or a
        jr nz,fe_dead
        ld hl,(AG + 0x8050)
        inc hl
        ld (AG + 0x8050),hl
        ld a,FE_NEXT
        ret
fe_dead:
        ld a,(AM + (0x16CC ^ 1))
        or a
        ret z
        ld hl,0x10
        ld (p_pend),hl
        ld hl,0
        ld (AG + 0x802E),hl         ; (clr.w $802E: the joystick byte and the next)
        ld a,0xFF
        ld (g_lock),a
        ld hl,(AM + 0x16BC)
        push hl
        ld de,4
        add hl,de
        ld (AM + 0x16BC),hl
        pop hl                      ; D3
        ld de,0x60
        call fe_cmp
        jp p,fe_late
        ld de,fe_boom               ; an explosion around him
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,(p_x)
        add hl,de
        ex (sp),hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,(p_y)
        add hl,de
        ld de,-0x46
        add hl,de
        ex de,hl
        pop hl
        ld bc,0
        call expl_add
        xor a
        ret
fe_late:
        push hl
        ld de,-0x30
        add hl,de
        ld de,0x5F
        call fe_cmp
        jp p,fe_nohd
        ld a,l
        rrca
        rrca
        rrca
        rrca
        and 15                      ; D0 = (D3 - 30h) >> 4
        ld b,a
        ld hl,(AG + 0x8034)
        dec hl                      ; D1 = lives - 1
        bit 7,h
        jr nz,fe_nohd
        ld a,h
        or a
        jr nz,fe_nohd
        ld a,l
        cp 2
        jr nc,fe_nohd
        ld c,a
        ld a,b
        call head_draw              ; ($88DE)
fe_nohd:
        pop hl
        ld de,0x100
        call fe_cmp
        jp p,fe_wait
        xor a
        ld (p_fadein),a
        ld a,(p_fade)
        or a
        jr nz,fe_wait
        ld hl,(AG + 0x8034)
        dec hl
        ld (AG + 0x8034),hl
        bit 7,h
        ld a,FE_RESTART
        ret z
        ld a,FE_OVER
        ret
fe_wait:
        xor a
        ret

; HL - DE as the 68000's cmp.w: S, Z of the difference. Keeps HL, DE.
fe_cmp: push hl
        or a
        sbc hl,de
        pop hl
        ret
