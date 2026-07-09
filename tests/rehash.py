#!/usr/bin/env python3
# Rehash correctness stress: many distinct keys across many table resizes.
# Usage: rehash.py <port>
# Exit 0 on success, 1 on failure (prints a diagnostic).
import socket, sys

N = 50000          # forces ~13 doublings from an initial size of 4

def connect(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.settimeout(30)
    return s

class Reader:
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

def read_bulk(r):
    hdr = r.line()
    assert hdr[:1] == b"$", hdr
    n = int(hdr[1:])
    if n < 0:
        return None
    data = r.read_n(n)
    r.read_n(2)
    return data

def key(i):  return b"key:%d" % i
def val(i):  return b"val:%d" % i

def main():
    if len(sys.argv) != 2:
        print("usage: rehash.py <port>"); return 2
    port = int(sys.argv[1])
    try:
        s = connect(port); r = Reader(s)
        # Phase 1: insert N distinct keys. Every ~997 inserts, GET an
        # already-inserted key and verify (some of these land while a rehash
        # is in flight, exercising the both-table lookup path).
        for i in range(N):
            s.sendall(resp_cmd(b"SET", key(i), val(i)))
            if r.line() != b"+OK":
                print("FAIL insert %d: not +OK" % i); return 1
            if i and i % 997 == 0:
                j = i // 2
                s.sendall(resp_cmd(b"GET", key(j)))
                got = read_bulk(r)
                if got != val(j):
                    print("FAIL mid-rehash GET key:%d -> %r" % (j, got)); return 1
        # Phase 2: every key must read back its exact value.
        for i in range(N):
            s.sendall(resp_cmd(b"GET", key(i)))
            got = read_bulk(r)
            if got != val(i):
                print("FAIL verify GET key:%d -> %r (want %r)" % (i, got, val(i)))
                return 1
        # Phase 3: delete every even key; assert :1. Odd keys untouched.
        for i in range(0, N, 2):
            s.sendall(resp_cmd(b"DEL", key(i)))
            if r.line() != b":1":
                print("FAIL DEL key:%d not :1" % i); return 1
        # Phase 4: even keys miss ($-1), odd keys still hold their value.
        for i in range(N):
            s.sendall(resp_cmd(b"GET", key(i)))
            got = read_bulk(r)
            want = None if i % 2 == 0 else val(i)
            if got != want:
                print("FAIL post-del GET key:%d -> %r (want %r)" % (i, got, want))
                return 1
        print("OK rehash: %d keys correct across resizes, del+verify clean" % N)
        return 0
    except (EOFError, OSError, ValueError, AssertionError) as e:
        print("FAIL rehash: %r" % e); return 1

if __name__ == "__main__":
    sys.exit(main())
