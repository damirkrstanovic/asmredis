#!/usr/bin/env python3
# Milestone I: EXPIRE/PEXPIRE/EXPIREAT/PEXPIREAT/TTL/PTTL/PERSIST conformance.
# Deterministic cases use past absolute timestamps (no sleep); one real-time
# check polls a short PEXPIRE. Usage: expire.py <port>. Exit 0 ok / 1 fail.
import socket, sys, time

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
def iexp(n): return b"-ERR invalid expire time in '%s' command"%n.encode()
def wa(n): return b"-ERR wrong number of arguments for '%s' command"%n.encode()

def main():
    if len(sys.argv)<2: print("usage: expire.py <port>"); return 2
    c=C(int(sys.argv[1]))
    try:
        eq(c.do("SET","foo","bar"), b"+OK", "set foo")
        eq(c.do("EXPIRE","foo","100"), b":1", "expire foo")
        eq(c.do("TTL","foo"), b":100", "ttl foo")
        eq(c.do("EXPIRE","nope","100"), b":0", "expire missing")
        eq(c.do("SET","nt","v"), b"+OK", "set nt")
        eq(c.do("TTL","nt"), b":-1", "ttl no-ttl")
        eq(c.do("TTL","gone"), b":-2", "ttl missing")
        eq(c.do("PTTL","gone"), b":-2", "pttl missing")
        eq(c.do("PERSIST","foo"), b":1", "persist had-ttl")
        eq(c.do("PERSIST","foo"), b":0", "persist no-ttl")
        eq(c.do("PERSIST","gone"), b":0", "persist missing")
        eq(c.do("SET","d1","v"), b"+OK", "set d1"); eq(c.do("EXPIRE","d1","-1"), b":1", "expire -1")
        eq(c.do("GET","d1"), b"$-1", "d1 gone"); eq(c.do("TTL","d1"), b":-2", "ttl d1 -2")
        eq(c.do("SET","d2","v"), b"+OK", "set d2"); eq(c.do("EXPIRE","d2","0"), b":1", "expire 0")
        eq(c.do("EXISTS","d2"), b":0", "d2 gone")
        eq(c.do("SET","d3","v"), b"+OK", "set d3"); eq(c.do("EXPIREAT","d3","1"), b":1", "expireat past")
        eq(c.do("EXISTS","d3"), b":0", "d3 gone"); eq(c.do("TYPE","d3"), b"+none", "type d3 none")
        eq(c.do("SET","d4","v"), b"+OK", "set d4"); eq(c.do("PEXPIREAT","d4","1"), b":1", "pexpireat past")
        eq(c.do("EXISTS","d4"), b":0", "d4 gone")
        eq(c.do("SET","s1","v"), b"+OK","s1"); c.do("EXPIRE","s1","100"); eq(c.do("SET","s1","v2"), b"+OK","reset s1"); eq(c.do("TTL","s1"), b":-1", "set clears ttl")
        eq(c.do("SET","n1","1"), b"+OK","n1"); c.do("EXPIRE","n1","100"); c.do("INCR","n1"); eq(c.do("TTL","n1"), b":100", "incr keeps ttl")
        c.do("DEL","l1"); c.do("RPUSH","l1","a"); c.do("EXPIRE","l1","100"); c.do("RPUSH","l1","b"); eq(c.do("TTL","l1"), b":100", "rpush keeps ttl")
        c.do("DEL","h1"); c.do("HSET","h1","f","v"); c.do("EXPIRE","h1","100"); c.do("HSET","h1","g","w"); eq(c.do("TTL","h1"), b":100", "hset keeps ttl")
        eq(c.do("SET","r1","v"), b"+OK","r1"); eq(c.do("PEXPIRE","r1","600000"), b":1","pexpire r1"); eq(c.do("TTL","r1"), b":600", "pexpire 600000 -> ttl 600")
        eq(c.do("EXPIRE","foo","abc"), NOTINT, "expire notint")
        eq(c.do("EXPIRE","nope","abc"), NOTINT, "expire notint before key-check")
        eq(c.do("EXPIRE","foo","9999999999999999"), iexp("expire"), "expire overflow")
        eq(c.do("EXPIRE","foo","-9999999999999999"), iexp("expire"), "expire neg-overflow")
        eq(c.do("PEXPIRE","foo","9223372036854775807"), iexp("pexpire"), "pexpire base-overflow")
        eq(c.do("EXPIREAT","foo","9999999999999999"), iexp("expireat"), "expireat overflow")
        eq(c.do("EXPIRE"), wa("expire"), "expire arity")
        eq(c.do("TTL"), wa("ttl"), "ttl arity")
        eq(c.do("PERSIST"), wa("persist"), "persist arity")
        eq(c.do("PEXPIREAT","foo"), wa("pexpireat"), "pexpireat arity")
        eq(c.do("SET","rt","v"), b"+OK","rt"); c.do("PEXPIRE","rt","150")
        gone=False; deadline=time.time()+3
        while time.time()<deadline:
            if c.do("GET","rt")==b"$-1": gone=True; break
            time.sleep(0.05)
        if not gone: FAILS.append("real-time expiry: key did not expire within 3s")
    except (EOFError,OSError,ValueError) as e:
        print("FAIL expire: %r"%e); return 1
    if FAILS:
        print("FAIL expire:"); [print("  "+f) for f in FAILS]; return 1
    print("OK expire: TTL family conformant"); return 0

if __name__=="__main__": sys.exit(main())
