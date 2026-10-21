; Cold code of the fixed area: routines that run once per level (or at power-on), kept in the
; front end's bank (BANK_FRONT at 8000h through front_call) to leave room in 4000h-7FFFh. They
; call only fixed code and never map the 8000h window themselves.

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
        di                          ; (the interrupt loads the background queue)
        ld a,(bq_tail)
        ld (bq_head),a              ; nothing in it
        ld hl,SLOT_PG*256 + SO_OK
        ld bc,2*SPR_SLOTS
        xor a
        call fill                   ; nothing loaded, nothing queued (slot_ok, slot_q)
        ei
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
        ld (mux_on),a
        ld (pk_mux),a
        ld (alloc_p),a
        ld a,(RG9SAV)
        and 2
        ld hl,UPW_60
        jr z,si_upw
        ld hl,UPW_50
si_upw: ld (up_window),hl           ; (50 Hz: a longer vertical blank)
        ld a,R5_SET_A
        ld (spr_set),a
        ld (spr_dsp),a
        ret
