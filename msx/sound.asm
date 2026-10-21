; Sound: the PSG (always) and an OPLL (MSX-MUSIC built in, or an FM-PAC cartridge) when one is
; found at the start. The music and the sound effects come from the game's tunes (the Amiga's
; MU1 player: music and effects are tunes of the same format); this file holds the hardware
; layer and the per-frame hook (snd_frame, from the VBLANK interrupt).
;
; Port rules: the PSG's address latch (A0h) is shared with the joystick reads (player.asm
; stick_bits: R14/R15 with interrupts disabled), so outside the interrupt every PSG access runs
; with interrupts disabled; R7 keeps bit 7 set and bit 6 clear (port B output, port A input).

PSG_ADDR:   equ 0xA0
PSG_DATA:   equ 0xA1
OPLL_ADDR:  equ 0x7C
OPLL_DATA:  equ 0x7D
PSG_MIX:    equ 0xBF                ; R7: no tone, no noise; port A input, port B output

; ----- at the start, with the BIOS in page 0 -----

; An OPLL: every slot's page 1 is searched for "OPLL" at 401Ch after "APRL" (MSX-MUSIC) or
; "PAC2" (FM-PAC, whose I/O ports are then switched on: bit 0 of 7FF6h in its slot).
; snd_fm = 1 when found. Uses the BIOS (RDSLT, WRSLT); interrupts end up disabled.
snd_detect:
        xor a
        ld (snd_fm),a
        ld c,0                      ; primary slot
sdt_p:  ld hl,EXPTBL
        ld e,c
        ld d,0
        add hl,de
        ld a,(hl)
        and 0x80
        or c
        ld b,a                      ; slot id (expanded: secondary 0 first)
sdt_s:  push bc
        ld a,b
        call sdt_try
        pop bc
        ret z                       ; found
        bit 7,b
        jr z,sdt_np                 ; not expanded: the next primary slot
        ld a,b
        add a,4
        ld b,a
        and 0x0C
        jr nz,sdt_s                 ; secondary 1-3
sdt_np: inc c
        ld a,c
        cp 4
        jr c,sdt_p
        or 1                        ; (NZ: none)
        ret

; A = slot id: Z when its page 1 holds an OPLL BIOS (then snd_fm = 1, the FM-PAC's ports on).
sdt_try:
        ld (snd_slot),a
        ld hl,0x401C
        ld de,sdt_opll
        ld b,4
        call sdt_cmp
        ret nz
        ld hl,0x4018
        ld de,sdt_aprl
        ld b,4
        call sdt_cmp
        jr z,sdt_yes
        ld hl,0x4018
        ld de,sdt_pac2
        ld b,4
        call sdt_cmp
        ret nz
        ld a,(snd_slot)             ; an FM-PAC: its I/O ports on
        ld hl,0x7FF6
        ld e,1
        call WRSLT
sdt_yes:
        ld a,1
        ld (snd_fm),a
        xor a                       ; (Z)
        ret

; HL = address in the slot snd_slot, DE = text, B = length: Z when they match.
sdt_cmp:
        push bc
        push de
        push hl
        ld a,(snd_slot)
        call RDSLT
        pop hl
        pop de
        pop bc
        ex de,hl
        cp (hl)
        ex de,hl
        ret nz
        inc hl
        inc de
        djnz sdt_cmp
        ret

sdt_opll:   db "OPLL"
sdt_aprl:   db "APRL"
sdt_pac2:   db "PAC2"

; ----- the chips -----

; Everything silent: the PSG's volumes 0 and its mixer (PSG_MIX); with an OPLL, its 9 channels
; keyed off at volume 15 (the quietest) and its rhythm off.
snd_init:
        di
        ld a,7
        ld e,PSG_MIX
        call psg_w
        ld a,8
        ld e,0
        call psg_w
        ld a,9
        call psg_w
        ld a,10
        call psg_w
        ei
        ld a,(snd_fm)
        or a
        ret z
        ld a,0x0E
        ld e,0
        call opll_w                 ; rhythm off
        ld b,9
        ld c,0
sin_ch: ld a,0x20
        add a,c
        ld e,0
        call opll_w                 ; key off, block 0, F-number 0
        ld a,0x30
        add a,c
        ld e,0x0F
        call opll_w                 ; instrument 0, volume 15
        inc c
        djnz sin_ch
        ret

; A = PSG register, E = value (interrupts disabled outside the interrupt). Keeps BC, DE, HL.
psg_w:  out (PSG_ADDR),a
        ld a,e
        out (PSG_DATA),a
        ret

; A = OPLL register, E = value, with the chip's waits (12 cycles after the address, 84 after
; the data). Keeps BC, DE, HL.
opll_w: out (OPLL_ADDR),a
        push af
        pop af
        ld a,e
        out (OPLL_DATA),a
        push af                     ; 84 cycles
        pop af
        push af
        pop af
        push af
        pop af
        push af
        pop af
        ret

; ----- per frame (the VBLANK interrupt) -----

; The music and the sound effects advance one frame (the player comes with the converted
; tunes). Keeps the banks of both windows.
snd_frame:
        ret

; A = sound (the game's tune number), C = request slot ($18014 with D0, D2): the effect starts.
snd_play:
        ret
