; VDP routines (V9938/V9958). They run with interrupts disabled.

; Writes A to register B.
wrreg:  out (VDP_CTRL),a
        ld a,b
        or 0x80
        out (VDP_CTRL),a
        ret

; Waits for the end of the VDP command (S#2 bit 0 = CE).
vdp_wait:
        ld a,2
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
vw_lp:  in a,(VDP_CTRL)
        rrca
        jr c,vw_lp
        xor a
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        ret

; Sends 15 bytes at HL to R#32..R#46 (starts the command).
vdp_cmd:
        ld a,32
        out (VDP_CTRL),a
        ld a,0x80+17
        out (VDP_CTRL),a
        ld bc,15*256 + VDP_IND
        otir
        ret

; Waits for the start of VBLANK (S#0 bit 7; reading clears the flag).
wait_vbl:
        in a,(VDP_CTRL)
        and 0x80
        jr z,wait_vbl
        ret

; NZ if a VBLANK is already pending.
vbl_pending:
        in a,(VDP_CTRL)
        and 0x80
        ret

; SCREEN 5 + settings, VDP ID, palette and tiles (pages 2-3) from the ROM.
vdp_setup:
        ld a,5
        call CHGMOD
        di
        ld a,1
        ld b,15
        call wrreg
        in a,(VDP_CTRL)             ; S#1: ID in bits 5..1
        rrca
        and 0x1F
        ld (vdp_id),a
        xor a
        ld b,15
        call wrreg
        xor a
        ld b,7
        call wrreg                  ; border colour = 0
        ld a,0x0A
        ld b,8
        call wrreg                  ; sprites off (SPD), VR=1
        ld a,(RG9SAV)
        and 0x7F
        ld b,9
        call wrreg                  ; 192 lines
        xor a
        ld b,1
        call wrreg                  ; display off during the upload
        xor a
        ld b,16
        call wrreg
        ld hl,palette
        ld bc,32*256 + VDP_PAL
        otir
        ; tiles: 64 KiB from the ROM -> VRAM 10000h-1FFFFh
        ld a,4
        ld b,14
        call wrreg
        xor a
        out (VDP_CTRL),a
        ld a,0x40
        out (VDP_CTRL),a
        ld d,BANK_TILES
        ld e,8
ut_bank:
        ld a,d
        call bank_8000
        ld hl,0x8000
        ld c,VDP_DATA
        push de
        ld e,32
ut_blk: ld b,0
        otir
        dec e
        jr nz,ut_blk
        pop de
        inc d
        dec e
        jr nz,ut_bank
        ; fixed parameters of the tile HMMM
        ld hl,16
        ld (cmdbuf+8),hl
        ld (cmdbuf+10),hl
        xor a
        ld (cmdbuf+12),a
        ld (cmdbuf+13),a
        ld a,0xD0
        ld (cmdbuf+14),a
        ld a,0x40
        ld b,1
        jp wrreg                    ; display on, no VDP interrupt
