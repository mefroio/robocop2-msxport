; MSX constants, screen/VRAM layout and RAM variables (page 3).

; --- I/O and BIOS ---
VDP_DATA:   equ 0x98
VDP_CTRL:   equ 0x99
VDP_PAL:    equ 0x9A
VDP_IND:    equ 0x9B
RDSLT:      equ 0x000C
WRSLT:      equ 0x0014
ENASLT:     equ 0x0024
CHGMOD:     equ 0x005F
RSLREG:     equ 0x0138
INITXT:     equ 0x006C
CHPUT:      equ 0x00A2
MSXVER:     equ 0x002D              ; the BIOS's MSX version: 0 MSX1, 1 MSX2, 2 MSX2+, 3 turbo R
MODE:       equ 0xFAFC              ; bits 1-2: the VRAM (0 16 KiB, 1 64 KiB, 2 128 KiB)
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
SPLIT_R19:  equ (HUD_R23 + SPLIT_LINE) & 255    ; R#19 after the split: its match is behind (isr.asm)
SPLIT_R19_ON: equ (HUD_R23 + VIEW_LINES + 2) & 255  ; R#19 during the split: a match at the right
                                    ;   border of display line V+2 times the display-on (isr.asm)
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
; the title music on the SCC / OPLL (music.asm), in the gap of IM2_TABLE..IM2_JUMP (C201h-C2C1h)
mus_mode:   equ 0xC201              ; what plays it (MM_SCC, MM_FM, MM_RHY; 0: the PSG player)
mus_on:     equ 0xC202              ; 1 while it plays (the VBLANK interrupt ticks it)
mus_div:    equ 0xC203              ; VBLANKs into the sixth one (60 Hz: skipped)
mus_speak:  equ 0xC204              ; 1: the tick of RoboCop's speech came (front_fire plays it)
mus_tick:   equ 0xC205              ; 2: the tune's tick (0 at its loop's start)
vm_bank:    equ 0xC207              ; vm_play: the bank of the speech's samples at 8000h
vm_hit:     equ 0xC208              ; vm_play: 1 when fire ended the speech
mus_dc:     equ 0xC209              ; 1: PSG voices A and B hold the speech PCM's middle level (music.asm)
scc_pg2:    equ 0xC20A              ; the SCC's slot in A8h's bits 4-5 when another cartridge has it (0: ours; sound.asm)
scc_a8:     equ 0xC20B              ; A8h while page 2 shows that SCC (sound.asm scc_open)
fx_tmp:     equ 0xC20C              ; music.asm fx_start: the PSG voice of the effect's noise part
fx_act:     equ 0xC20D              ; music.asm: 1 while an effect plays on the SCC engine (sndplay.asm ticks it)
fx_son:     equ 0xC20E              ; music.asm: 1 once the SCC's channels 0-3 are on for the effects
scp_mask:   equ 0xC20F              ; sound.asm scc_pat: the test values read back so far (a bit each)
fx_wc:      equ 0xC2A0              ; 4: music.asm fx_osc: the effect waveform each SCC channel 0-3 holds (FFh: none)
scp_need:   equ 0xC2A4              ; sound.asm scc_pat: the test values that must be read back
scp_try:    equ 0xC2A5              ;   and the tries left
scc_wb:     equ 0xC250              ; 32: a waveform on its way to the SCC (music.asm mo_scc)
fx_pv:      equ 0xC270              ; 3 x MV_SIZE (16): the effects' PSG voices with an SCC (music.asm fx_start)
mus_v:      equ 0xC210              ; 4 x MV_SIZE (16): the voices (3 melodic, the drums)

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
s38_old_c0: equ 0xC069              ; the first column of the page on screen until a flip is
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
s38_flip_seq: equ 0xCA7B            ; seq of the list that shows the last flip (s38_work: its page is free once shown)
cam_held:   equ 0xF16F              ; 1: the last update kept the camera at a page's edge (cadence: CAD_HOLD)
disp_c0:    equ 0xC04D              ; published state (for verification)
disp_f:     equ 0xC04E
disp_page:  equ 0xC04F

; register lists (the ISR applies one per VBLANK; the main loop fills the other)
vbl_list_a: equ 0xC080              ; 32 bytes
vbl_list_b: equ 0xC0A0              ; 32 bytes
split_list: equ 0xC0C0              ; [len, value, reg|80h, ...] for the HUD

; sprites (sprites.asm)
pk_state:   equ 0xC0E0              ; published frame: 0 on screen, 1 its queue to run (split
                                    ; interrupt: sprites.asm spr_upload), 2 ready for the VBLANK
pk_list:    equ 0xC0E1              ; 2: its register list (vbl_ptr once on screen)
pk_mux:     equ 0xC0E3              ; always 0 (objects alternating between frames: the code went
                                    ; on 2026-10-23; the Tcl checks still read it)
spr_vblank: equ 0xC0E5              ; 1: the frame being published has a new SAT (sat_nb)
spr_xadj:   equ 0xC0E6              ; SAT x correction of the frame (V9938: f - 8, V9958: 0)
sat_dirty:  equ 0xC0E7              ; 1: sat_buf must be built again
spr_n:      equ 0xC0E9              ; SAT entries the last sat_buf used
pub_vec:    equ 0xC0EA              ; 2 bytes: engine publish
bu_tot:     equ 0xC0EF              ; budget: sprites of all the objects shown,
bu_one:     equ 0xC0F0              ;   the same with every OR layer dropped (bu_tot + 1)
lb_n:       equ 0xC0F1              ; layout: entries so far
alloc_p:    equ 0xC0F4              ; layout: next pattern slot to try
tmp_o:      equ 0xC0F5              ; budget: object
sb_obj:     equ 0xC0F6              ; SAT build: object
bu_dirty:   equ 0xC078              ; budget: 1 when an object changed what it looks at (shown,
                                    ; composition, screen y) since it last ran
bu_cut:     equ 0xC067              ; budget: 1: objects left out (bg_cut),
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
sat_pair0:  equ 0xC300              ; two pairs of SAT buffers (32 x 4 bytes, and + 80h the other
sat_pair1:  equ 0xC400              ;   frames' with objects alternating), 256-aligned: the frame on
                                    ;   screen uses one (sat_cur), the one being built the other
pub_cur:    equ 0xC500              ; MAX_OBJ x 8 bytes: what the SAT being built shows (pub_spr layout)
pub_spr:    equ 0xC700              ; 2 x MAX_OBJ x 8 bytes: what the SAT of list A (C080) / B (C0A0)
                                    ; shows: per object flags (bit 7 shown, bit 0 BOB), id (2), drop,
                                    ; x (2), y (2)
disp:       equ 0xC800              ; MAX_OBJ x LAY_SIZE: the version each object shows (sprites.asm
                                    ; V_...), 256-aligned
pend:       equ 0xC900              ; MAX_OBJ x LAY_SIZE: the version it prepares (disp + 256)
col_held:   equ 0xCA00              ; 32 x 2: colour id | 8000h (EC) each SAT entry's row holds (set A;
                                    ; set B: col_held_b)
ent_own:    equ 0xCA40              ; 32: object whose run holds each SAT entry (FFh: free)
pl_obj:     equ 0xCA60              ; plan: the object,
pl_wait:    equ 0xCA61              ;   1: some of its patterns are on their way,
pc_start:   equ 0xCA62              ;   its new run's first entry,
up_window:  equ 0xCA63              ; 2: upload units of one blank time (60 or 50 Hz)
pq_left:    equ 0xCA65              ; 2: units the frame's queue may still take,
pq_wr:      equ 0xCA67              ; 2:   its next entry
su_left:    equ 0xCA69              ; 2: spr_upload: units this blank time has left
bq_head:    equ 0xCA6B              ; background queue: next entry to load (interrupt),
bq_tail:    equ 0xCA6C              ;   next free one (main program); low bytes in bq_buf
fl_n:       equ 0xCA6D              ; low byte of the last slot released for later (SLOT_PG)
sat_cur:    equ 0xCA6E              ; 2: the SAT pair of the frame on screen,
sat_nb:     equ 0xCA70              ; 2:   of the frame being built
pl_pq:      equ 0xCA72              ; plan: 1 when the object's patterns may take the frame's queue,
pl_pass:    equ 0xCA73              ;   0: the objects showing nothing yet, 1: the others,
pl_rcz:     equ 0xCA74              ;   low byte of ent_own past RoboCop's zone (no BOB run there)
pr_bsz:     equ 0xCA75              ; pc_run: the best hole's size (FFh: none),
pr_bst:     equ 0xCA76              ;   the run's first SAT entry there
pl_pa:      equ 0xCA77              ; 2: plan: the next free place of the first work list,
pl_pb:      equ 0xCA79              ; 2:   of the second
pl_wa:      equ 0xED10              ; 17: plan: objects that show nothing yet, FFh at the end
pl_wb:      equ 0xED21              ; 17:   the other objects to bring on
bu_ord:     equ 0xED32              ; 15: budget: the BOB objects by importance, FFh at the end
pl_st:      equ 0xED42              ; 16: plan: per object 1 or 2 when it goes into that work list
bo_pos:     equ 0xED52              ; 6: bu_order: per rank its count, then its next place
pat_held:   equ 0xCA80              ; 64 x 2: pattern id each pattern slot holds, or will once its
                                    ; upload runs (FFFFh: unknown)
slot_ref:   equ 0xCB00              ; 64: entries of shown or prepared versions using each slot
lk_cache:   equ 0xCB42              ; LK_CACHE_N x 2: per object-list entry the look last written
LK_CACHE_N: equ 60                  ;   into the map (Amiga address; 0: none) (mapobj.asm)
ao_cand:    equ 0xCBC0              ; up to 61: activate_objects' candidates (entry numbers, FFh
                                    ; after the last; within one 256-byte page)
so_x:       equ 0xF380              ; 2 x 60: the object list's x sorted (page 3's BIOS area: free
so_n:       equ 0xF400              ;   once the BIOS is not used), their entry numbers
obj_tab:    equ 0xCC00              ; MAX_OBJ x 32 bytes (sprites.asm: O_...; 256-byte aligned)
demo_tab:   equ 0xC580              ; demo actors (sprites.asm)
ent_pages:  equ 0x2000              ; (page 0 RAM) MAX_OBJ x 2 pages of 256 bytes: entries
                                    ; (sprites.asm ENT_SIZE)
ln_cnt:     equ 0xE000              ; budget: VIEW_LINES (E000h-E0A2h, 256-byte aligned): the sprites
                                    ;   on each line of the play area (E0A3h-E0FFh: free)
pat_slot:   equ 0xE100              ; 1024 (256-aligned): per pattern id & 3FFh the slot it was put in
                                    ; last (FFh: none; a hint: pat_held says what each slot holds)
pg_list:    equ 0xE500              ; 16: plan: the BOB objects whose category can have parts, FFh
                                    ;   after the last (sprites.asm pg_build, pg_each)
pg_ptr:     equ 0xE510              ;   pg_each's place in it
pg_new:     equ 0xE511              ;   1: an identity changed since the list was built
ft_tl:      equ 0xE520              ; 3 x 17: budget, the give-way's live objects of tiers 0-2 in
                                    ;   object order (ft_drop_t), FFh after the last (ft_lists)
ft_tb:      equ 0xE560              ; 3 x 17:   the same in the order of importance (bu_ord: ft_leave_t)
ft_wp:      equ 0xE5A0              ; 3: ft_lists: each list's next place (low bytes)
ft_lok:     equ 0xE5A3              ; 1 once ft_lists ran in this budget run
                                    ; (E5A4h-E5FFh: free, the old background upload ring's)
pq_buf:     equ 0xE600              ; [type, slot / SAT entry, id (2)] ... 0: the published frame's
                                    ; uploads (sprites.asm Q_...)
SLOT_PG:    equ 0xE7                ; page of four 64-byte tables per slot:
SO_OK:      equ 0x00                ;   1: its pattern is in VRAM (or in the frame's queue),
SO_Q:       equ 0x40                ;   1: in the background queue,
SO_GEN:     equ 0x80                ;   generation (each new pattern),
SO_FL:      equ 0xC0                ;   (the slots released when the planned frame is on screen)
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
fire_latch: equ AM + (0x0D78 ^ 1)   ; fire held (cleared every 4 frames with weapon 1)
w3_alt:     equ AM + (0x16D6 ^ 1)   ; weapon 3: wide or narrow spread next
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
uo_d0:      equ 0xCE0A              ; update_objects' registers: D0 (2),
uo_d1:      equ 0xCE0C              ;   D1 (2),
uo_d2:      equ 0xCE0E              ;   D2 (2),
uo_d3:      equ 0xCE10              ;   D3 (2),
uo_d4:      equ 0xCE12              ;   D4 (2)
key_p:      equ 0xCE14              ; key_scan: P as last seen
pause_n:    equ 0xCE15              ; ticks before "PAUSE ON." again
uo_capd:    equ 0xCE16              ; ENEMY_CAP: not 0 while the enemies in use reach it (objects.asm uo_cap)
dbg_msg:    equ 0xCE18              ; 20: the message "NUKE nn HOST nn" ($F841, written by $F788)
g_tick:     equ 0xCE05              ; 1 on the frames the game ticks
g_acc:      equ 0xCE06              ; cadence: + g_step per frame, the game ticks at CAD_TICK
g_step:     equ 0xCE07              ; 6 at 50 Hz, 5 at 60 Hz (300 a second: TICK_HZ ticks)
p_row:      equ 0xCE34              ; map row and column of the frame's start position
p_col:      equ 0xCE35
p_rec:      equ 0xCE36              ; frame record shown
pf_x:       equ 0xCE38              ; 2: update_player's fire and the shots: D0 (x),
pf_y:       equ 0xCE3A              ; 2:   D1 (y),
pf_dx:      equ 0xCE3C              ; 2:   D2 (the shot's x step),
pf_d7:      equ 0xCE3E              ;   D7 (direction)
sp_d7:      equ 0xCE3F              ; D7 as the special objects ($8B32) leave it for update_player
ht_n:       equ 0xCE40              ; hit_test: the boxes in ht_box,
ht_ok:      equ 0xCE41              ;   1 once they are worked out this tick (CE42h-CE43h: free)
ph_x0:      equ 0xCE44              ; 2: $FA7C: RoboCop's box: D0 (left),
ph_y0:      equ 0xCE46              ; 2:   D1 (top),
ph_x1:      equ 0xCE48              ; 2:   D4 (right, exclusive),
ph_y1:      equ 0xCE4A              ; 2:   D5 (bottom, exclusive)
ph_dmg:     equ 0xCE4C              ; a bullet's damage; a pickup's type (/ 4 in pl_hits)
sp_flag:    equ 0xCE4E              ; 2: $8B32: the record's flag byte (A4, an MSX address),
sp_x:       equ 0xCE50              ; 2:   D0 (x),
sp_y:       equ 0xCE52              ; 2:   D1 (y),
sp_atpt:    equ 0xCE54              ;   a lift at its path point (D4)
sc_run:     equ 0xCE56              ; 2: test builds' joystick script: the run of sc_start,
sc_start:   equ 0xCE58              ; 2:   its first game frame
ext_joy:    equ 0xCE5A              ; EXTJOY test builds: the joystick byte the Tcl driver puts here
h_row:      equ 0xCE5B              ; handlers' map cell: row,
h_col:      equ 0xCE5C              ;   column (-8..167)
v_x:        equ 0xCE6A              ; 2: the view the game asks the scroll engine for
v_y:        equ 0xCE6C              ; 2
pm_d0:      equ 0xCE70              ; player_move's registers: D0 (joystick bits),
pm_d1:      equ 0xCE71              ;   D1 (state at the frame's start),
pm_d2:      equ 0xCE72              ;   D2 (new state, FFh: none),
pm_d4:      equ 0xCE73              ;   D4 (x step),
pm_d5:      equ 0xCE74              ;   D5 (state & 7Eh)
spk_k:      equ 0xCE75              ; the hit spark this tick: its frame + 1 (0: none; pl_frame)
ps_x:       equ 0xCE76              ; 2: pl_show: RoboCop's composition on screen, x,
ps_y:       equ 0xCE78              ; 2:   y
wf_n:       equ 0xCE7A              ; VBLANKs since the last wait_frame (more than 1: a late frame)
g_tn:       equ 0xCE7B              ; game ticks still to run in this main-loop frame
up_lmode:   equ 0xCE7D              ; non-zero: this frame's upload runs late (sprites.asm up_step)
front_mode: equ 0xEC44              ; 1: the front end shows a picture (the VBLANK interrupt only
                                    ;   counts frames and runs the sound)
ps_bank:    equ 0xEC45              ; front.asm pic_show: the picture's bank,
ps_lines:   equ 0xEC46              ;   its lines
os_mode:    equ 0xEC47              ; obj_set: the silhouette asked for (0, BM_FLASH, BM_BLACK)
lb_mode:    equ 0xEC48              ; lb_fill: the entry's silhouette
spl_bas:    equ 0xEC4E              ; 2: sp_lift: the record's first path point
fl_pend:    equ 0xEC49              ; 5: per enemy slot, a hit flash drawn in a tick the display
                                    ;   skipped, shown with the next tick shown (bob.asm)
snd_fm:     equ 0xEC42              ; 1: an OPLL was found (sound.asm snd_detect)
snd_slot:   equ 0xEC43              ;   the slot searched / found
vram_busy:  equ 0xEC50              ; 1 while the main program streams to VRAM (vram_write ...
                                    ;   vram_done): the VBLANK interrupt leaves the SAT to vram_done
sat_due:    equ 0xEC51              ; always 0 (the alternation's SAT write waiting for vram_done
                                    ;   went on 2026-10-23; the Tcl checks still read it)
sat_vaddr:  equ 0xEC52              ; 2: that SAT's address as port 99h writes it (low, high | 40h;
                                    ;   R#14 = 7)
sat_len:    equ 0xEC54              ; bytes of sat_buf it takes
bob_own:    equ 0xEC56              ; 2: the owner of the BOBs drawn now (each system's object or
                                    ;   slot, set by its loop): with their order, their identity
                                    ;   from tick to tick (bob.asm)
bob_lown:   equ 0xEC58              ; 2: the owner of the last BOB recorded,
bob_pno:    equ 0xEC5A              ;   its part number (0, 1... for the BOBs of one owner in order)
bf_hint:    equ 0xEC5B              ; bob_flush: where the next identity is looked for first,
bf_nnew:    equ 0xEC5C              ;   records still without an object,
bf_new:     equ 0xEC5D              ;   2 x BOB_MAX: those records (EC5Dh-EC98h)
obj_key:    equ 0xECA0              ; MAX_OBJ x 4: each BOB object's identity: part, owner (2),
                                    ;   category + 1 (0: none) (bob.asm bob_flush)
bf_claim:   equ 0xECE0              ; MAX_OBJ: 1 for the objects bob_flush gave a record this tick
bf_htab:    equ 0xE800              ; 256: per hash of an identity the object it was given last
bf_unm:     equ 0xED58              ; bob_flush: objects with an identity no record took yet
bf_lp:      equ 0xED59              ; 2: bf_show: the object's bf_last record
bf_last:    equ 0xED60              ; MAX_OBJ x 6: per object the A2, D4 and mode of its last frame
bob_skip:   equ 0xCE7C              ; non-zero: the tick's BOBs are not recorded (a tick run in a row
                                    ; before the frame's last one: only the last one is shown)
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
bob_list:   equ 0xEA60              ; BOB_MAX x BOB_REC (EA60h-EC21h)
cat_head:   equ 0xEC30              ; 2 x BOB_CATS: each category's last record (0: none; bob.asm)
hz_ylo:     equ 0xEC3C              ; 2: hz_update's window: camera y - 64h,
hz_xlo:     equ 0xEC3E              ; 2:   camera x + 73h,
hz_xhi:     equ 0xEC40              ; 2:   camera x + 1A0h
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
ao_curn:    equ 0xCED7              ; the entry being activated
jump_pend:  equ 0xCED8              ; non-zero: the cracked wall moved RoboCop and the camera (act_10):
                                    ;   the scroll engine draws the new view (field.asm engines_jump)
tick_n:     equ 0xCEE0              ; 2: game ticks since the power-on (the test scripts' frames)
g_event:    equ 0xCEE2              ; what the last tick's frame_end asks for (FE_..., 0)
lv_fresh:   equ 0xCEE3              ; non-zero: the level's lists are copied into RAM at its start
sec_n:      equ 0xCEE4              ; display frames into the timer's second
lvl_bank:   equ 0xCEE5              ; the level's logic bank (logic_map maps it at A000h; kept by pl_init)
snd_v:      equ 0xCF00              ; 3 x SV_SIZE: the sound player's voices (sndplay.asm)
snd_div:    equ 0xCF1E              ; VBLANKs into the sixth one (60 Hz: skipped)
snd_mix:    equ 0xCF1F              ; the PSG mixer (R7) as written last
snd_last:   equ 0xCF20              ; the last effect started
snd_qh:     equ 0xCF21              ; the sound requests' queue (sndplay.asm): the next one the VBLANK takes,
snd_qt:     equ 0xCF22              ;   the next free entry,
snd_q:      equ 0xCF23              ;   SQ_N (8) entries
fs_buf:     equ 0xCF40              ; TXT_STATS_LEN: the statistics script with its numbers (front.asm)
fs_ptr:     equ 0xCFB8              ; 2: its next element
fs_col:     equ 0xCFBA              ; the cursor's column,
fs_row:     equ 0xCFBB              ;   row
fs_wait:    equ 0xCFBC              ; 2: calls left of a wait
fs_n:       equ 0xCFBE              ; 2: ticks so far
fs_done:    equ 0xCFC0              ; 1: the script ended ($16D1)
fs_div:     equ 0xCFC1              ; VBLANKs into the sixth one (60 Hz: skipped)
vp_rel:     equ 0xCFC2              ; front_fire, music.asm vm_play: fire released since they began
pl_gs:      equ 0xCFD0              ; 16: sprite plan: per object its parts' state (sprites.asm pw_gs)
pg_or:      equ 0xCFE0              ; sprite plan: pg_each's result
pl_seq:     equ 0xCFE1              ; sprite plan: plans so far (low byte: pl_stamp)
pg_fn:      equ 0xCFE2              ; 2: pg_each's test
pl_stamp:   equ 0xCFE4              ; 16: per object the plan its pend was prepared in (pl_seq)
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
ac_jmask:   equ 0xDD16              ; player_move's joystick mask ($B02B: 7Fh, 0 while the vehicle
                                    ;   steers; the code's value at power-on, rc2.asm)
ac_ridest:  equ 0xDD18              ; 2: RoboCop's state on the vehicle ($8C98: 2, or 3)
; (the port) the game logic's shortcuts: their caches, worked out again every life (level1.asm
; sw_init, mapobj.asm ao_sort) in the rest of this block
sw_list:    equ 0xDD20              ; 33: the spawn walk's candidates this tick (objects.asm
                                    ;   uo_free): the entries' indices in the list's order, FFh
                                    ;   after the last (up to 32 entries: the masks are longs)
sw_dirty:   equ 0xDD42              ; 4: bit k set while entry k may hold a count or its spawned bit
sw_key:     equ 0xDD46              ; 6: the camera's cells and the dirty mask sw_list was built for
sw_lp:      equ 0xDD4C              ; 2: the walk's next candidate (in sw_list)
sw_k:       equ 0xDD4E              ; the entry visited (its index)
sw_ci:      equ 0xDD4F              ; the index of the entry $B12 points at
sw_bc:      equ 0xDD50              ; 2: camera x + 5Eh this tick (the walk's D0 + 1)
sw_tchg:    equ 0xDD52              ; ENEMY_CAP: not 0 once a slot's type changed since the enemies
                                    ;   in use were counted (objects.asm uo_cap)
sw_px:      equ 0xDD54              ; 2: sw_prep: the x cell's mask
sp_rest:    equ 0xDD60              ; SP_REST_N: per special object n (counted from 1) 1 when the
                                    ;   lift was at rest at its last full run (special.asm sp_update)
SP_REST_N:  equ 12                  ;   (room for 11 records; level 1 has 7)
ao_calo:    equ 0xDD70              ; 2: activate_objects' candidates stand while camera x is in
ao_cahi:    equ 0xDD72              ; 2:   (ao_calo, ao_cahi] (mapobj.asm ao_cands)
AC_VARS_END: equ 0xDD80
spawn_ram:  equ 0xDD80              ; DD80h-DFFFh: the level's spawn list ($B0E; 14-byte records,
                                    ; words little-endian), copied from the level bank at its start
objl_ram:   equ 0xEE00              ; EE00h-F0FFh: the level's object list ($9C18; 12-byte records)
SP_RAM:     equ 0xE900              ; E900h-E9FFh: the level's special objects' records ($8B32)
dg_msxv:    equ 0xE900              ; DIAG test builds (tools/mkrom.py, music.asm dg_main; before any level):
dg_a8b:     equ 0xE901              ;   the BIOS's MSX version and A8h at the start (rc2.asm init),
dg_ptr:     equ 0xE902              ;   2: the next byte of dg_log,
dg_cur:     equ 0xE904              ;   2: the text cursor in dg_txt,
dg_n:       equ 0xE906              ;   counts,
dg_v:       equ 0xE907              ;   a test's value,
dg_bad:     equ 0xE908              ;   4: a test's first wrong values read,
dg_src:     equ 0xE90C              ;   the byte an ldi stores,
dg_lpos:    equ 0xE90E              ;   2: where the log's scc_pat part starts,
dg_log:     equ 0xE910              ;   176: the SCC tests' reads (sound.asm scc_pat, scc_scan),
dg_txt:     equ 0xEE00              ;   32 x 24: the screen's text (objl_ram, before the level)
sp_ptrs:    equ 0xEA00              ; their list as MSX pointers (0 after the last; up to 16)
lk_over:    equ 0xF168              ; LOCKSTEP test builds: frames that started late
bo_dirty:   equ 0xF16A              ; 1: an object's identity changed (budget: bu_order again)
pl_unl:     equ 0xF16B              ; plan: the slots of the version being built not loaded yet
su_vrchk:   equ 0xF16C              ; spr_upload: 1 to stop at the vertical blank (split interrupt)
spr_dsp:    equ 0xF16D              ; R#5 of the sprite set on screen (the interrupt's: sprites.asm iv_sat)
pcr_next:   equ 0xF16E              ; rows_sync: the SAT entry whose colour row follows the last one
                                    ;   written (FFh: none; pc_rows sets an address only otherwise)
                                    ; (F16Fh-F190h and F1A0h-F1C2h: free since the alternation went)
pq_rd:      equ 0xF1C3              ; 2: the published list's queue: where its upload goes on
rs_held:    equ 0xF1C5              ; 2: rows_sync: the col_held of the set being prepared,
rs_colhi:   equ 0xF1C7              ;   its colour table's high address byte (port 99h form)
sp_cam_x:   equ 0xF1C8              ; 2: the camera the objects' screen places were taken against
sp_cam_y:   equ 0xF1CA              ; 2:   (cam_follow)
col_held_b: equ 0xF200              ; 32 x 2: col_held of sprite set B (col_held: set A's)
rc_hold:    equ 0xF191              ; budget: RoboCop's one-layer sprites the totals count (the
rc_hold_t:  equ 0xF192              ;   largest of his recent versions), the tick it was set at
pl_pack:    equ 0xF193              ; plan: 1 once the BOBs' runs were packed (sat_pack: once a plan)
ft_line:    equ 0xF194              ; budget: the line something gives way on (FFh: the total),
ft_best:    equ 0xF195              ;   the cheapest OR layer found so far (its gain),
ft_bix:     equ 0xF196              ;   2: its object (0: none),
ft_tier:    equ 0xF198              ;   the tier looked at (O_TIER),
ft_bbit:    equ 0xF199              ;   the band found (its bit),
ln_neg:     equ 0xF19A              ;   1: ln_obj / ln_add take sprites away from the lines
pl_fl:      equ 0xF19B              ; 2: plan: the objects wanted (O_FLAGS bit 7), a bit each (fl_bit)
pl_flp:     equ 0xF19D              ; 2:   the same at the last plan's start
bu_wsum:    equ 0xF19F              ; budget: the most sprites on a line of each shown object, summed
fb_busy:    equ 0xF1E0              ; field.asm: 1 while there is work (idle_work calls fb_work)
fb_bsync:   equ 0xF1E1              ; V9938: the build target whose page holds the BOBs (flip ok)
pl_vis:     equ 0xF1E3              ; 2: plan: the objects the look still visits (pl_fl | pl_flp,
                                    ;   shifted out one by one)
iw_more:    equ 0xF1E5              ; 1 while a scroll engine may have idle work: set once a frame
                                    ;   (wait_frame, the engine's update) and when a changed cell is
                                    ;   queued (rq_add), cleared by the engine's idle exit; feed_vdp
                                    ;   looks at the engines only then
fb_eng:     equ 0xF1E7              ; field.asm: 0 the V9958's ring, 1 the V9938's two pages
fb_cqp:     equ 0xF1E8              ; tiles.asm fb_redraw -> field.asm fb_cellq: the page,
fb_cqr:     equ 0xF1E9              ;   1: the play-field BOBs draw the cell
cmd_lock:   equ 0xF1EA              ; 1 while the main program gives the VDP a command (the split
                                    ;   interrupt then starts no play-field copy: isr.asm)
fb_hold:    equ 0xF1EB              ; VBLANKs a published list has waited for its play-field BOBs
FB_HOLD:    equ 8                   ;   (isr.asm), at most
fb_vok:     equ 0xF1ED              ; 1: the copy waiting keeps ahead of the beam from the VBLANK
fb_c2:      equ 0xF1EE              ; 1: fb_cmd2 holds the next part of the copy waiting (the split
                                    ;   interrupt starts it right after fb_cmd's: 2)
fb_cmd2:    equ 0xF1EF              ; 15: that part's command (R#32-R#46)
fb_qlk:     equ 0xF1FE              ; 1 while field.asm moves items (queue, work): fb_pend holds
fb_tr:      equ 0xF240              ; 8: field.asm fb_cellq's cell
fb_vis:     equ 0xF248              ; 41 (test builds): the play-field BOBs of the list on screen
                                    ;   (tiles.asm fb_visrec: how many, FB_MAX x frame, x, y)
rcp_id:     equ 0xF1CC              ; 2: rc_prefetch: RoboCop's composition last brought in ahead,
rcp_ok:     equ 0xF1CE              ;   1 once all its patterns had a slot
sp_list:    equ 0xF1D0              ; 16: sat_pack: the objects whose runs it places, in order
ht_box:     equ 0xF100              ; 10 x 10: hit_test's boxes (F100h-F163h, within a 256-byte page)
ph_w:       equ 0xF164              ; 2: pl_hits: an enemy's width,
ph_h:       equ 0xF166              ; 2:   height
pf_pal:     equ 0xEA40              ; 32: the play field's palette (V9938 format) the VBLANK loads:
                                    ;   the copper's colours ($1049E, logic.asm pal_fade / pal_robo)
; (E100h-E7FFh: pat_slot and the sprite queues; E800h-E8FFh: bf_htab; EA22h-EA3Fh,
; C0ECh-C0EEh, C0F2h-C0F3h, CA7Ch, F19Bh-F19Fh, F1CFh, F1E2h-F1E6h, F1ECh, F1FFh,
; F271h-F27Fh: free; EA60h-EC41h: bob_list,
; cat_head, hz_ylo..; F280h-F37Fh: the stack: nothing else may live there)

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
RD_BURST:   equ 6                   ; changed cells drawn in a row between the HUD split and the VBLANK
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
FB_MAX:     equ 8                   ; play-field BOBs of a tick (field.asm)
FB_ENT:     equ 7                   ; an entry: frame, x (2), y (2), owner (2)
; (field.asm's state: what TC_TILE and TC_REF leave free with TC_SLOTS 304 at most, 0660h-075Fh
; and 0890h-090Fh, and E0A3h-E0FDh; with TC_SLOTS 256 at most, 0600h-065Fh too)
dyn_res:    equ 0x0600              ; 2: the dynamic frames resident in the atlas's dynamic slot (bits)
fb_dsn:     equ 0x0602              ; 1 while fb_bobs draws a dynamic frame strip by strip,
fb_ds:      equ 0x0603              ;   the frame's line its next strip starts from,
fb_dse:     equ 0x0604              ;   past its part's last line (lines of the frame),
fb_dpr:     equ 0x0605              ;   8: its part (fb_r's layout)
fb_stg:     equ 0x0610              ; the item's pieces when they are staged (2-4, the page shown's:
                                    ;   each composed in a 64 x 64 of its own, then all copied in a
                                    ;   row), else 0;
fb_spk:     equ 0x0611              ;   the piece being composed or copied (0 .. fb_stg - 1),
fb_scp:     equ 0x0612              ;   0 composing them, 1 copying them
fb_sbx:     equ 0x0613              ; the x in page 3 of the piece's 64 x 64 (FB_SX, or a cache's)
fb_spx:     equ 0x0614              ; 32: per staged piece its fb_px and fb_pe (x0, y0, x1, y1)
fb_bki:     equ 0x0634              ; field.asm fn_take: the best rank so far (fn_key; 0 none),
fb_bkp:     equ 0x0635              ;   2: its item
fb_sn:      equ 0x0660              ; the item being composed: its page's list when it started
fb_snap:    equ 0x0661              ;   (how many, then FB_MAX entries)
fb_own:     equ 0x0699              ; 2: the owner of a rectangle going into the queue (FFFFh: none)
fb_tick:    equ 0x069B              ; the picture being prepared (rc2.asm do_publish counts them): the
                                    ;   items' stamp (none of the page shown copied before it is
                                    ;   published), the caches' last use
fb_lost:    equ 0x069C              ; rectangles lost (queue full: statistics)
fb_cgi:     equ 0x069D              ; the cache of the item being composed (FFh: the tiles)
fb_cpi:     equ 0x069E              ; the next part of its copy (0-3; 4: done)
fb_bn:      equ 0x069F              ; copies left in a burst (FB_BURST)
fb_wn:      equ 0x06A0              ; the play-field BOBs wanted (fb_frame): how many,
fb_want:    equ 0x06A1              ;   FB_MAX entries: their place in the map and owner
fb_dn0:     equ 0x06D9              ; what VRAM page 0 (the V9958's ring) shows: how many (FFh:
fb_dr0:     equ 0x06DA              ;   unknown), the same entries
fb_dn1:     equ 0x0712              ; page 1 (the V9938's other page)
fb_dr1:     equ 0x0713
fb_vlast:   equ 0x074C              ; V9938: the displayed page last seen (074Bh free)
fb_cc:      equ 0x074D              ; 4: the piece's cells: first column, first row, last column,
                                    ;   last row
fb_xs:      equ 0x0751              ; 2: where its parts split: x,
fb_ys:      equ 0x0753              ; 2:   y (the cache's wrap, the ring's 256)
fb_cpy:     equ 0x0755              ; 2: the top of the copy's part in the map (fb_mayq)
fb_dcnt:    equ 0x0757              ; fb_diff's page's list: its entries,
fb_dptr:    equ 0x0758              ;   and their address (2)
fb_slc:     equ 0x075A              ; the piece's edge column its cache does not hold (FFh: none)
fb_lx0:     equ 0x075B              ; 2: the columns its parts keep (fb_part): from,
fb_lx1:     equ 0x075D              ; 2:   to
fb_stp:     equ 0x075F              ; the stamp of the rectangle going into the queue (fb_queue)
fb_qn:      equ 0x0890              ; queue: how many,
fb_q:       equ 0x0891              ;   FB_QMAX x [page, owner (2), x0, y0, x1, y1 (2 bytes each),
FB_QMAX:    equ 8                   ;   picture (fb_tick when queued)]
FB_QSZ:     equ 12
fb_cache:   equ 0x08F1              ; FB_GMAX caches of 4 x 4 cells: [owner (2; FFFFh free), window
FB_GMAX:    equ 3                   ;   (first column, first row), origin (column, row: cell (r, c)
FB_CSZ:     equ 9                   ;   at ((r - oy) & 3, (c - ox) & 3)), cells held (2: bit
                                    ;   row * 4 + column), last use (fb_tick)]
fb_bbn:     equ 0xE0A3              ; V9938: what the page being built may hold from the displayed
fb_bb:      equ 0xE0A4              ;   one (its copy): FB_BBMAX x [x0, y0, x1, y1] (2 bytes each)
FB_BBMAX:   equ 5
fb_cmd:     equ 0xE0CC              ; the VDP command being prepared (R#32-R#46)
fb_cur:     equ 0xE0DB              ; the item being composed (fb_q's layout),
fb_px:      equ 0xE0E7              ;   the piece's corner (2 + 2),
fb_pe:      equ 0xE0EB              ;   its other corner (2 + 2),
fb_r:       equ 0xE0EF              ; a rectangle in the map: x0, y0, x1, y1 (2 bytes each)
fb_ph:      equ 0xE0F7              ; the phase (0 none, field.asm FP_FILL .. FP_WAIT),
fb_ci:      equ 0xE0F8              ;   its cell (row, column), part or BOB index
fb_dpg:     equ 0xE0FA              ; fb_diff's page (| 40h: the hidden one)
fb_rw:      equ 0xE0FB              ; a cell: row,
fb_cl:      equ 0xE0FC              ;   column
fb_cq:      equ 0xE0FD              ; 1, 3 (its last part): fb_cmd holds a copy for the page shown
                                    ;   (the interrupts start it: 2, 4)
fb_n:       equ 0x1F9C              ; the tick's play-field BOBs (bob.asm fb_add): how many,
fb_new:     equ 0x1F9D              ;   FB_MAX x [frame, x (2), y (2), owner (2)] as their records
rd_bits:    equ 0x1FD5              ; 40: the cells waiting in RD_Q (tiles.asm rd_bit)
mw_atr:     equ 0x108A              ; map_write's attributes
mw_idx:     equ 0x108B              ; map_write's new patch
