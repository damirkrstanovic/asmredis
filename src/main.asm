%include "syscalls.inc"

global _start
extern net_serve
extern atoi_port
extern arena_init
extern ks_init
extern time_refresh

section .rodata
banner:      db "asmredis", 10
banner_len:  equ $ - banner
flag_banner: db "--banner"
err_port:     db "invalid port (use 1-65535)", 10
err_port_len: equ $ - err_port
; struct kernel_sigaction for SIG_IGN: {sa_handler, sa_flags, sa_restorer, sa_mask}.
; SIG_IGN never invokes user code, so no SA_RESTORER/restorer is required.
align 8
sa_ign:       dq SIG_IGN            ; sa_handler
              dq 0                  ; sa_flags
              dq 0                  ; sa_restorer
              dq 0                  ; sa_mask (SIGSETSIZE bytes)

section .text
_start:
    mov     rax, [rsp]          ; argc
    cmp     rax, 2
    jl      .no_banner
    mov     rsi, [rsp+16]       ; argv[1]
    mov     rax, [rsi]          ; first 8 bytes of argv[1]
    mov     rbx, [rel flag_banner]
    cmp     rax, rbx
    jne     .no_banner
    mov     rax, SYS_write
    mov     rdi, 1
    lea     rsi, [rel banner]
    mov     rdx, banner_len
    syscall
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
.no_banner:
    mov     rdi, PORT_DEFAULT
    mov     rax, [rsp]           ; argc
    cmp     rax, 2
    jl      .have_port
    mov     rdi, [rsp+16]        ; argv[1] ptr
    call    atoi_port            ; rax = port
    mov     rdi, rax
    ; validate 1..65535 (atoi_port would otherwise silently truncate to 16 bits)
    test    rdi, rdi
    jz      .bad_port
    cmp     rdi, 65535
    ja      .bad_port
.have_port:
    push    rdi                  ; preserve port across init calls
    sub     rsp, 8               ; keep rsp%16==0 at arena_init/ks_init calls
    ; ignore SIGPIPE: a write to a peer-closed socket must return -EPIPE (handled
    ; by _send's error path -> close_conn), not terminate the whole server.
    mov     rax, SYS_rt_sigaction
    mov     rdi, SIGPIPE
    lea     rsi, [rel sa_ign]
    xor     rdx, rdx             ; oldact = NULL
    mov     r10, SIGSETSIZE
    syscall
    call    arena_init           ; mmap the value arena
    call    ks_init              ; mmap the initial hashtable
    call    time_refresh         ; seed g_now_ms before net_serve
    add     rsp, 8
    pop     rdi
    call    net_serve            ; never returns
    xor     rdi, rdi
    mov     rax, SYS_exit
    syscall
.bad_port:
    mov     rax, SYS_write
    mov     rdi, 2
    lea     rsi, [rel err_port]
    mov     rdx, err_port_len
    syscall
    mov     rax, SYS_exit
    mov     rdi, 1
    syscall

section .bss
global argc, argv_ptrs, argv_lens
argc:       resq 1
argv_ptrs:  resq MAX_ARGS
argv_lens:  resq MAX_ARGS
