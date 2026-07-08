%include "syscalls.inc"
global ks_get, ks_set, ks_del
extern arena_alloc, memcmp_n, fnv1a
extern buckets

; Hashtable entry layout (40 bytes):
;   [0]=next_ptr  [8]=key_ptr  [16]=key_len  [24]=val_ptr  [32]=val_len

section .text

; _bucket_index(rdi=key, rsi=len) -> rax = &buckets[idx]. Preserves rdi/rsi.
_bucket_index:
    push    rdi
    push    rsi
    sub     rsp, 8                  ; align to 16 for the call
    call    fnv1a                   ; rax=hash (clobbers rcx, r8)
    and     rax, BUCKET_MASK
    lea     rdx, [rel buckets]
    lea     rax, [rdx + rax*8]      ; base then index (RIP-rel can't index)
    add     rsp, 8
    pop     rsi
    pop     rdi
    ret

; _find(rdi=key, rsi=len) -> rax = entry ptr or 0
_find:
    push    rbx
    push    r12
    push    r13                     ; 3 pushes -> rsp%16==0 at internal calls
    mov     r12, rdi                ; search key ptr
    mov     r13, rsi                ; search key len
    call    _bucket_index           ; rax=&head (rdi/rsi preserved)
    mov     rax, [rax]              ; entry = *head
.walk:
    test    rax, rax
    je      .none
    mov     rcx, [rax+16]           ; entry->key_len
    cmp     rcx, r13
    jne     .next
    mov     rbx, rax                ; save entry across memcmp
    mov     rdi, r12                ; search key
    mov     rsi, [rax+8]            ; stored key
    mov     rdx, r13                ; len
    call    memcmp_n                ; rax=0 if equal
    test    rax, rax
    mov     rax, rbx                ; restore entry (mov preserves flags)
    je      .found
.next:
    mov     rax, [rax]              ; entry = entry->next
    jmp     .walk
.none:
    xor     rax, rax
.found:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ks_get(rdi=key, rsi=len) -> rax=val_ptr (0 miss), rdx=val_len
ks_get:
    sub     rsp, 8                  ; align for call
    call    _find
    add     rsp, 8
    test    rax, rax
    je      .miss
    mov     rdx, [rax+32]           ; val_len
    mov     rax, [rax+24]           ; val_ptr
    ret
.miss:
    xor     rax, rax
    xor     rdx, rdx
    ret

; _copy_arena(rdi=src, rsi=len) -> rax = copied buf, or 0 oom
_copy_arena:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes even -> align for arena_alloc call
    mov     rbx, rdi                ; src
    mov     r12, rsi                ; len
    mov     rdi, rsi                ; size to alloc
    call    arena_alloc             ; rax=dest
    test    rax, rax
    je      .oom
    mov     rdi, rax                ; dest
    mov     rsi, rbx                ; src
    mov     rcx, r12                ; len
    rep     movsb                   ; rax (dest base) untouched by movsb
.oom:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; ks_set(rdi=key, rsi=len, rdx=val, rcx=vlen) -> rax=0 ok, 1 oom
ks_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at internal calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    mov     r14, rdx                ; val
    mov     r15, rcx                ; vlen
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    test    rax, rax
    je      .insert
    ; overwrite existing entry's value (old bytes leak, intentional)
    mov     rbx, rax                ; entry
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena             ; copy new value
    test    rax, rax
    je      .oom
    mov     [rbx+24], rax           ; val_ptr
    mov     [rbx+32], r15           ; val_len
    jmp     .ok
.insert:
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena             ; copy key
    test    rax, rax
    je      .oom
    mov     rbx, rax                ; key copy
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena             ; copy val
    test    rax, rax
    je      .oom
    mov     r14, rax                ; reuse r14 = val copy
    mov     rdi, 40
    call    arena_alloc             ; entry
    test    rax, rax
    je      .oom
    mov     [rax+8], rbx            ; key_ptr
    mov     [rax+16], r13           ; key_len
    mov     [rax+24], r14           ; val_ptr
    mov     [rax+32], r15           ; val_len
    ; prepend: entry->next = *head; *head = entry
    mov     rbx, rax                ; save entry
    mov     rdi, r12
    mov     rsi, r13
    call    _bucket_index           ; rax=&head
    mov     rcx, [rax]              ; old head
    mov     [rbx], rcx              ; entry->next = old head
    mov     [rax], rbx              ; *head = entry
.ok:
    xor     rax, rax
    jmp     .ret
.oom:
    mov     rax, 1
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ks_del(rdi=key, rsi=len) -> rax=1 deleted, 0 absent
; Clean slot scheme: slot = &head; while (*slot){ e=*slot;
;   if key matches: *slot = e->next; return 1; slot = &e->next (= e); }
ks_del:
    push    rbx
    push    r12
    push    r13
    push    r14                     ; 4 pushes even
    sub     rsp, 8                  ; align for internal calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    call    _bucket_index           ; rax=&head
    mov     r14, rax                ; slot = &head
.loop:
    mov     rbx, [r14]              ; entry = *slot
    test    rbx, rbx
    je      .absent
    mov     rcx, [rbx+16]           ; entry->key_len
    cmp     rcx, r13
    jne     .adv
    mov     rdi, r12
    mov     rsi, [rbx+8]            ; stored key
    mov     rdx, r13
    call    memcmp_n
    test    rax, rax
    jne     .adv
    ; match: *slot = entry->next
    mov     rcx, [rbx]              ; entry->next
    mov     [r14], rcx
    mov     rax, 1
    jmp     .ret
.adv:
    mov     r14, rbx                ; slot = &entry->next (next at offset 0)
    jmp     .loop
.absent:
    xor     rax, rax
.ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
