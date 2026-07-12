# Milestone L — More string ops (Design)

Date: 2026-07-13
Status: Approved, ready for planning

## Scope

`SETNX`, `GETSET`, `APPEND`, `STRLEN`, `MSET`, `MGET`. All in `src/string.asm`.

**Out of scope:** `SETEX`/`PSETEX`, `SETRANGE`/`GETRANGE`, `GETDEL`, `INCRBYFLOAT`.

## Reference ground truth (valkey, captured live)

- `SETNX k v` new → `:1`; on existing key → `:0`, no change.
- `GETSET k new` → old value (bulk); `GET`→new. Missing key → `$-1`. Old value a
  non-string → WRONGTYPE. Clears the TTL (SET semantics).
- `APPEND a hello` (new) → `:5`; `APPEND a world` → `:10`; value becomes `helloworld`.
  **Preserves the TTL.** `APPEND` on a non-string → WRONGTYPE.
- `STRLEN s` → `:len`; missing → `:0`; non-string → WRONGTYPE.
- `MSET a 1 b 2 c 3` → `+OK`; odd number of key/value args → wrongargs.
- `MGET a b nope L` → `[1, 2, nil, nil]` — **nil for both missing and non-string keys;
  MGET never errors on type.**
- Arity: SETNX/GETSET/APPEND need 3, STRLEN 2, MGET ≥ 2, MSET ≥ 3 and odd argc.

## Architecture (all in `src/string.asm`)

- `cmd_setnx` (argc 3): `ks_lookup`; present → `:0`; absent → `ks_set(keepttl=0)` → `:1`
  (oom → `emit_oom`).
- `cmd_getset` (argc 3): `ks_lookup`; non-string → WRONGTYPE; reply the old value
  (`reply_bulk` — it copies the bytes into the output buffer **before** `ks_set` frees
  the old value) or `reply_null` if missing; then `ks_set(new, keepttl=0)`. (On the
  rare OOM the old value is preserved by `ks_set`'s overwrite path and the reply is
  already the old value — an accepted extreme-edge imperfection vs Redis's error.)
- `cmd_append` (argc 3): `ks_lookup`; missing → `ks_set(keepttl=0)`, reply `:vallen`;
  non-string → WRONGTYPE; existing string → `mem_alloc(oldlen+vallen)`, copy old then
  appended bytes, `mem_free` old, set `[entry+24]/[entry+32]` (leaving `[48]` TTL
  untouched), reply `:newlen` (alloc failure → `emit_oom`, old value intact).
- `cmd_strlen` (argc 2): `ks_lookup`; missing → `:0`; non-string → WRONGTYPE; else
  `:[entry+32]`.
- `cmd_mset` (argc odd ≥ 3): loop key/value pairs, `ks_set(keepttl=0)` each; reply
  `+OK`. Even or < 3 argc → wrongargs.
- `cmd_mget` (argc ≥ 2): `reply_array_header(argc-1)`; each key `ks_lookup` → `reply_bulk`
  if `TYPE_STR` else `reply_null` (missing or wrong-type).

New externs in `string.asm`: `mem_alloc`, `mem_free`, `reply_bulk`, `reply_int`,
`reply_array_header`, `emit_wrongtype`.

## Files

- `src/string.asm`: the 6 routines + `lc_*` rodata + new externs.
- `src/dispatch.asm`: `extern` the 6; route MSET/MGET (len4), SETNX (len5),
  GETSET/APPEND/STRLEN (len6).
- New `tests/strops.py`.

## Error handling

Reuse `emit_wrongtype`, `emit_wrongargs` (lowercase names), `emit_oom`. No new strings.

## Testing

`tests/strops.py` (exact bytes): SETNX new/blocked, GETSET old/nil/wrongtype, APPEND
create/append/TTL-preserve/wrongtype, STRLEN/missing/wrongtype, MSET + odd-args error,
MGET mixed present/missing/wrongtype nils, arity. Oracle `check` lines in the `wire.sh`
conformance block. Wired into `wire.sh`.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** GETSET/APPEND/STRLEN check `[entry+40]==TYPE_STR` for WRONGTYPE;
  APPEND preserves `[48]` (in-place value swap); GETSET/SETNX/MSET clear TTL via
  `ks_set(keepttl=0)`; MGET returns nil (not error) for missing/wrong-type. MSET arity
  requires odd argc ≥ 3.
- **Scope:** 6 commands in the existing `string.asm`; single plan.
- **Ambiguity:** GETSET on OOM keeps the old value and returns it (documented edge);
  APPEND `oldlen+vallen` may be 0 (empty) → `mem_alloc(0)` gives a valid block.
