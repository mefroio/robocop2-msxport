; Bank switching - the ONLY place that knows the medium.
; Today: Konami SCC style MegaROM / MegaRAM (write inside the page itself).
; A floppy + memory mapper version only needs to replace these routines (OUT to ports FCh-FFh).
bank_8000:                          ; A = bank for the 8000h-9FFFh window
        ld (BANK_8000),a
        ret
bank_a000:                          ; A = bank for the A000h-BFFFh window
        ld (BANK_A000),a
        ret
