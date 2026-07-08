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

# --- Task 4: SET/GET/DEL semantics ---
./asmredis 7777 & SRV=$!; sleep 0.3
set1=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
geth=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n*2\r\n$3\r\nGET\r\n$1\r\nk\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
getm=$(printf '*2\r\n$3\r\nGET\r\n$4\r\nnope\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
del=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nabc\r\n*2\r\n$3\r\nDEL\r\n$1\r\nk\r\n*2\r\n$3\r\nDEL\r\n$1\r\nk\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
[ "$set1" = "2b4f4b0d0a" ]                   && echo "PASS set"      || { echo "FAIL set: $set1"; exit 1; }
[ "$geth" = "2b4f4b0d0a24330d0a6162630d0a" ]  && echo "PASS get-hit"  || { echo "FAIL get-hit: $geth"; exit 1; }
[ "$getm" = "242d310d0a" ]                    && echo "PASS get-miss" || { echo "FAIL get-miss: $getm"; exit 1; }
[ "$del" = "2b4f4b0d0a3a310d0a3a300d0a" ]     && echo "PASS del"      || { echo "FAIL del: $del"; exit 1; }

# --- Task 4b: hash-chain integrity in a SINGLE connection ---
# SET b 1, SET jz 2, SET se 3, GET b/jz/se, DEL jz (middle-of-chain unlink),
# GET jz (miss), GET b, GET se. All in one connection (shared keyspace state).
./asmredis 7777 & SRV=$!; sleep 0.3
chain=$(printf '*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n1\r\n*3\r\n$3\r\nSET\r\n$2\r\njz\r\n$1\r\n2\r\n*3\r\n$3\r\nSET\r\n$2\r\nse\r\n$1\r\n3\r\n*2\r\n$3\r\nGET\r\n$1\r\nb\r\n*2\r\n$3\r\nGET\r\n$2\r\njz\r\n*2\r\n$3\r\nGET\r\n$2\r\nse\r\n*2\r\n$3\r\nDEL\r\n$2\r\njz\r\n*2\r\n$3\r\nGET\r\n$2\r\njz\r\n*2\r\n$3\r\nGET\r\n$1\r\nb\r\n*2\r\n$3\r\nGET\r\n$2\r\nse\r\n' | nc -q1 127.0.0.1 7777 | xxd -p | tr -d '\n')
kill $SRV 2>/dev/null
exp="2b4f4b0d0a2b4f4b0d0a2b4f4b0d0a24310d0a310d0a24310d0a320d0a24310d0a330d0a3a310d0a242d310d0a24310d0a310d0a24310d0a330d0a"
[ "$chain" = "$exp" ] && echo "PASS chain" || { echo "FAIL chain: $chain"; exit 1; }

# --- Task 5: pipelining, split reads, protocol error, wrong argc ---
./asmredis 7777 & SRV=$!; sleep 0.3
pipe=$(printf '*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\r\n' | nc -q1 127.0.0.1 7777 | xxd -p | tr -d '\n')
split=$( { printf '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n'; sleep 0.3; printf '$3\r\nabc\r\n'; } | nc -q1 127.0.0.1 7777 | xxd -p | tr -d '\n')
perr=$(printf '@garbage\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r\n')
wa=$(printf '*1\r\n$3\r\nSET\r\n' | nc -q1 127.0.0.1 7777 | tr -d '\r\n')
kill $SRV 2>/dev/null
[ "$pipe" = "2b504f4e470d0a2b504f4e470d0a" ] && echo "PASS pipeline" || { echo "FAIL pipeline: $pipe"; exit 1; }
[ "$split" = "2b4f4b0d0a" ]                  && echo "PASS split"    || { echo "FAIL split: $split"; exit 1; }
[ "$perr" = "-ERR Protocol error" ]          && echo "PASS protoerr" || { echo "FAIL protoerr: $perr"; exit 1; }
[ "$wa" = "-ERR wrong number of arguments for 'set' command" ] && echo "PASS wrongargs" || { echo "FAIL wrongargs: $wa"; exit 1; }

# --- Task 6: full conformance diff against valkey oracle ---
valkey-server --port 7778 --save "" --appendonly no --daemonize yes --logfile /tmp/vk-oracle.log --dir /tmp
./asmredis 7777 & SRV=$!; sleep 0.3
fail=0
check() { m=$(valkey-cli -p 7777 "$@"); v=$(valkey-cli -p 7778 "$@"); if [ "$m" != "$v" ]; then echo "DIFF [$*] mine=<$m> valkey=<$v>"; fail=1; fi; }
check PING
check PING hello
check ECHO hello
check SET foo bar
check GET foo
check GET missing
check SET foo baz
check GET foo
check DEL foo
check DEL foo
check SET a 1
check SET b 2
check GET a
check GET b
check SET
check GET
check DEL
check ECHO
kill $SRV 2>/dev/null
valkey-cli -p 7778 shutdown nosave 2>/dev/null
[ "$fail" = "0" ] && echo "PASS conformance" || { echo "FAIL conformance"; exit 1; }
