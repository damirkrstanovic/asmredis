%include "syscalls.inc"
global arena_init, arena_alloc

section .bss
arena_next: resq 1
arena_end:  resq 1

section .text
; arena_init: mmap ARENA_SIZE anon RW; store base/end; exit(1) on failure.
arena_init:
    mov     rax, SYS_mmap
    xor     rdi, rdi
    mov     rsi, ARENA_SIZE
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9, r9
    syscall
    cmp     rax, -4095          ; mmap error range [-4095,-1]
    jae     .fail
    mov     [rel arena_next], rax
    add     rax, ARENA_SIZE
    mov     [rel arena_end], rax
    ret
.fail:
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; arena_alloc(rdi=size) -> rax=ptr (8-byte aligned) or 0 if exhausted
arena_alloc:
    add     rdi, 7
    and     rdi, -8
    mov     rax, [rel arena_next]
    mov     rcx, rax
    add     rcx, rdi
    cmp     rcx, [rel arena_end]
    ja      .oom
    mov     [rel arena_next], rcx
    ret
.oom:
    xor     rax, rax
    ret
