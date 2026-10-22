; The title music on an SCC and / or an OPLL, and RoboCop's speech (BANK_MUSIC at A000h around
; every call: mus_call from the main program, snd_frame from the VBLANK interrupt).
;
; The chips (mus_init, at power-on): an SCC answering in the cartridge's own slot (the Konami SCC
; mapper: 3Fh written to 9000h shows its registers at 9800h; an SCC+ starts in SCC mode; a
; MegaRAM has none), else in another primary slot (an SCC or SCC+ cartridge: sound.asm scc_scan;
; every access goes through sound.asm scc_wr / scc_wv), and the OPLL cold.asm snd_detect found.
; mus_mode then says what plays the title music (tools/msxscc.py, tools/msxfm.py: the Amiga's
; channels 0-2 and its drums, channel 3), the user's request for "the closest to the Amiga":
;   SCC:           the melody on SCC channels 1-3, the drums on PSG voice C;
;   OPLL:          the melody on OPLL channels 0-2, the drums on its rhythm section;
;   SCC and OPLL:  the melody on the SCC (the samples' own waveforms), the drums on the OPLL;
;   neither:       mus_mode 0: the PSG player's title (sndplay.asm).
; In game, with an SCC, the sound effects play there too (their tonal part; their noise on the
; PSG: fx_start below); without one, on the PSG player.
;
; RoboCop's speech keeps its place in the music here (tick VOICE_TICK; the user's choice for the
; SCC): the tick raises mus_speak and front.asm front_fire plays it (vm_music) as PSG PCM: for its
; VOICE_TICKS ticks the chips are muted and the PCM is the Amiga's four channels (the speech with
; the bass and the drums going on: tools/msxvoice.py voice_mix.bin); then the voices take up the
; state tools/mkrom.py computed for the tick after (mus_snap_...), the chips with them. (A music
; tick inside the PCM loop held the samples 0.4-1 ms every 20 ms, measured in openMSX: a buzz.)
; While the music plays, PSG voices A and B hold the PCM's middle level (a DC: silent), so the PCM
; starts and ends without a step. With the PSG alone the speech plays when the player starts
; (vm_alone: the music stopped, the user's choice for the PSG).
;
; The streams (one per voice: three melodic, the drums; read through the 8000h window from their
; banks on, crossing banks): records of a duration in ticks (1-255; 0: the end, the voice goes on
; at its stream's start) and a ctl byte, then the fields its bits give (a field not given keeps
; the voice's value):
;   SCC:          bits 0-3 the volume; 4: the period N (a word); 5: the waveform (a byte, after
;                 the word);
;   PSG drums:    sndplay.asm's format: bits 0-3 the volume, 4 tone on, 5 noise on; 6: the tone
;                 period (a word); 7: the noise period (a byte);
;   OPLL:         bits 0-3 the volume (attenuation); 4: the F-number and block (a word: its high
;                 byte is register 20h's low nibble); 5: the instrument (a byte: bits 4-7, bit 0
;                 sustain); 6: key on; 7: the key off and on again first (a new note);
;   OPLL rhythm:  bits 0-4 the keys struck (as register 0Eh); 5: the volumes for 36h-38h (3 bytes).
; Every stream lasts the tune's loop (5184 ticks), so the voices stay in step.

MV_PTR:     equ 0                   ; 2: the next record (8000h-9FFFh)
MV_BANK:    equ 2                   ;   its bank
MV_LEFT:    equ 3                   ; ticks left of the record in effect (0: the voice unused)
MV_CTL:     equ 4                   ; the record's ctl
MV_PER:     equ 5                   ; 2: the period (SCC, PSG) or the F-number and block (OPLL)
MV_AUX:     equ 7                   ; the waveform (SCC), instrument (OPLL) or noise period (PSG)
MV_SPTR:    equ 8                   ; 2: the stream's start
MV_SBANK:   equ 10                  ;   its bank
MV_NEW:     equ 11                  ; this tick: 0 no record, else bit 0 and the fields given (bit 4
                                    ;   the word, bit 5 the byte or the rhythm's volumes, bit 7 the
                                    ;   ctl's bit 7: an OPLL note again)
MV_RV:      equ 12                  ; 3: the rhythm's volumes (36h-38h)
MV_KIND:    equ 15                  ; the stream's format (MVK_...)
MV_SIZE:    equ 16
MVK_SCC:    equ 0
MVK_PSG:    equ 1
MVK_FM:     equ 2
MVK_RHY:    equ 3

MM_SCC:     equ 1                   ; mus_mode: the melody on the SCC,
MM_FM:      equ 2                   ;   on the OPLL,
MM_RHY:     equ 4                   ;   the drums on the OPLL's rhythm section (else on PSG voice C)

SCC_REGS:   equ 0x3F                ; the bank number that shows the SCC's registers at 9800h
SCC_WAVE:   equ 0x9800              ; 32 bytes a channel
SCC_FREQ:   equ 0x9880              ; 2 bytes a channel: the period's low 8 bits, its high 4
SCC_VOL:    equ 0x988A              ; a byte a channel (0-15)
SCC_ON:     equ 0x988F              ; bits 0-4: the channels on

; ----- at power-on -----

; rc2.asm init (after snd_init, through mus_call): the chips of the title music in mus_mode.
mus_init:
        di
        xor a
        ld (mus_on),a
        ld (mus_speak),a
        ld (mus_dc),a
        ld (snd_last),a
        ld (fx_act),a
        ld (fx_son),a
        call fx_wnone
        ld hl,mus_v + MV_LEFT       ; every voice idle (the music's, the effects' PSG ones)
        ld de,MV_SIZE
        ld b,4
mui_v:  ld (hl),a
        add hl,de
        djnz mui_v
        ld hl,fx_pv + MV_LEFT
        ld b,3
mui_p:  ld (hl),a
        add hl,de
        djnz mui_p
        if NO_SCC
        ld b,0
        else
        xor a
        ld (scc_pg2),a
        if NO_SCC_INT
        else
        call scc_detect
        ld b,a
        jr nz,mui_s
        endif
        call scc_scan               ; (another cartridge's)
        ld b,0
        jr z,mui_s
        ld b,MM_SCC
mui_s:
        endif
        if NO_FM
        else
        ld a,(snd_fm)
        or a
        jr z,mui_x
        ld a,b
        or a
        ld a,MM_FM | MM_RHY
        jr z,mui_f
        ld a,MM_RHY                 ; (the SCC plays the melody)
mui_f:  or b
        ld b,a
        endif
mui_x:  ld a,b
        ld (mus_mode),a
        ei
        ret

; An SCC in the cartridge's slot -> A = MM_SCC (NZ) when its waveform RAM keeps 8 bytes written
; there, else 0 (ROM there, or a MegaRAM: writes select its banks). The interrupts off; the
; 8000h window shows act_8000's bank after.
scc_detect:
        ld a,SCC_REGS
        ld (BANK_8000),a
        call scc_pat
        ld c,0
        jr nz,scd_x
        ld c,MM_SCC
scd_x:  ld a,(act_8000)
        ld (BANK_8000),a
        ld a,c
        or a
        ret

; ----- start, stop, the ticks -----

; front.asm front_title (snd_music through mus_call): the title music from its start. Its first
; records play at once; the VBLANK interrupt ticks it from then on.
mus_start:
        di
        call mus_quiet
        ld a,(mus_mode)
        ld hl,mus_scc               ; the melody's three streams
        ld c,MVK_SCC
        rra
        jr c,mst_m
        ld hl,mus_fm
        ld c,MVK_FM
mst_m:  ld ix,mus_v
        ld b,3
mst_v:  call mst_one
        djnz mst_v
        ld a,(mus_mode)             ; the drums'
        ld hl,mus_scc + 9
        ld c,MVK_PSG
        and MM_RHY
        jr z,mst_d
        ld hl,mus_fm + 9
        ld c,MVK_RHY
mst_d:  call mst_one
        ld a,(mus_mode)
        and MM_FM | MM_RHY
        call nz,mst_fm
        ld a,(mus_mode)
        rra
        jr nc,mst_t
        ld hl,SCC_ON                ; the SCC's channels 1-3 on (their volumes 0 until the
        ld a,7                      ; first records)
        call scc_wr
mst_t:  ld hl,0xFFFF                ; (the first tick makes it 0)
        ld (mus_tick),hl
        xor a
        ld (mus_div),a
        inc a
        ld (mus_on),a
        ld (mus_dc),a
        ld a,(snd_mix)              ; A and B: their level held (tone and noise off); C as well
        or 0x3F                     ; until the drums' first record
        and 0xBF
        ld (snd_mix),a
        ld e,a
        ld a,7
        call psg_w
        call dc_up
        call mus_adv                ; tick 0: every voice's first record
        ei
        ret

; HL = a stream's entry in mus_scc / mus_fm (its bank, its address), IX = a voice, C = the
; stream's kind: the voice reads it from the next tick on; IX and HL on the next ones. Keeps BC.
mst_one:
        ld a,(hl)
        ld (ix+MV_BANK),a
        ld (ix+MV_SBANK),a
        inc hl
        ld a,(hl)
        ld (ix+MV_PTR),a
        ld (ix+MV_SPTR),a
        inc hl
        ld a,(hl)
        ld (ix+MV_PTR+1),a
        ld (ix+MV_SPTR+1),a
        inc hl
        ld (ix+MV_KIND),c
        ld (ix+MV_LEFT),1
        ld de,MV_SIZE
        add ix,de
        ret

; The OPLL: the custom instrument (fm_patch: registers 00h-07h); with its rhythm, the rhythm's
; pitches (16h-18h, 26h-28h) and the rhythm mode on, no key struck.
mst_fm: ld hl,fm_patch
        ld c,0
        ld b,8
        call msf_w
        ld a,(mus_mode)
        and MM_RHY
        ret z
        ld c,0x16
        ld b,3
        call msf_w
        ld c,0x26
        ld b,3
        call msf_w
        ld a,0x0E
        ld e,0x20
        jp opll_w
msf_w:  ld a,c                      ; B registers from C on, their values from HL on
        ld e,(hl)
        call opll_w
        inc hl
        inc c
        djnz msf_w
        ret

; snd_stop (through mus_call): the music stops, its chips silent at once.
mus_stop:
        di
        call mus_quiet
        ei
        ret

; The voices idle, the chips silent (the SCC's channels off, the OPLL's keys and rhythm off, the
; drums' PSG voice C at volume 0). The interrupts off.
mus_quiet:
        xor a
        ld (mus_on),a
        ld (mus_speak),a
        ld ix,mus_v
        ld b,4
        ld de,MV_SIZE
muq_v:  ld (ix+MV_LEFT),a
        ld (ix+MV_NEW),a
        add ix,de
        djnz muq_v
        ld ix,fx_pv                 ; (the effects' PSG voices: their sound goes with snd_stop's)
        ld b,3
muq_e:  ld (ix+MV_LEFT),a
        ld (ix+MV_NEW),a
        add ix,de
        djnz muq_e
        ld (fx_act),a
        ld (fx_son),a
        call fx_wnone               ; (the music may load the channels' waveforms)
        ld a,(mus_mode)
        rra
        jr nc,muq_f
        ld hl,SCC_ON
        xor a
        call scc_wr                 ; every channel off,
        ld hl,SCC_VOL
        ld b,5
muq_s:  push bc
        xor a
        call scc_wr                 ;   at volume 0
        pop bc
        inc hl
        djnz muq_s
muq_f:  ld a,(mus_mode)
        and MM_FM | MM_RHY
        jr z,muq_p
        ld a,0x0E
        ld e,0
        call opll_w                 ; the rhythm off
        ld c,0x20
        ld b,3
muq_k:  ld a,c
        call opll_w                 ; channels 0-2: the key off
        inc c
        djnz muq_k
muq_p:  ld a,10
        out (PSG_ADDR),a
        xor a
        out (PSG_DATA),a            ; (voice C: the drums)
        ld hl,mus_dc
        cp (hl)
        ret z
        ld (hl),a
        ld a,(snd_mix)              ; A and B down from their level (C silent, its tone and
        or 0x3F                     ; noise off)
        and 0xBF
        ld (snd_mix),a
        ld e,a
        ld a,7
        call psg_w
        jp dc_down

; The PSG's voices up to (dc_up) or down from (dc_down) the level A and B hold under the music
; (voice_tab's VOICE_DC_IDX: VOICE_DC_A, VOICE_DC_B, C silent) along voice_tab, in about 20 ms
; (the interrupts off): a DC that never sounds, ramped so that it does not thump either.
dc_up:  ld c,0
dcu_lp: call dc_set
        ld a,c
        add a,4
        ld c,a
        cp VOICE_DC_IDX
        jr c,dcu_lp
        ld c,VOICE_DC_IDX
        jr dc_set
dc_down:
        ld c,VOICE_DC_IDX
dcd_lp: call dc_set
        ld a,c
        sub 4
        ld c,a
        jr nc,dcd_lp
        ld c,0
; C = a voice_tab index: the three voices' volumes (C, B, A: the table's order), then about
; 0.6 ms.
dc_set: ld b,voice_tab / 256
        ld a,10
        out (PSG_ADDR),a
        ld a,(bc)
        out (PSG_DATA),a
        inc b
        ld a,9
        out (PSG_ADDR),a
        ld a,(bc)
        out (PSG_DATA),a
        inc b
        ld a,8
        out (PSG_ADDR),a
        ld a,(bc)
        out (PSG_DATA),a
        ld b,160
dcs_w:  djnz dcs_w
        ret

; From the VBLANK interrupt (snd_frame, while mus_on): a tick 50 times a second (at 60 Hz every
; sixth VBLANK is skipped, as sndplay.asm does).
mus_frame:
        ld a,(RG9SAV)
        and 2
        jr nz,mus_adv
        ld hl,mus_div
        inc (hl)
        ld a,(hl)
        cp 6
        jr c,mus_adv
        ld (hl),0
        ret

; One tick (mus_frame): the voices' records, then the chips; mus_speak at VOICE_TICK. Uses AF,
; BC, DE, HL, IX; the 8000h window shows act_8000's bank after.
mus_adv:
        ld a,(mus_on)
        or a
        ret z
        ld hl,(mus_tick)
        inc hl
        ld (mus_tick),hl
        ld ix,mus_v
        ld b,4
ma_rd:  ld (ix+MV_NEW),0
        ld a,(ix+MV_LEFT)
        or a
        jr z,ma_n
        dec (ix+MV_LEFT)
        jr nz,ma_n
        push bc
        call mv_rec
        pop bc
ma_n:   ld de,MV_SIZE
        add ix,de
        djnz ma_rd
        ld hl,(mus_tick)            ; (after the records: voice 0 may have begun the loop again)
        ld de,VOICE_TICK
        or a
        sbc hl,de
        jr nz,ma_c
        ld a,1
        ld (mus_speak),a
ma_c:   ld a,(act_8000)             ; (the records' banks)
        ld (BANK_8000),a
        ld a,(mus_mode)
        rra
        call c,mo_scc
        ld a,(mus_mode)
        and MM_FM
        call nz,mo_fm3
        ld ix,mus_v + 3 * MV_SIZE
        ld a,(mus_mode)
        and MM_RHY
        jp nz,mo_rhy
        jp mo_psg

; IX = a voice of the music: its next record (at its stream's end the stream's start again:
; voice 0 then begins the tune's tick count again), MV_NEW for what it gives. Its bank stays at
; 8000h.
mv_rec: ld a,(ix+MV_BANK)
        ld (BANK_8000),a
        ld l,(ix+MV_PTR)
        ld h,(ix+MV_PTR+1)
mvr_rd: ld a,(hl)                   ; the duration (mr_byte inline: every record reads it)
        inc hl
        bit 5,h
        call nz,mr_next
        or a
        jr nz,mvr_go
        ld a,(ix+MV_SBANK)
        ld (ix+MV_BANK),a
        ld (BANK_8000),a
        ld l,(ix+MV_SPTR)
        ld h,(ix+MV_SPTR+1)
        push ix
        pop de
        ld a,e
        cp mus_v & 0xFF
        jr nz,mvr_rd
        ld de,0
        ld (mus_tick),de
        jr mvr_rd
mvr_go: ld (ix+MV_LEFT),a
        ld a,(hl)                   ; the ctl (D: as read, E: its field bits)
        inc hl
        bit 5,h
        call nz,mr_next
        ld (ix+MV_CTL),a
        ld d,a
        ld e,a
        ld a,(ix+MV_KIND)
        cp MVK_RHY
        jr z,mvr_rh
        cp MVK_PSG
        jr nz,mvr_f
        rrc e                       ; (the PSG's word and byte bits are 6 and 7)
        rrc e
mvr_f:  bit 4,e
        jr z,mvr_b
        call mr_byte
        ld (ix+MV_PER),a
        call mr_byte
        ld (ix+MV_PER+1),a
mvr_b:  bit 5,e
        jr z,mvr_x
        call mr_byte
        ld (ix+MV_AUX),a
mvr_x:  ld a,e
        and 0x30
        or 1
        bit 7,d
        jr z,mvr_o
        or 0x80
mvr_o:  ld (ix+MV_NEW),a
        ld (ix+MV_PTR),l
        ld (ix+MV_PTR+1),h
        ret
mvr_rh: bit 5,e
        jr z,mvr_x
        call mr_byte
        ld (ix+MV_RV),a
        call mr_byte
        ld (ix+MV_RV+1),a
        call mr_byte
        ld (ix+MV_RV+2),a
        jr mvr_x

; HL = a stream's next byte in the 8000h window, IX = its voice -> A = the byte, HL past it (at
; the window's end the voice's next bank, mapped). Keeps BC, DE.
mr_byte:
        ld a,(hl)
        inc hl
        bit 5,h
        ret z
mr_next:
        ld h,0x80
        push af
        ld a,(ix+MV_BANK)
        inc a
        ld (ix+MV_BANK),a
        ld (BANK_8000),a
        pop af
        ret

; ----- the chips -----

; Voices 0-2 on the SCC's channels 1-3: each record given this tick (mo_sc1).
mo_scc: ld ix,mus_v
        ld b,0
mos_lp: call mo_sc1
        ld de,MV_SIZE
        add ix,de
        inc b
        ld a,b
        cp 3
        jr nz,mos_lp
        ret

; IX = a voice on SCC channel B (0-3): the waveform (mo_wv), the period and the volume its
; record gave this tick. Keeps B, IX.
mo_sc1: ld c,(ix+MV_NEW)
        ld a,c
        or a
        ret z
        push bc
        bit 5,c
        jr z,mos_p
        ld a,b
        rrca
        rrca
        rrca
        ld e,a
        ld d,SCC_WAVE / 256         ; DE = 9800h + 32 x channel
        call mo_wv
mos_p:  pop bc
        push bc
        bit 4,c
        jr z,mos_v
        ld a,b
        add a,a
        add a,SCC_FREQ & 0xFF
        ld l,a
        ld h,SCC_FREQ / 256
        ld a,(ix+MV_PER)
        call scc_wr
        inc hl
        ld a,(ix+MV_PER+1)
        call scc_wr
mos_v:  pop bc
        push bc
        ld a,b
        add a,SCC_VOL & 0xFF
        ld l,a
        ld h,SCC_VOL / 256
        ld a,(ix+MV_CTL)
        and 15
        call scc_wr
        pop bc
        ret

; IX = a voice, DE = its SCC channel's waveform registers: waveform MV_AUX there, from the title
; music's table (scc_waves) or, while the music is off, the effects' (fx_waves; both here, at
; A000h): straight into the cartridge's own SCC, through scc_wb into another slot's (sound.asm
; scc_wv: page 2 is not this bank meanwhile).
mo_wv:  ld l,(ix+MV_AUX)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,scc_waves
        ld a,(mus_on)
        or a
        jr nz,mov_t
        ld bc,fx_waves
mov_t:  add hl,bc
        ld bc,32
        ld a,(scc_pg2)
        or a
        jr nz,mov_x
        ld a,SCC_REGS
        ld (BANK_8000),a
        ldir
        ld a,(act_8000)
        ld (BANK_8000),a
        ret
mov_x:  push de
        ld de,scc_wb
        ldir
        pop de
        jp scc_wv

; Voices 0-2 on the OPLL's channels 0-2: for each record given this tick, the key off first for
; a new note, the F-number, the instrument and volume, then the block, F-number bit 8, sustain
; and key.
mo_fm3: ld ix,mus_v
        ld b,0
mof_lp: ld a,(ix+MV_NEW)
        or a
        call nz,mo_fm
        ld de,MV_SIZE
        add ix,de
        inc b
        ld a,b
        cp 3
        jr nz,mof_lp
        ret
mo_fm:  ld c,a                      ; (C = MV_NEW, B = the channel)
        ld a,(ix+MV_AUX)
        and 1
        rrca
        rrca
        rrca                        ; (the sustain: register 20h's bit 5)
        ld d,a
        ld a,(ix+MV_PER+1)
        and 0x0F
        or d
        ld d,a                      ; D = register 20h without the key
        bit 7,c
        jr z,mof_f
        ld a,0x20
        add a,b
        ld e,d
        call opll_w                 ; the key off: the note starts again
mof_f:  bit 4,c
        jr z,mof_i
        ld a,0x10
        add a,b
        ld e,(ix+MV_PER)
        call opll_w
mof_i:  ld a,(ix+MV_CTL)
        and 15
        ld e,a
        ld a,(ix+MV_AUX)
        and 0xF0
        or e
        ld e,a
        ld a,0x30
        add a,b
        call opll_w
        ld a,d
        bit 6,(ix+MV_CTL)
        jr z,mof_k
        or 0x10
mof_k:  ld e,a
        ld a,0x20
        add a,b
        jp opll_w

; IX = the drums' voice on the OPLL's rhythm section: the volumes when given, all the keys off,
; then the ones the record strikes.
mo_rhy: ld a,(ix+MV_NEW)
        or a
        ret z
        bit 5,a
        jr z,mor_k
        ld a,0x36
        ld e,(ix+MV_RV)
        call opll_w
        ld a,0x37
        ld e,(ix+MV_RV+1)
        call opll_w
        ld a,0x38
        ld e,(ix+MV_RV+2)
        call opll_w
mor_k:  ld a,0x0E
        ld e,0x20
        call opll_w
        ld a,(ix+MV_CTL)
        and 0x1F
        ret z
        or 0x20
        ld e,a
        ld a,0x0E
        jp opll_w

; IX = the drums' voice: on PSG voice C (mo_pv).
mo_psg: ld a,2

; IX = a voice in sndplay.asm's PSG format, A = its PSG voice (0-2): for a record given this
; tick, its tone period (with tone on), volume, noise period (with noise on) and the mixer's
; tone and noise bits (sndplay.asm sq_out's way: snd_mix, port A input, port B output).
mo_pv:  ld e,a
        ld a,(ix+MV_NEW)
        or a
        ret z
; E = the PSG voice: IX's record to it (mo_pv's output).
mo_pw:  ld c,(ix+MV_CTL)
        bit 4,c
        jr z,mop_v
        ld a,e
        add a,a
        ld d,a
        out (PSG_ADDR),a
        ld a,(ix+MV_PER)
        out (PSG_DATA),a
        ld a,d
        inc a
        out (PSG_ADDR),a
        ld a,(ix+MV_PER+1)
        out (PSG_DATA),a
mop_v:  ld a,e
        add a,8
        out (PSG_ADDR),a
        ld a,c
        and 15
        out (PSG_DATA),a
        bit 5,c
        jr z,mop_m
        ld a,6
        out (PSG_ADDR),a
        ld a,(ix+MV_AUX)
        out (PSG_DATA),a
mop_m:  ld a,1                      ; D = the voice's tone bit, B its noise bit
        ld b,e
        inc b
        jr mop_s
mop_l:  add a,a
mop_s:  djnz mop_l
        ld d,a
        add a,a
        add a,a
        add a,a
        ld b,a
        ld a,(snd_mix)
        or d
        or b
        and 0x3F
        or 0x80
        bit 4,c
        jr z,mop_t
        xor d                       ; (tone on)
mop_t:  bit 5,c
        jr z,mop_w
        xor b                       ; (noise on)
mop_w:  ld (snd_mix),a
        ld e,a
        ld a,7
        out (PSG_ADDR),a
        ld a,e
        out (PSG_DATA),a
        ret

; ----- the in-game sound effects with an SCC -----

; The effects (tools/msxsccfx.py sccfx.bin, in bank SCCFX_BANK: tools/mkrom.py checks that its
; streams fit the bank; its waveforms here, fx_waves: tools/mkrom.py music.inc): per effect its
; Amiga channel, a stream for its tonal part on SCC channel 0-3 (that channel: a new effect there
; replaces the one playing, as on the Amiga) and one for its noise part on a PSG voice (channels
; 0-2: A-C; 3: an idle voice, C first, else the one nearest its record's end), in the music's
; formats, one-shot. sndplay.asm hands them over (sq_sfx: sound.asm fx_go) and, while one plays
; (fx_act), ticks them with its own ticks (fx_tk); the title music, while it plays, owns the
; voices. Their records have readers of their own (fxr_sc, fxr_ps: no bank crossing, the fields
; straight to the chip): measured in openMSX on the coverage drive, the music's reader and
; output made a tick cost 2300 T-states on average, these 1560.

; A = an effect (1..SND_SFX_N), in the VBLANK interrupt: its parts from their first records.
; While the Amiga's channel 3 plays an effect, a lower one there than the last one started is
; not played ($1822C, as sndplay.asm does).
fx_start:
        ld c,a
        ld a,(mus_on)
        or a
        ret nz
        ld a,SCCFX_BANK
        ld (BANK_8000),a
        ld a,c
        dec a
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        or a
        sbc hl,de
        ld de,0x8004
        add hl,de                   ; its entry (7 (n - 1) on): the channel, the two streams
        ld b,(hl)
        inc hl
        ld a,b
        cp 3
        jr nz,fxs_ok
        push hl
        call fx_busy3
        pop hl
        jr z,fxs_ok
        ld a,(snd_last)
        ld d,a
        ld a,c
        cp d
        jr c,fxs_x
fxs_ok: ld a,c
        ld (snd_last),a
        push hl
        ld ix,mus_v                 ; the tonal part: SCC voice B
        ld de,MV_SIZE
        ld a,b
        or a
        jr z,fxs_v
fxs_l:  add ix,de
        dec a
        jr nz,fxs_l
fxs_v:  pop hl
        push bc
        call fx_ofs
        push hl
        jr z,fxs_m
        ld (ix+MV_PTR),e
        ld (ix+MV_PTR+1),d
        call fxr_sc                 ; its first record to the SCC
        jr fxs_n
fxs_m:  xor a                       ; (none: the channel silent)
        ld (ix+MV_LEFT),a
        ld c,a
        call fxr_so
fxs_n:  pop hl
        pop bc
        ld a,SCCFX_BANK             ; the noise part
        ld (BANK_8000),a
        call fx_ofs
        push af
        push de
        call fx_pown
        ld a,b
        cp 3
        call nc,fx_pfree            ; (channel 3: a voice free, else the nearest its end)
        ld ix,fx_pv
        ld de,MV_SIZE
        ld (fx_tmp),a
        or a
        jr z,fxs_p
fxs_q:  add ix,de
        dec a
        jr nz,fxs_q
fxs_p:  pop de
        pop af
        jr z,fxs_x
        ld a,(fx_tmp)
        ld (ix+MV_RV),a
        ld (ix+MV_RV+1),b
        ld (ix+MV_PTR),e
        ld (ix+MV_PTR+1),d
        ld b,a
        call fxr_ps                 ; its first record to its voice
fxs_x:  ld a,1
        ld (fx_act),a               ; (sndplay.asm ticks the engine from now on)
        ld hl,fx_son
        cp (hl)
        jr z,fxs_y
        ld (hl),a
        ld hl,SCC_ON                ; (channels 0-3 on, once after a stop)
        ld a,0x0F
        call scc_wr
fxs_y:  ld a,(act_8000)
        ld (BANK_8000),a
        ret

; No effect waveform known in the SCC's channels (fx_wc FFh). A = 0 after; keeps BC, DE.
fx_wnone:
        ld hl,fx_wc
        ld a,0xFF
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        inc hl
        ld (hl),a
        xor a
        ret

; IX = a voice: silent from now on (its outputs write volume 0).
fx_mute:
        xor a
        ld (ix+MV_LEFT),a
        ld (ix+MV_CTL),a
        inc a
        ld (ix+MV_NEW),a
        ret

; HL = a 24-bit offset in sccfx.bin's header (that bank at 8000h) -> HL past it; Z when it is 0,
; else NZ, A = the bank of that place, DE = its address in the 8000h window. Keeps BC.
fx_ofs: ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        inc hl
        push hl
        ld h,a
        or d
        or e
        jr z,fxo_x
        ld a,d
        rlca
        rlca
        rlca
        and 7
        ld l,a
        ld a,h
        add a,a
        add a,a
        add a,a
        or l
        add a,SCCFX_BANK
        ld l,a
        ld a,d
        and 0x1F
        or 0x80
        ld d,a
        ld a,l
        or a
fxo_x:  pop hl
        ret

; B = an Amiga channel: the PSG voices its last effect played still sounding, silent. Keeps B.
fx_pown:
        ld ix,fx_pv
        ld c,0
fxp_l:  ld a,(ix+MV_LEFT)
        or a
        jr z,fxp_n
        ld a,(ix+MV_RV+1)
        cp b
        jr nz,fxp_n
        call fx_mute
        push bc
        ld a,c
        call mo_pv
        pop bc
fxp_n:  ld de,MV_SIZE
        add ix,de
        inc c
        ld a,c
        cp 3
        jr nz,fxp_l
        ret

; A = a PSG voice for channel 3's noise: an idle one (C first), else the one nearest its record's
; end. Keeps B.
fx_pfree:
        ld ix,fx_pv + 2 * MV_SIZE
        ld hl,0xFF00
        ld c,2
fxf_l:  ld a,(ix+MV_LEFT)
        cp h
        jr nc,fxf_n
        ld h,a
        ld l,c
fxf_n:  ld de,0 - MV_SIZE
        add ix,de
        dec c
        jp p,fxf_l
        ld a,l
        ret

; NZ when the Amiga's channel 3 plays an effect (SCC voice 3, or a PSG voice it holds). Keeps
; BC.
fx_busy3:
        ld a,(mus_v + 3 * MV_SIZE + MV_LEFT)
        or a
        ret nz
        push bc
        ld ix,fx_pv
        ld b,3
fxb_l:  ld a,(ix+MV_LEFT)
        or a
        jr z,fxb_n
        ld a,(ix+MV_RV+1)
        cp 3
        jr z,fxb_y
fxb_n:  ld de,MV_SIZE
        add ix,de
        djnz fxb_l
        pop bc
        xor a
        ret
fxb_y:  pop bc
        or a                        ; (A = 3: NZ)
        ret

; From sndplay.asm's tick (fx_tk), unless the title music plays: each playing voice advances
; (MV_LEFT counted down in place); at the end of its record the next one (or silence at its
; stream's end) goes to its chip at once (fxr_sc, fxr_ps). fx_act 0 when none plays any more.
fx_tick:
        ld a,(mus_on)
        or a
        ret nz
        ld a,SCCFX_BANK             ; (the streams: one bank, tools/mkrom.py checks it)
        ld (BANK_8000),a
        ld hl,mus_v + 0 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_0
        dec (hl)
        jr nz,fxt_0
        ld ix,mus_v + 0 * MV_SIZE
        ld b,0
        call fxr_sc
fxt_0:
        ld hl,mus_v + 1 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_1
        dec (hl)
        jr nz,fxt_1
        ld ix,mus_v + 1 * MV_SIZE
        ld b,1
        call fxr_sc
fxt_1:
        ld hl,mus_v + 2 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_2
        dec (hl)
        jr nz,fxt_2
        ld ix,mus_v + 2 * MV_SIZE
        ld b,2
        call fxr_sc
fxt_2:
        ld hl,mus_v + 3 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_3
        dec (hl)
        jr nz,fxt_3
        ld ix,mus_v + 3 * MV_SIZE
        ld b,3
        call fxr_sc
fxt_3:
        ld hl,fx_pv + 0 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_4
        dec (hl)
        jr nz,fxt_4
        ld ix,fx_pv + 0 * MV_SIZE
        ld b,0
        call fxr_ps
fxt_4:
        ld hl,fx_pv + 1 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_5
        dec (hl)
        jr nz,fxt_5
        ld ix,fx_pv + 1 * MV_SIZE
        ld b,1
        call fxr_ps
fxt_5:
        ld hl,fx_pv + 2 * MV_SIZE + MV_LEFT
        ld a,(hl)
        or a
        jr z,fxt_6
        dec (hl)
        jr nz,fxt_6
        ld ix,fx_pv + 2 * MV_SIZE
        ld b,2
        call fxr_ps
fxt_6:
        ld a,(act_8000)
        ld (BANK_8000),a
        ld hl,mus_v + MV_LEFT       ; any voice still playing? (else fx_act 0: no more ticks;
        ld a,(hl)                   ; every voice's MV_LEFT in page C2h)
        ld l,(mus_v + 1 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld l,(mus_v + 2 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld l,(mus_v + 3 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld l,(fx_pv + 0 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld l,(fx_pv + 1 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld l,(fx_pv + 2 * MV_SIZE + MV_LEFT) & 0xFF
        or (hl)
        ld (fx_act),a
        ret

; IX = an effect's voice on SCC channel B whose record ended, its stream's bank at 8000h: the
; next record (at the stream's end silence: MV_LEFT 0) to the SCC at once. Keeps B, IX.
fxr_sc: ld l,(ix+MV_PTR)
        ld h,(ix+MV_PTR+1)
        ld a,(hl)                   ; the duration
        or a
        jr z,fxr_se
        ld (ix+MV_LEFT),a
        inc hl
        ld c,(hl)                   ; the ctl
        inc hl
        bit 4,c
        jr z,fxr_s1
        ld e,(hl)                   ; DE = the period
        inc hl
        ld d,(hl)
        inc hl
fxr_s1: bit 5,c
        jr z,fxr_s2
        ld a,(hl)                   ; the waveform
        inc hl
        ld (ix+MV_AUX),a
fxr_s2: ld (ix+MV_PTR),l
        ld (ix+MV_PTR+1),h
        jr fxr_so
fxr_se: ld (ix+MV_LEFT),a           ; (the stream's end: volume 0)
        ld c,a

; IX = an effect's voice on SCC channel B, C = its record's ctl, DE its period (when the ctl's
; bit 4 gives one), MV_AUX its waveform (bit 5; not loaded again when the channel has it,
; fx_wc): to the SCC. The cartridge's own: its registers mapped for the writes (SCCFX_BANK at
; 8000h again after); another slot's: mo_sc1's way. Keeps B, IX.
fxr_so: ld a,(scc_pg2)
        or a
        jr nz,fxr_sx
        ld a,SCC_REGS
        ld (BANK_8000),a
        bit 5,c
        jr z,fxr_s3
        call fxr_wc
        call nz,fxr_ld
fxr_s3: bit 4,c
        jr z,fxr_s4
        ld a,b
        add a,a
        add a,SCC_FREQ & 0xFF
        ld l,a
        ld h,SCC_FREQ / 256
        ld (hl),e
        inc hl
        ld (hl),d
fxr_s4: ld a,b
        add a,SCC_VOL & 0xFF
        ld l,a
        ld h,SCC_VOL / 256
        ld a,c
        and 15
        ld (hl),a
        ld a,SCCFX_BANK
        ld (BANK_8000),a
        ret
fxr_sx: ld (ix+MV_CTL),c            ; (another slot's SCC)
        bit 4,c
        jr z,fxr_x1
        ld (ix+MV_PER),e
        ld (ix+MV_PER+1),d
fxr_x1: ld a,c
        and 0x30
        or 1
        ld (ix+MV_NEW),a
        bit 5,c
        jp z,mo_sc1
        call fxr_wc
        jp nz,mo_sc1
        res 5,(ix+MV_NEW)           ; (that waveform is there already)
        jp mo_sc1

; IX = an effect's voice on SCC channel B, MV_AUX a waveform -> Z when the channel has it
; already, else NZ (fx_wc notes it). Keeps BC, DE.
fxr_wc: ld hl,fx_wc
        ld a,l
        add a,b
        ld l,a
        ld a,(ix+MV_AUX)
        cp (hl)
        ld (hl),a
        ret

; IX = an effect's voice on SCC channel B, the SCC's registers at 9800h: waveform MV_AUX
; (fx_waves, here at A000h) into the channel. Keeps BC, DE.
fxr_ld: push bc
        push de
        ld a,b
        rrca
        rrca
        rrca
        ld e,a
        ld d,SCC_WAVE / 256         ; DE = 9800h + 32 x channel
        ld l,(ix+MV_AUX)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,fx_waves
        add hl,bc
        ld bc,32
        ldir
        pop de
        pop bc
        ret

; IX = an effect's PSG voice B whose record ended, its stream's bank at 8000h: the next record
; (at the stream's end silence: MV_LEFT 0) to the PSG at once (mo_pv's output).
fxr_ps: ld l,(ix+MV_PTR)
        ld h,(ix+MV_PTR+1)
        ld a,(hl)                   ; the duration
        or a
        jr z,fxr_pe
        ld (ix+MV_LEFT),a
        inc hl
        ld a,(hl)                   ; the ctl
        inc hl
        ld (ix+MV_CTL),a
        bit 6,a
        jr z,fxr_p1
        ld c,(hl)                   ; the tone period
        inc hl
        ld (ix+MV_PER),c
        ld c,(hl)
        inc hl
        ld (ix+MV_PER+1),c
fxr_p1: bit 7,a
        jr z,fxr_p2
        ld c,(hl)                   ; the noise period
        inc hl
        ld (ix+MV_AUX),c
fxr_p2: ld (ix+MV_PTR),l
        ld (ix+MV_PTR+1),h
        ld e,b
        jp mo_pw
fxr_pe: ld (ix+MV_LEFT),a           ; (the stream's end: volume 0)
        ld (ix+MV_CTL),a
        ld e,b
        jp mo_pw

; ----- RoboCop's speech -----

; The speech alone (front_title with the PSG alone: on start, the music stopped; fire held from
; the start is released first; its PCM ends at level 0).
vm_alone:
        di
        xor a
        ld (vp_rel),a
        ld a,VOICE_BANK
        ld de,VOICE_LEN
        call vm_play
        ld b,8
vma_z:  ld a,b
        out (PSG_ADDR),a
        xor a
        out (PSG_DATA),a
        inc b
        ld a,b
        cp 11
        jr nz,vma_z
        ei
        ret

; The speech in the title music (front_fire at mus_speak: tick VOICE_TICK just played): the chips
; muted, voice_mix.bin (the Amiga's four channels for the speech's VOICE_TICKS ticks, from and to
; the level A and B hold), then the voices as tools/mkrom.py computed them for the tick after
; (mus_snap_...: every field given) and the chips with them. Fire pressed once released meanwhile
; ends the speech (vm_hit: the title ends too).
vm_music:
        di
        call mus_mute
        ld a,VOICE_MIX_BANK
        ld de,VOICE_MIX_LEN
        call vm_play
        ld a,(vm_hit)
        or a
        jr nz,vmm_x
        ld a,(mus_mode)
        ld hl,mus_snap_scc
        rra
        jr c,vmm_m
        ld hl,mus_snap_fm
vmm_m:  ld de,mus_v
        ld bc,3 * MV_SIZE
        ldir
        ld a,(mus_mode)
        ld hl,mus_snap_psg
        and MM_RHY
        jr z,vmm_d
        ld hl,mus_snap_rhy
vmm_d:  ld bc,MV_SIZE
        ldir
        ld hl,VOICE_TICK + VOICE_TICKS
        ld (mus_tick),hl
        call ma_c
        in a,(VDP_CTRL)             ; (S#0: the VBLANK the speech held off is dropped, else it would
        xor a                       ; run the next tick at once; at 60 Hz the next VBLANK ticks:
        ld (mus_div),a              ; the speech ends just after one, the tick after is due 17 ms on)
vmm_x:  ei
        ret

; The chips quiet for the speech (the interrupts off): the SCC's volumes 0; the OPLL's melodic
; volumes 15, the keys as they are (the notes go on under the speech, as on the Amiga); its
; rhythm's keys off at volume 15. (The drums' PSG voice C plays the speech.)
mus_mute:
        ld a,(mus_mode)
        rra
        jr nc,mum_f
        ld hl,SCC_VOL
        ld b,3
mum_s:  push bc
        xor a
        call scc_wr
        pop bc
        inc hl
        djnz mum_s
mum_f:  ld a,(mus_mode)
        and MM_FM
        jr z,mum_r
        ld ix,mus_v
        ld b,0
mum_c:  ld a,(ix+MV_AUX)
        or 0x0F
        ld e,a
        ld a,0x30
        add a,b
        call opll_w
        ld de,MV_SIZE
        add ix,de
        inc b
        ld a,b
        cp 3
        jr nz,mum_c
mum_r:  ld a,(mus_mode)
        and MM_RHY
        ret z
        ld a,0x0E
        ld e,0x20
        call opll_w
        ld e,0xFF
        ld a,0x36
        call opll_w
        ld a,0x37
        call opll_w
        ld a,0x38
        jp opll_w

; A = the bank of VOICE_BANK's or VOICE_MIX_BANK's PCM, DE = its samples: the speech as PCM on
; the PSG (tools/msxvoice.py: index bytes through the 8000h window, one every VOICE_RATE_T
; T-states): each sets the three voices' volumes (voice_tab), tone and noise off (a voice then
; outputs its volume's level), so their summed levels follow the sample. C's volume is written
; first, then B's, then A's: until the third write the PSG mixes old and new volumes, and the
; table's B and A only grow with the level, C giving the fine steps (msxvoice.py smooth_table:
; the nearest combinations of the first table jumped, and those mixes were a hiss). The
; interrupts off (a VBLANK would delay samples); every 256 samples fire is read (SPACE or
; trigger A): pressed once released (vp_rel), it ends the speech, vm_hit = 1. Then the mixer as
; it was (the volumes as the last sample left them), the 8000h window act_8000's again.
vm_play:
        ld (vm_bank),a
        ld (BANK_8000),a
        xor a
        ld (mus_speak),a
        ld (vm_hit),a
        ld a,7
        out (PSG_ADDR),a
        ld a,PSG_MIX
        out (PSG_DATA),a
        ld hl,0x8000
vm_lp:  ld a,(hl)                   ; 8 (T-states, with the M1 wait)
        inc hl                      ; 7
        ld c,a                      ; 5
        ld b,voice_tab / 256        ; 8
        ld a,10                     ; 8
        out (PSG_ADDR),a            ; 12
        ld a,(bc)                   ; 8
        out (PSG_DATA),a            ; 12  voice C's volume
        inc b                       ; 5
        ld a,9                      ; 8
        out (PSG_ADDR),a            ; 12
        ld a,(bc)                   ; 8
        out (PSG_DATA),a            ; 12  B's
        inc b                       ; 5
        ld a,8                      ; 8
        out (PSG_ADDR),a            ; 12
        ld a,(bc)                   ; 8
        out (PSG_DATA),a            ; 12  A's
        ld a,h                      ; 5
        cp 0xA0                     ; 8
        jr z,vm_bnk                 ; 8
vm_b:   ld a,l                      ; 5
        or a                        ; 5
        jr z,vm_fire                ; 8
vm_c:   dec de                      ; 7
        ld a,d                      ; 5
        or e                        ; 5
        jr z,vm_end                 ; 8
        ld b,(VOICE_RATE_T - 238) / 14  ; 8 (the loop's own 238 T-states, M1 waits counted; an equ
                                    ; of voice.inc's, included later, would be 0)
vm_w:   djnz vm_w                   ; 14 a turn, 9 the last
        jr vm_lp                    ; 13
vm_bnk: ld h,0x80                   ; (the window's end: the next bank)
        ld a,(vm_bank)
        inc a
        ld (vm_bank),a
        ld (BANK_8000),a
        jr vm_b
vm_fire:
        ld a,15
        out (PSG_ADDR),a
        in a,(PSG_IN)
        and 0xBF                    ; (joystick port 1)
        out (PSG_DATA),a
        ld a,14
        out (PSG_ADDR),a
        in a,(PSG_IN)
        and 0x10
        jr z,vmf_dn                 ; (trigger A down)
        in a,(0xAA)
        and 0xF0
        or 8
        out (0xAA),a
        in a,(0xA9)
        and 1
        jr z,vmf_dn                 ; (SPACE down)
        ld a,1
        ld (vp_rel),a
        jr vm_c
vmf_dn: ld a,(vp_rel)
        or a
        jr z,vm_c
        ld (vm_hit),a
vm_end: ld a,7
        out (PSG_ADDR),a
        ld a,(snd_mix)
        out (PSG_DATA),a
        ld a,(act_8000)
        ld (BANK_8000),a
        ret
