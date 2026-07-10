%include "syscalls.inc"
global hash_new, hash_set, hash_get, hash_del, hash_exists, hash_free
global cmd_hset, cmd_hget, cmd_hdel, cmd_hgetall, cmd_hlen
global cmd_hexists, cmd_hkeys, cmd_hvals
extern mem_alloc, mem_free, mem_dup, memcmp_n
extern ks_lookup, ks_insert, ks_del
extern argc, argv_ptrs, argv_lens
extern reply_bulk, reply_int, reply_null, reply_array_header
extern emit_wrongtype, emit_wrongargs, emit_oom

; header: [0]=head [8]=tail [16]=count            (24 bytes, class 32)
; node:   [0]=next [8]=field_ptr [16]=field_len [24]=val_ptr [32]=val_len (40 bytes, class 64)
%define HHDR_SZ   24
%define HNODE_SZ  40

section .rodata
lc_hset:     db "hset"
lc_hget:     db "hget"
lc_hdel:     db "hdel"
lc_hlen:     db "hlen"
lc_hexists:  db "hexists"
lc_hkeys:    db "hkeys"
lc_hvals:    db "hvals"
lc_hgetall:  db "hgetall"

section .text

; hash_new() -> rax=header or 0 (OOM). Zeroed empty hash.
hash_new:
    sub     rsp, 8              ; align (entry 8 -> 0)
    mov     rdi, HHDR_SZ
    call    mem_alloc
    test    rax, rax
    je      .done
    xor     rcx, rcx
    mov     [rax], rcx          ; head = 0
    mov     [rax+8], rcx        ; tail = 0
    mov     [rax+16], rcx       ; count = 0
.done:
    add     rsp, 8
    ret

; _hfind(rdi=header, rsi=field, rdx=flen) -> rax=node|0. Walks the chain.
; Clobbers rbx,rcx,rdx,rsi,rdi; preserves r12,r13,r14,r15.
_hfind:
    push    rbx
    push    r12
    push    r13                 ; 3 pushes -> rsp%16==0 at call
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    mov     rax, [rdi]          ; node = head
.walk:
    test    rax, rax
    je      .none
    mov     rcx, [rax+16]       ; node->field_len
    cmp     rcx, r13
    jne     .next
    mov     rbx, rax            ; save node across memcmp
    mov     rdi, r12            ; search field
    mov     rsi, [rax+8]        ; stored field
    mov     rdx, r13            ; flen
    call    memcmp_n            ; rax=0 if equal
    test    rax, rax
    mov     rax, rbx            ; restore node (mov preserves flags)
    je      .found
.next:
    mov     rax, [rax]          ; node = node->next
    jmp     .walk
.none:
    xor     rax, rax
.found:
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_get(rdi=header, rsi=field, rdx=flen) -> rax=val_ptr, rdx=val_len; rax=0 miss.
hash_get:
    sub     rsp, 8              ; align (entry 8 -> 0)
    call    _hfind
    add     rsp, 8
    test    rax, rax
    je      .miss
    mov     rdx, [rax+32]       ; val_len
    mov     rax, [rax+24]       ; val_ptr
    ret
.miss:
    xor     rax, rax
    xor     rdx, rdx
    ret

; hash_exists(rdi=header, rsi=field, rdx=flen) -> rax=1/0.
hash_exists:
    sub     rsp, 8
    call    _hfind
    add     rsp, 8
    test    rax, rax
    setne   al
    movzx   rax, al
    ret

; hash_set(rdi=header, rsi=field, rdx=flen, rcx=value, r8=vlen)
;   -> rax: 0 = updated existing, 1 = added new, 2 = OOM (hash unchanged).
hash_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    mov     r14, rcx            ; value
    mov     r15, r8             ; vlen
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    _hfind              ; rax = node | 0
    test    rax, rax
    je      .append
    ; --- field exists: replace value in place (alloc new, free old) ---
    mov     rbx, rax            ; node (header no longer needed)
    mov     rdi, r14            ; new value
    mov     rsi, r15            ; vlen
    call    mem_dup             ; rax = new value copy or 0
    test    rax, rax
    je      .oom
    mov     r12, rax            ; new value copy
    mov     rdi, [rbx+24]       ; old val_ptr
    mov     rsi, [rbx+32]       ; old val_len
    call    mem_free
    mov     [rbx+24], r12       ; val_ptr = new
    mov     [rbx+32], r15       ; val_len = new
    xor     rax, rax            ; 0 = updated
    jmp     .ret
.append:
    mov     rdi, r12            ; field
    mov     rsi, r13            ; flen
    call    mem_dup             ; rax = field copy or 0
    test    rax, rax
    je      .oom
    mov     r12, rax            ; field copy
    mov     rdi, r14            ; value
    mov     rsi, r15            ; vlen
    call    mem_dup             ; rax = value copy or 0
    test    rax, rax
    je      .oom_free_field
    mov     r14, rax            ; value copy
    mov     rdi, HNODE_SZ
    call    mem_alloc           ; rax = node or 0
    test    rax, rax
    je      .oom_free_fv
    mov     [rax+8], r12        ; field_ptr
    mov     [rax+16], r13       ; field_len
    mov     [rax+24], r14       ; val_ptr
    mov     [rax+32], r15       ; val_len
    xor     rcx, rcx
    mov     [rax], rcx          ; next = 0
    mov     rcx, [rbx+8]        ; old tail
    test    rcx, rcx
    je      .empty
    mov     [rcx], rax          ; old_tail->next = node
    jmp     .settail
.empty:
    mov     [rbx], rax          ; head = node
.settail:
    mov     [rbx+8], rax        ; tail = node
    inc     qword [rbx+16]      ; count++
    mov     rax, 1              ; 1 = new field
    jmp     .ret
.oom_free_fv:
    mov     rdi, r14            ; value copy
    mov     rsi, r15
    call    mem_free
.oom_free_field:
    mov     rdi, r12            ; field copy
    mov     rsi, r13
    call    mem_free
.oom:
    mov     rax, 2              ; 2 = oom
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_del(rdi=header, rsi=field, rdx=flen) -> rax=1 removed / 0 absent.
; prev-pointer walk so the tail pointer can be fixed when removing the last node.
hash_del:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    xor     r15, r15            ; prev = 0
    mov     r14, [rbx]          ; node = head
.loop:
    test    r14, r14
    je      .absent
    mov     rcx, [r14+16]       ; field_len
    cmp     rcx, r13
    jne     .adv
    mov     rdi, r12
    mov     rsi, [r14+8]        ; stored field
    mov     rdx, r13
    call    memcmp_n
    test    rax, rax
    jne     .adv
    ; match at r14 (prev=r15): unlink
    mov     rcx, [r14]          ; node->next
    test    r15, r15
    je      .unlink_head
    mov     [r15], rcx          ; prev->next = node->next
    jmp     .fix_tail
.unlink_head:
    mov     [rbx], rcx          ; header->head = node->next
.fix_tail:
    cmp     [rbx+8], r14        ; was node the tail?
    jne     .free_it
    mov     [rbx+8], r15        ; header->tail = prev (0 if none)
.free_it:
    mov     rdi, [r14+8]        ; field_ptr
    mov     rsi, [r14+16]       ; field_len
    call    mem_free
    mov     rdi, [r14+24]       ; val_ptr
    mov     rsi, [r14+32]       ; val_len
    call    mem_free
    mov     rdi, r14            ; node
    mov     rsi, HNODE_SZ
    call    mem_free
    dec     qword [rbx+16]      ; count--
    mov     rax, 1
    jmp     .ret
.adv:
    mov     r15, r14            ; prev = node
    mov     r14, [r14]          ; node = node->next
    jmp     .loop
.absent:
    xor     rax, rax
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_free(rdi=header): free each node's field+value+node, then the header.
hash_free:
    push    rbx
    push    r12
    push    r13                 ; 3 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; node = head
.loop:
    test    r12, r12
    je      .nodes_done
    mov     r13, [r12]          ; next (save before free)
    mov     rdi, [r12+8]        ; field_ptr
    mov     rsi, [r12+16]       ; field_len
    call    mem_free
    mov     rdi, [r12+24]       ; val_ptr
    mov     rsi, [r12+32]       ; val_len
    call    mem_free
    mov     rdi, r12            ; node
    mov     rsi, HNODE_SZ
    call    mem_free
    mov     r12, r13
    jmp     .loop
.nodes_done:
    mov     rdi, rbx            ; header
    mov     rsi, HHDR_SZ
    call    mem_free
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- HSET key f v [f v ...] -> :new_fields ----
cmd_hset:
    mov     rax, [rel argc]
    cmp     rax, 4
    jb      .wa
    test    rax, 1              ; odd argc (incomplete pair) -> arity error
    jnz     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; new-field counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    xor     r14, r14            ; auto-created = 0
    jmp     .setloop
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
    mov     qword [r12+40], TYPE_HASH
    mov     r14, 1              ; auto-created = 1
.setloop:
    mov     r15, 2              ; arg index
.sl_next:
    cmp     r15, [rel argc]
    jae     .done_set
    mov     rdi, rbx            ; header
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]      ; field_ptr
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]      ; field_len
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8 + 8]  ; value_ptr
    lea     rax, [rel argv_lens]
    mov     r8,  [rax + r15*8 + 8]  ; value_len
    call    hash_set            ; 0 updated / 1 new / 2 oom
    cmp     rax, 2
    je      .set_oom
    cmp     rax, 1
    jne     .not_new
    inc     r13
.not_new:
    add     r15, 2
    jmp     .sl_next
.done_set:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.set_oom:
    cmp     qword [rbx+16], 0   ; any field present?
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
    lea     rdi, [rel lc_hset]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HGET key field -> bulk | nil ----
cmd_hget:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rdi, [rax+24]       ; header
    mov     rsi, [rel argv_ptrs + 16]
    mov     rdx, [rel argv_lens + 16]
    call    hash_get            ; rax=val_ptr(0 miss), rdx=val_len
    test    rax, rax
    jz      .miss
    mov     rdi, rax
    mov     rsi, rdx
    call    reply_bulk
    add     rsp, 8
    ret
.miss:
    call    reply_null
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_hget]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HEXISTS key field -> :0 | :1 ----
cmd_hexists:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
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
    lea     rdi, [rel lc_hexists]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HLEN key -> :count ----
cmd_hlen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
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
    lea     rdi, [rel lc_hlen]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HDEL key f [f ...] -> :removed ----
cmd_hdel:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; removed counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r15, 2              ; arg index
.dl_next:
    cmp     r15, [rel argc]
    jae     .done_del
    mov     rdi, rbx
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]  ; field
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]  ; flen
    call    hash_del            ; rax = 1 removed / 0
    add     r13, rax
    inc     r15
    jmp     .dl_next
.done_del:
    cmp     qword [rbx+16], 0   ; hash now empty?
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
    lea     rdi, [rel lc_hdel]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HGETALL / HKEYS / HVALS -> array ----
cmd_hgetall:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     eax, eax            ; mode 0 = getall (field+value)
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hgetall]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_hkeys:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 1              ; mode 1 = keys
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hkeys]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_hvals:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 2              ; mode 2 = vals
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hvals]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _hiter: eax=mode (0 getall, 1 keys, 2 vals). argc checked ==2.
_hiter:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    mov     r15, rax            ; mode
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .empty
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r13, [rbx+16]       ; count
    mov     rax, r13
    test    r15, r15            ; mode 0 (getall) -> 2*count
    jnz     .cnt_ok
    add     rax, rax
.cnt_ok:
    mov     rdi, rax
    call    reply_array_header
    mov     r12, [rbx]          ; node = head
.walk:
    test    r12, r12
    je      .ret
    cmp     r15, 1
    je      .emit_key
    cmp     r15, 2
    je      .emit_val
    ; mode 0: field then value
    mov     rdi, [r12+8]        ; field_ptr
    mov     rsi, [r12+16]       ; field_len
    mov     r14, [r12]          ; save next
    call    reply_bulk
    mov     rdi, [r12+24]       ; val_ptr
    mov     rsi, [r12+32]       ; val_len
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.emit_key:
    mov     rdi, [r12+8]
    mov     rsi, [r12+16]
    mov     r14, [r12]
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.emit_val:
    mov     rdi, [r12+24]
    mov     rsi, [r12+32]
    mov     r14, [r12]
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
