;===============================================================================
; Wrapper for Cx4 program pages
;===============================================================================

macro Cx4Page(page, file)
    arch cx4
    base (<page>)*$200
    incsrc <file>
    assert pc() <= ((<page>)+1)*$200, "Cx4 page ", hex(<page>, 2), " is ", dec(pc()-((<page>)+1)*$200), " bytes over its 512"
    print "- Cx4 page ", hex(<page>, 2), ": ", dec(((<page>)+1)*$200-pc()), " out of 512 bytes left"
    fillbyte $FF
    fill align $200
    base off
    arch 65816
endmacro

; Like Cx4Page, for a file of <count> pages. The file splits its pages itself
; (fill align $200 between them) and checks all but the last one.
macro Cx4Pages(page, count, file)
    arch cx4
    base (<page>)*$200
    incsrc <file>
    assert pc() <= ((<page>)+(<count>))*$200, "Cx4 page ", hex((<page>)+(<count>)-1, 2), " is ", dec(pc()-((<page>)+(<count>))*$200), " bytes over its 512"
    print "- Cx4 page ", hex((<page>)+(<count>)-1, 2), ": ", dec(((<page>)+(<count>))*$200-pc()), " out of 512 bytes left"
    fillbyte $FF
    fill align $200
    base off
    arch 65816
endmacro
