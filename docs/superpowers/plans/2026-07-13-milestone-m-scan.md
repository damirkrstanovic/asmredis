# Milestone M — SCAN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `SCAN cursor [MATCH pattern] [COUNT count]`, resize-safe reverse-binary cursor, glob MATCH.

**Reference design:** `docs/superpowers/specs/2026-07-13-asmredis-milestone-m-scan-design.md`

**Ground truth (valkey):** reply `[cursor_bulk, keys_array]`, cursor `"0"` when done; `SCAN notanumber`→`-ERR invalid cursor`; `COUNT abc`→notint; `COUNT 0`/unknown-opt/missing-arg→syntax error; no cursor→wrongargs. Cursors are implementation-specific (NOT oracle-diffable); only error cases are oracle-diffed.

**ABI:** entered rsp%16==8, calls rsp%16==0. Entry/node layout `[0]=next [8]=key_ptr [16]=key_len`. `parse_int(rdi,rsi)`→rax,rdx. `itoa_u(rdi=val,rsi=buf)`→rax=len. `memcmp_n(rdi,rsi,rdx)`→0 equal. `to_upper_buf(rdi,rsi)`. `reply_bulk(rdi,rsi)`, `reply_array_header(rdi=n)`. Args `[argv_ptrs+8*i]`/`[argv_lens+8*i]`, `[argc]`.

**No benchmark task:** SCAN doesn't touch the GET/SET hot path.

---

## Task 1: ks_scan_prep + SCAN

**Files:** `src/keyspace.asm`, `src/errmsg.asm`, new `src/scan.asm`, `src/dispatch.asm`, new `tests/scan.py`.

- [ ] **Step 1: `src/keyspace.asm`** — add `ks_scan_prep`. Add it to a `global` line. Add to `.text`:
```nasm
; ks_scan_prep() -> rax=ht_table[0] base, rdx=ht_mask[0]. Force-completes any pending
; rehash so the dict is a single table, then returns its base + mask.
ks_scan_prep:
    push    rbx                     ; 1 push -> rsp%16==0 at call
.fin:
    mov     rax, [rel rehashidx]
    test    rax, rax
    js      .done                   ; < 0 -> idle/complete
    call    _rehash_step
    jmp     .fin
.done:
    lea     rax, [rel ht_table]
    mov     rax, [rax]              ; ht_table[0]
    lea     rdx, [rel ht_mask]
    mov     rdx, [rdx]              ; ht_mask[0]
    pop     rbx
    ret
```

- [ ] **Step 2: `src/errmsg.asm`** — add `emit_invalidcursor`. `global emit_invalidcursor`. `.rodata`:
```nasm
m_invcur:     db "-ERR invalid cursor", 13, 10
m_invcur_len  equ $ - m_invcur
```
`.text`:
```nasm
emit_invalidcursor:
    lea     rdi, [rel m_invcur]
    mov     rsi, m_invcur_len
    jmp     append_raw
```

- [ ] **Step 3: Write `tests/scan.py`:**
```python
#!/usr/bin/env python3
# Milestone M: SCAN cursor [MATCH p] [COUNT n]. Coverage + MATCH + errors.
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
            if n<0: return None
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*":
            n=int(h[1:])
            if n<0: return None
            return [s.reply() for _ in range(n)]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()
FAILS=[]
def eq(g,w,l):
    if g!=w: FAILS.append("%s: got %r want %r"%(l,g,w))
def scan_all(c, *opts):
    cur=b"0"; seen=[]
    for _ in range(100000):
        r=c.do("SCAN", cur, *opts)
        cur=r[0]; seen += r[1]
        if cur==b"0": break
    return seen
def main():
    if len(sys.argv)<2: print("usage: scan.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # wipe: delete any pre-existing keys via a full scan
        for k in set(scan_all(c)): c.do("DEL", k)
        eq(scan_all(c), [], "empty keyspace")
        # populate 200 keys and verify full coverage
        exp=set()
        for i in range(200):
            k=("key:%d"%i).encode(); c.do("SET", k, b"v"); exp.add(k)
        got=scan_all(c)
        if sorted(got)!=sorted(exp): FAILS.append("coverage: %d keys, want %d (dupes=%d)"%(len(set(got)),len(exp),len(got)-len(set(got))))
        if set(got)!=exp: FAILS.append("coverage set mismatch")
        # MATCH with a big COUNT returns exactly matching keys
        for k in [b"user:1",b"user:2",b"user:30",b"other"]: c.do("SET",k,b"v"); exp.add(k)
        m=scan_all(c, "MATCH", "user:*", "COUNT", "10000")
        eq(sorted(set(m)), sorted([b"user:1",b"user:2",b"user:30"]), "match user:*")
        # empty keyspace shape
        r=c.do("SCAN","0"); 
        if not (isinstance(r,list) and len(r)==2 and isinstance(r[1],list)): FAILS.append("scan reply shape %r"%r)
        # errors
        eq(c.do("SCAN","notanumber"), b"-ERR invalid cursor", "invalid cursor")
        eq(c.do("SCAN","0","COUNT","abc"), b"-ERR value is not an integer or out of range", "count notint")
        eq(c.do("SCAN","0","COUNT","0"), b"-ERR syntax error", "count 0")
        eq(c.do("SCAN","0","BADOPT"), b"-ERR syntax error", "badopt")
        eq(c.do("SCAN","0","COUNT"), b"-ERR syntax error", "count missing")
        eq(c.do("SCAN"), b"-ERR wrong number of arguments for 'scan' command", "arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL scan: %r"%e); return 1
    if FAILS:
        print("FAIL scan:"); [print("  "+f) for f in FAILS]; return 1
    print("OK scan: cursor coverage + MATCH + errors conformant"); return 0
if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 4: Verify RED:**
```bash
make -s all >/dev/null 2>&1; ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/scan.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected FAIL (SCAN unknown), rc=1.

- [ ] **Step 5: Create `src/scan.asm`** (verbatim):
```nasm
%include "syscalls.inc"
global cmd_scan
extern argc, argv_ptrs, argv_lens
extern ks_scan_prep
extern parse_int, itoa_u, memcmp_n, to_upper_buf
extern reply_bulk, reply_array_header
extern emit_wrongargs, emit_notint, emit_syntax, emit_invalidcursor

section .rodata
lc_scan:  db "scan"
o_match:  db "MATCH"
o_count:  db "COUNT"

section .bss
scan_obuf:  resb 8                 ; uppercased option token
scan_cbuf:  resb 24                ; cursor decimal string
scan_kptr:  resq 4096              ; collected key ptrs
scan_klen:  resq 4096              ; collected key lens
sp_pat:     resq 1                 ; MATCH pattern ptr (0 = none)
sp_patlen:  resq 1
sp_count:   resq 1

section .text
; _rev64(rdi) -> rax: reverse the 64 bits of rdi. Leaf.
_rev64:
    mov     rax, rdi
    mov     rcx, rax                ; swap adjacent bits
    shr     rax, 1
    mov     rdx, 0x5555555555555555
    and     rax, rdx
    and     rcx, rdx
    lea     rax, [rax + rcx*2]
    mov     rcx, rax                ; swap bit-pairs
    shr     rax, 2
    mov     rdx, 0x3333333333333333
    and     rax, rdx
    and     rcx, rdx
    lea     rax, [rax + rcx*4]
    mov     rcx, rax                ; swap nibbles
    shr     rax, 4
    mov     rdx, 0x0f0f0f0f0f0f0f0f
    and     rax, rdx
    and     rcx, rdx
    shl     rcx, 4
    or      rax, rcx
    bswap   rax                     ; swap bytes -> full bit reversal
    ret

; _glob_match(rdi=pat, rsi=plen, rdx=str, rcx=slen) -> rax=1/0. '*','?',literal. Leaf.
;   r8=p r9=s r10=star r11=mark
_glob_match:
    xor     r8, r8
    xor     r9, r9
    mov     r10, -1
    xor     r11, r11
.gloop:
    cmp     r9, rcx
    jae     .gtail
    cmp     r8, rsi
    jae     .gstar
    mov     al, [rdi + r8]
    cmp     al, '*'
    je      .gsetstar
    cmp     al, '?'
    je      .gadv
    cmp     al, [rdx + r9]
    jne     .gstar
.gadv:
    inc     r8
    inc     r9
    jmp     .gloop
.gsetstar:
    mov     r10, r8
    mov     r11, r9
    inc     r8
    jmp     .gloop
.gstar:
    cmp     r10, -1
    je      .gno
    lea     r8, [r10+1]
    inc     r11
    mov     r9, r11
    jmp     .gloop
.gtail:
    cmp     r8, rsi
    jae     .gyes
    mov     al, [rdi + r8]
    cmp     al, '*'
    jne     .gno
    inc     r8
    jmp     .gtail
.gyes:
    mov     eax, 1
    ret
.gno:
    xor     eax, eax
    ret

; cmd_scan: SCAN cursor [MATCH p] [COUNT n]
;   rbx=v(cursor) r12=table r13=mask r14=buckets-left r15=n(collected)
cmd_scan:
    cmp     qword [rel argc], 2
    jb      .wa
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                     ; 5 pushes -> rsp%16==0
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    parse_int
    test    rdx, rdx
    jz      .badcursor
    mov     rbx, rax                ; v = cursor
    mov     qword [rel sp_pat], 0
    mov     qword [rel sp_count], 10
    mov     r15, 2                  ; i
.optloop:
    cmp     r15, [rel argc]
    jae     .optsdone
    lea     rax, [rel argv_lens]
    mov     r14, [rax + r15*8]      ; token len
    cmp     r14, 5
    jne     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rsi, [rel scan_obuf]
    mov     rcx, 5
.ocpy:
    mov     al, [rdi]
    mov     [rsi], al
    inc     rdi
    inc     rsi
    dec     rcx
    jnz     .ocpy
    lea     rdi, [rel scan_obuf]
    mov     rsi, 5
    call    to_upper_buf
    lea     rdi, [rel scan_obuf]
    lea     rsi, [rel o_match]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      .opt_match
    lea     rdi, [rel scan_obuf]
    lea     rsi, [rel o_count]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      .opt_count
    jmp     .syntax
.opt_match:
    inc     r15
    cmp     r15, [rel argc]
    jae     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rcx, [rax + r15*8]
    mov     [rel sp_pat], rcx
    lea     rax, [rel argv_lens]
    mov     rcx, [rax + r15*8]
    mov     [rel sp_patlen], rcx
    inc     r15
    jmp     .optloop
.opt_count:
    inc     r15
    cmp     r15, [rel argc]
    jae     .syntax
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + r15*8]
    call    parse_int
    test    rdx, rdx
    jz      .notint
    test    rax, rax
    jle     .syntax                 ; COUNT < 1
    mov     [rel sp_count], rax
    inc     r15
    jmp     .optloop
.optsdone:
    call    ks_scan_prep            ; rax=table, rdx=mask
    mov     r12, rax
    mov     r13, rdx
    mov     r14, [rel sp_count]     ; buckets to scan
    xor     r15, r15                ; n = 0
.scanloop:
    mov     rax, rbx
    and     rax, r13
    mov     rax, [r12 + rax*8]      ; node = bucket head
.chain:
    test    rax, rax
    jz      .nextbucket
    push    rax                     ; save node
    cmp     qword [rel sp_pat], 0
    je      .collect
    mov     rdi, [rel sp_pat]
    mov     rsi, [rel sp_patlen]
    mov     rdx, [rax+8]            ; key ptr
    mov     rcx, [rax+16]           ; key len
    call    _glob_match
    test    rax, rax
    jz      .skipkey
.collect:
    cmp     r15, 4096
    jae     .skipkey
    pop     rax
    push    rax
    mov     rcx, [rax+8]
    lea     rdx, [rel scan_kptr]
    mov     [rdx + r15*8], rcx
    mov     rcx, [rax+16]
    lea     rdx, [rel scan_klen]
    mov     [rdx + r15*8], rcx
    inc     r15
.skipkey:
    pop     rax
    mov     rax, [rax]              ; node = node->next
    jmp     .chain
.nextbucket:
    mov     rax, r13
    not     rax
    or      rbx, rax                ; v |= ~mask
    mov     rdi, rbx
    call    _rev64
    inc     rax
    mov     rdi, rax
    call    _rev64
    mov     rbx, rax                ; v = rev(rev(v)+1)
    test    rbx, rbx
    jz      .emit                   ; wrapped to 0 -> complete
    dec     r14
    jnz     .scanloop
.emit:
    mov     rdi, 2
    call    reply_array_header      ; [cursor, keys]
    mov     rdi, rbx
    lea     rsi, [rel scan_cbuf]
    call    itoa_u                  ; rax = len
    lea     rdi, [rel scan_cbuf]
    mov     rsi, rax
    call    reply_bulk
    mov     rdi, r15
    call    reply_array_header
    xor     r14, r14                ; i = 0
.emitkeys:
    cmp     r14, r15
    jae     .done
    lea     rax, [rel scan_kptr]
    mov     rdi, [rax + r14*8]
    lea     rax, [rel scan_klen]
    mov     rsi, [rax + r14*8]
    call    reply_bulk
    inc     r14
    jmp     .emitkeys
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.badcursor:
    call    emit_invalidcursor
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.syntax:
    call    emit_syntax
    jmp     .done
.wa:
    lea     rdi, [rel lc_scan]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 6: `src/dispatch.asm`** — `extern cmd_scan`; add `name_scan: db "SCAN"` rodata; in `.len4`, before its `jmp emit_unknown`, add `lea cmd_upper / lea name_scan / mov rdx,4 / call memcmp_n / test rax,rax / je cmd_scan`.

- [ ] **Step 7: Build + GREEN:**
```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/scan.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: `OK scan: ...conformant`, rc=0. If coverage fails (missing/dup keys), the reverse-binary cursor or `_rev64` is wrong — debug against the plan.

- [ ] **Step 8: Full regression:** `timeout 500 bash tests/wire.sh` → all PASS, exit 0. (Transient port-bind flake: if a step reports "setup failed"/"Connection refused" with no `DIFF`, `pkill -x asmredis; sleep 2` and re-run once.)

- [ ] **Step 9: Commit:**
```bash
git add src/keyspace.asm src/errmsg.asm src/scan.asm src/dispatch.asm tests/scan.py
git commit -m "scan: SCAN cursor [MATCH] [COUNT] (reverse-binary cursor + glob)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire into the suite

**Files:** `tests/wire.sh`.

- [ ] **Step 1: Oracle `check` lines (error cases only — cursors differ)** — insert into the conformance block before its `kill $SRV 2>/dev/null`:
```bash
check SCAN notanumber
check SCAN 0 COUNT abc
check SCAN 0 COUNT 0
check SCAN 0 BADOPT
check SCAN 0 COUNT
check SCAN
```

- [ ] **Step 2: Standalone `scan.py` run** — append at the end of `tests/wire.sh`:
```bash

# --- Milestone M: SCAN coverage + MATCH + errors ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/scan.py 7777 >/tmp/asmm_scan.txt 2>&1; then
  echo "PASS scan"; sc=0
else
  echo "FAIL scan: $(cat /tmp/asmm_scan.txt)"; sc=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $sc -eq 0 ] || exit 1
```

- [ ] **Step 3: Run full suite:** `timeout 500 bash tests/wire.sh` → all PASS incl. `PASS conformance` and `PASS scan`, exit 0. (Re-run once on the transient port flake.)

- [ ] **Step 4: Commit:**
```bash
git add tests/wire.sh
git commit -m "test: wire milestone-M SCAN coverage test + error oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** ks_scan_prep → T1S1; emit_invalidcursor → T1S2; cmd_scan + _glob_match + _rev64 → T1S5; routing → T1S6; coverage/MATCH/error tests + error oracle → T1/T2. Mapped.
- **Placeholder scan:** verbatim; no TODO.
- **Consistency:** `_rev64` is the standard 64-bit bit-reverse; the reverse-binary cursor `v|=~mask; rev; inc; rev` matches Redis dictScan; force-rehash-finish gives a single table so the cursor is applied to one mask. Scratch cap 4096 (documented). `_glob_match`/`_rev64` are leaves (their calls-at-odd-rsp inside the chain loop are safe — no SSE). Stack: cmd_scan 5-push frame; the chain loop's `push rax`/`pop rax` are balanced each iteration; `.wa` uses its own `sub rsp,8` before the pushes. Error labels (`.badcursor/.notint/.syntax`) reached after the pushes jump to `.done` which pops 5.
- **Scope:** one command + 2 helpers + a keyspace accessor; two tasks.
- **Not oracle-diffed:** only SCAN's error cases (deterministic) are oracle-checked; the iteration is validated by full-coverage in `scan.py`.
