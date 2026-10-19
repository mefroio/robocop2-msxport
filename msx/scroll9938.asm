; Scroll on the V9938 (MSX2): two pages aligned to 16 px + set-adjust (R#18) for the fine part.
; - The displayed page holds columns [vis_c0, vis_c0+16) at x = (col - vis_c0)*16.
; - R#18 shifts the image (and the sprites) by s = 8 - f px, f = cam_x - vis_c0*16 (0..15),
;   within the -7..+8 set-adjust range; the camera always sits at screen x = 8.
; - The back page is built for vis_c0 +1 (or -1): the new column + a 16 px shifted copy in
;   4 strips of 64 lines; when crossing 16 px the camera flips pages. If the back page is not
;   ready, the camera waits at the block limit (counted in 'stall').
; - New rows (vertical scroll through R#23, 256-line ring) go to both pages.
; - VDP commands are issued without blocking the CPU (vdp_busy).

; tile_to_page: A = row, E = column, D = page (0/1), C = first column of the page.
; Ignores whatever falls outside the page or the map.
tile_to_page:
        cp MAP_ROWS
        ret nc
        ld b,a
        ld a,e
        cp MAP_COLS
        ret nc
        sub c
        cp 16
        ret nc
        ld (s38_tmp_x),a
        push de
        push bc
        ld a,b
        call get_tile
        call set_src
        pop bc
        pop de
        ld a,(s38_tmp_x)
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+4),a             ; DX
        xor a
        ld (cmdbuf+5),a
        ld a,b
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+6),a             ; DY low = (row*16) & 255
        ld a,d
        ld (cmdbuf+7),a             ; DY high = page
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

s38_init:
        xor a
        ld b,25
        call wrreg
        ld hl,0
        ld (cam_x),hl
        ld (frame),hl
        ld (late),hl
        ld (stall),hl
        ld (tiles_drawn),hl
        ld hl,CAM_Y_MAX
        ld (cam_y),hl
        xor a
        ld (dir_y),a
        ld (s38_vis_page),a
        ld (s38_hdir),a
        ld a,0xFF
        ld (s38_back_c0),a
        ld (s38_rq),a
        call cam_cells
        ld a,b
        ld (s38_vis_c0),a
        ld a,c
        ld (prev_cy),a
        dec a
        ld (s38_tmp_row),a
s38i_row:
        ld a,(s38_vis_c0)
        ld e,a
s38i_col:
        push de
        ld a,(s38_vis_c0)
        ld c,a
        ld d,0
        ld a,(s38_tmp_row)
        call tile_to_page
        pop de
        inc e
        ld a,(s38_vis_c0)
        add a,16
        cp e
        jr nz,s38i_col
        ld a,(s38_tmp_row)
        inc a
        ld (s38_tmp_row),a
        ld b,a
        ld a,(prev_cy)
        add a,14
        cp b
        jr nz,s38i_row
        jp s38_regs

; Registers in VBLANK: R#23, R#18 (horizontal fine scroll) and R#2 (displayed page).
s38_regs:
        ld hl,(cam_y)
        ld (disp_camy),hl
        ld a,l
        ld b,23
        call wrreg
        ld a,(s38_vis_c0)
        ld (disp_c0),a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ex de,hl
        ld hl,(cam_x)
        or a
        sbc hl,de                   ; f = cam_x - vis_c0*16
        ld a,l
        and 0x0F
        ld (disp_f),a
        ld c,a
        ld a,15
        sub c
        xor 7                       ; R#18 = (15 - f) ^ 7  ->  s = 8 - f
        and 0x0F
        ld b,18
        call wrreg
        ld a,(s38_vis_page)
        ld (disp_page),a
        rrca
        rrca
        rrca
        or 0x1F
        ld b,2
        jp wrreg

s38_update:
        call cam_cells              ; B = cx, C = cy
        ld a,(s38_vis_c0)
        cp b
        jr z,s38_dir
        ld a,(s38_step)
        cp S38_READY
        jr nz,s38_hold
        ld a,(s38_back_c0)
        cp b
        jr nz,s38_hold
        ld a,b                      ; page flip
        ld (s38_vis_c0),a
        ld a,(s38_vis_page)
        xor 1
        ld (s38_vis_page),a
        ld a,0xFF
        ld (s38_back_c0),a
        jr s38_dir
s38_hold:
        ld hl,(stall)
        inc hl
        ld (stall),hl
        ld a,(s38_vis_c0)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        cp b
        jr nc,s38_h_set             ; moved left: hold at vis_c0*16
        ld de,15
        add hl,de                   ; moved right: hold at vis_c0*16+15
s38_h_set:
        ld (cam_x),hl
s38_dir:
        ld a,(s38_hdir)
        or a
        ld a,(s38_vis_c0)
        jr nz,s38_tl
        cp CAM_X_MAX/16
        jr nc,s38_vert              ; already at the right edge: nothing to build
        inc a
        jr s38_tset
s38_tl: or a
        jr z,s38_vert               ; already at the left edge
        dec a
s38_tset:
        ld e,a
        ld a,(s38_back_c0)
        cp e
        jr z,s38_vert
        ld a,e
        ld (s38_back_c0),a
        ld a,(s38_hdir)
        ld (s38_back_dir),a
        xor a
        ld (s38_step),a
s38_vert:
        ld a,(prev_cy)
        cp c
        jr z,s38_work
        jr c,s38_vdown
        ld a,c
        dec a
        jr s38_vq
s38_vdown:
        ld a,c
        add a,13
s38_vq: ld (s38_rq),a
        xor a
        ld (s38_rq_col),a
        ld (s38_rq_pass),a
        ld a,c
        ld (prev_cy),a
s38_work:
        call vdp_busy
        ret nz                      ; a copy strip is still running: do not block the CPU
        ld a,S38_BUDGET
        ld (budget),a
s38_w_rows:                         ; 1) pending row (short tiles, waits between them)
        ld a,(s38_rq)
        cp 0xFF
        jr z,s38_w_build
        ld a,(budget)
        or a
        ret z
        dec a
        ld (budget),a
        call s38_row_step
        jr s38_w_rows
s38_w_build:
        ld a,(s38_back_c0)
        cp 0xFF
        ret z
s38_w_col:                          ; 2) new column of the back page
        ld a,(s38_step)
        cp S38_COLS
        jr nc,s38_w_chunk
        ld a,(budget)
        or a
        ret z
        dec a
        ld (budget),a
        call s38_col_tile
        ld hl,s38_step
        inc (hl)
        jr s38_w_col
s38_w_chunk:                        ; 3) starts one copy strip and returns
        cp S38_READY
        ret nc
        call vdp_wait
        call s38_copy_chunk
        ld hl,s38_step
        inc (hl)
        ret

; End of frame: if the VDP is free, chain the next copy strip.
s38_kick:
        ld a,(s38_back_c0)
        cp 0xFF
        ret z
        ld a,(s38_step)
        cp S38_COLS
        ret c
        cp S38_READY
        ret nc
        call vdp_busy
        ret nz
        call s38_copy_chunk
        ld hl,s38_step
        inc (hl)
        ret

; One tile of the pending row: first on the displayed page (16 columns), then on the back one.
s38_row_step:
        ld a,(s38_rq_pass)
        or a
        jr nz,s38_rs_back
        ld a,(s38_vis_page)
        ld d,a
        ld a,(s38_vis_c0)
        jr s38_rs_go
s38_rs_back:
        ld a,(s38_back_c0)
        cp 0xFF
        jr z,s38_rs_done
        ld a,(s38_vis_page)
        xor 1
        ld d,a
        ld a,(s38_back_c0)
s38_rs_go:
        ld c,a
        ld a,(s38_rq_col)
        add a,c
        ld e,a
        ld a,(s38_rq)
        call tile_to_page
        ld a,(s38_rq_col)
        inc a
        ld (s38_rq_col),a
        cp 16
        ret nz
        xor a
        ld (s38_rq_col),a
        ld a,(s38_rq_pass)
        or a
        jr nz,s38_rs_done
        inc a
        ld (s38_rq_pass),a
        ret
s38_rs_done:
        ld a,0xFF
        ld (s38_rq),a
        ret

; Strip k (= s38_step - S38_COLS, 0..3) of the shifted copy: 240x64 px, displayed -> back.
s38_copy_chunk:
        ld a,(s38_step)
        sub S38_COLS
        rrca
        rrca                        ; k*64 (k = 0..3)
        ld (cmdbuf+2),a
        ld (cmdbuf+6),a
        ld a,(s38_vis_page)
        ld (cmdbuf+3),a
        xor 1
        ld (cmdbuf+7),a
        ld a,(s38_back_dir)
        or a
        jr nz,s38_cc_left
        ld a,16
        ld (cmdbuf+0),a             ; SX = 16 -> DX = 0
        xor a
        ld (cmdbuf+4),a
        jr s38_cc_go
s38_cc_left:
        xor a
        ld (cmdbuf+0),a             ; SX = 0 -> DX = 16
        ld a,16
        ld (cmdbuf+4),a
s38_cc_go:
        xor a
        ld (cmdbuf+1),a
        ld (cmdbuf+5),a
        ld hl,240
        ld (cmdbuf+8),hl
        ld hl,64
        ld (cmdbuf+10),hl
        ld hl,cmdbuf
        jp vdp_cmd

; Tile s38_step (0..14) of the back page's new column (rows cy-1 .. cy+13).
s38_col_tile:
        ld a,(s38_step)
        ld b,a
        ld a,(prev_cy)
        dec a
        add a,b
        push af
        ld a,(s38_back_c0)
        ld c,a
        ld a,(s38_back_dir)
        or a
        ld a,c
        jr nz,s38_ct_go             ; left: new column = back_c0
        add a,15                    ; right: new column = back_c0 + 15
s38_ct_go:
        ld e,a
        ld a,(s38_vis_page)
        xor 1
        ld d,a
        pop af
        jp tile_to_page
