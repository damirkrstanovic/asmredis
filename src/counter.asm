%include "syscalls.inc"
global cmd_incr, cmd_decr, cmd_incrby, cmd_decrby
extern argc, argv_ptrs, argv_lens
extern ks_lookup, ks_set
extern parse_int, itoa_s
extern reply_int
extern emit_wrongargs, emit_wrongtype, emit_notint, emit_oom
extern emit_incrdecr_ovf, emit_decr_ovf

section .rodata
lc_incr:    db "incr"
lc_decr:    db "decr"
lc_incrby:  db "incrby"
lc_decrby:  db "decrby"

section .text
; cmd_incr: INCR key -> :<value+1>
cmd_incr:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     rdi, 1
    jmp     _incr_by                 ; tail call (stack unchanged)
.wa:
    lea     rdi, [rel lc_incr]
    mov     rsi, 4
    sub     rsp, 8                   ; entry ==8 -> ==0 for the call
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_decr: DECR key -> :<value-1>
cmd_decr:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     rdi, -1
    jmp     _incr_by
.wa:
    lea     rdi, [rel lc_decr]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_incrby: INCRBY key increment
cmd_incrby:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8                   ; align calls (==8 -> ==0)
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int                ; rax=incr, rdx=valid
    test    rdx, rdx
    jz      .notint
    add     rsp, 8                   ; restore before tail call
    mov     rdi, rax
    jmp     _incr_by
.notint:
    call    emit_notint
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_incrby]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_decrby: DECRBY key decrement  (= key + (-decrement))
cmd_decrby:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int                ; rax=decr, rdx=valid
    test    rdx, rdx
    jz      .notint
    mov     rcx, 0x8000000000000000  ; LLONG_MIN cannot be negated
    cmp     rax, rcx
    je      .decrovf
    neg     rax                      ; increment = -decr
    add     rsp, 8
    mov     rdi, rax
    jmp     _incr_by
.decrovf:
    call    emit_decr_ovf
    add     rsp, 8
    ret
.notint:
    call    emit_notint
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_decrby]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _incr_by(rdi = signed increment): shared counter core. Key is argv[1].
; new = current(0 if absent) + increment; store as a string; reply :<new>.
; Errors: WRONGTYPE (non-string key) / not-integer value / overflow / oom.
;   rbx=key ptr  r15=key len  r12=increment  r13=new value.  [rsp..] = digit buffer.
_incr_by:
    push    rbx
    push    r12
    push    r13
    push    r15                      ; 4 pushes: entry ==8 -> ==8
    sub     rsp, 24                  ; digit buffer (>=21); ==8 -> ==0 at calls
    mov     r12, rdi                 ; increment
    mov     rbx, [rel argv_ptrs + 8] ; key ptr
    mov     r15, [rel argv_lens + 8] ; key len
    mov     rdi, rbx
    mov     rsi, r15
    call    ks_lookup                ; rax = entry | 0
    test    rax, rax
    jz      .cur_zero
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]            ; val ptr
    mov     rsi, [rax+32]            ; val len
    call    parse_int                ; rax=val, rdx=valid
    test    rdx, rdx
    jz      .notint
    jmp     .have_cur
.cur_zero:
    xor     rax, rax
.have_cur:
    add     rax, r12                 ; new = current + increment
    jo      .overflow
    mov     r13, rax                 ; new value
    mov     rdi, r13
    lea     rsi, [rsp]               ; digit buffer
    call    itoa_s                   ; rax = length
    mov     rdi, rbx                 ; key ptr
    mov     rsi, r15                 ; key len
    lea     rdx, [rsp]               ; value bytes
    mov     rcx, rax                 ; value len
    call    ks_set                   ; rax = 0 ok / 1 oom
    test    rax, rax
    jnz     .oom
    mov     rdi, r13
    call    reply_int
.done:
    add     rsp, 24
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret
.wrongtype:
    call    emit_wrongtype
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.overflow:
    call    emit_incrdecr_ovf
    jmp     .done
.oom:
    call    emit_oom
    jmp     .done
