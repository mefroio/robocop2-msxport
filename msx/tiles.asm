; Common tile code: map reads from the ROM and tile source in VRAM pages 2-3.

; get_tile: A = row, E = column -> HL = tile index. Preserves BC and DE.
get_tile:
        push de
        ld l,a
        ld h,0
        ld e,a
        ld d,0
        add hl,hl
        add hl,de                   ; row * 3 (rowtab: bank, address)
        ld de,rowtab
        add hl,de
        ld a,(hl)
        call bank_a000
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop de
        push de
        ld d,0
        add hl,de
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop de
        ret

; set_src: HL = tile index -> SX/SY in cmdbuf (tile i: x=(i&15)*16, y=512+(i&0x1F0)).
set_src:
        ld a,l
        and 0x0F
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+0),a
        xor a
        ld (cmdbuf+1),a
        ld a,l
        and 0xF0
        ld (cmdbuf+2),a
        ld a,h
        and 1
        add a,2
        ld (cmdbuf+3),a
        ret

; NZ if the VDP is still running a command (S#2 bit 0). Does not block.
vdp_busy:
        ld a,2
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        in a,(VDP_CTRL)
        and 1
        ld c,a
        xor a
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        ld a,c
        or a
        ret

; B = cam_x >> 4, C = cam_y >> 4
cam_cells:
        ld hl,(cam_x)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld b,a
        ld hl,(cam_y)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld c,a
        ret
