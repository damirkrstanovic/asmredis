#!/usr/bin/env bash
set -u
make -s clean && make -s all || { echo "BUILD FAILED"; exit 1; }
out=$(./asmredis --banner 2>/dev/null)
if [ "$out" = "asmredis" ]; then echo "PASS banner"; else echo "FAIL banner: got '$out'"; exit 1; fi

# --- Task 2: server answers +PONG to a PING array ---
./asmredis 7777 & SRV=$!
sleep 0.3
resp=$(printf '*1\r\n$4\r\nPING\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
if [ "$resp" = "2b504f4e470d0a" ]; then echo "PASS pong-skeleton"; else echo "FAIL pong-skeleton: $resp"; exit 1; fi

# --- Task 3: PING/ECHO/unknown via RESP arrays ---
./asmredis 7777 & SRV=$!; sleep 0.3
ping=$(printf '*1\r\n$4\r\nPING\r\n'         | nc -q1 127.0.0.1 7777 | xxd -p)
echo1=$(printf '*2\r\n$4\r\nECHO\r\n$5\r\nhello\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
unk=$(printf '*3\r\n$3\r\nFOO\r\n$1\r\na\r\n$1\r\nb\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r' | head -c 40)
kill $SRV 2>/dev/null
[ "$ping" = "2b504f4e470d0a" ]              && echo "PASS ping" || { echo "FAIL ping: $ping"; exit 1; }
[ "$echo1" = "24350d0a68656c6c6f0d0a" ]      && echo "PASS echo" || { echo "FAIL echo: $echo1"; exit 1; }
case "$unk" in "-ERR unknown command 'FOO'"*) echo "PASS unknown";; *) echo "FAIL unknown: $unk"; exit 1;; esac
