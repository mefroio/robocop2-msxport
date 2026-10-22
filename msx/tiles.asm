; Common tile code: the map (ROM, under the patches the game writes at run time) and the tile
; cache (VRAM pages 2-3).
;
; Map patches: the Amiga game writes map words while it runs (map objects copy their look into
; the map every frame, docs/AMIGA_ANALYSIS.md). map_write keeps such cells in page-0 RAM: per
; row a chain of patches (column, tile, attributes); get_tile and atr_rc read them before the
; ROM map. A patch that changes a cell's tile queues the cell for the scroll engines, which
; redraw it where it is shown (rd_q).
;
; Tile cache: the level's tile sheet (up to 512 tiles, most used first, tools/msxconv.py) is
; in the ROM; the TC_SLOTS VRAM slots start with tiles 0..TC_SLOTS-1 (vdp_setup) and a tile that is not in
; VRAM is copied into the slot the clock hand finds unused since it last passed (tile_src).

TC_SLOTS:   equ 256                 ; (page 2: 432 until the play-field BOBs took page 3 lines 0-175;
                                    ; the view and a margin use 129 tiles at most, a 40x24-cell window
                                    ; 209)

; At the level's start: the packed map attributes (bank ATR_BANK: 80 bytes per row, 4-bit
; codes, then the codes' 16 values) into page-0 RAM - rows 0-47 at ATR_RAM0, the others at
; ATR_RAM1 (atr_rows: each row's address) - and the values into atr_lut. atr_rc reads them
; there: no bank switching for the game logic's many attribute reads.
atr_load:
        ld a,(act_8000)
        push af
        ld a,ATR_BANK
        call bank_8000
        ld hl,0x8000
        ld de,ATR_RAM0
        ld bc,48*80
        ldir
        ld de,ATR_RAM1
        ld bc,(MAP_ROWS - 48)*80
        ldir
        ld de,atr_lut
        ld bc,16
        ldir
        pop af
        jp bank_8000

; ----- map reads -----

; get_tile: A = row, E = column -> HL = tile. Preserves BC and DE (and the A000h window's bank).
get_tile:
        push de
        ld d,a
        ld l,a
        ld h,MP_ROW/256
        ld a,(hl)                   ; the row's first patch (FFh: none)
gt_pl:  cp 0xFF
        jr z,gt_rom
        ld l,a
        ld h,MP_COL/256
        ld a,(hl)
        cp e
        jr z,gt_hit
        ld h,MP_NEXT/256
        ld a,(hl)
        jr gt_pl
gt_hit: ld h,MP_TILEL/256
        ld a,(hl)
        ld h,MP_TILEH/256
        ld h,(hl)
        ld l,a
        pop de
        ret
gt_rom: ld a,d
        ld l,a
        ld h,0
        ld e,a
        ld d,0
        add hl,hl
        add hl,de                   ; row * 3 (rowtab: bank, address)
        ld de,rowtab
        add hl,de
        ld a,(act_a000)
        push af                     ; (the window's bank is put back: the game logic runs there)
        ld a,(hl)
        call bank_a000
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop af
        pop de
        push de
        push af
        ld d,0
        add hl,de
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop af
        call bank_a000
        pop de
        ret

; D = row, E = column (-1..160: the neighbours wrap into the rows above and below, as the
; Amiga's linear map does) -> A = the cell's attributes (rows 51-52: the bits of the words after
; the map, ATR2; 0 further out). Keeps BC, DE, HL
; (and the 8000h window's bank).
atr_rc: ld a,e
        cp MAP_COLS
        jr nc,ar_wrap
        ld a,d
        cp MAP_ROWS
        jr nc,ar_after0
        push hl
        ld l,a
        ld h,MP_ROW/256
        ld a,(hl)
        inc a
        jr nz,ar_pl0                ; (the row has patches)
ar_rom: ld a,d                      ; the packed map in page-0 RAM (atr_load): 4-bit codes
        add a,a
        add a,atr_rows & 0xFF
        ld l,a
        ld a,0
        adc a,atr_rows / 256
        ld h,a
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                      ; the row's 80 bytes
        ld a,e
        srl a
        add a,l
        ld l,a
        jr nc,ar_nb
        inc h
ar_nb:  ld a,(hl)
        bit 0,e
        jr nz,ar_odd
        rrca                        ; (an even column: the high nibble)
        rrca
        rrca
        rrca
ar_odd: and 15
        add a,atr_lut & 0xFF        ; (atr_lut does not cross a 256-byte boundary)
        ld l,a
        ld h,atr_lut / 256
        ld a,(hl)                   ; its attributes
        pop hl
        ret
ar_pl0: dec a
ar_pl:  ld l,a
        ld h,MP_COL/256
        ld a,(hl)
        cp e
        jr z,ar_hit
        ld h,MP_NEXT/256
        ld a,(hl)
        cp 0xFF
        jr nz,ar_pl
        jr ar_rom
ar_hit: ld h,MP_ATR/256
        ld a,(hl)
        pop hl
        ret
ar_wrap:                            ; 160: the next row's first cell; -1 (FFh): the previous
        push de                     ; row's last one
        inc d
        ld e,0
        inc a
        jr nz,ar_w1
        dec d
        dec d
        ld e,MAP_COLS - 1
ar_w1:  call atr_rc
        pop de
        ret
ar_after0:
        push hl
        push de
        call ar_after
        pop de
        pop hl
        ret
ar_after:                           ; the two rows after the map: the words that follow it
        sub MAP_ROWS                ; in the Amiga's memory (graphics), as the game reads them
        cp 2
        jr nc,ar_none
        push bc
        ld c,e
        ld b,0
        ld hl,ATR2
        add hl,bc
        or a
        jr z,ar_a2
        ld bc,MAP_COLS
        add hl,bc
ar_a2:  ld a,(act_8000)
        ld b,a
        ld a,LEVEL_BANK
        call bank_8000
        ld c,(hl)
        ld a,b
        call bank_8000
        ld a,c
        pop bc
        ret
ar_none:
        xor a
        ret

; D = row, E = column, HL = an Amiga map word (DATAL tile offset | attributes): the cell becomes
; that (tile through the level's offset table, attributes in the low 7 bits). A changed tile is
; queued for redrawing. Keeps DE.
map_write:
        push de
        ld a,l
        and 0x7F
        ld (mw_atr),a
        ld a,l
        rla
        ld a,h
        rla
        ld l,a
        ld a,h
        rlca
        and 1
        ld h,a                      ; HL = offset >> 7
        add hl,hl
        ld de,OTILE
        add hl,de
        ld a,(act_8000)
        push af                     ; (the window's bank is put back: the game logic runs there)
        ld a,LEVEL_BANK
        call bank_8000
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; BC = tile
        pop af
        call bank_8000
        pop de
        push de
        ld l,d
        ld h,MP_ROW/256
        ld a,(hl)
mw_pl:  cp 0xFF
        jr z,mw_new
        ld l,a
        ld h,MP_COL/256
        ld a,(hl)
        cp e
        jr z,mw_upd
        ld h,MP_NEXT/256
        ld a,(hl)
        jr mw_pl
mw_upd: ld h,MP_ATR/256             ; the cell has a patch: updated
        ld a,(mw_atr)
        ld (hl),a
        ld h,MP_TILEL/256
        ld a,(hl)
        ld (hl),c
        ld h,MP_TILEH/256
        cp c
        ld a,(hl)
        ld (hl),b
        jr nz,mw_redraw
        cp b
        jr z,mw_done
mw_redraw:
        pop de
        call fb_invf
        jp rd_queue
mw_new: push bc                     ; no patch: nothing to do when the ROM map has the same
        ld a,d                      ; tile and attributes
        call get_tile
        pop bc
        or a
        sbc hl,bc
        jr nz,mw_new1
        call atr_rc
        ld hl,mw_atr
        cp (hl)
        jr z,mw_done
mw_new1:
        ld a,(mp_free)              ; a new patch, first in the row's chain
        cp 0xFF
        jr z,mw_full
        ld (mw_idx),a
        ld l,a
        ld h,MP_NEXT/256
        ld a,(hl)
        ld (mp_free),a
        ld l,d
        ld h,MP_ROW/256
        ld a,(hl)                   ; the row's old first patch
        push af
        ld a,(mw_idx)
        ld (hl),a
        ld l,a
        ld h,MP_NEXT/256
        pop af
        ld (hl),a
        ld h,MP_COL/256
        ld (hl),e
        ld h,MP_ATR/256
        ld a,(mw_atr)
        ld (hl),a
        ld h,MP_TILEL/256
        ld (hl),c
        ld h,MP_TILEH/256
        ld (hl),b
        ld hl,mp_used
        inc (hl)
        pop de
        call fb_invf
        jp rd_queue
mw_full:
        ld hl,mp_lost               ; (more patches than the table holds: counted)
        inc (hl)
mw_done:
        pop de
        ret

; D = row, E = column: the cell is redrawn where the scroll engine shows it, when it is near
; the view; once only while it waits (rd_bits: its redraw reads the map then; the level's
; beams rewrite their cells every tick), but again when it is the oldest, drawn on the V9938's
; first page only. A full queue drops the request (counted in rd_lost). Keeps DE.
rd_queue:
        call cam_cells              ; B = cx, C = cy
        ld a,d
        sub c
        inc a
        cp VIEW_ROWS + 2
        ret nc
        ld a,e
        sub b
        inc a
        cp 20
        ret nc
        call rd_bit
        ld c,a
        and (hl)
        jr z,rq_new
        ld a,(rd_phase)
        or a
        ret z
        ld a,(rd_head)
        ld l,a
        ld h,RD_Q/256
        ld a,(hl)
        cp d
        ret nz
        inc l
        ld a,(hl)
        cp e
        ret nz
        jr rq_add
rq_new: ld a,c
        or (hl)
        ld (hl),a
rq_add: ld a,(rd_tail)
        ld l,a
        add a,2
        and RD_Q_SIZE*2 - 1
        ld h,a
        ld a,(rd_head)
        cp h
        jr z,rq_full
        ld a,h
        ld (rd_tail),a
        ld h,RD_Q/256
        ld (hl),d
        inc l
        ld (hl),e
        ret
rq_full:
        ld hl,rd_lost
        inc (hl)
        ret

; -> Z when nothing waits to be redrawn, else D = row, E = column of the oldest request.
rd_peek:
        ld a,(rd_tail)
        ld l,a
        ld a,(rd_head)
        cp l
        ret z
        ld l,a
        ld h,RD_Q/256
        ld d,(hl)
        inc l
        ld e,(hl)
        or 1
        ret

; The oldest request is done (no longer waiting: rd_bits). Keeps BC, DE.
rd_pop: ld a,(rd_head)
        ld l,a
        ld h,RD_Q/256
        push de
        ld d,(hl)
        inc l
        ld e,(hl)
        call rd_bit
        cpl
        and (hl)
        ld (hl),a
        pop de
        ld a,(rd_head)
        add a,2
        and RD_Q_SIZE*2 - 1
        ld (rd_head),a
        xor a
        ld (rd_phase),a
        ret

; D = row, E = column -> HL = its byte of rd_bits, A = its bit: (row & 15) * 20 + column % 20,
; one bit for each cell of the window rd_queue keeps (16 rows, 20 columns). Keeps BC, DE.
rd_bit: push bc
        push de
        ld a,e
rbt_m:  sub 20
        jr nc,rbt_m
        add a,20
        ld e,a
        ld a,d
        and 15
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld c,l
        ld b,h
        add hl,hl
        add hl,hl
        add hl,bc                   ; row * 20
        ld d,0
        add hl,de
        ld a,l
        and 7
        ld b,a
        srl h
        rr l
        srl h
        rr l
        srl h
        rr l
        ld de,rd_bits
        add hl,de
        ld a,1
        inc b
rbt_s:  dec b
        jr z,rbt_x
        add a,a
        jr rbt_s
rbt_x:  pop de
        pop bc
        ret

; A = row, E = column of a tile drawn into the V9958's ring: when it meets a play-field BOB (or the
; field engine's work there), field.asm composes the cell again with the BOBs over it
; (fb_redraw). Keeps all.
fb_mark:
        push af
        push de
        ld d,a
        xor a
        call fb_meetq
        pop de
        pop af
        ret

; B = row, E = column, D = V9938 page of a tile drawn: on the page shown, or on the page being
; built once it holds the BOBs (fb_bsync), the same; before, where it meets a BOB the sync composes
; it (field.asm fb_bbcell). Keeps BC, DE, HL.
fb_mark38:
        ld a,(s38_vis_page)
        cp d
        jr z,fm38_go
        ld a,(s38_back_c0)
        push hl
        ld hl,fb_bsync
        cp (hl)
        pop hl
        jr nz,fm38_bb
fm38_go:
        push de
        ld a,d
        ld d,b
        call fb_meetq
        pop de
        ret
fm38_bb:
        push bc
        push de
        push hl
        ld d,b
        ld hl,fb_bbcell
        call field_call
        pop hl
        pop de
        pop bc
        ret

; D = row, E = column of a cell whose tile changed: the play-field caches holding it copy it
; again when they need it (field.asm fb_inval). Keeps DE.
fb_invf:
        push de
        ld hl,fb_inval
        call field_call
        pop de
        ret

; (isr.asm isr_vblank) -> NZ when the play-field BOBs still have work of a published picture for
; the page the published list shows (field.asm: the item being composed or one waiting, for
; s38_vis_page; page 0 on the V9958). Changes AF, BC (C: not VDP_CTRL any more), HL.
fb_pend:
        ld a,(fb_qlk)               ; (field.asm moving an item between its queue and its work)
        or a
        ret nz
        ld c,0
        ld a,(fb_eng)
        or a
        jr z,fpd_p
        ld a,(s38_vis_page)
        ld c,a
fpd_p:  ld a,(fb_ph)
        or a
        jr z,fpd_q
        ld a,(fb_cq)
        cp 4
        jr nz,fpd_c
        ld a,(fb_c2)
        dec a
        jr nz,fpd_q                 ; (its last copy runs)
fpd_c:
        ld hl,fb_cur
        call fpd_it
        ret nz
fpd_q:  ld a,(fb_qn)
        or a
        ret z
        ld b,a
        ld hl,fb_q
fpd_lp: call fpd_it
        ret nz
        ld a,l
        add a,FB_QSZ
        ld l,a
        jr nc,fpd_nc
        inc h
fpd_nc: djnz fpd_lp
        xor a
        ret
; HL = an item -> NZ when it is page C's and of a picture published (its stamp not fb_tick), but
; an explosion's (its owner a slot of expl_update: high byte 0), which the picture never waits for:
; a step drawn late shows the next one (field.asm takes the others first).
fpd_it: ld a,(hl)
        cp c
        jr nz,fpi_n
        push hl
        inc hl
        inc hl
        ld a,(hl)
        pop hl
        or a
        jr z,fpi_n
        push hl
        ld a,l
        add a,11
        ld l,a
        jr nc,fpi_c
        inc h
fpi_c:  ld a,(fb_tick)
        cp (hl)
        pop hl
        jr z,fpi_n
        or 1
        ret
fpi_n:  xor a
        ret


; D = row, E = column of a cell the game changed, about to be drawn on page A (the scroll
; engines' redraws), or of a tile drawn there (fb_mark, fb_mark38): when it meets the play-field
; BOBs' work or a BOB of that page, they compose it (field.asm fb_cellq: with the BOBs over it,
; never a hole in one) -> NZ; else Z (the scroll engine draws it). Keeps BC, DE, HL.
fb_redraw:
fb_meetq:
        push hl
        push bc
        ld c,a
        ld a,(fb_ph)
        ld hl,fb_qn
        or (hl)
        jr nz,frd_c
        ld a,c
        or a
        ld hl,fb_dn0
        jr z,frd_l
        ld hl,fb_dn1
frd_l:  ld a,(hl)
        inc a
        jr z,frd_z                  ; (unknown: nothing known there)
        dec a
        jr z,frd_z
frd_c:  ld a,c
        ld (fb_cqp),a
        push de
        ld hl,fb_cellq
        call field_call
        pop de
        pop bc
        pop hl
        ld a,(fb_cqr)
        or a
        ret
frd_z:  pop bc
        pop hl
        xor a
        ret

; ----- the tile cache -----

; A = row, E = column -> cmdbuf SX/SY at the cell's tile in VRAM (copied there first when it is
; not: the VDP must be idle then, so this waits for it). Preserves BC and DE.
tile_src:
        call get_tile
        push de
        push bc
        ld b,h
        ld c,l                      ; BC = tile
        add hl,hl
        ld de,TC_SLOT
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                   ; DE = slot + 1
        ld a,d
        or e
        call z,tc_load
        dec de
        ld hl,TC_REF
        add hl,de
        ld (hl),1
        ex de,hl
        call set_src
        pop bc
        pop de
        ret

; BC = tile, HL = its tc_slot entry + 1 -> DE = slot + 1: the first slot from the clock hand not
; used since the hand last passed gets the tile (copied from the ROM sheet).
tc_load:
        push hl
        call vdp_wait               ; (no command may be reading a slot)
        ld de,(tc_hand)
tl_lp:  inc de
        ld hl,-TC_SLOTS
        add hl,de
        jr nc,tl_in
        ld de,0
tl_in:  ld hl,TC_REF
        add hl,de
        ld a,(hl)
        or a
        jr z,tl_got
        ld (hl),0
        jr tl_lp
tl_got: ld (tc_hand),de
        ld hl,TC_TILE
        add hl,de
        add hl,de
        push de
        ld e,(hl)
        ld (hl),c
        inc hl
        ld d,(hl)
        ld (hl),b                   ; the slot holds the new tile
        ld a,d
        and e
        inc a
        jr z,tl_free
        ex de,hl
        add hl,hl
        ld de,TC_SLOT
        add hl,de
        ld (hl),0                   ; its old tile is no longer in VRAM
        inc hl
        ld (hl),0
tl_free:
        pop de
        push de
        call tc_upload
        pop de
        pop hl
        inc de
        ld (hl),d
        dec hl
        ld (hl),e
        ld hl,tc_loads
        inc (hl)
        ret

; BC = tile, DE = slot: the 16 lines of the tile (sheet position = tile: bank BANK_TILES +
; tile / 64, 2048 bytes per row of 16 tiles, 128 per line) to the slot's place in VRAM
; (10000h + the same layout). Destroys AF, BC, DE, HL.
tc_upload:
        ld a,c
        rra
        rra
        rra
        rra
        and 0x0F
        ld h,a
        ld a,b
        rlca
        rlca
        rlca
        rlca
        or h                        ; A = tile / 16 (0..31)
        ld h,a
        srl a
        srl a
        add a,BANK_TILES
        call bank_8000              ; 4 tile rows per bank
        ld a,h
        and 3
        add a,a
        add a,a
        add a,a
        add a,0x80
        ld h,a                      ; 8000h + (row & 3) * 2048
        ld a,c
        and 0x0F
        add a,a
        add a,a
        add a,a
        ld l,a                      ; + (tile & 15) * 8
        push hl
        ld a,e
        rra
        rra
        rra
        rra
        and 0x0F
        ld h,a
        ld a,d
        rlca
        rlca
        rlca
        rlca
        or h                        ; slot / 16
        add a,a
        add a,a
        add a,a
        ld h,a                      ; * 2048
        ld a,e
        and 0x0F
        add a,a
        add a,a
        add a,a
        ld l,a
        ex de,hl                    ; DE = VRAM address (low 16 bits; bit 16 set)
        pop hl                      ; HL = source
        ld b,16
tu_lp:  push bc
        push hl
        push de
        ex de,hl
        ld e,1
        call vram_write
        pop de
        pop hl
        ld bc,8*256 + VDP_DATA
        otir
        call vram_done
        ld bc,128 - 8
        add hl,bc
        ex de,hl
        ld bc,128
        add hl,bc
        ex de,hl
        pop bc
        djnz tu_lp
        ret

; set_src: HL = slot -> SX/SY in cmdbuf (slot s: x = (s & 15) * 16, y = 512 + (s & 1F0h)).
set_src:
        ld a,l
        and 0x0F
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+0),a
        xor a
        ld (cmdbuf+1),a
        ld a,l
        and 0xF0
        ld (cmdbuf+2),a
        ld a,h
        and 1
        add a,2
        ld (cmdbuf+3),a
        ret

; B = cam_x >> 4, C = cam_y >> 4
cam_cells:
        ld hl,(cam_x)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld b,a
        ld hl,(cam_y)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld c,a
        ret
