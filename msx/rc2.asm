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

init:   di
        ld sp,0xF380
        ld a,(MSXVER)
        or a
        jp z,no_msx2                ; (an MSX1)
        ld a,(MODE)
        and 6
        cp 4
        jp c,no_msx2                ; (less than 128 KiB of VRAM: the tiles, the HUD and the
        ld hl,2 + 3 * 256           ;  sprite tables need pages 2-3)           ; the mapper's banks at power-on in the 8000h and A000h windows
        ld (act_8000),hl            ; (act_8000, act_a000: the interrupts put act_a000 back)
        call slot_page2             ; cartridge also in page 2 (8000h-BFFFh)
        call snd_detect             ; an OPLL (with the BIOS: before page 0 becomes RAM)
        di
        call vdp_setup              ; SCREEN 5, VDP ID, IM 2, palette, tiles, HUD, sprite tables
        call ram_page0              ; page 0: RAM from now on (no more BIOS calls)
        jp c,no_ram
        call snd_init               ; the PSG (and the OPLL) silent
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
ng_go:  call tiles_init             ; the tile cache and the map patches
        call atr_load               ; the map attributes into page-0 RAM
        ld hl,AG + 0x8000           ; the game's globals ($8000-$80FF): level 0, score 0
        ld bc,256
        xor a
        call fill
        ld a,2
        ld (AG + 0x8034),a          ; two lives ($FFD8; hud_init draws their heads)
        call pl_init                ; the start of the level: RoboCop, the camera, the cadence
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
        call engines_init
        if DEMO_ACTORS
        call spr_demo_init
        endif
        call hud_init
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
ml_spr: call sprites_frame          ; upload slice, SAT, R#5 for the list
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
        ld a,(g_event)
        or a
        jp z,mainloop
        cp FE_RESTART
        jr z,ml_rst
        cp FE_OVER
        jr nz,ml_ng                 ; the next level: (for now) the title and a new game
        ld hl,front_over            ; game over: PIC9
        call front_call
ml_ng:  call title
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

; The scroll engine of the VDP found (vdp_id; FORCE_V9938) on the camera's view, the split, the
; sprite engine.
engines_init:
        ld a,(vdp_id)
        cp 2
        jr nz,init38
        if FORCE_V9938
        jr init38
        endif
        call split_init             ; A = 2: V9958 engine
        call scroll_init            ; V9958 engine
        ld hl,scroll_publish
        ld (pub_vec),hl
        ld hl,scroll_update
        ld de,scroll_work
        jr init_go
init38: xor a
        call split_init
        call s38_init               ; V9938 engine
        ld hl,s38_publish
        ld (pub_vec),hl
        ld hl,s38_update
        ld de,s38_work
init_go:
        ld (update_vec),hl
        ld (idle_vec),de
        jp sprites_init

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
        call pl_init
        call logic_map
        call obj_start              ; (lv_fresh clear: the header's values only)
        ld a,BANK_LC2
        call bank_8000
        call ao_start
        call logic_map
        xor a
        call set_weapon             ; ($8844)
        call engines_init
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
        jp tiles_upload             ; (the pictures' G7 overwrote the start of the tiles)
        endif

; HL = a routine of the front end (BANK_FRONT at 8000h around it).
front_call:
        ld a,BANK_FRONT
        call bank_8000
        jp (hl)

; No RAM in page 0 (the main RAM is not in page 3's slot): a red screen.
; An MSX1, or an MSX2 with less than 128 KiB of VRAM: the game cannot run there; a message in
; SCREEN 0 (the BIOS still serves page 0) and the machine stays on it.
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
        db "ROBOCOP 2 needs an MSX2 or MSX2+"
        db 13, 10
        db "with 128 KB of VRAM."
        db 0

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

do_update:
        ld hl,(update_vec)
        jp (hl)

do_publish:
        ld hl,(pub_vec)
        jp (hl)

idle_work:
        ld hl,(idle_vec)
        jp (hl)

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
        incbin "level1.pal"
        include "robocop_flash.inc" ; RoboCop's palette flashes (tools/msxsprites.py)
hud_palette:
        incbin "hud.pal"
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
l1_end:
        ds 0xC000 - l1_end, 0xFF

; ----- the game logic, module 3: the special objects (BANK_LC3 at 8000h around its calls) -----
        org 0x8000
        include "special.asm"
        include "frame.asm"
        include "at_c3.inc"
lc3_end:
        ds 0xA000 - lc3_end, 0xFF

; ----- the joystick script of test builds (BANK_INPUT at A000h around its reads) -----
        org 0xA000
        include "input.inc"         ; (tools/mkrom.py JOY=..., TELE=...)
input_end:
        ds 0xC000 - input_end, 0xFF

; ----- the front end: title, game over (BANK_FRONT at 8000h around its calls: front_call) -----
        org 0x8000
        include "front.asm"
        include "cold.asm"          ; init routines of the fixed code (cold.asm)
front_end:
        ds 0xA000 - front_end, 0xFF
