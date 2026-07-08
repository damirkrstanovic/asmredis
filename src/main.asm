%include "syscalls.inc"

global _start

section .rodata
banner:      db "asmredis", 10
banner_len:  equ $ - banner
flag_banner: db "--banner"

section .text
_start:
    mov     rax, [rsp]          ; argc
    cmp     rax, 2
    jl      .no_banner
    mov     rsi, [rsp+16]       ; argv[1]
    mov     rax, [rsi]          ; first 8 bytes of argv[1]
    mov     rbx, [rel flag_banner]
    cmp     rax, rbx
    jne     .no_banner
    mov     rax, SYS_write
    mov     rdi, 1
    lea     rsi, [rel banner]
    mov     rdx, banner_len
    syscall
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
.no_banner:
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
