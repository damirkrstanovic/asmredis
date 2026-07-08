#!/usr/bin/env bash
set -u
make -s clean all || { echo "BUILD FAILED"; exit 1; }
out=$(./asmredis --banner 2>/dev/null)
if [ "$out" = "asmredis" ]; then echo "PASS banner"; else echo "FAIL banner: got '$out'"; exit 1; fi

# --- Task 2: server answers +PONG to any bytes ---
./asmredis 7777 & SRV=$!
sleep 0.3
resp=$(printf 'x' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
if [ "$resp" = "2b504f4e470d0a" ]; then echo "PASS pong-skeleton"; else echo "FAIL pong-skeleton: $resp"; exit 1; fi
