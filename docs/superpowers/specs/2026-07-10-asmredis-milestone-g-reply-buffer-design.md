# Milestone G — Unified growable per-connection output buffer (Design)

Date: 2026-07-10
Status: Approved, ready for planning

## Problem

The reply path assumes a bounded maximum single reply (~16423 B, the
unknown-command echo), so the fixed buffers are treated as never-overflow. That
invariant is false for collection replies:

- **Build overflow:** `reply.asm`'s `_put_byte`/`_put_bytes`/`_put_crlf` append into
  a fixed 64 KB global `out_buf` with **no bounds check**. A reply > 64 KB (e.g.
  `HGETALL`/`LRANGE` of a large collection, bounded only by the 64 MB arena)
  corrupts memory during construction.
- **Stash overflow:** `flush_reply` (net.asm) copies the unwritten tail into a
  fixed 32 KB per-conn write slot with an unchecked `rep movsb`. A tail > 32 KB
  overflows into the neighbouring fd's slot — cross-connection memory corruption,
  reachable by a slow reader (a prompt reader drains before EAGAIN, which is why
  the current tests pass).

`HGETALL` of a ~2000-field hash is already ~42 KB (> 32 KB); the milestone-F
`hash-stress` test survives only because its client reads promptly. This is a
pre-existing bug (LRANGE has the identical exposure) that HASH made trivially
reachable.

## Scope

Replace the fixed global `out_buf` + fixed per-conn stash with a **unified,
growable per-connection output buffer**: each connection owns one buffer that the
reply is built into and drained from, growing to hold a reply of any size. Removes
the size ceiling entirely; the common path (small replies) stays allocation-free
so throughput does not regress.

Out of scope: client-output-buffer limits / max-reply caps (a future safety knob);
`writev`/scatter-gather; accumulate-then-flush pipelining (kept per-command).

## Architecture

Only four files change; the command layer (`dispatch`/`list`/`hash`/`errmsg`,
`parser`) is untouched because `reply.asm`'s public builders keep their signatures.

- **`include/syscalls.inc`** — `CONN_STATE_SZ` 32→64, `CONN_STATE_SHIFT` 5→6;
  rename `WRITE_BUF_SIZE`/`WRITE_BUF_SHIFT` → `OUTBUF_BASE_SIZE` (32768) /
  `OUTBUF_BASE_SHIFT` (15); add `ST_OUT_MMAP` (4); drop the now-unused
  `OUT_BUF_SIZE`.
- **`src/main.asm`** — drop the `out_buf`/`out_len` globals.
- **`src/reply.asm`** — the `_put_*` helpers target the current conn's buffer with
  bounds-check + grow.
- **`src/net.asm`** — the buffer lifecycle: base-slot init, `_grow`, `_send`,
  `_reset_outbuf`, and the rewritten `drain`/`on_writable`/`on_accept`/`close_conn`.

### conn_state layout

The existing `wr_pos`/`wr_len` fields already mean "drain cursor / total pending
bytes", so they are reused (renamed) as `out_pos`/`out_len`; two fields are
appended:
```
+0  rb_used   +8 out_pos   +16 out_len   +24 flags   +32 out_ptr   +40 out_cap
```
`flags`: `ST_IN_USE=1`, `ST_WATCH_OUT=2`, `ST_OUT_MMAP=4`. Record size 48 rounds up
to `CONN_STATE_SZ=64` (`CONN_STATE_SHIFT=6`).

### Buffer scheme: base slot + overflow mmap

Each conn's output buffer defaults to a per-fd slot in a pre-mapped region
`outbuf_base` (`MAX_CONNS × OUTBUF_BASE_SIZE = 1024 × 32 KB = 32 MB`, lazily paged
— this *replaces* today's identically-sized write-slot region, so the footprint is
unchanged and the removed 64 KB global `out_buf` is a net reduction).

- A reply that fits the 32 KB slot — **every non-collection reply, plus small
  collections** — uses the slot with **zero allocation**, exactly like today's hot
  path. No throughput regression.
- A reply exceeding the slot grows to a standalone `mmap` (`ST_OUT_MMAP` set),
  reclaimed (`munmap`, reset to the base slot) once fully sent or on close.

`OUTBUF_BASE_SIZE` is 32768 specifically so the largest non-collection reply
(~16423 B) never triggers a grow — matching the current no-alloc behaviour.

### Build-side globals (`reply.asm`)

The public builders (`reply_simple`/`reply_bulk`/`reply_null`/`reply_int`/
`reply_err`/`append_raw`/`reply_array_header`) keep their signatures. Internally
they target globals set by `drain` before dispatch:
- `cur_out` — base pointer of the current conn's buffer,
- `cur_cap` — its capacity,
- `cur_len` — bytes built so far (replaces `out_len`),
- `cur_err` — set if a grow failed (address-space exhaustion; practically
  unreachable).

### Reply construction (`reply.asm`)

Each `_put_*` inlines a bounds check and grows only on overflow (hot path is a
compare + not-taken branch, no call):
```
need = cur_len + n
if need > cur_cap: call _grow(need)          ; slow path only
if cur_err: return (skip the write)          ; grow failed -> no write, no overflow
base = cur_out                                ; reload: _grow may have moved it
write n bytes at base+cur_len; cur_len += n
```
**Invariant: `_put_*` never writes past `cur_cap`.** `_put_byte`(1)/`_put_crlf`(2)
check too (a boundary write can overflow a full slot).

`_grow(rdi=need)`: `newcap = max(2*cur_cap, need)` rounded up to a page; `mmap`
anon RW `newcap`; on mmap failure set `cur_err` and return (leaving `cur_out`/
`cur_cap` unchanged so `_put_*` skips). On success: copy `cur_out[0..cur_len]` into
the new buffer; if `ST_OUT_MMAP` was already set for this build (tracked via a
`cur_mmap` global mirrored into conn flags on persist), `munmap` the old buffer;
set `cur_out=new`, `cur_cap=newcap`, `cur_mmap=1`.

### Send path (`net.asm`)

`flush_reply` and `on_writable`'s inner loop unify into `_send(edi=fd) -> rax`:
writes directly from `out_ptr[out_pos..out_len]` — **no stash copy**, the buffer is
already the conn's own.
- **Fully sent** (`out_pos==out_len`) → `_reset_outbuf(fd)`; if `ST_WATCH_OUT` was
  set, clear it and MOD interest back to EPOLLIN; return 1.
- **EAGAIN** → persist `out_pos`; if `ST_WATCH_OUT` not set, set it and MOD to
  EPOLLOUT (drop EPOLLIN); return 0.
- **Other error** → `close_conn`; return 0.

`_reset_outbuf(fd)`: if `ST_OUT_MMAP`, `munmap(out_ptr, out_cap)`, reset
`out_ptr = outbuf_base + fd*OUTBUF_BASE_SIZE`, `out_cap = OUTBUF_BASE_SIZE`, clear
`ST_OUT_MMAP`; set `out_pos = out_len = 0`.

### Lifecycle

- **`on_accept`**: init `out_ptr = base slot`, `out_cap = OUTBUF_BASE_SIZE`,
  `out_pos = out_len = 0`, `flags = ST_IN_USE` (`ST_OUT_MMAP` clear).
- **`drain`** per command: load conn `out_ptr`/`out_cap`/mmap-flag into
  `cur_out`/`cur_cap`/`cur_mmap`; `cur_len = 0`, `cur_err = 0`; `parse_one` +
  `dispatch`; persist `cur_out`/`cur_cap`/mmap-flag back to conn and set
  `out_len = cur_len`; if `cur_err` → `close_conn`; else `out_pos = 0` and `_send`.
  Loop while `_send` returned 1 and input remains; stop on 0 (backpressure). The
  PROTOERR path likewise emits into `cur_out` then `_send`s.
- **`on_writable`**: `_send`; on 1 it has already reset + re-armed EPOLLIN, then
  `drain` the input buffered while blocked.
- **`close_conn`**: if `ST_OUT_MMAP`, `munmap(out_ptr, out_cap)` before clearing
  state — no leak if a client disconnects mid-large-reply.

## Error handling / edge cases

- **Small / non-collection replies never grow** → byte-for-byte the same fast path
  as today (the no-regression guarantee).
- **Grow failure** (mmap of a few MB fails — address-space exhaustion) → `cur_err`
  set, `_put_*` write nothing, `drain` closes the connection. Never a buffer
  overflow, never a partial/corrupt reply on the wire.
- **Pipelining + backpressure**: unchanged per-command semantics — on backpressure
  stop, resume via EPOLLOUT, then `drain` the rest.
- **Overflow buffer lifetime**: held only while a large reply is in flight;
  reclaimed on full send (`_reset_outbuf`) or on close. At most one overflow mmap
  per connection at a time.
- **Base slot for reused fds**: deterministic (`outbuf_base + fd*size`);
  `close_conn` zeroes conn_state, `on_accept` re-inits — correct across fd reuse.

## Testing

- **Bug-proving slow-reader test** (`tests/big_reply.py` extended, or a new
  `tests/slow_big.py`): a client with a throttled `recv` / small `SO_RCVBUF` issues
  a command whose reply exceeds the 32 KB slot (a ~2000-field `HGETALL` ≈ 42 KB)
  **and** one exceeding 64 KB (a larger `HGETALL`/`LRANGE`), forcing the EAGAIN /
  grow path, then reads the entire reply slowly and asserts the **exact, complete
  bytes** (correct element count and values, no corruption, no truncation). Fails
  on today's code (memory corruption / truncation), passes after the fix.
- **Cross-connection integrity**: connection A drains a large (> slot) reply under
  backpressure while connection B issues small commands interleaved; assert B's
  replies are byte-correct — proves no cross-fd slot corruption.
- **Regression**: full `tests/wire.sh` (string/list/hash conformance, reclamation,
  rehashing, concurrency, the existing `backpressure`/`big-reply-backpressure`
  checks) stays green.
- **Benchmark**: re-run the SET/GET sweep; the base-slot fast path must show no
  throughput regression vs milestone F.
- **Comment correctness**: the now-false "max reply ~16423 / stash never overflows"
  notes in `syscalls.inc` and `net.asm` are corrected to state that replies are
  unbounded and the buffer grows.

## Risk note

`net.asm` is the trickiest, most-reviewed file (epoll interest toggling, conn-state
machine, stack-alignment discipline). This milestone rewrites its write path and
changes the conn_state layout. Mitigations: the conn_state change reuses existing
field offsets (only appends two); `_send` unifies two existing code paths rather
than inventing new control flow; the base-slot fast path preserves current
behaviour; and the existing `backpressure`/`big-reply-backpressure` tests plus the
new slow-reader + cross-connection tests guard the rewrite.
