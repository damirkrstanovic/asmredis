%include "syscalls.inc"
global list_new, list_push_head, list_push_tail
global list_pop_head, list_pop_tail, list_free
extern mem_alloc, mem_free, mem_dup

; header: [0]=head [8]=tail [16]=length          (24 bytes, class 32)
; node:   [0]=prev [8]=next [16]=str_ptr [24]=str_len  (32 bytes, class 32)
%define HDR_SZ   24
%define NODE_SZ  32

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
