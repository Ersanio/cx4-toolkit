;===============================================================================
; DEFLATE decompression (RFC 1951)
;
; In:  R0   Address of the compressed data in ROM, 24-bit. LoROM, banks $00-$3F
;           or $80-$BF, $8000-$FFFF. The data may cross banks.
;           It is a raw DEFLATE stream, without a zlib or gzip header.
;      R1   Where to write the output, in SRAM ($70:0000-$70:7FFF)
; Out: R0   Address right after the end of the compressed data
;      R1   Address right after the end of the decompressed data
;
; Modifies R2-R15, ROMB, RAMB, DPR, MAR, MDR and Cx4 RAM $000-$53B.
;
; Handles stored, fixed and dynamic blocks. It doesn't check for invalid data.
;
; Optimized for size: all of DEFLATE has to fit in this one page. The bits are
; read one at a time, and building a Huffman tree takes 15 passes over the
; code lengths.
;
; The tables are in ROM at DEFLATE ["deflate_cx4_call (compact).asm"], in rows of 4 bytes:
;   base (16-bit, high byte first), number of extra bits, unused.
; ..ReadExtra reads a row and returns base + extra bits. Every read of more
; than one bit goes through it, so a row with base 0 just reads bits.
;
; A Huffman tree in Cx4 RAM is made of 16-bit words. For each code length from
; 1 to 15 it has a link word, followed by the symbols with that code length in
; ascending order. The link holds the address of the next code length's link.
;===============================================================================

; The Cx4 RAM addresses (!Deflate2DistTree, !Deflate2LitTree, !Deflate2Lengths)
; are defined in ["deflate_cx4_call (compact).asm"], next to the tables that use them.

; Rows of the table at DEFLATE
!RowLength     = (DEFLATE_Length-DEFLATE)/4
!RowHLIT       = (DEFLATE_HLIT-DEFLATE)/4
!RowHDIST      = (DEFLATE_HDIST-DEFLATE)/4
!RowHCLEN      = (DEFLATE_HCLEN-DEFLATE)/4
!Row3Bits      = (DEFLATE_Bits3-DEFLATE)/4
!Row8Bits      = (DEFLATE_Bits8-DEFLATE)/4
!Row16Bits     = (DEFLATE_Bits16-DEFLATE)/4
!RowCodeLength = (DEFLATE_CodeLength-DEFLATE)/4
!RowOrder      = (DEFLATE_Order-DEFLATE)/4

; Used during the whole routine
!SourceAddr    = R0                 ; Current offset of compressed data
!Destination   = R1                 ; Current offset of decompressed data output
!BitBuffer     = R2                 ; Unread bits of the current byte, below a marker bit
!Table         = R3                 ; Address of the table at DEFLATE
!BlockHeader   = R4                 ; Bit 0 = last block, bits 1-2 = block type
; ..ReadExtra
!ExtraBits     = R5                 ; Number of extra bits of the row
!Value         = R6                 ; Base of the row + the extra bits read so far
!BitPosition   = R7                 ; Number of extra bits read so far
; ..Decode
!Link          = R8                 ; Address of the current code length's link
!Code          = R9                 ; Ends up as the address of the decoded symbol
; ..Inflate
!CopyEnd       = R10                ; Offset right after the last output byte of the copy
!Distance      = R11                ; How far back to copy from
; ..ReadTrees
!OrderEnd      = R8                 ; Last row of DEFLATE_Order that has a length in the data
!OrderRow      = R9                 ; Current row of DEFLATE_Order
!Symbol        = R8                 ; Decoded code length symbol (0-18)
!RunEnd        = R9                 ; Address right after the last code length of the run
!LengthsEnd    = R10                ; Address right after the last code length
!PrevLength    = R11                ; The code length to write
!LitCount      = R12                ; Number of literal/length code lengths (HLIT)
!DistCount     = R13                ; Number of distance code lengths (HDIST)
!Lengths       = R14                ; Address of the code lengths for ..BuildTree
; ..BuildTree
!SymbolCount   = R5                 ; Number of code lengths
!CodeLength    = R6                 ; Code length of the current pass (1-15)
!Index         = R7                 ; Current symbol
!LinkAddr      = R8                 ; Address of the current pass' link
; ..Fixed
!SavedSource   = R15                ; !SourceAddr while reading DEFLATE_FixedTrees
                                    ; (!BitBuffer is saved in ROMB)

;-------------------------------------------------------------------------------
; Initialize
;-------------------------------------------------------------------------------
.Deflate2   LD A, #DEFLATE>>16              ; \
            OR A << 8, #(DEFLATE>>8)&$FF    ;  | !Table = DEFLATE
            OR A << 8, #DEFLATE&$FF         ;  |
            ST !Table, A                    ; /
            LD A, #$01              ; \ Only the marker bit: the first bit
            ST !BitBuffer, A        ; / will read a byte

;-------------------------------------------------------------------------------
; Read the block header: 1 bit for the last block, 2 bits for the block type
;-------------------------------------------------------------------------------
..Block     JSR ..Read3Bits
            ST !BlockHeader, A
            SHR A, #$01             ; \ Type 0: Stored
            BEQ ..Stored            ; /
            SUB A, #$01             ; \ Type 1: Fixed Huffman codes
            BEQ ..Fixed             ; /
            JSR ..ReadTrees         ; Type 2: Dynamic Huffman codes

;-------------------------------------------------------------------------------
; Decompress the block's data, with the block's trees
;-------------------------------------------------------------------------------
..Inflate   LD A, #!Deflate2LitTree  ; \
            JSR ..Decode            ;  | Symbol 256 is the end of the block,
            SUB A, #$000100         ;  | 257-285 are lengths
            BEQ ..EndBlock          ;  |
            BCS ..Match             ; /
            JSR ..PutByte           ; 0-255: Literal. The -$100 doesn't change the low byte
            BRA ..Inflate

..Match     ADD A, #!RowLength-1    ; \  A = 1-29
            JSR ..ReadExtra         ;  | Get the length of the copy, 3-258
            ADD A, !Destination     ;  |
            ST !CopyEnd, A          ; /
            LD A, #!Deflate2DistTree ; \
            JSR ..Decode            ;  | Get the distance, 1-32768. The distance
            JSR ..ReadExtra         ;  | symbol is the row of the table
            ST !Distance, A         ; /
            LD A, !Destination
..Copy      SUB A, !Distance        ; \
            ST MAR, A               ;  | Read byte from the SRAM
            LD MDR, RDRAM           ;  |
            WAIT                    ; /
            JSR ..PutMDR            ; \
            CMP A, !CopyEnd         ;  | Write the byte to the output
            BEQ ..Inflate           ;  | Loop if not done yet
            BRA ..Copy              ; /

..EndBlock  LD A, !BlockHeader      ; \
            AND A, #$01             ;  | Continue if this wasn't the last block
            BEQ ..Block             ; /
            STOP

;-------------------------------------------------------------------------------
; 0: Stored block. It starts at the next whole byte with a 16-bit length,
; followed by the same length inverted, then the bytes themselves.
;-------------------------------------------------------------------------------
..Stored    LD A, #$01              ; \ Drop the rest of the current byte
            ST !BitBuffer, A        ; /
            LD A, #!Row16Bits       ; \
            JSR ..ReadExtra         ;  | Read the length
            ADD A, !Destination     ;  |
            ST !CopyEnd, A          ; /
            LD A, #!Row16Bits       ; \ Skip the inverted length
            JSR ..ReadExtra         ; /
            LD A, !Destination
-           CMP A, !CopyEnd         ; \ Edge case: The length can be 0
            BEQ ..EndBlock          ; /
            LD A, #!Row8Bits        ; \
            JSR ..ReadExtra         ;  | Copy a byte
            JSR ..PutByte           ;  |
            BRA -                   ; /

;-------------------------------------------------------------------------------
; 1: Fixed Huffman codes. DEFLATE_FixedTrees holds these codes in the same
; format as the trees of a dynamic block, so we read them from there instead.
;-------------------------------------------------------------------------------
..Fixed     LD A, !Table                        ; \
            ADD A, #DEFLATE_FixedTrees-DEFLATE  ;  | Read from DEFLATE_FixedTrees,
            SWAP A, !SourceAddr                 ;  | starting at its first bit
            ST !SavedSource, A                  ;  |
            LD A, #$01                          ;  | Keep our place in the
            SWAP A, !BitBuffer                  ;  | compressed data
            ST ROMB, A                          ; /
            JSR ..ReadTrees
            LD A, !SavedSource      ; \
            ST !SourceAddr, A       ;  | Continue with the compressed data
            LD A, ROMB              ;  |
            ST !BitBuffer, A        ; /
            BRA ..Inflate

;-------------------------------------------------------------------------------
; 2: Dynamic Huffman codes. Read the block's trees.
;
; Out: Literal/length tree at !Deflate2LitTree, distance tree at !Deflate2DistTree
;-------------------------------------------------------------------------------
..ReadTrees LD A, #!RowHLIT         ; \
            JSR ..ReadExtra         ;  | Number of literal/length
            ST !LitCount, A         ; /  code lengths, 257-288
            LD A, #!RowHDIST        ; \
            JSR ..ReadExtra         ;  | Number of distance code lengths, 1-32
            ST !DistCount, A        ; /
            LD A, #!RowHCLEN        ; \  Number of code lengths of the code
            JSR ..ReadExtra         ;  | length tree (4-19), as the last row
            ST !OrderEnd, A         ; /  of DEFLATE_Order that has one

; The code length tree has 19 symbols. Their code lengths are 3 bits each, in
; the order of DEFLATE_Order. The ones that aren't in the data are 0.
            LD A, #!RowOrder
            ST !OrderRow, A
-           LD A, !OrderRow         ; \
            JSR ..ReadExtra         ;  | DPR = where this symbol's length goes
            ST DPR, A               ; /
            LD A, !OrderRow         ; \
            CMPR !OrderEnd, A       ;  | Read the length if it's in the data,
            LD A, #$00              ;  | use 0 otherwise
            JCS ..Read3Bits         ;  |
            JSR ..WriteWord         ; /
            LD A, !OrderRow         ; \
            ADD A, #$01             ;  | Next symbol
            ST !OrderRow, A         ;  |
            CMP A, #!RowOrder+19    ;  |
            %BNE(-)                 ; /

            LD A, #!Deflate2Lengths>>8           ; \
            OR A << 8, #!Deflate2Lengths&$FF     ;  | Build the code length tree
            ST !Lengths, A                      ;  |
            LD A, #19                           ;  | It's a temporary tree, it uses
            ST !SymbolCount, A                  ;  | the space of the distance tree
            LD A, #!Deflate2DistTree             ;  |
            JSR ..BuildTree                     ; /

; Read the code lengths of the literal/length tree and the distance tree. They
; are one list, compressed with the code length tree.
; Symbols 0-15: The code length itself
;           16: Repeat the previous code length 3-6 times
;           17: Repeat 0 for 3-10 times
;           18: Repeat 0 for 11-138 times
; They overwrite the 19 code lengths above, which we don't need anymore.
            LD A, !Lengths
            ST DPR, A
            LD A, !LitCount         ; \
            ADD A, !DistCount       ;  | Address right after the last code length
            ADD A << 1, !Lengths    ;  |
            ST !LengthsEnd, A       ; /

..ReadLength
            LD A, #!Deflate2DistTree ; \ Read a symbol
            JSR ..Decode            ; /
            ST !Symbol, A           ; \
            ADD A, #!RowCodeLength  ;  | Get how many times to write a length.
            JSR ..ReadExtra         ;  | It's 1 for the symbols 0-15
            ADD A << 1, DPR         ;  |
            ST !RunEnd, A           ; /
            LD A, !Symbol           ; \
            CMP A, #16              ;  | 16:    Keep the previous length
            BEQ ..WriteLength       ;  | 0-15:  The length is the symbol
            SKIPCC                  ;  | 17-18: The length is 0
            LD A, #$00              ;  |
            ST !PrevLength, A       ; /
..WriteLength
            LD A, !PrevLength       ; \
            JSR ..WriteWord         ;  | Write the length
            CMP A, !RunEnd          ;  | Loop if not done yet
            %BNE(..WriteLength)     ; /
            CMP A, !LengthsEnd      ; \ Next symbol
            %BNE(..ReadLength)      ; /

            LD A, !LitCount         ; \
            ST !SymbolCount, A      ;  | Build the literal/length tree
            LD A, #!Deflate2LitTree  ;  |
            JSR ..BuildTree         ; /
            LD A, !LitCount         ; \
            ADD A << 1, !Lengths    ;  | Build the distance tree. Its code
            ST !Lengths, A          ;  | lengths come right after those of
            LD A, !DistCount        ;  | the literal/length tree
            ST !SymbolCount, A      ;  |
            LD A, #!Deflate2DistTree ; /
                                    ; Falls through into ..BuildTree

;-------------------------------------------------------------------------------
; Build a Huffman tree from a list of code lengths
;
; In:  A    Address of the tree in Cx4 RAM
;      R14  Address of the code lengths in Cx4 RAM, 16-bit each
;      R5   Number of code lengths
;
; Shorter codes come first, and codes of the same length are in the order of
; their symbols. So we go through the list once for each code length, and
; write down the symbols that have it.
; Modifies R6-R8.
;-------------------------------------------------------------------------------
..BuildTree ST DPR, A
            LD A, #$00
            ST !CodeLength, A
..NextCodeLength
            LD A, !CodeLength       ; \
            ADD A, #$01             ;  | Return after code length 15
            ST !CodeLength, A       ;  |
            CMP A, #16              ;  |
            SKIPZC                  ;  |
            RTS                     ; /
            LD A, DPR               ; \
            ST !LinkAddr, A         ;  | Leave room for this code length's link
            JSR ..WriteWord         ; /
            LD A, #$00
            ST !Index, A
-           LD A, !Index            ; \
            ADD A << 1, !Lengths    ;  | Write the symbol if it has
            JSR ..ReadWord          ;  | this code length
            CMP A, !CodeLength      ;  |
            JEQ ..PutIndex          ; /
            LD A, !Index            ; \
            ADD A, #$01             ;  | Next symbol
            ST !Index, A            ;  |
            CMP A, !SymbolCount     ;  |
            %BNE(-)                 ; /
            LD A, DPR               ; \
            ST RAMB, A              ;  | Write this code length's link: The
            LD A, !LinkAddr         ;  | address where the next one starts
            WRRAM A, 0              ;  |
            ADD A, #$01             ;  |
            WRRAM A, 1              ; /
            BRA ..NextCodeLength

;-------------------------------------------------------------------------------
; Read a Huffman code from the compressed data
;
; In:  A    Address of the tree in Cx4 RAM
; Out: A    The symbol
;
; We read the code bit by bit, as its length isn't known. With each bit we
; calculate where the symbol would be, if the code had this length:
;   !Code = (!Code + bit) * 2 - !Link + 2
; If that address is past the symbols of this length, then the code is longer.
;-------------------------------------------------------------------------------
..Decode    ST !Link, A
            ST !Code, A
-           JSR ..GetBit            ; \
            ADD A, !Code            ;  | Address of the symbol, if the code
            SUB A << 1, !Link       ;  | has this length
            ADD A, #$02             ;  |
            ST !Code, A             ; /
            LD A, !Link             ; \
            JSR ..ReadWord          ;  | Get where the symbols of this length end
            ST !Link, A             ; /
            CMPR !Code, A           ; \ Read another bit if we're past that
            BCS -                   ; /
            LD A, !Code             ; Read the symbol
                                    ; Falls through into ..ReadWord

;-------------------------------------------------------------------------------
; Read a 16-bit word from Cx4 RAM
;
; In:  A    Address
; Out: A    The word
;-------------------------------------------------------------------------------
..ReadWord  RDRAM 0, A
            ADD A, #$01
            RDRAM 1, A
            LD A, RAMB
            RTS

;-------------------------------------------------------------------------------
; Write a 16-bit word to Cx4 RAM
;
; In:  A    The word (..PutIndex: !Index instead)
;      DPR  Address
; Out: A    Address + 2
;      DPR  Address + 2
;-------------------------------------------------------------------------------
..PutIndex  LD A, !Index
..WriteWord ST RAMB, A
            WRRAM #$00, 0
            WRRAM #$01, 1
            LD A, DPR
            ADD A, #$02
            ST DPR, A
            RTS

;-------------------------------------------------------------------------------
; Read a row of the table at DEFLATE, then its extra bits from the
; compressed data
;
; In:  A    Row (..Read3Bits: none, it reads 3 bits)
; Out: A    Base of the row + extra bits
;
; DEFLATE stores the bits of a value starting at the lowest one.
;-------------------------------------------------------------------------------
..Read3Bits LD A, #!Row3Bits
..ReadExtra SHL A, #$02             ; \
            ADD A, !Table           ;  | Address of the row
            ST MAR, A               ; /
            LD MDR, RDROM           ; \
            INC MAR                 ;  |
            WAIT                    ;  |
            LD A, MDR               ;  | Read the base, big endian
            LD MDR, RDROM           ;  |
            INC MAR                 ;  |
            WAIT                    ;  |
            OR A << 8, MDR          ;  |
            ST !Value, A            ; /
            LD MDR, RDROM           ; \
            WAIT                    ;  | Read the number of extra bits
            ST !ExtraBits, MDR      ; /
            LD A, #$00
            ST !BitPosition, A
-           LD A, !BitPosition      ; \
            CMP A, !ExtraBits       ;  | Done?
            BEQ +                   ; /
            JSR ..GetBit            ; \
            SHL A, !BitPosition     ;  | Add the next bit to the value
            ADD A, !Value           ;  |
            ST !Value, A            ; /
            LD A, !BitPosition      ; \
            ADD A, #$01             ;  | Next bit
            ST !BitPosition, A      ;  |
            BRA -                   ; /
+           LD A, !Value
            RTS

;-------------------------------------------------------------------------------
; Read a bit from the compressed data
;
; Out: A    The bit
;      Z    Set if the bit is 0
;
; !BitBuffer holds the bits of the current byte that we haven't read yet, with
; a marker bit above them. Once only the marker is left, we read the next byte.
;-------------------------------------------------------------------------------
..GetBit    LD A, !BitBuffer
            SHR A, #$01
            BEQ ..NextByte
-           SWAP A, !BitBuffer      ; \ Remove the bit from the buffer
            AND A, #$01             ; / and return it
            RTS

..NextByte  LD A, !SourceAddr       ; \
            ST MAR, A               ;  | Read the ROM byte
            LD MDR, RDROM           ; /
            ADD A, #$01             ; \  Increase offset of compressed data
            OR A, #$008000          ;  | Bank boundary crossing: $xx:0000
            ST !SourceAddr, A       ; /  becomes $xx:8000
            WAIT                    ; MDR now contains the read byte
            LD A, MDR               ; \
            OR A, #$000100          ;  | Add the marker bit
            ST !BitBuffer, A        ; /
            SHR A, #$01
            BRA -

;-------------------------------------------------------------------------------
; Write a byte to the output
;
; In:  A    The byte (..PutMDR: in MDR instead)
; Out: A    Offset right after the byte
;-------------------------------------------------------------------------------
..PutByte   ST MDR, A
..PutMDR    LD A, !Destination      ; \
            ST MAR, A               ;  | Write the byte to the destination
            ST RDRAM, MDR           ; /
            ADD A, #$01             ; \ Update the destination offset
            ST !Destination, A      ; /
            WAIT
            RTS

undef "RowLength"
undef "RowHLIT"
undef "RowHDIST"
undef "RowHCLEN"
undef "Row3Bits"
undef "Row8Bits"
undef "Row16Bits"
undef "RowCodeLength"
undef "RowOrder"
undef "SourceAddr"
undef "Destination"
undef "BitBuffer"
undef "Table"
undef "BlockHeader"
undef "ExtraBits"
undef "Value"
undef "BitPosition"
undef "Link"
undef "Code"
undef "CopyEnd"
undef "Distance"
undef "OrderEnd"
undef "OrderRow"
undef "Symbol"
undef "RunEnd"
undef "LengthsEnd"
undef "PrevLength"
undef "LitCount"
undef "DistCount"
undef "Lengths"
undef "SymbolCount"
undef "CodeLength"
undef "Index"
undef "LinkAddr"
undef "SavedSource"
