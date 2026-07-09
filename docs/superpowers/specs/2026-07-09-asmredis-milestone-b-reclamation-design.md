# Milestone B — Sub-project #1: Memory Reclamation (Design)

Date: 2026-07-09
Status: Approved, ready for planning

## Problem

The keyspace currently allocates from a bump-only arena (`arena_alloc`) and
**never frees**:

- `ks_del` unlinks an entry from its chain but leaks the entry (40 B), the key,
  and the value blocks.
- `ks_set` overwrite copies the new value into a fresh block and leaks the old
  value block.
- `cmd_set` ignores `ks_set`'s OOM return (`rax==1`) and always replies `+OK`,
  even when the arena is exhausted and nothing was stored.

Consequence: any churning workload (repeated DEL, or repeated overwrite of the
same key) monotonically consumes the 64 MB arena until exhaustion, after which
SETs silently no-op while still replying `+OK`.

## Scope

In scope:
1. Add a reclaiming allocator (segregated power-of-two free lists) on top of the
   existing bump arena.
2. Wire `ks_del` and `ks_set`-overwrite to actually free reclaimed blocks.
3. Make `cmd_set` reply an OOM error when `ks_set` returns 1.

Deferred (not this sub-project): hashtable rehashing, new commands
(EXISTS/INCR/EXPIRE/TTL), inline command protocol, cross-class coalescing.

## Architecture

Two files change; module boundaries stay clean.

- **`src/alloc.asm`** — gains the free-list allocator. The bump arena remains the
  *backing store*. New public API:
  - `mem_alloc(rdi=size) -> rax=ptr` (0 on OOM)
  - `mem_free(rdi=ptr, rsi=size)`
  `arena_alloc` becomes an internal primitive used to carve fresh blocks when a
  size-class free list is empty. `arena_init` unchanged.
- **`src/keyspace.asm`** — switches key/value/entry allocation from
  `arena_alloc` to `mem_alloc`; adds `mem_free` on DEL and SET-overwrite.
- **`src/dispatch.asm`** — `cmd_set` checks `ks_set`'s return and replies an OOM
  error instead of `+OK` when it is 1.

`parser`, `reply`, `net`, `util`, `main` are untouched.

## Allocator: segregated free lists

- **12 size classes**, powers of two `8, 16, 32, 64, 128, 256, 512, 1024, 2048,
  4096, 8192, 16384` (2^3 .. 2^14). Everything fits: values/keys are capped at
  ~16 KB by the parser (bulk length <= READ_BUF_SIZE=16384); entries are 40 B ->
  the 64 B class. Sizes never exceed the top class.
- **Free-list heads**: a BSS array of 12 qwords (`free_lists`), zero-init. Each
  list is a LIFO singly-linked stack. The "next" pointer is stored **inside** the
  freed block (intrusive) — the minimum class is 8 B, exactly enough to hold a
  pointer. Zero per-block metadata.
- **Class rounding** (`size -> class`): round `size` up to the next power of two,
  clamped to a minimum of 8. Computed with `bsr` (bit-scan reverse). Class index
  = log2(class_size) - 3. Deterministic: alloc and free round the *same* size to
  the *same* class, and the keyspace always frees a block with the same length it
  allocated, so a block never lands in the wrong class.

### `mem_alloc(rdi=size) -> rax=ptr`
1. Round `size` up to class `C` (class size + index).
2. If `free_lists[idx]` is non-empty: pop the head (load `[head]` as new head),
   return the popped block.
3. Else `arena_alloc(C)` — carve a fresh `C`-byte block from the bump arena.
4. Return 0 only if the list is empty **and** the arena is exhausted.

Blocks in a class are always exactly `C` bytes.

### `mem_free(rdi=ptr, rsi=size)`
1. Round `size` up to class `C` (index).
2. Push `ptr` onto `free_lists[idx]`: `[ptr] = free_lists[idx]; free_lists[idx] = ptr`.
O(1), no syscalls.

## Keyspace wiring

Entry layout (unchanged): `[0]=next [8]=key_ptr [16]=key_len [24]=val_ptr [32]=val_len`.

- **`ks_del`**: after unlinking the entry from its bucket chain, free all three
  blocks: `mem_free(val_ptr, val_len)`, `mem_free(key_ptr, key_len)`,
  `mem_free(entry, 40)`. (Free after the unlink so the chain is never walked into
  a freed/reused block.)
- **`ks_set` overwrite** (key exists): **allocate the new value block first** via
  `mem_alloc`. If it succeeds, copy the new value in, `mem_free` the old value
  block, then point the entry at the new block and update `val_len`. If the new
  alloc fails (OOM), leave the old value fully intact and return 1 — never corrupt
  a live key.
- **`ks_set` insert** (new key): allocate key + value + entry via `mem_alloc`,
  same order as today. On any OOM mid-way, `mem_free` whatever was already
  allocated in this call and return 1. The entry is linked into the chain only
  after all three allocations succeed (as today), so a failed insert leaves the
  table unchanged.

## `SET` OOM semantics

`ks_set` returns `rax=1` on OOM. `cmd_set` currently ignores it. Fix: when
`ks_set` returns 1, reply `-ERR out of memory\r\n` and store nothing.

Rationale for the string: Valkey's OOM reply (`-OOM command not allowed when used
memory > 'maxmemory'.`) references a `maxmemory` policy we do not implement — our
OOM is arena exhaustion, a distinct mechanism. A plain honest `-ERR out of
memory` is clearer and does not falsely imply maxmemory semantics.

## Edge cases / limitations

- **Cross-class fragmentation**: freed blocks stay in their own class; there is no
  coalescing. A freed 16 B block cannot satisfy a 512 B request. So OOM can occur
  with reusable memory stranded in other classes. Acceptable for a first
  reclamation cut; documented. Same-size churn (the common cache pattern) reuses
  perfectly.
- **OOM now means**: the requested class list is empty **and** the bump arena is
  exhausted — a real, rare condition, not the per-operation leak we have today.
- **Sizes > 16384**: unreachable (parser cap + 40 B entries). No handling needed
  beyond the top class covering it.

## Testing

Black-box wire tests, deterministic:

1. **Reclamation via overwrite (the key proof)**: overwrite one key with a
   ~16 KB value **N = 10,000 times** (~160 MB of total allocation through a 64 MB
   arena), each write with distinct content; then `GET` and assert it equals the
   *last* written value.
   - Without reclamation (current build): arena fills after ~4 K iterations;
     further SETs either return the new OOM error or store nothing -> final GET
     mismatches -> FAIL.
   - With reclamation: every overwrite reuses the freed block -> no OOM, final GET
     matches -> PASS.
2. **Reclamation via DEL**: loop `SET k <16KB>` then `DEL k` 10,000 times,
   asserting no OOM error on any SET — exercises the DEL free path.
3. **Regression**: all 21 existing `tests/wire.sh` checks must still pass (the
   chain/collision test guards free+realloc integrity).

## Benchmark

After green, re-run the full sweep (median-of-3, `-c 1..500`, `-d 3` and
`-d 512`, asmredis vs Valkey 9.1.0) and append a "Milestone B (reclamation)"
section to `docs/benchmark.md`, confirming the alloc/free path did not regress
throughput.
