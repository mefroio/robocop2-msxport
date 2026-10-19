; MSX constants and variables (page 3 RAM).
VDP_DATA:   equ 0x98
VDP_CTRL:   equ 0x99
VDP_PAL:    equ 0x9A
VDP_IND:    equ 0x9B
ENASLT:     equ 0x0024
CHGMOD:     equ 0x005F
RSLREG:     equ 0x0138
EXPTBL:     equ 0xFCC1
SLTTBL:     equ 0xFCC5
RG9SAV:     equ 0xFFE8
BANK_8000:  equ 0x9000              ; selects the bank of the 8000h-9FFFh window
BANK_A000:  equ 0xB000              ; selects the bank of the A000h-BFFFh window

SCREEN_LINES: equ 192
CAM_X_MAX:  equ MAP_COLS*16 - 256
CAM_Y_MAX:  equ MAP_ROWS*16 - SCREEN_LINES
TILES_PER_FRAME: equ 6

vdp_id:     equ 0xC000              ; 0 = V9938, 2 = V9958
cam_x:      equ 0xC002
cam_y:      equ 0xC004
prev_cx:    equ 0xC006              ; cam_x >> 4 of the previous frame
prev_cy:    equ 0xC007              ; cam_y >> 4
frame:      equ 0xC008
late:       equ 0xC00A
tiles_drawn: equ 0xC00C
dir_y:      equ 0xC00E
cmdbuf:     equ 0xC010              ; 15 bytes: SX SY DX DY NX NY CLR ARG CMD
q_col:      equ 0xC020              ; pending column (FFh = none)
q_col_row:  equ 0xC021              ; next row to draw in that column
q_col_end:  equ 0xC022
q_row:      equ 0xC023              ; pending row (FFh = none)
q_row_col:  equ 0xC024              ; next column to draw in that row
q_row_end:  equ 0xC025
budget:     equ 0xC026

; --- V9938 (MSX2) engine ---
S38_COLS:   equ 15                  ; tiles of the new column (done before the copy)
S38_CHUNKS: equ 4                   ; 64-line copy strips
S38_READY:  equ S38_COLS + S38_CHUNKS
S38_BUDGET: equ 6                   ; short tiles per frame
s38_vis_page: equ 0xC030            ; displayed page (0/1)
s38_vis_c0: equ 0xC031              ; first world column on the displayed page
s38_back_c0: equ 0xC032             ; first column of the back page (FFh = none)
s38_back_dir: equ 0xC033            ; 0 = built for the right, 1 = for the left
s38_step:   equ 0xC034              ; build progress (0..S38_READY)
s38_hdir:   equ 0xC035              ; current horizontal camera direction
s38_rq:     equ 0xC036              ; pending row (FFh = none)
s38_rq_col: equ 0xC037              ; next column (0..15, relative to the page)
s38_rq_pass: equ 0xC038             ; 0 = displayed page, 1 = back page
s38_tmp_row: equ 0xC039
s38_tmp_x:  equ 0xC03A
disp_c0:    equ 0xC03B              ; state actually displayed (for verification)
disp_f:     equ 0xC03C
disp_page:  equ 0xC03D
disp_camy:  equ 0xC03E              ; 2 bytes
stall:      equ 0xC040              ; frames in which the camera waited for the back page (2 bytes)
