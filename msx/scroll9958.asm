; Hardware scroll on the V9958 (MSX2+): 512x256 ring with SP2 (pages 0+1).
; World column c -> x = (c*16) & 511 (page = bit 8); row r -> y = (r*16) & 255.
; Keeps columns [cx-1, cx+17] and rows [cy-1, cy+12] drawn; the column/row about to enter
; is queued one step ahead and drawn one tile per scroll_work call while the VDP is idle;
; then the cells the game changed (tiles.asm rd_queue).

; draw_tile: A = row, E = column (world). Ignores tiles outside the map.
draw_tile:
        call dt_prep
        ret nc
        call vdp_wait
        ld hl,cmdbuf
        call vdp_cmd
dt_count:
        ld hl,(tiles_drawn)
        inc hl
        ld (tiles_drawn),hl
        ret

; A = row, E = column (world) -> C with cmdbuf set for the tile's copy into the ring, NC outside
; the map. Keeps DE.
dt_prep:
        cp MAP_ROWS
        ret nc
        ld c,a
        ld a,e
        cp MAP_COLS
        ret nc
        ld a,c
        call fb_mark                ; (field.asm: the play-field BOBs over it again)
        call tile_src
        ld a,c                      ; (tile_src keeps BC, not A)
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+6),a             ; DY = (row*16) & 255
        ld a,e
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+4),a             ; DX = (column*16) & 255
        xor a
        ld (cmdbuf+5),a
        ld a,e
        rrca
        rrca
        rrca
        rrca
        and 1
        ld (cmdbuf+7),a             ; ring page 0/1
        ld hl,16
        ld (cmdbuf+8),hl
        ld (cmdbuf+10),hl
        scf
        ret

; Once per frame: one column/row step at a time (the camera waits at the cell edge while
; the previous one is pending), one tile of work, then the registers of the next frame. It works
; toward the view the game wants (v_x, v_y; cam_x, cam_y are what it shows), also on frames
; without a tick (the cadence holds the ticks while the view shown lags far behind).
scroll_update:
        ld a,1
        ld (iw_more),a              ; (there may be work for scroll_work from now on)
        ld hl,(v_x)
        ld (cam_x),hl
        ld hl,(v_y)
        ld (cam_y),hl
        call cam_cells              ; B = cx, C = cy
        ld a,(prev_cx)
        cp b
        jr z,su_v
        ld a,(q_col)
        cp 0xFF
        jr nz,su_hhold
        ld a,(prev_cx)
        cp b
        jr c,su_right
        dec a
        ld (prev_cx),a
        dec a                       ; moved left: new column prev_cx-1
        jr su_qcol
su_right:
        inc a
        ld (prev_cx),a
        add a,17                    ; moved right: new column prev_cx+17
su_qcol:
        ld (q_col),a
        ld a,(prev_cy)
        dec a
        ld (q_col_row),a
        add a,VIEW_ROWS
        ld (q_col_end),a
        ld a,(prev_cx)
        cp b
        jr z,su_v
su_hhold:
        ld hl,(stall)
        inc hl
        ld (stall),hl
        ld a,(prev_cx)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        cp b
        jr nc,su_hset               ; moving left: hold at prev_cx*16
        ld de,15
        add hl,de                   ; moving right: hold at prev_cx*16+15
su_hset:
        ld (cam_x),hl
su_v:   ld a,(prev_cy)
        cp c
        jr z,su_work
        ld a,(q_row)
        cp 0xFF
        jr nz,su_vhold
        ld a,(prev_cy)
        cp c
        jr c,su_down
        dec a
        ld (prev_cy),a
        dec a                       ; moved up: new row prev_cy-1
        jr su_qrow
su_down:
        inc a
        ld (prev_cy),a
        add a,VIEW_ROWS-2           ; moved down: new row prev_cy+12
su_qrow:
        ld (q_row),a
        ld a,(prev_cx)
        dec a
        ld (q_row_col),a
        add a,19
        ld (q_row_end),a
        ld a,(prev_cy)
        cp c
        jr z,su_work
su_vhold:
        ld hl,(vstall)
        inc hl
        ld (vstall),hl
        ld a,(prev_cy)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        cp c
        jr nc,su_vset               ; moving up: hold at prev_cy*16
        ld de,15
        add hl,de                   ; moving down: hold at prev_cy*16+15
su_vset:
        ld (cam_y),hl
su_work:
        jp scroll_work

; Draws one queued tile if the VDP is idle (column first, then row); between the HUD split and
; the VBLANK the cells the game changed come first.
scroll_work:
        call vdp_busy
        ret nz
        ld a,(split_armed)
        or a
        jr nz,sw_cq
        call sw_redraw
        call vdp_busy
        ret nz
sw_cq:  ld a,(q_col)
        cp 0xFF
        jr z,sw_row
        ld e,a
        ld a,(q_col_row)
        push af
        inc a
        ld (q_col_row),a
        ld b,a
        ld a,(q_col_end)
        cp b
        jr nz,sw_col
        ld a,0xFF
        ld (q_col),a
sw_col: pop af
        jp draw_tile
sw_row: ld a,(q_row)
        cp 0xFF
        jr z,sw_idle
        ld a,(q_row_col)
        ld e,a
        inc a
        ld (q_row_col),a
        ld b,a
        ld a,(q_row_end)
        cp b
        ld a,(q_row)
        jp nz,draw_tile
        ld b,a
        ld a,0xFF
        ld (q_row),a
        ld a,b
        jp draw_tile

; No column or row to draw: the changed cells, and with none waiting either nothing to do until
; the next update or a changed cell sets iw_more again.
sw_idle:
        call sw_redraw
        ld a,(rd_tail)
        ld hl,rd_head
        cp (hl)
        ret nz
        xor a
        ld (iw_more),a
        ret

; The cells the game changed (tiles.asm rd_queue) that are in the kept area: between the HUD split
; and the VBLANK up to RD_BURST in a row (vdp_cmd_q: started where the beam is off the play area,
; each waiting for the one before); at other times the oldest one at once (the ring is always on
; screen: a cell may then show half drawn for one picture, but a change never waits).
sw_redraw:
        ld b,RD_BURST
swr_lp: push bc
        call swr_one
        pop bc
        ret nz                      ; (no more now)
        djnz swr_lp
        ret

; -> Z when the oldest request was drawn (or dropped: out of the kept area or the map), NZ when
; there is none or it is not the time.
swr_one:
        call rd_peek
        jr z,swr_none
        ld a,(prev_cy)
        dec a
        ld b,a
        ld a,d
        sub b
        cp VIEW_ROWS
        jr nc,swr_drop
        ld a,(prev_cx)
        dec a
        ld b,a
        ld a,e
        sub b
        cp 19
        jr nc,swr_drop
        xor a
        call fb_redraw
        jr nz,swr_drop              ; (the play-field BOBs compose it: tiles.asm)
        ld a,(split_armed)
        or a
        jr nz,swr_late
        ld a,d
        call dt_prep
        jr nc,swr_drop
        call vdp_wait               ; (the one before)
        ld hl,cmdbuf
        call vdp_cmd_q
        ret nz                      ; (the time passed: again later)
        call rd_pop
        call dt_count
        xor a
        ret
swr_drop:
        call rd_pop
        xor a
        ret
swr_late:
        call rd_pop                 ; (at other times one at once: a change never waits)
        ld a,d
        call draw_tile
swr_none:
        or 1
        ret

; Registers of the next frame: R#26 = ((X+7)>>3) & 63, R#27 = (-X) & 7 with X = cam_x - 8, so
; that the camera sits at screen x = 8 as on the V9938 (MSK hides x 0-7); R#23 = cam_y,
; R#19 = split line, page 1 (odd, required by SP2).
scroll_publish:
        ld hl,(cam_x)
        ld de,0xFFFF                ; X + 7 = cam_x - 1
        add hl,de
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        and 0x3F
        ld d,a                      ; R#26
        ld a,(cam_x)
        neg
        and 7
        ld e,a                      ; R#27
        call next_list
        push hl
        inc hl
        ld (hl),18                  ; 9 registers
        inc hl
        ld a,(cam_y)
        ld (hl),a
        inc hl
        ld (hl),0x97                ; R#23 first (isr.asm iv_list: the split's R#19 from it)
        inc hl
        add a,SPLIT_LINE
        ld (hl),a
        inc hl
        ld (hl),0x93
        inc hl
        ld (hl),R25_PLAY
        inc hl
        ld (hl),0x99                ; border mask back on (the split turns it off for the HUD)
        inc hl
        ld (hl),R1_ON
        inc hl
        ld (hl),0x81
        inc hl
        ld (hl),R8_SPR_ON
        inc hl
        ld (hl),0x88
        inc hl
        ld (hl),R2_PAGE1
        inc hl
        ld (hl),0x82
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0x9A
        inc hl
        ld (hl),e
        inc hl
        ld (hl),0x9B
        inc hl
        ld a,(spr_set)
        ld (hl),a
        inc hl
        ld (hl),0x85
        inc hl
        jp list_tail
