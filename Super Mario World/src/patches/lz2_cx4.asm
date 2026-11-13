;===============================================================================
; LC_LZ2 decompression, Cx4 version
;===============================================================================

!LZ2Buffer = $700400                ; Past SMW's save files ($70:0000-$70:0359)

            PHB
            PHK
            PLB

            LDX $8A                 ; \
            STX.w Cx4.R0            ;  | R0 = source
            LDA $8C                 ;  |
            STA.w Cx4.R0+2          ; /
            LDX.w #!LZ2Buffer       ; \
            STX.w Cx4.R1            ;  | R1 = !LZ2Buffer
            LDA.b #!LZ2Buffer>>16   ;  |
            STA.w Cx4.R1+2          ; /
            %Cx4ColdRun(Cx4SMW_LZ2)

            LDX.w Cx4.R0
            STX $8A
            LDA.w Cx4.R0+2
            STA $8C

            REP #$20
            LDA.w Cx4.R1
            SEC
            SBC.w #!LZ2Buffer
            TAY
            BEQ .Done
            STA $4335
            LDA.w #!LZ2Buffer
            STA $4332
            LDA $00
            STA $2181
            SEP #$20
            LDA.b #!LZ2Buffer>>16
            STA $4334
            LDA $02
            STA $2183
            STZ $4330
            LDA #$80
            STA $4331
            LDA #$08
            STA $420B

.Done       SEP #$20
            PLB
            JML $00B8EA|!FR
