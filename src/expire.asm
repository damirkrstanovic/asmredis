%include "syscalls.inc"
global time_refresh, g_now_ms
global cmd_expire, cmd_pexpire, cmd_expireat, cmd_pexpireat, cmd_ttl, cmd_pttl, cmd_persist
extern argc, argv_ptrs, argv_lens
extern parse_int, reply_int, ks_lookup, ks_del
extern emit_wrongargs, emit_notint, emit_invalid_expire

section .rodata
lc_expire:    db "expire"
lc_pexpire:   db "pexpire"
lc_expireat:  db "expireat"
lc_pexpireat: db "pexpireat"
lc_ttl:       db "ttl"
lc_pttl:      db "pttl"
lc_persist:   db "persist"

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

cmd_expire:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1000
    mov     rsi, [rel g_now_ms]
    lea     rdx, [rel lc_expire]
    mov     rcx, 6
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_expire]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pexpire:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1
    mov     rsi, [rel g_now_ms]
    lea     rdx, [rel lc_pexpire]
    mov     rcx, 7
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_pexpire]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_expireat:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1000
    xor     rsi, rsi
    lea     rdx, [rel lc_expireat]
    mov     rcx, 8
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_expireat]
    mov     rsi, 8
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pexpireat:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1
    xor     rsi, rsi
    lea     rdx, [rel lc_pexpireat]
    mov     rcx, 9
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_pexpireat]
    mov     rsi, 9
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _set_expire(rdi=mult, rsi=basetime, rdx=nameptr, rcx=namelen)
_set_expire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int
    test    rdx, rdx
    jz      .notint
    mov     rbx, rax
    cmp     r12, 1000
    jne     .addbase
    mov     rax, 9223372036854775
    cmp     rbx, rax
    jg      .invalid
    mov     rax, -9223372036854775
    cmp     rbx, rax
    jl      .invalid
    imul    rbx, rbx, 1000
.addbase:
    mov     rax, 0x7fffffffffffffff
    sub     rax, r13
    cmp     rbx, rax
    jg      .invalid
    add     rbx, r13
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    mov     rcx, [rel g_now_ms]
    cmp     rbx, rcx
    jg      .setttl
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
    mov     rdi, 1
    call    reply_int
    jmp     .done
.setttl:
    mov     [rax+48], rbx
    mov     rdi, 1
    call    reply_int
    jmp     .done
.zero:
    xor     edi, edi
    call    reply_int
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.invalid:
    mov     rdi, r14
    mov     rsi, r15
    call    emit_invalid_expire
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

cmd_ttl:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     edi, edi
    jmp     _ttl_generic
.wa:
    lea     rdi, [rel lc_ttl]
    mov     rsi, 3
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pttl:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     edi, 1
    jmp     _ttl_generic
.wa:
    lea     rdi, [rel lc_pttl]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _ttl_generic(rdi=ms_flag)
_ttl_generic:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    mov     rcx, [rax+48]
    test    rcx, rcx
    jz      .nottl
    sub     rcx, [rel g_now_ms]
    test    rbx, rbx
    jnz     .emit
    add     rcx, 500
    mov     rax, rcx
    xor     rdx, rdx
    mov     rcx, 1000
    div     rcx
    mov     rcx, rax
.emit:
    mov     rdi, rcx
    call    reply_int
    jmp     .done
.miss:
    mov     rdi, -2
    call    reply_int
    jmp     .done
.nottl:
    mov     rdi, -1
    call    reply_int
.done:
    pop     rbx
    ret

cmd_persist:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+48], 0
    je      .zero
    mov     qword [rax+48], 0
    mov     rdi, 1
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_persist]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
