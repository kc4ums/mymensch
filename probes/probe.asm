;***************************************************************************
;  FILE:   probe.asm
;  TITLE:  MyMENSCH Rev-C hardware probe for the software TNC
;
;  Measures what the datasheet doesn't say:
;    1. CPU (PHI2) clock, timed with VIA_A Timer 1 against ACIA_A's
;       1.8432 MHz baud clock (1000 characters at 115200 = 86.806 ms)
;    2. the signed and unsigned 16x16 multipliers
;    3. ADC: time for one single-cycle sequence, and sequences per second
;       in continuous mode
;    4. ADC: min / max / average of every sample slot over 256 sequences
;
;  Load and run:
;    wdc_uploader_term.exe -d COM10 probe.bin -m write -x -s 5 -t
;  Keys afterwards:  A = repeat the ADC slot scan   ESC = restart the board
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_A_DATA     EQU     $7F60
ACIA_A_STAT     EQU     $7F61
VIA_T1CL        EQU     $7F24           ; VIA_A
VIA_T1CH        EQU     $7F25
VIA_T1LL        EQU     $7F26
VIA_T1LH        EQU     $7F27
VIA_ACR         EQU     $7F2B
VIA_IFR         EQU     $7F2D
VIA_IER         EQU     $7F2E
MULU            EQU     $7FD0           ; A lo/hi, B lo/hi, result 0-3
MULS            EQU     $7FD8
ADC_SAMD0       EQU     $7FB0
ADC_SAMD1       EQU     $7FB1
ADC_SAMADDR     EQU     $7FB2
ADC_SEQD        EQU     $7FB3
ADC_CTRL        EQU     $7FB4
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1

NSLOT           EQU     10              ; ADC_IN0..8 + temperature diode
NCHARS          EQU     1000

; zero page
N32             EQU     $40
D32             EQU     $44
R32             EQU     $48
M32             EQU     $4C
P32             EQU     $50
M16             EQU     $54
DT              EQU     $56
SPTR            EQU     $5A
WIDTH           EQU     $5C
OVF             EQU     $5D             ; Timer 1 underflows (2)
H0              EQU     $5F             ; T1 high byte at start
H1              EQU     $60             ; T1 high byte at end
CNT             EQU     $61             ; 2
TO              EQU     $63             ; timeout counter (2)
SLOT            EQU     $65
VLO             EQU     $66
VHI             EQU     $67
TMP             EQU     $68

; slot statistics (data RAM)
MINL            EQU     $0300
MINH            EQU     $0310
MAXL            EQU     $0320
MAXH            EQU     $0330
SUM0            EQU     $0340           ; 24-bit sums
SUM1            EQU     $0350
SUM2            EQU     $0360
FIRSTL          EQU     $0370
FIRSTH          EQU     $0380
DIGBUF          EQU     $0390

PRINT   MACRO   STR
        ldx     #<STR
        ldy     #>STR
        jsr     puts_k
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

START:
        sei
        cld
        ldx     #$FF
        txs
        stz     WIDTH
        lda     #$80                    ; RTS to the CH340 so keys get through
        tsb     GPIOE_DDR
        trb     GPIOE_PIO
        PRINT   s_title
        jsr     t1_start
        jsr     clock_test
        jsr     mul_test
        jsr     adc_timing
        jsr     adc_scan
        PRINT   s_keys

idle:   lda     ACIA_A_STAT
        and     #$08
        beq     idle
        lda     ACIA_A_DATA
        cmp     #$1B
        beq     reboot
        and     #$DF
        cmp     #'A'
        bne     idle
        jsr     adc_scan
        PRINT   s_keys
        bra     idle
reboot: jmp     ($FFFC)

;---------------------------------------------------------------------------
; VIA_A Timer 1 free-running from $FFFF, interrupts off. Counts PHI2.
;---------------------------------------------------------------------------
t1_start:
        lda     #$7F
        sta     VIA_IER                 ; no VIA interrupts
        lda     #$40
        sta     VIA_ACR                 ; T1 continuous, PB7 off
        lda     #$FF
        sta     VIA_T1LL
        sta     VIA_T1LH
        sta     VIA_T1CL
        sta     VIA_T1CH                ; load and start
        lda     VIA_T1CL                ; clear the flag
        rts

; count a Timer 1 underflow if one happened (flag cleared by reading T1CL)
t1_poll:
        lda     VIA_IFR
        and     #$40
        beq     tp_r
        lda     VIA_T1CL
        inc     OVF
        bne     tp_r
        inc     OVF+1
tp_r:   rts

; begin a measurement: OVF = 0, H0 = timer high byte
t1_mark:
        jsr     t1_poll
        stz     OVF
        stz     OVF+1
        lda     VIA_T1CH
        sta     H0
        rts

; end a measurement: N32 = elapsed PHI2 cycles (256-cycle resolution)
t1_elapsed:
        lda     VIA_T1CH
        sta     H1
        jsr     t1_poll
        lda     OVF                     ; N32 = OVF * 65537
        sta     N32
        sta     N32+2
        lda     OVF+1
        sta     N32+1
        sta     N32+3
        lda     H0                      ; + (H0 - H1) * 256, H0 >= H1 unless wrapped
        sec
        sbc     H1
        tax
        lda     #0
        sbc     #0                      ; A = $FF if negative
        sta     TMP
        clc
        txa
        adc     N32+1
        sta     N32+1
        lda     TMP
        adc     N32+2
        sta     N32+2
        lda     TMP
        adc     N32+3
        sta     N32+3
        rts

;---------------------------------------------------------------------------
; 1. CPU clock: 1000 back-to-back characters at 115200 baud = 86.806 ms
;---------------------------------------------------------------------------
clock_test:
        PRINT   s_clk
        ldx     #4                      ; prime the transmitter
ct_pr:  jsr     tx_nul
        dex
        bne     ct_pr
        jsr     t1_mark
        lda     #<NCHARS
        sta     CNT
        lda     #>NCHARS
        sta     CNT+1
ct_lp:  jsr     tx_nul
        lda     CNT
        bne     ct_d
        dec     CNT+1
ct_d:   dec     CNT
        lda     CNT
        ora     CNT+1
        bne     ct_lp
        jsr     t1_elapsed
        PRINT   s_cyc
        jsr     print_u32
        lda     N32                     ; Hz = cycles * 1152 / 100
        sta     M32
        lda     N32+1
        sta     M32+1
        lda     N32+2
        sta     M32+2
        lda     N32+3
        sta     M32+3
        lda     #<1152
        sta     M16
        lda     #>1152
        sta     M16+1
        jsr     mul32
        jsr     p_to_n
        lda     #100
        jsr     set_d
        jsr     div32
        PRINT   s_hz
        jsr     print_u32
        PRINT   s_expect
        lda     #<9600                  ; cycles per 9600 Hz sample
        sta     D32
        lda     #>9600
        sta     D32+1
        stz     D32+2
        stz     D32+3
        jsr     div32
        PRINT   s_persamp
        jsr     print_u32
        jmp     crlf

; send a NUL once the transmitter is free; polls Timer 1 while waiting
tx_nul: jsr     t1_poll
        lda     ACIA_A_STAT
        and     #$10
        beq     tx_nul
        stz     ACIA_A_DATA
        rts

;---------------------------------------------------------------------------
; 2. Multipliers
;---------------------------------------------------------------------------
mul_test:
        PRINT   s_mulu                  ; 300 * 400 = 120000 = $0001D4C0
        lda     #<300
        sta     MULU
        lda     #>300
        sta     MULU+1
        lda     #<400
        sta     MULU+2
        lda     #>400
        sta     MULU+3
        ldx     #MULU-$7F00+4
        jsr     show_res
        PRINT   s_want_u
        PRINT   s_muls                  ; -3 * 1234 = -3702 = $FFFFF18A
        lda     #$FD                    ; -3
        sta     MULS
        lda     #$FF
        sta     MULS+1
        lda     #<1234
        sta     MULS+2
        lda     #>1234
        sta     MULS+3
        ldx     #MULS-$7F00+4
        jsr     show_res
        PRINT   s_want_s
        rts

; print the 4 result bytes at $7F00+X as a 32-bit hex number
show_res:
        lda     $7F03,x
        jsr     hex8
        lda     $7F02,x
        jsr     hex8
        lda     $7F01,x
        jsr     hex8
        lda     $7F00,x
        jmp     hex8

;---------------------------------------------------------------------------
; 3. ADC timing
;---------------------------------------------------------------------------
adc_timing:
        PRINT   s_adc1
        jsr     adc_single              ; first one may be slow
        bcc     at_ok
        PRINT   s_noeop
        rts
at_ok:  jsr     t1_mark
        lda     #64
        sta     CNT
at_lp:  jsr     adc_single
        bcs     at_to
        dec     CNT
        bne     at_lp
        jsr     t1_elapsed              ; cycles for 64 sequences
        ldx     #6                      ; / 64
at_sh:  lsr     N32+3
        ror     N32+2
        ror     N32+1
        ror     N32
        dex
        bne     at_sh
        jsr     print_u32
        PRINT   s_cycseq
        bra     at_cont
at_to:  PRINT   s_noeop
        rts

at_cont:
        PRINT   s_adc2                  ; continuous mode: count EOPs
        lda     #$01
        sta     ADC_SEQD                ; continuous, run
        lda     #$01
        sta     ADC_CTRL                ; autorun
        stz     CNT
        stz     CNT+1
        jsr     t1_mark
ac_lp:  jsr     t1_poll
        lda     OVF
        cmp     #20                     ; 20 x 65537 cycles (~89 ms at 14.7 MHz)
        bcs     ac_end
        lda     ADC_CTRL
        bit     #$80
        beq     ac_lp
        jsr     eop_reset
        inc     CNT
        bne     ac_lp
        inc     CNT+1
        bra     ac_lp
ac_end: jsr     t1_elapsed
        stz     ADC_SEQD                ; stop the sequencer
        lda     #$01
        sta     ADC_CTRL
        ldx     #3                      ; keep the cycle count
ae_sv:  lda     N32,x
        sta     FIRSTL,x
        dex
        bpl     ae_sv
        lda     CNT
        ldx     CNT+1
        jsr     pnum16
        PRINT   s_eops
        ldx     #3
ae_rs:  lda     FIRSTL,x
        sta     N32,x
        dex
        bpl     ae_rs
        jsr     print_u32
        PRINT   s_cyc2
        jmp     crlf

; run one single-cycle sequence; C=1 if no end-of-packet arrived
adc_single:
        lda     #$03
        sta     ADC_SEQD                ; single cycle, run
        lda     #$01
        sta     ADC_CTRL                ; autorun
        stz     TO
        stz     TO+1
as_w:   lda     ADC_CTRL
        bit     #$80
        bne     as_ok
        inc     TO
        bne     as_w
        inc     TO+1
        bne     as_w
        sec
        rts
as_ok:  jsr     eop_reset
        clc
        rts

; clear the end-of-packet flag (sequence from the WDC datasheet example)
eop_reset:
        lda     #$01
        sta     ADC_SAMD0
        lda     #$41
        sta     ADC_SAMADDR
        lda     #$10
        sta     ADC_CTRL
        stz     ADC_CTRL
        rts

;---------------------------------------------------------------------------
; 4. Slot statistics over 256 single sequences
;---------------------------------------------------------------------------
adc_scan:
        PRINT   s_scan
        ldx     #NSLOT-1
sc_in:  lda     #$FF
        sta     MINL,x
        sta     MINH,x
        stz     MAXL,x
        stz     MAXH,x
        stz     SUM0,x
        stz     SUM1,x
        stz     SUM2,x
        dex
        bpl     sc_in
        stz     CNT
sc_lp:  jsr     adc_single
        bcc     sc_ok
        PRINT   s_noeop
        rts
sc_ok:  ldx     #0
sc_sl:  stx     ADC_SAMADDR
        lda     ADC_SAMD0
        sta     VLO
        lda     ADC_SAMD1
        sta     VHI
        lda     CNT
        bne     sc_nf
        lda     VLO
        sta     FIRSTL,x
        lda     VHI
        sta     FIRSTH,x
sc_nf:  lda     VLO                     ; min
        cmp     MINL,x
        lda     VHI
        sbc     MINH,x
        bcs     sc_nmin
        lda     VLO
        sta     MINL,x
        lda     VHI
        sta     MINH,x
sc_nmin:
        lda     MAXL,x                  ; max
        cmp     VLO
        lda     MAXH,x
        sbc     VHI
        bcs     sc_nmax
        lda     VLO
        sta     MAXL,x
        lda     VHI
        sta     MAXH,x
sc_nmax:
        clc                             ; sum
        lda     SUM0,x
        adc     VLO
        sta     SUM0,x
        lda     SUM1,x
        adc     VHI
        sta     SUM1,x
        lda     SUM2,x
        adc     #0
        sta     SUM2,x
        inx
        cpx     #NSLOT
        bne     sc_sl
        dec     CNT
        bne     sc_lp

        PRINT   s_hdr
        ldx     #0
sc_pr:  stx     SLOT
        lda     #' '
        jsr     putc
        jsr     putc
        lda     SLOT
        ldx     #0
        jsr     pnum16
        PRINT   s_sp4
        ldx     SLOT
        lda     FIRSTH,x
        jsr     hex8
        lda     FIRSTL,x
        jsr     hex8
        jsr     sp2
        ldx     SLOT
        lda     #4
        sta     WIDTH
        lda     MINL,x
        ldy     MINH,x
        jsr     pnum_ay
        jsr     sp2
        ldx     SLOT
        lda     #4
        sta     WIDTH
        lda     MAXL,x
        ldy     MAXH,x
        jsr     pnum_ay
        jsr     sp2
        ldx     SLOT
        lda     #4
        sta     WIDTH
        lda     SUM1,x                  ; average = sum / 256
        ldy     SUM2,x
        jsr     pnum_ay
        jsr     crlf
        ldx     SLOT
        inx
        cpx     #NSLOT
        bne     sc_pr
        rts

;---------------------------------------------------------------------------
; Output helpers
;---------------------------------------------------------------------------
puts_k: stx     SPTR
        sty     SPTR+1
        ldy     #0
ps_lp:  lda     (SPTR),y
        beq     ps_d
        jsr     putc
        iny
        bne     ps_lp
        inc     SPTR+1
        bra     ps_lp
ps_d:   rts

putc:   pha
pc_w:   lda     ACIA_A_STAT
        and     #$10
        beq     pc_w
        pla
        sta     ACIA_A_DATA
        rts

crlf:   lda     #$0D
        jsr     putc
        lda     #$0A
        jmp     putc

sp2:    lda     #' '
        jsr     putc
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
        adc     #6                      ; C=1: +7 -> 'A'
hx_d:   adc     #'0'
        jmp     putc

pnum_ay:                                ; Y:A unsigned decimal
        sta     N32
        sty     N32+1
        stz     N32+2
        stz     N32+3
        jmp     print_u32

pnum16: sta     N32                     ; X:A unsigned decimal
        stx     N32+1
        stz     N32+2
        stz     N32+3
        jmp     print_u32

p_to_n: ldx     #3
ptn_lp: lda     P32,x
        sta     N32,x
        dex
        bpl     ptn_lp
        rts

set_d:  sta     D32
        stz     D32+1
        stz     D32+2
        stz     D32+3
        rts

; print N32 in decimal (N32 is preserved), zero padded to WIDTH
print_u32:
        phx
        phy
        ldx     #3
pu_sv:  lda     N32,x
        sta     M32,x                   ; keep a copy
        dex
        bpl     pu_sv
        ldy     #0
pu_lp:  lda     #10
        jsr     set_d
        jsr     div32
        lda     R32
        ora     #'0'
        sta     DIGBUF,y
        iny
        lda     N32
        ora     N32+1
        ora     N32+2
        ora     N32+3
        bne     pu_lp
pu_pad: cpy     WIDTH
        bcs     pu_out
        lda     #'0'
        sta     DIGBUF,y
        iny
        bra     pu_pad
pu_out: dey
        lda     DIGBUF,y
        jsr     putc
        cpy     #0
        bne     pu_out
        stz     WIDTH
        ldx     #3
pu_rs:  lda     M32,x
        sta     N32,x
        dex
        bpl     pu_rs
        ply
        plx
        rts

; N32 / D32 -> quotient N32, remainder R32
div32:  phx
        stz     R32
        stz     R32+1
        stz     R32+2
        stz     R32+3
        ldx     #32
dv_lp:  asl     N32
        rol     N32+1
        rol     N32+2
        rol     N32+3
        rol     R32
        rol     R32+1
        rol     R32+2
        rol     R32+3
        sec
        lda     R32
        sbc     D32
        sta     DT
        lda     R32+1
        sbc     D32+1
        sta     DT+1
        lda     R32+2
        sbc     D32+2
        sta     DT+2
        lda     R32+3
        sbc     D32+3
        bcc     dv_nx
        sta     R32+3
        lda     DT+2
        sta     R32+2
        lda     DT+1
        sta     R32+1
        lda     DT
        sta     R32
        inc     N32
dv_nx:  dex
        bne     dv_lp
        plx
        rts

; P32 = M32 * M16
mul32:  phx
        stz     P32
        stz     P32+1
        stz     P32+2
        stz     P32+3
        ldx     #16
mu_lp:  lsr     M16+1
        ror     M16
        bcc     mu_nx
        clc
        lda     P32
        adc     M32
        sta     P32
        lda     P32+1
        adc     M32+1
        sta     P32+1
        lda     P32+2
        adc     M32+2
        sta     P32+2
        lda     P32+3
        adc     M32+3
        sta     P32+3
mu_nx:  asl     M32
        rol     M32+1
        rol     M32+2
        rol     M32+3
        dex
        bne     mu_lp
        plx
        rts

;---------------------------------------------------------------------------
s_title:
        db      $0D,$0A,'MyMENSCH hardware probe',$0D,$0A,0
s_clk:  db      $0D,$0A,'1. CPU clock (1000 chars at 115200 baud)',$0D,$0A,0
s_cyc:  db      '   cycles: ',0
s_hz:   db      $0D,$0A,'   PHI2:   ',0
s_expect:
        db      ' Hz   (14745600 if undivided)',0
s_persamp:
        db      $0D,$0A,'   cycles per 9600 Hz sample: ',0
s_mulu: db      $0D,$0A,'2. Multipliers',$0D,$0A,'   unsigned 300*400  = ',0
s_want_u:
        db      '   (want 0001D4C0)',$0D,$0A,0
s_muls: db      '   signed  -3*1234   = ',0
s_want_s:
        db      '   (want FFFFF18A)',$0D,$0A,0
s_adc1: db      $0D,$0A,'3. ADC timing',$0D,$0A,'   single-cycle sequence: ',0
s_cycseq:
        db      ' cycles each',$0D,$0A,0
s_noeop:
        db      'NO END-OF-PACKET (ADC did not finish)',$0D,$0A,0
s_adc2: db      '   continuous mode: ',0
s_eops: db      ' sequences in ',0
s_cyc2: db      ' cycles',0
s_scan: db      $0D,$0A,'4. ADC slots over 256 sequences',$0D,$0A,0
s_hdr:  db      '  slot  first  min   max   avg',$0D,$0A,0
s_sp4:  db      '    ',0
s_keys: db      $0D,$0A,'A = scan ADC again   ESC = restart',$0D,$0A,0

        ENDS
        END
