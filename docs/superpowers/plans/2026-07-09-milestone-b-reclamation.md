# Milestone B — Memory Reclamation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reclaiming allocator (segregated power-of-two free lists) on top of the existing bump arena, wire the keyspace to actually free memory on DEL and SET-overwrite, and make SET reply an OOM error when the arena is truly exhausted.

**Architecture:** `src/alloc.asm` keeps the bump arena as a backing store and gains `mem_alloc`/`mem_free` over 12 size-class free lists (8..16384 B, LIFO, "next" pointer stored intrusively inside each freed block). `src/keyspace.asm` allocates via `mem_alloc` and frees via `mem_free` on DEL and overwrite. `src/dispatch.asm`'s `cmd_set` reports OOM. No new syscalls; free/alloc are O(1) with no coalescing.

**Tech Stack:** x86-64 NASM (elf64), static no-libc ELF, raw Linux syscalls. Black-box tests in bash (`tests/wire.sh`) + a Python RESP client helper.

**Reference design:** `docs/superpowers/specs/2026-07-09-asmredis-milestone-b-reclamation-design.md`

---

## File Structure

- `src/alloc.asm` — **rewrite**: keep `arena_init`/`arena_alloc`; add `_size_class`, `mem_alloc`, `mem_free`, and a `free_lists` BSS array.
- `src/keyspace.asm` — **modify**: `_copy_arena` and the entry allocation call `mem_alloc`; `ks_del` and `ks_set` (overwrite + insert-failure paths) call `mem_free`.
- `src/dispatch.asm` — **modify**: `cmd_set` branches on `ks_set`'s return, emitting `-ERR out of memory\r\n` on OOM.
- `tests/reclaim.py` — **create**: a minimal RESP client that runs `overwrite`, `del`, and `oom` stress modes.
- `tests/wire.sh` — **modify**: three new checks (`reclaim-overwrite`, `reclaim-del`, `oom-error`).

Key invariant enforced across files: a block is always freed with the **same byte length it was allocated with**, so it always returns to the class it came from. `mem_alloc`/`mem_free` round that length to a class identically (via `_size_class`).

---

## Task 1: Rewrite `alloc.asm` with size-class free lists

**Files:**
- Modify: `src/alloc.asm` (full rewrite of the file below)

This task adds `mem_alloc`/`mem_free` but does **not** yet wire the keyspace to them. `arena_alloc` stays public and in use, so behaviour is unchanged and all existing tests must still pass. The new allocator is validated behaviourally in Tasks 2–3.

- [ ] **Step 1: Replace the entire contents of `src/alloc.asm`**

```nasm
%include "syscalls.inc"
global arena_init, arena_alloc, mem_alloc, mem_free

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
```

- [ ] **Step 2: Build**

Run: `make -s clean && make -s all`
Expected: builds cleanly, produces `./asmredis`, no NASM/ld errors.

- [ ] **Step 3: Run the existing wire suite to confirm no regression**

Run: `bash tests/wire.sh`
Expected: all existing checks print `PASS` (banner … no-fd-leak). `mem_alloc`/`mem_free` are unused so far, so behaviour is identical to before.

- [ ] **Step 4: Commit**

```bash
git add src/alloc.asm
git commit -m "alloc: add segregated free-list mem_alloc/mem_free over bump arena"
```

---

## Task 2: Add the failing reclamation stress test

**Files:**
- Create: `tests/reclaim.py`
- Modify: `tests/wire.sh` (append checks after the `no-fd-leak` check, before EOF)

This writes the test that proves reclamation, and confirms it **fails** on the current (non-reclaiming) build — locking in the behaviour Task 3 must produce.

- [ ] **Step 1: Create `tests/reclaim.py`**

```python
#!/usr/bin/env python3
# Minimal RESP client stress-tester for memory reclamation.
# Usage: reclaim.py <port> <overwrite|del|oom>
# Exit 0 on success, 1 on failure (prints a diagnostic).
import socket, sys

VLEN = 16000          # under the 16376 storable cap; lands in the 16384 class
ITERS = 10000         # 10000 * 16000 ~= 160 MB through a 64 MB arena

def connect(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(15)
    return s

class Reader:
    """Buffered reader over a socket for line- and count-based RESP reads."""
    def __init__(self, sock):
        self.s = sock
        self.buf = b""
    def _fill(self):
        chunk = self.s.recv(65536)
        if not chunk:
            raise EOFError("server closed connection")
        self.buf += chunk
    def line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line
    def read_n(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

def resp_cmd(*parts):
    out = b"*%d\r\n" % len(parts)
    for p in parts:
        if isinstance(p, str):
            p = p.encode()
        out += b"$%d\r\n%s\r\n" % (len(p), p)
    return out

def value_for(i):
    # distinct per iteration so a stale value is detectable
    head = b"%08d" % i
    return head + b"x" * (VLEN - len(head))

def read_simple(r):
    # returns the reply line for +OK / -ERR ...
    return r.line()

def read_bulk(r):
    hdr = r.line()                 # $<len>
    assert hdr[:1] == b"$", hdr
    n = int(hdr[1:])
    if n < 0:
        return None
    data = r.read_n(n)
    r.read_n(2)                    # trailing CRLF
    return data

def mode_overwrite(port):
    s = connect(port); r = Reader(s)
    for i in range(ITERS):
        s.sendall(resp_cmd("SET", "rk", value_for(i)))
        rep = read_simple(r)
        if rep != b"+OK":
            print("FAIL overwrite iter %d: SET replied %r" % (i, rep)); return 1
    s.sendall(resp_cmd("GET", "rk"))
    got = read_bulk(r)
    want = value_for(ITERS - 1)
    if got != want:
        print("FAIL overwrite: final GET mismatch (got head %r want head %r, "
              "len %s)" % (got[:8] if got else got, want[:8], len(got) if got else None))
        return 1
    print("OK overwrite: %d overwrites reclaimed, final value correct" % ITERS)
    return 0

def mode_del(port):
    s = connect(port); r = Reader(s)
    for i in range(ITERS):
        s.sendall(resp_cmd("SET", "dk", value_for(i)))
        rep = read_simple(r)
        if rep != b"+OK":
            print("FAIL del iter %d: SET replied %r" % (i, rep)); return 1
        s.sendall(resp_cmd("DEL", "dk"))
        d = r.line()
        if d != b":1":
            print("FAIL del iter %d: DEL replied %r" % (i, d)); return 1
    print("OK del: %d SET/DEL cycles reclaimed, no OOM" % ITERS)
    return 0

def mode_oom(port):
    # Distinct keys with no reclamation must eventually exhaust the 64 MB arena
    # and produce an -ERR out of memory reply.
    s = connect(port); r = Reader(s)
    saw_oom = False
    for i in range(6000):          # ~6000 * ~16 KB > 64 MB
        s.sendall(resp_cmd("SET", "k%d" % i, value_for(i)))
        rep = read_simple(r)
        if rep == b"+OK":
            continue
        if rep.startswith(b"-ERR out of memory"):
            saw_oom = True
            break
        print("FAIL oom iter %d: unexpected reply %r" % (i, rep)); return 1
    if not saw_oom:
        print("FAIL oom: filled arena without any -ERR out of memory reply"); return 1
    print("OK oom: arena exhaustion reported as -ERR out of memory")
    return 0

def main():
    if len(sys.argv) != 3:
        print("usage: reclaim.py <port> <overwrite|del|oom>"); return 2
    port = int(sys.argv[1]); mode = sys.argv[2]
    fn = {"overwrite": mode_overwrite, "del": mode_del, "oom": mode_oom}.get(mode)
    if fn is None:
        print("unknown mode %r" % mode); return 2
    try:
        return fn(port)
    except (EOFError, socket.timeout, AssertionError) as e:
        print("FAIL %s: %r" % (mode, e)); return 1

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Append the reclamation checks to `tests/wire.sh`**

Add these blocks at the end of the file (after the `no-fd-leak` check on line 134):

```bash

# --- Milestone B: overwrite reclamation (10k x 16KB through a 64MB arena) ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 overwrite >/tmp/asmb_ow.txt 2>&1; then
  echo "PASS reclaim-overwrite"; ow=0
else
  echo "FAIL reclaim-overwrite: $(cat /tmp/asmb_ow.txt)"; ow=1
fi
kill $SRV 2>/dev/null

# --- Milestone B: SET/DEL reclamation (10k cycles, no OOM) ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 del >/tmp/asmb_del.txt 2>&1; then
  echo "PASS reclaim-del"; dl=0
else
  echo "FAIL reclaim-del: $(cat /tmp/asmb_del.txt)"; dl=1
fi
kill $SRV 2>/dev/null

# --- Milestone B: arena exhaustion is reported as -ERR out of memory ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 oom >/tmp/asmb_oom.txt 2>&1; then
  echo "PASS oom-error"; oo=0
else
  echo "FAIL oom-error: $(cat /tmp/asmb_oom.txt)"; oo=1
fi
kill $SRV 2>/dev/null

[ $((ow + dl + oo)) -eq 0 ] || exit 1
```

- [ ] **Step 3: Run the three new checks against the CURRENT build to confirm they fail**

Run: `bash tests/wire.sh`
Expected: the pre-existing checks still `PASS`, but the new checks **FAIL** on this non-reclaiming build:
- `FAIL reclaim-overwrite` — the arena fills after ~4000 overwrites; later SETs currently reply `+OK` while storing nothing (the milestone-A bug), so the final `GET` returns a stale value → mismatch.
- `FAIL reclaim-del` — after the arena fills, some SET no-longer-stores (or, post-Task-4, OOMs), so a later `DEL` replies `:0` instead of `:1`.
- `FAIL oom-error` — `cmd_set` currently always replies `+OK`, so no `-ERR out of memory` ever appears.

(The script exits non-zero. That is the expected "red" state for this task.)

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/reclaim.py tests/wire.sh
git commit -m "test: reclamation + OOM stress (red: current build leaks/never OOMs)"
```

---

## Task 3: Wire the keyspace to `mem_alloc`/`mem_free`

**Files:**
- Modify: `src/keyspace.asm`

Switch all allocations to `mem_alloc` and free reclaimed blocks on DEL, on overwrite (old value), and on a failed insert (partial rollback). This makes `reclaim-overwrite` and `reclaim-del` pass.

- [ ] **Step 1: Update the `extern` line**

Change line 3 from:

```nasm
extern arena_alloc, memcmp_n, fnv1a
```

to:

```nasm
extern mem_alloc, mem_free, memcmp_n, fnv1a
```

- [ ] **Step 2: Point `_copy_arena` at `mem_alloc`**

In `_copy_arena`, change the allocation call from `call arena_alloc` to `call mem_alloc`. The function becomes:

```nasm
; _copy_arena(rdi=src, rsi=len) -> rax = copied buf (>= len, class-sized), or 0 oom
_copy_arena:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes even -> align for the call
    mov     rbx, rdi                ; src
    mov     r12, rsi                ; len
    mov     rdi, rsi                ; size to alloc
    call    mem_alloc               ; rax=dest (rounded up to a size class)
    test    rax, rax
    je      .oom
    mov     rdi, rax                ; dest
    mov     rsi, rbx                ; src
    mov     rcx, r12                ; len
    rep     movsb                   ; rax (dest base) untouched by movsb
.oom:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 3: Replace `ks_set` with the mem_alloc/mem_free version**

Replace the whole `ks_set` function (lines 95–161) with:

```nasm
; ks_set(rdi=key, rsi=len, rdx=val, rcx=vlen) -> rax=0 ok, 1 oom
ks_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at internal calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    mov     r14, rdx                ; val
    mov     r15, rcx                ; vlen
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    test    rax, rax
    je      .insert
    ; --- overwrite: alloc new value first, only then free the old one ---
    mov     rbx, rax                ; entry
    mov     rdi, r14                ; new val
    mov     rsi, r15                ; new vlen
    call    _copy_arena             ; rax = new value block
    test    rax, rax
    je      .oom                    ; nothing freed/changed; old value intact
    mov     r14, rax                ; stash new block (val src no longer needed)
    mov     rdi, [rbx+24]           ; old val_ptr
    mov     rsi, [rbx+32]           ; old val_len
    call    mem_free                ; reclaim old value's block
    mov     [rbx+24], r14           ; val_ptr = new block
    mov     [rbx+32], r15           ; val_len = new len
    jmp     .ok
.insert:
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena             ; copy key
    test    rax, rax
    je      .oom                    ; nothing allocated yet
    mov     rbx, rax                ; key copy
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena             ; copy val
    test    rax, rax
    je      .oom_free_key
    mov     r14, rax                ; reuse r14 = val copy
    mov     rdi, 40
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_keyval
    mov     [rax+8], rbx            ; key_ptr
    mov     [rax+16], r13           ; key_len
    mov     [rax+24], r14           ; val_ptr
    mov     [rax+32], r15           ; val_len
    ; prepend: entry->next = *head; *head = entry
    mov     rbx, rax                ; save entry
    mov     rdi, r12
    mov     rsi, r13
    call    _bucket_index           ; rax=&head
    mov     rcx, [rax]              ; old head
    mov     [rbx], rcx              ; entry->next = old head
    mov     [rax], rbx              ; *head = entry
.ok:
    xor     rax, rax
    jmp     .ret
.oom_free_keyval:
    mov     rdi, r14                ; val copy
    mov     rsi, r15                ; vlen
    call    mem_free
.oom_free_key:
    mov     rdi, rbx                ; key copy
    mov     rsi, r13                ; klen
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
```

- [ ] **Step 4: Free the unlinked entry, key, and value in `ks_del`**

Replace the match arm in `ks_del`. Change the block starting at `; match: *slot = entry->next` so that after unlinking it frees all three blocks (freeing the entry last, after reading its key/value fields):

```nasm
    ; match: unlink then reclaim the entry's three blocks
    mov     rcx, [rbx]              ; entry->next
    mov     [r14], rcx              ; *slot = entry->next
    mov     rdi, [rbx+24]           ; val_ptr
    mov     rsi, [rbx+32]           ; val_len
    call    mem_free
    mov     rdi, [rbx+8]            ; key_ptr
    mov     rsi, [rbx+16]           ; key_len
    call    mem_free
    mov     rdi, rbx                ; entry block
    mov     rsi, 40
    call    mem_free
    mov     rax, 1
    jmp     .ret
```

(The surrounding `ks_del` prologue already does 4 pushes + `sub rsp, 8`, so `rsp%16==0` at these `mem_free` calls. `rbx`/`r12`/`r13`/`r14` are callee-saved and survive the calls.)

- [ ] **Step 5: Build**

Run: `make -s clean && make -s all`
Expected: builds cleanly, no errors.

- [ ] **Step 6: Run the wire suite**

Run: `bash tests/wire.sh`
Expected: all pre-existing checks `PASS`; `reclaim-overwrite` and `reclaim-del` now `PASS`. `oom-error` still `FAIL`s (fixed in Task 4) — the script exits non-zero, which is expected until Task 4.

To confirm just the two reclamation checks in isolation:
Run: `./asmredis 7777 & SRV=$!; sleep 0.3; python3 tests/reclaim.py 7777 overwrite; python3 tests/reclaim.py 7777 del; kill $SRV`
Expected: both print `OK ...` and exit 0.

- [ ] **Step 7: Commit**

```bash
git add src/keyspace.asm
git commit -m "keyspace: reclaim memory on DEL and SET-overwrite via mem_free"
```

---

## Task 4: `cmd_set` replies `-ERR out of memory` on OOM

**Files:**
- Modify: `src/dispatch.asm`

- [ ] **Step 1: Add the OOM error string to the `.rodata` block**

In the `section .rodata` block (after `lc_echo:` on line 29), add:

```nasm
m_oom:      db "-ERR out of memory", 13, 10
m_oom_len   equ $ - m_oom
```

- [ ] **Step 2: Branch `cmd_set` on `ks_set`'s return**

Replace the body of `cmd_set` between the `call ks_set` line and the `.wa:` label (lines 131–136) so the success path is guarded and an OOM path is added:

```nasm
    call    ks_set                      ; rax=0 ok, 1 oom
    test    rax, rax
    jnz     .oom
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    add     rsp, 8
    ret
.oom:
    lea     rdi, [rel m_oom]            ; "-ERR out of memory\r\n" (raw, already framed)
    mov     rsi, m_oom_len
    call    append_raw
    add     rsp, 8
    ret
```

(`append_raw` is already `extern`'d at the top of `dispatch.asm`. At `.oom`, `rsp%16==0` — the `sub rsp,8` in the `cmd_set` prologue aligned the call sites — so the `call append_raw` is aligned.)

- [ ] **Step 3: Build**

Run: `make -s clean && make -s all`
Expected: builds cleanly.

- [ ] **Step 4: Run the full wire suite — everything green now**

Run: `bash tests/wire.sh`
Expected: **all** checks `PASS`, including `reclaim-overwrite`, `reclaim-del`, and `oom-error`. The script exits 0.

- [ ] **Step 5: Spot-check the OOM reply shape against valkey for a normal SET (must be unchanged)**

Run: `./asmredis 7777 & SRV=$!; sleep 0.3; printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n' | nc -q1 127.0.0.1 7777 | xxd -p; kill $SRV`
Expected: `2b4f4b0d0a` (`+OK\r\n`) — the success path is byte-identical to before.

- [ ] **Step 6: Commit**

```bash
git add src/dispatch.asm
git commit -m "dispatch: SET replies -ERR out of memory when the arena is exhausted"
```

---

## Task 5: Re-run the full benchmark sweep and document results

**Files:**
- Modify: `docs/benchmark.md` (append a "Milestone B (reclamation)" section)

- [ ] **Step 1: Confirm a fully clean build and green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: build clean; every check `PASS`.

- [ ] **Step 2: Run the sweep (median-of-3, both payloads, -c 1..500) against asmredis and valkey**

Use the same methodology as the milestone-C section already in `docs/benchmark.md`: for each of `-c 1 20 50 100 200 500` and each payload `-d 3` and `-d 512`, run `valkey-benchmark -t set,get` three times and take the median, capturing min/p50/p75/p95/p99/max/avg. Run asmredis on port 7777 and valkey-server on port 7778.

A convenience runner (adjust `-n` to match the existing section's request counts):

```bash
./asmredis 7777 & A=$!
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk.log --dir /tmp
sleep 0.3
for d in 3 512; do
  for c in 1 20 50 100 200 500; do
    echo "=== d=$d c=$c asmredis ==="; valkey-benchmark -p 7777 -t set,get -d $d -c $c -n 100000 -q
    echo "=== d=$d c=$c valkey  ==="; valkey-benchmark -p 7778 -t set,get -d $d -c $c -n 100000 -q
  done
done
kill $A; valkey-cli -p 7778 shutdown nosave
```

Expected: throughput within the same envelope as milestone C (the alloc/free fast path is a few instructions with no syscalls; no throughput regression). Note any deviation.

- [ ] **Step 3: Append a "Milestone B (reclamation)" section to `docs/benchmark.md`**

Add a new dated section mirroring the milestone-C table format (percentile columns, both payloads, `-c 1..500`, median of 3), plus a one-paragraph note: reclamation added an O(1) segregated free-list alloc/free with no syscalls on the hot path; compare asmredis-vs-valkey and milestone-C-vs-milestone-B throughput; confirm no regression.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-B reclamation benchmark sweep (no throughput regression)"
```

---

## Self-Review (completed)

- **Spec coverage:** allocator with 12 size-class free lists → Task 1; keyspace frees on DEL, overwrite (alloc-new-first), and insert-failure rollback → Task 3; `cmd_set` OOM reply `-ERR out of memory` → Task 4; reclamation + OOM tests → Task 2; regression suite → Tasks 1/3/4; benchmark re-run → Task 5. All spec sections mapped.
- **Placeholder scan:** every code step contains complete NASM/Python/bash; no TBD/"handle edge cases"/"similar to".
- **Type/label consistency:** `mem_alloc(rdi=size)->rax`, `mem_free(rdi=ptr,rsi=size)`, `_size_class(rdi)->rax=class,rdx=index`, `free_lists` (12 qwords), `m_oom`/`m_oom_len` are used identically across Tasks 1/3/4. Entry offsets (`+8` key_ptr, `+16` key_len, `+24` val_ptr, `+32` val_len, size 40) match `keyspace.asm`. Stack-alignment notes (`rsp%16==0` at every `call`) verified per function against existing prologues.
