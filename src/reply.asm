%include "syscalls.inc"
global reply_simple, reply_bulk, reply_null, reply_int, reply_err, append_raw
global reply_array_header
extern out_buf, out_len
extern itoa_u

section .rodata
null_bulk:     db "$-1", 13, 10
null_bulk_len: equ $ - null_bulk

section .text
; ---- internal helpers (append to out_buf at [out_len]) ----

_put_byte:                       ; r8b = byte
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel out_len], rax
    ret

_put_bytes:                      ; rdi=src, rsi=len
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    lea     r10, [r11+rax]        ; dest = out_buf + out_len
    mov     rcx, rsi
    push    rsi
    mov     rsi, rdi              ; src
    mov     rdi, r10              ; dest
    rep     movsb
    pop     rsi
    add     [rel out_len], rsi
    ret

_put_crlf:
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    mov     word [r11+rax], 0x0a0d ; bytes 0d 0a
    add     qword [rel out_len], 2
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

reply_int:                       ; rdi=value -> ":<n>\r\n"
    push    rdi
    mov     r8b, ':'
    call    _put_byte
    pop     rdi
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
