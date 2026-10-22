; Test build (tools/mkrom.py DIAG=1; BANK_MUSIC at A000h): what this machine showed the sound
; detection, on screen, then SCC test tones; no game. The detection (music.asm mus_init) ran just
; before, at its place in rc2.asm init, its reads logged in dg_log (sound.asm scc_pat, scc_scan).
; Written for the user's SX-2 with an MSX Pico+, whose SCC the port did not find (2026-10-22).
;
; The screen (32 x 24 characters, front.asm dg_show), every number in hex:
;   0  V the BIOS's MSX version, VDP (0 V9938, 2 V9958), FM (snd_fm), MODE (mus_mode), P2
;      (scc_pg2: another slot's SCC)
;   1  A8 at the start and now, R9 (RG9SAV), CPU: loops of 37 T-states between two VBLANKs
;   2  EXP: EXPTBL, SLT: SLTTBL (the BIOS's slot tables)
;   3  CART: page 1's primary slot now, SUB: its secondary register (FF: not expanded)
;   4-5  for banks 02, 03, 3F, 40, 64, 7F written at 9000h: what 8000h-8001h show
;   6  98: 9800h-9803h with 3Fh at 9000h; SW: 8000h before and after 02h stored at 9800h (a
;      MegaRAM or a Konami mapper switches its 8000h bank there, a Konami SCC mapper does not)
;   7  LOG and how many bytes; 8-14 dg_log: FEh, C, the values scc_pat read (5Ah, BFh, 24h,
;      89h written, in turn); FDh, a slot scc_scan saw, E (expanded) or R (RAM)
;   16-21  64 values stored at 9800h and loaded back, by instruction form (F1-F6): how many came
;      back right and the first wrong ones
;   22  the tone playing, in turn for 3 s each: A (A4) through the engine's stores (sound.asm
;      scc_pvs) with 3Fh at 9000h meanwhile; B (E5) through (hl) stores; C (C5) as A, then bank
;      02h at 8000h meanwhile; D (G4) as A, the 8000h window switched between 02h and 3Fh every
;      frame (the game's way), the volume stored again each time; then none for 2 s

dg_main:
        di
        ld hl,dg_txt
        ld de,dg_txt + 1
        ld bc,32 * 24 - 1
        ld (hl),' '
        ldir
        ld bc,0x0000                ; row 0
        call dg_at
        ld hl,dgs_v
        call dg_str
        ld a,(dg_msxv)
        call dg_hex
        ld hl,dgs_vdp
        call dg_str
        ld a,(vdp_id)
        call dg_hex
        ld hl,dgs_fm
        call dg_str
        ld a,(snd_fm)
        call dg_hex
        ld hl,dgs_mode
        call dg_str
        ld a,(mus_mode)
        call dg_hex
        ld hl,dgs_p2
        call dg_str
        ld a,(scc_pg2)
        call dg_hex
        ld bc,0x0100                ; row 1
        call dg_at
        ld hl,dgs_a8
        call dg_str
        ld a,(dg_a8b)
        call dg_hex
        ld a,' '
        call dg_ch
        in a,(PPI_SLOT)
        call dg_hex
        ld hl,dgs_r9
        call dg_str
        ld a,(RG9SAV)
        call dg_hex
        ld hl,dgs_cpu
        call dg_str
        call dg_speed
        ld a,h
        call dg_hex
        ld a,l
        call dg_hex
        ld bc,0x0200                ; row 2
        call dg_at
        ld hl,dgs_exp
        call dg_str
        ld hl,EXPTBL
        ld b,4
        call dg_bytes
        ld hl,dgs_slt
        call dg_str
        ld hl,SLTTBL
        ld b,4
        call dg_bytes
        ld bc,0x0300                ; row 3
        call dg_at
        ld hl,dgs_cart
        call dg_str
        in a,(PPI_SLOT)
        rrca
        rrca
        and 3
        call dg_hex
        ld hl,dgs_sub
        call dg_str
        call dg_subreg
        call dg_hex
        ld bc,0x0400                ; rows 4-5
        call dg_at
        ld hl,dg_bnks
        ld b,3
        call dg_bks
        push hl
        ld bc,0x0500
        call dg_at
        pop hl
        ld b,3
        call dg_bks
        ld bc,0x0600                ; row 6
        call dg_at
        ld hl,dgs_98
        call dg_str
        ld a,SCC_REGS
        ld (BANK_8000),a
        ld hl,0x9800
        ld b,4
        call dg_bytes
        ld hl,dgs_sw
        call dg_str
        ld a,(0x8000)
        ld d,a
        ld a,2
        ld (0x9800),a
        ld a,(0x8000)
        ld e,a
        ld a,SCC_REGS
        ld (BANK_8000),a
        ld a,d
        call dg_hex
        ld a,' '
        call dg_ch
        ld a,e
        call dg_hex
        ld a,(act_8000)
        ld (BANK_8000),a
        ld bc,0x0700                ; row 7, rows 8-14
        call dg_at
        ld hl,dgs_log
        call dg_str
        ld hl,(dg_ptr)
        ld de,dg_log
        or a
        sbc hl,de
        ld a,l
        call dg_hex
        ld a,h
        or a
        ld a,l
        jr nz,dgl_70
        cp 70
        jr c,dgl_n
dgl_70: ld a,70
dgl_n:  ld (dg_n),a
        ld hl,dg_log
        ld b,8
dgl_r:  ld a,(dg_n)
        or a
        jr z,dgl_x
        push hl
        ld c,0
        call dg_at
        pop hl
        ld c,10
dgl_b:  ld a,(dg_n)
        or a
        jr z,dgl_x
        dec a
        ld (dg_n),a
        ld a,(hl)
        inc hl
        call dg_hex
        ld a,' '
        call dg_ch
        dec c
        jr nz,dgl_b
        inc b
        jr dgl_r
dgl_x:  ld bc,0x0F00                ; row 15, rows 16-21
        call dg_at
        ld hl,dgs_forms
        call dg_str
        ld bc,0x1000
        call dg_at
        ld hl,dgs_f1
        call dg_str
        ld iy,dgf1
        call dg_form
        ld bc,0x1100
        call dg_at
        ld hl,dgs_f2
        call dg_str
        ld iy,dgf2
        call dg_form
        ld bc,0x1200
        call dg_at
        ld hl,dgs_f3
        call dg_str
        ld iy,dgf3
        call dg_form
        ld bc,0x1300
        call dg_at
        ld hl,dgs_f4
        call dg_str
        ld iy,dgf4
        call dg_form
        ld bc,0x1400
        call dg_at
        ld hl,dgs_f5
        call dg_str
        ld iy,dgf5
        call dg_form
        ld bc,0x1500
        call dg_at
        ld hl,dgs_f6
        call dg_str
        ld iy,dgf6
        call dg_form
        ld hl,dg_show
        call front_call             ; (the screen: BANK_FRONT at 8000h from now on)
; The tones, in turn (row 22 says which).
dg_tones:
        ld hl,dgs_ta
        call dg_tline
        ld de,0x00FD                ; (A4)
        call dg_tone
        ld b,150
        call dg_wait
        call dg_quiet
        ld hl,dgs_tb
        call dg_tline
        call dg_tone_b
        ld b,150
        call dg_wait
        call dg_quiet
        ld hl,dgs_tc
        call dg_tline
        ld de,0x00D5                ; (C5)
        call dg_tone
        ld a,2
        ld (BANK_8000),a            ; (another bank at 8000h meanwhile)
        ld b,150
        call dg_wait
        call dg_quiet
        ld hl,dgs_td
        call dg_tline
        ld de,0x011C                ; (G4)
        call dg_tone
        ld b,150
dgt_d:  push bc
        ld a,2
        ld (BANK_8000),a
        ld b,1
        call dg_wait
        ld a,SCC_REGS
        ld (BANK_8000),a
        ld a,15
        ld (SCC_VOL),a
        ld a,0x0F
        ld (SCC_ON),a
        pop bc
        djnz dgt_d
        call dg_quiet
        ld hl,dgs_tn
        call dg_tline
        ld b,100
        call dg_wait
        jr dg_tones

; HL = a text: row 22 with it, drawn.
dg_tline:
        push hl
        ld bc,0x1600
        call dg_at
        pop hl
        call dg_str
        ld b,0x16
        ld hl,dg_row
        jp front_call

; DE = a period: channel 1's waveform with ldir, the period and volume 15 through sound.asm
; scc_pvs (the engine's stores to fixed addresses, the channels on); 3Fh at 9000h after.
dg_tone:
        ld a,SCC_REGS
        ld (BANK_8000),a
        push de
        ld hl,dg_sq
        ld de,SCC_WAVE
        ld bc,32
        ldir
        pop de
        ld b,0
        ld c,0x10
        ld a,15
        jp scc_pvs

; Tone B: the same through (hl) stores, higher (E5).
dg_tone_b:
        ld a,SCC_REGS
        ld (BANK_8000),a
        ld hl,dg_sq
        ld de,SCC_WAVE
        ld bc,32
        ldir
        ld hl,SCC_FREQ
        ld a,0xA9
        ld (hl),a
        inc hl
        xor a
        ld (hl),a
        ld hl,SCC_VOL
        ld a,15
        ld (hl),a
        ld hl,SCC_ON
        ld a,0x0F
        ld (hl),a
        ret

; No tone: channel 1 at volume 0, every channel off (fixed stores).
dg_quiet:
        ld a,SCC_REGS
        ld (BANK_8000),a
        xor a
        ld (SCC_VOL),a
        ld (SCC_ON),a
        ret

; B = VBLANKs to wait (S#0's flag; the interrupts off).
dg_wait:
        in a,(VDP_CTRL)
        rlca
        jr nc,dg_wait
        djnz dg_wait
        ret

; -> HL = loops of 37 T-states (with the M1 wait) between two VBLANKs: the CPU's speed.
dg_speed:
        in a,(VDP_CTRL)
dsp_w:  in a,(VDP_CTRL)
        rlca
        jr nc,dsp_w
        ld hl,0
dsp_c:  inc hl
        in a,(VDP_CTRL)
        rlca
        jr nc,dsp_c
        ret

; -> A = the secondary slot register of page 1's primary slot (FFh: that slot not expanded).
; Page 3 shows that slot for a moment: no stack meanwhile (the interrupts off).
dg_subreg:
        in a,(PPI_SLOT)
        rrca
        rrca
        and 3
        ld e,a
        ld d,0
        ld hl,EXPTBL
        add hl,de
        bit 7,(hl)
        ld a,0xFF
        ret z
        ld a,e
        rrca
        rrca
        ld e,a
        in a,(PPI_SLOT)
        ld d,a
        and 0x3F
        or e
        out (PPI_SLOT),a
        ld a,(0xFFFF)
        cpl
        ld e,a
        ld a,d
        out (PPI_SLOT),a
        ld a,e
        ret

; HL = bank numbers, B = how many: "Bnn XXXX " each, what 8000h-8001h show with it at 9000h.
; HL past them.
dg_bks: ld a,'B'
        call dg_ch
        ld a,(hl)
        call dg_hex
        ld a,' '
        call dg_ch
        ld a,(hl)
        ld (BANK_8000),a
        ld a,(0x8000)
        call dg_hex
        ld a,(0x8001)
        call dg_hex
        ld a,' '
        call dg_ch
        inc hl
        djnz dg_bks
        ld a,(act_8000)
        ld (BANK_8000),a
        ret

; IY = a form's routine (A = a value to store at 9800h -> A = what 9800h gives back): 64 values
; through it with 3Fh at 9000h; " OK nn BAD nn" and the first four wrong values at the cursor.
dg_form:
        ld a,SCC_REGS
        ld (BANK_8000),a
        ld de,0                     ; D = right, E = wrong
        ld c,64
        ld a,11
        ld (dg_v),a
dgf_lp: ld a,(dg_v)
        or a
        jr nz,dgf_v
        inc a                       ; (00h is what a missed load gives: never stored)
        ld (dg_v),a
dgf_v:  push bc
        push de
        call dg_jiy
        pop de
        pop bc
        ld hl,dg_v
        cp (hl)
        jr nz,dgf_bd
        inc d
        jr dgf_nx
dgf_bd: ld b,a
        ld a,e
        cp 4
        jr nc,dgf_b4
        ld hl,dg_bad
        add a,l
        ld l,a
        ld (hl),b
dgf_b4: inc e
dgf_nx: ld a,(dg_v)
        add a,37
        ld (dg_v),a
        dec c
        jr nz,dgf_lp
        ld a,(act_8000)
        ld (BANK_8000),a
        ld hl,dgs_ok
        call dg_str
        ld a,d
        call dg_hex
        ld hl,dgs_bad
        call dg_str
        ld a,e
        call dg_hex
        ld a,e
        or a
        ret z
        cp 4
        jr c,dgf_pe
        ld a,4
dgf_pe: ld b,a
        ld hl,dg_bad
dgf_pb: ld a,' '
        call dg_ch
        ld a,(hl)
        call dg_hex
        inc hl
        djnz dgf_pb
        ret
dg_jiy: jp (iy)

dgf1:   ld (0x9800),a               ; F1: (nn) store, a pause, (nn) load
        ld b,12
dg1w:   djnz dg1w
        ld a,(0x9800)
        ret
dgf2:   ld (0x9800),a               ; F2: (nn) store, (nn) load at once
        ld a,(0x9800)
        ret
dgf3:   ld hl,0x9800                ; F3: (hl) store, (hl) load at once
        ld (hl),a
        ld a,(hl)
        ret
dgf4:   ld hl,0x9800                ; F4: (hl) store, a pause, (nn) load
        ld (hl),a
        ld b,12
dg4w:   djnz dg4w
        ld a,(0x9800)
        ret
dgf5:   ld (0x9800),a               ; F5: (nn) store, a pause, (hl) load
        ld b,12
dg5w:   djnz dg5w
        ld hl,0x9800
        ld a,(hl)
        ret
dgf6:   ld (dg_src),a               ; F6: an ldi store, a pause, (nn) load
        ld hl,dg_src
        ld de,0x9800
        ldi
        ld b,12
dg6w:   djnz dg6w
        ld a,(0x9800)
        ret

; B = row, C = column: the text cursor there. Uses HL.
dg_at:  push de
        ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld e,c
        ld d,0
        add hl,de
        ld de,dg_txt
        add hl,de
        ld (dg_cur),hl
        pop de
        ret

; A = a character at the cursor, the cursor on. Keeps BC, DE, HL.
dg_ch:  push hl
        ld hl,(dg_cur)
        ld (hl),a
        inc hl
        ld (dg_cur),hl
        pop hl
        ret

; HL = a text (0 at its end) at the cursor. Keeps BC, DE.
dg_str: ld a,(hl)
        or a
        ret z
        call dg_ch
        inc hl
        jr dg_str

; A = a byte: two hex digits at the cursor. Keeps BC, DE, HL.
dg_hex: push af
        rrca
        rrca
        rrca
        rrca
        call dgh_n
        pop af
dgh_n:  and 15
        add a,'0'
        cp '9' + 1
        jr c,dgh_o
        add a,7
dgh_o:  jp dg_ch

; HL = bytes, B = how many: each "XX " at the cursor; HL past them. Keeps C, DE.
dg_bytes:
        ld a,(hl)
        call dg_hex
        ld a,' '
        call dg_ch
        inc hl
        djnz dg_bytes
        ret

dg_bnks:    db 0x02, 0x03, 0x3F, 0x40, 0x64, 0x7F
dg_sq:      db 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70
            db 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90
dgs_v:      db "V", 0
dgs_vdp:    db " VDP", 0
dgs_fm:     db " FM", 0
dgs_mode:   db " MODE", 0
dgs_p2:     db " P2 ", 0
dgs_a8:     db "A8 ", 0
dgs_r9:     db " R9 ", 0
dgs_cpu:    db " CPU ", 0
dgs_exp:    db "EXP ", 0
dgs_slt:    db "SLT ", 0
dgs_cart:   db "CART ", 0
dgs_sub:    db " SUB ", 0
dgs_98:     db "98 ", 0
dgs_sw:     db "SW ", 0
dgs_log:    db "LOG ", 0
dgs_forms:  db "FORMS. STORE LOAD", 0
dgs_f1:     db "F1 NN NN.", 0
dgs_f2:     db "F2 NN NN ", 0
dgs_f3:     db "F3 HL HL ", 0
dgs_f4:     db "F4 HL NN.", 0
dgs_f5:     db "F5 NN HL.", 0
dgs_f6:     db "F6 LDI NN", 0
dgs_ok:     db " OK ", 0
dgs_bad:    db " BAD ", 0
dgs_ta:     db "TONE A. ENGINE               ", 0
dgs_tb:     db "TONE B. HL STORES            ", 0
dgs_tc:     db "TONE C. ENGINE, BANK 02 AFTER", 0
dgs_td:     db "TONE D. BANKS SWITCHED       ", 0
dgs_tn:     db "NO TONE                      ", 0
