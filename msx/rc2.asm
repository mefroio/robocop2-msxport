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
        call slot_page2             ; cartridge also in page 2 (8000h-BFFFh)
        di
        call vdp_setup              ; SCREEN 5, VDP ID, IM 2, palette, tiles, HUD, sprite tables
        call ram_page0              ; page 0: RAM from now on (no more BIOS calls)
        jp c,no_ram
        call tiles_init             ; the tile cache and the map patches
        call atr_load               ; the map attributes into page-0 RAM
        ld hl,AG + 0x8000           ; the game's globals ($8000-$80FF)
        ld bc,256
        xor a
        call fill
        call pl_init                ; the start of the level: RoboCop, the camera, the cadence
        ld hl,AC_VARS               ; the variables of the Amiga's code area at the game's start
        ld bc,AC_VARS_END - AC_VARS ; (they live on across levels: ac_mkstep $C44A...)
        xor a
        call fill
        ld a,BANK_L1
        ld (lvl_bank),a
        call logic_map
        call obj_start              ; the objects (level 1)
        ld a,BANK_LC2
        call bank_8000
        call ao_start               ; the map objects and their first pass over the whole map
        call logic_map
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
        call sprites_init
        call spr_demo_init
        call hud_init
        call demo_init
        ld a,R0_IE1_ON
        ld b,0
        call wrreg                  ; line interrupt on (R#19 comes with each frame)
        ld a,R1_ON
        ld b,1
        call wrreg                  ; display and VBLANK interrupt on
mainloop:
        call wait_frame             ; feeds the VDP while waiting; returns right after the VBLANK
        call sprites_vblank         ; SAT of the list now on screen (still in the VBLANK)
        call key_scan               ; the keys the game reads as key codes (pause)
        call cadence                ; g_tick: does the game tick this frame (30 per second)?
        call hud_frame              ; HUD changes, long before the beam reaches the HUD
        call feed_vdp               ; (the scroll engine's next VDP command runs meanwhile)
        ld a,(g_tick)
        or a
        jr z,ml_frame
tick_start:
        call game_tick              ; the game's logic: RoboCop, the camera (the view)
        call do_update              ; scroll engine: state of the next frame, VDP work
        call pl_show                ; RoboCop's composition and place against the view shown
        call bob_flush              ; the BOBs of the tick as sprite objects
        if DEMO_ACTORS
        call demo_tick              ; the demo's objects
        endif
        call feed_vdp
        call sprites_moved          ; their positions go into the next SAT
        ld a,1
        ld (g_after),a
        jr ml_spr
ml_frame:
        call do_update
        ld a,(g_after)              ; the frame after a tick: budget and layout for the objects
        or a                        ; as it left them (60 Hz: some frames have no game work)
        jr z,ml_spr
        xor a
        ld (g_after),a
        call sprites_tick
ml_spr: call sprites_frame          ; upload slice, SAT, R#5 for the list
        if DEMO_HUD
        call hud_demo               ; demo of the game's HUD events
        endif
        call do_publish             ; registers of the next frame for the VBLANK
        jr mainloop

; No RAM in page 0 (the main RAM is not in page 3's slot): a red screen.
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
        include "player.inc"        ; RoboCop's logic tables (tools/player.py --inc)
        include "input.inc"         ; the JOY script of test builds (tools/mkrom.py)

palette:
        incbin "level1.pal"
hud_palette:
        incbin "hud.pal"
rowtab:
        include "rowtab.inc"

code_end:
        ds 0x8000 - code_end, 0xFF  ; pads banks 0-1 (16 KiB)

; ----- the game logic, module 1: the enemies (BANK_LC1 at 8000h while the game ticks) -----
        org 0x8000
        include "objects.asm"
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
