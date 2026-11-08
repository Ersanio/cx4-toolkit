incsrc "lib_cx4.asm"

if read1($00FFD5)&$20 == $20
    !FastROM = 1
    print "- The ROM had FastROM already applied, so the patch will use FastROM addressing"
    print "- Note: FastROM in conjuction with the Cx4 does not work on the FxPak Pro (TODO: not yet tested with firmware 1.11.2)"
else
    !FastROM = 0
    print "- Note: FastROM is compatible with the Cx4 (TODO: except for the FxPak Pro; not yet tested with firmware 1.11.2)"
    print "- Feel free to enable it in Lunar Magic for a new project"
endif

!FR = !FastROM<<23
