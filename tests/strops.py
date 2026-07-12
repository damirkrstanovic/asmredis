#!/usr/bin/env python3
# Milestone L: SETNX/GETSET/APPEND/STRLEN/MSET/MGET. Usage: strops.py <port>.
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
    if len(sys.argv)<2: print("usage: strops.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # SETNX
        eq(c.do("DEL","k"), b":0", "del k")
        eq(c.do("SETNX","k","v"), b":1", "setnx new")
        eq(c.do("SETNX","k","w"), b":0", "setnx exists")
        eq(c.do("GET","k"), b"v", "setnx unchanged")
        # GETSET
        eq(c.do("GETSET","k","new"), b"v", "getset old")
        eq(c.do("GET","k"), b"new", "getset applied")
        eq(c.do("DEL","fr"), b":0","del fr"); eq(c.do("GETSET","fr","v"), b"$-1", "getset missing")
        eq(c.do("DEL","L"), b":0","del L"); eq(c.do("RPUSH","L","a"), b":1","rpush L")
        eq(c.do("GETSET","L","v"), WT, "getset wrongtype")
        # APPEND
        eq(c.do("DEL","a"), b":0","del a")
        eq(c.do("APPEND","a","hello"), b":5", "append new")
        eq(c.do("APPEND","a","world"), b":10", "append more")
        eq(c.do("GET","a"), b"helloworld", "append value")
        eq(c.do("APPEND","L","x"), WT, "append wrongtype")
        # APPEND preserves TTL
        eq(c.do("SET","at","v"), b"+OK","set at"); c.do("EXPIRE","at","100"); c.do("APPEND","at","x")
        eq(c.do("TTL","at"), b":100", "append keeps ttl")
        # STRLEN
        eq(c.do("SET","s","hello"), b"+OK","set s"); eq(c.do("STRLEN","s"), b":5", "strlen")
        eq(c.do("STRLEN","nope"), b":0", "strlen missing")
        eq(c.do("STRLEN","L"), WT, "strlen wrongtype")
        # MSET / MGET
        eq(c.do("MSET","x","1","y","2","z","3"), b"+OK", "mset")
        eq(c.do("MGET","x","y","nope","L"), [b"1",b"2",b"$-1",b"$-1"], "mget mixed")
        eq(c.do("MSET","x","1","y"), wa("mset"), "mset odd")
        # arity
        eq(c.do("SETNX","k"), wa("setnx"), "setnx arity")
        eq(c.do("GETSET","k"), wa("getset"), "getset arity")
        eq(c.do("APPEND","k"), wa("append"), "append arity")
        eq(c.do("STRLEN"), wa("strlen"), "strlen arity")
        eq(c.do("MGET"), wa("mget"), "mget arity")
        eq(c.do("MSET"), wa("mset"), "mset arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL strops: %r"%e); return 1
    if FAILS:
        print("FAIL strops:"); [print("  "+f) for f in FAILS]; return 1
    print("OK strops: SETNX/GETSET/APPEND/STRLEN/MSET/MGET conformant"); return 0
if __name__=="__main__": sys.exit(main())
