%include "syscalls.inc"
global time_refresh, g_now_ms

section .bss
g_now_ms:    resq 1                     ; cached CLOCK_REALTIME milliseconds
ts_buf:      resq 2                     ; struct timespec {tv_sec, tv_nsec}

section .text
; time_refresh(): g_now_ms = now in ms. Clobbers rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11.
; Preserves rbx,rbp,r12-r15.
time_refresh:
    mov     rax, SYS_clock_gettime
    mov     rdi, CLOCK_REALTIME
    lea     rsi, [rel ts_buf]
    syscall
    mov     r8, [rel ts_buf]           ; tv_sec
    imul    r8, r8, 1000               ; sec*1000
    mov     rax, [rel ts_buf+8]        ; tv_nsec (< 1e9)
    xor     rdx, rdx
    mov     r9, 1000000
    div     r9                         ; rax = nsec/1e6 (0..999)
    add     rax, r8
    mov     [rel g_now_ms], rax
    ret
