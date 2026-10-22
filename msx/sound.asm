; Sound: the PSG (always), and for the title music an SCC (in the cartridge's slot) and an OPLL
; (MSX-MUSIC built in, or an FM-PAC cartridge) when found at the start (music.asm mus_init). The
; music and the sound effects come from the game's tunes (the Amiga's MU1 player: music and
; effects are tunes of the same format); this file holds the hardware layer and the per-frame
; hook (snd_frame, from the VBLANK interrupt).
;
; Port rules: the PSG's address latch (A0h) is shared with the joystick reads (player.asm
; stick_bits: R14/R15 with interrupts disabled), so outside the interrupt every PSG access runs
; with interrupts disabled; R7 keeps bit 7 set and bit 6 clear (port B output, port A input).

PSG_ADDR:   equ 0xA0
PSG_DATA:   equ 0xA1
PSG_IN:     equ 0xA2
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

; ----- the SCC (music.asm's title music) -----

; The SCC is in the cartridge's own slot (its mapper's bank 3Fh at 8000h shows the registers at
; 9800h: a Konami SCC or flash cartridge) or in another primary slot, not expanded (an SCC or
; SCC+ cartridge beside a MegaRAM: page 2 switched to it through port A8h for each access;
; scc_pg2 = its slot in A8h's bits 4-5, 0 for the cartridge's own). The code between scc_open
; and scc_close runs here, in the fixed area (page 2 may not be the cartridge's meanwhile); the
; interrupts off (or the VBLANK interrupt).

PPI_SLOT:   equ 0xA8

; HL = an SCC register (9800h-98FFh), A = its value. Keeps HL, DE.
scc_wr: push af
        call scc_open
        pop af
        ld (hl),a
        jr scc_close

; DE = a channel's waveform (9800h + 32 x channel): scc_wb's 32 bytes there.
scc_wv: call scc_open
        ld hl,scc_wb
        ld bc,32
        ldir
scc_close:
        ld a,(scc_pg2)
        or a
        jr nz,scl_x
        ld a,(act_8000)
        ld (BANK_8000),a
        ret
scl_x:  ld a,(scc_a8)
        out (PPI_SLOT),a
        ret

; The SCC's registers at 9800h-98FFh. Uses AF, C.
scc_open:
        ld a,(scc_pg2)
        or a
        jr nz,sco_x
        ld a,0x3F
        ld (BANK_8000),a
        ret
sco_x:  ld c,a
        in a,(PPI_SLOT)
        ld (scc_a8),a
        and 0xCF
        or c
        out (PPI_SLOT),a
        ret

; At power-on (music.asm mus_init, the interrupts off), when the cartridge has none: an SCC in
; another primary slot that is not expanded, the first where 8000h is not RAM and 9800h keeps
; what is written there after 3Fh at 9000h (scc_pat; a Konami SCC cartridge's mapper, an SCC+ in
; SCC mode: the registers at 9800h) -> scc_pg2 = that slot in A8h's bits 4-5 (0: none).
scc_scan:
        xor a
        ld (scc_pg2),a
        in a,(PPI_SLOT)
        ld d,a                      ; D = A8h as it is,
        and 0x30
        ld e,a                      ; E = the cartridge's page 2 (its slot in bits 4-5),
        ld c,0                      ; C = the slot tried (bits 4-5)
ssc_lp: ld a,c
        cp e
        jr z,ssc_n
        rrca
        rrca
        rrca
        rrca
        add a,EXPTBL & 0xFF
        ld l,a
        ld h,EXPTBL / 256
        bit 7,(hl)
        jr nz,ssc_n                 ; (expanded: its page 2 would need its secondary register)
        ld a,d
        and 0xCF
        or c
        out (PPI_SLOT),a
        ld hl,0x8000
        ld a,(hl)
        ld b,a
        cpl
        ld (hl),a
        cp (hl)
        ld (hl),b
        jr z,ssc_r                  ; (RAM: written back)
        ld a,0x3F
        ld (0x9000),a
        call scc_pat
        jr nz,ssc_r
        ld a,c
        ld (scc_pg2),a
ssc_r:  ld a,d
        out (PPI_SLOT),a
        ld a,(scc_pg2)
        or a
        ret nz
ssc_n:  ld a,c
        add a,0x10
        ld c,a
        cp 0x40
        jr c,ssc_lp
        ret

; Z when the SCC's first waveform byte (9800h, page 2 showing its registers) keeps four values
; written there, each read back after about 1 ms: an emulated SCC may answer there alone, or
; late (8 bytes at 9800h-9807h read back at once missed the MSX Pico+'s, the user's,
; 2026-10-22). ROM there, or a MegaRAM or Konami mapper (a write there selects the 8000h bank),
; gives NZ. Uses AF, B, HL.
scc_pat:
        ld hl,0x9800
        ld a,0x5A
scp_lp: ld (hl),a
        ld b,0
scp_w:  djnz scp_w                  ; (3300 T-states)
        cp (hl)
        ret nz
        add a,0x65                  ; (5Ah, BFh, 24h, 89h)
        cp 0xEE
        jr nz,scp_lp
        xor a                       ; (Z)
        ret

; ----- the players (sndplay.asm in BANK_INPUT, music.asm in BANK_MUSIC) -----

; From the VBLANK interrupt: the title music on the SCC / OPLL while it plays (music.asm), then
; the PSG player's requests queued since, its music and effects.
snd_frame:
        ld a,(mus_on)
        or a
        jr z,sf_psg
        ld a,BANK_MUSIC
        ld hl,mus_frame
        call snd_bk
sf_psg: ld hl,sq_frame
; HL = a routine of the PSG player: called with BANK_INPUT at A000h (the window's bank back
; after; act_a000 kept: the interrupts disabled, or the VBLANK interrupt itself). Keeps DE, IX,
; IY.
snd_bank:
        ld a,BANK_INPUT
; A = BANK_INPUT or BANK_MUSIC, HL = a routine there: the same.
snd_bk: push de
        push ix
        ld (BANK_A000),a
        call fc_hl
sbk_r:  ld a,(act_a000)
        ld (BANK_A000),a
        pop ix
        pop de
        ret

; From sndplay.asm (BANK_INPUT at A000h, in the VBLANK interrupt) with an SCC: effect A starts
; on the SCC and the PSG (fx_go: music.asm fx_start), or the effects advance a tick (fx_tk:
; fx_tick), with BANK_MUSIC at A000h meanwhile; BANK_INPUT again after.
fx_go:  ld hl,fx_start
        jr fx_bk
fx_tk:  ld hl,fx_tick
fx_bk:  ld c,a
        ld a,BANK_MUSIC
        ld (BANK_A000),a
        ld a,c
        call fc_hl
fxb_r:  ld a,BANK_INPUT
        ld (BANK_A000),a
        ret

; HL = a routine of music.asm (BANK_MUSIC at A000h around it; the bank that was there comes
; back). Keeps nothing but what the routine leaves in RAM.
mus_call:
        ld a,(act_a000)
        push af
        ld a,BANK_MUSIC
        call bank_a000
        call fc_hl
        pop af
        jp bank_a000

; The title's music from its start: on the SCC / OPLL at once (music.asm), else queued for the
; PSG player (the VBLANK interrupt starts it).
snd_music:
        ld a,(mus_mode)
        or a
        ld a,SQ_MUSIC
        jr z,snd_play
        ld hl,mus_start
        jr mus_call

; Everything silent ($18004): the SCC / OPLL and the PSG at once, the PSG player's voices at the
; next VBLANK. (At power-on rc2.asm calls sq_init through snd_bank: the interrupts stay off.)
snd_stop:
        ld a,(mus_mode)
        or a
        ld hl,mus_stop
        call nz,mus_call
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
