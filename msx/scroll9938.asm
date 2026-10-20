; Scroll on the V9938 (MSX2): two pages aligned to 16 px + set-adjust (R#18) for the fine part.
; - The displayed page holds columns [vis_c0, vis_c0+16) at x = (col - vis_c0)*16 and the
;   kept rows [cy-1, cy+12] at ring lines (row*16) & 255 (R#23 scrolls vertically).
; - R#18 shifts the image (and the sprites) by s = 8 - f px, f = cam_x - vis_c0*16 (0..15);
;   the camera always sits at screen x = 8.
; - The back page is built for vis_c0 +1 (or -1): the new column (one tile per kept row),
;   then a 16 px shifted copy of the 14 row slots from the displayed page, in chunks of up
;   to 4 rows that never cross the ring wrap. When the camera crosses 16 px the pages flip
;   at the next VBLANK; the old page is only reused once the ISR applied the flip. If the
;   back page is not ready, the camera waits at the block edge (counted in 'stall'); a camera
;   several columns away is reached one flip at a time. A row
;   still being drawn when the pages flip starts again on the new displayed page.
; - New rows go to both pages; on the back page only the new column is drawn when the
;   pending copy will still bring the rest of the row.
; - VDP commands never block the CPU: s38_work issues at most one command, only when the
;   VDP is idle, and is also called while the main loop waits for VBLANK.

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
        call tile_src
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
        call wrreg                  ; no V9958 scroll (FORCE_V9938 on an MSX2+)
        ld hl,0                     ; (the camera: set by the game, pl_init)
        ld (frame),hl
        ld (late),hl
        ld (stall),hl
        ld (vstall),hl
        ld (tiles_drawn),hl
        xor a
        ld (s38_vis_page),a
        ld (s38_flip_wait),a
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
        add a,VIEW_ROWS-1
        cp b
        jr nz,s38i_row
        jp s38_publish

; Once per frame: flips, camera holds, build target, row queue, one command, registers.
s38_update:
        ld a,(s38_flip_wait)
        or a
        jr z,s38u_cells
        ld a,(app_seq)
        ld b,a
        ld a,(pub_seq)
        cp b
        jr nz,s38u_cells            ; the flip is not on screen yet
        xor a
        ld (s38_flip_wait),a
s38u_cells:
        call cam_cells              ; B = cx, C = cy
        ld a,(s38_vis_c0)
        cp b
        jr z,s38u_target
        ld e,a                      ; E = the page one column towards the camera (it may be
        inc e                       ; several columns away: one flip at a time)
        jr c,s38u_step
        dec e
        dec e
s38u_step:
        ld a,(s38_flip_wait)
        or a
        jr nz,s38u_hold
        ld a,(s38_back_c0)
        cp e
        jr nz,s38u_hold
        ld a,(s38_phase)
        or a
        jr z,s38u_hold
        ld a,(s38_i)
        cp VIEW_ROWS
        jr nz,s38u_hold
        ld a,e                      ; page flip (shown at the next VBLANK)
        ld (s38_vis_c0),a
        ld a,(s38_vis_page)
        xor 1
        ld (s38_vis_page),a
        ld a,0xFF
        ld (s38_back_c0),a
        ld a,1
        ld (s38_flip_wait),a
        xor a                       ; a pending row restarts on the new displayed page:
        ld (s38_rq_col),a           ; its copy was made before the row, and the columns the
        ld (s38_rq_pass),a          ; row already drew there went to the other page
        ld a,e
        cp b
        jr z,s38u_target            ; (else the camera waits at that page's edge)
s38u_hold:
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
        jr nc,s38u_hset             ; moved left: hold at vis_c0*16
        ld de,15
        add hl,de                   ; moved right: hold at vis_c0*16+15
s38u_hset:
        ld (cam_x),hl
s38u_target:
        ld a,(s38_flip_wait)
        or a
        jr nz,s38u_vert             ; the old page is still on screen
        ld a,(s38_vis_c0)           ; the next page: on the camera's side, or on the camera's
        ld e,a                      ; page the side the view moves to (dir_x)
        cp b
        jr c,s38u_tr
        jr nz,s38u_tl
        ld a,(dir_x)
        or a
        jr nz,s38u_tl
s38u_tr:
        ld a,e
        cp CAM_X_MAX/16
        jr nc,s38u_vert             ; already at the right edge: nothing to build
        inc a
        jr s38u_tset
s38u_tl:
        ld a,e
        or a
        jr z,s38u_vert              ; already at the left edge
        dec a
s38u_tset:
        ld e,a
        ld a,(s38_back_c0)
        cp e
        jr z,s38u_vert
        ld a,e                      ; new build target
        ld (s38_back_c0),a
        ld a,(s38_vis_c0)
        cp e
        ld a,0                      ; built for the right (0) or the left (1)
        jr c,s38u_bd
        inc a
s38u_bd:
        ld (s38_back_dir),a
        xor a
        ld (s38_phase),a
        ld (s38_i),a
        ld a,(prev_cy)
        dec a
        ld (s38_r0),a
s38u_vert:
        ld a,(prev_cy)
        cp c
        jr z,s38u_work
        ld a,(s38_rq)
        cp 0xFF
        jr nz,s38u_vhold
        ld a,(prev_cy)
        cp c
        jr c,s38u_down
        dec a
        ld (prev_cy),a
        dec a                       ; moved up: new row prev_cy-1
        jr s38u_q
s38u_down:
        inc a
        ld (prev_cy),a
        add a,VIEW_ROWS-2           ; moved down: new row prev_cy+12
s38u_q: ld (s38_rq),a
        xor a
        ld (s38_rq_col),a
        ld (s38_rq_pass),a
        ld a,(prev_cy)
        cp c
        jr z,s38u_work
s38u_vhold:
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
        jr nc,s38u_vset             ; moving up: hold at prev_cy*16
        ld de,15
        add hl,de                   ; moving down: hold at prev_cy*16+15
s38u_vset:
        ld (cam_y),hl
s38u_work:
        jp s38_work

; Issues at most one VDP command, only if the VDP is idle.
; Priority: pending row, a cell the game changed, new column of the back page, shifted copy.
s38_work:
        call vdp_busy
        ret nz
        ld a,(s38_rq)
        cp 0xFF
        jp nz,s38_row_step
        call s38_redraw
        ret nz
        ld a,(s38_flip_wait)
        or a
        ret nz
        ld a,(s38_back_c0)
        cp 0xFF
        ret z
        ld a,(s38_phase)
        or a
        jr nz,s38w_copy
        call s38_col_tile
        ld hl,s38_i
        inc (hl)
        ld a,(hl)
        cp VIEW_ROWS
        ret c
        ld (hl),0
        ld a,1
        ld (s38_phase),a
        ret
s38w_copy:
        ld a,(s38_i)
        cp VIEW_ROWS
        ret nc                      ; back page ready
        jp s38_copy_chunk

; One step of the oldest cell the game changed (tiles.asm rd_queue), when it is in the kept
; rows: the displayed page, then the page being built (each draws only the columns it holds).
; NZ when it took this call.
s38_redraw:
        call rd_peek
        ret z
        ld a,(prev_cy)
        dec a
        ld b,a
        ld a,d
        sub b
        cp VIEW_ROWS
        jr nc,s38r_pop
        ld a,(rd_phase)
        or a
        jr nz,s38r_back
        inc a
        ld (rd_phase),a
        ld a,(s38_vis_c0)
        ld c,a
        ld a,(s38_vis_page)
        jr s38r_draw
s38r_back:
        call rd_pop
        ld a,(s38_back_c0)
        cp 0xFF
        jr z,s38r_nz
        ld c,a
        ld a,(s38_vis_page)
        xor 1
s38r_draw:
        ld b,d
        ld d,a
        ld a,b
        call tile_to_page
s38r_nz:
        or 1
        ret
s38r_pop:
        call rd_pop
        or 1
        ret

; One tile of the pending row: first on the displayed page (16 columns), then on the back
; page (all 16 columns, or only the new one when the pending copy brings the others).
s38_row_step:
        ld a,(s38_rq_pass)
        or a
        jr nz,s38rs_back
        ld a,(s38_vis_page)
        ld d,a
        ld a,(s38_vis_c0)
        jr s38rs_go
s38rs_back:
        ld a,(s38_back_c0)
        cp 0xFF
        jr z,s38rs_done
        call s38_covered
        jr nz,s38rs_bgo
        ld a,(s38_back_dir)
        or a
        ld a,15
        jr z,s38rs_nc
        xor a
s38rs_nc:
        ld b,a                      ; new column (page relative)
        ld a,(s38_rq_col)
        cp b
        jr z,s38rs_bgo
        jr nc,s38rs_done            ; past the new column
        ld a,b
        ld (s38_rq_col),a
s38rs_bgo:
        ld a,(s38_vis_page)
        xor 1
        ld d,a
        ld a,(s38_back_c0)
s38rs_go:
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
        jr nz,s38rs_done
        inc a
        ld (s38_rq_pass),a
        ret
s38rs_done:
        ld a,0xFF
        ld (s38_rq),a
        ret

; Z if the build's copy will still bring the slot of the pending row.
s38_covered:
        ld a,(s38_r0)
        ld b,a
        ld a,(s38_rq)
        sub b
        and 15                      ; position of the row's slot in the build
        cp VIEW_ROWS
        jr nc,s38c_no
        ld b,a
        ld a,(s38_phase)
        or a
        jr z,s38c_yes
        ld a,(s38_i)
        ld c,a
        ld a,b
        cp c
        jr c,s38c_no                ; already copied
s38c_yes:
        xor a
        ret
s38c_no:
        or 1
        ret

; New-column tile for slot (r0 + i) & 15, using the kept row that occupies that slot now.
s38_col_tile:
        ld a,(s38_r0)
        ld b,a
        ld a,(s38_i)
        add a,b
        ld b,a                      ; slot (low 4 bits)
        ld a,(prev_cy)
        dec a
        ld c,a                      ; first kept row
        ld a,b
        sub c
        and 15
        cp VIEW_ROWS
        ret nc                      ; free slot: no kept row there
        add a,c
        push af
        ld a,(s38_back_c0)
        ld c,a
        ld a,(s38_back_dir)
        or a
        ld a,c
        jr nz,s38ct_go              ; left: new column = back_c0
        add a,15                    ; right: new column = back_c0 + 15
s38ct_go:
        ld e,a
        ld a,(s38_vis_page)
        xor 1
        ld d,a
        pop af
        jp tile_to_page

; Next chunk of the shifted copy: up to 4 row slots from position s38_i, not crossing the
; ring wrap; 240 px wide, displayed page -> back page.
s38_copy_chunk:
        ld a,(s38_r0)
        ld b,a
        ld a,(s38_i)
        add a,b
        and 15
        ld c,a                      ; first slot
        ld a,16
        sub c                       ; slots before the wrap
        cp 4
        jr c,s38cc_n1
        ld a,4
s38cc_n1:
        ld b,a
        ld a,(s38_i)
        neg
        add a,VIEW_ROWS             ; slots left in the build
        cp b
        jr nc,s38cc_n2
        ld b,a
s38cc_n2:
        ld a,(s38_i)
        add a,b
        ld (s38_i),a
        ld a,c
        add a,a
        add a,a
        add a,a
        add a,a
        ld (cmdbuf+2),a             ; SY low
        ld (cmdbuf+6),a             ; DY low
        ld a,(s38_vis_page)
        ld (cmdbuf+3),a
        xor 1
        ld (cmdbuf+7),a
        ld a,(s38_back_dir)
        or a
        jr nz,s38cc_left
        ld a,16
        ld (cmdbuf+0),a             ; SX = 16 -> DX = 0
        xor a
        ld (cmdbuf+4),a
        jr s38cc_go
s38cc_left:
        xor a
        ld (cmdbuf+0),a             ; SX = 0 -> DX = 16
        ld a,16
        ld (cmdbuf+4),a
s38cc_go:
        xor a
        ld (cmdbuf+1),a
        ld (cmdbuf+5),a
        ld hl,240
        ld (cmdbuf+8),hl
        ld a,b
        add a,a
        add a,a
        add a,a
        add a,a
        ld l,a
        ld h,0
        ld (cmdbuf+10),hl           ; rows * 16 lines
        ld hl,cmdbuf
        jp vdp_cmd

; Registers of the next frame: page, R#18 = ((15 - f) ^ 7) & 15 (s = 8 - f), R#23, R#19.
s38_publish:
        ld a,(s38_vis_c0)
        ld (disp_c0),a
        ld a,(cam_x)
        and 15
        ld (disp_f),a
        ld b,a
        ld a,15
        sub b
        xor 7
        and 15
        ld d,a                      ; R#18
        ld a,(s38_vis_page)
        ld (disp_page),a
        rrca
        rrca
        rrca
        or 0x1F
        ld e,a                      ; R#2
        call next_list
        push hl
        inc hl
        ld (hl),14                  ; 7 registers
        inc hl
        ld (hl),R1_ON
        inc hl
        ld (hl),0x81
        inc hl
        ld (hl),R8_SPR_ON
        inc hl
        ld (hl),0x88
        inc hl
        ld (hl),e
        inc hl
        ld (hl),0x82
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0x92
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
