%include "syscalls.inc"
global arena_init, mem_alloc, mem_free, table_alloc, table_free

section .bss
arena_next: resq 1
arena_end:  resq 1
; Free-list heads, one per size class: 8,16,32,64,128,256,512,1024,2048,4096,
; 8192,16384 (2^3..2^14 -> 12 classes). Each list is an intrusive LIFO stack:
; the "next" pointer lives in the first 8 bytes of each freed block.
free_lists: resq 12

section .text
; arena_init: mmap ARENA_SIZE anon RW; store base/end; exit(1) on failure.
arena_init:
    mov     rax, SYS_mmap
    xor     rdi, rdi
    mov     rsi, ARENA_SIZE
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9, r9
    syscall
    cmp     rax, -4095          ; mmap error range [-4095,-1]
    jae     .fail
    mov     [rel arena_next], rax
    add     rax, ARENA_SIZE
    mov     [rel arena_end], rax
    ret
.fail:
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; arena_alloc(rdi=size) -> rax=ptr (8-byte aligned) or 0 if exhausted.
; Internal primitive: carves fresh bytes when a size-class list is empty.
arena_alloc:
    add     rdi, 7
    and     rdi, -8
    mov     rax, [rel arena_next]
    mov     rcx, rax
    add     rcx, rdi
    cmp     rcx, [rel arena_end]
    ja      .oom
    mov     [rel arena_next], rcx
    ret
.oom:
    xor     rax, rax
    ret

; _size_class(rdi=size) -> rax=class_size, rdx=index(0..11). Leaf, no calls.
; Rounds size up to the next power of two, clamped to a minimum of 8.
; CALLER CONTRACT: size MUST be <= 16384. Larger sizes yield index >= 12, which
; is out of bounds for free_lists (12 slots) and would corrupt adjacent .bss.
; Callers are safe because the parser caps keys/values at 16384 (READ_BUF_SIZE)
; and entries=40.
; Clobbers rax, rcx, rdx; preserves rbx and everything else.
_size_class:
    cmp     rdi, 8
    jbe     .min                ; size 0..8 -> class 8, index 0
    lea     rax, [rdi-1]        ; round-up trick: highbit(size-1)+1
    bsr     rcx, rax            ; rcx = position of highest set bit of (size-1)
    inc     rcx                 ; exponent of the next power of two
    mov     rax, 1
    shl     rax, cl             ; class_size = 1 << rcx
    mov     rdx, rcx
    sub     rdx, 3              ; index = log2(class_size) - 3
    ret
.min:
    mov     rax, 8
    xor     rdx, rdx
    ret

; mem_alloc(rdi=size) -> rax=ptr or 0 (OOM). Pops the size class's free list if
; non-empty, else carves a class-sized block from the bump arena.
mem_alloc:
    push    rbx                 ; entry rsp%16==8 -> after push == 0 (calls aligned)
    call    _size_class         ; rax=class_size, rdx=index
    lea     rcx, [rel free_lists]
    lea     rcx, [rcx + rdx*8]  ; rcx = &free_lists[index]
    mov     rbx, [rcx]          ; head
    test    rbx, rbx
    jz      .carve
    mov     rax, [rbx]          ; next = *head (stored inside the block)
    mov     [rcx], rax          ; *slot = next
    mov     rax, rbx            ; return the popped block
    pop     rbx
    ret
.carve:
    mov     rdi, rax            ; class_size
    call    arena_alloc         ; rax = ptr or 0
    pop     rbx
    ret

; mem_free(rdi=ptr, rsi=size). Pushes ptr onto its size class's free list.
; O(1), no syscalls. Size MUST match the size the block was allocated with.
mem_free:
    push    rbx
    mov     rbx, rdi            ; ptr (survives _size_class)
    mov     rdi, rsi            ; size -> _size_class arg
    call    _size_class         ; rax=class_size, rdx=index
    lea     rcx, [rel free_lists]
    lea     rcx, [rcx + rdx*8]  ; &free_lists[index]
    mov     rax, [rcx]          ; old head
    mov     [rbx], rax          ; ptr->next = old head
    mov     [rcx], rbx          ; head = ptr
    pop     rbx
    ret

; table_alloc(rdi=nbuckets) -> rax=ptr or 0. mmap nbuckets*8 zeroed bytes (anon
; RW) for a bucket array. Separate from the value arena; can exceed 16384 B.
; Leaf (only a syscall) — no stack-alignment obligation.
table_alloc:
    shl     rdi, 3              ; nbuckets * 8 = byte length
    mov     rsi, rdi            ; length
    mov     rax, SYS_mmap
    xor     rdi, rdi            ; addr = NULL
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1              ; fd
    xor     r9, r9              ; offset
    syscall
    cmp     rax, -4095          ; mmap error range [-4095,-1]
    jae     .fail
    ret
.fail:
    xor     rax, rax
    ret

; table_free(rdi=ptr, rsi=nbuckets). munmap(ptr, nbuckets*8). Leaf.
table_free:
    shl     rsi, 3              ; nbuckets * 8 = byte length
    mov     rax, SYS_munmap
    syscall
    ret
