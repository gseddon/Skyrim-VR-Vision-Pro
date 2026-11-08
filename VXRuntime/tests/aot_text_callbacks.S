    .text
    .balign 8
    .globl aot_text_callbacks
aot_text_callbacks:
    .quad callback_leaf
    .byte 0xcc, 0xcc, 0xcc, 0xcc
callback_leaf:
    movl $42, %eax
    ret
