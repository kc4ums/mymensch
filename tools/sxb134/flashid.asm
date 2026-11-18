;***************************************************************************
;  FILE:   flashid.asm
;  TITLE:  W65C134SXB flash chip probe (read-only, erases nothing)
;
;  Runs from RAM at $7000. Sends the JEDEC "software ID" command to the
;  flash in the SXB's PLCC socket and prints what comes back:
;
;     FLASH 8000: 57 44   ID: BF B5   SST39SF010A
;
;  - "8000:" is what the chip normally holds at its first two bytes.
;  - "ID:" is the manufacturer and device code. If the ID equals the
;    normal bytes, the chip ignored the command: its write-enable is not
;    wired to the CPU (or it's write-protected), so it can only be
;    programmed off the board.
;
;  How the chip is addressed: CPU $8000-$EFFF is the flash (CS7B), CPU
;  A0-A14 go to the chip, and the chip's A15 and A16 come from P34 (FA15)
;  and P35 (FAMS). The command addresses $5555 and $2AAA are CPU $D555 and
;  $AAAA with P34 = P35 = 0. The ID is read from chip $00000 and $00001.
;  P34/P35 are put back to 1 afterwards (as the ROM monitor leaves them).
;
;  Load and run:  python sxb134.py COM5 flashid.s19 --jsr 7000 --term
;  (or paste flashid.s19 into PuTTY and type J7000)
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

PD3             EQU     $03
FBANK           EQU     $30             ; P34 = FA15, P35 = FAMS
OUTCH           EQU     $F00F           ; monitor: send A (keeps Y)

        CODE
        ORG     $7000

start:  sei
        lda     #FBANK                  ; chip A15 = A16 = 0
        trb     PD3
        lda     $8000                   ; normal contents
        sta     n0
        lda     $8001
        sta     n1
        lda     #$AA                    ; software ID entry
        sta     $D555
        lda     #$55
        sta     $AAAA
        lda     #$90
        sta     $D555
        ldx     #20                     ; > 150 ns; a few us is plenty
w1:     dex
        bne     w1
        lda     $8000
        sta     mfr
        lda     $8001
        sta     dev
        lda     #$AA                    ; ID exit (the long form works for
        sta     $D555                   ; every JEDEC part)
        lda     #$55
        sta     $AAAA
        lda     #$F0
        sta     $D555
        lda     #$F0                    ; and the short form
        sta     $8000
        ldx     #20
w2:     dex
        bne     w2
        lda     $8000                   ; back to normal?
        sta     a0
        lda     #FBANK
        tsb     PD3
        cli

        ldx     #0
        jsr     puts                    ; "FLASH 8000: "
        lda     n0
        jsr     hex
        lda     n1
        jsr     hex
        ldx     #s_id-s_all
        jsr     puts                    ; "  ID: "
        lda     mfr
        jsr     hex
        lda     dev
        jsr     hex
        lda     mfr                     ; same as the normal bytes?
        cmp     n0
        bne     known
        lda     dev
        cmp     n1
        bne     known
        ldx     #s_none-s_all
        jsr     puts
        bra     done
known:  ldy     #0                      ; look the ID up
k1:     lda     ids,y
        beq     unk
        cmp     mfr
        bne     k2
        lda     ids+1,y
        cmp     dev
        bne     k2
        lda     ids+2,y                 ; offset of the name
        tax
        jsr     puts
        bra     chk
k2:     iny
        iny
        iny
        bra     k1
unk:    ldx     #s_unk-s_all
        jsr     puts
chk:    lda     a0                      ; left ID mode?
        cmp     n0
        beq     done
        ldx     #s_stuck-s_all
        jsr     puts
done:   lda     #13
        jsr     OUTCH
        lda     #10
        jmp     OUTCH

; X = offset into s_all, string ends with 0
puts:   lda     s_all,x
        beq     p_x
        phx
        jsr     OUTCH
        plx
        inx
        bra     puts
p_x:    rts

; A in hex, then a space
hex:    pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     nib
        pla
        jsr     nib
        lda     #' '
        jmp     OUTCH
nib:    and     #$0F
        ora     #'0'
        cmp     #'9'+1
        bcc     n_x
        adc     #6
n_x:    jmp     OUTCH

n0:     db      0
n1:     db      0
mfr:    db      0
dev:    db      0
a0:     db      0

; manufacturer, device, name
ids:    db      $BF,$B5,s_sst1-s_all
        db      $BF,$B6,s_sst2-s_all
        db      $BF,$B7,s_sst4-s_all
        db      $01,$20,s_amd1-s_all
        db      $1F,$D5,s_atm1-s_all
        db      $DA,$C1,s_win1-s_all
        db      $C2,$11,s_mx1-s_all
        db      0

s_all:  db      13,10,'FLASH 8000: ',0
s_id:   db      '  ID: ',0
s_none: db      ' -> no ID: writes do not reach the chip (not in-circuit programmable)',0
s_unk:  db      ' -> unknown chip, tell Claude these two numbers',0
s_stuck: db     ' (WARNING: still in ID mode, press RESET)',0
s_sst1: db      ' SST39SF010A 128K, 4K sectors: can program in-circuit',0
s_sst2: db      ' SST39SF020A 256K, 4K sectors: can program in-circuit',0
s_sst4: db      ' SST39SF040 512K, 4K sectors: can program in-circuit',0
s_amd1: db      ' AM29F010 128K, 16K sectors: can program in-circuit',0
s_atm1: db      ' AT29C010A 128K, 128-byte pages: can program in-circuit',0
s_win1: db      ' W29C011 128K: can program in-circuit',0
s_mx1:  db      ' MX29F001 128K: can program in-circuit',0

        ENDS
        END
