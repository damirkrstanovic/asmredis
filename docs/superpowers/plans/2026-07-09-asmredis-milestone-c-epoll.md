# asmredis Milestone C — epoll Event Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace asmredis's blocking one-client-at-a-time I/O with a single-threaded non-blocking `epoll` event loop that serves many concurrent clients with correct write backpressure.

**Architecture:** Rewrite `src/net.asm` only. `parser`/`dispatch`/`keyspace`/`reply`/`errmsg`/`util`/`alloc`/`main` are untouched — they already operate on `(buffer,len) → argv → out_buf`. Per-connection state (read buffer, pending-write buffer, counters) is stored in fixed arrays indexed directly by fd; the global `out_buf` is reused as per-event scratch (safe: single-threaded, one event processed to completion at a time).

**Tech Stack:** NASM, static no-libc ELF64, raw Linux syscalls (`epoll_create1`, `epoll_ctl`, `epoll_wait`, `accept4`), level-triggered epoll with interest-set toggling. Tests drive it with `nc`, `valkey-cli`, `valkey-benchmark`, and a small Python slow-reader.

**Verified ABI facts (this machine, x86-64 Linux):**
- Syscalls: `epoll_create1=291`, `epoll_ctl=233`, `epoll_wait=232`, `accept4=288`, `fcntl=72`. Existing: `socket=41 bind=49 listen=50 setsockopt=54 read=0 write=1 close=3 mmap=9 exit=60`.
- Flags: `EPOLLIN=0x1 EPOLLOUT=0x4 EPOLLERR=0x8 EPOLLHUP=0x10`; ctl ops `EPOLL_CTL_ADD=1 EPOLL_CTL_DEL=2 EPOLL_CTL_MOD=3`; `EAGAIN=11` (kernel returns `-11`); `EINTR=4` (returns `-4`); `SOCK_NONBLOCK=0x800`.
- **`struct epoll_event` is PACKED = 12 bytes**: `events`(u32)@0, `data`(u64)@4. Store fd at offset 4. The `epoll_wait` events array has a **12-byte stride** — NOT 16.
- Syscall ABI: nr in `rax`; args `rdi,rsi,rdx,r10,r8,r9`; return in `rax` (negative = `-errno`); clobbers `rcx,r11`. **Note:** `ecx`/`rcx` is clobbered by every `syscall`, so never hold the epoll event-mask in `rcx` across a syscall — copy it to a preserved reg first.

**How to use the reference code below:** it is a DRAFT guide. Follow the interface contracts and the ABI facts exactly, but FIX any bug you find; the tests are the gate. Lessons from milestone A that still apply: RIP-relative addressing cannot include an index register (`lea base` first, then `[base+idx*8]`); keep `rsp` 16-aligned at every `call`; `append_raw`/reply helpers clobber `r10,r11,rax,rcx,rsi,rdi`.

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `include/syscalls.inc` | modify | add epoll/accept4 syscall numbers, epoll flags, ctl ops, `EAGAIN`/`EINTR`, `SOCK_NONBLOCK`, and milestone-C tunables |
| `src/net.asm` | rewrite | non-blocking listener, epoll loop, accept/read/drain, backpressure, teardown |
| `tests/wire.sh` | modify | add concurrency + backpressure + fd-leak tests |
| `tests/slow_reader.py` | create | scripted slow-reading client for the backpressure test |
| `docs/benchmark.md`, `README.md` | modify (Task 3) | record that concurrency now works |

**Per-connection state model (used throughout):**
- `read_base`, `write_base` (BSS qwords): bases of two `mmap`'d regions, each `MAX_CONNS * CONN_BUF_SIZE`.
- Connection `fd`'s read buffer = `[read_base] + fd*CONN_BUF_SIZE` (= `fd << 14` for 16384).
- Connection `fd`'s write buffer = `[write_base] + fd*CONN_BUF_SIZE`.
- `conn_state` (BSS array `MAX_CONNS * CONN_STATE_SZ`): record for fd at `conn_state + fd*32`:
  - `+0 rb_used` (8) · `+8 wr_pos` (8) · `+16 wr_len` (8) · `+24 flags` (8; bit0=IN_USE, bit1=WATCHING_OUT)

---

## Task 1: Non-blocking epoll event loop (happy path)

Rewrite `net.asm` into an epoll loop that accepts many clients, reads, drains commands via the existing `parse_one`/`dispatch`, and writes replies. Writes use a simple write-all loop for now (correct backpressure via `EPOLLOUT` is Task 2). Result: all 16 existing wire tests pass AND the `-c 50` benchmark completes instead of stalling.

**Files:**
- Modify: `include/syscalls.inc`
- Rewrite: `src/net.asm`
- Modify: `tests/wire.sh` (add a concurrency check)

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh` (after the existing conformance block, before any final summary):
```bash
# --- Milestone C: concurrency — -c 50 must COMPLETE (milestone A stalled here) ---
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 30 valkey-benchmark -p 7777 -t set,get -n 20000 -c 50 -q >/tmp/asmc_bench.txt 2>/dev/null
bexit=$?
kill $SRV 2>/dev/null
if [ "$bexit" = "0" ] && grep -q 'requests per second' /tmp/asmc_bench.txt; then
  echo "PASS concurrency-c50"
else
  echo "FAIL concurrency-c50 (exit=$bexit): $(tr '\r' '\n' < /tmp/asmc_bench.txt | tail -2)"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: FAIL concurrency-c50 — the milestone-A blocking server stalls at `-c 50` and `timeout` kills the benchmark (exit 124).

- [ ] **Step 3: Add constants to `include/syscalls.inc`**

Append:
```nasm
; ---- milestone C: epoll / non-blocking ----
%define SYS_epoll_create1  291
%define SYS_epoll_ctl      233
%define SYS_epoll_wait     232
%define SYS_accept4        288

%define EPOLLIN            0x1
%define EPOLLOUT           0x4
%define EPOLLERR           0x8
%define EPOLLHUP           0x10
%define EPOLL_CTL_ADD      1
%define EPOLL_CTL_DEL      2
%define EPOLL_CTL_MOD      3
%define EAGAIN             11
%define EINTR              4
%define SOCK_NONBLOCK      0x800

%define MAX_CONNS          1024
%define CONN_BUF_SIZE      16384        ; per-conn read & write buffer (== fd<<14)
%define CONN_BUF_SHIFT     14
%define CONN_STATE_SZ      32
%define CONN_STATE_SHIFT   5
%define MAX_EVENTS         256
%define EV_SIZE            12           ; packed struct epoll_event stride
; conn_state flag bits
%define ST_IN_USE          1
%define ST_WATCH_OUT       2
```

- [ ] **Step 4: Rewrite `src/net.asm` (happy-path event loop)**

Full reference implementation (fix bugs; keep the contracts):
```nasm
%include "syscalls.inc"
global net_serve
extern parse_one, dispatch, emit_protoerr
extern out_buf, out_len

section .rodata
err_setup:     db "setup failed", 10
err_setup_len: equ $ - err_setup

section .bss
sockaddr:    resb 16
read_base:   resq 1
write_base:  resq 1
conn_state:  resb MAX_CONNS * CONN_STATE_SZ
ev_scratch:  resb 16                    ; one epoll_event for ctl calls (12 used)
events:      resb MAX_EVENTS * EV_SIZE  ; epoll_wait output (12-byte stride)

section .text
; ---- helpers -------------------------------------------------------------

; map_region: mmap MAX_CONNS*CONN_BUF_SIZE anon RW -> rax=base (fatal on error)
map_region:
    mov     rax, SYS_mmap
    xor     rdi, rdi
    mov     rsi, MAX_CONNS * CONN_BUF_SIZE
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9, r9
    syscall
    cmp     rax, -4095
    jae     net_fail            ; error
    ret

; ep_ctl: perform epoll_ctl(epfd=r12, op=rsi, fd=rdi, events_mask=edx)
;   builds ev_scratch {events=edx, data.fd=edi}. Clobbers rax,r10,r11,rcx.
ep_ctl:
    lea     r11, [rel ev_scratch]
    mov     [r11], edx           ; events mask
    mov     [r11+4], edi         ; data.fd = fd
    mov     r10, r11
    mov     rax, SYS_epoll_ctl
    ; rdi=fd already, rsi=op already, rdx=events (ignored by kernel beyond struct)
    mov     rdx, rdi             ; epoll_ctl wants fd in rdx? NO -- see note
    ; CORRECTION: epoll_ctl(epfd, op, fd, event*). So: rdi=epfd, rsi=op, rdx=fd, r10=event*
    ; The caller convention above is wrong; implement as below instead.
    ret
; NOTE: the ep_ctl draft above has the arg order wrong. Correct epoll_ctl ABI:
;   rdi=epfd, rsi=op, rdx=fd, r10=&epoll_event.
; Implement ep_ctl(rdi_in=fd, sil=op, edx_in=mask) by MOVING them into place:
;   save fd, op, mask; write ev_scratch{mask, fd}; then
;   mov rdi,r12(epfd); mov rsi,op; mov rdx,fd; lea r10,[ev_scratch]; syscall.
; Rewrite ep_ctl cleanly per this contract before use.

; ---- entry ---------------------------------------------------------------
; rdi = port (host order)
net_serve:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx                  ; 5 pushes -> rsp%16==0 at call sites
    mov     r14w, di             ; stash port briefly

    ; socket(AF_INET, SOCK_STREAM|SOCK_NONBLOCK, 0)
    mov     rax, SYS_socket
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    or      rsi, SOCK_NONBLOCK
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      net_fail
    mov     r13, rax             ; listen fd

    ; setsockopt SO_REUSEADDR = 1
    mov     dword [rsp-8], 1
    mov     rax, SYS_setsockopt
    mov     rdi, r13
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [rsp-8]
    mov     r8, 4
    syscall

    ; sockaddr_in {family=AF_INET, port=htons(r14w), addr=0}
    lea     rdi, [rel sockaddr]
    xor     rax, rax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     word [rdi], AF_INET
    mov     ax, r14w
    xchg    al, ah
    mov     [rdi+2], ax

    ; bind, listen
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

    ; epoll_create1(0)
    mov     rax, SYS_epoll_create1
    xor     rdi, rdi
    syscall
    test    rax, rax
    js      net_fail
    mov     r12, rax             ; epfd

    ; mmap the two per-conn buffer regions
    call    map_region
    mov     [rel read_base], rax
    call    map_region
    mov     [rel write_base], rax

    ; epoll_ctl(epfd, ADD, listen_fd, EPOLLIN)
    mov     rdi, r13             ; fd
    mov     rsi, EPOLL_CTL_ADD
    mov     rdx, EPOLLIN
    call    ep_ctl

.loop:
    mov     rax, SYS_epoll_wait
    mov     rdi, r12
    lea     rsi, [rel events]
    mov     rdx, MAX_EVENTS
    mov     r10, -1              ; block forever
    syscall
    test    rax, rax
    jg      .have
    ; rax<=0: EINTR -> retry; other -> retry (defensive)
    jmp     .loop
.have:
    mov     r15, rax             ; n = number of ready events
    xor     r14, r14             ; i = 0
.ev:
    cmp     r14, r15
    jge     .loop
    ; ev = events + i*12
    lea     rax, [rel events]
    lea     rbx, [r14 + r14*2]   ; i*3
    lea     rax, [rax + rbx*4]   ; + i*3*4 = i*12   -> rax = &events[i]
    mov     r10d, [rax]          ; event mask (use r10, NOT rcx: survives our code; but syscalls clobber r10!)
    ; SAFER: keep mask in a callee-saved reg. Use ebx for fd, and stash mask on stack or a preserved reg.
    mov     ebx, [rax+4]         ; fd  (callee-saved rbx survives calls)
    ; keep the mask in a byte on the stack red-zone-free: push it
    push    r10                  ; save mask (also keeps 16-alignment: now odd->realign in callees)
    ; NOTE: after this push rsp%16==8; the handlers below use `call`, so add `sub rsp,8`
    ; around calls OR pop the mask into a preserved reg first. Cleaner: mov r9d,[rax] into
    ; a reg you don't clobber. Simplest robust approach: dispatch on mask/fd WITHOUT extra push:
    pop     r10                  ; (undo; see cleaner dispatch below)

    ; ---- cleaner dispatch (implement this, ignore the push/pop sketch above) ----
    ; ebx = fd (preserved). Recompute mask each use from [rax] BEFORE any syscall, or
    ; copy mask to r15?/no (r15=n). Use a dedicated BSS byte or keep mask in ebp.
    ; RECOMMENDED: use rbp as the event-mask holder (push rbp in prologue -> 6 pushes,
    ; keeps rsp%16==0). Then: mov ebp, [rax]  ; mov ebx, [rax+4].
    ; The steps below assume: ebx=fd, ebp=event mask.

    cmp     ebx, r13d
    je      .accept
    test    ebp, EPOLLHUP | EPOLLERR
    jnz     .close
    test    ebp, EPOLLIN
    jz      .maybe_out
    mov     edi, ebx
    call    on_readable
    jmp     .next
.maybe_out:
    test    ebp, EPOLLOUT
    jz      .next
    mov     edi, ebx
    call    on_writable
    jmp     .next
.accept:
    call    on_accept
    jmp     .next
.close:
    mov     edi, ebx
    call    close_conn
.next:
    inc     r14
    jmp     .ev

; ---- on_accept: drain the listener with accept4 until EAGAIN ----
on_accept:
.a:
    mov     rax, SYS_accept4
    mov     rdi, r13
    xor     rsi, rsi
    xor     rdx, rdx
    mov     r10, SOCK_NONBLOCK
    syscall
    test    rax, rax
    js      .done                ; -EAGAIN or error -> stop accepting
    ; rax = new fd
    cmp     rax, MAX_CONNS
    jl      .ok
    ; over capacity -> close and keep draining
    mov     rdi, rax
    mov     rax, SYS_close
    syscall
    jmp     .a
.ok:
    mov     ebx, eax             ; wait: rbx is caller's fd... on_accept is called with no fd arg.
    ; Use a local; rbx here is fine to clobber? NO -- caller's .ev uses ebx=fd(listener). But we
    ; jumped here via .accept where ebx=listen fd, unneeded after. Still, be safe: use r8 for newfd.
    ; Implement with newfd in a reg not needed by the caller loop across this call. Since on_accept
    ; is a `call`, rbx/rbp/r12-r15 must be preserved for the caller. Save/restore any you use.
    ; init conn_state[newfd] = {0,0,0, IN_USE}; epoll_ctl ADD newfd EPOLLIN.
    ; (Implement cleanly: push whatever callee-saved regs you use.)
    jmp     .a
.done:
    ret

; ---- on_readable(edi=fd): read then drain complete commands ----
; Preserves callee-saved regs it uses. Uses fd-indexed read buffer + conn_state.
on_readable:
    ; sptr = conn_state + fd*32 ; rbuf = [read_base] + fd*16384
    ; space = CONN_BUF_SIZE - rb_used ; if <=0 close
    ; n = read(fd, rbuf+rb_used, space); if 0 close; if <0: EAGAIN? return : close
    ; rb_used += n ; call drain(fd)
    ret

; ---- drain(edi=fd): parse+dispatch+flush each complete command ----
; loop:
;   out_len=0
;   status,consumed = parse_one(rbuf, rb_used)
;   NEED_MORE -> return (partial stays at front)
;   PROTOERR  -> out_len=0; emit_protoerr; flush_reply(fd,out_buf,out_len); close_conn(fd); return
;   OK -> dispatch; rb_used-=consumed; if rb_used>0 memmove(rbuf, rbuf+consumed, rb_used)
;         if flush_reply(fd,out_buf,out_len)==0 return   ; backpressure (Task 2; Task 1 always returns 1)
;         if rb_used==0 return
drain:
    ret

; ---- flush_reply(edi=fd, rsi=buf, rdx=len) -> rax=1 written / 0 backpressure ----
; TASK 1: simple write-all loop; on EAGAIN retry (spin). Returns 1 when done, closes+returns 0 on error.
; (Small SET/GET replies over loopback complete on the first write, so no real spin. Task 2 replaces
;  this with proper EPOLLOUT buffering.)
flush_reply:
    ; written=0; loop write(fd, buf+written, len-written); on n>=0 accumulate; done when ==len.
    ; on -EAGAIN: continue (retry). on other error: close_conn(fd); return 0.
    mov     rax, 1
    ret

; ---- on_writable(edi=fd): Task 2 (no-op stub in Task 1) ----
on_writable:
    ret

; ---- close_conn(edi=fd): close + mark slot idle ----
close_conn:
    push    rdi
    mov     rax, SYS_close
    syscall                      ; close(fd) ; removes from epoll set
    pop     rdi
    ; conn_state[fd] = zeroed
    ; sptr = conn_state + fd*32 ; zero 32 bytes
    ret

; ---- fatal setup error ----
net_fail:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_setup]
    mov     rdx, err_setup_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall
```

Implementation notes the engineer MUST resolve (the draft above deliberately flags them):
1. **Fix `ep_ctl`** to the correct `epoll_ctl(epfd=rdi, op=rsi, fd=rdx, &event=r10)` ABI. Contract: call with `rdi=fd, rsi=op, rdx=mask`; inside, save those, populate `ev_scratch` (`[+0]=mask`, `[+4]=fd`), then `rdi=r12`(epfd)/`rsi=op`/`rdx=fd`/`r10=&ev_scratch`/`rax=SYS_epoll_ctl`/`syscall`. Preserve any callee-saved reg you touch.
2. **Event-mask register:** do NOT keep the mask in `rcx`/`r10` across syscalls (clobbered). Add `push rbp` to the prologue (6 pushes → `rsp%16==0` at calls) and hold the mask in `ebp`, fd in `ebx` for each event.
3. **fd-indexed address math** (illegal to use an index reg with `[rel ...]`): compute `rbuf` as `mov rax,fd; shl rax,CONN_BUF_SHIFT; add rax,[rel read_base]`; `sptr` as `mov rax,fd; shl rax,CONN_STATE_SHIFT; lea rcx,[rel conn_state]; add rax,rcx`.
4. **`on_accept`/`on_readable`/`drain`/`close_conn`** bodies: implement per the inline pseudocode. `drain`'s memmove is the same forward `rep movsb` (dest<src) used in milestone-A net.asm. `on_readable`+`drain` reuse the exact `parse_one`/`dispatch` calling pattern from the old net.asm (which preserved rbx,r12–r15).
5. **Stack alignment:** every `call` at `rsp%16==0`. With 6 prologue pushes and helpers that push an even count (or add `sub rsp,8`), keep it aligned. Trace it.
6. **`accept4` newfd register:** on_accept is `call`ed; preserve the caller's `rbx`(fd)/`rbp`(mask)/`r12`–`r15`. Use scratch or save/restore.

- [ ] **Step 5: Build and run the full suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: all prior PASS lines (banner … conformance) **plus** `PASS concurrency-c50`. If any earlier wire test regressed, the single-client path is broken — debug before proceeding.

- [ ] **Step 6: Commit**

```bash
git add include/syscalls.inc src/net.asm tests/wire.sh
git commit -m "net: epoll event loop (happy path) — concurrent clients, -c 50 completes"
```

---

## Task 2: Correct write backpressure (EPOLLOUT + per-conn write buffers)

Replace Task 1's write-all-spin `flush_reply` with proper non-blocking backpressure: on a short/`EAGAIN` write, stash the tail in the connection's write buffer and switch epoll interest to `EPOLLOUT`; finish the write when the socket is writable, then switch back to `EPOLLIN` and resume draining.

**Files:**
- Modify: `src/net.asm` (`flush_reply`, `on_writable`, interest toggling)
- Create: `tests/slow_reader.py`
- Modify: `tests/wire.sh` (backpressure test)

- [ ] **Step 1: Write the failing test**

Create `tests/slow_reader.py`:
```python
#!/usr/bin/env python3
# Sends N pipelined GETs for a pre-set key, then reads the replies SLOWLY in
# small chunks with delays, forcing the server's socket send buffer to fill and
# exercising the EPOLLOUT backpressure path. Verifies every reply is the exact
# expected bulk string, in order, with none dropped or corrupted.
import socket, sys, time

port = int(sys.argv[1]); n = int(sys.argv[2]); val = sys.argv[3].encode()
s = socket.create_connection(("127.0.0.1", port))
# SET k <val>
s.sendall(b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$%d\r\n%s\r\n" % (len(val), val))
# read +OK
assert s.recv(64).startswith(b"+OK"), "SET failed"
# pipeline N GETs at once
req = b"*2\r\n$3\r\nGET\r\n$1\r\nk\r\n" * n
s.sendall(req)
expected = b"$%d\r\n%s\r\n" % (len(val), val)
want = expected * n
# read slowly: small chunks, with a delay, so the server backs up
got = b""
while len(got) < len(want):
    time.sleep(0.005)
    chunk = s.recv(256)
    if not chunk:
        break
    got += chunk
s.close()
if got == want:
    print("OK slow-reader %d replies" % n)
    sys.exit(0)
else:
    print("MISMATCH got %d want %d bytes" % (len(got), len(want)))
    sys.exit(1)
```
`chmod +x tests/slow_reader.py`.

Append to `tests/wire.sh`:
```bash
# --- Milestone C: backpressure / EPOLLOUT path (slow reader, large-ish value) ---
./asmredis 7777 & SRV=$!; sleep 0.3
bigval=$(python3 -c "print('x'*4000, end='')")
if python3 tests/slow_reader.py 7777 2000 "$bigval" >/tmp/asmc_slow.txt 2>&1; then
  echo "PASS backpressure"
else
  echo "FAIL backpressure: $(cat /tmp/asmc_slow.txt)"; kill $SRV 2>/dev/null; exit 1
fi
kill $SRV 2>/dev/null
```
(2000 pipelined 4000-byte GET replies = ~8 MB, far exceeding any socket buffer, so the server MUST use the write buffer + EPOLLOUT to deliver them all correctly.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `FAIL backpressure` — Task 1's spin-write either wedges the loop (one connection monopolizes it while spinning on EAGAIN, `timeout`/hang) or the naive flush drops bytes. (If it happens to pass because the kernel buffered everything, increase N to 20000 so it can't.)

- [ ] **Step 3: Implement proper backpressure**

Replace `flush_reply` and `on_writable`, and ensure `drain` stops when `flush_reply` returns 0.

`flush_reply(edi=fd, rsi=buf, rdx=len) -> rax=1 fully written / 0 backpressure engaged`:
```nasm
; write as much as possible; if it can't all go, copy the tail into the conn's
; write buffer, set wr_pos/wr_len, epoll_ctl MOD to EPOLLOUT (drop EPOLLIN), return 0.
flush_reply:
    ; save fd, buf, len in callee-saved regs (e.g. r14b..? no r14=i). Use locals via push.
    ; written = 0
    ; .w: n = write(fd, buf+written, len-written)
    ;     if n < 0:
    ;        if n == -EAGAIN: goto .stash
    ;        else: close_conn(fd); return 0
    ;     written += n
    ;     if written == len: return 1
    ;     goto .w
    ; .stash:
    ;     rem = len - written
    ;     memcpy(write_buf(fd), buf+written, rem)     ; rem <= CONN_BUF_SIZE (one reply)
    ;     conn_state[fd].wr_pos = 0 ; wr_len = rem ; flags |= ST_WATCH_OUT
    ;     ep_ctl(fd, EPOLL_CTL_MOD, EPOLLOUT)         ; watch writes only
    ;     return 0
    ret
```

`on_writable(edi=fd)`:
```nasm
; flush the pending write buffer; when fully drained, switch back to EPOLLIN and resume draining.
on_writable:
    ; sptr = conn_state+fd*32 ; wbuf = write_base + fd*16384
    ; .w: rem = wr_len - wr_pos ; n = write(fd, wbuf+wr_pos, rem)
    ;     if n < 0: if -EAGAIN return ; else close_conn(fd); return
    ;     wr_pos += n
    ;     if wr_pos < wr_len: goto .w
    ;     ; fully drained:
    ;     wr_pos=0; wr_len=0; flags &= ~ST_WATCH_OUT
    ;     ep_ctl(fd, EPOLL_CTL_MOD, EPOLLIN)          ; watch reads again
    ;     drain(fd)                                    ; process input buffered while blocked
    ret
```

Ensure `drain` already returns immediately when `flush_reply` returns 0 (the Task-1 pseudocode has `if flush_reply(...)==0 return`; confirm it's wired). No other module changes.

Alignment/register reminders: `flush_reply`/`on_writable` are `call`ed from the loop and from `drain`; preserve the caller's `rbx`(fd)/`rbp`(mask)/`r12`–`r15`; keep `rsp%16==0` at inner `call`s (`ep_ctl`, `close_conn`, `drain`). `ep_ctl` recomputes `ev_scratch` each call, so concurrent fds don't interfere (single-threaded, one call at a time).

- [ ] **Step 4: Run the suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: every prior PASS **plus** `PASS backpressure`, and `PASS concurrency-c50` still passes (proper flush must not regress the happy path). Re-run 3× to shake out any nondeterministic wedging.

- [ ] **Step 5: Commit**

```bash
git add src/net.asm tests/slow_reader.py tests/wire.sh
git commit -m "net: correct write backpressure via per-conn buffers + EPOLLOUT"
```

---

## Task 3: Verification, fd-leak check, benchmark + docs

Add a heavier concurrency run and an fd-leak check, then record the milestone-C results and update the README.

**Files:**
- Modify: `tests/wire.sh` (heavier `-c 200`, fd-leak check)
- Modify: `docs/benchmark.md`, `README.md`

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh`:
```bash
# --- Milestone C: heavier concurrency (-c 200) still completes ---
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 40 valkey-benchmark -p 7777 -t set,get -n 40000 -c 200 -q >/tmp/asmc_b200.txt 2>/dev/null
b2=$?
# --- fd-leak: many short-lived connections; server's fd count returns to baseline ---
base=$(ls /proc/$SRV/fd 2>/dev/null | wc -l)
for i in $(seq 1 200); do valkey-cli -p 7777 PING >/dev/null 2>&1; done
sleep 0.3
after=$(ls /proc/$SRV/fd 2>/dev/null | wc -l)
kill $SRV 2>/dev/null
[ "$b2" = "0" ] && grep -q 'requests per second' /tmp/asmc_b200.txt && echo "PASS concurrency-c200" || { echo "FAIL concurrency-c200 (exit=$b2)"; exit 1; }
# allow a little slack but it must not grow unbounded (leak would be ~+200)
if [ "$after" -le $((base + 3)) ]; then echo "PASS no-fd-leak (base=$base after=$after)"; else echo "FAIL no-fd-leak (base=$base after=$after)"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails-then-passes**

Run: `bash tests/wire.sh`
Expected after Tasks 1-2: these should PASS. If `concurrency-c200` fails, the loop can't sustain 200 clients (investigate `MAX_EVENTS`/backlog); if `no-fd-leak` fails, `close_conn` isn't zeroing state / not closing — fix in `net.asm`. (This task's test is also a guard against regressions; a clean pass is the expected outcome.)

- [ ] **Step 3: Record results in `docs/benchmark.md`**

Run the actual comparison and paste real numbers:
```bash
./asmredis 7777 & SRV=$!
valkey-server --port 7778 --save "" --daemonize yes --logfile /tmp/vk.log --dir /tmp
sleep 0.4
for c in 1 20 50 100 200; do
  echo "asmredis -c $c:"; valkey-benchmark -p 7777 -t set,get -n 50000 -c $c -q 2>/dev/null
  echo "valkey   -c $c:"; valkey-benchmark -p 7778 -t set,get -n 50000 -c $c -q 2>/dev/null
done
kill $SRV; valkey-cli -p 7778 shutdown nosave 2>/dev/null
```
Add a "Milestone C (epoll)" section to `docs/benchmark.md` with a table of the `set,get` rps for asmredis vs valkey at `-c 1,20,50,100,200`, and a one-line note that the milestone-A `-c 50` stall is resolved. Keep the existing milestone-A section for historical contrast.

- [ ] **Step 4: Update `README.md`**

Change the "Limits (milestone A)" section: remove "serves one client at a time" and replace with a "Concurrency" note that asmredis now uses a single-threaded non-blocking `epoll` event loop handling up to `MAX_CONNS` (1024) concurrent clients with write backpressure. Keep the other limits (array-only RESP, leaking allocator). Update the "How it works" bullet for `src/net.asm` to say "epoll event loop + per-connection buffers".

- [ ] **Step 5: Run the full suite once more and commit**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: all PASS lines including `concurrency-c50`, `backpressure`, `concurrency-c200`, `no-fd-leak`.
```bash
git add tests/wire.sh docs/benchmark.md README.md
git commit -m "test+docs: heavier concurrency + fd-leak checks, milestone C benchmarks"
```

---

## Self-Review (completed during planning)

**Spec coverage:** epoll setup + non-blocking listener + `accept4` loop → Task 1; fd-indexed per-conn read buffers + drain reusing `parse_one`/`dispatch` → Task 1; correct backpressure (per-conn write buffers, `EPOLLOUT`, interest toggling, resume-drain) → Task 2; level-triggered + interest toggling to avoid spin → Task 2; teardown/`close_conn` + capacity limit + `EINTR` → Tasks 1/3; testing (16 regressions, `-c 50`/`-c 200` completion, backpressure slow-reader, fd-leak, conformance) → Tasks 1-3; docs → Task 3. All spec sections map to a task.

**Placeholder scan:** the `net.asm` reference is explicitly a draft with the tricky routines (`ep_ctl`, `on_accept`, `on_readable`, `drain`, `flush_reply`, `on_writable`, `close_conn`) specified by exact register/memory contract + pseudocode rather than full final assembly — this is deliberate (the same draft-then-fix workflow used for milestone A, where the implementer corrected real bugs). Every routine has a complete contract and the tests fully constrain behavior. No "TBD"/"handle errors"-style hand-waving remains; each flagged item names exactly what to fix.

**Consistency:** register conventions (`r12=epfd`, `r13=listen_fd`, `r14=i`, `r15=n`, `ebx=fd`, `ebp=event mask`), the `conn_state` layout (`rb_used@0 wr_pos@8 wr_len@16 flags@24`), and the flag bits (`ST_IN_USE=1`, `ST_WATCH_OUT=2`) are used identically across Tasks 1 and 2. `flush_reply` returns `1=written/0=backpressure` in both the Task-1 stub and Task-2 real version; `drain` checks that return the same way in both.

**Known implementation hotspots flagged inline:** correct `epoll_ctl` ABI arg order; keeping the event mask out of syscall-clobbered `rcx`/`r10` (use `ebp`); RIP-relative + index-register illegality in the fd math; 12-byte packed `epoll_event` stride; 16-byte stack alignment across the new `call` graph; callee-saved preservation of `rbx`/`rbp` through helper calls.
