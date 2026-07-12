%include "syscalls.inc"
global cmd_sadd, cmd_srem, cmd_sismember, cmd_scard, cmd_smembers
extern argc, argv_ptrs, argv_lens
extern ks_lookup, ks_insert, ks_del
extern hash_new, hash_set, hash_del, hash_exists
extern reply_int, reply_bulk, reply_array_header
extern emit_wrongtype, emit_wrongargs, emit_oom

section .rodata
lc_sadd:      db "sadd"
lc_srem:      db "srem"
lc_sismember: db "sismember"
lc_scard:     db "scard"
lc_smembers:  db "smembers"

section .text
; ---- SADD key member [member ...] -> :added ----
cmd_sadd:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; added counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    xor     r14, r14            ; auto-created = 0
    jmp     .addloop
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_insert
    test    rax, rax
    jz      .oom
    mov     r12, rax            ; entry
    call    hash_new
    test    rax, rax
    jz      .oom_del_key
    mov     rbx, rax            ; header
    mov     [r12+24], rbx       ; entry.val_ptr = header
    mov     qword [r12+40], TYPE_SET
    mov     r14, 1              ; auto-created = 1
.addloop:
    mov     r15, 2              ; arg index
.al_next:
    cmp     r15, [rel argc]
    jae     .done_add
    mov     rdi, rbx            ; header
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]  ; member ptr (field)
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]  ; member len (flen)
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8]  ; value ptr = member ptr (vlen=0, so unused copy)
    xor     r8, r8              ; vlen = 0 (empty value)
    call    hash_set            ; 0 updated / 1 new / 2 oom
    cmp     rax, 2
    je      .add_oom
    cmp     rax, 1
    jne     .not_new
    inc     r13
.not_new:
    inc     r15
    jmp     .al_next
.done_add:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.add_oom:
    cmp     qword [rbx+16], 0   ; any member present?
    jne     .oom
    test    r14, r14            ; auto-created and still empty?
    jz      .oom
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
    jmp     .oom
.oom_del_key:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
.oom:
    call    emit_oom
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_sadd]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SREM key member [member ...] -> :removed ----
cmd_srem:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r13, r13            ; removed counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r15, 2
.rl_next:
    cmp     r15, [rel argc]
    jae     .done_rem
    mov     rdi, rbx
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]
    call    hash_del            ; rax = 1 removed / 0
    add     r13, rax
    inc     r15
    jmp     .rl_next
.done_rem:
    cmp     qword [rbx+16], 0   ; set now empty?
    jne     .reply
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del              ; auto-delete key
.reply:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.zero:
    xor     rdi, rdi
    call    reply_int
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_srem]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SISMEMBER key member -> :0 | :1 ----
cmd_sismember:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rdi, [rax+24]
    mov     rsi, [rel argv_ptrs + 16]
    mov     rdx, [rel argv_lens + 16]
    call    hash_exists
    mov     rdi, rax
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     rdi, rdi
    call    reply_int
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_sismember]
    mov     rsi, 9
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SCARD key -> :count ----
cmd_scard:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rax, [rax+24]       ; header
    mov     rdi, [rax+16]       ; count
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     rdi, rdi
    call    reply_int
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_scard]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SMEMBERS key -> array of members (insertion order) ----
cmd_smembers:
    cmp     qword [rel argc], 2
    jne     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .empty
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     rdi, [rbx+16]       ; count
    call    reply_array_header
    mov     r12, [rbx]          ; node = head
.walk:
    test    r12, r12
    je      .ret
    mov     rdi, [r12+8]        ; member (field_ptr)
    mov     rsi, [r12+16]       ; field_len
    mov     r14, [r12]          ; save next
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.empty:
    xor     rdi, rdi
    call    reply_array_header  ; *0
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_smembers]
    mov     rsi, 8
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
