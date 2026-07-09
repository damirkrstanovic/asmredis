# Milestone E — LIST data type (Design)

Date: 2026-07-09
Status: Approved, ready for planning

## Problem

asmredis currently stores only strings: every entry's value is a byte buffer
(`val_ptr`/`val_len`), and every command assumes that. To be a useful cache it
needs collection types. This milestone adds the first one — **LIST** — plus the
general machinery every future type needs: a per-entry **type tag**, **WRONGTYPE**
errors, and a type-dispatched value-free path.

## Scope

Implement a doubly-linked LIST with six commands, matching Valkey 9.1.0 byte-for-byte:
`LPUSH`, `RPUSH` (variadic), `LPOP`, `RPOP` (single element), `LRANGE` (negative
indices), `LLEN`. Plus: entry type tagging, WRONGTYPE on every type mismatch, and
type-aware free (so `DEL`/`SET`-over-list frees the whole structure).

Deferred: `LPOP`/`RPOP` count argument; `LINDEX`/`LSET`/`LTRIM`/`LINSERT`;
blocking ops; other types (HASH, SET, ZSET). Those are future milestones.

## Ground truth (captured from Valkey 9.1.0, not recalled)

| Behavior | Valkey reply |
|---|---|
| `LPUSH k a b c` | `:3`; resulting order `c b a` (each value prepended, args left→right) |
| `RPUSH k a b c` | `:3`; order `a b c` |
| `LLEN` existing / missing | `:len` / `:0` |
| `LPOP`/`RPOP` missing key | `$-1` (nil bulk) |
| `LRANGE` missing / fully out-of-range | `*0` (empty array) |
| pop the last element | key is **auto-deleted** (`EXISTS`→`:0`) |
| type mismatch | `-WRONGTYPE Operation against a key holding the wrong kind of value\r\n` (no trailing period) |
| arity error | `-ERR wrong number of arguments for '<cmd>' command\r\n` (existing helper) |
| bad integer index | `-ERR value is not an integer or out of range\r\n` |
| `SET` over a list | replaces it; `TYPE`→`string` (old list freed) |

## Architecture

New file `src/list.asm` holds the list type (command handlers + node/header
primitives + `list_free`). `keyspace.asm` gains the type tag, a type-dispatched
free, and two lower-level accessors so callers can inspect/create typed entries.
`dispatch.asm` routes the six names and makes `cmd_get` WRONGTYPE-aware. Small
additions to `reply.asm`/`errmsg.asm`/`util.asm`/`alloc.asm`.

### Type tagging (keyspace.asm)

Entry layout grows one field:
`[0]=next [8]=key_ptr [16]=key_len [24]=val_ptr [32]=val_len [40]=type`
— 48 bytes, still within the 64-byte size class, so **no extra memory** per entry.
`type`: `0`=string, `1`=list (`STR=0`, `LIST=1`).

`_free_value(rdi=entry)` (internal): reads `[entry+40]`; string → `mem_free(val_ptr,
val_len)`; list → `list_free(val_ptr)` (walks header→nodes freeing each node's
string block, each node struct, then the header). Called by `ks_del` and the
`ks_set` overwrite branch.

### List representation (list.asm)

- **Header** — 24 B (class 32): `[0]=head [8]=tail [16]=length`. `entry.val_ptr`
  points here; `entry.val_len` is unused for lists.
- **Node** — 32 B (class 32): `[0]=prev [8]=next [16]=str_ptr [24]=str_len`. Each
  element's bytes are a distinct `mem_dup`'d copy (args live in the transient read
  buffer).
- Doubly linked → O(1) push/pop at both ends, O(n) range walk.

### Keyspace surface (keyspace.asm)

- `ks_lookup(rdi=key, rsi=len) -> rax=entry|0` — rehash-step + `_find`; returns the
  raw entry so callers can read `type`/`val_ptr`.
- `ks_insert(rdi=key, rsi=len) -> rax=entry|0` — rehash-step + `_maybe_expand` +
  allocate a new entry with the key copied, value fields zeroed, `type=0`, linked
  into the destination table. Caller fills `val_ptr`/`val_len`/`type`. OOM →
  rollback partial allocations, return 0. Assumes the key is absent (caller checks
  via `ks_lookup` first).
- `ks_del(rdi=key, rsi=len) -> rax=0/1` — unchanged signature, now frees via
  `_free_value` (type-aware). Used by `DEL` and by list commands for auto-delete.
- `ks_set` — string `SET` path retained; insert sets `type=0`; overwrite calls
  `_free_value` on the old value first (so `SET` over a list frees the list), then
  stores the new string with `type=0`.

`cmd_get` switches from `ks_get` to `ks_lookup` + a type check (string → bulk,
list → WRONGTYPE, miss → nil). `ks_get` is retired.

### Commands (list.asm)

- `LPUSH`/`RPUSH key v [v…]` — `ks_lookup`; if missing, `ks_insert` + attach a fresh
  empty header (`type=1`); if present and `type!=1` → WRONGTYPE. For each value
  arg left→right: `mem_dup` the bytes, allocate a node, link at head (LPUSH) or
  tail (RPUSH), `length++`. Reply `:length`. **OOM handling**: each value is pushed
  individually; if an allocation fails (`mem_dup` or node), stop and reply `-ERR
  out of memory`. Values pushed earlier in the same call remain (no multi-value
  undo — OOM is a degenerate 64 MB-arena condition); if the key was auto-created
  by this call and *zero* values were pushed, `ks_del` it so no empty list is left
  behind. The failed value's own partial allocation (e.g. a `mem_dup`'d string with
  no node yet) is freed before returning.
- `LPOP`/`RPOP key` — `ks_lookup`; miss → nil; `type!=1` → WRONGTYPE; else unlink
  the head/tail node, `reply_bulk` its string, `mem_free` the string + node,
  `length--`; if `length==0`, `ks_del` the key (auto-delete). 
- `LRANGE key start stop` — `ks_lookup`; miss → `*0`; `type!=1` → WRONGTYPE; parse
  start/stop with signed `parse_int` (bad → `-ERR value is not an integer…`);
  normalize negatives (`idx += length`, clamp to `[0,length-1]`); if `start>stop`
  or `start>=length` → `*0`; else emit `reply_array_header(stop-start+1)` and walk
  from index `start` emitting each node as a bulk.
- `LLEN key` — `ks_lookup`; miss → `:0`; `type!=1` → WRONGTYPE; else `:[header+16]`.

### Supporting additions

- `reply.asm`: `reply_array_header(rdi=n)` → `*<n>\r\n`.
- `errmsg.asm`: `emit_wrongtype` (the exact WRONGTYPE line) and `emit_notint`
  (`-ERR value is not an integer or out of range\r\n`).
- `util.asm`: `parse_int(rdi=ptr, rsi=len) -> rax=value, rdx=ok(1)/bad(0)` — signed
  base-10 with optional leading `-`, rejects empty/non-digit/overflow.
- `alloc.asm`: `mem_dup(rdi=src, rsi=len) -> rax=ptr|0` — `mem_alloc(len)` + copy;
  shared by list.asm (keyspace keeps its existing `_copy_arena`).
- `dispatch.asm`: route the six names (len-4 LPOP/RPOP/LLEN alongside PING/ECHO;
  len-5 LPUSH/RPUSH; len-6 LRANGE) to the `list.asm` handlers; add WRONGTYPE to
  `cmd_get`.

## Error handling / edge cases

- **Auto-create** on push to a missing key; **auto-delete** when a pop empties the
  list — both matched to Valkey.
- **WRONGTYPE** on any command whose key holds the wrong type (`DEL` is exempt — it
  works on any type; `SET` overwrites any type).
- **OOM**: every allocation (`mem_dup`, node, header, entry) is checked; on failure
  the operation rolls back its own partial allocations, leaves the existing list
  intact, and replies `-ERR out of memory`.
- **Arity** via the existing `emit_wrongargs` (lowercase command name).
- **Bad integer** index → `emit_notint`.
- Empty read buffer / value bytes of length 0 are valid list elements (a node with
  `str_len=0`).

## Testing

- **Conformance** — extend the `tests/wire.sh` valkey-oracle diff (`check` helper)
  to cover all six commands plus WRONGTYPE, nil pop, empty/negative LRANGE,
  auto-delete, SET-over-list, arity, and bad-index — every reply byte-identical to
  Valkey 9.1.0.
- **List stress/leak** (`tests/list.py`): build large lists via LPUSH/RPUSH,
  LRANGE-verify order, drain via LPOP/RPOP asserting order and final auto-delete;
  a churn loop (repeated build-then-drain of ~16 KB-worth of elements, many times
  over) proving node/string reclamation doesn't exhaust the 64 MB arena — extends
  the Milestone-B reclamation guarantee to list nodes.
- **Regression**: all existing checks stay green — string SET/GET/DEL, reclamation,
  OOM, rehashing (`rehash-correctness`), concurrency, backpressure. The entry
  type-field change is guarded by the conformance diff.

## Risk note

The riskiest part is the `keyspace.asm` refactor (new `ks_lookup`/`ks_insert`,
type-aware `ks_del`/`ks_set`, the type field) — it touches code hardened in
Milestones B (reclamation) and D (rehashing). It is necessary for type dispatch;
the conformance, reclamation, and `rehash-correctness` tests all guard it, and
everything outside keyspace is additive.
