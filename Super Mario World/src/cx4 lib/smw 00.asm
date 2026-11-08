arch cx4
base $0000

;===============================================================================
; Test 3k Data ROM Checksum
; Out: R0 ($7F80) = sum of all 3072 data ROM bytes (24-bit): Always $054336
;===============================================================================

.Checksum
            LD A, #$00
            ST R0, A
            %LDA($03FF)
            ST R1, A       ; Set the loop counter
-           LD A, R1
            RDROM A

            LD A, ROMB
            AND A, #$FF    ; Current data ROM value's low byte
            ADD A, R0
            ST R0, A

            LD A, ROMB
            SHR A, #$08
            AND A, #$FF    ; Current data ROM value's high byte
            ADD A, R0
            ST R0, A

            LD A, ROMB
            SHR A, #$10    ; Current data ROM value's bank byte
            ADD A, R0
            ST R0, A

            LD A, R1
            SUB A, #$01
            ST R1, A
            %BPL(-)

            STOP

;===============================================================================
; Test availability of SRAM writes through the Cx4
; Out: SRAM $700000 is set to #$69
;
; This should NOT work for the FxPak Pro (as of firmware 1.11.2)
;===============================================================================

.SramWrite  %LDA($700000)
            ST MAR, A
            LD A, #$69
            ST MDR, A
            ST RDRAM, MDR
            WAIT
            STOP

;===============================================================================
; Windowing HDMA
; Cx4 port of $00CA88 with some out-of-bounds fixes applied.
;
; In:  R0   X center, in pixels (0-255)                    (mirror $00)
;      R1   Y center, in scanlines (0-255)                 (mirror $01)
;      R2   Window radius (0-255)                          (mirror $1433)
;           Only the low byte of R0-R2 is used, the routine clears bits 8-23.
;      R3   24-bit address of the top half shape table
;           For example: $00CB12 for the circle.
;      R4   24-bit address of the bottom half shape table
;           For example: $00CB12 for the circle.
;           The keyhole passes $000000 as to not mirror the keyhole vertically.
;      R5   Address of the output table in Cx4 RAM, as the SNES sees it
;           ($6000-$6A40). Only bits 0-11 are used. The table takes $1C0 bytes.
;
; Out: [R5]  Window table, 2 bytes per scanline: left-right span
;            ($2126/$2127), 224 lines.
; Modifies R6-R10, and bits 8-23 of R0-R2.
;===============================================================================

; in
!XCenter     = R0
!YCenter     = R1
!Radius      = R2
!TopHalf     = R3
!BottomHalf  = R4
!OutputAddr  = R5
; scratch
!ShapeIndex  = R6
!InvRadius   = R7
!EndDistance = R8
!HalfWidth   = R9
!Distance    = R10

.Window
; Sanitize R0-R2
; If this Cx4 page ever runs out of space, this could technically be moved to window_cx4.asm, instead
            LD A, !XCenter          ; \
            AND A, #$FF             ;  | X center
            ST !XCenter,A           ; / 
            LD A, !YCenter          ; \
            AND A, #$FF             ;  | Y center
            ST !YCenter,A           ; / 
            LD A, !Radius           ; \
            AND A, #$FF             ;  | Radius
            ST !Radius, A           ; / 

; Initialize all 224 lines
; If this Cx4 page ever runs out of space, this could technically be moved to window_cx4.asm, instead
; However, this routine will be more costly than moving the above routine
            LD A, #$FF
            ST RAMB, A              ; RAMB low byte 0 = $FF, high byte = $00
            %LDA($01BE)             ; Begin loop
..Init      ADD A, !OutputAddr      ; \
            ST DPR, A               ;  | Set A to Cx4 RAM + loop number
            SUB A, !OutputAddr      ; /
            WRRAM #$00, 0           ; Write $FF
            WRRAM #$01, 1           ; Write $00
            SUB A, #$02             ; \
            BCS ..Init              ; / Continue loop

; Start the main routine
            LD A, !YCenter          ; \
            SUBR #224, A          ;  | !EndDistance = Math.Min(Math.Max(Math.Max(224 - !YCenter, 0), !YCenter) + 1, !Radius);
            SKIPCS                  ;  |
            LD A, #$00              ;  |
            CMP A, !YCenter         ;  |
            SKIPCS                  ;  | (End) Distance = amount of scanlines away from the base of the shape
            LD A, !YCenter          ;  |
            ADD A, #$01             ;  |
            CMP A, !Radius          ;  |
            SKIPCC                  ;  |
            LD A, !Radius           ;  |
            ST !EndDistance,A       ; /

            LD A, #$00              ; \  Initialize distance and table index
            ST !Distance, A         ;  |
            ST !ShapeIndex, A       ; /

            LD A, !Radius           ; \
            RDROM A                 ;  | !InvRadius = $800000 / Radius
            LD A, ROMB              ;  |
            ADD A, #$01             ;  | The Cx4 Div table's calculations are floored, this makes it ceiling instead
            ST !InvRadius, A        ; /  to match SMW's original calculation exactly

..LineLoop  LD A, !Distance         ; \
            ADD A, #$01             ;  | Distance++
            ST !Distance, A         ;  |
            CMP A, !EndDistance     ;  | Finish the routine if we reached the end
            BCS ..Done              ; /

            LD A, !Distance         ; \  Distance << 8 * ($800000 / Radius) >> 24
            SHL A, #$08             ;  |
            SMUL A, !InvRadius      ;  |
            NOP                     ;  |
            LD A, MACH              ;  | This shifts right by 24 by dropping MACL
            ST !ShapeIndex, A       ; /

; Draw top half
            LD A, !YCenter          ; \
            SUB A, !Distance        ;  | - If the next line happens to be above the visible screen,
            %BCC(..Bottom)          ; /    then skip to drawing the bottom part instead
            CMP A, #224           ; \  - If it happens to be below the screen
            BCS ..Bottom            ; /    then skip to drawing the bottom part instead
            ADD A << 1, !OutputAddr ; \
            ST DPR, A               ; / DPR = table + line * 2
            LD A, !TopHalf          ; \
            JSR ..DrawLine          ; / Draw top half shape

; Draw bottom half (vertically mirrored)
..Bottom    LD A, !BottomHalf        ; \
            AND A, #$00FF00          ;  | If no shape source is specified
            BEQ ..LineLoop           ; /  skip the bottom half

            LD A, !YCenter           ; \
            ADD A, !Distance         ;  |
            SUB A, #$01              ;  | - If the next line happens to be below the visible screen,
            CMP A, #224            ;  |   then skip drawing a line
            BCS ..LineLoop           ; / 
            ADD A << 1, !OutputAddr  ; \
            ST DPR, A                ; / DPR = table + line * 2
            LD A, !BottomHalf        ; \
            JSR ..DrawLine           ; / Draw bottom half shape
            BRA ..LineLoop           ; Continue the draw loop
..Done      STOP

;-------------------------------------------------------------------------------
; Writes one line of the window table.
; In:  A    shape table address
;      R6   shape index
;      DPR  table + line * 2
;-------------------------------------------------------------------------------
..DrawLine  ADD A, !ShapeIndex       ; \ Get ROM index to the shape table
            ST MAR, A                ; /
            LD MDR, RDROM            ; \  Read shape table from ROM
            WAIT                     ;  |
            LD A, MDR                ; /
            SMUL A, !Radius          ; \ 
            NOP                      ;  | HalfWidth = table[index] * radius >> 8
            LD A, MACL               ;  |
            SHR A, #$08              ;  |
            ST !HalfWidth, A         ; /

            LD A, !XCenter           ; \
            SUB A, !HalfWidth        ;  | Left edge = X center - half-width
            SKIPCS                   ;  |
            LD A, #$00               ;  | clamped at 0
            ST RAMB, A               ;  |
            WRRAM #$00, 0            ; /

            LD A, !XCenter           ; \
            ADD A, !HalfWidth        ;  | Right edge = X center + half-width
            CMP A, #$FF              ;  |
            SKIPCC                   ;  |
            LD A, #$FF               ;  | clamped at 255
            ST RAMB, A               ;  |
            WRRAM #$01, 0            ; /

            RTS

undef "XCenter"
undef "YCenter"
undef "Radius"
undef "TopHalf"
undef "BottomHalf"
undef "OutputAddr"
undef "ShapeIndex"
undef "InvRadius"
undef "EndDistance"
undef "HalfWidth"
undef "Distance"

;===============================================================================
; Aiming
;
; Cx4 version of SMW's aiming routine CODE_01BF6A (Magikoopa's magic).
; The routine returns the projectile's calculated X and Y speed towards a given
; target. It is improved to use vector normalization, making the projectile
; shoot towards the target at the same speed, regardless of the angle.
;
;   X speed = Speed * dx / sqrt(dx^2 + dy^2)
;   Y speed = Speed * dy / sqrt(dx^2 + dy^2)
; with [dx = target X - origin X] and [dy = target Y - origin Y].
;
; In:  R0   Speed (signed 8-bit). Negative aims away from the target
;      R1   Origin X (16-bit)
;      R2   Origin Y (16-bit)
;      R3   Target X (16-bit)
;      R4   Target Y (16-bit)
; Out: R5   X speed (signed)
;      R6   Y speed (signed)
;
; Differences from SMW's routine:
; - Every direction gets the same speed. SMW gives the longer axis the full
;   speed, so its diagonal shots were faster.
; - Distances of 128 pixels and more are measured correctly. SMW only used
;   the low byte of each distance.
; - Speeds are rounded to the nearest integer instead of down.
;===============================================================================

; in
!Speed       = R0
!OriginX     = R1
!OriginY     = R2
!TargetX     = R3
!TargetY     = R4
; out
!OutXSpeed   = R5
!OutYSpeed   = R6
; scratch
!DeltaX      = R5                   ; dx
!DeltaY      = R6                   ; dy
!ScaledDX    = R7                   ; |dx| at first, then dx scaled
!ScaledDY    = R8                   ; |dy| at first, then dy scaled
!LengthSq    = R9                   ; q = dx^2 + dy^2
!InvLength   = R10                  ; y = $100000000 / sqrt(q)
!SpeedScale  = R11                  ; Speed * y / $100
!NewtonTemp  = R11                  ; temp for ..NewtonRaphson, before SpeedScale
!ShiftCount  = R12                  ; left shift that scales dx and dy
!ThreeHalves = R13                  ; $600000 = 1.5, for ..NewtonRaphson

.Aim
            LD A, !TargetX          ; \
            SUB A, !OriginX         ;  | DeltaX = dx = target X - origin X,
            SXW                     ;  | sign-extended
            ST !DeltaX, A           ;  |
            SKIPNC                  ;  | ScaledDX = |dx|
            SUBR #$00, A            ;  |
            ST !ScaledDX, A         ; /

            LD A, !TargetY          ; \
            SUB A, !OriginY         ;  | DeltaY = dy = target Y - origin Y,
            SXW                     ;  | sign-extended
            ST !DeltaY, A           ;  |
            SKIPNC                  ;  | ScaledDY = |dy|
            SUBR #$00, A            ;  |
            ST !ScaledDY, A         ; /

            LD A, !ScaledDX         ; \
            OR A, !ScaledDY         ;  | Edge case: Target is exactly inside
            %BNE(..Proceed)         ;  | the source. If so: Aim straight down
            LD A, #$01              ;  |
            ST !DeltaY, A           ; / 

..Proceed   SHL A, #$07             ; \  This whole section with the shifting
            ST !ShiftCount, A       ;  | left-and-right-magic is so that the
            LD A, #$06              ;  | aiming calculation fits in the 24-bit
            SWAP A, !ShiftCount     ;  | registers of the Cx4. We can already
..SLCount   SWAP A, !ShiftCount     ;  | shift 7 times to the left, as the input
            ADD A, #$01             ;  | always is signed 16-bit.
            SWAP A, !ShiftCount     ;  | 
            SHL A, #$01             ;  | Then, we calculate how many times more
            %BPL(..SLCount)         ; /  we can shift to the left.

            LD A, !DeltaX           ; \  We use ShiftCount to scale down our
            SHL A, !ShiftCount      ;  | |dx| + |dy|: (d[x/y] << ShiftCount) >> 12
            ASR A, #$0C             ;  | 
            ST !ScaledDX, A         ;  | The proportionally scaled down dx/dy are
            LD A, !DeltaY           ;  | small enough to be used in a signed MACL
            SHL A, !ShiftCount      ;  | squaring calculation, which happens right
            ASR A, #$0C             ;  | after this section.
            ST !ScaledDY, A         ; /

            SMUL A, !ScaledDY       ; \  dy^2, we store this in MDR. We use MDR as
            NOP                     ;  | a scratch register.
            LD MDR, MACL            ;  | 
            LD A, !ScaledDX         ;  | dx^2
            SMUL A, !ScaledDX       ;  |
            NOP                     ;  | 
            LD A, MACL              ;  | LengthSq = dx^2 + dy^2
            ADD A, MDR              ;  |
            ;SKIPNC                 ;  | Distances of >=$800 result in $800000,
            ;SUB A, #$01            ;  | we make it $7FFFFF
            ST !LengthSq, A         ; /

            SHR A, #$10             ; \  Produce an inverse-square-root estimate
            RDROM A                 ;  | This first data ROM lookup gives us 1/n
            LD MDR, ROMB            ;  |
            ADD A, #$000100         ;  | 
            RDROM A                 ;  | This second data ROM lookup gives us sqrt(n)
            LD A, ROMB              ;  | 
            SHR A, #$03             ; /
            SMUL A, MDR             ; \  We multiply them for 1 / sqrt(n)
            NOP                     ;  |
            LD A, MACL              ;  |
            SHR A, #$10             ;  |
            ST !InvLength, A        ;  |
            LD A, MACH              ;  |
            ADD A << 8, !InvLength  ;  |
            ST !InvLength, A        ; / 

            %LDA($600000)           ; \ ThreeHalves = $600000 (1.5)
            ST !ThreeHalves, A      ; /
            JSR ..NewtonRaphson     ; \ Necessary to have better accuracy for
            JSR ..NewtonRaphson     ; / higher projectile speeds

            LD A, !Speed            ; \
            SXB                     ;  | SpeedScale = Speed * y / $100, with
            SMUL A, !InvLength      ;  | Speed sign-extended from 8 bits
            NOP                     ;  |
            LD A, MACL              ;  |
            SHR A, #$08             ;  |
            ST !SpeedScale, A       ;  |
            LD A, MACH              ;  | (MACL >> 8 plus MACH << 16)
            ADD A << 16,!SpeedScale ;  |
            ST !SpeedScale, A       ; /

            LD A, !ScaledDX         ; \
            SMUL A, !SpeedScale     ;  | X speed = scaled dx * SpeedScale
            NOP                     ;  | / $1000000 (MACH), rounded: + 1 when
            LD A, MACL              ;  | bit 23 of MACL (the .5) is set
            SHR A, #$17             ;  |
            ADD A, MACH             ;  |
            ST !OutXSpeed, A        ; /

            LD A, !ScaledDY         ; \
            SMUL A, !SpeedScale     ;  | Y speed, the same way
            NOP                     ;  |
            LD A, MACL              ;  |
            SHR A, #$17             ;  |
            ADD A, MACH             ;  |
            ST !OutYSpeed, A        ; /
            STOP

;-------------------------------------------------------------------------------
; One Newton-Raphson step, which brings y closer to $100000000 / sqrt(q):
;   y = y * (3 - q * y^2 / $10000000000000000) / 2
; If y is too large, the factor (3 - ...) / 2 is below 1.0 and y gets smaller.
; If y is too small, it is above 1.0 and y gets larger. Each step roughly
; squares the error: the data ROM estimate is up to 3% off, one step brings it
; down to 0.14% and two steps to 0.0004%.
;
; The factor uses $400000 = 1.0. SMUL is signed, so the largest value
; is $7FFFFF, just under 2.0. 3.0 would be $C00000, which reads as negative,
; so we calculate the factor as 1.5 - (q * y^2 / 2) instead.
;
; In:  R9   q
;      R10  y
;      R13  $600000, 1.5
; Out: R10  y, more accurate
;-------------------------------------------------------------------------------
..NewtonRaphson
            LD A, !InvLength        ; \  y^2 >> 24. The full product can be up
            SMUL A, !InvLength      ;  | to 48 bits, so we only keep MACH to
            NOP                     ;  | make it fit in a 24-bit register.
            LD A, MACH              ; /
            SMUL A, !LengthSq       ; \  q * y^2 >> 24. Since y is about
            NOP                     ;  | $100000000 / sqrt(q), this is always
            LD A, MACL              ;  | about $10000000000. We shift it right
            SHR A, #$13             ;  | by 19 more, for about $200000 (0.5):
            ST !NewtonTemp, A       ;  | half of q * y^2 / $10000000000000000.
            LD A, MACH              ;  |
            SHL A, #$05             ;  | MACL >> 19 and MACH << 5 don't overlap,
            OR A, !NewtonTemp       ; /  so OR works as an addition here.
            SUBR !ThreeHalves, A    ; Factor = 1.5 - A, about $400000 (1.0)
            SMUL A, !InvLength      ; \  y * factor
            NOP                     ;  |
            LD A, MACL              ;  | As $400000 = 1.0, we shift right by
            SHR A, #$16             ;  | 22 for the new y.
            ST !NewtonTemp, A       ;  |
            LD A, MACH              ;  | MACL >> 22 OR MACH << 2, the same
            SHL A, #$02             ;  | way as above.
            OR A, !NewtonTemp       ;  |
            ST !InvLength, A        ; /
            RTS

undef "Speed"
undef "OriginX"
undef "OriginY"
undef "TargetX"
undef "TargetY"
undef "OutXSpeed"
undef "OutYSpeed"
undef "DeltaX"
undef "DeltaY"
undef "ScaledDX"
undef "ScaledDY"
undef "LengthSq"
undef "InvLength"
undef "SpeedScale"
undef "NewtonTemp"
undef "ShiftCount"
undef "ThreeHalves"

fillbyte $FF
fill align $200
base off
arch 65816
