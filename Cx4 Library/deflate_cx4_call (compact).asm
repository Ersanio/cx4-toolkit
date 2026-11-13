;===============================================================================
; DEFLATE decompression, Cx4 version
;
; Not used by the game yet. Call it with JSL. It keeps the caller's P, A, X and Y
; sizes.
;
; Input:
;   $8A-$8C  Address of the compressed data in ROM (raw DEFLATE)
;   $00-$02  Address in WRAM to decompress to
; Output:
;   $8A-$8C  Address right after the end of the compressed data
;   Y        Size of the decompressed data
;===============================================================================

!DeflateBuffer = $700400            ; Past SMW's save files ($70:0000-$70:0359)
                                    ; The decompressed data can be up to $7C00 bytes

; Cx4 RAM that the Cx4 routine uses for its Huffman trees. Both tree addresses
; must fit in an 8-bit immediate. They are defined here because the tables
; below need them, and this file comes before cx4 lib/smw 03.asm.
!Deflate2DistTree = $00             ; $000-$05D: 15 links + 32 symbols. Also holds the
                                    ;            code length tree while reading a block's trees
!Deflate2LitTree  = $5E             ; $05E-$2BB: 15 links + 288 symbols
!Deflate2Lengths  = $02BC           ; $2BC-$53B: 288 + 32 code lengths, 16-bit each

            PHP
            PHB
            PHK                         ; \ Our bank has the Cx4 at $6000-$7FFF
            PLB                         ; /
            REP #$10                    ; 16-bit X and Y
            SEP #$20                    ; 8-bit A

            LDX $8A                     ; \
            STX.w Cx4.R0                ;  | R0 = source
            LDA $8C                     ;  |
            STA.w Cx4.R0+2              ; /
            LDX.w #!DeflateBuffer       ; \
            STX.w Cx4.R1                ;  | R1 = !DeflateBuffer
            LDA.b #!DeflateBuffer>>16   ;  |
            STA.w Cx4.R1+2              ; /
            %Cx4ColdRun(Cx4SMW_Deflate2)

            LDX.w Cx4.R0
            STX $8A
            LDA.w Cx4.R0+2
            STA $8C

            REP #$20
            LDA.w Cx4.R1
            SEC
            SBC.w #!DeflateBuffer
            TAY
            BEQ .Done
            STA $4335
            LDA.w #!DeflateBuffer
            STA $4332
            LDA $00
            STA $2181
            SEP #$20
            LDA.b #!DeflateBuffer>>16
            STA $4334
            LDA $02
            STA $2183
            STZ $4330
            LDA #$80
            STA $4331
            LDA #$08
            STA $420B

.Done       PLB
            PLP
            RTL

;===============================================================================
; Tables for the Cx4 routine (cx4 lib/smw 03.asm)
;
; The Cx4 reads them with ..ReadExtra. Each row is 4 bytes: a 16-bit base (high
; byte first), a number of extra bits to read from the compressed data, and an
; unused byte. ..ReadExtra returns the base + the extra bits.
; All of it must stay in one bank, and DEFLATE_FixedTrees within 255 bytes
; of DEFLATE.
;===============================================================================

macro DeflateRow(base, bits)
            db (<base>)>>8, (<base>)&$FF, <bits>, $00
endmacro

DEFLATE:
; Distance symbols 0-29. The row is the symbol
.Distance   %DeflateRow(1, 0)                       ;  0: 1
            %DeflateRow(2, 0)                       ;  1: 2
            %DeflateRow(3, 0)                       ;  2: 3
            %DeflateRow(4, 0)                       ;  3: 4
            %DeflateRow(5, 1)                       ;  4: 5-6
            %DeflateRow(7, 1)                       ;  5: 7-8
            %DeflateRow(9, 2)                       ;  6: 9-12
            %DeflateRow(13, 2)                      ;  7: 13-16
            %DeflateRow(17, 3)                      ;  8: 17-24
            %DeflateRow(25, 3)                      ;  9: 25-32
            %DeflateRow(33, 4)                      ; 10: 33-48
            %DeflateRow(49, 4)                      ; 11: 49-64
            %DeflateRow(65, 5)                      ; 12: 65-96
            %DeflateRow(97, 5)                      ; 13: 97-128
            %DeflateRow(129, 6)                     ; 14: 129-192
            %DeflateRow(193, 6)                     ; 15: 193-256
            %DeflateRow(257, 7)                     ; 16: 257-384
            %DeflateRow(385, 7)                     ; 17: 385-512
            %DeflateRow(513, 8)                     ; 18: 513-768
            %DeflateRow(769, 8)                     ; 19: 769-1024
            %DeflateRow(1025, 9)                    ; 20: 1025-1536
            %DeflateRow(1537, 9)                    ; 21: 1537-2048
            %DeflateRow(2049, 10)                   ; 22: 2049-3072
            %DeflateRow(3073, 10)                   ; 23: 3073-4096
            %DeflateRow(4097, 11)                   ; 24: 4097-6144
            %DeflateRow(6145, 11)                   ; 25: 6145-8192
            %DeflateRow(8193, 12)                   ; 26: 8193-12288
            %DeflateRow(12289, 12)                  ; 27: 12289-16384
            %DeflateRow(16385, 13)                  ; 28: 16385-24576
            %DeflateRow(24577, 13)                  ; 29: 24577-32768

; The trees of a block with fixed Huffman codes, in the format of a block with
; dynamic Huffman codes: 288 literal/length code lengths (144x 8, 112x 9,
; 24x 7, 8x 8) and 32 distance code lengths (32x 5). 224 bits.
.FixedTrees db $FF,$5B,$00,$88,$03,$98,$6D,$DB
            db $B6,$6D,$DB,$B6,$6D,$DB,$E6,$6C
            db $DB,$B6,$6D,$DB,$B6,$6D,$BC,$6D
            db $26,$9C,$6D,$0B

; The counts at the start of a block's trees
.HLIT       %DeflateRow(257, 5)                     ; Literal/length code lengths, 257-288
.HDIST      %DeflateRow(1, 5)                       ; Distance code lengths, 1-32
.HCLEN      %DeflateRow((.Order-DEFLATE)/4+3, 4)    ; Code length code lengths, 4-19, as the
                                                    ; last row of .Order that the data has

; Plain bits
.Bits3      %DeflateRow(0, 3)
.Bits8      %DeflateRow(0, 8)
.Bits16     %DeflateRow(0, 16)

; Length symbols 257-285
.Length     %DeflateRow(3, 0)                       ; 257: 3
            %DeflateRow(4, 0)                       ; 258: 4
            %DeflateRow(5, 0)                       ; 259: 5
            %DeflateRow(6, 0)                       ; 260: 6
            %DeflateRow(7, 0)                       ; 261: 7
            %DeflateRow(8, 0)                       ; 262: 8
            %DeflateRow(9, 0)                       ; 263: 9
            %DeflateRow(10, 0)                      ; 264: 10
            %DeflateRow(11, 1)                      ; 265: 11-12
            %DeflateRow(13, 1)                      ; 266: 13-14
            %DeflateRow(15, 1)                      ; 267: 15-16
            %DeflateRow(17, 1)                      ; 268: 17-18
            %DeflateRow(19, 2)                      ; 269: 19-22
            %DeflateRow(23, 2)                      ; 270: 23-26
            %DeflateRow(27, 2)                      ; 271: 27-30
            %DeflateRow(31, 2)                      ; 272: 31-34
            %DeflateRow(35, 3)                      ; 273: 35-42
            %DeflateRow(43, 3)                      ; 274: 43-50
            %DeflateRow(51, 3)                      ; 275: 51-58
            %DeflateRow(59, 3)                      ; 276: 59-66
            %DeflateRow(67, 4)                      ; 277: 67-82
            %DeflateRow(83, 4)                      ; 278: 83-98
            %DeflateRow(99, 4)                      ; 279: 99-114
            %DeflateRow(115, 4)                     ; 280: 115-130
            %DeflateRow(131, 5)                     ; 281: 131-162
            %DeflateRow(163, 5)                     ; 282: 163-194
            %DeflateRow(195, 5)                     ; 283: 195-226
            %DeflateRow(227, 5)                     ; 284: 227-258
            %DeflateRow(258, 0)                     ; 285: 258

; Code length symbols 0-18: How many times to write a code length
.CodeLength %DeflateRow(1, 0)                       ;  0
            %DeflateRow(1, 0)                       ;  1
            %DeflateRow(1, 0)                       ;  2
            %DeflateRow(1, 0)                       ;  3
            %DeflateRow(1, 0)                       ;  4
            %DeflateRow(1, 0)                       ;  5
            %DeflateRow(1, 0)                       ;  6
            %DeflateRow(1, 0)                       ;  7
            %DeflateRow(1, 0)                       ;  8
            %DeflateRow(1, 0)                       ;  9
            %DeflateRow(1, 0)                       ; 10
            %DeflateRow(1, 0)                       ; 11
            %DeflateRow(1, 0)                       ; 12
            %DeflateRow(1, 0)                       ; 13
            %DeflateRow(1, 0)                       ; 14
            %DeflateRow(1, 0)                       ; 15
            %DeflateRow(3, 2)                       ; 16: Previous length, 3-6 times
            %DeflateRow(3, 3)                       ; 17: 0, 3-10 times
            %DeflateRow(11, 7)                      ; 18: 0, 11-138 times

; The order in which the data has the lengths of the code length symbols.
; Each row holds the address of that symbol's length in Cx4 RAM.
.Order      %DeflateRow(!Deflate2Lengths+16*2, 0)    ; 16
            %DeflateRow(!Deflate2Lengths+17*2, 0)    ; 17
            %DeflateRow(!Deflate2Lengths+18*2, 0)    ; 18
            %DeflateRow(!Deflate2Lengths+0*2, 0)     ; 0
            %DeflateRow(!Deflate2Lengths+8*2, 0)     ; 8
            %DeflateRow(!Deflate2Lengths+7*2, 0)     ; 7
            %DeflateRow(!Deflate2Lengths+9*2, 0)     ; 9
            %DeflateRow(!Deflate2Lengths+6*2, 0)     ; 6
            %DeflateRow(!Deflate2Lengths+10*2, 0)    ; 10
            %DeflateRow(!Deflate2Lengths+5*2, 0)     ; 5
            %DeflateRow(!Deflate2Lengths+11*2, 0)    ; 11
            %DeflateRow(!Deflate2Lengths+4*2, 0)     ; 4
            %DeflateRow(!Deflate2Lengths+12*2, 0)    ; 12
            %DeflateRow(!Deflate2Lengths+3*2, 0)     ; 3
            %DeflateRow(!Deflate2Lengths+13*2, 0)    ; 13
            %DeflateRow(!Deflate2Lengths+2*2, 0)     ; 2
            %DeflateRow(!Deflate2Lengths+14*2, 0)    ; 14
            %DeflateRow(!Deflate2Lengths+1*2, 0)     ; 1
            %DeflateRow(!Deflate2Lengths+15*2, 0)    ; 15
