!VectorRAM = $7E010D ; 8 bytes of free RAM, we're using some stack space. Allowed range is 7E0000-$7E1FFF
!FreeRAM   = $7F9F00 ; (up until $7FA5FF, after which it might be used by other tools, see https://smwc.me/1665507)

LOROM

incsrc "arch.asm"

ORG $1F8000|!FR
;===============================================================================
; Vectors that will immediately jump to WRAM
;===============================================================================

Vectors:
.NMI        JML !FreeRAM+(WRAM_NMI-WRAM)
.IRQ        JML !FreeRAM+(WRAM_IRQ-WRAM)
.end

;===============================================================================
; NMI & IRQ wrappers are located in WRAM. Cx4 calls and status polling, as well
;===============================================================================

WRAM:
.NMI        incsrc "wram_nmi.asm"
.IRQ        incsrc "wram_irq.asm"
.FirmwareExecute
            PHD
            PEA $7F00              ; Prefer custom dp to save 1 cycle
            PLD                    ; per status check, compared to abs

-           BIT.b Cx4.Status
            BVS -

            STY.b Cx4.PageSelect   ; Page low byte / 2
            STZ.b Cx4.PageSelect+1 ; Page high byte / 2
            STA.b Cx4.Command      ; Offset into page / 2. Activates the Cx4

-           BIT.b Cx4.Status
            BVS -

            PLD
            RTL

.FirmwareDMA 
            ; The Cx4 is capable of its own DMA. Accepted modes:
            ; - ROM -> Cx4 RAM
            ; - ROM -> SRAM
            ; - SRAM <-> Cx4 RAM
            ; The Cx4 RAM region is specified as $006000-$006BFF

            ; TODO: Implement
            NOP
            RTL

.FirmwarePreload ; Preload a specified page into cache
            ; TODO: Implement
            NOP
            RTL
.end

; Call the routines by JSLing to these address definitions
!Firmware = !FreeRAM+(WRAM_FirmwareExecute-WRAM)
!FirmwareDMA = !FreeRAM+(WRAM_FirmwareDMA-WRAM)
!FirmwarePreload = !FreeRAM+(WRAM_FirmwarePreload-WRAM)

;===============================================================================
; Implement Cx4 initialization and detection
;===============================================================================

BootstrapCx4:
            STZ $0100 ; \ Restore hijack; Game mode 00
            STZ $0109 ; / Signal overworld loading
            JSR InitVectors
            JSR InitWRAMRoutines
            JSR InitCx4
            RTL

InitVectors:
            LDX.b #Vectors_end-Vectors-1
-           LDA.l Vectors,x
            STA !VectorRAM,x
            DEX
            BPL -
            RTS

InitWRAMRoutines:
            LDX.b #WRAM_end-WRAM-1
-           LDA.l WRAM,x
            STA !FreeRAM,x
            DEX
            BPL -
            RTS

InitCx4:    ; As (somewhat) seen in Mega Man X3 ($0080C1)
            PHD
            PEA $7F00
            PLD
            STZ.b Cx4.ROMConfig
            LDA.b #!VectorRAM
            STA.b Cx4.NMI
            LDA.b #!VectorRAM>>8
            STA.b Cx4.NMI+1
            LDA.b #(!VectorRAM+4)
            STA.b Cx4.IRQ
            LDA.b #(!VectorRAM+4)>>8
            STA.b Cx4.IRQ+1
            LDA #$44
            STA.b Cx4.WaitState
            LDA #$01
            STA.b Cx4.IRQDisable
            LDA.b #Cx4SMW
            STA.b Cx4.ProgramBase
            LDA.b #Cx4SMW>>8
            STA.b Cx4.ProgramBase+1
            LDA.b #Cx4SMW>>16
            STA.b Cx4.ProgramBase+2
            STZ.b Cx4.CacheLock
            PLD
            RTS

TestCx4:    %RunProgram(Cx4SMW_Checksum) ; Outputs the Cx4 Data ROM checksum at R0
            LDA Cx4.R0+0 ; outputs 36
            CMP #$36
            BNE .cksmfailed
            LDA Cx4.R0+1 ; outputs 43
            CMP #$43
            BNE .cksmfailed
            LDA Cx4.R0+2 ; outputs 05
            CMP #$05
            BNE .cksmfailed

            LDA $700000                ; Back up SRAM
            TAX
            %RunProgram(Cx4SMW_SramWrite) ; Check if the Cx4 chip is able to write to SRAM
            LDA $700000
            CMP #$69                   ; It is expected that that Cx4 routine outputs #$69 at SRAM $700000
            BNE .sramfailed
            TXA
            STA $700000                ; Restore SRAM

            STZ $0701 ; \ Restore hijack
            STZ $0702 ; /
            RTL

.cksmfailed PEA $001F
.error	    PLA
		    STA $2122
		    PLA
		    STA $2122
         	LDA #$0F
		    STA $2100
		    LDA #$00
		    STA $2121
            STP

.sramfailed PEA $0FFF
            BRA .error

NewWindow:  incsrc "patches/window_cx4.asm"
NewAim:     incsrc "patches/aim_cx4.asm"

            ; Here are some more fun ideas:
            ; - Rotating platform/Ball N Chain/Reznor rotations
            ; - Optimize OAM
            ; - Optimize the LC_LZ2 decompression (into SRAM)
            ; - Implement DEFLATE decompression   (into SRAM)

Cx4SMW:     incsrc "cx4 lib/smw 00.asm"    ; Cx4 page 0

;===============================================================================
; Call Cx4 initialization and detection
;===============================================================================

ORG $008055|!FR ; Hijack the cartridge's init
            PHK
            PLB
            JSL BootstrapCx4

ORG $0093DA|!FR ; Hijack "Nintendo Presents"
            JSL TestCx4
            NOP #2

;===============================================================================
; Various upgrades to the game
;===============================================================================

ORG $00CA88|!FR              ; Hijack windowing HDMA routine
            JSL NewWindow
            RTS

ORG $01BF57|!FR              ; Hijack the Magikoopa's aiming
            LDA #$38         ; \  Originally #$20, new algorithm corrects the aiming
            JSL NewAim       ;  | routine and as a consequence, the projectile
            NOP #2           ; /  now has the same speed regardless of angle

;===============================================================================
; Essential setup for the Cx4 to be detected by the system
;===============================================================================
;
; Note: The ROM size is limited to 2 MB due to the pinout of the Cx4 chip;
; A0 through A14 and A16 through A21 make 21 address lines;
; It is a physical limitation.
;
; If ROM space ever becomes an issue, it is suggested to use the MSU-1,
; or a stronger compression algorithm such as the LC_LZ3 or DEFLATE.
; One could port the decompressing to Cx4.
;
;===============================================================================

ORG $00FFBF ; Cartridge Type (Sub-number)
            ; Necessary for the "Cx4 Debugger" to show in Mesen
            db $10 ; $FF in SMW

ORG $00FFD6 ; Cartridge Type
            ; Necessary for the "Cx4 Debugger" to show in Mesen
            db $F3 ; Cx4. $02 in SMW

ORG $00FFD8 ; SRAM size
            ; MesenCE takes the SRAM size from here, bsnes from smw.bml
            db $05 ; 32 KB. $01 (2 KB) in SMW

ORG $0082BC ; Custom NMI return in order to support direct page
            JML !FreeRAM+(WRAM_NMI_return-WRAM)

ORG $0083B2 ; Custom IRQ return in order to support direct page
            JML !FreeRAM+(WRAM_IRQ_return-WRAM)

ORG $00FFE4
InternalHeaders:
.NatCOP     dw $ED4E ; some random $DB (STP) in bank $00
.NatBRK     dw $ED4E
.NatABORT   dw $ED4E
.NatNMI     dw !VectorRAM
.NatRESET   dw $ED4E
.NatIRQ     dw !VectorRAM+4
.Unused     dd $FFFFFFFF
.EmuCOP     dw $ED4E
.EmuBRK     dw $ED4E
.EmuABORT   dw $ED4E
.EmuNMI     dw $ED4E
.EmuRESET   dw read2($FFFC)
.EmuIRQ     dw $ED4E

; TODO: The patch is programmed such that the NMI/IRQ are wrapped with a Cx4 status check in WRAM.
; In Megaman X3, the entire NMI/IRQ routine is in WRAM, instead.