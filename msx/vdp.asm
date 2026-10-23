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

; The end of a VRAM stream. Keeps BC, DE, HL.
vram_done:
        xor a
        ld (vram_busy),a
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

