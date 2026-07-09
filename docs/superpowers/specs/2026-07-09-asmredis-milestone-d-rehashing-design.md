# Milestone D — Incremental Hashtable Rehashing (Design)

Date: 2026-07-09
Status: Approved, ready for planning

## Problem

The keyspace uses a **fixed 1024-bucket** separately-chained hashtable
(`buckets: resq NBUCKETS` in `main.asm`, masked with `BUCKET_MASK=1023` in
`_bucket_index`). There is no entry count and no resize. As the keyspace grows
past ~1024 keys, chains lengthen without bound and every `GET`/`SET`/`DEL`
degrades from O(1) toward O(n/1024) and beyond. A cache that holds 100 K+ keys
walks ~100-deep chains on every lookup.

## Scope

Add **incremental, grow-only** rehashing (Redis `dict` style): two hash tables
with a gradual migration cursor, so the table doubles as load rises without ever
pausing the event loop for an O(n) bulk rehash.

In scope:
1. Replace the static bucket array with a two-table dict (`ht0`/`ht1`) plus a
   `rehashidx` cursor and per-table entry counts.
2. Grow trigger at load factor 1; migrate one bucket per keyspace operation.
3. Make `ks_get`/`ks_set`/`ks_del` consult both tables while a rehash is in
   flight, and route new keys to the destination table.
4. `mmap`/`munmap` wrappers for bucket-array storage (separate from the value
   arena).

Deferred (not this milestone): shrinking on delete; storing a precomputed hash
in the entry; new commands; changing the entry layout.

## Decisions (locked)

- **Incremental** rehashing (not stop-the-world) — keeps tail latency flat.
- **Grow-only** — expand at load factor 1, never shrink.
- **Initial table size 4** (Redis `DICT_HT_INITIAL_SIZE`) — small on purpose, so
  rehashing is exercised heavily under any real load.

## Architecture

Two files change plus the include:

- **`src/keyspace.asm`** — the dict state, `ks_init`, `_rehash_step`, the expand
  trigger, and rewritten `ks_get`/`ks_set`/`ks_del`/`_find`. Bucket indexing
  becomes per-table (`hash & ht_mask[i]`).
- **`src/alloc.asm`** — add `table_alloc`/`table_free` (`mmap`/`munmap` of bucket
  arrays). The free-list value allocator (`mem_alloc`/`mem_free`) is untouched.
- **`src/main.asm`** — drop the static `buckets` array; call `ks_init` at startup.
- **`include/syscalls.inc`** — add `SYS_munmap` (11), `DICT_INITIAL` (4),
  `REHASH_MAX_EMPTY` (10); the old `NBUCKETS`/`BUCKET_MASK` become unused.

`parser`/`dispatch`/`reply`/`net`/`util` are untouched — rehashing is invisible
on the wire.

## State (BSS globals, in keyspace.asm)

Two `dictht`-equivalent tables held as index-`[0]`/`[1]` arrays so the
finish-swap is a small field copy:

```
ht_table:  resq 2   ; bucket-array pointer per table (0 when unused)
ht_size:   resq 2   ; nbuckets (power of two)
ht_mask:   resq 2   ; nbuckets - 1
ht_used:   resq 2   ; live entry count in this table
rehashidx: resq 1   ; -1 = not rehashing; else next ht0 bucket index to migrate
```

Total live entries = `ht_used[0] + ht_used[1]`. Bucket arrays are dedicated
`mmap`s (zeroed by `MAP_ANONYMOUS` → all heads null), **separate from the 64 MB
value arena** — a table larger than 2048 buckets (16384 B) exceeds `mem_alloc`'s
top size class, so bucket storage cannot come from the value allocator.

Entry layout is **unchanged**: 40 B, `[0]=next [8]=key_ptr [16]=key_len
[24]=val_ptr [32]=val_len`. Entries store no hash; migration recomputes FNV-1a.

## Lifecycle

### `ks_init` (called from `_start`, after `arena_init`, before `net_serve`)
`table_alloc(DICT_INITIAL)` → `ht_table[0]`; `ht_size[0]=4`, `ht_mask[0]=3`,
`ht_used[0]=0`; zero all of ht1; `rehashidx=-1`. If the initial `table_alloc`
fails, `exit(1)` (cannot serve without a table) — mirrors `arena_init`.

### Expand trigger (`_maybe_expand`, checked before a new-key insert)
If `rehashidx == -1` **and** `ht_used[0] >= ht_size[0]` (load factor 1):
`table_alloc(2 * ht_size[0])`. On success set `ht_table[1]`, `ht_size[1]`,
`ht_mask[1]`, `ht_used[1]=0`, `rehashidx=0`. On **allocation failure, do
nothing** — keep serving from ht0 at load factor >1 (graceful degradation, never
a crash or error).

### Migration step (`_rehash_step`, run once at the start of every op)
If `rehashidx < 0`, return immediately. Otherwise:
1. Skip empty ht0 buckets, advancing `rehashidx`, up to `REHASH_MAX_EMPTY` (10)
   skips; if the cap is hit without finding a full bucket, return (resume next
   op). If `rehashidx` reaches `ht_size[0]` while skipping, finish (below).
2. Migrate the one non-empty bucket at `rehashidx`: for each entry in its chain,
   recompute `h = fnv1a(key, key_len)`, compute `idx1 = h & ht_mask[1]`, prepend
   the entry to `ht_table[1][idx1]`, `ht_used[0]--`, `ht_used[1]++`.
3. Set `ht_table[0][rehashidx] = 0`, `rehashidx++`.
4. If `rehashidx >= ht_size[0]`, **finish**.

### Finish/swap
`table_free(ht_table[0], ht_size[0])`; copy ht1 fields into ht0
(`ht_table[0]=ht_table[1]`, size/mask/used likewise); zero all ht1 fields;
`rehashidx = -1`.

## Operation changes (keyspace.asm)

A shared helper `_find(key,len) -> entry|0` computes the hash once and searches
ht0's chain, then (if `rehashidx != -1`) ht1's chain.

- **`ks_get`**: `_rehash_step`; `_find`; return val_ptr/val_len or miss. (Running
  a step on reads keeps migration progressing under read-heavy load.)
- **`ks_set`**: `_rehash_step`; `_find`.
  - Hit → overwrite path unchanged from milestone B (alloc new value, free old,
    repoint; OOM leaves the live value intact).
  - Miss (new key) → `_maybe_expand`; choose target table (`ht1` if
    `rehashidx != -1`, else `ht0`); `_copy_arena` key+value, `mem_alloc(40)`
    entry (with milestone-B partial-rollback on OOM); prepend to
    `ht_table[target][h & ht_mask[target]]`; `ht_used[target]++`. Returns 1 on
    OOM (unchanged contract; `cmd_set` already replies `-ERR out of memory`).
- **`ks_del`**: `_rehash_step`; search ht0's chain (clean `slot=&head` unlink);
  on match free the 3 blocks (milestone B), `ht_used[0]--`, return 1. If not
  found and `rehashidx != -1`, repeat in ht1 (`ht_used[1]--`). Else return 0.

Invariant: new keys go only to the destination table and migration moves only
ht0→ht1, so during a resize every key lives in exactly one table and is never
visited twice or dropped.

## Allocator additions (alloc.asm)

The value allocator is unchanged. Add:

- `table_alloc(rdi=nbuckets) -> rax=ptr or 0` — `mmap(nbuckets*8, PROT_RW,
  MAP_ANON_PRIV)`; return 0 on the mmap error range (caller decides: fatal at
  init, graceful-skip on grow).
- `table_free(rdi=ptr, rsi=nbuckets)` — `munmap(ptr, nbuckets*8)`.

`SYS_munmap = 11` added to `syscalls.inc`. Bucket arrays round up to a page each
(a 4 KB minimum for tiny tables); at most two tables are live at once, so the
overhead is bounded and dwarfed by real tables.

## Edge cases / limitations

- **OOM on grow** → skip the expansion, serve from ht0 at LF>1. No error, no
  crash.
- **OOM on initial table** (`ks_init`) → `exit(1)`.
- **Hash recompute** during migration is intentional (no stored hash; +8 B/entry
  avoided).
- **Grow-only**: an emptied large table keeps its bucket array (bounded waste;
  entries themselves are freed normally via milestone-B reclamation).
- **Bounded per-op work**: one bucket splice plus ≤10 empty-bucket skips → O(1)
  amortized; no single op does an O(n) rehash.

## Testing

- **Protocol transparency is guarded by the existing valkey conformance diff** in
  `tests/wire.sh` — SET/GET/DEL replies must stay byte-identical to Valkey 9.1.0.
- **New correctness test** `tests/rehash.py` (wired into `wire.sh` as
  `rehash-correctness`): with `DICT_INITIAL=4`, SET **50,000 distinct keys**
  (forcing ~13 incremental expansions), GET all 50 K back and verify each value;
  then, interleaved, DEL half the keys while SETting new ones (exercising
  lookup + delete across both tables mid-rehash); finally GET-verify every
  surviving key returns its value and every deleted key misses. This proves no
  key is lost, duplicated, or misrouted across resizes.
- **Regression**: all existing `wire.sh` checks (chain, reclaim-overwrite/del,
  oom-error, conformance, concurrency, backpressure, no-fd-leak) still pass.
- **Benchmark confirmation**: re-run the sweep (median-of-3, `-c 1..500`,
  `-d 3`/`-d 512`, asmredis vs Valkey) and append a "Milestone D (rehashing)"
  section to `docs/benchmark.md`, confirming the per-op rehash step did not
  regress throughput and that large-keyspace lookups no longer degrade.
