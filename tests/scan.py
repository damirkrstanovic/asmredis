#!/usr/bin/env python3
# Milestone M: SCAN cursor [MATCH p] [COUNT n]. Coverage + MATCH + errors.
import socket, sys
def conn(port):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.connect(("127.0.0.1",port)); s.settimeout(10); return s
def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o
class C:
    def __init__(s,port): s.s=conn(port); s.b=b""
    def _f(s):
        c=s.s.recv(4096)
        if not c: raise EOFError("closed")
        s.b+=c
    def line(s):
        while b"\r\n" not in s.b: s._f()
        l,s.b=s.b.split(b"\r\n",1); return l
    def reply(s):
        h=s.line(); t=h[:1]
        if t in (b"+",b"-",b":"): return h
        if t==b"$":
            n=int(h[1:])
            if n<0: return None
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*":
            n=int(h[1:])
            if n<0: return None
            return [s.reply() for _ in range(n)]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()
FAILS=[]
def eq(g,w,l):
    if g!=w: FAILS.append("%s: got %r want %r"%(l,g,w))
def scan_all(c, *opts):
    cur=b"0"; seen=[]
    for _ in range(100000):
        r=c.do("SCAN", cur, *opts)
        cur=r[0]; seen += r[1]
        if cur==b"0": break
    return seen
def main():
    if len(sys.argv)<2: print("usage: scan.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # wipe: delete any pre-existing keys via a full scan
        for k in set(scan_all(c)): c.do("DEL", k)
        eq(scan_all(c), [], "empty keyspace")
        # populate 200 keys and verify full coverage
        exp=set()
        for i in range(200):
            k=("key:%d"%i).encode(); c.do("SET", k, b"v"); exp.add(k)
        got=scan_all(c)
        if sorted(got)!=sorted(exp): FAILS.append("coverage: %d keys, want %d (dupes=%d)"%(len(set(got)),len(exp),len(got)-len(set(got))))
        if set(got)!=exp: FAILS.append("coverage set mismatch")
        # MATCH with a big COUNT returns exactly matching keys
        for k in [b"user:1",b"user:2",b"user:30",b"other"]: c.do("SET",k,b"v"); exp.add(k)
        m=scan_all(c, "MATCH", "user:*", "COUNT", "10000")
        eq(sorted(set(m)), sorted([b"user:1",b"user:2",b"user:30"]), "match user:*")
        # empty keyspace shape
        r=c.do("SCAN","0");
        if not (isinstance(r,list) and len(r)==2 and isinstance(r[1],list)): FAILS.append("scan reply shape %r"%r)
        # errors
        eq(c.do("SCAN","notanumber"), b"-ERR invalid cursor", "invalid cursor")
        eq(c.do("SCAN","0","COUNT","abc"), b"-ERR value is not an integer or out of range", "count notint")
        eq(c.do("SCAN","0","COUNT","0"), b"-ERR syntax error", "count 0")
        eq(c.do("SCAN","0","BADOPT"), b"-ERR syntax error", "badopt")
        eq(c.do("SCAN","0","COUNT"), b"-ERR syntax error", "count missing")
        eq(c.do("SCAN"), b"-ERR wrong number of arguments for 'scan' command", "arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL scan: %r"%e); return 1
    if FAILS:
        print("FAIL scan:"); [print("  "+f) for f in FAILS]; return 1
    print("OK scan: cursor coverage + MATCH + errors conformant"); return 0
if __name__=="__main__": sys.exit(main())
