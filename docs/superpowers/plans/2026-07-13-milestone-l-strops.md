# Milestone L — More string ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `SETNX`/`GETSET`/`APPEND`/`STRLEN`/`MSET`/`MGET`, byte-exact vs valkey, in `src/string.asm`.

**Reference design:** `docs/superpowers/specs/2026-07-13-asmredis-milestone-l-strops-design.md`

**Ground truth (valkey):** SETNX new→:1/exists→:0; GETSET old/nil/WRONGTYPE, clears TTL; APPEND →:newlen, creates-if-missing, PRESERVES TTL, WRONGTYPE on non-string; STRLEN len/:0/WRONGTYPE; MSET→+OK (odd argc); MGET→array, nil for missing AND non-string (never errors).

**ABI:** entered rsp%16==8, calls rsp%16==0. `ks_set(rdi=key,rsi=len,rdx=val,rcx=vlen,r8=keepttl)`→0/1. `ks_lookup(rdi,rsi)`→rax=entry|0. `mem_alloc(rdi=size)`→rax|0. `mem_free(rdi=ptr,rsi=size)`. Entry `[24]`=val_ptr `[32]`=val_len `[40]`=type `[48]`=expire_ms. `reply_int(rdi)`, `reply_bulk(rdi=ptr,rsi=len)`, `reply_null`, `reply_array_header(rdi=n)`, `reply_simple(rdi,rsi)`. Args `[argv_ptrs+8*i]`/`[argv_lens+8*i]`, `[argc]`. `TYPE_STR=0`. `s_ok`/`s_ok_len` already defined in string.asm.

**No benchmark task:** these don't touch the plain GET/SET hot path.

---

## Task 1: The six string commands

**Files:** `src/string.asm`, `src/dispatch.asm`, new `tests/strops.py`.

- [ ] **Step 1: Write `tests/strops.py`:**
```python
#!/usr/bin/env python3
# Milestone L: SETNX/GETSET/APPEND/STRLEN/MSET/MGET. Usage: strops.py <port>.
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
    if len(sys.argv)<2: print("usage: strops.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # SETNX
        eq(c.do("DEL","k"), b":0", "del k")
        eq(c.do("SETNX","k","v"), b":1", "setnx new")
        eq(c.do("SETNX","k","w"), b":0", "setnx exists")
        eq(c.do("GET","k"), b"v", "setnx unchanged")
        # GETSET
        eq(c.do("GETSET","k","new"), b"v", "getset old")
        eq(c.do("GET","k"), b"new", "getset applied")
        eq(c.do("DEL","fr"), b":0","del fr"); eq(c.do("GETSET","fr","v"), b"$-1", "getset missing")
        eq(c.do("DEL","L"), b":0","del L"); eq(c.do("RPUSH","L","a"), b":1","rpush L")
        eq(c.do("GETSET","L","v"), WT, "getset wrongtype")
        # APPEND
        eq(c.do("DEL","a"), b":0","del a")
        eq(c.do("APPEND","a","hello"), b":5", "append new")
        eq(c.do("APPEND","a","world"), b":10", "append more")
        eq(c.do("GET","a"), b"helloworld", "append value")
        eq(c.do("APPEND","L","x"), WT, "append wrongtype")
        # APPEND preserves TTL
        eq(c.do("SET","at","v"), b"+OK","set at"); c.do("EXPIRE","at","100"); c.do("APPEND","at","x")
        eq(c.do("TTL","at"), b":100", "append keeps ttl")
        # STRLEN
        eq(c.do("SET","s","hello"), b"+OK","set s"); eq(c.do("STRLEN","s"), b":5", "strlen")
        eq(c.do("STRLEN","nope"), b":0", "strlen missing")
        eq(c.do("STRLEN","L"), WT, "strlen wrongtype")
        # MSET / MGET
        eq(c.do("MSET","x","1","y","2","z","3"), b"+OK", "mset")
        eq(c.do("MGET","x","y","nope","L"), [b"1",b"2",b"$-1",b"$-1"], "mget mixed")
        eq(c.do("MSET","x","1","y"), wa("mset"), "mset odd")
        # arity
        eq(c.do("SETNX","k"), wa("setnx"), "setnx arity")
        eq(c.do("GETSET","k"), wa("getset"), "getset arity")
        eq(c.do("APPEND","k"), wa("append"), "append arity")
        eq(c.do("STRLEN"), wa("strlen"), "strlen arity")
        eq(c.do("MGET"), wa("mget"), "mget arity")
        eq(c.do("MSET"), wa("mset"), "mset arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL strops: %r"%e); return 1
    if FAILS:
        print("FAIL strops:"); [print("  "+f) for f in FAILS]; return 1
    print("OK strops: SETNX/GETSET/APPEND/STRLEN/MSET/MGET conformant"); return 0
if __name__=="__main__": sys.exit(main())
```
(Note: `MGET` returns bulk strings for present keys and `$-1` framed lines for nils; the client's `reply()` returns the raw `$-1` line for negative bulk, so the expected list mixes `b"1"` and `b"$-1"`.)

- [ ] **Step 2: Verify RED:**
```bash
make -s all >/dev/null 2>&1; ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/strops.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected FAIL (SETNX unknown), rc=1.

- [ ] **Step 3: `src/string.asm`** — extend the extern block with:
```nasm
extern mem_alloc, mem_free
extern reply_bulk, reply_int, reply_array_header
extern emit_wrongtype
```
Add `global cmd_setnx, cmd_getset, cmd_append, cmd_strlen, cmd_mset, cmd_mget` to the globals line. Add to `.rodata`:
```nasm
lc_setnx:  db "setnx"
lc_getset: db "getset"
lc_append: db "append"
lc_strlen: db "strlen"
lc_mset:   db "mset"
lc_mget:   db "mget"
```
Add these routines to `.text` (verbatim):
```nasm
; ---- SETNX key value -> :1 set / :0 exists ----
cmd_setnx:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jnz     .exists
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    mov     rdi, 1
    call    reply_int
    add     rsp, 8
    ret
.exists:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.oom:
    call    emit_oom
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_setnx]
    mov     rsi, 5
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- GETSET key value -> old value | nil ----
cmd_getset:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .oldnil
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]           ; old val (copied into output before ks_set frees it)
    mov     rsi, [rax+32]
    call    reply_bulk
    jmp     .store
.oldnil:
    call    reply_null
.store:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set                  ; keepttl=0; OOM keeps old value (reply already old)
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_getset]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- APPEND key value -> :new_length ----  rbx=entry r12=newbuf r13=newlen
cmd_append:
    cmp     qword [rel argc], 3
    jne     .wa
    push    rbx
    push    r12
    push    r13                     ; 3 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .create
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rbx, rax                ; entry
    mov     r13, [rbx+32]           ; oldlen
    add     r13, [rel argv_lens + 16] ; + vallen = newlen
    mov     rdi, r13
    call    mem_alloc
    test    rax, rax
    jz      .oom
    mov     r12, rax                ; newbuf
    mov     rdi, r12                ; copy old bytes
    mov     rsi, [rbx+24]
    mov     rcx, [rbx+32]
    rep     movsb                   ; rdi now at newbuf+oldlen
    mov     rsi, [rel argv_ptrs + 16] ; copy appended bytes
    mov     rcx, [rel argv_lens + 16]
    rep     movsb
    mov     rdi, [rbx+24]           ; free old value
    mov     rsi, [rbx+32]
    call    mem_free
    mov     [rbx+24], r12           ; val_ptr = newbuf
    mov     [rbx+32], r13           ; val_len = newlen  ([48] TTL untouched)
    mov     rdi, r13
    call    reply_int
    jmp     .ret
.create:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    mov     rdi, [rel argv_lens + 16] ; new length = value length
    call    reply_int
    jmp     .ret
.wrongtype:
    call    emit_wrongtype
    jmp     .ret
.oom:
    call    emit_oom
.ret:
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_append]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- STRLEN key -> :len ----
cmd_strlen:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+32]
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_strlen]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- MSET key value [key value ...] -> +OK ----  rbx=index
cmd_mset:
    mov     rax, [rel argc]
    cmp     rax, 3
    jb      .wa
    test    rax, 1                  ; even argc -> incomplete pair
    jz      .wa
    push    rbx                     ; 1 push -> rsp%16==0
    mov     rbx, 1
.next:
    cmp     rbx, [rel argc]
    jae     .done
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    lea     rax, [rel argv_ptrs]
    mov     rdx, [rax + rbx*8 + 8]
    lea     rax, [rel argv_lens]
    mov     rcx, [rax + rbx*8 + 8]
    xor     r8, r8
    call    ks_set
    test    rax, rax
    jnz     .oom
    add     rbx, 2
    jmp     .next
.done:
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    pop     rbx
    ret
.oom:
    call    emit_oom
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_mset]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; ---- MGET key [key ...] -> array (nil for missing/wrong-type) ----  rbx=index
cmd_mget:
    cmp     qword [rel argc], 2
    jb      .wa
    push    rbx                     ; 1 push -> rsp%16==0
    mov     rbx, [rel argc]
    dec     rbx
    mov     rdi, rbx
    call    reply_array_header
    mov     rbx, 1
.next:
    cmp     rbx, [rel argc]
    jae     .done
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    call    ks_lookup
    test    rax, rax
    jz      .nil
    cmp     qword [rax+40], TYPE_STR
    jne     .nil
    mov     rdi, [rax+24]
    mov     rsi, [rax+32]
    call    reply_bulk
    jmp     .adv
.nil:
    call    reply_null
.adv:
    inc     rbx
    jmp     .next
.done:
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_mget]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 4: `src/dispatch.asm`** — add `extern cmd_setnx, cmd_getset, cmd_append, cmd_strlen, cmd_mset, cmd_mget`. Add name rodata:
```nasm
name_mset:   db "MSET"
name_mget:   db "MGET"
name_setnx:  db "SETNX"
name_getset: db "GETSET"
name_append: db "APPEND"
name_strlen: db "STRLEN"
```
Route (each a `lea cmd_upper / lea name_X / mov rdx,LEN / call memcmp_n / test rax,rax / je cmd_X` block before that bucket's `jmp emit_unknown`): `.len4` → MSET, MGET; `.len5` → SETNX; `.len6` → GETSET, APPEND, STRLEN.

- [ ] **Step 5: Build + GREEN:**
```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/strops.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: `OK strops: ...conformant`, rc=0.

- [ ] **Step 6: Full regression:** `timeout 500 bash tests/wire.sh` → all PASS, exit 0.

- [ ] **Step 7: Commit:**
```bash
git add src/string.asm src/dispatch.asm tests/strops.py
git commit -m "string: SETNX/GETSET/APPEND/STRLEN/MSET/MGET

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire into the suite

**Files:** `tests/wire.sh`.

- [ ] **Step 1: Oracle `check` lines** — insert into the conformance block before its `kill $SRV 2>/dev/null` (after the last existing `check`):
```bash
check DEL snk
check SETNX snk v
check SETNX snk w
check GET snk
check GETSET snk new
check GET snk
check DEL frs
check GETSET frs v
check DEL apk
check APPEND apk hello
check APPEND apk world
check GET apk
check STRLEN apk
check STRLEN nokeyz
check MSET ma 1 mb 2 mc 3
check MGET ma mb nokeyz
check GET ma
check MSET ma 1 mb
check RPUSH lst a
check GETSET lst v
check APPEND lst x
check STRLEN lst
check MGET ma lst nokeyz
check SETNX
check STRLEN
check MGET
check MSET
```

- [ ] **Step 2: Standalone `strops.py` run** — append at the end of `tests/wire.sh`:
```bash

# --- Milestone L: string ops conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/strops.py 7777 >/tmp/asml_strops.txt 2>&1; then
  echo "PASS strops"; sp=0
else
  echo "FAIL strops: $(cat /tmp/asml_strops.txt)"; sp=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $sp -eq 0 ] || exit 1
```

- [ ] **Step 3: Run full suite:** `timeout 500 bash tests/wire.sh` → all PASS incl. `PASS conformance` and `PASS strops`, exit 0. Any `DIFF` is a real divergence — report it.

- [ ] **Step 4: Commit:**
```bash
git add tests/wire.sh
git commit -m "test: wire milestone-L string-ops conformance + valkey oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** all 6 commands → T1S3; routing → T1S4; test/oracle → T1/T2. Mapped.
- **Placeholder scan:** verbatim; no TODO.
- **Consistency:** APPEND preserves `[48]` (in-place value swap, `mem_alloc`/`mem_free`); GETSET replies old before `ks_set` frees it; MGET nils for missing/wrong-type; MSET odd-argc arity (`test rax,1`); WRONGTYPE via `[entry+40]!=TYPE_STR`. Stack: 3-push (append), 1-push (mset/mget), `sub rsp,8` (setnx/getset/strlen and all `.wa`) — all reaching calls at rsp%16==0. Dispatch lengths MSET/MGET=4, SETNX=5, GETSET/APPEND/STRLEN=6 (buckets exist).
- **Scope:** 6 commands in `string.asm`; two tasks.
