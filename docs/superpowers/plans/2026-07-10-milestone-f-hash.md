# Milestone F — HASH data type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a HASH type (HSET/HGET/HDEL/HGETALL/HLEN/HEXISTS/HKEYS/HVALS) matching Valkey 9.1.0 byte-for-byte, reusing the type machinery from Milestone E.

**Architecture:** New `src/hash.asm` (insertion-ordered {field,value} pair list + command handlers). `keyspace.asm` gains one `_free_value` branch (`TYPE_HASH → hash_free`). `dispatch.asm` routes the eight names (incl. a new len-7 arm). `TYPE_HASH=2` in `syscalls.inc`. No new reply/error/util primitives — all reused from A–E.

**Tech Stack:** x86-64 NASM (elf64), static no-libc ELF, raw syscalls. Tests: bash valkey-oracle conformance diff + a Python RESP client.

**Reference design:** `docs/superpowers/specs/2026-07-10-asmredis-milestone-f-hash-design.md`

**ABI invariant:** every function entered at `rsp%16==8`; every internal `call` at `rsp%16==0`. Each function is annotated with its push/`sub rsp,8` accounting. Hash header: `[0]=head [8]=tail [16]=count` (24 B). Pair node: `[0]=next [8]=field_ptr [16]=field_len [24]=val_ptr [32]=val_len` (40 B). Entry: `…[40]=type`, TYPE_STR=0/TYPE_LIST=1/TYPE_HASH=2.

---

## Task 1: `TYPE_HASH` + `src/hash.asm` data-structure primitives

**Files:** Modify `include/syscalls.inc`; create `src/hash.asm`.

Additive — the primitives are unused until Task 4, so build + existing suite stay green (the Makefile globs `src/*.asm`).

- [ ] **Step 1: Add `TYPE_HASH` to `include/syscalls.inc`**

In the tunables block, next to `TYPE_STR`/`TYPE_LIST`:

```nasm
%define TYPE_HASH  2
```

- [ ] **Step 2: Create `src/hash.asm` with the primitives**

```nasm
%include "syscalls.inc"
global hash_new, hash_set, hash_get, hash_del, hash_exists, hash_free
extern mem_alloc, mem_free, mem_dup, memcmp_n

; header: [0]=head [8]=tail [16]=count            (24 bytes, class 32)
; node:   [0]=next [8]=field_ptr [16]=field_len [24]=val_ptr [32]=val_len (40 bytes, class 64)
%define HHDR_SZ   24
%define HNODE_SZ  40

section .text

; hash_new() -> rax=header or 0 (OOM). Zeroed empty hash.
hash_new:
    sub     rsp, 8              ; align (entry 8 -> 0)
    mov     rdi, HHDR_SZ
    call    mem_alloc
    test    rax, rax
    je      .done
    xor     rcx, rcx
    mov     [rax], rcx          ; head = 0
    mov     [rax+8], rcx        ; tail = 0
    mov     [rax+16], rcx       ; count = 0
.done:
    add     rsp, 8
    ret

; _hfind(rdi=header, rsi=field, rdx=flen) -> rax=node|0. Walks the chain.
; Clobbers rbx,rcx,rdx,rsi,rdi; preserves r12,r13,r14,r15.
_hfind:
    push    rbx
    push    r12
    push    r13                 ; 3 pushes -> rsp%16==0 at call
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    mov     rax, [rdi]          ; node = head
.walk:
    test    rax, rax
    je      .none
    mov     rcx, [rax+16]       ; node->field_len
    cmp     rcx, r13
    jne     .next
    mov     rbx, rax            ; save node across memcmp
    mov     rdi, r12            ; search field
    mov     rsi, [rax+8]        ; stored field
    mov     rdx, r13            ; flen
    call    memcmp_n            ; rax=0 if equal
    test    rax, rax
    mov     rax, rbx            ; restore node (mov preserves flags)
    je      .found
.next:
    mov     rax, [rax]          ; node = node->next
    jmp     .walk
.none:
    xor     rax, rax
.found:
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_get(rdi=header, rsi=field, rdx=flen) -> rax=val_ptr, rdx=val_len; rax=0 miss.
hash_get:
    sub     rsp, 8              ; align (entry 8 -> 0)
    call    _hfind
    add     rsp, 8
    test    rax, rax
    je      .miss
    mov     rdx, [rax+32]       ; val_len
    mov     rax, [rax+24]       ; val_ptr
    ret
.miss:
    xor     rax, rax
    xor     rdx, rdx
    ret

; hash_exists(rdi=header, rsi=field, rdx=flen) -> rax=1/0.
hash_exists:
    sub     rsp, 8
    call    _hfind
    add     rsp, 8
    test    rax, rax
    setne   al
    movzx   rax, al
    ret

; hash_set(rdi=header, rsi=field, rdx=flen, rcx=value, r8=vlen)
;   -> rax: 0 = updated existing, 1 = added new, 2 = OOM (hash unchanged).
hash_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    mov     r14, rcx            ; value
    mov     r15, r8             ; vlen
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    _hfind              ; rax = node | 0
    test    rax, rax
    je      .append
    ; --- field exists: replace value in place (alloc new, free old) ---
    mov     rbx, rax            ; node (header no longer needed)
    mov     rdi, r14            ; new value
    mov     rsi, r15            ; vlen
    call    mem_dup             ; rax = new value copy or 0
    test    rax, rax
    je      .oom
    mov     r12, rax            ; new value copy
    mov     rdi, [rbx+24]       ; old val_ptr
    mov     rsi, [rbx+32]       ; old val_len
    call    mem_free
    mov     [rbx+24], r12       ; val_ptr = new
    mov     [rbx+32], r15       ; val_len = new
    xor     rax, rax            ; 0 = updated
    jmp     .ret
.append:
    mov     rdi, r12            ; field
    mov     rsi, r13            ; flen
    call    mem_dup             ; rax = field copy or 0
    test    rax, rax
    je      .oom
    mov     r12, rax            ; field copy
    mov     rdi, r14            ; value
    mov     rsi, r15            ; vlen
    call    mem_dup             ; rax = value copy or 0
    test    rax, rax
    je      .oom_free_field
    mov     r14, rax            ; value copy
    mov     rdi, HNODE_SZ
    call    mem_alloc           ; rax = node or 0
    test    rax, rax
    je      .oom_free_fv
    mov     [rax+8], r12        ; field_ptr
    mov     [rax+16], r13       ; field_len
    mov     [rax+24], r14       ; val_ptr
    mov     [rax+32], r15       ; val_len
    xor     rcx, rcx
    mov     [rax], rcx          ; next = 0
    mov     rcx, [rbx+8]        ; old tail
    test    rcx, rcx
    je      .empty
    mov     [rcx], rax          ; old_tail->next = node
    jmp     .settail
.empty:
    mov     [rbx], rax          ; head = node
.settail:
    mov     [rbx+8], rax        ; tail = node
    inc     qword [rbx+16]      ; count++
    mov     rax, 1              ; 1 = new field
    jmp     .ret
.oom_free_fv:
    mov     rdi, r14            ; value copy
    mov     rsi, r15
    call    mem_free
.oom_free_field:
    mov     rdi, r12            ; field copy
    mov     rsi, r13
    call    mem_free
.oom:
    mov     rax, 2              ; 2 = oom
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_del(rdi=header, rsi=field, rdx=flen) -> rax=1 removed / 0 absent.
; prev-pointer walk so the tail pointer can be fixed when removing the last node.
hash_del:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    mov     rbx, rdi            ; header
    mov     r12, rsi            ; field
    mov     r13, rdx            ; flen
    xor     r15, r15            ; prev = 0
    mov     r14, [rbx]          ; node = head
.loop:
    test    r14, r14
    je      .absent
    mov     rcx, [r14+16]       ; field_len
    cmp     rcx, r13
    jne     .adv
    mov     rdi, r12
    mov     rsi, [r14+8]        ; stored field
    mov     rdx, r13
    call    memcmp_n
    test    rax, rax
    jne     .adv
    ; match at r14 (prev=r15): unlink
    mov     rcx, [r14]          ; node->next
    test    r15, r15
    je      .unlink_head
    mov     [r15], rcx          ; prev->next = node->next
    jmp     .fix_tail
.unlink_head:
    mov     [rbx], rcx          ; header->head = node->next
.fix_tail:
    cmp     [rbx+8], r14        ; was node the tail?
    jne     .free_it
    mov     [rbx+8], r15        ; header->tail = prev (0 if none)
.free_it:
    mov     rdi, [r14+8]        ; field_ptr
    mov     rsi, [r14+16]       ; field_len
    call    mem_free
    mov     rdi, [r14+24]       ; val_ptr
    mov     rsi, [r14+32]       ; val_len
    call    mem_free
    mov     rdi, r14            ; node
    mov     rsi, HNODE_SZ
    call    mem_free
    dec     qword [rbx+16]      ; count--
    mov     rax, 1
    jmp     .ret
.adv:
    mov     r15, r14            ; prev = node
    mov     r14, [r14]          ; node = node->next
    jmp     .loop
.absent:
    xor     rax, rax
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; hash_free(rdi=header): free each node's field+value+node, then the header.
hash_free:
    push    rbx
    push    r12
    push    r13                 ; 3 pushes -> rsp%16==0 at calls
    mov     rbx, rdi            ; header
    mov     r12, [rbx]          ; node = head
.loop:
    test    r12, r12
    je      .nodes_done
    mov     r13, [r12]          ; next (save before free)
    mov     rdi, [r12+8]        ; field_ptr
    mov     rsi, [r12+16]       ; field_len
    call    mem_free
    mov     rdi, [r12+24]       ; val_ptr
    mov     rsi, [r12+32]       ; val_len
    call    mem_free
    mov     rdi, r12            ; node
    mov     rsi, HNODE_SZ
    call    mem_free
    mov     r12, r13
    jmp     .loop
.nodes_done:
    mov     rdi, rbx            ; header
    mov     rsi, HHDR_SZ
    call    mem_free
    pop     r13
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 3: Build + regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build (new file linked); all existing checks PASS, exit 0.

- [ ] **Step 4: Commit**

```bash
git add include/syscalls.inc src/hash.asm
git commit -m "hash: TYPE_HASH + {field,value} pair primitives (new/set/get/del/exists/free)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Wire `_free_value` to `hash_free`

**Files:** Modify `src/keyspace.asm`.

- [ ] **Step 1: Extern `hash_free`**

Find the `extern list_free` line and change it to:

```nasm
extern list_free, hash_free
```

- [ ] **Step 2: Rewrite `_free_value` as a 3-way type dispatch**

Replace the entire `_free_value` function with:

```nasm
; _free_value(rdi=entry): free the entry's VALUE only (not entry/key), dispatched
; on type. A null val_ptr (an entry created by ks_insert before its value is
; filled) is a no-op on every branch. Preserves all callee-saved registers.
_free_value:
    push    rbx                     ; entry 8 -> 0 (call aligned)
    mov     rbx, rdi
    mov     rax, [rbx+40]           ; type
    cmp     rax, TYPE_STR
    je      .str
    cmp     rax, TYPE_LIST
    je      .list
    ; TYPE_HASH
    mov     rdi, [rbx+24]           ; hash header
    test    rdi, rdi
    jz      .done
    call    hash_free
    jmp     .done
.str:
    mov     rdi, [rbx+24]           ; val_ptr
    test    rdi, rdi
    jz      .done
    mov     rsi, [rbx+32]           ; val_len
    call    mem_free
    jmp     .done
.list:
    mov     rdi, [rbx+24]           ; list header
    test    rdi, rdi
    jz      .done
    call    list_free
.done:
    pop     rbx
    ret
```

- [ ] **Step 3: Build + FULL regression**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: clean build; EVERY existing check PASS, exit 0 — string/list behavior is unchanged (the hash branch is dormant since no hash entries exist yet). The `_free_value` change is exercised by the string and list tests (both still take their branches correctly).

- [ ] **Step 4: Commit**

```bash
git add src/keyspace.asm
git commit -m "keyspace: _free_value dispatches TYPE_HASH to hash_free

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Failing conformance + `hash.py` stress

**Files:** Create `tests/hash.py`; modify `tests/wire.sh`.

The commands aren't implemented yet, so these fail (red). Task 4 makes them pass.

- [ ] **Step 1: Add HASH conformance checks to `tests/wire.sh`**

In the conformance `check` series (after the LIST `check` lines added in Milestone E, before that block's `kill $SRV`), insert:

```bash
check HSET hh f1 a f2 b f3 c
check HGETALL hh
check HSET hh f1 z f4 d
check HGETALL hh
check HGET hh f1
check HGET hh nope
check HLEN hh
check HEXISTS hh f2
check HEXISTS hh nope
check HKEYS hh
check HVALS hh
check HDEL hh f2 f3 nope
check HGETALL hh
check HLEN nokey
check HGET nokey f
check HGETALL nokey
check HKEYS nokey
check HVALS nokey
check HEXISTS nokey f
check GET hh
check LPUSH hh x
check HSET hh
check HSET hh onlyfield
check HSET
check HEXISTS hh
check HGETALL
check SET hs str
check HGET hs f
check HDEL solo2 f
check HSET solo2 f v
check HDEL solo2 f
check HLEN solo2
check GET solo2
```

(`GET hh` and `LPUSH hh x` assert WRONGTYPE against a hash; `HGET hs f` asserts WRONGTYPE against a string; `HSET hh`/`HSET hh onlyfield`/`HSET` are arity errors; the `solo2` sequence asserts auto-delete: after `HDEL solo2 f` removes the only field, `HLEN solo2`→`:0` and `GET solo2`→nil, not WRONGTYPE.)

- [ ] **Step 2: Create `tests/hash.py`**

```python
#!/usr/bin/env python3
# HASH stress + leak test. Usage: hash.py <port>. Exit 0 ok / 1 fail.
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
    if len(sys.argv)!=2: print("usage: hash.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        s=connect(port); r=Reader(s)
        N=2000
        # build a hash with N distinct fields
        for i in range(N):
            s.sendall(cmd("HSET","H",b"f%d"%i,b"v%d"%i))
            ln=r.line()
            if ln!=b":1": print("FAIL HSET new f%d -> %r"%(i,ln)); return 1
        s.sendall(cmd("HLEN","H"))
        if r.line()!=b":%d"%N: print("FAIL HLEN"); return 1
        # HGET every field (order-independent)
        for i in range(N):
            s.sendall(cmd("HGET","H",b"f%d"%i)); v=read_bulk(r)
            if v!=b"v%d"%i: print("FAIL HGET f%d -> %r"%(i,v)); return 1
        # HKEYS/HVALS/HGETALL shapes
        s.sendall(cmd("HKEYS","H")); ks=read_array(r)
        if set(ks)!={b"f%d"%i for i in range(N)}: print("FAIL HKEYS set"); return 1
        s.sendall(cmd("HVALS","H")); vs=read_array(r)
        if set(vs)!={b"v%d"%i for i in range(N)}: print("FAIL HVALS set"); return 1
        s.sendall(cmd("HGETALL","H")); ga=read_array(r)
        if len(ga)!=2*N: print("FAIL HGETALL len %d"%len(ga)); return 1
        if dict(zip(ga[0::2],ga[1::2]))!={b"f%d"%i:b"v%d"%i for i in range(N)}:
            print("FAIL HGETALL pairs"); return 1
        # overwrite updates in place, does not count as new
        s.sendall(cmd("HSET","H",b"f0",b"zzz")); 
        if r.line()!=b":0": print("FAIL HSET overwrite count"); return 1
        s.sendall(cmd("HGET","H",b"f0")); 
        if read_bulk(r)!=b"zzz": print("FAIL HSET overwrite value"); return 1
        # HDEL-drain, assert auto-delete
        for i in range(N):
            s.sendall(cmd("HDEL","H",b"f%d"%i))
            if r.line()!=b":1": print("FAIL HDEL f%d"%i); return 1
        s.sendall(cmd("HLEN","H")); a=r.line()
        s.sendall(cmd("GET","H")); g=read_bulk(r)   # auto-deleted -> nil, not WRONGTYPE
        if a!=b":0" or g is not None: print("FAIL auto-delete %r %r"%(a,g)); return 1
        # churn/leak: build+drain a big field many times, >64MB cumulative
        BIG=b"x"*16000
        CYCLES=10000                 # 10000 * 16000 = 160MB through a 64MB arena
        for rep in range(CYCLES):
            s.sendall(cmd("HSET","C","fld",BIG))
            if r.line()!=b":1": print("FAIL churn hset %d"%rep); return 1
            s.sendall(cmd("HDEL","C","fld"))
            if r.line()!=b":1": print("FAIL churn hdel %d"%rep); return 1
        print("OK hash: %d fields correct; overwrite/HGETALL/auto-delete ok; %d churn reclaimed"%(N,CYCLES))
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL hash: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 3: Wire `hash.py` into `tests/wire.sh`** (append at end of file)

```bash

# --- Milestone F: HASH stress + leak ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/hash.py 7777 >/tmp/asmf_hash.txt 2>&1; then
  echo "PASS hash-stress"; hs=0
else
  echo "FAIL hash-stress: $(cat /tmp/asmf_hash.txt)"; hs=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $hs -eq 0 ] || exit 1
```

- [ ] **Step 4: Confirm RED**

Run: `bash tests/wire.sh`
Expected: `conformance` FAILS with HASH DIFFs (asmredis replies `-ERR unknown command 'HSET'…` where Valkey returns real results); the suite exits non-zero. Pre-existing checks still individually pass. (`hash-stress` isn't reached because conformance exits first — expected.)

- [ ] **Step 5: Commit**

```bash
git add tests/hash.py tests/wire.sh
git commit -m "test: HASH conformance + stress (red: commands not yet implemented)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: HASH command handlers + dispatch routing

**Files:** Modify `src/hash.asm` (append handlers), `src/dispatch.asm`.

- [ ] **Step 1: Extend `src/hash.asm` globals/externs + add `.rodata` names**

Change the `global` line to add the eight handlers:

```nasm
global hash_new, hash_set, hash_get, hash_del, hash_exists, hash_free
global cmd_hset, cmd_hget, cmd_hdel, cmd_hgetall, cmd_hlen
global cmd_hexists, cmd_hkeys, cmd_hvals
```

Change the `extern` line to:

```nasm
extern mem_alloc, mem_free, mem_dup, memcmp_n
extern ks_lookup, ks_insert, ks_del
extern argc, argv_ptrs, argv_lens
extern reply_bulk, reply_int, reply_null, reply_array_header
extern emit_wrongtype, emit_wrongargs, emit_oom
```

Add a `.rodata` section:

```nasm
section .rodata
lc_hset:     db "hset"
lc_hget:     db "hget"
lc_hdel:     db "hdel"
lc_hlen:     db "hlen"
lc_hexists:  db "hexists"
lc_hkeys:    db "hkeys"
lc_hvals:    db "hvals"
lc_hgetall:  db "hgetall"
```

- [ ] **Step 2: Append the eight handlers to `src/hash.asm` `.text`**

```nasm
; ---- HSET key f v [f v ...] -> :new_fields ----
cmd_hset:
    mov     rax, [rel argc]
    cmp     rax, 4
    jb      .wa
    test    rax, 1              ; odd argc (incomplete pair) -> arity error
    jnz     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; new-field counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    xor     r14, r14            ; auto-created = 0
    jmp     .setloop
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_insert
    test    rax, rax
    jz      .oom
    mov     r12, rax            ; entry
    call    hash_new
    test    rax, rax
    jz      .oom_del_key
    mov     rbx, rax            ; header
    mov     [r12+24], rbx       ; entry.val_ptr = header
    mov     qword [r12+40], TYPE_HASH
    mov     r14, 1              ; auto-created = 1
.setloop:
    mov     r15, 2              ; arg index
.sl_next:
    cmp     r15, [rel argc]
    jae     .done_set
    mov     rdi, rbx            ; header
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]      ; field_ptr
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]      ; field_len
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8 + 8]  ; value_ptr
    lea     rax, [rel argv_lens]
    mov     r8,  [rax + r15*8 + 8]  ; value_len
    call    hash_set            ; 0 updated / 1 new / 2 oom
    cmp     rax, 2
    je      .set_oom
    cmp     rax, 1
    jne     .not_new
    inc     r13
.not_new:
    add     r15, 2
    jmp     .sl_next
.done_set:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.set_oom:
    cmp     qword [rbx+16], 0   ; any field present?
    jne     .oom
    test    r14, r14            ; auto-created and still empty?
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
.wa:
    lea     rdi, [rel lc_hset]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HGET key field -> bulk | nil ----
cmd_hget:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rdi, [rax+24]       ; header
    mov     rsi, [rel argv_ptrs + 16]
    mov     rdx, [rel argv_lens + 16]
    call    hash_get            ; rax=val_ptr(0 miss), rdx=val_len
    test    rax, rax
    jz      .miss
    mov     rdi, rax
    mov     rsi, rdx
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
    lea     rdi, [rel lc_hget]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HEXISTS key field -> :0 | :1 ----
cmd_hexists:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rdi, [rax+24]
    mov     rsi, [rel argv_ptrs + 16]
    mov     rdx, [rel argv_lens + 16]
    call    hash_exists
    mov     rdi, rax
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
    lea     rdi, [rel lc_hexists]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HLEN key -> :count ----
cmd_hlen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rax, [rax+24]       ; header
    mov     rdi, [rax+16]       ; count
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
    lea     rdi, [rel lc_hlen]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HDEL key f [f ...] -> :removed ----
cmd_hdel:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; removed counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r15, 2              ; arg index
.dl_next:
    cmp     r15, [rel argc]
    jae     .done_del
    mov     rdi, rbx
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]  ; field
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]  ; flen
    call    hash_del            ; rax = 1 removed / 0
    add     r13, rax
    inc     r15
    jmp     .dl_next
.done_del:
    cmp     qword [rbx+16], 0   ; hash now empty?
    jne     .reply
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del              ; auto-delete key
.reply:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.zero:
    xor     rdi, rdi
    call    reply_int
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
    lea     rdi, [rel lc_hdel]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- HGETALL / HKEYS / HVALS -> array ----
cmd_hgetall:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     eax, eax            ; mode 0 = getall (field+value)
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hgetall]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_hkeys:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 1              ; mode 1 = keys
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hkeys]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
cmd_hvals:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     eax, 2              ; mode 2 = vals
    jmp     _hiter
.wa:
    lea     rdi, [rel lc_hvals]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _hiter: eax=mode (0 getall, 1 keys, 2 vals). argc checked ==2.
_hiter:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    mov     r15, rax            ; mode
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .empty
    cmp     qword [rax+40], TYPE_HASH
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r13, [rbx+16]       ; count
    mov     rax, r13
    test    r15, r15            ; mode 0 (getall) -> 2*count
    jnz     .cnt_ok
    add     rax, rax
.cnt_ok:
    mov     rdi, rax
    call    reply_array_header
    mov     r12, [rbx]          ; node = head
.walk:
    test    r12, r12
    je      .ret
    cmp     r15, 1
    je      .emit_key
    cmp     r15, 2
    je      .emit_val
    ; mode 0: field then value
    mov     rdi, [r12+8]        ; field_ptr
    mov     rsi, [r12+16]       ; field_len
    mov     r14, [r12]          ; save next
    call    reply_bulk
    mov     rdi, [r12+24]       ; val_ptr
    mov     rsi, [r12+32]       ; val_len
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.emit_key:
    mov     rdi, [r12+8]
    mov     rsi, [r12+16]
    mov     r14, [r12]
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.emit_val:
    mov     rdi, [r12+24]
    mov     rsi, [r12+32]
    mov     r14, [r12]
    call    reply_bulk
    mov     r12, r14
    jmp     .walk
.empty:
    xor     rdi, rdi
    call    reply_array_header  ; *0
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
```

- [ ] **Step 3: Route the commands in `src/dispatch.asm`**

(a) Add the eight handlers to the externs:

```nasm
extern cmd_hset, cmd_hget, cmd_hdel, cmd_hgetall, cmd_hlen
extern cmd_hexists, cmd_hkeys, cmd_hvals
```

(b) Add command names to `.rodata`:

```nasm
name_hset:    db "HSET"
name_hget:    db "HGET"
name_hdel:    db "HDEL"
name_hlen:    db "HLEN"
name_hkeys:   db "HKEYS"
name_hvals:   db "HVALS"
name_hgetall: db "HGETALL"
name_hexists: db "HEXISTS"
```

(c) Add a len-7 arm to the length switch. Change:

```nasm
    cmp     rax, 6
    je      .len6
    jmp     emit_unknown
```

to:

```nasm
    cmp     rax, 6
    je      .len6
    cmp     rax, 7
    je      .len7
    jmp     emit_unknown
```

(d) In `.len4`, before its `jmp emit_unknown`, add HGET/HSET/HDEL/HLEN:

```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hget]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hget
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hset]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hset
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hdel]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hdel
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hlen]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hlen
    jmp     emit_unknown
```

(e) In `.len5`, before its `jmp emit_unknown`, add HKEYS/HVALS:

```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hkeys]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_hkeys
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hvals]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_hvals
    jmp     emit_unknown
```

(f) Add `.len7` right after the `.len6` block (before `.done:`):

```nasm
.len7:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hgetall]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_hgetall
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hexists]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_hexists
    jmp     emit_unknown
```

- [ ] **Step 4: Build**

Run: `make -s clean && make -s all`
Expected: clean build, no undefined symbols.

- [ ] **Step 5: FULL suite — green**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — including `conformance` (all 8 HASH commands + WRONGTYPE + auto-delete + arity + missing, byte-identical to Valkey) and `hash-stress`. ~3-4 min.

- [ ] **Step 6: Direct spot-check**

```bash
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk.log --dir /tmp
./asmredis 7777 & SRV=$!; sleep 0.3
for c in "HSET k f1 a f2 b" "HGETALL k" "HGET k f1" "HKEYS k" "HDEL k f1" "HLEN k" "GET k"; do
  m=$(valkey-cli -p 7777 $c); v=$(valkey-cli -p 7778 $c)
  [ "$m" = "$v" ] && echo "OK   [$c]" || echo "DIFF [$c] mine=<$m> valkey=<$v>"
done
kill $SRV 2>/dev/null; valkey-cli -p 7778 shutdown nosave
```
Expected: all `OK`.

- [ ] **Step 7: Commit**

```bash
git add src/hash.asm src/dispatch.asm
git commit -m "hash: HSET/HGET/HDEL/HGETALL/HLEN/HEXISTS/HKEYS/HVALS commands + routing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Benchmark confirmation + docs

**Files:** Modify `docs/benchmark.md`.

The string SET/GET hot path is unchanged this milestone (no keyspace hot-path edit beyond the dormant `_free_value` hash branch). Confirm no regression and document.

- [ ] **Step 1: Clean build + green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh` → all PASS, exit 0.

- [ ] **Step 2: Run the SET/GET sweep**

Same methodology as prior milestones (median of 3, `-c {1,20,50,100,200,500}`, `-d {3,512}`, asmredis:7777 vs Valkey:7778, `valkey-benchmark -t set,get -n 100000 --precision 3`). Save all raw output; derive each cell strictly from files (per-metric median of 3).

- [ ] **Step 3: Append "Milestone F (HASH) — string hot path" to `docs/benchmark.md`**

Short intro (HASH is additive; the SET/GET path is unchanged — HASH correctness/leak is covered by `conformance` + `hash-stress`, not this throughput sweep), the two median-of-3 tables, and an honest "Reading the numbers" paragraph vs the in-run Valkey oracle and vs milestone-E asmredis (expected: within noise; if absolute numbers differ, check Valkey moved proportionally = ambient load; the in-run oracle comparison is load-invariant). Record `uname -r` and binary size.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-F HASH benchmark (string hot path, no regression)"
```

---

## Self-Review (completed)

- **Spec coverage:** TYPE_HASH + pair primitives → Task 1; `_free_value` hash branch → Task 2; conformance + stress tests → Task 3; 8 handlers with captured Valkey semantics (HSET new-count/overwrite-in-place, auto-create/delete, WRONGTYPE, arity, HGETALL/HKEYS/HVALS insertion order) + dispatch (incl. new len-7) → Task 4; benchmark → Task 5. All mapped.
- **Placeholder scan:** all code is complete verbatim NASM/Python/bash.
- **Consistency:** header `[0]=head [8]=tail [16]=count`, node `[0]=next [8]=field_ptr [16]=field_len [24]=val_ptr [32]=val_len` (HNODE_SZ=40, HHDR_SZ=24) used identically across primitives and handlers. `hash_set` return codes (0/1/2) consistent with the HSET accumulation and OOM rollback. `_hiter` array-header count (2*count for getall, count otherwise) exactly matches the emitted bulk count (2 or 1 per node × count nodes). Stack alignment annotated per function (entry `rsp%16==8`; each `call` at `0`; `_hfind`/`hash_free` use 3 pushes → 0, single-call handlers use `sub rsp,8`, 5-arg/variadic handlers use 5 pushes). `hash_del`'s prev-walk correctly fixes the tail pointer. Pop/getall reads `next` into a callee-saved reg before `reply_bulk`.
