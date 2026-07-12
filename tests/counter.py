#!/usr/bin/env python3
# Milestone H counters: INCR/DECR/INCRBY/DECRBY exact RESP-byte conformance.
# EXISTS/TYPE assertions are added in the next task. Usage: counter.py <port>.
# Exit 0 ok / 1 fail.
import socket, sys

def conn(port):
    s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1",port)); s.settimeout(10); return s

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
        if t in (b"+",b"-",b":"): return h        # full framed line, prefix included
        if t==b"$":
            n=int(h[1:])
            if n<0: return h
            while len(s.b)<n+2: s._f()
            d=s.b[:n]; s.b=s.b[n+2:]; return d
        if t==b"*":
            return [s.reply() for _ in range(int(h[1:]))]
        raise ValueError("bad reply %r"%h)
    def do(s,*p):
        s.s.sendall(cmd(*p)); return s.reply()

FAILS=[]
def eq(got,want,label):
    if got!=want: FAILS.append("%s: got %r want %r"%(label,got,want))

NOTINT=b"-ERR value is not an integer or out of range"
IOVF=b"-ERR increment or decrement would overflow"
DOVF=b"-ERR decrement would overflow"
WT=b"-WRONGTYPE Operation against a key holding the wrong kind of value"
def wa(name): return b"-ERR wrong number of arguments for '%s' command"%name.encode()

def counters(c):
    eq(c.do("DEL","cnt"), b":0", "del cnt")
    eq(c.do("INCR","cnt"), b":1", "incr cnt 1")
    eq(c.do("INCR","cnt"), b":2", "incr cnt 2")
    eq(c.do("INCRBY","cnt","10"), b":12", "incrby 10")
    eq(c.do("DECR","cnt"), b":11", "decr")
    eq(c.do("DECRBY","cnt","5"), b":6", "decrby 5")
    eq(c.do("DECRBY","cnt","-4"), b":10", "decrby -4")     # 6 - (-4)
    eq(c.do("DEL","d"), b":0", "del d")                    # d absent -> :0 (valkey-verified)
    eq(c.do("DECR","d"), b":-1", "decr fresh -> -1")       # signed reply
    # overflow at INT64_MAX
    eq(c.do("SET","big","9223372036854775807"), b"+OK", "set big MAX")
    eq(c.do("INCR","big"), IOVF, "incr overflow")
    # value one past MAX is not a valid integer
    eq(c.do("SET","p","9223372036854775808"), b"+OK", "set p >MAX")
    eq(c.do("INCR","p"), NOTINT, "incr >MAX value notint")
    # non-integer value, leading zero, bad increment arg
    eq(c.do("SET","s","abc"), b"+OK", "set s abc")
    eq(c.do("INCR","s"), NOTINT, "incr non-int")
    eq(c.do("SET","lz","011"), b"+OK", "set lz 011")
    eq(c.do("INCR","lz"), NOTINT, "incr leading-zero")
    eq(c.do("SET","m","5"), b"+OK", "set m 5")
    eq(c.do("INCRBY","m","xx"), NOTINT, "incrby bad arg")
    # DECRBY LLONG_MIN arg -> distinct message; INCRBY LLONG_MIN arg is valid
    eq(c.do("SET","z","0"), b"+OK", "set z 0")
    eq(c.do("DECRBY","z","-9223372036854775808"), DOVF, "decrby LLONG_MIN")
    eq(c.do("SET","z2","0"), b"+OK", "set z2 0")
    eq(c.do("INCRBY","z2","-9223372036854775808"), b":-9223372036854775808", "incrby LLONG_MIN")
    # WRONGTYPE
    eq(c.do("DEL","L"), b":0", "del L")                    # L absent -> :0 (valkey-verified)
    eq(c.do("RPUSH","L","a"), b":1", "rpush L")
    eq(c.do("INCR","L"), WT, "incr wrongtype")
    # full-range round-trip through LLONG_MIN
    eq(c.do("SET","g","-9223372036854775807"), b"+OK", "set g MIN+1")
    eq(c.do("DECR","g"), b":-9223372036854775808", "decr to LLONG_MIN")
    eq(c.do("INCR","g"), b":-9223372036854775807", "incr back from LLONG_MIN")
    # arity
    eq(c.do("INCR"), wa("incr"), "incr arity0")
    eq(c.do("INCR","a","b"), wa("incr"), "incr arity3")
    eq(c.do("DECR"), wa("decr"), "decr arity0")
    eq(c.do("INCRBY","k"), wa("incrby"), "incrby arity")
    eq(c.do("DECRBY","k"), wa("decrby"), "decrby arity")

def generic(c):
    # TYPE across the three types + none, and after INCR (string)
    eq(c.do("SET","ts","v"), b"+OK", "set ts")
    eq(c.do("TYPE","ts"), b"+string", "type string")
    eq(c.do("DEL","tl"), b":0", "del tl")                 # tl absent -> :0
    eq(c.do("RPUSH","tl","a"), b":1", "rpush tl")
    eq(c.do("TYPE","tl"), b"+list", "type list")
    eq(c.do("DEL","th"), b":0", "del th")                 # th absent -> :0
    eq(c.do("HSET","th","f","v"), b":1", "hset th")
    eq(c.do("TYPE","th"), b"+hash", "type hash")
    eq(c.do("TYPE","nope"), b"+none", "type none")
    eq(c.do("DEL","ic"), b":0", "del ic")                 # ic absent -> :0
    eq(c.do("INCR","ic"), b":1", "incr ic")
    eq(c.do("TYPE","ic"), b"+string", "type after incr")
    # EXISTS: variadic, duplicates counted, missing skipped
    eq(c.do("SET","e1","1"), b"+OK", "set e1")
    eq(c.do("SET","e2","2"), b"+OK", "set e2")
    eq(c.do("DEL","e3"), b":0", "del e3")                 # e3 absent -> :0
    eq(c.do("EXISTS","e1","e2","e3","e1"), b":3", "exists variadic")
    eq(c.do("EXISTS","absent"), b":0", "exists missing")
    # arity
    eq(c.do("EXISTS"), wa("exists"), "exists arity")
    eq(c.do("TYPE"), wa("type"), "type arity0")
    eq(c.do("TYPE","a","b"), wa("type"), "type arity2")

def main():
    if len(sys.argv)<2: print("usage: counter.py <port>"); return 2
    port=int(sys.argv[1]); c=C(port)
    try:
        counters(c)
        generic(c)
    except (EOFError,OSError,ValueError) as e:
        print("FAIL counter: %r"%e); return 1
    if FAILS:
        print("FAIL counter:"); [print("  "+f) for f in FAILS]; return 1
    print("OK counter: INCR/DECR/INCRBY/DECRBY + EXISTS/TYPE conformant"); return 0

if __name__=="__main__": sys.exit(main())
