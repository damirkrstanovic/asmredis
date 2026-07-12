%include "syscalls.inc"
global reply_simple, reply_bulk, reply_null, reply_int, reply_err, append_raw
global reply_array_header
extern cur_out, cur_cap, cur_len, cur_err, cur_mmap
extern mem_map_grow
extern itoa_u

section .rodata
null_bulk:     db "$-1", 13, 10
null_bulk_len: equ $ - null_bulk

section .text
; ---- internal helpers (append to cur_out at [cur_len], bounds-checked) ----

; _grow(rdi = required capacity): ensure cur_cap >= rdi, growing via mmap.
; On mmap failure sets cur_err (caller then skips the write). Preserves nothing
; the callers rely on except via the globals. rsp aligned by the caller.
_grow:
    call    mem_map_grow             ; (rdi=need) -> updates cur_out/cur_cap/cur_mmap
    ret                             ;              or sets cur_err on failure

_put_byte:                           ; r8b = byte
    mov     rax, [rel cur_len]
    cmp     rax, [rel cur_cap]
    jb      .store
    push    r8                       ; save byte across _grow (align: 1 push -> ==0)
    lea     rdi, [rax+1]
    call    _grow
    pop     r8
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.store:
    mov     r11, [rel cur_out]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel cur_len], rax
.skip:
    ret

_put_bytes:                          ; rdi=src, rsi=len
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, rsi
    cmp     rdx, [rel cur_cap]
    jbe     .copy
    push    rdi
    push    rsi                      ; 2 pushes -> ==8; +8 to align _grow call
    sub     rsp, 8
    mov     rdi, rdx                 ; need = cur_len + n
    call    _grow
    add     rsp, 8
    pop     rsi
    pop     rdi
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.copy:
    mov     r11, [rel cur_out]
    lea     r10, [r11+rax]
    mov     rcx, rsi
    push    rsi
    mov     rsi, rdi
    mov     rdi, r10
    rep     movsb
    pop     rsi
    add     [rel cur_len], rsi
.skip:
    ret

_put_crlf:
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, 2
    cmp     rdx, [rel cur_cap]
    jbe     .store
    mov     rdi, rdx
    sub     rsp, 8                   ; align _grow call (entry ==8 -> ==0)
    call    _grow
    add     rsp, 8
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.store:
    mov     r11, [rel cur_out]
    mov     word [r11+rax], 0x0a0d
    add     qword [rel cur_len], 2
.skip:
    ret

_put_uint:                       ; rdi=value
    sub     rsp, 32
    mov     rsi, rsp
    call    itoa_u                ; rax=len, [rsp..] filled
    mov     rdi, rsp
    mov     rsi, rax
    call    _put_bytes
    add     rsp, 32
    ret

; ---- public reply builders ----

reply_simple:                    ; rdi=ptr, rsi=len -> "+<payload>\r\n"
    push    rdi
    push    rsi
    mov     r8b, '+'
    call    _put_byte
    pop     rsi
    pop     rdi
    call    _put_bytes
    call    _put_crlf
    ret

reply_bulk:                      ; rdi=ptr, rsi=len -> "$<len>\r\n<payload>\r\n"
    push    rdi
    push    rsi
    mov     r8b, '$'
    call    _put_byte
    mov     rdi, [rsp]            ; len (top of stack = pushed rsi)
    call    _put_uint
    call    _put_crlf
    pop     rsi
    pop     rdi
    call    _put_bytes
    call    _put_crlf
    ret

reply_null:                      ; -> "$-1\r\n"
    lea     rdi, [rel null_bulk]
    mov     rsi, null_bulk_len
    call    _put_bytes
    ret

reply_int:                       ; rdi=signed value -> ":<n>\r\n"
    push    rdi
    mov     r8b, ':'
    call    _put_byte
    pop     rdi
    test    rdi, rdi
    jns     .mag
    push    rdi                  ; same stack idiom as the ':' emit above
    mov     r8b, '-'
    call    _put_byte
    pop     rdi
    neg     rdi                  ; magnitude (INT64_MIN -> 2^63 unsigned, printed correctly)
.mag:
    call    _put_uint
    call    _put_crlf
    ret

reply_err:                       ; rdi=ptr, rsi=len -> "<payload>\r\n"
    call    _put_bytes
    call    _put_crlf
    ret

append_raw:                      ; rdi=ptr, rsi=len -> raw bytes, no crlf
    call    _put_bytes
    ret

reply_array_header:              ; rdi=count -> "*<n>\r\n"
    push    rdi
    mov     r8b, '*'
    call    _put_byte
    pop     rdi
    call    _put_uint
    call    _put_crlf
    ret
