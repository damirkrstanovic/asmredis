# asmredis — Milestone C Design: epoll Event Loop

**Date:** 2026-07-09
**Status:** Approved, ready for implementation planning
**Depends on:** Milestone A (merged) — RESP2 server for PING/ECHO/SET/GET/DEL.

Replace the blocking, one-client-at-a-time I/O model with a single-threaded,
non-blocking **`epoll` event loop** so asmredis serves many concurrent clients.
No new commands, no behavior change visible to a single client — purely an I/O
architecture swap, plus correct write backpressure.

## Motivation

Milestone A serves one connection to completion before `accept()`ing the next.
The `-c 50` benchmark (see `docs/benchmark.md`) proved the limitation: it stalled
at exactly `100000 - 49` requests because 49 connections were never accepted.
This milestone makes all connections progress concurrently in one thread.

## Goals

- One process, one thread, non-blocking sockets, `epoll_wait` multiplexing.
- Correct **write backpressure**: a slow/full client never blocks others and
  never causes dropped or interleaved reply bytes (per-connection pending-write
  buffer + `EPOLLOUT`).
- All 16 existing wire tests pass unchanged.
- The `-c 50` (and `-c 200`) benchmark **completes** instead of stalling.

## Non-goals (unchanged from milestone A, still deferred)

- No new commands; no multithreading / SO_REUSEPORT sharding; no TLS.
- No memory reclamation (bump allocator still leaks — milestone B).
- No inline command protocol (array-form RESP only).
- No pipelined-reply batching optimization (we flush one reply at a time — see
  Backpressure).

## Scope of change

**Only `src/net.asm` is rewritten.** `parser.asm`, `dispatch.asm`, `keyspace.asm`,
`reply.asm`, `errmsg.asm`, `util.asm`, `alloc.asm`, and `main.asm` are unchanged.
The global `out_buf`/`out_len`/`argc`/`argv_ptrs`/`argv_lens` remain and are used
as **per-event scratch**: the loop is single-threaded and fully processes one
connection's ready-event before moving to the next, so there is no shared-state
hazard. `dispatch` still builds a reply into the global `out_buf` exactly as
today; `net.asm` then performs a new "write-or-buffer" step.

## Verified ABI facts (this machine, x86-64 Linux)

- Syscalls: `epoll_create1=291`, `epoll_ctl=233`, `epoll_wait=232`,
  `accept4=288`, `fcntl=72` (existing: `socket=41 bind=49 listen=50
  setsockopt=54 read=0 write=1 close=3 mmap=9 exit=60`).
- Flags: `EPOLLIN=0x1`, `EPOLLOUT=0x4`, `EPOLLERR=0x8`, `EPOLLHUP=0x10`.
- `epoll_ctl` ops: `EPOLL_CTL_ADD=1`, `EPOLL_CTL_DEL=2`, `EPOLL_CTL_MOD=3`.
- `EAGAIN = 11` (kernel returns `-11` from `read`/`write`/`accept4` when it would
  block).
- `SOCK_NONBLOCK = 0x800` (OR into `accept4`'s flags and the listen socket type).
- **`struct epoll_event` is PACKED = 12 bytes**: `events` (u32) at offset 0,
  `data` (u64) at offset 4. We store the fd in `data` at offset 4. The events
  array passed to `epoll_wait` therefore has a **12-byte stride**, not 16.
- `epoll_create1(flags)`: flags 0 is fine (no `EPOLL_CLOEXEC` needed here).
- `epoll_ctl(epfd, op, fd, struct epoll_event*)`.
- `epoll_wait(epfd, events*, maxevents, timeout)`: timeout `-1` = block forever.

## Tunables (add to include/syscalls.inc)

```
MAX_CONNS      1024        ; fd-indexed capacity; fd >= MAX_CONNS -> closed
CONN_BUF_SIZE  16384       ; per-connection read AND write buffer size
MAX_EVENTS     256         ; epoll_wait events array capacity per call
CONN_STATE_SZ  32          ; bytes per connection-state record (see below)
```

## Per-connection state (fd-indexed, no allocator)

Three fixed, fd-indexed structures (index = the fd integer):

1. `read_bufs`  — one `mmap`'d region, `MAX_CONNS * CONN_BUF_SIZE` (16 MiB).
   Connection `fd`'s read buffer starts at `read_base + fd*CONN_BUF_SIZE`.
2. `write_bufs` — one `mmap`'d region, `MAX_CONNS * CONN_BUF_SIZE` (16 MiB).
   Connection `fd`'s pending-write buffer at `write_base + fd*CONN_BUF_SIZE`.
3. `conn_state` — BSS array `MAX_CONNS * CONN_STATE_SZ`. Per fd record:
   ```
   offset 0:  rb_used   (8)   ; bytes buffered in this conn's read buffer
   offset 8:  wr_pos    (8)   ; next unwritten byte in this conn's write buffer
   offset 16: wr_len    (8)   ; total valid bytes in this conn's write buffer
   offset 24: flags     (8)   ; bit0 = slot in use; bit1 = watching EPOLLOUT
   ```
   Total 32 bytes/record; 32 KiB array. Zero-initialized in `.bss`.

Total preallocated buffer memory ≈ **32 MiB**. `accept4` returning `fd >=
MAX_CONNS` → `close(fd)` immediately (graceful capacity limit, not a crash).

## Setup sequence (net_serve)

1. `socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0)` — non-blocking listener.
   (Or `socket` then `accept4` with `SOCK_NONBLOCK`; making the listener
   non-blocking lets the accept loop end cleanly on `EAGAIN`.)
2. `setsockopt(SO_REUSEADDR)`, `bind`, `listen(128)` — as milestone A.
3. `arena_init` is already called by `main.asm` before `net_serve`; unchanged.
4. `epoll_create1(0)` → `epfd`. On error → fatal exit(1).
5. `mmap` the two buffer regions (`read_base`, `write_base`); store bases.
6. `epoll_ctl(epfd, ADD, listen_fd, {events=EPOLLIN, data.fd=listen_fd})`.
7. Enter the event loop.

## Event loop

```
loop:
  n = epoll_wait(epfd, events, MAX_EVENTS, -1)
  if n < 0: if EINTR retry; else fatal
  for i in 0..n-1:
     ev  = events[i].events           ; u32 at (events + i*12 + 0)
     fd  = events[i].data (low 32)     ; at (events + i*12 + 4)
     if fd == listen_fd:  on_accept()
     else if ev & (EPOLLHUP|EPOLLERR): close_conn(fd)
     else:
        if ev & EPOLLIN:  on_readable(fd)
        if ev & EPOLLOUT: on_writable(fd)   ; note: a fd won't have both interests
```

### on_accept
```
loop:
  fd = accept4(listen_fd, NULL, NULL, SOCK_NONBLOCK)
  if fd < 0: break            ; -EAGAIN => drained all pending; other errno => break
  if fd >= MAX_CONNS: close(fd); continue     ; at capacity
  conn_state[fd] = { rb_used=0, wr_pos=0, wr_len=0, flags=IN_USE }
  epoll_ctl(epfd, ADD, fd, {events=EPOLLIN, data.fd=fd})
```

### on_readable(fd)
Precondition: this fd is watching `EPOLLIN`, so its write buffer is empty (we
only watch `EPOLLIN` when nothing is pending to write — see Backpressure).
```
space = CONN_BUF_SIZE - rb_used
if space <= 0: close_conn(fd); return          ; unreasonably long single command
n = read(fd, read_bufs[fd] + rb_used, space)
if n == 0: close_conn(fd); return               ; peer closed
if n < 0: if EAGAIN return else close_conn(fd); return
rb_used += n
drain(fd)
```

### drain(fd) — process complete commands, flush one reply at a time
```
loop:
  out_len = 0
  status, consumed = parse_one(read_bufs[fd], rb_used)
  if status == NEED_MORE: compact-not-needed (already at front); return   ; wait for more
  if status == PROTOERR:
      out_len = 0; emit_protoerr()
      try_write(fd, out_buf, out_len)   ; best effort
      close_conn(fd); return
  ; status OK
  dispatch()                            ; builds this command's reply into out_buf
  ; advance read buffer past the consumed command (compact remainder to front)
  rb_used -= consumed
  if rb_used > 0: memmove(read_bufs[fd], read_bufs[fd]+consumed, rb_used)
  ; write-or-buffer this reply
  if not flush_reply(fd, out_buf, out_len): return   ; backpressure engaged, stop
  if rb_used == 0: return                             ; nothing more buffered
```
Note: because we flush each reply before parsing the next command, `out_buf`
holds at most one reply (≤ CONN_BUF_SIZE), so a per-conn write buffer of
CONN_BUF_SIZE always suffices. (A single GET reply for a value that fit in a
16 KiB read buffer is `$<len>\r\n<value>\r\n` ≤ CONN_BUF_SIZE.)

## Backpressure (correct write handling)

`flush_reply(fd, buf, len)` returns TRUE if fully written (caller continues),
FALSE if backpressure engaged (caller must stop draining):
```
written = 0
loop:
  n = write(fd, buf + written, len - written)
  if n >= 0:
     written += n
     if written == len: return TRUE
     continue                          ; short write, keep going
  if n == -EAGAIN:
     ; stash the unwritten tail into this conn's write buffer
     rem = len - written
     memcpy(write_bufs[fd], buf + written, rem)
     wr_pos = 0; wr_len = rem
     flags |= WATCHING_OUT
     epoll_ctl(epfd, MOD, fd, {events=EPOLLOUT, data.fd=fd})   ; drop EPOLLIN
     return FALSE
  else: close_conn(fd); return FALSE   ; real write error
```

### on_writable(fd)
```
loop:
  rem = wr_len - wr_pos
  n = write(fd, write_bufs[fd] + wr_pos, rem)
  if n >= 0:
     wr_pos += n
     if wr_pos == wr_len:              ; fully drained
        wr_pos = 0; wr_len = 0; flags &= ~WATCHING_OUT
        epoll_ctl(epfd, MOD, fd, {events=EPOLLIN, data.fd=fd})   ; watch reads again
        drain(fd)                       ; resume any input buffered while we were blocked
        return
     continue
  if n == -EAGAIN: return               ; still can't write; wait for next EPOLLOUT
  else: close_conn(fd); return
```

Interest-set toggling (EPOLLIN vs EPOLLOUT, never both simultaneously here) is
what makes a **level-triggered** epoll loop correct without busy-spinning: while
a write is pending we stop watching readability, so `epoll_wait` doesn't return
immediately on still-readable input we're not ready to process.

### close_conn(fd)
```
close(fd)                    ; also removes fd from the epoll set implicitly
conn_state[fd] = { rb_used=0, wr_pos=0, wr_len=0, flags=0 }   ; mark idle
```
(An explicit `epoll_ctl DEL` before `close` is optional; closing the fd removes
it from the interest list. We rely on `close` for removal.)

## Error handling

- Fatal setup errors (`socket`/`bind`/`listen`/`epoll_create1`/`mmap` < 0) →
  short stderr message + `exit(1)` (same pattern as milestone A `.fail`).
- Per-connection errors (`read`/`write` real error, `EPOLLHUP`, `EPOLLERR`,
  peer close) → `close_conn(fd)`; the loop continues. One client cannot affect
  another or the loop.
- `EINTR` from `epoll_wait` → retry the wait.
- Capacity: `fd >= MAX_CONNS` → `close` immediately.
- Protocol error from `parse_one` → emit `-ERR Protocol error\r\n` (best-effort
  write) then `close_conn`.

## Register / stack discipline (implementation guidance)

- `net_serve` never returns; keep long-lived values (`epfd`, `listen_fd`) in
  callee-saved registers (e.g. r12=epfd, r13=listen_fd), and per-event working
  values (current fd, events pointer, index) in callee-saved regs that survive
  the `call parse_one`/`call dispatch`/helper calls. parse_one and dispatch
  preserve rbx and r12–r15 (verified in milestone A).
- Keep `rsp` 16-byte aligned at every `call` (the milestone-A convention).
- The events array (`MAX_EVENTS * 12` bytes) lives in `.bss`; remember the
  **12-byte** packed stride when indexing `events[i]`.
- A single small `epoll_event` scratch struct in `.bss` is reused for every
  `epoll_ctl` ADD/MOD call (write `events` field at +0, `fd` at +4 before each).

## Files

- **Rewrite:** `src/net.asm` (the entire event loop, accept, read, drain,
  backpressure, teardown). This file grows; if it becomes unwieldy, a follow-up
  split (e.g. `src/evloop.asm` for the loop vs `src/net.asm` for socket setup)
  is reasonable, but start as one file matching the current structure.
- **Modify:** `include/syscalls.inc` (new syscall numbers, epoll flags, tunables).
- **Unchanged:** parser, dispatch, keyspace, reply, errmsg, util, alloc, main.

## Testing

1. **Regression — all 16 existing wire tests pass unchanged.** The single-client
   behavior and exact reply bytes are identical; the I/O swap is invisible.
2. **Concurrency — the stall is gone.** Re-run `valkey-benchmark -p 7777 -t
   set,get -n 100000 -c 50` and assert it **completes** (exit 0, non-zero rps)
   rather than timing out at `100000 - 49`. Add a heavier `-c 200` run. This is
   the direct proof the event loop works. Wrap in a `timeout` so a regression
   surfaces as a failure, not a hang.
3. **Backpressure / EPOLLOUT path.** A slow-reading client (reads its reply in
   small chunks with delays, or a pipelined batch against a client that reads
   slowly) must still receive correct, complete replies. Drive with a scripted
   slow reader (e.g. a small Python client that sends N requests then drains
   slowly) and verify byte-correct responses. This exercises `flush_reply`'s
   EAGAIN branch and `on_writable`.
4. **Conformance unchanged.** Re-run the valkey oracle diff at `-c 1`.
5. **Many short-lived connections.** A loop of `valkey-cli` one-shot commands
   (open/command/close) to exercise accept + teardown + slot reuse without fd
   leaks (spot-check `/proc/<pid>/fd` count returns to baseline).

## Milestone boundary

Milestone C delivers concurrency and correct backpressure. Still open for later:
memory reclamation / real allocator (B), more commands (B), inline protocol (B),
and multi-core sharding / RESP3 (beyond current plan).
