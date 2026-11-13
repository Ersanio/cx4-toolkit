;===============================================================================
; Cx4 DEFLATE decompression (inflate)
;
; In:  R0   Address of the compressed data in ROM, 24-bit. Raw DEFLATE (RFC 1951)
;           without a zlib or gzip header, like zopfli --deflate makes.
;           LoROM, banks $00-$3F or $80-$BF, $8000-$FFFF. The data may cross
;           banks.
;      R1   Where to write the output, in SRAM ($70:0000-$70:7FFF)
;      Data RAM $000-$0C8: NewDeflate_Tables, copied there by the SNES with
;           Cx4 DMA (see ["deflate_cx4_call (high performance).asm"])
; Out: R0   Address right after the end of the compressed data
;      R1   Address right after the end of the decompressed data
;
; Modifies R2-R15, MAR, MDR, RAMB, DPR, P and data RAM $0C9-$BFF.
;
; Two pages. The SNES preloads both before it starts the program, so no page
; is loaded while it runs:
;   Page 02  Entry point, block headers, stored blocks, building the Huffman
;            tables
;   Page 03  Decoding loop (literals and copies), bit reader, the end of the
;            table builder
;
; Optimized for cycles. Huffman codes are decoded with lookup tables, like
; zlib does: the next 9 bits (7 for distances) index a table that gives the
; symbol and the code's length at once. In SMW's graphics, 88% of the
; literal/length codes and 99% of the distance codes are that short. The
; longer ones continue in the slow path from where the table left off, one
; bit at a time.
;
; Copies read the output back from SRAM: they reach up to 32 KB back, and the
; 3 KB of data RAM are too small to keep that much.
;
; A broken stream isn't detected and can make the Cx4 write garbage or hang.
; Only the reserved block type 3 stops the program.
;
; All chip behavior this relies on is bsnes behavior, not hardware-confirmed.
;===============================================================================

; Registers used everywhere
!SourceAddr     = R0                ; Next byte of compressed data to read into the bit buffer
!Destination    = R1                ; Next byte of output
!BitBuf         = R2                ; Bit buffer. Bit 0 is the next bit of the stream
!BitCnt         = R3                ; Number of bits in the bit buffer (0-23)
!Header         = R4                ; Block header. Bit 0 is set for the last block

;-------------------------------------------------------------------------------
; Data RAM layout
;
;   $000-$0C8  NewDeflate_Tables, from the SNES
;   $0C9-$0DB  Code lengths of the 19 code length codes
;   $100-$4FF  Literal/length lookup table, 512 entries
;   $500-$55F  Distance tree: T[], then 32 entries. Also the code length tree
;   $560-$69F  Code lengths of a block, 1 byte per symbol (288 + 32)
;   $700-$95F  Literal/length tree: T[], then 288 entries
;   $B00-$BFF  Distance lookup table, 128 entries. Also the code length table
;
; A lookup table has a 2-byte entry for each value of the next 9 (or 7) bits:
; symbol << 4 | code length. For a code that is longer than that, the symbol
; is $120 + where the slow path continues (see ..Slow), and the code length
; is the table's 9 (or 7) bits.
;
; A tree is what the slow path and the table builder need. It starts with 16
; words T[0-15]: T[L] is the index of the first code longer than L bits. At
; +$20 come the entries of all used symbols, sorted by code, 2 bytes each, in
; the same format as the lookup table.
;
; Bits 16-23 of RAMB stay 0 the whole time, so that LD A, RAMB gives the 16
; bits read by RDRAM 0 and RDRAM 1: RDRAM 2 is never used, and every value
; stored into RAMB is below $10000.
;-------------------------------------------------------------------------------
!DeflateTables      = $000          ; NewDeflate_Tables, from the SNES
!DeflateCodeTab     = NewDeflate_CodeTab-NewDeflate_Tables      ; Base and extra bits of each distance and length code
!DeflateClenOrder   = NewDeflate_ClenOrder-NewDeflate_Tables    ; Where each code length code length goes
!DeflateFixedRuns   = NewDeflate_FixedRuns-NewDeflate_Tables    ; Code lengths of the fixed Huffman codes
!DeflateClenLens    = NewDeflate_TablesEnd-NewDeflate_Tables    ; Code lengths of the 19 code length codes
!DeflateLitFast     = $000100       ; Literal/length lookup table, 512 entries ($100-$4FF). Spelled like IR14
!DeflateDistTree    = $500          ; Distance tree, 32 symbols (= its lookup table + $600)
!DeflateLens        = $560          ; Code lengths of a dynamic block, 1 byte each (320)
!DeflateLitTree     = $700          ; Literal/length tree, 288 symbols (= its lookup table + $600)
!DeflateDistFast    = $00FF00       ; Distance lookup table, 128 entries. Spelled like IR2, so that
                                    ; ADD A << 1 can add it without a register. Data RAM addresses
                                    ; are 12 bits, and $C00-$FFF land on $800-$BFF (bsnes and MesenCE,
                                    ; not hardware-confirmed; manual 8.2.1), so it is at $B00-$BFF

assert !DeflateClenLens+19 <= $100, "Deflate: the tables from ROM are too big"
assert !DeflateLens+320 <= !DeflateLitTree && !DeflateLitTree+$260 <= $B00, "Deflate: the data RAM areas overlap"

; Subroutines in page 03 that page 02 calls with JSR P:, with P = page 03
!GetBits        = Cx4SMW_DeflateDecode_GetBits
!DecodeDist     = Cx4SMW_DeflateDecode_DecodeDist

; Block header registers (page 02)
!RunAddr        = R5                ; Data RAM address the next code length goes to
!RunValue       = R6                ; Code length that ..Run writes. Also the previous length, for code 16
!RunLast        = R7                ; Last address that ..Run writes
!ClenAddr       = R8                ; Where the next code length code length goes
!DistLens       = R12               ; Address of the distance code lengths (!DeflateLens + HLIT)
!HDist          = R13               ; Number of distance codes
!ClenLast       = R15               ; HCLEN - 1
!LensLast       = R15               ; Address of the block's last code length
!StoredLeft     = R5                ; Bytes left to copy from a stored block

; Table builder registers (.DeflateBuild)
!BuildTable     = R8                ; Lookup table
!BuildLens      = R9                ; Code lengths
!BuildCount     = R10               ; Number of symbols
!BuildBits      = R11               ; Bits of the lookup table index (9 or 7)
!BuildTree      = R15               ; Tree (lookup table + $600)
!BuildLen       = R5                ; Length of the current code
!BuildPtr       = R6                ; Current code length
!BuildLast      = R10               ; Address of the last code length
!BuildSum       = R14               ; Number of codes counted so far
!BuildHuff      = R7                ; Current code, bits reversed
!BuildTabLast   = R6                ; Last address of the lookup table
!BuildStep      = R9                ; Step between the entries a code fills, minus 1
!BuildEnd       = R10               ; Address of the last tree entry
!BuildIncr      = R14               ; Bit to add to the reversed code

;===============================================================================
; Page 02
;===============================================================================

.Deflate    LD A, #$00              ; \
            ST !BitBuf, A           ;  | Empty bit buffer
            ST !BitCnt, A           ; /
            ST RAMB, A              ; Bits 16-23 of RAMB stay 0 from here on

;-------------------------------------------------------------------------------
; Read the block header
;-------------------------------------------------------------------------------
..Block     LD P, #Cx4SMW_DeflateDecode>>9 ; P = page 03 for the JSR P: of page 02
            LD A, #$03              ; \
            JSR P:!GetBits          ;  | BFINAL (bit 0) and BTYPE (bits 1-2)
            ST !Header, A           ; /
            SHR A, #$01             ; A = BTYPE
            BEQ ..Stored            ; 0: stored
            CMP A, #$02             ; \ 2: dynamic Huffman codes
            BEQ ..Dynamic           ; /
            SKIPCC                  ; \ 3: reserved, so the stream is broken
            STOP                    ; / 1: fixed Huffman codes, fall through

;-------------------------------------------------------------------------------
; 1: Fixed Huffman codes (RFC 1951, 3.2.6). Their code lengths come from 5
; runs: count | (length - 4) per byte
;-------------------------------------------------------------------------------
..Fixed     %LDA(!DeflateLens)      ; \
            ST !RunAddr, A          ;  |
            LD A, #!DeflateFixedRuns ; |
-           ST DPR, A               ;  |
            RDRAM 0, #$00           ;  |
            LD A, RAMB              ;  | Code length
            AND A, #$07             ;  |
            ADD A, #$04             ;  |
            ST !RunValue, A         ;  |
            LD A, RAMB              ;  | Count
            AND A, #$F8             ;  |
            JSR ..Run               ;  |
            LD A, DPR               ;  |
            ADD A, #$01             ;  |
            CMPR #!DeflateFixedRuns+4, A
            BCS -                   ; /
            %LDA((!DeflateLens+288)) ; \ 288 literal/length codes, then 32
            ST !DistLens, A         ;  | distance codes
            LD A, #32               ;  |
            ST !HDist, A            ;  |
            BRA ..Build             ; /

;-------------------------------------------------------------------------------
; Write A times !RunValue at !RunAddr in data RAM, then move !RunAddr past
; them. A has to be at least 1.
; Out: A = !RunAddr. Modifies !RunLast and RAMB.
;-------------------------------------------------------------------------------
..Run       ADD A, !RunAddr         ; \
            SUB A, #$01             ;  | Last address to write
            ST !RunLast, A          ; /
            LD A, !RunValue         ; \
            ST RAMB, A              ;  |
            LD A, !RunAddr          ;  | Write the bytes
-           WRRAM A, 0              ;  |
            ADD A, #$01             ;  |
            CMPR !RunLast, A        ;  |
            BCS -                   ; /
            ST !RunAddr, A
            RTS

;-------------------------------------------------------------------------------
; 2: Dynamic Huffman codes. Read the code lengths (RFC 1951, 3.2.7)
;-------------------------------------------------------------------------------
..Dynamic   LD A, #$05              ; \
            JSR P:!GetBits          ;  | HLIT: 257-286 literal/length codes.
            ST !DistLens, A         ;  | Their lengths start at !DeflateLens,
            %LDA((!DeflateLens+257)) ; | the distance code lengths right after
            ADD A, !DistLens        ;  |
            ST !DistLens, A         ; /
            LD A, #$05              ; \
            JSR P:!GetBits          ;  | HDIST: 1-32 distance codes
            ADD A, #$01             ;  |
            ST !HDist, A            ; /
            LD A, #$04              ; \
            JSR P:!GetBits          ;  | HCLEN: 4-19 code length codes
            ADD A, #$03             ;  |
            ST !ClenLast, A         ; /

            LD A, #!DeflateClenLens ; \
            ST !RunAddr, A          ;  | Code length codes that HCLEN leaves
            LD A, #$00              ;  | out have length 0
            ST !RunValue, A         ;  |
            LD A, #19               ;  |
            JSR ..Run               ; /

            LD A, #$00              ; \
            ST DPR, A               ;  | Read the code length code lengths, 3
-           RDRAM 0, #!DeflateClenOrder ; | bits each. ClenOrder has where each
            LD A, RAMB              ;  | one goes. (Bits 8-15 of RAMB are 0:
            ST !ClenAddr, A         ;  | it last held a 3-bit value)
            LD A, #$03              ;  |
            JSR P:!GetBits          ;  |
            ST RAMB, A              ;  |
            LD A, !ClenAddr         ;  |
            WRRAM A, 0              ;  |
            LD A, DPR               ;  |
            ADD A, #$01             ;  |
            ST DPR, A               ;  |
            CMPR !ClenLast, A       ;  |
            BCS -                   ; /

            LD A, #!DeflateClenLens ; \
            ST !BuildLens, A        ;  | Build the code length code. It goes in
            LD A, #19               ;  | the distance tables, so !DecodeDist
            ST !BuildCount, A       ;  | decodes it. Its codes are 7 bits at
            JSR Cx4SMW_DeflateBuildDist ; most: the slow path is never needed

            LD A, !DistLens         ; \
            ADD A, !HDist           ;  | Address of the last code length
            SUB A, #$01             ;  |
            ST !LensLast, A         ; /
            %LDA(!DeflateLens)      ; \ The literal/length code lengths, then
            ST !RunAddr, A          ; / the distance code lengths right after

..Lengths   JSR P:!DecodeDist       ; A = next code length code (0-18)
            CMP A, #$10             ; \ 16-18: repeat
            BCS ..Repeat            ; /
            ST !RunValue, A         ; 0-15: one code length. Also the previous
            LD A, #$01              ; length for code 16
..RepeatRun JSR ..Run
            CMPR !LensLast, A       ; \ A = !RunAddr. More to read?
            BCS ..Lengths           ; /
            BRA ..Build

..Repeat    BEQ ..Repeat16          ; Z is still from the CMP
            CMP A, #$11             ; \
            LD A, #$00              ;  | 17 and 18 repeat a length of 0
            ST !RunValue, A         ;  | (LD and ST don't change the flags)
            BEQ ..Repeat17          ; /
            LD A, #$07              ; \
            JSR P:!GetBits          ;  | 18: 11-138 times
            ADD A, #11              ;  |
            BRA ..RepeatRun         ; /
..Repeat17  LD A, #$03              ; \ 17: 3-10 times
            BRA +                   ; /
..Repeat16  LD A, #$02              ; 16: the previous length 3-6 times
+           JSR P:!GetBits
            ADD A, #$03
            BRA ..RepeatRun

;-------------------------------------------------------------------------------
; Build the distance and literal/length tables, then decode the block's data
;-------------------------------------------------------------------------------
..Build     LD A, !DistLens         ; \
            ST !BuildLens, A        ;  | Distance codes
            LD A, !HDist            ;  |
            ST !BuildCount, A       ;  |
            JSR Cx4SMW_DeflateBuildDist ; /
            %LDA(!DeflateLens)      ; \
            ST !BuildLens, A        ;  | Literal/length codes
            SUBR !DistLens, A       ;  |
            ST !BuildCount, A       ;  | (HLIT)
            LD A, #!DeflateLitFast  ;  |
            ST !BuildTable, A       ;  |
            LD A, #$09              ;  |
            JSR Cx4SMW_DeflateBuild ; /
            %BRL(Cx4SMW_DeflateDecode)

;-------------------------------------------------------------------------------
; 0: Stored. Skip to the next byte boundary, read LEN and NLEN, then copy LEN
; bytes. Stored blocks are rare, so this goes through the bit buffer
;-------------------------------------------------------------------------------
..Stored    LD A, !BitCnt           ; \
            AND A, #$07             ;  | Skip to the byte boundary
            JSR P:!GetBits          ; /
            LD A, #$10              ; \
            JSR P:!GetBits          ;  | LEN
            ST !StoredLeft, A       ; /
            LD A, #$10              ; \ NLEN, the ones' complement of LEN.
            JSR P:!GetBits          ; / Not checked
-           LD A, !StoredLeft       ; \
            SUB A, #$01             ;  | Copy LEN bytes
            BMI ..BlockDone         ;  |
            ST !StoredLeft, A       ;  |
            LD A, #$08              ;  |
            JSR P:!GetBits          ;  |
            WAIT                    ;  |
            ST MDR, A               ;  |
            LD A, !Destination      ;  |
            ST MAR, A               ;  |
            ST RDRAM, MDR           ;  |
            ADD A, #$01             ;  |
            ST !Destination, A      ;  |
            BRA -                   ; /

;-------------------------------------------------------------------------------
; The end of a block. Page 03 comes back here. Is there another one?
;-------------------------------------------------------------------------------
..BlockDone LD A, !Header           ; \
            AND A, #$01             ;  | Yes, unless BFINAL was set
            BEQ ..Block             ; /

            WAIT                    ; Let the last write finish
            LD A, !BitCnt           ; \
            SHR A, #$03             ;  | Give back the whole bytes that are
            SUBR !SourceAddr, A     ;  | still in the bit buffer
            ST !SourceAddr, A       ; /
            AND A, #$008000         ; \
            SKIPZS                  ;  | If that went back from $xx:8000,
            STOP                    ;  | continue at $(xx-1):FFFF
            LD A, !SourceAddr       ;  |
            SUB A, #$008000         ;  |
            ST !SourceAddr, A       ;  |
            STOP                    ; /

;===============================================================================
; Build a lookup table and its tree from code lengths
;
; In:  A    Bits of the lookup table index: 9 for literal/length codes, 7 for
;           distance and code length codes
;      R8   Lookup table, as a data RAM address for ADD A << 1. The tree is
;           $600 bytes after it
;      R9   Data RAM address of the code lengths, 1 byte per symbol
;      R10  Number of symbols (1-288)
; Modifies R5-R11, R14, R15, RAMB and DPR. Keeps R12 and R13.
;
; .DeflateBuildDist is for the distance table: it sets A and R8.
;
; Codes are assigned like RFC 1951, 3.2.2 says, in the order of the tree. The
; lookup table is indexed by the bits in the order they come in the stream,
; so it uses each code with its bits reversed. The next code of the same
; length comes from adding 1 to the code's top bit and carrying downwards,
; like zlib does.
;
; With an index of n bits, a code of L bits fills the 2^(n-L) entries whose
; low L bits are the reversed code. Then the codes longer than n bits come,
; in the entries that are left. Together they write every entry, so the table
; doesn't have to be cleared first.
;===============================================================================

.DeflateBuildDist
            LD A, #!DeflateDistFast ; (IR2)
            ST !BuildTable, A
            LD A, #$07

.DeflateBuild
            ST !BuildBits, A
            LD A, #$06              ; \
            ADD A << 8, !BuildTable ;  | Tree = table + $600
            ST !BuildTree, A        ; /
            ST !RunAddr, A          ; \
            LD A, #$00              ;  | T[0-15] = 0
            ST !RunValue, A         ;  |
            LD A, #32               ;  |
            JSR Cx4SMW_Deflate_Run  ; /

            LD A, !BuildCount       ; \
            ADD A, !BuildLens       ;  | Address of the last code length
            SUB A, #$01             ;  |
            ST !BuildLast, A        ; /

;-------------------------------------------------------------------------------
; Count the codes of each length into T[]
;-------------------------------------------------------------------------------
            LD A, !BuildLens
-           ST !BuildPtr, A         ; \
            RDRAM 0, A              ;  | Code length (0: the symbol isn't used)
            LD A, RAMB              ;  |
            AND A, #$0F             ;  |
            BEQ +                   ; /
            JSR P:Cx4SMW_DeflateCount ; T[length]++ (P = page 03)
+           LD A, !BuildPtr         ; \
            ADD A, #$01             ;  | Next symbol
            CMPR !BuildLast, A      ;  |
            BCS -                   ; /

;-------------------------------------------------------------------------------
; T[L] = number of codes shorter than L
;-------------------------------------------------------------------------------
            LD A, !BuildTree        ; \
            ADD A, #$02             ;  | From T[1]
            ST DPR, A               ;  |
            LD A, #$00              ;  |
            ST !BuildSum, A         ;  |
-           RDRAM 0, #$00           ;  |
            RDRAM 1, #$01           ;  |
            LD A, RAMB              ;  | A = count, !BuildSum = codes so far
            SWAP A, !BuildSum       ;  |
            ST RAMB, A              ;  | T[L] = codes so far
            ADD A, !BuildSum        ;  |
            ST !BuildSum, A         ;  |
            WRRAM #$00, 0           ;  |
            WRRAM #$01, 1           ;  |
            LD A, DPR               ;  |
            ADD A, #$02             ;  |
            ST DPR, A               ;  | Until T[15]. ..Run left !RunLast
            CMPR !RunLast, A        ;  | at its 2nd byte
            BCS -                   ; /

;-------------------------------------------------------------------------------
; Sort the symbols by code into the tree. T[L] counts up, so afterwards it is
; the index where the codes longer than L start
;-------------------------------------------------------------------------------
            LD A, !BuildLens
-           ST !BuildPtr, A         ; \
            RDRAM 0, A              ;  | Code length
            LD A, RAMB              ;  |
            AND A, #$0F             ;  |
            BEQ +                   ; /
            ST !BuildLen, A         ; \ RAMB = T[length]++ + 1, which is the
            JSR P:Cx4SMW_DeflateCount ; / symbol's index + 1
            LD A, RAMB              ; \
            ADD A << 1, !BuildTree  ;  | DPR = tree + $20 + 2 * index
            ADD A, #$1E             ;  |
            ST DPR, A               ; /
            LD A, !BuildPtr         ; \
            SUB A, !BuildLens       ;  | Entry: symbol << 4 | length
            SHL A, #$04             ;  |
            OR A, !BuildLen         ;  |
            ST RAMB, A              ;  |
            WRRAM #$00, 0           ;  |
            WRRAM #$01, 1           ; /
+           LD A, !BuildPtr         ; \
            ADD A, #$01             ;  | Next symbol
            CMPR !BuildLast, A      ;  |
            BCS -                   ; /

            LD A, !BuildSum         ; \
            ADD A << 1, !BuildTree  ;  | Address of the last entry
            ADD A, #$1E             ;  |
            ST !BuildEnd, A         ; /
            LD A, #$02              ; \
            SHL A, !BuildBits       ;  | Last address of the lookup table
            ADD A, !BuildTable      ;  |
            SUB A, #$01             ;  |
            ST !BuildTabLast, A     ; /
            %BRL(Cx4SMW_DeflateFill) ; Continue in page 03

            assert pc() <= $600, "Cx4 page 02 (DEFLATE) is ", dec(pc()-$600), " bytes over its 512"
            print "- Cx4 page 02: ", dec($600-pc()), " out of 512 bytes left"
            fillbyte $FF
            fill align $200

;===============================================================================
; Page 03: decode the data of a block
;
; Comes from page 02 with the lookup tables ready, and goes back to
; Cx4SMW_Deflate_BlockDone at the end of the block.
;===============================================================================

            assert pc() == $600, "Cx4 page 03 (DEFLATE) has to start at $600"

!LenMinus1      = R7                ; Length of the copy - 1
!CopyLast       = R6                ; Address of the copy's last output byte
!Distance       = R9                ; Distance of the copy
!ExtraBits      = R8                ; Used by ..BaseExtra
!GetBitsValue   = R10
!GetBitsCount   = R11               ; n of the last GetBits call
!CodeLen        = R11               ; Length of the code just looked up. The same
                                    ; register, as the distance decoder removes
                                    ; the code's bits with GetBits
!Mask9          = R12               ; $0001FF
!SlowCode       = R5                ; See ..Slow
!SlowTree       = R13

.DeflateDecode
            %LDA($0001FF)
            ST !Mask9, A

;-------------------------------------------------------------------------------
; Decode a literal/length code
;-------------------------------------------------------------------------------
..Loop      LD A, !BitCnt           ; \
            CMPR #$0F, A            ;  | Make sure there are 16 bits
            JCS ..Refill            ; /
            LD A, !BitBuf           ; \
            AND A, !Mask9           ;  | Look the next 9 bits up
            ADD A << 1, #!DeflateLitFast ; | (the table is at $000100, IR14)
            RDRAM 0, A              ;  |
            ADD A, #$01             ;  |
            RDRAM 1, A              ; /
            LD A, RAMB              ; \
            AND A, #$0F             ;  | Remove the code's bits
            ST !CodeLen, A          ;  |
            LD A, !BitBuf           ;  |
            SHR A, !CodeLen         ;  |
            ST !BitBuf, A           ;  |
            LD A, !BitCnt           ;  |
            SUB A, !CodeLen         ;  |
            ST !BitCnt, A           ; /
            LD A, RAMB              ; \ A = symbol
            SHR A, #$04             ; /
..LitSym    CMP A, #$000100         ; \ 256 and up: end of block, a copy, or a
            BCS ..NotLiteral        ; / longer code

            WAIT                    ; \
            ST MDR, A               ;  | 0-255: a literal. Write it
            LD A, !Destination      ;  |
            ST MAR, A               ;  |
            ST RDRAM, MDR           ;  |
            ADD A, #$01             ;  |
            ST !Destination, A      ;  |
            BRA ..Loop              ; /

;-------------------------------------------------------------------------------
; 256: end of block. 257-285: a copy. Its length, then its distance.
;
; ..BaseExtra adds the extra bits to the base value from CodeTab, which has
; the base minus 2 for lengths and minus 1 for distances. That way the codes
; without extra bits share the ADD after the JCS.
;-------------------------------------------------------------------------------
..NotLiteral
            LD P, #Cx4SMW_Deflate>>9 ; \ 256: back to page 02
            BEQ P:Cx4SMW_Deflate_BlockDone ; /
            SUB A, #$000100         ; \ $120 and up: longer than 9 bits
            CMP A, #$1E             ;  |
            BCS ..LitSlow           ; /
            CMP A, #$09             ; \ Length code - 256 (1-29). 257-264 have
            JCS ..BaseExtraLen      ;  | no extra bits: length 3-10
            ADD A, #$01             ;  |
            ST !LenMinus1, A        ; /
            JSR ..DecodeDist        ; \ Distance codes 0-3 have no extra bits:
            CMP A, #$04             ;  | distance 1-4
            JCS ..BaseExtra         ;  |
            ADD A, #$01             ;  |
            ST !Distance, A         ; /

;-------------------------------------------------------------------------------
; Copy the bytes from !Distance bytes back. They can overlap the bytes being
; written, so go one byte at a time
;-------------------------------------------------------------------------------
            LD A, !Destination      ; \
            ADD A, !LenMinus1       ;  | Last byte to write
            ST !CopyLast, A         ; /
            LD A, !Destination
-           SUB A, !Distance        ; \
            WAIT                    ;  | Start reading the byte
            ST MAR, A               ;  |
            LD MDR, RDRAM           ; /
            LD A, !Destination      ; \ While it's being read: where it goes
            ST MAR, A               ;  | (a bus access keeps the address it
            ADD A, #$01             ;  | started with)
            ST !Destination, A      ; /
            WAIT                    ; \ Write it
            ST RDRAM, MDR           ; /
            CMPR !CopyLast, A       ; \ Loop if not done yet
            BCS -                   ; /
            BRA ..Loop

..LitSlow   SUB A, #$20             ; \
            ST !SlowCode, A         ;  | Literal/length codes longer than 9 bits
            %LDA(!DeflateLitTree)   ;  |
            JSR ..Slow              ;  |
            BRA ..LitSym            ; /

;-------------------------------------------------------------------------------
; Base value from CodeTab + extra bits
; In:  A = code index: distance code 0-29, or length code - 256 for
;      ..BaseExtraLen (they follow the distance codes)
; Out: A = base + extra bits. Modifies !ExtraBits, DPR and RAMB.
;-------------------------------------------------------------------------------
..BaseExtraLen
            ADD A, #29
..BaseExtra ST !ExtraBits, A        ; \
            ADD A << 1, !ExtraBits  ;  | DPR = 3 * index
            ST DPR, A               ; /
            RDRAM 1, #!DeflateCodeTab+2 ; \ Number of extra bits, through bits
            LD A, RAMB              ;  | 8-15 of RAMB (bits 16-23 are 0)
            SHR A, #$08             ;  |
            JSR ..GetBits           ; /  GetBits leaves RAMB and DPR alone
            RDRAM 0, #!DeflateCodeTab ; \
            RDRAM 1, #!DeflateCodeTab+1 ; | Add the base
            ADD A, RAMB             ;  |
            RTS                     ; /

;-------------------------------------------------------------------------------
; Decode a distance code (or, from page 02, a code length code)
; Out: A = symbol. Modifies RAMB and GetBits' registers. Codes longer than 7
; bits go through the slow path, which also modifies its registers.
;-------------------------------------------------------------------------------
..DecodeDist
            LD A, !BitCnt           ; \
            CMPR #$0F, A            ;  | Make sure there are 16 bits
            JCS ..Refill            ; /
            LD A, !BitBuf           ; \
            AND A, #$7F             ;  | Look the next 7 bits up
            ADD A << 1, #!DeflateDistFast ; | (the table is at $B00, see top)
            RDRAM 0, A              ;  |
            ADD A, #$01             ;  |
            RDRAM 1, A              ; /
            LD A, RAMB              ; \
            AND A, #$0F             ;  | Remove the code's bits. GetBits leaves
            JSR ..GetBits           ; /  RAMB alone and !CodeLen = their number
            LD A, RAMB              ; \ A = symbol
            SHR A, #$04             ;  |
            CMP A, #$1E             ;  | $120 and up: longer than 7 bits
            BCS ..DistSlow          ;  |
            RTS                     ; /

..DistSlow  SUB A, #$000100         ; \
            SUB A, #$20             ;  | ..Slow returns to our caller
            ST !SlowCode, A         ;  |
            %LDA(!DeflateDistTree)  ; /

;-------------------------------------------------------------------------------
; Slow path: codes longer than the lookup table's index. The table removed
; its bits already (!CodeLen of them).
; In:  A = tree, !SlowCode = what the table had minus $120
; Out: A = symbol. Modifies !SlowCode, !SlowTree, DPR, RAMB and GetBits'
;      registers.
;
; Like puff.c, with c = the code read so far as a number (first bit on top):
; after L bits, c minus the first code of length L is compared with the number
; of codes of length L. The tree has the codes sorted, so the code would be
; at index T[L-1] + that difference. !SlowCode keeps that index instead, which
; saves a register: it is a code of length L if it's below T[L], and the next
; one is 2 * index - T[L] + the next bit.
; The lookup table's entry has 2 * index - T[n] for after its n bits already.
;-------------------------------------------------------------------------------
..Slow      ST !SlowTree, A
            LD A, !CodeLen          ; \
            ADD A << 1, !SlowTree   ;  | DPR = &T[bits so far]
            ST DPR, A               ; /
-           LD A, #$01              ; \
            JSR ..GetBits           ;  | Index += next bit
            ADD A, !SlowCode        ;  |
            ST !SlowCode, A         ; /
            LD A, DPR               ; \
            ADD A, #$02             ;  | RAMB = T[L]
            ST DPR, A               ;  |
            RDRAM 0, #$00           ;  |
            RDRAM 1, #$01           ; /
            LD A, !SlowCode         ; \ Below T[L]: found
            CMP A, RAMB             ;  |
            %BCC(+)                 ; /
            ADD A, !SlowCode        ; \
            SUB A, RAMB             ;  | Index = 2 * index - T[L]
            ST !SlowCode, A         ;  |
            BRA -                   ; /
+           ADD A << 1, !SlowTree   ; \
            ST DPR, A               ;  | The entry at that index
            RDRAM 0, #$20           ;  |
            RDRAM 1, #$21           ; /
            LD A, RAMB              ; \ A = symbol
            SHR A, #$04             ;  |
            RTS                     ; /

;-------------------------------------------------------------------------------
; Read n bits
; In:  A = n (0-16)
; Out: A = the bits, the first one in bit 0. !GetBitsCount = n. Modifies
;      !GetBitsValue.
;-------------------------------------------------------------------------------
..GetBits   ST !GetBitsCount, A
            LD A, !BitCnt           ; \
            CMPR #$0F, A            ;  | Make sure there are 16 bits
            JCS ..Refill            ; /  (Refill returns A = !BitCnt too)
            SUB A, !GetBitsCount    ; \
            ST !BitCnt, A           ; /
            LD A, !BitBuf           ; \
            SHR A, !GetBitsCount    ;  | Remove the bits from the bit buffer
            SWAP A, !BitBuf         ;  |
            ST !GetBitsValue, A     ; /
            LD A, !BitBuf           ; \
            SHL A, !GetBitsCount    ;  | Return them: the old buffer minus the
            SUBR !GetBitsValue, A   ;  | new one shifted back
            RTS                     ; /

;-------------------------------------------------------------------------------
; Read bytes into the bit buffer until it has 16 bits or more. Call this when
; it has 15 or less. It ends with 23 at most, so the buffer fits in 24 bits.
; Out: A = !BitCnt. Changes MAR and MDR too.
;-------------------------------------------------------------------------------
..Refill    WAIT                    ; Let a pending SRAM write finish first
            LD A, !SourceAddr       ; \
            ST MAR, A               ;  |
            LD MDR, RDROM           ;  | Read the next byte
            ADD A, #$01             ;  |
            OR A, #$008000          ;  | $xx:FFFF + 1 = $(xx+1):0000 -> $(xx+1):8000
            ST !SourceAddr, A       ;  |
            WAIT                    ; /
            LD A, MDR               ; \
            SHL A, !BitCnt          ;  | Put it above the bits already there
            OR A, !BitBuf           ;  |
            ST !BitBuf, A           ; /
            LD A, !BitCnt           ; \
            ADD A, #$08             ;  |
            ST !BitCnt, A           ;  | Again if there are still less than 16
            CMPR #$0F, A            ;  | (one call level deeper, which also
            JCS ..Refill            ;  | returns A = !BitCnt)
            RTS                     ; /

;===============================================================================
; End of the table builder (.DeflateBuild in page 02): write the lookup table,
; going through the tree entries in code order. Returns to the builder's
; caller.
;===============================================================================

.DeflateFill
            LD A, #$00              ; \ The first code is 0
            ST !BuildHuff, A        ; /
            LD A, !BuildTree        ; \ First entry
            ADD A, #$20             ;  |
            ST DPR, A               ; /

..Entry     LD A, DPR               ; \
            CMPR !BuildEnd, A       ;  | No entries left: the code is
            %BCC(..Long)            ; /  incomplete, fill the rest like ..Long
            RDRAM 0, #$00           ; \
            RDRAM 1, #$01           ;  | RAMB = entry
            ADD A, #$02             ;  |
            ST DPR, A               ; /
            LD A, RAMB              ; \
            AND A, #$0F             ;  | Code length
            ST !BuildLen, A         ; /
            CMPR !BuildBits, A      ; \ Longer than the index: the rest are too
            %BCC(..Long)            ; /

            LD A, #$02              ; \
            SHL A, !BuildLen        ;  | Fill every 2^L-th entry, starting at
            SUB A, #$01             ;  | the reversed code
            ST !BuildStep, A        ;  |
            LD A, !BuildHuff        ;  |
            ADD A << 1, !BuildTable ;  |
-           WRRAM A, 0              ;  |
            ADD A, #$01             ;  |
            WRRAM A, 1              ;  |
            ADD A, !BuildStep       ;  |
            CMPR !BuildTabLast, A   ;  |
            BCS -                   ; /
            JSR ..NextCode          ; \ Next code. Back to 0: the table is full
            %BNE(..Entry)           ; /
            RTS

;-------------------------------------------------------------------------------
; The codes longer than the index (of n bits). The entries that are left go
; to their first n bits, one each, in code order. Each holds where the slow
; path continues (see ..Slow): T[n] for the first one, then 2 more for each
; next one, + $120 to tell them from symbols. Their code length is n, so the
; decoder removes those n bits before it goes to the slow path.
;-------------------------------------------------------------------------------
..Long      LD A, !BuildBits        ; \
            ST !BuildLen, A         ;  | From now on, codes of the index's
            ADD A << 1, !BuildTree  ;  | length
            ST DPR, A               ;  |
            RDRAM 0, #$00           ;  | RAMB = T[n]
            RDRAM 1, #$01           ; /
            LD A, RAMB              ; \
            ADD A, #$000100         ;  | Entry: ($120 + T[n]) << 4 | n
            ADD A, #$20             ;  |
            SHL A, #$04             ;  |
            OR A, !BuildBits        ;  |
            ST RAMB, A              ; /
-           LD A, !BuildHuff        ; \
            ADD A << 1, !BuildTable ;  | Write it
            WRRAM A, 0              ;  |
            ADD A, #$01             ;  |
            WRRAM A, 1              ; /
            LD A, RAMB              ; \
            ADD A, #$20             ;  | Next pattern: + 2
            ST RAMB, A              ; /
            JSR ..NextCode          ; \ Until the table is full
            %BNE(-)                 ; /
            RTS

;-------------------------------------------------------------------------------
; Add 1 to the reversed code of !BuildLen bits: start at its top bit, clear
; the set bits going down, then set the first clear one.
; Out: !BuildHuff, Z set if it went back to 0.
;-------------------------------------------------------------------------------
..NextCode  LD A, #$01              ; \
            SHL A, !BuildLen        ;  | Top bit
            SHR A, #$01             ;  |
            ST !BuildIncr, A        ; /
            LD A, !BuildHuff
-           ST !BuildHuff, A        ; \
            AND A, !BuildIncr       ;  | Clear the set bits
            BEQ +                   ;  |
            LD A, !BuildIncr        ;  |
            SHR A, #$01             ;  |
            SWAP A, !BuildIncr      ;  |
            XOR A, !BuildHuff       ;  |
            BRA -                   ; /
+           LD A, !BuildHuff        ; \ Set the clear one
            OR A, !BuildIncr        ;  |
            ST !BuildHuff, A        ; /
            RTS

;-------------------------------------------------------------------------------
; T[A]++ for the table builder in page 02, which calls it with JSR P:
; Out: RAMB = the new T[A]. Modifies DPR.
;-------------------------------------------------------------------------------
.DeflateCount
            ADD A << 1, !BuildTree
            ST DPR, A
            RDRAM 0, #$00
            RDRAM 1, #$01
            LD A, RAMB
            ADD A, #$01
            ST RAMB, A
            WRRAM #$00, 0
            WRRAM #$01, 1
            RTS

undef "SourceAddr"
undef "Destination"
undef "BitBuf"
undef "BitCnt"
undef "Header"
undef "DeflateTables"
undef "DeflateCodeTab"
undef "DeflateClenOrder"
undef "DeflateFixedRuns"
undef "DeflateClenLens"
undef "DeflateLitFast"
undef "DeflateDistTree"
undef "DeflateLens"
undef "DeflateLitTree"
undef "DeflateDistFast"
undef "GetBits"
undef "DecodeDist"
undef "RunAddr"
undef "RunValue"
undef "RunLast"
undef "ClenAddr"
undef "DistLens"
undef "HDist"
undef "ClenLast"
undef "LensLast"
undef "StoredLeft"
undef "BuildTable"
undef "BuildLens"
undef "BuildCount"
undef "BuildBits"
undef "BuildTree"
undef "BuildLen"
undef "BuildPtr"
undef "BuildLast"
undef "BuildSum"
undef "BuildHuff"
undef "BuildTabLast"
undef "BuildStep"
undef "BuildEnd"
undef "BuildIncr"
undef "LenMinus1"
undef "CopyLast"
undef "Distance"
undef "ExtraBits"
undef "GetBitsValue"
undef "GetBitsCount"
undef "Mask9"
undef "CodeLen"
undef "SlowCode"
undef "SlowTree"
