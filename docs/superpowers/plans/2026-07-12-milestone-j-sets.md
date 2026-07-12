# Milestone J — Sets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `SADD`/`SREM`/`SMEMBERS`/`SISMEMBER`/`SCARD` with byte-exact valkey semantics, reusing the hash machinery.

**Architecture:** A set is a `TYPE_SET(3)`-tagged hash header; members are hash fields with empty (0-length) values. `hash_new`/`hash_set`/`hash_del`/`hash_exists`/`hash_free` are reused verbatim (the allocator handles 0-length values). Set commands mirror the hash command wrappers. `_free_value` already routes non-STR/LIST types to `hash_free`, so no keyspace change is needed.

**Tech Stack:** x86-64 NASM. Tests: Python RESP client + valkey-cli oracle diff.

**Reference design:** `docs/superpowers/specs/2026-07-12-asmredis-milestone-j-sets-design.md`

**Ground truth (valkey):** SADD→:count-added (dups not counted); SREM→:count-removed + auto-delete key when empty; SCARD/SISMEMBER missing→:0; SMEMBERS missing→*0; TYPE→+set; WRONGTYPE both ways; arity: SADD/SREM/SISMEMBER need key+≥1 member, SCARD/SMEMBERS key-only; SMEMBERS in insertion order (matches valkey).

**ABI:** functions entered at rsp%16==8, calls at rsp%16==0. Entry `[24]`=val_ptr (=hash header for a set), `[40]`=type. Hash header `[0]`=head `[8]`=tail `[16]`=count; node `[0]`=next `[8]`=field_ptr `[16]`=field_len `[24]`=val_ptr `[32]`=val_len. `hash_set(rdi=hdr,rsi=field,rdx=flen,rcx=val,r8=vlen)`→0 updated/1 new/2 oom. `hash_del(hdr,field,flen)`→1/0. `hash_exists(hdr,field,flen)`→1/0. Command args at `[argv_ptrs+8*i]`/`[argv_lens+8*i]`, count `[argc]`.

**No benchmark task:** Sets add a new file and don't touch the SET/GET path (SET→reply_simple, GET→reply_bulk), so there is no hot-path change to measure.

---

## Task 1: Set type + the five commands

**Files:** `include/syscalls.inc`, new `src/set.asm`, `src/dispatch.asm`, new `tests/set.py`.

- [ ] **Step 1: `include/syscalls.inc`** — add the type constant next to the others:
```nasm
%define TYPE_SET   3
```

- [ ] **Step 2: Write the failing test `tests/set.py`:**
```python
#!/usr/bin/env python3
# Milestone J: SADD/SREM/SMEMBERS/SISMEMBER/SCARD conformance. Usage: set.py <port>.
import socket, sys
def conn(port):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.connect(("127.0.0.1",port)); s.settimeout(10); return s
def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o
class C:
    def __init__(s,port): s.s=conn(port); s.b=b""
    def _f(s):
        c=s.s.recv(4096)
        if not c: raise EOFError("closed")
        s.b+=c
    def line(s):
        while b"\r\n" not in s.b: s._f()
        l,s.b=s.b.split(b"\r\n",1); return l
    def reply(s):
        h=s.line(); t=h[:1]
        if t in (b"+",b"-",b":"): return h
        if t==b"$":
            n=int(h[1:])
            if n<0: return h
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*": return [s.reply() for _ in range(int(h[1:]))]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()
FAILS=[]
def eq(g,w,l):
    if g!=w: FAILS.append("%s: got %r want %r"%(l,g,w))
WT=b"-WRONGTYPE Operation against a key holding the wrong kind of value"
def wa(n): return b"-ERR wrong number of arguments for '%s' command"%n.encode()
def main():
    if len(sys.argv)<2: print("usage: set.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        eq(c.do("DEL","s"), b":0", "del s")
        eq(c.do("SADD","s","a","b","c"), b":3", "sadd 3")
        eq(c.do("SADD","s","a","d"), b":1", "sadd dup+1")
        eq(c.do("SCARD","s"), b":4", "scard 4")
        eq(c.do("SISMEMBER","s","a"), b":1", "sismember hit")
        eq(c.do("SISMEMBER","s","z"), b":0", "sismember miss")
        eq(c.do("SCARD","nope"), b":0", "scard missing")
        eq(c.do("SISMEMBER","nope","a"), b":0", "sismember missing")
        eq(c.do("SREM","s","a","z"), b":1", "srem 1")
        eq(c.do("SCARD","s"), b":3", "scard after srem")
        # SMEMBERS content (order-independent compare)
        m=c.do("SMEMBERS","s")
        eq(sorted(m), sorted([b"b",b"c",b"d"]), "smembers content")
        eq(c.do("SMEMBERS","nope"), [], "smembers missing -> empty")
        # auto-delete on empty
        eq(c.do("DEL","s2"), b":0", "del s2"); eq(c.do("SADD","s2","only"), b":1", "sadd s2")
        eq(c.do("SREM","s2","only"), b":1", "srem last")
        eq(c.do("EXISTS","s2"), b":0", "s2 gone"); eq(c.do("TYPE","s2"), b"+none", "type s2 none")
        # type + WRONGTYPE
        eq(c.do("DEL","s3"), b":0","del s3"); eq(c.do("SADD","s3","x"), b":1","sadd s3")
        eq(c.do("TYPE","s3"), b"+set", "type set")
        eq(c.do("SET","str","v"), b"+OK","set str"); eq(c.do("SADD","str","m"), WT, "sadd wrongtype")
        eq(c.do("GET","s3"), WT, "get on set wrongtype")
        eq(c.do("SCARD","str"), WT, "scard wrongtype")
        eq(c.do("SMEMBERS","str"), WT, "smembers wrongtype")
        # arity
        eq(c.do("SADD","s3"), wa("sadd"), "sadd arity")
        eq(c.do("SREM","s3"), wa("srem"), "srem arity")
        eq(c.do("SISMEMBER","s3"), wa("sismember"), "sismember arity")
        eq(c.do("SCARD"), wa("scard"), "scard arity")
        eq(c.do("SMEMBERS"), wa("smembers"), "smembers arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL set: %r"%e); return 1
    if FAILS:
        print("FAIL set:"); [print("  "+f) for f in FAILS]; return 1
    print("OK set: SADD/SREM/SMEMBERS/SISMEMBER/SCARD conformant"); return 0
if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 3: Verify RED:**
```bash
make -s all >/dev/null 2>&1; ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/set.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: FAIL (SADD unknown), rc=1.

- [ ] **Step 4: Create `src/set.asm`** (verbatim):
```nasm
%include "syscalls.inc"
global cmd_sadd, cmd_srem, cmd_sismember, cmd_scard, cmd_smembers
extern argc, argv_ptrs, argv_lens
extern ks_lookup, ks_insert, ks_del
extern hash_new, hash_set, hash_del, hash_exists
extern reply_int, reply_bulk, reply_array_header
extern emit_wrongtype, emit_wrongargs, emit_oom

section .rodata
lc_sadd:      db "sadd"
lc_srem:      db "srem"
lc_sismember: db "sismember"
lc_scard:     db "scard"
lc_smembers:  db "smembers"

section .text
; ---- SADD key member [member ...] -> :added ----
cmd_sadd:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                 ; 5 pushes -> rsp%16==0
    xor     r13, r13            ; added counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    xor     r14, r14            ; auto-created = 0
    jmp     .addloop
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
    mov     qword [r12+40], TYPE_SET
    mov     r14, 1              ; auto-created = 1
.addloop:
    mov     r15, 2              ; arg index
.al_next:
    cmp     r15, [rel argc]
    jae     .done_add
    mov     rdi, rbx            ; header
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]  ; member ptr (field)
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]  ; member len (flen)
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8]  ; value ptr = member ptr (vlen=0, so unused copy)
    xor     r8, r8              ; vlen = 0 (empty value)
    call    hash_set            ; 0 updated / 1 new / 2 oom
    cmp     rax, 2
    je      .add_oom
    cmp     rax, 1
    jne     .not_new
    inc     r13
.not_new:
    inc     r15
    jmp     .al_next
.done_add:
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.add_oom:
    cmp     qword [rbx+16], 0   ; any member present?
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
    lea     rdi, [rel lc_sadd]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SREM key member [member ...] -> :removed ----
cmd_srem:
    cmp     qword [rel argc], 3
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r13, r13            ; removed counter
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     r15, 2
.rl_next:
    cmp     r15, [rel argc]
    jae     .done_rem
    mov     rdi, rbx
    lea     rax, [rel argv_ptrs]
    mov     rsi, [rax + r15*8]
    lea     rax, [rel argv_lens]
    mov     rdx, [rax + r15*8]
    call    hash_del            ; rax = 1 removed / 0
    add     r13, rax
    inc     r15
    jmp     .rl_next
.done_rem:
    cmp     qword [rbx+16], 0   ; set now empty?
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
    lea     rdi, [rel lc_srem]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SISMEMBER key member -> :0 | :1 ----
cmd_sismember:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
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
    lea     rdi, [rel lc_sismember]
    mov     rsi, 9
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SCARD key -> :count ----
cmd_scard:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_SET
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
    lea     rdi, [rel lc_scard]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- SMEMBERS key -> array of members (insertion order) ----
cmd_smembers:
    cmp     qword [rel argc], 2
    jne     .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .empty
    cmp     qword [rax+40], TYPE_SET
    jne     .wrongtype
    mov     rbx, [rax+24]       ; header
    mov     rdi, [rbx+16]       ; count
    call    reply_array_header
    mov     r12, [rbx]          ; node = head
.walk:
    test    r12, r12
    je      .ret
    mov     rdi, [r12+8]        ; member (field_ptr)
    mov     rsi, [r12+16]       ; field_len
    mov     r14, [r12]          ; save next
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
.wa:
    lea     rdi, [rel lc_smembers]
    mov     rsi, 8
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 5: Route in `src/dispatch.asm`.** Add extern: `extern cmd_sadd, cmd_srem, cmd_sismember, cmd_scard, cmd_smembers`. Add name strings to `.rodata`:
```nasm
name_sadd:      db "SADD"
name_srem:      db "SREM"
name_scard:     db "SCARD"
name_smembers:  db "SMEMBERS"
name_sismember: db "SISMEMBER"
```
In `.len4`, before its `jmp emit_unknown`, add SADD and SREM (pattern: `lea rdi,[rel cmd_upper]` / `lea rsi,[rel name_sadd]` / `mov rdx,4` / `call memcmp_n` / `test rax,rax` / `je cmd_sadd`, then the same for `name_srem`→`cmd_srem`).
In `.len5`, before its `jmp emit_unknown`, add SCARD (`name_scard`, rdx=5, `je cmd_scard`).
In `.len8`, before its `jmp emit_unknown`, add SMEMBERS (`name_smembers`, rdx=8, `je cmd_smembers`).
In `.len9`, before its `jmp emit_unknown`, add SISMEMBER (`name_sismember`, rdx=9, `je cmd_sismember`).

- [ ] **Step 6: Build + GREEN:**
```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/set.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: `OK set: ...conformant`, rc=0. Debug the assembly against the plan if a labeled case fails; don't change the test.

- [ ] **Step 7: Full regression:** `timeout 500 bash tests/wire.sh` → all PASS, exit 0.

- [ ] **Step 8: Commit:**
```bash
git add include/syscalls.inc src/set.asm src/dispatch.asm tests/set.py
git commit -m "set: SADD/SREM/SMEMBERS/SISMEMBER/SCARD (TYPE_SET over the hash machinery)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire into the suite (set.py run + oracle diffs)

**Files:** `tests/wire.sh`.

- [ ] **Step 1: Oracle `check` lines** — insert into the conformance block immediately before its `kill $SRV 2>/dev/null` (after the last existing `check` line):
```bash
check DEL setk
check SADD setk a b c
check SADD setk a d
check SCARD setk
check SISMEMBER setk a
check SISMEMBER setk z
check SCARD setmiss
check SISMEMBER setmiss a
check SREM setk a z
check SCARD setk
check SMEMBERS setk
check SMEMBERS setmiss
check TYPE setk
check SADD
check SREM setk
check SCARD
check SISMEMBER setk
check SMEMBERS
check SET setstr v
check SADD setstr m
check SCARD setstr
```
(`check SMEMBERS setk` relies on asmredis matching valkey's insertion order — it does for these inputs; a `DIFF` here would be a real order divergence to investigate.)

- [ ] **Step 2: Standalone `set.py` run** — append at the end of `tests/wire.sh`:
```bash

# --- Milestone J: Sets conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/set.py 7777 >/tmp/asmj_set.txt 2>&1; then
  echo "PASS set"; st=0
else
  echo "FAIL set: $(cat /tmp/asmj_set.txt)"; st=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $st -eq 0 ] || exit 1
```

- [ ] **Step 3: Run full suite:** `timeout 500 bash tests/wire.sh` → all PASS incl. `PASS conformance` (with set oracle diffs) and `PASS set`, exit 0. Any `DIFF` line is a real divergence — report it.

- [ ] **Step 4: Commit:**
```bash
git add tests/wire.sh
git commit -m "test: wire milestone-J Sets conformance + valkey oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** TYPE_SET → Task 1 Step 1; the 5 commands mirroring hash wrappers → Task 1 Step 4; routing → Step 5; SMEMBERS order-independent test + oracle diffs → Tasks 1/2. `_free_value` needs NO change (TYPE_SET falls through to `hash_free`, verified). All mapped.
- **Placeholder scan:** verbatim NASM/Python/bash; no TODO.
- **Consistency:** every set command checks `[entry+40]==TYPE_SET` for WRONGTYPE; SADD stores members as empty-valued fields (`hash_set` vlen=0); SREM auto-deletes on empty via `[header+16]==0` → `ks_del` (mirrors `cmd_hdel`); SCARD reads `[header+16]`; SMEMBERS iterates head→tail. Dispatch lengths: SADD/SREM=4, SCARD=5, SMEMBERS=8, SISMEMBER=9 (buckets 8/9 exist from milestone I). Stack: 5-push frames for the looping/iterating commands, `sub rsp,8` for the single-shot ones, matching the hash originals they mirror.
- **Scope:** 5 commands, one new file + `TYPE_SET` + routing + test/wiring; two tasks.
