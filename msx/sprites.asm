; Hardware sprites (sprite mode 2, OR technique): RoboCop and the level's BOBs (enemies, shots,
; explosions...), with the adaptive budget.
;
; Data from tools/msxsprites.py (FORMAT there): compositions (RoboCop: per frame record and
; aim; BOBs: per frame), each a list of 16x16 sprites in SAT order (per column: A spans, then
; the B spans that OR into them, CC = 1), the sprites on each line and the columns in order of
; what dropping their OR layer costs. Index and compositions through the 8000h window, the
; pattern and colour pools through A000h.
;
; Objects (obj_tab): object 0 is RoboCop, the others BOB groups (an enemy drawn from parts takes
; one object per part). The game sets their compositions and screen positions; on every tick
; (sprites_tick) the budget chooses the dropped OR layers and, when what must be shown changes,
; a layout for the set that is not on screen is built; sprites_frame uploads it a slice per
; frame and, once complete, the next list shows that set.
;
; Sets: two (colour table + SAT, R#5). The 64 slots of the pattern table are shared: a pattern
; both sets use stays in one slot. A layout gives every object a run of SAT entries (object 0
; first, so it is drawn in front; a dropped B sprite takes none) and one of the object's two
; entry pages (ent_pages: per entry dy, dx, pattern slot, pattern and colour ids). An object
; whose composition, dropped columns and early clock are the same in the layout on screen
; keeps that page, and so its slots; otherwise its other page is filled from the composition
; with free slots. The entry's colour table row is the sprite's colour row. The SAT of the set
; on screen is written right after the VBLANK that puts the frame's registers on screen
; (sprites_vblank).
;
; Budget (on the frame after the game's tick, only when an object changed what it looks at):
; the VDP shows 8 sprites per line and 32 in all. When even the single-layer versions pass 32,
; the objects that do not fit then (in object order after RoboCop) are left out of this tick.
; Lines can only go over 8 where objects meet; each composition carries the most sprites it
; puts on a line (full, one layer, and after each prefix of its rank list), so the sums at each
; object's first line (where the sums grow) tell where they can. There, the BOBs drop their OR
; layers (their B sprites go, their A sprites switch to the single-layer A1, which never leaves
; holes) and RoboCop drops the fewest of his cheapest ones that let him fit beside them; when
; even that cannot fit, the BOBs that meet alternate between frames (multiplexing; RoboCop is
; always shown). Dropped columns stay dropped while the object keeps its composition (no flicker
; of quality, no new layout every tick). Then, while the total is above 32, the cheapest OR
; layers anywhere go.
; The alternate registers are free for this code: the ISR does not use them.

MAX_OBJ:    equ 16
OBJ_SIZE:   equ 32
O_FLAGS:    equ 0                   ; bit 7 shown, bit 6 alternating, bit 0 its phase
O_BANK:     equ 1                   ; composition: bank (relative to SPR_BASE_BANK),
O_COMP:     equ 2                   ;   2 bytes: address in the 8000h window
O_DROP:     equ 4                   ; dropped columns (budget)
O_EC:       equ 5                   ; 80h: its sprites use the early clock (O_BANK..O_EC as in a
                                    ; layout entry)
O_X:        equ 6                   ; 2 bytes: screen x of the composition's top-left
O_Y:        equ 8                   ; 2 bytes: screen y
O_NSPR:     equ 10                  ; composition header (COMP_HDR bytes): sprites,
O_NLINES:   equ 11                  ;   lines covered,
O_NCOLS:    equ 12                  ;   columns,
O_MINDX:    equ 13                  ;   leftmost and rightmost sprite dx,
O_MAXDX:    equ 14
O_NA:       equ 15                  ;   sprites of its single-layer version,
O_MFULL:    equ 16                  ;   most sprites on a line,
O_MONE:     equ 17                  ;   the same on one layer
O_KIND:     equ 18                  ; 0 RoboCop, 1 BOB (O_KIND, O_ID as in a layout entry)
O_ID:       equ 19                  ; 2 bytes: record * 4 + aim, or BOB frame
O_RANK:     equ 21                  ; 2 bytes: its rank list (8000h window)
O_LO:       equ 23                  ; budget: first visible line,
O_HI:       equ 24                  ;   end (0: none),
O_INV:      equ 25                  ;   1: meets another object,
O_GONE:     equ 26                  ;   sprites its dropped columns remove (O_DROP and O_GONE
                                    ;   stay from tick to tick while the composition does),
O_OUT:      equ 27                  ;   1: left out this tick (the objects pass 32 even on one layer),
O_MAXK:     equ 28                  ; 2 bytes: most sprites on a line per rank prefix dropped
O_BMASK:    equ 30                  ; its columns that have B spans
LAY_SIZE:   equ 16                  ; layout entry: present (80h), bank, comp (2), drop, ec,
                                    ; first SAT entry, entries, kind, id (2), page, min dx, max dx,
                                    ; FFh while its page is to be filled (lay_build), lines
EC_ON:      equ 32                  ; early clock on when the leftmost sprite's x falls below this,
EC_OFF:     equ 64                  ;   off from this (ahead of time: a new layout takes frames)
ENT_SIZE:   equ 8                   ; entry: dy, dx, pattern number, slot, pattern id (2),
                                    ; colour id | 8000h early clock (2)
ENT_PAGE:   equ ent_pages/256       ; page of object o, version v: ENT_PAGE + 2 o + v
SPR_SLOTS:  equ 64                  ; 16x16 patterns in the pattern table (2 KiB at SPR_PAT)
PAT_IDS:    equ (SPR_COL_BANK - SPR_PAT_BANK) * 256 ; pattern ids (pat_slot entries)
LINE_LIMIT: equ 8
SAT_MAX:    equ 32
PARK_LINE:  equ 200                 ; screen line of parked sprites (HUD: sprites off there)
COMP_HDR:   equ 8                   ; composition: nspr, nlines, ncols, min dx, max dx, A spans,
                                    ; most sprites on a line, the same on one layer
REC_SIZE:   equ 12                  ; sprite record: dy, dx, park bit, A1 bit, 4 words
UP_TOTAL:   equ 400                 ; work per frame (units of about 100 T-states) that the HUD,
                                    ; the game logic, the sprite tick, the SAT and the upload share
                                    ; (hud_cost + spr_cost; the upload takes what is left):
UP_LOOK:    equ 2                   ;   looking at an entry,
UP_PAT:     equ 9                   ;   writing a pattern,
UP_COL:     equ 5                   ;   writing a colour row,
UP_FILL:    equ 5                   ;   filling a page entry (up_fills),
COST_BUDGET: equ 100                ;   the budget,
COST_LAYB:  equ 140                 ;   a layout (lay_build),
COST_PHASE: equ 50                  ;   sat_phase,
COST_SATO:  equ 12                  ;   sat_build: an object,
COST_SATE:  equ 2                   ;     an entry
HUD_HEAVY:  equ 90                  ; HUD work (units) from which the layout of a tick waits

sprites_init:
        ld hl,obj_tab
        ld bc,MAX_OBJ*OBJ_SIZE
        xor a
        call fill
        ld hl,lay
        ld bc,2*MAX_OBJ*LAY_SIZE
        xor a
        call fill                   ; both layouts empty
        ld hl,lay_col
        ld bc,2*SAT_MAX*2
        ld a,0xFF
        call fill                   ; colour rows unknown
        ld hl,pat_held
        ld bc,SPR_SLOTS*2
        ld a,0xFF
        call fill                   ; patterns unknown
        ld hl,pat_slot
        ld bc,PAT_IDS
        ld a,0xFF
        call fill                   ; and put nowhere
        ld hl,pub_cur
        ld bc,MAX_OBJ*8
        xor a
        call fill
        ld a,1
        ld (bu_dirty),a             ; (the budget runs on the first tick)

        ld a,216
        ld (sat_buf),a              ; nothing shown
        xor a
        ld (lay_n),a
        ld (lay_n+1),a
        ld (spr_shown),a
        ld (up_state),a
        ld (spr_vblank),a
        ld (mux_on),a
        ld (spr_n),a
        ld (alloc_p),a
        ld a,1
        ld (sat_dirty),a
        ret

; During long work: the scroll engine's idle work (its next VDP command when the command engine
; is free), so that the VDP does not wait for the end of the frame. Keeps all registers but the
; A000h window (the upload maps it before each use).
feed_vdp:
        push af
        push bc
        push de
        push hl
        call idle_work
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

; Right after the VBLANK that put the last published list on screen (wait_frame): the SAT
; built for that list goes into the set it shows, before the first display line.
sprites_vblank:
        xor a
        ld (spr_cost),a             ; (a new frame)
        ld a,(spr_vblank)
        or a
        ret z
        ld a,(spr_shown)
        or a
        ld hl,(SPR_COL_A + 0x200) & 0xFFFF
        jr z,sv_set
        ld hl,(SPR_COL_B + 0x200) & 0xFFFF
sv_set: ld e,1
        call vram_write
        ld a,(spr_n)
        add a,a
        add a,a                     ; 4 bytes per entry
        cp 4*SAT_MAX
        jr z,sv_full
        inc a                       ; and the 216 after the last one
sv_full:
        ld b,a
        ld hl,sat_buf
        ld c,VDP_DATA
        otir
        xor a
        ld (spr_vblank),a           ; (cleared once the SAT is there: tools/msxframe.py reads it)
        ret

; ----- objects -----

; A = object -> IX = its entry. Keeps BC, DE.
obj_ix:
        push de
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,obj_tab
        add hl,de
        push hl
        pop ix
        pop de
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
        ld ix,obj_tab
        ld l,a
        ld h,0
        ld de,SPR_RC_ARM
        add hl,de
        xor a
        jr obj_set

; A = object, DE = BOB frame: that object takes the frame's composition.
obj_bob:
        call obj_ix
        ex de,hl
        ld a,1                      ; kind 1

; IX = object, HL = id, A = kind: the object takes that composition (nothing to do when it
; already shows it) and is shown.
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
        ret z                       ; the same
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
        ld (ix+O_RANK),l
        ld (ix+O_RANK+1),h
        ld a,1
        ld (bu_dirty),a             ; (the budget looks at the composition)
        ld b,(ix+O_NCOLS)
        ld c,0
os_bm:  ld a,(hl)                   ; the columns with B spans
        inc hl
        inc hl
        ld e,(hl)
        inc hl
        inc e
        dec e
        jr z,os_bn
        or c
        ld c,a
        add hl,de
os_bn:  djnz os_bm
        ld (ix+O_BMASK),c
        ld (ix+O_MAXK),l            ; the maxima after the rank list
        ld (ix+O_MAXK+1),h
        set 7,(ix+O_FLAGS)
        ret

; A = object: no longer shown.
obj_hide:
        call obj_ix
        bit 7,(ix+O_FLAGS)
        ret z
        ld (ix+O_FLAGS),0
        ld a,1
        ld (bu_dirty),a
        ret

; A = object, HL = screen x, DE = screen y of its composition's top-left.
obj_pos:
        push hl
        call obj_ix
        pop hl
        ld (ix+O_X),l
        ld (ix+O_X+1),h
        ld a,e
        cp (ix+O_Y)
        jr nz,op_y
        ld a,d
        cp (ix+O_Y+1)
        ret z
op_y:   ld (ix+O_Y),e
        ld (ix+O_Y+1),d
        ld a,1                      ; (the budget looks at y)
        ld (bu_dirty),a
        ret

; ----- tick -----

; After the game moved the objects (and the camera): the next SAT shows them where they are.
sprites_moved:
        ld a,1
        ld (sat_dirty),a
        ret

; On the frame after the game's tick: the budget (unless nothing it looks at changed since it
; last ran) and a new layout for the set that is not on screen when what must be shown changed.
sprites_tick:
        ld a,(mux_on)
        push af
        ld a,(bu_dirty)
        or a
        jr z,st_same
        xor a
        ld (bu_dirty),a
        call budget
        call feed_vdp
        ld a,COST_BUDGET
        call spr_charge
        jr st_lay
st_same:
        call obj_ecs                ; (the early clocks follow x)
st_lay: ld a,(hud_cost)              ; a frame the HUD took much of: the layout waits a tick
        cp HUD_HEAVY                ; (once in a row)
        jr c,st_lk
        ld a,(st_wait)
        or a
        jr nz,st_lk
        inc a
        ld (st_wait),a
        jr st_mx
st_lk:  xor a
        ld (st_wait),a
        call lay_check
        call feed_vdp
st_mx:  pop af                      ; (alternating before)
        ld b,a
        ld a,(mux_on)
        or a
        ret z                       ; (when it stops, the next game frame builds the SAT again)
        ld a,b
        or a
        ret nz                      ; still alternating: sat_phase goes on with sat_full
        ld hl,sat_buf               ; it starts: the SAT built shows every object, sat_full
        ld de,sat_full
        ld bc,4*SAT_MAX + 1
        ldir
        ret

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

budget:
        xor a
        ld (bu_over),a              ; (1: some line keeps more than 8)
        ld (mux_on),a
        ld (bu_tot),a
        ld (bu_one),a
        ld (bu_cut),a
        ld ix,obj_tab
        ld b,MAX_OBJ
bg_r:   xor a
        ld (ix+O_INV),a
        ld (ix+O_LO),a
        ld (ix+O_HI),a
        ld (ix+O_OUT),a
        ld a,(ix+O_FLAGS)
        and 0x80
        ld (ix+O_FLAGS),a           ; (not alternating)
        jr z,bg_rn
        call obj_ec
        call bg_range
        ld hl,bu_tot                ; the totals: as the objects are (their dropped columns stay
        ld a,(ix+O_NSPR)            ; while their compositions do), and with every column on
        sub (ix+O_GONE)             ; one layer
        add a,(hl)
        ld (hl),a
        inc hl
        ld a,(hl)
        add a,(ix+O_NA)
        ld (hl),a
bg_rn:  ld de,OBJ_SIZE
        add ix,de
        djnz bg_r
        ld ix,obj_tab               ; RoboCop counts on one layer with his largest version, so
        bit 7,(ix+O_FLAGS)          ; that the objects left out do not change with his frames
        jr z,bg_rc1
        ld a,(bu_one)
        sub (ix+O_NA)
        add a,SPR_RC_ONE
        ld (bu_one),a
bg_rc1: ld a,(bu_one)
        cp SAT_MAX + 1
        call nc,bg_cut
        call bg_depth
        ld a,(bu_ninv)
        or a
        jp z,bg_total               ; no line can go above the limit
        ld ix,obj_tab + OBJ_SIZE    ; the BOBs that meet others go on one layer
        ld b,MAX_OBJ - 1
bsi_lp: ld a,(ix+O_INV)
        or a
        call nz,bg_onelayer
bsi_n:  ld de,OBJ_SIZE
        add ix,de
        djnz bsi_lp
        call bg_need
        ld ix,obj_tab               ; RoboCop: the fewest of his cheapest OR layers that let him fit
        ld a,(ix+O_INV)
        or a
        call nz,bg_robo
bg_mux: ld a,(bu_over)
        or a
        jr z,bg_total
        ld ix,obj_tab               ; lines still above the limit: the BOBs that meet alternate
        ld b,MAX_OBJ
        ld c,1
bx_lp:  ld a,(ix+O_INV)
        or a
        jr z,bx_nx
        ld a,(ix+O_KIND)
        or a
        jr z,bx_nx                  ; RoboCop is always shown
        ld a,(ix+O_FLAGS)
        or 0x40
        or c
        ld (ix+O_FLAGS),a
        ld a,c
        xor 1
        ld c,a
        ld hl,mux_on
        inc (hl)
bx_nx:  ld de,OBJ_SIZE
        add ix,de
        djnz bx_lp
bg_total:
        ld a,(bu_tot)               ; above 32 sprites after the line phase: the BOBs' OR layers
        cp SAT_MAX + 1              ; go (object order), then RoboCop's, cheapest first, until the
        ret c                       ; total fits (the objects kept fit on one layer: bg_cut)
        ld ix,obj_tab + OBJ_SIZE
        ld d,MAX_OBJ - 1
btb:    bit 7,(ix+O_FLAGS)
        jr z,btb_n
        ld a,(ix+O_OUT)
        or a
        jr nz,btb_n
        call bg_onelayer
        ld a,(bu_tot)
        cp SAT_MAX + 1
        ret c
btb_n:  ld bc,OBJ_SIZE
        add ix,bc
        dec d
        jr nz,btb
        ld ix,obj_tab
        bit 7,(ix+O_FLAGS)
        ret z
        ld a,(ix+O_BANK)
        add a,SPR_BASE_BANK
        call bank_8000
        ld l,(ix+O_RANK)
        ld h,(ix+O_RANK+1)
        ld b,(ix+O_NCOLS)
btr:    push bc
        ld a,(hl)                   ; column bit
        ld (tmp_k),a
        inc hl
        inc hl
        ld a,(hl)                   ; B sprites
        ld (tmp_n),a
        inc hl
        ld e,a
        ld d,0
        add hl,de
        or a
        jr z,btr_n
        ld a,(tmp_k)
        and (ix+O_DROP)
        jr nz,btr_n
        push hl
        call bt_mark
        pop hl
        ld a,(bu_tot)
        cp SAT_MAX + 1
        jr c,btr_x
btr_n:  pop bc
        djnz btr
        ret
btr_x:  pop bc
        ret

; IX = BOB: every column on one layer (its B sprites go; bu_tot, O_GONE follow).
bg_onelayer:
        ld a,(ix+O_BMASK)
        or (ix+O_DROP)
        ld (ix+O_DROP),a
        ld a,(bu_tot)
        add a,(ix+O_GONE)
        ld c,(ix+O_NSPR)
        sub c
        add a,(ix+O_NA)
        ld (bu_tot),a               ; - NSPR + GONE + NA
        ld a,c
        sub (ix+O_NA)
        ld (ix+O_GONE),a
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
        ld (ix+O_EC),0
        ret
oec_on: ld (ix+O_EC),0x80
        ret

; IX = shown object -> O_LO, O_HI: its lines on screen (O_HI = 0: none). Keeps BC.
bg_range:
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        ld e,(ix+O_NLINES)
        ld d,0
        add hl,de                   ; end (signed)
        bit 7,h
        ret nz                      ; above the screen
        ld a,h
        or a
        ld a,VIEW_LINES
        jr nz,br_e
        ld a,l
        cp VIEW_LINES
        jr c,br_e
        ld a,VIEW_LINES
br_e:   ld (ix+O_HI),a
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        bit 7,h
        ld a,0
        jr nz,br_s                  ; starts above: from line 0
        ld a,h
        or a
        jr nz,br_none
        ld a,l
        cp VIEW_LINES
        jr nc,br_none               ; starts below the play area
br_s:   ld (ix+O_LO),a
        cp (ix+O_HI)
        ret c
br_none:
        ld (ix+O_HI),0
        ld (ix+O_LO),0
        ret

; Even with every column on one layer the objects pass 32 sprites: in object order after RoboCop
; (counted with SPR_RC_ONE), those that do not fit then are left out this tick (O_OUT); bu_cut = 1.
bg_cut: ld a,1
        ld (bu_cut),a
        ld ix,obj_tab + OBJ_SIZE
        ld b,MAX_OBJ - 1
        ld c,SPR_RC_ONE             ; one-layer sprites of the objects kept (RoboCop always)
cut_lp: bit 7,(ix+O_FLAGS)
        jr z,cut_n
        ld a,c
        add a,(ix+O_NA)
        cp SAT_MAX + 1
        jr nc,cut_out
        ld c,a
        jr cut_n
cut_out:
        ld (ix+O_OUT),1
        ld (ix+O_HI),0              ; (meets nothing)
        ld (ix+O_LO),0
        ld a,(bu_tot)
        sub (ix+O_NSPR)
        add a,(ix+O_GONE)
        ld (bu_tot),a
cut_n:  ld de,OBJ_SIZE
        add ix,de
        djnz cut_lp
        ret

BANDS:      equ (VIEW_LINES + 7) / 8 ; the line phase works on bands of 8 lines

; IX = object -> NZ when it takes part in the line phase (shown, not left out, lines on screen).
; Keeps BC, DE, HL.
bg_part:
        bit 7,(ix+O_FLAGS)
        ret z
        ld a,(ix+O_OUT)
        or a
        jr nz,bp_no
        ld a,(ix+O_HI)
        or a
        ret
bp_no:  xor a
        ret

; IX = object with lines on screen -> HL = bu_band entry of its first band, C = its bands.
; Keeps DE.
bg_bands:
        ld a,(ix+O_HI)
        dec a
        rrca
        rrca
        rrca
        and 0x1F
        ld c,a                      ; last band
        ld a,(ix+O_LO)
        rrca
        rrca
        rrca
        and 0x1F                    ; first band
        ld b,a
        add a,bu_band & 0xFF
        ld l,a
        ld h,bu_band/256
        ld a,c
        sub b
        inc a
        ld c,a
        ret

; Where lines can go above the limit, on bands of 8 lines (the cost grows with the objects, not
; their pairs): the most sprites each object can put on a line (O_MFULL) is added over the bands
; it covers; an object on a band above 8 meets others there (O_INV; bu_ninv of them).
bg_depth:
        xor a
        ld (bu_ninv),a
        ld hl,bu_band
        ld b,BANDS
bdz:    ld (hl),a
        inc l
        djnz bdz
        ld ix,obj_tab
        ld d,MAX_OBJ
bda:    call bg_part
        jr z,bda_n
        call bg_bands
        ld e,(ix+O_MFULL)
bda_l:  ld a,(hl)
        add a,e
        ld (hl),a
        inc l
        dec c
        jr nz,bda_l
bda_n:  ld bc,OBJ_SIZE
        add ix,bc
        dec d
        jr nz,bda
        ld ix,obj_tab
        ld d,MAX_OBJ
bdm:    call bg_part
        jr z,bdm_n
        call bg_bands
bdm_l:  ld a,(hl)
        cp LINE_LIMIT + 1
        jr nc,bdm_inv
        inc l
        dec c
        jr nz,bdm_l
        jr bdm_n
bdm_inv:
        ld (ix+O_INV),1
        ld hl,bu_ninv
        inc (hl)
bdm_n:  ld bc,OBJ_SIZE
        add ix,bc
        dec d
        jr nz,bdm
        ret

; With the BOBs that meet others on one layer: per band the most sprites the BOBs there can put
; on a line (O_MONE when on one layer, else O_MFULL) and the largest of them. Above 8: they
; alternate (bu_over = 1). On RoboCop's bands that hold BOBs, 8 less that sum is the most he may
; put on a line (bu_need) and 8 less the largest one (bu_needm: one BOB a frame when they
; alternate); both FFh when he meets none.
bg_need:
        xor a
        ld (bu_over),a
        ld hl,bu_band
        ld b,BANDS
bnz:    ld (hl),a
        inc l
        djnz bnz
        ld hl,bu_bmax
        ld b,BANDS
bnz2:   ld (hl),a
        inc l
        djnz bnz2
        ld ix,obj_tab + OBJ_SIZE
        ld d,MAX_OBJ - 1
bnb:    call bg_part
        jr z,bnb_n
        call bg_bands
        ld e,(ix+O_MFULL)
        ld a,(ix+O_INV)
        or a
        jr z,bnb_l
        ld e,(ix+O_MONE)
bnb_l:  ld a,(hl)
        add a,e
        ld (hl),a
        cp LINE_LIMIT + 1
        jr c,bnb_f
        ld a,1
        ld (bu_over),a              ; the BOBs alone pass 8 here
bnb_f:  ld a,l
        add a,bu_bmax - bu_band
        ld l,a
        ld a,(hl)
        cp e
        jr nc,bnb_m
        ld (hl),e
bnb_m:  ld a,l
        sub bu_bmax - bu_band - 1
        ld l,a
        dec c
        jr nz,bnb_l
bnb_n:  ld bc,OBJ_SIZE
        add ix,bc
        dec d
        jr nz,bnb
        ld a,0xFF
        ld (bu_need),a
        ld (bu_needm),a
        ld ix,obj_tab
        call bg_part
        ret z
        call bg_bands
bnr_l:  ld a,(hl)                   ; the BOBs' sum on one of RoboCop's bands
        or a
        jr z,bnr_n
        ld e,a
        ld a,LINE_LIMIT
        sub e
        jr nc,bnr_a
        xor a
bnr_a:  ld e,a
        ld a,(bu_need)
        cp e
        jr c,bnr_b
        ld a,e
        ld (bu_need),a
bnr_b:  ld a,l
        add a,bu_bmax - bu_band
        ld l,a
        ld e,(hl)                   ; the largest BOB there
        sub bu_bmax - bu_band
        ld l,a
        ld a,LINE_LIMIT
        sub e
        jr nc,bnr_c
        xor a
bnr_c:  ld e,a
        ld a,(bu_needm)
        cp e
        jr c,bnr_n
        ld a,e
        ld (bu_needm),a
bnr_n:  inc l
        dec c
        jr nz,bnr_l
        ret

; IX = RoboCop, who meets others: the fewest of his rank entries, in order, whose OR layers
; must go for him to fit on the lines he shares (bg_need; when even his one-layer version does
; not, the BOBs alternate and he fits beside one of them a frame). With objects left out
; (bg_cut), all of them: a steady layout matters more then.
bg_robo:
        ld a,(bu_need)
        cp (ix+O_MONE)
        jr nc,br_fits
        ld a,1
        ld (bu_over),a              ; they alternate
        ld a,(bu_needm)
br_fits:
        ld c,a                      ; the most he may put on a line
        ld a,(bu_cut)
        or a
        jr z,br_c
        ld c,0
br_c:
        ld a,(ix+O_BANK)
        add a,SPR_BASE_BANK
        call bank_8000
        ld l,(ix+O_MAXK)
        ld h,(ix+O_MAXK+1)
        ld b,0                      ; entries to drop
        ld a,(ix+O_NCOLS)
        ld e,a
brk_lp: ld a,(hl)                   ; most per line with the first B dropped
        cp c
        jr c,brk_k
        jr z,brk_k
        inc hl
        inc b
        ld a,b
        cp e
        jr c,brk_lp
brk_k:  inc b
        dec b
        ret z                       ; none
        ld l,(ix+O_RANK)
        ld h,(ix+O_RANK+1)
brk_d:  push bc
        ld a,(hl)                   ; column bit
        ld (tmp_k),a
        inc hl
        inc hl
        ld a,(hl)                   ; B sprites
        ld (tmp_n),a
        inc hl
        ld e,a
        ld d,0
        add hl,de
        or a
        jr z,brk_n
        ld a,(tmp_k)
        and (ix+O_DROP)
        jr nz,brk_n                 ; dropped already
        push hl
        call bt_mark
        pop hl
brk_n:  pop bc
        djnz brk_d
        ret

; IX = object: the column tmp_k drops its OR layer (tmp_n B sprites fewer). Keeps C, DE.
bt_mark:
        ld a,(tmp_k)
        or (ix+O_DROP)
        ld (ix+O_DROP),a
        ld a,(tmp_n)
        ld b,a
        add a,(ix+O_GONE)
        ld (ix+O_GONE),a
        ld a,(bu_tot)
        sub b
        ld (bu_tot),a
        ret

; ----- layouts -----

; A = set -> HL = its first layout entry. Keeps BC, DE.
lay_base:
        add a,lay/256               ; one page per set (MAX_OBJ * LAY_SIZE = 256)
        ld h,a
        ld l,0
        ret

; A = object, HL = first layout entry of a set -> HL = the object's entry. Keeps BC, DE.
lay_obj:
        add a,a
        add a,a
        add a,a
        add a,a                     ; *16
        add a,l
        ld l,a
        ret

; What the objects want shown against the layout on screen and the one being uploaded: a new
; layout for the set that is not on screen when neither is right.
lay_check:
        ld a,(up_state)
        or a
        jr z,lk_idle
        cp 2
        ret nc                      ; an upload past its pages finishes first, even when what the
                                    ; objects want changed meanwhile: its layout goes on screen
                                    ; (RoboCop where his own hotspot puts it) and the next one
                                    ; starts then (restarting it at every new frame of animation
                                    ; left some frames never shown when uploads take longer)
        ld a,(spr_shown)
        xor 1
        call lay_same
        ret z                       ; the upload under way is still the right one
lk_idle:
        ld a,(spr_shown)
        call lay_same
        jr nz,lk_build
        xor a
        ld (up_state),a             ; the set on screen is right
        ret
lk_build:
        call lay_build
lk_built:
        ld a,COST_LAYB
        call spr_charge
        ld a,1
        ld (up_state),a
        xor a
        ld (up_idx),a
        ld (up_rec),a
        ld (up_ent),a
        ret

; A = units of work done this frame by the sprite engine or the game logic (for the upload's
; share; saturates at 255).
spr_charge:
        push hl
        ld hl,spr_cost
        add a,(hl)
        jr nc,sc_s
        ld a,255
sc_s:   ld (hl),a
        pop hl
        ret

; A = set: Z if its layout holds every object as it wants to be shown.
lay_same:
        call lay_base
        ld ix,obj_tab
        ld c,MAX_OBJ
ls_lp:  call obj_want
        cp (hl)
        ret nz
        or a
        jr z,ls_nx
        call lb_same
        ret nz
ls_nx:  ld de,LAY_SIZE
        add hl,de
        ld de,OBJ_SIZE
        add ix,de
        dec c
        jr nz,ls_lp
        ret                         ; (Z)

; IX = object -> A = 80h when it is to be shown (and not left out this tick), else 0.
obj_want:
        ld a,(ix+O_OUT)
        or a
        ld a,0
        ret nz
        ld a,(ix+O_FLAGS)
        and 0x80
        ret

; Layout of the set that is not on screen for what the objects want: their entries in object
; order (an object that would pass 32 entries is left out) and each object's entry page. A page
; stays when the layout on screen, or the one being uploaded, shows the object the same way;
; the others are marked (IY+14 = FFh) and filled from the compositions by the upload (up_fills),
; once the slots of those that stay are known. Slots: busy[] = 1 used on screen, 2 taken for a
; new pattern, 3 kept with the pattern it holds.
lay_build:
        ld hl,busy
        ld bc,SPR_SLOTS
        xor a
        call fill
        ld a,(spr_shown)
        call lay_base
        ld (lb_sp),hl
        ld c,1
        call lay_mark               ; the slots of the layout on screen
        xor a
        ld (lb_n),a
        ld (lb_i),a
        ld ix,obj_tab
        ld a,(spr_shown)
        xor 1
        call lay_base
        push hl
        pop iy                      ; IY = the object's entry in the new layout
lb_obj: call obj_want
        or a
        jr z,lb_absent
        ld hl,(lb_sp)               ; its entry on screen
        ld a,(hl)
        or a
        jr z,lb_chg
        call lb_same
        jr nz,lb_chg
        push iy                     ; shown the same way there: that entry, at the next SAT entries
        pop de
        ld bc,LAY_SIZE
        ldir
        ld (iy+14),0
        ld a,(iy+7)
        call lb_fit
        jr nc,lb_next
        jr lb_absent
lb_chg: call lb_keep                ; A = page kept, FFh: to fill (up_fills)
        ld (iy+14),a
        ld a,(ix+O_NSPR)
        sub (ix+O_GONE)
        call lb_fit
        jr c,lb_absent              ; would not fit
        push ix                     ; bank, comp, drop, early clock
        pop hl
        inc hl
        push iy
        pop de
        inc de
        ld bc,5
        ldir
        ld de,O_KIND - (O_EC + 1)
        add hl,de
        push iy
        pop de
        ld a,e
        add a,8
        ld e,a
        ld bc,3
        ldir                        ; kind, id
        ld a,(ix+O_MINDX)
        ld (iy+12),a
        ld a,(ix+O_MAXDX)
        ld (iy+13),a
        ld a,(ix+O_NLINES)
        ld (iy+15),a
        jr lb_next
lb_absent:
        ld (iy+0),0
lb_next:
        ld hl,(lb_sp)
        ld de,LAY_SIZE
        add hl,de
        ld (lb_sp),hl
        add iy,de
        ld de,OBJ_SIZE
        add ix,de
        ld hl,lb_i
        inc (hl)
        ld a,(hl)
        cp MAX_OBJ
        jp c,lb_obj
        ld a,(spr_shown)
        xor 1
        ld e,a
        ld d,0
        ld hl,lay_n
        add hl,de
        ld a,(lb_n)
        ld (hl),a
        ret

; HL = a layout's first entry, C = busy code: the slots of its objects' entries get it.
lay_mark:
        ld a,c
        ld (tmp_k),a
        push hl
        pop iy
        ld e,0                      ; object
lm_lp:  ld a,(iy+0)
        or a
        jr z,lm_n
        ld d,(iy+7)
        ld a,e
        add a,a
        add a,(iy+11)
        add a,ENT_PAGE
        ld h,a
        ld l,3                      ; slot of its first entry
        ld b,busy/256
        ld a,(tmp_k)
lm_e:   ld c,(hl)
        ld (bc),a
        ld c,a
        ld a,l
        add a,ENT_SIZE
        ld l,a
        ld a,c
        dec d
        jr nz,lm_e
lm_n:   ld bc,LAY_SIZE
        add iy,bc
        inc e
        ld a,e
        cp MAX_OBJ
        jr c,lm_lp
        ret

; A = entries of the object's new layout entry IY: C when they would pass 32 entries; else
; they follow the entries so far (IY+6, IY+7, lb_n), IY+0 = 80h.
lb_fit: ld c,a
        ld a,(lb_n)
        ld b,a
        add a,c
        cp SAT_MAX + 1
        ccf
        ret c
        ld (lb_n),a
        ld (iy+6),b
        ld (iy+7),c
        ld (iy+0),0x80
        ret

; IX = object that the layout on screen does not show as it wants, IY = its entry in the new
; layout (still the old one there), HL = its entry on screen -> A = the page of the upload under
; way when that shows it so already (filled; its slots marked), else FFh with IY+11 = the page
; to fill (the one the layout on screen does not use).
lb_keep:
        ld b,0                      ; (not on screen: page 0)
        ld a,(hl)
        or a
        jr z,lk_up
        ld de,11
        add hl,de
        ld a,(hl)
        xor 1
        ld b,a                      ; the other page
lk_up:  ld a,(up_state)
        or a
        jr z,lk_fill
        ld a,(iy+0)
        or a
        jr z,lk_fill
        ld a,(iy+14)
        inc a
        jr z,lk_fill                ; its page is not filled
        push iy
        pop hl
        call lb_same
        jr nz,lk_fill
        call lb_markpage            ; that page stays, with its slots
        ld a,(iy+11)
        ret
lk_fill:
        ld (iy+11),b
        ld a,0xFF
        ret

; HL = a layout entry, IX = object: Z when the entry shows the object as it wants (composition,
; dropped columns, early clock). Keeps BC, DE, HL.
lb_same:
        push hl
        inc hl
        ld a,(ix+O_BANK)
        cp (hl)
        jr nz,lsm_x
        inc hl
        ld a,(ix+O_COMP)
        cp (hl)
        jr nz,lsm_x
        inc hl
        ld a,(ix+O_COMP+1)
        cp (hl)
        jr nz,lsm_x
        inc hl
        ld a,(ix+O_DROP)
        cp (hl)
        jr nz,lsm_x
        inc hl
        ld a,(ix+O_EC)
        cp (hl)
lsm_x:  pop hl
        ret

; IY = a layout entry of object lb_i (page IY+11): its slots busy (2).
lb_markpage:
        ld b,(iy+7)
        ld a,(lb_i)
        add a,a
        add a,(iy+11)
        add a,ENT_PAGE
        ld h,a
        ld l,3
        ld d,busy/256
        ld a,2
lmp_lp: ld e,(hl)
        ld (de),a
        ld e,a
        ld a,l
        add a,ENT_SIZE
        ld l,a
        ld a,e
        djnz lmp_lp
        ret

; IY = new layout entry of object lb_i: its page (IY+11) filled from the composition it holds
; (with its dropped columns and early clock), a slot for every entry (slot_for); from record
; up_rec and entry up_ent on, UP_FILL units a record. C when the units or the frame ran out
; (up_rec, up_ent = where to go on), NC when the page is complete.
lb_fill:
        ld a,(iy+5)
        ld (lb_ec),a
        ld a,(iy+1)
        add a,SPR_BASE_BANK
        call bank_8000
        ld l,(iy+2)
        ld h,(iy+3)
        ld a,(up_rec)
        ld c,a
        ld a,(hl)
        sub c
        ld b,a                      ; records left
        ld a,c
        add a,a
        add a,c
        add a,a
        add a,a                     ; 12 * up_rec
        push bc
        ld c,a
        ld b,0
        add hl,bc
        ld c,COMP_HDR
        add hl,bc                   ; HL = its next record
        pop bc
        ld a,(iy+11)
        ex de,hl
        ld hl,lb_i
        add a,(hl)
        add a,(hl)
        add a,ENT_PAGE
        ex de,hl
        ld d,a
        ld a,(up_ent)
        add a,a
        add a,a
        add a,a
        ld e,a                      ; DE = its next entry
        ld c,(iy+4)                 ; its dropped columns
        inc b
        dec b
        ret z                       ; (NC)
lf_lp:  call up_late
        jr c,lf_stop
        ld a,(up_units)
        sub UP_FILL
        jr c,lf_stop
        ld (up_units),a
        push hl
        ld a,(hl)
        ld (de),a                   ; dy (the entry counts only if the sprite is kept)
        inc hl
        inc e
        ld a,(hl)
        ld (de),a                   ; dx
        inc hl
        ld a,(hl)                   ; park bit
        and c
        jr nz,lf_skip               ; B sprite of a dropped column: no entry
        inc hl
        ld a,(hl)                   ; A1 bit
        inc hl
        and c
        jr z,lf_ids
        ld a,l                      ; A sprite of a dropped column: its A1 ids
        add a,4
        ld l,a
        jr nc,lf_ids
        inc h
lf_ids: call slot_for
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
        ld a,(hl)
        ld (de),a
        inc hl
        inc e
        ld a,(lb_ec)
        or (hl)
        ld (de),a                   ; colour id | 8000h (early clock)
        inc e
        inc e                       ; (the next entry: dec e below)
lf_skip:
        dec e
        pop hl
        ld a,l
        add a,REC_SIZE
        ld l,a
        jr nc,lf_n
        inc h
lf_n:   djnz lf_lp
        or a                        ; complete (NC)
        ret
lf_stop:
        ld a,e
        rrca
        rrca
        rrca
        and 0x1F
        ld (up_ent),a
        ld l,(iy+2)
        ld h,(iy+3)
        ld a,(hl)
        sub b
        ld (up_rec),a
        scf
        ret

; HL = pattern id in a record -> A = a slot for it, now busy: the slot it was last put in when
; that one still holds it and no other pattern claimed it in this layout (on screen or free),
; else a free one. Keeps BC, DE, HL.
slot_for:
        push bc
        push de
        push hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld hl,pat_slot
        add hl,bc
        ld e,(hl)                   ; where it was put last (FFh: never)
        ld a,e
        cp SPR_SLOTS
        jr nc,sl_new
        ld d,busy/256
        ld a,(de)
        cp 2
        jr z,sl_new                 ; claimed for another pattern
        ld a,e
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held/256
        ld a,(hl)
        cp c
        jr nz,sl_new
        inc l
        ld a,(hl)
        cp b
        jr nz,sl_new
        ld a,(de)                   ; it holds it: shared
        or a
        jr nz,sl_got
        ld a,3
        ld (de),a
sl_got: ld a,e
        pop hl
        pop de
        pop bc
        ret
sl_new: call alloc_slot
        pop hl
        pop de
        pop bc
        ret

; -> A = a free pattern slot, now taken (busy 2). Keeps BC, DE, HL.
alloc_slot:
        push hl
        push bc
        ld a,(alloc_p)
        ld l,a
        ld h,busy/256
        ld b,SPR_SLOTS
al_lp:  ld a,l
        and SPR_SLOTS - 1
        ld l,a
        ld a,(hl)
        or a
        jr z,al_got
        inc l
        djnz al_lp
        ld l,0                      ; (cannot happen: at most 32 + 32 slots in use)
al_got: ld (hl),2
        ld a,l
        inc a
        ld (alloc_p),a
        ld a,l
        pop bc
        pop hl
        ret

; ----- upload -----

; Once per frame: the SAT x correction of the camera, the set uploaded on screen (on the game's
; frame), the SAT when something moved or the set changed, the frame's phase when objects
; alternate, then an upload slice; R#5 for the list.
sprites_frame:
        ld a,(hud_msk)              ; non-zero: V9958 engine (R#26/R#27 do not move sprites)
        or a
        ld a,0
        jr nz,sf_xadj
        ld a,(cam_x)
        and 15
        sub 8                       ; V9938: R#18 moves sprites by 8 - f
sf_xadj:
        ld (spr_xadj),a
        ld a,(up_state)
        cp 4
        jr nz,sf_sat
        ld a,(g_tick)               ; (on the game's frame: the SAT is built then anyway)
        or a
        jr z,sf_sat
        xor a                       ; the upload completed: that set goes on screen
        ld (up_state),a
        ld a,(spr_shown)
        xor 1
        ld (spr_shown),a
        ld a,1
        ld (sat_dirty),a
sf_sat: ld a,(sat_dirty)
        or a
        jr z,sf_mux
        xor a
        ld (sat_dirty),a
        call sat_build
        call feed_vdp
        jr sf_ph
sf_mux: ld a,(mux_on)
        or a
        jr z,sf_up
sf_ph:  ld a,(mux_on)
        or a
        call nz,sat_phase
        ld a,1
        ld (spr_vblank),a
sf_up:  call up_step
        ld a,(spr_shown)
        or a
        ld a,R5_SET_A
        jr z,sf_r5
        ld a,R5_SET_B
sf_r5:  ld (spr_set),a
        ret

; The upload of the new layout into the set that is not on screen, up to this frame's units
; (what the HUD did this frame comes off them) and never once the beam is past the HUD split
; (the rest of the frame stays free); once complete, that set goes on screen the next frame.
up_step:
        ld a,(up_state)
        or a
        ret z
        cp 4
        ret z
        ld hl,UP_TOTAL              ; what the frame's work so far left
        ld a,(hud_cost)
        ld e,a
        ld d,0
        or a
        sbc hl,de
        ld a,(spr_cost)
        ld e,a
        sbc hl,de
        ld a,0
        jr c,us_u                   ; (nothing)
        ld a,h
        or a
        ld a,255
        jr nz,us_u
        ld a,l
us_u:   ld (up_units),a
        ld a,0xFF
        ld (up_next),a
        ld a,(up_state)
        cp 2
        jr z,us_pat
        cp 3
        jr z,us_col
        call up_fills
        ret c
        xor a
        ld (up_idx),a
us_pat: ld a,2
        ld (up_state),a
        call up_pats
        ret c
        ld a,3
        ld (up_state),a
        xor a
        ld (up_idx),a
        ld a,0xFF
        ld (up_next),a
us_col: call up_cols
        ret c
        ld a,4                      ; complete: that set goes on screen next frame
        ld (up_state),a
        ret

; The pages the new layout still needs filled (lay_build), record by record while the frame
; allows (lb_fill). C on return when this frame is over for them (up_idx, up_rec, up_ent = where
; to go on).
up_fills:
        ld a,(spr_shown)
        xor 1
        call lay_base
        ld a,(up_idx)
        call lay_obj
        push hl
        pop iy
ufl_lp: ld a,(up_idx)
        cp MAX_OBJ
        jp nc,up_end
        ld a,(iy+0)
        or a
        jr z,ufl_n
        ld a,(iy+14)
        inc a
        jr nz,ufl_n                 ; its page is there
        ld a,(up_idx)
        ld (lb_i),a
        call lb_fill
        ret c                       ; (on next frame)
        ld (iy+14),0
        xor a
        ld (up_rec),a
        ld (up_ent),a
ufl_n:  ld de,LAY_SIZE
        add iy,de
        ld hl,up_idx
        inc (hl)
        jr ufl_lp

up_end: xor a                       ; pass complete (NC)
        ret

; C when the upload must stop for this frame: the beam is past the HUD split, or a VBLANK came
; already (the frame is late).
up_late:
        ld a,(split_armed)
        sub 1
        ret c
        ld a,(tick)
        push hl
        ld hl,last_tick
        cp (hl)
        pop hl
        ret z
        scf
        ret

; -> HL = page entry of SAT entry up_idx of the new layout, B = entries of its object from there
; on (NZ); Z: past the last entry.
up_find:
        ld a,(spr_shown)
        xor 1
        call lay_base
        push hl
        pop iy
        ld c,0
uf_lp:  ld a,(iy+0)
        or a
        jr z,uf_n
        ld a,(up_idx)
        sub (iy+6)
        jr c,uf_n
        cp (iy+7)
        jr c,uf_got
uf_n:   ld de,LAY_SIZE
        add iy,de
        inc c
        ld a,c
        cp MAX_OBJ
        jr c,uf_lp
        xor a
        ret
uf_got: ld b,a
        add a,a
        add a,a
        add a,a                     ; * ENT_SIZE
        ld l,a
        ld a,c
        add a,a
        add a,(iy+11)
        add a,ENT_PAGE
        ld h,a
        ld a,(iy+7)
        sub b
        ld b,a                      ; (NZ)
        ret

; Patterns pass: every entry whose slot does not hold the pattern it wants. C on return when
; this frame's units ran out (up_idx = where to go on).
up_pats:
        call up_find
        jr z,up_end
upp_lp: call up_late
        ret c
        ld a,(up_units)
        sub UP_LOOK
        ret c
        ld (up_units),a
        push hl
        inc l
        inc l
        inc l
        ld a,(hl)                   ; its slot
        ld (tmp_k),a
        inc l
        ld e,(hl)
        inc l
        ld d,(hl)                   ; the pattern it wants
        add a,a
        add a,pat_held & 0xFF
        ld l,a
        ld h,pat_held/256
        ld a,(hl)
        cp e
        jr nz,upp_put
        inc l
        ld a,(hl)
        cp d
        jr z,upp_next
        dec l
upp_put:
        ld a,(up_units)
        sub UP_PAT
        jr c,up_out
        ld (up_units),a
        ld (hl),e
        inc l
        ld (hl),d
        ld hl,pat_slot
        add hl,de
        ld a,(tmp_k)
        ld (hl),a                   ; where that pattern is now
        push bc
        call pat_put
        pop bc
upp_next:
        pop hl
        ld a,l
        add a,ENT_SIZE
        ld l,a
        ld a,(up_idx)
        inc a
        ld (up_idx),a
        djnz upp_lp
        jr up_pats
up_out: pop hl                      ; units out (C)
        scf
        ret

; Colour rows pass: every entry of the new set whose row is not the one it wants.
up_cols:
        call up_find
        jp z,up_end
upc_lp: call up_late
        ret c
        ld a,(up_units)
        sub UP_LOOK
        ret c
        ld (up_units),a
        push hl
        ld a,l
        add a,6
        ld l,a
        ld e,(hl)
        inc l
        ld d,(hl)                   ; the row it wants (| 8000h: early clock)
        ld a,(spr_shown)
        xor 1
        rrca
        rrca                        ; set * 64
        ld l,a
        ld a,(up_idx)
        add a,a
        add a,l
        add a,lay_col & 0xFF
        ld l,a
        ld h,lay_col/256
        ld a,(hl)
        cp e
        jr nz,upc_put
        inc l
        ld a,(hl)
        cp d
        jr z,upc_next
        dec l
upc_put:
        ld a,(up_units)
        sub UP_COL
        jr c,up_out
        ld (up_units),a
        ld (hl),e
        inc l
        ld (hl),d
        push bc
        ld b,d
        ld c,e
        call col_put
        pop bc
upc_next:
        pop hl
        ld a,l
        add a,ENT_SIZE
        ld l,a
        ld a,(up_idx)
        inc a
        ld (up_idx),a
        djnz upc_lp
        jr up_cols

; tmp_k = slot, DE = pattern id: the pattern into that slot of the pattern table (the VRAM
; pointer is kept when the previous write ended at this slot).
pat_put:
        ld a,(up_next)
        ld hl,tmp_k
        cp (hl)
        jr z,pp_data
        push de
        ld l,(hl)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; slot * 32
        ld de,SPR_PAT & 0xFFFF
        add hl,de
        ld e,1
        call vram_write
        pop de
pp_data:
        ld a,(tmp_k)
        inc a
        ld (up_next),a
        ld a,d
        add a,SPR_BASE_BANK + SPR_PAT_BANK
        call bank_a000
        ld l,e
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,0xA000
        add hl,de
        ld bc,32*256 + VDP_DATA
        otir
        ret

; BC = colour id | 8000h (early clock) -> row up_idx of the new set's colour table.
col_put:
        ld a,(up_next)
        ld hl,up_idx
        cp (hl)
        jr z,cp_data
        push bc
        ld l,(hl)
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; entry * 16
        ld a,(spr_shown)
        or a
        ld de,SPR_COL_B & 0xFFFF
        jr z,cp_addr
        ld de,SPR_COL_A & 0xFFFF
cp_addr:
        add hl,de
        ld e,1
        call vram_write
        pop bc
cp_data:
        ld a,(up_idx)
        inc a
        ld (up_next),a
        ld a,b
        and 0x7E
        rrca                        ; id / 512
        add a,SPR_BASE_BANK + SPR_COL_BANK
        call bank_a000
        ld a,b
        and 1
        ld h,a
        ld l,c
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl                   ; (id & 511) * 16
        ld de,0xA000
        add hl,de
        bit 7,b
        jr nz,cp_ec
        ld bc,16*256 + VDP_DATA
        otir
        ret
cp_ec:  ld b,16
cp_lp:  ld a,(hl)
        or 0x80
        out (VDP_DATA),a
        inc hl
        djnz cp_lp
        ret

; ----- SAT -----

; The SAT for the layout on screen: each present object at its current position, its entries in
; order (from its page), parked where x falls outside 0..255; 216 after the last entry; into
; sat_buf, or into sat_full when objects alternate (sat_phase then makes sat_buf for each
; frame). pub_cur records what it shows.
sat_build:
        ld a,(cam_y)
        add a,PARK_LINE - 1
        cp 216
        jr nz,sb_pk
        dec a
sb_pk:  ld (sb_parky),a
        ld hl,pub_cur
        ld (sb_pub),hl
        xor a
        ld (sb_idx),a
        ld (sb_obj),a
        ld ix,obj_tab
        ld a,(spr_shown)
        call lay_base
        push hl
        pop iy                      ; IY = the object's layout entry
        ld a,0x80
        ld (sb_vis),a
        ld de,sat_buf
        ld a,(mux_on)
        or a
        jr z,sb_olp
        ld de,sat_full
sb_olp: ld a,(iy+0)
        or a
        jr nz,sb_pres
        ld hl,(sb_pub)
        ld (hl),0                   ; not shown
        jr sb_onext
sb_pres:
        call sb_object
        ld a,(sb_idx)
        add a,(iy+7)
        ld (sb_idx),a
sb_onext:
        ld hl,(sb_pub)
        ld bc,8
        add hl,bc
        ld (sb_pub),hl
        ld bc,OBJ_SIZE
        add ix,bc
        ld bc,LAY_SIZE
        add iy,bc
        ld hl,sb_obj
        inc (hl)
        ld a,(hl)
        cp MAX_OBJ
        jr c,sb_olp
        ld a,(sb_idx)
        ld (spr_n),a
        add a,a                     ; (COST_SATE)
        add a,4*COST_SATO
        call spr_charge
        ld a,(spr_n)
        cp SAT_MAX
        ret nc
        ld a,216
        ld (de),a
        ret

; IX = object, IY = its layout entry, DE = its first sat_buf entry: writes its entries (DE
; after them) and its pub_cur record. RoboCop's position is the composition's top-left for the
; composition the game asked for, but the layout on screen may still show an older one (its
; upload takes frames): that one goes where its own hotspot puts it (sb_rchot), so a new frame of
; animation or a turn does not shift the old one by the hotspots' difference.
sb_object:
        ld l,(ix+O_X)
        ld h,(ix+O_X+1)
        ld (sb_ox),hl
        ld l,(ix+O_Y)
        ld h,(ix+O_Y+1)
        ld (sb_oy),hl
        ld a,(iy+8)                 ; kind: 0 RoboCop
        or a
        call z,sb_rchot
        ld hl,(sb_pub)
        ld a,(sb_vis)
        or (iy+8)
        ld (hl),a                   ; flags: bit 7 shown, bit 0 BOB
        inc hl
        ld a,(iy+9)                 ; what the layout holds (an upload may be under way)
        ld (hl),a
        inc hl
        ld a,(iy+10)
        ld (hl),a
        inc hl
        ld a,(iy+4)
        ld (hl),a                   ; dropped columns
        inc hl
        ld a,(sb_ox)
        ld (hl),a
        inc hl
        ld a,(sb_ox+1)
        ld (hl),a                   ; (y after the 216 check)
        ld (sb_de0),de
        ld a,(sb_obj)
        add a,a
        add a,(iy+11)
        add a,ENT_PAGE
        ld (sb_page),a
        ld hl,(sb_oy)               ; wholly above or below the play area: parked (its SAT y
                                    ; would wrap around into it)
        bit 7,h
        jr z,sbo_yb
        ld e,(iy+15)
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
        ld a,(iy+5)
        or a
        jr z,sbo_xb
        ld de,32                    ; early clock: the VDP shows it 32 px further left
        add hl,de
sbo_xb: ld (sb_xbase),hl
        ld a,(iy+12)                ; min dx
        call xpos
        ld a,h
        push af
        ld a,(iy+13)                ; max dx
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
        ld b,(iy+7)
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
        ld hl,(sb_de0)              ; DE after its entries
        ld a,(iy+7)
        add a,a
        add a,a
        add a,l
        ld l,a
        ex de,hl
        ret

; RoboCop (IY = his layout entry): sb_ox / sb_oy moved by the hotspot of the record the layout
; shows minus the one the game asked for (p_hotx, p_hoty: pl_frame). Keeps DE (sb_object's
; sat_buf pointer).
sb_rchot:
        push de
        ld l,(iy+9)
        ld h,(iy+10)                ; the id shown: record * 4 + aim, or an arm pose
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

; IX = object, IY = its layout entry, (sb_de0) = its first SAT entry: an object wholly off the
; play area has its entries parked (DE after them); its pub_cur record keeps its y.
sb_parkall:
        ld hl,(sb_pub)
        ld de,6
        add hl,de
        ld a,(ix+O_Y)
        ld (hl),a
        inc hl
        ld a,(ix+O_Y+1)
        ld (hl),a
        ld de,(sb_de0)
        ld a,(sb_page)
        ld h,a
        ld l,2                      ; pattern number of its first entry
        ld b,(iy+7)
spk_lp: ld a,(sb_parky)
        ld (de),a
        inc e
        xor a
        ld (de),a
        inc e
        ld a,(hl)
        ld (de),a
        inc e
        inc e
        ld a,l
        add a,ENT_SIZE
        ld l,a
        djnz spk_lp
        ret

; Objects alternate: sat_buf = sat_full with the entries of those off this frame parked, and
; their pub_cur records not shown.
sat_phase:
        ld a,COST_PHASE
        call spr_charge
        ld a,(spr_n)
        add a,a
        add a,a
        inc a                       ; (and the 216)
        ld c,a
        ld b,0
        ld hl,sat_full
        ld de,sat_buf
        ldir
        ld ix,obj_tab
        ld a,(spr_shown)
        call lay_base
        push hl
        pop iy
        ld hl,pub_cur
        ld b,MAX_OBJ
sph_o:  ld a,(iy+0)
        or a
        jr z,sph_n
        bit 6,(ix+O_FLAGS)
        jr z,sph_n
        ld a,(frame)
        xor (ix+O_FLAGS)
        rrca                        ; carry: not its phase this frame
        ld a,(hl)
        res 7,a
        jr c,sph_off
        set 7,a
        ld (hl),a
        jr sph_n
sph_off:
        ld (hl),a
        push hl
        push bc
        ld a,(iy+6)
        add a,a
        add a,a
        ld l,a
        ld h,sat_buf/256
        ld b,(iy+7)
        ld a,(sb_parky)
sph_p:  ld (hl),a
        inc l
        inc l
        inc l
        inc l
        djnz sph_p
        pop bc
        pop hl
sph_n:  ld de,8
        add hl,de
        ld de,OBJ_SIZE
        add ix,de
        ld de,LAY_SIZE
        add iy,de
        djnz sph_o
        ret

; A = dx (signed) -> HL = sb_xbase + dx.
xpos:   ld e,a
        rla
        sbc a,a
        ld d,a
        ld hl,(sb_xbase)
        add hl,de
        ret

; ----- demo of the game's objects (DEMO_ACTORS > 0: until the enemies are ported) -----

COST_DEMO:  equ 60                  ; its work in upload units
DA_SIZE:    equ 16                  ; demo actor: kind (0 screen, 1 world), frame A, frame B,
                                    ; frame period (ticks = 2^n; FFh: frames A..A+7 in turn),
                                    ; x (2), y (2), direction, speed

; Screen actors bounce across the play area; world actors scroll with the map and come back
; ahead of the camera when they leave the screen.
spr_demo_init:
        if DEMO_ACTORS
        ld hl,demo_actors
        ld de,demo_tab
        ld bc,DEMO_ACTORS*DA_SIZE
        ldir
        endif
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
