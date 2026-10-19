; Hardware scroll on the V9958 (MSX2+): 512x256 ring with SP2 (pages 0+1).
; World column c -> x = (c*16) & 511 (page = bit 8); row r -> y = (r*16) & 255.
; Keeps columns [cx-1, cx+17] and rows [cy-1, cy+13] drawn.

; draw_tile: A = row, E = column (world). Ignores tiles outside the map.
draw_tile:
        cp MAP_ROWS
        ret nc
        ld c,a
        ld a,e
        cp MAP_COLS
        ret nc
        ld a,c
        push af
        push de
        call get_tile
        call set_src
        pop de
        pop af
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
        call vdp_wait
        ld hl,cmdbuf
        call vdp_cmd
        ld hl,(tiles_drawn)
        inc hl
        ld (tiles_drawn),hl
        ret

; Fills the initial ring and clears the queues.
scroll_init:
        ld a,0x3F
        ld b,2
        call wrreg                  ; displays page 1 (odd): required by SP2
        ld a,0x03
        ld b,25
        call wrreg                  ; R#25 = SP2 (512 px ring) + MSK (hides the left 8 px)
        ld hl,0
        ld (cam_x),hl
        ld (frame),hl
        ld (late),hl
        ld (tiles_drawn),hl
        ld hl,CAM_Y_MAX
        ld (cam_y),hl
        xor a
        ld (dir_y),a
        ld a,0xFF
        ld (q_col),a
        ld (q_row),a
        call cam_cells              ; B = cx, C = cy
        ld a,b
        ld (prev_cx),a
        ld a,c
        ld (prev_cy),a
        ; rows cy-1 .. cy+13, columns cx-1 .. cx+17
        ld a,c
        dec a
        ld d,a                      ; current row
        ld a,c
        add a,14
        ld (budget),a               ; used here as the row limit
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
        ld a,(budget)
        cp d
        jr nz,si_row
        jp scroll_regs

; R#23 = cam_y & 255; X = cam_x & 511: R#26 = (X+7)>>3, R#27 = (-X) & 7
scroll_regs:
        ld a,(cam_y)
        ld b,23
        call wrreg
        ld hl,(cam_x)
        ld de,7
        add hl,de
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        and 0x3F
        ld b,26
        call wrreg
        ld a,(cam_x)
        neg
        and 7
        ld b,27
        jp wrreg

; Detects a cell change and queues a column/row; draws up to TILES_PER_FRAME tiles.
scroll_update:
        call cam_cells
        ld a,(prev_cx)
        cp b
        jr z,su_v
        jr c,su_right
        ; moved left: column cx-1
        ld a,b
        dec a
        jr su_qcol
su_right:
        ld a,b
        add a,17
su_qcol:
        ld (q_col),a
        ld a,c
        dec a
        ld (q_col_row),a
        add a,15
        ld (q_col_end),a
        ld a,b
        ld (prev_cx),a
su_v:   ld a,(prev_cy)
        cp c
        jr z,su_draw
        jr c,su_down
        ld a,c
        dec a
        jr su_qrow
su_down:
        ld a,c
        add a,13
su_qrow:
        ld (q_row),a
        ld a,b
        dec a
        ld (q_row_col),a
        add a,19
        ld (q_row_end),a
        ld a,c
        ld (prev_cy),a
su_draw:
        ld a,TILES_PER_FRAME
        ld (budget),a
sd_col: ld a,(q_col)
        cp 0xFF
        jr z,sd_row
        ld a,(budget)
        or a
        ret z
        dec a
        ld (budget),a
        ld a,(q_col)
        ld e,a
        ld a,(q_col_row)
        call draw_tile
        ld a,(q_col_row)
        inc a
        ld (q_col_row),a
        ld b,a
        ld a,(q_col_end)
        cp b
        jr nz,sd_col
        ld a,0xFF
        ld (q_col),a
sd_row: ld a,(q_row)
        cp 0xFF
        ret z
        ld a,(budget)
        or a
        ret z
        dec a
        ld (budget),a
        ld a,(q_row_col)
        ld e,a
        ld a,(q_row)
        call draw_tile
        ld a,(q_row_col)
        inc a
        ld (q_row_col),a
        ld b,a
        ld a,(q_row_end)
        cp b
        jr nz,sd_row
        ld a,0xFF
        ld (q_row),a
        ret
