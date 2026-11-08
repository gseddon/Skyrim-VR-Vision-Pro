.text
.globl mainCRTStartup
mainCRTStartup:
 nop
 .byte 0x0f, 0xfc, 0xc0
 ret
