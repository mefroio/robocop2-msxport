; Hardware sprites (sprite mode 2, OR technique): RoboCop and the level's BOBs (enemies, shots,
; explosions...), with the adaptive budget.
;
; Data from tools/msxsprites.py (FORMAT there): compositions (RoboCop: per frame record and
; aim; BOBs: per frame), each a list of 16x16 sprites in SAT order (per band of 16 lines, per
; box: its A sprite, then the B sprite that ORs into it, CC = 1) and its band table (per band:
; its place, A and B sprites and what dropping its OR layer costs). Index and compositions
; through the 8000h window, the pattern and colour pools through A000h.
;
; Objects (obj_tab): object 0 is RoboCop, SPARK_OBJ the hit spark drawn on him, the others BOB
; parts (bob.asm keeps every BOB on the object its identity had: owner and part). The game sets
; each object's composition, silhouette and place; the budget adds the OR layers it drops (or
; leaves it out of the tick): that is the version the object wants. (Objects never alternate
; between frames, the user's rule: the code that took turns in the SAT pairs' second halves went
; on 2026-10-23; the pairs keep their 256 bytes.)
;
; Two sprite sets (colour table + SAT; R#5 switches them with each list) and the 64 pattern slots.
; The main program writes what a list needs as it plans it: the patterns into slots no shown entry
; uses (pat_now), the colour rows and the SAT into the set not on screen (pc_rows, q_sat); the
; VBLANK interrupt then puts the list on screen with its set. Every object shows one version
; (disp) and prepares the version it wants (pend: its patterns go into slots no other entry
; uses, or into the slot that still holds them); once they are all in, its colour rows go to its
; run of SAT entries and the new version replaces the old one in that same frame, so an object
; never shows half of a change, nor another object's frame. A released slot keeps its pattern (pat_held, pat_slot): frames
; that come back cost nothing.
;
; SAT: entries 0-1 the hit spark (in front of RoboCop), RoboCop's run from entry 2, the BOBs'
; runs from entry 31 down (RoboCop's changes of size never move them); an entry no object uses
; is parked on line 200 (HUD: sprites off there). An object's sprites stay together: a B sprite
; (CC) ORs into the A sprite before it on its line.
;
; Budget (on the frame after the game's tick, when an object changed its composition or its
; lines): the VDP shows 8 sprites per line and 32 in all (here 30 besides the spark's two).
; RoboCop and the characters (enemies, lifts, the vehicle) keep their look (the user's rule):
; RoboCop's compositions use at most 5 sprites on a line and the BOBs' at most 3, so a character
; always fits beside him; no object ever alternates between frames. When even the single-layer
; versions pass the total, the least important BOBs are left out of the tick (bg_cut). Then
; every line's sprites are counted (ln_cnt) and a line above 8 makes, in this order, the
; explosions (and the spark) drop an OR layer or go, the shots, enemy bullets, pickups and small
; parts drop one or go (ft_give): an OR layer is a band's (16 lines: its B sprites go, its A
; sprites show one colour per line), the cheapest of its tier there. Then the total (ft_total,
; the same order); only there, as the last resort (RoboCop, an enemy, a lift and the vehicle
; together), a character drops an OR layer, and keeps it dropped until it is hidden (O_HOLD): its
; look changes at most once. Fewer enemies at once (tools/mkrom.py ENEMY_CAP) keep it rare.
; The alternate registers are free for this code: the ISR does not use them.

MAX_OBJ:    equ 16
SPARK_OBJ:  equ MAX_OBJ - 1         ; the hit spark ($16A0, player.asm pl_show): SAT entries 0-1,
                                    ; in front of RoboCop as on the Amiga (cut into his sprites)
OBJ_SIZE:   equ 32
O_FLAGS:    equ 0                   ; bit 7 shown, bit 6 alternating, bit 0 its phase
O_BANK:     equ 1                   ; composition: bank (relative to SPR_BASE_BANK),
O_COMP:     equ 2                   ;   2 bytes: address in the 8000h window
O_DROP:     equ 4                   ; bands whose OR layer is dropped (budget)
O_EC:       equ 5                   ; 80h: its sprites use the early clock; bits 0-1: its silhouette
                                    ; (BM_FLASH, BM_BLACK: one layer, one colour) (O_BANK..O_EC as in a
                                    ; version record)
O_X:        equ 6                   ; 2 bytes: screen x of the composition's top-left
O_Y:        equ 8                   ; 2 bytes: screen y
O_NSPR:     equ 10                  ; composition header (COMP_HDR bytes): sprites,
O_NLINES:   equ 11                  ;   lines covered,
O_NBANDS:   equ 12                  ;   bands,
O_MINDX:    equ 13                  ;   leftmost and rightmost sprite dx,
O_MAXDX:    equ 14
O_NA:       equ 15                  ;   sprites of its single-layer version,
O_MFULL:    equ 16                  ;   most sprites on a line,
O_MONE:     equ 17                  ;   the same on one layer
O_KIND:     equ 18                  ; 0 RoboCop, 1 BOB (O_KIND, O_ID as in a version record)
O_ID:       equ 19                  ; 2 bytes: record * 4 + aim, or BOB frame
O_BANDT:    equ 21                  ; 2 bytes: its band table (8000h window)
O_TIER:     equ 25                  ; budget: 3 RoboCop (never touched), 2 the spark and the
                                    ;   explosions, 1 shots, enemy bullets, pickups, small parts,
                                    ;   0 the characters (enemies, lifts, the vehicle),
O_GONE:     equ 26                  ;   sprites its dropped bands remove,
O_OUT:      equ 27                  ;   1: left out this tick,
O_HOLD:     equ 28                  ;   a character's bands dropped for good (the total's last resort)
O_BMASK:    equ 30                  ; its bands that have B sprites
LAY_SIZE:   equ 16                  ; version record (disp: shown; pend: being prepared):
V_ON:       equ 0                   ;   80h: present,
V_BANK:     equ 1                   ;   bank, composition (2), dropped columns, early clock and
V_COMP:     equ 2                   ;   silhouette (as O_BANK..O_EC),
V_DROP:     equ 4                   ;   (bands)
V_EC:       equ 5
V_RUN:      equ 6                   ;   its first SAT entry (disp),
V_N:        equ 7                   ;   entries,
V_KIND:     equ 8                   ;   kind, id (2) (as O_KIND, O_ID),
V_ID:       equ 9
V_PAGE:     equ 11                  ;   which of the object's two entry pages holds its entries,
V_MINDX:    equ 12                  ;   min dx, max dx,
V_MAXDX:    equ 13
                                    ;   (14: spare)
V_LINES:    equ 15                  ;   lines
EC_ON:      equ 32                  ; early clock on when the leftmost sprite's x falls below this,
EC_OFF:     equ 64                  ;   off from this (ahead of time)
ENT_SIZE:   equ 8                   ; entry: dy, dx, pattern number, slot, pattern id (2),
                                    ; colour id | 8000h early clock (2)
ENT_PAGE:   equ ent_pages/256       ; page of object o, version page v: ENT_PAGE + 2 o + v
SPR_SLOTS:  equ 64                  ; 16x16 patterns in the pattern table (2 KiB at SPR_PAT)
PAT_HINTS:  equ 1024                ; pat_slot entries: a hint per pattern id & 3FFh (pat_held
                                    ; tells whether the slot still holds that id)
SLOT_LOAD:  equ 0x80                ; slot_ref bit: its pattern (pat_held) is still to be queued
LINE_LIMIT: equ 8
RC_LINE:    equ 5                   ; the most sprites on a line of any composition of RoboCop's
                                    ; (tools/msxsprites.py RC_CAP: his OR layers are never dropped)
SAT_MAX:    equ 32
BUD_MAX:    equ SAT_MAX - 2         ; the budget's total: entries 0-1 stay the spark's (the BOBs'
                                    ; runs are packed when no hole fits: sat_pack)
RC_HOLD:    equ 120                 ; VBLANKs RoboCop's largest recent sprite count holds (budget)
RC_RUN:     equ 2                   ; RoboCop's first SAT entry
PARK_LINE:  equ 200                 ; screen line of parked sprites (HUD: sprites off there)
COMP_HDR:   equ 8                   ; composition: nspr, nlines, nbands, min dx, max dx, A sprites,
                                    ; most sprites on a line, the same on one layer
REC_SIZE:   equ 12                  ; sprite record: dy, dx, park bit, A1 bit, 4 words
BAND_SIZE:  equ 4                   ; band table entry: dy, A sprites, B sprites, gain
UP_TOTAL:   equ 400                 ; work per frame (units of about 100 T-states) that the HUD,
                                    ; the game logic and the sprite engine share (hud_cost +
                                    ; spr_cost; kept for the HUD's own pacing):
COST_BUDGET: equ 100                ;   the budget
HUD_HEAVY:  equ 90                  ; HUD work (units) from which the layout of a tick waits
; At a level's start (engines_init): nothing shown, every slot and colour row unknown (spr_init,
; cold.asm: in the front end's bank).
sprites_init:
        ld a,(act_8000)
        push af
        ld hl,spr_init
        call front_call
        pop af
        jp bank_8000

; During long work: the scroll engine's idle work (its next VDP command when the command engine
; is free), so that the VDP does not wait for the end of the frame. Keeps all registers but the
; A000h window (the upload maps it before each use).
feed_vdp:
        push af
        ld a,(fb_busy)              ; nothing to feed: no play-field BOB work (field.asm) and no
        or a                        ; scroll work since the engine last found none (iw_more); in
        jr nz,fv_chk                ; normal play 96 % of the calls, 25 a picture, end here
        ld a,(iw_more)
        or a
        jr nz,fv_chk
        pop af
        ret
fv_chk: di                          ; (both engines' work starts with vdp_busy: while a command
        ld a,2                      ; runs there is nothing to do, so that is looked at first)
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a
        in a,(VDP_CTRL)             ; S#2
        push af
        xor a
        out (VDP_CTRL),a
        ld a,0x8F
        out (VDP_CTRL),a            ; R#15 = 0
        ei
        pop af
        rrca                        ; (CE)
        jr nc,fv_go
        pop af
        ret
fv_go:  push bc
        push de
        push hl
        push ix                     ; (the play-field BOBs' work uses IX and IY: field.asm)
        push iy
        ld hl,(act_8000)            ; (act_8000, act_a000: the tile cache maps its banks; the
        push hl                     ; game logic calls this from code in both windows)
        call idle_work
        pop hl
        ld a,(act_8000)
        cp l
        ld a,l
        call nz,bank_8000
        ld a,(act_a000)
        cp h
        ld a,h
        call nz,bank_a000
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ret

; HL = address, BC = bytes (at least 1), A = value.
fill:   ld (hl),a
        dec bc
        ld a,b
        or c
        ret z
        ld d,h
        ld e,l
        inc de
        ldir
        ret

; Right after the VBLANK that put the last published frame on screen (wait_frame): a new frame
; for the work counts.
sprites_vblank:
        xor a
        ld (spr_cost),a
        ret

; ----- objects -----

; A = object -> IX = its entry. Keeps BC, DE. (obj_tab is 256-byte aligned: 32 o is
; o >> 3 in the high byte and (o & 7) << 5 in the low one.)
obj_ix:
        rrca
        rrca
        rrca
        ld l,a
        and 0x1F
        add a,obj_tab / 256
        ld h,a
        ld a,l
        and 0xE0
        ld l,a
        push hl
        pop ix
        ret

; IX = object -> HL = its composition, its bank mapped at 8000h. Keeps BC, DE.
obj_comp:
        ld a,(ix+O_BANK)
        add a,SPR_BASE_BANK
        call bank_8000
        ld l,(ix+O_COMP)
        ld h,(ix+O_COMP+1)
        ret

; C = record, A = aim: RoboCop (object 0) takes that composition.
obj_rc:
        ld hl,os_mode
        ld (hl),0
        ld ix,obj_tab
        ld l,c
        ld h,0
        add hl,hl
        add hl,hl
        ld e,a
        ld d,0
        add hl,de                   ; record * 4 + aim
        xor a                       ; kind 0
        jr obj_set

; A = start-of-level arm pose - PL_ARM_FIRST: RoboCop takes that composition (SPR_RC_ARM + A).
obj_rc_arm:
        ld hl,os_mode
        ld (hl),0
        ld ix,obj_tab
        ld l,a
        ld h,0
        ld de,SPR_RC_ARM
        add hl,de
        xor a
        jr obj_set

; A = object, DE = BOB frame: that object takes the frame's composition.
obj_bob:
        ld hl,os_mode
        ld (hl),0
        call obj_ix
        ex de,hl
        ld a,1                      ; kind 1

; IX = object, HL = id, A = kind, os_mode = its silhouette (0: none): the object takes that
; composition (nothing to do when it already shows it so) and is shown. A silhouette shows the
; single-layer patterns (every column's OR layer dropped) with one colour row (lb_fill).
obj_set:
        bit 7,(ix+O_FLAGS)
        jr z,os_new
        cp (ix+O_KIND)
        jr nz,os_new
        ld e,a
        ld a,l
        cp (ix+O_ID)
        jr nz,os_kind
        ld a,h
        cp (ix+O_ID+1)
        jr nz,os_kind
        ld a,(ix+O_EC)              ; the same composition: and the same silhouette?
        and 3
        ld c,a
        ld a,(os_mode)
        cp c
        ret z
        jp os_mode_set
os_kind:
        ld a,e
os_new: ld (ix+O_KIND),a
        ld (ix+O_ID),l
        ld (ix+O_ID+1),h
        ld (ix+O_DROP),0            ; all its OR layers again
        ld (ix+O_GONE),0
        ld d,h
        ld e,l
        add hl,hl
        add hl,de                   ; *3: index entry
        or a
        ld de,0x8000                ; RoboCop's index
        jr z,os_idx
        ld de,SPR_BOB_INDEX
os_idx: add hl,de
        ld a,SPR_BASE_BANK
        call bank_8000
        ld a,(hl)
        ld (ix+O_BANK),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,0x8000
        add hl,de
        ld (ix+O_COMP),l
        ld (ix+O_COMP+1),h
        call obj_comp
        push ix
        pop de
        ld a,e
        add a,O_NSPR
        ld e,a                      ; (an obj_tab entry does not cross a 256-byte boundary)
        ld bc,COMP_HDR
        ldir                        ; the header; HL = first sprite record
        ld a,(ix+O_NSPR)
        ld e,a
        add a,a
        add a,e                     ; *3
        ld e,a
        ld d,0
        ex de,hl
        add hl,hl
        add hl,hl                   ; *12
        add hl,de                   ; rank list
        ld d,0
        ld (ix+O_BANDT),l           ; its band table, after the records
        ld (ix+O_BANDT+1),h
        ld a,1
        ld (bu_dirty),a             ; (the budget looks at the composition)
        ld b,(ix+O_NBANDS)
        ld c,0
        ld e,1
os_bm:  inc hl                      ; the bands with B sprites
        inc hl
        ld a,(hl)
        or a
        jr z,os_bn
        ld a,c
        or e
        ld c,a
os_bn:  inc hl
        inc hl
        sla e
        djnz os_bm
        ld (ix+O_BMASK),c
        set 7,(ix+O_FLAGS)
        call fl_on                  ; (the plan's look visits it: pl_fl)
os_mode_set:
        ld a,(ix+O_EC)
        and 0x80
        ld c,a
        ld a,(os_mode)
        or c
        ld (ix+O_EC),a
        ld a,1
        ld (bu_dirty),a             ; (the budget looks at the dropped columns)
        ld a,(os_mode)
        or a
        jr z,osm_full
        ld a,(ix+O_BMASK)           ; a silhouette: every OR layer dropped
        ld (ix+O_DROP),a
        ld a,(ix+O_NSPR)
        sub (ix+O_NA)
        ld (ix+O_GONE),a
        ret
osm_full:
        ld (ix+O_DROP),0            ; all its OR layers again
        ld (ix+O_GONE),0
        ret

; A = object: no longer shown.
obj_hide:
        call obj_ix
        bit 7,(ix+O_FLAGS)
        ret z
        ld (ix+O_FLAGS),0
        ld (ix+O_HOLD),0            ; (its look is decided anew when it shows again)
        ld a,1
        ld (bu_dirty),a
        jp fl_off                   ; (the plan's look visits it once more, then no longer)

; The objects wanted (O_FLAGS bit 7), one bit each (pl_fl): the plan's look visits only those and
; the ones wanted at its last run (pl_flp); any other shows and prepares nothing and keeps
; pl_st and pl_gs 0, so that visit would do nothing (measured: 2.1 of the 16 objects live in play).
; IX = the object -> DE = its bit, HL = pl_fl. Keeps BC.
fl_bit: push ix
        pop hl
        ld a,h
        sub obj_tab / 256           ; (obj_tab: 256-byte aligned, OBJ_SIZE 32)
        add a,a
        add a,a
        add a,a
        ld e,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or e
        add a,a
        add a,fl_bits & 0xFF
        ld l,a
        adc a,fl_bits / 256
        sub l
        ld h,a
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,pl_fl
        ret
fl_on:  call fl_bit
        ld a,(hl)
        or e
        ld (hl),a
        inc hl
        ld a,(hl)
        or d
        ld (hl),a
        ret
fl_off: call fl_bit
        ld a,e
        cpl
        and (hl)
        ld (hl),a
        inc hl
        ld a,d
        cpl
        and (hl)
        ld (hl),a
        ret
fl_bits:
        dw 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768

; A = object, HL = screen x, DE = screen y of its composition's top-left (obj_pos_ix: IX =
; the object).
obj_pos:
        push hl
        call obj_ix
        pop hl
obj_pos_ix:
        ld (ix+O_X),l
        ld (ix+O_X+1),h
        ld a,e
        cp (ix+O_Y)
        jr nz,op_y
        ld a,d
        cp (ix+O_Y+1)
        ret z
op_y:   ld (ix+O_Y),e               ; (the budget counts its lines again)
        ld (ix+O_Y+1),d
op_d:   ld a,1
        ld (bu_dirty),a
        ret


; ----- tick -----

; After the game moved the objects (and the camera): the next SAT shows them where they are.
sprites_moved:
        ld a,1
        ld (sat_dirty),a
        ret

; The camera the tick's placement (pl_show, bob_flush) takes the objects' screen places against.
cam_mark:
        ld hl,(cam_x)
        ld (sp_cam_x),hl
        ld hl,(cam_y)
        ld (sp_cam_y),hl
        ret

; A frame without a tick whose update moved the camera (the scroll engine catching up with the
; view the game wants): every shown object moves on the screen by the camera's step, where the
; tick's placement would have put it, and the SAT follows (else the picture shows the sprites
; against the last tick's camera, off the background by that step).
cam_follow:
        ld hl,(sp_cam_x)
        ld de,(cam_x)
        or a
        sbc hl,de
        ld b,h
        ld c,l                      ; BC = the step in x (old camera - new)
        ld hl,(sp_cam_y)
        ld de,(cam_y)
        or a
        sbc hl,de
        ex de,hl                    ; DE = the step in y
        ld a,b
        or c
        or d
        or e
        ret z                       ; (the camera did not move)
        call cam_mark
        ld ix,obj_tab
        ld a,MAX_OBJ
cf_lp:  push af
        bit 7,(ix+O_FLAGS)
        jr z,cf_next
        push de
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        add hl,de
        ex de,hl                    ; DE = its new y
        ld l,(ix+O_X)
        ld h,(ix+O_X+1)
        add hl,bc                   ; HL = its new x
        call obj_pos_ix
        pop de
cf_next:
        push de
        ld de,OBJ_SIZE
        add ix,de
        pop de
        pop af
        dec a
        jr nz,cf_lp
        call sprites_moved
        jp sprites_tick

; On the frame after the game's tick: the budget, unless nothing it looks at changed since it
; last ran (then only the early clocks follow x).
sprites_tick:
        ld a,(bu_dirty)
        or a
        jp z,obj_ecs
        xor a
        ld (bu_dirty),a
        call budget
        call feed_vdp
        ld a,COST_BUDGET
        jp spr_charge

; The early clock of every shown object (obj_ec).
obj_ecs:
        ld ix,obj_tab
        ld b,MAX_OBJ
oe_lp:  bit 7,(ix+O_FLAGS)
        call nz,obj_ec
        ld de,OBJ_SIZE
        add ix,de
        djnz oe_lp
        ret

; ----- budget -----

; The BOB objects in their order of importance, for the budget and the plan (bu_ord, FFh after
; the last): lifts and the vehicle (RoboCop stands on them), enemies, their bullets, pickups,
; RoboCop's shots and effects, explosions (bob.asm categories; within one, object order).
bu_order:
        xor a
        ld (bo_dirty),a
        ld hl,bo_pos                ; per rank: its count, then where its objects go
        ld b,BO_RANKS
        xor a
boz:    ld (hl),a
        inc hl
        djnz boz
        ld hl,obj_key + 4 + 3       ; (object 1's category + 1)
        ld b,SPARK_OBJ - 1
boc:    ld a,(hl)                   ; its rank
        add a,bo_rank & 0xFF
        ld e,a
        adc a,bo_rank / 256
        sub e
        ld d,a
        ld a,(de)
        cp BO_RANKS
        jr nc,boc_n                 ; (no identity)
        add a,bo_pos & 0xFF
        ld e,a
        ld d,bo_pos / 256
        ex de,hl
        inc (hl)
        ex de,hl
boc_n:  inc l
        inc l
        inc l
        inc l
        djnz boc
        ld hl,bo_pos                ; counts -> the first place of each rank
        ld b,BO_RANKS
        ld c,0
bop:    ld a,(hl)
        ld (hl),c
        add a,c
        ld c,a
        inc hl
        djnz bop
        ld a,c                      ; (the end)
        add a,bu_ord & 0xFF
        ld l,a
        ld h,bu_ord / 256
        ld (hl),0xFF
        ld hl,obj_key + 4 + 3
        ld c,1                      ; object
bow:    ld a,(hl)
        add a,bo_rank & 0xFF
        ld e,a
        adc a,bo_rank / 256
        sub e
        ld d,a
        ld a,(de)
        cp BO_RANKS
        jr nc,bow_n
        add a,bo_pos & 0xFF
        ld e,a
        ld d,bo_pos / 256
        ld a,(de)                   ; its place
        inc a
        ld (de),a
        dec a
        add a,bu_ord & 0xFF
        ld e,a
        ld d,bu_ord / 256
        ld a,c
        ld (de),a
bow_n:  inc l
        inc l
        inc l
        inc l
        inc c
        ld a,c
        cp SPARK_OBJ
        jr c,bow
        ret
BO_RANKS:   equ 6
bo_rank:    db 0xFF                 ; per category + 1 (bob.asm BC_...): its rank (FFh: none)
        db 2, 1, 3, 4, 0, 5         ; enemy bullets, enemies, pickups, effects, lifts and the
                                    ; vehicle, explosions

budget:
        ld a,(bo_dirty)             ; (only when an identity changed: bob.asm bf_key, bf_hide)
        or a
        call nz,bu_order
        xor a
        ld (ft_lok),a               ; (the give-way's lists: built at the first give)
        ld (bu_tot),a
        ld (bu_one),a
        ld (bu_cut),a
        ld (bu_wsum),a
        ld ix,obj_tab
        ld b,MAX_OBJ
bg_r:   push bc
        xor a
        ld (ix+O_OUT),a
        ld a,(ix+O_FLAGS)
        and 0x80
        ld (ix+O_FLAGS),a           ; (not alternating)
        jr z,bg_rn                  ; (not shown)
        call bg_tier
        call bg_drops
        call obj_ec
        ld hl,bu_tot                ; the totals: with what it drops, and on one layer
        ld a,(ix+O_NSPR)
        sub (ix+O_GONE)
        add a,(hl)
        ld (hl),a
        inc hl
        ld a,(hl)
        add a,(ix+O_NA)
        ld (hl),a
        ld a,(bu_wsum)              ; (the bands of a composition lie one under the other, so
        add a,(ix+O_MFULL)          ;  O_MFULL bounds its count on every line: no line can pass
        ld (bu_wsum),a              ;  8 while these sum to 8 at most)
bg_rn:  ld de,OBJ_SIZE
        add ix,de
        pop bc
        djnz bg_r
        ld ix,obj_tab + SPARK_OBJ * OBJ_SIZE ; the spark has SAT entries 0-1 of its own: it counts
        bit 7,(ix+O_FLAGS)          ; in no total (BUD_MAX: the others')
        jr z,bg_sp
        ld hl,bu_tot
        ld a,(hl)
        sub (ix+O_NSPR)
        add a,(ix+O_GONE)
        ld (hl),a
        inc hl
        ld a,(hl)
        sub (ix+O_NA)
        ld (hl),a
bg_sp:  ld ix,obj_tab               ; RoboCop (whole: nothing of his is ever dropped) counts with
        bit 7,(ix+O_FLAGS)          ; the largest of his recent versions (held RC_HOLD VBLANKs),
        jr z,bg_rc1                 ; so that what the BOBs drop does not change with each of
        if LOCKSTEP
        ld a,(last_tick)            ; (test builds: the frame's start, not the VBLANK count
        else                        ;  at this moment: exact display comparisons)
        ld a,(tick)                 ; his frames
        endif
        ld hl,rc_hold_t
        sub (hl)
        cp RC_HOLD
        ld a,(ix+O_NSPR)
        ld hl,rc_hold
        jr nc,bg_rhn                ; (held long enough: what he has now)
        cp (hl)
        jr c,bg_rhk                 ; (fewer than the one held)
bg_rhn: ld (hl),a
        if LOCKSTEP
        ld a,(last_tick)
        else
        ld a,(tick)
        endif
        ld (rc_hold_t),a
bg_rhk: ld a,(hl)
        sub (ix+O_NSPR)
        ld c,a                      ; (what the hold adds to what he shows)
        ld hl,bu_tot
        add a,(hl)
        ld (hl),a
        inc hl
        ld a,(ix+O_NSPR)            ; on one layer too
        sub (ix+O_NA)
        add a,c
        add a,(hl)
        ld (hl),a
bg_rc1: ld a,(bu_one)
        cp BUD_MAX + 1
        call nc,bg_cut
        call feed_vdp
        ld ix,obj_tab               ; RoboCop counts RC_LINE on every line whatever versions he
        ld a,(bu_wsum)              ; wants, shows and prepares (ln_rc): his O_MFULL is only the
        bit 7,(ix+O_FLAGS)          ; wanted one's
        jr z,bg_ws
        sub (ix+O_MFULL)
bg_ws:  cp LINE_LIMIT - RC_LINE + 1
        jr c,bg_tot                 ; no line can pass 8: nothing to count (82 % of the runs in
        call ln_fill                ; every line's sprites                         normal play)
        call ft_lines               ; the line phase
bg_tot: call feed_vdp
        jp ft_total                 ; the total phase

; IX = shown object -> O_TIER: 3 RoboCop (never touched), 2 the spark and the explosions (they
; give way first), 1 shots, enemy bullets, pickups and the characters' small parts, 0 the
; characters (enemies, lifts, the vehicle: never left out, their look fixed). Keeps BC.
bg_tier:
        push ix
        pop hl
        ld a,h
        sub obj_tab / 256
        rlca
        rlca
        rlca                        ; (8 objects a page)
        ld e,a
        ld a,l
        rlca
        rlca
        rlca
        and 7
        or e                        ; the object
        ld e,3
        or a
        jr z,bt_s                   ; (RoboCop)
        dec e
        cp SPARK_OBJ
        jr z,bt_s
        add a,a
        add a,a
        add a,(obj_key + 3) & 0xFF
        ld l,a
        ld h,obj_key / 256          ; (obj_key does not cross a 256-byte boundary)
        ld a,(hl)                   ; its category + 1 (0: none)
        add a,bo_rank & 0xFF
        ld l,a
        adc a,bo_rank / 256
        sub l
        ld h,a
        ld a,(hl)                   ; its rank (FFh: none)
        ld e,1
        cp BO_RANKS
        jr nc,bt_s                  ; (none: as a shot)
        add a,bo_tier & 0xFF
        ld l,a
        adc a,bo_tier / 256
        sub l
        ld h,a
        ld e,(hl)
        ld a,e                      ; a character's small part (16 px: the vehicle's jets) gives
        or a                        ; way as a shot
        jr nz,bt_s
        ld a,(ix+O_NSPR)
        cp 3
        jr nc,bt_s
        inc e
bt_s:   ld (ix+O_TIER),e
        ret
bo_tier:    db 0, 0, 1, 1, 1, 2     ; per rank: lifts and the vehicle, enemies, enemy bullets,
                                    ; pickups, effects, explosions

; IX = shown object -> O_DROP, O_GONE for this run: a silhouette drops every OR layer; else the
; bands a character had to drop once (O_HOLD: the total phase's last resort) stay dropped until
; it is hidden or changes owner: its look changes at most once. The phases drop what this run
; needs on top (effects only). Keeps BC.
bg_drops:
        ld a,(ix+O_EC)
        and 3
        jr z,bd_held
        ld a,(ix+O_BMASK)           ; a silhouette
        ld (ix+O_DROP),a
        ld a,(ix+O_NSPR)
        sub (ix+O_NA)
        ld (ix+O_GONE),a
        ret
bd_held:
        ld a,(ix+O_HOLD)
        and (ix+O_BMASK)
bd_set: ld (ix+O_DROP),a
        ld (ix+O_GONE),0
        or a
        ret z
        push bc
        call ft_map
        ld l,(ix+O_BANDT)
        ld h,(ix+O_BANDT+1)
        ld b,(ix+O_NBANDS)
        ld c,1
        ld e,0                      ; the B sprites of the bands dropped
bd_lp:  inc hl
        inc hl
        ld a,c
        and (ix+O_DROP)
        jr z,bd_n
        ld a,(hl)
        add a,e
        ld e,a
bd_n:   inc hl
        inc hl
        sla c
        djnz bd_lp
        ld (ix+O_GONE),e
        pop bc
        ret

; IX = shown object: its early clock (O_EC = 80h), on when its leftmost sprite's x (without it)
; falls below EC_ON, off from EC_OFF, as it was in between. Keeps BC.
obj_ec: ld a,(ix+O_MINDX)
        ld e,a
        rla
        sbc a,a
        ld d,a
        ld l,(ix+O_X)
        ld h,(ix+O_X+1)
        add hl,de
        ld a,(spr_xadj)
        ld e,a
        rla
        sbc a,a
        ld d,a
        add hl,de
        bit 7,h
        jr nz,oec_on
        ld a,h
        or a
        jr nz,oec_off
        ld a,l
        cp EC_ON
        jr c,oec_on
        cp EC_OFF
        ret c
oec_off:
        res 7,(ix+O_EC)
        ret
oec_on: set 7,(ix+O_EC)
        ret

; IX = object -> NC when it is shown and not left out. Keeps BC, DE.
ft_live:
        bit 7,(ix+O_FLAGS)
        scf
        ret z
        ld a,(ix+O_OUT)
        cp 1
        ccf
        ret

; IX = object: its composition's bank at 8000h. Keeps BC, DE, HL.
ft_map: ld a,(ix+O_BANK)
        add a,SPR_BASE_BANK
        jp bank_8000

; Even with every OR layer dropped the objects pass BUD_MAX sprites: after RoboCop (counted
; with rc_hold), the BOBs in their order of importance (bu_ord): those that do not fit then
; are left out this tick (O_OUT); bu_cut = 1.
bg_cut: ld a,1
        ld (bu_cut),a
        ld a,(rc_hold)
        ld c,a                      ; one-layer sprites of the objects kept (RoboCop always,
        ld hl,bu_ord                ; whole; the spark is never left out here: entries 0-1),
cut_lp: ld a,(hl)                   ; the BOBs in their order of importance
        cp 0xFF
        ret z
        push hl
        call obj_ix
        call cut_obj
        pop hl
        inc hl
        jr cut_lp

; IX = object, C = the one-layer sprites kept so far (bg_cut): kept when it fits, else left out.
; Keeps B.
cut_obj:
        bit 7,(ix+O_FLAGS)
        ret z
        ld a,c
        add a,(ix+O_NA)
        cp BUD_MAX + 1
        jr nc,cut_out
        ld c,a
        ret
cut_out:
        ld (ix+O_OUT),1
        ld a,(bu_tot)
        sub (ix+O_NSPR)
        add a,(ix+O_GONE)
        ld (bu_tot),a
        ret

; ----- the line and total phases (RoboCop is never touched, no object alternates) -----

; Every line's sprites (ln_cnt + line, for the lines of the play area): every object shown and
; not left out, band by band (A sprites, and B sprites unless its band dropped them).
ln_fill:
        ld hl,ln_cnt
        ld b,VIEW_LINES
        xor a
lf_z:   ld (hl),a
        inc l
        djnz lf_z
        call ln_rc
        ld ix,obj_tab + OBJ_SIZE    ; (the BOBs)
        ld b,MAX_OBJ - 1
lf_lp:  push bc
        call ft_live
        ld c,0
        call nc,ln_obj
        ld de,OBJ_SIZE
        add ix,de
        pop bc
        djnz lf_lp
        ret

; RoboCop's lines (on an empty ln_cnt): per line the most of the versions he wants, shows and
; prepares, whole (his new frame goes on screen a picture or two after the budget planned for
; it: counted so, the BOBs never take the line his old frame still needs).
ln_rc:  ld ix,obj_tab
        bit 7,(ix+O_FLAGS)
        ret z
        ld l,(ix+O_COMP)
        ld h,(ix+O_COMP+1)
        ld a,(ix+O_BANK)
        ld e,0
        call ln_ver                 ; the one he wants
        ld iy,disp
        call ln_rcv                 ; the one shown
        ld iy,pend
ln_rcv: ld a,(iy+V_ON)
        or a
        ret z
        push iy                     ; its place: the hotspot of its record against the one the
        call sb_rcdy                ; game asked for (sat_build does the same: sb_rchot)
        pop iy
        ld e,a
        ld l,(iy+V_COMP)
        ld h,(iy+V_COMP+1)
        ld a,(iy+V_BANK)

; A = bank, HL = a composition of RoboCop's, E = its y against O_Y (signed): every line its bands
; cover gets at least their sprites.
ln_ver: push de
        add a,SPR_BASE_BANK
        call bank_8000
        ld b,(hl)                   ; nspr
        inc hl
        inc hl
        ld c,(hl)                   ; nbands
        ld a,b
        add a,a
        add a,b                     ; * 3
        ld e,a
        ld d,0
        ex de,hl
        add hl,hl
        add hl,hl                   ; * 12
        ld a,COMP_HDR - 2
        add a,l
        ld l,a
        jr nc,lv_a
        inc h
lv_a:   add hl,de                   ; its band table
        pop de
        ld b,c
lv_lp:  push bc
        push hl
        ld a,(hl)                   ; dy
        add a,e                     ; (+ the version's offset: small)
        push de
        ld e,a
        inc hl
        ld a,(hl)
        inc hl
        add a,(hl)                  ; A + B sprites
        ld c,a
        call ln_first
        call ln_span
        jr z,lv_n
        ld h,ln_cnt / 256
lv_l:   ld a,(hl)
        cp c
        jr nc,lv_k
        ld (hl),c
lv_k:   inc l
        djnz lv_l
lv_n:   pop de
        pop hl
        inc hl
        inc hl
        inc hl
        inc hl
        pop bc
        djnz lv_lp
        ret

; IX = object, C = 0 to add its sprites to their lines, 1 to take them away.
ln_obj: ld a,c
        ld (ln_neg),a
        call ft_map
        ld l,(ix+O_BANDT)
        ld h,(ix+O_BANDT+1)
        ld b,(ix+O_NBANDS)
        ld c,1                      ; its bit
lo_lp:  push bc
        ld e,(hl)                   ; dy
        inc hl
        ld a,c
        and (ix+O_DROP)
        ld a,(hl)                   ; A sprites
        inc hl
        jr nz,lo_d
        add a,(hl)                  ; + B sprites
lo_d:   inc hl
        inc hl
        push hl
        call ln_add
        pop hl
        pop bc
        sla c
        djnz lo_lp
        ret

; IX = object, E = a band's dy, A = sprites: they go to (ln_neg 0) or leave the band's lines.
ln_add: ld c,a
        ld a,(ln_neg)
        or a
        jr z,la_p
        xor a
        sub c
        ld c,a
la_p:   call ln_first
        call ln_span
        ret z
        ld h,ln_cnt / 256
la_lp:  ld a,(hl)
        add a,c
        ld (hl),a
        inc l
        djnz la_lp
        ret

; IX = object, E = a band's dy -> HL = the band's first line (signed). Keeps BC.
ln_first:
        ld a,e
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        rla
        sbc a,a
        ld d,a
        add hl,de
        ret

; HL = a band's first line (signed) -> L = its first line in the play area, B = its lines there
; (Z: none). Keeps C, DE.
ln_span:
        ld b,16
        ld a,h
        or a
        jr z,ls_in
        inc a
        jr nz,ls_no                 ; (from 256 on, or below -256)
        ld a,l
        add a,b
        jr nc,ls_no                 ; (-17 or less)
        ld l,0
        ld b,a
        or a                        ; (Z: -16)
        ret
ls_in:  ld a,l
        cp VIEW_LINES
        jr nc,ls_no
        add a,b
        sub VIEW_LINES
        jr c,ls_ok                  ; (it ends inside)
        neg
        add a,b
        ld b,a
ls_ok:  or 1                        ; (NZ)
        ret
ls_no:  xor a
        ret

; The line phase: from the top, a line with more than 8 sprites makes something give way
; (ft_give) until it has 8, or until nothing that may can (the VDP then hides its last
; sprites: never RoboCop's, whose run comes first in the SAT).
ft_lines:
        ld hl,ln_cnt
        ld b,VIEW_LINES
fl_lp:  ld a,(hl)
        cp LINE_LIMIT + 1
        jr nc,fl_hit
fl_nx:  inc l
        djnz fl_lp
        ret
fl_hit: ld a,l
        ld (ft_line),a
        push bc
        call ft_give
        pop bc
        ld a,(ft_line)
        ld l,a
        ld h,ln_cnt / 256
        jr nc,fl_lp                 ; (the same line again)
        jr fl_nx

; The total phase: while the objects (but the spark) pass BUD_MAX sprites, something gives way
; as on a line (ft_line FFh: anywhere).
ft_total:
        ld a,0xFF
        ld (ft_line),a
ftt_lp: ld a,(bu_tot)
        cp BUD_MAX + 1
        ret c
        call ft_give
        jr nc,ftt_lp
        ret

; Something gives way on line ft_line (FFh: in the total), the first that can of: an OR layer of
; the explosions (and the spark), one of them left out, an OR layer of the shots, enemy bullets,
; pickups and small parts, one of them left out; in the total only, as the last resort, an OR
; layer of a character (dropped for good: its look changes at most once; their compositions fit
; beside RoboCop on any line, so a line never needs it). The OR layer dropped is the cheapest of
; the tier there (its band's gain: what its colours are worth). C when nothing can.
ft_give:
        ld a,2
        call ft_drop_t
        ret nc
        ld a,2
        call ft_leave_t
        ret nc
        ld a,1
        call ft_drop_t
        ret nc
        ld a,1
        call ft_leave_t
        ret nc
        ld a,(ft_line)
        inc a
        scf
        ret nz                      ; (a line: the VDP hides its last sprites, never RoboCop's)
        jp ft_drop_t                ; (A = 0: the characters)

; A = tier: the cheapest OR layer of a band of an object of that tier on line ft_line (FFh:
; anywhere, the spark excluded) is dropped. C when there is none. (The tier's live objects in
; object order, ft_tl: the same candidates in the same order as a walk of all 16 objects.)
ft_drop_t:
        ld (ft_tier),a
        ld a,(ft_lok)
        or a
        call z,ft_lists
        ld a,0xFF
        ld (ft_best),a
        ld hl,0
        ld (ft_bix),hl
        ld a,(ft_tier)
        ld hl,ft_tl
        call ft_tlist
fdt_lp: ld a,(hl)
        cp 0xFF
        jr z,fdt_x
        inc l
        push hl
        call obj_ix
        call ft_live
        call nc,ft_cand
        pop hl
        jr fdt_lp
fdt_x:  ld hl,(ft_bix)
        ld a,h
        or l
        scf
        ret z
        push hl
        pop ix

; IX = object, ft_bbit = one of its bands: that band's OR layer goes (its B sprites leave its
; lines, O_GONE and the total, not for the spark); a character's stays held. NC.
ft_dropb:
        call ft_map
        ld l,(ix+O_BANDT)
        ld h,(ix+O_BANDT+1)
        ld a,(ft_bbit)
        ld c,a
        ld b,1
fdb_f:  ld a,b
        cp c
        jr z,fdb_g
        inc hl
        inc hl
        inc hl
        inc hl
        sla b
        jr fdb_f
fdb_g:  ld a,c
        or (ix+O_DROP)
        ld (ix+O_DROP),a
        ld e,(hl)                   ; dy
        inc hl
        inc hl
        ld a,(hl)                   ; B sprites
        ld c,a
        add a,(ix+O_GONE)
        ld (ix+O_GONE),a
        call ft_spark
        jr z,fdb_l                  ; (the spark: in no total)
        ld a,(bu_tot)
        sub c
        ld (bu_tot),a
fdb_l:  ld a,1
        ld (ln_neg),a
        ld a,c
        call ln_add
        ld a,(ix+O_TIER)
        or a
        ret nz                      ; (NC)
        ld a,(ft_bbit)
        or (ix+O_HOLD)
        ld (ix+O_HOLD),a
        or a                        ; (NC)
        ret

; IX = object -> Z when it is the spark. Keeps BC, DE.
ft_spark:
        push ix
        pop hl
        ld a,l
        cp (obj_tab + SPARK_OBJ * OBJ_SIZE) & 0xFF
        ret nz
        ld a,h
        cp (obj_tab + SPARK_OBJ * OBJ_SIZE) / 256
        ret

; IX = a live object of tier ft_tier: its cheapest band on line ft_line (FFh: anywhere, but the
; spark's) whose OR layer is still there, if cheaper than ft_best: ft_best, ft_bix, ft_bbit.
ft_cand:
        ld a,(ft_line)
        inc a
        jr nz,fc_go
        call ft_spark
        ret z
fc_go:  call ft_map
        ld l,(ix+O_BANDT)
        ld h,(ix+O_BANDT+1)
        ld b,(ix+O_NBANDS)
        ld c,1
fc_lp:  ld a,c
        and (ix+O_DROP)
        jr nz,fc_n                  ; (dropped already)
        inc hl
        inc hl
        ld a,(hl)                   ; B sprites
        dec hl
        dec hl
        or a
        jr z,fc_n
        call ft_covers
        jr c,fc_n
        inc hl
        inc hl
        inc hl
        ld a,(hl)                   ; its gain
        dec hl
        dec hl
        dec hl
        push hl
        ld hl,ft_best
        cp (hl)
        jr nc,fc_np
        ld (hl),a
        ld (ft_bix),ix
        ld a,c
        ld (ft_bbit),a
fc_np:  pop hl
fc_n:   inc hl
        inc hl
        inc hl
        inc hl
        sla c
        djnz fc_lp
        ret

; IX = object, HL = one of its band entries -> NC when the band's 16 lines hold line ft_line
; (FFh: any line). Keeps BC, HL.
ft_covers:
        ld a,(ft_line)
        cp 0xFF
        ret z                       ; (NC)
        push hl
        push bc
        ld c,a
        ld e,(hl)
        call ln_first
        ld e,c
        ld d,0
        ex de,hl
        or a
        sbc hl,de                   ; line - its first line
        ld a,h
        or a
        scf
        jr nz,fcv_x
        ld a,l
        cp 16
        ccf
fcv_x:  pop bc
        pop hl
        ret

; IX = object -> NC when one of its bands holds line ft_line (FFh: always, but for the spark).
ft_anyb:
        ld a,(ft_line)
        inc a
        jr nz,fa_go
        call ft_spark
        scf
        ret z
        or a
        ret
fa_go:  call ft_map
        ld l,(ix+O_BANDT)
        ld h,(ix+O_BANDT+1)
        ld b,(ix+O_NBANDS)
fa_lp:  call ft_covers
        ret nc
        inc hl
        inc hl
        inc hl
        inc hl
        djnz fa_lp
        scf
        ret

; A = tier: the least important live object of that tier on line ft_line (FFh: anywhere, but the
; spark) is left out of the tick (the spark first, on a line). C when there is none. (The tier's
; live objects in the order of importance, ft_tb, walked from the end as bu_ord was.)
ft_leave_t:
        ld (ft_tier),a
        cp 2
        jr nz,flt_o
        ld ix,obj_tab + SPARK_OBJ * OBJ_SIZE
        call ft_live
        jr c,flt_o
        call ft_anyb
        jr nc,ft_out
flt_o:  ld a,(ft_lok)
        or a
        call z,ft_lists
        ld a,(ft_tier)
        ld hl,ft_tb
        call ft_tlist
        ld c,l                      ; (its start: the lists do not cross a 256-byte boundary)
flt_e:  ld a,(hl)
        inc l
        cp 0xFF
        jr nz,flt_e
        dec l
flt_lp: ld a,l
        cp c
        scf
        ret z                       ; (none)
        dec l
        ld a,(hl)
        push hl
        push bc
        call obj_ix
        call ft_live
        call nc,ft_anyb             ; (NC: on the line)
        pop bc
        pop hl
        jr c,flt_lp

; IX = object: left out of the tick: its sprites leave its lines and the total. NC.
ft_out: ld (ix+O_OUT),1
        ld c,1
        call ln_obj
        call ft_spark
        jr z,fo_x
        ld a,(bu_tot)
        sub (ix+O_NSPR)
        add a,(ix+O_GONE)
        ld (bu_tot),a
fo_x:   or a                        ; (NC)
        ret

; A = tier, HL = ft_tl or ft_tb -> HL = that tier's list (17 bytes a tier). Keeps BC.
ft_tlist:
        ld e,a
        add a,a
        add a,a
        add a,a
        add a,a
        add a,e                     ; 17 * tier
        add a,l
        ld l,a
        ret

; The give-way's candidates, once a budget run (at its first give: ft_lok): per tier 0-2 the
; live objects of that tier (RoboCop's tier 3 never gives way) in object order (ft_tl, for
; ft_drop_t) and in the order of importance (ft_tb, bu_ord's order, for ft_leave_t), FFh after
; the last. The tiers are the run's (bg_tier); an object left out later in the run stays in
; them (the walks test ft_live again). Walking every object for each give cost 4-7 % of the CPU
; in the busy scenes.
ft_lists:
        ld a,1
        ld (ft_lok),a
        ld hl,ft_tl
        call ftg_wp
        ld ix,obj_tab + OBJ_SIZE
        ld c,1
ftg_lp: call ftg_one
        ld de,OBJ_SIZE
        add ix,de
        inc c
        ld a,c
        cp MAX_OBJ
        jr c,ftg_lp
        call ftg_end
        ld hl,ft_tb
        call ftg_wp
        ld hl,bu_ord
ftg_blp: ld a,(hl)
        cp 0xFF
        jp z,ftg_end
        inc hl
        push hl
        ld c,a
        call obj_ix
        call ftg_one
        pop hl
        jr ftg_blp

; HL = ft_tl or ft_tb: each tier's list empty (ft_wp: their next places).
ftg_wp: ld de,ft_wp
        ld a,l
        ld (de),a
        add a,17
        inc de
        ld (de),a
        add a,17
        inc de
        ld (de),a
        ret

; IX = object C: into its tier's list when it is live and of tier 0-2. Keeps BC, IX.
ftg_one:
        call ft_live
        ret c
        ld a,(ix+O_TIER)
        cp 3
        ret nc
        add a,ft_wp & 0xFF
        ld e,a
        ld d,ft_wp / 256
        ld a,(de)
        ld l,a
        ld h,ft_tl / 256            ; (ft_tl and ft_tb: one 256-byte page)
        ld (hl),c
        inc a
        ld (de),a
        ret

; Each list of the kind ftg_wp started: FFh after its last.
ftg_end:
        ld de,ft_wp
        ld b,3
ftg_elp: ld a,(de)
        ld l,a
        ld h,ft_tl / 256
        ld (hl),0xFF
        inc de
        djnz ftg_elp
        ret

; ----- versions -----

; A = object -> IY = its disp record (pend_iy: its pend record), HL = the same. Keeps BC, DE.
ver_iy: add a,a
        add a,a
        add a,a
        add a,a                     ; * LAY_SIZE
        ld l,a
        ld h,disp/256
        push hl
        pop iy
        ret
pend_iy:
        ld a,(pl_obj)
        call ver_iy
        inc h                       ; (pend = disp + 256)
        push hl
        pop iy
        ret
disp_iy:
        ld a,(pl_obj)
        jr ver_iy

; IY = a version record of object pl_obj -> H = its entry page. Keeps BC, DE, L.
ver_page:
        ld a,(pl_obj)
        add a,a
        add a,(iy+V_PAGE)
        add a,ENT_PAGE
        ld h,a
        ret

; IX = object, IY = a version record: Z when it is the version the object wants (composition,
; dropped columns, early clock, silhouette).
ver_same:
        ld a,(ix+O_BANK)
        cp (iy+V_BANK)
        ret nz
        ld a,(ix+O_COMP)
        cp (iy+V_COMP)
        ret nz
        ld a,(ix+O_COMP+1)
        cp (iy+V_COMP+1)
        ret nz
        ld a,(ix+O_DROP)
        cp (iy+V_DROP)
        ret nz
        ld a,(ix+O_EC)
        cp (iy+V_EC)
        ret

; IX = object -> A = 80h when it is to be shown (and not left out this tick), else 0.
obj_want:
        ld a,(ix+O_OUT)
        or a
        ld a,0
        ret nz
        ld a,(ix+O_FLAGS)
        and 0x80
        ret

; A = object: it has a new owner (bob.asm bf_key): what it showed and prepared was another
; BOB's, so both go (it shows nothing until its own version is ready).
spr_forget:
        ld (pl_obj),a
        push ix
        push af
        call obj_ix
        ld (ix+O_HOLD),0            ; (another BOB's look: decided anew)
        pop af
        pop ix                      ; (bf_key's record)
        call disp_iy
        call disp_unref
        call pend_iy
        jp pend_unref

; A = units of work done this frame by the sprite engine or the game logic (the HUD's pacing;
; saturates at 255).
spr_charge:
        push hl
        ld hl,spr_cost
        add a,(hl)
        jr nc,sc_s
        ld a,255
sc_s:   ld (hl),a
        pop hl
        ret

; ----- slots -----

; HL = a pattern id in a record -> A = a slot for it, one more entry using it (NC): the slot that
; holds it (shared, or kept from before: no upload) or, when none does, a free one that will
; (its upload still to queue: slot_ok = 0, slot_gen counts on); pl_unl counts the slots not
; loaded yet (pend_load). C when no slot is free. Keeps BC, DE, HL (works in the alternate
; registers).
slot_for:
        ld a,(hl)
        inc hl
        exx
        ld c,a
        exx
        ld a,(hl)
        dec hl
        exx
        ld b,a                      ; BC = pattern id
        and (PAT_HINTS - 1) / 256
        add a,pat_slot / 256
        ld h,a
        ld l,c
        ld e,(hl)                   ; the slot it was put in last (FFh: never)
        ld a,e
        cp SPR_SLOTS
        jr nc,sl_new
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held / 256
        ld a,(hl)
        cp c
        jr nz,sl_new
        inc l
        ld a,(hl)
        cp b
        jr nz,sl_new
        ld l,e                      ; it holds it (or its upload is on its way): one more entry
        ld h,slot_ref / 256
        inc (hl)
        ld h,SLOT_PG
        ld a,(hl)                   ; (slot_ok)
        or a
        jr nz,sl_ld
        ld hl,pl_unl
        inc (hl)
sl_ld:  ld a,e
        exx
        or a                        ; (NC)
        ret
sl_new: call alloc_slot
        jr c,sl_none
        ld e,a
        ld l,a
        ld h,slot_ref / 256
        ld (hl),1
        ld h,SLOT_PG
        or SO_GEN
        ld l,a
        inc (hl)                    ; a new generation first (spr_upload: an older background
        ld l,e                      ; upload of this slot then no longer marks it loaded),
        ld (hl),0                   ; then not loaded (slot_ok),
        ld a,e
        or SO_Q
        ld l,a
        ld (hl),0                   ; and in no queue
        ld a,e
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held / 256
        ld (hl),c
        inc l
        ld (hl),b                   ; what it will hold
        ld a,b
        and (PAT_HINTS - 1) / 256
        add a,pat_slot / 256
        ld h,a
        ld l,c
        ld (hl),e                   ; and where that pattern is
        ld hl,pl_unl
        inc (hl)
        ld a,e
        exx
        or a                        ; (NC)
        ret
sl_none:
        exx
        scf
        ret

; -> A = a slot no entry uses (taken in turn: the oldest content goes first); C when none.
; Keeps BC, DE, HL.
alloc_slot:
        push hl
        push bc
        ld a,(alloc_p)
        ld l,a
        ld h,slot_ref / 256
        ld b,SPR_SLOTS
al_lp:  ld a,l
        and SPR_SLOTS - 1
        ld l,a
        ld a,(hl)
        or a
        jr z,al_got
        inc l
        djnz al_lp
        pop bc
        pop hl
        scf
        ret
al_got: ld a,l
        inc a
        ld (alloc_p),a
        ld a,l
        pop bc
        pop hl
        or a
        ret

; A = slot: one entry fewer uses it now (a version still being prepared: nothing showed it).
slot_unref:
        ld l,a
        ld h,slot_ref / 256
        dec (hl)
        ret

; At the start of a plan (the frame it released slots in is on screen): those slots go. Slots
; released since the last plan ended (spr_forget, from bob_flush before this plan: the list on
; screen still shows them) stay for the next plan: freed now, the plan could write a new pattern
; into one while the beam draws the sprite that shows it (the plan writes patterns at once).
slots_free:
        ld a,(fl_mark)
        sub SO_FL - 1
        jr z,sf_keep
        ld b,a
        ld h,SLOT_PG
        ld l,SO_FL
        ld d,slot_ref / 256
sf_lp:  ld e,(hl)
        ex de,hl
        dec (hl)
        ex de,hl
        inc l
        djnz sf_lp
sf_keep:
        ld a,(fl_mark)
        ld e,a                      ; (the last one freed: SO_FL - 1 when none)
        ld a,(fl_n)
        sub e
        ld b,a                      ; those released since
        ld a,SO_FL - 1
        jr z,sf_x
        ld h,SLOT_PG
        ld l,e
        inc l
        ld d,h
        ld e,SO_FL
sf_mv:  ld a,(hl)                   ; to the list's start
        ld (de),a
        inc l
        inc e
        djnz sf_mv
        ld a,e
        dec a
sf_x:   ld (fl_n),a
        ret

; IY = the disp record of object pl_obj: no longer shown once the planned frame is on screen:
; its slots released then, its SAT entries free now (the planned frame parks or reuses them).
disp_unref:
        ld a,(iy+V_ON)
        or a
        ret z
        ld (iy+V_ON),0
        ld a,1
        ld (sat_dirty),a            ; (its entries parked)
        ld b,(iy+V_N)
        inc b
        dec b
        ret z
        call ver_page
        ld l,3                      ; slot of entry 0
        ld a,(fl_n)                 ; (the frame on screen still shows them: they go once the
                                    ; planned one is, slots_free: at most 32 a plan)
        ld e,a
        ld d,SLOT_PG
du_lp:  ld a,(hl)
        inc e
        ld (de),a
        ld a,l
        add a,ENT_SIZE
        ld l,a
        djnz du_lp
        ld a,e
        ld (fl_n),a
        ld a,(iy+V_RUN)             ; its run: free
        add a,ent_own & 0xFF
        ld l,a
        ld h,ent_own / 256
        ld b,(iy+V_N)
        ld a,0xFF
du_e:   ld (hl),a
        inc l
        djnz du_e
        ret

; IY = the pend record of object pl_obj: dropped (its slots released at once: nothing shows
; them; one never loaded keeps nothing).
pend_unref:
        ld a,(iy+V_ON)
        or a
        ret z
        ld (iy+V_ON),0
        ld b,(iy+V_N)
        inc b
        dec b
        ret z
        call ver_page
        ld l,3
pu_lp:  ld a,(hl)
        push hl
        ld l,a
        ld h,slot_ref / 256
        dec (hl)
        jr nz,pu_n
        ld h,SLOT_PG                ; free now: if its pattern never got there, it holds nothing
        ld a,(hl)                   ; (slot_ok)
        or a
        jr nz,pu_n
        ld a,l
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held / 256
        ld (hl),0xFF
        inc l
        ld (hl),0xFF
pu_n:   pop hl
        ld a,l
        add a,ENT_SIZE
        ld l,a
        djnz pu_lp
        ret

; ----- plan -----

; Once per published frame (sprites_frame): every object's versions toward what it wants, in
; order RoboCop, the spark, the BOBs. The patterns a new version needs are written into their
; slots at once (pend_load, pat_now), so a version is complete in the plan that prepares it and
; shows in this frame.
spr_plan:
        ld hl,pl_seq
        inc (hl)                    ; (pl_stamp)
        ld a,(pg_new)
        or a
        call nz,pg_build            ; (an identity changed: the objects with parts again)
        xor a
        ld (pl_pack),a              ; (no packing yet in this plan)
        call slots_free
        call rc_zone
        ld hl,pl_wa                 ; one look at every object: one not shown drops its
        ld (pl_pa),hl               ; versions, one shown as it wants is left alone, the others
        ld hl,pl_wb                 ; go into the work lists: first those showing nothing yet
        ld (pl_pb),hl               ; (a BOB that just came is invisible until its first
                                    ; version), then the rest; in each by importance
        ld hl,(pl_fl)               ; the look visits the objects wanted now or at its last run
        ld de,(pl_flp)              ; (fl_bit): any other shows and prepares nothing and keeps
        ld (pl_flp),hl              ; pl_st and pl_gs 0
        ld a,l
        or e
        ld e,a
        ld a,h
        or d
        ld d,a
        ld (pl_vis),de
        ld ix,obj_tab
        ld iy,disp
        xor a
pc_lp:  ld (pl_obj),a
        ld hl,pl_vis + 1
        srl (hl)
        dec hl
        rr (hl)
        jr c,pc_vis
        ld a,(hl)
        inc hl
        or (hl)
        jr z,pc_end                 ; (none left to visit)
        jr pc_skip
pc_vis: ld c,0                      ; (pl_st: 0 no work, 1 the first list, 2 the second)
        ld a,(ix+O_OUT)
        or a
        jr nz,pc_not
        bit 7,(ix+O_FLAGS)
        jr z,pc_not
        inc c
        ld a,(iy+V_ON)
        or a
        jr z,pc_st                  ; (shows nothing yet)
        call ver_same
        ld c,2
        jr nz,pc_st
        ld c,0                      ; shown as it wants: a version prepared meanwhile goes, unless
        push iy                     ; another part of its owner prepares one too: they were
        pop hl                      ; prepared for one tick and show it together (pl_work; this
        inc h                       ; one dropped, theirs would show beside this one's later
        ld a,(hl)                   ; frame)
        or a
        jr z,pc_st                  ; (none prepared)
        ld hl,pgc_pend
        call pg_each
        ld c,2
        jr nz,pc_st
        ld c,0
        jr pc_pd
pc_not: ld a,(iy+V_ON)
        or a
        call nz,disp_unref
        ld c,0
pc_pd:  push iy
        pop hl
        inc h                       ; (its pend record)
        ld a,(hl)
        or a
        jr z,pc_st
        push bc
        ld de,256
        add iy,de
        call pend_unref
        ld de,-256
        add iy,de
        pop bc
pc_st:  ld a,(pl_obj)
        add a,pl_st & 0xFF
        ld l,a
        ld h,pl_st / 256
        ld (hl),c
        call pw_gs                  ; its parts' state (pl_groups): 2 changing, 0 not
        ld a,c
        or a
        jr z,pc_gs
        ld a,2
pc_gs:  ld (hl),a
pc_skip:
        ld de,OBJ_SIZE
        add ix,de
        ld de,LAY_SIZE
        add iy,de
        ld a,(pl_obj)
        inc a
        cp MAX_OBJ
        jp c,pc_lp
pc_end: xor a                       ; the work lists by importance: RoboCop, the spark, the BOBs
        call pl_put                 ; in the budget's order, then any other
        ld a,SPARK_OBJ
        call pl_put
        ld hl,bu_ord
pc_o:   ld a,(hl)
        cp 0xFF
        jr z,pc_r
        push hl
        call pl_put
        pop hl
        inc hl
        jr pc_o
pc_r:   ld hl,pl_st + 1             ; (pl_st does not cross a 256-byte boundary)
        ld b,SPARK_OBJ - 1
pc_rl:  ld a,(hl)
        or a
        jr z,pc_rn
        push bc
        push hl
        ld a,l
        sub pl_st & 0xFF
        call pl_put
        pop hl
        pop bc
pc_rn:  inc l
        djnz pc_rl
        ld hl,(pl_pa)
        ld (hl),0xFF                ; (the lists' ends)
        ld hl,(pl_pb)
        ld (hl),0xFF
        ld hl,pl_wa
        call pl_list
        ld hl,pl_wb
        call pl_list
        call pl_groups
        jp rc_prefetch

; RoboCop's zone (pl_rcz): the most entries his versions shown, under way and wanted take; no
; BOB run goes there (he would have to push it away). Again once his new version is shown
; (pend_commit): the entries only his old one took are the BOBs' in that plan already (with
; the SAT full, a BOB's new part waited a plan more, 10 pictures in a busy scene).
rc_zone:
        ld ix,obj_tab
        ld a,(ix+O_NSPR)
        sub (ix+O_GONE)
        ld c,a
        ld a,(disp + V_N)
        cp c
        jr c,pz_1
        ld c,a
pz_1:   ld a,(pend + V_ON)
        or a
        jr z,pz_2
        ld a,(pend + V_N)
        cp c
        jr c,pz_2
        ld c,a
pz_2:   ld a,c
        add a,(ent_own + RC_RUN) & 0xFF
        ld (pl_rcz),a
        ret

; RoboCop's next animation step (the same state's next record, the one before when its
; animation runs backwards, the same aim) gets its patterns into free slots before the logic
; asks for it: its version is then complete at once. Each walk
; step has 11-18 patterns of its own (the original redraws the body and arms every step), a
; cycle 106 against the 64 slots: loaded only after the change, a step showed 7-12 VBLANKs late
; and the steps (2 ticks each) in between were skipped, so the walk looked to go backwards. The
; slots it takes are free ones (slot_ref 0, as alloc_slot gives them): no version loses any.
; After the plan's own work; rcp_id / rcp_ok skip a step already brought in.
rc_prefetch:
        ld a,(obj_tab + O_FLAGS)
        rla
        ret nc                      ; (not shown)
        ld a,(obj_tab + O_KIND)
        or a
        ret nz
        ld hl,(obj_tab + O_ID)      ; record * 4 + aim
        ld de,SPR_RC_ARM
        or a
        sbc hl,de
        ret nc                      ; (a start-of-level arm pose)
        add hl,de
        ld a,l
        and 3
        ld b,a                      ; B = aim
        srl h
        rr l
        srl h
        rr l                        ; L = record
        ld a,(p_state)
        ld e,a
        ld d,0
        push hl
        ld hl,pl_nrec
        add hl,de
        ld c,(hl)                   ; C = the state's records
        ld hl,pl_rec0
        add hl,de
        ld d,(hl)                   ; D = its first
        pop hl
        ld a,c
        cp 2
        ret c                       ; (one record: no next step)
        ld a,l
        sub d                       ; the step shown
        cp c
        ret nc                      ; (not one of the state's)
        ld e,a
        ld a,(p_rev)
        or a
        ld a,e
        jr nz,rcp_back
        inc a
        cp c
        jr c,rcp_rec
        xor a
        jr rcp_rec
rcp_back:
        or a
        jr nz,rcp_b1
        ld a,c
rcp_b1: dec a
rcp_rec:
        add a,d                     ; the next record
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        ld e,b
        ld d,0
        add hl,de                   ; its composition: record * 4 + aim
        ld de,(rcp_id)
        or a
        sbc hl,de
        jr nz,rcp_new
        ld a,(rcp_ok)
        or a
        ret nz                      ; (brought in already)
rcp_new:
        add hl,de
        ld (rcp_id),hl
        xor a
        ld (rcp_ok),a
        ld d,h
        ld e,l
        add hl,hl
        add hl,de                   ; *3: its index entry
        ld de,0x8000                ; (RoboCop's index)
        add hl,de
        ld a,SPR_BASE_BANK
        call bank_8000
        ld a,(hl)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        add a,SPR_BASE_BANK
        call bank_8000
        ld hl,0x8000
        add hl,de                   ; its composition
        ld b,(hl)                   ; records
        ld de,COMP_HDR + 4
        add hl,de                   ; the first one's pattern id (RoboCop drops no column)
rcp_lp: push bc
        push hl
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; BC = pattern id
        call slot_warm
        pop hl
        pop bc
        ret c                       ; (no free slot or the queue is full: the next plan goes on)
        ld de,REC_SIZE
        add hl,de
        djnz rcp_lp
        ld a,1
        ld (rcp_ok),a
        ret

; BC = pattern id: nothing to do when a slot holds it (pat_held), else a free slot gets it, used
; by no entry, the pattern written at once (bq_pat). C when no slot is free.
slot_warm:
        ld a,b
        and (PAT_HINTS - 1) / 256
        add a,pat_slot / 256
        ld h,a
        ld l,c
        ld a,(hl)                   ; the slot it was put in last (FFh: never)
        cp SPR_SLOTS
        jr nc,swm_new
        add a,a
        add a,pat_held & 0xFF
        ld e,a
        ld d,pat_held / 256
        ld a,(de)
        cp c
        jr nz,swm_new
        inc e
        ld a,(de)
        cp b
        ret z                       ; (held, or on its way: NC)
swm_new:
        call alloc_slot             ; (keeps BC, DE, HL)
        ret c
        ld (hl),a                   ; where the pattern is
        ld e,a
        or SO_GEN
        ld l,a
        ld h,SLOT_PG
        inc (hl)                    ; a new generation (an older upload of the slot is not copied),
        ld l,e
        ld (hl),0                   ; not loaded,
        ld a,e
        or SO_Q
        ld l,a
        ld (hl),0                   ; in no queue
        ld a,e
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held / 256
        ld (hl),c
        inc l
        ld (hl),b                   ; what it will hold
        jp bq_pat                   ; (E = slot, BC = id; C when the queue is full)

; A = object: into its work list when the look at it put it in one (pl_st; then no more).
pl_put: ld c,a
        add a,pl_st & 0xFF
        ld l,a
        ld h,pl_st / 256
        ld a,(hl)
        ld (hl),0
        dec a
        ld hl,pl_pa
        jr z,pp_l
        dec a
        ret nz                      ; (none)
        ld hl,pl_pb
pp_l:   ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,c
        ld (de),a
        inc de
        ld (hl),d
        dec hl
        ld (hl),e
        ret

; HL = a work list (objects, FFh at its end): each one's version brought on.
pl_list:
        ld a,(hl)
        cp 0xFF
        ret z
        inc hl
        push hl
        call pl_work
        call feed_vdp               ; (the scroll engine's next VDP command: its pages are
        pop hl                      ; built only from the main loop's idle points)
        jr pl_list

; A = object that wants another version than it shows: the one it prepares goes on (once shown,
; the next one it wants is prepared: dropping a version under way each time an animation moved
; on showed nothing new at all), or the one it wants is prepared now. An owner's parts (a walking
; enemy's legs and torso) show versions prepared in one plan, so of one tick: a part prepares
; none while another prepares one of an earlier plan (pgc_old), keeps its own while another
; prepares one (spr_plan), and they are shown together (pw_ready, pl_groups); when one finds no
; slots, the others drop those of this plan (pgc_drop).
pl_work:
        ld (pl_obj),a
        call obj_ix
        call pend_iy
        ld a,(iy+V_ON)
        or a
        jr nz,pw_load
        push iy
        pop hl
        dec h                       ; (its disp)
        ld a,(hl)
        or a
        ld hl,pgc_old               ; a part whose other parts prepare the versions of an earlier
        jr nz,pw_gate               ; tick (or found no slots in this plan) waits: shown with
        ld hl,pgc_new               ; theirs, its version would be of another tick; one that
pw_gate:                            ; shows nothing yet does not wait: theirs go, and are
        call pg_each                ; prepared again with its own (the first list comes first)
        jr nz,pw_wait
        call pend_build
        jr c,pw_fail                ; (no slots)
        ld a,(pl_obj)
        add a,pl_stamp & 0xFF
        ld l,a
        ld h,pl_stamp / 256
        ld a,(pl_seq)
        ld (hl),a                   ; (the plan it was prepared in)
        ld a,(pl_unl)               ; (counted while it was built)
        ld c,a
        call pld_n
        jr z,pw_ready
        ret                         ; (its patterns on their way)
pw_load:
        call pend_load
        jr z,pw_ready
        ret
pw_fail:
        call pw_gs                  ; no slots: its parts show nothing new in this plan either
        ld (hl),4                   ; (those prepared in it go: pgc_drop; the others wait:
        ld hl,pgc_drop              ; pgc_old)
        jp pg_each
pw_wait:
        call pw_gs                  ; (not on its way: its parts do not wait for it)
        ld (hl),0
        ret

; The object's version complete: shown now, unless another part of its owner (the same owner
; and category: bob.asm obj_key) changes in this plan too: a walking enemy's legs and torso are
; two objects, and one shown a frame before the other split the character (or showed half of
; it, the other still loading). Then they change together at the plan's end (pl_groups).
pw_ready:
        ld a,(pl_obj)
        or a
        jp z,pend_commit            ; (RoboCop, the spark: no parts)
        cp SPARK_OBJ
        jp z,pend_commit
        call pg_part
        call pw_gs
        jr nz,pwr_def
        ld (hl),3
        jp pend_commit
pwr_def:
        ld (hl),1
        ret

; HL = pl_gs's byte of object pl_obj (0 no change, 1 complete and waiting for its parts, 2
; changing, 3 shown in this plan, 4 no slots for it in this plan). Keeps BC, DE, IX, IY; flags
; kept.
pw_gs:  push af
        ld a,(pl_obj)
        add a,pl_gs & 0xFF
        ld l,a
        ld h,pl_gs / 256
        pop af
        ret

; Object pl_obj's parts (the other BOB objects of its owner and category) -> A = the OR of their
; states 1 and 2 (NZ: one changes in this plan). Keeps IX, IY.
pg_part:
        ld hl,pgc_state

; HL = a test: called for each of object pl_obj's parts (the other BOB objects of its owner and
; category: a walking enemy's legs and torso) with A = that part; it ORs its answer into pg_or
; (pg_set). -> A = pg_or (NZ: some). Keeps IX, IY.
pg_each:
        ld (pg_fn),hl
        ld a,(pl_obj)
        add a,a
        add a,a
        add a,(obj_key + 1) & 0xFF
        ld l,a
        ld h,obj_key / 256
        ld e,(hl)                   ; owner
        inc l
        ld d,(hl)
        inc l
        ld c,(hl)                   ; category + 1
        xor a
        ld (pg_or),a
        or c
        ret z                       ; (no identity: RoboCop, the spark)
        cp BC_SPECIAL + 1
        jr nc,pge_ok                ; (lifts, the vehicle, explosions)
        cp BC_ENEMY + 1
        jr z,pge_ok
        xor a                       ; (bullets, pickups, RoboCop's shots: never in parts, and
        ret                         ; the most of the objects)
pge_ok: ld a,pg_list & 0xFF         ; (only the objects whose category can have parts: pg_build;
pge_lp: ld (pg_ptr),a               ;  no other can hold this key)
        ld l,a
        ld h,pg_list / 256
        ld a,(hl)
        cp 0xFF
        jr z,pge_end
        ld b,a
        ld a,(pl_obj)
        cp b
        jr z,pge_n
        ld a,b
        add a,a
        add a,a
        add a,(obj_key + 1) & 0xFF
        ld l,a
        ld h,obj_key / 256
        ld a,(hl)
        cp e
        jr nz,pge_n
        inc l
        ld a,(hl)
        cp d
        jr nz,pge_n
        inc l
        ld a,(hl)
        cp c
        jr nz,pge_n
        push bc
        push de
        ld a,b
        call pge_go
        pop de
        pop bc
pge_n:  ld a,(pg_ptr)
        inc a
        jr pge_lp
pge_end:
        ld a,(pg_or)
        or a
        ret
pge_go: ld hl,(pg_fn)
        jp (hl)

; The BOB objects whose category can have parts (enemies, lifts, the vehicle, explosions), in
; object order, FFh after the last (pg_list): what pg_each walks. Built at the plan's start when
; an identity changed since (pg_new: bob.asm bf_key, bf_hide); with ENEMY_CAP 1 it holds 1-4
; objects where pg_each used to compare all 14.
pg_build:
        xor a
        ld (pg_new),a
        ld de,pg_list
        ld b,1
pgb_lp: ld a,b
        add a,a
        add a,a
        add a,(obj_key + 3) & 0xFF
        ld l,a
        ld h,obj_key / 256
        ld a,(hl)                   ; its category + 1
        cp BC_SPECIAL + 1
        jr nc,pgb_in
        cp BC_ENEMY + 1
        jr nz,pgb_n
pgb_in: ld a,b
        ld (de),a
        inc de
pgb_n:  inc b
        ld a,b
        cp SPARK_OBJ
        jr c,pgb_lp
        ld a,0xFF
        ld (de),a
        ret

; pg_each's tests: A = a part.
; Its state 1 or 2 (changing in this plan).
pgc_state:
        add a,pl_gs & 0xFF
        ld l,a
        ld h,pl_gs / 256
        ld a,(hl)
        cp 3
        ret nc
pg_set: ld hl,pg_or
        or (hl)
        ld (hl),a
        ret
; It prepares a version.
pgc_pend:
        call pd_on
        ret z
        ld a,1
        jr pg_set
; It prepares a version of an earlier plan, or found no slots in this one.
pgc_old:
        ld c,a
        add a,pl_gs & 0xFF
        ld l,a
        ld h,pl_gs / 256
        ld a,(hl)
        cp 4
        jr z,pgo_y
        ld a,c
        call pd_on
        ret z
        ld a,c
        call pd_stamp
        ret z                       ; (of this plan)
pgo_y:  ld a,1
        jr pg_set
; It found no slots in this plan; else it drops a version of an earlier plan (still changing: it
; prepares the one it wants later in this plan).
pgc_new:
        ld c,a
        add a,pl_gs & 0xFF
        ld l,a
        ld h,pl_gs / 256
        ld a,(hl)
        cp 4
        jr z,pgo_y
        ld a,c
        call pd_on
        ret z
        ld a,c
        call pd_stamp
        ret z                       ; (of this plan)
        jr pgd_go
; It drops a version prepared in this plan (not on its way: state 0).
pgc_drop:
        ld c,a
        call pd_on
        ret z
        ld a,c
        call pd_stamp
        ret nz                      ; (of an earlier plan)
        ld b,0
pgd_go: ld a,(pl_obj)
        push af
        ld a,c
        ld (pl_obj),a
        push iy
        call pend_iy
        call pend_unref
        pop iy
        inc b
        dec b
        call z,pw_gs
        jr nz,pgd_s
        ld (hl),0
pgd_s:  pop af
        ld (pl_obj),a
        ret

; A = object -> HL = its pend record, A = its V_ON (Z: it prepares nothing).
pd_on:  add a,a
        add a,a
        add a,a
        add a,a
        ld l,a
        ld h,pend / 256
        ld a,(hl)
        or a
        ret

; A = object -> Z when its pend was prepared in this plan (pl_stamp).
pd_stamp:
        add a,pl_stamp & 0xFF
        ld l,a
        ld h,pl_stamp / 256
        ld a,(pl_seq)
        cp (hl)
        ret

; At the plan's end: the parts that waited for the other parts of their owner (pl_gs 1) are shown
; now, together, unless one of those is still on its way (2: its patterns not all in their slots;
; one that found no slots does not hold them, 0). In three passes: those that take fewer SAT
; entries than they show (within their own run: they free entries), those that take more or
; show nothing yet (pc_run may find no run: then their parts wait with them), then those that
; keep their run. (A part whose new version waited for another that had no run, while its own
; old one held the entries, kept the other out for good.)
pl_groups:
        ld hl,pl_gs + 1
        ld bc,SPARK_OBJ - 1
        ld a,1
        cpir
        ret nz                      ; (none waits: most plans; the passes cost 2 ms)
        ld c,0
pgr_ps: ld b,1
pgr_lp: push bc
        ld a,b
        ld (pl_obj),a
        call pw_gs
        ld a,(hl)
        cp 1
        jr nz,pgr_n
        call pg_part
        and 2
        jr nz,pgr_n
        ld a,(pl_obj)
        call obj_ix
        call pend_iy
        push iy
        pop hl
        dec h                       ; (its disp)
        ld a,(hl)
        or a
        ld e,1                      ; (no run yet)
        jr z,pgr_k
        ld a,l
        add a,V_N
        ld l,a
        ld a,(iy+V_N)
        cp (hl)
        ld e,2                      ; (as large: it keeps its run)
        jr z,pgr_k
        ld e,0                      ; (smaller)
        jr c,pgr_k
        inc e                       ; (larger)
pgr_k:  pop bc
        push bc
        ld a,c
        cp e
        jr nz,pgr_n                 ; (another pass's)
        xor a                       ; (each may pack the runs: two parts that take more entries
        ld (pl_pack),a              ; may both need it)
        call pend_commit
        call pw_gs
        ld a,(iy+V_ON)
        or a
        ld (hl),3                   ; (shown)
        jr z,pgr_n
        ld (hl),0                   ; no run free now: its parts wait with it
        ld hl,pgc_hold
        call pg_each
pgr_n:  pop bc
        inc b
        ld a,b
        cp SPARK_OBJ
        jr c,pgr_lp
        inc c
        ld a,c
        cp 3
        jr c,pgr_ps
        ret

; pg_each's test: a part waiting to be shown (state 1) waits on (0).
pgc_hold:
        add a,pl_gs & 0xFF
        ld l,a
        ld h,pl_gs / 256
        ld a,(hl)
        dec a
        ret nz
        ld (hl),a
        ret

; IX = object, IY = its pend record (empty): the version it wants, prepared: its entries (from
; its composition, with its dropped columns, early clock and silhouette) on the entry page its
; disp does not use, a slot for every pattern. C when the slots ran out (nothing kept).
pend_build:
        push iy
        call disp_iy
        ld a,(iy+V_ON)
        or a
        jr z,pb_p0
        ld a,(iy+V_PAGE)
        xor 1
pb_p0:  pop iy
        ld (iy+V_PAGE),a
        ld a,(ix+O_BANK)
        ld (iy+V_BANK),a
        ld a,(ix+O_COMP)
        ld (iy+V_COMP),a
        ld a,(ix+O_COMP+1)
        ld (iy+V_COMP+1),a
        ld a,(ix+O_DROP)
        ld (iy+V_DROP),a
        ld a,(ix+O_EC)
        ld (iy+V_EC),a
        and 0x80
        ld (lb_ec),a
        ld a,(ix+O_EC)
        and 3
        ld (lb_mode),a
        ld a,(ix+O_KIND)
        ld (iy+V_KIND),a
        ld a,(ix+O_ID)
        ld (iy+V_ID),a
        ld a,(ix+O_ID+1)
        ld (iy+V_ID+1),a
        ld a,(ix+O_MINDX)
        ld (iy+V_MINDX),a
        ld a,(ix+O_MAXDX)
        ld (iy+V_MAXDX),a
        ld a,(ix+O_NLINES)
        ld (iy+V_LINES),a
        xor a
        ld (iy+V_N),a
        ld (pl_unl),a
        call obj_comp               ; HL = its composition (bank mapped at 8000h)
        ld b,(hl)                   ; records
        ld de,COMP_HDR
        add hl,de
        push hl
        call ver_page
        ld d,h
        ld e,0                      ; DE = its first entry
        pop hl
        ld c,(iy+V_DROP)
pb_lp:  push hl
        ld a,(hl)
        ld (de),a                   ; dy (the entry counts only if the sprite is kept)
        inc hl
        inc e
        ld a,(hl)
        ld (de),a                   ; dx
        inc hl
        ld a,(hl)                   ; park bit
        and c
        jr nz,pb_skip               ; B sprite of a dropped column: no entry
        inc hl
        ld a,(hl)                   ; A1 bit
        inc hl
        and c
        jr z,pb_ids
        ld a,l                      ; A sprite of a dropped column: its A1 ids
        add a,4
        ld l,a
        jr nc,pb_ids
        inc h
pb_ids: call slot_for
        jr c,pb_none
        inc e
        inc e
        ld (de),a                   ; slot
        dec e
        add a,a
        add a,a
        ld (de),a                   ; pattern number
        inc e
        inc e
        ld a,(hl)
        ld (de),a
        inc hl
        inc e
        ld a,(hl)
        ld (de),a                   ; pattern id
        inc hl
        inc e
        ld a,(lb_mode)
        or a
        jr nz,pb_sil
        ld a,(hl)
        ld (de),a
        inc hl
        inc e
        ld a,(lb_ec)
        or (hl)
        ld (de),a                   ; colour id | 8000h (early clock)
pb_cd:  inc e
        pop hl
        jr pb_nx
pb_skip:
        dec e
        pop hl
pb_nx:  ld a,l
        add a,REC_SIZE
        ld l,a
        jr nc,pb_n
        inc h
pb_n:   djnz pb_lp
        ld a,e                      ; its entries: 8 bytes each from 0
        rrca
        rrca
        rrca
        and 0x1F
        ld (iy+V_N),a
        ld (iy+V_ON),0x80
        or a                        ; (NC)
        ret
pb_sil: dec a                       ; a silhouette: its colour row
        jr nz,pb_blk
        ld a,SPR_SIL_FLASH & 0xFF
        ld (de),a
        inc e
        ld a,(lb_ec)
        or SPR_SIL_FLASH / 256
        jr pb_s1
pb_blk: ld a,SPR_SIL_BLACK & 0xFF
        ld (de),a
        inc e
        ld a,(lb_ec)
        or SPR_SIL_BLACK / 256
pb_s1:  ld (de),a
        jr pb_cd
pb_none:
        pop hl                      ; no slot: what it took goes (E: past the last whole entry's
        ld a,e                      ; first byte)
        rrca
        rrca
        rrca
        and 0x1F
        ld (iy+V_N),a
        ld (iy+V_ON),0x80
        call pend_unref
        scf
        ret

; IY = the pend record of object pl_obj: its patterns not yet in their slots are written into
; them now (pat_now: slots no shown entry uses; 2026-10-23, before: through the frame's and the
; background queues, which the interrupts copied, a version waiting a frame or more for them).
; Z: all there.
pend_load:
        ld b,(iy+V_N)
        inc b
        dec b
        ret z
        call ver_page
        ld l,3                      ; slot of entry 0
        ld c,0                      ; its patterns not in their slots yet
pld_c:  ld e,(hl)
        ld d,SLOT_PG
        ld a,(de)                   ; (slot_ok)
        or a
        jr nz,pld_cn
        inc c
pld_cn: ld a,l
        add a,ENT_SIZE
        ld l,a
        djnz pld_c
pld_n:  ld a,c                      ; (C = its patterns not in their slots yet: pend_build
        or a                        ; counts them as it builds the version)
        ret z                       ; all there (Z)
        ld b,(iy+V_N)
        call ver_page
        ld l,3
pl_ld:  push bc
        push hl
        ld e,(hl)                   ; slot
        ld d,SLOT_PG
        ld a,(de)                   ; (slot_ok)
        or a
        jr nz,pl_ok                 ; loaded
        inc l
        ld c,(hl)
        inc l
        ld b,(hl)                   ; BC = pattern id
        call pat_now
        ld a,1
        ld (de),a                   ; (slot_ok)
pl_ok:  pop hl
        ld a,l
        add a,ENT_SIZE
        ld l,a
        pop bc
        djnz pl_ld
        xor a                       ; (Z: all there)
        ret

; A, E -> HL = A * E. Keeps BC.
mul8:   ld hl,0
        ld d,h                      ; DE = E, shifted left as A is shifted right
mul8_l: or a
        ret z
        srl a
        jr nc,mul8_n
        add hl,de
mul8_n: sla e
        rl d
        jr mul8_l

; E = slot, BC = pattern id (slot_warm, RoboCop's next step): the pattern into its slot now,
; loaded (slot_ok). NC. Keeps BC, DE.
bq_pat: call pat_now
        ld d,SLOT_PG
        ld a,1
        ld (de),a                   ; (slot_ok)
        or a
        ret

; E = slot, BC = pattern id: its 32 bytes from the pool into the slot now (the slot is free or
; new: no shown entry uses it, and the pattern table is the same for both sprite sets). The pool's
; bank at A000h through act_a000 (an interrupt puts it back; sprites_frame restores the window).
; Keeps BC, DE.
pat_now:
        push bc
        push de
        ld a,b
        add a,SPR_BASE_BANK + SPR_PAT_BANK
        ld (act_a000),a
        ld (BANK_A000),a            ; the pool's bank: id / 256,
        ld a,c
        rrca
        rrca
        rrca
        ld l,a
        and 0x1F
        add a,0xA0
        ld h,a
        ld a,l
        and 0xE0
        ld l,a                      ; HL = A000h + 32 * (id & FFh)
        ld a,e
        rrca
        rrca
        rrca
        ld d,a
        and 0xE0
        ld e,a
        ld a,d
        and 0x07
        add a,((SPR_PAT >> 8) & 0x3F) | 0x40
        ld d,a                      ; DE = SPR_PAT + 32 * slot (high | 40h: write)
        call spr_wr
        ld c,VDP_DATA
        call outi32
        pop de
        pop bc
        ret

; DE = a VRAM address in 1C000h-1FFFFh (D: high | 40h, E: low): the CPU's writes (port 98h) go
; there from now on (R#14 = 7). The interrupts off around it: they write registers through port
; 99h too. Uses A. (The interrupts write no VRAM: every sprite upload is the main program's.)
spr_wr: di
        ld a,7
        out (VDP_CTRL),a
        ld a,0x8E
        out (VDP_CTRL),a            ; R#14 = 7
        ld a,e
        out (VDP_CTRL),a
        ld a,d
        out (VDP_CTRL),a
        ei
        ret

; HL = 32 bytes (outi16: 16), C = VDP_DATA: written with OUTIs, 18 T-states a byte. During the
; display with sprites on the V9938 and V9958 take a CPU write at least every 70 VDP cycles (12
; T-states; openMSX's access-slot model, from measurements on real chips). Uses B, HL.
outi32:
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
outi16:
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        outi
        ret

; ----- commit -----

; IX = object, IY = its pend record, complete: it replaces the version shown when it gets a run
; of SAT entries (RoboCop's from entry RC_RUN, the spark's at 0, a BOB's the highest that fits;
; entries free or its own): the old version released and the new one shown from this frame (its
; colour rows go into the set that frame shows: rows_sync).
pend_commit:
        ld a,(pl_obj)
        or a
        jr nz,pcm_o
        ld a,RC_RUN                 ; RoboCop: his run from RC_RUN, whatever is there
        ld (pc_start),a
        call pr_clear               ; (a BOB in his way moves above his zone)
        jr pcm_c
pcm_o:  call pc_run
        ret c                       ; (no run free now)
        ld (pc_start),a
pcm_c:  push iy
        call disp_iy
        call disp_unref             ; the version shown goes (its run is free now)
        pop iy
        ld a,(pc_start)
        ld (iy+V_RUN),a
        add a,ent_own & 0xFF
        ld l,a
        ld h,ent_own / 256
        ld b,(iy+V_N)
        ld a,(pl_obj)
pc_own: ld (hl),a
        inc l
        djnz pc_own
        push iy                     ; pend -> disp (its colour rows: rows_sync)
        pop hl
        ld e,l
        dec h
        ld d,h
        inc h
        ld bc,LAY_SIZE
        ldir
        ld (iy+V_ON),0              ; (pend empty; its slots are the shown version's now)
        ld a,1
        ld (sat_dirty),a
        ld a,(pl_obj)
        or a
        ret nz
        push ix
        call rc_zone                ; (RoboCop: the zone of his new version)
        pop ix
        ret

; IY = a complete pend record of object pl_obj -> A = the first SAT entry of its run (C: none
; free now). A version as large as the one shown takes that one's run (its own entries, above
; RoboCop's zone): no search, and the holes stay as they are.
pc_run: ld a,(pl_obj)
        cp SPARK_OBJ
        ld a,0
        ret z                       ; (entries 0-1)
        ld e,(iy+V_N)               ; the new version's entries
        push iy
        call disp_iy
        ld a,(iy+V_ON)
        or a
        jr z,pr_srch                ; (nothing shown)
        ld a,(iy+V_N)
        cp e
        jr nz,pr_srch               ; (another size: the best hole for it)
        ld a,(iy+V_RUN)
        ld d,a
        add a,ent_own & 0xFF
        ld hl,pl_rcz
        cp (hl)
        jr c,pr_srch                ; (RoboCop's zone reaches it)
        pop iy
        ld a,d
        or a                        ; (NC)
        ret
pr_srch:
        pop iy
pr_find:
        ld a,0xFF                   ; a BOB: the smallest hole that fits (holes: runs of entries
        ld (pr_bsz),a               ; free or its own above RoboCop's zone; of two the same, the
        ld hl,ent_own + SAT_MAX - 1 ; higher), so that the holes left stay large
        ld c,0                      ; size of the hole being walked
pr_lp:  ld a,(pl_rcz)
        dec a
        cp l
        jr nc,pr_end                ; (below the zone's end: the last hole ends)
        ld a,(hl)
        inc a
        jr z,pr_fr
        dec a
        ld e,a
        ld a,(pl_obj)
        cp e
        jr z,pr_fr
        call pr_hole                ; another object's: the hole above it ends
        ld c,0
        dec l
        jr pr_lp
pr_fr:  inc c
        dec l
        jr pr_lp
pr_end: call pr_hole
        ld a,(pr_bsz)
        inc a
        jr z,pr_none                ; (none fits)
        ld a,(pr_bst)
        or a
        ret

; C = size of a hole whose lowest entry is L + 1 (ent_own's low byte): when the object (IY+V_N
; entries) fits and it is smaller than the best so far, it is the best (pr_bst: its run's first
; entry, at the hole's top). Keeps BC, HL.
pr_hole:
        ld a,c
        cp (iy+V_N)
        ret c                       ; (too small)
        ld a,(pr_bsz)
        cp c
        ret c
        ret z                       ; (not smaller: the higher one stays)
        ld a,c
        ld (pr_bsz),a
        ld a,l                      ; the run at the hole's top: L + 1 + C - n
        add a,c
        sub (iy+V_N)
        inc a
        sub ent_own & 0xFF
        ld (pr_bst),a
        ret
pr_none:
        ld a,(pl_pack)              ; no hole takes it: when the entries free above RoboCop's
        or a                        ; zone (with its own) do, the BOBs' runs are packed (once a
        jr nz,pr_no                 ; plan) and the search is tried again
        call pr_free
        cp (iy+V_N)
        jr c,pr_no
        call sat_pack
        jp pr_find
pr_no:  scf
        ret

; -> A = the SAT entries above RoboCop's zone that are free or object pl_obj's.
pr_free:
        ld a,(pl_obj)
        ld d,a
        ld c,0
        ld hl,ent_own + SAT_MAX - 1
prf_lp: ld a,(pl_rcz)
        dec a
        cp l
        jr nc,prf_x                 ; (below the zone's end)
        ld a,(hl)
        inc a
        jr z,prf_f
        dec a
        cp d
        jr nz,prf_n
prf_f:  inc c
prf_n:  dec l
        jr prf_lp
prf_x:  ld a,c
        ret

; The BOBs' runs packed against entry 31, in their order, the run of object pl_obj last (lowest:
; beside the hole), so that the entries free above RoboCop's zone become one hole next to it;
; the runs in his zone (his next version takes more entries) move above it too. A run that moves
; only has another place in the SAT being built (the set on screen is never written): rows_sync
; gives that set the colour rows there, sat_build the entries. Nothing moves when they do not all
; fit above his zone. Keeps IY.
sat_pack:
        push iy
        ld a,1
        ld (pl_pack),a
        ld de,sp_list               ; the objects of the runs from the top (sp_list within a page)
        ld hl,ent_own + SAT_MAX - 1
        ld c,0xFF                   ; (the owner seen last)
spk_lp: ld a,l
        cp (ent_own + RC_RUN) & 0xFF
        jr c,spk_e                  ; (down to RoboCop's run)
        ld a,(hl)
        cp c
        jr z,spk_n                  ; (the same run)
        ld c,a
        inc a
        jr z,spk_n                  ; (free)
        dec a
        jr z,spk_n                  ; (RoboCop's: not a BOB run)
        cp SPARK_OBJ
        jr z,spk_n
        ld b,a
        ld a,(pl_obj)
        cp b
        jr z,spk_n                  ; (pl_obj's goes last)
        ld a,b
        ld (de),a
        inc e
spk_n:  dec l
        jr spk_lp
spk_e:  ld a,(pl_obj)               ; then pl_obj's, when it shows a version
        call ver_iy
        ld a,(iy+V_ON)
        or a
        jr z,spk_w
        ld a,(pl_obj)
        ld (de),a
        inc e
spk_w:  ld a,0xFF
        ld (de),a
        ld de,sp_list               ; do they all fit above RoboCop's zone?
        ld c,SAT_MAX
spk_t:  ld a,(de)
        inc e
        cp 0xFF
        jr z,spk_go
        call ver_iy
        ld a,c
        sub (iy+V_N)
        jr c,spk_x
        ld c,a
        add a,ent_own & 0xFF
        ld hl,pl_rcz
        cp (hl)
        jr c,spk_x                  ; (the lowest would reach into it: nothing moves)
        jr spk_t
spk_go: ld a,1
        ld (sat_dirty),a
        ld de,sp_list               ; their entries freed
spk_c:  ld a,(de)
        inc e
        cp 0xFF
        jr z,spk_p
        call ver_iy
        ld a,(iy+V_RUN)
        add a,ent_own & 0xFF
        ld l,a
        ld h,ent_own / 256
        ld b,(iy+V_N)
spk_cf: ld (hl),0xFF
        inc l
        djnz spk_cf
        jr spk_c
spk_p:  ld de,sp_list               ; and placed from entry 31 down
        ld c,SAT_MAX
spk_r:  ld a,(de)
        inc e
        cp 0xFF
        jr z,spk_x
        ld b,a
        call ver_iy
        ld a,c
        sub (iy+V_N)
        ld c,a
        ld (iy+V_RUN),a
        add a,ent_own & 0xFF
        ld l,a
        ld h,ent_own / 256
        ld a,b
        ld b,(iy+V_N)
spk_rf: ld (hl),a
        inc l
        djnz spk_rf
        jr spk_r
spk_x:  pop iy
        ret

; IY = RoboCop's pend record: the BOBs whose runs are on his new run's entries move to runs above
; his zone (holes as pc_run finds them; their colour rows and entries follow there, rows_sync and
; sat_build: the picture is the same), or, when none fits, are shown no more (their next
; versions get runs there). Dropped, a walking enemy's legs vanished for up to 10 pictures
; whenever RoboCop's next frame took more sprites.
pr_clear:
        ld b,(iy+V_N)
        ld hl,ent_own + RC_RUN
prc_lp: ld a,(hl)
        inc a
        jr z,prc_n                  ; (free)
        dec a
        jr z,prc_n                  ; (his)
        push bc
        push hl
        push iy
        ld (pl_obj),a
        call disp_iy
        call pr_find
        jr c,prc_drop
        call prc_move
        jr prc_d
prc_drop:
        call disp_unref
prc_d:  xor a
        ld (pl_obj),a
        pop iy
        pop hl
        pop bc
prc_n:  inc l
        djnz prc_lp
        ret

; IY = the disp record of object pl_obj, A = the first entry of a free run of its size above
; RoboCop's zone (pr_find): its run moves there.
prc_move:
        push af
        ld a,(iy+V_RUN)
        add a,ent_own & 0xFF
        ld l,a
        ld h,ent_own / 256
        ld b,(iy+V_N)
        ld a,(pl_obj)
        ld c,a
prm_f:  ld a,(hl)                   ; its old entries free
        cp c
        jr nz,prm_fn
        ld (hl),0xFF
prm_fn: inc l
        djnz prm_f
        pop af
        ld (iy+V_RUN),a
        add a,ent_own & 0xFF
        ld l,a
        ld b,(iy+V_N)
prm_o:  ld (hl),c                   ; and its new ones
        inc l
        djnz prm_o
        ld a,1
        ld (sat_dirty),a
        ret

; The sprite set the next list shows (spr_set, after sprites_frame switched it): the colour row of
; every entry a version shown takes, from that version's colour ids; those its colour table does
; not hold yet (rs_held: that set's col_held) go into the frame's queue. (The two sets: the one on
; screen is never written; the other is made complete for the list that switches to it.)
rows_sync:
        ld a,0xFF
        ld (pcr_next),a             ; (no row written yet: pc_rows sets the first address)
        ld iy,disp
        xor a
        ld (pl_obj),a
rsy_lp: ld a,(iy+V_ON)
        or a
        jr z,rsy_n
        ld a,(iy+V_RUN)
        ld (pc_start),a
        call pc_rows
rsy_n:  ld de,LAY_SIZE
        add iy,de
        ld a,(pl_obj)
        inc a
        ld (pl_obj),a
        cp MAX_OBJ
        jr c,rsy_lp
        ret

; IY = a version shown by object pl_obj, pc_start = its run: its colour rows the set does not hold
; written into the set's colour table now (rs_colhi: the set not on screen; consecutive entries'
; rows follow one another in VRAM, so the address is set only where a run of rows starts:
; pcr_next); rs_held follows.
pc_rows:
        call ver_page
        ld l,6
        ld a,(pc_start)
        ld c,a                      ; SAT entry
        add a,a
        ld de,(rs_held)
        add a,e
        ld e,a                      ; (each col_held within a 256-byte page)
        ld b,(iy+V_N)
pcr_lp: ld a,(de)
        cp (hl)
        jr nz,pcr_w
        inc e
        inc l
        ld a,(de)
        cp (hl)
        jr nz,pcr_w1
        inc e                       ; the same row: nothing
        ld a,l
        add a,ENT_SIZE - 1
        ld l,a
        inc c
        djnz pcr_lp
        ret
pcr_w1: dec e
        dec l
pcr_w:  ld a,(hl)                   ; the row it wants (bit 15: the early clock): held,
        ld (de),a
        inc e
        inc l
        exx
        ld e,a
        exx
        ld a,(hl)
        ld (de),a
        inc e
        exx
        ld d,a                      ; DE' = the row's id
        and 0x7E
        rrca
        add a,SPR_BASE_BANK + SPR_COL_BANK
        ld (act_a000),a
        ld (BANK_A000),a            ; the pool's bank: (id & 7FFFh) / 512,
        ld a,e
        rlca
        rlca
        rlca
        rlca
        ld b,a
        and 0xF0
        ld l,a
        ld a,b
        and 0x0F
        bit 0,d
        jr z,pcr_h
        or 0x10
pcr_h:  add a,0xA0
        ld h,a                      ; HL' = A000h + 16 * (id & 1FFh)
        exx
        ld a,(pcr_next)
        cp c
        call nz,pcr_adr             ; (not right after the last row written: its address)
        ld a,c
        inc a
        ld (pcr_next),a
        exx
        ld c,VDP_DATA
        bit 7,d
        jr nz,pcr_ec
        call outi16
        jr pcr_nx
pcr_ec: ld b,16                     ; (the early clock: bit 7 of every byte)
pcr_eb: ld a,(hl)
        or 0x80
        out (c),a
        inc hl
        djnz pcr_eb
pcr_nx: exx
        ld a,l
        add a,ENT_SIZE - 1
        ld l,a
        inc c
        djnz pcr_lp
        ret

; C = SAT entry: the CPU's writes go to its colour row in the set rs_colhi names from now on.
; Keeps BC, DE, HL.
pcr_adr:
        push de
        ld a,c
        rlca
        rlca
        rlca
        rlca
        ld e,a
        and 0x0F
        ld d,a
        ld a,(rs_colhi)
        add a,d
        ld d,a                      ; the set's colour table + 16 * entry: high | 40h,
        ld a,e
        and 0xF0
        ld e,a                      ;   low
        call spr_wr
        pop de
        ret

; ----- SAT -----

; Every entry of the SAT being built (sat_nb) parked.
sat_park:
        ld a,(cam_y)
        add a,PARK_LINE - 1
        cp 216
        jr nz,sk_y
        dec a
sk_y:   ld (sb_parky),a
        ld hl,(sat_nb)
        ld b,SAT_MAX
sk_lp:  ld (hl),a                   ; (y only: x and pattern do not matter there)
        inc l
        inc l
        inc l
        inc l
        djnz sk_lp
        ret

; The SAT of the versions shown (disp, as the plan left them) at the objects' places, for the
; frame being published, into the pair of buffers the frame on screen does not use (sat_nb;
; isr.asm writes the pair's first, or with objects alternating its first on even frames and
; its second, + 80h, on odd ones): every entry parked, then each shown object's entries at its
; run; alternating objects of phase 0 are parked in the second, those of phase 1 in the first.
; pub_cur records what it shows (test builds, EXTJOY: tools/objcmp.py, msxframe.py).
sat_build:
        ld hl,(sat_cur)
        ld a,h
        xor (sat_pair0 ^ sat_pair1) / 256
        ld h,a
        ld l,0
        ld (sat_nb),hl
        call sat_park
        ld ix,obj_tab
        ld iy,disp
        if EXTJOY
        ld hl,pub_cur
        ld (sb_pub),hl              ; its pub_cur record (test builds)
        endif
        xor a
sb_olp: ld (sb_obj),a
        ld a,(iy+V_ON)
        or a
        jr nz,sb_pres
        if EXTJOY
        call sb_want                ; not shown (what it wants, if anything)
        endif
        jr sb_onext
sb_pres:
        ld a,(iy+V_RUN)
        add a,a
        add a,a
        ld e,a
        ld a,(sat_nb+1)
        ld d,a                      ; DE = its first SAT entry
        call sb_object
sb_onext:
        if EXTJOY
        ld hl,(sb_pub)
        ld de,8
        add hl,de
        ld (sb_pub),hl
        endif
        ld de,OBJ_SIZE
        add ix,de
        ld de,LAY_SIZE
        add iy,de
        ld a,(sb_obj)
        inc a
        cp MAX_OBJ
        jr c,sb_olp
        ret

; IX = object, IY = its disp record, DE = its first SAT entry: writes its entries and its
; pub_cur record. RoboCop's position is the composition's top-left for the composition the
; game asked for, but the version shown may still be an older one (the new one is on its way):
; that one goes where its own hotspot puts it (sb_rchot), so a new frame of animation or a turn
; does not shift the old one by the hotspots' difference. An object wholly off the play area
; keeps its entries parked.
sb_object:
        ld (sb_de0),de
        ld l,(ix+O_X)
        ld h,(ix+O_X+1)
        ld (sb_ox),hl
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        ld (sb_oy),hl
        ld a,(iy+V_KIND)            ; kind: 0 RoboCop
        or a
        call z,sb_rchot
        if EXTJOY
        ld a,(iy+V_EC)
        and 3
        add a,a
        ld hl,(sb_pub)
        or (iy+V_KIND)
        ld (hl),a
        ld a,(ix+O_FLAGS)
        and 0x40                    ; (alternating)
        or 0x80
        or (hl)
        ld (hl),a                   ; flags: bit 7 shown, bit 6 alternating, bits 1-2 silhouette,
        inc hl                      ; bit 0 BOB
        ld a,(iy+V_ID)              ; what is shown (a new version may be on its way)
        ld (hl),a
        inc hl
        ld a,(iy+V_ID+1)
        ld (hl),a
        inc hl
        ld a,(iy+V_DROP)
        ld (hl),a                   ; dropped columns
        inc hl
        ld a,(sb_ox)
        ld (hl),a
        inc hl
        ld a,(sb_ox+1)
        ld (hl),a                   ; (y after the 216 check)
        endif
        ld a,(sb_obj)
        add a,a
        add a,(iy+V_PAGE)
        add a,ENT_PAGE
        ld (sb_page),a
        ld hl,(sb_oy)               ; wholly above or below the play area: parked (its SAT y
                                    ; would wrap around into it)
        bit 7,h
        jr z,sbo_yb
        ld e,(iy+V_LINES)
        ld d,0
        add hl,de                   ; its end
        bit 7,h
        jp nz,sb_parkall
        ld a,h
        or l
        jp z,sb_parkall
        jr sbo_on
sbo_yb: ld a,h
        or a
        jp nz,sb_parkall
        ld a,l
        cp VIEW_LINES
        jp nc,sb_parkall
sbo_on: ld hl,(sb_ox)               ; SAT x of dx = 0
        ld a,(spr_xadj)
        ld e,a
        rla
        sbc a,a
        ld d,a
        add hl,de
        bit 7,(iy+V_EC)
        jr z,sbo_xb
        ld de,32                    ; early clock: the VDP shows it 32 px further left
        add hl,de
sbo_xb: ld (sb_xbase),hl
        ld a,(iy+V_MINDX)
        call xpos
        ld a,h
        push af
        ld a,(iy+V_MAXDX)
        call xpos
        pop af
        or h
        ld (sb_slow),a              ; non-zero: check every sprite's x
        ld a,(sb_oy)
        ld c,a
        ld a,(cam_y)
        dec a
        add a,c
        ld (sb_y0),a                ; SAT y of dy = 0
        xor a
        ld (sb_dy),a
sbo_go: ld de,(sb_de0)
        ld a,(sb_page)
        ld h,a
        ld l,0
        ld b,(iy+V_N)
        ld a,(sb_y0)
        ld c,a
        ld a,(sb_dy)
        add a,c
        ld c,a                      ; C = SAT y of dy = 0 with the offset
        ld a,(sb_slow)
        or a
        jr nz,sbs_lp
sbo_lp: ld a,(hl)                   ; dy
        add a,c
        cp 216
        jp z,sb_hit
        ld (de),a
        inc e
        inc l
        ld a,(sb_xbase)
        add a,(hl)                  ; dx
        ld (de),a
        inc e
        inc l
        ld a,(hl)                   ; pattern number
        ld (de),a
        inc e
        inc e
        ld a,l
        add a,ENT_SIZE - 2
        ld l,a
        djnz sbo_lp
        jr sbo_end
sbs_lp: ld a,(hl)                   ; (some sprites may fall outside 0..255)
        add a,c
        cp 216
        jp z,sb_hit
        ld (de),a
        inc e
        inc l
        ld a,(hl)
        push hl
        push de
        call xpos
        ld a,h
        or a
        ld a,l
        pop de
        pop hl
        jr z,sbs_x
        dec e
        ld a,(sb_parky)             ; outside 0..255: parked
        ld (de),a
        inc e
sbs_x:  ld (de),a
        inc e
        inc l
        ld a,(hl)
        ld (de),a
        inc e
        inc e
        ld a,l
        add a,ENT_SIZE - 2
        ld l,a
        djnz sbs_lp
sbo_end:
        if EXTJOY
        ld hl,(sb_pub)              ; the y it is shown at
        ld de,6
        add hl,de
        ld a,(sb_dy)
        ld e,a
        rla
        sbc a,a
        ld d,a
        push hl
        ld hl,(sb_oy)
        add hl,de
        ex de,hl
        pop hl
        ld (hl),e
        inc hl
        ld (hl),d
        endif
        ret

; IY = a version record of RoboCop's -> A = the hotspot y of its record minus the one the game
; asked for (p_hoty: pl_frame), signed. Keeps BC, DE.
sb_rcdy:
        push bc
        push de
        call srh_hot
        inc hl
        ld a,(p_hoty)
        ld c,a
        ld a,(hl)
        sub c
        pop de
        pop bc
        ret

; IY = a version record of RoboCop's -> HL = the pl_hot entry (x, y) of its record. Uses AF, DE.
srh_hot:
        ld l,(iy+V_ID)
        ld h,(iy+V_ID+1)            ; the id shown: record * 4 + aim, or an arm pose
        push hl
        ld de,(0 - SPR_RC_ARM) & 0xFFFF
        add hl,de
        pop hl
        ld a,PL_ARM_REC
        jr c,srh_rec                ; (an arm pose: their record)
        srl h
        rr l
        srl h
        rr l
        ld a,l
srh_rec:
        ld e,a
        ld d,0
        ld hl,pl_hot
        add hl,de
        add hl,de
        ret

; RoboCop (IY = his disp record): sb_ox / sb_oy moved by the hotspot of the record shown minus
; the one the game asked for (p_hotx, p_hoty: pl_frame). Keeps DE.
sb_rchot:
        push de
        call srh_hot
        ld a,(p_hotx)
        ld c,a
        ld a,(hl)
        sub c                       ; shown - asked (small, signed)
        ld e,a
        rla
        sbc a,a
        ld d,a
        inc hl
        push hl
        ld hl,(sb_ox)
        add hl,de
        ld (sb_ox),hl
        pop hl
        ld a,(p_hoty)
        ld c,a
        ld a,(hl)
        sub c
        ld e,a
        rla
        sbc a,a
        ld d,a
        ld hl,(sb_oy)
        add hl,de
        ld (sb_oy),hl
        pop de
        ret

; An entry would get SAT y 216, which ends the table: the whole object moves by the next
; offset (0, -1, +1, -2, +2, ...) and its entries are built again (never one part against
; the others).
sb_hit: ld a,(sb_dy)
        or a
        jp m,sbh_neg
        cpl                         ; o >= 0: -o - 1
        jr sbh_set
sbh_neg:
        neg                         ; o < 0: -o
sbh_set:
        ld (sb_dy),a
        jp sbo_go

; An object wholly off the play area: its entries stay parked; its pub_cur record keeps its y.
sb_parkall:
        if EXTJOY
        ld hl,(sb_pub)
        ld de,6
        add hl,de
        ld a,(ix+O_Y)
        ld (hl),a
        inc hl
        ld a,(ix+O_Y+1)
        ld (hl),a
        endif
        ret

        if EXTJOY
; IX = an object no version of which is shown: its pub_cur record holds what it wants, flags bit
; 5 (and bit 4 when the budget left it out this tick, bit 0 a BOB), or 0 when it wants nothing
; (test builds: tools/objcmp.py tells why a BOB is missing).
sb_want:
        ld hl,(sb_pub)
        ld (hl),0
        bit 7,(ix+O_FLAGS)
        ret z
        ld a,(ix+O_OUT)
        or a
        ld a,0x20
        jr z,sw_f
        ld a,0x30
sw_f:   or (ix+O_KIND)
        ld (hl),a
        inc hl
        ld a,(ix+O_ID)
        ld (hl),a
        inc hl
        ld a,(ix+O_ID+1)
        ld (hl),a
        inc hl
        ld (hl),0
        inc hl
        ld a,(ix+O_X)
        ld (hl),a
        inc hl
        ld a,(ix+O_X+1)
        ld (hl),a
        inc hl
        ld a,(ix+O_Y)
        ld (hl),a
        inc hl
        ld a,(ix+O_Y+1)
        ld (hl),a
        ret
        endif

; A = dx (signed) -> HL = sb_xbase + dx.
xpos:   ld e,a
        rla
        sbc a,a
        ld d,a
        ld hl,(sb_xbase)
        add hl,de
        ret

; ----- frame -----

; Once per published frame: the SAT x correction of the camera, the plan (versions, queues),
; then the SAT when something moved or a version changed (the VBLANK interrupt writes it when
; it puts the frame's list on screen).
sprites_frame:
        ld a,(act_a000)             ; (the uploads map the pools at A000h: the bank back at the end)
        push af
        ld a,(hud_msk)              ; non-zero: V9958 engine (R#26/R#27 do not move sprites)
        or a
        ld a,0
        jr nz,sf_xadj
        ld a,(cam_x)
        and 15
        sub 8                       ; V9938: R#18 moves sprites by 8 - f
sf_xadj:
        ld (spr_xadj),a
        call spr_plan
        ld a,(fl_n)
        ld (fl_mark),a              ; (the slots this plan released go at the next one's start)
        call feed_vdp
        ld a,(sat_dirty)
        or a
        jr z,sf_end
        xor a
        ld (sat_dirty),a
        ld a,(spr_set)              ; the list goes to the other sprite set (the one on screen is
        xor R5_SET_A ^ R5_SET_B     ; the last list's: wait_frame waited for it)
        ld (spr_set),a
        ld hl,col_held
        ld b,((SPR_COL_A >> 8) & 0x3F) | 0x40
        cp R5_SET_A
        jr z,sf_set
        ld hl,col_held_b
        ld b,((SPR_COL_B >> 8) & 0x3F) | 0x40
sf_set: ld (rs_held),hl
        ld a,b
        ld (rs_colhi),a
        call rows_sync              ; its colour rows
        call feed_vdp
        call sat_build
        call feed_vdp
        call q_sat                  ; and its SAT
        ld a,1
        ld (spr_vblank),a           ; (the list switches sets: tools/msxframe.py reads it)
sf_end: pop af
        jp bank_a000

; The SAT just built (sat_nb, its first half) into the SAT of the set spr_set names, now (that set
; is not on screen).
q_sat:  ld a,(spr_set)
        cp R5_SET_A
        ld d,(((SPR_COL_A + 0x200) >> 8) & 0x3F) | 0x40
        jr z,qs_a
        ld d,(((SPR_COL_B + 0x200) >> 8) & 0x3F) | 0x40
qs_a:   ld e,0                      ; (the SATs start at 256-byte boundaries)
        call spr_wr
        ld hl,(sat_nb)
        ld c,VDP_DATA
        call outi32
        call outi32
        call outi32
        jp outi32

; ----- the interrupts' side (isr.asm) -----

; The split interrupt and the VBLANK one: nothing to upload any more (every pattern, colour row and
; SAT is written by the main program when the plan needs it: pat_now, pc_rows, q_sat; until
; 2026-10-23 they went through a frame's queue and a background queue that these copied in the
; HUD's lines and the blank: the queue writing, the copies' set-up and the waiting cost more than
; the bytes, and a picture reached the screen a VBLANK late). spr_upload keeps C = VDP_CTRL for
; isr.asm.
spr_upload:
        ld c,VDP_CTRL
spr_late:
        ret

; A new list on screen (VBLANK) that switched sprite sets (a SAT built for it, prepared in the
; set its R#5 shows): that pair of SAT buffers is the one on screen from now on (sat_cur) and
; the set (spr_dsp). (Interrupt code: keeps DE, which the interrupt does not save.)
iv_sat: ld a,(spr_vblank)
        or a
        ret z                       ; (no SAT of its own: the set on screen goes on)
        xor a
        ld (spr_vblank),a
        ld hl,(sat_nb)
        ld (sat_cur),hl
        ld a,(spr_set)
        ld (spr_dsp),a
        ret

        if DEMO_ACTORS              ; (builds with the demo actors only)

; ----- demo of the game's objects (DEMO_ACTORS > 0: until the enemies are ported) -----

COST_DEMO:  equ 60                  ; its work in upload units
DA_SIZE:    equ 16                  ; demo actor: kind (0 screen, 1 world), frame A, frame B,
                                    ; frame period (ticks = 2^n; FFh: frames A..A+7 in turn),
                                    ; x (2), y (2), direction, speed

; Screen actors bounce across the play area; world actors scroll with the map and come back
; ahead of the camera when they leave the screen.
spr_demo_init:
        ld hl,demo_actors
        ld de,demo_tab
        ld bc,DEMO_ACTORS*DA_SIZE
        ldir
        xor a
        ld (demo_timer),a
        ret

demo_tick:
        ld a,COST_DEMO
        call spr_charge
        ld hl,demo_timer
        inc (hl)
        ld iy,demo_tab
        ld c,1                      ; object
dt_lp:  push bc
        ld a,(iy+3)                 ; frame
        cp 0xFF
        jr nz,dt_ab
        ld a,(demo_timer)
        and 7
        add a,(iy+1)
        jr dt_f
dt_ab:  ld b,a
        ld a,(demo_timer)
        inc b
dt_sh:  dec b
        jr z,dt_sd
        srl a
        jr dt_sh
dt_sd:  rrca
        ld a,(iy+1)
        jr nc,dt_f
        ld a,(iy+2)
dt_f:   ld e,a
        ld d,0
        pop bc
        push bc
        ld a,c
        call obj_bob
        ld a,(iy+0)                 ; position
        or a
        jr nz,dt_world
        ld l,(iy+4)                 ; screen actor: bounces in x between 0 and 208
        ld h,(iy+5)
        ld e,(iy+9)
        ld d,0
        ld a,(iy+8)
        or a
        jr nz,dt_left
        add hl,de
        ld a,l
        cp 208
        jr c,dt_sx
        ld (iy+8),1
        jr dt_sx
dt_left:
        or a
        sbc hl,de
        jr nc,dt_sx0
        ld hl,0
dt_sx0: ld a,h
        or l
        jr nz,dt_sx
        ld (iy+8),0
dt_sx:  ld (iy+4),l
        ld (iy+5),h
        ld e,(iy+6)
        ld d,(iy+7)
        jr dt_pos
dt_world:
        call dt_wrap
        ld l,(iy+4)                 ; screen = world - camera (+8 in x)
        ld h,(iy+5)
        ld de,(cam_x)
        or a
        sbc hl,de
        ld de,8
        add hl,de
        push hl
        ld l,(iy+6)
        ld h,(iy+7)
        ld de,(cam_y)
        or a
        sbc hl,de
        ex de,hl
        pop hl
dt_pos: pop bc
        push bc
        ld a,c
        call obj_pos
        pop bc
        inc c
        ld de,DA_SIZE
        add iy,de
        ld a,c
        cp DEMO_ACTORS + 1
        jp c,dt_lp
        ret

; IY = world actor: when the camera left it behind (more than 96 px to the left of the screen
; while it goes right, 300 px from its left edge while it goes left; below line 200 while it
; goes up, above line -64 while it goes down), it moves ahead (400 px in x, 300 lines in y).
dt_wrap:
        ld l,(iy+4)
        ld h,(iy+5)
        ld de,(cam_x)
        or a
        sbc hl,de                   ; x on screen - 8 (signed)
        ld a,(dir_x)
        or a
        jr nz,dw_cl
        ld de,96
        add hl,de
        bit 7,h
        jr z,dw_y
        ld de,400
        jr dw_x
dw_cl:  bit 7,h
        jr nz,dw_y
        ld de,-300
        add hl,de
        bit 7,h
        jr nz,dw_y
        ld de,-400
dw_x:   ld l,(iy+4)
        ld h,(iy+5)
        add hl,de
        ld (iy+4),l
        ld (iy+5),h
dw_y:   ld l,(iy+6)
        ld h,(iy+7)
        ld de,(cam_y)
        or a
        sbc hl,de                   ; y on screen (signed)
        ld a,(dir_y)
        or a
        jr nz,dw_cd
        bit 7,h                     ; camera going up
        ret nz
        ld de,-200
        add hl,de
        bit 7,h
        ret nz
        ld de,-300
        jr dw_ys
dw_cd:  bit 7,h                     ; camera going down
        ret z
        ld de,64
        add hl,de
        bit 7,h
        ret z
        ld de,300
dw_ys:  ld l,(iy+6)
        ld h,(iy+7)
        add hl,de
        ld (iy+6),l
        ld (iy+7),h
        ret

; kind, frame A, frame B, period, x, y, direction, speed (BOB frames: build/msx/robocop.json)
demo_actors:
        db 0, 44, 45, 5
        dw 0, 93
        db 0, 2
        ds 6, 0                     ; gunner (48x40) crossing RoboCop's lines
        db 0, 46, 47, 5
        dw 176, 85
        db 1, 1
        ds 6, 0                     ; woman (32x48), the other way
        db 1, 38, 39, 6
        dw 200, 713
        db 0, 0
        ds 6, 0                     ; bazooka (48x40) in the map
        db 1, 0, 0, 0
        dw 120, 675
        db 0, 0
        ds 6, 0                     ; vehicle (48x24) in the map
        db 1, 28, 28, 0xFF
        dw 60, 760
        db 0, 0
        ds 6, 0                     ; explosion (16x16), its 8 frames in turn
        endif
