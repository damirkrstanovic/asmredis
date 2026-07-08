#!/usr/bin/env bash
set -u
make -s clean all || { echo "BUILD FAILED"; exit 1; }
out=$(./asmredis --banner 2>/dev/null)
if [ "$out" = "asmredis" ]; then echo "PASS banner"; else echo "FAIL banner: got '$out'"; exit 1; fi
