;***************************************************************************
;  FILE:   adcprobe.asm
;  TITLE:  MyMENSCH Rev-C (W65C165i1M08SA) ADC probe
;
;  probe.asm and regmap.asm see no end-of-packet from the ADC at $7FB0.
;  This drives the ADC block every way the datasheet allows and prints
;  everything raw, so one run shows where the chain breaks:
;    1. $7FB0-$7FBF as read, then write/read-back of SAMD0, SAMD1,
;       SAMADDR and SEQD (CTRL is not written here; it has side effects)
;    2. sample store IER ($40) and ISR ($41) read with the SAMP_RD strobe
;    3. IER set to 1 (EOP interrupt enabled) with the SAMP_WR strobe
;    4. sequencer CSR written with SEQ_WR and read back with SEQ_RD
;    5. datasheet autorun (SEQD=03, CTRL=01), with IER on and SAMADDR
;       left at $41 so the autorun side-write only clears the ISR
;    6. slots 0-9 read directly (datasheet way) and with SAMP_RD
;
;  Registers (datasheet 2.14): base $7FB0
;    +0 SAMD0  +1 SAMD1  +2 SAMADDR  +3 SEQD  +4 CTRL
;    CTRL: 7 IRQ  6 IRQ_EN  5 SAMP_RD  4 SAMP_WR  3 SEQ_ADR  2 SEQ_RD
;          1 SEQ_WR  0 AUTORUN
;  Sample store (Intel Modular ADC): $00-$3F slots, $40 IER, $41 ISR.
;  Slot 8 is the temperature diode: about 3670 ($0E56) at 28 C.
;
;  No header pins are changed apart from GPIO E7 (RTS to the CH340).
;
;  Load and run:
;    wdc_uploader_term.exe -d COM10 adcprobe.bin -m write -x -s 5 -t
;  Keys afterwards:  D = run again   ESC = restart the board
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_A_DATA     EQU     $7F60
ACIA_A_STAT     EQU     $7F61
ADC_BASE        EQU     $7FB0
ADC_SAMD0       EQU     $7FB0
ADC_SAMD1       EQU     $7FB1
ADC_SAMADDR     EQU     $7FB2
ADC_SEQD        EQU     $7FB3
ADC_CTRL        EQU     $7FB4
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1

C_SAMP_RD       EQU     $20
C_SAMP_WR       EQU     $10
C_SEQ_RD        EQU     $04
C_SEQ_WR        EQU     $02
C_AUTORUN       EQU     $01

; zero page
CNT             EQU     $40             ; poll counter (2)
REG             EQU     $42             ; register offset under test
PAT             EQU     $43             ; pattern written
SPTR            EQU     $49             ; string pointer (2)

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
        lda     #$80                    ; RTS to the CH340 so keys get through
        tsb     GPIOE_DDR
        trb     GPIOE_PIO
run_all:
        PRINT   s_title
        jsr     t_regs
        jsr     t_store
        jsr     t_ier
        jsr     t_seq
        jsr     t_auto
        jsr     t_slots
        stz     ADC_SEQD                ; leave the sequencer stopped
        PRINT   s_keys

idle:   lda     ACIA_A_STAT
        and     #$08
        beq     idle
        lda     ACIA_A_DATA
        cmp     #$1B
        beq     reboot
        and     #$DF
        cmp     #'D'
        bne     idle
        bra     run_all
reboot: jmp     ($FFFC)

;---------------------------------------------------------------------------
; 1. raw registers and read-back
;---------------------------------------------------------------------------
t_regs: PRINT   s_raw
        ldx     #0
tr_d:   lda     ADC_BASE,x
        jsr     hex8
        jsr     space
        inx
        cpx     #16
        bne     tr_d
        PRINT   s_rb
        ldx     #0                      ; SAMD0, SAMD1, SAMADDR, SEQD
tr_r:   stx     REG
        lda     #'+'
        jsr     putc
        txa
        jsr     hex4
        lda     #' '
        jsr     putc
        lda     #$5A
        jsr     wr_rd
        lda     #$25                    ; bit 7 clear: SEQD/SAMADDR may not keep it
        jsr     wr_rd
        jsr     space
        ldx     REG
        inx
        cpx     #4
        bne     tr_r
        stz     ADC_SAMADDR
        stz     ADC_SEQD
        stz     ADC_SAMD0
        stz     ADC_SAMD1
        jmp     crlf

; write A to ADC_BASE+REG, print "ww->rr "
wr_rd:  sta     PAT
        jsr     hex8
        ldx     REG
        lda     PAT
        sta     ADC_BASE,x
        lda     #'-'
        jsr     putc
        lda     #'>'
        jsr     putc
        ldx     REG
        lda     ADC_BASE,x
        jsr     hex8
        jmp     space

;---------------------------------------------------------------------------
; 2. IER and ISR through the SAMP_RD strobe
;---------------------------------------------------------------------------
t_store:
        PRINT   s_st2
        PRINT   s_ier
        lda     #$40
        jsr     st_rd
        PRINT   s_isr
        lda     #$41
        jsr     st_rd
        jmp     crlf

; read sample store word at address A with SAMP_RD; print "hhll"
st_rd:  sta     ADC_SAMADDR
        lda     #C_SAMP_RD
        sta     ADC_CTRL
        nop
        nop
        lda     ADC_SAMD1
        jsr     hex8
        lda     ADC_SAMD0
        jsr     hex8
        stz     ADC_CTRL
        rts

; write word $00:A to sample store address X with SAMP_WR
st_wr:  sta     ADC_SAMD0
        stz     ADC_SAMD1
        stx     ADC_SAMADDR
        lda     #C_SAMP_WR
        sta     ADC_CTRL
        nop
        nop
        stz     ADC_CTRL
        rts

;---------------------------------------------------------------------------
; 3. enable the EOP interrupt in the sample store
;---------------------------------------------------------------------------
t_ier:  PRINT   s_ieron
        lda     #$01
        ldx     #$40
        jsr     st_wr
        lda     #$01                    ; clear any stale EOP
        ldx     #$41
        jsr     st_wr
        PRINT   s_ier
        lda     #$40
        jsr     st_rd
        PRINT   s_isr
        lda     #$41
        jsr     st_rd
        PRINT   s_ctrl
        lda     ADC_CTRL
        jsr     hex8
        jmp     crlf

;---------------------------------------------------------------------------
; 4. sequencer CSR with the manual SEQ_WR / SEQ_RD strobes
;---------------------------------------------------------------------------
t_seq:  PRINT   s_seq
        lda     #$00                    ; stop
        jsr     seq_wr
        jsr     seq_rd
        jsr     space
        lda     #$03                    ; single cycle, run
        jsr     seq_wr
        jsr     seq_rd
        jsr     poll                    ; prints CTRL and OK / NO EOP
        PRINT   s_stop
        lda     #$00
        jsr     seq_wr
        jsr     seq_rd
        jmp     crlf

; write A to the sequencer CSR; prints "ww->"
seq_wr: sta     ADC_SEQD
        jsr     hex8
        lda     #'-'
        jsr     putc
        lda     #'>'
        jsr     putc
        lda     #C_SEQ_WR
        sta     ADC_CTRL
        nop
        nop
        stz     ADC_CTRL
        rts

; read the sequencer CSR; prints what SEQD holds afterwards
seq_rd: stz     ADC_SEQD                ; so a stale value can't pass as a read
        lda     #C_SEQ_RD
        sta     ADC_CTRL
        nop
        nop
        lda     ADC_SEQD
        jsr     hex8
        stz     ADC_CTRL
        rts

; wait for CTRL bit 7 (about 0.1 s); prints " CTRL=cc OK" or " CTRL=cc NO EOP"
; then prints the ISR. C=0 if EOP seen.
poll:   stz     CNT
        stz     CNT+1
pl_w:   lda     ADC_CTRL
        bmi     pl_ok
        inc     CNT
        bne     pl_w
        inc     CNT+1
        bne     pl_w
        pha
        PRINT   s_ctrl
        pla
        jsr     hex8
        PRINT   s_noeop
        jsr     pl_isr
        sec
        rts
pl_ok:  pha
        PRINT   s_ctrl
        pla
        jsr     hex8
        PRINT   s_eopok
        jsr     pl_isr
        lda     #$01                    ; clear EOP
        ldx     #$41
        jsr     st_wr
        clc
        rts
pl_isr: PRINT   s_isr
        lda     #$41
        jmp     st_rd

;---------------------------------------------------------------------------
; 5. datasheet autorun
;---------------------------------------------------------------------------
t_auto: PRINT   s_auto
        lda     #$01                    ; autorun also writes SAMD to SAMADDR:
        sta     ADC_SAMD0               ; make that the harmless ISR clear
        stz     ADC_SAMD1
        lda     #$41
        sta     ADC_SAMADDR
        lda     #$03
        sta     ADC_SEQD
        lda     #C_AUTORUN
        sta     ADC_CTRL
        jsr     poll
        stz     ADC_CTRL
        lda     #$01                    ; continuous for a moment, then stop
        sta     ADC_SEQD
        lda     #$41
        sta     ADC_SAMADDR
        lda     #C_AUTORUN
        sta     ADC_CTRL
        PRINT   s_cont
        jsr     poll
        stz     ADC_SEQD
        lda     #C_AUTORUN
        sta     ADC_CTRL
        stz     ADC_CTRL
        jmp     crlf

;---------------------------------------------------------------------------
; 6. slots 0-9, direct and strobed
;---------------------------------------------------------------------------
t_slots:
        PRINT   s_slots
        PRINT   s_direct
        ldx     #0
ts_d:   stx     ADC_SAMADDR             ; direct, as the datasheet example
        lda     ADC_SAMD1
        jsr     hex8
        lda     ADC_SAMD0
        jsr     hex8
        jsr     space
        inx
        cpx     #10
        bne     ts_d
        PRINT   s_strobe
        ldx     #0
ts_s:   txa
        jsr     st_rd                   ; with SAMP_RD (keeps X)
        jsr     space
        inx
        cpx     #10
        bne     ts_s
        jmp     crlf

;---------------------------------------------------------------------------
; console
;---------------------------------------------------------------------------
puts_k: stx     SPTR
        sty     SPTR+1
        ldy     #0
ps_lp:  lda     (SPTR),y
        beq     ps_d
        jsr     putc
        iny
        bne     ps_lp
ps_d:   rts

space:  lda     #' '
putc:   pha                             ; keeps A, X, Y
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

hex8:   pha                             ; keeps X, Y
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

;---------------------------------------------------------------------------
s_title:
        db      $0D,$0A,'MyMENSCH ADC probe',$0D,$0A,0
s_raw:  db      $0D,$0A,'1. $7FB0-$7FBF: ',0
s_rb:   db      $0D,$0A,'   write->read: ',0
s_st2:  db      $0D,$0A,'2. sample store via SAMP_RD',$0D,$0A,0
s_ier:  db      '   IER($40)=',0
s_isr:  db      '  ISR($41)=',0
s_ieron:
        db      $0D,$0A,'3. IER <- 1 with SAMP_WR',$0D,$0A,0
s_ctrl: db      '  CTRL=',0
s_seq:  db      $0D,$0A,'4. sequencer via SEQ_WR/SEQ_RD: ',0
s_noeop:
        db      ' NO EOP',0
s_eopok:
        db      ' EOP OK',0
s_auto: db      $0D,$0A,'5. autorun single:',0
s_cont: db      $0D,$0A,'   autorun continuous:',0
s_slots:
        db      $0D,$0A,'6. slots 0-9 (slot 8 = temp, about 0E56 at 28 C)',0
s_direct:
        db      $0D,$0A,'   direct:  ',0
s_strobe:
        db      $0D,$0A,'   SAMP_RD: ',0
s_stop: db      $0D,$0A,'   stop: ',0
s_keys: db      $0D,$0A,'D = run again   ESC = restart',$0D,$0A,0

        ENDS
        END
