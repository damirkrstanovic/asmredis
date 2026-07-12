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

# --- regression: bulk-length integer overflow must not crash (remote SIGSEGV guard) ---
./asmredis 7777 & SRV=$!; sleep 0.3
printf '*1\r\n$18446744073709551614\r\n' | nc -q1 127.0.0.1 7777 >/dev/null 2>&1
sleep 0.1
# server must still be alive and answer a fresh PING
alive=$(printf '*1\r\n$4\r\nPING\r\n' | nc -q1 127.0.0.1 7777 | xxd -p)
kill $SRV 2>/dev/null
[ "$alive" = "2b504f4e470d0a" ] && echo "PASS overflow-guard" || { echo "FAIL overflow-guard: server died or wrong reply ($alive)"; exit 1; }

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
check LPUSH ml a b c
check LRANGE ml 0 -1
check RPUSH ml x y
check LRANGE ml 0 -1
check LLEN ml
check LPOP ml
check RPOP ml
check LRANGE ml 0 -1
check LLEN nope
check LPOP nope
check LRANGE nope 0 -1
check GET ml
check SET ml str
check GET ml
check LRANGE ml 0 -1
check LPUSH ml a
check LPUSH
check LRANGE ml 0
check LRANGE ml x 1
check RPUSH mk 1 2 3 4 5
check LRANGE mk 1 3
check LRANGE mk -2 -1
check LRANGE mk -100 100
check LPOP solo
check RPUSH solo only
check LPOP solo
check LLEN solo
check GET solo
check HSET hh f1 a f2 b f3 c
check HGETALL hh
check HSET hh f1 z f4 d
check HGETALL hh
check HGET hh f1
check HGET hh nope
check HLEN hh
check HEXISTS hh f2
check HEXISTS hh nope
check HKEYS hh
check HVALS hh
check HDEL hh f2 f3 nope
check HGETALL hh
check HLEN nokey
check HGET nokey f
check HGETALL nokey
check HKEYS nokey
check HVALS nokey
check HEXISTS nokey f
check GET hh
check LPUSH hh x
check HSET hh
check HSET hh onlyfield
check HSET
check HEXISTS hh
check HGETALL
check SET hs str
check HGET hs f
check HDEL solo2 f
check HSET solo2 f v
check HDEL solo2 f
check HLEN solo2
check GET solo2
check DEL c1
check INCR c1
check INCR c1
check INCRBY c1 10
check DECR c1
check DECRBY c1 4
check DECRBY c1 -2
check SET cmax 9223372036854775807
check INCR cmax
check SET cbad abc
check INCR cbad
check SET clz 011
check INCR clz
check INCRBY cbad notanint
check DECRBY c1 -9223372036854775808
check SET cmin -9223372036854775807
check DECR cmin
check INCR cmin
check RPUSH clist a
check INCR clist
check INCR
check INCRBY k1
check DECRBY k1
check TYPE cmax
check TYPE clist
check HSET chash f v
check TYPE chash
check TYPE cmissing
check EXISTS cmax cbad cmissing cmax
check EXISTS cmissing
check EXISTS
check TYPE
check TYPE a b
check SET ek v
check EXPIRE ek 100
check TTL ek
check EXPIRE nokey 100
check TTL nokey
check PTTL nokey
check SET nt2 v
check TTL nt2
check PERSIST ek
check PERSIST ek
check PERSIST nokey
check SET dk v
check EXPIREAT dk 1
check EXISTS dk
check TYPE dk
check GET dk
check TTL dk
check SET dk2 v
check PEXPIREAT dk2 1
check EXISTS dk2
check EXPIRE ek abc
check EXPIRE nokey abc
check EXPIRE ek 9999999999999999
check EXPIRE ek -9999999999999999
check EXPIREAT ek 9999999999999999
check EXPIRE
check TTL
check PERSIST
check PEXPIREAT ek
check DEL setk
check SADD setk a b c
check SADD setk a d
check SCARD setk
check SISMEMBER setk a
check SISMEMBER setk z
check SCARD setmiss
check SISMEMBER setmiss a
check SREM setk a z
check SCARD setk
check SMEMBERS setk
check SMEMBERS setmiss
check TYPE setk
check SADD
check SREM setk
check SCARD
check SISMEMBER setk
check SMEMBERS
check SET setstr v
check SADD setstr m
check SCARD setstr
check SET ko v EX 100
check TTL ko
check SET ko w KEEPTTL
check TTL ko
check SET ko v2
check TTL ko
check DEL kn
check SET kn v NX
check SET kn w NX
check GET kn
check SET kn z XX
check DEL km
check SET km v XX
check EXISTS km
check SET ko v EX abc
check SET ko v EX 0
check SET ko v EX -1
check SET ko v EX 100 PX 100
check SET ko v NX XX
check SET ko v BADOPT
check SET ko v EX
kill $SRV 2>/dev/null
valkey-cli -p 7778 shutdown nosave 2>/dev/null
[ "$fail" = "0" ] && echo "PASS conformance" || { echo "FAIL conformance"; exit 1; }

# --- Milestone C: concurrency — -c 50 must COMPLETE (milestone A stalled here) ---
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 30 valkey-benchmark -p 7777 -t set,get -n 20000 -c 50 -q >/tmp/asmc_bench.txt 2>/dev/null
bexit=$?
kill $SRV 2>/dev/null
if [ "$bexit" = "0" ] && grep -q 'requests per second' /tmp/asmc_bench.txt; then
  echo "PASS concurrency-c50"
else
  echo "FAIL concurrency-c50 (exit=$bexit): $(tr '\r' '\n' < /tmp/asmc_bench.txt | tail -2)"; exit 1
fi

# --- Milestone C: backpressure / EPOLLOUT path (slow reader, large-ish value) ---
./asmredis 7777 & SRV=$!; sleep 0.3
bigval=$(python3 -c "print('x'*4000, end='')")
if python3 tests/slow_reader.py 7777 500 "$bigval" >/tmp/asmc_slow.txt 2>&1; then
  echo "PASS backpressure"
else
  echo "FAIL backpressure: $(cat /tmp/asmc_slow.txt)"; kill $SRV 2>/dev/null; exit 1
fi
kill $SRV 2>/dev/null

# --- Milestone C: large (>16KB) replies under backpressure must not overflow write buffer ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/big_reply.py 7777 100 >/tmp/asmc_big.txt 2>&1; then
  echo "PASS big-reply-backpressure"
else
  echo "FAIL big-reply-backpressure: $(cat /tmp/asmc_big.txt)"; kill $SRV 2>/dev/null; exit 1
fi
kill $SRV 2>/dev/null

# --- Milestone C: heavier concurrency (-c 200) still completes ---
./asmredis 7777 & SRV=$!; sleep 0.3
timeout 40 valkey-benchmark -p 7777 -t set,get -n 40000 -c 200 -q >/tmp/asmc_b200.txt 2>/dev/null
b2=$?
# --- fd-leak: many short-lived connections; server fd count returns to baseline ---
base=$(ls /proc/$SRV/fd 2>/dev/null | wc -l)
for i in $(seq 1 200); do valkey-cli -p 7777 PING >/dev/null 2>&1; done
sleep 0.3
after=$(ls /proc/$SRV/fd 2>/dev/null | wc -l)
kill $SRV 2>/dev/null
if [ "$b2" = "0" ] && grep -q 'requests per second' /tmp/asmc_b200.txt; then echo "PASS concurrency-c200"; else echo "FAIL concurrency-c200 (exit=$b2)"; exit 1; fi
if [ "$after" -le $((base + 3)) ]; then echo "PASS no-fd-leak (base=$base after=$after)"; else echo "FAIL no-fd-leak (base=$base after=$after)"; exit 1; fi

# --- Milestone B: overwrite reclamation (10k x 16KB through a 64MB arena) ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 overwrite >/tmp/asmb_ow.txt 2>&1; then
  echo "PASS reclaim-overwrite"; ow=0
else
  echo "FAIL reclaim-overwrite: $(cat /tmp/asmb_ow.txt)"; ow=1
fi
kill $SRV 2>/dev/null

# --- Milestone B: SET/DEL reclamation (10k cycles, no OOM) ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 del >/tmp/asmb_del.txt 2>&1; then
  echo "PASS reclaim-del"; dl=0
else
  echo "FAIL reclaim-del: $(cat /tmp/asmb_del.txt)"; dl=1
fi
kill $SRV 2>/dev/null

# --- Milestone B: arena exhaustion is reported as -ERR out of memory ---
./asmredis 7777 & SRV=$!; sleep 0.3
if python3 tests/reclaim.py 7777 oom >/tmp/asmb_oom.txt 2>&1; then
  echo "PASS oom-error"; oo=0
else
  echo "FAIL oom-error: $(cat /tmp/asmb_oom.txt)"; oo=1
fi
# Reap the oom server (it fully committed the 64 MB arena; SIGTERM teardown can
# take >0.3s) so it releases port 7777 before the next server binds. Without the
# wait, the following bind() races the dying socket and fails with EADDRINUSE.
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $((ow + dl + oo)) -eq 0 ] || exit 1

# --- Milestone D: rehash correctness (50k keys across many resizes) ---
./asmredis 7777 & SRV=$!
# Wait until the server is actually accepting on 7777 (readiness, not a fixed
# sleep) so the client never races startup.
for _i in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 0.1
done
if timeout 60 python3 tests/rehash.py 7777 >/tmp/asmd_rehash.txt 2>&1; then
  echo "PASS rehash-correctness"; rh=0
else
  echo "FAIL rehash-correctness: $(cat /tmp/asmd_rehash.txt)"; rh=1
fi
kill $SRV 2>/dev/null

[ $rh -eq 0 ] || exit 1

# --- Milestone E: LIST stress + leak ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/list.py 7777 >/tmp/asme_list.txt 2>&1; then
  echo "PASS list-stress"; ls=0
else
  echo "FAIL list-stress: $(cat /tmp/asme_list.txt)"; ls=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ls -eq 0 ] || exit 1

# --- Milestone F: HASH stress + leak ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/hash.py 7777 >/tmp/asmf_hash.txt 2>&1; then
  echo "PASS hash-stress"; hs=0
else
  echo "FAIL hash-stress: $(cat /tmp/asmf_hash.txt)"; hs=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $hs -eq 0 ] || exit 1

# --- Milestone G: large replies under backpressure + cross-connection integrity ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/big_reply2.py 7777 >/tmp/asmg_big.txt 2>&1; then
  echo "PASS big-reply-grow"; bg=0
else
  echo "FAIL big-reply-grow: $(cat /tmp/asmg_big.txt)"; bg=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $bg -eq 0 ] || exit 1

# --- SIGPIPE hardening: broken-pipe write must not kill the server ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/sigpipe.py 7777 >/tmp/asm_sigpipe.txt 2>&1; then
  echo "PASS sigpipe"; sp=0
else
  echo "FAIL sigpipe: $(cat /tmp/asm_sigpipe.txt)"; sp=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $sp -eq 0 ] || exit 1

# --- Milestone H: counters + EXISTS/TYPE exact-byte conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/counter.py 7777 >/tmp/asmh_counter.txt 2>&1; then
  echo "PASS counter"; ct=0
else
  echo "FAIL counter: $(cat /tmp/asmh_counter.txt)"; ct=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ct -eq 0 ] || exit 1

# --- Milestone I: TTL family conformance + real-time expiry ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/expire.py 7777 >/tmp/asmi_expire.txt 2>&1; then
  echo "PASS expire"; ex=0
else
  echo "FAIL expire: $(cat /tmp/asmi_expire.txt)"; ex=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $ex -eq 0 ] || exit 1

# --- Milestone J: Sets conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/set.py 7777 >/tmp/asmj_set.txt 2>&1; then
  echo "PASS sets"; st=0
else
  echo "FAIL sets: $(cat /tmp/asmj_set.txt)"; st=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $st -eq 0 ] || exit 1

# --- Milestone K: SET options conformance ---
./asmredis 7777 & SRV=$!
for _i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/7777) 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
if timeout 60 python3 tests/setopt.py 7777 >/tmp/asmk_setopt.txt 2>&1; then
  echo "PASS setopt"; so=0
else
  echo "FAIL setopt: $(cat /tmp/asmk_setopt.txt)"; so=1
fi
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

[ $so -eq 0 ] || exit 1
