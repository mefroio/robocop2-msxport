; VDP routines (V9938/V9958).
; Interrupts may be enabled: every port 99h sequence (register write, VRAM address,
; status read) runs with interrupts disabled and leaves R#15 = 0 (see isr.asm).

; Writes A to register B.
wrreg:  di
        out (VDP_CTRL),a
        ld a,b
        or 0x80
        out (VDP_CTRL),a
        ei
        ret

; Z if the command engine is idle (S#2 bit 0 = CE). Does not block; changes only A.
vdp_busy:
        di
        ld a,2
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        in a,(VDP_CTRL)
        push af
        xor a
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        ei
        pop af
        and 1
        ret

; Waits for the end of the running command.
vdp_wait:
        call vdp_busy
        jr nz,vdp_wait
        ret

; Sends the 15 bytes at HL to R#32..R#46 (starts the command). cmd_lock keeps the split
; interrupt's play-field copy (isr.asm) off the registers; one it started just before is waited
; for.
vdp_cmd:
        ld a,1
        ld (cmd_lock),a
        call vdp_wait
        di
        ld a,32
        out (VDP_CTRL),a
        ld a,0x80+17
        out (VDP_CTRL),a
        ei
        ld bc,15*256 + VDP_IND
        otir
        xor a
        ld (cmd_lock),a
        ret

; vdp_cmd for a command drawing into lines the screen shows (HL = its 15 bytes, the VDP idle):
; R#32-R#45 now, the start (R#46) only between the HUD split and the VBLANK interrupt
; (split_armed = 0), tested and written with the interrupts off, so that it is done long before
; the beam draws those lines again. Z when it started, NZ (nothing started) otherwise.
vdp_cmd_q:
        ld a,(split_armed)
        or a
        ret nz
        ld a,1
        ld (cmd_lock),a
        call vdp_busy
        jr nz,vcq_no                ; (the split interrupt started a play-field copy)
        di
        ld a,32
        out (VDP_CTRL),a
        ld a,0x80+17
        out (VDP_CTRL),a
        ei
        ld bc,14*256 + VDP_IND
        otir                        ; R#32-R#45
        ld b,(hl)                   ; (the command)
        di
        ld a,(split_armed)
        or a
        jr nz,vcq_late
        ld a,b
        out (VDP_CTRL),a
        ld a,0x80+46
        out (VDP_CTRL),a            ; R#46: it starts
        ei
        xor a
        ld (cmd_lock),a
        ret
vcq_late:
        ei
vcq_no: xor a
        ld (cmd_lock),a
        inc a
        ret

; Sets the VRAM write address E:HL (E = bit 16) for port 98h; the stream that follows ends
; with vram_done (isr.asm: the VBLANK interrupt writes the SAT of a new list itself).
vram_write:
        di
        ld a,1
        ld (vram_busy),a
        ld a,h
        rlca
        rlca
        and 3
        sla e
        sla e
        or e
        out (VDP_CTRL),a
        ld a,0x8E
        out (VDP_CTRL),a            ; R#14 = A16..A14
        ld a,l
        out (VDP_CTRL),a
        ld a,h
        and 0x3F
        or 0x40
        out (VDP_CTRL),a
        ei
        ret

; The end of a VRAM stream: the y's of alternating sprites the VBLANK interrupt left meanwhile
; go now (sprites.asm sat_mux_out; still early in the frame: the streams are short). Keeps BC,
; DE, HL.
vram_done:
        di
        xor a
        ld (vram_busy),a
        ld a,(sat_due)
        or a
        jr z,vd_x
        push bc
        push hl
        call sat_mux_out
        pop hl
        pop bc
vd_x:   ei
        ret

; Copies B*256 bytes from HL to port 98h (B = 0: 64 KiB is not supported).
vram_blocks:
        ld c,VDP_DATA
vb_lp:  push bc
        ld b,0
        otir
        pop bc
        djnz vb_lp
        ret

; E = banks of 8 KiB: the tiles from the ROM -> VRAM from 10000h (8 at the start: 10000h-1FFFFh,
; the HUD and the sprite tables follow; 4 after a SCREEN 8 picture: G7 interleaves its bytes
; over both halves of VRAM, so a picture overwrites 10000h-16A00h).
tiles_upload:
        push de
        ld e,1
        ld hl,0
        call vram_write
        pop de
        ld d,BANK_TILES
ut_bank:
        ld a,d
        call bank_8000
        ld hl,0x8000
        ld b,32
        push de
        call vram_blocks
        pop de
        inc d
        dec e
        jr nz,ut_bank
        jp vram_done

; The HUD's empty panel: page 3 from line HUD_VRAM_LINE (after the tiles, which cover pages 2-3);
; also at each new game (cold.asm hud_init: the last game's digits and message go). Keeps the
; 8000h window.
hud_upload:
        ld a,(act_8000)
        push af
        ld e,1
        ld hl,VRAM_HUD & 0xFFFF
        call vram_write
        ld a,HUD_IMG_BANK
        call bank_8000
        ld hl,0x8000
        ld b,HUD_LINES/2            ; 128 bytes per line: 256 per pair of lines
        call vram_blocks
        if HUD_LINES & 1
        ld bc,128*256 + VDP_DATA
        otir                        ; the odd last line
        endif
        call vram_done
        pop af
        jp bank_8000

; (cold.asm vdp_setup) tiles_upload with the front end's bank back at 8000h.
tiles_upf:
        call tiles_upload
        ld a,BANK_FRONT
        jp bank_8000
