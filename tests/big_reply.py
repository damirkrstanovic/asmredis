#!/usr/bin/env python3
# Large-reply backpressure regression.
#
# Pipelines M unknown commands whose name is ~16370 bytes. Each request is
# exactly 16384 bytes (fills the read buffer); each reply
#   -ERR unknown command '<name>', with args beginning with: \r\n
# is 16423 bytes -- LARGER than the 16 KiB read-buffer slot. The replies are
# read slowly (small SO_RCVBUF + paced reads) so the server's send buffer fills
# and every >16 KiB reply must be STASHED into its per-conn write buffer and
# replayed via the EPOLLOUT / on_writable path.
#
# If the write slot were only 16384 bytes (like the read slot), stashing a
# 16423-byte reply overflows its slot. With WRITE_BUF_SIZE = 32768 it fits with
# margin. This exercises the stash/replay of >16 KiB replies end to end and
# verifies every reply byte is delivered exactly and in order, and the server
# survives.
import socket, sys, time
port = int(sys.argv[1]); m = int(sys.argv[2])
name = b"Z" * 16370
one_req = b"*1\r\n$%d\r\n%s\r\n" % (len(name), name)                            # 16384 bytes
exp = b"-ERR unknown command '" + name + b"', with args beginning with: \r\n"   # 16423 bytes
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)   # small window -> quick backpressure
s.connect(("127.0.0.1", port))
s.sendall(one_req * m)                                      # all requests up front
want = exp * m
got = b""
while len(got) < len(want):
    time.sleep(0.003)                                      # slower than the server produces
    chunk = s.recv(8192)
    if not chunk:
        print("EOF at %d/%d bytes (server crashed -> overflow)" % (len(got), len(want)))
        sys.exit(1)
    got += chunk
s.close()
if got == want:
    print("OK big-reply %d replies (%d bytes each)" % (m, len(exp))); sys.exit(0)
else:
    j = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]),
             min(len(got), len(want)))
    print("MISMATCH at byte %d: got %r want %r (got %d/%d)" %
          (j, got[j:j+16], want[j:j+16], len(got), len(want)))
    sys.exit(1)
