# Milestone J — Sets (Design)

Date: 2026-07-12
Status: Approved, ready for planning

## Problem

asmredis has string/list/hash + counters + TTL but no Set type — a core Redis
collection. Sets are the natural next data type and reuse the existing hash machinery
almost entirely.

## Scope

Five commands: `SADD`, `SREM`, `SMEMBERS`, `SISMEMBER`, `SCARD`. Full valkey-exact
semantics.

**Out of scope:** `SPOP`/`SRANDMEMBER` (require randomness — no RNG in the codebase,
and a random reply can't be oracle-diffed), `SMISMEMBER`/`SMOVE`, and the set-algebra
family `SUNION`/`SINTER`/`SDIFF`(`STORE`) — a natural follow-on milestone.

## Reference ground truth (valkey, captured live)

- `SADD s a b c` → `:3`; `SADD s a d` → `:1` (only new members counted); `SCARD s` → `:4`.
- `SISMEMBER s a` → `:1`, non-member → `:0`; `SCARD`/`SISMEMBER` of a missing key → `:0`.
- `SREM s a z` → `:1` (present removed, absent ignored); removing the **last** member
  deletes the key (`EXISTS`→`:0`, `TYPE`→`none`) — same auto-delete as `HDEL`.
- `SMEMBERS` of a missing key → empty array (`*0`).
- `TYPE` of a set → `+set`; `SADD` on a string → WRONGTYPE; `GET` on a set → WRONGTYPE.
- Arity: `SADD`/`SREM`/`SISMEMBER` need key + ≥1 member (`SADD s` alone → wrongargs);
  `SCARD`/`SMEMBERS` take the key only. Errors use the lowercase command name.

## Architecture

A set is a hash header (created by `hash_new`) tagged `TYPE_SET(3)` on the keyspace
entry, whose members are stored as hash **fields with an empty value**. The allocator
rounds size 0 to the 8-byte class and `mem_dup(x, 0)` returns a valid non-null 8-byte
block, so `hash_set(header, member, mlen, member_ptr, 0)`, `hash_del`, `hash_exists`,
and `hash_free` all operate correctly on empty-valued nodes — **no new set primitives
are needed**. The hash is a head→tail linked list appending at the tail, so member
iteration is insertion order, matching valkey's small-set order.

### Commands — `src/set.asm` (mirrors `hash.asm`'s command structure)

- `cmd_sadd` (argc ≥ 3): `ks_lookup` the key; if missing, `ks_insert` + `hash_new` +
  tag entry `TYPE_SET`; if present and `[entry+40] != TYPE_SET` → `emit_wrongtype`.
  For each member arg, `hash_set(header, member, mlen, member, 0)` and count the
  `1`(new) returns (a `2`=OOM aborts to `emit_oom`); reply `:added`.
- `cmd_srem` (argc ≥ 3): `ks_lookup`; missing → `:0`; non-set → WRONGTYPE. For each
  member, `hash_del`; count removals. If the count at `[header+16]` reaches 0, `ks_del`
  the key (auto-delete). Reply `:removed`.
- `cmd_sismember` (argc 3): `ks_lookup`; missing → `:0`; non-set → WRONGTYPE; else
  `hash_exists(member)` → `:1`/`:0`.
- `cmd_scard` (argc 2): `ks_lookup`; missing → `:0`; non-set → WRONGTYPE; else
  `:[header+16]`.
- `cmd_smembers` (argc 2): `ks_lookup`; missing → `*0`; non-set → WRONGTYPE; else emit
  `reply_array_header(count)` then each member as a bulk string (iterate head→tail,
  mirroring `cmd_hkeys`).

### Supporting changes

- `include/syscalls.inc`: `%define TYPE_SET 3`.
- `src/keyspace.asm`: `_free_value` dispatches `TYPE_SET` → `hash_free` (the set header
  is a hash header). Its existing type switch handles STR/LIST/HASH; add the SET case
  (it can share the HASH branch since both are hash headers freed by `hash_free`).
- `src/dispatch.asm`: route `SADD`/`SREM`/`SCARD` (len 4), `SMEMBERS`/`SISMEMBER`?
  — lengths: `SADD`=4, `SREM`=4, `SCARD`=5, `SMEMBERS`=8, `SISMEMBER`=9. Add to
  `.len4` (SADD, SREM), `.len5` (SCARD), `.len8` (SMEMBERS — bucket added in
  milestone I), `.len9` (SISMEMBER — bucket added in milestone I).
- `include/syscalls.inc` already has no set-specific tunables needed.

## Error handling

Reuse `emit_wrongtype`, `emit_wrongargs` (lowercase names `sadd`/`srem`/`sismember`/
`scard`/`smembers`), `emit_oom`. No new error strings.

## Testing

New `tests/set.py` (RESP client, exact bytes): SADD count-added incl. dups, SCARD,
SISMEMBER present/absent/missing-key, SREM incl. auto-delete on empty, SMEMBERS content
(compared as a **set**, order-independent, so the test is robust even though asmredis
happens to match valkey's order), WRONGTYPE both ways, TYPE→set, arity. Oracle `check`
lines in the `wire.sh` conformance block for the integer-returning commands and
`SMEMBERS` (order matches valkey for the small test inputs; if a `DIFF` ever appears it
is a real divergence to investigate, not to hide). Wired into `wire.sh`.

## Self-review notes

- **Placeholders:** none.
- **Consistency:** `TYPE_SET=3` used in the entry tag, the `_free_value` switch, and
  the command WRONGTYPE checks. Set members are always empty-valued hash fields; the
  auto-delete-on-empty mirrors `cmd_hdel`. `SMEMBERS`/`SCARD` are key-only; the rest
  need ≥1 member.
- **Scope:** 5 commands, one new file + small edits; single plan.
- **Ambiguity:** "empty set" (count reaches 0 after `SREM`) triggers `ks_del`, matching
  valkey's auto-delete; a set never persists with 0 members.
