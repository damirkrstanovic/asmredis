%include "syscalls.inc"
global net_serve
extern parse_one, dispatch, emit_protoerr
extern out_buf, out_len

section .rodata
err_setup:     db "setup failed", 10
err_setup_len: equ $ - err_setup

section .bss
sockaddr:    resb 16                       ; struct sockaddr_in
read_base:   resq 1                        ; base of per-conn read buffers
write_base:  resq 1                        ; base of per-conn write buffers
g_epfd:      resq 1                        ; epfd (ep_ctl reads it here, r12 is
                                           ; clobbered as scratch by drain/flush)
conn_state:  resb MAX_CONNS*CONN_STATE_SZ  ; +0 rb_used +8 wr_pos +16 wr_len +24 flags
ev_scratch:  resb 16                       ; scratch epoll_event for epoll_ctl
events:      resb MAX_EVENTS*EV_SIZE       ; epoll_wait output (12-byte stride!)

section .text
; ============================================================================
; net_serve(rdi = port, host order) — non-blocking epoll event loop. No return.
; Register roles across the loop (all callee-saved / syscall-safe):
;   r12 = epfd   r13 = listen fd   r14 = i (event index)
;   r15 = n (event count)   rbx = current fd   rbp = current event mask
; ============================================================================
net_serve:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    push    rbp                          ; 6 pushes: entry rsp%16==8 -> ==8
    sub     rsp, 8                        ; align: ==8 -> ==0 at every call site
    mov     r15w, di                     ; stash port (16-bit) in r15 until loop

    ; socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0)
    mov     rax, SYS_socket
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM | SOCK_NONBLOCK
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      net_fail
    mov     r13, rax                     ; listen fd

    ; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &1, 4)  (optval in red zone)
    mov     dword [rsp-8], 1
    mov     rax, SYS_setsockopt
    mov     rdi, r13
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [rsp-8]
    mov     r8, 4
    syscall

    ; build sockaddr_in {family=AF_INET, port=htons(port), addr=0}
    lea     rdi, [rel sockaddr]
    xor     rax, rax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     word [rdi], AF_INET
    mov     ax, r15w
    xchg    al, ah                       ; htons
    mov     [rdi+2], ax

    ; bind(fd, &sockaddr, 16)
    mov     rax, SYS_bind
    mov     rdi, r13
    lea     rsi, [rel sockaddr]
    mov     rdx, 16
    syscall
    test    rax, rax
    js      net_fail

    ; listen(fd, 128)
    mov     rax, SYS_listen
    mov     rdi, r13
    mov     rsi, 128
    syscall
    test    rax, rax
    js      net_fail

    ; epoll_create1(0) -> epfd
    mov     rax, SYS_epoll_create1
    xor     rdi, rdi
    syscall
    test    rax, rax
    js      net_fail
    mov     r12, rax                     ; epfd (loop uses r12 for epoll_wait)
    mov     [rel g_epfd], rax            ; and a stable copy for ep_ctl, since
                                         ; drain/flush_reply clobber r12 as scratch

    ; mmap the per-conn buffer regions (read slots are 16 KiB, write slots are
    ; 32 KiB so a stashed reply can never overflow its slot).
    mov     rsi, MAX_CONNS*CONN_BUF_SIZE
    call    map_region
    mov     [rel read_base], rax
    mov     rsi, MAX_CONNS*WRITE_BUF_SIZE
    call    map_region
    mov     [rel write_base], rax

    ; epoll_ctl(epfd, ADD, listen_fd, {EPOLLIN, fd=listen_fd})
    mov     rdi, r13
    mov     rsi, EPOLL_CTL_ADD
    mov     rdx, EPOLLIN
    call    ep_ctl

; ---- event loop ----
.wait:
    mov     rax, SYS_epoll_wait
    mov     rdi, r12
    lea     rsi, [rel events]
    mov     rdx, MAX_EVENTS
    mov     r10, -1                      ; block forever
    syscall
    test    rax, rax
    jle     .wait                        ; EINTR / error -> retry defensively
    mov     r15, rax                     ; n
    xor     r14, r14                     ; i = 0
.each:
    cmp     r14, r15
    jae     .wait
    ; &events[i] = events + i*12  (i*12 == (3*i)*4)
    lea     rax, [r14 + r14*2]           ; 3*i
    lea     rdx, [rel events]
    mov     ebp, [rdx + rax*4]           ; event mask (u32 @ +0)
    mov     ebx, [rdx + rax*4 + 4]       ; fd        (data.fd @ +4)

    cmp     ebx, r13d                    ; listener?
    je      .ev_accept
    ; Honor EPOLLIN BEFORE EPOLLHUP/EPOLLERR so buffered input is drained
    ; before we tear the connection down on a half-close. EPOLLIN and EPOLLOUT
    ; are never both armed for a conn (interest is toggled, never both).
    test    ebp, EPOLLIN
    jz      .ev_maybe_write
    mov     edi, ebx
    call    on_readable                  ; may close on EOF / proto error
    jmp     .ev_hup
.ev_maybe_write:
    test    ebp, EPOLLOUT
    jz      .ev_hup
    mov     edi, ebx
    call    on_writable                  ; may close on write error
.ev_hup:
    test    ebp, (EPOLLHUP | EPOLLERR)
    jz      .next
    ; Only close if the slot is still in use — on_readable/on_writable may
    ; have already closed it (avoids double-close of a reused fd).
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

; ============================================================================
; net_fail: report and exit(1).
; ============================================================================
net_fail:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_setup]
    mov     rdx, err_setup_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; ============================================================================
; map_region(rsi=size) -> rax = base of an anon region of `size` bytes. Fatal on err.
; Clobbers only caller-saved regs.  rsi = region size in bytes (caller-provided).
; ============================================================================
map_region:
    mov     rax, SYS_mmap
    xor     rdi, rdi                     ; addr = NULL
                                         ; rsi = size (set by caller)
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1                       ; fd
    xor     r9, r9                       ; offset
    syscall
    cmp     rax, -4095
    jae     net_fail                     ; mmap error
    ret

; ============================================================================
; ep_ctl(rdi=fd, rsi=op, rdx=mask): epoll_ctl on epfd with a fresh event.
; Correct kernel ABI: rdi=epfd, rsi=op, rdx=fd, r10=&event.
; epfd is read from [g_epfd] (NOT r12): drain/flush_reply use r12 as scratch,
; so relying on r12 here would pass garbage and fail with EBADF.
; Preserves callee-saved regs.
; ============================================================================
ep_ctl:
    lea     rax, [rel ev_scratch]
    mov     [rax], edx                   ; events @ +0
    mov     [rax+4], edi                 ; data.fd @ +4
    mov     rdx, rdi                     ; fd  -> rdx
    mov     rdi, [rel g_epfd]            ; epfd
    mov     r10, rax                     ; &event
    mov     rax, SYS_epoll_ctl           ; rsi (op) already in place
    syscall
    ret

; ============================================================================
; on_accept: drain the listener's accept queue (listener in r13).
; Preserves the caller's loop regs; uses rbx as scratch (saved) for newfd.
; ============================================================================
on_accept:
    push    rbx                          ; entry rsp%16==8 -> ==0 (calls aligned)
.acc:
    mov     rax, SYS_accept4
    mov     rdi, r13
    xor     rsi, rsi                     ; addr = NULL
    xor     rdx, rdx                     ; addrlen = NULL
    mov     r10, SOCK_NONBLOCK
    syscall
    test    rax, rax
    js      .done                        ; EAGAIN / error -> stop
    cmp     rax, MAX_CONNS
    jb      .ok
    ; fd out of range: close and keep draining
    mov     rdi, rax
    mov     rax, SYS_close
    syscall
    jmp     .acc
.ok:
    mov     rbx, rax                     ; newfd (survives ep_ctl)
    ; zero conn_state[newfd], then set flags = ST_IN_USE
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx                     ; &state
    xor     rcx, rcx
    mov     [rax], rcx                   ; rb_used = 0
    mov     [rax+8], rcx                 ; wr_pos  = 0
    mov     [rax+16], rcx                ; wr_len  = 0
    mov     qword [rax+24], ST_IN_USE    ; flags
    ; register newfd for EPOLLIN
    mov     rdi, rbx
    mov     rsi, EPOLL_CTL_ADD
    mov     rdx, EPOLLIN
    call    ep_ctl
    jmp     .acc
.done:
    pop     rbx
    ret

; ============================================================================
; on_readable(edi = fd): read available bytes into the conn's read buffer,
; then drain complete commands. Preserves caller regs (uses rbx, saved).
; ============================================================================
on_readable:
    push    rbx                          ; entry rsp%16==8 -> ==0
    mov     ebx, edi                     ; fd
    ; &state
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     r8, [rax]                    ; rb_used
    mov     rdx, CONN_BUF_SIZE
    sub     rdx, r8                      ; space = CONN_BUF_SIZE - rb_used
    jle     .closeit                     ; buffer full -> drop conn
    ; rbuf + rb_used
    mov     rsi, rbx
    shl     rsi, CONN_BUF_SHIFT
    add     rsi, [rel read_base]
    add     rsi, r8
    mov     rdi, rbx                     ; fd
    mov     rax, SYS_read                ; rdx = space
    syscall
    test    rax, rax
    jz      .closeit                     ; 0 = peer closed
    js      .maybe_eagain
    ; rb_used += n
    lea     rcx, [rel conn_state]
    mov     rdx, rbx
    shl     rdx, CONN_STATE_SHIFT
    add     rcx, rdx
    add     [rcx], rax
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

; ============================================================================
; drain(edi = fd): parse+dispatch+flush every complete command buffered.
;   rbx = fd (saved), r12 = consumed scratch (saved).
; ============================================================================
drain:
    push    rbx
    push    r12                          ; 2 pushes: ==8 -> ==8
    sub     rsp, 8                        ; align -> ==0
    mov     ebx, edi                     ; fd
.loop:
    ; reload rb_used and rbuf from conn_state (they change as we consume)
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rsi, [rax]                   ; rb_used
    mov     rdi, rbx
    shl     rdi, CONN_BUF_SHIFT
    add     rdi, [rel read_base]         ; rbuf
    mov     qword [rel out_len], 0
    call    parse_one                    ; rax=status, rdx=consumed
    cmp     rax, 1
    je      .fin                         ; NEED_MORE: partial stays at front
    test    rax, rax
    jz      .ok
    ; PROTOERR: emit error, flush, close
    mov     qword [rel out_len], 0
    call    emit_protoerr
    mov     edi, ebx
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    call    flush_reply
    mov     edi, ebx
    call    close_conn
    jmp     .fin
.ok:
    mov     r12, rdx                     ; consumed (survives dispatch)
    call    dispatch                     ; reply -> out_buf/out_len
    ; rb_used -= consumed
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rdx, [rax]
    sub     rdx, r12
    mov     [rax], rdx                   ; store new rb_used
    test    rdx, rdx
    jz      .after_move
    ; memmove(rbuf, rbuf+consumed, rb_used); dest<src -> forward rep movsb
    mov     rdi, rbx
    shl     rdi, CONN_BUF_SHIFT
    add     rdi, [rel read_base]         ; dest = rbuf
    mov     rsi, rdi
    add     rsi, r12                     ; src = rbuf + consumed
    mov     rcx, rdx                     ; count = rb_used
    rep     movsb
.after_move:
    mov     edi, ebx
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    call    flush_reply
    test    rax, rax
    jz      .fin                         ; backpressure (never in Task 1)
    ; loop while more bytes remain
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     rax, [rax]                   ; rb_used
    test    rax, rax
    jnz     .loop
.fin:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; ============================================================================
; flush_reply(edi=fd, rsi=buf, rdx=len) -> rax = 1 fully written / 0 back-
; pressure engaged (or conn closed on error). Non-blocking: on EAGAIN it
; stashes the unwritten tail into write_base[fd], records wr_pos/wr_len, sets
; ST_WATCH_OUT and MODs the epoll interest to EPOLLOUT (dropping EPOLLIN so the
; loop never busy-spins). `len` is a single reply (max ~16423 bytes), which fits
; the WRITE_BUF_SIZE (32 KiB) slot with margin, so the stash never overflows.
;   rbx = fd, r12 = cursor (buf+written), r13 = remaining (all saved).
; ============================================================================
flush_reply:
    push    rbx
    push    r12
    push    r13                          ; 3 pushes: ==8 -> ==0 (calls aligned)
    mov     ebx, edi                     ; fd
    mov     r12, rsi                     ; cursor = buf + written
    mov     r13, rdx                     ; remaining = len - written
    test    r13, r13
    jz      .ok1
.w:
    mov     rax, SYS_write
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    test    rax, rax
    js      .werr
    add     r12, rax                     ; cursor  += n
    sub     r13, rax                     ; remaining -= n
    jnz     .w                           ; short write -> keep going
.ok1:
    mov     eax, 1                        ; fully sent
    jmp     .fret
.werr:
    cmp     rax, -EAGAIN
    je      .eagain
    ; other error (EPIPE / ECONNRESET / ...): tear the conn down
    mov     edi, ebx
    call    close_conn
    xor     eax, eax
    jmp     .fret
.eagain:
    ; stash unwritten tail: memcpy(write_base[fd] + 0, cursor, remaining)
    mov     rdi, rbx
    shl     rdi, WRITE_BUF_SHIFT         ; write slots are WRITE_BUF_SIZE (32 KiB)
    add     rdi, [rel write_base]        ; dest = write buffer for fd
    mov     rsi, r12                     ; src  = unwritten tail
    mov     rcx, r13                     ; count = remaining (<= max reply < WRITE_BUF_SIZE)
    rep     movsb
    ; conn_state[fd]: wr_pos=0, wr_len=remaining, flags |= ST_WATCH_OUT
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     qword [rax+8], 0             ; wr_pos = 0
    mov     [rax+16], r13               ; wr_len = remaining
    or      qword [rax+24], ST_WATCH_OUT
    ; watch writes only (drop EPOLLIN) so we don't spin on a full send buffer
    mov     edi, ebx
    mov     rsi, EPOLL_CTL_MOD
    mov     rdx, EPOLLOUT
    call    ep_ctl
    xor     eax, eax                     ; backpressure engaged
.fret:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; on_writable(edi = fd): EPOLLOUT is ready — resume flushing the stashed tail
; from write_base[fd] starting at wr_pos. On full drain, clear wr state, MOD
; interest back to EPOLLIN, and drain() any input buffered while we were
; blocked. On EAGAIN just return (wait for the next EPOLLOUT). On real error,
; close. Persists wr_pos/wr_len/flags to conn_state.
;   rbx = fd (saved).
; ============================================================================
on_writable:
    push    rbx                          ; entry rsp%16==8 -> ==0 (calls aligned)
    mov     ebx, edi                     ; fd
.w:
    ; &state
    lea     rax, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    mov     r8, [rax+8]                  ; wr_pos
    mov     r9, [rax+16]                 ; wr_len
    mov     rdx, r9
    sub     rdx, r8                      ; rem = wr_len - wr_pos
    ; src = write_base[fd] + wr_pos
    mov     rsi, rbx
    shl     rsi, WRITE_BUF_SHIFT         ; write slots are WRITE_BUF_SIZE (32 KiB)
    add     rsi, [rel write_base]
    add     rsi, r8
    mov     rdi, rbx                     ; fd
    mov     rax, SYS_write               ; rdx = rem
    syscall
    test    rax, rax
    js      .werr
    ; wr_pos += n
    lea     rcx, [rel conn_state]
    mov     rdx, rbx
    shl     rdx, CONN_STATE_SHIFT
    add     rcx, rdx                     ; &state
    add     [rcx+8], rax                 ; wr_pos += n
    mov     r8, [rcx+8]                  ; new wr_pos
    cmp     r8, [rcx+16]                 ; wr_pos < wr_len ?
    jb      .w                           ; more to send
    ; fully drained: clear write state, re-watch reads
    mov     qword [rcx+8], 0             ; wr_pos = 0
    mov     qword [rcx+16], 0            ; wr_len = 0
    and     qword [rcx+24], ~ST_WATCH_OUT
    mov     edi, ebx
    mov     rsi, EPOLL_CTL_MOD
    mov     rdx, EPOLLIN
    call    ep_ctl
    mov     edi, ebx
    call    drain                        ; process input buffered while blocked
    jmp     .done
.werr:
    cmp     rax, -EAGAIN
    je      .done                        ; still can't write; wait for EPOLLOUT
    mov     edi, ebx
    call    close_conn                   ; real error
.done:
    pop     rbx
    ret

; ============================================================================
; close_conn(edi = fd): close the fd (removes it from epoll) and clear its
; conn_state record. Preserves callee-saved regs.
; ============================================================================
close_conn:
    mov     r8d, edi                     ; save fd
    mov     rax, SYS_close
    syscall                              ; rdi still = fd
    lea     rax, [rel conn_state]
    mov     rcx, r8
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx                     ; &state
    xor     rcx, rcx
    mov     [rax], rcx
    mov     [rax+8], rcx
    mov     [rax+16], rcx
    mov     [rax+24], rcx
    ret
