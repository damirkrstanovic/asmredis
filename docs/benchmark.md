# asmredis — Benchmarks

> **Status.** The **milestone-A** results below are a preliminary hand-run spot
> check (client counts 1 and 50, throughput + p50 only). The **milestone-C**
> section is the real sweep: full percentile distribution (min/p50/p75/p95/p99/
> max/avg), `-c` 1→500, two payload sizes, median of 3 runs — see
> "Milestone C (epoll event loop) — full sweep" below. The methodology section is
> what that sweep implements (minus `-n 1M` and CPU-governor pinning).

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

## Milestone C (epoll event loop) — full sweep

The milestone-A `-c 50` stall above is **resolved**: with the single-threaded
non-blocking `epoll` event loop (per-connection read/write buffers, `EPOLLOUT`
backpressure), asmredis completes every run and **scales cleanly** to `-c 500`
instead of hanging at `-c 50`.

**Method.** `valkey-benchmark -t set,get -n 100000 --precision 3`, concurrency
`-c ∈ {1,20,50,100,200,500}`, two payload sizes (`-d 3`, `-d 512`). Each cell is
the **median of 3 runs**. asmredis on port 7777, Valkey 9.1.0 oracle on 7778,
same box, loopback. Latency values are milliseconds. Environment as in
"Preliminary results" above (i5-8400, Linux 7.1.3, single core saturated).
_Deviations from the planned methodology: `-n 100000` (not 1M), and the CPU
governor was not pinned — so treat sub-few-percent throughput gaps as noise._

### Payload `-d 3` (default, 3-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **50,659** | 0.015 | 0.008 | 0.015 | 0.023 | 0.023 | 0.039 | 0.207 |
| 1 | SET | valkey | 40,568 | 0.021 | 0.016 | 0.023 | – | 0.031 | 0.063 | 0.191 |
| 1 | GET | **asmredis** | **50,736** | 0.015 | 0.008 | 0.015 | 0.023 | 0.023 | 0.039 | 0.183 |
| 1 | GET | valkey | 41,789 | 0.021 | 0.008 | 0.023 | – | 0.023 | 0.063 | 0.271 |
| 20 | SET | asmredis | 102,881 | 0.102 | 0.024 | 0.103 | 0.111 | 0.127 | 0.159 | 0.311 |
| 20 | SET | valkey | 110,132 | 0.099 | 0.032 | 0.103 | 0.103 | 0.119 | 0.159 | 0.439 |
| 20 | GET | asmredis | 103,199 | 0.102 | 0.032 | 0.103 | 0.111 | 0.127 | 0.159 | 0.359 |
| 20 | GET | valkey | 109,170 | 0.099 | 0.024 | 0.103 | – | 0.119 | 0.151 | 0.391 |
| 50 | SET | asmredis | 102,041 | 0.251 | 0.088 | 0.255 | 0.271 | 0.303 | 0.343 | 0.615 |
| 50 | SET | valkey | 107,991 | 0.240 | 0.080 | 0.239 | 0.247 | 0.279 | 0.327 | 0.871 |
| 50 | GET | asmredis | 100,908 | 0.253 | 0.072 | 0.255 | 0.271 | 0.303 | 0.335 | 0.479 |
| 50 | GET | valkey | 105,485 | 0.245 | 0.080 | 0.247 | 0.255 | 0.279 | 0.319 | 0.839 |
| 100 | SET | asmredis | 102,987 | 0.492 | 0.208 | 0.495 | 0.543 | 0.591 | 0.671 | 1.111 |
| 100 | SET | valkey | 105,042 | 0.486 | 0.152 | 0.487 | 0.503 | 0.543 | 0.599 | 1.639 |
| 100 | GET | asmredis | 102,459 | 0.494 | 0.136 | 0.503 | 0.535 | 0.591 | 0.655 | 1.039 |
| 100 | GET | valkey | 105,152 | 0.485 | 0.112 | 0.479 | 0.495 | 0.543 | 0.615 | 1.695 |
| 200 | SET | asmredis | 102,354 | 0.984 | 0.272 | 0.991 | 1.079 | 1.183 | 1.327 | 2.191 |
| 200 | SET | valkey | 101,937 | 0.992 | 0.304 | 0.991 | 1.023 | 1.103 | 1.207 | 3.519 |
| 200 | GET | asmredis | 104,167 | 0.970 | 0.296 | 0.983 | 1.079 | 1.215 | 1.343 | 2.143 |
| 200 | GET | valkey | 104,058 | 0.971 | 0.344 | 0.975 | 1.023 | 1.119 | 1.231 | 3.047 |
| 500 | SET | asmredis | 95,329 | 2.641 | 0.536 | 2.639 | 2.887 | 3.287 | 3.775 | 5.191 |
| 500 | SET | valkey | 102,041 | 2.464 | 0.296 | 2.463 | 2.855 | 3.191 | 3.431 | 4.783 |
| 500 | GET | asmredis | 102,775 | 2.457 | 0.400 | 2.447 | 2.895 | 3.343 | 3.767 | 4.879 |
| 500 | GET | valkey | 102,775 | 2.453 | 0.696 | 2.463 | 2.783 | 3.119 | 3.391 | 4.767 |

### Payload `-d 512` (512-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **50,050** | 0.016 | 0.008 | 0.015 | 0.023 | 0.023 | 0.039 | 0.383 |
| 1 | SET | valkey | 40,683 | 0.021 | 0.016 | 0.023 | – | 0.031 | 0.063 | 0.239 |
| 1 | GET | **asmredis** | **50,100** | 0.016 | 0.008 | 0.015 | 0.023 | 0.023 | 0.047 | 0.631 |
| 1 | GET | valkey | 41,442 | 0.021 | 0.008 | 0.023 | – | 0.023 | 0.063 | 0.223 |
| 20 | SET | asmredis | 102,041 | 0.103 | 0.024 | 0.103 | 0.119 | 0.127 | 0.167 | 0.391 |
| 20 | SET | valkey | 110,254 | 0.099 | 0.032 | 0.095 | 0.103 | 0.119 | 0.159 | 0.415 |
| 20 | GET | asmredis | 101,523 | 0.104 | 0.032 | 0.103 | 0.119 | 0.127 | 0.159 | 0.303 |
| 20 | GET | valkey | 106,952 | 0.101 | 0.032 | 0.103 | – | 0.119 | 0.159 | 0.383 |
| 50 | SET | asmredis | 101,215 | 0.253 | 0.096 | 0.255 | 0.271 | 0.303 | 0.351 | 0.615 |
| 50 | SET | valkey | 106,157 | 0.244 | 0.072 | 0.239 | 0.255 | 0.279 | 0.327 | 0.879 |
| 50 | GET | asmredis | 101,010 | 0.255 | 0.072 | 0.255 | 0.271 | 0.303 | 0.351 | 0.815 |
| 50 | GET | valkey | 107,066 | 0.242 | 0.072 | 0.239 | 0.247 | 0.279 | 0.327 | 0.847 |
| 100 | SET | asmredis | 103,093 | 0.490 | 0.144 | 0.495 | 0.535 | 0.599 | 0.655 | 1.119 |
| 100 | SET | valkey | 105,263 | 0.484 | 0.152 | 0.479 | 0.495 | 0.543 | 0.607 | 1.727 |
| 100 | GET | asmredis | 101,937 | 0.497 | 0.152 | 0.503 | 0.535 | 0.591 | 0.671 | 0.999 |
| 100 | GET | valkey | 104,712 | 0.485 | 0.176 | 0.479 | 0.503 | 0.551 | 0.615 | 1.655 |
| 200 | SET | asmredis | 103,413 | 0.977 | 0.304 | 0.991 | 1.071 | 1.199 | 1.375 | 2.135 |
| 200 | SET | valkey | 103,413 | 0.977 | 0.264 | 0.967 | 1.015 | 1.119 | 1.255 | 3.335 |
| 200 | GET | asmredis | 103,199 | 0.977 | 0.240 | 0.983 | 1.079 | 1.199 | 1.327 | 2.015 |
| 200 | GET | valkey | 103,842 | 0.972 | 0.272 | 0.975 | 1.023 | 1.111 | 1.207 | 3.183 |
| 500 | SET | asmredis | 95,785 | 2.631 | 0.864 | 2.631 | 2.855 | 3.199 | 3.615 | 6.223 |
| 500 | SET | valkey | 101,215 | 2.486 | 1.136 | 2.487 | 2.895 | 3.223 | 3.463 | 4.463 |
| 500 | GET | asmredis | 97,943 | 2.570 | 0.776 | 2.583 | 2.855 | 3.287 | 3.735 | 4.959 |
| 500 | GET | valkey | 97,943 | 2.568 | 0.768 | 2.575 | 2.743 | 3.111 | 3.439 | 6.727 |

**Reading the numbers.**
- **`-c 1`: asmredis ~25% faster** on throughput (≈50.5K vs ≈41K) and ~half the
  p50 latency (0.015 vs 0.023 ms) — a shorter per-request path (no persistence
  hooks, expiry, RESP3, ACLs, CONFIG, stats).
- **`-c 20–100`: Valkey edges ahead** on throughput by ~3–7%; latency
  distributions are within a few percent either way. Both saturate the one core.
- **`-c 200`: dead even** on throughput, and asmredis shows a **tighter tail**
  (max ≈2.1 ms vs Valkey's ≈3.0–3.5 ms) — no allocator GC / background threads,
  so fewer latency spikes.
- **`-c 500`: Valkey slightly ahead on SET** (~102K vs ~95K), GET tied (~98–103K);
  both complete cleanly. Tails are comparable at this level.
- The **milestone-A stall is gone at every level** — the event loop multiplexes
  all clients in one thread, the same way Valkey's does.

`p75` is blank (`–`) for a few low-concurrency Valkey rows because
`valkey-benchmark`'s percentile printout skips the 75% boundary when one latency
bucket spans it; those distributions are tight enough that p75 ≈ p50.

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
