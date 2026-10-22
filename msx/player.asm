; RoboCop's control: the Amiga routines of main_loop ($80C2) redone at the game's 30 Hz, in the
; same order (docs/AMIGA_ANALYSIS.md "Player control"):
;
;   player_move   $AFF8 -> pl_move: state machine, steps against the walls of the map attributes
;                          (bit 1), jumps, falls and landings on floors (bits 0/2) and lifts ($BD72),
;                          animation counter, camera and the start-of-level sequence
;   update_player $ACEC -> pl_aim: the aim; the fire, shots and effects: shots.asm pl_fire
;   draw_player   $B94A -> pl_frame: the state's last animation step ($15E8), the frame record and
;                          its hotspot; pl_show (after the scroll engine): the composition and
;                          its place on screen
;   read_joystick $BDEC -> joy_read: joystick port 1, else the keyboard (as the Amiga's keys)
;
; The variables keep the Amiga's meaning and values, as 16-bit little-endian words (msx/msx.inc,
; the Amiga address beside each); the tables come from the game's code (tools/player.py --inc).

COST_GAME:  equ 100                 ; the game tick's work in sprite upload units (msx/sprites.asm;
                                    ; about 11000 T-states measured with RoboCop moving)
SPR_X_OFS:  equ 5 - 0x90            ; sprite x = 5 + x - camera_x + hot_x (draw_player $BC0A), the
                                    ; display window starts at $90 (copper $1049E): map x of the
                                    ; composition's left edge = x + hot_x - 139
SPR_Y_OFS:  equ -16 - 25 - 0x1E     ; VSTART = hot_y - 16 + y - camera_y - 25 ($BC1E, $102BA), the
                                    ; play field starts at line $1E (copper $10332): map y of the
                                    ; composition's top = y + hot_y - 71
WALL:       equ 2                   ; map attribute bits
FLOOR:      equ 5

; Once per frame, after its list is published: g_tick = the game ticks due (TICK_HZ a second:
; 30 as the NTSC original, whose main loop waits for 2 VBLs of 60 Hz, or 25 as the PAL one,
; tools/mkrom.py TICK_HZ), counted on the VBLANKs since the
; last frame (wf_n), so that late frames (busy ticks took more than their frames) are caught up
; with ticks run in a row (the display skips their pictures).
; At most CAD_MAX ticks in a frame (tools/mkrom.py CAD_MAX; CAD_HOLD while the V9938 scroll keeps
; the camera at a page's edge): a longer delay is lost (only then the game slows down, as the
; original does when its frame takes 3 VBLs).
LAG_MAX:    equ 32                  ; pixels the view shown may lag behind the camera (cadence)
RC_EDGE:    equ 16                  ; pixels RoboCop keeps from the screen's edges while it lags
CAD_TICK:   equ 300 / TICK_HZ       ; + g_step (6 at 50 Hz, 5 at 60 Hz) per VBLANK, a tick at 10
                                    ; (30 Hz) or 12 (25 Hz)
cadence:
        if LOCKSTEP
        ld a,2                      ; (test builds: two ticks every frame, the first one's picture
        ld (g_tick),a               ; skipped)
        ld (g_tn),a
        ret
        endif
        ld a,(wf_n)
        cp 8
        jr c,cd_n
        ld a,8
cd_n:   ld b,a
        ld a,(g_step)
        ld c,a
        ld a,(g_acc)
cd_add: add a,c
        djnz cd_add
        ld b,0
cd_lp:  cp CAD_TICK
        jr c,cd_set
        sub CAD_TICK
        inc b
        jr cd_lp
cd_set: ld c,a
        ld d,0                      ; none while the view shown is LAG_MAX pixels or more behind
        call cam_lag                ; the one the game wants, or lags at all with RoboCop at the
        jr nc,cd_cap                ; screen's edge (the scroll catches up first: he never runs off
        call rc_safe                ; the screen), else at most CAD_MAX, CAD_HOLD while the V9938
        jr nc,cd_cap                ; scroll kept the camera at a page's edge (its next page comes
        ld d,CAD_MAX                ; sooner)
        ld a,(cam_held)
        or a
        jr z,cd_cap
        ld d,CAD_HOLD
cd_cap: ld a,d
        cp b
        jr nc,cd_n2
        ld b,d                      ; more due: the rest is lost (the game slows down)
cd_n2:  ld a,b
cd_max: ld (g_tick),a
        ld (g_tn),a
        ld a,c
        ld (g_acc),a
        ret

; -> C when the view shown (cam_x, cam_y: the scroll engine holds them while its next page or row
; is not ready) is less than LAG_MAX pixels from the one the game wants (v_x, v_y). Keeps BC.
cam_lag:
        ld hl,(v_x)
        ld de,(cam_x)
        call cl_abs
        ret nc
        ld hl,(v_y)
        ld de,(cam_y)
cl_abs: or a
        sbc hl,de
        jr nc,cl_p
        ex de,hl
        ld hl,0
        or a
        sbc hl,de                   ; (the distance)
cl_p:   ld de,LAG_MAX
        or a
        sbc hl,de
        ret

; -> NC when the view shown lags behind the one the game wants (x) and RoboCop's sprites reach
; within RC_EDGE pixels of the screen's left or right edge. Keeps BC.
rc_safe:
        ld hl,(v_x)
        ld de,(cam_x)
        or a
        sbc hl,de
        scf
        ret z                       ; (no lag: at the map's ends he may walk to its edge)
        ld ix,obj_tab
        bit 7,(ix+O_FLAGS)
        scf
        ret z
        ld l,(ix+O_X)
        ld h,(ix+O_X+1)
        ld a,(ix+O_MINDX)
        ld e,a
        rla
        sbc a,a
        ld d,a
        push hl
        add hl,de                   ; his left edge
        ld de,RC_EDGE
        or a
        sbc hl,de
        pop hl
        jp p,rs_r
        or a                        ; (NC: too far left)
        ret
rs_r:   ld a,(ix+O_MAXDX)
        ld e,a
        rla
        sbc a,a
        ld d,a
        add hl,de
        ld de,16 + RC_EDGE - 256
        add hl,de                   ; his right edge + RC_EDGE - 256
        ld a,h
        rla                         ; C when it is left of the edge
        ret

; One game frame: main_loop's calls that are ported so far, in its order.
game_tick:
        ld a,COST_GAME
        call spr_charge
        call logic_map              ; the logic banks at 8000h and A000h
        if INPUT_SCRIPT
        call script_tick            ; test builds: teleports, god mode
        endif
        ld a,(g_paused)
        or a
        jp nz,gt_pause
        call pl_fade                ; $F878
        call frame_keys             ; $F76C
        ld a,(g_paused)
        or a
        ret nz                      ; paused: this frame goes on once resumed
gt_go:  call bob_begin              ; no BOB drawn yet
gtp_move:
        call pl_move                ; $AFF8
        call pl_hits                ; $FA7C (hits.asm)
        call feed_vdp               ; (the V9938 scroll engine's VDP commands: between the stages)
gtp_act:
        ld a,BANK_LC3
        call bank_8000
        call hz_update              ; $9150 (module 3)
        ld a,BANK_LC2
        call bank_8000
        call activate_objects       ; $9C06 (module 2)
        call feed_vdp
gtp_sp: ld a,BANK_LC3
        call bank_8000
        call sp_update              ; $8B32 (module 3: special.asm)
        ld a,BANK_LC1
        call bank_8000
        call feed_vdp
gtp_aim:
        call pl_aim                 ; $ACEC: the aim,
        call pl_fire                ;   the fire, the shots and effects (shots.asm)
        call pl_frame               ; $B94A
gtp_eb: ld a,BC_EBULLET
        ld (bob_cat),a
        call eb_update              ; $F3CE
        call joy_read               ; $BDEC
        call feed_vdp
gtp_uo: ld a,BC_ENEMY
        ld (bob_cat),a
        call update_objects         ; $C3E4
        call feed_vdp
gtp_ex: ld a,BC_EXPL
        ld (bob_cat),a
        call expl_update            ; $F080
        call pk_update              ; $F900 (hits.asm)
gtp_en: call en_update              ; $89BE (the can itself: hud_energy)
        call rnd_step               ; $BDCE (logic.asm)
gtp_end:
        ld hl,(g_frame)
        inc hl
        ld (g_frame),hl
        ld hl,(AM + 0x0B02)
        inc hl
        inc hl
        inc hl
        ld (AM + 0x0B02),hl         ; ($B02 += 3)
        ld hl,(tick_n)
        inc hl
        ld (tick_n),hl
        ld a,BANK_LC3
        call bank_8000
        call frame_end              ; $8144-$82E8 (module 3: frame.asm)
        ld (g_event),a
        ld a,BANK_LC1
        jp bank_8000

gt_pause:
        call fk_keys
        ld a,(g_paused)
        or a
        jp z,gt_go
        ld hl,pause_n
        dec (hl)
        ret nz
        ld (hl),105
        ld a,HUD_MSG_F837
        jp game_msg

; ----- frame_keys ($F76C) -----

; The sound requests of the last frame ($B2C-$B31, from the last one to the first) are played
; and cleared (the sound effects come with the PSG/FM driver: snd_play). Then the keys: pause and
; the panel's digits, with the HUD.
frame_keys:
        ld b,6
fk_lp:  ld a,b
        dec a
        xor 1
        ld e,a
        ld d,0
        ld hl,g_snd
        add hl,de                   ; request b - 1 (byte $B2C + i at g_snd + (i ^ 1))
        ld a,(hl)
        or a
        jr z,fk_n
        ld (hl),0
        push bc
        dec b
        ld c,b                      ; channel (5..0), A = sound
        call snd_play
        pop bc
fk_n:   djnz fk_lp
        ; (then panel_update_digits $F6B8: hud_digits follows the values by itself)

; The keys ($F788): a new key code in $8032 ($8033 holds the last one handled). $21 shows the
; counts of nukes ($16C0) and hostages ($16BE) in the message line (rescuing a hostage puts it);
; $19 (P) pauses or resumes ($804E) with "PAUSE ON." / "PAUSE OFF.". While paused the game does
; not go on (game_tick), and "PAUSE ON." comes again every 105 ticks (the Amiga's busy loop of
; $48000 turns, about 4 s).
fk_keys:
        ld a,(g_key)
        ld hl,g_keydone
        cp (hl)
        ret z
        ld (hl),a
        cp 0x21
        jr nz,fk_pause
        ld hl,(AM + 0x16C0)
        ld de,dbg_msg + 5
        call num3
        ld hl,(AM + 0x16BE)
        ld de,dbg_msg + 15
        call num3
        ld hl,dbg_msg
        call hud_message
        ld a,(g_keydone)
fk_pause:
        cp 0x19
        ret nz
        ld hl,g_paused
        ld a,(hl)
        cpl
        ld (hl),a
        or a
        ld a,HUD_MSG_F837           ; "PAUSE ON."
        jr nz,fk_pm
        ld a,HUD_MSG_F82C           ; "PAUSE OFF."
fk_pm:  call game_msg
        ld a,105
        ld (pause_n),a
        ret

; HL = a count, DE = where its 3 characters go ($F750: from the table at $F855; 10 and more
; show as its last entry).
num3:   ld a,h
        or a
        jr nz,n3_10
        ld a,l
        cp 10
        jr c,n3_ok
n3_10:  ld a,10
n3_ok:  ld l,a
        add a,a
        add a,l
        ld l,a
        ld h,0
        ld bc,num3_tab
        add hl,bc
        ld bc,3
        ldir
        ret

; Once per frame (the Amiga's keyboard interrupt sets $8032 at any time): P = $19 (pause); a
; press puts its code, a release the code + 80h.
key_scan:
        if INPUT_SCRIPT
        ret
        else
        ld a,4
        call kb_row                 ; R Q P O N M L K
        ld a,c
        and 0x20
        ld hl,key_p
        cp (hl)
        ret z
        ld (hl),a
        or a                        ; (pressed or released: the flags of the cp told only that it
        ld a,0x19                   ; changed, so a release gave 19h too and P never resumed)
        jr nz,ks_set
        ld a,0x99
ks_set: ld (g_key),a
        ret
        endif

; ----- palette fades ($F878) -----

; While fading in ($16CE set) the level ($16CD) goes up to 1Fh, one step per frame, and the
; state is forced to FADE_STATE (also asked for: $1696); fading out it goes down to 0. The
; palette itself (each component at most ((level + 1) / 2) & 1Eh of 15, the flash of $F826):
; with the palette effects.
pl_fade:
        ld hl,(ac_flash)            ; the palette flash ($F826): counted down, the level's
        bit 7,h                     ; palette back at 0, then -1 (idle)
        jr nz,plf_go
        ld a,h
        or l
        jr nz,plf_dec
        ld (ac_flpal),a             ; (PAL_LEVEL)
        push hl
        call pal_robo               ; RoboCop in the level's colours again
        pop hl
plf_dec:
        dec hl
        ld (ac_flash),hl
plf_go:
        ld hl,p_fade
        ld a,(p_fadein)
        or a
        jr z,pf_out
        ld a,(hl)
        cp 0x1F
        ret z
        inc (hl)
        ld a,(hl)
        ld hl,FADE_STATE
        ld (p_pend),hl
        ld (p_state),hl
        jp pal_fade
pf_out: ld a,(hl)
        or a
        ret z
        dec (hl)
        ld a,(hl)
        jp pal_fade

; ----- player_move ($AFF8) -----

pl_move:
        call pl_cellof              ; A0: the cell of the frame's start position
        ld a,(p_state)
        ld (pm_d1),a                ; D1 = state
        and 0x7E
        ld (pm_d5),a                ; D5 = state & 7Eh
        ld a,0xFF
        ld (pm_d2),a                ; D2 = -1: no new state
        ld hl,ac_jmask              ; (the immediate $B02B: 0 while the vehicle steers)
        ld a,(g_joy)
        and (hl)
        ld (pm_d0),a                ; D0 = joystick bits
        ld hl,(p_conf)              ; reversed controls ($1698)
        ld a,h
        or l
        jr z,pm_pend
        dec hl
        ld (p_conf),hl
        ld a,(g_frame)
        and 7
        call z,pl_flash
        ld a,(pm_d0)
        ld c,a
        and 0x0C
        jr z,pm_pend
        ld a,c
        xor 0x0C
        ld (pm_d0),a
pm_pend:
        ld a,(p_pend+1)             ; a state the last frame asked for ($1696)
        bit 7,a
        jr nz,pm_10
        ld a,0xFF
        ld (p_pend+1),a
        ld a,(p_pend)
        ld (pm_d2),a
pm_10:  ld a,(pm_d5)
        cp 0x0A
        jr nz,pm_14
        ld a,(pm_d0)                ; states 10/11: left and right only, no fire
        and 0x0C
        ld (pm_d0),a
        ld hl,g_joy
        res 4,(hl)
pm_14:  ld a,(pm_d5)
        cp 0x0E
        jr nz,pm_8
        ld a,(pm_d0)                ; states 14/15: up only
        and 1
        ld (pm_d0),a
pm_8:   ld a,(pm_d5)
        cp 8
        jr nz,pm_6
        ld a,(pm_d0)                ; crouching: only up goes on
        cp 1
        jp nz,pm_b170
pm_6:   ld a,(pm_d5)
        cp 6
        jp z,pm_afb2
        ld a,(pm_d0)
        bit 2,a
        jr z,pm_right
        ld c,1                      ; left: state 1 (5 in the air)
        ld a,(p_air)
        or a
        jr z,pm_left1
        ld c,5
pm_left1:
        ld a,c
        ld (pm_d2),a
pm_right:
        ld a,(pm_d0)
        bit 3,a
        jr z,pm_step
        ld c,0                      ; right: state 0 (4 in the air)
        ld a,(p_air)
        or a
        jr z,pm_right1
        ld c,4
pm_right1:
        ld a,c
        ld (pm_d2),a
        ; the current state's step, unless the cell beside is a wall (the row above while vy < 0,
        ; i.e. on the ground or going up)
pm_step:
        ld a,(pm_d1)
        ld e,a
        ld d,0
        ld hl,pl_xstep
        add hl,de
        ld a,(hl)
        or a
        jr z,pm_add
        ld (pm_d4),a
        ld hl,(p_row)
        ld d,l                      ; D = row
        ld e,h                      ; E = column
        ld a,(p_vy+1)
        bit 7,a
        jr z,pm_side
        dec d                       ; the row above
pm_side:
        ld a,(pm_d4)
        bit 7,a
        jr z,pm_east
        dec e
        jr pm_wall
pm_east:
        inc e
pm_wall:
        call atr_rc
        and WALL
        jr nz,pm_b0fe
        ld a,(p_anim)
        and 6
        cp 6
        jr nz,pm_go
        ld a,6
        ld (snd_b30),a              ; footstep
pm_go:  ld a,(pm_d4)
pm_add: ld l,a
        rla
        sbc a,a
        ld h,a
        ld de,(p_x)
        add hl,de
        ld (p_x),hl
pm_b0fe:
        ld a,(pm_d0)
        and 0x0C
        jp nz,pm_b170
        ld a,(pm_d0)
        bit 0,a
        jr z,pm_b142
        ld a,(p_floor)              ; up on a floor with bit 2 ($1675) is fire
        bit 2,a
        jr z,pm_up
        ld a,0x10
        ld (g_joy),a
        jr pm_b142
pm_up:  ld a,(p_jwait)              ; just landed: stands a frame more
        or a
        jr z,pm_jump
        dec a
        ld (p_jwait),a
        ld a,2
        ld (pm_d2),a
        jp pm_b170
pm_jump:
        ld a,(p_air)
        or a
        jp nz,pm_b170
        ld a,(pm_d0)
        bit 4,a
        jp nz,pm_b170               ; up + fire: aims up, no jump
        ld a,(pm_d1)
        and 1
        add a,4
        ld (pm_d2),a                ; jump: state 4/5
        ld a,0xFF
        ld (p_air),a
pm_b142:
        xor a
        ld (p_jwait),a
        ld a,(pm_d0)
        bit 1,a
        jr z,pm_b170
        ld a,(g_joy)
        bit 4,a
        jr z,pm_crouch
        ld a,(pm_d1)                ; down + fire: state 6/7, next frame
        and 1
        add a,6
        ld (pm_d2),a
        ld (p_pend),a
        xor a
        ld (p_pend+1),a
        jr pm_b170
pm_crouch:
        ld a,(pm_d1)
        call st_c0f
        jr z,pm_b170
        ld a,(pm_d1)
        and 1
        add a,8
        ld (pm_d2),a                ; crouch: state 8/9
pm_b170:
        ld a,(pm_d5)
        cp 8
        jr nz,pm_count
        ld a,3
        ld (p_jwait),a
        ld a,(pm_d0)
        cp 1
        jr z,pm_rise
        xor a                       ; crouched: holds step 4, turning with left/right
        ld (p_rev),a
        ld hl,(p_anim)
        ld de,4
        or a
        sbc hl,de
        jp m,pm_count
        ld a,(pm_d0)
        bit 2,a
        jr z,pm_c8
        ld hl,9
        ld (p_state),hl
pm_c8:  ld a,(pm_d0)
        bit 3,a
        jr z,pm_c4
        ld hl,8
        ld (p_state),hl
pm_c4:  ld hl,4
        ld (p_anim),hl
        jr pm_count
pm_rise:
        ld a,0xFF                   ; up: rises (the animation backwards), stands at step 1
        ld (p_rev),a
        ld hl,(p_anim)
        ld a,h
        or a
        jr nz,pm_count
        ld a,l
        cp 1
        jr nz,pm_count
        ld a,2
        ld (pm_d2),a
pm_count:
        ld a,(p_rev)
        or a
        jr z,pm_fwd
        ld hl,(p_anim)
        dec hl
        bit 7,h
        jr z,pm_aset
        ld hl,(p_last)
        jr pm_aset
pm_fwd: ld hl,(p_anim)
        ld de,(p_last)
        or a
        sbc hl,de
        add hl,de
        jr nz,pm_inc
        ld hl,-1
pm_inc: inc hl
pm_aset:
        ld (p_anim),hl
        ; in the air y += vy / 4 and vy += 2 up to 1Fh; on the ground vy = -14h (a jump's start)
        ld a,(p_air)
        or a
        jr z,pm_ground
        ld hl,(p_vy)
        sra h
        rr l
        sra h
        rr l
        ld de,(p_y)
        add hl,de
        ld (p_y),hl
        ld hl,(p_vy)
        ld de,0x1F
        or a
        sbc hl,de
        jp p,pm_floor
        ld hl,(p_vy)
        inc hl
        inc hl
        ld (p_vy),hl
        jr pm_floor
pm_ground:
        ld hl,-0x14
        ld (p_vy),hl
        ; floors: a lift, else the start cell's attributes (bits 0/2); landing needs vy >= 0
pm_floor:
        call pl_lift
        jr c,pm_b24a
        ld hl,(p_row)
        ld d,l                      ; D = row
        ld e,h                      ; E = column
        call atr_rc
        ld de,(p_y)
        and FLOOR
        ld (p_floor),a
        ld hl,p_floor+1
        ld (hl),0
        jr z,pm_b26a
        ld a,(p_vy+1)
        bit 7,a
        call z,pm_land
        ld a,(p_air)
        or a
        jr nz,pm_b24a
        ld a,e
        and 0xF0                    ; on the cell's top
        ld e,a
        ld (p_y),de
        jr pm_b282
pm_b24a:
        ld (p_y),de
        ld a,(p_vy+1)
        bit 7,a
        call z,pm_land
        jr pm_b282
pm_b26a:
        ld a,(p_air)                ; no floor: falls from rest (state 4/5)
        or a
        jr nz,pm_b282
        ld a,(p_state)
        and 1
        add a,4
        ld (pm_d2),a
        ld a,0xFF
        ld (p_air),a
        ld hl,0
        ld (p_vy),hl
        ; walking or standing states with nothing asked for stand; so does a 2
pm_b282:
        ld a,(pm_d1)
        call st_c0f
        jr z,pm_b28e
        ld a,(pm_d2)
        bit 7,a
        jr nz,pm_stand
pm_b28e:
        ld a,(pm_d2)
        cp 2
        jr nz,pm_change
pm_stand:
        ld a,(pm_d1)
        and 1
        add a,2
        ld (pm_d2),a
pm_change:
        ld a,(pm_d2)
        bit 7,a
        jr nz,pm_cam
        ld hl,p_state
        cp (hl)
        jr nz,pm_new
        inc hl
        ld a,(hl)
        or a
        jr z,pm_cam
        ld a,(pm_d2)
pm_new: ld hl,0
        ld (p_anim),hl
        ld l,a
        ld (p_state),hl
        ld e,a                      ; the state's parameters ($B3AE): $15DF, $15E4, hitbox
        ld d,0
        ld hl,pl_stparm
        add hl,de
        add hl,de
        add hl,de
        ld a,(hl)
        ld (p_de),a
        inc hl
        ld a,(hl)
        ld (p_rev),a
        inc hl
        ld a,(hl)
        ld (p_hb),a
        xor a
        ld (p_hb+1),a
        ; camera: x eases by 1/16 towards x - CAM_DX (0..CAM_XMAX), y by 1/8 towards y - CAM_DY,
        ; or towards -60h when that is above 38h (0..the level's lowest)
pm_cam: ld hl,(p_x)
        ld de,(ac_camdx)            ; (the immediates $B2D8 and $B2FC: obj32 changes them)
        or a
        sbc hl,de
        ld de,(gcam_x)
        or a
        sbc hl,de
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        add hl,de
        bit 7,h
        jr z,pm_cx
        ld hl,0
        jr pm_cxs
pm_cx:  ld de,CAM_XMAX
        or a
        sbc hl,de
        add hl,de
        jr c,pm_cxs
        ex de,hl
pm_cxs: ld (gcam_x),hl
        ld hl,(p_y)
        ld de,(ac_camdy)
        add hl,de
        ld de,0x38
        or a
        sbc hl,de
        add hl,de
        jp p,pm_cy
        ld hl,-0x60
pm_cy:  ld de,(gcam_y)
        or a
        sbc hl,de
        sra h
        rr l
        sra h
        rr l
        sra h
        rr l
        add hl,de
        bit 7,h
        jr z,pm_cy1
        ld hl,0
        jr pm_cys
pm_cy1: ld de,(gcam_ymax)
        or a
        sbc hl,de
        add hl,de
        jp m,pm_cys
        ex de,hl
pm_cys: ld (gcam_y),hl
        ; the start of the level ($15CA clear): standing, aim 2, controls locked; from game frame
        ; 1Ch the arm poses 8..25 (sound 303h every few), then $15CA is set
        ld a,(p_started)
        or a
        jr nz,pm_view
        ld hl,4
        ld (p_aim),hl
        ld hl,0
        ld (p_anim),hl
        ld hl,2
        ld (p_de),hl
        ld (p_state),hl
        ld a,0xFF
        ld (g_lock),a
        ld hl,8
        ld (p_arm),hl
        ld hl,(g_frame)
        ld de,0x1C
        or a
        sbc hl,de
        jp m,pm_view
        ld a,(p_startn)
        ld c,a
        and 0x0B
        jr nz,pm_s1
        ld hl,0x0303
        ld (AM + 0x0B2E),hl         ; (move.w #$303,$B2E)
pm_s1:  ld a,c
        srl a
        add a,8
        ld l,a
        ld h,0
        ld (p_arm),hl
        inc c
        ld a,c
        ld (p_startn),a
        cp 0x25
        jr nz,pm_view
        ld a,0xFF
        ld (p_started),a
        xor a
        ld (p_startn),a
        ld (g_lock),a
        ld hl,0
        ld (p_arm),hl
pm_view:
        jp pl_view

; States 6/7 ($AFB2): at step 8 back to standing; at step 4 the effect of type 8 ahead of him.
pm_afb2:
        ld hl,(p_anim)
        ld a,h
        or a
        jp nz,pm_b170
        ld a,l
        cp 8
        jr nz,pm_a4
        ld a,2
        ld (pm_d2),a
pm_a4:  ld a,l
        cp 4
        jp nz,pm_b170
        ld a,0x14
        ld (snd_b2c),a
        call pl_punch
        jp pm_b170

; Landing: on the ground, standing (state 2 asked for), vy 0, a frame before jumping again.
; Keeps DE.
pm_land:
        xor a
        ld (p_air),a
        ld hl,0
        ld (p_anim),hl
        ld (p_vy),hl
        ld a,2
        ld (pm_d2),a
        ld a,1
        ld (p_jwait),a
        ret

; A = state -> NZ for those of the walking/standing set (bits of $C0F: 0-3, 10, 11).
st_c0f: cp 4
        jr c,sc_yes
        cp 10
        jr z,sc_yes
        cp 11
        jr z,sc_yes
        xor a
        ret
sc_yes: or 1
        ret

; The lift check ($BD72): on lift 3, 2, 1 or 0 (x in [left, right), y in (top - 15, top], not in
; the air going up) -> Carry, DE = top - 4, x moved by the lift's dx, its flag ($167A + index)
; set. The lifts' table (left, right, top, dx, index: 4 words each) is the special objects'.
pl_lift:
        ld b,4
        ld ix,lifts + 6
pli_lp: ld a,(p_air)
        or a
        jr z,pli_x
        ld a,(p_vy+1)
        bit 7,a
        jr nz,pli_next
pli_x:  ld hl,(p_x)
        ld e,(ix+0)
        ld d,(ix+1)
        or a
        sbc hl,de
        jp m,pli_next               ; x < left
        ld hl,(p_x)
        ld e,(ix+8)
        ld d,(ix+9)
        or a
        sbc hl,de
        jp p,pli_next               ; x >= right
        ld l,(ix+16)
        ld h,(ix+17)
        ld de,(p_y)
        or a
        sbc hl,de
        jp m,pli_next               ; top < y
        ld de,15
        or a
        sbc hl,de
        jp p,pli_next               ; top - 15 >= y
        ld e,(ix+16)
        ld d,(ix+17)
        dec de
        dec de
        dec de
        dec de
        ld l,(ix+24)
        ld h,(ix+25)
        push de
        ld de,(p_x)
        add hl,de
        ld (p_x),hl
        ld e,(ix+32)
        ld d,(ix+33)
        ld hl,p_onlift
        add hl,de
        ld a,l
        xor 1
        ld l,a                      ; (byte n at p_onlift + (n ^ 1))
        ld (hl),0xFF
        pop de
        scf
        ret
pli_next:
        dec ix
        dec ix
        djnz pli_lp
        or a
        ret

; -> p_row, p_col: the map cell of (x, y): row y >> 4, column (x >> 4) - 7 (A0 = $37FF2 + ...:
; the map at $38000 starts 7 cells to the right of x = 0).
pl_cellof:
        ld hl,(p_y)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        ld (p_row),a
        ld hl,(p_x)
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        sub 7
        ld (p_col),a
        ret

; The flash of the reversed controls ($F80E with the palette at $1010A). (The effect of states
; 6/7, $AFC4: shots.asm pl_punch.)
pl_flash:
        ld a,PAL_REVERSE
        jp pal_flash

; ----- update_player ($ACEC): the aim -----

; With a direction held, the aim takes the table's value for it every third frame ($1679).
pl_aim:
        ld a,(g_joy)
        and 0x0F
        ret z
        ld hl,p_aimw
        dec (hl)
        ret p
        ld (hl),2
        ld e,a
        ld d,0
        ld hl,pl_aimtab
        add hl,de
        ld a,(hl)
        ld (p_aim),a
        xor a
        ld (p_aim+1),a
        ret

; ----- draw_player ($B94A) -----

; The state's last animation step ($15E8), the frame record (counter / 2; past the state's
; records its last one, where the Amiga would read on) and its hotspot + 8 ($15CC, $15CE). The
; hit spark ($16A0, set by $FA7C) runs down: while it runs, frame (counter & 0Eh) / 2 of it
; ($B4DA) is drawn on him (spk_k, pl_show).
pl_frame:
        ld hl,(AM + 0x16A0)
        ld a,h
        or l
        jr z,pf_spark
        ld a,l
        and 0x0E
        rrca
        inc a                       ; its frame + 1
        dec hl
        ld (AM + 0x16A0),hl
pf_spark:
        ld (spk_k),a
        ld a,(p_state)
        ld e,a
        ld d,0
        ld hl,pl_steps
        add hl,de
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld (p_last),hl
        ld hl,pl_rec0
        add hl,de
        ld c,(hl)
        ld hl,pl_nrec
        add hl,de
        ld b,(hl)
        ld hl,(p_anim)
        srl h
        rr l
        ld a,h
        or a
        jr nz,pf_last
        ld a,l
        cp b
        jr c,pf_rec
pf_last:
        ld a,b
        dec a
pf_rec: add a,c
        ld (p_rec),a
        ld e,a
        ld d,0
        ld hl,pl_hot
        add hl,de
        add hl,de
        ld a,(hl)
        ld (p_hotx),a
        rla
        sbc a,a
        ld (p_hotx+1),a
        inc hl
        ld a,(hl)
        ld (p_hoty),a
        rla
        sbc a,a
        ld (p_hoty+1),a
        ret

; RoboCop's composition (record x aim, or a start-of-level arm pose) and its place on screen,
; and the hit spark, against the view as the scroll engine shows it (after do_update).
pl_show:
        ld a,(p_rec)
        ld c,a
        ld a,(p_arm)
        or a
        jr z,ps_aim
        ld a,c
        cp PL_ARM_REC
        jr nz,ps_aim
        ld a,(p_aim)
        and 6
        cp PL_ARM_AIM*2
        jr nz,ps_aim
        ld a,(p_arm)
        sub PL_ARM_FIRST
        cp SPR_RC_ARMS
        jr nc,ps_aim
        call obj_rc_arm
        jr ps_pos
ps_aim: ld a,(p_aim)
        and 6
        rrca
        call obj_rc
ps_pos: ld hl,(p_x)
        ld de,(p_hotx)
        add hl,de
        ld de,SPR_X_OFS + 8         ; (obj_pos: the view's left edge at screen x 8)
        add hl,de
        ld de,(cam_x)
        or a
        sbc hl,de
        ld (ps_x),hl
        ld hl,(p_y)
        ld de,(p_hoty)
        add hl,de
        ld de,SPR_Y_OFS
        add hl,de
        ld de,(cam_y)
        or a
        sbc hl,de
        ld (ps_y),hl
        ex de,hl
        ld hl,(ps_x)
        xor a
        call obj_pos
        ld a,(spk_k)                ; the hit spark: cut into his buffer at x ($16A2) & -16,
        or a                        ; y ($16A4) ($BB96)
        ld a,SPARK_OBJ
        jp z,obj_hide
        ld a,(spk_k)
        add a,SPR_SPARK - 1
        ld e,a
        ld d,0
        ld a,SPARK_OBJ
        call obj_bob
        ld a,(AM + 0x16A2)
        and 0xF0
        ld e,a
        ld d,0
        ld hl,(ps_x)
        add hl,de
        push hl
        ld a,(AM + 0x16A4)
        ld e,a
        ld hl,(ps_y)
        add hl,de
        ex de,hl
        pop hl
        ld a,SPARK_OBJ
        jp obj_pos

; ----- the view -----

; The MSX shows 256 x 163 of the game's 288 x 176 camera, so its range is a little larger: the
; view runs ahead of the camera in proportion and meets it at both ends of the map,
; v = c + c * VIEW_K / 65536 (VIEW_KX, VIEW_KY from tools/mkrom.py; taken per 16 pixels of c),
; at most the scroll engine's limits. The game's camera follows RoboCop with a lag (1/16 of the
; way a tick in x, 1/8 in y) that its wider view hides: the MSX's keeps him within AX_MIN..
; AX_MAX of the screen (his place as pl_show puts him) and his feet within AY_MIN..AY_MAX of
; the play area. dir_x follows the view (the V9938 engine builds its next page on that side).
AX_MIN:     equ 48
AX_MAX:     equ 160
AY_MIN:     equ 76
AY_MAX:     equ 150
pl_view:
        ld hl,(gcam_x)
        ld de,view_offx
        call pv_add
        ld de,(p_x)
        ld bc,SPR_X_OFS + 8 - AX_MAX
        ld a,AX_MAX - AX_MIN
        call pv_keep
        bit 7,h
        jr z,pv_x0
        ld hl,0
pv_x0:  ld de,CAM_X_MAX
        or a
        sbc hl,de
        add hl,de
        jr c,pv_x
        ex de,hl
pv_x:   ld de,(v_x)
        ld (v_x),hl
        ld (cam_x),hl
        or a
        sbc hl,de
        jr z,pv_y
        ld a,0
        jr nc,pv_xd
        inc a
pv_xd:  ld (dir_x),a
pv_y:   ld hl,(gcam_y)
        ld de,view_offy
        call pv_add
        ld de,(p_y)
        ld bc,0 - AY_MAX
        ld a,AY_MAX - AY_MIN
        call pv_keep
        bit 7,h
        jr z,pv_y0
        ld hl,0
pv_y0:  ld de,CAM_Y_MAX
        or a
        sbc hl,de
        add hl,de
        jr c,pv_y1
        ex de,hl
pv_y1:  ld de,(v_y)
        ld (v_y),hl
        ld (cam_y),hl
        or a
        sbc hl,de
        ret z
        ld a,1
        jr nc,pv_yd
        dec a
pv_yd:  ld (dir_y),a
        ret

; HL = a view coordinate, DE = RoboCop's (p_x or p_y), BC = what puts him at the edge of his
; range (his offset on screen minus its most), A = the range -> HL within DE + BC .. DE + BC + A
; (signed).
pv_keep:
        push hl
        ex de,hl
        add hl,bc
        ex de,hl                    ; DE = the least view (him at the most)
        pop hl
        push hl
        or a
        sbc hl,de
        pop hl
        jp m,pk_de                  ; (less: that one)
        push hl
        ex de,hl
        ld e,a
        ld d,0
        add hl,de
        ex de,hl                    ; DE = the most (him at the least)
        pop hl
        push hl
        or a
        sbc hl,de
        pop hl
        ret m
        ret z
pk_de:  ex de,hl
        ret

; HL = a camera coordinate, DE = its offset table (tools/mkrom.py, rowtab.inc: c * VIEW_K /
; 65536 per 16 pixels) -> HL = c + the entry for c / 16.
pv_add: push hl
        ld a,l
        srl h
        rra
        srl h
        rra
        srl h
        rra
        srl h
        rra
        add a,e
        ld e,a
        jr nc,pva_n
        inc d
pva_n:  ld a,(de)
        pop hl
        add a,l
        ld l,a
        ret nc
        inc h
        ret

; ----- read_joystick ($BDEC) -----

; Unless the controls are locked ($804D): the joystick's bits, else the keyboard's byte. With a
; JOY script (test builds) the script's bits for this game frame, and no keyboard (as on the
; bench, tools/amigaemu.py).
joy_read:
        if INPUT_SCRIPT
        xor a
        else
        call key_bits
        endif
        ld (g_keys),a
        ld a,(g_lock)
        or a
        ret nz
        if INPUT_SCRIPT
        call script_bits
        else
        call stick_bits
        endif
        and 0x7F
        jr nz,jr_set
        ld a,(g_keys)
jr_set: ld (g_joy),a
        ret

; Joystick port 1 -> A: up 1, down 2, left 4, right 8, trigger A 10h (fire), trigger B 20h (as
; the Amiga's F1 / right SHIFT). The MSX bits are already in the Amiga's order.
stick_bits:
        di
        ld a,15
        out (0xA0),a
        in a,(0xA2)
        and 0xBF                    ; port 1
        out (0xA1),a
        ld a,14
        out (0xA0),a
        in a,(0xA2)
        ei
        cpl
        and 0x3F
        ret

; Keyboard -> A: the cursor keys as the joystick; SPACE, RETURN, TAB, ESC, BS and DEL fire; F1 and
; SHIFT 20h (the Amiga's table at $10254: cursor keys, SPACE, RETURN, TAB, ESC, BS, DEL, F1,
; right SHIFT); bit 7 once one of them was pressed ($802D).
key_bits:
        ld b,0
        ld a,8
        call kb_row                 ; RIGHT DOWN UP LEFT DEL INS HOME SPACE
        bit 5,c
        jr z,kb_d
        set 0,b
kb_d:   bit 6,c
        jr z,kb_l
        set 1,b
kb_l:   bit 4,c
        jr z,kb_r
        set 2,b
kb_r:   bit 7,c
        jr z,kb_f
        set 3,b
kb_f:   ld a,c
        and 0x09
        jr z,kb_7
        set 4,b
kb_7:   ld a,7
        call kb_row                 ; RETURN SELECT BS STOP TAB ESC F5 F4
        ld a,c
        and 0xAC
        jr z,kb_6
        set 4,b
kb_6:   ld a,6
        call kb_row                 ; F3 F2 F1 CODE CAPS GRAPH CTRL SHIFT
        ld a,c
        and 0x21
        jr z,kb_end
        set 5,b
kb_end: ld a,(g_keys)
        and 0x80
        or b
        ret z
        or 0x80
        ret

; A = keyboard row -> C = its keys pressed (bit set).
kb_row: ld c,a
        in a,(0xAA)
        and 0xF0
        or c
        out (0xAA),a
        in a,(0xA9)
        cpl
        ld c,a
        ret

        if INPUT_SCRIPT
; The test aids of tools/amigaemu.py game (--tele, --god), at the same point of the frame: a
; teleport for this game frame puts RoboCop at (x, y) and the camera at (x - 108h within
; 0..8E0h, y - 70h from 0); GOD keeps the energy (100h) and the lives (2) full and the level's
; end away ($16C4 = 100h).
script_tick:
        if EXTJOY
        ret                         ; (the Tcl driver does it)
        else
        ld a,(act_a000)
        push af
        ld a,BANK_INPUT
        call bank_a000
        call stk_go
        pop af
        jp bank_a000
stk_go: ld hl,input_tele
stk_lp: ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,d
        and e
        inc a
        jr z,stk_god
        push hl
        ld hl,(tick_n)
        or a
        sbc hl,de
        pop hl
        jr z,stk_tp
        inc hl
        inc hl
        inc hl
        inc hl
        jr stk_lp
stk_tp: ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (p_x),de
        push hl
        ex de,hl
        ld de,-0x108
        add hl,de
        bit 7,h
        jr z,stk_x1
        ld hl,0
stk_x1: ld de,0x8E0
        or a
        sbc hl,de
        add hl,de
        jr c,stk_x2
        ex de,hl
stk_x2: ld (gcam_x),hl
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (p_y),de
        push hl
        ex de,hl
        ld de,-0x70
        add hl,de
        bit 7,h
        jr z,stk_y1
        ld hl,0
stk_y1: ld (gcam_y),hl
        pop hl
        jr stk_lp
stk_god:
        if GOD
        ld hl,0x100
        ld (AM + 0x169A),hl
        ld (AM + 0x16C4),hl
        ld hl,2
        ld (AG + 0x8034),hl
        endif
        ret
        endif

; -> A = the script's bits for game frame tick_n (the ticks since the power-on: a level started
; again does not restart the script): its runs from the one the last call found (or from the
; first, when tick_n went back).
script_bits:
        if EXTJOY
        ld a,(ext_joy)
        ret
        else
        ld a,(act_a000)
        push af
        ld a,BANK_INPUT
        call bank_a000
        ld hl,(tick_n)
        ld de,(sc_start)
        or a
        sbc hl,de
        jr nc,scb_go
        ld hl,input_script          ; back to the first run
        ld (sc_run),hl
        ld hl,0
        ld (sc_start),hl
        ld hl,(tick_n)
scb_go: ex de,hl                    ; DE = frames into the run
        ld hl,(sc_run)
scb_lp: ld c,(hl)
        inc hl
        ld b,(hl)
        ld a,b
        or c
        jr z,scb_end                ; past the script: nothing
        inc hl
        ex de,hl
        or a
        sbc hl,bc
        ex de,hl
        jr c,scb_in
        inc hl                      ; next run
        push hl
        ld hl,(sc_start)
        add hl,bc
        ld (sc_start),hl
        pop hl
        ld (sc_run),hl
        jr scb_lp
scb_in: ld c,(hl)
        jr scb_x
scb_end:
        ld c,0
scb_x:  pop af
        call bank_a000
        ld a,c
        ret
        endif
        endif
