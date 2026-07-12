# Milestone H — Integer counters + EXISTS/TYPE (Design)

Date: 2026-07-12
Status: Approved, ready for planning

## Problem

asmredis implements the string/list/hash CRUD core but none of the generic-key or
atomic-counter commands that make a store recognizably Redis. The two most
conspicuous cheap wins are the integer counter family (`INCR`/`DECR`/`INCRBY`/
`DECRBY`) and the generic key introspection commands `EXISTS` and `TYPE`.

Two latent infrastructure gaps block correct counters:

- **`reply_int` is unsigned.** It formats via `_put_uint` (`itoa_u`), so a negative
  integer reply (e.g. `DECR` of a fresh key → `-1`) would be emitted as
  `:18446744073709551615\r\n`. No current caller (`DEL`, list/hash lengths) passes a
  negative, so the bug is latent; counters are the first signed consumer.
- **`parse_int` rejects `LLONG_MIN`.** It parses magnitude as a positive int64
  (max `2^63-1`) then negates, so `-9223372036854775808` is reported invalid.
  valkey stores and re-parses the full `[LLONG_MIN, LLONG_MAX]` range (verified),
  so counters that reach `LLONG_MIN` must round-trip it.

## Reference ground truth (valkey 7799, empirically captured)

All behavior below was captured from a live `valkey-server`, not recalled:

- `INCR` at `INT64_MAX` → `-ERR increment or decrement would overflow` (raw-verified bytes).
- `DECRBY key -9223372036854775808` (arg == `LLONG_MIN`, un-negatable) → a **distinct**
  message: `-ERR decrement would overflow`.
- Non-integer stored value **and** a non-integer increment argument both →
  `-ERR value is not an integer or out of range` (matches existing `emit_notint`).
- `DECR` of a missing key → `-1`. `DECRBY m -3` on `m=10` → `13` (subtracts the arg).
- Full-range round-trip: `set g -9223372036854775807; DECR g` → `-9223372036854775808`
  (stored), then `INCR g` → `-9223372036854775807`.
- `INCR` on a list key → `-WRONGTYPE Operation against a key holding the wrong kind of value`.
- Wrong arg count → `-ERR wrong number of arguments for 'incr' command` (lowercase name).
- `TYPE` → `+string` / `+list` / `+hash` / `+none` (raw-verified `+none\r\n`).
- `EXISTS e1 e2 e3 e1` with `e3` missing → `3` (each argument counted, duplicates
  counted, missing skipped).

## Scope

Add six commands: `INCR`, `DECR`, `INCRBY`, `DECRBY`, `EXISTS key [key ...]`,
`TYPE key`. Make the supporting integer infrastructure fully int64-faithful.

**Out of scope:** `INCRBYFLOAT` and any float parse/format infrastructure (its own
future milestone); `SETNX`/`GETSET`/other string ops; expiry/TTL.

## Architecture

The counter commands are string-type operations built on the existing keyspace API
(`ks_lookup`, `ks_set`); `EXISTS`/`TYPE` are generic key commands alongside `DEL`.
The design mirrors valkey's own command structure so error bytes match exactly.

### Counter core — `src/counter.asm` (new file)

A shared `_incr_by(rdi = signed increment)` does the arithmetic path:

1. `ks_lookup(key)`. If the entry exists and `[entry+40] != TYPE_STR` → `emit_wrongtype`.
2. Parse the current value with `parse_int` (treat a missing key as `0`). Invalid →
   `emit_notint`.
3. `new = current + incr`, detecting signed overflow via the CPU `OF` flag (`add … ; jo`)
   → `emit_incrdecr_ovf` ("increment or decrement would overflow").
4. Format `new` once with `itoa_s` into a stack buffer; `ks_set(key, buf)`. On arena
   exhaustion (`ks_set` → 1) → `emit_oom`.
5. Reply `:<new>\r\n` via the now-signed `reply_int`.

The four commands are thin wrappers that compute `incr` and tail into `_incr_by`:

- `INCR key` (argc 2) → `incr = +1`
- `DECR key` (argc 2) → `incr = -1`
- `INCRBY key n` (argc 3) → `incr = parse_int(n)`; invalid → `emit_notint`
- `DECRBY key n` (argc 3) → `d = parse_int(n)`; invalid → `emit_notint`; **if
  `d == LLONG_MIN` → `emit_decr_ovf`** ("decrement would overflow", the un-negatable
  guard); else `incr = -d`

This is add-only in the core; the only negation is `-d` in `DECRBY` (and the
constant `-1` in `DECR`), and the sole value that cannot be negated (`LLONG_MIN`) is
guarded before the core. That reproduces both of valkey's distinct overflow messages
without a second arithmetic path. Wrong arg count in any wrapper → `emit_wrongargs`
with the command's lowercase name (matching the `lc_set`/`lc_get` pattern).

### Generic commands — added to `src/dispatch.asm` (next to `DEL`)

- `cmd_exists` (argc ≥ 2): loop `argv[1..argc-1]`, `ks_lookup` each, increment a
  counter for every non-null result (duplicates counted because each argument is
  looked up independently), then `reply_int(count)`. `ks_lookup` advances the
  incremental rehash once per call, which is harmless.
- `cmd_type` (argc 2): `ks_lookup`; on miss `reply_simple "none"`; else switch
  `[entry+40]`: `TYPE_STR`→`"string"`, `TYPE_LIST`→`"list"`, `TYPE_HASH`→`"hash"`.
  `TYPE` never returns `WRONGTYPE` — it is the type-introspection command.

### Supporting infrastructure

- **`src/util.asm`**:
  - Rewrite `parse_int` to accumulate magnitude as **unsigned** with a final
    range check, accepting `[LLONG_MIN, LLONG_MAX]`: reject on non-digit/empty/`-`
    alone, reject if the unsigned magnitude overflows or exceeds `2^63` (negative)
    / `2^63-1` (non-negative); value = `magnitude` or `-magnitude` (the latter
    yields `LLONG_MIN` for magnitude `2^63`). Same signature/return contract
    (`rax=value, rdx=1 valid / 0 invalid`), so existing callers are unaffected.
  - Add `itoa_s(rdi = signed value, rsi = out buf ≥ 21) -> rax = length`: emit `-`
    for negatives, then the unsigned magnitude via the existing `itoa_u` logic
    (`LLONG_MIN`'s magnitude via unsigned negation = `2^63`, which `itoa_u` prints
    correctly).
- **`src/reply.asm`**: make `reply_int` signed — emit `:`, then `-` and the unsigned
  magnitude when the value is negative, else the magnitude. `reply_bulk`'s length and
  `reply_array_header`'s count stay on `_put_uint` (always ≥ 0).
- **`src/errmsg.asm`**: add `emit_incrdecr_ovf`
  (`-ERR increment or decrement would overflow\r\n`) and `emit_decr_ovf`
  (`-ERR decrement would overflow\r\n`), following the existing tail-call-into-
  `append_raw` pattern. `emit_notint`, `emit_wrongtype`, `emit_wrongargs`, `emit_oom`
  are reused unchanged.
- **`src/dispatch.asm`**: route the six commands. `INCR`/`DECR`/`TYPE` (len 4) join
  the existing `.len4` bucket; `INCRBY`/`DECRBY`/`EXISTS` (len 6) join `.len6`
  (currently only `LRANGE`). No new length buckets. `extern` the four counter
  routines from `counter.asm`.
- **`Makefile`**: add `src/counter.asm` to the object list.

## Data flow

`net.drain → dispatch` (unchanged) routes by length+name to a command routine, which
builds its reply into the current connection's output buffer via the existing
`reply_*`/`emit_*` builders (all bounds-checked/growable since milestone G). No
change to the parse, keyspace, or net layers beyond the additive `parse_int`/
`reply_int` edits, which preserve their existing contracts.

## Error handling

Every error uses the exact valkey byte string (verified above): `emit_notint` for a
non-integer stored value or increment argument; `emit_incrdecr_ovf` for arithmetic
overflow; `emit_decr_ovf` for the `DECRBY LLONG_MIN` negation guard; `emit_wrongtype`
for a non-string key under a counter; `emit_wrongargs` for arg-count errors;
`emit_oom` when the arena is exhausted on store. `TYPE`/`EXISTS` have no error path
beyond arg-count.

## Testing

New `tests/counter.py` (RESP client, exit 0/1) covering: fresh `INCR`→1 / `DECR`→-1;
`INCRBY`/`DECRBY` with positive and negative args; overflow at `INT64_MAX`
(`-ERR increment or decrement would overflow`); `DECRBY LLONG_MIN`
(`-ERR decrement would overflow`); non-integer value and non-integer increment
(`-ERR value is not an integer or out of range`); `WRONGTYPE` (INCR on a list);
`LLONG_MIN` round-trip (`DECR` from `MIN+1` then `INCR` back); `TYPE`
string/list/hash/none; `EXISTS` variadic with duplicates and a missing key.

In addition, a **valkey oracle diff**: for a fixed command script, byte-compare
asmredis (7777) against `valkey-server` (7799), reusing the repo's existing
conformance/oracle approach, so any divergence in reply bytes fails the test. Wire
both into `tests/wire.sh` (new server instance, `timeout`, kill/wait) and gate the
suite exit on them.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** counter core is add-only; both overflow messages arise structurally
  (arithmetic `jo` vs the `DECRBY LLONG_MIN` guard), matching valkey. `parse_int`/
  `reply_int`/`itoa_s` edits preserve existing contracts (all current callers pass
  non-negative values and in-range integers).
- **Scope:** six commands + three contained infra edits + one new file; single plan.
- **Ambiguity:** "missing key = 0" applies only to the counter core; `EXISTS` counts
  a missing key as 0 (skipped) and `TYPE` returns `+none` — stated explicitly.
