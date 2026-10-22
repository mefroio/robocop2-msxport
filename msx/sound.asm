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

; Every store to an SCC register is to a fixed address (ld (nn),a), as Konami's games store: on
; the user's SX-2, the MSX Pico+'s SCC missed a store or a load through (hl) or (de) one time in
; four (right after the instruction's own fetch), never one through (nn) (their test cartridges,
; 2026-10-22). The waveforms go with ldir (each store after a load).

; B = an SCC channel (0-3), C = its record's ctl or MV_NEW (bit 4: DE is a period to set), A =
; its volume: those to the SCC and its channels on again (1-3 while the title music plays, 0-3
; for the effects: a store the chip missed does not keep them silent). scc_pv: through scc_open
; and scc_close; scc_pvs: the SCC's registers at 9800h already. Keeps BC, DE, HL.
scc_pv: push bc
        push af
        call scc_open
        pop af
        pop bc
        call scc_pvs
        jp scc_close
scc_pvs:
        push af
        ld a,b
        or a
        jr z,spv_0
        dec a
        jr z,spv_1
        dec a
        jr z,spv_2
        bit 4,c
        jr z,spv_3v
        ld a,e
        ld (SCC_FREQ + 6),a
        ld a,d
        ld (SCC_FREQ + 7),a
spv_3v: pop af
        ld (SCC_VOL + 3),a
        jr spv_on
spv_0:  bit 4,c
        jr z,spv_0v
        ld a,e
        ld (SCC_FREQ + 0),a
        ld a,d
        ld (SCC_FREQ + 1),a
spv_0v: pop af
        ld (SCC_VOL + 0),a
        jr spv_on
spv_1:  bit 4,c
        jr z,spv_1v
        ld a,e
        ld (SCC_FREQ + 2),a
        ld a,d
        ld (SCC_FREQ + 3),a
spv_1v: pop af
        ld (SCC_VOL + 1),a
        jr spv_on
spv_2:  bit 4,c
        jr z,spv_2v
        ld a,e
        ld (SCC_FREQ + 4),a
        ld a,d
        ld (SCC_FREQ + 5),a
spv_2v: pop af
        ld (SCC_VOL + 2),a
spv_on: ld a,(mus_on)
        or a
        ld a,7
        jr nz,spv_e
        ld a,0x0F
spv_e:  ld (SCC_ON),a
        ret

; A = the SCC's channels on (bits 0-4). Keeps BC, DE, HL.
scc_on: push bc
        push af
        call scc_open
        pop af
        ld (SCC_ON),a
        pop bc
        jr scc_close

; Every SCC channel at volume 0. Keeps BC, DE, HL.
scc_v0: push bc
        call scc_open
        xor a
        ld (SCC_VOL + 0),a
        ld (SCC_VOL + 1),a
        ld (SCC_VOL + 2),a
        ld (SCC_VOL + 3),a
        ld (SCC_VOL + 4),a
        pop bc
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
; written there, each read back after about 1 ms, in one of four tries: an emulated SCC may answer
; late, or miss one (the MSX Pico+'s, the user's, 2026-10-22). ROM there, or a MegaRAM or Konami
; mapper (a write there selects the 8000h bank), never answers. Uses AF, B.
scc_pat:
        ld a,4                      ; (up to four tries)
scp_t:  push af
        ld a,0x5A
scp_lp: ld (0x9800),a               ; (fixed addresses: see scc_pv)
        ld b,0
scp_w:  djnz scp_w                  ; (3300 T-states)
        ld b,a
        ld a,(0x9800)
        cp b
        jr nz,scp_n
        ld a,b
        add a,0x65                  ; (5Ah, BFh, 24h, 89h)
        cp 0xEE
        jr nz,scp_lp
        pop af
        xor a                       ; (Z)
        ret
scp_n:  pop af
        dec a
        jr nz,scp_t
        inc a                       ; (NZ)
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
