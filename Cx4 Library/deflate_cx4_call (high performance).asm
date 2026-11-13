;===============================================================================
; DEFLATE decompression, Cx4 version
;
; Not hooked up to anything yet. JSL here from anywhere: it saves and restores
; the processor flags and the data bank.
;
; Input:
;   $8A-$8C  Address of the raw DEFLATE data in ROM (no zlib or gzip header)
;   $00-$02  Where to put the decompressed data in RAM
; Output:
;   $8A-$8C  Address right after the end of the compressed data
;
; The Cx4 decompresses into SRAM, then the SNES copies the result to RAM with
; DMA. At most $7C00 bytes, because the buffer ends at $70:7FFF.
;===============================================================================

!DeflateBuffer = $700400            ; Past SMW's save files ($70:0000-$70:0359)

            PHP
            PHB
            PHK                     ; \ Our bank has the Cx4 at $6000-$7FFF
            PLB                     ; /
            REP #$10                ; 16-bit X and Y
            SEP #$20                ; 8-bit A

            %Cx4DMA(.Tables, Cx4.RAM, .TablesEnd-.Tables) ; Tables to data RAM $000

            LDX $8A                 ; \
            STX.w Cx4.R0            ;  | R0 = source
            LDA $8C                 ;  |
            STA.w Cx4.R0+2          ; /
            LDX.w #!DeflateBuffer   ; \
            STX.w Cx4.R1            ;  | R1 = !DeflateBuffer
            LDA.b #!DeflateBuffer>>16 ; |
            STA.w Cx4.R1+2          ; /

            %Cx4Preload(Cx4SMW_DeflateDecode, 1) ; Page 03 (decoding) into cache page 1
            %Cx4PreloadedRun(Cx4SMW_Deflate, 0)  ; Page 02 (headers, tables) into cache page 0, then run

            LDX.w Cx4.R0            ; \
            STX $8A                 ;  | Where the compressed data ended
            LDA.w Cx4.R0+2          ;  |
            STA $8C                 ; /

            REP #$20                ; \
            LDA.w Cx4.R1            ;  | Number of bytes the Cx4 wrote
            SEC                     ;  |
            SBC.w #!DeflateBuffer   ;  |
            BEQ .Done               ; /
            STA $4335               ; \
            LDA.w #!DeflateBuffer   ;  |
            STA $4332               ;  | DMA them from SRAM to RAM [$00]
            LDA $00                 ;  | with channel 3
            STA $2181               ;  |
            SEP #$20                ;  |
            LDA.b #!DeflateBuffer>>16 ; |
            STA $4334               ;  |
            LDA $02                 ;  |
            STA $2183               ;  |
            STZ $4330               ;  | 1 byte write once
            LDA #$80                ;  | $2180 (WRAM write)
            STA $4331               ;  |
            LDA #$08                ;  |
            STA $420B               ; /

.Done       PLB
            PLP
            RTL

;===============================================================================
; Tables for the Cx4. They go to data RAM $000, where its code reads them at
; these offsets with 8-bit immediates: keep them in this order and within 256
; bytes, with 19 bytes to spare after them.
;===============================================================================

macro DeflateCode(base, extra)
            dw <base>
            db <extra>
endmacro

; Base and number of extra bits of each distance code and length code
; (RFC 1951, 3.2.5). The bases are 1 less for distances and 2 less for lengths
; than in the RFC: the Cx4 adds that back with the same ADD for the codes
; without extra bits.
.Tables
.CodeTab    %DeflateCode(1-1, 0)        ; Distance codes 0-29
            %DeflateCode(2-1, 0)
            %DeflateCode(3-1, 0)
            %DeflateCode(4-1, 0)
            %DeflateCode(5-1, 1)
            %DeflateCode(7-1, 1)
            %DeflateCode(9-1, 2)
            %DeflateCode(13-1, 2)
            %DeflateCode(17-1, 3)
            %DeflateCode(25-1, 3)
            %DeflateCode(33-1, 4)
            %DeflateCode(49-1, 4)
            %DeflateCode(65-1, 5)
            %DeflateCode(97-1, 5)
            %DeflateCode(129-1, 6)
            %DeflateCode(193-1, 6)
            %DeflateCode(257-1, 7)
            %DeflateCode(385-1, 7)
            %DeflateCode(513-1, 8)
            %DeflateCode(769-1, 8)
            %DeflateCode(1025-1, 9)
            %DeflateCode(1537-1, 9)
            %DeflateCode(2049-1, 10)
            %DeflateCode(3073-1, 10)
            %DeflateCode(4097-1, 11)
            %DeflateCode(6145-1, 11)
            %DeflateCode(8193-1, 12)
            %DeflateCode(12289-1, 12)
            %DeflateCode(16385-1, 13)
            %DeflateCode(24577-1, 13)
            %DeflateCode(3-2, 0)        ; Length codes 257-285
            %DeflateCode(4-2, 0)
            %DeflateCode(5-2, 0)
            %DeflateCode(6-2, 0)
            %DeflateCode(7-2, 0)
            %DeflateCode(8-2, 0)
            %DeflateCode(9-2, 0)
            %DeflateCode(10-2, 0)
            %DeflateCode(11-2, 1)
            %DeflateCode(13-2, 1)
            %DeflateCode(15-2, 1)
            %DeflateCode(17-2, 1)
            %DeflateCode(19-2, 2)
            %DeflateCode(23-2, 2)
            %DeflateCode(27-2, 2)
            %DeflateCode(31-2, 2)
            %DeflateCode(35-2, 3)
            %DeflateCode(43-2, 3)
            %DeflateCode(51-2, 3)
            %DeflateCode(59-2, 3)
            %DeflateCode(67-2, 4)
            %DeflateCode(83-2, 4)
            %DeflateCode(99-2, 4)
            %DeflateCode(115-2, 4)
            %DeflateCode(131-2, 5)
            %DeflateCode(163-2, 5)
            %DeflateCode(195-2, 5)
            %DeflateCode(227-2, 5)
            %DeflateCode(258-2, 0)

; Where the code length code lengths go, in the order they come (RFC 1951,
; 3.2.7): the data RAM address of the symbol's code length. The code lengths
; are right after these tables
!ClenLens = .TablesEnd-.Tables
.ClenOrder  db !ClenLens+16, !ClenLens+17, !ClenLens+18, !ClenLens+0, !ClenLens+8
            db !ClenLens+7, !ClenLens+9, !ClenLens+6, !ClenLens+10, !ClenLens+5
            db !ClenLens+11, !ClenLens+4, !ClenLens+12, !ClenLens+3, !ClenLens+13
            db !ClenLens+2, !ClenLens+14, !ClenLens+1, !ClenLens+15

; Code lengths of the fixed Huffman codes (RFC 1951, 3.2.6), as runs of
; count | (length - 4). The counts are multiples of 8
.FixedRuns  db 144|(8-4)                ; Literals 0-143: 8 bits
            db 112|(9-4)                ; Literals 144-255: 9 bits
            db 24|(7-4)                 ; 256-279: 7 bits
            db 8|(8-4)                  ; 280-287: 8 bits
            db 32|(5-4)                 ; Distance codes 0-31: 5 bits
.TablesEnd

assert .TablesEnd-.Tables+19 <= 256, "Deflate tables: too big for the Cx4's 8-bit offsets"

undef "ClenLens"
undef "DeflateBuffer"
