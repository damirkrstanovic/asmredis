# Milestone E — LIST data type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a doubly-linked LIST type (LPUSH/RPUSH/LPOP/RPOP/LRANGE/LLEN) plus the general machinery every future type needs — a per-entry type tag, WRONGTYPE errors, and type-dispatched value-free — matching Valkey 9.1.0 byte-for-byte.

**Architecture:** A new `src/list.asm` holds the list type (node/header primitives + command handlers). `keyspace.asm` gains a type field on entries (`[40]=type`, still free in the 64-byte class), a type-aware `_free_value`, and two lower-level accessors `ks_lookup`/`ks_insert`. `dispatch.asm` routes the six names and makes `cmd_get` WRONGTYPE-aware. Small additions to `reply.asm`/`errmsg.asm`/`util.asm`/`alloc.asm`.

**Tech Stack:** x86-64 NASM (elf64), static no-libc ELF, raw syscalls. Black-box tests: bash valkey-oracle conformance diff + a Python RESP client.

**Reference design:** `docs/superpowers/specs/2026-07-09-asmredis-milestone-e-list-design.md`

**ABI invariant:** every function entered at `rsp%16==8`; every internal `call` at `rsp%16==0`. Each function below is annotated with its push/`sub rsp,8` accounting. Entry layout: `[0]=next [8]=key_ptr [16]=key_len [24]=val_ptr [32]=val_len [40]=type`.

---

## Task 1: Supporting primitives (reply/errmsg/util/alloc + constants)

**Files:** Modify `include/syscalls.inc`, `src/reply.asm`, `src/errmsg.asm`, `src/util.asm`, `src/alloc.asm`.

Purely additive — new symbols, no caller yet. Build + existing suite stay green.

- [ ] **Step 1: Constants in `include/syscalls.inc`**

In the tunables block add:

```nasm
%define TYPE_STR   0
%define TYPE_LIST  1
%define ENTRY_SZ   48          ; entry incl. type field (still class 64)
```

- [ ] **Step 2: `reply_array_header` in `src/reply.asm`**

Add `reply_array_header` to the `global` line, and append this function (mirrors `reply_int`'s structure exactly — same alignment):

```nasm
reply_array_header:              ; rdi=count -> "*<n>\r\n"
    push    rdi
    mov     r8b, '*'
    call    _put_byte
    pop     rdi
    call    _put_uint
    call    _put_crlf
    ret
```

- [ ] **Step 3: `emit_wrongtype`/`emit_notint`/`emit_oom` in `src/errmsg.asm`**

Add the three names to the `global` line. In `.rodata` add:

```nasm
m_wrongtype:     db "-WRONGTYPE Operation against a key holding the wrong kind of value", 13, 10
m_wrongtype_len  equ $ - m_wrongtype
m_notint:        db "-ERR value is not an integer or out of range", 13, 10
m_notint_len     equ $ - m_notint
m_oom2:          db "-ERR out of memory", 13, 10
m_oom2_len       equ $ - m_oom2
```

In `.text` add (tail-calls to `append_raw`, mirroring `emit_protoerr`):

```nasm
emit_wrongtype:
    lea     rdi, [rel m_wrongtype]
    mov     rsi, m_wrongtype_len
    jmp     append_raw

emit_notint:
    lea     rdi, [rel m_notint]
    mov     rsi, m_notint_len
    jmp     append_raw

emit_oom:
    lea     rdi, [rel m_oom2]
    mov     rsi, m_oom2_len
    jmp     append_raw
```

- [ ] **Step 4: `parse_int` in `src/util.asm`**

Add `parse_int` to the `global` line and append:

```nasm
; parse_int(rdi=ptr, rsi=len) -> rax=value (signed), rdx=1 valid / 0 invalid.
; Signed base-10, optional leading '-'. Rejects empty, "-", non-digits, and
; magnitudes past INT64_MAX. Leaf (no calls).
parse_int:
    test    rsi, rsi
    je      .bad
    xor     r8, r8              ; negative flag
    xor     rax, rax            ; accumulator
    movzx   rcx, byte [rdi]
    cmp     rcx, '-'
    jne     .digits
    mov     r8, 1
    inc     rdi
    dec     rsi
    je      .bad                ; "-" alone
.digits:
    movzx   rcx, byte [rdi]
    sub     rcx, '0'
    cmp     rcx, 9              ; unsigned: catches <'0' (wraps huge) and >'9'
    ja      .bad
    mov     r9, 922337203685477580  ; (2^63-1)/10; guard imul overflow
    cmp     rax, r9
    ja      .bad
    imul    rax, rax, 10
    add     rax, rcx
    js      .bad                ; passed INT64_MAX -> invalid
    inc     rdi
    dec     rsi
    jnz     .digits
    test    r8, r8
    je      .ok
    neg     rax
.ok:
    mov     rdx, 1
    ret
.bad:
    xor     rax, rax
    xor     rdx, rdx
    ret
```

- [ ] **Step 5: `mem_dup` in `src/alloc.asm`**

Add `mem_dup` to the `global` line and append after `mem_free`:

```nasm
; mem_dup(rdi=src, rsi=len) -> rax=copy or 0 (OOM). mem_alloc(len) + copy len bytes.
; len 0 yields a valid non-null 8-byte block (copies nothing).
mem_dup:
    push    rbx
    push    r12
    sub     rsp, 8              ; 2 pushes + 8 -> rsp%16==0 at call
    mov     rbx, rdi            ; src
    mov     r12, rsi            ; len
    mov     rdi, rsi            ; size
    call    mem_alloc
    test    rax, rax
    je      .done
    mov     rdi, rax            ; dest
    mov     rsi, rbx            ; src
    mov     rcx, r12            ; len
    rep     movsb               ; rax (dest base) preserved
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 6: Build + regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build; all existing checks PASS, exit 0 (new symbols unused).

- [ ] **Step 7: Commit**

```bash
git add include/syscalls.inc src/reply.asm src/errmsg.asm src/util.asm src/alloc.asm
git commit -m "primitives: array-header reply, WRONGTYPE/notint/oom errors, parse_int, mem_dup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `src/list.asm` — list data-structure primitives

**Files:** Create `src/list.asm`.

Pure header/node operations, no keyspace dependency. Unused so far (handlers come in Task 5), so build + existing suite stay green. The Makefile globs `src/*.asm`, so the new file is picked up automatically.

- [ ] **Step 1: Create `src/list.asm`**

```nasm
%include "syscalls.inc"
global list_new, list_push_head, list_push_tail
global list_pop_head, list_pop_tail, list_free
extern mem_alloc, mem_free, mem_dup

; header: [0]=head [8]=tail [16]=length          (24 bytes, class 32)
; node:   [0]=prev [8]=next [16]=str_ptr [24]=str_len  (32 bytes, class 32)
%define HDR_SZ   24
%define NODE_SZ  32

section .text

; list_new() -> rax=header or 0 (OOM). Zeroed empty list.
list_new:
    sub     rsp, 8              ; align (entry 8 -> 0)
    mov     rdi, HDR_SZ
    call    mem_alloc
    test    rax, rax
    je      .done
    xor     rcx, rcx
    mov     [rax], rcx          ; head = 0
    mov     [rax+8], rcx        ; tail = 0
    mov     [rax+16], rcx       ; length = 0
.done:
    add     rsp, 8
    ret

; list_push_head(rdi=header, rsi=str_ptr, rdx=str_len) -> rax=0 ok, 1 oom.
list_push_head:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; str_ptr
    mov     r13, rdx            ; str_len
    mov     rdi, r12
    mov     rsi, r13
    call    mem_dup             ; rax = string copy or 0
    test    rax, rax
    je      .oom
    mov     r14, rax            ; string copy
    mov     rdi, NODE_SZ
    call    mem_alloc           ; rax = node or 0
    test    rax, rax
    je      .oom_free_str
    mov     r15, rax            ; node
    mov     [r15+16], r14       ; str_ptr
    mov     [r15+24], r13       ; str_len
    xor     rcx, rcx
    mov     [r15], rcx          ; prev = 0
    mov     rcx, [rbx]          ; old head
    mov     [r15+8], rcx        ; node->next = old head
    test    rcx, rcx
    je      .empty
    mov     [rcx], r15          ; old_head->prev = node
    jmp     .sethead
.empty:
    mov     [rbx+8], r15        ; tail = node
.sethead:
    mov     [rbx], r15          ; head = node
    inc     qword [rbx+16]      ; length++
    xor     rax, rax
    jmp     .ret
.oom_free_str:
    mov     rdi, r14
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

; list_push_tail(rdi=header, rsi=str_ptr, rdx=str_len) -> rax=0 ok, 1 oom.
list_push_tail:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rdi, r12
    mov     rsi, r13
    call    mem_dup
    test    rax, rax
    je      .oom
    mov     r14, rax
    mov     rdi, NODE_SZ
    call    mem_alloc
    test    rax, rax
    je      .oom_free_str
    mov     r15, rax
    mov     [r15+16], r14       ; str_ptr
    mov     [r15+24], r13       ; str_len
    xor     rcx, rcx
    mov     [r15+8], rcx        ; next = 0
    mov     rcx, [rbx+8]        ; old tail
    mov     [r15], rcx          ; node->prev = old tail
    test    rcx, rcx
    je      .empty
    mov     [rcx+8], r15        ; old_tail->next = node
    jmp     .settail
.empty:
    mov     [rbx], r15          ; head = node
.settail:
    mov     [rbx+8], r15        ; tail = node
    inc     qword [rbx+16]
    xor     rax, rax
    jmp     .ret
.oom_free_str:
    mov     rdi, r14
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

; list_pop_head(rdi=header) -> rax=str_ptr, rdx=str_len (node freed; CALLER owns
; and must free the string). rax=0 if the list was empty.
list_pop_head:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8              ; 4 pushes + 8 -> rsp%16==0 at call
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; head node
    test    r12, r12
    je      .empty
    mov     r13, [r12+16]       ; str_ptr
    mov     r14, [r12+24]       ; str_len
    mov     rcx, [r12+8]        ; node->next
    mov     [rbx], rcx          ; head = next
    test    rcx, rcx
    je      .became_empty
    xor     rax, rax
    mov     [rcx], rax          ; next->prev = 0
    jmp     .unlinked
.became_empty:
    xor     rax, rax
    mov     [rbx+8], rax        ; tail = 0
.unlinked:
    dec     qword [rbx+16]      ; length--
    mov     rdi, r12            ; free node struct only
    mov     rsi, NODE_SZ
    call    mem_free
    mov     rax, r13            ; return str_ptr
    mov     rdx, r14            ; return str_len
    jmp     .ret
.empty:
    xor     rax, rax
    xor     rdx, rdx
.ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; list_pop_tail(rdi=header) -> rax=str_ptr, rdx=str_len (node freed; caller owns
; the string). rax=0 if empty.
list_pop_tail:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, [rbx+8]        ; tail node
    test    r12, r12
    je      .empty
    mov     r13, [r12+16]
    mov     r14, [r12+24]
    mov     rcx, [r12]          ; node->prev
    mov     [rbx+8], rcx        ; tail = prev
    test    rcx, rcx
    je      .became_empty
    xor     rax, rax
    mov     [rcx+8], rax        ; prev->next = 0
    jmp     .unlinked
.became_empty:
    xor     rax, rax
    mov     [rbx], rax          ; head = 0
.unlinked:
    dec     qword [rbx+16]
    mov     rdi, r12
    mov     rsi, NODE_SZ
    call    mem_free
    mov     rax, r13
    mov     rdx, r14
    jmp     .ret
.empty:
    xor     rax, rax
    xor     rdx, rdx
.ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; list_free(rdi=header): free every node's string + node, then the header.
list_free:
    push    rbx
    push    r12
    push    r13
    push    r14                 ; 4 pushes
    sub     rsp, 8              ; -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; node = head
.loop:
    test    r12, r12
    je      .nodes_done
    mov     r13, [r12+8]        ; next (save before free)
    mov     rdi, [r12+16]       ; str_ptr
    mov     rsi, [r12+24]       ; str_len
    call    mem_free
    mov     rdi, r12            ; node
    mov     rsi, NODE_SZ
    call    mem_free
    mov     r12, r13
    jmp     .loop
.nodes_done:
    mov     rdi, rbx            ; header
    mov     rsi, HDR_SZ
    call    mem_free
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 2: Build + regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build (new file compiled and linked); all existing checks PASS, exit 0.

- [ ] **Step 3: Commit**

```bash
git add src/list.asm
git commit -m "list: doubly-linked list primitives (new/push/pop/free)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Keyspace type field + `ks_lookup`/`ks_insert` + type-aware free

**Files:** Modify `src/keyspace.asm`.

Adds the type field, a type-dispatched `_free_value`, and two accessors. `ks_get` stays (dispatch still uses it until Task 5), so the string path and full suite remain green — the entry `type` is written `0` everywhere, guarded by the conformance/reclaim/rehash tests.

- [ ] **Step 1: Update globals + externs**

Change the `global` line to add `ks_lookup, ks_insert`:

```nasm
global ks_init, ks_get, ks_set, ks_del, ks_lookup, ks_insert
```

Add an extern line for `list_free` (below the existing externs):

```nasm
extern list_free
```

- [ ] **Step 2: In `ks_set` insert path — set the type field + use `ENTRY_SZ`**

Find the insert block that allocates the entry. Change `mov rdi, 40` to `mov rdi, ENTRY_SZ`, and add a `type=0` store after the `val_len` store. The block becomes:

```nasm
    mov     r14, rax                ; val copy
    mov     rdi, ENTRY_SZ
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_keyval
    mov     [rax+8], rbx            ; key_ptr
    mov     [rax+16], r13           ; key_len
    mov     [rax+24], r14           ; val_ptr
    mov     [rax+32], r15           ; val_len
    mov     qword [rax+40], TYPE_STR ; type = string
    mov     rdi, rax                ; entry
    mov     rsi, r12                ; key
    mov     rdx, r13                ; len
    call    _insert_entry           ; prepend into ht[0] or ht[1], used++
```

- [ ] **Step 3: In `ks_set` overwrite path — free old value type-aware, set type**

Replace the overwrite tail (from `mov r14, rax  ; new value block` through `jmp .ok`) with:

```nasm
    mov     r14, rax                ; new value block
    mov     rdi, rbx                ; entry (free old value, type-aware)
    call    _free_value
    mov     [rbx+24], r14
    mov     [rbx+32], r15
    mov     qword [rbx+40], TYPE_STR ; now a string
    jmp     .ok
```

- [ ] **Step 4: In `_del_in_table` match arm — free value type-aware + `ENTRY_SZ`**

Replace the match arm (from `mov rcx, [rbx]  ; entry->next` down to `mov rax, 1 / jmp .ret`) with:

```nasm
    mov     rcx, [rbx]              ; entry->next
    mov     [rbp], rcx              ; *slot = next
    mov     rdi, rbx                ; entry (free value, type-aware)
    call    _free_value
    mov     rdi, [rbx+8]            ; key_ptr
    mov     rsi, [rbx+16]           ; key_len
    call    mem_free
    mov     rdi, rbx                ; entry block
    mov     rsi, ENTRY_SZ
    call    mem_free
    lea     rcx, [rel ht_used]
    dec     qword [rcx + r15*8]     ; ht_used[t]--
    mov     rax, 1
    jmp     .ret
```

- [ ] **Step 5: Add `_free_value`, `ks_lookup`, `ks_insert`**

Append these three functions to `src/keyspace.asm` (after `ks_del`):

```nasm
; _free_value(rdi=entry): free the entry's VALUE only (not entry/key), dispatched
; on type. Preserves all callee-saved registers.
_free_value:
    push    rbx                     ; entry 8 -> 0 (call aligned)
    mov     rbx, rdi
    cmp     qword [rbx+40], TYPE_STR
    jne     .list
    mov     rdi, [rbx+24]           ; val_ptr
    mov     rsi, [rbx+32]           ; val_len
    call    mem_free
    jmp     .done
.list:
    mov     rdi, [rbx+24]           ; list header
    call    list_free
.done:
    pop     rbx
    ret

; ks_lookup(rdi=key, rsi=len) -> rax=entry|0. Rehash-step + find; returns the raw
; entry so callers can inspect [entry+40] type and [entry+24] val_ptr.
ks_lookup:
    push    r12
    push    r13
    sub     rsp, 8                  ; 2 pushes + 8 -> rsp%16==0 at calls
    mov     r12, rdi
    mov     r13, rsi
    call    _rehash_step
    mov     rdi, r12
    mov     rsi, r13
    call    _find
    add     rsp, 8
    pop     r13
    pop     r12
    ret

; ks_insert(rdi=key, rsi=len) -> rax=entry|0 (OOM). Creates a NEW entry (key
; copied, val_ptr/val_len=0, type=STR), linked into the destination table.
; Caller fills val_ptr/val_len/type. Assumes the key is absent (caller checked
; via ks_lookup).
ks_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r12, rdi                ; key
    mov     r13, rsi                ; klen
    call    _rehash_step
    call    _maybe_expand
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena             ; copy key
    test    rax, rax
    je      .oom
    mov     rbx, rax                ; key copy
    mov     rdi, ENTRY_SZ
    call    mem_alloc               ; entry
    test    rax, rax
    je      .oom_free_key
    mov     r14, rax                ; entry
    mov     [r14+8], rbx            ; key_ptr
    mov     [r14+16], r13           ; key_len
    xor     rcx, rcx
    mov     [r14+24], rcx           ; val_ptr = 0
    mov     [r14+32], rcx           ; val_len = 0
    mov     [r14+40], rcx           ; type = TYPE_STR (0)
    mov     rdi, r14                ; entry
    mov     rsi, r12                ; key
    mov     rdx, r13                ; len
    call    _insert_entry           ; prepend into ht[t], used++
    mov     rax, r14                ; return entry
    jmp     .ret
.oom_free_key:
    mov     rdi, rbx
    mov     rsi, r13
    call    mem_free
.oom:
    xor     rax, rax
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 6: Build + full regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build; EVERY existing check PASS, exit 0 — string SET/GET/DEL, `chain`, `conformance`, `reclaim-*`, `oom-error`, `rehash-correctness`, concurrency, backpressure. (Behaviour is identical; the type field is 0 on every entry and `_free_value` takes the string branch.)

- [ ] **Step 7: Commit**

```bash
git add src/keyspace.asm
git commit -m "keyspace: entry type tag + ks_lookup/ks_insert + type-aware free

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Failing conformance + stress test

**Files:** Create `tests/list.py`; modify `tests/wire.sh`.

Add list conformance checks (they FAIL now — asmredis replies `-ERR unknown command`) plus a stress/leak test. Task 5 makes them pass.

- [ ] **Step 1: Extend the conformance section in `tests/wire.sh`**

Find the conformance block (the `check` helper that diffs `valkey-cli -p 7777` vs `-p 7778`). Immediately before its `kill $SRV` line, add these list checks:

```bash
check LPUSH ml a b c
check LRANGE ml 0 -1
check RPUSH ml x y
check LRANGE ml 0 -1
check LLEN ml
check LPOP ml
check RPOP ml
check LRANGE ml 0 -1
check LLEN nope
check LPOP nope
check LRANGE nope 0 -1
check GET ml
check SET ml str
check GET ml
check LPUSH ml a
check LPUSH
check LRANGE ml 0
check LRANGE ml x 1
check RPUSH mk 1 2 3 4 5
check LRANGE mk 1 3
check LRANGE mk -2 -1
check LRANGE mk -100 100
check LPOP solo
check RPUSH solo only
check LPOP solo
check EXISTS solo
```

(`check GET ml` after the list exists asserts WRONGTYPE; `SET ml str` then `GET ml` asserts SET-over-list; `check EXISTS solo` after popping its only element asserts auto-delete. `EXISTS` already conforms — it is not a list command but a useful probe; if `EXISTS` is unimplemented in asmredis both sides differ identically... it IS implemented? No.)

NOTE: `EXISTS` is NOT implemented in asmredis. Replace the final auto-delete probe with a list-based one that both servers answer identically:

```bash
check LPOP solo
check RPUSH solo only
check LPOP solo
check LLEN solo
```

(After popping the only element the key is auto-deleted, so `LLEN solo` → `:0` on both — this verifies auto-delete without needing `EXISTS`.) Remove the `check EXISTS solo` line.

- [ ] **Step 2: Create `tests/list.py`**

```python
#!/usr/bin/env python3
# LIST stress + leak test. Usage: list.py <port>. Exit 0 ok / 1 fail.
import socket, sys

def connect(port):
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(30); return s

class Reader:
    def __init__(self, s): self.s=s; self.buf=b""
    def _fill(self):
        c=self.s.recv(65536)
        if not c: raise EOFError("closed")
        self.buf+=c
    def line(self):
        while b"\r\n" not in self.buf: self._fill()
        l,self.buf=self.buf.split(b"\r\n",1); return l
    def read_n(self,n):
        while len(self.buf)<n: self._fill()
        o,self.buf=self.buf[:n],self.buf[n:]; return o

def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o

def read_bulk(r):
    h=r.line(); assert h[:1]==b"$",h
    n=int(h[1:])
    if n<0: return None
    d=r.read_n(n); r.read_n(2); return d

def read_array(r):
    h=r.line(); assert h[:1]==b"*",h
    n=int(h[1:])
    return [read_bulk(r) for _ in range(n)]

def main():
    if len(sys.argv)!=2: print("usage: list.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        s=connect(port); r=Reader(s)
        N=2000
        # RPUSH builds ascending order
        for i in range(N):
            s.sendall(cmd("RPUSH","L",b"v%d"%i))
            ln=r.line()
            if ln!=b":%d"%(i+1): print("FAIL RPUSH len %d -> %r"%(i,ln)); return 1
        s.sendall(cmd("LLEN","L"))
        if r.line()!=b":%d"%N: print("FAIL LLEN"); return 1
        s.sendall(cmd("LRANGE","L","0","-1"))
        arr=read_array(r)
        if arr!=[b"v%d"%i for i in range(N)]: print("FAIL LRANGE order"); return 1
        # drain from head, ascending
        for i in range(N):
            s.sendall(cmd("LPOP","L")); v=read_bulk(r)
            if v!=b"v%d"%i: print("FAIL LPOP %d -> %r"%(i,v)); return 1
        # list now empty -> auto-deleted -> LLEN 0, LPOP nil
        s.sendall(cmd("LLEN","L"));  a=r.line()
        s.sendall(cmd("LPOP","L"));  b=read_bulk(r)
        if a!=b":0" or b is not None: print("FAIL auto-delete %r %r"%(a,b)); return 1
        # churn/leak: build+drain a big list many times through the 64MB arena
        BIG=b"x"*4000
        for rep in range(6000):     # 6000 * 4KB ~= 24MB per build, drained each time
            s.sendall(cmd("LPUSH","C",BIG))
            if r.line()!=b":1": print("FAIL churn push %d"%rep); return 1
            s.sendall(cmd("RPOP","C")); 
            if read_bulk(r)!=BIG: print("FAIL churn pop %d"%rep); return 1
        print("OK list: order/LLEN/auto-delete correct; %d churn cycles reclaimed"%6000)
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL list: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 3: Wire `list.py` into `tests/wire.sh`**

Append at the end of the file:

```bash

# --- Milestone E: LIST stress + leak ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/list.py 7777 >/tmp/asme_list.txt 2>&1; then
  echo "PASS list-stress"; ls=0
else
  echo "FAIL list-stress: $(cat /tmp/asme_list.txt)"; ls=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ls -eq 0 ] || exit 1
```

- [ ] **Step 4: Confirm RED on the current build**

Run: `bash tests/wire.sh`
Expected: the `conformance` check now **FAILS** (asmredis replies `-ERR unknown command 'LPUSH'…` where Valkey replies `:3`, etc.) and `list-stress` **FAILS** (unknown command). The suite exits non-zero. That is the expected red state.

- [ ] **Step 5: Commit the failing test**

```bash
git add tests/list.py tests/wire.sh
git commit -m "test: LIST conformance + stress (red: commands not yet implemented)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: LIST command handlers + dispatch routing + WRONGTYPE

**Files:** Modify `src/list.asm` (append handlers), `src/dispatch.asm`.

- [ ] **Step 1: Append the command handlers to `src/list.asm`**

Extend the `global` line and externs at the top of `src/list.asm`:

```nasm
global list_new, list_push_head, list_push_tail
global list_pop_head, list_pop_tail, list_free
global cmd_lpush, cmd_rpush, cmd_lpop, cmd_rpop, cmd_llen, cmd_lrange
extern mem_alloc, mem_free, mem_dup
extern ks_lookup, ks_insert, ks_del
extern argc, argv_ptrs, argv_lens
extern reply_bulk, reply_int, reply_null, reply_array_header
extern emit_wrongtype, emit_notint, emit_oom, emit_wrongargs
extern parse_int
```

Add a `.rodata` section (lowercase names for arity errors):

```nasm
section .rodata
lc_lpush:  db "lpush"
lc_rpush:  db "rpush"
lc_lpop:   db "lpop"
lc_rpop:   db "rpop"
lc_llen:   db "llen"
lc_lrange: db "lrange"
```

Append these handlers to the `.text` section:

```nasm
; ---- LPUSH / RPUSH key v [v...] -> :newlen ----
cmd_lpush:
    cmp     qword [rel argc], 3
    jb      .wa
    xor     eax, eax                ; dir = head
    jmp     _push_common
.wa:
    lea     rdi, [rel lc_lpush]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_rpush:
    cmp     qword [rel argc], 3
    jb      .wa
    mov     eax, 1                  ; dir = tail
    jmp     _push_common
.wa:
    lea     rdi, [rel lc_rpush]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _push_common: eax=dir (0 head, 1 tail). Arity already checked (>=3).
_push_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0 at calls
    mov     r15, rax                ; dir (0=head, 1=tail)
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    xor     r14, r14                ; auto-created = 0
    jmp     .pushloop
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_insert               ; rax = entry or 0
    test    rax, rax
    jz      .oom
    mov     r12, rax                ; entry
    call    list_new                ; rax = header or 0
    test    rax, rax
    jz      .oom_del_key            ; entry created but no list -> undo key
    mov     rbx, rax                ; header
    mov     [r12+24], rbx           ; entry.val_ptr = header
    mov     qword [r12+40], TYPE_LIST
    mov     r14, 1                  ; auto-created = 1
.pushloop:
    mov     r13, 2                  ; arg index
.pl_next:
    cmp     r13, [rel argc]
    jae     .done_push
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r13*8]      ; str_ptr
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r13*8]      ; str_len
    mov     rdi, rbx                ; header
    test    r15, r15
    jnz     .ptail
    call    list_push_head
    jmp     .pushed
.ptail:
    call    list_push_tail
.pushed:
    test    rax, rax
    jnz     .push_oom
    inc     r13
    jmp     .pl_next
.done_push:
    mov     rdi, [rbx+16]           ; length
    call    reply_int
    jmp     .ret
.push_oom:
    ; some values may already be in; if auto-created and still empty, drop the key
    cmp     qword [rbx+16], 0
    jne     .oom
    test    r14, r14
    jz      .oom
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
    jmp     .oom
.oom_del_key:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
.oom:
    call    emit_oom
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- LPOP / RPOP key -> bulk | nil ----
cmd_lpop:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     eax, eax                ; dir = head
    jmp     _pop_common
.wa:
    lea     rdi, [rel lc_lpop]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_rpop:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 1                  ; dir = tail
    jmp     _pop_common
.wa:
    lea     rdi, [rel lc_rpop]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _pop_common: eax=dir. Arity already checked (==2).
_pop_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     r15, rax                ; dir
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    mov     rdi, rbx
    test    r15, r15
    jnz     .ptail
    call    list_pop_head
    jmp     .popped
.ptail:
    call    list_pop_tail
.popped:
    test    rax, rax
    jz      .miss                   ; empty (defensive; shouldn't happen)
    mov     r12, rax                ; str_ptr
    mov     r13, rdx                ; str_len
    mov     rdi, r12
    mov     rsi, r13
    call    reply_bulk
    mov     rdi, r12                ; free the popped string (caller owns it)
    mov     rsi, r13
    call    mem_free
    cmp     qword [rbx+16], 0       ; list now empty?
    jne     .ret
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del                  ; auto-delete the key
    jmp     .ret
.miss:
    call    reply_null
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- LLEN key -> :len ----
cmd_llen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8                  ; align (entry 8 -> 0)
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rax, [rax+24]           ; header
    mov     rdi, [rax+16]           ; length
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     rdi, rdi
    call    reply_int
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_llen]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- LRANGE key start stop -> array ----
cmd_lrange:
    cmp     qword [rel argc], 4
    jne     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int               ; rax=val, rdx=ok
    test    rdx, rdx
    jz      .notint
    mov     r12, rax                ; start
    mov     rdi, [rel argv_ptrs + 24]
    mov     rsi, [rel argv_lens + 24]
    call    parse_int
    test    rdx, rdx
    jz      .notint
    mov     r13, rax                ; stop
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .emptyarr
    cmp     qword [rax+40], TYPE_LIST
    jne     .wrongtype
    mov     rbx, [rax+24]           ; header
    mov     r14, [rbx+16]           ; len (>=1 for a live list)
    ; normalize start
    test    r12, r12
    jns     .start_ok
    add     r12, r14
    jns     .start_ok
    xor     r12, r12
.start_ok:
    ; normalize stop
    test    r13, r13
    jns     .stop_hi
    add     r13, r14
.stop_hi:
    cmp     r13, r14
    jl      .stop_ok
    lea     r13, [r14-1]
.stop_ok:
    cmp     r12, r13                ; start > stop -> empty
    jg      .emptyarr
    cmp     r12, r14                ; start >= len -> empty
    jge     .emptyarr
    mov     rax, r13
    sub     rax, r12
    inc     rax                     ; count = stop-start+1
    mov     r15, rax                ; nodes to emit
    mov     rdi, rax
    call    reply_array_header
    mov     rax, [rbx]              ; node = head
.skip:
    test    r12, r12
    jle     .emit
    mov     rax, [rax+8]            ; node = node->next
    dec     r12
    jmp     .skip
.emit:
    mov     r12, rax                ; node
.emitloop:
    test    r15, r15
    jz      .ret
    mov     rdi, [r12+16]           ; str_ptr
    mov     rsi, [r12+24]           ; str_len
    mov     r13, [r12+8]            ; next (save before reply)
    call    reply_bulk
    mov     r12, r13
    dec     r15
    jmp     .emitloop
.emptyarr:
    xor     rdi, rdi
    call    reply_array_header      ; *0\r\n
    jmp     .ret
.notint:
    call    emit_notint
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_lrange]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 2: Route the commands + WRONGTYPE-aware `cmd_get` in `src/dispatch.asm`**

Update the externs. Change:

```nasm
extern reply_simple, reply_bulk, reply_null, reply_int, append_raw
extern ks_get, ks_set, ks_del
extern emit_wrongargs
```

to:

```nasm
extern reply_simple, reply_bulk, reply_null, reply_int, append_raw
extern ks_set, ks_del, ks_lookup
extern emit_wrongargs, emit_wrongtype
extern cmd_lpush, cmd_rpush, cmd_lpop, cmd_rpop, cmd_llen, cmd_lrange
```

In `.rodata`, add the command names:

```nasm
name_lpush:  db "LPUSH"
name_rpush:  db "RPUSH"
name_lpop:   db "LPOP"
name_rpop:   db "RPOP"
name_llen:   db "LLEN"
name_lrange: db "LRANGE"
```

In `dispatch`, extend the length switch. Change:

```nasm
    cmp     rax, 4
    je      .len4
    cmp     rax, 3
    je      .len3
    jmp     emit_unknown
```

to:

```nasm
    cmp     rax, 4
    je      .len4
    cmp     rax, 3
    je      .len3
    cmp     rax, 5
    je      .len5
    cmp     rax, 6
    je      .len6
    jmp     emit_unknown
```

Extend `.len4` — before its `jmp emit_unknown`, add LPOP/RPOP/LLEN:

```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lpop]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_lpop
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_rpop]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_rpop
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_llen]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_llen
    jmp     emit_unknown
```

Add `.len5` and `.len6` (place after the `.len3` block, before `.done`):

```nasm
.len5:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lpush]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_lpush
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_rpush]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_rpush
    jmp     emit_unknown
.len6:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lrange]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_lrange
    jmp     emit_unknown
```

Replace `cmd_get` entirely (it now uses `ks_lookup` + a type check):

```nasm
; cmd_get: GET key -> bulk value, $-1 on miss, WRONGTYPE if not a string.
cmd_get:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup                   ; rax = entry or 0
    test    rax, rax
    je      .miss
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]               ; val_ptr
    mov     rsi, [rax+32]               ; val_len
    call    reply_bulk
    add     rsp, 8
    ret
.miss:
    call    reply_null
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_get]
    mov     rsi, 3
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 3: Retire `ks_get` from `src/keyspace.asm`**

`ks_get` is now unused (its only caller was `cmd_get`). Remove `ks_get` from the `global` line and delete the `ks_get:` function body. (Grep to confirm no reference: `grep -rn "ks_get" src/` → empty.)

- [ ] **Step 4: Build**

Run: `make -s clean && make -s all`
Expected: clean build, no undefined symbols.

- [ ] **Step 5: Full suite — everything green**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — including `conformance` (now covering all six list commands + WRONGTYPE + auto-delete + SET-over-list + arity + bad-index, byte-identical to Valkey) and `list-stress`.

- [ ] **Step 6: Direct valkey diff spot-check**

```bash
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk.log --dir /tmp
./asmredis 7777 & SRV=$!; sleep 0.3
for c in "LPUSH k a b c" "LRANGE k 0 -1" "LLEN k" "RPOP k" "GET k" "LPUSH nope"; do
  m=$(valkey-cli -p 7777 $c); v=$(valkey-cli -p 7778 $c)
  [ "$m" = "$v" ] && echo "OK   [$c] -> $m" || echo "DIFF [$c] mine=<$m> valkey=<$v>"
done
kill $SRV 2>/dev/null; valkey-cli -p 7778 shutdown nosave
```
Expected: all `OK`, no `DIFF`.

- [ ] **Step 7: Commit**

```bash
git add src/list.asm src/dispatch.asm src/keyspace.asm
git commit -m "list: LPUSH/RPUSH/LPOP/RPOP/LRANGE/LLEN commands + WRONGTYPE-aware GET

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Benchmark confirmation + docs

**Files:** Modify `docs/benchmark.md`.

The string hot path gained one thing: `cmd_get` now goes through `ks_lookup` + a type compare, and entries carry a type field. Confirm the string SET/GET throughput didn't regress.

- [ ] **Step 1: Clean build + green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: all PASS, exit 0.

- [ ] **Step 2: Run the SET/GET sweep**

Same methodology as prior milestones (median of 3, `-c {1,20,50,100,200,500}`, `-d {3,512}`, asmredis:7777 vs Valkey:7778, `valkey-benchmark -t set,get -n 100000 --precision 3`). Save all raw output; derive each cell strictly from files. (LIST commands aren't part of `valkey-benchmark -t set,get`; this sweep specifically checks the string path didn't regress from the type-field/`ks_lookup` change.)

- [ ] **Step 3: Append a "Milestone E (LIST)" section to `docs/benchmark.md`**

Short intro (what changed on the hot path: entry type tag + `cmd_get` via `ks_lookup` + a type compare — a couple of instructions, no syscall), the two median-of-3 tables, and an honest "Reading the numbers" paragraph comparing asmredis-E vs the in-run Valkey oracle and vs milestone-D asmredis. Note that LIST ops are exercised for correctness/leak by `conformance` + `list-stress`, not by this throughput sweep. Record `uname -r` and the binary size.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-E LIST benchmark (string hot path, no regression)"
```

---

## Self-Review (completed)

- **Spec coverage:** type tag `[40]` + type-aware `_free_value` → Task 3; list header/node primitives → Task 2; `ks_lookup`/`ks_insert` → Task 3; six commands with captured Valkey semantics (auto-create, auto-delete, WRONGTYPE, nil pop, empty/negative LRANGE, bad-index, arity) → Task 5; supporting `reply_array_header`/`emit_wrongtype`/`emit_notint`/`emit_oom`/`parse_int`/`mem_dup` → Task 1; conformance + stress tests → Task 4; benchmark → Task 6. All mapped.
- **Placeholder scan:** all code is complete verbatim NASM/Python/bash.
- **Consistency:** entry offsets (`+8/+16/+24/+32/+40`, `ENTRY_SZ=48`), `TYPE_STR=0`/`TYPE_LIST=1`, header `[0]=head [8]=tail [16]=length`, node `[0]=prev [8]=next [16]=str_ptr [24]=str_len` used identically across list.asm and keyspace.asm. `ks_lookup`/`ks_insert`/`_free_value`/`list_free`/`list_push_head`/`list_pop_head` signatures consistent between definition and call sites. Stack alignment annotated per function (entry `rsp%16==8`; each `call` at `0`). Pop's ownership contract (node freed, caller frees the returned string) honored in `_pop_common`.
