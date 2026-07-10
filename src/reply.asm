%include "syscalls.inc"
global reply_simple, reply_bulk, reply_null, reply_int, reply_err, append_raw
global reply_array_header
extern cur_out, cur_cap, cur_len, cur_err
extern itoa_u

section .rodata
null_bulk:     db "$-1", 13, 10
null_bulk_len: equ $ - null_bulk

section .text
; ---- internal helpers (append to cur_out at [cur_len], bounds-checked) ----

_put_byte:                       ; r8b = byte
    mov     rax, [rel cur_len]
    cmp     rax, [rel cur_cap]   ; room for 1 more byte? (need cur_len < cur_cap)
    jae     .oom
    mov     r11, [rel cur_out]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel cur_len], rax
    ret
.oom:
    mov     qword [rel cur_err], 1
    ret

_put_bytes:                      ; rdi=src, rsi=len
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, rsi             ; cur_len + n
    cmp     rdx, [rel cur_cap]
    ja      .oom                 ; would exceed cap
    mov     r11, [rel cur_out]
    lea     r10, [r11+rax]       ; dest = cur_out + cur_len
    mov     rcx, rsi
    push    rsi
    mov     rsi, rdi             ; src
    mov     rdi, r10             ; dest
    rep     movsb
    pop     rsi
    add     [rel cur_len], rsi
    ret
.oom:
    mov     qword [rel cur_err], 1
    ret

_put_crlf:
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, 2
    cmp     rdx, [rel cur_cap]
    ja      .oom
    mov     r11, [rel cur_out]
    mov     word [r11+rax], 0x0a0d ; bytes 0d 0a
    add     qword [rel cur_len], 2
    ret
.oom:
    mov     qword [rel cur_err], 1
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
