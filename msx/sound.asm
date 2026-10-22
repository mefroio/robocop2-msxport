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
ssc_lp:
        if DIAG
        ld a,0xFD                   ; (test build: FDh, the slot, then E expanded, R RAM, or the
        call dg_rec                 ;  test's FEh)
        ld a,c
        call dg_rec
        endif
        ld a,c
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
        if DIAG
        jr z,ssc_ne
        ld a,'E'
        call dg_rec
        jr ssc_n
ssc_ne:
        else
        jr nz,ssc_n                 ; (expanded: its page 2 would need its secondary register)
        endif
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
        if DIAG
        jr nz,ssc_nr
        ld a,'R'
        call dg_rec
        jr ssc_r
ssc_nr:
        else
        jr z,ssc_r                  ; (RAM: written back)
        endif
        ld a,0x3F
        ld (0x9000),a
        ld a,3                      ; (three of the four values: an unknown cartridge)
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

; A = how many of four values must have answered (1 in the cartridge's own slot, whose image
; tools/mkrom.py checks; 3 in another slot, an unknown cartridge) -> Z when, over up to eight
; tries, that many different values written to the SCC's first waveform byte (9800h, page 2
; showing its registers) were read back about 1 ms later. An emulated SCC may not answer at times:
; the MSX Pico+ on the user's SX-2 read back 00 one time in four to two in four while its stores
; always landed (their test cartridges, 2026-10-22). ROM there, an empty slot, a MegaRAM or a
; Konami mapper (a write there selects the 8000h bank) answer none of them in ours. Uses AF, B.
scc_pat:
        if DIAG
        push af
        ld a,0xFE                   ; (test build: FEh, C, then every value read)
        call dg_rec
        ld a,c
        call dg_rec
        pop af
        endif
        ld (scp_need),a
        xor a
        ld (scp_mask),a
        ld a,8
        ld (scp_try),a
scp_t:  ld a,0x5A
scp_lp: ld (0x9800),a               ; (fixed addresses: see scc_pv)
        ld b,0
scp_w:  djnz scp_w                  ; (3300 T-states)
        ld b,a
        ld a,(0x9800)
        if DIAG
        call dg_rec
        endif
        cp b
        jr nz,scp_nx
        ld a,b                      ; (read back: its bit, 1 << (value & 3), in scp_mask)
        and 3
        inc a
        push bc
        ld b,a
        ld a,0x80
scp_bt: rlca
        djnz scp_bt
        pop bc
        push hl
        ld hl,scp_mask
        or (hl)
        ld (hl),a
        pop hl
scp_nx: ld a,b
        add a,0x65                  ; (5Ah, BFh, 24h, 89h)
        cp 0xEE
        jr nz,scp_lp
        ld a,(scp_mask)             ; (how many values read back so far)
        ld b,0
scp_cn: srl a
        jr nc,scp_c0
        inc b
scp_c0: or a
        jr nz,scp_cn
        ld a,(scp_need)
        dec a
        cp b
        jr c,scp_ok                 ; (need - 1 < count: enough)
        ld a,(scp_try)
        dec a
        ld (scp_try),a
        jr nz,scp_t
        or 1                        ; (NZ)
        ret
scp_ok: xor a                       ; (Z)
        ret

        if DIAG
; (Test build, rc2.asm init: B = a mark: 'P', the mark and what the SCC's first waveform byte
; gives back of 5Ah, BFh, 24h, 89h stored there (3Fh at 9000h, about 1 ms each), logged; page 2
; must show the cartridge. Keeps every register.)
dg_probe:
        push af
        push bc
        ld a,'P'
        call dg_rec
        ld a,b
        call dg_rec
        ld a,0x3F
        ld (BANK_8000),a
        ld a,0x5A
dgp_lp: ld (0x9800),a
        ld b,0
dgp_w:  djnz dgp_w
        ld b,a
        ld a,(0x9800)
        call dg_rec
        ld a,b
        add a,0x65
        cp 0xEE
        jr nz,dgp_lp
        ld a,(act_8000)
        ld (BANK_8000),a
        pop bc
        pop af
        ret

; (Test build: A = a byte for dg_log. Keeps every register and flag.)
dg_rec: push hl
        ld hl,(dg_ptr)
        ld (hl),a
        inc hl
        ld (dg_ptr),hl
        pop hl
        ret
        endif

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
