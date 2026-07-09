#!/usr/bin/env python3
# Minimal RESP client stress-tester for memory reclamation.
# Usage: reclaim.py <port> <overwrite|del|oom>
# Exit 0 on success, 1 on failure (prints a diagnostic).
import socket, sys

VLEN = 16000          # under the 16384 storable cap; lands in the 16384 class
ITERS = 10000         # 10000 * 16000 ~= 160 MB through a 64 MB arena

def connect(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(15)
    return s

class Reader:
    """Buffered reader over a socket for line- and count-based RESP reads."""
    def __init__(self, sock):
        self.s = sock
        self.buf = b""
    def _fill(self):
        chunk = self.s.recv(65536)
        if not chunk:
            raise EOFError("server closed connection")
        self.buf += chunk
    def line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line
    def read_n(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

def resp_cmd(*parts):
    out = b"*%d\r\n" % len(parts)
    for p in parts:
        if isinstance(p, str):
            p = p.encode()
        out += b"$%d\r\n%s\r\n" % (len(p), p)
    return out

def value_for(i):
    # distinct per iteration so a stale value is detectable
    head = b"%08d" % i
    return head + b"x" * (VLEN - len(head))

def read_simple(r):
    # returns the reply line for +OK / -ERR ...
    return r.line()

def read_bulk(r):
    hdr = r.line()                 # $<len>
    assert hdr[:1] == b"$", hdr
    n = int(hdr[1:])
    if n < 0:
        return None
    data = r.read_n(n)
    r.read_n(2)                    # trailing CRLF
    return data

def mode_overwrite(port):
    s = connect(port); r = Reader(s)
    for i in range(ITERS):
        s.sendall(resp_cmd("SET", "rk", value_for(i)))
        rep = read_simple(r)
        if rep != b"+OK":
            print("FAIL overwrite iter %d: SET replied %r" % (i, rep)); return 1
    s.sendall(resp_cmd("GET", "rk"))
    got = read_bulk(r)
    want = value_for(ITERS - 1)
    if got != want:
        print("FAIL overwrite: final GET mismatch (got head %r want head %r, "
              "len %s)" % (got[:8] if got else got, want[:8], len(got) if got else None))
        return 1
    print("OK overwrite: %d overwrites reclaimed, final value correct" % ITERS)
    return 0

def mode_del(port):
    s = connect(port); r = Reader(s)
    for i in range(ITERS):
        s.sendall(resp_cmd("SET", "dk", value_for(i)))
        rep = read_simple(r)
        if rep != b"+OK":
            print("FAIL del iter %d: SET replied %r" % (i, rep)); return 1
        s.sendall(resp_cmd("DEL", "dk"))
        d = r.line()
        if d != b":1":
            print("FAIL del iter %d: DEL replied %r" % (i, d)); return 1
    print("OK del: %d SET/DEL cycles reclaimed, no OOM" % ITERS)
    return 0

def mode_oom(port):
    # Distinct keys with no reclamation must eventually exhaust the 64 MB arena
    # and produce an -ERR out of memory reply.
    s = connect(port); r = Reader(s)
    saw_oom = False
    for i in range(6000):          # ~6000 * ~16 KB > 64 MB
        s.sendall(resp_cmd("SET", "k%d" % i, value_for(i)))
        rep = read_simple(r)
        if rep == b"+OK":
            continue
        if rep.startswith(b"-ERR out of memory"):
            saw_oom = True
            break
        print("FAIL oom iter %d: unexpected reply %r" % (i, rep)); return 1
    if not saw_oom:
        print("FAIL oom: filled arena without any -ERR out of memory reply"); return 1
    print("OK oom: arena exhaustion reported as -ERR out of memory")
    return 0

def main():
    if len(sys.argv) != 3:
        print("usage: reclaim.py <port> <overwrite|del|oom>"); return 2
    port = int(sys.argv[1]); mode = sys.argv[2]
    fn = {"overwrite": mode_overwrite, "del": mode_del, "oom": mode_oom}.get(mode)
    if fn is None:
        print("unknown mode %r" % mode); return 2
    try:
        return fn(port)
    except (EOFError, OSError, ValueError, AssertionError) as e:
        # OSError covers socket timeout and mid-stream connection reset/close
        # (BrokenPipeError/ConnectionResetError); ValueError covers a malformed
        # bulk-length header. Report a clean FAIL line instead of a traceback.
        print("FAIL %s: %r" % (mode, e)); return 1

if __name__ == "__main__":
    sys.exit(main())
