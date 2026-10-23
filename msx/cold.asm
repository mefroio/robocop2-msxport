; Cold code of the fixed area: routines that run once per level (or at power-on), kept in the
; front end's bank (BANK_FRONT at 8000h through front_call) to leave room in 4000h-7FFFh. They
; call only fixed code and never map the 8000h window themselves.

; State of the static HUD (hud.asm) at a new game: timer 09:58, ammo 000, score 0000000, full can,
; two RoboCop heads, the icon of weapon 0, empty message line; then the panel as the game starts
; (vdp.asm hud_upload, the last thing done here: it maps the 8000h window and puts this bank back).
hud_init:
        ld hl,hud_timer
        ld (hl),0x09
        inc hl
        ld (hl),0x58
        ld hl,hud_ammo
        ld b,6
        xor a
hi_z:   ld (hl),a
        inc hl
        djnz hi_z                   ; ammo and score
        ld hl,hi_shown
        ld de,hud_shown
        ld bc,14
        ldir
        ld hl,0x100
        ld (en_target),hl
        ld (en_shown),hl
        ld hl,msg_queue
        ld b,8 + 4
        xor a
hi_q:   ld (hl),a
        inc hl
        djnz hi_q                   ; queue, indices, column, count
        ld hl,hud_chars
        ld b,TEXT_CELLS
        ld a,SPACE
hi_c:   ld (hl),a
        inc hl
        djnz hi_c
        xor a
        ld (heads_g),a
        ld (heads_g+1),a
        ld (job_lines),a
        ld (jobq_n),a
        ld (weapon),a
        ld a,3
        ld (icon_shown),a           ; (weapon 0's icon, see set_weapon $FD30)
        ld a,2
        ld (lives),a
        jp hud_upload               ; (no last game's digits)
hi_shown:
        db 0, 9, 5, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; At a level's start (sprites.asm sprites_init): nothing shown, every slot and colour row
; unknown.
spr_init:
        ld hl,obj_tab
        ld bc,MAX_OBJ*OBJ_SIZE
        xor a
        call fill
        ld hl,disp
        ld bc,2*MAX_OBJ*LAY_SIZE
        xor a
        call fill                   ; nothing shown, nothing prepared
        ld hl,col_held
        ld bc,SAT_MAX*2
        ld a,0xFF
        call fill                   ; colour rows unknown (sets A and B)
        ld hl,col_held_b
        ld bc,SAT_MAX*2
        ld a,0xFF
        call fill
        ld hl,ent_own
        ld bc,SAT_MAX
        ld a,0xFF
        call fill                   ; every SAT entry free
        ld a,SPARK_OBJ
        ld (ent_own),a
        ld (ent_own+1),a            ; (the spark's two)
        ld hl,pat_held
        ld bc,SPR_SLOTS*2
        ld a,0xFF
        call fill                   ; patterns unknown
        ld hl,slot_ref
        ld bc,SPR_SLOTS
        xor a
        call fill                   ; every slot free
        ld hl,SLOT_PG*256 + SO_OK
        ld bc,2*SPR_SLOTS
        xor a
        call fill                   ; nothing loaded, nothing queued (slot_ok, slot_q)
        ld a,SO_FL - 1
        ld (fl_n),a                 ; nothing to release
        ld hl,pat_slot
        ld bc,PAT_HINTS
        ld a,0xFF
        call fill                   ; and put nowhere
        if EXTJOY
        ld hl,pub_cur
        ld bc,MAX_OBJ*8
        xor a
        call fill
        endif
        ld hl,obj_key
        ld bc,MAX_OBJ*4
        xor a
        call fill                   ; no BOB identity (bob.asm)
        ld hl,pl_st                 ; (the plan's look skips the objects not wanted: their work
        ld bc,MAX_OBJ               ;  and parts' states must start at 0)
        xor a
        call fill
        ld hl,pl_gs
        ld bc,MAX_OBJ
        xor a
        call fill
        ld hl,0
        ld (pl_fl),hl
        ld (pl_flp),hl
        ld a,1
        ld (pg_new),a               ; (the objects with parts: built at the first plan)
        ld hl,bf_last
        ld bc,MAX_OBJ*6
        ld a,0xFF
        call fill                   ; no frame remembered (bob.asm bf_show)
        ld a,SPR_MAX                ; (RoboCop counts whole in the budget)
        ld (rc_hold),a              ; (his largest until his own count is known)
        ld a,(tick)
        ld (rc_hold_t),a
        ld a,1
        ld (bu_dirty),a             ; (the budget runs on the first tick)
        ld (bo_dirty),a
        ld (sat_dirty),a
        xor a
        ld (spr_vblank),a
        ld (sat_due),a
        ld (pk_mux),a               ; (never set since the alternation went; the Tcl checks read it)
        ld (alloc_p),a
        ld (rcp_ok),a               ; (rc_prefetch: nothing brought in ahead)
        ld a,R5_SET_A
        ld (spr_set),a
        ld (spr_dsp),a
        ret

; The tile cache and the map patches at the start of a level (tiles.asm; rc2.asm new_game):
; slots 0..TC_SLOTS-1 hold tiles 0..TC_SLOTS-1 (uploaded by vdp_setup), no patch, nothing to
; redraw.
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
        call fill                   ; tiles TC_SLOTS-511: not in VRAM
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
        ld hl,rd_bits
        ld bc,40
        xor a
        call fill                   ; (nothing waits to be redrawn)
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

; (player.asm)
; Start of level 1 (level_init $871A, clear_game_vars $FE96): the game variables cleared (with
; the keyboard and joystick bytes, the input lock and the joystick mask), RoboCop and the camera
; at the header's position, no state asked for; the cadence for the
; machine's refresh rate (RG9SAV bit 1: 50 Hz) and the view on the camera.
pl_init:
        call snd_stop               ; (level_init $8720)
        ld hl,AM_START
        ld bc,AM_END - AM_START
        xor a
        call fill                   ; (clear_game_vars)
        ld hl,G_VARS
        ld bc,G_VARS_END - G_VARS
        xor a
        call fill
        xor a
        ld (g_keys),a               ; (clear_game_vars: $802D, $802E, $804D)
        ld (g_joy),a
        ld (g_lock),a
        ld (jump_pend),a
        ld a,0x7F
        ld (ac_jmask),a             ; ($B02B)
        xor a
        call pal_fade               ; black until the fade in
        if INPUT_SCRIPT
        ld hl,input_script
        ld (sc_run),hl              ; (the script's first run, from game frame 0)
        endif
        ld hl,LVL_X
        ld (p_x),hl
        ld (gcam_x),hl
        ld hl,LVL_Y
        ld (p_y),hl
        ld (gcam_y),hl
        ld hl,LVL_YMAX
        ld (gcam_ymax),hl
        ld a,0xFF
        ld (p_pend+1),a             ; (st $1696: its high byte)
        ld (p_fadein),a             ; the palette fades in ($16CE)
        ld a,(RG9SAV)
        and 2
        ld a,5                      ; 60 Hz: every other frame
        jr z,pi_hz
        inc a                       ; 50 Hz: 3 ticks in 5 frames
pi_hz:  ld (g_step),a
        neg
        add a,CAD_TICK
        ld (g_acc),a                ; the first frame ticks
        ld a,1
        ld (wf_n),a
        jp pl_view

; (isr.asm) At power-on (vdp.asm vdp_setup): the IM 2 table and jump, the interrupts' shared
; state.
isr_init:
        ld hl,IM2_TABLE
        ld de,IM2_TABLE+1
        ld bc,256
        ld (hl),IM2_VEC
        ldir
        ld a,0xC3                   ; JP isr
        ld (IM2_JUMP),a
        ld hl,isr
        ld (IM2_JUMP+1),hl
        ld a,IM2_I
        ld i,a
        im 2
        xor a
        ld (split_armed),a
        ld (fb_cq),a                ; (no play-field copy or command waits: field.asm)
        ld (fb_rdy),a
        ld (cmd_lock),a
        ld (fb_vok),a
        ld (fb_qlk),a
        ld (tick),a
        ld (last_tick),a
        ld (pk_state),a             ; (the sprite engine's state the interrupts share)
        ld (pk_mux),a
        ld (pq_buf),a
        ld (bq_head),a
        ld (bq_tail),a
        ld (vram_busy),a
        ld (sat_due),a
        ld (spr_vblank),a
        ld (pub_seq),a              ; the list on screen until the first one is published: one
        ld (app_seq),a              ; that changes nothing (R#15 = 0). At power-on the RAM holds
        ld hl,vbl_list_a            ; anything, and a list read from it once wrote R#14 and an
        ld (vbl_ptr),hl             ; address in the middle of the tiles' upload after the title
        ld (pk_list),hl
        ld (hl),a                   ; (seq 0)
        inc hl
        ld (hl),2
        inc hl
        ld (hl),a
        inc hl
        ld (hl),0x8F
        ld hl,sat_pair0
        ld (sat_cur),hl
        ld (sat_nb),hl
        ld hl,pq_buf
        ld (pq_rd),hl
        ld a,R5_SET_A
        ld (spr_dsp),a
        ret

; (sound.asm) At power-on, with the BIOS in page 0 (rc2.asm init, through front_call).
; An OPLL: every slot's page 1 is searched for "OPLL" at 401Ch after "APRL" (MSX-MUSIC) or
; "PAC2" (FM-PAC, whose I/O ports are then switched on: bit 0 of 7FF6h in its slot).
; snd_fm = 1 when found. Uses the BIOS (RDSLT, WRSLT); interrupts end up disabled.
snd_detect:
        xor a
        ld (snd_fm),a
        ld c,0                      ; primary slot
sdt_p:  ld hl,EXPTBL
        ld e,c
        ld d,0
        add hl,de
        ld a,(hl)
        and 0x80
        or c
        ld b,a                      ; slot id (expanded: secondary 0 first)
sdt_s:  push bc
        ld a,b
        call sdt_try
        pop bc
        ret z                       ; found
        bit 7,b
        jr z,sdt_np                 ; not expanded: the next primary slot
        ld a,b
        add a,4
        ld b,a
        and 0x0C
        jr nz,sdt_s                 ; secondary 1-3
sdt_np: inc c
        ld a,c
        cp 4
        jr c,sdt_p
        or 1                        ; (NZ: none)
        ret

; A = slot id: Z when its page 1 holds an OPLL BIOS (then snd_fm = 1, the FM-PAC's ports on).
sdt_try:
        ld (snd_slot),a
        ld hl,0x401C
        ld de,sdt_opll
        ld b,4
        call sdt_cmp
        ret nz
        ld l,0x18                   ; (H = 40h: 4018h; no ld hl,4018h in the image, see sdt_opll)
        ld de,sdt_aprl
        ld b,4
        call sdt_cmp
        jr z,sdt_yes
        ld l,0x18
        ld de,sdt_pac2
        ld b,4
        call sdt_cmp
        ret nz
        ld a,(snd_slot)             ; an FM-PAC: its I/O ports on
        ld hl,0x7FF6
        ld e,1
        call WRSLT
sdt_yes:
        ld a,1
        ld (snd_fm),a
        xor a                       ; (Z)
        ret

; HL = address in the slot snd_slot, DE = text, B = length: Z when they match.
sdt_cmp:
        push bc
        push de
        push hl
        ld a,(snd_slot)
        call RDSLT
        cpl                         ; (the texts are stored complemented)
        pop hl
        pop de
        pop bc
        ex de,hl
        cp (hl)
        ex de,hl
        ret nz
        inc hl
        inc de
        djnz sdt_cmp
        ret

; The texts complemented, so that "OPLL" is nowhere in the image: the MSX Pico+ firmware starts
; a Konami SCC ROM holding "OPLL" and an ld hl,4018h or ld de,4018h as an FM-PAC game, its
; mapper without the SCC (seen in its v2.12 code; tools/mkrom.py checks the image).
sdt_opll:   db 0xFF - 'O', 0xFF - 'P', 0xFF - 'L', 0xFF - 'L'
sdt_aprl:   db 0xFF - 'A', 0xFF - 'P', 0xFF - 'R', 0xFF - 'L'
sdt_pac2:   db 0xFF - 'P', 0xFF - 'A', 0xFF - 'C', 0xFF - '2'

; (vdp.asm) At power-on (rc2.asm init, through front_call): SCREEN 5, 212 lines, VDP ID, IM 2,
; palette, tiles (pages 2-3), HUD and sprite tables. Returns with the display off and no VDP
; interrupt enabled.
vdp_setup:
        ld a,5
        call CHGMOD
        di
        ld a,0x02                   ; display off, no VBLANK interrupt, 16x16 sprites
        out (VDP_CTRL),a
        ld a,0x81
        out (VDP_CTRL),a
        ld a,R0_IE1_OFF
        out (VDP_CTRL),a
        ld a,0x80
        out (VDP_CTRL),a
        call isr_init               ; no VDP interrupt source is enabled yet
        ld a,1
        ld b,15
        call wrreg
        in a,(VDP_CTRL)             ; S#1: ID in bits 5..1
        rrca
        and 0x1F
        ld (vdp_id),a
        xor a
        ld b,15
        call wrreg
        xor a
        ld b,7
        call wrreg                  ; border colour = 0
        ld a,R8_SPR_OFF
        ld b,8
        call wrreg
        ld a,(RG9SAV)
        or 0x80
        ld b,9
        call wrreg                  ; 212 lines (keeps the 50/60 Hz setting)
        xor a
        ld b,16
        call wrreg
        ld hl,palette
        ld bc,32*256 + VDP_PAL
        otir
        ld e,8
        call tiles_upload
        ld hl,field_upload
        call field_call             ; the play-field BOBs' atlas over the last tile slots
        call hud_upload
        ; sprite tables: both SATs end at sprite 0 (Y = 216)
        ld e,1
        ld hl,(SPR_COL_A + 0x200) & 0xFFFF
        call vram_write
        ld a,216
        out (VDP_DATA),a
        ld e,1
        ld hl,(SPR_COL_B + 0x200) & 0xFFFF
        call vram_write
        ld a,216
        out (VDP_DATA),a
        call vram_done
        ld a,R5_SET_A
        ld (spr_set),a
        ld b,5
        call wrreg
        ld a,R11_SPR
        ld b,11
        call wrreg
        ld a,R6_PAT
        ld b,6
        call wrreg
        ; fixed parameters of the tile HMMM
        ld hl,16
        ld (cmdbuf+8),hl
        ld (cmdbuf+10),hl
        xor a
        ld (cmdbuf+12),a
        ld (cmdbuf+13),a
        ld a,0xD0
        ld (cmdbuf+14),a
        ret

; No RAM in page 0 (rc2.asm init, the main RAM is not in page 3's slot): a red screen.
no_ram: xor a
        ld b,16
        call wrreg                  ; palette entry 0
        ld a,0x70
        out (VDP_PAL),a
        xor a
        out (VDP_PAL),a             ; red
        xor a
        ld b,7
        call wrreg                  ; border colour 0
        ld a,0x02
        ld b,1
        call wrreg                  ; display off, no interrupt
        di
        halt

; An MSX1, or an MSX2 with less than 128 KiB of VRAM (rc2.asm init, through front_call): the game
; cannot run there; a message in SCREEN 0 (the BIOS still serves page 0) and the machine stays
; on it.
no_msx2:
        ei
        call INITXT
        ld hl,no2_msg
nm_lp:  ld a,(hl)
        or a
        jr z,nm_x
        call CHPUT
        inc hl
        jr nm_lp
nm_x:   jr nm_x
no2_msg:
        db "ROBOCOP 2 needs an MSX2"
        db 13, 10
        db "with 128 KB of VRAM."
        db 0

; (tiles.asm) At power-on (rc2.asm init, through front_call).
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

; (sound.asm) At power-on (rc2.asm init, BANK_FRONT at 8000h).
; Everything silent: the PSG's volumes 0 and its mixer (PSG_MIX); with an OPLL, its 9 channels
; keyed off at volume 15 (the quietest) and its rhythm off.
snd_init:
        di
        ld a,7
        ld e,PSG_MIX
        call psg_w
        ld a,8
        ld e,0
        call psg_w
        ld a,9
        call psg_w
        ld a,10
        call psg_w
        ei
        ld a,(snd_fm)
        or a
        ret z
        ld a,0x0E
        ld e,0
        call opll_w                 ; rhythm off
        ld b,9
        ld c,0
sin_ch: ld a,0x20
        add a,c
        ld e,0
        call opll_w                 ; key off, block 0, F-number 0
        ld a,0x30
        add a,c
        ld e,0x0F
        call opll_w                 ; instrument 0, volume 15
        inc c
        djnz sin_ch
        ret

; (tiles.asm) At the level's start (rc2.asm new_game, BANK_FRONT at 8000h): the packed map
; attributes (bank ATR_BANK, through the A000h window: 80 bytes per row, 4-bit codes, then the
; codes' 16 values) into page-0 RAM - rows 0-47 at ATR_RAM0, the others at ATR_RAM1 (atr_rows:
; each row's address) - and the values into atr_lut. atr_rc reads them there: no bank switching
; for the game logic's many attribute reads.
atr_load:
        ld a,(act_a000)
        push af
        ld a,ATR_BANK
        call bank_a000
        ld hl,0xA000
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
        jp bank_a000

; (vdp.asm) E = banks of 8 KiB: the tiles from the ROM (through the A000h window) -> VRAM from
; 10000h (8 at the start: 10000h-1FFFFh, the HUD and the sprite tables follow; 4 after a SCREEN 8
; picture: G7 interleaves its bytes over both halves of VRAM, so a picture overwrites
; 10000h-16A00h).
tiles_upload:
        ld a,(act_a000)
        push af
        push de
        ld e,1
        ld hl,0
        call vram_write
        pop de
        ld d,BANK_TILES
ut_bank:
        ld a,d
        call bank_a000
        ld hl,0xA000
        ld b,32
        push de
        call vram_blocks
        pop de
        inc d
        dec e
        jr nz,ut_bank
        call vram_done
        pop af
        jp bank_a000

; (vdp.asm) The HUD's empty panel (HUD_IMG_BANK through the A000h window): page 3 from line
; HUD_VRAM_LINE (after the tiles, which cover pages 2-3); also at each new game (hud_init: the
; last game's digits and message go).
hud_upload:
        ld a,(act_a000)
        push af
        ld e,1
        ld hl,VRAM_HUD & 0xFFFF
        call vram_write
        ld a,HUD_IMG_BANK
        call bank_a000
        ld hl,0xA000
        ld b,HUD_LINES/2            ; 128 bytes per line: 256 per pair of lines
        call vram_blocks
        if HUD_LINES & 1
        ld bc,128*256 + VDP_DATA
        otir                        ; the odd last line
        endif
        call vram_done
        pop af
        jp bank_a000
