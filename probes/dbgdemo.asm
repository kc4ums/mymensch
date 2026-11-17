;***************************************************************************
;  FILE:   dbgdemo.asm
;  TITLE:  Demo of the dbg.inc helpers (dbg_regs, dbg_mem, dbg_list)
;
;  Load and run:
;    wdc_uploader_term.exe -d COM10 dbgdemo.bin -m write -x -s 5 -t
;  Keys afterwards:  D = run again   ESC = restart the board
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_A_DATA     EQU     $7F60
ACIA_A_STAT     EQU     $7F61
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1

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
run:
        lda     #$5A                    ; some known values
        ldx     #$03
        ldy     #$C4
        sec
        jsr     dbg_regs
        sta     $0300                   ; registers must survive the calls
        stx     $0301
        sty     $0302
        jsr     dbg_mem
        dw      $7FA0                   ; GPIO_E, ADC, multipliers
        db      $28
        jsr     dbg_list
        dw      $7FB4
        db      'ADC_CTRL',0
        dw      $7FB3
        db      'SEQD',0
        dw      $7F61
        db      'ACIA_A_STAT',0
        dw      $7F60
        db      'DATA',0
        dw      0
        jsr     dbg_regs                ; same A/X/Y, C still set
        sta     $0303
        stx     $0304
        sty     $0305

idle:   lda     ACIA_A_STAT
        and     #$08
        beq     idle
        lda     ACIA_A_DATA
        cmp     #$1B
        beq     reboot
        and     #$DF
        cmp     #'D'
        bne     idle
        bra     run
reboot: jmp     ($FFFC)

        INCLUDE '..\lib\dbg.inc'

        ENDS
        END
