# Jump tables whose index register is copied from the compared one, with an unrelated compare of the index register's own number
# earlier (Skyrim's SkyrimVR.exe+0x12a3690: `cmpl $7, %ebx; ja; movslq %ebx, %rax; jmp [table + rax*4]` after `cmpl $1, %eax`).
# vxrt-aot must bound the table by the compare of EBX (8 entries), not by the one of EAX (2).
        .text
        .globl  sw_copy
sw_copy:                                # int sw_copy(int a /* ecx */, int b /* edx */)
        pushq   %rbx
        movl    %edx, %ebx
        leal    -1(%rbx), %eax
        cmpl    $1, %eax                # (unrelated: EAX is b - 1)
        jbe     .Ldone1
        cmpl    $7, %ebx
        ja      .Ldone1
        movslq  %ebx, %rax
        leaq    .Ltab1(%rip), %rdx
        movl    (%rdx,%rax,4), %edx
        leaq    __ImageBase(%rip), %r11
        addq    %r11, %rdx
        jmpq    *%rdx
.Lc0:   movl    $10, %eax
        popq    %rbx
        ret
.Lc1:   movl    $11, %eax
        popq    %rbx
        ret
.Lc2:   movl    $12, %eax
        popq    %rbx
        ret
.Lc3:   movl    $13, %eax
        popq    %rbx
        ret
.Lc4:   movl    $14, %eax
        popq    %rbx
        ret
.Lc5:   movl    $15, %eax
        popq    %rbx
        ret
.Lc6:   movl    $16, %eax
        popq    %rbx
        ret
.Lc7:   movl    $17, %eax
        popq    %rbx
        ret
.Ldone1: xorl   %eax, %eax
        popq    %rbx
        ret
        .section .rdata,"dr"
        .p2align 2
.Ltab1: .rva    .Lc0
        .rva    .Lc1
        .rva    .Lc2
        .rva    .Lc3
        .rva    .Lc4
        .rva    .Lc5
        .rva    .Lc6
        .rva    .Lc7
