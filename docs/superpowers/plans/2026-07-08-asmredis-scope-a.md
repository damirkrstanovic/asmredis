# asmredis Scope-A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure-syscall x86-64 (NASM) Redis/Valkey-compatible server that handles `PING`, `ECHO`, `SET`, `GET`, `DEL` over RESP2, byte-identical to Valkey 9.1.0, serving one client at a time.

**Architecture:** Static ELF64, no libc, `_start` entry. `net` owns sockets and per-client read/write; `parser` turns RESP array bytes into an `argv[]` of (ptr,len) pairs pointing into the read buffer; `dispatch` matches `argv[0]` against a command table; handlers use `keyspace` (1024-bucket chained hashtable over an `mmap`'d bump arena) and `reply` (RESP writers). Keyspace/dispatch never touch sockets, so the I/O model is swappable later.

**Tech Stack:** NASM (`-f elf64`), GNU `ld` (static, no libc), raw Linux syscalls, `gdb`/`objdump` for debugging. Tests drive the binary with `nc`, `xxd`, and `valkey-cli`, diffing against a `valkey-server` oracle on port 7777.

**Verified ABI facts (this machine, x86-64 Linux, glibc 2.43):**
- Syscalls: `read=0 write=1 close=3 mmap=9 socket=41 accept=43 bind=49 listen=50 setsockopt=54 exit=60`
- Constants: `AF_INET=2 SOCK_STREAM=1 SOL_SOCKET=1 SO_REUSEADDR=2 INADDR_ANY=0`
- `mmap`: `PROT_READ|PROT_WRITE=3`, `MAP_PRIVATE|MAP_ANONYMOUS=0x22`, fd=`-1`, off=`0`
- Syscall ABI: number in `rax`; args in `rdi, rsi, rdx, r10, r8, r9`; return in `rax` (negative = `-errno`); clobbers `rcx, r11`.
- `htons(7777) = 0x611e` (store as 16-bit word `0x611e`).

**TDD note for assembly:** leaf routines (`itoa`, `memcmp`, hash) have no standalone harness without libc, so they are tested *through wire behavior* — e.g. `DEL`'s `:1\r\n` reply exercises `itoa`, `GET` exercises `memcmp`+hash. Each task's test is a red→green wire check via `nc`/`valkey-cli`. This is integration-level TDD, deliberate given the no-libc constraint.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Makefile` | build (`nasm`+`ld`), `run`, `test`, `clean` |
| `include/syscalls.inc` | syscall numbers, socket constants, tunables (`PORT_DEFAULT`, `ARENA_SIZE`, buffer sizes), error-string macros |
| `src/main.asm` | `_start`: parse argv[1] port → arena `mmap` → call `net_serve` → `exit` |
| `src/net.asm` | `net_serve`: socket/setsockopt/bind/listen/accept; per-client read→parse→dispatch→write loop; buffer + leftover compaction |
| `src/parser.asm` | `parse_one`: consume one RESP array → argc + argv[]; returns OK / NEED_MORE / PROTOERR |
| `src/dispatch.asm` | `dispatch`: uppercase argv[0], scan command table, call handler; argc validation |
| `src/keyspace.asm` | `ks_get`/`ks_set`/`ks_del` over 1024-bucket chained hashtable |
| `src/alloc.asm` | `arena_init`, `arena_alloc` (bump) |
| `src/reply.asm` | `reply_simple`, `reply_bulk`, `reply_null`, `reply_int`, `reply_err` |
| `src/util.asm` | `atoi_port`, `itoa_u`, `memcmp_n`, `to_upper_buf`, `fnv1a` |
| `tests/wire.sh` | golden wire tests + valkey conformance diff |

All handlers append reply bytes to a shared out-buffer (`out_buf`) and advance a cursor `out_len`; `net` writes `out_buf[0..out_len]` after the read buffer drains.

**Shared register/label contracts (used across tasks):**
- Global BSS symbols (declared in `main.asm`, `extern`'d elsewhere): `listen_fd` (implicit local to net), `arena_next`, `arena_end` (alloc), `buckets` (keyspace), `read_buf`, `out_buf`, `out_len`, `argv_ptrs`, `argv_lens`, `argc`.
- `parse_one` inputs: `rdi`=buf start, `rsi`=bytes available; outputs: `rax`=status (0=OK,1=NEED_MORE,2=PROTOERR), `rdx`=bytes consumed (on OK), and fills `argc`/`argv_ptrs[]`/`argv_lens[]`.
- `reply_*` inputs: pointer/len of payload in `rdi`/`rsi` (as noted per routine); each appends to `out_buf` at `out_len` and updates `out_len`.

---

## Task 1: Build system + walking skeleton

**Files:**
- Create: `include/syscalls.inc`
- Create: `src/main.asm`
- Create: `Makefile`

- [ ] **Step 1: Write the failing test**

Create `tests/wire.sh` with just the toolchain check for now:

```bash
#!/usr/bin/env bash
set -u
make -s clean all || { echo "BUILD FAILED"; exit 1; }
out=$(./asmredis --banner 2>/dev/null)
if [ "$out" = "asmredis" ]; then echo "PASS banner"; else echo "FAIL banner: got '$out'"; exit 1; fi
```

Make it executable: `chmod +x tests/wire.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `BUILD FAILED` (no Makefile/sources yet).

- [ ] **Step 3: Write minimal implementation**

`include/syscalls.inc`:
```nasm
; ---- Linux x86-64 syscall numbers ----
%define SYS_read        0
%define SYS_write       1
%define SYS_close       3
%define SYS_mmap        9
%define SYS_socket      41
%define SYS_accept      43
%define SYS_bind        49
%define SYS_listen      50
%define SYS_setsockopt  54
%define SYS_exit        60

; ---- socket constants ----
%define AF_INET         2
%define SOCK_STREAM     1
%define SOL_SOCKET      1
%define SO_REUSEADDR    2
%define INADDR_ANY      0

; ---- mmap constants ----
%define PROT_RW         3            ; PROT_READ|PROT_WRITE
%define MAP_ANON_PRIV   0x22         ; MAP_PRIVATE|MAP_ANONYMOUS

; ---- tunables ----
%define PORT_DEFAULT    6379
%define ARENA_SIZE      (64*1024*1024)
%define READ_BUF_SIZE   16384
%define OUT_BUF_SIZE    65536
%define MAX_ARGS        128
%define NBUCKETS        1024
%define BUCKET_MASK     1023
```

`src/main.asm`:
```nasm
%include "syscalls.inc"

global _start
extern net_serve            ; (rdi = port) -> does not return normally here (loops)
extern arena_init           ; sets up arena; no args

section .rodata
banner:      db "asmredis", 10
banner_len:  equ $ - banner
flag_banner: db "--banner"

section .text
_start:
    ; [rsp] = argc, [rsp+8] = argv[0], [rsp+16] = argv[1] ...
    mov     rax, [rsp]          ; argc
    ; --- handle "--banner" self-test: if argv[1] == "--banner" print banner+exit
    cmp     rax, 2
    jl      .no_banner
    mov     rsi, [rsp+16]       ; argv[1]
    ; compare first 8 bytes with "--banner"
    mov     rax, [rsi]
    mov     rbx, [rel flag_banner]
    cmp     rax, rbx
    jne     .no_banner
    ; print banner and exit 0
    mov     rax, SYS_write
    mov     rdi, 1
    lea     rsi, [rel banner]
    mov     rdx, banner_len
    syscall
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall

.no_banner:
    ; Task 2 will call net_serve here. For now just exit 0.
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
```

`Makefile`:
```make
AS      := nasm
ASFLAGS := -f elf64 -g -F dwarf -Iinclude
LD      := ld
LDFLAGS := -static -nostdlib
SRC     := $(wildcard src/*.asm)
OBJ     := $(SRC:src/%.asm=build/%.o)
BIN     := asmredis

all: $(BIN)

build/%.o: src/%.asm | build
	$(AS) $(ASFLAGS) $< -o $@

$(BIN): $(OBJ)
	$(LD) $(LDFLAGS) $(OBJ) -o $@

build:
	mkdir -p build

run: $(BIN)
	./$(BIN) 7777

test: $(BIN)
	bash tests/wire.sh

clean:
	rm -rf build $(BIN)

.PHONY: all run test clean
```

Note: `net_serve`/`arena_init` are `extern` but unused until Task 2. To link now, temporarily comment out the two `extern` lines in `main.asm` OR add empty stub files. Simplest: **remove the two `extern` lines for Task 1** and re-add them in Task 2. Update `main.asm` to drop the `extern` lines for this task.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/wire.sh`
Expected: `PASS banner`

- [ ] **Step 5: Commit**

```bash
git add Makefile include/syscalls.inc src/main.asm tests/wire.sh
git commit -m "build: toolchain + walking skeleton (--banner self-test)"
```

---

## Task 2: Listening socket + accept loop + hardcoded PONG

Brings up the full networking syscall chain, isolated from parsing. Server takes the port from `argv[1]`, accepts a connection, writes a hardcoded `+PONG\r\n`, closes it, loops.

**Files:**
- Create: `src/net.asm`
- Create: `src/util.asm` (just `atoi_port` for now)
- Modify: `src/main.asm` (call `net_serve` with parsed port)

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh` (before any existing exit):
```bash
# --- Task 2: server answers +PONG to any bytes ---
./asmredis 7777 & SRV=$!
sleep 0.3
resp=$(printf 'x' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
if [ "$resp" = "2b504f4e470d0a" ]; then echo "PASS pong-skeleton"; else echo "FAIL pong-skeleton: $resp"; exit 1; fi
```
(`2b504f4e470d0a` = `+PONG\r\n`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `FAIL pong-skeleton` (server exits immediately, `nc` gets nothing).

- [ ] **Step 3: Write minimal implementation**

`src/util.asm` (port parser — decimal argv string → integer in `rax`; 0 on empty):
```nasm
%include "syscalls.inc"
global atoi_port

section .text
; rdi = ptr to NUL-terminated decimal string -> rax = value
atoi_port:
    xor     rax, rax
.loop:
    movzx   rcx, byte [rdi]
    test    rcx, rcx
    je      .done
    cmp     rcx, '0'
    jb      .done
    cmp     rcx, '9'
    ja      .done
    imul    rax, rax, 10
    sub     rcx, '0'
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret
```

`src/net.asm`:
```nasm
%include "syscalls.inc"
global net_serve
extern arena_init            ; unused until Task 4; declare for later. (Comment out if unlinked.)

section .rodata
pong:      db "+PONG", 13, 10
pong_len:  equ $ - pong
err_bind:  db "bind failed", 10
err_bind_len: equ $ - err_bind

section .bss
sockaddr:  resb 16           ; struct sockaddr_in

section .text
; rdi = port number (host order)
net_serve:
    push    r12
    push    r13
    push    r14
    mov     r14w, di             ; save port (16-bit)

    ; --- socket(AF_INET, SOCK_STREAM, 0) ---
    mov     rax, SYS_socket
    mov     rdi, AF_INET
    mov     rsi, SOCK_STREAM
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .fail
    mov     r12, rax             ; r12 = listen fd

    ; --- setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &1, 4) ---
    mov     dword [rsp-8], 1     ; optval=1 in red zone
    mov     rax, SYS_setsockopt
    mov     rdi, r12
    mov     rsi, SOL_SOCKET
    mov     rdx, SO_REUSEADDR
    lea     r10, [rsp-8]
    mov     r8, 4
    syscall
    ; ignore setsockopt errors

    ; --- build sockaddr_in ---
    ; sin_family=AF_INET (2), sin_port=htons(port), sin_addr=0, pad=0
    lea     rdi, [rel sockaddr]
    xor     rax, rax
    mov     [rdi], rax           ; zero first 8 bytes
    mov     [rdi+8], rax         ; zero next 8 bytes
    mov     word [rdi], AF_INET
    mov     ax, r14w             ; port host order
    xchg    al, ah               ; htons
    mov     [rdi+2], ax

    ; --- bind(fd, &sockaddr, 16) ---
    mov     rax, SYS_bind
    mov     rdi, r12
    lea     rsi, [rel sockaddr]
    mov     rdx, 16
    syscall
    test    rax, rax
    js      .fail

    ; --- listen(fd, 128) ---
    mov     rax, SYS_listen
    mov     rdi, r12
    mov     rsi, 128
    syscall
    test    rax, rax
    js      .fail

.accept_loop:
    ; --- accept(fd, NULL, NULL) ---
    mov     rax, SYS_accept
    mov     rdi, r12
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .accept_loop         ; on error just retry
    mov     r13, rax             ; r13 = conn fd

    ; --- write(conn, pong, pong_len) ---
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel pong]
    mov     rdx, pong_len
    syscall

    ; --- close(conn) ---
    mov     rax, SYS_close
    mov     rdi, r13
    syscall
    jmp     .accept_loop

.fail:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_bind]
    mov     rdx, err_bind_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall
```
(If `arena_init` is not yet defined, comment out its `extern` line until Task 4.)

Modify `src/main.asm` `.no_banner:` block to parse the port and call `net_serve`:
```nasm
.no_banner:
    ; default port
    mov     rdi, PORT_DEFAULT
    mov     rax, [rsp]           ; argc
    cmp     rax, 2
    jl      .have_port
    mov     rdi, [rsp+16]        ; argv[1] ptr
    call    atoi_port            ; rax = port
    mov     rdi, rax
.have_port:
    call    net_serve            ; never returns
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
```
Add at top of `main.asm`: `extern net_serve` and `extern atoi_port`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/wire.sh`
Expected: `PASS banner` then `PASS pong-skeleton`.

- [ ] **Step 5: Commit**

```bash
git add src/net.asm src/util.asm src/main.asm tests/wire.sh
git commit -m "net: listening socket + accept loop + hardcoded PONG"
```

---

## Task 3: RESP parser + dispatch + real PING / ECHO / unknown-command

Add a per-client read loop, a RESP array parser filling `argv`, a command table, `reply` writers, and handlers for `PING` and `ECHO`. Unknown commands return the exact Valkey error. No keyspace yet.

**Files:**
- Create: `src/parser.asm`
- Create: `src/dispatch.asm`
- Create: `src/reply.asm`
- Modify: `src/util.asm` (add `memcmp_n`, `to_upper_buf`)
- Modify: `src/net.asm` (replace hardcoded write with read→parse→dispatch→write)
- Modify: `src/main.asm` (declare new BSS externs — actually defined here)

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh`:
```bash
# --- Task 3: PING/ECHO/unknown via valkey-cli-style RESP ---
./asmredis 7777 & SRV=$!; sleep 0.3
ping=$(printf '*1\r\n$4\r\nPING\r\n'         | nc -q1 127.0.0.1 7777 | xxd -p)
echo1=$(printf '*2\r\n$4\r\nECHO\r\n$5\r\nhello\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
unk=$(printf '*3\r\n$3\r\nFOO\r\n$1\r\na\r\n$1\r\nb\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r' | head -c 40)
kill $SRV 2>/dev/null
[ "$ping" = "2b504f4e470d0a" ]              && echo "PASS ping" || { echo "FAIL ping: $ping"; exit 1; }
[ "$echo1" = "24350d0a68656c6c6f0d0a" ]      && echo "PASS echo" || { echo "FAIL echo: $echo1"; exit 1; }
case "$unk" in "-ERR unknown command 'FOO'"*) echo "PASS unknown";; *) echo "FAIL unknown: $unk"; exit 1;; esac
```
(`24350d0a68656c6c6f0d0a` = `$5\r\nhello\r\n`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `FAIL ping` (skeleton returns PONG regardless, but ECHO and unknown will differ; ping may accidentally pass — the ECHO/unknown lines are the real red).

- [ ] **Step 3: Write minimal implementation**

Add BSS + externs. In `src/main.asm`, add a `section .bss` with the shared buffers (defined once, globally):
```nasm
section .bss
global read_buf, out_buf, out_len, argc, argv_ptrs, argv_lens
read_buf:   resb READ_BUF_SIZE
out_buf:    resb OUT_BUF_SIZE
out_len:    resq 1
argc:       resq 1
argv_ptrs:  resq MAX_ARGS
argv_lens:  resq MAX_ARGS
```

`src/reply.asm` (all append to `out_buf` at `out_len`):
```nasm
%include "syscalls.inc"
global reply_simple, reply_bulk, reply_null, reply_int, reply_err
extern out_buf, out_len
extern itoa_u

section .rodata
crlf:     db 13,10
null_bulk: db "$-1", 13, 10
null_bulk_len: equ $ - null_bulk

section .text
; helper: append rsi bytes from rdi to out_buf ; clobbers rax,rcx,rsi,rdi,r11
%macro APPEND 0
    ; rdi=src, rsi=len
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    add     r11, rax
    mov     rcx, rsi
    rep     movsb                 ; copies rcx bytes [rsi]->[rdi]; but we need dest=r11
%endmacro
; NOTE: rep movsb copies from RSI to RDI. We standardize: put SRC in rsi, DEST in rdi.

; reply_simple: rdi=ptr, rsi=len -> "+<payload>\r\n"
reply_simple:
    push    rdi
    push    rsi
    mov     r8b, '+'
    call    _put_byte
    pop     rsi
    pop     rdi
    call    _put_bytes
    call    _put_crlf
    ret

; reply_bulk: rdi=ptr, rsi=len -> "$<len>\r\n<payload>\r\n"
reply_bulk:
    push    rdi
    push    rsi
    mov     r8b, '$'
    call    _put_byte
    pop     rsi
    pop     rdi
    push    rdi
    push    rsi
    mov     rdi, rsi              ; number to print = len
    call    _put_uint            ; appends decimal len
    call    _put_crlf
    pop     rsi
    pop     rdi
    call    _put_bytes
    call    _put_crlf
    ret

; reply_null -> "$-1\r\n"
reply_null:
    lea     rsi, [rel null_bulk]
    mov     rdi, rsi
    mov     rsi, null_bulk_len
    call    _put_bytes
    ret

; reply_int: rdi = signed/unsigned value -> ":<n>\r\n"  (values here are >=0)
reply_int:
    push    rdi
    mov     r8b, ':'
    call    _put_byte
    pop     rdi
    call    _put_uint
    call    _put_crlf
    ret

; reply_err: rdi=ptr, rsi=len (payload already includes "-ERR ..." text, no crlf)
reply_err:
    call    _put_bytes
    call    _put_crlf
    ret

; ---- low-level appenders (dest = out_buf+out_len) ----
; _put_byte: r8b = byte
_put_byte:
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    mov     [r11+rax], r8b
    inc     rax
    mov     [rel out_len], rax
    ret

; _put_bytes: rdi=src ptr, rsi=len
_put_bytes:
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    lea     r11, [r11+rax]        ; dest
    mov     rcx, rsi
    push    rdi
    push    rsi
    mov     rsi, rdi              ; src
    mov     rdi, r11              ; dest
    rep     movsb
    pop     rsi
    pop     rdi
    add     [rel out_len], rsi
    ret

; _put_crlf
_put_crlf:
    lea     r11, [rel out_buf]
    mov     rax, [rel out_len]
    mov     word [r11+rax], 0x0a0d ; little-endian -> bytes 0d 0a
    add     rax, 2
    mov     [rel out_len], rax
    ret

; _put_uint: rdi=unsigned value -> appends decimal ASCII via itoa_u
_put_uint:
    sub     rsp, 32
    mov     rsi, rsp              ; scratch buffer
    call    itoa_u                ; rdi=value, rsi=buf -> rax=len, buf filled
    mov     rdi, rsi              ; src = scratch
    mov     rsi, rax              ; len
    call    _put_bytes
    add     rsp, 32
    ret
```

Add `itoa_u` and `memcmp_n`, `to_upper_buf` to `src/util.asm`:
```nasm
global itoa_u, memcmp_n, to_upper_buf

; itoa_u: rdi=unsigned value, rsi=out buffer (>=20 bytes) -> rax=length, buffer filled (no NUL)
itoa_u:
    mov     rax, rdi
    mov     rcx, 10
    lea     r8, [rsi+20]          ; write backwards from end
    mov     r9, r8
.div:
    xor     rdx, rdx
    div     rcx                   ; rax/10, rdx=remainder
    add     dl, '0'
    dec     r8
    mov     [r8], dl
    test    rax, rax
    jnz     .div
    ; digits are at [r8 .. r9), move to front (rsi)
    mov     rcx, r9
    sub     rcx, r8               ; length
    mov     rax, rcx              ; return length
    push    rsi
    mov     rdi, rsi              ; dest
    mov     rsi, r8               ; src
    rep     movsb
    pop     rsi
    ret

; memcmp_n: rdi=a, rsi=b, rdx=n -> rax=0 if equal, else 1
memcmp_n:
    xor     rax, rax
    test    rdx, rdx
    je      .eq
.loop:
    mov     cl, [rdi]
    cmp     cl, [rsi]
    jne     .ne
    inc     rdi
    inc     rsi
    dec     rdx
    jnz     .loop
.eq:
    xor     rax, rax
    ret
.ne:
    mov     rax, 1
    ret

; to_upper_buf: rdi=ptr, rsi=len -> uppercases a-z in place
to_upper_buf:
    test    rsi, rsi
    je      .done
.loop:
    mov     al, [rdi]
    cmp     al, 'a'
    jb      .skip
    cmp     al, 'z'
    ja      .skip
    sub     al, 32
    mov     [rdi], al
.skip:
    inc     rdi
    dec     rsi
    jnz     .loop
.done:
    ret
```

`src/parser.asm`:
```nasm
%include "syscalls.inc"
global parse_one
extern argc, argv_ptrs, argv_lens

; parse_one: rdi=buf start, rsi=bytes available
;   returns rax: 0=OK, 1=NEED_MORE, 2=PROTOERR ; rdx=bytes consumed (OK only)
; Fills argc, argv_ptrs[i], argv_lens[i].
; Registers: r8=cursor ptr, r9=end ptr, r10=arg index
section .text
parse_one:
    mov     r8, rdi               ; cursor
    lea     r9, [rdi+rsi]         ; end
    ; need at least 1 byte
    cmp     r8, r9
    jae     .need
    cmp     byte [r8], '*'
    jne     .proto
    inc     r8
    call    _read_uint            ; -> rax=value, r8 advanced past \r\n ; CF-style via rdx status
    cmp     rdx, 1
    je      .need
    cmp     rdx, 2
    je      .proto
    mov     r11, rax              ; N = number of args
    cmp     r11, MAX_ARGS
    ja      .proto
    mov     [rel argc], r11
    xor     r10, r10              ; i = 0
.arg:
    cmp     r10, r11
    jae     .ok
    ; expect '$'
    cmp     r8, r9
    jae     .need
    cmp     byte [r8], '$'
    jne     .proto
    inc     r8
    call    _read_uint            ; rax=len of this bulk
    cmp     rdx, 1
    je      .need
    cmp     rdx, 2
    je      .proto
    ; need rax bytes + trailing \r\n available
    mov     rcx, r9
    sub     rcx, r8               ; bytes remaining
    mov     rbx, rax
    add     rbx, 2                ; payload + CRLF
    cmp     rcx, rbx
    jb      .need
    ; record argv
    mov     [rel argv_ptrs + r10*8], r8
    mov     [rel argv_lens + r10*8], rax
    add     r8, rax               ; skip payload
    ; expect \r\n
    cmp     byte [r8], 13
    jne     .proto
    cmp     byte [r8+1], 10
    jne     .proto
    add     r8, 2
    inc     r10
    jmp     .arg
.ok:
    mov     rdx, r8
    sub     rdx, rdi              ; consumed
    xor     rax, rax
    ret
.need:
    mov     rax, 1
    ret
.proto:
    mov     rax, 2
    ret

; _read_uint: parse ASCII decimal at [r8] terminated by \r\n; advance r8 past \r\n.
;   -> rax=value ; rdx=0 OK, rdx=1 NEED_MORE (no CRLF yet), rdx=2 PROTOERR
_read_uint:
    xor     rax, rax
.d:
    cmp     r8, r9
    jae     .nm
    movzx   rcx, byte [r8]
    cmp     rcx, 13               ; '\r'
    je      .cr
    cmp     rcx, '0'
    jb      .pe
    cmp     rcx, '9'
    ja      .pe
    imul    rax, rax, 10
    sub     rcx, '0'
    add     rax, rcx
    inc     r8
    jmp     .d
.cr:
    lea     rcx, [r8+1]
    cmp     rcx, r9
    jae     .nm
    cmp     byte [r8+1], 10       ; '\n'
    jne     .pe
    add     r8, 2
    xor     rdx, rdx
    ret
.nm:
    mov     rdx, 1
    ret
.pe:
    mov     rdx, 2
    ret
```
(Note: uses `rbx`/`r11` — callers must treat them as clobbered. `net` saves what it needs.)

`src/dispatch.asm`:
```nasm
%include "syscalls.inc"
global dispatch
extern argc, argv_ptrs, argv_lens
extern to_upper_buf, memcmp_n
extern reply_simple, reply_bulk, reply_null, reply_int, reply_err
extern cmd_ping, cmd_echo         ; handlers below in this file? define here.

section .rodata
s_pong:    db "PONG"
s_pong_len: equ $ - s_pong
name_ping: db "PING"
name_echo: db "ECHO"
name_set:  db "SET"
name_get:  db "GET"
name_del:  db "DEL"
err_unknown_pre: db "-ERR unknown command '"
err_unknown_pre_len: equ $ - err_unknown_pre
err_unknown_mid: db "', with args beginning with: "
err_unknown_mid_len: equ $ - err_unknown_mid

section .text
; dispatch: assumes argc/argv already parsed. Writes reply to out_buf.
; Uppercases argv[0] in place (buffer is transient), matches, calls handler.
dispatch:
    mov     rax, [rel argc]
    test    rax, rax
    je      .done                 ; empty array: ignore
    ; uppercase argv[0]
    mov     rdi, [rel argv_ptrs]
    mov     rsi, [rel argv_lens]
    push    rsi
    push    rdi
    call    to_upper_buf
    pop     rdi
    pop     rsi
    ; match name: compare (rdi,rsi) with each table entry (name,len,handler)
    ; PING (len 4)
    cmp     rsi, 4
    jne     .not_ping
    lea     rbx, [rel name_ping]
    mov     rdx, 4
    push    rdi
    mov     rsi, rbx
    ; memcmp_n(rdi=argv0, rsi=name, rdx=4)
    mov     rdx, 4
    call    memcmp_n
    pop     rdi
    test    rax, rax
    jne     .try_echo
    jmp     cmd_ping
.not_ping:
.try_echo:
    mov     rsi, [rel argv_lens]  ; reload len
    cmp     rsi, 4
    jne     .try_set
    mov     rdi, [rel argv_ptrs]
    lea     rsi, [rel name_echo]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    jne     .try_set
    jmp     cmd_echo
.try_set:
    ; SET/GET/DEL added in Task 4 — jump table extended there.
    jmp     .unknown
.unknown:
    call    emit_unknown          ; builds -ERR unknown command '<orig>' ...
.done:
    ret

; ---- handlers ----
cmd_ping:
    ; PING with no arg -> +PONG ; PING <msg> -> bulk echo of msg
    mov     rax, [rel argc]
    cmp     rax, 2
    je      .with_arg
    lea     rdi, [rel s_pong]
    mov     rsi, s_pong_len
    call    reply_simple
    ret
.with_arg:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    reply_bulk
    ret

cmd_echo:
    mov     rax, [rel argc]
    cmp     rax, 2
    jne     .argerr
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    reply_bulk
    ret
.argerr:
    ; reuse wrong-args path (Task 5 provides emit_wrongargs); for now emit generic
    call    emit_unknown
    ret

; emit_unknown: writes -ERR unknown command '<argv0-original-bytes>', ...
; For Task 3 keep it simple: use argv0 (now uppercased) — Task 5 refines to original case + args.
emit_unknown:
    lea     rdi, [rel err_unknown_pre]
    mov     rsi, err_unknown_pre_len
    extern _put_raw
    ; Simplest: append prefix, then argv0, then "'\r\n". Use reply_err primitives.
    ; (Implemented via reply.asm helpers — see Step note.)
    ; Append prefix (no crlf):
    call    append_raw
    mov     rdi, [rel argv_ptrs]
    mov     rsi, [rel argv_lens]
    call    append_raw
    lea     rdi, [rel apostrophe_crlf]
    mov     rsi, 3
    call    append_raw
    ret

section .rodata
apostrophe_crlf: db "'", 13, 10
```

Because `dispatch.asm` needs a raw appender, add `append_raw` to `reply.asm` and export it:
```nasm
; in reply.asm, add:
global append_raw
; append_raw: rdi=src, rsi=len -> appends raw bytes, no crlf
append_raw:
    call    _put_bytes
    ret
```
And in `dispatch.asm` replace `extern _put_raw` line with `extern append_raw`.

Finally, rewire `src/net.asm` accept body to read→parse→dispatch→write. Replace the `.accept_loop` body's hardcoded write/close with:
```nasm
extern parse_one, dispatch
extern read_buf, out_buf, out_len

; inside .accept_loop after obtaining conn fd in r13:
.client_loop:
    ; read into read_buf (Task 3: assume one full command per read; Task 5 adds accumulation)
    mov     rax, SYS_read
    mov     rdi, r13
    lea     rsi, [rel read_buf]
    mov     rdx, READ_BUF_SIZE
    syscall
    test    rax, rax
    jle     .client_done          ; 0 = closed, <0 = error
    mov     r15, rax              ; bytes read
    ; reset out_len
    mov     qword [rel out_len], 0
    ; parse_one(read_buf, r15)
    lea     rdi, [rel read_buf]
    mov     rsi, r15
    call    parse_one
    test    rax, rax
    jnz     .client_done          ; NEED_MORE/PROTOERR: Task 5 handles; here just close
    call    dispatch
    ; write out_buf[0..out_len]
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    syscall
    jmp     .client_loop
.client_done:
    mov     rax, SYS_close
    mov     rdi, r13
    syscall
    jmp     .accept_loop
```
Add `push r15`/`pop r15` to `net_serve` prologue/epilogue register saves (add `push r15` after `push r14`, and matching pops). Remove the old hardcoded `pong` write/close in `.accept_loop`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/wire.sh`
Expected: `PASS ping`, `PASS echo`, `PASS unknown`.

Also spot-check with the real client:
```bash
./asmredis 7777 & SRV=$!; sleep 0.3
valkey-cli -p 7777 PING          # -> PONG
valkey-cli -p 7777 ECHO hi       # -> "hi"
kill $SRV
```

- [ ] **Step 5: Commit**

```bash
git add src/parser.asm src/dispatch.asm src/reply.asm src/util.asm src/net.asm src/main.asm tests/wire.sh
git commit -m "parser+dispatch: RESP arrays, PING/ECHO, unknown-command error"
```

---

## Task 4: Keyspace + arena allocator + SET / GET / DEL

**Files:**
- Create: `src/alloc.asm`
- Create: `src/keyspace.asm`
- Modify: `src/main.asm` (call `arena_init`; declare `buckets` BSS)
- Modify: `src/dispatch.asm` (add SET/GET/DEL to the table + handlers)

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh`:
```bash
# --- Task 4: SET/GET/DEL semantics ---
./asmredis 7777 & SRV=$!; sleep 0.3
set1=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
geth=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n*2\r\n$3\r\nGET\r\n$1\r\nk\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
getm=$(printf '*2\r\n$3\r\nGET\r\n$4\r\nnope\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
del=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n*2\r\n$3\r\nDEL\r\n$1\r\nk\r\n*2\r\n$3\r\nDEL\r\n$1\r\nk\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
[ "$set1" = "2b4f4b0d0a" ]                         && echo "PASS set"      || { echo "FAIL set: $set1"; exit 1; }
[ "$geth" = "2b4f4b0d0a24330d0a6162630d0a" ]        && echo "PASS get-hit"  || { echo "FAIL get-hit: $geth"; exit 1; }
[ "$getm" = "242d310d0a" ]                          && echo "PASS get-miss" || { echo "FAIL get-miss: $getm"; exit 1; }
[ "$del" = "2b4f4b0d0a3a310d0a3a300d0a" ]           && echo "PASS del"      || { echo "FAIL del: $del"; exit 1; }
```
(`2b4f4b0d0a`=`+OK\r\n`; `24330d0a6162630d0a`=`$3\r\nabc\r\n`; `242d310d0a`=`$-1\r\n`; `3a310d0a`=`:1\r\n`, `3a300d0a`=`:0\r\n`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `FAIL set` (SET currently falls through to unknown-command).

- [ ] **Step 3: Write minimal implementation**

`src/alloc.asm`:
```nasm
%include "syscalls.inc"
global arena_init, arena_alloc

section .bss
arena_next: resq 1
arena_end:  resq 1

section .text
; arena_init: mmap ARENA_SIZE anonymous RW; store base/end. Exit(1) on failure.
arena_init:
    mov     rax, SYS_mmap
    xor     rdi, rdi              ; addr = NULL
    mov     rsi, ARENA_SIZE
    mov     rdx, PROT_RW
    mov     r10, MAP_ANON_PRIV
    mov     r8, -1               ; fd
    xor     r9, r9               ; offset
    syscall
    ; mmap returns -errno in [-4095,-1] on error
    cmp     rax, -4095
    jae     .fail
    mov     [rel arena_next], rax
    add     rax, ARENA_SIZE
    mov     [rel arena_end], rax
    ret
.fail:
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

; arena_alloc: rdi=size -> rax=ptr (8-byte aligned), or 0 if exhausted
arena_alloc:
    add     rdi, 7
    and     rdi, -8               ; round up to 8
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
```

`src/keyspace.asm` (entry layout: next=0, key_ptr=8, key_len=16, val_ptr=24, val_len=32; 40 bytes):
```nasm
%include "syscalls.inc"
global ks_get, ks_set, ks_del
extern arena_alloc, memcmp_n, fnv1a
extern buckets

section .text
; _bucket_index: rdi=key ptr, rsi=key len -> rax = &buckets[idx]
_bucket_index:
    push    rdi
    push    rsi
    call    fnv1a                 ; rdi,rsi -> rax=hash
    and     rax, BUCKET_MASK
    lea     rdx, [rel buckets]
    lea     rax, [rdx + rax*8]    ; &buckets[idx]
    pop     rsi
    pop     rdi
    ret

; _find: rdi=key,rsi=len -> rax=entry ptr or 0 ; r8=&bucket head (for insert/del)
_find:
    call    _bucket_index
    mov     r8, rax               ; &head
    mov     rax, [r8]             ; first entry
.walk:
    test    rax, rax
    je      .none
    ; compare key_len
    mov     rcx, [rax+16]
    cmp     rcx, rsi
    jne     .next
    ; memcmp keys
    push    rax
    push    rdi
    push    rsi
    mov     rdx, rsi
    mov     rsi, [rax+8]          ; stored key ptr
    ; rdi already = search key
    call    memcmp_n
    mov     rcx, rax
    pop     rsi
    pop     rdi
    pop     rax
    test    rcx, rcx
    je      .found
.next:
    mov     rax, [rax]            ; next
    jmp     .walk
.none:
    xor     rax, rax
.found:
    ret

; ks_get: rdi=key,rsi=len -> rax=val ptr (0 if miss), rdx=val len
ks_get:
    call    _find
    test    rax, rax
    je      .miss
    mov     rdx, [rax+32]
    mov     rax, [rax+24]
    ret
.miss:
    xor     rax, rax
    xor     rdx, rdx
    ret

; _copy_arena: rdi=src, rsi=len -> rax=new buffer with copied bytes
_copy_arena:
    push    rdi
    push    rsi
    mov     rdi, rsi
    call    arena_alloc           ; rax = dest
    pop     rsi                   ; len
    pop     rdi                   ; src
    test    rax, rax
    je      .oom
    ; copy len bytes src->dest
    push    rax
    mov     rcx, rsi
    mov     rdx, rdi              ; src
    mov     rdi, rax              ; dest
    mov     rsi, rdx              ; src
    rep     movsb
    pop     rax
.oom:
    ret

; ks_set: rdi=key,rsi=len,rdx=val ptr,rcx=val len -> rax=0 ok, 1 oom
ks_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi              ; key ptr
    mov     r13, rsi              ; key len
    mov     r14, rdx              ; val ptr
    mov     r15, rcx              ; val len
    ; existing?
    mov     rdi, r12
    mov     rsi, r13
    call    _find                 ; rax=entry or 0
    test    rax, rax
    je      .insert
    ; overwrite value (old val bytes leak)
    mov     rbx, rax              ; entry
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena
    test    rax, rax
    je      .oom
    mov     [rbx+24], rax
    mov     [rbx+32], r15
    jmp     .ok
.insert:
    ; copy key
    mov     rdi, r12
    mov     rsi, r13
    call    _copy_arena
    test    rax, rax
    je      .oom
    mov     rbx, rax              ; new key ptr
    ; copy val
    mov     rdi, r14
    mov     rsi, r15
    call    _copy_arena
    test    rax, rax
    je      .oom
    push    rax                   ; new val ptr
    ; alloc entry (40 bytes)
    mov     rdi, 40
    call    arena_alloc
    test    rax, rax
    je      .oom_pop
    pop     rcx                   ; val ptr -> rcx
    mov     [rax+8], rbx          ; key ptr
    mov     [rax+16], r13         ; key len
    mov     [rax+24], rcx         ; val ptr
    mov     [rax+32], r15         ; val len
    ; push onto bucket chain
    mov     rdi, r12
    mov     rsi, r13
    push    rax
    call    _bucket_index         ; rax=&head
    mov     r8, rax
    pop     rax                   ; entry
    mov     rcx, [r8]             ; old head
    mov     [rax], rcx            ; entry->next = old head
    mov     [r8], rax             ; head = entry
.ok:
    xor     rax, rax
    jmp     .ret
.oom_pop:
    pop     rcx
.oom:
    mov     rax, 1
.ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ks_del: rdi=key,rsi=len -> rax=1 if deleted, 0 if absent
ks_del:
    call    _bucket_index
    mov     r8, rax               ; &head
    mov     r9, r8                ; prev slot (points to the pointer to update)
    mov     rax, [r8]             ; entry
.walk:
    test    rax, rax
    je      .absent
    mov     rcx, [rax+16]
    cmp     rcx, rsi
    jne     .next
    push    rax
    push    rdi
    push    rsi
    mov     rdx, rsi
    mov     rsi, [rax+8]
    call    memcmp_n
    mov     rcx, rax
    pop     rsi
    pop     rdi
    pop     rax
    test    rcx, rcx
    je      .unlink
.next:
    lea     r9, [rax]             ; prev slot = &entry->next
    mov     r9, rax               ; r9 = current entry (its +0 is next slot)
    mov     rax, [rax]            ; advance
    jmp     .walk
.unlink:
    ; *prev = entry->next.  prev slot: if r9==r8 (first), head; else r9->next field.
    mov     rcx, [rax]            ; entry->next
    cmp     r9, r8
    jne     .mid
    mov     [r8], rcx
    jmp     .deleted
.mid:
    mov     [r9], rcx             ; prev_entry->next = entry->next
.deleted:
    mov     rax, 1
    ret
.absent:
    xor     rax, rax
    ret
```
(Note: the `.next` prev-pointer bookkeeping above is subtle — the executor MUST verify `ks_del` unlinks a middle-of-chain entry via a wire test that inserts 3 colliding keys. Add such a test if the simple test passes but chains are suspect. Track `r9` as "the entry whose `next` field points at the current entry", initialized so that first-element removal updates the head via the `r9==r8` check.)

Add `fnv1a` to `src/util.asm`:
```nasm
global fnv1a
; fnv1a: rdi=ptr, rsi=len -> rax=64-bit hash
fnv1a:
    mov     rax, 0xcbf29ce484222325   ; offset basis
    mov     r8, 0x100000001b3         ; prime
    test    rsi, rsi
    je      .done
.loop:
    movzx   rcx, byte [rdi]
    xor     rax, rcx
    imul    rax, r8
    inc     rdi
    dec     rsi
    jnz     .loop
.done:
    ret
```

In `src/main.asm`: add `buckets` to BSS and call `arena_init` before `net_serve`:
```nasm
; in section .bss, add:
global buckets
buckets:    resq NBUCKETS         ; 1024 head pointers, zero-initialized

; in .no_banner, before 'call net_serve':
    push    rdi                   ; save port
    call    arena_init
    pop     rdi
```
Add `extern arena_init` at top of `main.asm`.

Extend `src/dispatch.asm`: replace `.try_set: jmp .unknown` with real SET/GET/DEL matching and handlers. Add near the handlers:
```nasm
extern ks_get, ks_set, ks_del

; replace the ".try_set:" label body:
.try_set:
    mov     rsi, [rel argv_lens]
    cmp     rsi, 3
    jne     .unknown
    mov     rdi, [rel argv_ptrs]
    ; compare against SET/GET/DEL (all len 3)
    lea     rsi, [rel name_set]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_set
    mov     rdi, [rel argv_ptrs]
    lea     rsi, [rel name_get]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_get
    mov     rdi, [rel argv_ptrs]
    lea     rsi, [rel name_del]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_del
    jmp     .unknown

section .rodata
s_ok: db "OK"
s_ok_len: equ $ - s_ok

section .text
cmd_set:
    mov     rax, [rel argc]
    cmp     rax, 3
    jne     .argerr
    mov     rdi, [rel argv_ptrs + 8]    ; key
    mov     rsi, [rel argv_lens + 8]
    mov     rdx, [rel argv_ptrs + 16]   ; val
    mov     rcx, [rel argv_lens + 16]
    call    ks_set
    test    rax, rax
    jnz     .oom
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    ret
.argerr:
    call    emit_unknown                ; Task 5 replaces with wrong-args message
    ret
.oom:
    ; -ERR out of memory
    ret

cmd_get:
    mov     rax, [rel argc]
    cmp     rax, 2
    jne     cmd_set.argerr
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_get                      ; rax=val ptr (0=miss), rdx=len
    test    rax, rax
    je      .miss
    mov     rdi, rax
    mov     rsi, rdx
    call    reply_bulk
    ret
.miss:
    call    reply_null
    ret

cmd_del:
    mov     rax, [rel argc]
    cmp     rax, 2
    jne     cmd_set.argerr
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del                      ; rax=1/0
    mov     rdi, rax
    call    reply_int
    ret
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/wire.sh`
Expected: `PASS set`, `PASS get-hit`, `PASS get-miss`, `PASS del`.

Conformance diff vs the oracle (valkey on 7778):
```bash
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk.log
./asmredis 7777 & SRV=$!; sleep 0.3
for c in "SET a 1" "GET a" "GET z" "DEL a" "DEL a" "ECHO hey"; do
  m=$(valkey-cli -p 7777 $c); v=$(valkey-cli -p 7778 $c)
  [ "$m" = "$v" ] && echo "OK  $c -> $m" || echo "DIFF $c: mine=$m valkey=$v"
done
kill $SRV; valkey-cli -p 7778 shutdown nosave 2>/dev/null
```
Expected: all `OK`.

- [ ] **Step 5: Commit**

```bash
git add src/alloc.asm src/keyspace.asm src/util.asm src/dispatch.asm src/main.asm tests/wire.sh
git commit -m "keyspace: arena allocator + hashtable + SET/GET/DEL"
```

---

## Task 5: Robustness — partial reads, pipelining, protocol & arg-count errors

Harden `net` to accumulate bytes across reads and process multiple commands per read; make parser errors surface as `-ERR Protocol error\r\n`; emit the exact wrong-args and unknown-command strings.

**Files:**
- Modify: `src/net.asm` (accumulation + drain loop + leftover compaction)
- Modify: `src/dispatch.asm` (real wrong-args message; unknown message with args)
- Create: `src/errmsg.asm` (builders for wrong-args and unknown, shared)

- [ ] **Step 1: Write the failing test**

Append to `tests/wire.sh`:
```bash
# --- Task 5: pipelining, split reads, protocol error, wrong argc ---
./asmredis 7777 & SRV=$!; sleep 0.3
# two commands in one packet -> two replies concatenated
pipe=$(printf '*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
# split: send SET header, pause, send rest over one connection (use a slow feeder)
split=$( { printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n'; sleep 0.3; printf '$3\r\nabc\r\n'; } | nc -q1 127.0.0.1 7777 | xxd -p)
# protocol error: bad first byte
perr=$(printf '@garbage\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r\n')
# wrong argc for SET
wa=$(printf '*1\r\n$3\r\nSET\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r\n')
kill $SRV 2>/dev/null
[ "$pipe" = "2b504f4e470d0a2b504f4e470d0a" ] && echo "PASS pipeline" || { echo "FAIL pipeline: $pipe"; exit 1; }
[ "$split" = "2b4f4b0d0a" ]                  && echo "PASS split"    || { echo "FAIL split: $split"; exit 1; }
[ "$perr" = "-ERR Protocol error" ]          && echo "PASS protoerr" || { echo "FAIL protoerr: $perr"; exit 1; }
[ "$wa" = "-ERR wrong number of arguments for 'set' command" ] && echo "PASS wrongargs" || { echo "FAIL wrongargs: $wa"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: `FAIL split` and/or `FAIL protoerr`/`FAIL wrongargs` (Task 3/4 close on NEED_MORE and emit the wrong error strings).

- [ ] **Step 3: Write minimal implementation**

Rewrite the `.client_loop` in `src/net.asm` to accumulate and drain. Use a BSS counter `rb_used` (bytes currently buffered):
```nasm
section .bss
rb_used:   resq 1

; .client_loop (replaces Task 3 version):
.client_reset:
    mov     qword [rel rb_used], 0
.client_loop:
    ; read appending at read_buf + rb_used
    mov     rax, SYS_read
    mov     rdi, r13
    lea     rsi, [rel read_buf]
    add     rsi, [rel rb_used]
    mov     rdx, READ_BUF_SIZE
    sub     rdx, [rel rb_used]
    jle     .client_done          ; buffer full with no complete command -> give up
    syscall
    test    rax, rax
    jle     .client_done
    add     [rel rb_used], rax
    mov     qword [rel out_len], 0
.drain:
    lea     rdi, [rel read_buf]
    mov     rsi, [rel rb_used]
    call    parse_one             ; rax=status, rdx=consumed
    cmp     rax, 1
    je      .need_more            ; NEED_MORE: keep buffered bytes, read again
    cmp     rax, 2
    je      .protoerr
    ; OK: dispatch, then advance past consumed bytes
    push    rdx
    call    dispatch
    pop     rdx
    ; compact: move [read_buf+rdx .. rb_used) to front
    mov     rcx, [rel rb_used]
    sub     rcx, rdx              ; remaining
    mov     [rel rb_used], rcx
    test    rcx, rcx
    je      .flush               ; nothing left; flush replies
    ; move remaining to front
    lea     rsi, [rel read_buf]
    add     rsi, rdx
    lea     rdi, [rel read_buf]
    push    rcx
    rep     movsb
    pop     rcx
    jmp     .drain
.flush:
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    syscall
    jmp     .client_reset
.need_more:
    ; write any replies accumulated so far, then read more (keep rb_used)
    mov     rax, [rel out_len]
    test    rax, rax
    je      .client_loop
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    syscall
    mov     qword [rel out_len], 0
    jmp     .client_loop
.protoerr:
    ; flush pending replies + protocol error, then close
    call    emit_protoerr         ; appends "-ERR Protocol error\r\n" to out_buf
    mov     rax, SYS_write
    mov     rdi, r13
    lea     rsi, [rel out_buf]
    mov     rdx, [rel out_len]
    syscall
    jmp     .client_done
```
Add `extern emit_protoerr` to net.asm. Note the `.drain` loop flushes only when the buffer empties or on NEED_MORE; for pipelined commands all replies accumulate in `out_buf` then flush together (matches the expected concatenated `+PONG+PONG`).

`src/errmsg.asm` (protocol error + wrong-args + unknown-with-args builders):
```nasm
%include "syscalls.inc"
global emit_protoerr, emit_wrongargs, emit_unknown2
extern append_raw
extern argc, argv_ptrs, argv_lens

section .rodata
m_proto:    db "-ERR Protocol error", 13, 10
m_proto_len: equ $ - m_proto
wa_pre:     db "-ERR wrong number of arguments for '"
wa_pre_len: equ $ - wa_pre
wa_post:    db "' command", 13, 10
wa_post_len: equ $ - wa_post
uk_pre:     db "-ERR unknown command '"
uk_pre_len: equ $ - uk_pre
uk_mid:     db "', with args beginning with: "
uk_mid_len: equ $ - uk_mid
uk_end:     db 13, 10
q_sp:       db "' "                    ; used to wrap each arg: 'arg' <space>
ap:         db "'"

section .text
emit_protoerr:
    lea     rdi, [rel m_proto]
    mov     rsi, m_proto_len
    jmp     append_raw            ; tail-call: appends and returns

; emit_wrongargs: rdi=lowercase cmd name ptr, rsi=len -> full wrong-args line
; NOTE: message uses the *lowercase* command name (valkey does: 'set', 'get'...).
emit_wrongargs:
    push    rdi
    push    rsi
    lea     rdi, [rel wa_pre]
    mov     rsi, wa_pre_len
    call    append_raw
    pop     rsi
    pop     rdi
    call    append_raw            ; the command name (already lowercase)
    lea     rdi, [rel wa_post]
    mov     rsi, wa_post_len
    call    append_raw
    ret

; emit_unknown2: builds "-ERR unknown command '<argv0>', with args beginning with: 'a' 'b' \r\n"
; argv0 uses ORIGINAL bytes; but dispatch uppercased argv[0] in place. To match valkey exactly,
; dispatch must pass the ORIGINAL argv0 (see Task 5 dispatch change: uppercase into a scratch copy).
emit_unknown2:
    lea     rdi, [rel uk_pre]
    mov     rsi, uk_pre_len
    call    append_raw
    mov     rdi, [rel argv_ptrs]
    mov     rsi, [rel argv_lens]
    call    append_raw
    lea     rdi, [rel uk_mid_hack]  ; "', with args beginning with: "
    mov     rsi, uk_mid_len
    call    append_raw
    ; each remaining arg: 'arg'<space>
    mov     r10, 1
.args:
    mov     rax, [rel argc]
    cmp     r10, rax
    jae     .fin
    lea     rdi, [rel ap]
    mov     rsi, 1
    call    append_raw
    mov     rdi, [rel argv_ptrs + r10*8]
    mov     rsi, [rel argv_lens + r10*8]
    call    append_raw
    lea     rdi, [rel q_sp]         ; "' "  (apostrophe + space)
    mov     rsi, 2
    call    append_raw
    inc     r10
    jmp     .args
.fin:
    lea     rdi, [rel uk_end]
    mov     rsi, 2
    call    append_raw
    ret

section .rodata
uk_mid_hack: db "', with args beginning with: "
```
(The `uk_mid`/`uk_mid_hack` duplication is redundant — use one label; the executor should keep a single `uk_mid` and reference it. Left as a fix-on-implement note.)

**Dispatch change to match unknown/wrong-args exactly:** in `src/dispatch.asm`, do NOT uppercase `argv[0]` in place. Instead copy `argv[0]` (up to, say, 16 bytes) into a scratch BSS buffer `cmd_upper`, uppercase the copy, and match against the table using the copy. Keep `argv_ptrs[0]` pointing at the original bytes so `emit_unknown2` prints the original. Replace the earlier `emit_unknown` calls with `emit_unknown2`, and replace `.argerr: call emit_unknown` in each handler with a call to `emit_wrongargs` passing the lowercase literal name:
```nasm
section .rodata
lc_set: db "set"
lc_get: db "get"
lc_del: db "del"
lc_echo: db "echo"
section .bss
cmd_upper: resb 16
section .text
; at start of dispatch, replace the in-place uppercase with:
    mov     rax, [rel argv_lens]
    cmp     rax, 16
    ja      .unknown              ; command names we support are <=4; long -> unknown
    ; copy argv0 -> cmd_upper
    mov     rsi, [rel argv_ptrs]
    lea     rdi, [rel cmd_upper]
    mov     rcx, rax
    push    rax
    rep     movsb
    pop     rax
    lea     rdi, [rel cmd_upper]
    mov     rsi, rax
    call    to_upper_buf
    ; now match cmd_upper (rdi=cmd_upper, current len in rax) against table
    ; ... use [rel cmd_upper] as the compare source instead of argv_ptrs[0] ...
```
Each handler's arg-count error becomes, e.g. for SET:
```nasm
.argerr:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
    call    emit_wrongargs
    ret
```
Wire `cmd_get`/`cmd_del` to their own `lc_get`/`lc_del` argerr labels the same way (repeat the 3-line block per handler — do not share one label, since the name differs).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/wire.sh`
Expected: all prior PASS lines plus `PASS pipeline`, `PASS split`, `PASS protoerr`, `PASS wrongargs`.

- [ ] **Step 5: Commit**

```bash
git add src/net.asm src/errmsg.asm src/dispatch.asm tests/wire.sh
git commit -m "robustness: partial reads, pipelining, protocol + arg-count errors"
```

---

## Task 6: Full conformance + benchmark smoke + docs

Consolidate the test harness to diff every command against the Valkey oracle, add a benchmark smoke run, and write a short README.

**Files:**
- Modify: `tests/wire.sh` (add an oracle-diff section that boots valkey on 7778 and compares)
- Create: `README.md`

- [ ] **Step 1: Write the failing test**

Add a final conformance block to `tests/wire.sh`:
```bash
# --- Task 6: full conformance diff against valkey oracle ---
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk-oracle.log --dir /tmp
./asmredis 7777 & SRV=$!; sleep 0.3
fail=0
check() { m=$(valkey-cli -p 7777 "$@"); v=$(valkey-cli -p 7778 "$@"); if [ "$m" != "$v" ]; then echo "DIFF [$*] mine=<$m> valkey=<$v>"; fail=1; fi; }
check PING
check ECHO hello
check SET foo bar
check GET foo
check GET missing
check SET foo baz          # overwrite
check GET foo
check DEL foo
check DEL foo
check SET a 1
check SET b 2
check GET a
check GET b
kill $SRV 2>/dev/null
valkey-cli -p 7778 shutdown nosave 2>/dev/null
[ "$fail" = "0" ] && echo "PASS conformance" || { echo "FAIL conformance"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/wire.sh`
Expected: either PASS (if Tasks 3-5 are correct) or specific `DIFF` lines pinpointing a mismatch. If it already passes, that's acceptable — this task's value is the consolidated harness and README; proceed.

- [ ] **Step 3: Write minimal implementation**

If any `DIFF` appears, fix the responsible handler (most likely candidates: overwrite semantics in `ks_set`, or an off-by-one in `itoa_u`). Re-run until `PASS conformance`.

Add a benchmark smoke target to the `Makefile`:
```make
bench: $(BIN)
	./$(BIN) 7777 & echo $$! > /tmp/asmredis.pid; sleep 0.3; \
	valkey-benchmark -p 7777 -t set,get -n 10000 -q -c 1 ; \
	kill $$(cat /tmp/asmredis.pid)
```
Note `-c 1` (single connection): milestone A serves one client at a time, so concurrency >1 would stall. Document this.

`README.md`:
```markdown
# asmredis

A minimal Redis/Valkey-compatible server in pure x86-64 assembly (NASM), no libc.
Milestone A: blocking single-client RESP2 server for `PING ECHO SET GET DEL`.

## Build & run
    make
    ./asmredis 7777

## Test (needs valkey-server + valkey-cli + nc)
    make test

## Benchmark smoke (single connection)
    make bench

## Limits (milestone A)
- One client at a time (epoll event loop is milestone C).
- Array-form RESP requests only (inline commands are milestone B).
- Bump allocator never frees; DEL/overwrite leak memory (milestone B).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: every `PASS` line including `PASS conformance`.
Then: `make bench` — expect non-zero requests/sec for SET and GET (smoke only).

- [ ] **Step 5: Commit**

```bash
git add tests/wire.sh Makefile README.md
git commit -m "conformance: full valkey oracle diff + benchmark smoke + README"
```

---

## Self-Review (completed during planning)

**Spec coverage:** every scope-A command (`PING ECHO SET GET DEL`) has a handler + test (Tasks 3-4); every reply variant in the spec's protocol table is asserted at the byte level (Tasks 3-6); partial reads / pipelining / protocol errors / wrong-argc from the spec's "Error handling" and "Data flow" sections are Task 5; the 1024-bucket FNV-1a chained hashtable, 40-byte entry layout, and `mmap` bump arena from the spec's "Keyspace"/"Memory" sections are Task 4; build system and three-layer testing from the spec are Tasks 1 and 6.

**Known implementation-time risks flagged inline for the executor:**
1. `ks_del` middle-of-chain unlink (`r9` prev-pointer bookkeeping) — verify with a 3-colliding-keys wire test.
2. `emit_unknown2` must print the *original* argv0 bytes, so dispatch uppercases into a `cmd_upper` scratch copy, not in place.
3. The duplicated `uk_mid`/`uk_mid_hack` label in `errmsg.asm` should collapse to one label.
4. `rep movsb` register discipline (src=`rsi`, dest=`rdi`) is easy to get backwards — the reply/keyspace copy helpers standardize on it; double-check each use.
5. Wrong-args messages use the *lowercase* command name (`'set'`), matching Valkey.

These are correctness hotspots, not plan gaps — the Task 4/5 wire tests will catch regressions.
```
