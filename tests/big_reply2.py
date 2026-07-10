#!/usr/bin/env python3
# Large-reply correctness under backpressure + cross-connection integrity.
# Usage: big_reply2.py <port>. Exit 0 ok / 1 fail.
import socket, sys

def conn(port, rcvbuf=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if rcvbuf is not None:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.connect(("127.0.0.1", port)); s.settimeout(30); return s

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
    def n(s,k):
        while len(s.b)<k: s._f()
        o,s.b=s.b[:k],s.b[k:]; return o

def bulk(r):
    h=r.line(); assert h[:1]==b"$",h
    k=int(h[1:])
    if k<0: return None
    d=r.n(k); r.n(2); return d

def arr(r):
    h=r.line(); assert h[:1]==b"*",h
    return [bulk(r) for _ in range(int(h[1:]))]

def build_hash(s, r, key, nfields, vlen):
    # HSET in batches; each field f<i> = <vlen bytes marked with i>
    exp={}
    i=0
    while i<nfields:
        batch=min(50, nfields-i)
        args=[b"HSET", key.encode()]
        for j in range(i,i+batch):
            f=b"f%d"%j; v=(b"%08d"%j)+b"y"*(vlen-8)
            args += [f,v]; exp[f]=v
        s.sendall(cmd(*args))
        assert r.line()==b":%d"%batch, "HSET batch"
        i+=batch
    return exp

def main():
    if len(sys.argv)!=2: print("usage: big_reply2.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        # ---- 1) >32KB reply under a slow reader (small SO_RCVBUF forces EAGAIN) ----
        s=conn(port, rcvbuf=4096); r=R(s)
        exp=build_hash(s, r, "H32", 2000, 12)     # ~2000*(f + 12B val + framing) ~ 44KB
        s.sendall(cmd("HGETALL","H32"))
        a=arr(r)
        got=dict(zip(a[0::2],a[1::2]))
        if got!=exp: print("FAIL >32KB HGETALL mismatch (n=%d)"%len(got)); return 1
        # ---- 2) >64KB reply (exceeds the old 64KB build buffer too) ----
        exp2=build_hash(s, r, "H64", 3000, 30)    # ~3000*(f + 30B + framing) ~ 130KB
        s.sendall(cmd("HGETALL","H64"))
        a2=arr(r)
        got2=dict(zip(a2[0::2],a2[1::2]))
        if got2!=exp2: print("FAIL >64KB HGETALL mismatch (n=%d)"%len(got2)); return 1
        s.close()
        # ---- 3) cross-connection integrity: A drains a huge reply slowly while B
        #         interleaves small commands; B's replies must stay correct ----
        A=conn(port, rcvbuf=4096); ra=R(A)
        expA=build_hash(A, ra, "HA", 4000, 40)    # ~large
        A.sendall(cmd("HGETALL","HA"))            # A now backpressured mid-drain
        # read A's reply slowly, interleaving B commands
        B=conn(port); rb=R(B)
        for k in range(200):
            B.sendall(cmd("SET", "bk%d"%k, "bv%d"%k)); assert rb.line()==b"+OK"
            B.sendall(cmd("GET", "bk%d"%k))
            if bulk(rb)!=b"bv%d"%k: print("FAIL cross-conn: B GET bk%d"%k); return 1
        aA=arr(ra)                                 # now finish reading A fully
        if dict(zip(aA[0::2],aA[1::2]))!=expA: print("FAIL cross-conn: A reply corrupted"); return 1
        A.close(); B.close()
        print("OK big_reply2: >32KB + >64KB replies intact; cross-connection clean")
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL big_reply2: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
