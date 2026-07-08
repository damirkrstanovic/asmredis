%include "syscalls.inc"
global net_serve
extern parse_one, dispatch
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
    push    r15
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

.client_loop:
    mov     rax, SYS_read
    mov     rdi, r13
    lea     rsi, [rel read_buf]
    mov     rdx, READ_BUF_SIZE
    syscall
    test    rax, rax
    jle     .client_done         ; EOF or error
    mov     r15, rax             ; bytes read

    mov     qword [rel out_len], 0
    lea     rdi, [rel read_buf]
    mov     rsi, r15
    call    parse_one
    test    rax, rax
    jnz     .client_done         ; NEED_MORE / PROTOERR: close (Task 5 hardens)

    call    dispatch

    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    syscall
    jmp     .client_loop

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
