;***************************************************************************
;  FILE:   mmon.asm
;  TITLE:  MMON - a small machine-language monitor for the MyMENSCH Rev-C
;
;  Upload it like any program (it lives at $8000-$8FFF):
;    wdc_uploader_term.exe -d COM10 mmon.bin -m write -x -s 5 -t
;
;  Commands (hex numbers, $ optional, upper or lower case):
;    D [start [end]]     dump memory, 128 bytes by default; D alone goes on
;    I                   dump the I/O page $7F00-$7FFF
;    E addr [bb bb ..]   write bytes, then show them read back
;    F start end bb      fill memory
;    G [addr]            call addr with A/X/Y/P from R; RTS comes back here
;    R [a [x [y [p]]]]   show or set the registers G uses
;    L                   load an S19 file (paste it, or Ctrl+T Ctrl+U in
;                        the uploader's terminal); G then runs its start
;    ?                   help
;    X                   leave: restart the board into WDC's firmware
;  ESC cancels a line, stops a dump and aborts a load.
;
;  BRK in your code stops back in the monitor and shows the registers;
;  G then resumes after the BRK and its signature byte.
;
;  Memory the monitor uses (L refuses to load over it):
;    $8000-$8FFF code
;    $0100-$02FF stack, line buffer, saved registers, IRQ vectors
;    $00F0-$00FF zero page
;  Put your programs at $0300-$7EFF or $9000-$F7FF.
;
;  IRQs: the jump table at $8000 sends each IRQ through a RAM vector.
;  Point one at your handler (handlers end with RTI):
;    VECS+0  $0260 ACIA_C    VECS+12 $026C VIA_D
;    VECS+2  $0262 ACIA_B    VECS+14 $026E VIA_C
;    VECS+4  $0264 ACIA_A    VECS+16 $0270 VIA_B
;    VECS+6  $0266 ADC       VECS+18 $0272 VIA_A
;    VECS+8  $0268 I2C       VECS+20 $0274 GPIO_A
;    VECS+10 $026A SPI       VECS+22 $0276 GPIO_E
;  They all point at an RTI after start-up.
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

ACIA_DATA       EQU     $7F60           ; ACIA_A, USB console via the CH340
ACIA_STAT       EQU     $7F61           ; bit 3 = RX full, bit 4 = TX empty
GPIOE_PIO       EQU     $7FA0
GPIOE_DDR       EQU     $7FA1

; zero page
PTR             EQU     $F0             ; 2
NUM             EQU     $F2             ; 2
ENDA            EQU     $F4             ; 2
LIDX            EQU     $F6             ; input line index
CNT             EQU     $F7
CHK             EQU     $F8             ; S-record checksum
RTYPE           EQU     $F9             ; S-record type ('0'..'9')
TMP             EQU     $FA
DIG             EQU     $FB             ; hex digits seen
DADDR           EQU     $FC             ; 2, next dump address
SPTR            EQU     $FE             ; 2, string pointer

; RAM
LINE            EQU     $0200           ; input line, 0-terminated
LMAX            EQU     72
R_A             EQU     $0250
R_X             EQU     $0251
R_Y             EQU     $0252
R_P             EQU     $0253
R_S             EQU     $0254
R_PC            EQU     $0255           ; 2
TARGET          EQU     $0257           ; 2, G address
NREC            EQU     $0259           ; 2, S1 records loaded
NERR            EQU     $025B           ; 2, bad records
NSKIP           EQU     $025D           ; 2, bytes refused (monitor memory)
VECS            EQU     $0260           ; 12 IRQ vectors, $0260-$0277
NBAD            EQU     $0278           ; 2, bytes that didn't read back
ABUF            EQU     $0280           ; 16, dump ASCII column

PRINT   MACRO   STR
        ldx     #<STR
        ldy     #>STR
        jsr     puts
        ENDM

        CODE
        ORG     $8000
        jmp     START
        jmp     nmi_h                   ; NMI
        jmp     brk_h                   ; BRK
        jmp     (VECS+0)                ; IRQ_ACIA_C
        jmp     (VECS+2)                ; IRQ_ACIA_B
        jmp     (VECS+4)                ; IRQ_ACIA_A
        jmp     (VECS+6)                ; IRQ_ADC
        jmp     (VECS+8)                ; IRQ_I2C
        jmp     (VECS+10)               ; IRQ_SPI
        jmp     (VECS+12)               ; IRQ_VIA_D
        jmp     (VECS+14)               ; IRQ_VIA_C
        jmp     (VECS+16)               ; IRQ_VIA_B
        jmp     (VECS+18)               ; IRQ_VIA_A
        jmp     (VECS+20)               ; IRQ_GPIO_A
        jmp     (VECS+22)               ; IRQ_GPIO_E
NoINT:  rti

;---------------------------------------------------------------------------
START:
        sei
        cld
        ldx     #$FF
        txs
        lda     #$80                    ; RTS to the CH340 so keys get through
        tsb     GPIOE_DDR
        trb     GPIOE_PIO
        ldx     #22
st_v:   lda     #<NoINT
        sta     VECS,x
        lda     #>NoINT
        sta     VECS+1,x
        dex
        dex
        bpl     st_v
        stz     R_A
        stz     R_X
        stz     R_Y
        lda     #$04                    ; I set: no stray IRQs by default
        sta     R_P
        lda     #$FF
        sta     R_S
        stz     TARGET
        lda     #$03
        sta     TARGET+1                ; G defaults to $0300
        stz     DADDR
        stz     DADDR+1
        PRINT   s_banner

main:   ldx     #$FF                    ; every command starts clean
        txs
        cld
        PRINT   s_prompt
        jsr     getline
        jsr     skipsp
        beq     main
        inc     LIDX
        ldx     #0
md_lp:  cmp     cmd_chr,x
        beq     md_go
        inx
        cpx     #NCMD
        bne     md_lp
bad:    PRINT   s_what
        bra     main
md_go:  txa
        asl     a
        tax
        jmp     (cmd_tbl,x)

cmd_chr:
        db      'DIEFGRL?X'
NCMD    EQU     9
cmd_tbl:
        dw      cmd_d, cmd_i, cmd_e, cmd_f, cmd_g, cmd_r, cmd_l, cmd_h, cmd_x

cmd_h:  PRINT   s_help
        jmp     main

cmd_x:  PRINT   s_bye
        jmp     ($FFFC)

;---------------------------------------------------------------------------
; D [start [end]]
;---------------------------------------------------------------------------
cmd_d:  jsr     gethex
        bcc     cd_def
        lda     NUM
        sta     DADDR
        lda     NUM+1
        sta     DADDR+1
        jsr     gethex
        bcc     cd_def
        lda     NUM
        sta     ENDA
        lda     NUM+1
        sta     ENDA+1
        bra     cd_go
cd_def: clc                             ; 128 bytes
        lda     DADDR
        adc     #$7F
        sta     ENDA
        lda     DADDR+1
        adc     #0
        sta     ENDA+1
        bcc     cd_go
        lda     #$FF                    ; don't wrap past $FFFF
        sta     ENDA
        sta     ENDA+1
cd_go:  jsr     dump
        jmp     main

cmd_i:  stz     DADDR
        lda     #$7F
        sta     DADDR+1
        lda     #$FF
        sta     ENDA
        lda     #$7F
        sta     ENDA+1
        jsr     dump
        jmp     main

; dump DADDR..ENDA (inclusive); DADDR ends up just past the last byte
dump:   lda     DADDR
        sta     PTR
        lda     DADDR+1
        sta     PTR+1
du_ln:  lda     PTR+1
        jsr     hex8
        lda     PTR
        jsr     hex8
        lda     #':'
        jsr     putc
        stz     CNT
du_b:   lda     #' '
        jsr     putc
        jsr     rdptr
        bcs     du_sk
        pha
        jsr     hex8
        pla
        bra     du_as
du_sk:  lda     #'-'
        jsr     putc
        jsr     putc
        lda     #0
du_as:  ldx     CNT
        sta     ABUF,x
        inc     CNT
        lda     PTR                     ; last byte?
        cmp     ENDA
        bne     du_nx
        lda     PTR+1
        cmp     ENDA+1
        beq     du_last
du_nx:  jsr     incptr
        lda     CNT
        cmp     #16
        bne     du_b
        jsr     du_asc
        jsr     esc_hit
        bcc     du_ln
        bra     du_done
du_last:
        jsr     incptr
        lda     CNT                     ; pad a short line
du_pad: cmp     #16
        beq     du_pd
        pha
        PRINT   s_3sp
        pla
        inc     a
        bra     du_pad
du_pd:  jsr     du_asc
du_done:
        lda     PTR
        sta     DADDR
        lda     PTR+1
        sta     DADDR+1
        rts

du_asc: lda     #' '
        jsr     putc
        jsr     putc
        ldx     #0
da_lp:  lda     ABUF,x
        cmp     #' '
        bcc     da_dot
        cmp     #$7F
        bcc     da_pr
da_dot: lda     #'.'
da_pr:  jsr     putc
        inx
        cpx     CNT
        bne     da_lp
        jmp     crlf

; A = byte at PTR; C=1 (and nothing read) for ACIA_A data, which would
; eat a key
rdptr:  lda     PTR+1
        cmp     #>ACIA_DATA
        bne     rp_rd
        lda     PTR
        cmp     #<ACIA_DATA
        bne     rp_rd
        sec
        rts
rp_rd:  lda     (PTR)
        clc
        rts

incptr: inc     PTR
        bne     ip_x
        inc     PTR+1
ip_x:   rts

; C=1 if ESC was pressed (other keys are dropped)
esc_hit:
        lda     ACIA_STAT
        and     #$08
        clc
        beq     eh_x
        lda     ACIA_DATA
        cmp     #$1B
        sec
        beq     eh_x
        clc
eh_x:   rts

;---------------------------------------------------------------------------
; E addr [bb bb ...]
;---------------------------------------------------------------------------
cmd_e:  jsr     gethex
        bcs     ce_a
        jmp     bad
ce_a:   lda     NUM
        sta     PTR
        sta     DADDR
        lda     NUM+1
        sta     PTR+1
        sta     DADDR+1
        stz     CNT
ce_lp:  jsr     gethex
        bcc     ce_end
        lda     NUM
        sta     (PTR)
        jsr     incptr
        inc     CNT
        bra     ce_lp
ce_end: jsr     skipsp                  ; anything left that isn't hex?
        beq     ce_ok
        PRINT   s_what
ce_ok:  lda     CNT                     ; show what is there now
        bne     ce_m
        lda     DADDR
        sta     ENDA
        lda     DADDR+1
        sta     ENDA+1
        bra     ce_d
ce_m:   lda     PTR                     ; end = PTR - 1
        sec
        sbc     #1
        sta     ENDA
        lda     PTR+1
        sbc     #0
        sta     ENDA+1
ce_d:   jsr     dump
        jmp     main

;---------------------------------------------------------------------------
; F start end bb
;---------------------------------------------------------------------------
cmd_f:  jsr     gethex
        bcc     cf_bad
        lda     NUM
        sta     PTR
        lda     NUM+1
        sta     PTR+1
        jsr     gethex
        bcc     cf_bad
        lda     NUM
        sta     ENDA
        lda     NUM+1
        sta     ENDA+1
        jsr     gethex
        bcc     cf_bad
        lda     NUM
        sta     TMP
        lda     PTR+1                   ; overlaps $8000-$8FFF?
        cmp     #$90
        bcs     cf_lp
        lda     ENDA+1
        cmp     #$80
        bcc     cf_lp
        PRINT   s_mine
        jmp     main
cf_lp:  lda     TMP
        sta     (PTR)
        lda     PTR
        cmp     ENDA
        bne     cf_nx
        lda     PTR+1
        cmp     ENDA+1
        beq     cf_x
cf_nx:  jsr     incptr
        bra     cf_lp
cf_x:   jmp     main
cf_bad: jmp     bad

;---------------------------------------------------------------------------
; G [addr]
;---------------------------------------------------------------------------
cmd_g:  jsr     gethex
        bcc     cg_go
        lda     NUM
        sta     TARGET
        lda     NUM+1
        sta     TARGET+1
cg_go:  PRINT   s_go
        lda     TARGET+1
        jsr     hex8
        lda     TARGET
        jsr     hex8
        jsr     crlf
        jsr     cg_call
        php                             ; the program did RTS
        sta     R_A
        stx     R_X
        sty     R_Y
        pla
        sta     R_P
        tsx
        stx     R_S
        cld
        PRINT   s_ret
        jsr     showregs
        jmp     main

cg_call:
        lda     R_P
        pha
        lda     R_A
        ldx     R_X
        ldy     R_Y
        plp
        jmp     (TARGET)

;---------------------------------------------------------------------------
; R [a [x [y [p]]]]
;---------------------------------------------------------------------------
cmd_r:  ldx     #0
cr_lp:  phx
        jsr     gethex
        plx
        bcc     cr_sh
        lda     NUM
        sta     R_A,x
        inx
        cpx     #4
        bne     cr_lp
cr_sh:  jsr     showregs
        jmp     main

; " A=xx X=xx Y=xx S=xx P=xx NV-BDIZC" (lower case = clear)
showregs:
        lda     #'A'
        ldx     R_A
        jsr     field
        lda     #'X'
        ldx     R_X
        jsr     field
        lda     #'Y'
        ldx     R_Y
        jsr     field
        lda     #'S'
        ldx     R_S
        jsr     field
        lda     #'P'
        ldx     R_P
        jsr     field
        lda     #' '
        jsr     putc
        lda     R_P
        ldx     #0
sr_fl:  asl     a
        pha
        lda     s_flags,x
        bcs     sr_up
        cmp     #'-'
        beq     sr_up
        ora     #$20
sr_up:  jsr     putc
        pla
        inx
        cpx     #8
        bne     sr_fl
        jmp     crlf

; print " c=xx", c in A, value in X
field:  pha
        lda     #' '
        jsr     putc
        pla
        jsr     putc
        lda     #'='
        jsr     putc
        txa
        jmp     hex8

;---------------------------------------------------------------------------
; BRK and NMI
;---------------------------------------------------------------------------
brk_h:  sta     R_A
        stx     R_X
        sty     R_Y
        pla
        sta     R_P
        pla                             ; return address = BRK + 2
        sta     TARGET                  ; G resumes there
        sec
        sbc     #2
        sta     R_PC
        pla
        sta     TARGET+1
        sbc     #0
        sta     R_PC+1
        tsx
        stx     R_S
        cld
        PRINT   s_brk
        bra     stop_sh

nmi_h:  sta     R_A
        stx     R_X
        sty     R_Y
        pla
        sta     R_P
        pla
        sta     R_PC
        sta     TARGET
        pla
        sta     R_PC+1
        sta     TARGET+1
        tsx
        stx     R_S
        cld
        PRINT   s_nmi

stop_sh:
        lda     R_PC+1
        jsr     hex8
        lda     R_PC
        jsr     hex8
        jsr     crlf
        jsr     showregs
        jmp     main

;---------------------------------------------------------------------------
; L: load S19. Records are parsed as the characters arrive: ACIA_A holds
; one byte, so there is no time to buffer a line and parse it afterwards.
;---------------------------------------------------------------------------
cmd_l:  PRINT   s_load
        stz     NREC
        stz     NREC+1
        stz     NERR
        stz     NERR+1
        stz     NSKIP
        stz     NSKIP+1
        stz     NBAD
        stz     NBAD+1
cl_wt:  jsr     getc
        cmp     #$1B
        beq     cl_abort
        cmp     #'S'
        bne     cl_wt
        jsr     getc
        sta     RTYPE
        stz     CHK
        jsr     getbyte                 ; count: address + data + checksum
        bcs     cl_bad
        sta     CNT
        jsr     getbyte
        bcs     cl_bad
        sta     PTR+1
        jsr     getbyte
        bcs     cl_bad
        sta     PTR
        dec     CNT
        dec     CNT
cl_dat: lda     CNT
        cmp     #2
        bcc     cl_ck
        jsr     getbyte
        bcs     cl_bad
        ldx     RTYPE
        cpx     #'1'
        bne     cl_nx
        jsr     store
cl_nx:  dec     CNT
        bra     cl_dat
cl_ck:  jsr     getbyte                 ; checksum: all bytes sum to $FF
        bcs     cl_bad
        lda     CHK
        cmp     #$FF
        bne     cl_bad
        lda     RTYPE
        cmp     #'9'
        beq     cl_end
        cmp     #'1'
        bne     cl_wt
        inc     NREC
        bne     cl_dt
        inc     NREC+1
cl_dt:  lda     #'.'
        jsr     putc
        bra     cl_wt
cl_bad: cmp     #$1B                    ; getbyte leaves the bad char in A
        beq     cl_abort
        inc     NERR
        bne     cl_be
        inc     NERR+1
cl_be:  lda     #'E'
        jsr     putc
        bra     cl_wt
cl_abort:
        jsr     drain
        PRINT   s_abort
        bra     cl_rep
cl_end: lda     PTR                     ; S9 address = start
        sta     TARGET
        lda     PTR+1
        sta     TARGET+1
        jsr     drain                   ; rest of the file, e.g. CR LF
cl_rep: jsr     crlf
        lda     NREC
        ldx     NREC+1
        jsr     hex16
        PRINT   s_recs
        lda     NERR
        ldx     NERR+1
        jsr     hex16
        PRINT   s_errs
        lda     NSKIP
        ldx     NSKIP+1
        jsr     hex16
        PRINT   s_skip
        lda     NBAD
        ldx     NBAD+1
        jsr     hex16
        PRINT   s_nbad
        lda     TARGET+1
        jsr     hex8
        lda     TARGET
        jsr     hex8
        jsr     crlf
        jmp     main

; read and drop input until the line has been quiet for about 50 ms
drain:  stz     CNT
        stz     TMP
dr_lp:  lda     ACIA_STAT
        and     #$08
        beq     dr_q
        lda     ACIA_DATA
        bra     drain
dr_q:   inc     CNT
        bne     dr_lp
        inc     TMP
        bne     dr_lp
        rts

; two hex chars -> A, added into CHK. C=1 on a bad char (char left in A)
getbyte:
        jsr     getc
        jsr     hexval
        bcs     gb_x
        asl     a
        asl     a
        asl     a
        asl     a
        sta     TMP
        jsr     getc
        jsr     hexval
        bcs     gb_x
        ora     TMP
        pha
        clc
        adc     CHK
        sta     CHK
        pla
        clc
gb_x:   rts

; store A at PTR unless it is monitor memory; PTR++
store:  ldx     PTR+1
        cpx     #$01                    ; stack and monitor RAM
        beq     so_no
        cpx     #$02
        beq     so_no
        cpx     #$00
        bne     so_hi
        ldx     PTR
        cpx     #$F0                    ; monitor zero page
        bcs     so_no
        bra     so_ok
so_hi:  cpx     #$80                    ; monitor code
        bcc     so_ok
        cpx     #$90
        bcc     so_no
so_ok:  sta     (PTR)
        cmp     (PTR)                   ; did it stick?
        beq     so_x
        inc     NBAD
        bne     so_x
        inc     NBAD+1
        bra     so_x
so_no:  inc     NSKIP
        bne     so_x
        inc     NSKIP+1
so_x:   jmp     incptr

;---------------------------------------------------------------------------
; line input
;---------------------------------------------------------------------------
getline:
        stz     LIDX
gl_lp:  jsr     getc
        cmp     #$0D
        beq     gl_end
        cmp     #$1B
        beq     gl_esc
        cmp     #$08
        beq     gl_bs
        cmp     #$7F
        beq     gl_bs
        cmp     #' '
        bcc     gl_lp
        cmp     #'a'
        bcc     gl_st
        cmp     #'z'+1
        bcs     gl_st
        and     #$DF                    ; upper case
gl_st:  ldx     LIDX
        cpx     #LMAX
        bcs     gl_lp
        sta     LINE,x
        inc     LIDX
        jsr     putc
        bra     gl_lp
gl_bs:  lda     LIDX
        beq     gl_lp
        dec     LIDX
        PRINT   s_bs
        bra     gl_lp
gl_esc: stz     LIDX
        lda     #'\'
        jsr     putc
gl_end: ldx     LIDX
        stz     LINE,x
        stz     LIDX
        jmp     crlf

; A = next non-space char of LINE (not consumed); Z=1 at the end
skipsp: ldx     LIDX
ss_lp:  lda     LINE,x
        cmp     #' '
        beq     ss_nx
        cmp     #','
        bne     ss_d
ss_nx:  inx
        bra     ss_lp
ss_d:   stx     LIDX
        cmp     #0
        rts

; hex number from LINE -> NUM (last 4 digits count). C=1 if there was one
gethex: jsr     skipsp
        stz     NUM
        stz     NUM+1
        stz     DIG
        cmp     #'$'
        bne     gh_lp
        inc     LIDX
gh_lp:  ldx     LIDX
        lda     LINE,x
        jsr     hexval
        bcs     gh_end
        ldy     #4
gh_sh:  asl     NUM
        rol     NUM+1
        dey
        bne     gh_sh
        ora     NUM
        sta     NUM
        inc     LIDX
        inc     DIG
        bra     gh_lp
gh_end: lda     DIG
        cmp     #1
        rts

; '0'-'9' 'A'-'F' -> 0-15 with C=0; anything else C=1, A unchanged
hexval: cmp     #'0'
        bcc     hv_no
        cmp     #'9'+1
        bcc     hv_dig
        cmp     #'A'
        bcc     hv_no
        cmp     #'F'+1
        bcs     hv_no
        sbc     #'A'-11                 ; C=0: A-'A'+10
        clc
        rts
hv_dig: sbc     #'0'-1                  ; C=0: A-'0'
        clc
        rts
hv_no:  sec
        rts

;---------------------------------------------------------------------------
; console
;---------------------------------------------------------------------------
getc:   lda     ACIA_STAT
        and     #$08
        beq     getc
        lda     ACIA_DATA
        rts

putc:   pha                             ; keeps A, X, Y
pc_w:   lda     ACIA_STAT
        and     #$10
        beq     pc_w
        pla
        sta     ACIA_DATA
        rts

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

crlf:   lda     #$0D
        jsr     putc
        lda     #$0A
        jmp     putc

hex16:  pha                             ; X = high, A = low
        txa
        jsr     hex8
        pla
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
s_banner:
        db      $0D,$0A,'MMON 1.0 for MyMENSCH Rev-C   ? = help',$0D,$0A,0
s_prompt:
        db      $0D,$0A,'>',0
s_what: db      '?',$0D,$0A,0
s_bs:   db      $08,' ',$08,0
s_3sp:  db      '   ',0
s_mine: db      'refused: $8000-$8FFF is the monitor',$0D,$0A,0
s_go:   db      'calling ',0
s_ret:  db      'returned:',$0D,$0A,0
s_brk:  db      'BRK at ',0
s_nmi:  db      'NMI at ',0
s_flags:
        db      'NV-BDIZC'
s_load: db      'send the S19 file now (ESC aborts)',$0D,$0A,0
s_abort:
        db      $0D,$0A,'aborted',0
s_recs: db      ' records, ',0
s_errs: db      ' bad, ',0
s_skip: db      ' bytes refused, ',0
s_nbad: db      ' bytes not written. G = ',0
s_bye:  db      'restarting',$0D,$0A,0
s_help: db      'D [start [end]]     dump memory (D alone continues)',$0D,$0A
        db      'I                   dump I/O $7F00-$7FFF',$0D,$0A
        db      'E addr [bb ..]      write bytes and show them',$0D,$0A
        db      'F start end bb      fill',$0D,$0A
        db      'G [addr]            call; RTS returns here',$0D,$0A
        db      'R [a [x [y [p]]]]   show/set registers for G',$0D,$0A
        db      'L                   load S19 (paste or Ctrl+T Ctrl+U)',$0D,$0A
        db      'X                   restart into WDC firmware',$0D,$0A
        db      'Free RAM: $0300-$7EFF, $9000-$F7FF.  IRQ vectors at $0260',$0D,$0A,0

        ENDS
        END
