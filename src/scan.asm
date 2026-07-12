%include "syscalls.inc"
global cmd_scan
extern argc, argv_ptrs, argv_lens
extern ks_scan_prep
extern parse_int, itoa_u, memcmp_n, to_upper_buf
extern reply_bulk, reply_array_header
extern emit_wrongargs, emit_notint, emit_syntax, emit_invalidcursor

section .rodata
lc_scan:  db "scan"
o_match:  db "MATCH"
o_count:  db "COUNT"

section .bss
scan_obuf:  resb 8                 ; uppercased option token
scan_cbuf:  resb 24                ; cursor decimal string
scan_kptr:  resq 4096              ; collected key ptrs
scan_klen:  resq 4096              ; collected key lens
sp_pat:     resq 1                 ; MATCH pattern ptr (0 = none)
sp_patlen:  resq 1
sp_count:   resq 1

section .text
; _rev64(rdi) -> rax: reverse the 64 bits of rdi. Leaf.
_rev64:
    mov     rax, rdi
    mov     rcx, rax                ; swap adjacent bits
    shr     rax, 1
    mov     rdx, 0x5555555555555555
    and     rax, rdx
    and     rcx, rdx
    lea     rax, [rax + rcx*2]
    mov     rcx, rax                ; swap bit-pairs
    shr     rax, 2
    mov     rdx, 0x3333333333333333
    and     rax, rdx
    and     rcx, rdx
    lea     rax, [rax + rcx*4]
    mov     rcx, rax                ; swap nibbles
    shr     rax, 4
    mov     rdx, 0x0f0f0f0f0f0f0f0f
    and     rax, rdx
    and     rcx, rdx
    shl     rcx, 4
    or      rax, rcx
    bswap   rax                     ; swap bytes -> full bit reversal
    ret

; _glob_match(rdi=pat, rsi=plen, rdx=str, rcx=slen) -> rax=1/0. '*','?',literal. Leaf.
;   r8=p r9=s r10=star r11=mark
_glob_match:
    xor     r8, r8
    xor     r9, r9
    mov     r10, -1
    xor     r11, r11
.gloop:
    cmp     r9, rcx
    jae     .gtail
    cmp     r8, rsi
    jae     .gstar
    mov     al, [rdi + r8]
    cmp     al, '*'
    je      .gsetstar
    cmp     al, '?'
    je      .gadv
    cmp     al, [rdx + r9]
    jne     .gstar
.gadv:
    inc     r8
    inc     r9
    jmp     .gloop
.gsetstar:
    mov     r10, r8
    mov     r11, r9
    inc     r8
    jmp     .gloop
.gstar:
    cmp     r10, -1
    je      .gno
    lea     r8, [r10+1]
    inc     r11
    mov     r9, r11
    jmp     .gloop
.gtail:
    cmp     r8, rsi
    jae     .gyes
    mov     al, [rdi + r8]
    cmp     al, '*'
    jne     .gno
    inc     r8
    jmp     .gtail
.gyes:
    mov     eax, 1
    ret
.gno:
    xor     eax, eax
    ret

; cmd_scan: SCAN cursor [MATCH p] [COUNT n]
;   rbx=v(cursor) r12=table r13=mask r14=buckets-left r15=n(collected)
cmd_scan:
    cmp     qword [rel argc], 2
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    parse_int
    test    rdx, rdx
    jz      .badcursor
    mov     rbx, rax                ; v = cursor
    mov     qword [rel sp_pat], 0
    mov     qword [rel sp_count], 10
    mov     r15, 2                  ; i
.optloop:
    cmp     r15, [rel argc]
    jae     .optsdone
    lea     rax, [rel argv_lens]
    mov     r14, [rax + r15*8]      ; token len
    cmp     r14, 5
    jne     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rsi, [rel scan_obuf]
    mov     rcx, 5
.ocpy:
    mov     al, [rdi]
    mov     [rsi], al
    inc     rdi
    inc     rsi
    dec     rcx
    jnz     .ocpy
    lea     rdi, [rel scan_obuf]
    mov     rsi, 5
    call    to_upper_buf
    lea     rdi, [rel scan_obuf]
    lea     rsi, [rel o_match]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      .opt_match
    lea     rdi, [rel scan_obuf]
    lea     rsi, [rel o_count]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      .opt_count
    jmp     .syntax
.opt_match:
    inc     r15
    cmp     r15, [rel argc]
    jae     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8]
    mov     [rel sp_pat], rcx
    lea     rax, [rel argv_lens]
    mov     rcx, [rax + r15*8]
    mov     [rel sp_patlen], rcx
    inc     r15
    jmp     .optloop
.opt_count:
    inc     r15
    cmp     r15, [rel argc]
    jae     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + r15*8]
    call    parse_int
    test    rdx, rdx
    jz      .notint
    test    rax, rax
    jle     .syntax                 ; COUNT < 1
    mov     [rel sp_count], rax
    inc     r15
    jmp     .optloop
.optsdone:
    call    ks_scan_prep            ; rax=table, rdx=mask
    mov     r12, rax
    mov     r13, rdx
    mov     r14, [rel sp_count]     ; buckets to scan
    xor     r15, r15                ; n = 0
.scanloop:
    mov     rax, rbx
    and     rax, r13
    mov     rax, [r12 + rax*8]      ; node = bucket head
.chain:
    test    rax, rax
    jz      .nextbucket
    push    rax                     ; save node
    cmp     qword [rel sp_pat], 0
    je      .collect
    mov     rdi, [rel sp_pat]
    mov     rsi, [rel sp_patlen]
    mov     rdx, [rax+8]            ; key ptr
    mov     rcx, [rax+16]           ; key len
    call    _glob_match
    test    rax, rax
    jz      .skipkey
.collect:
    cmp     r15, 4096
    jae     .skipkey
    pop     rax
    push    rax
    mov     rcx, [rax+8]
    lea     rdx, [rel scan_kptr]
    mov     [rdx + r15*8], rcx
    mov     rcx, [rax+16]
    lea     rdx, [rel scan_klen]
    mov     [rdx + r15*8], rcx
    inc     r15
.skipkey:
    pop     rax
    mov     rax, [rax]              ; node = node->next
    jmp     .chain
.nextbucket:
    mov     rax, r13
    not     rax
    or      rbx, rax                ; v |= ~mask
    mov     rdi, rbx
    call    _rev64
    inc     rax
    mov     rdi, rax
    call    _rev64
    mov     rbx, rax                ; v = rev(rev(v)+1)
    test    rbx, rbx
    jz      .emit                   ; wrapped to 0 -> complete
    dec     r14
    jnz     .scanloop
.emit:
    mov     rdi, 2
    call    reply_array_header      ; [cursor, keys]
    mov     rdi, rbx
    lea     rsi, [rel scan_cbuf]
    call    itoa_u                  ; rax = len
    lea     rdi, [rel scan_cbuf]
    mov     rsi, rax
    call    reply_bulk
    mov     rdi, r15
    call    reply_array_header
    xor     r14, r14                ; i = 0
.emitkeys:
    cmp     r14, r15
    jae     .done
    lea     rax, [rel scan_kptr]
    mov     rdi, [rax + r14*8]
    lea     rax, [rel scan_klen]
    mov     rsi, [rax + r14*8]
    call    reply_bulk
    inc     r14
    jmp     .emitkeys
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.badcursor:
    call    emit_invalidcursor
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.syntax:
    call    emit_syntax
    jmp     .done
.wa:
    lea     rdi, [rel lc_scan]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
