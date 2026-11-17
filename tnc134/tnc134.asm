;***************************************************************************
;  FILE:   tnc134.asm
;  TITLE:  W65C134SXB software TNC - transmit side (1200 baud AFSK)
;
;  Port of ../tnc/tnc.asm (MyMENSCH) to WDC's W65C134SXB. The packet code
;  is the same; the hardware layer is the W65C134S's:
;
;    P50-P53   4-bit R-2R DAC -> PKD (TM-V71A data pin 1)
;    P54       PTT via 2N7000 -> PKS (data pin 3)
;    P55       SQC in (optional, data pin 6)
;    P57       comparator (RX audio)
;    (Port 5 is not used by the SXB's ROM monitor, which owns P44-P47
;    and Port 6 for its UART.)
;  LEDs: Port 3 bits 0-2, the SXB's chip-select LED lines (WDC's LEDCS03
;  example drives them through PD3). Change LED_* below if yours differ.
;
;  Edit the CONFIG block below, build with mk_tnc134.bat, then load
;  tnc134.hex (or .s28) with EasySXB (9600 baud) and start it with
;  JMP or JSR at 00:2000. ESC returns to the monitor prompt.
;
;  Keys:  B = send a beacon now      P = periodic beacon on/off
;         1 = 1200 Hz test tone      2 = 2200 Hz test tone  (any key stops)
;         S = status   ? = help   ESC = back to the monitor
;
;  How it works on the 134
;  - Console I/O goes through the ROM monitor (OUTCH $F00F, RD_CHAR $F006),
;    whose UART is interrupt driven, so interrupts stay on while idle.
;  - Timer 1 is free (the monitor only enables Timer 2's interrupt, for
;    its 1 s clock; the T1 vector defaults to RESET, so T1's interrupt
;    stays off). T1 counts PHI2 = FCLK = 3.6864 MHz on the SXB.
;  - While a packet or tone plays, interrupts are off and every sample
;    waits for the T1 flag (IFR2 bit 4, cleared by writing a 1), every
;    192 cycles: 19200 samples/s, 16 per bit.
;  - The monitor's zero page runs $40-$A3 (its serial buffers are at
;    $90-$A3); this program uses $B0-$D1. Code is at $2000 in the SXB's
;    SRAM, buffers at $0300 and $0800-$17FF.
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

; W65C134S on-chip I/O (page zero)
PD3             EQU     $03             ; Port 3 (LED lines on the SXB)
IFR2            EQU     $08             ; bit 4 = Timer 1 flag
IER2            EQU     $09
TCR2            EQU     $0B             ; bit 0 = T1 on, 1 = T1 counts CLK, 2 = 8-bit mode
T1LL            EQU     $0C
T1LH            EQU     $0D
T1CL            EQU     $10
T1CH            EQU     $11             ; write: high latch, and reload T1
PD5             EQU     $1D             ; Port 5 data
PDD5            EQU     $1F             ; Port 5 direction (1 = output)
T1F             EQU     $10             ; IFR2 / IER2 bit for Timer 1
SPEED           EQU     $86             ; monitor: crystal code, 3 = 3.6864 MHz

; ROM monitor entry points
RD_CHAR         EQU     $F006           ; A = key or 0
OUTCH           EQU     $F00F           ; send A
MON_START       EQU     $F039           ; back to the monitor prompt

PTT_BIT         EQU     $10             ; P54
SQC_BIT         EQU     $20             ; P55
HB_LED          EQU     $01             ; P30: heartbeat
TX_LED          EQU     $02             ; P31: radio keyed
RX_LED          EQU     $04             ; P32: channel busy (SQC or audio)
LEDS            EQU     PD3
RX_BIT          EQU     $80             ; P57, comparator output
RX_EDGES        EQU     16              ; edges in 10 ms that mean "audio"
RX_HANG         EQU     20              ; RX LED stays on 200 ms after
DAC_MID         EQU     $08
OUT_MASK        EQU     $1F             ; P50-P54 outputs

; RAM
FRAME           EQU     $0300           ; AX.25 frame before encoding (256)
TONES           EQU     $0800           ; one byte per bit, $0800-$17FF
TONES_END       EQU     $1800

; zero page ($B0-$D1; the ROM monitor uses $40-$A3)
PH              EQU     $B0             ; 2, phase accumulator
INCL            EQU     $B2             ; phase increment
INCH            EQU     $B3
SCNT            EQU     $B4             ; samples left in this bit
TP              EQU     $B5             ; 2, TONES pointer
TEND            EQU     $B7             ; 2, end of TONES data
TONE            EQU     $B9             ; current NRZI tone
ONES            EQU     $BA             ; 1s in a row, for bit stuffing
CRC             EQU     $BB             ; 2
CRCON           EQU     $BD
CURB            EQU     $BE
BCNT            EQU     $BF
BITV            EQU     $C0
OVF             EQU     $C1             ; TONES overflowed
FLEN            EQU     $C2             ; frame length
MODE            EQU     $C3             ; 0 = frame, 1 = test tone
REP             EQU     $C4             ; test tone repeats left
PTR             EQU     $C5             ; 2
TICK            EQU     $C7             ; 10 ms ticks
SECS            EQU     $C8
NEXTM           EQU     $C9             ; minutes to the next beacon
PERIOD          EQU     $CA             ; periodic beacon on
TMP             EQU     $CB
LASTRX          EQU     $CC             ; last P57 level
EDGES           EQU     $CD             ; P57 changes in this tick
SPTR            EQU     $CE             ; 2
RXHANG          EQU     $D0             ; ticks the RX LED stays on
OUTV            EQU     $D1             ; next DAC + PTT value

; Timer 1 periods at PHI2 = 3.6864 MHz. The 134 reloads T1 from its latch
; when it times out; taken here as period = latch + 1. If test tone 1 reads
; 1206 Hz instead of 1200, use 192-2 / 36864-2 (period = latch + 2).
T1_SAMPLE       EQU     192-1           ; 19200 samples/s
T1_TICK         EQU     36864-1         ; 100 ticks/s

PRINT   MACRO   STR
        ldx     #<STR
        ldy     #>STR
        jsr     puts
        ENDM

        CODE
        ORG     $2000
        jmp     START                   ; run with JMP/JSR 00:2000

        ds      $2010-*
;***************************************************************************
;  CONFIG  (fixed at $2010 so it can also be patched from the monitor)
;***************************************************************************
cfg_ok:   db    1               ; set to 1 once call and position are right
cfg_call: db    'KC4UMS',2      ; your call: 6 chars, pad with spaces; SSID
cfg_dest: db    'APZ65C',0      ; destination (APZ = experimental software)
cfg_path: db    'WIDE1 ',1      ; digipeater path, up to 2 entries
          db    'WIDE2 ',1
cfg_npath: db   2               ; 0, 1 or 2 path entries used
cfg_lat:  db    '0000.00N'      ; ddmm.hhN  (latitude)
cfg_symt: db    '/'             ; symbol table
cfg_lon:  db    '00000.00W'     ; dddmm.hhW (longitude)
cfg_symc: db    '-'             ; symbol code: '-' house, '>' car
cfg_bmin: db    1              ; periodic beacon interval, minutes
cfg_txd:  db    45              ; TXDELAY in flags (45 = 300 ms)
cfg_sqc:  db    0               ; 0 = ignore SQC, 1 = busy when high,
                                ; 2 = busy when low
cfg_cmt:  db    'W65C134SXB software TNC',0       ; comment, max 40 chars

        ds      $2100-*
; 64-step sine, 4 bits, page aligned so lda sine,x never adds a cycle
sine:   db      8,9,10,10,11,12,12,13,14,14,14,15,15,15,15,15
        db      15,15,15,15,15,15,14,14,14,13,12,12,11,10,10,9
        db      8,7,6,6,5,4,4,3,2,2,2,1,1,1,1,1
        db      1,1,1,1,1,1,2,2,2,3,4,4,5,6,6,7
; phase increments: 65536 * f / 19200
inc_lo: db      <4096,<7509             ; mark 1200 Hz, space 2200 Hz
inc_hi: db      >4096,>7509

;---------------------------------------------------------------------------
START:
        sei
        cld
        ldx     #$FF
        txs
        lda     #HB_LED+TX_LED+RX_LED
        trb     LEDS
        lda     #T1F
        trb     IER2                    ; no Timer 1 interrupt (polled)
        lda     #$06
        trb     TCR2                    ; T1 counts PHI2, 16-bit mode
        lda     #$01
        tsb     TCR2                    ; T1 clock on
        jsr     radio_idle              ; also starts the 10 ms tick
        lda     PDD5
        and     #$FF-OUT_MASK           ; P55-P57 inputs
        ora     #OUT_MASK               ; P50-P54 outputs
        sta     PDD5
        cli                             ; the monitor's UART runs on interrupts
        stz     TICK
        stz     SECS
        stz     EDGES
        stz     RXHANG
        lda     #1                      ; first beacon a minute after start
        sta     NEXTM
        stz     PERIOD
        lda     cfg_ok
        beq     st_nc
        lda     cfg_bmin
        beq     st_nc
        lda     #1
        sta     PERIOD
st_nc:  PRINT   s_banner
        lda     SPEED                   ; the monitor measured the crystal
        cmp     #3
        beq     st_clk
        PRINT   s_clk                   ; not 3.6864 MHz: tones will be off
st_clk: lda     cfg_ok
        bne     main
        PRINT   s_nocfg

main:   jsr     tick_wait
        inc     TICK
        lda     TICK
        cmp     #100
        bne     mn_hb
        stz     TICK
        jsr     second
mn_hb:  jsr     heartbeat
        jsr     rx_led
mn_key: jsr     RD_CHAR                 ; 0 = no key
        cmp     #0
        beq     main
        cmp     #$1B
        bne     mn_cmd
        PRINT   s_bye
        jsr     radio_idle
        jmp     MON_START
mn_cmd: cmp     #'a'
        bcc     mn_up
        and     #$DF
mn_up:  ldx     #0
mn_lp:  cmp     key_chr,x
        beq     mn_go
        inx
        cpx     #NKEY
        bne     mn_lp
        bra     main
mn_go:  txa
        asl     a
        tax
        jsr     mn_jmp
        bra     main
mn_jmp: jmp     (key_tbl,x)

key_chr:
        db      'B12PS?'
NKEY    EQU     6
key_tbl:
        dw      k_beacon, k_tone1, k_tone2, k_period, k_status, k_help

k_help: PRINT   s_help
        rts

; once a second: periodic beacon
second: inc     SECS
        lda     SECS
        cmp     #60
        bne     sc_x
        stz     SECS
        lda     PERIOD
        beq     sc_x
        dec     NEXTM
        bne     sc_x
        lda     cfg_bmin
        sta     NEXTM
        jmp     beacon
sc_x:   rts

; heartbeat LED, "lub-dub" once a second: on for ticks 0-7 and 15-22
heartbeat:
        lda     TICK
        cmp     #8
        bcc     hb_on
        cmp     #15
        bcc     hb_off
        cmp     #23
        bcc     hb_on
hb_off: lda     #HB_LED
        trb     LEDS
        rts
hb_on:  lda     #HB_LED
        tsb     LEDS
        rts

; RX LED: on while the channel is busy, held RX_HANG ticks after
rx_led: lda     cfg_sqc
        beq     rl_aud
        jsr     sqc_busy
        bne     rl_busy
        bra     rl_quiet
rl_aud: lda     EDGES                   ; audio on P57 this tick?
        cmp     #RX_EDGES
        bcs     rl_busy
rl_quiet:
        lda     RXHANG
        beq     rl_off
        dec     RXHANG
        rts
rl_busy:
        lda     #RX_HANG
        sta     RXHANG
        lda     #RX_LED
        tsb     LEDS
        rts
rl_off: lda     #RX_LED
        trb     LEDS
        rts

; A <> 0 (Z=0) if SQC says the channel is busy (cfg_sqc must be 1 or 2)
sqc_busy:
        lda     PD5
        and     #SQC_BIT
        ldx     cfg_sqc
        cpx     #1
        beq     sb_x
        eor     #SQC_BIT                ; busy when low: invert
sb_x:   cmp     #0
        rts

; wait for the next 10 ms Timer 1 tick, counting P57 edges into EDGES
tick_wait:
        stz     EDGES
tw_lp:  lda     PD5
        and     #RX_BIT
        cmp     LASTRX
        beq     tw_s
        sta     LASTRX
        inc     EDGES
        bne     tw_s
        dec     EDGES                   ; stop at 255
tw_s:   lda     #T1F
        bit     IFR2                    ; Z = 0 when the T1 flag is up
        beq     tw_lp
        sta     IFR2                    ; write 1: clear it
        rts

k_period:
        lda     cfg_ok
        bne     kp_ok
        PRINT   s_nocfg
        rts
kp_ok:  lda     PERIOD
        eor     #1
        sta     PERIOD
        lda     cfg_bmin
        sta     NEXTM
        jmp     k_status

k_status:
        PRINT   s_st1
        lda     PERIOD
        beq     ks_off
        PRINT   s_on
        lda     cfg_bmin
        jsr     pdec
        PRINT   s_min
        lda     NEXTM
        jsr     pdec
        PRINT   s_min2
        rts
ks_off: PRINT   s_off
        rts

k_beacon:
        lda     cfg_ok
        bne     beacon
        PRINT   s_nocfg
        rts

;---------------------------------------------------------------------------
; build, encode and send the position beacon
;---------------------------------------------------------------------------
beacon: jsr     build_frame
        jsr     encode
        lda     OVF
        beq     bc_ok
        PRINT   s_ovf
        rts
bc_ok:  jsr     wait_clear
        bcc     bc_go
        PRINT   s_busy
        rts
bc_go:  PRINT   s_tx
        jsr     show_frame
        stz     MODE
        jsr     transmit
        PRINT   s_done
        rts

; C=1 if the channel stayed busy for ~10 s (only with cfg_sqc set)
wait_clear:
        lda     cfg_sqc
        beq     wc_ok
        lda     #0
        sta     TMP                     ; 256 x 40 ms
wc_lp:  jsr     sqc_busy
        beq     wc_ok                   ; not busy
        jsr     tick_wait
        jsr     tick_wait
        jsr     tick_wait
        jsr     tick_wait
        dec     TMP
        bne     wc_lp
        sec
        rts
wc_ok:  clc
        rts

;---------------------------------------------------------------------------
; frame: dest, source, path, control, PID, info
;---------------------------------------------------------------------------
build_frame:
        stz     FLEN
        lda     #<cfg_dest
        ldx     #>cfg_dest
        ldy     #$80                    ; C bit: command frame
        jsr     add_addr
        lda     #<cfg_call
        ldx     #>cfg_call
        ldy     #0
        jsr     add_addr
        lda     cfg_npath
        beq     bf_end
        lda     #<cfg_path
        ldx     #>cfg_path
        ldy     #0
        jsr     add_addr
        lda     cfg_npath
        cmp     #2
        bcc     bf_end
        lda     #<(cfg_path+7)
        ldx     #>(cfg_path+7)
        ldy     #0
        jsr     add_addr
bf_end: ldx     FLEN                    ; last address: extension bit
        lda     FRAME-1,x
        ora     #$01
        sta     FRAME-1,x
        lda     #$03                    ; UI
        jsr     add_byte
        lda     #$F0                    ; no layer 3
        jsr     add_byte
        lda     #'!'                    ; position, no messaging
        jsr     add_byte
        ldx     #0
bf_la:  lda     cfg_lat,x
        jsr     add_byte
        inx
        cpx     #8
        bne     bf_la
        lda     cfg_symt
        jsr     add_byte
        ldx     #0
bf_lo:  lda     cfg_lon,x
        jsr     add_byte
        inx
        cpx     #9
        bne     bf_lo
        lda     cfg_symc
        jsr     add_byte
        ldx     #0
bf_cm:  lda     cfg_cmt,x
        beq     bf_x
        jsr     add_byte
        inx
        cpx     #40
        bne     bf_cm
bf_x:   rts

; 7-byte entry at X:A (6 chars + SSID) -> shifted AX.25 address; Y = C bit
add_addr:
        sta     PTR
        stx     PTR+1
        sty     TMP
        ldy     #0
aa_lp:  lda     (PTR),y
        asl     a
        jsr     add_byte
        iny
        cpy     #6
        bne     aa_lp
        lda     (PTR),y                 ; SSID
        and     #$0F
        asl     a
        ora     #$60                    ; reserved bits
        ora     TMP
        jmp     add_byte

add_byte:
        phx
        ldx     FLEN
        sta     FRAME,x
        inc     FLEN
        plx
        rts

;---------------------------------------------------------------------------
; encode FRAME into TONES: flags, frame + FCS (stuffed), tail flags
;---------------------------------------------------------------------------
encode: lda     #<TONES
        sta     TP
        lda     #>TONES
        sta     TP+1
        stz     TONE
        stz     ONES
        stz     OVF
        stz     CRCON
        ldx     cfg_txd
en_f:   phx
        jsr     flag
        plx
        dex
        bne     en_f
        lda     #$FF
        sta     CRC
        sta     CRC+1
        lda     #1
        sta     CRCON
        ldx     #0
en_b:   phx
        lda     FRAME,x
        jsr     data_byte
        plx
        inx
        cpx     FLEN
        bne     en_b
        stz     CRCON
        lda     CRC                     ; FCS = ~CRC, low byte first
        eor     #$FF
        pha
        lda     CRC+1
        eor     #$FF
        sta     TMP
        pla
        jsr     data_byte
        lda     TMP
        jsr     data_byte
        jsr     flag
        jsr     flag
        jsr     flag
        lda     TP
        sta     TEND
        lda     TP+1
        sta     TEND+1
        rts

; one flag ($7E), no stuffing
flag:   lda     #$7E
        sta     CURB
        lda     #8
        sta     BCNT
fl_lp:  lda     CURB
        and     #1
        lsr     CURB
        jsr     nrzi
        dec     BCNT
        bne     fl_lp
        stz     ONES
        rts

; A = data byte, LSB first, with CRC (if CRCON) and bit stuffing
data_byte:
        sta     CURB
        lda     #8
        sta     BCNT
db_lp:  lda     CURB
        and     #1
        sta     BITV
        lsr     CURB
        lda     CRCON
        beq     db_nc
        lda     BITV
        jsr     crc_bit
db_nc:  lda     BITV
        jsr     nrzi
        lda     BITV
        beq     db_z
        inc     ONES
        lda     ONES
        cmp     #5
        bne     db_nx
        lda     #0                      ; stuffed 0
        jsr     nrzi
db_z:   stz     ONES
db_nx:  dec     BCNT
        bne     db_lp
        rts

; CRC-16/X.25, one bit (A = 0 or 1)
crc_bit:
        eor     CRC
        and     #1
        tay
        lsr     CRC+1
        ror     CRC
        cpy     #0
        beq     cb_x
        lda     CRC
        eor     #$08
        sta     CRC
        lda     CRC+1
        eor     #$84
        sta     CRC+1
cb_x:   rts

; NRZI: a 0 bit changes the tone, a 1 keeps it. Stores the tone.
nrzi:   cmp     #0
        bne     nz_put
        lda     TONE
        eor     #1
        sta     TONE
nz_put: lda     TP+1
        cmp     #>TONES_END
        bcc     nz_ok
        lda     #1
        sta     OVF
        rts
nz_ok:  lda     TONE
        sta     (TP)
        inc     TP
        bne     nz_x
        inc     TP+1
nz_x:   rts

;---------------------------------------------------------------------------
; play TONES[TP_start .. TEND). MODE 1 repeats the buffer REP times.
;---------------------------------------------------------------------------
transmit:
        lda     #TX_LED
        tsb     LEDS              ; TX LED on while keyed
        stz     PH
        stz     PH+1
        lda     #DAC_MID+PTT_BIT        ; first sample: mid-scale, keyed
        sta     OUTV
        sei                             ; nothing may steal cycles now
        lda     #<T1_SAMPLE             ; Timer 1: one flag per sample
        sta     T1LL
        lda     #>T1_SAMPLE
        sta     T1LH
        sta     T1CH                    ; reload and restart
        lda     #T1F
        sta     IFR2
tx_restart:
        lda     #<TONES
        sta     TP
        lda     #>TONES
        sta     TP+1
        lda     #16
        sta     SCNT
        lda     (TP)
        tax
        lda     inc_lo,x
        sta     INCL
        lda     inc_hi,x
        sta     INCH

; One sample per Timer 1 flag (192 cycles). The DAC is written right after
; the flag, so the rate is exact; the work after it takes at most ~120 cycles.
tx_smp: lda     #T1F                    ; 2
tx_w:   bit     IFR2                    ; 3   Z = 0 when the flag is up
        beq     tx_w                    ; 2/3
        lda     OUTV                    ; 3
        sta     PD5                     ; 3   DAC + PTT
        lda     #T1F                    ; 2
        sta     IFR2                    ; 3   write 1: clear the flag
        clc                             ;     next sample
        lda     PH
        adc     INCL
        sta     PH
        lda     PH+1
        adc     INCH
        sta     PH+1
        lsr     a
        lsr     a                       ;     top 6 bits
        tax
        lda     sine,x
        ora     #PTT_BIT
        sta     OUTV
        dec     SCNT
        bne     tx_smp

        lda     #16                     ; next bit
        sta     SCNT
        inc     TP
        bne     tx_b1
        inc     TP+1
tx_b1:  lda     TP
        cmp     TEND
        lda     TP+1
        sbc     TEND+1
        bcs     tx_end
        lda     (TP)
        tax
        lda     inc_lo,x
        sta     INCL
        lda     inc_hi,x
        sta     INCH
        bra     tx_smp

tx_end: lda     MODE
        beq     tx_off
        cli                             ; test tone: let the UART interrupt in,
        jsr     RD_CHAR                 ; then stop on a key
        sei
        cmp     #0
        bne     tx_off
        dec     REP
        beq     tx_off
        jmp     tx_restart
tx_off: lda     #T1F                    ; let the last sample play out
tx_ow:  bit     IFR2
        beq     tx_ow
        jsr     radio_idle
        lda     #TX_LED
        trb     LEDS
        cli
        rts

radio_idle:
        lda     #DAC_MID                ; PTT off, DAC mid-scale
        sta     PD5
        lda     #<T1_TICK               ; Timer 1 back to the 10 ms tick
        sta     T1LL
        lda     #>T1_TICK
        sta     T1LH
        sta     T1CH
        lda     #T1F
        sta     IFR2
        rts

;---------------------------------------------------------------------------
; test tones: 1200 (key 1) or 2200 Hz (key 2), about 30 s or until a key
;---------------------------------------------------------------------------
k_tone1:
        lda     #0
        bra     tone
k_tone2:
        lda     #1
tone:   ldx     #0                      ; 256 bits of one tone (0.21 s)
tn_f:   sta     TONES,x
        dex
        bne     tn_f
        lda     #<(TONES+256)
        sta     TEND
        lda     #>(TONES+256)
        sta     TEND+1
        lda     #140                    ; 140 x 0.213 s = 30 s
        sta     REP
        lda     #1
        sta     MODE
        PRINT   s_tone
        jsr     transmit
        PRINT   s_done
        rts

;---------------------------------------------------------------------------
; print FRAME as SRC>DEST,PATH:info
;---------------------------------------------------------------------------
show_frame:
        ldx     #7                      ; source
        jsr     pr_addr
        lda     #'>'
        jsr     putc
        ldx     #0                      ; destination
        jsr     pr_addr
        ldx     #14                     ; path entries until the extension bit
sf_p:   lda     FRAME-1,x
        and     #$01
        bne     sf_i
        lda     #','
        jsr     putc
        jsr     pr_addr
        txa
        clc
        adc     #7
        tax
        bra     sf_p
sf_i:   lda     #':'
        jsr     putc
        inx                             ; skip control and PID
        inx
sf_c:   cpx     FLEN
        beq     sf_x
        lda     FRAME,x
        jsr     putc
        inx
        bra     sf_c
sf_x:   jmp     crlf

; print the address at FRAME+X (X kept)
pr_addr:
        phx
        ldy     #6
pa_lp:  lda     FRAME,x
        lsr     a
        cmp     #' '
        beq     pa_sp
        jsr     putc
pa_sp:  inx
        dey
        bne     pa_lp
        lda     FRAME,x                 ; SSID
        lsr     a
        and     #$0F
        beq     pa_x
        pha
        lda     #'-'
        jsr     putc
        pla
        jsr     pdec
pa_x:   plx
        rts

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
        inc     SPTR+1
        bra     ps_lp
ps_d:   rts

; send A through the ROM monitor; keeps A, X, Y
putc:   pha
        phx
        phy
        jsr     OUTCH
        ply
        plx
        pla
        rts

crlf:   lda     #$0D
        jsr     putc
        lda     #$0A
        jmp     putc

; A in decimal (0-255), keeps X and Y
pdec:   phx
        phy
        ldy     #0                      ; leading digits printed?
        ldx     #100
        jsr     pd_dig
        ldx     #10
        jsr     pd_dig
        ora     #'0'
        jsr     putc
        ply
        plx
        rts
pd_dig: stx     TMP
        ldx     #0
pd_lp:  cmp     TMP
        bcc     pd_out
        sbc     TMP
        inx
        bra     pd_lp
pd_out: pha
        txa
        bne     pd_pr
        cpy     #0
        beq     pd_sk
pd_pr:  ora     #'0'
        jsr     putc
        ldy     #1
pd_sk:  pla
        rts

;---------------------------------------------------------------------------
s_banner:
        db      $0D,$0A,'W65C134SXB software TNC (transmit)   ? = help',$0D,$0A,0
s_help: db      'B beacon now   P periodic on/off   S status',$0D,$0A
        db      '1 1200 Hz tone   2 2200 Hz tone   (any key stops a tone)',$0D,$0A
        db      'ESC back to the monitor',$0D,$0A,0
s_nocfg:
        db      'Edit the CONFIG block in tnc134.asm (call, position, cfg_ok = 1)'
        db      ' before transmitting packets.',$0D,$0A,0
s_tx:   db      'TX ',0
s_done: db      'done',$0D,$0A,0
s_ovf:  db      'frame too long',$0D,$0A,0
s_busy: db      'channel busy, beacon skipped',$0D,$0A,0
s_tone: db      'tone on, any key stops ... ',0
s_st1:  db      'periodic beacon ',0
s_on:   db      'on, every ',0
s_min:  db      ' min, next in ',0
s_min2: db      ' min',$0D,$0A,0
s_off:  db      'off',$0D,$0A,0
s_bye:  db      'back to the monitor',$0D,$0A,0
s_clk:  db      'WARNING: monitor reports a crystal other than 3.6864 MHz;'
        db      ' tones and baud rate will be off. Fix T1_SAMPLE/T1_TICK.',$0D,$0A,0

        ENDS
        END
