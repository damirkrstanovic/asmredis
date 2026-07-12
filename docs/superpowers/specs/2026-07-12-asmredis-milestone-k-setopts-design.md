# Milestone K — SET options (Design)

Date: 2026-07-12
Status: Approved, ready for planning

## Problem

`SET` only accepts `SET key value`. Redis's `SET` takes expiry and conditional
options, now cheap to add given milestone I's deadline field + keep-TTL flag.

## Scope

`SET key value [EX seconds | PX ms | EXAT unix-s | PXAT unix-ms | KEEPTTL] [NX | XX]`.

**Out of scope:** the `GET` option (returns the old value / WRONGTYPE if the old value
isn't a string, and interacts with NX/XX) — a clean follow-on; `IDLE`/other niche
options.

## Reference ground truth (valkey, captured live)

- `SET k v EX 100` → `+OK`, `TTL`→100; `SET k v PX 50000` sets a ms TTL; plain `SET`
  clears TTL; `SET k w KEEPTTL` preserves the existing TTL.
- `SET k v EXAT 9999999999` → `+OK` (absolute seconds).
- `NX`: set only if the key is absent — else `$-1` (nil), no change. `XX`: set only if
  present — else `$-1`.
- **`SET k v EX 0` and `EX -1` → `-ERR invalid expire time in 'set' command`** — SET
  requires a strictly positive time and, unlike `EXPIRE`, never deletes; it stores the
  deadline (even a past absolute one, which passive expiry then reaps on access).
- `SET k v EX abc` → `-ERR value is not an integer or out of range` (existing `emit_notint`).
- Mutually exclusive / unknown / missing-arg → **`-ERR syntax error`** (new): `EX 100 PX 100`,
  `NX XX`, `EX 100 KEEPTTL`, `BADOPT`, `EX` (no value) all → syntax error.

## Architecture

`cmd_set` moves to a new `src/string.asm` (the future home of milestone L's string
commands too). The plain `SET key value` path (argc 3) is unchanged and fast. For
argc > 3:

1. **Parse options** over `argv[3..]`, case-insensitive (uppercase into a small
   scratch buffer via `to_upper_buf`, or compare against both cases). State: an
   expire-mode ∈ {none, EX, PX, EXAT, PXAT, KEEPTTL} plus its integer value, and a
   condition ∈ {none, NX, XX}. `EX/PX/EXAT/PXAT` consume the following token as their
   value (missing → syntax error) and set the expire-mode (a second expire-mode, or
   `KEEPTTL` alongside a timed mode, → syntax error). `NX`/`XX` set the condition (a
   second condition → syntax error). Any unrecognised token → syntax error. All via
   `emit_syntax`.
2. **Deadline** (only for EX/PX/EXAT/PXAT): `parse_int` the value (invalid →
   `emit_notint`); require value > 0 and no overflow (else `emit_invalid_expire` with
   name `set`); convert to an absolute ms deadline (mult 1000 for EX/EXAT, 1 for
   PX/PXAT; basetime `g_now_ms` for EX/PX, 0 for EXAT/PXAT). SET never deletes on a
   past deadline — it stores it.
3. **Condition:** `ks_lookup` the key. NX and key present → reply `$-1`, done. XX and
   key absent → reply `$-1`, done.
4. **Store:** `ks_set(key, value, keepttl = 1 if KEEPTTL else 0)`; on OOM → `emit_oom`.
   For a timed set, `ks_lookup` the (now-present) entry and store `[entry+48] =
   deadline`. Reply `+OK`.

The `keepttl` flag already exists (milestone I): plain SET / SET with a new expire
clears the old TTL (flag 0, then the explicit deadline store overrides); `KEEPTTL`
preserves it (flag 1, no deadline store).

## Error handling

New `emit_syntax` → `-ERR syntax error\r\n`. Reuse `emit_notint`, `emit_invalid_expire`
(name `set`), `emit_oom`, `emit_wrongargs` (name `set`, for argc < 3).

## Files

- New `src/string.asm`: the enhanced `cmd_set` + its option parser + the `set` rodata
  strings (`s_ok`, `lc_set`).
- `src/dispatch.asm`: `extern cmd_set`; remove the old `cmd_set` definition and its
  `s_ok`/`lc_set` rodata; keep the `.len3` `SET`→`cmd_set` routing.
- `src/errmsg.asm`: `emit_syntax`.
- New `tests/setopt.py`.

## Testing

`tests/setopt.py` (exact bytes): EX/PX set + TTL readback, EXAT/PXAT, KEEPTTL preserve,
plain SET clears, NX new/blocked, XX present/absent, all error cases (EX abc → notint;
EX 0/-1 → invalid-expire; EX+PX / NX+XX / EX+KEEPTTL / BADOPT / EX-missing-arg →
syntax error), and that the plain 3-arg SET still works. Oracle `check` lines in the
`wire.sh` conformance block (deterministic cases — TTL readback right after SET EX is
stable at the set value). Wired into `wire.sh`.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** the plain `SET key value` fast path is byte-identical to today's;
  option parsing only runs for argc > 3. Deadline math mirrors `_set_expire` but with
  SET's `value > 0` rule and no delete-on-past. `keepttl` flag reused. `emit_syntax`
  is the single new error.
- **Scope:** 7 options on `SET`; new `string.asm` + small edits; single plan.
- **Ambiguity:** a duplicate flag (e.g. `NX NX`, or two expire modes) is a syntax
  error; option order is irrelevant; a past absolute deadline is stored (not rejected,
  not deleted) — passive expiry handles it.
