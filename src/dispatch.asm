%include "syscalls.inc"
global dispatch
extern argc, argv_ptrs, argv_lens
extern to_upper_buf, memcmp_n
extern reply_simple, reply_bulk, reply_null, reply_int, append_raw
extern ks_set, ks_del, ks_lookup
extern emit_wrongargs, emit_wrongtype, emit_oom
extern cmd_lpush, cmd_rpush, cmd_lpop, cmd_rpop, cmd_llen, cmd_lrange
extern cmd_hset, cmd_hget, cmd_hdel, cmd_hgetall, cmd_hlen
extern cmd_hexists, cmd_hkeys, cmd_hvals
extern cmd_incr, cmd_decr, cmd_incrby, cmd_decrby
extern cmd_expire, cmd_pexpire, cmd_expireat, cmd_pexpireat, cmd_ttl, cmd_pttl, cmd_persist
extern cmd_sadd, cmd_srem, cmd_sismember, cmd_scard, cmd_smembers
extern cmd_set
extern cmd_setnx, cmd_getset, cmd_append, cmd_strlen, cmd_mset, cmd_mget
extern cmd_scan

section .rodata
s_pong:     db "PONG"
s_pong_len  equ $ - s_pong
name_ping:  db "PING"
name_echo:  db "ECHO"
name_set:   db "SET"
name_get:   db "GET"
name_del:   db "DEL"
name_lpush:  db "LPUSH"
name_rpush:  db "RPUSH"
name_lpop:   db "LPOP"
name_rpop:   db "RPOP"
name_llen:   db "LLEN"
name_lrange: db "LRANGE"
name_hset:    db "HSET"
name_hget:    db "HGET"
name_hdel:    db "HDEL"
name_hlen:    db "HLEN"
name_hkeys:   db "HKEYS"
name_hvals:   db "HVALS"
name_hgetall: db "HGETALL"
name_hexists: db "HEXISTS"
name_incr:    db "INCR"
name_decr:    db "DECR"
name_incrby:  db "INCRBY"
name_decrby:  db "DECRBY"
name_exists:  db "EXISTS"
name_type:    db "TYPE"
name_ttl:       db "TTL"
name_pttl:      db "PTTL"
name_expire:    db "EXPIRE"
name_pexpire:   db "PEXPIRE"
name_persist:   db "PERSIST"
name_expireat:  db "EXPIREAT"
name_pexpireat: db "PEXPIREAT"
name_sadd:      db "SADD"
name_srem:      db "SREM"
name_scard:     db "SCARD"
name_smembers:  db "SMEMBERS"
name_sismember: db "SISMEMBER"
name_mset:   db "MSET"
name_mget:   db "MGET"
name_setnx:  db "SETNX"
name_getset: db "GETSET"
name_append: db "APPEND"
name_strlen: db "STRLEN"
name_scan:   db "SCAN"
lc_exists:    db "exists"
lc_type:      db "type"
t_string:     db "string"
t_list:       db "list"
t_hash:       db "hash"
t_set:        db "set"
t_none:       db "none"
uk_pre:     db "-ERR unknown command '"
uk_pre_len  equ $ - uk_pre
uk_mid:     db "', with args beginning with: "
uk_mid_len  equ $ - uk_mid
ap:         db "'"
ap_sp:      db "' "
crlf2:      db 13, 10
lc_get:     db "get"
lc_del:     db "del"
lc_echo:    db "echo"

section .bss
cmd_upper:  resb 16

section .text
dispatch:
    mov     rax, [rel argc]
    test    rax, rax
    je      .done
    mov     rax, [rel argv_lens]        ; len of argv0
    cmp     rax, 16
    ja      emit_unknown                ; too long to be a known command
    ; copy argv0 -> cmd_upper (rep movsb: rsi=src, rdi=dest, rcx=count)
    mov     rsi, [rel argv_ptrs]
    lea     rdi, [rel cmd_upper]
    mov     rcx, rax
    rep     movsb
    lea     rdi, [rel cmd_upper]
    mov     rsi, rax
    push    rax                         ; preserve len across to_upper_buf
    call    to_upper_buf
    pop     rax
    cmp     rax, 4
    je      .len4
    cmp     rax, 3
    je      .len3
    cmp     rax, 5
    je      .len5
    cmp     rax, 6
    je      .len6
    cmp     rax, 7
    je      .len7
    cmp     rax, 8
    je      .len8
    cmp     rax, 9
    je      .len9
    jmp     emit_unknown
.len4:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_ping]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_ping
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_echo]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_echo
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lpop]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_lpop
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_rpop]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_rpop
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_llen]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_llen
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hget]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hget
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hset]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hset
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hdel]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hdel
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hlen]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_hlen
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_incr]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_incr
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_decr]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_decr
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_type]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_type
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pttl]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_pttl
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_sadd]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_sadd
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_srem]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_srem
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_mset]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_mset
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_mget]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_mget
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_scan]
    mov     rdx, 4
    call    memcmp_n
    test    rax, rax
    je      cmd_scan
    jmp     emit_unknown
.len3:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_set]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_set
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_get]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_get
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_del]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_del
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_ttl]
    mov     rdx, 3
    call    memcmp_n
    test    rax, rax
    je      cmd_ttl
    jmp     emit_unknown
.len5:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lpush]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_lpush
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_rpush]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_rpush
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hkeys]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_hkeys
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hvals]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_hvals
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_scard]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_scard
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_setnx]
    mov     rdx, 5
    call    memcmp_n
    test    rax, rax
    je      cmd_setnx
    jmp     emit_unknown
.len6:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lrange]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_lrange
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_incrby]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_incrby
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_decrby]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_decrby
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_exists]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_exists
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_expire]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_expire
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_getset]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_getset
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_append]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_append
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_strlen]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_strlen
    jmp     emit_unknown
.len7:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hgetall]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_hgetall
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_hexists]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_hexists
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pexpire]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_pexpire
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_persist]
    mov     rdx, 7
    call    memcmp_n
    test    rax, rax
    je      cmd_persist
    jmp     emit_unknown
.len8:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_expireat]
    mov     rdx, 8
    call    memcmp_n
    test    rax, rax
    je      cmd_expireat
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_smembers]
    mov     rdx, 8
    call    memcmp_n
    test    rax, rax
    je      cmd_smembers
    jmp     emit_unknown
.len9:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_pexpireat]
    mov     rdx, 9
    call    memcmp_n
    test    rax, rax
    je      cmd_pexpireat
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_sismember]
    mov     rdx, 9
    call    memcmp_n
    test    rax, rax
    je      cmd_sismember
    jmp     emit_unknown
.done:
    ret

cmd_ping:
    cmp     qword [rel argc], 2
    je      .arg
    lea     rdi, [rel s_pong]
    mov     rsi, s_pong_len
    call    reply_simple
    ret
.arg:
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    reply_bulk
    ret

cmd_echo:
    cmp     qword [rel argc], 2
    jne     .wa
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    reply_bulk
    ret
.wa:
    lea     rdi, [rel lc_echo]
    mov     rsi, 4
    sub     rsp, 8                      ; entered at rsp%16==8 -> align call to 0
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_get: GET key -> bulk value, $-1 on miss, WRONGTYPE if not a string.
cmd_get:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup                   ; rax = entry or 0
    test    rax, rax
    je      .miss
    cmp     qword [rax+40], TYPE_STR
    jne     .wrongtype
    mov     rdi, [rax+24]               ; val_ptr
    mov     rsi, [rax+32]               ; val_len
    call    reply_bulk
    add     rsp, 8
    ret
.miss:
    call    reply_null
    add     rsp, 8
    ret
.wrongtype:
    call    emit_wrongtype
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_get]
    mov     rsi, 3
    sub     rsp, 8                      ; entered at rsp%16==8 -> align call to 0
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_del: DEL key -> :1 if deleted, :0 if absent.
cmd_del:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_del                      ; rax = 1 or 0
    mov     rdi, rax
    call    reply_int
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_del]
    mov     rsi, 3
    sub     rsp, 8                      ; entered at rsp%16==8 -> align call to 0
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_exists: EXISTS key [key ...] -> :<count>. Each argument looked up
; independently; duplicates counted, missing skipped.
;   rbx = index i, r13 = count.
cmd_exists:
    cmp     qword [rel argc], 2
    jl      .wa
    push    rbx
    push    r13
    sub     rsp, 8                   ; 2 push + 8 -> ==0 at calls
    mov     rbx, 1                   ; i = 1
    xor     r13, r13                 ; count = 0
.loop:
    cmp     rbx, [rel argc]
    jae     .fin
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    call    ks_lookup
    test    rax, rax
    jz      .next
    inc     r13
.next:
    inc     rbx
    jmp     .loop
.fin:
    mov     rdi, r13
    call    reply_int
    add     rsp, 8
    pop     r13
    pop     rbx
    ret
.wa:
    lea     rdi, [rel lc_exists]
    mov     rsi, 6
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; cmd_type: TYPE key -> +string / +list / +hash / +none. Never WRONGTYPE.
cmd_type:
    cmp     qword [rel argc], 2
    jne     .wa
    sub     rsp, 8                   ; align calls
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    ks_lookup
    test    rax, rax
    jz      .none
    mov     rax, [rax+40]            ; type
    cmp     rax, TYPE_STR
    je      .str
    cmp     rax, TYPE_LIST
    je      .list
    cmp     rax, TYPE_SET
    je      .set
    lea     rdi, [rel t_hash]        ; TYPE_HASH
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.set:
    lea     rdi, [rel t_set]
    mov     rsi, 3
    call    reply_simple
    add     rsp, 8
    ret
.str:
    lea     rdi, [rel t_string]
    mov     rsi, 6
    call    reply_simple
    add     rsp, 8
    ret
.list:
    lea     rdi, [rel t_list]
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.none:
    lea     rdi, [rel t_none]
    mov     rsi, 4
    call    reply_simple
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_type]
    mov     rsi, 4
    sub     rsp, 8
    call    emit_wrongargs
    add     rsp, 8
    ret

; emit_unknown: append the valkey-exact unknown-command error to the reply buffer.
;   -ERR unknown command '<argv0>', with args beginning with: '<a1>' '<a2>' \r\n
; Uses rbx (callee-saved) for the loop index because append_raw clobbers r10.
emit_unknown:
    push    rbx
    lea     rdi, [rel uk_pre]
    mov     rsi, uk_pre_len
    call    append_raw
    mov     rdi, [rel argv_ptrs]        ; original argv0 bytes
    mov     rsi, [rel argv_lens]
    call    append_raw
    lea     rdi, [rel uk_mid]
    mov     rsi, uk_mid_len
    call    append_raw
    mov     rbx, 1                      ; loop index (survives append_raw)
.args:
    cmp     rbx, [rel argc]
    jae     .fin
    lea     rdi, [rel ap]
    mov     rsi, 1
    call    append_raw
    lea     rax, [rel argv_ptrs]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel argv_lens]
    mov     rsi, [rax + rbx*8]
    call    append_raw
    lea     rdi, [rel ap_sp]
    mov     rsi, 2
    call    append_raw
    inc     rbx
    jmp     .args
.fin:
    lea     rdi, [rel crlf2]
    mov     rsi, 2
    call    append_raw
    pop     rbx
    ret
