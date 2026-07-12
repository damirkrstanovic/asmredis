# Milestone H — Integer counters + EXISTS/TYPE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `INCR`/`DECR`/`INCRBY`/`DECRBY` + `EXISTS`/`TYPE` with byte-exact valkey fidelity, including full `[INT64_MIN, INT64_MAX]` round-trip.

**Architecture:** The four counters share one add-only core (`_incr_by`) in a new `src/counter.asm`; `EXISTS`/`TYPE` are small generic-key commands in `dispatch.asm` beside `DEL`. Supporting the counters requires three contained infra edits: `parse_int` becomes `string2ll`-faithful (strict format + full int64 range), `reply_int` becomes signed, and a new signed `itoa_s` is added. All error bytes were captured live from `valkey-server` (see the design spec).

**Tech Stack:** x86-64 NASM, static no-libc ELF, raw syscalls. Tests: Python RESP client (`tests/counter.py`) + the existing `valkey-cli` oracle diff in `tests/wire.sh`.

**Reference design:** `docs/superpowers/specs/2026-07-12-asmredis-milestone-h-counters-design.md`

**ABI note:** Functions are entered at `rsp%16==8`; the codebase maintains a "calls at `rsp%16==0`" convention via annotated `push`/`sub rsp,8`. (16-byte alignment is cosmetic here — no SSE, raw syscalls — but new code mirrors the existing idioms exactly.) Keyspace entry layout: `[24]=val_ptr [32]=val_len [40]=type`, `TYPE_STR=0 TYPE_LIST=1 TYPE_HASH=2`. API: `ks_lookup(rdi=key,rsi=len)->rax=entry|0`; `ks_set(rdi=key,rsi=len,rdx=val,rcx=vlen)->rax=0 ok/1 oom` (deep-copies key+value into the arena, so a stack buffer as `val` is safe). `parse_int(rdi=ptr,rsi=len)->rax=value,rdx=1 valid/0 invalid`. Command args: `[argv_ptrs+8*i]`,`[argv_lens+8*i]`, count in `[argc]`.

**Makefile:** no change — `SRC := $(wildcard src/*.asm)` picks up `src/counter.asm` automatically.

---

## Task 1: Make `parse_int` string2ll-faithful (strict format + full int64 range)

**Files:**
- Modify: `src/util.asm` (replace the `parse_int` body)

The current `parse_int` accepts leading zeros/`+`-less-but-lenient input and rejects `INT64_MIN`. valkey's `string2ll` (verified) rejects `011`,`00`,`-0`,`+5`,` 5`,`5 ` and accepts the full `[INT64_MIN, INT64_MAX]`. `parse_int` is used only by `list.asm` (LRANGE indices), which valkey also parses with `string2ll`, so strictness is more faithful there too — the full existing suite must stay green.

- [ ] **Step 1: Replace the `parse_int` implementation**

In `src/util.asm`, replace the entire `parse_int` routine (from the `; parse_int(...)` comment through its final `.bad`/`ret`) with:

```nasm
; parse_int(rdi=ptr, rsi=len) -> rax=value (signed), rdx=1 valid / 0 invalid.
; string2ll-faithful: base-10, optional leading '-', NO leading zeros (except the
; single "0"), no '+', no spaces, no "-0"; accepts the full [INT64_MIN, INT64_MAX].
; Leaf (no calls).
parse_int:
    test    rsi, rsi
    je      .bad
    xor     r8, r8                  ; neg = 0
    movzx   rcx, byte [rdi]
    cmp     cl, '-'
    jne     .first
    mov     r8, 1                   ; negative
    inc     rdi
    dec     rsi
    je      .bad                    ; "-" alone
.first:
    movzx   rcx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9                  ; unsigned: catches <'0' and >'9'
    ja      .bad
    jne     .accum                  ; first digit 1..9 -> normal accumulate
    ; first digit is '0': only the exact non-negative single "0" is valid
    test    r8, r8
    jnz     .bad                    ; "-0..." invalid
    cmp     rsi, 1
    jne     .bad                    ; "0" followed by more -> leading zero, invalid
    xor     rax, rax                ; value = 0
    mov     rdx, 1
    ret
.accum:
    xor     rax, rax                ; acc = 0 (unsigned magnitude)
    mov     r9, 1844674407370955161 ; floor((2^64-1)/10), multiply-overflow guard
.dloop:
    movzx   rcx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .bad
    cmp     rax, r9
    ja      .bad                    ; acc*10 would overflow u64
    imul    rax, rax, 10
    add     rax, rcx
    jc      .bad                    ; u64 add carry -> overflow
    inc     rdi
    dec     rsi
    jnz     .dloop
    test    r8, r8
    jnz     .neg
    mov     r10, 0x7fffffffffffffff ; non-negative: acc <= 2^63-1
    cmp     rax, r10
    ja      .bad
    mov     rdx, 1
    ret
.neg:
    mov     r10, 0x8000000000000000 ; negative: acc <= 2^63 (2^63 -> INT64_MIN)
    cmp     rax, r10
    ja      .bad
    neg     rax                     ; two's complement; acc=2^63 -> 0x8000... = INT64_MIN
    mov     rdx, 1
    ret
.bad:
    xor     rax, rax
    xor     rdx, rdx
    ret
```

- [ ] **Step 2: Build**

Run: `make -s clean && make -s all`
Expected: clean build, no errors.

- [ ] **Step 3: Full regression (the LRANGE/list guard)**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — in particular `list-stress` and the `conformance` `LRANGE` diffs, proving the stricter parser did not change accepted list indices.

- [ ] **Step 4: Commit**

```bash
git add src/util.asm
git commit -m "util: make parse_int string2ll-faithful (strict format, full int64 range)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Signed integer output — `reply_int` sign + new `itoa_s`

**Files:**
- Modify: `src/reply.asm` (`reply_int`)
- Modify: `src/util.asm` (add `itoa_s`, export it)

`reply_int` formats via `_put_uint` (unsigned), so a negative reply would be wrong. Make it emit `-` for negatives (mirroring the exact proven `push rdi / call _put_byte / pop rdi` idiom already used for the `:` prefix). Add `itoa_s` (used by the counter core in Task 3) to format a signed value into a caller buffer. No current `reply_int` caller passes a negative, so this is regression-free.

- [ ] **Step 1: Make `reply_int` signed**

In `src/reply.asm`, replace the `reply_int` routine with:

```nasm
reply_int:                       ; rdi=signed value -> ":<n>\r\n"
    push    rdi
    mov     r8b, ':'
    call    _put_byte
    pop     rdi
    test    rdi, rdi
    jns     .mag
    push    rdi                  ; same stack idiom as the ':' emit above
    mov     r8b, '-'
    call    _put_byte
    pop     rdi
    neg     rdi                  ; magnitude (INT64_MIN -> 2^63 unsigned, printed correctly)
.mag:
    call    _put_uint
    call    _put_crlf
    ret
```

- [ ] **Step 2: Add `itoa_s` and export it**

In `src/util.asm`, change the globals line:
```nasm
global itoa_u, memcmp_n, to_upper_buf
```
to:
```nasm
global itoa_u, itoa_s, memcmp_n, to_upper_buf
```
Then add this routine immediately after `itoa_u` (after its `ret`):
```nasm
; itoa_s(rdi=signed value, rsi=out buf >=21) -> rax=length. Emits '-' for
; negatives then the unsigned magnitude via itoa_u (INT64_MIN's magnitude is
; 2^63 via unsigned negation, which itoa_u prints correctly). Calls itoa_u.
itoa_s:
    test    rdi, rdi
    jns     .pos
    mov     byte [rsi], '-'
    neg     rdi                  ; magnitude
    push    rsi                  ; save buf; 1 push -> aligned call
    lea     rsi, [rsi+1]         ; digits go after the '-'
    call    itoa_u               ; rax = digit length
    pop     rsi
    inc     rax                  ; + '-'
    ret
.pos:
    jmp     itoa_u               ; tail call: rdi=value, rsi=buf
```

- [ ] **Step 3: Build**

Run: `make -s clean && make -s all`
Expected: clean build; `itoa_s` resolves; no undefined symbols.

- [ ] **Step 4: Regression (no behavior change yet)**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 (existing `reply_int` callers — `DEL`, list/hash lengths — are all non-negative, so output is unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/reply.asm src/util.asm
git commit -m "reply/util: signed reply_int + itoa_s for negative integer replies

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Counter commands (INCR/DECR/INCRBY/DECRBY) + overflow errors

**Files:**
- Modify: `src/errmsg.asm` (two new error emitters)
- Create: `src/counter.asm` (four commands + shared `_incr_by`)
- Modify: `src/dispatch.asm` (externs + `.len4`/`.len6` routing)
- Create: `tests/counter.py` (counter behavior, exact RESP bytes)

- [ ] **Step 1: Write the failing test (`tests/counter.py`)**

Create `tests/counter.py`:

```python
#!/usr/bin/env python3
# Milestone H counters: INCR/DECR/INCRBY/DECRBY exact RESP-byte conformance.
# EXISTS/TYPE assertions are added in the next task. Usage: counter.py <port>.
# Exit 0 ok / 1 fail.
import socket, sys

def conn(port):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1",port)); s.settimeout(10); return s

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
        if t in (b"+",b"-",b":"): return h        # full framed line, prefix included
        if t==b"$":
            n=int(h[1:])
            if n<0: return h
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*":
            return [s.reply() for _ in range(int(h[1:]))]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()

FAILS=[]
def eq(got,want,label):
    if got!=want: FAILS.append("%s: got %r want %r"%(label,got,want))

NOTINT=b"-ERR value is not an integer or out of range"
IOVF=b"-ERR increment or decrement would overflow"
DOVF=b"-ERR decrement would overflow"
WT=b"-WRONGTYPE Operation against a key holding the wrong kind of value"
def wa(name): return b"-ERR wrong number of arguments for '%s' command"%name.encode()

def counters(c):
    eq(c.do("DEL","cnt"), b":0", "del cnt")
    eq(c.do("INCR","cnt"), b":1", "incr cnt 1")
    eq(c.do("INCR","cnt"), b":2", "incr cnt 2")
    eq(c.do("INCRBY","cnt","10"), b":12", "incrby 10")
    eq(c.do("DECR","cnt"), b":11", "decr")
    eq(c.do("DECRBY","cnt","5"), b":6", "decrby 5")
    eq(c.do("DECRBY","cnt","-4"), b":10", "decrby -4")     # 6 - (-4)
    eq(c.do("DEL","d"), b":1", "del d")
    eq(c.do("DECR","d"), b":-1", "decr fresh -> -1")       # signed reply
    # overflow at INT64_MAX
    eq(c.do("SET","big","9223372036854775807"), b"+OK", "set big MAX")
    eq(c.do("INCR","big"), IOVF, "incr overflow")
    # value one past MAX is not a valid integer
    eq(c.do("SET","p","9223372036854775808"), b"+OK", "set p >MAX")
    eq(c.do("INCR","p"), NOTINT, "incr >MAX value notint")
    # non-integer value, leading zero, bad increment arg
    eq(c.do("SET","s","abc"), b"+OK", "set s abc")
    eq(c.do("INCR","s"), NOTINT, "incr non-int")
    eq(c.do("SET","lz","011"), b"+OK", "set lz 011")
    eq(c.do("INCR","lz"), NOTINT, "incr leading-zero")
    eq(c.do("SET","m","5"), b"+OK", "set m 5")
    eq(c.do("INCRBY","m","xx"), NOTINT, "incrby bad arg")
    # DECRBY LLONG_MIN arg -> distinct message; INCRBY LLONG_MIN arg is valid
    eq(c.do("SET","z","0"), b"+OK", "set z 0")
    eq(c.do("DECRBY","z","-9223372036854775808"), DOVF, "decrby LLONG_MIN")
    eq(c.do("SET","z2","0"), b"+OK", "set z2 0")
    eq(c.do("INCRBY","z2","-9223372036854775808"), b":-9223372036854775808", "incrby LLONG_MIN")
    # WRONGTYPE
    eq(c.do("DEL","L"), b":1", "del L")
    eq(c.do("RPUSH","L","a"), b":1", "rpush L")
    eq(c.do("INCR","L"), WT, "incr wrongtype")
    # full-range round-trip through LLONG_MIN
    eq(c.do("SET","g","-9223372036854775807"), b"+OK", "set g MIN+1")
    eq(c.do("DECR","g"), b":-9223372036854775808", "decr to LLONG_MIN")
    eq(c.do("INCR","g"), b":-9223372036854775807", "incr back from LLONG_MIN")
    # arity
    eq(c.do("INCR"), wa("incr"), "incr arity0")
    eq(c.do("INCR","a","b"), wa("incr"), "incr arity3")
    eq(c.do("DECR"), wa("decr"), "decr arity0")
    eq(c.do("INCRBY","k"), wa("incrby"), "incrby arity")
    eq(c.do("DECRBY","k"), wa("decrby"), "decrby arity")

def main():
    if len(sys.argv)<2: print("usage: counter.py <port>"); return 2
    port=int(sys.argv[1]); c=C(port)
    try:
        counters(c)
    except (EOFError,OSError,ValueError) as e:
        print("FAIL counter: %r"%e); return 1
    if FAILS:
        print("FAIL counter:"); [print("  "+f) for f in FAILS]; return 1
    print("OK counter: INCR/DECR/INCRBY/DECRBY conformant"); return 0

if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
make -s all >/dev/null && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/counter.py 7796; echo "rc=$?"
kill $SRV 2>/dev/null
```
Expected: FAIL (INCR is currently an unknown command, so `c.do("INCR","cnt")` returns the `-ERR unknown command …` line, not `:1`). rc=1.

- [ ] **Step 3: Add the two overflow error emitters (`src/errmsg.asm`)**

Change the globals line:
```nasm
global emit_wrongtype, emit_notint, emit_oom
```
to:
```nasm
global emit_wrongtype, emit_notint, emit_oom
global emit_incrdecr_ovf, emit_decr_ovf
```
Add these strings to the `.rodata` section (next to `m_notint`):
```nasm
m_iovf:          db "-ERR increment or decrement would overflow", 13, 10
m_iovf_len       equ $ - m_iovf
m_dovf:          db "-ERR decrement would overflow", 13, 10
m_dovf_len       equ $ - m_dovf
```
Add these emitters to the `.text` section (next to `emit_notint`):
```nasm
emit_incrdecr_ovf:
    lea     rdi, [rel m_iovf]
    mov     rsi, m_iovf_len
    jmp     append_raw

emit_decr_ovf:
    lea     rdi, [rel m_dovf]
    mov     rsi, m_dovf_len
    jmp     append_raw
```

- [ ] **Step 4: Create `src/counter.asm`**

```nasm
%include "syscalls.inc"
global cmd_incr, cmd_decr, cmd_incrby, cmd_decrby
extern argc, argv_ptrs, argv_lens
extern ks_lookup, ks_set
extern parse_int, itoa_s
extern reply_int
extern emit_wrongargs, emit_wrongtype, emit_notint, emit_oom
extern emit_incrdecr_ovf, emit_decr_ovf

section .rodata
lc_incr:    db "incr"
lc_decr:    db "decr"
lc_incrby:  db "incrby"
lc_decrby:  db "decrby"

section .text
; cmd_incr: INCR key -> :<value+1>
cmd_incr:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     rdi, 1
    jmp     _incr_by                 ; tail call (stack unchanged)
.wa:
    lea     rdi, [rel lc_incr]
    mov     rsi, 4
    sub     rsp, 8                   ; entry ==8 -> ==0 for the call
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_decr: DECR key -> :<value-1>
cmd_decr:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     rdi, -1
    jmp     _incr_by
.wa:
    lea     rdi, [rel lc_decr]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_incrby: INCRBY key increment
cmd_incrby:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8                   ; align calls (==8 -> ==0)
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int                ; rax=incr, rdx=valid
    test    rdx, rdx
    jz      .notint
    add     rsp, 8                   ; restore before tail call
    mov     rdi, rax
    jmp     _incr_by
.notint:
    call    emit_notint
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_incrby]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_decrby: DECRBY key decrement  (= key + (-decrement))
cmd_decrby:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 16]
    mov     rsi, [rel argv_lens + 16]
    call    parse_int                ; rax=decr, rdx=valid
    test    rdx, rdx
    jz      .notint
    mov     rcx, 0x8000000000000000  ; LLONG_MIN cannot be negated
    cmp     rax, rcx
    je      .decrovf
    neg     rax                      ; increment = -decr
    add     rsp, 8
    mov     rdi, rax
    jmp     _incr_by
.decrovf:
    call    emit_decr_ovf
    add     rsp, 8
    ret
.notint:
    call    emit_notint
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_decrby]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _incr_by(rdi = signed increment): shared counter core. Key is argv[1].
; new = current(0 if absent) + increment; store as a string; reply :<new>.
; Errors: WRONGTYPE (non-string key) / not-integer value / overflow / oom.
;   rbx=key ptr  r15=key len  r12=increment  r13=new value.  [rsp..] = digit buffer.
_incr_by:
    push    rbx
    push    r12
    push    r13
    push    r15                      ; 4 pushes: entry ==8 -> ==8
    sub     rsp, 24                  ; digit buffer (>=21); ==8 -> ==0 at calls
    mov     r12, rdi                 ; increment
    mov     rbx, [rel argv_ptrs + 8] ; key ptr
    mov     r15, [rel argv_lens + 8] ; key len
    mov     rdi, rbx
    mov     rsi, r15
    call    ks_lookup                ; rax = entry | 0
    test    rax, rax
    jz      .cur_zero
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]            ; val ptr
    mov     rsi, [rax+32]            ; val len
    call    parse_int                ; rax=val, rdx=valid
    test    rdx, rdx
    jz      .notint
    jmp     .have_cur
.cur_zero:
    xor     rax, rax
.have_cur:
    add     rax, r12                 ; new = current + increment
    jo      .overflow
    mov     r13, rax                 ; new value
    mov     rdi, r13
    lea     rsi, [rsp]               ; digit buffer
    call    itoa_s                   ; rax = length
    mov     rdi, rbx                 ; key ptr
    mov     rsi, r15                 ; key len
    lea     rdx, [rsp]               ; value bytes
    mov     rcx, rax                 ; value len
    call    ks_set                   ; rax = 0 ok / 1 oom
    test    rax, rax
    jnz     .oom
    mov     rdi, r13
    call    reply_int
.done:
    add     rsp, 24
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret
.wrongtype:
    call    emit_wrongtype
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.overflow:
    call    emit_incrdecr_ovf
    jmp     .done
.oom:
    call    emit_oom
    jmp     .done
```

- [ ] **Step 5: Route the four commands in `src/dispatch.asm`**

Add to the `extern` block (after the `cmd_hexists, cmd_hkeys, cmd_hvals` line):
```nasm
extern cmd_incr, cmd_decr, cmd_incrby, cmd_decrby
```
Add the name strings to `.rodata` (after `name_hexists`):
```nasm
name_incr:    db "INCR"
name_decr:    db "DECR"
name_incrby:  db "INCRBY"
name_decrby:  db "DECRBY"
```
In `.len4`, insert INCR/DECR routing before the closing `jmp emit_unknown` (i.e. right after the `je cmd_hlen` block):
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_incr]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_incr
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_decr]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_decr
```
In `.len6`, insert INCRBY/DECRBY routing before its closing `jmp emit_unknown` (after the `je cmd_lrange` block):
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_incrby]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_incrby
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_decrby]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_decrby
```

- [ ] **Step 6: Build and run the test to verify it passes**

```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/counter.py 7796; echo "rc=$?"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
```
Expected: `OK counter: INCR/DECR/INCRBY/DECRBY conformant`, rc=0.

- [ ] **Step 7: Full regression**

Run: `bash tests/wire.sh`
Expected: EVERY existing check PASS, exit 0 (counters don't disturb existing commands).

- [ ] **Step 8: Commit**

```bash
git add src/errmsg.asm src/counter.asm src/dispatch.asm tests/counter.py
git commit -m "counter: INCR/DECR/INCRBY/DECRBY with byte-exact valkey semantics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: EXISTS + TYPE

**Files:**
- Modify: `src/dispatch.asm` (routing + `cmd_exists`, `cmd_type`, rodata)
- Modify: `tests/counter.py` (add EXISTS/TYPE assertions)

- [ ] **Step 1: Extend the failing test**

In `tests/counter.py`, add this function after `counters(c)`:
```python
def generic(c):
    # TYPE across the three types + none, and after INCR (string)
    eq(c.do("SET","ts","v"), b"+OK", "set ts")
    eq(c.do("TYPE","ts"), b"+string", "type string")
    eq(c.do("DEL","tl"), b":1", "del tl")
    eq(c.do("RPUSH","tl","a"), b":1", "rpush tl")
    eq(c.do("TYPE","tl"), b"+list", "type list")
    eq(c.do("DEL","th"), b":1", "del th")
    eq(c.do("HSET","th","f","v"), b":1", "hset th")
    eq(c.do("TYPE","th"), b"+hash", "type hash")
    eq(c.do("TYPE","nope"), b"+none", "type none")
    eq(c.do("DEL","ic"), b":1", "del ic")
    eq(c.do("INCR","ic"), b":1", "incr ic")
    eq(c.do("TYPE","ic"), b"+string", "type after incr")
    # EXISTS: variadic, duplicates counted, missing skipped
    eq(c.do("SET","e1","1"), b"+OK", "set e1")
    eq(c.do("SET","e2","2"), b"+OK", "set e2")
    eq(c.do("DEL","e3"), b":1", "del e3")
    eq(c.do("EXISTS","e1","e2","e3","e1"), b":3", "exists variadic")
    eq(c.do("EXISTS","absent"), b":0", "exists missing")
    # arity
    eq(c.do("EXISTS"), wa("exists"), "exists arity")
    eq(c.do("TYPE"), wa("type"), "type arity0")
    eq(c.do("TYPE","a","b"), wa("type"), "type arity2")
```
And change the `try` body in `main` from:
```python
        counters(c)
```
to:
```python
        counters(c)
        generic(c)
```
And update the success line from:
```python
    print("OK counter: INCR/DECR/INCRBY/DECRBY conformant"); return 0
```
to:
```python
    print("OK counter: INCR/DECR/INCRBY/DECRBY + EXISTS/TYPE conformant"); return 0
```

- [ ] **Step 2: Run to verify the new assertions fail**

```bash
make -s all >/dev/null && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/counter.py 7796; echo "rc=$?"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
```
Expected: FAIL — `TYPE`/`EXISTS` are unknown commands, so their replies are `-ERR unknown command …`. rc=1.

- [ ] **Step 3: Add `cmd_exists` and `cmd_type` to `src/dispatch.asm`**

Add the name strings to `.rodata` (after the `name_decrby` line from Task 3):
```nasm
name_exists:  db "EXISTS"
name_type:    db "TYPE"
lc_exists:    db "exists"
lc_type:      db "type"
t_string:     db "string"
t_list:       db "list"
t_hash:       db "hash"
t_none:       db "none"
```
Add these two routines to `.text` (place them right after `cmd_del`, before `emit_unknown`):
```nasm
; cmd_exists: EXISTS key [key ...] -> :<count>. Each argument looked up
; independently; duplicates counted, missing skipped.
;   rbx = index i, r13 = count.
cmd_exists:
    cmp     qword [rel argc], 2
    jl      .wa
    push    rbx
    push    r13
    sub     rsp, 8                   ; 2 push + 8 -> ==0 at calls
    mov     rbx, 1                   ; i = 1
    xor     r13, r13                 ; count = 0
.loop:
    cmp     rbx, [rel argc]
    jae     .fin
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    call    ks_lookup
    test    rax, rax
    jz      .next
    inc     r13
.next:
    inc     rbx
    jmp     .loop
.fin:
    mov     rdi, r13
    call    reply_int
    add     rsp, 8
    pop     r13
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_exists]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_type: TYPE key -> +string / +list / +hash / +none. Never WRONGTYPE.
cmd_type:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8                   ; align calls
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .none
    mov     rax, [rax+40]            ; type
    cmp     rax, TYPE_STR
    je      .str
    cmp     rax, TYPE_LIST
    je      .list
    lea     rdi, [rel t_hash]        ; TYPE_HASH
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.str:
    lea     rdi, [rel t_string]
    mov     rsi, 6
    call    reply_simple
    add     rsp, 8
    ret
.list:
    lea     rdi, [rel t_list]
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.none:
    lea     rdi, [rel t_none]
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_type]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```
(`dispatch.asm` already `extern`s `ks_lookup`, `reply_simple`, `reply_int`, and `emit_wrongargs`, so no new externs are needed.)

In `.len4`, insert TYPE routing before the closing `jmp emit_unknown` (after the `je cmd_decr` block added in Task 3):
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_type]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_type
```
In `.len6`, insert EXISTS routing before its closing `jmp emit_unknown` (after the `je cmd_decrby` block added in Task 3):
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_exists]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_exists
```

- [ ] **Step 4: Build and run the test to verify it passes**

```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/counter.py 7796; echo "rc=$?"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
```
Expected: `OK counter: INCR/DECR/INCRBY/DECRBY + EXISTS/TYPE conformant`, rc=0.

- [ ] **Step 5: Commit**

```bash
git add src/dispatch.asm tests/counter.py
git commit -m "dispatch: EXISTS (variadic) + TYPE commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire into the suite — `counter.py` run + oracle diffs

**Files:**
- Modify: `tests/wire.sh` (add a `counter` run + `check` lines in the conformance block)

- [ ] **Step 1: Add oracle `check` lines to the conformance block**

In `tests/wire.sh`, inside the conformance block, insert these lines immediately before `kill $SRV 2>/dev/null` (the line right after the last `check GET solo2`):
```bash
check DEL c1
check INCR c1
check INCR c1
check INCRBY c1 10
check DECR c1
check DECRBY c1 4
check DECRBY c1 -2
check SET cmax 9223372036854775807
check INCR cmax
check SET cbad abc
check INCR cbad
check SET clz 011
check INCR clz
check INCRBY cbad notanint
check DECRBY c1 -9223372036854775808
check SET cmin -9223372036854775807
check DECR cmin
check INCR cmin
check RPUSH clist a
check INCR clist
check INCR
check INCRBY k1
check DECRBY k1
check TYPE cmax
check TYPE clist
check HSET chash f v
check TYPE chash
check TYPE cmissing
check EXISTS cmax cbad cmissing cmax
check EXISTS cmissing
check EXISTS
check TYPE
check TYPE a b
```

- [ ] **Step 2: Add a standalone `counter.py` run (exact-byte check)**

Append this block at the very end of `tests/wire.sh` (after the SIGPIPE block):
```bash

# --- Milestone H: counters + EXISTS/TYPE exact-byte conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/counter.py 7777 >/tmp/asmh_counter.txt 2>&1; then
  echo "PASS counter"; ct=0
else
  echo "FAIL counter: $(cat /tmp/asmh_counter.txt)"; ct=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ct -eq 0 ] || exit 1
```

- [ ] **Step 3: Run the full suite**

Run: `bash tests/wire.sh`
Expected: EVERY check PASS, exit 0 — including `PASS conformance` (now covering the counter/EXISTS/TYPE oracle diffs) and `PASS counter`.

- [ ] **Step 4: Commit**

```bash
git add tests/wire.sh
git commit -m "test: wire milestone-H counter conformance + valkey oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Benchmark + docs

**Files:**
- Modify: `docs/benchmark.md`

The SET/GET hot path does not use `reply_int`/`parse_int`/`itoa_s` (SET → `reply_simple`, GET → `reply_bulk`), so no throughput change is expected; this task records that, matching the per-milestone benchmark rhythm.

- [ ] **Step 1: Clean build + green suite**

Run: `make -s clean && make -s all && bash tests/wire.sh`
Expected: all PASS, exit 0.

- [ ] **Step 2: SET/GET sweep**

Same methodology as prior milestones (median of 3, `-c {1,20,50,100,200,500}`, `-d {3,512}`, asmredis:7777 vs Valkey:7778). Save raw output to files; derive the table cells from the files. NOTE (sandbox): chunk the runs so no single Bash command exceeds ~2 min.

- [ ] **Step 3: Append "Milestone H (integer counters + EXISTS/TYPE)" to `docs/benchmark.md`**

Short intro: milestone H adds the counter family and two generic-key commands; the SET/GET path is untouched (still `reply_simple`/`reply_bulk`, no `parse_int`/`itoa_s` on that path), so no regression is expected. Include the two median-of-3 tables, an honest "Reading the numbers" vs the in-run oracle and vs milestone G, `uname -r`, and binary size.

- [ ] **Step 4: Commit**

```bash
git add docs/benchmark.md
git commit -m "docs: milestone-H counters benchmark (no hot-path regression)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** counter core + four commands → Task 3; `parse_int` full-range/strict → Task 1; signed `reply_int` + `itoa_s` → Task 2; two overflow messages → Task 3; EXISTS/TYPE → Task 4; exact-byte test + valkey oracle diff → Tasks 3–5; benchmark → Task 6. All spec sections mapped.
- **Placeholder scan:** all code is complete verbatim NASM/Python/bash; no TODO/TBD.
- **Type/label consistency:** `_incr_by(rdi=increment)` is defined in Task 3 and tail-called by all four wrappers with the same contract; `itoa_s(rdi=value,rsi=buf)->rax=len` defined in Task 2, used in Task 3; `parse_int` contract (`rax=value,rdx=valid`) unchanged in Task 1 so existing `list.asm` callers are unaffected; entry offsets (`+24`/`+32`/`+40`) and `TYPE_*` constants used consistently; error strings match the live-captured valkey bytes exactly (`NOTINT`/`IOVF`/`DOVF`/`WT`/`wa()` in the test mirror `emit_notint`/`emit_incrdecr_ovf`/`emit_decr_ovf`/`emit_wrongtype`/`emit_wrongargs`).
- **Fidelity edges verified live:** leading-zero/`-0`/`+`/space rejection, `INT64_MAX+1` value rejected as not-integer, `DECRBY LLONG_MIN` distinct message, `INCRBY LLONG_MIN` accepted, LLONG_MIN round-trip, lowercase arity names.
