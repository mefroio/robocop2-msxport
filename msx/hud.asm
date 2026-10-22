; HUD at run time: the Amiga panel routines (docs/AMIGA_ANALYSIS.md) redone on the MSX HUD
; (page 3 lines 208-252) with the data of tools/msxhudrt.py: byte patches already in HUD
; colours, in two banks mapped at 8000h-BFFFh while the HUD works.
;
;   message_queue $FD76, message_ticker $FDA2 -> hud_message, hud_ticker (one character per frame)
;   panel_update_digits $F6B8                -> hud_digits (the cells whose digit changed)
;   update_energy_can $89BE                  -> hud_energy (one step every other frame: the
;                                               game called it at its 30 Hz)
;   panel_draw_head $88DE, panel_draw_icon   -> hud_request: jobs written HUD_JOB_LINES lines
;   $896A, the full can of $89BE                per frame
;
; hud_frame runs right after the VBLANK, so everything is written long before the beam
; reaches the HUD (display line 167). The values follow the game's layouts (BCD timer, ammo
; and score; energy 0..100h).

HUD_DIGITS:    equ 1                ; digit cells redrawn per frame at most
; what each piece of work costs, in sprite upload units (msx/sprites.asm UP_TOTAL: the upload
; gets what the HUD, the game logic and the sprite engine leave of the frame)
COST_CHAR:     equ 47
COST_DIGIT:    equ 54
COST_STEP:     equ 38
COST_JOB:      equ 34
HUD_JOB_LINES: equ 8                ; lines of a job written per frame
MSG_WAIT:      equ 0x50             ; frames a message stays before it is erased (Amiga: VBLs)
TEXT_CELLS:    equ 21
TEXT_LINES:    equ 8
SPACE:         equ 41               ; font glyph of ' '
JOB_HEAD0:     equ 0                ; request types (the value is the graphic or icon)
JOB_HEAD1:     equ 1
JOB_ICON:      equ 2
JOB_CAN:       equ 3

; Maps the HUD data at 8000h-BFFFh.
hud_map:
        ld a,HUD_BANK
        call bank_8000
        ld a,HUD_BANK + 1
        jp bank_a000

; (The HUD's state at a new game: cold.asm hud_init.)

; Once per frame, right after the VBLANK: the ticker, then one other piece of work: a job
; slice, else an energy step, else a digit cell.
hud_frame:
        xor a
        ld (hud_cost),a
        if DEMO_HUD = 0
        ld hl,(AG + 0x804A)         ; the game's values in their layouts (each word's bytes
        ld a,h                      ; swapped in the mirror): timer,
        ld h,l
        ld l,a
        ld (hud_timer),hl
        ld hl,(AG + 0x8030)         ;   ammo,
        ld a,h
        ld h,l
        ld l,a
        ld (hud_ammo),hl
        ld hl,(AG + 0x8046)         ;   score
        ld a,h
        ld h,l
        ld l,a
        ld (hud_score),hl
        ld hl,(AG + 0x8048)
        ld a,h
        ld h,l
        ld l,a
        ld (hud_score + 2),hl
        ld hl,(AM + 0x169C)
        ld (en_target),hl           ; the can follows the game's shown level ($89BE: en_update)
        endif
        call hud_map
        call hud_ticker
        ld a,(job_lines)
        ld hl,jobq_n
        or (hl)
        jp nz,hud_jobs
        call hud_energy
        ret c
        jp hud_digits

; HL = HUD VRAM address (low 16 bits; page 3, bit 16 set), DE = source, B = lines, C = bytes
; per line: copies the block (VRAM lines 128 bytes apart). Returns DE = next source line and
; HL = next VRAM line.
hud_put:
        push bc
        push hl
        push de
        ld e,1
        call vram_write
        pop hl
        ld b,c
        ld c,VDP_DATA
        otir
        call vram_done
        ex de,hl
        pop hl
        ld bc,128
        add hl,bc
        pop bc
        djnz hud_put
        ret

; ----- message ticker -----

; HL = message ($FF-terminated, the game's character codes): queued as message_queue $FD76
; does it (dropped when the slot under the write index is still busy).
hud_message:
        ex de,hl
        ld a,(msg_wr)
        and 6
        ld c,a
        ld b,0
        ld hl,msg_queue
        add hl,bc
        ld a,(hl)
        inc hl
        or (hl)
        ret nz
        ld (hl),d
        dec hl
        ld (hl),e
        ld a,(msg_wr)
        add a,2
        ld (msg_wr),a
        ret

; The game's message_queue ($FD76) for the ported logic: A = message (HUD_MSG_<Amiga address>,
; tools/msxhudrt.py). The HUD's own banks are mapped for a moment (the logic's are put back).
game_msg:
        ld l,a
        ld h,0
        add hl,hl
        ld de,HUD_MSGS              ; (in HUD_BANK + 1 at A000h)
        add hl,de
        ld a,(act_a000)
        ld b,a
        ld a,HUD_BANK + 1
        call bank_a000
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,b
        call bank_a000
        ex de,hl
        jp hud_message

; The game's panel_draw_head ($88DE) for the ported logic: A = head graphic (D0), C = slot (D1).
head_draw:
        ld b,a
        ld a,c
        add a,JOB_HEAD0
        ld c,b
        jp hud_request

; One step per frame (message_ticker $FDA2): the next character of the message in the read
; slot; after its last one the message stays MSG_WAIT frames, then the 21 columns are erased
; from the right, one per frame, and the slot is freed (an idle slot passes in one frame).
hud_ticker:
        call msg_slot
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        or a
        jr z,ht_idle                ; free (0) or printed (0080h)
        ld a,(de)
        inc de
        bit 7,a
        jr nz,ht_end
        ld (hl),d
        dec hl
        ld (hl),e
        ld c,a
        ld a,(msg_col)
        inc a
        ld (msg_col),a
        dec a
        jp text_put
ht_end: ld (hl),0
        dec hl
        ld (hl),0x80
        ld a,MSG_WAIT
        ld (msg_count),a
ht_idle:
        xor a
        ld (msg_col),a
        ld hl,msg_count
        dec (hl)
        jp m,ht_next
        ld a,(hl)
        cp TEXT_CELLS
        ret nc
        ld c,0x20                   ; erases column msg_count
        jp text_put
ht_next:
        inc (hl)
        call msg_slot
        xor a
        ld (hl),a
        inc hl
        ld (hl),a
        ld a,(msg_rd)
        add a,2
        ld (msg_rd),a
        ret

; HL -> the queue slot under the read index.
msg_slot:
        ld a,(msg_rd)
        and 6
        ld e,a
        ld d,0
        ld hl,msg_queue
        add hl,de
        ret

; A = column, C = character code: the cell takes the font glyph panel_draw_char ($10620)
; would use and is drawn again.
text_put:
        ld e,a
        ld a,c
        and 0x7F
        ld b,SPACE
        cp 0x20
        jr z,tp_g
        ld b,0x41
        cp 0x40
        jr nc,tp_s
        ld b,0x16
tp_s:   sub b
        ld b,a
tp_g:   ld d,0
        ld hl,hud_chars
        add hl,de
        ld (hl),b
        ld a,e
        ; fall through

; A = text column c: rewrites the HUD bytes of cell c (7 px at HUD_TEXT_X + 7c) and the first
; pixel of cell c+1. Cells are 7 px apart and drawn with colour 0 transparent
; (tools/hudmodel.py text_line): pixel 0 of a cell shows the previous cell's column 7 (its
; shadow) where its own is 0. The font holds every glyph line packed for both phases
; (msxhudrt.py): an even cell starts on a byte (4 bytes: pixels 0-6 and the next cell's
; pixel 0, or the frame after the last cell), an odd one in the middle of a byte (5 bytes:
; the previous cell's pixel 6, pixels 0-6, the next cell's pixels 0 and 1).
TXT_LINE:  equ 9                    ; font bytes per glyph line (even phase 4, odd phase 5)
text_draw:
        ld (td_col),a
        ld hl,hud_cost
        ld (hl),COST_CHAR
        ld c,a
        ld e,a
        ld d,0
        ld hl,hud_chars
        add hl,de
        ld a,(hl)
        call glyph_ptr
        ld a,c
        rrca
        jr nc,td_ce
        inc hl
        inc hl
        inc hl
        inc hl                      ; odd cell: its glyph's odd phase
td_ce:  ld (td_gc),hl
        ld a,SPACE
        inc c
        dec c
        jr z,td_p                   ; cell 0: no previous cell
        ld hl,hud_chars - 1
        add hl,de
        ld a,(hl)
td_p:   call glyph_ptr
        ld (td_gp),hl
        ld a,c
        cp TEXT_CELLS - 1
        ld a,SPACE
        jr nc,td_n                  ; last cell: no next cell
        ld hl,hud_chars + 1
        add hl,de
        ld a,(hl)
td_n:   call glyph_ptr
        ld (td_gn),hl
        ld a,c
        add a,a
        add a,a
        add a,a
        sub c                       ; 7c
        add a,HUD_TEXT_X
        srl a                       ; first byte (odd cells: the one with the previous pixel 6)
        ld l,a
        ld h,0
        ld de,HUD_TEXT
        add hl,de
        ld (td_vram),hl
        ld hl,HUD_FRAME
        ld (td_frame),hl
        ld ix,(td_gp)
        ld iy,(td_gn)
        ld hl,(td_gc)
        ld b,TEXT_LINES
td_lp:  push bc
        push hl
        ld de,td_px
        ld a,(td_col)
        rrca
        jr c,td_odd
        ld a,(hl)                   ; even: p0p1, with the previous shadow where p0 = 0
        cp 0x10
        jr nc,te_0
        ld c,a
        ld a,(ix+3)
        add a,a
        add a,a
        add a,a
        add a,a
        or c
te_0:   ld (de),a
        inc de
        inc hl
        ldi
        ldi                         ; p2p3 p4p5
        ld a,(td_col)
        cp TEXT_CELLS - 1
        jr z,te_last
        ld a,(iy+0)
        and 0xF0
        jr z,te_own                 ; next p0 = 0: this cell's shadow p7 stays
        rrca
        rrca
        rrca
        rrca
        ld c,a
        ld a,(hl)
        and 0xF0
        or c
        jr te_3
te_last:
        push hl
        ld hl,(td_frame)
        ld c,(hl)
        pop hl
        ld a,(hl)
        and 0xF0
        or c                        ; the frame after the last cell
        jr te_3
te_own: ld a,(hl)
te_3:   ld (de),a
        ld b,4
        jr td_out
td_odd: ld a,(hl)                   ; odd: 0p0, p0 = 0 shows the previous shadow
        or a
        jr nz,to_0
        ld a,(ix+3)
        and 15
to_0:   ld c,a
        ld a,(ix+3)
        and 0xF0                    ; the previous cell's p6
        or c
        ld (de),a
        inc de
        inc hl
        ldi
        ldi
        ldi                         ; p1p2 p3p4 p5p6
        ld a,(iy+0)
        and 0xF0                    ; next p0 ...
        jr nz,to_4
        ld a,(hl)                   ; ... or this cell's shadow p7
to_4:   ld c,a
        ld a,(iy+0)
        and 15                      ; next p1
        or c
        ld (de),a
        ld b,5
td_out: ld hl,(td_vram)
        push bc
        ld e,1
        call vram_write
        pop bc
        ld hl,td_px
        ld c,VDP_DATA
        otir
        call vram_done
        ld hl,(td_vram)
        ld de,128
        add hl,de
        ld (td_vram),hl
        ld hl,td_frame
        inc (hl)
        ld de,TXT_LINE
        add ix,de
        add iy,de
        pop hl
        add hl,de
        pop bc
        dec b
        jp nz,td_lp
        ret

; A = font glyph -> HL = its first line (TXT_LINE bytes per line). Keeps BC, DE.
glyph_ptr:
        push de
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl                   ; *8
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl                   ; *64
        add hl,de                   ; *72
        ld de,HUD_FONT
        add hl,de
        pop de
        ret

; ----- digits -----

; Redraws up to HUD_DIGITS cells whose digit is not the one the values ask for (the Amiga
; redrew a fixed half of them every game frame; the result on screen is the same).
hud_digits:
        ld hl,hud_timer
        ld de,hud_last
        ld b,8
hd_q:   ld a,(de)
        cp (hl)
        jr nz,hd_scan
        inc hl
        inc de
        djnz hd_q
        ret                         ; the values have not changed since every cell was right
hd_scan:
        ld a,HUD_DIGITS
        ld (hd_left),a
        ld c,0
hd_lp:  call cell_digit
        ld e,c
        ld d,0
        ld hl,hud_shown
        add hl,de
        cp (hl)
        jr z,hd_next
        ld (hl),a
        push bc
        call cell_draw
        pop bc
        ld hl,hd_left
        dec (hl)
        ret z
hd_next:
        inc c
        ld a,c
        cp 14
        jr c,hd_lp
        ld a,(hd_left)
        cp HUD_DIGITS
        ret nz                      ; something drawn: look again next frame
        ld hl,hud_timer             ; every cell is right for these values
        ld de,hud_last
        ld bc,8
        ldir
        ret

; C = cell -> A = the digit the values ask for (keeps BC).
cell_digit:
        ld e,c
        ld d,0
        ld hl,cell_src
        add hl,de
        ld a,(hl)
        ld e,a
        and 0x7F
        push de
        ld e,a
        ld hl,hud_timer
        add hl,de
        ld a,(hl)
        pop de
        bit 7,e
        jr z,cd_lo
        rrca
        rrca
        rrca
        rrca
cd_lo:  and 15
        ret

; Per cell: offset of its byte from hud_timer, bit 7 = high nibble (the game's layouts).
cell_src:
        db 0x80, 0x00, 0x81, 0x01          ; timer MM, SS
        db 0x02, 0x83, 0x03                ; ammo: hundreds in the low nibble, tens, units
        db 0x04, 0x85, 0x05, 0x86, 0x06, 0x87, 0x07   ; score

; C = cell, A = digit: writes its patch (16 lines).
cell_draw:
        ld hl,hud_cost
        ld b,a
        ld a,(hl)
        add a,COST_DIGIT
        ld (hl),a
        ld a,b
        push af
        ld l,c
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl                   ; *8
        ld d,h
        ld e,l
        add hl,hl                   ; *16
        add hl,de                   ; *24
        ld de,HUD_CELLS
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; VRAM
        inc hl
        ld c,(hl)                   ; bytes per line
        inc hl
        inc hl
        pop af
        add a,a
        push de
        ld e,a
        ld d,0
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; patch
        pop hl
        ld b,16
        jp hud_put

; ----- energy can -----

; One step of update_energy_can ($89BE) on the game's frames (it ran at the game's 30 Hz): the
; shown level moves 8 units towards the target; a target of 100h or more draws the full can
; (as a job); otherwise a step from an old level L >= 2 (L = old shown / 8) draws an empty
; top (variant by L) at panel line 33 - L and the can's own line 39 - L at panel line 42 - L.
; Carry on return when it drew something (or asked for the full can).
hud_energy:
        ld a,(g_tick)
        or a
        ret z
        ld hl,(en_target)
        ld a,l
        and 0xF8
        ld l,a
        ld de,(en_shown)
        ld a,e
        and 0xF8
        ld e,a
        or a
        sbc hl,de
        ret z                       ; (no carry)
        ld de,-8
        bit 7,h
        jr nz,he_dir
        ld de,8
he_dir: ld hl,(en_shown)
        push hl                     ; old shown
        add hl,de
        ld (en_shown),hl
        ld hl,(en_target)
        ld de,0x100
        or a
        sbc hl,de
        jp m,he_step
        ld (en_target),de
        ld (en_shown),de
        pop hl
        ld a,JOB_CAN
        ld c,0
        call hud_request
        scf
        ret
he_step:
        pop hl
        ld de,0x10
        or a
        sbc hl,de
        jp p,he_draw
        or a
        ret                         ; old level below 2: nothing drawn
he_draw:
        ld a,(hud_cost)
        add a,COST_STEP
        ld (hud_cost),a
        add hl,de
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l                        ; L (2..32)
        ld c,l
        ld a,c
        ld de,HUD_TOPS
        cp 24
        jr nc,he_top
        ld de,HUD_TOPS + 8*14
        cp 13
        jr nc,he_top
        ld de,HUD_TOPS + 2*8*14
he_top: ld a,33 - 3
        sub c                       ; can line of the top: (33 - L) - 3
        call can_line
        push bc
        ld bc,8*256 + 14
        call hud_put                ; the empty top
        pop bc
        ld a,39
        sub c                       ; can graphic line 39 - L
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,de
        add hl,hl
        add hl,de
        add hl,hl                   ; *14
        ld de,HUD_CAN
        add hl,de
        ex de,hl
        ld a,42 - 3
        sub c                       ; at can line (42 - L) - 3
        call can_line
        ld bc,1*256 + 14
        call hud_put
        scf
        ret

; A = line of the can element (0 = panel line 3, signed) -> HL = its VRAM address. Keeps BC, DE.
can_line:
        ld l,a
        rla
        sbc a,a
        ld h,a                      ; (signed: the empty top of levels 31-32 starts above the can)
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; *128
        push de
        ld de,HUD_CAN_V
        add hl,de
        pop de
        ret

; ----- jobs: heads, icon, full can -----

; A = type (JOB_HEAD0/1, JOB_ICON, JOB_CAN), C = graphic / icon: queued (4 at most).
hud_request:
        ld b,a
        ld a,(jobq_n)
        cp 4
        ret nc
        ld e,a
        inc a
        ld (jobq_n),a
        ld d,0
        ld hl,jobq
        add hl,de
        add hl,de
        ld (hl),b
        inc hl
        ld (hl),c
        ret

; Starts the next request when no job runs, then writes up to HUD_JOB_LINES lines of the job;
; the state shown (heads_g, icon_shown) changes when its last line is written.
hud_jobs:
        ld a,(job_lines)
        or a
        jp nz,hj_run
        ld a,(jobq_n)
        or a
        ret z
        dec a
        ld (jobq_n),a
        ld hl,(jobq)
        ld (job_done),hl
        ld hl,jobq + 2              ; the others move down
        ld de,jobq
        ld bc,6
        ldir
        ld a,(job_done)
        ld c,a
        ld a,(job_done+1)
        ld b,a                      ; B = value, C = type
        ld a,c
        cp JOB_ICON
        jr z,hj_icon
        cp JOB_CAN
        jr z,hj_can
        ld l,b                      ; head: graphic * 992 (+ 512 in slot 1)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; *32
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; *1024
        or a
        sbc hl,de                   ; *992
        ld de,HUD_HEADS
        add hl,de
        ld a,c
        or a
        ld de,HUD_HEAD0_V
        ld b,16
        jr z,hj_head
        ld de,512
        add hl,de
        ld de,HUD_HEAD1_V
        ld b,15
hj_head:
        ld a,HUD_HEAD_LINES
        jr hj_set
hj_icon:
        ld l,b
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; *128
        ld de,HUD_ICONS
        add hl,de
        ld de,HUD_ICON_V
        ld b,8
        ld a,16
        jr hj_set
hj_can: ld hl,HUD_CAN
        ld de,HUD_CAN_V
        ld b,14
        ld a,40
hj_set: ld (job_src),hl
        ld (job_dst),de
        ld (job_lines),a
        ld a,b
        ld (job_n),a
hj_run: ld a,(hud_cost)
        add a,COST_JOB
        ld (hud_cost),a
        ld a,(job_lines)
        ld b,a
        cp HUD_JOB_LINES + 1
        jr c,hj_n
        ld b,HUD_JOB_LINES
hj_n:   sub b
        ld (job_lines),a
        ld a,(job_n)
        ld c,a
        ld de,(job_src)
        ld hl,(job_dst)
        call hud_put
        ld (job_src),de
        ld (job_dst),hl
        ld a,(job_lines)
        or a
        ret nz
        ld a,(job_done)             ; complete: what the HUD shows now
        ld c,a
        ld a,(job_done+1)
        ld b,a
        ld a,c
        cp JOB_ICON
        jr z,hj_dicon
        ret nc                      ; (the can: en_shown already says it)
        ld e,c
        ld d,0
        ld hl,heads_g
        add hl,de
        ld (hl),b
        ret
hj_dicon:
        ld a,b
        ld (icon_shown),a
        ret

        if DEMO_HUD                 ; (builds with the HUD demo only)

; ----- demo of the game's events (until the game logic is ported) -----

; Timer -1 s every 60 frames (09:58 again after 00:00); score +150 every 97 frames; ammo -1
; every 8 frames; energy -18h every 90 frames (refilled to full below 20h); the next weapon
; every 480 frames (ammo and icon from set_weapon's tables); the next message every 240
; frames; every 900 frames a life lost (heads 3, 4, 5 in slot lives-1, 8 frames apart) or,
; with none left, an extra life (head 0 and "EXTRA LIFE.").
hud_demo:
        call hud_map
        ld hl,demo_t
        dec (hl)
        jr nz,dm_1
        ld (hl),60
        call bcd_timer
dm_1:   ld hl,demo_t + 1
        dec (hl)
        jr nz,dm_2
        ld (hl),97
        ld de,0x0150
        call bcd_score
dm_2:   ld hl,demo_t + 2
        dec (hl)
        jr nz,dm_3
        ld (hl),8
        call bcd_ammo
dm_3:   ld hl,demo_t + 3
        dec (hl)
        jr nz,dm_4
        ld (hl),90
        ld hl,(en_target)
        ld de,-0x18
        add hl,de
        ld a,h
        or a
        jr nz,dm_full               ; (below 0)
        ld a,l
        cp 0x20
        jr nc,dm_e
dm_full:
        ld hl,0x102
dm_e:   ld (en_target),hl
dm_4:   ld hl,demo_w
        ld de,480
        call countdown
        call z,demo_weapon
        ld hl,demo_w + 2
        ld de,240
        call countdown
        call z,demo_message
        ld hl,demo_w + 4
        ld de,900
        call countdown
        call z,demo_life
        ld a,(demo_anim)
        or a
        ret z
        ld a,(frame)
        and 7
        ret nz
        ld a,(demo_anim)            ; 3, 4, 5, then the life is gone
        cp 6
        jr z,dm_lost
        ld c,a
        inc a
        ld (demo_anim),a
        ld a,(lives)
        dec a
        jp hud_request              ; JOB_HEAD0 / JOB_HEAD1 = slot
dm_lost:
        xor a
        ld (demo_anim),a
        ld hl,lives
        dec (hl)
        ret

; HL -> word countdown, DE = its period: Z when it runs out (and it starts again).
countdown:
        ld a,(hl)
        sub 1
        ld (hl),a
        inc hl
        ld a,(hl)
        sbc a,0
        ld (hl),a
        dec hl
        or (hl)
        ret nz
        ld (hl),e
        inc hl
        ld (hl),d
        xor a
        ret

demo_init:
        ld hl,demo_init_t
        ld de,demo_t
        ld bc,10
        ldir
        xor a
        ld (demo_anim),a
        ld (demo_msg),a
        ret
demo_init_t:
        db 60, 97, 8, 90
        dw 480, 120, 900

demo_weapon:
        ld a,(weapon)
        inc a
        and 3
        ld (weapon),a
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,HUD_WEAPONS
        add hl,de
        ld de,hud_ammo
        ldi
        ldi                         ; its ammo
        ld c,(hl)
        ld a,JOB_ICON
        jp hud_request

demo_message:
        ld a,(demo_msg)
        ld e,a
        inc a
        cp HUD_NMSGS
        jr c,dms_n
        xor a
dms_n:  ld (demo_msg),a
        ld d,0
        ld hl,HUD_MSGS
        add hl,de
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp hud_message

demo_life:
        ld a,(demo_anim)
        or a
        ret nz
        ld a,(lives)
        or a
        jr z,dl_extra
        ld a,3
        ld (demo_anim),a
        ret
dl_extra:
        ld a,1
        ld (lives),a
        ld c,0
        ld a,JOB_HEAD0
        call hud_request
        ld hl,HUD_MSGS + 2*5        ; "EXTRA LIFE."
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp hud_message

; Timer minus one second (BCD); 00:00 goes back to 09:58.
bcd_timer:
        ld hl,hud_timer + 1
        ld a,(hl)
        sub 1
        daa
        jr c,bt_min
        ld (hl),a
        ret
bt_min: ld (hl),0x59
        dec hl
        ld a,(hl)
        sub 1
        daa
        jr c,bt_wrap
        ld (hl),a
        ret
bt_wrap:
        ld (hl),0x09
        inc hl
        ld (hl),0x58
        ret

; DE = BCD amount (4 digits) added to the score (7 digits).
bcd_score:
        ld hl,hud_score + 3
        ld a,(hl)
        add a,e
        daa
        ld (hl),a
        dec hl
        ld a,(hl)
        adc a,d
        daa
        ld (hl),a
        dec hl
        ld a,(hl)
        adc a,0
        daa
        ld (hl),a
        dec hl
        ld a,(hl)
        adc a,0
        daa
        and 15                      ; 7 digits: the first byte keeps one
        ld (hl),a
        ret

; Ammo minus one (BCD), stopping at 000.
bcd_ammo:
        ld hl,hud_ammo
        ld a,(hl)
        inc hl
        or (hl)
        ret z
        ld a,(hl)
        sub 1
        daa
        ld (hl),a
        ret nc
        dec hl
        ld a,(hl)
        sub 1
        daa
        and 15
        ld (hl),a
        ret
        endif
