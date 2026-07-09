# Milestone D — Incremental Rehashing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed 1024-bucket hashtable with an incremental, grow-only Redis-style dict (two tables + migration cursor) so lookups stay ~O(1) as the keyspace grows, without ever pausing the event loop for a bulk rehash.

**Architecture:** `keyspace.asm` holds a two-table dict (`ht0`/`ht1`, per-table size/mask/used, plus a signed `rehashidx`). Bucket arrays are dedicated `mmap`s (separate from the value arena) allocated via new `table_alloc`/`table_free` in `alloc.asm`. Every `ks_get`/`ks_set`/`ks_del` runs one `_rehash_step` (migrate one bucket), searches both tables while a resize is live, and routes new keys to the destination table. Initial size 4, grow at load factor 1.

**Tech Stack:** x86-64 NASM (elf64), static no-libc ELF, raw Linux syscalls. Black-box tests in bash (`tests/wire.sh`) + a Python RESP client.

**Reference design:** `docs/superpowers/specs/2026-07-09-asmredis-milestone-d-rehashing-design.md`

---

## File Structure

- `include/syscalls.inc` — **modify**: add `SYS_munmap`, `DICT_INITIAL`, `REHASH_MAX_EMPTY`; remove the now-dead `NBUCKETS`/`BUCKET_MASK` (in Task 3, once nothing references them).
- `src/alloc.asm` — **modify**: add `table_alloc`/`table_free` (mmap/munmap of bucket arrays). Value allocator untouched.
- `src/keyspace.asm` — **rewrite**: dict state + `ks_init`, `_rehash_step`, `_maybe_expand`, `_chain_find`, `_find`, `_insert_entry`, `_del_in_table`, and rewritten `ks_get`/`ks_set`/`ks_del`. Drops `_bucket_index`.
- `src/main.asm` — **modify**: call `ks_init` at startup; drop the static `buckets` array.
- `tests/rehash.py` — **create**: 50 K-key correctness stress across many resizes.
- `tests/wire.sh` — **modify**: one new `rehash-correctness` check.
- `docs/benchmark.md` — **modify** (Task 4): append a Milestone-D sweep.

**ABI invariant enforced throughout:** every function is *entered* at `rsp%16==8`; each internal `call` must execute at `rsp%16==0`. Each function below is annotated with its push/`sub rsp,8` sequence to guarantee this. Entry layout unchanged (40 B: `[0]=next [8]=key_ptr [16]=key_len [24]=val_ptr [32]=val_len`).

---

## Task 1: Allocator + constants for bucket-array storage

**Files:**
- Modify: `include/syscalls.inc`
- Modify: `src/alloc.asm`

Purely additive. `table_alloc`/`table_free` are new symbols not yet called, so the build and all existing tests stay green.

- [ ] **Step 1: Add constants to `include/syscalls.inc`**

In the syscall-numbers block (near `SYS_mmap 9`), add:

```nasm
%define SYS_munmap      11
```

In the `; ---- tunables ----` block (near `NBUCKETS`), add:

```nasm
%define DICT_INITIAL     4          ; initial hashtable buckets (Redis default)
%define REHASH_MAX_EMPTY 10         ; empty buckets skipped per rehash step
```

Do NOT remove `NBUCKETS`/`BUCKET_MASK` yet — `keyspace.asm`/`main.asm` still reference them until Task 3.

- [ ] **Step 2: Add `table_alloc`/`table_free` to `src/alloc.asm`**

Change the `global` line (line 2) from:

```nasm
global arena_init, mem_alloc, mem_free
```

to:

```nasm
global arena_init, mem_alloc, mem_free, table_alloc, table_free
```

Then append these two functions at the end of the file (after `mem_free`):

```nasm

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
```

- [ ] **Step 3: Build**

Run: `make -s clean && make -s all`
Expected: clean build, `./asmredis` produced.

- [ ] **Step 4: Regression — existing suite still green**

Run: `bash tests/wire.sh`
Expected: all existing checks PASS, exit 0 (new symbols unused so far).

- [ ] **Step 5: Commit**

```bash
git add include/syscalls.inc src/alloc.asm
git commit -m "alloc: add table_alloc/table_free (mmap bucket arrays) + rehash constants

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Rehash correctness characterization test

**Files:**
- Create: `tests/rehash.py`
- Modify: `tests/wire.sh`

This test verifies that a large keyspace with many keys stays fully correct — no key lost, duplicated, or misrouted. It **passes on the current fixed-table build** (which is correct, just non-scaling) and must stay green through the Task 3 rewrite; any bug in the two-table migration logic (lost/duplicated key) makes it **fail**. It is the primary guard for the rewrite. The `timeout` wrapper additionally guards that the rewrite's initial-size-4 table actually rehashes (an initial-size-4 table with broken/absent growth would go O(n²) over 50 K keys and time out).

- [ ] **Step 1: Create `tests/rehash.py`**

```python
#!/usr/bin/env python3
# Rehash correctness stress: many distinct keys across many table resizes.
# Usage: rehash.py <port>
# Exit 0 on success, 1 on failure (prints a diagnostic).
import socket, sys

N = 50000          # forces ~13 doublings from an initial size of 4

def connect(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(30)
    return s

class Reader:
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

def read_bulk(r):
    hdr = r.line()
    assert hdr[:1] == b"$", hdr
    n = int(hdr[1:])
    if n < 0:
        return None
    data = r.read_n(n)
    r.read_n(2)
    return data

def key(i):  return b"key:%d" % i
def val(i):  return b"val:%d" % i

def main():
    if len(sys.argv) != 2:
        print("usage: rehash.py <port>"); return 2
    port = int(sys.argv[1])
    try:
        s = connect(port); r = Reader(s)
        # Phase 1: insert N distinct keys. Every ~997 inserts, GET an
        # already-inserted key and verify (some of these land while a rehash
        # is in flight, exercising the both-table lookup path).
        for i in range(N):
            s.sendall(resp_cmd(b"SET", key(i), val(i)))
            if r.line() != b"+OK":
                print("FAIL insert %d: not +OK" % i); return 1
            if i and i % 997 == 0:
                j = i // 2
                s.sendall(resp_cmd(b"GET", key(j)))
                got = read_bulk(r)
                if got != val(j):
                    print("FAIL mid-rehash GET key:%d -> %r" % (j, got)); return 1
        # Phase 2: every key must read back its exact value.
        for i in range(N):
            s.sendall(resp_cmd(b"GET", key(i)))
            got = read_bulk(r)
            if got != val(i):
                print("FAIL verify GET key:%d -> %r (want %r)" % (i, got, val(i)))
                return 1
        # Phase 3: delete every even key; assert :1. Odd keys untouched.
        for i in range(0, N, 2):
            s.sendall(resp_cmd(b"DEL", key(i)))
            if r.line() != b":1":
                print("FAIL DEL key:%d not :1" % i); return 1
        # Phase 4: even keys miss ($-1), odd keys still hold their value.
        for i in range(N):
            s.sendall(resp_cmd(b"GET", key(i)))
            got = read_bulk(r)
            want = None if i % 2 == 0 else val(i)
            if got != want:
                print("FAIL post-del GET key:%d -> %r (want %r)" % (i, got, want))
                return 1
        print("OK rehash: %d keys correct across resizes, del+verify clean" % N)
        return 0
    except (EOFError, OSError, ValueError, AssertionError) as e:
        print("FAIL rehash: %r" % e); return 1

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Append the check to `tests/wire.sh`**

Add this block at the end of the file (after the last existing check, before EOF):

```bash

# --- Milestone D: rehash correctness (50k keys across many resizes) ---
./asmredis 7777 & SRV=$!; sleep 0.3
if timeout 60 python3 tests/rehash.py 7777 >/tmp/asmd_rehash.txt 2>&1; then
  echo "PASS rehash-correctness"; rh=0
else
  echo "FAIL rehash-correctness: $(cat /tmp/asmd_rehash.txt)"; rh=1
fi
kill $SRV 2>/dev/null

[ $rh -eq 0 ] || exit 1
```

- [ ] **Step 3: Confirm GREEN on the current (fixed-table) build**

```bash
make -s all
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 60 python3 tests/rehash.py 7777; echo "rehash exit=$?"
kill $SRV 2>/dev/null
```
Expected: prints `OK rehash: 50000 keys correct across resizes, del+verify clean`, exit 0. (The current fixed 1024-bucket table is correct — chains ~49 deep — so this passes and completes well under 60 s. This establishes the baseline the rewrite must preserve.)

- [ ] **Step 4: Commit**

```bash
git add tests/rehash.py tests/wire.sh
git commit -m "test: rehash correctness stress (50k keys, resize-crossing lookups/deletes)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Rewrite the keyspace as an incremental dict

**Files:**
- Modify: `src/keyspace.asm` (full rewrite — content below)
- Modify: `src/main.asm` (call `ks_init`; drop static `buckets`)
- Modify: `include/syscalls.inc` (drop dead `NBUCKETS`/`BUCKET_MASK`)

This is the core task. All assembly is given verbatim — place it exactly and verify the build + tests. If the build fails or a test other than expected regresses, debug; if stuck, report BLOCKED with the exact error.

- [ ] **Step 1: Replace the ENTIRE contents of `src/keyspace.asm` with:**

```nasm
%include "syscalls.inc"
global ks_init, ks_get, ks_set, ks_del
extern mem_alloc, mem_free, memcmp_n, fnv1a
extern table_alloc, table_free

; Hashtable entry layout (40 bytes):
;   [0]=next_ptr  [8]=key_ptr  [16]=key_len  [24]=val_ptr  [32]=val_len
;
; Incremental (Redis-style) dict. Two tables held as index-[0]/[1] arrays so the
; finish-swap is a field copy. rehashidx = -1 when idle, else the next ht[0]
; bucket to migrate into ht[1]. New keys go to ht[1] during a resize; migration
; only moves ht[0]->ht[1], so every key lives in exactly one table.

section .bss
ht_table:  resq 2      ; bucket-array pointer per table (0 when unused)
ht_size:   resq 2      ; nbuckets (power of two)
ht_mask:   resq 2      ; nbuckets - 1
ht_used:   resq 2      ; live entry count
rehashidx: resq 1      ; -1 idle; else next ht[0] bucket index to migrate

section .text

; ks_init: allocate the initial ht[0] (DICT_INITIAL buckets); exit(1) on failure.
; .bss is zeroed, so ht[1] and used[] start at 0; rehashidx MUST be set to -1.
ks_init:
    push    rbx                     ; entry rsp%16==8 -> 0 (call aligned)
    mov     rdi, DICT_INITIAL
    call    table_alloc             ; rax = bucket array or 0
    test    rax, rax
    jz      .fail
    lea     rbx, [rel ht_table]
    mov     [rbx], rax              ; ht_table[0]
    lea     rbx, [rel ht_size]
    mov     qword [rbx], DICT_INITIAL
    lea     rbx, [rel ht_mask]
    mov     qword [rbx], DICT_INITIAL-1
    lea     rbx, [rel rehashidx]
    mov     qword [rbx], -1
    pop     rbx
    ret
.fail:
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; _rehash_step: if a rehash is in flight, migrate one non-empty ht[0] bucket into
; ht[1] (skipping up to REHASH_MAX_EMPTY empty buckets), advance rehashidx, and
; finish+swap when ht[0] is drained. No-op when idle. Clobbers caller-saved regs.
_rehash_step:
    mov     rax, [rel rehashidx]
    test    rax, rax
    js      .done                   ; rehashidx < 0 -> idle
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes (entry 8) -> rsp%16==0 at calls
    mov     r12d, REHASH_MAX_EMPTY  ; empty-skip budget
    lea     r13, [rel ht_table]
    mov     r13, [r13]              ; ht_table[0] base
    lea     r14, [rel ht_size]
    mov     r14, [r14]              ; ht_size[0]
.scan:
    mov     rbx, [rel rehashidx]
    cmp     rbx, r14
    jae     .finish                 ; drained -> finish+swap
    mov     r15, [r13 + rbx*8]      ; head = ht_table[0][rehashidx]
    test    r15, r15
    jnz     .migrate
    inc     rbx
    mov     [rel rehashidx], rbx
    dec     r12
    jnz     .scan
    jmp     .epi                    ; skip budget spent -> resume next op
.migrate:
    ; move every entry in this bucket to ht[1] (recompute each hash)
.mloop:
    test    r15, r15
    je      .mdone
    mov     r12, [r15]              ; next (skip budget dead once migrating)
    mov     rdi, [r15+8]            ; key_ptr
    mov     rsi, [r15+16]           ; key_len
    call    fnv1a                   ; rax = hash
    lea     rcx, [rel ht_mask]
    and     rax, [rcx+8]            ; h & ht_mask[1]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx+8]            ; ht_table[1] base
    lea     rcx, [rcx + rax*8]      ; &ht_table[1][idx1]
    mov     rdx, [rcx]              ; old head1
    mov     [r15], rdx              ; entry->next = old head1
    mov     [rcx], r15              ; head1 = entry
    lea     rdx, [rel ht_used]
    dec     qword [rdx]             ; ht_used[0]--
    inc     qword [rdx+8]           ; ht_used[1]++
    mov     r15, r12                ; entry = next
    jmp     .mloop
.mdone:
    xor     rax, rax
    mov     [r13 + rbx*8], rax      ; ht_table[0][rehashidx] = 0
    inc     rbx
    mov     [rel rehashidx], rbx
    cmp     rbx, r14
    jae     .finish
    jmp     .epi
.finish:
    lea     rax, [rel ht_table]
    mov     rdi, [rax]              ; old ht[0] array
    mov     rsi, r14                ; ht_size[0]
    call    table_free              ; munmap
    lea     rax, [rel ht_table]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx            ; ht_table: [0]=[1], [1]=0
    lea     rax, [rel ht_size]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    lea     rax, [rel ht_mask]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    lea     rax, [rel ht_used]
    mov     rcx, [rax+8]
    mov     [rax], rcx
    xor     rcx, rcx
    mov     [rax+8], rcx
    mov     qword [rel rehashidx], -1
.epi:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.done:
    ret

; _maybe_expand: if idle and ht_used[0] >= ht_size[0] (load factor 1), start a
; rehash by allocating ht[1] = 2*ht_size[0]. On alloc failure, stay idle (serve
; at LF>1). Never called while already rehashing changes anything (guarded).
_maybe_expand:
    mov     rax, [rel rehashidx]
    test    rax, rax
    jns     .done                   ; already rehashing -> nothing
    lea     rcx, [rel ht_used]
    mov     rax, [rcx]              ; ht_used[0]
    lea     rcx, [rel ht_size]
    cmp     rax, [rcx]              ; used[0] >= size[0] ?
    jb      .done
    push    rbx                     ; entry 8 -> 0 (call aligned)
    lea     rcx, [rel ht_size]
    mov     rbx, [rcx]              ; size0
    lea     rdi, [rbx + rbx]        ; 2*size0
    call    table_alloc             ; rax = new array or 0
    test    rax, rax
    jz      .fail_alloc             ; OOM -> skip expansion, stay idle
    lea     rcx, [rel ht_table]
    mov     [rcx+8], rax            ; ht_table[1]
    lea     rcx, [rel ht_size]
    lea     rdx, [rbx + rbx]        ; 2*size0
    mov     [rcx+8], rdx            ; ht_size[1]
    lea     rcx, [rel ht_mask]
    dec     rdx                     ; 2*size0 - 1
    mov     [rcx+8], rdx            ; ht_mask[1]
    lea     rcx, [rel ht_used]
    mov     qword [rcx+8], 0        ; ht_used[1] = 0
    mov     qword [rel rehashidx], 0 ; begin migrating at bucket 0
.fail_alloc:
    pop     rbx
.done:
    ret

; _chain_find(rax=head entry, r12=key, r13=len) -> rax=entry|0. Walks one chain.
; Clobbers rbx,rcx,rdx,rsi,rdi; preserves r12,r13,r14,r15.
_chain_find:
    push    rbx                     ; entry 8 -> 0 (call aligned)
.walk:
    test    rax, rax
    je      .none
    mov     rcx, [rax+16]           ; entry->key_len
    cmp     rcx, r13
    jne     .next
    mov     rbx, rax                ; save entry across memcmp
    mov     rdi, r12                ; search key
    mov     rsi, [rax+8]            ; stored key
    mov     rdx, r13                ; len
    call    memcmp_n                ; rax=0 if equal
    test    rax, rax
    mov     rax, rbx                ; restore entry (mov preserves flags)
    je      .found
.next:
    mov     rax, [rax]              ; entry = entry->next
    jmp     .walk
.none:
    xor     rax, rax
.found:
    pop     rbx
    ret

; _find(rdi=key, rsi=len) -> rax=entry|0. Hash once; search ht[0], then ht[1]
; while a rehash is in flight.
_find:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; len
    call    fnv1a                   ; rax = hash
    mov     r14, rax                ; save hash
    lea     rcx, [rel ht_mask]
    mov     rax, r14
    and     rax, [rcx]              ; h & ht_mask[0]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx]              ; ht_table[0]
    mov     rax, [rcx + rax*8]      ; head0
    call    _chain_find
    test    rax, rax
    jnz     .done
    mov     rcx, [rel rehashidx]
    test    rcx, rcx
    js      .miss                   ; idle -> only ht[0]
    lea     rcx, [rel ht_mask]
    mov     rax, r14
    and     rax, [rcx+8]            ; h & ht_mask[1]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx+8]            ; ht_table[1]
    mov     rax, [rcx + rax*8]      ; head1
    call    _chain_find
    test    rax, rax
    jnz     .done
.miss:
    xor     rax, rax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; _insert_entry(rdi=entry, rsi=key, rdx=len): prepend entry into ht[1] while
; rehashing else ht[0], at bucket h&mask; bump that table's used count.
_insert_entry:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at call
    mov     rbx, rdi                ; entry
    mov     rdi, rsi                ; key
    mov     rsi, rdx                ; len
    call    fnv1a                   ; rax = hash
    xor     r12, r12                ; t = 0
    mov     rcx, [rel rehashidx]
    test    rcx, rcx
    js      .have_t                 ; idle -> t=0
    mov     r12d, 1                 ; rehashing -> t=1
.have_t:
    lea     rcx, [rel ht_mask]
    and     rax, [rcx + r12*8]      ; h & ht_mask[t]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx + r12*8]      ; ht_table[t]
    lea     rcx, [rcx + rax*8]      ; &ht_table[t][idx]
    mov     rdx, [rcx]              ; old head
    mov     [rbx], rdx              ; entry->next = old head
    mov     [rcx], rbx              ; head = entry
    lea     rcx, [rel ht_used]
    inc     qword [rcx + r12*8]     ; ht_used[t]++
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; _del_in_table(r12=key, r13=len, r14=hash, r15=table index t) -> rax=1 if the
; key was found (unlinked, its 3 blocks freed, ht_used[t]--), else 0.
_del_in_table:
    push    rbx
    push    rbp
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at calls
    mov     rax, r14
    lea     rcx, [rel ht_mask]
    and     rax, [rcx + r15*8]      ; h & ht_mask[t]
    lea     rcx, [rel ht_table]
    mov     rcx, [rcx + r15*8]      ; ht_table[t]
    lea     rbp, [rcx + rax*8]      ; slot = &head
.loop:
    mov     rbx, [rbp]              ; entry = *slot
    test    rbx, rbx
    je      .notfound
    mov     rcx, [rbx+16]           ; key_len
    cmp     rcx, r13
    jne     .adv
    mov     rdi, r12
    mov     rsi, [rbx+8]            ; stored key
    mov     rdx, r13
    call    memcmp_n
    test    rax, rax
    jne     .adv
    mov     rcx, [rbx]              ; entry->next
    mov     [rbp], rcx              ; *slot = next
    mov     rdi, [rbx+24]           ; val_ptr
    mov     rsi, [rbx+32]           ; val_len
    call    mem_free
    mov     rdi, [rbx+8]            ; key_ptr
    mov     rsi, [rbx+16]           ; key_len
    call    mem_free
    mov     rdi, rbx                ; entry block
    mov     rsi, 40
    call    mem_free
    lea     rcx, [rel ht_used]
    dec     qword [rcx + r15*8]     ; ht_used[t]--
    mov     rax, 1
    jmp     .ret
.adv:
    mov     rbp, rbx                ; slot = &entry->next (next at offset 0)
    jmp     .loop
.notfound:
    xor     rax, rax
.ret:
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret

; ks_get(rdi=key, rsi=len) -> rax=val_ptr(0 miss), rdx=val_len
ks_get:
    push    r12
    push    r13
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at calls
    mov     r12, rdi                ; key (survive _rehash_step)
    mov     r13, rsi                ; len
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    add     rsp, 8
    pop     r13
    pop     r12
    test    rax, rax
    je      .miss
    mov     rdx, [rax+32]           ; val_len
    mov     rax, [rax+24]           ; val_ptr
    ret
.miss:
    xor     rax, rax
    xor     rdx, rdx
    ret

; _copy_arena(rdi=src, rsi=len) -> rax = copied buf (>= len, class-sized), or 0.
_copy_arena:
    push    rbx
    push    r12
    sub     rsp, 8                  ; 2 pushes + 8 -> aligned
    mov     rbx, rdi                ; src
    mov     r12, rsi                ; len
    mov     rdi, rsi                ; size to alloc
    call    mem_alloc
    test    rax, rax
    je      .oom
    mov     rdi, rax                ; dest
    mov     rsi, rbx                ; src
    mov     rcx, r12                ; len
    rep     movsb
.oom:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; ks_set(rdi=key, rsi=len, rdx=val, rcx=vlen) -> rax=0 ok, 1 oom
ks_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    mov     r14, rdx                ; val
    mov     r15, rcx                ; vlen
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    test    rax, rax
    je      .insert
    ; overwrite: alloc new value first, then free old
    mov     rbx, rax                ; entry
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena
    test    rax, rax
    je      .oom                    ; old value intact
    mov     r14, rax                ; new value block
    mov     rdi, [rbx+24]           ; old val_ptr
    mov     rsi, [rbx+32]           ; old val_len
    call    mem_free
    mov     [rbx+24], r14
    mov     [rbx+32], r15
    jmp     .ok
.insert:
    call    _maybe_expand           ; may start a rehash before we route
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena             ; copy key
    test    rax, rax
    je      .oom
    mov     rbx, rax                ; key copy
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena             ; copy val
    test    rax, rax
    je      .oom_free_key
    mov     r14, rax                ; val copy
    mov     rdi, 40
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_keyval
    mov     [rax+8], rbx            ; key_ptr
    mov     [rax+16], r13           ; key_len
    mov     [rax+24], r14           ; val_ptr
    mov     [rax+32], r15           ; val_len
    mov     rdi, rax                ; entry
    mov     rsi, r12                ; key
    mov     rdx, r13                ; len
    call    _insert_entry           ; prepend into ht[0] or ht[1], used++
.ok:
    xor     rax, rax
    jmp     .ret
.oom_free_keyval:
    mov     rdi, r14
    mov     rsi, r15
    call    mem_free
.oom_free_key:
    mov     rdi, rbx
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

; ks_del(rdi=key, rsi=len) -> rax=1 deleted, 0 absent
ks_del:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    fnv1a
    mov     r14, rax                ; hash
    xor     r15, r15                ; t = 0
    call    _del_in_table
    test    rax, rax
    jnz     .deleted
    mov     rax, [rel rehashidx]
    test    rax, rax
    js      .absent                 ; idle -> only ht[0]
    mov     r15d, 1                 ; t = 1
    call    _del_in_table
    test    rax, rax
    jnz     .deleted
.absent:
    xor     rax, rax
    jmp     .ret
.deleted:
    mov     rax, 1
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 2: Update `src/main.asm` — call `ks_init`, drop the static bucket array**

Add `ks_init` to the externs. Change:

```nasm
extern net_serve
extern atoi_port
extern arena_init
```

to:

```nasm
extern net_serve
extern atoi_port
extern arena_init
extern ks_init
```

Change the `.have_port` block from:

```nasm
.have_port:
    push    rdi                  ; preserve port across arena_init
    call    arena_init           ; mmap the keyspace arena
    pop     rdi
    call    net_serve            ; never returns
```

to (the `sub rsp,8`/`add rsp,8` keeps the two inner `call`s 16-aligned now that there are two of them):

```nasm
.have_port:
    push    rdi                  ; preserve port across init calls
    sub     rsp, 8               ; keep rsp%16==0 at arena_init/ks_init calls
    call    arena_init           ; mmap the value arena
    call    ks_init              ; mmap the initial hashtable
    add     rsp, 8
    pop     rdi
    call    net_serve            ; never returns
```

Remove the static bucket array — delete these two lines from the `.bss` block at the end:

```nasm
global buckets
buckets:    resq NBUCKETS
```

- [ ] **Step 3: Remove dead constants from `include/syscalls.inc`**

Delete these two lines (nothing references them after Steps 1–2):

```nasm
%define NBUCKETS        1024
%define BUCKET_MASK     1023
```

- [ ] **Step 4: Build**

Run: `make -s clean && make -s all`
Expected: clean build, no NASM/ld errors. (If ld reports an undefined symbol like `buckets` or `BUCKET_MASK`, a reference was missed — grep `grep -rn "buckets\|BUCKET_MASK\|NBUCKETS\|_bucket_index" src/ include/` should return nothing.)

- [ ] **Step 5: Rehash correctness test now green on the rewritten build**

```bash
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 60 python3 tests/rehash.py 7777; echo "rehash exit=$?"
kill $SRV 2>/dev/null
```
Expected: `OK rehash: 50000 keys correct across resizes, del+verify clean`, exit 0. This now runs against an initial-size-4 table that rehashed ~13 times — proving inserts, lookups, and deletes stay correct across (and during) resizes.

- [ ] **Step 6: Full regression suite**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — especially `chain` (middle-of-chain unlink), `conformance` (valkey oracle byte-for-byte), the milestone-B `reclaim-*`/`oom-error`, and the new `rehash-correctness`.

- [ ] **Step 7: Commit**

```bash
git add src/keyspace.asm src/main.asm include/syscalls.inc
git commit -m "keyspace: incremental grow-only rehashing (two-table Redis-style dict)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Benchmark sweep + docs

**Files:**
- Modify: `docs/benchmark.md`

- [ ] **Step 1: Confirm clean build + green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: build clean; every check PASS.

- [ ] **Step 2: Run the sweep (median of 3, both payloads, -c 1..500)**

Same methodology as the milestone-B/C sections in `docs/benchmark.md`. asmredis on 7777, Valkey 9.1.0 oracle on 7778.

```bash
./asmredis 7777 & A=$!
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk.log --dir /tmp
sleep 0.3
for d in 3 512; do
  for c in 1 20 50 100 200 500; do
    for run in 1 2 3; do
      echo "=== d=$d c=$c run=$run asmredis ==="; valkey-benchmark -p 7777 -t set,get -n 100000 -c $c -d $d --precision 3
      echo "=== d=$d c=$c run=$run valkey  ==="; valkey-benchmark -p 7778 -t set,get -n 100000 -c $c -d $d --precision 3
    done
  done
done
kill $A; valkey-cli -p 7778 shutdown nosave
```
Save all raw output; derive each cell (rps, avg, min, p50, p75, p95, p99, max) as the median of the 3 runs, strictly from saved output — do not estimate. Under initial size 4, the insert phase rehashes ~13 times, so this exercises rehashing under load.

- [ ] **Step 3: Append a "Milestone D (incremental rehashing)" section to `docs/benchmark.md`**

Mirror the milestone-C/B table format (both payloads, `-c 1..500`, median of 3). Add a short intro (grow-only two-table dict, one bucket migrated per op, initial size 4) and a "Reading the numbers" paragraph honestly comparing asmredis-D vs the in-run Valkey oracle and vs the milestone-B asmredis figures — confirming the per-op rehash step did not regress throughput. If a regression appears, state it plainly with numbers.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-D incremental rehashing benchmark sweep"
```

---

## Self-Review (completed)

- **Spec coverage:** two-table dict state + init → Task 3 Step 1/2; `mmap` bucket storage → Task 1; incremental one-bucket migration with ≤10 empty skips → `_rehash_step`; grow-at-LF1 with OOM-graceful skip → `_maybe_expand`; both-table lookup → `_find`/`_chain_find`; new-key routing → `_insert_entry`; both-table delete → `_del_in_table`; protocol transparency → guarded by existing `conformance` check; 50 K-key correctness → Task 2; benchmark → Task 4. All spec sections mapped.
- **Placeholder scan:** every code step is complete verbatim NASM/Python/bash; no TBD/"handle edge cases".
- **Type/label consistency:** state symbols `ht_table`/`ht_size`/`ht_mask`/`ht_used`/`rehashidx` used identically across `ks_init`, `_rehash_step`, `_maybe_expand`, `_find`, `_insert_entry`, `_del_in_table`, `ks_get/set/del`. `table_alloc(rdi=nbuckets)->rax`, `table_free(rdi=ptr,rsi=nbuckets)`, `_chain_find(rax=head,r12=key,r13=len)->rax`, `_del_in_table(r12,r13,r14,r15)->rax`. Entry offsets (+8/+16/+24/+32, size 40) unchanged. Stack alignment annotated and checked per function (entry `rsp%16==8`; each `call` at `0`). `rehashidx` treated as signed (`js`/`jns`); explicitly initialized to -1 in `ks_init` (BSS zero would falsely mean "rehashing at bucket 0").
