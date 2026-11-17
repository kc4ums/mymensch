;***************************************************************************
;  FILE:   tnc.asm
;  TITLE:  MyMENSCH Rev-C software TNC - transmit side (1200 baud AFSK)
;
;  The MyMENSCH builds APRS packets itself and sends them as audio to the
;  Kenwood TM-V71A data port. No external TNC. Wiring:
;  hardware/radio_interface.svg.
;
;    J4 pin 37/39/41/43  VIA_B PA3..PA0  4-bit R-2R DAC -> PKD (data pin 1)
;    J4 pin 35           VIA_B PA4       PTT via 2N7000 -> PKS (data pin 3)
;    J4 pin 33           VIA_B PA5       SQC in (optional, data pin 6)
;
;  Edit the CONFIG block below (your call, position, set cfg_ok to 1),
;  build with mk_tnc.bat and load:
;    wdc_uploader_term.exe -d COM10 tnc.bin -m write -x -s 5 -t
;
;  LEDs: 0 = heartbeat while idle, 1 = TX (radio keyed),
;        2 = RX (channel busy: SQC if cfg_sqc is set, else audio on PA7).
;
;  Keys:  B = send a beacon now      P = periodic beacon on/off
;         1 = 1200 Hz test tone      2 = 2200 Hz test tone  (any key stops)
;         S = status   ? = help   ESC = restart the board
;
;  How it works
;  - A packet is built as an AX.25 UI frame (addresses, control, PID,
;    APRS position text, CRC-16), then encoded bit by bit into TONES:
;    TXDELAY flags, the frame with bit stuffing, tail flags, all NRZI.
;    One byte per bit: 0 = mark (1200 Hz), 1 = space (2200 Hz).
;  - The send loop then plays TONES: 19200 samples/s from a 64-step sine
;    table with a 16-bit phase accumulator (continuous phase), 16 samples
;    per bit. No timers are used: every sample takes exactly 768 cycles
;    at 14.7456 MHz, counted instruction by instruction (see tx_smp).
;    If the clock were different, the 1 and 2 test tones would show it.
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_DATA       EQU     $7F60           ; console (CH340)
ACIA_STAT       EQU     $7F61
GPIOB_DATA      EQU     $7F08           ; LEDs
GPIOB_DDR       EQU     $7F09
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1
VIAB_DDRA       EQU     $7F33
VIAB_ORA        EQU     $7F3F           ; port A, no handshake

PTT_BIT         EQU     $10             ; PA4
SQC_BIT         EQU     $20             ; PA5
HB_LED          EQU     $01             ; LED 0: heartbeat
TX_LED          EQU     $02             ; LED 1: radio keyed
RX_LED          EQU     $04             ; LED 2: channel busy (SQC or audio)
RX_BIT          EQU     $80             ; PA7, comparator output
RX_EDGES        EQU     16              ; edges in 10 ms that mean "audio"
RX_HANG         EQU     20              ; RX LED stays on 200 ms after
DAC_MID         EQU     $08
OUT_MASK        EQU     $1F             ; PA0-PA4 outputs

; RAM
FRAME           EQU     $0300           ; AX.25 frame before encoding (256)
TONES           EQU     $0800           ; one byte per bit, $0800-$17FF
TONES_END       EQU     $1800

; zero page
PH              EQU     $40             ; 2, phase accumulator
INCL            EQU     $42             ; phase increment
INCH            EQU     $43
SCNT            EQU     $44             ; samples left in this bit
TP              EQU     $45             ; 2, TONES pointer
TEND            EQU     $47             ; 2, end of TONES data
TONE            EQU     $49             ; current NRZI tone
ONES            EQU     $4A             ; 1s in a row, for bit stuffing
CRC             EQU     $4B             ; 2
CRCON           EQU     $4D
CURB            EQU     $4E
BCNT            EQU     $4F
BITV            EQU     $50
OVF             EQU     $51             ; TONES overflowed
FLEN            EQU     $52             ; frame length
MODE            EQU     $53             ; 0 = frame, 1 = test tone
REP             EQU     $54             ; test tone repeats left
PTR             EQU     $55             ; 2
TICK            EQU     $57             ; 10 ms ticks
SECS            EQU     $58
NEXTM           EQU     $59             ; minutes to the next beacon
PERIOD          EQU     $5A             ; periodic beacon on
TMP             EQU     $5B
LASTRX          EQU     $5C             ; last PA7 level
EDGES           EQU     $5D             ; PA7 changes in this tick
SPTR            EQU     $5E             ; 2
RXHANG          EQU     $60             ; ticks the RX LED stays on

; delay loop counts for 768 cycles a sample (see tx_smp)
D_SAMPLE        EQU     143
D_BIT           EQU     134

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

        ds      $8030-*
;***************************************************************************
;  CONFIG  (fixed at $8030 so it can also be patched with MMON's E command)
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
cfg_cmt:  db    'MyMENSCH 65C02 software TNC',0   ; comment, max 40 chars

        ds      $8100-*
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
        lda     #$80                    ; RTS to the CH340 so keys get through
        tsb     GPIOE_DDR
        trb     GPIOE_PIO
        lda     #$FF
        sta     GPIOB_DDR
        stz     GPIOB_DATA
        jsr     radio_idle
        lda     VIAB_DDRA
        and     #$FF-OUT_MASK           ; PA5-PA7 inputs
        ora     #OUT_MASK               ; PA0-PA4 outputs
        sta     VIAB_DDRA
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
        lda     cfg_ok
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
mn_key: lda     ACIA_STAT
        and     #$08
        beq     main
        lda     ACIA_DATA
        cmp     #$1B
        bne     mn_cmd
        PRINT   s_bye
        jmp     ($FFFC)
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
        trb     GPIOB_DATA
        rts
hb_on:  lda     #HB_LED
        tsb     GPIOB_DATA
        rts

; RX LED: on while the channel is busy, held RX_HANG ticks after
rx_led: lda     cfg_sqc
        beq     rl_aud
        jsr     sqc_busy
        bne     rl_busy
        bra     rl_quiet
rl_aud: lda     EDGES                   ; audio on PA7 this tick?
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
        tsb     GPIOB_DATA
        rts
rl_off: lda     #RX_LED
        trb     GPIOB_DATA
        rts

; A <> 0 (Z=0) if SQC says the channel is busy (cfg_sqc must be 1 or 2)
sqc_busy:
        lda     VIAB_ORA
        and     #SQC_BIT
        ldx     cfg_sqc
        cpx     #1
        beq     sb_x
        eor     #SQC_BIT                ; busy when low: invert
sb_x:   cmp     #0
        rts

; about 10 ms at 14.7456 MHz, counting PA7 edges into EDGES as it waits:
; 34 x 256 x 17 cycles
tick_wait:
        stz     EDGES
        ldx     #34
tw_o:   ldy     #0
tw_i:   lda     VIAB_ORA                ; 4
        and     #RX_BIT                 ; 2
        cmp     LASTRX                  ; 3
        beq     tw_s                    ; 3 / 2
        sta     LASTRX
        inc     EDGES
        bne     tw_s
        dec     EDGES                   ; stop at 255
tw_s:   dey                             ; 2
        bne     tw_i                    ; 3
        dex
        bne     tw_o
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
        tsb     GPIOB_DATA              ; TX LED on while keyed
        stz     PH
        stz     PH+1
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

; One sample. Both paths store the DAC at the same point and take exactly
; 768 cycles (14.7456 MHz / 19200). Cycle counts in the right column.
tx_smp: clc                             ; 2
        lda     PH                      ; 3
        adc     INCL                    ; 3
        sta     PH                      ; 3
        lda     PH+1                    ; 3
        adc     INCH                    ; 3
        sta     PH+1                    ; 3
        lsr     a                       ; 2
        lsr     a                       ; 2   top 6 bits
        tax                             ; 2
        lda     sine,x                  ; 4   page aligned
        ora     #PTT_BIT                ; 2
        sta     VIAB_ORA                ; 4   DAC + PTT
        dec     SCNT                    ; 5   = 41
        beq     tx_bit                  ; 2 / 3 taken
        ldy     #D_SAMPLE               ; 2
tx_d1:  dey                             ; 5 x 143 - 1 = 714
        bne     tx_d1
        nop                             ; 2
        nop                             ; 2
        nop                             ; 2
        bra     tx_smp                  ; 3   41+2+2+714+6+3 = 768

tx_bit: lda     #16                     ; 2   (44 so far)
        sta     SCNT                    ; 3
        inc     TP                      ; 5
        bne     tx_b1                   ; 3   (+4 once every 256 bits)
        inc     TP+1
tx_b1:  lda     TP                      ; 3
        cmp     TEND                    ; 3
        lda     TP+1                    ; 3
        sbc     TEND+1                  ; 3
        bcs     tx_end                  ; 2
        lda     (TP)                    ; 5
        tax                             ; 2
        lda     inc_lo,x                ; 4
        sta     INCL                    ; 3
        lda     inc_hi,x                ; 4
        sta     INCH                    ; 3
        ldy     #D_BIT                  ; 2   = 94
tx_d2:  dey                             ; 5 x 134 - 1 = 669
        bne     tx_d2
        nop                             ; 2
        bra     tx_smp                  ; 3   94+669+2+3 = 768

tx_end: lda     MODE
        beq     tx_off
        lda     ACIA_STAT               ; test tone: stop on a key
        and     #$08
        bne     tx_key
        dec     REP
        beq     tx_off
        jmp     tx_restart
tx_key: lda     ACIA_DATA
tx_off: jsr     radio_idle
        lda     #TX_LED
        trb     GPIOB_DATA
        rts

radio_idle:
        lda     #DAC_MID                ; PTT off, DAC mid-scale
        sta     VIAB_ORA
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
        db      $0D,$0A,'MyMENSCH software TNC (transmit)   ? = help',$0D,$0A,0
s_help: db      'B beacon now   P periodic on/off   S status',$0D,$0A
        db      '1 1200 Hz tone   2 2200 Hz tone   (any key stops a tone)',$0D,$0A
        db      'ESC restart',$0D,$0A,0
s_nocfg:
        db      'Edit the CONFIG block in tnc.asm (call, position, cfg_ok = 1)'
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
s_bye:  db      'restarting',$0D,$0A,0

        ENDS
        END
