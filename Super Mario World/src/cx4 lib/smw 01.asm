;===============================================================================
; Cx4 port of SMW's LC_LZ2 decompression
;
; In:  R0   Address of the compressed data in ROM, 24-bit. LoROM, banks $00-$3F
;           or $80-$BF, $8000-$FFFF. The data may cross banks.
;      R1   Where to write the output, in SRAM ($70:0000-$70:7FFF)
; Out: R0   Address right after the the end of the compressed data
;      R1   Address right after the the end of the decompressed data
;
; Modifies R2-R7, MAR and MDR.
;
; Optimized for cycles. In SMW's graphics, direct copy and repeat are 70% of
; the chunks, so the branching is optimized accordingly.
;===============================================================================

!SourceAddr    = R0                 ; Current offset of compressed data
!Destination   = R1                 ; Current offset of decompressed data output
!Header        = R2                 ; Header byte of current chunk
!LastByte      = R3                 ; Offset of the chunk's last output byte
!OutputStart   = R4                 ; Begin offset of decompressed data output for the "repeat" command
!CopyFrom      = R5                 ; Next byte to copy for the "repeat" command
!Value         = R6                 ; First byte of the "word fill" command
!Value2        = R7                 ; Second byte of the "word fill" command

macro LZ2ReadByte()
            LD A, !SourceAddr       ; \
            ST MAR, A               ;  | Read the ROM byte
            LD MDR, RDROM           ; /
            ADD A, #$01             ; \
            ST !SourceAddr, A       ;  | Increase offset of compressed data
            AND A, #$008000         ;  |
            JEQ ..NextBank          ; /
            WAIT                    ; MDR now contains the read byte
endmacro

;-------------------------------------------------------------------------------
; Initialize then jump into the main loop
;-------------------------------------------------------------------------------
.LZ2        LD A, !Destination
            ST !OutputStart, A
            BRA ..Loop

;-------------------------------------------------------------------------------
; Handle bank boundary crossing when reading the ROM
;-------------------------------------------------------------------------------
..NextBank  LD A, !SourceAddr
            OR A, #$008000
            ST !SourceAddr, A
            RTS

;-------------------------------------------------------------------------------
; 0: Direct copy. It's placed here so that at the end of the copy, it directly
; falls through into the loop, saving us 3 cycles from taking a branch instead
;-------------------------------------------------------------------------------
..DirectCopy
            %LZ2ReadByte()
            LD A, !Destination
            ST MAR, A
            ST RDRAM, MDR
            ADD A, #$01
            ST !Destination, A
            CMPR !LastByte, A
            WAIT
            BCS ..DirectCopy

;-------------------------------------------------------------------------------
; Read the chunk header
;-------------------------------------------------------------------------------
..Loop      %LZ2ReadByte()          ; \ Read header byte into A
            LD A, MDR               ; /
            CMP A, #$E0             ; \ $E0-$FF: long header or the end
            BCS ..LongHeader        ; /
            
            ST !Header, A           ; \
            AND A, #$1F             ;  | Determine which offset the final byte
            ADD A, !Destination     ;  | of the chunk should be written at
            ST !LastByte, A         ; / 

            LD A, !Header           ; \ Isolate command bits
            SHR A, #$05             ; /

..Dispatch  BEQ ..DirectCopy        ; Command 0: Direct Copy

            CMP A, #$04             ; \ Command 4-7: Repeat
            BCS ..Repeat            ; /

            CMP A, #$02             ; \ Command 2: Word Fill
            BEQ ..WordFill          ; /

            BCS ..IncreasingFill    ; Command 3: Increasing Fill
                                    ; Command 1: Fall through, below

;-------------------------------------------------------------------------------
; 1: Byte fill. Fills the same byte for an N amount of times.
;-------------------------------------------------------------------------------
..ByteFill  %LZ2ReadByte()

            LD A, !Destination      ; \
            ST MAR, A               ;  |
-           ST RDRAM, MDR           ;  | Write the byte to the destination
            ADD A, #$01             ;  |
            CMPR !LastByte, A       ;  |
            ST MAR, A               ;  |
            WAIT                    ;  | Loop if not done yet
            BCS -                   ; /

            ST !Destination, A      ; Update the destination offset
            BRA ..Loop

;-------------------------------------------------------------------------------
; 4: Repeat. Copy previously outputted bytes.
;-------------------------------------------------------------------------------
..Repeat    %LZ2ReadByte()          ; \
            ST !CopyFrom, MDR       ;  | Read the 16-bit offset, little endian
            %LZ2ReadByte()          ;  |
            LD A, !CopyFrom         ;  |
            OR A << 8, MDR          ; /  
            ADD A, !OutputStart     ; !OutputStart += !CopyFrom

-           ST MAR, A               ; \ 
            LD MDR, RDRAM           ;  |
            ADD A, #$01             ;  | Read byte from the SRAM
            ST !CopyFrom, A         ;  |
            LD A, !Destination      ;  |
            WAIT                    ; /

            ST MAR, A               ; \
            ST RDRAM, MDR           ;  |
            ADD A, #$01             ;  | Write the byte to the output
            ST !Destination, A      ;  | and update the destination offset
            CMPR !LastByte, A       ;  |
            LD A, !CopyFrom         ;  |
            WAIT                    ;  |
            BCS -                   ; /
            BRA ..Loop

;-------------------------------------------------------------------------------
; 2: Word fill. 
; Edge case: An odd length ends on the first byte
;-------------------------------------------------------------------------------
..WordFill  %LZ2ReadByte()          ; \
            ST !Value, MDR          ;  | Read word
            %LZ2ReadByte()          ;  |
            ST !Value2, MDR         ; /

            LD A, !Destination      ; \
            ST MAR, A               ;  |
-           LD MDR, !Value          ;  |
            ST RDRAM, MDR           ;  | Write the first byte
            ADD A, #$01             ;  |
            CMPR !LastByte, A       ;  | Handle edge case
            ST MAR, A               ;  |
            WAIT                    ;  |
            BMI +                   ; /

            LD MDR, !Value2         ; \
            ST RDRAM, MDR           ;  | Write the second byte
            ADD A, #$01             ;  |
            CMPR !LastByte, A       ;  |
            ST MAR, A               ;  |
            WAIT                    ;  |
            BCS -                   ; /
+           ST !Destination, A      ; Update the destination offset
            BRA ..Loop

;-------------------------------------------------------------------------------
; 3: Increasing fill.
; Edge case: Increase can wrap from $FF -> $00
;-------------------------------------------------------------------------------
..IncreasingFill
            %LZ2ReadByte()          ; Read the byte
            LD A, !Destination      ; \
            ST MAR, A               ;  |
-           ST RDRAM, MDR           ;  |
            ADD A, #$01             ;  | Write the byte
            ST !Destination, A      ;  |
            ST MAR, A               ;  |
            WAIT                    ; /
            LD A, MDR               ; \
            ADD A, #$01             ;  | Increase the byte's value by 1
            ST MDR, A               ; /
            LD A, !Destination      ; \
            CMPR !LastByte, A       ;  | Check loop end
            BCS -                   ; /
            BRA ..Loop

;-------------------------------------------------------------------------------
; Handle long header or decompression end
;-------------------------------------------------------------------------------
..LongHeader
            CMP A, #$FF             ; \
            SKIPZC                  ;  | $FF means we reached the end
            STOP                    ; /

            ST !Header, A           ; \
            AND A, #$03             ;  |
            ST !LastByte, A         ;  |
            %LZ2ReadByte()          ;  | Get the 12-bit length and the
            LD A, !LastByte         ;  | offset of the last byte of
            OR A << 8, MDR          ;  | the chunk
            ADD A, !Destination     ;  |
            ST !LastByte, A         ; /
            LD A, !Header           ; \
            SHR A, #$02             ;  | Extract the real command
            AND A, #$07             ; /
            BRA ..Dispatch

undef "SourceAddr"
undef "Destination"
undef "Header"
undef "LastByte"
undef "OutputStart"
undef "Value"
undef "Value2"
undef "CopyFrom"
