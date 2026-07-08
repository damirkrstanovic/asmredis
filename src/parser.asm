%include "syscalls.inc"
global parse_one
extern argc, argv_ptrs, argv_lens

section .text
; parse_one: rdi=buf start, rsi=bytes available
;   -> rax = status (0=OK, 1=NEED_MORE, 2=PROTOERR)
;      rdx = bytes consumed (valid on OK)
; Fills argc, argv_ptrs[i], argv_lens[i] (pointing INTO the buffer).
; Registers: r8=cursor, r9=end, r10=index, r11=N, rbx=scratch (saved).
parse_one:
    push    rbx
    mov     r8, rdi               ; cursor
    lea     r9, [rdi+rsi]         ; end
    cmp     r8, r9
    jae     .need
    cmp     byte [r8], '*'
    jne     .proto
    inc     r8
    call    _read_uint            ; rax=value, rdx=status, r8 advanced past \r\n
    cmp     rdx, 1
    je      .need
    cmp     rdx, 2
    je      .proto
    mov     r11, rax              ; N (argc)
    cmp     r11, MAX_ARGS
    ja      .proto
    mov     [rel argc], r11
    xor     r10, r10              ; index
.arg:
    cmp     r10, r11
    jae     .ok
    cmp     r8, r9
    jae     .need
    cmp     byte [r8], '$'
    jne     .proto
    inc     r8
    call    _read_uint            ; rax=bulk length
    cmp     rdx, 1
    je      .need
    cmp     rdx, 2
    je      .proto
    ; need rax payload bytes + 2 (trailing CRLF) still in buffer
    mov     rcx, r9
    sub     rcx, r8               ; remaining bytes
    mov     rbx, rax
    add     rbx, 2                ; payload + CRLF
    cmp     rcx, rbx
    jb      .need
    ; record argv[r10] = (r8, rax)
    lea     rbx, [rel argv_ptrs]
    mov     [rbx + r10*8], r8
    lea     rbx, [rel argv_lens]
    mov     [rbx + r10*8], rax
    add     r8, rax               ; skip payload (CRLF guaranteed in-bounds)
    cmp     byte [r8], 13
    jne     .proto
    cmp     byte [r8+1], 10
    jne     .proto
    add     r8, 2
    inc     r10
    jmp     .arg
.ok:
    mov     rdx, r8
    sub     rdx, rdi              ; bytes consumed
    xor     rax, rax
    pop     rbx
    ret
.need:
    mov     rax, 1
    pop     rbx
    ret
.proto:
    mov     rax, 2
    pop     rbx
    ret

; _read_uint: parse ASCII decimal at [r8], terminated by \r\n; advances r8
;   past the \r\n. -> rax=value, rdx: 0=ok 1=need 2=proto. Clobbers rax,rcx,rdx.
_read_uint:
    xor     rax, rax
.d:
    cmp     r8, r9
    jae     .nm
    movzx   rcx, byte [r8]
    cmp     rcx, 13
    je      .cr
    cmp     rcx, '0'
    jb      .pe
    cmp     rcx, '9'
    ja      .pe
    imul    rax, rax, 10
    sub     rcx, '0'
    add     rax, rcx
    ; Cap at READ_BUF_SIZE: any bulk length / array count larger than the
    ; read buffer can never be assembled anyway. This also makes the caller's
    ; `len + 2` computation unable to wrap (guards a remote SIGSEGV).
    cmp     rax, READ_BUF_SIZE
    ja      .pe
    inc     r8
    jmp     .d
.cr:
    lea     rcx, [r8+1]
    cmp     rcx, r9
    jae     .nm                   ; need the LF byte too
    cmp     byte [r8+1], 10
    jne     .pe
    add     r8, 2
    xor     rdx, rdx
    ret
.nm:
    mov     rdx, 1
    ret
.pe:
    mov     rdx, 2
    ret
