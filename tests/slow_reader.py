#!/usr/bin/env python3
# Sends N pipelined GETs for a pre-set key, then reads replies SLOWLY in small
# chunks with delays, forcing the server's send buffer to fill and exercising the
# EPOLLOUT backpressure path. Verifies every reply byte is correct and in order.
import socket, sys, time
port = int(sys.argv[1]); n = int(sys.argv[2]); val = sys.argv[3].encode()
s = socket.create_connection(("127.0.0.1", port))
s.sendall(b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$%d\r\n%s\r\n" % (len(val), val))
assert s.recv(64).startswith(b"+OK"), "SET failed"
req = b"*2\r\n$3\r\nGET\r\n$1\r\nk\r\n" * n
s.sendall(req)
want = (b"$%d\r\n%s\r\n" % (len(val), val)) * n
got = b""
while len(got) < len(want):
    time.sleep(0.005)
    chunk = s.recv(256)
    if not chunk: break
    got += chunk
s.close()
if got == want:
    print("OK slow-reader %d replies" % n); sys.exit(0)
else:
    print("MISMATCH got %d want %d bytes" % (len(got), len(want))); sys.exit(1)
