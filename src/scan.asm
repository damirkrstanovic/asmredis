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
sp_pat:     resq 1                 ; MATCH pattern ptr (0 = none)
sp_patlen:  resq 1
sp_count:   resq 1
sp_table:   resq 1                 ; single-table base (after ks_scan_prep)
sp_mask:    resq 1                 ; its mask

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
    mov     [rel sp_table], rax
    mov     [rel sp_mask], rdx
    ; PASS 1: count matched keys + compute the next cursor
    mov     rdi, rbx                ; start cursor
    xor     rsi, rsi                ; mode 0 = count
    call    _scan_run               ; rax=matched, rdx=next cursor
    mov     r15, rax                ; matched count
    mov     r12, rdx                ; next cursor
    ; emit [ cursor_string, [ keys ] ]
    mov     rdi, 2
    call    reply_array_header
    mov     rdi, r12                ; next cursor
    lea     rsi, [rel scan_cbuf]
    call    itoa_u                  ; rax = len
    lea     rdi, [rel scan_cbuf]
    mov     rsi, rax
    call    reply_bulk
    mov     rdi, r15                ; matched count -> keys array header
    call    reply_array_header
    ; PASS 2: emit the keys (same start cursor -> identical bucket walk)
    mov     rdi, rbx                ; start cursor
    mov     rsi, 1                  ; mode 1 = emit
    call    _scan_run
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

; _scan_run(rdi=start cursor, rsi=mode 0=count/1=emit) -> rax=matched, rdx=next cursor.
; Walks sp_count buckets from the cursor (reverse-binary), matching against sp_pat.
; Mode 0 only counts; mode 1 emits each matched key via reply_bulk. Deterministic:
; the two passes over the same start cursor visit identical buckets/keys.
;   rbx=v r12=mode r13=table r14=mask r15=buckets-left rbp=matched
_scan_run:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp                     ; 6 pushes (entry ==8) -> ==8
    sub     rsp, 8                  ; -> ==0 at calls
    mov     rbx, rdi                ; v
    mov     r12, rsi                ; mode
    mov     r13, [rel sp_table]
    mov     r14, [rel sp_mask]
    mov     r15, [rel sp_count]     ; buckets left
    xor     rbp, rbp                ; matched = 0
.rloop:
    mov     rax, rbx
    and     rax, r14
    mov     rax, [r13 + rax*8]      ; node = bucket head
.rchain:
    test    rax, rax
    jz      .rnext
    push    rax                     ; save node
    cmp     qword [rel sp_pat], 0
    je      .rmatch
    mov     rdi, [rel sp_pat]
    mov     rsi, [rel sp_patlen]
    mov     rdx, [rax+8]            ; key ptr
    mov     rcx, [rax+16]           ; key len
    call    _glob_match             ; leaf
    test    rax, rax
    jz      .rskip
.rmatch:
    inc     rbp                     ; matched++
    test    r12, r12
    jz      .rskip                  ; mode 0 -> count only
    pop     rax                     ; node
    mov     rcx, [rax]              ; next
    push    rcx                     ; save next across reply_bulk
    mov     rdi, [rax+8]
    mov     rsi, [rax+16]
    call    reply_bulk
    pop     rax                     ; rax = next
    jmp     .rchain
.rskip:
    pop     rax                     ; node
    mov     rax, [rax]              ; node = node->next
    jmp     .rchain
.rnext:
    mov     rax, r14
    not     rax
    or      rbx, rax                ; v |= ~mask
    mov     rdi, rbx
    call    _rev64
    inc     rax
    mov     rdi, rax
    call    _rev64
    mov     rbx, rax                ; v = rev(rev(v)+1)
    test    rbx, rbx
    jz      .rdone                  ; wrapped to 0 -> complete
    dec     r15
    jnz     .rloop
.rdone:
    mov     rax, rbp                ; matched count
    mov     rdx, rbx                ; next cursor
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
