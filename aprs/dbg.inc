;***************************************************************************
;  FILE:   dbg.inc
;  TITLE:  Debug dump helpers for the MyMENSCH (65C02), output on ACIA_A
;
;  Include inside your CODE section:      INCLUDE 'dbg.inc'
;  (from aprs/probe/ use:                 INCLUDE '..\dbg.inc')
;
;  Every call keeps A, X, Y, the flags (incl. D and I) and zero page.
;  Each uses at most 9 bytes of stack.
;
;  jsr dbg_regs
;      prints:   @8123 A=5A X=03 Y=00 S=FD P=B1 NV-BdIzC
;      @ is the address of the jsr. Flag letters are capitals when set,
;      lower case when clear (B always shows set: php pushes it as 1).
;
;  jsr dbg_mem          dump a block of memory or I/O
;  dw  $7FB0            start address
;  db  5                byte count (1-255, 0 = 256)
;      prints:   7FB0: 00 00 00 00 00      (16 bytes a line)
;      $7F60 (ACIA_A data) prints as -- so the dump doesn't eat a key.
;
;  jsr dbg_list         named single registers, list ends with dw 0
;  dw  $7FB4            address
;  db  'CTRL',0         name
;  dw  $7FB3
;  db  'SEQD',0
;  dw  0
;      prints:   CTRL=00 SEQD=03
;
;  Uses zero page $FE/$FF internally but restores them.
;***************************************************************************

DBG_DATA        EQU     $7F60           ; ACIA_A data
DBG_STAT        EQU     $7F61           ; ACIA_A status, bit 4 = TX empty
DBG_ZP          EQU     $FE             ; 2 bytes, saved and restored

;---------------------------------------------------------------------------
dbg_regs:
        php
        pha
        phx
        phy
        cld
        tsx                             ; $101,x=Y  $102=X  $103=A  $104=P
        jsr     dbg_crlf                ; $105/$106 = return address
        lda     #'@'
        jsr     dbg_putc
        lda     $105,x                  ; jsr address = return address - 2
        sec
        sbc     #2
        tay
        lda     $106,x
        sbc     #0
        jsr     dbg_hex8
        tya
        jsr     dbg_hex8
        lda     #'A'
        ldy     $103,x
        jsr     dbg_field
        lda     #'X'
        ldy     $102,x
        jsr     dbg_field
        lda     #'Y'
        ldy     $101,x
        jsr     dbg_field
        txa                             ; caller's S = ours + 6
        clc
        adc     #6
        tay
        lda     #'S'
        jsr     dbg_field
        lda     #'P'
        ldy     $104,x
        jsr     dbg_field
        lda     #' '
        jsr     dbg_putc
        lda     $104,x
        ldy     #0
dr_fl:  asl     a
        pha
        lda     dbg_flags,y
        bcs     dr_up
        cmp     #'-'
        beq     dr_up
        ora     #$20                    ; lower case = clear
dr_up:  jsr     dbg_putc
        pla
        iny
        cpy     #8
        bne     dr_fl
        jsr     dbg_crlf
        ply
        plx
        pla
        plp
        rts

; print " c=yy" with c in A, value in Y; keeps X
dbg_field:
        pha
        lda     #' '
        jsr     dbg_putc
        pla
        jsr     dbg_putc
        lda     #'='
        jsr     dbg_putc
        tya
        jmp     dbg_hex8

;---------------------------------------------------------------------------
dbg_mem:
        php
        pha
        phx
        phy
        cld
        lda     DBG_ZP
        pha
        lda     DBG_ZP+1
        pha
        tsx                             ; $107/$108,x = return address
        lda     $107,x
        sta     DBG_ZP
        lda     $108,x
        sta     DBG_ZP+1
        clc                             ; skip the 3 parameter bytes
        lda     $107,x
        adc     #3
        sta     $107,x
        bcc     dm_nc
        inc     $108,x
dm_nc:  ldy     #3
        lda     (DBG_ZP),y
        tax                             ; X = count (0 = 256)
        ldy     #1
        lda     (DBG_ZP),y
        pha
        iny
        lda     (DBG_ZP),y
        sta     DBG_ZP+1
        pla
        sta     DBG_ZP                  ; DBG_ZP = start
        ldy     #0
dm_lp:  tya
        and     #$0F
        bne     dm_sp
        jsr     dbg_crlf                ; new line: "aaaa:"
        tya
        clc
        adc     DBG_ZP
        pha
        lda     DBG_ZP+1
        adc     #0
        jsr     dbg_hex8
        pla
        jsr     dbg_hex8
        lda     #':'
        jsr     dbg_putc
dm_sp:  lda     #' '
        jsr     dbg_putc
        tya                             ; is this $7F60?
        clc
        adc     DBG_ZP
        pha
        lda     DBG_ZP+1
        adc     #0
        cmp     #>DBG_DATA
        bne     dm_rd1
        pla
        cmp     #<DBG_DATA
        bne     dm_rd
        lda     #'-'
        jsr     dbg_putc
        jsr     dbg_putc
        bra     dm_nx
dm_rd1: pla
dm_rd:  lda     (DBG_ZP),y
        jsr     dbg_hex8
dm_nx:  iny
        dex
        bne     dm_lp
        jsr     dbg_crlf
        pla
        sta     DBG_ZP+1
        pla
        sta     DBG_ZP
        ply
        plx
        pla
        plp
        rts

;---------------------------------------------------------------------------
dbg_list:
        php
        pha
        phx
        phy
        cld
        lda     DBG_ZP
        pha
        lda     DBG_ZP+1
        pha
        tsx                             ; DBG_ZP walks the inline list
        lda     $107,x
        sta     DBG_ZP
        lda     $108,x
        sta     DBG_ZP+1
        jsr     dbg_crlf
        ldy     #1                      ; Y = offset of the next entry
dl_ent: lda     (DBG_ZP),y              ; address lo
        pha
        iny
        ora     (DBG_ZP),y              ; dw 0 ends the list
        beq     dl_end
        lda     (DBG_ZP),y              ; address hi
        pha
        iny
dl_nm:  lda     (DBG_ZP),y              ; name
        iny
        cmp     #0
        beq     dl_val
        jsr     dbg_putc
        bra     dl_nm
dl_val: lda     #'='
        jsr     dbg_putc
        pla                             ; build the address in $FE/$FF
        tax                             ;   (hi in X for a moment)
        pla
        phy
        ldy     DBG_ZP                  ; keep the list pointer on the stack
        phy
        ldy     DBG_ZP+1
        phy
        sta     DBG_ZP
        stx     DBG_ZP+1
        cmp     #<DBG_DATA
        bne     dl_rd
        cpx     #>DBG_DATA
        bne     dl_rd
        lda     #'-'
        jsr     dbg_putc
        jsr     dbg_putc
        bra     dl_rs
dl_rd:  lda     (DBG_ZP)
        jsr     dbg_hex8
dl_rs:  ply
        sty     DBG_ZP+1
        ply
        sty     DBG_ZP
        ply
        lda     #' '
        jsr     dbg_putc
        bra     dl_ent
dl_end: pla                             ; drop address lo
        tya                             ; return past the dw 0:
        clc                             ;   list start + Y (Y = hi byte
        adc     DBG_ZP                  ;   offset of the terminator)
        pha
        lda     DBG_ZP+1
        adc     #0
        tsx
        sta     $109,x                  ; $108,x = return lo (one pla below)
        pla
        sta     $108,x
        jsr     dbg_crlf
        pla
        sta     DBG_ZP+1
        pla
        sta     DBG_ZP
        ply
        plx
        pla
        plp
        rts

;---------------------------------------------------------------------------
; console: keep A, X, Y
dbg_putc:
        pha
dbg_pw: lda     DBG_STAT
        and     #$10
        beq     dbg_pw
        pla
        sta     DBG_DATA
        rts

dbg_crlf:
        pha
        lda     #$0D
        jsr     dbg_putc
        lda     #$0A
        jsr     dbg_putc
        pla
        rts

dbg_hex8:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     dbg_hex4
        pla
        pha
        jsr     dbg_hex4
        pla
        rts
dbg_hex4:
        and     #$0F
        cmp     #10
        bcc     dbg_hd
        adc     #6                      ; C=1: +7 -> 'A'
dbg_hd: adc     #'0'
        jmp     dbg_putc

dbg_flags:
        db      'NV-BDIZC'
