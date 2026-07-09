# asmredis — Benchmarks

> **Status: preliminary spot-check, not the real benchmark suite.**
> These numbers were captured by hand while sanity-checking the milestone-A
> server. They cover only two client counts (1 and 50) and only the throughput
> + p50 that `valkey-benchmark -q` prints by default. The full methodology below
> is what we intend to measure properly later.

## Planned methodology (future)

Measure, for each command, the full latency distribution — **min, max, p50, p75,
p95, p99, and avg** — plus throughput (requests/sec), across client-concurrency
levels:

| Clients (`-c`) | 1 | 20 | 50 | 100 | 200 | 500 |
|---|---|---|---|---|---|---|

- Commands: `SET`, `GET` (and `PING` via the array form only — see caveat).
- Compare asmredis against a Valkey oracle on an adjacent port, same box, same run.
- Report percentiles with `valkey-benchmark --precision 3` and/or the
  `--csv`/latency-histogram output rather than the `-q` one-liner (which only
  gives rps + p50).
- Fixed request count per level (e.g. `-n 1000000`) and a couple of payload
  sizes (`-d 3`, `-d 512`).
- Pin/record CPU governor, and run 3× taking the median, to reduce noise.

**Expectation to validate:** asmredis (blocking, one client at a time) should win
or tie at `-c 1` on latency but fail to scale — and in fact *stall* — as
concurrency rises, until the milestone-C `epoll` event loop lands. Valkey should
scale up with its single-threaded event loop. The `-c 50` result below already
shows the stall.

---

## Preliminary results

### Environment
- CPU: Intel Core i5-8400 @ 2.80GHz (6 cores / 6 threads)
- Kernel: Linux 7.1.3-1-cachyos (x86_64)
- Reference: Valkey server 9.1.0 (`malloc=jemalloc`, build bits=64)
- asmredis: pure NASM (v3.02), static no-libc ELF64, **17,384-byte** binary
- Tool: `valkey-benchmark` 9.1.0, loopback (127.0.0.1)
- asmredis on port 7777, Valkey oracle on port 7778
- Milestone-A server: **blocking, serves one client at a time**

### `-c 1` — single connection, `-n 100000`, `-d 3` (default payload)

| Command | asmredis rps | asmredis p50 | valkey rps | valkey p50 |
|---|---|---|---|---|
| SET | **50,994** | 0.015 ms | 38,700 | 0.023 ms |
| GET | **50,813** | 0.015 ms | 40,016 | 0.023 ms |

512-byte payload (`-d 512`, asmredis only, `-n 50000`): SET 50,352 rps, GET
50,050 rps — essentially unchanged, the arena copy is cheap.

At one connection, asmredis is ~30% faster: throughput ≈ `1 / round-trip-latency`,
and asmredis's per-request path is far shorter (no persistence hooks, expiry,
RESP3, ACLs, CONFIG, stats — it does almost nothing but parse + hash-lookup).
Both are loopback, so ~0.02 ms is dominated by syscall + context-switch cost.

### `-c 50` — 50 connections, `-n 100000`, `-d 3`

| Command | asmredis | valkey rps | valkey p50 |
|---|---|---|---|
| SET | **stalled at 99,951 / 100,000; timed out (60 s)** | 107,875 | 0.239 ms |
| GET | not reached (timed out during SET) | 108,696 | 0.239 ms |

- Valkey scaled ~39K → ~108K rps (2.7×): its event loop multiplexes all 50
  connections in one thread, amortizing syscall overhead.
- asmredis **did not crash** (still answered `PING`→`PONG` afterward) but the
  benchmark hung at exactly **99,951 = 100000 − 49** requests. Mechanism:
  `valkey-benchmark` opens all 50 connections up front (kernel completes the
  handshakes into the listen backlog) and each fires an initial request.
  asmredis `accept()`s **only connection #1** and serves it in a blocking loop —
  that one client drains almost the entire shared request pool at ~50K rps. The
  other **49 connections are never accepted**, so their 49 initial requests never
  get a reply, and the benchmark waits forever for them → stall at `100000 − 49`.

This is textbook head-of-line blocking: fast hot path, zero concurrency.
Milestone C (single-threaded `epoll` event loop) is designed to close exactly
this gap, touching only `src/net.asm` — `parser`/`dispatch`/`keyspace` are
already agnostic to how bytes arrive.

---

## Milestone C (epoll event loop)

The milestone-A `-c 50` stall above is **now resolved**: with the single-threaded
non-blocking `epoll` event loop (per-connection read/write buffers, `EPOLLOUT`
backpressure), asmredis completes every run and **scales cleanly** across all
concurrency levels instead of hanging at `-c 50`.

Concurrency sweep, `valkey-benchmark -t set,get -n 50000 -q`, default payload
(`-d 3`), loopback. asmredis on 7777, Valkey 9.1.0 oracle on 7778, same box.
Numbers are throughput (requests/sec) from a single run — rough, not authoritative.

| `-c` | asmredis SET | valkey SET | asmredis GET | valkey GET |
|---|---|---|---|---|
| 1   | **50,352** | 40,193 | **50,659** | 41,701 |
| 20  | 103,520 | 108,225 | 103,520 | 105,042 |
| 50  | 102,249 | 108,932 | 102,669 | 107,066 |
| 100 | 102,881 | 105,932 | 102,459 | 103,950 |
| 200 | 104,167 | 104,167 | 103,093 | 104,384 |

- At `-c 1` asmredis stays ~25% ahead (shorter per-request path, as before).
- From `-c 20` upward both servers saturate the single core at ~100–108K rps;
  asmredis tracks Valkey within a few percent and **no longer stalls** — the
  event loop multiplexes all clients in one thread just like Valkey's does.
- p50 latency grows with concurrency as expected (≈0.015 ms at `-c 1` →
  ≈0.99 ms at `-c 200`) and stays within a few percent of Valkey's.

The `tests/wire.sh` suite additionally verifies a heavier `-c 200 -n 40000` run
completes and that file-descriptor count returns to baseline after 200
short-lived connections (no fd leak) — see `concurrency-c200` and `no-fd-leak`.

## Caveats / notes

- **`PING` inline not supported.** `valkey-benchmark -t ping` runs `PING_INLINE`
  (bare `PING\r\n`, no array framing); asmredis rejects non-`*` first bytes as a
  protocol error and closes the connection, so `-t ping` fails against it. The
  array-framed ping (`PING_MBULK` / `valkey-cli PING`) works. Benchmark asmredis
  with `-t set,get` only for now.
- **`WARNING: Could not fetch server CONFIG`** from `valkey-benchmark` against
  asmredis is expected — there is no `CONFIG` command; the tool falls back to
  defaults and proceeds.
- Numbers are a single hand-run on a loaded desktop; treat as rough, not
  authoritative. The planned suite (medians of repeated runs, full percentiles,
  the concurrency sweep above) will supersede this.
