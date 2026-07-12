# Milestone M — SCAN (Design)

Date: 2026-07-13
Status: Approved, ready for planning

## Scope

`SCAN cursor [MATCH pattern] [COUNT count]`. Cursor-based keyspace iteration.

**Out of scope:** `TYPE` filter option; `HSCAN`/`SSCAN`/`ZSCAN`; glob `[...]`/`\` escapes
(MATCH supports `*`, `?`, and literals).

## Reference ground truth (valkey, captured live)

- Reply is a 2-element array `[cursor_bulk_string, keys_array]`; the cursor is `"0"`
  when iteration is complete. Empty keyspace `SCAN 0` → `["0", []]`.
- `SCAN 0 COUNT 100 MATCH k1*` → the matching keys (order is implementation-specific).
- `SCAN notanumber` → `-ERR invalid cursor` (**new** error string).
- `SCAN 0 COUNT abc` → `-ERR value is not an integer or out of range` (existing `emit_notint`).
- `SCAN 0 COUNT 0` / `SCAN 0 BADOPT` / `SCAN 0 COUNT` (missing arg) → `-ERR syntax error`.
- `SCAN` (no cursor) → `-ERR wrong number of arguments for 'scan' command`.

**Not oracle-diffable:** SCAN's cursor values depend on the internal bucket layout,
which differs from valkey. The *error cases* above are deterministic and are
oracle-diffed; the iteration itself is tested by its coverage guarantee.

## Architecture

To make the cursor correct across table growth **between** SCAN calls, `SCAN` first
force-completes any pending incremental rehash (so the dict is a single table), then
uses Redis's **reverse-binary-increment cursor** over that table — the algorithm whose
whole purpose is resize-safety. Keys in the scanned buckets that match the MATCH glob
are collected into a bounded scratch and emitted.

### `keyspace.asm` — `ks_scan_prep`

```
ks_scan_prep() -> rax = ht_table[0] base, rdx = ht_mask[0]
```
Loops `_rehash_step` until `rehashidx < 0` (rehash complete → single table), then
returns table 0's base pointer and mask.

### `src/scan.asm` — `cmd_scan` + `_glob_match` + `_rev64`

- `cmd_scan` (argc ≥ 2): parse cursor (`parse_int`; invalid → `emit_invalidcursor`);
  parse `MATCH pattern` / `COUNT n` options (case-insensitive; `COUNT` not-integer →
  `emit_notint`, `COUNT < 1` / unknown / missing-arg → `emit_syntax`; default COUNT 10).
  `ks_scan_prep`. Then walk: for `count` buckets from the cursor, walk each bucket's
  chain (`[node+8]`=key, `[node+16]`=keylen), and for each key matching the pattern
  (or all, if no MATCH) append `(ptr,len)` to a scratch (capped at 4096/call). Advance
  the cursor by reverse-binary increment (`v |= ~mask; v = rev(v); v++; v = rev(v)`).
  Stop when the cursor wraps to 0 (→ next cursor `0`, complete) or `count` buckets are
  scanned (→ next cursor `v`). Emit `[next_cursor_decimal, [collected keys]]`.
- `_glob_match(pat, plen, str, slen) -> 1/0`: iterative glob with `*` backtracking,
  `?`, and literals. Leaf.
- `_rev64(rdi) -> rax`: 64-bit bit reversal (the standard swap-1/2/4-bit + `bswap`).
  Leaf.

### Supporting

- `errmsg.asm`: `emit_invalidcursor` → `-ERR invalid cursor\r\n`.
- `dispatch.asm`: route `SCAN` (len 4) → `cmd_scan`.

## Error handling

New `emit_invalidcursor`. Reuse `emit_notint`, `emit_syntax`, `emit_wrongargs`.

## Testing

`tests/scan.py`: populate N keys; iterate `SCAN 0` (default COUNT) collecting keys
until the cursor returns `"0"`; assert the **collected key set equals the expected
set** (full coverage — order and cursor values are implementation-specific and are not
asserted). Also: `MATCH prefix*` with a large COUNT returns exactly the matching keys;
empty keyspace → `["0", []]`; and the error cases. Oracle `check` lines in `wire.sh`
for the deterministic **error** cases only (`SCAN notanumber`, `SCAN 0 COUNT abc`,
`SCAN 0 COUNT 0`, `SCAN 0 BADOPT`, `SCAN`). Wired into `wire.sh`.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** the reverse-binary cursor + force-rehash-finish gives full coverage
  across resizes between calls; the scratch cap (4096 keys/call) is a documented bound
  (irrelevant at default COUNT). MATCH supports `*`/`?`/literal only (documented).
  Errors match the captured valkey strings.
- **Scope:** one command + two helpers + a keyspace accessor; single plan.
- **Ambiguity:** a full iteration (cursor 0 → … → 0) with a stable keyspace returns
  every key exactly once; the coverage test relies on read-only iteration (no resize
  mid-test).
