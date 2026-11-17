;***************************************************************************
;  FILE:   regmap.asm
;  TITLE:  MyMENSCH Rev-C (W65C165i1M08SA) I/O register map probe
;
;  probe.asm found the ACIAs working but no VIA_A timer, multiplier or
;  ADC. This shows what each block actually answers:
;    1. a hex dump of $7F00-$7FFF ($7F60, the console data register, skipped)
;    2. VIA_A, VIA_B, VIA_C: T1 latch and ACR write/read-back, T1 counting
;    3. both multipliers: all 8 registers after writing the operands
;    4. ADC: register read-back and one autorun sequence
;    5. Chip ID valid flag and ID
;    6. CPU speed from a software loop (needs no timer)
;
;  No port data direction registers are written, so no header pins change.
;
;  Load and run:
;    wdc_uploader_term.exe -d COM10 regmap.bin -m write -x -s 5 -t
;  Keys afterwards:  D = run again   ESC = restart the board
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_A_DATA     EQU     $7F60
ACIA_A_STAT     EQU     $7F61
MULU            EQU     $7FD0
MULS            EQU     $7FD8
ADC_SAMD0       EQU     $7FB0
ADC_SAMD1       EQU     $7FB1
ADC_SAMADDR     EQU     $7FB2
ADC_SEQD        EQU     $7FB3
ADC_CTRL        EQU     $7FB4
CHIPID          EQU     $7FC0
CHIPVALID       EQU     $7FC8
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1

; zero page
VB              EQU     $40             ; VIA base address (2)
T0              EQU     $42             ; first T1 reading (2)
CNT             EQU     $44             ; 3 bytes
NCH              EQU     $47             ; characters left (2)
SPTR            EQU     $49             ; string pointer (2)
PTR             EQU     $4B             ; dump pointer (2)

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
        jsr     dump
        jsr     via_all
        jsr     mul_test
        jsr     adc_test
        jsr     chip_id
        jsr     clock
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
; 1. $7F00-$7FFF, 16 bytes a line
;---------------------------------------------------------------------------
dump:   PRINT   s_dump
        stz     PTR
        lda     #$7F
        sta     PTR+1
dm_ln:  lda     #' '
        jsr     putc
        jsr     putc
        jsr     putc
        lda     #$7F
        jsr     hex8
        lda     PTR
        jsr     hex8
        lda     #':'
        jsr     putc
        ldy     #0
dm_b:   lda     #' '
        jsr     putc
        tya
        ora     PTR
        cmp     #$60                    ; ACIA_A data: reading it eats a key
        beq     dm_skip
        lda     (PTR),y
        jsr     hex8
        bra     dm_nx
dm_skip:
        lda     #'-'
        jsr     putc
        jsr     putc
dm_nx:  iny
        cpy     #16
        bne     dm_b
        jsr     crlf
        lda     PTR
        clc
        adc     #16
        sta     PTR
        bne     dm_ln
        rts

;---------------------------------------------------------------------------
; 2. VIAs
;---------------------------------------------------------------------------
via_all:
        PRINT   s_via
        lda     #$20
        ldx     #'A'
        jsr     via_test
        lda     #$30
        ldx     #'B'
        jsr     via_test
        lda     #$40
        ldx     #'C'
        jmp     via_test

; A = low byte of the VIA base, X = its letter
via_test:
        sta     VB
        lda     #$7F
        sta     VB+1
        phx
        PRINT   s_vname
        pla
        jsr     putc
        PRINT   s_latch                 ; T1 latch low (reg 6) is read/write
        ldy     #$0E
        lda     #$7F
        sta     (VB),y                  ; IER: all VIA interrupts off
        ldy     #6
        lda     #$5A
        sta     (VB),y
        lda     (VB),y
        jsr     hex8
        PRINT   s_latch2
        ldy     #6
        lda     #$A5
        sta     (VB),y
        lda     (VB),y
        jsr     hex8
        PRINT   s_acr
        ldy     #$0B
        lda     #$40                    ; T1 continuous, PB7 off
        sta     (VB),y
        lda     (VB),y
        jsr     hex8
        lda     #$FF                    ; latch $FFFF, then load and start
        ldy     #6
        sta     (VB),y
        iny
        sta     (VB),y
        ldy     #4
        sta     (VB),y
        iny
        sta     (VB),y
        jsr     rd_t1                   ; also clears the T1 flag
        sta     T0+1
        stx     T0
        ldx     #100                    ; ~500 cycles
vt_dl:  dex
        bne     vt_dl
        PRINT   s_t1
        lda     T0+1
        jsr     hex8
        lda     T0
        jsr     hex8
        lda     #' '
        jsr     putc
        jsr     rd_t1
        pha
        phx
        jsr     hex8                    ; hi
        pla
        pha
        jsr     hex8                    ; lo
        pla
        cmp     T0
        bne     vt_run
        pla
        cmp     T0+1
        bne     vt_run2
        PRINT   s_stop
        bra     vt_ifr
vt_run: pla
vt_run2:
        PRINT   s_count
vt_ifr: PRINT   s_ifr                   ; real VIA: $00 here
        ldy     #$0D
        lda     (VB),y
        jsr     hex8
        ldy     #$0B
        lda     #0
        sta     (VB),y                  ; ACR back to reset value
        jmp     crlf

; A = T1 high, X = T1 low
rd_t1:  ldy     #4
        lda     (VB),y
        tax
        iny
        lda     (VB),y
        rts

;---------------------------------------------------------------------------
; 3. Multipliers: print registers 0-7 after writing A and B
;---------------------------------------------------------------------------
mul_test:
        PRINT   s_mulu                  ; 300 * 400 = $0001D4C0
        lda     #<300
        sta     MULU
        lda     #>300
        sta     MULU+1
        lda     #<400
        sta     MULU+2
        lda     #>400
        sta     MULU+3
        ldx     #0
mt_u:   lda     MULU,x
        jsr     hex8
        lda     #' '
        jsr     putc
        inx
        cpx     #8
        bne     mt_u
        PRINT   s_want_u
        PRINT   s_muls                  ; -3 * 1234 = $FFFFF18A
        lda     #$FD
        sta     MULS
        lda     #$FF
        sta     MULS+1
        lda     #<1234
        sta     MULS+2
        lda     #>1234
        sta     MULS+3
        ldx     #0
mt_s:   lda     MULS,x
        jsr     hex8
        lda     #' '
        jsr     putc
        inx
        cpx     #8
        bne     mt_s
        PRINT   s_want_s
        rts

;---------------------------------------------------------------------------
; 4. ADC
;---------------------------------------------------------------------------
adc_test:
        PRINT   s_adc
        ldx     #0
at_r:   lda     ADC_SAMD0,x
        jsr     hex8
        lda     #' '
        jsr     putc
        inx
        cpx     #5
        bne     at_r
        PRINT   s_seq
        lda     #$03                    ; single cycle, run
        sta     ADC_SEQD
        lda     ADC_SEQD
        jsr     hex8
        PRINT   s_addr
        lda     #$05
        sta     ADC_SAMADDR
        lda     ADC_SAMADDR
        jsr     hex8
        PRINT   s_run
        lda     #$01                    ; autorun
        sta     ADC_CTRL
        stz     CNT
        stz     CNT+1
ad_w:   lda     ADC_CTRL
        bmi     ad_eop
        inc     CNT
        bne     ad_w
        inc     CNT+1
        bne     ad_w
        jsr     hex8                    ; last CTRL value
        PRINT   s_noeop
        bra     ad_x
ad_eop: jsr     hex8
        PRINT   s_eop                   ; temperature diode, slot 8
        lda     #$08
        sta     ADC_SAMADDR
        lda     ADC_SAMD1
        jsr     hex8
        lda     ADC_SAMD0
        jsr     hex8
        lda     #$01                    ; clear end-of-packet
        sta     ADC_SAMD0
        lda     #$41
        sta     ADC_SAMADDR
        lda     #$10
        sta     ADC_CTRL
        stz     ADC_CTRL
ad_x:   stz     ADC_SEQD
        jmp     crlf

;---------------------------------------------------------------------------
; 5. Chip ID
;---------------------------------------------------------------------------
chip_id:
        PRINT   s_cid
        lda     CHIPVALID
        jsr     hex8
        PRINT   s_cid2
        ldx     #7
ci_lp:  lda     CHIPID,x
        jsr     hex8
        dex
        bpl     ci_lp
        jmp     crlf

;---------------------------------------------------------------------------
; 6. CPU speed: count a 17-cycle polling loop while 1000 characters go out
;    at 115200 baud (86.806 ms). cycles = 17 * count + 26 * 1000
;---------------------------------------------------------------------------
clock:  PRINT   s_clk
        ldx     #4                      ; fill the transmitter first
ck_pr:  lda     ACIA_A_STAT
        and     #$10
        beq     ck_pr
        stz     ACIA_A_DATA
        dex
        bne     ck_pr
        stz     CNT
        stz     CNT+1
        stz     CNT+2
        lda     #<1000
        sta     NCH
        lda     #>1000
        sta     NCH+1
ck_lp:  inc     CNT                     ; 5
        bne     ck_st                   ; 3
        inc     CNT+1
        bne     ck_st
        inc     CNT+2
ck_st:  lda     ACIA_A_STAT             ; 4
        and     #$10                    ; 2
        beq     ck_lp                   ; 3
        stz     ACIA_A_DATA
        lda     NCH
        bne     ck_d
        dec     NCH+1
ck_d:   dec     NCH
        lda     NCH
        ora     NCH+1
        bne     ck_lp
        lda     CNT+2
        jsr     hex8
        lda     CNT+1
        jsr     hex8
        lda     CNT
        jsr     hex8
        jmp     crlf

;---------------------------------------------------------------------------
; Output helpers (A and Y preserved where noted)
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
        db      $0D,$0A,'MyMENSCH register map probe',$0D,$0A,0
s_dump: db      $0D,$0A,'1. I/O $7F00-$7FFF (-- = not read)',$0D,$0A,0
s_via:  db      $0D,$0A,'2. VIAs (a working VIA reads back 5A, A5, 40 and counts)',$0D,$0A,0
s_vname:
        db      '   VIA_',0
s_latch:
        db      '  latch 5A->',0
s_latch2:
        db      ' A5->',0
s_acr:  db      '  ACR 40->',0
s_t1:   db      '  T1 ',0
s_count:
        db      ' counting',0
s_stop: db      ' STOPPED',0
s_ifr:  db      '  IFR ',0
s_mulu: db      $0D,$0A,'3. Multipliers, registers 0-7',$0D,$0A,'   unsigned: ',0
s_want_u:
        db      $0D,$0A,'       want: 2C 01 90 01 C0 D4 01 00',$0D,$0A,0
s_muls: db      '   signed:   ',0
s_want_s:
        db      $0D,$0A,'       want: FD FF D2 04 8A F1 FF FF',$0D,$0A,0
s_adc:  db      $0D,$0A,'4. ADC',$0D,$0A,'   registers 0-4: ',0
s_seq:  db      $0D,$0A,'   SEQD 03->',0
s_addr: db      '  SAMADDR 05->',0
s_run:  db      $0D,$0A,'   autorun, CTRL = ',0
s_noeop:
        db      '  NO END-OF-PACKET',0
s_eop:  db      '  end-of-packet OK, temperature slot = ',0
s_cid:  db      $0D,$0A,'5. Chip ID valid ($7FC8, FF = valid): ',0
s_cid2: db      '   ID: ',0
s_clk:  db      $0D,$0A,'6. CPU speed loop count (hex): ',0
s_keys: db      $0D,$0A,'D = run again   ESC = restart',$0D,$0A,0

        ENDS
        END
