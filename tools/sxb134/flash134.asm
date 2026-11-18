;***************************************************************************
;  FILE:   flash134.asm
;  TITLE:  SST39SF010A writer for the W65C134SXB, run from RAM at $7000
;
;  sxb134.py --flash loads this, fills in the parameter block at $7003,
;  stages up to 4 KB of data in RAM and runs it with J7000; it prints one
;  line ("FLASH OK" or "FLASH ERR s aaaa") and returns to the monitor.
;  The parameter block also holds the result, which sxb134.py reads back.
;
;  The chip: SST39SF010A, 128 KB, 4 KB sectors, JEDEC commands at chip
;  addresses $5555 / $2AAA (the probe flashid.asm confirmed BF B5 on the
;  SXB, so writes do reach it). On the SXB the CPU sees 32 KB of it at
;  $8000-$EFFF ($F000 up is the 134's own ROM); chip A15 = P34 (FA15) and
;  A16 = P35 (FAMS) pick which 32 KB bank. The ROM monitor sets P34 = P35 = 1
;  at reset and only then looks for 'WDC' at $8000, so bank 3 is the one
;  that boots.
;
;  Commands are written with the bank lines at 0 (chip $5555 = CPU $D555,
;  chip $2AAA = CPU $AAAA); the bank lines are switched to the target bank
;  only for the data / sector-address cycle. Completion is found with the
;  DQ6 toggle bit; a 16-bit loop count (about 0.5 s) is the timeout.
;  Interrupts are off while it runs (at most ~0.2 s per 4 KB).
;***************************************************************************

        PW      132
        CHIP    65C02
        LONGA   OFF
        LONGI   OFF

PD3             EQU     $03
FBANK           EQU     $30             ; P34 = FA15, P35 = FAMS
OUTCH           EQU     $F00F

PTR             EQU     $B0             ; flash address
SRC             EQU     $B2             ; data in RAM
CNT             EQU     $B4             ; bytes left
TMO             EQU     $B6             ; timeout count
T6              EQU     $B8
DAT             EQU     $B9

        CODE
        ORG     $7000
        jmp     start

; ---- parameter block ($7003), written by sxb134.py ----
p_op:   db      0       ; bit 0 = erase the 4 KB sector at p_dst, bit 1 = program,
                        ; bit 2 = only fill p_src..+p_len with $FF (staging)
p_bank: db      3       ; 0-3: chip A16:A15
p_dst:  dw      $8000   ; CPU address, $8000-$EFFF
p_src:  dw      $1000   ; data in RAM
p_len:  dw      $1000   ; bytes (program and verify)
p_stat: db      $EE     ; result: 0 OK, 1 bad parameters, 2 erase timeout,
                        ;   3 program timeout, 4 verify mismatch, $EE = not run
p_bad:  dw      0       ; address where it failed

start:  sei
        lda     p_op
        and     #4
        beq     st_a
        jsr     setup                   ; fill the staging buffer with $FF
fl_a:   lda     CNT
        ora     CNT+1
        beq     fl_b
        lda     #$FF
        sta     (SRC)
        jsr     next
        bra     fl_a
fl_b:   stz     p_stat
        jmp     fail
st_a:   lda     #1
        sta     p_stat
        lda     p_dst+1                 ; $8000 <= dst, dst + len <= $F000
        cmp     #$80
        bcc     fail
        clc
        lda     p_dst
        adc     p_len
        tax
        lda     p_dst+1
        adc     p_len+1
        bcs     fail
        cmp     #$F0
        bcc     ok1
        bne     fail
        cpx     #0
        bne     fail
ok1:    lda     p_bank
        cmp     #4
        bcs     fail
        asl     a                       ; bank -> PD3 bits 4-5
        asl     a
        asl     a
        asl     a
        sta     T6

        lda     p_op
        lsr     a
        bcc     no_er
        jsr     erase
        bcs     fail
no_er:  lda     p_op
        and     #2
        beq     no_pr
        jsr     program
        bcs     fail
no_pr:  jsr     verify
        bcs     fail
        stz     p_stat
fail:   lda     #FBANK                  ; bank lines back to 1, as the
        tsb     PD3                     ; monitor leaves them
        cli
        ldx     #0
        lda     p_stat
        bne     f_err
        jsr     puts                    ; "FLASH OK"
        rts
f_err:  ldx     #s_err-s_all
        jsr     puts
        lda     p_stat
        jsr     hex
        lda     p_bad+1
        jsr     hex
        lda     p_bad
        jsr     hex
        rts

; bank lines: 0 for commands, T6 for the target
bank0:  lda     #FBANK
        trb     PD3
        rts
bankt:  lda     #FBANK
        trb     PD3
        lda     T6
        tsb     PD3
        rts

unlock: jsr     bank0
        lda     #$AA
        sta     $D555
        lda     #$55
        sta     $AAAA
        rts

; wait for DQ6 to stop toggling at (PTR); C = 1 on timeout
waitq:  stz     TMO
        stz     TMO+1
wq_a:   lda     (PTR)
        and     #$40
        sta     DAT
        lda     (PTR)
        and     #$40
        cmp     DAT
        beq     wq_ok
        inc     TMO
        bne     wq_a
        inc     TMO+1
        bne     wq_a
        sec
        rts
wq_ok:  clc
        rts

; erase the 4 KB sector holding p_dst
erase:  lda     #2
        sta     p_stat
        stz     PTR
        lda     p_dst+1
        and     #$F0
        sta     PTR+1
        sta     p_bad+1
        stz     p_bad
        jsr     unlock
        lda     #$80
        sta     $D555
        jsr     unlock
        jsr     bankt
        lda     #$30
        sta     (PTR)
        jmp     waitq

; program p_len bytes from p_src to p_dst ($FF bytes are left erased)
program:
        lda     #3
        sta     p_stat
        jsr     setup
pr_a:   lda     CNT
        ora     CNT+1
        beq     pr_ok
        lda     (SRC)
        cmp     #$FF
        beq     pr_n
        sta     DAT
        jsr     unlock
        lda     #$A0
        sta     $D555
        jsr     bankt
        lda     DAT
        sta     (PTR)
        jsr     waitq
        bcs     pr_bad
pr_n:   jsr     next
        bra     pr_a
pr_ok:  clc
        rts
pr_bad: lda     PTR
        sta     p_bad
        lda     PTR+1
        sta     p_bad+1
        sec
        rts

; compare p_len bytes
verify: lda     #4
        sta     p_stat
        jsr     setup
        jsr     bankt
vf_a:   lda     CNT
        ora     CNT+1
        beq     pr_ok
        lda     (SRC)
        cmp     (PTR)
        bne     pr_bad
        jsr     next
        bra     vf_a

setup:  lda     p_dst
        sta     PTR
        lda     p_dst+1
        sta     PTR+1
        lda     p_src
        sta     SRC
        lda     p_src+1
        sta     SRC+1
        lda     p_len
        sta     CNT
        lda     p_len+1
        sta     CNT+1
        rts

next:   inc     PTR
        bne     nx_a
        inc     PTR+1
nx_a:   inc     SRC
        bne     nx_b
        inc     SRC+1
nx_b:   lda     CNT
        bne     nx_c
        dec     CNT+1
nx_c:   dec     CNT
        rts

puts:   lda     s_all,x
        beq     p_x
        phx
        jsr     OUTCH
        plx
        inx
        bra     puts
p_x:    rts

hex:    pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     nib
        pla
nib:    and     #$0F
        ora     #'0'
        cmp     #'9'+1
        bcc     n_x
        adc     #6
n_x:    jmp     OUTCH

s_all:  db      13,10,'FLASH OK',0
s_err:  db      13,10,'FLASH ERR ',0

        ENDS
        END
