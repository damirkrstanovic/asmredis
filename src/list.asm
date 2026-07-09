%include "syscalls.inc"
global list_new, list_push_head, list_push_tail
global list_pop_head, list_pop_tail, list_free
global cmd_lpush, cmd_rpush, cmd_lpop, cmd_rpop, cmd_llen, cmd_lrange
extern mem_alloc, mem_free, mem_dup
extern ks_lookup, ks_insert, ks_del
extern argc, argv_ptrs, argv_lens
extern reply_bulk, reply_int, reply_null, reply_array_header
extern emit_wrongtype, emit_notint, emit_oom, emit_wrongargs
extern parse_int

; header: [0]=head [8]=tail [16]=length          (24 bytes, class 32)
; node:   [0]=prev [8]=next [16]=str_ptr [24]=str_len  (32 bytes, class 32)
%define HDR_SZ   24
%define NODE_SZ  32

section .rodata
lc_lpush:  db "lpush"
lc_rpush:  db "rpush"
lc_lpop:   db "lpop"
lc_rpop:   db "rpop"
lc_llen:   db "llen"
lc_lrange: db "lrange"

section .text

; list_new() -> rax=header or 0 (OOM). Zeroed empty list.
list_new:
    sub     rsp, 8              ; align (entry 8 -> 0)
    mov     rdi, HDR_SZ
    call    mem_alloc
    test    rax, rax
    je      .done
    xor     rcx, rcx
    mov     [rax], rcx          ; head = 0
    mov     [rax+8], rcx        ; tail = 0
    mov     [rax+16], rcx       ; length = 0
.done:
    add     rsp, 8
    ret

; list_push_head(rdi=header, rsi=str_ptr, rdx=str_len) -> rax=0 ok, 1 oom.
list_push_head:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; str_ptr
    mov     r13, rdx            ; str_len
    mov     rdi, r12
    mov     rsi, r13
    call    mem_dup             ; rax = string copy or 0
    test    rax, rax
    je      .oom
    mov     r14, rax            ; string copy
    mov     rdi, NODE_SZ
    call    mem_alloc           ; rax = node or 0
    test    rax, rax
    je      .oom_free_str
    mov     r15, rax            ; node
    mov     [r15+16], r14       ; str_ptr
    mov     [r15+24], r13       ; str_len
    xor     rcx, rcx
    mov     [r15], rcx          ; prev = 0
    mov     rcx, [rbx]          ; old head
    mov     [r15+8], rcx        ; node->next = old head
    test    rcx, rcx
    je      .empty
    mov     [rcx], r15          ; old_head->prev = node
    jmp     .sethead
.empty:
    mov     [rbx+8], r15        ; tail = node
.sethead:
    mov     [rbx], r15          ; head = node
    inc     qword [rbx+16]      ; length++
    xor     rax, rax
    jmp     .ret
.oom_free_str:
    mov     rdi, r14
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

; list_push_tail(rdi=header, rsi=str_ptr, rdx=str_len) -> rax=0 ok, 1 oom.
list_push_tail:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rdi, r12
    mov     rsi, r13
    call    mem_dup
    test    rax, rax
    je      .oom
    mov     r14, rax
    mov     rdi, NODE_SZ
    call    mem_alloc
    test    rax, rax
    je      .oom_free_str
    mov     r15, rax
    mov     [r15+16], r14       ; str_ptr
    mov     [r15+24], r13       ; str_len
    xor     rcx, rcx
    mov     [r15+8], rcx        ; next = 0
    mov     rcx, [rbx+8]        ; old tail
    mov     [r15], rcx          ; node->prev = old tail
    test    rcx, rcx
    je      .empty
    mov     [rcx+8], r15        ; old_tail->next = node
    jmp     .settail
.empty:
    mov     [rbx], r15          ; head = node
.settail:
    mov     [rbx+8], r15        ; tail = node
    inc     qword [rbx+16]
    xor     rax, rax
    jmp     .ret
.oom_free_str:
    mov     rdi, r14
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

; list_pop_head(rdi=header) -> rax=str_ptr, rdx=str_len (node freed; CALLER owns
; and must free the string). rax=0 if the list was empty.
list_pop_head:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8              ; 4 pushes + 8 -> rsp%16==0 at call
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; head node
    test    r12, r12
    je      .empty
    mov     r13, [r12+16]       ; str_ptr
    mov     r14, [r12+24]       ; str_len
    mov     rcx, [r12+8]        ; node->next
    mov     [rbx], rcx          ; head = next
    test    rcx, rcx
    je      .became_empty
    xor     rax, rax
    mov     [rcx], rax          ; next->prev = 0
    jmp     .unlinked
.became_empty:
    xor     rax, rax
    mov     [rbx+8], rax        ; tail = 0
.unlinked:
    dec     qword [rbx+16]      ; length--
    mov     rdi, r12            ; free node struct only
    mov     rsi, NODE_SZ
    call    mem_free
    mov     rax, r13            ; return str_ptr
    mov     rdx, r14            ; return str_len
    jmp     .ret
.empty:
    xor     rax, rax
    xor     rdx, rdx
.ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; list_pop_tail(rdi=header) -> rax=str_ptr, rdx=str_len (node freed; caller owns
; the string). rax=0 if empty.
list_pop_tail:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, [rbx+8]        ; tail node
    test    r12, r12
    je      .empty
    mov     r13, [r12+16]
    mov     r14, [r12+24]
    mov     rcx, [r12]          ; node->prev
    mov     [rbx+8], rcx        ; tail = prev
    test    rcx, rcx
    je      .became_empty
    xor     rax, rax
    mov     [rcx+8], rax        ; prev->next = 0
    jmp     .unlinked
.became_empty:
    xor     rax, rax
    mov     [rbx], rax          ; head = 0
.unlinked:
    dec     qword [rbx+16]
    mov     rdi, r12
    mov     rsi, NODE_SZ
    call    mem_free
    mov     rax, r13
    mov     rdx, r14
    jmp     .ret
.empty:
    xor     rax, rax
    xor     rdx, rdx
.ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; list_free(rdi=header): free every node's string + node, then the header.
list_free:
    push    rbx
    push    r12
    push    r13
    push    r14                 ; 4 pushes
    sub     rsp, 8              ; -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; node = head
.loop:
    test    r12, r12
    je      .nodes_done
    mov     r13, [r12+8]        ; next (save before free)
    mov     rdi, [r12+16]       ; str_ptr
    mov     rsi, [r12+24]       ; str_len
    call    mem_free
    mov     rdi, r12            ; node
    mov     rsi, NODE_SZ
    call    mem_free
    mov     r12, r13
    jmp     .loop
.nodes_done:
    mov     rdi, rbx            ; header
    mov     rsi, HDR_SZ
    call    mem_free
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- LPUSH / RPUSH key v [v...] -> :newlen ----
cmd_lpush:
    cmp     qword [rel argc], 3
    jb      .wa
    xor     eax, eax                ; dir = head
    jmp     _push_common
.wa:
    lea     rdi, [rel lc_lpush]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_rpush:
    cmp     qword [rel argc], 3
    jb      .wa
    mov     eax, 1                  ; dir = tail
    jmp     _push_common
.wa:
    lea     rdi, [rel lc_rpush]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _push_common: eax=dir (0 head, 1 tail). Arity already checked (>=3).
_push_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r15, rax                ; dir (0=head, 1=tail)
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    xor     r14, r14                ; auto-created = 0
    jmp     .pushloop
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_insert               ; rax = entry or 0
    test    rax, rax
    jz      .oom
    mov     r12, rax                ; entry
    call    list_new                ; rax = header or 0
    test    rax, rax
    jz      .oom_del_key            ; entry created but no list -> undo key
    mov     rbx, rax                ; header
    mov     [r12+24], rbx           ; entry.val_ptr = header
    mov     qword [r12+40], TYPE_LIST
    mov     r14, 1                  ; auto-created = 1
.pushloop:
    mov     r13, 2                  ; arg index
.pl_next:
    cmp     r13, [rel argc]
    jae     .done_push
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r13*8]      ; str_ptr
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r13*8]      ; str_len
    mov     rdi, rbx                ; header
    test    r15, r15
    jnz     .ptail
    call    list_push_head
    jmp     .pushed
.ptail:
    call    list_push_tail
.pushed:
    test    rax, rax
    jnz     .push_oom
    inc     r13
    jmp     .pl_next
.done_push:
    mov     rdi, [rbx+16]           ; length
    call    reply_int
    jmp     .ret
.push_oom:
    cmp     qword [rbx+16], 0       ; anything pushed yet?
    jne     .oom
    test    r14, r14                ; auto-created and still empty?
    jz      .oom
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del                  ; drop the empty auto-created key
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

; ---- LPOP / RPOP key -> bulk | nil ----
cmd_lpop:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     eax, eax                ; dir = head
    jmp     _pop_common
.wa:
    lea     rdi, [rel lc_lpop]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_rpop:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 1                  ; dir = tail
    jmp     _pop_common
.wa:
    lea     rdi, [rel lc_rpop]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _pop_common: eax=dir. Arity already checked (==2).
_pop_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     r15, rax                ; dir
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    mov     rdi, rbx
    test    r15, r15
    jnz     .ptail
    call    list_pop_head
    jmp     .popped
.ptail:
    call    list_pop_tail
.popped:
    test    rax, rax
    jz      .miss                   ; empty (defensive; shouldn't happen)
    mov     r12, rax                ; str_ptr
    mov     r13, rdx                ; str_len
    mov     rdi, r12
    mov     rsi, r13
    call    reply_bulk
    mov     rdi, r12                ; free the popped string (caller owns it)
    mov     rsi, r13
    call    mem_free
    cmp     qword [rbx+16], 0       ; list now empty?
    jne     .ret
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del                  ; auto-delete the key
    jmp     .ret
.miss:
    call    reply_null
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

; ---- LLEN key -> :len ----
cmd_llen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8                  ; align (entry 8 -> 0)
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rax, [rax+24]           ; header
    mov     rdi, [rax+16]           ; length
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
    lea     rdi, [rel lc_llen]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- LRANGE key start stop -> array ----
cmd_lrange:
    cmp     qword [rel argc], 4
    jne     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int               ; rax=val, rdx=ok
    test    rdx, rdx
    jz      .notint
    mov     r12, rax                ; start
    mov     rdi, [rel argv_ptrs + 24]
    mov     rsi, [rel argv_lens + 24]
    call    parse_int
    test    rdx, rdx
    jz      .notint
    mov     r13, rax                ; stop
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .emptyarr
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    mov     r14, [rbx+16]           ; len (>=1 for a live list)
    test    r12, r12                ; normalize start
    jns     .start_ok
    add     r12, r14
    jns     .start_ok
    xor     r12, r12
.start_ok:
    test    r13, r13                ; normalize stop
    jns     .stop_hi
    add     r13, r14
.stop_hi:
    cmp     r13, r14
    jl      .stop_ok
    lea     r13, [r14-1]
.stop_ok:
    cmp     r12, r13                ; start > stop -> empty
    jg      .emptyarr
    cmp     r12, r14                ; start >= len -> empty
    jge     .emptyarr
    mov     rax, r13
    sub     rax, r12
    inc     rax                     ; count = stop-start+1
    mov     r15, rax
    mov     rdi, rax
    call    reply_array_header
    mov     rax, [rbx]              ; node = head
.skip:
    test    r12, r12
    jle     .emit
    mov     rax, [rax+8]            ; node = node->next
    dec     r12
    jmp     .skip
.emit:
    mov     r12, rax                ; node
.emitloop:
    test    r15, r15
    jz      .ret
    mov     rdi, [r12+16]           ; str_ptr
    mov     rsi, [r12+24]           ; str_len
    mov     r13, [r12+8]            ; next (save before reply)
    call    reply_bulk
    mov     r12, r13
    dec     r15
    jmp     .emitloop
.emptyarr:
    xor     rdi, rdi
    call    reply_array_header      ; *0\r\n
    jmp     .ret
.notint:
    call    emit_notint
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
    lea     rdi, [rel lc_lrange]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
