%include "syscalls.inc"
global emit_protoerr, emit_wrongargs
global emit_wrongtype, emit_notint, emit_oom
global emit_incrdecr_ovf, emit_decr_ovf
global emit_invalid_expire
extern append_raw

section .rodata
m_proto:     db "-ERR Protocol error", 13, 10
m_proto_len  equ $ - m_proto
wa_pre:      db "-ERR wrong number of arguments for '"
wa_pre_len   equ $ - wa_pre
wa_post:     db "' command", 13, 10
wa_post_len  equ $ - wa_post
m_wrongtype:     db "-WRONGTYPE Operation against a key holding the wrong kind of value", 13, 10
m_wrongtype_len  equ $ - m_wrongtype
m_notint:        db "-ERR value is not an integer or out of range", 13, 10
m_notint_len     equ $ - m_notint
m_iovf:          db "-ERR increment or decrement would overflow", 13, 10
m_iovf_len       equ $ - m_iovf
m_dovf:          db "-ERR decrement would overflow", 13, 10
m_dovf_len       equ $ - m_dovf
m_oom2:          db "-ERR out of memory", 13, 10
m_oom2_len       equ $ - m_oom2
iexp_pre:     db "-ERR invalid expire time in '"
iexp_pre_len  equ $ - iexp_pre
iexp_post:    db "' command", 13, 10
iexp_post_len equ $ - iexp_post

section .text
; emit_protoerr: append "-ERR Protocol error\r\n" to the reply buffer.
emit_protoerr:
    lea     rdi, [rel m_proto]
    mov     rsi, m_proto_len
    jmp     append_raw                 ; tail-call (append_raw ends in ret)

; emit_wrongargs(rdi=lowercase name ptr, rsi=name len): append the full line
;   -ERR wrong number of arguments for '<name>' command\r\n
; append_raw clobbers rsi/rdi, so stash the name in callee-saved regs.
; Entered with rsp%16==8 (caller does the +8 to align the calls below).
emit_wrongargs:
    push    rbx
    push    r12
    sub     rsp, 8                     ; entry rsp%16==8 -> after 2 push + 8 -> 0
    mov     rbx, rdi                   ; name ptr
    mov     r12, rsi                   ; name len
    lea     rdi, [rel wa_pre]
    mov     rsi, wa_pre_len
    call    append_raw
    mov     rdi, rbx
    mov     rsi, r12
    call    append_raw
    lea     rdi, [rel wa_post]
    mov     rsi, wa_post_len
    call    append_raw
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

emit_wrongtype:
    lea     rdi, [rel m_wrongtype]
    mov     rsi, m_wrongtype_len
    jmp     append_raw

emit_notint:
    lea     rdi, [rel m_notint]
    mov     rsi, m_notint_len
    jmp     append_raw

emit_incrdecr_ovf:
    lea     rdi, [rel m_iovf]
    mov     rsi, m_iovf_len
    jmp     append_raw

emit_decr_ovf:
    lea     rdi, [rel m_dovf]
    mov     rsi, m_dovf_len
    jmp     append_raw

emit_oom:
    lea     rdi, [rel m_oom2]
    mov     rsi, m_oom2_len
    jmp     append_raw

; emit_invalid_expire(rdi=lowercase name ptr, rsi=name len)
emit_invalid_expire:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rel iexp_pre]
    mov     rsi, iexp_pre_len
    call    append_raw
    mov     rdi, rbx
    mov     rsi, r12
    call    append_raw
    lea     rdi, [rel iexp_post]
    mov     rsi, iexp_post_len
    call    append_raw
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
