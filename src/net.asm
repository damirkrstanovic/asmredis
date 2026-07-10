%include "syscalls.inc"
global net_serve
global cur_out, cur_cap, cur_len, cur_err
extern parse_one, dispatch, emit_protoerr

section .rodata
err_setup:     db "setup failed", 10
err_setup_len: equ $ - err_setup

section .bss
sockaddr:    resb 16                       ; struct sockaddr_in
read_base:   resq 1                        ; base of per-conn read buffers
outbuf_base: resq 1                        ; base of per-conn output buffer slots
g_epfd:      resq 1                        ; epfd (ep_ctl reads it here; r12 is scratch)
; conn_state record: +0 rb_used +8 out_pos +16 out_len +24 flags +32 out_ptr +40 out_cap
conn_state:  resb MAX_CONNS*CONN_STATE_SZ
ev_scratch:  resb 16                       ; scratch epoll_event for epoll_ctl
events:      resb MAX_EVENTS*EV_SIZE       ; epoll_wait output (12-byte stride!)
; current-reply build state (one command at a time; single-threaded).
cur_out:     resq 1                        ; base ptr of the current conn's output buffer
cur_cap:     resq 1                        ; its capacity
cur_len:     resq 1                        ; bytes built so far
cur_err:     resq 1                        ; set if a reply overflowed the buffer

section .text
; ============================================================================
; net_serve(rdi = port, host order) — non-blocking epoll event loop. No return.
;   r12 = epfd  r13 = listen fd  r14 = i  r15 = n  rbx = fd  rbp = event mask
; ============================================================================
net_serve:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    push    rbp                          ; 6 pushes: entry ==8 -> ==8
    sub     rsp, 8                        ; align -> ==0 at every call site
    mov     r15w, di                     ; stash port (16-bit)

    mov     rax, SYS_socket
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM | SOCK_NONBLOCK
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      net_fail
    mov     r13, rax                     ; listen fd

    mov     dword [rsp-8], 1
    mov     rax, SYS_setsockopt
    mov     rdi, r13
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [rsp-8]
    mov     r8, 4
    syscall

    lea     rdi, [rel sockaddr]
    xor     rax, rax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     word [rdi], AF_INET
    mov     ax, r15w
    xchg    al, ah                       ; htons
    mov     [rdi+2], ax

    mov     rax, SYS_bind
    mov     rdi, r13
    lea     rsi, [rel sockaddr]
    mov     rdx, 16
    syscall
    test    rax, rax
    js      net_fail

    mov     rax, SYS_listen
    mov     rdi, r13
    mov     rsi, 128
    syscall
    test    rax, rax
    js      net_fail

    mov     rax, SYS_epoll_create1
    xor     rdi, rdi
    syscall
    test    rax, rax
    js      net_fail
    mov     r12, rax                     ; epfd
    mov     [rel g_epfd], rax

    ; mmap the per-conn regions: read slots (16 KiB) and output base slots.
    mov     rsi, MAX_CONNS*CONN_BUF_SIZE
    call    map_region
    mov     [rel read_base], rax
    mov     rsi, MAX_CONNS*OUTBUF_BASE_SIZE
    call    map_region
    mov     [rel outbuf_base], rax

    mov     rdi, r13
    mov     rsi, EPOLL_CTL_ADD
    mov     rdx, EPOLLIN
    call    ep_ctl

.wait:
    mov     rax, SYS_epoll_wait
    mov     rdi, r12
    lea     rsi, [rel events]
    mov     rdx, MAX_EVENTS
    mov     r10, -1
    syscall
    test    rax, rax
    jle     .wait
    mov     r15, rax                     ; n
    xor     r14, r14                     ; i = 0
.each:
    cmp     r14, r15
    jae     .wait
    lea     rax, [r14 + r14*2]           ; 3*i
    lea     rdx, [rel events]
    mov     ebp, [rdx + rax*4]           ; event mask
    mov     ebx, [rdx + rax*4 + 4]       ; fd
    cmp     ebx, r13d
    je      .ev_accept
    test    ebp, EPOLLIN
    jz      .ev_maybe_write
    mov     edi, ebx
    call    on_readable
    jmp     .ev_hup
.ev_maybe_write:
    test    ebp, EPOLLOUT
    jz      .ev_hup
    mov     edi, ebx
    call    on_writable
.ev_hup:
    test    ebp, (EPOLLHUP | EPOLLERR)
    jz      .next
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    test    qword [rax+24], ST_IN_USE
    jz      .next
    mov     edi, ebx
    call    close_conn
    jmp     .next
.ev_accept:
    call    on_accept
.next:
    inc     r14
    jmp     .each

net_fail:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_setup]
    mov     rdx, err_setup_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; map_region(rsi=size) -> rax = base of an anon region. Fatal on err.
map_region:
    mov     rax, SYS_mmap
    xor     rdi, rdi
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9, r9
    syscall
    cmp     rax, -4095
    jae     net_fail
    ret

; ep_ctl(rdi=fd, rsi=op, rdx=mask): epoll_ctl on [g_epfd]. Preserves callee-saved.
ep_ctl:
    lea     rax, [rel ev_scratch]
    mov     [rax], edx
    mov     [rax+4], edi
    mov     rdx, rdi
    mov     rdi, [rel g_epfd]
    mov     r10, rax
    mov     rax, SYS_epoll_ctl
    syscall
    ret

; on_accept: drain the listener's accept queue (listener in r13).
on_accept:
    push    rbx
.acc:
    mov     rax, SYS_accept4
    mov     rdi, r13
    xor     rsi, rsi
    xor     rdx, rdx
    mov     r10, SOCK_NONBLOCK
    syscall
    test    rax, rax
    js      .done
    cmp     rax, MAX_CONNS
    jb      .ok
    mov     rdi, rax
    mov     rax, SYS_close
    syscall
    jmp     .acc
.ok:
    mov     rbx, rax                     ; newfd
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx                     ; &state
    xor     rcx, rcx
    mov     [rax], rcx                   ; rb_used = 0
    mov     [rax+8], rcx                 ; out_pos = 0
    mov     [rax+16], rcx                ; out_len = 0
    mov     qword [rax+24], ST_IN_USE    ; flags
    ; out_ptr = outbuf_base + fd*OUTBUF_BASE_SIZE ; out_cap = OUTBUF_BASE_SIZE
    mov     rdx, rbx
    shl     rdx, OUTBUF_BASE_SHIFT
    add     rdx, [rel outbuf_base]
    mov     [rax+32], rdx                ; out_ptr
    mov     qword [rax+40], OUTBUF_BASE_SIZE
    mov     rdi, rbx
    mov     rsi, EPOLL_CTL_ADD
    mov     rdx, EPOLLIN
    call    ep_ctl
    jmp     .acc
.done:
    pop     rbx
    ret

; on_readable(edi=fd): read into the read buffer, then drain complete commands.
on_readable:
    push    rbx
    mov     ebx, edi
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     r8, [rax]                    ; rb_used
    mov     rdx, CONN_BUF_SIZE
    sub     rdx, r8                       ; space
    jle     .closeit
    mov     rsi, rbx
    shl     rsi, CONN_BUF_SHIFT
    add     rsi, [rel read_base]
    add     rsi, r8
    mov     rdi, rbx
    mov     rax, SYS_read
    syscall
    test    rax, rax
    jz      .closeit
    js      .maybe_eagain
    lea     rcx, [rel conn_state]
    mov     rdx, rbx
    shl     rdx, CONN_STATE_SHIFT
    add     rcx, rdx
    add     [rcx], rax                   ; rb_used += n
    mov     edi, ebx
    call    drain
    pop     rbx
    ret
.maybe_eagain:
    cmp     rax, -EAGAIN
    je      .ret
.closeit:
    mov     edi, ebx
    call    close_conn
.ret:
    pop     rbx
    ret

; drain(edi=fd): parse+dispatch+send every complete command buffered.
;   rbx = fd, r12 = consumed (both saved).
drain:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
.loop:
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx                     ; &state
    ; set up cur_* from the conn's buffer for this command
    mov     rdx, [rax+32]
    mov     [rel cur_out], rdx           ; cur_out = out_ptr
    mov     rdx, [rax+40]
    mov     [rel cur_cap], rdx           ; cur_cap = out_cap
    mov     qword [rel cur_len], 0
    mov     qword [rel cur_err], 0
    mov     rsi, [rax]                   ; rb_used
    mov     rdi, rbx
    shl     rdi, CONN_BUF_SHIFT
    add     rdi, [rel read_base]         ; rbuf
    call    parse_one                    ; rax=status, rdx=consumed
    cmp     rax, 1
    je      .fin                         ; NEED_MORE
    test    rax, rax
    jz      .ok
    ; PROTOERR: emit into cur_out, send, close
    mov     qword [rel cur_len], 0
    call    emit_protoerr
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rdx, [rel cur_len]
    mov     [rax+16], rdx                ; out_len
    mov     qword [rax+8], 0             ; out_pos = 0
    mov     edi, ebx
    call    _send
    mov     edi, ebx
    call    close_conn
    jmp     .fin
.ok:
    mov     r12, rdx                     ; consumed
    call    dispatch                     ; builds into cur_out (cur_len / cur_err)
    ; rb_used -= consumed
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rdx, [rax]
    sub     rdx, r12
    mov     [rax], rdx
    test    rdx, rdx
    jz      .after_move
    mov     rdi, rbx
    shl     rdi, CONN_BUF_SHIFT
    add     rdi, [rel read_base]
    mov     rsi, rdi
    add     rsi, r12
    mov     rcx, rdx
    rep     movsb
.after_move:
    cmp     qword [rel cur_err], 0
    jne     .err_close                   ; reply overflowed the buffer -> close
    ; persist out_ptr/out_cap/out_len, out_pos = 0, then send
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rdx, [rel cur_out]
    mov     [rax+32], rdx
    mov     rdx, [rel cur_cap]
    mov     [rax+40], rdx
    mov     rdx, [rel cur_len]
    mov     [rax+16], rdx
    mov     qword [rax+8], 0             ; out_pos = 0
    mov     edi, ebx
    call    _send
    test    rax, rax
    jz      .fin                         ; backpressure or closed -> stop
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rax, [rax]                   ; rb_used
    test    rax, rax
    jnz     .loop
    jmp     .fin
.err_close:
    mov     edi, ebx
    call    close_conn
.fin:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; _send(edi=fd) -> rax = 1 fully sent (reset + re-armed) / 0 backpressure or closed.
; Writes from out_ptr[out_pos..out_len]. No stash copy — the buffer is the conn's.
;   rbx = fd, r14 = &state (both saved).
_send:
    push    rbx
    push    r14
    sub     rsp, 8                       ; 2 pushes + 8 -> ==0 at calls
    mov     ebx, edi
    lea     r14, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     r14, rcx                     ; &state
.w:
    mov     r8, [r14+8]                  ; out_pos
    mov     r9, [r14+16]                 ; out_len
    mov     rdx, r9
    sub     rdx, r8                      ; rem
    jz      .full
    mov     rsi, [r14+32]                ; out_ptr
    add     rsi, r8                      ; + out_pos
    mov     rdi, rbx
    mov     rax, SYS_write               ; rdx = rem
    syscall
    test    rax, rax
    js      .werr
    jz      .eagain                      ; write()==0 (shouldn't happen): wait for EPOLLOUT
    add     [r14+8], rax                 ; out_pos += n
    jmp     .w
.full:
    mov     edi, ebx
    call    _reset_outbuf
    test    qword [r14+24], ST_WATCH_OUT
    jz      .full_done
    and     qword [r14+24], ~ST_WATCH_OUT
    mov     edi, ebx
    mov     rsi, EPOLL_CTL_MOD
    mov     rdx, EPOLLIN
    call    ep_ctl
.full_done:
    mov     eax, 1
    jmp     .sret
.werr:
    cmp     rax, -EAGAIN
    je      .eagain
    mov     edi, ebx
    call    close_conn
    xor     eax, eax
    jmp     .sret
.eagain:
    test    qword [r14+24], ST_WATCH_OUT
    jnz     .eagain_done
    or      qword [r14+24], ST_WATCH_OUT
    mov     edi, ebx
    mov     rsi, EPOLL_CTL_MOD
    mov     rdx, EPOLLOUT
    call    ep_ctl
.eagain_done:
    xor     eax, eax
.sret:
    add     rsp, 8
    pop     r14
    pop     rbx
    ret

; _reset_outbuf(edi=fd): reply fully sent — reset the drain cursor/length.
; (Task 1: base slot only; Task 2 adds munmap of an overflow buffer.)
_reset_outbuf:
    lea     rax, [rel conn_state]
    mov     ecx, edi
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     qword [rax+8], 0             ; out_pos = 0
    mov     qword [rax+16], 0            ; out_len = 0
    ret

; on_writable(edi=fd): EPOLLOUT ready — resume the send; on full drain, drain input.
on_writable:
    push    rbx
    mov     ebx, edi
    call    _send
    test    rax, rax
    jz      .done
    mov     edi, ebx
    call    drain
.done:
    pop     rbx
    ret

; close_conn(edi=fd): close the fd and clear its conn_state. Idempotent.
close_conn:
    lea     rax, [rel conn_state]
    mov     ecx, edi
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    test    qword [rax+24], ST_IN_USE
    jz      .done
    mov     r8, rax
    mov     rax, SYS_close
    syscall
    xor     rcx, rcx
    mov     [r8], rcx                    ; rb_used
    mov     [r8+8], rcx                  ; out_pos
    mov     [r8+16], rcx                 ; out_len
    mov     [r8+24], rcx                 ; flags
.done:
    ret
