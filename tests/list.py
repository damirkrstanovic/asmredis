#!/usr/bin/env python3
# LIST stress + leak test. Usage: list.py <port>. Exit 0 ok / 1 fail.
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
    if len(sys.argv)!=2: print("usage: list.py <port>"); return 2
    port=int(sys.argv[1])
    try:
        s=connect(port); r=Reader(s)
        N=2000
        for i in range(N):
            s.sendall(cmd("RPUSH","L",b"v%d"%i))
            ln=r.line()
            if ln!=b":%d"%(i+1): print("FAIL RPUSH len %d -> %r"%(i,ln)); return 1
        s.sendall(cmd("LLEN","L"))
        if r.line()!=b":%d"%N: print("FAIL LLEN"); return 1
        s.sendall(cmd("LRANGE","L","0","-1"))
        arr=read_array(r)
        if arr!=[b"v%d"%i for i in range(N)]: print("FAIL LRANGE order"); return 1
        for i in range(N):
            s.sendall(cmd("LPOP","L")); v=read_bulk(r)
            if v!=b"v%d"%i: print("FAIL LPOP %d -> %r"%(i,v)); return 1
        s.sendall(cmd("LLEN","L"));  a=r.line()
        s.sendall(cmd("LPOP","L"));  b=read_bulk(r)
        if a!=b":0" or b is not None: print("FAIL auto-delete %r %r"%(a,b)); return 1
        BIG=b"x"*4000
        for rep in range(6000):
            s.sendall(cmd("LPUSH","C",BIG))
            if r.line()!=b":1": print("FAIL churn push %d"%rep); return 1
            s.sendall(cmd("RPOP","C"))
            if read_bulk(r)!=BIG: print("FAIL churn pop %d"%rep); return 1
        print("OK list: order/LLEN/auto-delete correct; %d churn cycles reclaimed"%6000)
        return 0
    except (EOFError,OSError,ValueError,AssertionError) as e:
        print("FAIL list: %r"%e); return 1

if __name__=="__main__": sys.exit(main())
