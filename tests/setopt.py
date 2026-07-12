#!/usr/bin/env python3
# Milestone K: SET options (EX/PX/EXAT/PXAT/KEEPTTL/NX/XX). Usage: setopt.py <port>.
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
NOTINT=b"-ERR value is not an integer or out of range"
IEXP=b"-ERR invalid expire time in 'set' command"
SYN=b"-ERR syntax error"
def main():
    if len(sys.argv)<2: print("usage: setopt.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        # plain SET still works
        eq(c.do("SET","k","v"), b"+OK", "plain set")
        eq(c.do("GET","k"), b"v", "plain get")
        # EX / PX / TTL readback
        eq(c.do("SET","k","v","EX","100"), b"+OK", "set ex")
        eq(c.do("TTL","k"), b":100", "ttl after ex")
        eq(c.do("SET","k","v","PX","500000"), b"+OK", "set px")
        eq(c.do("TTL","k"), b":500", "ttl after px")
        # plain SET clears TTL; KEEPTTL preserves
        eq(c.do("SET","k","v2"), b"+OK", "reset"); eq(c.do("TTL","k"), b":-1", "plain clears ttl")
        c.do("SET","k","v","EX","100"); eq(c.do("SET","k","w","KEEPTTL"), b"+OK", "keepttl")
        eq(c.do("TTL","k"), b":100", "ttl kept")
        # EXAT future
        eq(c.do("SET","k","v","EXAT","99999999999"), b"+OK", "exat")
        eq(c.do("TTL","k")[:2], b":9", "exat ttl big")
        # NX / XX
        eq(c.do("DEL","n"), b":0", "del n")
        eq(c.do("SET","n","v","NX"), b"+OK", "nx new")
        eq(c.do("SET","n","w","NX"), b"$-1", "nx blocked")
        eq(c.do("GET","n"), b"v", "nx unchanged")
        eq(c.do("SET","n","z","XX"), b"+OK", "xx present")
        eq(c.do("GET","n"), b"z", "xx applied")
        eq(c.do("DEL","m"), b":0", "del m")
        eq(c.do("SET","m","v","XX"), b"$-1", "xx absent")
        eq(c.do("EXISTS","m"), b":0", "xx no create")
        # errors
        eq(c.do("SET","k","v","EX","abc"), NOTINT, "ex notint")
        eq(c.do("SET","k","v","EX","0"), IEXP, "ex 0")
        eq(c.do("SET","k","v","EX","-1"), IEXP, "ex -1")
        eq(c.do("SET","k","v","EX","100","PX","100"), SYN, "ex+px")
        eq(c.do("SET","k","v","NX","XX"), SYN, "nx+xx")
        eq(c.do("SET","k","v","EX","100","KEEPTTL"), SYN, "ex+keepttl")
        eq(c.do("SET","k","v","BADOPT"), SYN, "badopt")
        eq(c.do("SET","k","v","EX"), SYN, "ex missing arg")
        eq(c.do("SET","k"), b"-ERR wrong number of arguments for 'set' command", "arity")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL setopt: %r"%e); return 1
    if FAILS:
        print("FAIL setopt:"); [print("  "+f) for f in FAILS]; return 1
    print("OK setopt: SET options conformant"); return 0
if __name__=="__main__": sys.exit(main())
