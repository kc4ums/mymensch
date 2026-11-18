;***************************************************************************
;  FILE:   amtor.asm   (built through amtor_ram.asm or amtor_rom.asm)
;  TITLE:  Stand-alone AMTOR Mode B (FEC, SITOR-B) station, W65C134SXB
;
;  A teletype-style HF data station that needs no computer: a PS/2
;  keyboard to type on, a 20x4 character LCD to read, and the radio
;  interface board on the radio's 6-pin DATA port (Kenwood TS-480: pin 1
;  ANI, 2 GND, 3 PTT, 5 ANO, 6 SQC; same layout as the TM-V71A's).
;
;  On the air: AMTOR / SITOR mode B, CCIR 476 code (4 marks in every 7
;  bits), 100 baud, 170 Hz shift, mark 1785 Hz (bit 1), space 1615 Hz,
;  i.e. fldigi's SITOR-B mode with its centre at 1700 Hz, on USB.
;  Every character is sent twice, the repeat 5 slots (350 ms) later, and
;  the receiver uses whichever copy arrives with a valid 4-of-7 pattern.
;
;  Hardware (W65C134SXB headers, from WDC's board datasheet):
;    J4 Port 5   P50-P53 4-bit DAC -> radio data in (ANI)
;                P54 PTT, P55 SQC in (unused), P57 comparator (ANO audio)
;    J3 Port 4   P40-P43 LCD D4-D7, P44 LCD RS, P45 LCD E (LCD R/W to GND)
;                P46 PS/2 keyboard CLOCK (falling-edge interrupt NE46)
;                P47 left alone (the ROM monitor's serial DSR input)
;    J5 Port 6   P63 PS/2 keyboard DATA
;    Port 3      P30 heartbeat, P31 TX, P32 SYNC LEDs (the SXB's
;                chip-select LEDs); only bits 0-2 are ever changed, so the
;                flash bank lines P34/P35 are never touched
;
;  Keys:  type to queue text (shown on the bottom line until it is sent)
;         F1 start transmitting    F2 finish: send the rest, ID, back to RX
;         F3 CQ call (sends it and returns to RX)   F4 insert "DE <call>"
;         F5 clear the screen      Up/Down/PgUp/PgDn/Home/End scroll back
;         Esc stop transmitting now (in RX: clear the typed text)
;         F12 back to the monitor (RAM build only)
;
;  Timing: Timer 1 interrupts 9600 times a second while receiving (one
;  comparator sample each, demodulated in the interrupt) and 19200 times
;  a second while transmitting (one DAC sample each). PHI2 = 3.6864 MHz.
;  The keyboard's clock edges interrupt through NE46; the Timer 1
;  handler masks only itself and re-enables interrupts, so a keyboard
;  bit is never kept waiting behind a sample.
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

; ---- W65C134S on-chip I/O (page zero) ----
PD3             EQU     $03             ; Port 3 data (LEDs, flash bank lines)
IFR2            EQU     $08             ; bit 4 = Timer 1 (write 1 to clear)
IER2            EQU     $09
TCR2            EQU     $0B             ; bit 0 T1 on, bit 1 T1 counts CLK, bit 2 8-bit
T1LL            EQU     $0C
T1CH            EQU     $11             ; write: high latch, and reload T1
BCR             EQU     $1B             ; bit 1: edge interrupts on P44-P47
PD4             EQU     $1C
PD5             EQU     $1D
PDD4            EQU     $1E
PDD5            EQU     $1F
PD6             EQU     $20
PDD6            EQU     $21
IFR1            EQU     $2C             ; bit 2 = NE46 (write 1 to clear)
IER1            EQU     $2D
T1F             EQU     $10
NE46F           EQU     $04

; ROM monitor's RAM interrupt vectors ($FFF2 -> JMP (UIRQT1), $FFD4 -> JMP (UNE46))
UVEC            EQU     $40             ; $40-$4F: BRK NMI IRQ2 IRQ1 T2 T1 NE46 GEN
UIRQT1          EQU     $4A
UNE46           EQU     $4C
SPEED           EQU     $86             ; monitor: crystal code, 3 = 3.6864 MHz
MON_START       EQU     $F039

; ---- pins ----
PTT_BIT         EQU     $10             ; P54
RX_BIT          EQU     $80             ; P57
DAC_MID         EQU     $08
OUT5            EQU     $1F             ; P50-P54 outputs
LCD_RS          EQU     $10             ; P44
LCD_E           EQU     $20             ; P45
OUT4            EQU     $3F             ; P40-P45 outputs
KB_DATA         EQU     $08             ; P63
HB_LED          EQU     $01
TX_LED          EQU     $02
SY_LED          EQU     $04
LED_ON_LOW      EQU     1               ; the SXB's LEDs light on a 0 (checked)

; ---- timing (PHI2 = 3.6864 MHz; T1 period assumed = latch + 1) ----
T1_RX           EQU     384-1           ; 9600 samples/s
T1_TX           EQU     192-1           ; 19200 samples/s
INC_M           EQU     12186           ; 65536*1785/9600
INC_S           EQU     11025           ; 65536*1615/9600
TINC_M          EQU     6093            ; 65536*1785/19200
TINC_S          EQU     5513            ; 65536*1615/19200
BITINC2         EQU     1365            ; 65536/48: bit phase step per 2 samples
SPB_TX          EQU     192             ; DAC samples per bit
ERR_MAX         EQU     4               ; bad characters in a row = lost sync
KB_TMO          EQU     20              ; ticks without a clock edge = frame reset
TAIL_PAIRS      EQU     4               ; idle pairs after the last character

; ---- RAM ----
RING            EQU     $0300           ; 96 sample products (1 bit window)
BITQ            EQU     $0360           ; 64 demodulated bits
KBQ             EQU     $03A0           ; 16 scan codes
TXQ             EQU     $03B0           ; 16 codes to send
CHR              EQU     $0400           ; 64 rolling 7-bit codes, one per bit
SL              EQU     $0440           ; 16 character slots
PRN             EQU     $0450           ; 40: the two printer lines
SCR             EQU     $0480           ; 80: LCD shadow, 4 rows of 20
TYB             EQU     $0500           ; 256: type-ahead ring
VARS            EQU     $0600
PRODM           EQU     $0800           ; phase -> mark I/Q reference bits
PRODS           EQU     $0900           ; phase -> space I/Q reference bits
DT0             EQU     $0A00           ; (new<<4|old) -> change of sum 0..3
DT1             EQU     $0B00
DT2             EQU     $0C00
DT3             EQU     $0D00
ABST            EQU     $0E00           ; |n-48|, n = 0..96
VALID           EQU     $0E80           ; 1 if the code has four 1s
SHL4            EQU     $0F00           ; n<<4
HIST            EQU     $4000           ; 256 lines x 20: scroll-back
HIST_HI         EQU     $40

; ---- page zero ($B0-$FF; the ROM monitor uses $40-$A3) ----
PML             EQU     $B0             ; receive: mark phase
PMH             EQU     $B1
PSL             EQU     $B2             ; space phase
PSH             EQU     $B3
S0              EQU     $B4             ; ones in the window: mark I, mark Q,
S1              EQU     $B5             ;   space I, space Q
S2              EQU     $B6
S3              EQU     $B7
RIDX            EQU     $B8
BPL             EQU     $B9             ; bit phase, 65536 = one bit
BPH             EQU     $BA
LASTD           EQU     $BB
DVAL            EQU     $BC             ; mark - space
EM              EQU     $BD
ES              EQU     $BE
MPK             EQU     $BF             ; peaks for the tuning bars
SPK             EQU     $C0
BQW             EQU     $C1
IT0             EQU     $C2
IT1             EQU     $C3
TPHL            EQU     $C4             ; transmit: phase, increment
TPHH            EQU     $C5
TINCL           EQU     $C6
TINCH           EQU     $C7
TSMP            EQU     $C8             ; samples left in this bit
TBITS           EQU     $C9             ; bits left in this code
TCODE           EQU     $CA
OUTV            EQU     $CB             ; next DAC + PTT value
TQR             EQU     $CC
TQW             EQU     $CD
TXEMPTY         EQU     $CE             ; queue ran dry at least once
ISRMODE         EQU     $CF             ; 0 receive, 1 transmit, 2 idle
TICKL           EQU     $D0
KIDLE           EQU     $D1
T10C            EQU     $D2             ; ticks left in this 10 ms
T10R            EQU     $D3
TIME10          EQU     $D4             ; 10 ms count
KBITS           EQU     $D5             ; keyboard frame bit count
KSR             EQU     $D6
KTMP            EQU     $D7
KQW             EQU     $D8
LRS             EQU     $D9             ; LCD RS bit for lcd_nib
PTR             EQU     $DA             ; 2
PTR2            EQU     $DC             ; 2
TMP             EQU     $DE
TMP2            EQU     $DF
TMP3            EQU     $E0
REVM            EQU     $E1             ; $7F if mark/space reversed, else 0

; main-loop variables
BQR             EQU     VARS+$00
KQR             EQU     VARS+$01
SYNC            EQU     VARS+$02
SCNT            EQU     VARS+$03
SI              EQU     VARS+$04
PAR             EQU     VARS+$05        ; next slot: 0 = DX, 1 = RX
ERRS            EQU     VARS+$06
RSHIFT          EQU     VARS+$07
LASTCR          EQU     VARS+$08
PCOL            EQU     VARS+$09
VIEW            EQU     VARS+$0A        ; scroll-back lines, 0 = live
HHEAD           EQU     VARS+$0B
HN              EQU     VARS+$0C
DIRTY           EQU     VARS+$0D
TXST            EQU     VARS+$0E        ; 0 RX, 1 phasing, 2 text, 4 tail, 5 drain
PHCNT           EQU     VARS+$0F
DLY1            EQU     VARS+$10
DLY2            EQU     VARS+$11
TXSH            EQU     VARS+$12        ; 0 letters, 1 figures, 2 unknown
PENDN           EQU     VARS+$13
PEND0           EQU     VARS+$14
TYW             EQU     VARS+$15
TYR             EQU     VARS+$16
LPOS            EQU     VARS+$17
LROW            EQU     VARS+$18
LDIRTY          EQU     VARS+$19
LTICK           EQU     VARS+$1A
STIME           EQU     VARS+$1B
KFL             EQU     VARS+$1C        ; 1/2 shift, $40 E0, $80 F0
TAIL            EQU     VARS+$1D
ROLL            EQU     VARS+$1E
BN              EQU     VARS+$1F
HB              EQU     VARS+$20
ENDREQ          EQU     VARS+$21
TYD             EQU     VARS+$22
RCODE           EQU     VARS+$23
SAVEV           EQU     VARS+$24        ; 4: monitor's T1 and NE46 vectors

LEDON   MACRO   BITS
        lda     #BITS
        IF      LED_ON_LOW
        trb     PD3
        ELSE
        tsb     PD3
        ENDIF
        ENDM

LEDOFF  MACRO   BITS
        lda     #BITS
        IF      LED_ON_LOW
        tsb     PD3
        ELSE
        trb     PD3
        ENDIF
        ENDM

        CODE
        IF      ROMBUILD
        ORG     $8000
        db      'WDC',0                 ; the ROM jumps to $8004 at reset
        jmp     START
        ELSE
        ORG     $2000
        jmp     START                   ; run with JMP 00:2000
        ENDIF

;***************************************************************************
;  CONFIG
;***************************************************************************
cfg_call:   db  'KC4UMS',0,0,0,0        ; your call, 0-terminated (up to 9)
cfg_autoid: db  1                       ; F2 adds "DE <call>" at the end
cfg_rev:    db  0                       ; 1 = swap mark and space
cfg_phase:  db  16                      ; phasing pairs before text (16 = 2.2 s)

;***************************************************************************
;  START
;***************************************************************************
START:  sei
        cld
        IF      ROMBUILD
        lda     #KB_DATA                ; escape hatch: P63 (J5 pin 6) held
        trb     PDD6                    ; low at power-up = go to the WDC
        ldx     #0                      ; monitor instead (to re-flash)
st_dl:  dex
        bne     st_dl
        lda     PD6
        and     #KB_DATA
        bne     st_go
        jmp     $F057                   ; the ROM's NOEXTROM re-entry
st_go:
        ENDIF
        ldx     #$FF
        txs
        IF      ROMBUILD
        ldx     #0                      ; straight from reset: every RAM
st_v:   lda     #<irq_ignore            ; vector to a plain RTI
        sta     UVEC,x
        lda     #>irq_ignore
        sta     UVEC+1,x
        inx
        inx
        cpx     #$10
        bne     st_v
        stz     IER1
        stz     IER2
        lda     #$FF
        sta     IFR1
        sta     IFR2
        ELSE
        ldx     #3                      ; keep the monitor's, for F12
st_s:   lda     UIRQT1,x
        sta     SAVEV,x
        dex
        bpl     st_s
        ENDIF
        lda     #<t1_isr
        sta     UIRQT1
        lda     #>t1_isr
        sta     UIRQT1+1
        lda     #<ps2_isr
        sta     UNE46
        lda     #>ps2_isr
        sta     UNE46+1

        lda     #$02                    ; edge interrupts on P44-P47
        tsb     BCR
        stz     PD4
        lda     #OUT4
        sta     PDD4
        lda     #KB_DATA
        trb     PDD6
        lda     #DAC_MID
        sta     PD5
        lda     #OUT5
        sta     PDD5
        LEDOFF  HB_LED+TX_LED+SY_LED
        lda     #$06                    ; Timer 1: PHI2, 16 bit, on
        trb     TCR2
        lda     #$01
        tsb     TCR2

        ldx     #$E1-$B0                ; clear our page-zero and variables
st_z:   stz     $B0,x
        dex
        bpl     st_z
        ldx     #0
st_cl:  stz     VARS,x                  ; and the buffers at $0300-$04FF
        stz     RING,x
        stz     CHR,x
        inx
        bne     st_cl
        lda     cfg_rev
        beq     st_r
        lda     #$7F
        sta     REVM
st_r:   jsr     mk_tables
        jsr     lcd_init
        jsr     scr_init
        jsr     banner

        lda     #2
        sta     ISRMODE                 ; idle until go_rx
        lda     #<T1_RX
        sta     T1LL
        lda     #>T1_RX
        sta     T1CH
        lda     #96
        sta     T10R
        sta     T10C
        lda     #T1F
        sta     IFR2
        tsb     IER2
        lda     #NE46F
        sta     IFR1
        tsb     IER1
        jsr     go_rx                   ; enables interrupts

;***************************************************************************
;  MAIN LOOP
;***************************************************************************
main:   jsr     kb_poll
        jsr     rx_poll
        jsr     tx_poll
        lda     DIRTY
        beq     m_a
        stz     DIRTY
        jsr     render
m_a:    lda     TYD
        beq     m_b
        stz     TYD
        jsr     ty_render
m_b:    jsr     status
        jsr     lcd_poll
        bra     main

;***************************************************************************
;  INTERRUPTS
;***************************************************************************
irq_ignore:
        rti

; Timer 1: one sample. Masks its own interrupt and lets the keyboard in.
t1_isr: pha
        lda     #T1F
        sta     IFR2
        trb     IER2
        cli
        phx
        phy
        inc     TICKL
        inc     KIDLE
        dec     T10C
        bne     t1_a
        lda     T10R
        sta     T10C
        inc     TIME10
t1_a:   lda     ISRMODE
        beq     rx_isr
        cmp     #1
        bne     isr_x
        jmp     tx_isr

; ---- receive: 1-bit correlator, square-wave I/Q references ----
rx_isr: lda     PD5
        sta     IT0                     ; bit 7 = comparator
        clc
        lda     PML
        adc     #<INC_M
        sta     PML
        lda     PMH
        adc     #>INC_M
        sta     PMH
        tax
        clc
        lda     PSL
        adc     #<INC_S
        sta     PSL
        lda     PSH
        adc     #>INC_S
        sta     PSH
        tay
        lda     PRODM,x
        ora     PRODS,y
        bit     IT0
        bpl     rx_a
        eor     #$0F
rx_a:   sta     IT1                     ; 4 product bits for this sample
        tay
        ldx     RIDX
        lda     SHL4,y
        ora     RING,x                  ; (new << 4) | old
        tay
        lda     IT1
        sta     RING,x
        inx
        cpx     #96
        bcc     rx_b
        ldx     #0
rx_b:   stx     RIDX
        clc
        lda     S0
        adc     DT0,y
        sta     S0
        clc
        lda     S1
        adc     DT1,y
        sta     S1
        clc
        lda     S2
        adc     DT2,y
        sta     S2
        clc
        lda     S3
        adc     DT3,y
        sta     S3
        lda     TICKL                   ; the rest every other sample
        lsr     a
        bcc     rx_c
isr_x:  ply
        plx
        sei
        lda     #T1F
        tsb     IER2
        pla
        rti
rx_c:   ldx     S0                      ; mark: max + min/2 of |I|, |Q|
        lda     ABST,x
        sta     IT0
        ldx     S1
        lda     ABST,x
        cmp     IT0
        bcs     rx_d
        lsr     a
        adc     IT0
        bra     rx_e
rx_d:   sta     IT1
        lda     IT0
        lsr     a
        adc     IT1
rx_e:   sta     EM
        ldx     S2                      ; space
        lda     ABST,x
        sta     IT0
        ldx     S3
        lda     ABST,x
        cmp     IT0
        bcs     rx_f
        lsr     a
        adc     IT0
        bra     rx_g
rx_f:   sta     IT1
        lda     IT0
        lsr     a
        adc     IT1
rx_g:   sta     ES
        lda     EM
        sec
        sbc     ES
        sta     DVAL
        eor     LASTD
        bpl     rx_h                    ; no mark/space change
        lda     BPH                     ; change: pull it 1/8 toward mid-phase
        sec
        sbc     #128
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        cmp     #$80
        ror     a
        eor     #$FF
        sec
        adc     BPH
        sta     BPH
rx_h:   lda     DVAL
        sta     LASTD
        clc
        lda     BPL
        adc     #<BITINC2
        sta     BPL
        lda     BPH
        adc     #>BITINC2
        sta     BPH
        bcc     rx_out
        ldx     BQW                     ; bit centre: 1 = mark
        lda     DVAL
        asl     a
        lda     #0
        rol     a
        eor     #1
        sta     BITQ,x
        inx
        txa
        and     #63
        sta     BQW
        lda     EM
        cmp     MPK
        bcc     rx_i
        sta     MPK
rx_i:   lda     ES
        cmp     SPK
        bcc     rx_out
        sta     SPK
rx_out: jmp     isr_x

; ---- transmit: phase-continuous FSK from the 4-bit sine table ----
tx_isr: lda     OUTV
        sta     PD5
        clc
        lda     TPHL
        adc     TINCL
        sta     TPHL
        lda     TPHH
        adc     TINCH
        sta     TPHH
        lsr     a
        lsr     a
        tax
        lda     SINE,x
        ora     #PTT_BIT
        sta     OUTV
        dec     TSMP
        bne     tx_x
        lda     #SPB_TX
        sta     TSMP
        dec     TBITS
        bne     tx_sh
        ldx     TQR
        cpx     TQW
        bne     tx_ld
        lda     #1                      ; nothing queued: hold the tone
        sta     TBITS
        sta     TXEMPTY
        bra     tx_x
tx_ld:  lda     TXQ,x
        sta     TCODE
        inx
        txa
        and     #15
        sta     TQR
        lda     #7
        sta     TBITS
        bra     tx_f
tx_sh:  lsr     TCODE
tx_f:   lda     TCODE
        lsr     a
        bcc     tx_s
        lda     #<TINC_M
        sta     TINCL
        lda     #>TINC_M
        sta     TINCH
        bra     tx_x
tx_s:   lda     #<TINC_S
        sta     TINCL
        lda     #>TINC_S
        sta     TINCH
tx_x:   jmp     isr_x

; PS/2 keyboard: one bit per falling clock edge on P46, data on P63.
ps2_isr:
        pha
        lda     #NE46F
        sta     IFR1
        stz     KIDLE
        lda     PD6
        and     #KB_DATA
        cmp     #1                      ; C = data bit
        ror     KTMP
        lda     KBITS
        beq     ps_st
        cmp     #9
        bcs     ps_end
        asl     KTMP
        ror     KSR                     ; data bits arrive LSB first
        inc     KBITS
        pla
        rti
ps_st:  bit     KTMP                    ; start bit must be 0
        bmi     ps_x
        inc     KBITS
ps_x:   pla
        rti
ps_end: cmp     #10
        bcs     ps_stop
        inc     KBITS                   ; parity bit, not checked
        pla
        rti
ps_stop:
        stz     KBITS
        phx
        ldx     KQW
        lda     KSR
        sta     KBQ,x
        inx
        txa
        and     #15
        sta     KQW
        plx
        pla
        rti

;***************************************************************************
;  RADIO: switch between receive and transmit
;***************************************************************************
go_rx:  sei
        lda     #2
        sta     ISRMODE
        lda     #DAC_MID                ; unkey
        sta     PD5
        lda     #<T1_RX
        sta     T1LL
        lda     #>T1_RX
        sta     T1CH
        lda     #96
        sta     T10R
        sta     T10C
        cli
        ldx     #95
gr_a:   stz     RING,x
        dex
        bpl     gr_a
        stz     S0
        stz     S1
        stz     S2
        stz     S3
        stz     RIDX
        stz     BPL
        stz     BPH
        stz     LASTD
        lda     BQW
        sta     BQR
        stz     SYNC
        stz     ERRS
        stz     TXST
        stz     ENDREQ
        LEDOFF  TX_LED+SY_LED
        stz     ISRMODE                 ; receive
        rts

tx_on:  lda     ISRMODE
        beq     ton_a
        rts
ton_a:  lda     #2
        sta     ISRMODE
        lda     #1
        sta     TXST
        lda     cfg_phase
        sta     PHCNT
        lda     #C_ALPHA
        sta     DLY1
        sta     DLY2
        lda     #2
        sta     TXSH
        stz     PENDN
        stz     ENDREQ
        stz     TQR
        stz     TQW
        jsr     tx_fill
        sei
        lda     #<T1_TX
        sta     T1LL
        lda     #>T1_TX
        sta     T1CH
        lda     #SPB_TX
        sta     T10R
        sta     T10C
        stz     TPHL
        stz     TPHH
        lda     #<TINC_M
        sta     TINCL
        lda     #>TINC_M
        sta     TINCH
        lda     #1
        sta     TSMP
        sta     TBITS
        stz     TXEMPTY
        lda     #DAC_MID+PTT_BIT
        sta     OUTV
        sta     PD5
        lda     #1
        sta     ISRMODE
        cli
        LEDON   TX_LED
        LEDOFF  SY_LED
        stz     SYNC
        rts

; F2: send what is queued, the ID, then return to receive
tx_end: lda     ISRMODE
        cmp     #1
        bne     te_x
        lda     ENDREQ
        bne     te_x
        lda     cfg_autoid
        beq     te_a
        lda     #13
        jsr     ty_add
        jsr     add_de
        lda     #13
        jsr     ty_add
te_a:   lda     #1
        sta     ENDREQ
te_x:   rts

;***************************************************************************
;  TRANSMIT: keep the code queue full
;***************************************************************************
tx_poll:
        lda     ISRMODE
        cmp     #1
        bne     tpo_x
        lda     TXST
        cmp     #5
        bne     tx_fill
        lda     TXEMPTY                 ; draining: done when the last
        beq     tpo_x                   ; code has gone out
        lda     TQR
        cmp     TQW
        bne     tpo_x
        jmp     go_rx
tpo_x:  rts

tx_fill:
        lda     TXST
        cmp     #5
        beq     tpo_x
        lda     TQW
        sec
        sbc     TQR
        and     #15
        cmp     #8
        bcs     tpo_x
        jsr     tx_pair
        bra     tx_fill

; queue one DX/RX pair
tx_pair:
        lda     TXST
        cmp     #1
        bne     tp_a
        lda     #C_REP                  ; phasing: RQ / alpha
        ldx     #C_ALPHA
        jsr     txq_put2
        dec     PHCNT
        bne     tp_x
        lda     #2
        sta     TXST
tp_x:   rts
tp_a:   cmp     #4
        beq     tp_tail
        jsr     tx_code
        bcc     tp_idle
        sta     TMP                     ; DX = this code, RX = the code
        ldx     DLY2                    ; from two pairs ago
        lda     DLY1
        sta     DLY2
        lda     TMP
        sta     DLY1
        jmp     txq_put2
tp_idle:
        lda     ENDREQ
        beq     tp_i
        lda     #4
        sta     TXST
        lda     #TAIL_PAIRS
        sta     TAIL
tp_i:   ldx     DLY2                    ; nothing to send: RQ in DX
        lda     DLY1
        sta     DLY2
        lda     #C_ALPHA
        sta     DLY1
        lda     #C_REP
        jmp     txq_put2
tp_tail:
        jsr     tp_i
        dec     TAIL
        bne     tp_x
        lda     #5                      ; drain: wait for the queue to
        sta     TXST                    ; run dry after this
        stz     TXEMPTY
        rts

; A = DX code, X = RX code
txq_put2:
        eor     REVM
        jsr     txq_put
        txa
        eor     REVM
txq_put:
        ldy     TQW
        sta     TXQ,y
        iny
        tya
        and     #15
        sta     TQW
        rts

; next code for a DX slot: C = 1 and A = code, or C = 0 if nothing to send
tx_code:
        lda     PENDN
        beq     tc_a
        stz     PENDN
        lda     PEND0
        sec
        rts
tc_a:   ldx     TYR
        cpx     TYW
        bne     tc_b
        clc
        rts
tc_b:   lda     TYB,x
        inx
        stx     TYR
        inc     TYD
        pha
        jsr     prn_char                ; local copy, as it goes out
        pla
        cmp     #13
        bne     tc_c
        lda     #C_LF                   ; Enter = CR LF
        sta     PEND0
        inc     PENDN
        lda     #C_CR
        sec
        rts
tc_c:   sec
        sbc     #$20
        tax
        lda     A2C,x
        and     #$7F
        cmp     #C_SP                   ; space: either shift
        beq     tc_ok
        sta     TMP
        lda     A2C,x
        rol     a
        lda     #0
        rol     a                       ; 1 = needs figures
        cmp     TXSH
        beq     tc_d
        sta     TXSH
        lda     TMP
        sta     PEND0
        inc     PENDN
        lda     #C_LTRS
        ldx     TXSH
        beq     tc_ok
        lda     #C_FIGS
        bra     tc_ok
tc_d:   lda     TMP
tc_ok:  sec
        rts

;***************************************************************************
;  RECEIVE: bits -> characters
;***************************************************************************
rx_poll:
        lda     ISRMODE
        bne     rp_x
rp_a:   ldx     BQR
        cpx     BQW
        beq     rp_x
        ldy     BITQ,x
        inx
        txa
        and     #63
        sta     BQR
        tya
        ldx     REVM
        beq     rp_b
        eor     #1
rp_b:   jsr     rx_bit
        bra     rp_a
rp_x:   rts

rx_bit: lsr     a                       ; C = bit
        ror     ROLL                    ; newest bit into bit 7
        lda     ROLL
        lsr     a                       ; the last 7 bits, oldest in bit 0
        sta     RCODE
        inc     BN
        lda     BN
        and     #63
        tax
        lda     RCODE
        sta     CHR,x
        lda     SYNC
        bne     rb_a
        jmp     rx_hunt
rb_a:   dec     SCNT
        bne     rb_x
        lda     #7
        sta     SCNT
        lda     RCODE
        jmp     rx_slot
rb_x:   rts

; A = k: A = the code that ended k bits ago
ch_back:
        eor     #$FF
        sec
        adc     BN
        and     #63
        tax
        lda     CHR,x
        rts

; not in sync: look for phasing (RQ alpha RQ alpha) or for a character
; and its repeat 35 bits later, twice
rx_hunt:
        lda     RCODE
        cmp     #C_ALPHA
        bne     rh_d
        lda     #7
        jsr     ch_back
        cmp     #C_REP
        bne     rh_d
        lda     #14
        jsr     ch_back
        cmp     #C_ALPHA
        bne     rh_d
        lda     #21
        jsr     ch_back
        cmp     #C_REP
        beq     rh_lock
rh_d:   ldx     RCODE
        lda     VALID,x
        beq     rh_x
        lda     #35
        jsr     ch_back
        cmp     RCODE
        bne     rh_x
        lda     #14
        jsr     ch_back
        sta     TMP
        tax
        lda     VALID,x
        beq     rh_x
        lda     #49
        jsr     ch_back
        cmp     TMP
        bne     rh_x
        jsr     rh_lock                 ; and print this character
        lda     #35
        jsr     ch_back
        ldx     RCODE
        jmp     rx_pair
rh_x:   rts
; the slot that just ended is an RX slot; take the last 6 slots from CH
rh_lock:
        ldy     #5
        lda     #0
rl_a:   sta     TMP2
        jsr     ch_back
        sta     SL,y
        lda     TMP2
        clc
        adc     #7
        dey
        bpl     rl_a
        lda     #6
        sta     SI
        stz     PAR
        lda     #7
        sta     SCNT
        stz     ERRS
        stz     RSHIFT
        lda     #1
        sta     SYNC
        rts

; A = the code of a slot that just ended
rx_slot:
        sta     TMP
        ldx     SI
        sta     SL,x
        inx
        txa
        and     #15
        sta     SI
        lda     PAR
        eor     #1
        sta     PAR
        beq     rs_a                    ; it was an RX slot
        rts
rs_a:   lda     SI
        sec
        sbc     #6
        and     #15
        tax
        lda     SL,x                    ; its DX slot, 5 slots earlier
        ldx     TMP

; A = DX copy, X = RX copy of one character
rx_pair:
        cmp     #C_REP
        bne     rq_a
        stz     ERRS                    ; idle / phasing
        rts
rq_a:   tay
        lda     VALID,y
        bne     rq_ok
        lda     VALID,x
        beq     rq_bad
        txa
        tay
rq_ok:  stz     ERRS
        tya
        jmp     rx_code
rq_bad: inc     ERRS
        lda     ERRS
        cmp     #ERR_MAX
        bcc     rq_e
        stz     SYNC                    ; lost it
        rts
rq_e:   lda     #'_'
        jmp     prn_char

; A = a valid code
rx_code:
        cmp     #C_LTRS
        bne     rc_a
        stz     RSHIFT
        rts
rc_a:   cmp     #C_FIGS
        bne     rc_b
        lda     #1
        sta     RSHIFT
        rts
rc_b:   cmp     #C_CR
        bne     rc_c
        lda     #1
        sta     LASTCR
        lda     #13
        jmp     prn_char
rc_c:   cmp     #C_LF
        bne     rc_d
        lda     LASTCR
        stz     LASTCR
        bne     rc_x
        lda     #13
        jmp     prn_char
rc_d:   stz     LASTCR
        tax
        lda     RSHIFT
        bne     rc_f
        lda     C2L,x
        bra     rc_g
rc_f:   lda     C2F,x
rc_g:   beq     rc_x                    ; alpha, beta, RQ: nothing to print
        jmp     prn_char
rc_x:   rts

;***************************************************************************
;  KEYBOARD
;***************************************************************************
kb_poll:
        lda     KBITS                   ; a frame that stopped half way
        beq     kb_a
        lda     KIDLE
        cmp     #KB_TMO
        bcc     kb_a
        stz     KBITS
kb_a:   ldx     KQR
        cpx     KQW
        bne     kb_b
        rts
kb_b:   ldy     KBQ,x
        inx
        txa
        and     #15
        sta     KQR
        tya
        cmp     #$F0
        bne     kb_c
        lda     #$80                    ; the next code is a key release
        tsb     KFL
        rts
kb_c:   cmp     #$E0
        bne     kb_d
        lda     #$40
        tsb     KFL
        rts
kb_d:   cmp     #$12
        beq     kb_sh
        cmp     #$59
        beq     kb_sh
        bit     KFL
        bmi     kb_clr                  ; other key releases: nothing
        bvs     kb_ext
        cmp     #$80
        bcs     kb_clr
        tax
        lda     KFL
        and     #$03
        bne     kb_s
        lda     PS2N,x
        bra     kb_k
kb_s:   lda     PS2S,x
kb_k:   beq     kb_clr
        jsr     key
kb_clr: lda     #$C0
        trb     KFL
        rts
kb_sh:  bit     KFL                     ; E0 12: not a real shift
        bvs     kb_clr
        ldx     #$01
        cmp     #$12
        beq     kb_s1
        ldx     #$02
kb_s1:  txa
        bit     KFL
        bmi     kb_s2
        tsb     KFL
        bra     kb_clr
kb_s2:  trb     KFL
        bra     kb_clr
kb_ext: ldx     #EXTN-1
ke_a:   cmp     EXTC,x
        beq     ke_b
        dex
        bpl     ke_a
        bra     kb_clr
ke_b:   lda     EXTK,x
        jsr     key
        bra     kb_clr

; A = key
key:    cmp     #$80
        bcs     k_fn
        cmp     #27
        bne     k_a
        lda     ISRMODE
        cmp     #1
        bne     k_clr
        jmp     go_rx                   ; stop transmitting now
k_clr:  lda     TYR                     ; receiving: clear the typing
        sta     TYW
        inc     TYD
        rts
k_a:    cmp     #8
        bne     k_b
        lda     TYW                     ; backspace: unsent text only
        cmp     TYR
        beq     k_x
        dec     TYW
        inc     TYD
        rts
k_b:    cmp     #13
        bne     k_b2
        jmp     ty_add
k_b2:
        cmp     #'a'
        bcc     k_c
        cmp     #'z'+1
        bcs     k_x
        and     #$DF
k_c:    cmp     #' '
        bcc     k_x
        cmp     #$60
        bcs     k_x
        tax
        lda     A2C-$20,x               ; only what CCIR 476 can send
        beq     k_x
        txa
        jmp     ty_add
k_x:    rts
k_fn:   cmp     #K_F1
        bne     k_f2
        jmp     tx_on
k_f2:   cmp     #K_F2
        bne     k_f3
        jmp     tx_end
k_f3:   cmp     #K_F3
        bne     k_f4
        lda     ISRMODE
        bne     k_x
        lda     #<s_cq                  ; CQ CQ CQ DE call call call PSE K
        ldy     #>s_cq
        jsr     ty_str
        jsr     add_de
        lda     #' '
        jsr     ty_add
        jsr     add_call
        lda     #' '
        jsr     ty_add
        jsr     add_call
        lda     #<s_pse
        ldy     #>s_pse
        jsr     ty_str
        jsr     tx_on
        lda     #1
        sta     ENDREQ
        rts
k_f4:   cmp     #K_F4
        bne     k_f5
        lda     #' '
        jsr     ty_add
        jsr     add_de
        lda     #' '
        jmp     ty_add
k_f5:   cmp     #K_F5
        bne     k_up
        jmp     prn_clear
k_up:   cmp     #K_UP
        bne     k_dn
        lda     VIEW
        inc     a
        cmp     HN
        bcs     k_x2
        sta     VIEW
        inc     DIRTY
        rts
k_dn:   cmp     #K_DOWN
        bne     k_end
        lda     VIEW
        beq     k_x2
        dec     VIEW
        inc     DIRTY
        rts
k_x2:   rts
k_end:  cmp     #K_END
        bne     k_home
        stz     VIEW
        inc     DIRTY
        rts
k_home: cmp     #K_HOME
        bne     k_f12
        lda     HN
        beq     k_x2
        dec     a
        sta     VIEW
        inc     DIRTY
        rts
k_f12:
        IF      ROMBUILD
        rts
        ELSE
        cmp     #K_F12
        bne     k_x2
        jsr     go_rx                   ; back to the monitor
        sei
        lda     #T1F
        trb     IER2
        lda     #NE46F
        trb     IER1                    ; keyboard edges would power down
        sta     IFR1
        ldx     #3
k12_a:  lda     SAVEV,x
        sta     UIRQT1,x
        dex
        bpl     k12_a
        cli
        jmp     MON_START
        ENDIF

; type-ahead buffer
ty_add: ldx     TYW
        inx
        cpx     TYR
        beq     ta_x                    ; full
        dex
        sta     TYB,x
        inx
        stx     TYW
        inc     TYD
ta_x:   rts

; A/Y = 0-terminated string
ty_str: sta     PTR2
        sty     PTR2+1
        ldy     #0
ts_a:   lda     (PTR2),y
        beq     ts_x
        phy
        jsr     ty_add
        ply
        iny
        bra     ts_a
ts_x:   rts

add_de: lda     #'D'
        jsr     ty_add
        lda     #'E'
        jsr     ty_add
        lda     #' '
        jsr     ty_add
add_call:
        ldy     #0
ac_a:   lda     cfg_call,y
        beq     ac_x
        phy
        jsr     ty_add
        ply
        iny
        cpy     #9
        bne     ac_a
ac_x:   rts

s_cq:   db      'CQ CQ CQ ',0
s_pse:  db      13,'PSE K',13,0

;***************************************************************************
;  SCREEN: row 0 status, rows 1-2 printer, row 3 typing
;***************************************************************************
scr_init:
        ldx     #79
si_a:   lda     #' '
        sta     SCR,x
        cpx     #40
        bcs     si_b
        sta     PRN,x
si_b:   dex
        bpl     si_a
        lda     #$0F
        sta     LDIRTY
        inc     TYD
        rts

banner: ldx     #0
bn_a:   lda     s_ban,x
        beq     bn_b
        phx
        jsr     prn_char
        plx
        inx
        bra     bn_a
bn_b:   ldy     #0
bn_c:   lda     cfg_call,y
        beq     bn_d
        phy
        jsr     prn_char
        ply
        iny
        cpy     #9
        bne     bn_c
bn_d:   lda     #13
        jsr     prn_char
        IF      ROMBUILD
        ELSE
        lda     SPEED
        cmp     #3
        beq     bn_x
        ldx     #0
bn_e:   lda     s_clk,x
        beq     bn_x
        phx
        jsr     prn_char
        plx
        inx
        bra     bn_e
        ENDIF
bn_x:   rts
s_ban:  db      'AMTOR FEC ',0
        IF      ROMBUILD
        ELSE
s_clk:  db      'CLOCK NOT 3.6864MHZ',13,0
        ENDIF

; print A (13 = new line) on the printer
prn_char:
        cmp     #13
        beq     prn_nl
        ldx     PCOL
        sta     PRN+20,x
        inx
        stx     PCOL
        inc     DIRTY
        cpx     #20
        bcs     prn_nl
        rts
prn_nl: lda     HHEAD                   ; line 2 into the scroll-back
        jsr     hist_ptr
        ldy     #19
pn_a:   lda     PRN+20,y
        sta     (PTR),y
        lda     #' '
        sta     PRN+20,y
        dey
        bpl     pn_a
        inc     HHEAD
        lda     HN
        cmp     #255
        bcs     pn_b
        inc     HN
pn_b:   ldy     #19                     ; line 1 = that line
        lda     HHEAD
        dec     a
        jsr     hist_ptr
pn_c:   lda     (PTR),y
        sta     PRN,y
        dey
        bpl     pn_c
        stz     PCOL
        inc     DIRTY
        rts

prn_clear:
        ldx     #39
pc_a:   lda     #' '
        sta     PRN,x
        dex
        bpl     pc_a
        stz     PCOL
        stz     VIEW
        inc     DIRTY
        rts

; PTR = HIST + A * 20
hist_ptr:
        sta     PTR
        stz     PTR+1
        asl     PTR
        rol     PTR+1
        asl     PTR
        rol     PTR+1                   ; *4
        lda     PTR
        sta     TMP2
        lda     PTR+1
        sta     TMP3
        asl     PTR
        rol     PTR+1
        asl     PTR
        rol     PTR+1                   ; *16
        clc
        lda     PTR
        adc     TMP2
        sta     PTR
        lda     PTR+1
        adc     TMP3
        adc     #HIST_HI
        sta     PTR+1
        rts

; printer (or scroll-back) into rows 1-2
render: lda     VIEW
        bne     rd_h
        ldx     #39
rd_a:   lda     PRN,x
        sta     SCR+20,x
        dex
        bpl     rd_a
        bra     rd_x
rd_h:   lda     HHEAD                   ; row 1 = line HHEAD-1-VIEW
        clc
        sbc     VIEW
        jsr     hist_ptr
        ldy     #19
rd_b:   lda     (PTR),y
        sta     SCR+20,y
        dey
        bpl     rd_b
        lda     HHEAD                   ; row 2 = line HHEAD-VIEW
        sec
        sbc     VIEW
        jsr     hist_ptr
        ldy     #19
rd_c:   lda     (PTR),y
        sta     SCR+40,y
        dey
        bpl     rd_c
rd_x:   lda     #$06
        tsb     LDIRTY
        rts

; row 3: the text not sent yet (last 19 characters) and a cursor
ty_render:
        lda     TYW
        sec
        sbc     TYR
        cmp     #20
        bcc     tr_a
        lda     #19
tr_a:   sta     TMP                     ; characters to show
        lda     TYW
        sec
        sbc     TMP
        tax                             ; first one
        ldy     #0
tr_b:   cpy     TMP
        beq     tr_c
        lda     TYB,x
        cmp     #13
        bne     tr_d
        lda     #$7F                    ; Enter shows as an arrow
tr_d:   sta     SCR+60,y
        inx
        iny
        bra     tr_b
tr_c:   lda     #'_'
tr_e:   sta     SCR+60,y
        lda     #' '
        iny
        cpy     #20
        bcc     tr_e
        lda     #$08
        tsb     LDIRTY
        rts

; every 100 ms: status row, LEDs
status: lda     TIME10
        sec
        sbc     STIME
        cmp     #10
        bcs     st_a
        rts
st_a:   lda     TIME10
        sta     STIME
        inc     HB
        lda     HB
        and     #$04
        beq     st_b
        LEDON   HB_LED
        bra     st_c
st_b:   LEDOFF  HB_LED
st_c:   ldx     #0
        lda     ISRMODE
        cmp     #1
        beq     st_tx
        lda     #'R'                    ; "RX SYNC M####.S####."
        sta     SCR
        lda     #'X'
        sta     SCR+1
        lda     SYNC
        beq     st_d
        LEDON   SY_LED
        ldx     #4
        bra     st_e
st_d:   LEDOFF  SY_LED
st_e:   ldy     #0
st_f:   lda     s_sync,x
        sta     SCR+3,y
        inx
        iny
        cpy     #4
        bne     st_f
        lda     #'M'
        sta     SCR+8
        lda     MPK
        ldx     #9
        jsr     bar
        lda     #'S'
        sta     SCR+14
        lda     SPK
        ldx     #15
        jsr     bar
        stz     MPK
        stz     SPK
        jmp     su_v
st_tx:  lda     #'T'                    ; "TX SEND Q:123"
        sta     SCR
        lda     #'X'
        sta     SCR+1
        lda     TXST
        cmp     #1
        bne     st_g
        ldx     #8
st_g:   cmp     #2
        bne     st_h
        ldx     #12
        lda     ENDREQ
        beq     st_h
        ldx     #16
st_h:   cmp     #4
        bcc     st_i
        ldx     #16
st_i:   ldy     #0
st_j:   lda     s_sync,x
        sta     SCR+3,y
        inx
        iny
        cpy     #4
        bne     st_j
        ldx     #8
st_k:   lda     s_q,x
        sta     SCR+8-8,x
        inx
        cpx     #20
        bne     st_k
        lda     TYW                     ; characters still to send
        sec
        sbc     TYR
        ldx     #10
        jsr     dec3
su_v:   lda     #' '
        ldx     VIEW
        beq     st_w
        lda     #'^'                    ; looking at the scroll-back
st_w:   sta     SCR+7
        lda     #$01
        tsb     LDIRTY
        rts
s_sync: db      '----SYNCPHASSENDEND '
s_q:    db      '        Q:          '

; X = column, A = level 0-73: 4 characters of bar and a space
bar:    lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; 0-4
        sta     TMP
        ldy     #0
br_a:   lda     #'#'
        cpy     TMP
        bcc     br_b
        lda     #'.'
br_b:   sta     SCR,x
        inx
        iny
        cpy     #4
        bne     br_a
        lda     #' '
        sta     SCR,x
        rts

; A = 0-255 in three digits at SCR+X
dec3:   ldy     #'0'-1
d3_a:   iny
        sec
        sbc     #100
        bcs     d3_a
        adc     #100
        pha
        tya
        sta     SCR,x
        pla
        ldy     #'0'-1
d3_b:   iny
        sec
        sbc     #10
        bcs     d3_b
        adc     #10+'0'
        sta     SCR+2,x
        tya
        sta     SCR+1,x
        rts

;***************************************************************************
;  LCD (HD44780, 4-bit, write only)
;***************************************************************************
lcd_init:
        stz     LRS
        ldx     #250                    ; 50 ms after power-up
        jsr     dly
        ldx     #250
        jsr     dly
        lda     #$03
        jsr     lcd_nib
        ldx     #50
        jsr     dly
        lda     #$03
        jsr     lcd_nib
        ldx     #2
        jsr     dly
        lda     #$03
        jsr     lcd_nib
        ldx     #2
        jsr     dly
        lda     #$02                    ; 4-bit interface
        jsr     lcd_nib
        ldx     #2
        jsr     dly
        lda     #$28                    ; 4-bit, 2 (=4) lines, 5x8
        jsr     lcd_cw
        lda     #$08                    ; display off
        jsr     lcd_cw
        lda     #$01                    ; clear
        jsr     lcd_byte
        ldx     #30
        jsr     dly
        lda     #$06                    ; move right
        jsr     lcd_cw
        lda     #$0C                    ; display on, no cursor
lcd_cw: jsr     lcd_byte
        ldx     #2
        jmp     dly

; X * 100 us (interrupts off)
dly:    ldy     #73
dl_a:   dey
        bne     dl_a
        dex
        bne     dly
        rts

lcd_byte:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     lcd_nib
        pla
lcd_nib:
        and     #$0F
        ora     LRS
        sta     PD4
        ora     #LCD_E
        sta     PD4
        eor     #LCD_E
        sta     PD4
        rts

; one byte per Timer 1 tick (52 or 104 us apart), changed rows only
lcd_poll:
        lda     TICKL
        cmp     LTICK
        beq     lp_x
        sta     LTICK
        lda     LPOS
        bne     lp_r
        lda     LDIRTY
        beq     lp_x
        ldx     #0
lp_a:   lsr     a
        bcs     lp_b
        inx
        bra     lp_a
lp_b:   stx     LROW
        lda     rowbit,x
        trb     LDIRTY
        stz     LRS
        lda     rowadr,x
        jsr     lcd_byte
        lda     #1
        sta     LPOS
        rts
lp_r:   ldx     LROW
        clc
        adc     rowofs,x
        tax
        lda     SCR-1,x
        ldy     #LCD_RS
        sty     LRS
        jsr     lcd_byte
        inc     LPOS
        lda     LPOS
        cmp     #21
        bcc     lp_x
        stz     LPOS
lp_x:   rts
rowadr: db      $80,$C0,$94,$D4
rowofs: db      0,20,40,60
rowbit: db      1,2,4,8

;***************************************************************************
;  TABLES built at start-up
;***************************************************************************
mk_tables:
        ldx     #0                      ; reference bits from the phase:
mt_a:   txa                             ; I = bit 7, Q = bit 7 ^ bit 6
        stz     TMP
        asl     a
        rol     TMP
        asl     a
        lda     #0
        rol     a
        eor     TMP
        asl     a
        ora     TMP
        sta     PRODM,x
        asl     a
        asl     a
        sta     PRODS,x
        inx
        bne     mt_a
mt_d:   txa                             ; sum changes: bit k of new - old
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     TMP
        txa
        and     #$0F
        sta     TMP2
        lda     #0
        lsr     TMP2
        rol     a
        eor     #$FF
        lsr     TMP
        adc     #1
        sta     DT0,x
        lda     #0
        lsr     TMP2
        rol     a
        eor     #$FF
        lsr     TMP
        adc     #1
        sta     DT1,x
        lda     #0
        lsr     TMP2
        rol     a
        eor     #$FF
        lsr     TMP
        adc     #1
        sta     DT2,x
        lda     #0
        lsr     TMP2
        rol     a
        eor     #$FF
        lsr     TMP
        adc     #1
        sta     DT3,x
        inx
        bne     mt_d
        ldx     #0                      ; |n - 48|
ma_a:   txa
        sec
        sbc     #48
        bcs     ma_b
        eor     #$FF
        adc     #1
ma_b:   sta     ABST,x
        inx
        cpx     #97
        bne     ma_a
        ldx     #127                    ; four 1s?
mv_a:   stx     TMP
        ldy     #0
mv_b:   lsr     TMP
        bcc     mv_c
        iny
mv_c:   lda     TMP
        bne     mv_b
        lda     #0
        cpy     #4
        bne     mv_d
        lda     #1
mv_d:   sta     VALID,x
        dex
        bpl     mv_a
        ldx     #15
ms_a:   txa
        asl     a
        asl     a
        asl     a
        asl     a
        sta     SHL4,x
        dex
        bpl     ms_a
        rts

; 64-step sine, 4 bits
SINE:   db      8,9,10,10,11,12,12,13,14,14,14,15,15,15,15,15
        db      15,15,15,15,15,15,14,14,14,13,12,12,11,10,10,9
        db      8,7,6,6,5,4,4,3,2,2,2,1,1,1,1,1
        db      1,1,1,1,1,1,2,2,2,3,4,4,5,6,6,7

        include 'amtor_tables.inc'

        ENDS
        END
