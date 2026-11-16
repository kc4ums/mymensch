;***************************************************************************
;  FILE:   aprsrx.asm
;  TITLE:  APRS receive-only interface: AEA PK-232 -> WDC MyMENSCH Rev-C
;          (W65C165i1 FPGA microcontroller, W65C02 core)
;
;  The PK-232 runs in plain text (monitor) mode and prints each packet it
;  hears as a line like
;
;      KC4UMS-9>APRS,WIDE1-1,WIDE2-1*:!3500.00N/08500.00W>Mobile
;
;  This program reads those lines on ACIA_B and prints a decoded version on
;  ACIA_A, the CH340 USB port (115200 baud, same port the uploader uses).
;
;  Hardware (header J4)
;    pin 44  RXD_B  <- MAX3232 R1OUT <- PK-232 DB-25 pin 3 (TXD out)
;    pin 49  VSS    -- ground
;    The board runs on 3.3 V: use a MAX3232 (3.3 V) level converter,
;    never wire RS-232 straight to the header.
;
;  Receive path
;    ACIA_B raises an interrupt for every byte (the program jump table at
;    $8000 routes IRQ_ACIA_B here). The handler puts the byte in a 256-byte
;    ring buffer; the main loop decodes lines from that buffer.
;
;  Load and run with WDC's uploader (press RESET when it asks):
;    wdc_uploader_term.exe -d COM10 aprsrx.bin -m write -x -s 5 -t
;  Console keys:  ESC = stop (restarts the board)  R = raw lines  S = stats
;
;  Build: mk_aprsrx.bat  (WDC02AS + WDCLN, makes aprsrx.bin)
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

;---------------------------------------------------------------------------
; Configuration
;---------------------------------------------------------------------------
; ACIA_B control register: 8 data bits, 1 stop bit, internal baud rate.
; Low nibble = speed: $18 1200, $1A 2400, $1C 4800, $1E 9600, $1F 19200
TNC_CTRL        EQU     $1E             ; 9600 8N1

;---------------------------------------------------------------------------
; W65C165i1 I/O (MyMENSCH Rev-C)
;---------------------------------------------------------------------------
GPIOB_DATA      EQU     $7F08           ; the 8 LEDs
GPIOB_DDR       EQU     $7F09
ACIA_A_DATA     EQU     $7F60           ; CH340 USB console
ACIA_A_STAT     EQU     $7F61
ACIA_B_DATA     EQU     $7F64           ; PK-232
ACIA_B_STAT     EQU     $7F65           ; write = program reset
ACIA_B_CMD      EQU     $7F66
ACIA_B_CTRL     EQU     $7F67
GPIOE_PIO       EQU     $7FA0           ; E7 = RTS to the CH340 (ACIA_A)
GPIOE_DDR       EQU     $7FA1

ST_RDRF         EQU     $08             ; ACIA status: byte received
ST_TDRE         EQU     $10             ; ACIA status: transmitter empty
ST_ERR          EQU     $07             ; overrun, framing, parity

;---------------------------------------------------------------------------
; Memory (10 KB data SRAM at $0000-$73FF; code runs at $8000)
;---------------------------------------------------------------------------
LINEBUF         EQU     $0200           ; current line from the TNC
HDRBUF          EQU     $0300           ; saved header (HEADERLN ON mode)
DESTBUF         EQU     $0400           ; destination call (for Mic-E)
DIGBUF          EQU     $0410           ; decimal digit scratch
LATSTR          EQU     $0420           ; Mic-E latitude digits
RXBUF           EQU     $0500           ; 256-byte receive ring
LINEMAX         EQU     250

rx_head         EQU     $0600           ; written only by the ISR
rx_tail         EQU     $0601           ; written only by the main loop
line_len        EQU     $0602
pkt_count       EQU     $0603           ; 2 bytes
rx_err          EQU     $0605           ; 2 bytes: overrun/framing/parity
rx_ovf          EQU     $0607           ; 2 bytes: ring buffer full
line_ovf        EQU     $0609           ; 2 bytes: lines over LINEMAX
pending_hdr     EQU     $060B
raw_mode        EQU     $060C
br_depth        EQU     $060D
gt_seen         EQU     $060E
wx_mode         EQU     $060F           ; 1 = positionless weather report
msg_bits        EQU     $0610
msg_cust        EQU     $0611
mic_off         EQU     $0612           ; Mic-E longitude +100 flag
mic_ns          EQU     $0613
mic_ew          EQU     $0614
mic_dc          EQU     $0615
mic_se          EQU     $0616
mic_sp          EQU     $0617

; Zero page
N32             EQU     $40             ; number / dividend / quotient
D32             EQU     $44             ; divisor
R32             EQU     $48             ; remainder
M32             EQU     $4C             ; multiplicand
P32             EQU     $50             ; product
M16             EQU     $54             ; multiplier (2)
T32             EQU     $56
CUR             EQU     $5A             ; parse pointer
IP              EQU     $5C             ; info field pointer
HP              EQU     $5E             ; header pointer
SPTR            EQU     $60             ; string pointer for puts
TPTR            EQU     $62             ; table pointer
TMP             EQU     $64
TMP2            EQU     $65
CNT             EQU     $66
WIDTH           EQU     $67             ; zero-pad width for print_u32
SYMT            EQU     $68             ; symbol table char
SYMC            EQU     $69             ; symbol code char
DEGW            EQU     $6A
HEMI            EQU     $6B
FSIGN           EQU     $6C
FMT             EQU     $6D
VAL             EQU     $6E             ; 16-bit value
DIVK            EQU     $70             ; coordinate divisor (4)
WXI             EQU     $74
DT              EQU     $75             ; div32 scratch (3)

; print a constant string (uses X and Y)
PRINT   MACRO   STR
        ldx     #<STR
        ldy     #>STR
        jsr     puts_k
        ENDM

;***************************************************************************
        CODE
        ORG     $8000

; Jump table required by the MyMENSCH firmware
        jmp     START
        jmp     NMI_Handle
        jmp     BRK_Handle
        jmp     NoINT                   ; IRQ_ACIA_C
        jmp     acia_b_isr              ; IRQ_ACIA_B
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

START:
        sei
        cld
        ldx     #$FF
        txs
        jsr     init_vars
        lda     #$FF
        sta     GPIOB_DDR               ; LEDs show the packet count
        stz     GPIOB_DATA
        lda     #$80                    ; RTS to the CH340 on, so the PC
        tsb     GPIOE_DDR               ; can send keys to us
        trb     GPIOE_PIO
        jsr     tnc_init
        cli
        PRINT   s_banner

;---------------------------------------------------------------------------
; Main loop
;---------------------------------------------------------------------------
main_loop:
        jsr     rx_get
        bcs     ml_key
        jsr     line_char
ml_key:
        jsr     con_get
        bcs     main_loop
        cmp     #$1B
        beq     quit
        and     #$DF                    ; upper case
        cmp     #'R'
        beq     ml_raw
        cmp     #'S'
        bne     main_loop
        jsr     show_stats
        bra     main_loop
ml_raw:
        lda     raw_mode
        eor     #1
        sta     raw_mode
        beq     ml_off
        PRINT   s_rawon
        bra     main_loop
ml_off:
        PRINT   s_rawoff
        bra     main_loop

quit:
        sei
        sta     ACIA_B_STAT             ; reset ACIA_B (receiver off)
        PRINT   s_bye
        jmp     ($FFFC)                 ; restart into the board's monitor

NMI_Handle:
BRK_Handle:
NoINT:
        rti

;---------------------------------------------------------------------------
init_vars:
        ldx     #$17
iv_lp:  stz     rx_head,x
        dex
        bpl     iv_lp
        stz     WIDTH
        rts

;---------------------------------------------------------------------------
; ACIA_B: 8N1 at TNC_CTRL speed, receive interrupt on, transmitter off.
; 7E1 from the TNC also frames correctly; the parity bit is masked later.
;---------------------------------------------------------------------------
tnc_init:
        sta     ACIA_B_STAT             ; program reset
        lda     #TNC_CTRL
        sta     ACIA_B_CTRL
        lda     #$09                    ; DTR on, RTS low, RX IRQ on, TX IRQ off
        sta     ACIA_B_CMD
        lda     ACIA_B_STAT
        lda     ACIA_B_DATA             ; flush
        rts

;---------------------------------------------------------------------------
; ACIA_B interrupt: one received byte into the ring
;---------------------------------------------------------------------------
acia_b_isr:
        pha
        phx
        lda     ACIA_B_STAT             ; also clears the IRQ flag
        bit     #ST_ERR                 ; count errors even with no new byte
        beq     isr_rx
        inc     rx_err
        bne     isr_rx
        inc     rx_err+1
isr_rx: bit     #ST_RDRF
        beq     isr_done
        lda     ACIA_B_DATA
        ldx     rx_head
        sta     RXBUF,x
        inx
        cpx     rx_tail
        beq     isr_full
        stx     rx_head
        bra     isr_done
isr_full:
        inc     rx_ovf
        bne     isr_done
        inc     rx_ovf+1
isr_done:
        plx
        pla
        rti

; rx_get: next TNC byte. C=0 and byte in A, or C=1 if none.
rx_get:
        ldx     rx_tail
        cpx     rx_head
        beq     rg_none
        lda     RXBUF,x
        inc     rx_tail
        clc
        rts
rg_none:
        sec
        rts

; con_get: console key. C=0 and key in A, or C=1 if none.
con_get:
        lda     ACIA_A_STAT
        and     #ST_RDRF
        beq     cg_none
        lda     ACIA_A_DATA
        clc
        rts
cg_none:
        sec
        rts

; putc: send A to the console. Keeps A, X, Y.
putc:   pha
pc_wt:  lda     ACIA_A_STAT
        and     #ST_TDRE
        beq     pc_wt
        pla
        sta     ACIA_A_DATA
        rts

;---------------------------------------------------------------------------
; line_char: collect one TNC character; process the line at CR or LF.
;---------------------------------------------------------------------------
line_char:
        and     #$7F                    ; drop parity
        cmp     #$0D
        beq     lc_eol
        cmp     #$0A
        beq     lc_eol
        cmp     #$20
        bcc     lc_ret                  ; other control chars ignored
        cmp     #$7F
        beq     lc_ret
        ldx     line_len
        cpx     #LINEMAX
        bcs     lc_long
        sta     LINEBUF,x
        inc     line_len
lc_ret: rts
lc_long:
        bne     lc_ret                  ; count each long line once
        inc     line_len
        inc     line_ovf
        bne     lc_ret
        inc     line_ovf+1
        rts
lc_eol:
        ldx     line_len
        beq     lc_ret                  ; blank line
        cpx     #LINEMAX
        bcc     lc_term
        ldx     #LINEMAX
lc_term:
        stz     LINEBUF,x
        jsr     process_line
        stz     line_len
        rts

;---------------------------------------------------------------------------
; process_line: split a monitored line into header and info.
;---------------------------------------------------------------------------
process_line:
        lda     raw_mode
        beq     pl_noraw
        PRINT   s_raw
        PRINT   LINEBUF
        jsr     crlf
pl_noraw:
        lda     pending_hdr
        beq     pl_scan
        stz     pending_hdr             ; HEADERLN ON: this line is the info
        lda     #<HDRBUF
        sta     HP
        lda     #>HDRBUF
        sta     HP+1
        lda     #<LINEBUF
        sta     IP
        lda     #>LINEBUF
        sta     IP+1
        jmp     decode_packet

pl_scan:
        stz     br_depth
        stz     gt_seen
        ldy     #0
pl_lp:  lda     LINEBUF,y
        beq     pl_tnc
        cmp     #'['
        beq     pl_open
        cmp     #']'
        beq     pl_close
        ldx     br_depth
        bne     pl_nx                   ; ignore text inside [ ] (MSTAMP)
        cmp     #'>'
        bne     pl_n3
        sta     gt_seen
pl_n3:  cmp     #':'
        beq     pl_colon
pl_nx:  iny
        bra     pl_lp
pl_open:
        ldx     #1
        stx     br_depth
        bra     pl_nx
pl_close:
        stz     br_depth
        bra     pl_nx

pl_colon:
        lda     gt_seen
        beq     pl_tnc                  ; "cmd:" etc. -> not a packet
        iny
        lda     #<LINEBUF
        sta     HP
        lda     #>LINEBUF
        sta     HP+1
        tya
        clc
        adc     #<LINEBUF
        sta     IP
        lda     #>LINEBUF
        adc     #0
        sta     IP+1
        lda     LINEBUF,y
        beq     pl_hdronly
        jmp     decode_packet
pl_hdronly:                             ; info comes on the next line
        ldy     #0
pl_cp:  lda     LINEBUF,y
        sta     HDRBUF,y
        beq     pl_cpd
        iny
        bra     pl_cp
pl_cpd: lda     #1
        sta     pending_hdr
        rts

pl_tnc: PRINT   s_tnc
        PRINT   LINEBUF
        jmp     crlf

;---------------------------------------------------------------------------
; decode_packet: HP -> header, IP -> info field
;---------------------------------------------------------------------------
decode_packet:
        jsr     crlf
        inc     pkt_count
        bne     dp_c
        inc     pkt_count+1
dp_c:   lda     pkt_count
        sta     GPIOB_DATA
        lda     #'#'
        jsr     putc
        lda     #4
        sta     WIDTH
        lda     pkt_count
        ldx     pkt_count+1
        jsr     pnum16
        jsr     space
        jsr     print_header
        jsr     crlf

        jsr     cur_ip
dp_sk:  lda     (CUR)                   ; skip leading spaces
        cmp     #' '
        bne     dp_go
        jsr     inc_cur
        bra     dp_sk
dp_go:  lda     CUR
        sta     IP
        lda     CUR+1
        sta     IP+1
        ldx     #0
dp_lp:  lda     dti_table,x
        beq     dp_unk
        cmp     (CUR)
        beq     dp_hit
        inx
        inx
        inx
        bra     dp_lp
dp_hit: jmp     (dti_table+1,x)
dp_unk: ldx     #<s_t_unk
        ldy     #>s_t_unk
        jmp     do_labeled

; data type indicator -> handler
dti_table:
        db      '!'
        dw      do_pos
        db      '='
        dw      do_pos
        db      '/'
        dw      do_pos_ts
        db      '@'
        dw      do_pos_ts
        db      ':'
        dw      do_msg
        db      ';'
        dw      do_object
        db      ')'
        dw      do_item
        db      '>'
        dw      do_status
        db      '`'
        dw      do_mice
        db      $27
        dw      do_mice
        db      $1C
        dw      do_mice
        db      $1D
        dw      do_mice
        db      '_'
        dw      do_wx
        db      '}'
        dw      do_third
        db      'T'
        dw      do_telem
        db      '<'
        dw      do_caps
        db      '?'
        dw      do_query
        db      '$'
        dw      do_nmea
        db      '#'
        dw      do_peet
        db      '*'
        dw      do_peet
        db      '{'
        dw      do_user
        db      0

do_telem:
        ldx     #<s_t_tel
        ldy     #>s_t_tel
        bra     do_labeled
do_caps:
        ldx     #<s_t_cap
        ldy     #>s_t_cap
        bra     do_labeled
do_query:
        ldx     #<s_t_qry
        ldy     #>s_t_qry
        bra     do_labeled
do_nmea:
        ldx     #<s_t_nmea
        ldy     #>s_t_nmea
        bra     do_labeled
do_peet:
        ldx     #<s_t_peet
        ldy     #>s_t_peet
        bra     do_labeled
do_user:
        ldx     #<s_t_user
        ldy     #>s_t_user

; print the label in X/Y and the info field as-is
do_labeled:
        jsr     puts_k
        jsr     cur_ip
        jsr     puts_cur
        jmp     crlf

;---------------------------------------------------------------------------
; print_header: "SRC > DEST via DIGI1,DIGI2*", copies DEST to DESTBUF
;---------------------------------------------------------------------------
print_header:
        lda     HP
        sta     CUR
        lda     HP+1
        sta     CUR+1
        ldy     #0
ph_src: lda     (CUR),y
        beq     ph_end
        cmp     #':'
        beq     ph_end
        cmp     #'>'
        beq     ph_gt
        jsr     putc
        iny
        bra     ph_src
ph_gt:  iny
        phy
        PRINT   s_arrow
        ply
        ldx     #0
ph_dst: lda     (CUR),y
        jsr     hdr_term
        bcs     ph_dend
        jsr     putc
        cpx     #15
        bcs     ph_dnx
        sta     DESTBUF,x
        inx
ph_dnx: iny
        bra     ph_dst
ph_dend:
        stz     DESTBUF,x
        cmp     #','
        beq     ph_path
        cmp     #'>'
        bne     ph_end
ph_path:
        phy
        PRINT   s_via
        ply
        iny
ph_pl:  lda     (CUR),y
        cmp     #','
        beq     ph_sep
        cmp     #'>'
        beq     ph_sep
        jsr     hdr_term
        bcs     ph_end
        jsr     putc
        iny
        bra     ph_pl
ph_sep: lda     #','
        jsr     putc
        iny
        bra     ph_pl
ph_end: rts

; C=1 if A ends a header token (NUL , : space < [ >)
hdr_term:
        cmp     #0
        beq     ht_y
        cmp     #','
        beq     ht_y
        cmp     #':'
        beq     ht_y
        cmp     #' '
        beq     ht_y
        cmp     #'<'
        beq     ht_y
        cmp     #'['
        beq     ht_y
        cmp     #'>'
        beq     ht_y
        clc
        rts
ht_y:   sec
        rts

;---------------------------------------------------------------------------
; Position reports  ! = (no timestamp)   / @ (timestamp)
;---------------------------------------------------------------------------
do_pos_ts:
        PRINT   s_time
        jsr     cur_ip1
        lda     #7
        jsr     putn_cur
        jsr     crlf
        bra     dpos_go
do_pos:
        jsr     cur_ip1
dpos_go:
        stz     wx_mode
        jsr     decode_position
        bcc     dpos_ok
        jmp     bad_data
dpos_ok:
        jsr     print_symbol
        jsr     pos_extension
        jmp     print_comment

;---------------------------------------------------------------------------
; decode_position: CUR -> position (uncompressed or compressed).
; Prints it, sets SYMT/SYMC, leaves CUR past it. C=1 if not valid.
;---------------------------------------------------------------------------
decode_position:
        lda     (CUR)
        cmp     #'0'
        bcc     dpo_cmp
        cmp     #'9'+1
        bcs     dpo_cmp
        jmp     pos_unc
dpo_cmp:
        cmp     #'/'
        beq     dpo_c
        cmp     #$5C                    ; backslash
        beq     dpo_c
        cmp     #'A'
        bcc     dpo_bad
        cmp     #'Z'+1
        bcc     dpo_c
        cmp     #'a'
        bcc     dpo_bad
        cmp     #'j'+1
        bcs     dpo_bad
dpo_c:  jmp     pos_cmp
dpo_bad:
        sec
        rts

; DDMM.hhN/DDDMM.hhW>   (19 chars)
pos_unc:
        lda     #19
        jsr     need_cur
        bcs     pu_bad
        ldy     #4
        lda     (CUR),y
        cmp     #'.'
        bne     pu_bad
        ldy     #14
        lda     (CUR),y
        cmp     #'.'
        bne     pu_bad
        ldy     #7
        lda     (CUR),y
        and     #$DF
        cmp     #'N'
        beq     pu_ns
        cmp     #'S'
        bne     pu_bad
pu_ns:  ldy     #17
        lda     (CUR),y
        and     #$DF
        cmp     #'E'
        beq     pu_ew
        cmp     #'W'
        beq     pu_ew
pu_bad: sec
        rts
pu_ew:  PRINT   s_pos
        lda     #2
        jsr     putn_cur                ; DD
        jsr     space
        lda     #6
        jsr     putn_cur                ; MM.hhN
        lda     (CUR)
        sta     SYMT
        jsr     inc_cur
        jsr     space
        jsr     space
        lda     #3
        jsr     putn_cur                ; DDD
        jsr     space
        lda     #6
        jsr     putn_cur                ; MM.hhW
        lda     (CUR)
        sta     SYMC
        jsr     inc_cur
        jsr     crlf
        clc
        rts

; Compressed: T YYYY XXXX C cs t  (13 chars, base 91)
pos_cmp:
        lda     #13
        jsr     need_cur
        bcs     pcv_bad
        ldy     #1                      ; the 8 base-91 digits
pcv_lp: lda     (CUR),y
        cmp     #'!'
        bcc     pcv_bad
        cmp     #'{'+1
        bcs     pcv_bad
        iny
        cpy     #9
        bne     pcv_lp
        bra     pcv_ok
pcv_bad:
        sec
        rts
pcv_ok: lda     (CUR)
        sta     SYMT
        jsr     inc_cur
        PRINT   s_pos
        lda     #4
        jsr     b91_n                   ; N32 = y
        jsr     sub_k_n                 ; T32 = 90*380926 - y
        lda     #'N'
        bcs     pc_lat
        jsr     sub_n_k                 ; south: T32 = y - 90*380926
        lda     #'S'
pc_lat: sta     HEMI
        jsr     t_to_n
        ldx     #0                      ; divisor 380926
        jsr     set_divk
        lda     #2
        sta     DEGW
        jsr     coord_out
        jsr     space
        jsr     space
        lda     #4
        jsr     b91_n                   ; N32 = x
        jsr     sub_n_k                 ; T32 = x - 180*190463
        lda     #'E'
        bcs     pc_lon
        jsr     sub_k_n                 ; west: T32 = 180*190463 - x
        lda     #'W'
pc_lon: sta     HEMI
        jsr     t_to_n
        ldx     #4                      ; divisor 190463
        jsr     set_divk
        lda     #3
        sta     DEGW
        jsr     coord_out
        jsr     crlf
        lda     (CUR)
        sta     SYMC
        ldy     #1                      ; course/speed bytes
        lda     (CUR),y
        cmp     #' '
        beq     pc_done
        ldy     #3
        lda     (CUR),y
        sec
        sbc     #33
        and     #$18
        cmp     #$10
        beq     pc_done                 ; altitude form, not decoded yet
        ldy     #1
        lda     (CUR),y
        cmp     #'{'
        beq     pc_done                 ; radio range form
        cmp     #'!'
        bcc     pc_done
        cmp     #'z'+1
        bcs     pc_done
        PRINT   s_crs
        ldy     #1                      ; course = (c-33)*4
        lda     (CUR),y
        sec
        sbc     #33
        stz     TMP2
        asl     a
        rol     TMP2
        asl     a
        rol     TMP2
        ldx     TMP2
        ldy     #3
        sty     WIDTH
        jsr     pnum16
        PRINT   s_spd
        ldy     #2                      ; speed = 1.08^(s-33)-1 knots
        lda     (CUR),y
        sec
        sbc     #33
        cmp     #90
        bcc     pc_sok
        lda     #89
pc_sok: asl     a
        tay
        lda     spd_tab,y
        ldx     spd_tab+1,y
        jsr     pnum16
        PRINT   s_kt
        jsr     crlf
pc_done:
        lda     #4                      ; skip symbol, c, s, type
        jsr     adv
        clc
        rts

; T32 = K - N32, C=1 if no borrow
sub_k_n:
        sec
        ldx     #0
        ldy     #4
skn_lp: lda     K90,x
        sbc     N32,x
        sta     T32,x
        inx
        dey
        bne     skn_lp
        rts

; T32 = N32 - K, C=1 if no borrow
sub_n_k:
        sec
        ldx     #0
        ldy     #4
snk_lp: lda     N32,x
        sbc     K90,x
        sta     T32,x
        inx
        dey
        bne     snk_lp
        rts

t_to_n: ldx     #3
ttn_lp: lda     T32,x
        sta     N32,x
        dex
        bpl     ttn_lp
        rts

; DIVK = divisor table entry X (0 = latitude, 4 = longitude)
set_divk:
        ldy     #0
sdk_lp: lda     DIVTAB,x
        sta     DIVK,y
        inx
        iny
        cpy     #4
        bne     sdk_lp
        rts

K90:    db      $4C,$1F,$0B,$02         ; 90*380926 = 180*190463 = 34283340
DIVTAB: db      $FE,$CF,$05,$00         ; 380926
        db      $FF,$E7,$02,$00         ; 190463

; b91_n: N32 = A base-91 digits at CUR, CUR advanced
b91_n:  sta     CNT
        stz     N32
        stz     N32+1
        stz     N32+2
        stz     N32+3
b91_lp: ldx     #3
b91_cp: lda     N32,x
        sta     M32,x
        dex
        bpl     b91_cp
        lda     #91
        sta     M16
        stz     M16+1
        jsr     mul32
        lda     (CUR)
        sec
        sbc     #33
        clc
        adc     P32
        sta     N32
        lda     P32+1
        adc     #0
        sta     N32+1
        lda     P32+2
        adc     #0
        sta     N32+2
        lda     P32+3
        adc     #0
        sta     N32+3
        jsr     inc_cur
        dec     CNT
        bne     b91_lp
        rts

; coord_out: N32 = coordinate in 1/DIVK degree units.
; Prints "DD MM.hhH" with DEGW degree digits and HEMI letter.
coord_out:
        jsr     divk_to_d
        jsr     div32                   ; N32 = degrees, R32 = remainder
        ldx     #3
co_cp:  lda     R32,x
        sta     T32,x
        dex
        bpl     co_cp
        lda     DEGW
        sta     WIDTH
        jsr     print_u32
        jsr     space
        ldx     #3                      ; hundredths of minutes = rem*6000/DIVK
co_cp2: lda     T32,x
        sta     M32,x
        dex
        bpl     co_cp2
        lda     #<6000
        sta     M16
        lda     #>6000
        sta     M16+1
        jsr     mul32
        ldx     #3
co_cp3: lda     P32,x
        sta     N32,x
        dex
        bpl     co_cp3
        jsr     divk_to_d
        jsr     div32
        lda     #2
        sta     WIDTH
        jsr     print_2dec              ; MM.hh
        lda     HEMI
        jmp     putc

divk_to_d:
        ldx     #3
dtd_lp: lda     DIVK,x
        sta     D32,x
        dex
        bpl     dtd_lp
        rts

;---------------------------------------------------------------------------
; Symbol line
;---------------------------------------------------------------------------
print_symbol:
        PRINT   s_sym
        lda     SYMT
        jsr     putc
        lda     SYMC
        jsr     putc
        jsr     space
        lda     SYMT
        cmp     #'/'
        bne     psy_alt
        lda     #<sym_tab
        sta     TPTR
        lda     #>sym_tab
        sta     TPTR+1
psy_lp: lda     (TPTR)
        beq     psy_end
        cmp     SYMC
        beq     psy_hit
psy_sk: jsr     inc_tptr                ; skip to the next entry
        lda     (TPTR)
        bne     psy_sk
        jsr     inc_tptr
        bra     psy_lp
psy_hit:
        jsr     inc_tptr
        ldx     TPTR
        ldy     TPTR+1
        jsr     puts_k
        bra     psy_end
psy_alt:
        PRINT   s_symalt
psy_end:
        jmp     crlf

;---------------------------------------------------------------------------
; pos_extension: CUR -> text after the symbol. Handles CSE/SPD, PHG, RNG,
; DFS and weather data. Leaves CUR at the comment.
;---------------------------------------------------------------------------
pos_extension:
        ldy     #3
        lda     (CUR),y
        cmp     #'/'
        bne     pe_other
        ldy     #0
        jsr     is_num3y
        bcs     pe_other
        ldy     #4
        jsr     is_num3y
        bcs     pe_other
        lda     SYMC
        cmp     #'_'
        beq     pe_wind
        PRINT   s_crs                   ; course/speed (knots)
        lda     #3
        jsr     putn_cur
        jsr     inc_cur
        PRINT   s_spd
        lda     #3
        jsr     putn_cur
        PRINT   s_kt
        jmp     crlf
pe_wind:
        PRINT   s_wx
        PRINT   s_wind
        lda     #3
        jsr     putn_cur
        lda     #'/'
        jsr     putc
        jsr     inc_cur
        lda     #3
        jsr     putn_cur
        PRINT   s_mph
        jsr     wx_fields
        jmp     crlf

pe_other:
        lda     SYMC
        cmp     #'_'
        bne     pe_phg
        PRINT   s_wx                    ; weather without wind
        jsr     wx_fields
        jmp     crlf
pe_phg: ldx     #KW_PHG
        jsr     match3
        bcs     pe_rng
        ldx     #<s_phgl
        ldy     #>s_phgl
        bra     pe_ext7
pe_rng: ldx     #KW_RNG
        jsr     match3
        bcs     pe_dfs
        ldx     #<s_rngl
        ldy     #>s_rngl
        bra     pe_ext7
pe_dfs: ldx     #KW_DFS
        jsr     match3
        bcs     pe_none
        ldx     #<s_dfsl
        ldy     #>s_dfsl
pe_ext7:
        jsr     puts_k
        lda     #3
        jsr     adv
        lda     #4
        jsr     putn_cur
        jmp     crlf
pe_none:
        rts

; C=0 if the 3 chars at CUR match kw_tab+X
match3: ldy     #0
m3_lp:  lda     (CUR),y
        cmp     kw_tab,x
        bne     m3_no
        inx
        iny
        cpy     #3
        bne     m3_lp
        clc
        rts
m3_no:  sec
        rts

KW_PHG          EQU     0
KW_RNG          EQU     3
KW_DFS          EQU     6
KW_ACK          EQU     9
KW_REJ          EQU     12
kw_tab: db      'PHGRNGDFSackrej'

; C=0 if CUR[Y..Y+2] are digits, '.' or ' ' (unknown values are allowed)
is_num3y:
        ldx     #3
in3_lp: lda     (CUR),y
        cmp     #'.'
        beq     in3_ok
        cmp     #' '
        beq     in3_ok
        cmp     #'0'
        bcc     in3_no
        cmp     #'9'+1
        bcs     in3_no
in3_ok: iny
        dex
        bne     in3_lp
        clc
        rts
in3_no: sec
        rts

;---------------------------------------------------------------------------
; Weather fields: letter + fixed number of digits, e.g. g005t077h50b10132
; Stops at the first letter it does not know; CUR is left there.
;---------------------------------------------------------------------------
wx_fields:
        lda     (CUR)
        beq     wf_end
        cmp     #'s'
        bne     wf_look
        ldx     wx_mode
        bne     wf_look                 ; positionless: s = wind speed
        lda     #'~'                    ; positioned: s = snowfall
wf_look:
        ldx     #0
wf_tl:  ldy     wx_tab,x
        beq     wf_end
        cmp     wx_tab,x
        beq     wf_hit
        pha
        txa
        clc
        adc     #7
        tax
        pla
        bra     wf_tl
wf_end: rts

wf_hit: stx     WXI
        lda     wx_tab+1,x
        sta     CNT                     ; digit count
        lda     wx_tab+2,x
        sta     FMT
        jsr     inc_cur
        jsr     parse_field             ; VAL, FSIGN; C=1 if missing
        bcs     wx_fields
        ldx     WXI
        ldy     wx_tab+4,x
        lda     wx_tab+3,x
        tax
        jsr     puts_k                  ; label
        lda     FSIGN
        beq     wf_pos
        lda     #'-'
        jsr     putc
wf_pos: lda     VAL
        sta     N32
        lda     VAL+1
        sta     N32+1
        stz     N32+2
        stz     N32+3
        lda     FMT
        cmp     #1
        beq     wf_f1
        cmp     #2
        beq     wf_f2
        cmp     #3
        beq     wf_f3
        jsr     print_u32
        bra     wf_unit
wf_f1:  jsr     print_2dec              ; hundredths: 0.25
        bra     wf_unit
wf_f2:  jsr     set_d10                 ; tenths: 1013.2
        jsr     div32
        lda     R32
        pha                             ; print_u32 overwrites R32
        jsr     print_u32
        lda     #'.'
        jsr     putc
        pla
        ora     #'0'
        jsr     putc
        bra     wf_unit
wf_f3:  lda     N32                     ; humidity: 00 means 100
        bne     wf_h
        lda     #100
        sta     N32
wf_h:   jsr     print_u32
wf_unit:
        ldx     WXI
        ldy     wx_tab+6,x
        lda     wx_tab+5,x
        tax
        jsr     puts_k
        jmp     wx_fields

; parse_field: CNT chars at CUR -> VAL (16 bit), FSIGN. CUR advanced.
; C=1 if the field is missing (dots/spaces) or malformed.
parse_field:
        stz     FSIGN
        stz     VAL
        stz     VAL+1
        stz     TMP2                    ; 1 = saw a bad character
        lda     (CUR)
        cmp     #'-'
        bne     pf_lp
        sta     FSIGN
        jsr     inc_cur
        dec     CNT
pf_lp:  lda     (CUR)
        beq     pf_miss
        cmp     #'0'
        bcc     pf_bad
        cmp     #'9'+1
        bcs     pf_bad
        sec
        sbc     #'0'
        pha
        asl     VAL                     ; VAL = VAL*10 + digit
        rol     VAL+1
        lda     VAL
        ldx     VAL+1
        asl     VAL
        rol     VAL+1
        asl     VAL
        rol     VAL+1
        clc
        adc     VAL
        sta     VAL
        txa
        adc     VAL+1
        sta     VAL+1
        pla
        clc
        adc     VAL
        sta     VAL
        bcc     pf_nx
        inc     VAL+1
        bra     pf_nx
pf_bad: lda     #1
        sta     TMP2
pf_nx:  jsr     inc_cur
        dec     CNT
        bne     pf_lp
        lda     TMP2
        bne     pf_miss
        clc
        rts
pf_miss:
        sec
        rts

; char, digits, format, label, unit
; format 0 = integer, 1 = hundredths, 2 = tenths, 3 = humidity
wx_tab:
        db      'c',3,0
        dw      s_wdir,s_deg
        db      's',3,0
        dw      s_wspd,s_mph
        db      'g',3,0
        dw      s_gust,s_mph
        db      't',3,0
        dw      s_temp,s_degf
        db      'r',3,1
        dw      s_rain1,s_in
        db      'p',3,1
        dw      s_rain24,s_in
        db      'P',3,1
        dw      s_rainm,s_in
        db      'h',2,3
        dw      s_hum,s_pct
        db      'b',5,2
        dw      s_baro,s_mb
        db      'L',3,0
        dw      s_lum,s_wm2
        db      '~',3,2
        dw      s_snow,s_in
        db      0

;---------------------------------------------------------------------------
; Positionless weather  _MMDDHHMMc...s...g...t...
;---------------------------------------------------------------------------
do_wx:
        lda     #9
        jsr     need_ip
        bcc     dw_ok
        jmp     bad_data
dw_ok:  PRINT   s_time
        jsr     cur_ip1
        lda     #8
        jsr     putn_cur
        jsr     crlf
        PRINT   s_wx
        lda     #1
        sta     wx_mode
        jsr     wx_fields
        stz     wx_mode
        jsr     crlf
        jmp     print_comment

;---------------------------------------------------------------------------
; Message   :ADDRESSEE:text{id
;---------------------------------------------------------------------------
do_msg:
        lda     #11
        jsr     need_ip
        bcs     dm_bad
        ldy     #10
        lda     (IP),y
        cmp     #':'
        beq     dm_ok
dm_bad: jmp     bad_data
dm_ok:  jsr     cur_ip1
        lda     (CUR)
        cmp     #'B'
        bne     dm_to
        ldy     #1
        lda     (CUR),y
        cmp     #'L'
        bne     dm_to
        iny
        lda     (CUR),y
        cmp     #'N'
        bne     dm_to
        PRINT   s_bln
        bra     dm_name
dm_to:  PRINT   s_msgto
dm_name:
        lda     #9
        jsr     putn_trim
        jsr     crlf
        jsr     inc_cur                 ; skip ':'
        ldx     #KW_ACK
        jsr     match3
        bcc     dm_ack
        ldx     #KW_REJ
        jsr     match3
        bcs     dm_text
        PRINT   s_rejl
        bra     dm_ar
dm_ack: PRINT   s_ackl
dm_ar:  lda     #3
        jsr     adv
        jsr     puts_cur
        jmp     crlf
dm_text:
        PRINT   s_text
dm_tl:  lda     (CUR)
        beq     dm_te
        cmp     #'{'
        beq     dm_id
        jsr     putc
        jsr     inc_cur
        bra     dm_tl
dm_id:  jsr     crlf
        PRINT   s_msgid
        jsr     inc_cur
        jsr     puts_cur
dm_te:  jmp     crlf

;---------------------------------------------------------------------------
; Object   ;NAME_____*DDHHMMzPOSITION...
;---------------------------------------------------------------------------
do_object:
        lda     #18
        jsr     need_ip
        bcs     dob_bad
        ldy     #10
        lda     (IP),y
        cmp     #'*'
        beq     dob_ok
        cmp     #'_'
        beq     dob_ok
dob_bad:
        jmp     bad_data
dob_ok: PRINT   s_obj
        jsr     cur_ip1
        lda     #9
        jsr     putn_trim
        jsr     obj_state               ; CUR -> '*' or '_'
        jsr     inc_cur
        PRINT   s_time
        lda     #7
        jsr     putn_cur
        jsr     crlf
        jmp     dpos_go

; prints " (killed)" if the char at CUR is '_', else " (live)"; then CRLF
obj_state:
        ldx     #<s_live
        ldy     #>s_live
        lda     (CUR)
        cmp     #'_'
        bne     os_p
        ldx     #<s_killed
        ldy     #>s_killed
os_p:   jsr     puts_k
        jmp     crlf

;---------------------------------------------------------------------------
; Item   )NAME!POSITION...  (name is 3-9 chars, ends with ! or _)
;---------------------------------------------------------------------------
do_item:
        PRINT   s_item
        jsr     cur_ip1
        ldx     #0
di_lp:  lda     (CUR)
        beq     di_bad
        cmp     #'!'
        beq     di_end
        cmp     #'_'
        beq     di_end
        jsr     putc
        jsr     inc_cur
        inx
        cpx     #10
        bcc     di_lp
di_bad: jsr     crlf
        jmp     bad_data
di_end: jsr     obj_state
        jsr     inc_cur
        jmp     dpos_go

;---------------------------------------------------------------------------
; Status  >text
;---------------------------------------------------------------------------
do_status:
        PRINT   s_status
        jsr     cur_ip1
        jsr     puts_cur
        jmp     crlf

;---------------------------------------------------------------------------
; Third-party traffic  }SRC>DEST,PATH:info  -> decode the inner packet
;---------------------------------------------------------------------------
do_third:
        PRINT   s_third
        jsr     cur_ip1
        lda     CUR
        sta     HP
        lda     CUR+1
        sta     HP+1
dt_lp:  lda     (CUR)
        beq     dt_bad
        cmp     #':'
        beq     dt_ok
        jsr     inc_cur
        bra     dt_lp
dt_ok:  jsr     inc_cur
        lda     CUR
        sta     IP
        lda     CUR+1
        sta     IP+1
        jmp     decode_packet
dt_bad: jmp     bad_data

;---------------------------------------------------------------------------
; Mic-E. Latitude and message bits are in the destination call;
; longitude, speed, course and symbol are in the info field.
;---------------------------------------------------------------------------
do_mice:
        stz     msg_bits
        stz     msg_cust
        ldy     #0
mi_lp:  lda     DESTBUF,y
        cmp     #'0'
        bcc     mi_bad
        cmp     #'9'+1
        bcc     mi_dig                  ; 0-9 : digit, bit 0
        cmp     #'A'
        bcc     mi_bad
        cmp     #'K'
        bcc     mi_cust                 ; A-J : digit, custom bit 1
        beq     mi_kspc                 ; K   : space, custom bit 1
        cmp     #'L'
        beq     mi_spc                  ; L   : space, bit 0
        cmp     #'P'
        bcc     mi_bad
        cmp     #'Z'
        bcc     mi_std                  ; P-Y : digit, bit 1
        beq     mi_zspc                 ; Z   : space, bit 1
mi_bad: jmp     bad_mice

mi_cust:
        sec
        sbc     #'A'-'0'
        jsr     mi_c1
        bra     mi_dig
mi_kspc:
        jsr     mi_c1
        bra     mi_spc
mi_std: sec
        sbc     #'P'-'0'
        jsr     mi_s1
        bra     mi_dig
mi_zspc:
        jsr     mi_s1
mi_spc: lda     #' '
mi_dig: sta     LATSTR,y
        iny
        cpy     #6
        bne     mi_lp

        lda     DESTBUF+3               ; flags from chars 3, 4, 5
        cmp     #'P'
        lda     #'S'
        bcc     mi_n1
        lda     #'N'
mi_n1:  sta     mic_ns
        stz     mic_off
        lda     DESTBUF+4
        cmp     #'P'
        bcc     mi_n2
        inc     mic_off
mi_n2:  lda     DESTBUF+5
        cmp     #'P'
        lda     #'E'
        bcc     mi_n3
        lda     #'W'
mi_n3:  sta     mic_ew

        lda     #9                      ; info needs at least 9 bytes
        jsr     need_ip
        bcs     mi_bad

        PRINT   s_pos                   ; latitude from the dest call
        lda     LATSTR
        jsr     putc
        lda     LATSTR+1
        jsr     putc
        jsr     space
        lda     LATSTR+2
        jsr     putc
        lda     LATSTR+3
        jsr     putc
        lda     #'.'
        jsr     putc
        lda     LATSTR+4
        jsr     putc
        lda     LATSTR+5
        jsr     putc
        lda     mic_ns
        jsr     putc
        jsr     space
        jsr     space

        lda     mic_off                 ; longitude degrees
        beq     mi_d1
        lda     #100
mi_d1:  ldy     #1
        clc
        adc     (IP),y
        sec
        sbc     #28
        cmp     #180
        bcc     mi_d3
        cmp     #190
        bcs     mi_d2
        sbc     #80-1                   ; C=0 here: 180-189 -> 100-109
        bra     mi_d3
mi_d2:  sbc     #190                    ; C=1 here: 190-199 -> 0-9
mi_d3:  ldx     #3
        jsr     put_a
        jsr     space
        ldy     #2                      ; minutes
        lda     (IP),y
        sec
        sbc     #28
        cmp     #60
        bcc     mi_m1
        sbc     #60
mi_m1:  ldx     #2
        jsr     put_a
        lda     #'.'
        jsr     putc
        ldy     #3                      ; hundredths
        lda     (IP),y
        sec
        sbc     #28
        ldx     #2
        jsr     put_a
        lda     mic_ew
        jsr     putc
        jsr     crlf

        ldy     #7
        lda     (IP),y
        sta     SYMC
        iny
        lda     (IP),y
        sta     SYMT
        jsr     print_symbol

        ; speed = SP*10 + DC/10, course = (DC%10)*100 + SE
        PRINT   s_crs
        ldy     #4
        lda     (IP),y
        sec
        sbc     #28
        sta     mic_sp
        iny
        lda     (IP),y
        sec
        sbc     #28
        sta     mic_dc
        iny
        lda     (IP),y
        sec
        sbc     #28
        sta     mic_se
        lda     mic_dc                  ; X = DC/10, A = DC%10
        ldx     #0
mi_dv:  cmp     #10
        bcc     mi_dvd
        sbc     #10
        inx
        bra     mi_dv
mi_dvd: stx     mic_dc                  ; keep DC/10 for the speed
        tax
        stz     VAL
        stz     VAL+1
        cpx     #0
        beq     mi_c0
mi_ch:  lda     #100
        jsr     val_add
        dex
        bne     mi_ch
mi_c0:  lda     mic_se
        jsr     val_add
        lda     #<400
        ldx     #>400
        jsr     val_wrap
        lda     #3
        sta     WIDTH
        jsr     pnum_val
        PRINT   s_spd
        stz     VAL
        stz     VAL+1
        ldx     mic_sp
        beq     mi_s0
mi_sl:  lda     #10
        jsr     val_add
        dex
        bne     mi_sl
mi_s0:  lda     mic_dc
        jsr     val_add
        lda     #<800
        ldx     #>800
        jsr     val_wrap
        jsr     pnum_val
        PRINT   s_kt
        jsr     crlf

        PRINT   s_mice                  ; message
        lda     msg_cust
        beq     mi_stdm
        PRINT   s_custom
        lda     #7
        sec
        sbc     msg_bits
        ora     #'0'
        jsr     putc
        bra     mi_mend
mi_stdm:
        lda     msg_bits
        asl     a
        tax
        ldy     mice_msgs+1,x
        lda     mice_msgs,x
        tax
        jsr     puts_k
mi_mend:
        jsr     crlf

        lda     #9                      ; altitude "xxx}" near the comment start
        ldy     #12
        lda     (IP),y
        cmp     #'}'
        beq     mi_alt9
        iny
        lda     (IP),y
        cmp     #'}'
        bne     mi_cmt
        lda     #10
        bra     mi_alt
mi_alt9:
        lda     #9
mi_alt: jsr     cur_ip_a                ; CUR = IP + A
        PRINT   s_alt
        lda     #3
        jsr     b91_n
        sec                             ; meters = value - 10000
        lda     N32
        sbc     #<10000
        sta     N32
        lda     N32+1
        sbc     #>10000
        sta     N32+1
        lda     N32+2
        sbc     #0
        sta     N32+2
        bcs     mi_apos
        lda     #'-'                    ; below sea level
        jsr     putc
        sec
        lda     #0
        sbc     N32
        sta     N32
        lda     #0
        sbc     N32+1
        sta     N32+1
        stz     N32+2
mi_apos:
        stz     N32+3
        jsr     print_u32
        PRINT   s_m
        jsr     crlf
mi_cmt: lda     #9
        jsr     cur_ip_a
        jmp     print_comment

mi_c1:  pha                             ; custom message bit
        lda     #1
        sta     msg_cust
        pla
mi_s1:  pha                             ; message bit for chars 0-2
        cpy     #3
        bcs     mi_s1x
        lda     mi_bit,y
        ora     msg_bits
        sta     msg_bits
mi_s1x: pla
        rts
mi_bit: db      4,2,1

bad_mice:
        PRINT   s_badmic
        PRINT   DESTBUF
        jmp     crlf

mice_msgs:
        dw      s_mm0,s_mm1,s_mm2,s_mm3,s_mm4,s_mm5,s_mm6,s_mm7

; VAL += A
val_add:
        clc
        adc     VAL
        sta     VAL
        bcc     va_r
        inc     VAL+1
va_r:   rts

; if VAL >= X:A then VAL -= X:A
val_wrap:
        sta     TMP
        stx     TMP2
        lda     VAL+1
        cmp     TMP2
        bcc     vw_r
        bne     vw_sub
        lda     VAL
        cmp     TMP
        bcc     vw_r
vw_sub: sec
        lda     VAL
        sbc     TMP
        sta     VAL
        lda     VAL+1
        sbc     TMP2
        sta     VAL+1
vw_r:   rts

;---------------------------------------------------------------------------
; Comment / bad data
;---------------------------------------------------------------------------
print_comment:
        lda     (CUR)
        beq     pcm_none
        PRINT   s_cmt
        jsr     puts_cur
        jsr     crlf
        jmp     find_alt                ; /A=nnnnnn altitude in feet
pcm_none:
        rts

find_alt:
        ldy     #0
fa_lp:  lda     (CUR),y
        beq     fa_no
        cmp     #'/'
        bne     fa_nx
        iny
        lda     (CUR),y
        dey
        cmp     #'A'
        bne     fa_nx
        iny
        iny
        lda     (CUR),y
        dey
        dey
        cmp     #'='
        bne     fa_nx
        tya
        clc
        adc     #3
        jsr     adv
        PRINT   s_alt
        lda     #6
        jsr     putn_cur
        PRINT   s_ft
        jmp     crlf
fa_nx:  iny
        bne     fa_lp
fa_no:  rts

bad_data:
        PRINT   s_bad
        jsr     cur_ip
        jsr     puts_cur
        jmp     crlf

;---------------------------------------------------------------------------
; Stats
;---------------------------------------------------------------------------
show_stats:
        PRINT   s_st1
        lda     pkt_count
        ldx     pkt_count+1
        jsr     pnum16
        PRINT   s_st2
        lda     rx_err
        ldx     rx_err+1
        jsr     pnum16
        PRINT   s_st3
        lda     rx_ovf
        ldx     rx_ovf+1
        jsr     pnum16
        PRINT   s_st4
        lda     line_ovf
        ldx     line_ovf+1
        jsr     pnum16
        jmp     crlf

;---------------------------------------------------------------------------
; Pointer helpers
;---------------------------------------------------------------------------
cur_ip: lda     #0
cur_ip_a:                               ; CUR = IP + A
        clc
        adc     IP
        sta     CUR
        lda     IP+1
        adc     #0
        sta     CUR+1
        rts
cur_ip1:
        lda     #1
        bra     cur_ip_a

inc_cur:
        inc     CUR
        bne     ic_r
        inc     CUR+1
ic_r:   rts

; CUR += A
adv:    clc
        adc     CUR
        sta     CUR
        bcc     adv_r
        inc     CUR+1
adv_r:  rts

inc_tptr:
        inc     TPTR
        bne     it_r
        inc     TPTR+1
it_r:   rts

; C=1 if any of the first A bytes at IP / CUR is NUL
need_ip:
        tay
ni_lp:  dey
        lda     (IP),y
        beq     ni_short
        cpy     #0
        bne     ni_lp
        clc
        rts
ni_short:
        sec
        rts

need_cur:
        tay
nc_lp:  dey
        lda     (CUR),y
        beq     nc_short
        cpy     #0
        bne     nc_lp
        clc
        rts
nc_short:
        sec
        rts

;---------------------------------------------------------------------------
; Output helpers
;---------------------------------------------------------------------------
; puts_k: print the NUL-terminated string at Y:X
puts_k: stx     SPTR
        sty     SPTR+1
puts_sp:
        ldy     #0
ps_lp:  lda     (SPTR),y
        beq     ps_d
        jsr     putc
        iny
        bne     ps_lp
        inc     SPTR+1
        bra     ps_lp
ps_d:   rts

; puts_cur: print the string at CUR (CUR unchanged)
puts_cur:
        lda     CUR
        sta     SPTR
        lda     CUR+1
        sta     SPTR+1
        bra     puts_sp

; putn_cur: print A chars from CUR (stops early at NUL). CUR advanced.
putn_cur:
        sta     CNT
pn_lp:  lda     (CUR)
        beq     pn_d
        jsr     putc
        jsr     inc_cur
        dec     CNT
        bne     pn_lp
pn_d:   rts

; putn_trim: print A chars at CUR without trailing spaces; CUR += A
putn_trim:
        sta     CNT
        tay
pt_bk:  cpy     #0
        beq     pt_pr
        dey
        lda     (CUR),y
        cmp     #' '
        beq     pt_bk
        iny
pt_pr:  sty     TMP                     ; print this many
        ldy     #0
pt_lp:  cpy     TMP
        bcs     pt_d
        lda     (CUR),y
        jsr     putc
        iny
        bra     pt_lp
pt_d:   lda     CNT
        jmp     adv

crlf:   lda     #$0D
        jsr     putc
        lda     #$0A
        jmp     putc

space:  lda     #' '
        jmp     putc

; put_a: A as decimal, X digits wide
put_a:  stx     WIDTH
        ldx     #0
; pnum16: X:A as unsigned decimal
pnum16: sta     N32
        stx     N32+1
        stz     N32+2
        stz     N32+3
        jmp     print_u32

pnum_val:
        lda     VAL
        ldx     VAL+1
        bra     pnum16

; print_2dec: N32 (0-9999) as "n.hh". WIDTH sets the integer part width.
print_2dec:
        lda     #100
        jsr     set_d
        jsr     div32
        lda     R32
        sta     VAL                     ; print_u32 overwrites R32
        jsr     print_u32
        lda     #'.'
        jsr     putc
        lda     #2
        sta     WIDTH
        lda     VAL
        ldx     #0
        jmp     pnum16

set_d10:
        lda     #10
set_d:  sta     D32
        stz     D32+1
        stz     D32+2
        stz     D32+3
        rts

; print_u32: N32 as decimal, zero padded to WIDTH digits. WIDTH reset to 0.
print_u32:
        phx
        phy
        ldy     #0
pu_lp:  jsr     set_d10
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
        ply
        plx
        rts

;---------------------------------------------------------------------------
; 32-bit math
;---------------------------------------------------------------------------
; div32: N32 / D32 -> quotient in N32, remainder in R32. Keeps X, Y.
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

; mul32: P32 = M32 * M16 (low 32 bits). M32 and M16 destroyed. Keeps X, Y.
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
; Tables and strings
;---------------------------------------------------------------------------
; compressed speed: round(1.08^n - 1) knots, n = 0..89
spd_tab:
        dw      0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,3,3,3
        dw      4,4,4,5,5,6,6,7,8,8,9,10,11,12,13,14,15,16,18,19
        dw      21,22,24,26,29,31,33,36,39,42,46,50,54,58,63,68,73,79,86,93
        dw      100,108,117,127,137,148,160,173,186,201,218,235,254,274,296,320,346,374,404,436
        dw      471,509,549,594,641,692,748,808,873,942

; primary symbol table names
sym_tab:
        db      '!','police',0
        db      '#','digipeater',0
        db      '$','phone',0
        db      '%','DX cluster',0
        db      '&','HF gateway',0
        db      $27,'small aircraft',0
        db      '(','mobile satellite',0
        db      '*','snowmobile',0
        db      '+','Red Cross',0
        db      ',','Boy Scouts',0
        db      '-','house',0
        db      '.','X',0
        db      '/','dot',0
        db      ':','fire',0
        db      ';','campground',0
        db      '<','motorcycle',0
        db      '=','railroad engine',0
        db      '>','car',0
        db      '?','file server',0
        db      '@','hurricane',0
        db      'A','aid station',0
        db      'B','BBS',0
        db      'C','canoe',0
        db      'E','eyeball',0
        db      'F','tractor',0
        db      'G','grid square',0
        db      'H','hotel',0
        db      'I','TCP/IP',0
        db      'K','school',0
        db      'L','PC user',0
        db      'M','MacAPRS',0
        db      'N','NTS station',0
        db      'O','balloon',0
        db      'P','police',0
        db      'R','RV',0
        db      'S','shuttle',0
        db      'T','SSTV',0
        db      'U','bus',0
        db      'V','ATV',0
        db      'W','NWS site',0
        db      'X','helicopter',0
        db      'Y','sailboat',0
        db      'Z','WinAPRS',0
        db      '[','jogger',0
        db      $5C,'DF triangle',0
        db      ']','mailbox',0
        db      '^','large aircraft',0
        db      '_','weather station',0
        db      '`','dish antenna',0
        db      'a','ambulance',0
        db      'b','bicycle',0
        db      'c','incident command',0
        db      'd','fire dept',0
        db      'e','horse',0
        db      'f','fire truck',0
        db      'g','glider',0
        db      'h','hospital',0
        db      'i','IOTA',0
        db      'j','jeep',0
        db      'k','truck',0
        db      'l','laptop',0
        db      'm','Mic-E repeater',0
        db      'n','node',0
        db      'o','EOC',0
        db      'p','rover',0
        db      'q','grid square',0
        db      'r','repeater',0
        db      's','ship',0
        db      't','truck stop',0
        db      'u','semi truck',0
        db      'v','van',0
        db      'w','water station',0
        db      'x','xAPRS',0
        db      'y','house w/ yagi',0
        db      0

s_banner:
        db      $0D,$0A,'APRS receive - PK-232 on ACIA_B (J4 pin 44)',$0D,$0A
        db      'ESC = stop   R = raw lines on/off   S = stats',$0D,$0A,0
s_bye:  db      $0D,$0A,'APRS receive stopped.',$0D,$0A,0
s_rawon:
        db      $0D,$0A,'[raw on]',$0D,$0A,0
s_rawoff:
        db      $0D,$0A,'[raw off]',$0D,$0A,0
s_raw:  db      '  raw| ',0
s_tnc:  db      'TNC| ',0
s_arrow:
        db      ' > ',0
s_via:  db      ' via ',0
s_time: db      '  Time   ',0
s_pos:  db      '  Pos    ',0
s_sym:  db      '  Sym    ',0
s_symalt:
        db      '(alternate/overlay)',0
s_crs:  db      '  Course ',0
s_spd:  db      '  Speed ',0
s_kt:   db      ' kt',0
s_wx:   db      '  WX    ',0
s_wind: db      ' Wind ',0
s_wdir: db      ' WindDir ',0
s_wspd: db      ' Wind ',0
s_gust: db      ' Gust ',0
s_temp: db      ' Temp ',0
s_rain1:
        db      ' Rain1h ',0
s_rain24:
        db      ' Rain24h ',0
s_rainm:
        db      ' RainToday ',0
s_hum:  db      ' Hum ',0
s_baro: db      ' Baro ',0
s_lum:  db      ' Lum ',0
s_snow: db      ' Snow ',0
s_deg:  db      'deg',0
s_mph:  db      'mph',0
s_degf: db      'F',0
s_in:   db      'in',0
s_pct:  db      '%',0
s_mb:   db      'mb',0
s_wm2:  db      'W/m2',0
s_phgl: db      '  PHG    ',0
s_rngl: db      '  Range  ',0
s_dfsl: db      '  DFS    ',0
s_cmt:  db      '  Cmt    ',0
s_alt:  db      '  Alt    ',0
s_ft:   db      ' ft',0
s_m:    db      ' m',0
s_bad:  db      '  ?? bad/unknown format: ',0
s_msgto:
        db      '  Msg to ',0
s_bln:  db      '  Bulletin ',0
s_text: db      '  Text   ',0
s_msgid:
        db      '  Msg ID ',0
s_ackl: db      '  ACK    id ',0
s_rejl: db      '  REJECT id ',0
s_obj:  db      '  Object ',0
s_item: db      '  Item   ',0
s_live: db      ' (live)',0
s_killed:
        db      ' (killed)',0
s_status:
        db      '  Status ',0
s_third:
        db      '  Third-party packet:',0
s_mice: db      '  Mic-E  ',0
s_custom:
        db      'Custom-',0
s_badmic:
        db      '  ?? bad Mic-E destination: ',0
s_mm0:  db      'Emergency!',0
s_mm1:  db      'Priority',0
s_mm2:  db      'Special',0
s_mm3:  db      'Committed',0
s_mm4:  db      'Returning',0
s_mm5:  db      'In Service',0
s_mm6:  db      'En Route',0
s_mm7:  db      'Off Duty',0
s_t_unk:
        db      '  Other  ',0
s_t_tel:
        db      '  Telemetry ',0
s_t_cap:
        db      '  Capabilities ',0
s_t_qry:
        db      '  Query  ',0
s_t_nmea:
        db      '  GPS    ',0
s_t_peet:
        db      '  WX (Peet Bros) ',0
s_t_user:
        db      '  User-defined ',0
s_st1:  db      $0D,$0A,'pkts ',0
s_st2:  db      '  uart errors ',0
s_st3:  db      '  buffer overflows ',0
s_st4:  db      '  long lines ',0

        ENDS
        END
