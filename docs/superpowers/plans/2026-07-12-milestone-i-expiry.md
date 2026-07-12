# Milestone I — Key expiration (TTL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `EXPIRE`/`PEXPIRE`/`EXPIREAT`/`PEXPIREAT`/`TTL`/`PTTL`/`PERSIST` with byte-exact valkey semantics, passive expiration on access, and a best-effort active reaper.

**Architecture:** An 8-byte absolute-ms deadline at entry `[48]` (`0`=none; `ENTRY_SZ` 48→56, same 64-byte class). A cached clock `g_now_ms` refreshed once per epoll wakeup via `clock_gettime`. Passive expiration is baked into `ks_lookup` (every reader gets it free). `ks_set` gains a keep-TTL flag so SET clears and INCR preserves. Active expiration is a bounded bucket-cursor sweep in `keyspace.asm`, driven by switching the epoll loop to a 100 ms tick.

**Tech Stack:** x86-64 NASM, static no-libc ELF, raw syscalls. Tests: Python RESP client + the valkey-cli oracle diff in `wire.sh`.

**Reference design:** `docs/superpowers/specs/2026-07-12-asmredis-milestone-i-expiry-design.md`

**Ground truth (captured live from valkey; do not change test expectations without re-checking the oracle):** EXPIRE→`:1`/`:0`; TTL→`-2`(missing)/`-1`(no ttl)/secs; PERSIST→`:1`/`:0`; past/zero/negative time deletes + returns `:1`; TTL rounds `(rem_ms+500)/1000` and **can be 0** for a live key (`PEXPIRE 100`→`TTL 0`,`PTTL 94`); SET clears TTL, INCR/RPUSH/HSET preserve it; bad time→`emit_notint`; overflow→`-ERR invalid expire time in '<cmd>' command`; the time arg is validated **before** the key-existence check.

**ABI:** functions entered at `rsp%16==8`, calls at `rsp%16==0`. Entry layout after this milestone: `[0]next [8]key_ptr [16]key_len [24]val_ptr [32]val_len [40]type [48]expire_ms`. `parse_int(rdi,rsi)->rax,rdx`; `ks_lookup(rdi,rsi)->rax=entry|0`; `ks_del(rdi,rsi)->rax`; `reply_int(rdi)`; args at `[argv_ptrs+8*i]`,`[argv_lens+8*i]`, `[argc]`.

**Known intentional divergence:** `EXPIRE k 1 2` → valkey `-ERR Unsupported option 2` (Redis-7 NX/XX/GT/LT flags, out of scope); we return `wrongargs` for any `argc≠3`. 4+-arg cases are kept out of the oracle diff.

---

## Task 1: Time source + deadline field + passive expiration infra

**Files:** `include/syscalls.inc`, new `src/expire.asm`, `src/keyspace.asm`, `src/dispatch.asm` (cmd_set), `src/counter.asm` (_incr_by), `src/net.asm`, `src/main.asm`.

After this task: the clock, the `[48]` field, `ks_set`'s keep-TTL flag, and passive expiration exist and are wired, but no TTL-setting command exists yet — so no key ever has a TTL and **all existing behavior is unchanged**. Full suite stays green.

- [ ] **Step 1: `include/syscalls.inc`** — grow the entry, add clock constants.

Change `%define ENTRY_SZ 48 ...` to:
```nasm
%define ENTRY_SZ   56          ; entry incl. type + 8-byte expire_ms at [48] (still class 64)
```
Add (near the syscall numbers / tunables):
```nasm
%define SYS_clock_gettime  228
%define CLOCK_REALTIME     0
%define EXPIRE_TICK_MS     100         ; epoll timeout that drives the active reaper
%define EXPIRE_BUCKETS     20          ; buckets scanned per active-expire cycle
```

- [ ] **Step 2: create `src/expire.asm`** with the clock helper and `g_now_ms` (commands come in Task 2).

```nasm
%include "syscalls.inc"
global time_refresh, g_now_ms

section .bss
g_now_ms:    resq 1                     ; cached CLOCK_REALTIME milliseconds
ts_buf:      resq 2                     ; struct timespec {tv_sec, tv_nsec}

section .text
; time_refresh(): g_now_ms = now in ms. Clobbers rax,rcx,rdx,rsi,rdi,r8,r9,r10,r11.
; Preserves rbx,rbp,r12-r15.
time_refresh:
    mov     rax, SYS_clock_gettime
    mov     rdi, CLOCK_REALTIME
    lea     rsi, [rel ts_buf]
    syscall
    mov     r8, [rel ts_buf]           ; tv_sec
    imul    r8, r8, 1000               ; sec*1000
    mov     rax, [rel ts_buf+8]        ; tv_nsec (< 1e9)
    xor     rdx, rdx
    mov     r9, 1000000
    div     r9                         ; rax = nsec/1e6 (0..999)
    add     rax, r8
    mov     [rel g_now_ms], rax
    ret
```

- [ ] **Step 3: `src/keyspace.asm`** — passive expiration in `ks_lookup`, keep-TTL flag in `ks_set`, init `[48]=0` on entry creation.

(a) Add to the extern list at the top (it already externs `mem_alloc` etc.):
```nasm
extern g_now_ms
```
(b) In `ks_insert`, after the `mov [r14+40], rcx` that zeroes the type (the `xor rcx,rcx` block initialising val_ptr/val_len/type), add one more zero-store so the new deadline field is clean:
```nasm
    mov     [r14+48], rcx           ; expire_ms = 0 (no TTL)
```
(c) In `ks_set`'s **insert** path, right after `mov qword [rax+40], TYPE_STR` (the new-entry field init, before `mov rdi, rax` / `call _insert_entry`), add:
```nasm
    mov     qword [rax+48], 0       ; expire_ms = 0 (new key: no TTL)
```
(d) Give `ks_set` a keep-TTL flag: `ks_set(rdi=key, rsi=len, rdx=val, rcx=vlen, r8=keepttl)` — `r8=0` clears any existing TTL on a successful overwrite (SET semantics), `r8=1` preserves it (INCR). `r8` is caller-saved (clobbered by the first internal `call`), so stash it in `rbx` at the top; on the overwrite path move it to `r12` (whose `key` value is dead once `_find` has run) so it survives `_copy_arena`/`_free_value`. **No frame/alignment change.**

  - At the top of `ks_set`, right after the `mov r12,rdi … mov r15,rcx` argument saves (and before `call _rehash_step`), add:
    ```nasm
    mov     rbx, r8                 ; stash keepttl (rbx survives _rehash_step/_find)
    ```
  - The **overwrite** path currently begins (after `je .insert` is not taken, `rax`=entry) with `mov rbx, rax` (entry). Replace that single line with:
    ```nasm
    mov     r12, rbx                ; keepttl -> r12 (key no longer needed on this path)
    mov     rbx, rax                ; entry
    ```
  - Then, on the overwrite path, after the existing `mov qword [rbx+40], TYPE_STR` and **before** `jmp .ok`, add (clears TTL only after the value swap has succeeded, so an OOM leaves the old value *and* its TTL intact):
    ```nasm
    test    r12, r12                ; keepttl?
    jnz     .ok
    mov     qword [rbx+48], 0       ; SET semantics: clear TTL on successful overwrite
    ```
  (The `.insert` path is unchanged — it reuses `rbx` for the key copy and already sets `[48]=0` via (c); `r12` stays the key there. All internal calls in `ks_set` preserve `rbx`/`r12`.)

(e) Bake passive expiration into `ks_lookup`. It currently ends: `call _find` / `add rsp,8` / `pop r13` / `pop r12` / `ret`, with `r12`=key and `r13`=len still live. Replace that tail with:
```nasm
    call    _find                   ; rax = entry | 0 ; r12=key, r13=len
    test    rax, rax
    jz      .ret
    mov     rcx, [rax+48]           ; expire_ms
    test    rcx, rcx
    jz      .ret                    ; no TTL
    cmp     rcx, [rel g_now_ms]
    ja      .ret                    ; deadline > now -> still live
    ; expired: delete (ks_del does not call ks_lookup -> no recursion) and miss
    mov     rdi, r12
    mov     rsi, r13
    call    ks_del
    xor     rax, rax
.ret:
    add     rsp, 8
    pop     r13
    pop     r12
    ret
```

- [ ] **Step 4: `src/dispatch.asm` (`cmd_set`)** — pass keep-TTL flag 0 (SET clears TTL).

`cmd_set` calls `ks_set` with key/val in rdi/rsi/rdx/rcx. Immediately before its `call ks_set`, add:
```nasm
    xor     r8, r8                  ; keepttl = 0 (SET clears any TTL)
```

- [ ] **Step 5: `src/counter.asm` (`_incr_by`)** — pass keep-TTL flag 1 (INCR preserves TTL).

In `_incr_by`, right before its `call ks_set`, add:
```nasm
    mov     r8, 1                   ; keepttl = 1 (INCR/DECR/INCRBY/DECRBY preserve TTL)
```
(All four counter commands funnel through `_incr_by`, so this one line covers them.)

- [ ] **Step 6: `src/net.asm`** — refresh the clock on each wakeup (timeout stays -1 in this task).

Add to the extern list: `extern time_refresh`. Replace the `.wait` block's tail (`syscall` / `test rax,rax` / `jle .wait` / `mov r15,rax` / `xor r14,r14`) with:
```nasm
    syscall
    mov     r15, rax                     ; n (may be <0 on EINTR)
    call    time_refresh                 ; refresh g_now_ms before processing
    test    r15, r15
    jle     .wait
    xor     r14, r14                     ; i = 0
```
(`time_refresh` preserves r12–r15/rbx/rbp, so the loop state is intact.)

- [ ] **Step 7: `src/main.asm`** — one clock refresh before the loop.

Add `extern time_refresh`. In the `.have_port` init block (after `call ks_init`, before `add rsp,8`), add:
```nasm
    call    time_refresh                 ; seed g_now_ms before net_serve
```

- [ ] **Step 8: Build + full regression.**

Run: `make -s clean && make -s all && timeout 500 bash tests/wire.sh`
Expected: clean build; EVERY check PASS, exit 0. No key can have a TTL yet, so behavior is identical to before; this proves the `ENTRY_SZ`/`ks_set`-signature/`ks_lookup` changes didn't regress SET/GET/DEL/INCR/list/hash.

- [ ] **Step 9: Commit.**
```bash
git add include/syscalls.inc src/expire.asm src/keyspace.asm src/dispatch.asm src/counter.asm src/net.asm src/main.asm
git commit -m "expire: clock + per-key deadline field + passive-expire infra (no commands yet)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The seven expiry commands

**Files:** `src/errmsg.asm`, `src/expire.asm`, `src/dispatch.asm`, new `tests/expire.py`.

- [ ] **Step 1: Write the failing test `tests/expire.py`.**

```python
#!/usr/bin/env python3
# Milestone I: EXPIRE/PEXPIRE/EXPIREAT/PEXPIREAT/TTL/PTTL/PERSIST conformance.
# Deterministic cases use past absolute timestamps (no sleep); one real-time
# check polls a short PEXPIRE. Usage: expire.py <port>. Exit 0 ok / 1 fail.
import socket, sys, time

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
def iexp(n): return b"-ERR invalid expire time in '%s' command"%n.encode()
def wa(n): return b"-ERR wrong number of arguments for '%s' command"%n.encode()

def main():
    if len(sys.argv)<2: print("usage: expire.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # return values
        eq(c.do("SET","foo","bar"), b"+OK", "set foo")
        eq(c.do("EXPIRE","foo","100"), b":1", "expire foo")
        eq(c.do("TTL","foo"), b":100", "ttl foo")           # <500ms elapsed -> 100
        eq(c.do("EXPIRE","nope","100"), b":0", "expire missing")
        eq(c.do("SET","nt","v"), b"+OK", "set nt")
        eq(c.do("TTL","nt"), b":-1", "ttl no-ttl")
        eq(c.do("TTL","gone"), b":-2", "ttl missing")
        eq(c.do("PTTL","gone"), b":-2", "pttl missing")
        # PERSIST
        eq(c.do("PERSIST","foo"), b":1", "persist had-ttl")
        eq(c.do("PERSIST","foo"), b":0", "persist no-ttl")
        eq(c.do("PERSIST","gone"), b":0", "persist missing")
        # past/zero/negative delete the key
        eq(c.do("SET","d1","v"), b"+OK", "set d1"); eq(c.do("EXPIRE","d1","-1"), b":1", "expire -1")
        eq(c.do("GET","d1"), b"$-1", "d1 gone"); eq(c.do("TTL","d1"), b":-2", "ttl d1 -2")
        eq(c.do("SET","d2","v"), b"+OK", "set d2"); eq(c.do("EXPIRE","d2","0"), b":1", "expire 0")
        eq(c.do("EXISTS","d2"), b":0", "d2 gone")
        eq(c.do("SET","d3","v"), b"+OK", "set d3"); eq(c.do("EXPIREAT","d3","1"), b":1", "expireat past")
        eq(c.do("EXISTS","d3"), b":0", "d3 gone"); eq(c.do("TYPE","d3"), b"+none", "type d3 none")
        eq(c.do("SET","d4","v"), b"+OK", "set d4"); eq(c.do("PEXPIREAT","d4","1"), b":1", "pexpireat past")
        eq(c.do("EXISTS","d4"), b":0", "d4 gone")
        # SET clears TTL; INCR/RPUSH/HSET preserve
        eq(c.do("SET","s1","v"), b"+OK","s1"); c.do("EXPIRE","s1","100"); eq(c.do("SET","s1","v2"), b"+OK","reset s1"); eq(c.do("TTL","s1"), b":-1", "set clears ttl")
        eq(c.do("SET","n1","1"), b"+OK","n1"); c.do("EXPIRE","n1","100"); c.do("INCR","n1"); eq(c.do("TTL","n1"), b":100", "incr keeps ttl")
        c.do("DEL","l1"); c.do("RPUSH","l1","a"); c.do("EXPIRE","l1","100"); c.do("RPUSH","l1","b"); eq(c.do("TTL","l1"), b":100", "rpush keeps ttl")
        c.do("DEL","h1"); c.do("HSET","h1","f","v"); c.do("EXPIRE","h1","100"); c.do("HSET","h1","g","w"); eq(c.do("TTL","h1"), b":100", "hset keeps ttl")
        # ms variants + rounding (TTL can be 0 for a live key)
        eq(c.do("SET","r1","v"), b"+OK","r1"); eq(c.do("PEXPIRE","r1","600000"), b":1","pexpire r1"); eq(c.do("TTL","r1"), b":600", "pexpire 600000 -> ttl 600")
        # errors
        eq(c.do("EXPIRE","foo","abc"), NOTINT, "expire notint")
        eq(c.do("EXPIRE","nope","abc"), NOTINT, "expire notint before key-check")
        eq(c.do("EXPIRE","foo","9999999999999999"), iexp("expire"), "expire overflow")
        eq(c.do("EXPIRE","foo","-9999999999999999"), iexp("expire"), "expire neg-overflow")
        eq(c.do("PEXPIRE","foo","9223372036854775807"), iexp("pexpire"), "pexpire base-overflow")
        eq(c.do("EXPIREAT","foo","9999999999999999"), iexp("expireat"), "expireat overflow")
        eq(c.do("EXPIRE"), wa("expire"), "expire arity")
        eq(c.do("TTL"), wa("ttl"), "ttl arity")
        eq(c.do("PERSIST"), wa("persist"), "persist arity")
        eq(c.do("PEXPIREAT","foo"), wa("pexpireat"), "pexpireat arity")
        # real-time: a short TTL actually elapses and the key vanishes
        eq(c.do("SET","rt","v"), b"+OK","rt"); c.do("PEXPIRE","rt","150")
        gone=False; deadline=time.time()+3
        while time.time()<deadline:
            if c.do("GET","rt")==b"$-1": gone=True; break
            time.sleep(0.05)
        if not gone: FAILS.append("real-time expiry: key did not expire within 3s")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL expire: %r"%e); return 1
    if FAILS:
        print("FAIL expire:"); [print("  "+f) for f in FAILS]; return 1
    print("OK expire: TTL family conformant"); return 0

if __name__=="__main__": sys.exit(main())
```

- [ ] **Step 2: Run to verify RED.**
```bash
make -s all >/dev/null 2>&1; ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/expire.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: FAIL (EXPIRE is an unknown command). rc=1.

- [ ] **Step 3: `src/errmsg.asm`** — add `emit_invalid_expire`.

Add to a `global` line: `global emit_invalid_expire`. Add to `.rodata`:
```nasm
iexp_pre:     db "-ERR invalid expire time in '"
iexp_pre_len  equ $ - iexp_pre
iexp_post:    db "' command", 13, 10
iexp_post_len equ $ - iexp_post
```
Add to `.text` (mirrors `emit_wrongargs`; entered at rsp%16==8):
```nasm
; emit_invalid_expire(rdi=lowercase name ptr, rsi=name len)
emit_invalid_expire:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rel iexp_pre]
    mov     rsi, iexp_pre_len
    call    append_raw
    mov     rdi, rbx
    mov     rsi, r12
    call    append_raw
    lea     rdi, [rel iexp_post]
    mov     rsi, iexp_post_len
    call    append_raw
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
```

- [ ] **Step 4: `src/expire.asm`** — add the seven commands and their shared cores.

Extend the top of the file:
```nasm
global cmd_expire, cmd_pexpire, cmd_expireat, cmd_pexpireat, cmd_ttl, cmd_pttl, cmd_persist
extern argc, argv_ptrs, argv_lens
extern parse_int, reply_int, ks_lookup, ks_del
extern emit_wrongargs, emit_notint, emit_invalid_expire
```
Add to `.rodata`:
```nasm
lc_expire:    db "expire"
lc_pexpire:   db "pexpire"
lc_expireat:  db "expireat"
lc_pexpireat: db "pexpireat"
lc_ttl:       db "ttl"
lc_pttl:      db "pttl"
lc_persist:   db "persist"
```
Add to `.text`:
```nasm
; ---- setter wrappers: rdi=mult(1000|1), rsi=basetime, rdx=name, rcx=namelen ----
cmd_expire:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1000
    mov     rsi, [rel g_now_ms]
    lea     rdx, [rel lc_expire]
    mov     rcx, 6
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_expire]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pexpire:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1
    mov     rsi, [rel g_now_ms]
    lea     rdx, [rel lc_pexpire]
    mov     rcx, 7
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_pexpire]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_expireat:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1000
    xor     rsi, rsi                    ; basetime = 0 (absolute)
    lea     rdx, [rel lc_expireat]
    mov     rcx, 8
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_expireat]
    mov     rsi, 8
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pexpireat:
    cmp     qword [rel argc], 3
    jne     .wa
    mov     rdi, 1
    xor     rsi, rsi
    lea     rdx, [rel lc_pexpireat]
    mov     rcx, 9
    jmp     _set_expire
.wa:
    lea     rdi, [rel lc_pexpireat]
    mov     rsi, 9
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _set_expire(rdi=mult, rsi=basetime, rdx=nameptr, rcx=namelen): shared setter.
;   argv[1]=key, argv[2]=when.  r12=mult r13=basetime r14=name r15=namelen rbx=when
_set_expire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes: entry ==8 -> ==0 at calls
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    mov     rdi, [rel argv_ptrs + 16]   ; when arg
    mov     rsi, [rel argv_lens + 16]
    call    parse_int                   ; rax=when, rdx=valid
    test    rdx, rdx
    jz      .notint
    mov     rbx, rax                    ; when
    cmp     r12, 1000                   ; seconds unit?
    jne     .addbase
    mov     rax, 9223372036854775       ; LLONG_MAX/1000
    cmp     rbx, rax
    jg      .invalid
    mov     rax, -9223372036854775      ; LLONG_MIN/1000
    cmp     rbx, rax
    jl      .invalid
    imul    rbx, rbx, 1000
.addbase:
    mov     rax, 0x7fffffffffffffff
    sub     rax, r13                    ; LLONG_MAX - basetime
    cmp     rbx, rax
    jg      .invalid
    add     rbx, r13                    ; absolute deadline (ms)
    mov     rdi, [rel argv_ptrs + 8]    ; key
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup                   ; passively expires; rax=entry|0
    test    rax, rax
    jz      .zero
    mov     rcx, [rel g_now_ms]
    cmp     rbx, rcx
    jg      .setttl                     ; deadline > now -> set it
    mov     rdi, [rel argv_ptrs + 8]    ; past -> delete the key
    mov     rsi, [rel argv_lens + 8]
    call    ks_del
    mov     rdi, 1
    call    reply_int
    jmp     .done
.setttl:
    mov     [rax+48], rbx               ; entry->expire_ms = deadline
    mov     rdi, 1
    call    reply_int
    jmp     .done
.zero:
    xor     edi, edi
    call    reply_int
    jmp     .done
.notint:
    call    emit_notint
    jmp     .done
.invalid:
    mov     rdi, r14
    mov     rsi, r15
    call    emit_invalid_expire
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---- TTL / PTTL ----
cmd_ttl:
    cmp     qword [rel argc], 2
    jne     .wa
    xor     edi, edi                    ; seconds
    jmp     _ttl_generic
.wa:
    lea     rdi, [rel lc_ttl]
    mov     rsi, 3
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

cmd_pttl:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     edi, 1                      ; ms
    jmp     _ttl_generic
.wa:
    lea     rdi, [rel lc_pttl]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; _ttl_generic(rdi=ms_flag): argv[1]=key. rbx=ms_flag
_ttl_generic:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .miss
    mov     rcx, [rax+48]
    test    rcx, rcx
    jz      .nottl
    sub     rcx, [rel g_now_ms]         ; remaining ms (>= 1)
    test    rbx, rbx
    jnz     .emit                       ; PTTL -> remaining
    add     rcx, 500
    mov     rax, rcx
    xor     rdx, rdx
    mov     rcx, 1000
    div     rcx                         ; (rem+500)/1000
    mov     rcx, rax
.emit:
    mov     rdi, rcx
    call    reply_int
    jmp     .done
.miss:
    mov     rdi, -2
    call    reply_int
    jmp     .done
.nottl:
    mov     rdi, -1
    call    reply_int
.done:
    pop     rbx
    ret

; ---- PERSIST ----
cmd_persist:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .zero
    cmp     qword [rax+48], 0
    je      .zero
    mov     qword [rax+48], 0           ; clear TTL
    mov     rdi, 1
    call    reply_int
    add     rsp, 8
    ret
.zero:
    xor     edi, edi
    call    reply_int
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_persist]
    mov     rsi, 7
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret
```

- [ ] **Step 5: `src/dispatch.asm`** — route the seven commands.

Add to the extern block: `extern cmd_expire, cmd_pexpire, cmd_expireat, cmd_pexpireat, cmd_ttl, cmd_pttl, cmd_persist`.
Add name strings to `.rodata`:
```nasm
name_ttl:       db "TTL"
name_pttl:      db "PTTL"
name_expire:    db "EXPIRE"
name_pexpire:   db "PEXPIRE"
name_persist:   db "PERSIST"
name_expireat:  db "EXPIREAT"
name_pexpireat: db "PEXPIREAT"
```
Add length dispatch for 8 and 9. Find the length switch (`cmp rax,4 / je .len4`, etc.) and add, before its `jmp emit_unknown`:
```nasm
    cmp     rax, 8
    je      .len8
    cmp     rax, 9
    je      .len9
```
In `.len3` (before its `jmp emit_unknown`), add TTL:
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_ttl]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_ttl
```
In `.len4`, add PTTL:
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pttl]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_pttl
```
In `.len6`, add EXPIRE:
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_expire]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_expire
```
In `.len7`, add PEXPIRE and PERSIST:
```nasm
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pexpire]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_pexpire
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_persist]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_persist
```
Add two new length blocks next to the others (each ending in `jmp emit_unknown`):
```nasm
.len8:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_expireat]
    mov     rdx, 8
    call    memcmp_n
    test    rax, rax
    je      cmd_expireat
    jmp     emit_unknown
.len9:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pexpireat]
    mov     rdx, 9
    call    memcmp_n
    test    rax, rax
    je      cmd_pexpireat
    jmp     emit_unknown
```
(Note: the top-of-dispatch guard rejects argv0 longer than 16 bytes; `PEXPIREAT`=9 is fine.)

- [ ] **Step 6: Build + run the test GREEN.**
```bash
make -s clean && make -s all && ./asmredis 7796 & SRV=$!
sleep 0.4
python3 tests/expire.py 7796; echo "rc=$?"
kill -9 $SRV 2>/dev/null
```
Expected: `OK expire: TTL family conformant`, rc=0. If a case fails, the label pinpoints it; the expected values are valkey-verified — debug the assembly, don't change the test.

- [ ] **Step 7: Full regression.** Run `timeout 500 bash tests/wire.sh` → all PASS, exit 0.

- [ ] **Step 8: Commit.**
```bash
git add src/errmsg.asm src/expire.asm src/dispatch.asm tests/expire.py
git commit -m "expire: EXPIRE/PEXPIRE/EXPIREAT/PEXPIREAT/TTL/PTTL/PERSIST commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Active expiration (bounded sweep + epoll tick)

**Files:** `src/keyspace.asm`, `src/net.asm`.

- [ ] **Step 1: `src/keyspace.asm`** — add the active reaper.

Add `ks_active_expire` to a `global` line. It needs the same table statics `_del_in_table` uses (`ht_table`, `ht_mask`, `ht_used`, `rehashidx`) — all local to `keyspace.asm`. Add a cursor to `.bss`:
```nasm
g_expire_cursor: resq 1
```
Add to `.text`:
```nasm
; ks_active_expire(): best-effort reaper. Skips while rehashing (transient). Scans
; EXPIRE_BUCKETS buckets of ht[0] from a persistent cursor, unlinking+freeing entries
; whose expire_ms has passed. Preserves callee-saved. Uses g_now_ms.
;   rbx=slot ptr, r12=entry, r13=buckets-left, r14=mask, r15=table base
ks_active_expire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15                         ; 5 pushes -> rsp%16==0 at calls
    mov     rax, [rel rehashidx]
    test    rax, rax
    jns     .ret                        ; rehashing (>=0) -> skip this cycle
    lea     rcx, [rel ht_table]
    mov     r15, [rcx]                  ; ht_table[0]
    test    r15, r15
    jz      .ret                        ; no table
    lea     rcx, [rel ht_mask]
    mov     r14, [rcx]                  ; ht_mask[0]
    mov     r13, EXPIRE_BUCKETS
.bucket:
    test    r13, r13
    jz      .ret
    mov     rax, [rel g_expire_cursor]
    mov     rcx, rax
    and     rcx, r14                    ; b = cursor & mask
    inc     rax
    mov     [rel g_expire_cursor], rax
    lea     rbx, [r15 + rcx*8]          ; slot = &ht_table[0][b]
.chain:
    mov     r12, [rbx]                  ; entry = *slot
    test    r12, r12
    jz      .nextb
    mov     rax, [r12+48]               ; expire_ms
    test    rax, rax
    jz      .keep
    cmp     rax, [rel g_now_ms]
    ja      .keep                       ; deadline > now
    ; expired: unlink and free the three blocks
    mov     rax, [r12]                  ; entry->next
    mov     [rbx], rax                  ; *slot = next
    mov     rdi, r12
    call    _free_value
    mov     rdi, [r12+8]                ; key_ptr
    mov     rsi, [r12+16]               ; key_len
    call    mem_free
    mov     rdi, r12
    mov     rsi, ENTRY_SZ
    call    mem_free
    lea     rcx, [rel ht_used]
    dec     qword [rcx]                 ; ht_used[0]--
    jmp     .chain                      ; re-read *slot (now = old next)
.keep:
    mov     rbx, r12                    ; slot = &entry->next (next at offset 0)
    jmp     .chain
.nextb:
    dec     r13
    jmp     .bucket
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
```
(Correctness notes for the reviewer: on reap, `*slot` is rewritten to `next` and we re-loop **without** advancing `slot`, so the new head is examined — no skipped entries, no use-after-free (we read `entry->next` before freeing). `slot` starts at the bucket head and becomes `&entry->next` (offset 0 of the entry) on keep, matching `_del_in_table`'s idiom.)

- [ ] **Step 2: `src/net.asm`** — finite epoll tick + call the reaper.

Add `extern ks_active_expire`. Change the `.wait` block: set the timeout to the tick and call the reaper each wakeup. Replace `mov r10, -1` with:
```nasm
    mov     r10, EXPIRE_TICK_MS
```
and change the post-syscall tail (from Task 1) to:
```nasm
    syscall
    mov     r15, rax                     ; n (0 on tick timeout, <0 on EINTR)
    call    time_refresh
    call    ks_active_expire
    test    r15, r15
    jle     .wait
    xor     r14, r14                     ; i = 0
```

- [ ] **Step 3: Build + regression + active-reaper health proxy.**

Run: `make -s clean && make -s all && timeout 500 bash tests/wire.sh` → all PASS, exit 0 (`expire`, `no-fd-leak`, everything). The active reaper now runs ~10×/s; the suite passing (including `no-fd-leak` base==after and the concurrency/stress tests) confirms the sweep unlinks/frees without corrupting the table under live traffic. (Direct observation of active vs passive reclaim isn't possible via RESP — see the spec's testing note.)

- [ ] **Step 4: Commit.**
```bash
git add src/keyspace.asm src/net.asm
git commit -m "expire: best-effort active reaper on a 100ms epoll tick

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire into the suite (expire.py run + oracle diffs)

**Files:** `tests/wire.sh`.

- [ ] **Step 1: Oracle `check` lines** — add to the conformance block, immediately before its `kill $SRV 2>/dev/null`. Only deterministic cases (no live-key TTL/PTTL values, which differ by a few ms between servers):
```bash
check SET ek v
check EXPIRE ek 100
check TTL ek
check EXPIRE nokey 100
check TTL nokey
check PTTL nokey
check SET nt2 v
check TTL nt2
check PERSIST ek
check PERSIST ek
check PERSIST nokey
check SET dk v
check EXPIREAT dk 1
check EXISTS dk
check TYPE dk
check GET dk
check TTL dk
check SET dk2 v
check PEXPIREAT dk2 1
check EXISTS dk2
check EXPIRE ek abc
check EXPIRE nokey abc
check EXPIRE ek 9999999999999999
check EXPIRE ek -9999999999999999
check EXPIREAT ek 9999999999999999
check EXPIRE
check TTL
check PERSIST
check PEXPIREAT ek
```
(`check TTL ek` after `EXPIRE ek 100` is stable at `100` because <500 ms elapse; `check TTL nt2` = `-1`; the deletes are byte-identical on both servers.)

- [ ] **Step 2: Standalone `expire.py` run** — append at the end of `tests/wire.sh` (after the counter block):
```bash

# --- Milestone I: TTL family conformance + real-time expiry ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/expire.py 7777 >/tmp/asmi_expire.txt 2>&1; then
  echo "PASS expire"; ex=0
else
  echo "FAIL expire: $(cat /tmp/asmi_expire.txt)"; ex=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ex -eq 0 ] || exit 1
```

- [ ] **Step 3: Run full suite.** `timeout 500 bash tests/wire.sh` → all PASS incl. `PASS conformance` (with the expiry oracle diffs) and `PASS expire`, exit 0. Any `DIFF [...]` line is a real divergence — report it, don't delete the check.

- [ ] **Step 4: Commit.**
```bash
git add tests/wire.sh
git commit -m "test: wire milestone-I TTL conformance + valkey oracle diffs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Benchmark + docs

**Files:** `docs/benchmark.md`.

The GET/SET hot path gains only: passive-expiry adds two instructions to `ks_lookup` (load `[48]`, compare vs cached `g_now_ms` — no syscall); the epoll loop gains one cached-clock refresh + a bounded reaper per 100 ms tick. A small-but-nonzero effect is possible on GET (the extra `ks_lookup` compare), so measure.

- [ ] **Step 1: Clean build + green suite.** `make -s clean && make -s all && timeout 500 bash tests/wire.sh` → all PASS.

- [ ] **Step 2: SET/GET spot benchmark.** Put the run in a **script file** and invoke `bash bench.sh` (ad-hoc compound Bash commands that start two servers + a benchmark get killed in this sandbox; a script file runs to completion). Parse the non-quiet `throughput summary:` line (not `-q`, whose `\r` progress corrupts parsing). Grid: `-c {1,50,200,500}` × `-d {3,512}`, asmredis:7777 vs valkey:7778, `-n 50000`.

- [ ] **Step 3: Append "Milestone I (key expiration)" to `docs/benchmark.md`.** Short intro: passive-expiry adds one compare to `ks_lookup`; expect GET within noise of milestone H. Include the throughput table (single-run spot-check, same constrained-sandbox caveat as milestone H), the asmredis-vs-oracle reading, `uname -r`, binary size.

- [ ] **Step 4: Commit.**
```bash
git add docs/benchmark.md
git commit -m "docs: milestone-I expiry benchmark (passive-expiry compare on GET)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** clock+`g_now_ms` → T1; `[48]` field + `ENTRY_SZ` → T1; passive-in-`ks_lookup` → T1; SET-clears/INCR-preserves via keep-TTL flag (refines the spec's return-entry sketch; same requirement) → T1 (ks_set/cmd_set/_incr_by); RPUSH/HSET preserve for free (they never touch `[48]`); the 7 commands + exact semantics/errors → T2; active reaper in keyspace.asm (refines spec's "net.asm owns it"; net just calls it) + epoll tick → T3; oracle diff + real-time test → T2/T4; benchmark → T5. All mapped.
- **Placeholder scan:** all code verbatim NASM/Python/bash; no TODO/TBD.
- **Consistency:** `[48]` offset, `ENTRY_SZ=56`, `g_now_ms` (single time source, refreshed once per wakeup before processing), `emit_invalid_expire(rdi=name,rsi=len)`, and the setter core's `(mult,basetime,name)` contract are used identically across wrappers. `ks_set`'s new `r8=keepttl` has exactly two callers (`cmd_set`=0, `_incr_by`=1). `ks_lookup`→`ks_del` is non-recursive (`ks_del` uses `_del_in_table`, not `ks_lookup`). Overflow constants: `LLONG_MAX/1000=9223372036854775`, `LLONG_MIN/1000=-9223372036854775`. TTL uses `(rem+500)/1000` and may return 0. Stack: `_set_expire` 5 pushes (==0), `_ttl_generic`/`cmd_persist`/wrappers annotated; `ks_active_expire` 5 pushes (==0); `ks_set` `sub rsp,16`/`add rsp,16` keeps its 5-push frame 16-aligned.
- **Staging:** T1 is a green no-op-behavior checkpoint (no TTL command exists yet); T2 adds commands; T3 adds active reaping — suite green after each.
- **Known divergence documented:** `argc≠3` EXPIRE → wrongargs (vs valkey's Redis-7 "Unsupported option"); 4+-arg cases excluded from the oracle diff.
