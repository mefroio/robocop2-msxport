; MSX constants, screen/VRAM layout and RAM variables (page 3).

; --- I/O and BIOS ---
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

; --- screen layout (SCREEN 5, 212 lines) ---
VIEW_LINES: equ 163                 ; play area = display lines 0-162
SPLIT_LINE: equ VIEW_LINES - 4      ; line interrupt at the right border of display line 159
HUD_BLACK:  equ 4                   ; display lines 163-166 blank (the switch happens there)
HUD_LINES:  equ 45                  ; HUD = display lines 167-211 (Amiga panel lines 1-45)
VIEW_ROWS:  equ 14                  ; tile rows kept drawn: [cy-1, cy+12]
CAM_X_MAX:  equ MAP_COLS*16 - 256
CAM_Y_MAX:  equ MAP_ROWS*16 - VIEW_LINES

; --- VDP register values ---
R0_IE1_ON:  equ 0x16                ; SCREEN 5 + line interrupt
R0_IE1_OFF: equ 0x06
R1_ON:      equ 0x62                ; display on, VBLANK interrupt, 16x16 sprites
R1_BLANK:   equ 0x22                ; display off (border colour), VBLANK interrupt
R2_PAGE0:   equ 0x1F
R2_PAGE1:   equ 0x3F
R2_PAGE3:   equ 0x7F
R8_SPR_ON:  equ 0x08                ; VRAM 64K x 4, sprites on
R8_SPR_OFF: equ 0x0A                ; sprites off
R25_PLAY:   equ 0x03                ; V9958: SP2 (512 px ring) + MSK (hides the left 8 px)
R25_HUD:    equ 0x01                ; V9958: SP2 only, the HUD uses all 256 px
R26_PAGE3:  equ 0x20                ; V9958 with SP2: shows page 3 unscrolled

; --- VRAM layout ---
; pages 0-1             play field (V9958: 512x256 ring with SP2; V9938: two 256x256 pages)
; page 2, page 3 0-175  tiles (432 slots)
; page 3 176-191        sprite patterns (64 x 16x16)
; page 3 192-199        sprite set A (colour table, SAT)
; page 3 200-207        sprite set B (colour table, SAT)
; page 3 208-252        HUD (45 lines; the 4 blank lines need no VRAM)
HUD_VRAM_LINE: equ 208
VRAM_HUD:   equ 0x18000 + HUD_VRAM_LINE*128
HUD_R23:    equ (HUD_VRAM_LINE - VIEW_LINES - HUD_BLACK) & 255   ; R#23 that shows it at line 167
SPR_PAT:    equ 0x1D800             ; R#6 = 3Bh
SPR_COL_A:  equ 0x1E000             ; SAT = SPR_COL_A + 200h, R#5 = C7h
SPR_COL_B:  equ 0x1E400             ; SAT = SPR_COL_B + 200h, R#5 = CFh
R5_SET_A:   equ 0xC7
R5_SET_B:   equ 0xCF
R6_PAT:     equ 0x3B
R11_SPR:    equ 3

; --- RAM (page 3) ---
IM2_TABLE:  equ 0xC100              ; 257 bytes, all = IM2_VEC (I = IM2_I)
IM2_I:      equ 0xC1
IM2_VEC:    equ 0xC2
IM2_JUMP:   equ 0xC2C2              ; JP isr

vdp_id:     equ 0xC000              ; 0 = V9938, 2 = V9958
tick:       equ 0xC001              ; VBLANK counter (ISR)
split_armed: equ 0xC002             ; 1 from VBLANK until the HUD split (ISR)
vbl_ptr:    equ 0xC003              ; 2 bytes: list applied at VBLANK [seq, len, value, reg|80h, ...]
pub_seq:    equ 0xC005              ; sequence number of the last published list
app_seq:    equ 0xC006              ; sequence number of the last list applied (ISR)
last_tick:  equ 0xC007              ; tick seen by the main loop
frame:      equ 0xC008              ; 2 bytes
late:       equ 0xC00A              ; 2 bytes: main-loop frames that missed a VBLANK
tiles_drawn: equ 0xC00C             ; 2 bytes
dir_y:      equ 0xC00E              ; demo camera: 0 = up, 1 = down
dir_x:      equ 0xC00F              ; horizontal direction: 0 = right, 1 = left
cmdbuf:     equ 0xC010              ; 15 bytes: SX SY DX DY NX NY CLR ARG CMD
cam_x:      equ 0xC020              ; 2 bytes
cam_y:      equ 0xC022              ; 2 bytes
prev_cx:    equ 0xC024              ; cam_x >> 4 of the previous frame
prev_cy:    equ 0xC025              ; cam_y >> 4 of the previous frame
stall:      equ 0xC026              ; 2 bytes: frames the camera waited (horizontal)
vstall:     equ 0xC028              ; 2 bytes: frames the camera waited (vertical)
spr_set:    equ 0xC02A              ; sprite set shown next (R#5 value)
hud_msk:    equ 0xC02B              ; 1: the split turns the V9958 border mask off for the HUD
update_vec: equ 0xC02C              ; 2 bytes: engine update (once per frame)
idle_vec:   equ 0xC02E              ; 2 bytes: engine work while waiting for VBLANK

; V9958 engine
q_col:      equ 0xC030              ; pending column (FFh = none)
q_col_row:  equ 0xC031              ; next row to draw in that column
q_col_end:  equ 0xC032
q_row:      equ 0xC033              ; pending row (FFh = none)
q_row_col:  equ 0xC034              ; next column to draw in that row
q_row_end:  equ 0xC035

; V9938 engine
s38_vis_page: equ 0xC040            ; displayed page (0/1)
s38_vis_c0: equ 0xC041              ; first world column on the displayed page
s38_back_c0: equ 0xC042             ; first column of the back page (FFh = none)
s38_back_dir: equ 0xC043            ; 0 = built for the right, 1 = for the left
s38_phase:  equ 0xC044              ; 0 = new column tiles, 1 = shifted copy
s38_i:      equ 0xC045              ; progress in the phase (0..VIEW_ROWS)
s38_r0:     equ 0xC046              ; first row of the build (slot order)
s38_flip_wait: equ 0xC047           ; 1 until the ISR applied the flip
s38_rq:     equ 0xC048              ; pending row (FFh = none)
s38_rq_col: equ 0xC049              ; next column (0..15, relative to the page)
s38_rq_pass: equ 0xC04A             ; 0 = displayed page, 1 = back page
s38_tmp_row: equ 0xC04B
s38_tmp_x:  equ 0xC04C
disp_c0:    equ 0xC04D              ; published state (for verification)
disp_f:     equ 0xC04E
disp_page:  equ 0xC04F

; register lists (the ISR applies one per VBLANK; the main loop fills the other)
vbl_list_a: equ 0xC080              ; 32 bytes
vbl_list_b: equ 0xC0A0              ; 32 bytes
split_list: equ 0xC0C0              ; [len, value, reg|80h, ...] for the HUD

; sprites (sprites.asm)
spr_shown:  equ 0xC0E0              ; set (0 = A, 1 = B) whose layout the last published list shows
up_state:   equ 0xC0E1              ; upload of the other set's layout: 0 idle, 1 pages, 2 patterns,
                                    ; 3 colour rows, 4 complete (that set goes on screen next frame)
up_idx:     equ 0xC0E2              ; next object (pages) or SAT entry of the pass
up_units:   equ 0xC0E3              ; work left in this frame
up_next:    equ 0xC0E4              ; slot / entry the VRAM pointer is at (FFh: unknown)
spr_vblank: equ 0xC0E5              ; 1: sat_buf goes to the set on screen after the VBLANK
spr_xadj:   equ 0xC0E6              ; SAT x correction of the frame (V9938: f - 8, V9958: 0)
sat_dirty:  equ 0xC0E7              ; 1: sat_buf must be built again
mux_on:     equ 0xC0E8              ; objects alternating between frames
spr_n:      equ 0xC0E9              ; SAT entries the last sat_buf used
pub_vec:    equ 0xC0EA              ; 2 bytes: engine publish
bu_over:    equ 0xC0EC              ; budget: 1 when lines stay above the limit (BOBs alternate)
bu_need:    equ 0xC0ED              ; budget: most sprites RoboCop may put on a line he shares,
bu_needm:   equ 0xC0EE              ;   the same beside one BOB (alternating)
bu_tot:     equ 0xC0EF              ; budget: sprites of all the objects shown,
bu_one:     equ 0xC0F0              ;   the same with every column on one layer (bu_tot + 1)
lb_n:       equ 0xC0F1              ; layout: entries so far
tmp_k:      equ 0xC0F2              ; column bit / pattern slot
tmp_n:      equ 0xC0F3              ; B sprites
alloc_p:    equ 0xC0F4              ; layout: next pattern slot to try
tmp_o:      equ 0xC0F5              ; budget: object
sb_obj:     equ 0xC0F6              ; SAT build: object
bu_dirty:   equ 0xC078              ; budget: 1 when an object changed what it looks at (shown,
                                    ; composition, screen y) since it last ran
bu_cut:     equ 0xC067              ; budget: 1: objects left out (bg_cut),
bu_ninv:    equ 0xC069              ;   objects that meet,
sb_page:    equ 0xC0FD              ; SAT build: the object's entry page
act_8000:   equ 0xC07C              ; bank the 8000h window shows (bank.asm)
act_a000:   equ 0xC07D              ; bank the A000h window shows
sb_parky:   equ 0xC050              ; SAT build: y of a parked sprite,
sb_xbase:   equ 0xC051              ;   2 bytes: SAT x of dx = 0,
sb_slow:    equ 0xC053              ;   non-zero: some sprite may fall outside 0..255,
sb_dy:      equ 0xC054              ;   line offset that keeps SAT y off 216,
sb_y0:      equ 0xC055              ;   SAT y of dy = 0,
sb_idx:     equ 0xC058              ;   SAT entry,
sb_pub:     equ 0xC059              ;   2 bytes: its pub_cur record,
sb_vis:     equ 0xC05B              ;   0: parked (multiplexing),
sb_de0:     equ 0xC060              ;   2 bytes: the object's first sat_buf entry
sb_ox:      equ 0xC062              ;   2 bytes: the object's x for the composition shown,
sb_oy:      equ 0xC064              ;   2 bytes: its y
lb_i:       equ 0xC05E              ; layout build: object,
up_rec:     equ 0xC05F              ; upload: record of the page being filled,
up_ent:     equ 0xC079              ;   its next entry,
spr_cost:   equ 0xC07A              ; work of the sprite engine and the game logic this frame (units)
st_wait:    equ 0xC07B              ; 1: the last tick's layout waited (a heavy HUD frame)
lb_sp:      equ 0xC074              ;   2 bytes: the object's entry in the layout on screen,
lb_ec:      equ 0xC076              ;   its early clock
sat_buf:    equ 0xC300              ; SAT of the next frame (32 x 4 bytes + 216), 256-aligned
sat_full:   equ 0xC400              ; the same with every object shown (objects alternating)
pub_cur:    equ 0xC500              ; MAX_OBJ x 8 bytes: what the SAT being built shows (pub_spr layout)
pub_spr:    equ 0xC700              ; 2 x MAX_OBJ x 8 bytes: what the SAT of list A (C080) / B (C0A0)
                                    ; shows: per object flags (bit 7 shown, bit 0 BOB), id (2), drop,
                                    ; x (2), y (2)
lay:        equ 0xC800              ; 2 sets x 256 (MAX_OBJ x sprites.asm LAY_SIZE), 256-aligned
lay_col:    equ 0xCA00              ; 2 sets x 32 x 2: colour id | 8000h (EC) each set's row holds
pat_held:   equ 0xCA80              ; 64 x 2: pattern id each pattern slot holds (FFFFh: unknown)
busy:       equ 0xCB00              ; 64: slots the set on screen uses or the new layout took
lay_n:      equ 0xCB40              ; 2 bytes: entries used by each set's layout
lk_cache:   equ 0xCB42              ; LK_CACHE_N x 2: per object-list entry the look last written
LK_CACHE_N: equ 60                  ;   into the map (Amiga address; 0: none) (mapobj.asm)
ao_cand:    equ 0xCBC0              ; up to 61: activate_objects' candidates (entry numbers, FFh
                                    ; after the last; within one 256-byte page)
so_x:       equ 0xF380              ; 2 x 60: the object list's x sorted (page 3's BIOS area: free
so_n:       equ 0xF400              ;   once the BIOS is not used), their entry numbers
obj_tab:    equ 0xCC00              ; MAX_OBJ x 32 bytes (sprites.asm: O_...)
demo_tab:   equ 0xC580              ; demo actors (sprites.asm)
ent_pages:  equ 0x2000              ; (page 0 RAM) MAX_OBJ x 2 pages of 256 bytes: entries
                                    ; (sprites.asm ENT_SIZE)
bu_band:    equ 0xE0A0              ; budget: per band of 8 lines the sprites the objects there can
                                    ; put on a line,
bu_bmax:    equ 0xE0C0              ;   the largest of them (bu_band + 20h, same page)
pat_slot:   equ 0xE100              ; per pattern id the slot it was put in last (FFh: none; a hint:
                                    ; pat_held says what each slot holds)
demo_timer: equ 0xC0D2              ; demo: tick counter of the actors

; HUD (hud.asm). The values use the game's BCD layouts.
hud_timer:  equ 0xC600              ; 2 bytes: minutes, seconds ($804A)
hud_ammo:   equ 0xC602              ; 2 bytes: hundreds in the low nibble, then tens/units ($8030)
hud_score:  equ 0xC604              ; 4 bytes: 7 digits, the first in the low nibble ($8046)
hud_shown:  equ 0xC608              ; 14 bytes: digit shown in each cell
en_target:  equ 0xC616              ; 2 bytes: energy target 0..100h ($169A)
en_shown:   equ 0xC618              ; 2 bytes: energy shown ($169C)
msg_queue:  equ 0xC61A              ; 4 x 2 bytes: message pointers (0 free, 0080h printed) ($FD92)
msg_rd:     equ 0xC622              ; read index (0, 2, 4, 6)
msg_wr:     equ 0xC623              ; write index
msg_col:    equ 0xC624              ; next column ($8058)
msg_count:  equ 0xC625              ; frames before / columns of the erasing (signed) ($805A)
hud_chars:  equ 0xC626              ; 21 bytes: font glyph shown in each text cell
heads_g:    equ 0xC63B              ; 2 bytes: head graphic shown in slot 0, 1
icon_shown: equ 0xC63D              ; weapon icon shown
job_lines:  equ 0xC63E              ; lines left of the running job (0: none)
job_n:      equ 0xC63F              ; its bytes per line
job_src:    equ 0xC640              ; 2 bytes: its next source line (HUD data window)
job_dst:    equ 0xC642              ; 2 bytes: its next VRAM line (low 16 bits)
job_done:   equ 0xC644              ; 2 bytes: what it shows when complete: type, value
jobq_n:     equ 0xC646              ; requests waiting
jobq:       equ 0xC647              ; 4 x 2 bytes: requests (type, value)
td_col:     equ 0xC650              ; text drawing: column,
td_gp:      equ 0xC651              ; 2 bytes: line of the previous cell's glyph,
td_gc:      equ 0xC653              ; 2 bytes: ... of this cell's glyph,
td_gn:      equ 0xC655              ; 2 bytes: ... of the next cell's glyph,
td_vram:    equ 0xC657              ; 2 bytes: VRAM of the first byte,
td_frame:   equ 0xC659              ; 2 bytes: frame pixel of the line,
td_px:      equ 0xC65B              ; 10 bytes: pixels of the line
hd_left:    equ 0xC665              ; digit cells left this frame
lives:      equ 0xC666              ; ($8034)
weapon:     equ 0xC667              ; ($805C)
demo_t:     equ 0xC668              ; 4 bytes: demo countdowns (timer, score, ammo, energy)
demo_w:     equ 0xC66C              ; 3 x 2 bytes: demo countdowns (weapon, message, life)
demo_anim:  equ 0xC672              ; demo: death animation step (0: none)
demo_msg:   equ 0xC673              ; demo: next message
hud_last:   equ 0xC674              ; 8 bytes: the values when every digit cell was last up to date
hud_cost:   equ 0xC67C              ; work the HUD did this frame, in sprite upload units (with
                                    ; spr_cost: the upload takes what is left of UP_TOTAL)

; game logic: the Amiga game's variables, mirrored at their own offsets: $0B00-$16FF -> AM +
; address (D000h-DBFFh), $8000-$80FF -> AG + address (DC00h-DCFFh). The mirror is the Amiga's
; memory with the two bytes of every word swapped: words are little-endian at their own address,
; a long is its two words (the high one first), and the byte the Amiga keeps at A is at A ^ 1
; here (every byte access, the byte equates below include it; tools/tracecmp.py swaps the
; dumps back). AM_START..AM_END is cleared at the start of a level, as clear_game_vars ($FE96)
; clears $B00-$16EB.
AM:         equ 0xD000 - 0x0B00
AG:         equ 0xDC00 - 0x8000
AM_START:   equ AM + 0x0B00
AM_END:     equ AM + 0x16EC
g_frame:    equ AM + 0x0B00         ; 2: game frames
g_snd:      equ AM + 0x0B2C         ; 6: sound requests ($B2C-$B31: request i at g_snd + (i ^ 1))
gcam_x:     equ AM + 0x0B04         ; 2: the game's camera
gcam_y:     equ AM + 0x0B06         ; 2
gcam_ymax:  equ AM + 0x0B08         ; 2: its lowest y
lifts:      equ AM + 0x0B3C         ; 40: 4 lifts x left, right, top, dx, flag index ($B3C-$B63)
p_hotx:     equ AM + 0x15CC         ; 2: hotspot + 8
p_hoty:     equ AM + 0x15CE         ; 2
p_started:  equ AM + (0x15CA ^ 1)   ; start-of-level sequence done
p_startn:   equ AM + (0x15CB ^ 1)   ; its step
p_x:        equ AM + 0x15D0         ; 2
p_y:        equ AM + 0x15D4         ; 2
p_aim:      equ AM + 0x15DA         ; 2
p_anim:     equ AM + 0x15DC         ; 2: animation step
p_de:       equ AM + 0x15DE         ; 2 (the state table's byte 1 goes into its low byte, $15DF)
p_vy:       equ AM + 0x15E0         ; 2
p_state:    equ AM + 0x15E2         ; 2
p_rev:      equ AM + (0x15E4 ^ 1)   ; animation backwards
p_air:      equ AM + (0x15E6 ^ 1)   ; airborne
p_last:     equ AM + 0x15E8         ; 2: the state's last animation step
p_floor:    equ AM + 0x1674         ; 2: floor attributes & 5 (the Amiga tests bit 2 of $1675)
p_arm:      equ AM + 0x1676         ; 2: special arm pose
p_jwait:    equ AM + (0x1678 ^ 1)   ; frames before jumping again
p_aimw:     equ AM + (0x1679 ^ 1)   ; frames before the aim changes
p_onlift:   equ AM + 0x167A         ; 4: on lift n (at p_onlift + (n ^ 1))
p_hb:       equ AM + 0x168E         ; 2: hitbox (offset in pl_hitbox here; a pointer on the Amiga)
p_pend:     equ AM + 0x1696         ; 2: state asked for the next frame (high byte FFh: none)
p_conf:     equ AM + 0x1698         ; 2: frames of reversed controls
p_fade:     equ AM + (0x16CD ^ 1)   ; palette fade level
p_fadein:   equ AM + (0x16CE ^ 1)   ; non-zero: fading in, else out
g_keys:     equ AG + (0x802D ^ 1)   ; keyboard byte: the joystick's bits, bit 7 once a key was used
g_joy:      equ AG + (0x802E ^ 1)   ; joystick byte: up 1, down 2, left 4, right 8, fire 10h
g_lock:     equ AG + (0x804D ^ 1)   ; non-zero: the joystick byte is not read
g_key:      equ AG + (0x8032 ^ 1)   ; last key code (bit 7: released), the keyboard interrupt's
g_keydone:  equ AG + (0x8033 ^ 1)   ; the last one frame_keys handled
g_paused:   equ AG + (0x804E ^ 1)   ; non-zero: paused
snd_b2c:    equ AM + (0x0B2C ^ 1)   ; sound request bytes $B2C-$B31
snd_b2d:    equ AM + (0x0B2D ^ 1)
snd_b2e:    equ AM + (0x0B2E ^ 1)
snd_b2f:    equ AM + (0x0B2F ^ 1)
snd_b30:    equ AM + (0x0B30 ^ 1)
snd_b31:    equ AM + (0x0B31 ^ 1)

; game logic: the port's own variables
G_VARS:     equ 0xCE00
lvl_bank:   equ 0xCE09              ; the level's logic bank (logic_map maps it at A000h)
uo_d0:      equ 0xCE0A              ; update_objects' registers: D0 (2),
uo_d1:      equ 0xCE0C              ;   D1 (2),
uo_d2:      equ 0xCE0E              ;   D2 (2),
uo_d3:      equ 0xCE10              ;   D3 (2),
uo_d4:      equ 0xCE12              ;   D4 (2)
key_p:      equ 0xCE14              ; key_scan: P as last seen
pause_n:    equ 0xCE15              ; ticks before "PAUSE ON." again
dbg_msg:    equ 0xCE18              ; 20: the message "NUKE nn HOST nn" ($F841, written by $F788)
g_tick:     equ 0xCE05              ; 1 on the frames the game ticks
g_acc:      equ 0xCE06              ; cadence: + g_step per frame, the game ticks at CAD_TICK (10)
g_step:     equ 0xCE07              ; 6 at 50 Hz, 5 at 60 Hz (30 ticks per second)
g_after:    equ 0xCE08              ; 1 on the first frame after a tick (sprite layout)
p_row:      equ 0xCE34              ; map row and column of the frame's start position
p_col:      equ 0xCE35
p_rec:      equ 0xCE36              ; frame record shown
v_x:        equ 0xCE6A              ; 2: the view the game asks the scroll engine for
v_y:        equ 0xCE6C              ; 2
pm_d0:      equ 0xCE70              ; player_move's registers: D0 (joystick bits),
pm_d1:      equ 0xCE71              ;   D1 (state at the frame's start),
pm_d2:      equ 0xCE72              ;   D2 (new state, FFh: none),
pm_d4:      equ 0xCE73              ;   D4 (x step),
pm_d5:      equ 0xCE74              ;   D5 (state & 7Eh)
G_VARS_END: equ 0xCE80
; BOBs of the game's tick (bob.asm): the call's arguments (bob_a2..bob_y contiguous, as a record)
bob_a2:     equ 0xCE80              ; 3: A2, the graphics (low byte first)
bob_d4:     equ 0xCE83              ; 2: D4, BLTSIZE
bob_x:      equ 0xCE85              ; 2: D0, x (world)
bob_y:      equ 0xCE87              ; 2: D1, y (world)
bob_mode:   equ 0xCE89              ; BM_NORMAL / BM_FLASH / BM_BLACK
bob_n:      equ 0xCE8A              ; BOBs recorded this tick
bob_ptr:    equ 0xCE8B              ; 2: next record
bd_d0:      equ 0xCE8D              ; 2: draw_bob's D0 (x - camera x),
bd_d1:      equ 0xCE8F              ; 2:   D1,
bd_d4:      equ 0xCE91              ; 2:   D4 (cut),
bd_wb:      equ 0xCE93              ; 2:   bytes per line,
bd_dmod:    equ 0xCE95              ; 2:   destination modulo
bob_cat:    equ 0xCE97              ; the category of the BOBs drawn now (bob.asm BC_...)
bf_obj:     equ 0xCE98              ; bob_flush: the next sprite object,
bf_catn:    equ 0xCE99              ;   the category being placed
bob_list:   equ 0xF100              ; BOB_MAX x BOB_REC (F100h-F27Bh; the stack below F380h)
; activate_objects (objects.asm)
ao_a4:      equ 0xCEA0              ; 2: A4, the next collision slot (MSX address in AM)
ao_a1:      equ 0xCEA2              ; 2: the entry's Amiga address
ao_x:       equ 0xCEA4              ; 2: D0
ao_y:       equ 0xCEA6              ; 2: D1
ao_row:     equ 0xCEA8              ; the entry's map cell: row,
ao_col:     equ 0xCEA9              ;   column (-8..167)
ao_dir:     equ 0xCEAA              ; conveyor: -2 / 2
ea_k:       equ 0xCEAB              ; explosion / pickup slot
ao_len:     equ 0xCEAC              ; 2: conveyor length (D7)
ao_tmp:     equ 0xCEAE              ; 2
ea_x:       equ 0xCEB0              ; 2
ea_y:       equ 0xCEB2              ; 2
ao_lkc:     equ 0xCECC              ; 2: activate_objects: the entry's lk_cache word
ao_cnd:     equ 0xCECE              ; 2: the next candidate (ao_cand)
ao_xlo:     equ 0xCED0              ; 2: the window's x range
ao_xhi:     equ 0xCED2              ; 2
ao_lo:      equ 0xCED4              ; its range in so_x
ao_hi:      equ 0xCED5
ao_cnt:     equ 0xCED6              ; entries in so_x
; enemy bullets ($F5BC, objects.asm ebullet_add)
eb_x:       equ 0xCEB4              ; 2: D0
eb_y:       equ 0xCEB6              ; 2: D1
eb_type:    equ 0xCEB8              ; D6
eb_dir:     equ 0xCEB9              ; D7 (bit 7: aimed)
eb_tx:      equ 0xCEBA              ; 2: the target (D4's high word)
eb_ty:      equ 0xCEBC              ; 2: (D6's high word)
eb_slot:    equ 0xCEBE              ; 2: A0 of the bullet started
eb_vxf:     equ 0xCEC0              ; 2: speed fractions
eb_vyf:     equ 0xCEC2              ; 2
t_save:     equ 0xCEC4              ; 2: handlers' scratch (D3, D7...)
t_d2:       equ 0xCECA              ; walkers: D2
eb_k:       equ 0xCECB              ; enemy bullets: slot
t_x:        equ 0xCEC6              ; 2
t_y:        equ 0xCEC8              ; 2

; game logic: the Amiga game's variables that live inside its code area (tools/amigacov.py lists
; what the game writes there): patched immediates and pointers, kept here (pointers as MSX
; addresses into the copies of the tables)
AC_VARS:    equ 0xDD00
ac_camdx:   equ 0xDD00              ; 2: the camera's x offset from RoboCop ($B2D8: 108h, 80h at the
                                    ;   level's end, obj32)
ac_camdy:   equ 0xDD02              ; 2: its y offset ($B2FC: -70h, -30h)
ac_mkmask:  equ 0xDD05              ; map markers spawn when (game frame & this, sign-extended) = 0
                                    ;   ($C53D)
ac_mkstep:  equ 0xDD06              ; 2: the marker scan's step 0-19 ($C44A)
ac_mkptr:   equ 0xDD08              ; 2: the marker table's entry used last ($C598)
ac_mktab:   equ 0xDD0A              ; 2: the level's marker table ($C692)
ac_diff:    equ 0xDD0C              ; 2: hit points per index for the difficulty ($8060)
ac_objlA:   equ 0xDD0E              ; 2: the level's object list's Amiga address ($9C18)
ac_flash:   equ 0xDD10              ; 2: palette flash countdown ($F826)
ac_flpal:   equ 0xDD13              ; the flash's palette (PAL_..., objects.asm)
ac_ediv:    equ 0xDD15              ; explosions: frame divider ($F07E, a byte: kept at A ^ 1)
AC_VARS_END: equ 0xDD80
spawn_ram:  equ 0xDD80              ; DD80h-DFFFh: the level's spawn list ($B0E; 14-byte records,
                                    ; words little-endian), copied from the level bank at its start
objl_ram:   equ 0xEE00              ; EE00h-F0FFh: the level's object list ($9C18; 12-byte records)
; (E100h-EDFFh: pat_slot; F100h-F27Fh: bob_list; F280h-F37Fh: the stack)

; --- page 0 RAM (0000h-3FFFh: the main RAM once the BIOS is no longer needed, tiles.asm ram_page0)
TC_SLOT:    equ 0x0000              ; 512 x 2: slot + 1 holding each tile (0: not in VRAM)
TC_TILE:    equ 0x0400              ; 432 x 2: tile in each slot (FFFFh: none)
TC_REF:     equ 0x0760              ; 432: slot used since the clock hand last passed
MP_ROW:     equ 0x0A00              ; 256: first patch of each map row (FFh: none)
MP_COL:     equ 0x0B00              ; 256: per patch its column,
MP_TILEL:   equ 0x0C00              ;   tile (low byte,
MP_TILEH:   equ 0x0D00              ;   high byte),
MP_ATR:     equ 0x0E00              ;   attributes,
MP_NEXT:    equ 0x0F00              ;   next patch of the row (FFh: none)
RD_Q:       equ 0x1000              ; RD_Q_SIZE x (row, column): cells to redraw
RD_Q_SIZE:  equ 64
tc_hand:    equ 0x1080              ; 2: the tile cache's clock hand
mp_free:    equ 0x1082              ; first free patch (FFh: none)
mp_used:    equ 0x1083              ; patches in use
mp_lost:    equ 0x1084              ; map writes lost (table full)
rd_head:    equ 0x1085              ; redraw queue: oldest request,
rd_tail:    equ 0x1086              ;   next free entry,
rd_phase:   equ 0x1087              ;   1: the oldest was drawn on the displayed page (V9938),
rd_lost:    equ 0x1088              ;   requests lost (queue full)
tc_loads:   equ 0x1089              ; tiles copied into VRAM on demand (statistics)
ATR_RAM0:   equ 0x108C              ; the packed map attributes (tiles.asm atr_load): rows 0-47,
ATR_RAM1:   equ 0x0910              ;   rows 48-50 (after TC_REF)
atr_lut:    equ 0x1F8C              ; 16: the attribute value of each code of the packed map
mw_atr:     equ 0x108A              ; map_write's attributes
mw_idx:     equ 0x108B              ; map_write's new patch
