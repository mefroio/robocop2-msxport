; Robocop 2 MSX - scroll engine prototype with the HUD split (play area 163 lines, HUD 45).
; MegaROM with a Konami SCC style mapper (MegaRAM compatible): 8 KiB banks switched by
; writes inside the page itself (9000h -> 8000h window, B000h -> A000h window).
; Banks 0-1 = code (4000h-7FFFh, fixed); data in the 8000h and A000h windows.
; Build with tools/mkrom.py (z80asm 1.8).

        include "banks.inc"
        include "robocop.inc"
        include "hud_rt.inc"
        include "options.inc"       ; build options (tools/mkrom.py): FORCE_V9938, DEMO_ACTORS
        include "msx.inc"

        org 0x4000
        db "AB"
        dw init
        ds 12, 0
        db "ROM_KON5"               ; (4010h: the mapper's tag, Konami SCC: the MSX Pico+ firmware
                                    ;  starts the ROM with it as a sure detection)

init:   di
        ld sp,0xF380
        if DIAG
        in a,(PPI_SLOT)
        ld (dg_a8b),a               ; (test build: A8h as the BIOS left it; the SCC probed
        ld hl,dg_log                ;  after each step of the start: sound.asm dg_probe)
        ld (dg_ptr),hl
        endif
        ld hl,2 + 3 * 256           ; the mapper's banks at power-on in the 8000h and A000h windows
        ld (act_8000),hl            ; (act_8000, act_a000: the interrupts put act_a000 back)
        call slot_page2             ; cartridge also in page 2 (8000h-BFFFh)
        ld a,(MSXVER)
        if DIAG
        ld (dg_msxv),a
        endif
        or a
        jr z,nm_go                  ; (an MSX1)
        ld a,(MODE)
        and 6
        cp 4
        jr nc,nm_ok                 ; (less than 128 KiB of VRAM: the tiles, the HUD and the
nm_go:  ld hl,no_msx2               ;  sprite tables need pages 2-3: cold.asm, a message, and
        jp front_call               ;  the machine stays on it)
nm_ok:
        if DIAG
        di
        ld b,'1'
        call dg_probe
        endif
        ld hl,snd_detect
        call front_call             ; an OPLL (with the BIOS: before page 0 becomes RAM; cold.asm)
        di
        if DIAG
        ld b,'2'
        call dg_probe
        endif
        ld hl,vdp_setup
        call front_call             ; SCREEN 5, VDP ID, IM 2, palette, tiles, HUD, sprite tables
        if DIAG
        di
        ld b,'3'
        call dg_probe
        endif
        ld hl,ram_page0
        call front_call             ; page 0: RAM from now on (no more BIOS calls; cold.asm)
        jp c,no_ram                 ; (cold.asm: BANK_FRONT still at 8000h)
        if DIAG
        ld b,'4'
        call dg_probe
        endif
        call snd_init               ; the PSG (and the OPLL) silent (cold.asm: BANK_FRONT at 8000h)
        if DIAG
        di
        ld b,'5'
        call dg_probe
        endif
        ld hl,mus_init
        call mus_call               ; an SCC: the title music's chips (music.asm)
        if DIAG
        ld hl,dg_main
        call mus_call               ; (test build: what this machine showed, then test tones; no game)
        endif
        ld hl,sq_init
        call snd_bank               ; the player idle, its queue empty (the interrupts still off)
        ld hl,AC_VARS               ; the variables of the Amiga's code area at the power-on
        ld bc,AC_VARS_END - AC_VARS ; (they live on across levels and games: the code is never
        xor a                       ; loaded again: ac_mkstep $C44A...)
        call fill
        ld a,2                      ; (the code's values: $8C98, $F826, $F07E; pl_init sets
        ld (ac_ridest),a            ; $B02B's)
        ld hl,0xFFFF
        ld (ac_flash),hl
        ld a,l
        ld (ac_ediv),a
        ld hl,0
        ld (tick_n),hl              ; (the test scripts' game frames)
        xor a
        ld (front_mode),a
        call title
        jr ng_go

; A new game ($FFC4, $FFD8): level 1 from the disk's state again (the map without the last
; game's changes), score 0, two lives; the display and the VDP's interrupts off meanwhile.
new_game:
        ld a,R0_IE1_OFF
        ld b,0
        call wrreg
        ld a,0x02
        ld b,1
        call wrreg
ng_go:  ld hl,tiles_init
        call front_call             ; the tile cache and the map patches (cold.asm)
        call atr_load               ; the map attributes into page-0 RAM (cold.asm: BANK_FRONT at 8000h)
        ld hl,AG + 0x8000           ; the game's globals ($8000-$80FF): level 0, score 0
        ld bc,256
        xor a
        call fill
        ld a,2
        ld (AG + 0x8034),a          ; two lives ($FFD8; hud_init draws their heads)
        ld hl,pl_init
        call front_call             ; the start of the level: RoboCop, the camera, the cadence
        ld a,BANK_L1
        ld (lvl_bank),a
        ld a,0xFF
        ld (lv_fresh),a             ; (the level's lists into RAM)
        call logic_map
        call obj_start              ; the objects (level 1)
        ld a,BANK_LC2
        call bank_8000
        call ao_start               ; the map objects and their first pass over the whole map
        call logic_map
        ld hl,engines_init
        call field_call             ; (field.asm)
        if DEMO_ACTORS
        call spr_demo_init
        endif
        ld hl,hud_init
        call front_call             ; (cold.asm)
        call logic_map
        if DEMO_HUD
        call demo_init
        endif
        call display_on
mainloop:
        call wait_frame             ; feeds the VDP while waiting; returns right after the VBLANK
        call sprites_vblank         ; SAT of the list now on screen (still in the VBLANK)
        call key_scan               ; the keys the game reads as key codes (pause)
        call sec_tick               ; the timer's seconds (the Amiga's CIA-B interrupt)
        call hud_frame              ; HUD changes, long before the beam reaches the HUD
        call feed_vdp               ; (the scroll engine's next VDP command runs meanwhile)
        ld a,(g_tick)               ; did the game tick at the end of the last frame?
        or a
        jr z,ml_frame
        call do_update              ; scroll engine: state of the next frame, VDP work
        call cam_mark               ; (the view the objects are placed against)
        call pl_show                ; RoboCop's composition and place against the view shown
        call bob_flush              ; the BOBs of the tick as sprite objects
        if DEMO_ACTORS
        call demo_tick              ; the demo's objects
        endif
        call feed_vdp
        call sprites_moved          ; their positions go into the next SAT
        call sprites_tick           ; the budget for them, before their layout
        jr ml_spr
ml_frame:
        call do_update              ; (no tick: versions on their way may still go on screen)
        call cam_follow             ; (the view caught up without a tick: the objects follow it)
ml_spr: ld hl,fb_frame
        call field_call             ; the play-field BOBs (field.asm): what changed
        call sprites_frame          ; upload slice, SAT, R#5 for the list
        if DEMO_HUD
        call hud_demo               ; demo of the game's HUD events
        endif
        call do_publish             ; registers of the next frame for the VBLANK
        call cadence                ; g_tick: the game's ticks due (30 per second)
        ld a,(g_tick)               ; they run now, while the list waits for its VBLANK (the
        or a                        ; next frame shows their picture)
        jp z,mainloop
ml_tk:  ld a,(g_tn)
        dec a
        ld (bob_skip),a             ; (a tick before the frame's last one: its BOBs are not shown)
tick_start:
        call game_tick              ; the game's logic: RoboCop, the camera (the view)
        ld a,(g_event)
        or a
        jr nz,ml_tkd                ; (a death, the end: no more ticks this frame)
        ld hl,g_tn
        dec (hl)
        jr nz,ml_tk                 ; a late frame: the next tick at once
ml_tkd: ld hl,fl_pend
        ld b,5
ml_flc: ld (hl),0                   ; (held hit flashes: shown now or never)
        inc hl
        djnz ml_flc
        ld a,(jump_pend)            ; the cracked wall moved RoboCop and the camera (mapobj.asm
        or a                        ; act_10): the new view drawn at once
        jr z,ml_ev
        xor a
        ld (jump_pend),a
        ld hl,engines_jump
        call field_call
ml_ev:  ld a,(g_event)
        or a
        jp z,mainloop
        cp FE_RESTART
        jr z,ml_rst
        cp FE_OVER
        ld hl,front_over            ; game over: PIC9
        jr z,ml_fe
        ld hl,front_stats           ; the next level: its statistics ($85D8), then (for now) the
ml_fe:  call front_call             ; title and a new game
        call title
        jp new_game
ml_rst: call level_restart
        xor a
        ld (g_tick),a               ; (no picture of the ticks before the restart)
        jp mainloop

; The CIA-B interrupt ($1015E, an alarm of 15625 lines: once a second) unless paused: the timer's
; seconds - 1 (BCD), at the bottom its minutes - 1 and seconds 59; below 0:00 time out ($804C,
; the timer stays at 0:00). Test builds with a script keep it still (the bench raises no CIA-B
; interrupt).
sec_tick:
        if INPUT_SCRIPT
        ret
        else
        ld a,(g_paused)
        or a
        ret nz
        ld a,(RG9SAV)
        and 2
        ld c,60
        jr z,stk_hz
        ld c,50
stk_hz: ld a,(wf_n)                 ; (the VBLANKs since the last frame)
        ld hl,sec_n
        add a,(hl)
        cp c
        jr nc,stk_sec
        ld (hl),a
        ret
stk_sec:
        sub c
        ld (hl),a
        ld hl,AG + (0x804B ^ 1)     ; seconds
        ld a,(hl)
        sub 1
        daa
        jp p,stk_s
        ld hl,AG + (0x804A ^ 1)     ; minutes
        ld a,(hl)
        sub 1
        daa
        jp m,stk_out
        ld (hl),a
        ld hl,AG + (0x804B ^ 1)
        ld a,0x59
stk_s:  ld (hl),a
        ret
stk_out:
        ld a,0xFF
        ld (AG + (0x804C ^ 1)),a
        ret
        endif

display_on:
        ld a,R0_IE1_ON
        ld b,0
        call wrreg                  ; line interrupt on (R#19 comes with each frame)
        ld a,R1_ON
        ld b,1
        jp wrreg                    ; display and VBLANK interrupt on

; After a death with lives left (main_loop $82E4: level_init again, without reloading the
; level): the map keeps its changes and the lists their state (ao_start resets the object
; list's entries but type 58h's), RoboCop and the camera at the start, weapon 0; the display
; and the VDP's interrupts off meanwhile; the HUD as it is.
level_restart:
        ld a,R0_IE1_OFF
        ld b,0
        call wrreg
        ld a,0x02                   ; display off, no VBLANK interrupt
        ld b,1
        call wrreg
        ld hl,pl_init
        call front_call             ; (cold.asm)
        call logic_map
        call obj_start              ; (lv_fresh clear: the header's values only)
        ld a,BANK_LC2
        call bank_8000
        call ao_start
        call logic_map
        xor a
        call set_weapon             ; ($8844)
        ld hl,engines_init
        call field_call
        jp display_on

; The title (front end) before a new game; test builds with a script start the game at once.
title:
        if INPUT_SCRIPT
        ret
        else
        ld hl,front_title
        call front_call
        ld hl,front_done
        call front_call
        ld e,4
        jp tiles_upload             ; (cold.asm, BANK_FRONT still at 8000h: the pictures' G7
                                    ; overwrote the start of the tiles)
        endif

; HL = a routine of the play-field BOB module (BANK_FIELD at A000h around it; the bank that was
; there comes back). Keeps nothing but what the routine returns in BC, DE, HL.
field_call:
        ld a,(act_a000)
        push af
        ld a,BANK_FIELD
        call bank_a000
        call fc_hl
        pop af
        jp bank_a000
fc_hl:  jp (hl)

; HL = a routine of the front end (BANK_FRONT at 8000h around it).
front_call:
        ld a,BANK_FRONT
        call bank_8000
        jp (hl)

do_update:
        ld hl,(update_vec)
        jp (hl)

do_publish:
        ld hl,(pub_vec)
        call fc_hl
        ld hl,fb_tick               ; (field.asm: this picture's play-field copies may start now,
        inc (hl)                    ; the next one's items wait for it)
        ret

idle_work:
        ld a,(fb_busy)              ; the play-field BOBs (field.asm) first while they have work: a
        or a                        ; picture waits for them (isr.asm)
        jr z,iw_scr
        ld a,(fb_cq)                ; (their copy waiting, its picture published and uploaded:
        rra                         ; nothing else may take the VDP before the interrupts start it,
        jr nc,iw_fb                 ; or fb_wait in the blank)
        ld a,(fb_tick)
        ld hl,fb_cur + 11
        cp (hl)
        jr z,iw_scr
        ld a,(pk_state)
        dec a
        jr z,iw_scr
        ld a,(split_armed)
        or a
        ret nz
        call vdp_busy
        ret nz
        ld hl,fb_work
        jp field_call
iw_fb:  call vdp_busy
        ret nz
        ld hl,fb_work
        call field_call
iw_scr: ld hl,(idle_vec)
        jp (hl)                     ; the scroll engine's step (a command when the VDP is idle)

; Selects in page 2 the same slot (primary/secondary) as page 1.
slot_page2:
        call RSLREG
        rrca
        rrca
        and 3
        ld c,a
        ld b,0
        ld hl,EXPTBL
        add hl,bc
        ld a,(hl)
        and 0x80
        or c
        ld c,a                      ; C = E000 00PP
        ld hl,SLTTBL
        ld a,c
        and 3
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        and 0x0C                    ; secondary slot of page 1
        or c
        ld h,0x80
        jp ENASLT

        include "bank.asm"
        include "vdp.asm"
        include "isr.asm"
        include "tiles.asm"
        include "bob.asm"
        include "logic.asm"         ; the game logic's helpers
        include "at_fixed.inc"
        include "scroll9958.asm"
        include "scroll9938.asm"
        include "sprites.asm"
        include "hud.asm"
        include "player.asm"
        include "sound.asm"         ; the PSG and the OPLL (MSX-MUSIC / FM-PAC)
        include "player.inc"        ; RoboCop's logic tables (tools/player.py --inc)

palette:
        incbin "level1_grade.pal"   ; (the level's palette through the colour grade: tools/mkrom.py)
        include "robocop_flash.inc" ; RoboCop's palette flashes (tools/msxsprites.py)
hud_palette:
        incbin "hud_grade.pal"
        include "grade.inc"         ; the fade's limits through the colour grade (tools/mkrom.py)
rowtab:
        include "rowtab.inc"

code_end:
        ds 0x8000 - code_end, 0xFF  ; pads banks 0-1 (16 KiB)

; ----- the game logic, module 1: the enemies (BANK_LC1 at 8000h while the game ticks) -----
        org 0x8000
        include "objects.asm"
        include "shots.asm"         ; RoboCop's fire, shots and effects
        include "hits.asm"          ; RoboCop against bullets, enemies, pickups; the pickups
        include "at_c1.inc"         ; the original's tables (tools/amitab.py)
lc1_end:
        ds 0xA000 - lc1_end, 0xFF

; ----- the game logic, module 2: the map objects (BANK_LC2 at 8000h around its calls) -----
        org 0x8000
        include "mapobj.asm"
        include "at_c2.inc"
lc2_end:
        ds 0xA000 - lc2_end, 0xFF

; ----- the game logic of level 1 (BANK_L1 at A000h) -----
        org 0xA000
        include "level1.asm"
        include "at_l1.inc"
        include "cells_l1.inc"      ; the camera-cell masks of its spawn list and hazards (tools/cellmasks.py)
l1_end:
        ds 0xC000 - l1_end, 0xFF

; ----- the game logic, module 3: the special objects (BANK_LC3 at 8000h around its calls) -----
        org 0x8000
        include "special.asm"
        include "frame.asm"
        include "plmove.asm"        ; RoboCop's player_move (player.asm game_tick)
        include "at_c3.inc"
lc3_end:
        ds 0xA000 - lc3_end, 0xFF

; ----- the joystick script of test builds and the sound player (BANK_INPUT at A000h around
; their calls) -----
        org 0xA000
        include "input.inc"         ; (tools/mkrom.py JOY=..., TELE=...)
        include "sndplay.asm"
        include "sound.inc"         ; the streams (tools/msxsound.py)
input_end:
        ds 0xC000 - input_end, 0xFF

; ----- the front end: title, game over (BANK_FRONT at 8000h around its calls: front_call) -----
        org 0x8000
        include "front.asm"
        include "cold.asm"          ; init routines of the fixed code (cold.asm)
        include "text.inc"          ; the text screens' font and the statistics (tools/msxtext.py)
front_end:
        ds 0xA000 - front_end, 0xFF

; ----- the play-field BOBs and the scroll engines' set-up (BANK_FIELD at A000h around its calls:
; field_call) -----
        org 0xA000
        include "field.asm"
field_end:
        ds 0xC000 - field_end, 0xFF

; ----- the title music on the SCC / OPLL and RoboCop's speech (BANK_MUSIC at A000h around their
; calls: mus_call, snd_frame) -----
        org 0xA000
        include "music.asm"
        if DIAG
        include "diag.asm"          ; (test builds: what this machine showed the sound detection)
        endif
        include "music.inc"         ; the streams' banks, the SCC's waveforms, the OPLL's patch (tools/mkrom.py)
music_tab:
        ds (0x100 - (music_tab & 0xFF)) & 0xFF, 0xFF  ; (voice_tab: 256-byte aligned)
        include "voice.inc"         ; RoboCop's speech: its PSG tables (tools/msxvoice.py)
music_end:
        ds 0xC000 - music_end, 0xFF
