%include "syscalls.inc"
global atoi_port
global itoa_u, memcmp_n, to_upper_buf
global fnv1a
global parse_int

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

; parse_int(rdi=ptr, rsi=len) -> rax=value (signed), rdx=1 valid / 0 invalid.
; string2ll-faithful: base-10, optional leading '-', NO leading zeros (except the
; single "0"), no '+', no spaces, no "-0"; accepts the full [INT64_MIN, INT64_MAX].
; Leaf (no calls).
parse_int:
    test    rsi, rsi
    je      .bad
    xor     r8, r8                  ; neg = 0
    movzx   rcx, byte [rdi]
    cmp     cl, '-'
    jne     .first
    mov     r8, 1                   ; negative
    inc     rdi
    dec     rsi
    je      .bad                    ; "-" alone
.first:
    movzx   rcx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9                  ; unsigned: catches <'0' and >'9'
    ja      .bad
    jne     .accum                  ; first digit 1..9 -> normal accumulate
    ; first digit is '0': only the exact non-negative single "0" is valid
    test    r8, r8
    jnz     .bad                    ; "-0..." invalid
    cmp     rsi, 1
    jne     .bad                    ; "0" followed by more -> leading zero, invalid
    xor     rax, rax                ; value = 0
    mov     rdx, 1
    ret
.accum:
    xor     rax, rax                ; acc = 0 (unsigned magnitude)
    mov     r9, 1844674407370955161 ; floor((2^64-1)/10), multiply-overflow guard
.dloop:
    movzx   rcx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .bad
    cmp     rax, r9
    ja      .bad                    ; acc*10 would overflow u64
    imul    rax, rax, 10
    add     rax, rcx
    jc      .bad                    ; u64 add carry -> overflow
    inc     rdi
    dec     rsi
    jnz     .dloop
    test    r8, r8
    jnz     .neg
    mov     r10, 0x7fffffffffffffff ; non-negative: acc <= 2^63-1
    cmp     rax, r10
    ja      .bad
    mov     rdx, 1
    ret
.neg:
    mov     r10, 0x8000000000000000 ; negative: acc <= 2^63 (2^63 -> INT64_MIN)
    cmp     rax, r10
    ja      .bad
    neg     rax                     ; two's complement; acc=2^63 -> 0x8000... = INT64_MIN
    mov     rdx, 1
    ret
.bad:
    xor     rax, rax
    xor     rdx, rdx
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
