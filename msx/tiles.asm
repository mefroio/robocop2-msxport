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
; in the ROM; the 432 VRAM slots start with tiles 0-431 (vdp_setup) and a tile that is not in
; VRAM is copied into the slot the clock hand finds unused since it last passed (tile_src).

TC_SLOTS:   equ 432

; Page 0 (0000h-3FFFh) switched to the main RAM (the slot of page 3) once the BIOS is not
; needed any more: the game never calls it after its start and IM 2 does not use page 0.
; Carry on return when there is no RAM there.
ram_page0:
        di
        in a,(0xA8)
        ld b,a                      ; B = primary slot register
        rlca
        rlca
        and 3
        ld c,a                      ; C = page 3's primary slot
        ld e,a
        ld d,0
        ld hl,EXPTBL
        add hl,de
        bit 7,(hl)
        jr z,rp_prim
        ld a,(0xFFFF)
        cpl                         ; its secondary slot register
        ld d,a
        and 0xFC
        ld e,a
        ld a,d
        rlca
        rlca
        and 3                       ; page 3's secondary slot
        or e
        ld (0xFFFF),a
rp_prim:
        ld a,b
        and 0xFC
        or c
        out (0xA8),a
        ld hl,0x0000                ; is it RAM?
        ld a,0x5A
        ld (hl),a
        cp (hl)
        jr nz,rp_none
        cpl
        ld (hl),a
        cp (hl)
        jr nz,rp_none
        ld hl,0x3FFF
        ld (hl),a
        cp (hl)
        jr nz,rp_none
        ei
        or a
        ret
rp_none:
        ei
        scf
        ret

; The tile cache and the map patches at the start of a level: slots 0-431 hold tiles 0-431
; (uploaded by vdp_setup), no patch, nothing to redraw.
tiles_init:
        ld hl,TC_SLOT
        ld de,1
        ld b,TC_SLOTS/2
ti_s:   ld (hl),e                   ; tile t: slot t + 1
        inc hl
        ld (hl),d
        inc hl
        inc de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        inc de
        djnz ti_s
        ld bc,(512 - TC_SLOTS)*2
        xor a
        call fill                   ; tiles 432-511: not in VRAM
        ld hl,TC_TILE
        ld de,0
        ld b,TC_SLOTS/2
ti_t:   ld (hl),e                   ; slot s: tile s
        inc hl
        ld (hl),d
        inc hl
        inc de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        inc de
        djnz ti_t
        ld hl,TC_REF
        ld bc,TC_SLOTS
        xor a
        call fill
        ld hl,0
        ld (tc_hand),hl
        ld hl,MP_ROW
        ld bc,256
        ld a,0xFF
        call fill                   ; no patch in any row
        ld hl,MP_NEXT               ; every patch free, chained
        xor a
mi_f:   inc a
        ld (hl),a
        inc l
        jr nz,mi_f
        dec l
        ld (hl),0xFF
        xor a
        ld (mp_free),a
        ld (mp_used),a
        ld (mp_lost),a
        ld (rd_head),a
        ld (rd_tail),a
        ld (rd_phase),a
        ld (rd_lost),a
        ld (tc_loads),a
        ret

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
        jp rd_queue
mw_full:
        ld hl,mp_lost               ; (more patches than the table holds: counted)
        inc (hl)
mw_done:
        pop de
        ret

; D = row, E = column: the cell is redrawn where the scroll engine shows it, when it is near
; the view (a full queue drops the request: counted in rd_lost). Keeps DE.
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
        ld a,(rd_tail)
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

; The oldest request is done.
rd_pop: ld a,(rd_head)
        add a,2
        and RD_Q_SIZE*2 - 1
        ld (rd_head),a
        xor a
        ld (rd_phase),a
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
