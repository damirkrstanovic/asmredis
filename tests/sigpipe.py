#!/usr/bin/env python3
# SIGPIPE hardening regression: a client that forces the server to write to a
# broken pipe must NOT kill the server. Repro: build a large hash, then on a
# victim connection request a huge reply (HGETALL) under a small SO_RCVBUF and
# close GRACEFULLY (FIN) WITHOUT reading it. The small recv buffer forces the
# server into the multi-write backpressure path, the un-drained FIN'd peer makes
# a later write() hit a broken pipe, and on unhardened code the default SIGPIPE
# disposition terminates the whole process (exit 141). We detect the death by a
# fresh connection no longer being able to PING.
# Usage: sigpipe.py <port>. Exit 0 ok / 1 fail (server died or reply corrupt).
import socket, sys, time

def conn(port, rcvbuf=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if rcvbuf is not None:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.connect(("127.0.0.1", port)); s.settimeout(10); return s

def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o

class R:
    def __init__(s,sock): s.s=sock; s.b=b""
    def _f(s):
        c=s.s.recv(4096)
        if not c: raise EOFError("closed")
        s.b+=c
    def line(s):
        while b"\r\n" not in s.b: s._f()
        l,s.b=s.b.split(b"\r\n",1); return l

def build_hash(s, r, key, nfields, vlen):
    i=0
    while i<nfields:
        batch=min(50, nfields-i)
        args=[b"HSET", key.encode()]
        for j in range(i,i+batch):
            args += [b"f%d"%j, (b"%08d"%j)+b"y"*(vlen-8)]
        s.sendall(cmd(*args))
        assert r.line()==b":%d"%batch, "HSET batch"
        i+=batch

def alive(port):
    try:
        s=conn(port); r=R(s)
        s.sendall(cmd("PING"))
        ok = r.line()==b"+PONG"
        s.close(); return ok
    except OSError:
        return False

def main():
    if len(sys.argv)!=2: print("usage: sigpipe.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        # seed a large hash so HGETALL yields a >100KB reply the server must stream
        s=conn(port); r=R(s)
        build_hash(s, r, "HP", 3000, 40)   # ~3000*(f + 40B + framing) ~ 150KB
        s.close()
        # fire several broken-pipe victims: each requests the huge reply under a
        # small recv buffer (forces the server's multi-write backpressure path)
        # and closes gracefully WITHOUT reading -> a later server write() hits a
        # broken pipe. On unhardened code the first such victim kills the server.
        for k in range(20):
            v=conn(port, rcvbuf=2048)
            v.sendall(cmd("HGETALL","HP"))
            v.close()                      # graceful FIN, reply left undrained
            time.sleep(0.02)
            if not alive(port):
                print("FAIL sigpipe: server died after broken-pipe write #%d"%k); return 1
        # final: server still fully functional
        s=conn(port); r=R(s)
        s.sendall(cmd("SET","k","v")); assert r.line()==b"+OK", "SET"
        s.sendall(cmd("GET","k")); assert r.line()==b"$1" and r.line()==b"v", "GET"
        s.close()
        print("OK sigpipe: server survived 20 broken-pipe writes; still serving")
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL sigpipe: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
