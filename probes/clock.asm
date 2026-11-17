;***************************************************************************
;  FILE:   clock.asm
;  TITLE:  MyMENSCH Rev-C clock and VIA_A Timer 1 probe
;
;  probe.asm's clock figure came out as 42.5 MHz, which can't be right.
;  Its wrap counter relies on the T1 interrupt flag clearing when T1C-L
;  is read; if this FPGA's VIA doesn't do that, every poll counts as a
;  wrap. This probe avoids the flag:
;    1. While 1000 characters go out at 115200 baud (86.806 ms) it reads
;       T1C-H and counts a wrap whenever the value jumps up. It also counts
;       its own loop iterations (about 30 cycles each on a W65C02S).
;    2. It then checks how the T1 flag (IFR bit 6) clears: by reading
;       T1C-L, and by writing $40 to the IFR.
;  All results are printed in hex.
;
;  Load and run:
;    wdc_uploader_term.exe -d COM4 clock.bin -m write -x -s 5 -t
;  Keys afterwards:  C = run again   ESC = restart the board
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_DATA       EQU     $7F60
ACIA_STAT       EQU     $7F61
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1
VIA             EQU     $7F20           ; VIA_A
T1CL            EQU     VIA+4
T1CH            EQU     VIA+5
T1LL            EQU     VIA+6
T1LH            EQU     VIA+7
ACR             EQU     VIA+11
IFR             EQU     VIA+13
IER             EQU     VIA+14

; zero page
CNT             EQU     $40             ; 3, loop iterations
WRAPS           EQU     $43             ; 2, T1 wraps seen
LASTH           EQU     $45
H0              EQU     $46             ; T1C-H at start
H1              EQU     $47             ; T1C-H at end
NCH             EQU     $48             ; 2, characters left
SPTR            EQU     $4A             ; 2
TO              EQU     $4C             ; 2, timeout
F_UP            EQU     $4E             ; IFR readings
F_RD            EQU     $4F
F_WR            EQU     $50

PRINT   MACRO   STR
        ldx     #<STR
        ldy     #>STR
        jsr     puts
        ENDM

        CODE
        ORG     $8000
        jmp     START
        jmp     NoINT                   ; NMI
        jmp     NoINT                   ; BRK
        jmp     NoINT                   ; IRQ_ACIA_C
        jmp     NoINT                   ; IRQ_ACIA_B
        jmp     NoINT                   ; IRQ_ACIA_A
        jmp     NoINT                   ; IRQ_ADC
        jmp     NoINT                   ; IRQ_I2C
        jmp     NoINT                   ; IRQ_SPI
        jmp     NoINT                   ; IRQ_VIA_D
        jmp     NoINT                   ; IRQ_VIA_C
        jmp     NoINT                   ; IRQ_VIA_B
        jmp     NoINT                   ; IRQ_VIA_A
        jmp     NoINT                   ; IRQ_GPIO_A
        jmp     NoINT                   ; IRQ_GPIO_E
NoINT:  rti

START:  sei
        cld
        ldx     #$FF
        txs
        lda     #$80                    ; RTS to the CH340 so keys get through
        tsb     GPIOE_DDR
        trb     GPIOE_PIO
run:    PRINT   s_title
        jsr     measure
        jsr     flagtest
        PRINT   s_keys
idle:   lda     ACIA_STAT
        and     #$08
        beq     idle
        lda     ACIA_DATA
        cmp     #$1B
        beq     reboot
        and     #$DF
        cmp     #'C'
        bne     idle
        bra     run
reboot: jmp     ($FFFC)

;---------------------------------------------------------------------------
; 1. T1 ticks and loop iterations during 1000 characters
;---------------------------------------------------------------------------
measure:
        PRINT   s_m1
        lda     #$7F
        sta     IER                     ; VIA interrupts off
        lda     #$40
        sta     ACR                     ; T1 continuous
        lda     #$FF
        sta     T1LL
        sta     T1LH
        sta     T1CL
        sta     T1CH                    ; load $FFFF and start
        ldx     #4                      ; fill the transmitter first
ms_f:   lda     ACIA_STAT
        and     #$10
        beq     ms_f
        stz     ACIA_DATA
        dex
        bne     ms_f
        stz     CNT
        stz     CNT+1
        stz     CNT+2
        stz     WRAPS
        stz     WRAPS+1
        lda     #<1000
        sta     NCH
        lda     #>1000
        sta     NCH+1
ms_w:   lda     ACIA_STAT               ; start on a character boundary
        and     #$10
        beq     ms_w
        stz     ACIA_DATA
        lda     T1CH
        sta     H0
        sta     LASTH
ms_lp:  inc     CNT                     ; 5
        bne     ms_t                    ; 3
        inc     CNT+1
        bne     ms_t
        inc     CNT+2
ms_t:   lda     T1CH                    ; 4
        cmp     LASTH                   ; 3
        sta     LASTH                   ; 3
        beq     ms_s                    ; 3  (same value: most loops)
        bcc     ms_s                    ;    counting down: no wrap
        inc     WRAPS                   ;    jumped up: wrapped
        bne     ms_s
        inc     WRAPS+1
ms_s:   lda     ACIA_STAT               ; 4
        and     #$10                    ; 2
        beq     ms_lp                   ; 3  = 30 cycles a loop
        stz     ACIA_DATA
        lda     NCH
        bne     ms_d
        dec     NCH+1
ms_d:   dec     NCH
        lda     NCH
        ora     NCH+1
        bne     ms_lp
        lda     T1CH
        sta     H1
        jsr     crlf
        PRINT   s_wraps
        lda     WRAPS+1
        jsr     hex8
        lda     WRAPS
        jsr     hex8
        PRINT   s_h0
        lda     H0
        jsr     hex8
        PRINT   s_h1
        lda     H1
        jsr     hex8
        PRINT   s_loops
        lda     CNT+2
        jsr     hex8
        lda     CNT+1
        jsr     hex8
        lda     CNT
        jsr     hex8
        jmp     crlf

;---------------------------------------------------------------------------
; 2. how does the T1 flag clear?
;---------------------------------------------------------------------------
flagtest:
        PRINT   s_f1
        stz     ACR                     ; one-shot: the flag sets only once
        stz     T1LL
        lda     #$04                    ; $0400 cycles
        sta     T1LH
        sta     T1CH                    ; start
        jsr     waitflag
        lda     IFR                     ; flag up
        sta     F_UP
        lda     T1CL                    ; a real 65C22 clears it here
        lda     IFR
        sta     F_RD
        lda     #$04
        sta     T1CH                    ; one-shot again
        jsr     waitflag
        lda     #$40                    ; write 1 to clear
        sta     IFR
        lda     IFR
        sta     F_WR
        PRINT   s_f2
        lda     F_UP
        jsr     hex8
        PRINT   s_f3
        lda     F_RD
        jsr     hex8
        PRINT   s_f4
        lda     F_WR
        jsr     hex8
        lda     #$7F
        sta     IER
        jmp     crlf

; wait for IFR bit 6 (or about 50 ms)
waitflag:
        stz     TO
        stz     TO+1
wf_lp:  lda     IFR
        and     #$40
        bne     wf_x
        inc     TO
        bne     wf_lp
        inc     TO+1
        bne     wf_lp
        PRINT   s_nof
wf_x:   rts

;---------------------------------------------------------------------------
; console
;---------------------------------------------------------------------------
puts:   stx     SPTR
        sty     SPTR+1
        ldy     #0
ps_lp:  lda     (SPTR),y
        beq     ps_d
        jsr     putc
        iny
        bne     ps_lp
ps_d:   rts

putc:   pha
pc_w:   lda     ACIA_STAT
        and     #$10
        beq     pc_w
        pla
        sta     ACIA_DATA
        rts

crlf:   lda     #$0D
        jsr     putc
        lda     #$0A
        jmp     putc

hex8:   pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     hex4
        pla
hex4:   and     #$0F
        cmp     #10
        bcc     hx_d
        adc     #6
hx_d:   adc     #'0'
        jmp     putc

;---------------------------------------------------------------------------
s_title:
        db      $0D,$0A,'MyMENSCH clock probe (VIA_A T1, no IFR)',$0D,$0A,0
s_m1:   db      '1. 1000 chars at 115200 (NULs follow)',$0D,$0A,0
s_wraps:
        db      '   T1 wraps: ',0
s_h0:   db      '  T1C-H start: ',0
s_h1:   db      '  end: ',0
s_loops:
        db      $0D,$0A,'   loop iterations: ',0
s_f1:   db      '2. T1 flag (IFR bit 6)',$0D,$0A,0
s_f2:   db      '   IFR with flag up: ',0
s_f3:   db      '  after reading T1C-L: ',0
s_f4:   db      '  after writing $40 to IFR: ',0
s_nof:  db      ' (flag never set) ',0
s_keys: db      $0D,$0A,'C = run again   ESC = restart',$0D,$0A,0

        ENDS
        END
