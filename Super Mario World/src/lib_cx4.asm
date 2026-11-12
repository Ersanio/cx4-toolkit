;===============================================================================
; Helper functions for the Capcom Consumer Custom Chip (Cx4)
; The Cx4 is a Hitachi HG51B169
;===============================================================================

struct Cx4 $006000
    .RAM skip 3072                        ; $6000-6BFF 3072 bytes of Cx4 RAM
    .Mirror skip 4928                     ; $6C00-7F3F Mirror of Cx4 RAM and I/O ports
    .DMASource skip 3                     ; $7F40-7F42 Cx4 DMA source, 24 bit SNES LoROM address
    .DMALength skip 2                     ; $7F43-7F44 Cx4 DMA length in bytes, 16 bit. A length of 0 copies nothing
    .DMADestination skip 3                ; $7F45-7F46 Cx4 DMA destination, low + high. 16-bit. Transfers allowed: ROM <-> Cx4 RAM (base $006000). Cx4 RAM <-> SRAM
                                          ; $7F47      Cx4 DMA destination, bank byte. Writing to it starts DMA and sets Cx4 status to Busy
    .Preload skip 1                       ; $7F48      Preload page. Bit 0 selects cache page 0 or 1. While the Cx4 is stopped, it also loads the respective block into the cache (a "preload"), bypassing any cache locks
    .ProgramBase skip 3                   ; $7F49-7F4B Program Base, 24bit LoROM addr (e.g. $028000 in MMX2-3); The address where page 00 of the Cx4 programs start
    .CacheLock skip 1                     ; $7F4C      Cache lock; Locks pages so cache misses won't auto-replace pages. Bit 0 locks cache page 0, bit 1 locks cache page 1
    .PageSelect skip 2                    ; $7F4D-7F4E PC/$200. Writing to it selects a page. (e.g. $02 = page $04 - "select the second page")
    .Command skip 1                       ; $7F4F      PC/$2. Writing to it selects an offset within the page (e.g. $04 = $08 - "select the 4th opcode"). Writing to it starts execution of the Cx4 program and sets Cx4 status to Busy
    .WaitState skip 1                     ; $7F50      Bits 0-2 = SRAM throttle, bits 4-6 = ROM throttle. Each Cx4 bus access (ROM, SRAM) is throttled by <wait> cycles, including the Cx4 DMA
    .IRQDisable skip 1                    ; $7F51      Writing 0 raises an IRQ to the SNES when it stops. Writing 1 disables the Cx4 IRQ, clears I and releases the SNES IRQ line. Write 1, then 0 to ack an IRQ and keep it enabled
    .ROMConfig skip 1                     ; $7F52      Physical ROM chip configuration. 0 = 2 chips, 1 = 1 chip. Despite MMX2 and MMX3 initially set it to 0, MMX3 does set it to 1 later on at offset $00D90C and $00D93D
    .ForceStop skip 1                     ; $7F53      Stops the Cx4 and clears the lock left by an invalid DMA (e.g. ROM <-> ROM)
    .Unused01 skip 1                      ; $7F54      Unused
    .Suspend skip 1                       ; $7F55      Suspend the Cx4 until $7F5D (.Resume) is written
    .Suspend32 skip 1                     ; $7F56      Suspend the Cx4 for 32 cycles
    .Suspend64 skip 1                     ; $7F57      Suspend the Cx4 for 64 cycles
    .Suspend96 skip 1                     ; $7F58      Suspend the Cx4 for 96 cycles
    .Suspend128 skip 1                    ; $7F59      Suspend the Cx4 for 128 cycles
    .Suspend160 skip 1                    ; $7F5A      Suspend the Cx4 for 160 cycles
    .Suspend192 skip 1                    ; $7F5B      Suspend the Cx4 for 192 cycles
    .Suspend224 skip 1                    ; $7F5C      Suspend the Cx4 for 224 cycles
    .Resume skip 1                        ; $7F5D      Resume from suspended state ($7F55). Timed suspends cannot be resumed in BSNES
    .Status skip 1                        ; $7F5E      Bit 6 = Busy, set upon [$7F47], [$7F48], [$7F4F] writes
    .Unused02 skip 1                      ; $7F5F      Unused
    .Vector01 skip 10                     ; $7F60-7F69 Vector copy     [FFE0..FFE9]
    .NMI skip 2                           ; $7F6A-7F6B SNES NMI Vector [FFEA..FFEB]
    .Vector02 skip 2                      ; $7F6C-7F6D Vector copy     [FFEC..FFED]
    .IRQ skip 2                           ; $7F6E-7F6F SNES IRQ Vector [FFEE..FFEF]
    .Vector03 skip 16                     ; $7F70-7F7F Vector copy     [FFF0..FFFF]
    .R0 skip 3                            ; $7F80-7F82 Cx4 Register R0
    .R1 skip 3                            ; $7F83-7F85 Cx4 Register R1
    .R2 skip 3                            ; $7F86-7F88 Cx4 Register R2
    .R3 skip 3                            ; $7F89-7F8B Cx4 Register R3
    .R4 skip 3                            ; $7F8C-7F8E Cx4 Register R4
    .R5 skip 3                            ; $7F8F-7F91 Cx4 Register R5
    .R6 skip 3                            ; $7F92-7F94 Cx4 Register R6
    .R7 skip 3                            ; $7F95-7F97 Cx4 Register R7
    .R8 skip 3                            ; $7F98-7F9A Cx4 Register R8
    .R9 skip 3                            ; $7F9B-7F9D Cx4 Register R9
    .R10 skip 3                           ; $7F9E-7FA0 Cx4 Register R10
    .R11 skip 3                           ; $7FA1-7FA3 Cx4 Register R11
    .R12 skip 3                           ; $7FA4-7FA6 Cx4 Register R12
    .R13 skip 3                           ; $7FA7-7FA9 Cx4 Register R13
    .R14 skip 3                           ; $7FAA-7FAC Cx4 Register R14
    .R15 skip 3                           ; $7FAD-7FAF Cx4 Register R15
    .Unused03 skip 16                     ; $7FB0-7FBF Unknown/unused
    .MirrorR0 skip 3                      ; $7FC0-7FC2 Cx4 Register R0 (Mirror)
    .MirrorR1 skip 3                      ; $7FC3-7FC5 Cx4 Register R1 (Mirror)
    .MirrorR2 skip 3                      ; $7FC6-7FC8 Cx4 Register R2 (Mirror)
    .MirrorR3 skip 3                      ; $7FC9-7FCB Cx4 Register R3 (Mirror)
    .MirrorR4 skip 3                      ; $7FCC-7FCE Cx4 Register R4 (Mirror)
    .MirrorR5 skip 3                      ; $7FCF-7FD1 Cx4 Register R5 (Mirror)
    .MirrorR6 skip 3                      ; $7FD2-7FD4 Cx4 Register R6 (Mirror)
    .MirrorR7 skip 3                      ; $7FD5-7FD7 Cx4 Register R7 (Mirror)
    .MirrorR8 skip 3                      ; $7FD8-7FDA Cx4 Register R8 (Mirror)
    .MirrorR9 skip 3                      ; $7FDB-7FDD Cx4 Register R9 (Mirror)
    .MirrorR10 skip 3                     ; $7FDE-7FE0 Cx4 Register R10 (Mirror)
    .MirrorR11 skip 3                     ; $7FE1-7FE3 Cx4 Register R11 (Mirror)
    .MirrorR12 skip 3                     ; $7FE4-7FE6 Cx4 Register R12 (Mirror)
    .MirrorR13 skip 3                     ; $7FE7-7FE9 Cx4 Register R13 (Mirror)
    .MirrorR14 skip 3                     ; $7FEA-7FEC Cx4 Register R14 (Mirror)
    .MirrorR15 skip 3                     ; $7FED-7FEF Cx4 Register R15 (Mirror)
    .Unused04 skip 16                     ; $7FF0-7FFF Unknown/unused
endstruct

;===============================================================================
; Macros for Cx4 code. Use these in `arch cx4`
;
; Most of them go through A, so they change A. Register arguments are R0-R15:
; A doesn't work as a register operand (it reads as 0 in bsnes).
;===============================================================================

;-------------------------------------------------------------------------------
; Loading values
;-------------------------------------------------------------------------------

; Load an 8-24-bit immediate value into A. Optimized to use the constant registers.
macro LDA(value)
    if <value> == $FFFFFF
            LD A, IR1
    elseif <value> == $00FF00
            LD A, IR2
    elseif <value> == $FF0000
            LD A, IR3
    elseif <value> == $00FFFF
            LD A, IR4
    elseif <value> == $FFFF00
            LD A, IR5
    elseif <value> == $800000
            LD A, IR6
    elseif <value> == $7FFFFF
            LD A, IR7
    elseif <value> == $008000
            LD A, IR8
    elseif <value> == $007FFF
            LD A, IR9
    elseif <value> == $FF7FFF
            LD A, IR10
    elseif <value> == $FFFF7F
            LD A, IR11
    elseif <value> == $010000
            LD A, IR12
    elseif <value> == $FEFFFF
            LD A, IR13
    elseif <value> == $000100
            LD A, IR14
    elseif <value> == $00FEFF
            LD A, IR15
    elseif <value> < $100
            LD A, #<value>
    elseif <value> < $10000
            LD A, #(<value>)>>8
            OR A << 8, #(<value>)&$FF
    elseif ((<value>)&$FFFF) == 0
            LD A, #(<value>)>>16
            SHL A, #16
    else
            LD A, #(<value>)>>16
            OR A << 8, #((<value>)>>8)&$FF
            OR A << 8, #(<value>)&$FF
    endif
endmacro

;-------------------------------------------------------------------------------
; Branches and calls
;-------------------------------------------------------------------------------

macro BNE(label)                 ; Z = 0: not equal, not zero
            SKIPZS
            BRA <label>
endmacro

macro BCC(label)                 ; C = 0: after SUB or CMP, lower (borrow)
            SKIPCS
            BRA <label>
endmacro

macro BPL(label)                 ; N = 0: plus
            SKIPNS
            BRA <label>
endmacro

macro BVC(label)                 ; v = 0: no overflow
            SKIPVS
            BRA <label>
endmacro

macro JSL(label)
            LD P,#(<label>)>>9
            JSR P:<label>
endmacro

macro BRL(label)
            LD P,#(<label>)>>9
            BRA P:<label>
endmacro

;===============================================================================
; Macros for SNES Cx4-related code
;===============================================================================

; Run the Cx4 program without preloading it. The Cx4 handles the cache miss.
macro Cx4ColdRun(label)
            PHA
            PHY
            PHP
            SEP #$30
            LDY.b #(<label>)>>9
            LDA.b #(<label>)>>1
            JSL !Cx4ColdRun
            PLP
            PLY
            PLA
endmacro

; Run the Cx4 program after preloading the page into a cache page of your choice, first.
macro Cx4PreloadedRun(label, cache)
            PHA
            PHY
            PHX
            PHP
            SEP #$30
            LDX.b #(<cache>)&1
            LDY.b #(<label>)>>9
            LDA.b #(<label>)>>1
            JSL !Cx4PreloadedRun
            PLP
            PLX
            PLY
            PLA
endmacro

; Preload the Cx4 page into a cache page of your choice.
macro Cx4Preload(label)
            PHY
            PHX
            PHP
            SEP #$30
            LDX.b #(<cache>)&1
            LDY.b #(<label>)>>9     ; page
            JSL !Cx4Preload
            PLP
            PLX
            PLY
endmacro

function Cx4IsROM(address)  = (((address)&$408000) == $008000) || (((address)&$C00000) == $C00000)
function Cx4IsSRAM(address) = (((address)&$F88000) == $700000)
function Cx4IsDRAM(address) = (((address)&$40F000) == $006000) && (((address)&$0C00) != $0C00)
function Cx4Region(address) = select(Cx4IsROM(address), 1, 0)|select(Cx4IsSRAM(address), 2, 0)|select(Cx4IsDRAM(address), 3, 0)
function Cx4LastByte(address, length) = ((address)+(length)-1)&$FFFFFF
function Cx4InOneBlock(address, length) = (Cx4Region(address) == Cx4Region(Cx4LastByte(address, length))) && (((address)>>16) == (Cx4LastByte(address, length)>>16))

; Run the Cx4 DMA.
macro Cx4DMA(source, destination, length)
    assert (<length>) >= $0001 && (<length>) <= $FFFF, "Cx4 DMA: length <length> isn't $0001-$FFFF"
    assert Cx4Region(<source>) != 0, "Cx4 DMA: source <source> isn't ROM, SRAM or Cx4 RAM"
    assert Cx4Region(<destination>) >= 2, "Cx4 DMA: destination <destination> isn't SRAM or Cx4 RAM"
    assert Cx4Region(<source>) != Cx4Region(<destination>), "Cx4 DMA: <source> -> <destination> is inside one region (ROM -> ROM, SRAM -> SRAM and Cx4 RAM -> Cx4 RAM aren't allowed)"
    assert Cx4InOneBlock(<source>, <length>), "Cx4 DMA: source <source> + <length> bytes runs out of its region or bank"
    assert Cx4InOneBlock(<destination>, <length>), "Cx4 DMA: destination <destination> + <length> bytes runs out of its region or bank"

            PHA
            PHP
            SEP #$30
            PHD
            PEA $7F00
            PLD
            LDA.b #<source>
            STA.b Cx4.DMASource+0
            LDA.b #(<source>)>>8
            STA.b Cx4.DMASource+1
            LDA.b #(<source>)>>16
            STA.b Cx4.DMASource+2
            LDA.b #<length>
            STA.b Cx4.DMALength+0
            LDA.b #(<length>)>>8
            STA.b Cx4.DMALength+1
            LDA.b #<destination>
            STA.b Cx4.DMADestination+0
            LDA.b #(<destination>)>>8
            STA.b Cx4.DMADestination+1
            LDA.b #(<destination>)>>16
            JSL !Cx4DMA
            PLD
            PLP
            PLA
endmacro