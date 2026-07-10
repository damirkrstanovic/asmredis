# Milestone G — Growable per-connection output buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the fixed global build buffer + fixed per-conn write stash with a unified, growable per-connection output buffer, so large collection replies (HGETALL/LRANGE/…) can never overflow.

**Architecture:** Each connection owns one output buffer: a slot in a pre-mapped base region for the common case, growing to a standalone `mmap` only for replies larger than the slot (reclaimed after send). The reply is built directly into it (`reply.asm` bounds-checks every write) and drained from it (`net.asm` `_send`, no stash copy).

**Tech Stack:** x86-64 NASM, static no-libc ELF, raw syscalls. Tests: bash + Python RESP clients (slow-reader + cross-connection).

**Reference design:** `docs/superpowers/specs/2026-07-10-asmredis-milestone-g-reply-buffer-design.md`

**Staging:** Task 1 unifies to a per-conn buffer with a **safe 64 KB cap** (over-size → clean connection close) — a fully-green, corruption-free checkpoint. Task 2 adds **mmap growth** (unbounded) and shrinks the base slot to 32 KB. This de-risks the `net.asm` rewrite.

**ABI invariant:** functions entered at `rsp%16==8`; every `call` at `rsp%16==0`. conn_state (new): `+0 rb_used +8 out_pos +16 out_len +24 flags +32 out_ptr +40 out_cap`, record size 64.

---

## Task 1: Unify to per-connection output buffer (safe 64 KB cap, no growth)

**Files:** `include/syscalls.inc`, `src/main.asm`, `src/reply.asm`, `src/net.asm`.

After this task: the reply is built into and drained from the conn's own base slot (no global `out_buf`, no stash copy). Replies ≤ 64 KB work exactly as before; a reply that would exceed the slot sets an error flag and the connection is closed cleanly (no overflow). Full existing suite stays green (largest existing reply, the ~44 KB `hash-stress` HGETALL, fits the 64 KB slot).

- [ ] **Step 1: `include/syscalls.inc`**

Change `CONN_STATE_SZ`/`CONN_STATE_SHIFT` and rename the write-slot constants; drop `OUT_BUF_SIZE`:

```nasm
%define CONN_STATE_SZ      64
%define CONN_STATE_SHIFT   6
```
Rename the two `WRITE_BUF_*` defines to:
```nasm
%define OUTBUF_BASE_SIZE   65536        ; per-conn output buffer base slot (Task 2 -> 32768)
%define OUTBUF_BASE_SHIFT  16           ; (Task 2 -> 15)
```
Delete the line `%define OUT_BUF_SIZE    65536`.

- [ ] **Step 2: `src/main.asm` — drop the `out_buf`/`out_len` globals**

Change the `.bss` globals line and remove the two definitions. From:
```nasm
global out_buf, out_len, argc, argv_ptrs, argv_lens
out_buf:    resb OUT_BUF_SIZE
out_len:    resq 1
argc:       resq 1
```
to:
```nasm
global argc, argv_ptrs, argv_lens
argc:       resq 1
```
(Leave `argv_ptrs`/`argv_lens`/`buckets` as they are.)

- [ ] **Step 3: `src/reply.asm` — target the current conn's buffer with bounds checks**

Change the extern line from `extern out_buf, out_len` to:
```nasm
extern cur_out, cur_cap, cur_len, cur_err
```
Replace the three `_put_*` helpers (leave `_put_uint` and all public builders unchanged) with:
```nasm
_put_byte:                       ; r8b = byte
    mov     rax, [rel cur_len]
    cmp     rax, [rel cur_cap]   ; room for 1 more byte? (need cur_len < cur_cap)
    jae     .oom
    mov     r11, [rel cur_out]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel cur_len], rax
    ret
.oom:
    mov     qword [rel cur_err], 1
    ret

_put_bytes:                      ; rdi=src, rsi=len
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, rsi             ; cur_len + n
    cmp     rdx, [rel cur_cap]
    ja      .oom                 ; would exceed cap
    mov     r11, [rel cur_out]
    lea     r10, [r11+rax]       ; dest = cur_out + cur_len
    mov     rcx, rsi
    push    rsi
    mov     rsi, rdi             ; src
    mov     rdi, r10             ; dest
    rep     movsb
    pop     rsi
    add     [rel cur_len], rsi
    ret
.oom:
    mov     qword [rel cur_err], 1
    ret

_put_crlf:
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, 2
    cmp     rdx, [rel cur_cap]
    ja      .oom
    mov     r11, [rel cur_out]
    mov     word [r11+rax], 0x0a0d ; bytes 0d 0a
    add     qword [rel cur_len], 2
    ret
.oom:
    mov     qword [rel cur_err], 1
    ret
```

- [ ] **Step 4: `src/net.asm` — full rewrite of the buffer lifecycle**

Replace the ENTIRE contents of `src/net.asm` with:

```nasm
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
    ; a grow may have allocated an overflow mmap that was never persisted into
    ; ST_OUT_MMAP (persist runs only on the success branch), so close_conn won't
    ; free it — munmap the in-flight buffer here (guarded by cur_mmap).
    cmp     qword [rel cur_mmap], 0
    je      .ec_close
    mov     rax, SYS_munmap
    mov     rdi, [rel cur_out]
    mov     rsi, [rel cur_cap]
    syscall
.ec_close:
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
```

- [ ] **Step 5: Build**

Run: `make -s clean && make -s all`
Expected: clean build, no undefined symbols (`out_buf`/`out_len` are gone; `cur_*` resolve between net.asm and reply.asm).

- [ ] **Step 6: Full regression (run ONCE; ~3-4 min)**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — including `backpressure`, `big-reply-backpressure`, `list-stress`, `hash-stress` (its ~44 KB HGETALL fits the 64 KB base slot and is sent directly from the conn buffer), conformance, concurrency, rehashing. (Do not launch a second overlapping `./asmredis 7777` during the run.)

- [ ] **Step 7: Commit**

```bash
git add include/syscalls.inc src/main.asm src/reply.asm src/net.asm
git commit -m "net: unified per-connection output buffer (safe 64KB cap, no stash copy)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Add overflow-mmap growth (unbounded replies)

**Files:** `include/syscalls.inc`, `src/reply.asm`, `src/net.asm`.

Now a reply exceeding the base slot grows to a standalone `mmap` (reclaimed after send / on close) instead of closing the connection. Base slot shrinks to 32 KB (growth covers the rest). A new global `cur_mmap` tracks whether the current build buffer is an owned mmap; it is mirrored into the conn's `ST_OUT_MMAP` flag.

- [ ] **Step 1: `include/syscalls.inc`**

Shrink the base slot and add the flag:
```nasm
%define OUTBUF_BASE_SIZE   32768
%define OUTBUF_BASE_SHIFT  15
%define ST_OUT_MMAP        4
```

- [ ] **Step 2: `src/reply.asm` — grow instead of erroring on overflow**

Add `cur_mmap` to the extern list:
```nasm
extern cur_out, cur_cap, cur_len, cur_err, cur_mmap
extern mem_map_grow
```
(`mem_map_grow` is a helper defined in net.asm — see Step 4.)

Change the three `_put_*` `.oom` handlers so that instead of setting `cur_err`, they call `_grow` to enlarge the buffer, then retry. Replace the `_put_*` helpers with:

```nasm
; _grow(rdi = required capacity): ensure cur_cap >= rdi, growing via mmap.
; On mmap failure sets cur_err (caller then skips the write). Preserves nothing
; the callers rely on except via the globals. rsp aligned by the caller.
_grow:
    call    mem_map_grow             ; (rdi=need) -> updates cur_out/cur_cap/cur_mmap
    ret                             ;              or sets cur_err on failure

_put_byte:                           ; r8b = byte
    mov     rax, [rel cur_len]
    cmp     rax, [rel cur_cap]
    jb      .store
    push    r8                       ; save byte across _grow (align: 1 push -> ==0)
    lea     rdi, [rax+1]
    call    _grow
    pop     r8
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.store:
    mov     r11, [rel cur_out]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel cur_len], rax
.skip:
    ret

_put_bytes:                          ; rdi=src, rsi=len
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, rsi
    cmp     rdx, [rel cur_cap]
    jbe     .copy
    push    rdi
    push    rsi                      ; 2 pushes -> ==8; +8 to align _grow call
    sub     rsp, 8
    mov     rdi, rdx                 ; need = cur_len + n
    call    _grow
    add     rsp, 8
    pop     rsi
    pop     rdi
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.copy:
    mov     r11, [rel cur_out]
    lea     r10, [r11+rax]
    mov     rcx, rsi
    push    rsi
    mov     rsi, rdi
    mov     rdi, r10
    rep     movsb
    pop     rsi
    add     [rel cur_len], rsi
.skip:
    ret

_put_crlf:
    mov     rax, [rel cur_len]
    mov     rdx, rax
    add     rdx, 2
    cmp     rdx, [rel cur_cap]
    jbe     .store
    mov     rdi, rdx
    sub     rsp, 8                   ; align _grow call (entry ==8 -> ==0)
    call    _grow
    add     rsp, 8
    cmp     qword [rel cur_err], 0
    jne     .skip
    mov     rax, [rel cur_len]
.store:
    mov     r11, [rel cur_out]
    mov     word [r11+rax], 0x0a0d
    add     qword [rel cur_len], 2
.skip:
    ret
```

- [ ] **Step 3: `src/net.asm` — declare `cur_mmap`, add `mem_map_grow`, update reset/close/drain**

Add `cur_mmap` to the `.bss` and the `global` line, and export `mem_map_grow`:
```nasm
global net_serve, mem_map_grow
global cur_out, cur_cap, cur_len, cur_err, cur_mmap
```
```nasm
cur_mmap:    resq 1                        ; 1 if cur_out is an owned mmap, else 0 (base slot)
```

In `drain`, when setting up `cur_*` for a command (right after `mov qword [rel cur_err], 0`), also clear the mmap flag — the conn is always at its base slot at command start:
```nasm
    mov     qword [rel cur_mmap], 0
```
(The conn is provably at its base slot here: backpressure drops EPOLLIN, and `_reset_outbuf` resets to the base slot after every full send. So `cur_mmap=0` and `cur_out`=base slot are correct on entry.)

In `drain`'s persist block (`.after_move`, after the `cur_err` check passes), also mirror `cur_mmap` into the conn flags. After the `mov [rax+40], rdx` (out_cap) store, add:
```nasm
    ; mirror mmap ownership into flags (ST_OUT_MMAP)
    mov     rdx, [rax+24]                ; flags
    and     rdx, ~ST_OUT_MMAP
    cmp     qword [rel cur_mmap], 0
    je      .mm0
    or      rdx, ST_OUT_MMAP
.mm0:
    mov     [rax+24], rdx
```
(Place this so `rax` still holds `&state`; it does at that point.)

Add the `mem_map_grow` helper (place it near `_reset_outbuf`):
```nasm
; mem_map_grow(rdi = required capacity): grow the current build buffer to hold at
; least `rdi` bytes. newcap = max(2*cur_cap, need) rounded up to a page; mmap it,
; copy the existing cur_len bytes, munmap the old buffer if it was an owned mmap,
; and update cur_out/cur_cap/cur_mmap. On mmap failure, set cur_err and return
; with cur_out/cur_cap unchanged (caller skips the write). Preserves callee-saved.
mem_map_grow:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                          ; 5 pushes -> ==0 at calls
    mov     r15, rdi                     ; need
    ; newcap = 2*cur_cap
    mov     r14, [rel cur_cap]
    add     r14, r14
    cmp     r14, r15
    jae     .have_cap
    mov     r14, r15                     ; newcap = need if bigger
.have_cap:
    ; round up to page (4096)
    add     r14, 4095
    and     r14, -4096
    ; mmap(NULL, newcap, RW, ANON|PRIVATE, -1, 0)
    mov     rax, SYS_mmap
    xor     rdi, rdi
    mov     rsi, r14
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9, r9
    syscall
    cmp     rax, -4095
    jae     .fail
    mov     r13, rax                     ; new buffer
    ; copy cur_len bytes from cur_out to new
    mov     rdi, r13
    mov     rsi, [rel cur_out]
    mov     rcx, [rel cur_len]
    rep     movsb
    ; if old was an owned mmap, munmap(cur_out, cur_cap)
    cmp     qword [rel cur_mmap], 0
    je      .swap
    mov     rax, SYS_munmap
    mov     rdi, [rel cur_out]
    mov     rsi, [rel cur_cap]
    syscall
.swap:
    mov     [rel cur_out], r13
    mov     [rel cur_cap], r14
    mov     qword [rel cur_mmap], 1
    jmp     .done
.fail:
    mov     qword [rel cur_err], 1       ; leave cur_out/cur_cap unchanged
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```

Replace `_reset_outbuf` with the version that reclaims an overflow mmap:
```nasm
; _reset_outbuf(edi=fd): reply fully sent — munmap an overflow buffer (if any),
; reset out_ptr to the base slot, clear ST_OUT_MMAP, zero out_pos/out_len.
;   rbx = fd, r12 = &state (saved).
_reset_outbuf:
    push    rbx
    push    r12
    sub     rsp, 8                       ; 2 pushes + 8 -> ==0 at calls
    mov     ebx, edi
    lea     r12, [rel conn_state]
    mov     rcx, rbx
    shl     rcx, CONN_STATE_SHIFT
    add     r12, rcx                     ; &state
    test    qword [r12+24], ST_OUT_MMAP
    jz      .to_base
    mov     rax, SYS_munmap
    mov     rdi, [r12+32]                ; out_ptr (overflow mmap)
    mov     rsi, [r12+40]                ; out_cap
    syscall
    and     qword [r12+24], ~ST_OUT_MMAP
.to_base:
    ; out_ptr = base slot ; out_cap = OUTBUF_BASE_SIZE
    mov     rdx, rbx
    shl     rdx, OUTBUF_BASE_SHIFT
    add     rdx, [rel outbuf_base]
    mov     [r12+32], rdx
    mov     qword [r12+40], OUTBUF_BASE_SIZE
    mov     qword [r12+8], 0             ; out_pos = 0
    mov     qword [r12+16], 0            ; out_len = 0
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
```
(Note: `_reset_outbuf` is now called at rsp%16==0 from `_send`; it does 2 pushes + `sub rsp,8` → its `syscall` needs no alignment but keeping the frame balanced is required for the pops.)

In `close_conn`, munmap an overflow buffer before clearing state. Replace `close_conn` with:
```nasm
close_conn:
    lea     rax, [rel conn_state]
    mov     ecx, edi
    shl     rcx, CONN_STATE_SHIFT
    add     rax, rcx
    test    qword [rax+24], ST_IN_USE
    jz      .done
    ; free an overflow output buffer if one is mapped
    test    qword [rax+24], ST_OUT_MMAP
    jz      .nounmap
    mov     r8, rax                      ; save &state across munmap
    mov     r9d, edi                     ; save fd (zero-extends into r9)
    mov     rax, SYS_munmap
    mov     rdi, [r8+32]                 ; out_ptr
    mov     rsi, [r8+40]                 ; out_cap
    syscall                              ; munmap clobbers rax/rcx/r11; r8/r9 survive
    mov     rax, r8
    mov     edi, r9d
.nounmap:
    mov     r8, rax
    mov     rax, SYS_close
    syscall                              ; rdi still = fd
    xor     rcx, rcx
    mov     [r8], rcx
    mov     [r8+8], rcx
    mov     [r8+16], rcx
    mov     [r8+24], rcx
.done:
    ret
```

- [ ] **Step 4: Build + full regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build; EVERY check PASS, exit 0. `hash-stress`'s ~44 KB HGETALL now grows the 32 KB base slot once to an mmap, sends it, and reclaims it — verifying the grow/reclaim path end to end.

- [ ] **Step 5: Commit**

```bash
git add include/syscalls.inc src/reply.asm src/net.asm
git commit -m "net: grow the per-conn output buffer via overflow mmap (unbounded replies)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Slow-reader large-reply + cross-connection tests

**Files:** Create `tests/big_reply2.py`; modify `tests/wire.sh`.

Prove the fix: a slow reader forcing a >32 KB and a >64 KB reply through backpressure receives the exact, complete bytes; and a large reply on one connection doesn't corrupt a small reply on another.

- [ ] **Step 1: Create `tests/big_reply2.py`**

```python
#!/usr/bin/env python3
# Large-reply correctness under backpressure + cross-connection integrity.
# Usage: big_reply2.py <port>. Exit 0 ok / 1 fail.
import socket, sys

def conn(port, rcvbuf=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if rcvbuf is not None:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.connect(("127.0.0.1", port)); s.settimeout(30); return s

def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o

class R:
    def __init__(s,sock): s.s=sock; s.b=b""
    def _f(s):
        c=s.s.recv(4096)
        if not c: raise EOFError("closed")
        s.b+=c
    def line(s):
        while b"\r\n" not in s.b: s._f()
        l,s.b=s.b.split(b"\r\n",1); return l
    def n(s,k):
        while len(s.b)<k: s._f()
        o,s.b=s.b[:k],s.b[k:]; return o

def bulk(r):
    h=r.line(); assert h[:1]==b"$",h
    k=int(h[1:])
    if k<0: return None
    d=r.n(k); r.n(2); return d

def arr(r):
    h=r.line(); assert h[:1]==b"*",h
    return [bulk(r) for _ in range(int(h[1:]))]

def build_hash(s, r, key, nfields, vlen):
    # HSET in batches; each field f<i> = <vlen bytes marked with i>
    exp={}
    i=0
    while i<nfields:
        batch=min(50, nfields-i)
        args=[b"HSET", key.encode()]
        for j in range(i,i+batch):
            f=b"f%d"%j; v=(b"%08d"%j)+b"y"*(vlen-8)
            args += [f,v]; exp[f]=v
        s.sendall(cmd(*args))
        assert r.line()==b":%d"%batch, "HSET batch"
        i+=batch
    return exp

def main():
    if len(sys.argv)!=2: print("usage: big_reply2.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        # ---- 1) >32KB reply under a slow reader (small SO_RCVBUF forces EAGAIN) ----
        s=conn(port, rcvbuf=4096); r=R(s)
        exp=build_hash(s, r, "H32", 2000, 12)     # ~2000*(f + 12B val + framing) ~ 44KB
        s.sendall(cmd("HGETALL","H32"))
        a=arr(r)
        got=dict(zip(a[0::2],a[1::2]))
        if got!=exp: print("FAIL >32KB HGETALL mismatch (n=%d)"%len(got)); return 1
        # ---- 2) >64KB reply (exceeds the old 64KB build buffer too) ----
        exp2=build_hash(s, r, "H64", 3000, 30)    # ~3000*(f + 30B + framing) ~ 130KB
        s.sendall(cmd("HGETALL","H64"))
        a2=arr(r)
        got2=dict(zip(a2[0::2],a2[1::2]))
        if got2!=exp2: print("FAIL >64KB HGETALL mismatch (n=%d)"%len(got2)); return 1
        s.close()
        # ---- 3) cross-connection integrity: A drains a huge reply slowly while B
        #         interleaves small commands; B's replies must stay correct ----
        A=conn(port, rcvbuf=4096); ra=R(A)
        expA=build_hash(A, ra, "HA", 4000, 40)    # ~large
        A.sendall(cmd("HGETALL","HA"))            # A now backpressured mid-drain
        # read A's reply slowly, interleaving B commands
        B=conn(port); rb=R(B)
        for k in range(200):
            B.sendall(cmd("SET", "bk%d"%k, "bv%d"%k)); assert rb.line()==b"+OK"
            B.sendall(cmd("GET", "bk%d"%k))
            if bulk(rb)!=b"bv%d"%k: print("FAIL cross-conn: B GET bk%d"%k); return 1
        aA=arr(ra)                                 # now finish reading A fully
        if dict(zip(aA[0::2],aA[1::2]))!=expA: print("FAIL cross-conn: A reply corrupted"); return 1
        A.close(); B.close()
        print("OK big_reply2: >32KB + >64KB replies intact; cross-connection clean")
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL big_reply2: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 2: Wire it into `tests/wire.sh`** (append at end)

```bash

# --- Milestone G: large replies under backpressure + cross-connection integrity ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/big_reply2.py 7777 >/tmp/asmg_big.txt 2>&1; then
  echo "PASS big-reply-grow"; bg=0
else
  echo "FAIL big-reply-grow: $(cat /tmp/asmg_big.txt)"; bg=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $bg -eq 0 ] || exit 1
```

- [ ] **Step 3: Run + verify green**

Run: `bash tests/wire.sh`
Expected: all checks PASS incl. `big-reply-grow`, exit 0. (This test fails/corrupts on pre-milestone-G code — the >64 KB HGETALL overflows the old 64 KB `out_buf` during construction, and the >32 KB reply overflows the old 32 KB stash under the slow reader.)

- [ ] **Step 4: Commit**

```bash
git add tests/big_reply2.py tests/wire.sh
git commit -m "test: large-reply-under-backpressure + cross-connection integrity

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Benchmark + docs

**Files:** `docs/benchmark.md`.

- [ ] **Step 1: Clean build + green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh` → all PASS, exit 0.

- [ ] **Step 2: SET/GET sweep**

Same methodology as prior milestones (median of 3, `-c {1,20,50,100,200,500}`, `-d {3,512}`, asmredis:7777 vs Valkey:7778). Save raw output; derive cells from files. NOTE (sandbox): chunk the runs so no single Bash command exceeds ~2 min.

- [ ] **Step 3: Append "Milestone G (growable reply buffer)" to `docs/benchmark.md`**

Short intro: the SET/GET path now builds into the per-conn base slot instead of a global buffer, drained directly (no stash copy) — still allocation-free for small replies, so no regression expected. The two median-of-3 tables, an honest "Reading the numbers" vs the in-run oracle and vs milestone F, `uname -r`, binary size.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-G growable reply buffer benchmark (no regression)"
```

---

## Self-Review (completed)

- **Spec coverage:** unified per-conn buffer + conn_state layout + base-slot scheme → Task 1; overflow-mmap growth + reclaim (reset/close munmap) → Task 2; slow-reader >32 KB/>64 KB + cross-connection tests → Task 3; comment corrections folded into the Task 1/2 rewrites; benchmark → Task 4. All mapped.
- **Placeholder scan:** all code is complete verbatim NASM/Python/bash.
- **Consistency:** conn_state offsets (`+8 out_pos +16 out_len +24 flags +32 out_ptr +40 out_cap`, size 64/shift 6) used identically across on_accept/drain/_send/_reset_outbuf/close_conn. `cur_out`/`cur_cap`/`cur_len`/`cur_err`/`cur_mmap` shared between net.asm (owner) and reply.asm. `_send` returns 1 full / 0 backpressure-or-closed, consumed identically by drain and on_writable. Stack alignment annotated per function (net_serve 6push+8; drain/on_readable/on_writable/on_accept per current; `_send` 2push+8; `mem_map_grow` 5push; `_reset_outbuf` Task2 2push+8; reply `_put_*` grow calls framed). Invariant: `_put_*` never write past `cur_cap` (bounds-check then grow-or-skip). The conn is provably at its base slot at each drain-command start (EPOLLIN dropped under backpressure; `_reset_outbuf` after every full send), so `cur_mmap=0`/`cur_out=base` on entry.
