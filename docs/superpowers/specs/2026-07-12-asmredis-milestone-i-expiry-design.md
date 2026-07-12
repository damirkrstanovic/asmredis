# Milestone I — Key expiration (TTL) (Design)

Date: 2026-07-12
Status: Approved, ready for planning

## Problem

asmredis has no notion of key expiry — the defining Redis feature. Adding TTLs
requires a time source (none exists yet), a per-key deadline, expired-keys-treated-
as-absent everywhere, and reclamation of expired-but-untouched keys.

## Scope

Seven commands: `EXPIRE`, `PEXPIRE`, `EXPIREAT`, `PEXPIREAT`, `TTL`, `PTTL`,
`PERSIST`. Passive expiration (expired keys are absent and reaped on access) plus a
best-effort active sweep (bounds memory for keys never accessed again). All semantics
byte-exact against valkey (captured live; see "Reference ground truth").

**Out of scope:** `SET EX/PX/EXAT/PXAT/KEEPTTL` options, `EXPIRETIME`/`PEXPIRETIME`,
`EXPIRE` NX/XX/GT/LT flags (Redis 7) — future milestones.

## Reference ground truth (valkey 7799, captured live)

- `EXPIRE k 100` (k exists) → `:1`; `TTL k` → `100`; `PTTL k` → ~`99990` ms.
- `EXPIRE missing 100` → `:0`.
- `TTL` of a key with no TTL → `-1`; of a missing key → `-2`; `PTTL` likewise.
- `PERSIST` with a TTL → `:1`; without a TTL, or missing key → `:0`.
- **Past/zero/negative time deletes the key and returns `:1`:** `EXPIRE k -1`,
  `EXPIRE k 0`, `EXPIREAT k 1`, `PEXPIREAT k 1` all delete `k` (subsequent `GET`→nil,
  `EXISTS`→0, `TYPE`→`none`, `TTL`→`-2`).
- **`TTL` rounds `(remaining_ms + 500) / 1000`:** `PEXPIRE k 2500` → `TTL 2`,
  `PTTL 2492`; `PEXPIRE k 1500` → `TTL 1`.
- **`SET` clears an existing TTL** (`TTL`→`-1` after re-`SET`); **`INCR`, `RPUSH`,
  `HSET` preserve the TTL** (`TTL`→~100 after).
- Errors: non-integer time → `-ERR value is not an integer or out of range`
  (existing `emit_notint`); overflowing time (`EXPIRE k 9999999999999999`) →
  `-ERR invalid expire time in 'expire' command` (**new**, command-name-parameterized);
  arg count → `-ERR wrong number of arguments for '<cmd>' command` (`emit_wrongargs`).

## Architecture

### Time source and cached clock

Add `clock_gettime(CLOCK_REALTIME)` (a new syscall) and a global `g_now_ms` =
`tv_sec*1000 + tv_nsec/1000000`. `g_now_ms` is refreshed **once per epoll-loop
wakeup**, before any event/command is processed. This is load-bearing: it makes the
passive-expiry check (below) a cheap memory compare instead of a syscall on every key
lookup. Mirrors Redis's cached `server.mstime`. Commands within one drain batch see a
single consistent "now" (as in Redis).

### Per-key deadline

Add an 8-byte field at entry offset `[48]` = **absolute CLOCK_REALTIME ms deadline**,
`0` = no TTL. `ENTRY_SZ` grows 48→56, still inside the 64-byte size class — **no
allocation growth**. Free-list memory is not zeroed, so every entry-creation path
(`ks_insert` and `ks_set`'s new-entry branch) must explicitly initialise `[48]=0`.

Entry layout becomes: `[0]next [8]key_ptr [16]key_len [24]val_ptr [32]val_len
[40]type [48]expire_ms`.

### Passive expiration — inside `ks_lookup`

`ks_lookup` gains one check: after locating the entry, if `expire_ms != 0 &&
expire_ms <= g_now_ms`, delete the key (unlink + free) and return "not found." Because
**every read command already routes through `ks_lookup`** (GET/EXISTS/TYPE/INCR/
LLEN/HGET/…, and the new TTL/PERSIST/EXPIRE), they all treat expired keys as absent
with no per-command change. Cost on a live hit: one load of `[48]` + one compare
against the cached `g_now_ms` (no syscall). The reap path (call `ks_del` with the
saved key/len, return 0) runs only when a key is actually expired.

### TTL clear-vs-preserve

`ks_set` **preserves `[48]` on overwrite** (it swaps only the value on the existing
entry) and additionally **returns the entry pointer in `rdx`** (rax stays 0 ok / 1
oom). Consequences, all matching valkey:
- `cmd_set` clears the TTL with one store `mov qword [entry+48], 0` after `ks_set` —
  no extra lookup (SET semantics: a full replacement drops the TTL).
- `INCR`/`DECR`/`INCRBY`/`DECRBY` (which store via `ks_set`) **preserve** the TTL
  because `ks_set` doesn't touch `[48]`; on a *new* key `ks_set` inits `[48]=0`.
- `RPUSH`/`HSET` mutate their header in place via `ks_insert` (new key → `[48]=0`)
  and never touch `[48]`, so they preserve an existing TTL for free.

`ks_set`'s new-return contract has only two callers (`cmd_set`, `_incr_by`);
`_incr_by` ignores `rdx`.

### Active expiration — bounded best-effort sweep

The epoll loop switches from an infinite timeout to a **100 ms tick**. On every
wakeup (event or timeout): refresh `g_now_ms`, then run `active_expire_cycle` — a
bounded sweep that advances a persistent bucket cursor over the main table, visiting
at most K buckets and reaping any entry whose `[48]` is expired. It is **best-effort**:
passive expiration guarantees *correctness*; the sweep only bounds *memory* for keys
never accessed again. Coordination with incremental rehashing is a plan-level detail —
worst case the cursor re-scans or skips a bucket in a cycle, which is harmless (the
next cycle, or an access, catches it). The loop restructures to: `epoll_wait(100ms)` →
if `<0` (EINTR) loop; else refresh clock + active sweep; if `==0` (pure tick) loop;
else process events (which now see the fresh `g_now_ms`).

### Command semantics (valkey-exact)

Shared setter core for the four setters, parameterised by (multiplier ∈ {1000 ms/s,
1 ms}, basetime ∈ {`g_now_ms` relative, `0` absolute}) and the lowercase command name:

1. Parse `when` with `parse_int`. Invalid → `emit_notint`.
2. Seconds variants: if `when > LLONG_MAX/1000` or `when < LLONG_MIN/1000` →
   `emit_invalid_expire`; else `when *= 1000`.
3. If `when > LLONG_MAX - basetime` → `emit_invalid_expire`; else `when += basetime`
   → absolute deadline `dl`.
4. `ks_lookup(key)` (live). Missing → `:0`.
5. `dl <= g_now_ms` → `ks_del(key)`, `:1`. Else `[entry+48] = dl`, `:1`.

- `EXPIRE`/`PEXPIRE`: basetime `g_now_ms`; `EXPIREAT`/`PEXPIREAT`: basetime `0`.
  `EXPIRE`/`EXPIREAT`: multiplier 1000; `PEXPIRE`/`PEXPIREAT`: multiplier 1.
- `TTL`/`PTTL key`: `ks_lookup` (live). Missing → `:-2`; `[48]==0` → `:-1`; else
  `rem = [48] - g_now_ms`; `PTTL` → `:rem`; `TTL` → `:(rem+500)/1000`.
- `PERSIST key`: `ks_lookup` (live). Missing or `[48]==0` → `:0`; else `[48]=0`, `:1`.

Arg counts: setters require argc 3, `TTL`/`PTTL`/`PERSIST` argc 2 → else
`emit_wrongargs` with the lowercase name.

## Error handling

`emit_notint` (bad `when`), `emit_wrongargs` (arity) are reused. New
`emit_invalid_expire(rdi=lowercase name ptr, rsi=len)` appends
`-ERR invalid expire time in '<name>' command\r\n` (same pre/name/post shape as
`emit_wrongargs`). No error path for `TTL`/`PTTL`/`PERSIST` beyond arity.

## Files

- **New `src/expire.asm`:** the 7 commands + shared setter core + shared TTL-query
  core + the `clock_gettime`→`g_now_ms` refresh helper (`time_refresh`).
- **`src/keyspace.asm`:** passive-expiry check in `ks_lookup`; `ks_set` preserves
  `[48]` and returns the entry ptr in `rdx`; init `[48]=0` on entry creation; declare
  `extern g_now_ms`.
- **`src/net.asm`:** finite 100 ms epoll timeout; call `time_refresh` + the active
  sweep on each wakeup; own the `active_expire_cycle` bucket-cursor sweep.
- **`src/dispatch.asm`:** route the 7 commands; add length-8 (`EXPIREAT`) and
  length-9 (`PEXPIREAT`) buckets (`TTL`→len3, `PTTL`→len4, `EXPIRE`→len6,
  `PEXPIRE`/`PERSIST`→len7).
- **`src/errmsg.asm`:** `emit_invalid_expire`.
- **`include/syscalls.inc`:** `ENTRY_SZ` 48→56; `SYS_clock_gettime` (228);
  `CLOCK_REALTIME` (0); active-sweep tunables (tick ms, buckets/cycle).
- **`src/main.asm`:** one initial `time_refresh` before `net_serve` (so `g_now_ms` is
  sane before the first wakeup).

## Staging (for the plan)

1. Time + entry field + `ks_set`/`ks_lookup` changes + the 7 commands + passive
   expiration — a complete, testable feature (expired keys report gone on access).
2. Active sweep + epoll-tick change — the memory-reclaim enhancement, added last so
   the suite is green before and after.

## Testing

New `tests/expire.py` (RESP client, exact bytes): all return values (`:1`/`:0`/`-1`/
`-2`), past/zero/negative deletion, TTL rounding (`PEXPIRE 2500`→`TTL 2`), SET-clears
vs INCR/RPUSH/HSET-preserve, `EXPIREAT`/`PEXPIREAT`, error cases (notint, invalid-
expire-time, arity), and expired-key-absent (`GET`/`EXISTS`/`TYPE` after a past
`PEXPIREAT`). A short **real-time expiry** check (`PEXPIRE k 150`, poll `GET` until nil
within a generous bound) exercises the live cached clock.

**Active expiration is not directly client-observable.** With no `DBSIZE`/memory-
introspection command (out of scope), a client cannot distinguish an actively-reaped
key from a passively-reaped one — a `GET` on a lapsed key returns nil either way and
passively expires it on that very access. So the active sweep is validated by (a) the
final adversarial code review of the bounded cursor logic (coverage, rehash
interaction, no double-free), and (b) a **health/stress proxy**: create many keys with
short TTLs, let them lapse **without** touching them across several active cycles, then
confirm the server stays fully functional (accepts a fresh workload, `no-fd-leak`
stays balanced, full suite green) — indirect evidence the reaper ran without
corrupting state. This limitation is called out honestly rather than faked with a
bogus signal.

Oracle `check` lines added to the `wire.sh` conformance block for the deterministic
(non-timing) cases; timing-sensitive checks live only in `expire.py` with generous
bounds. Both wired into `wire.sh`.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** `[48]` offset and `ENTRY_SZ=56` used identically across
  `ks_insert`/`ks_set`/`ks_lookup`/expiry commands; `g_now_ms` single source of time,
  refreshed once per wakeup; deadline is always absolute ms; `ks_set`'s `rdx`=entry
  contract has exactly two callers. Clear/preserve matrix matches the captured valkey
  behaviour (SET clears; INCR/RPUSH/HSET preserve).
- **Scope:** 7 commands + contained infra; staged into passive-then-active for a
  green checkpoint mid-milestone.
- **Ambiguity:** "expired" means strictly `expire_ms != 0 && expire_ms <= g_now_ms`;
  a deadline exactly equal to now is expired (so `TTL` on a survivor is always ≥ 1 ms
  remaining). Setter deletes when `dl <= g_now_ms`, matching valkey's `EXPIRE 0`→delete.
