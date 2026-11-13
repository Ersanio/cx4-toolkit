;===============================================================================
; Magikoopa magic aiming, Cx4 version
;
; The aiming routine is improved and is processed on the Cx4 now.
;
; Input:
;   A        Requested speed
;   X, Y     Slot of the new magic sprite
;
; Output:
;   $00      Y speed
;   $01      X speed
;===============================================================================
            PHY
            STA.w Cx4.R0            ;    R0 = speed
            LDA $E4,x               ; \  R1 = origin X: Magikoopa magic
            STA.w Cx4.R1            ;  |
            LDA $14E0,x             ;  |
            STA.w Cx4.R1+1          ; /
            LDA $D8,x               ; \  R2 = origin Y
            STA.w Cx4.R2            ;  |
            LDA $14D4,x             ;  |
            STA.w Cx4.R2+1          ; /
            LDA $D1                 ; \  R3 = target X: The player
            STA.w Cx4.R3            ;  |
            LDA $D2                 ;  |
            STA.w Cx4.R3+1          ; /
            LDA $D3                 ; \  R4 = target Y + 8 pixels down
            CLC                     ;  |
            ADC #$08                ;  |
            STA.w Cx4.R4            ;  |
            LDA $D4                 ;  |
            ADC #$00                ;  |
            STA.w Cx4.R4+1          ; /
            %Cx4ColdRun(Cx4SMW_Aim) ; Run the aiming routine
            LDA.w Cx4.R5            ; \ $01 = X speed
            STA $01                 ; /
            LDA.w Cx4.R6            ; \ $00 = Y speed
            STA $00                 ; /
            PLY
            RTL
