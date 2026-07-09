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

## Milestone B (memory reclamation) — full sweep

Milestone B replaces the old bump-pointer arena (which never freed) with a
**segregated power-of-two free-list allocator**: allocation pops a block off the
size-class free list and deallocation pushes it back, both **O(1) with no syscalls
on the hot path** (the arena is mapped once at startup). `DEL` and `SET`-overwrite
now **reclaim** their old blocks instead of leaking them, and `SET` replies
`-ERR out of memory` on true arena exhaustion rather than corrupting the heap.
The question this sweep answers: **did adding the alloc/free fast path regress
throughput vs milestone C?** The free-list path is only a handful of extra
instructions on `SET`/`DEL` and touches no syscall, so the expectation is "within
noise."

**Method.** Identical to the milestone-C sweep above:
`valkey-benchmark -t set,get -n 100000 --precision 3`, concurrency
`-c ∈ {1,20,50,100,200,500}`, two payloads (`-d 3`, `-d 512`), each cell the
**median of 3 runs**. asmredis on port 7777, Valkey 9.1.0 oracle on 7778, same
box, loopback; latencies in ms. Environment as above, with two minor deltas: the
kernel is **Linux 7.1.3-2-cachyos** (a point-release bump from 7.1.3-1) and the
asmredis binary is now **19,424 bytes** (the allocator adds free-list bookkeeping).
_Caveat for this run: the desktop was **busier than the milestone-C session**
(load average ≈ 4 on 6 cores — a game, browser, containers and other processes
competing for cores), which is visible in the fatter `max` tails (several ms) and
depresses the **absolute** throughput of **both** servers by ~8–13% relative to
the milestone-C numbers. The controlled, load-invariant comparison is therefore
asmredis-B vs the **Valkey oracle measured in the same runs**, not the
cross-session absolute figures._

### Payload `-d 3` (default, 3-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **45,496** | 0.019 | 0.008 | 0.023 | – | 0.031 | 0.047 | 2.679 |
| 1 | SET | valkey | 35,436 | 0.024 | 0.008 | 0.023 | 0.031 | 0.039 | 0.063 | 6.343 |
| 1 | GET | **asmredis** | **45,746** | 0.019 | 0.008 | 0.023 | – | 0.031 | 0.055 | 4.951 |
| 1 | GET | valkey | 36,232 | 0.024 | 0.008 | 0.023 | 0.031 | 0.039 | 0.063 | 3.863 |
| 20 | SET | asmredis | 96,061 | 0.113 | 0.040 | 0.111 | 0.119 | 0.135 | 0.199 | 9.591 |
| 20 | SET | valkey | 102,145 | 0.111 | 0.032 | 0.103 | 0.111 | 0.135 | 0.231 | 6.439 |
| 20 | GET | asmredis | 99,305 | 0.108 | 0.032 | 0.111 | 0.119 | 0.135 | 0.175 | 2.055 |
| 20 | GET | valkey | 102,987 | 0.108 | 0.032 | 0.103 | 0.111 | 0.135 | 0.207 | 11.911 |
| 50 | SET | asmredis | 100,908 | 0.258 | 0.072 | 0.255 | 0.271 | 0.303 | 0.343 | 11.727 |
| 50 | SET | valkey | 104,493 | 0.253 | 0.088 | 0.247 | 0.255 | 0.287 | 0.359 | 5.439 |
| 50 | GET | asmredis | 100,100 | 0.261 | 0.080 | 0.247 | 0.271 | 0.303 | 0.335 | 16.799 |
| 50 | GET | valkey | 104,712 | 0.249 | 0.072 | 0.247 | 0.255 | 0.295 | 0.351 | 3.191 |
| 100 | SET | asmredis | 99,502 | 0.523 | 0.184 | 0.503 | 0.559 | 0.623 | 0.679 | 10.727 |
| 100 | SET | valkey | 98,039 | 0.541 | 0.144 | 0.495 | 0.519 | 0.575 | 1.271 | 10.519 |
| 100 | GET | asmredis | 99,010 | 0.518 | 0.144 | 0.495 | 0.559 | 0.623 | 0.695 | 13.903 |
| 100 | GET | valkey | 100,705 | 0.517 | 0.152 | 0.495 | 0.511 | 0.559 | 0.639 | 14.511 |
| 200 | SET | asmredis | 94,787 | 1.072 | 0.440 | 1.039 | 1.167 | 1.351 | 1.799 | 15.183 |
| 200 | SET | valkey | 93,284 | 1.087 | 0.312 | 1.055 | 1.111 | 1.279 | 1.511 | 11.447 |
| 200 | GET | asmredis | 95,511 | 1.057 | 0.128 | 1.015 | 1.175 | 1.335 | 1.655 | 9.823 |
| 200 | GET | valkey | 93,985 | 1.088 | 0.464 | 1.023 | 1.119 | 1.271 | 1.943 | 16.991 |
| 500 | SET | asmredis | 83,963 | 3.005 | 0.752 | 3.007 | 3.375 | 3.927 | 4.311 | 5.623 |
| 500 | SET | valkey | 89,526 | 2.819 | 0.992 | 2.839 | 3.071 | 3.479 | 4.127 | 5.855 |
| 500 | GET | asmredis | 83,752 | 3.013 | 1.056 | 3.007 | 3.479 | 4.015 | 4.279 | 5.599 |
| 500 | GET | valkey | 88,028 | 2.869 | 1.088 | 2.847 | 3.063 | 3.487 | 4.015 | 6.559 |

### Payload `-d 512` (512-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **46,041** | 0.019 | 0.008 | 0.023 | 0.031 | 0.031 | 0.055 | 4.287 |
| 1 | SET | valkey | 34,542 | 0.025 | 0.016 | 0.023 | 0.031 | 0.047 | 0.071 | 8.743 |
| 1 | GET | **asmredis** | **44,703** | 0.020 | 0.008 | 0.023 | – | 0.031 | 0.055 | 1.071 |
| 1 | GET | valkey | 35,026 | 0.025 | 0.008 | 0.023 | – | 0.039 | 0.071 | 9.783 |
| 20 | SET | asmredis | 98,039 | 0.111 | 0.032 | 0.111 | 0.119 | 0.143 | 0.207 | 5.991 |
| 20 | SET | valkey | 100,100 | 0.116 | 0.032 | 0.103 | 0.111 | 0.143 | 0.335 | 6.679 |
| 20 | GET | asmredis | 97,371 | 0.112 | 0.032 | 0.111 | 0.119 | 0.135 | 0.215 | 9.679 |
| 20 | GET | valkey | 101,112 | 0.111 | 0.032 | 0.103 | 0.111 | 0.135 | 0.239 | 8.855 |
| 50 | SET | asmredis | 98,522 | 0.266 | 0.056 | 0.255 | 0.279 | 0.311 | 0.359 | 6.711 |
| 50 | SET | valkey | 105,708 | 0.248 | 0.072 | 0.239 | 0.255 | 0.287 | 0.367 | 2.695 |
| 50 | GET | asmredis | 101,626 | 0.253 | 0.080 | 0.255 | 0.271 | 0.303 | 0.343 | 0.639 |
| 50 | GET | valkey | 100,503 | 0.263 | 0.088 | 0.247 | 0.263 | 0.303 | 0.439 | 4.615 |
| 100 | SET | asmredis | 98,039 | 0.516 | 0.184 | 0.519 | 0.567 | 0.647 | 0.719 | 1.159 |
| 100 | SET | valkey | 99,206 | 0.517 | 0.152 | 0.495 | 0.527 | 0.615 | 0.703 | 1.719 |
| 100 | GET | asmredis | 99,206 | 0.510 | 0.184 | 0.511 | 0.559 | 0.631 | 0.687 | 1.103 |
| 100 | GET | valkey | 99,900 | 0.511 | 0.160 | 0.503 | 0.535 | 0.607 | 0.703 | 2.295 |
| 200 | SET | asmredis | 94,518 | 1.072 | 0.256 | 1.063 | 1.223 | 1.511 | 1.703 | 2.471 |
| 200 | SET | valkey | 92,851 | 1.086 | 0.392 | 1.071 | 1.175 | 1.367 | 1.535 | 2.559 |
| 200 | GET | asmredis | 92,421 | 1.091 | 0.320 | 1.071 | 1.199 | 1.463 | 1.655 | 2.367 |
| 200 | GET | valkey | 93,110 | 1.084 | 0.352 | 1.055 | 1.175 | 1.383 | 1.567 | 2.207 |
| 500 | SET | asmredis | 83,963 | 3.016 | 0.680 | 3.015 | 3.591 | 4.207 | 4.527 | 5.751 |
| 500 | SET | valkey | 89,366 | 2.835 | 0.560 | 2.847 | 3.303 | 3.767 | 4.119 | 5.119 |
| 500 | GET | asmredis | 81,500 | 3.100 | 0.696 | 3.111 | 3.599 | 4.247 | 4.679 | 5.943 |
| 500 | GET | valkey | 88,968 | 2.836 | 0.424 | 2.839 | 3.263 | 3.727 | 4.295 | 5.543 |

**Reading the numbers.** The primary comparison is asmredis-B against the Valkey
oracle **in the same runs**, which cancels the elevated ambient load:

- **`-c 1`: asmredis ~26–33% faster** on throughput (45.5K/45.7K vs 35.4K/36.2K on
  `-d 3`; 46.0K/44.7K vs 34.5K/35.0K on `-d 512`) — the short per-request path
  still wins at one connection. Under this session's load the p50 edge narrowed:
  both servers sit at 0.023 ms p50 (context-switch cost dominates the round trip
  when cores are contended), whereas on the quiet milestone-C box asmredis reached
  0.015 ms. That is a load artifact, not the allocator — the free path isn't even
  exercised in a fresh-key SET workload beyond the first overwrite.
- **`-c 20–100`: dead even**, trading the lead by 1–4% each way (e.g. `-d 3`
  `-c 100` SET: asmredis 99.5K vs valkey 98.0K; `-c 50` SET: asmredis 100.9K vs
  valkey 104.5K). Latency distributions match within a few percent.
- **`-c 200`: asmredis slightly ahead** on throughput (94.8K vs 93.3K SET, 95.5K
  vs 94.0K GET on `-d 3`) with comparable tails.
- **`-c 500`: Valkey ~5–8% ahead** (SET 89.5K vs 84.0K, GET 88.0K vs 83.8K on
  `-d 3`) — the same ordering seen in milestone C, where Valkey led at 500 as well.

**Did the allocator regress the hot path? No.** At every concurrency level the
asmredis-B-vs-oracle gap reproduces the milestone-C-vs-oracle gap (asmredis ~25–30%
ahead at `-c 1`, roughly even in the mid-range, Valkey ~5–8% ahead at `-c 500`).
The **absolute** throughput this session runs ~8–13% below the milestone-C figures,
but **Valkey drops by the same proportion in the identical runs** (e.g. `-c 1` SET
valkey 35.4K here vs 40.6K in milestone C, −13%; asmredis 45.5K vs 50.7K, −10%) —
the signature of a busier desktop (load ≈ 4, `max` tails up to ~17 ms), not of the
O(1) free-list path. The free-list allocator adds only a few non-syscall
instructions to `SET`/`DEL`, and the numbers bear that out: no measurable
throughput regression relative to the oracle.

As in milestone C, `p75` is blank (`–`) on a few very tight low-concurrency rows
where `valkey-benchmark`'s percentile printout collapses the 75% boundary into a
neighbouring latency bucket; there p75 ≈ p50.

## Milestone D (incremental rehashing) — full sweep

Milestone D replaces the fixed 1024-bucket hashtable with an **incremental,
grow-only Redis-style dict**: two tables `ht[0]`/`ht[1]` plus a migration cursor.
The initial table size is **4**, so a bulk 100K-key insert grows the table ~14
times, and because a grow spreads its migration across subsequent operations, a
rehash is **almost always in flight** during the benchmark — every `SET`/`GET`/`DEL`
runs one **O(1) bucket-migration step** (rehinsert one `ht[0]` bucket's chain into
`ht[1]`, advance the cursor) before doing its own work. That step touches no
syscall. The question this sweep answers: **did the per-op rehash step regress
throughput vs milestone B, and does large-keyspace performance hold up?**

**Method.** Identical to the milestone-C/B sweeps:
`valkey-benchmark -t set,get -n 100000 --precision 3`, concurrency
`-c ∈ {1,20,50,100,200,500}`, two payloads (`-d 3`, `-d 512`), each cell the
**per-metric median of 3 runs**. asmredis on port 7777, Valkey 9.1.0 oracle on
7778, same box, loopback; latencies in ms. Environment: **Linux 7.1.3-2-cachyos**
(same kernel as milestone B), Intel i5-8400 (6 cores), single core saturated. The
asmredis binary is now **24,880 bytes** (the two-table dict + migration logic adds
~5 KB over milestone B's 19,424). _Ambient load this session was **moderate** (load
average ≈ 2.5 on 6 cores) — lighter than the milestone-B run (load ≈ 4): the `max`
tails here top out at ~5.6 ms versus B's up-to-17 ms spikes. As before, the
controlled, load-invariant comparison is asmredis-D against the **Valkey oracle
measured in the same runs**, not the cross-session absolute figures._

### Payload `-d 3` (default, 3-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **48,309** | 0.017 | 0.008 | 0.023 | 0.023 | 0.023 | 0.063 | 0.287 |
| 1 | SET | valkey | 38,580 | 0.022 | 0.008 | 0.023 | – | 0.039 | 0.071 | 0.215 |
| 1 | GET | **asmredis** | **48,591** | 0.017 | 0.008 | 0.023 | 0.023 | 0.023 | 0.055 | 0.143 |
| 1 | GET | valkey | 40,306 | 0.022 | 0.008 | 0.023 | – | 0.031 | 0.071 | 0.423 |
| 20 | SET | asmredis | 103,306 | 0.102 | 0.024 | 0.103 | 0.111 | 0.127 | 0.151 | 0.319 |
| 20 | SET | valkey | 106,383 | 0.102 | 0.032 | 0.103 | 0.111 | 0.127 | 0.167 | 0.407 |
| 20 | GET | asmredis | 102,564 | 0.103 | 0.024 | 0.103 | 0.111 | 0.127 | 0.159 | 0.271 |
| 20 | GET | valkey | 103,627 | 0.104 | 0.032 | 0.103 | 0.111 | 0.127 | 0.159 | 0.383 |
| 50 | SET | asmredis | 102,145 | 0.249 | 0.072 | 0.255 | 0.271 | 0.303 | 0.335 | 0.663 |
| 50 | SET | valkey | 105,932 | 0.244 | 0.088 | 0.247 | 0.255 | 0.279 | 0.319 | 0.647 |
| 50 | GET | asmredis | 101,833 | 0.251 | 0.088 | 0.255 | 0.271 | 0.303 | 0.335 | 0.479 |
| 50 | GET | valkey | 105,820 | 0.244 | 0.072 | 0.247 | 0.255 | 0.279 | 0.319 | 0.799 |
| 100 | SET | asmredis | 103,520 | 0.488 | 0.184 | 0.495 | 0.551 | 0.615 | 0.671 | 1.183 |
| 100 | SET | valkey | 104,603 | 0.487 | 0.144 | 0.487 | 0.503 | 0.543 | 0.591 | 1.111 |
| 100 | GET | asmredis | 103,842 | 0.486 | 0.152 | 0.495 | 0.543 | 0.599 | 0.639 | 1.047 |
| 100 | GET | valkey | 105,374 | 0.483 | 0.160 | 0.479 | 0.503 | 0.543 | 0.583 | 0.967 |
| 200 | SET | asmredis | 103,627 | 0.974 | 0.088 | 0.975 | 1.119 | 1.279 | 1.423 | 2.223 |
| 200 | SET | valkey | 101,729 | 0.991 | 0.280 | 0.983 | 1.031 | 1.151 | 1.255 | 2.063 |
| 200 | GET | asmredis | 105,374 | 0.957 | 0.144 | 0.959 | 1.111 | 1.263 | 1.399 | 2.095 |
| 200 | GET | valkey | 100,100 | 1.007 | 0.320 | 1.007 | 1.055 | 1.159 | 1.279 | 1.887 |
| 500 | SET | asmredis | 94,073 | 2.677 | 1.424 | 2.671 | 3.175 | 3.663 | 3.975 | 5.231 |
| 500 | SET | valkey | 98,522 | 2.558 | 1.088 | 2.559 | 2.975 | 3.303 | 3.495 | 4.775 |
| 500 | GET | asmredis | 94,162 | 2.684 | 0.200 | 2.687 | 3.175 | 3.679 | 3.935 | 5.183 |
| 500 | GET | valkey | 99,602 | 2.534 | 1.144 | 2.543 | 2.959 | 3.303 | 3.511 | 4.655 |

### Payload `-d 512` (512-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **48,193** | 0.017 | 0.008 | 0.023 | – | 0.023 | 0.063 | 0.151 |
| 1 | SET | valkey | 38,388 | 0.022 | 0.008 | 0.023 | – | 0.039 | 0.071 | 0.247 |
| 1 | GET | **asmredis** | **47,893** | 0.018 | 0.008 | 0.023 | – | 0.031 | 0.063 | 0.151 |
| 1 | GET | valkey | 39,793 | 0.022 | 0.008 | 0.023 | – | 0.031 | 0.071 | 0.175 |
| 20 | SET | asmredis | 101,523 | 0.104 | 0.032 | 0.103 | 0.119 | 0.135 | 0.159 | 0.287 |
| 20 | SET | valkey | 106,157 | 0.103 | 0.032 | 0.103 | 0.111 | 0.127 | 0.167 | 0.423 |
| 20 | GET | asmredis | 101,317 | 0.104 | 0.016 | 0.103 | 0.119 | 0.127 | 0.159 | 0.303 |
| 20 | GET | valkey | 103,199 | 0.105 | 0.032 | 0.103 | 0.111 | 0.127 | 0.167 | 0.399 |
| 50 | SET | asmredis | 102,459 | 0.249 | 0.080 | 0.255 | 0.271 | 0.295 | 0.335 | 0.615 |
| 50 | SET | valkey | 106,724 | 0.243 | 0.072 | 0.239 | 0.255 | 0.279 | 0.327 | 0.615 |
| 50 | GET | asmredis | 101,317 | 0.252 | 0.072 | 0.255 | 0.271 | 0.295 | 0.335 | 0.447 |
| 50 | GET | valkey | 102,564 | 0.252 | 0.064 | 0.255 | 0.263 | 0.287 | 0.327 | 0.479 |
| 100 | SET | asmredis | 101,420 | 0.498 | 0.096 | 0.503 | 0.551 | 0.623 | 0.679 | 1.295 |
| 100 | SET | valkey | 103,093 | 0.495 | 0.144 | 0.495 | 0.511 | 0.567 | 0.607 | 1.151 |
| 100 | GET | asmredis | 99,701 | 0.507 | 0.176 | 0.511 | 0.551 | 0.607 | 0.663 | 1.047 |
| 100 | GET | valkey | 101,729 | 0.500 | 0.152 | 0.495 | 0.519 | 0.575 | 0.623 | 0.999 |
| 200 | SET | asmredis | 98,135 | 1.029 | 0.160 | 1.023 | 1.183 | 1.423 | 1.575 | 2.495 |
| 200 | SET | valkey | 96,246 | 1.051 | 0.296 | 1.031 | 1.119 | 1.295 | 1.391 | 2.327 |
| 200 | GET | asmredis | 98,912 | 1.019 | 0.144 | 1.015 | 1.151 | 1.399 | 1.535 | 2.063 |
| 200 | GET | valkey | 96,805 | 1.041 | 0.336 | 1.031 | 1.119 | 1.287 | 1.383 | 1.791 |
| 500 | SET | asmredis | 88,731 | 2.847 | 1.104 | 2.847 | 3.391 | 4.023 | 4.335 | 5.575 |
| 500 | SET | valkey | 91,996 | 2.742 | 0.264 | 2.759 | 3.191 | 3.703 | 3.999 | 4.927 |
| 500 | GET | asmredis | 88,183 | 2.864 | 0.200 | 2.863 | 3.391 | 3.975 | 4.295 | 5.407 |
| 500 | GET | valkey | 91,996 | 2.748 | 0.184 | 2.767 | 3.183 | 3.647 | 3.919 | 4.823 |

**Reading the numbers.** The primary comparison is asmredis-D against the Valkey
oracle **in the same runs**, which cancels ambient load:

- **`-c 1`: asmredis ~20–25% faster** on throughput (48.3K/48.6K vs 38.6K/40.3K on
  `-d 3`; 48.2K/47.9K vs 38.4K/39.8K on `-d 512`). p50 sits at 0.023 ms for both
  servers under this session's load — the same context-switch-dominated round trip
  seen in milestone B (the quiet milestone-C box reached 0.015 ms for asmredis).
  The per-op migration step does not show up here: it is one bucket rehash, no
  syscall, dwarfed by the loopback round-trip cost.
- **`-c 20–100`: within ~1–5%**, Valkey edging slightly ahead on throughput (e.g.
  `-d 3` `-c 50` SET: asmredis 102.1K vs valkey 105.9K; `-c 100` SET: 103.5K vs
  104.6K). Latency distributions match within a few percent — the same near-tie the
  earlier milestones showed at these levels.
- **`-c 200`: asmredis slightly ahead** on throughput (103.6K vs 101.7K SET, 105.4K
  vs 100.1K GET on `-d 3`; 98.1K vs 96.2K SET, 98.9K vs 96.8K GET on `-d 512`) with
  comparable or tighter tails. At this point the keyspace has fully rehashed several
  times over and asmredis holds its own.
- **`-c 500`: Valkey ~4–6% ahead** (SET 98.5K vs 94.1K, GET 99.6K vs 94.2K on
  `-d 3`) — the same ordering seen in milestones B and C, where Valkey led at 500.

**Did the per-op rehash step regress the hot path? No.** At every concurrency level
the asmredis-D-vs-oracle gap **reproduces** the milestone-B and milestone-C shape:
asmredis ~20–25% ahead at `-c 1`, roughly even (Valkey a hair ahead) in the
mid-range, Valkey ~5% ahead at `-c 500`. The **absolute** throughput this session
runs **above** the milestone-B figures (e.g. `-c 1` SET `-d 3`: 48.3K vs B's 45.5K,
+6%; `-c 500` SET: 94.1K vs B's 84.0K, +12%) — but **Valkey rises by the same
proportion in the identical runs** (`-c 1` SET 38.6K vs B's 35.4K, +9%; `-c 500`
SET 98.5K vs B's 89.5K, +10%). Both servers moving together upward is the signature
of a **quieter desktop than the milestone-B session** (load ≈ 2.5 vs ≈ 4; `max`
tails ≤ 5.6 ms here vs up to ~17 ms in B), not of any change in the relative cost
of the two implementations. The incremental dict's O(1) migration adds a handful of
non-syscall instructions per op, and the in-run oracle comparison — the load-
invariant measure — shows **no measurable throughput regression**. Large-keyspace
performance holds: even at `-c 500` with the table fully grown, asmredis stays
within ~5% of Valkey.

As in the earlier milestones, `p75` is blank (`–`) on a few very tight
low-concurrency Valkey (and one asmredis `-d 512`) rows where `valkey-benchmark`'s
percentile printout collapses the 75% boundary into a neighbouring latency bucket;
there p75 ≈ p50.

## Milestone E (LIST) — string hot path

Milestone E adds a **LIST type**. The only change to the string `SET`/`GET` path is
tiny: keyspace entries now carry a **type field** (`[40]=type`, entry size 48 vs 40
— both still in the 64-byte size class), and `cmd_get` now goes through **`ks_lookup`**
(rehash-step + find, returning the raw entry) followed by a **one-instruction type
compare**, instead of the old `ks_get`. `cmd_set` is unchanged except it also writes
the type field. The question this sweep answers: **did that regress `SET`/`GET`
throughput?** It is a couple of non-syscall instructions, so the expectation is
"within noise." LIST commands are **not** part of `valkey-benchmark -t set,get`;
their correctness and leak behavior are covered by the `conformance` + `list-stress`
wire tests, not this throughput sweep.

**Method.** Identical to the milestone-C/B/D sweeps:
`valkey-benchmark -t set,get -n 100000 --precision 3`, concurrency
`-c ∈ {1,20,50,100,200,500}`, two payloads (`-d 3`, `-d 512`), each cell the
**per-metric median of 3 runs**. asmredis on port 7777, Valkey 9.1.0 oracle on
7778, same box, loopback; latencies in ms. Environment: **Linux 7.1.3-2-cachyos**
(same kernel as milestones B/D), Intel i5-8400 (6 cores), single core saturated. The
asmredis binary is now **30,112 bytes** (the LIST type, its commands and the
type-field plumbing add ~5 KB over milestone D's 24,880). _Ambient load this session
was **light** (load average ≈ 0.2–1.5 on 6 cores — essentially just the benchmark):
the `max` tails top out at ~5 ms and asmredis reclaims the 0.015 ms `-c 1` p50 last
seen on the quiet milestone-C box. As before, the controlled, load-invariant
comparison is asmredis-E against the **Valkey oracle measured in the same runs**, not
the cross-session absolute figures._

### Payload `-d 3` (default, 3-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **52,274** | 0.014 | 0.008 | 0.015 | 0.023 | 0.023 | 0.031 | 0.199 |
| 1 | SET | valkey | 42,017 | 0.020 | 0.016 | 0.023 | – | 0.023 | 0.031 | 0.175 |
| 1 | GET | **asmredis** | **52,715** | 0.014 | 0.008 | 0.015 | – | 0.023 | 0.031 | 0.271 |
| 1 | GET | valkey | 42,955 | 0.020 | 0.016 | 0.023 | – | 0.023 | 0.039 | 0.263 |
| 20 | SET | asmredis | 104,384 | 0.101 | 0.040 | 0.103 | 0.111 | 0.119 | 0.151 | 0.775 |
| 20 | SET | valkey | 109,529 | 0.098 | 0.032 | 0.103 | – | 0.111 | 0.143 | 0.407 |
| 20 | GET | asmredis | 103,199 | 0.102 | 0.024 | 0.111 | 0.111 | 0.119 | 0.151 | 0.263 |
| 20 | GET | valkey | 106,838 | 0.101 | 0.032 | 0.103 | – | 0.111 | 0.151 | 0.375 |
| 50 | SET | asmredis | 102,987 | 0.247 | 0.088 | 0.247 | 0.271 | 0.295 | 0.327 | 0.591 |
| 50 | SET | valkey | 108,225 | 0.238 | 0.072 | 0.239 | 0.247 | 0.271 | 0.311 | 0.815 |
| 50 | GET | asmredis | 102,987 | 0.248 | 0.072 | 0.255 | 0.263 | 0.287 | 0.327 | 0.447 |
| 50 | GET | valkey | 106,724 | 0.241 | 0.080 | 0.239 | 0.247 | 0.279 | 0.311 | 0.767 |
| 100 | SET | asmredis | 106,724 | 0.473 | 0.128 | 0.479 | 0.527 | 0.591 | 0.631 | 1.023 |
| 100 | SET | valkey | 107,527 | 0.474 | 0.144 | 0.471 | 0.479 | 0.519 | 0.583 | 1.527 |
| 100 | GET | asmredis | 107,181 | 0.471 | 0.160 | 0.479 | 0.527 | 0.591 | 0.639 | 0.855 |
| 100 | GET | valkey | 106,270 | 0.478 | 0.144 | 0.479 | 0.487 | 0.527 | 0.567 | 1.591 |
| 200 | SET | asmredis | 107,527 | 0.938 | 0.240 | 0.967 | 1.063 | 1.183 | 1.247 | 2.055 |
| 200 | SET | valkey | 104,822 | 0.961 | 0.328 | 0.967 | 0.999 | 1.063 | 1.135 | 1.919 |
| 200 | GET | asmredis | 113,766 | 0.883 | 0.064 | 0.887 | 1.047 | 1.175 | 1.271 | 1.943 |
| 200 | GET | valkey | 105,485 | 0.957 | 0.232 | 0.959 | 0.999 | 1.087 | 1.183 | 2.895 |
| 500 | SET | asmredis | 106,270 | 2.361 | 0.672 | 2.359 | 2.807 | 3.191 | 3.615 | 4.951 |
| 500 | SET | valkey | 108,342 | 2.325 | 0.872 | 2.327 | 2.711 | 2.943 | 3.207 | 4.367 |
| 500 | GET | asmredis | 101,626 | 2.472 | 0.680 | 2.455 | 2.751 | 3.015 | 3.279 | 5.055 |
| 500 | GET | valkey | 109,170 | 2.293 | 0.640 | 2.287 | 2.655 | 2.959 | 3.319 | 4.375 |

### Payload `-d 512` (512-byte value) — median of 3

| `-c` | cmd | server | rps | avg | min | p50 | p75 | p95 | p99 | max |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | SET | **asmredis** | **52,770** | 0.014 | 0.008 | 0.015 | – | 0.023 | 0.031 | 0.199 |
| 1 | SET | valkey | 41,806 | 0.020 | 0.016 | 0.023 | – | 0.023 | 0.031 | 0.223 |
| 1 | GET | **asmredis** | **51,867** | 0.015 | 0.008 | 0.015 | 0.023 | 0.023 | 0.031 | 0.351 |
| 1 | GET | valkey | 42,517 | 0.020 | 0.016 | 0.023 | – | 0.023 | 0.031 | 0.295 |
| 20 | SET | asmredis | 104,167 | 0.100 | 0.048 | 0.103 | 0.111 | 0.127 | 0.151 | 0.311 |
| 20 | SET | valkey | 110,011 | 0.097 | 0.032 | 0.095 | 0.103 | 0.111 | 0.143 | 0.367 |
| 20 | GET | asmredis | 100,705 | 0.105 | 0.032 | 0.111 | – | 0.119 | 0.151 | 0.255 |
| 20 | GET | valkey | 107,066 | 0.100 | 0.032 | 0.103 | – | 0.111 | 0.151 | 0.383 |
| 50 | SET | asmredis | 102,145 | 0.250 | 0.072 | 0.255 | 0.263 | 0.287 | 0.327 | 0.583 |
| 50 | SET | valkey | 111,111 | 0.232 | 0.072 | 0.231 | 0.239 | 0.263 | 0.303 | 0.783 |
| 50 | GET | asmredis | 101,215 | 0.252 | 0.072 | 0.255 | 0.271 | 0.295 | 0.327 | 0.503 |
| 50 | GET | valkey | 107,643 | 0.239 | 0.080 | 0.239 | 0.247 | 0.279 | 0.319 | 0.783 |
| 100 | SET | asmredis | 106,838 | 0.472 | 0.128 | 0.479 | 0.527 | 0.575 | 0.623 | 1.023 |
| 100 | SET | valkey | 108,108 | 0.471 | 0.144 | 0.471 | 0.487 | 0.527 | 0.591 | 1.703 |
| 100 | GET | asmredis | 108,460 | 0.465 | 0.216 | 0.471 | 0.535 | 0.591 | 0.639 | 0.847 |
| 100 | GET | valkey | 104,712 | 0.486 | 0.144 | 0.487 | 0.495 | 0.535 | 0.591 | 1.631 |
| 200 | SET | asmredis | 104,712 | 0.961 | 0.312 | 0.975 | 1.031 | 1.135 | 1.231 | 2.031 |
| 200 | SET | valkey | 104,493 | 0.963 | 0.256 | 0.967 | 0.999 | 1.071 | 1.159 | 3.111 |
| 200 | GET | asmredis | 111,235 | 0.904 | 0.128 | 0.911 | 1.031 | 1.151 | 1.231 | 1.855 |
| 200 | GET | valkey | 105,820 | 0.952 | 0.256 | 0.967 | 1.007 | 1.087 | 1.191 | 1.839 |
| 500 | SET | asmredis | 98,135 | 2.567 | 0.784 | 2.559 | 2.735 | 2.975 | 3.519 | 4.975 |
| 500 | SET | valkey | 101,010 | 2.498 | 0.448 | 2.495 | 2.671 | 3.031 | 3.487 | 7.751 |
| 500 | GET | asmredis | 102,354 | 2.456 | 0.944 | 2.511 | 2.751 | 3.063 | 3.495 | 4.863 |
| 500 | GET | valkey | 105,597 | 2.376 | 0.696 | 2.391 | 2.687 | 2.983 | 3.303 | 5.071 |

**Reading the numbers.** The primary comparison is asmredis-E against the Valkey
oracle **in the same runs**, which cancels ambient load:

- **`-c 1`: asmredis ~23–26% faster** on throughput (52.3K/52.7K vs 42.0K/43.0K on
  `-d 3`; 52.8K/51.9K vs 41.8K/42.5K on `-d 512`) and **half the p50** (0.015 vs
  0.023 ms). This session's quiet box reproduces the milestone-C 0.015 ms p50 that
  the busier B/D sessions had masked at 0.023 ms — a load artifact of those runs,
  not a code change. The extra type-field write on `SET` and the type compare on
  `GET` are invisible here: they are dwarfed by the loopback round-trip cost.
- **`-c 20–100`: within ~1–5%**, Valkey edging slightly ahead on throughput (e.g.
  `-d 3` `-c 50` SET: asmredis 103.0K vs valkey 108.2K; `-c 100` SET: 106.7K vs
  107.5K, essentially tied). Latency distributions match within a few percent — the
  same near-tie every earlier milestone showed at these levels.
- **`-c 200`: asmredis ahead** on throughput (107.5K vs 104.8K SET, 113.8K vs 105.5K
  GET on `-d 3`; 104.7K vs 104.5K SET, 111.2K vs 105.8K GET on `-d 512`) with
  comparable or tighter tails.
- **`-c 500`: Valkey ~2–7% ahead** (SET 108.3K vs 106.3K, GET 109.2K vs 101.6K on
  `-d 3`) — the same ordering seen in milestones B/C/D, where Valkey led at 500.

**Did the type field + `ks_lookup`-based `cmd_get` regress the hot path? No.** At
every concurrency level the asmredis-E-vs-oracle gap **reproduces** the milestone-D
shape: asmredis ~20–26% ahead at `-c 1`, roughly even (Valkey a hair ahead) in the
mid-range, Valkey ~2–7% ahead at `-c 500`. The **absolute** throughput this session
runs **above** the milestone-D figures (e.g. `-c 1` SET `-d 3`: 52.3K vs D's 48.3K,
+8%; `-c 500` SET: 106.3K vs D's 94.1K, +13%) — but **Valkey rises by the same
proportion in the identical runs** (`-c 1` SET 42.0K vs D's 38.6K, +9%; `-c 500` SET
108.3K vs D's 98.5K, +10%). Both servers moving together upward is the signature of a
**quieter desktop than the D session** (load ≈ 0.2–1.5 vs ≈ 2.5; `max` tails ≤ 5 ms),
not of the type-field change. The change adds a couple of non-syscall instructions to
`GET` and one field write to `SET`, and the in-run oracle comparison — the load-
invariant measure — shows **no measurable throughput regression**.

As in the earlier milestones, `p75` is blank (`–`) on a few very tight
low-concurrency rows (mostly Valkey, plus a couple of asmredis rows) where
`valkey-benchmark`'s percentile printout collapses the 75% boundary into a
neighbouring latency bucket; there p75 ≈ p50.

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
