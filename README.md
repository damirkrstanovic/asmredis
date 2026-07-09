# asmredis

A minimal Redis/Valkey-compatible server written in pure x86-64 assembly (NASM), with no libc — only raw Linux syscalls. A single-threaded non-blocking `epoll` event loop serves many concurrent clients over RESP2, supporting `PING`, `ECHO`, `SET`, `GET`, `DEL`.

## Build & run
    make
    ./asmredis 7777        # listen on port 7777 (default 6379 if no arg)

Then, from another terminal:
    valkey-cli -p 7777 PING
    valkey-cli -p 7777 SET greeting hello
    valkey-cli -p 7777 GET greeting

## Test
Requires `valkey-server`, `valkey-cli`, `nc`, and `xxd`. Compares raw wire bytes and full-command behavior against a live valkey oracle:
    make test

## Benchmark smoke (single connection)
    make bench

## How it works
- `src/net.asm` — epoll event loop + per-connection read/write buffers (non-blocking, concurrent clients), with cross-read accumulation and pipelining.
- `src/parser.asm` — RESP2 array request parser producing an argv[] of pointers into the read buffer.
- `src/dispatch.asm` — case-insensitive command table + handlers.
- `src/keyspace.asm` — 1024-bucket separately-chained hashtable (FNV-1a) over an mmap'd bump arena.
- `src/alloc.asm`, `src/reply.asm`, `src/util.asm`, `src/errmsg.asm` — arena allocator, RESP reply writers, leaf helpers (itoa/memcmp/hash/uppercase), error messages.

## Limits (milestone A)
- **Concurrency:** asmredis uses a single-threaded non-blocking `epoll` event loop handling up to `MAX_CONNS` (1024) concurrent clients, with correct write backpressure (per-connection pending-write buffers + `EPOLLOUT`).
- Array-form RESP requests only; the inline command protocol is not supported (a non-`*` first byte returns `-ERR Protocol error`).
- The bump allocator never frees: `DEL` and value overwrites leak arena memory (a real allocator / rehashing is a future milestone).
