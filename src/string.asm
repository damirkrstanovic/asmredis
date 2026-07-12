%include "syscalls.inc"
global cmd_set
global cmd_setnx, cmd_getset, cmd_append, cmd_strlen, cmd_mset, cmd_mget
extern argc, argv_ptrs, argv_lens
extern ks_set, ks_lookup
extern parse_int, reply_simple, reply_null
extern to_upper_buf, memcmp_n
extern emit_oom, emit_wrongargs, emit_notint, emit_invalid_expire, emit_syntax
extern g_now_ms
extern mem_alloc, mem_free
extern reply_bulk, reply_int, reply_array_header
extern emit_wrongtype

section .rodata
s_ok:      db "OK"
s_ok_len   equ $ - s_ok
lc_set:    db "set"
lc_setnx:  db "setnx"
lc_getset: db "getset"
lc_append: db "append"
lc_strlen: db "strlen"
lc_mset:   db "mset"
lc_mget:   db "mget"
o_ex:      db "EX"
o_px:      db "PX"
o_exat:    db "EXAT"
o_pxat:    db "PXAT"
o_keepttl: db "KEEPTTL"
o_nx:      db "NX"
o_xx:      db "XX"

section .bss
optbuf:    resb 8              ; uppercased option token (max "KEEPTTL"=7)

section .text
; cmd_set: SET key value [EX s|PX ms|EXAT s|PXAT ms|KEEPTTL] [NX|XX]
cmd_set:
    cmp     qword [rel argc], 3
    jb      .wa
    ja      .opts
    ; ---- fast path: SET key value ----
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8                  ; keepttl = 0
    call    ks_set
    test    rax, rax
    jnz     .oom1
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    add     rsp, 8
    ret
.oom1:
    call    emit_oom
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

    ; ---- options path (argc > 3). r12=expmode r13=valueidx r14=cond r15=i rbx=deadline ----
.opts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    xor     r12, r12                ; expire mode: 0 none,1 EX,2 PX,3 EXAT,4 PXAT,5 KEEPTTL
    xor     r13, r13                ; expire value arg index
    xor     r14, r14                ; cond: 0 none,1 NX,2 XX
    mov     r15, 3                  ; i = 3
.ploop:
    cmp     r15, [rel argc]
    jae     .parsed
    lea     rax, [rel argv_lens]
    mov     rbx, [rax + r15*8]      ; token len
    cmp     rbx, 7
    ja      .syntax
    ; copy token -> optbuf, then uppercase
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]      ; token ptr
    lea     rsi, [rel optbuf]
    mov     rcx, rbx                ; len
.cpy:
    test    rcx, rcx
    jz      .cpydone
    mov     al, [rdi]
    mov     [rsi], al
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .cpy
.cpydone:
    lea     rdi, [rel optbuf]
    mov     rsi, rbx
    call    to_upper_buf
    cmp     rbx, 2
    je      .len2
    cmp     rbx, 4
    je      .len4
    cmp     rbx, 7
    je      .len7
    jmp     .syntax
.len2:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_ex]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_ex
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_px]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_px
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_nx]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_nx
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_xx]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_xx
    jmp     .syntax
.len4:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_exat]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      .set_exat
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_pxat]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      .set_pxat
    jmp     .syntax
.len7:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_keepttl]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      .set_keepttl
    jmp     .syntax
.set_ex:
    mov     rcx, 1
    jmp     .expmode
.set_px:
    mov     rcx, 2
    jmp     .expmode
.set_exat:
    mov     rcx, 3
    jmp     .expmode
.set_pxat:
    mov     rcx, 4
.expmode:
    test    r12, r12
    jnz     .syntax                 ; a mode already set
    mov     r12, rcx
    inc     r15                     ; consume the value token
    cmp     r15, [rel argc]
    jae     .syntax                 ; missing value
    mov     r13, r15                ; value arg index
    inc     r15
    jmp     .ploop
.set_keepttl:
    test    r12, r12
    jnz     .syntax
    mov     r12, 5
    inc     r15
    jmp     .ploop
.set_nx:
    test    r14, r14
    jnz     .syntax
    mov     r14, 1
    inc     r15
    jmp     .ploop
.set_xx:
    test    r14, r14
    jnz     .syntax
    mov     r14, 2
    inc     r15
    jmp     .ploop
.parsed:
    xor     rbx, rbx                ; deadline = 0
    test    r12, r12
    jz      .cond                   ; no expire mode
    cmp     r12, 5
    je      .cond                   ; KEEPTTL -> no deadline compute
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r13*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + r13*8]
    call    parse_int               ; rax=value, rdx=valid
    test    rdx, rdx
    jz      .notint
    test    rax, rax
    jle     .invalid                ; value <= 0 -> invalid expire time
    mov     rbx, rax                ; value
    cmp     r12, 2
    je      .add_now                ; PX (ms relative)
    cmp     r12, 4
    je      .deadline_done          ; PXAT (ms absolute)
    ; seconds: EX(1) relative, EXAT(3) absolute
    mov     rax, 9223372036854775   ; LLONG_MAX/1000
    cmp     rbx, rax
    jg      .invalid
    imul    rbx, rbx, 1000
    cmp     r12, 1
    je      .add_now                ; EX
    jmp     .deadline_done          ; EXAT (absolute)
.add_now:
    mov     rax, 0x7fffffffffffffff
    sub     rax, [rel g_now_ms]
    cmp     rbx, rax
    jg      .invalid
    add     rbx, [rel g_now_ms]
.deadline_done:
    ; rbx = absolute ms deadline
.cond:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup               ; rax=entry|0 (passively expires)
    test    r14, r14
    jz      .dostore
    cmp     r14, 1
    je      .nx
    test    rax, rax                ; XX: require present
    jz      .nilreply
    jmp     .dostore
.nx:
    test    rax, rax                ; NX: require absent
    jnz     .nilreply
.dostore:
    xor     r8, r8
    cmp     r12, 5
    jne     .kt0
    mov     r8, 1                   ; KEEPTTL -> keep TTL
.kt0:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    call    ks_set                  ; r8 = keepttl
    test    rax, rax
    jnz     .oom2
    test    r12, r12                ; timed set? (mode 1..4)
    jz      .ok
    cmp     r12, 5
    je      .ok
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup               ; entry just stored (not expired)
    mov     [rax+48], rbx           ; expire_ms = deadline
.ok:
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    jmp     .oret
.nilreply:
    call    reply_null              ; $-1
    jmp     .oret
.notint:
    call    emit_notint
    jmp     .oret
.invalid:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
    call    emit_invalid_expire
    jmp     .oret
.syntax:
    call    emit_syntax
    jmp     .oret
.oom2:
    call    emit_oom
.oret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- SETNX key value -> :1 set / :0 exists ----
cmd_setnx:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jnz     .exists
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    mov     rdi, 1
    call    reply_int
    add     rsp, 8
    ret
.exists:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.oom:
    call    emit_oom
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_setnx]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- GETSET key value -> old value | nil ----
cmd_getset:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .oldnil
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]           ; old val (copied into output before ks_set frees it)
    mov     rsi, [rax+32]
    call    reply_bulk
    jmp     .store
.oldnil:
    call    reply_null
.store:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set                  ; keepttl=0; OOM keeps old value (reply already old)
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_getset]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- APPEND key value -> :new_length ----  rbx=entry r12=newbuf r13=newlen
cmd_append:
    cmp     qword [rel argc], 3
    jne     .wa
    push    rbx
    push    r12
    push    r13                     ; 3 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rbx, rax                ; entry
    mov     r13, [rbx+32]           ; oldlen
    add     r13, [rel argv_lens + 16] ; + vallen = newlen
    mov     rdi, r13
    call    mem_alloc
    test    rax, rax
    jz      .oom
    mov     r12, rax                ; newbuf
    mov     rdi, r12                ; copy old bytes
    mov     rsi, [rbx+24]
    mov     rcx, [rbx+32]
    rep     movsb                   ; rdi now at newbuf+oldlen
    mov     rsi, [rel argv_ptrs + 16] ; copy appended bytes
    mov     rcx, [rel argv_lens + 16]
    rep     movsb
    mov     rdi, [rbx+24]           ; free old value
    mov     rsi, [rbx+32]
    call    mem_free
    mov     [rbx+24], r12           ; val_ptr = newbuf
    mov     [rbx+32], r13           ; val_len = newlen  ([48] TTL untouched)
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    mov     rdi, [rel argv_lens + 16] ; new length = value length
    call    reply_int
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
    jmp     .ret
.oom:
    call    emit_oom
.ret:
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_append]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- STRLEN key -> :len ----
cmd_strlen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+32]
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_strlen]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- MSET key value [key value ...] -> +OK ----  rbx=index
cmd_mset:
    mov     rax, [rel argc]
    cmp     rax, 3
    jb      .wa
    test    rax, 1                  ; even argc -> incomplete pair
    jz      .wa
    push    rbx                     ; 1 push -> rsp%16==0
    mov     rbx, 1
.next:
    cmp     rbx, [rel argc]
    jae     .done
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    lea     rax, [rel argv_ptrs]
    mov     rdx, [rax + rbx*8 + 8]
    lea     rax, [rel argv_lens]
    mov     rcx, [rax + rbx*8 + 8]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    add     rbx, 2
    jmp     .next
.done:
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    pop     rbx
    ret
.oom:
    call    emit_oom
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_mset]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- MGET key [key ...] -> array (nil for missing/wrong-type) ----  rbx=index
cmd_mget:
    cmp     qword [rel argc], 2
    jb      .wa
    push    rbx                     ; 1 push -> rsp%16==0
    mov     rbx, [rel argc]
    dec     rbx
    mov     rdi, rbx
    call    reply_array_header
    mov     rbx, 1
.next:
    cmp     rbx, [rel argc]
    jae     .done
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    call    ks_lookup
    test    rax, rax
    jz      .nil
    cmp     qword [rax+40], TYPE_STR
    jne     .nil
    mov     rdi, [rax+24]
    mov     rsi, [rax+32]
    call    reply_bulk
    jmp     .adv
.nil:
    call    reply_null
.adv:
    inc     rbx
    jmp     .next
.done:
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_mget]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
