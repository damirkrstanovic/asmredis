%include "syscalls.inc"
global dispatch
extern argc, argv_ptrs, argv_lens
extern to_upper_buf, memcmp_n
extern reply_simple, reply_bulk, append_raw

section .rodata
s_pong:     db "PONG"
s_pong_len  equ $ - s_pong
name_ping:  db "PING"
name_echo:  db "ECHO"
uk_pre:     db "-ERR unknown command '"
uk_pre_len  equ $ - uk_pre
uk_mid:     db "', with args beginning with: "
uk_mid_len  equ $ - uk_mid
ap:         db "'"
ap_sp:      db "' "
crlf2:      db 13, 10

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
    ; only PING/ECHO (both len 4) supported this task
    cmp     rax, 4
    jne     emit_unknown
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
    jne     emit_unknown                ; wrong argc -> unknown for now (Task 5 refines)
    mov     rdi, [rel argv_ptrs + 8]
    mov     rsi, [rel argv_lens + 8]
    call    reply_bulk
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
