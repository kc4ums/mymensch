;***************************************************************************
;  FILE:   aprsrx.asm
;  TITLE:  APRS receive-only interface: AEA PK-232 -> W65C265S (MyMensch)
;
;  The PK-232 is in plain text (monitor) mode and prints every packet it
;  hears as a line like
;
;      KC4UMS-9>APRS,WIDE1-1,WIDE2-1*:!3500.00N/08500.00W>Mobile
;
;  This program reads those lines on UART0 and prints a decoded version
;  on the Mensch Monitor console (UART3 / USB).
;
;  Hardware
;    UART0 RXD0 = P60  <- MAX232 R1OUT <- PK-232 DB25 pin 3 (TXD out)
;    Do NOT wire RS-232 straight to P60; it needs a level converter.
;
;  Receive path
;    The monitor ROM owns the UART interrupt vectors, so UART0's own
;    interrupt is left off. Timer 7 (vectored through RAM at $011C) fires
;    about 4000 times a second, polls the UART0 receive flag, and puts each
;    byte into a 2 KB ring buffer. The main loop decodes from that buffer,
;    so bytes are not lost while the console is busy printing.
;
;  Run it from the monitor with   J002000   (or G002000).
;  Console keys:  ESC = exit to monitor   R = raw lines on/off   S = stats
;
;  Build: mk_aprsrx.bat  (WDC816AS + WDCLN, makes aprsrx.s28 / aprsrx.bin)
;***************************************************************************

        PW      132
        CHIP    65816
        LONGA   OFF
        LONGI   ON

;---------------------------------------------------------------------------
; Configuration
;---------------------------------------------------------------------------
; TNC_BAUD selects how fast UART0 runs:
;   0 = same rate as the monitor console (the monitor's Timer 4, normally 9600)
;   1 = 1200   2 = 2400   3 = 4800   4 = 9600   5 = 19200  (uses Timer 3)
TNC_BAUD        EQU     0

T7_RELOAD       EQU     921             ; 3.6864 MHz / 921 = ~4 kHz poll rate

;---------------------------------------------------------------------------
; W65C265S registers
;---------------------------------------------------------------------------
TCR             EQU     $DF42           ; timer control (UART timer select)
TER             EQU     $DF43           ; timer enable
TIFR            EQU     $DF44           ; timer interrupt flags (write 1 = clear)
TIER            EQU     $DF46           ; timer interrupt enable
UIFR            EQU     $DF48           ; UART interrupt flags (write 1 = clear)
UIER            EQU     $DF49           ; UART interrupt enable
T3LL            EQU     $DF56
T3LH            EQU     $DF57
T7LL            EQU     $DF5E
T7LH            EQU     $DF5F
T3CL            EQU     $DF66
T3CH            EQU     $DF67
T7CL            EQU     $DF6E
T7CH            EQU     $DF6F
ACSR0           EQU     $DF70           ; UART0 control/status
ARTD0           EQU     $DF71           ; UART0 data

MON_SPEED       EQU     $DFB5           ; monitor's FCLK index (0..4)
UNIRQT7         EQU     $011C           ; monitor RAM vector for Timer 7 (JML xx)

;---------------------------------------------------------------------------
; Mensch Monitor ROM entry points (JSL)
;---------------------------------------------------------------------------
GET_BYTE_FROM_PC EQU    $00E033         ; console in, C=1 if nothing waiting
PUT_CHR         EQU     $00E04B         ; console out, char in A (8 bit)

;---------------------------------------------------------------------------
; Memory
;---------------------------------------------------------------------------
RXSIZE          EQU     $0800           ; 2 KB receive ring
RXBUF           EQU     $5000
LINEBUF         EQU     $5800           ; current line from the TNC
HDRBUF          EQU     $5900           ; saved header (HEADERLN ON mode)
DESTBUF         EQU     $5A00           ; destination call (for Mic-E)
DIGBUF          EQU     $5A20           ; decimal digit scratch
LATSTR          EQU     $5A40           ; Mic-E latitude digits
LINEMAX         EQU     250

; Working variables (absolute, bank 0)
rx_head         EQU     $5B00           ; written only by the ISR
rx_tail         EQU     $5B02           ; written only by the main loop
line_len        EQU     $5B04
pkt_count       EQU     $5B06
rx_err          EQU     $5B08           ; UART framing/overrun errors
rx_ovf          EQU     $5B0A           ; ring buffer overflows
line_ovf        EQU     $5B0C           ; lines longer than LINEMAX
pending_hdr     EQU     $5B0E
raw_mode        EQU     $5B0F
save_vec        EQU     $5B10           ; 4 bytes: monitor's $011C contents
save_acsr0      EQU     $5B14
save_tcr        EQU     $5B15
save_ter        EQU     $5B16
save_sp         EQU     $5B18
br_depth        EQU     $5B1A
gt_seen         EQU     $5B1C
wx_mode         EQU     $5B1D           ; 1 = positionless weather report
msg_bits        EQU     $5B1E
msg_cust        EQU     $5B1F
mic_off         EQU     $5B20           ; longitude +100 flag
mic_ns          EQU     $5B21
mic_ew          EQU     $5B22

; Direct page (internal RAM $C0-$FF is free for user programs)
N32             EQU     $C0             ; number / dividend / quotient
D32             EQU     $C4             ; divisor
R32             EQU     $C8             ; remainder
M32             EQU     $CC             ; multiplicand
P32             EQU     $D0             ; product
M16             EQU     $D4             ; multiplier
T32             EQU     $D6
IP              EQU     $DA             ; info field pointer
HP              EQU     $DC             ; header pointer
TMP             EQU     $DE
TMP2            EQU     $E0
WIDTH           EQU     $E2             ; zero-pad width for print_u32 (16 bit)
CNT             EQU     $E4
SYMT            EQU     $E5             ; symbol table char
SYMC            EQU     $E6             ; symbol code char
DIVK            EQU     $E8             ; coordinate divisor (4 bytes)
DEGW            EQU     $EC             ; degree digits (2 or 3)
HEMI            EQU     $ED             ; hemisphere letter
FSIGN           EQU     $EE
FMT             EQU     $EF
VAL             EQU     $F0             ; parsed field value (16 bit)

;***************************************************************************
        CODE
        ORG     $2000

START:
        sei
        clc
        xce                             ; native mode
        sep     #$20
        LONGA   OFF
        rep     #$10
        LONGI   ON
        phk
        plb                             ; DB = 0
        pea     $0000
        pld                             ; D = 0

        tsx
        stx     save_sp
        ldx     #$7EFF                  ; own stack; the monitor's is only 64 bytes
        txs

        jsr     init_vars
        jsr     uart0_init
        jsr     t7_init
        cli

        ldx     #s_banner
        jsr     puts

;---------------------------------------------------------------------------
; Main loop
;---------------------------------------------------------------------------
main_loop:
        jsr     rx_get
        bcs     ml_key
        jsr     line_char
ml_key:
        jsl     GET_BYTE_FROM_PC
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
        ldx     #s_rawon
        lda     raw_mode
        bne     ml_raw1
        ldx     #s_rawoff
ml_raw1:
        jsr     puts
        bra     main_loop

quit:
        jsr     shutdown
        ldx     #s_bye
        jsr     puts
        ldx     save_sp
        txs
        brk                             ; back to the monitor
        db      $00

;---------------------------------------------------------------------------
init_vars:
        ldx     #0
        stx     rx_head
        stx     rx_tail
        stx     line_len
        stx     pkt_count
        stx     rx_err
        stx     rx_ovf
        stx     line_ovf
        stx     WIDTH
        stz     pending_hdr
        stz     raw_mode
        rts

;---------------------------------------------------------------------------
; UART0: receiver on, 8 data bits, no parity, transmitter off.
; 7E1 from the TNC also frames correctly; the parity bit is masked later.
;---------------------------------------------------------------------------
uart0_init:
        lda     ACSR0
        sta     save_acsr0
        lda     TCR
        sta     save_tcr
        lda     TER
        sta     save_ter
        lda     #$03
        trb     UIER                    ; UART0 interrupts stay off (we poll)

        IF      TNC_BAUD
        lda     MON_SPEED               ; FCLK index 0..4 from the monitor
        cmp     #5
        bcc     u0_spd_ok
        lda     #2                      ; assume 3.6864 MHz
u0_spd_ok:
        rep     #$20
        LONGA   ON
        and     #$00FF
        sta     TMP
        asl     a
        asl     a
        clc
        adc     TMP                     ; *5 entries per crystal
        clc
        adc     #TNC_BAUD-1
        asl     a                       ; word table
        tax
        lda     baud_tab,x
        sep     #$20
        LONGA   OFF
        sta     T3LL
        sta     T3CL
        xba
        sta     T3LH
        sta     T3CH
        lda     #$08
        tsb     TER                     ; Timer 3 on
        lda     #$10
        trb     TCR                     ; UART0 <- Timer 3
        ELSE
        lda     #$10
        tsb     TCR                     ; UART0 <- Timer 4 (console rate)
        ENDIF

        lda     #$A4                    ; clear error, RX on, 8 bit
        sta     ACSR0
        lda     ARTD0                   ; flush
        lda     #$01
        sta     UIFR
        rts

        IF      TNC_BAUD
; Timer 3 values (datasheet table 2.9.6-1): 1200 2400 4800 9600 19200
baud_tab:
        dw      $005F,$002F,$0017,$000B,$0005   ; 1.8432 MHz
        dw      $007F,$003F,$001F,$000F,$0007   ; 2.4576 MHz
        dw      $00BF,$005F,$002F,$0017,$000B   ; 3.6864 MHz
        dw      $00FF,$007F,$003F,$001F,$000F   ; 4.9152 MHz
        dw      $013F,$009F,$004F,$0027,$0013   ; 6.1440 MHz
        ENDIF

;---------------------------------------------------------------------------
; Timer 7: periodic interrupt that polls UART0
;---------------------------------------------------------------------------
t7_init:
        ldx     #0
t7_sv:  lda     UNIRQT7,x
        sta     save_vec,x
        inx
        cpx     #4
        bne     t7_sv
        lda     #$5C                    ; JML t7_isr
        sta     UNIRQT7
        rep     #$20
        LONGA   ON
        lda     #t7_isr
        sta     UNIRQT7+1
        lda     #T7_RELOAD
        sta     T7LL
        sta     T7CL
        sep     #$20
        LONGA   OFF
        lda     #^t7_isr
        sta     UNIRQT7+3
        lda     #$80
        sta     TIFR                    ; clear stale flag
        tsb     TIER
        tsb     TER
        rts

shutdown:
        sei
        lda     #$80
        trb     TIER
        lda     save_ter
        sta     TER
        lda     save_tcr
        sta     TCR
        lda     save_acsr0
        sta     ACSR0
        lda     #$80
        sta     TIFR
        ldx     #0
sd_lp:  lda     save_vec,x
        sta     UNIRQT7,x
        inx
        cpx     #4
        bne     sd_lp
        cli
        rts

;---------------------------------------------------------------------------
; Timer 7 ISR. Entered through the monitor's JML at $011C, any M/X state.
;---------------------------------------------------------------------------
t7_isr:
        rep     #$30
        LONGA   ON
        pha
        phx
        phb
        phd
        lda     #0
        tcd
        sep     #$20
        LONGA   OFF
        pha
        plb                             ; DB = 0 (A is 0 here)
        lda     #$80
        sta     TIFR                    ; acknowledge Timer 7
        lda     UIFR
        lsr     a
        bcc     isr_done                ; no byte waiting
        lda     #$01
        sta     UIFR                    ; acknowledge before reading the data
        lda     ACSR0
        bpl     isr_ok
        sta     ACSR0                   ; writing bit 7 = 1 clears the error
        rep     #$20
        LONGA   ON
        inc     rx_err
        sep     #$20
        LONGA   OFF
isr_ok:
        lda     ARTD0
        ldx     rx_head
        sta     RXBUF,x
        inx
        cpx     #RXSIZE
        bcc     isr_nw
        ldx     #0
isr_nw:
        cpx     rx_tail
        beq     isr_full
        stx     rx_head
        bra     isr_done
isr_full:
        rep     #$20
        LONGA   ON
        inc     rx_ovf
isr_done:
        rep     #$30
        LONGA   ON
        pld
        plb
        plx
        pla
        rti
        LONGA   OFF

;---------------------------------------------------------------------------
; rx_get: next byte from the ring. C=0 and byte in A, or C=1 if empty.
;---------------------------------------------------------------------------
rx_get:
        ldx     rx_tail
        cpx     rx_head
        beq     rg_empty
        lda     RXBUF,x
        inx
        cpx     #RXSIZE
        bcc     rg_nw
        ldx     #0
rg_nw:  stx     rx_tail
        clc
        rts
rg_empty:
        sec
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
        inx
        stx     line_len
lc_ret: rts
lc_long:
        cpx     #LINEMAX
        bne     lc_ret
        inx                             ; count each long line once
        stx     line_len
        rep     #$20
        LONGA   ON
        inc     line_ovf
        sep     #$20
        LONGA   OFF
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
        ldx     #0
        stx     line_len
        rts

;---------------------------------------------------------------------------
; process_line: split a monitored line into header and info.
;---------------------------------------------------------------------------
process_line:
        lda     raw_mode
        beq     pl_noraw
        ldx     #s_raw
        jsr     puts
        ldx     #LINEBUF
        jsr     puts
        jsr     crlf
pl_noraw:
        lda     pending_hdr
        beq     pl_scan
        stz     pending_hdr             ; HEADERLN ON: this line is the info
        ldx     #HDRBUF
        stx     HP
        ldx     #LINEBUF
        stx     IP
        jmp     decode_packet

pl_scan:
        ldx     #0
        stx     br_depth
        stz     gt_seen
        ldx     #LINEBUF
pl_lp:  lda     !0,x
        beq     pl_tnc
        cmp     #'['
        beq     pl_open
        cmp     #']'
        beq     pl_close
        ldy     br_depth
        bne     pl_nx                   ; ignore text inside [ ] (MSTAMP)
        cmp     #'>'
        bne     pl_n3
        sta     gt_seen
pl_n3:  cmp     #':'
        beq     pl_colon
pl_nx:  inx
        bra     pl_lp
pl_open:
        ldy     #1
        sty     br_depth
        bra     pl_nx
pl_close:
        ldy     #0
        sty     br_depth
        bra     pl_nx

pl_colon:
        lda     gt_seen
        beq     pl_tnc                  ; "cmd:" etc. -> not a packet
        inx
        stx     IP
        ldx     #LINEBUF
        stx     HP
        ldx     IP
        lda     !0,x
        beq     pl_hdronly
        jmp     decode_packet
pl_hdronly:                             ; info comes on the next line
        ldx     #0
pl_cp:  lda     LINEBUF,x
        sta     HDRBUF,x
        beq     pl_cpd
        inx
        bra     pl_cp
pl_cpd: lda     #1
        sta     pending_hdr
        rts

pl_tnc: ldx     #s_tnc
        jsr     puts
        ldx     #LINEBUF
        jsr     puts
        jmp     crlf

;---------------------------------------------------------------------------
; decode_packet: HP -> header, IP -> info field
;---------------------------------------------------------------------------
decode_packet:
        jsr     crlf
        rep     #$20
        LONGA   ON
        inc     pkt_count
        sep     #$20
        LONGA   OFF
        lda     #'#'
        jsl     PUT_CHR
        lda     #4
        sta     WIDTH
        ldx     pkt_count
        jsr     pnum_x
        lda     #' '
        jsl     PUT_CHR
        jsr     print_header
        jsr     crlf

        ldx     IP
dp_sk:  lda     !0,x                    ; skip leading spaces
        cmp     #' '
        bne     dp_go
        inx
        bra     dp_sk
dp_go:  stx     IP
        ldy     #0
dp_lp:  lda     dti_table,y
        beq     dp_unk
        cmp     !0,x
        beq     dp_hit
        iny
        iny
        iny
        bra     dp_lp
dp_hit: rep     #$20
        LONGA   ON
        lda     dti_table+1,y
        sta     TMP
        sep     #$20
        LONGA   OFF
        jmp     (TMP)
dp_unk: ldx     #s_t_unk
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
        ldx     #s_t_tel
        bra     do_labeled
do_caps:
        ldx     #s_t_cap
        bra     do_labeled
do_query:
        ldx     #s_t_qry
        bra     do_labeled
do_nmea:
        ldx     #s_t_nmea
        bra     do_labeled
do_peet:
        ldx     #s_t_peet
        bra     do_labeled
do_user:
        ldx     #s_t_user

; print "  <label>" and the info field as-is
do_labeled:
        jsr     puts
        ldx     IP
        jsr     puts
        jmp     crlf

;---------------------------------------------------------------------------
; print_header: "SRC > DEST via DIGI1,DIGI2*", copies DEST to DESTBUF
;---------------------------------------------------------------------------
print_header:
        ldx     HP
ph_src: lda     !0,x
        beq     ph_end
        cmp     #':'
        beq     ph_end
        cmp     #'>'
        beq     ph_gt
        jsl     PUT_CHR
        inx
        bra     ph_src
ph_gt:  inx
        phx
        ldx     #s_arrow
        jsr     puts
        plx
        ldy     #0
ph_dst: lda     !0,x
        jsr     hdr_term
        bcs     ph_dend
        jsl     PUT_CHR
        cpy     #15
        bcs     ph_dnx
        sta     DESTBUF,y
        iny
ph_dnx: inx
        bra     ph_dst
ph_dend:
        pha
        lda     #0
        sta     DESTBUF,y
        pla
        cmp     #','
        beq     ph_path
        cmp     #'>'
        bne     ph_end
ph_path:
        phx
        ldx     #s_via
        jsr     puts
        plx
        inx
ph_pl:  lda     !0,x
        cmp     #','
        beq     ph_sep
        cmp     #'>'
        beq     ph_sep
        jsr     hdr_term
        bcs     ph_end
        jsl     PUT_CHR
        inx
        bra     ph_pl
ph_sep: lda     #','
        jsl     PUT_CHR
        inx
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
        ldx     #s_time
        jsr     puts
        ldx     IP
        inx
        ldy     #7
        jsr     putn
        jsr     crlf
        bra     dpos_go
do_pos:
        ldx     IP
        inx
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
; decode_position: X -> position (uncompressed or compressed).
; Prints it, sets SYMT/SYMC, returns X past it. C=1 if not valid.
;---------------------------------------------------------------------------
decode_position:
        lda     !0,x
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

; DDMM.hhN/DDDMM.hhW>
pos_unc:
        lda     !4,x
        cmp     #'.'
        bne     pu_bad
        lda     !14,x
        cmp     #'.'
        bne     pu_bad
        lda     !7,x
        and     #$DF
        cmp     #'N'
        beq     pu_ns
        cmp     #'S'
        bne     pu_bad
pu_ns:  lda     !17,x
        and     #$DF
        cmp     #'E'
        beq     pu_ew
        cmp     #'W'
        beq     pu_ew
pu_bad: sec
        rts
pu_ew:  phx
        ldx     #s_pos
        jsr     puts
        plx
        ldy     #2
        jsr     putn                    ; DD
        jsr     space
        ldy     #6
        jsr     putn                    ; MM.hhN
        lda     !0,x
        sta     SYMT
        inx
        jsr     space
        jsr     space
        ldy     #3
        jsr     putn                    ; DDD
        jsr     space
        ldy     #6
        jsr     putn                    ; MM.hhW
        lda     !0,x
        sta     SYMC
        inx
        jsr     crlf
        clc
        rts

; Compressed: T YYYY XXXX C cs t  (13 chars, base 91)
pos_cmp:
        phx                             ; check length and the base-91 digits
        ldy     #12
pcv_lp: inx
        lda     !0,x
        beq     pcv_bad
        cpy     #5
        bcc     pcv_nx                  ; symbol, cs, type: any char
        cmp     #'!'
        bcc     pcv_bad
        cmp     #'{'+1
        bcs     pcv_bad
pcv_nx: dey
        bne     pcv_lp
        plx
        bra     pcv_ok
pcv_bad:
        plx
        sec
        rts
pcv_ok: lda     !0,x
        sta     SYMT
        inx
        phx
        ldx     #s_pos
        jsr     puts
        plx
        jsr     b91_4                   ; N32 = y
        phx
        rep     #$20
        LONGA   ON
        lda     #$1F4C                  ; v = 90*380926 - y
        sec
        sbc     N32
        sta     T32
        lda     #$020B
        sbc     N32+2
        sta     T32+2
        bcs     pc_n
        lda     N32                     ; south: v = y - 90*380926
        sec
        sbc     #$1F4C
        sta     T32
        lda     N32+2
        sbc     #$020B
        sta     T32+2
        ldy     #'S'
        bra     pc_lat
pc_n:   ldy     #'N'
pc_lat: lda     T32
        sta     N32
        lda     T32+2
        sta     N32+2
        lda     #$CFFE                  ; 380926
        sta     DIVK
        lda     #$0005
        sta     DIVK+2
        sep     #$20
        LONGA   OFF
        tya
        sta     HEMI
        lda     #2
        sta     DEGW
        jsr     coord_out
        jsr     space
        jsr     space
        plx
        jsr     b91_4                   ; N32 = x
        phx
        rep     #$20
        LONGA   ON
        lda     N32                     ; v = x - 180*190463
        sec
        sbc     #$1F4C
        sta     T32
        lda     N32+2
        sbc     #$020B
        sta     T32+2
        bcs     pc_e
        lda     #$1F4C                  ; west: v = 180*190463 - x
        sec
        sbc     N32
        sta     T32
        lda     #$020B
        sbc     N32+2
        sta     T32+2
        ldy     #'W'
        bra     pc_lon
pc_e:   ldy     #'E'
pc_lon: lda     T32
        sta     N32
        lda     T32+2
        sta     N32+2
        lda     #$E7FF                  ; 190463
        sta     DIVK
        lda     #$0002
        sta     DIVK+2
        sep     #$20
        LONGA   OFF
        tya
        sta     HEMI
        lda     #3
        sta     DEGW
        jsr     coord_out
        jsr     crlf
        plx
        lda     !0,x
        sta     SYMC
        ; course/speed bytes
        lda     !1,x
        cmp     #' '
        beq     pc_done
        lda     !3,x
        sec
        sbc     #33
        and     #$18
        cmp     #$10
        beq     pc_done                 ; altitude form, not decoded yet
        lda     !1,x
        cmp     #'{'
        beq     pc_done                 ; radio range form
        cmp     #'!'
        bcc     pc_done
        cmp     #'z'+1
        bcs     pc_done
        phx
        ldx     #s_crs
        jsr     puts
        plx
        lda     !1,x                    ; course = (c-33)*4
        sec
        sbc     #33
        rep     #$20
        LONGA   ON
        and     #$00FF
        asl     a
        asl     a
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        lda     #3
        sta     WIDTH
        jsr     print_u32
        phx
        ldx     #s_spd
        jsr     puts
        plx
        lda     !2,x                    ; speed = 1.08^(s-33)-1 knots
        sec
        sbc     #33
        cmp     #90
        bcc     pc_sok
        lda     #89
pc_sok: rep     #$20
        LONGA   ON
        and     #$00FF
        asl     a
        tay
        lda     spd_tab,y
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        jsr     print_u32
        phx
        ldx     #s_kt
        jsr     puts
        plx
        jsr     crlf
pc_done:
        rep     #$20
        LONGA   ON
        txa
        clc
        adc     #4
        tax
        sep     #$20
        LONGA   OFF
        clc
        rts

; b91_4: N32 = 4 base-91 digits at X, X += 4
b91_4:
        lda     #4
        sta     CNT
        rep     #$20
        LONGA   ON
        stz     N32
        stz     N32+2
b91_lp: lda     N32
        sta     M32
        lda     N32+2
        sta     M32+2
        lda     #91
        sta     M16
        jsr     mul32
        lda     !0,x
        and     #$00FF
        sec
        sbc     #33
        clc
        adc     P32
        sta     N32
        lda     P32+2
        adc     #0
        sta     N32+2
        inx
        sep     #$20
        LONGA   OFF
        dec     CNT
        rep     #$20
        LONGA   ON
        bne     b91_lp
        sep     #$20
        LONGA   OFF
        rts

; coord_out: N32 = coordinate in 1/DIVK degree units.
; Prints "DD MM.hhH" with DEGW degree digits and HEMI letter.
coord_out:
        phx
        rep     #$20
        LONGA   ON
        lda     DIVK
        sta     D32
        lda     DIVK+2
        sta     D32+2
        sep     #$20
        LONGA   OFF
        jsr     div32                   ; N32 = degrees, R32 = remainder
        rep     #$20
        LONGA   ON
        lda     R32
        sta     T32
        lda     R32+2
        sta     T32+2
        sep     #$20
        LONGA   OFF
        lda     DEGW
        sta     WIDTH
        jsr     print_u32
        jsr     space
        rep     #$20
        LONGA   ON
        lda     T32                     ; hundredths of minutes = rem*6000/DIVK
        sta     M32
        lda     T32+2
        sta     M32+2
        lda     #6000
        sta     M16
        jsr     mul32
        lda     P32
        sta     N32
        lda     P32+2
        sta     N32+2
        lda     DIVK
        sta     D32
        lda     DIVK+2
        sta     D32+2
        sep     #$20
        LONGA   OFF
        jsr     div32
        lda     #2
        sta     WIDTH
        jsr     print_2dec              ; MM.hh
        lda     HEMI
        jsl     PUT_CHR
        plx
        rts

;---------------------------------------------------------------------------
; Symbol line
;---------------------------------------------------------------------------
print_symbol:
        phx
        ldx     #s_sym
        jsr     puts
        lda     SYMT
        jsl     PUT_CHR
        lda     SYMC
        jsl     PUT_CHR
        jsr     space
        lda     SYMT
        cmp     #'/'
        bne     psy_alt
        ldx     #sym_tab
psy_lp: lda     !0,x
        beq     psy_none
        cmp     SYMC
        beq     psy_hit
psy_sk: inx                             ; skip to next entry
        lda     !0,x
        bne     psy_sk
        inx
        bra     psy_lp
psy_hit:
        inx
        jsr     puts
        bra     psy_end
psy_alt:
        ldx     #s_symalt
        jsr     puts
        bra     psy_end
psy_none:
psy_end:
        jsr     crlf
        plx
        rts

;---------------------------------------------------------------------------
; pos_extension: X -> text after the symbol. Handles CSE/SPD, PHG, RNG,
; DFS and weather data. Leaves X at the comment.
;---------------------------------------------------------------------------
pos_extension:
        lda     !3,x
        cmp     #'/'
        bne     pe_other
        jsr     is_num3                 ; X[0..2]
        bcs     pe_other
        inx
        inx
        inx
        inx
        jsr     is_num3                 ; X[4..6]
        php
        dex
        dex
        dex
        dex
        plp
        bcs     pe_other
        lda     SYMC
        cmp     #'_'
        beq     pe_wind
        phx                             ; course/speed (knots)
        ldx     #s_crs
        jsr     puts
        plx
        ldy     #3
        jsr     putn
        inx
        phx
        ldx     #s_spd
        jsr     puts
        plx
        ldy     #3
        jsr     putn
        phx
        ldx     #s_kt
        jsr     puts
        plx
        jsr     crlf
        rts
pe_wind:
        phx
        ldx     #s_wx
        jsr     puts
        ldx     #s_wind
        jsr     puts
        plx
        ldy     #3
        jsr     putn
        lda     #'/'
        jsl     PUT_CHR
        inx
        ldy     #3
        jsr     putn
        phx
        ldx     #s_mph
        jsr     puts
        plx
        jsr     wx_fields
        jmp     crlf

pe_other:
        lda     SYMC
        cmp     #'_'
        bne     pe_phg
        phx                             ; weather without wind
        ldx     #s_wx
        jsr     puts
        plx
        jsr     wx_fields
        jmp     crlf
pe_phg: ldy     #s_phg
        jsr     match3
        bcs     pe_rng
        phx
        ldx     #s_phgl
        bra     pe_ext7
pe_rng: ldy     #s_rng
        jsr     match3
        bcs     pe_dfs
        phx
        ldx     #s_rngl
        bra     pe_ext7
pe_dfs: ldy     #s_dfs
        jsr     match3
        bcs     pe_none
        phx
        ldx     #s_dfsl
pe_ext7:
        jsr     puts
        plx
        inx
        inx
        inx
        ldy     #4
        jsr     putn
        jsr     crlf
pe_none:
        rts

; C=0 if the 3 chars at X match the 3 chars at Y (bank 0)
match3:
        lda     !0,x
        cmp     !0,y
        bne     m3_no
        lda     !1,x
        cmp     !1,y
        bne     m3_no
        lda     !2,x
        cmp     !2,y
        bne     m3_no
        clc
        rts
m3_no:  sec
        rts

; C=0 if X[0..2] are digits, '.' or ' ' (unknown values are allowed)
is_num3:
        ldy     #3
        phx
in3_lp: lda     !0,x
        cmp     #'.'
        beq     in3_ok
        cmp     #' '
        beq     in3_ok
        cmp     #'0'
        bcc     in3_no
        cmp     #'9'+1
        bcs     in3_no
in3_ok: inx
        dey
        bne     in3_lp
        plx
        clc
        rts
in3_no: plx
        sec
        rts

;---------------------------------------------------------------------------
; Weather fields: letter + fixed number of digits, e.g. g005t077h50b10132
; Stops at the first letter it does not know; X is left there.
;---------------------------------------------------------------------------
wx_fields:
        lda     !0,x
        beq     wf_end
        cmp     #'s'
        bne     wf_look
        lda     wx_mode
        bne     wf_s                    ; positionless: s = wind speed
        lda     #'~'                    ; positioned: s = snowfall
        bra     wf_look
wf_s:   lda     #'s'
wf_look:
        ldy     #0
wf_tl:  pha
        lda     wx_tab,y
        beq     wf_endp
        pla
        cmp     wx_tab,y
        beq     wf_hit
        iny
        iny
        iny
        iny
        iny
        iny
        iny
        bra     wf_tl
wf_endp:
        pla
wf_end: rts

wf_hit: lda     wx_tab+1,y
        sta     CNT                     ; digit count
        lda     wx_tab+2,y
        sta     FMT
        inx
        phy
        jsr     parse_field             ; VAL, FSIGN; C=1 if missing
        ply
        bcs     wx_fields
        phx
        rep     #$20
        LONGA   ON
        lda     wx_tab+3,y
        tax
        sep     #$20
        LONGA   OFF
        jsr     puts                    ; label
        lda     FSIGN
        beq     wf_pos
        lda     #'-'
        jsl     PUT_CHR
wf_pos: rep     #$20
        LONGA   ON
        lda     VAL
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
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
wf_f2:  rep     #$20                    ; tenths: 1013.2
        LONGA   ON
        lda     #10
        sta     D32
        stz     D32+2
        sep     #$20
        LONGA   OFF
        jsr     div32
        lda     R32
        pha                             ; print_u32 overwrites R32
        jsr     print_u32
        lda     #'.'
        jsl     PUT_CHR
        pla
        ora     #'0'
        jsl     PUT_CHR
        bra     wf_unit
wf_f3:  rep     #$20                    ; humidity: 00 means 100
        LONGA   ON
        lda     N32
        bne     wf_h
        lda     #100
        sta     N32
wf_h:   sep     #$20
        LONGA   OFF
        jsr     print_u32
wf_unit:
        rep     #$20
        LONGA   ON
        lda     wx_tab+5,y
        tax
        sep     #$20
        LONGA   OFF
        jsr     puts
        plx
        jmp     wx_fields

; parse_field: CNT chars at X -> VAL (16 bit), FSIGN. X advanced.
; C=1 if the field is missing (dots/spaces) or malformed.
parse_field:
        stz     FSIGN
        ldy     #0
        sty     VAL
        stz     TMP2                    ; 1 = saw a bad character
        lda     !0,x
        cmp     #'-'
        bne     pf_lp
        sta     FSIGN
        inx
        dec     CNT
pf_lp:  lda     !0,x
        beq     pf_short
        cmp     #'0'
        bcc     pf_bad
        cmp     #'9'+1
        bcs     pf_bad
        sec
        sbc     #'0'
        pha
        rep     #$20
        LONGA   ON
        lda     VAL                     ; VAL = VAL*10 + digit
        asl     a
        sta     TMP
        asl     a
        asl     a
        clc
        adc     TMP
        sta     VAL
        sep     #$20
        LONGA   OFF
        pla
        clc
        adc     VAL
        sta     VAL
        lda     VAL+1
        adc     #0
        sta     VAL+1
        bra     pf_nx
pf_bad: lda     #1
        sta     TMP2
pf_nx:  inx
        dec     CNT
        bne     pf_lp
        lda     TMP2
        bne     pf_miss
        clc
        rts
pf_short:
pf_miss:
        sec
        rts

; label/unit table: char, digits, format, label, unit
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
        ldx     #s_time
        jsr     puts
        ldx     IP
        inx
        ldy     #8
        jsr     putn
        jsr     crlf
        phx
        ldx     #s_wx
        jsr     puts
        plx
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
        ldx     IP
        lda     !10,x
        cmp     #':'
        beq     dm_ok
        jmp     bad_data
dm_ok:  inx
        lda     !0,x
        cmp     #'B'
        bne     dm_to
        lda     !1,x
        cmp     #'L'
        bne     dm_to
        lda     !2,x
        cmp     #'N'
        bne     dm_to
        phx
        ldx     #s_bln
        bra     dm_name
dm_to:  phx
        ldx     #s_msgto
dm_name:
        jsr     puts
        plx
        ldy     #9
        jsr     putn_trim
        jsr     crlf
        inx                             ; skip ':'
        ldy     #s_ack
        jsr     match3
        bcc     dm_ack
        ldy     #s_rej
        jsr     match3
        bcs     dm_text
        phx
        ldx     #s_rejl
        bra     dm_ar
dm_ack: phx
        ldx     #s_ackl
dm_ar:  jsr     puts
        plx
        inx
        inx
        inx
        jsr     puts
        jmp     crlf
dm_text:
        phx
        ldx     #s_text
        jsr     puts
        plx
dm_tl:  lda     !0,x
        beq     dm_te
        cmp     #'{'
        beq     dm_id
        jsl     PUT_CHR
        inx
        bra     dm_tl
dm_id:  jsr     crlf
        phx
        ldx     #s_msgid
        jsr     puts
        plx
        inx
        jsr     puts
dm_te:  jmp     crlf

;---------------------------------------------------------------------------
; Object   ;NAME_____*DDHHMMzPOSITION...
;---------------------------------------------------------------------------
do_object:
        ldx     IP
        lda     !10,x
        cmp     #'*'
        beq     dob_ok
        cmp     #'_'
        beq     dob_ok
        jmp     bad_data
dob_ok: phx
        ldx     #s_obj
        jsr     puts
        plx
        inx
        ldy     #9
        jsr     putn_trim
        jsr     obj_state               ; X -> '*' or '_'
        inx
        phx
        ldx     #s_time
        jsr     puts
        plx
        ldy     #7
        jsr     putn
        jsr     crlf
        jmp     dpos_go

; prints " (killed)" if the char at X is '_', else " (live)"; then CRLF
obj_state:
        phx
        lda     !0,x
        ldx     #s_live
        cmp     #'_'
        bne     os_p
        ldx     #s_killed
os_p:   jsr     puts
        jsr     crlf
        plx
        rts

;---------------------------------------------------------------------------
; Item   )NAME!POSITION...  (name is 3-9 chars, ends with ! or _)
;---------------------------------------------------------------------------
do_item:
        ldx     #s_item
        jsr     puts
        ldx     IP
        inx
        ldy     #0
di_lp:  lda     !0,x
        beq     di_bad
        cmp     #'!'
        beq     di_end
        cmp     #'_'
        beq     di_end
        jsl     PUT_CHR
        inx
        iny
        cpy     #10
        bcc     di_lp
di_bad: jsr     crlf
        jmp     bad_data
di_end: jsr     obj_state
        inx
        jmp     dpos_go

;---------------------------------------------------------------------------
; Status  >text
;---------------------------------------------------------------------------
do_status:
        ldx     #s_status
        jsr     puts
        ldx     IP
        inx
        jsr     puts
        jmp     crlf

;---------------------------------------------------------------------------
; Third-party traffic  }SRC>DEST,PATH:info  -> decode the inner packet
;---------------------------------------------------------------------------
do_third:
        ldx     #s_third
        jsr     puts
        ldx     IP
        inx
        stx     HP
dt_lp:  lda     !0,x
        beq     dt_bad
        cmp     #':'
        beq     dt_ok
        inx
        bra     dt_lp
dt_ok:  inx
        stx     IP
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

        ; flags from chars 3, 4, 5
        lda     DESTBUF+3
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

        ; info must have at least 9 bytes
        ldx     IP
        ldy     #0
mi_len: lda     !0,x
        beq     mi_bad
        inx
        iny
        cpy     #9
        bne     mi_len

        ldx     #s_pos                  ; latitude from the dest call
        jsr     puts
        lda     LATSTR
        jsl     PUT_CHR
        lda     LATSTR+1
        jsl     PUT_CHR
        jsr     space
        lda     LATSTR+2
        jsl     PUT_CHR
        lda     LATSTR+3
        jsl     PUT_CHR
        lda     #'.'
        jsl     PUT_CHR
        lda     LATSTR+4
        jsl     PUT_CHR
        lda     LATSTR+5
        jsl     PUT_CHR
        lda     mic_ns
        jsl     PUT_CHR
        jsr     space
        jsr     space

        ldx     IP                      ; longitude degrees
        lda     mic_off
        beq     mi_d1
        lda     #100
mi_d1:  clc
        adc     !1,x
        sec
        sbc     #28
        cmp     #180
        bcc     mi_d3
        cmp     #190
        bcs     mi_d2
        sec
        sbc     #80                     ; 180-189 -> 100-109
        bra     mi_d3
mi_d2:  sec
        sbc     #190                    ; 190-199 -> 0-9
mi_d3:  jsr     put_a3
        jsr     space
        lda     !2,x                    ; minutes
        sec
        sbc     #28
        cmp     #60
        bcc     mi_m1
        sec
        sbc     #60
mi_m1:  jsr     put_a2
        lda     #'.'
        jsl     PUT_CHR
        lda     !3,x                    ; hundredths
        sec
        sbc     #28
        jsr     put_a2
        lda     mic_ew
        jsl     PUT_CHR
        jsr     crlf

        lda     !7,x
        sta     SYMC
        lda     !8,x
        sta     SYMT
        jsr     print_symbol

        ; speed = SP*10 + DC/10, course = (DC%10)*100 + SE
        ldx     #s_crs
        jsr     puts
        ldx     IP
        lda     !5,x
        sec
        sbc     #28
        rep     #$20
        LONGA   ON
        and     #$00FF
        sta     N32
        stz     N32+2
        lda     #10
        sta     D32
        stz     D32+2
        sep     #$20
        LONGA   OFF
        jsr     div32                   ; N32 = DC/10, R32 = DC%10
        rep     #$20
        LONGA   ON
        lda     N32
        sta     TMP2                    ; DC/10
        lda     R32                     ; course
        jsr     mul100
        sta     TMP
        lda     !6,x
        and     #$00FF
        sec
        sbc     #28
        clc
        adc     TMP
        cmp     #400
        bcc     mi_c400
        sbc     #400
mi_c400:
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        lda     #3
        sta     WIDTH
        jsr     print_u32
        ldx     #s_spd
        jsr     puts
        ldx     IP
        rep     #$20
        LONGA   ON
        lda     !4,x                    ; SP
        and     #$00FF
        sec
        sbc     #28
        asl     a                       ; *10
        sta     TMP
        asl     a
        asl     a
        clc
        adc     TMP
        clc
        adc     TMP2
        cmp     #800
        bcc     mi_s800
        sbc     #800
mi_s800:
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        jsr     print_u32
        ldx     #s_kt
        jsr     puts
        jsr     crlf

        ; message
        ldx     #s_mice
        jsr     puts
        lda     msg_cust
        beq     mi_stdm
        ldx     #s_custom
        jsr     puts
        lda     #7
        sec
        sbc     msg_bits
        ora     #'0'
        jsl     PUT_CHR
        bra     mi_mend
mi_stdm:
        lda     msg_bits
        rep     #$20
        LONGA   ON
        and     #$0007
        asl     a
        tay
        lda     mice_msgs,y
        tax
        sep     #$20
        LONGA   OFF
        jsr     puts
mi_mend:
        jsr     crlf

        ; altitude "xxx}" near the start of the comment
        ldx     IP
        lda     !12,x
        cmp     #'}'
        beq     mi_alt
        lda     !13,x
        cmp     #'}'
        bne     mi_cmt
        inx
mi_alt: phx
        ldx     #s_alt
        jsr     puts
        plx
        inx                             ; X -> 3 base-91 chars at IP+9 (+1)
        inx
        inx
        inx
        inx
        inx
        inx
        inx
        inx
        jsr     b91_3
        rep     #$20
        LONGA   ON
        lda     N32                     ; meters = value - 10000
        sec
        sbc     #10000
        sta     N32
        lda     N32+2
        sbc     #0
        sta     N32+2
        bpl     mi_apos
        lda     #0                      ; negative: print "-" and negate
        sec
        sbc     N32
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        lda     #'-'
        jsl     PUT_CHR
mi_apos:
        sep     #$20
        LONGA   OFF
        jsr     print_u32
        ldx     #s_m
        jsr     puts
        jsr     crlf
mi_cmt: ldx     IP
        rep     #$20
        LONGA   ON
        txa
        clc
        adc     #9
        tax
        sep     #$20
        LONGA   OFF
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
        ldx     #s_badmic
        jsr     puts
        ldx     #DESTBUF
        jsr     puts
        jmp     crlf

mice_msgs:
        dw      s_mm0,s_mm1,s_mm2,s_mm3,s_mm4,s_mm5,s_mm6,s_mm7

; b91_3: N32 = 3 base-91 digits at X (no X change)
b91_3:
        lda     #3
        sta     CNT
        rep     #$20
        LONGA   ON
        stz     N32
        stz     N32+2
        phx
        bra     b91_lp3
b91_n3: sep     #$20
        LONGA   OFF
        dec     CNT
        rep     #$20
        LONGA   ON
        beq     b91_x3
b91_lp3:
        lda     N32
        sta     M32
        lda     N32+2
        sta     M32+2
        lda     #91
        sta     M16
        jsr     mul32
        lda     !0,x
        and     #$00FF
        sec
        sbc     #33
        clc
        adc     P32
        sta     N32
        lda     P32+2
        adc     #0
        sta     N32+2
        inx
        bra     b91_n3
b91_x3: plx
        sep     #$20
        LONGA   OFF
        rts

; A (16 bit) = A * 100
        LONGA   ON
mul100:
        asl     a
        asl     a
        sta     TMP                     ; 4x
        asl     a
        asl     a
        asl     a
        sta     T32                     ; 32x
        asl     a                       ; 64x
        clc
        adc     T32
        clc
        adc     TMP                     ; 100x
        rts
        LONGA   OFF

;---------------------------------------------------------------------------
; Comment / bad data
;---------------------------------------------------------------------------
print_comment:
        lda     !0,x
        beq     pc_none
        phx
        ldx     #s_cmt
        jsr     puts
        plx
        phx
        jsr     puts
        jsr     crlf
        plx
        jsr     find_alt                ; /A=nnnnnn altitude in feet
pc_none:
        rts

find_alt:
fa_lp:  lda     !0,x
        beq     fa_no
        cmp     #'/'
        bne     fa_nx
        lda     !1,x
        cmp     #'A'
        bne     fa_nx
        lda     !2,x
        cmp     #'='
        bne     fa_nx
        phx
        ldx     #s_alt
        jsr     puts
        plx
        inx
        inx
        inx
        ldy     #6
        jsr     putn
        ldx     #s_ft
        jsr     puts
        jmp     crlf
fa_nx:  inx
        bra     fa_lp
fa_no:  rts

bad_data:
        ldx     #s_bad
        jsr     puts
        ldx     IP
        jsr     puts
        jmp     crlf

;---------------------------------------------------------------------------
; Stats
;---------------------------------------------------------------------------
show_stats:
        ldx     #s_st1
        jsr     puts
        ldx     pkt_count
        jsr     pnum_x
        ldx     #s_st2
        jsr     puts
        ldx     rx_err
        jsr     pnum_x
        ldx     #s_st3
        jsr     puts
        ldx     rx_ovf
        jsr     pnum_x
        ldx     #s_st4
        jsr     puts
        ldx     line_ovf
        jsr     pnum_x
        jmp     crlf

;---------------------------------------------------------------------------
; Output helpers
;---------------------------------------------------------------------------
; puts: print NUL-terminated string at X. X ends on the NUL.
puts:   lda     !0,x
        beq     puts_d
        jsl     PUT_CHR
        inx
        bra     puts
puts_d: rts

; putn: print Y chars from X (stops early at NUL). X advanced.
putn:   lda     !0,x
        beq     putn_d
        jsl     PUT_CHR
        inx
        dey
        bne     putn
putn_d: rts

; putn_trim: print Y chars at X without trailing spaces; X += Y
putn_trim:
        stx     TMP                     ; start
        rep     #$20
        LONGA   ON
        tya
        clc
        adc     TMP
        sta     TMP2                    ; end
        sep     #$20
        LONGA   OFF
        ldy     TMP2
pt_bk:  cpy     TMP
        beq     pt_pr
        dey
        lda     !0,y
        cmp     #' '
        beq     pt_bk
        iny
pt_pr:  sty     TMP                     ; print up to here
pt_lp:  cpx     TMP
        bcs     pt_d
        lda     !0,x
        jsl     PUT_CHR
        inx
        bra     pt_lp
pt_d:   ldx     TMP2
        rts

crlf:   lda     #$0D
        jsl     PUT_CHR
        lda     #$0A
        jsl     PUT_CHR
        rts

space:  lda     #' '
        jsl     PUT_CHR
        rts

; put_a2 / put_a3: A (8 bit, 0-255) as 2 or 3 digits
put_a2: pha
        lda     #2
        bra     pa_go
put_a3: pha
        lda     #3
pa_go:  sta     WIDTH
        pla
        phx
        rep     #$20
        LONGA   ON
        and     #$00FF
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        jsr     print_u32
        plx
        rts

; pnum_x: print X as unsigned decimal
pnum_x: stx     N32
        ldx     #0
        stx     N32+2
        jmp     print_u32

; print_2dec: N32 (0-9999) as "n.hh". The caller sets WIDTH for the
; integer part (0 = no padding).
print_2dec:
        jsr     div100
        rep     #$20
        LONGA   ON
        lda     R32
        sta     VAL                     ; print_u32 overwrites R32
        sep     #$20
        LONGA   OFF
        jsr     print_u32
        lda     #'.'
        jsl     PUT_CHR
        rep     #$20
        LONGA   ON
        lda     VAL
        sta     N32
        stz     N32+2
        sep     #$20
        LONGA   OFF
        lda     #2
        sta     WIDTH
        jmp     print_u32

; div100: N32 = N32 / 100, R32 = remainder
div100: rep     #$20
        LONGA   ON
        lda     #100
        sta     D32
        stz     D32+2
        sep     #$20
        LONGA   OFF
        jmp     div32

; print_u32: N32 as decimal, zero padded to WIDTH digits. WIDTH reset to 0.
print_u32:
        phx
        phy
        ldy     #0
pu_lp:  rep     #$20
        LONGA   ON
        lda     #10
        sta     D32
        stz     D32+2
        sep     #$20
        LONGA   OFF
        jsr     div32
        lda     R32
        ora     #'0'
        sta     DIGBUF,y
        iny
        rep     #$20
        LONGA   ON
        lda     N32
        ora     N32+2
        sep     #$20
        LONGA   OFF
        bne     pu_lp
pu_pad: cpy     WIDTH
        bcs     pu_out
        lda     #'0'
        sta     DIGBUF,y
        iny
        bra     pu_pad
pu_out: dey
        lda     DIGBUF,y
        jsl     PUT_CHR
        cpy     #0
        bne     pu_out
        ldx     #0
        stx     WIDTH
        ply
        plx
        rts

;---------------------------------------------------------------------------
; 32-bit math (A 8 bit on entry/exit)
;---------------------------------------------------------------------------
; div32: N32 / D32 -> quotient in N32, remainder in R32
div32:  phx
        phy
        php
        rep     #$30
        LONGA   ON
        stz     R32
        stz     R32+2
        ldx     #32
dv_lp:  asl     N32
        rol     N32+2
        rol     R32
        rol     R32+2
        lda     R32
        sec
        sbc     D32
        tay
        lda     R32+2
        sbc     D32+2
        bcc     dv_nx
        sta     R32+2
        sty     R32
        inc     N32
dv_nx:  dex
        bne     dv_lp
        plp
        LONGA   OFF
        ply
        plx
        rts

; mul32: P32 = M32 * M16 (low 32 bits). M32 and M16 are destroyed.
; Works with A in either size; preserves X and Y.
mul32:  phx
        php
        rep     #$30
        LONGA   ON
        stz     P32
        stz     P32+2
        ldx     #16
mu_lp:  lsr     M16
        bcc     mu_nx
        lda     P32
        clc
        adc     M32
        sta     P32
        lda     P32+2
        adc     M32+2
        sta     P32+2
mu_nx:  asl     M32
        rol     M32+2
        dex
        bne     mu_lp
        plp
        LONGA   OFF
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
        db      $0D,$0A,'APRS receive - PK-232 on UART0 (P60)',$0D,$0A
        db      'ESC = exit   R = raw lines on/off   S = stats',$0D,$0A,0
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
s_phg:  db      'PHG'
s_rng:  db      'RNG'
s_dfs:  db      'DFS'
s_ack:  db      'ack'
s_rej:  db      'rej'
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
