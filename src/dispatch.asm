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

section .rodata
s_pong:     db "PONG"
s_pong_len  equ $ - s_pong
s_ok:       db "OK"
s_ok_len    equ $ - s_ok
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
uk_pre:     db "-ERR unknown command '"
uk_pre_len  equ $ - uk_pre
uk_mid:     db "', with args beginning with: "
uk_mid_len  equ $ - uk_mid
ap:         db "'"
ap_sp:      db "' "
crlf2:      db 13, 10
lc_set:     db "set"
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
    jmp     emit_unknown
.len6:
    lea     rdi, [rel cmd_upper]
    lea     rsi, [rel name_lrange]
    mov     rdx, 6
    call    memcmp_n
    test    rax, rax
    je      cmd_lrange
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

; cmd_set: SET key value -> +OK\r\n, or -ERR out of memory\r\n if the arena is full.
cmd_set:
    cmp     qword [rel argc], 3
    jne     .wa
    sub     rsp, 8                      ; align call sites to rsp%16==0
    mov     rdi, [rel argv_ptrs + 8]    ; key ptr
    mov     rsi, [rel argv_lens + 8]    ; key len
    mov     rdx, [rel argv_ptrs + 16]   ; val ptr
    mov     rcx, [rel argv_lens + 16]   ; val len
    call    ks_set                      ; rax=0 ok, 1 oom (arena exhausted)
    test    rax, rax
    jnz     .oom
    lea     rdi, [rel s_ok]
    mov     rsi, s_ok_len
    call    reply_simple
    add     rsp, 8
    ret
.oom:
    call    emit_oom
    add     rsp, 8
    ret
.wa:
    lea     rdi, [rel lc_set]
    mov     rsi, 3
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

; emit_unknown: append the valkey-exact unknown-command error to out_buf.
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
