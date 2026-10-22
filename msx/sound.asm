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

; ----- the chips -----

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

; ----- the player (sndplay.asm, BANK_INPUT) -----

; From the VBLANK interrupt: the requests queued since, then the music and the effects advance.
snd_frame:
        ld hl,sq_frame
; HL = a routine of the player, A its argument: called with BANK_INPUT at A000h (the window's
; bank back after; act_a000 kept: the interrupts disabled, or the VBLANK interrupt itself).
; Keeps DE, IX, IY.
snd_bank:
        push de
        push ix
        ld c,a
        ld a,BANK_INPUT
        ld (BANK_A000),a
        ld a,c
        call fc_hl
        ld a,(act_a000)
        ld (BANK_A000),a
        pop ix
        pop de
        ret

; The title's music from its start (queued: the VBLANK interrupt starts it).
snd_music:
        ld a,SQ_MUSIC
        jr snd_play

; Everything silent ($18004): the PSG at once, the voices at the next VBLANK. (At power-on
; rc2.asm calls sq_init through snd_bank: the interrupts stay off.)
snd_stop:
        ld a,SQ_STOP
; A = sound (the game's tune number; $18014 with D0): queued for the VBLANK interrupt, which
; starts it (the main program never keeps the interrupts off for it: the HUD's split).
snd_play:
        ld hl,sq_put
        ld c,a
        ld a,(act_a000)
        push af
        ld a,BANK_INPUT
        call bank_a000
        ld a,c
        call fc_hl
        pop af
        jp bank_a000
