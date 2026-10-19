; Robocop 2 MSX - scroll engine prototype.
; MegaROM with a Konami SCC style mapper (MegaRAM compatible): 8 KiB banks switched by
; writes inside the page itself (9000h -> 8000h window, B000h -> A000h window).
; Banks 0-1 = code (4000h-7FFFh, fixed); data in the 8000h and A000h windows.
; Build with tools/mkrom.py (z80asm 1.8).

        include "banks.inc"
        include "msx.inc"

FORCE_V9938: equ 0                  ; 1 = use the MSX2 engine even on a V9958 (test)

        org 0x4000
        db "AB"
        dw init
        ds 12, 0

init:   di
        ld sp,0xF380
        call slot_page2             ; cartridge also in page 2 (8000h-BFFFh)
        di
        call vdp_setup              ; SCREEN 5, VDP ID, palette, tiles in VRAM
        ld a,(vdp_id)
        cp 2
        jr nz,run9938
        if FORCE_V9938
        jr run9938
        endif
        call scroll_init
mainloop:
        call wait_vbl
        call scroll_regs            ; R#23/R#26/R#27 during the blanking
        call camera_step
        call scroll_update          ; queues and draws new edges (per-frame budget)
        call frame_end
        jr mainloop

run9938:
        call s38_init
ml38:   call wait_vbl
        call s38_regs               ; R#23/R#18/R#2 during the blanking
        call camera_step
        call s38_update
        call s38_kick
        call frame_end
        jr ml38

; Counts frames and late frames (the next VBLANK has already arrived).
frame_end:
        call vbl_pending
        jr z,fe_ok
        ld hl,(late)
        inc hl
        ld (late),hl
fe_ok:  ld hl,(frame)
        inc hl
        ld (frame),hl
        ret

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

; Demo camera: moves 1 px/frame to the right and bounces vertically (1 px every 2 frames).
camera_step:
        ld hl,(cam_x)
        ld de,CAM_X_MAX
        or a
        sbc hl,de
        jr nc,cs_y
        ld hl,(cam_x)
        inc hl
        ld (cam_x),hl
cs_y:   ld a,(frame)
        and 1
        ret z
        ld hl,(cam_y)
        ld a,(dir_y)
        or a
        jr nz,cs_down
        ld a,h                      ; moving up: stops at 0
        or l
        jr z,cs_flip
        dec hl
        ld (cam_y),hl
        ret
cs_down:
        ld de,CAM_Y_MAX
        push hl
        or a
        sbc hl,de
        pop hl
        jr nc,cs_flip
        inc hl
        ld (cam_y),hl
        ret
cs_flip:
        ld a,(dir_y)
        xor 1
        ld (dir_y),a
        ret

        include "bank.asm"
        include "vdp.asm"
        include "tiles.asm"
        include "scroll9958.asm"
        include "scroll9938.asm"

palette:
        incbin "level1.pal"
rowtab:
        include "rowtab.inc"

code_end:
        ds 0x8000 - code_end, 0xFF  ; pads banks 0-1 (16 KiB)
