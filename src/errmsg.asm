%include "syscalls.inc"
global emit_protoerr, emit_wrongargs
global emit_wrongtype, emit_notint, emit_oom
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
m_oom2:          db "-ERR out of memory", 13, 10
m_oom2_len       equ $ - m_oom2

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

emit_oom:
    lea     rdi, [rel m_oom2]
    mov     rsi, m_oom2_len
    jmp     append_raw
