# Milestone F — HASH data type (Design)

Date: 2026-07-10
Status: Approved, ready for planning

## Problem

asmredis has strings and lists. The next collection type is HASH — a field→value
map. The general type machinery (per-entry type tag, WRONGTYPE, type-dispatched
free) already exists from Milestone E, so HASH is almost entirely additive.

## Scope

Eight commands, byte-identical to Valkey 9.1.0: `HSET` (variadic pairs), `HGET`,
`HDEL` (variadic fields), `HGETALL`, `HLEN`, `HEXISTS`, `HKEYS`, `HVALS`. Plus a
`TYPE_HASH` tag and one `_free_value` branch.

Deferred: `HMGET`, `HINCRBY`/`HINCRBYFLOAT`, `HSETNX`, `HSTRLEN`, `HRANDFIELD`,
field expiration, listpack↔hashtable encoding conversion. Future milestones.

## Ground truth (captured from Valkey 9.1.0, not recalled)

| Behavior | Valkey reply |
|---|---|
| `HSET h f1 a f2 b f3 c` | `:3` (number of NEW fields) |
| `HSET h f1 z f4 d` | `:1` (f1 updated in place; only f4 is new) |
| `HGETALL h` after the above | `f1 z f2 b f3 c f4 d` — **insertion order**, overwrite keeps field position |
| `HGET` field / missing field | value bulk / `$-1` (nil) |
| `HGET`/`HGETALL`/`HKEYS`/`HVALS` on missing key | `$-1` / `*0` / `*0` / `*0` |
| `HLEN` / missing | `:count` / `:0` |
| `HDEL h f2 f3 nope` | `:2` (only fields that existed) |
| delete last field | key **auto-deleted** (`HLEN`→`:0`, `GET`→nil) |
| `HEXISTS` present / absent / missing key | `:1` / `:0` / `:0` |
| `HKEYS h` / `HVALS h` | array of fields / values, insertion order |
| type mismatch (any hash cmd on non-hash, or GET on hash) | `-WRONGTYPE Operation against a key holding the wrong kind of value\r\n` |
| arity (`HSET` odd pairs or none; `HEXISTS`/`HKEYS` wrong argc) | `-ERR wrong number of arguments for '<cmd>' command\r\n` |

The insertion-order + overwrite-in-place behavior mirrors Valkey's small-hash
listpack encoding; matching it requires an **ordered** structure (an unordered
nested dict could not reproduce `HGETALL` order).

## Architecture

New file `src/hash.asm` holds the HASH type (command handlers + pair primitives +
`hash_free`). `keyspace.asm` gains exactly one `_free_value` branch. `dispatch.asm`
routes the eight names. `include/syscalls.inc` gains `TYPE_HASH=2`. No new reply
or error primitives — everything HASH needs already exists from Milestones A–E.

### Type tag (keyspace.asm)

`TYPE_HASH=2` joins `TYPE_STR=0`/`TYPE_LIST=1`. `_free_value` (which already
dispatches string vs list) gains a hash branch:
```
type==TYPE_HASH -> hash_free(val_ptr)   ; walk pairs freeing field+value+node, then header
```
with the same null-guard the list branch has. This is the ONLY keyspace edit.

### Hash representation (hash.asm)

An insertion-ordered singly-linked list of {field,value} pairs:
- **Header** — 24 B (class 32): `[0]=head [8]=tail [16]=count`. `entry.val_ptr`
  points here; `entry.val_len` unused for hashes.
- **Pair node** — 40 B (class 64): `[0]=next [8]=field_ptr [16]=field_len
  [24]=val_ptr [32]=val_len`. Field and value are each a distinct `mem_dup`'d copy
  (args are transient in the read buffer). Singly-linked: HDEL uses the
  `slot=&head` unlink scheme; append uses the tail pointer for O(1) insertion order.

Field ops are O(n) walks (as Valkey's listpack is for small hashes). Acceptable
for a first cut; a later milestone can add listpack↔hashtable conversion.

### Keyspace surface — unchanged

HASH reuses the Milestone-E accessors as-is:
- `ks_lookup(key,len) -> entry|0` — find + inspect `[entry+40]` type.
- `ks_insert(key,len) -> entry|0` — create a typed entry; caller sets
  `val_ptr=header`, `type=TYPE_HASH`.
- `ks_del(key,len)` — type-aware free (now covers hashes via the `_free_value`
  branch); used by `DEL` and by `HDEL` auto-delete.

### Pair primitives (hash.asm)

- `hash_new() -> rax=header|0` — `mem_alloc(24)`, zero head/tail/count.
- `hash_set(rdi=header, rsi=field, rdx=flen, rcx=value, r8=vlen) -> rax`: walk for
  an existing field; if found, alloc-new-value-then-free-old, replace in place,
  return 0 (updated). If not found, dup field+value, alloc node, append at tail,
  `count++`, return 1 (new). On OOM (any alloc), free this op's partial
  allocations and return 2 (leaves the hash unchanged).
- `hash_get(rdi=header, rsi=field, rdx=flen) -> rax=val_ptr, rdx=val_len`;
  `rax=0` if the field is absent (a found value is never null — `mem_dup` is
  non-null even for empty values).
- `hash_del(rdi=header, rsi=field, rdx=flen) -> rax=1 removed / 0 absent` — unlink,
  free field+value+node, `count--`.
- `hash_exists(rdi=header, rsi=field, rdx=flen) -> rax=1/0`.
- `hash_free(rdi=header)` — free each node's field+value+node, then the header.

Iteration for HGETALL/HKEYS/HVALS is done in the handlers (same file, direct node
access), walking head→next.

### Commands (hash.asm handlers)

- `HSET key f v [f v…]` — arity: `argc` even and ≥4 (whole pairs), else
  `emit_wrongargs('hset')`. `ks_lookup`; if missing `ks_insert` + attach an empty
  `hash_new` header (`type=TYPE_HASH`); if present and not a hash → WRONGTYPE. For
  each pair, `hash_set`; accumulate the count of `rax==1` (new) results; `rax==2`
  → OOM handling (below). Reply `:new_count`.
- `HGET key f` — argc 3; miss → nil; WRONGTYPE if not hash; `hash_get` → bulk or nil.
- `HDEL key f [f…]` — argc ≥3; miss → `:0`; WRONGTYPE; per field `hash_del`,
  accumulate removed; if `count==0` afterward, `ks_del` the key; reply `:removed`.
- `HGETALL key` — argc 2; miss → `*0`; WRONGTYPE; `reply_array_header(2*count)`
  then per node emit field bulk + value bulk.
- `HLEN key` — argc 2; miss → `:0`; WRONGTYPE; `:count`.
- `HEXISTS key f` — argc 3; miss → `:0`; WRONGTYPE; `hash_exists` → `:0/:1`.
- `HKEYS key` — argc 2; miss → `*0`; WRONGTYPE; `reply_array_header(count)` + each
  field bulk.
- `HVALS key` — argc 2; miss → `*0`; WRONGTYPE; `reply_array_header(count)` + each
  value bulk.

### Dispatch routing

Command-name lengths: `HGET`/`HSET`/`HDEL`/`HLEN` (4), `HKEYS`/`HVALS` (5),
`HGETALL`/`HEXISTS` (7). Route len-4 alongside PING/ECHO/LPOP/RPOP/LLEN; len-5
alongside LPUSH/RPUSH; add a **new len-7** arm for HGETALL/HEXISTS. `cmd_upper` is
16 bytes, so 7-char names fit (argv0 > 16 is already rejected before the copy).

## Error handling / edge cases

- Auto-create on `HSET` to a missing key; auto-delete when `HDEL` empties the hash.
- **OOM**: every allocation checked; on failure roll back that op's partial
  allocations, leave the existing hash intact, reply `-ERR out of memory`. If
  `HSET` auto-created the key and added zero fields before failing, `ks_del` it so
  no empty hash persists. (The `_free_value` string/list/hash null-guards keep the
  rollback `ks_del` safe on an entry whose value is not yet populated.)
- **WRONGTYPE** on any hash command whose key holds a non-hash value; `DEL`/`SET`
  remain type-agnostic (SET over a hash frees it via `_free_value`).
- **Arity** via `emit_wrongargs`; **HSET odd pairs** is an arity error.
- Empty-string fields and values are valid (`mem_dup` of length 0 → non-null).

## Testing

- **Conformance** — extend the `tests/wire.sh` Valkey-oracle diff to all eight
  commands + WRONGTYPE + auto-delete (via `GET`→nil, not WRONGTYPE) + arity +
  missing/empty, using **small hashes** (well under Valkey's 128-field / 64-byte
  listpack thresholds) so Valkey stays in insertion-ordered listpack mode and
  `HGETALL`/`HKEYS`/`HVALS` match byte-for-byte.
- **Stress/leak** (`tests/hash.py`): build a large hash via `HSET`, `HGET`-verify
  every field (order-independent), check `HGETALL`/`HKEYS`/`HVALS` shapes and
  `HLEN`, `HDEL`-drain asserting auto-delete (post-drain `GET` → nil, not
  WRONGTYPE), and a churn loop whose cumulative allocation exceeds the 64 MB arena
  (like `list.py`) to prove field/value/node reclamation.
- **Regression**: all existing checks stay green — string SET/GET/DEL, the six
  LIST commands, reclamation, rehashing (`rehash-correctness`), concurrency,
  backpressure. The `_free_value` hash branch is guarded by conformance.

## Reuse note

This milestone is deliberately thin: the Milestone-E type refactor (type tag,
`ks_lookup`/`ks_insert`, type-aware `ks_del`/`_free_value`, WRONGTYPE, the array
reply builder) does the heavy lifting. HASH adds one new file, one keyspace
branch, and dispatch routing — validating that the type machinery generalizes.
