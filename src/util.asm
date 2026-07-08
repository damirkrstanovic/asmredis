%include "syscalls.inc"
global atoi_port

section .text
; rdi = ptr to NUL-terminated decimal string -> rax = value
atoi_port:
    xor     rax, rax
.loop:
    movzx   rcx, byte [rdi]
    test    rcx, rcx
    je      .done
    cmp     rcx, '0'
    jb      .done
    cmp     rcx, '9'
    ja      .done
    imul    rax, rax, 10
    sub     rcx, '0'
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret
