#!/usr/bin/env python3
# Milestone J: SADD/SREM/SMEMBERS/SISMEMBER/SCARD conformance. Usage: set.py <port>.
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
            if n<0: return h
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*": return [s.reply() for _ in range(int(h[1:]))]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()
FAILS=[]
def eq(g,w,l):
    if g!=w: FAILS.append("%s: got %r want %r"%(l,g,w))
WT=b"-WRONGTYPE Operation against a key holding the wrong kind of value"
def wa(n): return b"-ERR wrong number of arguments for '%s' command"%n.encode()
def main():
    if len(sys.argv)<2: print("usage: set.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        eq(c.do("DEL","s"), b":0", "del s")
        eq(c.do("SADD","s","a","b","c"), b":3", "sadd 3")
        eq(c.do("SADD","s","a","d"), b":1", "sadd dup+1")
        eq(c.do("SCARD","s"), b":4", "scard 4")
        eq(c.do("SISMEMBER","s","a"), b":1", "sismember hit")
        eq(c.do("SISMEMBER","s","z"), b":0", "sismember miss")
        eq(c.do("SCARD","nope"), b":0", "scard missing")
        eq(c.do("SISMEMBER","nope","a"), b":0", "sismember missing")
        eq(c.do("SREM","s","a","z"), b":1", "srem 1")
        eq(c.do("SCARD","s"), b":3", "scard after srem")
        # SMEMBERS content (order-independent compare)
        m=c.do("SMEMBERS","s")
        eq(sorted(m), sorted([b"b",b"c",b"d"]), "smembers content")
        eq(c.do("SMEMBERS","nope"), [], "smembers missing -> empty")
        # auto-delete on empty
        eq(c.do("DEL","s2"), b":0", "del s2"); eq(c.do("SADD","s2","only"), b":1", "sadd s2")
        eq(c.do("SREM","s2","only"), b":1", "srem last")
        eq(c.do("EXISTS","s2"), b":0", "s2 gone"); eq(c.do("TYPE","s2"), b"+none", "type s2 none")
        # type + WRONGTYPE
        eq(c.do("DEL","s3"), b":0","del s3"); eq(c.do("SADD","s3","x"), b":1","sadd s3")
        eq(c.do("TYPE","s3"), b"+set", "type set")
        eq(c.do("SET","str","v"), b"+OK","set str"); eq(c.do("SADD","str","m"), WT, "sadd wrongtype")
        eq(c.do("GET","s3"), WT, "get on set wrongtype")
        eq(c.do("SCARD","str"), WT, "scard wrongtype")
        eq(c.do("SMEMBERS","str"), WT, "smembers wrongtype")
        # arity
        eq(c.do("SADD","s3"), wa("sadd"), "sadd arity")
        eq(c.do("SREM","s3"), wa("srem"), "srem arity")
        eq(c.do("SISMEMBER","s3"), wa("sismember"), "sismember arity")
        eq(c.do("SCARD"), wa("scard"), "scard arity")
        eq(c.do("SMEMBERS"), wa("smembers"), "smembers arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL set: %r"%e); return 1
    if FAILS:
        print("FAIL set:"); [print("  "+f) for f in FAILS]; return 1
    print("OK set: SADD/SREM/SMEMBERS/SISMEMBER/SCARD conformant"); return 0
if __name__=="__main__": sys.exit(main())
