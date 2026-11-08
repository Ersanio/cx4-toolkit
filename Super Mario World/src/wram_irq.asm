SEI
PHP
REP #$30
PHA
PHX
PHY
PHB
PHD
PEA $0000
PLD
SEP #$30
LDA #$00
PHA
PLB

BIT.w Cx4.Status ; TODO: Should this wait rather than skip?
BVS ..return

LDA $004211
JML $008383|!FR	; IRQ

..return
REP #$30
PLD
PLB
PLY
PLX
PLA
PLP
RTI
