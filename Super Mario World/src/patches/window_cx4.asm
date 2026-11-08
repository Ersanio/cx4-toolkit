;===============================================================================
; Windowing HDMA routine, Cx4 version
;
; Input :
;   $00      X center, in pixels
;   $01      Y center, in scanlines
;   $04-$05  Pointer to the top half shape table
;   $06-$07  Pointer to the bottom half shape table
;            If $07 is 00, the bottom half is not mirrored.
;   $1433    Window radius
;===============================================================================

!WindowTable = $6000                ; Where the Cx4 should build the table
                                    ; Valid ranges: $6000-$6A40
                                    ; (Cx4 RAM, $1C0 bytes)

            SEP #$30                ; 8-bit A, X and Y
            LDA $00                 ; \ 
            STA.w Cx4.R0            ;  | R0 = X center
            LDA $01                 ;  |
            STA.w Cx4.R1            ;  | R1 = Y center
            LDA $1433               ;  | 
            STA.w Cx4.R2            ; /  R2 = radius
            LDA $04                 ; \
            STA.w Cx4.R3            ;  | R3 = top half table ROM address
            LDA $05                 ;  |
            STA.w Cx4.R3+1          ;  |
            LDA $06                 ;  | R4 = bottom half table ROM address
            STA.w Cx4.R4            ;  |
            LDA $07                 ;  |
            STA.w Cx4.R4+1          ;  |
            PHB                     ;  |
            PLA                     ;  |
            STA.w Cx4.R3+2          ;  |
            STA.w Cx4.R4+2          ; /
            LDA.b #!WindowTable     ; \
            STA.w Cx4.R5            ;  | R5 = where to build the table
            LDA.b #!WindowTable>>8  ;  |
            STA.w Cx4.R5+1          ; /
            %RunProgram(Cx4SMW_Window) ; Run our Cx4 program

            LDA #$A0                ; \
            STA $2181               ;  | WRAM address = $7E:04A0
            LDA #$04                ;  |
            STA $2182               ;  |
            STZ $2183               ; /
            STZ $4330               ; DMA channel 3: 1 byte write once
            LDA #$80                ; \ $2180 (WRAM write)
            STA $4331               ; /
            LDA.b #!WindowTable     ; \
            STA $4332               ;  | Source
            LDA.b #!WindowTable>>8  ;  |
            STA $4333               ;  |
            STZ $4334               ; /
            LDA #$C0                ; \
            STA $4335               ;  | 448 bytes (224 lines)
            LDA #$01                ;  |
            STA $4336               ; /
            LDA #$08                ; \  Start the copy
            STA $420B               ; /
            LDA #$80                ; \
            TSB $0D9F               ; / Enable HDMA channel 7
            RTL                     ;
