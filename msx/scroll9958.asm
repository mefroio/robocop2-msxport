; Hardware scroll on the V9958 (MSX2+): 512x256 ring with SP2 (pages 0+1).
; World column c -> x = (c*16) & 511 (page = bit 8); row r -> y = (r*16) & 255.
; Keeps columns [cx-1, cx+17] and rows [cy-1, cy+12] drawn; the column/row about to enter
; is queued one step ahead and drawn one tile per scroll_work call while the VDP is idle;
; then the cells the game changed (tiles.asm rd_queue).

; draw_tile: A = row, E = column (world). Ignores tiles outside the map.
draw_tile:
        cp MAP_ROWS
        ret nc
        ld c,a
        ld a,e
        cp MAP_COLS
        ret nc
        ld a,c
        call tile_src
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
        call vdp_wait
        ld hl,cmdbuf
        call vdp_cmd
        ld hl,(tiles_drawn)
        inc hl
        ld (tiles_drawn),hl
        ret

; Fills the initial ring and clears the queues.
scroll_init:
        ld a,R25_PLAY
        ld b,25
        call wrreg                  ; R#25 = SP2 (512 px ring) + MSK (hides the left 8 px)
        ld hl,0                     ; (the camera: set by the game, pl_init)
        ld (frame),hl
        ld (late),hl
        ld (stall),hl
        ld (vstall),hl
        ld (tiles_drawn),hl
        ld a,0xFF
        ld (q_col),a
        ld (q_row),a
        call cam_cells              ; B = cx, C = cy
        ld a,b
        ld (prev_cx),a
        ld a,c
        ld (prev_cy),a
        ; rows cy-1 .. cy+12, columns cx-1 .. cx+17
        ld a,c
        dec a
        ld d,a                      ; current row
si_row: ld a,b
        dec a
        ld e,a
si_col: push bc
        push de
        ld a,d
        call draw_tile
        pop de
        pop bc
        inc e
        ld a,b
        add a,18
        cp e
        jr nz,si_col
        inc d
        ld a,c
        add a,VIEW_ROWS-1
        cp d
        jr nz,si_row
        jp scroll_publish

; Once per frame: one column/row step at a time (the camera waits at the cell edge while
; the previous one is pending), one tile of work, then the registers of the next frame.
scroll_update:
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

; Draws one queued tile if the VDP is idle (column first, then row).
scroll_work:
        call vdp_busy
        ret nz
        ld a,(q_col)
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
        jr z,sw_redraw
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

; A cell the game changed (tiles.asm rd_queue), redrawn when it is in the kept area.
sw_redraw:
        call rd_peek
        ret z
        call rd_pop
        ld a,(prev_cy)
        dec a
        ld b,a
        ld a,d
        sub b
        cp VIEW_ROWS
        ret nc
        ld a,(prev_cx)
        dec a
        ld b,a
        ld a,e
        sub b
        cp 19
        ret nc
        ld a,d
        jp draw_tile

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
        ld a,(cam_y)
        ld (hl),a
        inc hl
        ld (hl),0x97
        inc hl
        add a,SPLIT_LINE
        ld (hl),a
        inc hl
        ld (hl),0x93
        inc hl
        ld a,(spr_set)
        ld (hl),a
        inc hl
        ld (hl),0x85
        inc hl
        jp list_tail
