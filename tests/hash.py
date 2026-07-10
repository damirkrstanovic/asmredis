#!/usr/bin/env python3
# HASH stress + leak test. Usage: hash.py <port>. Exit 0 ok / 1 fail.
import socket, sys

def connect(port):
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(30); return s

class Reader:
    def __init__(self, s): self.s=s; self.buf=b""
    def _fill(self):
        c=self.s.recv(65536)
        if not c: raise EOFError("closed")
        self.buf+=c
    def line(self):
        while b"\r\n" not in self.buf: self._fill()
        l,self.buf=self.buf.split(b"\r\n",1); return l
    def read_n(self,n):
        while len(self.buf)<n: self._fill()
        o,self.buf=self.buf[:n],self.buf[n:]; return o

def cmd(*p):
    o=b"*%d\r\n"%len(p)
    for x in p:
        if isinstance(x,str): x=x.encode()
        o+=b"$%d\r\n%s\r\n"%(len(x),x)
    return o

def read_bulk(r):
    h=r.line(); assert h[:1]==b"$",h
    n=int(h[1:])
    if n<0: return None
    d=r.read_n(n); r.read_n(2); return d

def read_array(r):
    h=r.line(); assert h[:1]==b"*",h
    n=int(h[1:])
    return [read_bulk(r) for _ in range(n)]

def main():
    if len(sys.argv)!=2: print("usage: hash.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        s=connect(port); r=Reader(s)
        N=2000
        for i in range(N):
            s.sendall(cmd("HSET","H",b"f%d"%i,b"v%d"%i))
            ln=r.line()
            if ln!=b":1": print("FAIL HSET new f%d -> %r"%(i,ln)); return 1
        s.sendall(cmd("HLEN","H"))
        if r.line()!=b":%d"%N: print("FAIL HLEN"); return 1
        for i in range(N):
            s.sendall(cmd("HGET","H",b"f%d"%i)); v=read_bulk(r)
            if v!=b"v%d"%i: print("FAIL HGET f%d -> %r"%(i,v)); return 1
        s.sendall(cmd("HKEYS","H")); ks=read_array(r)
        if len(ks)!=N or set(ks)!={b"f%d"%i for i in range(N)}: print("FAIL HKEYS"); return 1
        s.sendall(cmd("HVALS","H")); vs=read_array(r)
        if len(vs)!=N or set(vs)!={b"v%d"%i for i in range(N)}: print("FAIL HVALS"); return 1
        s.sendall(cmd("HGETALL","H")); ga=read_array(r)
        if len(ga)!=2*N: print("FAIL HGETALL len %d"%len(ga)); return 1
        if dict(zip(ga[0::2],ga[1::2]))!={b"f%d"%i:b"v%d"%i for i in range(N)}:
            print("FAIL HGETALL pairs"); return 1
        s.sendall(cmd("HSET","H",b"f0",b"zzz"))
        if r.line()!=b":0": print("FAIL HSET overwrite count"); return 1
        s.sendall(cmd("HGET","H",b"f0"))
        if read_bulk(r)!=b"zzz": print("FAIL HSET overwrite value"); return 1
        for i in range(N):
            s.sendall(cmd("HDEL","H",b"f%d"%i))
            if r.line()!=b":1": print("FAIL HDEL f%d"%i); return 1
        s.sendall(cmd("HLEN","H")); a=r.line()
        s.sendall(cmd("GET","H")); g=read_bulk(r)   # auto-deleted -> nil, not WRONGTYPE
        if a!=b":0" or g is not None: print("FAIL auto-delete %r %r"%(a,g)); return 1
        BIG=b"x"*16000
        CYCLES=10000                 # 10000 * 16000 = 160MB through a 64MB arena
        for rep in range(CYCLES):
            s.sendall(cmd("HSET","C","fld",BIG))
            if r.line()!=b":1": print("FAIL churn hset %d"%rep); return 1
            s.sendall(cmd("HDEL","C","fld"))
            if r.line()!=b":1": print("FAIL churn hdel %d"%rep); return 1
        print("OK hash: %d fields correct; overwrite/HGETALL/auto-delete ok; %d churn reclaimed"%(N,CYCLES))
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL hash: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
