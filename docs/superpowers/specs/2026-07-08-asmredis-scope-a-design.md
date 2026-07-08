# asmredis — Scope A Design

**Date:** 2026-07-08
**Status:** Approved, ready for implementation planning

A minimal Redis/Valkey-compatible key-value server written in pure x86-64
assembly (NASM), using only raw Linux syscalls — no libc. This document
specifies **milestone A**: a blocking, single-client-at-a-time TCP server that
speaks the RESP protocol and handles `PING`, `ECHO`, `SET`, `GET`, and `DEL`.

## Goals

- Speak enough RESP that the stock `valkey-cli` / `redis-cli` can connect and
  run `PING`, `ECHO`, `SET`, `GET`, `DEL` against it with byte-identical
  replies to Valkey 9.1.0.
- Pure syscalls, static ELF64 binary, zero runtime dependencies.
- Architecture that keeps the keyspace and command dispatch fully decoupled
  from the I/O model, so a later milestone can swap the blocking accept-loop
  for an `epoll` event loop without touching command logic.

## Non-goals (explicitly deferred)

- Concurrency: one client is served to completion before the next is accepted.
  (`epoll` event loop is milestone C.)
- Memory reclamation: the bump allocator never frees. `DEL` and value
  overwrites leak arena memory. (A real allocator / rehashing is milestone B.)
- Data types beyond byte-string values; expiry/TTL; persistence; auth; config;
  multiple databases; `COMMAND` introspection.

## Ground-truth protocol (captured from Valkey 9.1.0, not from memory)

Requests are RESP arrays of bulk strings:

```
*3\r\n $3\r\nSET\r\n $1\r\nk\r\n $3\r\nabc\r\n
```

Confirmed reply bytes (via raw `nc` + `xxd` against `valkey-server -p 7777`):

| Command        | Reply bytes                                                        | RESP type        |
|----------------|-------------------------------------------------------------------|------------------|
| `PING`         | `+PONG\r\n`                                                        | simple string    |
| `SET k v`      | `+OK\r\n`                                                          | simple string    |
| `GET k` (hit)  | `$3\r\nabc\r\n`                                                    | bulk string      |
| `GET k` (miss) | `$-1\r\n`                                                          | null bulk (RESP2)|
| `DEL k`        | `:1\r\n` / `:0\r\n`                                                | integer (count)  |
| `ECHO s`       | `$5\r\nhello\r\n`                                                  | bulk string      |
| wrong argc     | `-ERR wrong number of arguments for 'set' command\r\n`            | error            |
| unknown cmd    | `-ERR unknown command 'FOO', with args beginning with: 'a' 'b' \r\n` | error         |

Notes:
- Inline commands (`PING\r\n` with no array framing) are also accepted by the
  reference server, but real clients always send arrays. Milestone A parses the
  **array form only**; a bare inline `PING` is out of scope (documented, not a
  bug).
- `GET` miss uses the RESP2 null bulk `$-1\r\n` (we speak RESP2; no `HELLO`).

## Architecture

Six units. The `net` unit is the only one that touches sockets; `keyspace` and
`dispatch` operate purely on buffers and registers, which is what makes the I/O
model swappable.

```
  net (I/O)  --bytes-->  parser (RESP)  --argv[]-->  dispatch (cmd table)
     ^                                                    |
     |  reply bytes                                       | get/set/del
     +----------------------------------------------------+
                                                    keyspace (hashtable)
                                                          |
                                                        alloc (bump arena)

  reply.asm (RESP writer) + util.asm (memcmp, itoa, hash) cross-cut all.
```

| Unit       | File            | Responsibility                                              | Interface (register/memory contract) |
|------------|-----------------|-------------------------------------------------------------|--------------------------------------|
| `main`     | `src/main.asm`  | `_start`, arena init, calls `net` accept-loop, exit         | none (entry point)                   |
| `net`      | `src/net.asm`   | socket/setsockopt/bind/listen/accept; per-client read/write loop; buffer mgmt | owns conn fd + 16KB read buf + out buf |
| `parser`   | `src/parser.asm`| consume one RESP array from read buffer → `argv` table      | in: buf ptr+len, cursor; out: argc + argv[] (ptr,len pairs), or NEED_MORE |
| `dispatch` | `src/dispatch.asm`| uppercase argv[0], linear-scan command table, call handler | in: argc, argv[]; out: reply appended to out buf |
| `keyspace` | `src/keyspace.asm`| hashtable lookup/insert/delete on byte-string keys        | in: key ptr+len (+val ptr+len); out: val ptr+len or NOTFOUND |
| `alloc`    | `src/alloc.asm` | bump allocator over one `mmap`'d arena                      | in: size (rdi); out: ptr (rax), never fails until arena exhausted |
| `reply`    | `src/reply.asm` | emit RESP: simple string, bulk, null bulk, integer, error   | in: out-buf ptr + payload; advances out-buf cursor |
| `util`     | `src/util.asm`  | `memcmp`, `itoa` (int→ASCII), FNV-1a hash                   | leaf helpers                         |

Shared constants (syscall numbers, `AF_INET`, `SOCK_STREAM`, `SO_REUSEADDR`,
error strings) live in `include/syscalls.inc`.

## Data flow (one command)

1. `net` blocks on `read(connfd, readbuf+used, 16384-used)`.
2. `parser` runs on the buffer from the current cursor:
   - reads `*N\r\n` → argc;
   - for each of N: `$len\r\n`, then records `argv[i] = (ptr into readbuf, len)`,
     then skips the trailing `\r\n`. **No copies** — argv points into readbuf.
   - if the buffer ends mid-command, return `NEED_MORE`; `net` does another
     `read` appending to the buffer and re-parses from the same cursor.
3. `dispatch` uppercases a scratch copy of `argv[0]`, linear-scans the command
   table (`{name, len, argc_min, argc_max, handler_ptr}`), and calls the handler.
4. Handler calls `keyspace` as needed and uses `reply` helpers to append reply
   bytes to the out buffer.
5. After the parser drains the buffer (possibly multiple pipelined commands),
   `net` `write`s the accumulated out buffer, resets the out cursor, compacts
   any unparsed leftover bytes to the front of readbuf, and loops.
6. `read` returning 0 (peer closed) → `close(connfd)`, back to `accept`.

**Pipelining and partial reads** are handled by the cursor + `NEED_MORE` + leftover-compaction
logic above; this is the single trickiest part of the milestone and gets its own
tests.

## Keyspace design

- Fixed **1024 buckets** (power of two; index = `hash & 1023`).
- **Separate chaining.** Entry layout (40 bytes, from arena):
  ```
  offset 0:  next_ptr   (8)   ; next entry in bucket, or 0
  offset 8:  key_ptr    (8)   ; into arena
  offset 16: key_len    (8)
  offset 24: val_ptr    (8)   ; into arena
  offset 32: val_len    (8)
  ```
- Hash: **FNV-1a** (64-bit) over key bytes.
- `SET`: copy key and value bytes into the arena (readbuf is transient). If key
  exists, overwrite `val_ptr`/`val_len` (old value bytes leak). Else allocate an
  entry and push onto the bucket chain.
- `GET`: hash → bucket → walk chain, `memcmp` keys → return val or NOTFOUND.
- `DEL`: unlink from chain, return 1; if absent return 0. Entry/key/val bytes
  leak (`; TODO(milestone-B): reclaim`).

## Memory / allocator

- One `mmap(NULL, ARENA_SIZE, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS)`
  at startup. `ARENA_SIZE` = 64 MiB for milestone A.
- Bump pointer; `alloc(size)` returns current, advances by size (8-byte aligned).
- Arena exhaustion → return error / `-ERR out of memory\r\n` (do not crash).
- The bucket array itself is in `.bss` (fixed 1024×8 bytes).

## Error handling

- **Fatal setup errors** (socket/bind/listen `rax < 0`, e.g. port in use): write
  a short diagnostic to stderr (fd 2) and `exit(1)`.
- **Per-client I/O errors** (`read`/`write` `rax < 0`): `close(connfd)`, continue
  the accept-loop. One bad client never takes down the server.
- **Protocol errors** (malformed RESP: bad prefix byte, non-numeric length):
  send `-ERR Protocol error\r\n` and close the connection.
- **Command-level errors**: exact byte-for-byte strings captured from Valkey —
  wrong-argc and unknown-command messages as in the table above.

## Build

- `nasm -f elf64 -g -F dwarf` per `.asm` → `.o`.
- Link with `ld` (no libc), entry `_start`, static.
- `Makefile` targets: `all` (build `asmredis`), `run` (build + run on a chosen
  port), `test` (build + `tests/wire.sh`), `clean`.

## Testing

Three layers, all against the real reference server:

1. **Golden wire tests** — `tests/wire.sh` pipes raw RESP byte sequences to our
   server via `nc`, hexdumps the reply, and `diff`s against bytes captured from
   `valkey-server`. Covers every row of the protocol table plus a pipelined
   multi-command request and a split-across-reads request.
2. **Real client conformance** — run `valkey-cli -p <ourport>` through
   `PING`/`ECHO`/`SET`/`GET`/`DEL` and confirm expected values; run the same
   sequence against `valkey-server` and diff.
3. **Benchmark (later)** — `valkey-benchmark` once the `epoll` milestone lands.

The test server always runs on a **non-standard port** (e.g. 7777) so it never
collides with a real Redis/Valkey on 6379.

## Repository layout

```
asmredis/
  src/
    main.asm  net.asm  parser.asm  dispatch.asm
    keyspace.asm  alloc.asm  reply.asm  util.asm
  include/
    syscalls.inc          ; syscall numbers, AF_INET/SOCK_STREAM/etc., error strings
  Makefile
  tests/
    wire.sh
  docs/superpowers/specs/
    2026-07-08-asmredis-scope-a-design.md   (this file)
```

## Milestone boundaries

- **A (this spec):** blocking single-client server; `PING ECHO SET GET DEL`;
  RESP2 array requests; leaking bump allocator.
- **B (future):** memory reclamation / real allocator, hashtable rehashing,
  more commands (`EXISTS`, `INCR`, `EXPIRE`/`TTL`), inline command parsing.
- **C (future):** `epoll` non-blocking event loop for concurrent clients and
  performance work — touches only `net`, by design.
