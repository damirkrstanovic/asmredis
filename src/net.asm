%include "syscalls.inc"
global net_serve
extern parse_one, dispatch, emit_protoerr
extern read_buf, out_buf, out_len

section .rodata
err_bind:     db "bind failed", 10
err_bind_len: equ $ - err_bind

section .bss
sockaddr:  resb 16           ; struct sockaddr_in

section .text
; rdi = port number (host order)
net_serve:
    push    r12
    push    r13
    push    r14
    ; 3 pushes keep rsp 16-aligned at the call sites below (SysV ABI).
    ; r15 is used only as within-iteration scratch and never needs saving.
    mov     r14w, di             ; save port (16-bit)

    ; socket(AF_INET, SOCK_STREAM, 0)
    mov     rax, SYS_socket
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .fail
    mov     r12, rax             ; listen fd

    ; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &1, 4)
    mov     dword [rsp-8], 1
    mov     rax, SYS_setsockopt
    mov     rdi, r12
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [rsp-8]
    mov     r8, 4
    syscall

    ; build sockaddr_in
    lea     rdi, [rel sockaddr]
    xor     rax, rax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     word [rdi], AF_INET
    mov     ax, r14w
    xchg    al, ah               ; htons
    mov     [rdi+2], ax

    ; bind(fd, &sockaddr, 16)
    mov     rax, SYS_bind
    mov     rdi, r12
    lea     rsi, [rel sockaddr]
    mov     rdx, 16
    syscall
    test    rax, rax
    js      .fail

    ; listen(fd, 128)
    mov     rax, SYS_listen
    mov     rdi, r12
    mov     rsi, 128
    syscall
    test    rax, rax
    js      .fail

.accept_loop:
    mov     rax, SYS_accept
    mov     rdi, r12
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .accept_loop
    mov     r13, rax             ; conn fd
    xor     r14, r14             ; r14 = rb_used (bytes buffered in read_buf)

; ---- read more into read_buf at offset rb_used, then drain ----
; Register roles for the whole connection loop (all survive parse_one/dispatch,
; both of which preserve rbx and r12-r15):
;   r12 = listen fd   r13 = conn fd   r14 = rb_used   r15 = consumed (scratch)
.client_loop:
    mov     rdx, READ_BUF_SIZE
    sub     rdx, r14             ; space = READ_BUF_SIZE - rb_used
    jle     .client_done         ; buffer full without a complete command -> give up
    mov     rax, SYS_read
    mov     rdi, r13
    lea     rsi, [rel read_buf]
    add     rsi, r14             ; read into read_buf + rb_used (APPEND, don't overwrite)
    syscall                      ; rdx already = space
    test    rax, rax
    jle     .client_done         ; 0=peer closed, <0=error
    add     r14, rax             ; rb_used += n
    mov     qword [rel out_len], 0

; Drain every COMPLETE command currently buffered, batching replies. After each
; consumed command the remaining bytes are compacted to the front of read_buf so
; parse_one always starts at read_buf.
.drain:
    lea     rdi, [rel read_buf]
    mov     rsi, r14             ; rb_used
    call    parse_one            ; rax=status, rdx=consumed
    test    rax, rax
    jz      .ok
    cmp     rax, 1
    je      .need_more
    ; PROTOERR: flush any pending replies + the error, then CLOSE.
    call    emit_protoerr        ; appends "-ERR Protocol error\r\n"
    mov     rdx, [rel out_len]
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    syscall
    jmp     .client_done

.need_more:
    ; Partial command: keep the buffered bytes, flush replies, read more.
    mov     rdx, [rel out_len]
    test    rdx, rdx
    jz      .client_loop
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    syscall
    mov     qword [rel out_len], 0
    jmp     .client_loop

.ok:
    mov     r15, rdx             ; save consumed across dispatch (r15 preserved)
    call    dispatch             ; appends this command's reply to out_buf
    sub     r14, r15             ; rb_used -= consumed
    jnz     .compact
    ; Buffer drained: flush replies (if any) and read again.
    mov     rdx, [rel out_len]
    test    rdx, rdx
    jz      .client_loop
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    syscall
    mov     qword [rel out_len], 0
    jmp     .client_loop

.compact:
    ; memmove(read_buf, read_buf+consumed, rb_used). dest<src -> forward rep movsb.
    lea     rdi, [rel read_buf]  ; dest
    lea     rsi, [rdi + r15]     ; src = read_buf + consumed
    mov     rcx, r14             ; rb_used bytes remaining
    rep     movsb
    ; Overflow guard: flush before out_buf could overflow on the next reply.
    mov     rax, [rel out_len]
    cmp     rax, OUT_FLUSH_HI
    jb      .drain
    mov     rdx, rax
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    syscall
    mov     qword [rel out_len], 0
    jmp     .drain

.client_done:
    mov     rax, SYS_close
    mov     rdi, r13
    syscall
    jmp     .accept_loop

.fail:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_bind]
    mov     rdx, err_bind_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall
