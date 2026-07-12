# Milestone K — SET options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `SET key value [EX s|PX ms|EXAT s|PXAT ms|KEEPTTL] [NX|XX]`, byte-exact vs valkey, leveraging milestone-I's deadline field + keep-TTL flag.

**Architecture:** `cmd_set` moves to a new `src/string.asm`. The plain `SET key value` (argc 3) fast path is unchanged; argc > 3 runs an option parser (mutually-exclusive expire mode + NX/XX), computes an absolute-ms deadline (SET requires value > 0, never deletes), applies NX/XX against a lookup, stores via `ks_set` (keep-TTL flag), and sets `[entry+48]` for a timed set.

**Tech Stack:** x86-64 NASM. Tests: Python RESP client + valkey-cli oracle diff.

**Reference design:** `docs/superpowers/specs/2026-07-12-asmredis-milestone-k-setopts-design.md`

**Ground truth (valkey):** EX/PX/EXAT/PXAT set a TTL; KEEPTTL preserves; plain SET clears. NX set-iff-absent (else `$-1`), XX set-iff-present (else `$-1`). `EX abc`→notint; `EX 0`/`EX -1`→`-ERR invalid expire time in 'set' command`; `EX+PX`/`NX+XX`/`EX+KEEPTTL`/unknown-opt/missing-arg→`-ERR syntax error`. SET never deletes on a past deadline — it stores it.

**ABI:** entered rsp%16==8, calls rsp%16==0. `ks_set(rdi=key,rsi=len,rdx=val,rcx=vlen,r8=keepttl)`→0 ok/1 oom. `ks_lookup(rdi,rsi)`→rax=entry|0. `parse_int(rdi,rsi)`→rax,rdx. `to_upper_buf(rdi,rsi)` uppercases in place. `memcmp_n(rdi,rsi,rdx)`→0 equal. Entry `[48]`=expire_ms. Args at `[argv_ptrs+8*i]`/`[argv_lens+8*i]`, `[argc]`.

---

## Task 1: emit_syntax + SET with options in `src/string.asm`

**Files:** `src/errmsg.asm`, new `src/string.asm`, `src/dispatch.asm`, new `tests/setopt.py`.

- [ ] **Step 1: `src/errmsg.asm`** — add `emit_syntax`. Add `global emit_syntax`. `.rodata`:
```nasm
m_syntax:     db "-ERR syntax error", 13, 10
m_syntax_len  equ $ - m_syntax
```
`.text`:
```nasm
emit_syntax:
    lea     rdi, [rel m_syntax]
    mov     rsi, m_syntax_len
    jmp     append_raw
```

- [ ] **Step 2: Write the failing test `tests/setopt.py`:**
```python
#!/usr/bin/env python3
# Milestone K: SET options (EX/PX/EXAT/PXAT/KEEPTTL/NX/XX). Usage: setopt.py <port>.
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
NOTINT=b"-ERR value is not an integer or out of range"
IEXP=b"-ERR invalid expire time in 'set' command"
SYN=b"-ERR syntax error"
def main():
    if len(sys.argv)<2: print("usage: setopt.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # plain SET still works
        eq(c.do("SET","k","v"), b"+OK", "plain set")
        eq(c.do("GET","k"), b"v", "plain get")
        # EX / PX / TTL readback
        eq(c.do("SET","k","v","EX","100"), b"+OK", "set ex")
        eq(c.do("TTL","k"), b":100", "ttl after ex")
        eq(c.do("SET","k","v","PX","500000"), b"+OK", "set px")
        eq(c.do("TTL","k"), b":500", "ttl after px")
        # plain SET clears TTL; KEEPTTL preserves
        eq(c.do("SET","k","v2"), b"+OK", "reset"); eq(c.do("TTL","k"), b":-1", "plain clears ttl")
        c.do("SET","k","v","EX","100"); eq(c.do("SET","k","w","KEEPTTL"), b"+OK", "keepttl")
        eq(c.do("TTL","k"), b":100", "ttl kept")
        # EXAT future
        eq(c.do("SET","k","v","EXAT","99999999999"), b"+OK", "exat")
        eq(c.do("TTL","k")[:2], b":9", "exat ttl big")
        # NX / XX
        eq(c.do("DEL","n"), b":0", "del n")
        eq(c.do("SET","n","v","NX"), b"+OK", "nx new")
        eq(c.do("SET","n","w","NX"), b"$-1", "nx blocked")
        eq(c.do("GET","n"), b"v", "nx unchanged")
        eq(c.do("SET","n","z","XX"), b"+OK", "xx present")
        eq(c.do("GET","n"), b"z", "xx applied")
        eq(c.do("DEL","m"), b":0", "del m")
        eq(c.do("SET","m","v","XX"), b"$-1", "xx absent")
        eq(c.do("EXISTS","m"), b":0", "xx no create")
        # errors
        eq(c.do("SET","k","v","EX","abc"), NOTINT, "ex notint")
        eq(c.do("SET","k","v","EX","0"), IEXP, "ex 0")
        eq(c.do("SET","k","v","EX","-1"), IEXP, "ex -1")
        eq(c.do("SET","k","v","EX","100","PX","100"), SYN, "ex+px")
        eq(c.do("SET","k","v","NX","XX"), SYN, "nx+xx")
        eq(c.do("SET","k","v","EX","100","KEEPTTL"), SYN, "ex+keepttl")
        eq(c.do("SET","k","v","BADOPT"), SYN, "badopt")
        eq(c.do("SET","k","v","EX"), SYN, "ex missing arg")
        eq(c.do("SET","k"), b"-ERR wrong number of arguments for 'set' command", "arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL setopt: %r"%e); return 1
    if FAILS:
        print("FAIL setopt:"); [print("  "+f) for f in FAILS]; return 1
    print("OK setopt: SET options conformant"); return 0
if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 3: Verify RED** — but note SET currently rejects argc>3 with wrongargs, so the option cases fail:
```bash
make -s all >/dev/null 2>&1; ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/setopt.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: FAIL (SET EX etc. → wrongargs, not the expected replies). rc=1.

- [ ] **Step 4: Create `src/string.asm`** (verbatim):
```nasm
%include "syscalls.inc"
global cmd_set
extern argc, argv_ptrs, argv_lens
extern ks_set, ks_lookup
extern parse_int, reply_simple, reply_null
extern to_upper_buf, memcmp_n
extern emit_oom, emit_wrongargs, emit_notint, emit_invalid_expire, emit_syntax
extern g_now_ms

section .rodata
s_ok:      db "OK"
s_ok_len   equ $ - s_ok
lc_set:    db "set"
o_ex:      db "EX"
o_px:      db "PX"
o_exat:    db "EXAT"
o_pxat:    db "PXAT"
o_keepttl: db "KEEPTTL"
o_nx:      db "NX"
o_xx:      db "XX"

section .bss
optbuf:    resb 8              ; uppercased option token (max "KEEPTTL"=7)

section .text
; cmd_set: SET key value [EX s|PX ms|EXAT s|PXAT ms|KEEPTTL] [NX|XX]
cmd_set:
    cmp     qword [rel argc], 3
    jb      .wa
    ja      .opts
    ; ---- fast path: SET key value ----
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    xor     r8, r8                  ; keepttl = 0
    call    ks_set
    test    rax, rax
    jnz     .oom1
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    add     rsp, 8
    ret
.oom1:
    call    emit_oom
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

    ; ---- options path (argc > 3). r12=expmode r13=valueidx r14=cond r15=i rbx=deadline ----
.opts:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    xor     r12, r12                ; expire mode: 0 none,1 EX,2 PX,3 EXAT,4 PXAT,5 KEEPTTL
    xor     r13, r13                ; expire value arg index
    xor     r14, r14                ; cond: 0 none,1 NX,2 XX
    mov     r15, 3                  ; i = 3
.ploop:
    cmp     r15, [rel argc]
    jae     .parsed
    lea     rax, [rel argv_lens]
    mov     rbx, [rax + r15*8]      ; token len
    cmp     rbx, 7
    ja      .syntax
    ; copy token -> optbuf, then uppercase
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]      ; token ptr
    lea     rsi, [rel optbuf]
    mov     rcx, rbx                ; len
.cpy:
    test    rcx, rcx
    jz      .cpydone
    mov     al, [rdi]
    mov     [rsi], al
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .cpy
.cpydone:
    lea     rdi, [rel optbuf]
    mov     rsi, rbx
    call    to_upper_buf
    cmp     rbx, 2
    je      .len2
    cmp     rbx, 4
    je      .len4
    cmp     rbx, 7
    je      .len7
    jmp     .syntax
.len2:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_ex]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_ex
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_px]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_px
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_nx]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_nx
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_xx]
    mov     rdx, 2
    call    memcmp_n
    test    rax, rax
    je      .set_xx
    jmp     .syntax
.len4:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_exat]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      .set_exat
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_pxat]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      .set_pxat
    jmp     .syntax
.len7:
    lea     rdi, [rel optbuf]
    lea     rsi, [rel o_keepttl]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      .set_keepttl
    jmp     .syntax
.set_ex:
    mov     rcx, 1
    jmp     .expmode
.set_px:
    mov     rcx, 2
    jmp     .expmode
.set_exat:
    mov     rcx, 3
    jmp     .expmode
.set_pxat:
    mov     rcx, 4
.expmode:
    test    r12, r12
    jnz     .syntax                 ; a mode already set
    mov     r12, rcx
    inc     r15                     ; consume the value token
    cmp     r15, [rel argc]
    jae     .syntax                 ; missing value
    mov     r13, r15                ; value arg index
    inc     r15
    jmp     .ploop
.set_keepttl:
    test    r12, r12
    jnz     .syntax
    mov     r12, 5
    inc     r15
    jmp     .ploop
.set_nx:
    test    r14, r14
    jnz     .syntax
    mov     r14, 1
    inc     r15
    jmp     .ploop
.set_xx:
    test    r14, r14
    jnz     .syntax
    mov     r14, 2
    inc     r15
    jmp     .ploop
.parsed:
    xor     rbx, rbx                ; deadline = 0
    test    r12, r12
    jz      .cond                   ; no expire mode
    cmp     r12, 5
    je      .cond                   ; KEEPTTL -> no deadline compute
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r13*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + r13*8]
    call    parse_int               ; rax=value, rdx=valid
    test    rdx, rdx
    jz      .notint
    test    rax, rax
    jle     .invalid                ; value <= 0 -> invalid expire time
    mov     rbx, rax                ; value
    cmp     r12, 2
    je      .add_now                ; PX (ms relative)
    cmp     r12, 4
    je      .deadline_done          ; PXAT (ms absolute)
    ; seconds: EX(1) relative, EXAT(3) absolute
    mov     rax, 9223372036854775   ; LLONG_MAX/1000
    cmp     rbx, rax
    jg      .invalid
    imul    rbx, rbx, 1000
    cmp     r12, 1
    je      .add_now                ; EX
    jmp     .deadline_done          ; EXAT (absolute)
.add_now:
    mov     rax, 0x7fffffffffffffff
    sub     rax, [rel g_now_ms]
    cmp     rbx, rax
    jg      .invalid
    add     rbx, [rel g_now_ms]
.deadline_done:
    ; rbx = absolute ms deadline
.cond:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup               ; rax=entry|0 (passively expires)
    test    r14, r14
    jz      .dostore
    cmp     r14, 1
    je      .nx
    test    rax, rax                ; XX: require present
    jz      .nilreply
    jmp     .dostore
.nx:
    test    rax, rax                ; NX: require absent
    jnz     .nilreply
.dostore:
    xor     r8, r8
    cmp     r12, 5
    jne     .kt0
    mov     r8, 1                   ; KEEPTTL -> keep TTL
.kt0:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]
    mov     rcx, [rel argv_lens + 16]
    call    ks_set                  ; r8 = keepttl
    test    rax, rax
    jnz     .oom2
    test    r12, r12                ; timed set? (mode 1..4)
    jz      .ok
    cmp     r12, 5
    je      .ok
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup               ; entry just stored (not expired)
    mov     [rax+48], rbx           ; expire_ms = deadline
.ok:
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    jmp     .oret
.nilreply:
    call    reply_null              ; $-1
    jmp     .oret
.notint:
    call    emit_notint
    jmp     .oret
.invalid:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
    call    emit_invalid_expire
    jmp     .oret
.syntax:
    call    emit_syntax
    jmp     .oret
.oom2:
    call    emit_oom
.oret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 5: `src/dispatch.asm`** — remove the old `cmd_set` and its rodata; make it extern. Delete the entire `cmd_set:` routine (from `cmd_set:` through its `.wa` block's `ret`, ending right before `; cmd_get:`). Delete the `s_ok:`/`s_ok_len` lines and the `lc_set:` line from `.rodata` (they are only used by the removed `cmd_set`). Add `cmd_set` to an `extern` line (e.g. `extern cmd_set`). The `.len3` routing `... je cmd_set` is unchanged (now resolves to the extern). Build errors about undefined `s_ok`/`lc_set` would mean another user exists — if so, keep the rodata; there is none expected.

- [ ] **Step 6: Build + GREEN:**
```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/setopt.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: `OK setopt: SET options conformant`, rc=0. Debug the assembly against the plan if a labeled case fails.

- [ ] **Step 7: Full regression:** `timeout 500 bash tests/wire.sh` → all PASS, exit 0 (the plain-SET fast path is unchanged, so existing SET tests stay green).

- [ ] **Step 8: Commit:**
```bash
git add src/errmsg.asm src/string.asm src/dispatch.asm tests/setopt.py
git commit -m "string: SET key value [EX|PX|EXAT|PXAT|KEEPTTL] [NX|XX] options

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire into the suite

**Files:** `tests/wire.sh`.

- [ ] **Step 1: Oracle `check` lines** — insert into the conformance block before its `kill $SRV 2>/dev/null` (after the last existing `check` line):
```bash
check SET ko v EX 100
check TTL ko
check SET ko w KEEPTTL
check TTL ko
check SET ko v2
check TTL ko
check DEL kn
check SET kn v NX
check SET kn w NX
check GET kn
check SET kn z XX
check DEL km
check SET km v XX
check EXISTS km
check SET ko v EX abc
check SET ko v EX 0
check SET ko v EX -1
check SET ko v EX 100 PX 100
check SET ko v NX XX
check SET ko v BADOPT
check SET ko v EX
```

- [ ] **Step 2: Standalone `setopt.py` run** — append at the end of `tests/wire.sh`:
```bash

# --- Milestone K: SET options conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/setopt.py 7777 >/tmp/asmk_setopt.txt 2>&1; then
  echo "PASS setopt"; so=0
else
  echo "FAIL setopt: $(cat /tmp/asmk_setopt.txt)"; so=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $so -eq 0 ] || exit 1
```

- [ ] **Step 3: Run full suite:** `timeout 500 bash tests/wire.sh` → all PASS incl. `PASS conformance` and `PASS setopt`, exit 0. Any `DIFF` is a real divergence — report it.

- [ ] **Step 4: Commit:**
```bash
git add tests/wire.sh
git commit -m "test: wire milestone-K SET-options conformance + valkey oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** emit_syntax → T1S1; enhanced cmd_set with the option parser (expire modes, NX/XX, deadline with value>0/no-delete, keep-TTL) → T1S4; move out of dispatch → T1S5; tests+oracle → T1/T2. All mapped.
- **Placeholder scan:** verbatim; no TODO.
- **Consistency:** the plain-SET fast path is byte-identical to the pre-milestone code (only reached at argc==3). Deadline math mirrors `_set_expire` but with `value>0` and no delete-on-past. `keepttl` flag reused (0 clears then explicit deadline store overrides; 5=KEEPTTL keeps). Register roles in `.opts` (r12 mode, r13 value idx, r14 cond, r15 i, rbx deadline) are stable across the internal calls (all callee-saved-preserving). `emit_invalid_expire` is called with name `set`. Stack: 5-push frame in `.opts` (==0 at calls), `sub rsp,8` in fast/`.wa` paths.
- **Scope:** 7 options; new `string.asm` + errmsg + dispatch edit + test/wiring; two tasks.
- **Edge:** value<=0 for any of EX/PX/EXAT/PXAT → invalid (matches `EX 0`/`EX -1`); a past absolute deadline is stored, not deleted; NX/XX evaluated before the store; timed set re-looks-up to set `[48]`.
