%include "syscalls.inc"
global atoi_port
global itoa_u, memcmp_n, to_upper_buf
global fnv1a

section .text
; rdi = ptr to NUL-terminated decimal string -> rax = value
atoi_port:
    xor     rax, rax
.loop:
    movzx   rcx, byte [rdi]
    test    rcx, rcx
    je      .done
    cmp     rcx, '0'
    jb      .done
    cmp     rcx, '9'
    ja      .done
    imul    rax, rax, 10
    sub     rcx, '0'
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret

; itoa_u: rdi=unsigned value, rsi=out buffer (>=20 bytes) -> rax=length,
;         buffer filled (no NUL). Writes digits from the end of a 20-byte
;         window, then compacts them to the front of the output buffer.
itoa_u:
    mov     rax, rdi
    mov     rcx, 10
    lea     r8, [rsi+20]         ; one past the digit window
    mov     r9, r8               ; remember window end
.div:
    xor     rdx, rdx
    div     rcx
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    test    rax, rax
    jnz     .div
    mov     rcx, r9
    sub     rcx, r8              ; length in rcx
    mov     rax, rcx             ; return value = length
    mov     rdi, rsi             ; dest = out buffer front
    mov     rsi, r8              ; src  = first digit
    rep     movsb
    ret

; memcmp_n: rdi=a, rsi=b, rdx=n -> rax=0 if equal, 1 if differ
memcmp_n:
    test    rdx, rdx
    je      .eq
.loop:
    mov     cl, [rdi]
    cmp     cl, [rsi]
    jne     .ne
    inc     rdi
    inc     rsi
    dec     rdx
    jnz     .loop
.eq:
    xor     rax, rax
    ret
.ne:
    mov     rax, 1
    ret

; to_upper_buf: rdi=ptr, rsi=len -> uppercase a-z in place
to_upper_buf:
    test    rsi, rsi
    je      .done
.loop:
    mov     al, [rdi]
    cmp     al, 'a'
    jb      .skip
    cmp     al, 'z'
    ja      .skip
    sub     al, 32
    mov     [rdi], al
.skip:
    inc     rdi
    dec     rsi
    jnz     .loop
.done:
    ret

; fnv1a: rdi=ptr, rsi=len -> rax=64-bit FNV-1a hash. Clobbers rcx, r8.
fnv1a:
    mov     rax, 0xcbf29ce484222325
    mov     r8, 0x100000001b3
    test    rsi, rsi
    je      .done
.loop:
    movzx   rcx, byte [rdi]
    xor     rax, rcx
    imul    rax, r8
    inc     rdi
    dec     rsi
    jnz     .loop
.done:
    ret
