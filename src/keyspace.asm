%include "syscalls.inc"
global ks_init, ks_set, ks_del, ks_lookup, ks_insert, ks_active_expire
extern mem_alloc, mem_free, memcmp_n, fnv1a
extern table_alloc, table_free
extern list_free, hash_free
extern g_now_ms

; Hashtable entry layout (56 bytes, ENTRY_SZ; allocated in the 64-byte class):
;   [0]=next_ptr  [8]=key_ptr  [16]=key_len  [24]=val_ptr  [32]=val_len  [40]=type
;   [48]=expire_ms (absolute CLOCK_REALTIME ms deadline; 0 = no TTL)
;   type: TYPE_STR(0)=val_ptr/val_len are a string; TYPE_LIST(1)=val_ptr is a list header;
;         TYPE_HASH(2)=val_ptr is a hash header
;
; Incremental (Redis-style) dict. Two tables held as index-[0]/[1] arrays so the
; finish-swap is a field copy. rehashidx = -1 when idle, else the next ht[0]
; bucket to migrate into ht[1]. New keys go to ht[1] during a resize; migration
; only moves ht[0]->ht[1], so every key lives in exactly one table.

section .bss
ht_table:  resq 2      ; bucket-array pointer per table (0 when unused)
ht_size:   resq 2      ; nbuckets (power of two)
ht_mask:   resq 2      ; nbuckets - 1
ht_used:   resq 2      ; live entry count
rehashidx: resq 1      ; -1 idle; else next ht[0] bucket index to migrate
g_expire_cursor: resq 1

section .text

; ks_init: allocate the initial ht[0] (DICT_INITIAL buckets); exit(1) on failure.
; .bss is zeroed, so ht[1] and used[] start at 0; rehashidx MUST be set to -1.
ks_init:
    push    rbx                     ; entry rsp%16==8 -> 0 (call aligned)
    mov     rdi, DICT_INITIAL
    call    table_alloc             ; rax = bucket array or 0
    test    rax, rax
    jz      .fail
    lea     rbx, [rel ht_table]
    mov     [rbx], rax              ; ht_table[0]
    lea     rbx, [rel ht_size]
    mov     qword [rbx], DICT_INITIAL
    lea     rbx, [rel ht_mask]
    mov     qword [rbx], DICT_INITIAL-1
    lea     rbx, [rel rehashidx]
    mov     qword [rbx], -1
    pop     rbx
    ret
.fail:
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; _rehash_step: if a rehash is in flight, migrate one non-empty ht[0] bucket into
; ht[1] (skipping up to REHASH_MAX_EMPTY empty buckets), advance rehashidx, and
; finish+swap when ht[0] is drained. No-op when idle. Clobbers caller-saved regs.
_rehash_step:
    mov     rax, [rel rehashidx]
    test    rax, rax
    js      .done                   ; rehashidx < 0 -> idle
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes (entry 8) -> rsp%16==0 at calls
    mov     r12d, REHASH_MAX_EMPTY  ; empty-skip budget
    lea     r13, [rel ht_table]
    mov     r13, [r13]              ; ht_table[0] base
    lea     r14, [rel ht_size]
    mov     r14, [r14]              ; ht_size[0]
.scan:
    mov     rbx, [rel rehashidx]
    cmp     rbx, r14
    jae     .finish                 ; drained -> finish+swap
    mov     r15, [r13 + rbx*8]      ; head = ht_table[0][rehashidx]
    test    r15, r15
    jnz     .migrate
    inc     rbx
    mov     [rel rehashidx], rbx
    dec     r12
    jnz     .scan
    jmp     .epi                    ; skip budget spent -> resume next op
.migrate:
    ; move every entry in this bucket to ht[1] (recompute each hash)
.mloop:
    test    r15, r15
    je      .mdone
    mov     r12, [r15]              ; next (skip budget dead once migrating)
    mov     rdi, [r15+8]            ; key_ptr
    mov     rsi, [r15+16]           ; key_len
    call    fnv1a                   ; rax = hash
    lea     rcx, [rel ht_mask]
    and     rax, [rcx+8]            ; h & ht_mask[1]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx+8]            ; ht_table[1] base
    lea     rcx, [rcx + rax*8]      ; &ht_table[1][idx1]
    mov     rdx, [rcx]              ; old head1
    mov     [r15], rdx              ; entry->next = old head1
    mov     [rcx], r15              ; head1 = entry
    lea     rdx, [rel ht_used]
    dec     qword [rdx]             ; ht_used[0]--
    inc     qword [rdx+8]           ; ht_used[1]++
    mov     r15, r12                ; entry = next
    jmp     .mloop
.mdone:
    xor     rax, rax
    mov     [r13 + rbx*8], rax      ; ht_table[0][rehashidx] = 0
    inc     rbx
    mov     [rel rehashidx], rbx
    cmp     rbx, r14
    jae     .finish
    jmp     .epi
.finish:
    lea     rax, [rel ht_table]
    mov     rdi, [rax]              ; old ht[0] array
    mov     rsi, r14                ; ht_size[0]
    call    table_free              ; munmap
    lea     rax, [rel ht_table]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx            ; ht_table: [0]=[1], [1]=0
    lea     rax, [rel ht_size]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    lea     rax, [rel ht_mask]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    lea     rax, [rel ht_used]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    mov     qword [rel rehashidx], -1
.epi:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.done:
    ret

; _maybe_expand: if idle and ht_used[0] >= ht_size[0] (load factor 1), start a
; rehash by allocating ht[1] = 2*ht_size[0]. On alloc failure, stay idle (serve
; at LF>1). Guarded so it does nothing while already rehashing.
_maybe_expand:
    mov     rax, [rel rehashidx]
    test    rax, rax
    jns     .done                   ; already rehashing -> nothing
    lea     rcx, [rel ht_used]
    mov     rax, [rcx]              ; ht_used[0]
    lea     rcx, [rel ht_size]
    cmp     rax, [rcx]              ; used[0] >= size[0] ?
    jb      .done
    push    rbx                     ; entry 8 -> 0 (call aligned)
    lea     rcx, [rel ht_size]
    mov     rbx, [rcx]              ; size0
    lea     rdi, [rbx + rbx]        ; 2*size0
    call    table_alloc             ; rax = new array or 0
    test    rax, rax
    jz      .fail_alloc             ; OOM -> skip expansion, stay idle
    lea     rcx, [rel ht_table]
    mov     [rcx+8], rax            ; ht_table[1]
    lea     rcx, [rel ht_size]
    lea     rdx, [rbx + rbx]        ; 2*size0
    mov     [rcx+8], rdx            ; ht_size[1]
    lea     rcx, [rel ht_mask]
    dec     rdx                     ; 2*size0 - 1
    mov     [rcx+8], rdx            ; ht_mask[1]
    lea     rcx, [rel ht_used]
    mov     qword [rcx+8], 0        ; ht_used[1] = 0
    mov     qword [rel rehashidx], 0 ; begin migrating at bucket 0
.fail_alloc:
    pop     rbx
.done:
    ret

; _chain_find(rax=head entry, r12=key, r13=len) -> rax=entry|0. Walks one chain.
; Clobbers rbx,rcx,rdx,rsi,rdi; preserves r12,r13,r14,r15.
_chain_find:
    push    rbx                     ; entry 8 -> 0 (call aligned)
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
    pop     rbx
    ret

; _find(rdi=key, rsi=len) -> rax=entry|0. Hash once; search ht[0], then ht[1]
; while a rehash is in flight.
_find:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; len
    call    fnv1a                   ; rax = hash
    mov     r14, rax                ; save hash
    lea     rcx, [rel ht_mask]
    mov     rax, r14
    and     rax, [rcx]              ; h & ht_mask[0]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx]              ; ht_table[0]
    mov     rax, [rcx + rax*8]      ; head0
    call    _chain_find
    test    rax, rax
    jnz     .done
    mov     rcx, [rel rehashidx]
    test    rcx, rcx
    js      .miss                   ; idle -> only ht[0]
    lea     rcx, [rel ht_mask]
    mov     rax, r14
    and     rax, [rcx+8]            ; h & ht_mask[1]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx+8]            ; ht_table[1]
    mov     rax, [rcx + rax*8]      ; head1
    call    _chain_find
    test    rax, rax
    jnz     .done
.miss:
    xor     rax, rax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; _insert_entry(rdi=entry, rsi=key, rdx=len): prepend entry into ht[1] while
; rehashing else ht[0], at bucket h&mask; bump that table's used count.
_insert_entry:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at call
    mov     rbx, rdi                ; entry
    mov     rdi, rsi                ; key
    mov     rsi, rdx                ; len
    call    fnv1a                   ; rax = hash
    xor     r12, r12                ; t = 0
    mov     rcx, [rel rehashidx]
    test    rcx, rcx
    js      .have_t                 ; idle -> t=0
    mov     r12d, 1                 ; rehashing -> t=1
.have_t:
    lea     rcx, [rel ht_mask]
    and     rax, [rcx + r12*8]      ; h & ht_mask[t]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx + r12*8]      ; ht_table[t]
    lea     rcx, [rcx + rax*8]      ; &ht_table[t][idx]
    mov     rdx, [rcx]              ; old head
    mov     [rbx], rdx              ; entry->next = old head
    mov     [rcx], rbx              ; head = entry
    lea     rcx, [rel ht_used]
    inc     qword [rcx + r12*8]     ; ht_used[t]++
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; _del_in_table(r12=key, r13=len, r14=hash, r15=table index t) -> rax=1 if the
; key was found (unlinked, its 3 blocks freed, ht_used[t]--), else 0.
_del_in_table:
    push    rbx
    push    rbp
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at calls
    mov     rax, r14
    lea     rcx, [rel ht_mask]
    and     rax, [rcx + r15*8]      ; h & ht_mask[t]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx + r15*8]      ; ht_table[t]
    lea     rbp, [rcx + rax*8]      ; slot = &head
.loop:
    mov     rbx, [rbp]              ; entry = *slot
    test    rbx, rbx
    je      .notfound
    mov     rcx, [rbx+16]           ; key_len
    cmp     rcx, r13
    jne     .adv
    mov     rdi, r12
    mov     rsi, [rbx+8]            ; stored key
    mov     rdx, r13
    call    memcmp_n
    test    rax, rax
    jne     .adv
    mov     rcx, [rbx]              ; entry->next
    mov     [rbp], rcx              ; *slot = next
    mov     rdi, rbx                ; entry (free value, type-aware)
    call    _free_value
    mov     rdi, [rbx+8]            ; key_ptr
    mov     rsi, [rbx+16]           ; key_len
    call    mem_free
    mov     rdi, rbx                ; entry block
    mov     rsi, ENTRY_SZ
    call    mem_free
    lea     rcx, [rel ht_used]
    dec     qword [rcx + r15*8]     ; ht_used[t]--
    mov     rax, 1
    jmp     .ret
.adv:
    mov     rbp, rbx                ; slot = &entry->next (next at offset 0)
    jmp     .loop
.notfound:
    xor     rax, rax
.ret:
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret

; _copy_arena(rdi=src, rsi=len) -> rax = copied buf (>= len, class-sized), or 0.
_copy_arena:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes + 8 -> aligned
    mov     rbx, rdi                ; src
    mov     r12, rsi                ; len
    mov     rdi, rsi                ; size to alloc
    call    mem_alloc
    test    rax, rax
    je      .oom
    mov     rdi, rax                ; dest
    mov     rsi, rbx                ; src
    mov     rcx, r12                ; len
    rep     movsb
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
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    mov     r14, rdx                ; val
    mov     r15, rcx                ; vlen
    mov     rbx, r8                 ; stash keepttl (rbx survives _rehash_step/_find)
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    test    rax, rax
    je      .insert
    ; overwrite: alloc new value first, then free old
    mov     r12, rbx                ; keepttl -> r12 (key no longer needed on this path)
    mov     rbx, rax                ; entry
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena
    test    rax, rax
    je      .oom                    ; old value intact
    mov     r14, rax                ; new value block
    mov     rdi, rbx                ; entry (free old value, type-aware)
    call    _free_value
    mov     [rbx+24], r14
    mov     [rbx+32], r15
    mov     qword [rbx+40], TYPE_STR ; now a string
    test    r12, r12                ; keepttl?
    jnz     .ok
    mov     qword [rbx+48], 0       ; SET semantics: clear TTL on successful overwrite
    jmp     .ok
.insert:
    call    _maybe_expand           ; may start a rehash before we route
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
    je      .oom_free_key
    mov     r14, rax                ; val copy
    mov     rdi, ENTRY_SZ
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_keyval
    mov     [rax+8], rbx            ; key_ptr
    mov     [rax+16], r13           ; key_len
    mov     [rax+24], r14           ; val_ptr
    mov     [rax+32], r15           ; val_len
    mov     qword [rax+40], TYPE_STR ; type = string
    mov     qword [rax+48], 0       ; expire_ms = 0 (new key: no TTL)
    mov     rdi, rax                ; entry
    mov     rsi, r12                ; key
    mov     rdx, r13                ; len
    call    _insert_entry           ; prepend into ht[0] or ht[1], used++
.ok:
    xor     rax, rax
    jmp     .ret
.oom_free_keyval:
    mov     rdi, r14
    mov     rsi, r15
    call    mem_free
.oom_free_key:
    mov     rdi, rbx
    mov     rsi, r13
    call    mem_free
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
ks_del:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    fnv1a
    mov     r14, rax                ; hash
    xor     r15, r15                ; t = 0
    call    _del_in_table
    test    rax, rax
    jnz     .deleted
    mov     rax, [rel rehashidx]
    test    rax, rax
    js      .absent                 ; idle -> only ht[0]
    mov     r15d, 1                 ; t = 1
    call    _del_in_table
    test    rax, rax
    jnz     .deleted
.absent:
    xor     rax, rax
    jmp     .ret
.deleted:
    mov     rax, 1
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; _free_value(rdi=entry): free the entry's VALUE only (not entry/key), dispatched
; on type. A null val_ptr (an entry created by ks_insert before its value is
; filled) is a no-op on every branch. Preserves all callee-saved registers.
_free_value:
    push    rbx                     ; entry 8 -> 0 (call aligned)
    mov     rbx, rdi
    mov     rax, [rbx+40]           ; type
    cmp     rax, TYPE_STR
    je      .str
    cmp     rax, TYPE_LIST
    je      .list
    ; TYPE_HASH
    mov     rdi, [rbx+24]           ; hash header
    test    rdi, rdi
    jz      .done
    call    hash_free
    jmp     .done
.str:
    mov     rdi, [rbx+24]           ; val_ptr
    test    rdi, rdi
    jz      .done
    mov     rsi, [rbx+32]           ; val_len
    call    mem_free
    jmp     .done
.list:
    mov     rdi, [rbx+24]           ; list header
    test    rdi, rdi
    jz      .done
    call    list_free
.done:
    pop     rbx
    ret

; ks_lookup(rdi=key, rsi=len) -> rax=entry|0. Rehash-step + find; returns the raw
; entry so callers can inspect [entry+40] type and [entry+24] val_ptr.
ks_lookup:
    push    r12
    push    r13
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at calls
    mov     r12, rdi
    mov     r13, rsi
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    _find                   ; rax = entry | 0 ; r12=key, r13=len
    test    rax, rax
    jz      .ret
    mov     rcx, [rax+48]           ; expire_ms
    test    rcx, rcx
    jz      .ret                    ; no TTL
    cmp     rcx, [rel g_now_ms]
    ja      .ret                    ; deadline > now -> still live
    mov     rdi, r12
    mov     rsi, r13
    call    ks_del                  ; non-recursive; frees the expired key
    xor     rax, rax
.ret:
    add     rsp, 8
    pop     r13
    pop     r12
    ret

; ks_insert(rdi=key, rsi=len) -> rax=entry|0 (OOM). Creates a NEW entry (key
; copied, val_ptr/val_len=0, type=STR), linked into the destination table.
; Caller fills val_ptr/val_len/type. Assumes the key is absent (caller checked
; via ks_lookup).
ks_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    call    _rehash_step
    call    _maybe_expand
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena             ; copy key
    test    rax, rax
    je      .oom
    mov     rbx, rax                ; key copy
    mov     rdi, ENTRY_SZ
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_key
    mov     r14, rax                ; entry
    mov     [r14+8], rbx            ; key_ptr
    mov     [r14+16], r13           ; key_len
    xor     rcx, rcx
    mov     [r14+24], rcx           ; val_ptr = 0
    mov     [r14+32], rcx           ; val_len = 0
    mov     [r14+40], rcx           ; type = TYPE_STR (0)
    mov     [r14+48], rcx           ; expire_ms = 0 (no TTL)
    mov     rdi, r14                ; entry
    mov     rsi, r12                ; key
    mov     rdx, r13                ; len
    call    _insert_entry           ; prepend into ht[t], used++
    mov     rax, r14                ; return entry
    jmp     .ret
.oom_free_key:
    mov     rdi, rbx
    mov     rsi, r13
    call    mem_free
.oom:
    xor     rax, rax
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ks_active_expire(): best-effort reaper. Skips while rehashing (transient). Scans
; EXPIRE_BUCKETS buckets of ht[0] from a persistent cursor, unlinking+freeing entries
; whose expire_ms has passed. Preserves callee-saved. Uses g_now_ms.
;   rbx=slot ptr, r12=entry, r13=buckets-left, r14=mask, r15=table base
ks_active_expire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes -> rsp%16==0 at calls
    mov     rax, [rel rehashidx]
    test    rax, rax
    jns     .aret                       ; rehashing (>=0) -> skip this cycle
    lea     rcx, [rel ht_table]
    mov     r15, [rcx]                  ; ht_table[0]
    test    r15, r15
    jz      .aret                       ; no table
    lea     rcx, [rel ht_mask]
    mov     r14, [rcx]                  ; ht_mask[0]
    mov     r13, EXPIRE_BUCKETS
.bucket:
    test    r13, r13
    jz      .aret
    mov     rax, [rel g_expire_cursor]
    mov     rcx, rax
    and     rcx, r14                    ; b = cursor & mask
    inc     rax
    mov     [rel g_expire_cursor], rax
    lea     rbx, [r15 + rcx*8]          ; slot = &ht_table[0][b]
.chain:
    mov     r12, [rbx]                  ; entry = *slot
    test    r12, r12
    jz      .nextb
    mov     rax, [r12+48]               ; expire_ms
    test    rax, rax
    jz      .keep
    cmp     rax, [rel g_now_ms]
    ja      .keep                       ; deadline > now
    ; expired: unlink and free the three blocks
    mov     rax, [r12]                  ; entry->next
    mov     [rbx], rax                  ; *slot = next
    mov     rdi, r12
    call    _free_value
    mov     rdi, [r12+8]                ; key_ptr
    mov     rsi, [r12+16]               ; key_len
    call    mem_free
    mov     rdi, r12
    mov     rsi, ENTRY_SZ
    call    mem_free
    lea     rcx, [rel ht_used]
    dec     qword [rcx]                 ; ht_used[0]--
    jmp     .chain                      ; re-read *slot (now = old next)
.keep:
    mov     rbx, r12                    ; slot = &entry->next (next at offset 0)
    jmp     .chain
.nextb:
    dec     r13
    jmp     .bucket
.aret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
